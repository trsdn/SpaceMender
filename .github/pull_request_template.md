## Summary

Describe the problem and the outcome of this change.

## Validation

- [ ] `xcodegen generate`
- [ ] `xcodebuild -project SpaceMender.xcodeproj -scheme SpaceMender -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO test`
- [ ] `./scripts/build-app.sh`

## Safety

- [ ] Tests use fixtures and temporary roots; none address a real user cache root or the production Defender directory.
- [ ] The change introduces no personal filesystem paths, usernames, hostnames, or credentials.
- [ ] Any new or changed cleanup location declares an exact root, revalidates before deletion, and fails closed on symbolic links, path escapes, and changed resources.
- [ ] I documented changes to deletion policy, privilege boundary, or the provider contract.

## Regression proof

For a bug fix, state how the new test was shown to fail without the fix, and
confirm it failed with a genuine assertion rather than a compile error or a
hang.
