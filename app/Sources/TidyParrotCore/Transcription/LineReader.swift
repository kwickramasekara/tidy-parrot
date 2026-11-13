import Foundation

/// Blocking line reader over a pipe. Not thread-safe: use from one serial queue.
final class LineReader {
    /// Held, not just its descriptor, because the handle closes the descriptor when it's deallocated.
    private let handle: FileHandle
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    /// Returns nil at end of stream (the writer exited or closed the pipe).
    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            // POSIX read returns as soon as any bytes arrive. FileHandle.read(upToCount:) waits for the full
            // count or EOF, which would stall on a short reply line.
            let fd = handle.fileDescriptor
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
