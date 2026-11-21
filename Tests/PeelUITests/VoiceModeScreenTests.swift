import Foundation
import Testing
@testable import PeelUI

/// The Voice Mode setting, its route and the linen's flecks: no window.
struct VoiceModeScreenTests {
    @Test func settingIsOffByDefaultUnderItsKey() {
        #expect(VoiceModeSetting.key == "voiceMode")
        #expect(VoiceModeSetting.defaultValue == false)
        let suite = "peel.voicemode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.bool(forKey: VoiceModeSetting.key) == false)
    }

    @Test func settingPersists() {
        let suite = "peel.voicemode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: VoiceModeSetting.key)
        #expect(UserDefaults(suiteName: suite)!.bool(forKey: VoiceModeSetting.key))
    }

    @Test func routing() {
        #expect(VoiceModeRoute.initial(voiceModeOn: true, showedStandard: false) == .voice)
        #expect(VoiceModeRoute.initial(voiceModeOn: false, showedStandard: false) == .standard)
        #expect(VoiceModeRoute.initial(voiceModeOn: true, showedStandard: true) == .standard)
        #expect(VoiceModeRoute.initial(voiceModeOn: false, showedStandard: true) == .standard)
    }

    @Test func fleckPlacementIsFixed() {
        let first = LinenFleck.make()
        #expect(first == LinenFleck.make())
        #expect(first.count == 70)
        #expect(first != LinenFleck.make(seed: 1))
        #expect(first.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }
}
