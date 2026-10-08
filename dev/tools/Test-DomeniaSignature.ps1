#requires -Version 5.1
<# SP-09: offline signature report of a Domenia distribution (PROD, DEV, installed copy or prepared copy).
   Two separate answers:
     - integrity: every file listed by the manifest carries the manifest SHA-256, and no undeclared code file was added
       beside a DEV manifest (beside a PROD manifest, code files left by a previous version are reported apart: the
       installer never deletes them and the closed loader never runs them);
     - publisher: each file is covered by the proof that the delivery chain really produces:
         * PowerShell scripts: Authenticode status read locally (Get-AuthenticodeSignature), accepted only for a signer
           certificate pinned by thumbprint (-PublisherThumbprint); tools\Signer-Distribution.ps1 signs them;
         * frozen binaries (Domenia.exe, never re-signed under F8, and the third-party components): the SHA-256 pinned
           by the reviewed release contract of this tool's tree (tools\release-contract.json, Components Pinned=true);
         * files Authenticode cannot sign (.json, .xaml, .cs, .cmd, .ico, lock): only a signed catalog of the manifest
           (wad\package-manifest.cat, tools\Signer-Distribution.ps1 -ManifestCatalog) covers them; without it they rest
           on the unsigned manifest and are listed apart.
   A name or a subject alone proves nothing. This script makes no network request and asks for no CRL/OCSP check; it
   never signs, unblocks or installs anything. The signature stays optional until the organisation provides a
   certificate: an intact unsigned distribution passes unless -RequireSignature (scripts and pinned binaries) or
   -RequireSignedManifest (every file, through the signed catalog) is given. The verdict rules and the pins are read
   from the tool's own tree (wad\modules\Domenia-Release.Model.ps1, tools\release-contract.json), never from the copy
   under examination.
#>
[CmdletBinding()]
param(
    [string]$Root='',
    [string]$Manifest='',
    [string[]]$PublisherThumbprint=@(),
    [string]$ManifestCatalog='',
    [string]$ReportPath='',
    [switch]$RequireSignature,
    [switch]$RequireSignedManifest,
    [switch]$PassThru,
    [switch]$Quiet
)
$ErrorActionPreference='Stop'
$toolRoot=Split-Path -Parent $PSScriptRoot
# Default root computed here: Windows PowerShell 5.1 leaves $PSScriptRoot empty in parameter defaults under -File.
if([string]::IsNullOrWhiteSpace($Root)){$Root=$toolRoot}
. (Join-Path $toolRoot 'wad\modules\Domenia-Common.Model.ps1')
. (Join-Path $toolRoot 'wad\modules\Domenia-Release.Model.ps1')
# Relative paths follow the PowerShell location (cd), not the process directory.
$rootPath=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
$prefix=$rootPath+[IO.Path]::DirectorySeparatorChar
if(-not [IO.Directory]::Exists($rootPath)){throw 'Dossier de distribution absent.'}
$cursor=[IO.DirectoryInfo]::new($rootPath)
while($null -ne $cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Racine redirigée par un lien.'};$cursor=$cursor.Parent}
$defaultManifest=[string]::IsNullOrWhiteSpace($Manifest)
$manifestPath=if($defaultManifest){Join-Path $rootPath 'wad\package-manifest.json'}elseif([IO.Path]::IsPathRooted($Manifest)){$Manifest}else{Join-Path $rootPath $Manifest}
$manifestInfo=[IO.FileInfo]::new($manifestPath)
if((-not $manifestInfo.Exists) -or ($manifestInfo.Length -gt 4MB) -or ($manifestInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste absent, trop volumineux ou redirigé.'}
$data=[IO.File]::ReadAllText($manifestInfo.FullName,[Text.Encoding]::UTF8)|ConvertFrom-Json
if(([int]$data.Format -ne 1) -or (@($data.Files).Count -lt 1) -or (@($data.Files).Count -gt 5000)){throw 'Manifeste invalide.'}
$edition=[string]$data.Edition
# Frozen binaries pinned by the reviewed contract of this tool's tree (F8 launcher, third-party components).
$pinned=@{}
$contractPath=Join-Path $toolRoot 'tools\release-contract.json'
if([IO.File]::Exists($contractPath)){
    $contract=[IO.File]::ReadAllText($contractPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    foreach($component in @($contract.Components)){
        if(($null -ne $component) -and ($component.Pinned -eq $true) -and ([string]$component.Sha256 -match '^[0-9A-Fa-f]{64}$')){$pinned[[string]$component.Path]=[string]$component.Sha256}
    }
}
$hasher=[Security.Cryptography.SHA256]::Create()
$files=New-Object 'System.Collections.Generic.List[object]'
$declared=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$localConfiguration=New-Object 'System.Collections.Generic.List[string]'
try {
    foreach($entry in @($data.Files)){
        $relative=[string]$entry.Path
        if([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or (@($relative -split '[/\\]') -contains '..')){throw ('Chemin de manifeste non autorisé : '+$relative)}
        [void]$declared.Add($relative.Replace('\','/'))
        $path=[IO.Path]::GetFullPath((Join-Path $rootPath $relative))
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw ('Chemin hors de la distribution : '+$relative)}
        if([bool]$entry.PreserveExisting){
            # Local preferences are editable after installation: reported apart, outside the delivery verdict.
            $localConfiguration.Add($relative);continue
        }
        $row=[ordered]@{Path=$relative;ExpectedSha256=[string]$entry.Sha256;ActualSha256='';Present=$true;SignatureStatus='';Signer='';SignerThumbprint=''}
        $item=[IO.FileInfo]::new($path)
        if(-not $item.Exists){$row.Present=$false;$files.Add([pscustomobject]$row);continue}
        $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,1048576,[IO.FileOptions]::SequentialScan)
        try{$row.ActualSha256=[BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose()}
        if($relative -match '(?i)\.(exe|dll|ps1|psm1|psd1)$'){
            $signature=Get-AuthenticodeSignature -LiteralPath $path
            $row.SignatureStatus=[string]$signature.Status
            if($null -ne $signature.SignerCertificate){$row.Signer=[string]$signature.SignerCertificate.Subject;$row.SignerThumbprint=[string]$signature.SignerCertificate.Thumbprint}
        }
        $files.Add([pscustomobject]$row)
    }
} finally {$hasher.Dispose()}
# Signed catalog of the manifest: it covers the files that Authenticode cannot sign. The catalog must list exactly this
# manifest (Test-FileCatalog, local hashes only); a catalog that no longer matches it is a broken signature.
$catalogPath=''
if(-not [string]::IsNullOrWhiteSpace($ManifestCatalog)){
    $catalogPath=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($ManifestCatalog)
    if(-not [IO.File]::Exists($catalogPath)){throw 'Catalogue du manifeste absent.'}
}elseif([IO.File]::Exists([IO.Path]::ChangeExtension($manifestInfo.FullName,'.cat'))){$catalogPath=[IO.Path]::ChangeExtension($manifestInfo.FullName,'.cat')}
$manifestSignature=$null;$catalogMatch=''
if($catalogPath){
    $catalogSignature=Get-AuthenticodeSignature -LiteralPath $catalogPath
    $status=[string]$catalogSignature.Status
    try{$catalogMatch=[string](Test-FileCatalog -CatalogFilePath $catalogPath -Path $manifestInfo.FullName)}catch{$catalogMatch='Illisible'}
    if($catalogMatch -cne 'Valid'){$status='HashMismatch'}
    $manifestSignature=[pscustomobject]@{SignatureStatus=$status;Signer='';SignerThumbprint=''}
    if($null -ne $catalogSignature.SignerCertificate){$manifestSignature.Signer=[string]$catalogSignature.SignerCertificate.Subject;$manifestSignature.SignerThumbprint=[string]$catalogSignature.SignerCertificate.Thumbprint}
}
# Undeclared code beside a complete package manifest (not for a partial list such as tools\prod-manifest.json).
# The lab tools and the history stay in the repository and out of the DEV package (SE-15, build_packages.py).
$undeclared=New-Object 'System.Collections.Generic.List[string]'
$keptOutside=New-Object 'System.Collections.Generic.List[string]'
if($defaultManifest){
    foreach($candidate in [IO.Directory]::EnumerateFiles($rootPath,'*',[IO.SearchOption]::AllDirectories)){
        if($candidate -notmatch '(?i)\.(exe|dll|ps1|psm1|psd1)$'){continue}
        $relative=$candidate.Substring($prefix.Length).Replace('\','/')
        if($relative -match '^(?i:wad/data|wad/maintenance/backups|engineering/d120/lab|wad/docs/history)(/|$)'){continue}
        if($declared.Contains($relative)){continue}
        # Beside a PROD manifest (installed copy, DEV copy updated with a PROD package), files of a previous version are
        # left in place by the installer and never loaded: reported apart instead of making the copy a modified one.
        if($edition -ceq 'prod'){$keptOutside.Add($relative)}else{$undeclared.Add($relative)}
    }
}
$pin=$null
if(@($PublisherThumbprint).Count -gt 0){$pin=[pscustomobject]@{Name='';Thumbprints=@($PublisherThumbprint)}}
$verdict=Get-DomeniaSignatureVerdict -Files $files.ToArray() -Publisher $pin -ManifestSignature $manifestSignature -UndeclaredFiles $undeclared.ToArray() -PinnedComponents $pinned
$integrityOk=($verdict.IntegrityStatus -ceq 'Conforme')
$completeCover=($verdict.PublisherStatus -ceq 'Editeur verifie')
$codeCover=($completeCover -or ($verdict.PublisherStatus -ceq 'Editeur verifie, manifeste non signe'))
$signatureNeeded=([bool]$RequireSignature -or [bool]$RequireSignedManifest)
$signaturePassed=((-not $signatureNeeded) -or ($codeCover -and ((-not $RequireSignedManifest) -or $completeCover)))
$scopeCount={param([string]$Scope) @($verdict.Files|Where-Object{$_.Scope -ceq $Scope}).Count}
$result=[pscustomobject][ordered]@{
    Build=[string]$data.Build;Edition=$edition;Root=$rootPath;Manifest=$manifestInfo.FullName;Executed=(Get-Date).ToString('o');Runtime=$PSVersionTable.PSVersion.ToString()
    Offline=$true;RevocationChecked=$false;SignatureRequired=[bool]$signatureNeeded;SignedManifestRequired=[bool]$RequireSignedManifest
    Integrity=[pscustomobject]@{Status=$verdict.IntegrityStatus;Files=@($verdict.Files).Count;Modified=@($verdict.Files|Where-Object{($_.Integrity -ceq 'Modifiee') -or ($_.Integrity -ceq 'Absente')}|ForEach-Object{$_.Path});Undeclared=@($verdict.Undeclared);KeptOutsideManifest=$keptOutside.ToArray();LocalConfiguration=$localConfiguration.ToArray()}
    Publisher=[pscustomobject]@{
        Status=$verdict.PublisherStatus;Pinned=[bool]$verdict.PublisherPinned;VerifiedFiles=[int]$verdict.PublisherVerifiedFiles;Thumbprints=@($PublisherThumbprint)
        SignedFiles=(& $scopeCount 'Signature');PinnedComponents=@($verdict.PinnedFiles);ManifestOnly=@($verdict.ManifestOnlyFiles)
        ManifestCatalog=$catalogPath;ManifestCatalogMatch=$catalogMatch;ManifestSigned=[bool]$verdict.ManifestSigned;PinsSource=$(if($pinned.Count){$contractPath}else{''})
    }
    Overall=$verdict.Overall;NextAction=$verdict.NextAction;IntegrityNote=$verdict.IntegrityNote
    Passed=($integrityOk -and $signaturePassed)
    Files=@($verdict.Files)
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-signature-'+[guid]::NewGuid().ToString('N')+'.json')}
$ReportPath=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($ReportPath)
[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){
    $requirement=if($RequireSignedManifest){' (signature du manifeste exigée)'}elseif($RequireSignature){' (signature exigée)'}else{' (signature facultative)'}
    Write-Host ('Intégrité : '+$verdict.IntegrityStatus+' ('+@($verdict.Files).Count+' fichiers du manifeste).')
    if($keptOutside.Count){Write-Host ('Hors manifeste PROD, laissés par une version précédente et jamais chargés : '+$keptOutside.Count+' fichier(s) de code.')}
    Write-Host ('Éditeur : '+$verdict.PublisherStatus+$requirement+'.')
    if(@($verdict.ManifestOnlyFiles).Count){Write-Host ('Fichiers non signables couverts par le seul manifeste non signé : '+@($verdict.ManifestOnlyFiles).Count+'.')}
    Write-Host ('Rapport : '+$ReportPath)
}
if($PassThru){$result}
if(-not $result.Passed){exit 1}
exit 0
