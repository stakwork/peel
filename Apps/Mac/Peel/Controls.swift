import SwiftUI
import PeelCore
import PeelUI

/// An icon button that opens a menu below it, such as a message's More; lit
/// while its menu is open.
struct MenuButton<Label: View>: View {
    @Environment(\.menuPresenter) private var presenter
    let help: String
    var source: AnyHashable?
    /// `.trailing` for a button at the end of a row: the menu's right edge in line with it.
    var edge: PopoverEdge = .leading
    let entries: @MainActor () -> [MenuEntry]
    @ViewBuilder let label: () -> Label

    @State private var anchor = MenuAnchor()

    var body: some View {
        IconButton(help: help, lit: presenter?.isOpen(from: source) == true) {
            presenter?.show(entries(), at: anchor, source: source, edge: edge)
        } label: {
            label()
        }
        .menuAnchor(anchor)
        .onDisappear { presenter?.menuTriggerGone(source) }
    }
}

extension MenuButton where Label == Image {
    init(systemImage: String, help: String, source: AnyHashable? = nil, edge: PopoverEdge = .leading,
         entries: @escaping @MainActor () -> [MenuEntry]) {
        self.init(help: help, source: source, edge: edge, entries: entries) { Image(systemName: systemImage) }
    }
}

/// Peel's pop-up button: shows the chosen value and opens the menu below
/// itself, with a check by the current one.
struct PeelDropdown<Value: Hashable>: View {
    @Environment(\.menuPresenter) private var presenter
    let selection: Value
    let options: [(value: Value, label: String)]
    let choose: @MainActor (Value) -> Void

    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        Button {
            presenter?.show(
                options.map { option in
                    .button(option.label, checked: option.value == selection) { choose(option.value) }
                },
                at: anchor, minWidth: anchor.screenRect.width, highlightChecked: true
            )
        } label: {
            HStack(spacing: Theme.Space.sm) {
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
        .menuAnchor(anchor)
    }
}

/// A setting chosen from a `PeelDropdown` and saved at once, with its help
/// (if any) muted under it, or what went wrong saving it.
struct SettingDropdown<Value: Hashable>: View {
    let selection: Value
    let options: [(value: Value, label: String)]
    var help: String?
    let save: @MainActor (Value) async throws -> Void

    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PeelDropdown(selection: selection, options: options) { value in
                Task {
                    do {
                        try await save(value)
                        problem = nil
                    } catch {
                        problem = PeelError.problem(error, couldNot: "change the setting")
                    }
                }
            }
            .fixedSize()
            if let text = problem ?? help {
                Text(text)
                    .muted()
            }
        }
    }
}

extension View {
    /// A keyboard shortcut with no button to show: `action` runs on
    /// `shortcut` while this view is on screen and `enabled` holds.
    func hiddenShortcut(_ shortcut: KeyboardShortcut, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        background {
            if enabled {
                Button("", action: action)
                    .keyboardShortcut(shortcut)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
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
/// running shows its spinner inside it, `buttonProgress`), lined up on
/// their text, so a money button's "Click again to confirm" hangs below.
struct FormFooter<Buttons: View>: View {
    let problem: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let problem { ProblemText(problem) }
            Spacer()
            buttons
        }
    }
}

/// A quiet line with a chevron that opens what is under it: the agent
/// chat's tool rows, a form's "Enter address and key instead".
struct DisclosureButton<Label: View>: View {
    @Binding var open: Bool
    @ViewBuilder let label: Label

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                label
            }
            .font(Theme.font(13))
            .foregroundStyle(Theme.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}
