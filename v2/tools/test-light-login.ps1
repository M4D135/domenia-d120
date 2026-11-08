# Windows PowerShell 5.1, in the Windows desktop session. Invokes the offline path of the real UI; with -WindowsIdentity,
# one real directory attempt with the domain session running this script instead (no password typed or passed).
param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ArchiveSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory)][version]$BrowserVersion,
    [Parameter(Mandatory)][string]$Evidence,
    [switch]$WindowsIdentity
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-ci-process.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.IO.Compression.FileSystem
$Package = (Get-Item -LiteralPath $Package).FullName
$exe = Join-Path $Package 'Domenia.exe'
$release = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Package 'wad/package-release.json') | ConvertFrom-Json
if ($release.sourceCommit -cne $SourceCommit -or $release.packageType -cne 'PROD-LIGHT' -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash -ine $ArchiveSha256) { throw 'Commit, édition ou empreinte du ZIP différent.' }
$zip = [IO.Compression.ZipFile]::OpenRead((Get-Item -LiteralPath $Archive).FullName)
try {
    foreach ($name in @('Domenia.exe', 'wad/Domenia.dll', 'wad/package-manifest.json')) {
        $entries = @($zip.Entries | Where-Object FullName -ceq $name)
        if ($entries.Count -ne 1) { throw "Composant du ZIP absent ou répété : $name." }
        $stream = $entries[0].Open()
        try { $hash = (Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash }
        finally { $stream.Dispose() }
        if ($hash -cne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Package $name)).Hash) {
            throw "Le fichier extrait diffère du ZIP : $name."
        }
    }
} finally { $zip.Dispose() }

# An owned WinForms modal can be visible without being a direct child of UIA's desktop root.
# Enumerate the launched process's top-level HWNDs first, then use UIA inside the identified form.
if (-not ('DomeniaLoginWindows' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public sealed class DomeniaLoginWindow {
    public IntPtr Handle, Owner;
    public uint OwnerPid;
    public string Caption;
    public bool Visible;
}
public static class DomeniaLoginWindows {
    private delegate bool Callback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Callback cb, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder title, int count);
    public static DomeniaLoginWindow[] ForProcess(uint processId) {
        var windows = new List<DomeniaLoginWindow>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid != processId) return true;
            var caption = new StringBuilder(512);
            GetWindowText(hwnd, caption, caption.Capacity);
            IntPtr owner = GetWindow(hwnd, 4); // GW_OWNER
            uint ownerPid = 0;
            if (owner != IntPtr.Zero) GetWindowThreadProcessId(owner, out ownerPid);
            windows.Add(new DomeniaLoginWindow { Handle = hwnd, Owner = owner, OwnerPid = ownerPid,
                Caption = caption.ToString(), Visible = IsWindowVisible(hwnd) && !IsIconic(hwnd) });
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
'@
}
if (-not ('DomeniaLoginProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class DomeniaLoginProcess {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
    // Fixed when the process is created, unlike Process.MainModule, which races the loader right after Start().
    public static string ImagePath(IntPtr process) {
        var path = new StringBuilder(32768);
        uint size = (uint)path.Capacity;
        if (!QueryFullProcessImageName(process, 0, path, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return path.ToString(0, (int)size);
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    // Text of a WinForms control of another process (its UIA name is the accessible name, not the text).
    public static string Text(IntPtr hwnd) {
        var text = new StringBuilder(512);
        GetWindowText(hwnd, text, text.Capacity);
        return text.ToString();
    }
}
'@
}

function Wait-LoginElement([scriptblock]$Lookup, [string]$Step) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($app.HasExited) { throw "Domenia fermé pendant $Step (code $($app.ExitCode))." }
        try { $element = & $Lookup; if ($null -ne $element) { return $element } }
        catch [System.Windows.Automation.ElementNotAvailableException] { } # Modal transition.
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 120)
    throw "Délai dépassé : $Step."
}

function Find-LoginWindow([string]$TitlePattern) {
    $windows = [DomeniaLoginWindows]::ForProcess([uint32]$app.Id)
    # One probe per expected window, with the visible captions really seen; the latest is also kept as lastWindowProbe.
    $probe = [ordered]@{ expected=$TitlePattern; pid=$app.Id; windowCount=$windows.Length
        visibleCount=0; matchingCaptions=0; foreignOwner=0; unavailableElement=0; pidMismatch=0; captions=@() }
    $report.lastWindowProbe = $probe
    $report.windowProbes[$TitlePattern] = $probe
    foreach ($window in $windows) {
        if (!$window.Visible) { continue }
        $probe.visibleCount++
        $caption = $window.Caption.Replace([char]0x00a0,' ').Replace([char]0x202f,' ')
        if ($probe.captions.Count -lt 16) { $probe.captions += $(if ($caption.Length -gt 160) { $caption.Substring(0, 160) } else { $caption }) }
        if ($caption -cnotlike $TitlePattern) { continue }
        $probe.matchingCaptions++
        if ($window.Owner -ne [IntPtr]::Zero -and $window.OwnerPid -ne $app.Id) { $probe.foreignOwner++; continue }
        try { $element = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle) }
        catch [System.Windows.Automation.ElementNotAvailableException] { $probe.unavailableElement++; continue }
        if ($null -eq $element) { $probe.unavailableElement++; continue }
        [uint32]$actualPid = 0
        [void][DomeniaLoginWindows]::GetWindowThreadProcessId($window.Handle,[ref]$actualPid)
        if ($element.Current.ProcessId -ne $app.Id -or $actualPid -ne $app.Id -or $app.HasExited) {
            $probe.pidMismatch++; continue
        }
        $report.windows += [ordered]@{ expected=$TitlePattern; processId=$app.Id; hwnd=$window.Handle.ToInt64()
            ownerHwnd=$window.Owner.ToInt64(); ownerPid=$window.OwnerPid }
        return $element
    }
}

function Find-LoginControl($Window, [string]$Name, $Type) {
    if ($null -eq $Window) { return }
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type))
    $control = $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($null -ne $control -and !$control.Current.IsOffscreen) { return $control }
}

function Find-LoginButtonLike($Window, [string]$Pattern) {
    if ($null -eq $Window) { return }
    $buttons = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
    foreach ($button in $buttons) { if ($button.Current.Name -clike $Pattern -and !$button.Current.IsOffscreen) { return $button } }
}

function Invoke-LoginButton($Window, [string[]]$Names) {
    $button = Wait-LoginElement {
        foreach ($name in $Names) {
            $candidate = Find-LoginControl $Window $name ([System.Windows.Automation.ControlType]::Button)
            if ($null -ne $candidate -and $candidate.Current.IsEnabled) { return $candidate }
        }
    } ('bouton ' + ($Names -join ' / '))
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# The last warnings and errors of the technical journal since launch; one masked physical line per record.
function Read-DomeniaJournalProblems([DateTime]$SinceUtc) {
    try {
        $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Domenia/logs/domenia.log'
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return @('Journal technique absent.') }
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $text = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8).ReadToEnd() } finally { $stream.Dispose() }
        $since = $SinceUtc.AddSeconds(-1).ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $lines = @($text -split "`r?`n" | Where-Object {
            ($_ -cmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \[(ERREUR|ATTENTION)\] ') -and ([string]::CompareOrdinal($_.Substring(0, 20), $since) -ge 0)
        })
        return @($lines | Select-Object -Last 20 | ForEach-Object { $_.Substring(0, [Math]::Min(600, $_.Length)) })
    } catch { return @('Journal technique illisible : ' + $_.Exception.Message) }
}

$report = [ordered]@{ sourceCommit = $SourceCommit; archiveSha256 = $ArchiveSha256; expectedBrowser = $BrowserVersion.ToString()
    state = 'failed'; chooser = $false; credentialForm = $false; offlineHome = $false; observationErrors = @(); cleanupErrors = @()
    windowsIdentity = [bool]$WindowsIdentity; validationWindow = $false; connected = $false; loginFeedback = $null
    windows = @(); lastWindowProbe = $null; windowProbes = [ordered]@{}; close = $null }
$proof = [IO.File]::Open($Evidence, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$app = [Diagnostics.Process]::new()
$owned = [Collections.Generic.Dictionary[int,object]]::new()
$started = $false
try {
    $app.StartInfo.FileName = $exe
    $app.StartInfo.WorkingDirectory = $Package
    $app.StartInfo.UseShellExecute = $false
    $app.StartInfo.EnvironmentVariables['DOMENIA_SIMULATION'] = '0'
    $launchUtc = [DateTime]::UtcNow
    $started = $app.Start()
    if (!$started) { throw 'Démarrage de Domenia impossible.' }
    $owner = New-ReleaseOwnedProcess $app $exe $null
    $owned.Add($app.Id, $owner)
    $imagePath = [DomeniaLoginProcess]::ImagePath($app.Handle)
    if ($imagePath -ine $exe -or $app.SessionId -eq 0 -or $app.SessionId -ne (Get-Process -Id $PID).SessionId) {
        throw 'Processus Domenia ou session interactive inattendu.'
    }
    $report.application = [ordered]@{ processId=$app.Id; path=$imagePath; createdUtc=$owner.createdUtc; sessionId=$app.SessionId }
    $chooser = Wait-LoginElement { Find-LoginWindow 'Domenia — Connexion' } 'choix de connexion'
    $report.chooser = $true
    $net = Join-Path $Package 'wad/runtime/dotnet'
    $roots = @([Environment]::GetFolderPath('ProgramFilesX86'), [Environment]::GetFolderPath('ProgramFiles'))
    $browser = $roots | ForEach-Object { Join-Path $_ ("Microsoft/EdgeWebView/Application/" + $BrowserVersion) } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'msedgewebview2.exe') -PathType Leaf } | Select-Object -First 1
    if (!$browser) { throw 'Version Evergreen attendue absente des dossiers système.' }
    $modules = @{}; $browsers = @{}; $targets = @{}
    Update-ReleaseDescendants $owned $report
    Observe-ReleaseRuntimes $owned $modules $browsers $targets $report $net $browser
    Assert-ReleaseRuntimeEvidence $targets $modules $browsers $net $browser
    $report.browserProcesses = @($browsers.Values)
    $report.dotnetModules = @($modules.Values)

    if ($WindowsIdentity) {
        # One attempt only: success shows the main window, a refusal brings a new choice back with its message.
        $identity = Wait-LoginElement { Find-LoginButtonLike $chooser 'Continuer en tant que *' } "bouton de l'identité Windows"
        if (!$identity.Current.IsEnabled) { throw "Identité Windows indisponible : $($identity.Current.HelpText)" }
        $first = $chooser.Current.NativeWindowHandle
        $identity.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $outcome = Wait-LoginElement {
            if (!$report.validationWindow -and $null -ne (Find-LoginWindow 'Domenia — Validation de la connexion*')) { $report.validationWindow = $true }
            if ($null -ne (Find-LoginWindow 'Accueil* — Domenia*')) { return 'connected' }
            $again = Find-LoginWindow 'Domenia — Connexion'
            if ($null -ne $again -and $again.Current.NativeWindowHandle -ne $first) {
                $status = Find-LoginControl $again 'Résultat de la connexion précédente' ([System.Windows.Automation.ControlType]::Text)
                if ($null -ne $status) { $report.loginFeedback = [DomeniaLoginProcess]::Text([IntPtr]$status.Current.NativeWindowHandle); return 'refused' }
            }
        } 'résultat de la connexion Windows'
        if ($outcome -cne 'connected') { throw "Connexion par l'identité Windows refusée : $($report.loginFeedback)" }
        $report.connected = $true
    } else {
        Invoke-LoginButton $chooser @('Utiliser un autre compte', 'Se connecter avec ce compte')
        $credential = Wait-LoginElement { Find-LoginWindow 'Domenia — Se connecter avec un compte*' } 'saisie native'
        [void](Wait-LoginElement { Find-LoginControl $credential 'Mot de passe' ([System.Windows.Automation.ControlType]::Edit) } 'champ mot de passe')
        $report.credentialForm = $true
        Invoke-LoginButton $credential @('Annuler')
        $chooser = Wait-LoginElement { Find-LoginWindow 'Domenia — Connexion' } 'retour au choix'
        Invoke-LoginButton $chooser @('Continuer hors connexion')
        [void](Wait-LoginElement { Find-LoginWindow 'Accueil* — Domenia*' } 'accueil hors connexion')
        $report.offlineHome = $true
    }
    Update-ReleaseDescendants $owned $report
    # Each condition of the close is kept, so a refused close says whether the request, the exit or its code failed.
    $app.Refresh()
    $report.close = [ordered]@{ mainWindow = $app.MainWindowTitle; requested = $false; exited = $false; exitCode = $null; captions = @(); journal = @() }
    $report.close.requested = $app.CloseMainWindow()
    if ($report.close.requested) { $report.close.exited = $app.WaitForExit(15000) }
    if ($report.close.exited) { $report.close.exitCode = $app.ExitCode }
    if (!$report.close.requested -or !$report.close.exited -or $report.close.exitCode -ne 0) {
        if (!$app.HasExited) {
            $report.close.captions = @([DomeniaLoginWindows]::ForProcess([uint32]$app.Id) | Where-Object Visible | Select-Object -First 8 |
                ForEach-Object { $_.Caption.Substring(0, [Math]::Min(160, $_.Caption.Length)) })
        }
        $report.close.journal = @(Read-DomeniaJournalProblems $launchUtc)
        throw 'Fermeture de Domenia non confirmée.'
    }
    $report.state = 'passed'
} catch {
    $report.error = $_.Exception.Message
    throw
} finally {
    try {
        if ($started -and !$app.HasExited) {
            try { Update-ReleaseDescendants $owned $report } catch { $report.cleanupErrors += $_.Exception.Message }
            try { $app.Kill(); if (!$app.WaitForExit(10000)) { throw 'Fin du processus Domenia non confirmée.' } }
            catch { $report.cleanupErrors += $_.Exception.Message }
        }
        foreach ($entry in @($owned.Values | Where-Object depth -gt 0 | Sort-Object depth -Descending)) {
            try {
                if (!$entry.process.WaitForExit(3000)) {
                    if ($entry.process.StartTime.ToUniversalTime().Ticks -ne $entry.createdTicks) { throw 'Identité du processus modifiée.' }
                    $report.cleanupErrors += "Fermeture forcée du descendant $($entry.processId)."
                    $entry.process.Kill()
                    if (!$entry.process.WaitForExit(10000)) { throw 'Fin du descendant non confirmée.' }
                }
            } catch { $report.cleanupErrors += $_.Exception.Message }
            finally { $entry.process.Dispose() }
        }
    } finally {
        $app.Dispose()
        try {
            if ($report.cleanupErrors.Count) { $report.state = 'failed' }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 8))
            $proof.Write($bytes, 0, $bytes.Length)
        } finally { $proof.Dispose() }
    }
}
if ($report.state -cne 'passed') { throw "Recette du login incomplète. Voir $Evidence." }
