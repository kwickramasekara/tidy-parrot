import Foundation

/// A recorded clip in the format every engine expects: mono float32 PCM at 16 kHz.
struct AudioClip: Sendable, Equatable {
    static let sampleRate: Double = 16_000

    let samples: [Float]

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}
