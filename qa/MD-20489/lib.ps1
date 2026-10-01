# MD-20489 / PhotoLab 3.13.120-11222 - primitives for TikTok Trends tab testing.
# Dot-source this: . .\lib.ps1
#
# Everything here locates elements through `uiautomator dump` and derives the tap
# point from the node's own bounds. No hardcoded coordinates.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root      = $PSScriptRoot
$script:ScreensDir = Join-Path $script:Root 'screens'
$script:LogsDir    = Join-Path $script:Root 'logs'
$script:TmpDir     = Join-Path $script:Root '.tmp'
$script:StateFile  = Join-Path $script:LogsDir '_device_state.json'

foreach ($d in @($script:ScreensDir, $script:LogsDir, $script:TmpDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# ---------------------------------------------------------------- adb plumbing

function Invoke-Adb {
    # Returns stdout as a single string; throws on non-zero exit.
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    $out = & adb @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb $($Args -join ' ') failed (exit $LASTEXITCODE): $out"
    }
    return ($out -join "`n")
}

function Assert-Device {
    $out = & adb devices 2>&1 | Out-String
    $lines = $out -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Skip 1
    $ready = $lines | Where-Object { $_ -match '^\S+\s+device$' }
    if (-not $ready) {
        Write-Host $out
        throw 'No device in state "device". Fix USB / authorize the RSA prompt on the phone, then re-run.'
    }
    if (@($ready).Count -gt 1) {
        throw "More than one device attached. Set `$env:ANDROID_SERIAL to the one you want."
    }
    Write-Host "Device OK: $($ready[0])" -ForegroundColor Green
}

# -------------------------------------------------------- install / package id

function Install-Build {
    # Installs the APK and returns the package name, discovered by diffing the
    # third-party package list around the install (no aapt dependency).
    param([Parameter(Mandatory)][string]$ApkPath)

    if (-not (Test-Path $ApkPath)) { throw "APK not found: $ApkPath" }

    $before = (Invoke-Adb shell pm list packages -3) -split "`r?`n" |
              ForEach-Object { $_.Trim() } | Where-Object { $_ }

    Write-Host "Installing $ApkPath ..."
    $res = Invoke-Adb install -r $ApkPath
    Write-Host $res
    if ($res -notmatch 'Success') { throw "install -r did not report Success: $res" }

    $after = (Invoke-Adb shell pm list packages -3) -split "`r?`n" |
             ForEach-Object { $_.Trim() } | Where-Object { $_ }

    $new = Compare-Object -ReferenceObject $before -DifferenceObject $after |
           Where-Object { $_.SideIndicator -eq '=>' } |
           ForEach-Object { $_.InputObject -replace '^package:', '' }

    if (@($new).Count -eq 1) { 
        $pkg = $new[0]
    } else {
        # Reinstall over an existing build: nothing new appeared. Fall back to the
        # focused window after a launch, which the caller must confirm.
        $pkg = $null
        $cand = $after | Where-Object { $_ -match 'photolab|photo_lab|funny_photo|linerock' } |
                ForEach-Object { $_ -replace '^package:', '' }
        if (@($cand).Count -eq 1) { $pkg = $cand[0] }
    }

    if (-not $pkg) {
        Write-Warning 'Could not determine the package name automatically.'
        Write-Warning 'Launch the app by hand, then run: adb shell dumpsys window | findstr mCurrentFocus'
        throw 'Package name unresolved - pass it explicitly to the case runner.'
    }

    Write-Host "Package: $pkg" -ForegroundColor Green
    return $pkg
}

function Start-App {
    param([Parameter(Mandatory)][string]$Package)
    Invoke-Adb shell monkey -p $Package -c android.intent.category.LAUNCHER 1 | Out-Null
    Start-Sleep -Seconds 4
}

function Stop-App {
    param([Parameter(Mandatory)][string]$Package)
    Invoke-Adb shell am force-stop $Package | Out-Null
    Start-Sleep -Seconds 1
}

# ------------------------------------------------------------------- ui dump

function Get-UiDump {
    # Pulls the current hierarchy and returns [xml]. Retries: uiautomator
    # regularly answers "could not get idle state" while animations run.
    param([int]$Retries = 4)

    $local = Join-Path $script:TmpDir 'ui_dump.xml'
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $out = Invoke-Adb shell uiautomator dump /sdcard/ui_dump.xml
            if ($out -match 'ERROR|could not') { throw $out }
            Invoke-Adb pull /sdcard/ui_dump.xml $local | Out-Null
            [xml]$xml = Get-Content -Raw -Encoding UTF8 $local
            return $xml
        } catch {
            if ($i -eq $Retries) { throw "uiautomator dump failed after $Retries tries: $_" }
            Start-Sleep -Milliseconds 900
        }
    }
}

function Get-UiNodes {
    param([Parameter(Mandatory)][xml]$Dump)
    return $Dump.SelectNodes('//node')
}

function Find-NodeByText {
    # Matches on text first, then content-desc. -Exact for equality,
    # otherwise case-insensitive substring.
    param(
        [Parameter(Mandatory)][string]$Text,
        [xml]$Dump,
        [switch]$Exact
    )
    if (-not $Dump) { $Dump = Get-UiDump }

    $nodes = Get-UiNodes -Dump $Dump
    foreach ($attr in @('text', 'content-desc')) {
        $hit = $nodes | Where-Object {
            $v = $_.GetAttribute($attr)
            if (-not $v) { return $false }
            if ($Exact) { $v -eq $Text } else { $v -like "*$Text*" }
        }
        if ($hit) { return @($hit)[0] }
    }
    return $null
}

function Get-NodeCenter {
    param([Parameter(Mandatory)]$Node)
    $b = $Node.GetAttribute('bounds')
    if ($b -notmatch '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') { throw "Unparsable bounds: $b" }
    return [pscustomobject]@{
        X = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
        Y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
    }
}

function Tap-ByText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$Exact,
        [int]$SettleMs = 1200
    )
    $node = Find-NodeByText -Text $Text -Exact:$Exact
    if (-not $node) { throw "No node matching text '$Text' in the current hierarchy." }
    $c = Get-NodeCenter -Node $node
    Write-Host "  tap '$Text' -> ($($c.X),$($c.Y))"
    Invoke-Adb shell input tap $c.X $c.Y | Out-Null
    Start-Sleep -Milliseconds $SettleMs
    return $node
}

function Test-TextPresent {
    param([Parameter(Mandatory)][string]$Text, [switch]$Exact)
    return [bool](Find-NodeByText -Text $Text -Exact:$Exact)
}

function Get-VisibleTexts {
    # Flat list of on-screen texts, in hierarchy order - the raw material for
    # comparing against the sections the config says should be visible.
    param([xml]$Dump)
    if (-not $Dump) { $Dump = Get-UiDump }
    return Get-UiNodes -Dump $Dump |
           ForEach-Object { $_.GetAttribute('text') } |
           Where-Object { $_ -and $_.Trim() }
}

# -------------------------------------------------------------- scroll helpers

function Get-ScreenSize {
    $out = Invoke-Adb shell wm size
    if ($out -match 'Override size:\s*(\d+)x(\d+)') { return @([int]$Matches[1], [int]$Matches[2]) }
    if ($out -match 'Physical size:\s*(\d+)x(\d+)') { return @([int]$Matches[1], [int]$Matches[2]) }
    throw "Cannot read screen size: $out"
}

function Scroll-Down {
    param([int]$DurationMs = 400)
    $size = Get-ScreenSize
    $x  = [int]($size[0] / 2)
    $y1 = [int]($size[1] * 0.75)
    $y2 = [int]($size[1] * 0.30)
    Invoke-Adb shell input swipe $x $y1 $x $y2 $DurationMs | Out-Null
    Start-Sleep -Milliseconds 900
}

function Scroll-ToBottom {
    # Swipes until the hierarchy stops changing. Returns every text seen along
    # the way, de-duplicated but order-preserving, so a full section list can be
    # reconstructed from a screen taller than the viewport.
    param([int]$MaxSwipes = 25, [string]$ShotPrefix)

    $seen = New-Object System.Collections.Specialized.OrderedDictionary
    $prevSignature = ''
    for ($i = 0; $i -le $MaxSwipes; $i++) {
        $dump = Get-UiDump
        foreach ($t in (Get-VisibleTexts -Dump $dump)) {
            if (-not $seen.Contains($t)) { $seen.Add($t, $true) }
        }
        if ($ShotPrefix) { Save-Screenshot -Name ("{0}_scroll{1:d2}" -f $ShotPrefix, $i) }

        $sig = ($dump.OuterXml).GetHashCode().ToString()
        if ($sig -eq $prevSignature) {
            Write-Host "  reached bottom after $i swipe(s)"
            break
        }
        $prevSignature = $sig
        if ($i -lt $MaxSwipes) { Scroll-Down }
    }
    return @($seen.Keys)
}

# --------------------------------------------------------------- screenshots

function Save-Screenshot {
    # screencap to the device, then pull. A PowerShell redirect of
    # `adb exec-out screencap -p` mangles the PNG, so never do that.
    param([Parameter(Mandatory)][string]$Name)
    $remote = '/sdcard/_qa_shot.png'
    $local  = Join-Path $script:ScreensDir "$Name.png"
    Invoke-Adb shell screencap -p $remote | Out-Null
    Invoke-Adb pull $remote $local | Out-Null
    Invoke-Adb shell rm -f $remote | Out-Null
    Write-Host "  screenshot -> screens/$Name.png"
    return $local
}

# ------------------------------------------------------------------- logcat

function Start-CaseLog {
    param([Parameter(Mandatory)][string]$CaseId)
    Invoke-Adb logcat -c | Out-Null
    Write-Host "[$CaseId] logcat cleared"
}

function Stop-CaseLog {
    # Full dump for the record + a filtered view of the analytics events.
    param([Parameter(Mandatory)][string]$CaseId)
    $full = Join-Path $script:LogsDir "$CaseId.log"
    $ev   = Join-Path $script:LogsDir "$CaseId.events.log"
    $text = & adb logcat -d -v threadtime 2>&1
    $text | Out-File -FilePath $full -Encoding utf8
    $text | Select-String -Pattern 'home_page_' | ForEach-Object { $_.Line } |
            Out-File -FilePath $ev -Encoding utf8
    $n = (Get-Content $ev -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    Write-Host "[$CaseId] log -> logs/$CaseId.log ; $n home_page_* line(s) -> logs/$CaseId.events.log"
}

function Find-AnalyticsTag {
    # Step 1 of the task: which tag carries the home_page_* events.
    $text = & adb logcat -d -v threadtime 2>&1
    $hits = $text | Select-String -Pattern 'home_page_'
    if (-not $hits) {
        Write-Warning 'No home_page_* lines in the current buffer. Interact with the app, then re-run.'
        return
    }
    Write-Host "`nCandidate tags carrying home_page_*:" -ForegroundColor Cyan
    $hits | ForEach-Object {
        if ($_.Line -match '^\S+\s+\S+\s+\d+\s+\d+\s+(\w)\s+([^:]+):') {
            "{0}/{1}" -f $Matches[1], $Matches[2].Trim()
        }
    } | Group-Object | Sort-Object Count -Descending |
        ForEach-Object { "  {0,-40} {1} line(s)" -f $_.Name, $_.Count }

    Write-Host "`nFirst matching line verbatim:" -ForegroundColor Cyan
    Write-Host ($hits | Select-Object -First 1).Line
}

function Test-NoFatal {
    # O-6: a cold start must not crash.
    param([Parameter(Mandatory)][string]$CaseId)
    $full = Join-Path $script:LogsDir "$CaseId.log"
    if (-not (Test-Path $full)) { throw "No log for $CaseId yet - call Stop-CaseLog first." }
    $fatal = Select-String -Path $full -Pattern 'FATAL EXCEPTION|Process crashed|ANR in'
    if ($fatal) {
        Write-Host "FATAL found in $CaseId :" -ForegroundColor Red
        $fatal | ForEach-Object { Write-Host "  $($_.Line)" }
        return $false
    }
    Write-Host "No FATAL EXCEPTION in $CaseId" -ForegroundColor Green
    return $true
}

# -------------------------------------------------------- navigation shortcuts

function Press-Home  { Invoke-Adb shell input keyevent KEYCODE_HOME  | Out-Null; Start-Sleep -Milliseconds 800 }
function Press-Back  { Invoke-Adb shell input keyevent KEYCODE_BACK  | Out-Null; Start-Sleep -Milliseconds 800 }
function Press-Recents { Invoke-Adb shell input keyevent KEYCODE_APP_SWITCH | Out-Null; Start-Sleep -Seconds 1 }

function Resume-App {
    # Re-foreground without restarting the process (F-6 / S-4 need the warm path).
    param([Parameter(Mandatory)][string]$Package)
    Invoke-Adb shell monkey -p $Package -c android.intent.category.LAUNCHER 1 | Out-Null
    Start-Sleep -Seconds 2
}

# ----------------------------------------------------------------- network

function Set-Network {
    param([Parameter(Mandatory)][ValidateSet('on','off')][string]$State)
    $verb = if ($State -eq 'on') { 'enable' } else { 'disable' }
    foreach ($svc in @('wifi', 'data')) {
        try { Invoke-Adb shell svc $svc $verb | Out-Null }
        catch { Write-Warning "svc $svc $verb failed: $_" }
    }
    Start-Sleep -Seconds 3
    Write-Host "Network: $State" -ForegroundColor Yellow
}

# ------------------------------------------- display state: capture / restore

function Save-DeviceState {
    # Written before A-1/A-2 touch anything, so the originals survive a crash or
    # a Ctrl+C in the middle of the run.
    $fs = (Invoke-Adb shell settings get system font_scale).Trim()
    $wm = Invoke-Adb shell wm density
    $physical = if ($wm -match 'Physical density:\s*(\d+)') { [int]$Matches[1] } else { $null }
    $override = if ($wm -match 'Override density:\s*(\d+)') { [int]$Matches[1] } else { $null }

    $state = [pscustomobject]@{
        font_scale       = $fs              # literal 'null' when never set
        physical_density = $physical
        override_density = $override
        captured_at      = (Get-Date).ToString('s')
    }
    $state | ConvertTo-Json | Out-File -FilePath $script:StateFile -Encoding utf8
    Write-Host "Saved device state -> logs/_device_state.json : font_scale=$fs physical=$physical override=$override" -ForegroundColor Green
    return $state
}

function Restore-DeviceState {
    # Safe to run at any time, including as the only thing you run.
    if (-not (Test-Path $script:StateFile)) {
        Write-Warning 'No _device_state.json. Falling back to: settings delete font_scale + wm density reset.'
        try { Invoke-Adb shell settings delete system font_scale | Out-Null } catch { }
        try { Invoke-Adb shell wm density reset | Out-Null } catch { }
        return
    }
    $s = Get-Content -Raw $script:StateFile | ConvertFrom-Json

    if (-not $s.font_scale -or $s.font_scale -eq 'null') {
        # Was never set: writing 1.0 is NOT the same as unset.
        Invoke-Adb shell settings delete system font_scale | Out-Null
        Write-Host 'font_scale: deleted (was unset)'
    } else {
        Invoke-Adb shell settings put system font_scale $s.font_scale | Out-Null
        Write-Host "font_scale: restored to $($s.font_scale)"
    }

    if ($s.override_density) {
        Invoke-Adb shell wm density $s.override_density | Out-Null
        Write-Host "density: override restored to $($s.override_density)"
    } else {
        Invoke-Adb shell wm density reset | Out-Null
        Write-Host 'density: reset to physical'
    }
    Write-Host 'Device display state restored.' -ForegroundColor Green
}

function Set-FontScale {
    param([Parameter(Mandatory)][string]$Scale)
    Invoke-Adb shell settings put system font_scale $Scale | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "font_scale = $Scale" -ForegroundColor Yellow
}

function Set-Density {
    param([Parameter(Mandatory)][int]$Density)
    Invoke-Adb shell wm density $Density | Out-Null
    Start-Sleep -Seconds 3
    Write-Host "wm density = $Density" -ForegroundColor Yellow
}
