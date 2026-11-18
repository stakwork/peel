import PeelUI
import SwiftUI

/// "Let the model see this picture", under a picture waiting in the agent
/// chat's composer, on the Mac and the phone alike: off until turned on,
/// with what each side means under it (`ModelSight`). Nothing for any
/// other file or chat; the state is dropped with the file.
struct ModelSightToggle: View {
    @Environment(AppModel.self) private var model
    let file: URL
    let composer: ComposerID

    var body: some View {
        if model.offersModelSight(file, in: composer) {
            let on = Binding(
                get: { model.modelMaySee(file, in: composer) },
                set: { model.setModelMaySee($0, for: file, in: composer) }
            )
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: on) {
                    Text(ModelSight.title).font(Theme.font(11, .medium)).lineLimit(1)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text(ModelSight.help)
                    .font(Theme.font(10))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 210, alignment: .leading)
            .accessibilityHint(ModelSight.help)
        }
    }
}
