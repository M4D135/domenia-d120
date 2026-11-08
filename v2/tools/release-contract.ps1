# Local release evidence only. Never publishes, signs or downloads anything.
function Get-ContractTextHash([string]$Text) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Assert-ProductionPayloadName([string]$Name, [bool]$Developer) {
    if ($Developer -and $Name.StartsWith('wad/developer/', [StringComparison]::Ordinal)) { return }
    # Private runtimes have their own exact installed-input inventory. The shipped simulation assembly is an
    # intentional product capability; loose test/demo assets and launchers are not that capability.
    if ($Name.StartsWith('wad/runtime/', [StringComparison]::Ordinal)) { return }
    if ($Name -match '(^|/)(tests?|fixtures?|samples?|previews?|screenshots?|developer|node_modules|\.git|\.env)(/|$)' -or
        $Name -match '(^|/)Domenia\.(Tests|WebTests|E2e|Capture)(\.|/)' -or $Name -match '\.(ps1|cmd|bat|sh|py|pdb|log|db|sqlite|env)$') {
        throw "Contenu de recette, lanceur ou donnée privée interdit dans le runtime : $Name"
    }
}

function Write-ReleaseContract([string]$Root, [string]$Directory, [string]$OutBase, $Source, $Metadata, $Environment, [bool]$Developer) {
    if ($Source.sourceDate -cnotmatch '^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}$') { throw 'Date du commit absente du contrat source.' }
    $parsedDate = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Source.sourceDate, 'yyyy.MM.dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) { throw 'Date de commit invalide.' }
    $registryPath = Join-Path $Root 'tools/operation-contracts.json'
    Assert-OrdinaryReleasePath $registryPath
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($registry.format -cne 'Domenia.OperationContracts/1' -or $registry.fingerprint -cnotmatch '^[0-9a-f]{64}$') { throw 'Registre des corps absent ou invalide.' }
    if ($Metadata.build -cnotmatch ('^' + [regex]::Escape($Metadata.version) + '\+[0-9a-f]{64}$')) { throw 'Identité compilée invalide.' }
    $hash = $Metadata.build.Substring($Metadata.version.Length + 1)
    $label = $Source.sourceDate + '-DOMENIA-' + $Metadata.version + '-CANDIDATE-' + $hash
    $claim = [ordered]@{ label = $label; build = $Metadata.build; sourceCommit = $Source.sourceCommit; registryFingerprint = $registry.fingerprint }
    $claimText = $claim | ConvertTo-Json -Compress
    $claims = Join-Path $OutBase 'stages'; New-Item -ItemType Directory -Force -Path $claims | Out-Null
    Assert-OrdinaryReleasePath $claims
    # The stage key excludes the build hash: a second identity cannot silently reuse this same stage.
    $claimPath = Join-Path $claims ($Source.sourceDate + '-DOMENIA-' + $Metadata.version + '-CANDIDATE.json')
    if (Test-Path -LiteralPath $claimPath) {
        Assert-OrdinaryReleasePath $claimPath
        if ((Get-Content -LiteralPath $claimPath -Raw -Encoding UTF8) -cne $claimText) { throw 'Étape déjà utilisée par une autre identité ; aucune livraison écrasée.' }
    } else {
        $bytes = [Text.Encoding]::UTF8.GetBytes($claimText)
        $stream = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    $payload = Join-Path $Directory 'wad'
    $contracts = Join-Path $payload 'contracts'; New-Item -ItemType Directory -Force -Path $contracts | Out-Null
    Assert-OrdinaryReleasePath $contracts
    Copy-Item -LiteralPath $registryPath -Destination (Join-Path $contracts 'operation-contracts.json') -Force
    if ($null -eq $Environment -or -not $Environment.sdk -or -not $Environment.powershell -or -not $Environment.steps) { throw 'Environnement de reconstruction absent.' }
    $environmentText = $Environment | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $contracts 'build-environment.json'), $environmentText, (New-Object Text.UTF8Encoding $false))
    [string[]]$names = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Directory.Length + 1).Replace('\', '/') } | Where-Object { $_ -cnotin @('wad/package-manifest.json', 'wad/.lifecycle.lock', 'wad/package-contract.json') })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $fingerprint = New-Object Text.StringBuilder
    foreach ($name in $names) {
        Assert-ProductionPayloadName $name $Developer
        $file = Join-Path $Directory $name.Replace('/', '\'); Assert-OrdinaryReleasePath $file
        [void]$fingerprint.Append($name).Append('=').Append((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()).Append(':').Append((Get-Item -LiteralPath $file).Length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append("`n")
    }
    $fileVersion = (Get-Item -LiteralPath (Join-Path $Directory 'Domenia.exe')).VersionInfo.FileVersion
    if (-not $fileVersion) { throw 'Version déclarée de Domenia.exe absente.' }
    $contract = [ordered]@{ format = 'Domenia.Release/1'; label = $label; version = $Metadata.version; build = $Metadata.build;
        stage = 'candidate'; channel = 'manual'; sourceCommit = $Source.sourceCommit; sourceDate = $Source.sourceDate;
        registryFingerprint = $registry.fingerprint; executableSha256 = $Metadata.executableSha256; executableVersion = $fileVersion;
        componentsFingerprint = Get-ContractTextHash $fingerprint.ToString() }
    [IO.File]::WriteAllText((Join-Path $payload 'package-contract.json'), ($contract | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
}
