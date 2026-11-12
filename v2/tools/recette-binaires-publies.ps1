# Checks of the PUBLISHED Domenia packs, run on a disposable hosted runner only. It downloads the exact release ZIPs,
# verifies their SHA-256, then drives the product's own commands: startup admission of the in-place default
# configuration (--check-only, --check-settings-seed) and a real update 2.1.5 -> 2.1.6 followed by a restoration
# (livraison). No service, firewall, WinRM, policy or account is changed; nothing outside $Work is written.
# A candidate ZIP from a delivery CI run can be added: it then plays the newer package (update source, restoration).
param([Parameter(Mandatory = $true)][string]$Work, [string]$CandidateZip, [string]$CandidateVersion, [string]$CandidateSha256)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'release-ci-process.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

$published = [ordered]@{
    '2.1.5' = 'd435e21033ca144bf5ba31c43aa5ce76caa538fa8f9cc19faa1d70a925541a9a'
    '2.1.6' = '3d5ec57e326123a60c46042cffc52c006dac630a9839d505e5f5d8c8b0709b13'
}
$seedName = 'Domenia.settings.seed.json'
if (Test-Path -LiteralPath $Work) { throw 'Dossier de travail deja present ; rien n est reutilise.' }
New-Item -ItemType Directory -Path $Work | Out-Null
$logs = Join-Path $Work 'logs'; New-Item -ItemType Directory -Path $logs | Out-Null
$report = [ordered]@{ format = 'Domenia.PublishedBinaryChecks/1'; startedAt = (Get-Date).ToUniversalTime().ToString('o'); releases = $published; steps = @() }
$script:index = 0

function Add-Step([string]$Name, [string]$State, [string]$Detail) {
    $report.steps += [ordered]@{ step = $Name; state = $State; detail = $Detail }
    Write-Host ($State.ToUpperInvariant().PadRight(9) + $Name + $(if ($Detail) { ' :: ' + $Detail } else { '' }))
}

function Get-Pack([string]$Version) {
    $name = 'Domenia_' + $Version + '_PROD-LIGHT_Windows-x64.zip'
    $folder = Join-Path $Work ('release-' + $Version); New-Item -ItemType Directory -Path $folder | Out-Null
    $zip = Join-Path $folder $name; $sums = Join-Path $folder 'SHA256SUMS.txt'
    $base = 'https://github.com/M4D135/domenia-d120/releases/download/v' + $Version + '/'
    Invoke-WebRequest -UseBasicParsing -Uri ($base + $name) -OutFile $zip
    Invoke-WebRequest -UseBasicParsing -Uri ($base + 'SHA256SUMS.txt') -OutFile $sums
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($hash -cne $published[$Version]) { throw ('Empreinte de ' + $name + ' differente de la release : ' + $hash) }
    $line = @(Get-Content -LiteralPath $sums | Where-Object { $_ -like ('*' + $name) })
    if ($line.Count -ne 1 -or $line[0].Trim() -cne ($hash + '  ' + $name)) { throw ('SHA256SUMS.txt de v' + $Version + ' ne confirme pas le ZIP.') }
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
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-Sha([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

function Get-PackVersion([string]$Pack) {
    return ([IO.File]::ReadAllText((Join-Path $Pack 'wad\package-release.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version
}

$zip215 = $null; $zip216 = $null
try {
    $zip215 = Get-Pack '2.1.5'; $zip216 = Get-Pack '2.1.6'
    Add-Step 'telechargement des releases v2.1.5 et v2.1.6' 'passed' 'empreintes egales a la release et a SHA256SUMS.txt'
} catch { Add-Step 'telechargement des releases' 'failed' $_.Exception.Message }
$newest = '2.1.6'; $zipNew = $zip216
if ($CandidateZip) {
    try {
        if ($CandidateVersion -notmatch '^2\.[0-9]+\.[0-9]+$' -or [version]$CandidateVersion -le [version]'2.1.6') { throw 'Version candidate invalide.' }
        $hash = Get-Sha $CandidateZip
        if ($hash -cne $CandidateSha256.ToLowerInvariant()) { throw ('Empreinte du candidat differente : ' + $hash) }
        $newest = $CandidateVersion; $zipNew = $CandidateZip; $report['candidate'] = [ordered]@{ version = $CandidateVersion; sha256 = $hash }
        Add-Step ('candidat ' + $CandidateVersion) 'passed' ('ZIP ' + $hash)
    } catch { Add-Step 'candidat' 'failed' $_.Exception.Message; $zipNew = $null }
}
$refusesOldRestore = $zipNew -and ([version]$newest -ge [version]'2.1.7')

# 1. Startup admission with the newest binaries (published 2.1.6, or the candidate).
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

# 2. Real update 2.1.5 -> newest by the newest package, with a default configuration present, then restoration.
if ($zip215 -and $zipNew) {
    $target = $null; $source = $null; $transaction = $null; $seedSha = $null
    try {
        $target = Expand-Pack $zip215 'installation'
        $source = Expand-Pack $zipNew ('source-' + $newest)
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-215-reference')
        Add-Step '2.1.5 extraite : --check-only' 'passed' 'code 0'
        $seed = Join-Path $target ('wad\' + $seedName)
        $seedSha = Write-Seed $seed 125
        $run = Invoke-Domenia $target @('--check-only') 1 'cible-215-avec-seed'
        Add-Step '2.1.5 avec un fichier de configuration sur place : refus attendu (2.1.5 ne l admet pas)' 'passed' ('code 1 ; ' + (($run.Error -split "\r?\n" | Where-Object { $_ } | Select-Object -Last 1)))
        $run = Invoke-Domenia $source @('livraison', 'apercu', $target) 0 'livraison-apercu' 600
        $plan = Get-LastJson $run.Error
        $keptSeed = @($plan.Preserved) -contains ('wad/' + $seedName)
        $removedSeed = (@($plan.Removed) + @($plan.Replaced)) -contains ('wad/' + $seedName)
        if (-not $keptSeed -or $removedSeed) { throw ('Plan de mise a jour sans conservation du fichier : conserves ' + (@($plan.Preserved) -join ', ')) }
        Add-Step ('livraison apercu 2.1.5 -> ' + $newest + ' : fichier conserve dans le plan') 'passed' ('confirmation ' + $plan.Confirmation.Substring(0, 12) + '...')
        $run = Invoke-Domenia $source @('livraison', 'appliquer', $target, $plan.Confirmation) 0 'livraison-appliquer' 900
        $result = Get-LastJson $run.Error
        $transaction = $result.Transaction
        if ((Get-PackVersion $target) -cne $newest) { throw ('Installation non passee en ' + $newest + '.') }
        if ((Get-Sha $seed) -cne $seedSha) { throw 'Configuration par defaut modifiee par la mise a jour.' }
        Add-Step ('livraison appliquer : installation en ' + $newest + ', fichier identique') 'passed' ('action ' + $result.Action + ', sante ' + $result.HealthConfirmed + ', transaction ' + $transaction)
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-nouvelle-avec-seed')
        Add-Step ($newest + ' installee par mise a jour, fichier sur place : --check-only') 'passed' 'code 0'
    } catch { Add-Step ('mise a jour 2.1.5 -> ' + $newest) 'failed' $_.Exception.Message }

    if ($transaction -and $refusesOldRestore) {
        try {
            $run = Invoke-Domenia $source @('livraison', 'apercu-restauration', $target, $transaction) 2 'restauration-refusee' 600
            if ($run.Error -notmatch 'Domenia\.settings\.seed\.json') { throw 'Refus de restauration sans le nom du fichier.' }
            if ((Get-PackVersion $target) -cne $newest -or (Get-Sha (Join-Path $target ('wad\' + $seedName))) -cne $seedSha) { throw 'Installation modifiee par le refus.' }
            Add-Step 'restauration vers 2.1.5 avec le fichier sur place : refus avant toute modification' 'passed' 'code 2, fichier nomme, installation intacte'
            Move-Item -LiteralPath (Join-Path $target ('wad\' + $seedName)) -Destination (Join-Path $Work 'seed-deplace-avant-restauration.json')
        } catch { Add-Step 'refus de restauration vers 2.1.5' 'failed' $_.Exception.Message; $transaction = $null }
    }
    if ($transaction) {
        try {
            $run = Invoke-Domenia $source @('livraison', 'apercu-restauration', $target, $transaction) 0 'restauration-apercu' 600
            $plan = Get-LastJson $run.Error
            Add-Step 'livraison apercu-restauration' 'passed' ('conserves : ' + (@($plan.Preserved) -join ', '))
            $run = Invoke-Domenia $source @('livraison', 'restaurer', $target, $transaction, $plan.Confirmation) 0 'restauration' 900
            $version = Get-PackVersion $target
            $present = Test-Path -LiteralPath (Join-Path $target ('wad\' + $seedName))
            Add-Step 'livraison restaurer' 'passed' ('version ' + $version + ', fichier de configuration present : ' + $present)
            # Observation, not an expectation: 2.1.5 does not admit a file outside its manifest.
            $script:index++
            $prefix = Join-Path $logs (('{0:D2}-' -f $script:index) + 'cible-restauree')
            $check = $null
            try { [void](Invoke-ReleaseProcess -FilePath (Join-Path $target 'Domenia.exe') -ArgumentList @('--check-only') -LogPrefix $prefix -ExpectedExitCode 0); $check = 'code 0' }
            catch { $check = 'refus : ' + ((([IO.File]::ReadAllText($prefix + '.stderr.log', [Text.Encoding]::UTF8)) -split "\r?\n" | Where-Object { $_ } | Select-Object -Last 1)) }
            Add-Step ('version restauree ' + $version + ' avec le fichier : --check-only') 'observed' $check
            if ($present) {
                Move-Item -LiteralPath (Join-Path $target ('wad\' + $seedName)) -Destination (Join-Path $Work 'seed-retire-apres-restauration.json')
                [void](Invoke-Domenia $target @('--check-only') 0 'cible-restauree-sans-seed')
                Add-Step ('version restauree ' + $version + ' sans le fichier : --check-only') 'passed' 'code 0'
            }
        } catch { Add-Step ('restauration ' + $newest + ' -> 2.1.5') 'failed' $_.Exception.Message }
    }
}

# 3. Candidate only: update 2.1.6 (default configuration written in place) -> candidate, then restoration to 2.1.6.
if ($zip216 -and $CandidateZip -and $zipNew) {
    $transaction = $null
    try {
        $target = Expand-Pack $zip216 'installation-216'
        $source = Expand-Pack $zipNew ('source-bis-' + $newest)
        $seed = Join-Path $target ('wad\' + $seedName); $seedSha = Write-Seed $seed 140
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-216-avec-seed')
        Add-Step '2.1.6 avec un fichier ecrit sur place : --check-only' 'passed' 'code 0'
        $run = Invoke-Domenia $source @('livraison', 'apercu', $target) 0 'livraison-216-apercu' 600
        $plan = Get-LastJson $run.Error
        if (-not (@($plan.Preserved) -contains ('wad/' + $seedName)) -or ((@($plan.Removed) + @($plan.Replaced)) -contains ('wad/' + $seedName))) { throw 'Fichier non conserve dans le plan.' }
        $run = Invoke-Domenia $source @('livraison', 'appliquer', $target, $plan.Confirmation) 0 'livraison-216-appliquer' 900
        $result = Get-LastJson $run.Error; $transaction = $result.Transaction
        if ((Get-PackVersion $target) -cne $newest -or (Get-Sha $seed) -cne $seedSha) { throw 'Mise a jour incomplete ou fichier modifie.' }
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-216-mise-a-jour')
        Add-Step ('mise a jour 2.1.6 -> ' + $newest + ' : fichier conserve a l octet, demarrage admis') 'passed' ('sante ' + $result.HealthConfirmed + ', transaction ' + $transaction)
        $run = Invoke-Domenia $source @('livraison', 'apercu-restauration', $target, $transaction) 0 'restauration-216-apercu' 600
        $plan = Get-LastJson $run.Error
        [void](Invoke-Domenia $source @('livraison', 'restaurer', $target, $transaction, $plan.Confirmation) 0 'restauration-216' 900)
        if ((Get-PackVersion $target) -cne '2.1.6' -or (Get-Sha $seed) -cne $seedSha) { throw 'Restauration incomplete ou fichier modifie.' }
        [void](Invoke-Domenia $target @('--check-only') 0 'cible-216-restauree')
        Add-Step ('restauration ' + $newest + ' -> 2.1.6 : fichier conserve, 2.1.6 demarre avec') 'passed' 'code 0'
    } catch { Add-Step ('mise a jour et restauration 2.1.6 <-> ' + $newest) 'failed' $_.Exception.Message }
}

$report['finishedAt'] = (Get-Date).ToUniversalTime().ToString('o')
$failed = @($report.steps | Where-Object { $_.state -eq 'failed' }).Count
$report['failed'] = $failed
[IO.File]::WriteAllText((Join-Path $logs 'recette-binaires.json'), ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
if ($failed) { throw ('' + $failed + ' controle(s) en echec ; journaux conserves.') }
