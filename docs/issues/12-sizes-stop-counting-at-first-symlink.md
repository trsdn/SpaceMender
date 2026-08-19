---
title: "Reported sizes stop counting at the first symlink inside a scanned tree"
labels: [bug, priority-high]
---

## Summary

`FilesystemProviderSupport.allocatedSize` called `enumerator.skipDescendants()` whenever it met
a symlink. A symlink is not a directory and the enumerator never follows one, so there were no
descendants to skip — instead the call skipped the remainder of the **enclosing** directory,
silently dropping every sibling enumerated after the link.

macOS framework bundles place `Resources`, `Versions/Current`, `Libraries` and `Helpers`
symlinks directly beside the payload, so any cached `.app` or `.framework` loses most of its
measured size.

## Evidence

Found by reconciling the running app against the filesystem: the app reported the Playwright
cache as **206,5 MB** where `du` reported **541 MiB**.

Reproduced with the app's own algorithm, run standalone over the real cache:

```
MIT skipDescendants : 206 MB  (103 Dateien)
OHNE skipDescendants: 564 MB  (365 Dateien)
```

206 MB matches the app's display exactly, and 365 matches `find . -type f | wc -l`. So the app
was not counting **262 of 365 files** — 63% of the category.

The five symlinks responsible all sit in one directory:

```
chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/Frameworks/
  Google Chrome for Testing Framework.framework/
    Resources        -> symlink   (enumerated first)
    Versions         -> the entire payload, skipped
    Libraries        -> symlink
    Google Chrome for Testing Framework -> symlink
    Helpers          -> symlink
```

## Impact

The number the app shows is a promise about how much space cleanup will free. Deletion
(`removeItem`) removes the whole tree regardless, so the user was told they would recover
206,5 MB and would actually have recovered 564,7 MB.

On this machine only Playwright was affected, because it is the only cached tree containing a
macOS bundle. That understates the general severity: **Xcode DerivedData** and **unavailable
simulators** are full of `.app` and `.framework` products on any real development machine, and
both are scanned by the same code path.

This is the same defect class as issue #06 — reported size diverging from deleted size — which
that fix did not reach.

## Fix

Delete the `skipDescendants()` call. The `continue` alone is correct and sufficient: the
enumerator is created without `.resolvesSymlinks`, so it never descends into a symlink in the
first place, and the link itself contributes no bytes.

## Status

**Fixed** — `Sources/Services/CleanupProvider.swift`, `allocatedSize(of:fileManager:)`.

### The first regression test was wrong, and passed against the broken code

The initial fixture put a symlink beside a payload directory and asserted the payload was
counted. It passed **both** before and after the fix, which the red-proof caught. Reproducing
the bug requires two conditions that were not obvious:

1. **The symlink must be inside a subdirectory of the scanned root.** `skipDescendants()` after
   an entry at the top level of the enumeration does nothing at all.
2. **The symlink must be enumerated before the payload**, since it skips what follows.

Both are now encoded in `FrameworkLikeFixture`, and `preconditionHolds()` asserts condition 2
instead of trusting it — otherwise the suite could go green on a filesystem that returns the
entries the other way round and quietly stop guarding anything.

### Verification

- `Tests/AllocatedSizeSymlinkTests.swift` — 3 tests on **real** on-disk symlinks. A stubbed
  `FileManager` would model the enumerator behaviour we wish it had and prove nothing.
- `symlinkTargetOutsideTheTreeIsNotCounted` guards issue #02's invariant in the other
  direction: the link is skipped, never resolved, so the size never claims space that deleting
  this root would not free.
- Red-proofed behaviourally after the fixture was corrected: restoring `skipDescendants()`
  produced genuine expectation failures (`measured → 0` against an expected `65536`), not
  compile errors.
- Verified in the running app: the Playwright cache went from **206,5 MB** to **564,7 MB**,
  matching the independently measured 564,690,944 bytes. No other category changed.
