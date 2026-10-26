# Settings Window (Sidebar) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Usagi's single-page Settings window with a CodexBar-style sidebar window (General, Menu Bar, Notifications, About, and one page per service) and make every setting on it work.

**Architecture:** Pure rules (limit choice, labels, remaining %, refresh cadence, alert decisions, shortcut model, pane ids) go in `Sources/Logic.swift` (Foundation only, tested by `tests/swift/run.sh`). A `Preferences` class owns every UserDefaults key and posts one change notification. AppKit code (sidebar window, panes, notifier, hotkey) reads `Preferences` and the controller's snapshot; `main.swift` wires them to the status item.

**Tech Stack:** Swift 5 mode (also clean in Swift 6), AppKit, ServiceManagement (`SMAppService`), UserNotifications, Carbon hot keys. No SwiftUI, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-26-settings-window-design.md` (Korean; read it, section numbers below refer to it).

## Global Constraints

- macOS 14.0 minimum; built by `build.sh` with plain `/usr/bin/swiftc` (no Xcode project). No SwiftUI (its `@State` is a macro in the current SDK and does not compile this way).
- Every source file must compile with `-swift-version 5` and `-swift-version 6` without warnings: `/usr/bin/swiftc -swift-version 6 -module-name Usagi -target arm64-apple-macos14.0 -framework AppKit -framework WebKit Sources/*.swift -o /tmp/u6`.
- UI copy is English. Never show the mockup's Korean notes or its source tags ("지금 있음", "CodexBar", "새로").
- Settings apply immediately (no Save button); the menu bar redraws on every change.
- Pure logic goes in `Sources/Logic.swift` with plain-assertion tests in `tests/swift/main.swift` (style: `equal(actual, expected, "message")`, `check(cond, "message")`).
- UserDefaults keys (exact): existing `menuBarColor.<provider>`, `menuBarHidden`, `menuBarServices` (old, migrated), `alsoUseInApps`; new `menuBarLimit.<provider>`, `menuBarTextSize`, `menuBarShowsLogos`, `menuBarShowsRemaining`, `refreshInterval`, `notifyThresholds`, `notifyUsedUp`, `notifyReset`, `notifyState`, `openShortcut`, `settingsPane`.
- Defaults: limit `"auto"`, text size `regular`, logos on, remaining off, refresh 300 s, thresholds `[80, 95]`, used-up on, reset on, no shortcut, pane `general`.
- Commits: only once the user has agreed (asked at handoff). If agreed, work on branch `settings-window`; phase 1 (already in the working tree) is committed first as its own commit.
- Verification for every task, besides its own tests: `tests/swift/run.sh` and the Swift 6 compile above. `./build.sh` and `.github/verify-app.sh build/Usagi.app "$(/usr/bin/plutil -extract CFBundleShortVersionString raw Info.plist)"` from Task 3 on.
- Do not launch `build/Usagi.app` without asking: the installed Usagi may be running and the app is single-instance.

## Review Focus

- No snapshot yet / CLI missing while Settings is open: service page shows "Not updated yet", "Limit shown" lists only the automatic choice (plus a stored one). Test in Task 1.
- Active account switch: the limit list follows the new account; its limits are first sight, so no alert burst. Tests in Tasks 1 and 2.
- 15-minute refresh interval: the menu bar must not dim between refreshes. Test in Task 1.
- Remaining with readings above 100% (Usagi clamps up to 999): shows 0, never negative. Test in Task 1.
- A shortcut with only ⇧, or one another app already owns: refused with a message, the old shortcut kept. Tests in Task 4 (model) plus a manual check.

---

### Task 0: Branch and phase-1 commit (only if the user agreed to commits)

- [ ] **Step 1:** `git switch -c settings-window`
- [ ] **Step 2:** `git add Sources/Glyphs.swift Sources/Settings.swift Sources/Logic.swift Sources/ProviderIcons.swift Sources/main.swift tests/swift/main.swift tests/swift/run.sh README.md CHANGELOG.md docs/superpowers` then `git commit -m "Menu bar colors per service, Settings window, logos drawn in the menu bar"`

---

### Task 1: Menu bar options and refresh interval (logic, Preferences, drawing)

**Files:**
- Modify: `Sources/Logic.swift` (`MenuBar`, `MenuBarStyle`, `Cadence`)
- Create: `Sources/Preferences.swift` (replaces `MenuBarSettings` from `Sources/Settings.swift`; move `migrate` there)
- Modify: `Sources/ProviderIcons.swift` (`MenuBarGlyphs.label`), `Sources/main.swift` (`updateStatus`), `Sources/UsageController.swift` (hidden interval)
- Test: `tests/swift/main.swift`

**Interfaces (Produces):**
- `struct LimitOption: Equatable { var key: String; var title: String }`
- `MenuBar.autoLimit = "auto"`, `MenuBar.autoLimitTitle = "Higher of 5-hour and weekly"`
- `MenuBar.menuBarAccount(_ snapshot: [String: Any], provider: String) -> [String: Any]?` — the account dict `items` already picks (Active when its card is shown, else first shown card in the accounts list order). `items` must use it.
- `MenuBar.limitLabel(_ key: String) -> String` — same rule as `windowLabel` in `index.html:159`.
- `MenuBar.limitOptions(_ snapshot: [String: Any]?, provider: String, stored: String) -> [LimitOption]` — auto first; then the menu bar account's window keys ordered `5h`, `7d`, then the rest by key; a stored key not among them is appended with title `"<label> (not reported now)"`.
- `MenuBar.percent(_ windows: [String: Any], limit: String) -> Int?` — `auto` = existing `usedPercent`; otherwise that window's `used_percent`, nil when absent (shown as "–").
- `MenuBar.items(_ snapshot: [String: Any], hidden: Set<String> = [], limits: [String: String] = [:]) -> [MenuBarItem]`
- `MenuBar.shownPercent(_ percent: Int?, remaining: Bool) -> Int?` — remaining: `max(0, 100 - p)`.
- `MenuBar.accessibilityLabel(_ items: [MenuBarItem], stale: Bool, remaining: Bool = false) -> String` — items carry the percent as shown (already passed through `shownPercent`); remaining reads "Claude 58% left". `MenuBarGlyphs.label` likewise receives shown percents.
- `MenuBar.isStale(lastSuccess: Date?, failed: Bool, now: Date, refreshInterval: TimeInterval = Cadence.hidden) -> Bool` — stale after `max(15 min, refreshInterval + 5 min)`.
- `MenuBar.accountNames(_ snapshot: [String: Any]?, provider: String) -> [String]` — card order for that provider; email, else `"Account 1"` for `default`, `"Account N"` for `account-N`, else the id; the Active one gets `" (Active)"`.
- `MenuBarStyle.TextSize: String, CaseIterable { small, regular, large }` with `fontSize` 10/11/13 and `glyphSize` 12/14/16; keys `MenuBarStyle.limitKey(_:)` = `"menuBarLimit.<provider>"`, `textSizeKey`, `showsLogosKey`, `showsRemainingKey`.
- `Cadence.hiddenChoices: [TimeInterval] = [60, 120, 300, 900]`, `Cadence.intervalKey = "refreshInterval"`, `Cadence.hiddenInterval(stored: Int?) -> TimeInterval` (a listed choice, else 300), `Cadence.delay(since:shown:now:hidden: TimeInterval = Cadence.hidden)`.
- `@MainActor final class Preferences` with `static let didChange: Notification.Name`; typed get/set for every key in Global Constraints (setters post `didChange`); keeps `color(_:)`, `setColor(_:for:)`, `hidden`, `setShown(_:_:)`, `migrate(_:)` with phase-1 behaviour.
- `MenuBarGlyphs.label(_ items: [MenuBarItem], paint: MenuBarStyle.Paint, color: (String) -> RGB, size: MenuBarStyle.TextSize, logos: Bool) -> NSAttributedString`
- `UsageController.hiddenInterval: TimeInterval` (setting it reschedules the timer).

- [ ] **Step 1: Write the failing tests** (add to the menu bar section of `tests/swift/main.swift`)

```swift
equal(MenuBar.limitLabel("5h"), "5-hour", "label 5h")
equal(MenuBar.limitLabel("7d"), "Weekly", "label 7d")
equal(MenuBar.limitLabel("30d"), "30-day", "label 30d")
equal(MenuBar.limitLabel("12h"), "12-hour", "label 12h")
equal(MenuBar.limitLabel("fable"), "Fable weekly", "model window")
equal(MenuBar.limitLabel("claude_opus"), "Claude Opus weekly", "words split on _ - and spaces")
// snapshot from this file: claude default has 5h 41.6, 7d 17, fable 90
equal(MenuBar.limitOptions(snapshot, provider: "claude", stored: "auto").map(\.key), ["auto", "5h", "7d", "fable"], "options in order")
equal(MenuBar.limitOptions(snapshot, provider: "claude", stored: "opus").last, LimitOption(key: "opus", title: "Opus weekly (not reported now)"), "stored but missing")
equal(MenuBar.limitOptions(nil, provider: "codex", stored: "auto"), [LimitOption(key: "auto", title: "Higher of 5-hour and weekly")], "no snapshot yet")
equal(MenuBar.items(snapshot, limits: ["claude": "fable"]).first, MenuBarItem(provider: "claude", percent: 90), "chosen limit")
equal(MenuBar.items(snapshot, limits: ["claude": "opus"]).first, MenuBarItem(provider: "claude", percent: nil), "chosen limit missing: dash")
equal(MenuBar.limitOptions(activeSecond, provider: "codex", stored: "auto").map(\.key), ["auto", "5h"], "follows the Active account")
equal(MenuBar.shownPercent(42, remaining: true), 58, "remaining")
equal(MenuBar.shownPercent(120, remaining: true), 0, "never below 0")
equal(MenuBar.shownPercent(nil, remaining: true), nil, "no data stays no data")
equal(MenuBar.accessibilityLabel([MenuBarItem(provider: "claude", percent: 58)], stale: false, remaining: true), "Usagi: Claude 58% left", "a11y remaining")
check(!MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 16 * 60, refreshInterval: 900), "15 min refresh: not dim at 16 min")
check(MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 20 * 60 + 1, refreshInterval: 900), "but dim after 20 min")
check(MenuBar.isStale(lastSuccess: t0, failed: false, now: t0 + 15 * 60 + 1, refreshInterval: 300), "5 min refresh keeps 15 min")
equal(MenuBar.accountNames(activeSecond, provider: "codex"), ["Account 1", "Account 2 (Active)"], "names without emails")
equal(MenuBarStyle.TextSize.small.fontSize, 10, "small text"); equal(MenuBarStyle.TextSize.large.glyphSize, 16, "large logo")
equal(Cadence.hiddenInterval(stored: nil), 300, "default interval"); equal(Cadence.hiddenInterval(stored: 900), 900, "15 min")
equal(Cadence.hiddenInterval(stored: 7), 300, "unknown value"); equal(Cadence.delay(since: nil, shown: false, now: t0, hidden: 900), 900, "custom hidden interval")
```

- [ ] **Step 2: Run** `tests/swift/run.sh` — Expected: compile errors for the missing names; then add stubs returning wrong values and see the assertions FAIL.
- [ ] **Step 3: Implement the Logic.swift interfaces above.** Keep existing tests green (the existing `items`/`isStale`/`delay` call sites keep their defaults).
- [ ] **Step 4: Run** `tests/swift/run.sh` — Expected: all checks pass.
- [ ] **Step 5: Create `Preferences`, move phase-1 `MenuBarSettings` into it, wire `updateStatus`** (`items(_:hidden:limits:)`, `label(…size:logos:)` with percents mapped through `shownPercent`, `isStale(…refreshInterval:)`, `accessibilityLabel(…remaining:)`), set `controller.hiddenInterval` at launch and on `Preferences.didChange`, observe `didChange` to call `updateStatus()`. With logos off, the label draws no attachments and no space before the number.
- [ ] **Step 6: Verify the drawing offscreen.** Extend the scratchpad harness (pattern: draw `MenuBarGlyphs.label` under `NSAppearance(named: .aqua / .darkAqua).performAsCurrentDrawingAppearance` into a bitmap) for the three sizes, logos off, and remaining; look at the PNG. Then `./build.sh` and `verify-app.sh` (expect `verify-app: OK`).
- [ ] **Step 7: Commit** (if agreed): `git commit -am "Menu bar: limit per service, remaining, text size, logos switch, refresh interval"` (add `Sources/Preferences.swift`).

---

### Task 2: Limit alert rules (pure)

**Files:** Modify `Sources/Logic.swift`; Test `tests/swift/main.swift`

**Interfaces (Produces):**
- `enum LimitAlerts` with `struct Reading: Equatable { var used: Double; var resetsAt: Double?; var reset: Bool }`, `struct Record: Codable, Equatable { var used: Double; var resetsAt: Double?; var seen: Double }`, `enum Alert: Equatable { case crossed(Int), usedUp, reset }`, `struct Options: Equatable { var thresholds: [Int]; var usedUp: Bool; var reset: Bool }`
- Constants: `defaultThresholds = [80, 95]`, `thresholdChoices = [50, 60, 70, 80, 90, 95]`, `keepFor: TimeInterval = 35 * 86400`, `newCycleSlack = 60.0`, keys `stateKey = "notifyState"`, `thresholdsKey`, `usedUpKey`, `resetKey`.
- `static func readings(_ snapshot: [String: Any]) -> [String: Reading]` — key `"<provider>|<account id>|<window key>"`, only each service's `MenuBar.menuBarAccount`, all its windows (services hidden from the menu bar included).
- `static func evaluate(_ previous: Record?, _ reading: Reading, options: Options, now: Date) -> (alert: Alert?, record: Record)`
- `static func prune(_ records: [String: Record], now: Date) -> [String: Record]` — drops records with `seen` older than `keepFor`.
- `static func text(_ alert: Alert, key: String) -> (title: String, body: String)`

`evaluate` rules (spec 6.3):
1. No previous record → no alert, record the reading (first sight: launch after update, new account, Active switch).
2. `reading.reset == true` → alert `.reset` if `previous.used > 0` and `options.reset`; record `used 0, resetsAt nil`.
3. New cycle when both `resetsAt` exist and `reading.resetsAt > previous.resetsAt + newCycleSlack`. Base for crossing = 0 in a new cycle, else `previous.used`.
4. Steps = `options.thresholds` plus 100 when `options.usedUp`. The highest step `t` with `base < t <= reading.used` alerts: `.usedUp` for 100, else `.crossed(t)`. A crossing wins over a reset.
5. Otherwise a new cycle with `previous.used > 0` and `options.reset` alerts `.reset`.
6. Record: `used = reading.used`, `resetsAt` = the reading's in a new cycle, else the later of the two (an older source never moves the cycle back), `seen = now`.

Exact copy for `text` (label from `MenuBar.limitLabel`, name from `MenuBar.names`):
- `.crossed(80)` → `("Claude 5-hour limit at 80%", "80% of this limit is used.")`
- `.usedUp` → `("Claude 5-hour limit used up", "This limit is used up until it resets.")`
- `.reset` → `("Claude 5-hour limit reset", "This limit is available again.")`

- [ ] **Step 1: Write the failing tests**

```swift
let on = LimitAlerts.Options(thresholds: [80, 95], usedUp: true, reset: true)
func rec(_ used: Double, _ resetsAt: Double?) -> LimitAlerts.Record { .init(used: used, resetsAt: resetsAt, seen: 0) }
func read(_ used: Double, _ resetsAt: Double?, reset: Bool = false) -> LimitAlerts.Reading { .init(used: used, resetsAt: resetsAt, reset: reset) }
equal(LimitAlerts.evaluate(nil, read(97, 1000), options: on, now: t0).alert, nil, "first sight is silent")
equal(LimitAlerts.evaluate(nil, read(97, 1000), options: on, now: t0).record.used, 97, "but recorded")
equal(LimitAlerts.evaluate(rec(70, 1000), read(85, 1000), options: on, now: t0).alert, .crossed(80), "crossing 80")
equal(LimitAlerts.evaluate(rec(70, 1000), read(100, 1000), options: on, now: t0).alert, .usedUp, "several steps: highest only")
equal(LimitAlerts.evaluate(rec(70, 1000), read(100, 1000), options: .init(thresholds: [80, 95], usedUp: false, reset: true), now: t0).alert, .crossed(95), "used up off")
equal(LimitAlerts.evaluate(rec(85, 1000), read(88, 1000), options: on, now: t0).alert, nil, "no repeat")
equal(LimitAlerts.evaluate(rec(60, 1000), read(5, 20000), options: on, now: t0).alert, .reset, "new cycle")
equal(LimitAlerts.evaluate(rec(60, 1000), read(5, 20000), options: .init(thresholds: [80, 95], usedUp: true, reset: false), now: t0).alert, nil, "reset alerts off")
equal(LimitAlerts.evaluate(rec(60, 1000), read(5, 1030), options: on, now: t0).alert, nil, "within 60 s is the same cycle")
equal(LimitAlerts.evaluate(rec(0, 1000), read(0, 20000), options: on, now: t0).alert, nil, "unused limit: no reset alert")
equal(LimitAlerts.evaluate(rec(60, 1000), read(85, 20000), options: on, now: t0).alert, .crossed(80), "crossing beats reset")
equal(LimitAlerts.evaluate(rec(40, 1000), read(0, nil, reset: true), options: on, now: t0).alert, .reset, "Claude's reset flag")
equal(LimitAlerts.evaluate(rec(0, nil), read(0, nil, reset: true), options: on, now: t0).alert, nil, "flag seen twice")
equal(LimitAlerts.evaluate(rec(50, 2000), read(50, 1000), options: on, now: t0).record.resetsAt, 2000, "older source keeps the cycle")
equal(LimitAlerts.prune(["a": .init(used: 1, resetsAt: nil, seen: t0.timeIntervalSince1970 - 36 * 86400),
                        "b": .init(used: 1, resetsAt: nil, seen: t0.timeIntervalSince1970 - 34 * 86400)], now: t0).keys.sorted(), ["b"], "prune after 35 days")
equal(Set(LimitAlerts.readings(activeSecond).keys), ["claude|default|5h", "codex|account-2|5h"], "menu bar accounts only")
equal(LimitAlerts.text(.crossed(80), key: "claude|default|5h").title, "Claude 5-hour limit at 80%", "title")
equal(LimitAlerts.text(.reset, key: "codex|default|30d").title, "Codex 30-day limit reset", "reset title")
```

- [ ] **Step 2: Run** `tests/swift/run.sh` — Expected: FAIL (missing names, then wrong stub values).
- [ ] **Step 3: Implement `LimitAlerts`** per the rules above.
- [ ] **Step 4: Run** `tests/swift/run.sh` — Expected: all pass.
- [ ] **Step 5: Commit** (if agreed): `git commit -am "Limit alert rules: crossing, used up, reset, first sight is silent"`

---

### Task 3: Notifications delivery

**Files:** Create `Sources/LimitNotifier.swift`; Modify `Sources/Preferences.swift`, `Sources/main.swift`

**Interfaces:**
- Consumes: `LimitAlerts.*` (Task 2), `Preferences` thresholds/usedUp/reset/state (Task 1 pattern).
- Produces: `@MainActor final class LimitNotifier: NSObject, UNUserNotificationCenterDelegate` with `var opened: () -> Void`, `func status(_ done: @escaping @MainActor (UNAuthorizationStatus) -> Void)`, `func requestAuthorization()`, `func check(_ snapshot: [String: Any], preferences: Preferences)`.

- [ ] **Step 1: Check ad-hoc signing first (spike, throwaway).** Build the app with a temporary call to `requestAuthorization` at launch, ask the user before launching it (installed Usagi must be quit), and confirm the macOS permission prompt and a test banner appear. If they cannot, stop and report: the Notifications page then only shows the "turned off" state (spec 6.3) and Task 6 hides the alert rows.
- [ ] **Step 2: Implement `LimitNotifier`.** `check` runs `readings`, `evaluate` against stored `notifyState`, posts one `UNNotificationRequest` per alert (identifier = the reading key, so a newer alert replaces an older one), saves `prune`d state. `willPresent` shows banners while Usagi is active; `didReceive` calls `opened`.
- [ ] **Step 3: Wire in `main.swift`:** call `check` once per new snapshot (when `controller.lastSuccess` changes, like `syncAppEnvironment`), `opened` → `showPopover()`. Request authorization the first time any alert option is on and the status is `.notDetermined`.
- [ ] **Step 4: Verify:** `tests/swift/run.sh`, Swift 6 compile, `./build.sh`, `verify-app.sh`. Manual (with the user's go-ahead): set `defaults write io.github.extransload.usagi notifyThresholds -array 1`, wait for a refresh, see one banner, click it, popover opens; no repeat after the next refresh. Then `defaults delete io.github.extransload.usagi notifyThresholds`.
- [ ] **Step 5: Commit** (if agreed): `git commit -am "Notifications for limits passing a threshold, used up and reset"`

---

### Task 4: Keyboard shortcut to open Usagi

**Files:** Modify `Sources/Logic.swift`; Create `Sources/HotKey.swift`; Modify `Sources/main.swift`; Test `tests/swift/main.swift`

**Interfaces (Produces):**
- `struct Shortcut: Codable, Equatable { var keyCode: UInt32; var modifiers: UInt; var key: String }` (modifiers = `NSEvent.ModifierFlags` raw bits; `key` = the key's display text captured when recorded, e.g. "U", "F5", "Space").
- `Shortcut.command = 1 << 20`, `.option = 1 << 19`, `.control = 1 << 18`, `.shift = 1 << 17`; `var isAllowed: Bool` (needs ⌘, ⌥ or ⌃); `var display: String` (symbols in order ⌃⌥⇧⌘, then `key`); `var carbonModifiers: UInt32` (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000); `static let storeKey = "openShortcut"` (stored as JSON `Data`).
- `@MainActor final class HotKey` — `func register(_ shortcut: Shortcut?, action: @escaping @MainActor () -> Void) -> Bool` (false when the system refuses, e.g. another app holds it; nil unregisters).
- `final class ShortcutRecorder: NSView` — click to record, Escape cancels, `var shortcut: Shortcut?`, `var changed: (Shortcut?) -> Void`; refuses `!isAllowed` with a beep.

- [ ] **Step 1: Write the failing tests**

```swift
let cmdOptU = Shortcut(keyCode: 32, modifiers: Shortcut.command | Shortcut.option, key: "U")
equal(cmdOptU.display, "⌥⌘U", "display order")
check(cmdOptU.isAllowed, "⌥⌘ allowed")
check(!Shortcut(keyCode: 32, modifiers: Shortcut.shift, key: "U").isAllowed, "shift alone refused")
check(!Shortcut(keyCode: 32, modifiers: 0, key: "U").isAllowed, "no modifier refused")
equal(Shortcut(keyCode: 32, modifiers: Shortcut.control | Shortcut.shift | Shortcut.command, key: "U").carbonModifiers, 0x1300, "carbon bits")
equal(try? JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(cmdOptU)), cmdOptU, "stored as JSON")
```

- [ ] **Step 2: Run** `tests/swift/run.sh` — Expected: FAIL.
- [ ] **Step 3: Implement `Shortcut`** in Logic.swift; run tests — Expected: PASS.
- [ ] **Step 4: Implement `HotKey`** with `RegisterEventHotKey` / `InstallEventHandler(GetApplicationEventTarget(), …kEventHotKeyPressed…)` and `ShortcutRecorder`. While the recorder is recording, unregister the hotkey so pressing it doesn't toggle the popover.
- [ ] **Step 5: Wire in `main.swift`:** register from `Preferences` at launch and on `didChange`; action toggles the popover like a left click (`showPopover()`, `refreshIcons()`, `checkForUpdate()`, or close when shown). Registration failure is kept in a property the General page reads.
- [ ] **Step 6: Verify:** tests, Swift 6 compile, `./build.sh`, `verify-app.sh`.
- [ ] **Step 7: Commit** (if agreed): `git commit -am "Keyboard shortcut to open Usagi from anywhere"`

---

### Task 5: Sidebar window shell and service pages

**Files:** Replace `Sources/Settings.swift` with `Sources/SettingsWindow.swift` (window, sidebar, `SettingsActions`) and `Sources/SettingsForm.swift` (shared title / section header / rounded box / row helpers); Create `Sources/ServicePane.swift`; Modify `Sources/Logic.swift`, `Sources/main.swift`; Test `tests/swift/main.swift`; harness in the scratchpad.

**Interfaces (Produces):**
- `enum SettingsPane: Hashable { case general, menuBar, notifications, about, service(String) }` in Logic.swift with `var id: String` (`"general"`, `"menuBar"`, `"notifications"`, `"about"`, `"service:claude"`) and `init?(id: String)`; key `"settingsPane"`.
- `struct SettingsActions { var snapshot: () -> [String: Any]?; var lastSuccess: () -> Date?; var update: () -> [String: String]?; var checkForUpdates: () -> Void; var openUpdate: () -> Void; var alsoUseInApps: () -> Bool; var setAlsoUseInApps: (Bool) -> Void; var shortcutFailed: () -> Bool }`
- `@MainActor final class SettingsWindow` — `init(preferences: Preferences, actions: SettingsActions)`, `func show(selecting pane: SettingsPane? = nil)`, `func refresh()` (AppDelegate calls it after a snapshot or update check).
- `SettingsForm` helpers used by every pane: `title(_:)`, `section(_ header: String, rows: [NSView]) -> NSView`, `row(_ label: String, detail: String? = nil, control: NSView?) -> NSView`, `note(_:) -> NSTextField`.

- [ ] **Step 1: Write the failing test**

```swift
for pane in [SettingsPane.general, .menuBar, .notifications, .about, .service("codex")] {
    equal(SettingsPane(id: pane.id), pane, "pane id round trip \(pane.id)")
}
equal(SettingsPane(id: "service:claude"), .service("claude"), "service pane")
equal(SettingsPane(id: "nonsense"), nil, "unknown pane")
```

- [ ] **Step 2: Run** `tests/swift/run.sh` — Expected: FAIL. **Step 3:** implement `SettingsPane`; run — Expected: PASS.
- [ ] **Step 4: Build the window** (spec 5): `NSSplitViewController` with a sidebar item (source-list `NSTableView`, group rows "Usagi" and "Services", SF Symbol icons `gearshape`, `menubar.rectangle`, `bell.badge`, `info.circle` on coloured rounded squares; service rows in `MenuBar.services(snapshot)` order, so services without cards come last, each with `MenuBarGlyphs.image(provider, color:)` in the current colour) and a content item that swaps pane view controllers. About 720×520, resizable with a minimum size, centred the first time, last pane restored from `settingsPane`. Keep phase-1 behaviour: closing stops colour picking and deactivates the app when nothing is key; sidebar order is rebuilt only on `show`.
- [ ] **Step 5: Service page** (spec 6.5): Menu bar box (Show in menu bar, Color hex + well, Default + Reset, contrast warning — move phase-1 `ServiceSection` behaviour unchanged; Limit shown pop-up from `MenuBar.limitOptions`, writes `menuBarLimit.<provider>`), Status box (`MenuBar.accountNames`, "Updated 4 min ago" via `RelativeDateTimeFormatter` or "Not updated yet", "Claude Code found / not found" / "Codex CLI found / not found" from `providers[p]["cli"]`).
- [ ] **Step 6: Wire `main.swift`:** `openSettings` builds `SettingsActions` and calls `show()`; refresh the window after each snapshot and update check; General/Menu Bar/Notifications/About show an empty placeholder for now.
- [ ] **Step 7: Verify** with the scratchpad harness (render the window light/dark per pane to PNG; drive the switch, hex field, Reset and the Limit shown pop-up, then read UserDefaults — the phase-1 `interact` harness checks still pass against the service page). Tests, Swift 6, `./build.sh`, `verify-app.sh`.
- [ ] **Step 8: Commit** (if agreed): `git commit -am "Settings window with a sidebar and a page per service"`

---

### Task 6: General, Menu Bar, Notifications and About pages

**Files:** Create `Sources/SettingsPanes.swift`; Modify `Sources/Logic.swift` (update status line), `Sources/main.swift`; Test `tests/swift/main.swift`

**Interfaces:** Consumes `Preferences`, `SettingsForm`, `SettingsActions`, `ShortcutRecorder`, `LimitNotifier.status`. Produces `UpdateStatus.line(_ info: [String: String]?) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
equal(UpdateStatus.line(nil), "Not checked yet", "never checked")
equal(UpdateStatus.line(["current": "1.0.11", "failed": "true"]), "Couldn't check for updates", "failed")
equal(UpdateStatus.line(["current": "1.0.11", "latest": "1.0.11", "checked_at": "1800000000"]), "Up to date", "current")
equal(UpdateStatus.line(["current": "1.0.11", "version": "1.0.12", "checked_at": "1800000000"]), "Usagi 1.0.12 is available", "newer")
```

- [ ] **Step 2: Run** — FAIL. **Step 3:** implement `UpdateStatus.line`; run — PASS.
- [ ] **Step 4: Pages** (spec 6.1–6.4, controls per spec 5):
  - General: Start at login (`SMAppService.mainApp` status/register/unregister; `.requiresApproval` shows "Allow Usagi in System Settings > General > Login Items." and a button calling `SMAppService.openSystemSettingsLoginItems()`), Also Use in Apps (same value and action as the right-click item), Refresh while the menu is closed (1m 2m 5m 15m; detail "While the menu is open, Usagi refreshes every minute."), Open Usagi shortcut (`ShortcutRecorder` + Clear; failure note "Another app uses this shortcut.").
  - Menu Bar: preview (`MenuBarGlyphs.label` from the live snapshot, light and dark bar strips, redrawn on `didChange`), Show percentages as Used/Remaining, Text size Small/Regular/Large, Show logos, note "Turn services on or off, set their colors and the limit they show on each service's page."
  - Notifications: when `LimitNotifier.status` is denied, a top note "Notifications are turned off for Usagi." with a button opening `x-apple.systempreferences:com.apple.Notifications-Settings.extension`, other rows disabled; Warn when a limit passes (two pop-ups: Off + `LimitAlerts.thresholdChoices`), When a limit is used up, When a limit resets, note "Claude's numbers change only when Claude Code updates them, so an alert can come hours late."
  - About: app icon, "Usagi <version>", `UpdateStatus.line` plus " · checked <relative>" when `checked_at` exists, Check for Updates (becomes "Update to <version>…" when newer, which calls `openUpdate` → opens the popover with its banner), links GitHub / Releases / Changelog (`https://github.com/Extransload/usagi`, `/releases`, `/blob/main/CHANGELOG.md`), Acknowledgements "Menu bar logos from CodexBar (MIT) · © 2026 Peter Steinberger" linking `https://github.com/steipete/CodexBar`.
- [ ] **Step 5: Verify** with the harness (each page light/dark PNG; drive Used/Remaining, text size, logos, refresh interval, thresholds and confirm UserDefaults and the label), tests, Swift 6, `./build.sh`, `verify-app.sh`.
- [ ] **Step 6: Commit** (if agreed): `git commit -am "General, Menu Bar, Notifications and About settings pages"`

---

### Task 7: Docs, live check, review

**Files:** Modify `README.md`, `CHANGELOG.md`

- [ ] **Step 1: README:** Usage bullets for the right-click menu and Settings (pages and what they change), replace "add it under System Settings > General > Login Items" with Settings > General > Start at login, mention notifications and the shortcut; keep the CodexBar credit.
- [ ] **Step 2: CHANGELOG `## 1.0.11`:** rewrite Added/Changed for the sidebar Settings window and all its settings; keep the Menu Bar Shows migration line.
- [ ] **Step 3: Full verification:** `tests/swift/run.sh`, `/usr/bin/python3 -m unittest discover -s tests`, Swift 6 compile, `./build.sh`, `verify-app.sh`.
- [ ] **Step 4: Live check (ask the user first):** quit the installed Usagi, `open build/Usagi.app`, capture the menu bar with `screencapture -x -R <x>,0,<w>,28`, open Settings from the right-click menu, check every page.
- [ ] **Step 5: Independent review** of the whole branch diff (fresh reviewer), fix what holds up.
- [ ] **Step 6: Commit** (if agreed): `git commit -am "README and CHANGELOG for the Settings window"`
