#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$PasserOutreEmpreintes)
$ErrorActionPreference='Stop'
# Le manifeste est calcule sur les octets du depot : fins de ligne LF, BOM eventuel. Un clone Windows
# sorti avec core.autocrlf, ou un editeur qui reecrit les fins de ligne, rend le meme script avec
# d'autres octets. Cette difference-la ne change aucune execution et ne doit pas empecher le
# deblocage ; une difference de contenu reste un refus. Le manifeste ne vaut pas signature.
$texteExtensions=@('.ps1','.psm1','.psd1','.ps1xml','.json','.xml','.xaml','.cs','.cfg','.md','.txt','.cmd')
$script:shaRuntime=[Security.Cryptography.SHA256]::Create()
function Get-EmpreintesRuntime([string]$Path){
    $octets=[IO.File]::ReadAllBytes($Path)
    $brute=[BitConverter]::ToString($script:shaRuntime.ComputeHash($octets)).Replace('-','')
    $candidates=@($brute)
    if($texteExtensions -contains [IO.Path]::GetExtension($Path).ToLowerInvariant()){
        $texte=[Text.Encoding]::UTF8.GetString($octets)
        $texte=$texte.Replace([string][char]13+[char]10,[string][char]10).Replace([string][char]13,[string][char]10)
        $candidates+=[BitConverter]::ToString($script:shaRuntime.ComputeHash([Text.Encoding]::UTF8.GetBytes($texte))).Replace('-','')
        $candidates+=[BitConverter]::ToString($script:shaRuntime.ComputeHash([Text.Encoding]::UTF8.GetBytes([string][char]0xFEFF+$texte))).Replace('-','')
    }
    [pscustomobject]@{Brute=$brute;Candidates=$candidates;Octets=$octets.Length}
}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$manifestPath=Join-Path $root 'wad\package-manifest.json'
$probe=[IO.DirectoryInfo]::new($root)
while($null -ne $probe){if($probe.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier du paquet redirige.'};$probe=$probe.Parent}
$info=Get-Item -LiteralPath $manifestPath -Force
if($info.Length -gt 2MB -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste invalide.'}
$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
if($manifest.Format -ne 1 -or @($manifest.Files).Count -gt 1000){throw 'Manifeste incompatible ou trop volumineux.'}
$entries=@($manifest.Files|Where-Object{$_.Runtime -eq $true})
$files=[Collections.Generic.List[string]]::new()
$ecarts=[Collections.Generic.List[object]]::new()
$finsDeLigne=[Collections.Generic.List[string]]::new()
foreach($entry in $entries){
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
    if(-not $entry.PreserveExisting){
        $etat=Get-EmpreintesRuntime $path
        if($etat.Candidates -notcontains [string]$entry.Sha256){
            $ecarts.Add([pscustomobject]@{Chemin=$relative;Attendue=[string]$entry.Sha256;Lue=$etat.Brute;OctetsManifeste=$entry.Bytes;OctetsReels=$etat.Octets})
            continue
        }
        if($etat.Brute -ine [string]$entry.Sha256){$finsDeLigne.Add($relative)}
    }
    $files.Add($path)
}
$script:shaRuntime.Dispose()
if($finsDeLigne.Count -gt 0){
    $premiers=($finsDeLigne|Select-Object -First 8|ForEach-Object{$_}) -join ', '
    $suite=''
    if($finsDeLigne.Count -gt 8){$suite=' (+'+($finsDeLigne.Count-8)+' autres)'}
    Write-Host ('Fins de ligne differentes du manifeste, contenu identique : '+$finsDeLigne.Count+' fichier(s) : '+$premiers+$suite)
}
if($ecarts.Count -gt 0){
    $lignes=[Collections.Generic.List[string]]::new()
    foreach($e in @($ecarts|Select-Object -First 10)){
        $lignes.Add('  '+$e.Chemin+' : attendu '+$e.Attendue+' ('+[string]$e.OctetsManifeste+' octets) lu '+$e.Lue+' ('+[string]$e.OctetsReels+' octets)')
    }
    if($ecarts.Count -gt 10){$lignes.Add('  … '+($ecarts.Count-10)+' autre(s) en ecart')}
    $detail='Empreinte invalide sur '+$ecarts.Count+' fichier(s) du runtime.'+[Environment]::NewLine
    $detail+=($lignes -join [Environment]::NewLine)+[Environment]::NewLine
    $detail+='Manifeste : build '+[string]$manifest.Build+', edition '+[string]$manifest.Edition+', '+$entries.Count+' fichiers runtime.'+[Environment]::NewLine
    $detail+='Un fichier qui ne differe que par les fins de ligne ou le BOM est accepte et signale plus haut : ceux listes ici different par leur contenu. Verifiez la provenance de la copie (deux versions melees, fichier corrige a la main, paquet reconstruit sans son manifeste).'
    $detail+=[Environment]::NewLine+'Pour debloquer neanmoins une copie de laboratoire dont la provenance est connue : Debloquer-Paquet.ps1 -PasserOutreEmpreintes.'
    if(-not $PasserOutreEmpreintes){throw $detail}
    Write-Host ('ATTENTION : '+$detail) -ForegroundColor Yellow
    foreach($e in $ecarts){$files.Add([IO.Path]::GetFullPath((Join-Path $root $e.Chemin)))}
}
foreach($path in $files){if($PSCmdlet.ShouldProcess($path,'Retirer la marque de telechargement')){Unblock-File -LiteralPath $path -ErrorAction Stop}}
Write-Host 'Runtime debloque. Aucun test ou fichier de demonstration exige. Aucune donnee personnelle parcourue.'
Write-Host 'Aucune politique PowerShell, GPO, AppLocker/WDAC ou protection antivirus modifiee. Le manifeste ne vaut pas signature.'
