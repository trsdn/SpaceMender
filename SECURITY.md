# Security Policy

## Supported versions

Security fixes are provided for the latest published release.

## Reporting a vulnerability

Please report suspected vulnerabilities through a
[private GitHub Security Advisory](https://github.com/trsdn/SpaceMender/security/advisories/new)
for this repository. Do not open a public issue containing personal filesystem
paths, hostnames, credentials, or exploit details.

Include the affected version, impact, reproduction steps, and any suggested
mitigation. You can expect an initial response within seven days.

## Security boundary

SpaceMender deletes files. That is the whole point of the app, so the security
model is about *which* files it can reach, not about whether deletion is
possible.

**The unprivileged app** runs outside the App Sandbox because its providers
inspect user-owned developer, browser, and application cache roots. It can only
address roots declared by a registered provider. Every candidate is revalidated
immediately before deletion against the resource identity recorded at scan
time, and validation fails closed on symbolic links, path escapes, changed
resources, unreadable items, and unknown state.

**The privileged helper** is a separate hardened-runtime launch daemon
installed by `SMAppService`. It exists for exactly one operation: deleting
root-owned Microsoft Defender diagnostic archives under

```text
/Library/Application Support/Microsoft/Defender/wdavdiag
```

That root is compiled into the shared XPC contract. It cannot be supplied by
the UI, preferences, the environment, or an XPC request. The helper
independently revalidates every request rather than trusting the caller, and
it refuses any operation outside its single trusted root.

See [`docs/privileged-helper-security.md`](docs/privileged-helper-security.md)
for the full trust model, the prohibited privileged operations, and the known
limitation of local unsigned builds.

## What is explicitly out of scope

SpaceMender never targets Docker volumes, backups, system caches, APFS
snapshots, browser profiles, credentials, history, sessions, or extensions, and
never broadens a provider root merely to increase a space estimate. A report
that SpaceMender *could* delete more if a root were widened is a feature
request, not a vulnerability.

Reports that a user with local administrator access can modify the machine are
also out of scope: the helper's trust anchor is code signing, which an
attacker who already controls the system can subvert regardless.
