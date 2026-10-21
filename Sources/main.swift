import AppKit

enum Updates {
    static let latest = URL(string: "https://api.github.com/repos/Extransload/usagi/releases/latest")!
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    @MainActor private static var schedule = UpdateSchedule()

    /// Reports every finished check (newer, up to date or failed) so the page can say which.
    @MainActor static func check(force: Bool = false, then report: @escaping @MainActor ([String: String]) -> Void) {
        guard schedule.begin(now: Date(), force: force) else { return }
        Task {
            let version = await latestVersion()
            schedule.finish(success: version != nil, now: Date())
            report(UpdateStatus.info(latest: version, current: current, now: Date()))
        }
    }

    static func latestVersion() async -> String? {
        var request = URLRequest(url: latest, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await Network.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = release["tag_name"] as? String, !Version.parts(tag).isEmpty else { return nil }
            return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        } catch {
            return nil
        }
    }
}

/// `launchctl` in the user's launchd domain: the environment apps opened from now on inherit (no admin rights needed).
enum LaunchEnvironment {
    private static let queue = DispatchQueue(label: "usagi.launchctl", qos: .utility)

    static func current(_ names: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            let value = run(["getenv", name]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
        }
        return values
    }

    /// Applies `wanted` (nil = the option is off) off the main thread. Only someone else's replaced values are
    /// recorded (to put them back later); if a provider's folder change fails, its trackers are left as they are.
    /// `failed` runs (on the main thread) when a call fails, so the next snapshot tries again.
    static func sync(_ wanted: [String: AppEnvironment.Target]?, home: String, failed: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            let defaults = UserDefaults.standard
            if wanted == nil && !defaults.bool(forKey: AppEnvironment.inUseKey) { return }  // never used: nothing to undo
            var previous = defaults.dictionary(forKey: AppEnvironment.previousKey) as? [String: String] ?? [:]
            let now = current(AppEnvironment.variables)
            for name in AppEnvironment.variables {  // someone else's value is back (or set anew): nothing to put back
                if let value = now[name], !AppEnvironment.isUsagis(name, value, home: home) { previous[name] = nil }
            }
            var ok = true, folderFailed = Set<String>()
            for change in AppEnvironment.changes(wanted: wanted, current: now, previous: previous, home: home) {
                guard let owner = AppEnvironment.owner(change.name), !folderFailed.contains(owner.key) else { continue }
                if change.ours {
                    defaults.set(true, forKey: AppEnvironment.inUseKey)
                    if let before = now[change.name], !AppEnvironment.isUsagis(change.name, before, home: home) {
                        previous[change.name] = before
                        save(previous)
                    }
                }
                let done = run(change.value.map { ["setenv", change.name, $0] } ?? ["unsetenv", change.name]).ok
                if done && !change.ours { previous[change.name] = nil }
                if !done && owner.folder { folderFailed.insert(owner.key) }
                ok = done && ok
            }
            save(previous)
            if wanted == nil && ok { defaults.set(false, forKey: AppEnvironment.inUseKey) }
            if !ok { DispatchQueue.main.async { MainActor.assumeIsolated { failed() } } }
        }
    }

    private static func save(_ previous: [String: String]) {
        UserDefaults.standard.set(previous, forKey: AppEnvironment.previousKey)
    }

    private static func run(_ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (false, "") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: UsageController!

    private static let rabbit: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            for (x, angle, level) in [(4.25, -8.0, 5.0), (10.45, 8.0, 6.9)] {
                NSGraphicsContext.saveGraphicsState()
                let tilt = NSAffineTransform()
                tilt.translateX(by: x + 1.65, yBy: 9)
                tilt.rotate(byDegrees: angle)
                tilt.translateX(by: -(x + 1.65), yBy: -9)
                tilt.concat()
                let ear = NSBezierPath(roundedRect: NSRect(x: x, y: 1.35, width: 3.3, height: 8),
                                       xRadius: 1.65, yRadius: 1.65)
                ear.lineWidth = 1.1
                ear.stroke()
                ear.addClip()
                NSBezierPath(rect: NSRect(x: x, y: level, width: 3.3, height: 9.35 - level)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let head = NSBezierPath(ovalIn: NSRect(x: 3.3, y: 8.2, width: 11.4, height: 9))
            head.append(NSBezierPath(ovalIn: NSRect(x: 6.15, y: 11.5, width: 1.8, height: 1.8)))
            head.append(NSBezierPath(ovalIn: NSRect(x: 10.05, y: 11.5, width: 1.8, height: 1.8)))
            head.windingRule = .evenOdd
            head.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usagi"
        return image
    }()

    private let servicesMenu = NSMenu()
    private let alsoUseInAppsItem = NSMenuItem(title: "Also Use in Apps", action: #selector(toggleAlsoUseInApps), keyEquivalent: "")
    private var syncedSnapshot: Date?, syncedOff = false  // the snapshot last synced, to skip repeats
    private var requestedHeight: Double = 540

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdatesNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Menu Bar Shows", action: nil, keyEquivalent: "").submenu = servicesMenu
        alsoUseInAppsItem.target = self
        menu.addItem(alsoUseInAppsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Usagi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A Homebrew and a source install can both be started: the copy launched first wins. An update
        // isn't affected, because Homebrew quits the old copy before the new one opens.
        if let id = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
            if SingleInstance.shouldQuit(own: (getpid(), NSRunningApplication.current.launchDate),
                                         running: running.map { ($0.processIdentifier, $0.launchDate) }) {
                NSApp.terminate(nil)
                return
            }
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.rabbit
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        controller = UsageController()
        controller.onStatus = { [weak self] in self?.updateStatus() }
        controller.onCheckUpdates = { [weak self] in self?.checkForUpdate(force: true) }
        controller.onResize = { [weak self] height in
            self?.requestedHeight = Double(height)
            self?.fitPopover()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.fitPopover() } }
        popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        controller.loadViewIfNeeded()
        controller.setAlsoUseInApps(alsoUseInApps)
        updateStatus()
        refreshIcons()
        checkForUpdate()
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
            refreshIcons()
            checkForUpdate()
        }
    }

    /// The page's full height, fitted to the space below the menu bar on the screen the status item is on
    /// (refitted before every open, so a smaller screen or a moved Dock never gets a too-tall popover).
    private func fitPopover() {
        let window = statusItem.button?.window
        let available = (window?.screen ?? NSScreen.main).map { screen in
            Double(window.map { $0.frame.minY - screen.visibleFrame.minY } ?? screen.visibleFrame.height)
        }
        popover.contentSize = NSSize(width: 380, height: PopoverHeight.fit(requestedHeight, available: available))
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        fitPopover()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key even when the system declines the activation, so Escape and the arrow keys reach the page.
        controller.view.window?.makeKey()
    }

    /// How many services the menu bar shows before "+N" (UserDefaults; 0 = all).
    private var serviceLimit: Int? {
        MenuBar.serviceLimit(stored: UserDefaults.standard.object(forKey: MenuBar.serviceLimitKey) as? Int)
    }

    /// The largest choice is stored as 0 (all), so a service added later shows up without changing this.
    @objc private func setMenuBarServices(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag == servicesMenu.items.count ? 0 : sender.tag, forKey: MenuBar.serviceLimitKey)
        updateStatus()
    }

    private func buildServicesMenu() {
        let services = controller.snapshot.map { MenuBar.items($0, limit: nil).items.count } ?? 0
        let stored = UserDefaults.standard.object(forKey: MenuBar.serviceLimitKey) as? Int
        let (choices, checked) = MenuBar.serviceChoices(services: services, stored: stored)
        servicesMenu.removeAllItems()
        for count in choices {
            let item = servicesMenu.addItem(withTitle: count == 1 ? "1 Service" : "\(count) Services",
                                            action: #selector(setMenuBarServices(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = count == checked ? .on : .off
        }
    }

    private var alsoUseInApps: Bool { UserDefaults.standard.bool(forKey: AppEnvironment.enabledKey) }

    /// Off: undo what Usagi set. On: apps opened from now on use the Active accounts, like new terminals.
    @objc private func toggleAlsoUseInApps() {
        UserDefaults.standard.set(!alsoUseInApps, forKey: AppEnvironment.enabledKey)
        controller.setAlsoUseInApps(alsoUseInApps)
        syncAppEnvironment(force: true)
    }

    /// Runs after each new snapshot (and when the option is toggled): checks launchd and sets or undoes what
    /// the Active accounts need. While the option is off, only the first sync after turning it off is needed.
    private func syncAppEnvironment(force: Bool = false) {
        if !force && controller.lastSuccess == syncedSnapshot { return }
        let wanted = alsoUseInApps ? controller.snapshot.map { AppEnvironment.wanted($0, home: NSHomeDirectory()) } : nil
        if alsoUseInApps && wanted == nil { return }  // no snapshot yet
        if !force && wanted == nil && syncedOff { return }
        syncedSnapshot = controller.lastSuccess
        syncedOff = wanted == nil
        LaunchEnvironment.sync(wanted, home: NSHomeDirectory()) { [weak self] in
            self?.syncedSnapshot = nil
            self?.syncedOff = false
        }
    }

    private func showMenu() {
        alsoUseInAppsItem.state = alsoUseInApps ? .on : .off
        buildServicesMenu()
        if popover.isShown { popover.performClose(nil) }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { controller.refresh(.user) }

    /// From the right-click menu: open the menu and let the page start the check, as a click on its footer
    /// does, so "Checking…", "Up to date", the banner or "Couldn't check" show there.
    @objc private func checkForUpdatesNow() {
        showPopover()
        controller.checkForUpdatesFromMenu()
    }

    /// Quit Usagi (menu or page) ends here too: don't leave a bridge run behind.
    func applicationWillTerminate(_ notification: Notification) { Bridge.stopAll() }

    func popoverDidShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
        controller.popoverOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        controller.popoverClosed()
        if NSApp.isActive && NSApp.keyWindow == nil && statusItem.menu == nil { NSApp.deactivate() }
    }

    private func refreshIcons() {
        ProviderIcons.refreshWebIcons { [weak self] in
            self?.controller.sendProviderIcons()
            self?.updateStatus()
        }
    }

    private func checkForUpdate(force: Bool = false) {
        Updates.check(force: force) { [weak self] info in self?.controller.setUpdate(info) }
    }

    /// One item per service (its Active account) up to the Menu Bar Shows limit, or the rabbit when there are no cards. Dimmed (and
    /// "not up to date" for VoiceOver) when the last refresh failed or the last success is older than 15 minutes.
    private func updateStatus() {
        syncAppEnvironment()
        guard let button = statusItem.button else { return }
        let stale = MenuBar.isStale(lastSuccess: controller.lastSuccess, failed: controller.lastError != nil, now: Date())
        button.toolTip = MenuBar.tooltip(updated: controller.lastSuccess.map(Self.timeText), error: controller.lastError)
        let (items, more) = controller.snapshot.map { MenuBar.items($0, limit: serviceLimit) } ?? ([], 0)
        button.setAccessibilityLabel(MenuBar.accessibilityLabel(items, more: more, stale: stale))
        guard !items.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = Self.rabbit
            button.appearsDisabled = stale
            return
        }
        let label = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { label.append(NSAttributedString(string: "   ")) }
            if let icon = ProviderIcons.menuImage(item.provider) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
                label.append(NSAttributedString(attachment: attachment))
                label.append(NSAttributedString(string: " "))
            }
            label.append(NSAttributedString(string: MenuBar.percentText(item.percent)))
        }
        label.append(NSAttributedString(string: MenuBar.suffix(more: more)))
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]
        if stale { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        label.addAttributes(attributes, range: NSRange(location: 0, length: label.length))
        button.appearsDisabled = false
        button.image = nil
        button.attributedTitle = label
    }

    private static func timeText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
