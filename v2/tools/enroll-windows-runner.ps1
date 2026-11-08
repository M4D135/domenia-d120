# Enrole un poste Windows comme runner self-hosted de qualification Domenia v2.
# Ce script prépare une MACHINE : il ne construit ni ne teste rien du produit, et n'installe
# jamais le SDK .NET (le contrat de v2/tools/ci-windows.ps1 interdit toute installation pendant
# la CI : « SDK .NET préinstallé absent ; aucun setup-dotnet ni installation autorisés »).
# Le SDK 10.0.401 doit donc être posé sur le poste par l'opérateur avant l'enrôlement, puis
# vérifié ici. Le téléchargement du zip du runner est la seule descente réseau de ce script,
# avec SHA-256 exigé : sans -RunnerZipSha256, le script refuse de télécharger.
param(
    [Parameter(Mandatory = $true)][string]$Repository,          # ex. M4D135/domenia-d120
    [Parameter(Mandatory = $true)][string]$RunnerZipSha256,     # empreinte attendue du zip du runner
    [string]$RunnerVersion = '2.338.2',
    [string]$RunnerName = 'domenia-pc173',
    [string]$Labels = 'domenia-win',
    [string]$QualifRoot = (Join-Path $env:USERPROFILE 'qualif'),
    [string]$RunAsAccount,                                      # ex. .\degun ; vide = compte du service LocalSystem
    [string]$ExpectedSdk = '10.0.401',
    [switch]$RemoveExisting
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say([string]$m) { Write-Output ("[enroll] " + $m) }

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'L’’enrôlement exige Windows 64 bits.'
}
if ($Repository -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw 'Format de dépôt attendu : propriétaire/nom.' }
if ($RunnerZipSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Un SHA-256 de 64 caractères est exigé pour le zip du runner.' }
if ($RunnerName -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $Labels -notmatch '^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$') {
    throw 'Nom de runner ou étiquettes invalides (alphanumériques, point, tiret, underscore).'
}

# 1) Le SDK doit déjà être là, et satisfaire v2/global.json (10.0.401, rollForward latestPatch).
$command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $command) {
    throw ('SDK .NET absent du PATH. L’’installer hors CI (dotnet-install.ps1 -Channel 10.0 -Version ' +
        $ExpectedSdk + ' -InstallDirectory <racine> puis PATH/DOTNET_ROOT), puis relancer ce script.')
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$policy = (Get-Content -LiteralPath (Join-Path $projectRoot 'global.json') -Raw | ConvertFrom-Json).sdk
if ($ExpectedSdk -ne $policy.version -or $policy.rollForward -ne 'latestPatch' -or $policy.allowPrerelease -ne $false) {
    throw 'Version demandee incompatible avec la politique SDK de Domenia.'
}
Push-Location $projectRoot
try {
    $resolved = @(& $command.Source --version 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
} finally { Pop-Location }
if ($exitCode -ne 0 -or $resolved.Count -ne 1 -or $resolved[0] -notmatch '^10\.0\.4[0-9][0-9]$' -or [version]$resolved[0] -lt [version]$policy.version) {
    throw "SDK 10.0.4xx stable, au moins $($policy.version), requis avant enrolement."
}
Say ("SDK retenu : " + $resolved[0])

# 2) Jeton d'enrôlement à usage unique, demandé par l'API avec le jeton du compte.
$githubToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null }
if (-not $githubToken) { throw 'GH_TOKEN (ou GITHUB_TOKEN) requis pour demander un jeton d’’enrôlement.' }
$headers = @{ Authorization = "Bearer $githubToken"; Accept = 'application/vnd.github+json'
             'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'domenia-enroll-runner' }
$api = "https://api.github.com/repos/$Repository"
$token = (Invoke-RestMethod -Method Post -Uri "$api/actions/runners/registration-token" -Headers $headers -TimeoutSec 60).token
if (-not $token) { throw 'Jeton d’’enrôlement refusé par GitHub.' }

# 3) Zip du runner : téléchargé, contrôlé, dépaqueté sous la racine de qualification.
New-Item -ItemType Directory -Force -Path $QualifRoot | Out-Null
$zip = Join-Path $QualifRoot ("actions-runner-win-x64-$RunnerVersion.zip")
$url = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
$install = Join-Path $QualifRoot 'actions-runner'
if ($RemoveExisting -and (Test-Path -LiteralPath $install)) {
    try { & (Join-Path $install 'svc.cmd') stop } catch { Say 'service absent : nothing to stop' }
    Remove-Item -LiteralPath $install -Recurse -Force
}
if (-not (Test-Path -LiteralPath $zip)) {
    Say "téléchargement du runner $RunnerVersion"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 900
}
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $RunnerZipSha256.ToLowerInvariant()) {
    throw "Empreinte du zip du runner non conforme : $actual (attendu $RunnerZipSha256). Rien n'est dépaqueté."
}
Say "empreinte du zip confirmée : $actual"
if (-not (Test-Path -LiteralPath $install)) { New-Item -ItemType Directory -Force -Path $install | Out-Null }
Expand-Archive -LiteralPath $zip -DestinationPath $install -Force

# 4) Racines courtes et privées pour les essais (mêmes contraintes que le workflow de livraison :
#    LOCALAPPDATA/APPDATA à DACL privée, TEMP à DACL native héritée, chemins courts hors MAX_PATH).
foreach ($sub in @('tests\la', 'tests\ro', 'tests\tmp', 'nuget')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $QualifRoot $sub) | Out-Null
}

# 5) Configuration puis service. config.cmd ne reçoit le jeton que par la ligne de commande du
#    poste (usage unique, expiré côté GitHub après utilisation) ; il n'est jamais écrit en fichier.
$configArgs = @('--url', "https://github.com/$Repository", '--token', $token,
                '--name', $RunnerName, '--labels', $Labels, '--replace')
if ($RunAsAccount) { $configArgs += @('--runasaccount', $RunAsAccount) }
Push-Location -LiteralPath $install
try {
    if ($RunAsAccount) {
        $secure = Read-Host "Mot de passe du compte $RunAsAccount" -AsSecureString
        $plain = [Net.NetworkCredential]::new('', $secure).Password
        $secure = $null
        $configArgs += @('--runasservice', '--password', $plain)
        & (Join-Path $install 'config.cmd') @configArgs
        $code = $LASTEXITCODE
        $plain = $null
    } else {
        & (Join-Path $install 'config.cmd') @configArgs
        $code = $LASTEXITCODE
        if ($code -eq 0) { & (Join-Path $install 'svc.cmd') install }
    }
} finally { Pop-Location }
if ($code) { throw "config.cmd a refusé l'enrôlement (code $code)." }
Say ('runner configuré : ' + $RunnerName + ' étiquettes ' + $Labels)
Say ('service : actions.runner.' + ($Repository -replace '/', '.') + '.' + $RunnerName)
Say ('vérification : Get-Service actions.runner.* puis GET /repos/' + $Repository + '/actions/runners')
