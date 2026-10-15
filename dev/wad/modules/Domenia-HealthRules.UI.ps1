# Dashboard health policy editor: local preferences only, no collection or network action.
function Get-DomeniaHealthPolicySettingKey {
    param([string]$DomainDn)
    if(-not (Test-DomeniaHealthScope '' $DomainDn)){throw 'Aucun domaine actif pour ces règles.'}
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($DomainDn.Trim().ToLowerInvariant()))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return 'Dashboard.HealthPolicies.'+$hash
}
function Get-DomeniaStoredHealthPolicyBook {
    $domain=[string]$script:Conn.BaseDn;$key=Get-DomeniaHealthPolicySettingKey $domain
    $stored=[string](Get-DomeniaSetting $key '')
    if($stored){return ConvertTo-DomeniaHealthPolicyBook $stored $domain -Strict}
    # One-time read compatibility. All future edits use the domain-scoped authority only.
    $legacy=ConvertTo-DomeniaHealthPolicy (Get-DomeniaSetting 'Dashboard.HealthPolicy' '')
    return ConvertTo-DomeniaHealthPolicyBook @{Default=$legacy} $domain
}
function Get-DomeniaStoredHealthPolicy {
    param([string]$ScopeDn='')
    return Resolve-DomeniaHealthPolicy (Get-DomeniaStoredHealthPolicyBook) $ScopeDn
}
function Save-DomeniaHealthPolicy {
    param($Policy,[string]$ScopeDn='',[switch]$RemoveOverride)
    $book=Set-DomeniaHealthScopePolicy (Get-DomeniaStoredHealthPolicyBook) -ScopeDn $ScopeDn -Policy $Policy -Remove:$RemoveOverride
    Set-DomeniaSetting (Get-DomeniaHealthPolicySettingKey $book.DomainDn) ($book|ConvertTo-Json -Depth 15 -Compress)
    Save-DomeniaSettings -Immediate
}
function Show-DomeniaHealthRulesEditor {
    param([ValidateSet('Fleet','Computer')][string]$Board='Fleet')
    $hrDn=if($Board -eq 'Fleet'){[string]$script:FleetScopeDn}else{[string](Get-DomeniaHealthValue $script:SelectedObject 'DN' '')}
    while($hrDn -and $hrDn -notmatch '^(?i:OU|DC)='){$hrDn=Get-DomeniaRawDnParent $hrDn}
    if($hrDn -notmatch '^(?i:OU)='){$hrDn=''}
    $hrScopeState=@{Dn=$hrDn}
    $hrPolicy=Get-DomeniaStoredHealthPolicy -ScopeDn $hrDn
    $hrRules=[Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach($rule in @(Get-DomeniaHealthRuleCatalog)){$hrRules.Add([pscustomobject]@{Id=$rule.Id;Name=$rule.Name;Enabled=(Test-DomeniaHealthRuleEnabled $hrPolicy $rule.Id -IgnoreSuspension)})}
    $hrLimits=[Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach($limit in @(Get-DomeniaHealthThresholdCatalog)){$hrLimits.Add([pscustomobject]@{Id=$limit.Id;Name=$limit.Name;Value=[string]$hrPolicy.Thresholds.($limit.Id);Bounds=([string]$limit.Minimum+' à '+$limit.Maximum)})}
    $hrCustom=[Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach($rule in @($hrPolicy.CustomRules)){$hrCustom.Add(($rule|ConvertTo-Json -Compress|ConvertFrom-Json))}
    $hrSuspensions=[Collections.ObjectModel.ObservableCollection[object]]::new()
    $hrReloadSuspensions={param($p)$hrSuspensions.Clear();foreach($v in @($p.Suspensions)){$until=ConvertFrom-DomeniaUtcText $v.UntilUtc;$hrSuspensions.Add([pscustomobject]@{RuleId=$v.RuleId;Reason=$v.Reason;UntilUtc=$v.UntilUtc;UntilLocal=$until.ToLocalTime().ToString('dd/MM/yyyy HH:mm');State=$(if($until -gt [datetime]::UtcNow){'Suspendue'}else{'Terminée'})})}}
    & $hrReloadSuspensions $hrPolicy
    $hrWindow=[Windows.Window]::new();$hrWindow.Title='Règles de santé';$hrWindow.Width=920;$hrWindow.Height=660
    $hrRoot=[Windows.Controls.DockPanel]::new();$hrRoot.Margin=[Windows.Thickness]::new(16)
    $hrIntro=[Windows.Controls.TextBlock]::new();$hrIntro.Text='Choisissez les contrôles utiles. Une règle désactivée ne crée ni alerte ni pénalité de score. Les données manquantes restent inconnues. Le calcul et les listes utilisent les mêmes postes de lʼOU.';$hrIntro.TextWrapping='Wrap';$hrIntro.Margin=[Windows.Thickness]::new(0,0,0,14);[Windows.Controls.DockPanel]::SetDock($hrIntro,'Top');[void]$hrRoot.Children.Add($hrIntro)
    $hrFooter=[Windows.Controls.StackPanel]::new();$hrFooter.Margin=[Windows.Thickness]::new(0,12,0,0);[Windows.Controls.DockPanel]::SetDock($hrFooter,'Bottom')
    $hrError=[Windows.Controls.TextBlock]::new();$hrError.TextWrapping='Wrap';$hrError.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'WarningColor');[void]$hrFooter.Children.Add($hrError)
    $hrActions=[Windows.Controls.WrapPanel]::new();$hrActions.HorizontalAlignment='Right'
    $hrCancel=[Windows.Controls.Button]::new();$hrCancel.Content='Annuler';$hrCancel.MinWidth=100;$hrCancel.Margin=[Windows.Thickness]::new(6);$hrCancel.Add_Click({Set-DomeniaSurfaceResult $hrWindow $false})
    $hrSave=[Windows.Controls.Button]::new();$hrSave.Content='Appliquer';$hrSave.MinWidth=110;$hrSave.Margin=[Windows.Thickness]::new(6)
    [void]$hrActions.Children.Add($hrCancel);[void]$hrActions.Children.Add($hrSave);[void]$hrFooter.Children.Add($hrActions);[void]$hrRoot.Children.Add($hrFooter)
    $hrScopePanel=[Windows.Controls.StackPanel]::new();$hrScopePanel.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($hrScopePanel,'Top')
    $hrScopeChoice=[Windows.Controls.ComboBox]::new();$hrScopeChoice.Items.Add([pscustomobject]@{Name='Règles par défaut du domaine';Dn=''})|Out-Null
    if($hrDn){$hrScopeChoice.Items.Add([pscustomobject]@{Name=('Cette OU et ses sous-OU : '+$hrDn);Dn=$hrDn})|Out-Null}
    $hrScopeChoice.DisplayMemberPath='Name';$hrScopeChoice.SelectedIndex=$(if($hrDn){1}else{0});[void]$hrScopePanel.Children.Add($hrScopeChoice)
    $hrOrigin=[Windows.Controls.TextBlock]::new();$hrOrigin.TextWrapping='Wrap';$hrOrigin.Margin='0,6,0,6';[void]$hrScopePanel.Children.Add($hrOrigin)
    $hrInherit=[Windows.Controls.Button]::new();$hrInherit.Content='Revenir aux règles héritées';$hrInherit.HorizontalAlignment='Left';[void]$hrScopePanel.Children.Add($hrInherit)
    $hrDescribeOrigin={param($p)$source=Get-DomeniaHealthValue $p 'Origin';$hrOrigin.Text='Origine : '+$(if([string]$source.SourceDn){[string]$source.SourceDn}else{'règles par défaut du domaine'})+' · seules vos différences deviennent des exceptions locales.';$hrInherit.IsEnabled=([bool]$hrScopeState.Dn -and [bool]$source.Local)}
    & $hrDescribeOrigin $hrPolicy
    $hrScopeChoice.Add_SelectionChanged({
        $hrScopeState.Dn=[string]$hrScopeChoice.SelectedItem.Dn;$p=Get-DomeniaStoredHealthPolicy -ScopeDn $hrScopeState.Dn
        $hrRules.Clear();foreach($r in @(Get-DomeniaHealthRuleCatalog)){$hrRules.Add([pscustomobject]@{Id=$r.Id;Name=$r.Name;Enabled=(Test-DomeniaHealthRuleEnabled $p $r.Id -IgnoreSuspension)})}
        $hrLimits.Clear();foreach($l in @(Get-DomeniaHealthThresholdCatalog)){$hrLimits.Add([pscustomobject]@{Id=$l.Id;Name=$l.Name;Value=[string]$p.Thresholds.($l.Id);Bounds=([string]$l.Minimum+' à '+$l.Maximum)})}
        & $hrReloadSuspensions $p
        $hrCustom.Clear();foreach($r in @($p.CustomRules)){$hrCustom.Add(($r|ConvertTo-Json -Compress|ConvertFrom-Json))};$hrError.Text='';& $hrDescribeOrigin $p
    })
    $hrInherit.Add_Click({try{Save-DomeniaHealthPolicy -ScopeDn $hrScopeState.Dn -RemoveOverride;Set-DomeniaSurfaceResult $hrWindow $true}catch{$hrError.Text=$_.Exception.Message}})
    [void]$hrRoot.Children.Add($hrScopePanel)
    $hrTabs=[Windows.Controls.TabControl]::new()
    $hrMakeGrid={param($Rows)$g=[Windows.Controls.DataGrid]::new();$g.AutoGenerateColumns=$false;$g.CanUserAddRows=$false;$g.CanUserDeleteRows=$false;$g.HeadersVisibility='Column';$g.RowHeaderWidth=0;$g.ItemsSource=$Rows;$g.SelectionMode='Single';$g.EnableRowVirtualization=$true;$g.Margin=[Windows.Thickness]::new(0,10,0,0);return $g}
    $hrAddText={param($Grid,$Title,$Path,[bool]$ReadOnly=$false,$Width='*')$c=[Windows.Controls.DataGridTextColumn]::new();$c.Header=$Title;$c.Binding=[Windows.Data.Binding]::new($Path);$c.IsReadOnly=$ReadOnly;$c.Width=$Width;[void]$Grid.Columns.Add($c)}
    $hrAddCheck={param($Grid)$c=[Windows.Controls.DataGridCheckBoxColumn]::new();$c.Header='Activée';$c.Binding=[Windows.Data.Binding]::new('Enabled');$c.Width=72;[void]$Grid.Columns.Add($c)}
    $hrRuleGrid=& $hrMakeGrid $hrRules;& $hrAddCheck $hrRuleGrid;& $hrAddText $hrRuleGrid 'Contrôle' 'Name' $true
    $hrRuleTab=[Windows.Controls.TabItem]::new();$hrRuleTab.Header='Contrôles';$hrRuleTab.Content=$hrRuleGrid;[void]$hrTabs.Items.Add($hrRuleTab)
    $hrLimitGrid=& $hrMakeGrid $hrLimits;& $hrAddText $hrLimitGrid 'Seuil' 'Name' $true;& $hrAddText $hrLimitGrid 'Valeur' 'Value' $false 95;& $hrAddText $hrLimitGrid 'Valeurs autorisées' 'Bounds' $true 130
    $hrLimitTab=[Windows.Controls.TabItem]::new();$hrLimitTab.Header='Seuils';$hrLimitTab.Content=$hrLimitGrid;[void]$hrTabs.Items.Add($hrLimitTab)
    $hrCustomPanel=[Windows.Controls.DockPanel]::new();$hrCustomActions=[Windows.Controls.WrapPanel]::new();$hrCustomActions.Margin=[Windows.Thickness]::new(0,10,0,0);[Windows.Controls.DockPanel]::SetDock($hrCustomActions,'Top')
    $hrAdd=[Windows.Controls.Button]::new();$hrAdd.Content='Ajouter une alerte';$hrAdd.Margin=[Windows.Thickness]::new(0,0,8,0)
    $hrDelete=[Windows.Controls.Button]::new();$hrDelete.Content='Supprimer lʼalerte sélectionnée'
    [void]$hrCustomActions.Children.Add($hrAdd);[void]$hrCustomActions.Children.Add($hrDelete);[void]$hrCustomPanel.Children.Add($hrCustomActions)
    $hrCustomGrid=& $hrMakeGrid $hrCustom;& $hrAddCheck $hrCustomGrid;& $hrAddText $hrCustomGrid 'Nom' 'Name' $false 170
    $hrChoices=@(
        [pscustomobject]@{Title='Mesure';Path='Measure';Items=@([pscustomobject]@{Id='DiskFree';Name='Disque C: libre (%)'},[pscustomobject]@{Id='UptimeDays';Name='Sans redémarrage (j)'},[pscustomobject]@{Id='MemoryUsed';Name='Mémoire utilisée (%)'})}
        [pscustomobject]@{Title='Condition';Path='Operator';Items=@([pscustomobject]@{Id='LessThan';Name='Inférieur à'},[pscustomobject]@{Id='GreaterThan';Name='Supérieur à'})}
        [pscustomobject]@{Title='Niveau';Path='Severity';Items=@([pscustomobject]@{Id='Warn';Name='À surveiller'},[pscustomobject]@{Id='Alert';Name='Critique'})}
    )
    foreach($choice in $hrChoices){
        $column=[Windows.Controls.DataGridComboBoxColumn]::new();$column.Header=$choice.Title;$column.ItemsSource=$choice.Items;$column.DisplayMemberPath='Name';$column.SelectedValuePath='Id';$column.SelectedValueBinding=[Windows.Data.Binding]::new($choice.Path);$column.Width=125;[void]$hrCustomGrid.Columns.Add($column)
    }
    & $hrAddText $hrCustomGrid 'Seuil' 'Threshold' $false 75
    $hrLegend=[Windows.Controls.TextBlock]::new();$hrLegend.Text='Le disque et le démarrage sont disponibles après le relevé WMI de lʼOU. La mémoire utilisée demande lʼinventaire détaillé du poste. Une mesure absente reste inconnue. Supprimer retire la règle, sans effacer les données collectées.';$hrLegend.TextWrapping='Wrap';$hrLegend.Margin=[Windows.Thickness]::new(0,8,0,0);[Windows.Controls.DockPanel]::SetDock($hrLegend,'Bottom');[void]$hrCustomPanel.Children.Add($hrLegend);[void]$hrCustomPanel.Children.Add($hrCustomGrid)
    $hrCustomTab=[Windows.Controls.TabItem]::new();$hrCustomTab.Header='Mes alertes';$hrCustomTab.Content=$hrCustomPanel;[void]$hrTabs.Items.Add($hrCustomTab)
    $hrAdd.Add_Click({if($hrCustom.Count -ge 32){$hrError.Text='32 alertes personnalisées au maximum.';return};$hrCustom.Add([pscustomobject]@{Id=('custom.'+[guid]::NewGuid().ToString('N'));Name='Espace disque à surveiller';Measure='DiskFree';Operator='LessThan';Threshold=15;Severity='Warn';Enabled=$true})})
    $hrDelete.Add_Click({$selected=$hrCustomGrid.SelectedItem;if($null -ne $selected){[void]$hrCustom.Remove($selected)}})
    $hrSuspendPanel=[Windows.Controls.DockPanel]::new();$hrSuspendActions=[Windows.Controls.StackPanel]::new();$hrSuspendActions.Margin='0,10,0,10';[Windows.Controls.DockPanel]::SetDock($hrSuspendActions,'Top')
    $hrSuspendNote=[Windows.Controls.TextBlock]::new();$hrSuspendNote.Text='Une suspension exclut temporairement ce contrôle du score, pour la portée choisie. Son motif reste visible. Le contrôle reprend au premier recalcul après lʼéchéance ; aucune donnée collectée nʼest effacée.';$hrSuspendNote.TextWrapping='Wrap';$hrSuspendNote.Margin='0,0,0,8';[void]$hrSuspendActions.Children.Add($hrSuspendNote)
    $hrSuspendChoice=[Windows.Controls.ComboBox]::new();$hrSuspendChoice.DisplayMemberPath='Name';$hrSuspendChoice.ItemsSource=@(Get-DomeniaHealthRuleCatalog)+@($hrCustom);$hrSuspendChoice.SelectedIndex=0;$hrSuspendChoice.Margin='0,0,0,6';[void]$hrSuspendActions.Children.Add($hrSuspendChoice)
    $hrSuspendReason=[Windows.Controls.TextBox]::new();$hrSuspendReason.MaxLength=240;$hrSuspendReason.MinWidth=260;$hrSuspendReason.Margin='0,0,0,6'
    $hrReasonLabel=[Windows.Controls.TextBlock]::new();$hrReasonLabel.Text='Motif (obligatoire)';[void]$hrSuspendActions.Children.Add($hrReasonLabel);[void]$hrSuspendActions.Children.Add($hrSuspendReason)
    $hrSuspendLine=[Windows.Controls.WrapPanel]::new();$hrSuspendDuration=[Windows.Controls.ComboBox]::new();$hrSuspendDuration.DisplayMemberPath='Name';$hrSuspendDuration.ItemsSource=@([pscustomobject]@{Name='1 heure';Hours=1},[pscustomobject]@{Name='24 heures';Hours=24},[pscustomobject]@{Name='7 jours';Hours=168},[pscustomobject]@{Name='30 jours';Hours=720});$hrSuspendDuration.SelectedIndex=1;$hrSuspendDuration.MinWidth=130
    $hrSuspendAdd=[Windows.Controls.Button]::new();$hrSuspendAdd.Content='Suspendre';$hrSuspendAdd.Margin='8,0,8,0';$hrSuspendRemove=[Windows.Controls.Button]::new();$hrSuspendRemove.Content='Retirer la suspension sélectionnée'
    foreach($control in @($hrSuspendDuration,$hrSuspendAdd,$hrSuspendRemove)){[void]$hrSuspendLine.Children.Add($control)};[void]$hrSuspendActions.Children.Add($hrSuspendLine);[void]$hrSuspendPanel.Children.Add($hrSuspendActions)
    $hrSuspendGrid=& $hrMakeGrid $hrSuspensions;$hrSuspendGrid.IsReadOnly=$true;& $hrAddText $hrSuspendGrid 'Contrôle' 'RuleId' $true 140;& $hrAddText $hrSuspendGrid 'Motif' 'Reason' $true;& $hrAddText $hrSuspendGrid 'Jusquʼau (heure locale)' 'UntilLocal' $true 170;& $hrAddText $hrSuspendGrid 'État' 'State' $true 85
    [void]$hrSuspendPanel.Children.Add($hrSuspendGrid);$hrSuspendTab=[Windows.Controls.TabItem]::new();$hrSuspendTab.Header='Suspensions';$hrSuspendTab.Content=$hrSuspendPanel;[void]$hrTabs.Items.Add($hrSuspendTab)
    $hrSuspendTab.Add_GotFocus({
        if($hrSuspendChoice.IsDropDownOpen){return}
        $chosen=[string](Get-DomeniaHealthValue $hrSuspendChoice.SelectedItem 'Id' '')
        $choices=@(Get-DomeniaHealthRuleCatalog)+@($hrCustom)
        # Refresh only if custom rule identities changed; rebinding on every child focus loses selection.
        if((@($hrSuspendChoice.Items|ForEach-Object{$_.Id}) -join '|') -cne (@($choices|ForEach-Object{$_.Id}) -join '|')){
            $hrSuspendChoice.ItemsSource=$choices
            $match=@($choices|Where-Object{$_.Id -ceq $chosen}|Select-Object -First 1)
            if($match.Count){$hrSuspendChoice.SelectedItem=$match[0]}elseif($choices.Count){$hrSuspendChoice.SelectedIndex=0}
        }
    })
    $hrSuspendAdd.Add_Click({try{
        if($null -eq $hrSuspendChoice.SelectedItem){throw 'Choisissez un contrôle.'};$id=[string]$hrSuspendChoice.SelectedItem.Id;$until=[datetime]::UtcNow.AddHours([double]$hrSuspendDuration.SelectedItem.Hours)
        $candidate=@(ConvertTo-DomeniaHealthSuspensions @([pscustomobject]@{RuleId=$id;Reason=$hrSuspendReason.Text;UntilUtc=$until.ToString('o')}) -Strict)[0]
        foreach($old in @($hrSuspensions|Where-Object{$_.RuleId -ceq $id})){[void]$hrSuspensions.Remove($old)}
        $hrSuspensions.Add([pscustomobject]@{RuleId=$candidate.RuleId;Reason=$candidate.Reason;UntilUtc=$candidate.UntilUtc;UntilLocal=$until.ToLocalTime().ToString('dd/MM/yyyy HH:mm');State='Suspendue'});$hrError.Text=''
    }catch{$hrError.Text=$_.Exception.Message}})
    $hrSuspendRemove.Add_Click({if($null -ne $hrSuspendGrid.SelectedItem){[void]$hrSuspensions.Remove($hrSuspendGrid.SelectedItem)}})
    $hrSave.Add_Click({
        try{
            foreach($g in @($hrRuleGrid,$hrLimitGrid,$hrCustomGrid)){
                if(-not $g.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true) -or -not $g.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true)){throw 'Corrigez la valeur de la cellule en cours avant dʼappliquer les règles.'}
            }
            $limits=@{};foreach($row in $hrLimits){$limits[$row.Id]=$row.Value}
            $policy=ConvertTo-DomeniaHealthPolicy ([pscustomobject]@{Thresholds=$limits;DisabledRules=@($hrRules|Where-Object{-not $_.Enabled}|ForEach-Object{$_.Id});CustomRules=@($hrCustom);Suspensions=@($hrSuspensions|Where-Object{-not $_.RuleId.StartsWith('custom.') -or @($hrCustom.Id) -contains $_.RuleId})}) -Strict
            Save-DomeniaHealthPolicy $policy -ScopeDn $hrScopeState.Dn
            Set-DomeniaSurfaceResult $hrWindow $true
        }catch{$hrError.Text=$_.Exception.Message}
    })
    [void]$hrRoot.Children.Add($hrTabs);$hrWindow.Content=$hrRoot
    $saved=[bool](Show-DomeniaEmbeddedWindow $hrWindow)
    if($saved){
        Request-DomeniaFleetRefresh -Force
        if($null -ne $script:SelectedObject -and $script:SelectedObject.Type -eq 'Machine'){[void](Show-DomeniaCachedInventory -Computer (Get-CurrentSelectedComputerName))}
        Set-Status 'Règles enregistrées ; vues recalculées depuis la base locale.'
    }
    return $saved
}

function Show-DomeniaHealthExplanation {
    param([ValidateSet('Fleet','Computer')][string]$Board='Fleet')
    $data=(Get-DomeniaBoardState $Board).Data
    if($null -eq $data){Set-Status 'Calculez dʼabord le tableau de bord depuis la base locale.';return}
    $explanation=Get-DomeniaHealthValue $data 'HealthExplanation'
    if($null -eq $explanation){$explanation=Get-DomeniaHealthExplanation $data}
    $heWindow=[Windows.Window]::new();$heWindow.Title='Comprendre le score de santé';$heWindow.Width=850;$heWindow.Height=620
    $panel=[Windows.Controls.DockPanel]::new();$panel.Margin='12'
    $summary=[Windows.Controls.TextBlock]::new();$summary.Text=$explanation.Summary+"`n"+$explanation.ActiveRules+' règles activées · '+$explanation.DisabledRules+' désactivées · '+[int](Get-DomeniaHealthValue $explanation 'SuspendedRules' 0)+' suspendues'+$(if($explanation.Scope){"`nPérimètre : "+$explanation.Scope}else{''})
    $summary.TextWrapping='Wrap';$summary.Margin='0,0,0,16';[Windows.Controls.DockPanel]::SetDock($summary,'Top');[void]$panel.Children.Add($summary)
    $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.AutoGenerateColumns=$false;$grid.CanUserAddRows=$false;$grid.CanUserDeleteRows=$false;$grid.EnableRowVirtualization=$true;$grid.ItemsSource=$explanation.Rows
    foreach($field in @(@('Contrôle','Rule','2*'),@('État','Status','*'),@('Postes','Machines',70),@('Contribution','Effect','2*'))){$col=[Windows.Controls.DataGridTextColumn]::new();$col.Header=$field[0];$col.Binding=[Windows.Data.Binding]::new($field[1]);$col.Width=$field[2];[void]$grid.Columns.Add($col)}
    $tabs=[Windows.Controls.TabControl]::new();$rulesTab=[Windows.Controls.TabItem]::new();$rulesTab.Header='Contrôles et score';$rulesTab.Content=$grid;[void]$tabs.Items.Add($rulesTab)
    $policies=@(Get-DomeniaHealthValue $explanation 'Policies' @())
    if($policies.Count){
        $policyGrid=[Windows.Controls.DataGrid]::new();$policyGrid.IsReadOnly=$true;$policyGrid.AutoGenerateColumns=$false;$policyGrid.CanUserAddRows=$false;$policyGrid.CanUserDeleteRows=$false;$policyGrid.EnableRowVirtualization=$true;$policyGrid.ItemsSource=$policies
        foreach($field in @(@('Origine des règles','Scope','2*'),@('Postes','Machines',70),@('Suspensions','Suspended',95),@('Seuils appliqués','Thresholds','2*'))){$col=[Windows.Controls.DataGridTextColumn]::new();$col.Header=$field[0];$col.Binding=[Windows.Data.Binding]::new($field[1]);$col.Width=$field[2];[void]$policyGrid.Columns.Add($col)}
        $policyTab=[Windows.Controls.TabItem]::new();$policyTab.Header='Règles appliquées par OU';$policyTab.Content=$policyGrid;[void]$tabs.Items.Add($policyTab)
    }
    [void]$panel.Children.Add($tabs);$heWindow.Content=$panel;[void](Show-DomeniaEmbeddedWindow $heWindow)
}

function Show-DomeniaFleetAnalysis {
    $faData=(Get-DomeniaBoardState Fleet).Data
    if($null -eq $faData -or $null -eq $faData.PSObject.Properties['Pivots']){Set-Status 'Recalculez le dashboard depuis la base locale pour préparer cette analyse.';return}
    $faWindow=[Windows.Window]::new();$faWindow.Title='Analyser le parc';$faWindow.Width=1040;$faWindow.Height=710
    $faRoot=[Windows.Controls.DockPanel]::new();$faRoot.Margin='14'
    $faIntro=[Windows.Controls.TextBlock]::new();$faIntro.Text='Analyse de la vue conservée en base locale. Les catégories non renseignées sont incluses. Aucun relevé réseau nʼest lancé. Les dates comparées sont celles des calculs quotidiens enregistrés.';$faIntro.TextWrapping='Wrap';$faIntro.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($faIntro,'Top');[void]$faRoot.Children.Add($faIntro)
    $faTabs=[Windows.Controls.TabControl]::new()
    $faAddColumn={param($Grid,$Header,$Path,$Width)$column=[Windows.Controls.DataGridTextColumn]::new();$column.Header=$Header;$column.Binding=[Windows.Data.Binding]::new($Path);$column.Width=$Width;[void]$Grid.Columns.Add($column)}
    $faNewGrid={ $grid=[Windows.Controls.DataGrid]::new();$grid.AutoGenerateColumns=$false;$grid.IsReadOnly=$true;$grid.CanUserAddRows=$false;$grid.CanUserDeleteRows=$false;$grid.EnableRowVirtualization=$true;$grid.EnableColumnVirtualization=$true;$grid.SelectionMode='Single';return $grid }
    # Daily comparison remains available before the long trend has 90 days of history.
    $faComparePanel=[Windows.Controls.DockPanel]::new();$faCompareTop=[Windows.Controls.StackPanel]::new();$faCompareTop.Margin='0,10,0,10';[Windows.Controls.DockPanel]::SetDock($faCompareTop,'Top')
    $faBefore=[Windows.Controls.ComboBox]::new();$faBefore.ItemsSource=$faData.HealthHistory;$faBefore.DisplayMemberPath='Label';$faBefore.Margin='0,0,0,8'
    $faAfter=[Windows.Controls.ComboBox]::new();$faAfter.ItemsSource=$faData.HealthHistory;$faAfter.DisplayMemberPath='Label';$faAfter.Margin='0,0,0,8'
    foreach($pair in @(@('Premier relevé',$faBefore),@('Second relevé',$faAfter))){$label=[Windows.Controls.TextBlock]::new();$label.Text=$pair[0];[void]$faCompareTop.Children.Add($label);[void]$faCompareTop.Children.Add($pair[1])}
    $faCompareSummary=[Windows.Controls.TextBlock]::new();$faCompareSummary.TextWrapping='Wrap';$faCompareSummary.Margin='0,8,0,0';[void]$faCompareTop.Children.Add($faCompareSummary);[void]$faComparePanel.Children.Add($faCompareTop)
    $faCompareGrid=& $faNewGrid;foreach($col in @(@('Indicateur','Measure','2*'),@('Premier','Before','*'),@('Second','After','*'),@('Variation','Delta','*'))){& $faAddColumn $faCompareGrid $col[0] $col[1] $col[2]};[void]$faComparePanel.Children.Add($faCompareGrid)
    $faUpdateComparison={
        if($null -eq $faBefore.SelectedItem -or $null -eq $faAfter.SelectedItem){return}
        $comparison=Compare-DomeniaHealthSnapshots $faBefore.SelectedItem $faAfter.SelectedItem;$faCompareSummary.Text=$comparison.Summary+$(if($comparison.Limits.Count){"`n"+($comparison.Limits -join "`n")}else{''});$faCompareGrid.ItemsSource=$comparison.Rows
    }
    $faBefore.Add_SelectionChanged({& $faUpdateComparison});$faAfter.Add_SelectionChanged({& $faUpdateComparison})
    if($faData.HealthHistory.Count -gt 1){$faBefore.SelectedIndex=$faData.HealthHistory.Count-2;$faAfter.SelectedIndex=$faData.HealthHistory.Count-1}else{$faCompareSummary.Text='Un seul relevé disponible. Une comparaison sera possible après le prochain instantané quotidien.'}
    $faCompareTab=[Windows.Controls.TabItem]::new();$faCompareTab.Header='Comparer deux relevés';$faCompareTab.Content=$faComparePanel;[void]$faTabs.Items.Add($faCompareTab)
    # Virtualized non-empty cells avoid building a potentially enormous rectangular matrix.
    $faPivotPanel=[Windows.Controls.DockPanel]::new();$faPivotTop=[Windows.Controls.StackPanel]::new();$faPivotTop.Margin='0,10,0,10';[Windows.Controls.DockPanel]::SetDock($faPivotTop,'Top')
    $faPivotChoice=[Windows.Controls.ComboBox]::new();$faPivotChoice.ItemsSource=@([pscustomobject]@{Id='OuWindows';Name='OU × version de Windows'},[pscustomobject]@{Id='ModelRam';Name='Modèle × RAM'},[pscustomobject]@{Id='SiteCoverage';Name='OU / site × couverture ping et WMI'},[pscustomobject]@{Id='ModelBios';Name='Modèle × version du BIOS'});$faPivotChoice.DisplayMemberPath='Name';$faPivotChoice.Margin='0,0,0,8';[void]$faPivotTop.Children.Add($faPivotChoice)
    $faFilterLabel=[Windows.Controls.TextBlock]::new();$faFilterLabel.Text='Filtrer les catégories';[void]$faPivotTop.Children.Add($faFilterLabel)
    $faFilter=[Windows.Controls.TextBox]::new();$faFilter.MaxLength=256;$faFilter.Margin='0,0,0,8';[void]$faPivotTop.Children.Add($faFilter)
    $faPivotSummary=[Windows.Controls.TextBlock]::new();$faPivotSummary.TextWrapping='Wrap';[void]$faPivotTop.Children.Add($faPivotSummary);[void]$faPivotPanel.Children.Add($faPivotTop)
    $faFooter=[Windows.Controls.StackPanel]::new();$faFooter.Margin='0,10,0,0';[Windows.Controls.DockPanel]::SetDock($faFooter,'Bottom')
    $faDetail=[Windows.Controls.Button]::new();$faDetail.Content='Afficher les postes de la cellule sélectionnée';$faDetail.HorizontalAlignment='Left';$faDetail.IsEnabled=$false;[void]$faFooter.Children.Add($faDetail)
    $faError=[Windows.Controls.TextBlock]::new();$faError.TextWrapping='Wrap';$faError.Margin='0,6,0,0';[void]$faFooter.Children.Add($faError);[void]$faPivotPanel.Children.Add($faFooter)
    $faGrid=& $faNewGrid;& $faAddColumn $faGrid 'Ligne' 'Row' '2*';& $faAddColumn $faGrid 'Colonne' 'Column' '2*';& $faAddColumn $faGrid 'Postes' 'Count' 100;[void]$faPivotPanel.Children.Add($faGrid)
    $faUpdatePivot={
        if($null -eq $faPivotChoice.SelectedItem){return};$table=$faData.Pivots[[string]$faPivotChoice.SelectedItem.Id];$filter=$faFilter.Text.Trim();$rows=@($table.Rows|Where-Object{-not $filter -or $_.Row.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Column.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0})
        $visible=0;foreach($cell in $rows){$visible+=[int]$cell.Count};$faGrid.ItemsSource=$rows;$faPivotSummary.Text=$visible.ToString()+' poste(s) dans '+$rows.Count+' cellule(s) affichée(s), sur '+$table.Total+' comptes activés. Chaque poste compte une fois. Couverture : relevés encore exploitables selon leur date propre.';$faDetail.IsEnabled=$false
    }
    $faGrid.Add_SelectionChanged({$faDetail.IsEnabled=($null -ne $faGrid.SelectedItem)})
    $faPivotChoice.Add_SelectionChanged({& $faUpdatePivot});$faFilter.Add_TextChanged({& $faUpdatePivot});$faPivotChoice.SelectedIndex=0
    $faResult=@{Targets=$null;Label=''}
    $faDetail.Add_Click({
        if($null -eq $faGrid.SelectedItem){return}
        if(-not [object]::ReferenceEquals((Get-DomeniaBoardState Fleet).Data,$faData)){$faError.Text='La vue a été recalculée pendant cette consultation. Fermez puis rouvrez lʼanalyse pour utiliser ses nouvelles cellules.';return}
        $row=$faGrid.SelectedItem;$faResult.Targets=$row.Targets;$faResult.Label=[string]$row.Row+' / '+[string]$row.Column;Set-DomeniaSurfaceResult $faWindow $true
    })
    $faPivotTab=[Windows.Controls.TabItem]::new();$faPivotTab.Header='Tableaux croisés';$faPivotTab.Content=$faPivotPanel;[void]$faTabs.Items.Add($faPivotTab)
    [void]$faRoot.Children.Add($faTabs);$faWindow.Content=$faRoot
    $open=[bool](Show-DomeniaEmbeddedWindow $faWindow)
    if($open -and $null -ne $faResult.Targets){Show-DomeniaAttentionInWorkshop -Targets @($faResult.Targets) -Label $faResult.Label}
}
