# Runs the capture mode of Domenia 2 inside the Domenia VM (docs/CAPTURE.md), then prints capture.log.
# Works in the folder that holds this script: C:\DomeniaDev\src\<lot>\v2 (see tools/vm.sh) or the historical
# C:\DomeniaDev\src\v2. Default images folder: C:\DomeniaDev\captures\<lot> (historical: C:\DomeniaDev\captures).
# Default executable: the pack of the lot (embedded WebView2), else the Release build, else the Debug build.
# -Routes 'accueil,rechercher' and -Themes 'dark,light,contrast' add one image per screen and theme (plus its « bas »
# variant when the screen scrolls) after the default sequence. -Clean empties the images folder first (PNG, temporary
# files and capture.log only).
# Simulation only: Domenia refuses --capture in directory mode (real data would end up in the images).
param(
    [string]$Output = '',
    [string]$Exe = '',
    [string]$Routes = '',
    [string]$Themes = '',
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Through SSH the console keeps the OEM code page: UTF-8 keeps the accents of capture.log and of this script readable.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    Write-Warning ('Encodage UTF-8 de la console non appliqué : ' + $_.Exception.GetType().Name + '.')
}
$root = Split-Path -Parent $PSScriptRoot
$lot = ''
if ($root -match '^C:\\DomeniaDev\\src\\([a-z0-9][a-z0-9-]{0,39})\\v2$') { $lot = $Matches[1] }
# Reserved lots would mix with the historical folders (C:\DomeniaDev\src\v2, C:\DomeniaDev\out\Domenia).
if ($lot -in @('cache', 'v2', 'domenia')) { throw "Lot réservé : $lot (dossiers historiques de la VM)." }
if (-not $Output) { $Output = if ($lot) { Join-Path 'C:\DomeniaDev\captures' $lot } else { 'C:\DomeniaDev\captures' } }
if (-not $Exe) {
    $pack = if ($lot) { Join-Path 'C:\DomeniaDev\out' "$lot\Domenia\Domenia.exe" } else { 'C:\DomeniaDev\out\Domenia\Domenia.exe' }
    $candidates = @(
        $pack,
        (Join-Path $root 'src\Domenia.App\bin\x64\Release\net10.0-windows\win-x64\Domenia.exe'),
        (Join-Path $root 'src\Domenia.App\bin\x64\Debug\net10.0-windows\win-x64\Domenia.exe'))
    $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Exe) { throw 'Aucun Domenia.exe : lancer avant tools\build-vm.ps1 (avec -Publish pour le pack).' }
}
# No quote, space or other character outside the strict forms reaches the command line; Domenia then checks each
# route against CaptureRoute.Pattern and refuses the run (code 2) if one does not match.
if ($Routes -and ($Routes -cnotmatch '^[A-Za-z0-9=&%._,?-]{2,3000}$')) { throw 'Écrans invalides (-Routes) : minuscules, chiffres, tirets, requête après « ? », séparés par des virgules.' }
if ($Themes -and ($Themes -cnotmatch '^(dark|light|contrast)(,(dark|light|contrast)){0,2}$')) { throw 'Thèmes invalides (-Themes) : dark, light, contrast.' }
if ($Clean -and (Test-Path $Output)) {
    Get-ChildItem -LiteralPath $Output -File | Where-Object { $_.Name -like '*.png' -or $_.Name -like '*.png.tmp' -or $_.Name -eq 'capture.log' } | Remove-Item -Force
}
# Start-Process joins the arguments as they are: the folder is quoted here. Before a closing quote, backslashes are
# doubled (C:\x\ would otherwise end in an escaped quote and reach Domenia as C:\x").
$arguments = @('--simulation', '--capture', ('"{0}"' -f ($Output -replace '(\\+)$', '$1$1')))
$count = 0
if ($Routes) {
    $arguments += @('--capture-routes', ('"{0}"' -f $Routes))
    $count = @($Routes -split ',').Count
}
if ($Themes) { $arguments += @('--capture-themes', ('"{0}"' -f $Themes)) }
"Lancement : $Exe $($arguments -join ' ')"
$process = Start-Process -FilePath $Exe -ArgumentList $arguments -PassThru
# Reading the handle now keeps the exit code available once the process has ended.
$null = $process.Handle
# Domenia ends by itself (watchdog included); this bound only protects the SSH session: 330 s for the default sequence,
# plus 45 s per extra image (three per screen and theme at most: top, middle, bottom).
$themeCount = if ($Themes) { @($Themes -split ',').Count } else { 1 }
$limit = 330000 + (45000 * 3 * $count * $themeCount)
if (-not $process.WaitForExit($limit)) {
    Stop-Process -Id $process.Id -Force
    'Domenia toujours actif après le délai : processus arrêté.'
    exit 2
}
$log = Join-Path $Output 'capture.log'
if (Test-Path $log) { Get-Content -Encoding UTF8 $log } else { 'Aucun capture.log : voir le journal technique (%LOCALAPPDATA%\Domenia\logs\domenia.log).' }
"Code de sortie : $($process.ExitCode)"
exit $process.ExitCode
