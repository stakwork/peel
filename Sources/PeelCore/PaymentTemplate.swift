import Foundation

/// A payment template: one of the memes server's pictures that a payment in
/// a direct message can carry, as the official apps send them. The list is
/// the server's `GET /templates`; a picture, `GET /template/<muid>`, plain
/// image bytes. A payment names one by a media token for its muid in its
/// type 5 JSON (`{"content", "mediaType": "image/png", "mediaToken"}`, the
/// Mac app's `formatMsg`); see docs/phases/10-v1-extras.md, item 5.
public struct PaymentTemplate: Sendable, Hashable, Identifiable {
    public let muid: String
    /// Its picture's size in pixels, as the server lists it; nil when it does not say.
    public let width: Int?
    public let height: Int?

    public var id: String { muid }

    /// The media type the official apps give a payment, with a picture or without.
    static let mediaType = "image/png"

    /// The `/templates` reply, as the Mac app's `getPaymentTemplates` reads
    /// it: entries without a muid that can stand in a path dropped, a size
    /// kept only when both sides are positive. Nil when it is not a list.
    static func list(from data: Data) -> [PaymentTemplate]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let fields = entry as? [String: Any], let muid = fields["muid"] as? String,
                  MediaToken.isSafeMUID(muid), seen.insert(muid).inserted else { return nil }
            let width = (fields["width"] as? NSNumber)?.intValue ?? 0
            let height = (fields["height"] as? NSNumber)?.intValue ?? 0
            let sized = width > 0 && height > 0
            return PaymentTemplate(muid: muid, width: sized ? width : nil, height: sized ? height : nil)
        }
    }

    /// The template a direct payment's JSON names: its media token, with a
    /// muid that can stand in a path; nil without one.
    static func token(in body: String?) -> MediaToken? {
        guard let token = AttachmentFields.decode(body)?.mediaToken.flatMap(MediaToken.init),
              MediaToken.isSafeMUID(token.muid) else { return nil }
        return token
    }

    /// A direct payment's JSON: the note, and with a template its media
    /// token and the official apps' `mediaType`.
    static func paymentBody(text: String, token: String?) throws -> String {
        var fields = ["content": text]
        if let token {
            fields["mediaType"] = mediaType
            fields["mediaToken"] = token
        }
        return try Engine.json(fields)
    }
}

extension Message {
    /// The template a direct payment carries, sent or received, and the host
    /// its token names; nil for anything else. Its picture comes from this
    /// account's memes server only, and only when that is the host named
    /// (`Engine.templateImage(messageID:)`).
    public var paymentTemplate: (host: String, muid: String)? {
        guard type == MessageType.directPayment, !deleted, let token = PaymentTemplate.token(in: body) else { return nil }
        return (token.host, token.muid)
    }

    public var paymentTemplateMUID: String? { paymentTemplate?.muid }
}
