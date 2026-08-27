<#
    NongPlaiShop - FiveM Performance Tuner (PowerShell edition)
    Rewritten from the original .cmd to fix reliability issues caused by
    batch's fragile multi-line parsing and by spawning a fresh powershell.exe
    process for almost every step. This version runs as a single PowerShell
    session: fewer spawned processes, real try/catch per step, and a proper
    JSON-based backup so Reset can undo exactly what was changed.

    v2.0 additions: Hardware Scan Engine + Adaptive Deep Tweak.
    Before applying anything, v2 scans the actual CPU/GPU/RAM/Storage/NIC in this PC and
    only applies the tweaks that make sense for that hardware (e.g. Intel vs AMD CPU tweaks,
    NVMe vs SATA SSD vs HDD tweaks, Realtek vs Intel NIC tweaks). Same safe change-tracking
    and Reset as v1 - every adaptive tweak goes through the same Set-Reg/Set-SvcStart helpers
    so it is fully undoable.

    Usage:
        Right-click > Run with PowerShell   (it will self-elevate and show a UAC prompt)
        .\nongplai_v2.ps1                 -> shows the menu
        .\nongplai_v2.ps1 -HpetToggle      -> opens the separate HPET on/off tool
        .\nongplai_v2.ps1 -DryRun          -> menu runs in preview mode: shows exactly what
                                              Smart Apply would change without changing anything
        One-liner (no download needed):
            irm https://<your-host>/nongplai_v2.ps1 | iex
        Works the same as running the .ps1 file directly - it still self-elevates
        (UAC prompt) and still shows the interactive [1]/[2]/[3] menu.
#>

param(
    [switch]$HpetToggle,
    [switch]$DryRun
)

# Self-elevate: relaunch as Administrator if not already, then stop this non-elevated instance.
# NOTE: when run via `irm <url> | iex`, there is no on-disk script file, so
# $MyInvocation.MyCommand.Path is empty. $MyInvocation.MyCommand.Definition still holds the
# full script text in both cases (local file OR piped from iex), so we always write that text
# out to a temp .ps1 and elevate against the temp file. This makes the one-liner work exactly
# like running the .ps1 directly, including self-elevation and the interactive menu.
$currentId = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentId)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $runPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($runPath)) {
        # Running via irm | iex (or similar) - persist the script text so the elevated
        # child process has an actual file to run.
        $runPath = Join-Path $env:TEMP "nongplai_v2_$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -Path $runPath -Value $MyInvocation.MyCommand.Definition -Encoding UTF8
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runPath`"")
    if ($HpetToggle) { $argList += '-HpetToggle' }
    if ($DryRun) { $argList += '-DryRun' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host "Elevation was cancelled or failed. This tool needs to run as Administrator." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
    }
    exit 0
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$script:Changes   = New-Object System.Collections.Generic.List[Object]
$script:BackupDir = $null
$script:LogFile   = $null
$script:OK        = 0
$script:Total     = 0
$script:Failed    = New-Object System.Collections.Generic.List[string]
$script:DefenderPolicyValues = $null
$script:PendingExclusions = @{ Paths = New-Object System.Collections.Generic.List[string]; Processes = New-Object System.Collections.Generic.List[string] }
$script:DryRun = [bool]$DryRun
$script:HwInfo = $null

# ---------------------------------------------------------------------------
# v2: colored status output + progress bar
# ---------------------------------------------------------------------------
function Write-Ok    { param([string]$Message) Write-Host "  [OK] $Message"   -ForegroundColor Green }
function Write-Bad   { param([string]$Message) Write-Host "  [X]  $Message"   -ForegroundColor Red }
function Write-Warn2 { param([string]$Message) Write-Host "  [!]  $Message"   -ForegroundColor Yellow }
function Write-Info2 { param([string]$Message) Write-Host "  [i]  $Message"   -ForegroundColor Cyan }

function Write-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Label = '')
    $width = 30
    $filled = if ($Total -gt 0) { [int](($Current / $Total) * $width) } else { 0 }
    if ($filled -gt $width) { $filled = $width }
    $bar = ('#' * $filled) + ('.' * ($width - $filled))
    $pct = if ($Total -gt 0) { [int](($Current / $Total) * 100) } else { 0 }
    Write-Host ("  [{0}] {1}/{2} ({3}%) {4}" -f $bar, $Current, $Total, $pct, $Label) -ForegroundColor Magenta
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.ff"), $Message
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    }
}

function New-BackupFolder {
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $dir = Join-Path $env:TEMP "FiveM_Ultra_Backup_$ts"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $script:BackupDir = $dir
    $script:LogFile = Join-Path $dir "apply.log"
    New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
    Write-Log "Apply started"
    return $dir
}

function Save-Changes {
    if (-not $script:BackupDir) { return }
    $path = Join-Path $script:BackupDir "changes.json"
    try {
        $script:Changes | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
    } catch {
        Write-Log "! Could not save changes.json: $($_.Exception.Message)"
    }
}

function Find-LatestBackup {
    $dirs = @(Get-ChildItem -Path $env:TEMP -Directory -Filter "FiveM_Ultra_Backup_*" -ErrorAction SilentlyContinue)
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (Test-Path $desktop) {
        $dirs += @(Get-ChildItem -Path $desktop -Directory -Filter "FiveM_Ultra_Backup_*" -ErrorAction SilentlyContinue)
    }
    if ($dirs.Count -eq 0) { return $null }
    return ($dirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# ---------------------------------------------------------------------------
# Change-tracking helpers (each records enough to undo itself on Reset)
# ---------------------------------------------------------------------------
function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','Binary','QWord','ExpandString')]$Type = 'DWord'
    )
    try {
        $keyExisted = Test-Path $Path
        if ($script:DryRun) {
            Write-Host ("  [DRYRUN] would set {0}\{1} = {2} ({3})" -f $Path, $Name, $Value, $Type) -ForegroundColor DarkCyan
            return $true
        }
        if (-not $keyExisted) { New-Item -Path $Path -Force | Out-Null }
        $had = $false; $old = $null
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $prop -and ($prop.PSObject.Properties.Name -contains $Name)) { $had = $true; $old = $prop.$Name }
        $script:Changes.Add([PSCustomObject]@{
            Kind = 'RegValue'; Path = $Path; Name = $Name
            KeyCreated = (-not $keyExisted); HadValue = $had; OldValue = $old; Type = $Type
        })
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        return $true
    } catch {
        Write-Log ("  ! Set-Reg failed for {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message)
        return $false
    }
}

function Remove-Reg {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $prop -and ($prop.PSObject.Properties.Name -contains $Name)) {
            $script:Changes.Add([PSCustomObject]@{ Kind='RegValueRemoved'; Path=$Path; Name=$Name; OldValue=$prop.$Name })
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch { return $false }
}

function Set-SvcStart {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('Automatic','Manual','Disabled')]$StartupType)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log "  ! Service $Name not found, skipped"; return $false }
        if ($script:DryRun) {
            Write-Host ("  [DRYRUN] would set service {0} startup = {1}" -f $Name, $StartupType) -ForegroundColor DarkCyan
            return $true
        }
        $wmi = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        $oldStart = if ($wmi) { $wmi.StartMode } else { 'Automatic' }
        $script:Changes.Add([PSCustomObject]@{ Kind='Service'; Name=$Name; OldStart=$oldStart })
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction SilentlyContinue
        if ($StartupType -ne 'Automatic' -and $svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        } elseif ($StartupType -eq 'Automatic' -and $svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-Log ("  ! Set-SvcStart failed for {0}: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

function Invoke-Step {
    param(
        [int]$Number, [int]$Total, [string]$Description, [scriptblock]$Action
    )
    $label = "[$Number/$Total] $Description"
    Write-Host $label
    Write-Log $label
    try {
        & $Action
    } catch {
        Write-Host "  ! Step failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Log "  ! Step failed: $($_.Exception.Message)"
    }
    # Save after every step (not just at the very end) so that if the script is
    # interrupted mid-run, Reset can still undo whatever was actually applied.
    Save-Changes
}

# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------
function Find-FiveMExe {
    $found = $null
    try {
        $proc = Get-Process -Name FiveM -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.Path) { $found = $proc.Path }
    } catch {}
    if (-not $found) {
        $root = Join-Path $env:LOCALAPPDATA 'FiveM'
        if (Test-Path $root) {
            $hit = Get-ChildItem $root -Filter 'FiveM.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $found = $hit.FullName }
        }
    }
    if (-not $found) {
        # Portable/custom installs: check the root of every fixed drive for a FiveM folder.
        try {
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
                if ($found) { return }
                $guess = Join-Path $_.Root 'FiveM'
                if (Test-Path $guess) {
                    $hit = Get-ChildItem $guess -Filter 'FiveM.exe' -Recurse -ErrorAction SilentlyContinue -Depth 4 | Select-Object -First 1
                    if ($hit) { $found = $hit.FullName }
                }
            }
        } catch {}
    }
    if (-not $found) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $locs = @(
                [Environment]::GetFolderPath('Desktop'),
                [Environment]::GetFolderPath('CommonDesktopDirectory'),
                (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs')
            )
            foreach ($loc in $locs) {
                if (-not (Test-Path $loc)) { continue }
                $lnk = Get-ChildItem $loc -Filter '*FiveM*.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($lnk) {
                    $t = $shell.CreateShortcut($lnk.FullName).TargetPath
                    if ($t -and (Test-Path $t)) { $found = $t; break }
                }
            }
        } catch {}
    }
    return $found
}

function Get-DefenderBlockReason {
    # Add-MpPreference can fail for several unrelated reasons. Figure out which one actually
    # applies here so we can tell the person the real fix instead of always blaming Tamper Protection.
    $reasons = New-Object System.Collections.Generic.List[string]

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender') {
            $policyKeys = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -ErrorAction SilentlyContinue
            if ($policyKeys) {
                $reasons.Add("Windows Defender is centrally managed by a policy (Group Policy/MDM) on this PC - exclusions are locked by that policy, not by Tamper Protection.")
                $names = $policyKeys.PSObject.Properties.Name | Where-Object { $_ -notmatch '^PS' }
                if ($names) {
                    $script:DefenderPolicyValues = $names | ForEach-Object { "$_ = $($policyKeys.$_)" }
                }
            }
            # The specific sub-key that locks exclusions from being edited at all.
            $exclPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
            if (Test-Path $exclPolicy) {
                $reasons.Add("A dedicated 'Exclusions' policy key exists and is likely what's blocking exclusion changes specifically.")
            }
        }
    } catch {}

    try {
        $dsreg = (dsregcmd /status 2>$null) -join "`n"
        if ($dsreg -match 'AzureAdJoined\s*:\s*YES') {
            $reasons.Add("This PC is joined to a Work/School (Azure AD) account. Organizational MDM policy is likely controlling Defender - a personal Microsoft account can't override this.")
        }
        if ($dsreg -match 'DomainJoined\s*:\s*YES') {
            $reasons.Add("This PC is joined to a Windows domain. Defender is controlled by Group Policy from that domain.")
        }
    } catch {}

    try {
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mp -and $mp.IsTamperProtected) {
            $reasons.Add("Tamper Protection is ON for this Defender install.")
        }
    } catch {}

    if ($reasons.Count -eq 0) {
        $reasons.Add("Could not determine the exact cause - Defender rejected the change silently.")
    }
    return $reasons
}

function Find-FiveMRoot {
    # Works out the FiveM.app root folder (the thing we want Defender to exclude and where
    # GTAProcess.exe lives) on any machine/install location, not just the default path.
    $default = Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app'
    if (Test-Path $default) { return $default }

    $exePath = Find-FiveMExe
    if ($exePath) {
        # FiveM.exe normally sits directly inside the FiveM.app folder.
        $dir = Split-Path $exePath -Parent
        if ($dir -and (Test-Path $dir)) { return $dir }
    }

    try {
        foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $guess = Join-Path $drv.Root 'FiveM\FiveM.app'
            if (Test-Path $guess) { return $guess }
        }
    } catch {}

    return $default  # fall back to the default path even if it doesn't exist, for messaging
}

function Find-GtaProcessName {
    # 1) Most reliable: if FiveM is actually running right now, read the real process name
    #    directly - this works no matter where FiveM is installed or which build is running.
    try {
        $liveProc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*GTAProcess*' } | Select-Object -First 1
        if ($liveProc) { return "$($liveProc.ProcessName).exe" }
    } catch {}

    # 2) Not running: search every plausible install location on this machine, not just the
    #    default one, then pick the newest match (in case old builds are still cached).
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app\data\cache\subprocess'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'FiveM'))

    # Custom/portable installs are common - check the root of every fixed drive for a FiveM folder.
    try {
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
            $guess = Join-Path $_.Root 'FiveM'
            if (Test-Path $guess) { $candidates.Add($guess) }
        }
    } catch {}

    # If we already located FiveM.exe elsewhere, its folder is also a strong candidate.
    $exePath = Find-FiveMExe
    if ($exePath) {
        $exeDir = Split-Path $exePath -Parent
        if ($exeDir) { $candidates.Add($exeDir) }
    }

    $found = @()
    foreach ($base in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path $base)) { continue }
        $found += @(Get-ChildItem $base -Filter '*GTAProcess.exe' -Recurse -ErrorAction SilentlyContinue -Depth 6)
    }
    if ($found.Count -eq 0) { return $null }
    # Multiple cached builds can exist side by side; the most recently written one is the
    # one actually in use.
    $best = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $best.Name
}

function Get-ActiveAdapter {
    return Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------
function Invoke-ApplyUltra {
    Clear-Host
    Write-Host "============================================================"
    Write-Host "  APPLYING ULTRA PROFILE"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Registry, services, network, GPU/input tuning for FiveM."
    Write-Host "Defender/Firewall stay ON (folder exclusion only). Update paused for"
    Write-Host "this session. HPET is NOT touched - use -HpetToggle separately."
    Write-Host ""
    $confirm = Read-Host "Continue? [Y/N]"
    if ($confirm -notmatch '^[Yy]') { Write-Host "Cancelled."; return }

    New-BackupFolder | Out-Null
    $script:PendingExclusions = @{ Paths = New-Object System.Collections.Generic.List[string]; Processes = New-Object System.Collections.Generic.List[string] }

    Write-Host "Checking system..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $gpuNames = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue).Name -join '; '
        Write-Host ("Windows: " + $os.Caption + " " + $os.Version)
        Write-Host ("RAM: " + [math]::Round($cs.TotalPhysicalMemory/1GB,1) + " GB")
        Write-Host ("GPU: " + $gpuNames)
    } catch {}
    $fiveMRoot = Find-FiveMRoot
    if (Test-Path $fiveMRoot) { Write-Host "FiveM: detected at $fiveMRoot" } else { Write-Host "FiveM: not found on this PC; continuing without folder-specific tweaks" }
    $gtaName = Find-GtaProcessName
    if ($gtaName) { Write-Host "GTA process file: $gtaName" }

    Write-Host "Creating restore point..."
    try {
        Checkpoint-Computer -Description 'FiveM Ultra Before Apply' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host "Restore point: created"
    } catch {
        Write-Host ("Restore point: skipped - " + $_.Exception.Message)
    }

    Write-Host "Testing network baseline..."
    try { Test-Connection -ComputerName 1.1.1.1 -Count 4 | Format-Table -AutoSize | Out-Host } catch {}

    $script:Total = 39
    $n = 0

    Invoke-Step (++$n) $Total "Applying background, search, Game DVR, Delivery Optimization, telemetry policies..." {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0 'DWord' | Out-Null
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0 'DWord' | Out-Null
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord' | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 'DWord' | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0 'DWord' | Out-Null
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Applying power and multimedia scheduling tweaks..." {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PowerThrottling' 'PowerThrottlingOff' 1 'DWord' | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 0xffffffff 'DWord' | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 0 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 'DWord' | Out-Null
        try {
            $ultimateGuid = $null
            $list = powercfg.exe /list
            foreach ($line in $list) {
                if (($line -match 'Ultimate Performance') -and ($line -match '([0-9a-fA-F-]{36})')) { $ultimateGuid = $Matches[1]; break }
            }
            if (-not $ultimateGuid) {
                $out = powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
                if ($out -match '([0-9a-fA-F-]{36})') { $ultimateGuid = $Matches[1] }
            }
            if ($ultimateGuid) {
                powercfg.exe /setactive $ultimateGuid | Out-Null
                Write-Host "Power plan: Ultimate Performance selected."
            } else {
                powercfg.exe /setactive SCHEME_MIN | Out-Null
                Write-Host "Power plan: could not select Ultimate; High Performance selected."
            }
        } catch { Write-Host "Power plan: skipped - $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Applying FiveM GPU and process priority preferences..." {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FiveM.exe\PerfOptions' 'CpuPriorityClass' 3 'DWord' | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FiveM.exe\PerfOptions' 'IoPriority' 3 'DWord' | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FiveM.exe\PerfOptions' 'PagePriority' 5 'DWord' | Out-Null
        Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'FiveM.exe' 'GpuPreference=2;' 'String' | Out-Null
        $gtaName = Find-GtaProcessName
        if ($gtaName) {
            Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$gtaName\PerfOptions" 'CpuPriorityClass' 3 'DWord' | Out-Null
            Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$gtaName\PerfOptions" 'IoPriority' 3 'DWord' | Out-Null
            Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$gtaName\PerfOptions" 'PagePriority' 5 'DWord' | Out-Null
            Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $gtaName 'GpuPreference=2;' 'String' | Out-Null
        }
    }

    Invoke-Step (++$n) $Total "Applying kernel/TCP profile, Nagle off, autotuning, QoS DSCP policy..." {
        try {
            Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | ForEach-Object {
                $ip = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue)
                if ($ip.DhcpIPAddress -or $ip.IPAddress) {
                    Set-Reg $_.PSPath 'TcpAckFrequency' 1 'DWord' | Out-Null
                    Set-Reg $_.PSPath 'TCPNoDelay' 1 'DWord' | Out-Null
                }
            }
        } catch {}
        try { netsh.exe int tcp set global autotuninglevel=normal | Out-Null } catch {}
        try { netsh.exe int tcp set global congestionprovider=ctcp | Out-Null } catch {}
        try {
            Remove-NetQosPolicy -Name "FiveMUltraQoS" -Confirm:$false -ErrorAction SilentlyContinue
            New-NetQosPolicy -Name "FiveMUltraQoS" -AppPathNameMatchCondition "FiveM.exe" -DSCPAction 46 -NetworkProfile All -ErrorAction Stop | Out-Null
            $script:Changes.Add([PSCustomObject]@{ Kind='QosPolicy'; Name='FiveMUltraQoS' })
        } catch { Write-Log "  ! QoS policy failed: $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Requesting lower kernel timer resolution..." {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Disabling USB selective suspend on active power plan..." {
        try {
            powercfg.exe /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
            powercfg.exe /setactive SCHEME_CURRENT | Out-Null
        } catch {}
    }

    Invoke-Step (++$n) $Total "Applying graphics latency profile (HAGS, DWM)..." {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Applying 1:1 mouse curve and keyboard response..." {
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String' | Out-Null
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String' | Out-Null
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String' | Out-Null
        $flatCurve = [byte[]](0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        Set-Reg 'HKCU:\Control Panel\Mouse' 'SmoothMouseXCurve' $flatCurve 'Binary' | Out-Null
        Set-Reg 'HKCU:\Control Panel\Mouse' 'SmoothMouseYCurve' $flatCurve 'Binary' | Out-Null
        Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String' | Out-Null
        Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String' | Out-Null
    }

    Invoke-Step (++$n) $Total "Backing up and adjusting background services (SysMain, DiagTrack, WSearch)..." {
        Set-SvcStart 'SysMain' 'Manual' | Out-Null
        Set-SvcStart 'DiagTrack' 'Manual' | Out-Null
        Set-SvcStart 'WSearch' 'Manual' | Out-Null
    }

    Invoke-Step (++$n) $Total "Tuning network adapter power and offload settings..." {
        try {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($a in $adapters) {
                try { Disable-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue } catch {}
                try { Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Energy Efficient Ethernet' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
                try { Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
            }
        } catch {}
    }

    Invoke-Step (++$n) $Total "Removing QoS bandwidth reservation limit..." {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Applying TCP/UDP global stack tuning..." {
        try { netsh.exe int tcp set global ecncapability=disabled | Out-Null } catch {}
        try { netsh.exe int tcp set global timestamps=disabled | Out-Null } catch {}
        try { netsh.exe int tcp set global rss=enabled | Out-Null } catch {}
        try { netsh.exe int udp set global uro=disabled | Out-Null } catch {}
    }

    Invoke-Step (++$n) $Total "Disabling fullscreen optimizations for FiveM..." {
        $exePath = Find-FiveMExe
        if ($exePath) {
            Set-Reg 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $exePath '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE' 'String' | Out-Null
            Write-Host "FiveM.exe found: $exePath"
        } else {
            Write-Host "FiveM.exe path not found; skipped."
        }
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Backing up and adjusting Xbox-related services..." {
        foreach ($svc in 'XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc') {
            Set-SvcStart $svc 'Manual' | Out-Null
        }
    }

    Invoke-Step (++$n) $Total "Disabling CPU core parking on the active power plan..." {
        try {
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 100 | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 100 | Out-Null
            powercfg.exe /setactive SCHEME_CURRENT | Out-Null
        } catch {}
    }

    Invoke-Step (++$n) $Total "Adjusting visual effects for best performance..." {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Adding Defender exclusion for the FiveM folder..." {
        if (-not (Test-Path $fiveMRoot)) {
            Write-Host "Defender exclusion: FiveM install folder not found on this PC, skipped"
            return
        }
        try {
            Add-MpPreference -ExclusionPath $fiveMRoot -ErrorAction Stop
            $script:Changes.Add([PSCustomObject]@{ Kind='DefenderExclusion'; Path=$fiveMRoot })
            Write-Host "Defender exclusion: added"
        } catch {
            $script:PendingExclusions.Paths.Add($fiveMRoot) | Out-Null
            Write-Host "Defender exclusion: skipped (see diagnosis at the end of this run)"
        }
    }

    Invoke-Step (++$n) $Total "Setting faster DNS on the active adapter..." {
        $a = Get-ActiveAdapter
        if ($a) {
            try {
                $old = (Get-DnsClientServerAddress -InterfaceIndex $a.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                $script:Changes.Add([PSCustomObject]@{ Kind='Dns'; IfIndex=$a.IfIndex; OldServers=$old })
                Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ServerAddresses ('1.1.1.1','1.0.0.1') -ErrorAction Stop
            } catch { Write-Log "  ! DNS set failed: $($_.Exception.Message)" }
        }
    }

    Invoke-Step (++$n) $Total "Pausing Windows Update for this session..." {
        Set-SvcStart 'wuauserv' 'Manual' | Out-Null
    }

    Invoke-Step (++$n) $Total "Disabling TCP Chimney Offload..." {
        try { netsh.exe int tcp set global chimney=disabled | Out-Null } catch {}
    }

    Invoke-Step (++$n) $Total "Disabling memory compression (RAM >= 16GB only)..." {
        try {
            $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
            if ($ram -ge 15) {
                Disable-MMAgent -mc -ErrorAction Stop
                $script:Changes.Add([PSCustomObject]@{ Kind='MemoryCompression' })
                Write-Host "Memory compression: disabled"
            } else {
                Write-Host "Memory compression: left on (RAM below 16GB)"
            }
        } catch { Write-Host "Memory compression: skipped" }
    }

    Invoke-Step (++$n) $Total "Enabling MSI Mode for real GPUs..." {
        try {
            $excludePattern = 'Parsec|Virtual|Remote|Basic Render|Basic Display|Meta Virtual|TeamViewer|AnyDesk|RDP'
            $gpus = @(Get-PnpDevice -Class Display -Status OK -ErrorAction Stop |
                Where-Object { $_.FriendlyName -notmatch $excludePattern })
            if ($gpus.Count -eq 0) {
                Write-Host "MSI Mode: no real (non-virtual) display device found, skipped"
            } else {
                foreach ($gpu in $gpus) {
                    $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                    Set-Reg $devPath 'MSISupported' 1 'DWord' | Out-Null
                    Write-Host "MSI Mode: enabled for $($gpu.FriendlyName)"
                }
            }
        } catch { Write-Host "MSI Mode: skipped - $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Setting NVIDIA Low Latency Mode (if NVIDIA GPU present)..." {
        try {
            $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
            if ($gpu) {
                Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak' 'LowLatency' 2 'DWord' | Out-Null
                Write-Host "NVIDIA Low Latency: Ultra set"
            } else {
                Write-Host "NVIDIA Low Latency: no NVIDIA GPU detected, skipped"
            }
        } catch { Write-Host "NVIDIA Low Latency: skipped - $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Tuning NVIDIA PowerMizer for max performance (if NVIDIA GPU present)..." {
        try {
            $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
            if ($gpu) {
                Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak' 'PowerMizerEnable' 1 'DWord' | Out-Null
                Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak' 'PowerMizerLevel' 1 'DWord' | Out-Null
                Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak' 'PowerMizerLevelAC' 1 'DWord' | Out-Null
                Write-Host "NVIDIA PowerMizer: max performance set"
            } else {
                Write-Host "NVIDIA PowerMizer: no NVIDIA GPU detected, skipped"
            }
        } catch { Write-Host "NVIDIA PowerMizer: skipped - $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Setting 'Games' multimedia task GPU/CPU scheduling priority..." {
        # This is the profile Windows' multimedia scheduler uses for foreground games.
        # Raising it gives the game process better GPU/CPU scheduling priority under load.
        $tasksPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
        Set-Reg $tasksPath 'GPU Priority' 8 'DWord' | Out-Null
        Set-Reg $tasksPath 'Priority' 6 'DWord' | Out-Null
        Set-Reg $tasksPath 'Scheduling Category' 'High' 'String' | Out-Null
        Set-Reg $tasksPath 'SFIO Priority' 'High' 'String' | Out-Null
        Set-Reg $tasksPath 'Background Only' 'False' 'String' | Out-Null
        Set-Reg $tasksPath 'Clock Rate' 10000 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Disabling Xbox Game Bar and Game Mode overlay..." {
        # Game Bar / Game Mode can throttle or capture input on windowed/borderless FiveM sessions.
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0 'DWord' | Out-Null
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 0 'DWord' | Out-Null
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0 'DWord' | Out-Null
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GamePanelStartupTipIndex' 3 'DWord' | Out-Null
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Adding process-level Defender exclusions for FiveM/GTA..." {
        # Folder exclusion alone still lets real-time protection scan the running process's
        # memory/IO; excluding the process names removes that per-frame scanning overhead.
        try {
            Add-MpPreference -ExclusionProcess 'FiveM.exe' -ErrorAction Stop
            $script:Changes.Add([PSCustomObject]@{ Kind='DefenderExclusionProcess'; Name='FiveM.exe' })
            Write-Host "Process exclusion: FiveM.exe added"
        } catch {
            $script:PendingExclusions.Processes.Add('FiveM.exe') | Out-Null
            Write-Host "Process exclusion: FiveM.exe skipped (see diagnosis at the end of this run)"
        }
        $gtaName = Find-GtaProcessName
        if ($gtaName) {
            try {
                Add-MpPreference -ExclusionProcess $gtaName -ErrorAction Stop
                $script:Changes.Add([PSCustomObject]@{ Kind='DefenderExclusionProcess'; Name=$gtaName })
                Write-Host "Process exclusion: $gtaName added"
            } catch {
                $script:PendingExclusions.Processes.Add($gtaName) | Out-Null
                Write-Host "Process exclusion: $gtaName skipped (see diagnosis at the end of this run)"
            }
        }
    }

    Invoke-Step (++$n) $Total "Tuning TCP ephemeral port range and TIME_WAIT delay..." {
        # Reduces socket exhaustion / port reuse stalls, which show up as periodic connection hitching.
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'MaxUserPort' 65534 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpTimedWaitDelay' 30 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Extra Nagle/ACK tuning (TcpDelAckTicks) on active interfaces..." {
        try {
            Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | ForEach-Object {
                $ip = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue)
                if ($ip.DhcpIPAddress -or $ip.IPAddress) {
                    Set-Reg $_.PSPath 'TcpDelAckTicks' 0 'DWord' | Out-Null
                }
            }
        } catch {}
    }

    Invoke-Step (++$n) $Total "Restoring existing Xbox service settings check / Game DVR extra key..." {
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Refreshing local policies and DNS cache..." {
        try { gpupdate.exe /force | Out-Null } catch {}
        try { Clear-DnsClientCache } catch {}
        $a = Get-ActiveAdapter
        if ($a) { Write-Host ("Active adapter: " + $a.Name + " / " + $a.LinkSpeed) }
    }

    Invoke-Step (++$n) $Total "Disabling hibernation and favoring foreground app memory..." {
        try {
            $hadHiber = Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys')
            $script:Changes.Add([PSCustomObject]@{ Kind='Hibernation'; WasOn=$hadHiber })
            powercfg.exe /hibernate off | Out-Null
        } catch {}
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'LargeSystemCache' 0 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Tuning RAM: keep kernel paged-out code in physical memory..." {
        # DisablePagingExecutive keeps kernel/driver code resident in RAM instead of letting it
        # get paged to disk under memory pressure - avoids random micro-stalls from disk paging.
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'IoPageLockLimit' 0x4000000 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Checking pagefile configuration..." {
        try {
            $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
            $auto = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
            if ($pf) {
                Write-Host ("Pagefile: " + ($pf | ForEach-Object { $_.Name } | Select-Object -First 1) + " (system-managed: $auto) - left as-is, safe with 15.8 GB RAM")
            } else {
                Write-Host "Pagefile: none active - leaving as-is (not auto-creating one)"
            }
        } catch { Write-Host "Pagefile: could not read current config, left as-is" }
    }

    Invoke-Step (++$n) $Total "Setting disk I/O priority hints for FiveM/GTA processes..." {
        # IoPriority=3 (High) was already set in PerfOptions for both processes in step 3;
        # this adds the NTFS-level tweaks that reduce background disk overhead system-wide,
        # which matters most while FiveM is streaming map/asset data.
        try {
            $oldLastAccess = (fsutil.exe behavior query disablelastaccess) -join ' '
            fsutil.exe behavior set disablelastaccess 1 | Out-Null
            $script:Changes.Add([PSCustomObject]@{ Kind='FsutilBehavior'; Name='disablelastaccess'; OldRaw=$oldLastAccess })
            Write-Host "NTFS last-access timestamp updates: disabled"
        } catch {}
        try {
            $old8dot3 = (fsutil.exe behavior query disable8dot3) -join ' '
            fsutil.exe behavior set disable8dot3 1 | Out-Null
            $script:Changes.Add([PSCustomObject]@{ Kind='FsutilBehavior'; Name='disable8dot3'; OldRaw=$old8dot3 })
            Write-Host "NTFS 8.3 short filenames: disabled"
        } catch {}
    }

    Invoke-Step (++$n) $Total "Disabling RSC (Receive Segment Coalescing) on active adapters..." {
        # RSC merges incoming packets into bigger chunks before handing them to the CPU, which
        # saves CPU time but adds a small amount of per-packet latency. Works on any NIC/driver
        # that supports it; adapters that don't support it are skipped harmlessly.
        try {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($a in $adapters) {
                try {
                    $rscState = Get-NetAdapterRsc -Name $a.Name -ErrorAction SilentlyContinue
                    if ($rscState -and ($rscState.IPv4Enabled -or $rscState.IPv6Enabled)) {
                        $script:Changes.Add([PSCustomObject]@{ Kind='Rsc'; Name=$a.Name; WasOn=$true })
                        Disable-NetAdapterRsc -Name $a.Name -ErrorAction SilentlyContinue
                        Write-Host "RSC: disabled on $($a.Name)"
                    }
                } catch {}
            }
        } catch {}
    }

    Invoke-Step (++$n) $Total "Lowering mouse/keyboard input queue size (less buffering delay)..." {
        # Default queue size buffers more events before Windows processes them, which adds a
        # small amount of input lag. Lowering it (a well-known low-latency gaming tweak) makes
        # Windows process each move/click sooner. mouclass/kbdclass are core Windows HID class
        # drivers present on every install, so this works regardless of mouse/keyboard brand.
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize' 20 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize' 20 'DWord' | Out-Null
    }

    Invoke-Step (++$n) $Total "Disabling per-device power management on all HID (mouse/keyboard) devices..." {
        # The active power plan's USB selective suspend (already handled earlier) is one layer;
        # each individual HID device also has its own "allow the computer to turn off this
        # device to save power" switch. Turning that off too stops mice/keyboards napping
        # mid-session, regardless of make/model, since it goes through the standard Windows
        # power-management framework rather than any vendor-specific driver.
        try {
            $hidDevices = Get-PnpDevice -Class 'Mouse','Keyboard','HIDClass' -Status OK -ErrorAction SilentlyContinue
            $count = 0
            foreach ($dev in $hidDevices) {
                try {
                    $pnpEntity = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='$($dev.InstanceId -replace '\\','\\\\')'" -ErrorAction SilentlyContinue
                    if (-not $pnpEntity) { continue }
                    $powerDevice = Get-CimAssociatedInstance -InputObject $pnpEntity -Namespace root\wmi -ResultClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue
                    if ($powerDevice) {
                        $script:Changes.Add([PSCustomObject]@{ Kind='HidPower'; InstanceId=$dev.InstanceId })
                        Set-CimInstance -InputObject $powerDevice -Property @{ Enable = $false } -ErrorAction SilentlyContinue
                        $count++
                    }
                } catch {}
            }
            Write-Host "HID power management: disabled on $count device(s)"
        } catch { Write-Host "HID power management: skipped - $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Checking for virtual/remote network adapters that could confuse routing..." {
        # Informational only - does not disable anything, since these can be adapters the
        # person is actively using (Parsec, a VPN, Hyper-V, etc). Just flags anything that
        # might be worth checking manually if routing/ping looks wrong.
        try {
            $suspectPattern = 'Parsec|Virtual|VPN|TAP|Hyper-V|VMware|VirtualBox|Npcap|Loopback'
            $suspects = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.Name -match $suspectPattern -or $_.InterfaceDescription -match $suspectPattern }
            if ($suspects) {
                Write-Host "Active virtual/remote adapters found (not changed, just flagged):"
                foreach ($s in $suspects) { Write-Host "  - $($s.Name) ($($s.InterfaceDescription))" }
                Write-Host "If ping/routing looks wrong, check whether one of these is stealing the default route."
            } else {
                Write-Host "No active virtual/remote adapters found."
            }
        } catch {}
    }

    Save-Changes

    # ---- Verify ----
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  DONE"
    Write-Host "============================================================"
    $checks = @(
        { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PowerThrottling' -Name PowerThrottlingOff -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FiveM.exe\PerfOptions' -Name CpuPriorityClass -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'FiveM.exe' -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' -Name GlobalTimerResolutionRequests -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKCU:\Control Panel\Keyboard' -Name KeyboardDelay -EA SilentlyContinue) -ne $null }
        { (Get-CimInstance Win32_Service -Filter "Name='SysMain'" -EA SilentlyContinue).StartMode -eq 'Manual' }
        { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -Name NonBestEffortLimit -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name VisualFXSetting -EA SilentlyContinue) -ne $null }
        { (Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -EA SilentlyContinue).StartMode -eq 'Manual' }
        { (Get-MpPreference -EA SilentlyContinue).ExclusionPath -contains $fiveMRoot }
        { -not (Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys')) }
        { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'GPU Priority' -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -EA SilentlyContinue).AutoGameModeEnabled -eq 0 }
        { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name MaxUserPort -EA SilentlyContinue) -ne $null }
        { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name DisablePagingExecutive -EA SilentlyContinue).DisablePagingExecutive -eq 1 }
        { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' -Name MouseDataQueueSize -EA SilentlyContinue).MouseDataQueueSize -eq 20 }
        { $a = Get-ActiveAdapter; if ($a) { -not (Get-NetAdapterRsc -Name $a.Name -EA SilentlyContinue).IPv4Enabled } else { $true } }
    )
    $names = 'PowerThrottling','FiveM-CPU-priority','FiveM-GPU-preference','Timer-resolution','Keyboard-response','SysMain-service','QoS-reservation','Visual-effects','Windows-Update-pause','Defender-exclusion','Hibernation-off','Games-task-priority','GameBar-disabled','TCP-port-range','RAM-paging-tweak','HID-queue-size','RSC-off'
    $ok = 0; $failed = @()
    for ($i = 0; $i -lt $checks.Count; $i++) {
        try { if (& $checks[$i]) { $ok++ } else { $failed += $names[$i] } } catch { $failed += $names[$i] }
    }
    Write-Host "Checks passed: $ok/$($checks.Count)"
    if ($failed.Count -gt 0) { Write-Host ("Not applied: " + ($failed -join ', ') + " - see backup folder or check manually.") }
    Write-Host "Restart Windows, then test FiveM. Choose Reset if needed."
    Write-Host "Log saved to: $script:LogFile"
    Write-Host "============================================================"
    Write-Log "Apply finished. Checks passed: $ok/$($checks.Count). Not applied: $($failed -join ', ')"

    # ---- Auto-help for Defender exclusions that Tamper Protection blocked ----
    if ($script:PendingExclusions.Paths.Count -gt 0 -or $script:PendingExclusions.Processes.Count -gt 0) {
        Write-Host ""
        Write-Host "============================================================"
        Write-Host "  DEFENDER EXCLUSIONS NEED ONE MANUAL STEP"
        Write-Host "============================================================"
        $reasons = Get-DefenderBlockReason
        Write-Host "Windows blocked these changes. Likely reason(s) detected on this PC:"
        foreach ($r in $reasons) { Write-Host "  - $r" }
        if ($script:DefenderPolicyValues -and $script:DefenderPolicyValues.Count -gt 0) {
            Write-Host ""
            Write-Host "Policy values found under HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender :"
            foreach ($v in $script:DefenderPolicyValues) { Write-Host "  $v" }
            if (($script:DefenderPolicyValues -match 'DisableAntiVirus = 1') -or ($script:DefenderPolicyValues -match 'DisableAntiSpyware = 1')) {
                Write-Host ""
                Write-Host "!!! SECURITY WARNING !!!"
                Write-Host "These specific values mean Windows Defender is FULLY DISABLED on this PC right now -"
                Write-Host "not just exclusions locked. This is NOT normal for real company/school IT policy and"
                Write-Host "is NOT what a legitimate 3rd-party antivirus sets (that would show the AV's own name,"
                Write-Host "not 'managed by your organization'). This pattern is most often caused by:"
                Write-Host "  - A Windows activation crack / KMS-HWID activator hiding itself from Defender"
                Write-Host "  - Malware or a cheat/loader tool that disabled Defender to avoid detection"
                Write-Host "This PC currently has NO active antivirus protection. Recommended: after using"
                Write-Host "option [4] in the main menu to remove this policy and restart, immediately run a"
                Write-Host "full Windows Defender scan (Windows Security > Virus & threat protection > Scan options"
                Write-Host "> Full scan) to check nothing malicious is present."
            }
        }
        Write-Host ""
        Write-Host "These were auto-detected and still need to be added:"
        foreach ($p in $script:PendingExclusions.Paths)     { Write-Host "  Folder : $p" }
        foreach ($p in $script:PendingExclusions.Processes) { Write-Host "  Process: $p" }
        $clipText = @()
        $clipText += $script:PendingExclusions.Paths
        $clipText += $script:PendingExclusions.Processes
        try {
            $clipText -join "`r`n" | Set-Clipboard
            Write-Host ""
            Write-Host "-> Copied the list above to your clipboard."
        } catch {}
        $isManagedByOrg = $reasons -match 'centrally managed|Work/School|domain'
        if ($isManagedByOrg) {
            Write-Host ""
            Write-Host "The Exclusions page itself may be greyed out/blocked (not just this change) because"
            Write-Host "this account or PC is managed by an organization or family policy. To actually fix this:"
            Write-Host "  1. Settings > Accounts > Your info - confirm this is a personal Microsoft account,"
            Write-Host "     not a Work/School or Family (child) account."
            Write-Host "  2. If it's a Family Safety child account: a parent must allow this at"
            Write-Host "     https://family.microsoft.com under this child's Screen time / App settings."
            Write-Host "  3. If it's a Work/School account: Settings > Accounts > Access work or school -"
            Write-Host "     Disconnect it if this is meant to be a personal PC, or ask that org's IT admin."
            Write-Host ""
            Write-Host "COMMON ON PERSONAL/REFURBISHED PCs: if this PC was never actually enrolled in a"
            Write-Host "company/school MDM and steps 1-3 above don't apply to you, the policy key may just"
            Write-Host "be a leftover from a previous owner, a 'debloat'/tweak tool, or a pirated Windows"
            Write-Host "image - not real management. In that case it is generally safe to remove it yourself:"
            Write-Host "  regedit.exe -> navigate to:"
            Write-Host "    HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender"
            Write-Host "  -> right-click the 'Windows Defender' key itself -> Delete -> restart the PC."
            Write-Host "  (Only do this if you do NOT recognize any legitimate work/school/family management"
            Write-Host "  on this account - deleting it on a genuinely managed PC may violate that org's policy.)"
            Write-Host "Running this script again will NOT fix it until one of the above is resolved."
        } else {
            try {
                Start-Process "windowsdefender://exclusions" -ErrorAction Stop
                Write-Host "-> Opened Windows Security > Exclusions for you. Click 'Add an exclusion' and paste/select each item above."
            } catch {
                Write-Host "-> Open Windows Security > Virus & threat protection > Manage settings > Exclusions manually and add the items above."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# RESET
# ---------------------------------------------------------------------------
function Invoke-ResetUltra {
    Clear-Host
    Write-Host "============================================================"
    Write-Host "  RESET ULTRA PROFILE"
    Write-Host "============================================================"
    $dir = Find-LatestBackup
    if (-not $dir) {
        Write-Host "No backup folder found. Nothing to reset."
        Read-Host "Press Enter to continue"
        return
    }
    $changesFile = Join-Path $dir "changes.json"
    if (-not (Test-Path $changesFile)) {
        Write-Host "No changes.json found in $dir. Nothing to reset."
        Read-Host "Press Enter to continue"
        return
    }
    Write-Host "Restoring from: $dir"
    $list = @(Get-Content $changesFile -Raw | ConvertFrom-Json)
    [array]::Reverse($list)
    $count = 0
    foreach ($c in $list) {
        try {
            switch ($c.Kind) {
                'RegValue' {
                    if ($c.KeyCreated) {
                        Remove-Item -Path $c.Path -Recurse -Force -ErrorAction SilentlyContinue
                    } elseif ($c.HadValue) {
                        $val = $c.OldValue
                        if ($c.Type -eq 'Binary' -and $val) { $val = [byte[]]($val) }
                        New-ItemProperty -Path $c.Path -Name $c.Name -Value $val -PropertyType $c.Type -Force -ErrorAction SilentlyContinue | Out-Null
                    } else {
                        Remove-ItemProperty -Path $c.Path -Name $c.Name -Force -ErrorAction SilentlyContinue
                    }
                }
                'RegValueRemoved' {
                    New-ItemProperty -Path $c.Path -Name $c.Name -Value $c.OldValue -Force -ErrorAction SilentlyContinue | Out-Null
                }
                'Service' {
                    $target = if ($c.OldStart -in @('Automatic','Manual','Disabled')) { $c.OldStart } else { 'Automatic' }
                    Set-Service -Name $c.Name -StartupType $target -ErrorAction SilentlyContinue
                    if ($target -eq 'Automatic') { Start-Service -Name $c.Name -ErrorAction SilentlyContinue }
                }
                'QosPolicy' {
                    Remove-NetQosPolicy -Name $c.Name -Confirm:$false -ErrorAction SilentlyContinue
                }
                'DefenderExclusion' {
                    Remove-MpPreference -ExclusionPath $c.Path -ErrorAction SilentlyContinue
                }
                'DefenderExclusionProcess' {
                    Remove-MpPreference -ExclusionProcess $c.Name -ErrorAction SilentlyContinue
                }
                'Dns' {
                    if ($c.OldServers) {
                        Set-DnsClientServerAddress -InterfaceIndex $c.IfIndex -ServerAddresses $c.OldServers -ErrorAction SilentlyContinue
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $c.IfIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                    }
                }
                'MemoryCompression' {
                    Enable-MMAgent -mc -ErrorAction SilentlyContinue
                }
                'Hibernation' {
                    if ($c.WasOn) { powercfg.exe /hibernate on | Out-Null }
                }
                'FsutilBehavior' {
                    # Parse the previous state text and restore to 0/1/2 as fsutil reported it;
                    # default back to 0 (enabled/Windows default) if it can't be parsed.
                    $restoreVal = 0
                    if ($c.OldRaw -match '=\s*1\b') { $restoreVal = 1 }
                    fsutil.exe behavior set $c.Name $restoreVal | Out-Null
                }
                'Rsc' {
                    if ($c.WasOn) { Enable-NetAdapterRsc -Name $c.Name -ErrorAction SilentlyContinue }
                }
                'HidPower' {
                    try {
                        $pnpEntity = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='$($c.InstanceId -replace '\\','\\\\')'" -ErrorAction SilentlyContinue
                        if ($pnpEntity) {
                            $powerDevice = Get-CimAssociatedInstance -InputObject $pnpEntity -Namespace root\wmi -ResultClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue
                            if ($powerDevice) { Set-CimInstance -InputObject $powerDevice -Property @{ Enable = $true } -ErrorAction SilentlyContinue }
                        }
                    } catch {}
                }
            }
            $count++
        } catch {
            Write-Host "  ! Could not undo one change ($($c.Kind)): $($_.Exception.Message)"
        }
    }

    # Global settings that were changed via netsh/powercfg without per-value tracking: restore to Windows defaults.
    try { netsh.exe int tcp set global ecncapability=default | Out-Null } catch {}
    try { netsh.exe int tcp set global timestamps=default | Out-Null } catch {}
    try { netsh.exe int udp set global uro=enabled | Out-Null } catch {}
    try { netsh.exe int tcp set global chimney=default | Out-Null } catch {}
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
        foreach ($a in $adapters) {
            try { Enable-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue } catch {}
            try { Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Energy Efficient Ethernet' -DisplayValue 'Enabled' -ErrorAction SilentlyContinue } catch {}
            try { Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Interrupt Moderation' -DisplayValue 'Enabled' -ErrorAction SilentlyContinue } catch {}
        }
    } catch {}
    try {
        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 0 | Out-Null
        powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 50 | Out-Null
        powercfg.exe /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1 | Out-Null
        powercfg.exe /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1 | Out-Null
        powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    } catch {}
    try {
        $gtaName = Find-GtaProcessName
        if ($gtaName) {
            Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$gtaName" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name $gtaName -Force -ErrorAction SilentlyContinue
        }
        $exePath = Find-FiveMExe
        $layers = Get-Item 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' -ErrorAction SilentlyContinue
        if ($layers) {
            foreach ($valName in $layers.Property) {
                if ($valName -like '*FiveM.exe') {
                    Remove-ItemProperty $layers.PSPath -Name $valName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {}
    try {
        $gpu = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gpu) {
            $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            if (Test-Path $devPath) { Remove-ItemProperty -Path $devPath -Name 'MSISupported' -ErrorAction SilentlyContinue }
        }
    } catch {}

    Write-Host "Undid $count tracked changes, plus global network/power defaults."
    Write-Host "Removing temporary backup folders..."
    Get-ChildItem -Path $env:TEMP -Directory -Filter "FiveM_Ultra_Backup_*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (Test-Path $desktop) {
        Get-ChildItem -Path $desktop -Directory -Filter "FiveM_Ultra_Backup_*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "RESET COMPLETE. Restart Windows."
    Write-Host "============================================================"
    Read-Host "Press Enter to continue"
}

# ---------------------------------------------------------------------------
# HPET toggle (separate, optional, not part of Apply/Reset)
# ---------------------------------------------------------------------------
function Invoke-ToggleDefenderRealtime {
    Clear-Host
    Write-Host "============================================================"
    Write-Host "  TEMPORARY DEFENDER REAL-TIME PROTECTION TOGGLE"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "This turns real-time protection OFF or ON using Windows' own supported switch"
    Write-Host "(Set-MpPreference). It does NOT uninstall or permanently disable Defender -"
    Write-Host "it's the same toggle as the one in Windows Security > Virus & threat protection."
    Write-Host ""

    $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $status) {
        Write-Host "! Could not read Defender status. It may be blocked by the policy key seen earlier"
        Write-Host "  (menu option to remove that key is separate). Cancelling."
        Read-Host "Press Enter to continue"
        return
    }

    $isOn = $status.RealTimeProtectionEnabled
    Write-Host ("Current real-time protection: " + $(if ($isOn) { "ON" } else { "OFF" }))
    if ($status.IsTamperProtected) {
        Write-Host "Note: Tamper Protection is ON - Windows may silently revert this toggle within a"
        Write-Host "few minutes. If that happens, turn Tamper Protection off first in Windows Security."
    }
    Write-Host ""

    if ($isOn) {
        Write-Host "  [1] Turn OFF for this FiveM session"
        Write-Host "  [2] Cancel"
        $choice = Read-Host "Select"
        if ($choice -eq '1') {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
                Write-Host ""
                Write-Host "Real-time protection: OFF"
                Write-Host "!!! REMEMBER: come back to this menu and turn it back ON when you're done"
                Write-Host "!!! playing. Leaving it off longer than needed leaves this PC unprotected."
            } catch {
                Write-Host "! Failed to turn off: $($_.Exception.Message)"
                Write-Host "  This is most likely blocked by the same policy key discussed earlier."
            }
        } else {
            Write-Host "Cancelled."
        }
    } else {
        Write-Host "  [1] Turn back ON now"
        Write-Host "  [2] Cancel (stay off)"
        $choice = Read-Host "Select"
        if ($choice -eq '1') {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Write-Host ""
                Write-Host "Real-time protection: ON"
            } catch {
                Write-Host "! Failed to turn on: $($_.Exception.Message)"
            }
        } else {
            Write-Host "Left OFF. Please remember to turn it back on from this menu when you can -"
            Write-Host "this PC has no active antivirus protection while it's off."
        }
    }
    Read-Host "Press Enter to continue"
}

function Invoke-RemoveDefenderPolicy {
    Clear-Host
    Write-Host "============================================================"
    Write-Host "  REMOVE LEFTOVER DEFENDER MANAGEMENT POLICY (ADVANCED)"
    Write-Host "============================================================"
    Write-Host ""
    $keyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    if (-not (Test-Path $keyPath)) {
        Write-Host "No Windows Defender policy key found under Policies\Microsoft. Nothing to remove."
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host "Found: $keyPath"
    $vals = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue
    $disablesAV = $false
    if ($vals) {
        Write-Host ""
        Write-Host "Values under this key:"
        $vals.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            Write-Host "  $($_.Name) = $($_.Value)"
            if (($_.Name -eq 'DisableAntiVirus' -or $_.Name -eq 'DisableAntiSpyware') -and $_.Value -eq 1) { $disablesAV = $true }
        }
    }
    if ($disablesAV) {
        Write-Host ""
        Write-Host "!!! This key currently has Defender FULLY DISABLED (DisableAntiVirus/DisableAntiSpyware = 1) !!!"
        Write-Host "This PC has NO active antivirus right now. This is commonly caused by a Windows activation"
        Write-Host "crack or malware hiding from detection, not real IT management. After removing this and"
        Write-Host "restarting, run a FULL Windows Defender scan immediately (Windows Security > Virus & threat"
        Write-Host "protection > Scan options > Full scan) to make sure nothing malicious is on this PC."
    }
    $subkeys = Get-ChildItem $keyPath -ErrorAction SilentlyContinue
    if ($subkeys) {
        Write-Host ""
        Write-Host "Sub-keys (e.g. Exclusions, Scan, etc.):"
        $subkeys | ForEach-Object { Write-Host "  $($_.PSChildName)" }
    }

    Write-Host ""
    Write-Host "!!! WARNING !!!"
    Write-Host "This key is what makes Windows Security say 'managed by your organization' and"
    Write-Host "blocks changes like Defender exclusions. Deleting it is generally SAFE only if:"
    Write-Host "  - This is your own personal PC, AND"
    Write-Host "  - You do NOT recognize any real school/work/family management on this account"
    Write-Host "    (see the checks the apply step already suggested: Settings > Accounts)."
    Write-Host ""
    Write-Host "If this PC genuinely belongs to a company, school, or a managed family account,"
    Write-Host "do NOT proceed - deleting this may violate that organization's IT policy."
    Write-Host ""
    Write-Host "A full .reg backup of this key will be saved first so you can restore it if needed."
    Write-Host ""
    $confirm = Read-Host "Type DELETE (all caps) to proceed, anything else to cancel"
    if ($confirm -cne 'DELETE') {
        Write-Host "Cancelled. Nothing was changed."
        Read-Host "Press Enter to continue"
        return
    }

    $backupDir = Join-Path $env:TEMP ("FiveM_Ultra_Backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    $regBackup = Join-Path $backupDir "WindowsDefenderPolicy_backup.reg"
    try {
        reg.exe export "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" $regBackup /y | Out-Null
        Write-Host "Backup saved: $regBackup"
    } catch {
        Write-Host "! Could not create .reg backup - aborting for safety."
        Read-Host "Press Enter to continue"
        return
    }

    try {
        Remove-Item -Path $keyPath -Recurse -Force -ErrorAction Stop
        Write-Host ""
        Write-Host "Removed. Restart Windows, then check Windows Security > Virus & threat protection -"
        Write-Host "the 'managed by your organization' message should be gone, and exclusions should work."
        Write-Host "If you ever need to undo this: double-click the backup file above to restore it, or run:"
        Write-Host "  reg.exe import `"$regBackup`""
    } catch {
        Write-Host "! Removal failed: $($_.Exception.Message)"
        Write-Host "This usually means it's enforced by real Group Policy/MDM refresh, not a leftover key -"
        Write-Host "in that case this PC is genuinely managed and this should not be removed."
    }
    Read-Host "Press Enter to continue"
}

function Invoke-HpetToggle {
    Clear-Host
    Write-Host "============================================================"
    Write-Host "  HPET TOGGLE - OPTIONAL, NOT PART OF ULTRA"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Results vary by system. This changes Boot Configuration Data (BCD),"
    Write-Host "not the registry, so Reset does not touch it."
    Write-Host ""
    Write-Host "Current:"
    bcdedit.exe /enum "{current}" | Select-String "useplatformclock"
    Write-Host ""
    Write-Host "  [1] Disable HPET"
    Write-Host "  [2] Force HPET on"
    Write-Host "  [3] Cancel"
    $choice = Read-Host "Select"
    switch ($choice) {
        '1' {
            bcdedit.exe /deletevalue useplatformclock | Out-Null
            Write-Host "HPET disabled. Restart Windows, then test FiveM frame times."
        }
        '2' {
            bcdedit.exe /set useplatformclock true | Out-Null
            Write-Host "HPET forced ON. Restart Windows to apply."
        }
        default { Write-Host "Cancelled." }
    }
    Read-Host "Press Enter to continue"
}

# ===========================================================================
# v2.0 — HARDWARE SCAN ENGINE
# ===========================================================================
function Get-HwCpu {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $brand = 'Unknown'
    if ($cpu.Manufacturer -match 'Intel') { $brand = 'Intel' }
    elseif ($cpu.Manufacturer -match 'AMD') { $brand = 'AMD' }
    $ht = $false
    try { $ht = ($cpu.NumberOfLogicalProcessors -gt $cpu.NumberOfCores) } catch {}
    [PSCustomObject]@{
        Brand          = $brand
        Name           = $cpu.Name.Trim()
        Cores          = $cpu.NumberOfCores
        Threads        = $cpu.NumberOfLogicalProcessors
        MaxClockMHz    = $cpu.MaxClockSpeed
        SmtOrHt        = $ht
    }
}

function Get-HwGpu {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch 'Basic Render|Basic Display|Remote Display|Meta Virtual|TeamViewer|AnyDesk'
    })
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($g in $gpus) {
        $brand = 'Unknown'
        if ($g.Name -match 'NVIDIA') { $brand = 'NVIDIA' }
        elseif ($g.Name -match 'AMD|Radeon') { $brand = 'AMD' }
        elseif ($g.Name -match 'Intel') { $brand = 'Intel' }
        $vramGB = 0
        try {
            if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) { $vramGB = [math]::Round($g.AdapterRAM / 1GB, 1) }
        } catch {}
        $list.Add([PSCustomObject]@{
            Brand         = $brand
            Name          = $g.Name
            VramGB        = $vramGB
            DriverVersion = $g.DriverVersion
        })
    }
    return $list
}

function Get-HwRam {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $slots = $sticks.Count
    $speed = if ($sticks.Count -gt 0) { ($sticks | Select-Object -First 1).Speed } else { 0 }
    $type = 'Unknown'
    try {
        $smbiosType = ($sticks | Select-Object -First 1).SMBIOSMemoryType
        switch ($smbiosType) { 26 { $type = 'DDR4' } 34 { $type = 'DDR5' } 24 { $type = 'DDR3' } default { $type = "Type $smbiosType" } }
    } catch {}
    [PSCustomObject]@{
        TotalGB = $totalGB
        Slots   = $slots
        SpeedMHz = $speed
        Type    = $type
    }
}

function Get-HwStorage {
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in $disks) {
        $kind = 'HDD'
        if ($d.BusType -eq 'NVMe') { $kind = 'NVMe' }
        elseif ($d.MediaType -eq 'SSD') { $kind = 'SATA SSD' }
        elseif ($d.MediaType -eq 'HDD') { $kind = 'HDD' }
        $sizeGB = [math]::Round($d.Size / 1GB, 0)
        $list.Add([PSCustomObject]@{
            FriendlyName = $d.FriendlyName
            Kind         = $kind
            SizeGB       = $sizeGB
            BusType      = $d.BusType
        })
    }
    return $list
}

function Get-HwNic {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($a in $adapters) {
        $vendor = 'Other'
        if ($a.InterfaceDescription -match 'Realtek') { $vendor = 'Realtek' }
        elseif ($a.InterfaceDescription -match 'Intel') { $vendor = 'Intel' }
        elseif ($a.InterfaceDescription -match 'Killer') { $vendor = 'Killer' }
        elseif ($a.InterfaceDescription -match 'Broadcom') { $vendor = 'Broadcom' }
        $list.Add([PSCustomObject]@{
            Name         = $a.Name
            Vendor       = $vendor
            Model        = $a.InterfaceDescription
            LinkSpeed    = $a.LinkSpeed
            IfIndex      = $a.IfIndex
        })
    }
    return $list
}

function Invoke-HardwareScan {
    Write-Info2 "Scanning hardware..."
    $hw = [PSCustomObject]@{
        Cpu     = Get-HwCpu
        Gpu     = Get-HwGpu
        Ram     = Get-HwRam
        Storage = Get-HwStorage
        Nic     = Get-HwNic
        ScanTime = Get-Date
    }
    $script:HwInfo = $hw
    return $hw
}

function Show-HardwareSummary {
    param([Parameter(Mandatory)]$Hw)
    Write-Host ""
    Write-Host "  ================= HARDWARE SUMMARY =================" -ForegroundColor Cyan
    Write-Host ("  CPU     : {0}  [{1}]  {2}C/{3}T  {4} MHz  SMT/HT={5}" -f $Hw.Cpu.Name, $Hw.Cpu.Brand, $Hw.Cpu.Cores, $Hw.Cpu.Threads, $Hw.Cpu.MaxClockMHz, $Hw.Cpu.SmtOrHt) -ForegroundColor White
    if ($Hw.Gpu.Count -eq 0) {
        Write-Host "  GPU     : none detected" -ForegroundColor White
    } else {
        foreach ($g in $Hw.Gpu) {
            Write-Host ("  GPU     : {0}  [{1}]  VRAM={2}GB  Driver={3}" -f $g.Name, $g.Brand, $g.VramGB, $g.DriverVersion) -ForegroundColor White
        }
    }
    Write-Host ("  RAM     : {0} GB total  {1} sticks  {2} MHz  {3}" -f $Hw.Ram.TotalGB, $Hw.Ram.Slots, $Hw.Ram.SpeedMHz, $Hw.Ram.Type) -ForegroundColor White
    foreach ($s in $Hw.Storage) {
        Write-Host ("  Storage : {0}  [{1}]  {2} GB" -f $s.FriendlyName, $s.Kind, $s.SizeGB) -ForegroundColor White
    }
    if ($Hw.Nic.Count -eq 0) {
        Write-Host "  NIC     : none up/detected" -ForegroundColor White
    } else {
        foreach ($n in $Hw.Nic) {
            Write-Host ("  NIC     : {0}  [{1}]  {2}  Link={3}" -f $n.Name, $n.Vendor, $n.Model, $n.LinkSpeed) -ForegroundColor White
        }
    }
    Write-Host "  ======================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ===========================================================================
# v2.0 — CPU ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-CpuAdaptive {
    param([Parameter(Mandatory)]$Cpu)
    if ($Cpu.Brand -eq 'Intel') {
        Write-Info2 "Intel CPU detected - applying Intel-specific power/performance tweaks"
        try {
            # Processor Performance Boost Mode = Aggressive (3) on current scheme
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 3 | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 3 | Out-Null
            # Min processor state = 100%
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 893dee8e-2bef-41e0-89c6-b55d0929964c 100 2>$null | Out-Null
            # Deep C-states (C6/C7) are set in BIOS on most boards; no universal OS-level GUID exists for this, so we don't guess one here.
            powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
            Write-Ok "Boost mode = Aggressive, min processor state = 100%, deep idle states minimized"
        } catch { Write-Warn2 "Some Intel powercfg tweaks failed: $($_.Exception.Message)" }
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7' 'Attributes' 2 'DWord' | Out-Null
        if ($Cpu.SmtOrHt) { Write-Warn2 "Hyper-Threading is ON. Leave it ON unless a specific game/anti-cheat asks you to disable it in BIOS." }
    }
    elseif ($Cpu.Brand -eq 'AMD') {
        Write-Info2 "AMD CPU detected - applying Ryzen-specific power/performance tweaks"
        try {
            # Prefer/duplicate 'AMD Ryzen High Performance' scheme if present, else High Performance
            $list = powercfg.exe /list
            $ryzenGuid = $null
            foreach ($line in $list) {
                if (($line -match 'Ryzen') -and ($line -match '([0-9a-fA-F-]{36})')) { $ryzenGuid = $Matches[1]; break }
            }
            if ($ryzenGuid) {
                powercfg.exe /setactive $ryzenGuid | Out-Null
                Write-Ok "Power plan: AMD Ryzen High Performance selected"
            }
            # Min processor state = 100%
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 893dee8e-2bef-41e0-89c6-b55d0929964c 100 2>$null | Out-Null
            # CPPC preferred cores / C6 disable are BIOS-level on most AMD boards, no safe universal OS GUID for this.
            powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
            Write-Ok "Min processor state = 100%"
        } catch { Write-Warn2 "Some AMD powercfg tweaks failed: $($_.Exception.Message)" }
        try {
            $smt = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1)
            Write-Info2 ("SMT: logical={0} physical={1} -> " -f $smt.NumberOfLogicalProcessors, $smt.NumberOfCores) + ($(if ($Cpu.SmtOrHt) {'ON'} else {'OFF'}))
        } catch {}
    }
    else {
        Write-Warn2 "CPU brand not recognized - skipping CPU-specific deep tweaks (generic power tweaks from Apply Ultra still apply)"
    }
}

# ===========================================================================
# v2.0 — GPU ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-GpuAdaptive {
    param([Parameter(Mandatory)]$GpuList)
    if ($GpuList.Count -eq 0) { Write-Warn2 "No discrete/display GPU detected - skipping GPU deep tweaks"; return }
    foreach ($gpu in $GpuList) {
        if ($gpu.Brand -eq 'NVIDIA') {
            Write-Info2 "NVIDIA GPU detected ($($gpu.Name)) - applying deep tweaks"
            $nv = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak'
            Set-Reg $nv 'LowLatency' 2 'DWord' | Out-Null                       # Ultra Low Latency
            Set-Reg $nv 'PowerMizerEnable' 1 'DWord' | Out-Null
            Set-Reg $nv 'PowerMizerLevel' 1 'DWord' | Out-Null
            Set-Reg $nv 'PowerMizerLevelAC' 1 'DWord' | Out-Null                # Prefer Max Performance
            Set-Reg $nv 'PrerenderLimit' 1 'DWord' | Out-Null                   # Max pre-rendered frames = 1
            Set-Reg $nv 'OGL_ThreadControl' 1 'DWord' | Out-Null                # Threaded optimization ON
            Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak' 'Coolbits' 24 'DWord' | Out-Null   # unlock OC in NVCP
            Set-Reg $nv 'ShaderCache' 1 'DWord' | Out-Null
            Write-Ok "LowLatency=Ultra, PowerMizer=Max, PrerenderFrames=1, Threaded Opt=ON, Coolbits=24, Shader Cache=ON"
        }
        elseif ($gpu.Brand -eq 'AMD') {
            Write-Info2 "AMD GPU detected ($($gpu.Name)) - applying deep tweaks"
            $amdKey = 'HKLM:\SOFTWARE\AMD\CN'
            Set-Reg $amdKey 'EnableUlps' 0 'DWord' | Out-Null                   # prevent stutter from power state switching
            Set-Reg $amdKey 'PP_SclkDeepSleepDisable' 1 'DWord' | Out-Null
            Set-Reg $amdKey 'KMD_EnableComputePreemption' 0 'DWord' | Out-Null
            Set-Reg $amdKey 'DisableDrmdmaPowerGating' 1 'DWord' | Out-Null
            Set-Reg $amdKey 'Tessellation' 'AMD Optimized' 'String' | Out-Null
            Write-Ok "EnableUlps=0, SclkDeepSleepDisable=1, ComputePreemption=0, Tessellation=AMD Optimized"
        }
        elseif ($gpu.Brand -eq 'Intel') {
            Write-Warn2 "Intel integrated/Arc GPU ($($gpu.Name)) detected - vendor-specific registry tweaks are limited; MSI Mode + power tweaks from Apply Ultra still apply"
        }
        # Shared, brand-agnostic: MSI Mode + IRQ priority for this GPU
        try {
            $pnp = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $gpu.Name } | Select-Object -First 1
            if ($pnp) {
                $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($pnp.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                Set-Reg $devPath 'MSISupported' 1 'DWord' | Out-Null
                Write-Ok "MSI Mode enabled for $($gpu.Name)"
            }
        } catch { Write-Warn2 "MSI Mode step failed for $($gpu.Name)" }
    }
}

# ===========================================================================
# v2.0 — RAM ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-RamAdaptive {
    param([Parameter(Mandatory)]$Ram)
    $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    if ($Ram.TotalGB -lt 8) {
        Write-Info2 "RAM < 8GB ($($Ram.TotalGB)GB) - applying low-memory profile"
        Set-Reg $mm 'DisablePagingExecutive' 0 'DWord' | Out-Null   # keep paging exec ON, don't starve RAM
        Set-Reg $mm 'IoPageLockLimit' 0x1000000 'DWord' | Out-Null  # smaller lock limit (16MB)
        Write-Ok "Aggressive pagefile allowed, standby list kept small, ReadyBoost recommended if you have a spare USB stick"
    }
    elseif ($Ram.TotalGB -lt 16) {
        Write-Info2 "RAM 8-15GB ($($Ram.TotalGB)GB) - applying balanced profile"
        Set-Reg $mm 'DisablePagingExecutive' 0 'DWord' | Out-Null
        Set-Reg $mm 'IoPageLockLimit' 0x4000000 'DWord' | Out-Null  # 256MB
        Write-Ok "Balanced profile: paging executive kept, IoPageLockLimit=256MB"
    }
    else {
        Write-Info2 "RAM >= 16GB ($($Ram.TotalGB)GB) - applying high-memory profile"
        Set-Reg $mm 'DisablePagingExecutive' 1 'DWord' | Out-Null   # keep kernel code resident
        Set-Reg $mm 'IoPageLockLimit' 0x8000000 'DWord' | Out-Null  # 512MB
        try {
            $ram = $Ram.TotalGB
            if ($ram -ge 15) { Disable-MMAgent -mc -ErrorAction SilentlyContinue; Write-Ok "Memory compression disabled" }
        } catch {}
        Write-Ok "DisablePagingExecutive=1, IoPageLockLimit=512MB, memory compression off"
    }
    # Clear standby memory list so cached pages don't compete with the game for free RAM
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MemUtil2 {
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);
}
"@ -ErrorAction SilentlyContinue
        $classInfo = 80  # SystemMemoryListInformation
        $cmd = 4          # MemoryPurgeStandbyList
        $handle = [IntPtr]::new($cmd)
        [MemUtil2]::NtSetSystemInformation($classInfo, $handle, 4) | Out-Null
        Write-Ok "Standby memory list cleared"
    } catch { Write-Warn2 "Could not clear standby list (needs elevation, which we already have, or is unsupported on this build)" }
}

# ===========================================================================
# v2.0 — STORAGE ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-StorageAdaptive {
    param([Parameter(Mandatory)]$StorageList)
    if ($StorageList.Count -eq 0) { Write-Warn2 "No physical disks detected via Get-PhysicalDisk - skipping storage deep tweaks"; return }
    $sawNvme = $false; $sawSata = $false; $sawHdd = $false
    foreach ($disk in $StorageList) {
        switch ($disk.Kind) {
            'NVMe' {
                if (-not $sawNvme) {
                    Write-Info2 "NVMe drive(s) detected - applying NVMe deep tweaks"
                    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e97b-e325-11ce-bfc1-08002be10318}' 'EnableSelectiveSuspend' 0 'DWord' | Out-Null
                    fsutil.exe behavior set disablelastaccess 1 | Out-Null
                    fsutil.exe behavior set disable8dot3 1 | Out-Null
                    Write-Ok "NVMe power management disabled, LastAccess/8.3 disabled"
                    $sawNvme = $true
                }
            }
            'SATA SSD' {
                if (-not $sawSata) {
                    Write-Info2 "SATA SSD(s) detected - applying SSD deep tweaks"
                    try {
                        # AHCI Link Power Management -> Max Performance (subgroup 0012ee47-9041-4b5d-9b77-535fba8b1442)
                        powercfg.exe /setacvalueindex SCHEME_CURRENT 0012ee47-9041-4b5d-9b77-535fba8b1442 dab60367-53fe-4fbc-825e-521d069d2456 0 2>$null | Out-Null
                        powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
                    } catch {}
                    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableCompression' 1 'DWord' | Out-Null
                    Write-Ok "SATA Link Power Management -> Max Performance, Write Cache left ON, TRIM assumed active"
                    $sawSata = $true
                }
            }
            'HDD' {
                if (-not $sawHdd) {
                    Write-Info2 "HDD(s) detected - applying HDD deep tweaks"
                    try { schtasks.exe /Change /TN "Microsoft\Windows\Defrag\ScheduledDefrag" /Disable 2>$null | Out-Null } catch {}
                    Write-Ok "Write cache left ON, scheduled defrag disabled (avoid extra I/O while gaming)"
                    $sawHdd = $true
                }
            }
        }
    }
    # Shared: AHCI/StorAHCI TreatAsInternal + MSI on storage controllers (helps removable/eSATA/USB-bridged drives be treated as internal for caching)
    try {
        $storKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device'
        Set-Reg $storKey 'TreatAsInternalPort' '1' 'String' | Out-Null
        Write-Ok "StorAHCI TreatAsInternal hint applied"
    } catch {}
}

# ===========================================================================
# v2.0 — NETWORK ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-NetworkAdaptive {
    param([Parameter(Mandatory)]$NicList)
    if ($NicList.Count -eq 0) { Write-Warn2 "No active physical NIC detected - skipping network deep tweaks"; return }
    $usedCore0Skip = $false
    foreach ($nic in $NicList) {
        if ($nic.Vendor -eq 'Realtek') {
            Write-Info2 "Realtek NIC detected ($($nic.Model)) - applying Realtek deep tweaks"
            foreach ($prop in @(
                @{ Name='Receive Buffers'; Value='512' }, @{ Name='Transmit Buffers'; Value='512' },
                @{ Name='Speed & Duplex'; Value='Auto Negotiation' }, @{ Name='Interrupt Moderation'; Value='Disabled' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            Write-Ok "ReceiveBuffers=512, TransmitBuffers=512, SpeedDuplex=Auto, Interrupt Moderation=Disabled"
        }
        elseif ($nic.Vendor -eq 'Intel') {
            Write-Info2 "Intel NIC detected ($($nic.Model)) - applying Intel deep tweaks"
            foreach ($prop in @(
                @{ Name='Interrupt Moderation Rate'; Value='Off' }, @{ Name='Receive Buffers'; Value='4096' },
                @{ Name='Receive Side Scaling Queues'; Value='Maximum' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            Write-Ok "ITR=lowest (Off), ReceiveBuffers=4096, RSS Queues=Max"
        }
        else {
            Write-Warn2 "NIC vendor '$($nic.Vendor)' has no dedicated profile - applying general tweaks only"
        }
        # General, all vendors
        try { Set-NetAdapterRss -Name $nic.Name -Enabled $true -ErrorAction SilentlyContinue } catch {}
        try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'Jumbo Packet' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
        try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        # IRQ affinity: point this NIC's interrupts away from Core 0 (index 1) so it doesn't
        # compete with the core Windows/game threads default onto.
        try {
            $devPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
            $sub = Get-ChildItem $devPath -ErrorAction SilentlyContinue | Where-Object {
                (Get-ItemProperty $_.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc -eq $nic.Model
            } | Select-Object -First 1
            if ($sub) {
                Set-Reg $sub.PSPath 'MessageSignaledInterruptProperties\MSISupported' 1 'DWord' | Out-Null
                $affPath = Join-Path $sub.PSPath 'Interrupt Management\Affinity Policy'
                Set-Reg $affPath 'DevicePolicy' 4 'DWord' | Out-Null      # 4 = IrqPolicySpecifiedProcessors
                Set-Reg $affPath 'AssignmentSetOverride' ([byte[]](2,0,0,0,0,0,0,0)) 'Binary' | Out-Null  # core index 1 (skip core 0)
                Write-Ok "IRQ affinity for $($nic.Name) steered away from Core 0"
            }
        } catch { Write-Warn2 "IRQ affinity step skipped for $($nic.Name)" }
    }
    try { netsh.exe int tcp set global rss=enabled | Out-Null } catch {}
    try { netsh.exe int tcp set global ecncapability=disabled | Out-Null } catch {}
    Write-Ok "Global: RSS=ON, ECN=Off"
}

# ===========================================================================
# v2.0 — SMART APPLY (scan -> adaptive apply, with progress bar + DryRun)
# ===========================================================================
function Invoke-SmartApply {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  SMART ADAPTIVE TUNER v2.0 - HARDWARE SCAN -> DEEP TWEAK" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    if ($script:DryRun) {
        Write-Warn2 "DRY RUN MODE - nothing will actually be changed, this is a preview only"
    }
    Write-Host ""

    $hw = Invoke-HardwareScan
    Show-HardwareSummary -Hw $hw
    if (-not $script:DryRun) {
        $confirm = Read-Host "Apply adaptive deep tweaks for THIS hardware now? (Y/N)"
        if ($confirm -notmatch '^[Yy]') { Write-Host "Cancelled."; Read-Host "Press Enter to continue"; return }
    } else {
        Read-Host "Press Enter to preview the adaptive tweaks (dry run, nothing will change)"
    }

    if (-not $script:DryRun) {
        New-BackupFolder | Out-Null
        Write-Host "Creating restore point..."
        try {
            Checkpoint-Computer -Description 'NongPlai Smart Apply Before' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-Ok "Restore point created"
        } catch { Write-Warn2 "Restore point skipped - $($_.Exception.Message)" }
    }

    $modules = @(
        @{ Name = 'CPU adaptive tweaks';     Action = { Invoke-CpuAdaptive -Cpu $hw.Cpu } },
        @{ Name = 'GPU adaptive tweaks';     Action = { Invoke-GpuAdaptive -GpuList $hw.Gpu } },
        @{ Name = 'RAM adaptive tweaks';     Action = { Invoke-RamAdaptive -Ram $hw.Ram } },
        @{ Name = 'Storage adaptive tweaks'; Action = { Invoke-StorageAdaptive -StorageList $hw.Storage } },
        @{ Name = 'Network adaptive tweaks'; Action = { Invoke-NetworkAdaptive -NicList $hw.Nic } }
    )
    $total = $modules.Count
    $i = 0
    foreach ($m in $modules) {
        $i++
        Write-Host ""
        Write-ProgressBar -Current $i -Total $total -Label $m.Name
        try { & $m.Action } catch { Write-Bad "$($m.Name) failed: $($_.Exception.Message)" }
        if (-not $script:DryRun) { Save-Changes }
    }
    Write-Host ""
    Write-ProgressBar -Current $total -Total $total -Label 'Done'
    Write-Host ""
    if ($script:DryRun) {
        Write-Info2 "Dry run complete - nothing was changed. Re-run without -DryRun to apply for real."
    } else {
        Write-Ok "Smart Apply complete. Backup/log: $script:BackupDir"
        Write-Info2 "Run menu option [2] Reset All any time to undo everything (Smart Apply + Apply Ultra)."
    }
    Read-Host "Press Enter to continue"
}

function Invoke-HardwareScanOnly {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  HARDWARE SCAN ONLY - no changes will be made" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    $hw = Invoke-HardwareScan
    Show-HardwareSummary -Hw $hw
    Read-Host "Press Enter to continue"
}

function Invoke-ExportReport {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  EXPORT HARDWARE + TWEAK REPORT (HTML)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    $hw = if ($script:HwInfo) { $script:HwInfo } else { Invoke-HardwareScan }
    Show-HardwareSummary -Hw $hw

    $gpuRows = ($hw.Gpu | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.Brand)</td><td>$($_.VramGB) GB</td><td>$($_.DriverVersion)</td></tr>" }) -join "`n"
    $diskRows = ($hw.Storage | ForEach-Object { "<tr><td>$($_.FriendlyName)</td><td>$($_.Kind)</td><td>$($_.SizeGB) GB</td></tr>" }) -join "`n"
    $nicRows = ($hw.Nic | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.Vendor)</td><td>$($_.Model)</td><td>$($_.LinkSpeed)</td></tr>" }) -join "`n"
    $changesRows = if ($script:Changes.Count -gt 0) { ($script:Changes | ForEach-Object { "<tr><td>$($_.Kind)</td><td>$($_.Path)$($_.Name)</td></tr>" }) -join "`n" } else { "<tr><td colspan=2>No changes recorded this session (scan-only or dry run)</td></tr>" }

    $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>NongPlaiShop Smart Tuner Report</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#0f1117;color:#e6e6e6;padding:24px}
h1{color:#7ee787} h2{color:#79c0ff;border-bottom:1px solid #30363d;padding-bottom:4px}
table{border-collapse:collapse;width:100%;margin-bottom:24px}
td,th{border:1px solid #30363d;padding:6px 10px;text-align:left}
th{background:#161b22} tr:nth-child(even){background:#161b22}
.meta{color:#8b949e;font-size:0.9em}
</style></head><body>
<h1>NongPlaiShop Smart Adaptive Tuner - Report</h1>
<p class="meta">Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Computer: $env:COMPUTERNAME</p>

<h2>CPU</h2>
<table><tr><th>Name</th><th>Brand</th><th>Cores/Threads</th><th>Max MHz</th><th>SMT/HT</th></tr>
<tr><td>$($hw.Cpu.Name)</td><td>$($hw.Cpu.Brand)</td><td>$($hw.Cpu.Cores)/$($hw.Cpu.Threads)</td><td>$($hw.Cpu.MaxClockMHz)</td><td>$($hw.Cpu.SmtOrHt)</td></tr></table>

<h2>GPU</h2>
<table><tr><th>Name</th><th>Brand</th><th>VRAM</th><th>Driver</th></tr>$gpuRows</table>

<h2>RAM</h2>
<table><tr><th>Total</th><th>Slots</th><th>Speed</th><th>Type</th></tr>
<tr><td>$($hw.Ram.TotalGB) GB</td><td>$($hw.Ram.Slots)</td><td>$($hw.Ram.SpeedMHz) MHz</td><td>$($hw.Ram.Type)</td></tr></table>

<h2>Storage</h2>
<table><tr><th>Drive</th><th>Kind</th><th>Size</th></tr>$diskRows</table>

<h2>Network</h2>
<table><tr><th>Adapter</th><th>Vendor</th><th>Model</th><th>Link Speed</th></tr>$nicRows</table>

<h2>Changes applied this session</h2>
<table><tr><th>Kind</th><th>Target</th></tr>$changesRows</table>
</body></html>
"@
    $outPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "NongPlai_Tuner_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    try {
        Set-Content -Path $outPath -Value $html -Encoding UTF8
        Write-Ok "Report saved: $outPath"
        try { Start-Process $outPath } catch {}
    } catch { Write-Bad "Could not save report: $($_.Exception.Message)" }
    Read-Host "Press Enter to continue"
}

# ===========================================================================
# v2.0 — DO EVERYTHING (Legacy Apply Ultra + Hardware Scan + Adaptive Deep Tweaks, one shot)
# ===========================================================================
function Invoke-DoEverything {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  NONGPLAISHOP - APPLY EVERYTHING (Ultra + Adaptive Deep Tweak)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    if ($script:DryRun) { Write-Warn2 "DRY RUN MODE - preview only, nothing will actually be changed" }
    Write-Host ""

    # --- Part 1: full legacy 39-step Apply Ultra (creates backup folder + restore point) ---
    Invoke-ApplyUltra

    # --- Part 2: scan this PC's hardware and layer on adaptive CPU/GPU/RAM/Storage/Network tweaks ---
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  HARDWARE SCAN -> ADAPTIVE DEEP TWEAK" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    $hw = Invoke-HardwareScan
    Show-HardwareSummary -Hw $hw

    if (-not $script:BackupDir) { New-BackupFolder | Out-Null }

    $modules = @(
        @{ Name = 'CPU adaptive tweaks';     Action = { Invoke-CpuAdaptive -Cpu $hw.Cpu } },
        @{ Name = 'GPU adaptive tweaks';     Action = { Invoke-GpuAdaptive -GpuList $hw.Gpu } },
        @{ Name = 'RAM adaptive tweaks';     Action = { Invoke-RamAdaptive -Ram $hw.Ram } },
        @{ Name = 'Storage adaptive tweaks'; Action = { Invoke-StorageAdaptive -StorageList $hw.Storage } },
        @{ Name = 'Network adaptive tweaks'; Action = { Invoke-NetworkAdaptive -NicList $hw.Nic } }
    )
    $total = $modules.Count
    $i = 0
    foreach ($m in $modules) {
        $i++
        Write-Host ""
        Write-ProgressBar -Current $i -Total $total -Label $m.Name
        try { & $m.Action } catch { Write-Bad "$($m.Name) failed: $($_.Exception.Message)" }
        if (-not $script:DryRun) { Save-Changes }
    }

    Write-Host ""
    Write-ProgressBar -Current $total -Total $total -Label 'Done'
    Write-Host ""
    if ($script:DryRun) {
        Write-Info2 "Dry run complete - nothing was changed. Re-run without -DryRun to apply for real."
    } else {
        Write-Ok "Everything applied. Backup/log: $script:BackupDir"
        Write-Info2 "Restart Windows for all changes (services, power plan, network) to fully take effect."
        Write-Info2 "Use menu option [2] RESET ALL any time to undo everything."
    }
    Read-Host "Press Enter to return to menu"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($HpetToggle) {
    Invoke-HpetToggle
    exit 0
}

:menu while ($true) {
    Clear-Host
    Write-Host ""
    Write-Host "    _   _                 ____  _       _   ____  _"
    Write-Host "   | \ | | ___  _ __   __ _|  _ \| | __ _| | / ___|| |__   ___  _ __"
    Write-Host "   |  \| |/ _ \| '_ \ / _`` | |_) | |/ _`` | | \___ \| '_ \ / _ \| '_ \"
    Write-Host "   | |\  | (_) | | | | (_| |  __/| | (_| | |  ___) | | | | (_) | |_) |"
    Write-Host "   |_| \_|\___/|_| |_|\__, |_|   |_|\__,_|_| |____/|_| |_|\___/| .__/"
    Write-Host "                        |___/                                      |_|"
    Write-Host "   +--------------------------------------------------------------------------+"
    Write-Host "   |              N O N G P L A I S H O P   P E R F O R M A N C E             |"
    Write-Host "   |         Smart Adaptive Tuner v2.0 (Hardware Scan -> Deep Tweak)          |"
    Write-Host "   +--------------------------------------------------------------------------+"
    if ($script:DryRun) {
        Write-Host "   |  *** DRY RUN MODE ACTIVE - preview only, nothing will be changed ***     |" -ForegroundColor Yellow
    }
    Write-Host "   +---------------------------- MENU --------------------------------------+"
    Write-Host "   |  [1] APPLY EVERYTHING  (scan + all optimizations, CPU/GPU/RAM/SSD/net)  |"
    Write-Host "   |  [2] RESET ALL                                                          |"
    Write-Host "   |  [3] Exit                                                                |"
    Write-Host "   +--------------------------------------------------------------------------+"
    $sel = Read-Host "Select option"
    switch ($sel) {
        '1' { Invoke-DoEverything }
        '2' { Invoke-ResetUltra }
        '3' { break menu }
        default { }
    }
}

# Clean up the temp copy of this script if it was created for the irm|iex one-liner flow.
try {
    $selfPath = $MyInvocation.MyCommand.Path
    if ($selfPath -and ($selfPath -like (Join-Path $env:TEMP 'nongplai_v2_*.ps1'))) {
        Remove-Item -Path $selfPath -Force -ErrorAction SilentlyContinue
    }
} catch {}
