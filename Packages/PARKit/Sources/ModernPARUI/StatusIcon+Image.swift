import ModernPARCore
import SwiftUI

/// Renders a `StatusIcon` as an SF Symbol. Phase 8 may swap in the original's bespoke .icns art;
/// SF Symbols give us a crisp, native, accessible default now.
public struct StatusIconImage: View {
    let icon: StatusIcon
    public init(icon: StatusIcon) { self.icon = icon }

    public var body: some View {
        switch icon {
        case .neutral:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .recoverable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .notInVolumeSet:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
