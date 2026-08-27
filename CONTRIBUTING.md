# Contributing

Issues and pull requests are welcome. Keep changes focused and never include
real personal filesystem paths, usernames, hostnames, credentials, or private
network details in reports, fixtures, or logs.

Working with a coding agent? [`AGENTS.md`](AGENTS.md) carries the same rules in
the form agents read, plus the component layout and the verified commands.

## Development setup

Requirements:

- macOS 14 or newer
- Xcode with the macOS 14 SDK and Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

`project.yml` is canonical; do not hand-edit the generated project.

```bash
xcodegen generate
xcodebuild \
  -project SpaceMender.xcodeproj \
  -scheme SpaceMender \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  test
./scripts/build-app.sh
```

> **Run `xcodegen generate` after adding or removing any source or test file.**
> `xcodebuild` does not run XcodeGen. A test file that is missing from the
> generated project is skipped silently: the run still reports
> `** TEST SUCCEEDED **`, just without your tests. The tell is the absence of
> `◇ Test … started` lines for the new file, so check the count, not the exit
> code.

Tests use fixtures and isolated temporary roots. The suite must never delete
from the production Defender directory, address a real user cache root, or
exercise real Service Management approval.

## Adding a cleanup provider

Providers are the security surface of this app, so a new one touches more than
its own file. The contract is described in
[`docs/architecture-and-provider-contract.md`](docs/architecture-and-provider-contract.md);
in short, a provider must declare exact roots or vendor commands, candidate
identity, selection and deletion policy, running-application conflicts,
revalidation, user-facing consequences, and fixture tests. It must fail closed
for symbolic links, path escapes, changed resources, unreadable items, and
unknown state.

A new rule needs updates in five places:

1. the `CleanupRule` definition in `Sources/Models/CleanupRule.swift`
2. `CleanupProviderCatalog.builtIn` **and** `builtInOrder`
3. the `builtInRulesPreserveSupportedCleanupRoots` guard test, which is
   designed to fail so that catalog changes are deliberate rather than
   accidental
4. the provider table in `README.md`
5. the matching section in `docs/user-guide.md`

Prefer `.moveToTrash` whenever the deleted data could represent work in
progress rather than regenerable cache.

## Pull requests

Describe user-visible behavior and security implications. Add tests for
behavior changes and update the README, user guide, or changelog when
appropriate.

**Prove that a regression test fails without the fix.** Revert the change,
confirm the new test goes red for the reason you expect, then restore it. A
test that never failed has not been shown to test anything. Watch for three
failure modes seen in this repository: a revert that removes a symbol produces
a *compile* error rather than a test failure; a revert can make a test *hang*
instead of fail; and a fixture can be too weak to reproduce the bug at all, in
which case the "red" proof stays green.

CI builds the app and runs the full suite on macOS, and scans the repository
for secrets. There is no release workflow: signing and notarization credentials
do not belong in a repository that runs contributor code. Signed releases are
produced by [`trsdn/macos-notarization-broker`](https://github.com/trsdn/macos-notarization-broker);
see [`docs/release-security-and-operations.md`](docs/release-security-and-operations.md#automated-notarization).

Changing the app bundle layout, the bundle identifier, the helper's code
identity, or its launch daemon plist will fail that broker's preflight until the
matching profile is updated. That is deliberate — the profile is what lets a
secretless job describe exactly what the privileged job is allowed to sign.
