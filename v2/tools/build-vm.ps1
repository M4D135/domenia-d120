# Build (and optionally publish) Domenia 2 inside the Domenia VM. Offline: packages come from vendor/nuget and the local cache.
# Works in the folder that holds this script: C:\DomeniaDev\src\<lot>\v2 (one folder per batch of the team, see
# tools/vm.sh) or the historical C:\DomeniaDev\src\v2.
# -Publish writes the pack to C:\DomeniaDev\out\<lot>\Domenia (historical folder: C:\DomeniaDev\out\Domenia);
# -Zip (with -Publish) also writes Domenia.zip next to it and prints its size.
param([switch]$Publish, [switch]$Zip, [switch]$Test, [string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Through SSH the console keeps the OEM code page: UTF-8 keeps the accents of the messages readable.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    Write-Warning ('Encodage UTF-8 de la console non appliqué : ' + $_.Exception.GetType().Name + '.')
}
if ($Configuration -notin @('Debug', 'Release')) { throw 'Configuration : Debug ou Release.' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:NUGET_PACKAGES = 'C:\DomeniaDev\nuget-packages'
$dotnet = 'C:\DomeniaDev\dotnet\dotnet.exe'
# The SDK is portable (not registered): framework-dependent test executables find their runtime through DOTNET_ROOT.
$env:DOTNET_ROOT = Split-Path $dotnet; $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
# The tree of this script (tools\ is one level below v2\).
$root = Split-Path -Parent $PSScriptRoot
$lot = ''
if ($root -match '^C:\\DomeniaDev\\src\\([a-z0-9][a-z0-9-]{0,39})\\v2$') { $lot = $Matches[1] }
# Reserved lots would mix with the historical folders (C:\DomeniaDev\src\v2, C:\DomeniaDev\out\Domenia).
if ($lot -in @('cache', 'v2', 'domenia')) { throw "Lot réservé : $lot (dossiers historiques de la VM)." }
$outBase = if ($lot) { Join-Path 'C:\DomeniaDev\out' $lot } else { 'C:\DomeniaDev\out' }
"Arborescence : $root" + $(if ($lot) { " (lot $lot)" } else { '' })
Set-Location $root
if (-not (Test-Path (Join-Path $root 'Domenia.sln'))) {
    & $dotnet new sln -n Domenia --format sln | Out-Null
}
# Every project of src/ and tests/ belongs to the solution, including ones added after it was created; projects removed
# from the tree leave it.
$listed = @(& $dotnet sln Domenia.sln list | Where-Object { $_ -like '*.csproj' } | ForEach-Object { $_.Trim() })
foreach ($entry in $listed) {
    if (-not (Test-Path (Join-Path $root $entry))) {
        "Retrait de la solution : $entry"
        & $dotnet sln Domenia.sln remove $entry | Out-Null
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
}
$present = @($listed | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $root $_)) })
Get-ChildItem -Recurse -Filter *.csproj -Path src, tests | Where-Object { $present -notcontains $_.FullName } | ForEach-Object {
    "Ajout à la solution : $($_.Name)"
    & $dotnet sln Domenia.sln add $_.FullName | Out-Null
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
# « dotnet sln add » reports an unreadable project file but still exits with 0: a project left out would never be built
# while the build reports success, so every project of the tree must now be listed.
$listed = @(& $dotnet sln Domenia.sln list | Where-Object { $_ -like '*.csproj' } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $root $_.Trim())) })
$missing = @(Get-ChildItem -Recurse -Filter *.csproj -Path src, tests | Where-Object { $listed -notcontains $_.FullName })
if ($missing.Count -gt 0) {
    "Projet(s) absent(s) de la solution (fichier illisible ?) : $(($missing | ForEach-Object { $_.Name }) -join ', ')"
    exit 1
}
$logDirectory = Join-Path 'C:\DomeniaDev\build-logs' $(if ($lot) { $lot } else { 'historical' })
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$buildLog = Join-Path $logDirectory ("build-$Configuration.log")
& $dotnet build Domenia.sln -c $Configuration -nologo -v:minimal "-flp:LogFile=$buildLog;Verbosity=normal;Encoding=UTF-8"
$buildExit = $LASTEXITCODE
if ($buildExit) {
    "Compilation $Configuration interrompue (code $buildExit). Journal : $buildLog"
    exit $buildExit
}
"Compilation $Configuration réussie."
if ($Test) {
    & (Join-Path $root "tests\Domenia.Tests\bin\x64\$Configuration\net10.0-windows\win-x64\Domenia.Tests.exe")
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
if ($Publish) {
    $out = Join-Path $outBase 'Domenia'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    & $dotnet publish src\Domenia.App\Domenia.App.csproj -c Release -o $out -nologo -v:minimal -p:PublishReadyToRun=false -p:DomeniaRequirePackageManifest=true
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    $wv = Join-Path $out 'runtime\webview2'
    New-Item -ItemType Directory -Force -Path $wv | Out-Null
    $src = Get-ChildItem -Recurse -Filter msedgewebview2.exe -Path 'C:\DomeniaDev\cache\webview2\runtime' | Select-Object -First 1
    if (-not $src) { throw 'Runtime WebView2 fixe absent du cache local ; aucun téléchargement automatique.' }
    Copy-Item -Recurse -Force (Join-Path $src.DirectoryName '*') $wv
    # Exact bytes, including the fixed browser and .NET runtime. The manifest detects mixed versions; it is not signed.
    [IO.File]::WriteAllBytes((Join-Path $out '.lifecycle.lock'), [byte[]]@())
    $components = @(Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -ne '.lifecycle.lock' } | Sort-Object FullName | ForEach-Object {
        if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Composant du paquet redirigé.' }
        [ordered]@{ path = $_.FullName.Substring($out.Length + 1).Replace('\', '/'); length = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    if ($components.Count -lt 10 -or $components.Count -gt 4096) { throw 'Nombre de composants du paquet hors limites.' }
    $manifest = [ordered]@{ format = 1; files = $components } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $out 'package-manifest.json'), $manifest, (New-Object Text.UTF8Encoding $false))
    # This is a local packaging preflight, not a functional test suite or a network recipe.
    $check = Start-Process -FilePath (Join-Path $out 'Domenia.exe') -ArgumentList '--check-only' -Wait -PassThru -NoNewWindow
    if ($check.ExitCode -ne 0) { throw "Contrôle du paquet refusé (code $($check.ExitCode))." }
    "Pack : $out ($([math]::Round(((Get-ChildItem -Recurse $out | Measure-Object Length -Sum).Sum/1MB),1)) Mo)"
    if ($Zip) {
        # The archive operators download: one Domenia folder at its root.
        $zipPath = Join-Path $outBase 'Domenia.zip'
        if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($out, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
        "Archive : $zipPath ($([math]::Round((Get-Item $zipPath).Length/1MB,1)) Mo)"
    }
}
