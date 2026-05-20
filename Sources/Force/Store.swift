import Foundation
import SwiftUI

// MARK: - Models

struct Acknowledgement: Codable {
    var date: String          // yyyy-MM-dd
    var action: String
    var timestamp: Double
}

struct HistoryEntry: Codable, Identifiable {
    var date: String
    var action: String
    var timestamp: Double
    var id: Double { timestamp }
}

// MARK: - Date helpers

enum AppDate {
    static func todayKey() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func longToday() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: Date())
    }

    static func short(_ key: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_AU")
        out.dateFormat = "EEE, d MMM"
        return out.string(from: d)
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let acknowledgement = "af-acknowledgement-v1"
        static let checklist = "af-checklist-v1"
        static let history = "af-history-v1"
        static let lastAckMs = "af-last-ack-ms-v1"
    }

    @Published var checklistState: [String: Bool] = [:]
    @Published var todayAction: String = ""

    /// True when the current schedule period is already acknowledged — the
    /// app shows the dashboard rather than the locked contract.
    @Published var gateOpen: Bool = false

    /// Reset each process launch; backs the "every launch" / "on login" gate.
    private var sessionAcknowledged = false

    init() {
        let today = AppDate.todayKey()
        if let ack = loadAcknowledgement() {
            todayAction = ack.action
        }
        loadOrResetChecklist(for: today)
        recomputeGate()
    }

    // MARK: Period gate

    private var lastAckMs: Double { defaults.double(forKey: Keys.lastAckMs) }

    /// Decides whether the latest acknowledgement still satisfies the schedule.
    func recomputeGate() {
        gateOpen = isSatisfied()
    }

    private func isSatisfied() -> Bool {
        let last = lastAckMs
        guard last > 0 else { return false }
        let lastDate = Date(timeIntervalSince1970: last / 1000)
        let now = Date()
        switch SettingsStore.shared.frequency {
        case .everyLaunch, .onLogin:
            return sessionAcknowledged
        case .hourly:
            return now.timeIntervalSince(lastDate) < 3600
        case .every12h:
            return now.timeIntervalSince(lastDate) < 43_200
        case .daily:
            return Calendar.current.isDate(lastDate, inSameDayAs: now)
        case .weekly:
            return Calendar.current.isDate(lastDate, equalTo: now, toGranularity: .weekOfYear)
        }
    }

    // MARK: Acknowledgement

    func loadAcknowledgement() -> Acknowledgement? {
        guard let data = defaults.data(forKey: Keys.acknowledgement) else { return nil }
        return try? JSONDecoder().decode(Acknowledgement.self, from: data)
    }

    func confirm(action: String) {
        let today = AppDate.todayKey()
        let ack = Acknowledgement(date: today, action: action, timestamp: Date().timeIntervalSince1970 * 1000)
        if let data = try? JSONEncoder().encode(ack) {
            defaults.set(data, forKey: Keys.acknowledgement)
        }
        addToHistory(action: action, date: today)
        resetChecklist(for: today)
        recordToLog()
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Keys.lastAckMs)
        sessionAcknowledged = true
        todayAction = action
        gateOpen = true
    }

    /// Edits today's confirmed action in place: updates the live value, the
    /// stored acknowledgement, and today's most recent history entry (rather
    /// than appending a new one).
    func updateTodayAction(_ newAction: String) {
        let trimmed = newAction.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != todayAction else { return }
        let today = AppDate.todayKey()

        todayAction = trimmed

        if var ack = loadAcknowledgement() {
            ack.action = trimmed
            if let data = try? JSONEncoder().encode(ack) {
                defaults.set(data, forKey: Keys.acknowledgement)
            }
        }

        var history = loadHistory()
        if let idx = history.firstIndex(where: { $0.date == today }) {
            history[idx].action = trimmed
        } else {
            history.insert(HistoryEntry(date: today, action: trimmed, timestamp: Date().timeIntervalSince1970 * 1000), at: 0)
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
        }
    }

    // MARK: Checklist

    private func loadOrResetChecklist(for today: String) {
        if let data = defaults.data(forKey: Keys.checklist),
           let stored = try? JSONDecoder().decode([String: [String: Bool]].self, from: data),
           let dateWrap = defaults.string(forKey: Keys.checklist + "-date"),
           dateWrap == today,
           let items = stored["items"] {
            checklistState = items
        } else {
            resetChecklist(for: today)
        }
    }

    private func resetChecklist(for today: String) {
        var fresh: [String: Bool] = [:]
        for item in SettingsStore.shared.nonNegotiables { fresh[item.id] = false }
        checklistState = fresh
        persistChecklist(today)
    }

    /// Keeps checklist state in step with the editable item list: drops removed
    /// items, defaults newly added ones to unchecked. Called when items change.
    func syncChecklist() {
        let items = SettingsStore.shared.nonNegotiables
        var next: [String: Bool] = [:]
        for item in items { next[item.id] = checklistState[item.id] ?? false }
        checklistState = next
        persistChecklist(AppDate.todayKey())
    }

    func toggle(_ id: String) {
        checklistState[id, default: false].toggle()
        persistChecklist(AppDate.todayKey())
    }

    private func persistChecklist(_ today: String) {
        let wrap = ["items": checklistState]
        if let data = try? JSONEncoder().encode(wrap) {
            defaults.set(data, forKey: Keys.checklist)
            defaults.set(today, forKey: Keys.checklist + "-date")
        }
    }

    var completedCount: Int {
        SettingsStore.shared.nonNegotiables.filter { checklistState[$0.id] == true }.count
    }
    var totalCount: Int { SettingsStore.shared.nonNegotiables.count }

    // MARK: History

    func loadHistory() -> [HistoryEntry] {
        guard let data = defaults.data(forKey: Keys.history) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func addToHistory(action: String, date: String) {
        var history = loadHistory()
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date.distantPast
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        history = history.filter { (parser.date(from: $0.date) ?? Date.distantPast) >= cutoff }
        history.insert(HistoryEntry(date: date, action: action, timestamp: Date().timeIntervalSince1970 * 1000), at: 0)
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
        }
    }

    // MARK: Acknowledgement log (mirrors the Tauri backend record)

    private func recordToLog() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Force", isDirectory: true) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("acknowledgements.log")
        let line = "acknowledged_at_ms=\(Int(Date().timeIntervalSince1970 * 1000))\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: file)
        }
    }
}
