import Foundation
import PeelCore
import SwiftUI

// What the Mac's conversation and the iPhone's share beside the rows
// (`ChatRow`): the words beside Retry, the schedule a row redraws on, and
// the way a quote goes to what it quotes.

extension Message {
    /// "Not delivered", "Not uploaded", "Boost of 21 sats not sent" or
    /// "Not sent", beside Retry and Discard. An attachment the memes server
    /// never got says so, as the Mac app.
    public var undeliveredLabel: String {
        if uploadState == .failed { return "Not uploaded" }
        guard MessageType.payments.contains(type) else { return "Not delivered" }
        if type == MessageType.boost, let msat = amountMsat {
            return "Boost of \(Sats.format(msat: msat)) not sent"
        }
        return "Not sent"
    }
}

extension TimelineSchedule where Self == ExplicitTimelineSchedule<[Date]> {
    /// Draws now and again at `date`. `.now` comes first because, before
    /// its first entry, a timeline draws with that entry's date: a lone
    /// future date reads as already passed. A date already passed is left
    /// out: entries must not go back in time, or the timeline redraws on
    /// every frame for as long as it is on screen.
    public static func redrawing(at date: Date?) -> Self {
        let now = Date.now
        return .explicit([now] + [date].compactMap { $0 }.filter { $0 > now })
    }
}

extension EnvironmentValues {
    /// From a quote to the message it quotes, in the list it sits in. Set
    /// by the message list on every redraw, so it looks in the rows of now
    /// while the rows themselves (`Equatable`) stay as drawn.
    @Entry public var goToMessage: @MainActor @Sendable (Message) -> Void = { _ in }
}
