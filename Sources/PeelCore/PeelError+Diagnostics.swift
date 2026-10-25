import Foundation
import GRDB
import MQTTNIO
import Network
import NIOCore
import PeelDiagnostics
import Sphinxrs

extension PeelError {
    /// The kind of an error, for the diagnostics ring: the same split as
    /// `readable`, and never its words (the ring keeps no free text).
    public static func diagnosticKind(_ error: any Error) -> DiagnosticEvent.ErrorKind {
        switch error {
        case is DatabaseError, is RowDecodingError, is PersistenceError: return .database
        case let error as URLError:
            switch error.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return .secureConnection
            case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData, .zeroByteResource:
                return .server
            case .cancelled: return .cancelled
            default: return .network
            }
        case let error as CocoaError:
            return error.code == .userCancelled ? .cancelled : .file
        case let error as POSIXError:
            switch error.code {
            case .ENOENT, .EACCES, .ENOSPC: return .file
            default: return .network
            }
        case let error as NWError:
            if case .tls = error { return .secureConnection }
            return .network
        case is MQTTError, is ChannelError: return .connection
        case is DecodingError: return .decoding
        case is CancellationError: return .cancelled
        case is SphinxError: return .core
        case let failure as Engine.Failure:
            switch failure {
            case .noServer, .notConnected, .connectionDropped, .registrationTimedOut: return .connection
            default: return .engine
            }
        case is PeelError: return .engine
        default: return .other
        }
    }

    /// `problem(_:couldNot:)` for a failure the person is about to be told
    /// of: the kind goes into the diagnostics ring first (the message does
    /// not). Every notice built from an error goes through this.
    public static func noted(_ error: any Error, couldNot action: String? = nil) -> String {
        Diagnostics.note(error: error)
        return problem(error, couldNot: action)
    }
}

extension Diagnostics {
    /// Notes an error by its kind, never its message.
    public static func note(error: any Error) {
        note(errorKind: PeelError.diagnosticKind(error))
    }
}
