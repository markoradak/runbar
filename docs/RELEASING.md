# Releasing

## The blocker: builds are ad-hoc signed

`.github/workflows/release.yml` builds with `CODE_SIGN_IDENTITY=-` (ad-hoc). That is fine on the
machine that built it and **fails on every other Mac**: Gatekeeper shows *"Runbar is damaged and
can't be opened. You should move it to the Trash."* — which reads as malware, not as a signing
gap.

This must be fixed before the first public release. It is the one step that cannot be done from
the repo, because it needs an Apple account.

### What it takes

1. **Apple Developer Program — $99/year.** Required for a Developer ID certificate. There is no
   free path to notarization.
2. **Create a Developer ID Application certificate** in the Apple Developer portal, export it as a
   `.p12`, and base64 it: `base64 -i cert.p12 | pbcopy`.
3. **Create an app-specific password** at appleid.apple.com for notarytool.
4. **Add repository secrets:**
   - `DEVELOPER_ID_CERT_P12` — the base64 `.p12`
   - `DEVELOPER_ID_CERT_PASSWORD` — its export password
   - `APPLE_ID` — the Apple ID email
   - `APPLE_APP_PASSWORD` — the app-specific password
   - `APPLE_TEAM_ID` — from the developer portal
5. **Replace the Build step's signing flags** with the real identity, then notarize and staple
   *before* zipping:

   ```yaml
   - name: Import signing certificate
     env:
       CERT_P12: ${{ secrets.DEVELOPER_ID_CERT_P12 }}
       CERT_PASSWORD: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
     run: |
       echo "$CERT_P12" | base64 --decode > /tmp/cert.p12
       security create-keychain -p "" build.keychain
       security default-keychain -s build.keychain
       security unlock-keychain -p "" build.keychain
       security import /tmp/cert.p12 -k build.keychain -P "$CERT_PASSWORD" \
         -T /usr/bin/codesign
       security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" build.keychain
       rm /tmp/cert.p12

   # In the Build step, replace CODE_SIGN_IDENTITY=- with:
   #   CODE_SIGN_IDENTITY="Developer ID Application" \
   #   DEVELOPMENT_TEAM=${{ secrets.APPLE_TEAM_ID }} \
   #   OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

   - name: Notarize and staple
     env:
       APPLE_ID: ${{ secrets.APPLE_ID }}
       APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
       APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
     run: |
       APP="build/DerivedData/Build/Products/Release/Runbar.app"
       ditto -c -k --keepParent "$APP" /tmp/notarize.zip
       xcrun notarytool submit /tmp/notarize.zip \
         --apple-id "$APPLE_ID" \
         --password "$APPLE_APP_PASSWORD" \
         --team-id "$APPLE_TEAM_ID" \
         --wait
       xcrun stapler staple "$APP"
   ```

   Order matters: notarize and staple the `.app`, **then** run the existing Package step to zip it.
   Zipping first staples nothing and ships an unnotarized app inside a notarized zip.

6. **Hardened runtime is already on** (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml`), which
   notarization requires. Sandbox is intentionally off — see `docs/ARCHITECTURE.md`.

### Verifying

```bash
spctl -a -vvv -t install /path/to/Runbar.app   # → "accepted", source=Notarized Developer ID
xcrun stapler validate /path/to/Runbar.app     # → "The validate action worked!"
```

Test on a **different Mac than the one that built it**, or the check is meaningless — the build
machine trusts its own ad-hoc signature.

## The feed URL is permanent

`SUFeedURL` in `project.yml` is compiled into every shipped binary:

```
https://github.com/markoradak/runbar/releases/latest/download/appcast.xml
```

Once a user installs v0.1.0, that binary polls that URL forever. Changing it only affects *future*
downloads — existing installs keep asking the old one.

If the repo is ever transferred, GitHub's redirect keeps the URL alive and Sparkle follows it, so
transfers are safe. **The one thing that breaks it is recreating a repo at the old path** after
transferring away, which kills the redirect and silently strands every installed copy. Don't.

## Cutting a release

```bash
scripts/release.sh patch      # 0.1.0 -> 0.1.1
scripts/release.sh minor
scripts/release.sh 0.4.2      # explicit
scripts/release.sh patch -n   # dry run
```

It bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in lockstep (Sparkle compares the
build number; users see the marketing version), commits, tags, and pushes. The `v*` tag triggers
`release.yml`, which builds, zips, generates a signed appcast, and publishes both to this repo's
GitHub release.

Requires one secret: `SPARKLE_PRIVATE_KEY`, the EdDSA key whose public half is `SUPublicEDKey` in
`project.yml`. Export it with `<sparkle-bin>/generate_keys -x /dev/stdout`. **If that key is lost,
auto-update is permanently broken for every installed copy** — the public half is baked into
shipped binaries and Sparkle will reject anything signed with a new key. Back it up somewhere that
isn't this laptop.
