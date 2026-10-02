#requires -Version 5.1
<# Installs only manifest-listed code files. Existing settings and wad\data are never replaced.
   -WhatIf performs verification and lists the plan without writing.
   Restore is hash-guarded: it refuses to discard an independently modified file.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium',DefaultParameterSetName='Install')]
param(
    [Parameter(Mandatory,ParameterSetName='Install')][string]$Destination,
    [Parameter(Mandatory,ParameterSetName='Restore')][string]$RestoreBackup
)
$ErrorActionPreference='Stop'
function Get-CodeHash {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash}
function Get-SafePackagePath {
    param([string]$Base,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.IndexOf([char]0) -ge 0) {throw "Chemin de paquet invalide : $Relative"}
    $parts=@($Relative -split '[/\\]')
    if (@($parts | Where-Object {$_ -in @('','..','.')}).Count -gt 0) {throw "Chemin relatif invalide : $Relative"}
    if($Relative -match '^(?i:wad[/\\](data|maintenance[/\\]backups))([/\\]|$)') {throw 'Le programme de mise a jour ne doit pas toucher aux donnees ou sauvegardes.'}
    $prefix=[IO.Path]::GetFullPath($Base).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $prefix ($parts -join [IO.Path]::DirectorySeparatorChar)))
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Chemin hors du dossier autorise.'}
    # Reject existing junctions/symlinks in the destination chain; avoid redirection outside the install.
    $probe=$prefix.TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Le dossier racine ne doit pas etre une jonction/lien.'}
    foreach($part in $parts) {
        $probe=Join-Path $probe $part
        if(Test-Path -LiteralPath $probe) {
            if((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Lien/jonction refuse : $probe"}
        }
    }
    return $path
}
function Assert-AppClosed {
    param([string]$Root)
    if(@(Get-Process -Name Domenia,ADCC -ErrorAction SilentlyContinue).Count -gt 0) {throw 'Ferme toutes les instances Domenia.exe avant de mettre a jour ou restaurer.'}
    $core=Join-Path $Root 'wad\Domenia-Core.ps1'
    $legacy=Join-Path $Root 'wad\ADCC-Core.ps1'
    $processes=Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='powershell_ise.exe' OR Name='pwsh.exe'" -ErrorAction Stop
    foreach($process in $processes) {
        if([int]$process.ProcessId -eq $PID) {continue}
        if(([string]$process.CommandLine).IndexOf($legacy,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$process.CommandLine).IndexOf((Join-Path $Root 'wad\ADCC-Start.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$process.CommandLine).IndexOf($core,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$process.CommandLine).IndexOf((Join-Path $Root 'wad\Domenia-Start.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0) {throw "DOMENIA encore lance : PID $($process.ProcessId). Ferme-le sans interrompre une ecriture AD."}
    }
}
function Copy-CodeAtomically {
    param([string]$From,[string]$To)
    $dir=[IO.Path]::GetDirectoryName($To);[void][IO.Directory]::CreateDirectory($dir)
    $tmp=Join-Path $dir ('.domenia-update-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::Copy($From,$tmp,$false)
        $stream=[IO.File]::Open($tmp,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {$stream.Flush($true)}finally {$stream.Dispose()}
        if([IO.File]::Exists($To)) {[IO.File]::Replace($tmp,$To,$null,$true)}else {[IO.File]::Move($tmp,$To)}
    } finally {if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Write-CodeJournal {
    param([string]$Path,[object]$Value)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8))
        $stream=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,$null,$true)}else{[IO.File]::Move($temp,$Path)}
    } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Restore-CodeTransaction {
    param([string]$Backup,[object]$Journal)
    $targetRoot=[string]$Journal.Destination
    if(-not [IO.Directory]::Exists($targetRoot)) {throw 'Destination de restauration introuvable.'}
    # Validate every file first. Do not partially roll back an externally modified installation.
    foreach($entry in @($Journal.Files)) {
        $target=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if([bool]$entry.Existed) {
            $saved=Get-SafePackagePath (Join-Path $Backup 'files') ([string]$entry.Path)
            if(-not [IO.File]::Exists($saved) -or (Get-CodeHash $saved) -cne [string]$entry.OldSha256) {throw "Sauvegarde invalide : $($entry.Path)"}
        }
        if([IO.File]::Exists($target)) {
            $actual=Get-CodeHash $target
            if($actual -cne [string]$entry.NewSha256 -and $actual -cne [string]$entry.OldSha256) {throw "Fichier modifie depuis la mise a jour, restauration refusee : $($entry.Path)"}
        }
    }
    $entries=@($Journal.Files);[array]::Reverse($entries)
    foreach($entry in $entries) {
        $target=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if([bool]$entry.Existed) {
            $saved=Get-SafePackagePath (Join-Path $Backup 'files') ([string]$entry.Path)
            Copy-CodeAtomically $saved $target
        } elseif([IO.File]::Exists($target)) {[IO.File]::Delete($target)}
    }
}
if($PSCmdlet.ParameterSetName -eq 'Restore') {
    $backup=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RestoreBackup).Path)
    $journal=Get-Content -LiteralPath (Join-Path $backup 'transaction.json') -Raw | ConvertFrom-Json
    if([int]$journal.Format -ne 1 -or [string]::IsNullOrWhiteSpace([string]$journal.Destination)) {throw 'Journal de restauration invalide.'}
    Assert-AppClosed ([string]$journal.Destination)
    if($PSCmdlet.ShouldProcess([string]$journal.Destination,'Restaurer uniquement le code sauvegarde; conserver les donnees')) {
        [void][IO.Directory]::CreateDirectory((Join-Path ([string]$journal.Destination) 'wad\Support'))
        $lockPath=Join-Path ([string]$journal.Destination) 'wad\Support\.lifecycle.lock'
        $restoreLock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {Restore-CodeTransaction $backup $journal;[IO.File]::Delete((Join-Path ([string]$journal.Destination) 'wad\Support\.update.pending'))} finally {$restoreLock.Dispose()}
        Write-Host 'Code precedent restaure. wad\data et les preferences conservees n ont pas ete modifies.'
    }
    return
}
$source=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$targetRoot=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Destination).Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
if($source -ieq $targetRoot) {throw 'Extrais le nouveau ZIP dans un dossier distinct de ton DOMENIA actuel.'}
$sourcePrefix=$source+[IO.Path]::DirectorySeparatorChar;$targetPrefix=$targetRoot+[IO.Path]::DirectorySeparatorChar
if($sourcePrefix.StartsWith($targetPrefix,[StringComparison]::OrdinalIgnoreCase) -or $targetPrefix.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Les dossiers source et destination ne doivent pas etre imbriques.'}
if(-not (Test-Path -LiteralPath (Join-Path $targetRoot 'wad\Domenia-Core.ps1') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $targetRoot 'wad\ADCC-Core.ps1') -PathType Leaf)) {throw 'Destination incorrecte : choisir le dossier DOMENIA contenant wad\Domenia-Core.ps1.'}
Assert-AppClosed $targetRoot
$manifestPath=Join-Path $source 'tools\prod-manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if([int]$manifest.Format -ne 1 -or @($manifest.Files).Count -lt 5) {throw 'Manifeste du paquet invalide.'}
$plan=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
foreach($entry in @($manifest.Files)) {
    $relative=[string]$entry.Path
    if($relative -eq 'wad/Support/.lifecycle.lock'){continue}
    if($seen.ContainsKey($relative)) {throw 'Entree en double dans le manifeste.'};$seen[$relative]=$true
    $from=Get-SafePackagePath $source $relative;$to=Get-SafePackagePath $targetRoot $relative
    if(-not [IO.File]::Exists($from) -or (Get-CodeHash $from) -cne [string]$entry.Sha256) {throw "Integrite du paquet invalide : $relative"}
    if($relative.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($from,[ref]$tokens,[ref]$errors)
        if(@($errors).Count -gt 0) {throw "Script PowerShell invalide : $relative ; $($errors[0].Message)"}
    }
    $exists=[IO.File]::Exists($to)
    $sourceOverride=''
    if(-not $exists -and [bool]$entry.PreserveExisting -and $relative -match '^wad/Domenia\.'){
        $oldRelative=$relative -replace '^wad/Domenia\.','wad/ADCC.'
        $oldConfig=Get-SafePackagePath $targetRoot $oldRelative
        if([IO.File]::Exists($oldConfig)){
            if(([IO.FileInfo]::new($oldConfig)).Length -gt 1MB){throw 'Ancienne configuration trop volumineuse.'}
            if($relative.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)){$null=[IO.File]::ReadAllText($oldConfig)|ConvertFrom-Json}
            $sourceOverride=$oldConfig;Write-Host ('Migration sans suppression : '+$oldRelative+' -> '+$relative)
        }
    }
    if($exists -and [bool]$entry.PreserveExisting) {Write-Host ('Conserve : '+$relative);continue}
    $oldHash=if($exists){Get-CodeHash $to}else{''}
    if($oldHash -ceq [string]$entry.Sha256) {continue}
    $plan.Add([pscustomobject]@{Path=$relative;Existed=$exists;OldSha256=$oldHash;NewSha256=$(if($sourceOverride){Get-CodeHash $sourceOverride}else{[string]$entry.Sha256});SourceOverride=$sourceOverride})
}
# Preserve a package manifest together with the code, excluding the manifest from its own hash list.
$manifestRelative='wad/package-manifest.json';$manifestTarget=Get-SafePackagePath $targetRoot $manifestRelative
$manifestExists=[IO.File]::Exists($manifestTarget)
$plan.Add([pscustomobject]@{Path=$manifestRelative;Existed=$manifestExists;OldSha256=$(if($manifestExists){Get-CodeHash $manifestTarget}else{''});NewSha256=(Get-CodeHash $manifestPath)})
Write-Host ('Fichiers a installer : '+$plan.Count)
foreach($entry in $plan){Write-Host ('  '+$entry.Path)}
if(-not $PSCmdlet.ShouldProcess($targetRoot,'Sauvegarder le code puis installer la mise a jour, sans toucher a wad\data')) {return}
# DEV-only gate. PROD startup never depends on these suites.
$desktopPowerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if(Test-Path (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')){$desktopPowerShell=Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'}
# Current release gate: real Windows parser, module imports, WPF and selection behaviors.
# Historical suites remain in DEV for maintenance; their superseded UI expectations are not release criteria.
foreach($suite in @('Test-DomeniaPreload.ps1')){
    $test=Join-Path $source ('wad\tests\'+$suite)
    $report=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-preload-install-'+[guid]::NewGuid().ToString('N')+'.json')
    Write-Host ('Tests Windows avant copie : '+$suite+' ; rapport : '+$report)
    & $desktopPowerShell -NoLogo -NoProfile -STA -NonInteractive -File $test -ReportPath $report -Quiet
    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($report)){throw ('Verification native echouee avant copie : '+$report)}
    $result=[IO.File]::ReadAllText($report)|ConvertFrom-Json
    if(-not $result.Complete -or -not $result.NativeWindowsPowerShell -or -not $result.Wpf -or [int]$result.Failed -ne 0 -or [int]$result.Skipped -ne 0 -or [int]$result.Passed -lt 40){throw ('Rapport de tests incomplet ou en echec : '+$report)}
}
Assert-AppClosed $targetRoot

$backupParent=Join-Path $targetRoot 'wad\maintenance\backups'
# Validate maintenance path before creating it (junction protection).
[void](Get-SafePackagePath $targetRoot 'wad/maintenance')
if(Test-Path -LiteralPath $backupParent) {if((Get-Item -LiteralPath $backupParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier de sauvegarde redirige par un lien.'}}
$backup=Join-Path $backupParent ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $backup 'files'))
[void](Get-SafePackagePath $targetRoot 'wad/Support/.lifecycle.lock')
[void][IO.Directory]::CreateDirectory((Join-Path $targetRoot 'wad\Support'))
$lockPath=Join-Path $targetRoot 'wad\Support\.lifecycle.lock'
$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$pendingPath=Join-Path $targetRoot 'wad\Support\.update.pending'
if([IO.File]::Exists($pendingPath)){$lock.Dispose();throw 'Installation precedente incomplete. Utilisez -RestoreBackup avec le journal indique dans wad/Support/.update.pending.'}
$journal=[ordered]@{Format=1;Build=[string]$manifest.Build;Created=(Get-Date).ToString('o');Destination=$targetRoot;Status='Prepared';Files=$plan.ToArray()}
$journalPath=Join-Path $backup 'transaction.json'
$encoding=[Text.UTF8Encoding]::new($false)
$started=$false
try {
    Assert-AppClosed $targetRoot
    # Backup all original code before the first replacement.
    foreach($entry in $plan) {
        $to=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if([bool]$entry.Existed) {
            if((Get-CodeHash $to) -cne [string]$entry.OldSha256) {throw 'Fichier destination modifie pendant la preparation.'}
            $saved=Get-SafePackagePath (Join-Path $backup 'files') ([string]$entry.Path)
            Copy-CodeAtomically $to $saved
        } elseif([IO.File]::Exists($to)) {throw 'Un fichier destination est apparu pendant la preparation.'}
    }
    Write-CodeJournal $journalPath $journal
    [IO.File]::Copy($PSCommandPath,(Join-Path $backup 'RESTAURER-CODE.ps1'),$false)
    Write-CodeJournal $pendingPath ([ordered]@{Backup=$backup;Build=$manifest.Build;Status='Installing'})
    $started=$true
    foreach($entry in $plan) {
        $from=if([string]$entry.Path -eq 'wad/package-manifest.json'){$manifestPath}elseif($entry.PSObject.Properties['SourceOverride'] -and $entry.SourceOverride){[string]$entry.SourceOverride}else{Get-SafePackagePath $source ([string]$entry.Path)};$to=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if((Get-CodeHash $from) -cne [string]$entry.NewSha256) {throw 'Le paquet source a change pendant l installation.'}
        Copy-CodeAtomically $from $to
        if((Get-CodeHash $to) -cne [string]$entry.NewSha256) {throw 'Verification apres copie en echec.'}
    }
    $journal.Status='Installed'
    Write-CodeJournal $journalPath $journal
    [IO.File]::Delete($pendingPath)
    Write-Host ('Mise a jour installee. Ancien code : '+$backup)
    Write-Host 'Runtime installe. Lance Domenia.exe, pas un ancien ADCC.exe, et effectue la recette sur une OU de test. Les anciens fichiers DEV ne sont pas supprimes automatiquement.'
}
catch {
    $failure=$_.Exception.Message
    if($started) {
        try {Restore-CodeTransaction $backup $journal;[IO.File]::Delete($pendingPath);Write-Warning 'Installation en echec : ancien code restaure.'}
        catch {Write-Warning ('Restauration automatique incomplete : '+$_.Exception.Message+'. Sauvegarde : '+$backup)}
    }
    throw ('Mise a jour interrompue : '+$failure)
}
finally {$lock.Dispose()}
