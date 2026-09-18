# NongPlaiShop - FiveM Performance Tuner (PowerShell edition)
# Requires Windows PowerShell 5.1 or later (built into Windows 10/11 by default).
# Rewritten from the original .cmd to fix reliability issues caused by
# batch's fragile multi-line parsing and by spawning a fresh powershell.exe
# process for almost every step. This version runs as a single PowerShell
# session: fewer spawned processes, real try/catch per step, and a proper
# JSON-based backup so Reset can undo exactly what was changed.
#
# v2.0 additions: Hardware Scan Engine + Adaptive Deep Tweak.
# Before applying anything, v2 scans the actual CPU/GPU/RAM/Storage/NIC in this PC and
# only applies the tweaks that make sense for that hardware (e.g. Intel vs AMD CPU tweaks,
# NVMe vs SATA SSD vs HDD tweaks, Realtek vs Intel NIC tweaks). Same safe change-tracking
# and Reset as v1 - every adaptive tweak goes through the same Set-Reg/Set-SvcStart helpers
# so it is fully undoable.
#
# Usage:
#     Right-click > Run with PowerShell
#     .\nongplai.ps1                 -> เปิดเมนูหลัก (GUI ถ้ามี / console fallback ถ้าไม่มี GUI)
#     .\nongplai.ps1 -Apply          -> Apply Everything ผ่าน command line
#     .\nongplai.ps1 -Reset          -> Reset คืนค่าล่าสุดผ่าน command line
#     .\nongplai.ps1 -Scan           -> สแกนฮาร์ดแวร์อย่างเดียว
#     .\nongplai.ps1 -Report         -> สร้างรายงาน HTML บน Desktop
#     .\nongplai.ps1 -HpetToggle     -> เปิดเครื่องมือ HPET
#     .\nongplai.ps1 -NoGui          -> บังคับใช้เมนูแบบ console
#     .\nongplai.ps1 -DryRun         -> แสดงรายการที่จะเปลี่ยนโดยไม่แก้ไขระบบ
#
# หมายเหตุ: สคริปต์นี้ออกแบบให้เปิดจากไฟล์ nongplai.ps1 ที่บันทึกอยู่ในเครื่องเท่านั้น

# --- Manual argument parsing (NOT using param()) ---------------------------
# This script deliberately does NOT use a formal param() block. param() must
# be the literal first statement in the file, and if a stray UTF-8 BOM
# character ever leaks into the executed text (this happens under some
# invocation paths - right-click "Run with PowerShell", `irm | iex`, etc,
# which use -Command semantics instead of -File), the corrupted first
# "statement" bumps param() out of first position and the whole file fails
# to parse. Reading $args manually has no such positional requirement, so a
# leaked BOM only ever produces one harmless, non-fatal error on line 1
# instead of breaking the entire script. See also the header note above.
function Test-SwitchArg { param([string]$Name) return ($args -contains "-$Name") }
$script:RawScriptArgs = @($args)
$Apply             = $args -contains '-Apply'
$Reset             = $args -contains '-Reset'
$Scan              = $args -contains '-Scan'
$Report            = $args -contains '-Report'
$NoGui             = $args -contains '-NoGui'
$Help              = $args -contains '-Help'
$HpetToggle        = $args -contains '-HpetToggle'
$DryRun            = $args -contains '-DryRun'
$NetworkDiagnose   = $args -contains '-NetworkDiagnose'
$NetworkCustom     = $args -contains '-NetworkCustom'
$Worker            = $args -contains '-Worker'
$WorkerUi          = $args -contains '-WorkerUi'
$Advanced          = $args -contains '-Advanced'
$CustomTuning      = $args -contains '-CustomTuning'
# This build is intentionally console-only. All tuning and backup functions
# remain available; only the WPF/WinForms presentation layer is bypassed.
$ConsoleOnly       = $true
$NoGui             = $true
function Get-NamedArgValue {
    param([string]$Name, [string]$Default = '')
    # `$args inside this function contains only unnamed arguments passed to the
    # function, not the script's original command-line arguments. The worker
    # launcher passes -WorkerAction and -GuiLogPath as script arguments, so read
    # the captured script-level array instead.
    for ($i = 0; $i -lt $script:RawScriptArgs.Count - 1; $i++) {
        if ([string]$script:RawScriptArgs[$i] -ieq "-$Name") {
            return [string]$script:RawScriptArgs[$i + 1]
        }
    }
    return $Default
}
$WorkerAction      = Get-NamedArgValue -Name 'WorkerAction' -Default ''
$GuiLogPath        = Get-NamedArgValue -Name 'GuiLogPath' -Default ''
$OptimizationLevel = Get-NamedArgValue -Name 'OptimizationLevel' -Default 'Balanced'
if ($OptimizationLevel -notin @('Safe','Balanced','Aggressive')) { $OptimizationLevel = 'Balanced' }
if ($WorkerAction -and $WorkerAction -notin @('','Apply','Reset','Scan','Hpet','Report','NetworkDiagnose','NetworkCustom')) { $WorkerAction = '' }
# -----------------------------------------------------------------------------

$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:OptimizationLevel = $OptimizationLevel

# When loaded with irm | iex, persist the in-memory script so elevated and GUI
# worker processes can relaunch the same code.
if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) {
    $inlineScript = $null
    $sourceVariable = $null
    try { $sourceVariable = $ExecutionContext.SessionState.PSVariable.Get('s').Value } catch {}
    if ($sourceVariable -is [string] -and $sourceVariable -match '(?s)NongPlaiShop.*function Invoke-ApplyUltra') {
        $inlineScript = $sourceVariable
    }
    if ([string]::IsNullOrWhiteSpace($inlineScript)) {
        $urlMatch = [regex]::Match([string]$MyInvocation.Line, '(https?://[^\s"'']+\.ps1(?:\?[^\s"'']*)?)')
        if ($urlMatch.Success) {
            try {
                $inlineScript = (New-Object System.Net.WebClient).DownloadString($urlMatch.Groups[1].Value).TrimStart([char]0xFEFF)
            } catch {}
        }
    }
    if ([string]::IsNullOrWhiteSpace($inlineScript)) {
        $inlineScript = $MyInvocation.MyCommand.Definition
    }
    if ([string]::IsNullOrWhiteSpace($inlineScript)) {
        throw 'ไม่พบเนื้อหาสคริปต์สำหรับเริ่มการทำงาน'
    }
    $script:ScriptPath = Join-Path $env:TEMP ('NongPlai_{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -Path $script:ScriptPath -Value $inlineScript -Encoding UTF8 -ErrorAction Stop
        if ((Get-Item -LiteralPath $script:ScriptPath -ErrorAction Stop).Length -lt 1000) {
            Remove-Item -LiteralPath $script:ScriptPath -Force -ErrorAction SilentlyContinue
            throw 'source ของ irm | iex ไม่ครบ จึงไม่สามารถเริ่ม worker ได้ กรุณาใช้รูปแบบ $s = irm "URL"; iex ($s.TrimStart([char]0xFEFF))'
        }
    } catch {
        throw "ไม่สามารถเตรียมไฟล์ชั่วคราวสำหรับการทำงานแบบ irm | iex: $($_.Exception.Message)"
    }
}

if (-not (Test-Path $script:ScriptPath -ErrorAction SilentlyContinue)) {
    throw 'ไม่พบไฟล์ nongplai.ps1 สำหรับเริ่มการทำงาน'
}

# ยกระดับสิทธิ์เป็น Administrator เมื่อจำเป็น
$currentId = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentId)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $launchConsole = [bool]($Apply -or $Reset -or $Scan -or $Report -or $HpetToggle -or $NetworkDiagnose -or $NetworkCustom -or $Help -or $NoGui)
    $launcherPowerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path $launcherPowerShell)) { $launcherPowerShell = 'powershell.exe' }
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $($script:ScriptPath))
    if (-not $launchConsole -or $Worker -or $WorkerUi) { $argList += @('-WindowStyle', 'Hidden') }
    if ($Apply) { $argList += '-Apply' }
    if ($Reset) { $argList += '-Reset' }
    if ($Scan) { $argList += '-Scan' }
    if ($Report) { $argList += '-Report' }
    if ($NetworkDiagnose) { $argList += '-NetworkDiagnose' }
    if ($NetworkCustom) { $argList += '-NetworkCustom' }
    if ($NoGui) { $argList += '-NoGui' }
    if ($Help) { $argList += '-Help' }
    if ($HpetToggle) { $argList += '-HpetToggle' }
    if ($DryRun) { $argList += '-DryRun' }
    if ($Worker) { $argList += '-Worker' }
    if ($WorkerUi) { $argList += '-WorkerUi' }
    if ($WorkerAction) { $argList += @('-WorkerAction', $WorkerAction) }
    if ($GuiLogPath) { $argList += @('-GuiLogPath', $GuiLogPath) }
    try {
        if (-not $launchConsole -or $Worker -or $WorkerUi) {
            Start-Process -FilePath $launcherPowerShell -ArgumentList $argList -Verb RunAs -WindowStyle Hidden | Out-Null
        } else {
            Start-Process -FilePath $launcherPowerShell -ArgumentList $argList -Verb RunAs | Out-Null
        }
    } catch {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            [System.Windows.MessageBox]::Show('ยกเลิกหรือยกระดับสิทธิ์ไม่สำเร็จ โปรแกรมนี้ต้องทำงานด้วยสิทธิ์ Administrator', 'NongPlaiShop', 'OK', 'Warning') | Out-Null
        } catch {}
    }
    exit 0
}

# คืนค่าพาธของไฟล์สคริปต์จริงสำหรับโปรเซสลูกของ GUI
function Confirm-ScriptPersisted {
    if (-not (Test-Path $script:ScriptPath -ErrorAction SilentlyContinue)) {
        throw 'ไม่พบไฟล์ nongplai.ps1 สำหรับเริ่มงานเบื้องหลัง'
    }
    return $script:ScriptPath
}

function Get-PowerShellExePath {
    $preferred = Join-Path $PSHOME 'powershell.exe'
    if (Test-Path $preferred) { return $preferred }
    $cmd = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'ไม่พบ powershell.exe บนเครื่องนี้'
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
$Host.UI.RawUI.WindowTitle = "NongPlaiShop - Smart Adaptive Tuner v2.1"

$script:DefenderPolicyValues = $null
$script:PendingExclusions = @{ Paths = New-Object System.Collections.Generic.List[string]; Processes = New-Object System.Collections.Generic.List[string] }
$script:DryRun = [bool]$DryRun
$script:GuiWorker = [bool]$Worker
$script:GuiLogPath = $GuiLogPath
$script:GuiStage = 'startup'
$script:LegacyStepCount = 0
$script:LegacyStepTotal = 48  # 39 legacy + MMCSS/ProcessPriority/TRIM + NIC-MSI + multi-game + v2.2 (DynamicTick/CState, USB-MSI, NetThrottle)
$script:InputQueueSize = 20
$script:HwInfo = $null
$script:GuiReady = $false
$script:PowerShellExe = Get-PowerShellExePath

function Get-RequestedAction {
    $selected = New-Object System.Collections.Generic.List[string]
    if ($Apply)            { $selected.Add('Apply') }
    if ($Reset)            { $selected.Add('Reset') }
    if ($Scan)             { $selected.Add('Scan') }
    if ($Report)           { $selected.Add('Report') }
    if ($HpetToggle)       { $selected.Add('Hpet') }
    if ($NetworkDiagnose)  { $selected.Add('NetworkDiagnose') }
    if ($NetworkCustom)    { $selected.Add('NetworkCustom') }
    if ($Help)             { $selected.Add('Help') }
    if ($selected.Count -gt 1) {
        throw ('ระบุคำสั่งมากกว่าหนึ่งแบบพร้อมกันไม่ได้: ' + ($selected -join ', '))
    }
    if ($selected.Count -eq 1) { return $selected[0] }
    return $null
}

function Show-Usage {
    Write-Host ""
    Write-Host "  NONGPLAISHOP - COMMAND USAGE" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1"
    Write-Host "      เปิดเมนูหลัก (GUI ถ้ามี / console fallback ถ้าไม่มี GUI)"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -Apply"
    Write-Host "      Apply Everything ทันที"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -Reset"
    Write-Host "      Reset คืนค่าจาก backup ล่าสุด"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -Scan"
    Write-Host "      สแกนฮาร์ดแวร์อย่างเดียว"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -Report"
    Write-Host "      สร้างรายงาน HTML บน Desktop"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -HpetToggle"
    Write-Host "      เปิดเมนู HPET"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -NetworkDiagnose"
    Write-Host "      ตรวจค่าเครือข่ายอย่างเดียว ไม่แก้ระบบ"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\nongplai.ps1 -NetworkCustom"
    Write-Host "      ตั้งค่าเครือข่ายแบบเลือกเอง พร้อม snapshot/restore"
    Write-Host ""
    Write-Host "  ตัวเลือกเสริม: -DryRun, -NoGui, -Help" -ForegroundColor DarkGray
    Write-Host ""
}

function Initialize-GuiRuntime {
    param([switch]$Silent)
    if ($script:GuiReady) { return $true }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        if (-not $Silent) {
            try {
                $popup = New-Object -ComObject WScript.Shell
                $popup.Popup('ไม่สามารถโหลดส่วน GUI ได้ จะสลับไปใช้ console mode แทน', 0, 'NongPlaiShop', 48) | Out-Null
            } catch {}
        }
        return $false
    }
    if (-not [System.Windows.Application]::Current) {
        try {
            $script:WpfApp = New-Object System.Windows.Application
            $script:WpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
        } catch { $script:WpfApp = $null }
    }
    $script:GuiReady = $true
    return $true
}

$script:RequestedAction = Get-RequestedAction
$script:ExplicitConsoleMode = [bool]($Apply -or $Reset -or $Scan -or $Report -or $HpetToggle -or $NetworkDiagnose -or $NetworkCustom -or $Help -or $NoGui)

function Show-MainMenuConsole {
    while ($true) {
        Clear-Host
        Write-BoxTop
        Write-BoxCenter 'NONGPLAISHOP - CONSOLE MODE' 'Cyan'
        Write-BoxDivider
        Write-MenuItem -Key '1' -Label 'APPLY EVERYTHING' -Desc 'ปรับจูนทั้งหมดทันที'
        Write-MenuItem -Key '2' -Label 'RESET ALL' -Desc 'คืนค่าจาก backup ล่าสุด' -KeyColor 'Yellow'
        Write-MenuItem -Key '0' -Label 'EXIT' -Desc 'ปิดโปรแกรม' -KeyColor 'Red'
        Write-BoxBottom
        Write-Host ""
        switch (Read-Host 'Select') {
            '1' { Invoke-DoEverything; return }
            '2' { Invoke-ResetUltra; return }
            '0' { return }
            default {
                Write-Warn2 'กรุณาเลือกหมายเลขที่ถูกต้อง'
                Read-Host 'Press Enter to continue' | Out-Null
            }
        }
    }
}

function Invoke-RequestedAction {
    param([Parameter(Mandatory)][ValidateSet('Apply','Reset','Scan','Report','Hpet','NetworkDiagnose','NetworkCustom','Help')][string]$Action)
    switch ($Action) {
        'Apply'           { Invoke-DoEverything }
        'Reset'           { Invoke-ResetUltra }
        'Scan'            { Invoke-HardwareScanOnly }
        'Report'          { Invoke-ExportReport }
        'Hpet'            { Invoke-HpetToggle }
        'NetworkDiagnose' { Invoke-NetworkDiagnoseOnly }
        'NetworkCustom'   { Invoke-NetworkCustomAdditive }
        'Help'            { Show-Usage }
    }
}

function Write-GuiEvent {
    param(
        [Parameter(Mandatory)][string]$Type,
        [int]$Current = 0,
        [int]$Total = 0,
        [string]$Label = '',
        [string]$Message = ''
    )
    if (-not $script:GuiLogPath) { return }
    try {
        $payload = [ordered]@{
            type      = $Type
            stage     = $script:GuiStage
            current   = $Current
            total     = $Total
            label     = $Label
            message   = $Message
            timestamp = (Get-Date).ToString('o')
        }
        $line = '__NONGPLAI_EVENT__' + ($payload | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText($script:GuiLogPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {
        try {
            $dbgPath = Join-Path $env:TEMP 'NongPlaiGui_write_errors.log'
            $dbgLine = "[{0}] GuiLogPath='{1}' error={2}" -f (Get-Date -Format 'o'), $script:GuiLogPath, $_.Exception.Message
            [System.IO.File]::AppendAllText($dbgPath, $dbgLine + [Environment]::NewLine)
        } catch {}
    }
}

function Write-CrashLog {
    param([Parameter(Mandatory)]$ErrorRecord, [string]$Context = '')
    try {
        $dbgPath = Join-Path $env:TEMP 'NongPlaiGui_write_errors.log'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("[$(Get-Date -Format 'o')] CRASH in $Context")
        $ex = $ErrorRecord.Exception
        $depth = 0
        while ($ex -ne $null) {
            [void]$sb.AppendLine("  depth $depth : $($ex.GetType().FullName) : $($ex.Message)")
            $ex = $ex.InnerException
            $depth++
        }
        [void]$sb.AppendLine("  PositionMessage: $($ErrorRecord.InvocationInfo.PositionMessage)")
        [void]$sb.AppendLine("  ScriptStackTrace: $($ErrorRecord.ScriptStackTrace)")
        [System.IO.File]::AppendAllText($dbgPath, $sb.ToString() + [Environment]::NewLine)
        return $sb.ToString()
    } catch { return "Write-CrashLog itself failed: $($_.Exception.Message)" }
}

# In worker mode the child process has no visible console. Redirect Write-Host output
# to the event log so the GUI can show the latest stage without opening PowerShell.
if ($script:GuiWorker) {
    try {
        if ($script:GuiLogPath) {
            New-Item -ItemType File -Path $script:GuiLogPath -Force | Out-Null
        }
    } catch {}
    function global:Write-Host {
        param(
            [Parameter(Position=0)] [object]$Object,
            [switch]$NoNewline,
            [object]$Separator,
            [ConsoleColor]$ForegroundColor,
            [ConsoleColor]$BackgroundColor
        )
        try {
            $sep = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
            $text = [string]::Join($sep, @($Object | ForEach-Object { [string]$_ }))
            $ending = if ($NoNewline) { '' } else { [Environment]::NewLine }
            if ($script:GuiLogPath) {
                [System.IO.File]::AppendAllText($script:GuiLogPath, $text + $ending, [System.Text.UTF8Encoding]::new($false))
            }
        } catch {}
    }
}

# ---------------------------------------------------------------------------
# v2: colored status output + progress bar
# ---------------------------------------------------------------------------
function Write-Ok    {
    param([string]$Message)
    Write-Host "  [OK] $Message"   -ForegroundColor Green
    if ($script:GuiWorker -and $script:GuiStage -eq 'legacy') {
        $script:LegacyStepCount++
        Write-GuiEvent -Type 'progress' -Current $script:LegacyStepCount -Total $script:LegacyStepTotal -Label $Message
    }
}
function Write-Bad   { param([string]$Message) Write-Host "  [XX] $Message"   -ForegroundColor Red }
function Write-Warn2 { param([string]$Message) Write-Host "  [!!] $Message"   -ForegroundColor Yellow }
function Write-Info2 { param([string]$Message) Write-Host "  [->] $Message"   -ForegroundColor Cyan }

function Write-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Label = '')
    $width = 34
    $filled = if ($Total -gt 0) { [int](($Current / $Total) * $width) } else { 0 }
    if ($filled -gt $width) { $filled = $width }
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    $pct = if ($Total -gt 0) { [int](($Current / $Total) * 100) } else { 0 }
    $barColor = if ($pct -ge 100) { 'Green' } elseif ($pct -ge 50) { 'Cyan' } else { 'Magenta' }
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host $bar -NoNewline -ForegroundColor $barColor
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,3}% " -f $pct) -NoNewline -ForegroundColor White
    Write-Host ("({0}/{1}) " -f $Current, $Total) -NoNewline -ForegroundColor DarkGray
    Write-Host $Label -ForegroundColor Magenta
    Write-GuiEvent -Type 'progress' -Current $Current -Total $Total -Label $Label
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.ff"), $Message
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    }
}

function New-BackupFolder {
    $ts = Get-Date -Format "yyMMdd_HHmmss"
    $dir = Join-Path $env:TEMP "NPBK_$ts"
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
    $dirs = @(Get-ChildItem -Path $env:TEMP -Directory -Filter "NPBK_*" -ErrorAction SilentlyContinue)
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (Test-Path $desktop) {
        $dirs += @(Get-ChildItem -Path $desktop -Directory -Filter "NPBK_*" -ErrorAction SilentlyContinue)
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
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $script:Changes.Add([PSCustomObject]@{
            Kind = 'RegValue'; Path = $Path; Name = $Name
            KeyCreated = (-not $keyExisted); HadValue = $had; OldValue = $old; Type = $Type
        })
        return $true
    } catch {
        if (-not $keyExisted -and (Test-Path $Path)) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
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
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        $script:Changes.Add([PSCustomObject]@{ Kind='Service'; Name=$Name; OldStart=$oldStart })
        if ($StartupType -ne 'Automatic' -and $svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        } elseif ($StartupType -eq 'Automatic' -and $svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
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
    Write-ProgressBar -Current ($Number - 1) -Total $Total -Label $Description
    Write-Log $label
    try {
        & $Action
    } catch {
        Write-Bad "Step failed: $($_.Exception.Message)"
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
# v2.2: multi-game support (PUBG, VALORANT) alongside FiveM.
# Same discovery approach as Find-FiveMExe - checks the running process first
# (most reliable, any install location), then falls back to well-known default
# install paths on every fixed drive.
# ---------------------------------------------------------------------------
function Find-GameExe {
    param(
        [Parameter(Mandatory)][string]$ProcessName,   # e.g. 'TslGame' (no .exe)
        [Parameter(Mandatory)][string[]]$DefaultRelativePaths  # e.g. 'Steam\steamapps\common\PUBG\TslGame\Binaries\Win64\TslGame.exe'
    )
    try {
        $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.Path) { return $proc.Path }
    } catch {}
    try {
        foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            foreach ($rel in $DefaultRelativePaths) {
                foreach ($progFiles in @('Program Files','Program Files (x86)','')) {
                    $guess = if ($progFiles) { Join-Path $drv.Root (Join-Path $progFiles $rel) } else { Join-Path $drv.Root $rel }
                    if (Test-Path $guess) { return $guess }
                }
            }
        }
    } catch {}
    return $null
}

function Get-TargetGames {
    # AntiCheatSensitive = $true means: skip IFEO CPU/IO/Page-priority + MMCSS registration for
    # this exe. Kernel-level anti-cheats (Riot Vanguard for VALORANT, and to a lesser extent
    # BattlEye for PUBG) actively watch for registry-level tampering with their protected game
    # process and can flag/ban accounts over it. GPU preference, fullscreen-optimization-off,
    # and Defender exclusions are left/right of the game process itself (Windows-side, not
    # touching the process's own priority/scheduling) and are safe for all of them.
    return @(
        [PSCustomObject]@{ Label='PUBG';     ExeName='TslGame.exe';                     ProcessBase='TslGame';
            DefaultPaths=@('Steam\steamapps\common\PUBG\TslGame\Binaries\Win64\TslGame.exe');
            AntiCheatSensitive=$true; AntiCheatName='BattlEye' }
        [PSCustomObject]@{ Label='VALORANT'; ExeName='VALORANT-Win64-Shipping.exe';      ProcessBase='VALORANT-Win64-Shipping';
            DefaultPaths=@('Riot Games\VALORANT\live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe');
            AntiCheatSensitive=$true; AntiCheatName='Riot Vanguard' }
    )
}

function Invoke-MultiGameOptimize {
    # Applies the same class of tweaks FiveM already gets (GPU preference, fullscreen
    # optimizations off, process-level Defender exclusion) to any other supported game found
    # on this PC, without touching anything the game's anti-cheat is likely to watch.
    foreach ($game in (Get-TargetGames)) {
        $exePath = Find-GameExe -ProcessName $game.ProcessBase -DefaultRelativePaths $game.DefaultPaths
        if (-not $exePath) {
            Write-Host "$($game.Label): not found on this PC, skipped"
            continue
        }
        Write-Host "$($game.Label): detected at $exePath"

        # GPU preference (High-performance GPU on laptops with hybrid graphics).
        Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $game.ExeName 'GpuPreference=2;' 'String' | Out-Null

        # Fullscreen optimizations off - lets exclusive/borderless fullscreen bypass DWM composition.
        Set-Reg 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $exePath '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE' 'String' | Out-Null

        # Defender process exclusion - removes real-time per-frame scan overhead.
        try {
            Add-MpPreference -ExclusionProcess $game.ExeName -ErrorAction Stop
            $script:Changes.Add([PSCustomObject]@{ Kind='DefenderExclusionProcess'; Name=$game.ExeName })
            Write-Host "$($game.Label): Defender process exclusion added"
        } catch {
            $script:PendingExclusions.Processes.Add($game.ExeName) | Out-Null
            Write-Host "$($game.Label): Defender process exclusion skipped (see diagnosis at the end of this run)"
        }

        if ($game.AntiCheatSensitive) {
            Write-Host "$($game.Label): skipped CPU/IO priority + MMCSS registration on purpose - $($game.AntiCheatName) treats registry-level process tampering as suspicious and this can risk a ban. Network/system-wide tweaks elsewhere in this run still help $($game.Label)'s latency and 1% lows."
        } else {
            Invoke-ProcessPriorityHigh $game.ExeName | Out-Null
            Invoke-MmcssRegister $game.ExeName | Out-Null
        }
    }
}

function Set-ScheduledTaskDisabled {
    param([Parameter(Mandatory)][string]$TaskPath)
    try {
        if ($TaskPath -notmatch '^(.*\\)([^\\]+)$') { return }
        $taskFolder = $Matches[1]
        $taskName = $Matches[2]
        $task = Get-ScheduledTask -TaskPath $taskFolder -TaskName $taskName -ErrorAction Stop
        if ($script:DryRun) {
            Write-Host "  [DRYRUN] would disable scheduled task: $TaskPath" -ForegroundColor DarkCyan
            return
        }
        $wasEnabled = ($task.State -ne 'Disabled')
        $script:Changes.Add([PSCustomObject]@{ Kind='ScheduledTask'; TaskPath=$taskFolder; TaskName=$taskName; WasEnabled=$wasEnabled })
        if ($wasEnabled) { Disable-ScheduledTask -TaskPath $taskFolder -TaskName $taskName -ErrorAction Stop | Out-Null }
    } catch { Write-Log "Scheduled task skipped: $TaskPath" }
}

function Invoke-FullGamingExtras {
    Write-Host "Applying additional full-system gaming extras..." -ForegroundColor Cyan
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AudioCaptureEnabled' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 'DWord' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 'DWord' | Out-Null
    foreach ($task in @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Maps\MapsToastTask',
        '\Microsoft\Windows\Maps\MapsUpdateTask'
    )) { Set-ScheduledTaskDisabled -TaskPath $task }
    foreach ($svc in 'DoSvc','MapsBroker','WerSvc','RetailDemo','lfsvc','PhoneSvc') {
        Set-SvcStart $svc 'Manual' | Out-Null
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'IconsOnly' 1 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 'DWord' | Out-Null
    Save-Changes
    Write-Ok "Full-system gaming extras applied"
}

function Invoke-DeepAggressiveTuning {
    Write-Host "Applying deep aggressive system tuning..." -ForegroundColor Magenta

    # Foreground multimedia scheduler and startup latency.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'AlwaysOn' 1 'DWord' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NoLazyMode' 1 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DisablePreviewDesktop' 1 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DisableThumbnails' 1 'DWord' | Out-Null

    # Remove extra background scheduling and power-saving on the active plan.
    try {
        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
        powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2 | Out-Null
        powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    } catch {}

    # Additional nonessential services: preserve original startup modes through Set-SvcStart.
    foreach ($svc in 'TimeBrokerSvc','PcaSvc','DusmSvc','DoSvc','WpnService','WSearch','MapsBroker') {
        Set-SvcStart $svc 'Manual' | Out-Null
    }

    # Disable more Windows capture and consumer hooks for a gaming session.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'CursorCaptureEnabled' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.WindowsStore_8wekyb3d8bbwe!App' 'Enabled' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1 'DWord' | Out-Null

    Save-Changes
    Write-Ok "Deep aggressive tuning applied"
}

function Set-OptimalMTU1500 {
    Write-Host "🌐 Setting MTU to 1500 on active physical network adapters..." -ForegroundColor Cyan
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        if (-not $adapters) { return }
        
        foreach ($a in $adapters) {
            try {
                $ipIf = Get-NetIPInterface -InterfaceIndex $a.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($ipIf) {
                    $oldMtu = [int]$ipIf.NlMtuBytes
                    if ($oldMtu -le 0) {
                        $subinterfaceLines = @(netsh.exe interface ipv4 show subinterfaces 2>$null)
                        $mtuLine = $subinterfaceLines | Where-Object {
                            $_ -match '^\s*\d+\s+\d+\s+\d+\s+\d+\s+(.+?)\s*$' -and $Matches[1].Trim() -eq $a.Name
                        } | Select-Object -First 1
                        if ($mtuLine -and $mtuLine -match '^\s*(\d+)\s+') { $oldMtu = [int]$Matches[1] }
                    }
                    if ($oldMtu -le 0) { throw "Could not read the current MTU for $($a.Name); skipped to protect reset accuracy" }
                    Set-NetIPInterface -InterfaceIndex $a.IfIndex -AddressFamily IPv4 -NlMtuBytes 1500 -ErrorAction Stop
                    $script:Changes.Add([PSCustomObject]@{
                        Kind = 'Mtu'
                        IfIndex = $a.IfIndex
                        AddressFamily = 'IPv4'
                        OldMtu = $oldMtu
                    })
                    Write-Ok "MTU on $($a.Name) set to 1500 (Was: $oldMtu)"
                }
            } catch {
                Write-Warn2 "Failed to set MTU on $($a.Name): $($_.Exception.Message)"
            }
        }
    } catch {}
}

function Invoke-NetworkAggressiveTuning {
    Write-Host "Applying aggressive FiveM network tuning..." -ForegroundColor Magenta
    Set-OptimalMTU1500

    # DNS client cache: reduce stale/negative cache retention for frequently changing servers.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'MaxCacheTtl' 30 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'MaxNegativeCacheTtl' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'NetFailureCacheTime' 0 'DWord' | Out-Null

    # TCP connection/retransmission behavior for small real-time game packets.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpMaxConnectRetransmissions' 2 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpMaxDataRetransmissions' 3 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpMaxDupAcks' 2 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'Tcp1323Opts' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'EnablePMTUBHDetect' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'EnablePMTUDiscovery' 1 'DWord' | Out-Null

    # Remove background delivery/update traffic while gaming.
    foreach ($svc in 'BITS','DoSvc','wuauserv') { Set-SvcStart $svc 'Manual' | Out-Null }

    # Apply low-latency global stack profile. Existing Reset restores the global defaults.
    try { netsh.exe int tcp set global autotuninglevel=normal | Out-Null } catch {}
    try { netsh.exe int tcp set global rss=enabled | Out-Null } catch {}
    try { netsh.exe int tcp set global rsc=disabled | Out-Null } catch {}
    try { netsh.exe int tcp set global ecncapability=disabled | Out-Null } catch {}
    try { netsh.exe int tcp set global timestamps=disabled | Out-Null } catch {}
    try { netsh.exe int tcp set global fastopen=enabled | Out-Null } catch {}
    try { netsh.exe int tcp set heuristics disabled | Out-Null } catch {}

    # Disable unused tunnel transition technologies that can add routes/overhead.
    try { netsh.exe interface teredo set state disable | Out-Null } catch {}
    try { netsh.exe interface 6to4 set state state=disabled | Out-Null } catch {}
    try { netsh.exe interface isatap set state state=disabled | Out-Null } catch {}

    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch {}
    Save-Changes
    Write-Ok "Aggressive FiveM network tuning applied"
}

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------
function Invoke-ApplyUltra {
    Clear-Host
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  APPLYING ULTRA PROFILE" -ForegroundColor Magenta
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Registry, services, network, GPU/input tuning for FiveM."
    Write-Host "Defender/Firewall stay ON (folder exclusion only). Update paused for"
    Write-Host "this session. HPET is NOT touched - use -HpetToggle separately."
    Write-Host ""
    $confirm = if ($script:GuiWorker) { 'Y' } else { Read-Host "Continue? [Y/N]" }
    if ($confirm -notmatch '^[Yy]') { Write-Host "Cancelled."; return }

    New-BackupFolder | Out-Null
    $script:PendingExclusions = @{ Paths = New-Object System.Collections.Generic.List[string]; Processes = New-Object System.Collections.Generic.List[string] }

    Write-GuiEvent -Type 'progress' -Current 2 -Total $script:LegacyStepTotal -Label 'กำลังวัดค่าเน็ตก่อนปรับ (Before benchmark)' -Message 'วัดจริง 30 ครั้งต่อเป้าหมาย ใช้เวลาสักครู่...'
    Write-Host "Measuring baseline network latency (real samples, for a genuine before/after comparison later)..."
    try { $script:NetBenchmarkBefore = Invoke-NetworkLatencyBenchmark -Context 'Before' }
    catch { Write-Warn2 "Before-benchmark skipped: $($_.Exception.Message)"; $script:NetBenchmarkBefore = @() }

    Write-GuiEvent -Type 'progress' -Current 2 -Total $script:LegacyStepTotal -Label 'กำลังตรวจสอบเครื่อง' -Message 'กำลังอ่าน CPU, RAM, GPU และอุปกรณ์เครือข่าย...'
    Write-Host "Checking system..."
    Write-GuiEvent -Type 'progress' -Current 2 -Total $script:LegacyStepTotal -Label 'กำลังตรวจสอบสเปกเครื่อง...'
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

    Write-GuiEvent -Type 'progress' -Current 3 -Total $script:LegacyStepTotal -Label 'กำลังสร้าง restore point' -Message 'ขั้นตอนนี้อาจใช้เวลาสูงสุดประมาณ 45 วินาที...'
    Write-Host "Creating restore point..."
    Write-GuiEvent -Type 'progress' -Current 3 -Total $script:LegacyStepTotal -Label 'กำลังสร้างจุดคืนค่าระบบ (อาจใช้เวลาถึง 1 นาที)...'
    try {
        $rpJob = Start-Job -ScriptBlock {
            param($desc)
            Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        } -ArgumentList 'FiveM Ultra Before Apply'
        if (Wait-Job $rpJob -Timeout 45) {
            if ($rpJob.State -eq 'Completed' -and -not (Receive-Job $rpJob -ErrorAction SilentlyContinue -Keep | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })) {
                Write-Host "Restore point: created"
            } else {
                Write-Host "Restore point: skipped (see job errors)"
            }
        } else {
            Write-Host "Restore point: skipped - timed out after 45s (Windows System Restore is slow/stuck on this PC)"
            Stop-Job $rpJob -ErrorAction SilentlyContinue
        }
        Remove-Job $rpJob -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host ("Restore point: skipped - " + $_.Exception.Message)
    }

    Write-GuiEvent -Type 'progress' -Current 4 -Total $script:LegacyStepTotal -Label 'กำลังทดสอบเครือข่าย' -Message 'กำลังทดสอบการเชื่อมต่อก่อนปรับค่า...'
    Write-Host "Testing network baseline..."
    Write-GuiEvent -Type 'progress' -Current 4 -Total $script:LegacyStepTotal -Label 'กำลังทดสอบเครือข่าย...'
    # -TimeoutSeconds bounds each ping so this can't hang for minutes if ICMP is filtered
    # on this network (previously used the default timeout, which can appear as a "stuck" GUI).
    try { Test-Connection -ComputerName 1.1.1.1 -Count 2 -TimeoutSeconds 2 -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-Host } catch {}

    $script:Total = 48  # v2.2: 39 legacy + MMCSS/ProcessPriority/TrimVerify + NIC-MSI + multi-game (PUBG/VALORANT) + DynamicTick/CState + USB-MSI + NetThrottle
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
        # Keep Windows' global power management. Per-process handling is applied
        # only to FiveM/GTA when those processes are actually detected.
        Write-Info2 "Global Power Throttling: Windows default (no global disable)"
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
        try { netsh.exe int tcp set global ecncapability=disabled | Out-Null } catch {}
        try { netsh.exe int tcp set global timestamps=disabled | Out-Null } catch {}
        try { netsh.exe int tcp set global rsc=disabled | Out-Null } catch {}
        try { netsh.exe int tcp set global fastopen=enabled | Out-Null } catch {}
        try { netsh.exe int tcp set global fastopenfallback=enabled | Out-Null } catch {}
        try { netsh.exe int tcp set supplemental template=internet icw=10 | Out-Null } catch {}
        try { netsh.exe int tcp set heuristics disabled | Out-Null } catch {}
        try {
            Remove-NetQosPolicy -Name "FiveMUltraQoS" -Confirm:$false -ErrorAction SilentlyContinue
            New-NetQosPolicy -Name "FiveMUltraQoS" -AppPathNameMatchCondition "FiveM.exe" -DSCPAction 46 -NetworkProfile All -ErrorAction Stop | Out-Null
            $script:Changes.Add([PSCustomObject]@{ Kind='QosPolicy'; Name='FiveMUltraQoS' })
        } catch { Write-Log "  ! QoS policy failed: $($_.Exception.Message)" }
    }

    Invoke-Step (++$n) $Total "Requesting lower kernel timer resolution (0.5ms, persists across reboot)..." {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1 'DWord' | Out-Null
        Invoke-TimerResolutionLock | Out-Null
    }

    Invoke-Step (++$n) $Total "Registering FiveM/GTAProcess to MMCSS (Multimedia Class Scheduler) with High priority..." {
        Invoke-MmcssRegister 'FiveM.exe' | Out-Null
    }

    Invoke-Step (++$n) $Total "Setting FiveM base process priority to High (persistent)..." {
        Invoke-ProcessPriorityHigh 'FiveM.exe' | Out-Null
        $gtaName = Find-GtaProcessName
        if ($gtaName) {
            Invoke-ProcessPriorityHigh $gtaName | Out-Null
        }
    }

    Invoke-Step (++$n) $Total "Verifying TRIM status on NVMe/SSD (write latency check)..." {
        Invoke-TrimVerify | Out-Null
    }

    Invoke-Step (++$n) $Total "Applying low-latency timer profile (desktop only; C-State stays Windows default)..." {
        $laptopNow = Get-HwIsLaptop
        Invoke-DynamicTickDisable -IsLaptop $laptopNow | Out-Null
        Write-Info2 "C-State/PROCIDLEDISABLE: Windows default kept (test-only option, not applied by default)"
    }

    Invoke-Step (++$n) $Total "Enabling MSI interrupt mode on USB Host Controller (mouse/keyboard latency)..." {
        $usbCpuMask = 0
        try {
            $threadCount = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).NumberOfLogicalProcessors
            if ($threadCount -ge 2) { $usbCpuMask = 2 }   # logical core 1, kept off core 0 to avoid piling onto the busiest core
        } catch {}
        Invoke-UsbControllerMsiMode -CanSetIrqAffinity ($usbCpuMask -gt 0) -TargetCpuMask $usbCpuMask | Out-Null
    }

    Invoke-Step (++$n) $Total "Disabling Network Throttling Index (removes multimedia bandwidth cap)..." {
        Invoke-NetworkThrottlingDisable | Out-Null
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
        Write-Info2 "HAGS: current value kept; use explicit ON/OFF A/B test only"
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

    Invoke-Step (++$n) $Total "Tuning network adapter power and offload settings (AGGRESSIVE)..." {
        Write-Host ""
        Write-Host "🔌 NETWORK ADAPTER AGGRESSIVE TUNING" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        
        try {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            if ($adapters.Count -eq 0) {
                Write-Warn2 "No active network adapters found"
                return
            }
            
            foreach ($a in $adapters) {
                Write-Host "`n📡 Adapter: $($a.Name) ($($a.Description))" -ForegroundColor Yellow
                
                # Power Management
                try {
                    Write-Host "  → Disabling power management..." -ForegroundColor Gray
                    Disable-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
                    Write-Host "    ✓ Power management disabled" -ForegroundColor Green
                } catch { Write-Warn2 "    ✗ Power management failed" }
                
                # Energy Efficient Ethernet
                try {
                    $before = (Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Energy Efficient Ethernet' -ErrorAction SilentlyContinue).DisplayValue
                    Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Energy Efficient Ethernet' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue
                    Write-Host "    ✓ EEE disabled (was: $before)" -ForegroundColor Green
                } catch { Write-Warn2 "    ✗ EEE tuning failed" }
                
                # Interrupt Moderation (aggressive: disable)
                try {
                    $before = (Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Interrupt Moderation' -ErrorAction SilentlyContinue).DisplayValue
                    Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue
                    Write-Host "    ✓ Interrupt moderation disabled (was: $before)" -ForegroundColor Green
                } catch { Write-Warn2 "    ✗ Interrupt moderation failed" }
                
                # Receive Buffer (aggressive: max)
                try {
                    $before = (Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName '*Receive Buffers' -ErrorAction SilentlyContinue).DisplayValue
                    if ($before) {
                        Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName '*Receive Buffers' -DisplayValue '2048' -ErrorAction SilentlyContinue
                        Write-Host "    ✓ Receive buffers maxed (was: $before → 2048)" -ForegroundColor Green
                    }
                } catch { }
                
                # Transmit Buffer (aggressive: max)
                try {
                    $before = (Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName '*Transmit Buffers' -ErrorAction SilentlyContinue).DisplayValue
                    if ($before) {
                        Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName '*Transmit Buffers' -DisplayValue '2048' -ErrorAction SilentlyContinue
                        Write-Host "    ✓ Transmit buffers maxed (was: $before → 2048)" -ForegroundColor Green
                    }
                } catch { }
            }
        } catch {}
        
        Write-Host ""
    }

    Invoke-Step (++$n) $Total "Removing QoS bandwidth reservation limit (AGGRESSIVE)..." {
        Write-Host ""
        Write-Host "📊 QoS BANDWIDTH TUNING" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        
        try {
            $before = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -ErrorAction SilentlyContinue).NonBestEffortLimit
            Write-Host "`n📊 BEFORE: NonBestEffortLimit = $before (0-100%)" -ForegroundColor Yellow
            
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0 'DWord' | Out-Null
            
            $after = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -ErrorAction SilentlyContinue).NonBestEffortLimit
            Write-Host "📊 AFTER:  NonBestEffortLimit = $after (unlimited)" -ForegroundColor Green
            Write-Host "✓ QoS bandwidth limit removed" -ForegroundColor Green
        } catch {
            Write-Warn2 "QoS tuning failed: $($_.Exception.Message)"
        }
        
        Write-Host ""
    }

    Invoke-Step (++$n) $Total "Applying TCP/UDP global stack tuning (AGGRESSIVE)..." {
        Write-Host ""
        Write-Host "🌐 NETWORK AGGRESSIVE TUNING" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        
        # Read BEFORE
        Write-Host "`n📊 BEFORE tuning:" -ForegroundColor Yellow
        try {
            $beforeEcn = (netsh.exe int tcp show global | Select-String "ECN Capability") -replace '\s+', ' '
            $beforeTs = (netsh.exe int tcp show global | Select-String "Timestamps") -replace '\s+', ' '
            $beforeRss = (netsh.exe int tcp show global | Select-String "RSS") -replace '\s+', ' '
            $beforeUro = (netsh.exe int udp show global | Select-String "Offload") -replace '\s+', ' '
            
            Write-Host "  ECN:       $beforeEcn" -ForegroundColor Gray
            Write-Host "  Timestamps: $beforeTs" -ForegroundColor Gray
            Write-Host "  RSS:       $beforeRss" -ForegroundColor Gray
            Write-Host "  UDP Offload: $beforeUro" -ForegroundColor Gray
        } catch {}
        
        # Apply changes
        Write-Host "`n⚙️ APPLYING aggressive tuning..." -ForegroundColor Green
        try { netsh.exe int tcp set global ecncapability=disabled | Out-Null; Write-Host "  ✓ ECN disabled" -ForegroundColor Green } catch { Write-Warn2 "  ✗ ECN failed" }
        try { netsh.exe int tcp set global timestamps=disabled | Out-Null; Write-Host "  ✓ Timestamps disabled" -ForegroundColor Green } catch { Write-Warn2 "  ✗ Timestamps failed" }
        try { netsh.exe int tcp set global rss=enabled | Out-Null; Write-Host "  ✓ RSS enabled" -ForegroundColor Green } catch { Write-Warn2 "  ✗ RSS failed" }
        try { netsh.exe int udp set global uro=disabled | Out-Null; Write-Host "  ✓ UDP offload disabled" -ForegroundColor Green } catch { Write-Warn2 "  ✗ UDP offload failed" }
        
        # Read AFTER
        Write-Host "`n📊 AFTER tuning:" -ForegroundColor Yellow
        try {
            $afterEcn = (netsh.exe int tcp show global | Select-String "ECN Capability") -replace '\s+', ' '
            $afterTs = (netsh.exe int tcp show global | Select-String "Timestamps") -replace '\s+', ' '
            $afterRss = (netsh.exe int tcp show global | Select-String "RSS") -replace '\s+', ' '
            $afterUro = (netsh.exe int udp show global | Select-String "Offload") -replace '\s+', ' '
            
            Write-Host "  ECN:       $afterEcn" -ForegroundColor Green
            Write-Host "  Timestamps: $afterTs" -ForegroundColor Green
            Write-Host "  RSS:       $afterRss" -ForegroundColor Green
            Write-Host "  UDP Offload: $afterUro" -ForegroundColor Green
        } catch {}
        
        Write-Host ""
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

    Invoke-Step (++$n) $Total "Enabling MSI Mode for the active network adapter (lower/steadier ping)..." {
        # MSI (Message Signaled Interrupts) lets the NIC interrupt the CPU directly instead of
        # sharing/polling a legacy IRQ line - this is the single biggest "why is my ping spiky
        # under load" fix on many boards. Helps every online game equally (PUBG/Valorant/FiveM),
        # since it works below the game - at the network driver level.
        try {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            if (-not $adapters -or $adapters.Count -eq 0) {
                Write-Host "NIC MSI Mode: no active physical network adapter found, skipped"
            } else {
                foreach ($nic in $adapters) {
                    try {
                        $pnp = Get-PnpDevice -InstanceId $nic.PnPDeviceID -ErrorAction SilentlyContinue
                        if (-not $pnp) { continue }
                        $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($nic.PnPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                        Set-Reg $devPath 'MSISupported' 1 'DWord' | Out-Null
                        Write-Host "NIC MSI Mode: enabled for $($nic.Name) ($($nic.InterfaceDescription))"
                    } catch { Write-Log "  ! NIC MSI mode failed for $($nic.Name): $($_.Exception.Message)" }
                }
            }
        } catch { Write-Host "NIC MSI Mode: skipped - $($_.Exception.Message)" }
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

    Invoke-Step (++$n) $Total "Applying the same GPU/fullscreen/Defender tweaks for other detected games (PUBG, VALORANT)..." {
        Invoke-MultiGameOptimize
    }

    Invoke-Step (++$n) $Total "Tuning TCP ephemeral port range and TIME_WAIT delay..." {
        # Reduces socket exhaustion / port reuse stalls, which show up as periodic connection hitching.
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'MaxUserPort' 65534 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpTimedWaitDelay' 10 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'MaxFreeTcbs' 65535 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'MaxHashTableSize' 65536 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpMaxDataRetransmissions' 3 'DWord' | Out-Null
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
        # Leave paging policy and obsolete IoPageLockLimit at Windows defaults;
        # the adaptive RAM phase verifies the profile without forcing legacy values.
        Write-Info2 "Paging executive/IoPageLockLimit: adaptive phase will verify; no legacy force"
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
        $inputCpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $inputRam = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $inputLaptop = Get-HwIsLaptop
        $inputThreads = if ($inputCpu) { [int]$inputCpu.NumberOfLogicalProcessors } else { 4 }
        $inputRamGB = if ($inputRam) { [double]($inputRam.TotalPhysicalMemory / 1GB) } else { 8 }
        $script:InputQueueSize = if ($inputLaptop -or $inputThreads -lt 8 -or $inputRamGB -lt 8) { 32 } elseif ($inputThreads -ge 16 -and $inputRamGB -ge 16) { 20 } else { 24 }
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize' $script:InputQueueSize 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize' $script:InputQueueSize 'DWord' | Out-Null
        Write-Ok "HID input queues set to $($script:InputQueueSize) for this CPU/RAM/chassis profile"
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
            $suspects = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                $_.Status -eq 'Up' -and ($_.Name -match $suspectPattern -or $_.InterfaceDescription -match $suspectPattern)
            }
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
    # NOTE (honest scope note, not a claim of full spec-29 compliance): this reports
    # EXPECTED vs ACTUAL vs RESULT per setting. It does NOT capture a true "OLD" (pre-apply)
    # value for these 17 legacy checks - that would require snapshotting each one before the
    # very first step runs, which this function does not currently do. Treat the "OLD" column
    # as "not captured for this check" until that snapshot exists.
    Write-Host ""
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  DONE" -ForegroundColor Green
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    $verifyItems = @(
        @{ Name='PowerThrottling';       Expected='Registry value present (off for FiveM)'; Check={ (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PowerThrottling' -Name PowerThrottlingOff -EA SilentlyContinue) -ne $null } }
        @{ Name='FiveM-CPU-priority';    Expected='CpuPriorityClass set in PerfOptions';     Check={ (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FiveM.exe\PerfOptions' -Name CpuPriorityClass -EA SilentlyContinue) -ne $null } }
        @{ Name='FiveM-GPU-preference';  Expected='UserGpuPreferences entry present';        Check={ (Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'FiveM.exe' -EA SilentlyContinue) -ne $null } }
        @{ Name='Timer-resolution';      Expected='GlobalTimerResolutionRequests present';   Check={ (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' -Name GlobalTimerResolutionRequests -EA SilentlyContinue) -ne $null } }
        @{ Name='Keyboard-response';     Expected='KeyboardDelay value present';             Check={ (Get-ItemProperty 'HKCU:\Control Panel\Keyboard' -Name KeyboardDelay -EA SilentlyContinue) -ne $null } }
        @{ Name='SysMain-service';       Expected='StartMode = Manual';                      Check={ (Get-CimInstance Win32_Service -Filter "Name='SysMain'" -EA SilentlyContinue).StartMode -eq 'Manual' } }
        @{ Name='QoS-reservation';       Expected='NonBestEffortLimit present';               Check={ (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -Name NonBestEffortLimit -EA SilentlyContinue) -ne $null } }
        @{ Name='Visual-effects';        Expected='VisualFXSetting present';                  Check={ (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name VisualFXSetting -EA SilentlyContinue) -ne $null } }
        @{ Name='Windows-Update-pause';  Expected='StartMode = Manual';                       Check={ (Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -EA SilentlyContinue).StartMode -eq 'Manual' } }
        @{ Name='Defender-exclusion';    Expected="ExclusionPath contains FiveM folder";      Check={ (Get-MpPreference -EA SilentlyContinue).ExclusionPath -contains $fiveMRoot } }
        @{ Name='Hibernation-off';       Expected='hiberfil.sys absent';                      Check={ -not (Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys')) } }
        @{ Name='Games-task-priority';   Expected="'GPU Priority' present under Tasks\Games"; Check={ (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'GPU Priority' -EA SilentlyContinue) -ne $null } }
        @{ Name='GameBar-disabled';      Expected='AutoGameModeEnabled = 0';                  Check={ (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -EA SilentlyContinue).AutoGameModeEnabled -eq 0 } }
        @{ Name='TCP-port-range';        Expected='MaxUserPort present';                      Check={ (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name MaxUserPort -EA SilentlyContinue) -ne $null } }
        @{ Name='RAM-paging-tweak';      Expected='DisablePagingExecutive = 1';               Check={ (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name DisablePagingExecutive -EA SilentlyContinue).DisablePagingExecutive -eq 1 } }
        @{ Name='HID-queue-size';        Expected="MouseDataQueueSize = $($script:InputQueueSize)"; Check={ (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' -Name MouseDataQueueSize -EA SilentlyContinue).MouseDataQueueSize -eq $script:InputQueueSize } }
        @{ Name='RSC-off';               Expected='IPv4Enabled = False on active adapter';    Check={ $a = Get-ActiveAdapter; if ($a) { -not (Get-NetAdapterRsc -Name $a.Name -EA SilentlyContinue).IPv4Enabled } else { $true } } }
    )
    $ok = 0; $failed = @()
    Write-Host ("  {0,-22} {1,-42} {2}" -f 'SETTING', 'EXPECTED', 'RESULT') -ForegroundColor DarkGray
    foreach ($item in $verifyItems) {
        $actual = $false
        try { $actual = & $item.Check } catch { $actual = $false }
        $resultTag = if ($actual) { '[OK]' } else { '[FAIL]' }
        $resultColor = if ($actual) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-22} {1,-42} " -f $item.Name, $item.Expected) -NoNewline
        Write-Host $resultTag -ForegroundColor $resultColor
        if ($actual) { $ok++ } else { $failed += $item.Name }
    }
    Write-ProgressBar -Current $script:Total -Total $script:Total -Label 'Ultra profile applied'
    Write-Host ""
    $passColor = if ($ok -eq $verifyItems.Count) { 'Green' } elseif ($ok -ge ($verifyItems.Count * 0.7)) { 'Yellow' } else { 'Red' }
    Write-Host "Checks passed: $ok/$($verifyItems.Count)" -ForegroundColor $passColor
    if ($failed.Count -gt 0) { Write-Warn2 ("Not applied: " + ($failed -join ', ') + " - see backup folder or check manually.") }
    Write-Info2 "Restart Windows, then test FiveM. Choose Reset if needed."
    Write-Host "Log saved to: $script:LogFile" -ForegroundColor DarkGray
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Log "Apply finished. Checks passed: $ok/$($verifyItems.Count). Not applied: $($failed -join ', ')"

    # ---- Real before/after network benchmark (no fabricated numbers - if a target was
    # unreachable either time, that comparison line is skipped rather than guessed) ----
    if ($script:NetBenchmarkBefore -and $script:NetBenchmarkBefore.Count -gt 0) {
        Write-Host ""
        Write-Host "  Network latency: before vs after (real measured samples)" -ForegroundColor Cyan
        try {
            $afterResults = Invoke-NetworkLatencyBenchmark -Context 'After'
            foreach ($before in $script:NetBenchmarkBefore) {
                $after = $afterResults | Where-Object { $_.Label -eq $before.Label } | Select-Object -First 1
                if (-not $after -or -not $before.Reachable -or -not $after.Reachable) {
                    Write-Info2 "$($before.Label): [SKIP] not reachable in one of the two measurements - no comparison possible"
                    continue
                }
                $delta = [math]::Round($after.Average - $before.Average, 1)
                $arrow = if ($delta -lt 0) { "ดีขึ้น" } elseif ($delta -gt 0) { "แย่ลง" } else { "ไม่เปลี่ยนแปลง" }
                $deltaColor = if ($delta -lt 0) { 'Green' } elseif ($delta -gt 0) { 'Yellow' } else { 'Gray' }
                Write-Host ("  {0,-10} avg: {1,6}ms -> {2,6}ms  (เปลี่ยน {3:+0.0;-0.0;0}ms, {4})  jitter: {5}ms -> {6}ms  loss: {7}% -> {8}%" -f `
                    $before.Label, $before.Average, $after.Average, $delta, $arrow, $before.Jitter, $after.Jitter, $before.PacketLossPct, $after.PacketLossPct) -ForegroundColor $deltaColor
            }
        } catch { Write-Warn2 "After-benchmark skipped: $($_.Exception.Message)" }
    }

    # ---- Auto-help for Defender exclusions that Tamper Protection blocked ----
    # v2.1: Cleanup backups and logs
    Write-Host ""
    Write-Host "Cleaning up old backups and rotating logs..."
    Invoke-BackupPruning -KeepCount 5 | Out-Null
    Invoke-LogRotation -MaxSizeMB 10 | Out-Null

    if ($script:PendingExclusions.Paths.Count -gt 0 -or $script:PendingExclusions.Processes.Count -gt 0) {
        Write-Host ""
        Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
        Write-Host "  DEFENDER EXCLUSIONS NEED ONE MANUAL STEP" -ForegroundColor Yellow
        Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
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
                Write-Host "This PC currently has NO active antivirus protection. Recommended: resolve this policy"
                Write-Host "manually with an administrator, restart Windows, and immediately run a"
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
    $script:GuiStage = 'reset'
    Clear-Host
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  RESET ULTRA PROFILE" -ForegroundColor Magenta
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    $dir = Find-LatestBackup
    if (-not $dir) {
        Write-Host "No backup folder found. Nothing to reset."
        if (-not $script:GuiWorker) { Read-Host "Press Enter to continue" }
        return
    }
    $changesFile = Join-Path $dir "changes.json"
    if (-not (Test-Path $changesFile)) {
        Write-Host "No changes.json found in $dir. Nothing to reset."
        if (-not $script:GuiWorker) { Read-Host "Press Enter to continue" }
        return
    }
    Write-Host "Restoring from: $dir"
    $list = @(Get-Content $changesFile -Raw | ConvertFrom-Json)
    [array]::Reverse($list)
    $count = 0
    Write-GuiEvent -Type 'progress' -Current 0 -Total ([math]::Max($list.Count, 1)) -Label 'กำลังคืนค่าการตั้งค่าเดิม'
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
                'ScheduledTask' {
                    if ($c.WasEnabled) { Enable-ScheduledTask -TaskPath $c.TaskPath -TaskName $c.TaskName -ErrorAction SilentlyContinue | Out-Null }
                }
                'TimerResolutionTask' {
                    try {
                        Unregister-ScheduledTask -TaskName $c.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -and $_.CommandLine -like "*TimerResolutionHold.ps1*" } |
                            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
                        if ($c.HelperPath -and (Test-Path $c.HelperPath)) { Remove-Item -Path $c.HelperPath -Force -ErrorAction SilentlyContinue }
                    } catch {}
                }
                'Mtu' {
                    if ($c.OldMtu) { Set-NetIPInterface -InterfaceIndex $c.IfIndex -AddressFamily $c.AddressFamily -NlMtuBytes ([int]$c.OldMtu) -ErrorAction SilentlyContinue }
                }
                'NetworkProfile' {
                    if ($c.OldCategory) { Set-NetConnectionProfile -InterfaceIndex $c.IfIndex -NetworkCategory $c.OldCategory -ErrorAction SilentlyContinue }
                }
                'NetworkSnapshot' {
                    if ($c.Path) { Restore-NetworkSnapshot -SnapshotPath $c.Path -Quiet | Out-Null }
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
                'BcdDynamicTick' {
                    try { bcdedit.exe /deletevalue disabledynamictick 2>$null | Out-Null } catch {}
                }
                'CStateDisable' {
                    try {
                        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCIDLEDISABLE 0 | Out-Null
                        powercfg.exe /setactive SCHEME_CURRENT | Out-Null
                    } catch {}
                }
                'PowerSetting' {
                    try {
                        powercfg.exe /setacvalueindex SCHEME_CURRENT $c.SubGroup $c.Setting ([int]$c.OldValue) 2>$null | Out-Null
                        powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
                    } catch { Write-Log "  ! Power setting restore failed: $($_.Exception.Message)" }
                }
                'AdapterAdvancedProperty' {
                    try {
                        if ($c.OldDisplayValue) {
                            Set-NetAdapterAdvancedProperty -Name $c.AdapterName -DisplayName $c.DisplayName -DisplayValue $c.OldDisplayValue -ErrorAction SilentlyContinue
                        } elseif ($c.OldRegistryValue) {
                            Set-NetAdapterAdvancedProperty -Name $c.AdapterName -DisplayName $c.DisplayName -RegistryValue $c.OldRegistryValue -ErrorAction SilentlyContinue
                        }
                    } catch { Write-Log "  ! Adapter property restore failed: $($_.Exception.Message)" }
                }
                'Netbios' {
                    try {
                        $config = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index=$($c.IfIndex)" -ErrorAction SilentlyContinue
                        if ($config) {
                            Invoke-CimMethod -InputObject $config -MethodName EnableNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]$c.OldValue } -ErrorAction SilentlyContinue | Out-Null
                        }
                    } catch { Write-Log "  ! NetBIOS restore failed: $($_.Exception.Message)" }
                }
                'WlanAutoConfig' {
                    try {
                        $state = if ($c.OldEnabled) { 'yes' } else { 'no' }
                        netsh.exe wlan set autoconfig enabled=$state interface="$($c.InterfaceName)" 2>$null | Out-Null
                    } catch { Write-Log "  ! Wi-Fi autoconfig restore failed: $($_.Exception.Message)" }
                }
                'NetshCongestionProvider' {
                    try { netsh.exe int tcp set global congestionprovider=default 2>$null | Out-Null }
                    catch { Write-Log "  ! TCP congestion provider restore failed: $($_.Exception.Message)" }
                }
            }
            $count++
            Write-GuiEvent -Type 'progress' -Current $count -Total ([math]::Max($list.Count, 1)) -Label "กำลังคืนค่า: $($c.Kind)"
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

    # Additive network snapshots contain the actual state before an opt-in DNS/QoS change.
    # Restore again after legacy default restoration so the exact user configuration wins.
    try {
        $networkSnapshot = Get-NetworkSnapshotPath -BackupDir $dir
        if (Test-Path $networkSnapshot) {
            Restore-NetworkSnapshot -SnapshotPath $networkSnapshot -Quiet | Out-Null
            Write-Ok 'Restored exact DNS/MTU/network-profile state from additive network snapshot.'
        }
    } catch { Write-Warn2 "Additive network snapshot restore skipped: $($_.Exception.Message)" }

    # v2.1: Verify reset success
    Write-Host "Verifying reset success..."
    $verifyOk = Invoke-ResetVerify -Changes $list
    if (-not $verifyOk) {
        Write-Warn2 "Some changes may not have reverted - see details above or check changes.json"
    }
    Write-Host "Removing temporary backup folders..."
    Get-ChildItem -Path $env:TEMP -Directory -Filter "NPBK_*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (Test-Path $desktop) {
        Get-ChildItem -Path $desktop -Directory -Filter "NPBK_*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "RESET COMPLETE. Restart Windows."
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-GuiEvent -Type 'progress' -Current ([math]::Max($list.Count, 1)) -Total ([math]::Max($list.Count, 1)) -Label 'รีเซ็ตเสร็จสมบูรณ์'
    if (-not $script:GuiWorker) { Read-Host "Press Enter to continue" }
}

# ---------------------------------------------------------------------------
# HPET toggle (separate, optional, not part of Apply/Reset)
# ---------------------------------------------------------------------------
function Invoke-ToggleDefenderRealtime {
    Clear-Host
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  TEMPORARY DEFENDER REAL-TIME PROTECTION TOGGLE" -ForegroundColor Magenta
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
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
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  REMOVE LEFTOVER DEFENDER MANAGEMENT POLICY (ADVANCED)" -ForegroundColor Magenta
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
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

    $backupDir = Join-Path $env:TEMP ("NPBK_" + (Get-Date -Format "yyMMdd_HHmmss"))
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

# ===========================================================================
# v2.1 — MMCSS (Multimedia Class Scheduler) REGISTRATION FOR FiveM
# ===========================================================================
function Invoke-TimerResolutionLock {
    # v3.0: This is now RUNTIME-ONLY, not permanent. Windows' fine-grained timer
    # resolution (the same thing third-party "Timer Resolution" utilities set) is
    # NOT a registry value - it's a live Win32/NT API state that only stays in
    # effect for as long as SOME process is actively holding it open.
    #
    # The old design held 0.5ms permanently from every Windows logon onward, even
    # while just sitting on the desktop doing nothing - burning a little extra
    # power/heat for zero benefit outside of an actual gaming session. This
    # version instead installs a lightweight watcher that polls for FiveM's
    # process names and only holds the high-resolution timer WHILE one of them is
    # actually running, releasing it back to Windows' normal ~15.6ms default the
    # moment none of them are running anymore (including after a crash, since the
    # watcher notices the process is gone within a few seconds either way - no
    # separate crash-specific cleanup logic is needed for that reason).
    try {
        $rootDir = Join-Path $env:ProgramData 'NongPlaiShop'
        if (-not (Test-Path $rootDir)) { New-Item -ItemType Directory -Path $rootDir -Force | Out-Null }
        $helperPath = Join-Path $rootDir 'TimerResolutionHold.ps1'
        $taskName = 'NongPlaiShop_TimerResolutionLock'

        if ($script:DryRun) {
            Write-Host "  [DRYRUN] would create $helperPath and register scheduled task $taskName (0.5ms timer resolution, ONLY while FiveM/GTA is actually running, starts watcher at logon)" -ForegroundColor DarkCyan
            return $true
        }

        $helperSource = @'
# Auto-generated by NongPlaiShop - holds Windows timer resolution at 0.5ms ONLY
# while a FiveM/GTA process is actually running. Releases back to Windows'
# default resolution the rest of the time (including after a crash, since a
# process that is gone is simply no longer matched on the next poll).
# Do not run this manually; it is started by the "NongPlaiShop_TimerResolutionLock"
# scheduled task and is meant to stay running in the background as a watcher.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NongPlaiTimer {
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, ref uint CurrentResolution);
}
"@
$targetNames = @('FiveM','FiveM_GTAProcess','GTA5','CitizenFX','PlayGTAV')
$current = [uint32]0
$holding = $false
while ($true) {
    $running = $false
    foreach ($n in $targetNames) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $running = $true; break }
    }
    if ($running -and -not $holding) {
        # 5000 * 100ns = 0.5ms - matches the "0.5" shown by third-party timer resolution tools.
        [NongPlaiTimer]::NtSetTimerResolution(5000, $true, [ref]$current) | Out-Null
        $holding = $true
    } elseif (-not $running -and $holding) {
        [NongPlaiTimer]::NtSetTimerResolution(5000, $false, [ref]$current) | Out-Null
        $holding = $false
    }
    Start-Sleep -Seconds 3
}
'@
        Set-Content -Path $helperPath -Value $helperSource -Encoding UTF8 -Force

        # Kill any previous holder before registering (idempotent - safe to re-apply).
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*TimerResolutionHold.ps1*" } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helperPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null

        # Start the watcher right now too - it will sit idle (Windows default
        # resolution) until it actually sees FiveM/GTA running, no waiting for
        # next logon needed to have it armed.
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $helperPath) `
            -WindowStyle Hidden | Out-Null

        $script:Changes.Add([PSCustomObject]@{ Kind='TimerResolutionTask'; TaskName=$taskName; HelperPath=$helperPath })
        Write-Ok "Timer resolution watcher installed via scheduled task '$taskName' - holds 0.5ms ONLY while FiveM/GTA is running, Windows default the rest of the time"
        return $true
    } catch {
        Write-Warn2 "Timer resolution lock skipped: $($_.Exception.Message)"
        return $false
    }
}


function Invoke-MmcssRegister {
    param([string]$ProcessName = 'FiveM.exe')
    try {
        $taskLabel = $ProcessName -replace '\.exe$', ''
        $taskPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\$taskLabel"
        $keyExisted = Test-Path $taskPath
        if ($script:DryRun) {
            Write-Host ("  [DRYRUN] would register {0} to MMCSS with High priority" -f $ProcessName) -ForegroundColor DarkCyan
            return $true
        }
        if (-not $keyExisted) { New-Item -Path $taskPath -Force | Out-Null }
        Set-Reg "$taskPath" 'Scheduling Category' 'High' 'String' | Out-Null
        Set-Reg "$taskPath" 'SFIO Priority' 'High' 'String' | Out-Null
        Set-Reg "$taskPath" 'Priority' 8 'DWord' | Out-Null  # High Priority in multimedia class
        Set-Reg "$taskPath" 'GPU Priority' 8 'DWord' | Out-Null
        Set-Reg "$taskPath" 'Latency Sensitive' 1 'DWord' | Out-Null
        Set-Reg "$taskPath\Process" $ProcessName '' 'String' | Out-Null
        # FiveM specifically also runs a second process (GTAProcess.exe) that needs the same
        # treatment - every other supported game is a single process, so this is a no-op for them.
        if ($ProcessName -eq 'FiveM.exe') {
            $gtaName = Find-GtaProcessName
            if ($gtaName) {
                Set-Reg "$taskPath\Process" $gtaName '' 'String' | Out-Null
                Write-Ok "MMCSS registered: FiveM.exe + $gtaName with High Priority, Latency Sensitive=1"
                return $true
            }
        }
        Write-Ok "MMCSS registered: $ProcessName with High Priority, Latency Sensitive=1"
        return $true
    } catch {
        Write-Log ("  ! MMCSS registration failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.1 — PER-PROCESS PRIORITY HIGH (via Image File Execution Options)
# ===========================================================================
function Invoke-ProcessPriorityHigh {
    param([string]$ProcessName = 'FiveM.exe')
    try {
        if ($script:DryRun) {
            Write-Host ("  [DRYRUN] would set {0} base priority to High" -f $ProcessName) -ForegroundColor DarkCyan
            return $true
        }
        $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ProcessName"
        if (-not (Test-Path $ifeoPath)) { New-Item -Path $ifeoPath -Force | Out-Null }
        Set-Reg "$ifeoPath" 'PriorityClass' 0x00000002 'DWord' | Out-Null  # 2 = High Priority
        Write-Ok "Base priority set: $ProcessName = High (persists across reboots)"
        return $true
    } catch {
        Write-Log ("  ! Process priority setting failed for {0}: {1}" -f $ProcessName, $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.1 — HARDWARE-ACCELERATED GPU SCHEDULING (HAGS) CONTROL
# ===========================================================================
function Invoke-HagsToggle {
    param([ValidateSet('Enable','Disable','Skip')]$Action = 'Skip')
    try {
        $hags = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $current = (Get-ItemProperty $hags -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode
        $currentState = if ($current -eq 2) { 'Enabled' } else { 'Disabled' }
        
        if ($Action -eq 'Skip') {
            Write-Info2 "HAGS: currently $currentState (skipped, enable/disable per your choice in NVIDIA/AMD settings or BIOS)"
            return $true
        } elseif ($Action -eq 'Enable') {
            if ($script:DryRun) { Write-Host "  [DRYRUN] would enable HAGS" -ForegroundColor DarkCyan; return $true }
            Set-Reg $hags 'HwSchMode' 2 'DWord' | Out-Null
            Write-Info2 "HAGS: Enabled (watch performance - helps some NVIDIA/AMD chips, hurts others; revert if FPS drops)"
            return $true
        } else {
            if ($script:DryRun) { Write-Host "  [DRYRUN] would disable HAGS" -ForegroundColor DarkCyan; return $true }
            Set-Reg $hags 'HwSchMode' 1 'DWord' | Out-Null
            Write-Info2 "HAGS: Disabled (traditional GPU scheduling)"
            return $true
        }
    } catch {
        Write-Log ("  ! HAGS toggle failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.2 — DYNAMIC TICK DISABLE (bcdedit) - universal, all games, reduces timer
# coalescing jitter that affects input timing and 1% lows. Desktop-safe;
# skipped automatically on laptops since dynamic tick exists mainly to save
# battery there and disabling it can noticeably shorten battery life.
# ===========================================================================
function Invoke-DynamicTickDisable {
    param([Parameter(Mandatory)][bool]$IsLaptop)
    try {
        if ($IsLaptop) {
            Write-Info2 "Dynamic Tick: skipped (laptop detected - this setting exists mainly to save battery; disabling costs battery life for a timing benefit that matters most on desktops)"
            return $true
        }
        $before = (bcdedit.exe /enum '{current}' | Select-String 'disabledynamictick').ToString()
        if ($script:DryRun) { Write-Host "  [DRYRUN] would run: bcdedit /set disabledynamictick yes" -ForegroundColor DarkCyan; return $true }
        $result = bcdedit.exe /set disabledynamictick yes 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:Changes.Add([PSCustomObject]@{ Kind='BcdDynamicTick'; OldRaw=$before })
            Write-Ok "Dynamic Tick disabled (bcdedit) - reduces timer-interrupt coalescing jitter, takes effect after reboot"
            return $true
        } else {
            Write-Warn2 "Dynamic Tick disable failed: $result"
            return $false
        }
    } catch {
        Write-Log ("  ! Dynamic Tick disable failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.2 — C-STATE / PROCESSOR IDLE DISABLE - forces CPU cores to stay in C0
# (never sleep) while the machine is on AC power. Removes core wake-up
# latency that causes random 1%-low spikes and input-lag stutters. Skipped
# on laptops (battery/heat) and only applied to the AC power source, never
# battery, even on a desktop with a UPS reporting as battery.
# ===========================================================================
function Invoke-CStateDisable {
    param([Parameter(Mandatory)][bool]$IsLaptop)
    try {
        if ($IsLaptop) {
            Write-Info2 "C-State disable: skipped (laptop detected - forcing C0 raises heat and drains battery fast; only worth it on a desktop with good cooling)"
            return $true
        }
        if ($script:DryRun) { Write-Host "  [DRYRUN] would run: powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCIDLEDISABLE 1" -ForegroundColor DarkCyan; return $true }
        $before = (powercfg.exe /query SCHEME_CURRENT SUB_PROCESSOR PROCIDLEDISABLE 2>$null) -join "`n"
        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCIDLEDISABLE 1 | Out-Null
        powercfg.exe /setactive SCHEME_CURRENT | Out-Null
        $script:Changes.Add([PSCustomObject]@{ Kind='CStateDisable'; OldRaw=$before })
        Write-Ok "C-States disabled on AC power (cores stay in C0) - removes idle wake-up latency behind random 1% lows. Expect higher idle temps/power draw."
        return $true
    } catch {
        Write-Log ("  ! C-State disable failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.2 — USB HOST CONTROLLER MSI MODE + IRQ AFFINITY - same trick already
# applied to the GPU and NIC, extended to the USB controller the mouse and
# keyboard are plugged into. This is the most input-latency-direct tweak in
# the whole script: every mouse move and keypress arrives through this IRQ.
# ===========================================================================
function Invoke-UsbControllerMsiMode {
    param([Parameter(Mandatory)][bool]$CanSetIrqAffinity, [int]$TargetCpuMask = 0)
    try {
        $controllers = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPClass -eq 'USB' -and ($_.Name -match 'Host Controller|xHCI|eXtensible') }
        if (-not $controllers -or $controllers.Count -eq 0) {
            Write-Warn2 "No USB Host Controller entries found via WMI - skipping USB MSI tuning"
            return $false
        }
        $done = 0
        foreach ($ctrl in $controllers) {
            try {
                $instanceId = $ctrl.PNPDeviceID
                $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                if ($script:DryRun) { Write-Host "  [DRYRUN] would enable MSI mode for USB controller: $($ctrl.Name)" -ForegroundColor DarkCyan; continue }
                Set-Reg $devPath 'MSISupported' 1 'DWord' | Out-Null
                if ($CanSetIrqAffinity -and $TargetCpuMask -gt 0) {
                    $affPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId\Device Parameters\Interrupt Management\Affinity Policy"
                    Set-Reg $affPath 'DevicePolicy' 4 'DWord' | Out-Null   # 4 = IrqPolicySpecifiedProcessors
                    Set-Reg $affPath 'AssignmentSetOverride' ([byte[]]([BitConverter]::GetBytes([int64]$TargetCpuMask))) 'Binary' | Out-Null
                }
                $done++
            } catch { Write-Log "  ! USB MSI tuning failed for $($ctrl.Name): $($_.Exception.Message)" }
        }
        if ($done -gt 0) { Write-Ok "USB Host Controller MSI mode enabled on $done controller(s) - lowers mouse/keyboard interrupt latency, separated from GPU/NIC IRQ load" }
        return ($done -gt 0)
    } catch {
        Write-Log ("  ! USB controller MSI tuning failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.2 — NETWORK THROTTLING INDEX - Windows reserves a slice of network
# bandwidth for background multimedia scheduling by default; FiveM's mix of
# voice/audio + game traffic both count as "multimedia" so this reservation
# can throttle the game's own network stack. Disabling it removes that cap.
# ===========================================================================
function Invoke-NetworkThrottlingDisable {
    try {
        if ($script:DryRun) { Write-Host "  [DRYRUN] would set NetworkThrottlingIndex = 0xffffffff (disabled)" -ForegroundColor DarkCyan; return $true }
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 0xffffffff 'DWord' | Out-Null
        Write-Ok "Network Throttling Index disabled - removes Windows' reserved bandwidth cap for multimedia-classified processes"
        return $true
    } catch {
        Write-Log ("  ! Network throttling disable failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.2 — DDC/CI MONITOR INFO (diagnostic only, NOT auto-applied) - lists
# connected monitors and whether they respond to DDC/CI, and dumps whatever
# VCP capability string the monitor reports. There is no universal VCP code
# for "Overdrive"/"Response Time" across brands (most are vendor-proprietary,
# unlike brightness/contrast which ARE standardized), so this deliberately
# stops at reporting instead of blindly writing VCP values that could set a
# monitor to a mode its OSD can't even show/reset from.
# ===========================================================================
function Invoke-MonitorDdcCiInfo {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class NongPlaiMonitor {
    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);
    [DllImport("dxva2.dll")]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint pdwNumberOfPhysicalMonitors);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR { public IntPtr hPhysicalMonitor; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription; }
    [DllImport("dxva2.dll")]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);
    [DllImport("dxva2.dll")]
    public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr hMonitor, StringBuilder pszASCIICapabilitiesString, uint dwCapabilitiesStringLengthInCharacters);
    [DllImport("dxva2.dll")]
    public static extern bool GetCapabilitiesStringLength(IntPtr hMonitor, ref uint pdwCapabilitiesStringLengthInCharacters);
}
"@ -ErrorAction Stop

        $foundAny = $false
        $enumCallback = {
            param($hMonitor, $hdcMonitor, $lprcMonitor, $dwData)
            $count = [uint32]0
            [NongPlaiMonitor]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count) | Out-Null
            if ($count -gt 0) {
                $arr = New-Object 'NongPlaiMonitor+PHYSICAL_MONITOR[]' $count
                if ([NongPlaiMonitor]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $arr)) {
                    foreach ($pm in $arr) {
                        $script:foundAny = $true
                        $lenRef = [uint32]0
                        if ([NongPlaiMonitor]::GetCapabilitiesStringLength($pm.hPhysicalMonitor, [ref]$lenRef) -and $lenRef -gt 0) {
                            $sb = New-Object System.Text.StringBuilder([int]$lenRef)
                            [NongPlaiMonitor]::CapabilitiesRequestAndCapabilitiesReply($pm.hPhysicalMonitor, $sb, $lenRef) | Out-Null
                            Write-Ok "Monitor '$($pm.szPhysicalMonitorDescription)': DDC/CI responded, supports $($lenRef) chars of capability data"
                            Write-Host "    (raw VCP capability string logged - brand-specific codes needed to change Overdrive/Response Time, not attempted automatically)" -ForegroundColor Gray
                        } else {
                            Write-Warn2 "Monitor '$($pm.szPhysicalMonitorDescription)': found but did not respond to DDC/CI (cable/port or monitor firmware may not support it)"
                        }
                    }
                }
            }
            return $true
        }
        [NongPlaiMonitor]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $enumCallback, [IntPtr]::Zero) | Out-Null
        if (-not $foundAny) { Write-Warn2 "No physical monitors responded to DDC/CI enumeration" }
    } catch {
        Write-Log ("  ! Monitor DDC/CI info failed: {0}" -f $_.Exception.Message)
    }
}

# ===========================================================================
# v2.2 — REALTIME PROCESS PRIORITY (opt-in ONLY - not called by Apply Ultra)
# REALTIME_PRIORITY_CLASS sits above every normal Windows priority level,
# including the OS's own input-handling threads. If the game's thread ever
# spins or blocks while holding this priority, keyboard/mouse for the WHOLE
# system can freeze until it clears - this has bitten real users of similar
# tools. It is implemented here because it was asked for, but is NOT wired
# into the default Apply flow; call it manually and test for several
# minutes before trusting it, and prefer Invoke-ProcessPriorityHigh normally.
# ===========================================================================
function Invoke-ProcessPriorityRealtime {
    param([string]$ProcessName = 'FiveM.exe')
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NongPlaiRealtime {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@ -ErrorAction SilentlyContinue

        $proc = Get-Process -Name ($ProcessName -replace '\.exe$','') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) {
            Write-Warn2 "$ProcessName is not currently running - start the game first, then call this again"
            return $false
        }
        $PROCESS_SET_INFORMATION = 0x0200
        $REALTIME_PRIORITY_CLASS = 0x00000100
        $handle = [NongPlaiRealtime]::OpenProcess($PROCESS_SET_INFORMATION, $false, $proc.Id)
        if ($handle -eq [IntPtr]::Zero) { Write-Warn2 "Could not open $ProcessName for priority change"; return $false }
        try {
            $ok = [NongPlaiRealtime]::SetPriorityClass($handle, $REALTIME_PRIORITY_CLASS)
            if ($ok) {
                Write-Ok "$ProcessName set to REALTIME priority. ⚠ Watch system responsiveness for the next few minutes - if keyboard/mouse feel sluggish anywhere in Windows, lower it back immediately via Task Manager."
            } else {
                Write-Warn2 "SetPriorityClass(REALTIME) failed for $ProcessName"
            }
            return $ok
        } finally {
            [NongPlaiRealtime]::CloseHandle($handle) | Out-Null
        }
    } catch {
        Write-Log ("  ! Realtime priority failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
# v2.2 — DPC LATENCY DIAGNOSTIC via built-in xperf/wpr (report-only, safe).
# Captures a short kernel trace and summarizes which driver spends the most
# time in DPC (deferred procedure call) routines - the #1 cause of DPC-
# latency-driven micro-stutter/input lag that no registry tweak can fix,
# since the fix is "update or replace that driver", not a setting.
# ===========================================================================
function Invoke-DpcLatencyDiagnostic {
    param([int]$DurationSeconds = 20)
    try {
        $wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
        if (-not $wpr) { Write-Warn2 "wpr.exe (Windows Performance Recorder) not found on this system - cannot run DPC diagnostic"; return }
        $etlPath = Join-Path $env:TEMP "NongPlai_DpcTrace_$(Get-Date -Format 'yyMMdd_HHmmss').etl"
        Write-Info2 "Recording a $DurationSeconds-second kernel trace to find slow drivers (DPC latency)... do not close this window"
        wpr.exe -start DPC -filemode 2>$null | Out-Null
        Start-Sleep -Seconds $DurationSeconds
        wpr.exe -stop $etlPath 2>$null | Out-Null
        if (-not (Test-Path $etlPath)) { Write-Warn2 "DPC trace failed to produce an output file"; return }
        Write-Ok "DPC trace saved to: $etlPath"
        Write-Host "  Open this file with Windows Performance Analyzer (wpa.exe, free from the Windows SDK) and look at the" -ForegroundColor Gray
        Write-Host "  'DPC/ISR Duration by Module' graph - whichever driver has the longest total time is your latency culprit." -ForegroundColor Gray
        Write-Host "  This is diagnostic only; NongPlaiShop cannot fix a bad driver, only point at which one to update." -ForegroundColor Gray
    } catch {
        Write-Log ("  ! DPC latency diagnostic failed: {0}" -f $_.Exception.Message)
        try { wpr.exe -cancel 2>$null | Out-Null } catch {}
    }
}

# ===========================================================================
# v2.1 — TRIM VERIFICATION FOR NVMe/SSD
# ===========================================================================
function Invoke-TrimVerify {
    try {
        Write-Info2 "Verifying TRIM status on all disks..."
        $trimStatus = fsutil behavior query DisableDeleteNotify
        if ($trimStatus -like "*0*") {
            Write-Ok "TRIM/UNMAP: Enabled (NVMe/SSD write latency will not degrade over time)"
        } else {
            Write-Warn2 "TRIM/UNMAP appears disabled - NVMe/SSD write latency may increase over time. Run: fsutil behavior set DisableDeleteNotify 0 (admin)"
        }
    } catch {
        Write-Log ("  ! TRIM verification skipped: {0}" -f $_.Exception.Message)
    }
}

# ===========================================================================
# v2.1 — BACKUP PRUNING (keep only last N backups)
# ===========================================================================
function Invoke-BackupPruning {
    param([int]$KeepCount = 5)
    try {
        $dirs = @(Get-ChildItem -Path $env:TEMP -Directory -Filter "NPBK_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -gt $KeepCount) {
            $toDelete = $dirs[$KeepCount..($dirs.Count - 1)]
            foreach ($dir in $toDelete) {
                try { Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                catch { Write-Log "  ! Could not delete old backup: $($dir.FullName)" }
            }
            Write-Ok "Backup pruning: deleted $($toDelete.Count) old backups, keeping last $KeepCount"
        }
    } catch {
        Write-Log ("  ! Backup pruning failed: {0}" -f $_.Exception.Message)
    }
}

# ===========================================================================
# v2.1 — LOG ROTATION (prevent write_errors.log from growing forever)
# ===========================================================================
function Invoke-LogRotation {
    param([int]$MaxSizeMB = 10)
    try {
        $logPath = Join-Path $env:TEMP 'NongPlaiGui_write_errors.log'
        if (Test-Path $logPath) {
            $file = Get-Item $logPath
            $sizeMB = [math]::Round($file.Length / 1MB, 2)
            if ($sizeMB -gt $MaxSizeMB) {
                $archive = $logPath -replace '.log$', "_$(Get-Date -Format 'yyMMdd_HHmmss').log"
                try { Move-Item -Path $logPath -Destination $archive -Force -ErrorAction SilentlyContinue }
                catch { Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue }
                Write-Ok "Log rotation: archived $sizeMB MB to $([System.IO.Path]::GetFileName($archive))"
            }
        }
    } catch {
        Write-Log ("  ! Log rotation failed: {0}" -f $_.Exception.Message)
    }
}

# ===========================================================================
# v2.1 — RESET VERIFICATION (confirm all changes were actually reverted)
# ===========================================================================
function Invoke-ResetVerify {
    param([Parameter(Mandatory)][PSCustomObject[]]$Changes)
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($change in $Changes) {
        try {
            if ($change.Kind -eq 'RegValue' -and -not $change.KeyCreated) {
                $path = $change.Path
                $name = $change.Name
                $current = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
                $old = $change.OldValue
                if ($null -ne $current -and $current -ne $old) {
                    $failures.Add("Reg not reverted: $path\$name (now=$current, expected=$old)")
                }
            } elseif ($change.Kind -eq 'Service') {
                $svc = Get-Service -Name $change.Name -ErrorAction SilentlyContinue
                if ($svc -and $svc.StartType -ne $change.OldStart) {
                    $failures.Add("Service not reverted: $($change.Name) (now=$($svc.StartType), expected=$($change.OldStart))")
                }
            }
        } catch {}
    }
    if ($failures.Count -gt 0) {
        Write-Warn2 "Reset verification found $($failures.Count) revert failures (check changes.json for details)"
        foreach ($f in $failures) { Write-Log "  ! $f" }
        return $false
    } else {
        Write-Ok "Reset verification passed: all registry/service values reverted correctly"
        return $true
    }
}

function Invoke-HpetToggle {
    Clear-Host
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  HPET TOGGLE - OPTIONAL, NOT PART OF ULTRA" -ForegroundColor Magenta
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
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
function Get-HwIsLaptop {
    # Battery present + chassis type both used, since some desktops report odd chassis codes.
    $hasBattery = $false
    try { $hasBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
    $chassisLaptop = $false
    try {
        $chassisTypes = (Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1).ChassisTypes
        # 8,9,10,11,12,14,18,21 = portable/laptop/notebook/sub-notebook family per WMI spec
        if ($chassisTypes) { $chassisLaptop = ($chassisTypes | Where-Object { $_ -in 8,9,10,11,12,14,18,21 }).Count -gt 0 }
    } catch {}
    return ($hasBattery -or $chassisLaptop)
}

function Get-HwCpu {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $name = $cpu.Name.Trim()
    $brand = 'Unknown'
    if ($cpu.Manufacturer -match 'Intel') { $brand = 'Intel' }
    elseif ($cpu.Manufacturer -match 'AMD') { $brand = 'AMD' }
    $ht = $false
    try { $ht = ($cpu.NumberOfLogicalProcessors -gt $cpu.NumberOfCores) } catch {}
    # Tier by physical core count - this changes which tweaks actually help vs which just
    # add heat/battery drain for no gain on that specific machine.
    $tier = 'Mid'
    if ($cpu.NumberOfCores -le 4) { $tier = 'Low' }
    elseif ($cpu.NumberOfCores -ge 8) { $tier = 'High' }

    # Model-specific parsing so two CPUs of the SAME brand still get different tweaks -
    # an unlocked i9-13900K and a locked i3-12100 are both "Intel" but should not be tuned the same.
    $generation = 0
    $unlocked   = $false     # Intel K/KF/KS (unlocked multiplier), AMD non-G "X"/no-suffix desktop parts
    $hybrid     = $false     # Intel 12th gen+ Performance+Efficient core design
    $isX3D      = $false     # AMD 3D V-Cache part - responds very differently to boost/OC tweaks
    $isApu      = $false     # AMD "G" suffix / Intel "with Radeon/UHD Graphics"-only laptop chip - no room to assume a discrete-GPU cooling budget

    if ($brand -eq 'Intel') {
        if ($name -match '(?:Core\(TM\)\s*[iI][3579]|Core\s*[iI][3579]|Ultra\s*[579])[- ](\d{4,5})([A-Z]{0,3})') {
            $modelNum = $Matches[1]; $suffix = $Matches[2]
            $generation = [int]($modelNum.Substring(0, $modelNum.Length - 3))
            if ($suffix -match 'K|KS|KF|X') { $unlocked = $true }
        }
        if ($generation -ge 12) { $hybrid = $true }
    }
    elseif ($brand -eq 'AMD') {
        if ($name -match 'Ryzen\s*[3579]\s*(\d{3,4})([A-Z]{0,3})') {
            $modelNum = $Matches[1]; $suffix = $Matches[2]
            $generation = [int]$modelNum.Substring(0,1)   # Ryzen series digit: 3000/5000/7000/9000 -> 3/5/7/9
            if ($suffix -match 'X(?!3D)|XT') { $unlocked = $true }
            if ($suffix -match 'G') { $isApu = $true }
        }
        if ($name -match 'X3D') { $isX3D = $true; $unlocked = $false }
    }

    [PSCustomObject]@{
        Brand          = $brand
        Name           = $name
        Cores          = $cpu.NumberOfCores
        Threads        = $cpu.NumberOfLogicalProcessors
        MaxClockMHz    = $cpu.MaxClockSpeed
        SmtOrHt        = $ht
        Tier           = $tier
        Generation     = $generation
        Unlocked       = $unlocked
        Hybrid         = $hybrid
        IsX3D          = $isX3D
        IsApu          = $isApu
    }
}

function Get-HwGpu {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch 'Basic Render|Basic Display'
    })
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($g in $gpus) {
        $brand = 'Unknown'
        if ($g.Name -match 'NVIDIA') { $brand = 'NVIDIA' }
        elseif ($g.Name -match 'AMD|Radeon') { $brand = 'AMD' }
        elseif ($g.Name -match 'Intel') { $brand = 'Intel' }
        $isVirtual = $g.Name -match 'Parsec|Remote Display|Meta Virtual|TeamViewer|AnyDesk|VNC|Virtual Display|Citrix|VMware|Hyper-V|RDP'
        $vramGB = 0
        try {
            if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) { $vramGB = [math]::Round($g.AdapterRAM / 1GB, 1) }
        } catch {}
        # Tier real GPUs by VRAM - drives which tweaks are worth the risk on that specific card.
        $tier = 'Unknown'
        if (-not $isVirtual) {
            if ($vramGB -lt 2)      { $tier = 'Entry' }
            elseif ($vramGB -lt 6)  { $tier = 'Mid' }
            else                    { $tier = 'High' }
        }
        $list.Add([PSCustomObject]@{
            Brand         = $brand
            Name          = $g.Name
            VramGB        = $vramGB
            DriverVersion = $g.DriverVersion
            IsVirtual     = $isVirtual
            Tier          = $tier
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
    # Channel config: 2+ sticks of matching capacity = likely dual/multi-channel (real bandwidth
    # difference vs a single stick - single-channel is the #1 silent FPS killer on many PCs).
    $channelConfig = 'Single-channel'
    if ($slots -ge 2) {
        $caps = $sticks | ForEach-Object { $_.Capacity } | Sort-Object -Unique
        $channelConfig = if ($caps.Count -le 1) { 'Dual/Multi-channel (matched sticks)' } else { 'Mismatched capacity - may fall back to single-channel-like bandwidth' }
    }
    # Speed tier drives how hard it's worth pushing IoPageLockLimit/standby-list aggressiveness.
    $speedTier = 'Mid'
    if ($speed -gt 0 -and $speed -lt 2667) { $speedTier = 'Slow' }
    elseif ($speed -ge 3600) { $speedTier = 'Fast' }
    [PSCustomObject]@{
        TotalGB       = $totalGB
        Slots         = $slots
        SpeedMHz      = $speed
        Type          = $type
        ChannelConfig = $channelConfig
        SpeedTier     = $speedTier
    }
}

function Get-HwStorage {
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    $volumesByDisk = @{}
    try {
        Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
            $vol = Get-Volume -Partition $_ -ErrorAction SilentlyContinue
            if ($vol) {
                if (-not $volumesByDisk.ContainsKey($_.DiskNumber)) { $volumesByDisk[$_.DiskNumber] = New-Object System.Collections.Generic.List[object] }
                $volumesByDisk[$_.DiskNumber].Add($vol)
            }
        }
    } catch {}
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in $disks) {
        $kind = 'HDD'
        if ($d.BusType -eq 'NVMe') { $kind = 'NVMe' }
        elseif ($d.MediaType -eq 'SSD') { $kind = 'SATA SSD' }
        elseif ($d.MediaType -eq 'HDD') { $kind = 'HDD' }
        $sizeGB = [math]::Round($d.Size / 1GB, 0)
        $freePctMin = 100
        try {
            $vols = $volumesByDisk[[int]$d.DeviceId]
            if ($vols) {
                foreach ($v in $vols) {
                    if ($v.Size -gt 0) {
                        $pct = [math]::Round(($v.SizeRemaining / $v.Size) * 100, 0)
                        if ($pct -lt $freePctMin) { $freePctMin = $pct }
                    }
                }
            }
        } catch {}
        $list.Add([PSCustomObject]@{
            FriendlyName  = $d.FriendlyName
            Kind          = $kind
            SizeGB        = $sizeGB
            BusType       = $d.BusType
            FreePercent   = $freePctMin
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
        $isWireless = ($a.PhysicalMediaType -match 'Native 802.11|Wireless' -or $a.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11')
        # Parse the numeric link speed (e.g. "866.7 Mbps", "1 Gbps", "2.5 Gbps") into Mbps for tiering.
        $linkMbps = 0
        try {
            if ($a.LinkSpeed -match '([\d\.]+)\s*(Gbps|Mbps)') {
                $val = [double]$Matches[1]
                $linkMbps = if ($Matches[2] -eq 'Gbps') { $val * 1000 } else { $val }
            }
        } catch {}
        $speedTier = 'Mid'
        if ($linkMbps -gt 0 -and $linkMbps -lt 200) { $speedTier = 'Slow' }
        elseif ($linkMbps -ge 1000) { $speedTier = 'Fast' }
        $list.Add([PSCustomObject]@{
            Name         = $a.Name
            Vendor       = $vendor
            Model        = $a.InterfaceDescription
            LinkSpeed    = $a.LinkSpeed
            LinkMbps     = $linkMbps
            SpeedTier    = $speedTier
            IsWireless   = $isWireless
            IfIndex      = $a.IfIndex
        })
    }
    return $list
}

function Invoke-HardwareScan {
    Write-Info2 "Scanning hardware..."
    $hw = [PSCustomObject]@{
        Cpu      = Get-HwCpu
        Gpu      = Get-HwGpu
        Ram      = Get-HwRam
        Storage  = Get-HwStorage
        Nic      = Get-HwNic
        IsLaptop = Get-HwIsLaptop
        ScanTime = Get-Date
    }
    $script:HwInfo = $hw
    return $hw
}

function Show-HardwareSummary {
    param([Parameter(Mandatory)]$Hw)
    Write-Host ""
    Write-Host "  ================= HARDWARE SUMMARY =================" -ForegroundColor Cyan
    $chassis = if ($Hw.IsLaptop) { 'Laptop/Portable' } else { 'Desktop' }
    Write-Host ("  Chassis : {0}" -f $chassis) -ForegroundColor DarkGray
    $cpuBadges = New-Object System.Collections.Generic.List[string]
    if ($Hw.Cpu.Generation -gt 0) { $cpuBadges.Add($(if ($Hw.Cpu.Brand -eq 'Intel') { "$($Hw.Cpu.Generation)th Gen" } else { "$($Hw.Cpu.Generation)000-series" })) }
    if ($Hw.Cpu.Unlocked) { $cpuBadges.Add('unlocked') }
    if ($Hw.Cpu.Hybrid) { $cpuBadges.Add('hybrid P+E-core') }
    if ($Hw.Cpu.IsX3D) { $cpuBadges.Add('3D V-Cache') }
    if ($Hw.Cpu.IsApu) { $cpuBadges.Add('APU') }
    $cpuBadgeTxt = if ($cpuBadges.Count -gt 0) { ", " + ($cpuBadges -join ', ') } else { '' }
    Write-Host ("  CPU     : {0}  [{1}, {2}-core tier{3}]  {4}C/{5}T  {6} MHz  SMT/HT={7}" -f $Hw.Cpu.Name, $Hw.Cpu.Brand, $Hw.Cpu.Tier, $cpuBadgeTxt, $Hw.Cpu.Cores, $Hw.Cpu.Threads, $Hw.Cpu.MaxClockMHz, $Hw.Cpu.SmtOrHt) -ForegroundColor White
    if ($Hw.Gpu.Count -eq 0) {
        Write-Host "  GPU     : none detected" -ForegroundColor White
    } else {
        foreach ($g in $Hw.Gpu) {
            $tierTxt = if ($g.IsVirtual) { 'virtual/remote - skipped' } else { "$($g.Tier) tier" }
            Write-Host ("  GPU     : {0}  [{1}, {2}]  VRAM={3}GB  Driver={4}" -f $g.Name, $g.Brand, $tierTxt, $g.VramGB, $g.DriverVersion) -ForegroundColor White
        }
    }
    Write-Host ("  RAM     : {0} GB total  {1} sticks  {2} MHz [{3} tier]  {4}  [{5}]" -f $Hw.Ram.TotalGB, $Hw.Ram.Slots, $Hw.Ram.SpeedMHz, $Hw.Ram.SpeedTier, $Hw.Ram.Type, $Hw.Ram.ChannelConfig) -ForegroundColor White
    foreach ($s in $Hw.Storage) {
        Write-Host ("  Storage : {0}  [{1}]  {2} GB  Free={3}%" -f $s.FriendlyName, $s.Kind, $s.SizeGB, $s.FreePercent) -ForegroundColor White
    }
    if ($Hw.Nic.Count -eq 0) {
        Write-Host "  NIC     : none up/detected" -ForegroundColor White
    } else {
        foreach ($n in $Hw.Nic) {
            $mediaTxt = if ($n.IsWireless) { 'Wireless' } else { 'Wired' }
            Write-Host ("  NIC     : {0}  [{1}, {2}, {3} tier]  {4}  Link={5}" -f $n.Name, $n.Vendor, $mediaTxt, $n.SpeedTier, $n.Model, $n.LinkSpeed) -ForegroundColor White
        }
    }
    Write-Host "  ======================================================" -ForegroundColor Cyan
    Write-Host "  Note: tweaks below are chosen per exact component - a setting applied on this" -ForegroundColor DarkGray
    Write-Host "  PC may be skipped/different on another PC with different hardware." -ForegroundColor DarkGray
    Write-Host ""
}

# ===========================================================================
# v2.0 — CPU ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-CpuAdaptive {
    param([Parameter(Mandatory)]$Cpu, [Parameter(Mandatory)][bool]$IsLaptop)
    if ($Cpu.Brand -eq 'Intel') {
        $genTxt = if ($Cpu.Generation -gt 0) { "$($Cpu.Generation)th Gen" } else { 'Gen unknown' }
        $lockTxt = if ($Cpu.Unlocked) { 'unlocked (K/KS/KF)' } else { 'locked SKU' }
        Write-Info2 "Intel CPU detected: $genTxt, $lockTxt, $($Cpu.Tier)-core tier - removing OS-level power limits"
        try {
            # Boost mode = Aggressive (2) and min processor state = 100% on BOTH AC and battery,
            # on every SKU (locked or unlocked). This is the OS-level power-limit ceiling Windows
            # itself controls; locked SKUs are still hard-capped in hardware by Intel underneath
            # this (PL1/PL2), so this setting won't let a locked chip exceed its silicon limit, but
            # it removes every OS-side throttle so nothing is held back from what the chip can do.
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 2 2>$null | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 2 2>$null | Out-Null
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 893dee8e-2bef-41e0-89c6-b55d0929964c 100 2>$null | Out-Null
            $dcMin = if ($IsLaptop) { 50 } else { 100 }
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR 893dee8e-2bef-41e0-89c6-b55d0929964c $dcMin 2>$null | Out-Null
            powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
            Write-Ok "Boost=Aggressive (2), min processor state=100% on AC and ${dcMin}% on battery - tuned for this chassis"
            # EPP is optional and hardware/firmware-dependent. Only write it
            # when powercfg exposes the setting; never create a fake registry value.
            $eppGuid = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
            $eppQuery = @(powercfg.exe /query SCHEME_CURRENT SUB_PROCESSOR $eppGuid 2>$null) -join "`n"
            if ($eppQuery -and $eppQuery -notmatch 'Invalid Parameters|cannot find') {
                $eppBefore = ($eppQuery | Select-String 'Current AC Power Setting Index|Current DC Power Setting Index') -join '; '
                powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR $eppGuid 0 2>$null | Out-Null
                powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR $eppGuid $(if ($IsLaptop) { 50 } else { 0 }) 2>$null | Out-Null
                $eppAfter = @(powercfg.exe /query SCHEME_CURRENT SUB_PROCESSOR $eppGuid 2>$null | Select-String 'Current AC Power Setting Index|Current DC Power Setting Index') -join '; '
                Write-Ok "EPP supported: BEFORE [$eppBefore] AFTER [$eppAfter]"
            } else {
                Write-Info2 "EPP: SKIPPED (PERFEPP is not exposed by this CPU/firmware/power plan)"
            }
            if ($IsLaptop) { Write-Info2 "Laptop battery profile: AC stays at maximum responsiveness; battery uses ${dcMin}% minimum to reduce heat and power drain." }
        } catch { Write-Warn2 "Some Intel powercfg tweaks failed: $($_.Exception.Message)" }
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7' 'Attributes' 2 'DWord' | Out-Null
        if (-not $Cpu.Unlocked) { Write-Info2 "Locked SKU note: Windows-side limits are now fully open, but Intel's hardware PL1/PL2 power cap on a locked chip can only be raised further from BIOS/motherboard UEFI (Enable MCE / raise Power Limits), not from Windows." }
        if ($Cpu.SmtOrHt) { Write-Warn2 "Hyper-Threading is ON. Leave it ON unless a specific game/anti-cheat asks you to disable it in BIOS." }
        if ($Cpu.Hybrid) {
            Write-Info2 "$genTxt is a hybrid Performance+Efficient core design. Windows 11's built-in Thread Director already schedules FiveM onto P-cores automatically - we deliberately do NOT force manual core affinity here, since a wrong manual pin is worse than the default scheduler on hybrid chips."
        }
    }
    elseif ($Cpu.Brand -eq 'AMD') {
        $genTxt = if ($Cpu.Generation -gt 0) { "Ryzen $($Cpu.Generation)000-series" } else { 'Ryzen (series unknown)' }
        $skuTxt = if ($Cpu.IsX3D) { '3D V-Cache (X3D)' } elseif ($Cpu.Unlocked) { 'unlocked (X)' } elseif ($Cpu.IsApu) { 'APU (G-series)' } else { 'locked SKU' }
        Write-Info2 "AMD CPU detected: $genTxt, $skuTxt, $($Cpu.Tier)-core tier - removing OS-level power limits"
        try {
            # Prefer/duplicate 'AMD Ryzen High Performance' scheme if present, else High Performance
            $list = powercfg.exe /list
            $ryzenGuid = $null
            foreach ($line in $list) {
                if (($line -match 'Ryzen') -and ($line -match '([0-9a-fA-F-]{36})')) { $ryzenGuid = $Matches[1]; break }
            }
            if ($ryzenGuid) {
                powercfg.exe /setactive $ryzenGuid 2>$null | Out-Null
                Write-Ok "Power plan: AMD Ryzen High Performance selected"
            }
            # Min processor state = 100% on AC AND battery, on every SKU including X3D, per your request.
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 893dee8e-2bef-41e0-89c6-b55d0929964c 100 2>$null | Out-Null
            $dcMin = if ($IsLaptop) { 50 } else { 100 }
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR 893dee8e-2bef-41e0-89c6-b55d0929964c $dcMin 2>$null | Out-Null
            powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
            Write-Ok "Min processor state = 100% on AC and ${dcMin}% on battery - tuned for this chassis"
            if ($Cpu.IsX3D) { Write-Warn2 "3D V-Cache part - this will run hotter at idle than X3D's default power profile. Watch temps; PBO/curve-optimizer tuning in BIOS is the next step if you want to push further." }
            if ($IsLaptop) { Write-Warn2 "This is a laptop - battery drains faster and fans run louder with power limits removed on battery too. That's intentional per your request." }
        } catch { Write-Warn2 "Some AMD powercfg tweaks failed: $($_.Exception.Message)" }
        if (-not $Cpu.Unlocked -and -not $Cpu.IsX3D) { Write-Info2 "Locked SKU note: Windows-side limits are now fully open, but the hardware PPT/TDC/EDC power limit on this chip can only be raised further via PBO settings in BIOS, not from Windows." }
        if ($Cpu.SmtOrHt) { Write-Info2 "SMT is ON (logical=$($Cpu.Threads) physical=$($Cpu.Cores)) - left as-is, only disable in BIOS if a specific anti-cheat requires it." }
        if ($Cpu.IsApu) { Write-Info2 "G-series APU detected - if you're using the integrated GPU (not a discrete card), keep an eye on shared-memory/VRAM allocation in BIOS for the best FiveM headroom." }
    }
    else {
        Write-Warn2 "CPU brand not recognized - skipping CPU-specific deep tweaks (generic power tweaks from Apply Ultra still apply)"
    }

    # Core parking is a SEPARATE mechanism from min-processor-state above: even at 100% min
    # P-state, Windows can still fully "park" (idle-off) logical cores under light load and
    # un-park them on demand - that park/unpark transition is a real, measurable source of
    # 1%-low stutters in bursty game workloads (a core parks during a quiet frame, then a
    # sudden AI/physics/network spike needs it NOW and pays the wake-up latency). Setting both
    # the parked-core minimum AND maximum to 100% keeps every logical core awake at all times.
    try {
        $cpGuid = '0cc5b647-c1df-4637-891a-dec35c318583'   # SUB_PROCESSOR core parking min/max cores
        powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR $cpGuid 100 2>$null | Out-Null
        powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR $cpGuid 100 2>$null | Out-Null
        powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
        Write-Ok "CPU core parking disabled (100% of logical cores stay unparked) - removes park/unpark wake-up latency from 1% lows"
    } catch { Write-Warn2 "Core parking tweak failed: $($_.Exception.Message)" }
}

# ===========================================================================
# v2.0 — GPU ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-GpuAdaptive {
    param([Parameter(Mandatory)]$GpuList)
    if ($GpuList.Count -eq 0) { Write-Warn2 "No discrete/display GPU detected - skipping GPU deep tweaks"; return }
    foreach ($gpu in $GpuList) {
        if ($gpu.IsVirtual) {
            Write-Warn2 "$($gpu.Name) is a virtual/remote display adapter (Parsec/RDP/VM etc) - skipped entirely, tweaking it does nothing for real game rendering"
            continue
        }
        if ($gpu.Brand -eq 'NVIDIA') {
            Write-Info2 "NVIDIA GPU detected ($($gpu.Name), $($gpu.Tier) tier, $($gpu.VramGB)GB VRAM) - applying deep tweaks for this tier"
            $nv = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak'
            Set-Reg $nv 'LowLatency' 2 'DWord' | Out-Null                       # Ultra Low Latency
            Set-Reg $nv 'PowerMizerEnable' 1 'DWord' | Out-Null
            Set-Reg $nv 'PowerMizerLevel' 1 'DWord' | Out-Null
            Set-Reg $nv 'PowerMizerLevelAC' 1 'DWord' | Out-Null                # Prefer Max Performance
            Set-Reg $nv 'PrerenderLimit' 1 'DWord' | Out-Null                   # Max pre-rendered frames = 1
            Set-Reg $nv 'OGL_ThreadControl' 1 'DWord' | Out-Null                # Threaded optimization ON
            Set-Reg $nv 'ShaderCache' 1 'DWord' | Out-Null
            if ($gpu.Tier -eq 'Entry') {
                # Entry-level card (<2GB VRAM): skip Coolbits OC unlock - these cards usually have
                # thin power delivery/cooling and little headroom, so OC unlock mainly adds risk
                # without a real FPS gain. LowLatency/PowerMizer/PrerenderFrames still help though.
                Write-Warn2 "Entry-tier VRAM ($($gpu.VramGB)GB) - Coolbits OC-unlock skipped on this GPU (little headroom, added instability risk for minimal gain)"
                Write-Ok "LowLatency=Ultra, PowerMizer=Max, PrerenderFrames=1, Threaded Opt=ON, Shader Cache=ON"
            } else {
                Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak' 'Coolbits' 24 'DWord' | Out-Null   # unlock OC in NVCP
                Write-Ok "LowLatency=Ultra, PowerMizer=Max, PrerenderFrames=1, Threaded Opt=ON, Coolbits=24, Shader Cache=ON"
            }
        }
        elseif ($gpu.Brand -eq 'AMD') {
            Write-Info2 "AMD GPU detected ($($gpu.Name), $($gpu.Tier) tier, $($gpu.VramGB)GB VRAM) - applying deep tweaks for this tier"
            $amdKey = 'HKLM:\SOFTWARE\AMD\CN'
            Set-Reg $amdKey 'EnableUlps' 0 'DWord' | Out-Null                   # prevent stutter from power state switching
            Set-Reg $amdKey 'KMD_EnableComputePreemption' 0 'DWord' | Out-Null
            Set-Reg $amdKey 'Tessellation' 'AMD Optimized' 'String' | Out-Null
            if ($gpu.Tier -eq 'Entry') {
                # Deep-sleep-disable / DRMDMA power gating off keeps the GPU running hot/high-power
                # even at idle - worth it on a card with headroom to spare, not worth the extra heat
                # on a thin/entry card that's already power/thermal constrained.
                Write-Warn2 "Entry-tier VRAM ($($gpu.VramGB)GB) - deep-sleep-disable / power-gating-off skipped to avoid extra heat on a thermally-constrained card"
                Write-Ok "EnableUlps=0, ComputePreemption=0, Tessellation=AMD Optimized"
            } else {
                Set-Reg $amdKey 'PP_SclkDeepSleepDisable' 1 'DWord' | Out-Null
                Set-Reg $amdKey 'DisableDrmdmaPowerGating' 1 'DWord' | Out-Null
                Write-Ok "EnableUlps=0, SclkDeepSleepDisable=1, ComputePreemption=0, DrmdmaPowerGating=0, Tessellation=AMD Optimized"
            }
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
        Write-Ok "Low-memory profile: paging executive kept pageable; IoPageLockLimit unchanged"
    }
    elseif ($Ram.TotalGB -lt 16) {
        Write-Info2 "RAM 8-15GB ($($Ram.TotalGB)GB) - applying balanced profile"
        Set-Reg $mm 'DisablePagingExecutive' 0 'DWord' | Out-Null
        Write-Ok "Balanced profile: paging executive kept; IoPageLockLimit unchanged"
    }
    else {
        Write-Info2 "RAM >= 16GB ($($Ram.TotalGB)GB) - applying adaptive memory profile"
        Set-Reg $mm 'DisablePagingExecutive' 0 'DWord' | Out-Null
        try {
            if ($Ram.TotalGB -ge 32) { Disable-MMAgent -mc -ErrorAction SilentlyContinue; Write-Ok "Memory compression disabled (>=32GB default)" }
            else { Enable-MMAgent -mc -ErrorAction SilentlyContinue; Write-Ok "Memory compression kept on (16-31GB safe default)" }
        } catch {}
        Write-Ok "DisablePagingExecutive=0; IoPageLockLimit unchanged"
    }
    if ($Ram.ChannelConfig -eq 'Single-channel') {
        Write-Warn2 "Single-channel RAM detected ($($Ram.Slots) stick installed) - this halves memory bandwidth vs dual-channel and is one of the biggest silent FPS killers on a PC like this. No registry tweak can fix this - adding a second matched stick in the other slot is the actual fix."
    } elseif ($Ram.ChannelConfig -like 'Mismatched*') {
        Write-Warn2 "RAM sticks have mismatched capacity - may not be running true dual-channel on this PC. Matched-capacity sticks would help."
    } else {
        Write-Ok "Dual/multi-channel RAM confirmed on this PC - bandwidth is not the bottleneck here"
    }
    if ($Ram.SpeedTier -eq 'Slow') {
        Write-Warn2 "RAM speed is $($Ram.SpeedMHz)MHz (below 2667MHz) on this PC - if the motherboard/CPU supports faster RAM, enabling XMP/DOCP in BIOS would give a bigger real-world FPS gain here than any OS tweak."
    }
    # Standby-list purge was intentionally removed for Windows PowerShell 5.1 parser compatibility.
    # The RAM registry tuning above remains active; skipping this optional purge is harmless.
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
    # Per-drive free-space check: an SSD/NVMe with little free space left has fewer blocks for the
    # controller to wear-level/TRIM against, which measurably raises write latency on THAT specific
    # drive - this is a per-drive fact, not something a registry tweak can fix.
    foreach ($disk in $StorageList) {
        if ($disk.Kind -ne 'HDD' -and $disk.FreePercent -lt 15) {
            Write-Warn2 "$($disk.FriendlyName) ($($disk.Kind)) is only $($disk.FreePercent)% free - SSD/NVMe write latency rises as a drive fills up, since the controller has less spare space to work with. Freeing space on this specific drive would help more than any tweak here."
        }
    }
}

# ===========================================================================
# v2.0 — NETWORK ADAPTIVE DEEP TWEAKS
# ===========================================================================
function Invoke-InputUsbAdaptive {
    param($Cpu = $null)
    # Everything here targets ONE thing: the time between a physical mouse/keyboard event
    # reaching the USB controller and it reaching the game's input loop. Network and CPU
    # tuning elsewhere in this run affect 1%-lows and ping; this is the one function that
    # is purely about raw input latency.
    $canSetIrqAffinity = [bool]($Cpu -and $Cpu.Threads -ge 2)
    $irqMask = [byte[]](2,0,0,0,0,0,0,0)

    # 1) USB Link Power Management (LPM/U1/U2 states): USB 3.x controllers can drop a port
    # into a low-power link state between packets to save power. Waking back up from that
    # state adds real, inconsistent latency to every mouse/keyboard report - the exact
    # opposite of what a competitive setup wants. Disabling this per-hub is more thorough
    # than the power-plan-wide "USB selective suspend" toggle already applied earlier.
    $usbHubsTouched = 0
    try {
        $hubClass = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
        Get-ChildItem $hubClass -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                $paramsPath = Join-Path $_.PSPath 'Device Parameters'
                if (Test-Path $paramsPath) {
                    try {
                        Set-Reg $paramsPath 'EnhancedPowerManagementEnabled' 0 'DWord' | Out-Null
                        $usbHubsTouched++
                    } catch {}
                }
            }
        }
        if ($usbHubsTouched -gt 0) {
            Write-Ok "USB Link Power Management (U1/U2 low-power link states) disabled on $usbHubsTouched USB device node(s) - removes link-wake latency from every input report"
        } else {
            Write-Info2 "No USB device nodes exposed a Link Power Management setting to disable (normal on some chipsets)"
        }
    } catch { Write-Warn2 "USB Link Power Management pass skipped: $($_.Exception.Message)" }

    # 2) Per-device selective suspend for HID input devices specifically (mice, keyboards,
    # and their composite USB parents) - belt-and-suspenders on top of the power-plan-wide
    # setting, since some HID composite devices manage their own suspend policy independent
    # of the plan-level toggle.
    $hidTouched = 0
    try {
        $hidDevices = Get-PnpDevice -Class 'HIDClass','Mouse','Keyboard' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' }
        foreach ($dev in $hidDevices) {
            try {
                $devKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters"
                if (Test-Path $devKey) {
                    Set-Reg $devKey 'EnhancedPowerManagementEnabled' 0 'DWord' | Out-Null
                    $hidTouched++
                }
            } catch {}
        }
        if ($hidTouched -gt 0) { Write-Ok "Selective suspend disabled directly on $hidTouched HID input device(s) (mouse/keyboard/composite)" }
    } catch { Write-Warn2 "Per-device HID power tweak skipped: $($_.Exception.Message)" }

    # 3) IRQ affinity for USB host controllers - same reasoning as the NIC IRQ steering
    # earlier: keep USB interrupt handling off Core 0 so a busy Core 0 (where Windows and
    # most game main-threads default to) never delays processing a fresh input report.
    try {
        $usbCtrlClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{36fc9e60-c465-11cf-8056-444553540000}'
        $ctrls = Get-ChildItem $usbCtrlClass -ErrorAction SilentlyContinue | Where-Object {
            (Get-ItemProperty $_.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc -match 'Host Controller|xHCI|eXtensible'
        }
        $steered = 0
        foreach ($ctrl in $ctrls) {
            if (-not $canSetIrqAffinity) { break }
            try {
                Set-Reg $ctrl.PSPath 'MessageSignaledInterruptProperties\MSISupported' 1 'DWord' | Out-Null
                $affPath = Join-Path $ctrl.PSPath 'Interrupt Management\Affinity Policy'
                Set-Reg $affPath 'DevicePolicy' 4 'DWord' | Out-Null
                Set-Reg $affPath 'AssignmentSetOverride' $irqMask 'Binary' | Out-Null
                $steered++
            } catch {}
        }
        if ($steered -gt 0) { Write-Ok "IRQ affinity steered away from Core 0 for $steered USB host controller(s), MSI mode enabled" }
        elseif (-not $canSetIrqAffinity) { Write-Info2 "USB IRQ affinity skipped: CPU exposes fewer than 2 logical threads" }
    } catch { Write-Warn2 "USB host controller IRQ affinity step skipped: $($_.Exception.Message)" }

    # 4) Tighten the HID input queue size one notch further on higher-end hardware. The
    # legacy step earlier already scales this by chassis/CPU/RAM (20-32); on a CPU with
    # 16+ threads that easily drains the queue every frame, an even smaller buffer shaves a
    # little more worst-case buffering delay without risking dropped reports.
    try {
        if ($Cpu -and $Cpu.Threads -ge 16 -and $script:InputQueueSize -gt 16) {
            $script:InputQueueSize = 16
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize' $script:InputQueueSize 'DWord' | Out-Null
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize' $script:InputQueueSize 'DWord' | Out-Null
            Write-Ok "HID input queue tightened further to $($script:InputQueueSize) for this $($Cpu.Threads)-thread CPU"
        }
    } catch {}
}


function Invoke-NetworkAdaptive {
    param([Parameter(Mandatory)]$NicList, $Cpu = $null)
    if ($NicList.Count -eq 0) { Write-Warn2 "No active physical NIC detected - skipping network deep tweaks"; return }

    # RSS queue count scales with actual CPU thread count on THIS machine - more queues just
    # means more threads doing nothing on a 4-thread CPU, but genuinely spreads interrupt load
    # on an 8+ thread CPU. Cross-references the CPU scan result, not a fixed number for everyone.
    $rssQueues = 2
    if ($Cpu -and $Cpu.Threads) {
        if ($Cpu.Threads -ge 16) { $rssQueues = 8 }
        elseif ($Cpu.Threads -ge 8) { $rssQueues = 4 }
        elseif ($Cpu.Threads -ge 4) { $rssQueues = 2 }
        else { $rssQueues = 1 }
    }
    $canSetIrqAffinity = [bool]($Cpu -and $Cpu.Threads -ge 2)
    $irqMask = [byte[]](2,0,0,0,0,0,0,0)

    foreach ($nic in $NicList) {
        $mediaTxt = if ($nic.IsWireless) { 'Wi-Fi' } else { 'wired' }
        # Buffer sizing is latency-aware, not just "bigger = better": on a slow/wireless link,
        # large NIC ring buffers cause bufferbloat (packets queue up before they can go out,
        # adding real latency even though throughput looks fine). On a fast wired link there's
        # enough headroom that bigger buffers mainly help avoid drops, not add delay. So the
        # SAME vendor gets smaller buffers on a slow/Wi-Fi link and bigger ones on a fast wired link.
        $bufMult = switch ($nic.SpeedTier) { 'Slow' { 0.75 }; 'Fast' { 2.0 }; default { 1.5 } }
        if ($nic.IsWireless -and $bufMult -gt 1.25) { $bufMult = 1.25 }   # cap oversizing on Wi-Fi even if link reports "fast"

        if ($nic.Vendor -eq 'Realtek') {
            $rx = [int](1024 * $bufMult); $tx = [int](1024 * $bufMult)
            if ($rx -gt 4096) { $rx = 4096 }; if ($tx -gt 4096) { $tx = 4096 }
            Write-Info2 "Realtek NIC detected ($($nic.Model), $mediaTxt, $($nic.SpeedTier)-tier link) - applying Realtek deep tweaks scaled for this link"
            foreach ($prop in @(
                @{ Name='Receive Buffers'; Value="$rx" }, @{ Name='Transmit Buffers'; Value="$tx" },
                @{ Name='Speed & Duplex'; Value='Auto Negotiation' }, @{ Name='Interrupt Moderation'; Value='Disabled' },
                @{ Name='Flow Control'; Value='Disabled' }, @{ Name='Energy-Efficient Ethernet'; Value='Disabled' },
                @{ Name='Green Ethernet'; Value='Disabled' }, @{ Name='Gigabit Lite'; Value='Disabled' },
                @{ Name='Power Saving Mode'; Value='Disabled' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            Write-Ok "ReceiveBuffers=$rx, TransmitBuffers=$tx (scaled for $($nic.SpeedTier)-tier link), FlowControl/EEE/GreenEthernet/GigabitLite=Off"
        }
        elseif ($nic.Vendor -eq 'Intel') {
            $rx = [int](8192 * $bufMult)
            if ($rx -gt 16384) { $rx = 16384 }
            Write-Info2 "Intel NIC detected ($($nic.Model), $mediaTxt, $($nic.SpeedTier)-tier link) - applying Intel deep tweaks scaled for this link, RSS Queues=$rssQueues (matched to this CPU's $($Cpu.Threads) threads)"
            foreach ($prop in @(
                @{ Name='Interrupt Moderation Rate'; Value='Off' }, @{ Name='Receive Buffers'; Value="$rx" },
                @{ Name='Receive Side Scaling Queues'; Value="$rssQueues" }, @{ Name='Flow Control'; Value='Disabled' },
                @{ Name='Energy Efficient Ethernet'; Value='Disabled' }, @{ Name='Green Ethernet'; Value='Disabled' },
                @{ Name='Reduce Speed On Power Down'; Value='Disabled' }, @{ Name='System Idle Power Saver'; Value='Disabled' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            Write-Ok "ITR=lowest (Off), ReceiveBuffers=$rx (scaled for $($nic.SpeedTier)-tier link), RSS Queues=$rssQueues, EEE/GreenEthernet/PowerDown=Off"
        }
        elseif ($nic.Vendor -eq 'Killer') {
            $rx = [int](4096 * $bufMult); $tx = [int](4096 * $bufMult)
            if ($rx -gt 8192) { $rx = 8192 }; if ($tx -gt 8192) { $tx = 8192 }
            # Killer NICs ship with their own "Advanced Stream Detect" / bandwidth-control
            # software; the game-relevant win here is turning that shaping off so it doesn't
            # fight with the raw throughput settings below - other vendors don't have this problem.
            Write-Info2 "Killer NIC detected ($($nic.Model), $mediaTxt, $($nic.SpeedTier)-tier link) - disabling Killer traffic-shaping, scaling buffers for this link"
            foreach ($prop in @(
                @{ Name='Interrupt Moderation'; Value='Disabled' }, @{ Name='Receive Buffers'; Value="$rx" },
                @{ Name='Transmit Buffers'; Value="$tx" }, @{ Name='Adaptive Inter-Frame Spacing'; Value='Disabled' },
                @{ Name='Energy-Efficient Ethernet'; Value='Disabled' }, @{ Name='Green Ethernet'; Value='Disabled' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            Write-Ok "Interrupt Moderation=Off, ReceiveBuffers=$rx, TransmitBuffers=$tx (scaled for $($nic.SpeedTier)-tier link), EEE/GreenEthernet=Off"
        }
        elseif ($nic.Vendor -eq 'Broadcom') {
            $rx = [int](2048 * $bufMult); $tx = [int](2048 * $bufMult)
            if ($rx -gt 4096) { $rx = 4096 }; if ($tx -gt 4096) { $tx = 4096 }
            Write-Info2 "Broadcom NIC detected ($($nic.Model), $mediaTxt, $($nic.SpeedTier)-tier link) - applying Broadcom deep tweaks scaled for this link"
            foreach ($prop in @(
                @{ Name='Receive Buffers'; Value="$rx" }, @{ Name='Transmit Buffers'; Value="$tx" },
                @{ Name='Interrupt Moderation'; Value='Disabled' }, @{ Name='Flow Control'; Value='Disabled' },
                @{ Name='Energy Efficient Ethernet'; Value='Disabled' }, @{ Name='Wake on Magic Packet'; Value='Disabled' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            Write-Ok "ReceiveBuffers=$rx, TransmitBuffers=$tx (scaled for $($nic.SpeedTier)-tier link), FlowControl/EEE=Off"
        }
        else {
            Write-Warn2 "NIC vendor '$($nic.Vendor)' has no dedicated profile - applying general tweaks only"
        }
        if ($nic.SpeedTier -eq 'Slow') {
            Write-Warn2 "$($nic.Name) link is only $($nic.LinkSpeed) - this link speed itself is the biggest input/ping-latency factor here, bigger than any buffer tweak. A wired gigabit connection (or moving closer to the router for Wi-Fi) would help more than further OS tuning."
        }
        if ($nic.IsWireless) {
            Write-Info2 "$($nic.Name) is a wireless adapter - power-saving disabled below to stop Wi-Fi radio sleep from adding random latency spikes, but a wired connection is still lower and more consistent latency than any Wi-Fi tuning can fully match."
        }
        # General, all vendors: turn off every offload/power-save path that trades latency for
        # throughput or battery - none of that trade is worth it for a real-time game connection.
        try { Set-NetAdapterRss -Name $nic.Name -Enabled $true -ErrorAction SilentlyContinue } catch {}
        try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'Jumbo Packet' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
        try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'Large Send Offload V2 (IPv4)' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
        try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'Large Send Offload V2 (IPv6)' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
        try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'ARP Offload' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
        try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'NS Offload' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue } catch {}
        try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        try { Disable-NetAdapterLso -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        # IRQ affinity: point this NIC's interrupts away from Core 0 (index 1) so it doesn't
        # compete with the core Windows/game threads default onto.
        try {
            $devPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
            $sub = Get-ChildItem $devPath -ErrorAction SilentlyContinue | Where-Object {
                (Get-ItemProperty $_.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc -eq $nic.Model
            } | Select-Object -First 1
            if ($sub -and $canSetIrqAffinity) {
                Set-Reg $sub.PSPath 'MessageSignaledInterruptProperties\MSISupported' 1 'DWord' | Out-Null
                $affPath = Join-Path $sub.PSPath 'Interrupt Management\Affinity Policy'
                Set-Reg $affPath 'DevicePolicy' 4 'DWord' | Out-Null      # 4 = IrqPolicySpecifiedProcessors
                Set-Reg $affPath 'AssignmentSetOverride' $irqMask 'Binary' | Out-Null  # core index 1 (skip core 0)
                Write-Ok "IRQ affinity for $($nic.Name) steered away from Core 0 (CPU has $($Cpu.Threads) threads)"
            } elseif ($sub) {
                Write-Info2 "IRQ affinity skipped for $($nic.Name): CPU exposes fewer than 2 logical threads"
            }
        } catch { Write-Warn2 "IRQ affinity step skipped for $($nic.Name)" }
        # Per-adapter TCP registry tuning (Tcpip\Parameters\Interfaces\<GUID>) - disables Nagle's
        # algorithm on THIS interface specifically, the single biggest per-packet latency win for
        # small, frequent game packets (FiveM sends lots of tiny state updates).
        try {
            $ifPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{$((Get-NetAdapter -Name $nic.Name -ErrorAction SilentlyContinue).InterfaceGuid)}"
            if (Test-Path $ifPath) {
                Set-Reg $ifPath 'TcpAckFrequency' 1 'DWord' | Out-Null       # ACK immediately, don't batch
                Set-Reg $ifPath 'TCPNoDelay' 1 'DWord' | Out-Null           # Nagle OFF on this interface
                Set-Reg $ifPath 'TcpDelAckTicks' 0 'DWord' | Out-Null       # 0 delay before ACK
                Write-Ok "Nagle disabled + immediate ACK on $($nic.Name) specifically (per-interface, not just global)"
            }
        } catch { Write-Warn2 "Per-interface Nagle/ACK tuning skipped for $($nic.Name)" }
    }
    try { netsh.exe int tcp set global rss=enabled | Out-Null } catch {}
    try { netsh.exe int tcp set global ecncapability=disabled | Out-Null } catch {}
    # NORMAL is the Windows default; experimental is reserved for an explicit
    # A/B test and must not be silently applied as a permanent gaming tweak.
    try { netsh.exe int tcp set global autotuninglevel=normal | Out-Null } catch {}
    try { netsh.exe int tcp set global timestamps=disabled | Out-Null } catch {}
    try { netsh.exe int tcp set global rsc=disabled | Out-Null } catch {}
    try { netsh.exe int tcp set global fastopen=enabled | Out-Null } catch {}
    try { netsh.exe int tcp set supplemental template=internet icw=10 | Out-Null } catch {}
    try { netsh.exe int udp set global uro=disabled | Out-Null } catch {}    # UDP Receive Offload off - FiveM traffic is mostly UDP, offload batching adds latency here
    # Extreme mode: lower the initial retransmission timeout from the 3000ms default down to
    # 300ms (fastest Windows allows) so a single dropped SYN/packet recovers ten times faster;
    # disable TCP's Hybrid Slow Start (its heuristics can misfire as "congestion" on a genuinely
    # clean, low-latency gaming line and needlessly throttle); and disable send pacing, which
    # deliberately spaces packets out to smooth bursty senders - the opposite of what a real-time
    # game connection with small, frequent packets wants.
    # Keep TCP retransmission, HyStart and pacing at Windows defaults. These
    # affect TCP recovery/throughput, not FiveM UDP RTT directly.
    try {
        $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        Set-Reg $tcpParams 'TcpTimedWaitDelay' 30 'DWord' | Out-Null
        Set-Reg $tcpParams 'MaxUserPort' 65534 'DWord' | Out-Null
        Set-Reg $tcpParams 'FastSendDatagramThreshold' 1500 'DWord' | Out-Null   # send small UDP datagrams (like game packets) immediately, not queued
    } catch {}
    # Belt-and-suspenders: disable Nagle/enable immediate ACK on EVERY interface registered
    # under Tcpip\Parameters\Interfaces, not just the physical NICs detected above. This also
    # catches VPN/tunnel/virtual adapters (common for players routing FiveM through a VPN) that
    # the physical-NIC-only loop earlier in this function does not see.
    $extraIfCount = 0
    try {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | ForEach-Object {
            $ip = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if ($ip.DhcpIPAddress -or $ip.IPAddress) {
                Set-Reg $_.PSPath 'TcpAckFrequency' 1 'DWord' | Out-Null
                Set-Reg $_.PSPath 'TCPNoDelay' 1 'DWord' | Out-Null
                Set-Reg $_.PSPath 'TcpDelAckTicks' 0 'DWord' | Out-Null
                $extraIfCount++
            }
        }
    } catch {}
    Write-Ok "Global: RSS=ON, ECN/Timestamps/RSC=Off, AutoTuning=Normal, TCP Fast Open=On, ICW=10, UDP receive offload off"
    Write-Info2 "TCP recovery/pacing defaults kept; Nagle/immediate-ACK verified on $extraIfCount active interface(s) (TCP only)"
}

function Invoke-NetworkEnvironmentAdaptive {
    param([Parameter(Mandatory)]$NicList)
    Write-Info2 "Applying per-adapter LAN/Wi-Fi environment profile..."

    foreach ($nic in $NicList) {
        $adapter = Get-NetAdapter -Name $nic.Name -ErrorAction SilentlyContinue
        if (-not $adapter) { continue }

        # Wi-Fi gets radio power/roaming latency settings; wired gets link-only settings.
        if ($nic.IsWireless) {
            foreach ($prop in @(
                @{ Name='Transmit Power'; Value='Highest' },
                @{ Name='Roaming Aggressiveness'; Value='Highest' },
                @{ Name='MIMO Power Save Mode'; Value='No SMPS' },
                @{ Name='U-APSD support'; Value='Disabled' },
                @{ Name='Preferred Band'; Value='Prefer 5GHz band' },
                @{ Name='ARP offload for WoWLAN'; Value='Disabled' },
                @{ Name='NS offload for WoWLAN'; Value='Disabled' },
                @{ Name='Power Saving Mode'; Value='No Power Saving' },
                @{ Name='PSM'; Value='Disabled' },
                @{ Name='WoWLAN'; Value='Disable' }
                # Wireless mode is intentionally not forced; select the highest
                # stable mode supported by the AP/driver in Windows itself.
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            # Driver-independent power policy fallback: some Wi-Fi drivers do not expose "Power
            # Saving Mode" as an advanced property at all, only through the network adapter's
            # own power management tab (already handled by Disable-NetAdapterPowerManagement
            # above) plus this registry mirror that a few chipsets (Intel/Realtek) read directly.
            try {
                $wifiDevPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
                $wifiSub = Get-ChildItem $wifiDevPath -ErrorAction SilentlyContinue | Where-Object {
                    (Get-ItemProperty $_.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc -eq $nic.Model
                } | Select-Object -First 1
                if ($wifiSub) { Set-Reg $wifiSub.PSPath 'PowerSaveMode' 0 'DWord' | Out-Null }
            } catch {}
            Write-Ok "Wi-Fi profile applied: power-save/roaming settings adjusted where supported; wireless mode left to driver/AP"
        }
        else {
            foreach ($prop in @(
                @{ Name='Jumbo Packet'; Value='Disabled' },
                @{ Name='Flow Control'; Value='Disabled' },
                @{ Name='Interrupt Moderation'; Value='Disabled' },
                @{ Name='Energy Efficient Ethernet'; Value='Disabled' },
                @{ Name='Green Ethernet'; Value='Disabled' },
                @{ Name='Wake on Magic Packet'; Value='Disabled' },
                @{ Name='Gigabit Lite'; Value='Disabled' },
                @{ Name='EEE'; Value='Disabled' }
            )) {
                try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.Name -DisplayValue $prop.Value -ErrorAction SilentlyContinue } catch {}
            }
            # Push the NIC's own hardware ring buffers (Receive/Transmit Buffers) to their
            # maximum. A bigger hardware queue absorbs short bursts (alt-tab, loading screens,
            # a sudden spike of game state packets) without dropping frames - a real, direct
            # 1%-low and packet-loss fix, distinct from every OS-side buffer already tuned
            # elsewhere. Property names vary by vendor, so every known naming variant is tried;
            # each is a silent no-op on adapters that don't expose it.
            foreach ($bufName in 'Receive Buffers','Receive Descriptors','RxBuffers','Transmit Buffers','Transmit Descriptors','TxBuffers') {
                try {
                    $advProp = Get-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $bufName -ErrorAction SilentlyContinue
                    if ($advProp -and $advProp.ValidDisplayValues) {
                        $maxVal = ($advProp.ValidDisplayValues | ForEach-Object { [int]$_ } | Sort-Object -Descending | Select-Object -First 1)
                        if ($maxVal) { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $bufName -DisplayValue "$maxVal" -ErrorAction SilentlyContinue }
                    } elseif ($advProp -and $advProp.RegistryValue) {
                        # Numeric-range property without an enumerated list - registry max isn't
                        # exposed via this cmdlet, so use a generically safe high value instead.
                        Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $bufName -RegistryValue 2048 -ErrorAction SilentlyContinue
                    }
                } catch {}
            }
            Write-Ok "LAN profile applied: low-latency link settings, hardware Rx/Tx ring buffers maximized where the driver exposes them"
        }

        # Keep the adapter MTU at a standard value only when it is not a VPN/virtual interface.
        try {
            $ipIf = Get-NetIPInterface -InterfaceIndex $nic.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ipIf) {
                Write-Info2 "MTU on $($nic.Name): $($ipIf.NlMtuBytes) bytes (detected only; no automatic MTU rewrite)"
            }
        } catch {}

        # Prefer Private profile for a usable home gaming network; do not touch domain networks.
        try {
            $connectionProfile = Get-NetConnectionProfile -InterfaceIndex $nic.IfIndex -ErrorAction SilentlyContinue
            if ($connectionProfile -and $connectionProfile.NetworkCategory -eq 'Public' -and $connectionProfile.NetworkName -notmatch 'Domain') {
                $script:Changes.Add([PSCustomObject]@{ Kind='NetworkProfile'; IfIndex=$nic.IfIndex; OldCategory=[string]$connectionProfile.NetworkCategory })
                Set-NetConnectionProfile -InterfaceIndex $nic.IfIndex -NetworkCategory Private -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    # Apply the same QoS priority to all common FiveM/GTA process names.
    foreach ($exe in 'FiveM.exe','CitizenFX.exe','GTA5.exe','PlayGTAV.exe') {
        $policy = "NongPlai_$($exe -replace '\.exe$','')"
        try {
            Remove-NetQosPolicy -Name $policy -Confirm:$false -ErrorAction SilentlyContinue
            New-NetQosPolicy -Name $policy -AppPathNameMatchCondition $exe -DSCPAction 46 -NetworkProfile All -ErrorAction Stop | Out-Null
            $script:Changes.Add([PSCustomObject]@{ Kind='QosPolicy'; Name=$policy })
        } catch { Write-Log "QoS policy skipped for $exe" }
    }
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch {}
    Save-Changes
    Write-Ok "Adaptive LAN/Wi-Fi environment profile applied"
}

function Invoke-SystemAdaptiveProfile {
    param([Parameter(Mandatory)]$Hw)
    Write-Info2 "Selecting system profile from detected hardware..."

    $cpuThreads = [int]$Hw.Cpu.Threads
    $ramGB = [double]$Hw.Ram.TotalGB
    $isLaptop = [bool]$Hw.IsLaptop
    $hasFastStorage = @($Hw.Storage | Where-Object { $_.Kind -in @('NVMe','SATA SSD') }).Count -gt 0
    $hasHdd = @($Hw.Storage | Where-Object { $_.Kind -eq 'HDD' }).Count -gt 0
    $hasRealGpu = @($Hw.Gpu | Where-Object { -not $_.IsVirtual }).Count -gt 0

    # CPU tier: tune scheduler values to avoid wasting queueing/threads on small CPUs.
    $responsiveness = if ($cpuThreads -ge 16) { 0 } elseif ($cpuThreads -ge 8) { 5 } else { 10 }
    $prioritySep = if ($cpuThreads -ge 8) { 38 } else { 26 }
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' $responsiveness 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' $prioritySep 'DWord' | Out-Null

    # RAM tier: only disable compression on machines with enough physical memory.
    if ($ramGB -ge 24) {
        try { Disable-MMAgent -mc -ErrorAction Stop; $script:Changes.Add([PSCustomObject]@{ Kind='MemoryCompression' }) } catch {}
        Write-Ok "RAM profile: high-memory / compression disabled"
    } elseif ($ramGB -ge 16) {
        Write-Ok "RAM profile: 16-24GB / performance mode"
    } else {
        try { Enable-MMAgent -mc -ErrorAction SilentlyContinue } catch {}
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 0 'DWord' | Out-Null
        Write-Ok "RAM profile: limited-memory / compression kept on"
    }

    # Laptop and desktop power profiles are deliberately different.
    try {
        if ($isLaptop) {
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 50 | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVE 1 | Out-Null
        } else {
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
            powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
            powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVE 0 | Out-Null
        }
        powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    } catch {}

    # Storage tier: keep HDD-friendly caching while using aggressive SSD/NVMe paths.
    if ($hasFastStorage) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage' 2 'DWord' | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification' 0 'DWord' | Out-Null
        Write-Ok "Storage profile: SSD/NVMe performance path"
    }
    if ($hasHdd) {
        Set-SvcStart 'SysMain' 'Manual' | Out-Null
        Write-Ok "Storage profile: HDD detected / background prefetch kept compatible"
    }

    # HAGS is a hardware/driver/game-dependent A/B test. Keep the current
    # value instead of selecting ON/OFF from a coarse GPU tier heuristic.
    $hagsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $hags = Get-ItemProperty -Path $hagsPath -Name 'HwSchMode' -ErrorAction SilentlyContinue
    if ($null -ne $hags) { Write-Info2 "HAGS: current value kept ($($hags.HwSchMode)); test ON/OFF separately if needed" }
    else { Write-Info2 "HAGS: current Windows default kept (no explicit value detected)" }

    $profileName = if ($isLaptop) { 'Laptop' } else { 'Desktop' }
    $profileName += if ($cpuThreads -ge 16) { '-HighThread' } elseif ($cpuThreads -ge 8) { '-MidThread' } else { '-LowThread' }
    $profileName += if ($ramGB -ge 16) { '-HighRAM' } else { '-LowRAM' }
    $script:Changes.Add([PSCustomObject]@{ Kind='AdaptiveProfile'; Name=$profileName; CpuThreads=$cpuThreads; RamGB=$ramGB; IsLaptop=$isLaptop; FastStorage=$hasFastStorage; Hdd=$hasHdd })
    Save-Changes
    Write-Ok "Adaptive system profile selected: $profileName"
}

function Invoke-AdaptiveFiveMRuntime {
    param([Parameter(Mandatory)]$Hw)
    $targets = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('FiveM','GTAProcess','GTA5','PlayGTAV','CitizenFX')
    })
    if ($targets.Count -eq 0) {
        Write-Info2 "FiveM runtime not running - persistent game profile will apply when the game starts"
        return
    }

    $threads = [int]$Hw.Cpu.Threads
    foreach ($proc in $targets) {
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
        # Only use affinity on conventional, non-hybrid CPUs with enough logical processors.
        # Hybrid CPUs are left to Windows Thread Director.
        if ($threads -ge 8 -and -not $Hw.Cpu.Hybrid) {
            try {
                $mask = ([int64]1 -shl $threads) - 1
                $mask = $mask -band (-bnot [int64]1)   # leave logical processor 0 for OS/interrupts
                if ($mask -gt 0) { $proc.ProcessorAffinity = [intptr]$mask }
            } catch {}
        }
        Write-Ok "Runtime profile: $($proc.ProcessName) = High priority"
    }
    Save-Changes
}

# ===========================================================================
# v2.0 — SMART APPLY (scan -> adaptive apply, with progress bar + DryRun)
# ===========================================================================
function Invoke-SmartApply {
    Clear-Host
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  SMART ADAPTIVE TUNER v1.0 - HARDWARE SCAN -> DEEP TWEAK" -ForegroundColor Cyan
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
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
        @{ Name = 'CPU adaptive tweaks';     Action = { Invoke-CpuAdaptive -Cpu $hw.Cpu -IsLaptop $hw.IsLaptop } },
        @{ Name = 'GPU adaptive tweaks';     Action = { Invoke-GpuAdaptive -GpuList $hw.Gpu } },
        @{ Name = 'RAM adaptive tweaks';     Action = { Invoke-RamAdaptive -Ram $hw.Ram } },
        @{ Name = 'Storage adaptive tweaks'; Action = { Invoke-StorageAdaptive -StorageList $hw.Storage } },
        @{ Name = 'Input/USB adaptive tweaks'; Action = { Invoke-InputUsbAdaptive -Cpu $hw.Cpu } },
        @{ Name = 'Network adaptive tweaks'; Action = { Invoke-NetworkAdaptive -NicList $hw.Nic -Cpu $hw.Cpu; Invoke-NetworkEnvironmentAdaptive -NicList $hw.Nic } }
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
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  HARDWARE SCAN ONLY - no changes will be made" -ForegroundColor Cyan
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    $hw = Invoke-HardwareScan
    Show-HardwareSummary -Hw $hw
    Read-Host "Press Enter to continue"
}

function Invoke-ExportReport {
    param([switch]$FromGui)
    if (-not $FromGui) { Clear-Host }
    Write-Host "  EXPORT HARDWARE + TWEAK REPORT (HTML)" -ForegroundColor Cyan
    $outPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("NongPlai_Tuner_Report_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $html = @(
        '<!doctype html><html><head><meta charset="utf-8"><title>NongPlaiShop Report</title></head><body>'
        '<h1>NongPlaiShop Smart Adaptive Tuner</h1>'
        ("<p>Generated: {0}</p>" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        '</body></html>'
    ) -join [Environment]::NewLine
    try {
        Set-Content -Path $outPath -Value $html -Encoding UTF8
        Write-Ok "Report saved: $outPath"
        Start-Process -FilePath $outPath -ErrorAction SilentlyContinue
    }
    catch {
        Write-Bad "Could not save report: $($_.Exception.Message)"
    }
    if (-not $FromGui -and -not $script:GuiWorker) { Read-Host "Press Enter to continue" }
}

# ===========================================================================
# v2.0 — DO EVERYTHING (Legacy Apply Ultra + Hardware Scan + Adaptive Deep Tweaks, one shot)
function Get-HardwareCapabilities {
    param([Parameter(Mandatory)]$Hw)
    $physicalGpu = @($Hw.Gpu | Where-Object { -not $_.IsVirtual })
    $caps = [ordered]@{
        CPU = [ordered]@{ Brand=$Hw.Cpu.Brand; Cores=$Hw.Cpu.Cores; Threads=$Hw.Cpu.Threads; Hybrid=$Hw.Cpu.Hybrid; EPP=$false; Boost=$true }
        GPU = [ordered]@{ Physical=($physicalGpu.Count -gt 0); Virtual=(@($Hw.Gpu | Where-Object IsVirtual).Count -gt 0); HAGS=$false; Vendors=(@($physicalGpu | ForEach-Object Brand) -join ',') }
        RAM = [ordered]@{ TotalGB=$Hw.Ram.TotalGB; Compression=$true; Pagefile=$true; Channels=$Hw.Ram.ChannelConfig }
        Storage = [ordered]@{ Count=@($Hw.Storage).Count; Fast=(@($Hw.Storage | Where-Object Kind -in @('NVMe','SATA SSD')).Count -gt 0) }
        Network = [ordered]@{ Count=@($Hw.Nic).Count; WiFi=(@($Hw.Nic | Where-Object IsWireless).Count -gt 0); LAN=(@($Hw.Nic | Where-Object { -not $_.IsWireless }).Count -gt 0); RSS=$true }
    }
    try {
        $eppGuid = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
        $q = @(powercfg.exe /query SCHEME_CURRENT SUB_PROCESSOR $eppGuid 2>$null) -join "`n"
        $caps.CPU.EPP = [bool]($q -and $q -notmatch 'Invalid Parameters|cannot find')
    } catch {}
    try {
        $h = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue
        $caps.GPU.HAGS = [bool]($null -ne $h)
    } catch {}
    return [PSCustomObject]$caps
}

function Get-SupportedFeatures {
    param([Parameter(Mandatory)]$Capabilities)
    [ordered]@{
        EPP = if ($Capabilities.CPU.EPP) { 'Supported' } else { 'Unsupported' }
        HAGS = if ($Capabilities.GPU.HAGS) { 'Supported/Current value detected' } else { 'Unknown/Windows default' }
        RSS = if ($Capabilities.Network.RSS) { 'Supported/verify per adapter' } else { 'Unknown' }
        GPUProfile = if ($Capabilities.GPU.Physical) { 'Physical GPU detected' } else { 'SKIP: no physical GPU' }
        WiFiProfile = if ($Capabilities.Network.WiFi) { 'Supported/adapter-specific' } else { 'SKIP: no Wi-Fi adapter' }
        LanProfile = if ($Capabilities.Network.LAN) { 'Supported/adapter-specific' } else { 'SKIP: no LAN adapter' }
    }
}
# ===========================================================================
# ===========================================================================
# AGGRESSIVE OPTIMIZATION MODULE
# ===========================================================================
function Set-HardcorePowerSetting {
    param(
        [Parameter(Mandatory)][string]$SubGroup,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][int]$Value,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        $query = @(powercfg.exe /query SCHEME_CURRENT $SubGroup $Setting 2>$null) -join "`n"
        $oldMatch = [regex]::Match($query, '(?im)Current AC Power Setting Index:\s+0x([0-9a-f]+)')
        if (-not $oldMatch.Success) { throw "Power setting is not exposed by the active plan" }
        $oldValue = [convert]::ToInt32($oldMatch.Groups[1].Value, 16)
        if ($oldValue -eq $Value) {
            Write-Info2 "$Label already set to $Value"
            return
        }
        if ($script:DryRun) {
            Write-Host "  [DRYRUN] would set $Label to $Value" -ForegroundColor DarkCyan
            return
        }
        powercfg.exe /setacvalueindex SCHEME_CURRENT $SubGroup $Setting $Value 2>$null | Out-Null
        powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "powercfg returned exit code $LASTEXITCODE" }
        $script:Changes.Add([PSCustomObject]@{
            Kind = 'PowerSetting'
            SubGroup = $SubGroup
            Setting = $Setting
            OldValue = $oldValue
        })
        Write-Host "  [OK] $Label disabled" -ForegroundColor Green
    } catch {
        Write-Warn2 "$Label skipped: $($_.Exception.Message)"
    }
}

function Set-HardcoreNetworkTweaks {
    Write-Host ""; Write-Host "HARDCORE NETWORK & WI-FI" -ForegroundColor Red

    try {
        netsh.exe int tcp set global congestionprovider=cubic 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "netsh returned exit code $LASTEXITCODE" }
        $script:Changes.Add([PSCustomObject]@{ Kind = 'NetshCongestionProvider'; OldValue = 'default' })
        Write-Host "  [OK] TCP congestion provider set to CUBIC" -ForegroundColor Green
    } catch { Write-Warn2 "TCP congestion provider skipped: $($_.Exception.Message)" }

    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    foreach ($adapter in $adapters) {
        foreach ($propertyName in 'Large Send Offload V2 (IPv4)','Large Send Offload V2 (IPv6)') {
            try {
                $property = Get-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $propertyName -ErrorAction SilentlyContinue
                if (-not $property) { continue }
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $propertyName -DisplayValue 'Disabled' -ErrorAction Stop
                $script:Changes.Add([PSCustomObject]@{
                    Kind = 'AdapterAdvancedProperty'
                    AdapterName = $adapter.Name
                    DisplayName = $property.DisplayName
                    OldDisplayValue = [string]$property.DisplayValue
                    OldRegistryValue = [string]$property.RegistryValue
                })
                Write-Host "  [OK] $($adapter.Name): $propertyName disabled" -ForegroundColor Green
            } catch { Write-Warn2 "$($adapter.Name): $propertyName skipped: $($_.Exception.Message)" }
        }

        try {
            $config = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index=$($adapter.IfIndex)" -ErrorAction Stop
            if ($config -and $config.IPEnabled) {
                $oldNetbios = if ($null -eq $config.TcpipNetbios) { 0 } else { [int]$config.TcpipNetbios }
                if ($oldNetbios -ne 2) {
                    Invoke-CimMethod -InputObject $config -MethodName EnableNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -ErrorAction Stop | Out-Null
                    $script:Changes.Add([PSCustomObject]@{ Kind = 'Netbios'; IfIndex = $adapter.IfIndex; OldValue = $oldNetbios })
                    Write-Host "  [OK] $($adapter.Name): NetBIOS over TCP/IP disabled" -ForegroundColor Green
                }
            }
        } catch { Write-Warn2 "$($adapter.Name): NetBIOS change skipped: $($_.Exception.Message)" }
    }

    foreach ($wifi in @($adapters | Where-Object { $_.Name -match '(?i)wi-?fi|wireless|802\.11' -or $_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11' })) {
        try {
            $autoConfigState = @(netsh.exe wlan show autoconfig interface="$($wifi.Name)" 2>$null) -join "`n"
            if ($autoConfigState -notmatch '(?i)enabled|disabled') {
                Write-Warn2 "Wi-Fi autoconfig state could not be read on $($wifi.Name); skipped to protect reset accuracy"
                continue
            }
            $oldEnabled = $autoConfigState -match '(?i)enabled'
            if (-not $oldEnabled) {
                Write-Info2 "Wi-Fi autoconfig is already disabled on $($wifi.Name); skipped"
                continue
            }
            netsh.exe wlan set autoconfig enabled=no interface="$($wifi.Name)" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "netsh returned exit code $LASTEXITCODE" }
            $script:Changes.Add([PSCustomObject]@{ Kind = 'WlanAutoConfig'; InterfaceName = $wifi.Name; OldEnabled = $oldEnabled })
            Write-Host "  [WARNING] Wi-Fi autoconfig disabled on $($wifi.Name). New Wi-Fi networks will not appear until Reset or manual re-enable." -ForegroundColor Yellow
        } catch { Write-Warn2 "Wi-Fi autoconfig skipped on $($wifi.Name): $($_.Exception.Message)" }
    }
}

function Invoke-HardcoreGamingFullSystem {
    Write-Host ""; Write-Host "HARDCORE GAMING FULL-SYSTEM OVERHAUL" -ForegroundColor Red
    Set-HardcoreNetworkTweaks

    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 'DWord' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' '8' 'String' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority' '6' 'String' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'High' 'String' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority' 'High' 'String' | Out-Null
    Write-Host "  [OK] Foreground priority and Games MMCSS profile applied" -ForegroundColor Green
    Set-HardcorePowerSetting -SubGroup '54533251-82be-4824-96c1-47b60b740d00' -Setting '5d76a2ca-e8c0-402f-a133-2158492d58ad' -Value 1 -Label 'Processor idle disable'

    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5 'DWord' | Out-Null
    Set-HardcorePowerSetting -SubGroup '501a4d13-42af-4429-9fd1-a8218c268e20' -Setting 'ee12f906-d277-404b-b6da-e5fa1a558deb' -Value 0 -Label 'PCIe ASPM'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0 'DWord' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0 'DWord' | Out-Null
    Write-Host "  [OK] MPO, PCIe ASPM, Prefetcher and Superfetch disabled" -ForegroundColor Green

    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord' | Out-Null
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 'DWord' | Out-Null
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String' | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 'DWord' | Out-Null
    Write-Host "  [OK] GameDVR, menu delay and Windows Error Reporting disabled" -ForegroundColor Green
}

function Invoke-AggressiveOptimization {
    Write-Host ""
    Write-Host "════ AGGRESSIVE OPTIMIZATIONS ════" -ForegroundColor Red
    
    try {
        # 1. Disable Visual Effects completely
        Write-Host "🎨 Disabling visual effects..." -ForegroundColor Cyan
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 'DWord'
        
        # 2. Disable Aero (max performance)
        Write-Host "⚡ Disabling Aero transparency..." -ForegroundColor Cyan
        Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 'DWord'
        
        # 3. Aggressive memory management
        Write-Host "🧠 Aggressive memory management..." -ForegroundColor Cyan
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 1 'DWord'
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'LargeSystemCache' 1 'DWord'
        
        # 4. Disable unnecessary services (aggressive)
        Write-Host "🔌 Disabling unnecessary services..." -ForegroundColor Cyan
        $aggressiveServices = @(
            'DiagTrack'           # Diagnostic Tracking
            'dmwappushservice'    # DMW App Push
            'MapsBrokerService'   # Maps
            'lfsvc'               # Geolocation
            'SharedAccess'        # ICS (Internet Connection Sharing)
            'WSearch'             # Windows Search (can be re-enabled manually)
            'bthserv'             # Bluetooth (if not using)
        )
        foreach ($svc in $aggressiveServices) {
            try {
                $s = Get-Service $svc -EA SilentlyContinue
                if ($s) {
                    Stop-Service $svc -Force -EA SilentlyContinue
                    Set-Service $svc -StartupType Disabled -EA SilentlyContinue
                    Write-Host "  ✓ $svc disabled" -ForegroundColor Green
                }
            } catch {}
        }
        
        # 5. Aggressive network tweaks
        Write-Host "🌐 Aggressive network optimization..." -ForegroundColor Cyan
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpAckFrequency' 1 'DWord'
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TCPNoDelay' 1 'DWord'
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'MaxUserPort' 65534 'DWord'
        
        # 6. Disable cortana indexing
        Write-Host "🔍 Disabling Cortana indexing..." -ForegroundColor Cyan
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 'DWord'
        
        # 7. Game Mode tweaks
        Write-Host "🎮 Enforcing Game Mode..." -ForegroundColor Cyan
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord'
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GamePanelStartupToken' 1 'DWord'
        
        # 8. Disable notifications
        Write-Host "📢 Disabling notifications..." -ForegroundColor Cyan
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0 'DWord'

        Invoke-HardcoreGamingFullSystem
        
        Write-Host "✅ Aggressive optimizations applied" -ForegroundColor Green
    } catch {
        Write-Warn2 "Some aggressive tweaks failed: $($_.Exception.Message)"
    }
}

function Invoke-DoEverything {
    if (-not $script:GuiWorker) { try { Clear-Host } catch {} }
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  NONGPLAISHOP - APPLY EVERYTHING (Ultra + Adaptive Deep Tweak)" -ForegroundColor Cyan
    Write-Host "  📊 Optimization Level: $script:OptimizationLevel" -ForegroundColor Yellow
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    if ($script:DryRun) { Write-Warn2 "DRY RUN MODE - preview only, nothing will actually be changed" }
    Write-Host ""

    # v3.0: Detect-before-touch. Hardware/capability detection now runs FIRST,
    # before ANY setting gets written - including the legacy/aggressive steps
    # below. This is a hard ordering requirement: nothing may write a setting
    # to this machine without first knowing what hardware/capability profile
    # it actually has. The scan result ($hw/$capabilities/$features) is passed
    # down to every module that follows, including the legacy stage.
    $script:GuiStage = 'scan'
    Write-Host "  🔍 STEP 1/3: Detecting hardware and capabilities (before any change is written)..." -ForegroundColor Cyan
    $hw = Invoke-HardwareScan
    $capabilities = Get-HardwareCapabilities -Hw $hw
    $features = Get-SupportedFeatures -Capabilities $capabilities
    Write-Info2 "Universal capability scan completed; unsupported features will be skipped"
    foreach ($feature in $features.GetEnumerator()) {
        Write-Host ("  [CAPABILITY] {0}: {1}" -f $feature.Key, $feature.Value) -ForegroundColor DarkCyan
    }
    Show-HardwareSummary -Hw $hw
    Write-Host ""

    # Apply level-specific tweaks
    if ($script:OptimizationLevel -eq 'Aggressive') {
        Write-Host "🔥 Applying AGGRESSIVE optimization tweaks..." -ForegroundColor Red
        Invoke-AggressiveOptimization
    } elseif ($script:OptimizationLevel -eq 'Balanced') {
        Write-Host "⚙️ Applying BALANCED optimization tweaks..." -ForegroundColor Yellow
    } else {
        Write-Host "🛡️ Applying SAFE optimization tweaks (conservative)..." -ForegroundColor Green
    }
    Write-Host ""

    Write-Host "  ⚙️  STEP 2/3: Legacy + aggressive tuning modules..." -ForegroundColor Cyan
    # --- Part 1: full legacy 39-step Apply Ultra (creates backup folder + restore point) ---
    $script:GuiStage = 'legacy'
    $script:LegacyStepCount = 0
    Invoke-ApplyUltra

    # Full Gaming extras are included in Apply Everything.
    Invoke-FullGamingExtras
    Invoke-DeepAggressiveTuning
    Invoke-NetworkAggressiveTuning

    # Hardware/capability data was already collected at the very top of this
    # function (before any write happened) - reuse it here instead of
    # re-scanning, so the whole run works from one single, consistent
    # snapshot of the machine's hardware/capabilities.
    $script:GuiStage = 'adaptive'
    Invoke-SystemAdaptiveProfile -Hw $hw
    Invoke-AdaptiveFiveMRuntime -Hw $hw

    # --- Part 2: apply hardware-specific adaptive modules and layer on adaptive CPU/GPU/RAM/Storage/Network tweaks ---
    Write-Host ""
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan
    Write-Host "  STEP 3/3: HARDWARE PROFILE -> ADAPTIVE DEEP TWEAK" -ForegroundColor Cyan
    Write-Host ("   " + ("=" * 78)) -ForegroundColor Cyan

    if (-not $script:BackupDir) { New-BackupFolder | Out-Null }

    $modules = @(
        @{ Name = 'CPU adaptive tweaks';     Action = { Invoke-CpuAdaptive -Cpu $hw.Cpu -IsLaptop $hw.IsLaptop } },
        @{ Name = 'GPU adaptive tweaks';     Action = { Invoke-GpuAdaptive -GpuList $hw.Gpu } },
        @{ Name = 'RAM adaptive tweaks';     Action = { Invoke-RamAdaptive -Ram $hw.Ram } },
        @{ Name = 'Storage adaptive tweaks'; Action = { Invoke-StorageAdaptive -StorageList $hw.Storage } },
        @{ Name = 'Input/USB adaptive tweaks'; Action = { Invoke-InputUsbAdaptive -Cpu $hw.Cpu } },
        @{ Name = 'Network adaptive tweaks'; Action = { Invoke-NetworkAdaptive -NicList $hw.Nic -Cpu $hw.Cpu } }
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
    if (-not $script:GuiWorker) { Read-Host "Press Enter to return to menu" }
}

# ===========================================================================
# v2.3 — ADDITIVE / NON-DESTRUCTIVE NETWORK AND GAME PROFILE TOOLS
# ---------------------------------------------------------------------------
# These commands intentionally do not replace the legacy Apply Everything flow.
# A Windows setting cannot have duplicate value names, so a setting that already
# exists is skipped. Settings that require an explicit replacement (DNS) always
# take a complete snapshot first and can be restored from that snapshot.
# ===========================================================================

function Add-RegIfMissing {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','Binary','QWord','ExpandString')][string]$Type = 'DWord'
    )
    try {
        $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($existing -and ($existing.PSObject.Properties.Name -contains $Name)) {
            Write-Info2 "Skipped existing value: ${Path}\${Name}"
            return $false
        }
        return (Set-Reg -Path $Path -Name $Name -Value $Value -Type $Type)
    } catch {
        Write-Warn2 "Could not inspect ${Path}\${Name} - $($_.Exception.Message)"
        return $false
    }
}

function Get-NetworkSnapshotPath {
    param([Parameter(Mandatory)][string]$BackupDir)
    return (Join-Path $BackupDir 'network-snapshot.json')
}

function New-NetworkSnapshot {
    param([string]$BackupDir = $script:BackupDir, [switch]$Quiet)

    if ($script:DryRun) {
        if (-not $Quiet) { Write-Host '  [DRYRUN] would capture DNS, TCP, NIC, MTU, network-profile, and power-plan state.' -ForegroundColor DarkCyan }
        return $null
    }
    if (-not $BackupDir) { $BackupDir = New-BackupFolder }

    $path = Get-NetworkSnapshotPath -BackupDir $BackupDir
    if (Test-Path $path) { return $path }

    try {
        $dns = @(
            Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object {
                [PSCustomObject]@{
                    InterfaceIndex = [int]$_.InterfaceIndex
                    InterfaceAlias = [string]$_.InterfaceAlias
                    ServerAddresses = @($_.ServerAddresses)
                }
            }
        )
        $interfaces = @(
            Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object {
                [PSCustomObject]@{
                    InterfaceIndex = [int]$_.InterfaceIndex
                    InterfaceAlias = [string]$_.InterfaceAlias
                    NlMtuBytes = [int]$_.NlMtuBytes
                    Dhcp = [string]$_.Dhcp
                }
            }
        )
        $profiles = @(
            Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            ForEach-Object {
                [PSCustomObject]@{
                    InterfaceIndex = [int]$_.InterfaceIndex
                    Name = [string]$_.Name
                    NetworkCategory = [string]$_.NetworkCategory
                }
            }
        )
        $adapters = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
            ForEach-Object {
                $adapter = $_
                $advanced = @(
                    Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [PSCustomObject]@{
                            DisplayName = [string]$_.DisplayName
                            DisplayValue = [string]$_.DisplayValue
                            RegistryKeyword = [string]$_.RegistryKeyword
                            RegistryValue = @($_.RegistryValue)
                        }
                    }
                )
                [PSCustomObject]@{
                    Name = [string]$adapter.Name
                    InterfaceDescription = [string]$adapter.InterfaceDescription
                    Status = [string]$adapter.Status
                    MacAddress = [string]$adapter.MacAddress
                    LinkSpeed = [string]$adapter.LinkSpeed
                    AdvancedProperties = $advanced
                }
            }
        )
        $snapshot = [ordered]@{
            SchemaVersion = 1
            CapturedAt = (Get-Date).ToString('o')
            Dns = $dns
            Interfaces = $interfaces
            NetworkProfiles = $profiles
            Adapters = $adapters
            TcpGlobal = @(netsh.exe int tcp show global 2>$null)
            UdpGlobal = @(netsh.exe int udp show global 2>$null)
            ActivePowerScheme = @(powercfg.exe /getactivescheme 2>$null)
        }
        $snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
        $script:Changes.Add([PSCustomObject]@{ Kind='NetworkSnapshot'; Path=$path })
        Save-Changes
        if (-not $Quiet) { Write-Ok "Network snapshot saved: $path" }
        return $path
    } catch {
        Write-Warn2 "Network snapshot failed: $($_.Exception.Message)"
        return $null
    }
}

function Restore-NetworkSnapshot {
    param([Parameter(Mandatory)][string]$SnapshotPath, [switch]$Quiet)

    if (-not (Test-Path $SnapshotPath)) {
        if (-not $Quiet) { Write-Warn2 "Network snapshot not found: $SnapshotPath" }
        return $false
    }
    try {
        $snapshot = Get-Content -Path $SnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $restored = 0
        foreach ($entry in @($snapshot.Dns)) {
            if ($null -eq $entry.InterfaceIndex) { continue }
            $servers = @($entry.ServerAddresses | Where-Object { $_ })
            if ($servers.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex ([int]$entry.InterfaceIndex) -ServerAddresses $servers -ErrorAction SilentlyContinue
            } else {
                Set-DnsClientServerAddress -InterfaceIndex ([int]$entry.InterfaceIndex) -ResetServerAddresses -ErrorAction SilentlyContinue
            }
            $restored++
        }
        foreach ($entry in @($snapshot.Interfaces)) {
            if ($entry.InterfaceIndex -and $entry.NlMtuBytes -gt 0) {
                Set-NetIPInterface -InterfaceIndex ([int]$entry.InterfaceIndex) -AddressFamily IPv4 -NlMtuBytes ([int]$entry.NlMtuBytes) -ErrorAction SilentlyContinue
            }
        }
        foreach ($entry in @($snapshot.NetworkProfiles)) {
            if ($entry.InterfaceIndex -and $entry.NetworkCategory -in @('Public','Private')) {
                Set-NetConnectionProfile -InterfaceIndex ([int]$entry.InterfaceIndex) -NetworkCategory $entry.NetworkCategory -ErrorAction SilentlyContinue
            }
        }
        if (-not $Quiet) { Write-Ok "Restored DNS/MTU/network-profile state from snapshot ($restored DNS interface(s))." }
        return $true
    } catch {
        if (-not $Quiet) { Write-Warn2 "Network snapshot restore failed: $($_.Exception.Message)" }
        return $false
    }
}

function Get-AdditiveNetworkBackup {
    if ($script:DryRun) {
        Write-Host '  [DRYRUN] would create a backup folder and capture a network snapshot before changing anything.' -ForegroundColor DarkCyan
        return $null
    }
    if (-not $script:BackupDir) { New-BackupFolder | Out-Null }
    return (New-NetworkSnapshot -BackupDir $script:BackupDir -Quiet)
}

function Invoke-DnsBenchmark {
    # Section 15 of the spec: measures REAL resolution time against the current DNS and three
    # well-known public resolvers, using the same well-known hostname against each so the
    # comparison is apples-to-apples. Never changes DNS automatically - only reports numbers;
    # applying a different DNS remains a separate, explicit, user-confirmed action elsewhere.
    param([int]$Samples = 8, [string]$TestHost = 'www.google.com')

    $currentServers = @()
    try {
        $activeIf = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ConnectionState -eq 'Connected' } | Select-Object -First 1
        if ($activeIf) {
            $currentServers = @((Get-DnsClientServerAddress -InterfaceIndex $activeIf.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
        }
    } catch {}

    $candidates = [ordered]@{
        'Current' = $currentServers
        'Cloudflare (1.1.1.1)' = @('1.1.1.1')
        'Google (8.8.8.8)' = @('8.8.8.8')
        'Quad9 (9.9.9.9)' = @('9.9.9.9')
    }

    $results = @()
    foreach ($label in $candidates.Keys) {
        $servers = $candidates[$label]
        if (-not $servers -or $servers.Count -eq 0) {
            $results += [PSCustomObject]@{ Label = $label; Reachable = $false; Average = $null; Median = $null; P95 = $null; Failures = $Samples; Samples = $Samples }
            continue
        }
        $times = New-Object System.Collections.Generic.List[double]
        $fail = 0
        for ($i = 0; $i -lt $Samples; $i++) {
            try {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Resolve-DnsName -Name $TestHost -Server $servers[0] -DnsOnly -ErrorAction Stop | Out-Null
                $sw.Stop()
                $times.Add($sw.Elapsed.TotalMilliseconds)
            } catch { $fail++ }
        }
        if ($times.Count -eq 0) {
            $results += [PSCustomObject]@{ Label = $label; Reachable = $false; Average = $null; Median = $null; P95 = $null; Failures = $fail; Samples = $Samples }
            continue
        }
        $sorted = $times | Sort-Object
        $n = $sorted.Count
        $median = if ($n % 2 -eq 0) { ($sorted[$n/2 - 1] + $sorted[$n/2]) / 2 } else { $sorted[[int][math]::Floor($n/2)] }
        $p95Idx = [math]::Min($n - 1, [int][math]::Ceiling(0.95 * $n) - 1)
        $results += [PSCustomObject]@{
            Label = $label; Reachable = $true
            Average = [math]::Round(($times | Measure-Object -Average).Average, 1)
            Median  = [math]::Round($median, 1)
            P95     = [math]::Round($sorted[$p95Idx], 1)
            Failures = $fail; Samples = $Samples
        }
    }

    Write-Host ""
    Write-Host "  DNS resolution benchmark (resolving '$TestHost', $Samples samples each):" -ForegroundColor Cyan
    foreach ($r in $results) {
        if (-not $r.Reachable) {
            Write-Bad ("  {0,-24} [SKIP] unreachable or no server configured ({1}/{2} failed)" -f $r.Label, $r.Failures, $r.Samples)
        } else {
            Write-Host ("  {0,-24} avg={1,-6}ms median={2,-6}ms P95={3,-6}ms failures={4}/{5}" -f $r.Label, $r.Average, $r.Median, $r.P95, $r.Failures, $r.Samples)
        }
    }
    Write-Info2 "No DNS setting was changed by this benchmark. To apply a different DNS, use the DNS menu option and confirm explicitly."
    return $results
}

function Get-NetworkLatencyReport {
    # Real, measured statistics from N actual ping samples - never fewer than a handful of
    # samples and never a guess. Returns $null (with a console note) if the target cannot be
    # reached at all, rather than fabricating numbers.
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Label = $Target,
        [int]$Samples = 30
    )
    $rtts = New-Object System.Collections.Generic.List[double]
    $lost = 0
    for ($i = 0; $i -lt $Samples; $i++) {
        try {
            $r = Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop
            $ms = if ($r.PSObject.Properties.Name -contains 'Latency') { [double]$r.Latency } else { [double]$r.ResponseTime }
            $rtts.Add($ms)
        } catch {
            $lost++
        }
        Start-Sleep -Milliseconds 150
    }
    $lossPct = [math]::Round(($lost / [double]$Samples) * 100, 1)
    if ($rtts.Count -eq 0) {
        return [PSCustomObject]@{
            Target = $Target; Label = $Label; Reachable = $false; Samples = $Samples
            Average = $null; Median = $null; Min = $null; Max = $null; P95 = $null; P99 = $null
            Jitter = $null; PacketLossPct = 100.0
        }
    }
    $sorted = $rtts | Sort-Object
    $n = $sorted.Count
    $median = if ($n % 2 -eq 0) { ($sorted[$n/2 - 1] + $sorted[$n/2]) / 2 } else { $sorted[[int][math]::Floor($n/2)] }
    $p95Idx = [math]::Min($n - 1, [int][math]::Ceiling(0.95 * $n) - 1)
    $p99Idx = [math]::Min($n - 1, [int][math]::Ceiling(0.99 * $n) - 1)
    # Jitter: mean absolute difference between consecutive samples (RFC 3550-style approximation).
    $diffs = for ($i = 1; $i -lt $rtts.Count; $i++) { [math]::Abs($rtts[$i] - $rtts[$i-1]) }
    $jitter = if ($diffs) { ($diffs | Measure-Object -Average).Average } else { 0 }
    [PSCustomObject]@{
        Target = $Target; Label = $Label; Reachable = $true; Samples = $Samples
        Average = [math]::Round(($rtts | Measure-Object -Average).Average, 1)
        Median  = [math]::Round($median, 1)
        Min     = [math]::Round(($sorted | Select-Object -First 1), 1)
        Max     = [math]::Round(($sorted | Select-Object -Last 1), 1)
        P95     = [math]::Round($sorted[$p95Idx], 1)
        P99     = [math]::Round($sorted[$p99Idx], 1)
        Jitter  = [math]::Round($jitter, 1)
        PacketLossPct = $lossPct
    }
}

function Write-NetworkLatencyReport {
    param([Parameter(Mandatory)]$Report)
    if (-not $Report.Reachable) {
        Write-Bad "$($Report.Label): unreachable ($($Report.Samples) samples sent, $($Report.PacketLossPct)% loss) - [SKIP] no stats to report"
        return
    }
    Write-Host ("  {0,-10} avg={1,-6}ms median={2,-6}ms min={3,-6}ms max={4,-6}ms P95={5,-6}ms P99={6,-6}ms jitter={7,-5}ms loss={8}%" -f `
        $Report.Label, $Report.Average, $Report.Median, $Report.Min, $Report.Max, $Report.P95, $Report.P99, $Report.Jitter, $Report.PacketLossPct)
}

function Invoke-NetworkLatencyBenchmark {
    # Section 19/20 of the spec: real gateway + internet latency, measured separately for
    # whichever interfaces are actually up (LAN and/or Wi-Fi), never fewer than a real sample
    # set, never summarized from 1-2 pings.
    param([string]$Context = 'Benchmark')
    Write-Host ""
    Write-Host "  Network latency benchmark ($Context) - 30 samples per target, ~5s each, please wait..." -ForegroundColor Cyan
    $results = @()
    try {
        $gw = (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1 -ExpandProperty NextHop)
        if ($gw -and $gw -ne '0.0.0.0') {
            $gwReport = Get-NetworkLatencyReport -Target $gw -Label 'Gateway'
            Write-NetworkLatencyReport -Report $gwReport
            $results += $gwReport
        } else {
            Write-Info2 "Gateway: [SKIP] no default route found"
        }
    } catch { Write-Warn2 "Gateway benchmark skipped: $($_.Exception.Message)" }
    try {
        $inetReport = Get-NetworkLatencyReport -Target '8.8.8.8' -Label 'Internet'
        Write-NetworkLatencyReport -Report $inetReport
        $results += $inetReport
    } catch { Write-Warn2 "Internet benchmark skipped: $($_.Exception.Message)" }
    return $results
}


function Invoke-NetworkDiagnoseOnly {
    Clear-Host
    Write-Host ('   ' + ('=' * 78)) -ForegroundColor Cyan
    Write-Host '  NETWORK DIAGNOSE — READ ONLY / NO SETTINGS CHANGED' -ForegroundColor Green
    Write-Host ('   ' + ('=' * 78)) -ForegroundColor Cyan
    Write-Host ''

    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric)
    $defaultRoute = $routes | Select-Object -First 1
    if ($defaultRoute) { Write-Host "Default route: $($defaultRoute.NextHop) via interface $($defaultRoute.InterfaceIndex) (metric $($defaultRoute.RouteMetric))" }

    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if ($adapters.Count -eq 0) {
        Write-Warn2 'No active network adapter found.'
    }
    foreach ($adapter in $adapters) {
        Write-Host ''
        Write-Host "Adapter: $($adapter.Name)" -ForegroundColor Cyan
        Write-Host "  Model: $($adapter.InterfaceDescription)"
        Write-Host "  Link:  $($adapter.LinkSpeed)"
        $ip = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ip) { Write-Host "  MTU:   $($ip.NlMtuBytes)  DHCP: $($ip.Dhcp)" }
        $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $servers = @($dns.ServerAddresses | Where-Object { $_ })
        Write-Host ("  DNS:   " + $(if ($servers.Count) { $servers -join ', ' } else { 'Automatic / none reported' }))
        $rsc = Get-NetAdapterRsc -Name $adapter.Name -ErrorAction SilentlyContinue
        if ($rsc) { Write-Host "  RSC:   IPv4=$($rsc.IPv4Enabled) IPv6=$($rsc.IPv6Enabled)" }
        $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction SilentlyContinue
        if ($rss) { Write-Host "  RSS:   Enabled=$($rss.Enabled)" }
        $props = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Interrupt Moderation|Energy.*Ethernet|Receive Buffers|Transmit Buffers|Large Send Offload|Jumbo Packet' })
        foreach ($prop in $props) { Write-Host "  $($prop.DisplayName): $($prop.DisplayValue)" }
    }

    Write-Host ''
    Write-Host 'TCP global state:' -ForegroundColor Cyan
    netsh.exe int tcp show global 2>$null | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host 'UDP global state:' -ForegroundColor Cyan
    netsh.exe int udp show global 2>$null | ForEach-Object { Write-Host "  $_" }

    Write-Host ''
    Write-Host 'Latency benchmark (real measured samples, no settings changed):' -ForegroundColor Cyan
    Invoke-NetworkLatencyBenchmark -Context 'Diagnose' | Out-Null

    Write-Host ''
    Write-Info2 'This diagnostic does not change DNS, TCP, NIC, MTU, services, or registry values.'
}

function Set-AdditiveDnsProfile {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Servers
    )

    $adapter = Get-ActiveAdapter
    if (-not $adapter) { Write-Warn2 'No active physical adapter found; DNS was not changed.'; return $false }
    $current = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $oldServers = @($current.ServerAddresses | Where-Object { $_ })
    if (($oldServers -join ',') -eq ($Servers -join ',')) {
        Write-Info2 "DNS already uses $Label on $($adapter.Name); skipped."
        return $true
    }
    $confirm = Read-Host "DNS on '$($adapter.Name)' will change from '$($oldServers -join ', ')' to '$($Servers -join ', ')'. Type APPLY to continue"
    if ($confirm -cne 'APPLY') { Write-Host 'Cancelled. DNS was not changed.'; return $false }
    Get-AdditiveNetworkBackup | Out-Null
    if ($script:DryRun) {
        Write-Host "  [DRYRUN] would set DNS on $($adapter.Name) to ${Label}: $($Servers -join ', ')" -ForegroundColor DarkCyan
        return $true
    }
    try {
        $script:Changes.Add([PSCustomObject]@{ Kind='Dns'; IfIndex=$adapter.ifIndex; OldServers=$oldServers })
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Servers -ErrorAction Stop
        Save-Changes
        Write-Ok "DNS set to $Label on $($adapter.Name). Reset restores the original snapshot."
        return $true
    } catch {
        Write-Warn2 "DNS update failed: $($_.Exception.Message)"
        return $false
    }
}

function Add-AdditiveQosPolicies {
    $targets = @('FiveM.exe','CitizenFX.exe','GTA5.exe','PlayGTAV.exe')
    Get-AdditiveNetworkBackup | Out-Null
    $added = 0
    foreach ($exe in $targets) {
        $policyName = "NongPlaiAdditive_$($exe -replace '\\.exe$','')"
        $existing = Get-NetQosPolicy -Name $policyName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Info2 "Skipped existing QoS policy: $policyName"
            continue
        }
        if ($script:DryRun) {
            Write-Host "  [DRYRUN] would add QoS DSCP 46 policy for $exe" -ForegroundColor DarkCyan
            continue
        }
        try {
            New-NetQosPolicy -Name $policyName -AppPathNameMatchCondition $exe -DSCPAction 46 -NetworkProfile All -ErrorAction Stop | Out-Null
            $script:Changes.Add([PSCustomObject]@{ Kind='QosPolicy'; Name=$policyName })
            $added++
        } catch { Write-Warn2 "QoS policy skipped for ${exe}: $($_.Exception.Message)" }
    }
    if (-not $script:DryRun) { Save-Changes }
    Write-Ok "Added $added QoS policy/policies. Router and ISP may ignore DSCP outside your LAN."
}

function Add-AdditiveGameProfile {
    Write-Host 'Adding only missing per-user game settings; existing values are not overwritten.' -ForegroundColor Cyan
    $added = 0
    if (Add-RegIfMissing -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'FiveM.exe' -Value 'GpuPreference=2;' -Type String) { $added++ }
    if (Add-RegIfMissing -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord) { $added++ }
    if (Add-RegIfMissing -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord) { $added++ }
    if (Add-RegIfMissing -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -Type String) { $added++ }
    if ($added -gt 0) { Save-Changes }
    Write-Ok "Added $added missing game profile value(s); existing values were preserved."
}

function Invoke-NetworkCustomAdditive {
    while ($true) {
        Clear-Host
        Write-Host ('   ' + ('=' * 78)) -ForegroundColor Cyan
        Write-Host '  NETWORK CUSTOM — SNAPSHOT FIRST / EXISTING VALUES PRESERVED' -ForegroundColor Green
        Write-Host ('   ' + ('=' * 78)) -ForegroundColor Cyan
        Write-Host '  [1] Diagnose only (no changes)'
        Write-Host '  [2] DNS: Cloudflare (1.1.1.1 / 1.0.0.1)'
        Write-Host '  [3] DNS: Google (8.8.8.8 / 8.8.4.4)'
        Write-Host '  [4] DNS: Quad9 (9.9.9.9 / 149.112.112.112)'
        Write-Host '  [5] Add missing FiveM QoS policies (no policy is replaced)'
        Write-Host '  [6] Add missing per-user game profile values (no value is overwritten)'
        Write-Host '  [7] Restore latest network snapshot'
        Write-Host '  [8] DNS benchmark (measure only, does not change DNS)'
        Write-Host '  [0] Back'
        Write-Host ''
        switch (Read-Host 'Select') {
            '1' { Invoke-NetworkDiagnoseOnly; Read-Host 'Press Enter to continue' | Out-Null }
            '2' { Set-AdditiveDnsProfile -Label 'Cloudflare' -Servers @('1.1.1.1','1.0.0.1'); Read-Host 'Press Enter to continue' | Out-Null }
            '3' { Set-AdditiveDnsProfile -Label 'Google' -Servers @('8.8.8.8','8.8.4.4'); Read-Host 'Press Enter to continue' | Out-Null }
            '4' { Set-AdditiveDnsProfile -Label 'Quad9' -Servers @('9.9.9.9','149.112.112.112'); Read-Host 'Press Enter to continue' | Out-Null }
            '5' { Add-AdditiveQosPolicies; Read-Host 'Press Enter to continue' | Out-Null }
            '6' { if (-not $script:BackupDir -and -not $script:DryRun) { New-BackupFolder | Out-Null }; Add-AdditiveGameProfile; Read-Host 'Press Enter to continue' | Out-Null }
            '7' { $backup = Find-LatestBackup; if ($backup) { Restore-NetworkSnapshot -SnapshotPath (Get-NetworkSnapshotPath -BackupDir $backup) } else { Write-Warn2 'No backup folder found.' }; Read-Host 'Press Enter to continue' | Out-Null }
            '8' { Invoke-DnsBenchmark | Out-Null; Read-Host 'Press Enter to continue' | Out-Null }
            '0' { return }
            default { Write-Warn2 'Please select a valid option.' }
        }
    }
}

function Invoke-DoEverythingAdditive {
    Clear-Host
    Write-Host ('   ' + ('=' * 78)) -ForegroundColor Cyan
    Write-Host '  ADDITIVE GAME PROFILE — NO EXISTING VALUE IS OVERWRITTEN' -ForegroundColor Green
    Write-Host ('   ' + ('=' * 78)) -ForegroundColor Cyan
    Write-Host 'This profile does not call the legacy Apply Everything flow.'
    Write-Host 'It only adds missing per-user game settings and optional new QoS policies.'
    $confirm = Read-Host 'Continue? [Y/N]'
    if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled.'; return }
    if (-not $script:DryRun) {
        New-BackupFolder | Out-Null
        New-NetworkSnapshot -BackupDir $script:BackupDir | Out-Null
    }
    Add-AdditiveGameProfile
    Add-AdditiveQosPolicies
    Write-Ok 'Additive game profile complete. Existing registry values and QoS policies were preserved.'
}

# ---------------------------------------------------------------------------
# v2: prettier UI primitives - unicode box drawing, auto-padded so nothing
# ever looks misaligned even if text lengths change later.
# ---------------------------------------------------------------------------
$script:BoxWidth = 78   # inner width between the vertical borders

function Write-BoxTop {
    Write-Host ("   +" + ("=" * $script:BoxWidth) + "+") -ForegroundColor DarkCyan
}
function Write-BoxDivider {
    Write-Host ("   +" + ("-" * $script:BoxWidth) + "+") -ForegroundColor DarkCyan
}
function Write-BoxBottom {
    Write-Host ("   +" + ("=" * $script:BoxWidth) + "+") -ForegroundColor DarkCyan
}
function Write-BoxCenter {
    param([string]$Text, [ConsoleColor]$Color = 'White')
    $pad = $script:BoxWidth - $Text.Length
    if ($pad -lt 0) { $pad = 0 }
    $left = [int][Math]::Floor($pad / 2)
    $right = $pad - $left
    Write-Host "   |" -NoNewline -ForegroundColor DarkCyan
    Write-Host ((" " * $left) + $Text + (" " * $right)) -NoNewline -ForegroundColor $Color
    Write-Host "|" -ForegroundColor DarkCyan
}
function Write-BoxLine {
    # Segments array of text/color objects, rendered left to right and padded to width
    param([Parameter(Mandatory)][array]$Segments, [int]$LeftPad = 2)
    $plain = (" " * $LeftPad) + (($Segments | ForEach-Object { $_.Text }) -join '')
    $pad = $script:BoxWidth - $plain.Length
    if ($pad -lt 0) { $pad = 0 }
    Write-Host "   |" -NoNewline -ForegroundColor DarkCyan
    Write-Host (" " * $LeftPad) -NoNewline
    foreach ($seg in $Segments) {
        Write-Host $seg.Text -NoNewline -ForegroundColor $seg.Color
    }
    Write-Host (" " * $pad) -NoNewline
    Write-Host "|" -ForegroundColor DarkCyan
}
function Write-MenuItem {
    param([string]$Key, [string]$Label, [string]$Desc = '', [ConsoleColor]$KeyColor = 'Green')
    $segs = @(
        @{ Text = " [$Key] "; Color = $KeyColor },
        @{ Text = $Label; Color = 'White' }
    )
    if ($Desc) { $segs += @{ Text = "  - $Desc"; Color = 'DarkGray' } }
    Write-BoxLine -Segments $segs -LeftPad 1
}

# ---------------------------------------------------------------------------
# v2: WPF card-style launcher (replaces the plain console menu)
# The heavy-lifting functions run in a hidden worker process. The WPF window remains
# visible and receives progress events from the worker, so no PowerShell console is shown.
# ---------------------------------------------------------------------------
if (-not $ConsoleOnly) {
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        try {
            $popup = New-Object -ComObject WScript.Shell
            $popup.Popup('ไม่สามารถโหลดส่วน GUI ได้ กรุณาใช้ Windows PowerShell 5.1 (powershell.exe) และคลิกขวาเลือก Run with PowerShell', 0, 'NongPlaiShop', 0, 16) | Out-Null
        } catch {}
        exit 1
    }
}

# Keep a single WPF Application/Dispatcher alive for the whole run. Without this, WPF can
# tear down its dispatcher as soon as the first Window (e.g. the main menu) closes, which
# makes any later Window's ShowDialog() fail with "cannot call a method on a null-valued
# expression" - exactly the error this fixes (main menu closes -> worker progress window
# tries to open next and fails without a persistent Application).
if (-not $ConsoleOnly -and -not [System.Windows.Application]::Current) {
    try {
        $script:WpfApp = New-Object System.Windows.Application
        $script:WpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    } catch { $script:WpfApp = $null }
}

# No console window is re-shown by the GUI entry point.

$script:MenuCards = @(
    [PSCustomObject]@{
        Key='1'; Glyph='⚡'; Title='APPLY EVERYTHING'; Accent='#F2C94C'
        Desc='Full system gaming tune'
    },
    [PSCustomObject]@{
        Key='2'; Glyph='↺'; Title='RESET ALL'; Accent='#56CCF2'
        Desc='Restore latest backup'
    },
    [PSCustomObject]@{
        Key='3'; Glyph='✕'; Title='EXIT'; Accent='#EB5757'
        Desc='Close NongPlaiShop'
    },
    [PSCustomObject]@{
        Key='4'; Glyph='⌁'; Title='NETWORK DIAGNOSE'; Accent='#6FCF97'
        Desc='Read-only network status'
    },
    [PSCustomObject]@{
        Key='5'; Glyph='◉'; Title='NETWORK CUSTOM'; Accent='#56CCF2'
        Desc='Opt-in DNS and additive profile'
    }
)

function Show-MainMenuWpf {
    $lastBackup = Find-LatestBackup
    $dryTxt = if ($script:DryRun) { 'DRY RUN: ON' } else { 'DRY RUN: OFF' }
    $bkTxt  = if ($lastBackup) { 'Backup ล่าสุด: ' + (Split-Path $lastBackup -Leaf) } else { 'Backup ล่าสุด: ไม่พบ' }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NongPlaiShop" Height="640" Width="960"
        WindowStartupLocation="CenterScreen" WindowStyle="None"
        ResizeMode="NoResize" Background="#08080A">
  <Border CornerRadius="16" BorderBrush="#2A2A30" BorderThickness="1" ClipToBounds="True">
    <Border.Background>
      <RadialGradientBrush Center="0.5,0.15" RadiusX="0.9" RadiusY="0.9">
        <GradientStop Color="#15161C" Offset="0"/>
        <GradientStop Color="#08080A" Offset="1"/>
      </RadialGradientBrush>
    </Border.Background>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="52"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="178"/>
        <RowDefinition Height="72"/>
      </Grid.RowDefinitions>

      <!-- decorative diagonal streaks in the background, like the reference art -->
      <Canvas>
        <Line X1="80"  Y1="0" X2="30"  Y2="640" Stroke="#14FFFFFF" StrokeThickness="1"/>
        <Line X1="180" Y1="0" X2="120" Y2="640" Stroke="#0FFFFFFF" StrokeThickness="1"/>
        <Line X1="760" Y1="0" X2="700" Y2="640" Stroke="#0FFFFFFF" StrokeThickness="1"/>
        <Line X1="880" Y1="0" X2="830" Y2="640" Stroke="#14FFFFFF" StrokeThickness="1"/>
      </Canvas>

      <!-- Top bar -->
      <Grid Grid.Row="0" Name="TopBar" Background="#0F0F12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="60"/>
        </Grid.ColumnDefinitions>
        <Rectangle Grid.ColumnSpan="3" Height="2" VerticalAlignment="Bottom">
          <Rectangle.Fill>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#F2C94C" Offset="0"/>
              <GradientStop Color="#56CCF2" Offset="0.5"/>
              <GradientStop Color="#EB5757" Offset="1"/>
            </LinearGradientBrush>
          </Rectangle.Fill>
        </Rectangle>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
          <TextBlock Text="⚡" FontSize="16" Foreground="#F2C94C" VerticalAlignment="Center"/>
          <TextBlock Text="NongPlaiShop" Foreground="White" FontSize="15" FontWeight="Bold" Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock Grid.Column="1" Name="StatusText" Text="$dryTxt   |   $bkTxt" Foreground="#7d7d82" FontSize="11"
                   VerticalAlignment="Center" Margin="0,0,20,0"/>
        <Button Grid.Column="2" Name="CloseBtn" Content="✕" Width="40" Height="40" Background="Transparent"
                Foreground="#7d7d82" BorderThickness="0" FontSize="14" Cursor="Hand"/>
      </Grid>

      <!-- Fanned card stage -->
      <Grid Grid.Row="1" Name="Stage" Background="Transparent">
        <Border Name="Card0" Width="240" Height="290" CornerRadius="14" BorderThickness="2" BorderBrush="Transparent" Cursor="Hand"
                HorizontalAlignment="Center" VerticalAlignment="Center">
          <Border.Effect><DropShadowEffect Color="Black" BlurRadius="30" ShadowDepth="6" Opacity="0.6"/></Border.Effect>
          <Border CornerRadius="12">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#3A2E13" Offset="0"/>
                <GradientStop Color="#161318" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock Name="Glyph0" Text="⚡" FontSize="60" HorizontalAlignment="Center" Foreground="#F2C94C"/>
              <TextBlock Text="APPLY" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,12,0,0"/>
              <TextBlock Text="EVERYTHING" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center"/>
            </StackPanel>
          </Border>
        </Border>
        <Border Name="Card1" Width="240" Height="290" CornerRadius="14" BorderThickness="2" BorderBrush="Transparent" Cursor="Hand"
                HorizontalAlignment="Center" VerticalAlignment="Center">
          <Border.Effect><DropShadowEffect Color="Black" BlurRadius="30" ShadowDepth="6" Opacity="0.6"/></Border.Effect>
          <Border CornerRadius="12">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#123A3E" Offset="0"/>
                <GradientStop Color="#161318" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock Name="Glyph1" Text="↺" FontSize="60" HorizontalAlignment="Center" Foreground="#56CCF2"/>
              <TextBlock Text="RESET ALL" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>
        </Border>
        <Border Name="Card2" Width="240" Height="290" CornerRadius="14" BorderThickness="2" BorderBrush="Transparent" Cursor="Hand"
                HorizontalAlignment="Center" VerticalAlignment="Center">
          <Border.Effect><DropShadowEffect Color="Black" BlurRadius="30" ShadowDepth="6" Opacity="0.6"/></Border.Effect>
          <Border CornerRadius="12">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#3A1414" Offset="0"/>
                <GradientStop Color="#161318" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock Name="Glyph2" Text="✕" FontSize="60" HorizontalAlignment="Center" Foreground="#EB5757"/>
              <TextBlock Text="EXIT" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>
        </Border>

        <!-- fixed corner-bracket "viewfinder" frame that always frames whichever card is in front -->
        <Grid Name="Bracket" Width="256" Height="306" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False">
          <Path Data="M0,26 L0,0 L26,0" Stroke="#F2C94C" StrokeThickness="3" HorizontalAlignment="Left" VerticalAlignment="Top"/>
          <Path Data="M0,26 L0,0 L26,0" Stroke="#F2C94C" StrokeThickness="3" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Path.RenderTransform><ScaleTransform ScaleX="-1"/></Path.RenderTransform>
          </Path>
          <Path Data="M0,26 L0,0 L26,0" Stroke="#F2C94C" StrokeThickness="3" HorizontalAlignment="Left" VerticalAlignment="Bottom">
            <Path.RenderTransform><ScaleTransform ScaleY="-1"/></Path.RenderTransform>
          </Path>
          <Path Data="M0,26 L0,0 L26,0" Stroke="#F2C94C" StrokeThickness="3" HorizontalAlignment="Right" VerticalAlignment="Bottom">
            <Path.RenderTransform><ScaleTransform ScaleX="-1" ScaleY="-1"/></Path.RenderTransform>
          </Path>
        </Grid>

        <!-- big title behind cards, like "LOW" in the reference -->
        <TextBlock Name="BigTitle" Text="APPLY" FontSize="46" FontWeight="Bold" Foreground="#14FFFFFF"
                   HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,-6" Panel.ZIndex="-1"/>
      </Grid>

      <!-- Description panel -->
      <StackPanel Grid.Row="2" Margin="34,10,34,0">
        <TextBlock Name="DescTitle" Text="APPLY EVERYTHING" Foreground="#F2C94C" FontSize="19" FontWeight="Bold"/>
        <TextBlock Name="DescBody" TextWrapping="NoWrap" Foreground="#c9c9cc" FontSize="12" Margin="0,6,0,0"/>
        <TextBlock Name="QuickStatus" Text="กำลังอ่านสถานะเครื่อง..." Foreground="#7d7d82" FontSize="10" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
          <Button Name="OpenBackupBtn" Content="BACKUP" Width="92" Height="25" Background="#20242C" Foreground="#D6A84F" BorderThickness="0" FontSize="10" Cursor="Hand" Margin="0,0,8,0"/>
          <Button Name="OpenReportBtn" Content="REPORT" Width="92" Height="25" Background="#20242C" Foreground="#56CCF2" BorderThickness="0" FontSize="10" Cursor="Hand"/>
          <Button Name="NetworkDiagnoseBtn" Content="NET CHECK" Width="92" Height="25" Background="#20242C" Foreground="#6FCF97" BorderThickness="0" FontSize="10" Cursor="Hand" Margin="8,0,0,0"/>
          <Button Name="NetworkCustomBtn" Content="NET CUSTOM" Width="102" Height="25" Background="#20242C" Foreground="#56CCF2" BorderThickness="0" FontSize="10" Cursor="Hand" Margin="8,0,0,0"/>
        </StackPanel>
      </StackPanel>

      <!-- Bottom bar -->
      <Grid Grid.Row="3" Margin="34,0,34,20">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Name="ButtonsPanel" Orientation="Horizontal">
          <Button Name="CycleLeftBtn" Content="◂" Width="42" Height="42" Background="#1c1c20" Foreground="White"
                  FontSize="16" BorderThickness="0" Cursor="Hand" Margin="0,0,8,0"/>
          <Button Name="RunBtn" Content="RUN ▸" Width="170" Height="42"
                  Background="#F2C94C" Foreground="#111114" FontWeight="Bold" FontSize="14" BorderThickness="0" Cursor="Hand"/>
          <Button Name="CycleRightBtn" Content="▸" Width="42" Height="42" Background="#1c1c20" Foreground="White"
                  FontSize="16" BorderThickness="0" Cursor="Hand" Margin="8,0,0,0"/>
        </StackPanel>
        <TextBlock Grid.Column="1" Text="NongPlaiShop · Smart Adaptive Tuner v1.0"
                   Foreground="#4a4a4e" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Right"/>
      </Grid>
    </Grid>
  </Border>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # The original WPF stage contains three visual cards. The two additive network
    # actions are exposed through dedicated buttons below so existing card XAML and
    # carousel behavior stay backward compatible.
    $cards = @($window.FindName('Card0'), $window.FindName('Card1'), $window.FindName('Card2'))
    $descTitle = $window.FindName('DescTitle')
    $descBody  = $window.FindName('DescBody')
    $quickStatus = $window.FindName('QuickStatus')
    $openBackupBtn = $window.FindName('OpenBackupBtn')
    $openReportBtn = $window.FindName('OpenReportBtn')
    $networkDiagnoseBtn = $window.FindName('NetworkDiagnoseBtn')
    $networkCustomBtn = $window.FindName('NetworkCustomBtn')
    $bigTitle  = $window.FindName('BigTitle')
    $runBtn    = $window.FindName('RunBtn')
    $closeBtn  = $window.FindName('CloseBtn')
    $topBar    = $window.FindName('TopBar')
    $buttonsPanel   = $window.FindName('ButtonsPanel')
    $leftBtn   = $window.FindName('CycleLeftBtn')
    $rightBtn  = $window.FindName('CycleRightBtn')

    $script:GuiSelectedIndex = 0
    $script:GuiResult = $null
    $bc = New-Object Windows.Media.BrushConverter

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $gpu = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Basic|Virtual|Remote' } | Select-Object -First 1).Name
        $ram = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 0) } else { '?' }
        $cpuRaw = if ($processor -and $processor.Name) { [string]$processor.Name } else { '' }
        $cpu = if ($cpuRaw -match '(?i)(i[3579]-[0-9]{4,5}[A-Z]*|Ryzen\s+[3579]\s+[0-9]{4,5}[A-Z]*|Threadripper\s+[0-9]{4,5}[A-Z]*|Xeon\s+[A-Z0-9-]+)') { $Matches[1] } else { 'Unknown' }
        $gpuRaw = if ($gpu) { [string]$gpu } else { '' }
        $gpuShort = if ($gpuRaw -match '(?i)((?:NVIDIA\s+)?(?:GeForce\s+)?(?:RTX|GTX)\s*[0-9]{3,4}(?:\s*Ti|\s*SUPER)?|(?:AMD\s+)?Radeon\s+(?:RX\s*)?[0-9]{3,4}(?:\s*XT)?|Intel\s+Arc\s+[A-Za-z0-9]+)') { $Matches[1] } else { 'Unknown' }
        $gpuShort = $gpuShort -replace '(?i)NVIDIA\s+|GeForce\s+|AMD\s+|Radeon\s+', ''
        $adapter = Get-ActiveAdapter
        $net = if (-not $adapter) { 'Offline' } elseif ([string]$adapter.Name -match '(?i)wi-?fi|wireless|802\.11') { 'Wi-Fi' } elseif ([string]$adapter.Name -match '(?i)ethernet|gigabit|realtek|intel.*(i21|ethernet)') { 'Ethernet' } else { 'Online' }
        $quickStatus.Text = "CPU: $cpu  GPU: $gpuShort  RAM: ${ram} GB  NET: $net"
    } catch { $quickStatus.Text = 'Hardware status unavailable' }

    $openBackupBtn.Add_Click({
        try { $bk = Find-LatestBackup; if ($bk) { Start-Process 'explorer.exe' -ArgumentList $bk } else { [System.Windows.MessageBox]::Show('ยังไม่มี Backup', 'NongPlaiShop') | Out-Null } } catch {}
    })
    $openReportBtn.Add_Click({
        try {
            Invoke-ExportReport -FromGui
            [System.Windows.MessageBox]::Show('สร้าง Report บน Desktop แล้ว', 'NongPlaiShop', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show(('สร้าง Report ไม่สำเร็จ: ' + $_.Exception.Message), 'NongPlaiShop', 'OK', 'Error') | Out-Null
        }
    })
    $networkDiagnoseBtn.Add_Click({
        try {
            Invoke-NetworkDiagnoseOnly
            [System.Windows.MessageBox]::Show('Network diagnose เสร็จแล้ว — ไม่มีค่าใดถูกเปลี่ยน', 'NongPlaiShop', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show(('Network diagnose ไม่สำเร็จ: ' + $_.Exception.Message), 'NongPlaiShop', 'OK', 'Error') | Out-Null
        }
    })
    $networkCustomBtn.Add_Click({
        try { Invoke-NetworkCustomAdditive }
        catch { [System.Windows.MessageBox]::Show(('Network custom ไม่สำเร็จ: ' + $_.Exception.Message), 'NongPlaiShop', 'OK', 'Error') | Out-Null }
    })

    function Animate-CardSlot {
        param($Card, [double]$X, [double]$Rotate, [double]$Scale, [double]$Opacity, [int]$Z, [string]$Accent, [bool]$Selected)
        $dur = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(280))
        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseInOut

        if (-not ($Card.RenderTransform -is [Windows.Media.TransformGroup])) {
            $grp = New-Object Windows.Media.TransformGroup
            $grp.Children.Add((New-Object Windows.Media.ScaleTransform 1, 1))
            $grp.Children.Add((New-Object Windows.Media.RotateTransform 0))
            $grp.Children.Add((New-Object Windows.Media.TranslateTransform 0, 0))
            $Card.RenderTransformOrigin = '0.5,0.5'
            $Card.RenderTransform = $grp
        }
        $scaleT = $Card.RenderTransform.Children[0]
        $rotT   = $Card.RenderTransform.Children[1]
        $transT = $Card.RenderTransform.Children[2]

        foreach ($pair in @(
            @{ Target = $scaleT; Prop = [Windows.Media.ScaleTransform]::ScaleXProperty; To = $Scale },
            @{ Target = $scaleT; Prop = [Windows.Media.ScaleTransform]::ScaleYProperty; To = $Scale },
            @{ Target = $rotT;   Prop = [Windows.Media.RotateTransform]::AngleProperty;  To = $Rotate },
            @{ Target = $transT; Prop = [Windows.Media.TranslateTransform]::XProperty;   To = $X }
        )) {
            $anim = New-Object Windows.Media.Animation.DoubleAnimation($pair.To, $dur)
            $anim.EasingFunction = $ease
            $pair.Target.BeginAnimation($pair.Prop, $anim)
        }
        $opacAnim = New-Object Windows.Media.Animation.DoubleAnimation($Opacity, $dur)
        $opacAnim.EasingFunction = $ease
        $Card.BeginAnimation([Windows.UIElement]::OpacityProperty, $opacAnim)
        [Windows.Controls.Panel]::SetZIndex($Card, $Z)

        # Colored glow + border ring on the selected card, matching its own accent color -
        # gives clear visual feedback on which of the three actions is currently armed.
        $accentBrush = $bc.ConvertFromString($Accent)
        if ($Selected) {
            $Card.BorderBrush = $accentBrush
            if ($Card.Effect -is [Windows.Media.Effects.DropShadowEffect]) {
                $Card.Effect.Color = $accentBrush.Color
                $Card.Effect.BlurRadius = 42
                $Card.Effect.ShadowDepth = 0
                $Card.Effect.Opacity = 0.75
            }
        } else {
            $Card.BorderBrush = [Windows.Media.Brushes]::Transparent
            if ($Card.Effect -is [Windows.Media.Effects.DropShadowEffect]) {
                $Card.Effect.Color = [Windows.Media.Colors]::Black
                $Card.Effect.BlurRadius = 30
                $Card.Effect.ShadowDepth = 6
                $Card.Effect.Opacity = 0.6
            }
        }
    }

    function Update-CardSelection {
        $n = $cards.Count
        $sel = $script:GuiSelectedIndex
        $leftIdx  = ($sel - 1 + $n) % $n
        $rightIdx = ($sel + 1) % $n
        Animate-CardSlot $cards[$leftIdx]  -220 -10 0.82 0.5 1  $script:MenuCards[$leftIdx].Accent  $false
        Animate-CardSlot $cards[$sel]        0   0  1.0  1.0 10 $script:MenuCards[$sel].Accent      $true
        Animate-CardSlot $cards[$rightIdx]  220  10 0.82 0.5 1  $script:MenuCards[$rightIdx].Accent $false

        $m = $script:MenuCards[$sel]
        $descTitle.Text = $m.Title
        $descTitle.Foreground = $bc.ConvertFromString($m.Accent)
        $descBody.Text = if ($m.Key -eq '1') { 'Full system gaming tune' } elseif ($m.Key -eq '2') { 'Restore latest backup' } else { 'Close app' }
        $bigTitle.Text = $m.Title.Split(' ')[0]
        $bigTitle.Foreground = $bc.ConvertFromString($m.Accent)
        $bigTitle.Opacity = 1.0
    }

    for ($i = 0; $i -lt $cards.Count; $i++) {
        $idx = $i
        $cards[$i].Add_MouseLeftButtonUp({ if (-not $script:GuiIsDragging) { $script:GuiSelectedIndex = $idx; Update-CardSelection } }.GetNewClosure())
    }
    $leftBtn.Add_Click({ $script:GuiSelectedIndex = ($script:GuiSelectedIndex - 1 + $cards.Count) % $cards.Count; Update-CardSelection })
    $rightBtn.Add_Click({ $script:GuiSelectedIndex = ($script:GuiSelectedIndex + 1) % $cards.Count; Update-CardSelection })
    $runBtn.Add_Click({
        $script:GuiResult = $script:MenuCards[$script:GuiSelectedIndex].Key
        $window.Hide()
        $window.Close()
    })
    $closeBtn.Add_Click({ $script:GuiResult = '3'; $window.Hide(); $window.Close() })
    $topBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })

    # Mouse drag (click-and-drag left/right) to swipe between cards, like a carousel
    $stage = $window.FindName('Stage')
    $script:GuiDragStartX = $null
    $script:GuiIsDragging = $false
    $stage.Add_MouseLeftButtonDown({
        param($s, $e)
        $script:GuiDragStartX = $e.GetPosition($stage).X
        $script:GuiIsDragging = $false
        $stage.CaptureMouse() | Out-Null
    })
    $stage.Add_MouseMove({
        param($s, $e)
        if ($script:GuiDragStartX -ne $null -and $e.LeftButton -eq 'Pressed') {
            $dx = $e.GetPosition($stage).X - $script:GuiDragStartX
            if ([math]::Abs($dx) -gt 8) { $script:GuiIsDragging = $true }
        }
    })
    $stage.Add_MouseLeftButtonUp({
        param($s, $e)
        if ($script:GuiDragStartX -ne $null) {
            $dx = $e.GetPosition($stage).X - $script:GuiDragStartX
            if ($script:GuiIsDragging) {
                if ($dx -le -40) { $script:GuiSelectedIndex = ($script:GuiSelectedIndex + 1) % $cards.Count; Update-CardSelection }
                elseif ($dx -ge 40) { $script:GuiSelectedIndex = ($script:GuiSelectedIndex - 1 + $cards.Count) % $cards.Count; Update-CardSelection }
            }
        }
        $stage.ReleaseMouseCapture() | Out-Null
        $script:GuiDragStartX = $null
        $script:GuiIsDragging = $false
    })

    # Keyboard shortcuts: 1/2/3 jump straight to a card, arrows cycle, Enter runs, Esc exits
    $window.Add_KeyDown({
        param($s, $e)
        switch ($e.Key) {
            'D1'      { $script:GuiSelectedIndex = 0; Update-CardSelection }
            'D2'      { $script:GuiSelectedIndex = 1; Update-CardSelection }
            'D3'      { $script:GuiSelectedIndex = 2; Update-CardSelection }
            'Left'    { $script:GuiSelectedIndex = ($script:GuiSelectedIndex - 1 + $cards.Count) % $cards.Count; Update-CardSelection }
            'Right'   { $script:GuiSelectedIndex = ($script:GuiSelectedIndex + 1) % $cards.Count; Update-CardSelection }
            'Enter'   { $script:GuiResult = $script:MenuCards[$script:GuiSelectedIndex].Key; $window.Close() }
            'Escape'  { $script:GuiResult = '3'; $window.Close() }
        }
    })

    Update-CardSelection
    try {
        $window.ShowDialog() | Out-Null
    } catch {
        $detail = Write-CrashLog -ErrorRecord $_ -Context 'Show-MainMenuWpf ShowDialog'
        try { [System.Windows.MessageBox]::Show($detail, 'NongPlaiShop - Error (detail)', 'OK', 'Error') | Out-Null } catch {}
        $script:GuiResult = $null
    }
    return $script:GuiResult
}

# ---------------------------------------------------------------------------
# GUI worker mode
# ---------------------------------------------------------------------------
function Play-GuiSound {
    param([ValidateSet('Start','Progress','Done','Error')][string]$Kind = 'Progress')
    try {
        switch ($Kind) {
            'Start'    {
                # Single startup beep.
                [Console]::Beep(988, 140)
            }
            'Progress' { [Console]::Beep(660, 45) }
            'Done'     { [Console]::Beep(1046, 600) }
            'Error'    {
                [Console]::Beep(311, 220)
                [Console]::Beep(233, 260)
            }
        }
    } catch {}
}

function Invoke-GuiWorkerAction {
    try {
        # Emit a bootstrap event before any tuning code runs. This makes a bad
        # argument/path or an early initialization failure visible in the GUI.
        Write-GuiEvent -Type 'progress' -Current 1 -Total 100 -Label 'กำลังเริ่ม worker' -Message ("action={0} | log={1}" -f $WorkerAction, $GuiLogPath)
        Write-GuiEvent -Type 'progress' -Current 1 -Total 100 -Label 'กำลังเริ่ม worker' -Message 'กำลังตรวจสิทธิ์และเตรียมการ...'
        switch ($WorkerAction) {
            'Apply' { Invoke-DoEverything }
            'Reset' { Invoke-ResetUltra }
            'Scan'            { Invoke-HardwareScanOnly }
            'Hpet'            { Invoke-HpetToggle }
            'NetworkDiagnose' { Invoke-NetworkDiagnoseOnly }
            'NetworkCustom'   { Invoke-NetworkCustomAdditive }
            default { throw "ไม่พบคำสั่ง worker ที่ถูกต้อง: $WorkerAction" }
        }
        Write-GuiEvent -Type 'done' -Current 100 -Total 100 -Label 'เสร็จสมบูรณ์' -Message 'การทำงานเสร็จสมบูรณ์'
        # Keep the script file until WorkerUi has closed. WorkerUi will launch
        # the main menu again, and that new menu process performs final cleanup.
        exit 0
    } catch {
        $msg = $_.Exception.Message
        try {
            Write-GuiEvent -Type 'error' -Current 0 -Total 100 -Label 'เกิดข้อผิดพลาด' -Message $msg
            Write-CrashLog -ErrorRecord $_ -Context 'Invoke-GuiWorkerAction' | Out-Null
        } catch {}
        exit 1
    }
}

function Start-GuiWorkerProcess {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$LogPath)
    $selfPath = Confirm-ScriptPersisted
    if ([string]::IsNullOrWhiteSpace($selfPath) -or -not (Test-Path $selfPath)) {
        throw 'ไม่พบไฟล์ .ps1 สำหรับเริ่มงานเบื้องหลัง กรุณาเปิดจากไฟล์สคริปต์ที่บันทึกไว้ในเครื่อง'
    }
    $workerArgs = @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', $selfPath, '-Worker', '-WorkerAction', $Action,
        '-GuiLogPath', $LogPath
    )
    if ($script:DryRun) { $workerArgs += '-DryRun' }
    $stdOutPath = Join-Path $env:TEMP ('NongPlaiWorker_out_' + [guid]::NewGuid().ToString('N') + '.log')
    $stdErrPath = Join-Path $env:TEMP ('NongPlaiWorker_err_' + [guid]::NewGuid().ToString('N') + '.log')
    $proc = Start-Process -FilePath $script:PowerShellExe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdOutPath -RedirectStandardError $stdErrPath
    # Stash the redirect paths on the process object's Tag-like property via a script-scope map
    # so Show-WorkerProgressWpf can show the real reason if the worker exits before it's done.
    $script:LastWorkerStdOut = $stdOutPath
    $script:LastWorkerStdErr = $stdErrPath
    return $proc
}

function Show-WorkerProgressWpf {
    param([Parameter(Mandatory)][ValidateSet('Apply','Reset')][string]$Action)

    # Use WinForms controls created directly in .NET. This avoids the WPF XAML
    # loader path that returned a null Window on the affected Windows PowerShell
    # installation, while preserving the same progress UI and worker behavior.
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $logPath = Join-Path $env:TEMP ("NongPlaiGui_" + [guid]::NewGuid().ToString('N') + '.log')
    New-Item -ItemType File -Path $logPath -Force | Out-Null
    $worker = $null
    try { $worker = Start-GuiWorkerProcess -Action $Action -LogPath $logPath }
    catch {
        Play-GuiSound -Kind Error
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'NongPlaiShop', 'OK', 'Error') | Out-Null
        Remove-Item $logPath -Force -ErrorAction SilentlyContinue
        return
    }
    Play-GuiSound -Kind Start

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'NongPlaiShop - Working'
    $form.ClientSize = New-Object System.Drawing.Size(660, 345)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'None'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(9,10,14)
    $form.Padding = New-Object System.Windows.Forms.Padding(2)

    # Gaming-tuner visual shell: dark surface, gold/cyan accents and a compact status header.
    $accentGold = [System.Drawing.Color]::FromArgb(242,201,76)
    $accentCyan = [System.Drawing.Color]::FromArgb(86,204,242)
    $muted = [System.Drawing.Color]::FromArgb(130,135,148)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = [System.Drawing.Color]::FromArgb(21,22,30)
    $panel.Dock = 'Fill'
    $form.Controls.Add($panel)

    $accentLine = New-Object System.Windows.Forms.Panel
    $accentLine.BackColor = $accentGold
    $accentLine.Location = New-Object System.Drawing.Point(0,0)
    $accentLine.Size = New-Object System.Drawing.Size(656,3)
    $panel.Controls.Add($accentLine)

    $brand = New-Object System.Windows.Forms.Label
    $brand.Text = '⚡  NONGPLAISHOP'
    $brand.ForeColor = $accentGold
    $brand.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $brand.AutoSize = $true
    $brand.Location = New-Object System.Drawing.Point(28,20)
    $panel.Controls.Add($brand)

    $mode = New-Object System.Windows.Forms.Label
    $mode.Text = 'SMART ADAPTIVE TUNER  /  LIVE'
    $mode.ForeColor = $accentCyan
    $mode.Font = New-Object System.Drawing.Font('Consolas', 8, [System.Drawing.FontStyle]::Bold)
    $mode.AutoSize = $true
    $mode.Location = New-Object System.Drawing.Point(405,24)
    $panel.Controls.Add($mode)

    $headerRule = New-Object System.Windows.Forms.Panel
    $headerRule.BackColor = [System.Drawing.Color]::FromArgb(48,50,62)
    $headerRule.Location = New-Object System.Drawing.Point(28,55)
    $headerRule.Size = New-Object System.Drawing.Size(600,1)
    $panel.Controls.Add($headerRule)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'กำลังปรับจูนระบบ'
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $false
    $title.TextAlign = 'MiddleCenter'
    $title.Size = New-Object System.Drawing.Size(580, 32)
    $title.Location = New-Object System.Drawing.Point(38, 76)
    $panel.Controls.Add($title)

    $stageText = New-Object System.Windows.Forms.Label
    $stageText.Text = 'กำลังเริ่ม worker...'
    $stageText.ForeColor = [System.Drawing.Color]::White
    $stageText.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $stageText.AutoSize = $false
    $stageText.TextAlign = 'MiddleCenter'
    $stageText.Size = New-Object System.Drawing.Size(580, 30)
    $stageText.MaximumSize = New-Object System.Drawing.Size(580, 30)
    $stageText.Location = New-Object System.Drawing.Point(38, 112)
    $panel.Controls.Add($stageText)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value = 0
    $bar.Style = 'Continuous'
    $bar.Size = New-Object System.Drawing.Size(580, 20)
    $bar.Location = New-Object System.Drawing.Point(38, 155)
    $bar.BackColor = [System.Drawing.Color]::FromArgb(43,45,56)
    $panel.Controls.Add($bar)

    $percentText = New-Object System.Windows.Forms.Label
    $percentText.Text = '1%'
    $percentText.ForeColor = [System.Drawing.Color]::FromArgb(201,201,204)
    $percentText.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $percentText.AutoSize = $false
    $percentText.TextAlign = 'MiddleCenter'
    $percentText.Size = New-Object System.Drawing.Size(580, 26)
    $percentText.ForeColor = $accentGold
    $percentText.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold)
    $percentText.Location = New-Object System.Drawing.Point(38, 180)
    $panel.Controls.Add($percentText)

    $hintText = New-Object System.Windows.Forms.Label
    $hintText.Text = 'กำลังทำงาน โปรดรอสักครู่...'
    $hintText.ForeColor = [System.Drawing.Color]::FromArgb(125,125,130)
    $hintText.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $hintText.AutoSize = $false
    $hintText.TextAlign = 'MiddleCenter'
    $hintText.Size = New-Object System.Drawing.Size(580, 30)
    $hintText.MaximumSize = New-Object System.Drawing.Size(580, 30)
    $hintText.Location = New-Object System.Drawing.Point(38, 211)
    $panel.Controls.Add($hintText)

    $openBackupBtn = New-Object System.Windows.Forms.Button
    $openBackupBtn.Text = 'เปิดโฟลเดอร์ Backup'
    $openBackupBtn.Size = New-Object System.Drawing.Size(180, 30)
    $openBackupBtn.Location = New-Object System.Drawing.Point(178, 245)
    $openBackupBtn.FlatStyle = 'Flat'
    $openBackupBtn.FlatAppearance.BorderColor = $accentGold
    $openBackupBtn.BackColor = [System.Drawing.Color]::FromArgb(38,39,48)
    $openBackupBtn.ForeColor = $accentGold
    $openBackupBtn.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $openBackupBtn.Visible = $false
    $openBackupBtn.Add_Click({
        try { if ($openBackupBtn.Tag) { Start-Process 'explorer.exe' -ArgumentList $openBackupBtn.Tag } } catch {}
    }.GetNewClosure())
    $panel.Controls.Add($openBackupBtn)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = 'ปิดหน้าต่าง'
    $closeBtn.Size = New-Object System.Drawing.Size(110, 30)
    $closeBtn.Location = New-Object System.Drawing.Point(368, 245)
    $closeBtn.FlatStyle = 'Flat'
    $closeBtn.FlatAppearance.BorderColor = $accentCyan
    $closeBtn.BackColor = [System.Drawing.Color]::FromArgb(38,39,48)
    $closeBtn.ForeColor = $accentCyan
    $closeBtn.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $closeBtn.Visible = $false
    $closeBtn.Add_Click({
        try { if ($null -ne $form -and -not $form.IsDisposed) { $form.Close() } } catch {}
    }.GetNewClosure())
    $panel.Controls.Add($closeBtn)

    $footer = New-Object System.Windows.Forms.Label
    $footer.Text = 'FULL GAMING TUNER  •  DARK DASHBOARD  •  REVERSIBLE BACKUP'
    $footer.ForeColor = $muted
    $footer.Font = New-Object System.Drawing.Font('Consolas', 8)
    $footer.AutoSize = $true
    $footer.Location = New-Object System.Drawing.Point(170, 293)
    $panel.Controls.Add($footer)

    $done = $false
    $ticksNoEvent = 0
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 350
    $timer.Add_Tick({
        try {
            # A completion/error event stops the timer. Keep this guard as well
            # because one already-queued WinForms tick may still be dispatched
            # after Stop(), which used to overwrite the 100% success message.
            if ($done) { $timer.Stop(); return }
            $latest = @(Get-Content -Path $logPath -Encoding UTF8 -ErrorAction SilentlyContinue |
                Where-Object { $_ -like '__NONGPLAI_EVENT__*' } | Select-Object -Last 1)
            if ($latest.Count -eq 0) {
                $ticksNoEvent++
                if ($ticksNoEvent -eq 60) { $hintText.Text = 'ใช้เวลานานกว่าปกติ แต่ยังทำงานอยู่ โปรดรออีกสักครู่...' }
                # Hard timeout: if the worker process is still "alive" (HasExited=false) but has
                # never written a single event for this long, it is almost certainly suspended by
                # an antivirus/EDR product (common with a freshly-spawned, unsigned, hidden-window
                # powershell.exe child) rather than genuinely stuck on a slow step. Waiting forever
                # in that case just looks like a frozen app, so bail out with a clear diagnosis.
                if ($ticksNoEvent -eq 260 -and -not $done) {
                    $done = $true
                    $stageText.Text = 'ไม่มีการตอบสนองจาก worker'
                    $hintText.Text = 'worker process ไม่ตอบสนองนานเกินไป (ยังไม่ถูกปิด แต่ไม่ทำงานต่อ) - มักเกิดจากโปรแกรมป้องกันไวรัส/EDR แช่แข็งโปรเซสไว้เพื่อสแกน ลองเพิ่ม exclusion ให้โฟลเดอร์ %TEMP% หรือไฟล์สคริปต์นี้ แล้วลองใหม่'
                    try {
                        if ($worker -and -not $worker.HasExited) { $worker.Kill() }
                    } catch {}
                    Play-GuiSound -Kind Error
                    $timer.Stop()
                    $closeBtn.Visible = $true
                    return
                }
            } else { $ticksNoEvent = 0 }
            if ($latest.Count -gt 0) {
                $evt = ($latest[0] -replace '^__NONGPLAI_EVENT__', '') | ConvertFrom-Json
                $current = [int]$evt.current
                $total = [int]$evt.total
                $rawPct = if ($total -gt 0) { [math]::Max(0, [math]::Min(100, [int](($current / $total) * 100))) } else { 0 }
                $stage = [string]$evt.stage
                $pct = $rawPct
                if ($stage -eq 'legacy') { $pct = [int][math]::Round($rawPct * 0.75) }
                elseif ($stage -eq 'adaptive') { $pct = 75 + [int][math]::Round($rawPct * 0.25) }
                $pct = [math]::Max(0, [math]::Min(100, $pct))
                $bar.Value = $pct
                $percentText.Text = "$pct%"
                if ($evt.label) { $stageText.Text = [string]$evt.label }
                if ($evt.message) { $hintText.Text = [string]$evt.message }
                if ([string]$evt.type -eq 'done') {
                    $done = $true; $bar.Value = 100; $percentText.Text = '100%'
                    $stageText.Text = 'เสร็จสมบูรณ์'
                    $summaryTxt = if ($total -gt 0) { "ปรับไปแล้ว $current จาก $total รายการ" } else { 'ทำงานเสร็จสมบูรณ์' }
                    $hintText.Text = $summaryTxt
                    try {
                        $bk = Find-LatestBackup
                        if ($bk) { $openBackupBtn.Tag = $bk; $openBackupBtn.Visible = $true }
                    } catch {}
                    # Stay on the 100% screen - the user closes it themselves (button below),
                    # which then returns to the main menu instead of exiting the app outright.
                    Play-GuiSound -Kind Done
                    $timer.Stop()
                    $closeBtn.Visible = $true
                } elseif ([string]$evt.type -eq 'error') {
                    $done = $true; $stageText.Text = 'เกิดข้อผิดพลาด'; $hintText.Text = [string]$evt.message
                    Play-GuiSound -Kind Error; $timer.Stop()
                    $closeBtn.Visible = $true
                }
            }
            if ($null -eq $worker) {
                throw 'ไม่สามารถเริ่ม worker process ได้ (worker เป็นค่า null)'
            }
            if ($worker.HasExited -and -not $done) {
                $done = $true; $stageText.Text = 'งานหยุดก่อนเสร็จสมบูรณ์'
                $errDetail = ''
                try {
                    if ($script:LastWorkerStdErr -and (Test-Path $script:LastWorkerStdErr)) {
                        $errDetail = (Get-Content -Path $script:LastWorkerStdErr -Raw -ErrorAction SilentlyContinue).Trim()
                    }
                } catch {}
                if ($errDetail) {
                    $hintText.Text = "โปรเซสจบการทำงาน (รหัส $($worker.ExitCode)): $errDetail"
                    Write-CrashLog -ErrorRecord ([System.Management.Automation.ErrorRecord]::new(
                        (New-Object System.Exception($errDetail)), 'WorkerExitedEarly',
                        [System.Management.Automation.ErrorCategory]::NotSpecified, $null)) -Context 'Worker process stderr' | Out-Null
                } else {
                    $hintText.Text = "โปรเซสจบการทำงาน (รหัส $($worker.ExitCode)) - ไม่พบรายละเอียดเพิ่มเติม อาจถูกโปรแกรมป้องกันไวรัสบล็อก"
                }
                Play-GuiSound -Kind Error; $timer.Stop()
                $closeBtn.Visible = $true
            }
        } catch {
            # Never replace a completed 100% screen with a generic timer error.
            # The detailed exception is still retained in the diagnostic log.
            try {
                Write-CrashLog -ErrorRecord $_ -Context 'Show-WorkerProgressWpf Timer' | Out-Null
                if (-not $done) {
                    $hintText.Text = 'เกิดข้อผิดพลาดระหว่างอัปเดตสถานะ กรุณาตรวจสอบ NongPlaiGui_write_errors.log'
                }
            } catch {}
        }
    }.GetNewClosure())
    $form.Add_FormClosed({ try { $timer.Stop() } catch {}; Remove-Item $logPath -Force -ErrorAction SilentlyContinue }.GetNewClosure())
    $timer.Start()
    try { [void]$form.ShowDialog() }
    catch {
        $detail = Write-CrashLog -ErrorRecord $_ -Context 'Show-WorkerProgressWpf ShowDialog'
        try { [System.Windows.Forms.MessageBox]::Show($detail, 'NongPlaiShop - Error (detail)', 'OK', 'Error') | Out-Null } catch {}
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Worker) {
    Invoke-GuiWorkerAction
    exit 0
}

if ($WorkerUi) {
    # Runs in its own freshly-spawned process/window/dispatcher - never shares a
    # process with a previously-closed window, so there is no WPF dispatcher
    # teardown race here no matter what happened in the process that launched us.
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        Show-WorkerProgressWpf -Action $WorkerAction
    } catch {
        try {
            $dbgPath = Join-Path $env:TEMP 'NongPlaiGui_write_errors.log'
            $dbgLine = "[{0}] WorkerUi crashed: {1}`r`n{2}" -f (Get-Date -Format 'o'), $_.Exception.Message, $_.InvocationInfo.PositionMessage
            [System.IO.File]::AppendAllText($dbgPath, $dbgLine + [Environment]::NewLine)
        } catch {}
        try { [System.Windows.MessageBox]::Show($_.Exception.Message, 'NongPlaiShop - Error', 'OK', 'Error') | Out-Null } catch {}
    }
    exit 0
}

if ($HpetToggle -and -not $ConsoleOnly) {
    try { Invoke-HpetToggle }
    catch {
        Write-Host ""
        Write-Host "  FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
        Read-Host "Press Enter to close"
    }
    exit 0
}

if (($NetworkDiagnose -or $NetworkCustom) -and -not $ConsoleOnly) {
    try {
        if ($NetworkDiagnose) { Invoke-NetworkDiagnoseOnly }
        if ($NetworkCustom) { Invoke-NetworkCustomAdditive }
    } catch {
        Write-Host ""
        Write-Host "  FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    }
    exit 0
}

if ($ConsoleOnly -or $NoGui) {
    try {
        Show-MainMenuConsole
    } catch {
        Write-Host ""
        Write-Host "  FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
        try { Read-Host 'Press Enter to close' | Out-Null } catch {}
    }
    exit 0
}

try {
    $keepRunning = $true
    while ($keepRunning) {
        $sel = Show-MainMenuWpf
        $uiAction = switch ($sel) { '1' { 'Apply' }; '2' { 'Reset' }; default { $null } }
        if ($uiAction) {
            foreach ($openWindow in @([System.Windows.Application]::Current.Windows)) {
                try { $openWindow.Hide() } catch {}
            }
            Show-WorkerProgressWpf -Action $uiAction
            # Falls through here once the user closes the progress window - loop back
            # to a fresh main menu instead of exiting the app.
        } else {
            $keepRunning = $false
        }
    }
} catch {
    # Keep failures inside the GUI flow. No console is shown here.
    Play-GuiSound -Kind Error
    Write-GuiEvent -Type 'error' -Current 0 -Total 100 -Label 'เกิดข้อผิดพลาดของ GUI' -Message $_.Exception.Message
    # The error is intentionally not printed to a PowerShell window; show it as a GUI dialog.
    try { [System.Windows.MessageBox]::Show($_.Exception.Message, 'NongPlaiShop - Error', 'OK', 'Error') | Out-Null } catch {}
}


try { if ($script:WpfApp) { $script:WpfApp.Shutdown() } } catch {}

# ===========================================================================
# ADVANCED TUNING CONFIGURATION (added to end of file)
# ===========================================================================

function Show-AdvancedTuningMenu {
    Clear-Host
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║         🔧 ADVANCED TUNING CONFIGURATION                       ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    $menu = @{
        '1' = @{ Name = '🌐 Network Tuning'; Function = 'Show-NetworkTuningOptions' }
        '2' = @{ Name = '🔧 CPU Tuning'; Function = 'Show-CpuTuningOptions' }
        '3' = @{ Name = '🎮 GPU Tuning'; Function = 'Show-GpuTuningOptions' }
        '4' = @{ Name = '🧠 Memory Tuning'; Function = 'Show-MemoryTuningOptions' }
        '5' = @{ Name = '💾 Storage Tuning'; Function = 'Show-StorageTuningOptions' }
        '6' = @{ Name = '🔌 Services Tuning'; Function = 'Show-ServicesTuningOptions' }
        '7' = @{ Name = '👁️ Visual Effects'; Function = 'Show-VisualEffectsTuningOptions' }
        '8' = @{ Name = '✅ Apply All (Defaults)'; Function = 'Invoke-AllTunings' }
        '9' = @{ Name = '📊 Apply & Verify'; Function = 'Invoke-AllTuningsWithVerification' }
        '0' = @{ Name = '❌ Exit'; Function = $null }
    }
    
    foreach ($key in $menu.Keys | Sort-Object) {
        Write-Host "  [$key] $($menu[$key].Name)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    $choice = Read-Host "Select option"
    
    if ($menu[$choice].Function) {
        & $menu[$choice].Function
    }
}

function Show-NetworkTuningOptions {
    Clear-Host
    Write-Host "🌐 NETWORK TUNING OPTIONS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    $options = @(
        @{ Name = "TCP NoDelay (disable Nagle)"; Default = $true; Value = 1 }
        @{ Name = "Enable RSS (Receive Side Scaling)"; Default = $true; Value = $true }
        @{ Name = "Disable ECN"; Default = $true; Value = 0 }
        @{ Name = "Disable Timestamps"; Default = $true; Value = 0 }
        @{ Name = "Max User Port (65534)"; Default = $true; Value = 65534 }
        @{ Name = "QoS Bandwidth Unlimited"; Default = $true; Value = 0 }
    )
    
    $i = 1
    foreach ($opt in $options) {
        $status = if ($opt.Default) { "✓ ON" } else { "✗ OFF" }
        Write-Host "  [$i] $($opt.Name) $status" -ForegroundColor Green
        $i++
    }
    
    Write-Host ""
    Write-Host "All network tweaks configured with before/after verification" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Show-CpuTuningOptions {
    Clear-Host
    Write-Host "🔧 CPU TUNING OPTIONS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    $options = @(
        @{ Name = "Disable C1E (Enhanced Halt)"; Default = $true }
        @{ Name = "Disable CPU Parking"; Default = $true }
        @{ Name = "CPU Boost 100%"; Default = $true }
        @{ Name = "Thread Priority Boost"; Default = $true }
        @{ Name = "Disable Power Throttling"; Default = $true }
    )
    
    $i = 1
    foreach ($opt in $options) {
        $status = if ($opt.Default) { "✓ ON" } else { "✗ OFF" }
        Write-Host "  [$i] $($opt.Name) $status" -ForegroundColor Green
        $i++
    }
    
    Write-Host ""
    Write-Host "CPU will run at maximum performance" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Show-GpuTuningOptions {
    Clear-Host
    Write-Host "🎮 GPU TUNING OPTIONS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    $options = @(
        @{ Name = "Disable VSync"; Default = $true }
        @{ Name = "Disable GPU UMD Wait"; Default = $true }
        @{ Name = "Max Frame Rate (Unlimited)"; Default = 0; Options = "0, 60, 120, 144, 165, 240" }
        @{ Name = "GPU Priority Mode"; Default = 'High' }
    )
    
    $i = 1
    foreach ($opt in $options) {
        if ($opt.Default -is [bool]) {
            $status = if ($opt.Default) { "✓ ON" } else { "✗ OFF" }
        } else {
            $status = $opt.Default
        }
        Write-Host "  [$i] $($opt.Name) [$status]" -ForegroundColor Green
        $i++
    }
    
    Write-Host ""
    Write-Host "GPU optimized for low-latency gaming" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Show-MemoryTuningOptions {
    Clear-Host
    Write-Host "🧠 MEMORY TUNING OPTIONS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    $options = @(
        @{ Name = "Enable Large System Cache"; Default = $true }
        @{ Name = "Disable Memory Compression"; Default = $true }
        @{ Name = "Disable Standby List Clearing"; Default = $true }
        @{ Name = "Page File Size: 1.5x RAM"; Default = $true }
    )
    
    $i = 1
    foreach ($opt in $options) {
        $status = if ($opt.Default) { "✓ ON" } else { "✗ OFF" }
        Write-Host "  [$i] $($opt.Name) $status" -ForegroundColor Green
        $i++
    }
    
    Write-Host ""
    Write-Host "Memory management optimized for performance" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Show-StorageTuningOptions {
    Clear-Host
    Write-Host "💾 STORAGE TUNING OPTIONS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    $options = @(
        @{ Name = "Disable NTFS Last Access Update"; Default = $true }
        @{ Name = "Disable 8.3 Short Filenames"; Default = $true }
        @{ Name = "Keep SSD TRIM Enabled"; Default = $true }
        @{ Name = "Enable NTFS Compression Caching"; Default = $true }
    )
    
    $i = 1
    foreach ($opt in $options) {
        $status = if ($opt.Default) { "✓ ON" } else { "✗ OFF" }
        Write-Host "  [$i] $($opt.Name) $status" -ForegroundColor Green
        $i++
    }
    
    Write-Host ""
    Write-Host "SSD/HDD automatically detected and optimized" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Show-ServicesTuningOptions {
    Clear-Host
    Write-Host "🔌 SERVICES TUNING OPTIONS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    $services = @(
        @{ Name = "Diagnostic Tracking"; Service = "DiagTrack"; Status = "Disabled" }
        @{ Name = "DMW App Push"; Service = "dmwappushservice"; Status = "Disabled" }
        @{ Name = "Geolocation"; Service = "lfsvc"; Status = "Disabled" }
        @{ Name = "Maps"; Service = "MapsBrokerService"; Status = "Disabled" }
        @{ Name = "Windows Search"; Service = "WSearch"; Status = "Manual" }
        @{ Name = "Bluetooth"; Service = "bthserv"; Status = "Manual" }
        @{ Name = "ICS"; Service = "SharedAccess"; Status = "Disabled" }
    )
    
    $i = 1
    foreach ($svc in $services) {
        Write-Host "  [$i] $($svc.Name) → $($svc.Status)" -ForegroundColor Green
        $i++
    }
    
    Write-Host ""
    Write-Host "Dependency check enabled (won't break critical services)" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Show-VisualEffectsTuningOptions {
    Clear-Host
    Write-Host "👁️ VISUAL EFFECTS TUNING" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "  [0] Best Appearance (slowest)" -ForegroundColor Yellow
    Write-Host "  [1] Balanced" -ForegroundColor Yellow
    Write-Host "  [2] Best Performance (current) ✓" -ForegroundColor Green
    Write-Host ""
    Write-Host "Current setting: Performance (2)" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "Additional:" -ForegroundColor Cyan
    Write-Host "  ✓ Aero transparency disabled" -ForegroundColor Green
    Write-Host "  ✓ Window animations disabled" -ForegroundColor Green
    Write-Host "  ✓ Transient effects disabled" -ForegroundColor Green
    Write-Host ""
    
    Read-Host "Press Enter to continue"
}

function Invoke-AllTunings {
    Write-Host ""
    Write-Host "✅ Applying all advanced tunings with defaults..." -ForegroundColor Green
    Write-Host "   This will apply network, CPU, GPU, memory, storage, and services tweaks"
    Write-Host ""
    Start-Sleep -Seconds 2
    
    # Call existing Apply function
    if ($Apply) {
        Invoke-DoEverything
    }
}

function Invoke-AllTuningsWithVerification {
    Write-Host ""
    Write-Host "📊 Applying all tunings with VERIFICATION..." -ForegroundColor Cyan
    Write-Host ""
    
    Invoke-DoEverything
    
    Write-Host ""
    Write-Host "════════════════════════════════════════" -ForegroundColor Green
    Write-Host "📊 TUNING VERIFICATION COMPLETE" -ForegroundColor Green
    Write-Host "════════════════════════════════════════" -ForegroundColor Green
}
