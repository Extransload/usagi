import Foundation

/// Every Usagi setting, kept in UserDefaults. Each change posts `didChange`, which redraws the menu bar and Settings.
@MainActor final class Preferences {
    static let didChange = Notification.Name("UsagiPreferencesDidChange")
    private let defaults = UserDefaults.standard

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Stores `value` (nil removes the key) and announces it, unless nothing changes.
    private func store(_ value: Any?, _ key: String) {
        let old = defaults.object(forKey: key)
        if let value {
            if let old, (old as AnyObject).isEqual(value) { return }
            defaults.set(value, forKey: key)
        } else {
            guard old != nil else { return }
            defaults.removeObject(forKey: key)
        }
        changed()
    }

    // MARK: Services

    func color(_ provider: String) -> RGB {
        MenuBarStyle.color(provider, stored: defaults.string(forKey: MenuBarStyle.colorKey(provider)))
    }

    /// nil, or the default itself, puts back the default (so a later change of default applies).
    func setColor(_ color: RGB?, for provider: String) {
        store(color.flatMap { $0 == MenuBarStyle.color(provider, stored: nil) ? nil : $0.hex }, MenuBarStyle.colorKey(provider))
    }

    var hidden: Set<String> { Set(defaults.stringArray(forKey: MenuBar.hiddenKey) ?? []) }

    func setShown(_ shown: Bool, _ provider: String) {
        var hidden = self.hidden
        guard hidden.contains(provider) == shown else { return }
        if shown { hidden.remove(provider) } else { hidden.insert(provider) }
        store(hidden.sorted(), MenuBar.hiddenKey)
    }

    /// The limit a service's menu bar percentage follows: "auto" or a window key.
    func limit(_ provider: String) -> String {
        defaults.string(forKey: MenuBarStyle.limitKey(provider)) ?? MenuBar.autoLimit
    }

    func setLimit(_ limit: String, for provider: String) {
        store(limit == MenuBar.autoLimit ? nil : limit, MenuBarStyle.limitKey(provider))
    }

    var limits: [String: String] {
        Dictionary(uniqueKeysWithValues: MenuBar.allServices.map { ($0, limit($0)) })
    }

    /// The old "Menu Bar Shows" count becomes switches once there are cards to order the services, then is forgotten.
    /// Services without cards yet come last, so they stay off as they would have been left out before. Runs while the
    /// menu bar is being drawn, so it doesn't announce the change.
    func migrate(_ snapshot: [String: Any]) {
        guard let limit = defaults.object(forKey: MenuBar.serviceLimitKey) as? Int, !MenuBar.order(snapshot).isEmpty else { return }
        if defaults.object(forKey: MenuBar.hiddenKey) == nil {
            defaults.set(MenuBar.hidden(migrating: limit, order: MenuBar.services(snapshot)).sorted(), forKey: MenuBar.hiddenKey)
        }
        defaults.removeObject(forKey: MenuBar.serviceLimitKey)
    }

    // MARK: Menu bar

    var textSize: MenuBarStyle.TextSize {
        get { defaults.string(forKey: MenuBarStyle.textSizeKey).flatMap(MenuBarStyle.TextSize.init(rawValue:)) ?? .regular }
        set { store(newValue == .regular ? nil : newValue.rawValue, MenuBarStyle.textSizeKey) }
    }

    var showsLogos: Bool {
        get { defaults.object(forKey: MenuBarStyle.showsLogosKey) as? Bool ?? true }
        set { store(newValue ? nil : false, MenuBarStyle.showsLogosKey) }
    }

    var showsRemaining: Bool {
        get { defaults.bool(forKey: MenuBarStyle.showsRemainingKey) }
        set { store(newValue ? true : nil, MenuBarStyle.showsRemainingKey) }
    }

    // MARK: General

    /// How often Usagi refreshes while the menu is closed.
    var refreshInterval: TimeInterval {
        get { Cadence.hiddenInterval(stored: defaults.object(forKey: Cadence.intervalKey) as? Int) }
        set { store(newValue == Cadence.hidden ? nil : Int(newValue), Cadence.intervalKey) }
    }

    // MARK: Notifications

    /// The two "Warn when a limit passes" values; 0 is Off.
    var thresholds: [Int] {
        get {
            let stored = defaults.array(forKey: LimitAlerts.thresholdsKey) as? [Int] ?? []
            return stored.count == 2 ? stored : LimitAlerts.defaultThresholds
        }
        set { store(newValue == LimitAlerts.defaultThresholds ? nil : newValue, LimitAlerts.thresholdsKey) }
    }

    var notifyUsedUp: Bool {
        get { defaults.object(forKey: LimitAlerts.usedUpKey) as? Bool ?? true }
        set { store(newValue ? nil : false, LimitAlerts.usedUpKey) }
    }

    var notifyReset: Bool {
        get { defaults.object(forKey: LimitAlerts.resetKey) as? Bool ?? true }
        set { store(newValue ? nil : false, LimitAlerts.resetKey) }
    }
}
