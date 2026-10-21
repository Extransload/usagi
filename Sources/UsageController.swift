import AppKit
import WebKit

/// Forwards page messages so WKUserContentController doesn't keep the controller alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

@MainActor final class UsageController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    var onResize: ((CGFloat) -> Void)?
    var onStatus: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
    private(set) var snapshot: [String: Any]?
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    private var lastRefresh: Date?
    private var snapshotData: Data?
    private var errorData: Data?
    private var update: [String: String]?
    private var webView: WKWebView!
    private var shown = false
    private var asleep = false
    private var pageStopped = false
    private var crashReloads = CrashReloads()
    private var toolsFound = false
    private var jobs = JobQueue()
    private var logins = LoginWatches()
    private var refreshTimer: Timer?
    private var loginTimer: Timer?
    private let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath().standardizedFileURL

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(self), name: "agentUsage")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 540), configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NSWorkspace.shared.notificationCenter
        // Switching to another user counts as sleep; popoverOpened() also wakes, in case a wake never arrives.
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.sessionDidResignActiveNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false),
                               (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(asleep) }
            }
        }
        loadPage()
        refresh(.background)
    }

    // MARK: Popover and app

    func popoverOpened() {
        shown = true
        if pageStopped {
            pageStopped = false
            loadPage()
        }
        callPage("popoverShown")
        setAsleep(false)
        if Cadence.refreshOnOpen(since: lastRefresh, now: Date()) { refresh(.followUp) }
        scheduleRefresh()
    }

    func popoverClosed() {
        shown = false
        scheduleRefresh()
    }

    func refresh(_ origin: JobOrigin) { enqueue(Job(arguments: origin == .user ? Job.userRefresh : Job.refresh, origin: origin)) }

    /// Kept for page reloads; a failed check doesn't replace an earlier answer.
    func setUpdate(_ info: [String: String]) {
        if info["failed"] == nil || update == nil { update = info }
        callPage("setUpdate", json: info)
    }

    func sendProviderIcons() { callPage("setProviderIcons", json: ProviderIcons.dataURLs()) }

    func checkForUpdatesFromMenu() { callPage("checkForUpdates") }

    private func setAsleep(_ value: Bool) {
        guard value != asleep else { return }
        asleep = value
        if !value {
            onStatus?()
            refresh(.followUp)
        }
        scheduleRefresh()
        updateLoginTimer()
    }

    // MARK: Page

    private func loadPage() {
        guard let page = Bundle.main.url(forResource: "index", withExtension: "html") else { return }
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    private func isBundled(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let resources else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resources.path + "/")
    }

    /// Calls `window.<function>` with a JSON literal or a base64 string of UTF-8 JSON; a no-op while the
    /// page hasn't defined it yet (didFinish replays the state).
    private func callPage(_ function: String, json object: Any? = nil, base64 data: Data? = nil) {
        var argument = ""
        if let data {
            argument = "'\(data.base64EncodedString())'"
        } else if let object, let json = try? JSONSerialization.data(withJSONObject: object) {
            argument = String(decoding: json, as: UTF8.self)
        }
        webView.evaluateJavaScript("if (typeof window.\(function) === 'function') window.\(function)(\(argument))",
                                   completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendProviderIcons()
        if let update { callPage("setUpdate", json: update) }
        if let snapshotData { callPage("receiveSnapshot", base64: snapshotData) }
        if let errorData { callPage("receiveError", base64: errorData) }
        if shown { callPage("popoverShown") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if crashReloads.allow(now: Date()) { loadPage() } else { pageStopped = true }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(isBundled(navigationAction.request.url) ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "file",
              isBundled(message.frameInfo.request.url), let command = PageMessage.parse(message.body) else { return }
        switch command {
        case .bridge(let arguments): enqueue(Job(arguments: arguments, origin: .user))
        case .resize(let height): onResize?(CGFloat(height))
        case .quit: NSApp.terminate(nil)
        case .checkUpdates: onCheckUpdates?()
        }
    }

    // MARK: Bridge runs

    private func enqueue(_ job: Job) {
        if job.origin == .background && asleep { return }
        jobs.add(job)
        startNext()
    }

    private func startNext() {
        guard let job = jobs.start() else { return }
        let checkTools = !toolsFound, qos: DispatchQoS.QoSClass = job.origin == .background ? .utility : .userInitiated
        Task { [weak self] in
            let result = await Bridge.run(job.arguments, checkTools: checkTools, qos: qos)
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<Data, BridgeFailure>) {
        guard let job = jobs.finish() else { return }
        let now = Date()
        var failure: BridgeFailure?
        switch result {
        case .success(let data):
            toolsFound = true
            failure = succeeded(job, data: data, now: now)
        case .failure(let error):
            failure = error
        }
        if let failure { failed(job, failure, now: now) }
        var reports = job.reports
        if job.origin == .user { reports.append(ActionDone(job.arguments, ok: failure == nil)) }
        if failure == nil && job.arguments[0] == "login" {
            // Busy ends once the card shows the sign-in connecting, so a second click can't start another one.
            enqueue(Job(arguments: Job.refresh, origin: .followUp, reports: reports))
        } else {
            for report in reports { callPage("actionDone", base64: json(report.json)) }
        }
        onStatus?()
        startNext()
        scheduleRefresh()
        updateLoginTimer()
    }

    /// Applies a successful run; returns a failure when the output isn't what the action promises.
    private func succeeded(_ job: Job, data: Data, now: Date) -> BridgeFailure? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let arguments = job.arguments
        switch arguments[0] {
        case "login":
            logins.start(AccountKey(provider: arguments[1], account: arguments[2]), now: now)
        case "login_status":
            let key = AccountKey(provider: arguments[1], account: arguments[2])
            if logins.status(key, connecting: object["connecting"] as? Bool, now: now) { refresh(.followUp) }
        case "update":
            callPage("receiveUpdateResult", base64: data)
            if let link = object["release_url"] as? String, let url = URL(string: link), url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        default:
            guard object["providers"] is [String: Any], object["cards"] is [Any] else {
                return BridgeFailure(message: "The usage reader returned an unexpected response.")
            }
            snapshot = object
            snapshotData = data
            errorData = nil
            lastSuccess = now
            lastRefresh = now
            lastError = nil
            logins.reconcile(object, now: now)
            callPage("receiveSnapshot", base64: data)
        }
        return nil
    }

    private func failed(_ job: Job, _ failure: BridgeFailure, now: Date) {
        let action = job.arguments[0]
        if action == "login_status" {
            let key = AccountKey(provider: job.arguments[1], account: job.arguments[2])
            if logins.status(key, connecting: nil, now: now) && !failure.setup { refresh(.followUp) }
            guard failure.setup else { return }
        }
        if action == "snapshot" || failure.setup {
            lastError = failure.message
            lastRefresh = now
        }
        let kind = failure.setup ? "setup" : job.origin == .user ? "action" : "refresh"
        let data = json(["message": failure.message, "action": action, "kind": kind])
        if kind != "action" { errorData = data }
        callPage("receiveError", base64: data)
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    // MARK: Timers

    /// Every 60 s while the popover is shown, every 300 s while hidden, nothing while the screens sleep.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard !asleep else { return }
        let timer = Timer(timeInterval: Cadence.delay(since: lastRefresh, shown: shown, now: Date()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTick() }
        }
        timer.tolerance = shown ? 5 : 30
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshTick() {
        refreshTimer = nil
        onStatus?()
        refresh(.background)
        if !jobs.isBusy { scheduleRefresh() }
    }

    private func updateLoginTimer() {
        guard logins.isActive(now: Date()) && !asleep else {
            loginTimer?.invalidate()
            loginTimer = nil
            return
        }
        guard loginTimer == nil else { return }
        let timer = Timer(timeInterval: LoginWatches.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollLogins() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        loginTimer = timer
    }

    private func pollLogins() {
        if let key = logins.due(now: Date()) {
            enqueue(Job(arguments: ["login_status", key.provider, key.account], origin: .background))
        }
        updateLoginTimer()
    }
}
