# Single queue for legacy index/link deltas; Live cache writes share the same worker admission gate.
$script:Persistence=$null
$script:LinkBaseline=@{}
function Initialize-DomeniaPersistence {
    if($null -ne $script:Persistence){return}
    # D028: InFlight counts the items of the batch being written (they have left Pending); Conflicts holds the link keys
    # refused by the writer because another console changed them, until the associations are reloaded.
    # D113: LegacyImportJob marks an import that has left Pending but is not confirmed yet.
    # MO-03: Pending is an ordered dictionary (first queued, first written); LastSavedAt feeds the Santé zone (UX-32).
    $script:Persistence=[pscustomobject]@{Pending=([ordered]@{});Job='';Next=[datetime]::MinValue;Fault='';Failures=0;LinkBusy=$false;Timer=$null;LinkRequestTimer=$null;LinkPersistenceMore=$false;InFlight=0;InFlightItems=@();Conflicts=@{};LegacyImportJob='';LastSavedAt=$null}
    # MO-03 / FI-05: protected heartbeat timer, armed when an item is queued (Request-DomeniaStorageWork) and stopped
    # when nothing is left to write: a batch groups what arrives within about one second. It also runs minimized.
    $script:Persistence.Timer=New-DomeniaTimer -Owner 'Timer:Storage' -IntervalMs 1000 -RunWhenHidden -Tick {
        param($sender,$eventArgs)
        Start-DomeniaStorageWork
        if(-not (Test-DomeniaStorageWorkPending)){$sender.Stop()}
    }
    $script:Window.Add_Closed({
        if($null -ne $script:Persistence){
            try{$script:Persistence.Timer.Stop()}catch{}
            if($null -ne $script:Persistence.LinkRequestTimer){try{$script:Persistence.LinkRequestTimer.Stop()}catch{}}
        }
    })
}
function Add-DomeniaIndexPersistence {
    param($Row)
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    if(-not $script:DatabaseScopedPath){return $false}
    $key='Index|'+[string]$script:DatabaseScopedPath+'|'+[string]$Row.Guid+'|'+[string]$Row.DN
    if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.Contains($key)){Set-Status 'Cache en attente saturé. Les données restent visibles mais non enregistrées.' 'WARN';return $false}
    $script:Persistence.Pending[$key]=[pscustomobject]@{QueueKey=$key;Kind='Index';Path=[string]$script:DatabaseScopedPath;Row=$Row;Server=[string]$script:Conn.Server;At=[datetime]::UtcNow.ToString('o');Epoch=[long]$script:SessionEpoch}
    Request-DomeniaStorageWork
    return $true
}
function Request-DomeniaStorageWork {
    # Canonical batches already have a bounded collection window. Do not add a one-second delay per receipt.
    # The same queue/timer remains the sole writer; legacy deltas retain their debounce and failure backoff.
    if($null -eq $script:Persistence -or $null -eq $script:Persistence.Timer){return}
    $interval=1000
    # Under a maintenance lock the queue only waits (Start-DomeniaStorageWork): the idle poll resumes it within a
    # second of the release, without spinning the Dispatcher every 20 ms for the whole lock.
    $locked=(($null -ne $script:StorageMaintenance) -and [bool]$script:StorageMaintenance.Locked)
    if((-not $locked) -and (-not $script:Persistence.Job) -and ([int]$script:Persistence.Failures -eq 0)){
        foreach($item in $script:Persistence.Pending.Values){if([string]$item.Kind -eq 'StoreBatch'){$interval=20};break}
    }
    try{
        if([int]$script:Persistence.Timer.IntervalMs -ne $interval){Set-DomeniaTimerInterval -Timer $script:Persistence.Timer -Interval ([timespan]::FromMilliseconds($interval))}
        if(-not [bool]$script:Persistence.Timer.IsEnabled){$script:Persistence.Timer.Start()}
        if($interval -eq 20){Invoke-DomeniaTimerSoon -Owner 'Timer:Storage'}
    }catch{}
}
function Test-DomeniaStorageWorkPending {
    # MO-03: the save timer keeps running while an item waits or a batch is being written, unless the writer is
    # suspended after three failures (Reprendre les sauvegardes re-arms it).
    $p=$script:Persistence
    if($null -eq $p){return $false}
    if($p.Job -or $p.LegacyImportJob){return $true}
    if($p.Pending.Count -eq 0){return $false}
    if([int]$p.Failures -ge 3){foreach($v in @($p.Pending.Values)){if($v.Kind -eq 'LegacyImport'){return $true}};return $false}
    return $true
}
function Reset-DomeniaLinkBaseline {
    $script:LinkBaseline=@{}
    # D028: the associations were reloaded from disk (Complete-DomeniaUserMachineLinksUi, at startup or through Comptes >
    # Changer de compte): the conflict state ends here.
    if($null -ne $script:Persistence -and $null -ne $script:Persistence.PSObject.Properties['Conflicts']){$script:Persistence.Conflicts=@{}}
    foreach($l in @($script:UserMachineLinks)){$key=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant();if($key){$script:LinkBaseline[$key]=ConvertTo-DomeniaLinkRecord $l}}
}
function Queue-DomeniaLinkChanges {
    param([switch]$Quiet,[int]$MaxItems=0)
    if($MaxItems -lt 0){$MaxItems=0}
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    $script:Persistence.LinkPersistenceMore=$false
    # FI-19: while the associations of this session are read from the base (Request-DomeniaUserMachineLinks), the
    # reference of the writer is not known yet. The change stays in memory and the end of that reading asks for its save.
    if(($null -ne $script:LinkLoad) -and ([bool]$script:LinkLoad.Pending) -and ([long]$script:LinkLoad.Epoch -eq [long]$script:SessionEpoch)){
        $script:LinkLoad.Deferred=$true
        $script:UserMachineLinks=[object[]]@(ConvertTo-DomeniaCanonicalLinks -Links $script:UserMachineLinks);Rebuild-UserMachineLinkIndex;Refresh-LinkGrid;Refresh-AssociationContext -SkipResultRefresh
        if(-not $Quiet){Set-Status 'Associations en cours de lecture dans la base locale : la modification reste en mémoire et sera enregistrée à la fin de la lecture.'}
        return $true
    }
    if($script:Persistence.LinkBusy){
        if(-not $Quiet){Set-Status 'Enregistrement des liens encore actif. Attendez son résultat avant une nouvelle modification.' 'WARN'}
        return $false
    }
    $valid=@(ConvertTo-DomeniaCanonicalLinks -Links $script:UserMachineLinks);$current=@{};$items=[Collections.Generic.List[object]]::new()
    # D028: the quiet (background) path never resubmits a key refused as modified elsewhere; the explicit path still
    # submits it and the writer warns again. Reset-DomeniaLinkBaseline (reload) ends the conflict state.
    $conflicted=$null;if($Quiet -and $null -ne $script:Persistence.PSObject.Properties['Conflicts']){$conflicted=$script:Persistence.Conflicts}
    foreach($l in $valid){$key=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant();if($key){$current[$key]=ConvertTo-DomeniaLinkRecord $l}}
    foreach($key in @(@($script:LinkBaseline.Keys)+@($current.Keys)|Select-Object -Unique)){
        if($null -ne $conflicted -and $conflicted.ContainsKey($key)){continue}
        $before=$script:LinkBaseline[$key];$after=$current[$key]
        $old=Get-DomeniaLinkFingerprint $before;$new=Get-DomeniaLinkFingerprint $after
        if($old -ceq $new){continue}
        $items.Add([pscustomobject]@{QueueKey=('Link|'+[string]$script:DatabaseScopedPath+'|'+$key);Kind='Link';Key=$key;Path=[string]$script:DatabaseScopedPath;Expected=$old;Row=$after;Remove=($null -eq $after);Epoch=[long]$script:SessionEpoch})
    }
    # A quiet request without any change leaves the grids and the index alone.
    if($Quiet -and ($items.Count -eq 0)){return $true}
    # Points 32 and 34: under a maintenance lock an association would wait for a base that the switch leaves. It is
    # refused here instead: callers undo the change in memory and say so; the quiet path retries after the lock.
    $refusal='';if($items.Count){$refusal=Get-DomeniaStorageInputRefusal -Maintenance $script:StorageMaintenance}
    if($refusal){
        if(-not $Quiet){Set-Status $refusal 'WARN'}
        return $false
    }
    $queuedCount=$items.Count
    if($MaxItems -gt 0){$queuedCount=[Math]::Min($MaxItems,$items.Count)}
    if(((($MaxItems -eq 0) -and ($items.Count -gt 64)) -or (($script:Persistence.Pending.Count + $queuedCount) -gt 256))){
        if(-not $Quiet){Set-Status 'Trop de modifications de liens pour ce lot (64 maximum). Aucune sauvegarde globale effectuee.' 'WARN'}
        return $false
    }
    $queued=0
    foreach($i in $items){
        if(($MaxItems -gt 0) -and ($queued -ge $MaxItems)){break}
        $script:Persistence.Pending[$i.QueueKey]=$i
        $queued++
    }
    if(($MaxItems -gt 0) -and ($items.Count -gt $queued)){$script:Persistence.LinkPersistenceMore=$true}
    $script:Persistence.LinkBusy=($queued -gt 0)
    $script:UserMachineLinks=[object[]]$valid;Rebuild-UserMachineLinkIndex;Refresh-LinkGrid;Refresh-AssociationContext -SkipResultRefresh
    if((-not $Quiet) -and $queued){Set-Status ($queued.ToString()+' lien(s) en mémoire, enregistrement en arrière-plan en attente.')}
    if($queued){Request-DomeniaStorageWork}
    return $true
}
function Request-DomeniaLinkPersistence {
    # D028: coalesces link persistence requested by background observations; the single writer runs after a quiet
    # period, in batches of 64 at most. One owned timer, created once and reused.
    if ($null -eq $script:Persistence) { Initialize-DomeniaPersistence }
    $timer = $script:Persistence.LinkRequestTimer
    if ($null -eq $timer) {
        # FI-05: protected heartbeat timer, owned and registered by the factory; it also runs minimized.
        $timer = New-DomeniaTimer -Owner 'Timer:LinkPersistence' -IntervalMs 1500 -RunWhenHidden -Tick {
            param($sender,$eventArgs)
            $sender.Stop()
            if ($null -eq $script:Persistence) { return }
            # Busy writer or refused batch: try again later, silently. A partial batch re-arms for the rest.
            if ($script:Persistence.LinkBusy) { $sender.Start(); return }
            $ok = Queue-DomeniaLinkChanges -Quiet -MaxItems 64
            if ((-not $ok) -or [bool]$script:Persistence.LinkPersistenceMore) { $sender.Start() }
        }
        $script:Persistence.LinkRequestTimer = $timer
    }
    if (-not $timer.IsEnabled) { $timer.Start() }
}

function Start-DomeniaStorageWork {
    # Same liveness rule as the receipts: a save that left the engine without a callback frees the slot.
    # D113: keep the lock while a detached worker still runs; a lost completion never replays an import.
    if($null -ne $script:Persistence -and $script:Persistence.Job -and $null -ne $script:AsyncJobs -and -not $script:AsyncJobs.Contains([string]$script:Persistence.Job)){
        foreach($detached in @($script:DetachedReadJobs)){if($null -ne $detached -and [string]$detached.Id -eq [string]$script:Persistence.Job){return}}
        if(-not $script:Persistence.LegacyImportJob){
            $lost=@(Get-DomeniaMemberValue $script:Persistence 'InFlightItems')|Where-Object{$null -ne $_}
            if(@($lost).Count){
                # Unknown completion is not proof of a commit. Keep the exact lot and require explicit recovery.
                $script:Persistence.Failures=[Math]::Max(2,[int]$script:Persistence.Failures)
                Fail-DomeniaStorageWork 'Résultat de sauvegarde non reçu ; vérifiez la base puis reprenez les sauvegardes.' ([pscustomobject]@{Items=@($lost)})
                return
            }
        }
        if($script:Persistence.LegacyImportJob){
            $script:Persistence.LegacyImportJob=''
            Set-Status 'Résultat reprise des anciennes données non reçu. Vérifiez le stockage puis refaites la simulation avant toute nouvelle demande.' 'WARN'
            Add-DomeniaUiLog -Area 'Import' -Text 'Resultat reprise des anciennes donnees non recu ; aucun rejeu automatique.' -Level 'WARN'
        }
        $script:Persistence.Job=''
        $script:Persistence.InFlight=0
        $script:Persistence|Add-Member -NotePropertyName InFlightItems -NotePropertyValue @() -Force
        $hasLinkWork=$false
        if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
        foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
        $script:Persistence.LinkBusy=$hasLinkWork
    }
    if($null -eq $script:Persistence -or $script:AsyncEngineClosing -or $script:Persistence.Job -or -not $script:Persistence.Pending.Count){return}
    # Points 32 and 34: while a maintenance step holds the base (copy, switch to finish, unreadable base) the queue waits
    # untouched: no refused admission, no fault, no dropped import. The switch decides what happens to it. The timer
    # goes back to its idle poll, which resumes the queue within a second of the release.
    if(($null -ne $script:StorageMaintenance) -and [bool]$script:StorageMaintenance.Locked){
        if(($null -ne $script:Persistence.Timer) -and ([int]$script:Persistence.Timer.IntervalMs -ne 1000)){try{Set-DomeniaTimerInterval -Timer $script:Persistence.Timer -Interval ([timespan]::FromMilliseconds(1000))}catch{}}
        return
    }
    $import=@($script:Persistence.Pending.Values|Where-Object{$_.Kind -eq 'LegacyImport'}|Select-Object -First 1)
    $canStartImport=($import.Count -gt 0 -and -not $script:Persistence.LegacyImportJob)
    if(-not $canStartImport){
        if($script:Persistence.Failures -ge 3 -or [datetime]::UtcNow -lt $script:Persistence.Next){return}
    }
    # MO-03: one pass over the tasks (no pipeline per tick); the threshold follows the engine limits: the places left
    # to background work (MaxThreads minus the places kept for explicit actions, 4 by default).
    $storageBusy=@('LocalStore','LiveCache','IndexBuild','LegacyMigration','StoragePurge')
    foreach($job in @($script:AsyncJobs.Values)+@($script:DetachedReadJobs)){if($null -ne $job -and [string]$job.OperationId -in $storageBusy){return}}
    $threshold=4
    try{$limits=Get-DomeniaEngineLimits;$threshold=[Math]::Max(1,[int]$limits.MaxConcurrent-[int]$limits.ReservedForeground)}catch{$threshold=4}
    if(@($script:AsyncJobs.Keys).Count -ge $threshold){return}
    if($canStartImport){
        $item=$import[0]
        $path=[string]$item.Path
        if(-not $path){
            [void]$script:Persistence.Pending.Remove($item.QueueKey)
            $script:Persistence.Fault='Base du contexte non disponible.'
            Set-Status 'Reprise des anciennes données impossible : base du contexte non disponible.' 'ERROR'
            Add-DomeniaUiLog -Area 'Import' -Text 'Reprise des anciennes donnees impossible : base du contexte non disponible.' -Level 'ERROR'
            $hasLinkWork=$false
            if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
            foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
            $script:Persistence.LinkBusy=$hasLinkWork
            return
        }
        $state=[pscustomobject]@{Items=@($item);Epoch=[long]$script:SessionEpoch}
        try {
            $id=Start-UiTask -Name 'Reprise des anciennes donnees' -OperationId 'LocalStore' -Code (Get-DomeniaStorageWorkerCode) -Payload ([pscustomobject]@{Path=$path;Items=@($item)}) -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageWork' -ErrorHandler 'Fail-DomeniaStorageWork' -NonCancellable -TimeoutSeconds 600 -TaskClass 'Explicit'
            if([string]::IsNullOrWhiteSpace([string]$id)){throw 'Admission import non confirmee.'}
            $script:Persistence.Job=$id
            $script:Persistence.LegacyImportJob=$id
            [void]$script:Persistence.Pending.Remove($item.QueueKey)
            $script:Persistence.InFlight=1
            $script:Persistence|Add-Member -NotePropertyName InFlightItems -NotePropertyValue @($item) -Force
        } catch {
            [void]$script:Persistence.Pending.Remove($item.QueueKey)
            $script:Persistence.LegacyImportJob=''
            $script:Persistence.Fault=$_.Exception.Message
            Set-Status ('Reprise des anciennes données impossible au départ : '+$_.Exception.Message) 'ERROR'
            Add-DomeniaUiLog -Area 'Import' -Text ('Depart reprise des anciennes donnees impossible : '+$_.Exception.Message) -Level 'ERROR'
            $hasLinkWork=$false
            if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
            foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
            $script:Persistence.LinkBusy=$hasLinkWork
        }
        return
    }
    $items=@($script:Persistence.Pending.Values|Where-Object{$_.Kind -ne 'LegacyImport'}|Select-Object -First 1)
    if(-not $items.Count){return}
    $path=[string]$items[0].Path
    $items=@($script:Persistence.Pending.Values|Where-Object{$_.Path -ceq $path -and $_.Kind -ne 'LegacyImport'}|Select-Object -First 64)
    if(-not $path){$script:Persistence.Fault='Base du contexte non disponible.';$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(10);return}
    # A bulk update owns one transaction and one worker; do not combine dozens of large snapshots.
    # Point 30: a directory snapshot copies a whole scope; it runs alone too, so that it never holds the small saves.
    $soloKinds=@('IndexBulk','StoreBatch','DirectorySnapshot')
    $bulk=@($items|Where-Object{$_.Kind -in $soloKinds}|Select-Object -First 1)
    if($bulk.Count){
        if($items[0].Kind -in $soloKinds){$items=@($bulk[0])}
        else{
            # Preserve queue order: older individual rows must commit before a newer complete rebuild.
            $prefix=[Collections.Generic.List[object]]::new()
            foreach($item in $items){if($item.Kind -in $soloKinds){break};$prefix.Add($item)}
            $items=$prefix.ToArray();$bulk=@()
        }
    }
    $storageTimeout=120
    if($bulk.Count -and $bulk[0].Kind -eq 'IndexBulk'){$storageTimeout=[Math]::Min(3600,[Math]::Max(120,60+[int]([long]$bulk[0].Row.RowCount/500)))}
    # A snapshot copies at most 300 000 rows in SQLite, then hashes them in one streamed read: its time follows the size
    # of the base when it was asked (ObjectEstimate), with the same bounds as an index batch.
    if($bulk.Count -and $bulk[0].Kind -eq 'DirectorySnapshot'){$estimate=300000L;try{$estimate=[long](Get-DomeniaMember $bulk[0].Row 'ObjectEstimate' 300000)}catch{$estimate=300000L};$storageTimeout=[Math]::Min(1800,[Math]::Max(120,60+[int]([Math]::Min(300000L,[Math]::Max(0L,$estimate))/250)))}
    if($bulk.Count -and $bulk[0].Kind -eq 'IndexBulk' -and $null -ne $script:IndexProgressTimer -and $null -ne $bulk[0].Row.PSObject.Properties['Transfer'] -and $null -ne $bulk[0].Row.Transfer -and $null -ne $bulk[0].Row.Transfer.PSObject.Properties['Progress'] -and [long]$bulk[0].Epoch -eq [long]$script:SessionEpoch){$script:IndexTransferProgress=$bulk[0].Row.Transfer.Progress;$script:IndexProgressTimer.Start()}
    $state=[pscustomobject]@{Items=$items;Epoch=[long]$script:SessionEpoch}
    try {
        $script:Persistence.Job=Start-UiTask -Name 'Enregistrement cache et liens' -OperationId 'LocalStore' -Code (Get-DomeniaStorageWorkerCode) -Payload ([pscustomobject]@{Path=$path;Items=$items}) -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageWork' -ErrorHandler 'Fail-DomeniaStorageWork' -NonCancellable -TimeoutSeconds $storageTimeout
        if([string]::IsNullOrWhiteSpace([string]$script:Persistence.Job)){throw 'Admission du stockage non confirmee : lot conserve en attente.'}
        # Return to the idle poll interval while the worker owns the queue; its receipt re-arms the next batch promptly.
        if($null -ne $script:Persistence.Timer){try{Set-DomeniaTimerInterval -Timer $script:Persistence.Timer -Interval ([timespan]::FromMilliseconds(1000))}catch{}}
        foreach($i in $items){[void]$script:Persistence.Pending.Remove($i.QueueKey)}
        # D028: the batch left Pending but is not on disk yet; the label keeps counting it until the callback.
        $script:Persistence.InFlight=@($items).Count
        $script:Persistence|Add-Member -NotePropertyName InFlightItems -NotePropertyValue @($items) -Force
    }catch{$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(5);$script:Persistence.Fault=$_.Exception.Message}
}
function Complete-DomeniaStorageWork {
    param($Result,$State)
    if($null -eq $script:Persistence){return}
    $script:Persistence.Job='';$script:Persistence.InFlight=0
    $script:Persistence|Add-Member -NotePropertyName InFlightItems -NotePropertyValue @() -Force
    $storeItems=@($State.Items|Where-Object{$_.Kind -eq 'StoreBatch'})
    if($storeItems.Count){
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Saved','DataSource','BatchId')
        $item=$storeItems[0]
        if($null -eq $r -or -not [bool]$r.Saved -or [string]$r.DataSource -cne 'SQLite' -or [string]$r.BatchId -cne [string]$item.BatchId -or [string]$r.StoreId -cne [string]$item.Context.StoreId){Fail-DomeniaStorageWork 'Recu de stockage absent ou incoherent.' $State;return}
        $script:Persistence.Fault='';$script:Persistence.Failures=0;$script:Persistence.LastSavedAt=[datetime]::Parse([string]$r.CommittedAtUtc,[Globalization.CultureInfo]::InvariantCulture)
        Update-DomeniaStorageSpace -FreeBytes ([long](Get-DomeniaMember $r 'DiskFreeBytes' -1)) -MeasuredUtc ([string](Get-DomeniaMember $r 'DiskMeasuredUtc' '')) -Path ([string]$item.Path)
        # One invalidation per committed batch, only for the still-active database/session.
        # No rows are published here; dashboards re-read a transactional SQLite snapshot.
        if([long]$item.Epoch -eq [long]$script:SessionEpoch -and [string]$item.Path -ceq [string]$script:DatabaseScopedPath){
            $script:StoreSnapshotRevision=[Math]::Max([long]$script:StoreSnapshotRevision,[long]$r.SnapshotRevision)
            if(@($r.Rows).Count -or @($r.Observations).Count -or @($r.Details).Count){$script:FleetStale=$true}
        }
        # Caller owns generation/selection fencing. Even a stale request persists to its captured database.
        try { & ([string]$item.SuccessHandler) -Result $r -State $item.CallbackState }
        catch { Write-AppLog ('Donnees enregistrees, affichage differe : '+$_.Exception.Message) 'ERROR' }
        Request-DomeniaStorageWork
        return
    }
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Saved','Conflicts')
    if($null -eq $r -or -not $r.Saved){Fail-DomeniaStorageWork 'Resultat stockage non confirme.' $State;return}
    $items=@();if($null -ne $State){$items=@($State.Items)}
    foreach($saved in $items){
      if($saved.Kind -ne 'IndexBulk' -or $null -eq $saved.Row.PSObject.Properties['Transfer'] -or $null -eq $saved.Row.Transfer){continue}
      try{
        $folder=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$saved.Path))) 'index-spool'))
        $file=[IO.Path]::GetFullPath([string]$saved.Row.Transfer.Path)
        if([IO.Path]::GetDirectoryName($file) -ceq $folder -and [IO.Path]::GetFileName($file) -match '^[a-f0-9]{32}\.jsonl$'){[IO.File]::Delete($file)}
      }catch{Add-DomeniaUiLog -Area 'Index' -Level 'WARN' -Text ('Lot enregistre, nettoyage temporaire differe : '+$_.Exception.Message)}
    }

    $isImport=@($items|Where-Object{$_.Kind -eq 'LegacyImport'}).Count -gt 0
    if(-not $isImport){$script:Persistence.Fault='';$script:Persistence.Failures=0;$script:Persistence.LastSavedAt=Get-Date}
    if($items.Count){Update-DomeniaStorageSpace -FreeBytes ([long](Get-DomeniaMember $r 'DiskFreeBytes' -1)) -MeasuredUtc ([string](Get-DomeniaMember $r 'DiskMeasuredUtc' '')) -Path ([string]$items[0].Path)}
    if($isImport){$script:Persistence.LegacyImportJob=''}
    foreach($i in $items){
        if($i.Kind -eq 'LegacyImport'){
            if($i.Epoch -ne [long]$script:SessionEpoch -or [string]$i.Path -cne [string]$script:DatabaseScopedPath){
                Add-DomeniaUiLog -Area 'Import' -Text 'Reprise des anciennes donnees ignore : epoch ou chemin obsolette.'
                continue
            }
            if([bool]$r.Already){
                Set-Status 'Reprise des anciennes données déjà appliquée : rien à reprendre.'
                Add-DomeniaUiLog -Area 'Import' -Text 'Reprise des anciennes donnees deja applique (marqueur identique).'
                continue
            }
            $links=@()
            if($null -ne $r.PSObject.Properties['ImportedLinks']){
                $links=@($r.ImportedLinks)
                if($links.Count -eq 1 -and $null -eq $links[0]){$links=@()}
            }
            $conflicts=@()
            if($null -ne $r.PSObject.Properties['Conflicts']){
                $conflicts=@($r.Conflicts)
                if($conflicts.Count -eq 1 -and $null -eq $conflicts[0]){$conflicts=@()}
            }
            if($links.Count -gt 0){
                $existingKeys=@{}
                $merged=[Collections.Generic.List[object]]::new()
                foreach($currentLink in @($script:UserMachineLinks)){if($null -ne $currentLink){$merged.Add($currentLink)}}
                foreach($l in @($script:UserMachineLinks)){$k=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant();if($k){$existingKeys[$k]=$true}}
                foreach($l in $links){
                    $k=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant()
                    if(-not $k){continue}
                    $rec=ConvertTo-DomeniaLinkRecord $l
                    if($existingKeys.ContainsKey($k)){
                        $script:LinkBaseline[$k]=$rec
                        continue
                    }
                    $script:LinkBaseline[$k]=$rec
                    $merged.Add($l)
                    $existingKeys[$k]=$true
                }
                $script:UserMachineLinks=$merged.ToArray()
            }
            Rebuild-UserMachineLinkIndex
            Refresh-LinkGrid
            Refresh-AssociationContext -SkipResultRefresh
            try{Request-DomeniaIndexMetadata}catch{}
            $summary='Reprise des anciennes donnees applique : '+[int]$r.Imported.Objects+' objet(s), '+[int]$r.Imported.Park+' poste(s), '+[int]$r.Imported.UserScans+' recherche(s), '+[int]$r.Imported.Secrets+' metadonnee(s), '+$links.Count+' lien(s), '+$conflicts.Count+' association(s) existante(s) conservee(s).'
            Set-Status $summary $(if($conflicts.Count){'WARN'}else{'INFO'})
            Add-DomeniaUiLog -Area 'Import' -Text $summary
            continue
        }
        if($i.Kind -ne 'Link'){continue}
        if($i.Epoch -ne [long]$script:SessionEpoch){continue}
        if(@($r.Conflicts) -contains $i.Key){$script:Persistence.Conflicts[[string]$i.Key]=$true;Set-Status ('Association modifiée ailleurs : '+$i.Key+'. Votre version nʼa pas écrasé celle du disque. Rechargez les associations : Comptes > Changer de compte, ou redémarrage.') 'WARN';continue}
        [void]$script:Persistence.Conflicts.Remove([string]$i.Key)
        if($i.Remove){[void]$script:LinkBaseline.Remove($i.Key)}else{$script:LinkBaseline[$i.Key]=$i.Row}
    }
    # The home overview reads what was just committed (decision David 2026-10-08): a saved index update is computed
    # again; single rows and observations only mark it out of date (the end of a run asks for the calculation).
    # The BitLocker presence of an OU (bulk of secret metadata) is shown as soon as it is saved. A daily snapshot of
    # the overview never asks for a new calculation.
    if(@($items|Where-Object{($_.Kind -eq 'IndexBulk') -or (($_.Kind -eq 'SecretMeta') -and ($null -ne $_.Row.PSObject.Properties['Rows']))}).Count){
      # Les compteurs et l'âge « base à jour » se lisent dans IndexInfo, chargé avant cette écriture : sans relecture
      # ici la page reste figée sur la passe précédente, des jours après une mise à jour réussie.
      $indexItems=@($items|Where-Object{$_.Kind -eq 'IndexBulk' -and $_.Epoch -eq [long]$script:SessionEpoch -and [string]$_.Path -ceq [string]$script:DatabaseScopedPath})
      if($indexItems.Count){
        foreach($saved in $indexItems){
          $complete=($null -eq $saved.Row.PSObject.Properties['Complete'] -or [bool]$saved.Row.Complete)
          $scope=if($null -ne $saved.Row.PSObject.Properties['SyncScope']){[string]$saved.Row.SyncScope}else{'directory'}
          if($complete -and $scope -eq 'directory'){Set-DomeniaIndexPartial -Clear}
          if($null -ne $saved.Row.PSObject.Properties['RefreshOperationId'] -and [string]$saved.Row.RefreshOperationId){Complete-DomeniaOuRefreshCommit -Item $saved}
        }
        # FI-19: read again by the LocalIndexRead worker; Complete-DomeniaIndexMetadataUi updates the page.
        try{Request-DomeniaIndexMetadata}catch{}
        # PF-07: the storage time of the lot measured by the worker (prepared statements) is kept beside the IndexBuild
        # samples of the AD read, so that Statistiques des opérations shows the cost of the write per object.
        $writtenRows=[long](Get-DomeniaMember $r 'IndexRows' 0)
        if($writtenRows -gt 0){try{Register-DomeniaOperationSample -Operation 'IndexStore' -Mode 'SQLite prepare' -ItemCount ([int][Math]::Min([long][int]::MaxValue,$writtenRows)) -DurationMs ([long](Get-DomeniaMember $r 'IndexWriteMs' 0)) -SuccessCount ([int][Math]::Min([long][int]::MaxValue,$writtenRows))}catch{}}
        $walkSaved=@($indexItems|Where-Object{$null -ne $_.Row.PSObject.Properties['WalkStep'] -and [bool]$_.Row.WalkStep})
        if($walkSaved.Count -and $null -ne $script:IndexWalk){
          $script:IndexWalk.Saved += $walkSaved.Count
          Start-DomeniaIndexWalkStep
        }elseif($null -eq $script:IndexWalk){
          $partial=@($indexItems|Where-Object{$null -ne $_.Row.PSObject.Properties['Complete'] -and -not [bool]$_.Row.Complete}).Count -gt 0
          $savedCount=0;foreach($saved in $indexItems){$savedCount+=$(if($null -ne $saved.Row.PSObject.Properties['RowCount']){[long]$saved.Row.RowCount}else{@($saved.Row.Rows).Count})}
          $summary=('{0} fiche(s) enregistrée(s) dans la base locale.' -f $savedCount)
          if($partial){$summary+=' Lecture partielle : le dernier repère complet est conservé.'}else{$summary+=' La fraîcheur du périmètre lu est actualisée.'}
          [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text $summary)
          Set-DomeniaIndexProgress -Mode $(if($partial){'Error'}else{'Complete'}) -Message $summary
        }
      }
      try{Request-DomeniaFleetRefresh -Force}catch{}}
    elseif(@($items|Where-Object{$_.Kind -in @('Index','ParkSession','SecretMeta')}).Count){$script:FleetStale=$true}
    $hasLinkWork=$false
    if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
    foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
    $script:Persistence.LinkBusy=$hasLinkWork
    if(-not $isImport){Add-DomeniaUiLog -Area 'Cache' -Text ('Lot enregistre : '+[int]$r.Count+' element(s), conflits : '+@($r.Conflicts).Count)}
    # Points 24 and 30: verification results, snapshots and index updates refresh the Contrôles tab from the base.
    if(${function:Complete-DomeniaDirectorySyncStorage}){try{Complete-DomeniaDirectorySyncStorage -Items $items -Saved $true}catch{Add-DomeniaUiLog -Area 'Index' -Level 'WARN' -Text ('Contrôles de la base non actualisés : '+$_.Exception.Message)}}
}
function Fail-DomeniaStorageWork {
    param($Message,$State)
    if($null -eq $script:Persistence){return}
    $script:Persistence|Add-Member -NotePropertyName InFlightItems -NotePropertyValue @() -Force
    $items=@();if($null -ne $State){$items=@($State.Items)}
    foreach($storeItem in @($items|Where-Object{$_.Kind -eq 'StoreBatch'})){
        try { & ([string]$storeItem.ErrorHandler) -Message ([string]$Message) -State $storeItem.CallbackState } catch { Write-AppLog ('Notification stockage : '+$_.Exception.Message) 'WARN' }
    }
    if(${function:Complete-DomeniaDirectorySyncStorage}){try{Complete-DomeniaDirectorySyncStorage -Items $items -Saved $false -Message ([string]$Message)}catch{Add-DomeniaUiLog -Area 'Index' -Level 'WARN' -Text ('Contrôles de la base non actualisés : '+$_.Exception.Message)}}
    # An automatic save retry may preserve the base, but must never launch a remote follow-up after a failed receipt.
    foreach($item in $items){if($item.Kind -eq 'IndexBulk' -and $null -ne $item.Row -and $null -ne $item.Row.PSObject.Properties['RefreshOperationId'] -and [string]$item.Row.RefreshOperationId){Fail-DomeniaOuRefresh -OperationId ([string]$item.Row.RefreshOperationId) -Message ('Écriture locale non confirmée : '+[string]$Message)}}
    $isImport=@($items|Where-Object{$_.Kind -eq 'LegacyImport'}).Count -gt 0
    if($isImport){
        $script:Persistence.Job='';$script:Persistence.InFlight=0
        $script:Persistence.LegacyImportJob=''
        foreach($i in $items){if($script:Persistence.Pending.Contains($i.QueueKey)){[void]$script:Persistence.Pending.Remove($i.QueueKey)}}
        $script:Persistence.Fault=[string]$Message
        Set-Status ('Reprise des anciennes données échouée, sans rejeu automatique. Refaites la simulation avant une nouvelle demande : '+[string]$Message) 'ERROR'
        Add-DomeniaUiLog -Area 'Import' -Text ('Reprise des anciennes donnees echoue : '+[string]$Message) -Level 'ERROR'
        $hasLinkWork=$false
        if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
        foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
        $script:Persistence.LinkBusy=$hasLinkWork
        return
    }
    $diskFull=([string]$Message -match 'StorageInsufficientSpace|SQLite (?:code|step code) 13(?:\D|$)')
    # Point 30: a snapshot is a derived copy of the local base, taken on request. A failed one is reported (above) and
    # dropped: it is never retried in a loop that would suspend the other local saves. The operator can take it again.
    if((-not $diskFull) -and (@($items).Count -gt 0) -and (@($items|Where-Object{$_.Kind -ne 'DirectorySnapshot'}).Count -eq 0)){
        $script:Persistence.Job='';$script:Persistence.InFlight=0;$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(5)
        Add-DomeniaUiLog -Area 'Index' -Level 'WARN' -Text ('Relevé non enregistré, non relancé automatiquement : '+[string]$Message)
        Request-DomeniaStorageWork
        return
    }
    $script:Persistence.Failures++;$script:Persistence.Job='';$script:Persistence.InFlight=0;$script:Persistence.Fault=[string]$Message;$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(15)
    if($diskFull){$script:Persistence.Failures=[Math]::Max(3,[int]$script:Persistence.Failures)}
    # Retry older batches first; appending them could replay an old full rebuild after a newer OU update.
    $retry=[ordered]@{}
    foreach($i in $items){if(-not $script:Persistence.Pending.Contains($i.QueueKey)){$retry[$i.QueueKey]=$i}}
    foreach($entry in $script:Persistence.Pending.GetEnumerator()){$retry[$entry.Key]=$entry.Value}
    $script:Persistence.Pending=$retry
    if(@($items|Where-Object{$_.Kind -eq 'IndexBulk'}).Count){Set-DomeniaIndexProgress -Mode Error -Message ('Enregistrement non confirmé : '+[string]$Message+'. Le lot reste en attente.')}
    Request-DomeniaStorageWork
    if($diskFull){
        # Point 35: the refusal carries the measured free space; the tab shows it with what stays only in memory.
        if(([string]$Message -match 'espace libre (\d+) octets') -and $items.Count){Update-DomeniaStorageSpace -FreeBytes ([long]$matches[1]) -Path ([string]$items[0].Path)}else{Update-DomeniaStorageSpaceUi}
        if($null -ne $script:IndexWalk){Complete-DomeniaIndexWalkUi -Aborted -Detail 'Stockage suspendu : espace disque insuffisant. Les lots non enregistres sont conserves en attente.'}
        [void](Show-DomeniaRouteNotice -Kind Warning -Text ('Stockage suspendu : espace disque insuffisant. '+(Format-DomeniaStorageUnsaved (Get-DomeniaPersistenceState))+' Libérez de la place, puis reprenez les sauvegardes.') -RouteText 'Reprendre les sauvegardes' -Route 'StorageResume' -Key 'storage-suspended');return
    }
    if($script:Persistence.Failures -ge 3){
        if($null -ne $script:IndexWalk){Complete-DomeniaIndexWalkUi -Aborted -Detail 'Stockage suspendu après trois échecs. Reprenez les sauvegardes avant de relancer les lectures.'}
        [void](Show-DomeniaRouteNotice -Kind Warning -Text 'Cache non enregistré après trois échecs : les données restent en mémoire. Corrigez le stockage, puis reprenez les sauvegardes.' -RouteText 'Reprendre les sauvegardes' -Route 'StorageResume' -Key 'storage-suspended');return}
    Set-Status 'Cache non enregistré sur disque. Les observations sont encore en mémoire ; une nouvelle tentative bornée sera faite.' 'WARN'
}
function Queue-DomeniaMetadata {
    param([ValidateSet('Presence','UserScan','Park','ParkSession','ParkReset','SecretMeta','Sample','IndexBulk','LegacyImport','FleetSnapshot','DirectoryAbsence','DirectorySnapshot')][string]$Kind,$Row,[string]$Key='')
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    if(-not $script:DatabaseScopedPath){return $false}
    if($Kind -eq 'LegacyImport'){
        if($null -eq $Row){Set-Status 'Reprise des anciennes données impossible : données absentes.' 'WARN';return $false}
        $marker=[string]$Row.Marker
        $baseDn=[string]$Row.BaseDn
        if([string]::IsNullOrWhiteSpace($marker)){Set-Status 'Reprise des anciennes données impossible : marqueur absent.' 'WARN';return $false}
        if([string]::IsNullOrWhiteSpace($baseDn) -or $baseDn -notmatch '(?i)DC='){Set-Status 'Reprise des anciennes données impossible : domaine absent.' 'WARN';return $false}
        if($script:Persistence.LinkBusy){Set-Status 'Reprise des anciennes données impossible : enregistrement des liens en cours.' 'WARN';return $false}
        if($script:Persistence.LegacyImportJob){Set-Status 'Reprise des anciennes données déjà en cours.' 'WARN';return $false}
        # Points 32 and 34: an explicit import is refused under a maintenance lock rather than queued for a base that
        # the switch would leave (collected observations still wait in the queue; the switch accounts for them).
        $refusal=Get-DomeniaStorageInputRefusal -Maintenance $script:StorageMaintenance
        if($refusal){Set-Status ('Reprise des anciennes données : '+$refusal) 'WARN';return $false}
        foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){Set-Status 'Reprise des anciennes données impossible : modifications de liens en attente.' 'WARN';return $false}}
        if(-not $Key){$Key=$marker}
        $queueKey='LegacyImport|'+[string]$script:DatabaseScopedPath+'|'+$Key
        if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.Contains($queueKey)){Set-Status 'File locale pleine : reprise des anciennes données non enregistrée.' 'WARN';return $false}
        $script:Persistence.Pending[$queueKey]=[pscustomobject]@{QueueKey=$queueKey;Kind=$Kind;Path=[string]$script:DatabaseScopedPath;Row=$Row;Epoch=[long]$script:SessionEpoch}
        $script:Persistence.LinkBusy=$true
        Request-DomeniaStorageWork
        return $true
    }
    if(-not $Key){$Key=[guid]::NewGuid().ToString('N')}
    if($Kind -eq 'SecretMeta' -and $null -eq $Row.PSObject.Properties['Rows']){$Key+='|'+$(if([string]$Row.LapsScheme){'LAPS'}else{'BitLocker'})}
    $queueKey=$Kind+'|'+[string]$script:DatabaseScopedPath+'|'+$Key
    if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.Contains($queueKey)){Set-Status 'File locale pleine : les dernières informations sont en mémoire, pas encore enregistrées.' 'WARN';return $false}
    $script:Persistence.Pending[$queueKey]=[pscustomobject]@{QueueKey=$queueKey;Kind=$Kind;Path=[string]$script:DatabaseScopedPath;Row=$Row;Epoch=[long]$script:SessionEpoch}
    Request-DomeniaStorageWork
    return $true
}
function Get-DomeniaPersistenceState {
    # D028: the single place that builds the local save label, read by Fiabilite (Guard.UI) and the Live state line.
    # Pure read: never calls Initialize-DomeniaPersistence (timer, Closed handler); $script:Persistence and
    # $script:Live may be $null. Counts include the batches already sent and not yet confirmed (InFlight, SaveInFlight).
    $pending=0;$failed=0;$suspended=$false;$unavailable=$false;$conflicts=0;$queuedBytes=0L;$queuedChanges=0L
    $p=$script:Persistence
    if($null -ne $p){
        if($null -ne $p.Pending){$pending+=[int]$p.Pending.Count}
        $pending+=[int]$p.InFlight
        # A requested link save also exists before its coalescing timer queues the first batch.
        if(($null -ne $p.LinkRequestTimer -and $p.LinkRequestTimer.IsEnabled) -or [bool]$p.LinkPersistenceMore){$pending++}
        $failed=[int]$p.Failures
        # Same threshold as Start-DomeniaStorageWork and Fail-DomeniaStorageWork: three failures suspend the writer.
        $suspended=([int]$p.Failures -ge 3)
        if($null -ne $p.Conflicts){$conflicts=[int]$p.Conflicts.Count}
        foreach($item in @($p.Pending.Values)+@($p.InFlightItems)){if($item.Kind -eq 'StoreBatch'){$queuedBytes += [long]$item.Bytes;$queuedChanges += [long]$item.ChangeCount}}
    }
    $live=$script:Live
    if($null -ne $live){
        $livePending=[int]$live.SaveInFlight
        if($null -ne $live.SaveQueue){$livePending+=[int]$live.SaveQueue.Count}
        if($null -ne $live.QueryToSave){$livePending++}
        $pending+=$livePending
        # A failed read also sets SaveFault: it is a save failure only while Live work is still waiting.
        if((-not [string]::IsNullOrEmpty([string]$live.SaveFault)) -and ($livePending -gt 0)){$failed++}
        $unavailable=(-not [bool]$live.CacheReady)
    }
    $label=Get-DomeniaPersistenceLabel -Pending $pending -Failed $failed -Suspended ([bool]$suspended) -Unavailable ([bool]$unavailable) -Conflicts $conflicts
    return [pscustomobject]@{Pending=$pending;Failed=$failed;Suspended=[bool]$suspended;Unavailable=[bool]$unavailable;Conflicts=$conflicts;Label=[string]$label;QueuedBytes=$queuedBytes;QueuedChanges=$queuedChanges;MaximumQueuedBytes=33554432L;MaximumQueuedChanges=4096;MaximumBatchBytes=4194304;MaximumBatchChanges=250}
}

function Get-DomeniaCurrentStorageSpace {
    # Point 35: state of the last free-space measure of the active base volume (worker receipts, Mesurer, contrôle).
    $persistence=Get-DomeniaPersistenceState
    $free=-1L;$at='';$measure=$script:StorageSpaceMeasure
    if(($null -ne $measure) -and ([string]$measure.Path -ceq [string]$script:DatabaseScopedPath)){$free=[long]$measure.FreeBytes;$at=[string]$measure.MeasuredUtc}
    return Get-DomeniaStorageSpaceState -FreeBytes $free -MeasuredUtc $at -QueuedBytes ([long]$persistence.QueuedBytes)
}
function Update-DomeniaStorageSpace {
    # Point 35: records a free-space measure taken by a storage worker for the active base. Crossing into the
    # suspended state is announced once; the Stockage tab is refreshed every time.
    # Called from the storage completions: a display problem is logged and never reaches the save path.
    param([long]$FreeBytes=-1,[string]$MeasuredUtc='',[string]$Path='')
    try{
        if(($FreeBytes -lt 0) -or (-not $Path) -or ($Path -cne [string]$script:DatabaseScopedPath)){return}
        if(-not $MeasuredUtc){$MeasuredUtc=[datetime]::UtcNow.ToString('o')}
        $before=Get-DomeniaCurrentStorageSpace
        $script:StorageSpaceMeasure=[pscustomobject]@{Path=$Path;FreeBytes=$FreeBytes;MeasuredUtc=$MeasuredUtc}
        $after=Get-DomeniaCurrentStorageSpace
        if([bool]$after.BlocksCollections -and (-not [bool]$before.BlocksCollections)){Set-Status ([string]$after.Text) 'WARN'}
        Update-DomeniaStorageSpaceUi
    }catch{Write-AppLog ('Mesure dʼespace disque non affichée : '+$_.Exception.Message) 'WARN'}
}
function Update-DomeniaStorageSpaceUi {
    # Point 35: free space, collection threshold and what is still only in memory.
    try{
        $space=Get-DomeniaCurrentStorageSpace
        [void](Set-DomeniaControlText 'LblStorageSpace' ([string]$space.Text+[Environment]::NewLine+(Format-DomeniaStorageUnsaved (Get-DomeniaPersistenceState))))
    }catch{[void](Set-DomeniaControlText 'LblStorageSpace' ('État de lʼespace disque indisponible : '+$_.Exception.Message))}
}
function Update-DomeniaStorageLimitsUi {
    # Point 40: explicit storage, memory and retention bounds, with the last measure of this session when it exists.
    try{
        $engine=$null;try{$engine=Get-DomeniaEngineLimits}catch{$engine=$null}
        $usage=$null;if(($null -ne $script:StorageLastUsage) -and ([string]$script:StorageLastUsage.Path -ceq [string]$script:DatabaseScopedPath)){$usage=$script:StorageLastUsage}
        $lines=@(Get-DomeniaStorageLimitLines -Policy (Get-DomeniaCurrentStoragePolicy) -Engine $engine -Usage $usage -Space (Get-DomeniaCurrentStorageSpace))
        [void](Set-DomeniaControlText 'LblStorageLimits' ($lines -join [Environment]::NewLine))
    }catch{[void](Set-DomeniaControlText 'LblStorageLimits' ('Limites de stockage indisponibles : '+$_.Exception.Message))}
}
function Register-DomeniaSqliteBusyOutcome {
    # FI-12: counts, for the Operations panel, every finished worker whose SQLite lock wait ran out: an error worded as
    # SQLITE_BUSY/LOCKED by any storage worker, or a local read (LocalIndexRead, RelationHistoryRead of point 107)
    # answered Busy. Session counters only; nothing is retried or replayed here. Called once per finished task by
    # Complete-UiTasks.
    param($Job,$Output=$null,[AllowEmptyString()][string]$ErrorMessage='')
    if($null -eq $Job){return $false}
    $busy=$false
    if(-not [string]::IsNullOrWhiteSpace($ErrorMessage)){$busy=Test-DomeniaSqliteBusyText $ErrorMessage}
    elseif([string]$Job.OperationId -in @('LocalIndexRead','RelationHistoryRead')){
        foreach($item in @($Output)){if(($null -ne $item) -and ($null -ne $item.PSObject.Properties['Busy']) -and ($item.Busy -is [bool]) -and ([bool]$item.Busy)){$busy=$true}}
    }
    if(-not $busy){return $false}
    if($null -eq $script:DomeniaSqliteBusy){$script:DomeniaSqliteBusy=[pscustomobject]@{Count=0;LastUtc=$null;ByOperation=@{}}}
    $script:DomeniaSqliteBusy.Count++
    $script:DomeniaSqliteBusy.LastUtc=[datetime]::UtcNow
    $operation=[string]$Job.OperationId;if(-not $operation){$operation='Inconnue'}
    if(-not $script:DomeniaSqliteBusy.ByOperation.ContainsKey($operation)){$script:DomeniaSqliteBusy.ByOperation[$operation]=0}
    $script:DomeniaSqliteBusy.ByOperation[$operation]++
    return $true
}
function Get-DomeniaSqliteBusyStatusText {
    # FI-12: the Operations line, with the configured lock wait shared by the interface and every worker.
    $count=0;$last=$null
    if($null -ne $script:DomeniaSqliteBusy){$count=[int]$script:DomeniaSqliteBusy.Count;$last=$script:DomeniaSqliteBusy.LastUtc}
    $text=Format-DomeniaSqliteBusySummary -Count $count -LastUtc $last -TimeoutMs (Get-DomeniaSqliteBusyTimeoutMs (Get-CfgValue 'LocalStore' 'DatabaseBusyTimeoutMs' 2500))
    if($count -gt 0){
        $parts=@(foreach($name in @($script:DomeniaSqliteBusy.ByOperation.Keys|Sort-Object)){[string]$name+' : '+[string]$script:DomeniaSqliteBusy.ByOperation[$name]})
        if($parts.Count){$text+=' Opérations concernées : '+($parts -join ', ')+'.'}
    }
    return $text
}

function Get-DomeniaUserLocalRoot {
    return [string]([Environment]::GetFolderPath('LocalApplicationData'))
}

function Invoke-DomeniaPreferenceMigration {
    # Startup only, after validation; copy bytes once and retain the original. No overwrite,
    # configuration migration, deletion, cross-mode search or alternate write destination.
    $layout=$script:StorageLayout
    if(-not $script:DataStoreValidated -or $null -eq $layout -or [string]$layout.DataRoot -ine [string]$script:DataDir){
        throw 'DOMENIA_STORE_LAYOUT : migration des preferences sans stockage valide.'
    }
    $source=Join-Path ([string]$layout.DataRoot) 'Domenia.settings.json'
    $target=Join-Path (Join-Path ([string]$layout.DataRoot) 'Preferences') 'Domenia.settings.json'
    $sourceStream=$null;$temporary='';$copied=0;$failures=New-Object 'System.Collections.Generic.List[string]'
    try {
        $old=[pscustomobject]@{Path=$source;Exists=([IO.File]::Exists($source));Bytes=-1L;IsReparse=$true;ValidJson=$false}
        $new=[pscustomobject]@{Path=$target;Exists=(Test-Path -LiteralPath $target);Bytes=0L;IsReparse=$false;ValidJson=$false}
        $bytes=$null
        if($old.Exists -and -not $new.Exists){
            try {
                $info=Get-Item -LiteralPath $source -Force -ErrorAction Stop
                $old.Bytes=[long]$info.Length;$old.IsReparse=[bool]($info.Attributes -band [IO.FileAttributes]::ReparsePoint)
                $parent=$info.Directory
                while($null -ne $parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){$old.IsReparse=$true;break};$parent=$parent.Parent}
                if(-not $old.IsReparse -and $old.Bytes -le 1MB){
                    $sourceStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                    $old.Bytes=$sourceStream.Length
                    if($old.Bytes -le 1MB){
                        $bytes=New-Object byte[] ([int]$old.Bytes);$offset=0
                        while($offset -lt $bytes.Length){$read=$sourceStream.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){throw 'Source raccourcie pendant la lecture.'};$offset+=$read}
                        $reader=[IO.StreamReader]::new([IO.MemoryStream]::new($bytes),[Text.Encoding]::UTF8,$true)
                        try {
                            # A parser diagnostic can contain preference values; only the validity leaves this block.
                            try {$json=$reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop;$old.ValidJson=($null -ne $json -and $json -is [pscustomobject])}catch{$old.ValidJson=$false}
                        } finally {$reader.Dispose()}
                    }
                }
            } catch {$failures.Add('Lecture des anciennes preferences impossible : '+$source+' : '+$_.Exception.Message)}
        }
        $plan=Get-DomeniaPreferenceMigrationPlan -Layout $layout -Files @($old,$new)
        foreach($step in $plan.Steps){
            $traceAction=[string]$step.Action
            if($step.Action -eq 'Copier'){
                try {
                    $parent=[IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($target))
                    while($null -ne $parent){if(-not $parent.Exists -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw ('Destination de preferences non valide : '+$parent.FullName)};$parent=$parent.Parent}
                    $temporary=Join-Path ([IO.Path]::GetDirectoryName($target)) ('.domenia-migration-'+[guid]::NewGuid().ToString('N')+'.tmp')
                    $output=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    try {$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()}
                    $sha=[Security.Cryptography.SHA256]::Create()
                    try {$expected=[Convert]::ToBase64String($sha.ComputeHash($bytes));$actual=[Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($temporary)))}finally{$sha.Dispose()}
                    if($expected -cne $actual){throw 'La copie des preferences ne correspond pas a la source.'}
                    [IO.File]::Move($temporary,$target);$temporary='';$copied++;$traceAction='Copie confirmee'
                } catch {$traceAction='Copie non effectuee';$failures.Add('Copie des preferences refusee : '+$target+' : '+$_.Exception.Message)}
            }
            Write-StartupTrace -Stage 'Preferences/Migration' -Status $(if($step.Action -in @('Refuser','Ignorer') -or $traceAction -eq 'Copie non effectuee'){'WARN'}else{'INFO'}) -Detail ($traceAction+' : '+$step.Source+' -> '+$step.Target+' ; '+$step.Reason)
        }
        foreach($errorText in @($plan.Errors)+@($failures.ToArray())){Write-StartupTrace -Stage 'Preferences/Migration' -Status 'WARN' -Detail $errorText}
        return [pscustomobject]@{Copied=$copied;Plan=$plan;Errors=@($plan.Errors)+@($failures.ToArray())}
    } finally {
        if($null -ne $sourceStream){$sourceStream.Dispose()}
        if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    }
}

function Format-DomeniaStorageUsage {
    param($Usage,$Queue=$null)
    if($null -eq $Usage -or $Usage.Kind -cne 'StorageUsage' -or $Usage.ReadOnly -isnot [bool] -or -not $Usage.ReadOnly){throw 'Mesure locale non confirmee.'}
    $labels=@{Observations='Observations';Snapshots='Instantanes';History='Historique';Index='Index';ManualLinks='Associations conservees';Secrets='Metadonnees de secrets conservees'}
    if($Usage.DbstatAvailable -isnot [bool]){throw 'Disponibilite des tailles locales non confirmee.'}
    $seen=@{};$lines=New-Object 'System.Collections.Generic.List[string]'
    $at=[datetime]::MinValue
    if(-not [datetime]::TryParse([string]$Usage.MeasuredUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$at)){throw 'Date de mesure locale invalide.'}
    foreach($name in @('DatabaseBytes','WalBytes','ReusableBytes')){
        $value=0L
        if(-not [long]::TryParse([string](Get-DomeniaMember $Usage $name ''),[ref]$value) -or $value -lt -1){throw 'Taille locale non confirmee.'}
    }
    $lines.Add('Mesure du '+$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')+' : '+[string]$Usage.Path)
    $lines.Add('Base : '+(Format-DomeniaSize $Usage.DatabaseBytes)+' ; journal SQLite : '+(Format-DomeniaSize $Usage.WalBytes))
    $lines.Add('Espace deja reutilisable dans la base : '+(Format-DomeniaSize $Usage.ReusableBytes))
    if($null -ne $Usage.PSObject.Properties['DiskFreeBytes']){$lines.Add('Espace libre du volume : '+(Format-DomeniaSize ([long]$Usage.DiskFreeBytes)))}
    if($null -ne $Usage.PSObject.Properties['ReceiptCount']){$lines.Add('Recus conserves : '+[string]$Usage.ReceiptCount+' ; details compactes : '+[string]$Usage.CompactedReceiptCount+' (identifiants et empreintes conserves).')}
    if($null -ne $Queue){$lines.Add('File de stockage : '+$Queue.QueuedChanges+'/4096 changements, '+(Format-DomeniaSize $Queue.QueuedBytes)+'/32 Mo.')}
    $lines.Add('Limites : file de 4096 changements / 32 Mo ; lot maximal de 250 changements / 4 Mo. Le stockage dépend de lʼespace disque disponible.')
    foreach($category in @($Usage.Categories)){
        $name=[string]$category.Category
        if(-not $labels.ContainsKey($name) -or $seen.ContainsKey($name)){throw 'Categories de mesure locales incoherentes.'}
        $seen[$name]=$true;$rows=0L;$bytes=0L
        if(-not [long]::TryParse([string]$category.Rows,[ref]$rows) -or $rows -lt -1 -or -not [long]::TryParse([string]$category.Bytes,[ref]$bytes) -or $bytes -lt -1){throw 'Compteurs locaux non confirmes.'}
        $rowText=if($rows -lt 0){'nombre de lignes inconnu'}else{$rows.ToString()+' ligne(s)'}
        $lines.Add($labels[$name]+' : '+$rowText+' ; '+(Format-DomeniaSize $bytes))
    }
    if($seen.Count -ne $labels.Count){throw 'Categories de mesure locales incompletes.'}
    if(-not [bool]$Usage.DbstatAvailable){$lines.Add('Taille par categorie indisponible sur ce systeme ; aucune estimation appliquee.')}
    $reads=Format-DomeniaStorageReadProbes -Probes @(Get-DomeniaMember $Usage 'ReadProbes' @())
    if($reads){$lines.Add($reads)}
    return $lines -join [Environment]::NewLine
}

function Start-DomeniaStorageUsage {
    try {
        if([bool]$script:DemoMode){throw 'Mesure de la base locale indisponible en demonstration.'}
        $path=[string]$script:DatabaseScopedPath
        if([string]::IsNullOrWhiteSpace($path)){throw 'Aucune base locale active dans ce contexte.'}
        if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('StorageUsage','StoragePurge')}).Count -or @($script:DetachedReadJobs|Where-Object{$_.OperationId -in @('StorageUsage','StoragePurge')}).Count){throw 'Une mesure ou une purge locale est encore active.'}
        [void](Initialize-DomeniaWinSqliteNative)
        $state=[pscustomobject]@{Path=$path;Epoch=[long]$script:SessionEpoch}
        $id=Start-UiTask -Name 'Mesurer le stockage local' -OperationId 'StorageUsage' -Code (Get-DomeniaStorageUsageWorkerCode) -Payload ([pscustomobject]@{Path=$path}) -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageUsage' -ErrorHandler 'Fail-DomeniaStorageUsage' -DisableControls @('BtnStorageUsage') -TimeoutSeconds 60 -TaskClass 'Explicit'
        if(-not $id){throw 'Mesure locale non admise dans le moteur.'}
        [void](Set-DomeniaControlText 'LblStorageUsage' 'Mesure en cours dans la base locale...')
        Set-Status 'Mesure du stockage local en cours.'
    } catch {
        $text='Mesure du stockage impossible : '+$_.Exception.Message
        [void](Set-DomeniaControlText 'LblStorageUsage' $text)
        Set-Status $text 'WARN'
    }
}

function Complete-DomeniaStorageUsage {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath){return}
    try {
        $usage=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Path','Categories','ReadOnly')
        if($null -eq $usage -or [string]$usage.Path -ine [string]$State.Path){throw 'Contexte de mesure locale non confirme.'}
        $text=Format-DomeniaStorageUsage $usage -Queue (Get-DomeniaPersistenceState)
        [void](Set-DomeniaControlText 'LblStorageUsage' $text)
        $script:StorageLastUsage=$usage
        Update-DomeniaStorageSpace -FreeBytes ([long](Get-DomeniaMember $usage 'DiskFreeBytes' -1)) -MeasuredUtc ([string]$usage.MeasuredUtc) -Path ([string]$State.Path)
        Update-DomeniaStorageLimitsUi
        Set-Status 'Stockage local mesure en lecture seule.'
    } catch {Fail-DomeniaStorageUsage $_.Exception.Message $State}
}

function Fail-DomeniaStorageUsage {
    param($Message,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath){return}
    $text='Mesure du stockage impossible : '+[string]$Message
    [void](Set-DomeniaControlText 'LblStorageUsage' $text)
    Set-Status $text 'WARN';Write-AppLog $text 'WARN'
}

function Start-DomeniaStorageIntegrity {
    # Point 36: explicit, read-only targeted checks of the active base (schema, tables and columns, identity, pending
    # switch, receipts, references, SQLite structure, journal) in the StorageIntegrity worker. Nothing is repaired.
    try{
        if([bool]$script:DemoMode){throw 'contrôle indisponible en démonstration.'}
        $path=[string]$script:DatabaseScopedPath
        if([string]::IsNullOrWhiteSpace($path)){throw 'aucune base locale active.'}
        foreach($job in @(@($script:AsyncJobs.Values)+@($script:DetachedReadJobs))){if(($null -ne $job) -and ([string]$job.OperationId -in @('StorageIntegrity','StoragePurge','StorageMaintenance','StorageRetention'))){throw 'une autre opération sur la base locale est en cours.'}}
        [void](Initialize-DomeniaWinSqliteNative)
        $state=[pscustomobject]@{Path=$path;Epoch=[long]$script:SessionEpoch}
        $id=Start-UiTask -Name 'Contrôler lʼintégrité de la base locale' -OperationId 'StorageIntegrity' -Code (Get-DomeniaStorageIntegrityWorkerCode) -Payload ([pscustomobject]@{Path=$path;DomainDn=[string]$script:Conn.BaseDn}) -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageIntegrity' -ErrorHandler 'Fail-DomeniaStorageIntegrity' -DisableControls @('BtnStorageIntegrity') -TimeoutSeconds 300 -TaskClass 'Explicit'
        if(-not $id){throw 'contrôle non admis dans le moteur.'}
        [void](Set-DomeniaControlText 'LblStorageIntegrity' 'Contrôle en cours, en lecture seule…')
    }catch{
        $text='Contrôle dʼintégrité impossible : '+$_.Exception.Message
        [void](Set-DomeniaControlText 'LblStorageIntegrity' $text);Set-Status $text 'WARN'
    }
}
function Complete-DomeniaStorageIntegrity {
    param($Result,$State)
    if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return}
    try{
        $report=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Path','Checks','ReadOnly')
        if(($null -eq $report) -or ([string]$report.Path -ine [string]$State.Path)){throw 'Contexte du contrôle non confirmé.'}
        $verdict=Get-DomeniaStorageIntegrityVerdict $report
        [void](Set-DomeniaControlText 'LblStorageIntegrity' $verdict.Text)
        Update-DomeniaStorageSpace -FreeBytes ([long](Get-DomeniaMember $report 'DiskFreeBytes' -1)) -MeasuredUtc ([string](Get-DomeniaMember $report 'CheckedUtc' '')) -Path ([string]$State.Path)
        if($verdict.Failed -gt 0){Set-Status ('Intégrité de la base locale : défaut détecté. Restaurez une sauvegarde vérifiée ; la base actuelle nʼest pas modifiée.') 'WARN'}
        else{Set-Status ('Intégrité de la base locale : '+[string]$verdict.Verdict+'.')}
        Write-AppLog ('Contrôle dʼintégrité : '+[string]$verdict.Verdict+' ('+$verdict.Failed+' défaut(s), '+$verdict.Warnings+' alerte(s)).') $(if($verdict.Failed -gt 0){'WARN'}else{'INFO'})
    }catch{Fail-DomeniaStorageIntegrity $_.Exception.Message $State}
}
function Fail-DomeniaStorageIntegrity {
    param($Message,$State)
    if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return}
    $text='Contrôle dʼintégrité non confirmé : '+([string]$Message).TrimEnd('.')+'. Aucune modification de la base.'
    [void](Set-DomeniaControlText 'LblStorageIntegrity' $text);Set-Status $text 'WARN';Write-AppLog $text 'WARN'
}

function Get-DomeniaStoragePurgeChoice {
    $selection=@(foreach($name in @('Observations','Snapshots','History','Index')){$control=Get-DomeniaControl ('ChkStoragePurge'+$name);if($null -ne $control -and [bool]$control.IsChecked){$name}})
    $days=730
    if($selection -contains 'History'){
        $age=Get-DomeniaControl 'TxtStorageHistoryDays'
        if($null -eq $age -or -not [int]::TryParse([string]$age.Text,[ref]$days) -or $days -lt 1 -or $days -gt 36500){throw 'Age de l historique : indiquez un nombre entier de 1 a 36500 jours.'}
    }
    return [pscustomobject]@{Selection=$selection;HistoryAgeDays=$days;Key=((@($selection|Sort-Object) -join '|')+':'+$days)}
}
function Reset-DomeniaStoragePurgePreview {
    $hadPreview=($null -ne $script:StoragePurgePreview)
    $script:StoragePurgePreview=$null
    $button=Get-DomeniaControl 'BtnStoragePurge';if($button){$button.IsEnabled=$false}
    if($hadPreview){[void](Set-DomeniaControlText 'LblStoragePurge' 'Selection modifiee : refaites la simulation.')}
}
function Assert-DomeniaStoragePurgeReady {
    # -AllowQueued (points 32 and 34): an interrupted switch holds the maintenance lock, so data already queued in memory
    # cannot be written until it is resumed or rolled back. Only running work refuses then; the queue is kept for the
    # rollback base and dropped, counted, after a switch to another base (Clear-DomeniaStoragePendingForOtherBase).
    param([switch]$AllowQueued)
    if([bool]$script:DemoMode){throw 'Purge locale indisponible en demonstration.'}
    if([string]::IsNullOrWhiteSpace([string]$script:DatabaseScopedPath)){throw 'Aucune base locale active.'}
    if($script:AsyncEngineClosing){throw 'Fermeture en cours.'}
    if($null -ne $script:DomeniaDirectoryReads){foreach($read in $script:DomeniaDirectoryReads.Values){if(($null -ne $read) -and ($read.InFlight -or (($null -ne $read.Collector) -and (-not $read.Collector.Done)) -or ((-not $AllowQueued) -and ((($null -ne $read.Input) -and ($read.Input.Count -gt 0)) -or (($null -ne $read.BuildChanges) -and ($read.BuildChanges.Count -gt 0)) -or ($null -ne $read.Batch))))){throw 'Des lectures annuaire attendent leur enregistrement. Attendez leur fin.'}}}
    if((-not $AllowQueued) -and ($null -ne $script:Live) -and ($null -ne $script:Live.SavePending) -and ($script:Live.SavePending.Count -gt 0)){throw 'Des mesures attendent encore leur enregistrement.'}
    if(Test-DomeniaParkRunActive){throw 'Arrêtez les relevés de postes en cours avant la maintenance locale.'}
    # Every outstanding producer must finish; a late AD or workstation result can also refill the cache.
    if(@($script:AsyncJobs.Values|Where-Object{$null -ne $_}).Count -or @($script:DetachedReadJobs|Where-Object{$null -ne $_}).Count -or $script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){throw 'Une operation est encore active ou a verifier. Attendez sa fin puis refaites la simulation.'}
    if($null -ne $script:Live -and ($script:Live.SaveJob -or [int]$script:Live.SaveInFlight -gt 0)){throw 'Un enregistrement des observations est encore en cours.'}
    if($null -ne $script:Persistence){
        if($script:Persistence.Job -or $script:Persistence.LegacyImportJob){throw 'Un enregistrement local est encore en cours. Attendez sa confirmation.'}
        if((-not $AllowQueued) -and ($script:Persistence.LinkBusy -or $script:Persistence.Pending.Count -or (($null -ne $script:Persistence.LinkRequestTimer) -and $script:Persistence.LinkRequestTimer.IsEnabled))){throw 'Des modifications locales attendent leur enregistrement. Refaites la simulation apres cet enregistrement.'}
    }
}
function Format-DomeniaStoragePurge {
    param($Result,$State)
    if($null -eq $Result -or $Result.Kind -cne 'StoragePurge' -or $Result.DryRun -isnot [bool] -or $Result.Committed -isnot [bool] -or $Result.DryRun -ne [bool]$State.DryRun -or $Result.Committed -eq $Result.DryRun -or [string]$Result.Path -ine [string]$State.Path -or [string]$Result.Fingerprint -cnotmatch '^[A-F0-9]{64}$'){throw 'Resultat de purge locale non confirme.'}
    if((@($Result.Selection|Sort-Object) -join '|') -cne (@($State.Selection|Sort-Object) -join '|') -or [string]$Result.HistoryCutoffUtc -cne [string]$State.HistoryCutoffUtc){throw 'Selection de purge non confirmee.'}
    $expected=@{};foreach($category in $State.Selection){foreach($t in @(Get-DomeniaPurgeTargets $category)){$expected[$category+'|'+$t.Table]=$t.Action}}
    $seen=@{};$deleted=0L;$reset=0L;$lines=New-Object 'System.Collections.Generic.List[string]'
    $labels=@{};foreach($entry in @(Get-DomeniaRetentionPolicy)){$labels[$entry.Category]=$entry.Label}
    $categoryCounts=@{}
    foreach($row in @($Result.Counts)){
        $key=[string]$row.Category+'|'+[string]$row.Table;$n=0L
        if(-not $expected.ContainsKey($key) -or $seen.ContainsKey($key) -or [string]$row.Action -cne $expected[$key] -or -not [long]::TryParse([string]$row.Rows,[ref]$n) -or $n -lt 0 -or $row.Exists -isnot [bool]){throw 'Comptage de purge incomplet ou incoherent.'}
        $seen[$key]=$true
        if($row.Action -eq 'Reset'){$reset+=$n}else{$deleted+=$n}
        if(-not $categoryCounts.ContainsKey([string]$row.Category)){$categoryCounts[[string]$row.Category]=0L}
        if($row.Action -eq 'Delete'){$categoryCounts[[string]$row.Category]+=$n}
    }
    if($seen.Count -ne $expected.Count){throw 'Comptage de purge incomplet.'}
    foreach($name in @('DeletedRows','ResetRows')){$n=0L;if(-not [long]::TryParse([string](Get-DomeniaMember $Result $name ''),[ref]$n) -or $n -lt 0){throw 'Compte final de purge non confirme.'}}
    if(-not $Result.DryRun -and ([string]$Result.Fingerprint -cne [string]$State.ExpectedFingerprint -or [long]$Result.DeletedRows -ne $deleted -or [long]$Result.ResetRows -ne $reset)){throw 'Purge non confirmee : compte final incoherent.'}
    foreach($category in @($State.Selection|Sort-Object)){$lines.Add($labels[$category]+' : '+$categoryCounts[$category]+' ligne(s) '+$(if($Result.DryRun){'a supprimer'}else{'supprimee(s)'}))}
    if($State.Selection -contains 'History'){$lines.Add('Historique anterieur au '+([datetime]$State.HistoryCutoffUtc).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')+' ; dates illisibles conservees.')}
    if($State.Selection -contains 'Index'){$lines.Add('Reperes de synchronisation : '+$reset+' ligne(s) '+$(if($Result.DryRun){'a reinitialiser'}else{'reinitialisee(s)'})+'. Domaine et marqueur de reprise conserves.')}
    $lines.Add('Conserves : toutes les associations, leur historique protege, les secrets, la configuration, les preferences, les journaux et tous les recus.')
    $lines.Add('La purge libere de la place reutilisable dans la base ; elle ne compacte pas le fichier.')
    return ($lines -join [Environment]::NewLine)
}
function Start-DomeniaStoragePurge {
    param([switch]$Apply,$Preview=$null)
    try {
        Assert-DomeniaStoragePurgeReady
        $choice=Get-DomeniaStoragePurgeChoice
        if($Apply){
            if($null -eq $Preview -or $null -eq $script:StoragePurgePreview -or $Preview.Id -cne $script:StoragePurgePreview.Id -or $Preview.State.Epoch -ne [long]$script:SessionEpoch -or [string]$Preview.State.Path -cne [string]$script:DatabaseScopedPath -or $Preview.State.ChoiceKey -cne $choice.Key){throw 'Simulation absente ou contexte modifie. Refaites la simulation.'}
            $selection=@($Preview.State.Selection);$cutoff=[string]$Preview.State.HistoryCutoffUtc;$expected=[string]$Preview.Result.Fingerprint
        }else{
            $plan=Get-DomeniaPurgePlan -Selection $choice.Selection -HistoryAgeDays $choice.HistoryAgeDays
            if(@($plan.Refused).Count){throw ($plan.Refused -join ' ')}
            if(-not @($plan.Actions).Count){throw 'Choisissez au moins une categorie puis simulez.'}
            $selection=@($plan.Actions|ForEach-Object{$_.Category});$cutoff='';$expected=''
            foreach($action in $plan.Actions){if($action.Category -eq 'History'){$cutoff=[string]$action.OlderThanUtc}}
        }
        Reset-DomeniaStoragePurgePreview
        [void](Initialize-DomeniaWinSqliteNative)
        $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Path=[string]$script:DatabaseScopedPath;Epoch=[long]$script:SessionEpoch;Selection=$selection;HistoryCutoffUtc=$cutoff;DryRun=(-not [bool]$Apply);ChoiceKey=$choice.Key;ExpectedFingerprint=$expected}
        $payload=[pscustomobject]@{Path=$state.Path;Selection=$selection;HistoryCutoffUtc=$cutoff;DryRun=$state.DryRun;ExpectedFingerprint=$expected}
        $name=if($Apply){'Purge du stockage local'}else{'Simulation de purge locale'}
        $id=Start-UiTask -Name $name -OperationId 'StoragePurge' -Code (Get-DomeniaStoragePurgeWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaStoragePurge' -ErrorHandler 'Fail-DomeniaStoragePurge' -DisableControls @('BtnStorageUsage','BtnStoragePurgePreview') -NonCancellable -TimeoutSeconds 120 -TaskClass 'Explicit'
        if(-not $id){throw 'Operation locale non admise.'}
        [void](Set-DomeniaControlText 'LblStoragePurge' ($name+' en cours...'))
        Set-Status ($name+' en cours.')
    }catch{
        Reset-DomeniaStoragePurgePreview
        $text='Purge locale impossible : '+$_.Exception.Message
        [void](Set-DomeniaControlText 'LblStoragePurge' $text);Set-Status $text 'WARN'
    }
}
function Request-DomeniaStoragePurge {
    try {
        Assert-DomeniaStoragePurgeReady
        $preview=$script:StoragePurgePreview
        $choice=Get-DomeniaStoragePurgeChoice
        if($null -eq $preview -or $preview.State.Epoch -ne [long]$script:SessionEpoch -or [string]$preview.State.Path -cne [string]$script:DatabaseScopedPath -or $preview.State.ChoiceKey -cne $choice.Key){throw 'Refaites la simulation avant de purger.'}
        $description=Format-DomeniaStoragePurge $preview.Result $preview.State
        $startPurge=${function:Start-DomeniaStoragePurge}
        Request-DomeniaInlineConfirmation -Title 'Confirmer la purge locale' -Target $preview.State.Path -Message $description -ConfirmText 'Purger ces donnees locales' -CancelText 'Conserver' -OnConfirm ({& $startPurge -Apply -Preview $preview}.GetNewClosure()) -OnCancel {Set-Status 'Purge annulee ; aucune suppression.'}
    }catch{Reset-DomeniaStoragePurgePreview;Set-Status ('Purge locale impossible : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaStoragePurge {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    try {
        $result=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Path','DryRun','Committed','Counts','Fingerprint')
        $text=Format-DomeniaStoragePurge $result $State
        if($State.DryRun){
            $choice=Get-DomeniaStoragePurgeChoice
            if($State.ChoiceKey -cne $choice.Key){Reset-DomeniaStoragePurgePreview;[void](Set-DomeniaControlText 'LblStoragePurge' 'Selection modifiee pendant la simulation. Refaites la simulation.');return}
            $script:StoragePurgePreview=[pscustomobject]@{Id=$State.Id;State=$State;Result=$result}
            $button=Get-DomeniaControl 'BtnStoragePurge';if($button){$button.IsEnabled=$true}
            [void](Set-DomeniaControlText 'LblStoragePurge' ('Simulation ; aucune suppression.'+[Environment]::NewLine+$text))
            Set-Status 'Simulation terminée. Vérifiez les nombres avant de confirmer.'
        }else{
            Reset-DomeniaStoragePurgePreview
            if($State.Selection -contains 'Index'){
                # The committed transaction already confirms an empty index; no synchronous disk reread. A metadata reading
                # still running from before the purge is discarded (FI-19, Complete-DomeniaIndexMetadataUi).
                $script:IndexMetadataGeneration=[long]$script:IndexMetadataGeneration+1;$script:IndexMetadataPending=$false
                $script:IndexRows=@();$script:IndexInfo=$null;$script:IndexSyncStates=@{};$script:IndexMetadataError=''
                $script:IndexDbCount=0;$script:IndexDbUsers=0;$script:IndexDbComputers=0;$script:IndexDbMachinesActive=0;$script:IndexDbMachinesDisabled=0
                Rebuild-DomeniaIndexLookup
            }
            if($State.Selection -contains 'Observations'){
                $script:PresenceCache=@{};$script:ParkState=@{}
                # The dashboards forget the purged observations too (merged with the base otherwise).
                $script:FleetObservations=$null
                if($null -ne $script:Live){$script:Live.Observations.Clear();$script:Live.ObservationsLoaded=$false;$script:Live.SaveQueue=@{};$script:Live.Done=@{};$script:Live.PresenceSeen=@{}}
            }
            if($State.Selection -contains 'Snapshots' -and $null -ne $script:Live){$script:Live.MemoryQueries=@{};$script:Live.QueryToSave=$null}
            # History holds the daily snapshots of the overview (FO-10): purged, the curve is computed again.
            if(@($State.Selection|Where-Object{$_ -in @('Observations','Index','History')}).Count){try{Request-DomeniaFleetRefresh -Force}catch{}}
            if(@($State.Selection|Where-Object{$_ -in @('Snapshots','Observations','Index')}).Count){
                # Invalidate the displayed search producer too: no old stream may repopulate the purged cache.
                Stop-DomeniaLiveSearch
                if($null -ne $script:Live){$script:Live.Refresh.Clear();$script:Live.Deferred.Clear()}
                $script:VisitCache=@{};$script:CacheStats=[ordered]@{Hits=0;Misses=0;Writes=0;Evictions=0;Errors=0}
            }
            [void](Set-DomeniaControlText 'LblStorageUsage' 'Mesure precedente perimee apres la purge. Cliquez sur Mesurer.')
            [void](Set-DomeniaControlText 'LblStoragePurge' $text)
            Set-Status ('Purge locale confirmee : '+$result.DeletedRows+' ligne(s) supprimee(s).')
            Add-DomeniaUiLog -Area 'Stockage' -Text ('Purge locale confirmee : '+$result.DeletedRows+' ligne(s), categories '+($State.Selection -join ', ')+'. Associations, journaux et recus conserves.')
        }
    }catch{Fail-DomeniaStoragePurge $_.Exception.Message $State}
}
function Fail-DomeniaStoragePurge {
    param($Message,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    Reset-DomeniaStoragePurgePreview
    $text='Operation locale non confirmee : '+[string]$Message+'. Verifiez avec Mesurer puis refaites la simulation. Aucun rejeu automatique.'
    [void](Set-DomeniaControlText 'LblStoragePurge' $text);Set-Status $text 'WARN';Write-AppLog $text 'WARN'
}
function Update-DomeniaIndexLocation {
    # Decision David 2026-10-07: Outils > Base autonome shows where the base lives, with backup and copy.
    # UI-19: one readable line (domain, size on disk, last verified backup) instead of the path, which stays in the
    # tooltip and behind « Copier le chemin » ; a soft alert when no backup is younger than 7 days. Local file metadata
    # only (the active base is always on a local disk).
    $path='';try{$path=[string](Get-DomeniaDatabasePath)}catch{$path=''}
    $exists=(([bool]$path) -and ([IO.File]::Exists($path)))
    $bytes=-1L;$last=$null
    if($exists){
        $bytes=0L;foreach($suffix in @('','-wal')){$file=[IO.FileInfo]::new($path+$suffix);if($file.Exists){$bytes+=[long]$file.Length}}
        # Last verified backup: the receipt of the StorageBackup worker, or the newest copy of the Backups folder (scheduled
        # and manual copies Domenia-*.db, copies taken before a gesture Geste-*.db).
        try{
            $key=Get-DomeniaStoreId $path ([string]$script:Conn.BaseDn);$text=[string](Get-DomeniaSetting ('Storage.Backup.Last.'+$key) '')
            $parsed=[datetime]::MinValue
            if(([bool]$text) -and ([datetime]::TryParse($text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed))){$last=$parsed.ToUniversalTime()}
        }catch{$last=$null}
        try{
            $folder=Join-Path ([IO.Path]::GetDirectoryName($path)) 'Backups'
            $newest=@(foreach($pattern in @('Domenia-*.db','Geste-*.db')){Get-ChildItem -LiteralPath $folder -Filter $pattern -File -ErrorAction SilentlyContinue})|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
            if(($null -ne $newest) -and (($null -eq $last) -or ($newest.LastWriteTimeUtc -gt $last))){$last=$newest.LastWriteTimeUtc}
        }catch{}
    }
    $domain=[string]$script:Conn.Domain
    if(-not $domain){$domain=(@(([string]$script:Conn.BaseDn) -split ','|Where-Object{$_ -match '^\s*DC='}|ForEach-Object{($_ -replace '^\s*DC=','').Trim()}) -join '.')}
    $summary=Get-DomeniaDatabaseLocationSummary -Domain $domain -Bytes $bytes -LastBackupUtc $last -Demo:([bool]$script:DemoMode) -Missing:(-not $exists)
    $label=Get-DomeniaControl 'LblIndexLocation'
    if($null -ne $label){
        $label.Text=[string]$summary.Text
        $tip=if($path){'Fichier de la base : '+$path}else{'Aucune base active.'}
        $label.ToolTip=$tip;[Windows.Automation.AutomationProperties]::SetHelpText($label,$tip)
    }
    # « Copier le chemin » copies the path of the active context (Copy-DomeniaIndexLocationPath): enabled with it only.
    $copy=Get-DomeniaControl 'BtnIndexCopyPath';if($null -ne $copy){$copy.IsEnabled=(-not [string]::IsNullOrWhiteSpace([string]$script:DatabaseScopedPath))}
    $alert=Get-DomeniaControl 'LblIndexBackupStatus'
    if($null -ne $alert){$alert.Text=[string]$summary.AlertText;$alert.Visibility=if([bool]$summary.Alert){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
}
function Copy-DomeniaIndexLocationPath {
    # UI-19: the full path of the base stays one click away. The path of the active context only: no SQLite read on
    # the interface thread to resolve it.
    $path=[string]$script:DatabaseScopedPath
    if(-not $path){Set-Status 'Aucune base active : aucun chemin à copier.' 'WARN';return $false}
    try{Set-ClipboardSafe $path;Set-Status ('Chemin de la base copié : '+$path);return $true}
    catch{Set-Status ('Copie du chemin impossible : '+$_.Exception.Message) 'WARN';return $false}
}
function Set-DomeniaIndexTiles {
    # DS-09: writes the four tiles of Base autonome (value and detail of each), as computed by Get-DomeniaIndexTiles.
    param([object[]]$Tiles)
    foreach($tile in @($Tiles)){
        if($null -eq $tile){continue}
        [void](Set-DomeniaControlText -Name ('LblIndexTile'+[string]$tile.Key) -Text ([string]$tile.Value))
        [void](Set-DomeniaControlText -Name ('LblIndexTile'+[string]$tile.Key+'Detail') -Text ([string]$tile.Detail))
    }
}
function Open-DomeniaIndexLocation {
    $path=[string](Get-DomeniaDatabasePath)
    if(-not $path -or -not [IO.File]::Exists($path)){Set-Status 'Aucune base active à afficher.' 'WARN';return}
    Start-Process -FilePath 'explorer.exe' -ArgumentList @('/select,"'+$path+'"')
}
function Assert-DomeniaBackupDestination {
    param([string]$Database,[string]$Destination)
    if(-not $Destination){return}
    $source=[IO.Path]::GetFullPath($Database);$target=[IO.Path]::GetFullPath($Destination)
    foreach($protected in @($source,($source+'-wal'),($source+'-shm'),($source+'-journal'))){
        if([string]::Equals($target,$protected,[StringComparison]::OrdinalIgnoreCase)){throw 'Choisissez un autre fichier : la base active et ses journaux ne peuvent pas être remplacés par une exportation.'}
    }
}
function Invoke-DomeniaIndexBackup {
    # Consistent hot copy through the SQLite backup API, run by the StorageBackup worker (no wait on the Dispatcher,
    # D014); the original is never modified.
    param([switch]$ChooseDestination)
    try{
        $destination=''
        if($ChooseDestination){
            $request=New-DomeniaFileRequest -Mode Save
            $request.Title='Copier une sauvegarde de la base';$request.FileName=('Domenia-'+(Get-Date -Format 'yyyyMMdd-HHmm')+'.db')
            $request.Filter='Base SQLite (*.db)|*.db';$request.DefaultExt='.db';$request.CheckFileExists=$false
            if(-not $request.ShowDialog($script:Window)){return}
            $destination=[string]$request.FileName
        }
        $path=Get-DomeniaDatabasePath
        if(-not [IO.File]::Exists($path)){throw 'aucune base active a sauvegarder.'}
        Assert-DomeniaBackupDestination -Database $path -Destination $destination
        $payload=New-DomeniaBackupPayload -Path $path -BudgetSeconds ([int](Get-CfgValue 'LocalStore' 'BackupTimeoutSeconds' 30)) -CopyTo $destination
        $id=Start-UiTask -Name 'Sauvegarder la base' -OperationId 'StorageBackup' -Code (Get-DomeniaStorageBackupWorkerCode) -Payload $payload -CallbackState ([pscustomobject]@{CopyTo=$destination;Path=[string]$path;Epoch=[long]$script:SessionEpoch}) -ReplaceKey 'storage:backup' -TimeoutSeconds 150 -StatusText 'Sauvegarde de la base en cours...' -SuccessHandler 'Complete-DomeniaIndexBackupUi' -ErrorHandler 'Fail-DomeniaIndexBackupUi'
        if([string]::IsNullOrWhiteSpace([string]$id)){throw 'Sauvegarde non admise dans le moteur.'}
    }catch{Set-Status ('Sauvegarde de la base impossible : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaIndexBackupUi {
    param($Result,$State)
    if($null -ne $State -and [bool]$State.Automatic){$script:StorageAutoBackupJob=''}
    if($null -eq $State -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Backup','CopiedTo')
    if($null -eq $packet -or -not [string]$packet.Backup -or [string]$packet.CopiedTo -cne [string]$State.CopyTo){Fail-DomeniaIndexBackupUi 'Résultat de sauvegarde non confirmé.' $State;return}
    # Point 33 and FI-13: one verification rule for every copy; an unverified receipt is a failure, never a success.
    if(-not (Test-DomeniaBackupReceiptVerified $packet)){Fail-DomeniaIndexBackupUi 'Sauvegarde non vérifiée : contrôle SQLite ou empreinte SHA-256 absents.' $State;return}
    if([string]$packet.CopiedTo){Set-Status ('Sauvegarde de la base copiee : '+[string]$packet.CopiedTo)}
    else{Set-Status ('Sauvegarde de la base enregistrée : '+[string]$packet.Backup)}
    $origin='Manual';if([bool]$State.Automatic){$origin='Scheduled'}
    Register-DomeniaVerifiedBackup -Packet $packet -Path ([string]$State.Path) -Origin $origin
    Update-DomeniaIndexLocation;Update-DomeniaStorageBackupScheduleUi
}
function Fail-DomeniaIndexBackupUi {
    param([string]$Message,$State)
    if($null -ne $State -and [bool]$State.Automatic){$script:StorageAutoBackupJob=''}
    if($null -eq $State -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    try{Register-DomeniaBackupFailure -Path ([string]$State.Path) -Message ([string]$Message)}catch{Write-AppLog ('Échec de sauvegarde non mémorisé : '+$_.Exception.Message) 'WARN'}
    Set-Status ('Sauvegarde de la base impossible : '+$Message) 'WARN'
    Update-DomeniaStorageBackupScheduleUi
}
function New-DomeniaBackupPayload {
    # One backup policy for the active base (point 33, FI-13). Manual, scheduled and before-gesture copies are all made
    # by the StorageBackup worker (SQLite online backup, quick_check, SHA-256 of the produced file) in the Backups folder
    # of the base, and every series keeps the « Copies à conserver » newest copies of the storage policy. The copies
    # taken before a gesture form their own series (Geste-*.db) so that frequent gestures never rotate out a manual or
    # scheduled copy (Domenia-*.db).
    param([Parameter(Mandatory=$true)][string]$Path,[int]$BudgetSeconds=120,[AllowEmptyString()][string]$CopyTo='',[switch]$Gesture)
    $keep=7;try{$keep=[int](Get-DomeniaCurrentStoragePolicy).BackupKeep}catch{$keep=7}
    $series='';if($Gesture){$series='Gesture'}
    return [pscustomobject]@{Database=$Path;BackupDirectory=(Join-Path ([IO.Path]::GetDirectoryName($Path)) 'Backups');BudgetSeconds=$BudgetSeconds;Keep=$keep;CopyTo=$CopyTo;Series=$series}
}
function Register-DomeniaVerifiedBackup {
    # A verified receipt (Test-DomeniaBackupReceiptVerified), whichever copy it comes from, becomes the last verified
    # backup of the base: schedule line, location summary and point of return reused by a gesture within 30 minutes.
    param($Packet,[Parameter(Mandatory=$true)][string]$Path,[ValidateSet('Manual','Scheduled','Gesture')][string]$Origin='Manual')
    $key=Get-DomeniaStoreId $Path ([string]$script:Conn.BaseDn)
    Set-DomeniaSetting ('Storage.Backup.Last.'+$key) ([string]$Packet.VerifiedAtUtc)
    Set-DomeniaSetting ('Storage.Backup.LastDetail.'+$key) (([pscustomobject]@{Bytes=[long](Get-DomeniaMember $Packet 'Bytes' -1);Sha256=[string]$Packet.SHA256;File=[IO.Path]::GetFileName([string]$Packet.Backup);Automatic=($Origin -eq 'Scheduled');Origin=$Origin})|ConvertTo-Json -Compress)
    if($null -ne $script:StorageBackupFailures){[void]$script:StorageBackupFailures.Remove($key)}
}
function Register-DomeniaBackupFailure {
    # The last failed copy of the base in this session, shown by the schedule line, whichever copy failed.
    param([Parameter(Mandatory=$true)][string]$Path,[AllowEmptyString()][string]$Message='')
    $key=Get-DomeniaStoreId $Path ([string]$script:Conn.BaseDn)
    if($null -eq $script:StorageBackupFailures){$script:StorageBackupFailures=@{}}
    $script:StorageBackupFailures[$key]=[pscustomobject]@{AtUtc=[datetime]::UtcNow.ToString('o');Message=[string]$Message}
}

function Get-DomeniaGestureBackupState {
    # FI-13: decision for the active base from its last verified backup (setting Storage.Backup.Last.<store>); no disk
    # access on the interface thread.
    $path=[string]$script:DatabaseScopedPath;$last=''
    if($path){try{$key=Get-DomeniaStoreId $path ([string]$script:Conn.BaseDn);$last=[string](Get-DomeniaSetting ('Storage.Backup.Last.'+$key) '')}catch{$last=''}}
    return (Get-DomeniaGestureBackupDecision -LastSuccessUtc $last)
}
function Invoke-DomeniaGestureBackup {
    # FI-13: a verified backup of the local base precedes a gesture that changes it (AD read of an OU, CSV import,
    # removal of orphan associations, park reset). The copy is made by the StorageBackup worker (SQLite online backup,
    # rotation of the backup policy), never on the Dispatcher, and the gesture runs only from its success callback. A
    # verified copy younger than 30 min is already the point of return. When the copy fails, the gesture is not started
    # and the page offers an explicit choice to continue without a backup.
    param([Parameter(Mandatory=$true)][ValidateSet('IndexUpdate','LinkImport','LinkPrune','ParkReset')][string]$Gesture,[Parameter(Mandatory=$true)][scriptblock]$Then)
    $label=Get-DomeniaGestureBackupLabel -Gesture $Gesture
    $path=[string]$script:DatabaseScopedPath
    # Points 32 and 34: a base held by a maintenance (copy, switch to finish, unreadable base) is neither copied nor
    # changed: the gesture is refused where it is asked, with its reason, and never offered without a backup.
    $refusal=Get-DomeniaStorageInputRefusal $script:StorageMaintenance
    if($refusal){Set-Status $refusal 'WARN';return 'Maintenance'}
    # Nothing to protect: demonstration base, or no base file yet (first update of this domain).
    if(([bool]$script:DemoMode) -or ([string]::IsNullOrWhiteSpace($path)) -or (-not [IO.File]::Exists($path))){[void](& $Then);return 'NotNeeded'}
    $decision=Get-DomeniaGestureBackupState
    if(-not [bool]$decision.Due){
        Add-DomeniaUiLog -Area 'Stockage' -Text ('Avant '+$label+' : '+(Get-DomeniaGestureBackupNotice $decision))
        [void](& $Then);return 'Recent'
    }
    if($null -ne $script:StorageGestureBackup){
        # Annuler, a withdrawal from the queue, a detach after the cancel grace and a session change end the backup
        # without calling its handlers: the slot then frees itself (same liveness rule as Start-DomeniaStorageWork). A
        # detached copy that still runs keeps it until it ends.
        $slot=$script:StorageGestureBackup;$jobId=[string](Get-DomeniaMember $slot 'JobId' '');$alive=$false
        if(([long]$slot.Epoch -eq [long]$script:SessionEpoch) -and ([bool]$jobId)){
            if(($null -ne $script:AsyncJobs) -and $script:AsyncJobs.Contains($jobId)){$alive=$true}
            else{foreach($detached in @($script:DetachedReadJobs)){if(($null -ne $detached) -and ([string]$detached.Id -ceq $jobId)){$alive=$true;break}}}
        }
        if($alive){Set-Status ('Sauvegarde avant '+[string]$slot.Label+' déjà en cours : attendez sa fin.') 'WARN';return 'Busy'}
        $script:StorageGestureBackup=$null
        Add-DomeniaUiLog -Area 'Stockage' -Level 'WARN' -Text ('Sauvegarde avant '+[string]$slot.Label+' arrêtée sans reçu (annulée, retirée de la file ou session changée) : ce geste nʼa pas été lancé.')
    }
    # Same backup policy as the manual and scheduled copies (New-DomeniaBackupPayload), in the series Geste-*.db.
    $payload=New-DomeniaBackupPayload -Path $path -BudgetSeconds 120 -Gesture
    $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Gesture=$Gesture;Label=$label;Then=$Then;CopyTo='';Path=$path;Epoch=[long]$script:SessionEpoch;Automatic=$false;JobId=''}
    $script:StorageGestureBackup=$state
    try{
        $id=Start-UiTask -Name ('Sauvegarde avant '+$label) -OperationId 'StorageBackup' -Code (Get-DomeniaStorageBackupWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaGestureBackup' -ErrorHandler 'Fail-DomeniaGestureBackup' -ReplaceKey 'storage:backup:gesture' -TimeoutSeconds 150 -StatusText ('Sauvegarde vérifiée de la base avant '+$label+'…') -TaskClass 'Explicit'
        if([string]::IsNullOrWhiteSpace([string]$id)){throw 'Sauvegarde non admise dans le moteur.'}
        $state.JobId=[string]$id
    }catch{
        $script:StorageGestureBackup=$null
        Show-DomeniaGestureBackupFailure -State $state -Message $_.Exception.Message
        return 'Failed'
    }
    Add-DomeniaUiLog -Area 'Stockage' -Text ('Sauvegarde de la base demandée avant '+$label+'.')
    return 'Started'
}
function Complete-DomeniaGestureBackup {
    param($Result,$State)
    if(($null -eq $State) -or ($null -eq $script:StorageGestureBackup) -or ([string]$script:StorageGestureBackup.Id -cne [string]$State.Id)){return}
    $script:StorageGestureBackup=$null
    if(([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){Set-Status ('Sauvegarde terminée, mais la base ou la session a changé : '+[string]$State.Label+' nʼest pas lancée.') 'WARN';return}
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Backup','CopiedTo')
    # Same verification as the manual and scheduled copies: quick_check of the copy and SHA-256 of the produced file.
    if(-not (Test-DomeniaBackupReceiptVerified $packet)){Show-DomeniaGestureBackupFailure -State $State -Message 'résultat de sauvegarde non confirmé';return}
    try{Register-DomeniaVerifiedBackup -Packet $packet -Path ([string]$State.Path) -Origin 'Gesture'}catch{Write-AppLog ('Date de sauvegarde non mémorisée : '+$_.Exception.Message) 'WARN'}
    Add-DomeniaUiLog -Area 'Stockage' -Text ('Sauvegarde vérifiée avant '+[string]$State.Label+' : '+[string]$packet.Backup)
    try{Update-DomeniaIndexLocation}catch{}
    try{Update-DomeniaStorageBackupScheduleUi}catch{Write-AppLog ('État des sauvegardes non actualisé : '+$_.Exception.Message) 'WARN'}
    try{[void](& $State.Then)}
    catch{$text='Sauvegarde vérifiée, mais '+[string]$State.Label+' nʼa pas pu démarrer : '+$_.Exception.Message;Set-Status $text 'WARN';Write-AppLog $text 'WARN'}
}
function Fail-DomeniaGestureBackup {
    param($Message,$State)
    if(($null -eq $State) -or ($null -eq $script:StorageGestureBackup) -or ([string]$script:StorageGestureBackup.Id -cne [string]$State.Id)){return}
    $script:StorageGestureBackup=$null
    if(([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return}
    Show-DomeniaGestureBackupFailure -State $State -Message ([string]$Message)
}
function Show-DomeniaGestureBackupFailure {
    # FI-13: the gesture is not started. The operator may retry later or continue without a backup, in the page.
    param($State,[string]$Message)
    $detail=([string]$Message).Trim().TrimEnd('.');if(-not $detail){$detail='erreur inconnue'}
    $label=[string]$State.Label
    $text='Sauvegarde de la base impossible avant '+$label+' : '+$detail+'. Rien nʼa été lancé.'
    Set-Status $text 'WARN';Write-AppLog $text 'WARN'
    try{Register-DomeniaBackupFailure -Path ([string]$State.Path) -Message ('avant '+$label+' : '+$detail);Update-DomeniaStorageBackupScheduleUi}catch{Write-AppLog ('Échec de sauvegarde non mémorisé : '+$_.Exception.Message) 'WARN'}
    # Closures capture the functions they call: a closure does not see the functions of the module scope.
    $resume=${function:Resume-DomeniaGestureWithoutBackup};$status=${function:Set-Status}
    $onConfirm={& $resume -State $State}.GetNewClosure()
    $onCancel={& $status ('Rien nʼa été lancé : la base nʼa pas été modifiée. Réessayez quand la sauvegarde est possible.')}.GetNewClosure()
    [void](Request-DomeniaInlineConfirmation -Title ('Sauvegarde impossible avant '+$label) -Message ($text+' Vous pouvez réessayer plus tard, ou continuer sans sauvegarde : la base sera alors modifiée sans point de retour récent.') -Target ('storage:gesture-backup:'+[string]$State.Gesture) -ConfirmText 'Continuer sans sauvegarde' -CancelText 'Ne pas lancer' -Risk 'Danger' -OnConfirm $onConfirm -OnCancel $onCancel)
}

function Resume-DomeniaGestureWithoutBackup {
    # FI-13: « Continuer sans sauvegarde », explicit choice of the operator after a failed backup. The gesture runs only
    # in the session and on the base it was asked for; the choice is written to the journal.
    param($State)
    if($null -eq $State){return}
    if(([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){Set-Status ('La base ou la session a changé : '+[string]$State.Label+' nʼest pas lancée.') 'WARN';return}
    Add-DomeniaUiLog -Area 'Stockage' -Level 'WARN' -Text ('Poursuite sans sauvegarde confirmée par lʼopérateur : '+[string]$State.Label+'.')
    [void](& $State.Then)
}

function New-DomeniaStoreContext {
    param([Parameter(Mandatory=$true)][string]$RequestId,[long]$Generation=0,[string]$ScopeDn='',[bool]$Subtree=$true)
    $path=[string]$script:DatabaseScopedPath;$domain=([string]$script:Conn.BaseDn).Trim().ToLowerInvariant()
    if(-not $path -or -not $domain){throw 'Base du domaine non initialisee : collecte differee.'}
    return [pscustomobject]@{Version=1;StoreId=(Get-DomeniaStoreId $path $domain);Path=[IO.Path]::GetFullPath($path);DomainDn=$domain;SessionEpoch=[long]$script:SessionEpoch;RequestId=$RequestId;Generation=$Generation;ScopeDn=$ScopeDn;Subtree=$Subtree}
}
function Submit-DomeniaStoreBatch {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$BatchId,[long]$Sequence=0,[Parameter(Mandatory=$true)][object[]]$Changes,[Parameter(Mandatory=$true)][string]$SuccessHandler,[Parameter(Mandatory=$true)][string]$ErrorHandler,$CallbackState)
    # Only bounded serialization occurs on the caller. SQLite and readback stay in the LocalStore worker.
    if($SuccessHandler -notmatch '^[A-Za-z][A-Za-z0-9-]+$' -or $ErrorHandler -notmatch '^[A-Za-z][A-Za-z0-9-]+$'){throw 'Callback de stockage invalide.'}
    $batch=ConvertTo-DomeniaStoreBatch -Context $Context -BatchId $BatchId -Sequence $Sequence -Changes $Changes
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    if([int]$script:Persistence.Failures -ge 3){return [pscustomobject]@{Accepted=$false;Backpressure=$true;Reason='StorageSuspended';BatchId=$batch.BatchId}}
    # Points 32 and 34: a saved query is an operator change; under a maintenance lock it is refused (its caller says it
    # was not saved) instead of waiting for a base that the switch leaves. Collected data keeps waiting in the queue.
    if((Get-DomeniaStorageInputRefusal -Maintenance $script:StorageMaintenance) -and @($Changes|Where-Object{[string](Get-DomeniaStoreValue $_ 'Kind') -cin @('QueryRecipe','QueryDependency','QueryMigration')}).Count){return [pscustomobject]@{Accepted=$false;Backpressure=$false;Reason='StorageMaintenance';BatchId=$batch.BatchId}}
    $key='StoreBatch|'+$batch.Context.StoreId+'|'+$batch.BatchId
    $bytes=0L;$count=0L
    foreach($item in @($script:Persistence.Pending.Values)+@($script:Persistence.InFlightItems)){
        if([string]$item.QueueKey -ceq $key){
            if([string]$item.Hash -cne $batch.Hash){throw 'Identifiant de lot reutilise avec des donnees differentes.'}
            return [pscustomobject]@{Accepted=$true;Backpressure=$false;Reason='AlreadyQueued';BatchId=$batch.BatchId}
        }
        if([string]$item.Kind -eq 'StoreBatch'){$bytes += [long]$item.Bytes;$count += [long]$item.ChangeCount}
    }
    if($bytes+$batch.Bytes -gt 33554432 -or $count+$batch.Count -gt 4096){
        Request-DomeniaStorageWork
        return [pscustomobject]@{Accepted=$false;Backpressure=$true;Reason='StorageQueueFull';BatchId=$batch.BatchId}
    }
    $script:Persistence.Pending[$key]=[pscustomobject]@{Kind='StoreBatch';QueueKey=$key;Path=$batch.Context.Path;Epoch=$batch.Context.SessionEpoch;Json=$batch.Json;Hash=$batch.Hash;Bytes=$batch.Bytes;ChangeCount=$batch.Count;Context=$batch.Context;BatchId=$batch.BatchId;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler;CallbackState=$CallbackState}
    Request-DomeniaStorageWork
    return [pscustomobject]@{Accepted=$true;Backpressure=$false;Reason='Queued';BatchId=$batch.BatchId}
}
function Request-DomeniaStoreRead {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)]$Query,[Parameter(Mandatory=$true)][string]$SuccessHandler,[Parameter(Mandatory=$true)][string]$ErrorHandler,$CallbackState)
    if([string]$Context.StoreId -cne (Get-DomeniaStoreId ([string]$Context.Path) ([string]$Context.DomainDn))){throw 'Contexte de lecture invalide.'}
    Assert-DomeniaStoreSafeData $Query
    $copy=($Query|ConvertTo-Json -Depth 8 -Compress)|ConvertFrom-Json -ErrorAction Stop
    $payload=[pscustomobject]@{Action='StoreRead';Path=[string]$Context.Path;StoreId=[string]$Context.StoreId;DomainDn=[string]$Context.DomainDn;Query=$copy}
    # W13 (point 123): a local read belongs to the request of its store context (same trace identifier).
    return Start-UiTask -Name 'Lecture des donnees enregistrees' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -SuccessHandler $SuccessHandler -ErrorHandler $ErrorHandler -CallbackState $CallbackState -TimeoutSeconds 120 -TraceId ([string]$Context.RequestId)
}

function Get-DomeniaLocalDatabasePath {
    param([string]$Path,[switch]$Existing)
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path -match '[\x00-\x1f]'){throw 'Chemin local absolu requis.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\') -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full)).DriveType -eq [IO.DriveType]::Network){throw 'Une base active doit rester sur un disque local.'}
    if([IO.Path]::GetExtension($full) -ine '.db' -or ($Existing -and -not [IO.File]::Exists($full))){throw 'Fichier de base .db local requis.'}
    $part=$full;while($part){if((Test-Path -LiteralPath $part) -and ([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint)){throw 'Chemin redirige refuse.'};$next=[IO.Path]::GetDirectoryName($part);if($next -eq $part){break};$part=$next}
    foreach($suffix in @('-wal','-shm','-journal')){if([IO.File]::Exists($full+$suffix) -and ([IO.File]::GetAttributes($full+$suffix) -band [IO.FileAttributes]::ReparsePoint)){throw 'Annexe SQLite redirigee refusee.'}}
    return $full
}
function Get-DomeniaStorageMaintenanceUndo {
    # Point 31: the completed move, restore or resumed switch of this session that may still be undone: same epoch,
    # same active base, original kept with its marker. The worker refuses once the new base has received a write.
    $undo=$script:StorageLastSwitch
    if($null -eq $undo){return $null}
    if(([long]$undo.Epoch -ne [long]$script:SessionEpoch) -or ([string]$undo.TargetPath -cne [string]$script:DatabaseScopedPath)){return $null}
    return $undo
}
function Update-DomeniaStorageMaintenanceControls {
    # Point 32: the four assistant buttons follow the maintenance state; the explanation line follows it too when idle.
    $state=Get-DomeniaStorageMaintenanceControlState -Maintenance $script:StorageMaintenance -DemoMode ([bool]$script:DemoMode) -HasDatabase (-not [string]::IsNullOrWhiteSpace([string]$script:DatabaseScopedPath)) -CanUndo ($null -ne (Get-DomeniaStorageMaintenanceUndo))
    foreach($pair in @(@('BtnStorageMove','Move'),@('BtnStorageRestore','Restore'),@('BtnStorageResume','Resume'),@('BtnStorageRollback','Rollback'))){
        $button=Get-DomeniaControl ([string]$pair[0]);if($null -ne $button){$button.IsEnabled=[bool]$state.([string]$pair[1])}
    }
    return $state
}
function Test-DomeniaStorageMaintenanceHold {
    # True while a maintenance step holds the base: copy or pending switch (Locked), queue drain, or an assistant
    # waiting for its confirmation (Hold, released after 10 minutes so that a forgotten panel never blocks for ever).
    $maintenance=$script:StorageMaintenance
    if($null -eq $maintenance){return $false}
    if([bool]$maintenance.Locked -or [bool]$maintenance.Draining){return $true}
    if(-not [bool]$maintenance.Hold){return $false}
    $until=$maintenance.HoldUntil
    return (($null -eq $until) -or ([datetime]::UtcNow -lt [datetime]$until))
}
function Get-DomeniaStorageCollectionRefusal {
    # Points 32 and 35: one admission rule for the explicit collections that fill the base (directory passes and
    # workstation reads). '' when a new collection may start; otherwise the sentence to show. Already collected data
    # keeps being written: only new collections wait.
    if(Test-DomeniaStorageMaintenanceHold){return 'Maintenance de la base locale en cours : nouvelles collectes suspendues jusquʼà la fin de lʼassistant (Outils > Base autonome > Stockage).'}
    if(($null -ne $script:Persistence) -and ([int]$script:Persistence.Failures -ge 3)){return 'Enregistrement local suspendu après des échecs : nouvelles collectes suspendues. Reprenez les sauvegardes dans Outils > Base autonome > Stockage, section Reprises.'}
    $space=Get-DomeniaCurrentStorageSpace
    if([bool]$space.BlocksCollections){return [string]$space.Text}
    return ''
}
function Request-DomeniaStorageMaintenance {
    # Points 31, 32 and 34: Move (choose a new local location) or Restore (a verified backup into a new file). The
    # assistant suspends new collections, drains what is queued, inspects source and destination read-only (plus a
    # write test in the chosen folder), asks for confirmation, copies, verifies, then switches. Originals are kept.
    param([ValidateSet('Move','Restore')][string]$Mode,[string]$SourcePath='',[string]$TargetPath='')
    try{
        $current=$script:StorageMaintenance
        $recovery=(($null -ne $current) -and [bool]$current.Recovery -and ($null -eq $current.Receipt))
        if(($null -ne $current) -and ([bool]$current.Draining -or [string]$current.Job)){throw 'Une étape de maintenance est déjà en cours.'}
        if($recovery -and ($Mode -ne 'Restore')){throw 'Base locale illisible : seule la restauration dʼune sauvegarde vérifiée est possible.'}
        if(($null -ne $current) -and [bool]$current.Locked -and (-not $recovery)){throw 'Terminez ou reprenez la maintenance en attente.'}
        if([bool]$script:DemoMode){throw 'Maintenance locale indisponible en démonstration.'}
        $active=[string]$script:DatabaseScopedPath
        if(-not $active){throw 'Aucune base locale active.'}
        if($Mode -eq 'Move'){$SourcePath=$active}elseif(-not $SourcePath){
            $dialog=[Microsoft.Win32.OpenFileDialog]::new();$dialog.Title='Choisir la sauvegarde SQLite à restaurer';$dialog.Filter='Base SQLite (*.db)|*.db';$dialog.CheckFileExists=$true
            $backups='';try{$backups=Join-Path ([IO.Path]::GetDirectoryName($active)) 'Backups'}catch{$backups=''}
            if($backups -and [IO.Directory]::Exists($backups)){$dialog.InitialDirectory=$backups}
            if(-not $dialog.ShowDialog($script:Window)){return};$SourcePath=$dialog.FileName
        }
        if(-not $TargetPath){
            $dialog=[Microsoft.Win32.SaveFileDialog]::new();$dialog.Title=$(if($Mode -eq 'Restore'){'Choisir le nouveau fichier local de la base restaurée'}else{'Choisir le nouvel emplacement local de la base'});$dialog.Filter='Base SQLite (*.db)|*.db';$dialog.DefaultExt='.db';$dialog.AddExtension=$true;$dialog.OverwritePrompt=$false;$dialog.FileName='Domenia-'+[datetime]::Now.ToString('yyyyMMdd-HHmmss')+'.db'
            if(-not $dialog.ShowDialog($script:Window)){return};$TargetPath=$dialog.FileName
        }
        $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Mode=$Mode;Epoch=[long]$script:SessionEpoch;Path=$active;DomainDn=[string]$script:Conn.BaseDn;SourcePath=[IO.Path]::GetFullPath($SourcePath);TargetPath=[IO.Path]::GetFullPath($TargetPath);Fingerprint='';Job='';Locked=$recovery;Recovery=$recovery;Hold=$true;HoldUntil=[datetime]::UtcNow.AddMinutes(10);Draining=$false;DrainNext='';DrainUntil=[datetime]::MinValue;Receipt=$null}
        $script:StorageMaintenance=$state
        # Point 34: over an unreadable base the locked writer never empties its queue; what waits there targets that
        # base and is accounted for by the switch (Clear-DomeniaStoragePendingForOtherBase). Only running work waits.
        $ready=$true;try{Assert-DomeniaStoragePurgeReady -AllowQueued:$recovery}catch{$ready=$false}
        if($ready){Start-DomeniaStorageMaintenanceInspect -State $state}else{Start-DomeniaStorageMaintenanceDrain -State $state}
    }catch{Set-Status ('Maintenance locale impossible : '+$_.Exception.Message) 'WARN'}
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Start-DomeniaStorageMaintenanceInspect {
    param($State)
    try{
        if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){throw 'Contexte de maintenance modifié.'}
        $payload=[pscustomobject]@{Action='Inspect';ActivePath=$State.Path;SourcePath=$State.SourcePath;TargetPath=$State.TargetPath;DomainDn=$State.DomainDn}
        $State.Job=Start-UiTask -Name 'Vérifier la base et préparer la maintenance' -OperationId 'StorageMaintenance' -Code (Get-DomeniaStorageMaintenanceWorkerCode) -Payload $payload -SuccessHandler 'Complete-DomeniaStorageMaintenancePreview' -ErrorHandler 'Fail-DomeniaStorageMaintenance' -CallbackState $State -TimeoutSeconds 180 -TaskClass 'Explicit'
        if(-not $State.Job){throw 'Admission de la vérification non confirmée.'}
        [void](Set-DomeniaControlText 'LblStorageMaintenance' 'Étape 1 sur 3 : vérification en lecture seule de la source et de la destination, avec un test dʼécriture dans le dossier choisi.')
    }catch{
        if($null -ne $State){$State.Job='';$State.Hold=[bool]$State.Recovery}
        Set-Status ('Maintenance locale impossible : '+$_.Exception.Message) 'WARN'
    }
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Start-DomeniaStorageMaintenanceDrain {
    # Point 32: new collections stay suspended (Hold) while the single writer saves what is already queued; the
    # read-only inspection (then the confirmation) follows as soon as nothing is pending, so the preview and its
    # fingerprint always describe the base as it will be copied. Bounded to 120 s; nothing dropped, nothing replayed.
    # Point 34: over an unreadable base (Recovery) only running work is awaited; its queue can never be written.
    param($State)
    $State.Draining=$true;$State.DrainNext='Inspect';$State.DrainUntil=[datetime]::UtcNow.AddSeconds(120)
    if($null -eq $script:StorageDrainTimer){$script:StorageDrainTimer=New-DomeniaTimer -Owner 'Timer:StorageDrain' -IntervalMs 1000 -RunWhenHidden -Tick {Invoke-DomeniaStorageMaintenanceDrainTick}}
    $script:StorageDrainTimer.Start()
    if([bool]$State.Recovery){
        [void](Set-DomeniaControlText 'LblStorageMaintenance' 'Restauration en attente de la fin de lʼactivité locale en cours (120 s au plus) ; la base illisible reste en place.')
        Set-Status 'Restauration : attente de la fin de lʼactivité locale en cours.'
    }else{
        [void](Set-DomeniaControlText 'LblStorageMaintenance' ('Nouvelles collectes suspendues : enregistrement de la file avant la copie (120 s au plus). '+(Format-DomeniaStorageUnsaved (Get-DomeniaPersistenceState))))
        Set-Status 'Maintenance de la base : nouvelles collectes suspendues le temps dʼenregistrer la file locale.'
    }
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Invoke-DomeniaStorageMaintenanceDrainTick {
    $state=$script:StorageMaintenance
    if(($null -eq $state) -or (-not [bool]$state.Draining)){if($null -ne $script:StorageDrainTimer){$script:StorageDrainTimer.Stop()};return}
    if(($state.Epoch -ne [long]$script:SessionEpoch) -or ([string]$state.Path -cne [string]$script:DatabaseScopedPath)){
        $state.Draining=$false;$state.Hold=[bool]$state.Recovery;$script:StorageDrainTimer.Stop();[void](Update-DomeniaStorageMaintenanceControls);return
    }
    $why='';try{Assert-DomeniaStoragePurgeReady -AllowQueued:([bool]$state.Recovery)}catch{$why=[string]$_.Exception.Message}
    if(-not $why){
        $state.Draining=$false;$script:StorageDrainTimer.Stop()
        Start-DomeniaStorageMaintenanceInspect -State $state
        return
    }
    if([datetime]::UtcNow -gt $state.DrainUntil){
        $state.Draining=$false;$state.Hold=[bool]$state.Recovery;$script:StorageDrainTimer.Stop()
        $text='Maintenance non lancée : activité locale encore en cours après 120 s ('+$why.TrimEnd('.')+'). Collectes rétablies ; relancez lʼassistant quand elle sera terminée.'
        if([bool]$state.Recovery){$text='Restauration non lancée : activité locale encore en cours après 120 s ('+$why.TrimEnd('.')+'). La base illisible reste en place et les collectes restent suspendues ; relancez « Restaurer une sauvegarde… » quand elle sera terminée.'}
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN';[void](Update-DomeniaStorageMaintenanceControls);return
    }
    [void](Set-DomeniaControlText 'LblStorageMaintenance' ('Nouvelles collectes suspendues : attente de la fin de lʼactivité locale ('+$why.TrimEnd('.')+'). '+(Format-DomeniaStorageUnsaved (Get-DomeniaPersistenceState))))
}
function Stop-DomeniaStorageMaintenanceRequest {
    # Cancellation at the confirmation step: nothing was copied; collections resume unless the base is unreadable.
    param($State)
    if(($null -eq $State) -or ($null -eq $script:StorageMaintenance) -or ($State.Id -cne $script:StorageMaintenance.Id) -or $State.Job){return}
    $State.Hold=[bool]$State.Recovery;$State.Locked=[bool]$State.Recovery
    [void](Set-DomeniaControlText 'LblStorageMaintenance' 'Maintenance annulée ; base actuelle conservée.')
    Set-Status 'Maintenance annulée ; base actuelle conservée.'
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Complete-DomeniaStorageMaintenancePreview {
    param($Result,$State)
    if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath) -or ($null -eq $script:StorageMaintenance) -or ($script:StorageMaintenance.Id -cne $State.Id)){return}
    try{
        $State.Job='';$r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Action','Source','ActivePath','Target')
        if($null -eq $r){throw 'Inspection non confirmée.'}
        $sourceDomain=[string]$r.Source.DomainDn
        $domainConfirmed=(($sourceDomain -ieq [string]$State.DomainDn) -or (($State.Mode -eq 'Move') -and (-not $sourceDomain)))
        if(($r.Kind -cne 'StorageMaintenance') -or ($r.Action -cne 'Inspect') -or ([string]$r.Source.Path -cne $State.SourcePath) -or ([string]$r.ActivePath -cne $State.Path) -or (-not $domainConfirmed) -or ([string]$r.Source.Integrity -cne 'ok') -or ([string]$r.Source.Fingerprint -cnotmatch '^[a-f0-9]{64}$') -or ($null -eq $r.Target) -or ([string]$r.Target.Path -ine $State.TargetPath)){throw 'Inspection non confirmée.'}
        $preview=Get-DomeniaStorageMaintenancePreview -Mode $State.Mode -Inspection $r
        $State.Fingerprint=[string]$r.Source.Fingerprint;$State.HoldUntil=[datetime]::UtcNow.AddMinutes(10)
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $preview.Text)
        $start=${function:Start-DomeniaStorageMaintenanceApply};$cancel=${function:Stop-DomeniaStorageMaintenanceRequest}
        Request-DomeniaInlineConfirmation -Title $preview.Title -Target $State.TargetPath -Message $preview.Text -ConfirmText $preview.ConfirmText -CancelText 'Conserver la base actuelle' -OnConfirm ({& $start -State $State}.GetNewClosure()) -OnCancel ({& $cancel -State $State}.GetNewClosure())
    }catch{Fail-DomeniaStorageMaintenance $_.Exception.Message $State}
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Start-DomeniaStorageMaintenanceApply {
    param($State,[ValidateSet('','Resume','Rollback')][string]$Recovery='')
    $wasLocked=$false;if($null -ne $State){$wasLocked=[bool]$State.Locked}
    try{
        if(($null -eq $State) -or ($null -eq $script:StorageMaintenance) -or ($State.Id -cne $script:StorageMaintenance.Id) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){throw 'Contexte de maintenance modifié.'}
        # A restore over an unreadable base (State.Recovery) and the resume of a locked switch admit the queue that the
        # lock keeps for another base; only running work refuses them.
        $ready=$true;$why='';try{Assert-DomeniaStoragePurgeReady -AllowQueued:([bool]$State.Recovery -or ([bool]$Recovery -and $wasLocked))}catch{$ready=$false;$why=[string]$_.Exception.Message}
        if(-not $ready){
            if($Recovery){throw $why}
            # Writes reached the queue after the inspection: once saved, they would change the source and the copy would
            # refuse the confirmed fingerprint. Drain them, then inspect again and ask a new confirmation.
            Start-DomeniaStorageMaintenanceDrain -State $State
            Set-Status 'Des écritures locales sont arrivées depuis lʼaperçu : enregistrement, puis nouvel aperçu à confirmer.'
            return
        }
        $State.Locked=$true;$State.Hold=$true
        # An undo names the original (marker holder) as the worker's active base; the session itself is on the copy.
        $payload=[pscustomobject]@{Action=$(if($Recovery){$Recovery}else{$State.Mode});OperationId=$State.Id;ActivePath=(Get-DomeniaStorageMaintenanceMarkerPath $State);SourcePath=$State.SourcePath;TargetPath=$State.TargetPath;DomainDn=$State.DomainDn;ExpectedFingerprint=$State.Fingerprint;BudgetSeconds=600}
        $State.Job=Start-UiTask -Name 'Copier et vérifier la base locale' -OperationId 'StorageMaintenance' -Code (Get-DomeniaStorageMaintenanceWorkerCode) -Payload $payload -SuccessHandler 'Complete-DomeniaStorageMaintenanceApply' -ErrorHandler 'Fail-DomeniaStorageMaintenance' -CallbackState $State -TimeoutSeconds 660 -NonCancellable -TaskClass 'Explicit'
        if(-not $State.Job){$State.Locked=$wasLocked;throw 'Admission de maintenance non confirmée.'}
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $(if($Recovery -eq 'Rollback'){'Retour à la base précédente : vérification en cours.'}elseif($Recovery){'Reprise de la bascule : vérification de la copie en cours.'}else{'Étape 2 sur 3 : copie puis contrôle de la base ; nouvelles collectes et écritures suspendues.'}))
    }catch{
        if(($null -ne $State) -and (-not [bool]$State.Locked)){$State.Hold=[bool]$State.Recovery}
        Set-Status ('Maintenance non lancée : '+$_.Exception.Message) 'WARN'
    }
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Get-DomeniaStorageMaintenanceMarkerPath {
    # Base that holds (or will hold) the switch marker: the active base, except for the undo of a completed switch.
    param($State)
    $marker=[string](Get-DomeniaMember $State 'MarkerPath' '')
    if($marker){return $marker}
    return [string]$State.Path
}
function Clear-DomeniaStoragePendingForOtherBase {
    # Points 32 and 34: after a switch, what was queued for another base can no longer be written there (a marker
    # keeps it read-only, or the session left it) and was never part of the verified copy. Those items are dropped
    # and counted, never replayed into the new base; their callers are told, as for a refused batch. Operator changes
    # (associations, saved queries, imports) never reach this point: the lock refuses them where they are made
    # (Get-DomeniaStorageInputRefusal), so what is dropped here is collected data.
    param([string]$ActivePath)
    if(($null -eq $script:Persistence) -or (-not $ActivePath)){return 0}
    $message='Base locale changée par la maintenance : lot collecté pour lʼancienne base non enregistré.'
    $dropped=0
    foreach($key in @($script:Persistence.Pending.Keys)){
        $item=$script:Persistence.Pending[$key]
        if(($null -eq $item) -or ([string]$item.Path -ceq $ActivePath)){continue}
        [void]$script:Persistence.Pending.Remove($key);$dropped++
        try{
            if(($item.Kind -eq 'StoreBatch') -and [string]$item.ErrorHandler){& ([string]$item.ErrorHandler) -Message $message -State $item.CallbackState}
            elseif(($item.Kind -eq 'IndexBulk') -and ($null -ne $item.Row) -and ($null -ne $item.Row.PSObject.Properties['RefreshOperationId']) -and [string]$item.Row.RefreshOperationId){Fail-DomeniaOuRefresh -OperationId ([string]$item.Row.RefreshOperationId) -Message $message}
        }catch{Write-AppLog ('Notification stockage : '+$_.Exception.Message) 'WARN'}
    }
    $hasLinkWork=[bool]$script:Persistence.LegacyImportJob
    foreach($value in @($script:Persistence.Pending.Values)){if(($value.Kind -eq 'Link') -or ($value.Kind -eq 'LegacyImport')){$hasLinkWork=$true;break}}
    $script:Persistence.LinkBusy=$hasLinkWork
    if($dropped -gt 0){Write-AppLog ([string]$dropped+' élément(s) en file pour lʼancienne base non enregistré(s) après la bascule.') 'WARN'}
    return $dropped
}
function Invoke-DomeniaStorageMaintenanceSwitch {
    # Switches the session to the verified copy named by a receipt. Shared by the worker completion and by the local
    # retry of a restore that wrote no marker (unreadable previous base).
    param($State,$Receipt)
    try{
        Switch-DomeniaDatabaseContext -Path ([string]$Receipt.TargetPath) -ExpectedPath $State.Path -ExpectedEpoch $State.Epoch -StoreId ([string]$Receipt.StoreId) -Revision ([long]$Receipt.Revision)
    }catch{
        # An undo that could not switch back leaves the session on the current base, which stays valid.
        if([string]$State.Mode -eq 'Undo'){Fail-DomeniaStorageMaintenance ('bascule vers la base précédente non confirmée : '+$_.Exception.Message) $State;return}
        $State.Locked=$true;$State.Hold=$true
        $offer='« Reprendre la bascule »';if([bool]$Receipt.RedirectWritten){$offer+=' ou « Revenir à la base précédente »'}
        $text='Copie locale conservée, bascule non confirmée : '+$_.Exception.Message+'. Utilisez '+$offer+' ; aucun fichier nʼest supprimé.'
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN';[void](Update-DomeniaStorageMaintenanceControls);return
    }
    # The switch has advanced the epoch. A presentation failure must never relock its obsolete context.
    $State.Locked=$false;$State.Hold=$false;$State.Recovery=$false
    $original=Get-DomeniaStorageMaintenanceMarkerPath $State
    # Point 31: a switch that left a marker on its original stays undoable until the new base receives a write.
    if(([string]$Receipt.Action -in @('Move','Restore','Resume')) -and [bool]$Receipt.RedirectWritten){
        $script:StorageLastSwitch=[pscustomobject]@{OperationId=[string]$State.Id;OriginalPath=$original;TargetPath=[string]$Receipt.TargetPath;DomainDn=[string]$State.DomainDn;Epoch=[long]$script:SessionEpoch}
    }else{$script:StorageLastSwitch=$null}
    $dropped=0;try{$dropped=Clear-DomeniaStoragePendingForOtherBase -ActivePath ([string]$Receipt.TargetPath)}catch{Write-AppLog ('File locale après bascule non vérifiée : '+$_.Exception.Message) 'WARN'}
    Request-DomeniaStorageWork
    $kept='Original conservé : '+$original
    if([bool]$Receipt.RedirectWritten){$kept='Original conservé en lecture seule : '+$original+' ; « Revenir à la base précédente » reste possible tant que la nouvelle base nʼa reçu aucune écriture'}
    elseif(-not [bool]$Receipt.ActiveReadable){$kept='Ancienne base illisible laissée intacte : '+$original}
    if([string]$Receipt.Action -eq 'Rollback'){$text='Base précédente rétablie : '+[string]$Receipt.TargetPath+'. Lʼautre fichier est conservé.'}else{$text='Étape 3 sur 3 : base vérifiée en service : '+[string]$Receipt.TargetPath+'. '+$kept+'.'}
    if($dropped -gt 0){$text+=' '+[string]$dropped+' élément(s) collecté(s) pendant la maintenance pour lʼautre base nʼont pas été enregistrés ; relisez-les si besoin.'}
    # Resume-DomeniaDatabaseViews refreshes the location summary; the space and limit lines of the same page follow the
    # new base (its free space stays unknown until its first measure).
    try{[void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text;Resume-DomeniaDatabaseViews -ReloadLocalState;Update-DomeniaStorageSpaceUi;Update-DomeniaStorageLimitsUi}catch{Write-AppLog ('Base basculée ; relecture des vues différée : '+$_.Exception.Message) 'WARN'}
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Complete-DomeniaStorageMaintenanceApply {
    param($Result,$State)
    if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return}
    try{
        $State.Job='';$r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Committed','OperationId','TargetPath')
        if(($null -eq $r) -or ($r.Kind -cne 'StorageMaintenance') -or (-not $r.Committed) -or ($r.OperationId -cne $State.Id) -or ([string]$r.ActivePath -cne (Get-DomeniaStorageMaintenanceMarkerPath $State)) -or ($r.DomainDn -ine $State.DomainDn) -or ($r.Integrity -cne 'ok') -or (-not $r.OriginalPreserved)){throw 'Copie ou bascule non confirmée. Conservez les deux fichiers.'}
        # A worker that wrote no marker (unreadable previous base) is retried locally; a marker always names this target.
        if($null -eq $r.PSObject.Properties['RedirectWritten']){$r|Add-Member -NotePropertyName RedirectWritten -NotePropertyValue $true}
        if($null -eq $r.PSObject.Properties['ActiveReadable']){$r|Add-Member -NotePropertyName ActiveReadable -NotePropertyValue $true}
        $State.Receipt=$r
    }catch{
        if([string]$State.Mode -eq 'Undo'){Fail-DomeniaStorageMaintenance $_.Exception.Message $State;return}
        $State.Locked=$true;$State.Hold=$true;$text='Copie locale conservée, bascule non confirmée : '+$_.Exception.Message+'. Utilisez « Reprendre la bascule » ou « Revenir à la base précédente ».'
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN';[void](Update-DomeniaStorageMaintenanceControls);return
    }
    Invoke-DomeniaStorageMaintenanceSwitch -State $State -Receipt $r
}
function Fail-DomeniaStorageMaintenance {
    param($Message,$State)
    if(($null -eq $State) -or ($State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return}
    $State.Job=''
    $reason=([string]$Message).Trim()
    if([string]$State.Mode -eq 'Undo'){
        # The undo writes nothing but the removal of the marker of the original, after its own checks: the session stays
        # on the current base, which remains valid whatever happened. The offer ends; both files are kept.
        $State.Locked=$false;$State.Hold=$false;$script:StorageLastSwitch=$null
        $text='Retour à la base précédente non effectué : '+$reason.TrimEnd('.')+'. La base actuelle reste en service ; les deux fichiers sont conservés.'
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN';[void](Update-DomeniaStorageMaintenanceControls);return
    }
    # The worker states when a move or restore refused before publishing anything: active base untouched, no marker,
    # temporary copy removed. Only that statement releases the lock; any other failure of a locked step (timeout,
    # lost completion, refusal after the copy) can be ambiguous and stays locked until an explicit resume or rollback.
    $nothingPublished=($reason -match 'StorageNothingPublished : ')
    if($nothingPublished){$reason=($reason -replace '^.*?StorageNothingPublished : ','');$State.Locked=[bool]$State.Recovery}
    # A failed inspection changed nothing and releases the collections.
    if(-not [bool]$State.Locked){$State.Hold=[bool]$State.Recovery}
    $text='Maintenance locale interrompue : '+$reason.TrimEnd('.')+'. Aucun original supprimé.'
    if($nothingPublished -and (-not [bool]$State.Recovery)){$text='Maintenance locale non effectuée : '+$reason.TrimEnd('.')+'. Aucune copie publiée ; base actuelle conservée et collectes rétablies.'}
    elseif([bool]$State.Locked -and (-not [bool]$State.Recovery)){$text+=' Utilisez « Revenir à la base précédente » pour rétablir les collectes, ou « Reprendre la bascule ».'}
    elseif([bool]$State.Recovery){$text+=' La base illisible reste en place ; choisissez une autre sauvegarde vérifiée.'}
    [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN'
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Resume-DomeniaStorageMaintenance {
    param([switch]$Rollback)
    $state=$script:StorageMaintenance
    if($Rollback -and (($null -eq $state) -or (-not [bool]$state.Locked))){
        # Point 31: back to the original of a completed switch of this session, only while the new base is unchanged.
        $undo=Get-DomeniaStorageMaintenanceUndo
        if($null -eq $undo){Set-Status 'Aucune bascule à annuler pour la base active.';return}
        $start=${function:Start-DomeniaStorageMaintenanceUndo}
        Request-DomeniaInlineConfirmation -Title 'Revenir à la base précédente' -Target ([string]$undo.OriginalPath) -Message ('Revenir au fichier dʼorigine '+[string]$undo.OriginalPath+' uniquement si la base actuelle nʼa reçu aucune écriture depuis la bascule. Les deux fichiers sont conservés.') -ConfirmText 'Vérifier et revenir' -CancelText 'Garder la base actuelle' -OnConfirm ({& $start -Undo $undo}.GetNewClosure()) -OnCancel {Set-Status 'Base actuelle conservée.'}
        return
    }
    if(($null -eq $state) -or (-not [bool]$state.Locked) -or $state.Job -or [bool]$state.Draining){Set-Status 'Aucune bascule interrompue à reprendre.';return}
    if(($null -ne $state.Receipt) -and (-not [bool]$state.Receipt.RedirectWritten)){
        if($Rollback){Set-Status 'Aucun marqueur de bascule : la base précédente, illisible, nʼa pas été modifiée. Reprenez la bascule ou restaurez une autre sauvegarde.' 'WARN';return}
        # Point 34: a restore over an unreadable base wrote no marker; the verified copy is switched to again locally.
        $switch=${function:Invoke-DomeniaStorageMaintenanceSwitch};$receipt=$state.Receipt
        Request-DomeniaInlineConfirmation -Title 'Reprendre la bascule' -Target ([string]$receipt.TargetPath) -Message 'Vérifier lʼidentité de la base restaurée puis lʼutiliser. Les deux fichiers sont conservés.' -ConfirmText 'Vérifier et continuer' -CancelText 'Conserver en attente' -OnConfirm ({& $switch -State $state -Receipt $receipt}.GetNewClosure()) -OnCancel {Set-Status 'Reprise différée.'}
        return
    }
    $start=${function:Start-DomeniaStorageMaintenanceApply};$mode=if($Rollback){'Rollback'}else{'Resume'}
    $text=if($Rollback){'Revenir au fichier dʼorigine uniquement si la copie nʼa reçu aucune nouvelle écriture. Les deux fichiers sont conservés.'}else{'Vérifier la copie et reprendre la bascule interrompue. Les deux fichiers sont conservés.'}
    Request-DomeniaInlineConfirmation -Title 'Reprendre la maintenance locale' -Target $state.TargetPath -Message $text -ConfirmText 'Vérifier et continuer' -CancelText 'Conserver en attente' -OnConfirm ({& $start -State $state -Recovery $mode}.GetNewClosure()) -OnCancel {Set-Status 'Reprise différée.'}
}
function Start-DomeniaStorageMaintenanceUndo {
    # Point 31: undo of a completed switch. Nothing may be pending or running (a write would close the undo window);
    # the worker removes the marker of the original only if the current base is unchanged since the switch, then the
    # session switches back. Collections wait behind the lock meanwhile.
    param($Undo)
    try{
        $current=Get-DomeniaStorageMaintenanceUndo
        if(($null -eq $Undo) -or ($null -eq $current) -or ([string]$Undo.OperationId -cne [string]$current.OperationId)){throw 'bascule à annuler modifiée.'}
        $busy=$script:StorageMaintenance
        if(($null -ne $busy) -and ([bool]$busy.Locked -or [bool]$busy.Draining -or [string]$busy.Job)){throw 'une étape de maintenance est déjà en cours.'}
        $state=[pscustomobject]@{Id=[string]$current.OperationId;Mode='Undo';Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;MarkerPath=[string]$current.OriginalPath;DomainDn=[string]$current.DomainDn;SourcePath=[string]$current.OriginalPath;TargetPath=[string]$current.TargetPath;Fingerprint='';Job='';Locked=$false;Recovery=$false;Hold=$true;HoldUntil=[datetime]::UtcNow.AddMinutes(10);Draining=$false;DrainNext='';DrainUntil=[datetime]::MinValue;Receipt=$null}
        $script:StorageMaintenance=$state
        Start-DomeniaStorageMaintenanceApply -State $state -Recovery 'Rollback'
        if(-not [string]$state.Job){$state.Locked=$false;$state.Hold=$false}
    }catch{Set-Status ('Retour à la base précédente impossible : '+$_.Exception.Message) 'WARN'}
    [void](Update-DomeniaStorageMaintenanceControls)
}

function Get-DomeniaCurrentStoragePolicy {
    $value=$null;$json=[string](Get-DomeniaSetting 'Storage.PolicyJson' '')
    if($json){$value=ConvertFrom-Json -InputObject $json -ErrorAction Stop}
    return ConvertTo-DomeniaStoragePolicy $value
}
function Save-DomeniaStoragePolicy {
    $previous=[string](Get-DomeniaSetting 'Storage.PolicyJson' '');$changed=$false
    try{
        $value=[ordered]@{Version=1;AutomaticBackup=[bool](Get-DomeniaControl 'ChkStorageAutoBackup').IsChecked}
        foreach($name in @('BackupHours','BackupKeep','PresenceDays','ConsoleDays','InventoryDays','ProbeDays','DetailDays','LinkHistoryDays')){$value[$name]=[string](Get-DomeniaControl ('TxtStorage'+$name)).Text}
        $policy=ConvertTo-DomeniaStoragePolicy ([pscustomobject]$value)
        Set-DomeniaSetting 'Storage.PolicyJson' ($policy|ConvertTo-Json -Compress);$changed=$true
        Save-DomeniaSettings -Immediate -ThrowOnFailure
        Initialize-DomeniaStoragePolicy
        Set-Status 'Politique locale enregistrée. La conservation ne sʼapplique quʼaprès prévisualisation et confirmation.'
    }catch{if($changed){Set-DomeniaSetting 'Storage.PolicyJson' $previous};Set-Status ('Reglages de stockage non appliques : '+$_.Exception.Message) 'WARN'}
}
function Initialize-DomeniaStoragePolicy {
    $policy=Get-DomeniaCurrentStoragePolicy
    $control=Get-DomeniaControl 'ChkStorageAutoBackup';if($control){$control.IsChecked=$policy.AutomaticBackup}
    foreach($name in @('BackupHours','BackupKeep','PresenceDays','ConsoleDays','InventoryDays','ProbeDays','DetailDays','LinkHistoryDays')){$control=Get-DomeniaControl ('TxtStorage'+$name);if($control){$control.Text=[string]$policy.$name}}
    if($null -eq $script:StorageBackupTimer){$script:StorageBackupTimer=New-DomeniaTimer -Owner 'Timer:StorageBackupPolicy' -IntervalMs 60000 -RunWhenHidden -Tick {Invoke-DomeniaScheduledBackup}}
    if($policy.AutomaticBackup){$script:StorageBackupTimer.Start()}else{$script:StorageBackupTimer.Stop()}
    Update-DomeniaStorageBackupScheduleUi
    $control=Update-DomeniaStorageMaintenanceControls
    if($null -eq $script:StorageMaintenance){[void](Set-DomeniaControlText 'LblStorageMaintenance' ([string]$control.Text))}
    Update-DomeniaStorageSpaceUi
    Update-DomeniaStorageLimitsUi
    # Point 147: the local data policy shows the retention just saved.
    try{Initialize-DomeniaDataPolicyView}catch{Write-AppLog ('Politique des données non affichée : '+$_.Exception.Message) 'WARN'}
}
function Get-DomeniaStorageBackupKey {
    # Settings key of the active base for its backup receipts; '' without an active base.
    $path=[string]$script:DatabaseScopedPath
    if((-not $path) -or (-not [string]$script:Conn.BaseDn)){return ''}
    return Get-DomeniaStoreId $path ([string]$script:Conn.BaseDn)
}
function Test-DomeniaStorageBackupBusy {
    # The automatic backup waits for any maintenance step, pending local write or running task.
    if(Test-DomeniaStorageMaintenanceHold){return $true}
    if(Test-DomeniaStorageWorkPending){return $true}
    return (@($script:AsyncJobs.Values|Where-Object{$null -ne $_}).Count -gt 0)
}
function Update-DomeniaStorageBackupScheduleUi {
    # Point 33: frequency, next trigger, last verified success (quick_check and SHA-256 of the produced file) and last
    # failure of this session, for the active base.
    try{
        $key=Get-DomeniaStorageBackupKey
        if(-not $key){[void](Set-DomeniaControlText 'LblStorageBackupSchedule' 'Aucune base locale active : aucune sauvegarde planifiée.');return}
        $detail=$null;$json=[string](Get-DomeniaSetting ('Storage.Backup.LastDetail.'+$key) '')
        if($json){try{$detail=ConvertFrom-Json -InputObject $json -ErrorAction Stop}catch{$detail=$null}}
        $attempt='';if(($null -ne $script:StorageBackupAttempts) -and $script:StorageBackupAttempts.ContainsKey($key)){$attempt=[string]$script:StorageBackupAttempts[$key]}
        $failure=$null;if(($null -ne $script:StorageBackupFailures) -and $script:StorageBackupFailures.ContainsKey($key)){$failure=$script:StorageBackupFailures[$key]}
        $schedule=Get-DomeniaStorageBackupSchedule -Policy (Get-DomeniaCurrentStoragePolicy) -LastSuccessUtc ([string](Get-DomeniaSetting ('Storage.Backup.Last.'+$key) '')) -LastAttemptUtc $attempt -LastDetail $detail -LastFailure $failure -Busy (Test-DomeniaStorageBackupBusy)
        [void](Set-DomeniaControlText 'LblStorageBackupSchedule' $schedule.Text)
    }catch{[void](Set-DomeniaControlText 'LblStorageBackupSchedule' ('État des sauvegardes indisponible : '+$_.Exception.Message))}
}
function Invoke-DomeniaScheduledBackup {
    if([bool]$script:DemoMode -or -not [string]$script:DatabaseScopedPath -or $script:AsyncEngineClosing -or $script:StorageAutoBackupJob){return}
    try{
        $policy=Get-DomeniaCurrentStoragePolicy;$path=[string]$script:DatabaseScopedPath;$key=Get-DomeniaStoreId $path ([string]$script:Conn.BaseDn)
        $busy=Test-DomeniaStorageBackupBusy
        # Persistence.LastSavedAt does not cover every writer or another process: never infer an unchanged DB from it.
        $dirty=$null
        $last=[string](Get-DomeniaSetting ('Storage.Backup.Last.'+$key) '')
        $attempt='';if($null -ne $script:StorageBackupAttempts -and $script:StorageBackupAttempts.ContainsKey($key)){$attempt=[string]$script:StorageBackupAttempts[$key]}
        $decision=Get-DomeniaStorageBackupDecision -Policy $policy -LastSuccessUtc $last -LastAttemptUtc $attempt -DirtyUtc $dirty -Busy $busy
        if(-not $decision.Due){return}
        if($null -eq $script:StorageBackupAttempts){$script:StorageBackupAttempts=@{}};$script:StorageBackupAttempts[$key]=[datetime]::UtcNow.ToString('o')
        $payload=New-DomeniaBackupPayload -Path $path -BudgetSeconds 120
        $state=[pscustomobject]@{CopyTo='';Path=$path;Epoch=[long]$script:SessionEpoch;Automatic=$true;StoreKey=$key}
        $script:StorageAutoBackupJob=Start-UiTask -Name 'Sauvegarde locale planifiée' -OperationId 'StorageBackup' -Code (Get-DomeniaStorageBackupWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaIndexBackupUi' -ErrorHandler 'Fail-DomeniaIndexBackupUi' -ReplaceKey 'storage:backup' -TimeoutSeconds 150 -TaskClass 'Background'
        if(-not $script:StorageAutoBackupJob){throw 'Sauvegarde planifiée non admise.'}
    }catch{
        $text='Sauvegarde planifiée différée : '+$_.Exception.Message
        try{Register-DomeniaBackupFailure -Path ([string]$script:DatabaseScopedPath) -Message ([string]$_.Exception.Message)}catch{Write-AppLog ('Échec de sauvegarde non mémorisé : '+$_.Exception.Message) 'WARN'}
        Set-Status $text 'WARN'
    }finally{Update-DomeniaStorageBackupScheduleUi}
}

function Request-DomeniaStorageRecovery {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$DomainDn)
    try{
        $path=Get-DomeniaLocalDatabasePath $Path -Existing
        $state=[pscustomobject]@{Path=$path;DomainDn=$DomainDn;Epoch=[long]$script:SessionEpoch}
        $payload=[pscustomobject]@{Action='ReadRedirect';ActivePath=$path;SourcePath=$path;DomainDn=$DomainDn}
        return Start-UiTask -Name 'Retrouver une maintenance locale interrompue' -OperationId 'StorageMaintenance' -Code (Get-DomeniaStorageMaintenanceWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageRecovery' -ErrorHandler 'Fail-DomeniaStorageRecovery' -TimeoutSeconds 180 -TaskClass 'Explicit'
    }catch{Set-Status ('Reprise locale indisponible : '+$_.Exception.Message) 'WARN';return $null}
}
function Complete-DomeniaStorageRecovery {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath -or $State.DomainDn -ine [string]$script:Conn.BaseDn){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Action','ActivePath','Redirect')
        if($null -eq $r -or $r.Kind -cne 'StorageMaintenance' -or $r.Action -cne 'ReadRedirect' -or $r.ActivePath -cne $State.Path -or $r.DomainDn -ine $State.DomainDn){throw 'Lecture de reprise non confirmée.'}
        if($null -eq $r.Redirect){
            # The marker that refused the start is gone (resolved elsewhere): release the startup lock, nothing to resume.
            if(($null -ne $script:StorageMaintenance) -and ([string]$script:StorageMaintenance.Id -ceq 'recovery-pending')){$script:StorageMaintenance.Locked=$false;$script:StorageMaintenance.Hold=$false}
            Set-Status 'Aucune redirection en attente dans cette base.';[void](Update-DomeniaStorageMaintenanceControls);return
        }
        $redirect=$r.Redirect
        $id=[guid]::Empty;if(-not [guid]::TryParse([string]$redirect.OperationId,[ref]$id) -or $id -eq [guid]::Empty){throw 'Identifiant de reprise invalide.'}
        $target=Get-DomeniaLocalDatabasePath ([string]$redirect.TargetPath)
        if([string]$redirect.StoreId -cne (Get-DomeniaStoreId $target $State.DomainDn)){throw 'Identité de reprise incohérente.'}
        $script:StorageMaintenance=[pscustomobject]@{Id=$id.ToString('D');Mode='Move';Epoch=$State.Epoch;Path=$State.Path;DomainDn=$State.DomainDn;SourcePath=$State.Path;TargetPath=$target;Fingerprint='';Job='';Locked=$true;Recovery=$false;Hold=$true;Draining=$false;DrainNext='';DrainUntil=[datetime]::MinValue;Receipt=$null}
        $text='Bascule locale interrompue détectée. Original : '+$State.Path+'. Copie : '+$target+'. Utilisez « Reprendre la bascule » ou « Revenir à la base précédente » ; aucun fichier ne sera supprimé.'
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN'
    }catch{Fail-DomeniaStorageRecovery $_.Exception.Message $State}
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Fail-DomeniaStorageRecovery {
    param($Message,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    Set-Status ('Reprise locale non confirmee : '+[string]$Message+'. Les fichiers sont conserves.') 'WARN'
}

function Start-DomeniaStorageRetention {
    param([switch]$Apply,$Preview=$null)
    try{
        Assert-DomeniaStoragePurgeReady
        if(Test-DomeniaStorageMaintenanceHold){throw 'Une maintenance est en attente.'}
        $policy=Get-DomeniaCurrentStoragePolicy;$policyKey=$policy|ConvertTo-Json -Compress
        if($Apply){
            if($null -eq $Preview -or $null -eq $script:StorageRetentionPreview -or $Preview.State.Id -cne $script:StorageRetentionPreview.State.Id -or $Preview.State.Epoch -ne [long]$script:SessionEpoch -or $Preview.State.Path -cne [string]$script:DatabaseScopedPath -or $Preview.State.PolicyKey -cne $policyKey){throw 'Previsualisation absente ou reglage modifie.'}
            $state=$Preview.State;$state.DryRun=$false;$state.ExpectedFingerprint=[string]$Preview.Result.Fingerprint
        }else{
            # Point 37: one cutoff per family (LinkHistory compacts repeated observations), '' keeps a family unlimited.
            $cutoffs=Get-DomeniaStorageRetentionCutoffs -Policy $policy -NowUtc ([datetime]::UtcNow)
            $path=[string]$script:DatabaseScopedPath;$domain=[string]$script:Conn.BaseDn
            $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Mode='Retention';Path=$path;DomainDn=$domain;StoreId=(Get-DomeniaStoreId $path $domain);Epoch=[long]$script:SessionEpoch;PolicyKey=$policyKey;Cutoffs=$cutoffs;DryRun=$true;ExpectedFingerprint='';Locked=$false;Job=''}
        }
        $script:StorageRetentionPreview=$null;$button=Get-DomeniaControl 'BtnStorageRetentionApply';if($button){$button.IsEnabled=$false}
        $payload=[pscustomobject]@{Path=$state.Path;DomainDn=$state.DomainDn;StoreId=$state.StoreId;Cutoffs=$state.Cutoffs;DryRun=$state.DryRun;ExpectedFingerprint=$state.ExpectedFingerprint}
        if($Apply){$state.Locked=$true;$script:StorageMaintenance=$state}
        $state.Job=Start-UiTask -Name $(if($Apply){'Sauvegarder puis appliquer la conservation'}else{'Prévisualiser la conservation par famille'}) -OperationId 'StorageRetention' -Code (Get-DomeniaStorageRetentionWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageRetention' -ErrorHandler 'Fail-DomeniaStorageRetention' -TimeoutSeconds 300 -NonCancellable -TaskClass 'Explicit'
        if(-not $state.Job){$state.Locked=$false;throw 'Operation de conservation non admise.'}
    }catch{Set-Status ('Conservation non lancee : '+$_.Exception.Message) 'WARN'}
    # Point 32: an applied retention holds the base like the assistant; its buttons wait for the end.
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Request-DomeniaStorageRetention {
    try{
        Assert-DomeniaStoragePurgeReady;$preview=$script:StorageRetentionPreview
        if($null -eq $preview -or $preview.State.Epoch -ne [long]$script:SessionEpoch -or $preview.State.Path -cne [string]$script:DatabaseScopedPath){throw 'Refaites la previsualisation avant de confirmer.'}
        $start=${function:Start-DomeniaStorageRetention}
        Request-DomeniaInlineConfirmation -Title 'Appliquer la conservation des mesures' -Target $preview.State.Path -Message ($preview.Text+[Environment]::NewLine+'Une sauvegarde vérifiée est créée avant toute suppression. Aucun objet AD, compte, requête, journal ni reçu nʼest supprimé.') -ConfirmText 'Sauvegarder puis retirer ces données anciennes' -CancelText 'Conserver les mesures' -OnConfirm ({& $start -Apply -Preview $preview}.GetNewClosure()) -OnCancel {Set-Status 'Conservation inchangee.'}
    }catch{Set-Status ('Conservation non confirmee : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaStorageRetention {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath){return}
    try{
        $State.Job='';$r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Path','StoreId','Counts','Fingerprint')
        if($null -eq $r -or $r.Kind -cne 'StorageRetention' -or $r.Path -cne $State.Path -or $r.StoreId -cne $State.StoreId -or $r.DomainDn -ine $State.DomainDn -or $r.DryRun -isnot [bool] -or $r.Committed -isnot [bool] -or $r.DryRun -ne $State.DryRun -or $r.Committed -eq $r.DryRun -or [string]$r.Fingerprint -cnotmatch '^[a-f0-9]{64}$' -or -not $r.ReceiptsPreserved){throw 'Resultat de conservation non confirme.'}
        $families=@(Get-DomeniaStorageRetentionFamilies|ForEach-Object{[string]$_.Family})
        $seen=@{};$sum=0L
        foreach($row in @($r.Counts)){
            $n=0L;$family=[string]$row.Family
            if(($family -notin $families) -or $seen.ContainsKey($family) -or (-not [string]$State.Cutoffs.$family) -or ([string]$row.CutoffUtc -cne [string]$State.Cutoffs.$family) -or (-not [long]::TryParse([string]$row.Rows,[ref]$n)) -or ($n -lt 0)){throw 'Comptage par famille non conforme.'}
            $seen[$family]=$true;$sum+=$n
        }
        foreach($family in $families){if([string]$State.Cutoffs.$family -and -not $seen.ContainsKey($family)){throw 'Famille absente du comptage.'}}
        # Point 37: the loss of detail of each family is announced before anything is removed.
        $text=@(Get-DomeniaStorageRetentionLines -Counts @($r.Counts) -Cutoffs $State.Cutoffs -SkippedLegacyRows ([long]$r.SkippedLegacyRows) -DryRun ([bool]$State.DryRun)) -join [Environment]::NewLine
        if($State.DryRun){
            $script:StorageRetentionPreview=[pscustomobject]@{State=$State;Result=$r;Text=$text}
            $button=Get-DomeniaControl 'BtnStorageRetentionApply';if($button){$button.IsEnabled=($sum -gt 0)}
            [void](Set-DomeniaControlText 'LblStorageRetention' ('Prévisualisation : aucune suppression.'+[Environment]::NewLine+$text))
        }else{
            if($r.Fingerprint -cne $State.ExpectedFingerprint -or [long]$r.DeletedRows -ne $sum -or $null -eq $r.Backup -or -not $r.Backup.Verified -or [string]$r.Backup.SHA256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Suppression ou sauvegarde non confirmee.'}
            $State.Locked=$false;$script:StorageRetentionPreview=$null
            [void](Set-DomeniaControlText 'LblStorageRetention' ($text+[Environment]::NewLine+'Sauvegarde vérifiée avant suppression : '+$r.Backup.Path))
            Set-Status ('Conservation appliquée : '+$r.DeletedRows+' ligne(s) retirée(s) ; sauvegarde vérifiée conservée.')
            Reset-DomeniaStorageObservationViews -Revision ([long]$r.Revision)
        }
    }catch{Fail-DomeniaStorageRetention $_.Exception.Message $State}
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Fail-DomeniaStorageRetention {
    param($Message,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath){return}
    $State.Job='';$State.Locked=$false;$script:StorageRetentionPreview=$null
    $text='Conservation non confirmee : '+[string]$Message+'. Aucun rejeu automatique ; refaites la previsualisation.'
    [void](Set-DomeniaControlText 'LblStorageRetention' $text);Set-Status $text 'WARN'
    if(-not $State.DryRun){try{Reset-DomeniaStorageObservationViews}catch{Write-AppLog ('Relecture apres conservation differee : '+$_.Exception.Message) 'WARN'}}
    [void](Update-DomeniaStorageMaintenanceControls)
}
function Reset-DomeniaStorageObservationViews {
    param([long]$Revision=0)
    $script:StoreSnapshotRevision=[Math]::Max([long]$script:StoreSnapshotRevision,$Revision)
    $script:PresenceCache=@{};$script:ParkState=@{};$script:FleetObservations=$null;$script:FleetSelectedReads=@{};$script:FleetStale=$true;$script:FleetQuerySnapshotKey='';$script:SearchQueryRun=$null;$script:VisitCache=@{}
    if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.Generation++;$script:DomeniaQueryState.Records=$null;$script:DomeniaQueryState.Widgets=@{};$script:DomeniaQueryState.SearchRecords=@{};$script:DomeniaQueryState.SearchSnapshotKey=''}
    if($null -ne $script:Live){
        $script:Live.Observations.Clear();$script:Live.ObservationsLoaded=$false;$script:Live|Add-Member -NotePropertyName ObservationReadKey -NotePropertyValue '' -Force
        # Only a StoreRead is scheduled; a retention action never starts a network probe.
        if($null -ne $script:Live.Search -and $null -ne $script:Live.Search.State){
            $search=$script:Live.Search.State;$readKey=[string]$script:GlobalSearchGeneration+'|'+[string]$search.BaseDn+'|'+[string]$search.Scope
            $state=[pscustomobject]@{Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:GlobalSearchGeneration;ReadKey=$readKey;Offset=0;ScopeDn=[string]$search.BaseDn;Subtree=([string]$search.Scope -ne 'OneLevel')}
            [void](Initialize-DomeniaRemoteStoreState -State $state -Guid '' -DN $state.ScopeDn -Generation $state.Generation -ReadOnly)
            $job=Request-DomeniaStoreRead -Context $state.StoreContext -Query ([pscustomobject]@{Kind='Observation';ScopeDn=$state.ScopeDn;Subtree=$state.Subtree;Offset=0;Limit=250}) -SuccessHandler 'Complete-DomeniaLiveObservationRead' -ErrorHandler 'Fail-DomeniaLiveObservationRead' -CallbackState $state
            if($job){$script:Live.ObservationReadKey=$readKey}
        }
    }
    try{[void](Request-DomeniaSelectedObservation -Force -MinimumRevision $Revision)}catch{Write-AppLog ('Relecture du poste differee : '+$_.Exception.Message) 'WARN'}
    Resume-DomeniaDatabaseViews
}
