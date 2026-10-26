import AppKit

/// A service's Settings page: whether and how the menu bar shows it, and its accounts.
final class ServicePane: SettingsPage, NSTextFieldDelegate {
    let provider: String
    private let preferences: Preferences
    private let actions: SettingsActions
    private let logo = NSImageView()
    private let shown = NSSwitch()
    private let hex = NSTextField(string: "")
    private let well = NSColorWell(style: .default)
    private let reset = NSButton(title: "Reset", target: nil, action: nil)
    private let warning = SettingsForm.note("")
    private let limit = NSPopUpButton()
    private let accounts = NSTextField(labelWithString: "")
    private let updated = NSTextField(labelWithString: "")
    private let cli = NSTextField(labelWithString: "")
    private var limitKeys: [String] = []

    private var standard: RGB { MenuBarStyle.color(provider, stored: nil) }
    private var name: String { MenuBar.names[provider] ?? provider }

    init(provider: String, preferences: Preferences, actions: SettingsActions) {
        self.provider = provider
        self.preferences = preferences
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        hex.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        hex.placeholderString = "#RRGGBB"
        hex.delegate = self
        hex.widthAnchor.constraint(equalToConstant: 84).isActive = true
        well.supportsAlpha = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        reset.bezelStyle = .push
        reset.controlSize = .small
        for (control, action) in [(shown, #selector(toggleShown)), (well, #selector(pickColor)), (reset, #selector(resetColor)),
                                  (limit, #selector(chooseLimit))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        for label in [accounts, updated, cli] {
            label.textColor = .secondaryLabelColor
            label.alignment = .right
        }
        accounts.maximumNumberOfLines = 0
        let colors = NSStackView(views: [hex, well])
        colors.spacing = 8
        view = SettingsForm.page(name, icon: logo, [
            SettingsForm.section("Menu bar", [
                SettingsForm.row("Show in menu bar", control: shown),
                SettingsForm.row("Color", detail: "Its logo and percentage are drawn in this color.", control: colors),
                SettingsForm.row("Default \(standard.hex)", control: reset),
                SettingsForm.row("Limit shown", detail: "The limit the menu bar percentage follows.", control: limit),
            ]),
            warning,
            SettingsForm.section("Status", [
                SettingsForm.row("Accounts", control: accounts),
                SettingsForm.row("Last updated", control: updated),
                SettingsForm.row(provider == "claude" ? "Claude Code" : "Codex CLI", control: cli),
            ]),
        ])
        refresh()
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let color = preferences.color(provider)
        logo.image = MenuBarGlyphs.image(provider, color: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1),
                                         size: 22)
        shown.state = preferences.hidden.contains(provider) ? .off : .on
        // Typing that already spells the color (say in lower case) is left alone.
        if RGB(hex: hex.stringValue) != color { hex.stringValue = color.hex }
        // Only when it differs as hex, so a drag in the color panel isn't pulled back to the stored 8-bit value.
        if pickedColor()?.hex != color.hex { well.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }
        reset.isEnabled = color != standard
        let message = MenuBarStyle.contrastWarning(color)
        warning.stringValue = message.map { "⚠︎ " + $0 } ?? ""
        warning.isHidden = message == nil

        let snapshot = actions.snapshot()
        let options = MenuBar.limitOptions(snapshot, provider: provider, stored: preferences.limit(provider))
        if options.map(\.key) != limitKeys || limit.itemTitles != options.map(\.title) {
            limit.removeAllItems()
            limit.addItems(withTitles: options.map(\.title))
            limitKeys = options.map(\.key)
        }
        limit.selectItem(at: limitKeys.firstIndex(of: preferences.limit(provider)) ?? 0)

        let names = MenuBar.accountNames(snapshot, provider: provider)
        accounts.stringValue = names.isEmpty ? "No accounts yet" : names.joined(separator: "\n")
        updated.stringValue = actions.lastSuccess().map { SettingsForm.relative($0) }
            ?? "Not updated yet"
        let found = (snapshot?["providers"] as? [String: Any]).flatMap { ($0[provider] as? [String: Any])?["cli"] as? Bool }
        cli.stringValue = found.map { $0 ? "Found" : "Not found" } ?? "–"
    }

    override func closing() {
        if well.isActive { well.deactivate() }
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    private func pickedColor() -> RGB? {
        well.color.usingColorSpace(.sRGB).map { RGB(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent)) }
    }

    @objc private func toggleShown() {
        preferences.setShown(shown.state == .on, provider)
    }

    @objc private func pickColor() {
        if let picked = pickedColor() { preferences.setColor(picked, for: provider) }
    }

    @objc private func resetColor() {
        preferences.setColor(nil, for: provider)
    }

    @objc private func chooseLimit() {
        guard limit.indexOfSelectedItem >= 0, limit.indexOfSelectedItem < limitKeys.count else { return }
        preferences.setLimit(limitKeys[limit.indexOfSelectedItem], for: provider)
    }

    /// A valid hex applies as it is typed; anything else is put back when editing ends.
    func controlTextDidChange(_ notification: Notification) {
        if let typed = RGB(hex: hex.stringValue) { preferences.setColor(typed, for: provider) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hex.stringValue = preferences.color(provider).hex
    }
}
