import Foundation

// Pure logic shared by the app and tests/swift (Foundation only).

enum Version {
    static func newer(_ version: String, than other: String) -> Bool {
        let left = parts(version), right = parts(other)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func parts(_ version: String) -> [Int] {
        let plain = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        return plain.split(separator: ".").map { Int($0.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0 }
    }
}

enum PageMessage: Equatable {
    case bridge([String]), resize(Double), quit

    static let providers: Set<String> = ["claude", "codex"]
    static let heights: ClosedRange<Double> = 260...540

    static func isAccount(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...31).contains(scalars.count) else { return false }
        return scalars.indices.allSatisfy { index in
            let c = scalars[index]
            return ("a"..."z").contains(c) || ("0"..."9").contains(c) || (index > 0 && c == "-")
        }
    }

    static func parse(_ body: Any) -> PageMessage? {
        guard let fields = body as? [String: Any], let action = fields["action"] as? String,
              fields.values.allSatisfy({ $0 is String }) else { return nil }
        let provider = (fields["provider"] as? String).flatMap { providers.contains($0) ? $0 : nil }
        let account = (fields["account"] as? String).flatMap { isAccount($0) ? $0 : nil }
        switch action {
        case "snapshot", "update": return .bridge([action])
        case "quit": return .quit
        case "resize":
            guard let text = fields["height"] as? String, let height = Double(text), height.isFinite else { return nil }
            return .resize(min(heights.upperBound, max(heights.lowerBound, height)))
        case "select", "login", "remove":
            guard let provider, let account else { return nil }
            return .bridge([action, provider, account])
        case "add_auto":
            guard let provider else { return nil }
            return .bridge([action, provider])
        default: return nil
        }
    }
}

struct MenuBarItem: Equatable {
    var provider: String
    var percent: Int?
}

enum MenuBar {
    static let names = ["claude": "Claude", "codex": "Codex"]
    static let staleAfter: TimeInterval = 15 * 60
    static let figureSpace = "\u{2007}"

    /// Up to two cards for the title, plus how many more cards there are.
    static func items(_ snapshot: [String: Any]) -> (items: [MenuBarItem], more: Int) {
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        let providers = snapshot["providers"] as? [String: Any] ?? [:]
        let items = cards.prefix(2).map { card -> MenuBarItem in
            let provider = card["provider"] as? String ?? ""
            let accounts = (providers[provider] as? [String: Any])?["accounts"] as? [[String: Any]] ?? []
            let account = accounts.first { $0["id"] as? String == card["id"] as? String }
            let windows = account?["windows"] as? [String: Any] ?? [:]
            return MenuBarItem(provider: provider, percent: usedPercent(windows).flatMap(clampPercent))
        }
        return (items, max(0, cards.count - 2))
    }

    /// The higher of the 5-hour and weekly windows, else the highest of any window.
    static func usedPercent(_ windows: [String: Any]) -> Double? {
        func values(_ keys: [String]) -> [Double] {
            keys.compactMap { (windows[$0] as? [String: Any])?["used_percent"] as? Double }.filter { $0.isFinite }
        }
        let main = values(["5h", "7d"])
        return (main.isEmpty ? values(Array(windows.keys)) : main).max()
    }

    static func clampPercent(_ value: Double) -> Int? {
        value.isFinite ? Int(min(999, max(0, value)).rounded()) : nil
    }

    /// Padded to three digit widths with figure spaces so the title keeps its width.
    static func percentText(_ percent: Int?) -> String {
        guard let percent else { return String(repeating: figureSpace, count: 2) + "–" + figureSpace }
        let digits = String(percent)
        return String(repeating: figureSpace, count: max(0, 3 - digits.count)) + digits + "%"
    }

    static func suffix(more: Int, stale: Bool) -> String {
        (more > 0 ? "  +\(more)" : "") + (stale ? " !" : "")
    }

    static func accessibilityLabel(_ items: [MenuBarItem], more: Int, stale: Bool) -> String {
        var parts = items.map { "\(names[$0.provider] ?? $0.provider) \($0.percent.map { "\($0)%" } ?? "no data")" }
        if more > 0 { parts.append("\(more) more") }
        return "Usagi" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")) + (stale ? " (not up to date)" : "")
    }

    static func isStale(lastSuccess: Date?, failed: Bool, now: Date) -> Bool {
        failed || lastSuccess.map { now.timeIntervalSince($0) > staleAfter } ?? false
    }

    static func tooltip(updated: String?, error: String?) -> String {
        (["Usagi", updated.map { "Updated \($0)" } ?? "Not updated yet"] + [error].compactMap { $0 })
            .joined(separator: "\n")
    }
}

enum Cadence {
    static let shown: TimeInterval = 60, hidden: TimeInterval = 300, onOpen: TimeInterval = 30

    static func delay(since last: Date?, shown: Bool, now: Date) -> TimeInterval {
        let interval = shown ? Self.shown : hidden
        guard let last else { return interval }
        return min(interval, max(1, interval - now.timeIntervalSince(last)))
    }

    static func refreshOnOpen(since last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) > onOpen } ?? true
    }
}

enum JobOrigin { case user, followUp, background }

struct Job: Equatable {
    var arguments: [String]
    var origin: JobOrigin
}

/// One bridge run at a time. User actions go first, follow-up refreshes next; background
/// refreshes are dropped while anything runs. A job identical to one running or queued is
/// dropped, and a user request turns the existing job into a user job so it still reports back.
struct JobQueue {
    private(set) var running: Job?
    private(set) var waiting: [Job] = []

    var isBusy: Bool { running != nil || !waiting.isEmpty }

    @discardableResult
    mutating func add(_ job: Job) -> Bool {
        if running?.arguments == job.arguments {
            if job.origin == .user { running?.origin = .user }
            return false
        }
        if let index = waiting.firstIndex(where: { $0.arguments == job.arguments }) {
            if job.origin == .user && waiting[index].origin != .user {
                waiting.remove(at: index)
                insertUser(job)
            }
            return false
        }
        if job.origin == .background && isBusy { return false }
        if job.origin == .user { insertUser(job) } else { waiting.append(job) }
        return true
    }

    mutating func start() -> Job? {
        guard running == nil, !waiting.isEmpty else { return nil }
        running = waiting.removeFirst()
        return running
    }

    mutating func finish() -> Job? {
        defer { running = nil }
        return running
    }

    private mutating func insertUser(_ job: Job) {
        waiting.insert(job, at: waiting.firstIndex { $0.origin != .user } ?? waiting.endIndex)
    }
}

struct AccountKey: Hashable {
    var provider: String
    var account: String
}

/// Accounts with an open sign-in: polled with login_status every 3 s, given up after 11 minutes,
/// dropped once a snapshot shows them gone or no longer connecting.
struct LoginWatches {
    static let interval: TimeInterval = 3, limit: TimeInterval = 11 * 60, retry: TimeInterval = 30

    struct Watch: Equatable {
        var started: Date
        var next: Date
    }

    private(set) var watches: [AccountKey: Watch] = [:]

    func isActive(now: Date) -> Bool {
        watches.values.contains { now.timeIntervalSince($0.started) < Self.limit }
    }

    mutating func start(_ key: AccountKey, now: Date) {
        watches[key] = Watch(started: now, next: now.addingTimeInterval(Self.interval))
    }

    mutating func reconcile(_ snapshot: [String: Any], now: Date) {
        var connecting = Set<AccountKey>()
        for (provider, value) in snapshot["providers"] as? [String: Any] ?? [:] {
            for account in (value as? [String: Any])?["accounts"] as? [[String: Any]] ?? []
            where account["connecting"] as? Bool == true {
                if let id = account["id"] as? String { connecting.insert(AccountKey(provider: provider, account: id)) }
            }
        }
        watches = watches.filter { connecting.contains($0.key) }
        for key in connecting where watches[key] == nil { start(key, now: now) }
    }

    mutating func due(now: Date) -> AccountKey? {
        let ready = watches.filter { now >= $0.value.next && now.timeIntervalSince($0.value.started) < Self.limit }
        guard let entry = ready.min(by: { ($0.value.next, $0.key.provider, $0.key.account)
                                            < ($1.value.next, $1.key.provider, $1.key.account) }) else { return nil }
        watches[entry.key]?.next = now.addingTimeInterval(Self.interval)
        return entry.key
    }

    /// Handles a login_status reply (nil = it failed); returns true when a full snapshot should follow.
    mutating func status(_ key: AccountKey, connecting: Bool?, now: Date) -> Bool {
        guard watches[key] != nil else { return false }
        guard let connecting else {
            watches[key]?.next = now.addingTimeInterval(Self.retry)
            return true
        }
        if connecting { return false }
        watches[key] = nil
        return true
    }
}

/// GitHub update check: one at a time, every 6 hours after a success, 30 minutes after a failure.
struct UpdateSchedule {
    static let interval: TimeInterval = 6 * 3600, retry: TimeInterval = 30 * 60
    private(set) var inFlight = false
    private(set) var next: Date?

    mutating func begin(now: Date) -> Bool {
        guard !inFlight, next.map({ now >= $0 }) ?? true else { return false }
        inFlight = true
        return true
    }

    mutating func finish(success: Bool, now: Date) {
        inFlight = false
        next = now.addingTimeInterval(success ? Self.interval : Self.retry)
    }
}

enum PNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let maxBytes = 1_000_000

    static func hasSignature(_ data: Data) -> Bool { data.starts(with: signature) }
}

enum BridgeOutput {
    /// The bridge's own {"error": ...}, else the last line of stderr, else the exit status.
    static func errorMessage(stdout: Data, stderr: Data, status: Int32) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty { return message }
        let lines = String(decoding: stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
        if let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(line.trimmingCharacters(in: .whitespaces).prefix(300))
        }
        return "The usage reader failed (exit status \(status))."
    }
}
