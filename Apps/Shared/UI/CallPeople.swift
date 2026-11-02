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
        .accessibilityHidden(true)
    }
}
