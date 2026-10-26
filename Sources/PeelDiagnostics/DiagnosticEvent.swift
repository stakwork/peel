import Foundation

/// One entry in the event ring. Only enums and numbers: there is no String
/// field, so nothing a person wrote, no error message, path, name or key can
/// be stored here, however a caller is written. That is the privacy
/// guarantee for the ring (docs/diagnostics.md); keep it when adding a field.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case error, memorySample, memoryPressure, launch, previousRun, strutExit
    }

    /// The kinds of failure Peel shows a notice for, as `PeelError.readable`
    /// tells them apart; the words themselves are never kept.
    public enum ErrorKind: String, Codable, Sendable, CaseIterable {
        case database, network, connection, server, secureConnection, file, cancelled
        case core, decoding, engine, call, refused, other
    }

    /// What the person had just asked Peel to do.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case tribeJoin, send, sync, launch, other
    }

    public enum PressureLevel: String, Codable, Sendable, CaseIterable {
        case warning, critical
    }

    public enum ExitReason: String, Codable, Sendable, CaseIterable {
        case exit, uncaughtSignal
    }

    /// How the previous run ended (`PreviousRun`, without a report's id).
    public enum PreviousRunKind: String, Codable, Sendable, CaseIterable {
        case clean, crashed, killedForeground, killedBackground, unknown
    }

    public var kind: Kind
    public var timestamp: Date
    public var count: Int
    public var errorKind: ErrorKind?
    public var lastAction: Action?
    public var footprintBytes: UInt64?
    public var availableBytes: UInt64?
    public var pressureLevel: PressureLevel?
    public var previousRun: PreviousRunKind?
    public var exitReason: ExitReason?
    public var exitStatus: Int32?

    public init(
        kind: Kind, timestamp: Date = Date(), count: Int = 1, errorKind: ErrorKind? = nil,
        lastAction: Action? = nil, footprintBytes: UInt64? = nil, availableBytes: UInt64? = nil,
        pressureLevel: PressureLevel? = nil, previousRun: PreviousRunKind? = nil,
        exitReason: ExitReason? = nil, exitStatus: Int32? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.count = count
        self.errorKind = errorKind
        self.lastAction = lastAction
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
        self.pressureLevel = pressureLevel
        self.previousRun = previousRun
        self.exitReason = exitReason
        self.exitStatus = exitStatus
    }

    /// Whether `other` is the same event again (everything but when, and
    /// how often), so the ring counts it instead of writing it twice.
    func repeats(_ other: DiagnosticEvent) -> Bool {
        var copy = other
        copy.timestamp = timestamp
        copy.count = count
        return copy == self
    }
}
