import Foundation

public struct GitCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}

public struct GitCommandError: LocalizedError, Sendable {
    public let arguments: [String]
    public let result: GitCommandResult

    public var errorDescription: String? {
        let details = result.combinedOutput.isEmpty ? "Git コマンドが終了コード \(result.exitCode) で失敗しました。" : result.combinedOutput
        return details
    }
}

public protocol GitCommandRunning: Sendable {
    func run(arguments: [String], currentDirectory: URL?) throws -> GitCommandResult
}

public struct GitCommandRunner: GitCommandRunning {
    public init() {}

    public func run(arguments: [String], currentDirectory: URL?) throws -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let output = ConcurrentDataReader(handle: outputPipe.fileHandleForReading)
        let error = ConcurrentDataReader(handle: errorPipe.fileHandleForReading)
        output.start()
        error.start()
        process.waitUntilExit()
        let outputData = output.finish()
        let errorData = error.finish()

        let result = GitCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )

        guard result.exitCode == 0 else {
            throw GitCommandError(arguments: arguments, result: result)
        }
        return result
    }
}

private final class ConcurrentDataReader: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let readData = handle.readDataToEndOfFile()
            lock.lock()
            data = readData
            lock.unlock()
            group.leave()
        }
    }

    func finish() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
