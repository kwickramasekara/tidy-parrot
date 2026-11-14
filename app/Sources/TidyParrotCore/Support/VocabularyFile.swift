import Foundation

/// The user's list of terms to favour and respell. The helper reads and watches it, and creates it with a default
/// front-end list on first launch; the app only knows where it lives and opens it for editing.
enum VocabularyFile {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TidyParrot/vocabulary.txt")

    /// Returns the file to open, creating an empty one if the user deleted it (that's how they turn the vocabulary
    /// off), so choosing Edit Vocabulary always opens something.
    static func prepareForEditing(at url: URL = url) -> URL {
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            files.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
