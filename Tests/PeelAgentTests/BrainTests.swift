import Foundation
import Testing
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// Where Peel Home is (`Brain`), as `Profile.brain` keeps it: this Mac, or
/// moved to a home server; a home server kept the old way is read as this Mac.
struct BrainTests {
    /// Kept and read back; this Mac keeps nothing; a kept value Peel cannot
    /// read throws rather than being taken for this Mac, whose strut and
    /// bridge would then start beside the box's.
    @Test func whatIsKept() throws {
        let profile = TempProfile()
        try FileManager.default.createDirectory(at: profile.url, withIntermediateDirectories: true)
        let item = FileItem(file: profile.url.appending(path: "brain"))
        #expect(try Brain.read(item).brain == .thisMac)

        // Peel Home moved: kept, so the next launch never starts this Mac's strut or bridge.
        let moved = Brain.moved(MovedHome(host: "192.168.1.20:8090", date: Date(timeIntervalSince1970: 1_793_000_000),
                                          answered: true, strutCopy: "Strut.moved-2026-10-26", bridgeCopy: "Bridge.moved-2026-10-26"))
        try moved.keep(in: item)
        #expect(try Brain.read(item) == (moved, false))

        try Brain.thisMac.keep(in: item)
        #expect(try item.read() == nil)

        for unreadable in [#"not json"#, #"{}"#,
                           // Moved and a home server at once is not a record Peel wrote: neither is taken.
                           #"{"url":"http://100.64.0.7:3000","key":"k","moved":{"host":"h","date":0,"answered":true}}"#] {
            try item.write(Data(unreadable.utf8))
            #expect(throws: PeelError.self) { try Brain.read(item).brain }
        }
    }

    /// A home server kept the old way, by address and key (Account › Brain
    /// before Peel Home moved whole): read as this Mac, and said once.
    @Test func anOldHomeServerIsThisMac() throws {
        let profile = TempProfile()
        try FileManager.default.createDirectory(at: profile.url, withIntermediateDirectories: true)
        let item = FileItem(file: profile.url.appending(path: "brain"))
        try item.write(Data(#"{"url":"https://brain.tail1234.ts.net","key":"ab12ab12"}"#.utf8))
        #expect(try Brain.read(item) == (.thisMac, true))
    }
}
