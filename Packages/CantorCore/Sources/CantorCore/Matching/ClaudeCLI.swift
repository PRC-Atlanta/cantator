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
    /// After SIGTERM, how long Claude Code gets to exit before SIGKILL.
    static let killGraceSec: TimeInterval = 3
    /// After the process exits, how long to wait for the rest of its output. A child process it
    /// left behind can hold the pipe open, so the wait is bounded.
    static let drainGraceSec: TimeInterval = 2
    /// Every ANTHROPIC_ variable is removed (keys, tokens, base URL, model, headers), plus these,
    /// which send requests through another provider instead of the Claude account.
    static let apiVariables: Set<String> = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
        "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH", "AWS_BEARER_TOKEN_BEDROCK", "CLOUD_ML_REGION",
    ]
    /// Phrases Claude Code uses when the account's usage limit is reached. A bare "limit" would
    /// also catch context and token limits, which waiting does not fix.
    static let usageLimitPhrases = ["usage limit", "rate limit", "hit your limit", "weekly limit", "hour limit", "session limit"]

    public var path: String
    public var timeout: TimeInterval

    public init(path: String, timeout: TimeInterval = ClaudeCLI.timeout) {
        self.path = path
        self.timeout = timeout
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
        base.filter { !$0.key.hasPrefix("ANTHROPIC_") && !apiVariables.contains($0.key) }
    }

    public func run(system: String, prompt: String, schema: String, model: String) async throws -> Data {
        try await execute(arguments: Self.arguments(system: system, schema: schema, model: model), input: prompt)
    }

    /// Runs Claude Code with no built-in tools and only `allowedTools` from its MCP servers, which
    /// include the connectors on the signed-in Claude account. Returns the stream-json events, so
    /// the caller reads each tool's own result rather than Claude's retelling of it.
    public func runWithTools(system: String, prompt: String, allowedTools: [String], disallowedTools: [String], model: String) async throws -> Data {
        try await execute(
            arguments: Self.toolArguments(system: system, allowedTools: allowedTools, disallowedTools: disallowedTools, model: model),
            input: prompt
        )
    }

    static func toolArguments(system: String, allowedTools: [String], disallowedTools: [String], model: String) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--system-prompt", system,
            "--tools", "", "--allowedTools", allowedTools.joined(separator: ","), "--effort", "low",
            "--no-session-persistence", "--setting-sources", "",
        ]
        if !disallowedTools.isEmpty { arguments += ["--disallowedTools", disallowedTools.joined(separator: ",")] }
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    /// The MCP servers Claude Code can reach, including Claude account connectors, as `claude mcp list` prints them.
    public func mcpServers() async throws -> [MCPServerStatus] {
        MCPServerStatus.parse(String(decoding: try await execute(arguments: ["mcp", "list"], input: ""), as: UTF8.self))
    }

    public func accountStatus() async throws -> ClaudeAccountStatus {
        let data = try await execute(arguments: ["auth", "status"], input: "")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed }
        return ClaudeAccountStatus(
            isLoggedIn: root["loggedIn"] as? Bool ?? false, authMethod: root["authMethod"] as? String ?? "none"
        )
    }

    /// Runs on a plain dispatch thread, since it blocks while Claude Code works. It always returns:
    /// a hung process gets SIGTERM at the timeout and SIGKILL shortly after.
    private func execute(arguments: [String], input: String) async throws -> Data {
        let path = self.path, timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(path: path, arguments: arguments, input: input, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(path: String, arguments: [String], input: String, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = try emptyDirectory()

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // If the process exits early, a write must fail rather than raise SIGPIPE in the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // Output is collected as it arrives, so nothing waits on a pipe another process may hold open.
        let output = Mutex(Data())
        let ended = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            } else {
                output.withLock { $0.append(chunk) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw LLMError.notInstalled
        }

        // A process that never reads stdin must not block this thread either.
        let writer = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGraceSec) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGraceSec)
            }
        }
        _ = ended.wait(timeout: .now() + drainGraceSec)
        stdout.fileHandleForReading.readabilityHandler = nil
        let data = output.withLock { $0 }

        if timedOut || process.isRunning { throw LLMError.timedOut }
        // A failed request still prints a JSON result with the reason, so that is what gets read.
        if data.isEmpty, process.terminationStatus != 0 {
            throw LLMError.failed("Claude Code exited with status \(process.terminationStatus).")
        }
        return data
    }

    /// Reads Claude Code's JSON result. A failed request reports `is_error` with a reason in `result`.
    public static func structuredOutput(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed }
        if root["is_error"] as? Bool == true { throw failure(root["result"] as? String ?? "") }
        if let structured = root["structured_output"] as? [String: Any] { return structured }
        if let text = root["result"] as? String,
           let structured = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return structured
        }
        throw LLMError.malformed
    }

    /// The error for a failed request's reason, as Claude Code words it.
    static func failure(_ message: String) -> LLMError {
        let lowered = message.lowercased()
        if lowered.contains("not logged in") || lowered.contains("/login") { return .notLoggedIn }
        if usageLimitPhrases.contains(where: lowered.contains) || (lowered.contains("limit reached") && !lowered.contains("context")
            && !lowered.contains("token")) {
            return .limitReached
        }
        return .failed(message)
    }

    private static func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cantor-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One line of `claude mcp list`, such as "claude.ai Planning Center: https://mcp.planningcenteronline.com/mcp - ✓ Connected".
public struct MCPServerStatus: Equatable, Sendable {
    public var name: String
    public var address: String
    public var isConnected: Bool
    public var needsAuthentication: Bool

    static func parse(_ text: String) -> [MCPServerStatus] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            guard let separator = line.range(of: ": ") else { return nil }
            let name = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[separator.upperBound...])
            let status = rest.range(of: " - ", options: .backwards)
            let address = String(status.map { rest[..<$0.lowerBound] } ?? rest[...]).trimmingCharacters(in: .whitespaces)
            let state = status.map { String(rest[$0.upperBound...]).lowercased() } ?? ""
            guard !name.isEmpty, !address.isEmpty else { return nil }
            return MCPServerStatus(
                name: name, address: address, isConnected: state.contains("connected") && !state.contains("failed"),
                needsAuthentication: state.contains("auth")
            )
        }
    }
}
