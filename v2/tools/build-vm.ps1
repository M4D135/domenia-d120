# Build (and optionally publish) Domenia 2 inside the Domenia VM. Offline: packages come from vendor/nuget and the local cache.
# -Zip (with -Publish) also writes the pack as C:\DomeniaDev\out\Domenia.zip and prints its size.
param([switch]$Publish, [switch]$Zip, [switch]$Test, [string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
# Through SSH the console keeps the OEM code page: UTF-8 keeps the accents of the messages readable.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    Write-Warning ('Encodage UTF-8 de la console non appliqué : ' + $_.Exception.GetType().Name + '.')
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:NUGET_PACKAGES = 'C:\DomeniaDev\nuget-packages'
$dotnet = 'C:\DomeniaDev\dotnet\dotnet.exe'
# The SDK is portable (not registered): framework-dependent test executables find their runtime through DOTNET_ROOT.
$env:DOTNET_ROOT = Split-Path $dotnet; $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
$root = 'C:\DomeniaDev\src\v2'
Set-Location $root
if (-not (Test-Path (Join-Path $root 'Domenia.sln'))) {
    & $dotnet new sln -n Domenia --format sln | Out-Null
}
# Every project of src/ and tests/ belongs to the solution, including ones added after it was created.
$listed = @(& $dotnet sln Domenia.sln list | Where-Object { $_ -like '*.csproj' } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $root $_.Trim())) })
Get-ChildItem -Recurse -Filter *.csproj -Path src, tests | Where-Object { $listed -notcontains $_.FullName } | ForEach-Object {
    "Ajout à la solution : $($_.Name)"
    & $dotnet sln Domenia.sln add $_.FullName | Out-Null
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
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
    if ($Zip) {
        # The archive operators download: one Domenia folder at its root.
        $zipPath = 'C:\DomeniaDev\out\Domenia.zip'
        if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($out, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
        "Archive : $zipPath ($([math]::Round((Get-Item $zipPath).Length/1MB,1)) Mo)"
    }
}
