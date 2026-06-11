/* Unity-include wrapper: compiles the vendored par2 CLI entry point unmodified into the
 * `par2helper` executable. SPM targets cannot share source files, and copying the file would
 * fork it from the pinned vendor tree — a textual include keeps one source of truth.
 * (ARCHITECTURE.md §1.1: the bundled-CLI fallback / standby GPL license firewall.)
 * SPDX-License-Identifier: GPL-2.0-or-later */
#include "../Par2Cxx/vendor/src/par2cmdline.cpp"
