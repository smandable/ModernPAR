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

/* Mirrors the CLI's default (commandline.cpp): half of physical RAM, computed in whole
 * megabytes. GetTotalPhysicalMemory lives in the excluded CLI translation unit, so the
 * macOS sysctl is queried directly here. */
size_t defaultMemoryLimit() {
    unsigned long long physical = 0;
    size_t length = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &length, nullptr, 0) != 0 || physical == 0) {
        physical = 256ULL * 1048576;  /* the CLI's fallback floor */
    }
    return static_cast<size_t>(physical / 1048576 / 2) * 1048576;
}

/* Forwards each complete line written by the engine to the C callback. */
class LineForwardingBuf : public std::stringbuf {
public:
    LineForwardingBuf(Par2ShimLogLine callback, void *context, int isError)
        : callback_(callback), context_(context), isError_(isError) {}

    ~LineForwardingBuf() override { flushPending(); }

protected:
    int sync() override {
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
};

}  // namespace

extern "C" const char *par2shim_version(void) {
    return X_PACKAGE " " X_VERSION;
}

extern "C" Par2ShimResult par2shim_repair(
    const char *par2_path,
    const char *base_path,
    unsigned threads,
    size_t memory_limit_bytes,
    int dorepair,
    Par2ShimLogLine log_line,
    void *log_context) {
    if (par2_path == nullptr || par2_path[0] == '\0') {
        return PAR2SHIM_BAD_PARAMETER;
    }
    try {
        const std::string parfilename(par2_path);

        /* Default basepath = canonical directory of the .par2 file — byte-for-byte the
         * default the par2 CLI computes (commandline.cpp). */
        std::string basepath;
        if (base_path != nullptr && base_path[0] != '\0') {
            basepath = DiskFile::GetCanonicalPathname(base_path);
        } else {
            std::string path, name;
            DiskFile::SplitFilename(parfilename, path, name);
            basepath = DiskFile::GetCanonicalPathname(path);
            if (basepath.empty()) {
                basepath = DiskFile::GetCanonicalPathname("./");
            }
        }

        LineForwardingBuf outBuf(log_line, log_context, 0);
        LineForwardingBuf errBuf(log_line, log_context, 1);
        std::ostream sout(&outBuf);
        std::ostream serr(&errBuf);

        const std::vector<std::string> extrafiles;  /* no extra files for verify/repair */
        const Result result = par2repair(
            sout,
            serr,
            nlNormal,
            memory_limit_bytes != 0 ? memory_limit_bytes : defaultMemoryLimit(),
            basepath,
            /* nthreads: */ threads,  /* 0 = automatic, same as the CLI default */
            /* filethreads: */ _FILE_THREADS,
            parfilename,
            extrafiles,
            /* dorepair: */ dorepair != 0,
            /* purgefiles: */ false,
            /* renameonly: */ false,
            /* skipdata: */ false,
            /* skipleaway: */ 0);

        sout.flush();
        serr.flush();
        return static_cast<Par2ShimResult>(result);
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
