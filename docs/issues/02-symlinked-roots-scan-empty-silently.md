---
title: "Relocated (symlinked) cache roots silently scan as empty with no warning"
labels: [bug, ux, priority-medium]
---

## Summary

If a declared root is a **symlink to a directory** — a common developer setup for relocating
large caches to another volume — SpaceMender silently reports zero items. There is no
warning, no error, and no diagnostic. The provider simply appears to have nothing to clean.

## Scope note (important)

This is **not** a safety hole. It is the opposite: `FileManager` refuses to enumerate
through a symlinked directory root, so no items are ever produced and nothing outside the
declared root can be deleted. The defect is that this fail-closed behaviour is **invisible**
to the user, who is told "Nothing to clean" when the real answer is "this root is a symlink
and I cannot look inside it."

## Evidence

Verified on macOS 26.6.1 using a non-symlinked base path (`/private/tmp`, to avoid the
`/tmp -> /private/tmp` confounder):

```
root: /private/tmp/smtest2/home/Logs   (symlink -> /private/tmp/smtest2/real_target)
fileExists: true
root isSymbolicLink: true   isDirectory: false
contentsOfDirectory ERROR: 256 The file "Logs" couldn't be opened.  (POSIX 20 ENOTDIR)
enumerator -> []
```

The scan gate only asks whether the path exists — `Sources/Services/CleanupProvider.swift:835`:

```swift
for location in rule.locations where fileManager.fileExists(atPath: location.path) {
```

`fileExists` **follows** symlinks and returns `true`, so the loop body runs. Enumeration
then yields nothing:

- recursive branch, `Sources/Services/CleanupProvider.swift:843-850` — `enumerator` returns an
  empty sequence (the `errorHandler` returns `true`, continuing past the failure).
- non-recursive branch, `Sources/Services/CleanupProvider.swift:858` — `contentsOfDirectory`
  throws `NSCocoaErrorDomain 256`, which propagates as a scan failure for that provider.

## Impact

Developers frequently relocate exactly these directories to an external or larger volume:

```bash
mv ~/Library/Developer/Xcode/DerivedData /Volumes/Fast/DerivedData
ln -s /Volumes/Fast/DerivedData ~/Library/Developer/Xcode/DerivedData
```

For those users, DerivedData / cache providers report "Nothing to clean" indefinitely. The
app looks like it works but silently covers none of the disk space the user cares about —
which is the entire purpose of the tool.

The two branches are also **inconsistent**: recursive providers (user logs) silently show
zero items, while non-recursive providers surface an opaque "couldn't be opened" scan error.

## Reproduction

```bash
BASE=/private/tmp/demo
mkdir -p $BASE/real $BASE/home && touch $BASE/real/old.log
ln -s $BASE/real $BASE/home/Logs
# point a rule location at $BASE/home/Logs -> scan yields 0 items, no warning
```

## Suggested fix

Detect a symlinked declared root explicitly and surface it as a provider **warning**, rather
than letting it degrade into an empty result:

1. In the scan loop, read `.isSymbolicLinkKey` for each `rule.locations` entry.
2. If the root is a symlink, emit a warning such as
   *"`~/Library/Logs` is a symbolic link. SpaceMender only scans real directories, so this
   location was skipped."* — `OverviewProviderResult.warnings` already exists and renders.
3. Make both branches behave the same way instead of one silently returning `[]` and the
   other throwing an opaque Cocoa error.

If following relocated roots is desired later, that is a separate feature and must come with
its own containment design — do **not** simply resolve the root, since that would weaken the
fixed-canonical-root guarantee.
