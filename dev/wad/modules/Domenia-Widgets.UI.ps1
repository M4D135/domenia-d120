# Dashboard widgets (decision David 2026-10-07, phase 1): ready-made read-only probes shown as KPI, text, pie, bars or
# histogram on the fleet and workstation dashboards. Draft by the Spark; editor and widget element rewritten.

function Get-DomeniaWidgetList {
    param(
        [string]$Board
    )
    $key = "Widgets.$Board"
    $raw = Get-DomeniaSetting -Name $key -Default ""
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }
    try {
        $list = $raw | ConvertFrom-Json
        if ($null -eq $list) { return @() }
        if ($list -isnot [array]) { $list = @($list) }
        return $list
    } catch {
        return @()
    }
}

function Save-DomeniaWidgetList {
    param(
        [string]$Board,
        $Widgets
    )
    $key = "Widgets.$Board"
    if ($null -eq $Widgets) { $Widgets = @() }
    $json = $Widgets | ConvertTo-Json -Compress -Depth 5
    Set-DomeniaSetting -Name $key -Value $json
    Save-DomeniaSettings -Immediate
}

function Remove-DomeniaWidget {
    param(
        [string]$Board,
        [string]$Id
    )
    $list = Get-DomeniaWidgetList -Board $Board
    $filtered = $list | Where-Object { $_.Id -ne $Id }
    Save-DomeniaWidgetList -Board $Board -Widgets $filtered
}

function Get-DomeniaWidgetResults {
    param(
        [string]$Board,
        [string]$ProbeId
    )
    $results = @()
    if ($Board -eq "Fleet") {
        $scope = $script:FleetLast.Scope
        $targets = $script:FleetLast.Targets
        if ($null -eq $script:FleetObservations) { return @() }
        foreach ($dn in $script:FleetObservations.Keys) {
            $obs = $script:FleetObservations[$dn]
            if ($null -eq $obs -or $null -eq $obs.Probes) { continue }
            $dnLower = $dn.ToLower()
            $inScope = $true
            if ([string]::IsNullOrWhiteSpace($scope)) {
                $inScope = $true
            } else {
                $scopeLower = $scope.ToLower()
                $suffix = "," + $scopeLower
                if (-not $dnLower.EndsWith($suffix)) {
                    $inScope = $false
                }
            }
            if (-not $inScope) { continue }
            if ($obs.Probes.PSObject.Properties.Name -contains $ProbeId) {
                $res = $obs.Probes.$ProbeId
                if ($null -ne $res) {
                    $results += $res
                }
            }
        }
    } elseif ($Board -eq "Computer") {
        if ($null -eq $script:SelectedObject) { return @() }
        $dn = $script:SelectedObject.DN
        if ([string]::IsNullOrWhiteSpace($dn)) { return @() }
        $dnLower = $dn.ToLower()
        if ($null -eq $script:FleetObservations) { return @() }
        if ($script:FleetObservations.ContainsKey($dnLower)) {
            $obs = $script:FleetObservations[$dnLower]
            if ($null -ne $obs -and $null -ne $obs.Probes) {
                if ($obs.Probes.PSObject.Properties.Name -contains $ProbeId) {
                    $res = $obs.Probes.$ProbeId
                    if ($null -ne $res) {
                        $results += $res
                    }
                }
            }
        }
    }
    return $results
}

function Add-DomeniaWidgetSection {
    param(
        [Windows.Controls.StackPanel]$Panel,
        [string]$Board,
        [scriptblock]$OnChanged
    )
    $wrap = New-DomeniaDashboardSection $Panel "Widgets"
    if ($null -eq $wrap) { return }

    $btnAddWidget = [Windows.Controls.Button]::new()
    $btnAddWidget.Content = "Ajouter un widget"
    $btnAddWidget.Margin = [Windows.Thickness]::new(6,6,6,6)
    $btnAddWidget.SetResourceReference([Windows.Controls.Control]::StyleProperty,"RunButton")
    $btnAddWidget.Tag = @{ Board = $Board; OnChanged = $OnChanged }
    $btnAddWidget.Add_Click({
        param($s, $e)
        $tag = $s.Tag
        $added = Show-DomeniaWidgetEditor -Board $tag.Board
        if ($added -and $null -ne $tag.OnChanged) { & $tag.OnChanged }
    })
    $toolbar = [Windows.Controls.StackPanel]::new(); $toolbar.Orientation = 'Horizontal'; $toolbar.Margin = [Windows.Thickness]::new(0,0,0,6)
    foreach ($b in @($btnAddWidget)) { $b.MinHeight = 30; $b.Padding = [Windows.Thickness]::new(12,4,12,4); $b.VerticalAlignment = 'Top' }
    [void]$toolbar.Children.Add($btnAddWidget)

    $btnProbe = [Windows.Controls.Button]::new()
    $btnProbe.Content = "Sonder"
    $btnProbe.Margin = [Windows.Thickness]::new(6,6,6,6)
    $btnProbe.SetResourceReference([Windows.Controls.Control]::StyleProperty,"SecondaryButton")
    $btnProbe.ToolTip = "Lance les requetes des widgets (lecture seule) sur le perimetre, avec confirmation."
    $btnProbe.Tag = @{ Board = $Board; OnChanged = $OnChanged }
    $btnProbe.Add_Click({
        param($s, $e)
        $tag = $s.Tag
        Start-DomeniaWidgetProbe -Board $tag.Board
        if ($null -ne $tag.OnChanged) { & $tag.OnChanged }
    })
    $btnProbe.MinHeight = 30; $btnProbe.Padding = [Windows.Thickness]::new(12,4,12,4); $btnProbe.VerticalAlignment = 'Top'
    [void]$toolbar.Children.Add($btnProbe)
    $section = $wrap.Parent; [void]$section.Children.Insert(1,$toolbar)

    $widgets = @(Get-DomeniaWidgetList -Board $Board)
    foreach ($w in $widgets) {
        $elem = New-DomeniaWidgetElement -Board $Board -Widget $w -OnChanged $OnChanged
        if ($null -ne $elem) {
            [void]$wrap.Children.Add($elem)
        }
    }
}

function Start-DomeniaWidgetProbe {
    param(
        [string]$Board
    )
    $widgets = Get-DomeniaWidgetList -Board $Board
    if ($null -eq $widgets -or $widgets.Count -lt 1) {
        Set-Status "Aucun widget configure" -Level "WARN"
        return
    }

    $probeIds = $widgets | Select-Object -ExpandProperty ProbeId -Unique
    if ($null -eq $probeIds -or $probeIds.Count -lt 1) {
        Set-Status "Aucune requete associee" -Level "WARN"
        return
    }

    $probes = ConvertTo-DomeniaProbePayload -Ids $probeIds

    if ($Board -eq "Fleet") {
        $scope = $script:FleetLast.Scope
        if ([string]::IsNullOrWhiteSpace($scope)) {
            Set-Status "Choisissez une OU : jamais le domaine entier." -Level "WARN"
            return
        }
        if ($scope -eq $script:Conn.BaseDn) {
            Set-Status "Choisissez une OU : jamais le domaine entier." -Level "WARN"
            return
        }
        $targets = $script:FleetLast.Targets
        if ($null -eq $targets -or $targets.Count -lt 1) {
            Set-Status "Aucun poste dans le perimetre" -Level "WARN"
            return
        }
        $parts = $scope.Split(",")
        $ouName = $parts[0]
        if ($ouName.StartsWith("OU=")) { $ouName = $ouName.Substring(3) }
        $scopeLabel = $ouName
        Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $scopeLabel -Probes $probes
    } elseif ($Board -eq "Computer") {
        if ($null -eq $script:SelectedObject) {
            Set-Status "Aucun poste selectionne" -Level "WARN"
            return
        }
        $so = $script:SelectedObject
        $target = [PSCustomObject]@{
            name               = $so.Name
            distinguished_name = $so.DN
            object_guid        = [string]$so.Safety.Guid
        }
        $scopeLabel = $so.Name
        Start-DomeniaOnlinePark -ScopeTargets @($target) -ScopeLabel $scopeLabel -Probes $probes
    }
}

function Show-DomeniaWidgetEditor {
    # Choice of a ready-made probe, its visual and its title; the widget is saved for this board.
    param([string]$Board)
    $wdgCatalog = @(Get-DomeniaProbeCatalog)
    $wdgVisuals = [ordered]@{ 'Chiffre cle'='Kpi'; 'Texte'='Text'; 'Camembert'='Pie'; 'Barres'='Bar'; 'Histogramme'='Column' }
    $wdgW = [Windows.Window]::new(); $wdgW.Title = 'Ajouter un widget'; $wdgW.Width = 640; $wdgW.Height = 420
    $wdgGrid = [Windows.Controls.Grid]::new(); $wdgGrid.Margin = [Windows.Thickness]::new(10)
    foreach ($wdgI in 0..5) { $wdgRow = [Windows.Controls.RowDefinition]::new(); $wdgRow.Height = [Windows.GridLength]::Auto; [void]$wdgGrid.RowDefinitions.Add($wdgRow) }
    $wdgLast = [Windows.Controls.RowDefinition]::new(); $wdgLast.Height = [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star); [void]$wdgGrid.RowDefinitions.Add($wdgLast)
    $wdgC0 = [Windows.Controls.ColumnDefinition]::new(); $wdgC0.Width = [Windows.GridLength]::new(130); [void]$wdgGrid.ColumnDefinitions.Add($wdgC0); [void]$wdgGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $wdgPlace = { param($element,[int]$Row,[int]$Column) [Windows.Controls.Grid]::SetRow($element,$Row); [Windows.Controls.Grid]::SetColumn($element,$Column); $element.Margin = [Windows.Thickness]::new(4); [void]$wdgGrid.Children.Add($element) }
    $wdgLabel = { param([string]$Text,[int]$Row) $wdgT = [Windows.Controls.TextBlock]::new(); $wdgT.Text = $Text; $wdgT.VerticalAlignment = 'Center'; & $wdgPlace $wdgT $Row 0 }
    & $wdgLabel 'Categorie' 0; & $wdgLabel 'Requete' 1; & $wdgLabel 'Visuel' 2; & $wdgLabel 'Titre' 3
    $wdgCategory = [Windows.Controls.ComboBox]::new(); & $wdgPlace $wdgCategory 0 1
    $wdgQuery = [Windows.Controls.ComboBox]::new(); $wdgQuery.DisplayMemberPath = 'Name'; & $wdgPlace $wdgQuery 1 1
    $wdgVisual = [Windows.Controls.ComboBox]::new(); foreach ($wdgK in $wdgVisuals.Keys) { [void]$wdgVisual.Items.Add($wdgK) }; & $wdgPlace $wdgVisual 2 1
    $wdgTitle = [Windows.Controls.TextBox]::new(); $wdgTitle.MinHeight = 32; & $wdgPlace $wdgTitle 3 1
    $wdgHint = [Windows.Controls.TextBlock]::new(); $wdgHint.TextWrapping = 'Wrap'; $wdgHint.Text = 'Requetes en lecture seule. Le bouton Sonder du tableau de bord les execute sur le perimetre, avec confirmation.'; & $wdgPlace $wdgHint 4 1
    $wdgButtons = [Windows.Controls.StackPanel]::new(); $wdgButtons.Orientation = 'Horizontal'; $wdgButtons.HorizontalAlignment = 'Right'
    $wdgAdd = [Windows.Controls.Button]::new(); $wdgAdd.Content = 'Ajouter'; $wdgAdd.IsDefault = $true; $wdgAdd.Width = 120
    $wdgCancel = [Windows.Controls.Button]::new(); $wdgCancel.Content = 'Annuler'; $wdgCancel.IsCancel = $true; $wdgCancel.Width = 120
    [void]$wdgButtons.Children.Add($wdgCancel); [void]$wdgButtons.Children.Add($wdgAdd); & $wdgPlace $wdgButtons 5 1
    $wdgW.Content = $wdgGrid
    foreach ($wdgName in @($wdgCatalog | ForEach-Object { $_.Category } | Select-Object -Unique)) { [void]$wdgCategory.Items.Add($wdgName) }
    # Handlers run while Show-DomeniaEmbeddedWindow waits in this function: its variables are in scope.
    $wdgCategory.Add_SelectionChanged({ $wdgQuery.Items.Clear(); foreach ($wdgP in @($wdgCatalog | Where-Object { $_.Category -eq [string]$wdgCategory.SelectedItem })) { [void]$wdgQuery.Items.Add($wdgP) }; if ($wdgQuery.Items.Count) { $wdgQuery.SelectedIndex = 0 } })
    $wdgQuery.Add_SelectionChanged({ $wdgP = $wdgQuery.SelectedItem; if ($null -eq $wdgP) { return }; $wdgTitle.Text = [string]$wdgP.Name; foreach ($wdgK in $wdgVisuals.Keys) { if ($wdgVisuals[$wdgK] -eq [string]$wdgP.Visual) { $wdgVisual.SelectedItem = $wdgK } } })
    $wdgAdd.Add_Click({
        $wdgP = $wdgQuery.SelectedItem
        if ($null -eq $wdgP -or $null -eq $wdgVisual.SelectedItem) { return }
        $wdgList = @(Get-DomeniaWidgetList -Board $Board)
        $wdgList += [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N').Substring(0,8); ProbeId = [string]$wdgP.Id; Visual = [string]$wdgVisuals[[string]$wdgVisual.SelectedItem]; Title = $(if ($wdgTitle.Text.Trim()) { $wdgTitle.Text.Trim() } else { [string]$wdgP.Name }) }
        Save-DomeniaWidgetList -Board $Board -Widgets $wdgList
        Set-DomeniaSurfaceResult $wdgW $true
    })
    if ($wdgCategory.Items.Count) { $wdgCategory.SelectedIndex = 0 }
    return [bool](Show-DomeniaEmbeddedWindow $wdgW)
}
function New-DomeniaWidgetElement {
    # One widget: the measured probe drawn with the chosen visual, and a small button to remove it.
    param([string]$Board,$Widget,[scriptblock]$OnChanged)
    $sizes = @{ Kpi = @(230,110); Text = @(420,270); Pie = @(420,270); Bar = @(420,270); Column = @(420,270) }
    $size = $sizes[[string]$Widget.Visual]; if ($null -eq $size) { $size = @(230,110) }
    $probe = Get-DomeniaProbe -Id ([string]$Widget.ProbeId)
    $results = if ($null -ne $probe) { @(Get-DomeniaWidgetResults -Board $Board -ProbeId ([string]$Widget.ProbeId)) } else { @() }
    $measured = if ($results.Count) { Measure-DomeniaWidgetData -Probe $probe -Results $results -Visual ([string]$Widget.Visual) } else { $null }
    if ($null -eq $measured -or -not $measured.Machines) {
        $size = @(230,110)
        $chart = New-DomeniaKpiTile -Title ([string]$Widget.Title) -Value $(if ($null -eq $probe) { 'Requete inconnue' } else { 'Pas encore de resultat' }) -Detail 'Bouton Sonder'
    } else {
        $title = [string]$Widget.Title + ' (' + $measured.Machines + ' postes)'
        $chart = switch ([string]$Widget.Visual) {
            'Pie' { New-DomeniaDonutChart -Title $title -Items $measured.Items -Width $size[0] -Height $size[1]; break }
            'Bar' { New-DomeniaBarChart -Title $title -Items $measured.Items -Width $size[0] -Height $size[1]; break }
            'Column' { New-DomeniaColumnChart -Title $title -Items $measured.Items -Width $size[0] -Height $size[1]; break }
            'Text' {
                $panel = [Windows.Controls.StackPanel]::new()
                [void]$panel.Children.Add((New-DomeniaChartText -Text $title -Size 14 -Bold -Key 'TextColor'))
                foreach ($item in @($measured.Items | Select-Object -First 12)) { [void]$panel.Children.Add((New-DomeniaChartText -Text ([string]$item.Label + ' : ' + [int]$item.Value + ' poste(s)') -Size 12 -Key 'MutedColor')) }
                New-DomeniaChartCard -Width $size[0] -Height ([Math]::Min(270,[Math]::Max(110,70 + 20 * @($measured.Items | Select-Object -First 12).Count))) -Content $panel; break
            }
            default {
                $unit = switch -Regex ([string]$probe.Transform) { '^PercentFree$' { ' %'; break } '^GB' { ' Go'; break } '^DaysSince$' { ' j'; break } '^Mbps$' { ' Mbit/s'; break } default { '' } }
                $value = if ($measured.Numeric) { $sum = 0.0; foreach ($v in $measured.Values) { $sum += [double]$v }; ([string][Math]::Round($sum / @($measured.Values).Count,1)) + $unit } else { [string]@($measured.Items)[0].Label }
                New-DomeniaKpiTile -Title $title -Value $value -Detail $measured.Summary
            }
        }
    }
    $holder = [Windows.Controls.Grid]::new(); $holder.VerticalAlignment = 'Top'
    [void]$holder.Children.Add($chart)
    $remove = [Windows.Controls.Button]::new(); $remove.Content = 'x'; $remove.Width = 24; $remove.Height = 24; $remove.MinHeight = 24; $remove.Padding = [Windows.Thickness]::new(0)
    $remove.HorizontalAlignment = 'Right'; $remove.VerticalAlignment = 'Top'; $remove.Margin = [Windows.Thickness]::new(0,12,14,0); $remove.Background = [Windows.Media.Brushes]::Transparent; $remove.BorderThickness = [Windows.Thickness]::new(0); $remove.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'MutedColor'); $remove.ToolTip = 'Retirer ce widget'
    $remove.Tag = @{ Board = $Board; Id = [string]$Widget.Id; OnChanged = $OnChanged }
    $remove.Add_Click({ param($s,$e) $tag = $s.Tag; Remove-DomeniaWidget -Board $tag.Board -Id $tag.Id; if ($null -ne $tag.OnChanged) { & $tag.OnChanged } })
    [void]$holder.Children.Add($remove)
    return $holder
}
