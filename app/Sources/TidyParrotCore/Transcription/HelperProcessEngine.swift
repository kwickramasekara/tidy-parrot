import Foundation

/// Runs helper/tidy_parrot_helper.py, which keeps the model loaded, and talks to it over `HelperProtocol`.
@MainActor
public final class HelperProcessEngine: TranscriptionEngine {
    public struct Configuration: Sendable, Equatable {
        public let python: String
        public let script: String
        public let arguments: [String]

        public init(python: String, script: String, arguments: [String]) {
            self.python = python
            self.script = script
            self.arguments = arguments
        }
    }

    public var onStateChange: ((EngineState) -> Void)?

    private let configuration: Configuration
    private var connection: HelperConnection?

    public init(configuration: Configuration) {
        self.configuration = configuration
        signal(SIGPIPE, SIG_IGN)  // a dead helper must surface as a write error, not kill the app
    }

    public func start() {
        onStateChange?(.loading)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.python)
        process.arguments = [configuration.script] + configuration.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { $1 }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Log.handle
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            let pid = ended.processIdentifier
            Task { @MainActor in self?.handleExit(pid: pid, status: status) }
        }

        do {
            try process.run()
        } catch {
            let reason = "Couldn't start helper: \(error.localizedDescription)"
            Log.write(reason)
            onStateChange?(.failed(reason))
            return
        }
        Log.write("helper started (pid \(process.processIdentifier))")

        let connection = HelperConnection(
            process: process, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        self.connection = connection
        connection.readMessage { [weak self] message in
            Task { @MainActor in self?.handleFirstMessage(message, from: connection) }
        }
    }

    public func stop() {
        guard let connection else { return }
        detach()
        connection.close()  // EOF makes the helper exit on its own
    }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        guard let connection else { throw TranscriptionError.notRunning }
        // The body runs synchronously on the main actor, so requests reach the serial queue in call order.
        let message = try await withCheckedThrowingContinuation { continuation in
            connection.send(HelperProtocol.frame(clip)) { continuation.resume(with: $0) }
        }
        switch message {
        case .transcript(let transcript): return transcript
        case .error(let text): throw TranscriptionError.engine(text)
        case .ready: throw TranscriptionError.invalidReply
        }
    }

    private func handleFirstMessage(_ message: HelperProtocol.Message?, from started: HelperConnection) {
        guard started === connection else { return }  // replaced or stopped meanwhile
        switch message {
        case .ready(let loadMilliseconds, let cleanMode):
            Log.write("helper ready in \(loadMilliseconds) ms, clean mode \(cleanMode)")
            onStateChange?(.ready(cleanMode: cleanMode))
        case .error(let text):
            // e.g. model missing. Detach so the exit that follows doesn't replace this with a bare status code.
            Log.write(text)
            detach()
            onStateChange?(.failed(text))
        case .transcript, nil:
            // Nothing usable: the helper died before replying, and handleExit reports it.
            break
        }
    }

    private func handleExit(pid: Int32, status: Int32) {
        Log.write("helper exited with status \(status)")
        // Ignore exits of a process we already replaced, stopped on purpose, or reported.
        guard connection?.processIdentifier == pid else { return }
        detach()
        let reason = "Helper stopped (status \(status))"
        Log.write(reason)
        onStateChange?(.failed(reason))
    }

    private func detach() {
        connection = nil
    }
}

/// The running helper's pipes. Blocking I/O happens on `queue`, one request at a time, matching the helper's
/// one-clip-in, one-line-out loop.
private final class HelperConnection: @unchecked Sendable {
    // Safety: `reader` is used and `input` written only on `queue`. `close()` may race a write, which then fails
    // with EPIPE and surfaces as an error, the same as the helper dying mid-request.
    let processIdentifier: Int32
    private let process: Process
    private let input: FileHandle
    private let reader: LineReader
    private let queue = DispatchQueue(label: "tidyparrot.helper-connection")

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.processIdentifier = process.processIdentifier
        self.input = input
        self.reader = LineReader(output)
    }

    /// Reads one line without sending anything; used for the startup message. Nil at EOF or on a bad line.
    func readMessage(_ completion: @escaping @Sendable (HelperProtocol.Message?) -> Void) {
        queue.async { [self] in
            completion(reader.readLine().flatMap(HelperProtocol.decode))
        }
    }

    func send(_ frame: Data, completion: @escaping @Sendable (Result<HelperProtocol.Message, Error>) -> Void) {
        queue.async { [self] in
            completion(
                Result {
                    try input.write(contentsOf: frame)
                    guard let line = reader.readLine() else { throw TranscriptionError.notRunning }
                    guard let message = HelperProtocol.decode(line) else { throw TranscriptionError.invalidReply }
                    return message
                })
        }
    }

    func close() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }
}
