import SwiftUI

// Peel's form system: shadcn's conventions in SwiftUI (Tom, 2026-10-09),
// replacing direction A's label-left, value-right rows for text. Each field
// is a `FormItem`, its label above a bordered input that reads left; switches
// keep their label on the left. See docs/design/README.md, "Forms".

/// A form in a popover: the title with a close button, the sections, then
/// the footer (`FormFooter`). `compact` is for a form of one or two fields,
/// such as Join a tribe: narrower, with no sections.
struct FormPopover<Content: View, Footer: View>: View {
    let title: String
    var compact = false
    let close: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(Theme.font(15, .bold))
                Spacer(minLength: 8)
                HoverIconButton(systemImage: "xmark", help: "Close", action: close)
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

/// Set by a panel that draws its own box (`FormPopover`), so the presenter
/// leaves out the menu box it gives every other panel.
struct DrawsOwnPanelBox: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

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

    /// A raised card with a hairline: a switch row, a form's previews (a
    /// tribe, a contact), the Account screen's sections and boxes.
    func formCard() -> some View {
        background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.menu)
                .shadow(color: Theme.sectionShadow, radius: 1, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.formEdge))
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
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            content
        }
        .padding(.top, 16)
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

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        let multiline = axis == .vertical
        HStack(alignment: multiline ? .firstTextBaseline : .center, spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            // No prompt is an empty one: the label above already names the field.
            TextField(label, text: $text, prompt: Text(prompt ?? "").foregroundStyle(Theme.tertiaryText), axis: axis)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .fontDesign(monospaced ? .monospaced : nil)
                .lineLimit(multiline ? 3...6 : 1...1)
                .focused($focused)
        }
        .padding(.horizontal, 12)
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
        .padding(.horizontal, 12)
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
        Toggle(isOn: $isOn) { FormLabel(label, detail: detail) }
            .toggleStyle(FormSwitchStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .formCard()
    }
}

/// Peel's switch: 30 by 18, the button colour when on.
private struct FormSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Theme.button : Theme.switchOff)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Theme.switchKnob)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                            .padding(2)
                    }
                    .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isOn)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.5)
        }
        // One element for VoiceOver: the label, read once, as a switch.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
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
        InlineConfirm(trigger: trigger, prompt: prompt, explanation: explanation, confirm: confirm, style: .section, action: action)
            .formCard()
            .padding(.top, 16)
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
        Group {
            if isAsking.wrappedValue {
                question
            } else {
                triggerButton
            }
        }
        .disabled(working)
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
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
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

    private var answers: some View {
        HStack(spacing: style == .text ? 12 : 8) {
            if let prompt {
                // A row's prompt takes the row's font.
                if style == .text {
                    Text(prompt).foregroundStyle(Theme.secondaryText)
                } else {
                    Text(prompt)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if style == .section { Spacer(minLength: 8) }
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
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(hovering ? Theme.fieldFill : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

