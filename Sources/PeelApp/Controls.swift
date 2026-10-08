import SwiftUI

/// An icon button that opens a menu below it, such as a message's More.
struct MenuButton: View {
    @Environment(\.menuPresenter) private var presenter
    let systemImage: String
    let help: String
    var source: AnyHashable?
    let entries: @MainActor () -> [MenuEntry]

    @State private var frame: CGRect = .zero

    var body: some View {
        HoverIconButton(systemImage: systemImage, help: help) {
            presenter?.show(entries(), at: frame, source: source)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// A small icon button that lights up under the pointer: an SF Symbol, or
/// any label (`CopyButton`'s icon).
struct HoverIconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                .frame(width: 28, height: 26)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension HoverIconButton where Label == Image {
    init(systemImage: String, help: String, action: @escaping () -> Void) {
        self.init(help: help, action: action) { Image(systemName: systemImage) }
    }
}

/// Peel's pop-up button: shows the chosen value and opens the menu below
/// itself, with a check by the current one.
struct PeelDropdown<Value: Hashable>: View {
    @Environment(\.menuPresenter) private var presenter
    let selection: Value
    let options: [(value: Value, label: String)]
    let choose: @MainActor (Value) -> Void

    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Button {
            presenter?.show(
                options.map { option in
                    .button(option.label, checked: option.value == selection) { choose(option.value) }
                },
                at: frame, minWidth: frame.width, highlightChecked: true
            )
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(Theme.font(13))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .dropdownBoxed(hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// A sidebar row's badge: an unread count, or what else the row counts
/// (Payments' "+350").
struct UnreadBadge: View {
    let text: String
    var foreground = Theme.buttonText
    var fill = Theme.accent

    init(count: Int) {
        text = Self.text(count)
    }

    init(text: String, foreground: Color, fill: Color) {
        self.text = text
        self.foreground = foreground
        self.fill = fill
    }

    /// A count as badges show it, capped at "99+".
    static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    var body: some View {
        Text(text)
            .font(Theme.font(11, .bold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(fill, in: Capsule())
    }
}

/// Why the last attempt failed: quiet, not red, since nothing was lost.
struct ProblemText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(3)
    }
}

/// A popover form's last row: what went wrong, and its buttons (the one
/// running shows its spinner inside it, `buttonProgress`).
struct FormFooter<Buttons: View>: View {
    let problem: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack {
            if let problem { ProblemText(problem) }
            Spacer()
            buttons
        }
    }
}
