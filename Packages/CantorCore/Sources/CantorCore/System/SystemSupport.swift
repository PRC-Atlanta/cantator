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

    /// A file that exists but cannot be decoded is moved aside, never overwritten by the next save.
    public func load(onQuarantine: (URL) -> Void = { _ in }) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [url, backupURL] {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if let value = try? decoder.decode(Value.self, from: data) { return value }
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = candidate.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: candidate, to: aside)
            onQuarantine(aside)
        }
        return nil
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

    public init(url: URL = AppPaths.support.appendingPathComponent("runlog.jsonl")) {
        self.url = url
    }

    public func record(_ event: String, cue: String?, at date: Date = Date()) {
        let entry: [String: String] = ["time": ISO8601DateFormatter().string(from: date), "event": event, "cue": cue ?? ""]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let target = url
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: target) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: target)
            }
        }
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
        case anthropicAPIKey = "anthropic-api-key"
    }

    static let service = "org.prcatlanta.Cantor"

    private static func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    public static func read(_ key: Key) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func write(_ value: String, for key: Key) throws {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var request = query(key)
        request[kSecValueData as String] = Data(value.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
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

    /// Returns false if system sound is still on the house and no other device exists.
    @discardableResult
    public func engage(houseUID: String, preferredUID: String?) -> Bool {
        let currentDefault = backend.defaultUID(system: false)
        let currentSystem = backend.defaultUID(system: true)
        guard currentDefault == houseUID || currentSystem == houseUID else { return true }

        let available = backend.availableUIDs().filter { $0 != houseUID }
        guard let target = preferredUID.flatMap({ available.contains($0) ? $0 : nil }) ?? available.first else { return false }

        // A saved record means an earlier engage is still in force: keep the true originals.
        if file.load() == nil {
            try? file.save(Record(originalDefault: currentDefault, originalSystem: currentSystem))
        }
        var moved = true
        if currentSystem == houseUID { moved = backend.setDefault(uid: target, system: true) && moved }
        if currentDefault == houseUID { moved = backend.setDefault(uid: target, system: false) && moved }
        return moved
    }

    /// Restores the saved devices. Safe to call on launch: it does nothing without a record.
    public func release() {
        guard let record = file.load() else { return }
        let available = Set(backend.availableUIDs())
        if let uid = record.originalSystem, available.contains(uid) { _ = backend.setDefault(uid: uid, system: true) }
        if let uid = record.originalDefault, available.contains(uid) { _ = backend.setDefault(uid: uid, system: false) }
        try? FileManager.default.removeItem(at: file.url)
        try? FileManager.default.removeItem(at: file.url.appendingPathExtension("bak"))
    }
}
