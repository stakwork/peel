import Foundation
import Observation
import PeelCore
import PeelDiagnostics

/// A tribe's settings as typed into Create a tribe or Edit tribe, on the
/// Mac and the iPhone: prices in sats and the escrow time in hours, as
/// people think of them; `settings()` reads them back into msat and
/// milliseconds. A field still showing what the tribe had sends exactly
/// that, even where the shown text was rounded (an escrow time of 20
/// minutes).
public struct TribeSettingsDraft: Equatable {
    public var name = ""
    public var summary = ""
    /// The image's link, never shown: what the tribe has, or an upload.
    public var photoURL = ""
    public var priceToJoin = ""
    public var pricePerMessage = ""
    public var escrow = ""
    public var escrowHours = ""
    public var isPrivate = false
    public var unlisted = false
    /// Turned on, in the order they were.
    public var tags: [String] = []
    /// What the tribe had, so a field left as it was shown sends exactly that.
    public private(set) var original: TribeSettings?

    /// A new tribe's: nothing typed yet.
    public init() {}

    /// An edit's, from what the tribe has.
    public init(_ settings: TribeSettings) {
        name = settings.name
        summary = settings.summary ?? ""
        photoURL = settings.photoURL ?? ""
        priceToJoin = Sats.text(settings.priceToJoinMsat, unit: Sats.msatPerSat)
        pricePerMessage = Sats.text(settings.pricePerMessageMsat, unit: Sats.msatPerSat)
        escrow = Sats.text(settings.escrowMsat, unit: Sats.msatPerSat)
        escrowHours = Sats.text(settings.escrowMillis, unit: Sats.millisecondsPerHour)
        isPrivate = settings.isPrivate
        unlisted = settings.unlisted
        tags = settings.tags
        original = settings
    }

    /// The official apps' tags, and any other the tribe already has.
    public var tagChoices: [String] {
        TribeSettings.tagChoices + (original?.tags ?? []).filter { !TribeSettings.tagChoices.contains($0) }
    }

    /// What the typed fields are, for watching any change to them.
    public var typedFields: [String] { [name, photoURL, priceToJoin, pricePerMessage, escrow, escrowHours] }

    /// A field that can have its own problem, named as the engine's words name it.
    public enum Field: String, Sendable {
        case name, photo = "image", priceToJoin = "price to join", pricePerMessage = "price per message"
        case escrow, escrowHours = "escrow time"

        /// The field an engine refusal is about, if it is about one.
        public init?(_ failure: Engine.Failure) {
            switch failure {
            case .tribeNeedsName: self = .name
            case .tribeImageNotHTTPS: self = .photo
            default: return nil
            }
        }
    }

    /// What is wrong with one field, shown under it until a field changes.
    public struct FieldProblem: Error, Equatable {
        public let field: Field
        public let text: String

        public init(field: Field, text: String) {
            self.field = field
            self.text = text
        }
    }

    /// Why a save did not go: one field's problem, or the form's.
    public enum SaveProblem: Equatable {
        case field(FieldProblem)
        case form(String)
    }

    /// The settings to send. A number that does not parse is that field's
    /// problem (`FieldProblem`).
    public func settings() throws -> TribeSettings {
        func value(
            _ text: String, unit: UInt64, _ stored: KeyPath<TribeSettings, UInt64>, _ field: Field
        ) throws -> UInt64 {
            if let original, text == Sats.text(original[keyPath: stored], unit: unit) { return original[keyPath: stored] }
            do {
                return try Sats.parse(text, unit: unit, of: field.rawValue)
            } catch {
                throw FieldProblem(field: field, text: PeelError.problem(error))
            }
        }
        return TribeSettings(
            name: name, summary: summary, photoURL: photoURL,
            pricePerMessageMsat: try value(pricePerMessage, unit: Sats.msatPerSat, \.pricePerMessageMsat, .pricePerMessage),
            priceToJoinMsat: try value(priceToJoin, unit: Sats.msatPerSat, \.priceToJoinMsat, .priceToJoin),
            escrowMsat: try value(escrow, unit: Sats.msatPerSat, \.escrowMsat, .escrow),
            escrowMillis: try value(escrowHours, unit: Sats.millisecondsPerHour, \.escrowMillis, .escrowHours),
            isPrivate: isPrivate, unlisted: unlisted, tags: tags
        )
    }

    /// Under the price to join and per message: what members actually pay,
    /// only when that is not the price typed ("Members pay 3 sats, the minimum.").
    /// Both, from one read of the fields.
    public var membersPay: (toJoin: String?, perMessage: String?) {
        let typed = try? settings()
        return (Self.membersPay(typed?.joinPrice), Self.membersPay(typed?.messagePrice))
    }

    private static func membersPay(_ price: TribePrice?) -> String? {
        guard let price, price.reason != nil else { return nil }
        return "Members pay \(price.described)."
    }

    /// A failed save in the form's words: a field's own problem under it,
    /// else the form's.
    public static func saveProblem(_ error: any Error, creating: Bool) -> SaveProblem {
        let couldNot = creating ? "create the tribe" : "save the tribe"
        // The kind only; a field's own problem is typed text's, never kept.
        Diagnostics.note(error: error)
        if let problem = error as? FieldProblem { return .field(problem) }
        if let failure = error as? Engine.Failure {
            if let field = Field(failure) { return .field(FieldProblem(field: field, text: PeelError.problem(failure))) }
            return .form(PeelError.problem(failure, couldNot: couldNot))
        }
        return .form(PeelError.problem(error, couldNot: couldNot))
    }
}

/// Join a tribe's lookup, on the Mac and the iPhone: the link typed or
/// scanned, then what the tribe is and costs once the tribes server
/// answers. A link edited during a lookup is looked up again, never shown
/// with the old answer; editing it clears what was shown.
@MainActor @Observable
public final class TribeLookup {
    public var link: String {
        didSet {
            guard link != oldValue else { return }
            info = nil
            problem = nil
        }
    }
    /// The tribe, once looked up (or as a link card read it).
    public private(set) var info: TribeInfo?
    public private(set) var lookingUp = false
    public private(set) var problem: String?

    public init(link: String = "", info: TribeInfo? = nil) {
        self.link = link
        self.info = info
    }

    /// Asks the tribes server about the link. Asked again while one runs
    /// (a link pasted or scanned meanwhile), the running one asks once more
    /// when it is done, for the link as it is then; an answer for a link
    /// edited since is dropped.
    public func lookUp(with model: AppModel) async {
        guard !lookingUp else {
            askAgain = true
            return
        }
        lookingUp = true
        defer { lookingUp = false }
        repeat {
            askAgain = false
            let looked = link
            guard !looked.trimmed.isEmpty else { return }
            do {
                let found = try await model.previewTribe(looked)
                if link == looked {
                    info = found
                    problem = nil
                }
            } catch {
                if link == looked { problem = PeelError.problem(error) }
            }
        } while askAgain
    }

    @ObservationIgnored private var askAgain = false

    /// Joins, paying only the price shown; `.busy` before a lookup.
    public func join(with model: AppModel, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let info else { return .busy }
        return await model.joinTribe(link, agreedJoinMsat: info.joinAmountMsat, confirmedMsat: confirmedMsat)
    }
}

/// "How you appear in #tribe", on the Mac and the iPhone: a name and a
/// photo sent with your messages there in place of your account's, as the
/// official apps keep them. Save sends neither until it is asked.
@MainActor @Observable
public final class TribeIdentityDraft {
    public var alias = "" {
        didSet { if alias != oldValue { problem = nil } }
    }
    /// The tribe's own photo: nil while it uses the account's.
    public var photoURL: String?
    public var uploading = false
    public private(set) var saving = false
    public private(set) var problem: String?

    public init() {}

    /// Whether what is shown differs from what the tribe has.
    public func changed(from tribe: Tribe) -> Bool {
        alias.trimmed.nilIfEmpty != tribe.myAlias || photoURL != tribe.myPhotoURL
    }

    /// Back to what the tribe has.
    public func reset(to tribe: Tribe) {
        alias = tribe.myAlias ?? ""
        photoURL = tribe.myPhotoURL
        problem = nil
    }

    /// What members will read, only when it is not what was typed.
    public var note: String? { Tribe.aliasNote(alias) }

    /// A picture uploaded and shown, unsaved; its failure is the problem.
    public func upload(_ picture: () async throws -> String) async {
        uploading = true
        defer { uploading = false }
        do {
            photoURL = try await picture()
        } catch {
            problem = PeelError.problem(error, couldNot: "upload the photo")
        }
    }

    public func save(in tribe: Tribe, with model: AppModel) async {
        guard !saving, !uploading else { return }
        saving = true
        defer { saving = false }
        do {
            try await model.setTribeIdentity(tribe.pubkey, alias: alias, photoURL: photoURL)
        } catch {
            problem = PeelError.problem(error, couldNot: "save how you appear")
        }
    }
}

/// A chat's time zone switch, on the Mac and the iPhone: whether your
/// offset goes with what you send there. Set at once, put back if the
/// change is refused.
@MainActor @Observable
public final class TimeZoneSharingSwitch {
    /// Nil until read.
    public private(set) var sharing: Bool?
    public private(set) var problem: String?

    public init() {}

    public func load(_ chat: String, with model: AppModel) async {
        sharing = await model.timeZoneSharing(in: chat)
    }

    public func set(_ on: Bool, in chat: String, with model: AppModel) async {
        let was = sharing
        sharing = on
        problem = nil
        do {
            try await model.setTimeZoneSharing(on, in: chat)
        } catch {
            sharing = was
            problem = PeelError.problem(error, couldNot: "change time zone sharing")
        }
    }
}
