import Foundation
import SwiftUI

// MARK: - Remote sync (Supabase)
//
// Pulls the editable contract / quotes / goals / reflection from the same
// Supabase project the web editor writes to, so changes made anywhere land on
// this Mac. Auth is email + password via GoTrue; content is read over PostgREST
// (row-level security returns only the signed-in user's row). The fetched copy
// is applied to SettingsStore, which already persists locally — so the last
// successful sync is the offline fallback.
//
// Note: tokens are kept in UserDefaults to match the rest of the app's storage.
// Moving them to the Keychain would be a reasonable hardening step.

enum SyncStatus: Equatable {
    case needsConfig
    case loggedOut
    case syncing
    case synced(Date)
    case error(String)
}

@MainActor
final class RemoteSync: ObservableObject {
    static let shared = RemoteSync()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let baseURL = "af-supabase-url-v1"
        static let anonKey = "af-supabase-anon-v1"
        static let access = "af-supabase-access-v1"
        static let refresh = "af-supabase-refresh-v1"
        static let email = "af-supabase-email-v1"
        static let userId = "af-supabase-userid-v1"
        static let localDirty = "af-sync-dirty-v1"
        static let localUpdatedAt = "af-sync-local-ms-v1"
    }

    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: Keys.baseURL) } }
    @Published var anonKey: String { didSet { defaults.set(anonKey, forKey: Keys.anonKey) } }
    @Published private(set) var email: String?
    @Published private(set) var status: SyncStatus = .loggedOut

    /// True when the Mac holds edits to synced fields that haven't reached the
    /// cloud yet. Surfaced in Settings; cleared after a successful push/pull.
    @Published private(set) var localDirty: Bool

    /// Set while a remote pull is writing into SettingsStore, so the resulting
    /// `didSet`s don't get mistaken for user edits.
    private var applyingRemote = false

    private var accessToken: String? {
        get { defaults.string(forKey: Keys.access) }
        set { defaults.set(newValue, forKey: Keys.access) }
    }
    private var refreshToken: String? {
        get { defaults.string(forKey: Keys.refresh) }
        set { defaults.set(newValue, forKey: Keys.refresh) }
    }
    private var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { defaults.set(newValue, forKey: Keys.userId) }
    }
    private var localUpdatedAt: Double {
        get { defaults.double(forKey: Keys.localUpdatedAt) }
        set { defaults.set(newValue, forKey: Keys.localUpdatedAt) }
    }

    /// User-entered overrides win; otherwise fall back to the build-time baked
    /// config (set by install.sh). Lets distributed builds work with no setup.
    var effectiveURL: String {
        let override = baseURL.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? SupabaseConfig.url : override
    }
    var effectiveAnonKey: String {
        let override = anonKey.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? SupabaseConfig.anonKey : override
    }

    var isConfigured: Bool {
        !effectiveURL.isEmpty && !effectiveAnonKey.isEmpty
    }
    var isLoggedIn: Bool { accessToken != nil }

    private init() {
        baseURL = defaults.string(forKey: Keys.baseURL) ?? ""
        anonKey = defaults.string(forKey: Keys.anonKey) ?? ""
        email = defaults.string(forKey: Keys.email)
        localDirty = defaults.bool(forKey: Keys.localDirty)
        status = !isConfigured ? .needsConfig : (isLoggedIn ? .synced(.distantPast) : .loggedOut)
    }

    /// Called from SettingsStore when the user edits a synced field on the Mac.
    /// Records the edit time so the next sync can decide push-vs-pull.
    func markLocalEdit() {
        guard !applyingRemote else { return }
        localUpdatedAt = Date().timeIntervalSince1970 * 1000
        localDirty = true
        defaults.set(true, forKey: Keys.localDirty)
    }

    private func clearDirty() {
        localDirty = false
        defaults.set(false, forKey: Keys.localDirty)
    }

    // MARK: Public API

    /// Called once on launch — refreshes content if we have a session.
    func launchSync() async {
        guard isConfigured, isLoggedIn else { return }
        await syncNow()
    }

    func login(email rawEmail: String, password: String) async {
        let email = rawEmail.trimmingCharacters(in: .whitespaces)
        guard isConfigured else { status = .needsConfig; return }
        guard !email.isEmpty, !password.isEmpty else {
            status = .error("Enter your email and password."); return
        }
        status = .syncing
        do {
            let token = try await requestToken(
                grant: "password",
                body: ["email": email, "password": password]
            )
            store(token: token, email: token.user.email ?? email)
            await syncNow()
        } catch {
            status = .error(message(for: error))
        }
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        userId = nil
        email = nil
        defaults.removeObject(forKey: Keys.email)
        status = .loggedOut
    }

    /// Reconciles local and cloud copies with last-write-wins. If the Mac holds
    /// newer edits, they're pushed; otherwise the cloud copy is pulled in.
    func syncNow() async {
        guard isConfigured, isLoggedIn else { return }
        status = .syncing
        do {
            let cloud = try await fetchContent(retryOn401: true)
            let cloudMs = parseTimestamp(cloud.updated_at)
            if localDirty && localUpdatedAt > cloudMs {
                try await push(retryOn401: true)
            } else {
                apply(cloud)
                localUpdatedAt = cloudMs
            }
            clearDirty()
            status = .synced(Date())
        } catch {
            status = .error(message(for: error))
        }
    }

    /// Pushes pending local edits without pulling — used when leaving Settings.
    func pushIfDirty() async {
        guard isConfigured, isLoggedIn, localDirty else { return }
        status = .syncing
        do {
            try await push(retryOn401: true)
            clearDirty()
            status = .synced(Date())
        } catch {
            status = .error(message(for: error))
        }
    }

    // MARK: Apply (cloud -> local)

    private func apply(_ c: RemoteContent) {
        applyingRemote = true
        defer { applyingRemote = false }

        let settings = SettingsStore.shared
        let contract = c.contract_md.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contract.isEmpty { settings.contractText = c.contract_md }

        if !c.goals.isEmpty {
            settings.nonNegotiables = c.goals.map { NonNegotiable(id: $0.id, label: $0.label) }
        }

        let quotes = c.quotes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let quote = quotes.randomElement() { settings.motivation = quote }

        settings.reflection = c.reflection
    }

    // MARK: Networking

    private func fetchContent(retryOn401: Bool) async throws -> RemoteContent {
        guard let token = accessToken else { throw SyncError.notLoggedIn }
        var req = URLRequest(url: try restURL())
        req.httpMethod = "GET"
        req.setValue(effectiveAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        if code == 401, retryOn401 {
            try await refreshSession()
            return try await fetchContent(retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            throw SyncError.server(serverMessage(data) ?? "Request failed (\(code)).")
        }
        let rows = try JSONDecoder().decode([RemoteContent].self, from: data)
        guard let row = rows.first else { throw SyncError.server("No contract found for this account.") }
        return row
    }

    /// PATCHes only the Mac-owned fields (contract + goals); quotes and
    /// reflection stay under the web editor's control and are left untouched.
    private func push(retryOn401: Bool) async throws {
        guard let token = accessToken, let uid = userId else { throw SyncError.notLoggedIn }
        let settings = SettingsStore.shared
        let goals = settings.nonNegotiables.map { ["id": $0.id, "label": $0.label] }
        let body: [String: Any] = [
            "contract_md": settings.contractText,
            "goals": goals,
        ]

        var req = URLRequest(url: try patchURL(userId: uid))
        req.httpMethod = "PATCH"
        req.setValue(effectiveAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retryOn401 {
            try await refreshSession()
            return try await push(retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            throw SyncError.server(serverMessage(data) ?? "Save failed (\(code)).")
        }
    }

    private func refreshSession() async throws {
        guard let refresh = refreshToken else { throw SyncError.notLoggedIn }
        let token = try await requestToken(grant: "refresh_token", body: ["refresh_token": refresh])
        store(token: token, email: token.user.email ?? email ?? "")
    }

    private func requestToken(grant: String, body: [String: String]) async throws -> TokenResponse {
        var comps = URLComponents(url: try authBase(), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        guard let url = comps?.url else { throw SyncError.badConfig }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(effectiveAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if grant == "refresh_token" { logout() }
            throw SyncError.server(serverMessage(data) ?? "Login failed (\(code)).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(token: TokenResponse, email: String) {
        accessToken = token.access_token
        refreshToken = token.refresh_token
        userId = token.user.id
        self.email = email
        defaults.set(email, forKey: Keys.email)
    }

    // MARK: URL helpers

    private func normalizedBase() throws -> URL {
        var s = effectiveURL
        if s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme != nil else { throw SyncError.badConfig }
        return url
    }
    private func authBase() throws -> URL {
        try normalizedBase().appendingPathComponent("auth/v1/token")
    }
    private func restURL() throws -> URL {
        var comps = URLComponents(
            url: try normalizedBase().appendingPathComponent("rest/v1/contents"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "select", value: "contract_md,quotes,goals,reflection,updated_at"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps?.url else { throw SyncError.badConfig }
        return url
    }
    private func patchURL(userId: String) throws -> URL {
        var comps = URLComponents(
            url: try normalizedBase().appendingPathComponent("rest/v1/contents"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        guard let url = comps?.url else { throw SyncError.badConfig }
        return url
    }

    /// Parses a PostgREST timestamptz ("2026-05-22T10:00:00.123456+00:00") to
    /// epoch ms. Fractional seconds are trimmed to milliseconds for ISO8601.
    private func parseTimestamp(_ s: String?) -> Double {
        guard var str = s else { return 0 }
        if let dot = str.firstIndex(of: ".") {
            var i = str.index(after: dot)
            var frac = ""
            while i < str.endIndex, str[i].isNumber {
                frac.append(str[i])
                i = str.index(after: i)
            }
            let ms = String(frac.prefix(3))
            str.replaceSubrange(dot..<i, with: ms.isEmpty ? "" : "." + ms)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: str) { return d.timeIntervalSince1970 * 1000 }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: str) { return d.timeIntervalSince1970 * 1000 }
        return 0
    }

    // MARK: Errors

    private func serverMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["error_description"] as? String)
            ?? (obj["msg"] as? String)
            ?? (obj["message"] as? String)
            ?? (obj["error"] as? String)
    }

    private func message(for error: Error) -> String {
        switch error {
        case SyncError.server(let m): return m
        case SyncError.badConfig: return "Check the Supabase URL and key."
        case SyncError.notLoggedIn: return "Not logged in."
        default: return (error as NSError).localizedDescription
        }
    }
}

private enum SyncError: Error {
    case badConfig
    case notLoggedIn
    case server(String)
}

// MARK: - Wire models

private struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String
    let user: TokenUser
}
private struct TokenUser: Codable {
    let id: String
    let email: String?
}
private struct RemoteGoal: Codable {
    let id: String
    let label: String
}
private struct RemoteContent: Codable {
    let contract_md: String
    let quotes: [String]
    let goals: [RemoteGoal]
    let reflection: String
    let updated_at: String?
}
