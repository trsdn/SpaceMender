# Architecture and provider contribution contract

## Components

- SwiftUI views and `AppViewModel` own navigation, selection, confirmation,
  progress, history presentation, and stale-task suppression on the main
  actor.
- `CleanupProviderCatalog` is the only built-in provider registry.
- `OverviewScanCoordinator` scans up to three providers concurrently and keeps
  successful provider results when another provider is unavailable or fails.
- Each `CleanupProvider` owns discovery, validation, execution planning,
  execution, availability, running-app behavior, preview metadata, and safety
  metadata.
- `FilesystemProviderSupport` centralizes fixed-root validation, resource
  identity checks, size calculation, running-app blocking, Trash operations,
  root-preserving contents deletion, and per-item outcomes.
- `ProcessRunner` provides bounded stdout/stderr capture, timeout,
  cancellation, termination, and structured process results.
- `OverviewCleanupExecutor` executes the frozen cross-provider plan and emits
  provider/item progress.
- `CleanupHistoryStore` writes path-free aggregate records to the user
  Application Support directory.
- `DefenderPrivilegedHelperClient` is the sole privileged app boundary. The
  helper repeats authorization and archive validation before unlinking.

`project.yml` is the canonical XcodeGen source. `SpaceMender.xcodeproj` is
generated from it. The helper builds from `HelperSources` plus the shared XPC
contract/validator in `Sources/PrivilegedHelperShared`.

## Provider contract

A new provider must supply a stable unique rule ID and implement
`CleanupProvider`. It must define:

1. **Exact scope:** fixed canonical roots or a named vendor executable and
   fixed argument shape. User configuration may narrow or locate a vendor
   installation; it must not turn into arbitrary path/command input.
2. **Candidate identity:** stable provider ID, item identity, discovery time,
   modification time, cleanup policy, and filesystem resource identity where
   available.
3. **Discovery:** cancellable, symlink-safe enumeration that does not modify
   disk. Provider failure must be isolated and user-facing.
4. **Retention:** an explicit provider default and supported choices, or no age
   control. Never borrow another provider’s retention value.
5. **Safety metadata:** whether data is regenerable, whether privilege is
   required, the exact cleanup policy, and plain-language consequences.
6. **Running-app behavior:** bundle identifiers and process names whose active
   state blocks selection as safe and blocks execution.
7. **Validation:** repeat provider/policy, canonical-root, type, symlink,
   existence, modification, age, and resource-identity checks immediately
   before acting. Unknown state fails closed.
8. **Execution:** honor only items in the immutable plan. Return per-item
   cleaned, moved-to-Trash, changed/skipped, failed, or cancelled outcomes.
9. **Accounting:** return approximate allocated size or explicitly mark it
   unknown. Never report Trash bytes as permanent reclamation.
10. **User impact:** explain rebuild/download cost, recovery path, required
    permissions, and whether an external vendor tool owns the operation.

Use the shared filesystem, process, or privileged-operation implementation
when it exactly fits. Do not add a central scanner/executor switch; register
the implementation in `CleanupProviderCatalog.builtIn` and add its ID to the
presentation order.

## Required tests

Every provider contribution must cover:

- exact roots and allowed types;
- path escape, traversal, symlink, missing, unreadable, and changed-resource
  rejection;
- retention boundaries when supported;
- identity preservation between scan and execution;
- exact selection (deselected candidates remain untouched);
- running-app behavior;
- cancellation and partial outcomes;
- root preservation for contents-only cache cleanup;
- Trash versus permanent/vendor accounting;
- unknown estimate behavior when parsing is not reliable;
- user-facing consequences and provider registration.

Vendor-command providers need fixtures for missing tools, nonzero exit,
stderr/warnings, timeout/cancellation, large output, and localized or
unparseable output. Privileged providers additionally need XPC contract,
unauthorized-client, protocol-version, and isolated-root validator tests.
Destructive tests must use isolated test-owned fixture roots and must never
point at production cleanup locations.

## Prohibited provider designs

Do not contribute providers that:

- accept arbitrary paths, commands, shell fragments, or elevated scripts;
- clean broad system directories, `/private/var`, arbitrary caches, Docker
  volumes, device backups, APFS snapshots, or browser profile data;
- follow symlinks outside a declared root;
- silently select candidates after a scan;
- infer safety from a category name instead of explicit metadata;
- delete a cache root when contents-only cleanup is declared;
- bypass running-app or changed-since-scan protection;
- turn a scan estimate or free-space delta into a guaranteed claim;
- require network upload of paths, filenames, contents, or cleanup history.

Any expansion of trusted roots or privilege requires a security-model update,
tests, user-facing documentation, and release-review evidence.
