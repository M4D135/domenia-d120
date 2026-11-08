# Each invocation owns new directories. Never delete a path left by another run.
function Invoke-DomeniaTestProfile {
    param([ValidateSet('c', 'f')][string]$Stage, [scriptblock]$Body)
    $ErrorActionPreference = 'Stop'
    if ($env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[1-9][0-9]*$') {
        throw 'Identite du passage GitHub absente ou invalide.'
    }
    $name = $Stage + ([long]$env:GITHUB_RUN_ID).ToString('x') + '-' + ([int]$env:GITHUB_RUN_ATTEMPT).ToString('x')
    $userRoot = Join-Path (Join-Path $env:USERPROFILE 'dp') $name
    $tempRoot = Join-Path (Join-Path $env:SystemDrive 'dp') $name
    $owned = @()
    $old = @($env:LOCALAPPDATA, $env:APPDATA, $env:TEMP, $env:TMP)
    try {
        foreach ($root in @($userRoot, $tempRoot)) {
            $parent = Split-Path -Parent $root
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            for ($ancestor = [IO.DirectoryInfo]$parent; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
                if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Profil redirige : $ancestor" }
            }
            # New-Item without Force refuses an existing directory, even if a foreign run owns it.
            New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
            $owned += $root
        }
        $env:LOCALAPPDATA = Join-Path $userRoot 'la'
        $env:APPDATA = Join-Path $userRoot 'ro'
        $env:TEMP = Join-Path $tempRoot 'tmp'
        $env:TMP = $env:TEMP
        foreach ($path in @($env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
            New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
        }
        & $Body
    } finally {
        $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP, $env:TMP = $old
        foreach ($root in $owned) {
            try { Remove-DomeniaOwnedProfile ([IO.DirectoryInfo]$root) }
            catch { Write-Warning "Profil de ce passage conserve pour inspection : $root ($($_.Exception.GetType().Name))." }
        }
    }
}

function Remove-DomeniaOwnedProfile([IO.FileSystemInfo]$Item) {
    $Item.Refresh()
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Chemin redirige conserve : $Item" }
    if ($Item -is [IO.DirectoryInfo]) {
        foreach ($child in $Item.GetFileSystemInfos()) { Remove-DomeniaOwnedProfile $child }
    }
    $Item.Delete()
}
