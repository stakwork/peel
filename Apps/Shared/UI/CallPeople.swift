import SwiftUI
import PeelCore
import PeelUI

// Shared by the Mac's call card and window and the phone's call row.

/// The green dot of someone on a call (`#49C998`, Sphinx's online green).
/// Grey (`secondaryText`) for a call that is not connected.
struct OnlineDot: View {
    var color = Theme.confirmed

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// Up to three people on a call, overlapping, then "+N". Names and photos
/// are what each joiner sent: shown as given, never matched to a contact.
/// You are told apart by the ticket's identity.
struct CallPeopleStack: View {
    @Environment(AppModel.self) private var model
    let people: [CallParticipant]
    let size: CGFloat
    let border: Color
    @State private var showing = false
    #if os(macOS)
    @State private var hoverTask: Task<Void, Never>?
    #endif

    var body: some View {
        HStack(spacing: -7) {
            ForEach(people.prefix(3)) { person in
                let shown = model.avatar(of: person)
                Avatar(name: shown.avatarName, url: shown.photoURL, size: size, hue: shown.hue)
                .padding(2)
                .background(border, in: Circle())
                .help(shown.name)
            }
            if people.count > 3 {
                Text("+\(people.count - 3)")
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                    .padding(.leading, 11)
            }
        }
        .padding(-2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(people.count == 1 ? "1 person on the call" : "\(people.count) people on the call")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !people.isEmpty { showing = true } }
        #if os(macOS)
        .onHover { inside in
            hoverTask?.cancel()
            guard !people.isEmpty else { return }
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled { showing = true }
                }
            } else {
                showing = false
            }
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            CallParticipantsList(people: people)
        }
        #else
        .onTapGesture { if !people.isEmpty { showing = true } }
        .popover(isPresented: $showing) {
            CallParticipantsList(people: people)
                .presentationCompactAdaptation(.popover)
        }
        #endif
    }
}

/// Everyone on a call, as each joiner presented themselves.
struct CallParticipantsList: View {
    @Environment(AppModel.self) private var model
    let people: [CallParticipant]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(people) { person in
                    let shown = model.avatar(of: person)
                    HStack(spacing: 8) {
                        Avatar(name: shown.avatarName, url: shown.photoURL, size: Theme.AvatarSize.sm, hue: shown.hue)
                        Text(shown.name)
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 180, maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}
