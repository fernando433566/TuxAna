//! TuxAna (`tuxana`): a Wyoming text-to-speech server (the protocol Home Assistant uses for Piper)
//! that speaks with Microsoft Ana, the Spanish (Spain) voice of Cortana.
//!
//! The voice is Microsoft's original Windows OneCore engine, run by Wine.
//! This program only does the networking; the speech itself comes from `ana-engine.exe` (see engine.rs).
//!
//! Options (each one can also be given as an environment variable):
//!   --uri tcp://0.0.0.0:10200      WYOMING_URI          where to listen
//!   --wine /opt/wine/bin/wine      ANA_WINE             command that runs Wine
//!   --engine-exe <path>            ANA_ENGINE_EXE       ana-engine.exe
//!   --sample-rate 22050            ANA_SAMPLE_RATE      output sample rate (Hz)
//!   --rate 0                       ANA_RATE             speaking rate, -10..10 (0 = like Windows)
//!   --samples-per-chunk 1024       ANA_SAMPLES_PER_CHUNK

mod engine;
mod handler;
mod sentences;
mod wyoming;

use std::net::TcpListener;
use std::sync::Arc;
use std::thread;

use engine::{EngineSettings, SharedEngine};
use handler::{handle_client, Context};

fn main() {
    let uri = option("--uri", "WYOMING_URI", "tcp://0.0.0.0:10200");
    let settings = EngineSettings {
        wine: option("--wine", "ANA_WINE", "/opt/wine/bin/wine").into(),
        engine_exe: option("--engine-exe", "ANA_ENGINE_EXE", "/opt/ana/windows/ana-engine.exe").into(),
        sample_rate: number(option("--sample-rate", "ANA_SAMPLE_RATE", "22050"), "--sample-rate"),
        speaking_rate: number(option("--rate", "ANA_RATE", "0"), "--rate"),
    };
    let samples_per_chunk = number(option("--samples-per-chunk", "ANA_SAMPLES_PER_CHUNK", "1024"), "--samples-per-chunk");

    let address = uri.strip_prefix("tcp://").unwrap_or(&uri);
    let listener = TcpListener::bind(address).unwrap_or_else(|err| fail(&format!("cannot listen on {address}: {err}")));
    eprintln!("[server] listening on tcp://{address}");

    let context = Arc::new(Context { engine: SharedEngine::new(settings), samples_per_chunk });

    // Start Wine + Ana in the background; clients can already connect (describe works immediately).
    let warm = Arc::clone(&context);
    thread::spawn(move || warm.engine.warm_up());

    for connection in listener.incoming() {
        let Ok(stream) = connection else { continue };
        let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_default();
        let context = Arc::clone(&context);
        thread::spawn(move || {
            if let Err(err) = handle_client(stream, context) {
                eprintln!("[client {peer}] connection closed: {err}");
            }
        });
    }
}

/// Value of a command-line option, else of an environment variable, else the default.
fn option(flag: &str, env_name: &str, default: &str) -> String {
    let args: Vec<String> = std::env::args().collect();
    if let Some(position) = args.iter().position(|a| a == flag) {
        return args.get(position + 1).cloned().unwrap_or_else(|| fail(&format!("{flag} needs a value")));
    }
    std::env::var(env_name).unwrap_or_else(|_| default.to_string())
}

fn number<T: std::str::FromStr>(text: String, name: &str) -> T {
    text.trim().parse().unwrap_or_else(|_| fail(&format!("{name}: '{text}' is not a valid number")))
}

fn fail(message: &str) -> ! {
    eprintln!("tuxana: {message}");
    std::process::exit(2);
}
