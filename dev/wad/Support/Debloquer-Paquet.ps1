#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param()
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$manifestPath=Join-Path $root 'wad\package-manifest.json'
$probe=[IO.DirectoryInfo]::new($root)
while($null -ne $probe){if($probe.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier du paquet redirige.'};$probe=$probe.Parent}
$info=Get-Item -LiteralPath $manifestPath -Force
if($info.Length -gt 2MB -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste invalide.'}
$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
if($manifest.Format -ne 1 -or @($manifest.Files).Count -gt 1000){throw 'Manifeste incompatible ou trop volumineux.'}
$files=[Collections.Generic.List[string]]::new()
foreach($entry in @($manifest.Files|Where-Object{$_.Runtime -eq $true})){
    $relative=[string]$entry.Path
    if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[/\\])\.\.([/\\]|$)|:|^wad[/\\]data([/\\]|$)'){throw 'Chemin refuse dans le manifeste.'}
    $path=[IO.Path]::GetFullPath((Join-Path $root $relative))
    if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fichier hors du paquet.'}
    if(-not [IO.File]::Exists($path)){throw ('Fichier du runtime manquant : '+$relative)}
    $cursor=$path
    while($cursor.Length -gt $root.Length){
        if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Lien de redirection refuse.'}
        $cursor=Split-Path -Parent $cursor
    }
    if(-not $entry.PreserveExisting -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.Sha256){throw ('Empreinte invalide : '+$relative+'. Aucun deblocage en masse effectue.')}
    $files.Add($path)
}
foreach($path in $files){if($PSCmdlet.ShouldProcess($path,'Retirer la marque de telechargement')){Unblock-File -LiteralPath $path -ErrorAction Stop}}
Write-Host 'Runtime debloque. Aucun test ou fichier de demonstration exige. Aucune donnee personnelle parcourue.'
Write-Host 'Aucune politique PowerShell, GPO, AppLocker/WDAC ou protection antivirus modifiee. Le manifeste ne vaut pas signature.'
