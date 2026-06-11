/* Par2Shim — the extern "C" umbrella over the embedded par2cmdline-turbo engine.
 *
 * This is the ONLY header Swift sees. The contract (ARCHITECTURE.md §1.1, §6):
 *   - C ABI only: POD types, const char*, function pointers. No C++ crosses this line.
 *   - Every entry point catches ALL C++ exceptions (libpar2 throws; Swift cannot catch)
 *     and returns an error code instead.
 *   - Blocking calls; run them on a background thread and bridge progress via callbacks
 *     (callbacks arrive on engine worker threads).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later (part of ModernPAR; wraps GPL turbo sources)
 */

#ifndef PAR2SHIM_H
#define PAR2SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors libpar2's Result enum, plus shim-level failure codes from 100 up. */
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
    PAR2SHIM_BAD_PARAMETER = 101
} Par2ShimResult;

/* "par2cmdline-turbo 1.4.0" — proves Swift is linked against the vendored engine. */
const char *par2shim_version(void);

/* Sink for the engine's stdout/stderr text, line-buffered by the shim.
 * `is_error` is 1 for stderr lines. May be NULL to discard output. */
typedef void (*Par2ShimLogLine)(void *context, const char *line, int is_error);

/* Verify (dorepair = 0) or repair (dorepair = 1) the set anchored at `par2_path`.
 * `base_path` may be NULL (defaults to the .par2 file's directory, canonicalized —
 * the same default the par2 CLI applies). `threads` 0 = automatic.
 * `memory_limit_bytes` 0 = automatic (half of physical RAM — the CLI's default; passing a
 * literal 0 through to the engine would mean a zero-byte working buffer and pathological
 * one-slice-at-a-time processing). */
Par2ShimResult par2shim_repair(
    const char *par2_path,
    const char *base_path,
    unsigned threads,
    size_t memory_limit_bytes,
    int dorepair,
    Par2ShimLogLine log_line,
    void *log_context);

#ifdef __cplusplus
}
#endif

#endif /* PAR2SHIM_H */
