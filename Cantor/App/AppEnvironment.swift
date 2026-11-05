import OSLog
import SwiftUI

/// The app model, read from the environment like `@Environment(AppModel.self)`. SwiftUI can update
/// a view once more after the layout it was in has gone, such as a service table's rows when the
/// service is left quickly, and by then the view no longer has the environment. A plain `@Environment` read then stops the app; this
/// falls back to the app's one model, which is what the environment held, and logs which view it was.
@MainActor
@propertyWrapper
struct AppEnvironment: DynamicProperty {
    @Environment(AppModel.self) private var model: AppModel?
    private let fileID: StaticString
    private let line: UInt

    init(fileID: StaticString = #fileID, line: UInt = #line) {
        self.fileID = fileID
        self.line = line
    }

    var wrappedValue: AppModel {
        if let model { return model }
        let site = "\(fileID):\(line)"
        // Once per place, since a body can read the model many times in one update.
        if Self.logged.insert(site).inserted {
            Self.log.notice("No app model in the environment at \(site, privacy: .public); using the app's own")
        }
        guard let current = AppModel.current else { fatalError("No app model yet at \(site)") }
        return current
    }

    private static let log = Logger(subsystem: "org.prcatlanta.Cantor", category: "environment")
    private static var logged: Set<String> = []
}
