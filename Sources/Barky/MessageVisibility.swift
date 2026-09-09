import Foundation
import CoreGraphics

enum MessageVisibility {
    static func isReadable(_ frame: CGRect, in viewport: CGRect) -> Bool {
        guard !frame.isEmpty, !viewport.isEmpty,
              !frame.isInfinite, !viewport.isInfinite,
              !frame.isNull, !viewport.isNull else { return false }
        let intersection = frame.intersection(viewport)
        // Half the bubble must be visible. For a bubble taller than the viewport,
        // half the viewport is sufficient so long replies can be acknowledged.
        return !intersection.isNull
            && intersection.height >= min(frame.height, viewport.height) * 0.5
            && intersection.width >= min(frame.width, viewport.width) * 0.5
    }
}
