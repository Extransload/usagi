import Foundation

struct BridgeFailure: Error {
    var message: String
    var setup = false
}

/// Runs `/usr/bin/python3 bridge.py <arguments>` with a watchdog.
enum Bridge {
    static let timeout: TimeInterval = 60
    static let setupMessage = "Install the Command Line Tools: run xcode-select --install in Terminal"

    static func run(_ arguments: [String], checkTools: Bool, qos: DispatchQoS.QoSClass,
                    timeout: TimeInterval = Bridge.timeout) async -> Result<Data, BridgeFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: runNow(arguments, checkTools: checkTools, timeout: timeout))
            }
        }
    }

    /// Without the Command Line Tools /usr/bin/python3 is only a shim that fails (and may prompt).
    static func toolsInstalled() -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let folder = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !folder.isEmpty
            && FileManager.default.isExecutableFile(atPath: folder + "/usr/bin/python3")
    }

    private static func runNow(_ arguments: [String], checkTools: Bool, timeout: TimeInterval) -> Result<Data, BridgeFailure> {
        if checkTools && !toolsInstalled() { return .failure(BridgeFailure(message: setupMessage, setup: true)) }
        guard let script = Bundle.main.url(forResource: "bridge", withExtension: "py") else {
            return .failure(BridgeFailure(message: "Usage reader not found."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        process.standardInput = FileHandle.nullDevice
        let output = PipeReader(), errors = PipeReader(keep: 8192)
        process.standardOutput = output.pipe
        process.standardError = errors.pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return .failure(BridgeFailure(message: "Could not start python3: \(error.localizedDescription)"))
        }
        // Process makes the child a process group leader, so -pid reaches bridge.py and its CLI children.
        let group = process.processIdentifier
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(-group, SIGTERM)
            let stopped = exited.wait(timeout: .now() + 2) == .success
            kill(-group, SIGKILL)
            if !stopped { exited.wait() }
        }
        let deadline = DispatchTime.now() + 2
        let stdout = output.finish(by: deadline), stderr = errors.finish(by: deadline)
        if timedOut {
            return .failure(BridgeFailure(message: "The usage reader did not answer within \(Int(timeout)) seconds and was stopped."))
        }
        if process.terminationReason == .uncaughtSignal {
            return .failure(BridgeFailure(message: "The usage reader stopped unexpectedly (signal \(process.terminationStatus))."))
        }
        guard process.terminationStatus == 0 else {
            return .failure(BridgeFailure(message: BridgeOutput.errorMessage(stdout: stdout, stderr: stderr,
                                                                            status: process.terminationStatus)))
        }
        guard (try? JSONSerialization.jsonObject(with: stdout)) is [String: Any] else {
            return .failure(BridgeFailure(message: "The usage reader returned an unexpected response."))
        }
        return .success(stdout)
    }
}

/// Drains a pipe as data arrives so a chatty child can't block on a full pipe; optionally keeps only the tail.
private final class PipeReader: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private let keep: Int?
    private var data = Data()

    init(keep: Int? = nil) {
        self.keep = keep
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self?.received(chunk)
        }
    }

    private func received(_ chunk: Data) {
        guard !chunk.isEmpty else {
            ended.signal()
            return
        }
        lock.lock()
        data.append(chunk)
        if let keep, data.count > keep { data = Data(data.suffix(keep)) }
        lock.unlock()
    }

    /// Waits until `deadline` at most for end of file (a detached grandchild may hold the pipe open).
    func finish(by deadline: DispatchTime) -> Data {
        _ = ended.wait(timeout: deadline)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
