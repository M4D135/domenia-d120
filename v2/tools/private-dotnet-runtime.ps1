# Copy only an already-installed Windows x64 runtime into a new, application-private directory.
# Dot-source this file: no command runs on import, no package/runtime is downloaded or installed.
# The publisher must use AppHostDotNetSearch=AppRelative, AppHostRelativeDotNet=runtime/dotnet,
# RuntimeFrameworkVersion=<snapshot.version>, RollForward=Disable and SelfContained=false.

function Assert-PrivateDotNetOrdinaryPath([string]$Path, [bool]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Chemin du runtime .NET absent.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -cnotmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':') -or $full -match '[\x00-\x1f]') { throw 'Runtime .NET : chemin local de lecteur requis.' }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'Runtime .NET : lecteur réseau refusé.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne $Directory) { throw "Type de chemin .NET inattendu : $full" }
    $current = $item
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Runtime .NET redirigé : $full" }
        $parent = [IO.Path]::GetDirectoryName($current.FullName)
        if ([string]::IsNullOrEmpty($parent)) { break }
        $current = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (-not $current.PSIsContainer) { throw "Ancêtre .NET non ordinaire : $full" }
    }
    return $item
}

function Assert-PrivateDotNetRelativeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 512 -or $Name -match '[\x00-\x1f\\:<>"|?*]') {
        throw 'Chemin relatif du runtime .NET hors contrat.'
    }
    foreach ($part in $Name.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -match '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { throw "Chemin .NET ambigu : $Name" }
    }
}

function Get-PrivateDotNetFileIdentity([string]$Root, [string]$Relative) {
    Assert-PrivateDotNetRelativeName $Relative
    $path = Join-Path $Root $Relative.Replace('/', '\')
    [void](Assert-PrivateDotNetOrdinaryPath $path $false)
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $length = $stream.Length
        if ($length -lt 0 -or $length -gt 536870912) { throw "Fichier .NET supérieur à 512 Mio : $Relative" }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        if ($stream.Position -ne $length -or $stream.Length -ne $length) { throw "Fichier .NET modifié pendant sa lecture : $Relative" }
        [void](Assert-PrivateDotNetOrdinaryPath $path $false)
    } finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{ path = $Relative; length = $length; sha256 = $hash }
}

function Assert-PrivateDotNetAmd64([string]$Path) {
    [void](Assert-PrivateDotNetOrdinaryPath $Path $false)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        try {
            if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw "Exécutable .NET non PE : $Path" }
            $stream.Position = 0x3c; $offset = $reader.ReadInt32()
            if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "En-tête PE .NET invalide : $Path" }
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Composant .NET non x64 : $Path" }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-PrivateDotNetTree([string]$Root, [string]$Relative = '') {
    $start = $Root
    if ($Relative) { Assert-PrivateDotNetRelativeName $Relative; $start = Join-Path $Root $Relative.Replace('/', '\') }
    [void](Assert-PrivateDotNetOrdinaryPath $start $true)
    $prefix = $Root.TrimEnd('\') + '\'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $files = New-Object 'System.Collections.Generic.List[string]'
    if ($Relative) { $directories.Add($Relative) }
    $pending.Push($start)
    while ($pending.Count) {
        $folder = $pending.Pop()
        [void](Assert-PrivateDotNetOrdinaryPath $folder $true)
        foreach ($entry in Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop) {
            # Check before descending: Get-ChildItem -Recurse would discover a redirected tree too late.
            [void](Assert-PrivateDotNetOrdinaryPath $entry.FullName ([bool]$entry.PSIsContainer))
            if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fichier .NET hors racine.' }
            $name = $entry.FullName.Substring($prefix.Length).Replace('\', '/')
            Assert-PrivateDotNetRelativeName $name
            if ($entry.PSIsContainer) { $directories.Add($name); $pending.Push($entry.FullName) }
            else { $files.Add($name) }
            if ($files.Count -gt 2048 -or $directories.Count -gt 2048) { throw 'Arbre .NET privé supérieur au plafond de fichiers ou dossiers.' }
        }
    }
    return [pscustomobject]@{ files = $files.ToArray(); directories = $directories.ToArray() }
}

function New-PrivateDotNetInventory([string]$Root, [string]$Version, [string[]]$Files, [string[]]$Directories) {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $directoryNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [string[]]$orderedFiles = @($Files); [Array]::Sort($orderedFiles, [StringComparer]::Ordinal)
    [string[]]$orderedDirectories = @($Directories); [Array]::Sort($orderedDirectories, [StringComparer]::Ordinal)
    if ($orderedFiles.Count -lt 10 -or $orderedFiles.Count -gt 2048 -or $orderedDirectories.Count -gt 2048) { throw 'Inventaire .NET privé hors bornes.' }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $canonical = New-Object Text.StringBuilder
    [void]$canonical.Append('Domenia.PrivateDotNetRuntime/1').Append("`n").Append($Version).Append("`n")
    foreach ($relative in $orderedDirectories) {
        Assert-PrivateDotNetRelativeName $relative
        if (-not $directoryNames.Add($relative)) { throw "Dossier .NET répété : $relative" }
        [void](Assert-PrivateDotNetOrdinaryPath (Join-Path $Root $relative.Replace('/', '\')) $true)
        [void]$canonical.Append('D').Append([char]0).Append($relative).Append("`n")
    }
    $total = 0L
    foreach ($relative in $orderedFiles) {
        if (-not $names.Add($relative) -or $directoryNames.Contains($relative)) { throw "Entrée .NET répétée ou ambiguë : $relative" }
        $entry = Get-PrivateDotNetFileIdentity $Root $relative
        $total += $entry.length
        if ($total -gt 2147483648) { throw 'Runtime .NET privé supérieur à 2 Gio.' }
        $entries.Add($entry)
        [void]$canonical.Append('F').Append([char]0).Append($relative).Append([char]0)
        [void]$canonical.Append($entry.length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append([char]0).Append($entry.sha256).Append("`n")
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $inventoryHash = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical.ToString())))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    return [pscustomobject][ordered]@{
        format = 'Domenia.PrivateDotNetRuntime/1'; sourceRoot = $Root; version = $Version; relativeRoot = 'runtime/dotnet'
        coreLibraryRelativePath = 'shared/Microsoft.NETCore.App/' + $Version + '/System.Private.CoreLib.dll'
        directories = $orderedDirectories; files = $entries.ToArray(); fileCount = $entries.Count; length = $total; inventorySha256 = $inventoryHash
    }
}

function Get-PrivateDotNetRuntime([string]$DotNetRoot, [string]$Version = '') {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) { throw 'Lecture du runtime privé réservée à Windows x64.' }
    if ($Version -and $Version -cnotmatch '^10\.0\.(0|[1-9][0-9]{0,8})$') { throw 'Version .NET privée : 10.0.x stable requise.' }
    $root = (Assert-PrivateDotNetOrdinaryPath $DotNetRoot $true).FullName
    if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }
    $bases = @('host/fxr', 'shared/Microsoft.NETCore.App', 'shared/Microsoft.WindowsDesktop.App')
    $common = $null
    foreach ($relative in $bases) {
        $base = Join-Path $root $relative.Replace('/', '\')
        [void](Assert-PrivateDotNetOrdinaryPath $base $true)
        $versions = @(foreach ($directory in Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop) {
            if ($directory.Name -cmatch '^10\.0\.(0|[1-9][0-9]{0,8})$') {
                [void](Assert-PrivateDotNetOrdinaryPath $directory.FullName $true)
                $directory.Name
            }
        })
        if ($null -eq $common) { $common = $versions }
        else { $common = @($common | Where-Object { $versions -ccontains $_ }) }
    }
    if (-not $common.Count) { throw 'Aucune version 10.0.x stable commune à NETCore, WindowsDesktop et hostfxr déjà installée.' }
    if ($Version) {
        if ($common -cnotcontains $Version) { throw "Version .NET privée demandée absente d’au moins un composant : $Version" }
    } else { $Version = @($common | Sort-Object { [version]$_ } -Descending)[0] }
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('dotnet.exe', 'LICENSE.txt', 'ThirdPartyNotices.txt')) { $files.Add($name) }
    $directories = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('host', 'host/fxr', 'shared', 'shared/Microsoft.NETCore.App', 'shared/Microsoft.WindowsDesktop.App')) { $directories.Add($name) }
    foreach ($relative in $bases) {
        $tree = Get-PrivateDotNetTree $root ($relative + '/' + $Version)
        foreach ($name in $tree.files) { $files.Add($name) }
        foreach ($name in $tree.directories) { $directories.Add($name) }
    }
    $snapshot = New-PrivateDotNetInventory -Root $root -Version $Version -Files ($files.ToArray()) -Directories ($directories.ToArray())
    $required = @('dotnet.exe', 'LICENSE.txt', 'ThirdPartyNotices.txt', ('host/fxr/' + $Version + '/hostfxr.dll'),
        ('shared/Microsoft.NETCore.App/' + $Version + '/coreclr.dll'), ('shared/Microsoft.NETCore.App/' + $Version + '/hostpolicy.dll'),
        ('shared/Microsoft.NETCore.App/' + $Version + '/System.Private.CoreLib.dll'), ('shared/Microsoft.NETCore.App/' + $Version + '/Microsoft.NETCore.App.deps.json'),
        ('shared/Microsoft.WindowsDesktop.App/' + $Version + '/System.Windows.Forms.dll'),
        ('shared/Microsoft.WindowsDesktop.App/' + $Version + '/Microsoft.WindowsDesktop.App.deps.json'),
        ('shared/Microsoft.WindowsDesktop.App/' + $Version + '/Microsoft.WindowsDesktop.App.runtimeconfig.json'))
    foreach ($name in $required) {
        if (@($snapshot.files | Where-Object { $_.path -ceq $name -and $_.length -gt 0 }).Count -ne 1) { throw "Composant .NET privé absent ou vide : $name" }
    }
    foreach ($name in @('dotnet.exe', ('host/fxr/' + $Version + '/hostfxr.dll'),
        ('shared/Microsoft.NETCore.App/' + $Version + '/coreclr.dll'), ('shared/Microsoft.NETCore.App/' + $Version + '/hostpolicy.dll'))) {
        Assert-PrivateDotNetAmd64 (Join-Path $root $name.Replace('/', '\'))
    }
    return $snapshot
}

function Confirm-PrivateDotNetCopy([string]$Root, $Runtime) {
    # Enumerate the entire destination, not only the three selected source trees: no extra file or version may be hidden.
    $tree = Get-PrivateDotNetTree $Root
    $actual = New-PrivateDotNetInventory $Root $Runtime.version $tree.files $tree.directories
    if ($actual.inventorySha256 -cne $Runtime.inventorySha256 -or $actual.fileCount -ne $Runtime.fileCount -or $actual.length -ne $Runtime.length) {
        throw "Copie .NET privée différente de l'inventaire confirmé."
    }
    return $actual
}

function Copy-PrivateDotNetRuntime($Runtime, [string]$PackageRoot) {
    if ($null -eq $Runtime -or $Runtime.format -cne 'Domenia.PrivateDotNetRuntime/1' -or $Runtime.relativeRoot -cne 'runtime/dotnet' -or
        $Runtime.inventorySha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Instantané du runtime .NET privé invalide.' }
    # Use a newly qualified inventory rather than trusting file paths carried by the caller's object.
    $current = Get-PrivateDotNetRuntime -DotNetRoot $Runtime.sourceRoot -Version $Runtime.version
    if ($current.inventorySha256 -cne $Runtime.inventorySha256) { throw 'Runtime .NET installé modifié depuis sa sélection.' }
    $package = (Assert-PrivateDotNetOrdinaryPath $PackageRoot $true).FullName
    if ((Test-Path -LiteralPath (Join-Path $package 'package-manifest.json')) -or (Test-Path -LiteralPath (Join-Path $package 'package-release.json'))) {
        throw 'Paquet déjà constitué : aucune insertion de runtime dans une livraison existante.'
    }
    $runtimeParent = Join-Path $package 'runtime'
    if (Test-Path -LiteralPath $runtimeParent) { [void](Assert-PrivateDotNetOrdinaryPath $runtimeParent $true) }
    else { [void][IO.Directory]::CreateDirectory($runtimeParent); [void](Assert-PrivateDotNetOrdinaryPath $runtimeParent $true) }
    $destination = Join-Path $runtimeParent 'dotnet'
    if (Test-Path -LiteralPath $destination) { throw "Destination .NET privée existante conservée : $destination" }
    $parent = [IO.Path]::GetDirectoryName($package)
    [void](Assert-PrivateDotNetOrdinaryPath $parent $true)
    $stage = Join-Path $parent ('.domenia-dotnet-' + [Guid]::NewGuid().ToString('N') + '.partial')
    if (Test-Path -LiteralPath $stage) { throw 'Préparation .NET privée déjà présente ; aucun écrasement.' }
    [void][IO.Directory]::CreateDirectory($stage)
    [void](Assert-PrivateDotNetOrdinaryPath $stage $true)
    foreach ($relative in $current.directories) {
        $folder = Join-Path $stage $relative.Replace('/', '\')
        [void][IO.Directory]::CreateDirectory($folder)
        [void](Assert-PrivateDotNetOrdinaryPath $folder $true)
    }
    foreach ($entry in $current.files) {
        $source = Join-Path $current.sourceRoot $entry.path.Replace('/', '\')
        $target = Join-Path $stage $entry.path.Replace('/', '\')
        [void](Assert-PrivateDotNetOrdinaryPath $source $false)
        [void](Assert-PrivateDotNetOrdinaryPath ([IO.Path]::GetDirectoryName($target)) $true)
        $sourceStream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($sourceStream.Length -ne $entry.length) { throw "Taille du runtime .NET source modifiée : $($entry.path)" }
            $targetStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $sourceStream.CopyTo($targetStream); $targetStream.Flush($true) }
            finally { $targetStream.Dispose() }
            if ($sourceStream.Length -ne $entry.length -or $sourceStream.Position -ne $entry.length) { throw "Copie .NET interrompue : $($entry.path)" }
        } finally { $sourceStream.Dispose() }
        $copied = Get-PrivateDotNetFileIdentity $stage $entry.path
        if ($copied.length -ne $entry.length -or $copied.sha256 -cne $entry.sha256) { throw "Copie .NET altérée : $($entry.path)" }
    }
    [void](Confirm-PrivateDotNetCopy $stage $current)
    $after = Get-PrivateDotNetRuntime -DotNetRoot $current.sourceRoot -Version $current.version
    if ($after.inventorySha256 -cne $current.inventorySha256) { throw 'Runtime .NET installé modifié pendant sa copie.' }
    [void](Assert-PrivateDotNetOrdinaryPath $runtimeParent $true)
    # Directory.Move refuses an existing destination. A failed preparation remains beside the pack for diagnosis.
    [IO.Directory]::Move($stage, $destination)
    [void](Confirm-PrivateDotNetCopy $destination $current)
    return [pscustomobject][ordered]@{
        format = 'Domenia.PrivateDotNetCopy/1'; sourceRoot = $current.sourceRoot; root = $destination; version = $current.version
        relativeRoot = 'runtime/dotnet'; coreLibraryPath = Join-Path $destination $current.coreLibraryRelativePath.Replace('/', '\')
        fileCount = $current.fileCount; length = $current.length; inventorySha256 = $current.inventorySha256
        provenance = 'installed-dotnet-private-copy'; downloaded = $false; installed = $false
    }
}
