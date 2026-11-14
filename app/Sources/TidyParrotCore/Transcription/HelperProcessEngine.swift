import Foundation

/// Runs helper/tidy_parrot_helper.py, which keeps the model loaded, and talks to it over `HelperProtocol`.
@MainActor
final class HelperProcessEngine: TranscriptionEngine {
    struct Configuration: Sendable, Equatable {
        let python: String
        let script: String
        let arguments: [String]
    }

    var onStateChange: ((EngineState) -> Void)?
    var onVocabularyChange: ((VocabularyStatus) -> Void)?

    private let configuration: Configuration
    private var connection: HelperConnection?

    init(configuration: Configuration) {
        self.configuration = configuration
        signal(SIGPIPE, SIG_IGN)  // a dead helper must surface as a write error, not kill the app
    }

    func start() {
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
            fail("Couldn't start helper: \(error.localizedDescription)")
            return
        }
        Log.write("helper started (pid \(process.processIdentifier))")

        let connection = HelperConnection(
            process: process, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        self.connection = connection
        connection.readLine { [weak self] line in
            Task { @MainActor in self?.handleFirstLine(line, from: connection) }
        }
    }

    func stop() {
        disconnect()
    }

    func transcribe(_ clip: AudioClip) async throws -> Transcript {
        guard let connection else { throw TranscriptionError.notRunning }
        let message = try await withCheckedThrowingContinuation { continuation in
            connection.send(HelperProtocol.frame(clip)) { continuation.resume(with: $0) }
        }
        switch message {
        case .transcript(let transcript, let vocabulary):
            if let vocabulary { onVocabularyChange?(vocabulary) }
            return transcript
        case .error(let text): throw TranscriptionError.engine(text)
        case .ready: throw TranscriptionError.invalidReply
        }
    }

    /// `line` is nil when the helper exited without writing anything; `handleExit` reports that.
    private func handleFirstLine(_ line: String?, from started: HelperConnection) {
        guard let line, started === connection else { return }  // replaced or stopped meanwhile
        switch HelperProtocol.decode(line) {
        case .ready(let loadMilliseconds, let cleanMode, let vocabulary):
            Log.write("helper ready in \(loadMilliseconds) ms, clean mode \(cleanMode)")
            onStateChange?(.ready(cleanMode: cleanMode, loadMilliseconds: loadMilliseconds))
            if let vocabulary { onVocabularyChange?(vocabulary) }
        case .error(let text):
            // e.g. model missing. Disconnect first so the exit that follows doesn't replace this with a status code.
            fail(text)
        case .transcript, nil:
            fail("Helper started with an unexpected reply")
        }
    }

    private func handleExit(pid: Int32, status: Int32) {
        Log.write("helper exited with status \(status)")
        // Ignore exits of a process we already replaced, stopped on purpose, or reported.
        guard connection?.processIdentifier == pid else { return }
        fail("Helper stopped (status \(status))")
    }

    private func fail(_ reason: String) {
        Log.write(reason)
        disconnect()
        onStateChange?(.failed(reason))
    }

    /// Forgets the helper, so its later replies and exit are ignored, and makes sure it ends.
    private func disconnect() {
        connection?.close()  // EOF makes the helper exit on its own
        connection = nil
    }
}

/// The running helper's pipes. Blocking I/O happens on `queue`, one request at a time, matching the helper's
/// one-clip-in, one-line-out loop.
private final class HelperConnection: @unchecked Sendable {
    // Safety: `input` and `reader` are used only on `queue`; the rest is immutable or thread-safe (`Process`).
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

    /// Reads one line without sending anything; used for the startup message. Nil at EOF.
    func readLine(_ completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            completion(reader.readLine())
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

    /// Ends the helper. The pipe closes after any request in progress, which terminating the helper cuts short.
    func close() {
        queue.async { [self] in try? input.close() }
        if process.isRunning { process.terminate() }
    }
}

extension HelperProcessEngine.Configuration {
    /// Reads the keys scripts/build.sh writes into Info.plist. They hold absolute paths, so moving the project folder
    /// needs a rebuild. Nil if they're missing.
    init?(infoDictionary info: [String: Any]) {
        guard let python = info["TPHelperPython"] as? String, let script = info["TPHelperScript"] as? String else {
            return nil
        }
        self.init(python: python, script: script, arguments: info["TPHelperArguments"] as? [String] ?? [])
    }
}
