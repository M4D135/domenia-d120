# Admit and inventory the complete WebView2 Runtime already installed on the Windows runner (Evergreen).
# No installer, updater, registry change, ACL change or dependency download is performed.
# Since 2026-11-08 nothing is copied: the delivered PROD-LIGHT pack has no browser and its checks use this engine.
# Loader contract: learn.microsoft.com/dotnet/api/microsoft.web.webview2.core.corewebview2environment.createasync
# A real WebView launch must still prove that its browser process comes from the admitted directory.

function Assert-OrdinaryPrivateWebViewPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'WebView2 privé : chemin local absolu requis.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':') -or $full -match '[\x00-\x1F]') { throw 'WebView2 privé : chemin local absolu requis.' }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'WebView2 privé : lecteur réseau refusé.' }
    $current = $full
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "WebView2 privé : chemin redirigé refusé : $Path" }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    if ($full.Length -gt 3) { return $full.TrimEnd('\') }
    return $full
}

function Test-PrivateWebViewRelativeName([string]$Name) {
    if (-not $Name -or $Name.Length -gt 512 -or $Name -match '[\x00-\x1F\\:<>"|?*]' -or $Name.StartsWith('/') -or $Name.EndsWith('/')) { return $false }
    foreach ($part in $Name.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { return $false }
    }
    return $true
}

function Get-PrivateWebViewHash($Stream) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Assert-PrivateWebViewX64([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'WebView2 privé : image PE absente.' }
            $stream.Position = 0x3c
            $offset = $reader.ReadUInt32()
            if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw 'WebView2 privé : en-tête PE invalide.' }
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'WebView2 privé : runtime Windows x64 requis.' }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Test-PrivateWebViewVersion([string]$Version) {
    return $Version -cmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$' -and [version]$Version -ge [version]'155.0.4283.62'
}

function Assert-PrivateWebViewMicrosoftSignature([string]$Path, [string]$ExpectedHash) {
    # Hold the same bytes against replacement/writes while checking Windows trust and the inventory hash.
    $held = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-PrivateWebViewX64 $Path
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductVersion
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne 'Microsoft Corporation') {
            throw 'WebView2 privé : signature Microsoft Windows valide requise.'
        }
        if ((Get-PrivateWebViewHash $held) -cne $ExpectedHash) { throw 'WebView2 privé : composant modifié pendant la vérification de signature.' }
        return $version
    } finally { $held.Dispose() }
}

function Read-PrivateWebViewInventory([string]$Root) {
    $base = Assert-OrdinaryPrivateWebViewPath $Root
    if (-not [IO.Directory]::Exists($base)) { throw 'WebView2 privé : dossier absent.' }
    $files = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($base)
    $total = 0L
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        [void](Assert-OrdinaryPrivateWebViewPath $directory)
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            # Inspect each directory before descending; never enumerate through a reparse point.
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "WebView2 privé : composant redirigé : $($item.FullName)" }
            $name = $item.FullName.Substring($base.Length + 1).Replace('\', '/')
            if (-not (Test-PrivateWebViewRelativeName $name)) { throw "WebView2 privé : nom de composant refusé : $name" }
            if ($item.PSIsContainer) {
                if (-not $directories.Add($name) -or $directories.Count -gt 1024 -or $files.ContainsKey($name)) { throw 'WebView2 privé : inventaire de dossiers hors bornes ou répété.' }
                $pending.Enqueue($item.FullName)
                continue
            }
            if ($files.ContainsKey($name) -or $directories.Contains($name) -or $files.Count -ge 2048) { throw 'WebView2 privé : inventaire de fichiers hors bornes ou répété.' }
            $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $length = $stream.Length
                if ($length -lt 0 -or $length -gt 2147483648) { throw 'WebView2 privé : fichier supérieur à 2 Gio.' }
                $total += $length
                if ($total -gt 4294967296) { throw 'WebView2 privé : inventaire supérieur à 4 Gio.' }
                $files.Add($name, [pscustomobject][ordered]@{ path = $name; length = $length; sha256 = (Get-PrivateWebViewHash $stream) })
            } finally { $stream.Dispose() }
        }
    }
    $versions = @{}
    foreach ($required in @('msedgewebview2.exe', 'msedge.dll')) {
        if (-not $files.ContainsKey($required)) { throw "WebView2 privé : composant requis absent : $required" }
        $versions[$required] = Assert-PrivateWebViewMicrosoftSignature (Join-Path $base $required) $files[$required].sha256
    }
    $version = $versions['msedgewebview2.exe']
    if (-not (Test-PrivateWebViewVersion $version)) { throw 'WebView2 privé : version préinstallée inférieure au minimum qualifié ou invalide.' }
    if ($versions['msedge.dll'] -cne $version) { throw 'WebView2 privé : versions EXE et DLL différentes.' }
    [string[]]$names = @($files.Keys)
    [string[]]$directoryNames = @($directories)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    [Array]::Sort($directoryNames, [StringComparer]::Ordinal)
    $entries = @($names | ForEach-Object { $files[$_] })
    # Canonical UTF-8/LF digest, independent of PowerShell JSON formatting and destination path.
    $canonical = [Text.StringBuilder]::new("domenia-private-webview2-v1`ninstalled-webview2-private-copy`n$version`n")
    foreach ($name in $directoryNames) { [void]$canonical.Append("D`t$name`n") }
    foreach ($entry in $entries) { [void]$canonical.Append("F`t$($entry.path)`t$($entry.length.ToString([Globalization.CultureInfo]::InvariantCulture))`t$($entry.sha256)`n") }
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical.ToString())
    $memory = [IO.MemoryStream]::new($bytes, $false)
    try { $inventoryHash = Get-PrivateWebViewHash $memory } finally { $memory.Dispose() }
    return [pscustomobject][ordered]@{
        sourceRoot = $base; version = $version; provenance = 'installed-webview2-private-copy'
        executableSha256 = $files['msedgewebview2.exe'].sha256; inventorySha256 = $inventoryHash
        length = $total; directories = $directoryNames; files = $entries
    }
}

function Get-PrivateWebViewRuntime {
    [CmdletBinding()]
    param([string]$SourceRoot)
    if ($env:OS -ne 'Windows_NT') { throw 'WebView2 privé : inventaire Windows réel requis.' }
    # Closed CI locations: never use Edge, a per-user install, a download, registry or PATH discovery.
    $roots = @('C:\Program Files (x86)\Microsoft\EdgeWebView\Application', 'C:\Program Files\Microsoft\EdgeWebView\Application')
    if (-not $SourceRoot) {
        $candidates = @(
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                [void](Assert-OrdinaryPrivateWebViewPath $root)
                $children = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)
                if ($children.Count -gt 64) { throw 'WebView2 privé : trop de versions préinstallées.' }
                foreach ($child in $children) {
                    if ($child.PSIsContainer -and (Test-PrivateWebViewVersion $child.Name)) {
                        [pscustomobject]@{ path = $child.FullName; version = [version]$child.Name }
                    }
                }
            }
        )
        if (-not $candidates.Count) { throw 'WebView2 privé : aucun runtime préinstallé admis ; aucune installation automatique.' }
        $SourceRoot = ($candidates | Sort-Object -Property @{Expression = 'version'; Descending = $true}, path | Select-Object -First 1).path
    }
    $source = Assert-OrdinaryPrivateWebViewPath $SourceRoot
    $parent = [IO.Path]::GetDirectoryName($source)
    $name = [IO.Path]::GetFileName($source)
    if ($parent -notin $roots -or -not (Test-PrivateWebViewVersion $name)) { throw 'WebView2 privé : seule une version préinstallée sous une racine fermée est admise.' }
    $inventory = Read-PrivateWebViewInventory $source
    if ($inventory.version -cne $name) { throw 'WebView2 privé : version du dossier différente des binaires.' }
    return $inventory
}
