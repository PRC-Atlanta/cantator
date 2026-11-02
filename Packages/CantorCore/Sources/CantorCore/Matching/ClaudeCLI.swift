import Darwin
import Foundation
import Synchronization

/// What LLMTiebreaker needs from Claude. Tests use a fake, so they never start a real process.
public protocol ClaudeRunner: Sendable {
    func run(system: String, prompt: String, schema: String, model: String) async throws -> Data
}

public struct ClaudeAccountStatus: Equatable, Sendable {
    public var isLoggedIn: Bool
    public var authMethod: String

    /// True when requests would be billed to an API key instead of the Claude account.
    public var usesAPIKey: Bool { authMethod.lowercased().contains("api") }
}

/// Runs the operator's own installed Claude Code in headless mode, so requests use the Claude
/// account it is signed in to. API credentials are removed from its environment, and it runs with
/// no tools, no settings and no MCP servers, from an empty folder.
public struct ClaudeCLI: ClaudeRunner {
    public static let timeout: TimeInterval = 120
    static let apiVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]

    public var path: String

    public init(path: String) {
        self.path = path
    }

    /// A GUI app does not inherit the shell's PATH, so the usual install locations are checked.
    public static func locate(override: String = "") -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [override, "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func arguments(system: String, schema: String, model: String) -> [String] {
        var arguments = [
            "-p", "--output-format", "json", "--json-schema", schema, "--system-prompt", system,
            "--tools", "", "--effort", "low", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
        ]
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    static func environment(from base: [String: String]) -> [String: String] {
        base.filter { !apiVariables.contains($0.key) }
    }

    public func run(system: String, prompt: String, schema: String, model: String) async throws -> Data {
        try await execute(arguments: Self.arguments(system: system, schema: schema, model: model), input: prompt)
    }

    public func accountStatus() async throws -> ClaudeAccountStatus {
        let data = try await execute(arguments: ["auth", "status"], input: "")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed }
        return ClaudeAccountStatus(
            isLoggedIn: root["loggedIn"] as? Bool ?? false, authMethod: root["authMethod"] as? String ?? "none"
        )
    }

    private func execute(arguments: [String], input: String) async throws -> Data {
        let path = self.path
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = Self.environment(from: ProcessInfo.processInfo.environment)
            process.currentDirectoryURL = try Self.emptyDirectory()

            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            // If the process exits early, a write must fail rather than raise SIGPIPE in the app.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

            do {
                try process.run()
            } catch {
                throw LLMError.notInstalled
            }

            let timedOut = Mutex(false)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) {
                guard process.isRunning else { return }
                timedOut.withLock { $0 = true }
                process.terminate()
            }

            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()

            if timedOut.withLock({ $0 }) { throw LLMError.timedOut }
            // A failed request still prints a JSON result with the reason, so that is what gets read.
            if output.isEmpty, process.terminationStatus != 0 {
                throw LLMError.failed("Claude Code exited with status \(process.terminationStatus).")
            }
            return output
        }.value
    }

    /// Reads Claude Code's JSON result. A failed request reports `is_error` with a reason in `result`.
    public static func structuredOutput(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed }
        if root["is_error"] as? Bool == true {
            let message = root["result"] as? String ?? ""
            let lowered = message.lowercased()
            if lowered.contains("not logged in") || lowered.contains("/login") { throw LLMError.notLoggedIn }
            if lowered.contains("limit") { throw LLMError.limitReached }
            throw LLMError.failed(message)
        }
        if let structured = root["structured_output"] as? [String: Any] { return structured }
        if let text = root["result"] as? String,
           let structured = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return structured
        }
        throw LLMError.malformed
    }

    private static func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cantor-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
