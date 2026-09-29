import AppKit
import CoreGraphics
import Foundation

struct OverlayDisplayOption: Identifiable, Equatable, Sendable {
    let id: UInt32
    let title: String
    let detail: String

    var menuTitle: String {
        detail.isEmpty ? title : "\(title) · \(detail)"
    }
}

extension NSScreen {
    var overlayDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    var overlayDisplayName: String {
        if #available(macOS 10.15, *) {
            return localizedName
        }
        return "显示器"
    }

    var isBuiltInDisplay: Bool {
        guard let displayID = overlayDisplayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}
