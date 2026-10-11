import SwiftUI

/// A panel: shadcn's `Card` in a popover, drawing its own box. The title
/// with a close button, the body, then the footer (a form's is
/// `FormFooter`). 372 wide, or 320 with `compact`, for a form of one or two
/// fields with no sections, such as Join a tribe.
///
/// ```swift
/// Panel("Tribe details", close: done) {
///     body
/// } footer: {
///     FormFooter(problem: problem) { … }
/// }
/// ```
struct Panel<Content: View, Footer: View>: View {
    private let title: String
    private let compact: Bool
    private let close: () -> Void
    private let content: Content
    private let footer: Footer

    init(
        _ title: String, compact: Bool = false, close: @escaping () -> Void,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.compact = compact
        self.close = close
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(Theme.font(15, .bold))
                Spacer(minLength: 8)
                IconButton("xmark", help: "Close", action: close)
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: compact ? 12 : 0) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.top, compact ? 10 : 2)
            .padding(.bottom, 4)
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        }
        .frame(width: compact ? 320 : 372)
        // The shadow on the box alone: on the whole view every label would cast one.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(Theme.sidebar)
                .shadow(color: Theme.popoverShadow, radius: 10, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.formEdge))
        .endsEditingOnClick()
        .preference(key: DrawsOwnPanelBox.self, value: true)
    }
}

/// Set by `Panel`, so the presenter leaves out the menu box it gives a
/// panel that draws none of its own.
struct DrawsOwnPanelBox: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
