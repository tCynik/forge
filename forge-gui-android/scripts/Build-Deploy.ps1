<#
.SYNOPSIS
  Build the Android debug APK and deploy it to a connected device, preserving
  in-game progress (quest/conquest/decks/preferences/achievements) across the
  reinstall, and optionally pushing local working-branch changes to res/ files
  (cards, editions, quests, languages, ...) that ship outside the compiled code.

.PARAMETER Serial
  adb serial to target. Omit to auto-resolve (single device, or the
  previously used one when several are connected -- see Common.ps1).

.PARAMETER SkipBuild
  Skip the maven build and install whatever APK is already in forge-gui-android/target.

.PARAMETER NoBackup
  Skip backing up/restoring the device's game-progress folder (data/).

.PARAMETER NoPushRes
  Skip pushing local working-branch res/ changes after install.

.PARAMETER BaseBranch
  Branch to diff against when collecting local res/ changes (default: master).
  Only used when NoPushRes is not set.

.PARAMETER Force
  Proceed even if the just-taken progress backup looks suspiciously smaller than the
  previous one for this device (see the backup-shrink guard below). Only pass this if
  you're sure the device's progress was legitimately reset/changed outside this script
  (e.g. you know another machine's deploy already ran) -- not as a default habit.
#>
param(
    [string]$Serial,
    [switch]$SkipBuild,
    [switch]$NoBackup,
    [switch]$NoPushRes,
    [string]$BaseBranch = "master",
    [switch]$Force
)

# Not "Stop": this script shells out to adb/mvn constantly, and PowerShell treats ANY line a native
# process writes to its own stderr as an error record -- under "Stop" that aborts the whole script on
# purely informational chatter (e.g. adb's streamed installs print "All files should be loaded.
# Notifying the device." to stderr). Real failures are checked explicitly via $LASTEXITCODE / output text.
$ErrorActionPreference = "Continue"
chcp 65001 > $null  # UTF-8 console output, so Cyrillic (res/languages, adb/logcat text) doesn't garble
. "$PSScriptRoot\Common.ps1"

$repoRoot = Get-RepoRoot
$androidDir = Join-Path $repoRoot "forge-gui-android"
$backupRoot = Join-Path $PSScriptRoot "backups"

$targetSerial = Resolve-TargetDevice -Serial $Serial
Write-Host "Target device: $targetSerial ($(Get-DeviceModel $targetSerial))"

if (-not $SkipBuild) {
    $mvn = Get-MvnCommand
    $buildJavaHome = Get-BuildJavaHome
    Install-AndroidMavenPlugin

    $m2Drive = Register-SubstDrive -DriveLetter "M" -TargetPath (Join-Path $env:USERPROFILE ".m2\repository")
    # Map the *parent* of the repo, not the repo itself: if the build's cwd ends up being the bare
    # drive root ("P:\"), mvn.cmd's quoted "-Dmaven.multiModuleProjectDirectory=%CD%" argument breaks
    # (trailing backslash escapes the closing quote, corrupting the whole command line -- classic
    # cmd.exe quoting trap). Building from "P:\forge" instead keeps %CD% root-free and safe.
    $projectParentDrive = Register-SubstDrive -DriveLetter "P" -TargetPath (Split-Path $repoRoot -Parent)
    $buildDir = if ($projectParentDrive) { Join-Path $projectParentDrive (Split-Path $repoRoot -Leaf) } else { $repoRoot }
    # android-test-build (not android-debug): the android-debug profile signs via
    # android-maven-plugin's own in-process SignedJarBuilder, which reaches into JDK-internal
    # sun.security classes whose *layout* (not just export visibility) changed since this plugin
    # was last updated (~2017) -- it produces an APK Android rejects with
    # "Failed to verify signature: no verified SignerInfos". android-test-build instead leaves the
    # APK unsigned (sign.debug=false) and signs it afterwards with the bundled uber-apk-signer.jar
    # (tools/uber-apk-signer.jar, --debug = auto-generated debug keystore), which is what CI's
    # release build does too (via its own uber-apk-signer invocation).
    # "verify" (not "install"): the profile's uber-apk-signer step binds to the verify phase, so
    # that's as far as we need to go -- "install" would also copy every reactor module's jar into
    # the local .m2 repo for no benefit here.
    # "clean" is required, not cosmetic: uber-apk-signer's SignV2 step runs `-a target/`, signing
    # every *.apk it finds in the whole target dir. Leftover APKs from a previous day's build (the
    # filename embeds a date) confuse it into reporting them as errors ("Successfully processed N
    # APKs and N errors") and exiting 2, failing the whole Maven build even though today's APK was
    # signed correctly moments earlier. A clean target/ avoids the ambiguity entirely.
    $mvnArgs = @("-U", "-pl", "forge-gui-android", "-am", "-P", "android-test-build", "clean", "verify", "-Dmaven.test.skip=true", "-B")
    if ($m2Drive) { $mvnArgs += "-Dmaven.repo.local=$m2Drive" }

    Write-Host "Building debug APK ($mvn $($mvnArgs -join ' '))..."
    Push-Location $buildDir
    $prevJavaHome = $env:JAVA_HOME
    $prevMavenOpts = $env:MAVEN_OPTS
    try {
        if ($buildJavaHome) { $env:JAVA_HOME = $buildJavaHome }
        # android-maven-plugin's in-process APK signer (com.android.sdklib.internal.build.SignedJarBuilder,
        # last updated ~2017) reaches into JDK-internal sun.security classes that JDK 9+'s module system
        # no longer exports by default -- without this, the "apk" goal dies with IllegalAccessError on JDK 17.
        $env:MAVEN_OPTS = "$prevMavenOpts --add-exports=java.base/sun.security.x509=ALL-UNNAMED --add-exports=java.base/sun.security.pkcs=ALL-UNNAMED --add-exports=java.base/sun.security.util=ALL-UNNAMED".Trim()
        & $mvn @mvnArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Maven build failed (exit $LASTEXITCODE)."
            exit $LASTEXITCODE
        }
    } finally {
        $env:JAVA_HOME = $prevJavaHome
        $env:MAVEN_OPTS = $prevMavenOpts
        Pop-Location
    }
}

$apk = Get-ChildItem (Join-Path $androidDir "target") -Filter "forge-android-*.apk" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apk) {
    Write-Error "No APK found in forge-gui-android/target. Build must have failed or SkipBuild was passed with no prior build."
    exit 1
}

# Re-sign with a keystore pinned to this machine (see Get-PinnedDebugKeystore) so repeated builds --
# and, once the pinned keystore file is manually copied to another dev machine, builds from THAT
# machine too -- always carry the same certificate. Without this, `adb install -r` below breaks
# every time the signing machine changes, forcing an uninstall that (despite the backup/restore
# steps further down) has repeatedly cost real in-game progress in practice.
$pinnedKeystorePath = Join-Path $env:USERPROFILE ".forge-android-build\debug.keystore"
$pinnedKeystorePreexisted = Test-Path $pinnedKeystorePath
$pinnedKeystore = Get-PinnedDebugKeystore
if ($pinnedKeystore) {
    $signerJar = Join-Path $androidDir "tools\uber-apk-signer.jar"
    $signJavaHome = Get-BuildJavaHome
    $javaExe = if ($signJavaHome) { Join-Path $signJavaHome "bin\java.exe" } else { "java" }
    Write-Host "Re-signing $($apk.Name) with the pinned debug keystore ($pinnedKeystore)..."
    & $javaExe -jar $signerJar -a $apk.FullName --allowResign --overwrite --ksDebug $pinnedKeystore | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Re-signing failed (exit $LASTEXITCODE) -- continuing with the APK as Maven signed it; adb install may hit INSTALL_FAILED_UPDATE_INCOMPATIBLE if that differs from what's on the device."
    }
}
Write-Host "Using APK: $($apk.FullName)"

$assetsDir = Get-DeviceAssetsDir $targetSerial
$dataDir = "$assetsDir/data"
Write-Host "Device assets dir: $assetsDir"

$backupPath = $null
if (-not $NoBackup) {
    $hasData = (adb -s $targetSerial shell "test -d '$dataDir' && echo yes") -match "yes"
    if ($hasData) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupPath = Join-Path $backupRoot "$targetSerial\$stamp"
        New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
        Write-Host "Backing up game progress ($dataDir) to $backupPath ..."
        adb -s $targetSerial pull $dataDir $backupPath | Out-Null

        # Guard against deploying over a device whose progress was *already* wiped by something
        # else moments ago (in practice: another dev machine deploying to the same physical device
        # around the same time). Without this, the backup we just took is worthless -- it captures
        # the already-empty state -- and this script would go on to "restore" from it, i.e. from
        # nothing, silently cementing the loss. Confirmed happening for real on 2026-07-30.
        $newSize = (Get-ChildItem $backupPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $priorBackups = Get-ChildItem (Join-Path $backupRoot $targetSerial) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $backupPath } | Sort-Object Name -Descending
        if ($priorBackups.Count -gt 0) {
            $priorSize = (Get-ChildItem $priorBackups[0].FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($priorSize -gt 1MB -and ($newSize -lt $priorSize * 0.1)) {
                Write-Warning "Just-taken backup ($([math]::Round($newSize/1KB))KB) is much smaller than the previous one for this device ($([math]::Round($priorSize/1KB))KB, from $($priorBackups[0].Name)). The device's progress may have already been wiped by something else (e.g. another machine deploying to it moments ago) -- proceeding would install over that and could cement the loss."
                if (-not $Force) {
                    Write-Error "Stopping before install/uninstall. If this shrink is expected (you know progress was legitimately reset), re-run with -Force. Otherwise check what else touched this device just now, and consider restoring from $($priorBackups[0].FullName) instead."
                    exit 1
                }
                Write-Host "-Force given -- proceeding anyway."
            }
        }
    } else {
        Write-Host "No existing progress folder on device ($dataDir) -- nothing to back up."
    }
}

Write-Host "Installing APK (adb install -r)..."
# Do NOT redirect adb's stderr with 2>&1: PowerShell 5.1 wraps every redirected stderr line from a
# native command in a terminating NativeCommandError, which -- combined with $ErrorActionPreference
# = Stop above -- aborts the whole script on any incidental stderr chatter (e.g. some devices print
# "All files should be loaded. Notifying the device." during a streamed install). adb's actual
# Success/Failure result line goes to stdout, so plain capture is enough for the check below.
$installOutput = adb -s $targetSerial install -r -d $apk.FullName
Write-Host $installOutput
# adb can return multiple lines (string array); -notmatch on an array filters element-by-element and
# returns non-matching elements, which is truthy even when one line DID match -- join first so this
# is a real all-or-nothing check.
$installText = $installOutput -join "`n"
if ($installText -notmatch "Success") {
    if ($installText -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
        # Device has an existing forge.app signed with a different key -- adb can't update it in
        # place. We already backed up progress above, so it's safe to remove the old app and
        # install fresh; the restore-if-missing check below puts progress back.
        if ($pinnedKeystorePreexisted) {
            # The pinned keystore already existed on THIS machine yet still produced a signature the
            # device doesn't recognize -- that means the keystore itself diverged from whatever
            # machine last successfully deployed to this device, not a one-time first-pairing. This is
            # the operator-facing case: fix the root cause, not just this install.
            Write-Warning @"
Pinned keystore already exists on this machine ($pinnedKeystorePath) but the device rejected the
update as an incompatible signature -- this machine's copy of the keystore does not match whatever
last signed the app on this device. Proceeding with uninstall+reinstall now (progress already
backed up above), but this will keep happening on every deploy from this machine until you fix it:

  1. On the machine that last successfully deployed to this device, locate:
       %USERPROFILE%\.forge-android-build\debug.keystore
  2. Copy that file to THIS machine, to the exact same path, overwriting this machine's copy.
     Use any channel except git (USB drive, cloud folder, scp, ...) -- this file is a signing key
     and must never be committed.
  3. Re-run this script. adb install -r should then update in place with no further uninstalls.
"@
        } else {
            Write-Host "Existing forge.app was signed with a different key (expected on first deploy from a freshly-created pinned keystore) -- uninstalling it and installing fresh (progress was already backed up)..."
        }
        adb -s $targetSerial uninstall forge.app | Out-Null
        $installOutput = adb -s $targetSerial install -d $apk.FullName
        Write-Host $installOutput
        $installText = $installOutput -join "`n"
    }
    if ($installText -notmatch "Success") {
        Write-Error "adb install did not report Success."
        exit 1
    }
}

if ($backupPath) {
    $listing = adb -s $targetSerial shell "ls '$dataDir' 2>/dev/null"
    $stillHasData = $null -ne ($listing | Where-Object { $_.Trim() -ne "" })
    if (-not $stillHasData) {
        Write-Host "Progress folder missing/empty after install -- restoring from backup ($backupPath)..."
        # Two gotchas here, both hit on a real device during development:
        # 1. `adb shell mkdir` creates the dir as the "shell" user. Under scoped storage, an app can
        #    read/write *files* inside a directory it doesn't own, but it CANNOT create new
        #    *subdirectories* there later -- e.g. it crashed with "cannot create profile directory:
        #    .../data/gauntlet/" the first time this ran. So data/ itself must be app-owned, and the
        #    only way to get that without root is to let the app create it: launch briefly, stop it.
        # 2. `adb push <localDir> <remoteDir>` copies localDir *into* remoteDir (like `cp -r`), i.e.
        #    pushing "...\data" onto ".../Forge/data" produces ".../Forge/data/data/..." -- push each
        #    child of the backup's data/ individually instead so contents land directly in $dataDir.
        adb -s $targetSerial shell am force-stop forge.app | Out-Null
        adb -s $targetSerial shell monkey -p forge.app -c android.intent.category.LAUNCHER 1 | Out-Null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $exists = adb -s $targetSerial shell "test -d '$dataDir' && echo yes"
            if ($exists -match "yes") { break }
        }
        adb -s $targetSerial shell am force-stop forge.app | Out-Null
        Get-ChildItem (Join-Path $backupPath "data") | ForEach-Object {
            adb -s $targetSerial push $_.FullName "$dataDir/$($_.Name)" | Out-Null
        }
        # Pushed files/dirs are owned by "shell", not the app -- confirmed on-device that this alone
        # still blocks the app from later mkdir'ing *inside* a restored folder (e.g. a new adventure
        # plane save dir), throwing "Can not find save directory" even though data/ itself is fine.
        # chmod -R 777 on just the restored subtree (not all of data/, which includes the app-owned
        # parent already) fixes it without needing root/chown.
        adb -s $targetSerial shell "chmod -R 777 '$dataDir'" | Out-Null
    } else {
        Write-Host "Progress folder intact after install -- no restore needed."
    }
}

if (-not $NoPushRes) {
    & "$PSScriptRoot\Push-LocalRes.ps1" -Serial $targetSerial -BaseBranch $BaseBranch
}

Write-Host "Done."
