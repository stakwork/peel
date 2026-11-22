import Foundation
import Testing
@testable import PeelCore

/// An iPhone's Keychain outlives the app, its files do not: words with no
/// profile directory are an earlier install's, and must not read as an account.
struct ReinstallTests {
    @Test func wordsWithNoDirectoryAreStale() {
        #expect(Profile.isStaleAfterReinstall(hasWords: true, directoryExists: false))
    }

    @Test func wordsWithADirectoryAreANormalLaunch() {
        #expect(!Profile.isStaleAfterReinstall(hasWords: true, directoryExists: true))
    }

    @Test func noWordsIsNothingToClear() {
        #expect(!Profile.isStaleAfterReinstall(hasWords: false, directoryExists: false))
        #expect(!Profile.isStaleAfterReinstall(hasWords: false, directoryExists: true))
    }

    /// A development profile is never touched, whatever its folder holds.
    @Test func aDevelopmentProfileIsLeftAlone() throws {
        let temp = TempProfile()
        let profile = Profile(developmentAt: temp.url)
        try profile.secrets.save(mnemonic: "words", pin: "")
        #expect(!profile.discardKeychainLeftByReinstall())
        #expect(profile.hasAccount)
    }
}
