function Get-DomeniaResultPresentation {
    $grid=Get-DomeniaControl 'DgObjects';$columns=[Collections.Generic.List[object]]::new();$sort=[Collections.Generic.List[object]]::new()
    if($null -eq $grid){return [pscustomobject]@{Columns=@();Sort=@()}}
    $index=0
    foreach($column in $grid.Columns){
        $columns.Add([pscustomobject]@{Key=(Get-DomeniaGridColumnKey $column $index);Index=$column.DisplayIndex;Width=$column.Width.Value.ToString('R',[Globalization.CultureInfo]::InvariantCulture);Unit=$column.Width.UnitType.ToString()});$index++
    }
    foreach($description in $grid.Items.SortDescriptions){$sort.Add([pscustomobject]@{Field=[string]$description.PropertyName;Direction=[string]$description.Direction})}
    return [pscustomobject]@{Columns=$columns.ToArray();Sort=$sort.ToArray()}
}
function Restore-DomeniaResultPresentation {
    param($Presentation)
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid -or $null -eq $Presentation){return}
    $keys=@{};$index=0;foreach($column in $grid.Columns){$keys[(Get-DomeniaGridColumnKey $column $index)]=$column;$index++}
    foreach($item in @(ConvertTo-DomeniaColumnLayout $Presentation.Columns|Sort-Object Index)){
        if(-not $keys.ContainsKey([string]$item.Key)){continue};$column=$keys[[string]$item.Key]
        $column.Width=[Windows.Controls.DataGridLength]::new([double]$item.Width,[Windows.Controls.DataGridLengthUnitType]([string]$item.Unit))
        $column.DisplayIndex=[Math]::Min($grid.Columns.Count-1,[int]$item.Index)
    }
    $allowed=@{};foreach($column in $grid.Columns){if([string]$column.SortMemberPath){$allowed[[string]$column.SortMemberPath]=$column};$column.SortDirection=$null}
    $grid.Items.SortDescriptions.Clear()
    foreach($sort in @($Presentation.Sort)){
        if(-not $allowed.ContainsKey([string]$sort.Field) -or [string]$sort.Direction -notin @('Ascending','Descending')){continue}
        $direction=[ComponentModel.ListSortDirection]([string]$sort.Direction)
        $grid.Items.SortDescriptions.Add([ComponentModel.SortDescription]::new([string]$sort.Field,$direction));$allowed[[string]$sort.Field].SortDirection=$direction
    }
}
function Get-DomeniaSearchWorkspaces {
    $text=[string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]')
    if([Text.Encoding]::UTF8.GetByteCount($text) -gt 1048576){throw 'Bibliothèque de vues trop volumineuse.'}
    $all=@(ConvertFrom-Json -InputObject $text -ErrorAction Stop)
    if($all.Count -gt 100){throw 'Cent vues personnelles au maximum.'}
    $rows=[Collections.Generic.List[object]]::new();$ids=@{}
    foreach($item in $all){
        if([string]$item.DomainDn -ine [string]$script:Conn.BaseDn){continue}
        $record=ConvertTo-DomeniaSearchWorkspace $item ([string]$script:Conn.BaseDn)
        if($ids.ContainsKey($record.Id)){throw 'Vue personnelle dupliquée.'};$ids[$record.Id]=$true;$rows.Add($record)
    }
    return @($rows.ToArray()|Sort-Object Name)
}
function Update-DomeniaSearchWorkspaces {
    $combo=Get-DomeniaControl 'CmbSearchWorkspace';if($null -eq $combo){return}
    try{$id=[string]$combo.SelectedItem.Id;$rows=@(Get-DomeniaSearchWorkspaces);$combo.ItemsSource=$rows;$combo.DisplayMemberPath='Name';$combo.SelectedIndex=-1;foreach($row in $rows){if($row.Id -ceq $id){$combo.SelectedItem=$row;break}}}
    catch{Set-Status ('Vues personnelles non chargées : '+$_.Exception.Message) 'WARN'}
}
function Save-DomeniaSearchWorkspace {
    try{
        if((Get-DomeniaSearchMode) -ne 'OU'){throw 'Choisissez une OU pour enregistrer une vue.'}
        $form=Show-DomeniaFormDialog -Title 'Enregistrer une vue' -Message 'Mémorise lʼOU, les filtres, les colonnes et le tri. Les résultats et les mots de passe ne font pas partie de la vue.' -Fields @(@{Name='Name';Label='Nom de la vue';Value=''}) -AcceptText 'Enregistrer'
        if($null -eq $form){return};$name=([string]$form.Name).Trim();if(-not $name){return}
        $presentation=Get-DomeniaResultPresentation
        $candidate=[pscustomobject]@{Version=1;Id=[guid]::NewGuid().ToString('D');Name=$name;DomainDn=[string]$script:Conn.BaseDn;OuDn=[string]$script:SelectedBranchDn;Subtree=[bool](Get-DomeniaControl 'ChkSubtree').IsChecked;TypeLabel=[string](Get-DomeniaControl 'CmbGlobalType').SelectedItem.Content;Presence=[string](Get-DomeniaControl 'CmbPresenceFilter').SelectedItem.Content;LocalFilter=[string](Get-DomeniaControl 'TxtSuiteResultFilter').Text;Limit=[string](Get-DomeniaControl 'TxtGlobalLimit').Text;Columns=$presentation.Columns;Sort=$presentation.Sort}
        $candidate=ConvertTo-DomeniaSearchWorkspace $candidate ([string]$script:Conn.BaseDn)
        $previous=[string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]');$all=@(ConvertFrom-Json $previous -ErrorAction Stop)
        if($all.Count -ge 100){throw 'Cent vues sont déjà enregistrées. Supprimez une vue devenue inutile.'}
        if(@($all|Where-Object{$_.DomainDn -ieq $candidate.DomainDn -and $_.Name -ieq $name}).Count){throw 'Une vue porte déjà ce nom dans ce domaine.'}
        Set-DomeniaSetting 'Search.WorkspacesJson' (ConvertTo-Json -InputObject @($all+$candidate) -Depth 8 -Compress)
        try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{Set-DomeniaSetting 'Search.WorkspacesJson' $previous;throw}
        Update-DomeniaSearchWorkspaces;Set-Status ('Vue enregistrée : '+$name)
    }catch{Set-Status ('Vue non enregistrée : '+$_.Exception.Message) 'WARN'}
}
function Remove-DomeniaSearchWorkspace {
    try{
        $selected=(Get-DomeniaControl 'CmbSearchWorkspace').SelectedItem;if($null -eq $selected){return}
        $previous=[string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]');$all=@(ConvertFrom-Json $previous -ErrorAction Stop)
        $remaining=@($all|Where-Object{-not ($_.Id -ceq $selected.Id -and $_.DomainDn -ieq [string]$script:Conn.BaseDn)})
        Set-DomeniaSetting 'Search.WorkspacesJson' (ConvertTo-Json -InputObject $remaining -Depth 8 -Compress)
        try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{Set-DomeniaSetting 'Search.WorkspacesJson' $previous;throw}
        $script:SearchWorkspaceUndo=[pscustomobject]@{Before=$previous;After=[string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]')}
        Update-DomeniaSearchWorkspaces;Set-Status 'Vue retirée. Annuler restaure cette suppression tant que les vues ne changent pas.'
    }catch{Set-Status ('Vue non supprimée : '+$_.Exception.Message) 'WARN'}
}
function Undo-DomeniaSearchWorkspace {
    $undo=$script:SearchWorkspaceUndo;if($null -eq $undo){return}
    try{
        if([string](Get-DomeniaSetting 'Search.WorkspacesJson' '[]') -cne $undo.After){throw 'Les vues ont changé depuis cette suppression.'}
        Set-DomeniaSetting 'Search.WorkspacesJson' $undo.Before
        try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{Set-DomeniaSetting 'Search.WorkspacesJson' $undo.After;throw}
        $script:SearchWorkspaceUndo=$null;Update-DomeniaSearchWorkspaces;Set-Status 'Suppression de la vue annulée.'
    }catch{Set-Status ('Annulation non appliquée : '+$_.Exception.Message) 'WARN'}
}
function Open-DomeniaSearchWorkspace {
    try{
        $selected=(Get-DomeniaControl 'CmbSearchWorkspace').SelectedItem;if($null -eq $selected){return}
        $view=ConvertTo-DomeniaSearchWorkspace $selected ([string]$script:Conn.BaseDn)
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
        }finally{$script:RestoringSettings=$oldRestore;$script:SuppressBranchAutoLoad=$oldAuto;$script:ExperienceRestoring=$oldExperience}
        # Opening a preference is inert. The operator chooses AD refresh or a local query next.
        $script:NavSearchLaunching=$false;Update-DomeniaSearchFilterChips
        Set-Status ('Vue « '+$view.Name+' » préparée. Lancez une requête locale ou Actualiser les objets AD pour remplir les résultats.')
    }catch{Set-Status ('Vue non ouverte : '+$_.Exception.Message) 'WARN'}
}
function Update-DomeniaSearchFilterChips {
    $panel=Get-DomeniaControl 'PnlSearchFilterChips';if($null -eq $panel){return};$panel.Children.Clear()
    $chips=[Collections.Generic.List[object]]::new()
    $filter=[string](Get-DomeniaControl 'TxtSuiteResultFilter').Text;if($filter){$chips.Add(@('Local','Dans la liste : '+$filter))}
    $presence=[string](Get-DomeniaControl 'CmbPresenceFilter').SelectedItem.Content;if($presence -and $presence -ne 'Tous'){$chips.Add(@('Presence','Ping mémorisé : '+$presence))}
    foreach($chip in $chips){$button=[Windows.Controls.Button]::new();$button.Content=$chip[1]+' ×';$button.Tag=$chip[0];$button.Margin='0,0,6,4';$button.Padding='8,2';$button.ToolTip='Retirer ce filtre local ; aucun appel au réseau';$button.Add_Click({param($sender,$args)if([string]$sender.Tag -eq 'Local'){(Get-DomeniaControl 'TxtSuiteResultFilter').Text=''}else{(Get-DomeniaControl 'CmbPresenceFilter').SelectedIndex=0};Update-DomeniaSearchFilterChips});[void]$panel.Children.Add($button)}
    # W13 (point 120): the last presentation change of the list (columns, sort, filters) is undone from here or by Ctrl+Z.
    try{$undo=New-DomeniaPresentationUndoChip;if($null -ne $undo){[void]$panel.Children.Add($undo)}}catch{}
}
function Request-DomeniaSearchInspection {
    param([switch]$Compare)
    try{
        $grid=Get-DomeniaControl 'DgObjects';$rows=@($grid.SelectedItems)
        if($Compare){if($rows.Count -lt 2 -or $rows.Count -gt 8 -or @($rows|Where-Object{$_.Type -cne 'Machine'}).Count){throw 'Sélectionnez de deux à huit postes (Ctrl ou Maj + clic).'}}
        elseif($rows.Count -ne 1){[void](Set-DomeniaControlText 'LblSearchPreview' 'Sélectionnez une ligne pour consulter ses données enregistrées.');return}
        $guids=@($rows|ForEach-Object{if(-not (Test-DomeniaGuidText ([string]$_.Guid))){throw 'Un objet sélectionné ne possède pas de GUID AD confirmé.'};([guid]$_.Guid).ToString('D')})
        $context=New-DomeniaStoreContext -RequestId ('search-inspect-'+[guid]::NewGuid().ToString('N'))
        $state=[pscustomobject]@{Context=$context;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:GlobalSearchGeneration;Guids=$guids;Names=@($rows|ForEach-Object{[string]$_.Name});Compare=[bool]$Compare;Token=[guid]::NewGuid().ToString('N')}
        if(-not $Compare){$script:SearchPreviewToken=$state.Token;[void](Set-DomeniaControlText 'LblSearchPreview' 'Lecture locale…');(Get-DomeniaControl 'DgSearchPreview').ItemsSource=@()}
        $query=@{Kind='Directory';Guids=$guids;IncludeObservations=$true;ObservationFamilies=@('Presence','Console','Inventory');Limit=8}
        $job=Request-DomeniaStoreRead -Context $context -Query $query -SuccessHandler 'Complete-DomeniaSearchInspection' -ErrorHandler 'Fail-DomeniaSearchInspection' -CallbackState $state
        if(-not $job){throw 'Lecture locale non admise.'}
    }catch{Set-Status ('Consultation locale indisponible : '+$_.Exception.Message) 'WARN'}
}
function Test-DomeniaSearchInspectionCurrent {
    param($State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne [long]$script:GlobalSearchGeneration -or $State.Context.Path -ine [string]$script:DatabaseScopedPath){return $false}
    if(-not $State.Compare){return ($State.Token -ceq [string]$script:SearchPreviewToken -and (Get-DomeniaControl 'PnlSearchPreview').Visibility -eq 'Visible')}
    return $true
}
function Complete-DomeniaSearchInspection {
    param($Result,$State)
    if(-not (Test-DomeniaSearchInspectionCurrent $State)){return}
    try{
        if($null -eq $Result -or $Result.Busy -or $Result.Missing -or $Result.DataSource -cne 'SQLite' -or $Result.StoreId -cne $State.Context.StoreId -or $Result.Path -ine $State.Context.Path){throw 'Lecture non confirmée par la base.'}
        $comparison=@(Get-DomeniaComputerComparison -Rows $Result.Rows -Observations $Result.Observations -Guids $State.Guids)
        $caption='Révision locale '+$Result.SnapshotRevision+' · '+@($Result.Rows).Count+'/'+$State.Guids.Count+' objet(s) enregistrés · aucune collecte'
        if(-not $State.Compare){
            (Get-DomeniaControl 'DgSearchPreview').ItemsSource=@($comparison|ForEach-Object{[pscustomobject]@{Propriété=$_.Propriété;Valeur=$_.V0;Date=$_.T0}})
            [void](Set-DomeniaControlText 'LblSearchPreview' ($State.Names[0]+' · '+$caption));return
        }
        $window=[Windows.Window]::new();$window.Title='Comparer les postes';$window.Width=1160;$window.Height=720
        $root=[Windows.Controls.DockPanel]::new();$root.Margin='16';$title=[Windows.Controls.TextBlock]::new();$title.Text=$caption+' · Les dates différentes ne décrivent pas un instant commun.';$title.TextWrapping='Wrap';$title.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($title,'Top');[void]$root.Children.Add($title)
        $table=[Windows.Controls.DataGrid]::new();$table.IsReadOnly=$true;$table.AutoGenerateColumns=$false;$table.CanUserAddRows=$false;$table.EnableRowVirtualization=$true;$table.EnableColumnVirtualization=$true
        foreach($field in @('Propriété','Comparaison')){$column=[Windows.Controls.DataGridTextColumn]::new();$column.Header=$field;$column.Binding=[Windows.Data.Binding]::new($field);$column.Width=180;[void]$table.Columns.Add($column)}
        for($i=0;$i -lt $State.Guids.Count;$i++){
            foreach($part in @(@('V','Valeur'),@('T','Date UTC / tentative'))){$column=[Windows.Controls.DataGridTextColumn]::new();$column.Header=$State.Names[$i]+' · '+$part[1];$column.Binding=[Windows.Data.Binding]::new($part[0]+$i);$column.Width=240;[void]$table.Columns.Add($column)}
        }
        $table.ItemsSource=$comparison;[void]$root.Children.Add($table);$window.Content=$root;[void](Show-DomeniaEmbeddedWindow $window)
    }catch{Fail-DomeniaSearchInspection $_.Exception.Message $State}
}
function Fail-DomeniaSearchInspection {
    param([string]$Message,$State)
    if(-not (Test-DomeniaSearchInspectionCurrent $State)){return}
    if(-not $State.Compare){[void](Set-DomeniaControlText 'LblSearchPreview' ('Lecture locale non confirmée : '+$Message))}
    Set-Status ('Consultation locale non confirmée : '+$Message) 'WARN'
}
function Switch-DomeniaSearchPreview {
    $panel=Get-DomeniaControl 'PnlSearchPreview';if($null -eq $panel){return}
    if($panel.Visibility -eq 'Visible'){$panel.Visibility='Collapsed';$script:SearchPreviewToken='';return}
    $panel.Visibility='Visible';Request-DomeniaSearchInspection
}
function Initialize-DomeniaSearchWorkspace {
    if($script:SearchWorkspaceBound){return};$script:SearchWorkspaceBound=$true
    foreach($name in @('BtnSearchWorkspaceSave','BtnSearchWorkspaceOpen','BtnSearchWorkspaceRemove','BtnSearchWorkspaceUndo','BtnSearchCompare','BtnSearchPreview','BtnSearchPreviewClose')){
        $button=Get-DomeniaControl $name;if($null -eq $button){continue}
        $button.Add_Click({param($sender,$args)switch([string]$sender.Name){
            'BtnSearchWorkspaceSave'{Save-DomeniaSearchWorkspace}
            'BtnSearchWorkspaceOpen'{Open-DomeniaSearchWorkspace}
            'BtnSearchWorkspaceRemove'{Remove-DomeniaSearchWorkspace}
            'BtnSearchWorkspaceUndo'{Undo-DomeniaSearchWorkspace}
            'BtnSearchCompare'{Request-DomeniaSearchInspection -Compare}
            default{Switch-DomeniaSearchPreview}
        }})
    }
    # These three controls belong to the existing results grid. A test window
    # without them must not fail startup; the workspace buttons are optional.
    $filter=Get-DomeniaControl 'TxtSuiteResultFilter'
    if($null -ne $filter){$filter.Add_TextChanged({Update-DomeniaSearchFilterChips})}
    $presence=Get-DomeniaControl 'CmbPresenceFilter'
    if($null -ne $presence){$presence.Add_SelectionChanged({Update-DomeniaSearchFilterChips})}
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid){Update-DomeniaSearchWorkspaces;Update-DomeniaSearchFilterChips;return}
    $grid.Add_SelectionChanged({
        $panel=Get-DomeniaControl 'PnlSearchPreview'
        if($null -ne $panel -and $panel.Visibility -eq 'Visible'){
            $script:SearchPreviewToken=''
            if($null -eq $script:SearchPreviewTimer){$script:SearchPreviewTimer=New-DomeniaTimer -Owner 'SearchPreview' -IntervalMs 200 -Tick {$script:SearchPreviewTimer.Stop();Request-DomeniaSearchInspection}}
            $script:SearchPreviewTimer.Stop();$script:SearchPreviewTimer.Start()
        }
    })
    try{Initialize-DomeniaPresentationUndo}catch{Write-AppLog ('Annulation de présentation indisponible : '+$_.Exception.Message) 'WARN'}
    Update-DomeniaSearchWorkspaces;Update-DomeniaSearchFilterChips
}
