import Foundation

extension Engine {
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
        case historyFailed(String)
        /// An error that belongs to one conversation, such as a send the server refused.
        case conversationError(chat: String, message: String)
        /// Why the last attempt to connect failed.
        case connectionError(String)
        /// An error that belongs to no conversation in particular.
        case coreError(String)
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
            case .offline(let seconds?): "Offline, retrying in \(seconds)s"
            case .offline(nil): "Offline"
            case .connecting: "Connecting"
            case .connected: "Connected"
            }
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noServer
        case notConnected
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
        case untrustedMediaHost(String)
        case uploadInProgress
        case invalidAmount
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
        case alreadyAnswered
        case notPinnable
        case invalidPrice
        case notAFile(String)
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

        public var description: String {
            switch self {
            case .invoiceExpired: "that invoice has expired"
            case .invoiceAlreadyPaid: "that invoice has already been paid"
            case .invoicePending: "a payment of that invoice is still on its way"
            case .ownInvoice: "that is this account's own invoice"
            case .invoiceWithoutAmount: "that invoice names no amount; Peel only pays invoices that say how much"
            case .serverTimedOut: "the server did not answer in time"
            case .noInvoiceFromServer: "the server made no invoice (its Lightning node may be down); try again later"
            case .invalidAmount: "the amount must be more than nothing"
            case .balanceUnknown: "the balance is not known yet; connect first"
            case .insufficientBalance: "the balance is not enough for that"
            case .needsConfirmation(let msat): "\(Sats.format(msat: msat)) needs confirming first"
            case .notBoostable: "only someone else's delivered message can be boosted"
            case .paymentToTribe: "a payment to a tribe goes to the tribes server; boost a message instead"
            case .noteTooLong: "the note is too long to go with a payment"
            case .nameTooLong: "your name is too long to go with a payment"
            case .notRetryable: "only an undelivered message of ours can be sent again or discarded"
            case .noServer: "this account has no server recorded"
            case .notConnected: "not connected to the server"
            case .invalidContactInfo: "contact info must look like pubkey_lsp_scid"
            case .registrationTimedOut: "the server did not confirm registration in time"
            case .invalidTribeLink: "that is not a tribe link"
            case .tribeDeleted: "this tribe has been deleted"
            case .notInTribe: "this account is not in that tribe"
            case .noTribeServer: "the server has not named a tribes server for this account"
            case .tribeServerTimedOut: "the tribes server did not answer in time"
            case .awaitingApproval: "the tribe's owner has not approved this account yet"
            case .notTribeOwner: "only the tribe's owner can do that"
            case .noSuchMessage: "there is no such message in this chat"
            case .notDelivered: "that message has not been delivered yet; reply once it has"
            case .notInThread: "that message is not in that thread"
            case .notAChat: "that is neither a contact nor a tribe this account is in"
            case .noMemesServer: "this account has no memes server for attachments"
            case .noCallServer: "this account has no call server"
            case .notAnAttachment: "that message is not an attachment"
            case .attachmentWithoutKey: "this attachment is paid; it opens once bought"
            case .largeAttachment: "this attachment is large; it downloads when asked"
            case .untrustedMediaHost(let host): "the attachment is on \(host), not this account's memes server"
            case .uploadInProgress: "this attachment is still uploading"
            case .notAnInvoice: "that is not a Lightning invoice"
            case .unreadableInvoice: "that invoice cannot be read"
            case .invoiceMismatch: "the server's invoice does not match what was asked for"
            case .memoTooLong: "the memo is too long for an invoice"
            case .requestToTribe: "payment requests go to a person, not a tribe"
            case .requestExpired: "this request's invoice has expired; ask again with a new one"
            case .notAPaymentRequest: "that is not someone's payment request"
            case .notAContact: "that is not a contact"
            case .emptyName: "the name cannot be empty"
            case .photoNotHTTPS: "a photo must be an https URL"
            case .unreadableTribeHost(let host): "unreadable tribes host \(host)"
            case .unreadableCallServer(let host): "unreadable call server \(host)"
            case .callOnAnotherServer: "that call is not on this account's call server"
            case .accountClosed: "this account is closed"
            case .notDeletable:
                "only your own sent messages, or any in a tribe you own, can be deleted; "
                    + "not a thread's first message while it has replies"
            case .tribePriceRose(let boost):
                "this tribe now charges more per message; \(boost ? "boost again as a new boost" : "send it as a new message")"
            case .joinPriceChanged: "the price to join has changed; look the tribe up again"
            case .noRouteToTribe: "the tribes server gave no route to this tribe"
            case .ownerCannotLeave: "the owner cannot leave a tribe; delete it instead"
            case .tribeChangeInProgress: "another change to this tribe is still being saved"
            case .tribeServerMismatch: "the tribes server answered for a different tribe"
            case .tribeNeedsName: "a tribe needs a name"
            case .tribeImageNotHTTPS: "the image must be an https link"
            case .amountTooLarge: "an amount is too large"
            case .notAMemberKey: "that is not a member's key"
            case .memberNotWaiting: "that member is not waiting for an answer"
            case .alreadyAnswered: "that request has already been answered"
            case .notPinnable: "only a message the tribe has delivered can be pinned"
            case .invalidPrice: "a price must be from 1 to \(Engine.maxAttachmentPriceSats.formatted()) sats"
            case .notAFile(let path): "\(path) is not a file"
            case .notAPaidAttachment: "that is not a paid attachment someone sent"
            case .purchaseInProgress: "this attachment is already being bought"
            case .alreadyBought: "this attachment is already bought"
            case .unknownTimeZone(let identifier): "unknown time zone \(identifier); use a name like Europe/London"
            case .publicTribeTimeZone: "your time zone is never sent in public tribes"
            case .memberNeeded: "a tribe has a local time per member; name the member"
            case .notAContactCode: "that is not contact info, an invite or a Sphinx link"
            case .keyWithoutRoute: "that names only a key, not how to reach it; ask for their whole contact info"
            case .inviteWithoutInviter: "that invite names nobody to add"
            case .tribeLinkNotContact: "that is a tribe link; join it from Join a tribe"
            case .ownContactInfo: "that is this account's own contact info"
            case .contactNeedsSats: "adding a contact needs \(Sats.format(msat: Engine.keyExchangeMsat))"
            case .noSuchInvite: "there is no such invite"
            case .inviteNotPending: "that invite is no longer waiting to be used"
            case .inviteNotRefunded:
                "the server has sent no sats back yet; the invite may have been used. Ask again, or remove it from the list"
            case .inviteFailed: "the server refused the invite's payment; no sats moved"
            case .inviteNotConfirmed: "the server has not confirmed the invite yet; it shows once it does"
            case .nicknameTooLong: "the nickname is too long"
            case .inviteMessageTooLong: "the message is too long"
            case .cancelInProgress: "an invite is already being cancelled"
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
    public struct Invite: Sendable, Equatable {
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
