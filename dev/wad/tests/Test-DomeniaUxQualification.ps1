#requires -Version 5.1
# W13 (points 111 to 116, 119): qualification harness of the interface. Static rules on the real main XAML
# (Get-MainXaml) and on the views of the package, then WPF checks (STA) with the real adapters and inert doubles:
# empty state of the result list, panels inside a short RDP window, zoom without loss of input or focus.
# What stays human (Narrator or NVDA, real DPI change on a second screen) is listed in the report, never claimed.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$core=Join-Path $wad 'Domenia-Core.ps1'
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Check-Suite {param([string]$Name,[scriptblock]$Code)
    try{if(-not (& $Code)){throw 'Condition non verifiee.'};$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
function Get-SuiteFunctionText {param([string]$Path,[string]$Name)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw $errors[0].Message}
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Definition absente : '+$Name)}
    return [string]$nodes[0].Extent.Text
}
function Import-SuiteFunction {param([string]$Path,[string]$Name) . ([scriptblock]::Create((Get-SuiteFunctionText $Path $Name) -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name)))}
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Commands.Model.ps1')){. (Join-Path $modules $file)}
$mainText=[regex]::Match((Get-SuiteFunctionText $core 'Get-MainXaml'),'(?s)@"\s*\n(.*?)\n"@').Groups[1].Value
[xml]$main=$mainText
$x='http://schemas.microsoft.com/winfx/2006/xaml'
$templates=@('ControlTemplate','DataTemplate','ItemsPanelTemplate','Style')
function Get-SuiteElements {
    # Elements of the page itself: templates and styles are skipped, resources too.
    param($Node,[string]$Container='')
    foreach($child in @($Node.ChildNodes)){
        if($child -isnot [Xml.XmlElement]){continue}
        if(($templates -contains $child.LocalName) -or $child.LocalName.EndsWith('.Resources')){continue}
        $here=$Container
        $style=[string]$child.GetAttribute('Style')
        if(($child.LocalName -in @('TabItem','Expander','GroupBox')) -or (($child.LocalName -eq 'Border') -and $style.Contains('Card'))){
            $label=[string]$child.GetAttribute('Name',$x);if(-not $label){$label=[string]$child.GetAttribute('Header')};if(-not $label){$label=$child.LocalName+'@'+[string]$child.GetHashCode()}
            $here=$label
        }
        [pscustomobject]@{Element=$child;Container=$here}
        Get-SuiteElements -Node $child -Container $here
    }
}
$elements=@(Get-SuiteElements -Node $main.DocumentElement)

Check-Suite 'P111 : une seule action principale par carte, onglet ou extenseur (paires independantes listees)' {
    $allowed=@('BtnAccountRemoteSave|BtnAccountSecretsSave','BtnApplyAccountOptions|BtnUserUnlock','BtnDetectUserComputers|BtnRelationPlanRun','BtnLoadBitLocker|BtnLoadLaps')
    $groups=@{}
    foreach($item in $elements){
        $e=$item.Element
        if(($e.LocalName -ne 'Button') -or (-not ([string]$e.GetAttribute('Style')).Contains('RunButton')) -or ([string]$e.GetAttribute('Visibility') -eq 'Collapsed')){continue}
        if(-not $groups.ContainsKey($item.Container)){$groups[$item.Container]=New-Object 'System.Collections.Generic.List[string]'}
        $groups[$item.Container].Add([string]$e.GetAttribute('Name',$x))
    }
    $faults=@(foreach($key in @($groups.Keys)){$names=@($groups[$key]|Sort-Object);if(($names.Count -gt 1) -and ($allowed -notcontains ($names -join '|'))){$key+' : '+($names -join ', ')}})
    if($faults.Count){throw ('Plusieurs actions principales : '+($faults -join ' ; '))}
    $true
}
Check-Suite 'P111 : options avancees repliees par defaut' {
    $open=@($elements|Where-Object{($_.Element.LocalName -eq 'Expander') -and ([string]$_.Element.GetAttribute('IsExpanded') -eq 'True')}|ForEach-Object{[string]$_.Element.GetAttribute('Header')})
    # X04 (P-UX-19): « Reprises » holds the resume actions moved from Fiabilité; its routes (StorageResume, LegacyImport)
    # give the focus to a button inside it, so it stays open.
    $allowed=@('Emplacement et sauvegarde','Stockage local','Reprises')
    $unexpected=@($open|Where-Object{$allowed -notcontains $_})
    if($unexpected.Count){throw ('Extenseurs ouverts : '+($unexpected -join ', '))}
    @($elements|Where-Object{[string]$_.Element.GetAttribute('Name',$x) -eq 'ExpAccountSecurityOptions'}).Count -eq 1
}
Check-Suite 'P112 : couleurs par ressources, aucune couleur fixe nouvelle dans la page et les vues' {
    $fixed=@(foreach($item in $elements){$e=$item.Element;foreach($attribute in @('Foreground','Background','BorderBrush','Fill','Stroke','Tag')){$v=[string]$e.GetAttribute($attribute);if($v -match '^#|^(White|Black|Gray|Red|Green|Blue)$'){$e.LocalName+'.'+$attribute+'='+$v}}})
    # CD-05 (lot Z04): the last three white texts use the OnAccent token; the ratchet is now at zero.
    if($fixed.Count){throw ('Couleurs fixes : '+($fixed -join ', '))}
    foreach($view in @('Domenia-Operations.xaml','Domenia-CommandPalette.xaml')){
        $text=[IO.File]::ReadAllText((Join-Path $modules $view),[Text.Encoding]::UTF8)
        if($text -match '(?i)(Foreground|Background|BorderBrush)="#'){throw ($view+' : couleur fixe')}
    }
    $true
}
Check-Suite 'P112 : echelle typographique fermee et boutons derives du style de base' {
    # W17 (point 112): eight named sizes defined once in the window resources; the page and its views refer to them.
    $expected=[ordered]@{FontSizeCaption='11';FontSizeSmall='12';FontSizeBody='13';FontSizeSubtitle='14';FontSizeSection='16';FontSizeTitle='18';FontSizePageTitle='22';FontSizeDisplay='27'}
    $resources=@($main.DocumentElement.SelectNodes('*[local-name()="Window.Resources"]/*[local-name()="Double"]'))
    $defined=@{};foreach($node in $resources){$defined[[string]$node.GetAttribute('Key',$x)]=[string]$node.InnerText}
    foreach($key in @($expected.Keys)){if([string]$defined[$key] -cne [string]$expected[$key]){throw ('Taille nommee absente ou differente : '+$key+' = '+[string]$defined[$key])}}
    if($defined.Count -ne $expected.Count){throw ('Tailles nommees en trop : '+(@($defined.Keys) -join ', '))}
    $allowed=@($expected.Keys|ForEach-Object{'{DynamicResource '+$_+'}'})
    if([string]$main.DocumentElement.GetAttribute('FontSize') -cne '{DynamicResource FontSizeBody}'){throw 'Taille de la fenetre hors echelle'}
    $sizes=@($elements|ForEach-Object{[string]$_.Element.GetAttribute('FontSize')}|Where-Object{$_}|Select-Object -Unique)
    $outside=@($sizes|Where-Object{$allowed -notcontains $_})
    if($outside.Count){throw ('Tailles hors echelle : '+($outside -join ', '))}
    foreach($view in @(Get-ChildItem -LiteralPath $modules -Filter '*.xaml' -File)){
        $text=[IO.File]::ReadAllText($view.FullName,[Text.Encoding]::UTF8)
        if($text -match 'FontSize="[0-9]'){throw ($view.Name+' : taille de police litterale')}
    }
    $styles=@($main.SelectNodes('//*[local-name()="Style"]')|Where-Object{[string]$_.GetAttribute('TargetType') -eq 'Button'})
    foreach($style in $styles){$key=[string]$style.GetAttribute('Key',$x);if(($key -ne 'BaseButton') -and (-not ([string]$style.GetAttribute('BasedOn')).Contains('BaseButton'))){throw ('Style de bouton isole : '+$key)}}
    $true
}
Check-Suite 'P115 : focus visible, ordre de tabulation naturel, arbre au clavier sans intercepteur' {
    $base=@($main.SelectNodes('//*[local-name()="Style"]')|Where-Object{[string]$_.GetAttribute('Key',$x) -eq 'BaseButton'})[0]
    $focus=@($base.SelectNodes('*[local-name()="Setter"]')|Where-Object{[string]$_.GetAttribute('Property') -eq 'FocusVisualStyle'}).Count -eq 1
    $tabIndex=@($elements|Where-Object{[string]$_.Element.GetAttribute('TabIndex')}).Count
    $tree=@($elements|Where-Object{[string]$_.Element.GetAttribute('Name',$x) -eq 'TvDirectory'})[0].Element
    $keys=@($tree.Attributes|Where-Object{$_.Name -match 'KeyDown|KeyUp'}).Count
    $debounce=(Get-SuiteFunctionText $core 'Set-SelectedBranch').Contains('Get-DomeniaTreeSelectionSource')
    $focus -and ($tabIndex -eq 0) -and ($keys -eq 0) -and $debounce
}
Check-Suite 'P116 : chaque controle interactif affiche a un nom accessible (XAML ou catalogue d aide)' {
    $help=@(Get-Content -LiteralPath (Join-Path $modules 'Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $catalogue=@{};foreach($entry in $help){$catalogue[[string]$entry.Name]=$entry}
    $interactive=@('Button','TextBox','PasswordBox','ComboBox','CheckBox','RadioButton','DataGrid','ListBox','TreeView','Slider','ToggleButton','Expander','TabItem')
    $missing=@(foreach($item in $elements){
        $e=$item.Element
        if(($interactive -notcontains $e.LocalName) -or ([string]$e.GetAttribute('Visibility') -eq 'Collapsed')){continue}
        $name=[string]$e.GetAttribute('Name',$x)
        $label=[string]$e.GetAttribute('AutomationProperties.Name')
        $content=[string]$e.GetAttribute('Content');if(-not $content){$content=[string]$e.GetAttribute('Header')}
        if($label -or (($content.Trim().Length -gt 1) -and (-not $content.StartsWith('&'))) -or ($name -and $catalogue.ContainsKey($name))){continue}
        $e.LocalName+':'+$name
    })
    if($missing.Count){throw ('Sans nom accessible : '+($missing -join ', '))}
    $true
}
Check-Suite 'P116 : chaque etat se lit par un symbole et un mot distincts, jamais par la seule couleur' {
    $statuses=@('Success','Observed','Estimated','Warning','Partial','Error','Refused','Uncertain','Pending','Unknown','Unavailable','Empty','NoChange','Info')
    $glyphs=@($statuses|ForEach-Object{$g=Get-DomeniaStatusGlyph $_;[string]$g.Glyph+'|'+[string]$g.Text})
    ($glyphs.Count -eq @($glyphs|Select-Object -Unique).Count) -and (@($statuses|Where-Object{-not (Get-DomeniaStatusGlyph $_).Recognized}).Count -eq 0)
}
Check-Suite 'P119 : un seul etat vide pour la liste, avec son titre, son texte et sa prochaine action' {
    $empty=@($elements|Where-Object{[string]$_.Element.GetAttribute('Name',$x) -eq 'UxSearchEmpty'})
    $names=@('LblSearchEmptyTitle','LblSearchEmptyText','BtnSearchEmptyNext')
    $inside=@($names|Where-Object{$n=$_;@($empty[0].Element.SelectNodes('.//*')|Where-Object{[string]$_.GetAttribute('Name',$x) -eq $n}).Count -eq 1})
    # UX-03 is a state of this panel (« Le filtre masque N lignes »), never a second overlay.
    $legacy=$mainText.Contains('Aucune ligne à afficher') -or $mainText.Contains('UxSearchFilteredEmpty')
    $init=(Get-SuiteFunctionText (Join-Path $modules 'Domenia-SearchWorkspace.UI.ps1') 'Initialize-DomeniaSearchWorkspace').Contains('Initialize-DomeniaSearchEmptyState')
    ($empty.Count -eq 1) -and ($inside.Count -eq 3) -and (-not $legacy) -and $init
}
Check-Suite 'P114 : Window.DpiChanged passe par le recalage teste ci-dessous (seulement en processus DPI par ecran)' {
    $t=Get-SuiteFunctionText (Join-Path $modules 'Domenia-UX.UI.ps1') 'Initialize-DomeniaUiZoom'
    $t.Contains('Add_DpiChanged({Update-DomeniaUiZoomForDpi})') -and $t.Contains("GetEvent('DpiChanged')")
}
Check-Suite 'P116 : les vues annoncent leurs changements (zones polies : Send-DomeniaUxLiveChange)' {
    $ux=Join-Path $modules 'Domenia-UX.UI.ps1'
    $empty=Get-SuiteFunctionText $ux 'Update-DomeniaSearchEmptyState'
    $trace=Get-SuiteFunctionText (Join-Path $modules 'Domenia-Observability.UI.ps1') 'Update-DomeniaOperationsTraceDetail'
    $activity=Get-SuiteFunctionText (Join-Path $modules 'Domenia-Experience.UI.ps1') 'Update-DomeniaExperienceActivity'
    $empty.Contains("Set-DomeniaLiveText -Control (Get-DomeniaControl 'LblSearchEmptyTitle')") -and $empty.Contains("Set-DomeniaLiveText -Control (Get-DomeniaControl 'LblSearchEmptyText')") -and $trace.Contains("`$label = Get-DomeniaControl 'LblOperationsTrace'") -and $trace.Contains('Set-DomeniaLiveText -Control $label') -and $activity.Contains('Send-DomeniaUxLiveChange -Control $stateLabel') -and (Get-SuiteFunctionText $ux 'Set-DomeniaLiveText').Contains('Send-DomeniaUxLiveChange -Control $Control')
}

# ---------------------------------------------------------------- WPF (STA)
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){
    Check-Suite 'Comportement WPF (STA requis)' {throw 'Fil STA requis : lancer la suite avec -STA.'}
}else{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    function Get-DomeniaControl {param([string]$Name);if($null -eq $script:Ctrl){return $null};return $script:Ctrl[$Name]}
    function Set-Status {param($Text,$Level);$script:Status=[string]$Text}
    function Write-AppLog {param($Text,$Level)}
    function Set-DomeniaContextHint {param($Title,$Text);$script:Hint=[string]$Text}
    function Select-DomeniaWorkspace {param([string]$Workspace,[string]$Inner='',[string]$Tab='') $script:Workspace=$Workspace}
    function Get-DomeniaSearchMode {return 'Global'}
    function ConvertTo-DomeniaErrorInfo {param($ErrorRecordOrException,[string]$Operation) if([string]$ErrorRecordOrException -match 'refus'){return [pscustomobject]@{Kind='AccessDenied'}};return [pscustomobject]@{Kind='Timeout'}}
    function New-DomeniaTimer {param([string]$Owner,[int]$IntervalMs,[scriptblock]$Tick) $t=[pscustomobject]@{Owner=$Owner;Running=$false};$t|Add-Member -MemberType ScriptMethod -Name Start -Value {$this.Running=$true};$t|Add-Member -MemberType ScriptMethod -Name Stop -Value {$this.Running=$false};return $t}
    function Update-DomeniaUxLayout {}
    function Set-DomeniaSetting {param($Name,$Value)}
    function Save-DomeniaSettings {}
    function Pump {param($Window);$Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout()}
    # The live region announcement is recorded: which control the screen reader is told about, in order.
    $script:Announced=New-Object 'System.Collections.Generic.List[string]'
    function Send-DomeniaUxLiveChange {param($Control) if($null -ne $Control){$script:Announced.Add([string]$Control.Name)}}
    $ux=Join-Path $modules 'Domenia-UX.UI.ps1'
    foreach($name in @('Get-DomeniaSearchEmptyInputs','Update-DomeniaSearchEmptyState','Invoke-DomeniaSearchEmptyAction','Initialize-DomeniaSearchEmptyState','Get-DomeniaUxOuDisplay','Get-DomeniaUiZoomLayoutSize','Set-DomeniaUiZoom','Set-DomeniaLiveText','Update-DomeniaUiZoomForDpi')){Import-SuiteFunction $ux $name}
    # UX-03 merged into the one empty state: the filter wording and « Effacer le filtre » are the real ones.
    Import-SuiteFunction (Join-Path $modules 'Domenia-Experience.Model.ps1') 'Get-DomeniaFilteredEmptyState'
    Import-SuiteFunction (Join-Path $modules 'Domenia-Experience.UI.ps1') 'Clear-DomeniaResultFilters'
    Import-SuiteFunction (Join-Path $modules 'Domenia-Experience.UI.ps1') 'Update-DomeniaFilteredEmptyState'
    function Apply-DomeniaPresenceFilter {$script:PresenceApplied=[string]$script:CurrentPresenceFilter}
    $script:DomeniaSearchEmptyTimer=$null;$script:DomeniaSearchEmptyBound=$false
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="1024" Height="720" ShowActivated="False">
  <ScrollViewer x:Name="RootScroll" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto">
    <Grid x:Name="UxShellGrid">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <StackPanel>
        <TextBox x:Name="TxtGlobalSearch"/>
        <TextBox x:Name="TxtSuiteResultFilter"/>
        <ComboBox x:Name="CmbPresenceFilter"><ComboBoxItem Content="Tous" IsSelected="True"/><ComboBoxItem Content="En ligne"/></ComboBox>
      </StackPanel>
      <Grid Grid.Row="1" Height="300">
        <DataGrid x:Name="DgObjects" AutoGenerateColumns="False"><DataGrid.Columns><DataGridTextColumn Header="Nom" Binding="{Binding Name}"/></DataGrid.Columns></DataGrid>
        <Border x:Name="UxSearchEmpty"><StackPanel>
          <TextBlock x:Name="LblSearchEmptyTitle" Text=""/>
          <TextBlock x:Name="LblSearchEmptyText" Text=""/>
          <Button x:Name="BtnSearchEmptyNext" Content=""/>
        </StackPanel></Border>
      </Grid>
    </Grid>
  </ScrollViewer>
</Window>
'@
    [xml]$doc=$xaml;$reader=New-Object Xml.XmlNodeReader $doc
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $script:Window=$window;$script:Ctrl=@{}
    foreach($node in $doc.SelectNodes('//*')){$n=$node.GetAttribute('Name',$x);if($n){$script:Ctrl[$n]=$window.FindName($n)}}
    $window.ShowInTaskbar=$false;$window.WindowStartupLocation='Manual';$window.Left=0;$window.Top=0
    $window.Show();try{[void]$window.Activate()}catch{};Pump $window
    try{
        $grid=$script:Ctrl['DgObjects']
        Check-Suite 'P119 : rien interroge, lecture en cours, aucun resultat, filtre local, refus' {
            $script:Live=$null;$script:CurrentPresenceFilter='Tous'
            Initialize-DomeniaSearchEmptyState;Pump $window
            $nothing=[string]$script:Ctrl['LblSearchEmptyTitle'].Text
            $rows=New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
            $search=[pscustomobject]@{Stopped=$false;Finalized=$false;Final=$null;Error='';Rows=$rows;State=[pscustomobject]@{Search='dupont';SearchMode='Global';BaseDn='DC=example,DC=invalid'}}
            $script:Live=[pscustomobject]@{Search=$search}
            $grid.ItemsSource=$rows;Pump $window
            $running=[string]$script:Ctrl['LblSearchEmptyTitle'].Text
            $timerOn=[bool]$script:DomeniaSearchEmptyTimer.Running
            $search.Finalized=$true;Update-DomeniaSearchEmptyState;Pump $window
            $none=[string]$script:Ctrl['LblSearchEmptyTitle'].Text;$noneText=[string]$script:Ctrl['LblSearchEmptyText'].Text;$noneButton=[string]$script:Ctrl['BtnSearchEmptyNext'].Content
            $rows.Add([pscustomobject]@{Name='PC-01'});$rows.Add([pscustomobject]@{Name='PC-02'});Pump $window
            $shown=$grid.Items.Count
            $script:Ctrl['TxtSuiteResultFilter'].Text='compta'
            [Windows.Data.CollectionViewSource]::GetDefaultView($rows).Filter=[Predicate[object]]{param($row) $false};Pump $window
            $filtered=[string]$script:Ctrl['LblSearchEmptyTitle'].Text;$filteredText=[string]$script:Ctrl['LblSearchEmptyText'].Text;$filteredButton=[string]$script:Ctrl['BtnSearchEmptyNext'].Content
            $script:Ctrl['BtnSearchEmptyNext'].RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));Pump $window
            $cleared=([string]$script:Ctrl['TxtSuiteResultFilter'].Text -eq '')
            [Windows.Data.CollectionViewSource]::GetDefaultView($rows).Filter=$null
            $refusedRows=New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
            $script:Live=[pscustomobject]@{Search=[pscustomobject]@{Stopped=$false;Finalized=$true;Final=$null;Error='Acces refuse';Rows=$refusedRows;State=[pscustomobject]@{Search='';SearchMode='OU';BaseDn='OU=Paris,DC=example,DC=invalid'}}}
            $script:Announced.Clear()
            $grid.ItemsSource=$refusedRows;Pump $window
            $refused=[string]$script:Ctrl['LblSearchEmptyTitle'].Text;$refusedText=[string]$script:Ctrl['LblSearchEmptyText'].Text
            # The verdict is announced once, then its explanation; recomputing the same state announces nothing more.
            $announcedRefusal=($script:Announced.ToArray() -join ',')
            Update-DomeniaSearchEmptyState;Pump $window
            $announcedAgain=$script:Announced.Count
            if($nothing -ne 'Rien nʼa encore été interrogé'){throw ('Depart : '+$nothing)}
            if(($running -ne 'Lecture en cours') -or (-not $timerOn)){throw ('En cours : '+$running)}
            if(($none -ne 'Aucun résultat') -or (-not $noneText.Contains('« dupont »')) -or (-not $noneText.Contains('tout le domaine')) -or ($noneButton -ne 'Élargir le périmètre ou corriger la saisie')){throw ('Aucun resultat : '+$none+' / '+$noneText)}
            if($shown -ne 2){throw 'Lignes non affichees'}
            if(($filtered -ne 'Le filtre masque 2 lignes') -or (-not $filteredText.Contains('texte « compta »')) -or (-not $filteredText.Contains('sans requête AD')) -or ($filteredButton -ne 'Effacer le filtre') -or (-not $cleared) -or ($script:PresenceApplied -ne 'Tous')){throw ('Filtre : '+$filtered+' / '+$filteredText)}
            if(($refused -ne 'Lecture refusée') -or (-not $refusedText.Contains('(Paris)'))){throw ('Refus : '+$refused+' / '+$refusedText)}
            if(($announcedRefusal -ne 'LblSearchEmptyTitle,LblSearchEmptyText') -or ($announcedAgain -ne 2)){throw ('Annonces : '+$announcedRefusal+' puis '+$announcedAgain)}
            Test-DomeniaNoAbsenceClaim ($none+' '+$noneText+' '+$filteredText+' '+$refusedText)
        }
        Check-Suite 'P119 avec UX-03 : une copie filtree de la liste dit combien de lignes le filtre masque' {
            $script:Live=$null;$script:CurrentPresenceFilter='Tous';$script:DomeniaListFilterCounts=$null
            $script:Ctrl['TxtSuiteResultFilter'].Text='compta'
            # As Set-DomeniaItemsSource: the counts of the whole list come with the copy, then the grid takes the copy.
            $copy=New-Object System.Collections.ArrayList
            Update-DomeniaFilteredEmptyState -Loaded 48 -Visible 0 -Source $copy
            $script:Announced.Clear()
            $grid.ItemsSource=$null;Pump $window
            $between=$script:Announced.Count
            $grid.ItemsSource=$copy;Pump $window
            $title=[string]$script:Ctrl['LblSearchEmptyTitle'].Text;$text=[string]$script:Ctrl['LblSearchEmptyText'].Text;$next=[string]$script:Ctrl['BtnSearchEmptyNext'].Tag
            # Another list never inherits these counts.
            $other=New-Object System.Collections.ArrayList
            $grid.ItemsSource=$other;Pump $window
            $after=[string]$script:Ctrl['LblSearchEmptyTitle'].Text
            $script:Ctrl['TxtSuiteResultFilter'].Text='';$grid.ItemsSource=$null;$script:DomeniaListFilterCounts=$null
            if(($between -ne 0) -or ($title -ne 'Le filtre masque 48 lignes') -or (-not $text.Contains('texte « compta »')) -or ($next -ne 'ClearLocalFilter') -or ($after -eq $title)){throw ('Copie filtree : '+$between+' annonce(s) entre deux listes, '+$title+' / '+$text+' / '+$next+' puis '+$after)}
            $true
        }
        Check-Suite 'P114 : zoom de 80 a 150 % sans perte de saisie, de curseur ni de focus' {
            $box=$script:Ctrl['TxtGlobalSearch'];$box.Text='saisie en cours';[void]$box.Focus();$box.CaretIndex=6;Pump $window
            $ok=$true
            foreach($percent in @(80,100,120,150,100)){
                Set-DomeniaUiZoom -Percent $percent;Pump $window
                $shell=$script:Ctrl['UxShellGrid']
                if(($box.Text -ne 'saisie en cours') -or ($box.CaretIndex -ne 6)){$ok=$false}
                if(-not [object]::ReferenceEquals([Windows.Input.FocusManager]::GetFocusedElement($window),$box)){$ok=$false}
                if([Math]::Abs($shell.LayoutTransform.ScaleX-($percent/100.0)) -gt 0.001){$ok=$false}
            }
            $ok
        }
        Check-Suite 'P114 : recalage sur changement de DPI : zoom garde, saisie, curseur et focus intacts' {
            # Window.DpiChanged cannot be raised by a test (its arguments are internal to WPF): its handler is run directly.
            $box=$script:Ctrl['TxtGlobalSearch'];$box.Text='saisie en cours';[void]$box.Focus();$box.CaretIndex=4;Pump $window
            Set-DomeniaUiZoom -Percent 120;Pump $window
            $shell=$script:Ctrl['UxShellGrid'];$shell.Width=10;$shell.Height=10
            Update-DomeniaUiZoomForDpi;Pump $window
            $refitted=($shell.Width -gt 10) -and ($shell.Height -gt 10)
            $kept=($box.Text -eq 'saisie en cours') -and ($box.CaretIndex -eq 4) -and [object]::ReferenceEquals([Windows.Input.FocusManager]::GetFocusedElement($window),$box)
            $refitted -and $kept -and ([Math]::Abs($shell.LayoutTransform.ScaleX-1.2) -lt 0.001) -and ([int]$script:DomeniaUiZoomPercent -eq 120)
        }
    }finally{try{$window.Close()}catch{}}
    Check-Suite 'P113 : panneau des operations et palette tiennent dans une fenetre RDP courte (1024x768 a 150 %)' {
        $layerWindow=New-Object Windows.Window;$layerWindow.Width=683;$layerWindow.Height=480;$layerWindow.ShowInTaskbar=$false;$layerWindow.ShowActivated=$false
        $layer=New-Object Windows.Controls.Grid;$layerWindow.Content=$layer;$layerWindow.Show();Pump $layerWindow
        try{
            Import-SuiteFunction (Join-Path $modules 'Domenia-Experience.UI.ps1') 'Set-DomeniaOperationsPanelPosition'
            . (Join-Path $modules 'Domenia-Commands.UI.ps1')
            $ok=$true
            foreach($view in @('Domenia-Operations.xaml','Domenia-CommandPalette.xaml')){
                [xml]$d=[IO.File]::ReadAllText((Join-Path $modules $view),[Text.Encoding]::UTF8);$r=New-Object Xml.XmlNodeReader $d
                $panel=[Windows.Markup.XamlReader]::Load($r);$layer.Children.Clear();[void]$layer.Children.Add($panel);Pump $layerWindow
                if($view -eq 'Domenia-Operations.xaml'){$script:OperationsPanel=[pscustomobject]@{View=$panel;Layer=$layer};Set-DomeniaOperationsPanelPosition}
                else{$script:CommandPalette=[pscustomobject]@{View=$panel;Layer=$layer;Open=$true};Set-DomeniaCommandPalettePosition}
                Pump $layerWindow
                $point=$panel.TranslatePoint([Windows.Point]::new(0,0),$layer)
                if(($point.X -lt 0) -or (($point.X+$panel.ActualWidth) -gt ($layer.ActualWidth+0.5)) -or (($point.Y+$panel.ActualHeight) -gt ($layer.ActualHeight+0.5))){$ok=$false}
                if(($view -eq 'Domenia-Operations.xaml') -and ($panel.Child -isnot [Windows.Controls.ScrollViewer])){$ok=$false}
            }
            $ok
        }finally{$layerWindow.Close()}
    }
}
$human=@('Lecteur d ecran (Narrateur ou NVDA) sur les pages principales, la palette et le panneau des operations','Changement reel de DPI : fenetre deplacee entre deux ecrans de mises a l echelle differentes, puis changement de mise a l echelle a chaud','Parcours au clavier complet par un operateur (ordre de tabulation, focus visible sur chaque page)','Session RDP reelle 1024x768 et 1280x720')
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaUxQualification';Runtime=$PSVersionTable.PSVersion.ToString();Executed=(Get-Date).ToString('o');Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;WpfExecuted=([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA);NoADAccess=$true;NoNetwork=$true;HumanQualificationRemaining=$human;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-uxqualification-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($failed.Count){throw ('Qualification interface en echec : '+$failed.Count)}
