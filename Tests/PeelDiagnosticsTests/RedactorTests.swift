import Foundation
import Testing
@testable import PeelDiagnostics

enum Fixtures {
    static let tribeName = "Bitcoin Builders"
    static let tribeKey = "02" + String(repeating: "ab12cd34", count: 8)  // 66 hex
    static let seed = "abandon ability able about above absent absorb abstract absurd abuse access accident"
    static let hexKey = String(repeating: "9f", count: 32)
    static let vendorID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    static let invoice = "lnbc2500u1pjq8k2hpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu"
    static let uuid = "A1B2C3D4-0000-4000-8000-0123456789AB"

    static let reason = """
        Could not join \(tribeName) (\(tribeKey)) for Alice Nakamoto: paid 12,500 sats, invoice \(invoice). \
        message: hey are you coming to dinner tonight
        seed \(seed) key \(hexKey)
        file /Users/alice/Library/Application Support/Peel/db.sqlite and /var/mobile/Containers/Data/Application/\(uuid)/Library/x.db
        vendor \(vendorID) host alices-macbook-pro.local
        """

    static let record = CrashRecord(
        id: "rec-1", appIdentifier: "com.sphinx.peel", appVersion: "1.2.3", osVersion: "26.0", osBuild: "25A1",
        machineModel: "iPhone17,1", timestamp: Date(timeIntervalSince1970: 1_700_000_000), signal: "SIGABRT", signalCode: "0",
        faultAddress: 0xdead_beef, machException: "EXC_CRASH", exceptionName: "NSInvalidArgumentException", exceptionReason: reason,
        processName: "Peel", processPath: "/Users/alice/Library/Developer/Xcode/DerivedData/Peel-abc/Build/Peel.app/Contents/MacOS/Peel",
        threads: [
            .init(number: 0, crashed: true, frames: [
                .init(pc: 0x1_0000_1234, imageName: "/Users/alice/Build/Peel.app/Contents/MacOS/Peel",
                      symbol: "$s4Peel8AppModelC8joinTribeyyYaF", offset: 52),
                .init(pc: 0x1_8000_0010, imageName: "/usr/lib/system/libsystem_kernel.dylib", symbol: "Peel.AppModel.send", offset: 8),
                .init(pc: 0x1_8000_0020, imageName: nil, symbol: nil, offset: nil),
            ], registers: [.init(name: "x0", value: 0x1234), .init(name: "pc", value: 0x1_0000_1234)]),
        ],
        images: [
            .init(name: "/Users/alice/Build/Peel.app/Contents/MacOS/Peel", uuid: "C0FFEE00-1111-2222-3333-444455556666",
                  base: 0x1_0000_0000, size: 0x40000, arch: "arm64"),
        ],
        events: [.init(kind: .error, timestamp: Date(timeIntervalSince1970: 1_699_999_000), errorKind: .network, lastAction: .tribeJoin)],
        strutStderrTail: "strut failed for Alice Nakamoto in /Users/alice/strut")
}

struct RedactorTests {
    let redactor = Redactor(allow: [Fixtures.tribeName, Fixtures.tribeKey], knownNames: ["Alice Nakamoto"])

    private func everything(_ redacted: RedactedRecord) throws -> String {
        redacted.rendered() + String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
    }

    @Test func tribeNameAndKeySurviveVerbatim() throws {
        let redacted = redactor.redact(Fixtures.record)
        let reason = try #require(redacted.exceptionReason)
        #expect(reason.contains(Fixtures.tribeName))
        #expect(reason.contains(Fixtures.tribeKey))
        #expect(try everything(redacted).contains(Fixtures.tribeKey))
    }

    @Test func nothingPrivateAppearsAnywhere() throws {
        let text = try everything(redactor.redact(Fixtures.record))
        for leak in ["Alice", "Nakamoto", "alice", "12,500", "lnbc2500", "dinner", "coming to", "abandon ability", "absent absorb",
                     Fixtures.hexKey, Fixtures.vendorID, Fixtures.uuid, "alices-macbook", ".local", "/Users/", "/var/mobile/Containers"] {
            #expect(!text.localizedCaseInsensitiveContains(leak), "leaked \(leak)")
        }
        #expect(text.contains("[amount]"))
        #expect(text.contains("[key]"))
        #expect(text.contains("[device]"))
        #expect(text.contains("[text]"))
        #expect(text.contains("[contact]"))
    }

    @Test func pathsKeepTheirTail() {
        let out = redactor.redactText("/Users/alice/Library/Application Support/Peel/db.sqlite")
        #expect(out == "~/Library/Application Support/Peel/db.sqlite")
        let phone = redactor.redactText("/var/mobile/Containers/Data/Application/\(Fixtures.uuid)/Library/x.db")
        #expect(phone == "~/Library/x.db")
    }

    @Test func stacksImagesAndAddressesSurviveExactly() throws {
        let redacted = redactor.redact(Fixtures.record)
        let original = Fixtures.record
        let thread = redacted.threads[0]
        #expect(thread.frames.map(\.pc) == original.threads[0].frames.map(\.pc))
        #expect(thread.frames.map(\.offset) == original.threads[0].frames.map(\.offset))
        #expect(thread.frames[0].symbol == "$s4Peel8AppModelC8joinTribeyyYaF")
        #expect(thread.frames[1].symbol == "Peel.AppModel.send")
        #expect(thread.frames[0].imageName == "~/Build/Peel.app/Contents/MacOS/Peel")
        #expect(thread.frames[1].imageName == "/usr/lib/system/libsystem_kernel.dylib")
        #expect(thread.registers == original.threads[0].registers.map { .init(name: $0.name, value: $0.value) })
        #expect(redacted.images[0].uuid == "C0FFEE00-1111-2222-3333-444455556666")
        #expect(redacted.images[0].base == 0x1_0000_0000)
        #expect(redacted.images[0].size == 0x40000)
        #expect(redacted.faultAddress == 0xdead_beef)
        #expect(redacted.events == original.events)
        #expect(redacted.rendered().contains("0x100001234"))
        #expect(redacted.rendered().contains("C0FFEE00-1111-2222-3333-444455556666"))
        #expect(redacted.appVersion == "1.2.3")
        #expect(redacted.machineModel == "iPhone17,1")
    }

    @Test func aContactsKeyIsRedactedWhenNotAllowed() {
        let other = "03" + String(repeating: "cd56ef78", count: 8)
        let out = redactor.redactText("member \(other) and \(Fixtures.tribeKey)")
        #expect(!out.contains(other))
        #expect(out.contains(Fixtures.tribeKey))
    }

    @Test func allowedNameSurvivesInsideQuotesAndLabels() {
        #expect(redactor.redactText("joined \"\(Fixtures.tribeName)\"") == "joined \"\(Fixtures.tribeName)\"")
        #expect(redactor.redactText("name: \(Fixtures.tribeName)") == "name: \(Fixtures.tribeName)")
        #expect(redactor.redactText("name: Someone Else") == "name: [text]")
        #expect(redactor.redactText("said \"hey there\"") == "said [text]")
    }

    @Test func moneyForms() {
        for sample in ["paid 12,500 sats", "3 msat", "0.5 BTC", "20 USD", "costs $4.99", "1 sat"] {
            let out = redactor.redactText(sample)
            #expect(out.contains("[amount]"), "\(sample)")
            #expect(!out.contains { $0.isNumber }, "\(sample) -> \(out)")
        }
    }

    @Test func keyForms() {
        let samples = ["xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi",
                       "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789", String(repeating: "A1b2", count: 12),
                       "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", "npub1" + String(repeating: "q", count: 58)]
        for sample in samples { #expect(redactor.redactText("k \(sample) end") == "k [key] end", "\(sample)") }
    }

    @Test func codeLikeTextIsNotMistakenForKeys() {
        let text = "Peel.AppModel.joinTribe in $s4Peel8AppModelC8joinTribe10agreedJoinMsat9confirmedMsatAA14PaymentOutcomeOSSs6UInt64VAHSgtYaF"
        #expect(redactor.redactText(text) == text)
        #expect(redactor.redactText("/Applications/Peel.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC") ==
                "/Applications/Peel.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC")
    }

    @Test func namesAreMatchedWholeAndWithoutCase() {
        let names = Redactor(knownNames: ["Al", "bob"])
        #expect(names.redactText("BOB said hi, Alan too") == "[contact] said hi, Alan too")
    }

    @Test func untrustedFieldsAreKeptOnlyAsIdentifiers() {
        var record = Fixtures.record
        record.osVersion = "26.0 for Alice Nakamoto at home"
        #expect(Redactor().redact(record).osVersion == "[removed]")
    }

    /// A real crash log (every thread, hundreds of images) is far over a
    /// device answer's 32 KB; what the agent reads keeps the crashed thread.
    @Test func theCompactRecordFitsADeviceAnswer() {
        var record = redactor.redact(Fixtures.record)
        let crashed = record.threads[0]
        let frame = crashed.frames[0]
        record.threads = [.init(number: 0, crashed: false, frames: Array(repeating: frame, count: 200), registers: [])]
            + [.init(number: 1, crashed: true, frames: Array(repeating: frame, count: 200), registers: crashed.registers)]
            + (2..<60).map { .init(number: $0, crashed: false, frames: Array(repeating: frame, count: 200), registers: []) }
        record.images += (0..<800).map { .init(name: "/usr/lib/lib\($0).dylib", uuid: Fixtures.uuid, base: 0, size: 1, arch: "arm64") }
        record.events = Array(repeating: record.events[0], count: 2000)
        record.exceptionReason = String(repeating: "x", count: 40_000)
        #expect(record.rendered().utf8.count > 32 * 1024)

        let text = record.compact().rendered()
        #expect(text.utf8.count < 16 * 1024)
        #expect(text.contains("Thread 1 Crashed:") && !text.contains("Thread 0:"))
        #expect(text.contains("<\(Fixtures.uuid)>") == false, "only the images the frames are in")
        #expect(text.contains("Exception Type: EXC_CRASH"))
    }
}
