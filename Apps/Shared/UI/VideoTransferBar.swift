import PeelUI
import SwiftUI

/// The bar over a chat while a video is compressed and uploaded
/// (`AppModel.transfer`): "Compressing video for upload…", then
/// "Uploading…", with the progress in the accent. It floats at the top of
/// the chat, has no height while idle, goes a moment after the upload is
/// done, and after a failure stays, with the reason, until dismissed. Quiet:
/// system colours, no red.
///
/// ```swift
/// ChatColumn().videoTransferBar()
/// ```
struct VideoTransferBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content.animation(.easeOut(duration: 0.2), value: model.transfer.words)
    }

    @ViewBuilder private var content: some View {
        if let words = model.transfer.words {
            let failed = if case .failed = model.transfer { true } else { false }
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(words)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(failed ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fraction = model.transfer.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                    }
                }
                if failed {
                    Button {
                        model.dismissTransfer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss", tableName: "Shared"))
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// The transfer bar floating at the top of this view.
    func videoTransferBar() -> some View {
        overlay(alignment: .top) { VideoTransferBar() }
    }
}
