import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let duration: TimeInterval

    public var isSuccess: Bool {
        return exitCode == 0
    }
}

public actor ProcessRunner {
    private var currentProcess: Process?
    private var isTerminatedByUser: Bool = false

    public init() {}

    public func terminateCurrent() {
        isTerminatedByUser = true
        currentProcess?.terminate()
    }

    /// Executes an executable asynchronously, streaming stdout and stderr line-by-line to `onLine` handler.
    public func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let startTime = Date()
        isTerminatedByUser = false

        let process = Process()
        self.currentProcess = process

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        // Setup enhanced environment with common binary paths
        var env = ProcessInfo.processInfo.environment
        let defaultPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(defaultPaths):\(existingPath)"
        } else {
            env["PATH"] = defaultPaths
        }

        if let customEnv = environment {
            for (k, v) in customEnv {
                env[k] = v
            }
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulators protected by an isolated lock or serial actor/queue
        let lineProcessor = LineStreamCollector(onLine: onLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineProcessor.append(data: data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineProcessor.append(data: data)
        }

        return try await withTaskCancellationHandler {
            do {
                try process.run()
                process.waitUntilExit()

                // Remove handlers to prevent leaking or reading closed handles
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Read any remainder
                let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingStdout.isEmpty {
                    lineProcessor.append(data: remainingStdout)
                }

                let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingStderr.isEmpty {
                    lineProcessor.append(data: remainingStderr)
                }

                lineProcessor.flushRemainder()

                let duration = Date().timeIntervalSince(startTime)
                let fullOutput = lineProcessor.fullOutput()
                let exitCode = process.terminationStatus

                self.currentProcess = nil

                return ProcessResult(
                    exitCode: exitCode,
                    output: fullOutput,
                    duration: duration
                )
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.currentProcess = nil
                throw error
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Helper class to safely parse streamed chunks into individual lines
private final class LineStreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var accumulatedText = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)

        // Process bytes looking for '\n' or '\r'
        while let delimiterRange = buffer.range(of: Data([0x0A])) /* \n */ {
            let lineData = buffer.subdata(in: 0..<delimiterRange.lowerBound)
            buffer.removeSubrange(0..<delimiterRange.upperBound)

            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    accumulatedText.append(trimmed + "\n")
                    onLine?(trimmed)
                }
            }
        }

        // Also check if line has progress carriage returns without newline (\r)
        if buffer.contains(0x0D) {
            if let str = String(data: buffer, encoding: .utf8), str.contains("\r") {
                let parts = str.components(separatedBy: "\r")
                if parts.count > 1 {
                    for i in 0..<(parts.count - 1) {
                        let line = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty {
                            accumulatedText.append(line + "\n")
                            onLine?(line)
                        }
                    }
                    if let last = parts.last {
                        buffer = last.data(using: .utf8) ?? Data()
                    }
                }
            }
        }
    }

    func flushRemainder() {
        lock.lock()
        defer { lock.unlock() }

        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                accumulatedText.append(trimmed + "\n")
                onLine?(trimmed)
            }
            buffer.removeAll()
        }
    }

    func fullOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedText
    }
}
