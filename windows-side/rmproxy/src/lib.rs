//! rmproxy.dll: lets Microsoft's OneCore TTS engine (MSTTSEngine_OneCore.dll) run without `sapi_onecore.dll`.
//!
//! The OneCore engine asks COM for a few helper classes that live in `sapi_onecore.dll`, a DLL Wine cannot
//! load. The Speech Platform 11 runtime (`mssps.dll`) has classes with the same interfaces, so the registry
//! points those OneCore class ids at this DLL, and this DLL forwards each request:
//!
//! ```text
//! HKCR\CLSID\{onecore-clsid}\InprocServer32  = ...\rmproxy.dll
//! HKCR\CLSID\{onecore-clsid}\ProxyTarget     (default) = "{speech-platform-clsid}"  or  "stub-lexicon"
//!                                           "Dll"     = DLL to forward to (default: Speech Platform mssps.dll)
//! ```
//!
//! "stub-lexicon" is an empty user lexicon: there are no custom pronunciations, so the engine always uses
//! its own dictionary, exactly as on a fresh Windows install.

#![allow(non_snake_case)]

use std::ffi::c_void;

use windows::core::{implement, w, IUnknown, Interface, Result, GUID, HRESULT, PCWSTR};
use windows::Win32::Foundation::{BOOL, CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, S_FALSE};
use windows::Win32::Media::Speech::{
    ISpContainerLexicon, ISpContainerLexicon_Impl, ISpLexicon, ISpLexicon_Impl, SPPARTOFSPEECH, SPWORDLIST,
    SPWORDPRONUNCIATIONLIST,
};
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::System::Registry::{RegGetValueW, HKEY_CLASSES_ROOT, RRF_RT_REG_SZ};

const SPERR_NOT_IN_LEX: HRESULT = HRESULT(0x8004_5037_u32 as i32);
const DEFAULT_TARGET_DLL: PCWSTR = w!(r"C:\Program Files\Common Files\Microsoft Shared\Speech\Platform\v11.0\mssps.dll");

type DllGetClassObjectFn = unsafe extern "system" fn(*const GUID, *const GUID, *mut *mut c_void) -> HRESULT;

/// Entry point COM calls to get a class factory for one of "our" class ids.
#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(clsid: *const GUID, iid: *const GUID, out: *mut *mut c_void) -> HRESULT {
    let key = format!(r"CLSID\{{{:?}}}\ProxyTarget", *clsid);
    let Some(target) = read_registry_string(&key, None) else {
        return CLASS_E_CLASSNOTAVAILABLE;
    };

    if target.eq_ignore_ascii_case("stub-lexicon") {
        let factory: IClassFactory = StubLexiconFactory.into();
        return factory.query(iid, out);
    }

    // Forward to the real class in the Speech Platform (or the DLL named in "Dll").
    let Ok(target_clsid) = parse_guid(&target) else {
        return CLASS_E_CLASSNOTAVAILABLE;
    };
    let dll = read_registry_string(&key, Some("Dll"));
    let dll_path = match &dll {
        Some(path) => windows::core::HSTRING::from(path.as_str()),
        None => windows::core::HSTRING::from(DEFAULT_TARGET_DLL.to_string().unwrap_or_default()),
    };
    let Ok(module) = LoadLibraryW(&dll_path) else {
        return CLASS_E_CLASSNOTAVAILABLE;
    };
    let Some(entry) = GetProcAddress(module, windows::core::s!("DllGetClassObject")) else {
        return CLASS_E_CLASSNOTAVAILABLE;
    };
    let real_get_class_object: DllGetClassObjectFn = std::mem::transmute(entry);
    real_get_class_object(&target_clsid, iid, out)
}

/// The DLL is never unloaded (it is tiny and the engine keeps using it).
#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_FALSE
}

// ---------------------------------------------------------------------------------------------
// The empty lexicon and its class factory
// ---------------------------------------------------------------------------------------------

#[implement(IClassFactory)]
struct StubLexiconFactory;

impl IClassFactory_Impl for StubLexiconFactory_Impl {
    fn CreateInstance(&self, outer: Option<&IUnknown>, iid: *const GUID, out: *mut *mut c_void) -> Result<()> {
        if outer.is_some() {
            return Err(CLASS_E_NOAGGREGATION.into());
        }
        let lexicon: ISpContainerLexicon = StubLexicon.into();
        unsafe { lexicon.query(iid, out).ok() }
    }

    fn LockServer(&self, _lock: BOOL) -> Result<()> {
        Ok(())
    }
}

#[implement(ISpContainerLexicon)]
struct StubLexicon;

impl ISpLexicon_Impl for StubLexicon_Impl {
    fn GetPronunciations(&self, _word: &PCWSTR, _lang: u16, _flags: u32, _list: *mut SPWORDPRONUNCIATIONLIST) -> Result<()> {
        Err(SPERR_NOT_IN_LEX.into()) // "not in this lexicon": the engine falls back to its own dictionary
    }
    fn AddPronunciation(&self, _word: &PCWSTR, _lang: u16, _pos: SPPARTOFSPEECH, _pron: *const u16) -> Result<()> {
        Ok(())
    }
    fn RemovePronunciation(&self, _word: &PCWSTR, _lang: u16, _pos: SPPARTOFSPEECH, _pron: *const u16) -> Result<()> {
        Ok(())
    }
    fn GetGeneration(&self, generation: *mut u32) -> Result<()> {
        unsafe { write_if_not_null(generation, 1) };
        Ok(())
    }
    fn GetGenerationChange(&self, _flags: u32, generation: *mut u32, list: *mut SPWORDLIST) -> Result<()> {
        unsafe {
            write_if_not_null(generation, 1);
            if !list.is_null() {
                (*list).pFirstWord = std::ptr::null_mut();
            }
        }
        Ok(())
    }
    fn GetWords(&self, _flags: u32, generation: *mut u32, cookie: *mut u32, list: *mut SPWORDLIST) -> Result<()> {
        unsafe {
            write_if_not_null(generation, 1);
            write_if_not_null(cookie, 0);
            if !list.is_null() {
                (*list).pFirstWord = std::ptr::null_mut();
            }
        }
        Ok(())
    }
}

impl ISpContainerLexicon_Impl for StubLexicon_Impl {
    fn AddLexicon(&self, _lexicon: Option<&ISpLexicon>, _flags: u32) -> Result<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------

unsafe fn write_if_not_null(ptr: *mut u32, value: u32) {
    if !ptr.is_null() {
        *ptr = value;
    }
}

/// Reads a REG_SZ value below HKEY_CLASSES_ROOT (`None` = the key's default value).
fn read_registry_string(key: &str, value: Option<&str>) -> Option<String> {
    let key = windows::core::HSTRING::from(key);
    let value = value.map(windows::core::HSTRING::from);
    let value_ptr = value.as_ref().map_or(PCWSTR::null(), |v| PCWSTR(v.as_ptr()));
    let mut buffer = [0u16; 512];
    let mut size = std::mem::size_of_val(&buffer) as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CLASSES_ROOT,
            &key,
            value_ptr,
            RRF_RT_REG_SZ,
            None,
            Some(buffer.as_mut_ptr() as *mut c_void),
            Some(&mut size),
        )
    };
    if status.is_err() {
        return None;
    }
    let chars = (size as usize / 2).saturating_sub(1); // size includes the terminating NUL
    Some(String::from_utf16_lossy(&buffer[..chars]))
}

fn parse_guid(text: &str) -> std::result::Result<GUID, ()> {
    let hex: String = text.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    u128::from_str_radix(&hex, 16).map(GUID::from_u128).map_err(|_| ())
}
