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
//   - Chinese that arrives with no line waiting is added to the line just completed when it is
//     that recent (ORPHAN_LATE): one sentence heard can come back as two in Chinese.
// Following another recognizer (Live Translate chosen under 翻): the lines are the recognizer's
// (captions.rs reports each line opened, ended or dropped) and Live Translate, hearing the same
// audio, only supplies the Chinese, paired the same way. Chinese with no line waiting that is not
// that recent is kept for the next line. A line Live Translate brings no Chinese for goes to the
// text model rather than end with none. While Live Translate is disconnected (pause, resume),
// lines that end go to the text model, and so do the lines being spoken when it went: the Chinese
// for their start will not come. Should Live Translate stop (a refused connection), captions go
// back to the text model for good. Each run of 聽 with Live Translate has a number (follow_on): a
// run that has been replaced by a newer one finds a different number and leaves the newer run's
// pairing alone.
// Nothing here talks to the network or the screen: a Sink receives the lines, so the pairing is
// tested on its own (tests below).

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager};

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
/// Chinese this soon after a line's translation completed, with no line waiting, still belongs to it.
const ORPHAN_LATE: Duration = Duration::from_millis(1500);

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
    /// Following: a line Live Translate brought no Chinese for, with what was said on it; the text
    /// model translates it.
    fn untranslated(&mut self, id: u64, heard: &str);
}

struct Line {
    id: u64,
    en: String,
    zh: String,
    /// When what was said on it ended.
    ended: Option<Instant>,
    /// Following: the text model translates this line (Live Translate missed the start of it). It
    /// still takes the Chinese meant for it, so that Chinese does not land under the next line.
    skip: bool,
}

#[derive(Default)]
pub struct Interp {
    /// Lines still being spoken or translated, oldest first.
    lines: VecDeque<Line>,
    last_in: Option<Instant>,
    last_out: Option<Instant>,
    /// The lines are another recognizer's (open_line, end_line, remove_line); only Chinese comes here.
    following: bool,
    /// Chinese that came with no line waiting for it.
    orphan: String,
    /// The line whose translation completed last: id, its Chinese, when.
    last_done: Option<(u64, String, Instant)>,
    /// Following, while Live Translate is disconnected: lines go to the text model.
    away: bool,
}

impl Interp {
    /// Pairing for lines another recognizer makes.
    pub fn following() -> Self {
        Interp { following: true, ..Default::default() }
    }

    /// The recognizer opened a line.
    pub fn open_line(&mut self, id: u64) {
        let zh = std::mem::take(&mut self.orphan);
        self.lines.push_back(Line { id, en: String::new(), zh, ended: None, skip: self.away });
    }

    /// The recognizer's line ended with `text`. False when the Chinese for it will not come from
    /// here (the caller has the text model translate it): a line opened before this pairing began,
    /// or while Live Translate is disconnected, or one it missed the start of.
    pub fn end_line(&mut self, id: u64, text: &str, now: Instant, sink: &mut impl Sink) -> bool {
        let Some(at) = self.lines.iter().position(|l| l.id == id) else { return false };
        if self.away {
            // No Chinese is coming for it: its sound was not sent.
            self.lines.remove(at);
            return false;
        }
        let line = &mut self.lines[at];
        line.en = text.to_string();
        line.ended = Some(now);
        let taken = !line.skip;
        self.release(now, sink);
        taken
    }

    /// The recognizer dropped a line: Chinese it had goes on to the next.
    pub fn remove_line(&mut self, id: u64) {
        let Some(at) = self.lines.iter().position(|l| l.id == id) else { return };
        let gone = self.lines.remove(at).expect("position is in range");
        if gone.zh.is_empty() {
            return;
        }
        match self.lines.get_mut(at) {
            Some(next) => next.zh.insert_str(0, &gone.zh),
            None => self.orphan.insert_str(0, &gone.zh),
        }
    }

    /// A piece of what was said.
    pub fn heard(&mut self, piece: &str, now: Instant, sink: &mut impl Sink) {
        if piece.trim().is_empty() {
            return;
        }
        self.last_in = Some(now);
        if self.lines.back().is_none_or(|l| l.ended.is_some()) {
            let id = sink.open();
            self.lines.push_back(Line { id, en: String::new(), zh: String::new(), ended: None, skip: false });
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
            self.release(now, sink);
            if self.lines.is_empty() {
                // The rest of the line just completed ("Right, let's start." as 對。我們開始吧。).
                if let Some((id, zh, at)) = self.last_done.as_mut().filter(|(_, _, at)| now.duration_since(*at) < ORPHAN_LATE) {
                    zh.push_str(rest);
                    *at = now;
                    sink.translated(*id, zh.trim(), true);
                    return;
                }
            }
            if self.lines.is_empty() && self.following {
                self.orphan.push_str(rest);
                return;
            }
            if self.lines.is_empty() {
                // Chinese with nothing heard before it: a line of its own.
                let id = sink.open();
                self.lines.push_back(Line { id, en: String::new(), zh: String::new(), ended: Some(now), skip: false });
            }
            // Feed up to and including the next sentence end, then see whether the line is complete.
            let cut = rest.char_indices().find(|(_, c)| is_zh_end(*c)).map_or(rest.len(), |(i, c)| i + c.len_utf8());
            let (head, tail) = rest.split_at(cut);
            rest = tail;
            let next_ended = self.lines.get(1).is_some_and(|l| l.ended.is_some());
            let line = self.lines.front_mut().expect("a line was just ensured");
            grow(&mut line.zh, head);
            if translation_complete(line, next_ended) {
                let line = self.lines.pop_front().expect("front exists");
                self.complete(line, now, sink);
            } else if !line.skip {
                sink.translated(line.id, line.zh.trim(), false);
            }
        }
    }

    /// Lines at the front whose translation is complete leave.
    fn release(&mut self, now: Instant, sink: &mut impl Sink) {
        while let Some(line) = self.lines.front() {
            let next_ended = self.lines.get(1).is_some_and(|l| l.ended.is_some());
            if !translation_complete(line, next_ended) {
                break;
            }
            let line = self.lines.pop_front().expect("front exists");
            self.complete(line, now, sink);
        }
    }

    /// A line's translation ends as it stands. Following, a line with no Chinese goes to the text
    /// model, and one the text model already has only gave up the Chinese meant for it. A line of
    /// this module's own (Chinese with nothing heard before it) ends there, or goes if it is empty.
    fn complete(&mut self, line: Line, now: Instant, sink: &mut impl Sink) {
        if line.skip {
            return;
        }
        let zh = line.zh.trim().to_string();
        if self.following && zh.is_empty() {
            sink.untranslated(line.id, line.en.trim());
            return;
        }
        if !self.following && line.en.trim().is_empty() {
            if zh.is_empty() {
                sink.drop_line(line.id);
                return;
            }
            // Nothing heard will come to it: it ends, not left gray.
            sink.heard(line.id, "", true);
        }
        sink.translated(line.id, &zh, true);
        self.last_done = Some((line.id, zh, now));
    }

    /// Time passes: pauses end lines and their translations.
    pub fn tick(&mut self, now: Instant, sink: &mut impl Sink) {
        if let Some(line) = self.lines.back_mut().filter(|l| l.ended.is_none() && !self.following) {
            if self.last_in.is_some_and(|t| now.duration_since(t) >= IN_QUIET) {
                line.ended = Some(now);
                sink.heard(line.id, line.en.trim(), true);
            }
        }
        self.release(now, sink);
        while let Some(line) = self.lines.front() {
            let Some(ended) = line.ended else { break };
            let since = self.last_out.map_or(ended, |o| o.max(ended));
            if now.duration_since(since) < ZH_QUIET {
                break;
            }
            let line = self.lines.pop_front().expect("front exists");
            self.complete(line, now, sink);
        }
    }

    /// The session ended: every line ends as it stands. Following, lines still being spoken stay
    /// (the next session's Chinese, or the text model, will translate them).
    pub fn flush(&mut self, sink: &mut impl Sink) {
        let now = Instant::now();
        let mut speaking = VecDeque::new();
        while let Some(mut line) = self.lines.pop_front() {
            if line.ended.is_none() {
                if self.following {
                    speaking.push_back(line);
                    continue;
                }
                line.ended = Some(now);
                if !line.en.trim().is_empty() {
                    sink.heard(line.id, line.en.trim(), true);
                }
            }
            self.complete(line, now, sink);
        }
        self.lines = speaking;
        self.orphan.clear();
    }

    /// Following: Live Translate lost its connection. Lines that ended keep the Chinese they have
    /// (or go to the text model), the lines being spoken will be the text model's, and so will
    /// every line that ends until it is back (resume).
    pub fn pause(&mut self, sink: &mut impl Sink) {
        self.flush(sink);
        for line in &mut self.lines {
            line.skip = true;
        }
        self.last_done = None;
        self.away = true;
    }

    /// Following: Live Translate is connected again, hearing what is said from now on.
    pub fn resume(&mut self) {
        self.away = false;
    }

    /// Following: is Live Translate disconnected?
    pub fn away(&self) -> bool {
        self.away
    }

    /// Nothing is being spoken or translated.
    pub fn idle(&self) -> bool {
        self.lines.is_empty()
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

    /// Never called: only following lines go to the text model.
    fn untranslated(&mut self, id: u64, _: &str) {
        captions::set_translation(self.0, id, "", true);
    }
}

/// Live Translate following the 聽 recognizer: which run of it this is, and the pairing while it
/// runs (None otherwise).
#[derive(Default)]
pub struct Following(Mutex<Slot>);

#[derive(Default)]
struct Slot {
    run: u64,
    interp: Option<Interp>,
}

fn with_following(app: &AppHandle, f: impl FnOnce(&mut Interp, &mut TranslationSink)) {
    let state = app.state::<Following>();
    let Ok(mut g) = state.0.lock() else { return };
    if let Some(interp) = g.interp.as_mut() {
        f(interp, &mut TranslationSink(app));
    }
}

/// The same, only for run `run` (Live Translate's own calls: an earlier run still winding down
/// must not touch the pairing of the run that replaced it).
fn with_run(app: &AppHandle, run: u64, f: impl FnOnce(&mut Interp, &mut TranslationSink)) {
    let state = app.state::<Following>();
    let Ok(mut g) = state.0.lock() else { return };
    if g.run != run {
        return;
    }
    if let Some(interp) = g.interp.as_mut() {
        f(interp, &mut TranslationSink(app));
    }
}

/// Live Translate starts supplying the captions' Chinese; returns the run's number, which its
/// calls below carry. A run still winding down hands over: lines that ended keep what they have.
pub fn follow_on(app: &AppHandle) -> u64 {
    let state = app.state::<Following>();
    let (run, earlier) = {
        let Ok(mut g) = state.0.lock() else { return 0 };
        g.run += 1;
        let earlier = g.interp.replace(Interp::following());
        (g.run, earlier)
    };
    if let Some(mut interp) = earlier {
        interp.flush(&mut TranslationSink(app));
    }
    run
}

/// Run `run` stopped: lines already ended keep what they have; later lines go to the text model.
pub fn follow_off(app: &AppHandle, run: u64) {
    let taken = app.state::<Following>().0.lock().ok().and_then(|mut g| if g.run == run { g.interp.take() } else { None });
    if let Some(mut interp) = taken {
        interp.flush(&mut TranslationSink(app));
    }
}

/// Run `run` lost its connection: the text model translates until it is back.
pub fn follow_pause(app: &AppHandle, run: u64) {
    with_run(app, run, |i, sink| i.pause(sink));
}

/// Run `run` is connected again.
pub fn follow_resume(app: &AppHandle, run: u64) {
    with_run(app, run, |i, _| i.resume());
}

/// Is Live Translate supplying the captions' Chinese (running and connected)?
pub fn following(app: &AppHandle) -> bool {
    app.state::<Following>().0.lock().is_ok_and(|g| g.interp.as_ref().is_some_and(|i| !i.away()))
}

pub fn line_opened(app: &AppHandle, id: u64) {
    with_following(app, |i, _| i.open_line(id));
}

/// True when Live Translate brings this line's Chinese; false: the text model should translate it.
pub fn line_ended(app: &AppHandle, id: u64, text: &str) -> bool {
    let mut taken = false;
    with_following(app, |i, sink| taken = i.end_line(id, text, Instant::now(), sink));
    taken
}

pub fn line_dropped(app: &AppHandle, id: u64) {
    with_following(app, |i, _| i.remove_line(id));
}

/// A piece of run `run`'s Chinese.
pub fn follow_translated(app: &AppHandle, run: u64, piece: &str) {
    with_run(app, run, |i, sink| i.translated(piece, Instant::now(), sink));
}

pub fn follow_tick(app: &AppHandle, run: u64) {
    with_run(app, run, |i, sink| i.tick(Instant::now(), sink));
}

/// A Live Translate session of run `run` ended (it is replaced): lines that ended keep what they have.
pub fn follow_flush(app: &AppHandle, run: u64) {
    with_run(app, run, |i, sink| i.flush(sink));
}

/// Nothing is waiting for run `run`'s Chinese.
pub fn follow_idle(app: &AppHandle, run: u64) -> bool {
    app.state::<Following>().0.lock().map_or(true, |g| g.run != run || g.interp.as_ref().is_none_or(Interp::idle))
}

/// Chinese onto the recognizer's lines (they show and keep their own text).
pub struct TranslationSink<'a>(pub &'a AppHandle);

impl Sink for TranslationSink<'_> {
    /// Never called: following, lines are only opened by the recognizer (and captions::open would
    /// take the Following lock this runs under).
    fn open(&mut self) -> u64 {
        0
    }

    fn heard(&mut self, _: u64, _: &str, _: bool) {}

    fn translated(&mut self, id: u64, text: &str, done: bool) {
        captions::set_translation(self.0, id, &zh::to_taiwan(text), done);
    }

    fn drop_line(&mut self, _: u64) {}

    fn untranslated(&mut self, id: u64, heard: &str) {
        captions::translate_with_text_model(self.0, id, heard);
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
        /// Lines handed to the text model, with what was said on them.
        to_text_model: Vec<(u64, String)>,
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
            // Late Chinese may extend a complete line, never reopen it.
            assert!(!l.3 || done, "line {id} reopened after its translation was complete");
            (l.2, l.3) = (text.into(), done);
        }
        fn drop_line(&mut self, id: u64) {
            self.dropped.push(id);
        }
        fn untranslated(&mut self, id: u64, heard: &str) {
            assert!(!self.lines[id as usize].3, "line {id} already had its translation");
            self.to_text_model.push((id, heard.into()));
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
    fn following_another_recognizer_only_the_chinese_comes_from_here() {
        let (t0, mut s) = (Instant::now(), Screen::default());
        let mut i = Interp::following();
        let a = s.open();
        i.open_line(a);
        i.translated("歡迎來到", ms(t0, 500), &mut s);
        i.tick(ms(t0, 3000), &mut s);
        assert_eq!(s.lines[0], (String::new(), false, "歡迎來到".into(), false), "the recognizer ends lines, not pauses here");
        i.end_line(a, "Welcome to the panel.", ms(t0, 3100), &mut s);
        i.translated("座談會。", ms(t0, 3200), &mut s);
        assert_eq!(s.lines[0], (String::new(), false, "歡迎來到座談會。".into(), true));
        // Late Chinese with no line waiting joins the line just completed.
        i.translated("各位好。", ms(t0, 3600), &mut s);
        assert_eq!(s.lines[0].2, "歡迎來到座談會。各位好。");
        // Later, it waits for the next line.
        i.translated("今天", ms(t0, 6000), &mut s);
        let b = s.open();
        i.open_line(b);
        i.translated("談數位典藏。", ms(t0, 6200), &mut s);
        assert_eq!(s.lines[1].2, "今天談數位典藏。");
        assert!(!s.lines[1].3, "not before the recognizer ends the line");
        i.end_line(b, "Today it is digital archives.", ms(t0, 6500), &mut s);
        assert!(s.lines[1].3);
        assert!(i.idle());
    }

    #[test]
    fn a_dropped_line_hands_its_chinese_on() {
        let (t0, mut s) = (Instant::now(), Screen::default());
        let mut i = Interp::following();
        let (a, b) = (s.open(), s.open());
        i.open_line(a);
        i.translated("我們", ms(t0, 100), &mut s);
        i.open_line(b);
        i.remove_line(a);
        i.translated("開始吧。", ms(t0, 200), &mut s);
        i.end_line(b, "Let's start.", ms(t0, 300), &mut s);
        assert_eq!(s.lines[1].2, "我們開始吧。");
        assert!(s.lines[1].3);
    }

    #[test]
    fn following_a_session_ending_keeps_lines_still_being_spoken() {
        let (t0, mut s) = (Instant::now(), Screen::default());
        let mut i = Interp::following();
        let (a, b) = (s.open(), s.open());
        i.open_line(a);
        i.end_line(a, "First.", ms(t0, 0), &mut s);
        i.open_line(b);
        i.flush(&mut s);
        assert_eq!(s.to_text_model, vec![(a, "First.".to_string())], "the ended line had no Chinese: the text model translates it");
        assert!(!i.idle(), "the line still being spoken waits for the next session");
        i.translated("第二句。", ms(t0, 5000), &mut s);
        i.end_line(b, "Second.", ms(t0, 5100), &mut s);
        assert_eq!(s.lines[1].2, "第二句。");
        assert!(s.lines[1].3);
    }

    #[test]
    fn the_session_ending_ends_every_line() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("We will", ms(t0, 0), &mut s);
        i.translated("我們會", ms(t0, 100), &mut s);
        i.flush(&mut s);
        assert_eq!(s.lines[0], ("We will".into(), true, "我們會".into(), true));
        assert!(i.idle());
        // Chinese with nothing heard first, long after: a line of its own, ended.
        i.translated("好。", ms(t0, 5000), &mut s);
        assert_eq!(s.lines[1], (String::new(), true, "好。".into(), true));
    }

    #[test]
    fn one_sentence_heard_two_in_chinese_stay_one_line() {
        let (t0, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("Right, let's start.", ms(t0, 0), &mut s);
        i.tick(ms(t0, 1000), &mut s);
        i.translated("對。我們開始吧。", ms(t0, 1200), &mut s);
        assert_eq!(s.lines.len(), 1, "no line of its own for the second sentence");
        assert_eq!(s.lines[0], ("Right, let's start.".into(), true, "對。我們開始吧。".into(), true));
        // The same when the two sentences come in pieces.
        let (t1, mut i, mut s) = (Instant::now(), Interp::default(), Screen::default());
        i.heard("Right, let's start.", ms(t1, 0), &mut s);
        i.tick(ms(t1, 1000), &mut s);
        i.translated("對。", ms(t1, 1200), &mut s);
        i.translated("我們開始", ms(t1, 1400), &mut s);
        i.translated("吧。", ms(t1, 1500), &mut s);
        assert_eq!(s.lines.len(), 1);
        assert_eq!(s.lines[0], ("Right, let's start.".into(), true, "對。我們開始吧。".into(), true));
        i.tick(ms(t1, 9000), &mut s);
        assert!(i.idle());
    }

    #[test]
    fn following_a_line_with_no_chinese_goes_to_the_text_model() {
        let (t0, mut s) = (Instant::now(), Screen::default());
        let mut i = Interp::following();
        let a = s.open();
        i.open_line(a);
        assert!(i.end_line(a, "Thanks.", ms(t0, 0), &mut s));
        i.tick(ms(t0, 3500), &mut s);
        assert_eq!(s.to_text_model, vec![(a, "Thanks.".to_string())]);
        assert!(!s.lines[0].3, "not completed with no Chinese");
        assert!(i.idle());
        // A session ending (rotated) hands its ended lines with no Chinese on the same way.
        let b = s.open();
        i.open_line(b);
        i.end_line(b, "Next.", ms(t0, 4000), &mut s);
        i.flush(&mut s);
        assert_eq!(s.to_text_model[1], (b, "Next.".to_string()));
        // A line opened before the pairing began is not taken.
        assert!(!i.end_line(99, "Earlier.", ms(t0, 5000), &mut s));
    }

    #[test]
    fn following_while_disconnected_the_text_model_translates() {
        let (t0, mut s) = (Instant::now(), Screen::default());
        let mut i = Interp::following();
        let (a, b) = (s.open(), s.open());
        i.open_line(a);
        i.translated("歡迎", ms(t0, 100), &mut s);
        i.end_line(a, "Welcome.", ms(t0, 200), &mut s);
        i.open_line(b);
        // The connection drops: the ended line keeps what it has, the one being spoken is the text model's.
        i.pause(&mut s);
        assert_eq!(s.lines[a as usize], (String::new(), false, "歡迎".into(), true));
        assert!(i.away());
        let c = s.open();
        i.open_line(c);
        assert!(!i.end_line(c, "Said while it was away.", ms(t0, 1000), &mut s), "the text model translates it");
        // Back: the line spoken across the gap is the text model's, yet takes the Chinese of its tail.
        i.resume();
        let d = s.open();
        i.open_line(d);
        i.translated("那件事。", ms(t0, 2000), &mut s);
        assert!(!i.end_line(b, "And about that matter.", ms(t0, 2100), &mut s));
        i.translated("下一句。", ms(t0, 2300), &mut s);
        assert!(i.end_line(d, "Next sentence.", ms(t0, 2400), &mut s));
        assert_eq!(s.lines[b as usize].2, "", "the tail's Chinese did not land under it");
        assert_eq!(s.lines[d as usize], (String::new(), false, "下一句。".into(), true), "nor under the next line");
        assert!(s.to_text_model.is_empty(), "the caller sends lines not taken to the text model");
        assert!(i.idle());
    }
}
