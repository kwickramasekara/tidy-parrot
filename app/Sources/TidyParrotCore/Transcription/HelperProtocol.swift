import Foundation

/// Wire format shared with helper/wire_protocol.py; change both together.
///
///     stdout, once at start: {"ready": true, "load_ms": ..., "clean_mode": ..., "vocabulary": V}  or {"error": "..."}
///     stdin, per clip:       4-byte little-endian length N, then N bytes of float32 mono PCM at 16 kHz
///     stdout, per clip:      {"text": "...", "ms": ..., "vocabulary": V}                         or {"error": "..."}
///
/// V is optional: {"terms": Int, "loaded_at": unix seconds or null, "error": String or null}. It rides on replies
/// because this side reads exactly one line per clip, so the helper can't speak unprompted.
enum HelperProtocol {
    enum Message: Equatable {
        case ready(loadMilliseconds: Int, cleanMode: Bool, vocabulary: VocabularyStatus?)
        case transcript(Transcript, vocabulary: VocabularyStatus?)
        case error(String)
    }

    /// Every line the helper writes; which fields are set depends on the message.
    private struct Line: Decodable {
        var ready: Bool?
        var loadMs: Int?
        var cleanMode: Bool?
        var text: String?
        var ms: Int?
        var error: String?
        var vocabulary: Vocabulary?

        enum CodingKeys: String, CodingKey {
            case ready, text, ms, error, vocabulary
            case loadMs = "load_ms"
            case cleanMode = "clean_mode"
        }
    }

    private struct Vocabulary: Decodable {
        var terms: Int
        var loadedAt: Double?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case terms, error
            case loadedAt = "loaded_at"
        }

        var status: VocabularyStatus {
            VocabularyStatus(terms: terms, loadedAt: loadedAt.map(Date.init(timeIntervalSince1970:)), problem: error)
        }
    }

    static func frame(_ clip: AudioClip) -> Data {
        let samples = clip.samples
        var data = Data(capacity: 4 + samples.count * MemoryLayout<Float>.size)
        withUnsafeBytes(of: UInt32(samples.count * MemoryLayout<Float>.size).littleEndian) {
            data.append(contentsOf: $0)
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }  // arm64 floats are already little-endian
        return data
    }

    /// Nil for a line that isn't one of the messages above.
    static func decode(_ line: String) -> Message? {
        guard let parsed = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return nil }
        if let message = parsed.error { return .error(message) }
        let vocabulary = parsed.vocabulary?.status
        if parsed.ready == true {
            return .ready(
                loadMilliseconds: parsed.loadMs ?? 0, cleanMode: parsed.cleanMode ?? false, vocabulary: vocabulary)
        }
        guard let text = parsed.text else { return nil }
        return .transcript(Transcript(text: text, milliseconds: parsed.ms ?? 0), vocabulary: vocabulary)
    }
}
