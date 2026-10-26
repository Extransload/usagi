import AppKit

/// Settings kept in UserDefaults: each service's color and whether the menu bar shows it. `changed` redraws the menu bar.
@MainActor final class MenuBarSettings {
    var changed: () -> Void = {}
    private let defaults = UserDefaults.standard

    func color(_ provider: String) -> RGB {
        MenuBarStyle.color(provider, stored: defaults.string(forKey: MenuBarStyle.colorKey(provider)))
    }

    /// nil, or the default itself, puts back the default (so a later change of default applies).
    func setColor(_ color: RGB?, for provider: String) {
        let key = MenuBarStyle.colorKey(provider)
        let hex = color.flatMap { $0 == MenuBarStyle.color(provider, stored: nil) ? nil : $0.hex }
        guard hex != defaults.string(forKey: key) else { return }
        if let hex { defaults.set(hex, forKey: key) } else { defaults.removeObject(forKey: key) }
        changed()
    }

    var hidden: Set<String> { Set(defaults.stringArray(forKey: MenuBar.hiddenKey) ?? []) }

    func setShown(_ shown: Bool, _ provider: String) {
        var hidden = self.hidden
        guard hidden.contains(provider) == shown else { return }
        if shown { hidden.remove(provider) } else { hidden.insert(provider) }
        defaults.set(hidden.sorted(), forKey: MenuBar.hiddenKey)
        changed()
    }

    /// The old "Menu Bar Shows" count becomes switches once there are cards to order the services, then is forgotten.
    /// Services without cards yet come last, so they stay off as they would have been left out before.
    func migrate(_ snapshot: [String: Any]) {
        guard let limit = defaults.object(forKey: MenuBar.serviceLimitKey) as? Int, !MenuBar.order(snapshot).isEmpty else { return }
        if defaults.object(forKey: MenuBar.hiddenKey) == nil {
            defaults.set(MenuBar.hidden(migrating: limit, order: MenuBar.services(snapshot)).sorted(), forKey: MenuBar.hiddenKey)
        }
        defaults.removeObject(forKey: MenuBar.serviceLimitKey)
    }
}

/// The Settings window, opened from the status item's right-click menu: one section per service, in card order.
@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    static let width: CGFloat = 380
    private var window: NSWindow?
    private var sections: [ServiceSection] = []

    func show(_ settings: MenuBarSettings, services: [String]) {
        if window == nil || sections.map(\.provider) != services { build(settings, services: services) }
        sections.forEach { $0.refresh() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build(_ settings: MenuBarSettings, services: [String]) {
        sections.forEach { $0.stopPicking() }  // the color panel must not keep driving a well that is going away
        sections = services.map { ServiceSection(provider: $0, settings: settings) }
        sections.forEach { $0.resized = { [weak self] in self?.fit() } }
        let note = NSTextField(wrappingLabelWithString: "A service's logo and percentage are drawn in its color. While a menu "
                                   + "is open, the numbers are out of date, or Increase contrast is on in System Settings, "
                                   + "the menu bar shows them without color.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = Self.width
        let stack = NSStackView(views: sections.map(\.view) + [note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let window = self.window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Usagi Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = stack
        let new = self.window == nil
        self.window = window
        fit()
        if new { window.center() }  // once it has its size, or its left edge ends up in the middle
    }

    /// Follows the content's height (a contrast warning comes and goes).
    private func fit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let top = window.frame.maxY
        window.setContentSize(content.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    /// Like the popover, hands the keyboard back to the app that had it once nothing of Usagi's is left open.
    func windowWillClose(_ notification: Notification) {
        sections.forEach { $0.stopPicking() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if NSApp.isActive && NSApp.keyWindow == nil { NSApp.deactivate() }
            }
        }
    }
}

/// One service: Show in menu bar, its color (hex and color well), the default with Reset, and a contrast warning.
@MainActor private final class ServiceSection: NSObject, NSTextFieldDelegate {
    let provider: String
    let view: NSView
    var resized: () -> Void = {}
    private let settings: MenuBarSettings
    private let shown = NSSwitch()
    private let hex = NSTextField(string: "")
    private let well = NSColorWell(style: .default)
    private let reset = NSButton(title: "Reset", target: nil, action: nil)
    private let warning = NSTextField(wrappingLabelWithString: "")

    private var standard: RGB { MenuBarStyle.color(provider, stored: nil) }

    init(provider: String, settings: MenuBarSettings) {
        self.provider = provider
        self.settings = settings
        let title = NSTextField(labelWithString: MenuBar.names[provider] ?? provider)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        hex.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        hex.placeholderString = "#RRGGBB"
        hex.widthAnchor.constraint(equalToConstant: 84).isActive = true
        well.supportsAlpha = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        reset.bezelStyle = .push
        reset.controlSize = .small
        let colors = NSStackView(views: [hex, well])
        colors.spacing = 8
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Show in menu bar"), shown],
            [NSTextField(labelWithString: "Color"), colors],
            [NSTextField(labelWithString: "Default \(MenuBarStyle.color(provider, stored: nil).hex)"), reset],
        ])
        grid.column(at: 0).width = SettingsWindow.width - 150
        grid.column(at: 1).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.cell(for: shown)?.yPlacement = .center
        warning.textColor = .secondaryLabelColor
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.preferredMaxLayoutWidth = SettingsWindow.width
        let stack = NSStackView(views: [title, grid, warning])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        view = stack
        super.init()
        for control in [shown, well, reset] as [NSControl] {
            control.target = self
        }
        shown.action = #selector(toggleShown)
        well.action = #selector(pickColor)
        reset.action = #selector(resetColor)
        hex.delegate = self
    }

    /// `well` is false while the color well itself is being dragged, so its panel isn't pulled back to the stored hex.
    func refresh(well updateWell: Bool = true) {
        let color = settings.color(provider)
        shown.state = settings.hidden.contains(provider) ? .off : .on
        // Typing that already spells the color (say in lower case) is left alone.
        if RGB(hex: hex.stringValue) != color { hex.stringValue = color.hex }
        if updateWell { well.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }
        reset.isEnabled = color != standard
        let message = MenuBarStyle.contrastWarning(color)
        if warning.isHidden != (message == nil) || warning.stringValue != (message.map { "⚠︎ " + $0 } ?? "") {
            warning.stringValue = message.map { "⚠︎ " + $0 } ?? ""
            warning.isHidden = message == nil
            resized()
        }
    }

    func stopPicking() {
        if well.isActive { well.deactivate() }
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    @objc private func toggleShown() {
        settings.setShown(shown.state == .on, provider)
    }

    @objc private func pickColor() {
        guard let srgb = well.color.usingColorSpace(.sRGB) else { return }
        settings.setColor(RGB(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)),
                          for: provider)
        refresh(well: false)
    }

    @objc private func resetColor() {
        settings.setColor(nil, for: provider)
        refresh()
    }

    /// A valid hex applies as it is typed; anything else is put back when editing ends.
    func controlTextDidChange(_ notification: Notification) {
        guard let typed = RGB(hex: hex.stringValue) else { return }
        settings.setColor(typed, for: provider)
        refresh()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hex.stringValue = settings.color(provider).hex
    }
}
