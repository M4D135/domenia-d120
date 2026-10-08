# WPF charts drawn with native shapes (no external library), themed through DynamicResource keys.
# Redesign 2026-10-07 (David : "souci du detail, user experience first") : white cards on a soft canvas with a
# layered shadow, rings drawn as stroked arcs, linked hover between rings and legends, and an entrance motion
# (fade, rise, drawing, counting) that follows the Windows animation setting.
# Every builder returns a ready-to-insert FrameworkElement. Event handlers use their sender's Tag, never
# GetNewClosure, so they can call the application functions.

# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------
$script:DomeniaChartDisplayFont = 'Segoe UI Variable Display, Segoe UI'
$script:DomeniaChartIconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$script:DomeniaChartRadius = 14
$script:DomeniaIntro = New-Object System.Collections.ArrayList
$script:DomeniaIntroTimer = $null
$script:DomeniaCounting = New-Object System.Collections.ArrayList
$script:DomeniaEntranceHooked = @{}
$script:DomeniaEntrancePending = @{}

function Get-DomeniaChartPalette {
    # Eight pastel categorical colours (decision David 2026-10-07), distinct on light and dark backgrounds.
    return @('#93C5FD','#FCD34D','#86EFAC','#C4B5FD','#F9A8D4','#5EEAD4','#FDBA74','#CBD5E1')
}
function Get-DomeniaStateColor {
    # Pastel meaning colours for shapes (rings, bars, tints).
    param([string]$State)
    return (Get-DomeniaBoardColor $State)
}
function Get-DomeniaStateDotColor {
    # Small marks (dots, icons) need a little more contrast than the pastel shapes.
    param([string]$State)
    switch ($State) { 'Ok' { return '#4ADE80' } 'Warn' { return '#FBBF24' } 'Alert' { return '#F87171' } 'Off' { return '#94A3B8' } 'Info' { return '#60A5FA' } default { return '' } }
}
function Get-DomeniaStateTextKey {
    # Text in a state colour comes from the theme palettes (contrast checked for light and dark).
    param([string]$State)
    switch ($State) { 'Ok' { return 'StatusSuccess' } 'Warn' { return 'StatusWarning' } 'Alert' { return 'StatusError' } default { return 'TextColor' } }
}
function ConvertTo-DomeniaChartBrush {
    param([string]$Hex,[double]$Opacity = 1)
    $b = [System.Windows.Media.Brushes]::Transparent
    try {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
        if ($Opacity -lt 1) { $b.Opacity = $Opacity }
        $b.Freeze()
    } catch { }
    return $b
}
function Format-DomeniaChartNumber {
    # 12 345 ; 3,4 ; no trailing ,0.
    param($Value)
    $number = 0.0
    if (-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { try { $number = [double]$Value } catch { return [string]$Value } }
    return $number.ToString('#,0.#',[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))
}

function New-DomeniaChartText {
    param(
        [string]$Text,
        [double]$Size = 12,
        [switch]$Bold = $false,
        [string]$Key = 'TextColor',
        [double]$MaxWidth = 0,
        [ValidateSet('','Normal','Medium','SemiBold','Bold')][string]$Weight = '',
        [switch]$Display,
        [switch]$OneLine
    )
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $t.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    if ($Bold -and -not $Weight) { $Weight = 'SemiBold' }
    if ($Weight) { $t.FontWeight = [System.Windows.FontWeight](New-Object System.Windows.FontWeightConverter).ConvertFromString($Weight) }
    if ($Display) { $t.FontFamily = [System.Windows.Media.FontFamily]::new($script:DomeniaChartDisplayFont) }
    if ($OneLine) { $t.TextWrapping = [System.Windows.TextWrapping]::NoWrap; $t.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis; if ($Text) { $t.ToolTip = $Text } }
    if ($MaxWidth -gt 0) { $t.MaxWidth = $MaxWidth }
    if ($Key -like '#*') { $t.Foreground = ConvertTo-DomeniaChartBrush $Key }
    elseif ($Key) { $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Key) }
    return $t
}
function New-DomeniaChartIcon {
    # Segoe Fluent / MDL2 glyph in a soft tinted circle.
    param([string]$Glyph,[string]$Hex,[double]$Size = 22)
    $circle = New-Object System.Windows.Controls.Border
    $circle.Width = $Size; $circle.Height = $Size
    $circle.CornerRadius = [System.Windows.CornerRadius]::new($Size / 2)
    $circle.Background = ConvertTo-DomeniaChartBrush $Hex 0.14
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = $Glyph
    $icon.FontFamily = [System.Windows.Media.FontFamily]::new($script:DomeniaChartIconFont)
    $icon.FontSize = [Math]::Round($Size * 0.5)
    $icon.Foreground = ConvertTo-DomeniaChartBrush $Hex
    $icon.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $circle.Child = $icon
    return $circle
}
function Get-DomeniaChartTruncated {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return [string][char]0x2026 }
    return ($Text.Substring(0, $Max - 1) + [char]0x2026)
}
function Get-DomeniaChartItemColor {
    # An item may carry its own meaning colour (Color = '#RRGGBB'): free space, presence, service state...
    param($Item,[string[]]$Palette,[int]$Index)
    if ($null -ne $Item -and $null -ne $Item.PSObject.Properties['Color'] -and [string]$Item.Color -match '^#[0-9A-Fa-f]{6}$') { return [string]$Item.Color }
    return $Palette[$Index % $Palette.Count]
}

# ---------------------------------------------------------------------------
# Motion
# ---------------------------------------------------------------------------
function Test-DomeniaMotion {
    # Off when Windows animations are disabled (accessibility, remote session) or for static captures.
    if ($script:DomeniaReduceMotion) { return $false }
    try { return [bool][System.Windows.SystemParameters]::ClientAreaAnimation } catch { return $true }
}
function New-DomeniaChartEase {
    param([string]$Kind = 'Quint')
    $ease = if ($Kind -eq 'Back') { $b = [System.Windows.Media.Animation.BackEase]::new(); $b.Amplitude = 0.35; $b } else { [System.Windows.Media.Animation.QuinticEase]::new() }
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    return $ease
}
function Start-DomeniaTween {
    # From -> To after DelayMs; the value is held at From during the delay, then returns to the base value
    # (which must be the final one) when the animation stops.
    param($Target,$Property,[double]$From,[double]$To,[double]$Ms = 480,[double]$DelayMs = 0,[string]$Ease = 'Quint')
    if ($null -eq $Target -or $null -eq $Property) { return }
    $a = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
    [void]$a.KeyFrames.Add([System.Windows.Media.Animation.DiscreteDoubleKeyFrame]::new($From,[System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))
    if ($DelayMs -gt 0) { [void]$a.KeyFrames.Add([System.Windows.Media.Animation.DiscreteDoubleKeyFrame]::new($From,[System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($DelayMs)))) }
    $k = [System.Windows.Media.Animation.EasingDoubleKeyFrame]::new($To,[System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($DelayMs + $Ms)))
    $k.EasingFunction = New-DomeniaChartEase $Ease
    [void]$a.KeyFrames.Add($k)
    $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $Target.BeginAnimation($Property,$a)
}
function Set-DomeniaHoverValue {
    # Hover feedback: animated when motion is on, immediate otherwise.
    param($Target,$Property,[double]$To,[double]$Ms = 170)
    if ($null -eq $Target) { return }
    if (-not (Test-DomeniaMotion)) { $Target.BeginAnimation($Property,$null); $Target.SetValue($Property,[double]$To); return }
    $a = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $a.To = $To
    $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
    $a.EasingFunction = New-DomeniaChartEase
    $Target.BeginAnimation($Property,$a)
}
function Register-DomeniaIntro {
    # A drawing step played when its dashboard appears: Visual locates the card, Target is animated.
    param($Visual,$Target,$Property,[double]$From,[double]$To,[double]$Ms = 700,[double]$DelayMs = 0,[string]$Ease = 'Quint')
    if (-not (Test-DomeniaMotion)) { return }
    [void]$script:DomeniaIntro.Add([pscustomobject]@{ Visual = $Visual; Target = $Target; Property = $Property; From = $From; To = $To; Ms = $Ms; Delay = $DelayMs; Ease = $Ease; Count = $null })
}
function Register-DomeniaCountUp {
    # Leading integer of a text counted from zero ("128 postes", "62 %").
    param([System.Windows.Controls.TextBlock]$Text)
    if ($null -eq $Text -or -not (Test-DomeniaMotion)) { return }
    if ([string]$Text.Text -notmatch '^(\d{1,7})(\s+\D.*)?$') { return }
    $target = [int]$Matches[1]
    if ($target -lt 2) { return }
    [void]$script:DomeniaIntro.Add([pscustomobject]@{ Visual = $Text; Target = $null; Property = $null; From = 0; To = $target; Ms = 900; Delay = 0; Ease = ''; Count = [pscustomobject]@{ Text = $Text; Suffix = [string]$Matches[2]; Final = [string]$Text.Text } })
}
function Start-DomeniaCountTimer {
    if ($null -eq $script:DomeniaIntroTimer) {
        # Normal priority: at Background the ticks can starve behind the rendering of the entrance animations.
        $script:DomeniaIntroTimer = New-Object System.Windows.Threading.DispatcherTimer ([System.Windows.Threading.DispatcherPriority]::Normal)
        $script:DomeniaIntroTimer.Interval = [TimeSpan]::FromMilliseconds(16)
        $script:DomeniaIntroTimer.Add_Tick({
            $now = [DateTime]::UtcNow
            $left = 0
            foreach ($item in @($script:DomeniaCounting)) {
                $elapsed = ($now - $item.Start).TotalMilliseconds
                if ($elapsed -lt 0) { $left++; continue }
                $t = [Math]::Min(1.0, $elapsed / $item.Ms)
                if ($t -ge 1.0) { $item.Count.Text.Text = $item.Count.Final; [void]$script:DomeniaCounting.Remove($item); continue }
                $eased = 1.0 - [Math]::Pow(1.0 - $t, 4)
                $item.Count.Text.Text = ([string][int][Math]::Round($item.To * $eased)) + $item.Count.Suffix
                $left++
            }
            if (-not $left) { $script:DomeniaIntroTimer.Stop() }
        })
    }
    if (-not $script:DomeniaIntroTimer.IsEnabled) { $script:DomeniaIntroTimer.Start() }
}
function Add-DomeniaDashboardCards {
    # Cards of a dashboard in reading order (sections, then their tiles).
    param($Node,$Into)
    if ($Node -isnot [System.Windows.Controls.Panel]) { return }
    foreach ($child in @($Node.Children)) {
        if ($child -is [System.Windows.FrameworkElement] -and [string]$child.Uid -eq 'DomeniaCard') { [void]$Into.Add($child) }
        else { Add-DomeniaDashboardCards $child $Into }
    }
}
function Invoke-DomeniaDashboardEntrance {
    # Cards rise and fade in one after another, then rings and bars draw and figures count.
    # A dashboard built while hidden plays its entrance the first time it is shown.
    param([System.Windows.FrameworkElement]$Panel)
    if ($null -eq $Panel) { return }
    $stale = @($script:DomeniaIntro | Where-Object { $null -eq [System.Windows.Window]::GetWindow($_.Visual) -and -not $Panel.IsAncestorOf($_.Visual) })
    foreach ($item in $stale) { [void]$script:DomeniaIntro.Remove($item) }
    if (-not (Test-DomeniaMotion)) { $script:DomeniaIntro.Clear(); return }
    $key = [string]$Panel.Name; if (-not $key) { $key = [string]$Panel.GetHashCode() }
    if (-not $Panel.IsVisible) {
        $script:DomeniaEntrancePending[$key] = $true
        if (-not $script:DomeniaEntranceHooked.ContainsKey($key)) {
            $script:DomeniaEntranceHooked[$key] = $true
            $Panel.Add_IsVisibleChanged({
                param($s,$e)
                $name = [string]$s.Name; if (-not $name) { $name = [string]$s.GetHashCode() }
                if ($s.IsVisible -and $script:DomeniaEntrancePending[$name]) { $script:DomeniaEntrancePending[$name] = $false; Invoke-DomeniaDashboardEntrance -Panel $s }
            })
        }
        return
    }
    $script:DomeniaEntrancePending[$key] = $false
    $cards = New-Object System.Collections.ArrayList
    Add-DomeniaDashboardCards $Panel $cards
    $index = 0
    $start = [DateTime]::UtcNow
    foreach ($card in $cards) {
        $delay = [Math]::Min(520.0, 38.0 * $index)
        $index++
        Start-DomeniaTween $card ([System.Windows.UIElement]::OpacityProperty) 0 1 420 $delay
        if ($card.RenderTransform -is [System.Windows.Media.TranslateTransform] -and -not $card.RenderTransform.IsFrozen) { Start-DomeniaTween $card.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) 14 0 520 $delay }
        foreach ($item in @($script:DomeniaIntro | Where-Object { $card -eq $_.Visual -or $card.IsAncestorOf($_.Visual) })) {
            [void]$script:DomeniaIntro.Remove($item)
            if ($null -ne $item.Count) {
                $item.Count.Text.Text = '0' + $item.Count.Suffix
                [void]$script:DomeniaCounting.Add([pscustomobject]@{ Count = $item.Count; To = $item.To; Ms = $item.Ms; Start = $start.AddMilliseconds($delay + 140) })
                continue
            }
            Start-DomeniaTween $item.Target $item.Property $item.From $item.To $item.Ms ($delay + 160 + $item.Delay) $item.Ease
        }
    }
    if ($script:DomeniaCounting.Count) { Start-DomeniaCountTimer }
}

# ---------------------------------------------------------------------------
# Card
# ---------------------------------------------------------------------------
function New-DomeniaChartCard {
    # Surface with a soft shadow (on its own layer, so the text keeps ClearType), hairline border, optional state tint.
    # Height 0 = fits its content.
    param([double]$Width, [double]$Height, [System.Windows.UIElement]$Content, [ValidateSet('','Ok','Warn','Alert','Off')][string]$State = '', [switch]$Static, [double]$MinHeight = 0)
    $radius = [System.Windows.CornerRadius]::new($script:DomeniaChartRadius)
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Uid = 'DomeniaCard'
    $grid.Width = $Width
    if ($Height -gt 0) { $grid.Height = $Height } elseif ($MinHeight -gt 0) { $grid.MinHeight = $MinHeight }
    $grid.Margin = [System.Windows.Thickness]::new(7)
    $grid.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $grid.SnapsToDevicePixels = $true

    $surface = New-Object System.Windows.Controls.Border
    $surface.CornerRadius = $radius
    $surface.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'BgCard')
    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.Color = [System.Windows.Media.Color]::FromRgb(15, 23, 42)
    $shadow.Direction = 270; $shadow.ShadowDepth = 2; $shadow.BlurRadius = 14; $shadow.Opacity = 0.07
    $shadow.RenderingBias = [System.Windows.Media.Effects.RenderingBias]::Performance
    $surface.Effect = $shadow
    [void]$grid.Children.Add($surface)

    $color = Get-DomeniaStateColor $State
    if ($color -and $State -in @('Warn','Alert')) {
        $tint = New-Object System.Windows.Controls.Border
        $tint.CornerRadius = $radius
        $tint.Background = ConvertTo-DomeniaChartBrush (Get-DomeniaStateDotColor $State) 0.07
        [void]$grid.Children.Add($tint)
    }
    $stroke = New-Object System.Windows.Controls.Border
    $stroke.CornerRadius = $radius
    $stroke.BorderThickness = [System.Windows.Thickness]::new(1)
    if ($color -and $State -in @('Warn','Alert')) { $stroke.BorderBrush = ConvertTo-DomeniaChartBrush (Get-DomeniaStateDotColor $State) 0.45 }
    else { $stroke.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BorderColor'); $stroke.Opacity = 0.75 }
    [void]$grid.Children.Add($stroke)

    $body = New-Object System.Windows.Controls.Border
    $body.Padding = [System.Windows.Thickness]::new(16, 14, 16, 14)
    $body.Child = $Content
    [void]$grid.Children.Add($body)

    $shift = New-Object System.Windows.Media.TranslateTransform
    $grid.RenderTransform = $shift
    if (-not $Static) {
        $grid.Tag = @{ Shadow = $shadow; Shift = $shift }
        $grid.Add_MouseEnter({
            param($s,$e)
            $parts = $s.Tag; if ($parts -isnot [hashtable] -or $null -eq $parts.Shadow) { return }
            Set-DomeniaHoverValue $parts.Shift ([System.Windows.Media.TranslateTransform]::YProperty) -2
            Set-DomeniaHoverValue $parts.Shadow ([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 26
            Set-DomeniaHoverValue $parts.Shadow ([System.Windows.Media.Effects.DropShadowEffect]::ShadowDepthProperty) 6
            Set-DomeniaHoverValue $parts.Shadow ([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty) 0.13
        })
        $grid.Add_MouseLeave({
            param($s,$e)
            $parts = $s.Tag; if ($parts -isnot [hashtable] -or $null -eq $parts.Shadow) { return }
            Set-DomeniaHoverValue $parts.Shift ([System.Windows.Media.TranslateTransform]::YProperty) 0 240
            Set-DomeniaHoverValue $parts.Shadow ([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 14 240
            Set-DomeniaHoverValue $parts.Shadow ([System.Windows.Media.Effects.DropShadowEffect]::ShadowDepthProperty) 2 240
            Set-DomeniaHoverValue $parts.Shadow ([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty) 0.07 240
        })
    }
    return $grid
}
function New-DomeniaChartHeader {
    param([string]$Title, [double]$Width, [string]$Subtitle = '')
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $t = New-DomeniaChartText -Text $Title -Size 13.5 -Weight SemiBold -Key 'TextColor' -OneLine
    if ($Width -gt 0) { $t.MaxWidth = [Math]::Max(40, $Width - 40) }
    [void]$stack.Children.Add($t)
    if ($Subtitle) { $sub = New-DomeniaChartText -Text $Subtitle -Size 11.5 -Key 'MutedColor' -OneLine; $sub.Margin = [System.Windows.Thickness]::new(0, 1, 0, 0); [void]$stack.Children.Add($sub) }
    return $stack
}
function New-DomeniaChartEmpty {
    param([double]$Width, [double]$Height, [string]$Message = 'Aucune donnee pour le moment', [string]$Title = '')
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $stack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $icon = New-DomeniaChartIcon ([string][char]0xE9D2) '#94A3B8' 34
    $icon.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$stack.Children.Add($icon)
    if ($Title) { $head = New-DomeniaChartText -Text $Title -Size 13 -Weight SemiBold -Key 'TextColor'; $head.TextAlignment = [System.Windows.TextAlignment]::Center; $head.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; [void]$stack.Children.Add($head) }
    $text = New-DomeniaChartText -Text $Message -Size 12 -Key 'MutedColor'
    $text.TextAlignment = [System.Windows.TextAlignment]::Center
    $text.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $text.MaxWidth = [Math]::Max(80, $Width - 48)
    [void]$stack.Children.Add($text)
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $stack -Static
}

# ---------------------------------------------------------------------------
# 1. KPI tile and attention list
# ---------------------------------------------------------------------------
function New-DomeniaKpiTile {
    param(
        [string]$Title,
        [string]$Value,
        [string]$Detail,
        [double]$Width = 230,
        [double]$Height = 118,
        [ValidateSet('','Ok','Warn','Alert','Off')][string]$State = ''
    )
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($h in @('Auto','*','Auto')) { $row = New-Object System.Windows.Controls.RowDefinition; $row.Height = [System.Windows.GridLength](New-Object System.Windows.GridLengthConverter).ConvertFromString($h); [void]$grid.RowDefinitions.Add($row) }

    $head = New-Object System.Windows.Controls.DockPanel
    if ($State) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7
        $dot.Margin = [System.Windows.Thickness]::new(0, 1, 7, 0)
        $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $dot.Fill = ConvertTo-DomeniaChartBrush (Get-DomeniaStateDotColor $State)
        [void]$head.Children.Add($dot)
    }
    [void]$head.Children.Add((New-DomeniaChartText -Text $Title -Size 12 -Weight Medium -Key 'MutedColor' -OneLine))
    [void]$grid.Children.Add($head)

    # One line each: a long value gets a smaller font, then an ellipsis with the full text as tooltip.
    $length = ([string]$Value).Length
    $valueSize = if ($length -gt 22) { 15 } elseif ($length -gt 16) { 18 } elseif ($length -gt 11) { 21 } else { 27 }
    $valueKey = if ($State -in @('Warn','Alert')) { Get-DomeniaStateTextKey $State } else { 'TextColor' }
    $valueText = New-DomeniaChartText -Text $Value -Size $valueSize -Weight SemiBold -Key $valueKey -Display -OneLine
    $valueText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $valueText.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($valueText, 1)
    [void]$grid.Children.Add($valueText)
    Register-DomeniaCountUp $valueText

    if ($Detail) {
        $detailText = New-DomeniaChartText -Text $Detail -Size 11.5 -Key 'MutedColor' -OneLine
        [System.Windows.Controls.Grid]::SetRow($detailText, 2)
        [void]$grid.Children.Add($detailText)
    }
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $grid -State $State
}
function New-DomeniaRowButton {
    # Flat button holding a whole line (click and keyboard), highlighted on hover and on focus.
    param($Content,[string]$Name)
    $xaml = @'
<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" HorizontalContentAlignment="Stretch" HorizontalAlignment="Stretch" Cursor="Hand" Padding="0">
  <Button.Template>
    <ControlTemplate TargetType="Button">
      <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="6"><ContentPresenter/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentColor}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Button.Template>
</Button>
'@
    $button = [Windows.Markup.XamlReader]::Parse($xaml)
    $button.Content = $Content
    [System.Windows.Automation.AutomationProperties]::SetName($button, $Name)
    return $button
}
function New-DomeniaAttentionCard {
    # Points requiring attention, most serious first; a single reassuring line when nothing is wrong.
    # Fleet: a point naming its workstations unfolds them on click (Switch-DomeniaAttentionDetails), from the data in
    # memory. Workstation: a point naming a route offers a link to the workspace of the useful action, running nothing.
    param([string]$Title = 'Points d attention',[object[]]$Items = @(),[double]$Width = 460,[double]$MinHeight = 0,[int]$Max = 9,[string]$Board = '')
    $panel = New-Object System.Windows.Controls.StackPanel
    $ordered = @(@($Items | Where-Object { $_.Level -eq 'Alert' }) + @($Items | Where-Object { $_.Level -eq 'Warn' }) + @($Items | Where-Object { $_.Level -notin @('Alert','Warn') }))
    $alerts = @($Items | Where-Object { $_.Level -eq 'Alert' }).Count
    $warnings = @($Items | Where-Object { $_.Level -eq 'Warn' }).Count

    $head = New-Object System.Windows.Controls.DockPanel
    $head.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $badgeState = if ($alerts) { 'Alert' } elseif ($warnings) { 'Warn' } else { 'Ok' }
    $glyph = if ($alerts) { [string][char]0xEA39 } elseif ($warnings) { [string][char]0xE7BA } else { [string][char]0xE73E }
    $badge = New-DomeniaChartIcon $glyph (Get-DomeniaStateDotColor $badgeState) 30
    $badge.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    [void]$head.Children.Add($badge)
    $titles = New-Object System.Windows.Controls.StackPanel
    $titles.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$titles.Children.Add((New-DomeniaChartText -Text $Title -Size 14.5 -Weight SemiBold -Key 'TextColor' -Display -OneLine))
    $summary = if (-not ($alerts + $warnings)) { $(if ($ordered.Count) { 'Rien d urgent · ' + $ordered.Count + ' information(s)' } else { 'Toutes les verifications sont au vert.' }) } else { @($(if ($alerts) { [string]$alerts + ' critique(s)' }), $(if ($warnings) { [string]$warnings + ' a surveiller' })) -join ' · ' }
    [void]$titles.Children.Add((New-DomeniaChartText -Text $summary.Trim(' ','·') -Size 11.5 -Key 'MutedColor' -OneLine))
    [void]$head.Children.Add($titles)
    [void]$panel.Children.Add($head)

    $shown = 0
    foreach ($item in ($ordered | Select-Object -First $Max)) {
        $level = [string]$item.Level
        $line = New-Object System.Windows.Controls.Border
        $line.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
        $line.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BorderColor')
        $line.Padding = [System.Windows.Thickness]::new(0, 7, 0, 7)
        $row = New-Object System.Windows.Controls.DockPanel
        $mark = New-Object System.Windows.Controls.TextBlock
        $mark.Text = if ($level -eq 'Alert') { [string][char]0xEA39 } elseif ($level -eq 'Warn') { [string][char]0xE7BA } else { [string][char]0xE946 }
        $mark.FontFamily = [System.Windows.Media.FontFamily]::new($script:DomeniaChartIconFont)
        $mark.FontSize = 13
        $mark.Width = 22
        $mark.Margin = [System.Windows.Thickness]::new(4, 1, 6, 0)
        $mark.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
        $mark.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($level -in @('Alert','Warn')) { Get-DomeniaStateTextKey $level } else { 'AccentText' }))
        [void]$row.Children.Add($mark)
        $groupsProperty = $item.PSObject.Properties['Groups']; $machinesProperty = $item.PSObject.Properties['Machines']; $routeProperty = $item.PSObject.Properties['Route']
        $hasTargets = ((($null -ne $groupsProperty) -and (@($groupsProperty.Value).Count -gt 0)) -or (($null -ne $machinesProperty) -and (@($machinesProperty.Value).Count -gt 0)))
        $route = if ($null -ne $routeProperty) { [string]$routeProperty.Value } else { '' }
        if ($hasTargets -and ($Board -eq 'Fleet')) {
            $chevron = New-Object System.Windows.Controls.TextBlock
            $chevron.Text = [string][char]0xE70D
            $chevron.FontFamily = [System.Windows.Media.FontFamily]::new($script:DomeniaChartIconFont)
            $chevron.FontSize = 10; $chevron.Margin = [System.Windows.Thickness]::new(8, 3, 4, 0); $chevron.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
            $chevron.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'MutedColor')
            [System.Windows.Controls.DockPanel]::SetDock($chevron, [System.Windows.Controls.Dock]::Right)
            $row.Children.Insert(0, $chevron)
            [void]$row.Children.Add((New-DomeniaChartText -Text ([string]$item.Text) -Size 12.5 -Key 'TextColor'))
            $holder = New-Object System.Windows.Controls.StackPanel
            $details = New-Object System.Windows.Controls.StackPanel
            $details.Visibility = [System.Windows.Visibility]::Collapsed
            $details.Margin = [System.Windows.Thickness]::new(32, 4, 0, 2)
            $button = New-DomeniaRowButton -Content $row -Name ([string]$item.Text + ' : afficher les postes concernés')
            $button.ToolTip = 'Afficher les postes concernés (données déjà en mémoire, aucune requête).'
            $button.Tag = @{ Item = $item; Board = $Board; Details = $details; Chevron = $chevron }
            $button.Add_Click({ param($s,$e) Switch-DomeniaAttentionDetails -Button $s })
            [void]$holder.Children.Add($button)
            [void]$holder.Children.Add($details)
            $line.Child = $holder
        } else {
            if ($route) {
                $routeText = if (($null -ne $item.PSObject.Properties['RouteText']) -and [string]$item.RouteText) { [string]$item.RouteText } else { 'Ouvrir' }
                $link = New-Object System.Windows.Controls.TextBlock
                $link.Margin = [System.Windows.Thickness]::new(8, 1, 0, 0); $link.FontSize = 12
                $hyperlink = New-Object System.Windows.Documents.Hyperlink
                [void]$hyperlink.Inlines.Add($routeText)
                $hyperlink.ToolTip = 'Ouvre lʼécran de lʼaction utile, sans rien exécuter.'
                $hyperlink.Tag = $route
                $hyperlink.Add_Click({ param($s,$e) try { Invoke-DomeniaUxRoute -Route ([string]$s.Tag) } catch { } })
                [void]$link.Inlines.Add($hyperlink)
                [System.Windows.Controls.DockPanel]::SetDock($link, [System.Windows.Controls.Dock]::Right)
                $row.Children.Insert(0, $link)
            }
            [void]$row.Children.Add((New-DomeniaChartText -Text ([string]$item.Text) -Size 12.5 -Key 'TextColor'))
            $line.Child = $row
        }
        [void]$panel.Children.Add($line)
        $shown++
    }
    if ($ordered.Count -gt $Max) { $more = New-DomeniaChartText -Text ('et ' + ($ordered.Count - $Max) + ' autre(s) point(s)') -Size 11.5 -Key 'MutedColor'; $more.Margin = [System.Windows.Thickness]::new(32, 4, 0, 0); [void]$panel.Children.Add($more) }
    $state = if ($alerts) { 'Alert' } elseif ($warnings) { 'Warn' } else { '' }
    return New-DomeniaChartCard -Width $Width -Height 0 -Content $panel -State $state -MinHeight $MinHeight
}

# ---------------------------------------------------------------------------
# 2. Rings: donut and gauge share the stroked-arc drawing
# ---------------------------------------------------------------------------
function New-DomeniaArcPath {
    # Stroked arc on a circle (angles in degrees, 0 = top, clockwise). Returns the path and its length.
    param([double]$Center,[double]$Radius,[double]$Start,[double]$Sweep,[double]$Thickness,[switch]$Round)
    $toPoint = { param([double]$deg) $rad = $deg * [Math]::PI / 180.0; [System.Windows.Point]::new($Center + $Radius * [Math]::Sin($rad), $Center - $Radius * [Math]::Cos($rad)) }
    $sweepUsed = [Math]::Min(359.9, [Math]::Max(0.01, $Sweep))
    $figure = New-Object System.Windows.Media.PathFigure
    $figure.StartPoint = & $toPoint $Start
    $figure.IsClosed = $false
    [void]$figure.Segments.Add([System.Windows.Media.ArcSegment]::new((& $toPoint ($Start + $sweepUsed)), [System.Windows.Size]::new($Radius, $Radius), 0, [bool]($sweepUsed -gt 180), [System.Windows.Media.SweepDirection]::Clockwise, $true))
    $geometry = New-Object System.Windows.Media.PathGeometry
    [void]$geometry.Figures.Add($figure)
    $path = New-Object System.Windows.Shapes.Path
    $path.Data = $geometry
    $path.StrokeThickness = $Thickness
    $cap = if ($Round) { [System.Windows.Media.PenLineCap]::Round } else { [System.Windows.Media.PenLineCap]::Flat }
    $path.StrokeStartLineCap = $cap; $path.StrokeEndLineCap = $cap; $path.StrokeDashCap = $cap
    return [pscustomobject]@{ Path = $path; Length = $Radius * $sweepUsed * [Math]::PI / 180.0 }
}
function Register-DomeniaArcDrawing {
    # The arc draws itself from its start: dash as long as the arc, offset from its length to 0.
    param($Card,$Arc,[double]$DelayMs = 0,[double]$Ms = 760)
    if (-not (Test-DomeniaMotion)) { return }
    $units = $Arc.Length / [Math]::Max(1.0, $Arc.Path.StrokeThickness)
    $dash = New-Object System.Windows.Media.DoubleCollection
    [void]$dash.Add($units + 0.5); [void]$dash.Add($units + 2)
    $Arc.Path.StrokeDashArray = $dash
    Register-DomeniaIntro -Visual $Arc.Path -Target $Arc.Path -Property ([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty) -From ($units + 0.5) -To 0 -Ms $Ms -DelayMs $DelayMs
}
function Set-DomeniaDonutFocus {
    # Hover on a ring segment or a legend line: the others fade, the centre tells the hovered part.
    param($State,[int]$Index)
    if ($null -eq $State) { return }
    for ($i = 0; $i -lt $State.Segments.Count; $i++) {
        $focused = ($Index -lt 0 -or $i -eq $Index)
        Set-DomeniaHoverValue $State.Segments[$i] ([System.Windows.UIElement]::OpacityProperty) $(if ($focused) { 1.0 } else { 0.28 })
        Set-DomeniaHoverValue $State.Segments[$i] ([System.Windows.Shapes.Shape]::StrokeThicknessProperty) $(if ($Index -ge 0 -and $i -eq $Index) { $State.Thickness + 5 } else { $State.Thickness })
        if ($i -lt $State.Rows.Count) { Set-DomeniaHoverValue $State.Rows[$i] ([System.Windows.UIElement]::OpacityProperty) $(if ($focused) { 1.0 } else { 0.45 }) }
    }
    if ($Index -lt 0) { $State.Big.Text = $State.DefaultBig; $State.Small.Text = $State.DefaultSmall; return }
    $State.Big.Text = $State.Percents[$Index]
    $State.Small.Text = Get-DomeniaChartTruncated $State.Labels[$Index] 18
}
function New-DomeniaDonutChart {
    param(
        [string]$Title,
        [object[]]$Items,
        [double]$Width = 340,
        [double]$Height = 240,
        [string]$CenterText = ''
    )
    $valid = @($Items | Where-Object { $_ -and $_.Value -ne $null -and [double]$_.Value -gt 0 })
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height -Title $Title }
    # Eight parts at most: the smallest ones are gathered as "Autres".
    # Parts with a meaning colour keep their order (used / free); the others go from largest to smallest.
    if (-not @($valid | Where-Object { $null -ne $_.PSObject.Properties['Color'] }).Count) { $valid = @($valid | Sort-Object { [double]$_.Value } -Descending) }
    if ($valid.Count -gt 8) {
        $rest = 0.0; foreach ($it in @($valid | Select-Object -Skip 7)) { $rest += [double]$it.Value }
        $valid = @(@($valid | Select-Object -First 7) + [pscustomobject]@{ Label = 'Autres'; Value = $rest; Color = '#94A3B8' })
    }
    $total = 0.0
    foreach ($it in $valid) { $total += [double]$it.Value }
    if ($total -le 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height -Title $Title }

    $palette = Get-DomeniaChartPalette
    $size = [Math]::Floor([Math]::Min([Math]::Min($Width * 0.44, $Height - 76), 168))
    $thickness = [Math]::Round($size * 0.13)
    $radius = ($size - $thickness - 8) / 2.0
    $center = $size / 2.0

    $ring = New-Object System.Windows.Controls.Grid
    $ring.Width = $size; $ring.Height = $size
    $ring.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $size; $canvas.Height = $size
    [void]$ring.Children.Add($canvas)
    $track = New-DomeniaArcPath -Center $center -Radius $radius -Start 0 -Sweep 359.9 -Thickness $thickness
    $track.Path.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'BorderColor')
    $track.Path.Opacity = 0.35
    [void]$canvas.Children.Add($track.Path)

    $state = @{ Segments = New-Object System.Collections.ArrayList; Rows = New-Object System.Collections.ArrayList; Labels = @(); Percents = @(); Thickness = $thickness; Big = $null; Small = $null; DefaultBig = ''; DefaultSmall = '' }
    $gap = if ($valid.Count -gt 1) { 1.6 } else { 0 }
    $angle = 0.0
    $index = 0
    $timeline = 0.0
    foreach ($it in $valid) {
        $sweep = 360.0 * [double]$it.Value / $total
        $hex = Get-DomeniaChartItemColor $it $palette $index
        $arc = New-DomeniaArcPath -Center $center -Radius $radius -Start ($angle + $gap / 2) -Sweep ([Math]::Max(0.6, $sweep - $gap)) -Thickness $thickness
        $arc.Path.Stroke = ConvertTo-DomeniaChartBrush $hex
        $arc.Path.Cursor = [System.Windows.Input.Cursors]::Hand
        $arc.Path.Tag = @{ State = $state; Index = $index }
        $arc.Path.ToolTip = [string]$it.Label + ' : ' + (Format-DomeniaChartNumber ([Math]::Round([double]$it.Value, 1)))
        $arc.Path.Add_MouseEnter({ param($s,$e) Set-DomeniaDonutFocus $s.Tag.State $s.Tag.Index })
        $arc.Path.Add_MouseLeave({ param($s,$e) Set-DomeniaDonutFocus $s.Tag.State -1 })
        [void]$canvas.Children.Add($arc.Path)
        [void]$state.Segments.Add($arc.Path)
        # Parts draw one after the other, clockwise, over about 0.8 s.
        $duration = [Math]::Max(90.0, 760.0 * $sweep / 360.0)
        Register-DomeniaArcDrawing -Card $ring -Arc $arc -DelayMs $timeline -Ms $duration
        $timeline += $duration * 0.92
        $state.Labels += [string]$it.Label
        $state.Percents += ([string][Math]::Round(100.0 * [double]$it.Value / $total) + ' %')
        $angle += $sweep
        $index++
    }

    # Centre: a big figure and a small caption ("62 % libre" -> "62 %" over "libre").
    $big = $CenterText; $small = ''
    if (-not $big) { $big = Format-DomeniaChartNumber $total; $small = 'au total' }
    elseif ($big -match '^(\S+(?:\s%)?)\s+(.+)$') { $big = $Matches[1]; $small = $Matches[2] }
    $middle = New-Object System.Windows.Controls.StackPanel
    $middle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $middle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $middle.IsHitTestVisible = $false
    $bigText = New-DomeniaChartText -Text $big -Size $(if ($big.Length -gt 6) { 17 } else { 23 }) -Weight SemiBold -Key 'TextColor' -Display
    $bigText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $smallText = New-DomeniaChartText -Text $small -Size 11 -Key 'MutedColor'
    $smallText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $smallText.MaxWidth = $radius * 1.5
    $smallText.TextAlignment = [System.Windows.TextAlignment]::Center
    [void]$middle.Children.Add($bigText); [void]$middle.Children.Add($smallText)
    [void]$ring.Children.Add($middle)
    Register-DomeniaCountUp $bigText
    $state.Big = $bigText; $state.Small = $smallText; $state.DefaultBig = $big; $state.DefaultSmall = $small

    # Legend: colour dot, label, value and share; hovering a line focuses its part.
    $legend = New-Object System.Windows.Controls.StackPanel
    $legend.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $legend.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0)
    $legendWidth = [Math]::Max(90, $Width - $size - 16 - 34)
    $index = 0
    foreach ($it in $valid) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Width = $legendWidth
        $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        foreach ($w in @('14','*','Auto')) { $col = New-Object System.Windows.Controls.ColumnDefinition; $col.Width = [System.Windows.GridLength](New-Object System.Windows.GridLengthConverter).ConvertFromString($w); [void]$row.ColumnDefinitions.Add($col) }
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8
        $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $dot.Fill = ConvertTo-DomeniaChartBrush (Get-DomeniaChartItemColor $it $palette $index)
        [void]$row.Children.Add($dot)
        $label = New-DomeniaChartText -Text ([string]$it.Label) -Size 12 -Key 'TextColor' -OneLine
        [System.Windows.Controls.Grid]::SetColumn($label, 1)
        [void]$row.Children.Add($label)
        $share = New-DomeniaChartText -Text ([string][Math]::Round(100.0 * [double]$it.Value / $total) + ' %') -Size 12 -Weight SemiBold -Key 'MutedColor'
        $share.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        [System.Windows.Controls.Grid]::SetColumn($share, 2)
        [void]$row.Children.Add($share)
        $row.Tag = @{ State = $state; Index = $index }
        $row.Add_MouseEnter({ param($s,$e) Set-DomeniaDonutFocus $s.Tag.State $s.Tag.Index })
        $row.Add_MouseLeave({ param($s,$e) Set-DomeniaDonutFocus $s.Tag.State -1 })
        [void]$legend.Children.Add($row)
        [void]$state.Rows.Add($row)
        $index++
    }

    $body = New-Object System.Windows.Controls.DockPanel
    $header = New-DomeniaChartHeader -Title $Title -Width $Width
    [System.Windows.Controls.DockPanel]::SetDock($header, [System.Windows.Controls.Dock]::Top)
    [void]$body.Children.Add($header)
    $content = New-Object System.Windows.Controls.StackPanel
    $content.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $content.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$content.Children.Add($ring)
    [void]$content.Children.Add($legend)
    [void]$body.Children.Add($content)
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $body
}
function New-DomeniaGauge {
    # Three-quarter ring with round ends; the colour turns amber then red past 80 % and 90 % (reversed with -LowIsBad).
    param(
        [string]$Title,
        [double]$Value,
        [double]$Maximum = 100,
        [double]$Width = 240,
        [double]$Height = 250,
        [string]$Unit = '',
        [switch]$LowIsBad,
        [string]$Caption = ''
    )
    if ($Maximum -le 0) { $Maximum = 100 }
    $pct = [Math]::Min(1.0, [Math]::Max(0.0, $Value / $Maximum))
    $size = [Math]::Floor([Math]::Min($Width - 40, $Height - 64))
    $thickness = [Math]::Round($size * 0.1)
    $radius = ($size - $thickness - 6) / 2.0
    $center = $size / 2.0

    $ring = New-Object System.Windows.Controls.Grid
    $ring.Width = $size; $ring.Height = $size
    $ring.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $size; $canvas.Height = $size
    [void]$ring.Children.Add($canvas)
    $track = New-DomeniaArcPath -Center $center -Radius $radius -Start 225 -Sweep 270 -Thickness $thickness -Round
    $track.Path.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'BorderColor')
    $track.Path.Opacity = 0.45
    [void]$canvas.Children.Add($track.Path)
    $alert = if ($LowIsBad) { 1 - $pct } else { $pct }
    $level = if ($alert -gt 0.9) { 'Alert' } elseif ($alert -gt 0.8) { 'Warn' } else { '' }
    if ($pct -gt 0.004) {
        $arc = New-DomeniaArcPath -Center $center -Radius $radius -Start 225 -Sweep (270.0 * $pct) -Thickness $thickness -Round
        $arc.Path.Stroke = ConvertTo-DomeniaChartBrush $(if ($level) { Get-DomeniaStateColor $level } else { Get-DomeniaBoardColor 'Info' })
        [void]$canvas.Children.Add($arc.Path)
        Register-DomeniaArcDrawing -Card $ring -Arc $arc -Ms 900
    }

    $percentText = [string][Math]::Round(100.0 * $pct) + ' %'
    $caption = if ($Caption) { $Caption } elseif ($Unit -eq '%' -and $Maximum -eq 100) { '' } else { (Format-DomeniaChartNumber ([Math]::Round($Value, 1))) + ' / ' + (Format-DomeniaChartNumber ([Math]::Round($Maximum, 1))) + ' ' + $Unit }
    $middle = New-Object System.Windows.Controls.StackPanel
    $middle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $middle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $big = New-DomeniaChartText -Text $percentText -Size ([Math]::Max(18, [Math]::Round($size * 0.2))) -Weight SemiBold -Key $(if ($level) { Get-DomeniaStateTextKey $level } else { 'TextColor' }) -Display
    $big.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    [void]$middle.Children.Add($big)
    Register-DomeniaCountUp $big
    if ($caption.Trim()) { $small = New-DomeniaChartText -Text $caption.Trim() -Size 11 -Key 'MutedColor'; $small.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; [void]$middle.Children.Add($small) }
    [void]$ring.Children.Add($middle)

    $body = New-Object System.Windows.Controls.StackPanel
    [void]$body.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$body.Children.Add($ring)
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $body
}

# ---------------------------------------------------------------------------
# 3. Bars (horizontal), columns, line
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
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height -Title $Title }
    $sorted = @($valid | Sort-Object { [double]$_.Value } -Descending)
    # A fixed height holds as many rows as fit (26 px each under the title); without one the card fits its bars.
    if (-not $PSBoundParameters.ContainsKey('Height')) { $Height = 0 }
    if ($Height -gt 0) { $Top = [Math]::Max(1, [Math]::Min($Top, [int][Math]::Floor(($Height - 28 - 30) / 26))) }
    if ($Top -gt 0 -and $sorted.Count -gt $Top) { $sorted = @($sorted | Select-Object -First $Top) }

    $palette = Get-DomeniaChartPalette
    $max = 0.0
    foreach ($it in $sorted) { if ([double]$it.Value -gt $max) { $max = [double]$it.Value } }
    if ($max -le 0) { $max = 1.0 }
    $inner = $Width - 32 - 14
    $labelWidth = [Math]::Floor([Math]::Min(150, $inner * 0.36))
    $valueWidth = 64
    $barWidth = [Math]::Max(40, $inner - $labelWidth - $valueWidth - 12)
    $single = -not @($sorted | Where-Object { $null -ne $_.PSObject.Properties['Color'] }).Count

    $list = New-Object System.Windows.Controls.StackPanel
    $i = 0
    foreach ($it in $sorted) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Height = 26
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.ToolTip = [string]$it.Label + ' : ' + (Format-DomeniaChartNumber $it.Value) + $Unit
        foreach ($w in @($labelWidth, $barWidth, $valueWidth)) { $col = New-Object System.Windows.Controls.ColumnDefinition; $col.Width = [System.Windows.GridLength]::new($w); [void]$row.ColumnDefinitions.Add($col) }
        $label = New-DomeniaChartText -Text ([string]$it.Label) -Size 12 -Key 'TextColor' -OneLine
        $label.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
        [void]$row.Children.Add($label)
        $track = New-Object System.Windows.Controls.Border
        $track.Height = 8; $track.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $track.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'BorderColor')
        $track.Opacity = 0.4
        [System.Windows.Controls.Grid]::SetColumn($track, 1)
        [void]$row.Children.Add($track)
        $bar = New-Object System.Windows.Controls.Border
        $bar.Height = 8; $bar.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $bar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $bar.Width = [Math]::Max(8.0, $barWidth * [double]$it.Value / $max)
        # One series = one colour (the accent); colours only when they carry a meaning.
        if ($single) { $bar.Background = ConvertTo-DomeniaChartBrush (Get-DomeniaBoardColor 'Info') }
        else { $bar.Background = ConvertTo-DomeniaChartBrush (Get-DomeniaChartItemColor $it $palette $i) }
        $scale = New-Object System.Windows.Media.ScaleTransform
        $bar.RenderTransform = $scale
        [System.Windows.Controls.Grid]::SetColumn($bar, 1)
        [void]$row.Children.Add($bar)
        Register-DomeniaIntro -Visual $bar -Target $scale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -From 0 -To 1 -Ms 700 -DelayMs (45 * $i)
        $value = New-DomeniaChartText -Text ((Format-DomeniaChartNumber $it.Value) + $Unit) -Size 12 -Weight SemiBold -Key 'TextColor' -OneLine
        $value.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        [System.Windows.Controls.Grid]::SetColumn($value, 2)
        [void]$row.Children.Add($value)
        [void]$list.Children.Add($row)
        $i++
    }
    # In a card of fixed height, a short list sits in the middle of the free space rather than at the top.
    $body = New-Object System.Windows.Controls.DockPanel
    $header = New-DomeniaChartHeader -Title $Title -Width $Width
    [System.Windows.Controls.DockPanel]::SetDock($header, [System.Windows.Controls.Dock]::Top)
    [void]$body.Children.Add($header)
    if ($Height -gt 0) { $list.VerticalAlignment = [System.Windows.VerticalAlignment]::Center }
    [void]$body.Children.Add($list)
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $body
}
function New-DomeniaChartGrid {
    # Horizontal guides with their values (0, half, max) for columns and lines.
    param($Canvas,[double]$Left,[double]$Top,[double]$PlotWidth,[double]$PlotHeight,[double]$Max)
    foreach ($fraction in @(0.0, 0.5, 1.0)) {
        $y = $Top + $PlotHeight * (1 - $fraction)
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $Left; $line.X2 = $Left + $PlotWidth; $line.Y1 = $y; $line.Y2 = $y
        $line.StrokeThickness = 1
        $line.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'BorderColor')
        if ($fraction -gt 0) { $dash = New-Object System.Windows.Media.DoubleCollection; [void]$dash.Add(3); [void]$dash.Add(4); $line.StrokeDashArray = $dash; $line.Opacity = 0.8 }
        [void]$Canvas.Children.Add($line)
        $label = New-DomeniaChartText -Text (Format-DomeniaChartNumber ([Math]::Round($Max * $fraction, 1))) -Size 10 -Key 'MutedColor'
        $label.Width = $Left - 6
        $label.TextAlignment = [System.Windows.TextAlignment]::Right
        [System.Windows.Controls.Canvas]::SetLeft($label, 0)
        [System.Windows.Controls.Canvas]::SetTop($label, $y - 7)
        [void]$Canvas.Children.Add($label)
    }
}
function New-DomeniaColumnChart {
    param(
        [string]$Title,
        [object[]]$Items,
        [double]$Width = 420,
        [double]$Height = 260
    )
    # Zero buckets stay on the axis: they show the shape of the distribution.
    $valid = @($Items | Where-Object { $_ -and $_.Value -ne $null -and [double]$_.Value -ge 0 })
    if (-not @($valid | Where-Object { [double]$_.Value -gt 0 }).Count) { return New-DomeniaChartEmpty -Width $Width -Height $Height -Title $Title }
    $max = 0.0
    foreach ($it in $valid) { if ([double]$it.Value -gt $max) { $max = [double]$it.Value } }
    if ($max -le 0) { $max = 1.0 }

    $innerW = $Width - 32 - 14; $innerH = $Height - 28 - 14 - 34
    $left = 34; $top = 16; $plotW = [Math]::Max(40, $innerW - $left - 4); $plotH = [Math]::Max(40, $innerH - $top - 24)
    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $innerW; $canvas.Height = $innerH
    New-DomeniaChartGrid $canvas $left $top $plotW $plotH $max

    $n = $valid.Count
    $slot = $plotW / $n
    $barW = [Math]::Min(46.0, $slot * 0.62)
    $i = 0
    foreach ($it in $valid) {
        $h = if ([double]$it.Value -gt 0) { [Math]::Max(3.0, $plotH * ([double]$it.Value / $max)) } else { 0.0 }
        $x = $left + $slot * $i + ($slot - $barW) / 2.0
        $bar = New-Object System.Windows.Controls.Border
        $bar.Width = $barW; $bar.Height = $h
        $bar.CornerRadius = [System.Windows.CornerRadius]::new([Math]::Min(6, $barW / 3), [Math]::Min(6, $barW / 3), 0, 0)
        $bar.Background = ConvertTo-DomeniaChartBrush (Get-DomeniaChartItemColor $it @(Get-DomeniaBoardColor 'Info') 0)
        $bar.ToolTip = [string]$it.Label + ' : ' + (Format-DomeniaChartNumber $it.Value)
        $bar.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 1.0)
        $scale = New-Object System.Windows.Media.ScaleTransform
        $bar.RenderTransform = $scale
        [System.Windows.Controls.Canvas]::SetLeft($bar, $x)
        [System.Windows.Controls.Canvas]::SetTop($bar, $top + $plotH - $h)
        [void]$canvas.Children.Add($bar)
        Register-DomeniaIntro -Visual $bar -Target $scale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -From 0 -To 1 -Ms 720 -DelayMs (50 * $i) -Ease 'Back'
        if ($n -le 12 -and [double]$it.Value -gt 0) {
            $value = New-DomeniaChartText -Text (Format-DomeniaChartNumber $it.Value) -Size 10.5 -Weight SemiBold -Key 'TextColor'
            $value.Width = $slot; $value.TextAlignment = [System.Windows.TextAlignment]::Center
            [System.Windows.Controls.Canvas]::SetLeft($value, $left + $slot * $i)
            [System.Windows.Controls.Canvas]::SetTop($value, $top + $plotH - $h - 16)
            [void]$canvas.Children.Add($value)
        }
        # One label every few columns when they are narrow, so labels never overlap.
        $every = [Math]::Max(1, [int][Math]::Ceiling(54.0 / [Math]::Max(1.0, $slot)))
        if (($i % $every) -eq 0) {
            $label = New-DomeniaChartText -Text ([string]$it.Label) -Size 10.5 -Key 'MutedColor' -OneLine
            $label.Width = [Math]::Max($slot, 50); $label.TextAlignment = [System.Windows.TextAlignment]::Center
            [System.Windows.Controls.Canvas]::SetLeft($label, $left + $slot * $i + ($slot - $label.Width) / 2.0)
            [System.Windows.Controls.Canvas]::SetTop($label, $top + $plotH + 6)
            [void]$canvas.Children.Add($label)
        }
        $i++
    }
    $body = New-Object System.Windows.Controls.StackPanel
    [void]$body.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$body.Children.Add($canvas)
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $body
}
function New-DomeniaLineChart {
    param(
        [string]$Title,
        [object[]]$Points,
        [double]$Width = 420,
        [double]$Height = 260
    )
    $valid = @($Points | Where-Object { $_ -and $_.Value -ne $null })
    if ($valid.Count -eq 0) { return New-DomeniaChartEmpty -Width $Width -Height $Height -Title $Title }
    $max = 0.0
    foreach ($p in $valid) { if ([double]$p.Value -gt $max) { $max = [double]$p.Value } }
    if ($max -le 0) { $max = 1.0 }

    $innerW = $Width - 32 - 14; $innerH = $Height - 28 - 14 - 34
    $left = 34; $top = 10; $plotW = [Math]::Max(40, $innerW - $left - 8); $plotH = [Math]::Max(40, $innerH - $top - 24)
    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $innerW; $canvas.Height = $innerH
    New-DomeniaChartGrid $canvas $left $top $plotW $plotH $max

    $n = $valid.Count
    $step = if ($n -gt 1) { $plotW / ($n - 1) } else { 0 }
    $points = New-Object System.Windows.Media.PointCollection
    $length = 0.0
    $previous = $null
    $i = 0
    foreach ($p in $valid) {
        $point = [System.Windows.Point]::new($left + $step * $i, $top + $plotH - ($plotH * ([double]$p.Value / $max)))
        if ($null -ne $previous) { $length += [Math]::Sqrt([Math]::Pow($point.X - $previous.X, 2) + [Math]::Pow($point.Y - $previous.Y, 2)) }
        $points.Add($point); $previous = $point
        if ($n -le 8 -or ($i % [Math]::Ceiling($n / 8.0)) -eq 0 -or $i -eq $n - 1) {
            $label = New-DomeniaChartText -Text ([string]$p.Label) -Size 10.5 -Key 'MutedColor' -OneLine
            $label.Width = 56; $label.TextAlignment = [System.Windows.TextAlignment]::Center
            [System.Windows.Controls.Canvas]::SetLeft($label, $point.X - 28)
            [System.Windows.Controls.Canvas]::SetTop($label, $top + $plotH + 6)
            [void]$canvas.Children.Add($label)
        }
        $i++
    }
    # Area under the curve fading to transparent (opacity mask keeps the theme accent).
    $area = New-Object System.Windows.Media.PointCollection
    foreach ($pt in $points) { $area.Add($pt) }
    $area.Add([System.Windows.Point]::new($left + $step * ($n - 1), $top + $plotH))
    $area.Add([System.Windows.Point]::new($left, $top + $plotH))
    $fill = New-Object System.Windows.Shapes.Polygon
    $fill.Points = $area
    $fill.Fill = ConvertTo-DomeniaChartBrush (Get-DomeniaBoardColor 'Info')
    $mask = New-Object System.Windows.Media.LinearGradientBrush
    $mask.StartPoint = [System.Windows.Point]::new(0, 0); $mask.EndPoint = [System.Windows.Point]::new(0, 1)
    [void]$mask.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(200, 0, 0, 0), 0))
    [void]$mask.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0, 0, 0, 0), 1))
    $fill.OpacityMask = $mask
    [void]$canvas.Children.Add($fill)
    Register-DomeniaIntro -Visual $fill -Target $fill -Property ([System.Windows.UIElement]::OpacityProperty) -From 0 -To 1 -Ms 600 -DelayMs 500

    $line = New-Object System.Windows.Shapes.Polyline
    $line.Points = $points
    $line.StrokeThickness = 2.5
    $line.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
    $line.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round; $line.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    $line.Stroke = ConvertTo-DomeniaChartBrush '#60A5FA'
    [void]$canvas.Children.Add($line)
    if ((Test-DomeniaMotion) -and $length -gt 0) {
        $units = $length / 2.5
        $dash = New-Object System.Windows.Media.DoubleCollection; [void]$dash.Add($units + 1); [void]$dash.Add($units + 2)
        $line.StrokeDashArray = $dash
        Register-DomeniaIntro -Visual $line -Target $line -Property ([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty) -From ($units + 1) -To 0 -Ms 900
    }
    # The latest point is marked.
    $last = $points[$points.Count - 1]
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 9; $dot.Height = 9; $dot.StrokeThickness = 2
    $dot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'BgCard')
    $dot.Stroke = ConvertTo-DomeniaChartBrush '#60A5FA'
    $dot.ToolTip = [string]$valid[$n - 1].Label + ' : ' + (Format-DomeniaChartNumber $valid[$n - 1].Value)
    [System.Windows.Controls.Canvas]::SetLeft($dot, $last.X - 4.5); [System.Windows.Controls.Canvas]::SetTop($dot, $last.Y - 4.5)
    [void]$canvas.Children.Add($dot)

    $body = New-Object System.Windows.Controls.StackPanel
    [void]$body.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$body.Children.Add($canvas)
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $body
}

# ---------------------------------------------------------------------------
# 4. Health score and value list
# ---------------------------------------------------------------------------
function New-DomeniaHealthCard {
    # Full ring with the score in the middle and the verdict below; colour from the verdict.
    param([string]$Title,[double]$Score,[string]$Verdict,[string]$Detail = '',[ValidateSet('','Ok','Warn','Alert','Off')][string]$State = 'Ok',[double]$Width = 230,[double]$Height = 250)
    $pct = [Math]::Min(1.0, [Math]::Max(0.0, $Score / 100.0))
    $size = [Math]::Floor([Math]::Min($Width - 40, $Height - 100))
    $thickness = [Math]::Round($size * 0.11)
    $radius = ($size - $thickness - 6) / 2.0
    $center = $size / 2.0
    $ring = New-Object System.Windows.Controls.Grid
    $ring.Width = $size; $ring.Height = $size
    $ring.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = $size; $canvas.Height = $size
    [void]$ring.Children.Add($canvas)
    $track = New-DomeniaArcPath -Center $center -Radius $radius -Start 0 -Sweep 359.9 -Thickness $thickness
    $track.Path.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'BorderColor')
    $track.Path.Opacity = 0.4
    [void]$canvas.Children.Add($track.Path)
    if ($pct -gt 0.004) {
        $arc = New-DomeniaArcPath -Center $center -Radius $radius -Start 0 -Sweep (360.0 * $pct) -Thickness $thickness -Round
        $arc.Path.Stroke = ConvertTo-DomeniaChartBrush $(if ($State) { Get-DomeniaStateColor $State } else { Get-DomeniaBoardColor 'Info' })
        [void]$canvas.Children.Add($arc.Path)
        Register-DomeniaArcDrawing -Card $ring -Arc $arc -Ms 1000
    }
    $middle = New-Object System.Windows.Controls.StackPanel
    $middle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $middle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $big = New-DomeniaChartText -Text ([string][int][Math]::Round($Score)) -Size ([Math]::Max(20, [Math]::Round($size * 0.26))) -Weight SemiBold -Key 'TextColor' -Display
    $big.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    [void]$middle.Children.Add($big)
    Register-DomeniaCountUp $big
    $outOf = New-DomeniaChartText -Text 'sur 100' -Size 11 -Key 'MutedColor'
    $outOf.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    [void]$middle.Children.Add($outOf)
    [void]$ring.Children.Add($middle)
    $body = New-Object System.Windows.Controls.StackPanel
    [void]$body.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width))
    [void]$body.Children.Add($ring)
    $verdictText = New-DomeniaChartText -Text $Verdict -Size 14 -Weight SemiBold -Key $(if ($State -in @('Warn','Alert')) { Get-DomeniaStateTextKey $State } else { 'TextColor' }) -OneLine
    $verdictText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $verdictText.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$body.Children.Add($verdictText)
    if ($Detail) { $sub = New-DomeniaChartText -Text $Detail -Size 11.5 -Key 'MutedColor' -OneLine; $sub.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; [void]$body.Children.Add($sub) }
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $body
}
function New-DomeniaListCard {
    # Values as a clean list: label on the left, figure on the right, hairline separators.
    param([string]$Title,[string]$Subtitle = '',[object[]]$Items = @(),[double]$Width = 420,[double]$Height = 0,[double]$MinHeight = 0,[string]$Unit = '',[string]$Fallback = '',[int]$Max = 10)
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-DomeniaChartHeader -Title $Title -Width $Width -Subtitle $Subtitle))
    $rows = @($Items | Where-Object { $null -ne $_ })
    if (-not $rows.Count -and $Fallback) { [void]$panel.Children.Add((New-DomeniaChartText -Text $Fallback -Size 15 -Weight SemiBold -Key 'TextColor' -Display)) }
    $first = $true
    foreach ($item in @($rows | Select-Object -First $Max)) {
        $line = New-Object System.Windows.Controls.Border
        $line.BorderThickness = [System.Windows.Thickness]::new(0, $(if ($first) { 0 } else { 1 }), 0, 0)
        $line.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BorderColor')
        $line.Padding = [System.Windows.Thickness]::new(0, 6, 0, 6)
        $first = $false
        $dock = New-Object System.Windows.Controls.DockPanel
        if ($null -ne $item.PSObject.Properties['Value'] -and [string]$item.Value -ne '') {
            $figure = New-DomeniaChartText -Text ((Format-DomeniaChartNumber $item.Value) + $(if ($Unit) { ' ' + $Unit } else { '' })) -Size 12 -Weight SemiBold -Key 'MutedColor'
            $figure.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
            [System.Windows.Controls.DockPanel]::SetDock($figure, [System.Windows.Controls.Dock]::Right)
            [void]$dock.Children.Add($figure)
        }
        if ($null -ne $item.PSObject.Properties['Color'] -and [string]$item.Color -match '^#[0-9A-Fa-f]{6}$') {
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 8; $dot.Height = 8; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
            $dot.Fill = ConvertTo-DomeniaChartBrush ([string]$item.Color)
            [void]$dock.Children.Add($dot)
        }
        [void]$dock.Children.Add((New-DomeniaChartText -Text ([string]$item.Label) -Size 12.5 -Key 'TextColor' -OneLine))
        $line.Child = $dock
        [void]$panel.Children.Add($line)
    }
    if ($rows.Count -gt $Max) { $more = New-DomeniaChartText -Text ('et ' + ($rows.Count - $Max) + ' autre(s)') -Size 11.5 -Key 'MutedColor'; $more.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0); [void]$panel.Children.Add($more) }
    return New-DomeniaChartCard -Width $Width -Height $Height -Content $panel -MinHeight $MinHeight
}
