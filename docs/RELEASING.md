# Releasing

## Signing and notarization

`.github/workflows/release.yml` imports a Developer ID Application certificate, signs the build
with it under a hardened runtime, then notarizes and staples the `.app` **before** zipping. This
is what lets Runbar open on a Mac other than the one that built it — an ad-hoc signature
(`CODE_SIGN_IDENTITY=-`) instead produces *"Runbar is damaged and can't be opened"* on every other
machine, which reads as malware.

### Required repository secrets

These are already set on this repo (shared with the `battery` app, which uses the same Apple
Developer account and the same secret names):

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the Developer ID Application `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PWD` | the `.p12` export password |
| `MACOS_CERTIFICATE_NAME` | the identity string, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `KEYCHAIN_PASSWORD` | any throwaway password for the temp CI keychain |
| `APPLE_ID` | Apple ID email for notarytool |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com |
| `APPLE_TEAM_ID` | Developer team ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA appcast-signing key — see [Cutting a release](#cutting-a-release) |

A Developer ID Application certificate is per-*team*, not per-app, so signing both Runbar and
`battery` with it is expected. Getting there in the first place needs the **Apple Developer Program
($99/year)** — there is no free path to notarization — a **Developer ID Application certificate**
exported as a `.p12`, and an **app-specific password** at appleid.apple.com. Hardened runtime is
already on (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml`), which notarization requires; sandbox
is intentionally off — see `docs/ARCHITECTURE.md`.

### Verifying

The Notarize step already runs these in CI and fails the release if either does not pass:

```bash
spctl -a -vvv -t install /path/to/Runbar.app   # → "accepted", source=Notarized Developer ID
xcrun stapler validate /path/to/Runbar.app     # → "The validate action worked!"
```

After the first release, download the published zip and open it on a **different Mac than a build
machine** as a final sanity check — a machine trusts a signature it produced, so testing there
proves nothing.

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
`release.yml`, which builds, signs, notarizes and staples the app, zips it, generates a signed
appcast, and publishes both to this repo's GitHub release.

The appcast is signed with `SPARKLE_PRIVATE_KEY`, the EdDSA key whose public half is
`SUPublicEDKey` in `project.yml` (`0Y/fgay6lWHRxqpxECSMG38IXYiVlolaDTAK9jXwgxM=`). Export a key
with `<sparkle-bin>/generate_keys -x /dev/stdout`. **The private key and the baked-in public key
must correspond, or Sparkle rejects every update.** Runbar shares this key with the `battery`
app — one key signs both apps' feeds — so `SUPublicEDKey` here matches `battery`'s. **If the key
is lost, auto-update is permanently broken for every installed copy of both apps**, since the
public half ships inside every binary and cannot be changed for installs already in the field.
Back it up somewhere that isn't this laptop.
