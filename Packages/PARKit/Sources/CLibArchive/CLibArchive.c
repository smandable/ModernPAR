// CLibArchive — header bridge to the SYSTEM libarchive (linked via the SDK's
// libarchive.2.tbd stub; see VENDORED.txt for the header provenance and the
// version-skew rule). This translation unit exists because an SPM C target
// needs at least one source file; the API surface is the vendored headers.

#include "archive.h"

// Compile-time pin: the vendored headers must stay at the version verified
// against the macOS runtime (3.7.4). A version bump must re-verify the
// version-skew rule in VENDORED.txt.
_Static_assert(
    ARCHIVE_VERSION_NUMBER == 3007004,
    "vendored libarchive headers drifted from the verified runtime version");
