import Foundation

/// Dispatches a verify/repair route to the PAR2 engine or the native PAR1 engine by the
/// anchor file's form — the call sites keep injecting ONE `PAR2Engine`, exactly as before
/// Phase 8. The anchor's extension is authoritative: `.par2` is PAR2; `.par`/`.pNN`/`.qNN`
/// are PAR1 (the session's `anchorFile(for:)` only ever anchors on these).
public struct EngineRouter: PAR2Engine, Sendable {
    private let par2: any PAR2Engine
    private let par1: any PAR2Engine

    public init(par2: any PAR2Engine, par1: any PAR2Engine) {
        self.par2 = par2
        self.par1 = par1
    }

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        isPar1Route(route) ? par1.run(route) : par2.run(route)
    }

    /// Peeks at the anchor bookmark's filename. The scope started by resolution is balanced
    /// immediately — the chosen engine resolves its own access.
    private func isPar1Route(_ route: SessionRoute) -> Bool {
        guard let data = route.anchorBookmark, let resolved = try? ScopedAccess.resolve(data)
        else { return false }
        if resolved.didStart { resolved.url.stopAccessingSecurityScopedResource() }
        let ext = resolved.url.pathExtension.lowercased()
        if ext == "par" { return true }
        guard ext.count == 3, let first = ext.first, first == "p" || first == "q" else {
            return false
        }
        return ext.dropFirst().allSatisfy(\.isNumber)
    }
}
