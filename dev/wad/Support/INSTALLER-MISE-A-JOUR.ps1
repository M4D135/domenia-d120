#requires -Version 5.1
<# Installs only manifest-listed code files. Existing settings and wad\data are never replaced.
   Shipped in PROD and DEV as wad\Support\INSTALLER-MISE-A-JOUR.ps1; it runs from an extracted package (source = the
   folder that contains Domenia.exe and wad) or from an installed copy (-RestoreLatest).
   FI-06: no test suite ever runs on the target workstation. The prepared version is checked with Domenia-Start.ps1
   -CheckOnly; a Windows qualification report (release_guard format) is verified when supplied, bound to the SHA-256
   of the delivered ZIP. Without it a warning is shown; -RequireQualification refuses instead.
   UX-29: explicit answer before any write, prepared copy removed after success, five complete backups kept.
   FO-20: -Install copies a package into an empty folder (hashes checked, files unblocked, Domenia-Start -CheckOnly);
   shortcuts are offered and never created without an answer.
   -WhatIf performs verification and lists the plan without writing.
   Restore is hash-guarded: it refuses to discard an independently modified file.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium',DefaultParameterSetName='Update')]
param(
    [Parameter(Mandatory,ParameterSetName='Update')]
    [Parameter(Mandatory,ParameterSetName='Install')]
    [Parameter(Mandatory,ParameterSetName='RestoreLatest')]
    [string]$Destination,
    [Parameter(Mandatory,ParameterSetName='Install')][switch]$Install,
    [Parameter(Mandatory,ParameterSetName='Restore')][string]$RestoreBackup,
    [Parameter(Mandatory,ParameterSetName='RestoreLatest')][switch]$RestoreLatest,
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][string]$Package='',
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][string]$QualificationReport='',
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][switch]$RequireQualification,
    [Parameter(ParameterSetName='Install')][ValidateSet('Demander','Oui','Non')][string]$Shortcuts='Demander'
)
$ErrorActionPreference='Stop'
# -Confirm:$false waives the question; an explicit -Confirm already asked through ShouldProcess.
$askOperator=-not $PSBoundParameters.ContainsKey('Confirm')
$keptBackups=5
# Same floor as engineering/d120/release_guard.py REQUIRED.
$qualificationScenarios=@('parser.ps51','runtime.modules','worker.contracts','startup.exe_login_main','ui.actual_events','ui.layout_profiles','data.sqlite','security.secret_markers','race.selection','prod.standalone')
function Get-CodeHash {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash}
function Get-SafePackagePath {
    param([string]$Base,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.IndexOf([char]0) -ge 0) {throw "Chemin de paquet invalide : $Relative"}
    $parts=@($Relative -split '[/\\]')
    if (@($parts | Where-Object {$_ -in @('','..','.')}).Count -gt 0) {throw "Chemin relatif invalide : $Relative"}
    if($Relative -match '^(?i:wad[/\\](data|maintenance[/\\]backups))([/\\]|$)') {throw 'Lʼinstallateur ne touche jamais aux données ni aux sauvegardes.'}
    $prefix=[IO.Path]::GetFullPath($Base).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $prefix ($parts -join [IO.Path]::DirectorySeparatorChar)))
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Chemin hors du dossier autorisé.'}
    # Reject existing junctions/symlinks in the destination chain; avoid redirection outside the install.
    $probe=$prefix.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $ancestor=[IO.DirectoryInfo]::new($probe)
    while($null -ne $ancestor){if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Le dossier racine ne doit pas être une jonction ni un lien.'};$ancestor=$ancestor.Parent}
    foreach($part in $parts) {
        $probe=Join-Path $probe $part
        if(Test-Path -LiteralPath $probe) {
            if((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Lien ou jonction refusé : $probe"}
        }
    }
    return $path
}
function Assert-AppClosed {
    param([string]$Root)
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    foreach($instance in @(Get-Process -Name Domenia,ADCC -ErrorAction SilentlyContinue)){
        $instancePath=[string]$instance.Path
        if(-not $instancePath){throw 'Une instance Domenia ne peut pas être identifiée. Fermez-la avant de continuer.'}
        if($instancePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Fermez Domenia dans le dossier à mettre à jour ou à restaurer.'}
    }
    $core=Join-Path $Root 'wad\Domenia-Core.ps1'
    $legacy=Join-Path $Root 'wad\ADCC-Core.ps1'
    $processes=Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='powershell_ise.exe' OR Name='pwsh.exe'" -ErrorAction Stop
    foreach($process in $processes) {
        if([int]$process.ProcessId -eq $PID) {continue}
        if(([string]$process.CommandLine).IndexOf($legacy,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$process.CommandLine).IndexOf((Join-Path $Root 'wad\ADCC-Start.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$process.CommandLine).IndexOf($core,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$process.CommandLine).IndexOf((Join-Path $Root 'wad\Domenia-Start.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0) {throw "Domenia est encore lancé : PID $($process.ProcessId). Fermez-le sans interrompre une écriture AD."}
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
        if([IO.File]::Exists($To)) {[IO.File]::Replace($tmp,$To,[NullString]::Value,$true)}else {[IO.File]::Move($tmp,$To)}
    } finally {if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Write-CodeJournal {
    param([string]$Path,[object]$Value)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8))
        $stream=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value,$true)}else{[IO.File]::Move($temp,$Path)}
    } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-CodeManifest {
    param([string]$Path,[switch]$Previous)
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Length -gt 2MB -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste invalide ou redirigé.'}
    $value=[IO.File]::ReadAllText($Path)|ConvertFrom-Json
    if([int]$value.Format -ne 1 -or [string]::IsNullOrWhiteSpace([string]$value.Build) -or @($value.Files).Count -lt 5){throw 'Manifeste du paquet invalide.'}
    $seen=@{}
    foreach($entry in @($value.Files)){
        $relative=[string]$entry.Path
        # Canonical names make duplicate checks and special-file exclusions unambiguous.
        if($relative.Contains('\') -or $relative -eq 'wad/package-manifest.json' -or $relative -eq 'wad/Support/.update.pending' -or $seen.ContainsKey($relative) -or [string]$entry.Sha256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'Entrée de manifeste invalide ou dupliquée.'}
        if($entry.Runtime -isnot [bool] -or $entry.PreserveExisting -isnot [bool]){throw 'Indicateurs du manifeste invalides.'}
        if(-not $Previous -and $entry.PreserveExisting -and $relative -notin @('wad/Domenia.config.json','wad/Domenia.login-mode.cfg','wad/Domenia.theme.cfg','wad/Domenia.ui-profile.cfg')){throw 'Conservation réservée aux préférences du logiciel.'}
        $seen[$relative]=$true
    }
    foreach($required in @('Domenia.exe','wad/Domenia-Core.ps1','wad/Domenia-Start.ps1','wad/Domenia-Modules.ps1','wad/Support/.lifecycle.lock')){
        if(-not $Previous -and -not $seen.ContainsKey($required)){throw ('Manifeste incomplet : '+$required)}
    }
    return $value
}
function Assert-CodeVersion {
    param([string]$Root,[object]$Manifest,[IO.FileStream]$OwnedLock=$null)
    foreach($entry in @($Manifest.Files)){
        if(-not $entry.Runtime){continue}
        $path=Get-SafePackagePath $Root ([string]$entry.Path)
        if(-not [IO.File]::Exists($path)){throw ('Composant manquant : '+$entry.Path)}
        if($entry.PreserveExisting){continue}
        if([string]$entry.Path -ieq 'wad/Support/.lifecycle.lock' -and $null -ne $OwnedLock){
            # The exclusive lock cannot be reopened for hashing; hash its owned handle.
            $position=$OwnedLock.Position;$hasher=[Security.Cryptography.SHA256]::Create()
            try{$OwnedLock.Position=0;$actual=[BitConverter]::ToString($hasher.ComputeHash($OwnedLock)).Replace('-','')}finally{$OwnedLock.Position=$position;$hasher.Dispose()}
        }else{$actual=Get-CodeHash $path}
        if($actual -ine [string]$entry.Sha256){throw ('Version incomplète ou mélangée : '+$entry.Path)}
    }
}
function Assert-RestoredCode {
    param([object]$Journal,[IO.FileStream]$OwnedLock)
    foreach($entry in @($Journal.Files)){
        $target=Get-SafePackagePath ([string]$Journal.Destination) ([string]$entry.Path)
        if($entry.Existed){if(-not [IO.File]::Exists($target) -or (Get-CodeHash $target) -ine [string]$entry.OldSha256){throw ('Restauration non vérifiée : '+$entry.Path)}}
        elseif([IO.File]::Exists($target)){throw ('Fichier nouveau encore présent : '+$entry.Path)}
    }
    $previousManifest=Get-SafePackagePath ([string]$Journal.Destination) 'wad/package-manifest.json'
    if([IO.File]::Exists($previousManifest)){Assert-CodeVersion ([string]$Journal.Destination) (Get-CodeManifest $previousManifest -Previous) $OwnedLock}
}

function Restore-CodeTransaction {
    param([string]$Backup,[object]$Journal,[switch]$VerifyOnly)
    $targetRoot=[string]$Journal.Destination
    if(-not [IO.Directory]::Exists($targetRoot)) {throw 'Destination de restauration introuvable.'}
    $seen=@{}
    foreach($entry in @($Journal.Files)){
        $relative=[string]$entry.Path
        if($relative.Contains('\') -or $relative -in @('wad/Support/.lifecycle.lock','wad/Support/.update.pending') -or $seen.ContainsKey($relative) -or $entry.Existed -isnot [bool] -or [string]$entry.NewSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or ($entry.Existed -and [string]$entry.OldSha256 -notmatch '^[A-Fa-f0-9]{64}$')){throw 'Journal de restauration invalide.'}
        $seen[$relative]=$true
    }
    # Validate every file first. Do not partially roll back an externally modified installation.
    foreach($entry in @($Journal.Files)) {
        $target=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if([bool]$entry.Existed) {
            $saved=Get-SafePackagePath (Join-Path $Backup 'files') ([string]$entry.Path)
            if(-not [IO.File]::Exists($saved) -or (Get-CodeHash $saved) -cne [string]$entry.OldSha256) {throw "Sauvegarde invalide : $($entry.Path)"}
        }
        if([IO.File]::Exists($target)) {
            $actual=Get-CodeHash $target
            if($actual -cne [string]$entry.NewSha256 -and $actual -cne [string]$entry.OldSha256) {throw "Fichier modifié depuis la mise à jour, restauration refusée : $($entry.Path)"}
        }
    }
    if($VerifyOnly){return}
    $entries=@($Journal.Files);[array]::Reverse($entries)
    foreach($entry in $entries) {
        $target=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if([bool]$entry.Existed) {
            $saved=Get-SafePackagePath (Join-Path $Backup 'files') ([string]$entry.Path)
            Copy-CodeAtomically $saved $target
        } elseif([IO.File]::Exists($target)) {[IO.File]::Delete($target)}
    }
}
function Read-OperatorAnswer {
    # O/N question. $null means no answer: non-interactive host, closed input or three unreadable answers.
    param([string]$Question)
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{$answer=Read-Host $Question}catch{return $null}
        if($null -eq $answer){return $null}
        $value=([string]$answer).Trim()
        if($value -match '^(?i:o|oui|y|yes)$'){return $true}
        if($value -match '^(?i:n|non|no)$'){return $false}
        Write-Host 'Répondez O (oui) ou N (non).'
    }
    return $null
}
function Get-BackupRoot {param([string]$Root) return (Join-Path $Root 'wad\maintenance\backups')}
function Get-CompletedBackups {
    # Backup folders created by this installer (yyyyMMdd-HHmmss-xxxxxxxx), newest first, with their journal status.
    param([string]$Root)
    $parent=Get-BackupRoot $Root
    if(-not [IO.Directory]::Exists($parent)){return @()}
    if((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier de sauvegarde redirigé par un lien.'}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($folder in @([IO.DirectoryInfo]::new($parent).GetDirectories())){
        if($folder.Name -cnotmatch '^\d{8}-\d{6}-[0-9a-f]{8}$'){continue}
        if($folder.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
        $journalPath=Join-Path $folder.FullName 'transaction.json'
        $status='';$build='';$destination=''
        if([IO.File]::Exists($journalPath)){
            try{$journal=[IO.File]::ReadAllText($journalPath)|ConvertFrom-Json;$status=[string]$journal.Status;$build=[string]$journal.Build;$destination=[string]$journal.Destination}catch{$status='Illisible'}
        }
        $rows.Add([pscustomobject]@{Name=$folder.Name;Path=$folder.FullName;Journal=[IO.File]::Exists($journalPath);Status=$status;Build=$build;Destination=$destination})
    }
    return @($rows.ToArray()|Sort-Object -Property Name -Descending)
}
function Invoke-BackupRotation {
    # Keeps the $Keep newest complete backups (Installed or Restored). A backup referenced by the pending marker, an
    # unfinished or unreadable journal is never deleted. A folder without journal changed nothing (the journal is
    # written before the first replacement): it is an abandoned preparation and is removed.
    param([string]$Root,[string]$Current,[int]$Keep)
    $pending=Join-Path $Root 'wad\Support\.update.pending'
    $protected=''
    if([IO.File]::Exists($pending)){try{$protected=[string](([IO.File]::ReadAllText($pending)|ConvertFrom-Json).Backup)}catch{return @()}}
    $parentPrefix=[IO.Path]::GetFullPath((Get-BackupRoot $Root)).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $currentPath=[IO.Path]::GetFullPath($Current).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if($protected){$protected=[IO.Path]::GetFullPath($protected).TrimEnd([IO.Path]::DirectorySeparatorChar)}
    $removed=New-Object 'System.Collections.Generic.List[string]'
    $complete=0
    foreach($candidate in @(Get-CompletedBackups $Root)){
        $isComplete=(($candidate.Status -ceq 'Installed') -or ($candidate.Status -ceq 'Restored'))
        if(($candidate.Path -ieq $currentPath) -or ($candidate.Path -ieq $protected)){if($isComplete){$complete++};continue}
        if(-not $candidate.Path.StartsWith($parentPrefix,[StringComparison]::OrdinalIgnoreCase)){continue}
        $drop=$false
        if(-not $candidate.Journal){$drop=$true}
        elseif($isComplete){$complete++;$drop=($complete -gt $Keep)}
        if($drop){Remove-Item -LiteralPath $candidate.Path -Recurse -Force;$removed.Add($candidate.Name)}
    }
    return @($removed.ToArray())
}
function Get-SourceManifestPath {
    # DEV package: tools\prod-manifest.json ; PROD package or installed copy: wad\package-manifest.json (Edition prod).
    param([string]$Source)
    $dev=Join-Path $Source 'tools\prod-manifest.json'
    if([IO.File]::Exists($dev)){return $dev}
    $prod=Join-Path $Source 'wad\package-manifest.json'
    if(-not [IO.File]::Exists($prod)){throw 'Manifeste du paquet introuvable : extrayez tout le ZIP (dossier contenant Domenia.exe et wad).'}
    $edition=[string](([IO.File]::ReadAllText($prod)|ConvertFrom-Json).Edition)
    if($edition -cne 'prod'){throw 'Manifeste PROD introuvable dans ce paquet.'}
    return $prod
}
function Get-QualificationState {
    # Offline check of a release_guard report: Windows PowerShell 5.1, campaign PASS, same Build, required scenarios
    # executed and PASS, report bound to the SHA-256 of the ZIP given in -Package, and that ZIP carrying the same file
    # hashes as the package being installed. A local report is not a signature: it proves neither origin nor author.
    param([string]$ReportPath,[string]$PackagePath,[object]$Manifest)
    $state=[pscustomobject]@{Bound=$false;Reason='';ArchiveSha256='';Edition=''}
    if(-not $ReportPath){$state.Reason='aucun rapport fourni (-QualificationReport).';return $state}
    if(-not $PackagePath){$state.Reason='le ZIP livré (-Package) est nécessaire pour lier le rapport à son empreinte.';return $state}
    try{
        $reportFile=[IO.FileInfo]::new([IO.Path]::GetFullPath($ReportPath))
        $zipFile=[IO.FileInfo]::new([IO.Path]::GetFullPath($PackagePath))
        if((-not $reportFile.Exists) -or ($reportFile.Length -gt 16MB)){throw 'rapport absent ou trop volumineux.'}
        if(-not $zipFile.Exists){throw 'ZIP absent.'}
        $zipHash=(Get-CodeHash $zipFile.FullName).ToLowerInvariant()
        $state.ArchiveSha256=$zipHash
        $report=[IO.File]::ReadAllText($reportFile.FullName)|ConvertFrom-Json
        $reportHost=$report.Host
        if(($null -eq $reportHost) -or ([string]$reportHost.Platform -cne 'Windows') -or ([string]$reportHost.PSEdition -cne 'Desktop') -or (-not ([string]$reportHost.PSVersion).StartsWith('5.1.'))){throw 'preuve Windows PowerShell 5.1 requise.'}
        if([string]$report.OverallStatus -cne 'PASS'){throw 'campagne inachevée ou en échec.'}
        if([string]$report.Build -cne [string]$Manifest.Build){throw 'Build du rapport différent de celui du paquet.'}
        $edition=''
        if($null -ne $report.PSObject.Properties['Archives'] -and $null -ne $report.Archives){
            foreach($archive in @($report.Archives)){if(([string]$archive.SHA256).ToLowerInvariant() -ceq $zipHash){$edition=[string]$archive.Edition}}
        }elseif(([string]$report.ArchiveSHA256).ToLowerInvariant() -ceq $zipHash){$edition='?'}
        if(-not $edition){throw 'rapport non lié au ZIP fourni.'}
        $byId=@{}
        foreach($scenario in @($report.Scenarios)){if($null -ne $scenario){$byId[[string]$scenario.Id]=$scenario}}
        foreach($id in $qualificationScenarios){
            $scenario=$byId[$id]
            if(($null -eq $scenario) -or ([string]$scenario.Status -cne 'PASS') -or ($scenario.Executed -isnot [bool]) -or (-not $scenario.Executed)){throw ('scénario requis absent, non exécuté ou en échec : '+$id)}
        }
        Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($zipFile.FullName)
        try{
            $entry=$null
            foreach($prefix in @('prod','dev')){if($null -eq $entry){$entry=$zip.GetEntry($prefix+'/wad/package-manifest.json');if($null -ne $entry){$state.Edition=$prefix}}}
            if(($null -eq $entry) -or ($entry.Length -gt 2MB)){throw 'manifeste absent du ZIP.'}
            $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
            try{$zipManifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
        }finally{$zip.Dispose()}
        if([string]$zipManifest.Build -cne [string]$Manifest.Build){throw 'Build du ZIP différent de celui du paquet.'}
        $zipHashes=@{}
        foreach($file in @($zipManifest.Files)){$zipHashes[[string]$file.Path]=([string]$file.Sha256).ToUpperInvariant()}
        foreach($file in @($Manifest.Files)){
            if($zipHashes[[string]$file.Path] -cne ([string]$file.Sha256).ToUpperInvariant()){throw ('fichier différent du ZIP qualifié : '+$file.Path)}
        }
        $state.Bound=$true;$state.Reason='rapport Windows PowerShell 5.1 lié au ZIP '+$zipHash+'.'
    }catch{$state.Bound=$false;$state.Reason=$_.Exception.Message}
    return $state
}
function Confirm-Qualification {
    param([object]$Manifest)
    $state=Get-QualificationState $QualificationReport $Package $Manifest
    if($state.Bound){Write-Host ('Qualification : '+$state.Reason);return}
    if($RequireQualification){throw ('Rapport de qualification refusé : '+$state.Reason+' Rien nʼa été modifié.')}
    Write-Warning ('Aucun rapport de qualification Windows lié au ZIP de cette livraison ('+$state.Reason+') Installation non qualifiante : la version préparée sera seulement contrôlée par Domenia-Start -CheckOnly.')
}
function Get-DesktopPowerShell {
    $path=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(Test-Path (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')){$path=Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'}
    return $path
}
function Restore-FromBackup {
    param([string]$Backup)
    $journal=Get-Content -LiteralPath (Join-Path $Backup 'transaction.json') -Raw | ConvertFrom-Json
    if([int]$journal.Format -ne 1 -or [string]::IsNullOrWhiteSpace([string]$journal.Destination)) {throw 'Journal de restauration invalide.'}
    Assert-AppClosed ([string]$journal.Destination)
    if(-not $PSCmdlet.ShouldProcess([string]$journal.Destination,'Restaurer uniquement le code sauvegardé ; conserver les données')) {return}
    [void](Get-SafePackagePath ([string]$journal.Destination) 'wad/Support/.lifecycle.lock')
    [void][IO.Directory]::CreateDirectory((Join-Path ([string]$journal.Destination) 'wad\Support'))
    $lockPath=Join-Path ([string]$journal.Destination) 'wad\Support\.lifecycle.lock'
    $restoreLock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $restorePending=Get-SafePackagePath ([string]$journal.Destination) 'wad/Support/.update.pending'
        if([IO.File]::Exists($restorePending)){
            $pending=[IO.File]::ReadAllText($restorePending)|ConvertFrom-Json
            if([string]$pending.Backup -ine $Backup){throw 'Une autre transaction doit être restaurée en premier.'}
        }
        Restore-CodeTransaction $Backup $journal -VerifyOnly
        Write-CodeJournal $restorePending ([ordered]@{Backup=$Backup;Build=$journal.Build;Status='Restoring'})
        Restore-CodeTransaction $Backup $journal
        Assert-RestoredCode $journal $restoreLock
        $journal.Status='Restored';Write-CodeJournal (Join-Path $Backup 'transaction.json') $journal
        [IO.File]::Delete($restorePending)
    } finally {$restoreLock.Dispose()}
    $restoredBuild='(inconnue)'
    $restoredManifest=Join-Path ([string]$journal.Destination) 'wad\package-manifest.json'
    if([IO.File]::Exists($restoredManifest)){try{$restoredBuild=[string](([IO.File]::ReadAllText($restoredManifest)|ConvertFrom-Json).Build)}catch{}}
    Write-Host ('Code précédent restauré. Version avant : '+[string]$journal.Build+' ; version après : '+$restoredBuild+'.')
    Write-Host 'wad\data et les préférences conservées nʼont pas été modifiés.'
}

if($PSCmdlet.ParameterSetName -eq 'Restore') {
    Restore-FromBackup ([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RestoreBackup).Path))
    return
}
if($PSCmdlet.ParameterSetName -eq 'RestoreLatest') {
    $restoreRoot=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Destination).Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $pendingMarker=Join-Path $restoreRoot 'wad\Support\.update.pending'
    $chosen=''
    if([IO.File]::Exists($pendingMarker)){
        # An interrupted installation is always the one to restore first.
        $chosen=[IO.Path]::GetFullPath([string](([IO.File]::ReadAllText($pendingMarker)|ConvertFrom-Json).Backup))
        $backupPrefix=[IO.Path]::GetFullPath((Get-BackupRoot $restoreRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $chosen.StartsWith($backupPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Le marqueur dʼinstallation désigne une sauvegarde hors de ce dossier Domenia.'}
    }else{
        foreach($candidate in @(Get-CompletedBackups $restoreRoot)){
            if(($candidate.Status -ceq 'Installed') -and ([IO.Path]::GetFullPath($candidate.Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) -ieq $restoreRoot)){$chosen=$candidate.Path;break}
        }
    }
    if(-not $chosen){throw ('Aucune sauvegarde restaurable dans '+(Get-BackupRoot $restoreRoot)+'.')}
    Write-Host ('Sauvegarde restaurée : '+$chosen)
    Restore-FromBackup $chosen
    return
}

$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd([IO.Path]::DirectorySeparatorChar)
if($Install){
    $fullDestination=[IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if([IO.File]::Exists($fullDestination)){throw 'La destination est un fichier : choisissez un dossier vide.'}
    if([IO.Directory]::Exists($fullDestination) -and @([IO.Directory]::EnumerateFileSystemEntries($fullDestination)).Count -gt 0){throw 'Le dossier de destination nʼest pas vide. Pour une mise à jour, relancez sans -Install.'}
    $targetRoot=$fullDestination
}else{
    $targetRoot=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Destination).Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}
if($source -ieq $targetRoot) {throw 'Extrayez le nouveau ZIP dans un dossier distinct de votre Domenia actuel.'}
$sourcePrefix=$source+[IO.Path]::DirectorySeparatorChar;$targetPrefix=$targetRoot+[IO.Path]::DirectorySeparatorChar
if($sourcePrefix.StartsWith($targetPrefix,[StringComparison]::OrdinalIgnoreCase) -or $targetPrefix.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Les dossiers source et destination ne doivent pas être imbriqués.'}
$manifestPath=Get-SourceManifestPath $source
$manifest=Get-CodeManifest $manifestPath
$manifestHash=Get-CodeHash $manifestPath
$desktopPowerShell=Get-DesktopPowerShell

if($Install){
    # FO-20: first installation into an empty folder. Files are copied from the verified package, the lifecycle lock
    # last (neither Domenia.exe nor Domenia-Start.ps1 starts without it), then unblocked and checked with -CheckOnly.
    $copies=New-Object 'System.Collections.Generic.List[object]'
    foreach($entry in @($manifest.Files)){
        $relative=[string]$entry.Path
        $from=Get-SafePackagePath $source $relative
        if(-not [IO.File]::Exists($from) -or (Get-CodeHash $from) -cne [string]$entry.Sha256) {throw "Intégrité du paquet invalide : $relative"}
        if($relative.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
            $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($from,[ref]$tokens,[ref]$errors)
            if(@($errors).Count -gt 0) {throw "Script PowerShell invalide : $relative ; $($errors[0].Message)"}
        }
        $copies.Add([pscustomobject]@{Path=$relative;From=$from;Sha256=([string]$entry.Sha256).ToUpperInvariant()})
    }
    Confirm-Qualification $manifest
    Write-Host ('Première installation de la version '+[string]$manifest.Build+' dans '+$targetRoot+' : '+($copies.Count+1)+' fichiers.')
    if(-not $PSCmdlet.ShouldProcess($targetRoot,'Installer Domenia dans un dossier vide')) {return}
    if($askOperator){
        $answer=Read-OperatorAnswer ('Installer ces '+($copies.Count+1)+' fichiers ? (O/N)')
        if($answer -ne $true){Write-Host 'Installation annulée : aucun fichier écrit.';return}
    }
    $created=-not [IO.Directory]::Exists($targetRoot)
    [void][IO.Directory]::CreateDirectory($targetRoot)
    $written=New-Object 'System.Collections.Generic.List[string]'
    # Code first, then the manifest, then the lifecycle lock that makes the copy startable.
    $ordered=@($copies|Where-Object{$_.Path -cne 'wad/Support/.lifecycle.lock'})+@([pscustomobject]@{Path='wad/package-manifest.json';From=$manifestPath;Sha256=$manifestHash})+@($copies|Where-Object{$_.Path -ceq 'wad/Support/.lifecycle.lock'})
    try{
        foreach($copy in $ordered){
            $to=Get-SafePackagePath $targetRoot ([string]$copy.Path)
            if([IO.File]::Exists($to)){throw ('Fichier apparu pendant lʼinstallation : '+$copy.Path)}
            Copy-CodeAtomically ([string]$copy.From) $to
            $written.Add($to)
            if((Get-CodeHash $to) -ine [string]$copy.Sha256){throw ('Vérification après copie en échec : '+$copy.Path)}
            Unblock-File -LiteralPath $to -ErrorAction Stop
        }
        Assert-CodeVersion $targetRoot $manifest
        & $desktopPowerShell -NoLogo -NoProfile -STA -NonInteractive -File (Join-Path $targetRoot 'wad\Domenia-Start.ps1') -CheckOnly
        if($LASTEXITCODE -ne 0){throw 'La version installée ne passe pas le contrôle de démarrage (Domenia-Start -CheckOnly).'}
    }catch{
        $failure=$_.Exception.Message
        # The folder was empty: only the files written here are removed, then the folders left empty.
        foreach($path in @($written.ToArray())){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
        foreach($folder in @([IO.Directory]::GetDirectories($targetRoot,'*',[IO.SearchOption]::AllDirectories)|Sort-Object -Property Length -Descending)){if(@([IO.Directory]::EnumerateFileSystemEntries($folder)).Count -eq 0){[IO.Directory]::Delete($folder)}}
        if($created -and @([IO.Directory]::EnumerateFileSystemEntries($targetRoot)).Count -eq 0){[IO.Directory]::Delete($targetRoot)}
        throw ('Installation interrompue, fichiers copiés retirés : '+$failure)
    }
    Write-Host ('Domenia '+[string]$manifest.Build+' installé dans '+$targetRoot+' ; fichiers débloqués et contrôle de démarrage réussi.')
    $shortcutTargets=@(
        [pscustomobject]@{Label='sur le Bureau';Folder=[Environment]::GetFolderPath('DesktopDirectory')},
        [pscustomobject]@{Label='dans le menu Démarrer';Folder=[Environment]::GetFolderPath('Programs')}
    )
    foreach($shortcut in $shortcutTargets){
        $choice=$null
        if($Shortcuts -ceq 'Oui'){$choice=$true}elseif($Shortcuts -ceq 'Non'){$choice=$false}elseif($askOperator){$choice=Read-OperatorAnswer ('Créer un raccourci Domenia '+$shortcut.Label+' ? (O/N)')}
        if($choice -ne $true){
            if($null -eq $choice){Write-Host ('Raccourci '+$shortcut.Label+' non créé : aucune réponse.')}else{Write-Host ('Raccourci '+$shortcut.Label+' non créé.')}
            continue
        }
        if([string]::IsNullOrWhiteSpace([string]$shortcut.Folder) -or -not [IO.Directory]::Exists([string]$shortcut.Folder)){Write-Warning ('Dossier introuvable : raccourci '+$shortcut.Label+' non créé.');continue}
        $link=Join-Path ([string]$shortcut.Folder) 'Domenia.lnk'
        if([IO.File]::Exists($link)){Write-Host ('Un raccourci Domenia existe déjà '+$shortcut.Label+' : il est conservé tel quel.');continue}
        $shell=New-Object -ComObject WScript.Shell
        try{
            $item=$shell.CreateShortcut($link)
            $item.TargetPath=Join-Path $targetRoot 'Domenia.exe';$item.WorkingDirectory=$targetRoot;$item.IconLocation=(Join-Path $targetRoot 'wad\Domenia.ico')+',0';$item.Description='Domenia'
            $item.Save()
        }finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
        Write-Host ('Raccourci créé '+$shortcut.Label+' : '+$link)
    }
    return
}

if(-not (Test-Path -LiteralPath (Join-Path $targetRoot 'wad\Domenia-Core.ps1') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $targetRoot 'wad\ADCC-Core.ps1') -PathType Leaf)) {throw 'Destination incorrecte : choisissez le dossier Domenia contenant wad\Domenia-Core.ps1. Pour une première installation dans un dossier vide, ajoutez -Install.'}
Assert-AppClosed $targetRoot
$activeManifestPath=Get-SafePackagePath $targetRoot 'wad/package-manifest.json'
$activeManifest=$null;$activeBuild=''
if([IO.File]::Exists($activeManifestPath)){
    $activeManifest=Get-CodeManifest $activeManifestPath -Previous;$activeBuild=[string]$activeManifest.Build
    Assert-CodeVersion $targetRoot $activeManifest
    if($activeBuild -ceq [string]$manifest.Build){throw 'Cette version est déjà active. Utilisez une livraison portant un nouveau Build.'}
}
Confirm-Qualification $manifest
$plan=New-Object 'System.Collections.Generic.List[object]';$preparation=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
foreach($entry in @($manifest.Files)) {
    $relative=[string]$entry.Path
    if($seen.ContainsKey($relative)) {throw 'Entrée en double dans le manifeste.'};$seen[$relative]=$true
    $from=Get-SafePackagePath $source $relative;$to=Get-SafePackagePath $targetRoot $relative
    if(-not [IO.File]::Exists($from) -or (Get-CodeHash $from) -cne [string]$entry.Sha256) {throw "Intégrité du paquet invalide : $relative"}
    if($relative.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($from,[ref]$tokens,[ref]$errors)
        if(@($errors).Count -gt 0) {throw "Script PowerShell invalide : $relative ; $($errors[0].Message)"}
    }
    if($relative -eq 'wad/Support/.lifecycle.lock'){
        $preparation.Add([pscustomobject]@{Path=$relative;From=$from;Sha256=[string]$entry.Sha256});continue
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
    $preparedFrom=if($exists -and $entry.PreserveExisting){$to}elseif($sourceOverride){$sourceOverride}else{$from}
    $preparedHash=if($preparedFrom -eq $from){[string]$entry.Sha256}else{Get-CodeHash $preparedFrom}
    $preparation.Add([pscustomobject]@{Path=$relative;From=$preparedFrom;Sha256=$preparedHash})
    if($exists -and [bool]$entry.PreserveExisting) {Write-Host ('Conservé : '+$relative);continue}
    $oldHash=if($exists){Get-CodeHash $to}else{''}
    if($oldHash -ceq [string]$entry.Sha256) {continue}
    $plan.Add([pscustomobject]@{Path=$relative;Existed=$exists;OldSha256=$oldHash;NewSha256=$(if($sourceOverride){Get-CodeHash $sourceOverride}else{[string]$entry.Sha256});SourceOverride=$sourceOverride})
}
# Preserve a package manifest together with the code, excluding the manifest from its own hash list.
$manifestRelative='wad/package-manifest.json';$manifestTarget=Get-SafePackagePath $targetRoot $manifestRelative
$manifestExists=[IO.File]::Exists($manifestTarget)
$plan.Add([pscustomobject]@{Path=$manifestRelative;Existed=$manifestExists;OldSha256=$(if($manifestExists){Get-CodeHash $manifestTarget}else{''});NewSha256=$manifestHash})
$activeLabel=if($activeBuild){$activeBuild}else{'(inconnue)'}
Write-Host ('Version active : '+$activeLabel+' ; version préparée : '+[string]$manifest.Build+'.')
Write-Host ('Fichiers à installer : '+$plan.Count)
foreach($entry in $plan){Write-Host ('  '+$entry.Path)}
if(-not $PSCmdlet.ShouldProcess($targetRoot,'Sauvegarder le code puis installer la mise à jour, sans toucher à wad\data')) {return}
if($askOperator){
    $answer=Read-OperatorAnswer ('Installer ces '+$plan.Count+' fichiers ? (O/N)')
    if($answer -ne $true){Write-Host 'Installation annulée : aucun fichier modifié.';return}
}
Assert-AppClosed $targetRoot

$backupParent=Get-BackupRoot $targetRoot
# Validate maintenance path before creating it (junction protection).
[void](Get-SafePackagePath $targetRoot 'wad/maintenance')
if(Test-Path -LiteralPath $backupParent) {if((Get-Item -LiteralPath $backupParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier de sauvegarde redirigé par un lien.'}}
$backup=Join-Path $backupParent ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $backup 'files'))
$staged=Join-Path $backup 'prepared'
[void][IO.Directory]::CreateDirectory($staged)
# Freeze every declared file, including unchanged files and preserved settings, before taking the activation lock.
$stagedHashes=@{}
foreach($entry in $preparation){
    $prepared=Get-SafePackagePath $staged ([string]$entry.Path)
    Copy-CodeAtomically ([string]$entry.From) $prepared
    $actual=Get-CodeHash $prepared
    if($actual -ine [string]$entry.Sha256){throw ('Le paquet a changé pendant sa préparation : '+$entry.Path)}
    $stagedHashes[[string]$entry.Path]=$actual
}
$stagedManifestPath=Get-SafePackagePath $staged 'wad/package-manifest.json'
Copy-CodeAtomically $manifestPath $stagedManifestPath
if((Get-CodeHash $stagedManifestPath) -ine $manifestHash){throw 'Le manifeste a changé pendant la préparation.'}
Assert-CodeVersion $staged $manifest
. (Join-Path $staged 'wad/modules/Domenia-Common.Model.ps1')
. (Join-Path $staged 'wad/modules/Domenia-Release.Model.ps1')
$installDecision=Get-DomeniaInstallPlan -Manifest $manifest -StagedHashes $stagedHashes -ActiveBuild $activeBuild
if(-not $installDecision.Allowed){throw ([string]::Join('; ',[string[]]$installDecision.Blockers))}
# FI-06: the prepared version must start (-CheckOnly: hashes, parser, imports); no test suite runs on this workstation.
& $desktopPowerShell -NoLogo -NoProfile -STA -NonInteractive -File (Join-Path $staged 'wad/Domenia-Start.ps1') -CheckOnly
if($LASTEXITCODE -ne 0){throw 'La version préparée ne peut pas démarrer. Le code actif est inchangé.'}
[void](Get-SafePackagePath $targetRoot 'wad/Support/.lifecycle.lock')
[void][IO.Directory]::CreateDirectory((Join-Path $targetRoot 'wad\Support'))
$lockPath=Join-Path $targetRoot 'wad\Support\.lifecycle.lock'
$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$pendingPath=Join-Path $targetRoot 'wad\Support\.update.pending'
if([IO.File]::Exists($pendingPath)){$lock.Dispose();throw 'Installation précédente incomplète. Lancez dʼabord -RestoreLatest -Destination avec ce dossier Domenia.'}
$journal=[ordered]@{Format=1;Build=[string]$manifest.Build;Created=(Get-Date).ToString('o');Destination=$targetRoot;Status='Prepared';Files=$plan.ToArray()}
$journalPath=Join-Path $backup 'transaction.json'
$encoding=[Text.UTF8Encoding]::new($false)
$started=$false
try {
    Assert-AppClosed $targetRoot
    if($null -ne $activeManifest){Assert-CodeVersion $targetRoot $activeManifest $lock}
    Assert-CodeVersion $staged $manifest
    # Backup all original code before the first replacement.
    foreach($entry in $plan) {
        $to=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if([bool]$entry.Existed) {
            if((Get-CodeHash $to) -cne [string]$entry.OldSha256) {throw 'Fichier destination modifié pendant la préparation.'}
            $saved=Get-SafePackagePath (Join-Path $backup 'files') ([string]$entry.Path)
            Copy-CodeAtomically $to $saved
        } elseif([IO.File]::Exists($to)) {throw 'Un fichier destination est apparu pendant la préparation.'}
    }
    Write-CodeJournal $journalPath $journal
    [IO.File]::Copy($PSCommandPath,(Join-Path $backup 'RESTAURER-CODE.ps1'),$false)
    Write-CodeJournal $pendingPath ([ordered]@{Backup=$backup;Build=$manifest.Build;Status='Installing'})
    $started=$true
    foreach($entry in $plan) {
        $from=Get-SafePackagePath $staged ([string]$entry.Path);$to=Get-SafePackagePath $targetRoot ([string]$entry.Path)
        if((Get-CodeHash $from) -cne [string]$entry.NewSha256) {throw 'Le paquet source a changé pendant lʼinstallation.'}
        Copy-CodeAtomically $from $to
        if((Get-CodeHash $to) -cne [string]$entry.NewSha256) {throw 'Vérification après copie en échec.'}
    }
    Assert-CodeVersion $targetRoot $manifest $lock
    if((Get-CodeHash $manifestTarget) -ine $manifestHash){throw 'Manifeste actif différent de la version préparée.'}
    $journal.Status='Installed'
    Write-CodeJournal $journalPath $journal
    [IO.File]::Delete($pendingPath)
}
catch {
    $failure=$_.Exception.Message
    if($started) {
        try {Restore-CodeTransaction $backup $journal;Assert-RestoredCode $journal $lock;$journal.Status='Restored';Write-CodeJournal $journalPath $journal;[IO.File]::Delete($pendingPath);Write-Warning 'Installation en échec : ancien code restauré.'}
        catch {Write-Warning ('Restauration automatique incomplète : '+$_.Exception.Message+'. Sauvegarde : '+$backup)}
    }
    throw ('Mise à jour interrompue : '+$failure)
}
finally {$lock.Dispose()}
# UX-29: the prepared copy is no longer needed once the new version is active; only complete backups are rotated.
$cleanup=@()
try {
    if([IO.Directory]::Exists($staged)){Remove-Item -LiteralPath $staged -Recurse -Force}
    $cleanup=@(Invoke-BackupRotation $targetRoot $backup $keptBackups)
} catch {Write-Warning ('Nettoyage des sauvegardes incomplet : '+$_.Exception.Message)}
Write-Host ('Mise à jour installée. Version avant : '+$activeLabel+' ; version après : '+[string]$manifest.Build+'.')
Write-Host ('Code précédent sauvegardé dans '+$backup+' ('+$keptBackups+' sauvegardes complètes au plus ; '+$cleanup.Count+' ancienne(s) retirée(s)).')
Write-Host ('Retour arrière : wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination '''+$targetRoot+'''')
Write-Host 'Lancez Domenia.exe. Les anciens fichiers DEV ne sont pas supprimés automatiquement.'
