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
    $hrBook=Get-DomeniaStoredHealthPolicyBook
    $hrScopeState=@{Dn=$hrDn}
    $hrRuleNames=@{};foreach($rule in @(Get-DomeniaHealthRuleCatalog)){$hrRuleNames[$rule.Id]=$rule.Name}
    $hrRules=[Collections.ObjectModel.ObservableCollection[object]]::new()
    $hrLimits=[Collections.ObjectModel.ObservableCollection[object]]::new()
    $hrCustom=[Collections.ObjectModel.ObservableCollection[object]]::new()
    $hrSuspensions=[Collections.ObjectModel.ObservableCollection[object]]::new()
    $hrSuspensionRow={param($v)
        $until=ConvertFrom-DomeniaUtcText ([string]$v.UntilUtc);$name=[string]$hrRuleNames[[string]$v.RuleId]
        if(-not $name){$match=@($hrCustom|Where-Object{[string]$_.Id -ceq [string]$v.RuleId}|Select-Object -First 1);$name=if($match.Count){[string]$match[0].Name}else{[string]$v.RuleId}}
        [pscustomobject]@{RuleId=[string]$v.RuleId;Name=$name;Reason=[string]$v.Reason;UntilUtc=[string]$v.UntilUtc;UntilLocal=$(if($null -ne $until){$until.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{'Échéance illisible'});State=$(if(($null -ne $until) -and ($until -gt [datetime]::UtcNow)){'Suspendue'}else{'Réactivée (échéance passée)'})}
    }
    $hrWindow=[Windows.Window]::new();$hrWindow.Title='Règles de santé';$hrWindow.Width=920;$hrWindow.Height=660
    $hrRoot=[Windows.Controls.DockPanel]::new();$hrRoot.Margin=[Windows.Thickness]::new(16)
    $hrIntro=[Windows.Controls.TextBlock]::new();$hrIntro.Text='Choisissez les contrôles utiles. Une règle désactivée ne crée ni alerte ni pénalité de score. Les données manquantes restent inconnues. Le calcul et les listes utilisent les mêmes postes de lʼOU. Une OU hérite des réglages de ses OU parentes ; seules ses différences deviennent des exceptions locales.';$hrIntro.TextWrapping='Wrap';$hrIntro.Margin=[Windows.Thickness]::new(0,0,0,14);[Windows.Controls.DockPanel]::SetDock($hrIntro,'Top');[void]$hrRoot.Children.Add($hrIntro)
    $hrFooter=[Windows.Controls.StackPanel]::new();$hrFooter.Margin=[Windows.Thickness]::new(0,12,0,0);[Windows.Controls.DockPanel]::SetDock($hrFooter,'Bottom')
    $hrError=[Windows.Controls.TextBlock]::new();$hrError.TextWrapping='Wrap';$hrError.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'WarningColor');[void]$hrFooter.Children.Add($hrError)
    $hrActions=[Windows.Controls.WrapPanel]::new();$hrActions.HorizontalAlignment='Right'
    $hrCancel=[Windows.Controls.Button]::new();$hrCancel.Content='Annuler';$hrCancel.MinWidth=100;$hrCancel.Margin=[Windows.Thickness]::new(6);$hrCancel.ToolTip='Fermer sans enregistrer : aucune règle nʼest modifiée.';$hrCancel.Add_Click({Set-DomeniaSurfaceResult $hrWindow $false})
    $hrSave=[Windows.Controls.Button]::new();$hrSave.Content='Appliquer';$hrSave.MinWidth=110;$hrSave.Margin=[Windows.Thickness]::new(6);$hrSave.ToolTip='Enregistrer les règles de la portée choisie puis recalculer les vues depuis la base locale.'
    [void]$hrActions.Children.Add($hrCancel);[void]$hrActions.Children.Add($hrSave);[void]$hrFooter.Children.Add($hrActions);[void]$hrRoot.Children.Add($hrFooter)
    $hrScopePanel=[Windows.Controls.StackPanel]::new();$hrScopePanel.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($hrScopePanel,'Top')
    $hrScopeLabel=[Windows.Controls.TextBlock]::new();$hrScopeLabel.Text='Portée des règles';$hrScopeLabel.Margin='0,0,0,4';[void]$hrScopePanel.Children.Add($hrScopeLabel)
    $hrScopeChoice=[Windows.Controls.ComboBox]::new();$hrScopeChoice.DisplayMemberPath='Name';$hrScopeChoice.ToolTip='Domaine, OU parentes, OU affichée ou autre OU possédant déjà une exception.'
    $hrScopeItems=@(Get-DomeniaHealthEditorScopes -Book $hrBook -CurrentDn $hrDn);$hrScopeChoice.ItemsSource=$hrScopeItems
    [void]$hrScopePanel.Children.Add($hrScopeChoice)
    $hrOrigin=[Windows.Controls.TextBlock]::new();$hrOrigin.TextWrapping='Wrap';$hrOrigin.Margin='0,6,0,6';[void]$hrScopePanel.Children.Add($hrOrigin)
    $hrInherit=[Windows.Controls.Button]::new();$hrInherit.Content='Revenir aux règles héritées';$hrInherit.HorizontalAlignment='Left';$hrInherit.ToolTip='Supprimer lʼexception locale de cette OU : elle reprend les réglages hérités.';[void]$hrScopePanel.Children.Add($hrInherit)
    $hrLoad={param([string]$Dn)
        # Point 76: every row carries the origin of its value (domain, ancestor OU or local exception).
        $p=Resolve-DomeniaHealthPolicy $hrBook $Dn;$origins=@{}
        foreach($o in @(Get-DomeniaHealthPolicyOrigins -Book $hrBook -ScopeDn $Dn)){$origins[[string]$o.Kind+'|'+[string]$o.Id]=[string]$o.Origin}
        $hrRules.Clear();foreach($r in @(Get-DomeniaHealthRuleCatalog)){$hrRules.Add([pscustomobject]@{Id=$r.Id;Name=$r.Name;Enabled=(Test-DomeniaHealthRuleEnabled $p $r.Id -IgnoreSuspension);Origin=[string]$origins['Contrôle|'+$r.Id]})}
        $hrLimits.Clear();foreach($l in @(Get-DomeniaHealthThresholdCatalog)){$hrLimits.Add([pscustomobject]@{Id=$l.Id;Name=$l.Name;Value=[string]$p.Thresholds.($l.Id);Bounds=([string]$l.Minimum+' à '+$l.Maximum);Origin=[string]$origins['Seuil|'+$l.Id]})}
        $hrCustom.Clear();foreach($r in @($p.CustomRules)){$hrCustom.Add(($r|ConvertTo-Json -Compress|ConvertFrom-Json))}
        $hrSuspensions.Clear();foreach($v in @($p.Suspensions)){$hrSuspensions.Add((& $hrSuspensionRow $v))}
        $source=Get-DomeniaHealthValue $p 'Origin'
        $hrOrigin.Text='Origine : '+(Format-DomeniaHealthScopeLabel ([string]$source.SourceDn) ([string]$hrBook.DomainDn))+' · alertes personnalisées : '+[string]$origins['Liste|CustomRules']+' · suspensions : '+[string]$origins['Liste|Suspensions']+'. Seules vos différences deviennent des exceptions locales.'
        $hrInherit.IsEnabled=([bool]$Dn -and [bool]$source.Local)
        $hrError.Text=''
    }
    $hrInherit.Add_Click({try{Save-DomeniaHealthPolicy -ScopeDn $hrScopeState.Dn -RemoveOverride;Set-DomeniaSurfaceResult $hrWindow $true}catch{$hrError.Text=$_.Exception.Message}})
    [void]$hrRoot.Children.Add($hrScopePanel)
    $hrTabs=[Windows.Controls.TabControl]::new()
    $hrMakeGrid={param($Rows)$g=[Windows.Controls.DataGrid]::new();$g.AutoGenerateColumns=$false;$g.CanUserAddRows=$false;$g.CanUserDeleteRows=$false;$g.HeadersVisibility='Column';$g.RowHeaderWidth=0;$g.ItemsSource=$Rows;$g.SelectionMode='Single';$g.EnableRowVirtualization=$true;$g.Margin=[Windows.Thickness]::new(0,10,0,0);return $g}
    $hrAddText={param($Grid,$Title,$Path,[bool]$ReadOnly=$false,$Width='*')$c=[Windows.Controls.DataGridTextColumn]::new();$c.Header=$Title;$c.Binding=[Windows.Data.Binding]::new($Path);$c.IsReadOnly=$ReadOnly;$c.Width=$Width;[void]$Grid.Columns.Add($c)}
    $hrAddCheck={param($Grid)$c=[Windows.Controls.DataGridCheckBoxColumn]::new();$c.Header='Activée';$c.Binding=[Windows.Data.Binding]::new('Enabled');$c.Width=72;[void]$Grid.Columns.Add($c)}
    $hrRuleGrid=& $hrMakeGrid $hrRules;$hrRuleGrid.ToolTip='Cochez les contrôles utiles. La colonne Origine indique dʼoù vient le réglage actuel.';& $hrAddCheck $hrRuleGrid;& $hrAddText $hrRuleGrid 'Contrôle' 'Name' $true;& $hrAddText $hrRuleGrid 'Origine' 'Origin' $true 240
    $hrRuleTab=[Windows.Controls.TabItem]::new();$hrRuleTab.Header='Contrôles';$hrRuleTab.Content=$hrRuleGrid;[void]$hrTabs.Items.Add($hrRuleTab)
    $hrLimitGrid=& $hrMakeGrid $hrLimits;$hrLimitGrid.ToolTip='Modifiez la valeur dans les bornes autorisées. La colonne Origine indique dʼoù vient le seuil actuel.';& $hrAddText $hrLimitGrid 'Seuil' 'Name' $true;& $hrAddText $hrLimitGrid 'Valeur' 'Value' $false 95;& $hrAddText $hrLimitGrid 'Valeurs autorisées' 'Bounds' $true 130;& $hrAddText $hrLimitGrid 'Origine' 'Origin' $true 220
    $hrLimitTab=[Windows.Controls.TabItem]::new();$hrLimitTab.Header='Seuils';$hrLimitTab.Content=$hrLimitGrid;[void]$hrTabs.Items.Add($hrLimitTab)
    $hrCustomPanel=[Windows.Controls.DockPanel]::new();$hrCustomActions=[Windows.Controls.WrapPanel]::new();$hrCustomActions.Margin=[Windows.Thickness]::new(0,10,0,0);[Windows.Controls.DockPanel]::SetDock($hrCustomActions,'Top')
    $hrAdd=[Windows.Controls.Button]::new();$hrAdd.Content='Ajouter une alerte';$hrAdd.Margin=[Windows.Thickness]::new(0,0,8,0);$hrAdd.ToolTip='Ajouter une alerte personnalisée sur une mesure du poste (32 au maximum).'
    $hrDelete=[Windows.Controls.Button]::new();$hrDelete.Content='Supprimer lʼalerte sélectionnée';$hrDelete.ToolTip='Retirer définitivement cette alerte personnalisée. Pour la masquer quelque temps, utilisez plutôt lʼonglet Suspensions.'
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
    $hrLegend=[Windows.Controls.TextBlock]::new();$hrLegend.Text='Le disque et le démarrage sont disponibles après le relevé WMI de lʼOU. La mémoire utilisée demande lʼinventaire détaillé du poste. Une mesure absente reste inconnue. Supprimer retire définitivement la règle, sans effacer les données collectées ; masquer temporairement une alerte se fait dans lʼonglet Suspensions.';$hrLegend.TextWrapping='Wrap';$hrLegend.Margin=[Windows.Thickness]::new(0,8,0,0);[Windows.Controls.DockPanel]::SetDock($hrLegend,'Bottom');[void]$hrCustomPanel.Children.Add($hrLegend);[void]$hrCustomPanel.Children.Add($hrCustomGrid)
    $hrCustomTab=[Windows.Controls.TabItem]::new();$hrCustomTab.Header='Mes alertes';$hrCustomTab.Content=$hrCustomPanel;[void]$hrTabs.Items.Add($hrCustomTab)
    $hrAdd.Add_Click({if($hrCustom.Count -ge 32){$hrError.Text='32 alertes personnalisées au maximum.';return};$hrCustom.Add([pscustomobject]@{Id=('custom.'+[guid]::NewGuid().ToString('N'));Name='Espace disque à surveiller';Measure='DiskFree';Operator='LessThan';Threshold=15;Severity='Warn';Enabled=$true})})
    $hrDelete.Add_Click({$selected=$hrCustomGrid.SelectedItem;if($null -ne $selected){[void]$hrCustom.Remove($selected)}})
    $hrSuspendPanel=[Windows.Controls.DockPanel]::new();$hrSuspendActions=[Windows.Controls.StackPanel]::new();$hrSuspendActions.Margin='0,10,0,10';[Windows.Controls.DockPanel]::SetDock($hrSuspendActions,'Top')
    $hrSuspendNote=[Windows.Controls.TextBlock]::new();$hrSuspendNote.Text='Suspendre masque temporairement un contrôle pour la portée choisie : il sort du score, mais les postes quʼil aurait signalés restent affichés dans « Comprendre le score ». Le motif et lʼéchéance sont obligatoires ; le contrôle reprend seul au premier recalcul après lʼéchéance, ou tout de suite avec « Réactiver maintenant ». Aucune donnée collectée nʼest effacée et la règle nʼest pas supprimée. Une suspension terminée reste listée 30 jours.';$hrSuspendNote.TextWrapping='Wrap';$hrSuspendNote.Margin='0,0,0,8';[void]$hrSuspendActions.Children.Add($hrSuspendNote)
    $hrSuspendChoice=[Windows.Controls.ComboBox]::new();$hrSuspendChoice.DisplayMemberPath='Name';$hrSuspendChoice.ItemsSource=@(Get-DomeniaHealthRuleCatalog)+@($hrCustom);$hrSuspendChoice.SelectedIndex=0;$hrSuspendChoice.Margin='0,0,0,6';$hrSuspendChoice.ToolTip='Contrôle à suspendre temporairement.';[void]$hrSuspendActions.Children.Add($hrSuspendChoice)
    $hrSuspendReason=[Windows.Controls.TextBox]::new();$hrSuspendReason.MaxLength=240;$hrSuspendReason.MinWidth=260;$hrSuspendReason.Margin='0,0,0,6';$hrSuspendReason.ToolTip='Motif obligatoire, de 3 à 240 caractères, visible dans lʼexplication du score.'
    $hrReasonLabel=[Windows.Controls.TextBlock]::new();$hrReasonLabel.Text='Motif (obligatoire)';[void]$hrSuspendActions.Children.Add($hrReasonLabel);[void]$hrSuspendActions.Children.Add($hrSuspendReason)
    $hrSuspendLine=[Windows.Controls.WrapPanel]::new();$hrSuspendDuration=[Windows.Controls.ComboBox]::new();$hrSuspendDuration.DisplayMemberPath='Name';$hrSuspendDuration.ItemsSource=@([pscustomobject]@{Name='1 heure';Hours=1},[pscustomobject]@{Name='24 heures';Hours=24},[pscustomobject]@{Name='7 jours';Hours=168},[pscustomobject]@{Name='30 jours';Hours=720});$hrSuspendDuration.SelectedIndex=1;$hrSuspendDuration.MinWidth=130;$hrSuspendDuration.ToolTip='Échéance de la suspension, à partir de maintenant.'
    $hrSuspendAdd=[Windows.Controls.Button]::new();$hrSuspendAdd.Content='Suspendre';$hrSuspendAdd.Margin='8,0,8,0';$hrSuspendAdd.ToolTip='Ajouter la suspension à la liste ; elle sʼapplique après Appliquer.'
    $hrSuspendRemove=[Windows.Controls.Button]::new();$hrSuspendRemove.Content='Réactiver maintenant';$hrSuspendRemove.ToolTip='Retirer la suspension sélectionnée : le contrôle compte de nouveau après Appliquer.'
    foreach($control in @($hrSuspendDuration,$hrSuspendAdd,$hrSuspendRemove)){[void]$hrSuspendLine.Children.Add($control)};[void]$hrSuspendActions.Children.Add($hrSuspendLine);[void]$hrSuspendPanel.Children.Add($hrSuspendActions)
    $hrSuspendGrid=& $hrMakeGrid $hrSuspensions;$hrSuspendGrid.IsReadOnly=$true;& $hrAddText $hrSuspendGrid 'Contrôle' 'Name' $true 180;& $hrAddText $hrSuspendGrid 'Motif' 'Reason' $true;& $hrAddText $hrSuspendGrid 'Jusquʼau (heure locale)' 'UntilLocal' $true 150;& $hrAddText $hrSuspendGrid 'État' 'State' $true 170
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
        $candidate=(ConvertTo-DomeniaHealthSuspensions @([pscustomobject]@{RuleId=$id;Reason=$hrSuspendReason.Text;UntilUtc=$until.ToString('o')}) -Strict)[0]
        foreach($old in @($hrSuspensions|Where-Object{$_.RuleId -ceq $id})){[void]$hrSuspensions.Remove($old)}
        $hrSuspensions.Add((& $hrSuspensionRow $candidate));$hrError.Text=''
    }catch{$hrError.Text=$_.Exception.Message}})
    $hrSuspendRemove.Add_Click({if($null -ne $hrSuspendGrid.SelectedItem){[void]$hrSuspensions.Remove($hrSuspendGrid.SelectedItem)}})
    # Point 76: every local exception of the domain, readable without opening each OU.
    $hrExceptionPanel=[Windows.Controls.DockPanel]::new()
    $hrExceptionTop=[Windows.Controls.StackPanel]::new();$hrExceptionTop.Margin='0,10,0,8';[Windows.Controls.DockPanel]::SetDock($hrExceptionTop,'Top')
    $hrExceptionNote=[Windows.Controls.TextBlock]::new();$hrExceptionNote.TextWrapping='Wrap';$hrExceptionNote.Margin='0,0,0,6';[void]$hrExceptionTop.Children.Add($hrExceptionNote)
    $hrExceptionOpen=[Windows.Controls.Button]::new();$hrExceptionOpen.Content='Modifier cette exception';$hrExceptionOpen.HorizontalAlignment='Left';$hrExceptionOpen.IsEnabled=$false;$hrExceptionOpen.ToolTip='Choisir lʼOU sélectionnée comme portée des onglets Contrôles, Seuils, Mes alertes et Suspensions.';[void]$hrExceptionTop.Children.Add($hrExceptionOpen)
    [void]$hrExceptionPanel.Children.Add($hrExceptionTop)
    $hrExceptionRows=@(Get-DomeniaHealthPolicyExceptions -Book $hrBook -NowUtc ([datetime]::UtcNow))
    $hrExceptionNote.Text=if($hrExceptionRows.Count){[string]$hrExceptionRows.Count+' OU possèdent une exception locale. Chaque ligne indique ce qui diffère des réglages hérités.'}else{'Aucune exception : toutes les OU appliquent les règles par défaut du domaine.'}
    $hrExceptionGrid=& $hrMakeGrid $hrExceptionRows;$hrExceptionGrid.IsReadOnly=$true;$hrExceptionGrid.ToolTip='Exceptions locales enregistrées pour ce domaine.';& $hrAddText $hrExceptionGrid 'OU' 'Label' $true 260;& $hrAddText $hrExceptionGrid 'Différences avec les réglages hérités' 'Changes' $true
    [void]$hrExceptionPanel.Children.Add($hrExceptionGrid)
    $hrExceptionGrid.Add_SelectionChanged({$hrExceptionOpen.IsEnabled=($null -ne $hrExceptionGrid.SelectedItem)})
    $hrExceptionOpen.Add_Click({
        $wanted=[string]$hrExceptionGrid.SelectedItem.ScopeDn
        $match=@($hrScopeChoice.Items|Where-Object{[string]$_.Dn -ieq $wanted}|Select-Object -First 1)
        if($match.Count){$hrScopeChoice.SelectedItem=$match[0];$hrTabs.SelectedIndex=0}else{$hrError.Text='Cette OU ne figure plus dans la liste des portées.'}
    })
    $hrExceptionTab=[Windows.Controls.TabItem]::new();$hrExceptionTab.Header='Exceptions par OU';$hrExceptionTab.Content=$hrExceptionPanel;[void]$hrTabs.Items.Add($hrExceptionTab)
    $hrSave.Add_Click({
        try{
            foreach($g in @($hrRuleGrid,$hrLimitGrid,$hrCustomGrid)){
                if(-not $g.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true) -or -not $g.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true)){throw 'Corrigez la valeur de la cellule en cours avant dʼappliquer les règles.'}
            }
            $limits=@{};foreach($row in $hrLimits){$limits[$row.Id]=$row.Value}
            $customIds=@($hrCustom|ForEach-Object{[string]$_.Id})
            $kept=@($hrSuspensions|Where-Object{(-not ([string]$_.RuleId).StartsWith('custom.')) -or ($customIds -contains [string]$_.RuleId)})
            $policy=ConvertTo-DomeniaHealthPolicy ([pscustomobject]@{Thresholds=$limits;DisabledRules=@($hrRules|Where-Object{-not $_.Enabled}|ForEach-Object{$_.Id});CustomRules=@($hrCustom);Suspensions=@(Optimize-DomeniaHealthSuspensions -Suspensions $kept -NowUtc ([datetime]::UtcNow))}) -Strict
            Save-DomeniaHealthPolicy $policy -ScopeDn $hrScopeState.Dn
            Set-DomeniaSurfaceResult $hrWindow $true
        }catch{$hrError.Text=$_.Exception.Message}
    })
    [void]$hrRoot.Children.Add($hrTabs);$hrWindow.Content=$hrRoot
    # Initial scope selected before the handler is attached: the rows are loaded once, explicitly.
    $hrInitial=@($hrScopeItems|Where-Object{[string]$_.Dn -ieq $hrDn}|Select-Object -First 1)
    if($hrInitial.Count){$hrScopeChoice.SelectedItem=$hrInitial[0]}else{$hrScopeChoice.SelectedIndex=0}
    $hrScopeState.Dn=[string](Get-DomeniaHealthValue $hrScopeChoice.SelectedItem 'Dn' '')
    & $hrLoad $hrScopeState.Dn
    $hrScopeChoice.Add_SelectionChanged({if($null -eq $hrScopeChoice.SelectedItem){return};$hrScopeState.Dn=[string]$hrScopeChoice.SelectedItem.Dn;try{& $hrLoad $hrScopeState.Dn}catch{$hrError.Text=$_.Exception.Message}})
    $saved=[bool](Show-DomeniaEmbeddedWindow $hrWindow)
    if($saved){
        Request-DomeniaFleetRefresh -Force
        if($null -ne $script:SelectedObject -and $script:SelectedObject.Type -eq 'Machine'){[void](Show-DomeniaCachedInventory -Computer (Get-CurrentSelectedComputerName))}
        Set-Status 'Règles enregistrées ; vues recalculées depuis la base locale.'
    }
    return $saved
}

function Show-DomeniaHealthExplanation {
    # Point 75: contributions of each rule, eligible population and what disabled or suspended rules would flag.
    param([ValidateSet('Fleet','Computer')][string]$Board='Fleet')
    $heData=(Get-DomeniaBoardState $Board).Data
    if($null -eq $heData){Set-Status 'Calculez dʼabord le tableau de bord depuis la base locale.';return}
    $heExplanation=Get-DomeniaHealthValue $heData 'HealthExplanation'
    if($null -eq $heExplanation){$heExplanation=Get-DomeniaHealthExplanation $heData}
    $heFleet=($Board -eq 'Fleet')
    $heWindow=[Windows.Window]::new();$heWindow.Title='Comprendre le score de santé';$heWindow.Width=900;$heWindow.Height=660
    $hePanel=[Windows.Controls.DockPanel]::new();$hePanel.Margin='12'
    $heCounts=[string]$heExplanation.ActiveRules+' règle(s) activée(s) · '+$heExplanation.DisabledRules+' désactivée(s) · '+[int](Get-DomeniaHealthValue $heExplanation 'SuspendedRules' 0)+' suspendue(s)'
    $heMasked=[int](Get-DomeniaHealthValue $heExplanation 'MaskedMachines' 0)
    if($heMasked){$heCounts+=' · '+$(if($heFleet){[string]$heMasked+' poste(s) masqué(s) par une règle désactivée ou suspendue'}else{[string]$heMasked+' contrôle(s) masqué(s) sur ce poste'})}
    $heSummary=[Windows.Controls.TextBlock]::new();$heSummary.Text=[string]$heExplanation.Summary+"`n"+$heCounts+$(if($heExplanation.Scope){"`nPérimètre : "+$heExplanation.Scope}else{''})
    $heSummary.TextWrapping='Wrap';$heSummary.Margin='0,0,0,16';[Windows.Controls.DockPanel]::SetDock($heSummary,'Top');[void]$hePanel.Children.Add($heSummary)
    $heResult=@{Targets=$null;Label=''}
    $heFooter=[Windows.Controls.StackPanel]::new();$heFooter.Margin='0,10,0,0';[Windows.Controls.DockPanel]::SetDock($heFooter,'Bottom')
    $heButtons=[Windows.Controls.WrapPanel]::new()
    $heShowFlagged=[Windows.Controls.Button]::new();$heShowFlagged.Content='Afficher les postes signalés';$heShowFlagged.Margin='0,0,8,0';$heShowFlagged.IsEnabled=$false;$heShowFlagged.ToolTip='Ouvrir dans lʼatelier les postes que ce contrôle retire des postes sains.'
    $heShowMasked=[Windows.Controls.Button]::new();$heShowMasked.Content='Afficher les postes masqués';$heShowMasked.IsEnabled=$false;$heShowMasked.ToolTip='Ouvrir dans lʼatelier les postes que ce contrôle signalerait sʼil nʼétait ni désactivé ni suspendu.'
    [void]$heButtons.Children.Add($heShowFlagged);[void]$heButtons.Children.Add($heShowMasked)
    $heError=[Windows.Controls.TextBlock]::new();$heError.TextWrapping='Wrap';$heError.Margin='0,6,0,0'
    if($heFleet){[void]$heFooter.Children.Add($heButtons);[void]$heFooter.Children.Add($heError);[void]$hePanel.Children.Add($heFooter)}
    $heGrid=[Windows.Controls.DataGrid]::new();$heGrid.IsReadOnly=$true;$heGrid.AutoGenerateColumns=$false;$heGrid.CanUserAddRows=$false;$heGrid.CanUserDeleteRows=$false;$heGrid.EnableRowVirtualization=$true;$heGrid.SelectionMode='Single';$heGrid.ItemsSource=$heExplanation.Rows
    $heGrid.ToolTip='Évaluables : postes dont la donnée est connue pour ce contrôle. Un poste peut être signalé par plusieurs contrôles : les colonnes ne sʼadditionnent pas.'
    foreach($field in @(@('Contrôle','Rule','2*'),@('État','Status',110),@('Évaluables','Eligible',110),@($(if($heFleet){'Postes signalés'}else{'Signalé'}),'Machines',90),@('Effet sur le score','Effect','2*'),@('Si la règle comptait','Consequence','2*'))){$col=[Windows.Controls.DataGridTextColumn]::new();$col.Header=$field[0];$col.Binding=[Windows.Data.Binding]::new($field[1]);$col.Width=$field[2];[void]$heGrid.Columns.Add($col)}
    $heGrid.Add_SelectionChanged({$row=$heGrid.SelectedItem;$heShowFlagged.IsEnabled=(($null -ne $row) -and (@($row.Guids).Count -gt 0));$heShowMasked.IsEnabled=(($null -ne $row) -and (@($row.MaskedGuids).Count -gt 0))})
    $heOpen={param([object[]]$Guids,[string]$Label)
        if(-not [object]::ReferenceEquals((Get-DomeniaBoardState Fleet).Data,$heData)){$heError.Text='La vue a été recalculée pendant cette consultation. Fermez puis rouvrez lʼexplication.';return}
        $wanted=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($guid in $Guids){[void]$wanted.Add([string]$guid)}
        $heResult.Targets=@(foreach($target in @($heData.Last.Targets)){if($null -ne $target -and $wanted.Contains([string]$target.object_guid)){$target}});$heResult.Label=$Label
        Set-DomeniaSurfaceResult $heWindow $true
    }
    $heShowFlagged.Add_Click({$row=$heGrid.SelectedItem;if($null -ne $row){& $heOpen @($row.Guids) ([string]$row.Rule+' · postes signalés')}})
    $heShowMasked.Add_Click({$row=$heGrid.SelectedItem;if($null -ne $row){& $heOpen @($row.MaskedGuids) ([string]$row.Rule+' · postes masqués')}})
    $heTabs=[Windows.Controls.TabControl]::new();$heRulesTab=[Windows.Controls.TabItem]::new();$heRulesTab.Header='Contrôles et score';$heRulesTab.Content=$heGrid;[void]$heTabs.Items.Add($heRulesTab)
    $hePolicies=@(Get-DomeniaHealthValue $heExplanation 'Policies' @())
    if($hePolicies.Count){
        $hePolicyGrid=[Windows.Controls.DataGrid]::new();$hePolicyGrid.IsReadOnly=$true;$hePolicyGrid.AutoGenerateColumns=$false;$hePolicyGrid.CanUserAddRows=$false;$hePolicyGrid.CanUserDeleteRows=$false;$hePolicyGrid.EnableRowVirtualization=$true;$hePolicyGrid.ItemsSource=$hePolicies
        foreach($field in @(@('Origine des règles','Scope','2*'),@('Postes','Machines',70),@('Suspensions','Suspended',95),@('Seuils appliqués','Thresholds','2*'))){$col=[Windows.Controls.DataGridTextColumn]::new();$col.Header=$field[0];$col.Binding=[Windows.Data.Binding]::new($field[1]);$col.Width=$field[2];[void]$hePolicyGrid.Columns.Add($col)}
        $hePolicyTab=[Windows.Controls.TabItem]::new();$hePolicyTab.Header='Règles appliquées par OU';$hePolicyTab.Content=$hePolicyGrid;[void]$heTabs.Items.Add($hePolicyTab)
    }
    [void]$hePanel.Children.Add($heTabs);$heWindow.Content=$hePanel
    $heOpened=[bool](Show-DomeniaEmbeddedWindow $heWindow)
    if($heOpened -and $null -ne $heResult.Targets){Show-DomeniaAttentionInWorkshop -Targets @($heResult.Targets) -Label $heResult.Label}
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
    $faPivotChoice=[Windows.Controls.ComboBox]::new();$faPivotChoice.ItemsSource=@([pscustomobject]@{Id='OuWindows';Name='OU × version de Windows'},[pscustomobject]@{Id='ModelRam';Name='Modèle × RAM'},[pscustomobject]@{Id='SiteCoverage';Name='OU / site × couverture ping et WMI'});$faPivotChoice.DisplayMemberPath='Name';$faPivotChoice.Margin='0,0,0,8';[void]$faPivotTop.Children.Add($faPivotChoice)
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
