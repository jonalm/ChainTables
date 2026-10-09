---
status: accepted
---

# A prefix segment is portable to every filesystem

The record cache stores a record at `cache.dir/<bucket>/<key segments…>` (since
ADR-0040, `cache.dir/<namespace>/<bucket>/<key segments…>`), one
directory per `/`-separated segment of the slot key (ADR-0010, ADR-0011). So
every segment of a chain's prefix, and the bucket name, must be a valid
directory name on every platform a client might run on. ChainTables targets
Linux, macOS and Windows. Issue #71.

## The rule

A segment, of the prefix or of the bucket name:

- is non-empty;
- uses only lowercase ASCII `a-z`, digits `0-9`, `.`, `_` and `-`;
- is not `.` or `..`;
- does not end in `.`;
- is not a Windows device name (`con`, `prn`, `aux`, `nul`, `com0`–`com9`,
  `lpt0`–`lpt9`), with or without an extension (`nul.txt`).

`Chain(...)` checks the prefix and bucket before any I/O. Before this rule,
`create_chain` could put slot 0 and then fail to cache it, which left a chain
that no client could read. `record_path` applies the same check
(`portable_segment_problem`), so the two can never disagree.

## Why each part

- **`.`, `..` and the empty segment** would leave the cache or collapse into the
  parent directory. libcurl also normalizes dot segments in the URL.
- **`\` and `:`** are path syntax on Windows. With them, a segment such as
  `C:x` or `a\..\..` makes `joinpath` resolve outside the cache.
- **`*?"<>|`, control characters and a trailing `.` or space** are refused or
  silently rewritten by Windows.
- **Device names** open a device rather than a file on Windows, in any
  directory.
- **Uppercase** would let two prefixes (`a/B`, `a/b`) share a cache directory
  on the case-insensitive filesystems that macOS and Windows use by default.
  The read path rehashes every record, so a collision would be detected, but
  only as a failure.
- **Non-ASCII** is subject to Unicode normalization on macOS, where `é` may be
  stored as either one code point or two.

## Path length

Windows refuses a path over `MAX_PATH`: 259 UTF-16 code units plus the
terminating NUL, unless long paths are enabled, which ChainTables cannot assume.
Two limits apply, on every platform:

- **The prefix is at most 100 characters.** The prefix is shared by every
  machine that opens the chain, but the cache directory is local, so a chain
  must be openable under any reasonable `cache_dir`. With a 63-character bucket
  (S3's longest), the path below `cache_dir` is at most 63 + 1 + 100 + 1 + 20 =
  185, which leaves 74 for `cache_dir`. *Amended by ADR-0040*: the store's cache
  namespace, at most 12 characters, comes first, so the path below `cache_dir`
  is at most 198 and 61 are left for it. The Windows default,
  `C:\Users\<user>\.julia\chaintables\records`, is about 40 plus the user
  name.
- **The longest cache path is at most 259 UTF-16 code units.** This is checked
  by `record_path` and, before any I/O, by `Chain(...)` for slot 0. Every slot
  key has the same length, so one check covers them all. "Longest" means the
  absolute directory plus the longer of the record's 12-digit name and the
  temporary file it is written to first, which is now a fixed
  `<16 hex>.tmp` (20 characters) instead of `tempname`'s platform-dependent
  name. The directory is then at most 238, under Windows' 248 limit for
  creating a directory.

Both checks run on Linux and macOS as well, so a cache directory that would
fail on Windows also fails there. The cache directory is local, and that is
the price of one rule everywhere.

An allowlist is used, not a denylist, so that a platform quirk we have not
listed cannot slip through.

## Considered options

- **Refuse only the problem characters on Windows.** Rejected: a chain created
  on Linux at `a:b` would be unreadable from a Windows client, which is the
  bug from #71 again.
- **Encode or hash keys into cache paths, so any key is allowed.** The cache
  is disposable, so this costs no data. Rejected for now in favour of a short,
  explainable rule: the user preferred simplicity to functionality.

## Consequences

- **ADR-0031 is amended**: the prefix is opaque *within this alphabet*. No
  segment means anything, but not every string is a prefix.
- A chain created at a prefix that breaks the rule can no longer be opened by a
  client. No such chain is known to exist.
- A cache directory longer than about 61 characters (74 before ADR-0040) can refuse a long prefix
  that another machine accepted. The error names the path and its length.
