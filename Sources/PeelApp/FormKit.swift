import SwiftUI
import PeelUI

// Peel's form system: shadcn's conventions in SwiftUI (Tom, 2026-10-09),
// replacing direction A's label-left, value-right rows for text. Each field
// is a `FormItem`, its label above a bordered input that reads left; switches
// keep their label on the left. A form in a popover is a `Panel` (UI/Panel.swift).
// See docs/design/README.md, "Forms".

extension View {
    /// A click on the form anywhere but a field or a control ends editing:
    /// the caret goes and the field is at rest again, as on the web. A
    /// field's own click, and a button's, win over this one.
    func endsEditingOnClick() -> some View {
        contentShape(Rectangle())
            .onTapGesture {
                #if os(macOS)
                // The key window, the one clicked (a popover is a window of
                // its own). Not `NSApp.currentEvent`'s: by the time a tap's
                // action runs that is no longer the click.
                NSApp.windows.first(where: \.isKeyWindow)?.makeFirstResponder(nil)
                #endif
            }
    }
}

/// A group of fields under a heading ("Basics", "Pricing"), stacked.
struct FormSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let title { SectionHeader(title) }
            content
        }
        .padding(.top, Theme.Space.lg)
    }
}

/// One field: its label above it, then the field, then a line of help, or
/// what is wrong with it in place of the help.
struct FormItem<Field: View>: View {
    let label: String
    var helper: String?
    var problem: String?
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.font(13, .medium))
            field
            if let text = problem ?? helper {
                Text(text)
                    .font(Theme.font(12))
                    .foregroundStyle(problem == nil ? Theme.secondaryText : Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label with its description under it in the secondary colour: a
/// switch row's, an Account row's.
struct FormLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.font(13))
            if let detail {
                Text(detail)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// How a field looks in each state, as shadcn's input: a soft fill and a
/// 1 pt border at rest, a stronger border under the pointer, an accent
/// border with a 3 pt ring outside while focused, amber border and ring
/// while it has a problem (amber, not red: nothing was lost), half
/// opacity while off. Also the cells of the PIN and the twelve words.
struct FieldChrome: ViewModifier {
    let focused: Bool
    var hovering = false
    var problem = false

    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let border = problem ? Theme.attention : focused ? Theme.accent
            : hovering && isEnabled ? Theme.inputBorderHover : Theme.inputBorder
        let ring = problem ? Theme.problemRing : focused ? Theme.focusRing : nil
        content
            .background(Theme.fieldFill, in: shape)
            .overlay { shape.strokeBorder(border) }
            // The ring is the 3 pt band just outside the border.
            .background {
                if let ring {
                    RoundedRectangle(cornerRadius: Theme.Radius.control + 3, style: .continuous)
                        .strokeBorder(ring, lineWidth: 3)
                        .padding(-3)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A text input, 32 tall and the width of the form, its text on the left
/// (`axis: .vertical` for a textarea of three lines or more). `systemImage`
/// goes before the text, as a search's magnifying glass; `focusOnAppear`
/// takes the keyboard when it appears, and each change of `focusRequest`
/// takes it again. The label is its accessibility name
/// (and, in a `FormItem`, the text above it); the prompt is its placeholder.
struct FormTextField: View {
    let label: String
    var prompt: String?
    @Binding var text: String
    var axis: Axis = .horizontal
    var problem = false
    var systemImage: String?
    var monospaced = false
    var focusOnAppear = false
    var focusRequest = 0
    /// Dots for what is typed (an API key); one line.
    var secure = false

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        let multiline = axis == .vertical && !secure
        HStack(alignment: multiline ? .firstTextBaseline : .center, spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            // No prompt is an empty one: the label above already names the field.
            let prompt = Text(prompt ?? "").foregroundStyle(Theme.tertiaryText)
            Group {
                if secure {
                    SecureField(label, text: $text, prompt: prompt)
                } else {
                    TextField(label, text: $text, prompt: prompt, axis: axis)
                        .lineLimit(multiline ? 3...6 : 1...1)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.font(13))
            .fontDesign(monospaced ? .monospaced : nil)
            .focused($focused)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, multiline ? 8 : 0)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: multiline ? .topLeading : .leading)
        .modifier(FieldChrome(focused: focused, hovering: hovering, problem: problem))
        .focusesOnClick($focused)
        .onHover { hovering = $0 }
        .onAppear { if focusOnAppear { focused = true } }
        .onChange(of: focusRequest) { focused = true }
    }
}

/// A number input, the same as a text input with the unit inside its right
/// edge in the secondary colour; the digits read left, tabular.
struct FormNumberField: View {
    let label: String
    @Binding var text: String
    let unit: String
    var prompt = "0"
    var problem = false

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .monospacedDigit()
                .focused($focused)
            Text(unit)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 32)
        .modifier(FieldChrome(focused: focused, hovering: hovering, problem: problem))
        .focusesOnClick($focused)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// A click on a field's padding or its unit focuses it; clicks on the
    /// text itself stay the text field's (caret, selection). On the field
    /// itself, so it wins over the form's `endsEditingOnClick`.
    fileprivate func focusesOnClick(_ focused: FocusState<Bool>.Binding) -> some View {
        contentShape(Rectangle()).onTapGesture { focused.wrappedValue = true }
    }
}

/// A switch in a card of its own, as shadcn's: the label and its
/// description on the left, the switch on the right.
struct FormSwitchRow: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Card {
            Toggle(isOn: $isOn) { FormLabel(label, detail: detail) }
                .toggleStyle(FormSwitchStyle())
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 10)
        }
    }
}

/// The switch in a `FormSwitchRow`, its label on the left.
struct FormSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.md) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            PeelSwitch(isOn: configuration.$isOn)
        }
        // One element for VoiceOver: the label, read once, as a switch.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Peel's switch: 30 by 18, the button colour when on. Alone, as at the
/// end of a row, it needs an accessibility label of its own.
struct PeelSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Theme.button : Theme.switchOff)
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Theme.switchKnob)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The destructive action as its own section at the end of a form: one red
/// row, which turns into the question with Cancel and the action (and, with
/// `explanation`, what it does above them), confirmed in place, never in a
/// dialog. The action reports its own failure.
struct FormDestructiveSection: View {
    let trigger: String
    var prompt: String?
    var explanation: String?
    let confirm: String
    let action: () async -> Void

    var body: some View {
        Card {
            InlineConfirm(trigger: trigger, prompt: prompt, explanation: explanation, confirm: confirm, style: .section, action: action)
        }
        .padding(.top, Theme.Space.lg)
    }
}

/// Peel's one in-place confirm, never a dialog: the trigger, then the
/// prompt with Cancel and the action (red unless `confirmKind` says
/// otherwise); `explanation` puts longer words above them. Off while the
/// action runs, with the spinner in the action's button; the action reports
/// its own failure. Pass `confirming` to hide what stands beside it while it
/// asks, or to cancel it from outside.
struct InlineConfirm<Trigger: View>: View {
    enum Style {
        /// Form buttons: an outline Cancel, then the action.
        case buttons
        /// A row's small text buttons, in the row's font.
        case text
        /// A form's last card: a full-width red row (`FormDestructiveSection`).
        case section
    }

    var prompt: String?
    var explanation: String?
    let confirm: String
    var confirmKind = PeelButton.Variant.destructive
    var style = Style.buttons
    var alignment = HorizontalAlignment.leading
    var confirming: Binding<Bool>?
    let action: () async -> Void
    @ViewBuilder let trigger: Trigger

    @State private var asking = false
    @State private var working = false

    private var isAsking: Binding<Bool> { confirming ?? $asking }

    var body: some View {
        // A container, not a Group: `onDisappear` then means this confirm
        // went, not the trigger giving way to the question.
        ZStack {
            if isAsking.wrappedValue {
                question
            } else {
                triggerButton
            }
        }
        .disabled(working)
        // A `confirming` binding outlives this view: gone, it no longer asks.
        .onDisappear { confirming?.wrappedValue = false }
    }

    @ViewBuilder private var triggerButton: some View {
        let open = { isAsking.wrappedValue = true }
        switch style {
        case .buttons: Button(action: open) { trigger }.buttonStyle(.peel(.outline))
        case .text: Button(action: open) { trigger }.buttonStyle(.plain)
        case .section: SectionTrigger(action: open) { trigger }
        }
    }

    private var question: some View {
        Group {
            if let explanation {
                VStack(alignment: alignment, spacing: 10) {
                    Text(explanation)
                        .font(Theme.font(style == .section ? 12 : 13))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                    answers
                }
            } else {
                answers
            }
        }
        .padding(.horizontal, style == .section ? 12 : 0)
        .padding(.vertical, style == .section ? 9 : 0)
    }

    /// The prompt beside the buttons when it fits on one line, else above
    /// them (wrapping, set by `alignment`). The buttons never shrink.
    @ViewBuilder private var answers: some View {
        if let prompt {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: spacing) {
                    promptText(prompt).fixedSize(horizontal: true, vertical: false)
                    if style == .section { Spacer(minLength: 8) }
                    buttons
                }
                VStack(alignment: alignment, spacing: 6) {
                    promptText(prompt)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                    // A section's buttons stay at its right edge.
                    buttons.frame(maxWidth: style == .section ? .infinity : nil, alignment: .trailing)
                }
            }
        } else {
            HStack(spacing: spacing) {
                if style == .section { Spacer(minLength: 8) }
                buttons
            }
        }
    }

    private var spacing: CGFloat { style == .text ? 12 : 8 }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    /// A row's prompt takes the row's font.
    @ViewBuilder private func promptText(_ prompt: String) -> some View {
        if style == .text {
            Text(prompt).foregroundStyle(Theme.secondaryText)
        } else {
            Text(prompt).muted()
        }
    }

    private var buttons: some View {
        HStack(spacing: spacing) {
            styled(Button("Cancel") { isAsking.wrappedValue = false }, .outline)
            styled(
                Button {
                    working = true
                    Task {
                        await action()
                        working = false
                        isAsking.wrappedValue = false
                    }
                } label: {
                    Text(confirm).buttonProgress(working, size: style == .text ? .mini : .small)
                },
                confirmKind
            )
        }
        .fixedSize()
    }

    /// Form buttons, or text in the colour of what the button does.
    @ViewBuilder private func styled(_ button: some View, _ kind: PeelButton.Variant) -> some View {
        if style == .text {
            button
                .buttonStyle(.plain)
                .foregroundStyle(kind == .destructive ? Theme.destructive : kind == .primary ? Theme.accent : Theme.secondaryText)
        } else {
            button.buttonStyle(.peel(kind))
        }
    }
}

extension InlineConfirm where Trigger == Text {
    init(
        trigger: String, prompt: String? = nil, explanation: String? = nil, confirm: String,
        confirmKind: PeelButton.Variant = .destructive, style: Style = .buttons,
        alignment: HorizontalAlignment = .leading, confirming: Binding<Bool>? = nil,
        action: @escaping () async -> Void
    ) {
        self.init(
            prompt: prompt, explanation: explanation, confirm: confirm, confirmKind: confirmKind, style: style,
            alignment: alignment, confirming: confirming, action: action
        ) { Text(trigger) }
    }
}

/// A destructive section's red row, the width of its card.
private struct SectionTrigger<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(Theme.font(13))
                .foregroundStyle(Theme.destructive)
                .padding(.horizontal, Theme.Space.md)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(hovering ? Theme.fieldFill : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

