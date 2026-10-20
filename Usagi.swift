import AppKit
import Foundation
import WebKit

private final class Bridge {
    static func run(_ arguments: [String]) throws -> Data {
        guard let script = Bundle.main.url(forResource: "bridge", withExtension: "py") else {
            throw NSError(domain: "Usagi", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage reader not found."])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            throw NSError(domain: "Usagi", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: parsed?["error"] ?? "Command failed."])
        }
        return data
    }
}

private final class UsageController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    var onSnapshot: ((Data) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    private var webView: WKWebView!
    private var refreshTimer: Timer?
    private var loginTimer: Timer?
    private var pendingLogin: (provider: String, account: String)?
    private var loading = false
    private var pendingActions: [[String]] = []

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "agentUsage")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 540), configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let page = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.perform(["snapshot"])
        }
    }

    deinit {
        refreshTimer?.invalidate()
        loginTimer?.invalidate()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "agentUsage")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendProviderIcons()
        if let update { sendUpdate(update) }
        perform(["snapshot"])
    }

    private var update: [String: String]?

    func sendUpdate(_ info: [String: String]) {
        update = info
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        webView.evaluateJavaScript("window.setUpdate(\(String(decoding: json, as: UTF8.self)))", completionHandler: nil)
    }

    private func finishUpdate(_ result: Data) {
        if let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
           let link = object["release_url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        send("window.receiveUpdateResult", data: result)
    }

    func sendProviderIcons() {
        guard let json = try? JSONSerialization.data(withJSONObject: ProviderIcons.dataURLs()) else { return }
        webView.evaluateJavaScript("window.setProviderIcons(\(String(decoding: json, as: UTF8.self)))",
                                   completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String], let action = body["action"] else { return }
        switch action {
        case "snapshot": perform(["snapshot"])
        case "resize":
            if let value = body["account"], let height = Double(value) {
                onResize?(CGFloat(min(540, max(260, height))))
            }
        case "select", "login", "remove":
            guard let provider = body["provider"], ["claude", "codex"].contains(provider),
                  let account = body["account"] else { return }
            perform([action, provider, account])
        case "add":
            guard let provider = body["provider"], ["claude", "codex"].contains(provider),
                  let account = body["account"] else { return }
            perform(["add", provider, account])
        case "add_auto":
            guard let provider = body["provider"], ["claude", "codex"].contains(provider) else { return }
            perform(["add_auto", provider])
        case "update": perform(["update"])
        case "quit": NSApplication.shared.terminate(nil)
        default: break
        }
    }

    func perform(_ arguments: [String]) {
        guard !loading else {
            if arguments.first != "snapshot" && !pendingActions.contains(arguments) {
                pendingActions.append(arguments)
            }
            return
        }
        if arguments.first == "login", arguments.count == 3 {
            pendingLogin = (arguments[1], arguments[2])
            loginTimer?.invalidate()
            loginTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.perform(["snapshot"])
            }
        }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Bridge.run(arguments)
                if arguments.first == "update" {
                    DispatchQueue.main.async { self?.finishUpdate(result) }
                }
                let data = ["login", "update"].contains(arguments.first) ? try Bridge.run(["snapshot"]) : result
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.onSnapshot?(data)
                    self?.send("window.receiveSnapshot", data: data)
                    self?.updateLoginState(from: data)
                    if let next = self?.pendingActions.first {
                        self?.pendingActions.removeFirst()
                        self?.perform(next)
                    }
                }
            } catch {
                let data = Data(error.localizedDescription.utf8)
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.send("window.receiveError", data: data)
                    if arguments.first == "login" {
                        self?.pendingLogin = nil
                        self?.loginTimer?.invalidate()
                        self?.loginTimer = nil
                    }
                    if let next = self?.pendingActions.first {
                        self?.pendingActions.removeFirst()
                        self?.perform(next)
                    }
                }
            }
        }
    }

    private func updateLoginState(from data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else { return }
        let entries = providers.values.compactMap { ($0 as? [String: Any])?["accounts"] as? [[String: Any]] }.flatMap { $0 }
        if let login = pendingLogin,
           let provider = providers[login.provider] as? [String: Any],
           let accounts = provider["accounts"] as? [[String: Any]],
           let entry = accounts.first(where: { $0["id"] as? String == login.account }),
           entry["logged_in"] as? Bool == true || entry["connecting"] as? Bool != true {
            pendingLogin = nil
        }
        let connecting = entries.contains { $0["connecting"] as? Bool == true }
        if connecting && loginTimer == nil {
            loginTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.perform(["snapshot"])
            }
        } else if !connecting && pendingLogin == nil {
            loginTimer?.invalidate()
            loginTimer = nil
        }
    }

    private func send(_ function: String, data: Data) {
        webView.evaluateJavaScript("\(function)('\(data.base64EncodedString())')", completionHandler: nil)
    }
}

private let menuBarIcon: NSImage = {
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

private enum Updates {
    static let latest = URL(string: "https://api.github.com/repos/Extransload/usagi/releases/latest")!
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    static func check(then done: @escaping ([String: String]?) -> Void) {
        var request = URLRequest(url: latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = release["tag_name"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let info = newer(version, than: current) ? ["version": version, "current": current] : nil
            DispatchQueue.main.async { done(info) }
        }.resume()
    }

    static func newer(_ version: String, than other: String) -> Bool {
        let left = version.split(separator: ".").map { Int($0) ?? 0 }
        let right = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

private enum ProviderIcons {
    static let apps = ["claude": ["com.anthropic.claudefordesktop"], "codex": ["com.openai.codex", "com.openai.chat"]]
    static let web = ["claude": URL(string: "https://claude.ai/apple-touch-icon.png")!]
    static let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/usagi/icons")

    static func found(_ provider: String) -> NSImage? {
        for id in apps[provider] ?? [] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return tile(NSWorkspace.shared.icon(forFile: app.path), margin: 100.0 / 824)
            }
        }
        return NSImage(contentsOf: cache.appendingPathComponent(provider + ".png")).map { tile($0, margin: 0) }
    }

    static func image(_ provider: String) -> NSImage? {
        found(provider) ?? Bundle.main.url(forResource: provider, withExtension: "png", subdirectory: "assets")
            .flatMap(NSImage.init(contentsOf:))
    }

    static func dataURLs() -> [String: String] {
        var urls: [String: String] = [:]
        for provider in apps.keys {
            guard let tiff = found(provider)?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            urls[provider] = "data:image/png;base64," + png.base64EncodedString()
        }
        return urls
    }

    static func fetchMissing(then done: @escaping () -> Void) {
        for (provider, url) in web where found(provider) == nil {
            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count < 1_000_000,
                      NSImage(data: data) != nil else { return }
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                guard (try? data.write(to: cache.appendingPathComponent(provider + ".png"), options: .atomic)) != nil
                else { return }
                DispatchQueue.main.async(execute: done)
            }.resume()
        }
    }

    private static func tile(_ icon: NSImage, margin: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 29, yRadius: 29).addClip()
            icon.draw(in: rect.insetBy(dx: -rect.width * margin, dy: -rect.height * margin))
            return true
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: UsageController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon
        statusItem.button?.toolTip = "Usage and accounts"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        controller = UsageController()
        controller.onSnapshot = { [weak self] data in self?.updateStatus(data) }
        controller.loadViewIfNeeded()
        popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 540)
        controller.onResize = { [weak self] height in
            self?.popover.contentSize = NSSize(width: 380, height: height)
        }
        popover.behavior = .transient
        popover.animates = true
        ProviderIcons.fetchMissing { [weak self] in
            self?.controller.sendProviderIcons()
            self?.controller.perform(["snapshot"])
        }
        checkForUpdate()
    }

    private var lastUpdateCheck: Date?

    private func checkForUpdate() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        Updates.check { [weak self] info in
            self?.lastUpdateCheck = Date()
            if let info { self?.controller.sendUpdate(info) }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            checkForUpdate()
        }
    }

    private func updateStatus(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = object["providers"] as? [String: Any],
              let cards = object["cards"] as? [[String: String]] else { return }
        if cards.isEmpty {
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.image = menuBarIcon
            return
        }
        let parts = cards.prefix(2).map { card -> (String, String) in
            let key = card["provider"] ?? ""
            guard let provider = providers[key] as? [String: Any],
                  let accountID = card["id"],
                  let accounts = provider["accounts"] as? [[String: Any]],
                  let account = accounts.first(where: { $0["id"] as? String == accountID }),
                  let windows = account["windows"] as? [String: [String: Any]] else {
                return (key, "–")
            }
            let used = ["5h", "7d"].compactMap { windows[$0]?["used_percent"] as? Double }.max()
                ?? windows.values.compactMap { $0["used_percent"] as? Double }.max()
            return (key, used.map { "\(Int($0.rounded()))%" } ?? "–")
        }
        let label = NSMutableAttributedString(string: "")
        for (index, part) in parts.enumerated() {
            if index > 0 { label.append(NSAttributedString(string: "   ")) }
            if let icon = ProviderIcons.image(part.0) {
                icon.size = NSSize(width: 13, height: 13)
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
                label.append(NSAttributedString(attachment: attachment))
                label.append(NSAttributedString(string: " "))
            }
            label.append(NSAttributedString(string: part.1))
        }
        if cards.count > 2 { label.append(NSAttributedString(string: "  +\(cards.count - 2)")) }
        label.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                           range: NSRange(location: 0, length: label.length))
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = label
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
