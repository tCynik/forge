# Android device build/deploy

Scripts live in `forge-gui-android/scripts/` (PowerShell, run from any cwd).

## Build order (what `Build-Deploy.ps1` does, in order)

1. Resolve target device (see Device selection below).
2. Resolve `mvn`: PATH first, else IntelliJ's bundled Maven 3.8.1 (`Get-MvnCommand` in
   `Common.ps1`) — this repo needs Maven 3.8.1 specifically for the old
   `android-maven-plugin` to work, matching CI.
3. Resolve a JDK 17 (`Get-BuildJavaHome`): existing `JAVA_HOME` if it's already 17, else
   scans `~/.jdks/*17*` (IntelliJ-downloaded JDKs). Root pom pins
   `maven.compiler.release=17`; a newer system JDK (e.g. 23) will not work for the
   Android toolchain even though plain `javac` might tolerate it.
4. `Install-AndroidMavenPlugin`: `com.simpligility.maven.plugins:android-maven-plugin:4.6.2`
   is Card-Forge's own fork, not on Maven Central. One-time download of the jar+pom
   from its GitHub release straight into the local `.m2` repo (same as CI does).
5. `Register-SubstDrive` maps `.m2\repository` → `M:` and the repo's **parent** dir → `P:`
   (build then runs from `P:\forge`, not `P:\`) before invoking Maven. Two reasons,
   both hit for real during development:
   - The `d8` (dex) step shells out via `cmd.exe /X /C "<one giant command>"` with a
     `--classpath` entry per dependency (~90 for this project). Under deep paths like
     `C:\Users\<user>\.m2\repository\...` that command exceeds cmd.exe's ~8191-char
     limit and fails silently/with a garbled OS error. Short drive letters fix it.
   - Mapping the repo root itself (so the build's cwd becomes the bare drive root
     `P:\`) breaks `mvn.cmd`: its quoted
     `"-Dmaven.multiModuleProjectDirectory=%CD%"` argument gets a trailing backslash
     right before the closing quote, which cmd.exe interprets as an escaped quote,
     corrupting the whole command line. Mapping the *parent* avoids this.
   If `M:`/`P:` are already mapped to something else on this machine, falls back to any
   free letter `G:`-`Z:` instead of clobbering the existing mapping.
6. Builds `mvn -U -pl forge-gui-android -am -P android-test-build clean verify
   -Dmaven.test.skip=true -B -Dmaven.repo.local=<M:>\`. Notable choices:
   - `-P android-test-build` (**not** `android-debug`): `android-debug` signs via
     android-maven-plugin's own in-process `SignedJarBuilder`, which reaches into
     JDK-internal `sun.security.pkcs`/`sun.security.x509` classes whose *layout* (not
     just export visibility) changed since the plugin was last touched (~2017) — even
     with `--add-exports` granted (also set, in `MAVEN_OPTS`, as a harmless belt-and-braces),
     it produces an APK Android rejects at install with
     `Failed to verify signature: no verified SignerInfos`. `android-test-build` leaves
     the APK unsigned (`sign.debug=false`) and signs it afterwards with the bundled
     `tools/uber-apk-signer.jar --debug` (auto-generated/discovered debug keystore,
     search order: exec dir → `~/.android/debug.keystore` → built-in) — the same tool
     CI's release build uses (with a real keystore instead).
   - `clean` is required, not cosmetic: the `android-test-build` profile's uber-apk-signer
     step runs `-a target/`, signing every `*.apk` it finds in the whole `target/` dir.
     The output filename embeds a date, so leftover APKs from an earlier day's build sit
     there as "already signed" and get counted as errors
     (`Successfully processed N APKs and N errors`), making uber-apk-signer exit 2 and
     failing the whole Maven build even though today's APK was signed correctly moments
     earlier. A clean `target/` avoids the ambiguity.
   - `verify` (not `install`): the signer step binds to the `verify` phase, so that's as
     far as the build needs to go — `install` would also copy every reactor module's jar
     into the local `.m2` for no benefit here.
   - `-Dmaven.test.skip=true` (not just `-DskipTests`): skips compiling tests too, not
     just running them.
7. Picks the newest `forge-android-*.apk` in `forge-gui-android/target` (uber-apk-signer
   writes a second, `-aligned-debugSigned` file after the plain build output).
8. Backs up the device's game-progress folder (`<ASSETS_DIR>/data/`: quest, conquest,
   decks/preferences, achievements, puzzle, custom, adventure saves) via `adb pull`,
   if present.
9. `adb install -r -d` (`-d` allows a version downgrade). If that fails with
   `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (device has an existing `forge.app` signed with a
   different key, e.g. an official/production build or a previous machine/keystore's
   build), falls back to `adb uninstall forge.app` + plain `adb install -d` — safe
   because step 8 already backed up progress. Note: rebuilds from *this* script sign
   consistently across runs (uber-apk-signer keeps finding the same
   `~/.android/debug.keystore`), so this fallback should only fire the first time a given
   device is deployed to, or after switching machines/build scripts.
10. If the progress folder is missing/empty after install, restores it. This is more
    involved than a plain `adb push` for two reasons hit for real on-device:
    - `adb shell mkdir` (or a directory created implicitly by `adb push`) is owned by
      `shell`. Under scoped storage the app can read/write *files* inside a directory
      it doesn't own, but cannot create *new subdirectories* there later — it crashed
      with `cannot create profile directory: .../data/gauntlet/` the first time this
      ran, and later `Can not find save directory` (`SaveLoadScene.java:372`) for a
      restored `adventure/<Plane>/` folder even after `data/` itself was fixed. Fix:
      launch the app briefly (so it creates `data/` under its own UID), stop it, `adb
      push` each backed-up child individually into that now-app-owned folder, then
      `chmod -R 777` the restored subtree (no root/chown available, but this was
      empirically sufic to unblock both the mkdir and the read-back cases above).
    - `adb push <localDir> <remoteDir>` copies `localDir` *into* `remoteDir` like
      `cp -r`, not merging its contents — pushing the whole backed-up `data` folder
      onto `.../Forge/data` produces `.../Forge/data/data/...`. Each child is pushed
      individually instead.
11. Calls `Push-LocalRes.ps1` (unless `-NoPushRes`).

`Push-LocalRes.ps1` pushes local/branch changes under `forge-gui/res/**` (card scripts,
editions, quest data, languages, ...) directly to the device's `.../Forge/res/` dir.
Needed because on launch the app's `AssetsDownloader` pulls the production res package
from the snapshot server, which would otherwise clobber local changes not yet merged to
`master`. Safe to run standalone after editing res files, without rebuilding/reinstalling
the APK.

Both scripts set `$ErrorActionPreference = "Continue"`, not `"Stop"`: PowerShell wraps
*any* line a native process (adb, mvn) writes to its own stderr in an error record, and
under `"Stop"` that aborts the whole script on purely informational chatter (e.g. adb's
streamed installs print "All files should be loaded. Notifying the device." to stderr).
Real failures are checked explicitly via `$LASTEXITCODE` / output text instead.

Common params: `-Serial <adb-serial>` to target a specific device, `-BaseBranch <name>`
(default `master`) for the diff base used by `Push-LocalRes.ps1`, `-SkipBuild` /
`-NoBackup` / `-NoPushRes` on `Build-Deploy.ps1`.

## Device selection

Both scripts auto-resolve the target device:
- 1 device connected → used automatically.
- 0 devices → error, stop.
- 2+ devices, one was used before (state cached in `scripts/.device-state.json`) →
  reuses it silently.
- 2+ devices, none used before and no `-Serial` given → script prints
  `AMBIGUOUS_DEVICE_SELECTION` followed by `DEVICE\t<serial>\t<model>` lines and
  exits with code 2. **When this happens, ask the user which device to use, then
  re-run the script with `-Serial <chosen>`.** Do not guess.

## Typical invocation

```powershell
powershell -File forge-gui-android/scripts/Build-Deploy.ps1
```

To only push resource edits without a full rebuild (e.g. after editing a card
script or quest file):

```powershell
powershell -File forge-gui-android/scripts/Push-LocalRes.ps1
```

## Known limitation: Android ≤10 (API ≤29) devices can't get storage access

The manifest (`forge-gui-android/src/main/AndroidManifest.xml`) sets
`targetSdkVersion="35"` with no `requestLegacyExternalStorage` flag. Once an app
*targets* API 30+, that flag has no effect **on any device, at any OS version** —
scoped storage is enforced unconditionally. `Main.java`'s `initForge()` only requests
the API 30+ `MANAGE_EXTERNAL_STORAGE` "all files access" fallback for
`SDK_INT >= R` (30); for API ≤29 devices it assumes plain legacy external-storage
access still works, which is no longer true at `targetSdk=35`. Confirmed on a real
Android 10 (API 29) device: app fails with "Can't access external storage" /
"Can't read/write to storage", and `adb shell appops set <pkg> LEGACY_STORAGE allow`
does **not** fix it — the enforced "Uid mode" stays `ignore` and survives even a full
device reboot. There is no known adb/permission workaround; a real device fix would
need `Main.java`'s storage path selection to also cover this combination (e.g. fall
back to `getExternalFilesDir()`-style scoped-storage-compliant paths for API ≤29 too),
or the device needs to be Android 11+ (where the existing `MANAGE_EXTERNAL_STORAGE`
flow already works, confirmed on a Pixel 8 / Android 17 device).

## TODO: language selection doesn't apply to the Classic/Adventure mode buttons

Changing the language in Settings persists correctly (`FLanguage.changeLanguage()` →
`ForgePreferences` → confirmed on-device the `.preferences` file gets the right
`UI_LANGUAGE` value), and it *does* apply on the next full app restart
(`Localizer 'ru-RU' loaded successfully` confirmed in logcat) — most of the UI honors
it correctly afterward.

**Except** the "Classic Mode" / "Adventure Mode" buttons on `SplashScreen`
(`forge-gui-mobile/src/forge/screens/SplashScreen.java:290-293`), which stay in
English regardless:

```java
if (!init) {
    init = true;
    btnAdventure = new FButton(Forge.getLocalizer().getMessageorUseDefault("lblAdventureMode", "Adventure Mode"));
    btnHome = new FButton(Forge.getLocalizer().getMessageorUseDefault("lblClassicMode", "Classic Mode"));
```

The `ru-RU.properties` translations for both keys exist and are correct
(`lblClassicMode=Классический режим`, `lblAdventureMode=Режим приключений` —
verified, this is not a missing-translation issue). The `!init` guard means this block
runs exactly once per process and is suspected to run before `Localizer` has loaded the
configured locale, baking in whatever `getMessageorUseDefault` resolved at that moment
(the English default, via its exception/`INVALID PROPERTY` fallback path) permanently
for the rest of the app's lifetime. `Localizer` already supports
`registerObserver`/`notifyObservers()` for exactly this kind of live-update case;
`SplashScreen` doesn't use it for these two buttons. Not yet fixed — tracked here per
user request, do not fix without being asked (separate task).
