#requires -Version 5.1
<# SP-09: offline signature report of a Domenia distribution (PROD, DEV, installed copy or prepared copy).
   Two separate answers:
     - integrity: every file listed by the manifest carries the manifest SHA-256, and no undeclared code file was added;
     - publisher: Authenticode status read locally (Get-AuthenticodeSignature) for the signable files, accepted only
       for a signer certificate pinned by thumbprint (-PublisherThumbprint). A name or a subject alone proves nothing.
   This script makes no network request and asks for no CRL/OCSP check; it never signs, unblocks or installs anything.
   The signature stays optional until the organisation provides a certificate: an intact unsigned distribution passes
   unless -RequireSignature is given. The verdict rules are read from the tool's own tree
   (wad\modules\Domenia-Release.Model.ps1), never from the copy under examination.
#>
[CmdletBinding()]
param(
    [string]$Root=(Split-Path -Parent $PSScriptRoot),
    [string]$Manifest='',
    [string[]]$PublisherThumbprint=@(),
    [string]$ReportPath='',
    [switch]$RequireSignature,
    [switch]$PassThru,
    [switch]$Quiet
)
$ErrorActionPreference='Stop'
$toolRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'wad\modules\Domenia-Common.Model.ps1')
. (Join-Path $toolRoot 'wad\modules\Domenia-Release.Model.ps1')
$rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
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
# Undeclared code beside a complete package manifest (not for a partial list such as tools\prod-manifest.json).
$undeclared=New-Object 'System.Collections.Generic.List[string]'
if($defaultManifest){
    foreach($candidate in [IO.Directory]::EnumerateFiles($rootPath,'*',[IO.SearchOption]::AllDirectories)){
        if($candidate -notmatch '(?i)\.(exe|dll|ps1|psm1|psd1)$'){continue}
        $relative=$candidate.Substring($prefix.Length).Replace('\','/')
        if($relative -match '^(?i:wad/data|wad/maintenance/backups)(/|$)'){continue}
        if(-not $declared.Contains($relative)){$undeclared.Add($relative)}
    }
}
$pin=$null
if(@($PublisherThumbprint).Count -gt 0){$pin=[pscustomobject]@{Name='';Thumbprints=@($PublisherThumbprint)}}
$verdict=Get-DomeniaSignatureVerdict -Files $files.ToArray() -Publisher $pin -UndeclaredFiles $undeclared.ToArray()
$integrityOk=($verdict.IntegrityStatus -ceq 'Conforme')
$publisherOk=($verdict.PublisherStatus -ceq 'Editeur verifie')
$result=[pscustomobject][ordered]@{
    Build=[string]$data.Build;Root=$rootPath;Manifest=$manifestInfo.FullName;Executed=(Get-Date).ToString('o');Runtime=$PSVersionTable.PSVersion.ToString()
    Offline=$true;RevocationChecked=$false;SignatureRequired=[bool]$RequireSignature
    Integrity=[pscustomobject]@{Status=$verdict.IntegrityStatus;Files=@($verdict.Files).Count;Modified=@($verdict.Files|Where-Object{($_.Integrity -ceq 'Modifiee') -or ($_.Integrity -ceq 'Absente')}|ForEach-Object{$_.Path});Undeclared=@($verdict.Undeclared);LocalConfiguration=$localConfiguration.ToArray()}
    Publisher=[pscustomobject]@{Status=$verdict.PublisherStatus;Pinned=[bool]$verdict.PublisherPinned;VerifiedFiles=[int]$verdict.PublisherVerifiedFiles;Thumbprints=@($PublisherThumbprint)}
    Overall=$verdict.Overall;NextAction=$verdict.NextAction;IntegrityNote=$verdict.IntegrityNote
    Passed=($integrityOk -and ((-not $RequireSignature) -or $publisherOk))
    Files=@($verdict.Files)
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-signature-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){
    Write-Host ('Intégrité : '+$verdict.IntegrityStatus+' ('+@($verdict.Files).Count+' fichiers du manifeste).')
    Write-Host ('Éditeur : '+$verdict.PublisherStatus+$(if($RequireSignature){' (signature exigée)'}else{' (signature facultative)'})+'.')
    Write-Host ('Rapport : '+$ReportPath)
}
if($PassThru){$result}
if(-not $result.Passed){exit 1}
exit 0
