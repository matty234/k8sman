# Updates

k8sman is distributed as a zip on GitHub Releases (`matty234/k8sman`) and
updates itself with [Sparkle 2](https://sparkle-project.org). A Homebrew cask
in a personal tap is an optional extra. This page covers the options that
were considered, how the chosen one works, how to cut a release, and
how releases are signed and notarized.

## Options considered

| | Sparkle 2 | Custom checker (GitHub API) | Homebrew cask |
|---|---|---|---|
| Discovery | Appcast XML (a release asset) | `GET /repos/…/releases/latest` | `brew outdated` / `brew upgrade` |
| Integrity | EdDSA signatures on the archive **and** the feed, checked before extraction | Our own checksum or signature code | sha256 in the cask, pinned by the tap |
| Install | Separate installer process waits for the app to quit, swaps the whole bundle atomically, relaunches | Our own helper script: wait for exit, swap, `open` | `brew` replaces `/Applications/k8sman.app` |
| UI | Native release notes and progress windows; "gentle reminder" hooks | All ours | Terminal only |
| Ad-hoc signed app | Works (see below) | Works | Works, but the download is quarantined |
| Effort and risk | A Swift package, a few delegate methods, signing in CI | Moderate code, and security-sensitive code we'd own | One file in a tap repo |
| Delta updates, phased rollout, critical updates | Built in | No | No |

**Choice: Sparkle 2, with an optional Homebrew cask.**

- **Robust installer.** Sparkle replaces the whole `.app` in one step, so the
  embedded `Contents/MacOS/k8sman-server` is always swapped together with the
  UI. It never runs a new frontend against an old backend. It also handles
  the cases a hand-written swap gets wrong: the app is still running, the
  parent directory isn't writable (it asks for authorization), app
  translocation, the update is on a different volume, and rollback when a
  move fails.
- **Real signatures.** Every archive and the appcast itself are EdDSA
  (ed25519) signed. The public key is built into the app. With
  `SUVerifyUpdateBeforeExtraction` the archive is checked *before* it is
  unpacked. With `SURequireSignedFeed` a tampered or spoofed feed is rejected.
  A custom checker would need the same pieces, and we would own every bug in
  them.
- **The ad-hoc signature isn't a problem.** Sparkle's rule is "EdDSA valid, or
  Apple code signature matches the old app". Ad-hoc signatures never match
  across builds (the requirement is a cdhash), so for us EdDSA is
  **mandatory**. That is exactly the guarantee we want, and an attacker can't
  get around it by ad-hoc signing their own app. Sparkle also checks that
  the new bundle's ad-hoc signature is internally valid.
- **No Gatekeeper prompt after an update.** The installer clears
  `com.apple.quarantine` from the new bundle. Only the very first install
  from a browser or `brew` meets Gatekeeper ("Open Anyway"). Later updates
  launch without prompts.
- **Fits the project.** The macOS runner already uses Swift Package Manager
  (Flutter's `FlutterGeneratedPluginSwiftPackage`), so Sparkle is a normal
  SPM dependency of the Runner target (a prebuilt, signed xcframework). There
  are no CocoaPods. Its native windows match the app's native style.

Why not the alternatives:

- **The custom checker** would only give a nicer banner, and it would mean
  writing and maintaining a self-replacing installer and a signature scheme.
  We get the in-app banner anyway, from Sparkle's gentle-reminder hooks.
- **Homebrew alone** doesn't reach people who downloaded the zip, and it
  doesn't notify anyone. It complements Sparkle: see `packaging/homebrew/`.

### Caveats of ad-hoc signing (releases up to 0.2.7, and local builds)

- Each build has a new code identity. Keychain items that the *app* created
  with "Always Allow", and privacy (TCC) grants, may prompt again after an
  update. k8sman stores no secrets in the keychain itself; exec credential
  plugins such as `aws` and `kubelogin` run as their own binaries and are
  unaffected.
- The first launch needs "Open Anyway". Releases from 0.2.8 on are Developer
  ID signed and notarized instead (see below), so neither applies to them.

## How it works in the app

- **Native side** (`frontend/macos/Runner/UpdateController.swift`):
  - Owns an `SPUStandardUpdaterController`.
  - Adds **Check for Updates…** to the app menu and routes **About k8sman**
    to the Flutter About panel.
  - Exposes the `k8sman/updates` method channel.
  - Sparkle's own scheduler is off (`SUEnableAutomaticChecks` = NO), so it
    never shows its "check automatically?" prompt.
- **Dart side** (`frontend/lib/app/updates/`):
  - `UpdateController` runs the background check about 20 s after launch
    when the last check is over 3 hours old, then every 6 hours (re-evaluated
    hourly against the wall clock, so a Mac that slept checks soon after waking).
  - **About k8sman** shows the version, the *Check for updates automatically*
    switch (stored in the app's user defaults, `UpdatesAutomaticChecks`), the
    last check time, and **Check Now**.
  - When a background check finds an update, Sparkle doesn't open its window.
    It calls the gentle-reminder delegate, and Flutter shows a small
    bottom-right banner: *Update available: vX.Y.Z — Release Notes ·
    Install & Relaunch…*. **Install** brings Sparkle's window to the front,
    with the release notes and Install → Install and Relaunch. The close
    button hides the banner for that version.
- **Disabled** in Debug builds (`flutter run`, `#if DEBUG` plus Dart
  `kReleaseMode`), for version `0.0.0` or `*-dev`, and when no public key or
  feed is configured. In those builds the menu item is greyed out and About
  says why updates are off.
- **Backend and port-forwards across an update:**
  - Sparkle quits the app before installing. `applicationWillTerminate` sends
    SIGTERM to `k8sman-server` (SIGKILL after 3 s), so the backend has
    stopped its forwards and exited before the bundle is swapped. The backend
    also exits when its stdin closes.
  - `updaterWillRelaunchApplication` records the forwards that were running
    and aren't AutoStart (`ResumePortForwards` in user defaults). The
    relaunched app's `BackendSupervisor` restarts them once the new backend
    is listening.
  - AutoStart forwards come back on their own, as on any launch.
  - On the "install on quit" path (no relaunch), forwards behave as after a
    normal quit: only AutoStart forwards come back.
- **Feed:** `https://github.com/matty234/k8sman/releases/latest/download/appcast.xml`
  (`K8SMAN_UPDATE_FEED_URL` in `Configs/AppInfo.xcconfig`). GitHub redirects
  this to the newest non-pre-release's `appcast.xml`, so publishing a
  release is what rolls an update out.
  - For testing, override it with the `K8SMAN_UPDATE_FEED_URL` environment
    variable or `defaults write dev.k8sman.app UpdateFeedURL <url>`.
  - Both overrides work in release builds. That's safe, because the feed and
    the archive must still be signed with the key built into the app.
- **Versions:** `make release` sets `CFBundleShortVersionString` and
  `CFBundleVersion` to the `pubspec.yaml` version (for example `0.1.1`).
  Sparkle compares `CFBundleVersion`, using its standard dotted-version
  comparison.

## Keys (do this once)

The private key signs updates; anyone holding it can push code to every
user. **Never commit it.** Nothing in this repo contains a real key.

1. Run Sparkle's tools (`make sparkle-tools` downloads them, pinned, to
   `build/sparkle/bin`):

   ```sh
   build/sparkle/bin/generate_keys            # creates the key in your login keychain, prints the public key
   build/sparkle/bin/generate_keys -p         # print the public key again later
   build/sparkle/bin/generate_keys -x sparkle_private.key   # export the private key for CI
   ```

2. Put the **public** key in `frontend/macos/Runner/Configs/AppInfo.xcconfig`
   (`SPARKLE_PUBLIC_ED_KEY = …`) and commit it. It's public. You can also set
   it as the repository *variable* `SPARKLE_PUBLIC_ED_KEY` instead.
3. Add the contents of `sparkle_private.key` as the repository **secret**
   `SPARKLE_PRIVATE_ED_KEY`, then delete the file. The keychain copy is your
   backup: if you lose the key, existing installs can't be updated any more,
   short of a Developer ID signed key rotation.

## Cutting a release

1. Bump `version:` in `frontend/pubspec.yaml` (for example `0.1.1`) and commit.
2. Tag it. The annotated tag message becomes the release notes, shown in
   Sparkle's window and on GitHub:
   `git tag -a v0.1.1 -m "- Faster tables"` then `git push origin v0.1.1`.
3. `.github/workflows/release.yml` does the rest:
   - builds the Windows app first (`.github/workflows/windows.yml` on
     `windows-latest`): `k8sman-<v>-windows-x64.zip` and the Inno Setup
     installer `k8sman-<v>-windows-x64-setup.exe`
   - then, on `macos-latest`, checks that the tag matches `pubspec.yaml`
   - runs `make test`
   - runs `make release REQUIRE_UPDATE_KEY=1` and `make appcast`
   - verifies the signed feed
   - creates the GitHub release with `k8sman-<v>-macos.zip`, `appcast.xml`,
     the two Windows files and `SHA256SUMS`
   - prints the Homebrew cask values

   Windows builds don't use Sparkle: they check `releases/latest` on the
   GitHub API on the same schedule and link to the release page. Their version comes
   from `--dart-define=K8SMAN_VERSION`, so local Windows builds never check.
   To try the Windows build without tagging, run the `windows` workflow by
   hand (`gh workflow run windows.yml --ref <branch>`).

   Tags with a pre-release suffix (`v0.2.0-rc.1`) become GitHub
   pre-releases. `releases/latest` skips those, so no user is offered them.
   Their `CFBundleVersion` is the digits only (`0.2.0.1`), which sorts
   *after* `0.2.0`. A tester on an rc should reinstall the final release by
   hand.

To do the same locally (the private key comes from your keychain):

```sh
make release            # dist/k8sman-<v>-macos.zip + SHA256SUMS
make appcast            # + dist/appcast.xml (EdDSA-signed archive and feed)
```

The feed holds only the newest release, which is all Sparkle needs.
Possible later improvements:

- **Delta updates:** run `generate_appcast` over the previous releases'
  zips.
- **Phased rollout:** add `sparkle:phasedRolloutInterval`.

## Testing updates locally (no GitHub)

```sh
make release
make update-e2e        # tools/update-e2e.sh
```

The script:

- Generates a throwaway ed25519 key (`tools/update-e2e/keygen.go`) in
  `build/update-e2e/keys/`.
- Derives 0.1.0 and 0.1.1 copies of the Release app with that key and the
  bundle id `dev.k8sman.e2e`, so the real app's preferences and caches are
  untouched.
- Serves signed appcasts from `python3 -m http.server` on 127.0.0.1.
- Drives the app's own `Sparkle.framework` headlessly
  (`tools/update-e2e/UpdateProbe.swift`, a minimal user driver) against an
  "installed", quarantined copy of 0.1.0.

It checks that:

1. An archive replaced after signing is **rejected**, and 0.1.0 is untouched.
2. A feed and archive signed with a different key are **rejected**.
3. A feed edited after signing is **rejected**.
4. The good feed: the update is downloaded, verified, extracted and installed.
   The bundle is 0.1.1, `k8sman-server` was replaced with it, the code
   signature is valid, and the new bundle is not quarantined.

The probe declines the relaunch so that no GUI app starts. **Check these by
hand** with two real builds:

1. Build and install 0.1.0 with your real public key, in `/Applications`.
2. Build 0.1.1, then run
   `make appcast DOWNLOAD_URL=http://127.0.0.1:8000/k8sman-0.1.1-macos.zip`.
   Serve `dist/` with `python3 -m http.server 8000 --directory dist`.
3. Start the app with the override:
   `K8SMAN_UPDATE_FEED_URL=http://127.0.0.1:8000/appcast.xml /Applications/k8sman.app/Contents/MacOS/k8sman`.
   Or use `defaults write dev.k8sman.app UpdateFeedURL http://127.0.0.1:8000/appcast.xml`,
   then `defaults delete dev.k8sman.app UpdateFeedURL` when you're done.
4. Then check:
   - **k8sman → Check for Updates…** shows Sparkle's window with the notes.
   - **About k8sman** shows *Version 0.1.0* and the switch.
   - With a stale last check (`defaults delete dev.k8sman.app UpdatesLastCheck`),
     the banner appears about 20 s after launch.
   - **Install & Relaunch** quits the app (the backend stops; check with
     `pgrep k8sman-server`), installs, and relaunches as 0.1.1.
   - A port-forward that was running (not AutoStart) is active again, and
     AutoStart ones are too.
   - The relaunched app opens without a Gatekeeper prompt.
   - A `flutter run` build shows **Check for Updates…** greyed out, and
     About says *Updates are off: development build*.

## Developer ID and notarization

Releases from 0.2.8 on are signed with `Developer ID Application: Matthew
Brown (TL74XU6K79)` and the hardened runtime, then notarized and stapled, so
they open without a Gatekeeper prompt.

- **Signing** (`tools/sign-macos.sh`). After `flutter build`, the app is
  re-signed inside-out with `--options runtime --timestamp`, instead of
  `codesign --deep` (which Sparkle's docs warn against). The order is:
  - Sparkle's `Installer.xpc`, `Downloader.xpc` (keeping its entitlements),
    `Autoupdate`, `Updater.app`, then the framework itself.
  - The other frameworks and dylibs.
  - `k8sman-server`.
  - The app, with `Runner/Release.entitlements`.

  Release builds are AOT, so the hardened runtime needs no `allow-jit`.
- **Notarizing** (`tools/notarize-macos.sh`). `xcrun notarytool submit --wait`
  with an App Store Connect API key, then `stapler staple`. If Apple rejects
  the app, the script prints Apple's log. `make release` zips the *stapled*
  app, and `make appcast` signs that zip.
- **Locally:** run `make release MACOS_SIGN_IDENTITY="Developer ID
  Application: …" NOTARIZE=1` with `NOTARY_KEY_FILE`, `NOTARY_KEY_ID` and
  `NOTARY_ISSUER_ID` set. Without `MACOS_SIGN_IDENTITY` the app is ad-hoc
  signed.
- **In CI** (`release.yml`):
  - The certificate comes from the base64 `.p12` secret `MACOS_CERT_P12`
    (password in `MACOS_CERT_PASSWORD`). It goes into a temporary keychain
    that's deleted afterwards.
  - The API key comes from `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and
    `NOTARY_ISSUER_ID`.
  - The variable `APPLE_TEAM_ID` picks the identity.
  - A final release without the certificate fails. A pre-release falls back
    to ad-hoc signing, with a warning.
- **The disk image.** `make release` also builds `k8sman-<version>-macos.dmg`
  (`tools/make-dmg.sh`): the app and an Applications shortcut in a
  compressed image, signed, notarized and stapled (`tools/notarize-macos.sh`
  takes a `.dmg` too). It's the download for people. Sparkle and Homebrew keep
  using the zip.
- **Moving into Applications.** A release build running from a disk image,
  from Downloads, or translocated (a quarantined app opened where it was
  unzipped, which macOS runs from a hidden read-only copy where Sparkle can't
  install updates) offers once to move itself into `/Applications`
  (`Runner/AppMover.swift`). That falls back to `~/Applications` for
  non-admins. It replaces an older copy (which goes to the Trash), clears the
  quarantine flag, trashes the original or ejects the disk image, and
  relaunches. "Don't ask again" is remembered in the app's defaults.
- **Keep EdDSA.** Sparkle accepts an update if EdDSA is valid *or* the
  Developer ID team matches. The first Developer ID release (0.2.8) reaches
  ad-hoc installs as a normal EdDSA-signed update. After that, the stable
  identity also means no TCC or keychain re-prompts.
- **Exporting the `.p12`.** macOS's `security import` can't read the
  PKCS#12 encryption that OpenSSL 3 and later use by default. Export with
  `openssl pkcs12 -export … -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
  -macalg sha1`.
- **Renewal.** The certificate expires on 5 December 2027. Before then,
  create a new CSR and `.p12` and update the two certificate secrets. The
  Team ID stays the same, so updates keep working.
- **Sandboxing.** If the app is ever sandboxed, Sparkle's installer XPC
  services must be enabled (`SUEnableInstallerLauncherService`). It isn't
  sandboxed today.
