# Releasing

There are no published builds yet. This is what it takes to make one, and what
is still missing.

## Why signing is not optional

macOS refuses to open a downloaded app that is not signed with a Developer ID
and notarised by Apple. The error it shows is *"MotionCues is damaged and can't
be opened"*, which is untrue but is what the user sees. So distributing a build
means signing and notarising it, or not distributing it at all.

Building from source needs none of this — that path works today.

## What you need

| Thing | Where it comes from |
|---|---|
| Apple Developer Program membership | $99/year, developer.apple.com |
| Developer ID Application certificate | Xcode › Settings › Accounts › Manage Certificates |
| Team ID | the 10 characters in the certificate name |
| App-specific password | appleid.apple.com › Sign-In and Security |

Store the notary credentials in the keychain once:

```bash
xcrun notarytool store-credentials MotionCuesNotary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Then create `Scripts/.env` (git-ignored):

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
TEAM_ID="TEAMID"
NOTARY_PROFILE="MotionCuesNotary"
```

## Making a release

```bash
./Scripts/release.sh 1.0.0
```

The script refuses to run on a dirty tree, runs the tests before building,
verifies the signature and the hardened runtime, notarises, staples the ticket
so first launch works offline, checks Gatekeeper accepts the result, and
produces a signed DMG and a ZIP.

To rehearse without an Apple account:

```bash
./Scripts/release.sh 1.0.0 --skip-notarize
```

That produces an app that runs on *this* Mac and nowhere else. It is a check
that the build and packaging work, not a release.

Then:

```bash
git tag -a v1.0.0 -m "MotionCues 1.0.0"
git push origin v1.0.0
gh release create v1.0.0 build/MotionCues-1.0.0.dmg build/MotionCues-1.0.0.zip \
  --title "MotionCues 1.0.0" --notes "..."
```

## Not done yet

**Automatic updates.** There is no Sparkle integration. Adding it means a
feed URL, an EdDSA signing key kept out of the repository, and an `appcast.xml`
the release script updates — worth doing once there is something to update
*from*, and worth not doing before, since an update mechanism with no releases
behind it is just an attack surface.

**CI-built releases.** The workflow builds and tests but does not produce
artefacts, because signing on a runner means putting a certificate and an
app-specific password into repository secrets. That is a reasonable thing to do
later; it is not a reasonable thing to do casually.

**A Homebrew cask.** Trivial once there is a stable download URL and a checksum.
