import SwiftUI
import PeelUI

/// Measures of a `Panel` that callers compute from.
enum PanelMetrics {
    /// The body's and footer's horizontal padding.
    static let inset: CGFloat = 18
    /// From the right edge to an icon button that ends a row: the header's
    /// close, and a fitted status row's action.
    static let actionInset: CGFloat = 10
}

/// A panel: shadcn's `Card` in a popover, the only box a popover has. The
/// title with the panel's own utility actions (Copy link, as icon buttons)
/// and a close button, the body, then the footer: navigation (Members,
/// Edit tribe…) on the left, the commit or the destructive action on the
/// right, never both (a form's is `FormFooter`). The actions may be left
/// out, or both the actions and the footer. 372 wide, or 320 with
/// `compact` (or, with `fit`, as wide as its content: a status row), for a
/// short form with no sections (Join a tribe) or a short list (Members). A
/// nil title omits the header for a single status row; the popover still
/// dismisses on Escape or a click outside.
///
/// ```swift
/// Panel("Members", compact: true, close: done) {
///     body
/// } actions: {
///     CopyButton("Copy link", text: link, systemImage: "link", iconOnly: true)
/// } footer: {
///     FormFooter(problem: problem) { … }
/// }
/// ```
struct Panel<Content: View, Actions: View, Footer: View>: View {
    private let title: String?
    private let compact: Bool
    private let fit: Bool
    private let close: () -> Void
    private let content: Content
    private let actions: Actions
    private let footer: Footer

    init(
        _ title: String?, compact: Bool = false, fit: Bool = false, close: @escaping () -> Void,
        @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.compact = compact
        self.fit = fit
        self.close = close
        self.content = content()
        self.actions = actions()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: Theme.Space.xs) {
                    Text(title).font(Theme.font(15, .bold))
                    Spacer(minLength: 8)
                    actions
                    IconButton("xmark", help: "Close", action: close)
                }
                .padding(.leading, PanelMetrics.inset)
                .padding(.trailing, PanelMetrics.actionInset)
                .padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: compact ? 12 : 0) {
                content
            }
            .padding(.leading, PanelMetrics.inset)
            // A fitted status row ends in its action, placed as the header's close.
            .padding(.trailing, fit ? PanelMetrics.actionInset : PanelMetrics.inset)
            .padding(.top, title == nil ? 12 : compact ? 10 : 2)
            .padding(.bottom, Theme.Space.xs)
            // No footer (left out, or a condition that is false) takes no room.
            footer
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.top, Theme.Space.lg)
        }
        .padding(.bottom, title == nil ? 8 : Theme.Space.lg)
        // `fit` takes the content's ideal width (a one-line status row).
        .frame(width: fit ? nil : compact ? 320 : 372)
        // The shadow on the box alone: on the whole view every label would cast one.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(Theme.sidebar)
                .shadow(color: Theme.popoverShadow, radius: 10, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.formEdge))
        .endsEditingOnClick()
    }
}

extension Panel where Actions == EmptyView {
    init(
        _ title: String?, compact: Bool = false, close: @escaping () -> Void,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(title, compact: compact, close: close, content: content, actions: { EmptyView() }, footer: footer)
    }
}

extension Panel where Actions == EmptyView, Footer == EmptyView {
    init(_ title: String?, compact: Bool = false, fit: Bool = false, close: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(title, compact: compact, fit: fit, close: close, content: content, actions: { EmptyView() }, footer: { EmptyView() })
    }
}

/// The top of a details panel (a contact's, a tribe's): the picture, the
/// name, and muted lines under it.
struct PanelHero<Picture: View, Lines: View>: View {
    let name: String
    @ViewBuilder let picture: Picture
    @ViewBuilder let lines: Lines

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            picture
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(Theme.font(16, .bold))
                    .lineLimit(2)
                lines
                    .muted()
            }
        }
    }
}
