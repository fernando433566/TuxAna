//! The Wyoming wire format (https://github.com/OHF-Voice/wyoming).
//!
//! Every event is:
//!   1. one line of JSON:  {"type": "...", "data": {...}, "data_length": N, "payload_length": M}
//!   2. optionally N bytes of extra JSON that is merged into "data"
//!   3. optionally M bytes of binary payload (for example raw audio)

use std::io::{self, BufRead, Read, Write};

use serde_json::{json, Map, Value};

/// Protocol version we report in the events we send.
const PROTOCOL_VERSION: &str = "1.8.0";

#[derive(Debug)]
pub struct Event {
    pub kind: String,
    pub data: Value,
    #[allow(dead_code)] // a TTS server never receives audio, but the payload is part of every event
    pub payload: Vec<u8>,
}

impl Event {
    /// A string field of `data`, if present.
    pub fn text(&self, field: &str) -> Option<&str> {
        self.data.get(field).and_then(Value::as_str)
    }
}

/// Reads the next event. `Ok(None)` means the client closed the connection.
pub fn read_event(reader: &mut impl BufRead) -> io::Result<Option<Event>> {
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(None);
    }
    let header: Value = serde_json::from_str(&line).map_err(invalid)?;

    let kind = header.get("type").and_then(Value::as_str).ok_or_else(|| invalid("event without type"))?;
    let mut data = header.get("data").cloned().unwrap_or_else(|| json!({}));

    let data_length = header.get("data_length").and_then(Value::as_u64).unwrap_or(0);
    if data_length > 0 {
        let extra: Value = serde_json::from_slice(&read_bytes(reader, data_length)?).map_err(invalid)?;
        if let (Some(data), Some(extra)) = (data.as_object_mut(), extra.as_object()) {
            data.extend(extra.clone());
        }
    }

    let payload_length = header.get("payload_length").and_then(Value::as_u64).unwrap_or(0);
    let payload = read_bytes(reader, payload_length)?;

    Ok(Some(Event { kind: kind.to_string(), data, payload }))
}

/// Writes one event. `data` should be a JSON object (or `Value::Null` for none).
pub fn write_event(writer: &mut impl Write, kind: &str, data: Value, payload: &[u8]) -> io::Result<()> {
    let mut header = Map::new();
    header.insert("type".into(), kind.into());
    header.insert("version".into(), PROTOCOL_VERSION.into());

    let data_bytes = match &data {
        Value::Object(map) if !map.is_empty() => serde_json::to_vec(&data).map_err(invalid)?,
        _ => Vec::new(),
    };
    if !data_bytes.is_empty() {
        header.insert("data_length".into(), data_bytes.len().into());
    }
    if !payload.is_empty() {
        header.insert("payload_length".into(), payload.len().into());
    }

    writer.write_all(serde_json::to_string(&header).map_err(invalid)?.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.write_all(&data_bytes)?;
    writer.write_all(payload)?;
    writer.flush()
}

fn read_bytes(reader: &mut impl Read, len: u64) -> io::Result<Vec<u8>> {
    let mut buffer = vec![0u8; len as usize];
    reader.read_exact(&mut buffer)?;
    Ok(buffer)
}

fn invalid(err: impl ToString) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_with_data_and_payload() {
        let mut wire = Vec::new();
        write_event(&mut wire, "audio-chunk", json!({"rate": 22050, "width": 2}), &[1, 2, 3]).unwrap();

        let event = read_event(&mut io::Cursor::new(wire)).unwrap().unwrap();
        assert_eq!(event.kind, "audio-chunk");
        assert_eq!(event.data["rate"], 22050);
        assert_eq!(event.payload, vec![1, 2, 3]);
    }

    #[test]
    fn inline_data_is_merged_with_data_block() {
        let extra = br#"{"text":"Hola"}"#;
        let wire = format!("{{\"type\":\"synthesize\",\"data\":{{\"a\":1}},\"data_length\":{}}}\n", extra.len());
        let mut bytes = wire.into_bytes();
        bytes.extend_from_slice(extra);

        let event = read_event(&mut io::Cursor::new(bytes)).unwrap().unwrap();
        assert_eq!(event.text("text"), Some("Hola"));
        assert_eq!(event.data["a"], 1);
    }
}
