import CoreLocation
import OSLog
import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// Asks the system for Peel's location permission on behalf of a page the
/// person allowed (`PageLocation`). Made only when a page asks, never at
/// launch. Peel never reads a position: WebKit does, for the one page, and
/// only for as long as it is open. No background updates, no Always.
@MainActor
final class PageLocationAuthorizer: NSObject, CLLocationManagerDelegate {
    enum Outcome: Equatable {
        case granted
        /// The person (or a restriction) turned location off for Peel: not asked
        /// again; Settings is the way back.
        case denied
    }

    static let log = Logger(subsystem: "dev.peel.ios", category: "page-location")
    /// The purpose key in Info.plist's `NSLocationTemporaryUsageDescriptionDictionary`.
    static let preciseKey = "PagePrecise"

    private var manager: CLLocationManager?
    private var waiting: CheckedContinuation<Void, Never>?

    /// Makes sure the system lets Peel's pages have a location: asks once
    /// when undecided, and, when `precise` and only approximate is allowed,
    /// asks for full accuracy for this visit.
    func authorize(precise: Bool) async -> Outcome {
        let manager = self.manager ?? makeManager()
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                waiting = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return .denied
        }
        if precise, manager.accuracyAuthorization == .reducedAccuracy {
            await withCheckedContinuation { continuation in
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.preciseKey) { _ in
                    continuation.resume()
                }
            }
        }
        let accuracy = manager.accuracyAuthorization == .fullAccuracy ? "precise" : "approximate"
        Self.log.info("system location allowed, accuracy \(accuracy, privacy: .public)")
        return .granted
    }

    private func makeManager() -> CLLocationManager {
        let manager = CLLocationManager()
        manager.delegate = self
        self.manager = manager
        return manager
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            waiting?.resume()
            waiting = nil
        }
    }

    /// Where the person turns location back on for Peel.
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// What the page sheet's location prompt and notices show, one at a time,
/// like `PhoneWalletSheets`.
@MainActor @Observable
final class PageLocationPrompts {
    struct Ask: Identifiable {
        let id = UUID()
        let host: String
    }

    struct Answer: Sendable {
        var allowed = false
        var remember = false
        var precise = false
    }

    var asking: Ask?
    /// The host whose request found location off for Peel.
    var deniedBySystem: String?
    /// Allowed once for this sheet: not kept.
    @ObservationIgnored var allowedOnce: Set<String> = []
    @ObservationIgnored private var waiting: CheckedContinuation<Answer, Never>?

    func ask(host: String) async -> Answer {
        guard waiting == nil, !Task.isCancelled else { return Answer() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                asking = Ask(host: host)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(Answer()) }
        }
    }

    func answer(_ answer: Answer) {
        asking = nil
        waiting?.resume(returning: answer)
        waiting = nil
    }
}

/// Peel's own question, before the system's: who is asking, what they get,
/// and Precise, off unless the person turns it on.
struct PageLocationPromptSheet: View {
    let host: String
    let done: (PageLocationPrompts.Answer) -> Void
    @State private var precise = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only this site gets it, only while its page is open. Peel doesn't keep or send it.")
                        .foregroundStyle(Theme.secondaryText)
                    Toggle("Precise location", isOn: $precise)
                }
                Section {
                    Button("Allow") { done(.init(allowed: true, remember: true, precise: precise)) }
                    Button("Allow once") { done(.init(allowed: true, remember: false, precise: precise)) }
                    Button("Don't allow", role: .cancel) { done(.init(allowed: false, remember: true)) }
                }
            }
            .navigationTitle("\(host) wants your location")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

/// You › Site location: each site's decision, changed or forgotten.
struct SiteLocationScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForgetAll = false

    var body: some View {
        List {
            if model.siteLocations.isEmpty {
                Text("A site that asks for your location appears here once you decide.")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(model.siteLocations) { grant in
                NavigationLink {
                    SiteLocationDetail(origin: grant.origin)
                } label: {
                    LabeledContent(host(of: grant.origin), value: PageLocation.summary(grant))
                }
            }
            Section {
                if !model.siteLocations.isEmpty {
                    Button("Forget all sites", role: .destructive) { confirmingForgetAll = true }
                }
                Button("Phone location settings") { PageLocationAuthorizer.openSettings() }
            } footer: {
                Text("On iOS 26, sites are asked by the system's own prompt and are not listed here.")
            }
        }
        .navigationTitle("Site location")
        .confirmationDialog("Forget every site's choice?", isPresented: $confirmingForgetAll, titleVisibility: .visible) {
            Button("Forget all sites", role: .destructive) { model.forgetAllSiteLocations() }
        }
    }

    private func host(of origin: String) -> String { URL(string: origin)?.host() ?? origin }
}

private struct SiteLocationDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let origin: String

    var body: some View {
        let grant = model.siteLocations.first { $0.origin == origin }
        List {
            if let grant {
                Section(URL(string: origin)?.host() ?? origin) {
                    Picker("Location", selection: Binding(
                        get: { grant.allowed }, set: { model.updateSiteLocation(grant, allowed: $0) }
                    )) {
                        Text("Allow").tag(true)
                        Text("Block").tag(false)
                    }
                    if grant.allowed {
                        Toggle("Precise location", isOn: Binding(
                            get: { grant.precise }, set: { model.updateSiteLocation(grant, precise: $0) }
                        ))
                    }
                }
                Section {
                    Button("Remove", role: .destructive) {
                        model.removeSiteLocation(origin)
                        dismiss()
                    }
                } footer: {
                    Text("Removed, the site asks again next time.")
                }
            }
        }
        .navigationTitle("Site location")
        .navigationBarTitleDisplayMode(.inline)
    }
}
