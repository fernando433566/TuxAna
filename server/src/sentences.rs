//! Cuts streamed text into whole sentences.
//!
//! When Home Assistant streams an answer (for example from an LLM) the text arrives in small pieces.
//! Speaking each piece on its own would break the intonation, so we wait for complete sentences.

/// Characters that end a sentence.
const SENTENCE_END: [char; 4] = ['.', '!', '?', '…'];
/// Characters that may follow the end mark and still belong to the sentence: «¿Vienes?» dijo.
const CLOSING: [char; 6] = ['"', '\'', '»', '”', ')', ']'];

#[derive(Default)]
pub struct SentenceSplitter {
    pending: String,
}

impl SentenceSplitter {
    /// Adds a piece of text and returns the sentences it completed.
    pub fn push(&mut self, chunk: &str) -> Vec<String> {
        self.pending.push_str(chunk);
        let mut sentences = Vec::new();
        while let Some(end) = find_sentence_end(&self.pending) {
            let rest = self.pending.split_off(end);
            let sentence = std::mem::replace(&mut self.pending, rest);
            push_trimmed(&mut sentences, &sentence);
        }
        sentences
    }

    /// Returns whatever is left when the stream ends.
    pub fn finish(&mut self) -> Option<String> {
        let rest = std::mem::take(&mut self.pending);
        let rest = rest.trim();
        (!rest.is_empty()).then(|| rest.to_string())
    }
}

/// Byte index just after the first complete sentence, if there is one.
/// A sentence is complete when its end mark (plus closing quotes) is followed by whitespace,
/// or at a line break. We need to see that whitespace, so "3.5" is never cut.
fn find_sentence_end(text: &str) -> Option<usize> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    for (i, &(index, c)) in chars.iter().enumerate() {
        if c == '\n' {
            return Some(index + 1);
        }
        if !SENTENCE_END.contains(&c) {
            continue;
        }
        let mut next = i + 1;
        while next < chars.len() && (SENTENCE_END.contains(&chars[next].1) || CLOSING.contains(&chars[next].1)) {
            next += 1; // "?!", "...", "?»"
        }
        if next < chars.len() && chars[next].1.is_whitespace() {
            return Some(chars[next].0);
        }
    }
    None
}

fn push_trimmed(sentences: &mut Vec<String>, sentence: &str) {
    let sentence = sentence.trim();
    if !sentence.is_empty() {
        sentences.push(sentence.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_for_whole_sentences() {
        let mut splitter = SentenceSplitter::default();
        assert!(splitter.push("Hola, soy Cor").is_empty());
        assert_eq!(splitter.push("tana. ¿En qué puedo ").as_slice(), ["Hola, soy Cortana."]);
        assert!(splitter.push("ayudarte?").is_empty()); // no whitespace after "?" yet
        assert_eq!(splitter.finish().as_deref(), Some("¿En qué puedo ayudarte?"));
    }

    #[test]
    fn keeps_decimals_quotes_and_repeated_marks() {
        let mut splitter = SentenceSplitter::default();
        let sentences = splitter.push("Hace 3.5 grados. «¡Qué frío!» dijo. ¿¡En serio?! Sí.\nVale ");
        assert_eq!(sentences, ["Hace 3.5 grados.", "«¡Qué frío!»", "dijo.", "¿¡En serio?!", "Sí."]);
        assert_eq!(splitter.finish().as_deref(), Some("Vale"));
    }
}
