---
title: "Reported sizes exclude app-bundle contents that cleanup actually deletes"
labels: [bug, correctness, priority-medium]
---

## Summary

`allocatedSize` enumerates with `.skipsPackageDescendants`, so bytes inside `.app`, `.bundle`,
`.framework`, and similar package directories are never counted. Deletion has no such
exclusion — `removeItem` removes the package and everything in it. Every reported figure
(item size, provider total, "reclaimed" in history) therefore **under-reports** what is
actually removed.

## Evidence

Sizing skips package interiors — `Sources/Services/CleanupProvider.swift:1171-1200`:

```swift
guard let enumerator = fileManager.enumerator(
    at: url,
    includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
    options: [.skipsHiddenFiles, .skipsPackageDescendants]   // <- interior bytes never counted
) else { return 0 }
```

Deletion does not — `Sources/Services/CleanupProvider.swift:1336-1339`:

```swift
for child in children {
    try Task.checkCancellation()
    try fileManager.removeItem(at: child)   // <- removes the whole package, recursively
}
```

Note that `validateTree` (`:1360-1365`) enumerates with `options: []`, i.e. it **does** descend
into packages. So the codebase already walks package interiors for safety validation and
deletion, and excludes them only when measuring.

### Measured

Verified on macOS 26.6.1 with a fixture containing one 4 KB plain file and a `Test.app`
bundle holding one 4 KB file:

```
enumerator with .skipsPackageDescendants listed:
  plain.txt
  Test.app            (interior NOT listed)
allocatedSize total : 4096 bytes
du -sk actual       : 8 KB
```

Half the bytes that deletion removes were invisible to the estimate.

## Impact

- Users choose what to clean based on size. Caches routinely contain bundles — Xcode
  DerivedData holds `.app`/`.framework` build products, Homebrew caches hold `.pkg`/`.app`
  payloads — so the under-count lands squarely on the largest categories.
- `CleanupHistoryStore`'s "reclaimed" totals are correspondingly wrong, permanently.
- The error is silent and always in the same direction, so it never self-corrects.

The README describes sizes as "approximate allocated-byte estimates", which fairly covers
allocation-vs-logical rounding. It does not cover omitting a bundle's entire contents.

## Reproduction

```bash
BASE=/private/tmp/pkgsize
mkdir -p "$BASE/Test.app/Contents/MacOS"
dd if=/dev/zero of="$BASE/plain.txt"                     bs=4096 count=1 2>/dev/null
dd if=/dev/zero of="$BASE/Test.app/Contents/MacOS/big.bin" bs=4096 count=1 2>/dev/null
du -sk "$BASE"     # 8 KB actual; allocatedSize returns 4096
```

## Suggested fix

Drop `.skipsPackageDescendants` from `allocatedSize` so measurement matches deletion:

```swift
options: [.skipsHiddenFiles]
```

`.skipsHiddenFiles` is worth reviewing too — hidden files are also deleted by `removeItem`
but are likewise excluded from the count, producing the same class of under-report.

Add a regression test asserting that a directory containing a package reports the package's
full recursive size.

## Status

**Fixed.** `allocatedSize` now enumerates with `options: []`, matching how `validateTree`
(`CleanupProvider.swift:1364`) and `removeItem` already traverse the tree. Measurement,
validation and deletion now agree.

### Corrections to this report

Two details above were inaccurate and are left in place for the record:

- The quoted call site was `options: [.skipsHiddenFiles, .skipsPackageDescendants]`. The real
  code had only `[.skipsPackageDescendants]` — hidden files were **always** counted, so the
  suggested `options: [.skipsHiddenFiles]` would have *introduced* the second under-report it
  warned about. The fix uses `options: []`.
- The under-report only occurs when a bundle sits **inside** a scanned item. Measured
  directly: with the item root being the bundle itself, `.skipsPackageDescendants` makes no
  difference — the flag does not skip the root's own descendants. That boundary is now pinned
  by `sizeOfBundleItselfCountsItsPayload`.

Discovery (`CleanupProvider.swift:846`) deliberately **keeps** the flag: a `.app` should
surface as one item, not as thousands of internal files.

### Verification

Regression tests in `Tests/PackageSizeAccountingTests.swift`:

- `sizeOfDirectoryIncludesContentsOfNestedBundles` — verified to **fail against the pre-fix
  code** with `Expectation failed: (measured → 4096) == (actuallyOnDisk → 20480)`, an 80%
  under-report.
- `sizeOfBundleItselfCountsItsPayload` — characterises the unaffected boundary case.

Both assert against an independent full traversal rather than a magic constant, so the test
states the invariant (*reported size == space actually freed*) instead of a fixture's number.

Confirmed in the running app against a real cache. `~/Library/Caches/ms-playwright` contains a
`Chromium.app` bundle:

| | Reported |
|---|---|
| before | 204,2 MB |
| after | **206,5 MB** |

The overview now displays `1 item · 206,5 MB`, matching the post-fix measurement exactly.
`~/Library/Caches/org.swift.swiftpm` (no bundles) is unchanged at 638,1 MB, confirming the fix
does not inflate sizes indiscriminately.

No existing test expectation changed: the suite's other size assertions are hand-built
`CleanupItem` fixtures (`allocatedSize: 1`) or stubbed tool output, not filesystem
measurements. The full suite went from 122 to 126 tests, all green.
