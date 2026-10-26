#if canImport(CrashReporter)
import CrashReporter
import Foundation

/// Moves PLCrashReporter's pending report into Peel's private raw folder.
/// This file and `CrashRecorder` are the only code that touches the library.
enum PendingReport {
    /// The id of the record made from the pending report (its bytes kept whole
    /// beside it), or nil when there was none. The pending report is purged.
    static func collect(from reporter: PLCrashReporter, into store: DiagnosticsStore, events: [DiagnosticEvent]) -> String? {
        guard reporter.hasPendingCrashReport() else { return nil }
        defer { reporter.purgePendingCrashReport() }
        guard let data = try? reporter.loadPendingCrashReportDataAndReturnError() else { return nil }
        let id = UUID().uuidString
        var record = (try? PLCrashReport(data: data)).map { CrashRecord(report: $0, id: id) }
            ?? CrashRecord(id: id, threads: [], images: [], events: [])
        record.events = events
        record.strutStderrTail = store.strutTail()
        do { try store.saveRaw(record, report: data) } catch { return nil }
        return id
    }
}

extension CrashRecord {
    init(report: PLCrashReport, id: String) {
        self.init(id: id, threads: [], images: [], events: [])
        appIdentifier = report.applicationInfo?.applicationIdentifier
        appVersion = report.applicationInfo?.applicationVersion
        osVersion = report.systemInfo?.operatingSystemVersion
        osBuild = report.systemInfo?.operatingSystemBuild
        timestamp = report.systemInfo?.timestamp
        if report.hasMachineInfo { machineModel = report.machineInfo?.modelName }
        if report.hasProcessInfo {
            processName = report.processInfo?.processName
            processPath = report.processInfo?.processPath
        }
        if let signalInfo = report.signalInfo {
            signal = signalInfo.name
            signalCode = signalInfo.code
            faultAddress = signalInfo.address
        }
        if let mach = report.machExceptionInfo {
            machException = Self.machName(mach.type)
        }
        if report.hasExceptionInfo, let exception = report.exceptionInfo {
            exceptionName = exception.exceptionName
            exceptionReason = exception.exceptionReason
        }
        images = (report.images as? [PLCrashReportBinaryImageInfo] ?? []).map { image in
            Image(name: image.imageName ?? "", uuid: image.hasImageUUID ? image.imageUUID : nil,
                  base: image.imageBaseAddress, size: image.imageSize, arch: Self.arch(image.codeType))
        }
        threads = (report.threads as? [PLCrashReportThreadInfo] ?? []).map { thread in
            Thread(
                number: Int(thread.threadNumber), crashed: thread.crashed,
                frames: (thread.stackFrames as? [PLCrashReportStackFrameInfo] ?? []).map { frame in
                    let pc = frame.instructionPointer
                    let image = images.first { pc >= $0.base && pc < $0.base &+ $0.size }
                    return Frame(pc: pc, imageName: image?.name, symbol: frame.symbolInfo?.symbolName,
                                 offset: frame.symbolInfo.map { pc &- $0.startAddress })
                },
                registers: (thread.registers as? [PLCrashReportRegisterInfo] ?? []).map {
                    Register(name: $0.registerName, value: $0.registerValue)
                })
        }
    }

    private static func arch(_ type: PLCrashReportProcessorInfo?) -> String? {
        guard let type else { return nil }
        // CPU_TYPE_ARM64 and CPU_TYPE_X86_64, as Apple's logs name them.
        switch type.type {
        case 0x0100_000C: return "arm64"
        case 0x0100_0007: return "x86_64"
        default: return nil
        }
    }

    private static func machName(_ type: UInt64) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 4: "EXC_EMULATION"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 7: "EXC_SYSCALL"
        case 8: "EXC_MACH_SYSCALL"
        case 9: "EXC_RPC_ALERT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "EXC_\(type)"
        }
    }
}
#endif
