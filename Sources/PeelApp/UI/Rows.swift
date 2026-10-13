import SwiftUI
import PeelUI

/// A row in a list: shadcn's `Item`. Something at the start (an avatar, a
/// tick), a title over an optional muted detail, and something at the end
/// (a time, an amount, a row's own buttons). With an action it is a button
/// that lights under the pointer; `selected` is the one selected fill,
/// `Theme.selection`, as the sidebar's selected chat. Without an action it
/// only lays out (a member, a booster) and never lights.
///
/// ```swift
/// ListRow(selected: isOn, action: open) {
///     Avatar(…)
/// } title: { Text(name) } detail: { Text("2 min ago") } trailing: { … }
/// ```
///
/// The sidebar's own rows keep `SidebarRowStyle` (14 pt, their unread and
/// keyboard states), with the same fills.
struct ListRow<Leading: View, Title: View, Detail: View, Trailing: View>: View {
    enum Size {
        /// One line, 28 tall at least: a time zone, a member, a search result
        /// (36, its own `minHeight`).
        case sm
        /// A larger avatar or two lines: a payment, a mention.
        case md

        var spacing: CGFloat { self == .sm ? 8 : 12 }
        var padding: EdgeInsets {
            self == .sm ? EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
                : EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        }
    }

    /// Every row's corners, the sidebar's.
    static var radius: CGFloat { Theme.Radius.control }

    private let size: Size
    private let selected: Bool
    private let tint: Color?
    private let alignment: VerticalAlignment
    private let minHeight: CGFloat
    private let action: (() -> Void)?
    private let leading: Leading
    private let title: Title
    private let detail: Detail
    private let trailing: Trailing

    @State private var hovering = false

    /// `tint` fills a row that is not selected, under the pointer or not
    /// (a payment just received). `alignment` is the start's and end's
    /// against the title and detail, centred but for a long detail (a
    /// mention's text). `minHeight` is for a list of fixed rows.
    init(
        size: Size = .sm, selected: Bool = false, tint: Color? = nil, alignment: VerticalAlignment = .center,
        minHeight: CGFloat = 28, action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading, @ViewBuilder title: () -> Title,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) {
        self.size = size
        self.selected = selected
        self.tint = tint
        self.alignment = alignment
        self.minHeight = minHeight
        self.action = action
        self.leading = leading()
        self.title = title()
        self.detail = detail()
        self.trailing = trailing()
    }

    var body: some View {
        if let action {
            Button(action: action) {
                content
                    .background(fill, in: RoundedRectangle(cornerRadius: Self.radius))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            // The padding too, so a right-click there opens the row's menu.
            content.contentShape(Rectangle())
        }
    }

    private var content: some View {
        HStack(alignment: alignment, spacing: size.spacing) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.text)
                detail
                    .font(Theme.font(12))
                    .foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A long title gives way to the end: a time or an amount (fixed
            // by the caller) or a row's buttons, which wrap before they spill.
            .layoutPriority(-1)
            // At least twice the spacing between the title and the end.
            trailing
                .foregroundStyle(muted)
                .padding(.leading, size.spacing)
        }
        .padding(size.padding)
        .frame(minHeight: minHeight)
    }

    /// The detail's and the end's colour: on the selected fill the
    /// sidebar's pairing, `selectionText` at 80% (4.8:1 light, 7.1:1 dark,
    /// where `secondaryText` is 4.3 and 3.9).
    private var muted: Color {
        selected ? Theme.selectionText.opacity(0.8) : Theme.secondaryText
    }

    private var fill: Color {
        selected ? Theme.selection : tint ?? (hovering ? Theme.hover : .clear)
    }
}

extension ListRow where Detail == EmptyView {
    init(
        size: Size = .sm, selected: Bool = false, tint: Color? = nil, alignment: VerticalAlignment = .center,
        minHeight: CGFloat = 28, action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading, @ViewBuilder title: () -> Title, @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(size: size, selected: selected, tint: tint, alignment: alignment, minHeight: minHeight, action: action,
                  leading: leading, title: title, detail: { EmptyView() }, trailing: trailing)
    }
}

/// Facts in a card: shadcn's description list. Each `Fact` is a muted name
/// in a column and its value beside it, with an optional action at the
/// end; a hairline between them. Tribe details, a payment, an invoice, and
/// the Account's settings (their column wider, `labelWidth: 150`).
///
/// ```swift
/// FactList {
///     Fact("Owner") { … }
///     Fact("Each message", text: "3 sats")
/// }
/// ```
struct FactList<Content: View>: View {
    private let labelWidth: CGFloat
    private let content: Content

    init(labelWidth: CGFloat = 100, @ViewBuilder content: () -> Content) {
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        Card {
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Theme.divider.frame(height: 1) }
                        row
                    }
                }
            }
        }
        .environment(\.factLabelWidth, labelWidth)
    }
}

/// One fact of a `FactList`: its name, the value, and an action at the end
/// (Edit, Copy). Name, value and action share the first line's baseline,
/// so a value with a note under it, or one that wraps, reads from the top.
struct Fact<Value: View, Trailing: View>: View {
    @Environment(\.factLabelWidth) private var labelWidth
    private let label: String
    private let value: Value
    private let trailing: Trailing

    init(_ label: String, @ViewBuilder value: () -> Value, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.value = value()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: labelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .font(Theme.font(13))
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
    }
}

extension Fact where Trailing == EmptyView {
    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.init(label, value: value, trailing: { EmptyView() })
    }
}

extension Fact where Value == FactText {
    /// A value in words, selectable, wrapping, with an icon before it.
    init(_ label: String, text: String, symbol: String? = nil, tint: Color? = nil, monospaced: Bool = false,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(label, value: { FactText(text: text, symbol: symbol, tint: tint, monospaced: monospaced) },
                  trailing: trailing)
    }
}

extension Fact where Value == FactText, Trailing == EmptyView {
    init(_ label: String, text: String, symbol: String? = nil, tint: Color? = nil, monospaced: Bool = false) {
        self.init(label, text: text, symbol: symbol, tint: tint, monospaced: monospaced) { EmptyView() }
    }
}

/// A fact's value in words: the icon (muted) and the text, both in `tint`
/// when there is one (an expired invoice's attention colour).
struct FactText: View {
    let text: String
    let symbol: String?
    let tint: Color?
    let monospaced: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint ?? Theme.secondaryText)
            }
            Text(text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : Theme.font(13))
                .monospacedDigit()
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension EnvironmentValues {
    @Entry var factLabelWidth: CGFloat = 100
}
