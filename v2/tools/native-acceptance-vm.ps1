# Explicit final acceptance in the existing interactive session. No build, test suite, logoff or restart.
# Invoke through desktop-run.ps1 -Session desktop on EACH VM, with its own reviewed manifest and fresh RunId.
param(
    [Parameter(Mandatory = $true)] [string]$Manifest,
    [ValidateSet('critical-read-only', 'critical-canary', 'read-only', 'canary')] [string]$Mode = 'critical-read-only',
    [ValidateSet('Debug', 'Release')] [string]$Configuration = 'Release',
    [switch]$FinalValidation
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Retain launcher diagnostics even when validation fails before evidence.jsonl can be opened.
$local = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrWhiteSpace($local)) { throw 'Dossier local des preuves indisponible.' }
$launches = Join-Path $local 'Domenia\E2E\NativeAcceptance\launches'
[IO.Directory]::CreateDirectory($launches) | Out-Null
$launchLog = Join-Path $launches ([guid]::NewGuid().ToString('N') + '.log')
$launchStream = [IO.FileStream]::new($launchLog, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
$launchWriter = [IO.StreamWriter]::new($launchStream, [Text.UTF8Encoding]::new($false), 4096, $true)
$logLimited = $false
function Write-RecipeOutput([string]$Line) {
    # A log bound never interrupts the native child after a possible publication.
    if ($Line.Length -le 32768 -and $launchStream.Length + [Text.Encoding]::UTF8.GetByteCount($Line) + 2 -le 4MB - 1024) {
        $launchWriter.WriteLine($Line)
        $launchWriter.Flush()
        $launchStream.Flush($true)
    } elseif (-not $script:logLimited) {
        $script:logLimited = $true
        $launchWriter.WriteLine('Journal de lancement tronque par la borne de 4 Mio/32 Kcar ; consulter evidence.jsonl et les recus. Aucune qualification deduite.')
        $launchWriter.Flush()
        $launchStream.Flush($true)
    }
    Write-Output $Line
}
$code = 1
try {
    Write-RecipeOutput ('Journal de lancement conserve : ' + $launchLog)
    if (-not $FinalValidation) { throw 'Recette reservee a la phase finale : -FinalValidation est requis.' }
    if ((Get-Process -Id $PID).SessionId -eq 0) {
        throw 'Session SSH/service refusee : utiliser desktop-run.ps1 -Session desktop avec la session de bureau deja ouverte.'
    }
    if (-not [IO.Path]::IsPathRooted($Manifest) -or $Manifest.StartsWith('\\') -or $Manifest -match '[\x00-\x1f]') {
        throw 'Manifeste local absolu requis.'
    }
    $manifestPath = [IO.Path]::GetFullPath($Manifest)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or (Get-Item -LiteralPath $manifestPath).Length -gt 16384) {
        throw 'Manifeste absent ou trop volumineux.'
    }
    $root = Split-Path -Parent $PSScriptRoot
    $runnerFolder = Join-Path $root "tests\Domenia.Tests\bin\x64\$Configuration\net10.0-windows\win-x64"
    $runner = Join-Path $runnerFolder 'Domenia.Tests.exe'
    $assembly = Join-Path $runnerFolder 'Domenia.Tests.dll'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf) -or -not (Test-Path -LiteralPath $assembly -PathType Leaf)) {
        throw 'Pilote compile absent. Compiler dans la VM Domenia puis copier ce meme lot sur la VM domaine ; aucun build implicite.'
    }
    $runtime = 'C:\DomeniaDev\dotnet'
    if (-not (Test-Path -LiteralPath (Join-Path $runtime 'dotnet.exe') -PathType Leaf)) {
        throw 'Runtime local absent : aucun telechargement ou installation automatique.'
    }
    $env:DOTNET_ROOT = $runtime
    $env:DOTNET_ROOT_X64 = $runtime
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $OutputEncoding = [Console]::OutputEncoding
    } catch { Write-Warning 'Encodage console UTF-8 indisponible.' }
    # The C# parser alone validates duplicate/unknown JSON keys and the complete identity manifest before connecting.
    Write-RecipeOutput ('VM : ' + $env:COMPUTERNAME + ' ; session : ' + (Get-Process -Id $PID).SessionId)
    Write-RecipeOutput ('Assemblage SHA-256 : ' + (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash.ToLowerInvariant())
    Write-RecipeOutput ('Mode explicite : ' + $Mode + ' ; aucune suite de tests ordinaire ne sera lancee.')
    $previous = Get-Location
    try {
        Set-Location -LiteralPath $runnerFolder
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $runner '--native-acceptance' $manifestPath ('--' + $Mode) 2>&1 | ForEach-Object { Write-RecipeOutput "$_" }
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($null -eq $code -or $code -isnot [int]) { $code = 1 }
    } finally { Set-Location -LiteralPath $previous.Path }
    Write-RecipeOutput ('Code du protocole : ' + $code + '. Examiner les preuves brutes ; ce code ne qualifie pas la recette metier.')
    Write-RecipeOutput ('Preuves et recus conserves sous ' + (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Domenia\E2E\NativeAcceptance'))
} catch {
    $ErrorActionPreference = 'Stop'
    Write-RecipeOutput ('Lancement arrete : ' + $_.Exception.GetType().Name + ' : ' + $_.Exception.Message)
    Write-RecipeOutput 'Consulter les preuves et recus conserves ; aucune relance automatique.'
    $code = 1
} finally {
    try { $launchWriter.Dispose() } finally { $launchStream.Dispose() }
}
Write-Output ('Journal de lancement : ' + $launchLog + ' ; code protocole : ' + $code + ' ; validation metier non deduite.')
exit $code
