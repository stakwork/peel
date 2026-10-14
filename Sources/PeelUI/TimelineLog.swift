import CryptoKit
import Foundation
import os
import SwiftUI

/// Opt-in diagnostics for the message list's placement (a blank list on
/// opening until a scroll): where it went, by which path, and what its
/// scroll geometry and visible rows were. Off unless
/// `defaults write dev.peel.mac PeelTimelineLog -bool YES`, read once at
/// launch, and then nothing extra is observed or built. Lines carry only
/// numbers, row indices, path names and a short hash of the chat: never
/// message text, names, keys, ids or amounts. How to capture it:
/// `docs/testing.md`, "Timeline log".
public enum TimelineLog {
    public static let enabled = UserDefaults.standard.bool(forKey: "PeelTimelineLog")
    private static let logger = Logger(subsystem: "dev.peel.mac", category: "timeline")

    /// Built only when enabled. Public: the line holds nothing private.
    public static func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = line()
        logger.debug("\(text, privacy: .public)")
    }

    /// A key made at launch, so a chat's tag cannot be matched to it from
    /// outside this run.
    private static let salt = SymmetricKey(size: .bits128)

    /// A chat named by six hex characters of a keyed hash of its key: one
    /// chat's lines can be told from another's within a run, and the key
    /// is neither written nor recoverable from a pasted log.
    public static func tag(_ chat: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(chat.utf8), using: salt)
            .prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// A list's composer: the chat, a thread in it, or the agent chat.
    public static func tag(_ composer: ComposerID) -> String {
        guard let chat = composer.chat else { return "agent" }
        return composer.thread == nil ? tag(chat) : "\(tag(chat))/thread"
    }

    /// One decimal place, enough for points.
    public static func points(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

extension View {
    /// With the timeline log on, reports the list's whole scroll geometry and
    /// which rows are in view; off, the view as it is.
    @ViewBuilder
    public func timelineProbe(geometry: @escaping (ScrollGeometry) -> Void,
                       visible: @escaping ([String]) -> Void) -> some View {
        if TimelineLog.enabled {
            self
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in geometry(new) }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01, visible)
        } else {
            self
        }
    }
}
