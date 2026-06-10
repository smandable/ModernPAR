import ModernPARCore
import SwiftUI

/// The set facts strip above the file table: file count, total size, block size, source/recovery
/// block counts, redundancy. Painted by the native parser the instant a set is opened — before
/// any engine runs. (ROADMAP Phase 1 demoable milestone)
public struct SetHeader: View {
    // Named `parSet`, not `set` — `set` is the accessor keyword inside computed properties.
    let parSet: ParSet
    public init(set: ParSet) { self.parSet = set }

    public var body: some View {
        HStack(spacing: 16) {
            fact(
                parSet.kind == .par2 ? "PAR2 set" : "PAR1 set",
                systemImage: "shield.lefthalf.filled")
            fact(
                "\(parSet.files.count) file\(parSet.files.count == 1 ? "" : "s")",
                systemImage: "doc")
            fact(totalSize, systemImage: "externaldrive")
            if parSet.kind == .par2 {
                fact(
                    "\(parSet.sliceSizeBytes.formatted(.byteCount(style: .file))) blocks",
                    systemImage: "square.grid.3x3")
                fact("\(parSet.sourceBlockCount) source", systemImage: "square.stack.3d.up")
                fact(
                    "\(parSet.recoveryBlocksAvailable) recovery (\(redundancy))",
                    systemImage: "cross.case")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private var totalSize: String {
        // Saturating sum: sizes come from untrusted packet data; a checked `+` would let a
        // crafted set crash the app during header render.
        parSet.files.reduce(UInt64(0)) { sum, file in
            let (next, overflow) = sum.addingReportingOverflow(file.sizeBytes)
            return overflow ? UInt64.max : next
        }
        .formatted(.byteCount(style: .file))
    }

    private var redundancy: String {
        let percent = RecoveryMath.redundancyPercent(
            sourceBlocks: parSet.sourceBlockCount,
            recoveryBlocks: parSet.recoveryBlocksAvailable)
        return percent.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private func fact(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}
