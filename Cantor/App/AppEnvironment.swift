import OSLog
import SwiftUI

/// The app model, read from the environment like `@Environment(AppModel.self)`. SwiftUI can update
/// a view once more after a switch such as Simple and Advanced has replaced the layout it was in,
/// when that view no longer has the environment. A plain `@Environment` read then stops the app; this
/// falls back to the app's one model, which is what the environment held, and logs which view it was.
@MainActor
@propertyWrapper
struct AppEnvironment: DynamicProperty {
    @Environment(AppModel.self) private var model: AppModel?
    private let site: String

    init(fileID: StaticString = #fileID, line: UInt = #line) {
        site = "\(fileID):\(line)"
    }

    var wrappedValue: AppModel {
        if let model { return model }
        Self.log.notice("No app model in the environment at \(self.site, privacy: .public); using the app's own")
        guard let current = AppModel.current else { fatalError("No app model yet at \(site)") }
        return current
    }

    private static let log = Logger(subsystem: "org.prcatlanta.Cantor", category: "environment")
}
