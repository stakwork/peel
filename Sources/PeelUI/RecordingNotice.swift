import Foundation

/// What a call tells you when the server starts or stops recording it. Feed
/// it each `isRecording` the call reports; it answers with the words to show
/// when that changed, and nothing for a call that was never recorded or a
/// repeat.
public struct RecordingNotice: Equatable, Sendable {
    public static let started = "Recording in progress.\nPlease be aware this call is being recorded."
    public static let ended = "Recording ended.\nThis call is no longer being recorded."

    private var recording = false

    public init() {}

    /// The toast's text for `isRecording`, or nil when it did not change.
    public mutating func update(_ isRecording: Bool) -> String? {
        guard isRecording != recording else { return nil }
        recording = isRecording
        return isRecording ? Self.started : Self.ended
    }
}
