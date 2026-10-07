# Software board provider (dashboards made of widgets, decision David 2026-10-07): turns the software list read
# by the software worker into the entries of the Software board (catalog keys software.*).
# Pure rules: no WPF, no network, no disk; relies on the contract of Domenia-Boards.Model.ps1.

function Get-DomeniaSoftwareBoardData {
    # Port of the old Update-DomeniaSoftwareDashboard: count, declared size, publishers (top 6 + Autres),
    # architecture, installation scope, names installed in several versions, missing publishers, largest products.
    # Rows: Name, Publisher, Version, Architecture, Scope, SizeKb. Missing fields and odd sizes are tolerated.
    param($Rows = @())
    $data = New-DomeniaBoardData -Board Software
    $unknownPublisher = 'Editeur non renseigne'
    $unknownValue = 'Non precise'
    # Neutral greys, one per meaning (not a real category): the pastel 'Off' grey for an unknown value, the darker
    # slate of the renderer's own grouped part for "Autres", so the two slices and legend dots never look alike.
    $grey = Get-DomeniaBoardColor 'Off'
    $restGrey = '#94A3B8'
    $sortGroups = @(@{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })

    # Rows are read defensively (StrictMode: never read a missing property) and normalised once.
    $field = {
        param($Row,[string]$Name)
        $raw = $null
        if ($Row -is [System.Collections.IDictionary]) { if ($Row.Contains($Name)) { $raw = $Row[$Name] } }
        elseif ($null -ne $Row.PSObject.Properties[$Name]) { $raw = $Row.$Name }
        return $raw
    }
    $text = {
        param($Row,[string]$Name)
        $value = & $field $Row $Name
        if ($null -eq $value) { return '' }
        return ([string]$value).Trim()
    }
    $plural = {
        param([int]$Number,[string]$One,[string]$Many)
        if ($Number -gt 1) { return ([string]$Number + ' ' + $Many) }
        return ([string]$Number + ' ' + $One)
    }
    $software = New-Object System.Collections.ArrayList
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $name = & $text $row 'Name'
        if (-not $name) { continue }
        $kb = 0.0
        try { $kb = [double](& $field $row 'SizeKb') } catch { $kb = 0.0 }
        if (([double]::IsNaN($kb)) -or ([double]::IsInfinity($kb)) -or ($kb -lt 0)) { $kb = 0.0 }
        [void]$software.Add([pscustomobject]@{
            Name = $name
            Publisher = (& $text $row 'Publisher')
            Version = (& $text $row 'Version')
            Architecture = (& $text $row 'Architecture')
            Scope = (& $text $row 'Scope')
            SizeKb = $kb
        })
    }
    $total = $software.Count
    if (-not $total) {
        $data.Summary = 'Aucun logiciel lu.'
        foreach ($section in @('Synthese','Repartition')) { $data.Hints[$section] = 'Aucun logiciel lu : chargez les logiciels du poste pour remplir cette section.' }
        [void](Complete-DomeniaBoardData -Data $data)
        return $data
    }

    # Synthese: count and number of declared publishers (the "not declared" group is not a publisher).
    $publishers = @($software | Group-Object -Property { if ($_.Publisher) { $_.Publisher } else { $unknownPublisher } } | Sort-Object -Property $sortGroups)
    $declared = @($publishers | Where-Object { [string]$_.Name -ne $unknownPublisher }).Count
    $publisherText = 'Aucun editeur declare'
    if ($declared) { $publisherText = & $plural $declared 'editeur' 'editeurs' }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'software.count' -Kind Value -Value ([string]$total) -Detail $publisherText)

    # Synthese: sum of the known sizes (omitted when no size is declared at all).
    $sized = @($software | Where-Object { $_.SizeKb -gt 0 })
    if ($sized.Count) {
        $totalKb = 0.0
        foreach ($item in $sized) { $totalKb += $item.SizeKb }
        $sizeDetail = 'Somme des tailles connues'
        if ($sized.Count -lt $total) { $sizeDetail = $sizeDetail + ' (' + [string]$sized.Count + ' sur ' + [string]$total + ')' }
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'software.size' -Kind Value -Value (Format-DomeniaDashboardSize ($totalKb * 1KB)) -Detail $sizeDetail)
    }

    # Synthese: names (case-insensitive) present in more than one version; the most duplicated first.
    $multiple = @($software | Group-Object -Property { $_.Name.ToLowerInvariant() } | ForEach-Object {
        $named = $_
        $versions = @($named.Group | ForEach-Object { [string]$_.Version } | Sort-Object -Unique)
        if ($versions.Count -gt 1) { [pscustomobject]@{ Name = [string]$named.Group[0].Name; Versions = $versions.Count } }
    } | Sort-Object -Property @(@{ Expression = 'Versions'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }))
    $multipleDetail = 'Aucun doublon de version'
    if ($multiple.Count -eq 1) { $multipleDetail = [string]$multiple[0].Name + ' : ' + [string]$multiple[0].Versions + ' versions' }
    elseif ($multiple.Count -gt 1) { $multipleDetail = [string]$multiple[0].Name + ' et ' + [string]($multiple.Count - 1) + ' autre(s)' }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'software.multiversion' -Kind Value -Value ([string]$multiple.Count) -Detail $multipleDetail)

    # Synthese: products without a declared publisher, in list order.
    $anonymous = @($software | Where-Object { -not $_.Publisher })
    $anonymousDetail = 'Tous les editeurs sont renseignes'
    if ($anonymous.Count -eq 1) { $anonymousDetail = [string]$anonymous[0].Name }
    elseif ($anonymous.Count -gt 1) { $anonymousDetail = [string]$anonymous[0].Name + ' et ' + [string]($anonymous.Count - 1) + ' autre(s)' }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'software.nopublisher' -Kind Value -Value ([string]$anonymous.Count) -Detail $anonymousDetail)

    # Repartition: rings of software counts, largest first; ties ordered by name so the result is stable.
    $addRing = {
        param([string]$Key,[object[]]$Groups,[string]$Missing,[int]$Keep = 0)
        $all = @($Groups | Where-Object { $null -ne $_ })
        if (-not $all.Count) { return }
        $shown = @(if ($Keep -gt 0) { $all | Select-Object -First $Keep } else { $all })
        $parts = New-Object System.Collections.ArrayList
        foreach ($group in $shown) {
            if ([string]$group.Name -eq $Missing) { [void]$parts.Add([pscustomobject]@{ Label = [string]$group.Name; Value = [double]$group.Count; Color = $grey }) }
            else { [void]$parts.Add([pscustomobject]@{ Label = [string]$group.Name; Value = [double]$group.Count }) }
        }
        $rest = 0
        foreach ($group in @($all | Select-Object -Skip $shown.Count)) { $rest += [int]$group.Count }
        if ($rest -gt 0) { [void]$parts.Add([pscustomobject]@{ Label = 'Autres'; Value = [double]$rest; Color = $restGrey }) }
        $top = $all[0]
        $detail = (& $plural ([int]$top.Count) 'logiciel' 'logiciels') + ' sur ' + [string]$total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key $Key -Kind Distribution -Value ([string]$top.Name) -Detail $detail -Items @($parts) -CenterText (& $plural $total 'logiciel' 'logiciels'))
    }
    $null = & $addRing 'software.publishers' $publishers $unknownPublisher 6
    $architecture = @($software | Group-Object -Property { if ($_.Architecture) { $_.Architecture } else { $unknownValue } } | Sort-Object -Property $sortGroups)
    $null = & $addRing 'software.architecture' $architecture $unknownValue
    $scopes = @($software | Group-Object -Property { if ($_.Scope) { $_.Scope } else { $unknownValue } } | Sort-Object -Property $sortGroups)
    $null = & $addRing 'software.scope' $scopes $unknownValue

    # Repartition: the 8 largest declared sizes in Mo (one series: no meaning colour, the renderer uses its accent).
    # Every field is a tie-breaker: Sort-Object is not stable under 5.1, the cut-off at 8 must not depend on input order.
    $sortLargest = @(@{ Expression = 'SizeKb'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }, @{ Expression = 'Version'; Descending = $false }, @{ Expression = 'Scope'; Descending = $false }, @{ Expression = 'Architecture'; Descending = $false })
    $largest = @($software | Where-Object { $_.SizeKb -gt 0 } | Sort-Object -Property $sortLargest | Select-Object -First 8)
    if ($largest.Count) {
        $names = @{}
        foreach ($item in $largest) { $lower = $item.Name.ToLowerInvariant(); $names[$lower] = 1 + [int]$names[$lower] }
        # A name shown twice gets its version; a label still shown twice (same version in two scopes or
        # architectures) then gets its scope, then its architecture, so the bars can be told apart.
        $labels = @(foreach ($item in $largest) {
            if (([int]$names[$item.Name.ToLowerInvariant()] -gt 1) -and ($item.Version)) { $item.Name + ' ' + $item.Version } else { $item.Name }
        })
        $tags = @(foreach ($item in $largest) { '' })
        foreach ($extra in @('Scope','Architecture')) {
            $seen = @{}
            for ($i = 0; $i -lt $labels.Count; $i++) { $same = ($labels[$i] + '|' + $tags[$i]).ToLowerInvariant(); $seen[$same] = 1 + [int]$seen[$same] }
            for ($i = 0; $i -lt $labels.Count; $i++) {
                $value = [string]$largest[$i].$extra
                if (([int]$seen[($labels[$i] + '|' + $tags[$i]).ToLowerInvariant()] -gt 1) -and ($value)) {
                    if ($tags[$i]) { $tags[$i] = $tags[$i] + ', ' + $value } else { $tags[$i] = $value }
                }
            }
        }
        $bars = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $largest.Count; $i++) {
            $item = $largest[$i]
            $label = $labels[$i]
            if ($tags[$i]) { $label = $label + ' (' + $tags[$i] + ')' }
            $mo = $item.SizeKb / 1024
            $rounded = [Math]::Round($mo)
            if ($mo -lt 10) { $rounded = [Math]::Round($mo, 1) }
            [void]$bars.Add([pscustomobject]@{ Label = $label; Value = [double]$rounded })
        }
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'software.largest' -Kind Distribution -Value ([string]$bars[0].Label) -Detail (Format-DomeniaDashboardSize ($largest[0].SizeKb * 1KB)) -Items @($bars) -Unit 'Mo')
    }

    $read = 'logiciel lu.'
    if ($total -gt 1) { $read = 'logiciels lus.' }
    $data.Summary = [string]$total + ' ' + $read + ' Synthese calculee sur la liste chargee.'
    [void](Complete-DomeniaBoardData -Data $data)
    return $data
}
