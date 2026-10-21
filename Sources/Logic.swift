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

/// The popover grows with its content and only scrolls when that is taller than the screen allows.
enum PopoverHeight {
    static let minimum: Double = 260, screenMargin: Double = 24

    static func fit(_ requested: Double, available: Double?) -> Double {
        guard let available, available > 0 else { return max(minimum, min(requested, 540)) }
        return min(available, max(minimum, min(requested, available - screenMargin)))
    }
}

enum PageMessage: Equatable {
    case bridge([String]), resize(Double), quit, checkUpdates

    static let providers: Set<String> = ["claude", "codex"]
    static let heights: ClosedRange<Double> = 260...4000

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
        case "snapshot": return .bridge(Job.userRefresh)
        case "update": return .bridge([action])
        case "quit": return .quit
        case "check_update": return .checkUpdates
        case "resize":
            guard let text = fields["height"] as? String, let height = Double(text), height.isFinite else { return nil }
            return .resize(min(heights.upperBound, max(heights.lowerBound, height)))
        case "select", "login", "remove":
            guard let provider, let account else { return nil }
            return .bridge([action, provider, account])
        case "add_auto":
            guard let provider else { return nil }
            return .bridge([action, provider])
        case "reorder":  // "codex,claude": the services' new card order, each once
            guard let order = fields["order"] as? String else { return nil }
            let list = order.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !list.isEmpty, Set(list).count == list.count, list.allSatisfy(providers.contains) else { return nil }
            return .bridge([action, order])
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

    static let defaultServiceLimit = 2
    static let serviceLimitKey = "menuBarServices"  // UserDefaults: 1, 2, 3, or 0 for all

    /// One item per service, in card order: the Active account's usage when its card is shown, else the
    /// service's first card. At most `limit` services (nil for all); `more` counts the services left out,
    /// so extra accounts of a shown service never add a "+N".
    static func items(_ snapshot: [String: Any], limit: Int? = defaultServiceLimit) -> (items: [MenuBarItem], more: Int) {
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        let providers = snapshot["providers"] as? [String: Any] ?? [:]
        var order: [String] = []
        for case let provider? in cards.map({ $0["provider"] as? String }) where !order.contains(provider) {
            order.append(provider)
        }
        let all = order.map { provider -> MenuBarItem in
            let info = providers[provider] as? [String: Any] ?? [:]
            let shown = cards.filter { $0["provider"] as? String == provider }.compactMap { $0["id"] as? String }
            let accounts = info["accounts"] as? [[String: Any]] ?? []
            // The Active account, else the first shown card in the page's order (the accounts list is sorted).
            let id = (info["active"] as? String).flatMap { shown.contains($0) ? $0 : nil }
                ?? accounts.compactMap { $0["id"] as? String }.first(where: shown.contains) ?? shown.first
            let windows = accounts.first { $0["id"] as? String == id }?["windows"] as? [String: Any] ?? [:]
            return MenuBarItem(provider: provider, percent: usedPercent(windows).flatMap(clampPercent))
        }
        let count = limit.map { max(1, $0) } ?? all.count
        return (Array(all.prefix(count)), max(0, all.count - count))
    }

    /// The stored "Menu Bar Shows" choice: a number of services, or 0 (or anything unknown) for all of them.
    static func serviceLimit(stored: Int?) -> Int? {
        guard let stored else { return defaultServiceLimit }
        return stored > 0 ? stored : nil
    }

    /// "Menu Bar Shows" offers 1…N for the N services with cards; picking N stores 0 (all), so a service
    /// added later shows up too. Returns the choices and the one to check.
    static func serviceChoices(services: Int, stored: Int?) -> (choices: [Int], checked: Int) {
        let count = services > 0 ? services : PageMessage.providers.count  // before the first snapshot: every service
        let limit = serviceLimit(stored: stored) ?? count
        return (Array(1...count), min(limit, count))
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

    static func suffix(more: Int) -> String {
        more > 0 ? "  +\(more)" : ""
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

/// The page's actionDone message: the action with its provider and account, without options like --ask-shell.
struct ActionDone: Equatable {
    var action: String
    var provider: String?
    var account: String?
    var ok: Bool

    init(_ arguments: [String], ok: Bool) {
        let fields = arguments.filter { !$0.hasPrefix("-") }
        action = fields.first ?? ""
        provider = fields.count > 1 ? fields[1] : nil
        account = fields.count > 2 ? fields[2] : nil
        self.ok = ok
    }

    var json: [String: Any] {
        ["action": action, "provider": provider ?? NSNull(), "account": account ?? NSNull(), "ok": ok]
    }
}

struct Job: Equatable {
    /// The refresh button may ask the login shell where a missing CLI is; automatic refreshes never do.
    static let refresh = ["snapshot"], userRefresh = ["snapshot", "--ask-shell"]

    var arguments: [String]
    var origin: JobOrigin
    /// actionDone messages held back until this job has finished (a sign-in waits for its follow-up snapshot).
    var reports: [ActionDone] = []

    /// Both kinds of snapshot count as the same job.
    var key: [String] { arguments.first == "snapshot" ? Job.refresh : arguments }
}

/// One bridge run at a time. User actions go first, follow-up refreshes next; background
/// refreshes are dropped while anything runs. A job identical to one running or queued is
/// dropped and its held-back reports move to that job; a user request turns a queued job into
/// the user's (a refresh-button snapshot with --ask-shell) and a running one into a user job,
/// so it still reports back.
struct JobQueue {
    private(set) var running: Job?
    private(set) var waiting: [Job] = []

    var isBusy: Bool { running != nil || !waiting.isEmpty }

    @discardableResult
    mutating func add(_ job: Job) -> Bool {
        if job.arguments.first == "reorder" {
            // The newest order wins: it replaces a waiting reorder (taking over its actionDone reports) and is
            // never merged into the running one, which may already be saving an older order.
            var newest = job
            if let index = waiting.firstIndex(where: { $0.arguments.first == "reorder" }) {
                newest.reports = waiting.remove(at: index).reports + job.reports
            }
            insertUser(newest)
            return true
        }
        if var current = running, current.key == job.key {
            if job.origin == .user { current.origin = .user }
            current.reports += job.reports
            running = current
            return false
        }
        if let index = waiting.firstIndex(where: { $0.key == job.key }) {
            if job.origin == .user && waiting[index].origin != .user {
                var promoted = job
                promoted.reports = waiting.remove(at: index).reports + job.reports
                insertUser(promoted)
            } else {
                waiting[index].reports += job.reports
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
    /// The repeating 3 s timer can fire a little before `next`; without slack every other tick would be skipped.
    static let slack: TimeInterval = 1

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
        let ready = watches.filter {
            now.addingTimeInterval(Self.slack) >= $0.value.next && now.timeIntervalSince($0.value.started) < Self.limit
        }
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

    /// `force` (the user asked) skips the wait, but never starts a second check while one is running.
    mutating func begin(now: Date, force: Bool = false) -> Bool {
        guard !inFlight, force || next.map({ now >= $0 }) ?? true else { return false }
        inFlight = true
        return true
    }

    mutating func finish(success: Bool, now: Date) {
        inFlight = false
        next = now.addingTimeInterval(success ? Self.interval : Self.retry)
    }
}

enum UpdateStatus {
    /// What the page gets after a check: `version` when a newer release exists (it shows the banner), `latest`
    /// when this copy is current, `failed` when GitHub couldn't be reached.
    static func info(latest: String?, current: String, now: Date) -> [String: String] {
        guard let latest else { return ["current": current, "failed": "true"] }
        return ["current": current, "checked_at": String(Int(now.timeIntervalSince1970)),
                Version.newer(latest, than: current) ? "version" : "latest": latest]
    }
}

/// Reloads after the page's WebContent process crashed: at most 3 a minute, then none until the popover opens.
struct CrashReloads {
    static let limit = 3, window: TimeInterval = 60
    private(set) var recent: [Date] = []

    mutating func allow(now: Date) -> Bool {
        recent = recent.filter { now.timeIntervalSince($0) < Self.window } + [now]
        return recent.count <= Self.limit
    }
}

enum SingleInstance {
    /// Another copy (say a Homebrew and a source install) is running: the one launched first stays, and when
    /// two start at the same moment the lower pid stays, so exactly one survives.
    static func shouldQuit(own: (pid: Int32, launched: Date?), running: [(pid: Int32, launched: Date?)]) -> Bool {
        running.contains { other in
            guard other.pid != own.pid else { return false }
            if let theirs = other.launched, let ours = own.launched, theirs != ours { return theirs < ours }
            return other.pid < own.pid
        }
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

/// "Also Use in Apps": the launchd user environment that apps opened from now on inherit, so they use the
/// Active accounts as new terminals do. Usagi only ever sets its own profile folders and profile names, so a
/// value of that shape is Usagi's (even if a quit or failure cut a change short) and anything else is someone
/// else's, which Usagi remembers when it replaces it and puts back when it undoes its own.
enum AppEnvironment {
    enum Target: Equatable { case value(String), unset }
    struct Change: Equatable { let name: String, value: String?, ours: Bool }

    static let enabledKey = "alsoUseInApps", previousKey = "appEnvironmentPrevious"
    /// Set before Usagi's first setenv and cleared once it has undone everything: until then, Usagi never
    /// touches launchd, so someone's own profile-shaped value is safe unless the option was used.
    static let inUseKey = "appEnvironmentInUse"
    static let providers = [("claude", "CLAUDE_CONFIG_DIR", ".claude", "CLAUDE"), ("codex", "CODEX_HOME", ".codex", "CODEX")]
    /// The shell hooks' tracking variables: a terminal app opened while a profile was set passes them to its
    /// new tabs, so usagi.zsh and Agent Kit's hook undo the inherited folder once the account is default again.
    static func trackers(_ key: String) -> [String] { ["_USAGI_\(key)_ACCOUNT", "_AGENTKIT_\(key)_ACCOUNT"] }
    static var variables: [String] { providers.flatMap { [$0.1] + trackers($0.3) } }

    /// The provider key ("CLAUDE", "CODEX") a variable belongs to, and whether it is the folder variable.
    static func owner(_ name: String) -> (key: String, folder: Bool)? {
        for (_, variable, _, key) in providers where ([variable] + trackers(key)).contains(name) { return (key, variable == name) }
        return nil
    }

    static func isUsagis(_ name: String, _ value: String, home: String) -> Bool {
        guard let owner = owner(name) else { return false }
        guard owner.folder else { return PageMessage.isAccount(value) }
        let folder = providers.first { $0.3 == owner.key }!.2
        let prefix = "\(home)/\(folder)-"
        return value.hasPrefix(prefix) && PageMessage.isAccount(String(value.dropFirst(prefix.count)))
    }

    /// Each variable's target: the Active profile's folder (and its name for the trackers), or unset for
    /// `default`. A provider missing from the snapshot, or a name that isn't a profile name, is left alone.
    static func wanted(_ snapshot: [String: Any], home: String) -> [String: Target] {
        let providers = snapshot["providers"] as? [String: Any] ?? [:]
        var targets: [String: Target] = [:]
        for (provider, variable, folder, key) in Self.providers {
            guard let active = (providers[provider] as? [String: Any])?["active"] as? String,
                  active == "default" || PageMessage.isAccount(active) else { continue }
            let profile = active != "default"
            targets[variable] = profile ? .value("\(home)/\(folder)-\(active)") : .unset
            for name in trackers(key) { targets[name] = profile ? .value(active) : .unset }
        }
        return targets
    }

    /// launchctl changes from `current` to `wanted` (nil when the option is off): set Usagi's value (`ours`), or
    /// undo Usagi's value by putting back the one it replaced (`previous`) or unsetting. Folders come first.
    static func changes(wanted: [String: Target]?, current: [String: String], previous: [String: String],
                        home: String) -> [Change] {
        var result: [Change] = []
        for variable in variables {
            let now = current[variable], ours = now.map { isUsagis(variable, $0, home: home) } ?? false
            switch wanted?[variable] {
            case .value(let value)? where now != value: result.append(Change(name: variable, value: value, ours: true))
            case .unset? where ours, nil where wanted == nil && ours:
                result.append(Change(name: variable, value: previous[variable], ours: false))
            default: break
            }
        }
        return result
    }
}
