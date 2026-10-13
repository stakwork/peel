import Foundation
import Observation

/// One payment from a button: the engine is asked first; over the threshold
/// it answers with the amount, which arms the button (orange, "Boost 150 sats"),
/// and the second click sends exactly that amount (the engine refuses any
/// other). Not twice while one is on its way.
@MainActor @Observable
final class PaymentAttempt {
    /// The amount the engine asked to confirm, once asked.
    var armed: UInt64?
    var working = false
    var problem: String?

    /// Returns whether it was sent.
    func run(_ send: (_ confirmedMsat: UInt64?) async -> PaymentOutcome) async -> Bool {
        guard !working else { return false }
        working = true
        problem = nil
        let outcome = await send(armed)
        working = false
        switch outcome {
        case .sent:
            armed = nil
            return true
        case .needsConfirmation(let msat):
            armed = msat
        case .refused(let reason):
            armed = nil
            problem = reason
        case .busy:
            break
        }
        return false
    }
}
