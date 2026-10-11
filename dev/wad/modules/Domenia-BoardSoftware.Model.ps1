# Software board provider (dashboards made of widgets, decision David 2026-10-07): turns the software list read
# by the software worker into the entries of the Software board (catalog keys software.*).
# Pure rules: no WPF, no network, no disk; relies on the contract of Domenia-Boards.Model.ps1.

# FO-09: a click on a ring part or on a bar filters the software list the board was drawn from. The three rules
# below decide what a click means; they hold no WPF and no list, so they are tested on their own. A selection is
# { Field; Value }: Field names a property of a software row, Value is what the chart showed for that part.
function Test-DomeniaSoftwareRowMatchesSelect {
    # Rows the selection keeps. No selection keeps everything; a selection the product does not know about
    # (unknown field, empty value) keeps nothing: an unknown field must never read as "everything passes".
    param($Row,$Select)
    if ($null -eq $Select) { return $true }
    $fields = @('Publisher','Architecture','Scope','Name')
    $field = ([string]$Select.Field).Trim()
    $value = ([string]$Select.Value).Trim()
    if (-not $field -or -not $value) { return $false }
    if ($fields -notcontains $field) { return $false }
    if ($null -eq $Row) { return $false }
    $cell = ''
    if ($Row -is [System.Collections.IDictionary]) { if ($Row.Contains($field)) { $cell = [string]$Row[$field] } }
    elseif ($null -ne $Row.PSObject.Properties[$field]) { $cell = [string]$Row.$field }
    return (([string]$cell).Trim() -ieq $value)
}

function Get-DomeniaSoftwareSelectLabel {
    # Text of the chip shown over the list. The chip is the only trace of a filter that comes from a chart: the
    # scope selector, unlike it, stays visible in the toolbar. An empty text means "nothing to clear".
    param($Select)
    if ($null -eq $Select) { return '' }
    $value = ([string]$Select.Value).Trim()
    if (-not $value) { return '' }
    return ('Filtré : ' + $value)
}

function Get-DomeniaSoftwareSelectToggle {
    # A second click on the same part removes the filter, a click on another part replaces it (FO-09). The
    # selection is normalised here, so what the interface keeps has one shape and one case whatever the chart sent.
    param($Current,$Incoming)
    if ($null -eq $Incoming) { return $null }
    $field = ([string]$Incoming.Field).Trim()
    $value = ([string]$Incoming.Value).Trim()
    if (-not $field -or -not $value) { return $null }
    if (($null -ne $Current) -and (([string]$Current.Field) -eq $field) -and (([string]$Current.Value) -ieq $value)) { return $null }
    return [pscustomobject]@{ Field = $field; Value = $value }
}

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
        param([string]$Key,[object[]]$Groups,[string]$Missing,[int]$Keep = 0,[string]$Field = '')
        $all = @($Groups | Where-Object { $null -ne $_ })
        if (-not $all.Count) { return }
        $shown = @(if ($Keep -gt 0) { $all | Select-Object -First $Keep } else { $all })
        $parts = New-Object System.Collections.ArrayList
        foreach ($group in $shown) {
            # FO-09: every real group carries the criterion a click on it applies; the grey 'Autres' part does
            # not, it gathers several publishers under one label and would filter the list on a false name.
            $select = $null
            # The unknown group ('Editeur non renseigne', 'Non precise') names a label the board invented for the
            # rows that hold no value: no row carries it, so clicking it would empty the list. Only a value the
            # rows really carry becomes a criterion.
            if ($Field -and ([string]$group.Name -ne $Missing)) { $select = [pscustomobject]@{ Field = $Field; Value = [string]$group.Name } }
            # A part with no criterion carries no Select property at all (not a null one): the renderer reads the
            # property to decide whether the part is clickable, and one shape keeps that decision honest.
            $part = [ordered]@{ Label = [string]$group.Name; Value = [double]$group.Count }
            if ([string]$group.Name -eq $Missing) { $part['Color'] = $grey }
            if ($null -ne $select) { $part['Select'] = $select }
            [void]$parts.Add([pscustomobject]$part)
        }
        $rest = 0
        foreach ($group in @($all | Select-Object -Skip $shown.Count)) { $rest += [int]$group.Count }
        if ($rest -gt 0) { [void]$parts.Add([pscustomobject]@{ Label = 'Autres'; Value = [double]$rest; Color = $restGrey }) }
        $top = $all[0]
        $detail = (& $plural ([int]$top.Count) 'logiciel' 'logiciels') + ' sur ' + [string]$total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key $Key -Kind Distribution -Value ([string]$top.Name) -Detail $detail -Items @($parts) -CenterText (& $plural $total 'logiciel' 'logiciels'))
    }
    $null = & $addRing 'software.publishers' $publishers $unknownPublisher 6 'Publisher'
    $architecture = @($software | Group-Object -Property { if ($_.Architecture) { $_.Architecture } else { $unknownValue } } | Sort-Object -Property $sortGroups)
    $null = & $addRing 'software.architecture' $architecture $unknownValue 0 'Architecture'
    $scopes = @($software | Group-Object -Property { if ($_.Scope) { $_.Scope } else { $unknownValue } } | Sort-Object -Property $sortGroups)
    $null = & $addRing 'software.scope' $scopes $unknownValue 0 'Scope'

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
            # The bar length stays in Mo; its text is the readable size ('2,3 Go', never '2354 Mo'; CO-16).
            # FO-09: the bar filters on the software name, not on its decorated label (the label may carry a
            # version and a scope added only to tell two bars apart).
            [void]$bars.Add([pscustomobject]@{ Label = $label; Value = [double]$rounded; Display = (Format-DomeniaDashboardSize ($item.SizeKb * 1KB)); Select = [pscustomobject]@{ Field = 'Name'; Value = $item.Name } })
        }
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'software.largest' -Kind Distribution -Value ([string]$bars[0].Label) -Detail (Format-DomeniaDashboardSize ($largest[0].SizeKb * 1KB)) -Items @($bars) -Unit 'Mo')
    }

    $read = 'logiciel lu.'
    if ($total -gt 1) { $read = 'logiciels lus.' }
    $data.Summary = [string]$total + ' ' + $read + ' Synthese calculee sur la liste chargee.'
    [void](Complete-DomeniaBoardData -Data $data)
    return $data
}
