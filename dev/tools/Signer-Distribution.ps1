#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$Thumbprint)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$Thumbprint) -ErrorAction Stop
if(-not $cert.HasPrivateKey -or $cert.NotAfter -lt (Get-Date) -or $cert.NotBefore -gt (Get-Date)){throw 'Certificat de signature avec cle privee valide requis.'}
if(@($cert.EnhancedKeyUsageList|Where-Object{$_.ObjectId.Value -eq '1.3.6.1.5.5.7.3.3'}).Count -eq 0){throw 'Usage Code Signing requis.'}
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
    if($rel -ne 'Domenia.exe' -and $rel -notmatch '\.ps1$'){continue}
    $path=Join-Path $root $rel
    if($PSCmdlet.ShouldProcess($path,('Signer avec le certificat organisationnel '+$cert.Thumbprint))){
        $result=Set-AuthenticodeSignature -FilePath $path -Certificate $cert -HashAlgorithm SHA256
        if($result.Status -ne 'Valid'){throw ('Signature non validee : '+$rel+' ; '+$result.Status)}
    }
}
Write-Host 'Apres signature effective, reconstruire les manifestes et ZIP avec tools/build_packages.py puis verifier la distribution. Aucun certificat ou cle privee ne doit etre ajoute au ZIP.'
Write-Host 'Aucun serveur d horodatage impose. La politique de confiance et de validite a long terme doit etre definie par votre organisation.'
