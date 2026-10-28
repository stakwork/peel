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

    /// A synced colour lands on the palette hue nearest by hue angle, the
    /// short way round the wheel; colours beyond the palette still map.
    @Test func aSyncedColourMapsToItsNearestHue() {
        let cases: [(String, PersonHue)] = [
            ("#ff0000", .coral), ("#FF0000", .coral), ("ff0000", .coral),  // 0°: coral (9°) beats pink (333°, 27° away)
            ("#ff00aa", .pink), ("#00ff00", .green), ("#0000ff", .violet), ("#ffff00", .lime),
            ("#00ffff", .teal), ("#ff00ff", .orchid), ("#ff0066", .pink),
            // Past 351°, the short way round is back through 0°.
            ("#ff0010", .coral),
            // Grey has no hue: the hue angle 0, deterministically.
            ("#808080", .coral),
        ]
        for (hex, hue) in cases {
            #expect(PersonHue(nearestTo: hex) == hue, "\(hex)")
        }
        for bad in ["", "#12", "#gggggg", "#1234567", "red"] {
            #expect(PersonHue(nearestTo: bad) == nil, "\(bad)")
        }
        // Every palette fill maps to its own hue.
        let fills = ["#ba4a36", "#587900", "#007f3d", "#007c70", "#007893", "#765dc1", "#9951a9", "#b44778"]
        #expect(fills.compactMap(PersonHue.init(nearestTo:)) == PersonHue.allCases)
    }

    /// The colour key order: `<alias>-color` for a tribe member, `<pubkey>-color`,
    /// `chat-<pubkey>-color`, the first that is a colour; else the hash.
    @Test func syncedColoursComeBeforeTheHash() {
        let key = "02" + String(repeating: "ab", count: 32)
        func hue(_ alias: String?, _ inTribe: Bool, _ synced: [String: String]) -> PersonHue {
            PersonHue(pubkey: key, alias: alias, inTribe: inTribe, synced: synced)
        }
        #expect(hue("Bob", true, [:]) == PersonHue(pubkey: key, alias: "Bob", inTribe: true))
        #expect(hue("Bob", true, ["Bob-color": "#0000ff", "\(key)-color": "#ff0000"]) == .violet)
        #expect(hue("Bob", true, ["\(key)-color": "#ff0000"]) == .coral)
        #expect(hue(nil, false, ["\(key)-color": "#00ff00", "chat-\(key)-color": "#ff0000"]) == .green)
        #expect(hue(nil, false, ["chat-\(key)-color": "#ff0000"]) == .coral)
        // The alias key is for tribes only; a contact is by key.
        #expect(hue("Bob", false, ["Bob-color": "#0000ff", "\(key)-color": "#ff0000"]) == .coral)
        // A tribe's own chat colour does not colour its members.
        #expect(hue("Bob", true, ["chat-\(key)-color": "#ff0000"]) == PersonHue(pubkey: key, alias: "Bob", inTribe: true))
        // A value that is not a colour is skipped for the next key; a key with a local id is never used.
        #expect(hue(nil, false, ["\(key)-color": "nope", "chat-\(key)-color": "#0000ff"]) == .violet)
        #expect(hue(nil, false, ["12-color": "#0000ff"]) == PersonHue(pubkey: key, alias: nil, inTribe: false))
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
