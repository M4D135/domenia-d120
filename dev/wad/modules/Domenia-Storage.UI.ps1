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
    if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.Contains($key)){Set-Status 'Cache en attente sature. Les donnees restent visibles mais non enregistrees.' 'WARN';return $false}
    $script:Persistence.Pending[$key]=[pscustomobject]@{QueueKey=$key;Kind='Index';Path=[string]$script:DatabaseScopedPath;Row=$Row;Server=[string]$script:Conn.Server;At=[datetime]::UtcNow.ToString('o');Epoch=[long]$script:SessionEpoch}
    Request-DomeniaStorageWork
    return $true
}
function Request-DomeniaStorageWork {
    # Canonical batches already have a bounded collection window. Do not add a one-second delay per receipt.
    # The same queue/timer remains the sole writer; legacy deltas retain their debounce and failure backoff.
    if($null -eq $script:Persistence -or $null -eq $script:Persistence.Timer){return}
    $interval=1000
    if(-not $script:Persistence.Job -and [int]$script:Persistence.Failures -eq 0){
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
    # D028: the associations were reloaded from disk (Load-UserMachineLinks, at startup or through Comptes > Changer de
    # compte): the conflict state ends here.
    if($null -ne $script:Persistence -and $null -ne $script:Persistence.PSObject.Properties['Conflicts']){$script:Persistence.Conflicts=@{}}
    foreach($l in @($script:UserMachineLinks)){$key=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant();if($key){$script:LinkBaseline[$key]=ConvertTo-DomeniaLinkRecord $l}}
}
function Queue-DomeniaLinkChanges {
    param([switch]$Quiet,[int]$MaxItems=0)
    if($MaxItems -lt 0){$MaxItems=0}
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    $script:Persistence.LinkPersistenceMore=$false
    if($script:Persistence.LinkBusy){
        if(-not $Quiet){Set-Status 'Enregistrement des liens encore actif. Attendez son resultat avant une nouvelle modification.' 'WARN'}
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
    if((-not $Quiet) -and $queued){Set-Status ($queued.ToString()+' lien(s) en memoire, enregistrement en arriere-plan en attente.')}
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
                Fail-DomeniaStorageWork 'Résultat de sauvegarde non reçu ; vérifiez la base puis reprenez les sauvegardes dans Fiabilité.' ([pscustomobject]@{Items=@($lost)})
                return
            }
        }
        if($script:Persistence.LegacyImportJob){
            $script:Persistence.LegacyImportJob=''
            Set-Status 'Resultat reprise des anciennes donnees non recu. Verifiez le stockage puis refaites la simulation avant toute nouvelle demande.' 'WARN'
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
            Set-Status 'Reprise des anciennes donnees impossible : base du contexte non disponible.' 'ERROR'
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
            Set-Status ('Reprise des anciennes donnees impossible au depart : '+$_.Exception.Message) 'ERROR'
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
    $bulk=@($items|Where-Object{$_.Kind -in @('IndexBulk','StoreBatch')}|Select-Object -First 1)
    if($bulk.Count){
        if($items[0].Kind -in @('IndexBulk','StoreBatch')){$items=@($bulk[0])}
        else{
            # Preserve queue order: older individual rows must commit before a newer complete rebuild.
            $prefix=[Collections.Generic.List[object]]::new()
            foreach($item in $items){if($item.Kind -in @('IndexBulk','StoreBatch')){break};$prefix.Add($item)}
            $items=$prefix.ToArray();$bulk=@()
        }
    }
    $storageTimeout=120
    if($bulk.Count -and $bulk[0].Kind -eq 'IndexBulk'){$storageTimeout=[Math]::Min(3600,[Math]::Max(120,60+[int]([long]$bulk[0].Row.RowCount/500)))}
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
    if($isImport){$script:Persistence.LegacyImportJob=''}
    foreach($i in $items){
        if($i.Kind -eq 'LegacyImport'){
            if($i.Epoch -ne [long]$script:SessionEpoch -or [string]$i.Path -cne [string]$script:DatabaseScopedPath){
                Add-DomeniaUiLog -Area 'Import' -Text 'Reprise des anciennes donnees ignore : epoch ou chemin obsolette.'
                continue
            }
            if([bool]$r.Already){
                Set-Status 'Reprise des anciennes donnees deja applique : rien a reprendre.'
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
            [void](Load-DomeniaIndexMetadata)
            $summary='Reprise des anciennes donnees applique : '+[int]$r.Imported.Objects+' objet(s), '+[int]$r.Imported.Park+' poste(s), '+[int]$r.Imported.UserScans+' recherche(s), '+[int]$r.Imported.Secrets+' metadonnee(s), '+$links.Count+' lien(s), '+$conflicts.Count+' association(s) existante(s) conservee(s).'
            Set-Status $summary $(if($conflicts.Count){'WARN'}else{'INFO'})
            Add-DomeniaUiLog -Area 'Import' -Text $summary
            continue
        }
        if($i.Kind -ne 'Link'){continue}
        if($i.Epoch -ne [long]$script:SessionEpoch){continue}
        if(@($r.Conflicts) -contains $i.Key){$script:Persistence.Conflicts[[string]$i.Key]=$true;Set-Status ('Association modifiee ailleurs : '+$i.Key+'. Votre version n a pas ecrase celle du disque. Rechargez les associations : Comptes > Changer de compte, ou redemarrage.') 'WARN';continue}
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
        try{[void](Load-DomeniaIndexMetadata);Update-DomeniaIndexStats}catch{}
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
}
function Fail-DomeniaStorageWork {
    param($Message,$State)
    if($null -eq $script:Persistence){return}
    $script:Persistence|Add-Member -NotePropertyName InFlightItems -NotePropertyValue @() -Force
    $items=@();if($null -ne $State){$items=@($State.Items)}
    foreach($storeItem in @($items|Where-Object{$_.Kind -eq 'StoreBatch'})){
        try { & ([string]$storeItem.ErrorHandler) -Message ([string]$Message) -State $storeItem.CallbackState } catch { Write-AppLog ('Notification stockage : '+$_.Exception.Message) 'WARN' }
    }
    # An automatic save retry may preserve the base, but must never launch a remote follow-up after a failed receipt.
    foreach($item in $items){if($item.Kind -eq 'IndexBulk' -and $null -ne $item.Row -and $null -ne $item.Row.PSObject.Properties['RefreshOperationId'] -and [string]$item.Row.RefreshOperationId){Fail-DomeniaOuRefresh -OperationId ([string]$item.Row.RefreshOperationId) -Message ('Écriture locale non confirmée : '+[string]$Message)}}
    $isImport=@($items|Where-Object{$_.Kind -eq 'LegacyImport'}).Count -gt 0
    if($isImport){
        $script:Persistence.Job='';$script:Persistence.InFlight=0
        $script:Persistence.LegacyImportJob=''
        foreach($i in $items){if($script:Persistence.Pending.Contains($i.QueueKey)){[void]$script:Persistence.Pending.Remove($i.QueueKey)}}
        $script:Persistence.Fault=[string]$Message
        Set-Status ('Reprise des anciennes donnees echoue, sans rejeu automatique. Refaites la simulation avant une nouvelle demande : '+[string]$Message) 'ERROR'
        Add-DomeniaUiLog -Area 'Import' -Text ('Reprise des anciennes donnees echoue : '+[string]$Message) -Level 'ERROR'
        $hasLinkWork=$false
        if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
        foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
        $script:Persistence.LinkBusy=$hasLinkWork
        return
    }
    $script:Persistence.Failures++;$script:Persistence.Job='';$script:Persistence.InFlight=0;$script:Persistence.Fault=[string]$Message;$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(15)
    $diskFull=([string]$Message -match 'StorageInsufficientSpace|SQLite (?:code|step code) 13(?:\D|$)')
    if($diskFull){$script:Persistence.Failures=[Math]::Max(3,[int]$script:Persistence.Failures)}
    # Retry older batches first; appending them could replay an old full rebuild after a newer OU update.
    $retry=[ordered]@{}
    foreach($i in $items){if(-not $script:Persistence.Pending.Contains($i.QueueKey)){$retry[$i.QueueKey]=$i}}
    foreach($entry in $script:Persistence.Pending.GetEnumerator()){$retry[$entry.Key]=$entry.Value}
    $script:Persistence.Pending=$retry
    if(@($items|Where-Object{$_.Kind -eq 'IndexBulk'}).Count){Set-DomeniaIndexProgress -Mode Error -Message ('Enregistrement non confirmé : '+[string]$Message+'. Le lot reste en attente.')}
    Request-DomeniaStorageWork
    if($diskFull){
        if($null -ne $script:IndexWalk){Complete-DomeniaIndexWalkUi -Aborted -Detail 'Stockage suspendu : espace disque insuffisant. Les lots non enregistres sont conserves en attente.'}
        Set-Status 'Stockage suspendu : espace disque insuffisant. Les lots restent en mémoire ; liberez de la place puis Reprendre les sauvegardes dans Fiabilite.' 'WARN';return
    }
    if($script:Persistence.Failures -ge 3){
        if($null -ne $script:IndexWalk){Complete-DomeniaIndexWalkUi -Aborted -Detail 'Stockage suspendu après trois échecs. Reprenez les sauvegardes avant de relancer les lectures.'}
        Set-Status 'Cache non enregistre : trois echecs. Les donnees restent en memoire ; corrigez le stockage puis Reprendre les sauvegardes dans Fiabilite.' 'WARN';return}
    Set-Status 'Cache non enregistre sur disque. Les observations sont encore en memoire ; une nouvelle tentative bornee sera faite.' 'WARN'
}
function Queue-DomeniaMetadata {
    param([ValidateSet('Presence','UserScan','Park','ParkSession','SecretMeta','Sample','IndexBulk','LegacyImport','FleetSnapshot')][string]$Kind,$Row,[string]$Key='')
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    if(-not $script:DatabaseScopedPath){return $false}
    if($Kind -eq 'LegacyImport'){
        if($null -eq $Row){Set-Status 'Reprise des anciennes donnees impossible : donnees absentes.' 'WARN';return $false}
        $marker=[string]$Row.Marker
        $baseDn=[string]$Row.BaseDn
        if([string]::IsNullOrWhiteSpace($marker)){Set-Status 'Reprise des anciennes donnees impossible : marqueur absent.' 'WARN';return $false}
        if([string]::IsNullOrWhiteSpace($baseDn) -or $baseDn -notmatch '(?i)DC='){Set-Status 'Reprise des anciennes donnees impossible : domaine absent.' 'WARN';return $false}
        if($script:Persistence.LinkBusy){Set-Status 'Reprise des anciennes donnees impossible : enregistrement des liens en cours.' 'WARN';return $false}
        if($script:Persistence.LegacyImportJob){Set-Status 'Reprise des anciennes donnees deja en cours.' 'WARN';return $false}
        foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){Set-Status 'Reprise des anciennes donnees impossible : modifications de liens en attente.' 'WARN';return $false}}
        if(-not $Key){$Key=$marker}
        $queueKey='LegacyImport|'+[string]$script:DatabaseScopedPath+'|'+$Key
        if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.Contains($queueKey)){Set-Status 'File locale pleine : reprise des anciennes donnees non enregistre.' 'WARN';return $false}
        $script:Persistence.Pending[$queueKey]=[pscustomobject]@{QueueKey=$queueKey;Kind=$Kind;Path=[string]$script:DatabaseScopedPath;Row=$Row;Epoch=[long]$script:SessionEpoch}
        $script:Persistence.LinkBusy=$true
        Request-DomeniaStorageWork
        return $true
    }
    if(-not $Key){$Key=[guid]::NewGuid().ToString('N')}
    if($Kind -eq 'SecretMeta' -and $null -eq $Row.PSObject.Properties['Rows']){$Key+='|'+$(if([string]$Row.LapsScheme){'LAPS'}else{'BitLocker'})}
    $queueKey=$Kind+'|'+[string]$script:DatabaseScopedPath+'|'+$Key
    if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.Contains($queueKey)){Set-Status 'File locale pleine : les dernieres informations sont en memoire, pas encore enregistrees.' 'WARN';return $false}
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
    $lines.Add('Limites : file de 4096 changements / 32 Mo ; lot maximal de 250 changements / 4 Mo. Le stockage depend de l espace disque disponible.')
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
    if([bool]$script:DemoMode){throw 'Purge locale indisponible en demonstration.'}
    if([string]::IsNullOrWhiteSpace([string]$script:DatabaseScopedPath)){throw 'Aucune base locale active.'}
    if($script:AsyncEngineClosing){throw 'Fermeture en cours.'}
    if($null -ne $script:DomeniaDirectoryReads){foreach($read in $script:DomeniaDirectoryReads.Values){if($null -ne $read -and (($null -ne $read.Input -and $read.Input.Count -gt 0) -or ($null -ne $read.BuildChanges -and $read.BuildChanges.Count -gt 0) -or $null -ne $read.Batch -or $read.InFlight -or ($null -ne $read.Collector -and -not $read.Collector.Done))){throw 'Des lectures annuaire attendent leur enregistrement. Attendez leur fin.'}}}
    if($null -ne $script:Live -and $null -ne $script:Live.SavePending -and $script:Live.SavePending.Count -gt 0){throw 'Des mesures attendent encore leur enregistrement.'}
    if($null -ne $script:ParkRun -and -not $script:ParkRun.Completed){throw 'Arretez le releve du parc avant la maintenance locale.'}
    # Every outstanding producer must finish; a late AD or workstation result can also refill the cache.
    if(@($script:AsyncJobs.Values|Where-Object{$null -ne $_}).Count -or @($script:DetachedReadJobs|Where-Object{$null -ne $_}).Count -or $script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){throw 'Une operation est encore active ou a verifier. Attendez sa fin puis refaites la simulation.'}
    if($null -ne $script:Live -and ($script:Live.SaveJob -or [int]$script:Live.SaveInFlight -gt 0)){throw 'Un enregistrement des observations est encore en cours.'}
    if($null -ne $script:Persistence){
        if($script:Persistence.Job -or $script:Persistence.LinkBusy -or $script:Persistence.Pending.Count -or ($null -ne $script:Persistence.LinkRequestTimer -and $script:Persistence.LinkRequestTimer.IsEnabled)){throw 'Des modifications locales attendent leur enregistrement. Refaites la simulation apres cet enregistrement.'}
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
            Set-Status 'Simulation terminee. Verifiez les nombres avant de confirmer.'
        }else{
            Reset-DomeniaStoragePurgePreview
            if($State.Selection -contains 'Index'){
                # The committed transaction already confirms an empty index; no synchronous disk reread.
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
    $path='';try{$path=[string](Get-DomeniaDatabasePath)}catch{}
    $box=Get-DomeniaControl 'TxtIndexLocation';if($null -ne $box){$box.Text=if($path){$path}else{'Aucune base active.'}}
    $text=''
    if($path -and [IO.File]::Exists($path)){
        $backups=[string](Get-DomeniaStoreBackupDirectory)
        $last=Get-ChildItem -LiteralPath $backups -Filter 'Domenia-*.db' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
        $text='Sauvegardes : '+$backups+' · '+$(if($null -ne $last){'derniere le '+$last.LastWriteTime.ToString('dd/MM/yyyy HH:mm')}else{'aucune pour l instant'})
    }
    [void](Set-DomeniaControlText 'LblIndexBackupStatus' $text)
}
function Open-DomeniaIndexLocation {
    $path=[string](Get-DomeniaDatabasePath)
    if(-not $path -or -not [IO.File]::Exists($path)){Set-Status 'Aucune base active a afficher.' 'WARN';return}
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
        $payload=[pscustomobject]@{Database=$path;BackupDirectory=(Join-Path ([IO.Path]::GetDirectoryName($path)) 'Backups');BudgetSeconds=[int](Get-CfgValue 'LocalStore' 'BackupTimeoutSeconds' 30);Keep=[int](Get-CfgValue 'LocalStore' 'DatabaseBackupCount' 7);CopyTo=$destination}
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
    if([string]$packet.CopiedTo){Set-Status ('Sauvegarde de la base copiee : '+[string]$packet.CopiedTo)}
    else{Set-Status ('Sauvegarde de la base enregistree : '+[string]$packet.Backup)}
    if([bool]$packet.Verified){$key=Get-DomeniaStoreId ([string]$State.Path) ([string]$script:Conn.BaseDn);Set-DomeniaSetting ('Storage.Backup.Last.'+$key) ([string]$packet.VerifiedAtUtc)}
    Update-DomeniaIndexLocation
}
function Fail-DomeniaIndexBackupUi {
    param([string]$Message,$State)
    if($null -ne $State -and [bool]$State.Automatic){$script:StorageAutoBackupJob=''}
    if($null -eq $State -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    Set-Status ('Sauvegarde de la base impossible : '+$Message) 'WARN'
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
    $payload=[pscustomobject]@{Action='StoreRead';Path=[string]$Context.Path;StoreId=[string]$Context.StoreId;DomainDn=[string]$Context.DomainDn;Query=$copy;BusyTimeoutMs=1000}
    return Start-UiTask -Name 'Lecture des donnees enregistrees' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -SuccessHandler $SuccessHandler -ErrorHandler $ErrorHandler -CallbackState $CallbackState -TimeoutSeconds 120
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
function Request-DomeniaStorageMaintenance {
    param([ValidateSet('Move','Restore')][string]$Mode,[string]$SourcePath='',[string]$TargetPath='')
    try{
        Assert-DomeniaStoragePurgeReady
        if($null -ne $script:StorageMaintenance -and $script:StorageMaintenance.Locked){throw 'Terminez ou reprenez la maintenance en attente.'}
        $active=[string]$script:DatabaseScopedPath
        if($Mode -eq 'Move'){$SourcePath=$active}elseif(-not $SourcePath){
            $dialog=[Microsoft.Win32.OpenFileDialog]::new();$dialog.Title='Choisir la sauvegarde SQLite a restaurer';$dialog.Filter='Base SQLite (*.db)|*.db';$dialog.CheckFileExists=$true
            if(-not $dialog.ShowDialog($script:Window)){return};$SourcePath=$dialog.FileName
        }
        if(-not $TargetPath){
            $dialog=[Microsoft.Win32.SaveFileDialog]::new();$dialog.Title='Choisir un nouveau fichier local pour la base';$dialog.Filter='Base SQLite (*.db)|*.db';$dialog.DefaultExt='.db';$dialog.AddExtension=$true;$dialog.OverwritePrompt=$false;$dialog.FileName='Domenia-'+[datetime]::Now.ToString('yyyyMMdd-HHmmss')+'.db'
            if(-not $dialog.ShowDialog($script:Window)){return};$TargetPath=$dialog.FileName
        }
        $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Mode=$Mode;Epoch=[long]$script:SessionEpoch;Path=$active;DomainDn=[string]$script:Conn.BaseDn;SourcePath=[IO.Path]::GetFullPath($SourcePath);TargetPath=[IO.Path]::GetFullPath($TargetPath);Fingerprint='';Job='';Locked=$false;Receipt=$null}
        $script:StorageMaintenance=$state
        $payload=[pscustomobject]@{Action='Inspect';ActivePath=$active;SourcePath=$state.SourcePath;DomainDn=$state.DomainDn}
        $state.Job=Start-UiTask -Name 'Verifier la base et preparer la maintenance' -OperationId 'StorageMaintenance' -Code (Get-DomeniaStorageMaintenanceWorkerCode) -Payload $payload -SuccessHandler 'Complete-DomeniaStorageMaintenancePreview' -ErrorHandler 'Fail-DomeniaStorageMaintenance' -CallbackState $state -TimeoutSeconds 180 -TaskClass 'Explicit'
        if(-not $state.Job){throw 'Admission de la verification non confirmee.'}
    }catch{Set-Status ('Maintenance locale impossible : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaStorageMaintenancePreview {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath -or $null -eq $script:StorageMaintenance -or $script:StorageMaintenance.Id -cne $State.Id){return}
    try{
        $State.Job='';$r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Action','Source','ActivePath')
        if($null -eq $r -or $r.Kind -cne 'StorageMaintenance' -or $r.Action -cne 'Inspect' -or $r.Source.Path -cne $State.SourcePath -or $r.ActivePath -cne $State.Path -or $r.Source.DomainDn -ine $State.DomainDn -or $r.Source.Integrity -cne 'ok' -or [string]$r.Source.Fingerprint -cnotmatch '^[a-f0-9]{64}$'){throw 'Inspection non confirmee.'}
        $State.Fingerprint=[string]$r.Source.Fingerprint
        $message=('Domaine : '+$r.Source.DomainDn+'. Revision : '+$r.Source.Revision+'. Objets : '+$r.Source.Counts.ad_objects+'. Mesures : '+$r.Source.Counts.domenia_observations+'. Requetes : '+$r.Source.Counts.domenia_query_recipes+'. Integrite SQLite : verifiee.'+[Environment]::NewLine+'Source : '+$State.SourcePath+[Environment]::NewLine+'Destination : '+$State.TargetPath+[Environment]::NewLine+'La copie sera verifiee avant la bascule. Le fichier original et les sauvegardes sont conserves. Les ecritures sont suspendues pendant cette operation.')
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $message)
        $start=${function:Start-DomeniaStorageMaintenanceApply}
        Request-DomeniaInlineConfirmation -Title $(if($State.Mode -eq 'Restore'){'Restaurer cette sauvegarde'}else{'Deplacer la base locale'}) -Target $State.TargetPath -Message $message -ConfirmText 'Copier, verifier puis utiliser la nouvelle base' -CancelText 'Conserver la base actuelle' -OnConfirm ({& $start -State $State}.GetNewClosure()) -OnCancel {Set-Status 'Maintenance annulee ; base actuelle conservee.'}
    }catch{Fail-DomeniaStorageMaintenance $_.Exception.Message $State}
}
function Start-DomeniaStorageMaintenanceApply {
    param($State,[ValidateSet('','Resume','Rollback')][string]$Recovery='')
    try{
        if($null -eq $State -or $null -eq $script:StorageMaintenance -or $State.Id -cne $script:StorageMaintenance.Id -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){throw 'Contexte de maintenance modifie.'}
        Assert-DomeniaStoragePurgeReady
        $State.Locked=$true
        $payload=[pscustomobject]@{Action=$(if($Recovery){$Recovery}else{$State.Mode});OperationId=$State.Id;ActivePath=$State.Path;SourcePath=$State.SourcePath;TargetPath=$State.TargetPath;DomainDn=$State.DomainDn;ExpectedFingerprint=$State.Fingerprint;BudgetSeconds=600}
        $State.Job=Start-UiTask -Name 'Copier et verifier la base locale' -OperationId 'StorageMaintenance' -Code (Get-DomeniaStorageMaintenanceWorkerCode) -Payload $payload -SuccessHandler 'Complete-DomeniaStorageMaintenanceApply' -ErrorHandler 'Fail-DomeniaStorageMaintenance' -CallbackState $State -TimeoutSeconds 660 -NonCancellable -TaskClass 'Explicit'
        if(-not $State.Job){$State.Locked=$false;throw 'Admission de maintenance non confirmee.'}
    }catch{Set-Status ('Maintenance non lancee : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaStorageMaintenanceApply {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    try{
        $State.Job='';$r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Committed','OperationId','TargetPath')
        if($null -eq $r -or $r.Kind -cne 'StorageMaintenance' -or -not $r.Committed -or $r.OperationId -cne $State.Id -or $r.ActivePath -cne $State.Path -or $r.DomainDn -ine $State.DomainDn -or $r.Integrity -cne 'ok' -or -not $r.OriginalPreserved){throw 'Copie ou bascule non confirmee. Conservez les deux fichiers.'}
        $State.Receipt=$r
        # Preference persistence and invalidation belong to the context switch. Its failure keeps recovery available.
        Switch-DomeniaDatabaseContext -Path ([string]$r.TargetPath) -ExpectedPath $State.Path -ExpectedEpoch $State.Epoch -StoreId ([string]$r.StoreId) -Revision ([long]$r.Revision)
    }catch{
        $State.Locked=$true;$text='Copie locale conservee, bascule non confirmee : '+$_.Exception.Message+'. Utilisez Reprendre la bascule ou Revenir a la base precedente.'
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN';return
    }
    # The switch has advanced the epoch. A presentation failure must never relock its obsolete context.
    $State.Locked=$false
    $text='Base verifiee en service : '+$r.TargetPath+'. Original conserve : '+$State.Path
    try{[void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text;Resume-DomeniaDatabaseViews}catch{Write-AppLog ('Base basculee ; relecture des vues differee : '+$_.Exception.Message) 'WARN'}
}
function Fail-DomeniaStorageMaintenance {
    param($Message,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return}
    $State.Job=''
    # A failed write/receipt can be ambiguous. Keep collection suspended until explicit recovery.
    if(-not $State.Locked){$State.Locked=$false}
    $text='Maintenance locale interrompue : '+[string]$Message+'. Aucun original supprime.'
    [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN'
}
function Resume-DomeniaStorageMaintenance {
    param([switch]$Rollback)
    $state=$script:StorageMaintenance
    if($null -eq $state -or -not $state.Locked -or $state.Job){Set-Status 'Aucune bascule interrompue a reprendre.';return}
    $start=${function:Start-DomeniaStorageMaintenanceApply};$mode=if($Rollback){'Rollback'}else{'Resume'}
    $text=if($Rollback){'Revenir au fichier original uniquement si la copie ne contient aucun nouveau commit. Les deux fichiers seront conserves.'}else{'Verifier la copie et reprendre la bascule interrompue. Les deux fichiers seront conserves.'}
    Request-DomeniaInlineConfirmation -Title 'Reprendre la maintenance locale' -Target $state.TargetPath -Message $text -ConfirmText 'Verifier et continuer' -CancelText 'Conserver en attente' -OnConfirm ({& $start -State $state -Recovery $mode}.GetNewClosure()) -OnCancel {Set-Status 'Reprise differee.'}
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
        foreach($name in @('BackupHours','BackupKeep','PresenceDays','ConsoleDays','InventoryDays','ProbeDays','DetailDays')){$value[$name]=[string](Get-DomeniaControl ('TxtStorage'+$name)).Text}
        $policy=ConvertTo-DomeniaStoragePolicy ([pscustomobject]$value)
        Set-DomeniaSetting 'Storage.PolicyJson' ($policy|ConvertTo-Json -Compress);$changed=$true
        Save-DomeniaSettings -Immediate -ThrowOnFailure
        Initialize-DomeniaStoragePolicy
        Set-Status 'Politique locale enregistree. La conservation sera appliquee uniquement après previsualisation et confirmation.'
    }catch{if($changed){Set-DomeniaSetting 'Storage.PolicyJson' $previous};Set-Status ('Reglages de stockage non appliques : '+$_.Exception.Message) 'WARN'}
}
function Initialize-DomeniaStoragePolicy {
    $policy=Get-DomeniaCurrentStoragePolicy
    $control=Get-DomeniaControl 'ChkStorageAutoBackup';if($control){$control.IsChecked=$policy.AutomaticBackup}
    foreach($name in @('BackupHours','BackupKeep','PresenceDays','ConsoleDays','InventoryDays','ProbeDays','DetailDays')){$control=Get-DomeniaControl ('TxtStorage'+$name);if($control){$control.Text=[string]$policy.$name}}
    if($null -eq $script:StorageBackupTimer){$script:StorageBackupTimer=New-DomeniaTimer -Owner 'Timer:StorageBackupPolicy' -IntervalMs 60000 -RunWhenHidden -Tick {Invoke-DomeniaScheduledBackup}}
    if($policy.AutomaticBackup){$script:StorageBackupTimer.Start()}else{$script:StorageBackupTimer.Stop()}
}
function Invoke-DomeniaScheduledBackup {
    if([bool]$script:DemoMode -or -not [string]$script:DatabaseScopedPath -or $script:AsyncEngineClosing -or $script:StorageAutoBackupJob){return}
    try{
        $policy=Get-DomeniaCurrentStoragePolicy;$path=[string]$script:DatabaseScopedPath;$key=Get-DomeniaStoreId $path ([string]$script:Conn.BaseDn)
        $busy=($null -ne $script:StorageMaintenance -and $script:StorageMaintenance.Locked) -or (Test-DomeniaStorageWorkPending) -or @($script:AsyncJobs.Values|Where-Object{$null -ne $_}).Count -gt 0
        # Persistence.LastSavedAt does not cover every writer or another process: never infer an unchanged DB from it.
        $dirty=$null
        $last=[string](Get-DomeniaSetting ('Storage.Backup.Last.'+$key) '')
        $attempt='';if($null -ne $script:StorageBackupAttempts -and $script:StorageBackupAttempts.ContainsKey($key)){$attempt=[string]$script:StorageBackupAttempts[$key]}
        $decision=Get-DomeniaStorageBackupDecision -Policy $policy -LastSuccessUtc $last -LastAttemptUtc $attempt -DirtyUtc $dirty -Busy $busy
        if(-not $decision.Due){return}
        if($null -eq $script:StorageBackupAttempts){$script:StorageBackupAttempts=@{}};$script:StorageBackupAttempts[$key]=[datetime]::UtcNow.ToString('o')
        $payload=[pscustomobject]@{Database=$path;BackupDirectory=(Join-Path ([IO.Path]::GetDirectoryName($path)) 'Backups');BudgetSeconds=120;Keep=$policy.BackupKeep;CopyTo=''}
        $state=[pscustomobject]@{CopyTo='';Path=$path;Epoch=[long]$script:SessionEpoch;Automatic=$true;StoreKey=$key}
        $script:StorageAutoBackupJob=Start-UiTask -Name 'Sauvegarde locale planifiee' -OperationId 'StorageBackup' -Code (Get-DomeniaStorageBackupWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaIndexBackupUi' -ErrorHandler 'Fail-DomeniaIndexBackupUi' -ReplaceKey 'storage:backup' -TimeoutSeconds 150 -TaskClass 'Background'
        if(-not $script:StorageAutoBackupJob){throw 'Sauvegarde planifiee non admise.'}
    }catch{Set-Status ('Sauvegarde planifiee differee : '+$_.Exception.Message) 'WARN'}
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
        if($null -eq $r -or $r.Kind -cne 'StorageMaintenance' -or $r.Action -cne 'ReadRedirect' -or $r.ActivePath -cne $State.Path -or $r.DomainDn -ine $State.DomainDn){throw 'Lecture de reprise non confirmee.'}
        if($null -eq $r.Redirect){Set-Status 'Aucune redirection en attente dans cette base.';return}
        $redirect=$r.Redirect
        $id=[guid]::Empty;if(-not [guid]::TryParse([string]$redirect.OperationId,[ref]$id) -or $id -eq [guid]::Empty){throw 'Identifiant de reprise invalide.'}
        $target=Get-DomeniaLocalDatabasePath ([string]$redirect.TargetPath)
        if([string]$redirect.StoreId -cne (Get-DomeniaStoreId $target $State.DomainDn)){throw 'Identite de reprise incoherente.'}
        $script:StorageMaintenance=[pscustomobject]@{Id=$id.ToString('D');Mode='Move';Epoch=$State.Epoch;Path=$State.Path;DomainDn=$State.DomainDn;SourcePath=$State.Path;TargetPath=$target;Fingerprint='';Job='';Locked=$true;Receipt=$null}
        $text='Bascule locale interrompue detectee. Original : '+$State.Path+'. Copie : '+$target+'. Utilisez Reprendre la bascule ou Revenir a la base precedente ; aucun fichier ne sera supprime.'
        [void](Set-DomeniaControlText 'LblStorageMaintenance' $text);Set-Status $text 'WARN'
    }catch{Fail-DomeniaStorageRecovery $_.Exception.Message $State}
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
        if($null -ne $script:StorageMaintenance -and $script:StorageMaintenance.Locked){throw 'Une maintenance est en attente.'}
        $policy=Get-DomeniaCurrentStoragePolicy;$policyKey=$policy|ConvertTo-Json -Compress
        if($Apply){
            if($null -eq $Preview -or $null -eq $script:StorageRetentionPreview -or $Preview.State.Id -cne $script:StorageRetentionPreview.State.Id -or $Preview.State.Epoch -ne [long]$script:SessionEpoch -or $Preview.State.Path -cne [string]$script:DatabaseScopedPath -or $Preview.State.PolicyKey -cne $policyKey){throw 'Previsualisation absente ou reglage modifie.'}
            $state=$Preview.State;$state.DryRun=$false;$state.ExpectedFingerprint=[string]$Preview.Result.Fingerprint
        }else{
            $cutoffs=[ordered]@{};$now=[datetime]::UtcNow
            foreach($family in @('Presence','Console','Inventory','Probe','Detail')){$days=[int]$policy.($family+'Days');$cutoffs[$family]=if($days -gt 0){$now.AddDays(-$days).ToString('o')}else{''}}
            $path=[string]$script:DatabaseScopedPath;$domain=[string]$script:Conn.BaseDn
            $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Mode='Retention';Path=$path;DomainDn=$domain;StoreId=(Get-DomeniaStoreId $path $domain);Epoch=[long]$script:SessionEpoch;PolicyKey=$policyKey;Cutoffs=[pscustomobject]$cutoffs;DryRun=$true;ExpectedFingerprint='';Locked=$false;Job=''}
        }
        $script:StorageRetentionPreview=$null;$button=Get-DomeniaControl 'BtnStorageRetentionApply';if($button){$button.IsEnabled=$false}
        $payload=[pscustomobject]@{Path=$state.Path;DomainDn=$state.DomainDn;StoreId=$state.StoreId;Cutoffs=$state.Cutoffs;DryRun=$state.DryRun;ExpectedFingerprint=$state.ExpectedFingerprint}
        if($Apply){$state.Locked=$true;$script:StorageMaintenance=$state}
        $state.Job=Start-UiTask -Name $(if($Apply){'Sauvegarder puis appliquer la conservation'}else{'Previsualiser la conservation par famille'}) -OperationId 'StorageRetention' -Code (Get-DomeniaStorageRetentionWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageRetention' -ErrorHandler 'Fail-DomeniaStorageRetention' -TimeoutSeconds 300 -NonCancellable -TaskClass 'Explicit'
        if(-not $state.Job){$state.Locked=$false;throw 'Operation de conservation non admise.'}
    }catch{Set-Status ('Conservation non lancee : '+$_.Exception.Message) 'WARN'}
}
function Request-DomeniaStorageRetention {
    try{
        Assert-DomeniaStoragePurgeReady;$preview=$script:StorageRetentionPreview
        if($null -eq $preview -or $preview.State.Epoch -ne [long]$script:SessionEpoch -or $preview.State.Path -cne [string]$script:DatabaseScopedPath){throw 'Refaites la previsualisation avant de confirmer.'}
        $start=${function:Start-DomeniaStorageRetention}
        Request-DomeniaInlineConfirmation -Title 'Appliquer la conservation des mesures' -Target $preview.State.Path -Message ($preview.Text+[Environment]::NewLine+'Une sauvegarde verifiee sera creee avant suppression. Aucun objet AD, compte, recette, journal ni recu ne sera supprime.') -ConfirmText 'Sauvegarder puis supprimer ces mesures anciennes' -CancelText 'Conserver les mesures' -OnConfirm ({& $start -Apply -Preview $preview}.GetNewClosure()) -OnCancel {Set-Status 'Conservation inchangee.'}
    }catch{Set-Status ('Conservation non confirmee : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaStorageRetention {
    param($Result,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath){return}
    try{
        $State.Job='';$r=Get-DomeniaEffectiveWorkerResult $Result @('Kind','Path','StoreId','Counts','Fingerprint')
        if($null -eq $r -or $r.Kind -cne 'StorageRetention' -or $r.Path -cne $State.Path -or $r.StoreId -cne $State.StoreId -or $r.DomainDn -ine $State.DomainDn -or $r.DryRun -isnot [bool] -or $r.Committed -isnot [bool] -or $r.DryRun -ne $State.DryRun -or $r.Committed -eq $r.DryRun -or [string]$r.Fingerprint -cnotmatch '^[a-f0-9]{64}$' -or -not $r.ReceiptsPreserved){throw 'Resultat de conservation non confirme.'}
        $seen=@{};$sum=0L;$lines=[Collections.Generic.List[string]]::new()
        foreach($row in @($r.Counts)){
            $n=0L;$family=[string]$row.Family
            if($family -notin @('Presence','Console','Inventory','Probe','Detail') -or $seen.ContainsKey($family) -or -not [string]$State.Cutoffs.$family -or [string]$row.CutoffUtc -cne [string]$State.Cutoffs.$family -or -not [long]::TryParse([string]$row.Rows,[ref]$n) -or $n -lt 0){throw 'Comptage par famille non conforme.'}
            $seen[$family]=$true;$sum+=$n;$lines.Add($family+' : '+$n+' ligne(s) ancienne(s).')
        }
        foreach($family in @('Presence','Console','Inventory','Probe','Detail')){if([string]$State.Cutoffs.$family -and -not $seen.ContainsKey($family)){throw 'Famille absente du comptage.'}}
        if([long]$r.SkippedLegacyRows -gt 0){$lines.Add([string]$r.SkippedLegacyRows+' mesure(s) anciennes non migrees conservees.')}
        $lines.Add('Les dates inconnues et les tentatives recentes restent conservees. La suppression libere de la place reutilisable ; elle ne reduit pas immediatement le fichier.')
        $text=$lines -join [Environment]::NewLine
        if($State.DryRun){
            $script:StorageRetentionPreview=[pscustomobject]@{State=$State;Result=$r;Text=$text}
            $button=Get-DomeniaControl 'BtnStorageRetentionApply';if($button){$button.IsEnabled=($sum -gt 0)}
            [void](Set-DomeniaControlText 'LblStorageRetention' ('Previsualisation : aucune suppression.'+[Environment]::NewLine+$text))
        }else{
            if($r.Fingerprint -cne $State.ExpectedFingerprint -or [long]$r.DeletedRows -ne $sum -or $null -eq $r.Backup -or -not $r.Backup.Verified -or [string]$r.Backup.SHA256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Suppression ou sauvegarde non confirmee.'}
            $State.Locked=$false;$script:StorageRetentionPreview=$null
            [void](Set-DomeniaControlText 'LblStorageRetention' ($text+[Environment]::NewLine+'Sauvegarde verifiee : '+$r.Backup.Path))
            Set-Status ('Conservation appliquee : '+$r.DeletedRows+' mesure(s) supprimee(s).')
            Reset-DomeniaStorageObservationViews -Revision ([long]$r.Revision)
        }
    }catch{Fail-DomeniaStorageRetention $_.Exception.Message $State}
}
function Fail-DomeniaStorageRetention {
    param($Message,$State)
    if($null -eq $State -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath){return}
    $State.Job='';$State.Locked=$false;$script:StorageRetentionPreview=$null
    $text='Conservation non confirmee : '+[string]$Message+'. Aucun rejeu automatique ; refaites la previsualisation.'
    [void](Set-DomeniaControlText 'LblStorageRetention' $text);Set-Status $text 'WARN'
    if(-not $State.DryRun){try{Reset-DomeniaStorageObservationViews}catch{Write-AppLog ('Relecture apres conservation differee : '+$_.Exception.Message) 'WARN'}}
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
