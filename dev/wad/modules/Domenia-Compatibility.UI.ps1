# Compatibility of this workstation (point 145). Local reads only: registry of this machine, process facts and the file
# version of winsqlite3.dll. No network, no WMI, no administrator right. The verdict comes from the pure rules of
# Domenia-Compatibility.Model.ps1 and the matrix shipped with the modules; it is read once per session.
$script:CompatibilityModuleRoot = $PSScriptRoot
$script:DomeniaCompatibilityMatrix = $null
$script:DomeniaCompatibilityMatrixRead = $false
$script:DomeniaLocalCompatibility = $null
$script:DomeniaAboutCompatibilityHelp = $null

function Get-DomeniaCompatibilityMatrix {
    # Matrix delivered with the modules, never downloaded. Absent or unreadable: $null (the verdict is then Inconnu).
    if ($script:DomeniaCompatibilityMatrixRead) { return $script:DomeniaCompatibilityMatrix }
    $script:DomeniaCompatibilityMatrixRead = $true
    $script:DomeniaCompatibilityMatrix = $null
    try {
        $root = [string]$script:CompatibilityModuleRoot
        if (-not $root) { return $null }
        $path = Join-Path $root 'Domenia-Compatibility.json'
        $info = [IO.FileInfo]::new($path)
        if ((-not $info.Exists) -or ($info.Length -gt 1MB)) { Write-AppLog 'Matrice de compatibilité absente ou trop volumineuse : compatibilité inconnue.' 'WARN'; return $null }
        $script:DomeniaCompatibilityMatrix = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { try { Write-AppLog ('Matrice de compatibilité illisible : ' + $_.Exception.Message) 'WARN' } catch { Write-DomeniaSwallowed 'Compatibilité' 'Get-DomeniaCompatibilityMatrix' $_ } }
    return $script:DomeniaCompatibilityMatrix
}

function Read-DomeniaLocalRegistryValue {
    # One value of HKEY_LOCAL_MACHINE on this workstation (64-bit view of the process); $null when absent or refused.
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Name)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Path,$false)
        if ($null -eq $key) { return $null }
        return $key.GetValue($Name,$null)
    } catch { return $null }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Get-DomeniaEnvironmentFacts {
    # Facts of this workstation for the matrix. A value that cannot be read stays unknown.
    $windowsKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $sqlitePath = Join-Path ([Environment]::SystemDirectory) 'winsqlite3.dll'
    $sqlitePresent = $null
    $sqliteVersion = ''
    try {
        $sqlitePresent = [IO.File]::Exists($sqlitePath)
        if ($sqlitePresent) { $sqliteVersion = [string]([Diagnostics.FileVersionInfo]::GetVersionInfo($sqlitePath).ProductVersion) }
    } catch { $sqlitePresent = $null }
    $edition = 'Desktop'
    if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = [string]$PSVersionTable.PSEdition }
    $raw = @{
        InstallationType = [string](Read-DomeniaLocalRegistryValue -Path $windowsKey -Name 'InstallationType')
        CurrentBuild = [string](Read-DomeniaLocalRegistryValue -Path $windowsKey -Name 'CurrentBuild')
        DisplayVersion = [string](Read-DomeniaLocalRegistryValue -Path $windowsKey -Name 'DisplayVersion')
        ShellEdition = $edition
        ShellVersion = [string]$PSVersionTable.PSVersion
        Is64BitProcess = [Environment]::Is64BitProcess
        NetRelease = (Read-DomeniaLocalRegistryValue -Path 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name 'Release')
        SqlitePresent = $sqlitePresent
        SqliteVersion = $sqliteVersion
    }
    return ConvertTo-DomeniaEnvironmentFacts @raw
}

function Get-DomeniaLocalCompatibility {
    # Facts, verdict and sentence of this session. -Refresh reads the facts again (nothing else changes them).
    param([switch]$Refresh)
    if (($null -ne $script:DomeniaLocalCompatibility) -and (-not $Refresh)) { return $script:DomeniaLocalCompatibility }
    $facts = Get-DomeniaEnvironmentFacts
    $verdict = Get-DomeniaCompatibilityVerdict -Matrix (Get-DomeniaCompatibilityMatrix) -Facts $facts
    $script:DomeniaLocalCompatibility = [pscustomobject]@{ Facts = $facts; Verdict = $verdict; Text = (Get-DomeniaCompatibilityText $verdict) }
    return $script:DomeniaLocalCompatibility
}

function Update-DomeniaAboutCompatibility {
    # À propos: one sentence and, in the tooltip, the line of each observed dimension. Never blocks the panel. The
    # tooltip and the help text read by screen readers change together; without detail both keep the static help.
    $label = Get-DomeniaControl 'LblUxAboutCompatibility'
    if ($null -eq $label) { return }
    if ($null -eq $script:DomeniaAboutCompatibilityHelp) { $script:DomeniaAboutCompatibilityHelp = [string]$label.ToolTip }
    $tip = [string]$script:DomeniaAboutCompatibilityHelp
    try {
        $state = Get-DomeniaLocalCompatibility
        $label.Text = [string]$state.Text
        $lines = @(@($state.Verdict.Rows) | ForEach-Object { [string]$_.Message })
        if ($state.Verdict.ReviewedOn) { $lines += ('Matrice relue le ' + [string]$state.Verdict.ReviewedOn + '. Qualifié exige un rapport Windows lié au ZIP livré.') }
        if ($lines.Count -gt 0) { $tip = [string]::Join([Environment]::NewLine,[string[]]$lines) }
    } catch {
        $label.Text = 'Compatibilité de ce poste : non évaluée (' + $_.Exception.Message + ').'
    }
    if ($tip) { $label.ToolTip = $tip } else { $label.ToolTip = $null }
    try { [Windows.Automation.AutomationProperties]::SetHelpText($label,$tip) } catch { Write-DomeniaSwallowed 'Compatibilité' 'Update-DomeniaAboutCompatibility' $_ }
}

function Get-DomeniaCompatibilitySupportFields {
    # Technical dossier: versions and statuses only (no machine, account or path).
    $fields = [ordered]@{}
    try {
        $state = Get-DomeniaLocalCompatibility
        $fields['Compatibility'] = [string]$state.Verdict.Overall
        $fields['CompatibilityMatrix'] = [string]$state.Verdict.ReviewedOn
        $fields['WindowsBuild'] = $state.Facts.Windows.Build
        $fields['WindowsProduct'] = $state.Facts.Windows.Product
        $fields['DotNetRelease'] = $state.Facts.DotNet.Release
        $fields['WinSqlite'] = $state.Facts.Sqlite.Present
        foreach ($row in @($state.Verdict.Rows)) { $fields[('Compatibility' + [string]$row.Dimension)] = [string]$row.Status }
    } catch { $fields['Compatibility'] = 'Inconnu' }
    return $fields
}
