import Foundation

enum ProcessRunnerError: Error, LocalizedError {
    case failed(status: Int32, message: String)
    var errorDescription: String? {
        switch self { case .failed(_, let m): m.isEmpty ? "the tool failed" : m }
    }
}

/// Runs a system tool and returns its output. Standard output and standard error are drained at the same time, so a tool
/// that writes a lot to either can never block on a full pipe.
enum ProcessRunner {
    @discardableResult
    static func run(_ tool: String, _ args: [String], currentDirectory: URL? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = currentDirectory
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        // Standard error is drained on its own operating-system thread. Not on a Dispatch queue: Dispatch's worker threads
        // are shared with Swift concurrency, and when callers on those workers are all parked here waiting, a queued reader
        // would never get a thread and every caller would wait forever (this hung the test suite).
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        reader.stackSize = 256 * 1024
        reader.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        p.waitUntilExit()
        let errData = errBox.data
        guard p.terminationStatus == 0 else {
            throw ProcessRunnerError.failed(status: p.terminationStatus, message: String(decoding: errData.prefix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
