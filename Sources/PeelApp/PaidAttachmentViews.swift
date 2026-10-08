import SwiftUI
import PeelCore

// MARK: - Model

extension AppModel {
    /// Buys someone else's paid attachment; it opens once its seller sends the key.
    func buyAttachment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This attachment cannot be bought.") }
        return await pay("purchase \(id)") { try await $0.buyAttachment(messageID: id, confirmedMsat: confirmedMsat) }
    }
}

// MARK: - Buying

/// Someone else's paid attachment before it is bought, as the official apps
/// show it: no preview exists until then (the message carries none, and
/// nothing is fetched or decrypted before paying), so a soft veil stands in
/// for a picture, with a lock, what it is, the price and Unlock (the
/// shared confirmation: over the threshold a second click). Then
/// "Unlocking" until the seller's app sends the key, or their refusal.
struct LockedAttachment: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    let state: PurchaseState

    @State private var attempt = PaymentAttempt()

    private var message: Message { row.message }
    private var kind: AttachmentKind { message.attachmentKind ?? .file }
    private var isPicture: Bool { kind == .image || kind == .video }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPicture {
                Veil(seed: message.uuid ?? "")
                    .frame(width: 320, height: 200)
                    .overlay {
                        VStack(spacing: 8) {
                            lockMark(size: 40)
                            Text(kind == .video ? "Paid video" : "Paid photo")
                                .font(Theme.font(13, .semibold))
                                .foregroundStyle(Theme.text)
                        }
                    }
            } else {
                HStack(spacing: 10) {
                    lockMark(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind == .text ? "Paid message" : "Paid file")
                            .font(Theme.font(13, .semibold))
                        Text(kind == .text ? "Opens once bought" : AttachmentFormat.kind(mediaType: message.mediaType) ?? "File")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 320)
            }
            Theme.divider.frame(height: 1)
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 320, alignment: .leading)
        }
        .frame(width: 320)
        .background(Theme.quote)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.divider))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paid \(isPicture ? (kind == .video ? "video" : "photo") : "attachment"), "
            + Sats.format(msat: message.attachmentPriceMsat ?? 0))
    }

    private func lockMark(size: CGFloat) -> some View {
        Image(systemName: "lock.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Theme.divider))
    }

    @ViewBuilder private var footer: some View {
        let price = message.attachmentPriceMsat ?? 0
        let seller = row.alias ?? "The sender"
        switch state {
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Unlocking: waiting for \(seller) to send the key")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        case .denied:
            Text("\(seller) turned the purchase down and sent the sats back.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .unlocked, .forSale:
            // Never shown: an unlocked one or our own is drawn as the attachment itself.
            EmptyView()
        case .locked, .failed:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(Sats.format(msat: price))
                        .font(Theme.font(14, .semibold))
                        .monospacedDigit()
                        .padding(.top, 5)
                    Spacer(minLength: 8)
                    PayButton(verb: "Unlock", totalMsat: price, attempt: attempt, send: { confirmed in
                        await model.buyAttachment(message, confirmedMsat: confirmed)
                    }, sent: {}, isDefault: false, namesAmount: false)
                }
                if let problem = attempt.problem {
                    ProblemText(problem)
                } else if state == .failed {
                    ProblemText("The last try did not go through; nothing was paid.")
                }
            }
        }
    }
}

/// What stands in for a paid picture: soft, blurred colour fields picked from
/// the message, so locked pictures do not all look alike. Never the picture.
private struct Veil: View {
    let seed: String

    private static let tones: [Color] = [
        Color(light: 0x8E969C, dark: 0x3E6189), Color(light: 0xB08B7E, dark: 0x5B4A6E),
        Color(light: 0x7E9A8C, dark: 0x2F5D55), Color(light: 0x9B8BB0, dark: 0x6B5A3E),
    ]

    var body: some View {
        let value = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        ZStack {
            Theme.quote
            ForEach(0..<3, id: \.self) { index in
                let tone = Self.tones[(value >> (index * 3)) % Self.tones.count]
                Circle()
                    .fill(tone.opacity(0.75))
                    .frame(width: 180, height: 180)
                    .offset(x: CGFloat((value >> (index * 2)) % 220) - 110, y: CGFloat((value >> (index + 4)) % 120) - 60)
            }
        }
        .blur(radius: 34)
        .clipped()
    }
}

/// Under our own paid attachment: its price and how many have bought it.
struct ForSaleNote: View {
    let priceMsat: UInt64
    let purchases: Int

    var body: some View {
        Label {
            Text("For sale at \(Sats.format(msat: priceMsat)) · "
                + (purchases == 0 ? "not bought yet" : purchases == 1 ? "bought once" : "bought \(purchases) times"))
        } icon: {
            Image(systemName: "lock")
        }
        .font(Theme.font(12))
        .monospacedDigit()
        .foregroundStyle(Theme.secondaryText)
    }
}

// MARK: - Selling

/// Beside the files waiting in a composer: what they sell for. Empty sends
/// them free; a price sends each as a paid attachment its buyers unlock.
struct AttachmentPriceField: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID

    var body: some View {
        let text = Binding(
            get: { model.attachmentPrices[composer] ?? "" },
            set: { model.attachmentPrices[composer] = String($0.filter { $0.isASCII && $0.isNumber }.prefix(8)) }
        )
        HStack(spacing: 6) {
            Image(systemName: text.wrappedValue.isEmpty ? "lock.open" : "lock")
                .font(.system(size: 12))
                .foregroundStyle(text.wrappedValue.isEmpty ? Theme.secondaryText : Theme.text)
            FormNumberField(label: "Price", text: text, unit: "sats", prompt: "Free")
        }
        .help("Sell these files: buyers pay this many sats each to open one. Leave empty to send them free.")
    }
}
