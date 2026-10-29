import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Which version of one of the person's own apps everyone opens, in its
/// header (strut's plans/app-releases.md): a chip with that version, a lock
/// while the app is held at a release, opening the versions menu; beside it
/// "Make vN live" while a newer one waits or this window shows another. A
/// version picked in the menu shows in this window only (`previewing`).
struct AppVersionsControl: View {
    @Environment(\.menuPresenter) private var presenter
    let title: String
    let versions: AppVersions
    /// The version this window shows instead of the live one.
    @Binding var previewing: String?
    /// A change is under way: Make live waits for it.
    let busy: Bool
    /// Asks strut to change what is live, then says `done`.
    let change: (AppLiveTarget, _ done: String) -> Void

    @State private var anchor = MenuAnchor()
    @State private var confirming = false

    /// What marks the chip while its menu is open.
    static let source = "app-versions"
    private var source: String { Self.source }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Chip(lit: presenter?.isOpen(from: source) == true) {
                presenter?.show(entries(), at: anchor, source: source, edge: .trailing)
            } label: {
                HStack(spacing: 5) {
                    if versions.held { Image(systemName: "lock.fill").font(.system(size: 9)) }
                    Text(versions.active)
                    if !versions.behind.isEmpty {
                        Circle().fill(Theme.attention).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(Theme.font(12, .medium))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .frame(height: 24)
            }
            .menuAnchor(anchor)
            .help(versions.held
                  ? "Everyone opens \(versions.active), held at release \(versions.release ?? ""): new versions wait for you"
                  : "Everyone opens \(versions.active): every new version goes live")
            .accessibilityLabel("Versions, \(versions.active) live")
            .accessibilityValue([versions.held ? "held at release \(versions.release ?? "")" : "following latest",
                                 versions.newestWaiting.map { "\($0) waiting" },
                                 versions.behind.isEmpty ? nil : "workflows changed"].compactMap { $0 }.joined(separator: ", "))
            .onDisappear { presenter?.menuTriggerGone(source) }
            if let offer {
                Button("Make \(offer) live") { confirming = true }
                    .buttonStyle(.peel(.primary, size: .sm))
                    .disabled(busy)
                    .peelPopover(isPresented: $confirming, edge: .trailing) {
                        MakeLivePanel(title: title, version: offer, versions: versions) {
                            confirming = false
                        } confirm: {
                            confirming = false
                            change(.version(offer), "\(offer) is live")
                        }
                    }
            }
        }
    }

    /// What "Make live" offers: the version shown here, else the newest waiting.
    private var offer: String? {
        if let previewing, previewing != versions.active { return previewing }
        return versions.newestWaiting
    }

    private func entries() -> [MenuEntry] {
        Self.menu(versions, shown: previewing ?? versions.active, preview: { previewing = $0 }, change: change)
    }

    /// The versions menu: what everyone opens, the newest versions (a pick
    /// is shown in this window only: `preview`, nil for the live one),
    /// History, and Follow latest.
    static func menu(_ versions: AppVersions, shown: String, preview: @escaping @MainActor (String?) -> Void,
                     change: @escaping (AppLiveTarget, _ done: String) -> Void) -> [MenuEntry] {
        let following = "Every version Peel builds goes live"
        let header = versions.release.map { "Everyone opens \(versions.active) · release \($0)" }
            ?? "Everyone opens \(versions.active) · \(following.lowercased())"
        // The newest, and the live and shown ones however far down.
        let listedVersions = versions.versions.enumerated()
            .filter { $0.offset < listed || [versions.active, shown].contains($0.element.label) }.map(\.element)
        let list: [MenuEntry] = listedVersions.map { version in
            .button(version.label, detail: detail(version, in: versions), checked: version.label == shown) {
                preview(version.label == versions.active ? nil : version.label)
            }
        }
        var more: [MenuEntry] = []
        if !versions.releases.isEmpty {
            more.append(.submenu("History", detail: versions.behind.isEmpty ? nil : "changed", history(versions, change: change)))
        }
        if versions.held {
            let newest = versions.versions.first?.label ?? versions.active
            more.append(.item(MenuItem(title: "Follow latest", subtitle: following, confirm: "Everyone opens \(newest)") {
                change(.latest, "Following latest: \(newest) is live")
                return true
            }))
        } else {
            more.append(.button("Follow latest", subtitle: following, checked: true) {})
        }
        return .sections([.header(header)] + list, more)
    }

    /// Releases, newest first, each one a roll back away; what the live
    /// release locked that has moved on, and taking it with the same page.
    private static func history(_ versions: AppVersions, change: @escaping (AppLiveTarget, _ done: String) -> Void) -> [MenuEntry] {
        let releases: [MenuEntry] = versions.releases.map { release in
            let title = "\(release.id) · \(release.version)"
            let when = release.createdAt.map { Formatting.relative($0) }
            if release.id == versions.release {
                return .button(title, detail: "live", checked: true) {}
            }
            return .item(MenuItem(title: title, confirm: "Everyone opens \(release.version)", detail: when) {
                change(.release(release.id), "\(release.id) is live: everyone opens \(release.version)")
                return true
            })
        }
        guard let release = versions.release, !versions.behind.isEmpty else { return [.header("Releases")] + releases }
        let changed: [MenuEntry] = versions.behind.map { drift in
            .view(AnyView(DriftLine(drift: drift)))
        }
        let take = MenuEntry.item(MenuItem(title: "Use these with \(versions.active)",
                                           confirm: "Everyone gets them with \(versions.active)") {
            change(.version(versions.active), "\(versions.active) uses the workflows as they are now")
            return true
        })
        return .sections([.header("Releases")] + releases, [.header("Changed since \(release)")] + changed + [take])
    }

    private static func detail(_ version: AppVersions.Version, in versions: AppVersions) -> String? {
        let when = version.createdAt.map { Formatting.relative($0) }
        let state = version.label == versions.active ? "live" : versions.isWaiting(version.label) ? "waiting" : nil
        let parts = [state, when].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The newest versions the menu lists; older ones are a rollback away
    /// in History or strut's UI.
    private static let listed = 6
}

/// One workflow or step the live release locked that has moved on: its name
/// and `v14 → v17`.
private struct DriftLine: View {
    let drift: AppVersions.Drift
    /// In a menu, under its rows' titles; in a panel, none.
    var inMenu = true

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(drift.name).lineLimit(1)
            Spacer(minLength: Theme.Space.lg)
            Text("\(drift.locked) → \(drift.current ?? "gone")")
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
        .font(Theme.font(12))
        .padding(.horizontal, inMenu ? Theme.Space.sm : 0)
        .padding(.leading, inMenu ? 25 : 0)
        .frame(height: 24)
    }
}

/// "Make v9 live?": what changes for everyone, asked once before strut
/// takes the release.
private struct MakeLivePanel: View {
    let title: String
    let version: String
    let versions: AppVersions
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        Panel("Make \(version) live?", compact: true, close: cancel) {
            Text("Everyone who opens \(title) gets \(version) instead of \(versions.active): its tab, links to it, and apps that import it.")
                .fixedSize(horizontal: false, vertical: true)
            // Any pick holds the app (strut's plans/app-releases.md §1.2).
            if !versions.held {
                Text("From now on, new versions wait here until you make them live.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !versions.behind.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Workflows that changed since \(versions.release ?? "") go with it:")
                        .muted()
                    ForEach(versions.behind, id: \.name) { DriftLine(drift: $0, inMenu: false) }
                }
            }
            Text("The workflows it calls are kept as they are now. You can roll back from History.")
                .muted()
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            FormFooter(problem: nil) {
                Button("Cancel", action: cancel).buttonStyle(.peel(.outline, size: .sm))
                Button("Make \(version) live", action: confirm).buttonStyle(.peel(.primary, size: .sm))
            }
        }
    }
}

/// Under the header while this window shows a version other than the live
/// one: who sees what, and the way back.
struct AppPreviewBar: View {
    let shown: String
    let live: String
    let back: () -> Void

    var body: some View {
        Callout(.attention, "Only you see \(shown). Everyone else opens \(live).",
                detail: "Runs you start here use the workflows as they are now.",
                icon: .symbol("eye", Theme.attention)) {
            Button("Back to \(live)", action: back).buttonStyle(.peel(.outline, size: .sm))
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, 6)
    }
}
