import Foundation

public enum PCM16 {
    /// How loud, 0…1, for the HUD's meter: RMS on a dB scale from -50 dB up.
    public static func level(of samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(samples.count)).squareRoot() / Double(Int16.max)
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return Float(max(0, min(1, (db + 50) / 50)))
    }

    public static func data(_ samples: [Int16]) -> Data {
        // Apple platforms are little-endian, as WAV is.
        samples.withUnsafeBytes { Data($0) }
    }
}

/// Writes mono 16-bit PCM to a WAV file, then fixes the header's sizes on `finish`.
public final class WAVFileWriter {
    public let url: URL
    public let sampleRate: Int
    private var handle: FileHandle?
    public private(set) var sampleCount = 0

    public init(url: URL, sampleRate: Int = Int(DictationDefaults.sampleRate)) throws {
        self.url = url
        self.sampleRate = sampleRate
        // Private to the user, as everything Peel writes.
        guard FileManager.default.createFile(
            atPath: url.path, contents: Self.header(sampleRate: sampleRate, sampleCount: 0),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    public var duration: TimeInterval { Double(sampleCount) / Double(sampleRate) }

    public func append(_ samples: [Int16]) throws {
        guard let handle, !samples.isEmpty else { return }
        try handle.write(contentsOf: PCM16.data(samples))
        sampleCount += samples.count
    }

    /// Closes the file with its real length in the header.
    public func finish() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, sampleCount: sampleCount))
        try handle.close()
        self.handle = nil
    }

    /// Closes and deletes the file.
    public func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    public static func header(sampleRate: Int, sampleCount: Int) -> Data {
        let dataSize = UInt32(sampleCount * 2)
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        put32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16)                          // fmt chunk size
        put16(1)                           // PCM
        put16(1)                           // mono
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))      // bytes per second
        put16(2)                           // block align
        put16(16)                          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        put32(dataSize)
        return data
    }
}
