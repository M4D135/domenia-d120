#requires -Version 5.1
# SP-09: -Root names the copy prepared by tools/build_packages.py --stage-dir (runtime files and tools\prod-manifest.json);
# the audited source tree stays unsigned and build_packages.py --signed-stage checks each signed file against it.
# Only the PowerShell scripts are signed: Domenia.exe is never taken from the stage (F8) and the third-party binaries keep
# their own vendor; both are pinned by SHA-256 in tools\release-contract.json (tools\Test-DomeniaSignature.ps1).
# -ManifestCatalog signs, after the build, a catalog of the delivered manifest (wad\package-manifest.json ->
# wad\package-manifest.cat): it covers the files that Authenticode cannot sign (.json, .xaml, .cs, .cmd, .ico, lock).
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Stage')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$Thumbprint,
    [Parameter(ParameterSetName='Stage')][string]$Root='',
    [Parameter(Mandatory,ParameterSetName='Catalog')][string]$ManifestCatalog
)
$ErrorActionPreference='Stop'
$cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$Thumbprint) -ErrorAction Stop
if(-not $cert.HasPrivateKey -or $cert.NotAfter -lt (Get-Date) -or $cert.NotBefore -gt (Get-Date)){throw 'Certificat de signature avec cle privee valide requis.'}
if(@($cert.EnhancedKeyUsageList|Where-Object{$_.ObjectId.Value -eq '1.3.6.1.5.5.7.3.3'}).Count -eq 0){throw 'Usage Code Signing requis.'}
if($PSCmdlet.ParameterSetName -eq 'Catalog'){
    $manifestFile=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($ManifestCatalog)
    $info=[IO.FileInfo]::new($manifestFile)
    if((-not $info.Exists) -or ($info.Length -gt 4MB) -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste livre absent, trop volumineux ou redirige.'}
    $data=[IO.File]::ReadAllText($info.FullName)|ConvertFrom-Json
    if(([int]$data.Format -ne 1) -or (@($data.Files).Count -lt 1)){throw 'Manifeste livre invalide.'}
    $catalog=[IO.Path]::ChangeExtension($info.FullName,'.cat')
    if([IO.File]::Exists($catalog)){throw ('Catalogue deja present, non remplace : '+$catalog)}
    if($PSCmdlet.ShouldProcess($catalog,('Creer et signer le catalogue du manifeste avec le certificat organisationnel '+$cert.Thumbprint))){
        try{
            [void](New-FileCatalog -Path $info.FullName -CatalogFilePath $catalog -CatalogVersion 2.0)
            $result=Set-AuthenticodeSignature -FilePath $catalog -Certificate $cert -HashAlgorithm SHA256
            if($result.Status -ne 'Valid'){throw ('Signature du catalogue non validee : '+$result.Status)}
        }catch{if([IO.File]::Exists($catalog)){[IO.File]::Delete($catalog)};throw}
        Write-Host ('Catalogue signe : '+$catalog+'. Le livrer avec le manifeste ; toute modification du manifeste le rend invalide.')
    }
    return
}
# Default root computed here: Windows PowerShell 5.1 leaves $PSScriptRoot empty in parameter defaults under -File.
if([string]::IsNullOrWhiteSpace($Root)){$Root=Split-Path -Parent $PSScriptRoot}
$root=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
if(-not [IO.File]::Exists((Join-Path $root 'tools\prod-manifest.json'))){throw 'Copie preparee invalide : tools\prod-manifest.json absent (build_packages.py --stage-dir).'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'tools\prod-manifest.json') -Raw|ConvertFrom-Json
$files=@($manifest.Files|Where-Object{$_.Runtime -eq $true})
foreach($f in $files){
    $rel=[string]$f.Path
    if($rel -match '(^|[/\\])\.\.([/\\]|$)|:' -or [IO.Path]::IsPathRooted($rel)){throw 'Chemin du manifeste refuse.'}
    $path=Join-Path $root $rel
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$f.Sha256){throw ('Fichier modifie avant signature : '+$rel+'. Regenerer et verifier le paquet apres revue de source.')}
}
foreach($f in $files){
    $rel=[string]$f.Path
    if($rel -notmatch '\.ps1$'){continue}
    $path=Join-Path $root $rel
    if($PSCmdlet.ShouldProcess($path,('Signer avec le certificat organisationnel '+$cert.Thumbprint))){
        $result=Set-AuthenticodeSignature -FilePath $path -Certificate $cert -HashAlgorithm SHA256
        if($result.Status -ne 'Valid'){throw ('Signature non validee : '+$rel+' ; '+$result.Status)}
    }
}
Write-Host 'Apres signature effective, reconstruire les manifestes et ZIP avec tools/build_packages.py --signed-stage, signer le catalogue du manifeste livre (-ManifestCatalog) puis verifier la distribution (tools\Test-DomeniaSignature.ps1). Aucun certificat ou cle privee ne doit etre ajoute au ZIP.'
Write-Host 'Aucun serveur d horodatage impose. La politique de confiance et de validite a long terme doit etre definie par votre organisation.'
