import Testing
@testable import PeelCore

struct PersonHueTests {
    @Test func keysAsTheOfficialAppsDo() {
        let key = "02" + String(repeating: "ab", count: 32)
        #expect(PersonHue.colourKey(pubkey: key, alias: "Bob", inTribe: false) == "\(key)-color")
        #expect(PersonHue.colourKey(pubkey: key, alias: " Tom_Smith \n", inTribe: true) == "Tom_Smith-color")
        // A tribe member with no alias falls back to the key.
        #expect(PersonHue.colourKey(pubkey: key, alias: "  ", inTribe: true) == "\(key)-color")
        #expect(PersonHue.colourKey(pubkey: key, alias: nil, inTribe: true) == "\(key)-color")
    }

    /// FNV-1a (32-bit) mod 8, checked against values worked out by hand, so
    /// a person keeps their colour across launches, Macs and builds.
    @Test func hashIsStable() {
        #expect(PersonHue(colourKey: "") == .violet)  // the offset basis, 0x811C9DC5
        #expect(PersonHue(colourKey: "Tom_Smith-color") == .lime)  // 0x61C853E9
        #expect(PersonHue(colourKey: "Evan-color") == .pink)
        #expect(PersonHue(colourKey: "Gonza-color") == .coral)
        #expect(PersonHue(colourKey: "Bot-color") == .cyan)
        #expect(PersonHue(pubkey: "x", alias: "Bot", inTribe: true) == PersonHue(colourKey: "Bot-color"))
    }

    @Test func everyHueIsReachable() {
        let hues = Set((0..<200).map { PersonHue(colourKey: "member\($0)-color") })
        #expect(hues.count == PersonHue.allCases.count)
    }

    @Test func mentionOfYouOrEveryone() {
        let aliases = ownMentionAliases(name: "Tom Smith", echoed: [])
        #expect(mentions("@Tom_Smith,", aliases: aliases))
        // The tribe made this account unique: the plain name is someone else's.
        let renamed = ownMentionAliases(name: "Tom Smith", echoed: ["Tom_Smith_2"])
        #expect(mentions("@tom_smith_2", aliases: renamed))
        #expect(!mentions("@Tom_Smith", aliases: renamed))
        #expect(mentions("@All:", aliases: renamed))
        #expect(!mentions("@Evan", aliases: aliases))
        #expect(!mentions("@allison", aliases: aliases))
    }
}
