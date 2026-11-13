import AVFoundation

enum Resampler {
    /// Converts a whole mono clip in one pass. Returns [] on failure, which callers treat as "nothing heard".
    static func resample(_ input: [Float], from rate: Double, to target: Double = AudioClip.sampleRate) -> [Float] {
        guard !input.isEmpty else { return [] }
        if rate == target { return input }
        guard
            let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)),
            let inChannel = inBuffer.floatChannelData?[0]
        else { return [] }

        inBuffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            inChannel.update(from: base, count: input.count)
        }

        let outCapacity = AVAudioFrameCount(Double(input.count) * target / rate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return [] }

        var supplied = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            // Hand over the whole clip once, then signal end of stream so the converter flushes its tail.
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error {
            Log.write("resample failed: \(error.localizedDescription)")
            return []
        }
        guard let outChannel = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: outChannel, count: Int(outBuffer.frameLength)))
    }
}
