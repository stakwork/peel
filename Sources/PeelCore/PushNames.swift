import Foundation
import PeelPush

/// The names the notification extension shows for a push, from what the app
/// holds. A push names the chat by the core's child index for it
/// (`Engine.Contact.childIndex`, the core's `my_idx`), as in sphinx-ios-v2's
/// `saveContactsToSharedUserDefaults`: the core's contacts give index and key,
/// the stored chats give the name and whether the key is a tribe's.
public enum PushNames {
    /// One entry per core contact whose chat has a name. A key with no chat
    /// (a contact whose key exchange has not finished, one never shown) or a
    /// chat with no name is left out: the push then says the generic line.
    public static func entries(contacts: [Engine.Contact], chats: [Conversation]) -> [PushNameEntry] {
        let byKey = Dictionary(chats.map { ($0.chat, $0) }, uniquingKeysWith: { $1 })
        return contacts.compactMap { contact in
            guard let chat = byKey[contact.pubkey], let name = chat.alias,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return PushNameEntry(kind: chat.isTribe ? .tribe : .contact, index: contact.childIndex, name: name)
        }
    }

    /// Changes when a chat appears or goes, or a name or its kind changes,
    /// and not for a new message, so the map is written on those alone.
    /// Per process, never kept.
    public static func signature(_ chats: [Conversation]) -> Int {
        var hasher = Hasher()
        for chat in chats {
            hasher.combine(chat.chat)
            hasher.combine(chat.isTribe)
            hasher.combine(chat.alias)
        }
        return hasher.finalize()
    }
}
