# Compatibility matrix of Domenia (point 145). Pure rules: no WPF, no network, no disk.
# The matrix (Domenia-Compatibility.json, shipped with the modules) says which Windows, PowerShell, .NET Framework,
# SQLite, directory and CIM environments were really executed. The caller reads the local facts (registry, file
# version) and passes them here. A fact that was not read stays unknown: it is never taken as compatible.

function Get-DomeniaCompatibilityStatuses {
    # Closed list, ordered from the most to the least reassuring. Inconnu is a verdict only, never a matrix status.
    return @('Qualifie','Teste','Attendu','NonPrisEnCharge')
}

function Get-DomeniaCompatibilityStatusLabel {
    param([AllowEmptyString()][string]$Status)
    switch ($Status) {
        'Qualifie' { return 'qualifié' }
        'Teste' { return 'testé en labo, non qualifié' }
        'Attendu' { return 'prévu, jamais testé' }
        'NonPrisEnCharge' { return 'non pris en charge' }
        default { return 'inconnu' }
    }
}

function ConvertTo-DomeniaNetFrameworkLabel {
    # .NET Framework 4.x version from the Release value of HKLM\...\NDP\v4\Full. '' when unknown or older than 4.5.
    param($Release)
    $value = 0
    if (($null -eq $Release) -or (-not [int]::TryParse([string]$Release,[ref]$value)) -or ($value -le 0)) { return '' }
    $table = @(
        @(533320,'4.8.1'),@(528040,'4.8'),@(461808,'4.7.2'),@(461308,'4.7.1'),@(460798,'4.7'),
        @(394802,'4.6.2'),@(394254,'4.6.1'),@(393295,'4.6'),@(379893,'4.5.2'),@(378675,'4.5.1'),@(378389,'4.5')
    )
    foreach ($row in $table) { if ($value -ge [int]$row[0]) { return [string]$row[1] } }
    return ''
}

function ConvertTo-DomeniaCompatibilityVersion {
    # [version] from '5.1', '5.1.26100.6584' or a [version]; $null when unreadable.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [version]) { return $Value }
    $parsed = $null
    if ([version]::TryParse(([string]$Value).Trim(),[ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-DomeniaEnvironmentFacts {
    # Normalises what the caller read on this workstation. Every value may be absent: it then stays $null (unknown).
    # Parameter names avoid the automatic variables $PSEdition and $PSVersionTable.
    # InstallationType comes from HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion ('Client', 'Server', 'Server Core').
    param(
        [AllowEmptyString()][string]$InstallationType = '',
        [AllowEmptyString()][string]$CurrentBuild = '',
        [AllowEmptyString()][string]$DisplayVersion = '',
        [AllowEmptyString()][string]$ShellEdition = '',
        [AllowEmptyString()][string]$ShellVersion = '',
        $Is64BitProcess = $null,
        $NetRelease = $null,
        $SqlitePresent = $null,
        [AllowEmptyString()][string]$SqliteVersion = ''
    )
    $product = $null
    $type = $InstallationType.Trim()
    if ($type -ieq 'Client') { $product = 'Client' }
    elseif ($type -like 'Server*') { $product = 'Server' }
    $build = $null
    $number = 0
    if ([int]::TryParse($CurrentBuild.Trim(),[ref]$number) -and ($number -gt 0)) { $build = $number }
    $windowsLabel = ''
    if (($null -ne $product) -and ($null -ne $build)) {
        $name = 'Windows Server'
        if ($product -ceq 'Client') { $name = 'Windows 10'; if ($build -ge 22000) { $name = 'Windows 11' } }
        $windowsLabel = $name
        if ($DisplayVersion.Trim()) { $windowsLabel += ' ' + $DisplayVersion.Trim() }
        $windowsLabel += ' (build ' + [string]$build + ')'
    }
    $edition = $null
    if ($ShellEdition.Trim()) { $edition = $ShellEdition.Trim() }
    $version = ConvertTo-DomeniaCompatibilityVersion $ShellVersion
    $bitness = $null
    if ($null -ne $Is64BitProcess) { $bitness = 32; if ([bool]$Is64BitProcess) { $bitness = 64 } }
    $psLabel = ''
    if (($null -ne $edition) -and ($null -ne $version)) {
        $psLabel = 'PowerShell ' + $version.ToString()
        if ($edition -ceq 'Desktop') { $psLabel = 'Windows PowerShell ' + $version.ToString() }
        if ($null -ne $bitness) { $psLabel += ' ' + [string]$bitness + ' bits' }
    }
    $release = $null
    $releaseValue = 0
    if (($null -ne $NetRelease) -and [int]::TryParse([string]$NetRelease,[ref]$releaseValue) -and ($releaseValue -gt 0)) { $release = $releaseValue }
    $netLabel = ''
    if ($null -ne $release) {
        $netLabel = ConvertTo-DomeniaNetFrameworkLabel $release
        if ($netLabel) { $netLabel = '.NET Framework ' + $netLabel } else { $netLabel = '.NET Framework antérieur à 4.5' }
    }
    $present = $null
    if ($null -ne $SqlitePresent) { $present = [bool]$SqlitePresent }
    $sqliteLabel = ''
    if ($null -ne $present) {
        $sqliteLabel = 'winsqlite3.dll absent'
        if ($present) { $sqliteLabel = 'winsqlite3.dll présent'; if ($SqliteVersion.Trim()) { $sqliteLabel += ' (' + $SqliteVersion.Trim() + ')' } }
    }
    return [pscustomobject]@{
        Windows = [pscustomobject]@{ Product = $product; Build = $build; Label = $windowsLabel }
        PowerShell = [pscustomobject]@{ Edition = $edition; Version = $version; Bitness = $bitness; Label = $psLabel }
        DotNet = [pscustomobject]@{ Release = $release; Label = $netLabel }
        Sqlite = [pscustomobject]@{ Present = $present; Label = $sqliteLabel }
    }
}

function Test-DomeniaCompatibilityMatch {
    # 'Match', 'NoMatch' or 'Unknown' (a fact needed by the condition was not read). An empty condition never matches
    # observed facts: it describes a documentation-only entry.
    param($Match,$Facts)
    $keys = @()
    if ($Match -is [Collections.IDictionary]) { $keys = @($Match.Keys) }
    elseif ($null -ne $Match) { $keys = @($Match.PSObject.Properties | ForEach-Object { $_.Name }) }
    if ($keys.Count -eq 0) { return 'NoMatch' }
    $unknown = $false
    foreach ($key in $keys) {
        $expected = Get-DomeniaMember $Match ([string]$key)
        $verdict = 'NoMatch'
        switch ([string]$key) {
            'Product' { $actual = Get-DomeniaMember $Facts 'Product'; if ($null -eq $actual) { $verdict = 'Unknown' } elseif ([string]$actual -ceq [string]$expected) { $verdict = 'Match' } }
            'Edition' { $actual = Get-DomeniaMember $Facts 'Edition'; if ($null -eq $actual) { $verdict = 'Unknown' } elseif ([string]$actual -ceq [string]$expected) { $verdict = 'Match' } }
            'Present' { $actual = Get-DomeniaMember $Facts 'Present'; if ($null -eq $actual) { $verdict = 'Unknown' } elseif ([bool]$actual -eq [bool]$expected) { $verdict = 'Match' } }
            'Bitness' { $actual = Get-DomeniaMember $Facts 'Bitness'; if ($null -eq $actual) { $verdict = 'Unknown' } elseif ([int]$actual -eq [int]$expected) { $verdict = 'Match' } }
            { $_ -in @('MinBuild','MaxBuild','MinRelease','MaxRelease') } {
                $field = 'Build'; if ($_ -like '*Release') { $field = 'Release' }
                $actual = Get-DomeniaMember $Facts $field
                if ($null -eq $actual) { $verdict = 'Unknown' }
                elseif ($_ -like 'Min*') { if ([long]$actual -ge [long]$expected) { $verdict = 'Match' } }
                elseif ([long]$actual -le [long]$expected) { $verdict = 'Match' }
            }
            { $_ -in @('MinVersion','MaxVersion') } {
                $actual = ConvertTo-DomeniaCompatibilityVersion (Get-DomeniaMember $Facts 'Version')
                $bound = ConvertTo-DomeniaCompatibilityVersion $expected
                if ($null -eq $actual) { $verdict = 'Unknown' }
                elseif ($null -eq $bound) { $verdict = 'NoMatch' }
                elseif ($_ -ceq 'MinVersion') { if ($actual -ge $bound) { $verdict = 'Match' } }
                elseif ($actual -le $bound) { $verdict = 'Match' }
            }
            default { $verdict = 'NoMatch' }
        }
        if ($verdict -ceq 'NoMatch') { return 'NoMatch' }
        if ($verdict -ceq 'Unknown') { $unknown = $true }
    }
    if ($unknown) { return 'Unknown' }
    return 'Match'
}

function Test-DomeniaCompatibilityMatrix {
    # Structural check of the shipped matrix. Qualifie needs a qualification report bound to the delivered ZIP; an
    # observed dimension needs conditions on each entry; ids are unique per dimension.
    param($Matrix)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Matrix) { return [pscustomobject]@{ Valid = $false; Problems = @('Matrice absente.') } }
    if ([string](Get-DomeniaMember $Matrix 'Schema' '') -cne 'DomeniaCompatibilityMatrix/1') { $problems.Add('Schéma de matrice inconnu.') }
    $statuses = @(Get-DomeniaCompatibilityStatuses)
    $dimensions = @(Get-DomeniaMember $Matrix 'Dimensions' @())
    if ($dimensions.Count -eq 0) { $problems.Add('Matrice sans dimension.') }
    $dimensionIds = @{}
    foreach ($dimension in $dimensions) {
        $id = [string](Get-DomeniaMember $dimension 'Id' '')
        if (-not $id) { $problems.Add('Dimension sans identifiant.'); continue }
        if ($dimensionIds.ContainsKey($id)) { $problems.Add('Dimension en double : ' + $id) }
        $dimensionIds[$id] = $true
        $observed = [bool](Get-DomeniaMember $dimension 'Observed' $false)
        $entries = @(Get-DomeniaMember $dimension 'Entries' @())
        if ($entries.Count -eq 0) { $problems.Add($id + ' : aucune entrée.') }
        $entryIds = @{}
        foreach ($entry in $entries) {
            $entryId = [string](Get-DomeniaMember $entry 'Id' '')
            if ((-not $entryId) -or $entryIds.ContainsKey($entryId)) { $problems.Add($id + ' : entrée sans identifiant ou en double (' + $entryId + ').'); continue }
            $entryIds[$entryId] = $true
            $status = [string](Get-DomeniaMember $entry 'Status' '')
            if ($statuses -cnotcontains $status) { $problems.Add($id + '/' + $entryId + ' : statut inconnu (' + $status + ').') }
            if (-not [string](Get-DomeniaMember $entry 'Label' '')) { $problems.Add($id + '/' + $entryId + ' : libellé manquant.') }
            $evidence = @(Get-DomeniaMember $entry 'Evidence' @())
            if ($status -ceq 'Qualifie') {
                $bound = @($evidence | Where-Object { ([string](Get-DomeniaMember $_ 'Kind' '') -ceq 'Qualification') -and ([string](Get-DomeniaMember $_ 'ArchiveSha256' '') -match '^[0-9A-Fa-f]{64}$') })
                if ($bound.Count -eq 0) { $problems.Add($id + '/' + $entryId + ' : Qualifie exige un rapport de qualification lié au SHA-256 du ZIP.') }
            }
            if ($status -ceq 'Teste') {
                if (@($evidence | Where-Object { [string](Get-DomeniaMember $_ 'Ref' '') }).Count -eq 0) { $problems.Add($id + '/' + $entryId + ' : Teste exige la référence dʼun rapport dʼexécution.') }
            }
            $match = Get-DomeniaMember $entry 'Match'
            $conditions = 0
            if ($match -is [Collections.IDictionary]) { $conditions = $match.Count } elseif ($null -ne $match) { $conditions = @($match.PSObject.Properties).Count }
            if ($observed -and ($conditions -eq 0)) { $problems.Add($id + '/' + $entryId + ' : dimension observée sans condition.') }
        }
    }
    return [pscustomobject]@{ Valid = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

function Get-DomeniaCompatibilityVerdict {
    # One row per observed dimension: the first matching entry gives the status. Unread fact or environment absent
    # from the matrix: Inconnu, never compatible. Overall: the least reassuring row (NonPrisEnCharge, Inconnu,
    # Attendu, Teste, then Qualifie when every row is qualified).
    param($Matrix,$Facts)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $check = Test-DomeniaCompatibilityMatrix $Matrix
    if (-not $check.Valid) {
        return [pscustomobject]@{ Overall = 'Inconnu'; OverallLabel = (Get-DomeniaCompatibilityStatusLabel 'Inconnu'); Rows = @(); MatrixValid = $false; Problems = $check.Problems; ReviewedOn = '' }
    }
    foreach ($dimension in @(Get-DomeniaMember $Matrix 'Dimensions' @())) {
        if (-not [bool](Get-DomeniaMember $dimension 'Observed' $false)) { continue }
        $id = [string](Get-DomeniaMember $dimension 'Id' '')
        # Distinct name: PowerShell variables ignore case and $facts would replace the $Facts parameter.
        $dimensionFacts = Get-DomeniaMember $Facts $id
        $observedLabel = [string](Get-DomeniaMember $dimensionFacts 'Label' '')
        $status = 'Inconnu'; $entryLabel = ''; $note = ''; $unknown = $false
        foreach ($entry in @(Get-DomeniaMember $dimension 'Entries' @())) {
            $result = Test-DomeniaCompatibilityMatch (Get-DomeniaMember $entry 'Match') $dimensionFacts
            if ($result -ceq 'Unknown') { $unknown = $true; continue }
            if ($result -ceq 'Match') {
                $status = [string](Get-DomeniaMember $entry 'Status' '')
                $entryLabel = [string](Get-DomeniaMember $entry 'Label' '')
                $note = [string](Get-DomeniaMember $entry 'Note' '')
                break
            }
        }
        $label = [string](Get-DomeniaMember $dimension 'Label' $id)
        if (-not $observedLabel) { $observedLabel = 'non relevé' }
        if ($entryLabel) { $message = $label + ' : ' + $observedLabel + ', ' + (Get-DomeniaCompatibilityStatusLabel $status) + '.' }
        elseif ($unknown -or ($observedLabel -ceq 'non relevé')) { $message = $label + ' : ' + $observedLabel + ' ; compatibilité inconnue.' }
        else { $message = $label + ' : ' + $observedLabel + ', absent de la matrice ; compatibilité inconnue.' }
        $rows.Add([pscustomobject]@{ Dimension = $id; Label = $label; Observed = $observedLabel; Status = $status; StatusLabel = (Get-DomeniaCompatibilityStatusLabel $status); Entry = $entryLabel; Note = $note; Message = $message })
    }
    $order = @('NonPrisEnCharge','Inconnu','Attendu','Teste','Qualifie')
    $overall = 'Inconnu'
    if ($rows.Count -gt 0) {
        foreach ($candidate in $order) { if (@($rows | Where-Object { $_.Status -ceq $candidate }).Count -gt 0) { $overall = $candidate; break } }
    }
    return [pscustomobject]@{ Overall = $overall; OverallLabel = (Get-DomeniaCompatibilityStatusLabel $overall); Rows = $rows.ToArray(); MatrixValid = $true; Problems = @(); ReviewedOn = [string](Get-DomeniaMember $Matrix 'ReviewedOn' '') }
}

function Get-DomeniaCompatibilityText {
    # Short sentence for À propos: the overall status, then the row that decides it when it is not the best case.
    param($Verdict)
    if ($null -eq $Verdict) { return 'Compatibilité de ce poste : non évaluée.' }
    if (-not [bool](Get-DomeniaMember $Verdict 'MatrixValid' $false)) { return 'Compatibilité de ce poste : inconnue (matrice de compatibilité absente ou illisible).' }
    $overall = [string](Get-DomeniaMember $Verdict 'Overall' 'Inconnu')
    $text = 'Compatibilité de ce poste : environnement ' + (Get-DomeniaCompatibilityStatusLabel $overall) + '.'
    $decisive = @(@(Get-DomeniaMember $Verdict 'Rows' @()) | Where-Object { $_.Status -ceq $overall })
    if (($overall -cne 'Qualifie') -and ($decisive.Count -gt 0)) { $text += ' ' + [string]$decisive[0].Message }
    return $text
}
