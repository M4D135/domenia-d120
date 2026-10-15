$script:Continuity=$null
$script:FavouriteTreeReveal=$null
$script:FavouriteTreeRevealTimer=$null
function Stop-DomeniaFavouriteTreeReveal {
    param([string]$Message='')
    $script:FavouriteTreeReveal=$null
    if($null -ne $script:FavouriteTreeRevealTimer){$script:FavouriteTreeRevealTimer.Stop()}
    if($Message){[void](Set-DomeniaControlText 'LblTreeStatus' $Message);Set-Status $Message 'WARN'}
}
function Start-DomeniaFavouriteTreeReveal {
    # The favourite already started its one content search. This operation only locates its tree item.
    param([string]$Dn)
    Stop-DomeniaFavouriteTreeReveal
    $path=Get-DomeniaTreeRevealPath -Dn $Dn -BaseDn ([string]$script:Conn.BaseDn)
    if(-not $path.Count){return}
    if($null -ne $script:Continuity){
        $script:Continuity.Restoring=$false;$script:Continuity.RestoreSearch=$null
        $script:Continuity.RestoreToken=([string]$script:SessionEpoch+'|'+(Get-DomeniaTreeContextKey))
    }
    $timeout=[Math]::Max(60,2*[int](Get-CfgValue 'Async' 'TreeTimeoutSeconds' 30))
    $now=[datetime]::UtcNow
    $script:FavouriteTreeReveal=[pscustomobject]@{
        DN=$Dn;Path=$path;Level=0;Parent=$null;Root=$null;Frames=$null
        Epoch=[long]$script:SessionEpoch;Context=(Get-DomeniaTreeContextKey);Generation=[int]$script:GlobalSearchGeneration
        IdleSeconds=$timeout;IdleDeadline=$now.AddSeconds($timeout);Deadline=$now.AddMinutes(10)
    }
    if($null -eq $script:FavouriteTreeRevealTimer){
        $script:FavouriteTreeRevealTimer=New-DomeniaTimer -Owner 'Timer:FavouriteTreeReveal' -IntervalMs 35 -Tick {Invoke-DomeniaFavouriteTreeReveal}
    }
    $script:FavouriteTreeRevealTimer.Start()
    Invoke-DomeniaFavouriteTreeReveal
}
function Invoke-DomeniaFavouriteTreeReveal {
    $s=$script:FavouriteTreeReveal
    if($null -eq $s){return}
    if($script:AsyncEngineClosing -or $s.Epoch -ne [long]$script:SessionEpoch -or $s.Context -cne (Get-DomeniaTreeContextKey) -or $s.Generation -ne [int]$script:GlobalSearchGeneration -or $s.DN -ine [string]$script:SelectedBranchDn){Stop-DomeniaFavouriteTreeReveal;return}
    $now=[datetime]::UtcNow
    if($now -gt $s.Deadline -or $now -gt $s.IdleDeadline){Stop-DomeniaFavouriteTreeReveal 'Localisation du favori non confirmée dans le délai. Les résultats restent disponibles ; redépliez la branche pour réessayer.';return}
    if(Test-DomeniaAccessBusyWrite){return}
    $tree=Get-DomeniaControl 'TvDirectory';if($null -eq $tree){return}
    if($null -ne $s.Root -and -not $tree.Items.Contains($s.Root)){Stop-DomeniaFavouriteTreeReveal;return}
    $watch=[Diagnostics.Stopwatch]::StartNew();$examined=0
    while($examined -lt 512 -and $watch.ElapsedMilliseconds -lt 8){
        if($null -eq $s.Frames){
            if($null -ne $s.Parent){
                if([bool]$s.Parent.Tag.Loading -or [string]$s.Parent.Tag.RenderId){return}
                if(-not [bool]$s.Parent.Tag.Loaded){
                    Stop-DomeniaFavouriteTreeReveal 'La branche du favori nʼa pas pu être lue. Les résultats sont conservés ; redépliez cette branche pour réessayer.';return
                }
            }
            # Keep the live collection, including an empty/single-item ItemCollection.
            # A pipeline-producing if expression would unwrap/enumerate it in PowerShell.
            $items=$tree.Items
            if($null -ne $s.Parent){$items=$s.Parent.Items}
            if($null -eq $s.Parent -and $items.Count -eq 0){return}
            $s.Frames=[Collections.Generic.Queue[object]]::new()
            $s.Frames.Enqueue([pscustomobject]@{Items=$items;Index=0;Group=$null})
        }
        if($s.Frames.Count -eq 0){
            Stop-DomeniaFavouriteTreeReveal 'Le chemin du favori ne figure pas dans les branches chargées. Vérifiez son emplacement ou vos droits ; aucune autre OU nʼest sélectionnée.';return
        }
        $frame=$s.Frames.Peek()
        if($frame.Index -ge $frame.Items.Count){[void]$s.Frames.Dequeue();continue}
        $node=$frame.Items[$frame.Index];$frame.Index++;$examined++
        $tag=Get-DomeniaMember $node 'Tag'
        if($null -eq $tag){continue}
        if([string](Get-DomeniaMember $tag 'Kind') -eq 'SystemGroup'){
            $s.Frames.Enqueue([pscustomobject]@{Items=$node.Items;Index=0;Group=$node});continue
        }
        if([string](Get-DomeniaMember $tag 'DN') -ine [string]$s.Path[$s.Level]){continue}
        if($null -ne $frame.Group){$frame.Group.IsExpanded=$true}
        if($s.Level -eq 0){$s.Root=$node}
        $s.IdleDeadline=[datetime]::UtcNow.AddSeconds($s.IdleSeconds)
        if($s.Level -eq $s.Path.Count-1){
            $old=$script:SuppressBranchAutoLoad;$script:SuppressBranchAutoLoad=$true
            try{$node.IsSelected=$true;$node.BringIntoView();Update-DomeniaSearchScopeUi}
            finally{$script:SuppressBranchAutoLoad=$old}
            if($null -ne $script:Continuity){$script:Continuity.Dirty=$true}
            [void](Set-DomeniaControlText 'LblTreeStatus' 'OU du favori sélectionnée dans lʼarbre.')
            Stop-DomeniaFavouriteTreeReveal;return
        }
        $s.Parent=$node;$s.Level++;$s.Frames=$null
        # Expanded starts the existing one-level, commit-before-display reader. Never retry an auth/network failure here.
        if(-not $node.IsExpanded){$node.IsExpanded=$true}
        elseif(-not [bool]$tag.Loaded -and -not [bool]$tag.Loading -and -not [string]$tag.RenderId){Load-TreeChildren -Node $node}
        if(-not [bool]$tag.Loaded){return}
    }
}
function Get-DomeniaGridColumnKey {
    param($Column,[int]$Index)
    $key=[string]$Column.SortMemberPath
    try{if(-not $key -and $null -ne $Column.Binding){$key=[string]$Column.Binding.Path.Path}}catch{}
    if(-not $key){
        if($Column.Header -is [string]){$key=[string]$Column.Header}
        elseif($Column.Header -is [Windows.Controls.TextBlock]){$key=[string]$Column.Header.Text}
    }
    if(-not $key){$key='Column'+$Index}
    if($key.Length -gt 240){$key=$key.Substring(0,240)}
    return $key
}
function Register-DomeniaGridLayout {
    param($Grid)
    if($null -eq $Grid -or $null -eq $script:Continuity -or -not $Grid.Name){return}
    $name=[string]$Grid.Name
    $columns=[Collections.Generic.List[object]]::new();$keys=@{};$i=0
    foreach($col in $Grid.Columns){
        $key=Get-DomeniaGridColumnKey $col $i
        if($keys.ContainsKey($key)){$key+='|'+$i};$keys[$key]=$true
        $columns.Add([pscustomobject]@{Column=$col;Key=$key});$i++
    }
    $first=-not $script:Continuity.Grids.ContainsKey($name)
    $script:Continuity.Grids[$name]=[pscustomobject]@{Grid=$Grid;Columns=$columns.ToArray()}
    if($script:Continuity.Layouts.ContainsKey($name)){
        $saved=ConvertTo-DomeniaColumnLayout $script:Continuity.Layouts[$name]
        $script:Continuity.Applying=$true
        try{
            foreach($r in @($saved|Sort-Object Index)){
                $entry=@($columns|Where-Object{$_.Key -ceq $r.Key}|Select-Object -First 1)
                if(-not $entry.Count){continue}
                $col=$entry[0].Column
                $col.Width=[Windows.Controls.DataGridLength]::new([double]$r.Width,[Windows.Controls.DataGridLengthUnitType]([string]$r.Unit))
                $col.DisplayIndex=[Math]::Min([int]$r.Index,$Grid.Columns.Count-1)
            }
        }finally{$script:Continuity.Applying=$false}
    }
    if($first){
        $Grid.Add_ColumnReordered({param($sender,$args) Save-DomeniaGridLayout $sender})
        $Grid.Add_PreviewMouseLeftButtonUp({param($sender,$args) Save-DomeniaGridLayout $sender})
        $Grid.Add_AutoGeneratedColumns({param($sender,$args) Register-DomeniaGridLayout $sender})
    }
}
function Save-DomeniaGridLayout {
    param($Grid)
    if($null -eq $script:Continuity -or $script:Continuity.Applying -or $null -eq $Grid -or -not $script:Continuity.Grids.ContainsKey([string]$Grid.Name)){return}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($entry in $script:Continuity.Grids[[string]$Grid.Name].Columns){
        $c=$entry.Column
        $rows.Add([pscustomobject]@{Key=$entry.Key;Index=[int]$c.DisplayIndex;Width=$c.Width.Value.ToString('R',[Globalization.CultureInfo]::InvariantCulture);Unit=$c.Width.UnitType.ToString()})
    }
    $script:Continuity.Layouts[[string]$Grid.Name]=ConvertTo-DomeniaColumnLayout $rows.ToArray()
    Set-DomeniaSetting -Name 'GridLayoutsJson' -Value ($script:Continuity.Layouts|ConvertTo-Json -Depth 5 -Compress)
}
function Get-DomeniaTreeContextKey {
    if($null -eq $script:Conn -or -not $script:Conn.BaseDn){return ''}
    return Get-DomeniaLiveHash (([string]$script:Conn.BaseDn+'|'+[string]$script:Conn.BindUser).ToLowerInvariant())
}
function Get-DomeniaRealizedTreeNodes {
    $tree=Get-DomeniaControl 'TvDirectory';$out=[Collections.Generic.List[object]]::new()
    if($null -eq $tree){return ,$out.ToArray()}
    $queue=[Collections.Generic.Queue[object]]::new();foreach($n in $tree.Items){$queue.Enqueue($n)}
    while($queue.Count -gt 0 -and $out.Count -lt 600){
        $n=$queue.Dequeue();if($n -isnot [Windows.Controls.TreeViewItem]){continue};$out.Add($n)
        foreach($c in $n.Items){if($c -is [Windows.Controls.TreeViewItem]){$queue.Enqueue($c)}}
    }
    return ,$out.ToArray()
}
function Save-DomeniaTreeBookmark {
    if($null -eq $script:Continuity -or $script:Continuity.Restoring){return}
    $key=Get-DomeniaTreeContextKey;if(-not $key -or -not $script:SelectedBranchDn){return}
    $expanded=[Collections.Generic.List[string]]::new()
    foreach($n in (Get-DomeniaRealizedTreeNodes)){if($n.IsExpanded -and $n.Tag.DN -and $expanded.Count -lt 128){$expanded.Add([string]$n.Tag.DN)}}
    $sub=Get-DomeniaControl 'ChkSubtree'
    $r=[pscustomobject]@{Selected=[string]$script:SelectedBranchDn;Expanded=$expanded.ToArray();Subtree=($null -eq $sub -or [bool]$sub.IsChecked);At=[datetime]::UtcNow.ToString('o')}
    $valid=ConvertTo-DomeniaTreeBookmark $r ([string]$script:Conn.BaseDn)
    if($null -eq $valid){return}
    $script:Continuity.Bookmarks[$key]=$valid
    if($script:Continuity.Bookmarks.Count -gt 12){$old=@($script:Continuity.Bookmarks.Keys|Where-Object{$_ -ne $key}|Select-Object -First 1);if($old.Count){[void]$script:Continuity.Bookmarks.Remove($old[0])}}
    Set-DomeniaSetting 'OuBookmarksJson' ($script:Continuity.Bookmarks|ConvertTo-Json -Depth 5 -Compress)
}
function Start-DomeniaTreeBookmarkRestore {
    if($null -eq $script:Continuity){return}
    $key=Get-DomeniaTreeContextKey
    $token=([string]$script:SessionEpoch+'|'+$key)
    if($script:Continuity.RestoreToken -ceq $token){return}
    $script:Continuity.Context=$key;$script:Continuity.RestoreToken=$token
    $script:Continuity.Restoring=$false;$script:Continuity.RestoreSearch=$null
    if(-not $key -or -not $script:Continuity.Bookmarks.ContainsKey($key)){return}
    $r=ConvertTo-DomeniaTreeBookmark $script:Continuity.Bookmarks[$key] ([string]$script:Conn.BaseDn)
    if($null -eq $r){return}
    $script:Continuity.Restoring=$true;$script:Continuity.Restore=$r
    $script:Continuity.RestoreDeadline=[datetime]::UtcNow.AddSeconds(60);$script:Continuity.SelectedRestored=$false
    $script:Continuity.RestoreGeneration=[int]$script:GlobalSearchGeneration
}
function Invoke-DomeniaTreeBookmarkRestore {
    $s=$script:Continuity
    if(-not $s.Restoring){return}
    if($s.Context -cne (Get-DomeniaTreeContextKey)){$s.Restoring=$false;$s.RestoreSearch=$null;return}
    if(-not $s.SelectedRestored -and $s.RestoreGeneration -ne [int]$script:GlobalSearchGeneration){$s.Restoring=$false;$s.RestoreSearch=$null;return}
    if([datetime]::UtcNow -gt $s.RestoreDeadline){
        $s.Restoring=$false
        if(-not $s.SelectedRestored){
            # D039: warn in the page and wait for an explicit choice. A timeout is never read as an absence,
            # and neither the domain nor any other scope is substituted.
            $decision=Get-DomeniaOuRestoreDecision
            if($null -ne $decision -and $decision.Message){
                Set-Status ([string]$decision.Message) 'WARN'
                Show-DomeniaOuRestoreNotice -Decision $decision
            }else{Set-Status 'OU mémorisée non retrouvée dans le délai. Choisissez une branche ; aucune recherche globale de remplacement.' 'WARN'}
        }
        return
    }
    if(Test-DomeniaAccessBusyWrite){return}
    $pending=$false;$expandedThisTick=0
    foreach($n in (Get-DomeniaRealizedTreeNodes)){
        $dn=[string]$n.Tag.DN;if(-not $dn){continue}
        $needed=($s.Restore.Expanded -contains $dn -or $s.Restore.Selected.EndsWith(','+$dn,[StringComparison]::OrdinalIgnoreCase))
        if($needed -and -not $n.IsExpanded -and $n.IsEnabled){
            if($expandedThisTick -lt 1 -and @($script:AsyncJobs.Keys).Count -lt [Math]::Max(1,([int](Get-CfgValue 'Async' 'MaxThreads' 6)-2))){$n.IsExpanded=$true;$expandedThisTick++};$pending=$true
        }
        if($needed -and -not [bool]$n.Tag.Loaded){$pending=$true}
        if(-not $s.SelectedRestored -and $dn -ieq $s.Restore.Selected -and $n.IsEnabled){
            $old=$script:SuppressBranchAutoLoad;$script:SuppressBranchAutoLoad=$true
            try{
                $n.IsSelected=$true;$script:SelectedBranchDn=$dn
                $check=Get-DomeniaControl 'ChkSubtree';if($null -ne $check){$check.IsChecked=[bool]$s.Restore.Subtree}
                Update-DomeniaSearchScopeUi;$n.BringIntoView();$s.SelectedRestored=$true
            }finally{$script:SuppressBranchAutoLoad=$old}
            Hide-DomeniaOuRestoreNotice
            # Restore the filter under suppression, then queue one fresh search.
            # Unrelated expanded branches must not delay this content load.
            # D032: an OU search is guarded by the OU text, never by the text of the upper bar.
            $scope=Get-DomeniaSearchScope -Mode OU
            $s.RestoreSearch=[pscustomobject]@{
                DN=$dn;Scope=[string]$scope.Scope;Context=$s.Context;Epoch=[long]$script:SessionEpoch
                Generation=[int]$script:GlobalSearchGeneration
                Text=(Get-DomeniaSearchText -Mode OU)
                TypeFilter=[string](Get-GlobalSelectedTypeFilter -Mode OU)
            }
        }
    }
    if($s.SelectedRestored -and -not $pending){$s.Restoring=$false}
}
function Invoke-DomeniaRestoredOuSearch {
    if($null -eq $script:Continuity -or $null -eq $script:Continuity.RestoreSearch){return}
    $c=$script:Continuity;$request=$c.RestoreSearch
    if($script:AsyncEngineClosing -or $request.Epoch -ne [long]$script:SessionEpoch -or $request.Context -cne (Get-DomeniaTreeContextKey) -or $request.Generation -ne [int]$script:GlobalSearchGeneration){$c.RestoreSearch=$null;return}
    $scope=Get-DomeniaSearchScope -Mode OU
    $text=Get-DomeniaSearchText -Mode OU
    if([string]$scope.BaseDn -ine $request.DN -or [string]$scope.Scope -ne $request.Scope -or $text -cne $request.Text -or [string](Get-GlobalSelectedTypeFilter -Mode OU) -cne $request.TypeFilter){$c.RestoreSearch=$null;return}
    if($script:RestoringSettings -or $script:SuppressBranchAutoLoad -or -not $script:Conn.Connected -or (Test-DomeniaAccessBusyWrite)){return}
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid -or -not $grid.IsEnabled -or $null -eq $script:Live){return}
    # Consume before scheduling: a timer tick, callback or duplicate ContentRendered
    # event cannot launch a second search. Keep the current workspace and drafts.
    $c.RestoreSearch=$null
    Write-AppLog ('OU restaurée : chargement unique du périmètre '+$request.DN+' ; portée='+$request.Scope+'. Sans sonde des postes.') 'INFO'
    Invoke-GlobalSearch -AllowEmpty -SilentError -PreserveSelection -SearchMode OU
}
function Complete-DomeniaObjectChanges {
    param($Result,$State)
    $effective=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Records','Server')
    if($null -eq $effective){Fail-DomeniaObjectChanges -Message 'Reverification AD sans resultat exploitable.' -State $State;return}
    Complete-DomeniaDirectoryReadPipe -Pipe $State.DirectoryPipe -Final $effective
}
function Fail-DomeniaObjectChanges {
    param($Message,$State)
    if($null -ne $State -and $null -ne $State.PSObject.Properties['DirectoryPipe'] -and -not $State.DirectoryPipe.Completed){
        try{$State.DirectoryPipe.Stop.Cancel()}catch{}
        Complete-DomeniaDirectoryReadPipe -Pipe $State.DirectoryPipe -Error ([string]$Message)
    }
    if($null -eq $script:Continuity){return}
    if($null -ne $State -and ($State.Epoch -ne [long]$script:SessionEpoch -or $State.Identity -cne [string]$script:Live.Identity)){return}
    $script:Continuity.ChangeJob='';$script:Continuity.ChangeNext=[datetime]::UtcNow.AddSeconds(120)
    Write-AppLog ('Reverification des objets non confirmee : '+$Message) 'WARN'
    [void](Request-DomeniaAccessRecovery -Operation 'Reverification AD' -ErrorValue $Message -OperationId 'GlobalSearch')
}
function Clear-DomeniaVisitCacheForObject {
    # D025 / FI-21: drops the cached reads of one object only: every key carrying its GUID (with or without hyphens),
    # or, without a GUID, every key carrying its DN. The other objects and the cached lists stay. Returns the count.
    param([AllowEmptyString()][string]$Guid='',[AllowEmptyString()][string]$Dn='')
    if($null -eq $script:VisitCache){return 0}
    $removed=0
    $invalidateGuid=ConvertTo-DomeniaGuidText $Guid
    if($invalidateGuid){
        $needle=$invalidateGuid.ToLowerInvariant()
        $needleNoHyphen=$needle.Replace('-','')
        foreach($cacheKey in @($script:VisitCache.Keys)){
            $keyText=[string]$cacheKey
            $keyNoHyphen=$keyText.Replace('-','')
            if(($keyText.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($keyNoHyphen.IndexOf($needleNoHyphen,[StringComparison]::OrdinalIgnoreCase) -ge 0)){[void]$script:VisitCache.Remove($cacheKey);$removed++}
        }
    }elseif($Dn){
        foreach($cacheKey in @($script:VisitCache.Keys)){
            if(([string]$cacheKey).IndexOf($Dn,[StringComparison]::OrdinalIgnoreCase) -ge 0){[void]$script:VisitCache.Remove($cacheKey);$removed++}
        }
    }
    return $removed
}
function Test-DomeniaListRevalidationEnabled {
    # SE-13: the background revalidation of the listed objects is off by default (nothing on the network without a
    # gesture). An administrator may enable it (Streaming.RevalidateListedObjects); the in-page switch then stops it
    # for the session.
    if(-not (ConvertTo-SuiteFlag (Get-CfgValue 'Streaming' 'RevalidateListedObjects' $false) -Default $false)){return $false}
    return (-not [bool]$script:ListRevalidationPaused)
}
function Update-DomeniaListRevalidationUi {
    # SE-13: the switch and 'Liste vérifiée à HH:mm' exist in the page only when the administrator enabled the revalidation.
    $configured=ConvertTo-SuiteFlag (Get-CfgValue 'Streaming' 'RevalidateListedObjects' $false) -Default $false
    $panel=Get-DomeniaControl 'UxListRevalidation'
    if($null -ne $panel){$panel.Visibility=if($configured){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    $label=''
    if($configured){
        if([bool]$script:ListRevalidationPaused){$label='arrêtée pour cette session'}
        elseif($null -ne $script:Continuity -and $null -ne $script:Continuity.PSObject.Properties['CheckedAt'] -and $script:Continuity.CheckedAt -is [datetime]){$label='Liste vérifiée à '+$script:Continuity.CheckedAt.ToString('HH:mm')}
        else{$label='Liste non encore revérifiée'}
    }
    [void](Set-DomeniaControlText 'LblListRevalidation' $label)
}
function Test-DomeniaContinuityTickNeeded {
    # PF-06: a restore, a layout to save, a revalidation in progress or its results to show keep the 700 ms pace.
    $c=$script:Continuity
    if($null -eq $c){return $false}
    if([bool]$c.Restoring -or [bool]$c.Dirty -or [bool]$c.CacheDirty -or $null -ne $c.RestoreSearch -or [bool]$script:FleetAwaitingRestore){return $true}
    # Revalidation results waiting to be shown; the revalidation itself is paced by ChangeNext (2 s or more).
    if($c.ChangeEvents.Count -gt 0){return $true}
    if([string]$c.RestoreToken -cne ([string]$script:SessionEpoch+'|'+(Get-DomeniaTreeContextKey))){return $true}
    return $false
}
function Invoke-DomeniaObjectChanges {
    if($null -eq $script:Continuity -or -not (Test-DomeniaLiveSearchActive) -or (Test-DomeniaAccessBusyWrite)){return}
    $s=$script:Live.Search;$c=$script:Continuity;$grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid -or -not $grid.IsEnabled -or -not $s.Finalized -or $s.Error){return}
    if(-not [object]::ReferenceEquals($c.ChangeSearch,$s)){
        $c.ChangeSearch=$s;$c.ChangeQueue.Clear();$c.ChangeEvents.Clear();$c.Stamps=@{};$c.ChangeNext=[datetime]::UtcNow.AddSeconds(8);$c.CacheDirty=$false
        # SE-13: a new list has not been checked yet.
        if($null -ne $c.PSObject.Properties['CheckedAt']){$c.CheckedAt=$null;try{Update-DomeniaListRevalidationUi}catch{}}
    }
    $count=0;$watch=[Diagnostics.Stopwatch]::StartNew()
    while($c.ChangeEvents.Count -gt 0 -and $count -lt 8 -and $watch.ElapsedMilliseconds -lt 5){
        $event=$c.ChangeEvents.Dequeue();$count++
        if(-not [object]::ReferenceEquals($s,$event.State.Search) -or $event.State.Identity -cne $script:Live.Identity -or $event.State.Mutation -ne $c.Mutation){continue}
        $r=$event.Row;$key=([string]$r.OldDN).ToLowerInvariant()
        if(-not $s.Map.ContainsKey($key)){continue};$row=$s.Map[$key]
        if([string]$row.Guid -ine [string]$r.Guid){continue}
        if($r.Status -eq 'Unconfirmed'){$row.DirectoryState='A reverifier : deplace, filtre ou acces';continue}
        if($r.DN -ine $row.DN){
            # Point 23: moved or renamed inside the scope of this list (the check reads that scope only). The row keeps
            # its GUID and takes its new DN under a new key: no second row, no stale path in the fiche.
            $newKey=([string]$r.DN).Trim().ToLowerInvariant()
            if($newKey -and (-not $s.Map.ContainsKey($newKey))){
                $oldDn=[string]$row.DN
                [void]$s.Map.Remove($key);$s.Map[$newKey]=$row
                if($s.Fresh.ContainsKey($key)){$s.Fresh[$newKey]=$s.Fresh[$key];[void]$s.Fresh.Remove($key)}
                if($null -ne $r.Row){$snapshot=ConvertTo-DomeniaLiveSnapshot $r.Row;foreach($p in $snapshot.PSObject.Properties){Set-DomeniaLiveRowValue $row $p.Name $p.Value};$s.Fresh[$newKey]=$snapshot}
                else{Set-DomeniaLiveRowValue $row 'DN' ([string]$r.DN)}
                [void](Clear-DomeniaVisitCacheForObject -Guid ([string]$row.Guid) -Dn $oldDn)
                $row.DirectoryState=if(${function:Get-DomeniaMoveStateText}){Get-DomeniaMoveStateText (Get-DomeniaDirectoryMove -OldDn $oldDn -NewDn ([string]$r.DN) -ScopeDn ([string]$s.State.BaseDn) -Scope $(if([string]$s.State.Scope -ieq 'OneLevel'){'OneLevel'}else{'Subtree'}))}else{'Déplacé ou renommé'}
                $s.RefreshNeeded=$true
            }else{$row.DirectoryState='Objet déplacé : relancer la recherche'}
            $row.DirectoryChecked=$event.At;$c.Stamps[[string]$r.Guid]=[string]$r.Stamp;$c.CacheDirty=$true
            continue
        }
        if($r.Status -eq 'Changed' -and $null -ne $r.Row){
            $snapshot=ConvertTo-DomeniaLiveSnapshot $r.Row
            foreach($p in $snapshot.PSObject.Properties){Set-DomeniaLiveRowValue $row $p.Name $p.Value}
            $s.Fresh[$key]=$snapshot;$s.RefreshNeeded=$true;$c.CacheDirty=$true
            # D025: invalidate detail caches by object GUID when known; otherwise fall back to the old DN match.
            [void](Clear-DomeniaVisitCacheForObject -Guid ([string]$row.Guid) -Dn ([string]$row.DN))
            $row.DirectoryState='AD mis a jour'
        }else{$row.DirectoryState='AD revalide'}
        $row.DirectoryChecked=$event.At;$c.Stamps[[string]$r.Guid]=[string]$r.Stamp
    }
    if($c.CacheDirty -and $c.ChangeEvents.Count -eq 0){
        # Rows came from SQL readback; rendering a changed row never writes another cache.
        $c.CacheDirty=$false
    }
    if(-not $grid.IsVisible -or $c.ChangeJob -or [datetime]::UtcNow -lt $c.ChangeNext){return}
    # C2: no directory read in demonstration. C1: the rest policy decides; without it, only an active window revalidates.
    if([bool]$script:DemoMode){return}
    # PF-10: no command lookup in the tick; the shared C1 check keeps its open fallback.
    if(-not (Test-DomeniaLiveBackgroundAllowed -Source 'ObjectChanges')){return}
    if([bool]$script:DirectoryCredentialFaulted -and $null -eq (Get-DomeniaRetryCredential 'GlobalSearch')){return}
    if(@($script:AsyncJobs.Keys).Count -ge [Math]::Max(1,([int](Get-CfgValue 'Async' 'MaxThreads' 6)-2))){return}
    # SE-13: off by default; when an administrator enables it, the in-page switch can stop it for the session.
    if(-not (Test-DomeniaListRevalidationEnabled)){return}
    if($c.ChangeQueue.Count -eq 0){foreach($r in $s.Rows){if($r.Guid){$c.ChangeQueue.Enqueue([pscustomobject]@{Guid=[string]$r.Guid;DN=[string]$r.DN;Stamp=[string]$c.Stamps[[string]$r.Guid]})}}}
    $items=[Collections.Generic.List[object]]::new();while($items.Count -lt 24 -and $c.ChangeQueue.Count){$items.Add($c.ChangeQueue.Dequeue())}
    if(-not $items.Count){$c.ChangeNext=[datetime]::UtcNow.AddSeconds(60);return}
    # D031: a global list is revalidated in the whole domain with the global type only. It never inherits
    # the selected OU, its depth, its type or its text; an OU list keeps its own perimeter.
    # A work view (D038) is revalidated in its own perimeter with the allowed classes only.
    $viewId='';if($null -ne $s.State.PSObject.Properties['ViewId']){$viewId=[string]$s.State.ViewId}
    if([string]$s.State.SearchMode -eq 'Global'){$q=[pscustomobject]@{BaseDn=[string]$s.State.BaseDn;Scope=[string]$s.State.Scope;Filter=[string]$s.State.TypeFilter}}
    elseif($viewId){$q=[pscustomobject]@{BaseDn=[string]$s.State.BaseDn;Scope=[string]$s.State.Scope;Filter=(Get-TypeLdapFilter -Type 'Tous')}}
    else{$q=Get-BranchQueryData}
    $state=[pscustomobject]@{Search=$s;Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch;Mutation=$c.Mutation;StoreContext=(New-DomeniaStoreContext -RequestId ([guid]::NewGuid().ToString('D')) -Generation ([long]$s.State.Generation) -ScopeDn ([string]$q.BaseDn) -Subtree ([string]$q.Scope -eq 'Subtree'))}
    $state|Add-Member NoteProperty ChangeResults ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
    $pipe=New-DomeniaDirectoryReadPipe -Context $state.StoreContext -CommitHandler 'Complete-DomeniaDirectoryChangesCommit' -CompleteHandler 'Complete-DomeniaDirectoryChangesRead' -ErrorHandler 'Fail-DomeniaObjectChanges' -CallbackState $state
    $state|Add-Member NoteProperty DirectoryPipe $pipe
    try{
        $c.ChangeJob=Start-UiTask -Name 'Reverification objets listes' -OperationId 'LiveDirectoryCheck' -Code (Get-DomeniaChangeWorkerCode) -Payload ([pscustomobject]@{Items=$items.ToArray();BaseDn=$q.BaseDn;Scope=$q.Scope;Filter=$q.Filter;Progress=$pipe.Input;DirectoryReadState=$pipe.Collector;StopToken=$pipe.Stop.Token;ChangeResults=$state.ChangeResults}) -CallbackState $state -ReplaceKey 'listed-changes' -TimeoutSeconds 20 -SuccessHandler 'Complete-DomeniaObjectChanges' -ErrorHandler 'Fail-DomeniaObjectChanges' -TaskClass 'Background'
        $interval=if($c.ChangeQueue.Count){2}else{[Math]::Max(30,[Math]::Min(600,[int](Get-CfgValue 'Streaming' 'RevalidateIntervalSeconds' 60)))}
        $c.ChangeNext=[datetime]::UtcNow.AddSeconds($interval)
    }catch{$c.ChangeJob='';$c.ChangeNext=[datetime]::UtcNow.AddSeconds(60);Write-AppLog ('Reverification differee : '+$_.Exception.Message) 'WARN'}
}
function Get-DomeniaOuRestoreDecision {
    # D039: decides from what the tree actually read. The parent loaded without the saved OU means it is absent
    # under that parent (deleted or moved); anything else (timeout, refusal, branch not read) is a read to retry.
    $s=$script:Continuity
    if($null -eq $s -or $null -eq $s.Restore -or $null -eq (Get-Command Resolve-DomeniaOuRestore -CommandType Function -ErrorAction SilentlyContinue)){return $null}
    $saved=[string]$s.Restore.Selected
    if(-not $saved){return $null}
    $parentDn=Get-DomeniaDnParent $saved
    $parentRead=$false;$found=$false
    foreach($n in (Get-DomeniaRealizedTreeNodes)){
        $dn=[string]$n.Tag.DN
        if($dn -ieq $saved){$found=$true}
        if($parentDn -and $dn -ieq $parentDn -and [bool]$n.Tag.Loaded){$parentRead=$true}
    }
    $decision=Resolve-DomeniaOuRestore -SavedDn $saved -Exists $found -MovedToDn '' -ReadFailed (-not $parentRead -and -not $found)
    Add-Member -InputObject $decision -NotePropertyName SavedDn -NotePropertyValue $saved -Force
    return $decision
}
function Show-DomeniaOuRestoreNotice {
    # In-page warning with an explicit choice. The selected branch and the results stay unchanged.
    param($Decision)
    if($null -eq $Decision){return}
    [void](Set-DomeniaControlText 'LblOuRestoreMessage' ([string]$Decision.Message))
    $banner=Get-DomeniaControl 'OuRestoreBanner'
    if($null -ne $banner){$banner.Visibility='Visible'}
    if($null -ne $script:Continuity){Add-Member -InputObject $script:Continuity -NotePropertyName RestoreNotice -NotePropertyValue $Decision -Force}
}
function Hide-DomeniaOuRestoreNotice {
    $banner=Get-DomeniaControl 'OuRestoreBanner'
    if($null -ne $banner){$banner.Visibility='Collapsed'}
    if($null -ne $script:Continuity -and $null -ne $script:Continuity.PSObject.Properties['RestoreNotice']){$script:Continuity.RestoreNotice=$null}
}
function Invoke-DomeniaOuRestoreRetry {
    # Explicit operator gesture: one more restoration attempt of the same bookmark, nothing else.
    if($null -eq $script:Continuity -or (Test-DomeniaAccessBusyWrite)){return}
    Hide-DomeniaOuRestoreNotice
    $script:Continuity.RestoreToken=''
    Start-DomeniaTreeBookmarkRestore
    if(-not $script:Continuity.Restoring){Set-Status 'Aucune OU mémorisée à relire pour ce compte et ce domaine.' 'WARN'}
}
function Initialize-DomeniaContinuity {
    # Search and navigation surfaces (hint, work views, back and forward) belong to the search module;
    # it keeps its own once-per-window guard.
    if($null -ne (Get-Command Initialize-DomeniaSearchUi -CommandType Function -ErrorAction SilentlyContinue)){
        try{Initialize-DomeniaSearchUi}catch{Write-AppLog ('Initialisation de la recherche : '+$_.Exception.Message) 'ERROR'}
    }
    if($null -ne $script:Continuity){return}
    $script:Continuity=[pscustomobject]@{Mutation=0L;Grids=@{};Layouts=(ConvertTo-DomeniaStateMap ([string](Get-DomeniaSetting 'GridLayoutsJson' '{}')));Bookmarks=(ConvertTo-DomeniaStateMap ([string](Get-DomeniaSetting 'OuBookmarksJson' '{}')));Applying=$false;Restoring=$false;Restore=$null;RestoreSearch=$null;RestoreToken='';RestoreGeneration=0;Context='';RestoreDeadline=[datetime]::MinValue;SelectedRestored=$false;Dirty=$false;Timer=$null;ChangeQueue=[Collections.Generic.Queue[object]]::new();ChangeEvents=[Collections.Generic.Queue[object]]::new();ChangeSearch=$null;ChangeJob='';ChangeNext=[datetime]::MinValue;Stamps=@{};CacheDirty=$false;RestoreNotice=$null;CheckedAt=$null}
    # SE-13: in-page switch, shown only when an administrator enabled the background revalidation.
    $script:ListRevalidationPaused=$false
    $revalidate=Get-DomeniaControl 'ChkListRevalidation'
    if($revalidate -is [Windows.Controls.CheckBox]){
        $revalidate.IsChecked=$true
        $revalidate.Add_Checked({$script:ListRevalidationPaused=$false;try{Update-DomeniaListRevalidationUi}catch{}})
        $revalidate.Add_Unchecked({$script:ListRevalidationPaused=$true;try{Update-DomeniaListRevalidationUi}catch{}})
    }
    try{Update-DomeniaListRevalidationUi}catch{}
    foreach($control in @($script:Ctrl.Values)){if($control -is [Windows.Controls.DataGrid]){Register-DomeniaGridLayout $control}}
    $retry=Get-DomeniaControl 'BtnOuRestoreRetry';if($null -ne $retry){$retry.Add_Click({try{Invoke-DomeniaOuRestoreRetry}catch{Write-AppLog ('Relecture de lʼOU mémorisée : '+$_.Exception.Message) 'WARN'}})}
    $dismiss=Get-DomeniaControl 'BtnOuRestoreDismiss';if($null -ne $dismiss){$dismiss.Add_Click({Hide-DomeniaOuRestoreNotice;$tree=Get-DomeniaControl 'TvDirectory';if($null -ne $tree){[void]$tree.Focus()}})}
    $tree=Get-DomeniaControl 'TvDirectory'
    if($null -ne $tree){
        $tree.Add_SelectedItemChanged({if($null -ne $script:Continuity -and -not $script:Continuity.Restoring){$script:Continuity.Dirty=$true}})
        $tree.Add_PreviewMouseDown({Stop-DomeniaFavouriteTreeReveal;if($null -ne $script:Continuity){$script:Continuity.Restoring=$false;$script:Continuity.RestoreSearch=$null;$script:Continuity.Dirty=$true}})
        $tree.Add_PreviewKeyDown({Stop-DomeniaFavouriteTreeReveal;if($null -ne $script:Continuity){$script:Continuity.Restoring=$false;$script:Continuity.RestoreSearch=$null;$script:Continuity.Dirty=$true}})
        $tree.AddHandler([Windows.Controls.TreeViewItem]::ExpandedEvent,[Windows.RoutedEventHandler]{if($null -ne $script:Continuity -and -not $script:Continuity.Restoring){$script:Continuity.Dirty=$true}})
        $tree.AddHandler([Windows.Controls.TreeViewItem]::CollapsedEvent,[Windows.RoutedEventHandler]{if($null -ne $script:Continuity -and -not $script:Continuity.Restoring){$script:Continuity.Dirty=$true}})
    }
    # FI-05 / PF-06: protected heartbeat timer, owned and registered by the factory: 700 ms while a layout, a restore or
    # a revalidation is under way, every 2 s at rest.
    $script:Continuity.Timer=New-DomeniaTimer -Owner 'Timer:Continuity' -IntervalMs 700 -IdleIntervalMs 2000 -Busy {Test-DomeniaContinuityTickNeeded} -Tick {
            if($script:AsyncEngineClosing){return}
            if($script:Continuity.RestoreToken -cne ([string]$script:SessionEpoch+'|'+(Get-DomeniaTreeContextKey))){Start-DomeniaTreeBookmarkRestore}
            Invoke-DomeniaTreeBookmarkRestore
            # The home overview waited for the remembered OU: computed once the restore ended, found or not.
            if([bool]$script:FleetAwaitingRestore -and -not ([bool]$script:Continuity.Restoring -and -not [bool]$script:Continuity.SelectedRestored)){$script:FleetAwaitingRestore=$false;try{Request-DomeniaFleetRefresh}catch{}}
            Invoke-DomeniaRestoredOuSearch
            if($script:Continuity.Dirty -and -not $script:Continuity.Restoring){Save-DomeniaTreeBookmark;$script:Continuity.Dirty=$false}
            if($script:Continuity.ChangeJob -and -not $script:AsyncJobs.Contains($script:Continuity.ChangeJob)){
                $pending=@($script:DetachedReadJobs|Where-Object{$_.Id -eq $script:Continuity.ChangeJob});if(-not $pending.Count){$script:Continuity.ChangeJob=''}
            }
            Invoke-DomeniaObjectChanges
    };$script:Continuity.Timer.Start()
    $script:Window.Add_ContentRendered({Start-DomeniaTreeBookmarkRestore})
    $script:Window.Add_Closed({
        Stop-DomeniaFavouriteTreeReveal
        if($null -ne $script:Continuity){$script:Continuity.Timer.Stop();foreach($g in $script:Continuity.Grids.Values){Save-DomeniaGridLayout $g.Grid};Save-DomeniaTreeBookmark;Save-DomeniaSettings -Immediate}
    })
}
