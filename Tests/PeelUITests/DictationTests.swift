import Foundation
import Testing
@testable import PeelUI

/// The hotkey's state machine, with the time passed in.
struct DictationStateMachineTests {
    private func machine() -> DictationStateMachine {
        DictationStateMachine(holdThreshold: 0.2, maxRecording: 300)
    }

    @Test func aTapIsIgnored() {
        var m = machine()
        #expect(m.handle(.hotkeyDown(isRepeat: false), at: 0).effects == [.beginCapture])
        _ = m.handle(.tick, at: 0.1)
        #expect(m.handle(.hotkeyUp, at: 0.15).effects == [.discard])
        #expect(m.isIdle)
    }

    @Test func holdingBecomesPushToTalkAndReleaseSubmits() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        #expect(m.handle(.tick, at: 0.1).effects.isEmpty)
        #expect(m.handle(.tick, at: 0.2).effects == [.showHUD])
        #expect(m.phase == .recording(since: 0))
        #expect(m.handle(.hotkeyUp, at: 3).effects == [.submit(.pushToTalk)])
        #expect(m.isIdle)
    }

    @Test func spaceWhileHeldLocksAndIsSwallowed() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        _ = m.handle(.tick, at: 0.3)
        let lock = m.handle(.spaceDown(isRepeat: false), at: 1)
        #expect(lock.swallow)
        #expect(lock.effects == [.enterLocked])
        // Repeats and the release of that Space are swallowed too.
        #expect(m.handle(.spaceDown(isRepeat: true), at: 1.5).swallow)
        #expect(m.handle(.spaceUp, at: 2).swallow)
        // Releasing the key does not end it; a later Space is the user's own.
        #expect(m.handle(.hotkeyUp, at: 2).effects.isEmpty)
        #expect(!m.handle(.spaceDown(isRepeat: false), at: 3).swallow)
        #expect(m.phase == .locked(since: 0))
    }

    @Test func spaceBeforeTheThresholdLocksAndShowsTheHUD() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        let lock = m.handle(.spaceDown(isRepeat: false), at: 0.1)
        #expect(lock.effects == [.showHUD, .enterLocked])
        #expect(lock.swallow)
    }

    @Test func spaceWithoutTheKeyPassesThrough() {
        var m = machine()
        let out = m.handle(.spaceDown(isRepeat: false), at: 0)
        #expect(!out.swallow && out.effects.isEmpty)
    }

    @Test func tickAcceptsAndCancelDiscards() {
        var m = machine()
        func lock() {
            _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
            _ = m.handle(.spaceDown(isRepeat: false), at: 0.5)
            _ = m.handle(.spaceUp, at: 0.6)
            _ = m.handle(.hotkeyUp, at: 0.7)
        }
        lock()
        #expect(m.handle(.accept, at: 5).effects == [.submit(.locked)])
        #expect(m.isIdle)
        lock()
        #expect(m.handle(.cancel, at: 5).effects == [.discard])
        #expect(m.isIdle)
    }

    @Test func escapeCancelsAndIsSwallowedWhenRecording() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        _ = m.handle(.spaceDown(isRepeat: false), at: 0.5)
        let out = m.handle(.escapeDown, at: 1)
        #expect(out.effects == [.discard] && out.swallow)
        #expect(m.isIdle)
    }

    @Test func escapeWithNothingRunningPassesThrough() {
        var m = machine()
        let out = m.handle(.escapeDown, at: 0)
        #expect(out.effects.isEmpty && !out.swallow)
    }

    @Test func pressingTheKeyAgainWhenLockedSubmits() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        _ = m.handle(.spaceDown(isRepeat: false), at: 0.5)
        _ = m.handle(.hotkeyUp, at: 0.6)
        #expect(m.handle(.hotkeyDown(isRepeat: true), at: 1).effects.isEmpty)
        #expect(m.handle(.hotkeyDown(isRepeat: false), at: 2).effects == [.submit(.locked)])
    }

    @Test func keyRepeatIsIgnored() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        #expect(m.handle(.hotkeyDown(isRepeat: true), at: 0.05).effects.isEmpty)
        #expect(m.phase == .pending(since: 0))
        #expect(machine().handle(.hotkeyDown(isRepeat: true), at: 0).effects.isEmpty)
    }

    @Test func anotherKeyBeforeTheThresholdMeansAShortcut() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        #expect(m.handle(.otherKeyDown, at: 0.1).effects == [.discard])
        #expect(m.isIdle)
    }

    @Test func anotherKeyWhileRecordingIsIgnored() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        _ = m.handle(.tick, at: 0.3)
        #expect(m.handle(.otherKeyDown, at: 0.4).effects.isEmpty)
        #expect(m.phase == .recording(since: 0))
    }

    @Test func theLongestRecordingSubmitsByItself() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 10)
        _ = m.handle(.tick, at: 10.3)
        #expect(m.handle(.tick, at: 309).effects.isEmpty)
        #expect(m.handle(.tick, at: 310).effects == [.submit(.pushToTalk)])
        #expect(m.isIdle)

        _ = m.handle(.hotkeyDown(isRepeat: false), at: 400)
        _ = m.handle(.spaceDown(isRepeat: false), at: 401)
        #expect(m.handle(.tick, at: 700).effects == [.submit(.locked)])
    }

    @Test func theLateReleaseAfterAutoSubmitDoesNothing() {
        var m = machine()
        _ = m.handle(.hotkeyDown(isRepeat: false), at: 0)
        _ = m.handle(.tick, at: 0.3)
        _ = m.handle(.tick, at: 300)
        #expect(m.handle(.hotkeyUp, at: 301).effects.isEmpty)
    }
}

struct HotkeyConfigTests {
    @Test func theDefaultIsRightOption() {
        #expect(DictationDefaults.hotkey.keyCode == 61)
        #expect(DictationDefaults.hotkey.isModifier)
    }

    @Test func roundTripsThroughEncoding() throws {
        let key = HotkeyConfig.key(code: 40, character: "k")
        let back = try #require(HotkeyConfig.decode(try #require(key.encoded())))
        #expect(back == key)
        #expect(back.label == "K")
        #expect(!back.isModifier)
    }

    @Test func modifierFlagsTellTheKeyDown() {
        let rightOption = HotkeyConfig.rightOption
        #expect(rightOption.isDown(flags: 0x40 | 0x80000) == true)
        // The left Option's bit is not the right's.
        #expect(rightOption.isDown(flags: 0x20 | 0x80000) == false)
        #expect(HotkeyConfig.fn.isDown(flags: 0x80_0000) == true)
        #expect(HotkeyConfig.key(code: 40).isDown(flags: 0xffff) == nil)
    }

    @Test func namesKeysWithoutACharacter() {
        #expect(HotkeyConfig.key(code: 122).label == "F1")
        #expect(HotkeyConfig.key(code: 200).label == "Key 200")
        #expect(HotkeyConfig.key(code: 49).isReserved)
    }

    @Test func settingsPersistAndDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "dictation-test-\(UUID().uuidString)"))
        let settings = DictationSettings(defaults: defaults)
        #expect(settings.hotkey == DictationDefaults.hotkey)
        settings.hotkey = .fn
        #expect(settings.hotkey == .fn)
        #expect(settings.storedEnabled == nil)
        settings.storedEnabled = false
        #expect(settings.storedEnabled == false)
    }

    @Test func onByDefaultOnlyOnceGranted() {
        #expect(DictationSettings.isEnabled(stored: nil, permissionsGranted: true))
        #expect(!DictationSettings.isEnabled(stored: nil, permissionsGranted: false))
        #expect(!DictationSettings.isEnabled(stored: false, permissionsGranted: true))
        #expect(DictationSettings.isEnabled(stored: true, permissionsGranted: false))
    }
}

struct DictationAudioTests {
    @Test func preRollKeepsTheLastSamplesOldestFirst() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2])
        #expect(buffer.snapshot() == [1, 2])
        buffer.append([3, 4, 5])
        #expect(buffer.snapshot() == [2, 3, 4, 5])
        buffer.append([6, 7, 8, 9, 10, 11])
        #expect(buffer.snapshot() == [8, 9, 10, 11])
        buffer.removeAll()
        #expect(buffer.snapshot().isEmpty)
    }

    @Test func preRollSizeFollowsSeconds() {
        #expect(PreRollBuffer(seconds: 0.2, sampleRate: 16_000).capacity == 3200)
    }

    @Test func conversionClipsRatherThanWraps() {
        #expect(PCM16.samples(from: [0, 1, -1, 2, -2]) == [0, 32767, -32767, 32767, -32767])
    }

    @Test func levelRisesWithLoudness() {
        #expect(PCM16.level(of: []) == 0)
        #expect(PCM16.level(of: [0, 0, 0]) == 0)
        let quiet = PCM16.level(of: [Int16](repeating: 100, count: 100))
        let loud = PCM16.level(of: [Int16](repeating: 20000, count: 100))
        #expect(quiet < loud)
        #expect(loud <= 1 && quiet >= 0)
    }

    @Test func wavFileHasARealHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        try writer.append([Int16](repeating: 1, count: 8000))
        try writer.append([Int16](repeating: 2, count: 8000))
        try writer.finish()
        #expect(writer.duration == 1)
        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 32_000)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        let dataSize = data[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(dataSize == 32_000)
    }

    @Test func discardRemovesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(url: url)
        try writer.append([1, 2, 3])
        writer.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theStubAnswersWithCannedText() async throws {
        let text = try await StubTranscriber().transcribe(audioFileURL: URL(fileURLWithPath: "/dev/null"))
        #expect(text == StubTranscriber.text)
    }
}
