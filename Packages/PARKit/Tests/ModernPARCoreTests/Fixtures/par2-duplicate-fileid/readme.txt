Crafted PAR2 index files whose Main packet lists one File ID more than once.

Both were built from a normal two-file set (par2 c -s4096 -c5 set.par2 data.bin good.bin)
by rewriting the Main packet's File ID list and re-emitting every packet under the
recomputed set ID = MD5(main body), so both the native parser and the engine accept them.

  repeated-in-recovery.par2 — data.bin's File ID appears TWICE in the recovery list
                              (recoverable count 3, one object at two indices).
  listed-in-both.par2       — data.bin's File ID is in the recovery list AND the
                              non-recovery list.

Why they are here: the vendored engine builds one Par2RepairerSourceFile per Main entry by
looking each File ID up in a map, so a repeat puts the SAME object at two indices. It then
counts that file's blocks twice, opens its path on two file threads (the diskFileMap guard
is a non-atomic find-then-insert whose assert is compiled out under NDEBUG), and during a
repair walks past the end of its block vectors — a SIGSEGV, in-process, after the repair has
already rewritten user files. An intact set can also be reported as damaged.

ModernPAR therefore refuses such a set in EngineRunSupport.paintRoster (rejectionReason)
before the engine opens it; MalformedSetGuardTests pins that. The data files are deliberately
NOT committed: the guard fires from the index alone, so the tests cannot reach the crash.
