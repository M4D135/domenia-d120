# Build (and optionally publish) Domenia 2 inside the Domenia VM. Offline: packages come from vendor/nuget and the local cache.
# Works in the folder that holds this script: C:\DomeniaDev\src\<lot>\v2 (one folder per batch of the team, see
# tools/vm.sh) or the historical C:\DomeniaDev\src\v2.
# -Publish writes the pack to C:\DomeniaDev\out\<lot>\Domenia (historical folder: C:\DomeniaDev\out\Domenia);
# This internal PROD test pack is never zipped: only the PROD-LIGHT archive is delivered, by the delivery CI (2026-11-08).
param([switch]$Publish, [switch]$Zip, [switch]$Test, [switch]$Critical, [ValidatePattern('^[A-Za-z0-9_.]{1,128}$')][string]$TestFilter, [string]$Configuration = 'Debug')
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
if ($Zip) { throw 'Aucune archive PROD : seul le pack PROD-LIGHT est livré, par la CI de livraison (décision du 08/11/2026).' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:NUGET_PACKAGES = 'C:\DomeniaDev\nuget-packages'
$dotnet = 'C:\DomeniaDev\dotnet\dotnet.exe'
# The SDK is portable (not registered): framework-dependent test executables find their runtime through DOTNET_ROOT.
$env:DOTNET_ROOT = Split-Path $dotnet; $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
# The tree of this script (tools\ is one level below v2\).
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'release-packages-vm.ps1') # parse the publisher on every build, without publishing
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
if (($Critical -or $TestFilter) -and -not $Test -or ($Critical -and $TestFilter)) { throw 'Sélection critique ou filtre réservés aux tests, sans combinaison.' }
if ($Test) {
    $testArguments = @(); if ($Critical) { $testArguments += '--critical' }; if ($TestFilter) { $testArguments += $TestFilter }
    & (Join-Path $root "tests\Domenia.Tests\bin\x64\$Configuration\net10.0-windows\win-x64\Domenia.Tests.exe") @testArguments
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
if ($Publish) {
    $qualifiedSource = Read-ReleaseSource $root
    $qualifiedSeed = Read-ReleaseSeed $root $qualifiedSource
    if ($null -ne $qualifiedSeed) {
        & (Join-Path $root 'src\Domenia.App\bin\x64\Release\net10.0-windows\win-x64\Domenia.exe') --check-settings-seed (Join-Path $root '.release-seed.json')
        if ($LASTEXITCODE) { throw 'Configuration de distribution invalide ; aucun ancien pack remplacé.' }
        # Check again after semantic validation; a racing change can never enter the new manifest unnoticed.
        [void](Read-ReleaseSeed $root $qualifiedSource)
    }
    # Identity derives from exact inputs, never from the clock, an arbitrary cache order or an invented commit id.
    $identitySource = Get-Content -LiteralPath 'src\Domenia.Core\ProductInfo.cs' -Raw
    $versionMatch = [regex]::Matches($identitySource, 'DevelopmentVersion = "([0-9A-Za-z.\-]+)"')
    if ($versionMatch.Count -ne 1) { throw 'Version déclarée de livraison absente ou ambiguë.' }
    $releaseVersion = $versionMatch[0].Groups[1].Value
    if ($releaseVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Publication refusée : version stable non déclarée ; aucun ancien pack remplacé.' }
    [string[]]$sourcePaths = @(Get-ChildItem -LiteralPath 'src', 'web' -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') })
    $sourcePaths += 'Directory.Build.props'
    [Array]::Sort($sourcePaths, [StringComparer]::Ordinal)
    if ($sourcePaths.Count -gt 16384) { throw "Trop de fichiers source pour l’identité de livraison." }
    $identityText = New-Object Text.StringBuilder
    $sourceBytes = 0L
    foreach ($relative in $sourcePaths) {
        if ($relative.Length -gt 512 -or $relative -match '[\x00-\x1F]') { throw 'Chemin source hors contrat de livraison.' }
        $inputFile = Get-Item -LiteralPath (Join-Path $root $relative)
        if (($inputFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Entrée de build redirigée.' }
        $sourceBytes += $inputFile.Length
        if ($sourceBytes -gt 268435456) { throw 'Entrées source de livraison supérieures à 256 Mio.' }
        [void]$identityText.Append($relative).Append([char]0).Append($inputFile.Length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append([char]0).Append((Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()).Append("`n")
    }
    $sdkIdentity = @(& $dotnet --version)
    if ($LASTEXITCODE -or $sdkIdentity.Count -ne 1 -or $sdkIdentity[0] -notmatch '^\d+\.\d+\.\d+([\-A-Za-z0-9.]+)?$') { throw 'Identité du SDK local non qualifiée.' }
    [void]$identityText.Append('sdk').Append([char]0).Append($sdkIdentity[0]).Append("`n")
    $browserCandidates = @(Get-ChildItem -Recurse -File -Filter msedgewebview2.exe -Path 'C:\DomeniaDev\cache\webview2\runtime')
    if ($browserCandidates.Count -ne 1) { throw 'Runtime WebView2 fixe absent ou ambigu dans le cache local ; aucun choix implicite ni téléchargement.' }
    $src = $browserCandidates[0]
    [string[]]$browserPaths = @(Get-ChildItem -LiteralPath $src.DirectoryName -Recurse -File | ForEach-Object { $_.FullName.Substring($src.DirectoryName.Length + 1) })
    [Array]::Sort($browserPaths, [StringComparer]::Ordinal)
    if ($browserPaths.Count -gt 4096) { throw 'Runtime WebView2 supérieur au plafond de fichiers.' }
    $browserBytes = 0L
    foreach ($relative in $browserPaths) {
        $inputFile = Get-Item -LiteralPath (Join-Path $src.DirectoryName $relative)
        if (($inputFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Runtime WebView2 redirigé.' }
        $browserBytes += $inputFile.Length
        if ($browserBytes -gt 8589934592 -or $relative.Length -gt 512 -or $relative -match '[\x00-\x1F]') { throw 'Runtime WebView2 hors limites.' }
        [void]$identityText.Append('webview2/').Append($relative.Replace('\', '/')).Append([char]0).Append($inputFile.Length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append([char]0).Append((Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()).Append("`n")
    }
    $identityHasher = [Security.Cryptography.SHA256]::Create()
    try { $sourceIdentity = ([BitConverter]::ToString($identityHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($identityText.ToString())))).Replace('-', '').ToLowerInvariant() }
    finally { $identityHasher.Dispose() }
    $buildIdentity = $releaseVersion + '+' + $sourceIdentity
    # This is the declared store contract, not an inspection or mutation of an operator database. Fail when that contract changes.
    $storeIdentity = Get-Content -LiteralPath 'src\Domenia.Store\Sqlite\DomeniaDatabase.cs' -Raw
    if ($storeIdentity -notmatch 'versions\[0\]\["value"\] != "11"' -or $storeIdentity -notmatch 'SupportedDataSchemaRevision = 2;') { throw 'Contrat de schéma changé : qualifier explicitement les métadonnées de livraison avant publication.' }
    $out = Join-Path $outBase 'Domenia'
    if (Test-Path $out) { throw 'Dossier de livraison déjà utilisé ; conserver le pack et choisir un nouveau dossier.' }
    & $dotnet publish src\Domenia.App\Domenia.App.csproj -c Release -o $out -nologo -v:minimal -p:PublishReadyToRun=false -p:DebugType=None -p:DebugSymbols=false -p:CopyOutputSymbolsToPublishDirectory=false -p:DomeniaRequirePackageManifest=true -p:DomeniaWadLayout=true -p:AppHostDotNetSearch=AppRelative -p:AppHostRelativeDotNet=runtime/dotnet "-p:DomeniaBuildIdentity=$buildIdentity"
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    $payload = Move-ReleasePayload $out
    $wv = Join-Path $payload 'runtime\webview2'
    New-Item -ItemType Directory -Force -Path $wv | Out-Null
    Copy-Item -Recurse -Force (Join-Path $src.DirectoryName '*') $wv
    $buildEnvironment = [ordered]@{ format = 'Domenia.BuildEnvironment/1'; recordedAt = [DateTimeOffset]::UtcNow.ToString('o'); sourceCommit = $qualifiedSource.sourceCommit;
        sdk = ((& $dotnet --version) | Out-String).Trim(); powershell = $PSVersionTable.PSVersion.ToString(); os = [Environment]::OSVersion.Version.ToString();
        steps = @('committed source inventory', 'Windows build', 'publish', 'copy installed WebView', 'contract and manifest', 'check-only'); deterministic = $true; readyToRun = $false; pathMap = '/_/domenia/' }
    Complete-ReleasePackages -Root $root -OutBase $outBase -Version $releaseVersion -BuildIdentity $buildIdentity -WebViewVersion $src.VersionInfo.ProductVersion -Zip:$Zip -BuildEnvironment $buildEnvironment
}
