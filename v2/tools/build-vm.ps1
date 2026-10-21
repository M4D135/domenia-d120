# Build (and optionally publish) Domenia 2 inside the Domenia VM. Offline: packages come from vendor/nuget and the local cache.
param([switch]$Publish, [switch]$Test, [string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:NUGET_PACKAGES = 'C:\DomeniaDev\nuget-packages'
$dotnet = 'C:\DomeniaDev\dotnet\dotnet.exe'
$root = 'C:\DomeniaDev\src\v2'
Set-Location $root
if (-not (Test-Path (Join-Path $root 'Domenia.sln'))) {
    & $dotnet new sln -n Domenia --format sln | Out-Null
    Get-ChildItem -Recurse -Filter *.csproj -Path src, tests | ForEach-Object { & $dotnet sln Domenia.sln add $_.FullName | Out-Null }
}
& $dotnet build Domenia.sln -c $Configuration -nologo -clp:NoSummary -v:minimal
if ($LASTEXITCODE) { exit $LASTEXITCODE }
if ($Test) {
    & (Join-Path $root "tests\Domenia.Tests\bin\x64\$Configuration\net10.0-windows\win-x64\Domenia.Tests.exe")
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
if ($Publish) {
    $out = 'C:\DomeniaDev\out\Domenia'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    & $dotnet publish src\Domenia.App\Domenia.App.csproj -c Release -o $out -nologo -v:minimal -p:PublishReadyToRun=false
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    $wv = Join-Path $out 'runtime\webview2'
    New-Item -ItemType Directory -Force -Path $wv | Out-Null
    $src = Get-ChildItem -Recurse -Filter msedgewebview2.exe -Path 'C:\DomeniaDev\cache\webview2\runtime' | Select-Object -First 1
    Copy-Item -Recurse -Force (Join-Path $src.DirectoryName '*') $wv
    "Pack : $out ($([math]::Round(((Get-ChildItem -Recurse $out | Measure-Object Length -Sum).Sum/1MB),1)) Mo)"
}
