# Release security and operations

## Signing model

The app and `SpaceMenderDefenderHelper` are separate Mach-O products signed
with the same Developer ID Application team. Release builds enable hardened
runtime and use empty entitlement dictionaries: neither product receives
network, JIT, debugger, library-validation, automation, or broad filesystem
exceptions. The app remains outside App Sandbox only for its documented local
provider roots.

The helper is embedded at
`SpaceMender.app/Contents/MacOS/SpaceMenderDefenderHelper`. Its `SMAppService`
launch-daemon property list is embedded at
`Contents/Library/LaunchDaemons/app.spacemender.SpaceMender.DefenderHelper.plist`
and names that executable through `BundleProgram`. The helper's embedded Info
property list requires the app identifier and the same signing-team OU. Release
verification prints both products' designated requirements and checks bundle
identifiers, hardened-runtime flags, helper layout, launch label, Mach service,
stapled ticket, and Gatekeeper result.

## Credential handling

`SPACEMENDER_TEAM_ID` and the signing identity are non-secret configuration.
Notarization uses only the profile name in `SPACEMENDER_NOTARY_PROFILE`; the
profile credentials live in the macOS keychain and are consumed by
`xcrun notarytool`. Generated archives, export options, submissions, and ZIPs
are written to ignored `release-artifacts/`. No credential file belongs in the
repository.

Create the profile outside source control:

```bash
xcrun notarytool store-credentials spacemender-notary
```

The complete signed/notarized command is:

```bash
export SPACEMENDER_TEAM_ID=ABCDE12345
export SPACEMENDER_SIGNING_IDENTITY="Developer ID Application"
export SPACEMENDER_NOTARY_PROFILE=spacemender-notary
./scripts/package-release.sh
```

`./scripts/package-release.sh --dry-run` creates and validates an unsigned
local archive. `--skip-notarization` signs and verifies locally but does not
submit, staple, or perform the final Gatekeeper/notarization checks. Neither
mode may be described as notarized.

The scripts do not prove that a checked-in or previously built artifact was
notarized. Preserve the successful `notarytool` result, stapler validation,
`spctl` assessment, signature/designated-requirement output, checksum, and
artifact identity for every published release.

## Provider and recovery contract

Every provider must define exact roots or vendor commands, candidate identity,
selection and deletion policy, running-app conflicts, revalidation, user-facing
consequences, and fixture tests. New providers must fail closed for symlinks,
path escapes, changed resources, unreadable items, and unknown state.

User logs and staged app-updater downloads go to Trash. Regenerable
browser/developer caches and validated
Defender archives are permanent deletion. Simulator and Homebrew cleanup use
vendor tools. SpaceMender never broadens a provider root merely to increase a
space estimate, and never targets Docker volumes, backups, system caches, APFS
snapshots, browser profiles, credentials, history, sessions, or extensions.

See [`architecture-and-provider-contract.md`](architecture-and-provider-contract.md)
for registration and test requirements, and
[`user-guide.md`](user-guide.md) for installation, helper lifecycle, recovery,
and troubleshooting.
