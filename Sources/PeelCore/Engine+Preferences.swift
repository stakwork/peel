import Foundation

extension Engine {
    /// Every change to a user setting goes through here, to the one owner
    /// of them (`Preferences.swift`). Returns false if it was already so.
    @discardableResult
    func set<Value>(_ preference: Preference<Value>, _ value: Value, for identifier: String = Preferences.accountWide) throws -> Bool {
        try storage.setPreference(preference, value, for: identifier)
    }
}
