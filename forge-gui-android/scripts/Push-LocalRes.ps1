<#
.SYNOPSIS
  Push local, not-yet-merged changes to forge-gui/res/** (cards, editions,
  quests, languages, ...) straight onto a connected device.

  Why this is needed: on first launch / update-check, the app downloads the
  "production" res package from the snapshot server (see AssetsDownloader),
  which would otherwise overwrite exactly the local/branch changes you're
  trying to test before they're merged to main. Run this after installing
  the APK (Build-Deploy.ps1 does this automatically unless -NoPushRes).

.PARAMETER Serial
  adb serial to target. Omit to auto-resolve (see Common.ps1).

.PARAMETER BaseBranch
  Branch to diff the current branch against (default: master). Local res/
  changes are: (committed-on-branch-but-not-in-BaseBranch) UNION (uncommitted
  tracked changes) UNION (untracked new files), all scoped to forge-gui/res/**.
#>
param(
    [string]$Serial,
    [string]$BaseBranch = "master"
)

# Not "Stop": adb writes routine progress chatter to its own stderr, which PowerShell converts to an
# error record and "Stop" would treat as a terminating exception -- see Build-Deploy.ps1 for detail.
$ErrorActionPreference = "Continue"
chcp 65001 > $null  # UTF-8 console output, so Cyrillic (res/languages, adb output) doesn't garble
. "$PSScriptRoot\Common.ps1"

$repoRoot = Get-RepoRoot
$resPrefix = "forge-gui/res/"

$targetSerial = Resolve-TargetDevice -Serial $Serial
$assetsDir = Get-DeviceAssetsDir $targetSerial
$deviceResDir = "$assetsDir/res"

Push-Location $repoRoot
try {
    $mergeBaseRef = $null
    foreach ($candidate in @("origin/$BaseBranch", $BaseBranch)) {
        git rev-parse --verify --quiet $candidate *> $null
        if ($LASTEXITCODE -eq 0) { $mergeBaseRef = $candidate; break }
    }

    $changed = New-Object System.Collections.Generic.HashSet[string]
    $deleted = New-Object System.Collections.Generic.HashSet[string]

    if ($mergeBaseRef) {
        $mergeBase = (git merge-base HEAD $mergeBaseRef).Trim()
        git diff --name-only --diff-filter=ACMR $mergeBase HEAD -- $resPrefix | ForEach-Object { $changed.Add($_) | Out-Null }
        git diff --name-only --diff-filter=D $mergeBase HEAD -- $resPrefix | ForEach-Object { $deleted.Add($_) | Out-Null }
    } else {
        Write-Warning "Could not resolve '$BaseBranch' or 'origin/$BaseBranch' -- only uncommitted/untracked changes will be pushed."
    }

    git diff --name-only --diff-filter=ACMR HEAD -- $resPrefix | ForEach-Object { $changed.Add($_) | Out-Null }
    git diff --name-only --diff-filter=D HEAD -- $resPrefix | ForEach-Object { $deleted.Add($_) | Out-Null }
    git ls-files --others --exclude-standard -- $resPrefix | ForEach-Object { $changed.Add($_) | Out-Null }

    foreach ($d in $deleted) { $changed.Remove($d) | Out-Null }

    if ($changed.Count -eq 0 -and $deleted.Count -eq 0) {
        Write-Host "No local changes under $resPrefix relative to $BaseBranch -- nothing to push."
        return
    }

    Write-Host "Pushing $($changed.Count) changed / $($deleted.Count) deleted file(s) under $resPrefix to $deviceResDir ..."

    foreach ($path in $changed) {
        $rel = $path.Substring($resPrefix.Length)
        $localPath = Join-Path $repoRoot ($path -replace '/', '\')
        $remotePath = "$deviceResDir/$rel"
        $remoteDir = Split-Path $remotePath -Parent
        # Split-Path leaves backslashes on the drive-agnostic part fine here since remotePath uses '/'; normalize below.
        $remoteDir = $remoteDir -replace '\\', '/'
        adb -s $targetSerial shell "mkdir -p '$remoteDir'" | Out-Null
        adb -s $targetSerial push $localPath $remotePath | Out-Null
        Write-Host "  + $rel"
    }

    foreach ($path in $deleted) {
        $rel = $path.Substring($resPrefix.Length)
        $remotePath = "$deviceResDir/$rel"
        adb -s $targetSerial shell "rm -f '$remotePath'" | Out-Null
        Write-Host "  - $rel"
    }

    Write-Host "Done. Restart the app on the device to pick up the changes."
} finally {
    Pop-Location
}
