import AppKit
import ServiceManagement
import UserNotifications

/// Settings > General: start at login, Also Use in Apps, the refresh interval and the Open Usagi shortcut.
final class GeneralPane: SettingsPage {
    private let preferences: Preferences
    private let actions: SettingsActions
    private let login = NSSwitch()
    private let approval = SettingsForm.note("Allow Usagi in System Settings > General > Login Items.")
    private let approvalButton = NSButton(title: "Open Login Items", target: nil, action: nil)
    private let apps = NSSwitch()
    private var interval = NSSegmentedControl()
    private let recorder = ShortcutRecorder()
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private let taken = SettingsForm.note("Another app uses that shortcut. Choose another one.")
    private let needsModifier = SettingsForm.note("A shortcut needs ⌘, ⌥ or ⌃.")

    init(preferences: Preferences, actions: SettingsActions) {
        self.preferences = preferences
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        for (control, action) in [(login, #selector(toggleLogin)), (apps, #selector(toggleApps)), (approvalButton, #selector(openLoginItems)),
                                  (clear, #selector(clearShortcut))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        approvalButton.controlSize = .small
        clear.controlSize = .small
        interval = SettingsForm.segments(["1 min", "2 min", "5 min", "15 min"], selected: 2, target: self, action: #selector(chooseInterval))
        recorder.changed = { [weak self] in self?.preferences.shortcut = $0 }
        recorder.recordingChanged = { [weak self] recording in
            self?.needsModifier.isHidden = true
            self?.actions.setShortcutPaused(recording)
        }
        recorder.refused = { [weak self] in self?.needsModifier.isHidden = false }
        needsModifier.isHidden = true
        let shortcut = NSStackView(views: [recorder, clear])
        shortcut.spacing = 6
        let approvalRow = NSStackView(views: [approval, approvalButton])
        approvalRow.spacing = 8
        view = SettingsForm.page("General", [
            SettingsForm.section("System", [
                SettingsForm.row("Start at login", control: login),
                SettingsForm.row("Also Use in Apps", detail: "Apps you open from now on use the Active accounts, like new terminals.",
                                 control: apps),
            ]),
            approvalRow,
            SettingsForm.section("Refreshing", [
                SettingsForm.row("Refresh while the menu is closed", detail: "While the menu is open, Usagi refreshes every minute.",
                                 control: interval),
            ]),
            SettingsForm.section("Keyboard shortcut", [
                SettingsForm.row("Open Usagi", detail: "Opens the account cards from any app.", control: shortcut),
            ]),
            taken,
            needsModifier,
        ])
        refresh()
    }

    override func closing() {
        recorder.cancel()
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        approval.superview?.isHidden = status != .requiresApproval
        apps.state = actions.alsoUseInApps() ? .on : .off
        interval.selectedSegment = Cadence.hiddenChoices.firstIndex(of: preferences.refreshInterval) ?? 2
        recorder.shortcut = preferences.shortcut
        clear.isEnabled = preferences.shortcut != nil
        taken.isHidden = !actions.shortcutFailed()
    }

    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        refresh()
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func toggleApps() {
        actions.setAlsoUseInApps(apps.state == .on)
        refresh()
    }

    @objc private func chooseInterval() {
        let index = interval.selectedSegment
        guard Cadence.hiddenChoices.indices.contains(index) else { return }
        preferences.refreshInterval = Cadence.hiddenChoices[index]
    }

    @objc private func clearShortcut() { preferences.shortcut = nil }
}

/// Settings > Menu Bar: a live preview, used or remaining, text size and logos.
final class MenuBarPane: SettingsPage {
    private let preferences: Preferences
    private let actions: SettingsActions
    private let preview = MenuBarPreview()
    private var shownAs = NSSegmentedControl()
    private var size = NSSegmentedControl()
    private let logos = NSSwitch()

    init(preferences: Preferences, actions: SettingsActions) {
        self.preferences = preferences
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        shownAs = SettingsForm.segments(["Used", "Remaining"], selected: 0, target: self, action: #selector(chooseShownAs))
        size = SettingsForm.segments(["Small", "Regular", "Large"], selected: 1, target: self, action: #selector(chooseSize))
        logos.target = self
        logos.action = #selector(toggleLogos)
        preview.heightAnchor.constraint(equalToConstant: 64).isActive = true
        view = SettingsForm.page("Menu Bar", [
            preview,
            SettingsForm.section("Display", [
                SettingsForm.row("Show percentages as", control: shownAs),
                SettingsForm.row("Text size", control: size),
                SettingsForm.row("Show logos", control: logos),
            ]),
            SettingsForm.note("Turn services on or off, set their colors and the limit they show on each service's page."),
        ])
        refresh()
    }

    override func refresh() {
        guard isViewLoaded else { return }
        shownAs.selectedSegment = preferences.showsRemaining ? 1 : 0
        size.selectedSegment = MenuBarStyle.TextSize.allCases.firstIndex(of: preferences.textSize) ?? 1
        logos.state = preferences.showsLogos ? .on : .off
        let remaining = preferences.showsRemaining
        let live = actions.snapshot().map { MenuBar.items($0, hidden: preferences.hidden, limits: preferences.limits) } ?? []
        let items = (live.isEmpty ? [MenuBarItem(provider: "claude", percent: 42), MenuBarItem(provider: "codex", percent: 7)] : live)
            .map { MenuBarItem(provider: $0.provider, percent: MenuBar.shownPercent($0.percent, remaining: remaining)) }
        preview.show(items, preferences: preferences)
    }

    @objc private func chooseShownAs() { preferences.showsRemaining = shownAs.selectedSegment == 1 }

    @objc private func chooseSize() {
        let sizes = MenuBarStyle.TextSize.allCases
        if sizes.indices.contains(size.selectedSegment) { preferences.textSize = sizes[size.selectedSegment] }
    }

    @objc private func toggleLogos() { preferences.showsLogos = logos.state == .on }
}

/// The menu bar label as it looks now, on a light and a dark menu bar.
final class MenuBarPreview: NSView {
    private var label = NSAttributedString()

    /// The label's colors resolve as it is drawn, so one label serves both bars.
    @MainActor func show(_ items: [MenuBarItem], preferences: Preferences) {
        label = MenuBarGlyphs.label(items, paint: .color, color: preferences.color, size: preferences.textSize,
                                    logos: preferences.showsLogos)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let half = (bounds.width - 10) / 2
        for (index, (name, gray)) in [(NSAppearance.Name.aqua, 0.9), (.darkAqua, 0.16)].enumerated() {
            let strip = NSRect(x: CGFloat(index) * (half + 10), y: 0, width: half, height: bounds.height)
            let shape = NSBezierPath(roundedRect: strip.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor(white: gray, alpha: 1).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let size = label.size()
                label.draw(at: NSPoint(x: strip.midX - size.width / 2, y: strip.midY - size.height / 2))
            }
        }
    }
}

/// Settings > Notifications: when to warn about a limit, and whether macOS lets Usagi notify at all.
final class NotificationsPane: SettingsPage {
    private let preferences: Preferences
    private let status: @MainActor (@escaping @MainActor (UNAuthorizationStatus) -> Void) -> Void
    private let request: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private let off = SettingsForm.note("Notifications are turned off for Usagi.")
    private let openSettings = NSButton(title: "Open Notification Settings", target: nil, action: nil)
    private let ask = SettingsForm.note("Usagi asks for permission the first time it has an alert.")
    private let allow = NSButton(title: "Allow Now", target: nil, action: nil)
    private let first = NSPopUpButton(), second = NSPopUpButton()
    private let usedUp = NSSwitch(), reset = NSSwitch()
    private var alerts: NSView?

    init(preferences: Preferences, status: @escaping @MainActor (@escaping @MainActor (UNAuthorizationStatus) -> Void) -> Void,
         request: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void) {
        self.preferences = preferences
        self.status = status
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let titles = ["Off"] + LimitAlerts.thresholdChoices.map { "\($0)%" }
        for popup in [first, second] {
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = #selector(chooseThresholds)
        }
        for (control, action) in [(usedUp, #selector(toggleUsedUp)), (reset, #selector(toggleReset)),
                                  (openSettings, #selector(openNotificationSettings)), (allow, #selector(allowNow))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        openSettings.controlSize = .small
        allow.controlSize = .small
        let thresholds = NSStackView(views: [first, second])
        thresholds.spacing = 6
        let offRow = NSStackView(views: [off, openSettings]), askRow = NSStackView(views: [ask, allow])
        offRow.spacing = 8
        askRow.spacing = 8
        let alerts = SettingsForm.section("Alerts", [
            SettingsForm.row("Warn when a limit passes", control: thresholds),
            SettingsForm.row("When a limit is used up", control: usedUp),
            SettingsForm.row("When a limit resets", control: reset),
        ])
        self.alerts = alerts
        view = SettingsForm.page("Notifications", [
            offRow, askRow, alerts,
            SettingsForm.note("Usagi watches the limits of the account each service shows in the menu bar. Claude's numbers "
                              + "change only when Claude Code updates them, so an alert can come hours late."),
        ])
        refresh()
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let values = preferences.thresholds
        for (popup, value) in zip([first, second], values) {
            popup.selectItem(at: LimitAlerts.thresholdChoices.firstIndex(of: value).map { $0 + 1 } ?? 0)
        }
        usedUp.state = preferences.notifyUsedUp ? .on : .off
        reset.state = preferences.notifyReset ? .on : .off
        status { [weak self] status in
            guard let self else { return }
            let denied = status == .denied
            off.superview?.isHidden = !denied
            ask.superview?.isHidden = status != .notDetermined
            for control in [first, second, usedUp, reset] as [NSControl] { control.isEnabled = !denied }
            alerts?.alphaValue = denied ? 0.5 : 1
        }
    }

    @objc private func chooseThresholds() {
        preferences.thresholds = [first, second].map { $0.indexOfSelectedItem > 0 ? LimitAlerts.thresholdChoices[$0.indexOfSelectedItem - 1] : 0 }
    }

    @objc private func toggleUsedUp() { preferences.notifyUsedUp = usedUp.state == .on }

    @objc private func toggleReset() { preferences.notifyReset = reset.state == .on }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    @objc private func allowNow() { request { [weak self] _ in self?.refresh() } }
}

/// Settings > About: the version and update check, links and acknowledgements.
final class AboutPane: SettingsPage {
    static let repository = "https://github.com/Extransload/usagi"
    private let version: String
    private let actions: SettingsActions
    private let status = NSTextField(labelWithString: "")
    private let check = NSButton(title: "Check for Updates", target: nil, action: nil)

    init(version: String, actions: SettingsActions) {
        self.version = version
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "Usagi \(version)")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        status.textColor = .secondaryLabelColor
        check.target = self
        check.action = #selector(checkOrUpdate)
        let texts = NSStackView(views: [name, status, check])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        let header = NSStackView(views: [icon, texts])
        header.spacing = 14
        func link(_ title: String, _ url: String) -> NSView {
            let button = LinkButton(title: "Open", url: url)
            return SettingsForm.row(title, control: button)
        }
        view = SettingsForm.page("About", [
            header,
            SettingsForm.section("Links", [
                link("GitHub", Self.repository), link("Releases", Self.repository + "/releases"),
                link("Changelog", Self.repository + "/blob/main/CHANGELOG.md"),
            ]),
            SettingsForm.section("Acknowledgements", [
                SettingsForm.row("Menu bar logos from CodexBar (MIT)", detail: "© 2026 Peter Steinberger",
                                 control: LinkButton(title: "Open", url: "https://github.com/steipete/CodexBar")),
            ]),
        ])
        refresh()
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let info = actions.update()
        var line = UpdateStatus.line(info)
        if info?["failed"] == nil, let seconds = info?["checked_at"].flatMap(Double.init) {
            line += " · checked " + SettingsForm.relative(Date(timeIntervalSince1970: seconds))
        }
        status.stringValue = line
        check.title = info?["version"].map { "Update to \($0)…" } ?? "Check for Updates"
    }

    @objc private func checkOrUpdate() {
        if actions.update()?["version"] != nil {
            actions.openUpdate()
        } else {
            status.stringValue = "Checking…"
            actions.checkForUpdates()
        }
    }
}

/// A small button that opens a web page.
final class LinkButton: NSButton {
    private var url: String = ""

    convenience init(title: String, url: String) {
        self.init(title: title, target: nil, action: nil)
        self.url = url
        controlSize = .small
        target = self
        action = #selector(open)
    }

    @objc private func open() {
        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
    }
}
