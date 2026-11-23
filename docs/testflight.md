# TestFlight from GitHub Actions

`.github/workflows/testflight.yml` archives the iPhone app, the Mac app or both
on a clean `xcode-27` runner and uploads them to App Store Connect, where they
show up in TestFlight once Apple has processed them. Run it from the Actions
tab ("TestFlight", Run workflow): pick the branch (normally `main`) and the
platform (`both`, `ios` or `mac`).

## What a run does

1. Reads the current build numbers from the branch (`scripts/build-number.py`)
   and gives each platform the next one.
2. Per platform, in parallel:
   - the Sphinx core from the sphinx-rs release `Vendor/sphinxrs.lock` pins
     (`scripts/build-ffi.sh`, with `PEEL_REQUIRE_CORE_FIXES=1`). The iPhone
     takes that release's `universal-sphinxrs.a`, checked against
     `Vendor/sphinxrs-ios.lock` (`scripts/fetch-ios-core.sh`);
   - Mac only: the agent's bridge (`scripts/stage-bridge.sh`, sphinx's runner
     at the `Vendor/runner.lock` commit) and strut (`scripts/stage-strut.sh`,
     at the `Vendor/strut.lock` commit). Each stage is cached by its pin, so it
     is built again only when the pin moves; the first run after a move takes
     longer;
   - `xcodebuild archive` (Release, automatic signing) with the new build
     number, then `xcodebuild -exportArchive` with
     `Apps/Config/ExportOptions.plist`, which uploads to App Store Connect.
3. Commits the build numbers of what was uploaded to the branch it ran on, as
   one "New iOS build N New Mac build M" commit. A platform that failed keeps
   its old number, so running again reuses it.

Two runs never overlap (they would take the same number). The numbers come
from the repository, so a build uploaded by hand from Xcode must have its
number committed too, or the next run collides with it and the upload fails.

## Secrets

Settings > Secrets and variables > Actions, as repository secrets:

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | The App Store Connect API key's ID. |
| `ASC_ISSUER_ID` | The issuer ID shown above the keys list. |
| `ASC_KEY_P8` | The key's `.p8` file, its whole text. |
| `SIGNING_CERTIFICATES_P12` | A `.p12` with an "Apple Development" identity of the team and its private key, base64 (`base64 -i peel-dev.p12 \| pbcopy`). |
| `SIGNING_CERTIFICATES_PASSWORD` | The password the `.p12` was exported with. |
| `SPHINX_REPO_TOKEN` | A token that can read `stakwork/sphinx` (private): the runner's sources and build-ffi.sh's check of the core's security fixes. |

The API key: App Store Connect > Users and Access > Integrations > App Store
Connect API, a team key with the Admin role (Xcode creates and fetches the
provisioning profiles with it). Its `.p8` downloads once.

The `.p12`: in Keychain Access, under My Certificates, a valid "Apple
Development: <name>" identity of the team (8297M44YTW), Export. The archive
signs with it; the export re-signs for the App Store with Apple's
cloud-managed distribution certificates, through the Admin key, as Xcode's
Organizer does on a Mac without the distribution keys. The identity belongs to
whoever exported it: when it expires or is revoked, export a new one.

`SPHINX_REPO_TOKEN`: a fine-grained personal access token with read access to
the contents of `stakwork/sphinx`.

## Moving a pin

- sphinx-rs: `scripts/build-ffi.sh --update <tag>`, then
  `scripts/fetch-ios-core.sh --update`, and commit both locks.
- runner or strut: as before (`Vendor/runner.lock`, `Vendor/strut.lock`); the
  next run stages the new commit.
