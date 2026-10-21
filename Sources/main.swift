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

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdatesNow), keyEquivalent: "").target = self
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
        controller.onResize = { [weak self] height in self?.popover.contentSize = NSSize(width: 380, height: height) }
        popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        controller.loadViewIfNeeded()
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
        } else if let button = statusItem.button {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Key even when the system declines the activation, so Escape and the arrow keys reach the page.
            controller.view.window?.makeKey()
            refreshIcons()
            checkForUpdate()
        }
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { controller.refresh(.user) }

    /// From the right-click menu: check now and open the menu, where the footer or the banner shows the answer.
    @objc private func checkForUpdatesNow() {
        checkForUpdate(force: true) { [weak self] in
            guard let self, !self.popover.isShown, let button = self.statusItem.button else { return }
            NSApp.activate()
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.controller.view.window?.makeKey()
        }
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

    private func checkForUpdate(force: Bool = false, then done: (@MainActor () -> Void)? = nil) {
        Updates.check(force: force) { [weak self] info in
            self?.controller.setUpdate(info)
            done?()
        }
    }

    /// Up to two cards' usage with provider icons, or the rabbit when there are no cards. Dimmed (and
    /// "not up to date" for VoiceOver) when the last refresh failed or the last success is older than 15 minutes.
    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let stale = MenuBar.isStale(lastSuccess: controller.lastSuccess, failed: controller.lastError != nil, now: Date())
        button.toolTip = MenuBar.tooltip(updated: controller.lastSuccess.map(Self.timeText), error: controller.lastError)
        let (items, more) = controller.snapshot.map(MenuBar.items) ?? ([], 0)
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
