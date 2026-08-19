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
