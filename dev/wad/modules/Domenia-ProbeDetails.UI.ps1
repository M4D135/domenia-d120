# Detail pages always read the committed family for the selected GUID. Opening never contacts a workstation.
function Show-DomeniaProbeDetails {
    param([string]$ProbeId)
    $selected=$script:SelectedObject
    if($null -eq $selected -or [string]$selected.Type -cne 'Machine' -or -not (Test-DomeniaGuidText ([string]$selected.Guid))){Set-Status 'Sélectionnez un poste identifié pour consulter ses mesures.' 'WARN';return}
    $probe=@(Get-DomeniaProbeCatalog|Where-Object{[string]$_.Id -ceq $ProbeId})
    if($probe.Count -ne 1){Set-Status 'Sonde absente du catalogue courant.' 'WARN';return}
    $definition=$probe[0]
    $window=[Windows.Window]::new();$window.Title='Détails de la sonde · '+$definition.Name;$window.Width=1000;$window.Height=680
    $root=[Windows.Controls.DockPanel]::new();$root.Margin=[Windows.Thickness]::new(16)
    $top=[Windows.Controls.StackPanel]::new();[Windows.Controls.DockPanel]::SetDock($top,'Top')
    $title=[Windows.Controls.TextBlock]::new();$title.Text=[string]$selected.Name+' · '+$definition.Name;$title.FontSize=20;$title.FontWeight='SemiBold';$title.TextWrapping='Wrap';[void]$top.Children.Add($title)
    $status=[Windows.Controls.TextBlock]::new();$status.Text='Lecture des mesures enregistrées dans la base locale…';$status.TextWrapping='Wrap';$status.Margin='0,8,0,8';[void]$top.Children.Add($status)
    $choice=[Windows.Controls.ComboBox]::new();$choice.Items.Add('Dernière réussite')|Out-Null;$choice.Items.Add('Dernière tentative')|Out-Null;$choice.SelectedIndex=0;$choice.IsEnabled=$false;$choice.Margin='0,0,0,10';[void]$top.Children.Add($choice)
    [void]$root.Children.Add($top)
    $footer=[Windows.Controls.WrapPanel]::new();$footer.Margin='0,10,0,0';[Windows.Controls.DockPanel]::SetDock($footer,'Bottom')
    $previous=[Windows.Controls.Button]::new();$previous.Content='Précédent';$previous.Margin='0,0,8,0';$previous.IsEnabled=$false
    $next=[Windows.Controls.Button]::new();$next.Content='Suivant';$next.Margin='0,0,8,0';$next.IsEnabled=$false
    $position=[Windows.Controls.TextBlock]::new();$position.VerticalAlignment='Center';$position.Margin='0,0,16,0'
    $close=[Windows.Controls.Button]::new();$close.Content='Fermer'
    foreach($control in @($previous,$next,$position,$close)){[void]$footer.Children.Add($control)};[void]$root.Children.Add($footer)
    $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.AutoGenerateColumns=$true;$grid.CanUserAddRows=$false;$grid.CanUserDeleteRows=$false;$grid.EnableRowVirtualization=$true;$grid.EnableColumnVirtualization=$true;$grid.HeadersVisibility='Column';[void]$root.Children.Add($grid)
    $context=New-DomeniaStoreContext -RequestId ('probe-details-'+[guid]::NewGuid().ToString('N'))
    $state=[pscustomobject]@{Window=$window;Status=$status;Choice=$choice;Grid=$grid;Previous=$previous;Next=$next;Position=$position;Closed=$false;Context=$context;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;Guid=[string]$selected.Guid;ProbeId=$ProbeId;Definition=$definition;Observation=$null;Offset=0;Limit=100;SnapshotRevision=-1L}
    $window.Tag=$state;$window.Content=$root
    foreach($control in @($previous,$next,$choice,$close)){$control.Tag=$state}
    $previous.Add_Click({param($sender,$eventArgs)$s=$sender.Tag;$s.Offset=[Math]::Max(0,$s.Offset-$s.Limit);Update-DomeniaProbeDetailsPage $s})
    $next.Add_Click({param($sender,$eventArgs)$s=$sender.Tag;$s.Offset+=$s.Limit;Update-DomeniaProbeDetailsPage $s})
    $choice.Add_SelectionChanged({param($sender,$eventArgs)$s=$sender.Tag;if($null -ne $s.Observation){$s.Offset=0;Update-DomeniaProbeDetailsPage $s}})
    $close.Add_Click({param($sender,$eventArgs)Set-DomeniaSurfaceResult $sender.Tag.Window $false})
    try{
        $job=Request-DomeniaStoreRead -Context $context -Query @{Kind='Observation';Guids=@($state.Guid);Family=('Probe:'+$ProbeId);Limit=1} -SuccessHandler 'Complete-DomeniaProbeDetailsRead' -ErrorHandler 'Fail-DomeniaProbeDetailsRead' -CallbackState $state
        if(-not $job){throw 'Lecture locale non admise.'}
    }catch{Fail-DomeniaProbeDetailsRead $_.Exception.Message $state}
    try{[void](Show-DomeniaEmbeddedWindow $window)}finally{$state.Closed=$true}
}
function Test-DomeniaProbeDetailsState {
    param($State)
    return ($null -ne $State -and -not $State.Closed -and $State.Epoch -eq [long]$script:SessionEpoch -and $State.Generation -eq [long]$script:SelectedObjectGeneration -and [string]$State.Context.Path -ieq [string]$script:DatabaseScopedPath -and [string]$State.Guid -ieq [string]$script:SelectedObject.Guid)
}
function Complete-DomeniaProbeDetailsRead {
    param($Result,$State)
    if(-not (Test-DomeniaProbeDetailsState $State)){return}
    try{
        if($null -eq $Result -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne [string]$State.Context.StoreId -or [string]$Result.Path -ine [string]$State.Context.Path -or $Result.Busy -or $Result.Missing){throw 'Mesures non confirmées par la base.'}
        $rows=@($Result.Observations|Where-Object{[string]$_.Guid -ieq [string]$State.Guid -and [string]$_.Family -ceq ('Probe:'+$State.ProbeId)})
        if($rows.Count -eq 0){$State.Status.Text='Aucune observation enregistrée pour cette sonde et ce poste. Lancez une collecte explicitement depuis le dashboard.';return}
        if($rows.Count -ne 1){throw 'Famille de mesures ambiguë.'}
        $State.Observation=$rows[0];$State.SnapshotRevision=[long]$Result.SnapshotRevision
        $State.Choice.IsEnabled=$true
        if($null -eq $rows[0].Data){$State.Choice.SelectedIndex=1}
        Update-DomeniaProbeDetailsPage $State
    }catch{Fail-DomeniaProbeDetailsRead $_.Exception.Message $State}
}
function Update-DomeniaProbeDetailsPage {
    param($State)
    if(-not (Test-DomeniaProbeDetailsState $State) -or $null -eq $State.Observation){return}
    $observation=$State.Observation;$attempt=($State.Choice.SelectedIndex -eq 1)
    $data=if($attempt){$observation.AttemptData}else{$observation.Data}
    if($attempt -and $null -eq $data -and [string]$observation.Status -ceq 'Success'){$data=$observation.Data}
    $entry=$null
    if($null -ne $data -and $null -ne $data.Probes){$entry=Get-DomeniaMemberValue $data.Probes $State.ProbeId}
    $State.Grid.ItemsSource=$null;$State.Previous.IsEnabled=$false;$State.Next.IsEnabled=$false
    $note='Révision locale '+$State.SnapshotRevision+' · Réussite UTC : '+[string]$observation.LastSuccessAtUtc+' · Tentative UTC : '+[string]$observation.LastAttemptAtUtc
    if([string]$observation.Error){$note+=' · Dernière tentative non confirmée : '+[string]$observation.Error}
    if($null -eq $entry){$State.Status.Text=$note+' · Aucune valeur conservée pour ce relevé.';$State.Position.Text='';return}
    $properties=@(Get-DomeniaMember $entry 'Properties' @())
    if(-not $properties.Count){
        # Older rows did not carry their column schema. Never label them using a newer definition.
        $width=0;foreach($row in @($entry.Rows)){$width=[Math]::Max($width,@($row).Count)}
        $properties=@(for($i=1;$i -le $width;$i++){'Valeur '+$i})
        $note+=' · Ancien relevé : intitulés et types des colonnes non conservés'
    }
    $page=Get-DomeniaProbeDetailPage -Probe $entry -Properties $properties -Offset $State.Offset -Limit $State.Limit
    $State.Grid.ItemsSource=$page.Rows;$State.Previous.IsEnabled=$page.HasPrevious;$State.Next.IsEnabled=$page.HasNext
    $State.Position.Text=$(if($page.StoredCount){'Lignes '+($page.Offset+1)+'–'+($page.Offset+$page.Rows.Count)+' / '+$page.StoredCount}else{'Aucun détail mémorisé'})
    $total=if($null -eq $page.ReportedCount){'non déterminé'}elseif($page.CountComplete){[string]$page.ReportedCount}else{[string]$page.ReportedCount+' (complétude non confirmée)'}
    $State.Status.Text=$note+' · Total rapporté : '+$total+' · Détails mémorisés : '+$page.StoredCount+$(if($page.Truncated){' · Lecture partielle : '+$page.LimitReason}else{''})
}
function Fail-DomeniaProbeDetailsRead {
    param([string]$Message,$State)
    if(-not (Test-DomeniaProbeDetailsState $State)){return}
    $State.Status.Text='Lecture locale non confirmée : '+$Message;$State.Grid.ItemsSource=$null;$State.Previous.IsEnabled=$false;$State.Next.IsEnabled=$false
}
