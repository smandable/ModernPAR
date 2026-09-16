Two PAR2 sets over the same three files, one written by the engine ModernPAR shipped through
v1.0.1 and one by the engine on main. They differ in exactly one thing: the affected set's
slice checksums are shifted by an empty member.

  affected/  data.par2 + volumes + a.bin, b.bin, empty-ae7 — the set ModernPAR 1.0.1 wrote.
  fixed/     data.par2 only — the same three members through the engine on main (turbo patch
             6). The index alone carries every FileDesc and IFSC packet, so it is all the
             parser needs; no data files, no volumes.

How they were made (both with par2shim_create, block size 4096, 4 recovery blocks, files
a.bin 40960 bytes, b.bin 20000 bytes, and the 0-byte empty-ae7):

  git archive 8f59931 Packages/PARKit | tar -x -C <scratch>      # the pre-fix engine
  swift build --product <driver> --scratch-path <scratch>/build  # affected/
  # and the same from HEAD for fixed/

The name "empty-ae7" is not arbitrary. An empty file's File ID is MD5(MD5("") ‖ 0 ‖ name), so
it depends only on the name, and Main-packet File IDs sort as little-endian 128-bit integers
(NOT memcmp). "empty-ae7" sorts first — which is what triggers the defect.

What goes wrong: libpar2's Par2Creator::ProcessData walks its source files and its block
iterator in lockstep, but a 0-byte file owns no blocks. Every member sorting after one had its
IFSC slice checksums and its FileDesc whole-file MD5 written a block late, and the slots at the
end of the last member were never written at all — they stay as the zeroed packet body. So
affected/data.par2's a.bin carries 10 IFSC entries of which the LAST is an all-zero MD5 with
CRC 0, while fixed/data.par2's a.bin carries 10 real ones. Verified with the vendored
Par2HelperCLI: the affected set reports both a.bin and b.bin damaged over byte-identical data
and says "Repair is possible"; a repair then renames the intact originals to name.1, writes
shifted copies over them, and ends "Repair Failed." The fixed set reports "All files are
correct".

That all-zero trailing entry is the detection signature (Par2RecoverySet.emptyFileDefect): no
real slice hashes to an all-zero MD5, and a set whose empty member sorts LAST — or one written
on the multi-pass path for blocks over 32 MiB — has none and is perfectly good. Sets like this
one are already out in the field, which is why the parser recognizes one and the app refuses to
repair against it. EmptyFileDefectTests pins both directions.
