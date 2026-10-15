#requires -Version 5.1
<# Installs only manifest-listed code files. Existing settings and wad\data are never replaced.
   Shipped in PROD and DEV as wad\Support\INSTALLER-MISE-A-JOUR.ps1; it runs from an extracted package (source = the
   folder that contains Domenia.exe and wad) or from an installed copy (-RestoreLatest).
   FI-06: no test suite ever runs on the target workstation. The prepared version is checked with Domenia-Start.ps1
   -CheckOnly; a Windows qualification report (release_guard format) is verified when supplied, bound to the SHA-256
   of the delivered ZIP. Without it a warning is shown; -RequireQualification refuses instead.
   UX-29: explicit answer before any write, prepared copy removed after success, five complete backups kept.
   FO-20: -Install copies a package into an empty folder (hashes checked, files unblocked, Domenia-Start -CheckOnly);
   shortcuts are offered and never created without an answer. -Confirm:$false waives every question, the shortcut one
   included: -Shortcuts Oui|Non then gives the answer.
   A supplied qualification report that is refused stops the installation before any write.
   Exit codes: 0 done (or -WhatIf), 1 error, 2 nothing installed (refused or unanswered question).
   -WhatIf performs verification and lists the plan without writing.
   Restore is hash-guarded: it refuses to discard an independently modified file.
   Point 144: -Uninstall removes an installed copy (code files that still carry their manifest hash, then the manifest,
   then the lifecycle lock, and the Domenia.lnk shortcuts aimed at it). Local data goes only on an explicit choice:
   -LocalData Supprimer (preferences, wad\data, code backups) and -ProfileData Supprimer (base, logs and receipts of the
   Windows profile, shared by every copy of this account). Without an answer, or with -Confirm:$false and Demander, the
   data is kept. No administrator right is needed for a copy the user installed.
   Point 143: the data schema transition of an update is announced before the answer and kept in the journal.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium',DefaultParameterSetName='Update')]
param(
    [Parameter(Mandatory,ParameterSetName='Update')]
    [Parameter(Mandatory,ParameterSetName='Install')]
    [Parameter(Mandatory,ParameterSetName='RestoreLatest')]
    [Parameter(Mandatory,ParameterSetName='Uninstall')]
    [string]$Destination,
    [Parameter(Mandatory,ParameterSetName='Install')][switch]$Install,
    [Parameter(Mandatory,ParameterSetName='Restore')][string]$RestoreBackup,
    [Parameter(Mandatory,ParameterSetName='RestoreLatest')][switch]$RestoreLatest,
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][string]$Package='',
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][string]$QualificationReport='',
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][switch]$RequireQualification,
    [Parameter(ParameterSetName='Install')][ValidateSet('Demander','Oui','Non')][string]$Shortcuts='Demander',
    [Parameter(Mandatory,ParameterSetName='Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName='Uninstall')][ValidateSet('Demander','Conserver','Supprimer')][string]$LocalData='Demander',
    [Parameter(ParameterSetName='Uninstall')][ValidateSet('Demander','Conserver','Supprimer')][string]$ProfileData='Demander'
)
$ErrorActionPreference='Stop'
# -Confirm:$false waives the question; an explicit -Confirm already asked through ShouldProcess.
$askOperator=-not $PSBoundParameters.ContainsKey('Confirm')
# Relative paths follow the PowerShell location (cd), not the process directory.
if($Package){$Package=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($Package)}
if($QualificationReport){$QualificationReport=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($QualificationReport)}
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
function Stop-Cancelled {
    # Nothing was written. Exit code 2 tells a scripted deployment that the update did not happen.
    param([string]$Message)
    Write-Host $Message
    exit 2
}
function Get-BackupRoot {param([string]$Root) return (Join-Path $Root 'wad\maintenance\backups')}
function Get-DataSchemaVersion {
    # Point 143: DataSchemaVersion declared by wad\Domenia.release.json of a Domenia folder; '' when absent or unreadable
    # (version without release contract, file redirected, too large or invalid).
    param([string]$Root)
    try{
        $info=[IO.FileInfo]::new((Join-Path $Root 'wad\Domenia.release.json'))
        if((-not $info.Exists) -or ($info.Length -gt 1MB) -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)){return ''}
        $value=([IO.File]::ReadAllText($info.FullName)|ConvertFrom-Json).DataSchemaVersion
        if(($value -is [int]) -or ($value -is [long])){return [string]$value}
    }catch{}
    return ''
}
function Import-PackageModel {
    # Dot-sources one pure rule file of the package being installed, after checking it against the package manifest
    # (same bytes as the staged copy loaded later). Nothing of the active installation is executed.
    param([string]$Source,[object]$Manifest,[string]$Relative)
    $entry=@($Manifest.Files|Where-Object{[string]$_.Path -ceq $Relative})
    if($entry.Count -ne 1){throw ('Règle absente du manifeste : '+$Relative)}
    $path=Get-SafePackagePath $Source $Relative
    if((Get-CodeHash $path) -cne [string]$entry[0].Sha256){throw ('Intégrité du paquet invalide : '+$Relative)}
    return $path
}
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
    # written before the first replacement): it is an abandoned preparation and is removed. The prepared copy kept by
    # the backups of earlier installers is removed from the complete backups that stay (files and journal are kept).
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
        if($drop){Remove-Item -LiteralPath $candidate.Path -Recurse -Force;$removed.Add($candidate.Name);continue}
        $prepared=Join-Path $candidate.Path 'prepared'
        if($isComplete -and [IO.Directory]::Exists($prepared)){
            if((Get-Item -LiteralPath $prepared -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            Remove-Item -LiteralPath $prepared -Recurse -Force
        }
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
    # Offline check of a release_guard report, with the same rules as engineering/d120/release_guard.py require_evidence:
    # Windows PowerShell 5.1, campaign PASS, same Build, no fixture, archives bound by SHA-256 (DEV and PROD when the
    # report lists both), each required scenario executed, PASS, timed, with its evidence hash and bound to an archive
    # of the report (prod.standalone to the PROD one). The ZIP given in -Package must be one of them: each member listed
    # by its manifest carries the manifest SHA-256, and that manifest carries the hashes of the package being installed.
    # A local report is not a signature: it proves neither origin nor author.
    param([string]$ReportPath,[string]$PackagePath,[object]$Manifest)
    $state=[pscustomobject]@{Provided=(-not [string]::IsNullOrWhiteSpace($ReportPath));Bound=$false;Reason='';ArchiveSha256='';Edition=''}
    if(-not $state.Provided){$state.Reason='aucun rapport fourni (-QualificationReport).';return $state}
    if(-not $PackagePath){$state.Reason='le ZIP livré (-Package) est nécessaire pour lier le rapport à son empreinte.';return $state}
    $hex={param($Value,[string]$What) $text=[string]$Value;if(($Value -isnot [string]) -or ($text -cnotmatch '^[0-9a-fA-F]{64}$')){throw ($What+' : empreinte SHA-256 attendue.')};return $text.ToLowerInvariant()}
    $utc={
        param($Value,[string]$What)
        if($Value -is [datetime]){return ([DateTimeOffset]$Value).UtcDateTime}
        if(($Value -isnot [string]) -or ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$')){throw ('horodatage absent ou illisible : '+$What)}
        return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    }
    try{
        $reportFile=[IO.FileInfo]::new($ReportPath)
        $zipFile=[IO.FileInfo]::new($PackagePath)
        if((-not $reportFile.Exists) -or ($reportFile.Length -gt 16MB)){throw 'rapport absent ou trop volumineux.'}
        if(-not $zipFile.Exists){throw 'ZIP absent.'}
        $zipHash=(Get-CodeHash $zipFile.FullName).ToLowerInvariant()
        $state.ArchiveSha256=$zipHash
        $report=[IO.File]::ReadAllText($reportFile.FullName)|ConvertFrom-Json
        if(($null -ne $report.PSObject.Properties['FixtureOnly']) -and ($report.FixtureOnly -ne $false)){throw 'rapport de test (FixtureOnly) : ce nʼest pas une qualification.'}
        # Edition of the delivered ZIP, read from its single manifest (prod/ or dev/ root).
        Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($zipFile.FullName)
        try{
            $manifestEntries=@($zip.Entries|Where-Object{$_.FullName -match '^(prod|dev)/wad/package-manifest\.json$'})
            if($manifestEntries.Count -ne 1){throw 'manifeste unique absent du ZIP.'}
            $zipEdition=$manifestEntries[0].FullName.Substring(0,$manifestEntries[0].FullName.IndexOf('/'))
            if($manifestEntries[0].Length -gt 2MB){throw 'manifeste du ZIP trop volumineux.'}
            $reader=[IO.StreamReader]::new($manifestEntries[0].Open(),[Text.Encoding]::UTF8)
            try{$zipManifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
            # Every member listed by the ZIP manifest is present with that SHA-256: a ZIP reduced to its manifest is refused.
            $hasher=[Security.Cryptography.SHA256]::Create()
            try{
                foreach($file in @($zipManifest.Files)){
                    $member=$zip.GetEntry($zipEdition+'/'+[string]$file.Path)
                    if($null -eq $member){throw ('fichier absent du ZIP : '+$file.Path)}
                    $stream=$member.Open()
                    try{$memberHash=[BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose()}
                    if($memberHash -ine [string]$file.Sha256){throw ('empreinte différente dans le ZIP : '+$file.Path)}
                }
            }finally{$hasher.Dispose()}
        }finally{$zip.Dispose()}
        $state.Edition=$zipEdition
        $bound=@{}
        if($null -eq $report.PSObject.Properties['Archives']){
            if((& $hex $report.ArchiveSHA256 'ArchiveSHA256') -cne $zipHash){throw 'rapport non lié au ZIP fourni.'}
            $bound[$zipHash]=$zipEdition
        }else{
            $archives=@($report.Archives)
            if(($null -eq $report.Archives) -or ($archives.Count -eq 0)){throw 'Archives : liste attendue.'}
            foreach($archive in $archives){
                $edition=[string]$archive.Edition
                if(($edition -cne 'dev') -and ($edition -cne 'prod')){throw ('édition inconnue dans le rapport : '+$edition)}
                $sha=& $hex $archive.SHA256 'Archives[].SHA256'
                if($bound.ContainsKey($sha) -or (@($bound.Values) -ccontains $edition)){throw 'archive déclarée deux fois dans le rapport.'}
                if(($null -ne $archive.PSObject.Properties['SHA256End']) -and ($null -ne $archive.SHA256End) -and ((& $hex $archive.SHA256End 'Archives[].SHA256End') -cne $sha)){throw ('archive modifiée pendant la campagne : '+$edition)}
                $bound[$sha]=$edition
            }
            if((@($bound.Values) -cnotcontains 'dev') -or (@($bound.Values) -cnotcontains 'prod')){throw 'campagne liée aux archives DEV et PROD requise.'}
            if(-not $bound.ContainsKey($zipHash)){throw 'rapport non lié au ZIP fourni.'}
            if($bound[$zipHash] -cne $zipEdition){throw 'édition du rapport différente de celle du ZIP.'}
            if(($null -ne $report.PSObject.Properties['ArchiveSHA256']) -and ($null -ne $report.ArchiveSHA256) -and (-not $bound.ContainsKey((& $hex $report.ArchiveSHA256 'ArchiveSHA256')))){throw 'ArchiveSHA256 hors des archives du rapport.'}
        }
        if([string]$report.Build -cne [string]$Manifest.Build){throw 'Build du rapport différent de celui du paquet.'}
        if([string]$zipManifest.Build -cne [string]$Manifest.Build){throw 'Build du ZIP différent de celui du paquet.'}
        $reportHost=$report.Host
        if(($null -eq $reportHost) -or ([string]$reportHost.Platform -cne 'Windows') -or ([string]$reportHost.PSEdition -cne 'Desktop') -or (-not ([string]$reportHost.PSVersion).StartsWith('5.1.'))){throw 'preuve Windows PowerShell 5.1 requise.'}
        if([string]$report.OverallStatus -cne 'PASS'){throw 'campagne inachevée ou en échec.'}
        $byId=@{}
        foreach($scenario in @($report.Scenarios)){
            if($null -eq $scenario){throw 'Scenarios : objet attendu.'}
            $id=[string]$scenario.Id
            if((-not $id) -or $byId.ContainsKey($id)){throw 'scénario de preuve sans identifiant ou dupliqué.'}
            if(@('PASS','FAIL','SKIP','NOT_EXECUTED') -cnotcontains [string]$scenario.Status){throw ('statut de scénario inconnu : '+$id)}
            $byId[$id]=$scenario
        }
        foreach($id in $qualificationScenarios){
            $scenario=$byId[$id]
            if(($null -eq $scenario) -or ([string]$scenario.Status -cne 'PASS') -or ($scenario.Executed -isnot [bool]) -or (-not $scenario.Executed)){throw ('scénario requis absent, non exécuté ou en échec : '+$id)}
            if((& $utc $scenario.EndedUtc $id) -lt (& $utc $scenario.StartedUtc $id)){throw ('horodatage incohérent : '+$id)}
            [void](& $hex $scenario.EvidenceSHA256 ('empreinte de preuve de '+$id))
            $target=$null;if($null -ne $scenario.PSObject.Properties['ArchiveSHA256']){$target=$scenario.ArchiveSHA256}
            if($null -ne $report.PSObject.Properties['Archives']){
                if($null -eq $target){throw ('scénario non lié à une archive : '+$id)}
                $target=& $hex $target ($id+'.ArchiveSHA256')
                if(-not $bound.ContainsKey($target)){throw ('scénario lié à une archive hors rapport : '+$id)}
                if(($id -ceq 'prod.standalone') -and ($bound[$target] -cne 'prod')){throw 'prod.standalone doit viser lʼarchive PROD.'}
                if(($null -ne $scenario.PSObject.Properties['Edition']) -and ($null -ne $scenario.Edition) -and ([string]$scenario.Edition -cne $bound[$target])){throw ('édition du scénario incohérente : '+$id)}
            }elseif(($null -ne $target) -and ((& $hex $target ($id+'.ArchiveSHA256')) -cne $zipHash)){throw ('scénario lié à une autre archive : '+$id)}
        }
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
    # A report given by the operator and refused is a contrary proof (failed campaign, other build, other ZIP): never
    # continue on it. Only a missing report keeps the non-qualifying installation (integrator decision).
    if($state.Provided){throw ('Rapport de qualification fourni refusé : '+$state.Reason+' Rien nʼa été modifié. Corrigez le rapport ou relancez sans -QualificationReport.')}
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
    # Point 143: what the restored code will do with a base that the installed version may have migrated.
    $notice=$journal.PSObject.Properties['RestoreNotice']
    if(($null -ne $notice) -and -not [string]::IsNullOrWhiteSpace([string]$notice.Value)){Write-Host ([string]$notice.Value)}
    else{Write-Host 'Base locale : schéma de données non consigné par cette sauvegarde. Si la version restaurée refuse la base, restaurez dans Domenia la sauvegarde de la base faite avant la migration.'}
}

function ConvertTo-LongPath {
    # Long form of an existing path (8.3 segments expanded by the file system), compared case-insensitively. A segment
    # that cannot be resolved is kept as given.
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $rootPart=[IO.Path]::GetPathRoot($full)
    $current=$rootPart
    foreach($segment in @($full.Substring($rootPart.Length).Split([IO.Path]::DirectorySeparatorChar)|Where-Object{$_})){
        $next=Join-Path $current $segment
        try{$found=@([IO.Directory]::GetFileSystemEntries($current,$segment));if($found.Count -eq 1){$next=$found[0]}}catch{}
        $current=$next
    }
    return $current
}
function Get-DataFolder {
    # Absolute folder of one data category under a root, $null when absent. Refuses a path leaving the root and any link
    # or junction in the folder or below it, before anything is deleted.
    param([string]$Root,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Root)){return $null}
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $prefix $Relative))
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw ('Dossier de données hors de son emplacement : '+$Relative)}
    $info=[IO.DirectoryInfo]::new($path)
    if(-not $info.Exists){return $null}
    $pending=New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push($info)
    while($pending.Count -gt 0){
        $folder=$pending.Pop()
        if($folder.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Lien ou jonction dans les données, rien nʼest supprimé : '+$folder.FullName)}
        foreach($file in $folder.GetFiles()){if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Lien dans les données, rien nʼest supprimé : '+$file.FullName)}}
        foreach($child in $folder.GetDirectories()){$pending.Push($child)}
    }
    return $path
}
function Remove-EmptyFolders {
    # Removes the empty folders below Root (links are never entered), then Root itself when it is empty.
    param([string]$Root)
    $info=[IO.DirectoryInfo]::new($Root)
    if((-not $info.Exists) -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)){return}
    foreach($child in $info.GetDirectories()){if(-not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)){Remove-EmptyFolders $child.FullName}}
    if(@([IO.Directory]::EnumerateFileSystemEntries($Root)).Count -eq 0){[IO.Directory]::Delete($Root)}
}
function Assert-NoDomeniaRunning {
    # The profile data is shared by every copy of Domenia of this account: no copy may be running while it is removed.
    if(@(Get-Process -Name Domenia,ADCC -ErrorAction SilentlyContinue).Count -gt 0){throw 'Une copie de Domenia est ouverte : fermez toutes les copies avant de supprimer les données du profil. Rien nʼest supprimé.'}
    foreach($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='powershell_ise.exe' OR Name='pwsh.exe'" -ErrorAction Stop)){
        if([int]$process.ProcessId -eq $PID){continue}
        if(([string]$process.CommandLine) -match '(?i)(Domenia|ADCC)-(Core|Start)\.ps1'){throw ('Domenia est encore lancé : PID '+$process.ProcessId+'. Fermez toutes les copies avant de supprimer les données du profil. Rien nʼest supprimé.')}
    }
}
function Get-OpenReceipts {
    # Write receipts of the profile that are still to be checked: Stage outside the terminal stages of Domenia, or a file
    # that cannot be read as a receipt. Such a receipt is the only trace that an AD write may have left without
    # verification, so the profile data is never deleted while one remains. $Folder: receipts folder ($null when absent).
    param([AllowNull()][string]$Folder)
    $open=New-Object 'System.Collections.Generic.List[string]'
    $count=0
    if(-not [string]::IsNullOrWhiteSpace($Folder)){
        foreach($file in [IO.Directory]::EnumerateFiles($Folder,'*.json',[IO.SearchOption]::AllDirectories)){
            $count++
            $stage=''
            try{
                if(([IO.FileInfo]::new($file)).Length -le 65536){
                    $receipt=[IO.File]::ReadAllText($file)|ConvertFrom-Json
                    if(($null -ne $receipt) -and ([string]$receipt.Format -eq '1')){$stage=[string]$receipt.Stage}
                }
            }catch{$stage=''}
            if(@('Verified','NotSent','Reviewed','Delivered') -notcontains $stage){$open.Add($file.Substring($Folder.TrimEnd([IO.Path]::DirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar))}
        }
    }
    return [pscustomobject]@{Count=$count;Open=$open.ToArray()}
}
function Resolve-DataChoice {
    # Explicit answer for one data category: Conserver unless the operator says to delete.
    param([string]$Choice,[string]$Question,[string]$Switch,[bool]$Present)
    # ValidateSet ignores case: the value gets its canonical spelling before the case-sensitive comparisons below and
    # in Get-DomeniaUninstallPlan ('-LocalData supprimer' must delete, '-LocalData demander' must ask).
    foreach($canonical in @('Demander','Conserver','Supprimer')){if($Choice -ieq $canonical){$Choice=$canonical}}
    if($Choice -cne 'Demander'){return $Choice}
    if(-not $Present){return 'Conserver'}
    if(-not $askOperator){Write-Host ('Données conservées : question non posée (-Confirm:$false). Ajoutez '+$Switch+' Supprimer pour les supprimer.');return 'Conserver'}
    $answer=Read-OperatorAnswer $Question
    if($answer -eq $true){return 'Supprimer'}
    if($null -eq $answer){Write-Host 'Aucune réponse : données conservées.'}
    return 'Conserver'
}
function Invoke-DomeniaUninstall {
    param([string]$Root)
    $targetRoot=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if(-not (Test-Path -LiteralPath (Join-Path $targetRoot 'wad\Domenia-Core.ps1') -PathType Leaf)){throw 'Destination incorrecte : choisissez le dossier Domenia contenant wad\Domenia-Core.ps1. Rien nʼest supprimé.'}
    $manifestPath=Get-SafePackagePath $targetRoot 'wad/package-manifest.json'
    if(-not [IO.File]::Exists($manifestPath)){throw 'Manifeste absent : cette copie nʼa pas été installée par ce programme. Rien nʼest supprimé.'}
    Assert-AppClosed $targetRoot
    $activeManifest=Get-CodeManifest $manifestPath -Previous
    # The removal rule comes from this installer's own package, checked against its manifest.
    $ownManifest=Get-CodeManifest (Get-SourceManifestPath $source)
    . (Import-PackageModel $source $ownManifest 'wad/modules/Domenia-Common.Model.ps1')
    . (Import-PackageModel $source $ownManifest 'wad/modules/Domenia-Release.Model.ps1')
    # A DEV tree carries its tools and its Windows suites folder; neither is ever run here, only detected.
    $devTree=([IO.Directory]::Exists((Join-Path $targetRoot 'tools')) -or [IO.Directory]::Exists([IO.Path]::Combine($targetRoot,'wad','tests')))
    $pendingPath=Join-Path $targetRoot 'wad\Support\.update.pending'
    $observed=@{}
    foreach($entry in @($activeManifest.Files)){
        $relative=[string]$entry.Path
        if(($relative -ceq 'wad/Support/.lifecycle.lock') -or [bool]$entry.PreserveExisting){continue}
        $path=Get-SafePackagePath $targetRoot $relative
        if([IO.File]::Exists($path)){$observed[$relative]=Get-CodeHash $path}
    }
    $profileRoot=[Environment]::GetFolderPath('LocalApplicationData')
    $preview=Get-DomeniaUninstallPlan -Manifest $activeManifest -Observed $observed -LocalData Supprimer -ProfileData Supprimer -DevTree $devTree -PendingInstall ([IO.File]::Exists($pendingPath))
    if(-not $preview.Allowed){throw ([string]::Join(' ',[string[]]$preview.Blockers))}
    # Data really present, so that a question is asked only when there is something to keep or delete.
    $localPresent=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in @($preview.LocalFolders)){if($null -ne (Get-DataFolder $targetRoot $relative)){$localPresent.Add($relative)}}
    foreach($relative in @($preview.RemoveSettings)){if([IO.File]::Exists((Get-SafePackagePath $targetRoot $relative))){$localPresent.Add($relative)}}
    $profilePresent=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in @($preview.ProfileFolders)){if($null -ne (Get-DataFolder $profileRoot $relative)){$profilePresent.Add($relative)}}
    Write-Host ('Désinstallation de Domenia '+[string]$preview.Build+' dans '+$targetRoot+' : '+@($preview.RemoveCode).Count+' fichier(s) de code.')
    if(@($preview.KeepModified).Count -gt 0){Write-Host ('Fichiers modifiés depuis lʼinstallation, conservés : '+[string]::Join(', ',[string[]]$preview.KeepModified))}
    Write-Host ('Données de ce dossier présentes : '+$(if($localPresent.Count){[string]::Join(', ',$localPresent.ToArray())}else{'aucune'})+'.')
    Write-Host ('Données Domenia du profil Windows présentes : '+$(if($profilePresent.Count){[string]::Join(', ',$profilePresent.ToArray())+' (partagées par toutes les copies de ce compte)'}else{'aucune'})+'.')
    $receipts=Get-OpenReceipts (Get-DataFolder $profileRoot 'Domenia\Receipts')
    if($receipts.Open.Count -gt 0){Write-Host ('Reçus dʼopérations à vérifier : '+$receipts.Open.Count+'. Les données du profil ne seront pas supprimées tant quʼils ne sont pas vérifiés dans Domenia (onglet « Fiabilité », Opérations à vérifier).')}
    if(-not $PSCmdlet.ShouldProcess($targetRoot,'Désinstaller Domenia ; les données ne sont supprimées que sur un choix explicite')){if($WhatIfPreference){return};Stop-Cancelled 'Désinstallation annulée : rien nʼest supprimé.'}
    if($askOperator){
        $answer=Read-OperatorAnswer ('Désinstaller Domenia de '+$targetRoot+' ? (O/N)')
        if($answer -ne $true){Stop-Cancelled $(if($null -eq $answer){'Désinstallation annulée faute de réponse : rien nʼest supprimé.'}else{'Désinstallation annulée : rien nʼest supprimé.'})}
    }
    $localChoice=Resolve-DataChoice $LocalData 'Supprimer aussi les données de ce dossier (préférences, wad\data, sauvegardes du code) ? (O/N, N les conserve)' '-LocalData' ($localPresent.Count -gt 0)
    $profileChoice=Resolve-DataChoice $ProfileData ('Supprimer aussi les données Domenia de votre profil Windows (base locale, journaux, '+$receipts.Count+' reçu(s) dʼopérations), partagées par toutes les copies de Domenia de ce compte ? (O/N, N les conserve)') '-ProfileData' ($profilePresent.Count -gt 0)
    $plan=Get-DomeniaUninstallPlan -Manifest $activeManifest -Observed $observed -LocalData $localChoice -ProfileData $profileChoice -DevTree $devTree -PendingInstall ([IO.File]::Exists($pendingPath))
    if(-not $plan.Allowed){throw ([string]::Join(' ',[string[]]$plan.Blockers))}
    if(@($plan.ProfileFolders).Count -gt 0){
        Assert-NoDomeniaRunning
        # Read again after the answers: a receipt left unchecked keeps the whole profile, and nothing is deleted.
        $receipts=Get-OpenReceipts (Get-DataFolder $profileRoot 'Domenia\Receipts')
        if($receipts.Open.Count -gt 0){
            $named=[string]::Join(', ',[string[]]@($receipts.Open|Select-Object -First 10))
            if($receipts.Open.Count -gt 10){$named+=' et '+($receipts.Open.Count-10)+' autre(s)'}
            throw ('Reçus dʼopérations à vérifier : '+$named+'. Une écriture AD a pu partir sans vérification : vérifiez ces opérations dans Domenia (onglet « Fiabilité », Opérations à vérifier), puis relancez la désinstallation. Rien nʼest supprimé.')
        }
    }
    # Every data folder is checked for links before the first deletion.
    $localTargets=@(foreach($relative in @($plan.LocalFolders)){$folder=Get-DataFolder $targetRoot $relative;if($null -ne $folder){$folder}})
    $profileTargets=@(foreach($relative in @($plan.ProfileFolders)){$folder=Get-DataFolder $profileRoot $relative;if($null -ne $folder){$folder}})
    # Shortcuts aimed at this copy, read before its Domenia.exe is removed.
    $exe=ConvertTo-LongPath (Join-Path $targetRoot 'Domenia.exe')
    $links=New-Object 'System.Collections.Generic.List[string]'
    $shell=New-Object -ComObject WScript.Shell
    try{
        foreach($folder in @([Environment]::GetFolderPath('DesktopDirectory'),[Environment]::GetFolderPath('Programs'))){
            if([string]::IsNullOrWhiteSpace($folder)){continue}
            $link=Join-Path $folder 'Domenia.lnk'
            if(-not [IO.File]::Exists($link)){continue}
            $target=[string]$shell.CreateShortcut($link).TargetPath
            if($target -and [IO.File]::Exists($target) -and ((ConvertTo-LongPath $target) -ieq $exe)){$links.Add($link)}
            else{Write-Host ('Raccourci conservé, il vise une autre copie : '+$link)}
        }
    }finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    Assert-AppClosed $targetRoot
    $lockPath=Join-Path $targetRoot 'wad\Support\.lifecycle.lock'
    $lock=$null
    if([IO.File]::Exists($lockPath)){$lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    $removed=0;$changed=New-Object 'System.Collections.Generic.List[string]'
    try{
        foreach($relative in @($plan.RemoveCode)){
            if($relative -ceq 'wad/Support/.lifecycle.lock'){continue}
            $path=Get-SafePackagePath $targetRoot $relative
            if(-not [IO.File]::Exists($path)){continue}
            # Read again under the exclusive lock: a file changed since the plan is kept, never removed blindly.
            if(($relative -cne 'wad/package-manifest.json') -and ((Get-CodeHash $path) -cne [string]$observed[$relative])){$changed.Add($relative);continue}
            [IO.File]::Delete($path);$removed++
        }
        foreach($relative in @($plan.RemoveSettings)){$path=Get-SafePackagePath $targetRoot $relative;if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
        foreach($folder in $localTargets){[IO.Directory]::Delete($folder,$true)}
    }finally{if($null -ne $lock){$lock.Dispose()}}
    if((@($plan.RemoveCode) -ccontains 'wad/Support/.lifecycle.lock') -and [IO.File]::Exists($lockPath)){[IO.File]::Delete($lockPath);$removed++}
    foreach($link in $links){if([IO.File]::Exists($link)){[IO.File]::Delete($link)}}
    foreach($folder in $profileTargets){[IO.Directory]::Delete($folder,$true)}
    if($profileTargets.Count -gt 0){$profileFolder=Join-Path $profileRoot 'Domenia';if([IO.Directory]::Exists($profileFolder) -and (@([IO.Directory]::EnumerateFileSystemEntries($profileFolder)).Count -eq 0)){[IO.Directory]::Delete($profileFolder)}}
    Remove-EmptyFolders $targetRoot
    Write-Host ('Domenia désinstallé : '+$removed+' fichier(s) de code supprimé(s), '+$links.Count+' raccourci(s) retiré(s).')
    foreach($line in @($plan.Lines|Select-Object -Skip 1)){Write-Host $line}
    if($changed.Count -gt 0){Write-Host ('Fichiers modifiés pendant la désinstallation, conservés : '+[string]::Join(', ',$changed.ToArray()))}
    if([IO.Directory]::Exists($targetRoot)){Write-Host ('Dossier conservé : '+$targetRoot+' (données conservées ou fichiers non livrés par ce paquet).')}
    else{Write-Host ('Dossier supprimé : '+$targetRoot)}
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
if($Uninstall){
    Invoke-DomeniaUninstall -Root $Destination
    return
}
if($Install){
    $fullDestination=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar)
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
    if(-not $PSCmdlet.ShouldProcess($targetRoot,'Installer Domenia dans un dossier vide')) {if($WhatIfPreference){return};Stop-Cancelled 'Installation annulée : aucun fichier écrit.'}
    if($askOperator){
        $answer=Read-OperatorAnswer ('Installer ces '+($copies.Count+1)+' fichiers ? (O/N)')
        if($answer -ne $true){Stop-Cancelled $(if($null -eq $answer){'Installation annulée faute de réponse : aucun fichier écrit.'}else{'Installation annulée : aucun fichier écrit.'})}
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
        # Empty input: the check never consumes the answers typed for the questions that follow.
        $null | & $desktopPowerShell -NoLogo -NoProfile -STA -NonInteractive -File (Join-Path $targetRoot 'wad\Domenia-Start.ps1') -CheckOnly
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
        if($Shortcuts -ceq 'Oui'){$choice=$true}elseif($Shortcuts -ceq 'Non'){$choice=$false}
        elseif(-not $askOperator){Write-Host ('Raccourci '+$shortcut.Label+' non créé : question non posée (-Confirm:$false). Ajoutez -Shortcuts Oui pour le créer.');continue}
        else{$choice=Read-OperatorAnswer ('Créer un raccourci Domenia '+$shortcut.Label+' ? (O/N)')}
        if($choice -ne $true){
            if($null -eq $choice){Write-Host ('Raccourci '+$shortcut.Label+' non créé : aucune réponse.')}else{Write-Host ('Raccourci '+$shortcut.Label+' non créé.')}
            continue
        }
        # The installation is complete: a shortcut that cannot be created (COM, redirected or read-only folder) is a
        # warning, and the next shortcut is still offered.
        try{
            if([string]::IsNullOrWhiteSpace([string]$shortcut.Folder) -or -not [IO.Directory]::Exists([string]$shortcut.Folder)){throw 'dossier introuvable.'}
            $link=Join-Path ([string]$shortcut.Folder) 'Domenia.lnk'
            if([IO.File]::Exists($link)){Write-Host ('Un raccourci Domenia existe déjà '+$shortcut.Label+' : il est conservé tel quel.');continue}
            $shell=New-Object -ComObject WScript.Shell
            try{
                $item=$shell.CreateShortcut($link)
                $item.TargetPath=Join-Path $targetRoot 'Domenia.exe';$item.WorkingDirectory=$targetRoot;$item.IconLocation=(Join-Path $targetRoot 'wad\Domenia.ico')+',0';$item.Description='Domenia'
                $item.Save()
            }finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
            Write-Host ('Raccourci créé '+$shortcut.Label+' : '+$link)
        }catch{Write-Warning ('Raccourci '+$shortcut.Label+' non créé : '+$_.Exception.Message)}
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
# Point 143: the data schema transition is announced before the answer; the application migrates the base itself at
# its first start, after a verified backup, and the restore advice is kept in the transaction journal.
. (Import-PackageModel $source $manifest 'wad/modules/Domenia-Common.Model.ps1')
. (Import-PackageModel $source $manifest 'wad/modules/Domenia-Release.Model.ps1')
$schemaTransition=Get-DomeniaDataSchemaTransition -ActiveSchema (Get-DataSchemaVersion $targetRoot) -TargetSchema (Get-DataSchemaVersion $source)
Write-Host ('Version active : '+$activeLabel+' ; version préparée : '+[string]$manifest.Build+'.')
Write-Host ([string]$schemaTransition.UpdateNotice)
Write-Host ('Fichiers à installer : '+$plan.Count)
foreach($entry in $plan){Write-Host ('  '+$entry.Path)}
if(-not $PSCmdlet.ShouldProcess($targetRoot,'Sauvegarder le code puis installer la mise à jour, sans toucher à wad\data')) {if($WhatIfPreference){return};Stop-Cancelled 'Installation annulée : aucun fichier modifié.'}
if($askOperator){
    $answer=Read-OperatorAnswer ('Installer ces '+$plan.Count+' fichiers ? (O/N)')
    if($answer -ne $true){Stop-Cancelled $(if($null -eq $answer){'Installation annulée faute de réponse : aucun fichier modifié.'}else{'Installation annulée : aucun fichier modifié.'})}
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
$null | & $desktopPowerShell -NoLogo -NoProfile -STA -NonInteractive -File (Join-Path $staged 'wad/Domenia-Start.ps1') -CheckOnly
if($LASTEXITCODE -ne 0){throw 'La version préparée ne peut pas démarrer. Le code actif est inchangé.'}
[void](Get-SafePackagePath $targetRoot 'wad/Support/.lifecycle.lock')
[void][IO.Directory]::CreateDirectory((Join-Path $targetRoot 'wad\Support'))
$lockPath=Join-Path $targetRoot 'wad\Support\.lifecycle.lock'
$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$pendingPath=Join-Path $targetRoot 'wad\Support\.update.pending'
if([IO.File]::Exists($pendingPath)){$lock.Dispose();throw 'Installation précédente incomplète. Lancez dʼabord -RestoreLatest -Destination avec ce dossier Domenia.'}
$journal=[ordered]@{Format=1;Build=[string]$manifest.Build;Created=(Get-Date).ToString('o');Destination=$targetRoot;Status='Prepared';Files=$plan.ToArray()
    DataSchema=[ordered]@{Before=[int]$schemaTransition.ActiveSchema;After=[int]$schemaTransition.TargetSchema;Direction=[string]$schemaTransition.Direction};RestoreNotice=[string]$schemaTransition.RestoreNotice}
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
if(-not [bool]$schemaTransition.RestoreReadsBase){Write-Host ('Avant un retour arrière : '+[string]$schemaTransition.RestoreNotice)}
Write-Host 'Lancez Domenia.exe. Les anciens fichiers DEV ne sont pas supprimés automatiquement.'
