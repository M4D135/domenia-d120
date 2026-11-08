#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$PureOnly)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$results=[Collections.Generic.List[object]]::new()
$script:GeometryEvidence=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Value,[string]$Why);if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}
}
function Read-Ast {param([string]$Path)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Expect (@($errors).Count -eq 0) ($errors|Out-String);return $ast
}
function Import-Function {param($Ast,[string]$Name)
    $found=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    Expect ($found.Count -eq 1) ('Fonction absente ou ambiguë : '+$Name)
    . ([scriptblock]::Create(($found[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))))
}
function New-Owner {
    $grid=[pscustomobject]@{IsEnabled=$false;ItemsSource='initial';SelectedItem=$null;Items=[Collections.ArrayList]::new()}
    [pscustomobject]@{Kind='Machine';Closed=$false;RequestId='current';Job='job';Selected=$null;Window=$null;Epoch=7;BaseDn='DC=example,DC=invalid';
        Go=[pscustomobject]@{IsEnabled=$false};Box=[pscustomobject]@{IsEnabled=$false;Text='PC'};Grid=$grid;Tree=$grid;
        Accept=[pscustomobject]@{IsEnabled=$false};Busy=[pscustomobject]@{Visibility='Visible'};Path=[pscustomobject]@{Text=''};
        Status=[pscustomobject]@{Text='initial'};Mode='Navigation';ActiveNode=$null;RootNode=$null}
}
function New-State {param($Owner)
    [pscustomobject]@{Owner=$Owner;RequestId='current';Epoch=7;BaseDn='DC=example,DC=invalid';Verify=$false;Mode='Search';Node=$null;DN='';Guid=''}
}
function Get-DomeniaControl {param($Name);return $script:Controls[$Name]}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Set-DomeniaSurfaceResult {param($Window,[bool]$Result);$script:SurfaceAccepted=$Result}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stops.Add([string]$Id)}
function Set-DomeniaSetting {param($Name,$Value);$script:Settings[$Name]=$Value}
function Save-DomeniaSettings {$script:Saves++}
function Get-DomeniaSetting {param($Name,$Default);if($script:Settings.ContainsKey($Name)){return $script:Settings[$Name]};return $Default}
function Get-DomeniaEmbeddedContext {return [pscustomobject]@{Epoch=$script:SessionEpoch;BaseDn=$script:Conn.BaseDn;Closing=$false}}
function Get-DomeniaEmbeddedLookupCode {return 'throw "No worker is run by this test"'}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$TimeoutSeconds,$SuccessHandler,$ErrorHandler);$script:StartUiTaskCalls++;$script:LastState=$CallbackState;return $null}

$ux=Read-Ast (Join-Path $wad 'modules/Domenia-UX.UI.ps1')
$embedded=Read-Ast (Join-Path $wad 'modules/Domenia-Embedded.UI.ps1')
foreach($name in @('Get-DomeniaUxAvailableSize','Get-DomeniaUxHeightPlan','Get-DomeniaUxLayoutPlan','Get-DomeniaUiZoomLayoutSize','Set-DomeniaUiZoom','Initialize-DomeniaUiZoom','Update-DomeniaUxLayout','Switch-DomeniaUxHelp','Set-DomeniaUxShortLayout','Set-DomeniaSearchQueryOptionsLayout')){Import-Function $ux $name}
foreach($name in @('Complete-DomeniaEmbeddedLookup','Fail-DomeniaEmbeddedLookup','Complete-DomeniaOuPickerRead','Fail-DomeniaOuPickerRead','Stop-DomeniaOuPickerRead','Start-DomeniaOuPickerRead','Show-DomeniaOuPickerNavigation','New-DomeniaOuPickerNode')){Import-Function $embedded $name}
# Exercise the actual picker click closure without opening a window or admitting a network worker.
$picker=$embedded.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-DomeniaInlinePicker'},$true)[0]
$assignment=$picker.Body.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$run'},$true)[0]
$runAst=$assignment.Right.FindAll({param($n)$n -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true)[0].ScriptBlock
$pickerRun=$runAst.GetScriptBlock()
$script:SessionEpoch=7;$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'}
$script:Controls=@{};$script:Stops=[Collections.Generic.List[string]]::new();$script:Settings=@{};$script:Saves=0

Case 'Viewport : le zoom utilise la place utile, sans le pied de fenêtre' {
    $script:Window=[pscustomobject]@{ActualWidth=1920;ActualHeight=1080;Width=1920;Height=1080}
    $script:Controls=@{RootScroll=[pscustomobject]@{ViewportWidth=1900;ViewportHeight=1000}}
    $script:DomeniaUiZoomPercent=150;$size=Get-DomeniaUxAvailableSize
    Expect ([Math]::Abs($size.Width-(1900.0/1.5)) -lt 0.001) 'La largeur ignore le zoom ou le viewport.'
    Expect ([Math]::Abs($size.Height-(1000.0/1.5)) -lt 0.001) 'La hauteur inclut encore le pied de fenêtre.'
    $plan=Get-DomeniaUxHeightPlan -Width $size.Width -Height $size.Height
    Expect ($plan.Short -and $plan.LowHeight -and $plan.FoldNavigation) 'Le zoom 150 % doit activer la disposition compacte.'
    $script:DomeniaUiZoomPercent=100;$size=Get-DomeniaUxAvailableSize
    $plan=Get-DomeniaUxHeightPlan -Width $size.Width -Height $size.Height
    Expect (-not $plan.Short -and -not $plan.LowHeight -and -not $plan.FoldNavigation) 'Retour à 100 % sans restauration de la disposition.'
}
Case 'Viewport : minimums identiques au shell, et réduction à 80 %' {
    $script:Controls.RootScroll.ViewportWidth=800;$script:Controls.RootScroll.ViewportHeight=600
    $script:DomeniaUiZoomPercent=150;$size=Get-DomeniaUxAvailableSize
    Expect ($size.Width -eq 900 -and $size.Height -eq 450) 'Les minimums de défilement divergent du shell.'
    $script:DomeniaUiZoomPercent=80;$size=Get-DomeniaUxAvailableSize
    Expect ($size.Width -eq 1000 -and $size.Height -eq 750) 'Le zoom 80 % ne libère pas la place attendue.'
}
Case 'Viewport : ouverture avant mesure, préférence de zoom absente' {
    $script:Controls=@{};$script:DomeniaUiZoomPercent=0
    $script:Window=[pscustomobject]@{ActualWidth=0;ActualHeight=0;Width=1280;Height=720}
    $size=Get-DomeniaUxAvailableSize
    Expect ($size.Width -eq 1280 -and $size.Height -eq 720) 'Le premier calcul doit utiliser la taille prévue à 100 %.'
}
Case 'Disposition : la largeur logique pilote le plan avant les contrôles WPF' {
    $script:Window=[pscustomobject]@{ActualWidth=1920;ActualHeight=1080;Width=1920;Height=1080}
    $script:Controls=@{RootScroll=[pscustomobject]@{ViewportWidth=1900;ViewportHeight=1000}}
    $script:UxShortScreen=$false;$script:DomeniaUiZoomPercent=150
    function Update-DomeniaUxSidebar {}
    Update-DomeniaUxLayout
    Expect ($script:UxShortScreen -and $script:UxShortNavFold) 'Update-DomeniaUxLayout utilise encore la fenêtre extérieure.'
}
Case 'Disposition : options de requête réservées aux hauteurs inférieures à 560' {
    Expect ((Get-DomeniaUxHeightPlan -Width 1000 -Height 559).TinyHeight) 'La surface de 559 unités doit proposer les options compactes.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 1000 -Height 560).TinyHeight) 'Les options ne doivent pas se replier à 560 unités.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 1000 -Height 0).TinyHeight) 'Une mesure absente ne prouve pas une petite surface.'
}
Case 'Disposition : options compactes selon largeur et hauteur, indépendantes des marges très basses' {
    $narrow=Get-DomeniaUxHeightPlan -Width 1099 -Height 939
    Expect ($narrow.QueryOptionsCompact -and -not $narrow.TinyHeight -and -not $narrow.LowHeight) 'Une fenêtre étroite replie les options sans adopter les marges ou la colonne OU très compactes.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 1100 -Height 939).QueryOptionsCompact) 'La largeur1100 ne doit pas déclencher seule le repli.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 1099 -Height 940).QueryOptionsCompact) 'La hauteur940 conserve la barre complète.'
    Expect ((Get-DomeniaUxHeightPlan -Width 1900 -Height 559).QueryOptionsCompact) 'Une surface très basse replie les options même si elle est large.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 1900 -Height 560).QueryOptionsCompact) 'Une surface large de560 unités garde la barre complète.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 0 -Height 800).QueryOptionsCompact) 'Une largeur absente ne prouve pas une fenêtre étroite.'
    Expect (-not (Get-DomeniaUxHeightPlan -Width 1000 -Height 0).QueryOptionsCompact) 'Une hauteur absente ne doit pas déclencher le repli.'
}
Case 'Sélecteur : admission refusée, contrôles utilisables et motif affiché' {
    $r=New-Owner;$r.Job='';$r.Box.IsEnabled=$true;$r.Grid.IsEnabled=$true;$r.Go.IsEnabled=$true
    $fnContext=${function:Get-DomeniaEmbeddedContext};$fnLookupCode=${function:Get-DomeniaEmbeddedLookupCode};$fnStartTask=${function:Start-UiTask}
    & $pickerRun $false
    Expect (-not $r.Job -and $r.Box.IsEnabled -and $r.Grid.IsEnabled -and $r.Go.IsEnabled) 'Un refus du moteur bloque le sélecteur.'
    Expect ($r.Busy.Visibility -eq 'Hidden' -and $r.Status.Text -match 'non admise') 'La progression reste active ou le refus est invisible.'
    Expect (-not $r.Accept.IsEnabled -and $null -eq $r.Selected) 'Un refus a validé un choix.'
}
Case 'Sélecteur : ancien gestionnaire après fermeture sans nouvelle soumission' {
    $r=New-Owner;$r.Job='';$r.Closed=$true
    $fnContext={throw 'Contexte demandé après fermeture'};$fnLookupCode={throw 'Code demandé après fermeture'};$fnStartTask={throw 'Tâche démarrée après fermeture'}
    & $pickerRun $false
    Expect ($r.Status.Text -eq 'initial' -and $r.RequestId -eq 'current') 'Un événement de panneau fermé a changé son état.'
}
foreach($callback in @('Complete-DomeniaEmbeddedLookup','Fail-DomeniaEmbeddedLookup','Complete-DomeniaOuPickerRead','Fail-DomeniaOuPickerRead')){
    foreach($reason in @('Closed','RequestId','Epoch','BaseDn')){
        Case ($callback+' : retour ignoré pour '+$reason) {
            $owner=New-Owner;$state=New-State $owner
            switch($reason){'Closed'{$owner.Closed=$true}'RequestId'{$state.RequestId='old'}'Epoch'{$state.Epoch=6}'BaseDn'{$state.BaseDn='DC=other,DC=invalid'}}
            & $callback $null $state
            Expect ($owner.Status.Text -eq 'initial' -and $owner.Job -eq 'job' -and -not $owner.Go.IsEnabled) 'Un ancien retour a modifié le panneau.'
        }
    }
}
Case 'Sélecteur : un retour courant remplit la liste sans valider automatiquement' {
    $owner=New-Owner;$state=New-State $owner
    $row=[pscustomobject]@{Name='PC-TEST';DN='CN=PC-TEST,DC=example,DC=invalid';Guid='test'}
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@($row);RequestId='current';Verified=$false;Capped=$false}) $state
    Expect ($owner.Grid.ItemsSource.Count -eq 1 -and $owner.Go.IsEnabled -and $owner.Busy.Visibility -eq 'Hidden') 'Le retour courant est perdu.'
    Expect (-not $owner.Accept.IsEnabled -and $null -eq $owner.Selected) 'La recherche a choisi implicitement un objet.'
}
Case 'OU : annulation invalide la réponse avant de stopper le worker' {
    $owner=New-Owner;$state=New-State $owner
    $node=[pscustomobject]@{Tag=[pscustomobject]@{Loading=$true;Loaded=$false};IsExpanded=$true};$owner.ActiveNode=$node
    Stop-DomeniaOuPickerRead $owner
    Expect ($owner.RequestId -cne 'current' -and -not $owner.Job -and $script:Stops.Contains('job')) 'La lecture ne peut pas être invalidée.'
    Expect (-not $node.Tag.Loading -and -not $node.IsExpanded -and $null -eq $owner.ActiveNode) 'La branche annulée reste marquée en cours.'
    Complete-DomeniaOuPickerRead $null $state
    Expect ($owner.Status.Text -eq 'initial' -and $owner.Tree.IsEnabled -and -not $owner.Accept.IsEnabled) 'Une réponse annulée a repeuplé le panneau.'
}
Case 'OU : admission refusée restaure la branche pour un nouvel essai' {
    $owner=New-Owner;$owner.Job='';$owner.Kind='OU'
    $node=[pscustomobject]@{Tag=[pscustomobject]@{Loading=$false;Loaded=$false;DN=$owner.BaseDn};Items=[Collections.ArrayList]::new()}
    Start-DomeniaOuPickerRead -Owner $owner -Mode Children -Node $node
    Expect (-not $owner.Job -and $owner.Tree.IsEnabled -and $owner.Go.IsEnabled -and $owner.Busy.Visibility -eq 'Hidden') 'Lʼarbre reste bloqué.'
    Expect (-not $node.Tag.Loading -and -not $node.Tag.Loaded -and $node.Items.Count -eq 1) 'La branche ne permet plus de réessayer.'
}
Case 'OU : connexion changée avant clic, aucune lecture admise' {
    $owner=New-Owner;$owner.Job='';$owner.Epoch=6;$script:LastState=$null
    Start-DomeniaOuPickerRead -Owner $owner -Mode Search
    Expect ($null -eq $script:LastState -and $owner.Status.Text -match 'connexion a changé') 'Un sélecteur ancien a lu le nouveau domaine.'
}

if(-not $PureOnly){
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'La qualification WPF exige Windows ; utilisez -PureOnly pour les seuls tests purs.'}
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Case 'WPF : les boutons de zoom recalculent la disposition, une seule fois par geste' {
        $script:Controls=@{UxShellGrid=[Windows.Controls.Grid]::new();RootScroll=[Windows.Controls.ScrollViewer]::new();BtnUiZoomOut=[Windows.Controls.Button]::new();BtnUiZoomIn=[Windows.Controls.Button]::new();BtnUiZoomReset=[Windows.Controls.Button]::new()}
        $script:LayoutCalls=0
        function Update-DomeniaUxLayout {$script:LayoutCalls++}
        Initialize-DomeniaUiZoom;Initialize-DomeniaUiZoom
        $before=$script:LayoutCalls
        $script:Controls.BtnUiZoomIn.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($script:LayoutCalls -eq ($before+1) -and $script:DomeniaUiZoomPercent -eq 110) 'Le zoom a perdu ou doublé son gestionnaire.'
        Expect ($script:Settings['Ui.ZoomPercent'] -eq 110) 'Le zoom nʼest pas enregistré.'
        foreach($zoom in @(80,150,100)){
            Set-DomeniaUiZoom $zoom
            Expect ($script:Controls.UxShellGrid.LayoutTransform.ScaleX -eq ($zoom/100.0)) 'Transformation de zoom incorrecte.'
            Expect ($script:Controls.BtnUiZoomOut.IsEnabled -eq ($zoom -gt 80) -and $script:Controls.BtnUiZoomIn.IsEnabled -eq ($zoom -lt 150)) 'Bornes des boutons de zoom incorrectes.'
        }
    }
    Case 'WPF : réouverture du shell, nouveaux boutons reliés et zoom restauré' {
        $script:Controls=@{UxShellGrid=[Windows.Controls.Grid]::new();RootScroll=[Windows.Controls.ScrollViewer]::new();BtnUiZoomOut=[Windows.Controls.Button]::new();BtnUiZoomIn=[Windows.Controls.Button]::new();BtnUiZoomReset=[Windows.Controls.Button]::new()}
        function Update-DomeniaUxLayout {}
        $script:Settings['Ui.ZoomPercent']=130;Initialize-DomeniaUiZoom
        Expect ($script:DomeniaUiZoomPercent -eq 130 -and $script:Controls.BtnUiZoomReset.Content -eq '130 %') 'La réouverture a perdu le zoom enregistré.'
        $script:Controls.BtnUiZoomReset.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($script:DomeniaUiZoomPercent -eq 100) 'Le bouton de la nouvelle fenêtre nʼest pas relié.'
    }
    Case 'WPF : compacité des requêtes sans imposer de largeur au Grid' {
        $script:Controls=@{};$script:Window=[Windows.Window]::new()
        $bar=[Windows.Controls.Grid]::new();$row=[Windows.Controls.Grid]::new();$view=[Windows.Controls.ComboBox]::new()
        [void]$bar.Children.Add($row);[void]$row.Children.Add($view)
        $script:Controls.UxSearchQueryBar=$bar;$script:Controls.CmbWorkView=$view
        function Set-DomeniaExperienceJournalLayout {param([bool]$Collapsed,[switch]$Transient)}
        $script:UxLogCollapsed=$true
        Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 600)
        Expect ([double]::IsNaN($bar.Width) -and [double]::IsNaN($row.Width) -and $view.MinHeight -eq 28) 'Le compact contraint la largeur de la barre.'
        Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1900 -Height 1000)
        Expect ($view.MinHeight -eq 34 -and $bar.Margin.Top -eq 6) 'Les dimensions normales ne sont pas restaurées.'
        $script:Window.Close()
    }
    Case 'WPF : navigation OU française, validation réservée aux vraies OU' {
        $owner=New-Owner;$owner.Kind='OU';$owner.Tree=[Windows.Controls.TreeView]::new();$owner.Job='job'
        $node=New-DomeniaOuPickerNode -Owner $owner -Dn $owner.BaseDn -Name 'Domaine'
        [void]$owner.Tree.Items.Add($node)
        $state=New-State $owner;$state.Mode='Children';$state.Node=$node
        function Get-DomeniaRawDnParent {param([string]$DN);return ($DN -split ',',2)[1]}
        $rows=@(
            [pscustomobject]@{Name='Zulu';DN='OU=Zulu,DC=example,DC=invalid';Type='OU';Guid='z'},
            [pscustomobject]@{Name='Équipe';DN='OU=Équipe,DC=example,DC=invalid';Type='OU';Guid='e'},
            [pscustomobject]@{Name='Alpha';DN='OU=Alpha,DC=example,DC=invalid';Type='OU';Guid='a'},
            [pscustomobject]@{Name='Autre domaine';DN='OU=Other,DC=other,DC=invalid';Type='OU';Guid='x'})
        Complete-DomeniaOuPickerRead ([pscustomobject]@{Rows=$rows;RequestId='current';Verified=$false;Capped=$false}) $state
        Expect (($node.Items.Header -join '|') -eq 'Alpha|Équipe|Zulu') 'Ordre français ou contrôle du parent incorrect.'
        Expect (-not $owner.Accept.IsEnabled -and $node.Tag.Loaded) 'Une branche a été choisie automatiquement.'
    }
    Case 'WPF : options compactes, clavier, choix conservés et restauration sans lecture' {
        foreach($name in @('Update-DomeniaUxLayout','Test-DomeniaUxNavFolded','Update-DomeniaUxSidebar','Set-DomeniaUxHeaderLayout')){Import-Function $ux $name}
        $core=Read-Ast (Join-Path $wad 'Domenia-Core.ps1')
        foreach($name in @('Get-MainXaml','Get-DomeniaXamlControlNames')){Import-Function $core $name}
        $script:Controls=@{};$xaml=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)
        $script:Window=[Windows.Markup.XamlReader]::Parse($xaml)
        foreach($name in @(Get-DomeniaXamlControlNames $xaml)){$control=$script:Window.FindName($name);if($null -ne $control){$script:Controls[$name]=$control}}
        $script:Window.Width=1000;$script:Window.Height=700;$script:Window.ShowInTaskbar=$false
        $script:Window.WindowStartupLocation='Manual';$script:Window.Left=0;$script:Window.Top=0
        [Windows.Controls.ToolTipService]::SetIsEnabled($script:Window,$false)
        $script:Controls.WorkspaceTabs.SelectedItem=$script:Controls.WsSearch
        $script:Controls.CmbWorkView.ItemsSource=@([pscustomobject]@{DisplayName='Postes actifs';Id='a'},[pscustomobject]@{DisplayName='Disques à vérifier';Id='b'})
        $script:Controls.CmbWorkView.SelectedIndex=1
        $script:Controls.TxtSearchQueryFilter.Text='disque'
        $script:Controls.ChkSearchQueryFavorites.IsChecked=$true
        $script:Controls.CmbSearchQueryResult.Visibility='Visible';$script:Controls.CmbSearchQueryResult.SelectedIndex=1
        $script:Controls.LblSearchQuery.Text='5000 postes recensés · 417 inconnus affichés · données locales · couverture complète du 13/10/2026 · OU=Postes,OU=Production,OU=Lyon,OU=France,DC=example,DC=invalid'
        $script:Controls.LblSearchQueryDetails.Text='Source : données locales · OU=Postes,OU=Production,OU=Lyon,OU=France,DC=example,DC=invalid · Avec les sous-OU'
        $script:OptionExecutions=0;$script:LastState=$null;$script:StartUiTaskCalls=0;$script:OptionsGlobalSearchCalls=0
        function Invoke-GlobalSearch {$script:OptionsGlobalSearchCalls++}
        function InvokeGlobalSearch {$script:OptionsGlobalSearchCalls++}
        $script:Controls.BtnWorkView.Add_Click({$script:OptionExecutions++})
        $button=$script:Controls.BtnSearchQueryOptions;$panel=$script:Controls.UxSearchQueryOptionsScroll
        $script:UxLogCollapsed=$true
        $script:UxLayoutSignature='';$script:UxNavLayoutSignature='';$script:UxNavCollapsed=$false;$script:UxHelpVisible=$true;$script:UxHelpCompactOpen=$false
        $script:UxShortScreen=$false;$script:UxShortHelpOpen=$false;$script:UxShortLogHeld=$false;$script:UxShortLogReleased=$false;$script:UxShortNavFold=$false;$script:UxShortNavReleased=$false
        $script:DomeniaUiZoomPercent=100
        function Invoke-OptionsKey {param($Control,[Windows.Input.Key]$Key,[switch]$Preview)
            # Synthetic native WPF key events: no OS keyboard injection, AD or application startup.
            $source=[Windows.PresentationSource]::FromVisual($Control)
            Expect ($null -ne $source) 'Le contrôle clavier doit appartenir à un vrai HWND.'
            $down=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$source,0,$Key)
            $down.RoutedEvent=if($Preview){[Windows.Input.Keyboard]::PreviewKeyDownEvent}else{[Windows.Input.Keyboard]::KeyDownEvent}
            $down.Source=$Control;$Control.RaiseEvent($down)
            if(-not $Preview){
                $up=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$source,1,$Key)
                $up.RoutedEvent=[Windows.Input.Keyboard]::KeyUpEvent;$up.Source=$Control;$Control.RaiseEvent($up)
            }
            $script:Window.UpdateLayout()
            return $down.Handled
        }
        try{
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 1000)
            $parents=@{};foreach($name in @('UxSearchQueryHeader','LblSearchQueryDetails','UxSearchQueryResultBar','CmbWorkViewScope','BtnSearchQueryFavorite','BtnQueryClearSearch')){$parents[$name]=$script:Controls[$name].Parent}
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 500)
            # UI-23: the two parts of « Vérifier la liste ▾ » stay joined; the spacing of the row goes on their panel.
            $verify=$script:Controls.BtnParkVerify
            Expect ($verify.Margin -eq [Windows.Thickness]::new(0) -and $verify.Parent.Margin -eq [Windows.Thickness]::new(0,0,4,4) -and $script:Controls.BtnParkVerifyMenu.Margin -eq [Windows.Thickness]::new(1,0,0,0) -and $verify.Padding -eq [Windows.Thickness]::new(6,4,6,4)) 'Vérifier la liste est séparé de sa flèche en mode compact.'
            $state=$button.Resources['Domenia.QueryOptions']
            Expect ($state.Compact -and -not $state.Open -and $button.Visibility -eq 'Visible' -and $panel.Visibility -eq 'Collapsed') 'Le premier mode compact doit laisser les options fermées.'
            Expect ($button.IsTabStop -and $button.Focusable -and $button.Content -match 'Inconnus') 'Le bouton doit être accessible au clavier et annoncer le filtre choisi.'
            Expect ([object]::ReferenceEquals($script:Controls.BtnQueryClearSearch.Parent,$script:Controls.UxSearchScopeInfo) -and $script:Controls.BtnQueryClearSearch.Content -eq 'Effacer') 'Effacer doit rester hors du volet compact.'
            $script:Window.Show();$script:Window.UpdateLayout()
            # The real full layout also folds the navigation and the help column at1000px.
            # This HWND hosts keyboard/focus behavior; Geometry independently covers the tiny viewport.
            Update-DomeniaUxLayout;$script:Window.UpdateLayout()
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 500)
            $script:Window.UpdateLayout();[void]$button.Focus()
            foreach($visibleControl in @($button,$script:Controls.BtnQueryClearSearch)){
                $root=$script:Window.Content
                $bounds=$visibleControl.TransformToAncestor($root).TransformBounds([Windows.Rect]::new(0,0,$visibleControl.ActualWidth,$visibleControl.ActualHeight))
                $shown=$bounds;$shown.Intersect([Windows.Rect]::new(0,0,$root.ActualWidth,$root.ActualHeight))
                $ancestor=$visibleControl
                while($null -ne $ancestor -and -not [object]::ReferenceEquals($ancestor,$root)){
                    $clip=[Windows.Media.VisualTreeHelper]::GetClip($ancestor)
                    if($null -ne $clip){$shown.Intersect($ancestor.TransformToAncestor($root).TransformBounds($clip.Bounds))}
                    if($ancestor.ClipToBounds -or $ancestor -is [Windows.Controls.ScrollContentPresenter]){$shown.Intersect($ancestor.TransformToAncestor($root).TransformBounds([Windows.Rect]::new(0,0,$ancestor.RenderSize.Width,$ancestor.RenderSize.Height)))}
                    $ancestor=[Windows.Media.VisualTreeHelper]::GetParent($ancestor)
                }
                $full=($visibleControl.IsVisible -and $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and $shown.Width -ge ($bounds.Width-1) -and $shown.Height -ge ($bounds.Height-1))
                $script:GeometryEvidence.Add([pscustomobject]@{Scenario='Compact query options with long active scope';Control=$visibleControl.Name;Width=$bounds.Width;Height=$bounds.Height;VisibleWidth=[Math]::Max([double]0,$shown.Width);VisibleHeight=[Math]::Max([double]0,$shown.Height);FullyVisible=$full;WindowWidth=$script:Window.ActualWidth;WindowHeight=$script:Window.ActualHeight;Rendering='Presented native WPF HWND; synthetic routed key events, no OS input injection'})
                Expect $full ($visibleControl.Name+' est coupé dans le résumé compact de la requête active.')
            }
            [void](Invoke-OptionsKey $button ([Windows.Input.Key]::Enter))
            Expect ($state.Open -and $panel.Visibility -eq 'Visible') 'Entrée nʼouvre pas les options par le vrai bouton WPF.'
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 500)
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 500)
            Expect ($state.Open -and $panel.Visibility -eq 'Visible' -and $panel.MaxHeight -le 80) 'Un nouveau layout perd lʼouverture ou la borne du volet.'
            [void](Invoke-OptionsKey $button ([Windows.Input.Key]::Space))
            Expect (-not $state.Open -and $panel.Visibility -eq 'Collapsed') 'Espace ne referme pas les options, ou un handler a été doublé.'
            $script:Controls.CmbSearchQueryResult.Visibility='Collapsed'
            Expect ($button.Content -eq 'Options · Requête active') 'Le résumé fermé conserve le filtre local après passage à une requête Annuaire.'
            $script:Controls.CmbSearchQueryResult.Visibility='Visible'
            Expect ($button.Content -eq 'Options · Inconnus' -and -not $state.Open) 'Le retour à la requête locale doit rétablir son résumé sans ouvrir les options.'
            [void](Invoke-OptionsKey $button ([Windows.Input.Key]::Enter))
            Expect $state.Open 'La réouverture au clavier a échoué.'
            $escapeHandled=Invoke-OptionsKey $panel ([Windows.Input.Key]::Escape) -Preview
            Expect ($escapeHandled -and -not $state.Open -and [object]::ReferenceEquals([Windows.Input.FocusManager]::GetFocusedElement($script:Window),$button)) 'Échap doit fermer les options et rendre le focus au bouton.'
            $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            Expect $state.Open 'Le clic de réouverture est perdu.'
            $script:Controls.BtnSearchQueryFavorite.Content='★';$script:Settings['Search.QueryFavorites']=@('b')
            $focused=$script:Controls.TxtSearchQueryFilter;$focused.BringIntoView();$script:Window.UpdateLayout();[void]$focused.Focus()
            Expect $focused.IsKeyboardFocused 'Le champ doit réellement recevoir le focus dans le HWND présenté.'
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1900 -Height 1000)
            Expect (-not $state.Compact -and $button.Visibility -eq 'Collapsed' -and $panel.Visibility -eq 'Collapsed') 'Le retour normal conserve un volet compact visible.'
            Expect ($verify.Margin -eq [Windows.Thickness]::new(0) -and $verify.Parent.Margin -eq [Windows.Thickness]::new(0,0,8,4)) 'Vérifier la liste est séparé de sa flèche au retour normal.'
            Expect ($focused.IsKeyboardFocused -and [object]::ReferenceEquals([Windows.Input.Keyboard]::FocusedElement,$focused)) 'Le retour normal doit rendre le focus au champ précédemment utilisé.'
            foreach($name in $parents.Keys){Expect ([object]::ReferenceEquals($script:Controls[$name].Parent,$parents[$name])) ($name+' nʼa pas retrouvé son parent dʼorigine.')}
            Expect ($script:Controls.BtnQueryClearSearch.Content -eq 'Effacer la requête' -and [Windows.Controls.Grid]::GetColumn($script:Controls.UxSearchQueryBar) -eq 0 -and [Windows.Controls.Grid]::GetRow($script:Controls.UxSearchQueryBar) -eq 1) 'La barre normale ne retrouve pas son organisation.'
            Expect ($script:Controls.BtnSearchQueryFavorite.Content -eq '★' -and @($script:Settings['Search.QueryFavorites']).Count -eq 1 -and $script:Settings['Search.QueryFavorites'][0] -eq 'b') 'Le retour normal a remplacé le symbole ou la préférence de favori.'
            Expect ($script:Controls.CmbGlobalType.Parent.Width -eq 148 -and $script:Controls.CmbPresenceFilter.Parent.Width -eq 138 -and $script:Controls.TxtGlobalLimit.Parent.Width -eq 90) 'Les filtres gardent leurs largeurs très compactes.'
            Expect ($script:Controls.CmbWorkView.SelectedItem.Id -eq 'b' -and $script:Controls.TxtSearchQueryFilter.Text -eq 'disque' -and $script:Controls.ChkSearchQueryFavorites.IsChecked -and $script:Controls.CmbSearchQueryResult.SelectedIndex -eq 1) 'La disposition a modifié un choix de requête.'
            Set-DomeniaUxShortLayout (Get-DomeniaUxHeightPlan -Width 1000 -Height 500)
            Expect ($state.Open -and $panel.Visibility -eq 'Visible') 'Le retour compact doit préserver le choix dʼouverture de la session.'
            Expect ($script:Controls.BtnSearchQueryFavorite.Content -eq '★' -and $script:Settings['Search.QueryFavorites'][0] -eq 'b') 'Le retour compact a perdu le favori.'
            Expect ($script:OptionExecutions -eq 0 -and $script:StartUiTaskCalls -eq 0 -and $script:OptionsGlobalSearchCalls -eq 0 -and $null -eq $script:LastState) 'La disposition ou son clavier a exécuté une requête ou admis une lecture.'
            # Exercise the real clear action and its real selector details, with local I/O boundaries only.
            $searchUi=Read-Ast (Join-Path $wad 'modules/Domenia-Search.UI.ps1')
            foreach($name in @('Clear-DomeniaSearchQuery','Update-DomeniaSearchQueryDetails')){Import-Function $searchUi $name}
            function Set-DomeniaControlText {param($Name,$Text);$control=Get-DomeniaControl $Name;if($null -ne $control){$control.Text=[string]$Text};return $true}
            function Invalidate-DomeniaSearchResults {$script:OptionsInvalidations++}
            function Apply-DomeniaPresenceFilter {$script:OptionsPresenceFilters++}
            function Update-DomeniaSearchMoreButton {param($Search)}
            $script:OptionsInvalidations=0;$script:OptionsPresenceFilters=0
            $script:SearchQueryCatalogBusy=$false;$script:SelectedBranchDn='';$script:SearchQueryLibraryError=''
            $script:ActiveSearchViewId='fixture-local';$script:SearchQueryRun=[pscustomobject]@{Id='fixture-local'}
            $script:DomeniaQueryState=[pscustomobject]@{SearchRecipe='fixture';SearchRefinement='fixture';SearchRecords=@{fixture='record'}}
            $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            Expect (-not $state.Open) 'Le contrôle Effacer doit aussi être testé avec les options repliées.'
            Clear-DomeniaSearchQuery
            Expect ($button.Content -eq 'Options de requête' -and $script:Controls.CmbWorkView.SelectedIndex -eq -1 -and $script:Controls.CmbSearchQueryResult.Visibility -eq 'Collapsed') 'Effacer doit supprimer le choix et rendre le résumé compact inactif.'
            Expect ($script:OptionsInvalidations -eq 1 -and $script:OptionsPresenceFilters -eq 0 -and -not $script:ActiveSearchViewId -and $null -eq $script:SearchQueryRun -and $null -eq $script:DomeniaQueryState.SearchRecipe) 'La vraie requête appliquée nʼa pas été annulée et retirée.'
            Clear-DomeniaSearchQuery
            Expect ($script:OptionsInvalidations -eq 1 -and $script:OptionsPresenceFilters -eq 1 -and $button.Content -eq 'Options de requête') 'Sur une liste ordinaire, Effacer ne doit pas invalider une deuxième liste.'
            Expect ($script:OptionExecutions -eq 0 -and $script:StartUiTaskCalls -eq 0 -and $script:OptionsGlobalSearchCalls -eq 0) 'Effacer a démarré une lecture.'
            # Independently verify the text dependency is detached when the real HWND closes.
            $script:Controls.CmbSearchQueryResult.Visibility='Collapsed'
            $script:Controls.LblSearchQuery.Text='Requête de contrôle encore active'
            $label=$script:Controls.LblSearchQuery;$caption=[string]$button.Content
            Expect ($caption -match 'Requête active') 'Le résumé doit annoncer la requête active lorsque le choix de population est masqué.'
            $script:Window.Close()
            $label.Text='Aucune requête appliquée aux résultats.'
            Expect ([string]$button.Content -ceq $caption) 'Un ancien callback continue de modifier le shell fermé.'
        }finally{if($null -ne $script:Window){$script:Window.Close()}}
    }
    Case 'WPF : Recherche réelle, barre de requêtes accessible et six lignes complètes' {
        # Only the real presentation functions and XAML are loaded. No application startup, credentials or worker.
        $core=Read-Ast (Join-Path $wad 'Domenia-Core.ps1')
        foreach($name in @('Get-MainXaml','Get-DomeniaXamlControlNames')){Import-Function $core $name}
        foreach($name in @('Update-DomeniaUxLayout','Test-DomeniaUxNavFolded','Update-DomeniaUxSidebar','Set-DomeniaUxHeaderLayout')){Import-Function $ux $name}
        $experience=Read-Ast (Join-Path $wad 'modules/Domenia-Experience.UI.ps1')
        Import-Function $experience 'Set-DomeniaExperienceJournalLayout'
        $model=Read-Ast (Join-Path $wad 'modules/Domenia-Experience.Model.ps1')
        Import-Function $model 'ConvertTo-SuiteNumber'
        function Update-DomeniaExperienceLogView {}
        function Update-DomeniaExperienceLogBadge {}
        function Settle-Layout {
            # A session-0 desktop may cap an HWND at 1044 x 788. Arrange the real XAML
            # in a native WPF host of the requested size, independently of that desktop.
            # No scale or fake control bounds: ScrollViewer clips and virtualization remain real.
            for($layoutPass=0;$layoutPass -lt 2;$layoutPass++){
                $script:GeometryHost.Measure([Windows.Size]::new(1920,1080))
                $script:GeometryHost.Arrange([Windows.Rect]::new(0,0,1920,1080))
                $script:GeometryHost.UpdateLayout()
                $script:Window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
            }
        }
        function Get-VisibleBounds {param($Control)
            $root=$script:GeometryHost
            $bounds=$Control.TransformToAncestor($root).TransformBounds([Windows.Rect]::new(0,0,$Control.ActualWidth,$Control.ActualHeight))
            $visible=$bounds;$visible.Intersect([Windows.Rect]::new(0,0,$root.ActualWidth,$root.ActualHeight))
            $ancestor=$Control
            while($null -ne $ancestor -and -not [object]::ReferenceEquals($ancestor,$root)){
                if($ancestor -is [Windows.UIElement]){
                    # IsVisible also requires a PresentationSource and is false for the whole
                    # off-screen render tree. Check effective Visibility through every ancestor.
                    if($ancestor.Visibility -ne [Windows.Visibility]::Visible){$visible=[Windows.Rect]::Empty;break}
                    $clip=[Windows.Media.VisualTreeHelper]::GetClip($ancestor)
                    if($null -ne $clip){$visible.Intersect($ancestor.TransformToAncestor($root).TransformBounds($clip.Bounds))}
                    if($ancestor.ClipToBounds -or $ancestor -is [Windows.Controls.ScrollContentPresenter]){
                        $visible.Intersect($ancestor.TransformToAncestor($root).TransformBounds([Windows.Rect]::new(0,0,$ancestor.RenderSize.Width,$ancestor.RenderSize.Height)))
                    }
                }
                $ancestor=[Windows.Media.VisualTreeHelper]::GetParent($ancestor)
            }
            return [pscustomobject]@{Bounds=$bounds;Visible=$visible}
        }
        $script:Controls=@{};$xaml=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)
        $script:Window=[Windows.Markup.XamlReader]::Parse($xaml)
        foreach($name in @(Get-DomeniaXamlControlNames $xaml)){$control=$script:Window.FindName($name);if($null -ne $control){$script:Controls[$name]=$control}}
        $script:Window.Width=1920;$script:Window.Height=1080;$script:Window.ShowInTaskbar=$false
        $script:Window.WindowStartupLocation='Manual';$script:Window.Left=0;$script:Window.Top=0
        [Windows.Controls.ToolTipService]::SetIsEnabled($script:Window,$false)
        $script:UxLayoutSignature='';$script:UxNavLayoutSignature='';$script:UxNavCollapsed=$false;$script:UxHelpVisible=$true;$script:UxHelpCompactOpen=$false
        $script:UxShortScreen=$false;$script:UxShortHelpOpen=$false;$script:UxShortLogHeld=$false;$script:UxShortLogReleased=$false;$script:UxShortNavFold=$false;$script:UxShortNavReleased=$false
        $script:UxLogCollapsed=$false;$script:UxLogHeight=142.0
        try{
            $script:Controls.WorkspaceTabs.SelectedItem=$script:Controls.WsSearch
            $script:Controls.CmbWorkView.ItemsSource=@([pscustomobject]@{DisplayName='Postes actifs de lʼOU';Id='fixture'})
            $script:Controls.CmbWorkView.SelectedIndex=0
            $script:Controls.LblSearchQueryDetails.Text='Source : données locales · OU : Postes · Avec les sous-OU'
            $script:Controls.LblSearchQuery.Text='Requête appliquée : 30 correspondants · 2 inconnus · 1 non-correspondant'
            $script:Controls.CmbSearchQueryResult.Visibility='Visible'
            $rows=[Collections.ArrayList]::new()
            for($i=1;$i -le 40;$i++){[void]$rows.Add([pscustomobject]@{Type='Machine';Name=('PC-TEST-{0:000}' -f $i);DN=('CN=PC-TEST-{0:000},OU=Postes,DC=example,DC=invalid' -f $i);Presence='Non vérifié'})}
            $grid=$script:Controls.DgObjects;$grid.ItemsSource=$rows
            $script:Window.Show()
            $content=$script:Window.Content;$script:Window.Content=$null
            $script:GeometryHost=[Windows.Controls.Grid]::new()
            $script:GeometryHost.Width=1920;$script:GeometryHost.Height=1080
            $script:GeometryHost.Resources=$script:Window.Resources
            $script:GeometryHost.SetValue([Windows.Documents.TextElement]::FontFamilyProperty,$script:Window.FontFamily)
            $script:GeometryHost.SetValue([Windows.Documents.TextElement]::FontSizeProperty,$script:Window.FontSize)
            $script:GeometryHost.UseLayoutRounding=$true
            [void]$script:GeometryHost.Children.Add($content)
            $script:Window.Content=[Windows.Controls.Grid]::new()
            Settle-Layout
            Expect ($script:GeometryHost.ActualWidth -eq 1920 -and $script:GeometryHost.ActualHeight -eq 1080) 'Le host WPF nʼa pas atteint le viewport demandé.'
            Set-DomeniaExperienceJournalLayout -Collapsed $false
            $script:Settings['Ui.ZoomPercent']=100;Initialize-DomeniaUiZoom;Settle-Layout
            $names=@('TxtSearchQueryFilter','ChkSearchQueryFavorites','CmbWorkView','BtnWorkView','BtnSearchQueryFavorite','BtnSearchQueryWorkshop','LblSearchQueryDetails','LblSearchQuery','CmbSearchQueryResult','BtnQueryClearSearch')
            foreach($zoom in @(100,150,100)){
                Set-DomeniaUiZoom $zoom;Settle-Layout;Set-DomeniaUiZoom $zoom;Settle-Layout
                foreach($name in $names){
                    $control=$script:Controls[$name]
                    if($zoom -eq 150){$control.BringIntoView();Settle-Layout}
                    $rect=Get-VisibleBounds $control
                    $full=($rect.Bounds.Width -gt 0 -and $rect.Bounds.Height -gt 0 -and $rect.Visible.Width -ge ($rect.Bounds.Width-1) -and $rect.Visible.Height -ge ($rect.Bounds.Height-1))
                    $script:GeometryEvidence.Add([pscustomobject]@{Zoom=$zoom;Control=$name;X=$rect.Bounds.X;Y=$rect.Bounds.Y;Width=$rect.Bounds.Width;Height=$rect.Bounds.Height;VisibleWidth=[Math]::Max([double]0,$rect.Visible.Width);VisibleHeight=[Math]::Max([double]0,$rect.Visible.Height);FullyVisible=$full})
                    Expect $full ($name+' est coupé à '+$zoom+' % malgré le défilement disponible.')
                }
                if($zoom -eq 100){
                    $complete=0;$rowEvidence=[Collections.Generic.List[object]]::new()
                    for($i=0;$i -lt $grid.Items.Count;$i++){
                        $row=$grid.ItemContainerGenerator.ContainerFromIndex($i)
                        if($null -eq $row){continue};$rect=Get-VisibleBounds $row
                        $rowComplete=($rect.Bounds.Height -gt 0 -and $rect.Visible.Height -ge ($rect.Bounds.Height-1) -and $rect.Visible.Width -gt 100)
                        if($rowComplete){$complete++}
                        $rowEvidence.Add([pscustomobject]@{Index=$i;Y=$rect.Bounds.Y;Height=$rect.Bounds.Height;VisibleHeight=[Math]::Max([double]0,$rect.Visible.Height);FullyVisible=$rowComplete})
                    }
                    $gridRect=Get-VisibleBounds $grid
                    $script:GeometryEvidence.Add([pscustomobject]@{Zoom=$zoom;Control='DgObjects';X=$gridRect.Bounds.X;Y=$gridRect.Bounds.Y;Width=$gridRect.Bounds.Width;Height=$gridRect.Bounds.Height;VisibleWidth=[Math]::Max([double]0,$gridRect.Visible.Width);VisibleHeight=[Math]::Max([double]0,$gridRect.Visible.Height);FullyVisibleRows=$complete;Rows=@($rowEvidence.ToArray());HostWidth=$script:GeometryHost.ActualWidth;HostHeight=$script:GeometryHost.ActualHeight;WindowWidth=$script:Window.ActualWidth;WindowHeight=$script:Window.ActualHeight;Rendering='Native off-screen WPF; real XAML and ancestor clips; no scaling'})
                    Expect ($complete -ge 6) ('Recherche nʼaffiche que '+$complete+' lignes complètes à 1920 × 1080 / 100 %.')
                }
            }
        }finally{if($null -ne $script:GeometryHost){$script:GeometryHost.Children.Clear();$script:GeometryHost=$null};if($null -ne $script:Window){$script:Window.Close()}}
    }
}
$report=[pscustomobject]@{Suite='Domenia UX state safety';Mode=$(if($PureOnly){'PureOnly'}else{'Windows WPF and pure'});Passed=(@($results|Where-Object{-not $_.Passed}).Count -eq 0);Count=$results.Count;WindowsQualified=(-not $PureOnly);NoNetwork=$true;Results=@($results.ToArray());Geometry=@($script:GeometryEvidence.ToArray())}
if($ReportPath){$parent=Split-Path -Parent $ReportPath;if($parent){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
if(-not $Quiet){$report|ConvertTo-Json -Depth 8}
if(-not $report.Passed){exit 1}
