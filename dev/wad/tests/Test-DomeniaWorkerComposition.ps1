#requires -Version 5.1
# Offline construction only: no generated operation body is executed.
param(
    [string]$DevRoot,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

if (-not $DevRoot) {
    $DevRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

# Load build functions
$BuildSource = Join-Path $DevRoot 'tools/Production.Source.ps1'
if (-not (Test-Path $BuildSource)) { throw "Build source not found: $BuildSource" }
. $BuildSource

# Define operations to test
# Closed factory names: a changed contract may never turn this fixture into an operation launcher.
$factories=@{
    'LocalStore'='Get-DomeniaStorageWorkerCode'
    'StorageUsage'='Get-DomeniaStorageUsageWorkerCode'
    'StoragePurge'='Get-DomeniaStoragePurgeWorkerCode'
    'StorageBackup'='Get-DomeniaStorageBackupWorkerCode'
    'StorageMaintenance'='Get-DomeniaStorageMaintenanceWorkerCode'
    'StorageRetention'='Get-DomeniaStorageRetentionWorkerCode'
    'LiveCache'='Get-DomeniaLiveCacheCode'
    'LegacyMigration'='Get-DomeniaMigrationWorkerCode'
    'LocalIndexRead'='Get-DomeniaLocalIndexReadWorkerCode'
    'RelationHistoryRead'='Get-DomeniaRelationHistoryReadWorkerCode'
    'StorageIntegrity'='Get-DomeniaStorageIntegrityWorkerCode'
    'LiveConsole'='Get-DomeniaLiveProbeCode'
    'LiveSelectedPing'='Get-DomeniaLiveProbeCode'
 }
$ops=@($factories.Keys)

# Load contracts
$ContractPath = Join-Path $DevRoot 'tools/operation-contracts.json'
if (-not (Test-Path $ContractPath)) { throw "Contracts not found: $ContractPath" }
$items = Get-Content $ContractPath -Raw | ConvertFrom-Json
$items = @($items | Where-Object { $_.Operation -in $ops })
if(($items.Count -ne $ops.Count) -or (@($items.Operation | Select-Object -Unique).Count -ne $ops.Count)){throw 'Contrat incomplet ou duplique pour les factories composees.'}
foreach($item in $items){if([string]$item.Function -cne [string]$factories[[string]$item.Operation]){throw ('Factory inattendue : '+$item.Operation)}}

# Collect all module paths needed for AST parsing
$names = @('Common.Model','HealthRules.Model','Boards.Model','ProbeCatalog.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model','Storage.Worker','ProbeDetails.Model')
$paths = @($names | ForEach-Object { Join-Path $DevRoot ('wad/modules/Domenia-' + $_ + '.ps1') })
$paths += @($items | ForEach-Object { Join-Path $DevRoot $_.File })
$paths = @($paths | Select-Object -Unique)

# Parse and load functions into the current scope
foreach ($path in $paths) {
    if (-not (Test-Path $path)) { throw "Missing file: $path" }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse error in $path : $($errors.Message -join '; ')" }

    foreach ($fn in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
        # Load function body as script block
        Set-Item -Path ('Function:' + $fn.Name) -Value $fn.Body.GetScriptBlock()
    }
}

$cache = @{}
$rows = @()

foreach ($item in $items) {
    # 1. Construct trusted source text only; do not execute the generated operation.
    # We call the function defined in the loaded scope
    $runtime = & $item.Function
    # Normalize line endings to LF for comparison
    $runtime = $runtime.Replace("`r`n", "`n").Replace("`r", "`n")

    # 2. Get PROD Body (Using the build logic)
    $build = Get-DomeniaBuildWorkerBody (Join-Path $DevRoot 'wad') $item $cache

    # 3. Compare
    $runtimeHash = Get-DomeniaBuildHash $runtime
    $buildHash = Get-DomeniaBuildHash $build
    $expectedHash = $item.Sha256

    $same = ($runtime -ceq $build)
    $matchesExpected = ($runtimeHash -ceq $expectedHash)

    $rows += [pscustomobject]@{
        Operation = $item.Operation
        RuntimeHash = $runtimeHash
        ProdHash = $buildHash
        ExpectedHash = $expectedHash
        Same = $same
        MatchesExpected = $matchesExpected
    }
}

# Report
$report=[pscustomobject]@{
    Kind='Offline factory construction; no database, directory or operation execution'
    Engine=([string]$PSVersionTable.PSEdition+' '+[string]$PSVersionTable.PSVersion)
    WindowsPowerShell51Executed=(($PSVersionTable.PSEdition -eq 'Desktop') -and ($PSVersionTable.PSVersion.Major -eq 5) -and ($PSVersionTable.PSVersion.Minor -eq 1) -and ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT))
    QualifiesApplication=$false
    Operations=$rows
}
if ($ReportPath) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}

$mismatches = @($rows | Where-Object { (-not $_.Same) -or (-not $_.MatchesExpected) })

if ($mismatches.Count -gt 0) {
    Write-Host "FAIL: $($mismatches.Count) mismatches found." -ForegroundColor Red
    $mismatches | Format-Table
    throw "Worker composition mismatch."
}

Write-Host "PASS: $($rows.Count) operations verified. Runtime and PROD bodies match expected hashes." -ForegroundColor Green