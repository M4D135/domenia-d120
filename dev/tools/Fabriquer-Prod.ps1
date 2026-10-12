#requires -Version 5.1
<#
.SYNOPSIS
Reconstruit un PROD Domenia depuis un dossier wad complet, sans modifier ce dossier.
.EXAMPLE
.\tools\Fabriquer-Prod.ps1
.EXAMPLE
.\tools\Fabriquer-Prod.ps1 -SourceWad 'D:\Sources\wad' -OutputDirectory 'D:\Livraisons\prod'
.NOTES
Windows PowerShell 5.1 minimum. Aucun telechargement ni compilateur requis.
Les DLL du dossier wad doivent deja etre compilees. L'application n'est jamais lancee.
#>
[CmdletBinding()]
param([string]$SourceWad='',[string]$OutputDirectory='',[string]$LauncherPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$dev=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Production.Source.ps1')
if(-not $SourceWad){$SourceWad=Join-Path $dev 'wad'}
if(-not $LauncherPath){$LauncherPath=Join-Path $dev 'Domenia.exe'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path (Split-Path $dev -Parent) ('prod-'+[datetime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))}
$SourceWad=[IO.Path]::GetFullPath($SourceWad)
if($SourceWad -eq [IO.Path]::GetPathRoot($SourceWad)){throw 'Le dossier source doit etre un dossier wad complet, pas la racine du volume.'}
$SourceWad=$SourceWad.TrimEnd('/','\')
$LauncherPath=[IO.Path]::GetFullPath($LauncherPath)
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('/','\')
foreach($source in @($SourceWad,$dev)){
    if($OutputDirectory -ieq $source -or $OutputDirectory.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Choisissez une sortie hors du dossier DEV et des sources wad.'}
}
if(Test-Path -LiteralPath $OutputDirectory){throw ('La sortie existe deja. Choisissez un nouveau dossier : '+$OutputDirectory)}
$parent=[IO.Path]::GetDirectoryName($OutputDirectory)
# Inspect the existing ancestor before creating any missing output directories.
$ancestor=$parent
while(-not (Test-Path -LiteralPath $ancestor)){
    $next=[IO.Path]::GetDirectoryName($ancestor)
    if(-not $next -or $next -eq $ancestor){throw 'Dossier parent de sortie inaccessible.'}
    $ancestor=$next
}
Assert-DomeniaBuildPlainPath $ancestor
[void][IO.Directory]::CreateDirectory($parent);Assert-DomeniaBuildPlainPath $parent
$work=Join-Path $parent ('.domenia-build-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try{
    Write-Host '1/3 Preparation des fichiers et des contrats Domenia...'
    $payload=Join-Path $work 'payload'
    $prepared=New-DomeniaProductionPayload -SourceWad $SourceWad -LauncherPath $LauncherPath -PayloadRoot $payload -ToolsRoot $PSScriptRoot
    Write-Host ('    '+$prepared.Files+' fichiers ; '+$prepared.Operations+' operations worker actualisees.')
    Write-Host '2/3 Verification du manifeste et de chaque composant...'
    $manifest=Read-DomeniaBuildText (Join-Path $payload 'wad/package-manifest.json')|ConvertFrom-Json
    foreach($entry in $manifest.Files){
        $file=Get-DomeniaBuildChildPath $payload $entry.Path
        if((Get-Item -LiteralPath $file -Force).Length -ne [long]$entry.Bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $entry.Sha256){throw ('Verification impossible : '+$entry.Path)}
        if([IO.Path]::GetExtension($file) -ieq '.ps1'){[void](Get-DomeniaBuildAst (Read-DomeniaBuildText $file) $entry.Path)}
    }
    $files=@(Get-ChildItem -LiteralPath $payload -Force)
    if($files.Count -ne 2 -or @($files|Where-Object{$_.Name -cnotin @('Domenia.exe','wad')}).Count){throw 'Structure PROD inattendue.'}
    Write-Host '3/3 Publication du dossier termine...'
    [IO.Directory]::Move($payload,$OutputDirectory)
    Write-Host ('PROD cree : '+$OutputDirectory) -ForegroundColor Green
    Write-Host '    Domenia.exe + dossier wad'
    Write-Host 'Fichiers et integrite controles. Qualifiez vos modifications sur Windows avant diffusion.'
    [pscustomobject]@{OutputDirectory=$OutputDirectory;Build=$prepared.Build;Files=$prepared.Files;WindowsApplicationExecuted=$false}
}finally{if([IO.Directory]::Exists($work)){[IO.Directory]::Delete($work,$true)}}
