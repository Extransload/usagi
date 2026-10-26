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
    static let allServices = ["claude", "codex"]
    static let staleAfter: TimeInterval = 15 * 60
    static let figureSpace = "\u{2007}"

    static let hiddenKey = "menuBarHidden"  // UserDefaults: the services turned off in Settings
    /// The old "Menu Bar Shows" count (1, 2, … or 0 for all), read once to turn the services past it off.
    static let serviceLimitKey = "menuBarServices"

    /// The services with cards, in card order.
    static func order(_ snapshot: [String: Any]) -> [String] {
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        var order: [String] = []
        for case let provider? in cards.map({ $0["provider"] as? String }) where !order.contains(provider) {
            order.append(provider)
        }
        return order
    }

    /// Settings lists every service: those with cards in card order, then the rest.
    static func services(_ snapshot: [String: Any]?) -> [String] {
        let shown = snapshot.map(order) ?? []
        return shown + allServices.filter { !shown.contains($0) }
    }

    /// The old "Menu Bar Shows" count as switches: the services past it, in card order, are turned off.
    static func hidden(migrating limit: Int, order: [String]) -> Set<String> {
        limit > 0 ? Set(order.dropFirst(limit)) : []
    }

    static let autoLimit = "auto", autoLimitTitle = "Higher of 5-hour and weekly"

    /// The account the menu bar uses for a service: the Active account when its card is shown, else the first
    /// shown card in the page's order (the accounts list is sorted). The snapshot's account entry, or nil.
    static func menuBarAccount(_ snapshot: [String: Any], provider: String) -> [String: Any]? {
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        let info = (snapshot["providers"] as? [String: Any])?[provider] as? [String: Any] ?? [:]
        let shown = cards.filter { $0["provider"] as? String == provider }.compactMap { $0["id"] as? String }
        let accounts = info["accounts"] as? [[String: Any]] ?? []
        let id = (info["active"] as? String).flatMap { shown.contains($0) ? $0 : nil }
            ?? accounts.compactMap { $0["id"] as? String }.first(where: shown.contains) ?? shown.first
        return accounts.first { $0["id"] as? String == id }
    }

    /// A limit's name, as the cards show it (windowLabel in index.html): "5-hour", "Weekly", "30-day", "Fable weekly".
    static func limitLabel(_ key: String) -> String {
        if key == "5h" { return "5-hour" }
        if key == "7d" { return "Weekly" }
        let count = key.dropLast()
        if let unit = key.last, unit == "d" || unit == "h", !count.isEmpty, count.allSatisfy({ ("0"..."9").contains($0) }),
           let number = Int(count) {
            return "\(number)-\(unit == "d" ? "day" : "hour")"
        }
        let words = key.split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") + " weekly"
    }

    /// A service's "Limit shown" choices: automatic, then the limits its menu bar account reports (5-hour, weekly,
    /// then the rest by key), then a stored choice that isn't reported now.
    static func limitOptions(_ snapshot: [String: Any]?, provider: String, stored: String) -> [LimitOption] {
        let windows = snapshot.flatMap { menuBarAccount($0, provider: provider)?["windows"] as? [String: Any] } ?? [:]
        func rank(_ key: String) -> Int { key == "5h" ? 0 : key == "7d" ? 1 : 2 }
        let keys = windows.filter { $0.value is [String: Any] }.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        var options = [LimitOption(key: autoLimit, title: autoLimitTitle)] + keys.map { LimitOption(key: $0, title: limitLabel($0)) }
        if stored != autoLimit && !keys.contains(stored) {
            options.append(LimitOption(key: stored, title: limitLabel(stored) + " (not reported now)"))
        }
        return options
    }

    /// The usage the menu bar shows for a limit choice; nil (a dash) when the chosen limit isn't reported.
    static func percent(_ windows: [String: Any], limit: String) -> Int? {
        guard limit != autoLimit else { return usedPercent(windows).flatMap(clampPercent) }
        return ((windows[limit] as? [String: Any])?["used_percent"] as? Double).flatMap(clampPercent)
    }

    /// "Show percentages as Remaining" turns usage into what is left, never below 0.
    static func shownPercent(_ percent: Int?, remaining: Bool) -> Int? {
        percent.map { remaining ? max(0, 100 - $0) : $0 }
    }

    /// A service's accounts in card order, named as the cards name them, the Active one marked.
    static func accountNames(_ snapshot: [String: Any]?, provider: String) -> [String] {
        guard let snapshot else { return [] }
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        let info = (snapshot["providers"] as? [String: Any])?[provider] as? [String: Any] ?? [:]
        let accounts = info["accounts"] as? [[String: Any]] ?? []
        return cards.filter { $0["provider"] as? String == provider }.compactMap { $0["id"] as? String }.map { id in
            let email = accounts.first { $0["id"] as? String == id }?["email"] as? String
            let slot = id == "default" ? "Account 1" : id.hasPrefix("account-") ? "Account " + id.dropFirst(8) : id
            let name = email.flatMap { $0.isEmpty ? nil : $0 } ?? slot
            return info["active"] as? String == id ? name + " (Active)" : name
        }
    }

    /// One item per service turned on, in card order, from its menu bar account and its chosen limit.
    static func items(_ snapshot: [String: Any], hidden: Set<String> = [], limits: [String: String] = [:]) -> [MenuBarItem] {
        order(snapshot).filter { !hidden.contains($0) }.map { provider in
            let windows = menuBarAccount(snapshot, provider: provider)?["windows"] as? [String: Any] ?? [:]
            return MenuBarItem(provider: provider, percent: percent(windows, limit: limits[provider] ?? autoLimit))
        }
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

    /// `items` carry the percentages as shown (see shownPercent).
    static func accessibilityLabel(_ items: [MenuBarItem], stale: Bool, remaining: Bool = false) -> String {
        let parts = items.map { "\(names[$0.provider] ?? $0.provider) \($0.percent.map { "\($0)%\(remaining ? " left" : "")" } ?? "no data")" }
        return "Usagi" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")) + (stale ? " (not up to date)" : "")
    }

    /// Out of date after 15 minutes, or 5 minutes past the refresh interval when that is longer.
    static func isStale(lastSuccess: Date?, failed: Bool, now: Date, refreshInterval: TimeInterval = Cadence.hidden) -> Bool {
        failed || lastSuccess.map { now.timeIntervalSince($0) > max(staleAfter, refreshInterval + 5 * 60) } ?? false
    }

    static func tooltip(updated: String?, error: String?) -> String {
        (["Usagi", updated.map { "Updated \($0)" } ?? "Not updated yet"] + [error].compactMap { $0 })
            .joined(separator: "\n")
    }
}

/// One choice in a service's "Limit shown" list: "auto" or a window key, with its title.
struct LimitOption: Equatable {
    var key: String
    var title: String
}

/// An sRGB color, each component 0…1.
struct RGB: Equatable {
    var red: Double, green: Double, blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#CC7C5E", with or without the "#", in either case; spaces around it are ignored.
    init?(hex text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : Substring(trimmed)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        "#" + [red, green, blue].map { String(format: "%02X", Int((min(1, max(0, $0.isNaN ? 0 : $0)) * 255).rounded())) }
            .joined()
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 (none) to 21 (black on white).
    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Settings: each service's color, drawn on its logo and percentage in the menu bar.
enum MenuBarStyle {
    enum Paint: Equatable { case color, plain, dimmed }

    static let defaultColors = ["claude": RGB(red: 0xCC / 255.0, green: 0x7C / 255.0, blue: 0x5E / 255.0),
                                "codex": RGB(red: 0x49 / 255.0, green: 0xA3 / 255.0, blue: 0xB0 / 255.0)]
    /// Conservative stand-ins for the menu bar behind the item (85% gray when light, 25% when dark), as in CodexBar.
    static let lightBar = RGB(red: 0.85, green: 0.85, blue: 0.85), darkBar = RGB(red: 0.25, green: 0.25, blue: 0.25)
    static let minimumContrast = 2.0

    static func colorKey(_ provider: String) -> String { "menuBarColor.\(provider)" }

    static let textSizeKey = "menuBarTextSize", showsLogosKey = "menuBarShowsLogos", showsRemainingKey = "menuBarShowsRemaining"

    enum TextSize: String, CaseIterable {
        case small, regular, large

        var fontSize: Double { self == .small ? 10 : self == .regular ? 11 : 13 }
        var glyphSize: Double { self == .small ? 12 : self == .regular ? 14 : 16 }
    }

    static func limitKey(_ provider: String) -> String { "menuBarLimit.\(provider)" }

    /// The stored "#RRGGBB", else the service's default.
    static func color(_ provider: String, stored: String?) -> RGB {
        stored.flatMap(RGB.init(hex:)) ?? defaultColors[provider] ?? RGB(red: 0.5, green: 0.5, blue: 0.5)
    }

    /// Whether the color stands out from a light or dark menu bar; where it doesn't, the plain label color is used.
    static func readable(_ color: RGB, dark: Bool) -> Bool {
        color.contrast(with: dark ? darkBar : lightBar) >= minimumContrast
    }

    /// Shown under a color in Settings. With these two bars and 2:1, no color is too faint on both.
    static func contrastWarning(_ color: RGB) -> String? {
        if !readable(color, dark: false) { return "Too faint on a light menu bar, so it's shown in black there." }
        if !readable(color, dark: true) { return "Too faint on a dark menu bar, so it's shown in white there." }
        return nil
    }

    /// Plain while a menu is open (the highlight would swallow the colors) or Increase Contrast is on, dimmed while
    /// the numbers are out of date, else each service in its color.
    static func paint(highlighted: Bool, stale: Bool, increaseContrast: Bool) -> Paint {
        if stale { return .dimmed }
        return highlighted || increaseContrast ? .plain : .color
    }
}

/// SVG path data limited to the absolute M, L, H, V, C and Z commands the logos use.
enum SVGPath {
    enum Step: Equatable {
        case move(Double, Double), line(Double, Double), curve(Double, Double, Double, Double, Double, Double), close
    }

    /// The steps, or nil for anything else (relative or other commands, missing or stray numbers).
    static func steps(_ data: String) -> [Step]? {
        var scanner = Scanner(Array(data.unicodeScalars))
        var steps: [Step] = [], command: Unicode.Scalar?
        var pen = (x: 0.0, y: 0.0), start = pen
        var bare = false  // a command letter still waiting for its numbers
        while scanner.skipSeparators() {
            if let letter = scanner.letter() {
                guard !bare else { return nil }
                bare = letter != "Z"
                command = letter
                if letter == "Z" {
                    steps.append(.close)
                    pen = start
                    command = nil
                }
                continue
            }
            switch command {
            case "M", "L":
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                steps.append(command == "M" ? .move(x, y) : .line(x, y))
                if command == "M" { start = (x, y) }
                pen = (x, y)
                command = "L"  // more pairs after M are lines
            case "H":
                guard let x = scanner.number() else { return nil }
                pen.x = x
                steps.append(.line(pen.x, pen.y))
            case "V":
                guard let y = scanner.number() else { return nil }
                pen.y = y
                steps.append(.line(pen.x, pen.y))
            case "C":
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(),
                      let d = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return nil }
                steps.append(.curve(a, b, c, d, x, y))
                pen = (x, y)
            default:
                return nil
            }
            bare = false
        }
        guard !bare, case .move? = steps.first else { return nil }
        return steps
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        /// Skips spaces and commas; false at the end.
        mutating func skipSeparators() -> Bool {
            while index < scalars.count, [" ", ",", "\n", "\t", "\r"].contains(scalars[index]) { index += 1 }
            return index < scalars.count
        }

        /// A supported command letter; any other letter is left for `number` to reject.
        mutating func letter() -> Unicode.Scalar? {
            guard ["M", "L", "H", "V", "C", "Z"].contains(scalars[index]) else { return nil }
            defer { index += 1 }
            return scalars[index]
        }

        /// A number such as 12, -3.5, .5 or 1e-2; "1-2" and "1.5.5" are two numbers each.
        mutating func number() -> Double? {
            guard skipSeparators() else { return nil }
            let begin = index
            func digits() -> Int {
                let from = index
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
                return index - from
            }
            if ["+", "-"].contains(scalars[index]) { index += 1 }
            var count = digits()
            if index < scalars.count, scalars[index] == "." {
                index += 1
                count += digits()
            }
            guard count > 0 else { return nil }
            if index < scalars.count, ["e", "E"].contains(scalars[index]) {
                index += 1
                if index < scalars.count, ["+", "-"].contains(scalars[index]) { index += 1 }
                guard digits() > 0 else { return nil }
            }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[begin..<index])
            return Double(text)
        }
    }
}

enum LimitAlerts {
    struct Reading: Equatable {
        var used: Double
        var resetsAt: Double?
        var reset: Bool
    }

    struct Record: Codable, Equatable {
        var used: Double
        var resetsAt: Double?
        var seen: Double
    }

    enum Alert: Equatable { case crossed(Int), usedUp, reset }

    struct Options: Equatable {
        var thresholds: [Int]
        var usedUp: Bool
        var reset: Bool
    }

    static let defaultThresholds = [80, 95], thresholdChoices = [50, 60, 70, 80, 90, 95]
    static let keepFor: TimeInterval = 35 * 86400, newCycleSlack = 60.0
    static let stateKey = "notifyState", thresholdsKey = "notifyThresholds", usedUpKey = "notifyUsedUp", resetKey = "notifyReset"

    /// Each service's menu bar account, every limit it reports, keyed "<provider>|<account id>|<window key>". Services
    /// switched off in the menu bar are included.
    static func readings(_ snapshot: [String: Any]) -> [String: Reading] {
        var readings: [String: Reading] = [:]
        for provider in MenuBar.order(snapshot) {
            guard let account = MenuBar.menuBarAccount(snapshot, provider: provider), let id = account["id"] as? String else { continue }
            for case let (window, value as [String: Any]) in account["windows"] as? [String: Any] ?? [:] {
                guard let used = value["used_percent"] as? Double, used.isFinite else { continue }
                readings["\(provider)|\(id)|\(window)"] = Reading(used: used, resetsAt: value["resets_at"] as? Double,
                                                                   reset: value["reset"] as? Bool == true)
            }
        }
        return readings
    }

    /// What one limit's new reading calls for, and what to remember. Alerts only on crossings seen while running (a
    /// limit seen for the first time is just recorded), at most one per reading: the highest step crossed, else a reset.
    static func evaluate(_ previous: Record?, _ reading: Reading, options: Options, now: Date) -> (alert: Alert?, record: Record) {
        let seen = now.timeIntervalSince1970
        guard let previous else { return (nil, Record(used: reading.used, resetsAt: reading.resetsAt, seen: seen)) }
        if reading.reset {  // Claude's "Reset" until Claude Code reports the new cycle
            return (previous.used > 0 && options.reset ? .reset : nil, Record(used: 0, resetsAt: nil, seen: seen))
        }
        var newCycle = false
        if let before = previous.resetsAt, let after = reading.resetsAt { newCycle = after > before + newCycleSlack }
        let base = newCycle ? 0 : previous.used
        let steps = options.thresholds.filter { $0 > 0 } + (options.usedUp ? [100] : [])
        let alert: Alert?
        if let step = steps.filter({ base < Double($0) && Double($0) <= reading.used }).max() {
            alert = step == 100 && options.usedUp ? .usedUp : .crossed(step)
        } else {
            alert = newCycle && previous.used > 0 && options.reset ? .reset : nil
        }
        // An older source never moves the cycle back.
        let resetsAt = newCycle ? reading.resetsAt : [previous.resetsAt, reading.resetsAt].compactMap { $0 }.max()
        return (alert, Record(used: reading.used, resetsAt: resetsAt, seen: seen))
    }

    static func prune(_ records: [String: Record], now: Date) -> [String: Record] {
        records.filter { now.timeIntervalSince1970 - $0.value.seen <= keepFor }
    }

    static func text(_ alert: Alert, key: String) -> (title: String, body: String) {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let name = parts.first.map { MenuBar.names[$0] ?? $0 } ?? "Usagi"
        let limit = "\(name) \(MenuBar.limitLabel(parts.last ?? "")) limit"
        switch alert {
        case .crossed(let step): return ("\(limit) at \(step)%", "\(step)% of this limit is used.")
        case .usedUp: return ("\(limit) used up", "This limit is used up until it resets.")
        case .reset: return ("\(limit) reset", "This limit is available again.")
        }
    }
}

enum Cadence {
    static let shown: TimeInterval = 60, hidden: TimeInterval = 300, onOpen: TimeInterval = 30

    /// Settings > General offers these refresh intervals for while the menu is closed.
    static let hiddenChoices: [TimeInterval] = [60, 120, 300, 900]
    static let intervalKey = "refreshInterval"

    static func hiddenInterval(stored: Int?) -> TimeInterval {
        stored.map(TimeInterval.init).flatMap { hiddenChoices.contains($0) ? $0 : nil } ?? hidden
    }

    static func delay(since last: Date?, shown: Bool, now: Date, hidden: TimeInterval = Cadence.hidden) -> TimeInterval {
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
