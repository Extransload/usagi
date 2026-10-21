import AppKit
import ImageIO

enum Home {
    /// Follows $HOME (like bridge.py) so a temporary HOME keeps everything Usagi writes in one place.
    static let url: URL = {
        let path = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
}

enum Network {
    static let session = URLSession(configuration: .ephemeral)

    /// Downloads at most `limit` bytes; a larger announced or actual body gives nil.
    static func data(from url: URL, limit: Int) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            do {
                let (bytes, response) = try await session.bytes(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
                    bytes.task.cancel()
                    return nil
                }
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > limit {
                        bytes.task.cancel()
                        return nil
                    }
                }
                return data
            } catch {
                return nil
            }
        }.value
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard data.count <= PNG.maxBytes, PNG.hasSignature(data),
              let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceTypeIdentifierHint: "public.png"] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png" else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Provider icons from the installed apps, else the claude.ai icon downloaded to ~/.config/usagi/icons.
/// Rendered once and kept in memory until a download replaces the file.
@MainActor enum ProviderIcons {
    static let apps = ["claude": ["com.anthropic.claudefordesktop"], "codex": ["com.openai.codex", "com.openai.chat"]]
    static let web = ["claude": URL(string: "https://claude.ai/apple-touch-icon.png")!]
    static let maxAge: TimeInterval = 30 * 86400

    private struct Entry {
        var tile: NSBitmapImageRep?
        var menu: NSImage?
    }

    private static var entries: [String: Entry] = [:]
    private static var urls: [String: String]?
    private static var downloading: Set<String> = []
    private static var attempted: [String: Date] = [:]

    static func menuImage(_ provider: String) -> NSImage? { entry(provider).menu }

    static func dataURLs() -> [String: String] {
        if let urls { return urls }
        var result: [String: String] = [:]
        for provider in apps.keys {
            guard let png = entry(provider).tile?.representation(using: .png, properties: [:]) else { continue }
            result[provider] = "data:image/png;base64," + png.base64EncodedString()
        }
        urls = result
        return result
    }

    /// Downloads a missing web icon, or replaces one older than 30 days; `done` runs after a new file is saved.
    static func refreshWebIcons(then done: @escaping @MainActor () -> Void) {
        let now = Date()
        for (provider, url) in web where appIcon(provider) == nil && !downloading.contains(provider) {
            if let last = attempted[provider], now.timeIntervalSince(last) < 3600 { continue }
            let file = self.file(provider)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // A fresh file is read and decoded only when no rendered tile is in memory.
            if let modified, now.timeIntervalSince(modified) < maxAge,
               entries[provider]?.tile != nil || webIcon(provider) != nil { continue }
            downloading.insert(provider)
            attempted[provider] = now
            Task {
                let data = await Network.data(from: url, limit: PNG.maxBytes)
                downloading.remove(provider)
                guard let data, Network.decodePNG(data) != nil else { return }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                guard (try? data.write(to: file, options: .atomic)) != nil else { return }
                entries = [:]
                urls = nil
                done()
            }
        }
    }

    private static func file(_ provider: String) -> URL {
        Home.url.appendingPathComponent(".config/usagi/icons/\(provider).png")
    }

    private static func appIcon(_ provider: String) -> NSImage? {
        for id in apps[provider] ?? [] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: app.path)
            }
        }
        return nil
    }

    private static func webIcon(_ provider: String) -> CGImage? {
        (try? Data(contentsOf: file(provider))).flatMap(Network.decodePNG)
    }

    private static func entry(_ provider: String) -> Entry {
        if let entry = entries[provider] { return entry }
        let tile = appIcon(provider).flatMap { render($0, margin: 100.0 / 824) }
            ?? webIcon(provider).flatMap { render(NSImage(cgImage: $0, size: .zero), margin: 0) }
        let menu = tile.map { rep -> NSImage in
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            return image
        } ?? Bundle.main.url(forResource: provider, withExtension: "png", subdirectory: "assets").flatMap(NSImage.init(contentsOf:))
        menu?.size = NSSize(width: 13, height: 13)
        menu?.accessibilityDescription = MenuBar.names[provider]
        let entry = Entry(tile: tile, menu: menu)
        entries[provider] = entry
        return entry
    }

    private static func render(_ icon: NSImage, margin: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        NSBezierPath(roundedRect: rect, xRadius: 29, yRadius: 29).addClip()
        icon.draw(in: rect.insetBy(dx: -rect.width * margin, dy: -rect.height * margin))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
