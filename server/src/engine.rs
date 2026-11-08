//! Talks to `ana-engine.exe`, the Windows program (running in Wine) that owns Microsoft Ana.
//!
//! The engine is started once and kept alive: starting Wine and loading the voice takes a few
//! seconds at most, synthesizing then takes milliseconds.
//! The protocol is described at the top of `windows-side/ana-engine/src/main.rs`.

use std::io::{self, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;
use std::time::Instant;

const FRAME_READY: u32 = 0;
const FRAME_AUDIO: u32 = 1;
const FRAME_DONE: u32 = 2;

/// How to start the engine.
#[derive(Clone, Debug)]
pub struct EngineSettings {
    /// The command that runs Wine.
    pub wine: PathBuf,
    /// Path of `ana-engine.exe`.
    pub engine_exe: PathBuf,
    /// Output sample rate in Hz.
    pub sample_rate: u32,
    /// SAPI speaking rate, -10 (slow) .. 10 (fast); 0 is Windows' default.
    pub speaking_rate: i32,
}

/// Why a synthesis did not finish.
#[derive(Debug)]
pub enum SynthesisError {
    /// The engine reported an error (HRESULT) or died.
    Engine(String),
    /// Writing the audio to the client failed (usually: it disconnected).
    Client(io::Error),
}

/// One running `ana-engine.exe`.
struct Engine {
    process: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Engine {
    fn start(settings: &EngineSettings) -> io::Result<Engine> {
        let mut command = Command::new(&settings.wine);
        command
            .arg(&settings.engine_exe)
            .env("ANA_SAMPLE_RATE", settings.sample_rate.to_string())
            .env("ANA_RATE", settings.speaking_rate.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit()); // Wine and the engine log to our stderr

        let mut process = command.spawn()?;
        let stdin = process.stdin.take().expect("stdin is piped");
        let mut stdout = BufReader::new(process.stdout.take().expect("stdout is piped"));

        wait_for_magic(&mut stdout)?;
        let (kind, payload) = read_frame(&mut stdout)?;
        if kind != FRAME_READY || payload.len() != 4 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "engine did not send READY"));
        }
        Ok(Engine { process, stdin, stdout })
    }

    /// Sends one text and passes every audio chunk to `on_audio` as soon as it arrives.
    fn synthesize(
        &mut self,
        text: &str,
        is_ssml: bool,
        mut on_audio: impl FnMut(&[u8]) -> io::Result<()>,
    ) -> Result<(), SynthesisError> {
        let engine_died = |err: io::Error| SynthesisError::Engine(format!("engine I/O error: {err}"));

        let flags: u32 = if is_ssml { 1 } else { 0 };
        let mut request = Vec::with_capacity(8 + text.len());
        request.extend_from_slice(&flags.to_le_bytes());
        request.extend_from_slice(&(text.len() as u32).to_le_bytes());
        request.extend_from_slice(text.as_bytes());
        self.stdin.write_all(&request).and_then(|_| self.stdin.flush()).map_err(engine_died)?;

        // If the client goes away we keep reading until DONE, so the engine stays in sync for the next request.
        let mut client_error = None;
        loop {
            let (kind, payload) = read_frame(&mut self.stdout).map_err(engine_died)?;
            match kind {
                FRAME_AUDIO if client_error.is_none() => client_error = on_audio(&payload).err(),
                FRAME_AUDIO => {}
                FRAME_DONE => {
                    let status = u32::from_le_bytes(payload[..4].try_into().unwrap_or_default());
                    return match (status, client_error) {
                        (_, Some(err)) => Err(SynthesisError::Client(err)),
                        (0, None) => Ok(()),
                        (hresult, None) => Err(SynthesisError::Engine(format!("SAPI error 0x{hresult:08x}"))),
                    };
                }
                other => return Err(SynthesisError::Engine(format!("unexpected frame kind {other}"))),
            }
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

/// The engine shared by all client connections. Requests are served one at a time.
pub struct SharedEngine {
    settings: EngineSettings,
    engine: Mutex<Option<Engine>>,
}

impl SharedEngine {
    pub fn new(settings: EngineSettings) -> Self {
        SharedEngine { settings, engine: Mutex::new(None) }
    }

    pub fn sample_rate(&self) -> u32 {
        self.settings.sample_rate
    }

    /// Starts the engine now (if it is not running), so the first request does not have to wait.
    pub fn warm_up(&self) {
        let mut slot = self.engine.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(err) = ensure_started(&mut slot, &self.settings) {
            eprintln!("[engine] could not start: {err}");
        }
    }

    pub fn synthesize(
        &self,
        text: &str,
        is_ssml: bool,
        on_audio: impl FnMut(&[u8]) -> io::Result<()>,
    ) -> Result<(), SynthesisError> {
        let mut slot = self.engine.lock().unwrap_or_else(|e| e.into_inner());
        let engine = ensure_started(&mut slot, &self.settings)
            .map_err(|err| SynthesisError::Engine(format!("could not start the engine: {err}")))?;

        let result = engine.synthesize(text, is_ssml, on_audio);
        if let Err(SynthesisError::Engine(reason)) = &result {
            // The process may be broken: throw it away, the next request starts a fresh one.
            eprintln!("[engine] {reason}; restarting it on the next request");
            *slot = None;
        }
        result
    }
}

fn ensure_started<'a>(slot: &'a mut Option<Engine>, settings: &EngineSettings) -> io::Result<&'a mut Engine> {
    if slot.is_none() {
        eprintln!("[engine] starting Microsoft Ana (this takes a while the first time)...");
        let started = Instant::now();
        *slot = Some(Engine::start(settings)?);
        eprintln!("[engine] ready after {:.1} s", started.elapsed().as_secs_f32());
    }
    Ok(slot.as_mut().expect("just started"))
}

/// Skips anything printed before the engine's "ANA1" marker (Wine may print messages to stdout).
fn wait_for_magic(stdout: &mut impl Read) -> io::Result<()> {
    let mut last_four = [0u8; 4];
    let mut byte = [0u8; 1];
    while &last_four != b"ANA1" {
        if stdout.read(&mut byte)? == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "engine exited during start-up"));
        }
        last_four.rotate_left(1);
        last_four[3] = byte[0];
    }
    Ok(())
}

fn read_frame(stdout: &mut impl Read) -> io::Result<(u32, Vec<u8>)> {
    let mut header = [0u8; 8];
    stdout.read_exact(&mut header)?;
    let kind = u32::from_le_bytes(header[0..4].try_into().unwrap());
    let len = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    let mut payload = vec![0u8; len];
    stdout.read_exact(&mut payload)?;
    Ok((kind, payload))
}
