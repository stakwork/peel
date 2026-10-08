import SwiftUI

// Peel's form system, direction A (Tom, 2026-10-08): inset grouped sections
// on a recessed popover, the label on the left of each row and its value on
// the right. See docs/design/README.md, "Forms".

/// A form in a popover: the title with a close button, the sections, then
/// the footer (`FormFooter`). The popover is recessed (`Theme.sidebar`) so
/// the sections (`Theme.menu`) sit up off it. `compact` is for a form of one
/// or two fields, such as Join a tribe: narrower, with boxed fields
/// (`FormTextField(boxed:)`) straight on the popover and no sections.
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
            VStack(alignment: .leading, spacing: compact ? 10 : 0) {
                content
            }
            .padding(.horizontal, compact ? 18 : 14)
            .padding(.top, compact ? 10 : 6)
            .padding(.bottom, 4)
            footer
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
        }
        .frame(width: compact ? 320 : 372)
        // The shadow on the box alone: on the whole view every label would cast one.
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.sidebar)
                .shadow(color: Theme.popoverShadow, radius: 10, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.formEdge))
        .preference(key: DrawsOwnPanelBox.self, value: true)
    }
}

/// Set by a panel that draws its own box (`FormPopover`), so the presenter
/// leaves out the menu box it gives every other panel.
struct DrawsOwnPanelBox: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// A titled group of rows on a raised card, a hairline between rows.
struct FormSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(Theme.font(11, .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
            }
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Theme.divider.frame(height: 1) }
                        row
                    }
                }
            }
            .formCard()
        }
        .padding(.top, title == nil ? 14 : 12)
    }
}

extension View {
    /// A section's raised card; also behind a form's previews (a tribe, a
    /// contact) and the Account screen's boxes.
    func formCard() -> some View {
        background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.menu)
                .shadow(color: Theme.sectionShadow, radius: 1, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.formEdge))
    }

    /// A row's inset and height: at least 38 tall, 12 pt in from the card.
    fileprivate func formRowPadding() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minHeight: 38)
    }
}

/// One row of a section: the label (and a line under it, `detail`) on the
/// left, the value on the right; `stacked` puts the value under the label,
/// for a field of several lines. `problem` shows under the row.
struct FormRow<Value: View>: View {
    let label: String
    var detail: String?
    var stacked = false
    var problem: String?
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    FormLabel(label, detail: detail)
                    value
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    FormLabel(label, detail: detail).frame(width: 118, alignment: .leading)
                    value.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .formRowPadding()
            }
            if let problem { FormProblem(problem) }
        }
    }
}

/// A row's label, with its description under it in the secondary colour.
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

/// What is wrong with one field, under its row: amber, not red, since
/// nothing was lost.
private struct FormProblem: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.font(11))
            .foregroundStyle(Theme.attention)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
            .padding(.top, -3)
    }
}

/// How a field looks in each state: no box at rest (a boxed field keeps a
/// soft fill), a soft fill under the pointer, a dark well with an accent
/// ring while focused, an amber ring while it has a problem. Also the
/// cells of the PIN and the twelve words.
struct FieldChrome: ViewModifier {
    let focused: Bool
    var hovering = false
    var boxed = true
    var problem = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let well = focused || problem
        content
            .background(well ? Theme.input : boxed || hovering ? Theme.fieldFill : .clear, in: shape)
            .overlay { if well { shape.strokeBorder(focused ? Theme.accent : Theme.attention) } }
            .background {
                if well {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(focused ? Theme.focusRing : Theme.problemRing)
                        .padding(-3)
                }
            }
            .animation(.easeOut(duration: 0.12), value: well)
    }
}

/// A one-line text field (`axis: .vertical` for several lines). In a row
/// its text sits on the right at rest and moves left while you type; a
/// several-line field and a `boxed` one (on a compact popover, a page, a
/// search) read left. `systemImage` goes before the text, as a search's
/// magnifying glass; `focusOnAppear` takes the keyboard when it appears.
struct FormTextField: View {
    let label: String
    var prompt: String?
    @Binding var text: String
    var axis: Axis = .horizontal
    var boxed = false
    var problem = false
    var systemImage: String?
    var monospaced = false
    var focusOnAppear = false

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        let multiline = axis == .vertical
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            // At rest in a row the text reads right: a label on the section's
            // card covers the field, which keeps reading left, since AppKit
            // ends editing when a field's alignment changes as it is focused.
            // Clicks go through the label to the field.
            let resting = !(focused || problem || boxed || multiline)
            TextField(label, text: $text, prompt: prompt.map { Text($0).foregroundStyle(Theme.tertiaryText) }, axis: axis)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .fontDesign(monospaced ? .monospaced : nil)
                .lineLimit(multiline ? 2...4 : 1...1)
                .focused($focused)
                .overlay {
                    if resting {
                        Text(text.isEmpty ? prompt ?? "" : text)
                            .font(Theme.font(13))
                            .foregroundStyle(text.isEmpty ? Theme.tertiaryText : Theme.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .background(hovering ? Theme.fieldFill : .clear)
                            .background(Theme.menu)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, multiline ? 5 : 0)
        .frame(minHeight: multiline ? 44 : 26, alignment: multiline ? .topLeading : .leading)
        .modifier(FieldChrome(focused: focused, hovering: hovering, boxed: boxed, problem: problem))
        // A several-line field lines its text up with the label above it.
        .padding(.horizontal, multiline && !boxed ? -8 : 0)
        .background { FocusCatcher(focused: $focused) }
        .onHover { hovering = $0 }
        .onAppear { if focusOnAppear { focused = true } }
    }
}

/// A small boxed number field with its unit inside, on the right of a row.
struct FormNumberField: View {
    let label: String
    @Binding var text: String
    let unit: String
    var prompt = "0"
    var problem = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .focused($focused)
            Text(unit)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .frame(width: 108, height: 26)
        .modifier(FieldChrome(focused: focused, hovering: false, boxed: true, problem: problem))
        .background { FocusCatcher(focused: $focused) }
    }
}

/// Behind a field: a click on its padding or its unit focuses it, while
/// clicks on the text itself stay the text field's (caret, selection).
private struct FocusCatcher: View {
    var focused: FocusState<Bool>.Binding

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
    }
}

/// A row with a switch: the label and its description on the left.
struct FormSwitchRow: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { FormLabel(label, detail: detail) }
            .toggleStyle(FormSwitchStyle())
            .formRowPadding()
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
            .opacity(isEnabled ? 1 : 0.45)
        }
        // One element for VoiceOver: the label, read once, as a switch.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The form's buttons, 28 high: `primary` commits (a quiet neutral chip
/// while it cannot; `fill` in place of the button colour, orange for a
/// payment waiting for its second click), `secondary` is outlined,
/// `destructive` is outlined with red text, for the second click of an
/// in-place confirm.
struct FormButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        FormButton(configuration: configuration, kind: kind, fill: fill)
    }

    private struct FormButton: View {
        let configuration: Configuration
        let kind: Kind
        let fill: Color?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            let primary = kind == .primary
            configuration.label
                .font(Theme.font(13, primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(background, in: shape)
                .overlay { shape.strokeBorder(border) }
                .brightness(brightness)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .environment(\.filledButton, primary && isEnabled)
        }

        private var foreground: Color {
            switch kind {
            case .primary: isEnabled ? Theme.buttonText : Theme.tertiaryText
            case .secondary: isEnabled ? Theme.text : Theme.tertiaryText
            case .destructive: isEnabled ? Theme.destructive : Theme.tertiaryText
            }
        }

        /// A primary button a touch brighter under the pointer, darker pressed.
        private var brightness: Double {
            guard kind == .primary, isEnabled else { return 0 }
            return configuration.isPressed ? -0.07 : hovering ? 0.05 : 0
        }

        private var border: Color {
            guard kind == .primary else { return Theme.divider }
            return isEnabled ? .clear : Theme.formEdge
        }

        private var background: Color {
            if kind == .primary { return isEnabled ? fill ?? Theme.button : Theme.fieldFill }
            return isEnabled && (hovering || configuration.isPressed) ? Theme.hover : .clear
        }
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
            .padding(.top, 14)
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
        /// Outlined form buttons.
        case buttons
        /// A row's small text buttons, in the row's font.
        case text
        /// A form's last card: a full-width red row (`FormDestructiveSection`).
        case section
    }

    var prompt: String?
    var explanation: String?
    let confirm: String
    var confirmKind = FormButtonStyle.Kind.destructive
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
        case .buttons: Button(action: open) { trigger }.buttonStyle(FormButtonStyle())
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
            styled(Button("Cancel") { isAsking.wrappedValue = false }, .secondary)
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
    @ViewBuilder private func styled(_ button: some View, _ kind: FormButtonStyle.Kind) -> some View {
        if style == .text {
            button
                .buttonStyle(.plain)
                .foregroundStyle(kind == .destructive ? Theme.destructive : kind == .primary ? Theme.accent : Theme.secondaryText)
        } else {
            button.buttonStyle(FormButtonStyle(kind: kind))
        }
    }
}

extension InlineConfirm where Trigger == Text {
    init(
        trigger: String, prompt: String? = nil, explanation: String? = nil, confirm: String,
        confirmKind: FormButtonStyle.Kind = .destructive, style: Style = .buttons,
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
                .background(hovering ? Theme.fieldFill : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

