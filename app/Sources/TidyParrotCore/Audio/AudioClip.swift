import Foundation

/// A recorded clip in the format every engine expects: mono float32 PCM at 16 kHz.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}
