// Sign in with ChatGPT (OpenAI, preview since 2026-10): the user's ChatGPT plan (Go, Plus, Pro or
// Business) pays for text requests instead of an API key. Only the Responses API is open to it: no
// transcription or audio, so it can stand in for the translation key, not the speech one.
//
// The same protocol as the first version (src-tauri/src/chatgpt.rs), from OpenAI's documentation at
// developers.openai.com/siwc/token-sharing-open-source: OAuth 2 authorization code with PKCE S256,
// a loopback callback on 127.0.0.1 (any free port, path /auth/callback), dynamic client
// registration through client_id=dynamic_agent_client, the issued client id kept for next time.
//
// Here are the pieces that are plain logic: the addresses, the sign-in and token requests, reading
// the browser's return, the Responses request, and what a refusal means. The app does the
// listening, the browser and the Keychain (ChatGPTSignIn.swift); the stream is read by
// StreamedReply's .responses format (Streaming.swift).

import Foundation

public enum ChatGPTPlan {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// The scope that lets requests draw on the ChatGPT plan; an ID token alone does not.
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let callbackPath = "/auth/callback"
    public static let dynamicClient = "dynamic_agent_client"
    public static let agentName = "OwnVoice Meet"
    public static let discoveryURL = URL(string: issuer + "/.well-known/openid-configuration")!
    public static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    /// How long the browser has to come back.
    public static let signInTimeout: TimeInterval = 300

    /// A ChatGPT connection, kept in the Keychain (never in a file, never shown).
    public struct Connection: Codable, Equatable, Sendable {
        public var clientID: String
        public var access: String
        public var refresh: String
        public var expiresAt: Date
        public var scopes: [String]
        /// The account's email, to show which account is connected.
        public var email: String

        public init(clientID: String, access: String, refresh: String, expiresAt: Date, scopes: [String], email: String) {
            self.clientID = clientID
            self.access = access
            self.refresh = refresh
            self.expiresAt = expiresAt
            self.scopes = scopes
            self.email = email
        }

        /// Whether the user agreed to let requests use the plan.
        public var planAllowed: Bool { scopes.contains(ChatGPTPlan.planScope) }

        /// About to expire (within a minute): refresh before using it.
        public func isExpired(now: Date = Date()) -> Bool {
            now.addingTimeInterval(60) >= expiresAt
        }
    }

    // MARK: Sign-in

    /// The authorization and token endpoints from the issuer's discovery document; both must be
    /// on the issuer itself.
    public static func endpoints(_ data: Data) throws -> (authorize: URL, token: URL) {
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let auth = v["authorization_endpoint"] as? String, let token = v["token_endpoint"] as? String else {
            throw ServiceError("discovery: no endpoints")
        }
        for u in [auth, token] where !u.hasPrefix(issuer) {
            throw ServiceError("discovery: unexpected endpoint \(u)")
        }
        guard let a = URL(string: auth), let t = URL(string: token) else { throw ServiceError("discovery: bad endpoint") }
        return (a, t)
    }

    /// The loopback address the browser comes back to.
    public static func redirect(port: UInt16) -> String {
        "http://127.0.0.1:" + String(port) + callbackPath
    }

    /// The browser's sign-in address. `clientID` is the one issued last time, if any; without it
    /// the app registers itself under its name.
    public static func authorizeURL(endpoint: URL, clientID: String?, redirect: String, state: String, nonce: String, challenge: String) -> URL {
        var pairs = [
            ("client_id", clientID ?? dynamicClient),
            ("response_type", "code"),
            ("redirect_uri", redirect),
            ("scope", scopes),
            ("resource", resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
        ]
        if clientID == nil { pairs.append(("agent_name_hint", agentName)) }
        let base = endpoint.absoluteString
        return URL(string: base + (base.contains("?") ? "&" : "?") + form(pairs))!
    }

    /// The code from the browser, exchanged for tokens (a form body for the token endpoint).
    public static func codeExchange(clientID: String, code: String, verifier: String, redirect: String) -> Data {
        Data(form([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect),
            ("resource", resource),
        ]).utf8)
    }

    /// A fresh access token for a saved connection (a form body for the token endpoint).
    public static func refreshRequest(_ c: Connection) -> Data {
        Data(form([("grant_type", "refresh_token"), ("client_id", c.clientID), ("refresh_token", c.refresh), ("resource", resource)]).utf8)
    }

    /// The token endpoint's answer as a connection; what it leaves out (a refresh can) is kept from
    /// `previous`.
    public static func connection(tokenResponse data: Data, clientID: String, previous: Connection? = nil, now: Date = Date()) throws -> Connection {
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = v["access_token"] as? String else { throw ServiceError("no access_token") }
        let scopes = (v["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        let seconds = (v["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let email = (v["id_token"] as? String).flatMap { idClaims($0)["email"] as? String } ?? previous?.email ?? ""
        return Connection(
            clientID: clientID,
            access: access,
            refresh: v["refresh_token"] as? String ?? previous?.refresh ?? "",
            expiresAt: now.addingTimeInterval(seconds),
            scopes: scopes,
            email: email
        )
    }

    /// The ID token's claims, read for the nonce and the email shown in Settings. The access token
    /// is what OpenAI checks on every request, so nothing here is trusted for access.
    public static func idClaims(_ idToken: String) -> [String: Any] {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return [:] }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// A refused token request: its status and the service's own words.
    public static func tokenError(_ data: Data, status: Int) -> String {
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = v["error_description"] as? String
            ?? (v["error"] as? [String: Any])?["message"] as? String
            ?? v["error"] as? String
            ?? ""
        return String(status) + ": " + message
    }

    /// What came back to the loopback address.
    public enum Callback: Equatable, Sendable {
        /// Some other address (a favicon): answered 404, keep waiting.
        case elsewhere
        /// The state is not the one this sign-in sent.
        case mismatch
        /// The user (or OpenAI) ended the sign-in.
        case denied(String)
        case code(String, clientID: String?)
    }

    /// Reads the request line of the browser's return ("GET /auth/callback?code=… HTTP/1.1").
    public static func callback(requestLine: String, state: String) -> Callback {
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let (path, query) = target.firstIndex(of: "?").map { (String(target[..<$0]), String(target[target.index(after: $0)...])) } ?? (target, "")
        guard path == callbackPath else { return .elsewhere }
        let q = formValues(query)
        guard q["state"] == state else { return .mismatch }
        if let error = q["error"] {
            return .denied([error, q["error_description"] ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces))
        }
        guard let code = q["code"], !code.isEmpty else { return .denied("no code") }
        return .code(code, clientID: q["client_id"])
    }

    // MARK: PKCE and forms

    /// A random value for the state, the nonce and the PKCE verifier: 32 bytes, base64url (43
    /// characters).
    public static func randomToken() -> String {
        var g = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }))
    }

    /// Base64url without padding (the PKCE challenge is this of the verifier's SHA-256).
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// application/x-www-form-urlencoded.
    public static func form(_ pairs: [(String, String)]) -> String {
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        return pairs.map { esc($0.0) + "=" + esc($0.1) }.joined(separator: "&")
    }

    /// The values of a form-encoded query ("+" is a space).
    public static func formValues(_ query: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let key = dec(kv[0])
            if values[key] == nil { values[key] = kv.count > 1 ? dec(kv[1]) : "" }
        }
        return values
    }

    // MARK: Requests

    /// The Responses request for the ChatGPT plan: store false and stream true are required;
    /// temperature and output limits are not accepted. The script joins the instructions, as with
    /// Chat Completions.
    public static func requestBody(model: String, effort: String, system: String, user: String, script: String = "") throws -> Data {
        let instructions = [system, Assistants.scriptBlock(script)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": user]],
            "store": false,
            "stream": true,
        ]
        if !effort.isEmpty { body["reasoning"] = ["effort": effort] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// A refused request, as something the user can act on (errors and recovery in OpenAI's
    /// documentation). The app puts it into words.
    public enum Failure: Error, Equatable, Sendable {
        /// A free account, or a Business workspace whose admin has not allowed it.
        case notEligible
        /// The plan's usage limit is reached.
        case quotaUsedUp
        /// The sign-in has expired or was revoked.
        case signedOut
        /// The reply stopped before the end.
        case incomplete
        /// Anything else: the status (0 inside a stream), the code and the service's message.
        case other(status: Int, code: String, message: String)
    }

    /// What a refused request means, from its status and body.
    public static func failure(status: Int, body: Data) -> Failure {
        let v = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = v?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        return failure(status: status, code: code, message: error?["message"] as? String ?? String(decoding: body.prefix(300), as: UTF8.self))
    }

    static func failure(status: Int, code: String, message: String) -> Failure {
        switch (status, code) {
        case (_, "subscription_sharing_user_not_eligible"): return .notEligible
        case (_, "subscription_sharing_usage_limit_exceeded"): return .quotaUsedUp
        case (401, _): return .signedOut
        default: return .other(status: status, code: code, message: String(message.prefix(300)))
        }
    }

    /// The failure a stream line reports (response.failed, error, response.incomplete), if any.
    public static func streamFailure(_ line: String) -> Failure? {
        guard let v = Streaming.object(line) else { return nil }
        switch v["type"] as? String {
        case "response.failed":
            let e = (v["response"] as? [String: Any])?["error"] as? [String: Any]
            return failure(status: 0, code: e?["code"] as? String ?? "failed", message: e?["message"] as? String ?? "")
        case "error":
            let e = v["error"] as? [String: Any] ?? v
            return failure(status: 0, code: e["code"] as? String ?? "failed", message: e["message"] as? String ?? "")
        case "response.incomplete":
            return .incomplete
        default:
            return nil
        }
    }
}
