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

## Provider and recovery contract

Every provider must define exact roots or vendor commands, candidate identity,
selection and deletion policy, running-app conflicts, revalidation, user-facing
consequences, and fixture tests. New providers must fail closed for symlinks,
path escapes, changed resources, unreadable items, and unknown state.

User logs go to Trash. Regenerable browser/developer caches and validated
Defender archives are permanent deletion. Simulator and Homebrew cleanup use
vendor tools. SpaceMender never broadens a provider root merely to increase a
space estimate, and never targets Docker volumes, backups, system caches, APFS
snapshots, browser profiles, credentials, history, sessions, or extensions.
