# Search workspace of the Rechercher page (points 56 to 60): saved views, visible filter chips, explicit collective
# scope, side preview and workstation comparison. Rules come from Domenia-SearchWorkspace.Model.ps1. A view, a chip,
# the preview or the comparison never contacts the directory or a workstation by itself: the preview and the
# comparison only read the committed local SQLite base; removing the type chip reads the OU again and says so.
$script:SearchWorkspaceBound=$false
$script:SearchWorkspaceUndo=$null
$script:SearchWorkspaceTimer=$null
$script:SearchWorkspacePendingSort=$null
$script:SearchPreviewToken=''
$script:SearchPreviewPending=$false

# ---------------------------------------------------------------- Point 57: saved views
function Get-DomeniaResultPresentation {
    $grid=Get-DomeniaControl 'DgObjects';$columns=[Collections.Generic.List[object]]::new()
    if($null -eq $grid){return [pscustomobject]@{Columns=@();Sort=@()}}
    $index=0
    foreach($column in $grid.Columns){
        $columns.Add([pscustomobject]@{Key=(Get-DomeniaGridColumnKey $column $index);Index=$column.DisplayIndex;Width=$column.Width.Value.ToString('R',[Globalization.CultureInfo]::InvariantCulture);Unit=$column.Width.UnitType.ToString()});$index++
    }
    return [pscustomobject]@{Columns=$columns.ToArray();Sort=@(Get-DomeniaGridSort $grid)}
}
function Restore-DomeniaResultPresentation {
    # Columns (order and width) apply at once; the sort applies to the next list shown, since a new list resets it.
    param($Presentation)
    $grid=Get-DomeniaControl 'DgObjects';if(($null -eq $grid) -or ($null -eq $Presentation)){return}
    $keys=@{};$index=0;foreach($column in $grid.Columns){$keys[(Get-DomeniaGridColumnKey $column $index)]=$column;$index++}
    # ConvertTo-DomeniaColumnLayout returns its array as one object: assigned first, then enumerated.
    $layout=ConvertTo-DomeniaColumnLayout $Presentation.Columns
    foreach($item in @($layout|Sort-Object Index)){
        if(-not $keys.ContainsKey([string]$item.Key)){continue};$column=$keys[[string]$item.Key]
        $column.Width=[Windows.Controls.DataGridLength]::new([double]$item.Width,[Windows.Controls.DataGridLengthUnitType]([string]$item.Unit))
        $column.DisplayIndex=[Math]::Min($grid.Columns.Count-1,[int]$item.Index)
    }
    Set-DomeniaGridSort -Grid $grid -Sort @($Presentation.Sort)
    $script:SearchWorkspacePendingSort=[pscustomobject]@{Sort=@($Presentation.Sort);Epoch=[long]$script:SessionEpoch}
}
function Get-DomeniaSearchWorkspaceStore {
    return (ConvertFrom-DomeniaSearchWorkspaceStore -Text ([string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]')) -DomainDn ([string]$script:Conn.BaseDn))
}
function Get-DomeniaSearchWorkspaces {
    return @((Get-DomeniaSearchWorkspaceStore).Views)
}
function Update-DomeniaSearchWorkspaceButtons {
    $combo=Get-DomeniaControl 'CmbSearchWorkspace';$selected=$null;if($null -ne $combo){$selected=$combo.SelectedItem}
    $canSave=(([bool][string]$script:Conn.BaseDn) -and ([bool][string]$script:SelectedBranchDn))
    foreach($pair in @(@('BtnSearchWorkspaceSave',$canSave),@('BtnSearchWorkspaceOpen',($null -ne $selected)),@('BtnSearchWorkspaceRemove',($null -ne $selected)),@('BtnSearchWorkspaceUndo',($null -ne $script:SearchWorkspaceUndo)))){
        $button=Get-DomeniaControl $pair[0]
        if(($null -ne $button) -and ([bool]$button.IsEnabled -ne [bool]$pair[1])){$button.IsEnabled=[bool]$pair[1]}
    }
}
function Update-DomeniaSearchWorkspaces {
    $combo=Get-DomeniaControl 'CmbSearchWorkspace';if($null -eq $combo){return}
    $id='';if($null -ne $combo.SelectedItem){$id=[string]$combo.SelectedItem.Id}
    try{
        $store=Get-DomeniaSearchWorkspaceStore
        $rows=@(foreach($view in @($store.Views)){
            # The label shows the name, then the OU, the depth and the type: two views stay easy to tell apart.
            $view|Add-Member -NotePropertyName Label -NotePropertyValue (Get-DomeniaSearchWorkspaceLabel $view) -Force
            $view
        })
        $combo.ItemsSource=$rows;$combo.DisplayMemberPath='Label';$combo.SelectedIndex=-1
        foreach($row in $rows){if([string]$row.Id -ceq $id){$combo.SelectedItem=$row;break}}
        if([int]$store.Rejected -gt 0){Set-Status ([string]$store.Rejected+' vue(s) enregistrée(s) illisible(s) ignorée(s) ; elles restent stockées telles quelles.') 'WARN'}
    }catch{$combo.ItemsSource=@();Set-Status ('Vues personnelles non chargées : '+$_.Exception.Message) 'WARN'}
    Update-DomeniaSearchWorkspaceButtons
}
function Save-DomeniaSearchWorkspace {
    try{
        if(((Get-DomeniaSearchMode) -ne 'OU') -or (-not [string]$script:SelectedBranchDn)){throw 'Choisissez une OU dans lʼarbre pour enregistrer une vue.'}
        $domain=[string]$script:Conn.BaseDn;if(-not $domain){throw 'Connectez-vous avant dʼenregistrer une vue.'}
        $form=Show-DomeniaFormDialog -Title 'Enregistrer une vue' -Message 'Mémorise lʼOU, la profondeur, le type, la présence, le filtre local, la limite, les colonnes (ordre et largeur) et le tri. Les résultats et les mots de passe ne font pas partie de la vue.' -Fields @(@{Name='Name';Label='Nom de la vue';Value=''}) -AcceptText 'Enregistrer'
        if($null -eq $form){return}
        $name=([string]$form.Name).Trim();if(-not $name){Set-Status 'Vue non enregistrée : nom vide.' 'WARN';return}
        $presentation=Get-DomeniaResultPresentation
        $type=Get-DomeniaControl 'CmbGlobalType';$presence=Get-DomeniaControl 'CmbPresenceFilter';$filter=Get-DomeniaControl 'TxtSuiteResultFilter';$limit=Get-DomeniaControl 'TxtGlobalLimit';$subtree=Get-DomeniaControl 'ChkSubtree'
        $candidate=[pscustomobject]@{
            Version=1;Id=[guid]::NewGuid().ToString('D');Name=$name;DomainDn=$domain;OuDn=[string]$script:SelectedBranchDn
            Subtree=(($null -eq $subtree) -or ([bool]$subtree.IsChecked))
            TypeLabel=$(if(($null -ne $type) -and ($null -ne $type.SelectedItem)){[string]$type.SelectedItem.Content}else{'Tous'})
            Presence=$(if(($null -ne $presence) -and ($null -ne $presence.SelectedItem)){[string]$presence.SelectedItem.Content}else{'Tous'})
            LocalFilter=$(if($null -ne $filter){[string]$filter.Text}else{''});Limit=$(if($null -ne $limit){[string]$limit.Text}else{'100'})
            Columns=$presentation.Columns;Sort=$presentation.Sort
        }
        $previous=[string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]')
        $store=ConvertFrom-DomeniaSearchWorkspaceStore -Text $previous -DomainDn $domain
        $added=Add-DomeniaSearchWorkspaceRecord -Items $store.All -Candidate $candidate -DomainDn $domain
        Set-DomeniaSetting 'Search.WorkspacesJson' (ConvertTo-DomeniaSearchWorkspaceStoreText -Items $added.Items)
        try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{Set-DomeniaSetting 'Search.WorkspacesJson' $previous;throw}
        $script:SearchWorkspaceUndo=$null
        Update-DomeniaSearchWorkspaces
        $combo=Get-DomeniaControl 'CmbSearchWorkspace'
        if($null -ne $combo){foreach($row in @($combo.ItemsSource)){if([string]$row.Id -ceq [string]$added.Record.Id){$combo.SelectedItem=$row;break}}}
        Update-DomeniaSearchWorkspaceButtons
        Set-Status ('Vue enregistrée : '+[string]$added.Record.Name+'. Aucun résultat ni mot de passe nʼest conservé.')
    }catch{Set-Status ('Vue non enregistrée : '+$_.Exception.Message) 'WARN'}
}
function Remove-DomeniaSearchWorkspace {
    try{
        $combo=Get-DomeniaControl 'CmbSearchWorkspace';if(($null -eq $combo) -or ($null -eq $combo.SelectedItem)){return}
        $selected=$combo.SelectedItem;$domain=[string]$script:Conn.BaseDn
        $previous=[string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]')
        $store=ConvertFrom-DomeniaSearchWorkspaceStore -Text $previous -DomainDn $domain
        $removed=Remove-DomeniaSearchWorkspaceRecord -Items $store.All -Id ([string]$selected.Id) -DomainDn $domain
        if([int]$removed.Removed -lt 1){throw 'Cette vue nʼest plus enregistrée.'}
        $after=ConvertTo-DomeniaSearchWorkspaceStoreText -Items $removed.Items
        Set-DomeniaSetting 'Search.WorkspacesJson' $after
        try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{Set-DomeniaSetting 'Search.WorkspacesJson' $previous;throw}
        $script:SearchWorkspaceUndo=[pscustomobject]@{Before=$previous;After=$after;Name=[string]$selected.Name}
        Update-DomeniaSearchWorkspaces
        Set-Status ('Vue « '+[string]$selected.Name+' » retirée. Annuler la restaure tant que les vues ne changent pas.')
    }catch{Set-Status ('Vue non retirée : '+$_.Exception.Message) 'WARN'}
}
function Undo-DomeniaSearchWorkspace {
    $undo=$script:SearchWorkspaceUndo;if($null -eq $undo){return}
    try{
        # Views changed since the removal: restoring the former text would undo those changes too, so the undo ends.
        if([string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]') -cne [string]$undo.After){$script:SearchWorkspaceUndo=$null;throw 'Les vues ont changé depuis ce retrait.'}
        Set-DomeniaSetting 'Search.WorkspacesJson' ([string]$undo.Before)
        # A failed write (disk busy or locked) keeps the undo: Annuler stays available and can be tried again.
        try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{Set-DomeniaSetting 'Search.WorkspacesJson' ([string]$undo.After);throw}
        $script:SearchWorkspaceUndo=$null;Update-DomeniaSearchWorkspaces;Set-Status ('Vue « '+[string]$undo.Name+' » restaurée.')
    }catch{
        $retry=$(if($null -ne $script:SearchWorkspaceUndo){' Réessayez Annuler.'}else{''})
        Update-DomeniaSearchWorkspaceButtons;Set-Status ('Annulation non appliquée : '+$_.Exception.Message+$retry) 'WARN'
    }
}
function Open-DomeniaSearchWorkspace {
    try{
        $combo=Get-DomeniaControl 'CmbSearchWorkspace';if(($null -eq $combo) -or ($null -eq $combo.SelectedItem)){return}
        $view=ConvertTo-DomeniaSearchWorkspace $combo.SelectedItem ([string]$script:Conn.BaseDn)
        if(Test-DomeniaAccessBusyWrite){throw 'Une écriture est en cours.'};if(@(Get-DomeniaDirtyFields).Count){throw 'Enregistrez ou abandonnez la fiche modifiée avant de changer de vue.'}
        Enter-DomeniaNavSearch;Stop-DomeniaPendingFilterChange
        $oldRestore=[bool]$script:RestoringSettings;$oldAuto=[bool]$script:SuppressBranchAutoLoad;$oldExperience=[bool]$script:ExperienceRestoring
        $script:RestoringSettings=$true;$script:SuppressBranchAutoLoad=$true;$script:ExperienceRestoring=$true
        try{
            $script:SelectedBranchDn=$view.OuDn;Set-DomeniaSearchMode -Mode OU
            (Get-DomeniaControl 'ChkSubtree').IsChecked=$view.Subtree;(Get-DomeniaControl 'TxtGlobalLimit').Text=[string]$view.Limit
            foreach($pair in @(@('CmbGlobalType',$view.TypeLabel),@('CmbPresenceFilter',$view.Presence))){$box=Get-DomeniaControl $pair[0];foreach($item in $box.Items){if([string]$item.Content -ceq $pair[1]){$box.SelectedItem=$item;break}}}
            $script:CurrentPresenceFilter=$view.Presence;(Get-DomeniaControl 'TxtSuiteResultFilter').Text=$view.LocalFilter
            $script:ActiveSearchViewId='';$script:SearchQueryRun=$null;$script:BranchObjects=@();(Get-DomeniaControl 'DgObjects').ItemsSource=@()
            $script:NavHistoryRows=$null;$script:NavHistoryState=$null;Reset-DomeniaLiveIdentity
            Restore-DomeniaResultPresentation $view
            [void](Set-DomeniaControlText 'LblBranchCount' 'Vue préparée · résultats à relire')
            [void](Set-DomeniaControlText 'LblSearchQuery' 'Aucune requête appliquée. La vue mémorise la présentation et les filtres.')
            Update-DomeniaSearchScopeUi;Update-DomeniaOuBreadcrumb $view.OuDn
            # The tree shows the OU of the view when its item is already read; nothing is read to find it.
            [void](Select-DomeniaRealizedTreeNode -Dn $view.OuDn)
        }finally{$script:RestoringSettings=$oldRestore;$script:SuppressBranchAutoLoad=$oldAuto;$script:ExperienceRestoring=$oldExperience}
        # Opening a preference is inert. The operator chooses AD refresh or a local query next.
        $script:NavSearchLaunching=$false
        Request-DomeniaSearchWorkspaceRefresh
        Set-Status ('Vue « '+$view.Name+' » préparée. Lancez une requête locale ou Actualiser pour remplir les résultats ; le tri de la vue sʼappliquera à cette liste.')
    }catch{Set-Status ('Vue non ouverte : '+$_.Exception.Message) 'WARN'}
}

# ---------------------------------------------------------------- Point 56: visible filter chips
function Get-DomeniaSearchLoadedCount {
    # Rows loaded for the list on screen, before the local filters.
    if(($null -ne $script:Live) -and ($null -ne $script:Live.Search) -and (Test-DomeniaLiveSearchActive)){try{return [int]$script:Live.Search.Rows.Count}catch{}}
    return [int]@($script:BranchObjects).Count
}
function Get-DomeniaSearchFilterState {
    # The criteria of the list on screen, read from its visible controls and from the query that produced it.
    $type=Get-DomeniaControl 'CmbGlobalType';$presence=Get-DomeniaControl 'CmbPresenceFilter';$local=Get-DomeniaControl 'TxtSuiteResultFilter';$subtree=Get-DomeniaControl 'ChkSubtree';$grid=Get-DomeniaControl 'DgObjects'
    $queryName='';$queryKind='Local';$selection=''
    # A local query run describes the list only while that list is the one shown (as in Get-DomeniaNavSnapshot):
    # an OU list read since then, an AD query or an erased list carries no criterion of that former run.
    $run=$script:SearchQueryRun
    if(($null -ne $run) -and ([string]$script:ActiveSearchViewId -cne [string]$run.Id)){$run=$null}
    if($null -ne $run){
        $queryName=[string]$run.Name
        $selection=switch([string]$run.Selection){'Unknown'{'Inconnus'};'NoMatch'{'Non correspondants'};default{'Correspondants'}}
    }elseif([string]$script:ActiveSearchViewId){
        $id=[string]$script:ActiveSearchViewId
        if($id.StartsWith('local:',[StringComparison]::Ordinal)){
            $entry=@($script:SearchQueryCatalog|Where-Object{[string]$_.Id -ceq $id}|Select-Object -First 1)
            $queryName=$(if($entry.Count){[string]$entry[0].Name}else{$id.Substring(6)})
        }else{
            $plain=$id;if($plain.StartsWith('ad:',[StringComparison]::Ordinal)){$plain=$plain.Substring(3)}
            $view=@(Get-DomeniaWorkViews|Where-Object{[string]$_.Id -ceq $plain}|Select-Object -First 1)
            $queryName=$(if($view.Count){[string]$view[0].Name}else{$plain});$queryKind='Directory'
        }
    }
    $segment=''
    if(($null -ne $script:DomeniaQueryState) -and ($null -ne $script:DomeniaQueryState.SearchRecipe)){
        $count=0;try{$count=[int]$script:DomeniaQueryState.SearchRecords.Count}catch{$count=0}
        $segment=[string]$count+' poste(s) retenu(s)'
    }
    return [pscustomobject]@{
        Mode=(Get-DomeniaSearchMode);OuDn=[string]$script:SelectedBranchDn;Subtree=(($null -eq $subtree) -or ([bool]$subtree.IsChecked))
        GlobalText=(Get-DomeniaSearchText -Mode Global)
        TypeLabel=$(if(($null -ne $type) -and ($null -ne $type.SelectedItem)){[string]$type.SelectedItem.Content}else{'Tous'})
        Presence=$(if(($null -ne $presence) -and ($null -ne $presence.SelectedItem)){[string]$presence.SelectedItem.Content}else{[string]$script:CurrentPresenceFilter});LocalFilter=$(if($null -ne $local){[string]$local.Text}else{''})
        QueryName=$queryName;QueryKind=$queryKind;QuerySelection=$selection;SegmentName=$segment
        Shown=$(if($null -ne $grid){[int]$grid.Items.Count}else{-1});Loaded=(Get-DomeniaSearchLoadedCount)
    }
}
function Update-DomeniaSearchFilterChips {
    $panel=Get-DomeniaControl 'PnlSearchFilterChips';if($null -eq $panel){return}
    $model=Get-DomeniaSearchFilterChips -State (Get-DomeniaSearchFilterState)
    # The chips are rebuilt only when a criterion changes: a list that loads keeps its chips, their keyboard focus
    # and their tooltips, and only the counts of the summary follow it. The panel keeps the signature it shows.
    $signature=(@($model.Chips|ForEach-Object{[string]$_.Key+'|'+[string]$_.Scope+'|'+[string]$_.Label+'|'+[string]$_.Removable+'|'+[string]$_.Effect}) -join "`n")
    if(([string]$panel.Tag -ceq $signature) -and ($panel.Children.Count -eq @($model.Chips).Count)){[void](Set-DomeniaControlText 'LblSearchFilterSummary' ([string]$model.Summary));return}
    $panel.Tag=$signature
    $panel.Children.Clear()
    foreach($chip in @($model.Chips)){
        $text=[Windows.Controls.TextBlock]::new()
        $text.Text=[string]$chip.Scope+' · '+[string]$chip.Label+$(if($chip.Removable){'  '+[string][char]0x00D7}else{''})
        $text.TextTrimming='CharacterEllipsis';$text.MaxWidth=360;$text.VerticalAlignment='Center'
        if($chip.Removable){
            $button=[Windows.Controls.Button]::new();$button.Content=$text;$button.Tag=[string]$chip.Key
            $button.Margin=[Windows.Thickness]::new(0,0,6,4);$button.Padding=[Windows.Thickness]::new(8,1,8,1);$button.MinHeight=26;$button.MinWidth=0
            try{$button.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'SecondaryButton')}catch{}
            $button.ToolTip=[string]$chip.Effect
            [Windows.Automation.AutomationProperties]::SetName($button,'Retirer le critère '+[string]$chip.Label)
            [Windows.Automation.AutomationProperties]::SetHelpText($button,[string]$chip.Effect)
            $button.Add_Click({param($sender,$eventArgs) try{Remove-DomeniaSearchFilterChip -Key ([string]$sender.Tag)}catch{Set-Status ('Critère non retiré : '+$_.Exception.Message) 'WARN'}})
            [void]$panel.Children.Add($button)
        }else{
            $border=[Windows.Controls.Border]::new();$border.Child=$text
            $border.Margin=[Windows.Thickness]::new(0,0,6,4);$border.Padding=[Windows.Thickness]::new(8,3,8,3);$border.CornerRadius=[Windows.CornerRadius]::new(10);$border.BorderThickness=[Windows.Thickness]::new(1)
            try{$border.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty,'BorderColor');$border.SetResourceReference([Windows.Controls.Border]::BackgroundProperty,'BgReadonly')}catch{}
            $border.ToolTip=[string]$chip.Effect
            [Windows.Automation.AutomationProperties]::SetName($border,[string]$chip.Label)
            [Windows.Automation.AutomationProperties]::SetHelpText($border,[string]$chip.Effect)
            [void]$panel.Children.Add($border)
        }
    }
    [void](Set-DomeniaControlText 'LblSearchFilterSummary' ([string]$model.Summary))
}
function Remove-DomeniaSearchFilterChip {
    # Each chip is removed through the visible control that holds it, so that its usual handler applies.
    param([ValidateSet('Type','Query','Segment','Presence','Local')][string]$Key)
    switch($Key){
        'Local'{$box=Get-DomeniaControl 'TxtSuiteResultFilter';if($null -ne $box){$box.Text=''}}
        'Presence'{$box=Get-DomeniaControl 'CmbPresenceFilter';if($null -ne $box){$box.SelectedIndex=0}}
        'Type'{$box=Get-DomeniaControl 'CmbGlobalType';if($null -ne $box){$box.SelectedIndex=0}}
        'Segment'{
            # Only the workshop selection goes: the list on screen, its query and its other criteria stay, and every
            # loaded row is shown again without any read.
            $q=$script:DomeniaQueryState
            if($null -ne $q){$q.SearchRecipe=$null;$q.SearchRefinement=$null;$q.SearchRecords=@{}}
            Apply-DomeniaPresenceFilter
            [void](Set-DomeniaControlText 'LblSearchQuery' 'Sélection de lʼatelier retirée : toutes les lignes chargées sont réaffichées, sans lecture.')
        }
        default{Clear-DomeniaSearchQuery}
    }
    Update-DomeniaSearchFilterChips
}

# ---------------------------------------------------------------- Point 60: explicit collective scope
function Get-DomeniaResultScopeMode {
    $combo=Get-DomeniaControl 'CmbResultScope'
    if(($null -ne $combo) -and ($null -ne $combo.SelectedItem) -and ([string]$combo.SelectedItem.Tag -eq 'Selected')){return 'Selected'}
    return 'Visible'
}
function Get-DomeniaSearchListCompleteness {
    # What is known of the completeness of the list on screen; never 'Complete' without a finished, unlimited read.
    $grid=Get-DomeniaControl 'DgObjects'
    if(($null -ne $script:Live) -and ($null -ne $script:Live.Search) -and (Test-DomeniaLiveSearchActive)){
        $s=$script:Live.Search
        if(($null -eq $grid) -or ([object]::ReferenceEquals($grid.ItemsSource,$s.Rows))){
            $limit=0;try{$limit=[int]$s.State.Limit}catch{$limit=0}
            if([string]$s.Error){return [pscustomobject]@{State='Partial';Limit=$limit}}
            if(-not [bool]$s.Finalized){return [pscustomobject]@{State='Loading';Limit=$limit}}
            if(($null -ne $s.Final) -and ([bool]$s.Final.LimitReached)){return [pscustomobject]@{State='Limited';Limit=$limit}}
            if($null -ne $s.Final){return [pscustomobject]@{State='Complete';Limit=$limit}}
        }
    }
    # A finished local query states its limit only while its list is still shown (see Get-DomeniaSearchFilterState).
    $run=$script:SearchQueryRun
    if(($null -ne $run) -and ([string]$script:ActiveSearchViewId -cne [string]$run.Id)){$run=$null}
    if(($null -ne $run) -and (-not [string]$run.Job) -and ([long](Get-DomeniaMember $run 'Total' -1) -gt [long](Get-DomeniaMember $run 'Shown' -1)) -and ([long](Get-DomeniaMember $run 'Shown' -1) -ge 0)){
        return [pscustomobject]@{State='Limited';Limit=[int]$run.Limit}
    }
    return [pscustomobject]@{State='Unknown';Limit=0}
}
function Update-DomeniaResultScopeUi {
    # Counts only: this label is refreshed while long lists load.
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    $state=Get-DomeniaSearchListCompleteness
    $summary=Get-DomeniaSearchScopeSummary -Mode (Get-DomeniaResultScopeMode) -VisibleCount ([int]$grid.Items.Count) -SelectedCount ([int]$grid.SelectedItems.Count) -LoadedCount (Get-DomeniaSearchLoadedCount) -Completeness $state.State -Limit $state.Limit
    [void](Set-DomeniaControlText 'LblResultScope' ('Export et relevés : '+[string]$summary.Label))
}
function Get-DomeniaResultScopePlan {
    $grid=Get-DomeniaControl 'DgObjects';$visible=@();$selected=@()
    if($null -ne $grid){$visible=@($grid.Items);$selected=@($grid.SelectedItems)}
    $state=Get-DomeniaSearchListCompleteness
    return (Get-DomeniaSearchSelectionPlan -VisibleRows $visible -SelectedRows $selected -Mode (Get-DomeniaResultScopeMode) -LoadedCount (Get-DomeniaSearchLoadedCount) -Completeness $state.State -Limit $state.Limit)
}
function Start-DomeniaResultSurvey {
    # Pinger, Détecter and Analyser la liste act on the scope chosen beside the results: the list as shown, or the
    # selected rows only. The number of workstations and the scope are confirmed before any read.
    param([ValidateSet('Ping','Detect','Analyze')][string]$Kind)
    try{
        if((Get-DomeniaResultScopeMode) -eq 'Selected'){
            if([bool]$script:ListSurveyBlocked){throw 'vue sur tout le domaine : aucun relevé des postes. Choisissez une OU puis relancez la vue.'}
            $plan=Get-DomeniaResultScopePlan
            $targets=@(foreach($row in @($plan.Rows)){if(([string]$row.Type -eq 'Machine') -and ([bool][string]$row.DN) -and ([bool][string]$row.Guid)){[pscustomobject]@{name=[string]$row.Name;distinguished_name=[string]$row.DN;object_guid=[string]$row.Guid}}})
            if(-not $targets.Count){throw $(if($plan.Count){'aucun poste identifié parmi les lignes sélectionnées.'}else{[string]$plan.Label})}
            $label='la sélection ('+$targets.Count+' poste(s) sur '+$plan.Count+' ligne(s) sélectionnée(s))'
            switch($Kind){
                'Ping'{Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label -PingOnly}
                'Detect'{Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label}
                default{Start-DomeniaParkAnalysis -ScopeTargets $targets -ScopeLabel $label}
            }
            return
        }
        switch($Kind){
            'Ping'{Start-DomeniaOnlinePark -DisplayedResults -PingOnly}
            'Detect'{Start-DomeniaOnlinePark -DisplayedResults}
            default{Start-DomeniaParkAnalysis}
        }
    }catch{Set-Status ('Relevé non lancé : '+$_.Exception.Message) 'WARN'}
}

# ---------------------------------------------------------------- Points 58 and 59: local preview and comparison
function Assert-DomeniaSearchInspectionResult {
    param($Result,$Context)
    if(($null -eq $Result) -or ([bool]$Result.Busy) -or ([bool]$Result.Missing) -or ([string]$Result.DataSource -cne 'SQLite') -or ([string]$Result.StoreId -cne [string]$Context.StoreId) -or ([string]$Result.Path -ine [string]$Context.Path)){throw 'Lecture non confirmée par la base locale.'}
}
function Get-DomeniaSearchPreviewRow {
    # The current row of the grid (keyboard focus or last click) leaves a multiple selection untouched; otherwise the
    # single selected row. $null when nothing designates one row.
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return $null}
    $current=$null;try{$current=$grid.CurrentItem}catch{$current=$null}
    if(($null -ne $current) -and ($null -ne $current.PSObject.Properties['DN'])){return $current}
    if([int]$grid.SelectedItems.Count -eq 1){return $grid.SelectedItem}
    return $null
}
function Test-DomeniaSearchPreviewCurrent {
    param($State)
    if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ($State.Generation -ne [long]$script:GlobalSearchGeneration) -or ([string]$State.Context.Path -ine [string]$script:DatabaseScopedPath)){return $false}
    $panel=Get-DomeniaControl 'PnlSearchPreview'
    return (([string]$State.Token -ceq [string]$script:SearchPreviewToken) -and ($null -ne $panel) -and ($panel.Visibility -eq 'Visible'))
}
function Request-DomeniaSearchPreview {
    $panel=Get-DomeniaControl 'PnlSearchPreview';if(($null -eq $panel) -or ($panel.Visibility -ne 'Visible')){return}
    $table=Get-DomeniaControl 'DgSearchPreview'
    try{
        $row=Get-DomeniaSearchPreviewRow
        $message=''
        if($null -eq $row){$message='Aperçu local : sélectionnez une ligne, ou parcourez la liste avec les flèches, pour consulter sa fiche enregistrée.'}
        elseif(-not (Test-DomeniaGuidText ([string]$row.Guid))){$message='Aperçu local : '+[string]$row.Name+' nʼa pas de GUID AD confirmé ; ouvrez sa fiche pour la lire.'}
        elseif(-not [string]$script:DatabaseScopedPath){$message='Aperçu local : aucune base locale active. Actualisez dʼabord lʼOU dans Base de données.'}
        if($message){$script:SearchPreviewToken='';if($null -ne $table){$table.ItemsSource=@()};[void](Set-DomeniaControlText 'LblSearchPreview' $message);return}
        $guid=([guid][string]$row.Guid).ToString('D')
        $context=New-DomeniaStoreContext -RequestId ('search-preview-'+[guid]::NewGuid().ToString('N'))
        $state=[pscustomobject]@{Context=$context;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:GlobalSearchGeneration;Guid=$guid;Name=[string]$row.Name;Token=[guid]::NewGuid().ToString('N')}
        $script:SearchPreviewToken=$state.Token
        if($null -ne $table){$table.ItemsSource=@()}
        [void](Set-DomeniaControlText 'LblSearchPreview' ('Lecture locale de '+[string]$row.Name+'…'))
        $job=Request-DomeniaStoreRead -Context $context -Query @{Kind='Directory';Guids=@($guid);IncludeObservations=$true;Limit=1} -SuccessHandler 'Complete-DomeniaSearchPreview' -ErrorHandler 'Fail-DomeniaSearchPreview' -CallbackState $state
        if(-not $job){throw 'lecture locale non admise.'}
    }catch{$script:SearchPreviewToken='';[void](Set-DomeniaControlText 'LblSearchPreview' ('Aperçu local indisponible : '+$_.Exception.Message))}
}
function Complete-DomeniaSearchPreview {
    param($Result,$State)
    if(-not (Test-DomeniaSearchPreviewCurrent $State)){return}
    try{
        Assert-DomeniaSearchInspectionResult $Result $State.Context
        $table=Get-DomeniaControl 'DgSearchPreview'
        $row=@($Result.Rows|Where-Object{([string]$_.Guid) -ieq [string]$State.Guid}|Select-Object -First 1)
        if(-not $row.Count){
            if($null -ne $table){$table.ItemsSource=@()}
            [void](Set-DomeniaControlText 'LblSearchPreview' ($State.Name+' : absent de la base locale. Actualisez lʼOU (Objets AD) pour lʼenregistrer ; rien nʼest lu ici.'))
            return
        }
        if($null -ne $table){$table.ItemsSource=@(Get-DomeniaSearchPreviewRows -Row $row[0] -Observations @($Result.Observations))}
        [void](Set-DomeniaControlText 'LblSearchPreview' ($State.Name+' · base locale, révision '+[string]$Result.SnapshotRevision+' · aucune collecte'))
    }catch{Fail-DomeniaSearchPreview $_.Exception.Message $State}
}
function Fail-DomeniaSearchPreview {
    param([string]$Message,$State)
    if(-not (Test-DomeniaSearchPreviewCurrent $State)){return}
    $table=Get-DomeniaControl 'DgSearchPreview';if($null -ne $table){$table.ItemsSource=@()}
    [void](Set-DomeniaControlText 'LblSearchPreview' ('Lecture locale non confirmée : '+$Message))
}
function Switch-DomeniaSearchPreview {
    param([ValidateSet('Toggle','Open','Close')][string]$State='Toggle')
    $panel=Get-DomeniaControl 'PnlSearchPreview';if($null -eq $panel){return}
    $show=($panel.Visibility -ne 'Visible');if($State -eq 'Open'){$show=$true}elseif($State -eq 'Close'){$show=$false}
    $splitter=Get-DomeniaControl 'SearchPreviewSplitter'
    # The side column takes 400 pixels while the preview is shown and nothing once it is closed.
    $area=$panel.Parent
    if($show){
        $panel.Visibility='Visible';if($null -ne $splitter){$splitter.Visibility='Visible'}
        if(($area -is [Windows.Controls.Grid]) -and ($area.ColumnDefinitions.Count -ge 3) -and ($area.ColumnDefinitions[2].Width.IsAuto)){$area.ColumnDefinitions[2].Width=[Windows.GridLength]::new(400)}
        Request-DomeniaSearchPreview
        return
    }
    $panel.Visibility='Collapsed';if($null -ne $splitter){$splitter.Visibility='Collapsed'}
    if(($area -is [Windows.Controls.Grid]) -and ($area.ColumnDefinitions.Count -ge 3)){$area.ColumnDefinitions[2].Width=[Windows.GridLength]::Auto}
    $script:SearchPreviewToken=''
}
function Get-DomeniaComparisonRowStyle {
    # Rows whose values differ stand out; an incomplete row stays visibly uncertain. Based on the themed row style.
    $xaml='<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="DataGridRow"><Style.Triggers>'+
        '<DataTrigger Binding="{Binding Difference}" Value="Different"><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="BorderBrush" Value="{DynamicResource AccentColor}"/><Setter Property="BorderThickness" Value="3,0,0,0"/></DataTrigger>'+
        '<DataTrigger Binding="{Binding Difference}" Value="DateOnly"><Setter Property="BorderBrush" Value="{DynamicResource MutedColor}"/><Setter Property="BorderThickness" Value="3,0,0,0"/></DataTrigger>'+
        '<DataTrigger Binding="{Binding Difference}" Value="Unknown"><Setter Property="FontStyle" Value="Italic"/><Setter Property="Foreground" Value="{DynamicResource MutedColor}"/></DataTrigger>'+
        '</Style.Triggers></Style>'
    $style=[Windows.Markup.XamlReader]::Parse($xaml)
    $base=$null;try{if($null -ne $script:Window){$base=$script:Window.TryFindResource([Windows.Controls.DataGridRow])}}catch{$base=$null}
    if($base -is [Windows.Style]){$style.BasedOn=$base}
    return $style
}
function Show-DomeniaSearchComparison {
    try{
        $grid=Get-DomeniaControl 'DgObjects';$rows=@();if($null -ne $grid){$rows=@($grid.SelectedItems)}
        if(($rows.Count -lt 2) -or ($rows.Count -gt 8) -or (@($rows|Where-Object{[string]$_.Type -cne 'Machine'}).Count -gt 0)){throw 'sélectionnez de deux à huit postes (Ctrl ou Maj + clic).'}
        $guids=@(foreach($row in $rows){if(-not (Test-DomeniaGuidText ([string]$row.Guid))){throw ('le poste '+[string]$row.Name+' nʼa pas de GUID AD confirmé.')};([guid][string]$row.Guid).ToString('D')})
        if(@($guids|Select-Object -Unique).Count -ne $guids.Count){throw 'le même poste est sélectionné deux fois.'}
        if(-not [string]$script:DatabaseScopedPath){throw 'aucune base locale active.'}
        $names=@($rows|ForEach-Object{[string]$_.Name})
        # In-page sheet: Show-DomeniaEmbeddedWindow hosts this content in the main window, never a separate window.
        $window=[Windows.Window]::new();$window.Title='Comparer '+$guids.Count+' postes';$window.Width=900
        $root=[Windows.Controls.DockPanel]::new()
        $top=[Windows.Controls.StackPanel]::new();[Windows.Controls.DockPanel]::SetDock($top,'Top')
        $status=[Windows.Controls.TextBlock]::new();$status.Text='Lecture de la base locale…';$status.TextWrapping='Wrap';$status.Margin=[Windows.Thickness]::new(0,0,0,6);[void]$top.Children.Add($status)
        $legend=[Windows.Controls.TextBlock]::new();$legend.Text='Chaque valeur garde sa date de mesure : deux dates différentes ne décrivent pas le même instant. « Non lu » nʼest jamais compté comme identique. Les lignes en gras diffèrent.';$legend.TextWrapping='Wrap';$legend.FontSize=11.5;$legend.Margin=[Windows.Thickness]::new(0,0,0,6);[void]$top.Children.Add($legend)
        $only=[Windows.Controls.CheckBox]::new();$only.Content='Différences seulement';$only.Margin=[Windows.Thickness]::new(0,0,0,8);$only.ToolTip='Masque les lignes identiques (mêmes valeurs et mêmes dates). Les valeurs inconnues restent affichées.';[void]$top.Children.Add($only)
        [void]$root.Children.Add($top)
        $table=[Windows.Controls.DataGrid]::new();$table.ToolTip='Valeurs enregistrées de chaque poste, chacune avec sa date. Rien nʼest relu ici.';$table.IsReadOnly=$true;$table.AutoGenerateColumns=$false;$table.CanUserAddRows=$false;$table.EnableRowVirtualization=$true;$table.EnableColumnVirtualization=$true;$table.HeadersVisibility='Column';$table.MaxHeight=560
        [Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($table,'Auto');[Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($table,'Auto')
        try{$table.RowStyle=Get-DomeniaComparisonRowStyle}catch{}
        foreach($spec in @(@('Propriété','Property',190),@('Comparaison','Comparison',170))){$column=[Windows.Controls.DataGridTextColumn]::new();$column.Header=$spec[0];$column.Binding=[Windows.Data.Binding]::new($spec[1]);$column.Width=[double]$spec[2];[void]$table.Columns.Add($column)}
        for($i=0;$i -lt $guids.Count;$i++){
            foreach($part in @(@('V','valeur',200),@('T','date UTC',150))){$column=[Windows.Controls.DataGridTextColumn]::new();$column.Header=$names[$i]+' · '+$part[1];$column.Binding=[Windows.Data.Binding]::new($part[0]+$i);$column.Width=[double]$part[2];[void]$table.Columns.Add($column)}
        }
        [void]$root.Children.Add($table)
        $context=New-DomeniaStoreContext -RequestId ('search-compare-'+[guid]::NewGuid().ToString('N'))
        $state=[pscustomobject]@{Window=$window;Status=$status;Table=$table;Only=$only;Rows=@();Closed=$false;Context=$context;Epoch=[long]$script:SessionEpoch;Guids=$guids;Names=$names}
        $only.Tag=$state
        $only.Add_Checked({param($sender,$eventArgs) Update-DomeniaSearchComparisonRows $sender.Tag})
        $only.Add_Unchecked({param($sender,$eventArgs) Update-DomeniaSearchComparisonRows $sender.Tag})
        $window.Content=$root
        $job=Request-DomeniaStoreRead -Context $context -Query @{Kind='Directory';Guids=$guids;IncludeObservations=$true;Limit=8} -SuccessHandler 'Complete-DomeniaSearchComparison' -ErrorHandler 'Fail-DomeniaSearchComparison' -CallbackState $state
        if(-not $job){throw 'lecture locale non admise.'}
        try{[void](Show-DomeniaEmbeddedWindow $window)}finally{$state.Closed=$true}
    }catch{Set-Status ('Comparaison indisponible : '+$_.Exception.Message) 'WARN'}
}
function Test-DomeniaSearchComparisonCurrent {
    param($State)
    return (($null -ne $State) -and (-not [bool]$State.Closed) -and ($State.Epoch -eq [long]$script:SessionEpoch) -and ([string]$State.Context.Path -ieq [string]$script:DatabaseScopedPath))
}
function Update-DomeniaSearchComparisonRows {
    param($State)
    if(($null -eq $State) -or ([bool]$State.Closed)){return}
    $rows=@($State.Rows)
    if([bool]$State.Only.IsChecked){$rows=@($rows|Where-Object{[string]$_.Difference -ne 'Same'})}
    $State.Table.ItemsSource=$rows
}
function Complete-DomeniaSearchComparison {
    param($Result,$State)
    if(-not (Test-DomeniaSearchComparisonCurrent $State)){return}
    try{
        Assert-DomeniaSearchInspectionResult $Result $State.Context
        $State.Rows=@(Get-DomeniaComputerComparison -Rows @($Result.Rows) -Observations @($Result.Observations) -Guids $State.Guids)
        $different=@($State.Rows|Where-Object{[string]$_.Difference -eq 'Different'}).Count
        $unknown=@($State.Rows|Where-Object{[string]$_.Difference -eq 'Unknown'}).Count
        $State.Status.Text='Base locale, révision '+[string]$Result.SnapshotRevision+' · '+@($Result.Rows).Count+' poste(s) sur '+$State.Guids.Count+' enregistré(s) · '+$different+' propriété(s) différente(s) · '+$unknown+' incomplète(s) · aucune collecte.'
        Update-DomeniaSearchComparisonRows $State
    }catch{Fail-DomeniaSearchComparison $_.Exception.Message $State}
}
function Fail-DomeniaSearchComparison {
    param([string]$Message,$State)
    if(-not (Test-DomeniaSearchComparisonCurrent $State)){return}
    $State.Status.Text='Lecture locale non confirmée : '+$Message
    $State.Table.ItemsSource=@()
}

# ---------------------------------------------------------------- Wiring
function Invoke-DomeniaSearchWorkspaceRefresh {
    if($null -ne $script:SearchWorkspaceTimer){$script:SearchWorkspaceTimer.Stop()}
    try{Update-DomeniaSearchFilterChips}catch{Write-AppLog ('Critères de la liste : '+$_.Exception.Message) 'WARN'}
    try{Update-DomeniaResultScopeUi}catch{Write-AppLog ('Portée collective : '+$_.Exception.Message) 'WARN'}
    try{Update-DomeniaSearchWorkspaceButtons}catch{Write-AppLog ('Vues personnelles : '+$_.Exception.Message) 'WARN'}
    if($script:SearchPreviewPending){$script:SearchPreviewPending=$false;Request-DomeniaSearchPreview}
    # The end of a live read raises no grid event: while the list loads, the refresh is armed again, so that the
    # scope line states complete, limited or partial as soon as the read ends.
    try{if([string](Get-DomeniaSearchListCompleteness).State -eq 'Loading'){Request-DomeniaSearchWorkspaceRefresh}}catch{Write-AppLog ('Portée collective : '+$_.Exception.Message) 'WARN'}
}
function Request-DomeniaSearchWorkspaceRefresh {
    # Chips, scope and preview follow the list at most every 200 ms: a list loading 20 000 rows refreshes them a few
    # times while it loads, never once per row.
    param([switch]$Preview)
    if($Preview){$script:SearchPreviewPending=$true}
    if($null -eq $script:SearchWorkspaceTimer){$script:SearchWorkspaceTimer=New-DomeniaTimer -Owner 'Timer:SearchWorkspace' -IntervalMs 200 -Tick {Invoke-DomeniaSearchWorkspaceRefresh}}
    if(-not [bool]$script:SearchWorkspaceTimer.IsEnabled){$script:SearchWorkspaceTimer.Start()}
}
function Invoke-DomeniaSearchWorkspaceListChanged {
    # A new list: the sort of a view just opened applies to it once, then the chips, scope and preview follow it.
    $pending=$script:SearchWorkspacePendingSort
    $grid=Get-DomeniaControl 'DgObjects'
    if(($null -ne $pending) -and ($null -ne $grid)){
        if([long]$pending.Epoch -ne [long]$script:SessionEpoch){$script:SearchWorkspacePendingSort=$null}
        else{
            # An emptied grid is not the next list: the sort waits for rows or for a live list that will receive them.
            $source=$grid.ItemsSource;$live=($source -is [Collections.Specialized.INotifyCollectionChanged]);$filled=$false
            if((-not $live) -and ($null -ne $source)){foreach($item in $source){$filled=$true;break}}
            if($live -or $filled){$script:SearchWorkspacePendingSort=$null;try{Set-DomeniaGridSort -Grid $grid -Sort @($pending.Sort)}catch{}}
        }
    }
    Request-DomeniaSearchWorkspaceRefresh -Preview
}
function Reset-DomeniaSearchWorkspaceSession {
    # A new AD session (Changer de session) may open another domain: its own views are listed again, the undo of a
    # removal made in the former session is dropped, and the sort waiting for a list and the preview of a former row
    # are cleared. Nothing is read: the preview waits for a row of the new session.
    $script:SearchWorkspaceUndo=$null;$script:SearchWorkspacePendingSort=$null;$script:SearchPreviewToken='';$script:SearchPreviewPending=$false
    $table=Get-DomeniaControl 'DgSearchPreview';if($null -ne $table){$table.ItemsSource=@()}
    $panel=Get-DomeniaControl 'PnlSearchPreview'
    if(($null -ne $panel) -and ($panel.Visibility -eq 'Visible')){[void](Set-DomeniaControlText 'LblSearchPreview' 'Aperçu local : nouvelle session. Sélectionnez une ligne pour consulter sa fiche enregistrée.')}
    Update-DomeniaSearchWorkspaces
    Request-DomeniaSearchWorkspaceRefresh
}
function Initialize-DomeniaSearchWorkspace {
    if($script:SearchWorkspaceBound){return};$script:SearchWorkspaceBound=$true
    foreach($name in @('BtnSearchWorkspaceSave','BtnSearchWorkspaceOpen','BtnSearchWorkspaceRemove','BtnSearchWorkspaceUndo','BtnSearchCompare','BtnSearchPreview','BtnSearchPreviewClose')){
        $button=Get-DomeniaControl $name;if($null -eq $button){continue}
        $button.Add_Click({param($sender,$eventArgs)switch([string]$sender.Name){
            'BtnSearchWorkspaceSave'{Save-DomeniaSearchWorkspace}
            'BtnSearchWorkspaceOpen'{Open-DomeniaSearchWorkspace}
            'BtnSearchWorkspaceRemove'{Remove-DomeniaSearchWorkspace}
            'BtnSearchWorkspaceUndo'{Undo-DomeniaSearchWorkspace}
            'BtnSearchCompare'{Show-DomeniaSearchComparison}
            'BtnSearchPreviewClose'{Switch-DomeniaSearchPreview -State Close}
            default{Switch-DomeniaSearchPreview}
        }})
    }
    $combo=Get-DomeniaControl 'CmbSearchWorkspace';if($null -ne $combo){$combo.Add_SelectionChanged({Update-DomeniaSearchWorkspaceButtons})}
    $scope=Get-DomeniaControl 'CmbResultScope';if($null -ne $scope){$scope.Add_SelectionChanged({Request-DomeniaSearchWorkspaceRefresh})}
    # These controls belong to the existing results area. A test window without them must not fail startup.
    $filter=Get-DomeniaControl 'TxtSuiteResultFilter';if($null -ne $filter){$filter.Add_TextChanged({Request-DomeniaSearchWorkspaceRefresh})}
    foreach($name in @('CmbPresenceFilter','CmbGlobalType')){$box=Get-DomeniaControl $name;if($null -ne $box){$box.Add_SelectionChanged({Request-DomeniaSearchWorkspaceRefresh})}}
    $subtree=Get-DomeniaControl 'ChkSubtree';if($null -ne $subtree){$subtree.Add_Checked({Request-DomeniaSearchWorkspaceRefresh});$subtree.Add_Unchecked({Request-DomeniaSearchWorkspaceRefresh})}
    $grid=Get-DomeniaControl 'DgObjects'
    if($grid -is [Windows.Controls.DataGrid]){
        $grid.Add_SelectionChanged({Request-DomeniaSearchWorkspaceRefresh -Preview})
        $grid.Add_CurrentCellChanged({Request-DomeniaSearchWorkspaceRefresh -Preview})
        $descriptor=[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.ItemsControl]::ItemsSourceProperty,[Windows.Controls.DataGrid])
        if($null -ne $descriptor){$descriptor.AddValueChanged($grid,[EventHandler]{param($sender,$eventArgs) try{Invoke-DomeniaSearchWorkspaceListChanged}catch{}})}
    }
    # No handler runs per row appended to a live list. The live list writes its counts and its state (loading, limit,
    # partial) in this counter once per slice and once per filter pass, as does every other list shown: the chips and
    # the scope line follow that text, and the refresh armed while a list loads catches the end of its read.
    $counter=Get-DomeniaControl 'LblSuiteResultCount'
    if($counter -is [Windows.Controls.TextBlock]){
        $textDescriptor=[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.TextBlock]::TextProperty,[Windows.Controls.TextBlock])
        if($null -ne $textDescriptor){$textDescriptor.AddValueChanged($counter,[EventHandler]{param($sender,$eventArgs) try{Request-DomeniaSearchWorkspaceRefresh}catch{}})}
    }
    # A reopened main window brings new controls: binding again must be possible then.
    if($script:Window -is [Windows.Window]){$script:Window.Add_Closed({$script:SearchWorkspaceBound=$false;$script:SearchPreviewToken='';$script:SearchWorkspacePendingSort=$null;if($null -ne $script:SearchWorkspaceTimer){$script:SearchWorkspaceTimer.Stop()}})}
    Update-DomeniaSearchWorkspaces
    Invoke-DomeniaSearchWorkspaceRefresh
}
