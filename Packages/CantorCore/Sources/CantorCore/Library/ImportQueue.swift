import Foundation
import Observation

/// Runs imports one file at a time, in the order chosen. Files chosen while others convert join
/// the end. Between files it waits while `canRun` says no, so a queue started before a service
/// never converts while a cue is armed or playing.
@MainActor
@Observable
public final class ImportQueue {
    /// The file being converted, and how far through it is.
    public struct Status: Equatable, Sendable {
        /// New for each file, so a late report from the file before is ignored.
        public var fileID = UUID()
        public var filename: String
        /// Which file this is, counting from 1, out of `total`.
        public var number: Int
        public var total: Int
        public var fraction: Double
        /// Waiting for the show to be idle before starting this file.
        public var paused = false

        public var percent: Int { Int((fraction * 100).rounded(.down)) }
    }

    public typealias Perform = @Sendable (URL, @escaping Importer.Progress) throws -> URL

    public private(set) var status: Status?
    @ObservationIgnored private var waiting: [URL] = []
    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private let perform: Perform
    @ObservationIgnored private let canRun: @MainActor () -> Bool
    @ObservationIgnored private let pollInterval: Duration
    /// Called once the last file is done, with where each import landed and the failures.
    @ObservationIgnored public var onFinished: (@MainActor (_ imported: [URL], _ failures: [String]) -> Void)?
    @ObservationIgnored private var imported: [URL] = []

    public init(
        pollInterval: Duration = .seconds(1), canRun: @escaping @MainActor () -> Bool,
        perform: @escaping Perform = { url, progress in try Importer.importFile(url, progress: progress) }
    ) {
        self.pollInterval = pollInterval
        self.canRun = canRun
        self.perform = perform
    }

    public var isRunning: Bool { status != nil }

    public func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        waiting += urls
        if var status {
            status.total += urls.count
            self.status = status
            return
        }
        status = Status(filename: urls[0].lastPathComponent, number: 1, total: urls.count, fraction: 0)
        Task { await run() }
    }

    private func run() async {
        var first = true
        while !waiting.isEmpty {
            if !first { status?.number += 1 }
            first = false
            let url = waiting.removeFirst()
            let fileID = UUID()
            status?.fileID = fileID
            status?.filename = url.lastPathComponent
            status?.fraction = 0
            // Checked before each file. One already converting finishes: stopping it partway
            // would waste the work, and one file is short next to a service.
            while !canRun() {
                status?.paused = true
                try? await Task.sleep(for: pollInterval)
            }
            status?.paused = false

            let perform = self.perform
            let report: Importer.Progress = { fraction in
                Task { @MainActor [weak self] in
                    guard let self, var status = self.status, status.fileID == fileID else { return }
                    // Read, then write: reading status inside its own assignment is an access conflict.
                    status.fraction = max(status.fraction, fraction)
                    self.status = status
                }
            }
            // A dispatch queue, not the shared Swift threads: an encode or FFmpeg can block for minutes.
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Result { try perform(url, report) })
                }
            }
            switch result {
            case .success(let destination): imported.append(destination)
            case .failure(let error): failures.append(error.localizedDescription)
            }
        }
        let done = (imported, failures)
        imported = []
        failures = []
        status = nil
        onFinished?(done.0, done.1)
    }
}
