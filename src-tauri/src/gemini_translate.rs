// Live Translate (gemini.rs, translate mode) sends two continuous streams with no turns: what was
// said (inputTranscription) and the Chinese (outputTranscription), the second a little behind the
// first. This pairs them into caption lines:
//   - What was said grows the newest line (gray). The line ends at a pause (IN_QUIET without new
//     words), or at the end of a sentence once it is long (SPLIT_CHARS), or at MAX_CHARS anyway.
//   - The Chinese goes to the oldest line still waiting for its translation. That line's
//     translation is complete when the line has ended and the Chinese has as many sentences as
//     what was said, or once the next line has ended too and the Chinese reads as a whole sentence
//     of plausible length, or when no Chinese has come for ZH_QUIET after the line ended. A piece
//     of Chinese that completes one line and starts the next is split at the sentence end.
// Nothing here talks to the network or the screen: a Sink receives the lines, so the pairing is
// tested on its own (tests below).

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use tauri::AppHandle;

use crate::captions;
use crate::zh;

/// A pause this long ends the line being spoken.
const IN_QUIET: Duration = Duration::from_millis(1000);
/// No more Chinese for this long after a line ended: its translation is as complete as it gets.
const ZH_QUIET: Duration = Duration::from_millis(3000);
/// A sentence end past this many characters ends the line (long unbroken speech).
const SPLIT_CHARS: usize = 120;
/// A line ends here even without a sentence end.
const MAX_CHARS: usize = 300;

/// Where the lines go.
pub trait Sink {
    /// A new caption line; returns its id.
    fn open(&mut self) -> u64;
    /// What was said so far on the line; `done` when the line has ended.
    fn heard(&mut self, id: u64, text: &str, done: bool);
    /// The line's Chinese so far; `done` when it is complete.
    fn translated(&mut self, id: u64, text: &str, done: bool);
    /// A line that ended with nothing on it.
    fn drop_line(&mut self, id: u64);
}

struct Line {
    id: u64,
    en: String,
    zh: String,
    /// When what was said on it ended.
    ended: Option<Instant>,
}

#[derive(Default)]
pub struct Interp {
    /// Lines still being spoken or translated, oldest first.
    lines: VecDeque<Line>,
    last_in: Option<Instant>,
    last_out: Option<Instant>,
}

impl Interp {
    /// A piece of what was said.
    pub fn heard(&mut self, piece: &str, now: Instant, sink: &mut impl Sink) {
        if piece.trim().is_empty() {
            return;
        }
        self.last_in = Some(now);
        if self.lines.back().is_none_or(|l| l.ended.is_some()) {
            let id = sink.open();
            self.lines.push_back(Line { id, en: String::new(), zh: String::new(), ended: None });
        }
        let line = self.lines.back_mut().expect("a line was just ensured");
        grow(&mut line.en, piece);
        let text = line.en.trim();
        let n = text.chars().count();
        let long = n >= MAX_CHARS || (n >= SPLIT_CHARS && ends_sentence(text));
        sink.heard(line.id, text, long);
        if long {
            line.ended = Some(now);
        }
    }

    /// A piece of the translation.
    pub fn translated(&mut self, piece: &str, now: Instant, sink: &mut impl Sink) {
        if piece.is_empty() {
            return;
        }
        self.last_out = Some(now);
        let mut rest = piece;
        while !rest.is_empty() {
            // A line already complete now that the next one has ended does not take this piece.
            self.release(sink);
            if self.lines.is_empty() {
                // Chinese with nothing heard before it: a line of its own.
                let id = sink.open();
                self.lines.push_back(Line { id, en: String::new(), zh: String::new(), ended: Some(now) });
            }
            // Feed up to and including the next sentence end, then see whether the line is complete.
            let cut = rest.char_indices().find(|(_, c)| is_zh_end(*c)).map_or(rest.len(), |(i, c)| i + c.len_utf8());
            let (head, tail) = rest.split_at(cut);
            rest = tail;
            let next_ended = self.lines.get(1).is_some_and(|l| l.ended.is_some());
            let line = self.lines.front_mut().expect("a line was just ensured");
            grow(&mut line.zh, head);
            let complete = translation_complete(line, next_ended);
            sink.translated(line.id, line.zh.trim(), complete);
            if complete {
                self.lines.pop_front();
            }
        }
    }

    /// Lines at the front whose translation is complete leave.
    fn release(&mut self, sink: &mut impl Sink) {
        while let Some(line) = self.lines.front() {
            let next_ended = self.lines.get(1).is_some_and(|l| l.ended.is_some());
            if !translation_complete(line, next_ended) {
                break;
            }
            let line = self.lines.pop_front().expect("front exists");
            sink.translated(line.id, line.zh.trim(), true);
        }
    }

    /// Time passes: pauses end lines and their translations.
    pub fn tick(&mut self, now: Instant, sink: &mut impl Sink) {
        if let Some(line) = self.lines.back_mut().filter(|l| l.ended.is_none()) {
            if self.last_in.is_some_and(|t| now.duration_since(t) >= IN_QUIET) {
                line.ended = Some(now);
                sink.heard(line.id, line.en.trim(), true);
            }
        }
        self.release(sink);
        while let Some(line) = self.lines.front() {
            let Some(ended) = line.ended else { break };
            let since = self.last_out.map_or(ended, |o| o.max(ended));
            if now.duration_since(since) < ZH_QUIET {
                break;
            }
            let line = self.lines.pop_front().expect("front exists");
            finish(line, sink);
        }
    }

    /// The session ended: every line ends as it stands.
    pub fn flush(&mut self, sink: &mut impl Sink) {
        while let Some(mut line) = self.lines.pop_front() {
            if line.ended.is_none() {
                line.ended = Some(Instant::now());
                if !line.en.trim().is_empty() {
                    sink.heard(line.id, line.en.trim(), true);
                }
            }
            finish(line, sink);
        }
    }

    /// Nothing is being spoken or translated.
    pub fn idle(&self) -> bool {
        self.lines.is_empty()
    }
}

/// A line's translation ends as it stands (or the line goes, when nothing came of it).
fn finish(line: Line, sink: &mut impl Sink) {
    if line.en.trim().is_empty() && line.zh.trim().is_empty() {
        sink.drop_line(line.id);
    } else {
        sink.translated(line.id, line.zh.trim(), true);
    }
}

fn translation_complete(line: &Line, next_ended: bool) -> bool {
    if line.ended.is_none() || !line.zh.trim_end().ends_with(is_zh_end) {
        return false;
    }
    let (en, zh) = (line.en.trim(), line.zh.trim());
    if sentences(zh) >= sentences(en) {
        return true;
    }
    // The interpreter joined sentences: once the next line is waiting too, a whole sentence of
    // plausible length (Chinese runs about a third of the English letters, or more) will do.
    next_ended && zh.chars().count() * 4 >= en.chars().count()
}

/// Streams may send pieces (deltas) or the text so far; either way `text` ends up as the whole.
fn grow(text: &mut String, piece: &str) {
    let so_far = text.trim();
    let whole = piece.trim_start();
    if !so_far.is_empty() && whole.len() > so_far.len() && whole.starts_with(so_far) {
        *text = piece.to_string();
    } else {
        text.push_str(piece);
    }
}

fn is_zh_end(c: char) -> bool {
    matches!(c, '。' | '？' | '！' | '?' | '!' | '…')
}

fn ends_sentence(text: &str) -> bool {
    text.trim_end().ends_with(['.', '?', '!', '。', '？', '！', '…'])
}

/// Sentences in a line of any language (at least one).
fn sentences(text: &str) -> usize {
    text.split(['.', '?', '!', '。', '？', '！', '…']).filter(|s| s.chars().any(char::is_alphanumeric)).count().max(1)
}

/// The captions on screen, in the transcript and in the summary.
pub struct CaptionSink<'a>(pub &'a AppHandle);

impl Sink for CaptionSink<'_> {
    fn open(&mut self) -> u64 {
        captions::open(self.0)
    }

    fn heard(&mut self, id: u64, text: &str, done: bool) {
        if done {
            captions::finish_heard(self.0, id, text);
        } else {
            captions::show_heard(self.0, id, text);
        }
    }

    fn translated(&mut self, id: u64, text: &str, done: bool) {
        captions::set_translation(self.0, id, &zh::to_taiwan(text), done);
    }

    fn drop_line(&mut self, id: u64) {
        captions::drop_line(self.0, id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Records what reaches the screen: per line, what was said and the Chinese, and whether each is done.
    #[derive(Default)]
    struct Screen {
        lines: Vec<(String, bool, String, bool)>,
        dropped: Vec<u64>,
    }

    impl Sink for Screen {
        fn open(&mut self) -> u64 {
            self.lines.push(Default::default());
            self.lines.len() as u64 - 1
        }
        fn heard(&mut self, id: u64, text: &str, done: bool) {
            let l = &mut self.lines[id as usize];
            assert!(!l.1, "line {id} heard after it ended");
            (l.0, l.1) = (text.into(), done);
        }
        fn translated(&mut self, id: u64, text: &str, done: bool) {
            let l = &mut self.lines[id as usize];
            assert!(!l.3, "line {id} translated after its translation was complete");
            (l.2, l.3) = (text.into(), done);
        }
        fn drop_line(&mut self, id: u64) {
            self.dropped.push(id);
        }
    }

    fn ms(t0: Instant, n: u64) -> Instant {
        t0 + Duration::from_millis(n)
    }

    #[test]
    fn a_sentence_and_its_translation_make_one_line() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("Welcome to", ms(t0, 0), &mut s);
        i.heard(" the panel.", ms(t0, 300), &mut s);
        assert_eq!(s.lines[0], ("Welcome to the panel.".into(), false, String::new(), false), "gray while it may go on");
        i.translated("歡迎來到", ms(t0, 600), &mut s);
        assert_eq!(s.lines[0].2, "歡迎來到");
        i.tick(ms(t0, 1400), &mut s);
        assert!(s.lines[0].1, "the pause ended the line");
        i.translated("座談會。", ms(t0, 1500), &mut s);
        assert_eq!(s.lines[0], ("Welcome to the panel.".into(), true, "歡迎來到座談會。".into(), true));
        assert!(i.idle());
    }

    #[test]
    fn chinese_that_runs_into_the_next_line_is_split_at_the_sentence_end() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("I am the moderator.", ms(t0, 0), &mut s);
        i.tick(ms(t0, 1100), &mut s);
        i.heard("Our first panelist is here.", ms(t0, 1300), &mut s);
        i.translated("我是主持人。我們的第一位", ms(t0, 1500), &mut s);
        assert_eq!(s.lines[0].2, "我是主持人。");
        assert!(s.lines[0].3);
        assert_eq!(s.lines[1].2, "我們的第一位");
        assert!(!s.lines[1].3);
        i.tick(ms(t0, 2400), &mut s);
        i.translated("與談人到了。", ms(t0, 2500), &mut s);
        assert_eq!(s.lines[1], ("Our first panelist is here.".into(), true, "我們的第一位與談人到了。".into(), true));
    }

    #[test]
    fn long_unbroken_speech_is_cut_at_a_sentence_end() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        let long = "The library decided to move the whole collection to open formats by March next year, and the board agreed to it.";
        i.heard(long, ms(t0, 0), &mut s);
        assert!(!s.lines[0].1, "short of SPLIT_CHARS");
        i.heard(" Then we", ms(t0, 100), &mut s);
        i.heard(" talked about storage costs for the archive after the grant ends.", ms(t0, 200), &mut s);
        assert!(s.lines[0].1, "a sentence end past SPLIT_CHARS ends the line");
        i.heard(" Next", ms(t0, 300), &mut s);
        assert_eq!(s.lines.len(), 2);
        assert_eq!(s.lines[1].0, "Next");
    }

    #[test]
    fn a_line_with_no_translation_ends_after_a_while() {
        // Speech already in Chinese: Live Translate stays silent (echoTargetLanguage false).
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("大家好。", ms(t0, 0), &mut s);
        i.tick(ms(t0, 1000), &mut s);
        assert!(s.lines[0].1);
        i.tick(ms(t0, 3500), &mut s);
        assert!(!s.lines[0].3, "still waiting");
        i.tick(ms(t0, 4000), &mut s);
        assert_eq!(s.lines[0], ("大家好。".into(), true, String::new(), true));
        assert!(i.idle());
    }

    #[test]
    fn joined_sentences_do_not_swallow_the_next_line() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("Thanks. We start now with the first talk.", ms(t0, 0), &mut s);
        i.tick(ms(t0, 1000), &mut s);
        i.translated("謝謝，我們現在開始第一場演講。", ms(t0, 1200), &mut s);
        assert!(!s.lines[0].3, "two sentences heard, one translated, and nothing after it yet");
        i.heard("Over to you.", ms(t0, 1300), &mut s);
        i.tick(ms(t0, 2300), &mut s);
        assert!(s.lines[0].3, "the next line ended: a whole sentence of plausible length completes the first");
        i.translated("交給你。", ms(t0, 2400), &mut s);
        assert_eq!(s.lines[0].2, "謝謝，我們現在開始第一場演講。");
        assert_eq!(s.lines[1], ("Over to you.".into(), true, "交給你。".into(), true));
        // The same when both lines' Chinese comes in one piece.
        let (t1, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("Thanks. We start now with the first talk.", ms(t1, 0), &mut s);
        i.tick(ms(t1, 1000), &mut s);
        i.heard("Over to you.", ms(t1, 1100), &mut s);
        i.tick(ms(t1, 2100), &mut s);
        i.translated("謝謝，我們現在開始第一場演講。交給你。", ms(t1, 2200), &mut s);
        assert_eq!(s.lines[0].2, "謝謝，我們現在開始第一場演講。");
        assert_eq!(s.lines[1].2, "交給你。");
        assert!(s.lines[0].3 && s.lines[1].3);
    }

    #[test]
    fn cumulative_text_is_not_doubled() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("Hello", ms(t0, 0), &mut s);
        i.heard("Hello everyone", ms(t0, 100), &mut s);
        assert_eq!(s.lines[0].0, "Hello everyone");
        i.heard(" again", ms(t0, 200), &mut s);
        assert_eq!(s.lines[0].0, "Hello everyone again");
        i.heard(" again", ms(t0, 300), &mut s);
        assert_eq!(s.lines[0].0, "Hello everyone again again", "a repeated word is a piece, not the text so far");
    }

    #[test]
    fn the_session_ending_ends_every_line() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("We will", ms(t0, 0), &mut s);
        i.translated("我們會", ms(t0, 100), &mut s);
        i.flush(&mut s);
        assert_eq!(s.lines[0], ("We will".into(), true, "我們會".into(), true));
        assert!(i.idle());
        // Chinese with nothing heard first still gets a line.
        i.translated("好。", ms(t0, 200), &mut s);
        assert_eq!(s.lines[1].2, "好。");
        assert!(s.lines[1].3);
    }
}
