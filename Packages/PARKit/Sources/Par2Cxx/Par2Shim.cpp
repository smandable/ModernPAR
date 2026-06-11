/* Par2Shim implementation — see include/par2shim.h for the boundary contract.
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "par2shim.h"

#include <sys/sysctl.h>

#include <exception>
#include <sstream>
#include <string>
#include <vector>

#include "vendor/src/libpar2.h"
#include "vendor/src/diskfile.h"

namespace {

/* Distinct type (deliberately not std::exception) thrown from the streambuf to unwind the
 * engine on cancellation. The vendored foreach_parallel.h patch guarantees worker-thread
 * throws are rethrown on the joining thread instead of hitting std::terminate. */
struct CancelledException {};

/* Mirrors the CLI's default (commandline.cpp): half of physical RAM, computed in whole
 * megabytes. GetTotalPhysicalMemory lives in the excluded CLI translation unit, so the
 * macOS sysctl is queried directly here. */
size_t defaultMemoryLimit() {
    unsigned long long physical = 0;
    size_t length = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &length, nullptr, 0) != 0 || physical == 0) {
        physical = 256ULL * 1048576; /* the CLI's fallback floor */
    }
    return static_cast<size_t>(physical / 1048576 / 2) * 1048576;
}

/* Forwards each complete line written by the engine to the C callback and polls the
 * cancellation flag on every sync (std::endl and the "\r"-progress std::flush both land
 * here, on whichever engine thread produced the output). */
class LineForwardingBuf : public std::stringbuf {
public:
    LineForwardingBuf(
        Par2ShimLogLine callback, void *context, int isError,
        Par2ShimShouldCancel shouldCancel, void *cancelContext)
        : callback_(callback),
          context_(context),
          isError_(isError),
          shouldCancel_(shouldCancel),
          cancelContext_(cancelContext) {}

    ~LineForwardingBuf() override {
        try {
            flushPending();
        } catch (...) {
            /* never throw from a destructor */
        }
    }

protected:
    int sync() override {
        if (shouldCancel_ != nullptr && shouldCancel_(cancelContext_) != 0) {
            throw CancelledException{};
        }
        flushPending();
        return 0;
    }

private:
    void flushPending() {
        if (callback_ == nullptr) {
            str("");
            return;
        }
        std::string buffered = str();
        size_t start = 0;
        for (;;) {
            size_t newline = buffered.find_first_of("\r\n", start);
            if (newline == std::string::npos) break;
            if (newline > start) {
                std::string line = buffered.substr(start, newline - start);
                callback_(context_, line.c_str(), isError_);
            }
            start = newline + 1;
        }
        str(buffered.substr(start));
    }

    Par2ShimLogLine callback_;
    void *context_;
    int isError_;
    Par2ShimShouldCancel shouldCancel_;
    void *cancelContext_;
};

/* Shared run scaffolding: streams with badbit exceptions enabled (without that mask the
 * ostream machinery would catch the streambuf's CancelledException itself and only set
 * badbit), the engine call, and the catch-all boundary. */
template <typename EngineCall>
Par2ShimResult runEngine(
    Par2ShimLogLine log_line, void *log_context,
    Par2ShimShouldCancel should_cancel, void *cancel_context,
    const EngineCall &call) {
    try {
        LineForwardingBuf outBuf(log_line, log_context, 0, should_cancel, cancel_context);
        LineForwardingBuf errBuf(log_line, log_context, 1, should_cancel, cancel_context);
        std::ostream sout(&outBuf);
        std::ostream serr(&errBuf);
        sout.exceptions(std::ios::badbit);
        serr.exceptions(std::ios::badbit);

        const Result result = call(sout, serr);

        sout.flush();
        serr.flush();
        return static_cast<Par2ShimResult>(result);
    } catch (const CancelledException &) {
        return PAR2SHIM_CANCELLED;
    } catch (const std::ios_base::failure &) {
        /* Portability armor, unreachable on libc++ (its ostream sentry leaves a bad stream
         * as a silent no-op rather than calling setstate, so nothing throws failure here).
         * libstdc++'s sentry DOES setstate(failbit) and throws on an already-bad stream;
         * classify by asking the cancel flag again. */
        if (should_cancel != nullptr && should_cancel(cancel_context) != 0) {
            return PAR2SHIM_CANCELLED;
        }
        return PAR2SHIM_CXX_EXCEPTION;
    } catch (const std::exception &e) {
        if (log_line != nullptr) {
            std::string message = std::string("engine exception: ") + e.what();
            log_line(log_context, message.c_str(), 1);
        }
        return PAR2SHIM_CXX_EXCEPTION;
    } catch (...) {
        if (log_line != nullptr) {
            log_line(log_context, "engine exception: (unknown)", 1);
        }
        return PAR2SHIM_CXX_EXCEPTION;
    }
}

/* Default basepath = canonical directory of the .par2 file — byte-for-byte the default the
 * par2 CLI computes (commandline.cpp). */
std::string resolveBasePath(const char *base_path, const std::string &parfilename) {
    if (base_path != nullptr && base_path[0] != '\0') {
        return DiskFile::GetCanonicalPathname(base_path);
    }
    std::string path, name;
    DiskFile::SplitFilename(parfilename, path, name);
    std::string basepath = DiskFile::GetCanonicalPathname(path);
    if (basepath.empty()) {
        basepath = DiskFile::GetCanonicalPathname("./");
    }
    return basepath;
}

}  // namespace

extern "C" const char *par2shim_version(void) {
    return X_PACKAGE " " X_VERSION;
}

extern "C" Par2ShimResult par2shim_repair(
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
    void *cancel_context) {
    if (par2_path == nullptr || par2_path[0] == '\0') {
        return PAR2SHIM_BAD_PARAMETER;
    }
    if (extra_file_count > 0 && extra_files == nullptr) {
        return PAR2SHIM_BAD_PARAMETER;
    }
    for (size_t i = 0; i < extra_file_count; i++) {
        if (extra_files[i] == nullptr || extra_files[i][0] == '\0') {
            return PAR2SHIM_BAD_PARAMETER;
        }
    }
    return runEngine(
        log_line, log_context, should_cancel, cancel_context,
        [&](std::ostream &sout, std::ostream &serr) -> Result {
            const std::string parfilename(par2_path);
            const std::string basepath = resolveBasePath(base_path, parfilename);
            std::vector<std::string> extrafiles;
            extrafiles.reserve(extra_file_count);
            for (size_t i = 0; i < extra_file_count; i++) {
                extrafiles.emplace_back(extra_files[i]);
            }
            return par2repair(
                sout,
                serr,
                nlNormal,
                memory_limit_bytes != 0 ? memory_limit_bytes : defaultMemoryLimit(),
                basepath,
                /* nthreads: */ threads, /* 0 = automatic, same as the CLI default */
                /* filethreads: */ _FILE_THREADS,
                parfilename,
                extrafiles,
                /* dorepair: */ dorepair != 0,
                /* purgefiles: */ false,
                /* renameonly: */ false,
                /* skipdata: */ false,
                /* skipleaway: */ 0);
        });
}

extern "C" Par2ShimResult par2shim_create(
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
    void *cancel_context) {
    if (par2_path == nullptr || par2_path[0] == '\0' || files == nullptr || file_count == 0 ||
        block_size == 0 || block_size % 4 != 0) {
        return PAR2SHIM_BAD_PARAMETER;
    }
    for (size_t i = 0; i < file_count; i++) {
        /* A hole in the array is always a caller error; silently creating a set that
         * covers fewer files than requested would be the worst failure mode for a
         * data-integrity tool. */
        if (files[i] == nullptr || files[i][0] == '\0') {
            return PAR2SHIM_BAD_PARAMETER;
        }
    }
    Scheme engineScheme;
    switch (scheme) {
        case PAR2SHIM_SCHEME_VARIABLE: engineScheme = scVariable; break;
        case PAR2SHIM_SCHEME_LIMITED: engineScheme = scLimited; break;
        case PAR2SHIM_SCHEME_UNIFORM: engineScheme = scUniform; break;
        default: return PAR2SHIM_BAD_PARAMETER;
    }
    return runEngine(
        log_line, log_context, should_cancel, cancel_context,
        [&](std::ostream &sout, std::ostream &serr) -> Result {
            /* par2create appends ".par2" to the name itself (par2creator.cpp), so mirror the
             * CLI and strip a trailing ".par2" — the caller's path IS the index file. */
            std::string parfilename(par2_path);
            if (parfilename.length() > 5 &&
                stricmp(parfilename.substr(parfilename.length() - 5, 5).c_str(), ".par2") == 0) {
                parfilename = parfilename.substr(0, parfilename.length() - 5);
            }
            const std::string basepath = resolveBasePath(base_path, parfilename);
            std::vector<std::string> extrafiles;
            extrafiles.reserve(file_count);
            for (size_t i = 0; i < file_count; i++) {
                extrafiles.emplace_back(files[i]); /* validated non-null/non-empty above */
            }
            return par2create(
                sout,
                serr,
                nlNormal,
                memory_limit_bytes != 0 ? memory_limit_bytes : defaultMemoryLimit(),
                basepath,
                /* nthreads: */ threads,
                /* filethreads: */ _FILE_THREADS,
                parfilename,
                extrafiles,
                block_size,
                /* firstblock: */ 0,
                engineScheme,
                recovery_file_count,
                recovery_block_count);
        });
}
