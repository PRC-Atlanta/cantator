import Darwin
import Foundation
import Synchronization

/// FFmpeg, when the operator has installed it, for imports macOS can't read. Cantator never
/// ships it. It runs sandboxed: no network, no system services, no other programs, and file
/// writes only in its own temporary folder.
public enum FFmpeg {
    /// Offered by the open panel. Without FFmpeg, these are refused with a note that it is needed.
    public static let extensions = [
        "mkv", "mka", "avi", "webm", "ogg", "oga", "opus", "wma", "wmv", "flv", "ape", "wv", "ac3", "dts", "mpg", "mpeg", "ts", "3gp",
    ]
    static let timeoutSec: TimeInterval = 600
    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// A GUI app does not inherit the shell's PATH, so the usual install locations are checked.
    public static func locate() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Writes the source's first audio track to a FLAC in a new temporary folder and returns it.
    /// FLAC is lossless, so nothing is lost before Apple's encoder makes the m4a. The caller
    /// removes the folder.
    static func extractAudio(from source: URL, ffmpeg: String, progress: Importer.Progress? = nil) throws -> URL {
        let name = source.lastPathComponent
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("cantor-ffmpeg-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw ImportError.failed(name, error.localizedDescription)
        }
        // The sandbox matches resolved paths, as in /private/var.
        let folder = URL(fileURLWithPath: realpath(base.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        } ?? base.path, isDirectory: true)
        let output = folder.appendingPathComponent("audio.flac")
        let log = folder.appendingPathComponent("ffmpeg.log")

        let process = Process()
        let ffmpegArguments = arguments(source: source.path, output: output.path)
        if FileManager.default.isExecutableFile(atPath: sandboxExec) {
            process.executableURL = URL(fileURLWithPath: sandboxExec)
            process.arguments = ["-p", sandboxProfile(writableFolder: folder.path, executable: ffmpeg), ffmpeg] + ffmpegArguments
        } else {
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ffmpegArguments
        }
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        // The log goes to a file, so a chatty run can never fill a pipe and stall.
        manager.createFile(atPath: log.path, contents: nil)
        process.standardError = try? FileHandle(forWritingTo: log)

        // Progress lines arrive on stdout. The total length is in the log, near the start.
        let stdout = Pipe()
        process.standardOutput = stdout
        let reading = Mutex(ProgressReading())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let progress else { return }
            reading.withLock { state in
                state.pending += String(decoding: chunk, as: UTF8.self)
                while let newline = state.pending.firstIndex(of: "\n") {
                    let line = String(state.pending[..<newline])
                    state.pending.removeSubrange(...newline)
                    guard line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) else { continue }
                    if state.durationSec == nil {
                        state.durationSec = duration(inLog: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
                    }
                    if let total = state.durationSec, total > 0 { state.throttle.report(micros / 1_000_000 / total, to: progress) }
                }
            }
        }
        defer { stdout.fileHandleForReading.readabilityHandler = nil }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? manager.removeItem(at: folder)
            throw ImportError.needsFFmpeg(name)
        }
        if exited.wait(timeout: .now() + timeoutSec) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            try? manager.removeItem(at: folder)
            throw ImportError.failed(name, "FFmpeg took longer than \(Int(timeoutSec / 60)) minutes")
        }
        guard process.terminationStatus == 0, manager.fileExists(atPath: output.path) else {
            // Each log line starts with its level, so the errors can be told from the information.
            let errors = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .filter { $0.hasPrefix("[error]") || $0.hasPrefix("[fatal]") || $0.hasPrefix("[panic]") }
                .map { $0.drop { $0 != "]" }.dropFirst().trimmingCharacters(in: .whitespaces) }
            try? manager.removeItem(at: folder)
            if errors.contains(where: { $0.contains("matches no streams") }) { throw ImportError.noAudio(name) }
            if errors.contains(where: { $0.contains("Invalid data found") }) { throw ImportError.unsupported(name) }
            throw ImportError.failed(name, errors.last ?? "FFmpeg exited with status \(process.terminationStatus)")
        }
        return output
    }

    private struct ProgressReading {
        var pending = ""
        var durationSec: Double?
        var throttle = Importer.ProgressThrottle()
    }

    /// The input's length from a line such as "[info]   Duration: 00:03:12.34, start: 0.000000".
    /// Nil until that line is written, or when FFmpeg reports N/A.
    static func duration(inLog log: String) -> Double? {
        guard let range = log.range(of: "Duration: ") else { return nil }
        let parts = log[range.upperBound...].prefix { $0 != "," }.split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func arguments(source: String, output: String) -> [String] {
        [
            "-nostdin", "-hide_banner", "-loglevel", "level+info", "-nostats", "-progress", "pipe:1",
            // Without "file:", a name such as "concat:..." or "http:..." would be read as a protocol.
            "-i", "file:" + source,
            "-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "0",
            "-c:a", "flac", "-sample_fmt", "s32",
            "file:" + output,
        ]
    }

    /// Reading files is allowed, so FFmpeg can load its libraries and the source. Denied: the
    /// network; writing outside `writableFolder`; Mach services, which would otherwise let it write
    /// preferences through cfprefsd, send Apple Events or open apps through LaunchServices; and
    /// starting any program but `executable`.
    static func sandboxProfile(writableFolder: String, executable: String) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Homebrew's ffmpeg is a link into its Cellar, and the check sees the resolved path.
        let resolved = realpath(executable, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        } ?? executable
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath \(quoted(writableFolder))) (literal "/dev/null") (literal "/dev/dtracehelper"))
        (deny mach-lookup)
        (deny appleevent-send)
        (deny process-fork)
        (deny process-exec)
        (allow process-exec (literal \(quoted(executable))) (literal \(quoted(resolved))))
        """
    }
}
