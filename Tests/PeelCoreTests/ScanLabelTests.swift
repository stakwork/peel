import CoreGraphics
import Foundation
import Testing
@testable import PeelCore

struct ScanLabelTests {
    @Test func aWebAddressShowsItsHostWithoutWWW() {
        #expect(ScanLabel("https://www.Example.com/a/b?c=d") == ScanLabel(kind: .web, text: "example.com"))
        #expect(ScanLabel("http://news.example.org").text == "news.example.org")
    }

    @Test func aPeelLinkSaysWhatItDoes() {
        let open = ScanLabel("peel://open?url=https%3A%2F%2Fwww.shop.example%2F")
        #expect(open == ScanLabel(kind: .peel, text: "Open shop.example in Peel"))
        #expect(ScanLabel("peel://strut/link?url=https%3A%2F%2Fbox.example&challenge=x").kind != .web)
    }

    @Test func anInvoiceTribeAndInviteAreNamed() {
        #expect(ScanLabel(coffee) == ScanLabel(kind: .invoice, text: "Lightning invoice"))
        #expect(ScanLabel("lightning:\(coffee)").kind == .invoice)
        let key = String(repeating: "ab", count: 33)
        #expect(ScanLabel("sphinx.chat://?action=tribeV2&pubkey=\(key)&host=tribes.sphinx.chat")
            == ScanLabel(kind: .tribe, text: "Tribe"))
    }

    @Test func anythingElseIsCutShort() {
        #expect(ScanLabel("hello") == ScanLabel(kind: .text, text: "hello"))
        let long = ScanLabel(String(repeating: "x", count: 80))
        #expect(long.text == String(repeating: "x", count: 30) + "…")
        #expect(ScanLabel("line one\nline two").text == "line one")
        #expect(ScanLabel("  ").text == "Code")
    }

    @Test func bracketsSitOnTheCornersWithProportionalArms() {
        let b = ScanBrackets(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 100, y: 0),
                             bottomRight: CGPoint(x: 100, y: 50), bottomLeft: CGPoint(x: 0, y: 50))
        #expect(b.brackets.count == 4)
        #expect(b.center == CGPoint(x: 50, y: 25))
        let first = b.brackets[0]
        #expect(first.corner == CGPoint(x: 0, y: 0))
        #expect(first.end == CGPoint(x: 22, y: 0))
        #expect(first.start == CGPoint(x: 0, y: 11))
        #expect(ScanBrackets.area([.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]) == 100)
    }
}
