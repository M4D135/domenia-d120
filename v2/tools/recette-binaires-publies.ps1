# Checks of the PUBLISHED Domenia pack, run on a disposable hosted runner only. The reference is the current release
# recorded in packs/manifest.json of the tested commit (version, URLs and SHA-256 pinned in the repository): its ZIP is
# downloaded and verified, then the product's own commands are driven (--check-only, --check-settings-seed, livraison).
# A candidate ZIP from a delivery CI run can be added: it then plays the newer package, with a real update of the
# reference (default configuration written in place) and a restoration back to it. No service, firewall, WinRM, policy
# or account is changed; nothing outside $Work is written. Restoring a release older than 2.1.6 is no longer exercised
# here (those releases were removed on 2026-11-12): C# tests cover it and run 43241745675 observed it on real binaries.
param([Parameter(Mandatory = $true)][string]$Work, [string]$CandidateZip, [string]$CandidateVersion, [string]$CandidateSha256,
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\..\packs\manifest.json'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'release-ci-process.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

$seedName = 'Domenia.settings.seed.json'
$releaseBase = 'https://github.com/M4D135/domenia-d120/releases/download/v'
if (Test-Path -LiteralPath $Work) { throw 'Dossier de travail deja present ; rien n est reutilise.' }
New-Item -ItemType Directory -Path $Work | Out-Null
$logs = Join-Path $Work 'logs'; New-Item -ItemType Directory -Path $logs | Out-Null
$report = [ordered]@{ format = 'Domenia.PublishedBinaryChecks/2'; startedAt = (Get-Date).ToUniversalTime().ToString('o'); steps = @() }
$script:index = 0

function Add-Step([string]$Name, [string]$State, [string]$Detail) {
    $report.steps += [ordered]@{ step = $Name; state = $State; detail = $Detail }
    Write-Host ($State.ToUpperInvariant().PadRight(9) + $Name + $(if ($Detail) { ' :: ' + $Detail } else { '' }))
}

function Get-Sha([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

function Get-Reference([string]$Path) {
    $manifest = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $version = [string]$manifest.version
    if ($version -notmatch '^2\.[0-9]+\.[0-9]+$') { throw ('Version de reference invalide : ' + $version) }
    $archive = @($manifest.archives | Where-Object { $_.edition -eq 'PROD-LIGHT' })
    if ($archive.Count -ne 1) { throw 'Archive PROD-LIGHT absente ou ambigue dans le manifeste.' }
    $name = 'Domenia_' + $version + '_PROD-LIGHT_Windows-x64.zip'
    $base = $releaseBase + $version + '/'
    if ($archive[0].filename -cne $name -or $archive[0].download_url -cne ($base + $name) -or $manifest.checksums.download_url -cne ($base + 'SHA256SUMS.txt')) {
        throw 'Adresses du manifeste hors de la release attendue.'
    }
    foreach ($value in @($archive[0].sha256, $manifest.checksums.sha256)) { if ($value -notmatch '^[0-9a-f]{64}$') { throw 'Empreinte du manifeste invalide.' } }
    return [pscustomobject]@{ Version = $version; Name = $name; Base = $base; Sha256 = [string]$archive[0].sha256; SumsSha256 = [string]$manifest.checksums.sha256 }
}

function Get-Pack($Reference) {
    $folder = Join-Path $Work ('release-' + $Reference.Version); New-Item -ItemType Directory -Path $folder | Out-Null
    $zip = Join-Path $folder $Reference.Name; $sums = Join-Path $folder 'SHA256SUMS.txt'
    Invoke-WebRequest -UseBasicParsing -Uri ($Reference.Base + $Reference.Name) -OutFile $zip
    Invoke-WebRequest -UseBasicParsing -Uri ($Reference.Base + 'SHA256SUMS.txt') -OutFile $sums
    $hash = Get-Sha $zip
    if ($hash -cne $Reference.Sha256) { throw ('Empreinte de ' + $Reference.Name + ' differente du manifeste : ' + $hash) }
    if ((Get-Sha $sums) -cne $Reference.SumsSha256) { throw 'SHA256SUMS.txt different du manifeste.' }
    $line = @(Get-Content -LiteralPath $sums | Where-Object { $_ -like ('*' + $Reference.Name) })
    if ($line.Count -ne 1 -or $line[0].Trim() -cne ($hash + '  ' + $Reference.Name)) { throw ('SHA256SUMS.txt de v' + $Reference.Version + ' ne confirme pas le ZIP.') }
    return $zip
}

function Expand-Pack([string]$Zip, [string]$Name) {
    $folder = Join-Path $Work $Name
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $folder)
    return $folder
}

function Invoke-Domenia([string]$Pack, [string[]]$Arguments, [int]$Expected, [string]$Label, [int]$Timeout = 180) {
    $script:index++
    $prefix = Join-Path $logs (('{0:D2}-' -f $script:index) + $Label)
    [void](Invoke-ReleaseProcess -FilePath (Join-Path $Pack 'Domenia.exe') -ArgumentList $Arguments -LogPrefix $prefix -ExpectedExitCode $Expected -TimeoutSeconds $Timeout)
    return [pscustomobject]@{
        Output = [IO.File]::ReadAllText($prefix + '.stdout.log', [Text.Encoding]::UTF8)
        Error = [IO.File]::ReadAllText($prefix + '.stderr.log', [Text.Encoding]::UTF8)
    }
}

function Get-LastJson([string]$Text) {
    $lines = @($Text -split "\r?\n" | Where-Object { $_.TrimStart().StartsWith('{') })
    if ($lines.Count -lt 1) { throw 'Aucun resultat JSON dans la sortie de la commande.' }
    return ($lines[$lines.Count - 1] | ConvertFrom-Json)
}

function Write-Seed([string]$Path, [int]$Zoom) {
    $text = "{`n  `"format`": `"domenia.preferencesExport`",`n  `"version`": 1,`n  `"exportedAt`": `"2026-11-12T12:00:00Z`",`n" +
        "  `"mode`": `"Annuaire`",`n  `"values`": {`n    `"settings.zoom`": $Zoom`n  }`n}"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false))
    return Get-Sha $Path
}

function Get-PackVersion([string]$Pack) {
    return ([IO.File]::ReadAllText((Join-Path $Pack 'wad\package-release.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version
}

$reference = $null; $zipRef = $null
try {
    $reference = Get-Reference $ManifestPath
    $zipRef = Get-Pack $reference
    $report['reference'] = [ordered]@{ version = $reference.Version; sha256 = $reference.Sha256 }
    Add-Step ('telechargement de la release v' + $reference.Version + ' du manifeste') 'passed' ('ZIP ' + $reference.Sha256 + ', egal au manifeste et a SHA256SUMS.txt')
} catch { Add-Step 'telechargement de la release de reference' 'failed' $_.Exception.Message }
$newest = $(if ($reference) { $reference.Version } else { $null }); $zipNew = $zipRef
if ($CandidateZip) {
    try {
        if (-not $reference) { throw 'Candidat sans reference publiee verifiee.' }
        if ($CandidateVersion -notmatch '^2\.[0-9]+\.[0-9]+$' -or [version]$CandidateVersion -le [version]$reference.Version) { throw 'Version candidate invalide ou non posterieure a la reference.' }
        $hash = Get-Sha $CandidateZip
        if ($hash -cne $CandidateSha256.ToLowerInvariant()) { throw ('Empreinte du candidat differente : ' + $hash) }
        $newest = $CandidateVersion; $zipNew = $CandidateZip; $report['candidate'] = [ordered]@{ version = $CandidateVersion; sha256 = $hash }
        Add-Step ('candidat ' + $CandidateVersion) 'passed' ('ZIP ' + $hash)
    } catch { Add-Step 'candidat' 'failed' $_.Exception.Message; $zipNew = $null }
}

# 1. Startup admission with the newest binaries (the reference release, or the candidate).
if ($zipNew) {
    try {
        $pack = Expand-Pack $zipNew ('admission-' + $newest)
        $wad = Join-Path $pack 'wad'; $seed = Join-Path $wad $seedName
        [void](Invoke-Domenia $pack @('--check-only') 0 'admission-reference')
        Add-Step ($newest + ' sans configuration par defaut : --check-only') 'passed' 'code 0'
        $sha = Write-Seed $seed 110
        $run = Invoke-Domenia $pack @('--check-only') 0 'admission-seed-wad'
        Add-Step ($newest + ' avec wad\Domenia.settings.seed.json hors manifeste : --check-only') 'passed' ('code 0, seed ' + $sha)
        [void](Invoke-Domenia $pack @('--check-settings-seed', $seed) 0 'check-seed-valide')
        Add-Step '--check-settings-seed sur un fichier valide' 'passed' 'code 0'
        $bad = Join-Path $Work 'seed-refuse.json'
        [IO.File]::WriteAllText($bad, ([IO.File]::ReadAllText($seed).Replace('settings.zoom', 'connection.password')), (New-Object Text.UTF8Encoding $false))
        [void](Invoke-Domenia $pack @('--check-settings-seed', $bad) 2 'check-seed-refuse')
        Add-Step '--check-settings-seed sur une cle interdite' 'passed' 'code 2'
        Move-Item -LiteralPath $seed -Destination (Join-Path $pack $seedName)
        $run = Invoke-Domenia $pack @('--check-only') 1 'admission-seed-racine'
        Add-Step ($newest + ' avec le fichier a la racine (mauvais emplacement) : refus') 'passed' ('code 1 ; ' + (($run.Error -split "\r?\n" | Where-Object { $_ } | Select-Object -Last 1)))
        Move-Item -LiteralPath (Join-Path $pack $seedName) -Destination $seed
        $part = $seed + '.domenia-' + ('a' * 32) + '.part'
        [IO.File]::WriteAllText($part, 'partiel')
        $run = Invoke-Domenia $pack @('--check-only') 1 'admission-part'
        if ($run.Error -notmatch 'interrompue') { throw 'Refus du temporaire sans la consigne d ecriture interrompue.' }
        Add-Step ($newest + ' avec un temporaire .part laisse : refus avec consigne') 'passed' 'code 1, ecriture interrompue'
        Remove-Item -LiteralPath $part
        [void](Invoke-Domenia $pack @('--check-only') 0 'admission-apres-part')
        if ((Get-Sha $seed) -cne $sha) { throw 'Configuration par defaut modifiee par les controles.' }
        Add-Step ($newest + ' apres retrait du temporaire : --check-only') 'passed' 'code 0, seed inchange'
    } catch { Add-Step ('admission au demarrage (' + $newest + ')') 'failed' $_.Exception.Message }
}

# 2. Without a candidate: the published package drives its own maintenance route; updating to itself is refused.
if ($zipRef -and -not $CandidateZip) {
    try {
        $target = Expand-Pack $zipRef 'installation'
        $source = Expand-Pack $zipRef ('source-' + $reference.Version)
        $run = Invoke-Domenia $source @('livraison', 'apercu', $target) 2 'livraison-meme-version' 600
        if ($run.Error -notmatch 'actif') { throw 'Refus sans le motif du paquet deja actif.' }
        Add-Step ('livraison apercu ' + $reference.Version + ' sur elle-meme : refus, paquet deja actif') 'passed' 'code 2'
    } catch { Add-Step 'livraison sur la meme version' 'failed' $_.Exception.Message }
}

# 3. Candidate: real update reference -> candidate (default configuration written in place when the reference admits it),
#    health confirmed by the real WebView2 probe, then restoration back to the reference.
if ($zipRef -and $CandidateZip -and $zipNew) {
    $transaction = $null; $withSeed = [version]$reference.Version -ge [version]'2.1.6'
    try {
        $target = Expand-Pack $zipRef 'installation'
        $source = Expand-Pack $zipNew ('source-' + $newest)
        $seed = Join-Path $target ('wad\' + $seedName); $seedSha = $null
        if ($withSeed) { $seedSha = Write-Seed $seed 140 }
        [void](Invoke-Domenia $target @('--check-only') 0 'reference-installee')
        Add-Step ($reference.Version + ' extraite' + $(if ($withSeed) { ', fichier ecrit sur place' } else { '' }) + ' : --check-only') 'passed' 'code 0'
        $run = Invoke-Domenia $source @('livraison', 'apercu', $target) 0 'livraison-apercu' 600
        $plan = Get-LastJson $run.Error
        if ($withSeed -and (-not (@($plan.Preserved) -contains ('wad/' + $seedName)) -or ((@($plan.Removed) + @($plan.Replaced)) -contains ('wad/' + $seedName)))) { throw 'Fichier non conserve dans le plan.' }
        Add-Step ('livraison apercu ' + $reference.Version + ' -> ' + $newest) 'passed' ('confirmation ' + $plan.Confirmation.Substring(0, 12) + '...')
        $run = Invoke-Domenia $source @('livraison', 'appliquer', $target, $plan.Confirmation) 0 'livraison-appliquer' 900
        $result = Get-LastJson $run.Error; $transaction = $result.Transaction
        if ($result.Action -cne 'update' -or $result.HealthConfirmed -ne $true) { throw ('Mise a jour non confirmee : ' + $result.Action + ', sante ' + $result.HealthConfirmed) }
        if ((Get-PackVersion $target) -cne $newest) { throw ('Installation non passee en ' + $newest + '.') }
        if ($withSeed -and (Get-Sha $seed) -cne $seedSha) { throw 'Configuration par defaut modifiee par la mise a jour.' }
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-mise-a-jour')
        Add-Step ('livraison appliquer ' + $reference.Version + ' -> ' + $newest + $(if ($withSeed) { ', fichier conserve a l octet' } else { '' })) 'passed' ('action update, sante True, transaction ' + $transaction)
        $run = Invoke-Domenia $source @('livraison', 'apercu-restauration', $target, $transaction) 0 'restauration-apercu' 600
        $plan = Get-LastJson $run.Error
        [void](Invoke-Domenia $source @('livraison', 'restaurer', $target, $transaction, $plan.Confirmation) 0 'restauration' 900)
        if ((Get-PackVersion $target) -cne $reference.Version) { throw 'Restauration incomplete.' }
        if ($withSeed -and (Get-Sha $seed) -cne $seedSha) { throw 'Configuration par defaut modifiee par la restauration.' }
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-restauree')
        Add-Step ('livraison restaurer ' + $newest + ' -> ' + $reference.Version + $(if ($withSeed) { ', fichier conserve' } else { '' })) 'passed' ('version ' + $reference.Version + ' demarre, code 0')
    } catch { Add-Step ('mise a jour et restauration ' + $reference.Version + ' <-> ' + $newest) 'failed' $_.Exception.Message }
}

$report['finishedAt'] = (Get-Date).ToUniversalTime().ToString('o')
$failed = @($report.steps | Where-Object { $_.state -eq 'failed' }).Count
$report['failed'] = $failed
[IO.File]::WriteAllText((Join-Path $logs 'recette-binaires.json'), ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
if ($failed) { throw ('' + $failed + ' controle(s) en echec ; journaux conserves.') }
