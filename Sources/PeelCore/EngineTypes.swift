import Foundation
import PeelDiagnostics

extension Engine {
    /// Why the app asks whether its connection can be trusted (`Engine.appBecameActive`).
    public enum ForegroundReason: Sendable {
        case foreground, push
    }

    public enum Event: Sendable {
        case connection(ConnectionState)
        /// The server knows this account and has given it a route hint.
        case registered(contactInfo: String?)
        case balance(msat: UInt64)
        case message(Message, Arrival)
        case sendStatus(tag: String?, status: String)
        /// A restore or catch-up fetched history up to `reached` of `end`.
        case history(phase: HistoryPhase, reached: UInt64, end: UInt64?)
        /// The server has nothing more; after a restore, the account is complete.
        case historyDone
        /// History is fetched to the end on this connection, with no error or
        /// stall (`Engine.isCaughtUp`).
        case caughtUp
        case historyFailed(String)
        /// History is being asked for again (`resumeHistory`); `restart`: a
        /// restore's plan from its first page, so its counts start over.
        case historyResumed(restart: Bool)
        /// An error that belongs to one conversation, such as a send the server refused.
        case conversationError(chat: String, message: String)
        /// Why the last attempt to connect failed.
        case connectionError(String)
        /// An error that belongs to no conversation in particular.
        case coreError(String)
        /// The engine read its state again from storage (`Engine.recoverCore`).
        case coreRecovered(reason: DiagnosticEvent.CoreRecoveryReason, stage: DiagnosticEvent.CoreRecoveryStage)
        /// The core keeps failing and loading new messages is being retried (true), or is working again (false).
        case syncFailing(Bool)
        /// A background check with the server failed: shown as `coreError`
        /// is, and gone once connected again.
        case serverCheckError(String)
        /// The name or photo this account sends changed (by the user, or
        /// filled in by a restore).
        case profile(alias: String, photoURL: String?)
        /// The aliases tribes echoed back on this account's messages changed
        /// (`echoedOwnAliases`).
        case echoedAliases([String: Set<String>])
        /// An attachment going up to or coming down from the memes server:
        /// bytes so far of the total, at most every 5% or 250 ms, and at the end.
        case transfer(messageID: Int64, direction: Direction, bytes: Int64, total: Int64)
        /// Sats reached this account, worth a notification: a direct payment
        /// to it or a boost on one of its own messages, new to this Mac, past
        /// the chat's read marker, with real sats (`msat`; `amountMsat` is the
        /// amount). Follows its `.message`. The chat's mute level is for the
        /// listener to apply. Never sent for history already read, nor in a
        /// restore.
        case moneyReceived(Message)
        /// An invoice made here was paid and the server has settled it, as
        /// stored: `paid`, or `underpaid` with what arrived in `paidMsat`.
        /// Once per invoice: a settle repeated later is not sent again.
        case invoicePaid(InvoiceRecord)
        /// Someone added this account: their key exchange (type 10), seen
        /// for the first time, live or catching up, never in a restore. The
        /// core has already accepted them (there is nothing to answer); the
        /// contact is marked new until their chat is opened. Follows its
        /// `.message`.
        case contactAdded(Message)
        /// A sync applied preferences set on another device: read them again.
        case preferencesChanged

        public enum Direction: Sendable {
            case upload, download
        }
    }

    /// How a message reached this device: as it was sent, in a history
    /// page (catching up after being offline), or in a restore.
    public enum Arrival: Sendable {
        case live, history, restore
    }

    public enum HistoryPhase: Sendable {
        /// The first message per contact key, from which the core rebuilds contacts.
        case contacts
        case messages
    }

    /// What the server holds for this account, as `getMsgsCounts` reports it.
    public struct MessageCounts: Decodable, Sendable {
        public let total: UInt64
        public let firstForEachKey: UInt64
        public let totalHighestIndex: UInt64
        public let firstForEachKeyHighestIndex: UInt64

        enum CodingKeys: String, CodingKey {
            case total
            case firstForEachKey = "first_for_each_scid"
            case totalHighestIndex = "total_highest_index"
            case firstForEachKeyHighestIndex = "first_for_each_scid_highest_index"
        }
    }

    public enum ConnectionState: Sendable, Equatable {
        case offline(retryIn: Int?)
        case connecting
        case connected

        public var label: String {
            switch self {
            case .offline(let seconds?): String(localized: "Offline, retrying in \(seconds)s", table: "Shared")
            case .offline(nil): String(localized: "Offline", table: "Shared")
            case .connecting: String(localized: "Connecting", table: "Shared")
            case .connected: String(localized: "Connected", table: "Shared")
            }
        }

        /// Whole seconds until the next try while offline with one set
        /// (`retryAt`), 0 once it is due; nil otherwise.
        public func retrySeconds(retryAt: Date?, now: Date) -> Int? {
            guard case .offline = self, let retryAt else { return nil }
            return max(0, Int(retryAt.timeIntervalSince(now).rounded(.up)))
        }

        /// `label`, counting down to the next try: "Offline, retrying in
        /// 8s", then "Offline, retrying" once it is due.
        public func label(retryAt: Date?, now: Date) -> String {
            switch retrySeconds(retryAt: retryAt, now: now) {
            case nil: label
            case 0: String(localized: "Offline, retrying", table: "Shared")
            case let seconds?: String(localized: "Offline, retrying in \(seconds)s", table: "Shared")
            }
        }
    }

    /// A send for the agent's request (`sendText(for:)`) that is stored but
    /// whose publish failed, or may have: it is in the chat, and a retry or a
    /// reconnect may still send it, so it is neither sent nor not.
    public struct SendUnconfirmed: Error, CustomStringConvertible {
        public let error: any Error

        public var description: String {
            String(localized: "the connection failed while sending (\(PeelError.readable(error))); it is in the chat, not confirmed", table: "Shared")
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noServer
        case notConnected
        /// The connection looked open but stopped answering; it is being
        /// made again (`Engine.connectionAnswers`).
        case connectionDropped
        /// A core call returned without what it exists to make (an invite's
        /// code, a payment's tag), named here; nothing was committed or sent.
        case coreReturnedNothing(String)
        case invalidContactInfo
        case registrationTimedOut
        case notRetryable
        case invalidTribeLink
        case tribeDeleted
        case notInTribe
        case noTribeServer
        case tribeServerTimedOut
        case awaitingApproval
        case notTribeOwner
        case noSuchMessage
        case notDelivered
        case notInThread
        case notAChat
        case noMemesServer
        case noCallServer
        case notAnAttachment
        case attachmentWithoutKey
        /// Larger than a download asked for (`downloadAttachment(upTo:)`):
        /// its size, when known (encrypted, if the server named it).
        case largeAttachment(size: Int64?)
        /// Not in the cache, and a lookup that may not fetch (`cachedOnly`).
        case notDownloaded
        case untrustedMediaHost(String)
        /// Not a payment template's picture: no template on the payment, an
        /// unusable muid, or bytes that are no image.
        case noPaymentTemplate
        case uploadInProgress
        /// The preferences file on the memes server did not decrypt, or
        /// holds an item the official apps could not read: left alone.
        case unreadablePreferences
        /// The memes server says there is no preferences file, though this
        /// device has seen one: it says so for storage errors too, so
        /// nothing is changed or written.
        case preferencesMissing
        case invalidAmount
        /// A boost amount is whole sats, as the official apps keep it.
        case partSat
        case balanceUnknown
        case insufficientBalance
        /// Over the confirmation threshold (an invite, always): show the
        /// amount, then call again with it as `confirmedMsat`.
        case needsConfirmation(amountMsat: UInt64)
        case notBoostable
        case paymentToTribe
        case noteTooLong
        case nameTooLong
        case invoiceExpired
        /// Paid before, from here or another device, or being paid now.
        case invoiceAlreadyPaid
        case invoicePending
        case ownInvoice
        /// An invoice that names no amount: the core would send nothing.
        case invoiceWithoutAmount
        case serverTimedOut
        case noInvoiceFromServer
        case notAnInvoice
        case unreadableInvoice
        /// The server's invoice differs from the one asked of it.
        case invoiceMismatch
        case memoTooLong
        case requestToTribe
        case requestExpired
        case notAPaymentRequest
        case notAContact
        /// A send for the agent's request (`sendText(for:)`) once that request
        /// is past its time, or no longer waiting to be sent.
        case requestClosed
        /// Sats with this contact the server has not settled or refused.
        case paymentWithContactPending
        case emptyName
        case photoNotHTTPS
        case unreadableTribeHost(String)
        case unreadableCallServer(String)
        case callOnAnotherServer
        case accountClosed
        case notDeletable
        /// The tribe's price per message is now above what this message or
        /// boost (`boost`) paid.
        case tribePriceRose(boost: Bool)
        case joinPriceChanged
        case noRouteToTribe
        case ownerCannotLeave
        case tribeChangeInProgress
        case tribeServerMismatch
        case tribeNeedsName
        case tribeImageNotHTTPS
        /// A tribe price or escrow over what the network carries.
        case amountTooLarge
        case notAMemberKey
        case memberNotWaiting
        /// The tribes server did not confirm `showSenders`: one from before
        /// the command knows nothing of it.
        case sendersNotShown
        case alreadyAnswered
        case notPinnable
        case invalidPrice
        case notAFile(String)
        /// A file over `sendLimit`, by name.
        case tooLargeToSend(String)
        case notAPaidAttachment
        case purchaseInProgress
        case alreadyBought
        case unknownTimeZone(String)
        case publicTribeTimeZone
        /// A tribe's local time is per member.
        case memberNeeded
        case notAContactCode
        /// A bare key, or a link naming only one: no way to reach them.
        case keyWithoutRoute
        case inviteWithoutInviter
        case tribeLinkNotContact
        case ownContactInfo
        /// Under the key exchange's 5 sats, or a new account the server has
        /// sent no balance yet (it sends none until one changes).
        case contactNeedsSats
        case noSuchInvite
        case inviteNotPending
        /// The server sent no sats back for a cancelled invite.
        case inviteNotRefunded
        case inviteNotConfirmed
        case inviteFailed
        case nicknameTooLong
        case inviteMessageTooLong
        case cancelInProgress
        /// Words typed back that differ from the account's, by position
        /// (1 to 12). Never the words.
        case wrongWords(positions: [Int])
        /// Words to check against that are not this account's.
        case notThisAccountsWords
        /// An app's payment that would take its connection past its budget
        /// (`Storage.Commit.walletBudget`); nothing was written or sent.
        case overBudget
        /// A keysend to something that is not a node's key.
        case notANodeKey
        /// A keysend to this account itself.
        case keysendToSelf

        public var description: String {
            switch self {
            case .invoiceExpired: String(localized: "that invoice has expired", table: "Shared")
            case .invoiceAlreadyPaid: String(localized: "that invoice has already been paid", table: "Shared")
            case .invoicePending: String(localized: "a payment of that invoice is still on its way", table: "Shared")
            case .ownInvoice: String(localized: "that is this account's own invoice", table: "Shared")
            case .invoiceWithoutAmount: String(localized: "that invoice names no amount; Peel only pays invoices that say how much", table: "Shared")
            case .serverTimedOut: String(localized: "the server did not answer in time", table: "Shared")
            case .noInvoiceFromServer: String(localized: "the server made no invoice (its Lightning node may be down); try again later", table: "Shared")
            case .unreadablePreferences:
                "the preferences file on the memes server could not be read, so settings are not synced and the file is left as it is"
            case .preferencesMissing:
                "the memes server did not return the preferences file this account has, so settings are not synced and nothing is written"
            case .invalidAmount: String(localized: "the amount must be more than nothing", table: "Shared")
            case .partSat: String(localized: "a boost amount is a whole number of sats", table: "Shared")
            case .balanceUnknown: String(localized: "the balance is not known yet; connect first", table: "Shared")
            case .insufficientBalance: String(localized: "the balance is not enough for that", table: "Shared")
            case .needsConfirmation(let msat): String(localized: "\(Sats.format(msat: msat)) needs confirming first", table: "Shared")
            case .notBoostable: String(localized: "only someone else's delivered message can be boosted", table: "Shared")
            case .paymentToTribe: String(localized: "a payment to a tribe goes to the tribes server; boost a message instead", table: "Shared")
            case .noteTooLong: String(localized: "the note is too long to go with a payment", table: "Shared")
            case .nameTooLong: String(localized: "your name is too long to go with a payment", table: "Shared")
            case .notRetryable: String(localized: "only an undelivered message of ours can be sent again or discarded", table: "Shared")
            case .noServer: String(localized: "this account has no server recorded", table: "Shared")
            case .notConnected: String(localized: "not connected to the server", table: "Shared")
            case .connectionDropped: String(localized: "the connection had stopped answering; reconnecting now", table: "Shared")
            case .coreReturnedNothing(let what): String(localized: "the core returned no \(what); nothing was sent", table: "Shared")
            case .invalidContactInfo: String(localized: "contact info must look like pubkey_lsp_scid", table: "Shared")
            case .registrationTimedOut: String(localized: "the server did not confirm registration in time", table: "Shared")
            case .invalidTribeLink: String(localized: "that is not a tribe link", table: "Shared")
            case .tribeDeleted: String(localized: "this tribe has been deleted", table: "Shared")
            case .notInTribe: String(localized: "this account is not in that tribe", table: "Shared")
            case .noTribeServer: String(localized: "the server has not named a tribes server for this account", table: "Shared")
            case .tribeServerTimedOut: String(localized: "the tribes server did not answer in time", table: "Shared")
            case .awaitingApproval: String(localized: "the tribe's owner has not approved this account yet", table: "Shared")
            case .notTribeOwner: String(localized: "only the tribe's owner can do that", table: "Shared")
            case .noSuchMessage: String(localized: "there is no such message in this chat", table: "Shared")
            case .notDelivered: String(localized: "that message has not been delivered yet; reply once it has", table: "Shared")
            case .notInThread: String(localized: "that message is not in that thread", table: "Shared")
            case .notAChat: String(localized: "that is neither a contact nor a tribe this account is in", table: "Shared")
            case .noMemesServer: String(localized: "this account has no memes server for attachments", table: "Shared")
            case .noCallServer: String(localized: "this account has no call server", table: "Shared")
            case .notAnAttachment: String(localized: "that message is not an attachment", table: "Shared")
            case .attachmentWithoutKey: String(localized: "this attachment is paid; it opens once bought", table: "Shared")
            case .notDownloaded: String(localized: "this attachment is not downloaded yet", table: "Shared")
            case .largeAttachment: String(localized: "this attachment is large; it downloads when asked", table: "Shared")
            case .untrustedMediaHost(let host): String(localized: "the attachment is on \(host), not this account's memes server", table: "Shared")
            case .noPaymentTemplate: String(localized: "that is not a payment picture", table: "Shared")
            case .uploadInProgress: String(localized: "this attachment is still uploading", table: "Shared")
            case .notAnInvoice: String(localized: "that is not a Lightning invoice", table: "Shared")
            case .unreadableInvoice: String(localized: "that invoice cannot be read", table: "Shared")
            case .invoiceMismatch: String(localized: "the server's invoice does not match what was asked for", table: "Shared")
            case .memoTooLong: String(localized: "the memo is too long for an invoice", table: "Shared")
            case .requestToTribe: String(localized: "payment requests go to a person, not a tribe", table: "Shared")
            case .requestExpired: String(localized: "this request's invoice has expired; ask again with a new one", table: "Shared")
            case .notAPaymentRequest: String(localized: "that is not someone's payment request", table: "Shared")
            case .notAContact: String(localized: "that is not a contact", table: "Shared")
            case .requestClosed: String(localized: "the agent's request is past its time, or already answered", table: "Shared")
            case .paymentWithContactPending:
                "a payment with this contact is still on its way; remove them once it has gone through or failed"
            case .emptyName: String(localized: "the name cannot be empty", table: "Shared")
            case .photoNotHTTPS: String(localized: "a photo must be an https URL", table: "Shared")
            case .unreadableTribeHost(let host): String(localized: "unreadable tribes host \(host)", table: "Shared")
            case .unreadableCallServer(let host): String(localized: "unreadable call server \(host)", table: "Shared")
            case .callOnAnotherServer: String(localized: "that call is not on this account's call server", table: "Shared")
            case .accountClosed: String(localized: "this account is closed", table: "Shared")
            case .notDeletable:
                String(localized: "only your own sent messages, or any in a tribe you own, can be deleted; not a thread's first message while it has replies", table: "Shared")
            case .tribePriceRose(let boost):
                boost
                    ? String(localized: "this tribe now charges more per message; boost again as a new boost", table: "Shared")
                    : String(localized: "this tribe now charges more per message; send it as a new message", table: "Shared")
            case .joinPriceChanged: String(localized: "the price to join has changed; look the tribe up again", table: "Shared")
            case .noRouteToTribe: String(localized: "the tribes server gave no route to this tribe", table: "Shared")
            case .ownerCannotLeave: String(localized: "the owner cannot leave a tribe; delete it instead", table: "Shared")
            case .tribeChangeInProgress: String(localized: "another change to this tribe is still being saved", table: "Shared")
            case .tribeServerMismatch: String(localized: "the tribes server answered for a different tribe", table: "Shared")
            case .tribeNeedsName: String(localized: "a tribe needs a name", table: "Shared")
            case .tribeImageNotHTTPS: String(localized: "the image must be an https link", table: "Shared")
            case .amountTooLarge: String(localized: "an amount is too large", table: "Shared")
            case .notAMemberKey: String(localized: "that is not a member's key", table: "Shared")
            case .memberNotWaiting: String(localized: "that member is not waiting for an answer", table: "Shared")
            case .sendersNotShown: String(localized: "the tribes server did not confirm it; it may not tell a member who is speaking yet", table: "Shared")
            case .alreadyAnswered: String(localized: "that request has already been answered", table: "Shared")
            case .notPinnable: String(localized: "only a message the tribe has delivered can be pinned", table: "Shared")
            case .invalidPrice: String(localized: "a price must be from 1 to \(Engine.maxAttachmentPriceSats.formatted()) sats", table: "Shared")
            case .notAFile(let path): String(localized: "\(path) is not a file", table: "Shared")
            case .tooLargeToSend(let name):
                String(localized: "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(Engine.sendLimit), countStyle: .file)), the most Peel can send", table: "Shared")
            case .notAPaidAttachment: String(localized: "that is not a paid attachment someone sent", table: "Shared")
            case .purchaseInProgress: String(localized: "this attachment is already being bought", table: "Shared")
            case .alreadyBought: String(localized: "this attachment is already bought", table: "Shared")
            case .unknownTimeZone(let identifier): "unknown time zone \(identifier); use a name like Europe/London"
            case .publicTribeTimeZone: String(localized: "your time zone is never sent in public tribes", table: "Shared")
            case .memberNeeded: String(localized: "a tribe has a local time per member; name the member", table: "Shared")
            case .notAContactCode: String(localized: "that is not contact info, an invite or a Sphinx link", table: "Shared")
            case .keyWithoutRoute: String(localized: "that names only a key, not how to reach it; ask for their whole contact info", table: "Shared")
            case .inviteWithoutInviter: String(localized: "that invite names nobody to add", table: "Shared")
            case .tribeLinkNotContact: String(localized: "that is a tribe link; join it from Join a tribe", table: "Shared")
            case .overBudget: String(localized: "that is over what this app may spend without asking", table: "Shared")
            case .notANodeKey: String(localized: "that is not a node's key", table: "Shared")
            case .keysendToSelf: String(localized: "that is this account's own key", table: "Shared")
            case .ownContactInfo: String(localized: "that is this account's own contact info", table: "Shared")
            case .contactNeedsSats:
                // The key exchange's sats and their ping.
                String(localized: "adding a contact needs \(Sats.format(msat: Engine.keyExchangeMsat + Engine.pingMsat(toTribe: false)))", table: "Shared")
            case .noSuchInvite: String(localized: "there is no such invite", table: "Shared")
            case .inviteNotPending: String(localized: "that invite is no longer waiting to be used", table: "Shared")
            case .inviteNotRefunded:
                String(localized: "the server has sent no sats back yet; the invite may have been used. Ask again, or remove it from the list", table: "Shared")
            case .inviteFailed: String(localized: "the server refused the invite's payment; no sats moved", table: "Shared")
            case .inviteNotConfirmed: String(localized: "the server has not confirmed the invite yet; it shows once it does", table: "Shared")
            case .nicknameTooLong: String(localized: "the nickname is too long", table: "Shared")
            case .inviteMessageTooLong: String(localized: "the message is too long", table: "Shared")
            case .cancelInProgress: String(localized: "an invite is already being cancelled", table: "Shared")
            case .wrongWords(let positions):
                positions.count == 1
                    ? String(localized: "word \(positions[0]) does not match", table: "Shared")
                    : String(localized: "words \(positions.map(String.init).formatted(.list(type: .and))) do not match", table: "Shared")
            case .notThisAccountsWords: String(localized: "those are not this account's twelve words", table: "Shared")
            }
        }
    }

    /// A contact as the core knows it. Names and photos are not part of core state.
    public struct Contact: Decodable, Sendable {
        public let pubkey: String
        /// Present once the key exchange with this contact has completed.
        public let contactKey: String?
        /// The child key this account uses for the contact; it names them in topics.
        public let childIndex: UInt64
        /// Their server's node.
        public let lsp: String?

        enum CodingKeys: String, CodingKey {
            case pubkey
            case lsp
            case contactKey = "contact_key"
            case childIndex = "my_idx"
        }
    }

    /// What an invite code carries: where to connect and who sent it.
    public struct Invite: Sendable, Equatable, Codable {
        public let code: String
        public let server: String?
        public let inviterContactInfo: String?
        public let inviterAlias: String?
    }

    /// How someone asked to join a private tribe: the request message, as the
    /// official apps answer from the chat, or the member on the owner's list.
    public enum JoinRequest: Sendable {
        case message(uuid: String)
        case member(pubkey: String, alias: String)
    }
}
