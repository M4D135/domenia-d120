# CI compilation only by default. All NuGet inputs are vendored and hashed; never install an SDK or runtime.
# Framework-dependent CI output is not a portable release candidate and must never be packaged as PROD.
param([switch]$Critical, [switch]$FinalValidation)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $root
$output = Join-Path $repo 'artifacts\domenia-v2-ci'
$logs = Join-Path $output 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false
$record = [ordered]@{
    format = 'Domenia.WindowsCI/1'; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    sourceCommit = $null; machine = [Environment]::MachineName; platform = [Environment]::OSVersion.Platform.ToString()
    sdk = $null; debug = 'not-run'; release = 'not-run'; critical = 'not-run'; e2eSelfTests = 'not-run'; releaseGuardCritical = 'not-run'
    portablePackage = $false; domainAcceptance = 'not-run'; uiAcceptance = 'not-run'; twoVmAcceptance = 'not-run'
    dependenciesDownloaded = $false; state = 'started'; error = $null
}
$previous = Get-Location

function Invoke-CiDotnet([string]$Name, [string[]]$Arguments) {
    $path = Join-Path $logs ($Name + '.log')
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $script:dotnet @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $path
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($null -eq $code -or $code -ne 0) { throw "Échec $Name (code $code). Aucun téléchargement de secours : consulter $path." }
}

function Assert-OrdinaryCiInput([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Entrée non ordinaire : $Path" }
    $current = $item.Directory
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Ancêtre redirigé : $Path" }
        $current = $current.Parent
    }
}

$ciExitCode = 1
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) { throw 'Ce contrôle exige Windows x64.' }
    if ($Critical -and -not $FinalValidation) { throw 'Tests critiques réservés à la phase finale : -FinalValidation requis.' }
    if ($FinalValidation -and -not $Critical) { throw '-FinalValidation exige une sélection critique explicite.' }
    Set-Location -LiteralPath $root
    $head = @(& git rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or $head[0] -cnotmatch '^[0-9a-f]{40}$') { throw 'Commit Git absent ou ambigu.' }
    if ($env:GITHUB_SHA -and $env:GITHUB_SHA -cne $head[0]) { throw 'Le checkout ne correspond pas au commit demandé par GitHub.' }
    $record.sourceCommit = $head[0]
    $record['runnerImage'] = "$env:ImageOS / $env:ImageVersion"
    $record['runId'] = $env:GITHUB_RUN_ID
    $record['runAttempt'] = $env:GITHUB_RUN_ATTEMPT
    $command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw 'SDK .NET préinstallé absent ; aucun setup-dotnet ni installation autorisés.' }
    $script:dotnet = $command.Source
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = '1'
    $env:NUGET_PACKAGES = Join-Path $output 'nuget-packages'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $output 'nuget-http-cache'
    Invoke-CiDotnet 'sdk-installed' @('--list-sdks')
    # Running from v2 honors the committed global.json. No roll-forward override or local replacement is allowed.
    $sdk = @(& $script:dotnet --version 2>&1 | ForEach-Object { "$_" })
    [IO.File]::WriteAllLines((Join-Path $logs 'sdk-selection.log'), [string[]]$sdk, $utf8)
    if ($LASTEXITCODE -ne 0 -or $sdk.Count -ne 1 -or $sdk[0] -cnotmatch '^10\.0\.4[0-9][0-9]$' -or [version]$sdk[0] -lt [version]'10.0.401') {
        throw 'Le SDK 10.0.401/latestPatch exigé par global.json nʼest pas préinstallé. Échec explicite ; aucun SDK téléchargé.'
    }
    $record.sdk = $sdk[0]
    Invoke-CiDotnet 'dotnet-info' @('--info')
    $vendor = Join-Path $root 'vendor\nuget'
    $hashFile = Join-Path $vendor 'SHA256SUMS'
    Assert-OrdinaryCiInput $hashFile
    $declared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $packageEvidence = @()
    foreach ($line in [IO.File]::ReadAllLines($hashFile)) {
        if ($line -cnotmatch '^([0-9a-fA-F]{64})  ([A-Za-z0-9._-]+\.nupkg)$') { throw 'Inventaire NuGet invalide : SHA256SUMS.' }
        $expected = $Matches[1].ToLowerInvariant(); $name = $Matches[2]
        if (-not $declared.Add($name)) { throw "Paquet NuGet répété : $name" }
        $path = Join-Path $vendor $name
        Assert-OrdinaryCiInput $path
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "Paquet NuGet altéré : $name" }
        $packageEvidence += [ordered]@{ path = 'vendor/nuget/' + $name; length = (Get-Item -LiteralPath $path).Length; sha256 = $actual }
    }
    $observed = @(Get-ChildItem -LiteralPath $vendor -File -Filter '*.nupkg')
    if ($declared.Count -lt 1 -or $declared.Count -ne $observed.Count -or @($observed | Where-Object { -not $declared.Contains($_.Name) }).Count) { throw 'Le feed local contient des paquets non couverts par SHA256SUMS.' }
    [IO.File]::WriteAllText((Join-Path $logs 'nuget-inputs.json'), ($packageEvidence | ConvertTo-Json -Depth 4), $utf8)
    # A private config with one local feed prevents NuGet audit, global sources and user caches from contacting a server.
    $config = Join-Path $output 'NuGet.offline.config'
    $escaped = [Security.SecurityElement]::Escape($vendor)
    [IO.File]::WriteAllText($config, ('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear/><add key="vendored" value="' + $escaped + '"/></packageSources><fallbackPackageFolders><clear/></fallbackPackageFolders></configuration>'), $utf8)
    $projects = @(Get-ChildItem -LiteralPath (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -File -Filter '*.csproj' | Sort-Object FullName)
    if ($projects.Count -lt 11) { throw 'Projet C# attendu absent du checkout.' }
    $solution = Join-Path $output 'Domenia.CI.sln'
    if (Test-Path -LiteralPath $solution) { throw 'Dossier CI déjà utilisé ; conserver ses preuves et utiliser un checkout propre.' }
    Invoke-CiDotnet 'solution-create' @('new', 'sln', '-n', 'Domenia.CI', '--format', 'sln', '--output', $output)
    Invoke-CiDotnet 'solution-projects' (@('sln', $solution, 'add') + @($projects | ForEach-Object { $_.FullName }))
    $contractsPython = Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1
    & $contractsPython.Source -B -I (Join-Path $root 'tools\update-operation-contracts.py')
    if ($LASTEXITCODE) { throw 'Corps ou registre non épinglés ; compilation refusée.' }
    $settings = @('-p:SelfContained=false', '-p:NuGetAudit=false', '-p:RestoreIgnoreFailedSources=false', '-p:DisableTransitiveFrameworkReferenceDownloads=true')
    Invoke-CiDotnet 'restore-offline' (@('restore', $solution, '--configfile', $config, '--packages', $env:NUGET_PACKAGES, '--disable-parallel') + $settings)
    foreach ($configuration in @('Debug', 'Release')) {
        Invoke-CiDotnet ('build-' + $configuration) (@('build', $solution, '-c', $configuration, '--no-restore', '-nologo', '-v:minimal', '-warnaserror') + $settings)
        $record[$configuration.ToLowerInvariant()] = 'passed'
    }
    if ($Critical) {
        $runner = Join-Path $root 'tests\Domenia.Tests\bin\x64\Release\net10.0-windows\win-x64\Domenia.Tests.exe'
        Assert-OrdinaryCiInput $runner
        $record['testAssemblySha256'] = (Get-FileHash -LiteralPath ([IO.Path]::ChangeExtension($runner, '.dll')) -Algorithm SHA256).Hash.ToLowerInvariant()
        $criticalCode = $null
        $record.critical = 'running'
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $runner --critical 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $logs 'critical-csharp.log')
            $criticalCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        $record['criticalExitCode'] = $criticalCode
        if ($null -eq $criticalCode -or $criticalCode -ne 0) {
            $record.critical = if ($criticalCode -eq 2) { 'selection-refused' } else { 'failed' }
            throw "Sélection C# critique en échec (code $criticalCode) ; les preuves restent conservées."
        }
        $record.critical = 'passed'
        # Pure harness checks: no Domenia process, window or network. Final validation only, with a separate receipt.
        $e2eRunner = Join-Path $root 'tests\Domenia.E2E\bin\x64\Release\net10.0-windows\win-x64\Domenia.E2E.exe'
        Assert-OrdinaryCiInput $e2eRunner
        $record['e2eSelfTestsAssemblySha256'] = (Get-FileHash -LiteralPath ([IO.Path]::ChangeExtension($e2eRunner, '.dll')) -Algorithm SHA256).Hash.ToLowerInvariant()
        $e2eCode = $null
        $record.e2eSelfTests = 'running'
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $e2eRunner self-test 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $logs 'e2e-self-test.log')
            $e2eCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        $record['e2eSelfTestsExitCode'] = $e2eCode
        if ($null -eq $e2eCode -or $e2eCode -ne 0) {
            $record.e2eSelfTests = 'failed'
            throw "Auto-tests du harnais E2E en échec (code $e2eCode) ; aucune recette native déduite."
        }
        $record.e2eSelfTests = 'passed'
        # This dependency-free suite checks rejection of forged/incomplete release evidence only.
        # Its synthetic fixtures are never accepted as native/UI receipts and cannot publish anything.
        # Preserve PATH precedence when Windows also exposes an application-execution alias.
        # Passing every match to & would concatenate their paths instead of selecting an executable.
        $pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $pythonCommand) { throw 'Python préinstallé absent pour les contrôles critiques de la garde ; aucune installation autorisée.' }
        $record['releaseGuardPython'] = $pythonCommand.Source
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $pythonCommand.Source -B -I (Join-Path $root 'tests\tools\test_release_guard.py') -v 2>&1 |
                ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $logs 'critical-release-guard.log')
            $guardCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        $record['releaseGuardExitCode'] = $guardCode
        if ($null -eq $guardCode -or $guardCode -ne 0) {
            $record.releaseGuardCritical = 'failed'
            throw "Garde de publication en échec (code $guardCode) ; aucune validation de livraison déduite."
        }
        $record.releaseGuardCritical = 'passed'
    }
    $record.state = 'completed'; $ciExitCode = 0
} catch {
    $record.state = 'failed'; $record.error = $_.Exception.Message
    [IO.File]::WriteAllText((Join-Path $logs 'failure.log'), $_.Exception.ToString(), $utf8)
    Write-Host ('Contrôle Windows CI interrompu : ' + $_.Exception.Message)
} finally {
    $record['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $logs 'result.json'), ($record | ConvertTo-Json -Depth 6), $utf8)
    Set-Location -LiteralPath $previous.Path
}
exit $ciExitCode
