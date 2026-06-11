// unrarshim.h — pure-C facade over the vendored RARLAB UnRAR engine (CUnrar).
//
// Swift imports CUnrar as a plain C module through this header, so no C++
// interoperability propagates to dependents (same pattern as par2shim.h).
// Everything crossing this boundary is POD, const char* (UTF-8), or a
// C function pointer; all C++ exceptions are caught behind it.
//
// This component vendors UnRAR source code. Per its license, the UnRAR source
// code may not be used to develop a RAR (WinRAR) compatible archiver — this
// shim deliberately exposes EXTRACTION AND LISTING ONLY, no creation.
//
// Thread-safety: the UnRAR engine keeps process-global state. Callers must
// serialize all unrarshim_* calls onto a single thread/queue; do not run two
// archive operations concurrently in one process.

#ifndef UNRARSHIM_H
#define UNRARSHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Outcome of a whole-archive operation. Values 0–25 mirror the engine's
// ERAR_* codes (static_asserted in UnrarShim.cpp); 90+ are shim-synthesized.
typedef enum {
    UNRARSHIM_SUCCESS = 0,
    UNRARSHIM_NO_MEMORY = 11,        // ERAR_NO_MEMORY
    UNRARSHIM_BAD_DATA = 12,         // ERAR_BAD_DATA — CRC mismatch / corrupt data
    UNRARSHIM_BAD_ARCHIVE = 13,      // ERAR_BAD_ARCHIVE — not a valid RAR volume
    UNRARSHIM_UNKNOWN_FORMAT = 14,   // ERAR_UNKNOWN_FORMAT
    UNRARSHIM_OPEN_ERROR = 15,       // ERAR_EOPEN
    UNRARSHIM_CREATE_ERROR = 16,     // ERAR_ECREATE — cannot create output file/dir
    UNRARSHIM_CLOSE_ERROR = 17,      // ERAR_ECLOSE
    UNRARSHIM_READ_ERROR = 18,       // ERAR_EREAD
    UNRARSHIM_WRITE_ERROR = 19,      // ERAR_EWRITE
    UNRARSHIM_SMALL_BUFFER = 20,     // ERAR_SMALL_BUF
    UNRARSHIM_UNKNOWN_ERROR = 21,    // ERAR_UNKNOWN
    UNRARSHIM_MISSING_PASSWORD = 22, // ERAR_MISSING_PASSWORD — needed, none supplied
    UNRARSHIM_REFERENCE_ERROR = 23,  // ERAR_EREFERENCE
    UNRARSHIM_BAD_PASSWORD = 24,     // ERAR_BAD_PASSWORD — wrong password (RAR5)
    UNRARSHIM_LARGE_DICT = 25,       // ERAR_LARGE_DICT — dictionary allocation refused
    UNRARSHIM_VOLUME_MISSING = 90,   // a required volume is absent (name via callback)
    UNRARSHIM_CXX_EXCEPTION = 100,   // unexpected C++ exception caught at the boundary
    UNRARSHIM_BAD_PARAMETER = 101,   // null/invalid argument
    UNRARSHIM_CANCELLED = 102        // should_cancel returned nonzero
} UnrarShimResult;

// Archive-level facts, mirroring dll.hpp ROADF_* (static_asserted in the shim).
#define UNRARSHIM_FLAG_VOLUME 0x0001u       // part of a multi-volume set
#define UNRARSHIM_FLAG_COMMENT 0x0002u      // has an archive comment
#define UNRARSHIM_FLAG_LOCK 0x0004u         // locked archive
#define UNRARSHIM_FLAG_SOLID 0x0008u        // solid archive
#define UNRARSHIM_FLAG_NEWNUMBERING 0x0010u // .partNN.rar volume naming
#define UNRARSHIM_FLAG_SIGNED 0x0020u       // signed archive
#define UNRARSHIM_FLAG_RECOVERY 0x0040u     // has a recovery record
#define UNRARSHIM_FLAG_ENCHEADERS 0x0080u   // encrypted headers (password to even list)
#define UNRARSHIM_FLAG_FIRSTVOLUME 0x0100u  // this file is the FIRST volume of the set

// One archive entry, valid only for the duration of the entry() callback.
typedef struct {
    const char *name_utf8;  // path inside the archive, '/'-separated
    uint64_t unpacked_size; // 0 for directories
    uint32_t crc32;
    int is_directory;
    int is_encrypted;
    int unp_version; // format generation needed to unpack (15/20/29/50…)
} UnrarShimEntry;

// All callbacks are optional (may be NULL) and are invoked synchronously on
// the calling thread or on the engine's worker thread. They must not call
// back into unrarshim_* functions.
typedef struct {
    void *context;

    // Listing: one call per archive entry (unrarshim_list only).
    void (*entry)(void *context, const UnrarShimEntry *entry);

    // Extraction lifecycle (unrarshim_extract only).
    void (*file_start)(void *context, const char *name_utf8, uint64_t unpacked_size);
    // unrar_code is the per-file ERAR_* result (0 = extracted cleanly).
    void (*file_done)(void *context, const char *name_utf8, int unrar_code);
    // Incremental count of unpacked bytes written (for determinate progress).
    void (*bytes_extracted)(void *context, uint64_t bytes);

    // Multi-volume: the engine switched to the named, present volume.
    void (*volume_changed)(void *context, const char *volume_path_utf8);
    // Multi-volume: the named volume is required but absent. The operation
    // then fails with UNRARSHIM_VOLUME_MISSING (no interactive supply).
    void (*volume_missing)(void *context, const char *volume_path_utf8);

    // Password request ("prompt once, reuse" — the engine caches the first
    // answer for the rest of the archive). Fill utf8_buf (NUL-terminated,
    // buf_size bytes capacity) and return 1; return 0 to decline, which fails
    // the operation with UNRARSHIM_MISSING_PASSWORD.
    int (*need_password)(void *context, char *utf8_buf, size_t buf_size);

    // RAR7 large-dictionary gate: return 1 to allow allocating required_kib
    // KiB (engine cap current_max_kib), 0 to refuse → UNRARSHIM_LARGE_DICT.
    int (*allow_large_dictionary)(void *context, uint64_t required_kib,
                                  uint64_t current_max_kib);

    // Cooperative cancellation, polled at volume changes and during unpacked-
    // data writes (sub-second granularity). Nonzero → UNRARSHIM_CANCELLED.
    int (*should_cancel)(void *context);
} UnrarShimCallbacks;

// Lists every entry of the archive (following all volumes of a multi-volume
// set; each split file is reported exactly once). archive_flags_out (optional)
// receives UNRARSHIM_FLAG_* bits. Encrypted-header archives fire
// need_password during the open.
UnrarShimResult unrarshim_list(const char *archive_path_utf8,
                               const UnrarShimCallbacks *callbacks,
                               uint32_t *archive_flags_out);

// Extracts every entry into destination_dir_utf8 (entry paths are created
// beneath it; the engine sanitizes traversal attempts). Entries that arrive
// "split before" (opening a non-first volume) are skipped. Per-file data
// errors (CRC/bad password) are reported via file_done and extraction
// continues; the first such error becomes the overall result. Warning-class
// skips (engine code 21, e.g. an unsafe/absolute symlink the DLL policy never
// extracts) are also reported via file_done and extraction continues, but
// they do NOT fail the run. When keep_broken_files is 0, files failing their
// checksum are deleted.
UnrarShimResult unrarshim_extract(const char *archive_path_utf8,
                                  const char *destination_dir_utf8,
                                  int keep_broken_files,
                                  const UnrarShimCallbacks *callbacks,
                                  uint32_t *archive_flags_out);

// "UnRAR x.yz" — the engine version compiled into this build.
const char *unrarshim_version(void);

#ifdef __cplusplus
}
#endif

#endif /* UNRARSHIM_H */
