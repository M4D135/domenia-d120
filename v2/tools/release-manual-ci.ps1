# Prepare and verify the exact corrective archives for David's explicitly authorized manual acceptance.
# Every dependency is already installed on the runner or committed in vendor/nuget. This script never publishes.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $root
$outBase = Join-Path $repo 'artifacts\domenia-v2-delivery'
if (Test-Path -LiteralPath $outBase) { throw 'Dossier de livraison déjà utilisé ; preuves antérieures conservées.' }
$logs = Join-Path $outBase 'logs'
New-Item -ItemType Directory -Path $logs | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false
$previous = Get-Location
$record = [ordered]@{
    format = 'Domenia.ManualDeliveryCI/1'; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    sourceCommit = $null; state = 'started'; phase = 'preflight'; dependenciesDownloaded = $false; published = $false
    installedRuntimeModified = $false; serviceNetworkModified = $false
    domainAcceptance = 'not-run'; uiAcceptance = 'not-run'; twoVmAcceptance = 'not-run'; userManualAcceptance = 'pending'
    packageIntegrity = 'not-run'; privateDotNet = 'not-run'; installedWebView = 'not-run'; webCritical = 'not-run'; simulationUi = 'not-run'
}

function Invoke-ReleaseCommand([string]$Name, [string]$File, [string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    $global:LASTEXITCODE = $null
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $File @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    [IO.File]::WriteAllLines((Join-Path $logs ($Name + '.log')), [string[]]$output, $utf8)
    if ($Name -eq 'source-inventory') { Write-Host 'Inventaire source conservé dans le journal de préparation.' }
    else { foreach ($line in $output) { Write-Host $line } }
    if ($null -eq $code -or $code -ne 0) { throw "Contrôle $Name en échec (code $code) ; aucune installation ou tentative réseau de secours." }
    return [pscustomobject]@{ exitCode = $code; output = $output }
}

function Write-NewReleaseJson([string]$Path, $Value, [int]$Depth = 8) {
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth $Depth))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

$exitCode = 1
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) { throw 'La préparation exige Windows x64.' }
    [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
    Set-Location -LiteralPath $root
    . (Join-Path $PSScriptRoot 'release-packages-vm.ps1')
    . (Join-Path $PSScriptRoot 'private-dotnet-runtime.ps1')
    . (Join-Path $PSScriptRoot 'private-webview-runtime.ps1')
    . (Join-Path $PSScriptRoot 'release-ci-process.ps1')
    . (Join-Path $PSScriptRoot 'measure-package-startup.ps1')
    $commit = @(& git rev-parse HEAD)
    if ($LASTEXITCODE -or $commit.Count -ne 1 -or $commit[0] -cnotmatch '^[0-9a-f]{40}$' -or $commit[0] -cne $env:GITHUB_SHA) { throw 'Commit de livraison absent, ambigu ou différent du checkout demandé.' }
    $record.sourceCommit = $commit[0]
    $record['runnerImage'] = "$env:ImageOS / $env:ImageVersion"
    $record['runId'] = $env:GITHUB_RUN_ID
    $record['sessionId'] = (Get-Process -Id $PID).SessionId
    $ciRoot = Join-Path $repo 'artifacts\domenia-v2-ci'
    $ci = Get-Content -LiteralPath (Join-Path $ciRoot 'logs\result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ci.sourceCommit -cne $record.sourceCommit -or $ci.state -cne 'completed' -or $ci.debug -cne 'passed' -or $ci.release -cne 'passed' -or $ci.critical -cne 'passed' -or $ci.releaseGuardCritical -cne 'passed') {
        throw 'Les compilations et les deux sélections critiques du même SHA doivent réussir avant la livraison.'
    }
    $record['criticalCi'] = $ci
    $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    $dotnet = (Get-Command dotnet -CommandType Application | Select-Object -First 1).Source
    $dotnetRoot = Split-Path -Parent $dotnet
    [void](Invoke-ReleaseCommand 'rebuild-comparison-tests' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tests\tools\test_compare_rebuild.py'), '-v'))
    [void](Invoke-ReleaseCommand 'operation-contract-tests' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tests\tools\test_operation_contracts.py'), '-v'))
    [void](Invoke-ReleaseCommand 'critical-manual-package-tests' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tests\tools\test_verify_manual_packages.py'), '-v'))
    $record['manualPackageVerifierCritical'] = 'passed'
    [void](Invoke-ReleaseCommand 'critical-browser-evidence-tests' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tests\tools\test_verify_ci_browser_evidence.py'), '-v'))
    $record['browserEvidenceVerifierCritical'] = 'passed'
    $record.phase = 'source-inventory'
    $prepared = Invoke-ReleaseCommand 'source-inventory' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tools\prepare-release-source.py'))
    $source = ($prepared.output -join "`n") | ConvertFrom-Json
    Write-NewReleaseJson (Join-Path $root '.release-source.json') $source
    [void](Read-ReleaseSource $root)
    if ($source.sourceCommit -cne $record.sourceCommit) { throw 'Inventaire source différent du commit de livraison.' }
    $versionSource = Get-Content -LiteralPath (Join-Path $root 'src\Domenia.Core\ProductInfo.cs') -Raw -Encoding UTF8
    $versions = [regex]::Matches($versionSource, 'DevelopmentVersion = "([0-9A-Za-z.\-]+)"')
    if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value -cne '2.1.6') { throw 'Version 2.1.6 non déclarée.' }
    $version = $versions[0].Groups[1].Value
    $storeSource = Get-Content -LiteralPath (Join-Path $root 'src\Domenia.Store\Sqlite\DomeniaDatabase.cs') -Raw -Encoding UTF8
    if ($storeSource -notmatch 'versions\[0\]\["value"\] != "11"' -or $storeSource -notmatch 'SupportedDataSchemaRevision = 2;') { throw 'Schéma du magasin différent du contrat de livraison 11/2.' }
    $record.phase = 'runtime-inventory'
    # Windows images replace serviced patch versions. Select one installed, stable common
    # patch across hostfxr/NETCore/WindowsDesktop; freeze its inventory before the exact-pack tests.
    # Never download a runtime or silently select an older patch than the qualified CI baseline.
    $net = Get-PrivateDotNetRuntime -DotNetRoot $dotnetRoot
    if ([version]$net.version -lt [version]'10.0.13') { throw 'Runtime privé 10.0.13 ou correctif 10.0.x plus récent requis sur cette machine de qualification.' }
    # Only PROD-LIGHT is delivered since 2026-11-08 (David): no browser is copied into the pack. The runner's installed
    # Evergreen engine, admitted and inventoried here, is the browser of every web and UI check of the exact pack.
    $web = Get-PrivateWebViewRuntime
    Write-NewReleaseJson (Join-Path $logs 'dotnet-inputs.json') $net
    Write-NewReleaseJson (Join-Path $logs 'webview-inputs.json') $web
    # Fail on browser/module/layout regressions before copying and compressing the private .NET runtime.
    # This source preflight does not replace the later pass against the exact extracted pack.
    $webTests = Join-Path $root 'tests\Domenia.WebTests\bin\x64\Release\net10.0-windows\win-x64\Domenia.WebTests.dll'
    $webPreflight = Join-Path $logs 'web-preflight'
    New-Item -ItemType Directory -Path $webPreflight | Out-Null
    $record.phase = 'web-source-preflight'
    [void](Invoke-ReleaseProcess -FilePath $dotnet -ArgumentList @($webTests, '--root', $root, '--runtime', $web.sourceRoot, '--out', $webPreflight, '--critical') -LogPrefix (Join-Path $logs 'web-preflight') -TimeoutSeconds 660)
    $record['webSourcePreflight'] = 'passed'
    $identity = 'source=' + $record.sourceCommit + "`nsdk=" + $ci.sdk + "`ndotnet=" + $net.inventorySha256 + "`n"
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $buildHash = ([BitConverter]::ToString($hasher.ComputeHash($utf8.GetBytes($identity)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $buildIdentity = $version + '+' + $buildHash
    $record['build'] = $buildIdentity
    $package = Join-Path $outBase 'Domenia'
    $config = Join-Path $ciRoot 'NuGet.offline.config'
    $env:NUGET_PACKAGES = Join-Path $ciRoot 'nuget-packages'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $ciRoot 'nuget-http-cache'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'; $env:DOTNET_NOLOGO = '1'
    $settings = @('-p:SelfContained=false', '-p:PublishReadyToRun=false', '-p:DebugType=None', '-p:DebugSymbols=false', '-p:CopyOutputSymbolsToPublishDirectory=false', '-p:NuGetAudit=false', '-p:RestoreIgnoreFailedSources=false',
        '-p:DisableTransitiveFrameworkReferenceDownloads=true', '-p:EnableRuntimePackDownload=false', '-p:EnableTargetingPackDownload=false', '-p:EnableAppHostPackDownload=false',
        '-p:AppHostDotNetSearch=AppRelative', '-p:AppHostRelativeDotNet=runtime/dotnet', ('-p:RuntimeFrameworkVersion=' + $net.version), '-p:RollForward=Disable',
        '-p:DomeniaRequirePackageManifest=true', '-p:DomeniaWadLayout=true', ('-p:DomeniaBuildIdentity=' + $buildIdentity))
    $project = Join-Path $root 'src\Domenia.App\Domenia.App.csproj'
    $record.phase = 'publish-offline'
    [void](Invoke-ReleaseCommand 'restore-publish-offline' $dotnet (@('restore', $project, '--configfile', $config, '--packages', $env:NUGET_PACKAGES, '--disable-parallel') + $settings))
    [void](Invoke-ReleaseCommand 'publish-private-runtime' $dotnet (@('publish', $project, '-c', 'Release', '-o', $package, '--no-restore', '-nologo', '-v:minimal', '-warnaserror') + $settings))
    $payload = Move-ReleasePayload $package
    $record.phase = 'copy-private-runtime'
    $netCopy = Copy-PrivateDotNetRuntime -Runtime $net -PackageRoot $payload
    Write-NewReleaseJson (Join-Path $logs 'dotnet-copy.json') $netCopy
    $runtimeConfig = Get-Content -LiteralPath (Join-Path $payload 'Domenia.runtimeconfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $frameworks = @($runtimeConfig.runtimeOptions.frameworks)
    if ($runtimeConfig.runtimeOptions.rollForward -cne 'Disable' -or $frameworks.Count -ne 2 -or
        @($frameworks | Where-Object { $_.version -cne $net.version -or $_.name -notin @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App') }).Count -ne 0 -or
        @($frameworks.name | Sort-Object -Unique).Count -ne 2) { throw 'Le runtimeconfig ne fige pas exactement les deux runtimes privés.' }
    $record.phase = 'complete-packages'
    $previousGuiErrors = $env:DOTNET_DISABLE_GUI_ERRORS
    try {
        $env:DOTNET_DISABLE_GUI_ERRORS = '1'
        $buildEnvironment = [ordered]@{ format = 'Domenia.BuildEnvironment/1'; recordedAt = $record.startedAt; sourceCommit = $record.sourceCommit;
            sdk = $ci.sdk; powershell = $PSVersionTable.PSVersion.ToString(); os = [Environment]::OSVersion.Version.ToString();
            dotnetInventory = $net.inventorySha256; nugetInventory = (Get-FileHash -LiteralPath (Join-Path $root 'vendor/nuget/SHA256SUMS') -Algorithm SHA256).Hash.ToLowerInvariant();
            steps = @('offline restore', 'Debug and Release build', 'critical and full C#', 'web source preflight', 'offline publish', 'copy qualified private .NET runtime', 'contract and manifest', 'exact-pack controls');
            deterministic = $true; readyToRun = $false; pathMap = '/_/domenia/'; dependencyDownloads = $false }
        Complete-ReleasePackages -Root $root -OutBase $outBase -Version $version -BuildIdentity $buildIdentity -Zip -PrivateDotNetVersion $net.version -ManualUserAcceptance -BuildEnvironment $buildEnvironment
    } finally { $env:DOTNET_DISABLE_GUI_ERRORS = $previousGuiErrors }
    $receipts = @(Get-ChildItem -LiteralPath $outBase -File -Filter 'Domenia.delivery-*.json')
    if ($receipts.Count -ne 1) { throw 'Reçu de préparation absent ou ambigu.' }
    $delivery = Get-Content -LiteralPath $receipts[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $record['delivery'] = $delivery
    # Verify the archives before extracting and execute these exact extracted bytes, not only the publish directory.
    $record.phase = 'verify-before-extraction'
    $archiveProof = Join-Path $logs 'archive-before-startup.json'
    [void](Invoke-ReleaseCommand 'verify-before-extraction' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tools\verify-manual-packages.py'), '--production-only', '--directory', $delivery.archives, '--commit', $record.sourceCommit, '--version', $version, '--out', $archiveProof))
    $archiveIdentity = Get-Content -LiteralPath $archiveProof -Raw -Encoding UTF8 | ConvertFrom-Json
    $light = Join-Path $outBase 'extracted-PROD-LIGHT'
    if (Test-Path -LiteralPath $light) { throw 'Extraction antérieure conservée.' }
    $lightArchive = Join-Path $delivery.archives ('Domenia_' + $version + '_PROD-LIGHT_Windows-x64.zip')
    [IO.Compression.ZipFile]::ExtractToDirectory($lightArchive, $light)
    $lightDotNet = Join-Path $light 'wad\runtime\dotnet'
    $browserRoot = $web.sourceRoot
    $record.phase = 'measured-interactive-startup'
    $record['measuredStartup'] = @(Measure-PackageStartup $light $logs $archiveIdentity.archives.'PROD-LIGHT'.sha256 $record.sourceCommit $browserRoot)
    $record.phase = 'startup-smokes'
    [void](Invoke-ReleaseProcess -FilePath (Join-Path $light 'Domenia.exe') -ArgumentList @('--check-only') -LogPrefix (Join-Path $logs 'light-start') -PrivateDotNetRoot $lightDotNet)
    $lightHost = Get-Content -LiteralPath (Join-Path $logs 'light-start.stderr.log') -Encoding UTF8 -Raw
    $versions = [regex]::Matches($lightHost, 'WebView2 Evergreen \S+ ([0-9]+(?:\.[0-9]+){3}) ;')
    if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value -cne $web.version) { throw 'Le ZIP LIGHT ne retient pas le moteur Evergreen qualifié du runner ; tests navigateur non lancés.' }
    $lightBrowserVersion = $versions[0].Groups[1].Value
    [void](Invoke-ReleaseProcess -FilePath (Join-Path $light 'Domenia.exe') -ArgumentList @('version') -LogPrefix (Join-Path $logs 'cli-version'))
    # A separate copy without the runtime directories must refuse startup even though the runner has a matching global runtime.
    # CoreHostLibMissingFailure is the native apphost refusal, before managed integrity checks can run.
    $missing = Join-Path $outBase 'check-missing-private-runtime'
    New-Item -ItemType Directory -Path $missing | Out-Null
    Copy-Item -LiteralPath (Join-Path $light 'Domenia.exe') -Destination $missing
    $missingPayload = Join-Path $missing 'wad'
    New-Item -ItemType Directory -Path $missingPayload | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $light 'wad') -File -Force | Copy-Item -Destination $missingPayload
    [void](Invoke-ReleaseProcess -FilePath (Join-Path $missing 'Domenia.exe') -ArgumentList @('--check-only') -LogPrefix (Join-Path $logs 'missing-private-runtime') -ExpectedExitCode -2147450749)
    $record.privateDotNet = 'passed'
    $privateDotnet = Join-Path $lightDotNet 'dotnet.exe'
    $webOutput = Join-Path $logs 'web'
    New-Item -ItemType Directory -Path $webOutput | Out-Null
    $webCheck = @{
        FilePath = $privateDotnet; ArgumentList = @($webTests, '--root', $root, '--runtime', $browserRoot, '--out', $webOutput, '--critical')
        LogPrefix = (Join-Path $logs 'web-critical'); TimeoutSeconds = 660; PrivateDotNetRoot = $lightDotNet; PrivateWebViewRoot = $browserRoot
    }
    $record.phase = 'web-critical'
    [void](Invoke-ReleaseProcess @webCheck)
    $webReports = @(Get-ChildItem -LiteralPath $webOutput -File -Recurse -Filter 'report.json')
    if ($webReports.Count -ne 1) { throw 'Rapport critique WebView absent ou ambigu.' }
    $webReport = Get-Content -LiteralPath $webReports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $webResults = @($webReport.report.results)
    if ($webReport.status -cne 'passed' -or $webReport.error -or $webReport.report.selection -cne 'critical-only' -or
        $webReport.report.passed -le 0 -or $webReport.report.failed -ne 0 -or $webResults.Count -ne $webReport.report.passed -or
        @($webResults | Where-Object { $_.passed -ne $true -or -not $_.name }).Count -ne 0) { throw 'Les tests critiques WebView ne sont pas tous réussis.' }
    $record.webCritical = 'passed'; $record['webCriticalCount'] = $webReport.report.passed; $record.installedWebView = 'passed'
    $uiOutput = Join-Path $logs 'ui-simulation'
    $e2e = Join-Path $root 'tests\Domenia.E2E\bin\x64\Release\net10.0-windows\win-x64\Domenia.E2E.dll'
    $filter = 'accueil/actualiser-ou,accueil/catalogue-widgets,fiche/modifier-description,operations/releve-reprise,parametres/collecte-fenetre,shell/apparence-clavier,synchro/parc-partage'
    $uiCheck = @{
        FilePath = $privateDotnet; ArgumentList = @($e2e, 'run', '--exe', (Join-Path $light 'Domenia.exe'), '--scenarios', (Join-Path $root 'tests\e2e'), '--filter', $filter, '--mode', 'simulation', '--out', $uiOutput)
        LogPrefix = (Join-Path $logs 'ui-simulation-critical'); TimeoutSeconds = 900; PrivateDotNetRoot = $lightDotNet; PrivateWebViewRoot = $browserRoot
    }
    $record.phase = 'ui-simulation-critical'
    [void](Invoke-ReleaseProcess @uiCheck)
    $ui = Get-Content -LiteralPath (Join-Path $uiOutput 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ui.summary.passed -ne 7 -or $ui.summary.failed -ne 0 -or $ui.summary.skipped -ne 0 -or $ui.summary.invalid -ne 0 -or @($ui.scenarios).Count -ne 7) { throw 'Les sept parcours UI critiques en simulation ne sont pas tous réussis.' }
    $browserEvidence = Join-Path $logs 'browser-evidence.json'
    [void](Invoke-ReleaseCommand 'verify-browser-evidence' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tools\verify-ci-browser-evidence.py'),
        '--web-report', $webReports[0].FullName, '--ui-report', (Join-Path $uiOutput 'report.json'), '--package', $light, '--commit', $record.sourceCommit, '--version', $version, '--out', $browserEvidence))
    $browserProof = Get-Content -LiteralPath $browserEvidence -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($browserProof.status -cne 'passed' -or $browserProof.scope -cne 'UI-simulation-smoke' -or $browserProof.sourceCommit -cne $record.sourceCommit -or $browserProof.version -cne $version) { throw 'Captures ou rapports du passage navigateur non qualifiés.' }
    $record.phase = 'light-native-login'
    $loginProof = Join-Path $logs 'light-native-login.json'
    & (Join-Path $root 'tools/test-light-login.ps1') -Package $light -SourceCommit $record.sourceCommit `
        -Archive $lightArchive `
        -ArchiveSha256 $archiveIdentity.archives.'PROD-LIGHT'.sha256 -BrowserVersion $lightBrowserVersion -Evidence $loginProof
    $login = Get-Content -LiteralPath $loginProof -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($login.state -cne 'passed' -or !$login.chooser -or !$login.credentialForm -or !$login.offlineHome -or !@($login.browserProcesses).Count) {
        throw 'Le vrai parcours de connexion du ZIP LIGHT est incomplet.'
    }
    if (@($login.browserProcesses | Where-Object { -not [string]::Equals((Split-Path -Parent $_.path), $browserRoot, [StringComparison]::OrdinalIgnoreCase) }).Count) {
        throw 'La connexion du ZIP LIGHT a utilisé un autre moteur que le moteur Evergreen qualifié.'
    }
    $lightOutput = Join-Path $logs 'ui-light'
    $lightCheck = @{
        FilePath = (Join-Path $lightDotNet 'dotnet.exe')
        ArgumentList = @($e2e, 'run', '--exe', (Join-Path $light 'Domenia.exe'), '--scenarios', (Join-Path $root 'tests/e2e'),
            '--filter', 'accueil/catalogue-widgets', '--mode', 'simulation', '--out', $lightOutput)
        LogPrefix = (Join-Path $logs 'light-evergreen'); TimeoutSeconds = 360
        PrivateDotNetRoot = $lightDotNet; PrivateWebViewRoot = $browserRoot
    }
    [void](Invoke-ReleaseProcess @lightCheck)
    $lightUi = Get-Content -LiteralPath (Join-Path $lightOutput 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($lightUi.summary.passed -ne 1 -or $lightUi.summary.failed -ne 0 -or $lightUi.summary.skipped -ne 0 -or $lightUi.summary.invalid -ne 0 -or @($lightUi.scenarios).Count -ne 1) {
        throw 'Le parcours du ZIP PROD-LIGHT avec Evergreen preinstalle est incomplet.'
    }
    $record['lightEvergreenUi'] = 'passed'
    $record['lightWebViewVersion'] = $lightBrowserVersion
    $record['lightNativeLogin'] = $login.state
    $record.simulationUi = 'passed'; $record['simulationUiCount'] = 7; $record['visualReview'] = 'pending'
    [void](Invoke-ReleaseProcess -FilePath (Join-Path $light 'Domenia.exe') -ArgumentList @('--check-only') -LogPrefix (Join-Path $logs 'light-after-ui') -PrivateDotNetRoot $lightDotNet)
    [void](Read-ReleaseSource $root)
    $record.phase = 'verify-exact-archives'
    $verification = Join-Path $logs 'manual-package-verification.json'
    [void](Invoke-ReleaseCommand 'verify-packages' $python @('-X', 'utf8', '-B', '-I', (Join-Path $root 'tools\verify-manual-packages.py'), '--production-only', '--directory', $delivery.archives, '--commit', $record.sourceCommit, '--version', $version, '--out', $verification))
    $verified = Get-Content -LiteralPath $verification -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($verified.eligibleForManualDelivery -ne $true -or $verified.sourceCommit -cne $record.sourceCommit) { throw 'Les archives ne sont pas qualifiées pour la livraison manuelle.' }
    $record.packageIntegrity = 'passed'
    $publish = Join-Path $outBase 'publish'
    New-Item -ItemType Directory -Path $publish | Out-Null
    foreach ($name in @(('Domenia_' + $version + '_PROD-LIGHT_Windows-x64.zip'), 'source-commit.json', 'SHA256SUMS.txt')) {
        $inputFile = Join-Path $delivery.archives $name
        $destination = Join-Path $publish $name
        Copy-Item -LiteralPath $inputFile -Destination $destination
        if ((Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { throw 'Archive modifiée pendant sa préparation pour transfert.' }
    }
    Copy-Item -LiteralPath $verification -Destination (Join-Path $publish 'verification-paquets.json')
    $record['artifacts'] = $publish
    $record['executableSha256'] = $delivery.executableSha256
    $record.state = 'completed'; $record.phase = 'completed'
    $exitCode = 0
} catch {
    $record.state = 'failed'; $record['error'] = $_.Exception.Message
    $failureDetails = $_.Exception.ToString() + "`r`n" + $_.InvocationInfo.PositionMessage + "`r`n" + $_.ScriptStackTrace
    [IO.File]::WriteAllText((Join-Path $logs 'failure.log'), $failureDetails, $utf8)
    Write-Host ('Préparation de livraison interrompue : ' + $_.Exception.Message)
} finally {
    $record['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    Write-NewReleaseJson (Join-Path $logs 'delivery-result.json') $record
    Set-Location -LiteralPath $previous.Path
}
exit $exitCode
