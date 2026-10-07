# WPF charts drawn with native shapes (no external library), themed through DynamicResource keys.
# First draft by the Spark (2026-10-07), corrected and rendered in the VM before integration.
# Domenia-Charts.UI.ps1
# Native WPF chart primitives (PowerShell 5.1 / .NET Framework 4.x, no external libs).
# Each builder returns a ready-to-insert FrameworkElement. No globals, no classes, no Add-Type.

# ---------------------------------------------------------------------------
# Theme keys (resolved via SetResourceReference): TextColor, MutedColor,
# BorderColor, TileBg, AccentColor. Palette below is fixed 8-color, colorblind-safe.
# ---------------------------------------------------------------------------

function Get-DomeniaChartPalette {
    # 8 hex colors, readable on light and dark, distinguishable for common CVD.
    return @(
        '#0072B2',  # blue
        '#E69F00',  # orange
        '#009E73',  # green
        '#CC79A7',  # pink
        '#56B4E9',  # sky blue
        '#D55E00',  # vermilion
        '#F0E442',  # yellow
        '#8C8C8C'   # gray
    )
}

# --- internal helpers (underscore prefix = not part of the public API) ---

function ConvertTo-DomeniaChartBrush {
    param([string]$Hex)
    $b = [System.Windows.Media.Brushes]::Transparent
    # A Color cannot be cast to a Brush: build a frozen SolidColorBrush.
    try { $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Hex)); $b.Freeze() } catch { }
    return $b
}

function New-DomeniaChartText {
    param(
        [string]$Text,
        [double]$Size = 12,
        [switch]$Bold = $false,
        [string]$Key = 'TextColor',
        [double]$MaxWidth = 0
    )
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $t.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::Bold }
    if ($MaxWidth -gt 0) { $t.MaxWidth = $MaxWidth }
    if ($Key) { $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Key) }
    return $t
}

function Get-DomeniaChartTruncated {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return '…' }
    return ($Text.Substring(0, $Max - 1) + '…')
}

function New-DomeniaChartEmpty {
    param([double]$Width, [double]$Height, [string]$Message = 'Aucune donnée')
    $b = New-Object System.Windows.Controls.Border
    $b.Width = $Width
    $b.Height = $Height
    $b.CornerRadius = 10
    $b.Margin = [System.Windows.Thickness]::new(6)
    $b.BorderThickness = 1
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'TileBg')
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BorderColor')
    $b.Child = New-DomeniaChartText -Text $Message -Size 14 -Key 'MutedColor'
    $b.Child.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $b.Child.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    return $b
}

function New-DomeniaChartHeader {
    param([string]$Title, [double]$Width)
    $t = New-DomeniaChartText -Text $Title -Size 14 -Bold -Key 'TextColor'
    $t.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    if ($Width -gt 0) { $t.MaxWidth = $Width }
    return $t
}

function New-DomeniaChartCard {
    param([double]$Width, [double]$Height, [System.Windows.UIElement]$Content)
    $b = New-Object System.Windows.Controls.Border
    $b.Width = $Width
    $b.Height = $Height
    $b.CornerRadius = 10
    $b.Margin = [System.Windows.Thickness]::new(6)
    $b.BorderThickness = 1
    $b.Padding = [System.Windows.Thickness]::new(12)
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'TileBg')
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BorderColor')
    $b.Child = $Content
    return $b
}

# ---------------------------------------------------------------------------
# 1. KPI tile
# ---------------------------------------------------------------------------

function New-DomeniaKpiTile {
    param(
        [string]$Title,
        [string]$Value,
        [string]$Detail,
        [double]$Width = 230,
        [double]$Height = 110
    )
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
    $sp.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    # Every line stays on one line: a long value gets a smaller font, then an ellipsis with the full text as tooltip.
    $length = ([string]$Value).Length
    $valueSize = if ($length -gt 18) { 16 } elseif ($length -gt 12) { 20 } else { 26 }
    foreach ($line in @(@($Title,12,'MutedColor',$false),@($Value,$valueSize,'TextColor',$true),@($Detail,11,'MutedColor',$false))) {
        if ([string]::IsNullOrEmpty([string]$line[0])) { continue }
        $text = New-DomeniaChartText -Text ([string]$line[0]) -Size ([double]$line[1]) -Bold:([bool]$line[3]) -Key ([string]$line[2])
        $text.TextWrapping = [System.Windows.TextWrapping]::NoWrap
        $text.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $text.ToolTip = [string]$line[0]
        if ([bool]$line[3]) { $text.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2) }
        [void]$sp.Children.Add($text)
    }

    return New-DomeniaChartCard -Width $Width -Height $Height -Content $sp
}

# ---------------------------------------------------------------------------
# 2. Donut chart
# ---------------------------------------------------------------------------

function New-DomeniaDonutChart {
    param(
        [string]$Title,
        [object[]]$Items,
        [double]$Width = 340,
        [double]$Height = 240,
        [string]$CenterText = ''
    )
    $valid = @($Items | Where-Object { $_ -and $_.Value -ne $null -and [double]$_.Value -gt 0 })
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height }

    $total = 0.0
    foreach ($it in $valid) { $total += [double]$it.Value }
    if ($total -le 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height }

    $palette = Get-DomeniaChartPalette
    $size = [Math]::Min($Width * 0.42, $Height * 0.82)
    $cx = $size / 2.0
    $cy = $size / 2.0
    $outer = $size / 2.0
    $inner = $outer * 0.62

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $size
    $canvas.Height = $size

    $angle = -90.0
    $colorIndex = 0
    foreach ($it in $valid) {
        $frac = [double]$it.Value / $total
        $sweep = $frac * 360.0
        $brush = ConvertTo-DomeniaChartBrush $palette[$colorIndex % $palette.Count]; $colorIndex++
        $angle += $sweep

        if ($sweep -ge 359.99) {
            # single segment = full ring (two arcs)
            $fig = New-Object System.Windows.Media.PathFigure
            $fig.IsClosed = $true
            $fig.Segments = New-Object System.Windows.Media.PathSegmentCollection
            $p = [System.Windows.Point]::new($cx, $cy - $outer)
            $fig.StartPoint = $p
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                ([System.Windows.Point]::new($cx, $cy + $outer)),
                ([System.Windows.Size]::new($outer, $outer)), 0, $true,
                [System.Windows.Media.SweepDirection]::Clockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                ([System.Windows.Point]::new($cx, $cy - $outer)),
                ([System.Windows.Size]::new($outer, $outer)), 0, $true,
                [System.Windows.Media.SweepDirection]::Clockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                ([System.Windows.Point]::new($cx, $cy - $inner)),
                ([System.Windows.Size]::new($inner, $inner)), 0, $true,
                [System.Windows.Media.SweepDirection]::Counterclockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                ([System.Windows.Point]::new($cx, $cy + $inner)),
                ([System.Windows.Size]::new($inner, $inner)), 0, $true,
                [System.Windows.Media.SweepDirection]::Counterclockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                ([System.Windows.Point]::new($cx, $cy - $inner)),
                ([System.Windows.Size]::new($inner, $inner)), 0, $true,
                [System.Windows.Media.SweepDirection]::Counterclockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                ([System.Windows.Point]::new($cx, $cy - $outer)),
                ([System.Windows.Size]::new($outer, $outer)), 0, $true,
                [System.Windows.Media.SweepDirection]::Counterclockwise, $true)))

            $geo = New-Object System.Windows.Media.PathGeometry
            $geo.Figures = New-Object System.Windows.Media.PathFigureCollection
            $geo.Figures.Add($fig)
            $path = New-Object System.Windows.Shapes.Path
            $path.Data = $geo
            $path.Fill = $brush
            [void]$canvas.Children.Add($path)
        }
        else {
            $a0 = $angle - $sweep
            $a1 = $angle
            $p1 = [System.Windows.Point]::new(
                $cx + $outer * [Math]::Cos($a0 * [Math]::PI / 180.0),
                $cy + $outer * [Math]::Sin($a0 * [Math]::PI / 180.0))
            $p2 = [System.Windows.Point]::new(
                $cx + $outer * [Math]::Cos($a1 * [Math]::PI / 180.0),
                $cy + $outer * [Math]::Sin($a1 * [Math]::PI / 180.0))
            $p3 = [System.Windows.Point]::new(
                $cx + $inner * [Math]::Cos($a1 * [Math]::PI / 180.0),
                $cy + $inner * [Math]::Sin($a1 * [Math]::PI / 180.0))
            $p4 = [System.Windows.Point]::new(
                $cx + $inner * [Math]::Cos($a0 * [Math]::PI / 180.0),
                $cy + $inner * [Math]::Sin($a0 * [Math]::PI / 180.0))
            $large = [bool]($sweep -gt 180.0)

            $fig = New-Object System.Windows.Media.PathFigure
            $fig.IsClosed = $true
            $fig.StartPoint = $p1
            $fig.Segments = New-Object System.Windows.Media.PathSegmentCollection
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                $p2, ([System.Windows.Size]::new($outer, $outer)), 0, $large,
                [System.Windows.Media.SweepDirection]::Clockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.LineSegment]::new($p3, $true)))
            $fig.Segments.Add(([System.Windows.Media.ArcSegment]::new(
                $p4, ([System.Windows.Size]::new($inner, $inner)), 0, $large,
                [System.Windows.Media.SweepDirection]::Counterclockwise, $true)))
            $fig.Segments.Add(([System.Windows.Media.LineSegment]::new($p1, $true)))

            $geo = New-Object System.Windows.Media.PathGeometry
            $geo.Figures = New-Object System.Windows.Media.PathFigureCollection
            $geo.Figures.Add($fig)
            $path = New-Object System.Windows.Shapes.Path
            $path.Data = $geo
            $path.Fill = $brush
            [void]$canvas.Children.Add($path)
        }
    }

    # center text
    if (-not [string]::IsNullOrEmpty($CenterText)) {
        $ct = New-DomeniaChartText -Text $CenterText -Size 16 -Bold -Key 'TextColor'
        $ct.TextAlignment = [System.Windows.TextAlignment]::Center
        $ct.Width = $size
        [void]$canvas.Children.Add($ct)
        [System.Windows.Controls.Canvas]::SetLeft($ct, 0)
        [System.Windows.Controls.Canvas]::SetTop($ct, ($size / 2.0) - 11)
    }

    # legend (right)
    $legend = New-Object System.Windows.Controls.StackPanel
    $legend.Orientation = [System.Windows.Controls.Orientation]::Vertical
    $legend.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $legend.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $i = 0
    foreach ($it in $valid) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)

        $sw = New-Object System.Windows.Shapes.Rectangle
        $sw.Width = 12; $sw.Height = 12; $sw.RadiusX = 2; $sw.RadiusY = 2
        $sw.Fill = ConvertTo-DomeniaChartBrush $palette[$i % $palette.Count]
        $sw.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$row.Children.Add($sw)

        $pct = [Math]::Round(([double]$it.Value / $total) * 100.0, 1)
        $lbl = New-DomeniaChartText -Text ("{0}  {1}%" -f ("" + $it.Label), $pct) -Size 11 -Key 'TextColor'
        $lbl.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        [void]$row.Children.Add($lbl)

        [void]$legend.Children.Add($row)
        $i++
    }

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    [void]$row.Children.Add($canvas)
    [void]$row.Children.Add($legend)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
    [void]$sp.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$sp.Children.Add($row)

    return New-DomeniaChartCard -Width $Width -Height $Height -Content $sp
}

# ---------------------------------------------------------------------------
# 3. Bar chart (horizontal)
# ---------------------------------------------------------------------------

function New-DomeniaBarChart {
    param(
        [string]$Title,
        [object[]]$Items,
        [double]$Width = 380,
        [double]$Height = 260,
        [int]$Top = 10,
        [string]$Unit = ''
    )
    $valid = @($Items | Where-Object { $_ -and $_.Value -ne $null -and [double]$_.Value -gt 0 })
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height }

    $sorted = @($valid | Sort-Object { [double]$_.Value } -Descending)
    if ($Top -gt 0 -and $sorted.Count -gt $Top) { $sorted = @($sorted | Select-Object -First $Top) }

    $palette = Get-DomeniaChartPalette
    $max = 0.0
    foreach ($it in $sorted) { if ([double]$it.Value -gt $max) { $max = [double]$it.Value } }
    if ($max -le 0) { $max = 1.0 }

    $labelW = [Math]::Min(120, $Width * 0.32)
    $valueW = 56
    $barArea = $Width - $labelW - $valueW - 24
    if ($barArea -lt 40) { $barArea = 40 }

    $grid = New-Object System.Windows.Controls.Grid
    $grid.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $i = 0
    foreach ($it in $sorted) {
        [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))

        $lbl = New-DomeniaChartText -Text (Get-DomeniaChartTruncated ("" + $it.Label) 14) -Size 11 -Key 'TextColor'
        $lbl.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $lbl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $lbl.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $lbl.ToolTip = ("" + $it.Label)
        [System.Windows.Controls.Grid]::SetRow($lbl, $i)
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        [void]$grid.Children.Add($lbl)

        $bar = New-Object System.Windows.Shapes.Rectangle
        $bar.Height = 16
        $bar.RadiusX = 3; $bar.RadiusY = 3
        $bar.Width = [Math]::Max(2.0, ($barArea * ([double]$it.Value / $max)))
        $bar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $bar.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $bar.Fill = ConvertTo-DomeniaChartBrush $palette[$i % $palette.Count]
        [System.Windows.Controls.Grid]::SetRow($bar, $i)
        [System.Windows.Controls.Grid]::SetColumn($bar, 1)
        [void]$grid.Children.Add($bar)

        $val = New-DomeniaChartText -Text ("{0}{1}" -f [double]$it.Value, $Unit) -Size 11 -Key 'MutedColor'
        $val.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $val.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $val.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        [System.Windows.Controls.Grid]::SetRow($val, $i)
        [System.Windows.Controls.Grid]::SetColumn($val, 2)
        [void]$grid.Children.Add($val)

        $i++
    }
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $grid.ColumnDefinitions[0].Width = $labelW
    $grid.ColumnDefinitions[1].Width = $barArea
    $grid.ColumnDefinitions[2].Width = $valueW

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
    [void]$sp.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$sp.Children.Add($grid)

    return New-DomeniaChartCard -Width $Width -Height $Height -Content $sp
}

# ---------------------------------------------------------------------------
# 4. Column chart (vertical histogram)
# ---------------------------------------------------------------------------

function New-DomeniaColumnChart {
    param(
        [string]$Title,
        [object[]]$Items,
        [double]$Width = 420,
        [double]$Height = 260
    )
    $valid = @($Items | Where-Object { $_ -and $_.Value -ne $null -and [double]$_.Value -gt 0 })
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height }

    $max = 0.0
    foreach ($it in $valid) { if ([double]$it.Value -gt $max) { $max = [double]$it.Value } }
    if ($max -le 0) { $max = 1.0 }

    # Inner size: card padding/border (26) and header (30) are outside the plot; x labels need 20 px below it.
    $innerW = $Width - 26; $innerH = $Height - 56
    $plotH = $innerH - 36
    $plotW = $innerW - 40
    if ($plotW -lt 40) { $plotW = 40 }
    if ($plotH -lt 40) { $plotH = 40 }

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $innerW
    $canvas.Height = $innerH

    # Y axis + max label
    $axis = New-Object System.Windows.Shapes.Line
    $axis.X1 = 30; $axis.Y1 = 12
    $axis.X2 = 30; $axis.Y2 = 12 + $plotH
    $axis.StrokeThickness = 1
    $axis.SetResourceReference([System.Windows.Shapes.Line]::StrokeProperty, 'BorderColor')
    [void]$canvas.Children.Add($axis)

    $maxLbl = New-DomeniaChartText -Text ("" + [Math]::Round($max, 1)) -Size 10 -Key 'MutedColor'
    [System.Windows.Controls.Canvas]::SetLeft($maxLbl, 0)
    [System.Windows.Controls.Canvas]::SetTop($maxLbl, 6)
    [void]$canvas.Children.Add($maxLbl)

    # X axis
    $xaxis = New-Object System.Windows.Shapes.Line
    $xaxis.X1 = 30; $xaxis.Y1 = 12 + $plotH
    $xaxis.X2 = 30 + $plotW; $xaxis.Y2 = 12 + $plotH
    $xaxis.StrokeThickness = 1
    $xaxis.SetResourceReference([System.Windows.Shapes.Line]::StrokeProperty, 'BorderColor')
    [void]$canvas.Children.Add($xaxis)

    $n = $valid.Count
    $slot = $plotW / $n
    $barW = $slot * 0.6
    $skip = 1
    if ($n -gt 8) { $skip = 2 }

    $i = 0
    foreach ($it in $valid) {
        $h = $plotH * ([double]$it.Value / $max)
        $x = 30 + $slot * $i + ($slot - $barW) / 2.0
        $y = 12 + $plotH - $h

        $bar = New-Object System.Windows.Shapes.Rectangle
        $bar.Width = $barW
        $bar.Height = [Math]::Max(1.0, $h)
        $bar.Fill = [System.Windows.Media.Brushes]::Transparent
        $bar.SetResourceReference([System.Windows.Shapes.Rectangle]::FillProperty, 'AccentColor')
        [System.Windows.Controls.Canvas]::SetLeft($bar, $x)
        [System.Windows.Controls.Canvas]::SetTop($bar, $y)
        [void]$canvas.Children.Add($bar)

        if (($i % $skip) -eq 0) {
            $lbl = New-DomeniaChartText -Text (Get-DomeniaChartTruncated ("" + $it.Label) 8) -Size 9 -Key 'MutedColor'
            [System.Windows.Controls.Canvas]::SetLeft($lbl, $x - 4)
            [System.Windows.Controls.Canvas]::SetTop($lbl, 12 + $plotH + 4)
            [void]$canvas.Children.Add($lbl)
        }
        $i++
    }

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
    [void]$sp.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$sp.Children.Add($canvas)

    return New-DomeniaChartCard -Width $Width -Height $Height -Content $sp
}

# ---------------------------------------------------------------------------
# 5. Line chart (polyline + filled area)
# ---------------------------------------------------------------------------

function New-DomeniaLineChart {
    param(
        [string]$Title,
        [object[]]$Points,
        [double]$Width = 420,
        [double]$Height = 260
    )
    $valid = @($Points | Where-Object { $_ -and $_.Value -ne $null -and [double]$_.Value -gt 0 })
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height }

    $max = 0.0
    foreach ($p in $valid) { if ([double]$p.Value -gt $max) { $max = [double]$p.Value } }
    if ($max -le 0) { $max = 1.0 }

    # Inner size: card padding/border (26) and header (30) are outside the plot; x labels need 20 px below it.
    $innerW = $Width - 26; $innerH = $Height - 56
    $plotH = $innerH - 36
    $plotW = $innerW - 40
    if ($plotW -lt 40) { $plotW = 40 }
    if ($plotH -lt 40) { $plotH = 40 }

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $innerW
    $canvas.Height = $innerH

    # axes
    $axis = New-Object System.Windows.Shapes.Line
    $axis.X1 = 30; $axis.Y1 = 12
    $axis.X2 = 30; $axis.Y2 = 12 + $plotH
    $axis.StrokeThickness = 1
    $axis.SetResourceReference([System.Windows.Shapes.Line]::StrokeProperty, 'BorderColor')
    [void]$canvas.Children.Add($axis)

    $xaxis = New-Object System.Windows.Shapes.Line
    $xaxis.X1 = 30; $xaxis.Y1 = 12 + $plotH
    $xaxis.X2 = 30 + $plotW; $xaxis.Y2 = 12 + $plotH
    $xaxis.StrokeThickness = 1
    $xaxis.SetResourceReference([System.Windows.Shapes.Line]::StrokeProperty, 'BorderColor')
    [void]$canvas.Children.Add($xaxis)

    $maxLbl = New-DomeniaChartText -Text ("" + [Math]::Round($max, 1)) -Size 10 -Key 'MutedColor'
    [System.Windows.Controls.Canvas]::SetLeft($maxLbl, 0)
    [System.Windows.Controls.Canvas]::SetTop($maxLbl, 6)
    [void]$canvas.Children.Add($maxLbl)

    $n = $valid.Count
    $step = if ($n -gt 1) { $plotW / ($n - 1) } else { 0 }

    $pts = New-Object System.Windows.Media.PointCollection
    $i = 0
    foreach ($p in $valid) {
        $x = 30 + $step * $i
        $y = 12 + $plotH - ($plotH * ([double]$p.Value / $max))
        $pts.Add(([System.Windows.Point]::new($x, $y)))

        # markers
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 6; $dot.Height = 6
        $dot.Fill = [System.Windows.Media.Brushes]::Transparent
        $dot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, 'AccentColor')
        [System.Windows.Controls.Canvas]::SetLeft($dot, $x - 3)
        [System.Windows.Controls.Canvas]::SetTop($dot, $y - 3)
        [void]$canvas.Children.Add($dot)

        if ($n -le 12 -or ($i % 2) -eq 0) {
            $lbl = New-DomeniaChartText -Text (Get-DomeniaChartTruncated ("" + $p.Label) 6) -Size 9 -Key 'MutedColor'
            [System.Windows.Controls.Canvas]::SetLeft($lbl, $x - 12)
            [System.Windows.Controls.Canvas]::SetTop($lbl, 12 + $plotH + 4)
            [void]$canvas.Children.Add($lbl)
        }
        $i++
    }

    # filled area under curve (close to baseline)
    $areaPts = New-Object System.Windows.Media.PointCollection
    foreach ($pt in $pts) { $areaPts.Add($pt) }
    $areaPts.Add(([System.Windows.Point]::new(30 + $step * ($n - 1), 12 + $plotH)))
    $areaPts.Add(([System.Windows.Point]::new(30, 12 + $plotH)))

    $area = New-Object System.Windows.Shapes.Polygon
    $area.Points = $areaPts
    $area.Fill = [System.Windows.Media.Brushes]::Transparent
    $area.SetResourceReference([System.Windows.Shapes.Polygon]::FillProperty, 'AccentColor')
    $area.Opacity = 0.25
    [void]$canvas.Children.Add($area)

    # line
    $line = New-Object System.Windows.Shapes.Polyline
    $line.Points = $pts
    $line.StrokeThickness = 2
    $line.Stroke = [System.Windows.Media.Brushes]::Transparent
    $line.SetResourceReference([System.Windows.Shapes.Polyline]::StrokeProperty, 'AccentColor')
    [void]$canvas.Children.Add($line)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
    [void]$sp.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$sp.Children.Add($canvas)

    return New-DomeniaChartCard -Width $Width -Height $Height -Content $sp
}

# ---------------------------------------------------------------------------
# 6. Gauge (semicircle)
# ---------------------------------------------------------------------------

function New-DomeniaGauge {
    param(
        [string]$Title,
        [double]$Value,
        [double]$Maximum = 100,
        [double]$Width = 240,
        [double]$Height = 180,
        [string]$Unit = '',
        [switch]$LowIsBad
    )
    if ($Maximum -le 0) { $Maximum = 100 }
    $pct = $Value / $Maximum
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 1) { $pct = 1 }

    $size = [Math]::Min($Width * 0.7, $Height * 0.9)
    $cx = $size / 2.0
    $cy = $size * 0.55
    $r = $size * 0.42
    $trackW = $r * 0.28

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $size
    $canvas.Height = $size * 0.75

    # track (full semicircle)
    $track = New-Object System.Windows.Shapes.Path
    $track.StrokeThickness = $trackW
    $track.Stroke = [System.Windows.Media.Brushes]::Transparent
    $track.SetResourceReference([System.Windows.Shapes.Path]::StrokeProperty, 'BorderColor')
    $track.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
    $track.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    $track.Data = ([System.Windows.Media.Geometry]::Parse([string]::Format([Globalization.CultureInfo]::InvariantCulture, "M {0} {1} A {2} {2} 0 0 1 {3} {1}", ($cx - $r), $cy, $r, ($cx + $r))))
    [void]$canvas.Children.Add($track)

    # value arc
    $endX = $cx + $r * [Math]::Cos([Math]::PI * (1 - $pct))
    $endY = $cy - $r * [Math]::Sin([Math]::PI * (1 - $pct))
    $large = [bool]($pct -gt 0.5)

    $valArc = New-Object System.Windows.Shapes.Path
    $valArc.StrokeThickness = $trackW
    $valArc.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
    $valArc.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    # High is bad by default (memory, processor); -LowIsBad reverses it (battery).
    $alert = if ($LowIsBad) { 1 - $pct } else { $pct }
    if ($alert -gt 0.9) { $valArc.Stroke = ConvertTo-DomeniaChartBrush '#D55E00' }
    elseif ($alert -gt 0.8) { $valArc.Stroke = ConvertTo-DomeniaChartBrush '#E69F00' }
    else { $valArc.Stroke = [System.Windows.Media.Brushes]::Transparent; $valArc.SetResourceReference([System.Windows.Shapes.Path]::StrokeProperty, 'AccentColor') }
    $valArc.Data = ([System.Windows.Media.Geometry]::Parse([string]::Format([Globalization.CultureInfo]::InvariantCulture, "M {0} {1} A {2} {2} 0 0 1 {3} {4}", ($cx - $r), $cy, $r, $endX, $endY)))
    [void]$canvas.Children.Add($valArc)

    # center value
    $cv = New-DomeniaChartText -Text ("{0:0.#} {1}" -f $Value, $Unit).Trim() -Size 20 -Bold -Key 'TextColor'
    $cv.TextAlignment = [System.Windows.TextAlignment]::Center
    $cv.Width = $size
    [void]$canvas.Children.Add($cv)
    [System.Windows.Controls.Canvas]::SetTop($cv, $cy - 26)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
    [void]$sp.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$sp.Children.Add($canvas)

    return New-DomeniaChartCard -Width $Width -Height $Height -Content $sp
}
