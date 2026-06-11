// UnrarShim.cpp — implementation of the pure-C unrarshim.h facade.
//
// This file (not the vendored tree) owns every contract subtlety:
//   - UCM_* callback semantics are documented in vendor/VENDORED.txt and must
//     be re-verified on any UnRAR version bump.
//   - All C++ exceptions are caught at the extern-C boundary; callbacks never
//     let exceptions escape into the engine (which would std::terminate or
//     corrupt its unwinding).
//   - Extraction and listing ONLY. Per the UnRAR license, this source may not
//     be used to develop a RAR (WinRAR) compatible archiver, and no creation
//     capability is exposed.

#include "rar.hpp"

#include "unrarshim.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// The shim's public constants mirror dll.hpp; drift breaks Swift silently,
// so pin every mirrored value at compile time.
static_assert(UNRARSHIM_SUCCESS == ERAR_SUCCESS, "ERAR drift");
static_assert(UNRARSHIM_NO_MEMORY == ERAR_NO_MEMORY, "ERAR drift");
static_assert(UNRARSHIM_BAD_DATA == ERAR_BAD_DATA, "ERAR drift");
static_assert(UNRARSHIM_BAD_ARCHIVE == ERAR_BAD_ARCHIVE, "ERAR drift");
static_assert(UNRARSHIM_UNKNOWN_FORMAT == ERAR_UNKNOWN_FORMAT, "ERAR drift");
static_assert(UNRARSHIM_OPEN_ERROR == ERAR_EOPEN, "ERAR drift");
static_assert(UNRARSHIM_CREATE_ERROR == ERAR_ECREATE, "ERAR drift");
static_assert(UNRARSHIM_CLOSE_ERROR == ERAR_ECLOSE, "ERAR drift");
static_assert(UNRARSHIM_READ_ERROR == ERAR_EREAD, "ERAR drift");
static_assert(UNRARSHIM_WRITE_ERROR == ERAR_EWRITE, "ERAR drift");
static_assert(UNRARSHIM_SMALL_BUFFER == ERAR_SMALL_BUF, "ERAR drift");
static_assert(UNRARSHIM_UNKNOWN_ERROR == ERAR_UNKNOWN, "ERAR drift");
static_assert(UNRARSHIM_MISSING_PASSWORD == ERAR_MISSING_PASSWORD, "ERAR drift");
static_assert(UNRARSHIM_REFERENCE_ERROR == ERAR_EREFERENCE, "ERAR drift");
static_assert(UNRARSHIM_BAD_PASSWORD == ERAR_BAD_PASSWORD, "ERAR drift");
static_assert(UNRARSHIM_LARGE_DICT == ERAR_LARGE_DICT, "ERAR drift");

static_assert(UNRARSHIM_FLAG_VOLUME == ROADF_VOLUME, "ROADF drift");
static_assert(UNRARSHIM_FLAG_COMMENT == ROADF_COMMENT, "ROADF drift");
static_assert(UNRARSHIM_FLAG_LOCK == ROADF_LOCK, "ROADF drift");
static_assert(UNRARSHIM_FLAG_SOLID == ROADF_SOLID, "ROADF drift");
static_assert(UNRARSHIM_FLAG_NEWNUMBERING == ROADF_NEWNUMBERING, "ROADF drift");
static_assert(UNRARSHIM_FLAG_SIGNED == ROADF_SIGNED, "ROADF drift");
static_assert(UNRARSHIM_FLAG_RECOVERY == ROADF_RECOVERY, "ROADF drift");
static_assert(UNRARSHIM_FLAG_ENCHEADERS == ROADF_ENCHEADERS, "ROADF drift");
static_assert(UNRARSHIM_FLAG_FIRSTVOLUME == ROADF_FIRSTVOLUME, "ROADF drift");

namespace {

struct ShimContext {
    UnrarShimCallbacks cb{};  // copied; the caller's struct may be stack-local
    // PROCESSDATA can fire off the API thread; everything it touches is atomic.
    std::atomic<bool> cancelled{false};
    // Set/read only on the API thread (volume + password callbacks are
    // synchronous within RAROpenArchiveEx/RARReadHeaderEx/RARProcessFileW).
    bool passwordDeclined = false;
    bool volumeMissing = false;

    bool shouldCancel() {
        if (cancelled.load(std::memory_order_relaxed)) return true;
        if (cb.should_cancel != nullptr && cb.should_cancel(cb.context) != 0) {
            cancelled.store(true, std::memory_order_relaxed);
            return true;
        }
        return false;
    }
};

// The one callback the engine sees. Must be exception-tight: a C++ exception
// unwinding through the engine's call sites is undefined behavior.
int CALLBACK ShimEngineCallback(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
    auto *ctx = reinterpret_cast<ShimContext *>(userData);
    if (ctx == nullptr) return -1;
    try {
        switch (msg) {
            case UCM_PROCESSDATA: {
                if (ctx->cb.bytes_extracted != nullptr && p2 > 0)
                    ctx->cb.bytes_extracted(ctx->cb.context, static_cast<uint64_t>(p2));
                return ctx->shouldCancel() ? -1 : 1;
            }
            case UCM_NEEDPASSWORDW: {
                if (ctx->shouldCancel()) return -1;
                char utf8[2048] = {0};
                int filled = 0;
                if (ctx->cb.need_password != nullptr)
                    filled = ctx->cb.need_password(ctx->cb.context, utf8, sizeof(utf8));
                if (filled == 0 || utf8[0] == 0) {
                    cleandata(utf8, sizeof(utf8));
                    ctx->passwordDeclined = true;
                    return -1;
                }
                auto *buf = reinterpret_cast<wchar *>(p1);
                const size_t cap = static_cast<size_t>(p2);  // capacity in wchars
                if (!UtfToWide(utf8, buf, cap) || buf[0] == 0) {
                    // Inconvertible password — treat as declined. (Overlong
                    // passwords are silently truncated by UtfToWide, which is
                    // harmless: every RAR key derivation truncates to 127
                    // wchars anyway — crypt.cpp MAXPASSWORD_RAR.)
                    cleandata(buf, cap * sizeof(wchar));
                    cleandata(utf8, sizeof(utf8));
                    ctx->passwordDeclined = true;
                    return -1;
                }
                cleandata(utf8, sizeof(utf8));
                return 1;
            }
            case UCM_NEEDPASSWORD:
                // ANSI fallback fires only when the wide path yielded nothing
                // (we declined, or conversion failed). Decline it too.
                ctx->passwordDeclined = true;
                return -1;
            case UCM_CHANGEVOLUMEW: {
                std::string nameUtf8;
                WideToUtf(std::wstring(reinterpret_cast<const wchar *>(p1)), nameUtf8);
                if (static_cast<int>(p2) == RAR_VOL_ASK) {
                    // The volume is absent. MVP surfaces a mapped error (the
                    // UI re-runs after the user supplies it); returning >= 0
                    // unchanged would re-ask forever.
                    ctx->volumeMissing = true;
                    if (ctx->cb.volume_missing != nullptr)
                        ctx->cb.volume_missing(ctx->cb.context, nameUtf8.c_str());
                    return -1;
                }
                if (ctx->cb.volume_changed != nullptr)
                    ctx->cb.volume_changed(ctx->cb.context, nameUtf8.c_str());
                return ctx->shouldCancel() ? -1 : 1;
            }
            case UCM_CHANGEVOLUME:
                // ANSI variant: ASK only reaches here if the W handler
                // returned >= 0, which ours never does for ASK.
                if (static_cast<int>(p2) == RAR_VOL_ASK) {
                    ctx->volumeMissing = true;
                    return -1;
                }
                return ctx->shouldCancel() ? -1 : 1;
            case UCM_LARGEDICT: {
                if (ctx->cb.allow_large_dictionary == nullptr) return 0;
                return ctx->cb.allow_large_dictionary(ctx->cb.context,
                                                      static_cast<uint64_t>(p1),
                                                      static_cast<uint64_t>(p2)) != 0
                           ? 1
                           : 0;
            }
            default:
                return 1;
        }
    } catch (...) {
        return -1;
    }
}

// Folds the shim-tracked abort reasons over the engine's raw code: the engine
// reports user aborts as generic EOPEN/UNKNOWN/BAD_DATA, so the flags win.
UnrarShimResult MapResult(int code, const ShimContext &ctx) {
    if (ctx.cancelled.load(std::memory_order_relaxed)) return UNRARSHIM_CANCELLED;
    if (ctx.volumeMissing) return UNRARSHIM_VOLUME_MISSING;
    if (ctx.passwordDeclined) return UNRARSHIM_MISSING_PASSWORD;
    switch (code) {
        case ERAR_SUCCESS:
            return UNRARSHIM_SUCCESS;
        case ERAR_NO_MEMORY:
        case ERAR_BAD_DATA:
        case ERAR_BAD_ARCHIVE:
        case ERAR_UNKNOWN_FORMAT:
        case ERAR_EOPEN:
        case ERAR_ECREATE:
        case ERAR_ECLOSE:
        case ERAR_EREAD:
        case ERAR_EWRITE:
        case ERAR_SMALL_BUF:
        case ERAR_UNKNOWN:
        case ERAR_MISSING_PASSWORD:
        case ERAR_EREFERENCE:
        case ERAR_BAD_PASSWORD:
        case ERAR_LARGE_DICT:
            return static_cast<UnrarShimResult>(code);
        default:
            return UNRARSHIM_UNKNOWN_ERROR;
    }
}

// Per-file data problems where the CLI convention is "report and move on".
bool IsPerFileError(int code) {
    return code == ERAR_BAD_DATA || code == ERAR_BAD_PASSWORD || code == ERAR_LARGE_DICT;
}

// Warning-class per-file outcomes: the engine skipped the entry (e.g. an
// absolute/unsafe symlink, which the DLL policy never extracts) and set only
// the warning-grade error code that the call tail maps to ERAR_UNKNOWN. The
// CLI convention is a warning plus continued extraction, and the skip must
// not fail the archive.
bool IsPerFileWarning(int code) { return code == ERAR_UNKNOWN; }

// The engine's global error state is STICKY (cleaned only at archive open) and
// unrar.dll's call tails convert it into per-call return codes — so without a
// per-iteration clean, one corrupt/skipped file poisons every later call.
// Safe here: the shim tracks its own first-error result, and all unrarshim_*
// calls are serialized by contract.
void CleanStickyEngineState() { ErrHandler.Clean(); }

struct OpenedArchive {
    HANDLE handle = nullptr;
    uint32_t flags = 0;
    int openResult = ERAR_SUCCESS;
};

// dll.hpp takes mutable wchar_t* parameters; C++14 strings only hand out
// const data(), so cross the boundary with NUL-terminated vectors.
std::vector<wchar> MutableWide(const std::wstring &s) {
    std::vector<wchar> buf(s.begin(), s.end());
    buf.push_back(0);
    return buf;
}

OpenedArchive OpenArchive(const char *pathUtf8, unsigned openMode, int keepBroken,
                          ShimContext &ctx) {
    OpenedArchive out;
    std::wstring widePath;
    if (!UtfToWide(pathUtf8, widePath)) {
        out.openResult = ERAR_EOPEN;
        return out;
    }
    std::vector<wchar> widePathBuf = MutableWide(widePath);
    RAROpenArchiveDataEx open{};
    open.ArcNameW = widePathBuf.data();
    open.OpenMode = openMode;
    open.Callback = ShimEngineCallback;
    open.UserData = reinterpret_cast<LPARAM>(&ctx);
    open.OpFlags = keepBroken != 0 ? ROADOF_KEEPBROKEN : 0;
    out.handle = RAROpenArchiveEx(&open);
    out.flags = open.Flags;
    out.openResult = static_cast<int>(open.OpenResult);
    return out;
}

}  // namespace

extern "C" {

const char *unrarshim_version(void) {
    // Formatted exactly once (C++11 static-init is thread-safe); the values
    // are compile-time constants.
    static const std::string version = [] {
        char buffer[32];
        std::snprintf(buffer, sizeof(buffer), "UnRAR %d.%02d", RARVER_MAJOR, RARVER_MINOR);
        return std::string(buffer);
    }();
    return version.c_str();
}

UnrarShimResult unrarshim_list(const char *archive_path_utf8,
                               const UnrarShimCallbacks *callbacks,
                               uint32_t *archive_flags_out) {
    if (archive_path_utf8 == nullptr) return UNRARSHIM_BAD_PARAMETER;
    try {
        ShimContext ctx;
        if (callbacks != nullptr) ctx.cb = *callbacks;

        OpenedArchive arc = OpenArchive(archive_path_utf8, RAR_OM_LIST, 0, ctx);
        if (archive_flags_out != nullptr) *archive_flags_out = arc.flags;
        if (arc.handle == nullptr) return MapResult(arc.openResult, ctx);

        UnrarShimResult result = UNRARSHIM_SUCCESS;
        for (;;) {
            if (ctx.shouldCancel()) {
                result = UNRARSHIM_CANCELLED;
                break;
            }
            CleanStickyEngineState();
            RARHeaderDataEx header{};
            int rh = RARReadHeaderEx(arc.handle, &header);
            if (rh == ERAR_END_ARCHIVE) break;
            if (rh != ERAR_SUCCESS) {
                result = MapResult(rh, ctx);
                break;
            }
            if (ctx.cb.entry != nullptr) {
                std::string nameUtf8;
                WideToUtf(std::wstring(header.FileNameW), nameUtf8);
                UnrarShimEntry entry{};
                entry.name_utf8 = nameUtf8.c_str();
                entry.unpacked_size = (static_cast<uint64_t>(header.UnpSizeHigh) << 32) |
                                      static_cast<uint64_t>(header.UnpSize);
                entry.crc32 = header.FileCRC;
                entry.is_directory = (header.Flags & RHDF_DIRECTORY) != 0 ? 1 : 0;
                entry.is_encrypted = (header.Flags & RHDF_ENCRYPTED) != 0 ? 1 : 0;
                entry.unp_version = static_cast<int>(header.UnpVer);
                ctx.cb.entry(ctx.cb.context, &entry);
            }
            int pc = RARProcessFileW(arc.handle, RAR_SKIP, nullptr, nullptr);
            if (pc != ERAR_SUCCESS) {
                result = MapResult(pc, ctx);
                break;
            }
        }
        RARCloseArchive(arc.handle);
        return result;
    } catch (...) {
        return UNRARSHIM_CXX_EXCEPTION;
    }
}

UnrarShimResult unrarshim_extract(const char *archive_path_utf8,
                                  const char *destination_dir_utf8,
                                  int keep_broken_files,
                                  const UnrarShimCallbacks *callbacks,
                                  uint32_t *archive_flags_out) {
    if (archive_path_utf8 == nullptr || destination_dir_utf8 == nullptr)
        return UNRARSHIM_BAD_PARAMETER;
    try {
        ShimContext ctx;
        if (callbacks != nullptr) ctx.cb = *callbacks;

        std::wstring destWide;
        if (!UtfToWide(destination_dir_utf8, destWide)) return UNRARSHIM_BAD_PARAMETER;
        std::vector<wchar> destWideBuf = MutableWide(destWide);

        OpenedArchive arc =
            OpenArchive(archive_path_utf8, RAR_OM_EXTRACT, keep_broken_files, ctx);
        if (archive_flags_out != nullptr) *archive_flags_out = arc.flags;
        if (arc.handle == nullptr) return MapResult(arc.openResult, ctx);

        UnrarShimResult result = UNRARSHIM_SUCCESS;
        for (;;) {
            if (ctx.shouldCancel()) {
                result = UNRARSHIM_CANCELLED;
                break;
            }
            CleanStickyEngineState();
            RARHeaderDataEx header{};
            int rh = RARReadHeaderEx(arc.handle, &header);
            if (rh == ERAR_END_ARCHIVE) break;
            if (rh != ERAR_SUCCESS) {
                result = MapResult(rh, ctx);
                break;
            }
            std::string nameUtf8;
            WideToUtf(std::wstring(header.FileNameW), nameUtf8);

            // A "split before" entry is the tail of a file that started in an
            // earlier volume — only seen when opening a non-first volume
            // (callers normalize to the first volume; this is a backstop).
            if ((header.Flags & RHDF_SPLITBEFORE) != 0) {
                int pc = RARProcessFileW(arc.handle, RAR_SKIP, nullptr, nullptr);
                if (pc != ERAR_SUCCESS) {
                    result = MapResult(pc, ctx);
                    break;
                }
                continue;
            }

            const uint64_t unpSize = (static_cast<uint64_t>(header.UnpSizeHigh) << 32) |
                                     static_cast<uint64_t>(header.UnpSize);
            if (ctx.cb.file_start != nullptr)
                ctx.cb.file_start(ctx.cb.context, nameUtf8.c_str(), unpSize);

            int pc = RARProcessFileW(arc.handle, RAR_EXTRACT, destWideBuf.data(), nullptr);

            if (ctx.cancelled.load(std::memory_order_relaxed) || ctx.volumeMissing ||
                ctx.passwordDeclined) {
                // file_done is deliberately not fired: the file's state is
                // "operation aborted", not a per-file verdict.
                result = MapResult(pc, ctx);
                break;
            }
            if (ctx.cb.file_done != nullptr)
                ctx.cb.file_done(ctx.cb.context, nameUtf8.c_str(), pc);
            if (pc == ERAR_SUCCESS) continue;
            if (IsPerFileWarning(pc)) continue;  // skipped entry: warn, never fail the run
            if (IsPerFileError(pc)) {
                if (result == UNRARSHIM_SUCCESS) result = MapResult(pc, ctx);
                continue;  // CLI convention: report the file, keep extracting
            }
            result = MapResult(pc, ctx);  // environmental (I/O, memory): stop
            break;
        }
        RARCloseArchive(arc.handle);
        return result;
    } catch (...) {
        return UNRARSHIM_CXX_EXCEPTION;
    }
}

}  // extern "C"
