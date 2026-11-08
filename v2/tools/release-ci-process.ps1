# Local process checks of the exact package. No global runtime, service or network change.
function ConvertTo-ReleaseArgument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Get-ReleaseCreationStamp([datetime]$Value) {
    # Win32_Process.CreationDate has microsecond precision; Process.StartTime has 100 ns ticks.
    $ticks = $Value.ToUniversalTime().Ticks
    return ($ticks - ($ticks % 10))
}

function New-ReleaseOwnedProcess([Diagnostics.Process]$Process, [string]$Path, $Parent) {
    # Retain the opened instance handle, not merely its reusable PID.
    [void]$Process.Handle
    $created = $Process.StartTime.ToUniversalTime()
    $parentId = $null; $depth = 0
    if ($null -ne $Parent) { $parentId = $Parent.processId; $depth = $Parent.depth + 1 }
    return [pscustomobject]@{
        process = $Process; processId = $Process.Id; parentProcessId = $parentId
        path = [IO.Path]::GetFullPath($Path); createdUtc = $created.ToString('o'); createdTicks = $created.Ticks
        creationStamp = (Get-ReleaseCreationStamp $created); depth = $depth
        identity = ($Process.Id.ToString() + ':' + $created.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture))
    }
}

function Update-ReleaseDescendants($Owned, $Record) {
    $rows = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop |
        Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate)
    $byId = @{}
    foreach ($row in $rows) { $byId[[int]$row.ProcessId] = $row }
    # Rebuild the live ancestry for every CIM snapshot. A dead parent's PID never admits a new child.
    $active = @{}
    foreach ($entry in @($Owned.Values)) {
        if (-not $byId.ContainsKey($entry.processId)) { continue }
        $row = $byId[$entry.processId]
        if ($null -eq $row.CreationDate -or (Get-ReleaseCreationStamp $row.CreationDate) -ne $entry.creationStamp) { continue }
        $entry.process.Refresh()
        if (-not $entry.process.HasExited) { $active[$entry.processId] = $entry }
    }
    do {
        $added = $false
        foreach ($row in $rows) {
            $id = [int]$row.ProcessId; $parentId = [int]$row.ParentProcessId
            if ($active.ContainsKey($id) -or $Owned.ContainsKey($id) -or -not $active.ContainsKey($parentId) -or $null -eq $row.CreationDate) { continue }
            $parent = $active[$parentId]
            if ((Get-ReleaseCreationStamp $row.CreationDate) -lt $parent.creationStamp) { continue }
            $candidate = $null
            try {
                $candidate = [Diagnostics.Process]::GetProcessById($id)
                [void]$candidate.Handle
                if ($candidate.HasExited) { $candidate.Dispose(); continue }
                $actualPath = $candidate.MainModule.FileName
                $entry = New-ReleaseOwnedProcess $candidate $actualPath $parent
                if ($entry.creationStamp -ne (Get-ReleaseCreationStamp $row.CreationDate) -or $entry.createdTicks -lt $parent.createdTicks) {
                    $candidate.Dispose(); continue
                }
                if ($row.ExecutablePath -and -not [string]::Equals($entry.path, $row.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin du processus différent entre CIM et son handle.' }
                $Owned.Add($id, $entry)
                $active[$id] = $entry
                $candidate = $null # Ownership of this exact handle moved into the ledger.
                $added = $true
            } catch [ArgumentException] {
                # A short-lived child can disappear between the CIM snapshot and OpenProcess.
                if ($null -ne $candidate) { $candidate.Dispose() }
            } catch [InvalidOperationException] {
                if ($null -ne $candidate) { $candidate.Dispose() }
            } catch {
                if ($null -ne $candidate) { $candidate.Dispose() }
                $Record.observationErrors += ('PID ' + $id + ': ' + $_.Exception.GetType().Name)
                throw
            }
        }
    } while ($added)
}

function Observe-ReleaseRuntimes($Owned, $Modules, $Browsers, $Targets, $Record, [string]$DotNetRoot, [string]$WebViewRoot) {
    $netPrefix = $null; $application = $null
    if ($DotNetRoot) {
        $netPrefix = [IO.Path]::GetFullPath($DotNetRoot).TrimEnd('\') + '\'
        $package = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($netPrefix.TrimEnd('\')))
        if ([IO.Path]::GetFileName($package) -ceq 'wad') { $package = [IO.Path]::GetDirectoryName($package) }
        $application = Join-Path $package 'Domenia.exe'
    }
    foreach ($entry in @($Owned.Values)) {
        $name = [IO.Path]::GetFileName($entry.path)
        if ($WebViewRoot -and $name -ieq 'msedgewebview2.exe') {
            $expected = Join-Path ([IO.Path]::GetFullPath($WebViewRoot)) 'msedgewebview2.exe'
            if (-not [string]::Equals($entry.path, $expected, [StringComparison]::OrdinalIgnoreCase)) { throw "Processus WebView2 extérieur au moteur qualifié (PID $($entry.processId))." }
            $Browsers[$entry.identity] = [ordered]@{ processId = $entry.processId; parentProcessId = $entry.parentProcessId; createdUtc = $entry.createdUtc; path = $entry.path }
        }
        # The root may be the private dotnet.exe hosting WebTests/E2E. Also prove each real Domenia child.
        if (-not $DotNetRoot -or ($entry.depth -ne 0 -and $name -ine 'Domenia.exe')) { continue }
        if ($name -ieq 'Domenia.exe' -and -not [string]::Equals($entry.path, $application, [StringComparison]::OrdinalIgnoreCase)) { throw "Un processus Domenia observé provient d'un autre paquet." }
        $Targets[$entry.identity] = $entry
        $observed = @()
        try {
            $entry.process.Refresh()
            if ($entry.process.HasExited) { continue }
            $observed = @($entry.process.Modules | Where-Object { $_.ModuleName -in @('hostfxr.dll', 'coreclr.dll') } |
                ForEach-Object { [ordered]@{ name = $_.ModuleName; path = $_.FileName; processId = $entry.processId; createdUtc = $entry.createdUtc } })
        } catch {
            if (-not $entry.process.HasExited) { $Record.observationErrors += $_.Exception.GetType().Name }
        }
        foreach ($module in $observed) {
            if (-not $module.path.StartsWith($netPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Runtime .NET extérieur au paquet : $($module.path)" }
            $Modules[$entry.identity + '|' + $module.name.ToLowerInvariant()] = $module
        }
    }
}

function Write-ReleaseEvidence($Stream, [string]$Text) {
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush($true)
}

function Assert-ReleaseRuntimeEvidence($Targets, $Modules, $Browsers, [string]$DotNetRoot, [string]$WebViewRoot) {
    if ($DotNetRoot) {
        foreach ($target in $Targets.Values) {
            if (-not $Modules.ContainsKey($target.identity + '|hostfxr.dll') -or -not $Modules.ContainsKey($target.identity + '|coreclr.dll')) {
                throw "Chargement du hostfxr et du CoreCLR privés non observé (PID $($target.processId)) ; autonomie .NET non prouvée."
            }
        }
        if ($Targets.Count -lt 1) { throw 'Aucun hôte .NET privé observé.' }
    }
    if ($WebViewRoot -and $Browsers.Count -lt 1) { throw 'Aucun processus du moteur WebView2 qualifié observé ; démarrage du navigateur non prouvé.' }
}

function Invoke-ReleaseProcess([string]$FilePath, [string[]]$ArgumentList, [string]$LogPrefix,
    [int]$TimeoutSeconds = 120, [int]$ExpectedExitCode = 0, [string]$PrivateDotNetRoot, [string]$PrivateWebViewRoot) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = [IO.Path]::GetFullPath($FilePath)
    $start.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-ReleaseArgument $_ }) -join ' ')
    $start.WorkingDirectory = Split-Path -Parent $start.FileName
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $start.EnvironmentVariables['DOTNET_DISABLE_GUI_ERRORS'] = '1'
    foreach ($key in @('WEBVIEW2_BROWSER_EXECUTABLE_FOLDER', 'WEBVIEW2_USER_DATA_FOLDER', 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER')) { $start.EnvironmentVariables.Remove($key) }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $owned = [Collections.Generic.Dictionary[int,object]]::new()
    $modules = @{}; $browsers = @{}; $targets = @{}
    $record = [ordered]@{ executable = $start.FileName; arguments = $ArgumentList; exitCode = $null; expectedExitCode = $ExpectedExitCode
        dotnetModules = @(); browserProcesses = @(); ownedProcesses = @(); timedOut = $false; observationErrors = @(); cleanupErrors = @(); state = 'failed' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextObservation = 0L; $started = $false; $primary = $null
    $stdout = $null; $stderr = $null; $jsonStream = $null; $outStream = $null; $errorStream = $null
    try {
        # Reserve evidence before starting: a repeated log prefix cannot overwrite a previous proof.
        foreach ($suffix in @('.json', '.stdout.log', '.stderr.log')) {
            if (Test-Path -LiteralPath ($LogPrefix + $suffix)) { throw 'Préfixe de preuves existant conservé ; processus non lancé.' }
        }
        $jsonStream = [IO.File]::Open(($LogPrefix + '.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $outStream = [IO.File]::Open(($LogPrefix + '.stdout.log'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $errorStream = [IO.File]::Open(($LogPrefix + '.stderr.log'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $started = $process.Start()
        if (-not $started) { throw "Le processus de contrôle n'a pas démarré." }
        $record['processId'] = $process.Id
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $root = New-ReleaseOwnedProcess $process $start.FileName $null
        $owned.Add($root.processId, $root)
        do {
            Observe-ReleaseRuntimes $owned $modules $browsers $targets $record $PrivateDotNetRoot $PrivateWebViewRoot
            if ($clock.ElapsedMilliseconds -ge $nextObservation) {
                $nextObservation = $clock.ElapsedMilliseconds + 500
                Update-ReleaseDescendants $owned $record
                Observe-ReleaseRuntimes $owned $modules $browsers $targets $record $PrivateDotNetRoot $PrivateWebViewRoot
            }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds -and -not $process.HasExited) {
                $record.timedOut = $true
                throw "Contrôle du paquet expiré après $TimeoutSeconds secondes."
            }
        } while (-not $process.WaitForExit(40))
        $record.exitCode = $process.ExitCode
        if ($process.ExitCode -ne $ExpectedExitCode) { throw "Contrôle Windows en échec : code $($process.ExitCode), attendu $ExpectedExitCode ; $LogPrefix." }
        Assert-ReleaseRuntimeEvidence $targets $modules $browsers $PrivateDotNetRoot $PrivateWebViewRoot
        $record.state = 'passed'
    } catch {
        $primary = $_
        $record.state = 'failed'; $record['error'] = $_.Exception.Message
    } finally {
        # Discover late descendants only through currently live, already-bound parent instances.
        if ($owned.Count) {
            try {
                Update-ReleaseDescendants $owned $record
                Observe-ReleaseRuntimes $owned $modules $browsers $targets $record $PrivateDotNetRoot $PrivateWebViewRoot
                if ($null -eq $primary) { Assert-ReleaseRuntimeEvidence $targets $modules $browsers $PrivateDotNetRoot $PrivateWebViewRoot }
            }
            catch { $record.cleanupErrors += ('Observation finale : ' + $_.Exception.Message); if ($null -eq $primary) { $primary = $_ } }
        }
        foreach ($entry in @($owned.Values | Sort-Object depth -Descending)) {
            try {
                $entry.process.Refresh()
                if (-not $entry.process.HasExited) {
                    if ($entry.process.StartTime.ToUniversalTime().Ticks -ne $entry.createdTicks) { throw 'Instance de processus différente ; arrêt refusé.' }
                    if (-not $entry.process.WaitForExit(500)) {
                        $entry.process.Kill()
                        if (-not $entry.process.WaitForExit(10000)) { throw "Arrêt physique non confirmé (PID $($entry.processId))." }
                    }
                }
            } catch {
                $record.cleanupErrors += ('PID ' + $entry.processId + ': ' + $_.Exception.Message)
                if ($null -eq $primary) { $primary = $_ }
            }
        }
        # A failed identity capture still owns the Process.Start handle. Never look up a replacement PID.
        if ($started -and $owned.Count -eq 0) {
            try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(10000) } }
            catch { $record.cleanupErrors += $_.Exception.Message; if ($null -eq $primary) { $primary = $_ } }
        }
        foreach ($capture in @(@{ task = $stdout; stream = $outStream; name = 'stdout' }, @{ task = $stderr; stream = $errorStream; name = 'stderr' })) {
            if ($null -eq $capture.task -or $null -eq $capture.stream) { continue }
            try {
                if (-not $capture.task.Wait(10000)) { throw ('Journal ' + $capture.name + ' incomplet après la fin des processus propres.') }
                Write-ReleaseEvidence $capture.stream $capture.task.Result
                # Keep a bounded failure explanation in the run log even if GitHub cannot upload artifacts.
                # These are the controlled qualification processes, not an operator's collection or profile.
                if ($null -ne $primary) {
                    Write-Host ('Échec qualification · ' + [IO.Path]::GetFileName($LogPrefix) + ' · ' + $capture.name)
                    $tail = [string]$capture.task.Result
                    if ($tail.Length -gt 32768) { $tail = $tail.Substring($tail.Length - 32768) }
                    foreach ($line in @($tail -split "\r?\n" | Select-Object -Last 60)) {
                        $safe = $line -replace '(?i)(password|passwd|secret|token|authorization)\s*[:=]\s*\S+', '$1=[masqué]'
                        Write-Host ($safe.Substring(0, [Math]::Min(2048, $safe.Length)))
                    }
                }
            } catch {
                $record.cleanupErrors += $_.Exception.Message
                if ($null -eq $primary) { $primary = $_ }
            }
        }
        foreach ($stream in @($outStream, $errorStream)) {
            if ($null -ne $stream) { try { $stream.Dispose() } catch { if ($null -eq $primary) { $primary = $_ } } }
        }
        foreach ($entry in $owned.Values) { try { $entry.process.Dispose() } catch { if ($null -eq $primary) { $primary = $_ } } }
        try { $process.Dispose() } catch { if ($null -eq $primary) { $primary = $_ } }
        if ($null -ne $primary) { $record.state = 'failed'; $record['error'] = $primary.Exception.Message }
        $record.dotnetModules = @($modules.Values | Sort-Object processId, name)
        $record.browserProcesses = @($browsers.Values | Sort-Object processId, createdUtc)
        $record.ownedProcesses = @($owned.Values | Sort-Object depth, processId | ForEach-Object {
            [ordered]@{ processId = $_.processId; parentProcessId = $_.parentProcessId; createdUtc = $_.createdUtc; path = $_.path; depth = $_.depth }
        })
        $record['elapsedMilliseconds'] = $clock.ElapsedMilliseconds
        if ($null -ne $jsonStream) {
            try { Write-ReleaseEvidence $jsonStream ($record | ConvertTo-Json -Depth 6) }
            catch { if ($null -eq $primary) { $primary = $_ } }
        }
        if ($null -ne $jsonStream) { try { $jsonStream.Dispose() } catch { if ($null -eq $primary) { $primary = $_ } } }
    }
    if ($null -ne $primary) { throw $primary }
    return [pscustomobject]$record
}
