import AppKit

/// What the Settings pages need from the rest of the app.
struct SettingsActions {
    var snapshot: @MainActor () -> [String: Any]?
    var lastSuccess: @MainActor () -> Date?
    /// The last update check's answer (UpdateStatus.info), if any.
    var update: @MainActor () -> [String: String]?
    var checkForUpdates: @MainActor () -> Void
    /// Opens the menu with its update banner, where updates run.
    var openUpdate: @MainActor () -> Void
    var alsoUseInApps: @MainActor () -> Bool
    var setAlsoUseInApps: @MainActor (Bool) -> Void
    var shortcutFailed: @MainActor () -> Bool
    var setShortcutPaused: @MainActor (Bool) -> Void
}

/// A Settings page. `refresh` re-reads Preferences and the app's state; `closing` runs when the window closes.
class SettingsPage: NSViewController {
    func refresh() {}
    func closing() {}
}

/// The Settings window: a sidebar of Usagi's pages and one page per service (in card order), and the selected page.
@MainActor final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row: Equatable {
        case group(String), pane(SettingsPane)
    }

    private let preferences: Preferences
    private let actions: SettingsActions
    private var window: NSWindow?
    private let table = NSTableView()
    private let content = NSViewController()
    private var rows: [Row] = []
    private var pages: [SettingsPane: SettingsPage] = [:]
    private var current: SettingsPane?
    /// Makes the page for a pane that has no page of its own yet.
    var makePage: @MainActor (SettingsPane) -> SettingsPage? = { _ in nil }

    init(preferences: Preferences, actions: SettingsActions) {
        self.preferences = preferences
        self.actions = actions
        super.init()
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(selecting pane: SettingsPane? = nil) {
        if window == nil { build() }
        // Services follow the card order; a reorder while the window is open shows here the next time it opens.
        let services = MenuBar.services(actions.snapshot()).map { Row.pane(.service($0)) }
        let wanted: [Row] = [.group("Usagi"), .pane(.general), .pane(.menuBar), .pane(.notifications), .pane(.about),
                             .group("Services")] + services
        if wanted != rows {
            rows = wanted
            table.reloadData()
        }
        select(pane ?? preferences.settingsPane)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// After a change to Preferences, a new snapshot or an update check.
    func refresh() {
        guard isVisible else { return }
        let services = rows.indices.filter { if case .pane(.service) = rows[$0] { return true } else { return false } }
        table.reloadData(forRowIndexes: IndexSet(services), columnIndexes: [0])  // logos in their current colors
        current.flatMap { pages[$0] }?.refresh()
    }

    private func build() {
        table.style = .sourceList
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane")))
        table.dataSource = self
        table.delegate = self
        table.floatsGroupRows = false
        table.rowSizeStyle = .medium
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = table
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        let sidebar = NSViewController()
        sidebar.view = sidebarScroll
        content.view = NSView()
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        let window = NSWindow(contentViewController: split)
        window.title = "Usagi Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 720, height: 520))
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.center()
        self.window = window
    }

    private func select(_ pane: SettingsPane) {
        let target = rows.contains(.pane(pane)) ? pane : .general
        if let index = rows.firstIndex(of: .pane(target)), table.selectedRow != index {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        show(page: target)
    }

    private func show(page pane: SettingsPane) {
        guard pane != current else { return }
        current = pane
        preferences.settingsPane = pane
        guard let page = pages[pane] ?? makePage(pane) ?? (pane.serviceProvider.map {
            ServicePane(provider: $0, preferences: preferences, actions: actions)
        }) else { return }
        pages[pane] = page
        content.view.subviews.forEach { $0.removeFromSuperview() }
        let view = page.view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
        ])
        page.refresh()
    }

    // MARK: Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        switch rows[row] {
        case .group(let title):
            label.stringValue = title
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        case .pane(let pane):
            label.stringValue = title(pane)
            let image = NSImageView(image: icon(pane))
            cell.imageView = image
            for view in [image, label] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, case .pane(let pane) = rows[table.selectedRow] else { return }
        show(page: pane)
    }

    private func title(_ pane: SettingsPane) -> String {
        switch pane {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .notifications: return "Notifications"
        case .about: return "About"
        case .service(let provider): return MenuBar.names[provider] ?? provider
        }
    }

    private func icon(_ pane: SettingsPane) -> NSImage {
        switch pane {
        case .general: return SettingsForm.icon("gearshape.fill", .systemGray)
        case .menuBar: return SettingsForm.icon("menubar.rectangle", .systemBlue)
        case .notifications: return SettingsForm.icon("bell.badge.fill", .systemRed)
        case .about: return SettingsForm.icon("info", .systemGreen)
        case .service(let provider):
            let color = preferences.color(provider)
            return MenuBarGlyphs.image(provider, color: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1),
                                       size: 18) ?? NSImage()
        }
    }

    // MARK: Window

    /// Like the popover, hands the keyboard back to the app that had it once nothing of Usagi's is left open.
    func windowWillClose(_ notification: Notification) {
        pages.values.forEach { $0.closing() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if NSApp.isActive && NSApp.keyWindow == nil { NSApp.deactivate() }
            }
        }
    }
}

extension SettingsPane {
    var serviceProvider: String? {
        if case .service(let provider) = self { return provider }
        return nil
    }
}
