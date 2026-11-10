import Foundation
import Synchronization

nonisolated enum ProcessRunner {
    /// Runs a tool without a shell, so file names need no quoting. Task cancellation
    /// terminates the process. Returns stdout; non-zero exit throws with the end of stderr.
    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String],
        toolName: String,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = OutputCollector(onLine: onOutputLine)
        let stderr = OutputCollector(onLine: nil)
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()
        guard status == 0 else {
            throw ConversionError.toolFailed(tool: toolName, detail: stderr.tail)
        }
        return stdout.text
    }
}

/// Collects a stream of bytes, whole lines at a time, keeping only a bounded tail.
private nonisolated final class OutputCollector: Sendable {
    private struct State {
        var data = Data()
        var pendingLine = Data()
    }

    private let state = Mutex(State())
    private let onLine: (@Sendable (String) -> Void)?
    private static let limit = 256 * 1024

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = state.withLock { state in
            state.data.append(chunk)
            if state.data.count > Self.limit {
                state.data.removeFirst(state.data.count - Self.limit)
            }
            guard onLine != nil else { return [] }
            state.pendingLine.append(chunk)
            var complete: [String] = []
            while let newline = state.pendingLine.firstIndex(of: 0x0A) {
                let line = state.pendingLine[state.pendingLine.startIndex..<newline]
                complete.append(String(decoding: line, as: UTF8.self))
                state.pendingLine = Data(state.pendingLine[(newline + 1)...])
            }
            return complete
        }
        lines.forEach { onLine?($0) }
    }

    var text: String {
        state.withLock { String(decoding: $0.data, as: UTF8.self) }
    }

    /// The last non-empty line, which is where command-line tools put the actual error.
    var tail: String {
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.last.map { String($0.prefix(300)) } ?? ""
    }
}
