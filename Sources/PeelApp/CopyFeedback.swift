import SwiftUI

/// What every copy action shows once it has copied: a button's icon turns
/// into a check (green, or the button's text colour on a filled button) and
/// its title into "Copied" for a moment
/// (`CopyButton`, `CopyLabel`); a menu, which has closed by then, shows a
/// "Copied" pill at the bottom of the window (`MenuEntry.copy`, through
/// `MenuPresenter.showToast`). VoiceOver hears "Copied" either way.
enum CopyFeedback {
    /// How long the check or the pill stays.
    static let hold: Duration = .milliseconds(1500)

    /// In quickly, without overshoot; a cross-fade only under Reduce Motion.
    static func enter(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.18, bounce: 0)
    }

    /// Out a little faster than in.
    static let exit: Animation = .easeOut(duration: 0.14)

    @MainActor static func announce(_ text: String = "Copied") {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// A copy button: runs `copy`, then, if it copied, shows the check and
/// "Copied" for `CopyFeedback.hold`; another click starts the wait again.
/// The label variant takes the surrounding button style (`.peel(...)`);
/// `iconOnly` draws the small hover icon button of the hover bar, with the
/// title as its tooltip.
///
///     CopyButton("Copy hash", text: hash)
///     CopyButton("Copy invoice", text: invoice, iconOnly: true)
///     CopyButton("Copy image") { model.copyImage(message) }   // returns whether it copied
struct CopyButton: View {
    let title: String
    let systemImage: String
    let iconOnly: Bool
    let copy: @MainActor () -> Bool

    @State private var copiedAt: Date?

    init(_ title: String, systemImage: String = "doc.on.doc", iconOnly: Bool = false,
         copy: @escaping @MainActor () -> Bool) {
        self.title = title
        self.systemImage = systemImage
        self.iconOnly = iconOnly
        self.copy = copy
    }

    init(_ title: String, text: String, systemImage: String = "doc.on.doc", iconOnly: Bool = false) {
        self.init(title, systemImage: systemImage, iconOnly: iconOnly) { Clipboard.copy(text) }
    }

    var body: some View {
        if iconOnly {
            IconButton(help: title, action: run) { label }
        } else {
            Button(action: run) { label }
                .accessibilityLabel(title)
        }
    }

    private var label: CopyLabel {
        CopyLabel(title, systemImage: systemImage, iconOnly: iconOnly, copiedAt: copiedAt)
    }

    private func run() {
        guard copy() else { return }
        copiedAt = .now
        CopyFeedback.announce()
    }
}

/// The label of a copy button, for a button that copies in its own way
/// (the twelve words, after their warning): the icon and title until
/// `copiedAt`, then the check and "Copied" until `CopyFeedback.hold` after it.
struct CopyLabel: View {
    let title: String
    let systemImage: String
    let iconOnly: Bool
    let copiedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.filledButton) private var filled
    @State private var copied = false

    init(_ title: String, systemImage: String = "doc.on.doc", iconOnly: Bool = false, copiedAt: Date?) {
        self.title = title
        self.systemImage = systemImage
        self.iconOnly = iconOnly
        self.copiedAt = copiedAt
    }

    var body: some View {
        HStack(spacing: 6) {
            // Both drawn, one shown, so nothing moves when they swap.
            ZStack {
                Image(systemName: systemImage)
                    .opacity(copied ? 0 : 1)
                    .scaleEffect(copied && !reduceMotion ? 0.6 : 1)
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    // Green clashes with a fill: there it keeps the button's text colour.
                    .foregroundStyle(filled ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.confirmed))
                    .opacity(copied ? 1 : 0)
                    .scaleEffect(copied || reduceMotion ? 1 : 0.6)
            }
            if !iconOnly {
                ZStack(alignment: .leading) {
                    Text(title)
                        .opacity(copied ? 0 : 1)
                        .offset(y: copied && !reduceMotion ? -4 : 0)
                    Text("Copied")
                        .opacity(copied ? 1 : 0)
                        .offset(y: copied || reduceMotion ? 0 : 4)
                }
            }
        }
        .animation(copied ? CopyFeedback.enter(reduceMotion: reduceMotion) : CopyFeedback.exit, value: copied)
        .task(id: copiedAt) {
            let left = copiedAt.map { CopyFeedback.hold - .seconds(Date.now.timeIntervalSince($0)) } ?? .zero
            guard left > .zero else {
                copied = false
                return
            }
            copied = true
            try? await Task.sleep(for: left)
            if !Task.isCancelled { copied = false }
        }
    }
}

/// The pill a menu's copy leaves at the bottom of the window.
struct ToastView: View {
    /// Read here, not by the window's root, so only the pill redraws.
    let presenter: MenuPresenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toast = presenter.toast
        ZStack {
            if let toast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.confirmed)
                    Text(toast.text)
                }
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .menuBoxed(in: Capsule(style: .circular))
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 6)),
                                      removal: .opacity)
                )
                .task(id: toast.id) {
                    try? await Task.sleep(for: CopyFeedback.hold)
                    if !Task.isCancelled { presenter.hideToast(id: toast.id) }
                }
            }
        }
        .animation(toast == nil ? CopyFeedback.exit : CopyFeedback.enter(reduceMotion: reduceMotion), value: toast == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
