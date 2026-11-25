// What each service costs, and what was used: list prices (USD, checked 2026-10-17 on the providers'
// pricing pages, as in the first version's catalog; Claude rates checked 2026-11-03), audio seconds for speech recognition billed by
// the minute, tokens for text models. Apple, Gemma and a local server cost nothing.

import Foundation

public struct Tokens: Codable, Equatable, Sendable {
    /// Input not read from a cache.
    public var input = 0
    public var cached = 0
    public var output = 0

    public init(input: Int = 0, cached: Int = 0, output: Int = 0) {
        self.input = input
        self.cached = cached
        self.output = output
    }

    /// Streams report usage piece by piece; the largest of each is the total.
    public mutating func merge(_ t: Tokens) {
        input = max(input, t.input)
        cached = max(cached, t.cached)
        output = max(output, t.output)
    }
}

public enum Price: Equatable, Sendable {
    case perMinute(Double)
    case perMillionTokens(input: Double, cached: Double, output: Double)
    case free
}

public enum Pricing {
    public static func price(_ model: String) -> Price {
        switch model {
        case "gemini-live": .perMinute(0.009)
        case "gemini-live-translate": .perMinute(0.0368)
        case "gemini-transcribe": .perMinute(0.005)
        case "openai-live": .perMinute(0.017)
        case "openai-mini": .perMinute(0.003)
        case "claude-haiku-5-5": .perMillionTokens(input: 0.10, cached: 0.01, output: 0.50)
        case "claude-sonnet-5-5": .perMillionTokens(input: 2.00, cached: 0.10, output: 10.00)
        case "claude-opus-5-5": .perMillionTokens(input: 4.00, cached: 0.20, output: 20.00)
        case "claude-fable-5-2": .perMillionTokens(input: 8.00, cached: 0.20, output: 40.00)
        case "gpt-6-luna": .perMillionTokens(input: 0.10, cached: 0.01, output: 0.50)
        case "gpt-6.1-sol": .perMillionTokens(input: 2.00, cached: 0.10, output: 10.00)
        case "gemini-3.5-flash-lite": .perMillionTokens(input: 0.30, cached: 0.03, output: 2.50)
        case "gemini-3.8-flash": .perMillionTokens(input: 0.75, cached: 0.075, output: 3.75)
        default: .free
        }
    }
}

public struct UsageTally: Codable, Equatable, Sendable {
    public var audioSeconds = 0.0
    public var tokens = Tokens()
    public var requests = 0

    public init() {}

    public func cost(_ model: String) -> Double {
        switch Pricing.price(model) {
        case .perMinute(let usd): usd * audioSeconds / 60
        case let .perMillionTokens(i, c, o): (Double(tokens.input) * i + Double(tokens.cached) * c + Double(tokens.output) * o) / 1_000_000
        case .free: 0
        }
    }
}

/// Usage per model.
public struct UsageBook: Codable, Equatable, Sendable {
    public private(set) var models: [String: UsageTally] = [:]

    public init() {}

    public mutating func addAudio(_ model: String, seconds: Double) {
        models[model, default: UsageTally()].audioSeconds += seconds
    }

    public mutating func addTokens(_ model: String, _ t: Tokens) {
        var tally = models[model, default: UsageTally()]
        tally.tokens.input += t.input
        tally.tokens.cached += t.cached
        tally.tokens.output += t.output
        tally.requests += 1
        models[model] = tally
    }

    public var total: Double {
        models.reduce(0) { $0 + $1.value.cost($1.key) }
    }

    /// "2026-11": the month a record belongs to, a Gregorian one whatever calendar the Mac shows.
    public static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let c = SessionFiles.gregorian(calendar).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

public enum Version {
    /// Whether a release tag ("mac-v0.6.0", "v0.6", "0.6.1") is newer than `local` ("0.5.0").
    public static func isNewer(_ tag: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let digits = s.drop { !$0.isNumber }
            return digits.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (a, b) = (parts(tag), parts(local))
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}
