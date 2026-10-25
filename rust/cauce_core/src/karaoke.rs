//! Word timings laid over a line's own text, so a karaoke line reads exactly like the plain one
//! whatever spacing a lyrics service gave its words.

/// One timed piece of a line. `text` is a slice of the line: a word and the gap after it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Piece {
    pub text: String,
    pub index: usize,
}

/// Splits `line` at each of `words` in order. Each piece keeps the gap that follows its word,
/// and `index` names the word whose timing lights it. A word the line does not contain is
/// skipped; text before the first word joins the first piece. `None` when no word is found.
pub fn fit(line: &str, words: &[&str]) -> Option<Vec<Piece>> {
    let mut cursor = 0;
    let mut found: Vec<(usize, usize)> = Vec::new();
    for (index, word) in words.iter().enumerate() {
        let word = word.trim();
        if word.is_empty() {
            continue;
        }
        if let Some(at) = line[cursor..].find(word) {
            found.push((cursor + at, index));
            cursor += at + word.len();
        }
    }
    if found.is_empty() {
        return None;
    }
    let pieces = found
        .iter()
        .enumerate()
        .map(|(position, &(at, index))| {
            let start = if position == 0 { 0 } else { at };
            let end = found
                .get(position + 1)
                .map_or(line.len(), |&(next, _)| next);
            Piece {
                text: line[start..end].to_owned(),
                index,
            }
        })
        .collect();
    Some(pieces)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(pieces: &[Piece]) -> Vec<&str> {
        pieces.iter().map(|piece| piece.text.as_str()).collect()
    }

    #[test]
    fn words_without_spaces_get_the_gaps_from_the_line() {
        let pieces = fit("hello there world", &["hello", "there", "world"]).unwrap();
        assert_eq!(texts(&pieces), ["hello ", "there ", "world"]);
        assert_eq!(
            pieces.iter().map(|piece| piece.index).collect::<Vec<_>>(),
            [0, 1, 2]
        );
    }

    #[test]
    fn words_that_already_carry_spaces_are_not_doubled() {
        let pieces = fit("hello there", &["hello ", "there"]).unwrap();
        assert_eq!(texts(&pieces), ["hello ", "there"]);
    }

    #[test]
    fn the_pieces_always_spell_the_whole_line() {
        let line = "(oh) don't stop, now";
        let pieces = fit(line, &["oh", "don't", "stop,", "now"]).unwrap();
        assert_eq!(
            pieces
                .iter()
                .map(|piece| piece.text.as_str())
                .collect::<String>(),
            line
        );
    }

    #[test]
    fn a_word_missing_from_the_line_is_skipped() {
        let pieces = fit("one two", &["one", "zzz", "two"]).unwrap();
        assert_eq!(texts(&pieces), ["one ", "two"]);
        assert_eq!(pieces[1].index, 2);
    }

    #[test]
    fn no_word_found_means_no_karaoke() {
        assert_eq!(fit("one two", &["zzz"]), None);
    }
}
