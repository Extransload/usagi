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
equal(menu.items, [MenuBarItem(provider: "claude", percent: 42), MenuBarItem(provider: "codex", percent: 12)], "items")
equal(menu.more, 0, "a second Codex account is not another service")
var activeSecond = snapshot
activeSecond["providers"] = [
    "claude": ["active": "default", "accounts": [account("default", ["5h": 41.6])]],
    "codex": ["active": "account-2", "accounts": [account("default", ["30d": 12.4]), account("account-2", ["5h": 70])]],
]
equal(MenuBar.items(activeSecond).items.last, MenuBarItem(provider: "codex", percent: 70), "the Active account's usage")
var hiddenActive = activeSecond
hiddenActive["cards"] = [["provider": "claude", "id": "default"], ["provider": "codex", "id": "default"]]
equal(MenuBar.items(hiddenActive).items.last, MenuBarItem(provider: "codex", percent: 12), "Active card hidden: first card")
var savedOrder = activeSecond
savedOrder["cards"] = [["provider": "codex", "id": "account-3"], ["provider": "codex", "id": "account-2"]]
savedOrder["providers"] = ["codex": ["active": "default", "accounts": [account("default", ["5h": 1]), account("account-2", ["5h": 20]), account("account-3", ["5h": 30])]]]
equal(MenuBar.items(savedOrder).items, [MenuBarItem(provider: "codex", percent: 20)], "fallback follows the page's order")
equal(MenuBar.items(snapshot, limit: 1).items, [MenuBarItem(provider: "claude", percent: 42)], "limit 1")
equal(MenuBar.items(snapshot, limit: 1).more, 1, "one service left out")
equal(MenuBar.items(snapshot, limit: nil).items.count, 2, "all services")
equal(MenuBar.serviceLimit(stored: nil), 2, "default limit")
equal(MenuBar.serviceLimit(stored: 1), 1, "stored limit")
equal(MenuBar.serviceLimit(stored: 3), nil, "no third service yet: all")
equal(MenuBar.serviceLimit(stored: 0), nil, "0 means all")
equal(MenuBar.items(["cards": [], "providers": [:]]).items, [], "no cards")
equal(MenuBar.items(["cards": [["provider": "claude", "id": "gone"]], "providers": [:]]).items,
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
equal(MenuBar.suffix(more: 0), "", "no suffix")
equal(MenuBar.suffix(more: 2), "  +2", "more, no stale marker")
equal(MenuBar.accessibilityLabel(menu.items, more: 1, stale: false), "Usagi: Claude 42%, Codex 12%, 1 more", "a11y label")
equal(MenuBar.accessibilityLabel([MenuBarItem(provider: "codex", percent: nil)], more: 0, stale: true),
      "Usagi: Codex no data (not up to date)", "a11y no data, stale")
equal(MenuBar.accessibilityLabel([], more: 0, stale: false), "Usagi", "a11y without cards")
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

// Also Use in Apps
func pairs(_ list: [(String, String?)]) -> [String] { list.map { "\($0.0)=\($0.1 ?? "<unset>")" } }
let envSnapshot: [String: Any] = ["providers": ["claude": ["active": "default"], "codex": ["active": "account-2"]]]
let wanted = AppEnvironment.wanted(envSnapshot, home: "/Users/me")
equal(wanted["CLAUDE_CONFIG_DIR"], .unset, "default is unset")
equal(wanted["CODEX_HOME"], .folder("/Users/me/.codex-account-2"), "profile folder")
equal(AppEnvironment.wanted(["providers": ["claude": ["active": "../x"]]], home: "/h")["CLAUDE_CONFIG_DIR"], .unset, "bad names ignored")
equal(pairs(AppEnvironment.changes(wanted: wanted, current: [:], applied: [:])), ["CODEX_HOME=/Users/me/.codex-account-2"], "set the profile")
equal(pairs(AppEnvironment.changes(wanted: wanted, current: ["CODEX_HOME": "/Users/me/.codex-account-2"], applied: [:])), [], "already set")
equal(pairs(AppEnvironment.changes(wanted: wanted, current: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-a"], applied: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-a"])),
      ["CLAUDE_CONFIG_DIR=<unset>", "CODEX_HOME=/Users/me/.codex-account-2"], "back to default undoes ours")
equal(pairs(AppEnvironment.changes(wanted: wanted, current: ["CLAUDE_CONFIG_DIR": "/mine"], applied: [:])),
      ["CODEX_HOME=/Users/me/.codex-account-2"], "a value Usagi didn't set stays")
equal(pairs(AppEnvironment.changes(wanted: nil, current: ["CODEX_HOME": "/Users/me/.codex-account-2", "CLAUDE_CONFIG_DIR": "/mine"],
                                   applied: ["CODEX_HOME": "/Users/me/.codex-account-2"])), ["CODEX_HOME=<unset>"], "turning it off undoes only ours")
equal(pairs(AppEnvironment.changes(wanted: nil, current: ["CODEX_HOME": "/changed"], applied: ["CODEX_HOME": "/Users/me/.codex-account-2"])),
      [], "changed by someone else since")

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
