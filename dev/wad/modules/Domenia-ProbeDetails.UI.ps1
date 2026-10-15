# Detail pages always read the committed families of the selected GUID. Opening never contacts a workstation.
# Points 81 to 99: above the stored rows, the interpreted reading of the probe family (Domenia-Readings.Model.ps1)
# combines the related probes of the same workstation, each with its own date and source.
function Show-DomeniaProbeDetails {
    param([string]$ProbeId)
    $selected=$script:SelectedObject
    if($null -eq $selected -or [string]$selected.Type -cne 'Machine' -or -not (Test-DomeniaGuidText ([string]$selected.Guid))){Set-Status 'Sélectionnez un poste identifié pour consulter ses mesures.' 'WARN';return}
    $probe=@(Get-DomeniaProbeCatalog|Where-Object{[string]$_.Id -ceq $ProbeId})
    if($probe.Count -ne 1){Set-Status 'Sonde absente du catalogue courant.' 'WARN';return}
    $definition=$probe[0]
    $readingDefinition=Get-DomeniaReadingForProbe $ProbeId
    $window=[Windows.Window]::new();$window.Title='Détails de la sonde · '+$definition.Name;$window.Width=1000;$window.Height=760
    $root=[Windows.Controls.DockPanel]::new();$root.Margin=[Windows.Thickness]::new(16)
    $top=[Windows.Controls.StackPanel]::new();[Windows.Controls.DockPanel]::SetDock($top,'Top')
    $title=[Windows.Controls.TextBlock]::new();$title.Text=[string]$selected.Name+' · '+$definition.Name;$title.FontSize=20;$title.FontWeight='SemiBold';$title.TextWrapping='Wrap';[void]$top.Children.Add($title)
    $status=[Windows.Controls.TextBlock]::new();$status.Text='Lecture des mesures enregistrées dans la base locale…';$status.TextWrapping='Wrap';$status.Margin='0,8,0,8';[void]$top.Children.Add($status)
    $readingTitle=[Windows.Controls.TextBlock]::new();$readingTitle.FontSize=15;$readingTitle.FontWeight='SemiBold';$readingTitle.TextWrapping='Wrap';$readingTitle.Margin='0,4,0,4'
    $readingGrid=New-DomeniaProbeReadingGrid
    $readingActions=[Windows.Controls.WrapPanel]::new();$readingActions.Margin='0,6,0,0';$readingActions.Visibility='Collapsed'
    $approve=[Windows.Controls.Button]::new();$approve.Content='Approuver cette version pour ce modèle';$approve.Margin='0,0,8,0';$approve.IsEnabled=$false
    $approve.ToolTip='Enregistre localement la version du BIOS de ce poste comme référence de son modèle. Aucune action sur le poste.'
    $remove=[Windows.Controls.Button]::new();$remove.Content='Retirer la référence du modèle';$remove.IsEnabled=$false
    $remove.ToolTip='Supprime la référence BIOS locale de ce modèle. Aucune action sur le poste.'
    foreach($control in @($approve,$remove)){[void]$readingActions.Children.Add($control)}
    if($null -ne $readingDefinition){
        $readingTitle.Text='Lecture : '+[string]$readingDefinition.Title+' (requêtes '+(@($readingDefinition.Probes) -join ', ')+')'
        foreach($control in @($readingTitle,$readingGrid,$readingActions)){[void]$top.Children.Add($control)}
        if([string]$readingDefinition.Id -ceq 'bios'){$readingActions.Visibility='Visible'}
    }
    $rawTitle=[Windows.Controls.TextBlock]::new();$rawTitle.Text='Valeurs enregistrées de la requête';$rawTitle.FontSize=15;$rawTitle.FontWeight='SemiBold';$rawTitle.Margin='0,12,0,4';[void]$top.Children.Add($rawTitle)
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
    $state=[pscustomobject]@{Window=$window;Status=$status;Choice=$choice;Grid=$grid;Previous=$previous;Next=$next;Position=$position;Closed=$false;Context=$context;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;Guid=[string]$selected.Guid;ProbeId=$ProbeId;Definition=$definition;Observation=$null;Offset=0;Limit=100;SnapshotRevision=-1L;ReadingDefinition=$readingDefinition;Reading=$null;ReadingGrid=$readingGrid;ReadingTitle=$readingTitle;Approve=$approve;Remove=$remove;Observations=@()}
    $window.Tag=$state;$window.Content=$root
    foreach($control in @($previous,$next,$choice,$close,$approve,$remove)){$control.Tag=$state}
    $previous.Add_Click({param($sender,$eventArgs)$s=$sender.Tag;$s.Offset=[Math]::Max(0,$s.Offset-$s.Limit);Update-DomeniaProbeDetailsPage $s})
    $next.Add_Click({param($sender,$eventArgs)$s=$sender.Tag;$s.Offset+=$s.Limit;Update-DomeniaProbeDetailsPage $s})
    $choice.Add_SelectionChanged({param($sender,$eventArgs)$s=$sender.Tag;if($null -ne $s.Observation){$s.Offset=0;Update-DomeniaProbeDetailsPage $s}})
    $close.Add_Click({param($sender,$eventArgs)Set-DomeniaSurfaceResult $sender.Tag.Window $false})
    $approve.Add_Click({param($sender,$eventArgs)Invoke-DomeniaBiosReferenceAction -State $sender.Tag})
    $remove.Add_Click({param($sender,$eventArgs)Invoke-DomeniaBiosReferenceAction -State $sender.Tag -Remove})
    try{
        # Only the families of this probe and of its reading, for this GUID: never every family of the workstation.
        $families=@('Probe:'+$ProbeId)
        if($null -ne $readingDefinition){foreach($id in @($readingDefinition.Probes)){if($families -cnotcontains ('Probe:'+$id)){$families+=('Probe:'+$id)}}}
        $job=Request-DomeniaStoreRead -Context $context -Query @{Kind='Observation';Guids=@($state.Guid);Families=$families;Limit=1} -SuccessHandler 'Complete-DomeniaProbeDetailsRead' -ErrorHandler 'Fail-DomeniaProbeDetailsRead' -CallbackState $state
        if(-not $job){throw 'Lecture locale non admise.'}
    }catch{Fail-DomeniaProbeDetailsRead $_.Exception.Message $state}
    try{[void](Show-DomeniaEmbeddedWindow $window)}finally{$state.Closed=$true}
}
function New-DomeniaProbeReadingGrid {
    # Facts grid of a reading: wrapped text, French headers, read only.
    $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.AutoGenerateColumns=$false;$grid.CanUserAddRows=$false;$grid.CanUserDeleteRows=$false;$grid.HeadersVisibility='Column';$grid.MaxHeight=300
    $wrap=[Windows.Style]::new([Windows.Controls.TextBlock]);[void]$wrap.Setters.Add([Windows.Setter]::new([Windows.Controls.TextBlock]::TextWrappingProperty,[Windows.TextWrapping]::Wrap))
    foreach($column in @(@('Point','Point',170),@('Valeur','Valeur',300),@('Etat','État',80),@('Date','Date',120),@('Source','Source',150),@('Limite','Limite',260),@('Piste','Piste',220))){
        $text=[Windows.Controls.DataGridTextColumn]::new();$text.Header=[string]$column[1];$text.Binding=[Windows.Data.Binding]::new([string]$column[0]);$text.Width=[Windows.Controls.DataGridLength]::new([double]$column[2]);$text.ElementStyle=$wrap
        $grid.Columns.Add($text)
    }
    return $grid
}
function Get-DomeniaBiosReferenceSettingKey {
    # Domain-scoped local setting, like the health policies: references of one domain never apply to another.
    param([string]$DomainDn)
    if(-not ([string]$DomainDn).Trim()){throw 'Aucun domaine actif pour les références BIOS.'}
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($DomainDn.Trim().ToLowerInvariant()))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return 'Inventory.BiosReferences.'+$hash
}
function Get-DomeniaStoredBiosReferences {
    $key=Get-DomeniaBiosReferenceSettingKey ([string]$script:Conn.BaseDn)
    return ConvertTo-DomeniaBiosReferenceBook ([string](Get-DomeniaSetting $key '')) -Strict
}
function Invoke-DomeniaBiosReferenceAction {
    # Explicit gesture in the BIOS reading: approves the version of this workstation for its model, or removes the
    # model reference. Local setting only: nothing is read from or written to the workstation or the directory.
    param($State,[switch]$Remove)
    if(-not (Test-DomeniaProbeDetailsState $State) -or $null -eq $State.Reading -or $null -eq $State.Reading.Context){return}
    $context=$State.Reading.Context
    try{
        if(-not [string]$context.Model){throw 'Modèle du poste non relevé.'}
        $key=Get-DomeniaBiosReferenceSettingKey ([string]$script:Conn.BaseDn)
        $book=Get-DomeniaStoredBiosReferences
        if($Remove){$book=Remove-DomeniaBiosReference $book ([string]$context.Manufacturer) ([string]$context.Model);$message='Référence BIOS retirée pour '+[string]$context.Model+'.'}
        else{
            if(-not [string]$context.Version){throw 'Version du BIOS non relevée.'}
            $book=Set-DomeniaBiosReference -Book $book -Manufacturer ([string]$context.Manufacturer) -Model ([string]$context.Model) -Version ([string]$context.Version) -NowUtc ([datetime]::UtcNow)
            $message='Version '+[string]$context.Version+' approuvée comme référence pour '+[string]$context.Model+'.'
        }
        Set-DomeniaSetting $key ($book|ConvertTo-Json -Depth 5 -Compress)
        Update-DomeniaProbeReading $State
        Set-Status $message
    }catch{Set-Status ('Référence BIOS non enregistrée : '+$_.Exception.Message) 'WARN'}
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
        $State.Observations=@($Result.Observations|Where-Object{[string]$_.Guid -ieq [string]$State.Guid})
        $State.SnapshotRevision=[long]$Result.SnapshotRevision
        Update-DomeniaProbeReading $State
        $rows=@($State.Observations|Where-Object{[string]$_.Family -ceq ('Probe:'+$State.ProbeId)})
        if($rows.Count -eq 0){$State.Status.Text='Aucune observation enregistrée pour cette sonde et ce poste. Lancez une collecte explicitement depuis le dashboard.';return}
        if($rows.Count -ne 1){throw 'Famille de mesures ambiguë.'}
        $State.Observation=$rows[0]
        $State.Choice.IsEnabled=$true
        if($null -eq $rows[0].Data){$State.Choice.SelectedIndex=1}
        Update-DomeniaProbeDetailsPage $State
    }catch{Fail-DomeniaProbeDetailsRead $_.Exception.Message $State}
}
function Update-DomeniaProbeReading {
    # Rebuilds the reading from the committed families already read; no new store or workstation request.
    param($State)
    if($null -eq $State.ReadingDefinition){return}
    $sources=@{}
    foreach($probeId in @($State.ReadingDefinition.Probes)){
        $row=@($State.Observations|Where-Object{[string]$_.Family -ceq ('Probe:'+$probeId)}|Select-Object -First 1)
        if(-not $row.Count){continue}
        $entry=$null
        if($null -ne $row[0].Data -and $null -ne (Get-DomeniaMemberValue $row[0].Data 'Probes')){$entry=Get-DomeniaMemberValue (Get-DomeniaMemberValue $row[0].Data 'Probes') $probeId}
        $attemptError=if([string]$row[0].Status -ceq 'Error'){[string]$row[0].Error}else{''}
        # Never read successfully: the failed attempt is the only fact, with its own date.
        if($null -eq $entry -and $attemptError){$entry=[pscustomobject]@{Error=$attemptError;CheckedUtc=[string]$row[0].LastAttemptAtUtc};$attemptError=''}
        $sources[$probeId]=ConvertTo-DomeniaReadingSource -ProbeId $probeId -Entry $entry -AttemptError $attemptError
    }
    $options=@{}
    try{$limits=(Get-DomeniaStoredHealthPolicy).Thresholds;$options.DiskFreeWarn=$limits.DiskFreeWarn;$options.DiskFreeAlert=$limits.DiskFreeAlert}catch{$options=@{}}
    $note=''
    if([string]$State.ReadingDefinition.Id -ceq 'bios'){try{$options.BiosReferences=Get-DomeniaStoredBiosReferences}catch{$note=' · Références BIOS locales illisibles : '+$_.Exception.Message}}
    try{
        $reading=Invoke-DomeniaReading -Id ([string]$State.ReadingDefinition.Id) -Sources $sources -Options $options
        $State.Reading=$reading
        $State.ReadingGrid.ItemsSource=@(ConvertTo-DomeniaReadingRows $reading)
        $State.ReadingTitle.Text='Lecture : '+[string]$reading.Title+' (requêtes '+(@($reading.Probes) -join ', ')+')'+$note
        $context=$reading.Context;$canApprove=$false;$canRemove=$false
        if($null -ne $context){$canApprove=((([string]$context.Model).Length -gt 0) -and (([string]$context.Version).Length -gt 0));$canRemove=($null -ne $context.Reference)}
        $State.Approve.IsEnabled=$canApprove;$State.Remove.IsEnabled=$canRemove
    }catch{$State.ReadingTitle.Text='Lecture interprétée indisponible : '+$_.Exception.Message;$State.ReadingGrid.ItemsSource=$null;$State.Approve.IsEnabled=$false;$State.Remove.IsEnabled=$false}
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
    # Point 10: last success, last attempt and its error, local write time, collector definition and incoherent dates.
    $note='Révision locale '+$State.SnapshotRevision+' · '+(Format-DomeniaObservationProvenance -Observation $observation -NowUtc ([datetime]::UtcNow)).Text
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
