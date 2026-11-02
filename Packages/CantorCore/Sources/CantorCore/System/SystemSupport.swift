import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Security

// MARK: Persistence

public enum AppPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cantor", isDirectory: true)
    }
}

/// Atomic JSON with one rolling backup, so a crash mid-write cannot lose cue points.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var backupURL: URL { url.appendingPathExtension("bak") }

    /// A file that exists but cannot be read or decoded is moved aside, never overwritten by the next save.
    public func load(onQuarantine: (URL) -> Void = { _ in }) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [url, backupURL] {
            let data: Data
            do {
                data = try Data(contentsOf: candidate)
            } catch {
                // Not there is normal. A file that is there but unreadable is reported like a bad one.
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                onQuarantine(setAside(candidate, as: "unreadable"))
                continue
            }
            if let value = try? decoder.decode(Value.self, from: data) { return value }
            onQuarantine(setAside(candidate, as: "corrupt"))
        }
        return nil
    }

    /// Returns where the file now is: the original path if it could not be moved.
    private func setAside(_ candidate: URL, as label: String) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = candidate.appendingPathExtension("\(label)-\(stamp)")
        do {
            try FileManager.default.moveItem(at: candidate, to: aside)
            return aside
        } catch {
            return candidate
        }
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: Run log

public final class RunLog: @unchecked Sendable {
    private let url: URL
    /// Serial, so entries land in the order they were recorded.
    private let queue = DispatchQueue(label: "org.prcatlanta.Cantor.runlog", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(url: URL = AppPaths.support.appendingPathComponent("runlog.jsonl")) {
        self.url = url
    }

    public func record(_ event: String, cue: String?, at date: Date = Date()) {
        let entry: [String: String] = ["time": Self.formatter.string(from: date), "event": event, "cue": cue ?? ""]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let target = url
        queue.async { Self.append(line, to: target) }
    }

    /// Waits for queued entries to reach the file. Call before quitting.
    public func flush() {
        queue.sync {}
    }

    private static func append(_ line: Data, to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        // A log that exists but will not open loses this line, never its history.
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

// MARK: Keychain

public enum KeychainError: LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        if case .status(let status) = self {
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
        return nil
    }
}

public enum Keychain {
    public enum Key: String, CaseIterable, Sendable {
        case pcoAppID = "pco-app-id"
        case pcoSecret = "pco-secret"
    }

    static let service = "org.prcatlanta.Cantor"

    private static func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    // Items stay in the file-based login keychain. The data protection keychain needs a
    // keychain-access-groups entitlement, which an ad hoc signed app cannot have.

    /// Nil for any failure. Use `lookup` to tell "not stored" from "could not read".
    public static func read(_ key: Key) -> String? {
        try? lookup(key)
    }

    /// Nil only when nothing is stored. Any other failure, such as denied access, throws.
    public static func lookup(_ key: Key) throws -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.status(errSecDecode) }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// An empty value removes the item. Otherwise the item is updated in place, so a failed write
    /// leaves the old secret rather than none.
    public static func write(_ value: String, for key: Key) throws {
        guard !value.isEmpty else {
            let status = SecItemDelete(query(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var request = query(key)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }
}

// MARK: Sleep

/// Keeps the Mac and display awake while a service is loaded. Closing the lid still sleeps it.
public final class SleepGuard {
    private var assertions: [IOPMAssertionID] = []
    private var activity: NSObjectProtocol?

    public init() {}

    public var isActive: Bool { !assertions.isEmpty }

    public func engage(reason: String = "Cantor has a service loaded") {
        guard assertions.isEmpty else { return }
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical], reason: reason
        )
    }

    public func release() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

public enum PowerStatus {
    public static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

// MARK: System sounds

public protocol SoundRoutingBackend {
    func defaultUID(system: Bool) -> String?
    func setDefault(uid: String, system: Bool) -> Bool
    func availableUIDs() -> [String]
}

public struct CoreAudioRouting: SoundRoutingBackend {
    public init() {}
    public func defaultUID(system: Bool) -> String? { AudioDevices.defaultDeviceUID(system: system) }
    public func setDefault(uid: String, system: Bool) -> Bool { AudioDevices.setDefaultDevice(uid: uid, system: system) }
    public func availableUIDs() -> [String] { AudioDevices.outputDevices().map(\.uid) }
}

/// Moves macOS alert and default output away from the house device while a service is loaded.
/// The originals are saved to disk first, so they can be restored after a crash.
public final class SystemSoundGuard {
    public struct Record: Codable, Equatable {
        public var originalDefault: String?
        public var originalSystem: String?

        public init(originalDefault: String? = nil, originalSystem: String? = nil) {
            self.originalDefault = originalDefault
            self.originalSystem = originalSystem
        }
    }

    private let backend: SoundRoutingBackend
    private let file: JSONFile<Record>

    public init(
        backend: SoundRoutingBackend = CoreAudioRouting(),
        file: JSONFile<Record> = JSONFile(url: AppPaths.support.appendingPathComponent("sound-guard.json"))
    ) {
        self.backend = backend
        self.file = file
    }

    /// Why the last engage left sound on the house, when it was not the lack of another device.
    public private(set) var lastError: Error?

    /// Returns false if system sound is still on the house: no other device exists, or the restore
    /// record could not be saved (see `lastError`). Nothing is moved that could not be put back.
    @discardableResult
    public func engage(houseUID: String, preferredUID: String?) -> Bool {
        lastError = nil
        let currentDefault = backend.defaultUID(system: false)
        let currentSystem = backend.defaultUID(system: true)
        guard currentDefault == houseUID || currentSystem == houseUID else { return true }

        let available = backend.availableUIDs().filter { $0 != houseUID }
        guard let target = preferredUID.flatMap({ available.contains($0) ? $0 : nil }) ?? available.first else { return false }

        // A saved record means an earlier engage is still in force: keep the true originals. A field
        // an earlier release already restored is filled from now.
        let saved = file.load()
        var record = saved ?? Record()
        record.originalDefault = record.originalDefault ?? currentDefault
        record.originalSystem = record.originalSystem ?? currentSystem
        if record != saved {
            do {
                try file.save(record)
            } catch {
                lastError = error
                return false
            }
        }
        var moved = true
        if currentSystem == houseUID { moved = backend.setDefault(uid: target, system: true) && moved }
        if currentDefault == houseUID { moved = backend.setDefault(uid: target, system: false) && moved }
        return moved
    }

    /// Restores the saved devices. Safe to call on launch: it does nothing without a record.
    /// A device that is not connected stays in the record, so a later release can restore it.
    public func release() {
        guard var record = file.load() else { return }
        let available = Set(backend.availableUIDs())
        if let uid = record.originalSystem, available.contains(uid), backend.setDefault(uid: uid, system: true) {
            record.originalSystem = nil
        }
        if let uid = record.originalDefault, available.contains(uid), backend.setDefault(uid: uid, system: false) {
            record.originalDefault = nil
        }
        guard record.originalSystem == nil, record.originalDefault == nil else {
            try? file.save(record)
            return
        }
        try? FileManager.default.removeItem(at: file.url)
        try? FileManager.default.removeItem(at: file.url.appendingPathExtension("bak"))
    }
}
