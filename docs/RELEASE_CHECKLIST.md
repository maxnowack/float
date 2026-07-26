# Secure release checklist

## Source and tests

- [ ] Start from a reviewed commit and a clean worktree.
- [ ] Review the exact `Package.resolved` diff and
      [`docs/DEPENDENCIES.md`](DEPENDENCIES.md).
- [ ] Run `yarn --cwd extension install --frozen-lockfile`.
- [ ] Run `yarn --cwd extension test`.
- [ ] Run `./scripts/build-chrome.sh` and `./scripts/build-firefox.sh`.
- [ ] Run all XCTest tests with `xcodebuild test`.
- [ ] Run Debug, Release, and explicit `arm64 x86_64` Release builds.
- [ ] Run `xcodebuild analyze` for the companion.

## Signing

- [ ] Build Release with the maintainer's Apple-issued Developer ID Application
      identity. Do not add Hardened Runtime exception entitlements.
- [ ] Confirm the app and embedded `LiveKitWebRTC.framework` have the same Team
      Identifier.
- [ ] Confirm the Release entitlement dump contains no `get-task-allow`,
      camera, microphone, screen-recording, Accessibility, automation,
      disable-library-validation, unsigned-executable-memory,
      disable-executable-page-protection, or dyld-environment exception.
- [ ] Run:

```bash
codesign --verify --deep --strict --verbose=4 Float.app
codesign -d --entitlements - Float.app
codesign -d --verbose=4 Float.app
spctl --assess --type execute --verbose=4 Float.app
```

An ad-hoc build can validate bundle sealing and the Hardened Runtime flag, but
it cannot satisfy Gatekeeper or prove same-team library validation. Do not
describe an ad-hoc result as a distributable signing result.

## Runtime

- [ ] Confirm only `127.0.0.1:17891` is listening and the LAN address refuses
      connections.
- [ ] Re-run web-Origin, forged-Origin, wrong-HMAC, replay, timeout, and
      oversized-message rejection checks.
- [ ] Pair fresh Chrome and Firefox installations; restart each browser and the
      companion; then rotate the secret and pair again.
- [ ] Test recorded video, live video, nested iframes, and multiple video
      sources in both supported browsers.
- [ ] Test manual selection, auto-start, auto-stop, PiP play/pause/skip, source
      mute restoration, Spaces, fullscreen apps, and clean quit/relaunch.
- [ ] Inspect Release logs to confirm no secrets, HMACs, page URLs, full SDP, or
      full ICE candidates appear.

## Packaging and notarization

- [ ] Store notarization credentials in a `notarytool` Keychain profile.
- [ ] Run the canonical release command:

```bash
./scripts/release.sh \
  --tag vX.Y.Z \
  --notary-profile FLOAT_NOTARY \
  --signing-identity "Developer ID Application: Maintainer Name (TEAMID)"
```

The command fails before publishing unless each Release app has a Developer ID
Application signature, Hardened Runtime, matching app/framework Team IDs,
required sandbox/network entitlements, no forbidden security exceptions, an
accepted notarization, a stapled ticket, and a passing Gatekeeper assessment.
It then creates and verifies `artifacts/SHA256SUMS.txt`. Only after all of those
checks pass does it push the branch and tag or create the GitHub release.

- [ ] Test the stapled artifact on a clean Mac account before promoting a draft
      release to final.

Notarization is intentionally separate from ordinary pull-request CI. CI
contains no signing or notarization credentials.
