#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Light','Dark')][string]$Theme = 'Light',
    [switch]$Verify,
    [switch]$Progressive,
    [string]$ReportPath = '',
    [string]$CaptureDirectory = '',
    [string[]]$CaptureRoutes = @('WsSearch'),
    [switch]$Quiet
)

# Offline preview of the actual 1.0 RC1 WPF layout. No application startup is run.
# Only a fixed allowlist of presentation functions is extracted from the local source.
$ErrorActionPreference = 'Stop'
if($Progressive -and ($Verify -or $CaptureDirectory)){throw 'Le mode progressif est un aperçu interactif distinct des tests et captures statiques.'}
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Utilisez Windows PowerShell 5.1, pas PowerShell 7.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Lancez ce script avec powershell.exe -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $wad 'Domenia-Core.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($corePath,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ('Erreur de syntaxe du coeur : ' + $parseErrors[0].Message) }
$presentationNames = @(
    'Set-DomeniaControlText','Get-MainXaml','Assert-DomeniaXamlPreflight','Get-DomeniaXamlControlNames',
    'Get-DomeniaControl','Set-DomeniaContextHint','Get-DomeniaFriendlyControlLabel',
    'Get-DomeniaDefaultToolTip','Save-DomeniaUiProfile','Apply-DomeniaUiProfile',
    'Set-TabVisibility','Set-VisibleTabsForType','Assert-DomeniaWorkspaceSelection',
    'Select-DomeniaWorkspace','Get-DomeniaSearchMode','Get-DomeniaSearchText','Set-DomeniaSearchMode','Get-DomeniaSearchScope','Update-DomeniaSearchScopeUi',
    'Set-SelectedBranch','Reset-DomeniaSearchScope','Set-DomeniaComboByContent',
    'Set-DomeniaItemsSource','Set-DomeniaGridRows','Test-DomeniaSearchStateCurrent','Get-GlobalSelectedTypeFilter','Get-TypeLdapFilter','Get-DomeniaEffectiveWorkerResult','Normalize-LinkComputer'
)
foreach ($name in $presentationNames) {
    $nodes = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if ($nodes.Count -ne 1) { throw ('Fonction UI introuvable ou ambigue : ' + $name) }
    Invoke-Expression $nodes[0].Extent.Text
}
# D082/D085: counters and selection preview come from the shell rules (and their dependencies).
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Relations.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Access.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-UX.UI.ps1')

# Isolated UI state and local-only replacements. No user cache/config/log is read.
$script:PreviewSettings = @{}
$script:Ctrl = @{}
$script:SelectedObject = $null
$script:CurrentUiProfile = 'Tech'
$script:ReadOnlyMode = $true
$script:PreviewTheme = $Theme
$script:Conn = [pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Domain='example.invalid'}
$script:SelectedBranchDn = $script:Conn.BaseDn
$script:SearchMode='OU'
$script:SuppressBranchAutoLoad = $false
$script:RestoringSettings = $false
function Set-DomeniaSetting { param([string]$Name,$Value) $script:PreviewSettings[$Name]=$Value }
function Get-DomeniaSetting { param([string]$Name,$Default=$null) if($script:PreviewSettings.ContainsKey($Name)){return $script:PreviewSettings[$Name]};return $Default }
function Add-DomeniaUiLog { param([string]$Area,[string]$Text,[string]$Level='INFO') }
function Set-Status { param([string]$Text,[string]$Level='INFO') }
function Write-AppLog { param([string]$Text,[string]$Level='INFO') }
function Apply-DomeniaGuiElementPolicy { }
function Update-Dashboard { }
function Save-DomeniaSettings { param([switch]$Immediate) }
function Get-DomeniaCredentialUserName { param($Credential) return '' }
$script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:SessionEpoch=1;$script:WriteState='Idle'
function Apply-DomeniaPresenceFilter {
    [void](Set-DomeniaGridRows 'DgObjects' -Rows $script:BranchObjects)
}


$script:PreviewChecks = New-Object 'System.Collections.Generic.List[object]'
function Test-PreviewAssertion {
    param([string]$Name,[scriptblock]$Test)
    try {
        $result = & $Test
        if (-not [bool]$result) { throw 'Condition non verifiee.' }
        $script:PreviewChecks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})
    } catch {
        $script:PreviewChecks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})
    }
}
function Update-PreviewLayout {
    if ($null -eq $script:Window) { return }
    $script:Window.UpdateLayout()
    $script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Update-DomeniaUxLayout
    Sync-DomeniaUxNavigation
    # Never suggest a verified AD connection in the offline view.
    (Get-DomeniaControl 'LblUxDomain').Text='APERÇU LOCAL · Données fictives · Sans accès AD'
}
function Open-PreviewObject {
    param([string]$Kind='Machine')
    $display = if($Kind -eq 'Machine'){'PC-DEMO-01'}else{'Alex Démo'}
    $script:SelectedObject=[pscustomobject]@{Type=$Kind;Name=$display;DN='CN=Exemple,OU=Demo,DC=example,DC=invalid'}
    Set-VisibleTabsForType -Type $Kind
    foreach($k in @('Object','Computer')){
        $h=Get-DomeniaControl ($k+'ReadContent');$e=Get-DomeniaControl ($k+'ReadPlaceholder')
        if($null -ne $h){$h.Visibility='Visible';$h.IsEnabled=$true}
        if($null -ne $e){$e.Visibility='Collapsed'}
    }
    foreach ($entry in @(@('TxtObjName',$display),@('TxtObjType',$Kind),@('TxtObjDn','CN=Exemple,OU=Demo,DC=example,DC=invalid'))) {
        $control=Get-DomeniaControl ([string]$entry[0]);if($null -ne $control){$control.Text=[string]$entry[1]}
    }
    Update-PreviewLayout
}

$script:Window = $null
try {
    $xamlText = Get-MainXaml
    Assert-DomeniaXamlPreflight -XamlText $xamlText -Context 'Apercu local RC1.4'
    $reader = [Xml.XmlNodeReader]::new([xml]$xamlText)
    try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $script:Window.Title = 'DOMENIA 1.0 RC1.4 | APERÇU LOCAL | aucune connexion AD'
    foreach ($name in @(Get-DomeniaXamlControlNames -XamlText $xamlText)) {
        $control=$script:Window.FindName($name)
        if ($null -ne $control) { $script:Ctrl[$name]=$control }
    }
    # Visual support workspace only: its production model/handlers are not loaded.
    $supportText=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Support.xaml'),[Text.Encoding]::UTF8)
    $supportReader=[Xml.XmlNodeReader]::new([xml]$supportText)
    try { $supportView=[Windows.Markup.XamlReader]::Load($supportReader) } finally { $supportReader.Close() }
    $supportTab=[Windows.Controls.TabItem]::new();$supportTab.Name='TabSupport';$supportTab.Header='Atelier';$supportTab.Content=$supportView
    [void](Get-DomeniaControl 'WorkspaceTabs').Items.Add($supportTab)
    $script:Ctrl['TabSupport']=$supportTab
    foreach($name in @(Get-DomeniaXamlControlNames -XamlText $supportText)) {
        $control=$supportView.FindName($name);if($null -ne $control){$script:Ctrl[$name]=$control}
    }
    (Get-DomeniaControl 'ChkReadOnlyMode').IsChecked=$true
    (Get-DomeniaControl 'ChkReadOnlyMode').IsEnabled=$false
    foreach ($control in @($script:Ctrl.Values)) {
        if ($control -is [Windows.Controls.Button] -and [string]$control.Name -notmatch '^Btn(Ux|Suite)' -and
            [string]$control.Name -notin @('BtnGlobalSearch','BtnThemeToggle')) { $control.IsEnabled=$false }
    }
    $script:PreviewRows = @(
        [pscustomobject]@{Type='Machine';Name='PC-DEMO-01';Login='PC-DEMO-01';UPN='pc-demo-01.example.invalid';Presence='Non testé';Association='Donnée fictive';DN='CN=PC-DEMO-01,OU=Marseille,DC=example,DC=invalid'},
        [pscustomobject]@{Type='Utilisateur';Name='Alex Démo';Login='alex.demo';UPN='alex.demo@example.invalid';Presence='Non testé';Association='Donnée fictive';DN='CN=Alex Demo,OU=Support,OU=Marseille,DC=example,DC=invalid'},
        [pscustomobject]@{Type='Groupe';Name='Support Lyon';Login='support.lyon';UPN='';Presence='Non testé';Association='Donnée fictive';DN='CN=Support Lyon,OU=Lyon,DC=example,DC=invalid'}
    )
    if($Progressive){. (Join-Path $PSScriptRoot 'Preview-DomeniaProgress.ps1')}
    function Invoke-DomeniaSearchFilterChanged {
        param([ValidateSet('Global','OU')][string]$Mode='OU')
        if ($script:SuppressBranchAutoLoad -or $script:RestoringSettings) { return }
        Set-DomeniaSearchMode -Mode $Mode
        $scope = Get-DomeniaSearchScope -Mode $Mode
        $text = Get-DomeniaSearchText -Mode $Mode
        $type = [string](Get-DomeniaControl 'CmbGlobalType').SelectedItem.Content
        if($Mode -eq 'Global'){$type='Tous'}
        $types = @{Utilisateurs='Utilisateur';Machines='Machine';Groupes='Groupe'}
        $rows = New-Object System.Collections.ArrayList
        foreach ($row in $script:PreviewRows) {
            # Synthetic DNs deliberately contain no escapes. Production uses LDAP SearchRoot.
            $within = $row.DN.EndsWith(','+$scope.BaseDn,[StringComparison]::OrdinalIgnoreCase)
            if ($scope.Scope -eq 'OneLevel') { $within = ($row.DN.Substring($row.DN.IndexOf(',')+1) -ieq $scope.BaseDn) }
            if (-not $within) { continue }
            if ($types.ContainsKey($type) -and $row.Type -ne $types[$type]) { continue }
            if ($type -eq 'OU et conteneurs') { continue }
            if ($text -and $text -ne '*' -and $row.Name -notlike ($text+'*') -and $row.Login -notlike ($text+'*')) { continue }
            [void]$rows.Add($row)
        }
        if($Progressive){Start-DomeniaProgressDemo $rows.ToArray();Update-DomeniaSearchScopeUi;Invoke-DomeniaUxRoute -Route 'WsSearch';return}
        $script:BranchObjects=@($rows.ToArray())
        [void](Set-DomeniaItemsSource 'DgObjects' $script:BranchObjects)
        (Get-DomeniaControl 'LblBranchCount').Text = [string]$rows.Count + ' résultat(s) fictif(s)'
        Update-DomeniaSearchScopeUi
        Invoke-DomeniaUxRoute -Route 'WsSearch'
    }
    $tree = Get-DomeniaControl 'TvDirectory'
    $root = [Windows.Controls.TreeViewItem]::new();$root.Header='example.invalid (démonstration)'
    $root.Tag=[pscustomobject]@{DN=$script:Conn.BaseDn;Name='example.invalid'}
    foreach ($site in @('Marseille','Lyon')) {
        $item=[Windows.Controls.TreeViewItem]::new();$item.Header='OU '+$site
        $item.Tag=[pscustomobject]@{DN=('OU='+$site+','+$script:Conn.BaseDn);Name=$site}
        $item.Add_Selected({param($sender,$event) if($event.OriginalSource -eq $sender){Set-SelectedBranch -Node $sender;$event.Handled=$true}})
        if ($site -eq 'Marseille') {
            $child=[Windows.Controls.TreeViewItem]::new();$child.Header='OU Support'
            $child.Tag=[pscustomobject]@{DN=('OU=Support,'+$item.Tag.DN);Name='Support'}
            $child.Add_Selected({param($sender,$event) if($event.OriginalSource -eq $sender){Set-SelectedBranch -Node $sender;$event.Handled=$true}})
            [void]$item.Items.Add($child);$item.IsExpanded=$true
        }
        [void]$root.Items.Add($item)
    }
    $root.Add_Selected({param($sender,$event) if($event.OriginalSource -eq $sender){Set-SelectedBranch -Node $sender;$event.Handled=$true}})
    [void]$tree.Items.Add($root);$root.IsExpanded=$true
    (Get-DomeniaControl 'BtnSearchAllDomain').IsEnabled=$true
    (Get-DomeniaControl 'BtnSearchAllDomain').Add_Click({Reset-DomeniaSearchScope})
    (Get-DomeniaControl 'ChkSubtree').Add_Checked({Invoke-DomeniaSearchFilterChanged})
    (Get-DomeniaControl 'ChkSubtree').Add_Unchecked({Invoke-DomeniaSearchFilterChanged})
    (Get-DomeniaControl 'CmbGlobalType').Add_SelectionChanged({Invoke-DomeniaSearchFilterChanged})
    Invoke-DomeniaSearchFilterChanged
    (Get-DomeniaControl 'DgObjects').Add_SelectionChanged({
        param($sender,$args)
        if($args.OriginalSource -eq $sender -and $null -ne (Get-Command Select-DomeniaLiveResult -ErrorAction SilentlyContinue)){Select-DomeniaLiveResult}
    })
    (Get-DomeniaControl 'DgObjects').Add_MouseDoubleClick({
        param($sender,$args)
        $container=[Windows.Controls.ItemsControl]::ContainerFromElement($sender,$args.OriginalSource)
        if($container -is [Windows.Controls.DataGridRow] -and @($sender.SelectedItems).Count -eq 1){Open-PreviewObject -Kind ([string]$sender.SelectedItem.Type);$args.Handled=$true}
    })
    (Get-DomeniaControl 'DgObjects').Add_KeyDown({
        param($sender,$args)
        if($args.Key -eq 'Enter' -and @($sender.SelectedItems).Count -eq 1){Open-PreviewObject -Kind ([string]$sender.SelectedItem.Type);$args.Handled=$true}
    })
    (Get-DomeniaControl 'BtnGlobalSearch').Add_Click({ Invoke-DomeniaSearchFilterChanged -Mode Global })
    (Get-DomeniaControl 'BtnSearchInOu').IsEnabled=$true
    (Get-DomeniaControl 'BtnSearchInOu').Add_Click({Invoke-DomeniaSearchFilterChanged -Mode OU})
    (Get-DomeniaControl 'TxtGlobalSearch').Add_KeyDown({param($sender,$args) if($args.Key -eq [Windows.Input.Key]::Return){Invoke-DomeniaSearchFilterChanged -Mode Global;$args.Handled=$true}})
    (Get-DomeniaControl 'BtnThemeToggle').Add_Click({
        $script:PreviewTheme=if($script:PreviewTheme -eq 'Light'){'Dark'}else{'Light'}
        Set-DomeniaUxPalette -Window $script:Window -Theme $script:PreviewTheme
    })
    (Get-DomeniaControl 'CmbUiProfile').Add_SelectionChanged({
        param($sender,$args)
        if($null -ne $sender.SelectedItem -and [string]$sender.SelectedItem.Tag -ne $script:CurrentUiProfile){Apply-DomeniaUiProfile -Profile ([string]$sender.SelectedItem.Tag)}
    })
    (Get-DomeniaControl 'TxtUiLog').Text='APERÇU LOCAL. Aucun annuaire ni poste distant contacté. Les actions métier sont désactivées.'
    Set-VisibleTabsForType -Type ''
    Initialize-DomeniaUxShell
    Set-DomeniaUxPalette -Window $script:Window -Theme $Theme
    $script:Window.Add_ContentRendered({Update-PreviewLayout})

    if ($Verify -or -not [string]::IsNullOrWhiteSpace($CaptureDirectory)) {
        $script:Window.Show()
        Update-PreviewLayout
    }
    if ($Verify) {
        Test-PreviewAssertion 'Analyse native de tous les scripts du paquet' {
            $bad=@()
            foreach($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $wad) -Filter '*.ps1' -Recurse -File)){
                $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e)
                if(@($e).Count -gt 0){$bad+=($file.Name+': '+$e[0].Message)}
            }
            if($bad.Count -gt 0){throw ($bad -join '; ')};$true
        }
        Test-PreviewAssertion 'Chargement WPF de la vraie fenêtre' { $script:Window -is [Windows.Window] }
        Test-PreviewAssertion 'Navigation latérale et ancienne liste de fonctions présentes' {
            @('BtnUxNavHome','BtnUxNavSearch','BtnUxHelpToggle','UxLogRow','WorkspaceTabs','SearchBrowserLayout','SearchOuPanel','BtnSearchAllDomain','ChkSubtree','TxtGlobalSearch','TvDirectory','TabAccounts','TabSupport','DgObjects') | ForEach-Object { if($null -eq (Get-DomeniaControl $_)){throw ('Controle absent : '+$_)} };$true
        }
        Test-PreviewAssertion 'Partie nommée du TextBox conservée' {
            $box=Get-DomeniaControl 'TxtGlobalSearch';$box.ApplyTemplate()|Out-Null;$null -ne $box.Template.FindName('PART_ContentHost',$box)
        }
        Test-PreviewAssertion 'Partie popup de la liste déroulante conservée' {
            $combo=Get-DomeniaControl 'CmbUiProfile';$combo.ApplyTemplate()|Out-Null;$null -ne $combo.Template.FindName('PART_Popup',$combo)
        }
        Test-PreviewAssertion 'Aide statique et accessible sur les contrôles catalogués' {
            foreach($pair in @($script:Ctrl.GetEnumerator())) {
                $control=$pair.Value
                if($control -isnot [Windows.FrameworkElement] -or -not $script:UxHelpCatalogue.ContainsKey([string]$pair.Key)){continue}
                if(-not [Windows.Controls.ToolTipService]::GetShowOnDisabled($control)){throw ('Aide desactivee : '+$pair.Key)}
                if([string]::IsNullOrWhiteSpace([Windows.Automation.AutomationProperties]::GetHelpText($control))){throw ('HelpText absent : '+$pair.Key)}
            };$true
        }
        Test-PreviewAssertion 'Le titre ne collisionne pas avec la variable du contrôle' {
            Set-DomeniaContextHint -Title 'Titre de test' -Text 'Description de test'
            (Get-DomeniaControl 'LblContextTitle').Text -ceq 'Titre de test'
        }
        Test-PreviewAssertion 'La saisie et le mot de passe révélé ne remontent pas dans l aide' {
            $sensitive=@($script:Ctrl.Values | Where-Object { $_ -is [Windows.Controls.TextBox] -and $_.Name -match '(PasswordVisible|NewVisible|ConfirmVisible|AdminVisible)' })
            if($sensitive.Count -eq 0){throw 'Aucun champ sensible dans le test.'}
            foreach($box in $sensitive){
                $old=$box.Text;$box.Text='SECRET_SENTINEL_98_R17'
                Show-DomeniaUxControlHelp -Control $box
                $output=(Get-DomeniaFriendlyControlLabel $box)+(Get-DomeniaDefaultToolTip $box)+(Get-DomeniaUxControlHelpText $box)+(Get-DomeniaControl 'LblContextHint').Text
                $box.Text=$old
                if($output.Contains('SECRET_SENTINEL_98_R17')){throw ('Valeur divulguee : '+$box.Name)}
            };$true
        }
        Test-PreviewAssertion 'Enregistrement de l aide idempotent' {
            $box=Get-DomeniaControl 'TxtGlobalSearch';Initialize-DomeniaUxControlHelp $box;Initialize-DomeniaUxControlHelp $box
            [bool]$box.Resources['Domenia.UxHelpAttached']
        }
        Test-PreviewAssertion 'Sans objet la navigation assistance est indisponible' {
            $script:SelectedObject=$null;Set-VisibleTabsForType -Type '';Sync-DomeniaUxNavigation
            -not (Get-DomeniaControl 'BtnUxNavComputer').IsEnabled
        }
        Test-PreviewAssertion 'Ancien raccourci Annuaire redirige vers Recherche' {
            Invoke-DomeniaUxRoute -Route 'TabDirectory'
            (Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsSearch'
        }
        Test-PreviewAssertion 'Recherche accessible depuis le bandeau' {
            Invoke-DomeniaUxRoute -Route 'WsSearch'
            (Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsSearch'
        }
        Test-PreviewAssertion 'Arbre et resultats dans la meme page, colonnes distinctes' {
            $layout=Get-DomeniaControl 'SearchBrowserLayout'
            $children=@($layout.Children)
            [Windows.Controls.Grid]::GetColumn((Get-DomeniaControl 'SearchOuPanel')) -eq 0 -and
            [Windows.Controls.Grid]::GetColumn($children[-1]) -eq 2 -and
            (Get-DomeniaControl 'TabDirectory') -eq $null
        }
        Test-PreviewAssertion 'OU Marseille filtre deux objets fictifs' {
            $script:SelectedBranchDn='OU=Marseille,DC=example,DC=invalid'
            (Get-DomeniaControl 'ChkSubtree').IsChecked=$true
            Invoke-DomeniaSearchFilterChanged
            (Get-DomeniaControl 'DgObjects').Items.Count -eq 2
        }
        Test-PreviewAssertion 'Enfants directs exclut la sous-OU fictive' {
            (Get-DomeniaControl 'ChkSubtree').IsChecked=$false
            Invoke-DomeniaSearchFilterChanged
            (Get-DomeniaControl 'DgObjects').Items.Count -eq 1
        }
        Test-PreviewAssertion 'Tout le domaine conserve le texte de recherche' {
            (Get-DomeniaControl 'TxtGlobalSearch').Text='PC-DEMO'
            Reset-DomeniaSearchScope
            (Get-DomeniaControl 'TxtGlobalSearch').Text -eq 'PC-DEMO' -and
            $script:SelectedBranchDn -eq $script:Conn.BaseDn -and
            [bool](Get-DomeniaControl 'ChkSubtree').IsChecked
        }
        (Get-DomeniaControl 'TxtGlobalSearch').Text=''
        Reset-DomeniaSearchScope
        Test-PreviewAssertion 'Route inconnue rejetée' {
            try{Invoke-DomeniaUxRoute -Route 'Invoke-Anything'}catch{return $true};$false
        }
        Test-PreviewAssertion 'Mode Essentiel masque WMI même après ouverture de machine' {
            Apply-DomeniaUiProfile -Profile 'Tech';Open-PreviewObject -Kind 'Machine'
            (Get-DomeniaControl 'TabWmi').Visibility -eq [Windows.Visibility]::Collapsed
        }
        Test-PreviewAssertion 'Mode Expert rétablit WMI pour une machine' {
            Apply-DomeniaUiProfile -Profile 'Admin'
            (Get-DomeniaControl 'TabWmi').Visibility -eq [Windows.Visibility]::Visible
        }
        Test-PreviewAssertion 'Mode Expert ne montre pas WMI sur un utilisateur' {
            Open-PreviewObject -Kind 'Utilisateur'
            (Get-DomeniaControl 'TabWmi').Visibility -eq [Windows.Visibility]::Collapsed
        }
        Test-PreviewAssertion 'Un onglet technique masqué ne reste pas sélectionné' {
            Apply-DomeniaUiProfile -Profile 'Admin';Select-DomeniaWorkspace -Workspace 'WsObject' -Inner 'DetailTabs' -Tab 'TabRaw'
            Apply-DomeniaUiProfile -Profile 'Tech'
            (Get-DomeniaControl 'DetailTabs').SelectedItem.Visibility -eq [Windows.Visibility]::Visible
        }
        Test-PreviewAssertion 'Choisir le profil Expert ne désactive pas la lecture seule' {
            Apply-DomeniaUiProfile -Profile 'Admin';[bool](Get-DomeniaControl 'ChkReadOnlyMode').IsChecked
        }
        Test-PreviewAssertion 'Réduire le journal conserve son contenu' {
            $before=(Get-DomeniaControl 'TxtUiLog').Text;Switch-DomeniaUxLog
            $ok=((Get-DomeniaControl 'UxLogRow').Height.Value -eq 42 -and (Get-DomeniaControl 'TxtUiLog').Text -ceq $before)
            Switch-DomeniaUxLog;$ok
        }
        Test-PreviewAssertion 'Thèmes clair et sombre changent les ressources effectives' {
            Set-DomeniaUxPalette -Window $script:Window -Theme 'Dark'
            $dark=$script:Window.Resources['BgCard'].Color.ToString()
            Set-DomeniaUxPalette -Window $script:Window -Theme 'Light'
            $dark -ne $script:Window.Resources['BgCard'].Color.ToString()
        }
        Test-PreviewAssertion 'Panneau latéral en grande largeur' {
            $script:Window.Width=1600;$script:UxHelpVisible=$true;$script:UxLayoutSignature='';Update-PreviewLayout
            (Get-DomeniaControl 'UxHelpColumn').Width.Value -eq 300
        }
        Test-PreviewAssertion 'Petite largeur sans colonne d aide imposée' {
            $script:Window.Width=1100;$script:UxHelpCompactOpen=$false;$script:UxLayoutSignature='';Update-PreviewLayout
            (Get-DomeniaControl 'UxHelpColumn').Width.Value -eq 0 -and (Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Collapsed
        }
        Test-PreviewAssertion 'Aide en superposition accessible en petite largeur' {
            Switch-DomeniaUxHelp;Update-PreviewLayout
            (Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Visible -and [Windows.Controls.Grid]::GetColumn((Get-DomeniaControl 'UxHelpPanel')) -eq 0
        }
        Test-PreviewAssertion 'Noms de parties autorisés dans deux modèles distincts' {
            $xml='<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Window.Resources><ControlTemplate x:Key="A"><Border x:Name="Part"/></ControlTemplate><ControlTemplate x:Key="B"><Border x:Name="Part"/></ControlTemplate></Window.Resources></Window>'
            Assert-DomeniaXamlPreflight -XamlText $xml;$true
        }
        Test-PreviewAssertion 'Vrai doublon de nom de contrôle rejeté' {
            $xml='<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><StackPanel><Button x:Name="Duplicate"/><Button x:Name="Duplicate"/></StackPanel></Window>'
            try{Assert-DomeniaXamlPreflight -XamlText $xml}catch{return $true};$false
        }
        Test-PreviewAssertion 'Rail icones : largeur et libelles replies' {
            $script:UxNavCollapsed=$false;$script:UxNavLayoutSignature='';Update-PreviewLayout
            Switch-DomeniaUxSidebar;Update-PreviewLayout
            (Get-DomeniaControl 'UxNavColumn').Width.Value -eq 68 -and
            (Get-DomeniaControl 'UxNavLabelSearch').Visibility -eq [Windows.Visibility]::Collapsed -and
            (Get-DomeniaControl 'UxNavIconSearch').IsVisible
        }
        Test-PreviewAssertion 'Rail icones : centrage du pictogramme' {
            $icon=Get-DomeniaControl 'UxNavIconSearch';$button=Get-DomeniaControl 'BtnUxNavSearch'
            $point=$icon.TranslatePoint([Windows.Point]::new($icon.ActualWidth/2,0),$button)
            [Math]::Abs($point.X-$button.ActualWidth/2) -lt 1.5
        }
        Test-PreviewAssertion 'Repli conserve la destination et les droits' {
            $route=(Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name
            $enabled=(Get-DomeniaControl 'BtnUxNavComputer').IsEnabled
            Switch-DomeniaUxSidebar;Update-PreviewLayout
            (Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -ceq $route -and
            (Get-DomeniaControl 'BtnUxNavComputer').IsEnabled -eq $enabled -and
            (Get-DomeniaControl 'UxNavLabelSearch').Visibility -eq [Windows.Visibility]::Visible
        }
        Test-PreviewAssertion 'Choix du rail enregistre' { $script:PreviewSettings.ContainsKey('UxNavCollapsed') -and -not [bool]$script:PreviewSettings.UxNavCollapsed }
        Test-PreviewAssertion 'Repli de l aide libere aussi la gouttiere' {
            $script:Window.Width=1600;$script:UxHelpVisible=$true;$script:UxHelpCompactOpen=$true;$script:UxLayoutSignature='';Update-PreviewLayout
            (Get-DomeniaControl 'BtnUxHelpClose').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            Update-PreviewLayout
            (Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Collapsed -and
            (Get-DomeniaControl 'UxHelpColumn').Width.Value -eq 0 -and (Get-DomeniaControl 'WorkspaceTabs').Margin.Right -eq 0
        }
        Test-PreviewAssertion 'Redimensionner ne reouvre pas une aide fermee' {
            $script:Window.Width=1100;Update-PreviewLayout
            $small=(Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Collapsed
            $script:Window.Width=1600;Update-PreviewLayout
            $small -and (Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Collapsed -and -not [bool]$script:PreviewSettings.UxHelpVisible
        }
        Test-PreviewAssertion 'Bouton du bandeau rouvre l aide' {
            (Get-DomeniaControl 'BtnUxHelpToggle').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Update-PreviewLayout
            (Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Visible -and [bool]$script:PreviewSettings.UxHelpVisible
        }
        Test-PreviewAssertion 'OU lisible sans DN coupe dans une hauteur fixe' {
            $script:SelectedBranchDn='OU=STAGING,OU=Postes,OU=Unite locale,DC=example,DC=invalid'
            Update-DomeniaSearchScopeUi
            (Get-DomeniaControl 'LblOuScopeName').Text -eq 'STAGING' -and
            (Get-DomeniaControl 'TxtBranchDn').Text -ceq $script:SelectedBranchDn -and
            [double]::IsNaN((Get-DomeniaControl 'TxtBranchDn').Height)
        }
        Test-PreviewAssertion 'Deplier le DN ne lance aucune recherche' {
            Invoke-DomeniaUxRoute -Route 'WsSearch';Update-PreviewLayout
            $before=$script:SelectedBranchDn;$count=(Get-DomeniaControl 'DgObjects').Items.Count
            (Get-DomeniaControl 'UxOuPathDetails').IsExpanded=$true;Update-PreviewLayout
            (Get-DomeniaControl 'TxtBranchDn').IsVisible -and $script:SelectedBranchDn -ceq $before -and (Get-DomeniaControl 'DgObjects').Items.Count -eq $count
        }
        (Get-DomeniaControl 'UxOuPathDetails').IsExpanded=$false

        Test-PreviewAssertion 'Filtre local respecte le verrouillage de la grille' {
            $grid=Get-DomeniaControl 'DgObjects';$was=$grid.IsEnabled
            try {
                $grid.IsEnabled=$false;Update-PreviewLayout
                -not (Get-DomeniaControl 'TxtSuiteResultFilter').IsEnabled -and -not (Get-DomeniaControl 'BtnSuiteResultClear').IsEnabled
            } finally {$grid.IsEnabled=$was;Update-PreviewLayout}
        }
        Test-PreviewAssertion 'Contrat partage importe avant affichage' {
            $null -ne (Get-SuiteDesign) -and (Get-SuitePalette -Theme 'Dark').BgCard -eq '#182538'
        }
        Test-PreviewAssertion 'Filtre local reduit la grille sans changer le perimetre' {
            (Get-DomeniaControl 'TxtGlobalSearch').Text='';Reset-DomeniaSearchScope
            $before=$script:SelectedBranchDn
            (Get-DomeniaControl 'TxtSuiteResultFilter').Text='PC-DEMO'
            Apply-DomeniaPresenceFilter
            $ok=((Get-DomeniaControl 'DgObjects').Items.Count -eq 1 -and $before -ceq $script:SelectedBranchDn)
            (Get-DomeniaControl 'TxtSuiteResultFilter').Clear();Apply-DomeniaPresenceFilter;$ok
        }
        Test-PreviewAssertion 'Export suit les lignes visibles seulement' {
            $visible=@(Get-DomeniaExperienceVisibleRows)
            @(Get-DomeniaExperienceExportRows $visible @()).Count -eq $visible.Count
        }
        Test-PreviewAssertion 'Operation de mutation jamais annulable dans le suivi' {
            $job=[pscustomobject]@{Id='fixture';Name='Mutation fictive';OperationId='Demo';IsWrite=$true;NonCancellable=$false;CancelRequested=$false;SessionEpoch=1;Started=Get-Date}
            -not (Get-DomeniaExperienceTaskRow $job -SessionEpoch 1).CanCancel
        }
        Test-PreviewAssertion 'Densite compacte ne change pas le jeu de donnees' {
            $before=(Get-DomeniaControl 'DgObjects').Items.Count
            [void](Set-DomeniaComboByContent 'CmbSuiteDensity' 'Compact');Apply-DomeniaExperienceDensity
            $ok=((Get-DomeniaControl 'DgObjects').RowHeight -eq 28 -and (Get-DomeniaControl 'DgObjects').Items.Count -eq $before)
            [void](Set-DomeniaComboByContent 'CmbSuiteDensity' 'Confort');Apply-DomeniaExperienceDensity;$ok
        }
        Test-PreviewAssertion 'Journal reduit masque ses outils sans effacer le texte' {
            $before=(Get-DomeniaControl 'TxtUiLog').Text
            Set-DomeniaExperienceJournalLayout -Collapsed $true
            $ok=((Get-DomeniaControl 'UxSuiteLogTools').Visibility -eq [Windows.Visibility]::Collapsed -and (Get-DomeniaControl 'TxtUiLog').Text -ceq $before)
            Set-DomeniaExperienceJournalLayout -Collapsed $false;$ok
        }
        Test-PreviewAssertion 'Recherche journal suspend seulement le defilement' {
            (Get-DomeniaControl 'TxtUiLog').Text='DEMO Alpha DEMO Beta';(Get-DomeniaControl 'TxtSuiteLogFind').Text='Beta'
            Find-DomeniaExperienceLog
            (Get-DomeniaControl 'TxtUiLog').SelectedText -eq 'Beta' -and -not (Get-DomeniaControl 'ChkUiLogFollow').IsChecked
        }
        Test-PreviewAssertion 'Activite vide ne fabrique pas de reussite' {
            Open-DomeniaExperienceActivity
            (Get-DomeniaControl 'DgSuiteActivity').Items.Count -eq 0 -and (Get-DomeniaControl 'LblSuiteActivityState').Text.Contains('Aucune')
        }
        $failed=@($script:PreviewChecks | Where-Object {-not $_.Passed})
        $report=[ordered]@{Build='2026.09.30-1.0 RC1-PROGRESSIVE';Environment='Windows PowerShell/WPF, local-only';Executed=(Get-Date).ToString('o');Passed=($script:PreviewChecks.Count-$failed.Count);Failed=$failed.Count;Tests=$script:PreviewChecks.ToArray();NoADAccess=$true}
        if([string]::IsNullOrWhiteSpace($ReportPath)){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-interface-'+[guid]::NewGuid().ToString('N')+'.json')}
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if(-not $Quiet){Write-Host ('Rapport : '+$ReportPath);$script:PreviewChecks | Format-Table Name,Passed -AutoSize}
        if($failed.Count -gt 0){throw ('Tests interface en echec : '+$failed.Count+' ; rapport : '+$ReportPath)}
    }
    if (-not [string]::IsNullOrWhiteSpace($CaptureDirectory)) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($CaptureDirectory))
        $script:Window.Width=1600;$script:Window.Height=960;$script:UxHelpVisible=$true;$script:UxLayoutSignature=''
        Reset-DomeniaSearchScope
        foreach($captureRoute in @($CaptureRoutes)) {
        $captureTab=''
        if($captureRoute -match '^(?<route>[^:]+):(?<tab>.+)$'){$captureRoute=$Matches.route;$captureTab=$Matches.tab}
        Invoke-DomeniaUxRoute -Route $captureRoute
        if($captureTab){$tabControl=$script:Window.FindName($captureTab);if($null -ne $tabControl){$tabControl.IsSelected=$true}}
        foreach($captureTheme in @('Light','Dark')) {
            Set-DomeniaUxPalette -Window $script:Window -Theme $captureTheme
            foreach($layout in @('Ouvert','Compact')) {
                $script:UxNavCollapsed=($layout -eq 'Compact')
                $script:UxHelpVisible=($layout -eq 'Ouvert');$script:UxHelpCompactOpen=$script:UxHelpVisible
                $script:UxLayoutSignature='';$script:UxNavLayoutSignature='';Update-PreviewLayout
                $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$script:Window.ActualWidth,[int]$script:Window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($script:Window)
                $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $label=if($captureTab){$captureRoute+'-'+$captureTab}else{$captureRoute}
                $path=Join-Path $CaptureDirectory ('DOMENIA_1.0 RC1_APERCU_'+$label+'_'+$captureTheme+'_'+$layout+'.png')
                $stream=[IO.File]::Create($path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
                Write-Host ('Capture WPF locale de donnees fictives : '+$path)
            }
        }
        }
    }
    if (-not $Verify -and [string]::IsNullOrWhiteSpace($CaptureDirectory)) { [void]$script:Window.ShowDialog() }
} finally {
    if($null -ne $script:Window){$script:Window.Close()}
}
