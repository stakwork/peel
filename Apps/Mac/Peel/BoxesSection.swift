import PeelCore
import PeelUI
import SwiftUI

/// A box's link waiting for the person's yes (`Boxes.asking`), over the
/// main window: "Link Peel to <host> as <name>?", Link or Cancel. Nothing
/// is signed without the click.
struct BoxLinkConfirm: View {
    @Environment(AppModel.self) private var model
    let offer: BoxLinkOffer

    var body: some View {
        Callout(.neutral, BoxWords.title(offer), detail: BoxWords.question(offer)) {
            HStack(spacing: Theme.Space.sm) {
                Button("Cancel") { model.boxes.decline() }
                    .buttonStyle(.peel(.ghost, size: .sm))
                Button("Link") {
                    model.boxes.accept()
                    model.openAccount(.connections)
                }
                .buttonStyle(.peel(.primary, size: .sm))
            }
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Account › Connections › Boxes (`AppModel.boxes`): the strut boxes this
/// account is linked to, each as its member, with Open (the box's own strut
/// UI in the web pane, as them, where its apps are) and Forget; a link under
/// way, and what went wrong or was let go. A box is linked from its own
/// Connect, by its QR code or Open in Peel.
struct BoxesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let boxes = model.boxes
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection(String(localized: "Stadeum servers")) {
                if let offer = boxes.linking {
                    Fact(offer.host) {
                        Text("Linking Peel…").muted()
                    } trailing: {
                        PeelSpinner(size: 16, delayed: false)
                    }
                }
                ForEach(boxes.links) { box in
                    BoxRow(box: box)
                }
                if boxes.links.isEmpty, boxes.linking == nil {
                    Fact(String(localized: "Stadeum servers")) {
                        Text(BoxWords.howToLink).muted().fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        EmptyView()
                    }
                }
            }
            ForEach([boxes.notice, boxes.problem].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One linked box: its name, who Peel is there and, under it, its whole
/// address (the one place a person reads it); Open and Forget.
private struct BoxRow: View {
    @Environment(AppModel.self) private var model
    let box: BoxLink
    @State private var opening = false
    @State private var forgetting = false

    var body: some View {
        Fact(box.title) {
            VStack(alignment: .leading, spacing: 2) {
                Text("As \(box.person)")
                Text(verbatim: box.host)
            }
            .muted()
        } trailing: {
            HStack(spacing: Theme.Space.sm) {
                if !forgetting {
                    Button { open() } label: { Text("Open").buttonProgress(opening) }
                        .buttonStyle(.peel(.outline))
                        .disabled(opening)
                }
                InlineConfirm(trigger: String(localized: "Forget"), prompt: String(localized: "Forget \(box.title)?"),
                              explanation: String(localized: "Peel stops opening it as \(box.person). The server keeps the link until you remove it in Connect there."),
                              confirm: String(localized: "Forget"), alignment: .trailing, confirming: $forgetting) {
                    model.boxes.forget(box)
                }
            }
        }
    }

    private func open() {
        opening = true
        Task {
            defer { opening = false }
            if let page = await model.boxes.page(of: box) { model.web.open(box: page) }
        }
    }
}
