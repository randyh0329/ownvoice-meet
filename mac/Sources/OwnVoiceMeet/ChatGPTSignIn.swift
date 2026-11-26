// Sign in with ChatGPT: the user's ChatGPT plan (Go, Plus, Pro or Business) pays for captions,
// replies, the summary and 補對照 instead of an API key. Text only: recognition is not open to it.
//
// Continue with ChatGPT opens the browser at OpenAI's sign-in (OAuth 2 with PKCE, ChatGPTPlan in
// Core has the protocol); the browser comes back to 127.0.0.1 on a free port, where a small
// listener takes the code. The tokens are kept in the login Keychain, refreshed when they are about
// to expire, and forgotten on Sign Out of ChatGPT. The requests themselves are ChatGPTPlanModel
// (TextModels.swift).

import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import OwnVoiceCore
import SwiftUI

// MARK: - The connection in the Keychain

enum ChatGPTStore {
    static let account = "chatgpt"

    static func load() -> ChatGPTPlan.Connection? {
        guard let text = Keychain.get(account) else { return nil }
        return try? JSONDecoder().decode(ChatGPTPlan.Connection.self, from: Data(text.utf8))
    }

    static func save(_ c: ChatGPTPlan.Connection) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        Keychain.set(account, String(decoding: data, as: UTF8.self))
    }

    static func forget() {
        Keychain.set(account, "")
    }
}

// MARK: - Tokens

enum ChatGPTAuth {
    static func endpoints() async throws -> (authorize: URL, token: URL) {
        let (data, _) = try await URLSession.shared.data(from: ChatGPTPlan.discoveryURL)
        return try ChatGPTPlan.endpoints(data)
    }

    /// A form posted to the token endpoint; a refusal comes back as the service's own words.
    static func tokenRequest(_ url: URL, _ body: Data) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ServiceError(ChatGPTPlan.tokenError(data, status: status)) }
        return data
    }

    /// PKCE S256: base64url, no padding, of the verifier's SHA-256.
    static func challenge(_ verifier: String) -> String {
        ChatGPTPlan.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func refreshed(_ c: ChatGPTPlan.Connection) async throws -> ChatGPTPlan.Connection {
        let (_, token) = try await endpoints()
        let data = try await tokenRequest(token, ChatGPTPlan.refreshRequest(c))
        return try ChatGPTPlan.connection(tokenResponse: data, clientID: c.clientID, previous: c)
    }
}

/// A usable access token for each request: the saved one, refreshed (and saved) when it is about to
/// expire. Only one refresh at a time: a refresh token works once, and translations run side by
/// side.
actor ChatGPTTokens {
    static let shared = ChatGPTTokens()
    private var refreshing: Task<ChatGPTPlan.Connection, Error>?

    func access() async throws -> String {
        if let refreshing {
            do { return try await refreshing.value.access } catch { throw Self.expired(error) }
        }
        guard let c = ChatGPTStore.load() else { throw AppError(ChatGPTPlan.Failure.notConnectedMessage) }
        guard c.planAllowed else { throw AppError(ChatGPTPlan.Failure.planNotAllowedMessage) }
        guard c.isExpired() else { return c.access }
        let task = Task { try await ChatGPTAuth.refreshed(c) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            // Not when the user signed out meanwhile.
            if ChatGPTStore.load() != nil { ChatGPTStore.save(fresh) }
            return fresh.access
        } catch {
            throw Self.expired(error)
        }
    }

    private static func expired(_ error: Error) -> AppError {
        let detail = error.localizedDescription
        return AppError(String(localized: "The ChatGPT sign-in has expired; sign in again in Settings (\(detail))."))
    }
}

// MARK: - What a refusal means

extension ChatGPTPlan.Failure {
    static var notConnectedMessage: String {
        String(localized: "Not connected to ChatGPT yet: press Continue with ChatGPT in Settings → Listen & Translate.")
    }

    static var planNotAllowedMessage: String {
        String(localized: "This sign-in did not allow using your ChatGPT plan; sign in again in Settings.")
    }

    var message: String {
        switch self {
        case .notEligible:
            String(localized: "This ChatGPT account can't use its plan here (it needs Go, Plus, Pro or Business; a company account needs its admin to allow it). Use an API key instead.")
        case .quotaUsedUp:
            String(localized: "The ChatGPT plan's usage limit is reached: see chatgpt.com/settings/usage, or use an API key for now.")
        case .signedOut:
            String(localized: "The ChatGPT sign-in has expired; sign in again in Settings.")
        case .incomplete:
            String(localized: "ChatGPT did not finish this line.")
        case let .other(status, code, text):
            [status > 0 ? String(status) : "", code].filter { !$0.isEmpty }.joined(separator: " ") + ": " + text
        }
    }
}

// MARK: - Signing in

@MainActor
@Observable
final class ChatGPTSignIn {
    private(set) var connection: ChatGPTPlan.Connection? = ChatGPTStore.load()
    /// The browser is open, waiting for the user to sign in.
    private(set) var waiting = false
    private(set) var message = ""
    @ObservationIgnored private var callback: LoopbackCallback?

    /// Opens the browser to sign in and waits (up to 5 minutes) for it to come back.
    func signIn() async {
        guard !waiting else { return }
        waiting = true
        message = ""
        defer {
            waiting = false
            callback = nil
        }
        do {
            let fresh = try await connect()
            ChatGPTStore.save(fresh)
            connection = fresh
            if !fresh.planAllowed { message = ChatGPTPlan.Failure.planNotAllowedMessage }
        } catch is CancellationError {
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }

    func cancel() {
        callback?.cancel()
    }

    /// Forgets the connection on this Mac (the account stays connected in ChatGPT's settings until
    /// the user disconnects it there).
    func signOut() {
        ChatGPTStore.forget()
        connection = nil
        message = ""
    }

    private func connect() async throws -> ChatGPTPlan.Connection {
        // The client id issued last time is used again.
        let previous = ChatGPTStore.load()?.clientID
        let (authorize, token) = try await ChatGPTAuth.endpoints()
        let state = ChatGPTPlan.randomToken(), nonce = ChatGPTPlan.randomToken(), verifier = ChatGPTPlan.randomToken()
        let callback = try LoopbackCallback(state: state)
        self.callback = callback
        let redirect = ChatGPTPlan.redirect(port: try await callback.start())
        let url = ChatGPTPlan.authorizeURL(endpoint: authorize, clientID: previous, redirect: redirect, state: state, nonce: nonce,
                                           challenge: ChatGPTAuth.challenge(verifier))
        NSWorkspace.shared.open(url)
        let returned = try await callback.wait()
        guard let clientID = returned.clientID ?? previous else {
            throw AppError(String(localized: "ChatGPT did not complete the sign-in; try again."))
        }
        let data = try await ChatGPTAuth.tokenRequest(token, ChatGPTPlan.codeExchange(clientID: clientID, code: returned.code, verifier: verifier, redirect: redirect))
        // The nonce sent with this sign-in must come back in the ID token: the answer belongs to it.
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let id = v?["id_token"] as? String else {
            throw AppError(String(localized: "ChatGPT sent no identity data; sign in again."))
        }
        guard ChatGPTPlan.idClaims(id)["nonce"] as? String == nonce else {
            throw AppError(String(localized: "The ChatGPT sign-in reply did not match; sign in again."))
        }
        return try ChatGPTPlan.connection(tokenResponse: data, clientID: clientID)
    }
}

/// The browser's return to 127.0.0.1 on a free port: the first request to /auth/callback with this
/// sign-in's state is answered with a short page and ends the wait; anything else gets a 404. Gives
/// up after 5 minutes. Everything runs on one queue.
final class LoopbackCallback: @unchecked Sendable {
    struct Returned: Sendable {
        let code: String
        let clientID: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "OwnVoice Meet ChatGPT sign-in")
    private let state: String
    private var outcome: Result<Returned, Error>?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<Returned, Error>?

    init(state: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.state = state
    }

    /// Starts listening; returns the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        ready?.resume(returning: listener.port?.rawValue ?? 0)
                        ready = nil
                    case .failed(let error):
                        ready?.resume(throwing: error)
                        ready = nil
                        finish(.failure(error))
                    case .cancelled:
                        ready?.resume(throwing: CancellationError())
                        ready = nil
                        listener.stateUpdateHandler = nil
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [self] connection in
                    connection.start(queue: queue)
                    receive(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    /// Waits for the browser.
    func wait() async throws -> Returned {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Returned, Error>) in
            queue.async { [self] in
                if let outcome {
                    continuation.resume(with: outcome)
                    return
                }
                waiter = continuation
                queue.asyncAfter(deadline: .now() + ChatGPTPlan.signInTimeout) { [self] in
                    finish(.failure(AppError(String(localized: "Sign-in was not finished within 5 minutes."))))
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<Returned, Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(with: result)
        waiter = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    /// Reads until the request line is in.
    private func receive(_ connection: NWConnection, _ soFar: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] data, _, isComplete, error in
            var buffer = soFar
            if let data { buffer.append(data) }
            if let end = buffer.firstRange(of: Data("\r\n".utf8)) {
                answer(connection, requestLine: String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 65536 {
                connection.cancel()
            } else {
                receive(connection, buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, requestLine: String) {
        guard outcome == nil else {
            send(connection, Self.page(String(localized: "Sign-in was not completed. You can close this tab.")))
            return
        }
        switch ChatGPTPlan.callback(requestLine: requestLine, state: state) {
        case .elsewhere:
            send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .mismatch:
            send(connection, Self.page(String(localized: "Sign-in failed: the reply did not match. Go back to OwnVoice Meet and try again.")))
            finish(.failure(AppError(String(localized: "The ChatGPT sign-in reply did not match; sign in again."))))
        case .denied(let detail):
            send(connection, Self.page(String(localized: "Sign-in was not completed. You can close this tab.")))
            finish(.failure(AppError(String(localized: "Sign-in was not completed (\(detail))."))))
        case let .code(code, clientID):
            send(connection, Self.page(String(localized: "Connected to ChatGPT. You can close this tab and go back to OwnVoice Meet.")))
            finish(.success(Returned(code: code, clientID: clientID)))
        }
    }

    private func send(_ connection: NWConnection, _ response: String) {
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(_ text: String) -> String {
        let html = "<!doctype html><meta charset=utf-8><title>OwnVoice Meet</title><p style=\"font:18px system-ui;margin:3em\">" + text + "</p>"
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + String(Data(html.utf8).count) + "\r\nConnection: close\r\n\r\n" + html
    }
}

// MARK: - Settings

/// Settings → Listen & Translate, when the ChatGPT plan translates the captions or writes a summary.
struct ChatGPTSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings
        let account = model.chatGPT
        if s.translate == .chatgpt || s.liveSummaryModel == .chatgpt || s.meetingSummaryModel == .chatgpt {
            Section("ChatGPT plan") {
                if let c = account.connection {
                    let email = c.email
                    if email.isEmpty {
                        Text("Connected to ChatGPT.")
                    } else {
                        Text(verbatim: String(localized: "Connected to ChatGPT as \(email)."))
                    }
                    HStack {
                        if !c.planAllowed {
                            Button("Continue with ChatGPT") { Task { await account.signIn() } }
                                .disabled(account.waiting)
                        }
                        Button("Sign Out of ChatGPT") { account.signOut() }
                    }
                } else if account.waiting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in the browser…")
                        Spacer()
                        Button("Cancel") { account.cancel() }
                    }
                } else {
                    Button("Continue with ChatGPT") { Task { await account.signIn() } }
                }
                if !account.message.isEmpty {
                    Text(verbatim: account.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("OpenAI's Sign in with ChatGPT, still in preview. Text only: recognition still needs its own option. It shares your plan's quota with ChatGPT and Codex (see chatgpt.com → Settings → Usage); free accounts can't use it, and a Business account needs its admin to allow it. Each line comes about 1 second later than with an API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Signing out forgets the connection on this Mac; to disconnect the app itself, go to ChatGPT → Settings → Security → Sign in with ChatGPT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
