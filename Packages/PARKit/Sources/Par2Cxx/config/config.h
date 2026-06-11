/* Hand-written autotools config.h for arm64-apple-darwin (macOS 14+), replacing the
 * ./configure step for the vendored par2cmdline-turbo v1.4.0 build inside SwiftPM.
 * Values mirror what configure produces on this platform (see config.h.in upstream).
 * Committed and pinned per ROADMAP Phase 2 / ARCHITECTURE.md §1.1. */

#ifndef PAR2CXX_CONFIG_H
#define PAR2CXX_CONFIG_H

#define HAVE_CXX14 1
#define HAVE_DECL_POSIX_MEMALIGN 1
#define HAVE_DIRENT_H 1
/* no <endian.h> on macOS */
#define HAVE_FSEEKO 1
#define HAVE_GETOPT 1
#define HAVE_GETOPT_H 1
#define HAVE_GETOPT_LONG 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MEMCPY 1
#define HAVE_PTHREAD 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRCASECMP 1
#define HAVE_STRCHR 1
/* no stricmp on macOS (strcasecmp is used) */
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE__BOOL 1
#define STDC_HEADERS 1

#define PACKAGE "par2cmdline"
#define PACKAGE_BUGREPORT "ike.devolder@gmail.com"
#define PACKAGE_NAME "par2cmdline"
#define PACKAGE_STRING "par2cmdline 1.1.1"
#define PACKAGE_TARNAME "par2cmdline"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "1.1.1"
#define VERSION "1.1.1"
#define X_PACKAGE "par2cmdline-turbo"
#define X_VERSION "1.4.0"

/* arm64-apple-darwin is little-endian; off_t is 64-bit natively. */
/* WORDS_BIGENDIAN intentionally undefined */
#define _LARGEFILE_SOURCE 1

#endif /* PAR2CXX_CONFIG_H */
