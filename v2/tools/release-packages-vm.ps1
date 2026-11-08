. (Join-Path $PSScriptRoot 'release-contract.ps1')
# Dot-sourced by build-vm.ps1. No network, dependency installation or operator data access.
function Read-ReleaseSource([string]$Root) {
    $path = Join-Path $Root '.release-source.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Manifeste source absent : publier avec tools/vm.sh depuis le dépôt commité.' }
    if ((Get-Item -LiteralPath $path).Length -gt 2097152) { throw 'Manifeste source trop grand.' }
    $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($document.format -ne 1 -or $document.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or @($document.files).Count -lt 10 -or @($document.files).Count -gt 4096) { throw 'Manifeste source invalide.' }
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $bytes = 0L
    foreach ($entry in $document.files) {
        $name = [string]$entry.path
        if (-not (Test-ReleaseSourceName $name) -or -not $names.Add($name) -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $entry.length -lt 0) { throw 'Entrée source invalide ou répétée.' }
        $file = Join-Path $Root $name.Replace('/', '\')
        Assert-OrdinaryReleasePath $file
        $actual = Get-Item -LiteralPath $file
        if ($actual.PSIsContainer -or $actual.Length -ne $entry.length -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) { throw "Source différente du commit $($document.sourceCommit) : $name" }
        $bytes += $actual.Length
        if ($bytes -gt 268435456) { throw 'Inventaire source supérieur à 256 Mio.' }
    }
    foreach ($base in @('src', 'web', 'tests', 'tools', 'vendor')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root $base) -Recurse -File) {
            $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
            if (Test-ReleaseSourceName $relative) {
                if (-not $names.Contains($relative)) { throw "Source hors commit présente dans la VM : $relative" }
            }
        }
    }
    return $document
}

function Test-ReleaseSourceName([string]$Name) {
    if ($Name.Length -gt 512 -or $Name -match '[\x00-\x1F\\:<>"|?*]' -or $Name -match '(^|/)(\.|\.\.)(/|$)' -or $Name.StartsWith('/')) { return $false }
    if ($Name -match '(^|/)(bin|obj|\.vs|\.git|__pycache__)(/|$)' -or $Name -match '(\.pyc|\.DS_Store)$') { return $false }
    return $Name -cmatch '^(src|web|tests|tools)/' -or $Name -cin @('Directory.Build.props', 'global.json', 'NuGet.config', 'README.md') -or $Name -cmatch '^docs/[^/]+\.md$' -or $Name -cmatch '^vendor/nuget/([A-Za-z0-9._-]+\.nupkg|SHA256SUMS)$'
}

function Assert-OrdinaryReleasePath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Source ou paquet redirigé : $Path" }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

# Bytes are frozen by the cockpit and bound to the transfer manifest; stale files from a preceding run are ignored.
function Read-ReleaseSeed([string]$Root, $Source) {
    if ($null -eq $Source.seed) { return $null }
    $seed = $Source.seed
    if ($seed.fileName -cne 'Domenia.settings.seed.json' -or $seed.length -lt 1 -or $seed.length -gt 1048576 -or $seed.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Configuration de distribution : métadonnées invalides.' }
    $file = Join-Path $Root '.release-seed.json'
    Assert-OrdinaryReleasePath $file
    $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $seed.length) { throw 'Configuration de distribution : taille différente.' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw 'Configuration de distribution : lecture incomplète.' }
            $offset += $read
        }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $sha = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        if ($sha -cne $seed.sha256) { throw 'Configuration de distribution : empreinte différente.' }
        return ,$bytes
    } finally { $stream.Dispose() }
}

# The native apphost is compiled to load wad/Domenia.dll. Keep only the entry point at the root.
function Move-ReleasePayload([string]$Directory) {
    $payload = Join-Path $Directory 'wad'
    if (Test-Path -LiteralPath $payload) { throw 'Dossier wad déjà présent ; aucune superposition de packs.' }
    New-Item -ItemType Directory -Path $payload | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        if ($item.Name -cnotin @('Domenia.exe', 'wad')) { Move-Item -LiteralPath $item.FullName -Destination $payload }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $payload 'Domenia.dll') -PathType Leaf)) { throw 'Application absente du dossier wad.' }
    return $payload
}

function Write-ReleaseManifest([string]$Directory, [switch]$Light) {
    $payload = Join-Path $Directory 'wad'
    [IO.File]::WriteAllBytes((Join-Path $payload '.lifecycle.lock'), [byte[]]@())
    [string[]]$names = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | Where-Object { $_.FullName -ne (Join-Path $payload '.lifecycle.lock') -and $_.FullName -ne (Join-Path $payload 'package-manifest.json') } | ForEach-Object { $_.FullName.Substring($Directory.Length + 1).Replace('\', '/') })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $components = @(foreach ($name in $names) {
        $path = Join-Path $Directory $name.Replace('/', '\'); Assert-OrdinaryReleasePath $path
        [ordered]@{ path = $name; length = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    # Windows PowerShell 5.1 does not expose dictionary keys to Measure-Object -Property.
    $totalBytes = 0L
    foreach ($component in $components) { $totalBytes += [long]$component['length'] }
    if ($components.Count -lt 10 -or $components.Count -gt 4096 -or $totalBytes -gt 8589934592) { throw 'Composants du paquet hors bornes.' }
    $manifest = if ($Light) { [ordered]@{ format = 2; packageType = 'PROD-LIGHT'; files = $components } }
        else { [ordered]@{ format = 1; files = $components } }
    $json = $manifest | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $payload 'package-manifest.json'), $json, (New-Object Text.UTF8Encoding $false))
}

function Write-FlatReleaseZip([string]$Directory, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { throw "Archive existante conservée : $Destination" }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            [string[]]$paths = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | ForEach-Object { $_.FullName })
            [Array]::Sort($paths, [StringComparer]::Ordinal)
            foreach ($path in $paths) {
                Assert-OrdinaryReleasePath $path
                $name = $path.Substring($Directory.Length + 1).Replace('\', '/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $path, $name, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

# Since 2026-11-08 only PROD-LIGHT is delivered (David): the browser is Evergreen, else the Socle WebView2 pack the operator
# extracts into wad\runtime\webview2; the builder never puts a browser in it. Without a private .NET runtime this completes
# only the internal PROD test pack of the lab VM (fixed WebView2 already copied by build-vm.ps1), never an archive.
function Complete-ReleasePackages([string]$Root, [string]$OutBase, [string]$Version, [string]$BuildIdentity, [string]$WebViewVersion, [switch]$Zip,
    [string]$PrivateDotNetVersion, [switch]$ManualUserAcceptance, $BuildEnvironment) {
    $source = Read-ReleaseSource $Root
    $seedBytes = Read-ReleaseSeed $Root $source
    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Un pack de production exige une version stable déclarée dans ProductInfo.' }
    $light = [bool]$PrivateDotNetVersion
    $kind = if ($light) { 'PROD-LIGHT' } else { 'PROD' }
    if ($Zip -and -not $light) { throw 'Aucune archive PROD : seul le pack PROD-LIGHT est livré, par la CI de livraison (décision du 08/11/2026).' }
    $package = Join-Path $OutBase 'Domenia'
    $payload = Join-Path $package 'wad'
    if ($light -and (Test-Path -LiteralPath (Join-Path $payload 'runtime\webview2'))) { throw 'Moteur WebView2 présent dans le pack PROD-LIGHT ; aucun pack déclaré valide.' }
    if ($null -ne $seedBytes) {
        [IO.File]::WriteAllBytes((Join-Path $payload 'Domenia.settings.seed.json'), $seedBytes)
        & (Join-Path $package 'Domenia.exe') --check-settings-seed (Join-Path $payload 'Domenia.settings.seed.json')
        if ($LASTEXITCODE) { throw 'Configuration de distribution refusée par le codec de Domenia ; aucun ZIP déclaré valide.' }
    }
    $guides = Join-Path $payload 'guides'; New-Item -ItemType Directory -Force -Path $guides | Out-Null
    $guideNames = @('MISES-A-JOUR.md', 'DEMONSTRATION.md', 'REFERENTIELS.md', 'CONFIGURATION-DIFFUSABLE.md')
    if ($ManualUserAcceptance) { $guideNames += ('RECETTE-MANUELLE-V' + $Version + '.md') }
    foreach ($name in $guideNames) {
        if (-not @($source.files | Where-Object { $_.path -ceq ('docs/' + $name) }).Count) { throw "Guide non qualifié par le commit : $name" }
        Copy-Item -LiteralPath (Join-Path $Root ('docs/' + $name)) -Destination (Join-Path $guides $name)
    }
    $licenses = Join-Path $payload 'licenses'; New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    $licenseRoot = 'C:\DomeniaDev\dotnet'
    $coreLibrary = Join-Path $payload 'System.Private.CoreLib.dll'
    if ($light) {
        if ($PrivateDotNetVersion -cnotmatch '^10\.0\.(0|[1-9][0-9]*)$') { throw 'Version du runtime privé invalide.' }
        $licenseRoot = Join-Path $payload 'runtime\dotnet'
        $coreLibrary = Join-Path $licenseRoot ('shared\Microsoft.NETCore.App\' + $PrivateDotNetVersion + '\System.Private.CoreLib.dll')
    }
    Assert-OrdinaryReleasePath $coreLibrary
    foreach ($name in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
        $license = Join-Path $licenseRoot $name
        Assert-OrdinaryReleasePath $license
        Copy-Item -LiteralPath $license -Destination (Join-Path $licenses ('dotnet-' + $name))
    }
    $exeHash = (Get-FileHash -LiteralPath (Join-Path $package 'Domenia.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $netVersion = (Get-Item -LiteralPath $coreLibrary).VersionInfo.ProductVersion
    if ($light) { $WebViewVersion = 'Evergreen' }
    if (-not $netVersion -or -not $WebViewVersion -or $netVersion.Length -gt 100 -or $WebViewVersion.Length -gt 100) { throw 'Versions des runtimes embarqués absentes ou invalides.' }
    if ($light) { $netVersion = $PrivateDotNetVersion }
    $metadata = [ordered]@{ version = $Version; build = $BuildIdentity; dataSchemaVersion = 11; dataSchemaRevision = 2; project = 'Domenia'; architecture = 'win-x64'; packageType = $kind; sourceCommit = $source.sourceCommit; executableSha256 = $exeHash; dependencies = [ordered]@{ '.NET' = $netVersion; WebView2 = $WebViewVersion } }
    [IO.File]::WriteAllText((Join-Path $payload 'package-release.json'), ($metadata | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    Write-ReleaseContract $Root $package $OutBase $source $metadata $BuildEnvironment $false
    Write-ReleaseManifest $package -Light:$light
    $check = Start-Process -FilePath (Join-Path $package 'Domenia.exe') -ArgumentList '--check-only' -Wait -PassThru -NoNewWindow
    if ($check.ExitCode -ne 0) { throw "Contrôle du paquet $kind refusé : $($check.ExitCode)" }
    [void](Read-ReleaseSource $Root)
    $validationStatus = if ($ManualUserAcceptance) { 'manual-user-pending' } else { 'candidate-unvalidated' }
    $delivery = [ordered]@{ version = $Version; build = $BuildIdentity; sourceCommit = $source.sourceCommit; executableSha256 = $exeHash; publisherTrust = 'not-established'; validationStatus = $validationStatus }
    $delivery[$(if ($light) { 'prodLight' } else { 'prod' })] = $package
    if ($ManualUserAcceptance) {
        $delivery['authorization'] = 'David, 2026-10-25 : livraison sans tests des deux VM, recette manuelle utilisateur.'
        $delivery['domainAcceptance'] = 'not-run'; $delivery['uiAcceptance'] = 'not-run'; $delivery['twoVmAcceptance'] = 'not-run'
    }
    if ($Zip) {
        # Unique delivery folder preserves earlier archives and their proofs, including a partial failed attempt.
        $directory = Join-Path $OutBase ('delivery-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $directory | Out-Null
        $name = 'Domenia_' + $Version + '_PROD-LIGHT_Windows-x64.zip'
        $zipPath = Join-Path $directory $name
        Write-FlatReleaseZip $package $zipPath
        $line = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
        [IO.File]::WriteAllText((Join-Path $directory 'SHA256SUMS.txt'), ($line + "`n"), (New-Object Text.UTF8Encoding $false))
        Copy-Item -LiteralPath (Join-Path $Root '.release-source.json') -Destination (Join-Path $directory 'source-commit.json')
        "Archive PROD-LIGHT : $zipPath ($((Get-Item -LiteralPath $zipPath).Length) octets)"
        $delivery['archives'] = $directory
    }
    $receipt = Join-Path $OutBase ('Domenia.delivery-' + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($receipt, ($delivery | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    if ($ManualUserAcceptance) {
        "Pack $kind avec intégrité contrôlée : $package ; reçu=$receipt. Livraison manuelle autorisée par David ; recette utilisateur en attente. Aucun succès des deux VM ou de la recette UI/native n'est déduit."
    } else {
        "Candidat $kind avec intégrité contrôlée : $package ; reçu=$receipt. Non validé pour publication : les preuves critiques des deux VM et la revue UI/native sont requises par release-guard.py."
    }
}
