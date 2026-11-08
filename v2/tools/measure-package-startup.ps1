# Dot-source in the Windows delivery runner. Only the newly extracted simulation package is launched.
# First/second launch are measured; no reboot, OS cache purge or installed runtime change is performed.
# WebViewRoot is the qualified browser folder the pack must use: the runner's Evergreen engine for PROD-LIGHT.
function Measure-PackageStartup([string]$Package, [string]$Logs, [string]$ArchiveSha256, [string]$Commit, [string]$WebViewRoot) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Mesure réservée au runner Windows jetable de livraison.'
    }
    if (-not $WebViewRoot -or -not (Test-Path -LiteralPath (Join-Path $WebViewRoot 'msedgewebview2.exe') -PathType Leaf)) { throw 'Moteur WebView2 qualifié absent pour la mesure.' }
    if (-not ('DomeniaStartupProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public sealed class DomeniaStartupWindow {
    public IntPtr Handle; public bool Bootstrap; public bool Responsive; public uint Dpi;
}
public static class DomeniaStartupProbe {
    private delegate bool Callback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Callback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    public static DomeniaStartupWindow[] Find(uint process) {
        var result = new List<DomeniaStartupWindow>();
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner != process || !IsWindowVisible(window)) return true;
            // Shell navigation changes the caption to "Accueil — Domenia…"; native classes stay stable.
            var name = new StringBuilder(256); GetClassName(window, name, name.Capacity);
            bool bootstrap = name.ToString().Equals("DomeniaStartup" + process.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal);
            if (!bootstrap && !name.ToString().StartsWith("WindowsForms10.Window.", StringComparison.Ordinal)) return true;
            IntPtr response;
            result.Add(new DomeniaStartupWindow { Handle=window, Bootstrap=bootstrap,
                Responsive=SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 2, 100, out response) != IntPtr.Zero,
                Dpi=GetDpiForWindow(window) });
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
'@
    }
    $utf8 = New-Object Text.UTF8Encoding $false
    $journal = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Domenia\logs\domenia.log'
    $profile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Domenia\WebView2-Simulation'
    $results = @()
    foreach ($pass in @('premier-lancement', 'second-lancement')) {
        $output = Join-Path $Logs ('startup-' + $pass + '.json')
        if (Test-Path -LiteralPath $output) { throw 'Mesure antérieure conservée.' }
        $offset = if (Test-Path -LiteralPath $journal) { (Get-Item -LiteralPath $journal).Length } else { 0L }
        $record = [ordered]@{
            format = 'Domenia.PackageStartup/1'; sourceCommit = $Commit; archiveSha256 = $ArchiveSha256; webviewRoot = $WebViewRoot
            pass = $pass; profileAlreadyPresent = (Test-Path -LiteralPath $profile); mode = 'simulation-no-auto-connect'
            osCachePurged = $false; coldOsCacheEstablished = $false; firstVisibleMs = $null; mainVisibleMs = $null
            interfaceReadyObservedMs = $null; responsiveSamples = 0; unresponsiveSamples = 0; mainResponsiveSamples = 0; mainUnresponsiveSamples = 0; dpi = $null
            phases = @(); state = 'started'; timedOut = $false; observationErrors = @(); cleanupErrors = @()
            domainConnection = 'not-run'; nativeCredentialEntry = 'not-run'; operatorMachine = 'not-measured'
        }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $Package 'Domenia.exe'; $start.Arguments = '--simulation --no-auto-connect'
        $start.WorkingDirectory = $Package; $start.UseShellExecute = $false
        foreach ($key in @('WEBVIEW2_BROWSER_EXECUTABLE_FOLDER', 'WEBVIEW2_USER_DATA_FOLDER', 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER')) { $start.EnvironmentVariables.Remove($key) }
        $process = New-Object Diagnostics.Process; $process.StartInfo = $start
        $owned = [Collections.Generic.Dictionary[int,object]]::new(); $modules = @{}; $browsers = @{}; $targets = @{}
        $clock = [Diagnostics.Stopwatch]::StartNew(); $failure = $null; $main = $null; $started = $false
        try {
            $started = $process.Start()
            if (-not $started) { throw 'Processus de mesure non lancé.' }
            $root = New-ReleaseOwnedProcess $process $start.FileName $null; $owned.Add($root.processId, $root)
            $record['processCreationMs'] = $clock.ElapsedMilliseconds
            do {
                if ($process.HasExited) { throw ('Processus terminé avant interface utilisable, code ' + $process.ExitCode) }
                foreach ($window in [DomeniaStartupProbe]::Find([uint32]$process.Id)) {
                    if ($null -eq $record.firstVisibleMs) { $record.firstVisibleMs = $clock.ElapsedMilliseconds }
                    if (-not $window.Bootstrap) {
                        if ($null -eq $main) { $main = $window }
                        if ($window.Handle -ne $main.Handle) { continue }
                        if ($null -eq $record.mainVisibleMs) { $record.mainVisibleMs = $clock.ElapsedMilliseconds }
                        if ($window.Responsive) { $record.mainResponsiveSamples++ } else { $record.mainUnresponsiveSamples++ }
                    }
                    $record.dpi = $window.Dpi
                    if ($window.Responsive) { $record.responsiveSamples++ } else { $record.unresponsiveSamples++ }
                }
                if (Test-Path -LiteralPath $journal) {
                    $file = [IO.File]::Open($journal, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    try {
                        if ($file.Length -lt $offset -or $file.Length -gt 16777216) { throw 'Frontière du journal de mesure perdue.' }
                        [void]$file.Seek($offset, [IO.SeekOrigin]::Begin)
                        $reader = New-Object IO.StreamReader($file, $utf8)
                        try { $tail = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    } finally { $file.Dispose() }
                    # The page can acknowledge the interface before WebView2 reports the end of the navigation: both lines
                    # are waited for, so the phase list is complete whatever their order in the journal.
                    if (($tail -match 'Démarrage/InterfaceReady :') -and ($tail -match 'Démarrage/Navigation :')) {
                        $record.interfaceReadyObservedMs = $clock.ElapsedMilliseconds
                        $record.phases = @([regex]::Matches($tail, 'Démarrage/(?<phase>[A-Za-z]+) : (?<duration>[0-9]+) ms ; depuis l.amorçage (?<elapsed>[0-9]+) ms') | ForEach-Object {
                            [ordered]@{ phase = $_.Groups['phase'].Value; durationMs = [long]$_.Groups['duration'].Value; sinceManagedStartupMs = [long]$_.Groups['elapsed'].Value }
                        })
                        break
                    }
                }
                if ($clock.Elapsed.TotalSeconds -ge 180) { $record.timedOut = $true; throw 'Interface non acquittée dans le délai de mesure de 180 secondes.' }
                Start-Sleep -Milliseconds 50
            } while ($true)
            if ($null -eq $main -or $null -eq $record.firstVisibleMs -or $record.responsiveSamples -lt 1) { throw 'Fenêtre visible/réactive non observée.' }
            $usable = @([DomeniaStartupProbe]::Find([uint32]$process.Id) | Where-Object { $_.Handle -eq $main.Handle -and -not $_.Bootstrap -and $_.Responsive })
            if ($usable.Count -lt 1) { throw 'Fenêtre principale non réactive après le jalon interface utilisable.' }
            $record['mainResponsiveAfterReady'] = $true
            foreach ($phase in @('NativeVisible', 'Integrity', 'Composition', 'WebViewEnvironment', 'WebViewControl', 'Navigation', 'InterfaceReady')) {
                if (@($record.phases | Where-Object { $_.phase -ceq $phase }).Count -ne 1) { throw ('Phase mesurée absente ou ambiguë : ' + $phase) }
            }
            Update-ReleaseDescendants $owned $record
            Observe-ReleaseRuntimes $owned $modules $browsers $targets $record (Join-Path $Package 'wad\runtime\dotnet') $WebViewRoot
            Assert-ReleaseRuntimeEvidence $targets $modules $browsers (Join-Path $Package 'wad\runtime\dotnet') $WebViewRoot
            $record.state = 'passed'
        } catch { $failure = $_; $record.state = 'failed'; $record['error'] = $_.Exception.Message }
        finally {
            if ($started -and -not $process.HasExited) {
                try {
                    Update-ReleaseDescendants $owned $record
                    if ($null -ne $main) { [void][DomeniaStartupProbe]::PostMessage($main.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
                    else { [void]$process.CloseMainWindow() }
                    $record['gracefulClose'] = $process.WaitForExit(10000)
                } catch { $record.cleanupErrors += $_.Exception.GetType().Name; if ($null -eq $failure) { $failure = $_ } }
            }
            foreach ($entry in @($owned.Values | Sort-Object depth -Descending)) {
                try {
                    if (-not $entry.process.HasExited -and -not $entry.process.WaitForExit(1000)) {
                        if ($entry.process.StartTime.ToUniversalTime().Ticks -ne $entry.createdTicks) { throw 'Identité du processus modifiée.' }
                        $entry.process.Kill(); if (-not $entry.process.WaitForExit(10000)) { throw 'Fin physique non confirmée.' }
                        $record.cleanupErrors += 'Processus propre arrêté après délai de fermeture.'
                    }
                } catch { $record.cleanupErrors += $_.Exception.Message; if ($null -eq $failure) { $failure = $_ } }
                finally { $entry.process.Dispose() }
            }
            if ($started -and $owned.Count -eq 0) {
                try {
                    if (-not $process.HasExited) { $process.Kill(); if (-not $process.WaitForExit(10000)) { throw 'Processus démarré sans reçu : fin physique non confirmée.' } }
                } catch { $record.cleanupErrors += $_.Exception.Message; if ($null -eq $failure) { $failure = $_ } }
            }
            $record['dotnetModules'] = @($modules.Values | Sort-Object processId, name)
            $record['browserProcesses'] = @($browsers.Values | Sort-Object processId, createdUtc)
            $record['ownedProcesses'] = @($owned.Values | Sort-Object depth, processId | ForEach-Object {
                [ordered]@{ processId = $_.processId; parentProcessId = $_.parentProcessId; path = $_.path; createdUtc = $_.createdUtc; depth = $_.depth }
            })
            $process.Dispose()
            if ($null -ne $failure -or $record.cleanupErrors.Count) { $record.state = 'failed' }
            [IO.File]::WriteAllText($output, ($record | ConvertTo-Json -Depth 8), $utf8)
        }
        $results += [pscustomobject]$record
        if ($null -ne $failure) { throw $failure }
        if ($record.state -cne 'passed') { throw 'Mesure non validée ; consulter son reçu.' }
    }
    return $results
}
