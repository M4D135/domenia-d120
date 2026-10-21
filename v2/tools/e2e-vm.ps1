# Runs the end-to-end scenarios of Domenia 2 inside the Domenia VM (docs/E2E.md): Domenia.E2E.exe starts Domenia.exe with
# --e2e-port and DOMENIA_E2E=1 (child environment only), drives it through the DevTools protocol of the WebView2 and writes
# report.json, report.html and the screenshots of every step. Meant to run in the visible desktop session through
# tools/desktop-run.ps1 (see tools/vm.sh <lot> e2e); works in the folder that holds this script.
# -Mode annuaire starts Domenia without --simulation: on the joined VM it reads the directory with the identity of the
# session it runs in (integrated authentication, no password anywhere).
param(
    [string]$Exe = '',
    [string]$Scenarios = '',
    [ValidateSet('simulation', 'annuaire')] [string]$Mode = 'simulation',
    [ValidateSet('Debug', 'Release')] [string]$Configuration = 'Release',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Through SSH (or the output file of the desktop task) the console keeps the OEM code page: UTF-8 keeps the accents.
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
if ($Scenarios -and ($Scenarios -cnotmatch '^[A-Za-z0-9*?_./,-]{1,200}$')) { throw 'Motif de scénarios invalide (-Scenarios) : lettres, chiffres et * ? _ . / , - seulement.' }
if (-not $Output) { $Output = if ($lot) { Join-Path 'C:\DomeniaDev\e2e' $lot } else { 'C:\DomeniaDev\e2e\v2' } }
$runner = Join-Path $root "tests\Domenia.E2E\bin\x64\$Configuration\net10.0-windows\win-x64\Domenia.E2E.exe"
if (-not (Test-Path -LiteralPath $runner)) { throw "Harnais introuvable : $runner (lancer avant tools\build-vm.ps1 -Configuration $Configuration)." }
if (-not $Exe) {
    $pack = if ($lot) { Join-Path 'C:\DomeniaDev\out' "$lot\Domenia\Domenia.exe" } else { 'C:\DomeniaDev\out\Domenia\Domenia.exe' }
    $candidates = @($pack, (Join-Path $root "src\Domenia.App\bin\x64\$Configuration\net10.0-windows\win-x64\Domenia.exe"))
    $Exe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $Exe) { throw 'Aucun Domenia.exe : lancer avant tools\build-vm.ps1 (avec -Publish pour le pack).' }
}
# The harness is framework-dependent: it finds the portable SDK runtime of the VM through DOTNET_ROOT.
$env:DOTNET_ROOT = 'C:\DomeniaDev\dotnet'
$env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$arguments = @('run', '--exe', $Exe, '--scenarios', (Join-Path $root 'tests\e2e'), '--mode', $Mode, '--out', $Output)
if ($Scenarios) { $arguments += @('--filter', $Scenarios) }
"Lancement : $runner $($arguments -join ' ')"
"Session Windows : $([Environment]::UserDomainName)\$([Environment]::UserName), session $((Get-Process -Id $PID).SessionId)."
# Windows PowerShell 5.1 turns each line of the standard error into an error record, which « Stop » would make fatal:
# the harness speaks on both streams, so they are read as plain text here.
$ErrorActionPreference = 'Continue'
& $runner @arguments 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
"Code de sortie : $code"
exit $code
