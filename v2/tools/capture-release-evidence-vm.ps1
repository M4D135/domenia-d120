# Capture existing final-validation evidence only. Does not build, execute tests, publish, or change the machine.
param(
    [Parameter(Mandatory = $true)][ValidateSet('CNAMTS-DC01', 'DOMENIA-FIRSTRUN-20261020')][string]$VmName,
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$Pack,
    [Parameter(Mandatory = $true)][string]$TestDirectory,
    [Parameter(Mandatory = $true)][string]$DebugBuildLog,
    [Parameter(Mandatory = $true)][string]$ReleaseBuildLog,
    [Parameter(Mandatory = $true)][string]$CSharpLog,
    [Parameter(Mandatory = $true)][string]$WebReport,
    [Parameter(Mandatory = $true)][string[]]$UiReport,
    [Parameter(Mandatory = $true)][string]$NativeEvidence,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [switch]$FinalValidation
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $FinalValidation) { throw 'Capture reservee aux preuves finales existantes ; -FinalValidation requis.' }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or (Get-Process -Id $PID).SessionId -le 0) { throw 'Bureau Windows interactif requis, sans fermeture de session.' }
. (Join-Path $PSScriptRoot 'release-packages-vm.ps1')
$expected = @{
    'CNAMTS-DC01' = '7625c944-b4fc-4f8b-ac23-c796cc1be791'
    'DOMENIA-FIRSTRUN-20261020' = 'bc2f1ac0-9545-49bd-a0f5-cb89d352cf61'
}
# Local, read-only WMI; no remote endpoint, credential, service or policy is configured.
$system = @(Get-WmiObject -Class Win32_ComputerSystemProduct)
if ($system.Count -ne 1 -or ([string]$system[0].UUID).ToLowerInvariant() -cne $expected[$VmName]) { throw 'UUID systeme different de la VM autorisee. Conserver les preuves et requalifier la correspondance, sans changer la garde.' }
foreach ($path in @($SourceRoot, $Pack, $TestDirectory, $EvidenceRoot)) {
    if (-not [IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\') -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Dossiers locaux absolus existants requis.' }
    Assert-OrdinaryReleasePath $path
}
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$Pack = [IO.Path]::GetFullPath($Pack).TrimEnd('\')
$TestDirectory = [IO.Path]::GetFullPath($TestDirectory).TrimEnd('\')
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\')
$source = Read-ReleaseSource $SourceRoot
$prefix = $VmName + '-' + [guid]::NewGuid().ToString('N')
$folder = Join-Path $EvidenceRoot $prefix
New-Item -ItemType Directory -Path $folder | Out-Null

function Assert-EvidenceName([string]$Name) {
    if ($Name.Length -lt 1 -or $Name.Length -gt 512 -or $Name -match '[\x00-\x1f\\:<>"|?*]' -or $Name.StartsWith('/')) { throw 'Chemin de preuve invalide.' }
    foreach ($part in $Name.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'Chemin de preuve ambigu ou reserve.' }
    }
}

function Get-EvidenceIdentity([string]$Path, [string]$Name, [long]$Maximum) {
    Assert-OrdinaryReleasePath $Path
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or $file.Length -gt $Maximum) { throw "Preuve absente ou hors borne : $Name" }
    return [ordered]@{ path = $Name; length = $file.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Copy-Evidence([string]$Path, [string]$Relative, [long]$Maximum = 67108864) {
    Assert-EvidenceName $Relative
    $before = Get-EvidenceIdentity $Path ($prefix + '/' + $Relative) $Maximum
    $destination = Join-Path $folder $Relative.Replace('/', '\')
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
    if (Test-Path -LiteralPath $destination) { throw 'Une preuve existe deja ; aucun remplacement.' }
    $inputStream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($inputStream.Length -ne $before.length) { throw 'Preuve modifiee pendant sa capture.' }
        $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
    $after = Get-EvidenceIdentity $destination $before.path $Maximum
    if ($after.length -ne $before.length -or $after.sha256 -cne $before.sha256) { throw 'Copie de preuve differente ; aucun succes deduit.' }
    return $after
}

# Current packs keep Domenia.exe and wad\ at the root, manifest and release in wad\ ; older flat packs keep them at the root.
# Format 2 is the delivered PROD-LIGHT pack, format 1 the PROD pack (internal lab build or earlier evidence).
$data = if (Test-Path -LiteralPath (Join-Path $Pack 'wad\package-manifest.json') -PathType Leaf) { 'wad/' } else { '' }
$packManifest = Join-Path $Pack ($data.Replace('/', '\') + 'package-manifest.json')
$packIdentity = Get-EvidenceIdentity $packManifest ($data + 'package-manifest.json') 2097152
$manifest = Get-Content -LiteralPath $packManifest -Raw -Encoding UTF8 | ConvertFrom-Json
$light = $manifest.format -eq 2
$kind = if ($light) { 'PROD-LIGHT' } else { 'PROD' }
if (($manifest.format -ne 1 -and -not ($light -and $data -and $manifest.packageType -ceq 'PROD-LIGHT')) -or @($manifest.files).Count -lt 10 -or @($manifest.files).Count -gt 4096) { throw 'Manifeste du paquet incomplet.' }
$names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.files) {
    Assert-EvidenceName ([string]$entry.path)
    if (-not $names.Add([string]$entry.path)) { throw 'Composant de paquet duplique.' }
    $actual = Get-EvidenceIdentity (Join-Path $Pack $entry.path.Replace('/', '\')) $entry.path 2147483648
    if ($actual.length -ne $entry.length -or $actual.sha256 -cne $entry.sha256) { throw "Paquet modifie : $($entry.path)" }
}
# A Socle WebView2 engine extracted beside a PROD-LIGHT pack is never in its manifest: only the exact index pinned in the sources admits it.
$socle = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($light -and (Test-Path -LiteralPath (Join-Path $Pack 'wad\runtime\webview2'))) {
    $socleIndex = Join-Path $SourceRoot 'src\Domenia.App\Socle\webview2-156.0.4314.42.files.json'
    if ((Get-EvidenceIdentity $socleIndex 'socle-index.json' 1048576).sha256 -cne 'a846d3785426fabe872f7e53188e3ba998d4a0ebde34f6af66ac4fe04acf77d3') { throw 'Index du pack WebView2 du Socle different de celui epingle.' }
    foreach ($entry in (Get-Content -LiteralPath $socleIndex -Raw -Encoding UTF8 | ConvertFrom-Json).files) {
        $name = 'wad/' + [string]$entry.path
        Assert-EvidenceName $name
        if ($names.Contains($name) -or -not $socle.Add($name)) { throw 'Composant du Socle duplique ou deja manifeste.' }
        $actual = Get-EvidenceIdentity (Join-Path $Pack $name.Replace('/', '\')) $name 2147483648
        if ($actual.length -ne $entry.bytes -or $actual.sha256 -cne ([string]$entry.sha256).ToLowerInvariant()) { throw "Pack WebView2 du Socle modifie : $name" }
    }
}
$observed = @(Get-ChildItem -LiteralPath $Pack -Recurse -File -Force)
foreach ($file in $observed) {
    $name = $file.FullName.Substring($Pack.Length + 1).Replace('\', '/')
    Assert-OrdinaryReleasePath $file.FullName
    if ($name -notin @(($data + 'package-manifest.json'), ($data + '.lifecycle.lock')) -and -not $names.Contains($name) -and -not $socle.Contains($name)) { throw "Composant non manifeste : $name" }
}
$release = Get-Content -LiteralPath (Join-Path $Pack ($data.Replace('/', '\') + 'package-release.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
$exe = Get-EvidenceIdentity (Join-Path $Pack 'Domenia.exe') 'Domenia.exe' 2147483648
if ($release.packageType -cne $kind -or $release.sourceCommit -cne $source.sourceCommit -or $release.executableSha256 -cne $exe.sha256) { throw "Paquet $kind different du commit ou du lanceur attendu." }
$testFiles = @(Get-ChildItem -LiteralPath $TestDirectory -Recurse -File | ForEach-Object {
    $name = $_.FullName.Substring($TestDirectory.Length + 1).Replace('\', '/')
    Assert-EvidenceName $name
    Get-EvidenceIdentity $_.FullName $name 536870912
} | Sort-Object path)
if (@($testFiles | Where-Object { $_.path -ceq 'Domenia.Tests.dll' }).Count -ne 1) { throw 'Assemblage de tests absent.' }

$ui = @()
$uiScreenshots = @()
$index = 0
foreach ($path in $UiReport) {
    $index++
    $relative = 'ui/' + $index + '/report.json'
    $reference = Copy-Evidence $path $relative 16777216
    $document = Get-Content -LiteralPath (Join-Path $folder $relative.Replace('/', '\')) -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($scenario in $document.scenarios) {
        foreach ($step in $scenario.steps) {
            if ($step.screenshot) {
                Assert-EvidenceName ([string]$step.screenshot)
                $screenshot = Join-Path ([IO.Path]::GetDirectoryName($path)) $step.screenshot.Replace('/', '\')
                $uiScreenshots += Copy-Evidence $screenshot ('ui/' + $index + '/' + $step.screenshot) 33554432
            }
        }
    }
    $ui += $reference
}
$snapshot = [ordered]@{
    format = 'Domenia.ReleaseSnapshot/1'; capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
    vmName = $VmName; vmUuid = $expected[$VmName]; systemUuid = ([string]$system[0].UUID).ToLowerInvariant()
    machine = [Environment]::MachineName; os = [Environment]::OSVersion.Platform.ToString(); sessionId = (Get-Process -Id $PID).SessionId
    sourceCommit = $source.sourceCommit; packageType = $kind; packageManifestSha256 = $packIdentity.sha256; executableSha256 = $exe.sha256
    socleFiles = $socle.Count
    executablePath = Join-Path $Pack 'Domenia.exe'; testFiles = $testFiles
    sourceManifest = Copy-Evidence (Join-Path $SourceRoot '.release-source.json') 'raw/source-manifest.json' 2097152
    debugBuild = Copy-Evidence $DebugBuildLog 'raw/build-Debug.log' 33554432
    releaseBuild = Copy-Evidence $ReleaseBuildLog 'raw/build-Release.log' 33554432
    csharp = Copy-Evidence $CSharpLog 'raw/critical-csharp.log' 33554432
    web = Copy-Evidence $WebReport 'web/report.json' 16777216
    webScreenshot = Copy-Evidence (Join-Path ([IO.Path]::GetDirectoryName($WebReport)) 'page.png') 'web/page.png' 33554432
    ui = $ui
    uiScreenshots = $uiScreenshots
    native = Copy-Evidence $NativeEvidence 'raw/native-evidence.jsonl' 67108864
}
# No status is promoted here; invalid/failed raw results are still preserved and the release gate refuses them later.
[void](Read-ReleaseSource $SourceRoot)
if ((Get-FileHash -LiteralPath $packManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $packIdentity.sha256) { throw 'Manifeste du paquet modifie pendant la capture.' }
$target = Join-Path $folder 'snapshot.json'
$stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 8))
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
} finally { $stream.Dispose() }
Get-EvidenceIdentity $target ($prefix + '/snapshot.json') 4194304 | ConvertTo-Json -Depth 4
Write-Output 'Preuves capturees, aucun verdict metier ajoute. Revue UI/native et garde de publication encore requises.'
