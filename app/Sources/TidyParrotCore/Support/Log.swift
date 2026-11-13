import Foundation

/// One log file shared with the helper's stderr. O_APPEND keeps both writers from overwriting each other.
/// Log timings and states only, never transcribed text.
public enum Log {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TidyParrot.log")

    static let handle: FileHandle = {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : FileHandle.standardError
    }()

    public static func write(_ message: String) {
        let stamp = Date().formatted(.iso8601)
        try? handle.write(contentsOf: Data("\(stamp) [app] \(message)\n".utf8))
    }
}
