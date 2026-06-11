import Foundation
import Par2Cxx

/// Thin Swift face over `par2shim_create`. Blocking — call it off the main actor. The full
/// create UX (redundancy %, schemes, naming) arrives in Phase 6; this is the engine-level
/// capability plus what the tests need today.
public enum Par2Create {
    public struct Failure: Error, Equatable {
        public let code: Int32
    }

    /// Creates `parFile` covering `files` (all in one folder). `recoveryBlockCount` is the
    /// explicit block count — derive it from a redundancy percentage with `RecoveryMath`.
    public static func createSet(
        parFile: URL,
        files: [URL],
        blockSize: UInt64,
        recoveryBlockCount: UInt32,
        threads: UInt32 = 0
    ) throws {
        var argv: [UnsafePointer<CChar>?] = files.map { UnsafePointer(strdup($0.path)) }
        defer {
            for pointer in argv { free(UnsafeMutablePointer(mutating: pointer)) }
        }
        let result = argv.withUnsafeBufferPointer { buffer in
            par2shim_create(
                parFile.path,
                nil,
                buffer.baseAddress,
                files.count,
                blockSize,
                recoveryBlockCount,
                PAR2SHIM_SCHEME_VARIABLE,
                0,
                threads,
                0,
                nil, nil, nil, nil)
        }
        guard result == PAR2SHIM_SUCCESS else {
            throw Failure(code: Int32(result.rawValue))
        }
    }
}
