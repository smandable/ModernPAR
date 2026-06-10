import Foundation

/// One row in the file table. Equatable + stable id so SwiftUI's `Table` can diff cheaply at the
/// PAR2 limit of 32 768 rows. (ARCHITECTURE.md §3.2)
///
/// In Phase 1 the `id` becomes the real PAR2 File ID
/// (`MD5(MD5-of-first-16k ‖ length ‖ name)`), which is name-dependent.
public struct FileEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var sizeBytes: UInt64
    public var status: FileStatus
    /// Recovery blocks still needed to repair this file — feeds the "need N more blocks" report.
    public var blocksNeeded: Int

    public init(
        id: UUID = UUID(),
        name: String,
        sizeBytes: UInt64 = 0,
        status: FileStatus = .pending,
        blocksNeeded: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.status = status
        self.blocksNeeded = blocksNeeded
    }
}
