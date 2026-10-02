# DOMENIA R1.11. Presentation only. No AD, remote execution or credential validation here.
# Help titles/descriptions come from a static catalogue, NEVER from a control value.
. (Join-Path $PSScriptRoot 'Domenia-Experience.Model.ps1')
. (Join-Path $PSScriptRoot 'Domenia-Experience.UI.ps1')
$script:UxModuleRoot = $PSScriptRoot
$script:UxHelpCatalogue = @{}
$script:UxShellInitialized = $false
$script:UxNavCollapsed = $false
$script:UxNavLayoutSignature = ''
$script:UxHelpVisible = $true
$script:UxHelpCompactOpen = $false
$script:UxLayoutSignature = ''
$script:UxLogCollapsed = $false
$script:UxLogHeight = 142.0
$script:UxProfileUpdating = $false

function Import-DomeniaUxHelpCatalogue {
    if ($script:UxHelpCatalogue.Count -gt 0) { return }
    $file = Join-Path $script:UxModuleRoot 'Domenia-UX.help.json'
    $items = [IO.File]::ReadAllText($file,[Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($item in @($items)) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Name) -or
            [string]::IsNullOrWhiteSpace([string]$item.Title) -or
            [string]::IsNullOrWhiteSpace([string]$item.Text)) { throw 'Catalogue d aide incomplet.' }
        if ($script:UxHelpCatalogue.ContainsKey([string]$item.Name)) { throw 'Nom duplique dans le catalogue d aide.' }
        $script:UxHelpCatalogue[[string]$item.Name] = $item
    }
}

function Get-DomeniaUxHelpEntry {
    param($Control,[string]$Name='')
    Import-DomeniaUxHelpCatalogue
    if ([string]::IsNullOrWhiteSpace($Name) -and $null -ne $Control) {
        try { $Name = [string]$Control.Name } catch { }
    }
    if ($script:UxHelpCatalogue.ContainsKey($Name)) { return $script:UxHelpCatalogue[$Name] }
    # Unknown dynamic controls receive a neutral description; no value reflection.
    return [pscustomobject]@{
        Name=$Name;Title='Aide';Text='Consultez le libelle et les actions de cette zone. Aucun contenu saisi n est recopie dans cette aide.';Kind='Unknown'
    }
}

function Get-DomeniaUxControlHelpText {
    param($Control)
    $entry = Get-DomeniaUxHelpEntry -Control $Control
    $description = [string]$entry.Text
    # Preserve status reasons supplied by the existing security UI.
    # Do not reflect Text, Password, SelectedItem, DataContext, Content or Tag.
    try {
        $statusTip = $Control.ToolTip
        if ($statusTip -is [string] -and $statusTip -ne $description -and
            $statusTip -match '^(Desactive|Droit indetermine|Estimation ACL|Ecriture brute|Action distante|Fonction desactivee|Aucune valeur|Aucun secret|Selectionne une ligne|Charge d.abord)') {
            return $description + "`r`n`r`n" + [string]$statusTip
        }
    } catch { }
    return $description
}

function Show-DomeniaUxControlHelp {
    param($Control)
    if ($null -eq $Control -or $null -eq $script:Window) { return }
    try {
        # A login window cannot send password-related context to the main window.
        if ([Windows.Window]::GetWindow($Control) -ne $script:Window) { return }
        $entry = Get-DomeniaUxHelpEntry -Control $Control
        Set-DomeniaContextHint -Title ([string]$entry.Title) -Text (Get-DomeniaUxControlHelpText -Control $Control)
    } catch { }
}

function Initialize-DomeniaUxControlHelp {
    param($Control)
    if ($null -eq $Control -or $Control -isnot [Windows.FrameworkElement]) { return }
    Import-DomeniaUxHelpCatalogue
    $name = [string]$Control.Name
    if (-not $script:UxHelpCatalogue.ContainsKey($name)) { return }
    if ($Control.Resources.Contains('Domenia.UxHelpAttached')) { return }
    $entry = $script:UxHelpCatalogue[$name]
    $Control.ToolTip = [string]$entry.Text
    [Windows.Controls.ToolTipService]::SetShowOnDisabled($Control,$true)
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($Control,350)
    [Windows.Controls.ToolTipService]::SetBetweenShowDelay($Control,100)
    [Windows.Controls.ToolTipService]::SetShowDuration($Control,20000)
    [Windows.Automation.AutomationProperties]::SetName($Control,[string]$entry.Title)
    [Windows.Automation.AutomationProperties]::SetHelpText($Control,[string]$entry.Text)
    $Control.Resources['Domenia.UxHelpAttached'] = $true
    $Control.Add_MouseEnter({param($sender,$eventArgs) Show-DomeniaUxControlHelp -Control $sender})
    $Control.Add_GotKeyboardFocus({
        param($sender,$eventArgs)
        # A routed child focus must not let a parent overwrite the specific help.
        if ($sender -eq $eventArgs.OriginalSource) { Show-DomeniaUxControlHelp -Control $sender }
    })
    $Control.Add_ToolTipOpening({param($sender,$eventArgs) Show-DomeniaUxControlHelp -Control $sender})
}

function Initialize-DomeniaUxWindowHelp {
    param($Window,[string]$XamlText='')
    if ($null -eq $Window) { return }
    Import-DomeniaUxHelpCatalogue
    if (-not [string]::IsNullOrWhiteSpace($XamlText)) {
        foreach ($match in [regex]::Matches($XamlText,'x:Name\s*=\s*"([^"]+)"')) {
            $control = $Window.FindName([string]$match.Groups[1].Value)
            if ($null -ne $control) { Initialize-DomeniaUxControlHelp -Control $control }
        }
    }
}

function Restore-DomeniaUxBaseToolTip {
    param([string]$Name)
    if ($null -eq $script:UxHelpCatalogue -or -not $script:UxHelpCatalogue.ContainsKey($Name)) { return }
    $control = Get-DomeniaControl -Name $Name
    if ($null -ne $control) { $control.ToolTip = [string]$script:UxHelpCatalogue[$Name].Text }
}

function Get-DomeniaUxRouteNames {
    return @('TabDashboard','WsSearch','TabDirectory','WsObject','TabRelations','WsComputer','TabSupport','TabAccounts','TabApplicationTools')
}

function Invoke-DomeniaUxRoute {
    param([Parameter(Mandatory=$true)][string]$Route)
    if ($Route -notin @(Get-DomeniaUxRouteNames)) { throw 'Destination interface non autorisee.' }
    if ($Route -eq 'TabDirectory') { $Route = 'WsSearch' }
    $target = Get-DomeniaControl -Name $Route
    if ($null -eq $target -or -not $target.IsEnabled -or $target.Visibility -ne [Windows.Visibility]::Visible) {
        Set-DomeniaContextHint -Title 'Ouvrez d abord une fiche' -Text 'Selectionnez une ligne pour precharger sa fiche. Pour l assistance poste, choisissez une machine.'
        return
    }
    Select-DomeniaWorkspace -Workspace $Route
    if ($Route -eq 'WsSearch') {
        $box = Get-DomeniaControl 'TxtGlobalSearch'
        if ($null -ne $box) { [void]$box.Focus() }
    }
    Sync-DomeniaUxNavigation
}

function Sync-DomeniaUxNavigation {
    if ($null -eq $script:Ctrl) { return }
    $workspaces = Get-DomeniaControl 'WorkspaceTabs'
    if ($null -eq $workspaces) { return }
    $current = '';try { $current = [string]$workspaces.SelectedItem.Name } catch { }
    $allowed = @(Get-DomeniaUxRouteNames)
    foreach ($pair in @($script:Ctrl.GetEnumerator())) {
        if ([string]$pair.Key -notmatch '^BtnUx(Nav|Home|Step|HelpAccounts)') { continue }
        $button = $pair.Value
        if ($button -isnot [Windows.Controls.Button]) { continue }
        $route = [string]$button.Uid
        if ($route -notin $allowed) { continue }
        $target = Get-DomeniaControl -Name $route
        $available = ($null -ne $target -and $target.IsEnabled -and $target.Visibility -eq [Windows.Visibility]::Visible)
        # These are navigation buttons only; no permission-bearing control is enabled here.
        $button.IsEnabled = $available
        $button.Tag = if ($route -eq $current) { 'Active' } else { '' }
        $tip = [string](Get-DomeniaUxHelpEntry -Control $button).Text
        if (-not $available) {
            if ($route -eq 'TabSupport') { $tip += ' Atelier indisponible : consultez le journal.' }
            else { $tip += ' Selectionnez une ligne adaptee dans les resultats ; sa fiche se prepare sans changer de page.' }
        }
        $button.ToolTip = $tip
    }
    $titles = @{
        TabDashboard='Accueil';WsSearch='Recherche et filtre OU';TabDirectory='Parcourir l''annuaire';WsObject='Fiche de l''objet'
        TabRelations='Relations utilisateur / poste';WsComputer='Assistance poste';TabSupport='Atelier support'
        TabAccounts='Comptes et accès';TabApplicationTools='Outils et vérifications'
    }
    $pageTitle = Get-DomeniaControl 'LblUxPageTitle'
    if ($null -ne $pageTitle -and $titles.ContainsKey($current)) { $pageTitle.Text = [string]$titles[$current] }
    $domainText = '';try { $domainText = [string](Get-DomeniaControl 'TxtDashDomain').Text } catch { }
    $domainLabel = Get-DomeniaControl 'LblUxDomain'
    if ($null -ne $domainLabel -and -not [string]::IsNullOrWhiteSpace($domainText)) { $domainLabel.Text = 'Session AD · ' + $domainText }
    $selectionLabel = Get-DomeniaControl 'LblUxSelected'
    if ($null -ne $selectionLabel) {
        $selectionLabel.Text = 'Aucune selection'
        if ($null -ne $script:SelectionLoad) {
            $selectionLabel.Text = $script:SelectionLoad.Context.Type + ' : ' + $script:SelectionLoad.Context.Name
        }
        elseif ($null -ne $script:SelectedObject) {
            $selectionLabel.Text = ([string]$script:SelectedObject.Type + ' · ' + [string]$script:SelectedObject.Name).Trim([char[]]@(' ','·'))
        }
    }
    Update-DomeniaExperienceIdentity
}

function Update-DomeniaUxProfileVisibility {
    param([AllowEmptyString()][string]$ObjectType='')
    if ($script:UxProfileUpdating -or $null -eq $script:Ctrl) { return }
    $script:UxProfileUpdating = $true
    try {
        if (-not $PSBoundParameters.ContainsKey('ObjectType')) {
            try { $ObjectType = [string]$script:SelectedObject.Type } catch { $ObjectType = '' }
        }
        $expert = ([string]$script:CurrentUiProfile -eq 'Admin')
        $hasObject = -not [string]::IsNullOrWhiteSpace($ObjectType)
        $rules = @{
            TabRaw=($expert -and $hasObject);TabPermissions=($expert -and $hasObject)
            TabWmi=($expert -and $ObjectType -eq 'Machine');TabSelfCheck=$expert;TabCmdlets=$expert;TabLog=$expert
        }
        foreach ($name in $rules.Keys) {
            $tab = Get-DomeniaControl $name
            if ($null -ne $tab) { $tab.Visibility = if ($rules[$name]) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
        }
        # Never leave a hidden detail page selected. No AD read is performed.
        foreach ($name in @('DetailTabs','ComputerTabs','ApplicationToolTabs')) {
            $tabs = Get-DomeniaControl $name
            if ($null -eq $tabs) { continue }
            if ($null -ne $tabs.SelectedItem -and $tabs.SelectedItem.Visibility -ne [Windows.Visibility]::Visible) {
                foreach ($item in @($tabs.Items)) {
                    if ($item.Visibility -eq [Windows.Visibility]::Visible) { $tabs.SelectedItem=$item;break }
                }
            }
        }
    } finally { $script:UxProfileUpdating = $false }
}

function Update-DomeniaUxLayout {
    if ($null -eq $script:Window) { return }
    Update-DomeniaUxSidebar
    $panel = Get-DomeniaControl 'UxHelpPanel';$column = Get-DomeniaControl 'UxHelpColumn'
    if ($null -eq $panel -or $null -eq $column) { return }
    $width = [double]$script:Window.ActualWidth
    if ($width -le 0) { $width = [double]$script:Window.Width }
    $plan = Get-DomeniaUxLayoutPlan -Width $width -NavCollapsed $script:UxNavCollapsed -HelpVisible $script:UxHelpVisible -CompactHelpOpen $script:UxHelpCompactOpen
    $signature = '{0}:{1}:{2}' -f $plan.Compact,$plan.HelpShown,$plan.NavWidth
    if ($signature -eq $script:UxLayoutSignature) { return }
    $script:UxLayoutSignature=$signature
    $button = Get-DomeniaControl 'BtnUxHelpToggle'
    if (-not $plan.HelpShown -and $panel.IsKeyboardFocusWithin -and $null -ne $button) { [void]$button.Focus() }
    $column.Width = [Windows.GridLength]::new([double]$plan.ColumnWidth)
    if ($plan.Compact) {
        [Windows.Controls.Grid]::SetColumn($panel,0)
        $panel.Width=$plan.HelpWidth;$panel.HorizontalAlignment=[Windows.HorizontalAlignment]::Right
        [Windows.Controls.Panel]::SetZIndex($panel,20)
    } else {
        [Windows.Controls.Grid]::SetColumn($panel,1)
        $panel.Width=[double]::NaN;$panel.HorizontalAlignment=[Windows.HorizontalAlignment]::Stretch
        [Windows.Controls.Panel]::SetZIndex($panel,0)
    }
    $panel.Visibility = if ($plan.HelpShown) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $workspaces=Get-DomeniaControl 'WorkspaceTabs'
    if($null -ne $workspaces){$workspaces.Margin=[Windows.Thickness]::new(0,0,[double]$plan.WorkspaceGap,0)}
    if ($null -ne $button) {
        $button.ToolTip = if ($plan.HelpShown) { 'Réduire le panneau d''aide. Les infobulles restent disponibles.' } else { 'Afficher le panneau d''aide contextuelle.' }
        [Windows.Automation.AutomationProperties]::SetName($button,$button.ToolTip)
    }
}

function Switch-DomeniaUxHelp {
    if ($null -eq $script:Window) { return }
    $width=[double]$script:Window.ActualWidth
    if($width -le 0){$width=[double]$script:Window.Width}
    $plan=Get-DomeniaUxLayoutPlan -Width $width -NavCollapsed $script:UxNavCollapsed -HelpVisible $script:UxHelpVisible -CompactHelpOpen $script:UxHelpCompactOpen
    # A deliberate toggle applies to both layout modes; resize must not undo it.
    $script:UxHelpVisible=-not $plan.HelpShown
    $script:UxHelpCompactOpen=$script:UxHelpVisible
    Update-DomeniaUxLayout
    Save-DomeniaUxLayoutSettings
}

function Switch-DomeniaUxLog {
    $row=Get-DomeniaControl 'UxLogRow'
    if($null -eq $row){return}
    if(-not $script:UxLogCollapsed){$script:UxLogHeight=ConvertTo-SuiteNumber $row.ActualHeight -Default 180 -Minimum 100 -Maximum 600}
    Set-DomeniaExperienceJournalLayout -Collapsed (-not $script:UxLogCollapsed)
    Save-DomeniaExperiencePreferences
}

function Initialize-DomeniaUxShell {
    if ($null -eq $script:Window -or $script:UxShellInitialized) { return }
    Import-DomeniaUxHelpCatalogue
    foreach ($control in @($script:Ctrl.Values)) { Initialize-DomeniaUxControlHelp -Control $control }
    foreach ($pair in @($script:Ctrl.GetEnumerator())) {
        if ([string]$pair.Key -notmatch '^BtnUx(Nav|Home|Step|HelpAccounts)') { continue }
        $button=$pair.Value
        if ($button -is [Windows.Controls.Button] -and [string]$button.Uid -in @(Get-DomeniaUxRouteNames)) {
            $button.Add_Click({param($sender,$eventArgs) Invoke-DomeniaUxRoute -Route ([string]$sender.Uid)})
        }
    }
    (Get-DomeniaControl 'BtnUxHelpToggle').Add_Click({Switch-DomeniaUxHelp})
    (Get-DomeniaControl 'BtnUxHelpClose').Add_Click({Switch-DomeniaUxHelp})
    (Get-DomeniaControl 'BtnUxSidebarToggle').Add_Click({Switch-DomeniaUxSidebar})
    (Get-DomeniaControl 'BtnUxCopyOuPath').Add_Click({Copy-DomeniaUxOuPath})
    (Get-DomeniaControl 'BtnUxLogToggle').Add_Click({Switch-DomeniaUxLog})
    (Get-DomeniaControl 'WorkspaceTabs').Add_SelectionChanged({
        param($sender,$eventArgs)
        if ($sender -eq $eventArgs.OriginalSource) { Sync-DomeniaUxNavigation }
    })
    $script:UxHelpVisible=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpVisible' -Default $true) -Default $true
    $script:UxHelpCompactOpen=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpCompactOpen' -Default $false)
    $script:UxNavCollapsed=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxNavCollapsed' -Default $false)
    $script:UxNavLayoutSignature=''
    try { Update-DomeniaSearchScopeUi } catch { }
    $script:Window.Add_SizeChanged({Update-DomeniaUxLayout})
    $script:Window.Add_ContentRendered({Sync-DomeniaUxNavigation;Update-DomeniaUxLayout})
    $script:Window.Add_Closed({$script:UxShellInitialized=$false;$script:UxLayoutSignature='';$script:UxHelpCompactOpen=$false;$script:UxNavLayoutSignature=''})
    $script:UxShellInitialized=$true
    Initialize-DomeniaExperience
    Update-DomeniaUxProfileVisibility
    Sync-DomeniaUxNavigation
    Update-DomeniaUxLayout
}

function Set-DomeniaUxPalette {
    param($Window,[ValidateSet('Light','Dark')][string]$Theme='Light')
    if ($null -eq $Window) { return }
    $palette=Get-SuitePalette -Theme $Theme
    $converter=[Windows.Media.BrushConverter]::new()
    foreach ($key in $palette.Keys) { $Window.Resources[$key]=$converter.ConvertFromInvariantString([string]$palette[$key]) }
    $Window.Background=$Window.Resources['WindowBg'];$Window.Foreground=$Window.Resources['TextColor']
    # Native popup/control brushes in the same window scope, not a system-wide change.
    $Window.Resources[[Windows.SystemColors]::WindowBrushKey]=$Window.Resources['BgInput']
    $Window.Resources[[Windows.SystemColors]::WindowTextBrushKey]=$Window.Resources['TextColor']
    $Window.Resources[[Windows.SystemColors]::ControlBrushKey]=$Window.Resources['BgCard']
    $Window.Resources[[Windows.SystemColors]::ControlTextBrushKey]=$Window.Resources['TextColor']
    foreach ($tuple in @(@('TxtUiLog','Background','LogBg'),@('TxtUiLog','Foreground','LogFg'),@('LogPanel','Background','BgCard'),@('LogPanel','BorderBrush','BorderColor'))) {
        $element=$Window.FindName([string]$tuple[0])
        if ($null -eq $element) { continue }
        if ($tuple[1] -eq 'Foreground') { $element.Foreground=$Window.Resources[[string]$tuple[2]] }
        elseif ($tuple[1] -eq 'BorderBrush') { $element.BorderBrush=$Window.Resources[[string]$tuple[2]] }
        else { $element.Background=$Window.Resources[[string]$tuple[2]] }
    }
}

function ConvertTo-DomeniaUxFlag {
    param($Value,[bool]$Default=$false)
    if ($Value -is [bool]) { return $Value }
    $parsed = $false
    if ($null -ne $Value -and [bool]::TryParse([string]$Value,[ref]$parsed)) { return $parsed }
    return $Default
}

function Get-DomeniaUxLayoutPlan {
    param([double]$Width=1360,[bool]$NavCollapsed=$false,[bool]$HelpVisible=$true,[bool]$CompactHelpOpen=$false)
    # Dimensions in WPF device-independent units, not physical pixels.
    $navWidth = if ($NavCollapsed) { 68.0 } else { 204.0 }
    $available = [Math]::Max(900.0,$Width) - $navWidth - 40.0
    $compact = $available -lt 1040.0
    $shown = if ($compact) { $CompactHelpOpen } else { $HelpVisible }
    [pscustomobject]@{
        NavWidth=$navWidth;Compact=$compact;HelpShown=$shown
        HelpWidth=300.0
        ColumnWidth=$(if ($shown -and -not $compact) {300.0} else {0.0})
        WorkspaceGap=$(if ($shown -and -not $compact) {12.0} else {0.0})
    }
}

function Save-DomeniaUxLayoutSettings {
    Set-DomeniaSetting -Name 'UxNavCollapsed' -Value ([bool]$script:UxNavCollapsed)
    Set-DomeniaSetting -Name 'UxHelpVisible' -Value ([bool]$script:UxHelpVisible)
    Set-DomeniaSetting -Name 'UxHelpCompactOpen' -Value ([bool]$script:UxHelpCompactOpen)
    if ($null -ne (Get-Command Save-DomeniaSettings -CommandType Function -ErrorAction SilentlyContinue)) {
        Save-DomeniaSettings -Immediate
    }
}

function Switch-DomeniaUxSidebar {
    $script:UxNavCollapsed = -not $script:UxNavCollapsed
    Update-DomeniaUxLayout
    Save-DomeniaUxLayoutSettings
}

function Update-DomeniaUxSidebar {
    $collapsed = [bool]$script:UxNavCollapsed
    if ($script:UxNavLayoutSignature -ceq [string]$collapsed) { return }
    $column = Get-DomeniaControl 'UxNavColumn'; $sidebar=Get-DomeniaControl 'UxSidebar'
    if ($null -eq $column -or $null -eq $sidebar) { return }
    $column.Width=[Windows.GridLength]::new($(if($collapsed){68.0}else{204.0}))
    $sidebar.Padding=[Windows.Thickness]::new($(if($collapsed){8.0}else{10.0}))
    foreach ($name in @('UxBrandExpanded','UxNavFooter','UxSidebarToggleLabel')) {
        $c=Get-DomeniaControl $name
        if ($null -ne $c) { $c.Visibility=if($collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible} }
    }
    $brand=Get-DomeniaControl 'UxBrandCompact'
    if($null -ne $brand){$brand.Visibility=if($collapsed){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    foreach($suffix in @('Home','Search','Object','Relations','Computer','Support','Accounts','Tools')) {
        $label=Get-DomeniaControl ('UxNavLabel'+$suffix)
        $icon=Get-DomeniaControl ('UxNavIcon'+$suffix)
        $content=Get-DomeniaControl ('UxNavContent'+$suffix)
        $button=Get-DomeniaControl ('BtnUxNav'+$suffix)
        if($null -ne $label){$label.Visibility=if($collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
        if($null -ne $icon){$icon.Margin=[Windows.Thickness]::new(0,0,$(if($collapsed){0}else{10}),0)}
        if($null -ne $content){$content.HorizontalAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Left}}
        if($null -ne $button){$button.HorizontalContentAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Stretch}}
        # Keep IsEnabled, route and Active tag untouched: this is not a permission update.
    }
    $toggle=Get-DomeniaControl 'BtnUxSidebarToggle'
    if($null -ne $toggle){
        $toggle.ToolTip=if($collapsed){'Déployer le menu : icônes et libellés.'}else{'Réduire le menu : conserver uniquement les icônes.'}
        $toggle.HorizontalContentAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Stretch}
        [Windows.Automation.AutomationProperties]::SetName($toggle,$toggle.ToolTip)
    }
    $content=Get-DomeniaControl 'UxSidebarToggleContent'
    if($null -ne $content){$content.HorizontalAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Left}}
    $glyph=Get-DomeniaControl 'UxSidebarToggleGlyph'
    if($null -ne $glyph){
        $glyph.Margin=[Windows.Thickness]::new(0,0,$(if($collapsed){0}else{10}),0)
        $path=if($collapsed){'M2,2 L20,2 20,18 2,18 Z M8,2 L8,18 M12,6 L16,10 12,14'}else{'M2,2 L20,2 20,18 2,18 Z M8,2 L8,18 M16,6 L12,10 16,14'}
        $glyph.Data=[Windows.Media.Geometry]::Parse($path)
    }
    $script:UxNavLayoutSignature=[string]$collapsed
}

function Get-DomeniaUxOuDisplay {
    param([AllowEmptyString()][string]$DistinguishedName,[bool]$IsDomain=$false)
    # Parse separators only for display. Never rebuild the LDAP search root from this label.
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $start=0; $escaped=$false; $quoted=$false
    for($i=0;$i -lt $DistinguishedName.Length;$i++){
        $c=$DistinguishedName[$i]
        if($escaped){$escaped=$false;continue}
        if($c -eq [char]92){$escaped=$true;continue}
        if($c -eq [char]34){$quoted=-not $quoted;continue}
        if($c -eq [char]44 -and -not $quoted){$parts.Add($DistinguishedName.Substring($start,$i-$start).Trim());$start=$i+1}
    }
    if($start -lt $DistinguishedName.Length){$parts.Add($DistinguishedName.Substring($start).Trim())}
    $names=New-Object 'System.Collections.Generic.List[string]'
    $domain=New-Object 'System.Collections.Generic.List[string]'
    foreach($part in $parts){
        $equals=$part.IndexOf('=');if($equals -lt 1){continue}
        $kind=$part.Substring(0,$equals).Trim();$value=$part.Substring($equals+1)
        # Escaped UTF-8 octets and escaped separators can occur in an AD distinguished name.
        $value=[regex]::Replace($value,'(?:\\[0-9A-Fa-f]{2})+',{
            param($match)
            $bytes=New-Object 'System.Collections.Generic.List[byte]'
            foreach($hex in [regex]::Matches($match.Value,'[0-9A-Fa-f]{2}')){$bytes.Add([Convert]::ToByte($hex.Value,16))}
            [Text.Encoding]::UTF8.GetString($bytes.ToArray())
        })
        $value=[regex]::Replace($value,'\\([,+=<>#;"\\ ])','$1')
        if($kind -ieq 'DC'){$domain.Add($value)}else{$names.Add($value)}
    }
    $leaf=if($IsDomain -or $names.Count -eq 0){'Tout le domaine'}else{[string]$names[0]}
    $path=New-Object 'System.Collections.Generic.List[string]'
    if($domain.Count -gt 0){$path.Add(($domain -join '.'))}
    for($i=$names.Count-1;$i -ge 0;$i--){$path.Add($names[$i])}
    $full=if($path.Count -gt 0){$path -join ' / '}else{$DistinguishedName}
    $trail=if($path.Count -gt 3){'… / '+($path.GetRange($path.Count-3,3) -join ' / ')}else{$full}
    [pscustomobject]@{Name=$leaf;Breadcrumb=$trail;FullPath=$full;DistinguishedName=$DistinguishedName}
}

function Update-DomeniaUxOuScope {
    param($Scope)
    if($null -eq $Scope){return}
    $display=Get-DomeniaUxOuDisplay -DistinguishedName ([string]$Scope.BaseDn) -IsDomain ([bool]$Scope.IsDomain)
    $name=Get-DomeniaControl 'LblOuScopeName';$path=Get-DomeniaControl 'LblOuScopePath';$summary=Get-DomeniaControl 'LblSearchScope'
    if($null -ne $name){$name.Text=$display.Name;$name.ToolTip=$display.FullPath}
    if($null -ne $path){$path.Text=$display.Breadcrumb;$path.ToolTip=$display.FullPath}
    if($null -ne $summary){
        $depth=if($Scope.Scope -eq 'Subtree'){'Sous-OU incluses'}else{'Enfants directs'}
        # D032: browsing always reads 'Dans cette OU', the upper bar always 'Domaine entier'.
        $label='Dans : '+$display.Name+'  ·  '+$depth
        if($null -ne (Get-Command Get-DomeniaScopeLabel -CommandType Function -ErrorAction SilentlyContinue)){
            $label=Get-DomeniaScopeLabel -Mode Browse -OuName ([string]$display.Name) -Subtree ($Scope.Scope -eq 'Subtree')
        }
        $summary.Text=$label
        $summary.ToolTip='Racine LDAP : '+[string]$Scope.BaseDn+"`r`n"+$depth+"`r`nLe texte de la barre du haut ne filtre pas cette OU."
    }
}

function Copy-DomeniaUxOuPath {
    $box=Get-DomeniaControl 'TxtBranchDn'
    if($null -eq $box -or [string]::IsNullOrWhiteSpace([string]$box.Text)){return}
    try{
        [Windows.Clipboard]::SetText([string]$box.Text)
        Set-DomeniaContextHint -Title 'Chemin LDAP copié' -Text 'Le DN de la branche sélectionnée est dans le presse-papiers. Le filtre et les résultats restent inchangés.'
    }catch{
        Set-DomeniaContextHint -Title 'Copie indisponible' -Text 'Le presse-papiers est occupé. Dépliez le chemin LDAP pour le sélectionner et le copier manuellement.'
    }
}

function Initialize-DomeniaUxLoginPresentation {
    param($Window)
    if($null -eq $Window){return}
    # A short login by default; long errors/details remain scrollable on small screens.
    $work=[Windows.SystemParameters]::WorkArea
    $Window.MaxHeight=[Math]::Max(280.0,[Math]::Min(800.0,$work.Height-24.0))
    $Window.MaxWidth=[Math]::Max(340.0,$work.Width-24.0)
    if($Window.Width -gt $Window.MaxWidth){$Window.Width=$Window.MaxWidth}
    if (-not $Window.Resources.Contains('DomeniaLoginWaitWired')) {
        $waitCancel = $Window.FindName('BtnLoginWaitCancel')
        if ($null -ne $waitCancel) {
            $waitCancel.Add_Click({
                param($sender,$eventArgs)
                $owner = (Get-DomeniaOwningDialog $sender)
                $cancel = $owner.FindName('BtnCancel')
                if ($null -ne $cancel) { $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
            })
            $Window.Add_PreviewKeyDown({
                param($sender,$eventArgs)
                $wait = $sender.FindName('PanelSplash')
                if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $null -ne $wait -and $wait.IsVisible) {
                    $eventArgs.Handled = $true
                    $cancel = $sender.FindName('BtnCancel')
                    if ($null -ne $cancel) { $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                }
            })
        }
        $Window.Resources['DomeniaLoginWaitWired'] = $true
    }
    Initialize-DomeniaExperienceLogin -Window $Window
}
