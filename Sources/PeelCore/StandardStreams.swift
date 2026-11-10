import Darwin
import PeelDiagnostics

/// The process's stdout and stderr, which the core writes its logs to. Rust's `println!` and
/// `eprintln!` panic when the write fails, so a stream gone bad (a terminal or debugger pipe whose
/// other end went, as Xcode's does after a long suspension: EIO) fails every core call
/// ("failed printing to stderr: Input/output error (os error 5)") until the app is relaunched.
/// The engine points both at /dev/null when it sees it, and the call goes through again.
enum StandardStreams {
    /// Whether `error` is the core's panic on a stream it could not write to.
    static func isBroken(_ error: any Error) -> Bool {
        let text = String(describing: error) + PeelError.readable(error)
        return text.contains("failed printing to std")
    }

    /// Points stdout and stderr at /dev/null; whether both took.
    @discardableResult
    static func repair() -> Bool {
        let null = open("/dev/null", O_WRONLY)
        guard null >= 0 else { return false }
        defer { close(null) }
        let repaired = dup2(null, STDOUT_FILENO) >= 0 && dup2(null, STDERR_FILENO) >= 0
        Diagnostics.recordCoreRecovery(reason: .brokenStreams, stage: .streams)
        return repaired
    }
}
