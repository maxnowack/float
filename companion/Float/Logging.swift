import Foundation
import OSLog

enum FloatLog {
    static let signaling = Logger(subsystem: "de.unsou.Float", category: "signaling")
    static let authentication = Logger(subsystem: "de.unsou.Float", category: "authentication")
    static let media = Logger(subsystem: "de.unsou.Float", category: "media")
    static let pictureInPicture = Logger(subsystem: "de.unsou.Float", category: "pip")

    static func debug(_ logger: Logger, _ message: String) {
#if DEBUG
        logger.debug("\(message, privacy: .private(mask: .hash))")
#else
        _ = logger
        _ = message
#endif
    }
}
