# Shared helpers for Android device build/deploy scripts.
# Dot-source this file: . "$PSScriptRoot\Common.ps1"

$script:StateFile = Join-Path $PSScriptRoot ".device-state.json"

function Get-RepoRoot {
    (git -C $PSScriptRoot rev-parse --show-toplevel).Trim() -replace '/', '\'
}

function Get-ConnectedDevices {
    # Returns array of serials whose state is exactly "device" (skips "unauthorized"/"offline").
    # Always returns a real array (even 0/1 elements) -- PowerShell unwraps single-element
    # arrays to a bare scalar on return otherwise, which turns $devices[0] into a *character* index.
    $lines = adb devices | Select-Object -Skip 1
    $devices = @()
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+device$') {
            $devices += $Matches[1]
        }
    }
    return $devices
}

function Get-DeviceModel($serial) {
    (adb -s $serial shell getprop ro.product.model).Trim()
}

function Read-DeviceState {
    if (Test-Path $script:StateFile) {
        try { return Get-Content $script:StateFile -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-DeviceState($serial) {
    @{ serial = $serial; savedAt = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -Encoding utf8 $script:StateFile
}

function Resolve-TargetDevice {
    param([string]$Serial)

    $devices = @(Get-ConnectedDevices)
    if ($devices.Count -eq 0) {
        Write-Error "No adb devices connected (or none authorized). Plug in the device / enable USB debugging and retry."
        exit 1
    }

    if ($Serial) {
        if ($devices -contains $Serial) {
            Save-DeviceState $Serial
            return $Serial
        }
        Write-Error "Requested device '$Serial' is not connected. Connected: $($devices -join ', ')"
        exit 1
    }

    if ($devices.Count -eq 1) {
        Save-DeviceState $devices[0]
        return $devices[0]
    }

    # Multiple devices connected, no explicit -Serial given.
    $state = Read-DeviceState
    if ($state -and ($devices -contains $state.serial)) {
        Write-Host "Multiple devices connected; using previously used device $($state.serial) (pass -Serial to override)."
        Save-DeviceState $state.serial
        return $state.serial
    }

    Write-Host "AMBIGUOUS_DEVICE_SELECTION"
    foreach ($d in $devices) {
        Write-Host "DEVICE`t$d`t$(Get-DeviceModel $d)"
    }
    exit 2
}

function Get-DeviceApiLevel($serial) {
    [int](adb -s $serial shell getprop ro.build.version.sdk).Trim()
}

# forge.app package: matches forge-gui-android/src/main/AndroidManifest.xml
$script:ForgePackage = "forge.app"

function Get-DeviceAssetsDir($serial) {
    $api = Get-DeviceApiLevel $serial
    if ($api -gt 29) { # Android 10 (Q) and below use external storage root; 11+ (R, API 30+) uses the obb dir
        return "/storage/emulated/0/Android/obb/$script:ForgePackage/Forge"
    } else {
        return "/storage/emulated/0/Forge"
    }
}

function Register-SubstDrive {
    # android-maven-plugin's d8 goal shells out via "cmd.exe /X /C <one giant command>" with a
    # --classpath entry per dependency jar. Forge has ~90 dependencies, so under deep paths
    # (C:\Users\<user>\.m2\repository\..., C:\Users\<user>\IdeaProjects\forge\...) that command
    # can exceed cmd.exe's ~8191-char line limit and fail with an (often mangled/untranslated)
    # OS error. CI builds on Linux, which has no such limit, so this only bites on Windows.
    # Mapping the long roots to drive letters via `subst` shortens every path derived from them.
    param([Parameter(Mandatory)][string]$DriveLetter, [Parameter(Mandatory)][string]$TargetPath)

    $desired = $TargetPath.TrimEnd('\')
    $substLines = @(subst)

    $driveSpec = "${DriveLetter}:"
    $existingLine = $substLines | Where-Object { $_ -like "$driveSpec*" }
    if ($existingLine -and ($existingLine -match '=>\s*(.+)$')) {
        $currentTarget = $Matches[1].Trim().TrimEnd('\')
        if ($currentTarget -eq $desired) {
            return "$driveSpec\"
        }
        # Preferred letter is taken by something else -- don't clobber it, fall back to any free
        # letter instead (e.g. G-Z) rather than failing outright.
        Write-Warning "$driveSpec is already mapped to something else ($currentTarget) -- picking a different free drive letter instead."
        $usedLetters = @((Get-PSDrive -PSProvider FileSystem).Name)
        foreach ($line in $substLines) {
            if ($line -match '^([A-Z]):') { $usedLetters += $Matches[1] }
        }
        $freeLetter = [char[]]'GHIJKLMNOPQRSTUVWXYZ' | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
        if (-not $freeLetter) {
            Write-Warning "No free drive letter available either -- continuing without a subst mapping for $desired."
            return $null
        }
        $driveSpec = "${freeLetter}:"
    }

    subst $driveSpec $TargetPath
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not 'subst $driveSpec $TargetPath' (exit $LASTEXITCODE). Continuing without it."
        return $null
    }
    Write-Host "Mapped $driveSpec -> $TargetPath (shortens paths for the Windows d8 command-line-length limit)."
    return "$driveSpec\"
}

function Install-AndroidMavenPlugin {
    # com.simpligility.maven.plugins:android-maven-plugin:4.6.2 is Card-Forge's own fork and isn't
    # on Maven Central. CI (.github/workflows/snapshots-android.yml) installs it by dropping the
    # jar/pom straight into the local repo -- do the same here, once.
    $groupPath = Join-Path $env:USERPROFILE ".m2\repository\com\simpligility\maven\plugins\android-maven-plugin\4.6.2"
    $jarPath = Join-Path $groupPath "android-maven-plugin-4.6.2.jar"
    if (Test-Path $jarPath) {
        return
    }
    Write-Host "android-maven-plugin 4.6.2 not found in local Maven repo -- fetching from Card-Forge's fork release..."
    New-Item -ItemType Directory -Force -Path $groupPath | Out-Null
    $base = "https://github.com/Card-Forge/android-maven-plugin/releases/download/4.6.2"
    Invoke-WebRequest -Uri "$base/android-maven-plugin-4.6.2.jar" -OutFile $jarPath
    Invoke-WebRequest -Uri "$base/android-maven-plugin-4.6.2.pom" -OutFile (Join-Path $groupPath "android-maven-plugin-4.6.2.pom")
    Write-Host "Installed android-maven-plugin 4.6.2 to $groupPath"
}

function Get-MvnCommand {
    # Prefer mvn on PATH. Otherwise this repo (per CI) needs Maven 3.8.1 specifically for the
    # android-maven-plugin (4.6.2) to work -- fall back to IntelliJ's bundled maven3, which ships
    # exactly that version.
    if (Get-Command mvn -ErrorAction SilentlyContinue) {
        return "mvn"
    }
    $candidates = @(Get-ChildItem -Path "$env:ProgramFiles\JetBrains\*\plugins\maven\lib\maven3\bin\mvn.cmd" -ErrorAction SilentlyContinue)
    if ($candidates.Count -gt 0) {
        Write-Host "mvn not on PATH -- using IntelliJ-bundled Maven: $($candidates[0].FullName)"
        return $candidates[0].FullName
    }
    Write-Error "Could not find 'mvn'. Install Maven (3.8.1 recommended, matches CI) and put it on PATH, or install/open IntelliJ IDEA (bundles a compatible Maven under its 'maven' plugin)."
    exit 1
}

function Get-BuildJavaHome {
    # Root pom pins maven.compiler.release=17 and CI builds Android with JDK 17 specifically.
    # If JAVA_HOME already points at a JDK 17 install, leave it alone.
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "release"))) {
        $release = Get-Content (Join-Path $env:JAVA_HOME "release") -Raw
        if ($release -match 'JAVA_VERSION="17') {
            return $env:JAVA_HOME
        }
    }
    # Look for a JDK 17 IntelliJ downloaded for itself under ~/.jdks (corretto-17.x, jbr-17.x, temurin-17.x, ...).
    $candidates = @(Get-ChildItem -Path "$env:USERPROFILE\.jdks" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(^|[^0-9])17([^0-9]|$)' } |
        Sort-Object Name -Descending)
    if ($candidates.Count -gt 0) {
        Write-Host "JAVA_HOME not set to a JDK 17 -- using $($candidates[0].FullName) for this build."
        return $candidates[0].FullName
    }
    Write-Warning "No JDK 17 found (checked JAVA_HOME and ~/.jdks). Build will use whatever JDK is on PATH; this repo requires 17 and may fail to compile/dex."
    return $env:JAVA_HOME
}

function Get-PinnedDebugKeystore {
    # `android-test-build`'s uber-apk-signer step (bare "--debug") signs with whatever debug
    # keystore it finds first: exec dir, then ~/.android/debug.keystore, then a key baked into the
    # jar. That keystore is per-machine and NOT synced (same as this user's local AI/system-prompt
    # config across machines, by design) -- so a build from machine A and a build from machine B
    # carry different certificates. `adb install -r` then refuses to update in place
    # (INSTALL_FAILED_UPDATE_INCOMPATIBLE), forcing an uninstall+reinstall on every switch between
    # machines, which is the actual root cause of progress getting wiped when alternating machines.
    #
    # Fix: pin one stable keystore locally (NEVER committed to the repo -- forge-gui-android/*.keystore
    # is gitignored on purpose, matching the real release keystore's handling) and re-sign the built
    # APK with it every time, on every machine. To make both dev machines agree, manually copy this
    # one file between them once (any channel outside git): whichever machine already has real
    # installs out there, copy ITS %USERPROFILE%\.forge-android-build\debug.keystore to the other
    # machine at the same path -- from then on both machines produce byte-identical signatures and
    # `adb install -r` always updates in place, no more uninstall/data-loss cycles.
    $dir = Join-Path $env:USERPROFILE ".forge-android-build"
    $keystorePath = Join-Path $dir "debug.keystore"
    if (Test-Path $keystorePath) {
        return $keystorePath
    }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $androidDebugKeystore = Join-Path $env:USERPROFILE ".android\debug.keystore"
    if (Test-Path $androidDebugKeystore) {
        Write-Host "Pinning $keystorePath as a copy of $androidDebugKeystore (matches whatever this machine has already signed/installed with so far)."
        Copy-Item $androidDebugKeystore $keystorePath
    } else {
        Write-Host "Generating a stable debug keystore at $keystorePath (used for every future build on this machine)."
        $javaHome = Get-BuildJavaHome
        $keytool = if ($javaHome) { Join-Path $javaHome "bin\keytool.exe" } else { "keytool" }
        & $keytool -genkeypair -v -keystore $keystorePath -storepass android -keypass android `
            -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 `
            -dname "CN=Android Debug,O=Android,C=US" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "keytool failed to generate a debug keystore (exit $LASTEXITCODE) -- signing will fall back to uber-apk-signer's own default keystore search."
            return $null
        }
    }
    return $keystorePath
}
