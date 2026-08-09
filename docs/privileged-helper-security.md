# Defender privileged helper security model

SpaceMender remains outside the App Sandbox because its providers inspect
several user-owned developer and application cache roots. Those providers stay
in the unprivileged app process. Only deletion of root-owned Microsoft Defender
diagnostic ZIP archives crosses the privilege boundary.

## Trust model and trusted roots

The unprivileged app trusts only the roots and vendor commands declared by its
registered providers. The privileged helper has exactly one production trusted
root:

```text
/Library/Application Support/Microsoft/Defender/wdavdiag
```

That root is compiled into the shared contract and production validation
configuration. It is not supplied by the UI, preferences, environment, or XPC
request. Test configurations may use isolated fixture roots, but normal tests
never address the production directory.

## Boundary

- The helper is a separate hardened-runtime product installed as a launch
  daemon by `SMAppService`.
- Its XPC interface accepts encoded `DefenderCandidateIdentity` values only.
  The contract has no arbitrary path, executable, argument, or shell-command
  field.
- The helper derives the connecting process identity from the XPC connection
  audit token and checks it against the configured designated signing
  requirement for `app.spacemender.SpaceMender` and the expected signing-team
  OU. Missing, ad-hoc, unknown, or mismatched clients fail closed before a
  cleanup operation is accepted.
- The helper reports only item status and generic safety messages. Unified logs
  contain aggregate counts, not archive names or paths.

## Independent validation

The production validator always uses
`/Library/Application Support/Microsoft/Defender/wdavdiag` and requires UID 0.
For each selected filename it:

1. rejects separators, traversal, empty names, and non-ZIP names;
2. opens the fixed root and archive with `O_NOFOLLOW`;
3. verifies a regular file, root ownership, and canonical parent root;
4. compares device/inode resource identity and modification time with the scan;
5. confirms the file was already older than the scan's retention cutoff; and
6. calls `unlinkat` relative to the already opened root descriptor.

Changed, missing, recent, symlinked, replaced, or unverifiable candidates are
skipped or rejected per item.

The app also revalidates provider identity before calling the helper. Helper
validation is authoritative and is deliberately duplicated rather than
trusting the scan or app process. This narrows, but cannot mathematically
eliminate, all filesystem time-of-check/time-of-use races.

## Prohibited privileged operations

The helper cannot:

- receive or execute a shell command, executable, argument list, or script;
- delete an arbitrary path or accept a caller-selected root;
- recursively clean the Defender product tree;
- remove Defender definitions, quarantine data, databases, or configuration;
- clean user caches, logs, simulators, Homebrew, browser data, system caches,
  Docker volumes, backups, APFS snapshots, or `/private/var`;
- authorize a caller based only on a process name, PID, or claimed bundle ID.

User-owned cleanup remains in the current-user app process. Adding another
privileged operation requires a new fixed-operation contract and independent
validation; the Defender API must not be generalized.

## Local verification limitation

Unsigned builds cannot complete the real Service Management approval and
audit-token signing handshake. They therefore remain explicitly scan-only.
Automated tests exercise the XPC data contract, fail-closed authorization
policy, and validator/removal logic only with unique temporary roots. No test
invokes deletion under the production Defender directory.

For a signed test, build both products with the same Developer ID team, install
or upgrade through **SpaceMender → Settings → Microsoft Defender helper**,
approve the daemon in System Settings if requested, refresh until the client
reports ready, and use **Remove Helper** during uninstall. A successful local
unit test or unsigned release dry run is not evidence that the production XPC
signing handshake, Service Management approval, or Apple notarization passed.
