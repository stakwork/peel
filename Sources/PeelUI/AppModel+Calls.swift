import Foundation
import PeelCore

/// What a call shows of the account: people's faces and the chat's title.
/// The calls themselves are `CallStore`'s (`calls`).
extension AppModel {
    /// Someone on a call: their name ("Guest" when they sent none) and
    /// photo as they sent them, a hue keyed as for a tribe member, and you
    /// as yourself.
    public func avatar(of person: CallParticipant) -> Sender {
        avatar(
            fromMe: person.identity == calls.call?.identity, alias: person.nickname.isEmpty ? "Guest" : person.nickname,
            photoURL: person.avatarURL?.absoluteString, chat: person.identity, inTribe: true
        )
    }

    /// "#tribe" or the contact's name, for the call window.
    public func chatTitle(_ chat: String) -> String {
        conversations.first { $0.chat == chat }?.title ?? "Call"
    }
}
