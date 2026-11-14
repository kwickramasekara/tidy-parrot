import Foundation

/// The user's list of terms to favour and respell. The helper reads and watches it, and creates it with a default
/// front-end list on first launch; the app only knows where it lives and opens it for editing.
enum VocabularyFile {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TidyParrot/vocabulary.txt")

    /// Returns the file to open, creating an empty one if the user deleted it (that's how they turn the vocabulary
    /// off). Nil until the helper's first launch has created the folder: making the folder here would stop the helper
    /// from seeding the default list, which it does only when the folder is new.
    static func prepareForEditing(at url: URL = url) -> URL? {
        let files = FileManager.default
        guard files.fileExists(atPath: url.deletingLastPathComponent().path) else { return nil }
        if !files.fileExists(atPath: url.path) {
            files.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
