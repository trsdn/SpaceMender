# Defender privileged helper security model

SpaceMender remains outside the App Sandbox because its providers inspect
several user-owned developer and application cache roots. Those providers stay
in the unprivileged app process. Only deletion of root-owned Microsoft Defender
diagnostic ZIP archives crosses the privilege boundary.

## Boundary

- The helper is a separate hardened-runtime product installed as a launch
  daemon by `SMAppService`.
- Its XPC interface accepts encoded `DefenderCandidateIdentity` values only.
  The contract has no arbitrary path, executable, argument, or shell-command
  field.
- Foundation applies the configured designated signing requirement to the
  peer's XPC audit token before the listener delegate receives the connection.
  Missing or mismatched requirements fail closed.
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

## Local verification limitation

Unsigned builds cannot complete the real Service Management approval and
audit-token signing handshake. They therefore remain explicitly scan-only.
Automated tests exercise the XPC data contract, fail-closed authorization
policy, and validator/removal logic only with unique temporary roots. No test
invokes deletion under the production Defender directory.

For a signed test, set `DEVELOPMENT_TEAM`, sign both targets with the same
Developer ID Application identity, build the app, call
`DefenderHelperServiceManager.installOrUpgrade()`, approve the daemon in System
Settings if requested, verify `DefenderPrivilegedHelperClient` reports
`ready`, and use `DefenderHelperServiceManager.remove()` during uninstall.
