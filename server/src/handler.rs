//! One Home Assistant (or other Wyoming client) connection.
//!
//! Events we answer:
//!   describe                         -> info (who we are, which voice we offer)
//!   ping                             -> pong
//!   synthesize {text}                -> audio-start, audio-chunk..., audio-stop
//!   synthesize-start                 -> (opens a text stream)
//!   synthesize-chunk {text}          -> audio-start, audio-chunk..., audio-stop   for every finished sentence
//!   synthesize-stop                  -> audio for the rest of the text, then synthesize-stopped
//!
//! A streaming client also sends a plain `synthesize` inside the stream for older servers; we ignore it,
//! like wyoming-piper does.

use std::io::{self, BufReader, BufWriter, Write};
use std::net::TcpStream;
use std::sync::Arc;

use serde_json::{json, Value};

use crate::engine::{SharedEngine, SynthesisError};
use crate::sentences::SentenceSplitter;
use crate::wyoming::{read_event, write_event};

/// Name of the only voice we offer.
pub const VOICE_NAME: &str = "es_ES-ana";

pub struct Context {
    pub engine: SharedEngine,
    /// Audio is sent to the client in chunks of this many samples (like wyoming-piper).
    pub samples_per_chunk: usize,
}

pub fn handle_client(stream: TcpStream, context: Arc<Context>) -> io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = BufWriter::new(stream);
    // Some(..) while a synthesize-start ... synthesize-stop stream is open.
    let mut text_stream: Option<SentenceSplitter> = None;

    while let Some(event) = read_event(&mut reader)? {
        match event.kind.as_str() {
            "describe" => write_event(&mut writer, "info", info(), &[])?,

            "ping" => write_event(&mut writer, "pong", json!({ "text": event.text("text") }), &[])?,

            "synthesize" if text_stream.is_none() => {
                let text = event.text("text").unwrap_or_default();
                let is_ssml = event.text("text_format") == Some("ssml");
                // The whole text goes to the engine at once, exactly as Windows would speak it.
                speak(&context, &mut writer, text, is_ssml)?;
            }

            "synthesize-start" => text_stream = Some(SentenceSplitter::default()),

            "synthesize-chunk" => {
                if let Some(splitter) = text_stream.as_mut() {
                    for sentence in splitter.push(event.text("text").unwrap_or_default()) {
                        speak(&context, &mut writer, &sentence, false)?;
                    }
                }
            }

            "synthesize-stop" => {
                if let Some(rest) = text_stream.take().and_then(|mut splitter| splitter.finish()) {
                    speak(&context, &mut writer, &rest, false)?;
                }
                write_event(&mut writer, "synthesize-stopped", Value::Null, &[])?;
            }

            _ => {} // events for other services (or the duplicated "synthesize" of a stream)
        }
    }
    Ok(())
}

/// Synthesizes `text` and sends it as audio-start, audio-chunk..., audio-stop.
fn speak(context: &Context, writer: &mut impl Write, text: &str, is_ssml: bool) -> io::Result<()> {
    let text = text.trim();
    let format = json!({ "rate": context.engine.sample_rate(), "width": 2, "channels": 1 });
    eprintln!("[synthesize] {text:?}");

    write_event(writer, "audio-start", format.clone(), &[])?;
    if !text.is_empty() {
        let bytes_per_chunk = context.samples_per_chunk * 2; // 16-bit mono
        let result = context.engine.synthesize(text, is_ssml, |pcm| {
            for chunk in pcm.chunks(bytes_per_chunk) {
                write_event(writer, "audio-chunk", format.clone(), chunk)?;
            }
            Ok(())
        });
        match result {
            Ok(()) => {}
            Err(SynthesisError::Client(err)) => return Err(err),
            Err(SynthesisError::Engine(reason)) => {
                eprintln!("[synthesize] failed: {reason}");
                write_event(writer, "error", json!({ "text": reason, "code": "engine-error" }), &[])?;
            }
        }
    }
    write_event(writer, "audio-stop", Value::Null, &[])
}

/// The answer to `describe`: one TTS program with one voice.
fn info() -> Value {
    let attribution = json!({ "name": "Microsoft", "url": "https://www.microsoft.com/" });
    json!({
        "asr": [], "handle": [], "intent": [], "wake": [], "mic": [], "snd": [],
        "tts": [{
            "name": "tuxana",
            "description": "TuxAna: Microsoft Ana, the Spanish voice of Cortana (original Windows 10 engine in Wine)",
            "attribution": attribution,
            "installed": true,
            "version": env!("CARGO_PKG_VERSION"),
            "supports_synthesize_streaming": true,
            "voices": [{
                "name": VOICE_NAME,
                "description": "Microsoft Ana (Cortana), español de España",
                "attribution": attribution,
                "installed": true,
                "version": null,
                "languages": ["es_ES"],
                "speakers": null
            }]
        }]
    })
}
