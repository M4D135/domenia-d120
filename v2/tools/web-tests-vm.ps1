# Final-development tests only. Uses the already-cached fixed WebView2 in the interactive VM session.
param([ValidateSet('Debug', 'Release')][string]$Configuration = 'Release', [switch]$Critical)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($root -notmatch '^C:\\DomeniaDev\\src\\([a-z0-9][a-z0-9-]{0,39})\\v2$') { throw 'Arborescence de lot VM attendue.' }
$lot = $Matches[1]
if ($lot -in @('cache', 'v2', 'domenia')) { throw 'Lot réservé.' }
if ((Get-Process -Id $PID).SessionId -eq 0) { throw 'Ouvrir le bureau Windows ; les tests WebView2 nécessitent une session interactive.' }
$runner = Join-Path $root "tests\Domenia.WebTests\bin\x64\$Configuration\net10.0-windows\win-x64\Domenia.WebTests.exe"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'Harnais absent : compiler le lot avant les tests.' }
$runtimes = @(Get-ChildItem -LiteralPath 'C:\DomeniaDev\cache\webview2\runtime' -Filter msedgewebview2.exe -File -Recurse | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
if ($runtimes.Count -ne 1) { throw "Un seul runtime fixe local est requis ($($runtimes.Count) trouvé(s)) ; aucun téléchargement ni choix implicite." }
$output = Join-Path 'C:\DomeniaDev\web-tests' $lot
New-Item -ItemType Directory -Path $output -Force | Out-Null
$env:DOTNET_ROOT = 'C:\DomeniaDev\dotnet'
$env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
"Tests web : lot $lot, configuration $Configuration, session $((Get-Process -Id $PID).SessionId), runtime $($runtimes[0])."
$ErrorActionPreference = 'Continue'
$selection = @(); if ($Critical) { $selection += '--critical' }
& $runner --root $root --runtime $runtimes[0] --out $output @selection 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
"Code de sortie : $code ; preuves uniques conservées dans $output."
exit $code
