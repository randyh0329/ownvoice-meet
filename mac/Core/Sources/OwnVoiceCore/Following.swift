// Live Translate following another recognizer (chosen under Translation): which run of it this is,
// and the pairing (Interpreter, following) while it runs. Each start of listening with Live
// Translate is a run with a number (on): a run that has been replaced by a newer one finds a
// different number and leaves the newer run's pairing alone. The caption side (lines opened, ended,
// dropped) speaks to whichever run is current; Live Translate's own calls carry their run's number.
// Should Live Translate stop for good (off, or a refused connection), lines go back to the text
// model: lineEnded answers false.

import Foundation

public struct LiveTranslateFollowing {
    /// The number of the latest run.
    public private(set) var run = 0
    /// The pairing while a run is on.
    private var interpreter: Interpreter?

    public init() {}

    /// Live Translate starts supplying the captions' Chinese; returns the run's number, which its
    /// calls below carry. A run still winding down hands over: lines that ended keep what they have.
    public mutating func on(sink: InterpreterSink) -> Int {
        run += 1
        var earlier = interpreter
        interpreter = Interpreter(following: true)
        earlier?.flush(sink: sink)
        return run
    }

    /// Run `run` stopped: lines already ended keep what they have; later lines go to the text model.
    public mutating func off(run: Int, sink: InterpreterSink) {
        guard run == self.run, var taken = interpreter else { return }
        interpreter = nil
        taken.flush(sink: sink)
    }

    /// Run `run` lost its connection: the text model translates until it is back.
    public mutating func pause(run: Int, sink: InterpreterSink) {
        guard run == self.run else { return }
        interpreter?.pause(sink: sink)
    }

    /// Run `run` is connected again.
    public mutating func resume(run: Int) {
        guard run == self.run else { return }
        interpreter?.resume()
    }

    /// Is Live Translate supplying the captions' Chinese (running and connected)?
    public var following: Bool {
        interpreter.map { !$0.away } ?? false
    }

    // The caption side: the current run, whichever it is.

    public mutating func lineOpened(_ id: Int) {
        interpreter?.openLine(id)
    }

    /// True when Live Translate brings this line's Chinese; false: the text model should translate it.
    public mutating func lineEnded(_ id: Int, _ text: String, now: Date, sink: InterpreterSink) -> Bool {
        interpreter?.endLine(id, text, now: now, sink: sink) ?? false
    }

    public mutating func lineDropped(_ id: Int) {
        interpreter?.removeLine(id)
    }

    // Live Translate's side: only for its own run.

    /// A piece of run `run`'s Chinese.
    public mutating func translated(run: Int, _ piece: String, now: Date, sink: InterpreterSink) {
        guard run == self.run else { return }
        interpreter?.translated(piece, now: now, sink: sink)
    }

    public mutating func tick(run: Int, now: Date, sink: InterpreterSink) {
        guard run == self.run else { return }
        interpreter?.tick(now: now, sink: sink)
    }

    /// A Live Translate session of run `run` ended (it is replaced): lines that ended keep what they have.
    public mutating func flush(run: Int, sink: InterpreterSink) {
        guard run == self.run else { return }
        interpreter?.flush(sink: sink)
    }

    /// Nothing is waiting for run `run`'s Chinese: a good moment to replace its session.
    public func idle(run: Int) -> Bool {
        run != self.run || (interpreter?.idle ?? true)
    }
}
