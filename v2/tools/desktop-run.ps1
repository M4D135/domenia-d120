# Runs a script of this tools folder inside the desktop session of the account when one is open, else directly in this
# SSH session (docs/CAPTURE.md § 11, docs/E2E.md § 7).
#
# Why: with a desktop session of the same account (console, or an interactive task such as DomeniaLive), WebView2 started
# from the SSH session (session 0, elevated) hands its browser process to the explorer of that desktop (session 1), which
# cannot attach to a window of session 0: Domenia stops at startup (0x80070578 or a 60 s timeout). The script then runs in
# that desktop through a one-shot scheduled task (LogonType Interactive, RunLevel Limited, no password stored), its output
# is streamed back here line by line, and the task and its work folder are removed at the end whatever happens. The open
# session itself is never touched (no logoff, no restart).
#
#   desktop-run.ps1 -Script capture-vm.ps1 -Arguments @{ Exe = '...'; Clean = $true } [-TimeoutSeconds 1800] [-Session auto]
#
# -Session auto (default): desktop session of this account if there is one, else direct; desktop: required (error if
# none); direct: always in this session. Exit code: the script's, 124 on timeout, 1 if the task ended without a code.
param(
    [Parameter(Mandatory = $true)] [string]$Script,
    [hashtable]$Arguments = @{},
    [int]$TimeoutSeconds = 1800,
    [ValidateSet('auto', 'direct', 'desktop')] [string]$Session = 'auto'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Through SSH the console keeps the OEM code page: UTF-8 keeps the accents readable.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    Write-Warning ('Encodage UTF-8 de la console non appliqué : ' + $_.Exception.GetType().Name + '.')
}

function Say([string]$text) { [Console]::Out.WriteLine($text) }

# Only a script of this folder, and plain values (text, number, switch): nothing else reaches the generated wrapper.
if ($Script -cnotmatch '^[a-z0-9][a-z0-9-]{0,40}\.ps1$') { throw 'Script invalide : nom dʼun script du dossier tools seulement.' }
$scriptPath = Join-Path $PSScriptRoot $Script
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Script introuvable : $scriptPath" }
foreach ($key in @($Arguments.Keys)) {
    if ([string]$key -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,40}$') { throw "Paramètre invalide : $key" }
    $value = $Arguments[$key]
    if (-not (($value -is [string]) -or ($value -is [bool]) -or ($value -is [int]))) { throw "Valeur invalide pour -$key (texte, nombre ou interrupteur)." }
    # Control characters and the typographic quotes PowerShell reads as quote marks are refused outright.
    if (($value -is [string]) -and ($value -match '[\x00-\x1F\u2018-\u201B]')) { throw "Valeur invalide pour -$key (caractère non admis)." }
}
if (($TimeoutSeconds -lt 30) -or ($TimeoutSeconds -gt 86400)) { throw 'TimeoutSeconds : de 30 à 86400.' }

$root = Split-Path -Parent $PSScriptRoot
$lot = ''
if ($root -match '^C:\\DomeniaDev\\src\\([a-z0-9][a-z0-9-]{0,39})\\v2$') { $lot = $Matches[1] }
$tasks = 'C:\DomeniaDev\tasks'
$prefix = 'Domenia-vmsh-'

# Desktop session of this account: an explorer.exe outside session 0 owned by the same SID (language independent).
function Get-DesktopSessionId {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'")) {
        if ([int]$process.SessionId -eq 0) { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
        if (($owner.ReturnValue -eq 0) -and ($owner.Sid -eq $me)) { return [int]$process.SessionId }
    }
    return $null
}

function Format-Literal([string]$text) { return "'" + $text.Replace("'", "''") + "'" }

# New complete lines of the task output since $from (a UTF-8 character is never cut); returns the new offset.
function Write-NewOutput([string]$path, [long]$from) {
    if (-not (Test-Path -LiteralPath $path)) { return $from }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $length = $stream.Length
        if ($length -le $from) { return $from }
        $stream.Position = $from
        $buffer = New-Object byte[] ([int]($length - $from))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $from }
        $last = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($last -lt 0) { return $from }
        [Console]::Out.Write([Text.Encoding]::UTF8.GetString($buffer, 0, $last + 1))
        return $from + $last + 1
    } finally {
        $stream.Dispose()
    }
}

# Last resort after a timeout: processes started from this lot only (sources or pack), never anything else.
function Stop-LotProcesses {
    if (-not $lot) { return }
    $prefixes = @("C:\DomeniaDev\src\$lot\", "C:\DomeniaDev\out\$lot\")
    $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Domenia.exe' OR Name = 'Domenia.E2E.exe' OR Name = 'msedgewebview2.exe'")
    foreach ($process in $all) {
        $path = [string]$process.ExecutablePath
        if (-not $path) { continue }
        foreach ($p in $prefixes) {
            if ($path.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
                Say ("Arrêt de $($process.Name) (processus $($process.ProcessId)).")
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
}

$desktop = $null
$own = (Get-Process -Id $PID).SessionId
if (($Session -ne 'direct') -and ($own -eq 0)) { $desktop = Get-DesktopSessionId }
if (($Session -eq 'desktop') -and ($null -eq $desktop)) { throw 'Aucune session de bureau ouverte pour ce compte : -Session desktop impossible.' }

if ($null -eq $desktop) {
    if ($own -eq 0) { Say "Aucune session de bureau pour ce compte : $Script sʼexécute directement dans la session SSH." }
    $global:LASTEXITCODE = 0
    & $scriptPath @Arguments
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- one-shot interactive task

# Leftovers of a run stopped abruptly (vm.sh holds the exclusive VM lock: none of them can still be in use).
foreach ($old in @(Get-ScheduledTask -TaskName ($prefix + '*') -ErrorAction SilentlyContinue)) {
    Say "Ancienne tâche retirée : $($old.TaskName)."
    Stop-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $tasks) {
    Get-ChildItem -LiteralPath $tasks -Directory -Filter ($prefix + '*') | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

$label = if ($lot) { $lot } else { 'v2' }
$taskName = $prefix + $label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path $tasks $taskName
New-Item -ItemType Directory -Force -Path $work | Out-Null
$log = Join-Path $work 'output.log'
$done = Join-Path $work 'exit-code.txt'
$wrapper = Join-Path $work 'run.ps1'

$call = '& ' + (Format-Literal $scriptPath)
foreach ($key in @($Arguments.Keys | Sort-Object)) {
    $value = $Arguments[$key]
    if ($value -is [bool]) {
        if ($value) { $call += " -$key" }
    } elseif ($value -is [int]) {
        $call += " -$key $value"
    } else {
        $call += " -$key " + (Format-Literal $value)
    }
}
# The wrapper runs in the desktop session: every stream of the script goes to output.log (UTF-8), the exit code last.
$template = @'
# One-shot wrapper written by tools/desktop-run.ps1 (Domenia), removed with its task.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8 } catch { [IO.File]::AppendAllText(__LOG__, "Encodage UTF-8 de la console non appliqué.`r`n", $utf8) }
$code = 1
try {
    $global:LASTEXITCODE = 0
    __CALL__ *>&1 | ForEach-Object { [IO.File]::AppendAllText(__LOG__, (($_ | Out-String).TrimEnd("`r", "`n") + "`r`n"), $utf8) }
    $code = $LASTEXITCODE
    if ($code -isnot [int]) { $code = 0 }
} catch {
    [IO.File]::AppendAllText(__LOG__, ('Erreur : ' + $_.Exception.Message + "`r`n"), $utf8)
    $code = 1
}
# Written aside then renamed: the waiting side never reads a half-written code.
[IO.File]::WriteAllText((__DONE__ + '.tmp'), [string]$code, $utf8)
[IO.File]::Move((__DONE__ + '.tmp'), __DONE__)
exit $code
'@
$text = $template.Replace('__LOG__', (Format-Literal $log)).Replace('__DONE__', (Format-Literal $done)).Replace('__CALL__', $call)
# With a byte order mark: Windows PowerShell 5.1 would read the accents as ANSI otherwise.
[IO.File]::WriteAllText($wrapper, $text, (New-Object System.Text.UTF8Encoding $true))

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $wrapper) -WorkingDirectory $PSScriptRoot
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
# Normal priority (a task gets « below normal » by default, which Domenia and WebView2 would inherit).
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Priority 4 -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 300))
$code = 1
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'Tâche ponctuelle de tools/desktop-run.ps1 (Domenia) : retirée à la fin de son exécution.' -Force | Out-Null
    Say "Session de bureau n° $desktop ouverte pour $user : $Script sʼexécute dans cette session (tâche ponctuelle $taskName, sans élévation)."
    Start-ScheduledTask -TaskName $taskName
    $offset = [long]0
    $started = Get-Date
    $endedAt = $null
    while ($true) {
        $offset = Write-NewOutput $log $offset
        if (Test-Path -LiteralPath $done) {
            Start-Sleep -Milliseconds 300
            $offset = Write-NewOutput $log $offset
            $written = [IO.File]::ReadAllText($done).Trim()
            if ($written -match '^-?[0-9]{1,10}$') { $code = [int]$written } else { Say "Code de sortie illisible : $written"; $code = 1 }
            break
        }
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        # 267009: running; 267011: not run yet. Any other result without exit-code.txt: the wrapper never ran or died.
        if (($null -ne $task) -and ($task.State -ne 'Running') -and ($null -ne $info) -and ($info.LastTaskResult -ne 267009) -and ($info.LastTaskResult -ne 267011)) {
            if ($null -eq $endedAt) { $endedAt = Get-Date }
            elseif (((Get-Date) - $endedAt).TotalSeconds -gt 3) {
                $offset = Write-NewOutput $log $offset
                Say ('La tâche sʼest terminée sans code de sortie (résultat 0x{0:X8}).' -f [int64]$info.LastTaskResult)
                $code = 1
                break
            }
        }
        if (((Get-Date) - $started).TotalSeconds -gt $TimeoutSeconds) {
            Say "Délai de $TimeoutSeconds s dépassé : tâche arrêtée."
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Stop-LotProcesses
            $code = 124
            break
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Say "ATTENTION : la tâche $taskName nʼa pas pu être retirée." } else { Say "Tâche $taskName retirée." }
}
exit $code
