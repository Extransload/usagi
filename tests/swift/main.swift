import Foundation

// Plain assertions over Sources/Logic.swift; run with tests/swift/run.sh.

var failures = 0, checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let fs = "\u{2007}"

// Version comparison
check(Version.newer("1.0.3", than: "1.0.2"), "patch bump")
check(Version.newer("1.10.0", than: "1.9.9"), "numeric, not lexical")
check(Version.newer("2", than: "1.9.9"), "shorter but higher")
check(!Version.newer("1.0", than: "1.0.0"), "missing parts count as 0")
check(!Version.newer("1.0.2", than: "1.0.2"), "same version")
check(!Version.newer("1.0.1", than: "1.0.2"), "older")
check(Version.newer("v1.0.3", than: "1.0.2"), "v prefix")
check(!Version.newer("1.0.3-beta", than: "1.0.3"), "suffix ignored")
equal(Version.parts("v1.2.3"), [1, 2, 3], "parts")

// Page messages
equal(PageMessage.parse(["action": "snapshot"]), .bridge(["snapshot", "--ask-shell"]), "refresh button asks the shell")
equal(PageMessage.parse(["action": "update"]), .bridge(["update"]), "update")
equal(PageMessage.parse(["action": "quit"]), .quit, "quit")
equal(PageMessage.parse(["action": "select", "provider": "claude", "account": "default"]),
      .bridge(["select", "claude", "default"]), "select default")
equal(PageMessage.parse(["action": "login", "provider": "codex", "account": "account-2"]),
      .bridge(["login", "codex", "account-2"]), "login")
equal(PageMessage.parse(["action": "remove", "provider": "codex", "account": "a" + String(repeating: "b", count: 30)]),
      .bridge(["remove", "codex", "a" + String(repeating: "b", count: 30)]), "31 characters")
equal(PageMessage.parse(["action": "add_auto", "provider": "claude"]), .bridge(["add_auto", "claude"]), "add_auto")
equal(PageMessage.parse(["action": "resize", "height": "300"]), .resize(300), "resize")
equal(PageMessage.parse(["action": "resize", "height": "1000"]), .resize(1000), "resize keeps a tall page")
equal(PageMessage.parse(["action": "resize", "height": "9000"]), .resize(4000), "resize clamps absurd heights")
equal(PopoverHeight.fit(700, available: 1000), 700, "fits on screen: no scrolling")
equal(PopoverHeight.fit(1200, available: 900), 876, "taller than the screen: scroll inside")
equal(PopoverHeight.fit(100, available: 900), 260, "minimum height")
equal(PopoverHeight.fit(700, available: 250), 250, "never taller than the screen")
equal(PopoverHeight.fit(700, available: nil), 540, "no screen known: old cap")
equal(PageMessage.parse(["action": "resize", "height": "12.5"]), .resize(260), "resize clamps low")
for bad: [String: Any] in [
    ["action": "add", "provider": "claude", "account": "x"],
    ["action": "login_worker", "provider": "claude", "account": "x"],
    ["action": "login_status", "provider": "claude", "account": "x"],
    ["action": "select", "provider": "gemini", "account": "default"],
    ["action": "select", "provider": "claude"],
    ["action": "select", "provider": "claude", "account": "-x"],
    ["action": "select", "provider": "claude", "account": "Upper"],
    ["action": "select", "provider": "claude", "account": "../x"],
    ["action": "select", "provider": "claude", "account": ""],
    ["action": "select", "provider": "claude", "account": "a" + String(repeating: "b", count: 31)],
    ["action": "select", "provider": "claude", "account": "é"],
    ["action": "add_auto"],
    ["action": "resize", "height": 300],
    ["action": "resize", "height": "nan"],
    ["action": "resize", "height": "inf"],
    ["action": "resize", "height": "tall"],
    ["action": "resize", "account": "300"],
    ["action": "snapshot", "extra": 1],
    ["action": 1],
    ["provider": "claude"],
] {
    check(PageMessage.parse(bad) == nil, "rejects \(bad)")
}
check(PageMessage.parse("snapshot") == nil, "rejects a non-object body")

// Menu bar
func account(_ id: String, _ windows: [String: Double]) -> [String: Any] {
    ["id": id, "windows": windows.mapValues { ["used_percent": $0] }]
}
let snapshot: [String: Any] = [
    "cards": [["provider": "claude", "id": "default"], ["provider": "codex", "id": "default"],
              ["provider": "codex", "id": "account-2"]],
    "providers": [
        "claude": ["accounts": [account("default", ["5h": 41.6, "7d": 17, "fable": 90])]],
        "codex": ["accounts": [account("default", ["30d": 12.4]), account("account-2", [:])]],
    ],
]
let menu = MenuBar.items(snapshot)
equal(menu, [MenuBarItem(provider: "claude", percent: 42), MenuBarItem(provider: "codex", percent: 12)],
      "one item per service: a second Codex account is not another service")
var activeSecond = snapshot
activeSecond["providers"] = [
    "claude": ["active": "default", "accounts": [account("default", ["5h": 41.6])]],
    "codex": ["active": "account-2", "accounts": [account("default", ["30d": 12.4]), account("account-2", ["5h": 70])]],
]
equal(MenuBar.items(activeSecond).last, MenuBarItem(provider: "codex", percent: 70), "the Active account's usage")
var hiddenActive = activeSecond
hiddenActive["cards"] = [["provider": "claude", "id": "default"], ["provider": "codex", "id": "default"]]
equal(MenuBar.items(hiddenActive).last, MenuBarItem(provider: "codex", percent: 12), "Active card hidden: first card")
var savedOrder = activeSecond
savedOrder["cards"] = [["provider": "codex", "id": "account-3"], ["provider": "codex", "id": "account-2"]]
savedOrder["providers"] = ["codex": ["active": "default", "accounts": [account("default", ["5h": 1]), account("account-2", ["5h": 20]), account("account-3", ["5h": 30])]]]
equal(MenuBar.items(savedOrder), [MenuBarItem(provider: "codex", percent: 20)], "fallback follows the page's order")
equal(MenuBar.items(snapshot, hidden: ["claude"]), [MenuBarItem(provider: "codex", percent: 12)], "a service turned off")
equal(MenuBar.items(snapshot, hidden: ["claude", "codex"]), [], "every service turned off")
equal(MenuBar.items(snapshot, hidden: ["gemini"]), menu, "an unknown name changes nothing")
var codexFirst = snapshot
codexFirst["cards"] = [["provider": "codex", "id": "default"], ["provider": "claude", "id": "default"]]
equal(MenuBar.order(codexFirst), ["codex", "claude"], "services in card order")
equal(MenuBar.services(codexFirst), ["codex", "claude"], "Settings lists services in card order")
equal(MenuBar.services(savedOrder), ["codex", "claude"], "then services without cards")
equal(MenuBar.services(nil), ["claude", "codex"], "before a snapshot: every service")
equal(MenuBar.hidden(migrating: 1, order: ["codex", "claude"]), ["claude"], "Menu Bar Shows 1: the rest are turned off")
equal(MenuBar.hidden(migrating: 2, order: ["codex", "claude"]), [], "Menu Bar Shows 2: nothing turned off")
equal(MenuBar.hidden(migrating: 0, order: ["codex", "claude"]), [], "Menu Bar Shows all")
equal(MenuBar.hidden(migrating: 5, order: ["claude"]), [], "a count above the services")
equal(MenuBar.hidden(migrating: 1, order: MenuBar.services(["cards": [["provider": "claude", "id": "default"]]])), ["codex"],
      "a service without cards yet stays off too")
equal(PageMessage.parse(["action": "reorder", "order": "codex,claude"]), .bridge(["reorder", "codex,claude"]), "reorder")
equal(PageMessage.parse(["action": "reorder", "order": "codex"]), .bridge(["reorder", "codex"]), "reorder one")
for bad in ["codex,codex", "gemini", "", "codex,", ",claude"] {
    equal(PageMessage.parse(["action": "reorder", "order": bad]), nil, "reorder rejects \(bad)")
}
equal(MenuBar.items(["cards": [], "providers": [:]]), [], "no cards")
equal(MenuBar.items(["cards": [["provider": "claude", "id": "gone"]], "providers": [:]]),
      [MenuBarItem(provider: "claude", percent: nil)], "missing account")
equal(MenuBar.usedPercent(["5h": ["used_percent": 3.0], "7d": ["used_percent": 55.0], "opus": ["used_percent": 99.0]]), 55,
      "5h/7d preferred over model windows")
equal(MenuBar.usedPercent(["30d": ["used_percent": 7.0], "fable": ["used_percent": 9.0]]), 9, "else any window")
equal(MenuBar.usedPercent(["5h": ["used_percent": "x"]]), nil, "non-numbers ignored")
equal(MenuBar.usedPercent([:]), nil, "no windows")
equal(MenuBar.clampPercent(.nan), nil, "nan")
equal(MenuBar.clampPercent(.infinity), nil, "infinity")
equal(MenuBar.clampPercent(-4), 0, "negative")
equal(MenuBar.clampPercent(12345), 999, "huge")
equal(MenuBar.clampPercent(99.5), 100, "rounds")
equal(MenuBar.percentText(5), fs + fs + "5%", "pads one digit")
equal(MenuBar.percentText(42), fs + "42%", "pads two digits")
equal(MenuBar.percentText(100), "100%", "three digits")
equal(MenuBar.percentText(nil), fs + fs + "–" + fs, "no data")
equal(MenuBar.percentText(5).count, MenuBar.percentText(nil).count, "same width with and without data")
equal(MenuBar.limitLabel("5h"), "5-hour", "label 5h")
equal(MenuBar.limitLabel("7d"), "Weekly", "label 7d")
equal(MenuBar.limitLabel("30d"), "30-day", "label 30d")
equal(MenuBar.limitLabel("12h"), "12-hour", "label 12h")
equal(MenuBar.limitLabel("fable"), "Fable weekly", "model window")
equal(MenuBar.limitLabel("claude_opus"), "Claude Opus weekly", "words split on _ - and spaces")
equal(MenuBar.limitOptions(snapshot, provider: "claude", stored: "auto").map(\.key), ["auto", "5h", "7d", "fable"], "options in order")
equal(MenuBar.limitOptions(snapshot, provider: "claude", stored: "opus").last,
      LimitOption(key: "opus", title: "Opus weekly (not reported now)"), "stored but missing")
equal(MenuBar.limitOptions(nil, provider: "codex", stored: "auto"),
      [LimitOption(key: "auto", title: "Higher of 5-hour and weekly")], "no snapshot yet")
equal(MenuBar.items(snapshot, limits: ["claude": "fable"]).first, MenuBarItem(provider: "claude", percent: 90), "chosen limit")
equal(MenuBar.items(snapshot, limits: ["claude": "opus"]).first, MenuBarItem(provider: "claude", percent: nil), "chosen limit missing: dash")
equal(MenuBar.limitOptions(activeSecond, provider: "codex", stored: "auto").map(\.key), ["auto", "5h"], "follows the Active account")
equal(MenuBar.shownPercent(42, remaining: true), 58, "remaining")
equal(MenuBar.shownPercent(42, remaining: false), 42, "used")
equal(MenuBar.shownPercent(120, remaining: true), 0, "never below 0")
equal(MenuBar.shownPercent(nil, remaining: true), nil, "no data stays no data")
equal(MenuBar.accessibilityLabel([MenuBarItem(provider: "claude", percent: 58)], stale: false, remaining: true),
      "Usagi: Claude 58% left", "a11y remaining")
check(!MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 16 * 60, refreshInterval: 900), "15 min refresh: not dim at 16 min")
check(MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 20 * 60 + 1, refreshInterval: 900), "but dim after 20 min")
check(MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 15 * 60 + 1, refreshInterval: 300), "5 min refresh keeps 15 min")
equal(MenuBar.accountNames(activeSecond, provider: "codex"), ["Account 1", "Account 2 (Active)"], "names without emails")
var withEmail = activeSecond
withEmail["providers"] = ["codex": ["active": "default", "accounts": [["id": "default", "email": "me@x.io"], ["id": "account-2"]]]]
equal(MenuBar.accountNames(withEmail, provider: "codex"), ["me@x.io (Active)", "Account 2"], "emails and the Active one")
equal(MenuBar.accountNames(nil, provider: "codex"), [], "no snapshot: no accounts")
equal(MenuBarStyle.TextSize.small.fontSize, 10, "small text")
equal(MenuBarStyle.TextSize.regular.fontSize, 11, "regular text")
equal(MenuBarStyle.TextSize.large.glyphSize, 16, "large logo")
equal(MenuBarStyle.limitKey("codex"), "menuBarLimit.codex", "limit key")
equal(Cadence.hiddenInterval(stored: nil), 300, "default interval")
equal(Cadence.hiddenInterval(stored: 900), 900, "15 min")
equal(Cadence.hiddenInterval(stored: 7), 300, "unknown value")
equal(Cadence.delay(since: nil, shown: false, now: t0, hidden: 900), 900, "custom hidden interval")
equal(Cadence.delay(since: nil, shown: true, now: t0, hidden: 900), 60, "open menu stays at 1 minute")
equal(MenuBar.accessibilityLabel(menu, stale: false), "Usagi: Claude 42%, Codex 12%", "a11y label")
equal(MenuBar.accessibilityLabel([MenuBarItem(provider: "codex", percent: nil)], stale: true),
      "Usagi: Codex no data (not up to date)", "a11y no data, stale")
equal(MenuBar.accessibilityLabel([], stale: false), "Usagi", "a11y without cards")

// Menu bar colors
let claudeDefault = RGB(red: 0xCC / 255.0, green: 0x7C / 255.0, blue: 0x5E / 255.0)
equal(RGB(hex: "#CC7C5E"), claudeDefault, "hex")
equal(RGB(hex: "cc7c5e"), claudeDefault, "lower case without #")
equal(RGB(hex: " #cc7c5e\n"), claudeDefault, "surrounding spaces")
for bad in ["", "#", "#CC7C5", "#CC7C5E0", "#CC7C5E00", "#GG0000", "red", "#+C7C5E", "# CC7C5E"] {
    equal(RGB(hex: bad), nil, "rejects \(bad.debugDescription)")
}
equal(claudeDefault.hex, "#CC7C5E", "back to hex")
equal(RGB(red: 1, green: 0, blue: 0.5).hex, "#FF0080", "rounds to the nearest step")
equal(RGB(red: 1.4, green: -0.2, blue: .nan).hex, "#FF0000", "out of range and nan are clamped")
let white = RGB(red: 1, green: 1, blue: 1), black = RGB(red: 0, green: 0, blue: 0)
check(abs(white.contrast(with: black) - 21) < 1e-9, "black on white")
check(abs(black.contrast(with: white) - 21) < 1e-9, "either way round")
check(abs(claudeDefault.contrast(with: claudeDefault) - 1) < 1e-9, "a color on itself")
equal(MenuBarStyle.color("claude", stored: nil), claudeDefault, "Claude's default")
equal(MenuBarStyle.color("codex", stored: nil), RGB(hex: "#49A3B0"), "Codex's default")
equal(MenuBarStyle.color("claude", stored: "#112233"), RGB(hex: "#112233"), "a stored color")
equal(MenuBarStyle.color("claude", stored: "junk"), claudeDefault, "an unreadable stored color falls back")
equal(MenuBarStyle.colorKey("codex"), "menuBarColor.codex", "UserDefaults key")
for provider in MenuBar.allServices {
    let color = MenuBarStyle.color(provider, stored: nil)
    check(MenuBarStyle.readable(color, dark: false) && MenuBarStyle.readable(color, dark: true), "\(provider)'s default reads on both bars")
}
let paleYellow = RGB(red: 1, green: 1, blue: 0.6), nearBlack = RGB(red: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x22 / 255.0)
check(!MenuBarStyle.readable(paleYellow, dark: false), "pale yellow is too faint on a light bar")
check(MenuBarStyle.readable(paleYellow, dark: true), "but reads on a dark bar")
check(!MenuBarStyle.readable(nearBlack, dark: true), "near black is too faint on a dark bar")
check(MenuBarStyle.readable(nearBlack, dark: false), "but reads on a light bar")
equal(MenuBarStyle.contrastWarning(claudeDefault), nil, "no warning for a color that reads everywhere")
equal(MenuBarStyle.contrastWarning(paleYellow), "Too faint on a light menu bar, so it's shown in black there.", "light bar")
equal(MenuBarStyle.contrastWarning(nearBlack), "Too faint on a dark menu bar, so it's shown in white there.", "dark bar")
equal(MenuBarStyle.contrastWarning(RGB(red: 0.5, green: 0.5, blue: 0.5)), nil, "mid gray reads on both bars")
equal(MenuBarStyle.paint(highlighted: false, stale: false, increaseContrast: false), .color, "fresh: in color")
equal(MenuBarStyle.paint(highlighted: true, stale: false, increaseContrast: false), .plain, "menu open: plain")
equal(MenuBarStyle.paint(highlighted: false, stale: false, increaseContrast: true), .plain, "Increase Contrast: plain")
equal(MenuBarStyle.paint(highlighted: false, stale: true, increaseContrast: false), .dimmed, "out of date: dimmed")
equal(MenuBarStyle.paint(highlighted: true, stale: true, increaseContrast: true), .dimmed, "out of date wins")

// Logo paths
typealias Step = SVGPath.Step
equal(SVGPath.steps("M1 2L3 4H5V6C1 2 3 4 5 6Z"),
      [Step.move(1, 2), .line(3, 4), .line(5, 4), .line(5, 6), .curve(1, 2, 3, 4, 5, 6), .close], "each command")
equal(SVGPath.steps("M1-2.5.5,4 6 7"), [Step.move(1, -2.5), .line(0.5, 4), .line(6, 7)],
      "packed numbers, commas, and pairs after M are lines")
equal(SVGPath.steps("M1 1L2 2ZH5V3"), [Step.move(1, 1), .line(2, 2), .close, .line(5, 1), .line(5, 3)],
      "after Z the pen is back at the start")
equal(SVGPath.steps("M0 0L1e1 2E-1"), [Step.move(0, 0), .line(10, 0.2)], "exponents")
for bad in ["", "L1 2", "M1", "M1 2L3", "m1 2", "M1 2Q3 4 5 6", "M1 2 x", "M1 2-", "M1 2C1 2 3 4 5", "M1 2L", "M1 2LL3 4", "MZ"] {
    equal(SVGPath.steps(bad), nil, "rejects \(bad.debugDescription)")
}
for (provider, data) in Glyphs.paths {
    let steps = SVGPath.steps(data) ?? []
    check(steps.count > 20, "\(provider)'s logo parses")
    check({ if case .move? = steps.first { return true }; return false }(), "\(provider)'s logo starts with a move")
    let inside = steps.allSatisfy { step in
        switch step {
        case .move(let x, let y), .line(let x, let y): return (0...100).contains(x) && (0...100).contains(y)
        case .curve(let a, let b, let c, let d, let x, let y): return [a, b, c, d, x, y].allSatisfy { (0...100).contains($0) }
        case .close: return true
        }
    }
    check(inside, "\(provider)'s logo stays inside its 100×100 box")
}
equal(Set(Glyphs.paths.keys), Set(MenuBar.allServices), "a logo for every service")
check(!MenuBar.isStale(lastSuccess: nil, failed: false, now: t0), "not stale before the first refresh")
check(MenuBar.isStale(lastSuccess: t0, failed: true, now: t0), "stale after a failure")
check(!MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 15 * 60), "fresh at 15 minutes")
check(MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 15 * 60 + 1), "stale after 15 minutes")
equal(MenuBar.tooltip(updated: "14:05", error: nil), "Usagi\nUpdated 14:05", "tooltip")
equal(MenuBar.tooltip(updated: nil, error: "Boom"), "Usagi\nNot updated yet\nBoom", "tooltip with error")

// Refresh cadence
equal(Cadence.delay(since: nil, shown: true, now: t0), 60, "shown")
equal(Cadence.delay(since: nil, shown: false, now: t0), 300, "hidden")
equal(Cadence.delay(since: t0, shown: false, now: t0 + 100), 200, "counts from the last refresh")
equal(Cadence.delay(since: t0, shown: true, now: t0 + 500), 1, "overdue")
equal(Cadence.delay(since: t0 + 50, shown: true, now: t0), 60, "clock went back")
check(Cadence.refreshOnOpen(since: nil, now: t0), "open without data")
check(!Cadence.refreshOnOpen(since: t0, now: t0 + 30), "open within 30 s")
check(Cadence.refreshOnOpen(since: t0, now: t0 + 31), "open after 30 s")

// Job queue
var queue = JobQueue()
check(queue.add(Job(arguments: ["snapshot"], origin: .background)), "background when idle")
equal(queue.start(), Job(arguments: ["snapshot"], origin: .background), "starts")
check(!queue.add(Job(arguments: ["login_status", "claude", "default"], origin: .background)), "background dropped while busy")
check(!queue.add(Job(arguments: ["snapshot"], origin: .user)), "identical to running is dropped")
equal(queue.running?.origin, .user, "running job now reports to the page")
check(queue.add(Job(arguments: ["snapshot"], origin: .followUp)) == false, "follow-up identical to running")
check(queue.add(Job(arguments: ["select", "claude", "a"], origin: .user)), "user queued")
check(queue.add(Job(arguments: ["login", "codex", "b"], origin: .followUp)), "follow-up queued")
check(queue.add(Job(arguments: ["remove", "claude", "a"], origin: .user)), "second user action")
check(!queue.add(Job(arguments: ["select", "claude", "a"], origin: .user)), "identical to queued is dropped")
equal(queue.waiting.map { $0.arguments[0] }, ["select", "remove", "login"], "users before follow-ups")
check(!queue.add(Job(arguments: ["login", "codex", "b"], origin: .user)), "promoted, not added")
equal(queue.waiting.map { $0.arguments[0] }, ["select", "remove", "login"], "promoted job joins the users")
equal(queue.waiting.last?.origin, .user, "promoted origin")
equal(queue.start(), nil, "one at a time")
equal(queue.finish()?.origin, .user, "finish returns the upgraded job")
equal(queue.start()?.arguments, ["select", "claude", "a"], "next user action")
_ = queue.finish()
_ = queue.start(); _ = queue.finish(); _ = queue.start(); _ = queue.finish()
check(!queue.isBusy, "drained")

// Refresh button (--ask-shell) and automatic snapshots are one job
queue = JobQueue()
_ = queue.add(Job(arguments: ["select", "claude", "a"], origin: .user)); _ = queue.start()
check(queue.add(Job(arguments: Job.refresh, origin: .followUp)), "plain snapshot queued")
check(!queue.add(Job(arguments: Job.userRefresh, origin: .user)), "refresh button joins the queued snapshot")
equal(queue.waiting, [Job(arguments: Job.userRefresh, origin: .user)], "queued snapshot becomes the refresh button's")
check(!queue.add(Job(arguments: Job.refresh, origin: .followUp)), "plain snapshot joins the refresh button's")
equal(queue.waiting.first?.arguments, Job.userRefresh, "still asks the shell")
_ = queue.finish(); _ = queue.start()
check(!queue.add(Job(arguments: Job.refresh, origin: .background)), "running refresh-button snapshot absorbs a background one")
_ = queue.finish()
_ = queue.add(Job(arguments: Job.refresh, origin: .background)); _ = queue.start()
check(!queue.add(Job(arguments: Job.userRefresh, origin: .user)), "refresh button while a plain snapshot runs")
equal(queue.running, Job(arguments: Job.refresh, origin: .user), "the running snapshot reports back")
_ = queue.finish()

// Held-back actionDone reports move with the job they were attached to
let loginDone = ActionDone(["login", "claude", "a"], ok: true)
_ = queue.add(Job(arguments: ["select", "claude", "a"], origin: .user)); _ = queue.start()
check(queue.add(Job(arguments: Job.userRefresh, origin: .user)), "refresh queued")
check(!queue.add(Job(arguments: Job.refresh, origin: .followUp, reports: [loginDone])), "sign-in follow-up joins it")
equal(queue.waiting.first?.reports, [loginDone], "report waits on the queued snapshot")
_ = queue.finish(); _ = queue.start()
check(!queue.add(Job(arguments: Job.refresh, origin: .followUp, reports: [ActionDone(["login", "codex", "b"], ok: true)])),
      "follow-up joins the running snapshot")
equal(queue.finish()?.reports.map { $0.provider }, ["claude", "codex"], "finished job carries both reports")
_ = queue.add(Job(arguments: Job.refresh, origin: .followUp)); _ = queue.start()
_ = queue.add(Job(arguments: ["remove", "claude", "a"], origin: .user))
check(!queue.add(Job(arguments: Job.userRefresh, origin: .user, reports: [loginDone])) && queue.running?.reports == [loginDone],
      "reports join a running job")
check(queue.add(Job(arguments: Job.refresh, origin: .followUp, reports: [loginDone])) == false, "dropped as a duplicate")
equal(queue.running?.reports.count, 2, "but its report is kept")
check(!queue.add(Job(arguments: ["remove", "claude", "a"], origin: .followUp, reports: [loginDone]))
      && queue.waiting.first?.reports == [loginDone], "reports join a queued user job")

// actionDone payload
equal(ActionDone(Job.userRefresh, ok: true), ActionDone(["snapshot"], ok: true), "options left out")
let done = ActionDone(["login", "codex", "account-2"], ok: false)
equal([done.action, done.provider, done.account], ["login", "codex", "account-2"], "fields")
check(done.json["ok"] as? Bool == false && ActionDone(["update"], ok: true).json["provider"] is NSNull, "json")

// Login watches
var watches = LoginWatches()
let claude = AccountKey(provider: "claude", account: "default"), codex = AccountKey(provider: "codex", account: "account-2")
func connecting(_ pairs: [(String, String, Bool)]) -> [String: Any] {
    var providers: [String: [[String: Any]]] = [:]
    for (provider, id, flag) in pairs { providers[provider, default: []].append(["id": id, "connecting": flag]) }
    return ["providers": providers.mapValues { ["accounts": $0] }]
}
watches.start(claude, now: t0)
check(watches.isActive(now: t0), "active after login")
equal(watches.due(now: t0), nil, "not due before 3 s")
equal(watches.due(now: t0 + 1.9), nil, "not due well before 3 s")
equal(watches.due(now: t0 + 3), claude, "due at 3 s")
equal(watches.due(now: t0 + 4), nil, "polled, next in 3 s")
watches.reconcile(connecting([("claude", "default", true), ("codex", "account-2", true)]), now: t0 + 4)
equal(watches.watches[claude]?.started, t0, "reconcile keeps the start time")
equal(watches.due(now: t0 + 7), claude, "both due: the earliest scheduled first")
equal(watches.due(now: t0 + 7.5), codex, "then the other")
check(!watches.status(claude, connecting: true, now: t0 + 8), "still connecting: no snapshot")
check(watches.status(claude, connecting: nil, now: t0 + 8), "failure asks for a snapshot")
equal(watches.due(now: t0 + 11), codex, "failed account backs off")
check(watches.status(codex, connecting: false, now: t0 + 12), "stopped connecting: snapshot")
equal(watches.watches[codex], nil, "and stops polling it")
check(!watches.status(codex, connecting: false, now: t0 + 13), "unknown account: nothing")
watches.reconcile(connecting([("codex", "account-2", false)]), now: t0 + 14)
equal(watches.watches.count, 0, "account gone from the snapshot stops polling")
check(!watches.isActive(now: t0 + 14), "inactive")
watches.reconcile(connecting([("codex", "default", true)]), now: t0)
check(watches.isActive(now: t0 + 659), "within 11 minutes")
check(!watches.isActive(now: t0 + 660), "gives up after 11 minutes")
equal(watches.due(now: t0 + 700), nil, "no polling after giving up")
watches.reconcile(connecting([("codex", "default", true)]), now: t0 + 700)
check(!watches.isActive(now: t0 + 700), "a later snapshot doesn't restart it")

var early = LoginWatches()
early.start(claude, now: t0)
var polls: [Date] = []
for tick in 1...6 {  // a 3 s timer whose fires drift a little either way
    let now = t0 + Double(tick) * 3 + (tick % 2 == 0 ? -0.2 : 0.3)
    if early.due(now: now) != nil { polls.append(now) }
}
equal(polls.count, 6, "every 3 s tick polls, even one a little early")

// Crash reloads
var reloads = CrashReloads()
check(reloads.allow(now: t0) && reloads.allow(now: t0 + 10) && reloads.allow(now: t0 + 20), "three a minute")
check(!reloads.allow(now: t0 + 30), "not a fourth")
check(!reloads.allow(now: t0 + 61), "still three within the last minute")
check(reloads.allow(now: t0 + 200), "allowed again later")

// Single instance
let firstLaunch = Date(timeIntervalSince1970: 1_000), laterLaunch = Date(timeIntervalSince1970: 2_000)
check(!SingleInstance.shouldQuit(own: (10, laterLaunch), running: [(10, laterLaunch)]), "only this copy")
check(!SingleInstance.shouldQuit(own: (10, laterLaunch), running: []), "not listed yet")
check(SingleInstance.shouldQuit(own: (10, laterLaunch), running: [(70, firstLaunch), (10, laterLaunch)]), "an older copy runs")
check(!SingleInstance.shouldQuit(own: (10, firstLaunch), running: [(7, laterLaunch), (10, firstLaunch)]), "a newer copy quits instead")
check(SingleInstance.shouldQuit(own: (10, laterLaunch), running: [(7, laterLaunch), (10, laterLaunch)]), "same moment: lower pid stays")
check(!SingleInstance.shouldQuit(own: (7, laterLaunch), running: [(7, laterLaunch), (10, laterLaunch)]), "same moment: this lower pid stays")
check(SingleInstance.shouldQuit(own: (10, nil), running: [(7, nil), (10, nil)]), "no launch dates: lower pid stays")

// Update check schedule
var updates = UpdateSchedule()
check(updates.begin(now: t0), "first check")
check(!updates.begin(now: t0), "one at a time")
updates.finish(success: false, now: t0)
check(!updates.begin(now: t0 + 29 * 60), "backs off after a failure")
check(updates.begin(now: t0 + 30 * 60), "retries after 30 minutes")
updates.finish(success: true, now: t0 + 30 * 60)
check(!updates.begin(now: t0 + 30 * 60 + 5 * 3600), "6 hours after a success")
check(updates.begin(now: t0 + 30 * 60 + 6 * 3600), "then checks again")

// PNG and bridge errors
check(PNG.hasSignature(Data(PNG.signature + [0, 1])), "png signature")
check(!PNG.hasSignature(Data("<html>".utf8)), "html is not png")
check(!PNG.hasSignature(Data(PNG.signature.prefix(4))), "short data")
equal(BridgeOutput.errorMessage(stdout: Data(#"{"error": "Unknown account", "code": "x"}"#.utf8), stderr: Data(), status: 1),
      "Unknown account", "bridge error")
equal(BridgeOutput.errorMessage(stdout: Data(), stderr: Data("Traceback\n  File x\nValueError: bad\n\n".utf8), status: 1),
      "ValueError: bad", "last stderr line")
equal(BridgeOutput.errorMessage(stdout: Data("oops".utf8), stderr: Data(), status: 2),
      "The usage reader failed (exit status 2).", "fallback")

// Update status for the page's footer, and checks the user asks for
let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
equal(UpdateStatus.info(latest: "1.0.4", current: "1.0.3", now: checkedAt),
      ["current": "1.0.3", "version": "1.0.4", "checked_at": "1800000000"], "newer release → banner")
equal(UpdateStatus.info(latest: "1.0.3", current: "1.0.3", now: checkedAt),
      ["current": "1.0.3", "latest": "1.0.3", "checked_at": "1800000000"], "same version → up to date")
equal(UpdateStatus.info(latest: "1.0.2", current: "1.0.3", now: checkedAt),
      ["current": "1.0.3", "latest": "1.0.2", "checked_at": "1800000000"], "older release → up to date")
equal(UpdateStatus.info(latest: nil, current: "1.0.3", now: checkedAt), ["current": "1.0.3", "failed": "true"], "failed check")
check(PageMessage.parse(["action": "check_update"]) == .checkUpdates, "page asks for a check")
var asked = UpdateSchedule()
check(asked.begin(now: checkedAt), "first check")
asked.finish(success: true, now: checkedAt)
check(!asked.begin(now: checkedAt + 60), "waits 6 h")
check(asked.begin(now: checkedAt + 60, force: true), "the user can check now")
check(!asked.begin(now: checkedAt + 61, force: true), "but not twice at once")

// Reordering: the newest order wins
var orders = JobQueue()
func reorder(_ order: String) -> Job { Job(arguments: ["reorder", order], origin: .user) }  // as the page's messages are queued
orders.add(reorder("codex,claude"))
_ = orders.start()
orders.add(reorder("claude,codex"))
orders.add(reorder("codex,claude"))
equal(orders.waiting.map(\.arguments), [["reorder", "codex,claude"]], "one waiting reorder: the newest, not merged into the running one")

// Also Use in Apps
func pairs(_ list: [AppEnvironment.Change]) -> [String] { list.map { "\($0.name)=\($0.value ?? "<unset>")\($0.ours ? "" : " (undo)")" } }
func changes(_ wanted: [String: AppEnvironment.Target]?, _ current: [String: String], _ previous: [String: String] = [:]) -> [String] {
    pairs(AppEnvironment.changes(wanted: wanted, current: current, previous: previous, home: "/Users/me"))
}
let me = "/Users/me", codex2 = "/Users/me/.codex-account-2"
let envSnapshot: [String: Any] = ["providers": ["claude": ["active": "default"], "codex": ["active": "account-2"]]]
let wanted = AppEnvironment.wanted(envSnapshot, home: me)
equal(wanted["CLAUDE_CONFIG_DIR"], .unset, "default is unset")
equal(wanted["CODEX_HOME"], .value(codex2), "profile folder")
equal(wanted["_USAGI_CODEX_ACCOUNT"], .value("account-2"), "usagi.zsh tracker")
equal(wanted["_AGENTKIT_CODEX_ACCOUNT"], .value("account-2"), "Agent Kit tracker")
equal(wanted["_AGENTKIT_CLAUDE_ACCOUNT"], .unset, "trackers unset for default")
check(AppEnvironment.wanted(["providers": ["claude": ["active": "../x"]]], home: "/h").isEmpty, "bad names are left alone")
check(AppEnvironment.wanted(["providers": [:]], home: "/h").isEmpty, "missing providers are left alone")
check(AppEnvironment.isUsagis("CODEX_HOME", codex2, home: me), "a profile folder is Usagi's")
check(!AppEnvironment.isUsagis("CODEX_HOME", "/custom", home: me), "another folder is someone else's")
check(!AppEnvironment.isUsagis("CODEX_HOME", "/Users/me/.codex-../x", home: me), "not a profile name")
check(!AppEnvironment.isUsagis("CLAUDE_CONFIG_DIR", codex2, home: me), "another service's folder")
check(AppEnvironment.isUsagis("_AGENTKIT_CLAUDE_ACCOUNT", "work", home: me), "a tracker holding a name")
let codexSet = ["CODEX_HOME=\(codex2)", "_USAGI_CODEX_ACCOUNT=account-2", "_AGENTKIT_CODEX_ACCOUNT=account-2"]
equal(changes(wanted, [:]), codexSet, "set the profile and trackers")
let codexNow = ["CODEX_HOME": codex2, "_USAGI_CODEX_ACCOUNT": "account-2", "_AGENTKIT_CODEX_ACCOUNT": "account-2"]
equal(changes(wanted, codexNow), [], "already set")
let claudeWork = ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "_USAGI_CLAUDE_ACCOUNT": "work", "_AGENTKIT_CLAUDE_ACCOUNT": "work"]
equal(changes(wanted, codexNow.merging(claudeWork) { $1 }),
      ["CLAUDE_CONFIG_DIR=<unset> (undo)", "_USAGI_CLAUDE_ACCOUNT=<unset> (undo)", "_AGENTKIT_CLAUDE_ACCOUNT=<unset> (undo)"],
      "back to default undoes Usagi's values")
equal(changes(wanted, codexNow.merging(["CLAUDE_CONFIG_DIR": "/mine"]) { $1 }), [], "default leaves someone else's value")
equal(changes(nil, codexNow, ["CODEX_HOME": "/custom"]),
      ["CODEX_HOME=/custom (undo)", "_USAGI_CODEX_ACCOUNT=<unset> (undo)", "_AGENTKIT_CODEX_ACCOUNT=<unset> (undo)"],
      "turning it off puts back what Usagi replaced")
equal(changes(nil, ["CODEX_HOME": "/changed"]), [], "someone else's value is never undone")
equal(changes(wanted, ["CODEX_HOME": "/Users/me/.codex-old"]).first, "CODEX_HOME=\(codex2)", "a stale Usagi folder is simply replaced")
equal(changes(nil, ["CODEX_HOME": "/Users/me/.codex-old"]), ["CODEX_HOME=<unset> (undo)"], "and undone when off, even if unrecorded")

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
