/* Par2Shim — the extern "C" umbrella over the embedded par2cmdline-turbo engine.
 *
 * This is the ONLY header Swift sees. The contract (ARCHITECTURE.md §1.1, §6):
 *   - C ABI only: POD types, const char*, function pointers. No C++ crosses this line.
 *   - Every entry point catches ALL C++ exceptions (libpar2 throws; Swift cannot catch)
 *     and returns an error code instead.
 *   - Blocking calls; run them on a background thread. Callbacks arrive on engine worker
 *     threads and must be thread-safe.
 *   - Cancellation is cooperative: `should_cancel` is polled every time the engine flushes
 *     a line or a progress update — typically sub-second, but bounded by one backend chunk
 *     computation and one chunk's recovered-data write during repair (those stretches print
 *     nothing). When it returns nonzero the run unwinds and PAR2SHIM_CANCELLED comes back.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later (part of ModernPAR; wraps GPL turbo sources)
 */

#ifndef PAR2SHIM_H
#define PAR2SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors libpar2's Result enum, plus shim-level codes from 100 up. */
typedef enum {
    PAR2SHIM_SUCCESS = 0,
    PAR2SHIM_REPAIR_POSSIBLE = 1,      /* damaged, enough recovery data to repair */
    PAR2SHIM_REPAIR_NOT_POSSIBLE = 2,  /* damaged, NOT enough recovery data */
    PAR2SHIM_INVALID_ARGS = 3,
    PAR2SHIM_INSUFFICIENT_CRITICAL_DATA = 4,
    PAR2SHIM_REPAIR_FAILED = 5,
    PAR2SHIM_FILE_IO_ERROR = 6,
    PAR2SHIM_LOGIC_ERROR = 7,
    PAR2SHIM_MEMORY_ERROR = 8,
    /* shim-level */
    PAR2SHIM_CXX_EXCEPTION = 100,      /* a C++ exception was caught at the boundary */
    PAR2SHIM_BAD_PARAMETER = 101,
    PAR2SHIM_CANCELLED = 102           /* should_cancel returned nonzero */
} Par2ShimResult;

/* Mirrors libpar2's Scheme enum (recovery-file sizing, the CLI's -u/-l default). */
typedef enum {
    PAR2SHIM_SCHEME_VARIABLE = 1,  /* each recovery file has 2x the blocks of the previous */
    PAR2SHIM_SCHEME_LIMITED = 2,   /* limit recovery-file size */
    PAR2SHIM_SCHEME_UNIFORM = 3    /* all recovery files the same size */
} Par2ShimScheme;

/* "par2cmdline-turbo 1.4.0" — proves Swift is linked against the vendored engine. */
const char *par2shim_version(void);

/* Sink for the engine's stdout/stderr text, line-buffered by the shim (both newline- and
 * carriage-return-terminated — progress updates use "\r"). `is_error` is 1 for stderr.
 * May be NULL to discard output. */
typedef void (*Par2ShimLogLine)(void *context, const char *line, int is_error);

/* Cooperative cancellation poll. Return nonzero to stop the run. May be NULL. */
typedef int (*Par2ShimShouldCancel)(void *context);

/* Verify (dorepair = 0) or repair (dorepair = 1) the set anchored at `par2_path`.
 * `base_path` may be NULL (defaults to the .par2 file's directory, canonicalized —
 * the same default the par2 CLI applies). `threads` 0 = automatic.
 * `memory_limit_bytes` 0 = automatic (half of physical RAM — the CLI's default; passing a
 * literal 0 through to the engine would mean a zero-byte working buffer and pathological
 * one-slice-at-a-time processing).
 * `extra_files` (may be NULL when count is 0): additional files to scan for misplaced data —
 * the folder's data files, like `par2 r set.par2 *`. This is what lets the engine find
 * renamed/misnamed sources, including its own `name.1` backups from an interrupted repair. */
Par2ShimResult par2shim_repair(
    const char *par2_path,
    const char *base_path,
    const char *const *extra_files,
    size_t extra_file_count,
    unsigned threads,
    size_t memory_limit_bytes,
    int dorepair,
    Par2ShimLogLine log_line,
    void *log_context,
    Par2ShimShouldCancel should_cancel,
    void *cancel_context);

/* Create a recovery set named `par2_path` covering `files` (absolute paths, all within one
 * folder — `base_path` NULL defaults like par2shim_repair). `block_size` must be a positive
 * multiple of 4. `recovery_block_count` is the explicit count (the Swift layer derives it
 * from a redundancy %). `recovery_file_count` 0 = automatic for the scheme. */
Par2ShimResult par2shim_create(
    const char *par2_path,
    const char *base_path,
    const char *const *files,
    size_t file_count,
    uint64_t block_size,
    uint32_t recovery_block_count,
    Par2ShimScheme scheme,
    uint32_t recovery_file_count,
    unsigned threads,
    size_t memory_limit_bytes,
    Par2ShimLogLine log_line,
    void *log_context,
    Par2ShimShouldCancel should_cancel,
    void *cancel_context);

#ifdef __cplusplus
}
#endif

#endif /* PAR2SHIM_H */
