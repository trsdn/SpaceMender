# AGENTS.md

Working notes for coding agents in this repository. Everything below was run on
macOS 26.6 with Xcode 26.6 (Swift 6.3.3) before it was written down.

SpaceMender is a native macOS disk-cleanup app: a SwiftUI application plus a
separate privileged helper tool that deletes validated Microsoft Defender
archives. The helper is why this repository is stricter than its size suggests —
a careless change here deletes a user's files with root privileges.

## Toolchain

- macOS 14 or newer (deployment target is `macOS 14.0`)
- Xcode with the macOS 14 SDK and Swift 6 (`SWIFT_VERSION: "6.0"` in `project.yml`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

CI pins `runs-on: macos-26` rather than `macos-latest`, deliberately: for an
Xcode project a silent runner-image bump is a toolchain change.

## Commands

### Regenerate the project — do this first, and after every file add or remove

```bash
xcodegen generate
```

`project.yml` is canonical. **Never hand-edit `SpaceMender.xcodeproj`**; it is
generated and your edit will be overwritten.

### Test

```bash
xcodegen generate
xcodebuild \
  -project SpaceMender.xcodeproj \
  -scheme SpaceMender \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Verified: `** TEST SUCCEEDED **`, 158 tests in 28 suites, ~24 s.

### Build the app bundle

```bash
./scripts/build-app.sh
```

Verified: `** BUILD SUCCEEDED **`. This script runs `xcodegen generate` itself
and writes `build/Build/Products/Debug/SpaceMender.app`.

### Unsigned release rehearsal (no credentials needed)

```bash
./scripts/package-release.sh --dry-run
```

Verified: `** ARCHIVE SUCCEEDED **`, then structure verification and
`release-artifacts/SpaceMender.zip`. This output is **not** signed or notarized
and must never be described as either.

### Lint

There is no SwiftLint or SwiftFormat configuration in this repository — do not
add one as a drive-by change. What CI actually enforces is:

```bash
# The privacy check from .github/workflows/ci.yml, runnable locally:
git grep -nE '/Users/[A-Za-z0-9._-]+' -- . | grep -vE '/Users/(example|person)\b'
```

Any output means CI will fail. The Swift 6 compiler (strict concurrency) and
`gitleaks` in `.github/workflows/secret-scan.yml` are the rest of the gate.

## The silent-skip trap

`xcodebuild` does not run XcodeGen. A test file that is missing from the
generated project **is skipped silently** — the run still prints
`** TEST SUCCEEDED **`, just without your tests.

> Check the test count, not the exit code. If you added a test file and the
> total is still 158, your tests did not run. The other tell is the absence of
> `◇ Test … started` lines for the new file.

## Architecture

`Sources/` is the app, `HelperSources/` is the privileged helper, and
`Sources/PrivilegedHelperShared/` is the XPC contract and validator compiled
into **both** targets.

| Piece | Responsibility |
| --- | --- |
| `AppViewModel` + `Views/` | Navigation, selection, confirmation, progress, history — main actor |
| `CleanupProviderCatalog` | The only built-in provider registry (`builtIn` + `builtInOrder`) |
| `OverviewScanCoordinator` | Scans up to three providers concurrently; keeps good results when one fails |
| `CleanupProvider` | Per-rule discovery, validation, planning, execution, safety metadata |
| `FilesystemProviderSupport` | Shared root validation, resource identity, sizing, Trash, per-item outcomes |
| `ProcessRunner` | Bounded stdout/stderr capture, timeout, cancellation for vendor commands |
| `OverviewCleanupExecutor` | Executes the frozen cross-provider plan |
| `CleanupHistoryStore` | Path-free aggregate records in Application Support |
| `DefenderPrivilegedHelperClient` | The sole privileged boundary; helper re-authorizes and re-validates before unlinking |

Three targets are declared in `project.yml`: `SpaceMender` (app),
`SpaceMenderDefenderHelper` (tool, embedded into the app by a post-build
script), and `SpaceMenderTests`.

## Conventions

**Safety is the product.** Providers fail closed for symlinks, path escapes,
changed resources, unreadable items, and unknown state. Prefer `.moveToTrash`
whenever deleted data could be work in progress rather than regenerable cache.
Never widen a provider root to inflate a space estimate.

**A new cleanup rule touches five places**, per `CONTRIBUTING.md`:

1. the `CleanupRule` definition in `Sources/Models/CleanupRule.swift`
2. `CleanupProviderCatalog.builtIn` **and** `builtInOrder`
3. the `builtInRulesPreserveSupportedCleanupRoots` guard test — it is designed
   to fail so catalog changes are deliberate
4. the provider table in `README.md`
5. the matching section in `docs/user-guide.md`

Read [`docs/architecture-and-provider-contract.md`](docs/architecture-and-provider-contract.md)
before adding a provider; it lists the ten-point contract and required tests.

**Prove a regression test fails without the fix.** Revert the change, confirm
the test goes red for the reason you expect, restore it. Three failure modes
seen in this repository: a revert that removes a symbol gives a *compile* error
rather than a test failure; a revert can make a test *hang* rather than fail;
and a fixture can be too weak to reproduce the bug, leaving the "red" proof
green.

**Never publish personal paths.** Use `/Users/example` in documentation and
`/Users/person` in fixtures. CI rejects anything else.

**Tests use isolated fixture roots.** The suite must never delete from the
production Defender directory, address a real user cache root, or exercise real
Service Management approval.

**Never commit build output.** `build/`, `build-release/`, `release-artifacts/`,
and `DerivedData/` are gitignored — keep it that way.

Update `CHANGELOG.md` under `## [Unreleased]` for user-visible changes.

## Releases — read before adding a workflow

**There is deliberately no release workflow in this repository, and none should
be added.** Signing needs a Developer ID certificate and notarization
credentials, and those do not belong in a repository that runs contributor code.

Signed releases are produced by
[`trsdn/macos-notarization-broker`](https://github.com/trsdn/macos-notarization-broker),
a manually dispatched broker that builds in a secretless job, validates on a
second secretless runner, and only then signs in a protected environment.
SpaceMender is onboarded as the `spacemender` profile.

That broker pins the helper's exact bundle-relative path, code identifier,
launch daemon `Label`/`BundleProgram`, and per-file SHA-256. **Changing the app
bundle layout, the bundle identifier, the helper's code identity, or its launch
daemon plist will fail the broker preflight until the matching profile is
updated.** That is intended. If you make such a change, say so explicitly in the
pull request description.

See [`docs/release-security-and-operations.md`](docs/release-security-and-operations.md)
and [`docs/release-checklist.md`](docs/release-checklist.md).
