import Darwin
import Foundation

/// FFmpeg, when the operator has installed it, for imports macOS can't read. Cantator never
/// ships it. It runs sandboxed: no network, and writes only to its own temporary folder.
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
    static func extractAudio(from source: URL, ffmpeg: String) throws -> URL {
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
            process.arguments = ["-p", sandboxProfile(writableFolder: folder.path), ffmpeg] + ffmpegArguments
        } else {
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ffmpegArguments
        }
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Errors go to a file, so a chatty run can never fill a pipe and stall.
        manager.createFile(atPath: log.path, contents: nil)
        process.standardError = try? FileHandle(forWritingTo: log)

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
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            try? manager.removeItem(at: folder)
            if text.contains("matches no streams") { throw ImportError.noAudio(name) }
            if text.contains("Invalid data found") { throw ImportError.unsupported(name) }
            let reason = text.split(separator: "\n").last.map(String.init) ?? "FFmpeg exited with status \(process.terminationStatus)"
            throw ImportError.failed(name, reason)
        }
        return output
    }

    static func arguments(source: String, output: String) -> [String] {
        [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            // Without "file:", a name such as "concat:..." or "http:..." would be read as a protocol.
            "-i", "file:" + source,
            "-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "0",
            "-c:a", "flac", "-sample_fmt", "s32",
            "file:" + output,
        ]
    }

    /// Everything is allowed except the network and writing outside `writableFolder`.
    static func sandboxProfile(writableFolder: String) -> String {
        let folder = writableFolder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath "\(folder)") (literal "/dev/null") (literal "/dev/dtracehelper"))
        """
    }
}
