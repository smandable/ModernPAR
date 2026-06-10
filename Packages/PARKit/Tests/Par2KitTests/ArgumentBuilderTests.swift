import ModernPARCore
import Testing

@testable import Par2Kit

/// Placeholder shape assertions for the CLI argument mapping. Phase 2 expands this with the full
/// `-b -s -r -c -f -u -l -n -m -t` option matrix and golden-output snapshot tests.
struct ArgumentBuilderTests {
    @Test func verifyMapsToVerb_v() {
        #expect(ArgumentBuilder.command(for: .verifyRepair) == "v")
        #expect(ArgumentBuilder.build(for: SessionRoute(mode: .verifyRepair)) == ["v"])
    }

    @Test func createMapsToVerb_c() {
        #expect(ArgumentBuilder.command(for: .createSet) == "c")
    }

    @Test func extractIsNotAPar2Command() {
        #expect(ArgumentBuilder.command(for: .extractArchive) == nil)
        #expect(ArgumentBuilder.build(for: SessionRoute(mode: .extractArchive)).isEmpty)
    }
}
