//! ana-engine.exe: Microsoft Ana (the Spanish voice of Cortana) as a long-running process.
//!
//! It runs inside Wine. It loads the voice once, then waits for texts on stdin and writes the
//! audio to stdout *while* SAPI is producing it. The Linux `tuxana` server is its only client.
//!
//! Wire protocol (every integer is a little-endian u32):
//!
//! ```text
//! start-up  engine -> server   "ANA1"  READY frame
//! request   server -> engine   flags  text_len  text (UTF-8)       flags: 0 = plain text, 1 = SSML
//! response  engine -> server   AUDIO frame ... AUDIO frame  DONE frame
//!
//! frame = kind  payload_len  payload
//!   kind 0 READY  payload = sample rate
//!   kind 1 AUDIO  payload = 16-bit mono PCM
//!   kind 2 DONE   payload = HRESULT of the synthesis (0 = success)
//! ```
//!
//! Settings come from environment variables (Wine passes them through):
//! `ANA_SAMPLE_RATE` (default 22050) and `ANA_RATE` (SAPI speaking rate -10..10, default 0).

use std::ffi::c_void;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use windows::core::{implement, Result, GUID, HRESULT, HSTRING};
use windows::Win32::Foundation::{E_FAIL, E_NOTIMPL, S_OK};
use windows::Win32::Media::Audio::{WAVEFORMATEX, WAVE_FORMAT_PCM};
use windows::Win32::Media::Speech::{ISpObjectToken, ISpStream, ISpVoice, SPF_IS_NOT_XML, SPF_IS_XML};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, ISequentialStream_Impl, IStream, IStream_Impl, CLSCTX_INPROC_SERVER,
    COINIT_MULTITHREADED, LOCKTYPE, STATFLAG, STATSTG, STGC, STGTY_STREAM, STREAM_SEEK,
};

// Classes of the Microsoft Speech Platform 11 runtime (mssps.dll), which hosts the OneCore engine.
const CLSID_SP_VOICE: GUID = GUID::from_u128(0xd941651c_44e6_4c17_badf_c36826fc3424);
const CLSID_SP_STREAM: GUID = GUID::from_u128(0x0f59bf10_9fa9_4469_b4d3_d83d939b4ac3);
const CLSID_SP_OBJECT_TOKEN: GUID = GUID::from_u128(0x4424cb70_2a7c_43e2_833d_cbfd82da104f);
/// "The stream contains raw PCM described by a WAVEFORMATEX".
const SPDFID_WAVEFORMATEX: GUID = GUID::from_u128(0xc31adbae_527f_4ff5_a230_f62bb61ff70c);
/// Registry token of the voice (created by the container's `ana.reg`).
const ANA_TOKEN: &str = r"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech Server\v11.0\Voices\Tokens\MSTTS_V110_esES_Ana";

const FRAME_READY: u32 = 0;
const FRAME_AUDIO: u32 = 1;
const FRAME_DONE: u32 = 2;

fn main() {
    if let Err(err) = run() {
        eprintln!("ana-engine: fatal error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let sample_rate: u32 = env_number("ANA_SAMPLE_RATE", 22050);
    let speaking_rate: i32 = env_number("ANA_RATE", 0);
    let format = pcm_format(sample_rate);

    let voice = load_ana(speaking_rate)?;

    // The first synthesis loads the voice data (~90 MB); do it now so the first real request is fast.
    speak(&voice, &format, "Hola.", false, Output::Discard)?;
    eprintln!("ana-engine: voice loaded ({sample_rate} Hz, rate {speaking_rate})");

    send_bytes(b"ANA1").map_err(io_to_win)?;
    send_frame(FRAME_READY, &sample_rate.to_le_bytes()).map_err(io_to_win)?;

    let mut stdin = io::stdin().lock();
    while let Some((text, is_ssml)) = read_request(&mut stdin).map_err(io_to_win)? {
        let status = match speak(&voice, &format, &text, is_ssml, Output::Stdout) {
            Ok(()) => S_OK,
            Err(err) => {
                eprintln!("ana-engine: synthesis failed: {err}");
                err.code()
            }
        };
        send_frame(FRAME_DONE, &(status.0 as u32).to_le_bytes()).map_err(io_to_win)?;
    }
    Ok(()) // stdin closed: the server is gone
}

/// Creates a Speech Platform voice object and selects Microsoft Ana.
fn load_ana(speaking_rate: i32) -> Result<ISpVoice> {
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        let voice: ISpVoice = CoCreateInstance(&CLSID_SP_VOICE, None, CLSCTX_INPROC_SERVER)?;
        let token: ISpObjectToken = CoCreateInstance(&CLSID_SP_OBJECT_TOKEN, None, CLSCTX_INPROC_SERVER)?;
        token.SetId(None, &HSTRING::from(ANA_TOKEN), false)?;
        voice.SetVoice(&token)?;
        voice.SetRate(speaking_rate)?;
        Ok(voice)
    }
}

/// Synthesizes `text`. Returns when SAPI has finished; the audio has been written by then.
fn speak(voice: &ISpVoice, format: &WAVEFORMATEX, text: &str, is_ssml: bool, output: Output) -> Result<()> {
    let flags = if is_ssml { SPF_IS_XML } else { SPF_IS_NOT_XML };
    unsafe {
        // SAPI writes into an ISpStream; we give it a base stream (PcmSink) that forwards every write.
        let sink: IStream = PcmSink::new(output).into();
        let stream: ISpStream = CoCreateInstance(&CLSID_SP_STREAM, None, CLSCTX_INPROC_SERVER)?;
        stream.SetBaseStream(&sink, &SPDFID_WAVEFORMATEX, format)?;
        voice.SetOutput(&stream, false)?;
        voice.Speak(&HSTRING::from(text), flags.0 as u32, None)
    }
}

fn pcm_format(sample_rate: u32) -> WAVEFORMATEX {
    WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_PCM as u16,
        nChannels: 1,
        nSamplesPerSec: sample_rate,
        nAvgBytesPerSec: sample_rate * 2,
        nBlockAlign: 2,
        wBitsPerSample: 16,
        cbSize: 0,
    }
}

// ---------------------------------------------------------------------------------------------
// PcmSink: a minimal COM IStream. SAPI only writes to it (and asks for the current position).
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Output {
    /// Send each chunk to the server as an AUDIO frame.
    Stdout,
    /// Throw the audio away (warm-up).
    Discard,
}

#[implement(IStream)]
struct PcmSink {
    output: Output,
    bytes_written: AtomicU64,
    failed: AtomicBool,
}

impl PcmSink {
    fn new(output: Output) -> Self {
        PcmSink { output, bytes_written: AtomicU64::new(0), failed: AtomicBool::new(false) }
    }
}

impl ISequentialStream_Impl for PcmSink_Impl {
    fn Read(&self, _buffer: *mut c_void, _len: u32, _read: *mut u32) -> HRESULT {
        E_NOTIMPL
    }

    fn Write(&self, buffer: *const c_void, len: u32, written: *mut u32) -> HRESULT {
        let pcm = unsafe { std::slice::from_raw_parts(buffer as *const u8, len as usize) };
        if let Output::Stdout = self.output {
            if self.failed.load(Ordering::Relaxed) || send_frame(FRAME_AUDIO, pcm).is_err() {
                self.failed.store(true, Ordering::Relaxed);
                return E_FAIL; // stdout is broken: make SAPI abort this utterance
            }
        }
        self.bytes_written.fetch_add(len as u64, Ordering::Relaxed);
        if !written.is_null() {
            unsafe { *written = len };
        }
        S_OK
    }
}

impl IStream_Impl for PcmSink_Impl {
    fn Seek(&self, offset: i64, _origin: STREAM_SEEK, new_position: *mut u64) -> Result<()> {
        // SAPI only uses Seek(0, ...) to ask where it is; real repositioning is not possible on a pipe.
        if offset != 0 {
            return Err(E_NOTIMPL.into());
        }
        if !new_position.is_null() {
            unsafe { *new_position = self.bytes_written.load(Ordering::Relaxed) };
        }
        Ok(())
    }

    fn Stat(&self, stat: *mut STATSTG, _flags: &STATFLAG) -> Result<()> {
        if !stat.is_null() {
            unsafe {
                *stat = STATSTG::default();
                (*stat).r#type = STGTY_STREAM.0 as u32;
                (*stat).cbSize = self.bytes_written.load(Ordering::Relaxed);
            }
        }
        Ok(())
    }

    fn SetSize(&self, _size: u64) -> Result<()> {
        Ok(())
    }
    fn Commit(&self, _flags: &STGC) -> Result<()> {
        Ok(())
    }
    fn Revert(&self) -> Result<()> {
        Ok(())
    }
    fn CopyTo(&self, _to: Option<&IStream>, _len: u64, _read: *mut u64, _written: *mut u64) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn LockRegion(&self, _offset: u64, _len: u64, _kind: &LOCKTYPE) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn UnlockRegion(&self, _offset: u64, _len: u64, _kind: u32) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn Clone(&self) -> Result<IStream> {
        Err(E_NOTIMPL.into())
    }
}

// ---------------------------------------------------------------------------------------------
// stdin / stdout helpers
// ---------------------------------------------------------------------------------------------

/// Reads one request. `None` means the server closed stdin.
fn read_request(input: &mut impl Read) -> io::Result<Option<(String, bool)>> {
    let mut header = [0u8; 8];
    match input.read_exact(&mut header) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err),
    }
    let flags = u32::from_le_bytes(header[0..4].try_into().unwrap());
    let len = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    let mut text = vec![0u8; len];
    input.read_exact(&mut text)?;
    let text = String::from_utf8(text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok(Some((text, flags & 1 == 1)))
}

fn send_frame(kind: u32, payload: &[u8]) -> io::Result<()> {
    let mut out = io::stdout().lock(); // the lock keeps frames from different threads apart
    out.write_all(&kind.to_le_bytes())?;
    out.write_all(&(payload.len() as u32).to_le_bytes())?;
    out.write_all(payload)?;
    out.flush()
}

fn send_bytes(bytes: &[u8]) -> io::Result<()> {
    let mut out = io::stdout().lock();
    out.write_all(bytes)?;
    out.flush()
}

fn env_number<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

fn io_to_win(err: io::Error) -> windows::core::Error {
    eprintln!("ana-engine: I/O error: {err}");
    E_FAIL.into()
}
