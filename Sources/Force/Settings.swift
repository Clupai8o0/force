import Foundation
import SwiftUI

// MARK: - Schedule

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case everyLaunch
    case hourly
    case every12h
    case daily
    case weekly
    case onLogin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyLaunch: return "Every launch"
        case .hourly:      return "Every hour"
        case .every12h:    return "Every 12 hours"
        case .daily:       return "Once a day"
        case .weekly:      return "Once a week"
        case .onLogin:     return "On login / restart"
        }
    }

    var detail: String {
        switch self {
        case .everyLaunch: return "Re-acknowledge each time Force opens."
        case .hourly:      return "Re-locks one hour after each acknowledgement."
        case .every12h:    return "Re-locks twelve hours after each acknowledgement."
        case .daily:       return "One acknowledgement carries the whole day."
        case .weekly:      return "One acknowledgement carries the whole week."
        case .onLogin:     return "Re-acknowledge on every login and restart."
        }
    }

    /// Seconds between forced relaunches for launchd, when applicable.
    var startInterval: Int? {
        switch self {
        case .hourly:   return 3600
        case .every12h: return 43_200
        default:        return nil
        }
    }
}

// MARK: - Editable copy

struct NonNegotiable: Codable, Identifiable, Equatable {
    var id: String
    var label: String
}

enum DefaultCopy {
    static let motivation = "Execution beats planning. Commits, deployments, and documentation are the only valid measures."

    static let nonNegotiables: [NonNegotiable] = [
        .init(id: "brush-teeth", label: "Brush teeth (morning & night)"),
        .init(id: "wash-face", label: "Wash face (morning & night)"),
        .init(id: "leetcode", label: "LeetCode: 1 problem minimum"),
        .init(id: "cold-message", label: "Send 1 cold message/email"),
        .init(id: "gym", label: "Gym/30min physical activity"),
        .init(id: "journal", label: "Journal: 5-10 minutes"),
        .init(id: "read", label: "Read: 15-30 minutes"),
        .init(id: "no-doomscroll", label: "No doomscrolling (sit in silence 5-10 min)"),
    ]
}

// MARK: - Settings store

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let frequency = "af-frequency-v1"
        static let autoLaunch = "af-autolaunch-v1"
        static let motivation = "af-motivation-v1"
        static let contractText = "af-contract-text-v1"
        static let nonNegotiables = "af-nonnegotiables-v1"
        static let onboarded = "af-onboarded-v1"
        static let reflection = "af-reflection-v1"
        static let displayName = "af-display-name-v1"
    }

    @Published var frequency: Frequency {
        didSet {
            defaults.set(frequency.rawValue, forKey: Keys.frequency)
            Store.shared.recomputeGate()
            if autoLaunch { LaunchAgent.install(for: frequency) }
        }
    }

    @Published var autoLaunch: Bool {
        didSet {
            defaults.set(autoLaunch, forKey: Keys.autoLaunch)
            if autoLaunch { LaunchAgent.install(for: frequency) } else { LaunchAgent.uninstall() }
        }
    }

    @Published var motivation: String {
        didSet {
            defaults.set(motivation, forKey: Keys.motivation)
            RemoteSync.shared.markLocalEdit()
        }
    }

    @Published var contractText: String {
        didSet {
            defaults.set(contractText, forKey: Keys.contractText)
            RemoteSync.shared.markLocalEdit()
        }
    }

    @Published var reflection: String {
        didSet { defaults.set(reflection, forKey: Keys.reflection) }
    }

    @Published var nonNegotiables: [NonNegotiable] {
        didSet {
            if let data = try? JSONEncoder().encode(nonNegotiables) {
                defaults.set(data, forKey: Keys.nonNegotiables)
            }
            Store.shared.syncChecklist()
            RemoteSync.shared.markLocalEdit()
        }
    }

    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    @Published var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    private init() {
        frequency = defaults.string(forKey: Keys.frequency).flatMap(Frequency.init(rawValue:)) ?? .daily
        autoLaunch = defaults.bool(forKey: Keys.autoLaunch)
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        displayName = defaults.string(forKey: Keys.displayName) ?? ""
        motivation = defaults.string(forKey: Keys.motivation) ?? DefaultCopy.motivation
        contractText = defaults.string(forKey: Keys.contractText) ?? Contract.defaultMarkdown
        reflection = defaults.string(forKey: Keys.reflection) ?? ""
        if let data = defaults.data(forKey: Keys.nonNegotiables),
           let decoded = try? JSONDecoder().decode([NonNegotiable].self, from: data) {
            nonNegotiables = decoded
        } else {
            nonNegotiables = DefaultCopy.nonNegotiables
        }
    }
}

// MARK: - LaunchAgent integration

/// Installs/removes a user LaunchAgent so Force auto-launches on login and on
/// the chosen interval. User-initiated only (toggled in onboarding/settings).
enum LaunchAgent {
    static let label = "com.acknowledgementforce.agent"

    private static var plistURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LaunchAgents/\(label).plist")
    }

    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    static func install(for frequency: Frequency) {
        guard let url = plistURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        if let interval = frequency.startInterval {
            dict["StartInterval"] = interval
        } else if frequency == .daily {
            dict["StartCalendarInterval"] = ["Hour": 6, "Minute": 0]
        } else if frequency == .weekly {
            dict["StartCalendarInterval"] = ["Weekday": 1, "Hour": 6, "Minute": 0]
        }

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0) else { return }
        try? data.write(to: url)
        reload(url: url)
    }

    static func uninstall() {
        guard let url = plistURL else { return }
        run(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: url)
    }

    private static func reload(url: URL) {
        let domain = "gui/\(getuid())"
        run(["/bin/launchctl", "bootout", "\(domain)/\(label)"])
        run(["/bin/launchctl", "bootstrap", domain, url.path])
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = nil
        p.standardError = nil
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return -1 }
    }
}
