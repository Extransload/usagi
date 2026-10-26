import AppKit
import Carbon.HIToolbox

/// The global "Open Usagi" shortcut, as a Carbon hot key: it works in any app and needs no permission.
@MainActor final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (@MainActor () -> Void)?

    /// Registers `shortcut` in place of the current one; nil just unregisters. False when the system refuses it, for
    /// example because another app holds the same shortcut.
    func register(_ shortcut: Shortcut?, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        guard let shortcut else { return true }
        guard shortcut.isAllowed else { return false }
        installHandler()
        Self.action = action
        var hotKey: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5553_4147), id: 1)  // "USAG"
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
        else { return false }
        reference = hotKey
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Hot key events arrive on the main thread, through the application's event target.
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}

/// Click, then press the shortcut; Escape cancels. A shortcut without ⌘, ⌥ or ⌃ is refused with a beep.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }
    var changed: (Shortcut?) -> Void = { _ in }
    /// Lets the owner pause the hot key while a new one is typed, so pressing the old one doesn't open the menu.
    var recordingChanged: (Bool) -> Void = { _ in }
    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            updateTitle()
            recordingChanged(recording)
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(toggle)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(toggle)
        updateTitle()
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggle() {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    // Shortcuts with ⌘ arrive as key equivalents before they reach keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recording { record(event) } else { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: Self.keyName(event))
        guard candidate.isAllowed else {
            NSSound.beep()
            return
        }
        recording = false
        shortcut = candidate
        changed(candidate)
    }

    private func updateTitle() {
        title = recording ? "Type Shortcut…" : shortcut?.display ?? "Record Shortcut"
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key's name without any modifier applied (⇧⌘2 is "2", not "@").
    private static func keyName(_ event: NSEvent) -> String {
        names[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
    }
}
