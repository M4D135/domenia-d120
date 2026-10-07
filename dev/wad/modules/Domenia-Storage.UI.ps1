# Single queue for legacy index/link deltas; Live cache writes share the same worker admission gate.
$script:Persistence=$null
$script:LinkBaseline=@{}
function Initialize-DomeniaPersistence {
    if($null -ne $script:Persistence){return}
    # D028: InFlight counts the items of the batch being written (they have left Pending); Conflicts holds the link keys
    # refused by the writer because another console changed them, until the associations are reloaded.
    # D113: LegacyImportJob marks an import that has left Pending but is not confirmed yet.
    $script:Persistence=[pscustomobject]@{Pending=@{};Job='';Next=[datetime]::MinValue;Fault='';Failures=0;LinkBusy=$false;Timer=$null;LinkRequestTimer=$null;LinkPersistenceMore=$false;InFlight=0;Conflicts=@{};LegacyImportJob=''}
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval=[timespan]::FromMilliseconds(350);$timer.Add_Tick({Start-DomeniaStorageWork});$script:Persistence.Timer=$timer;$timer.Start()
    if($null -ne (Get-Command Register-DomeniaOwnedTimer -CommandType Function -ErrorAction SilentlyContinue)){try{[void](Register-DomeniaOwnedTimer -Owner 'Timer:Storage' -Timer $timer)}catch{}}
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
    if($script:Persistence.Pending.Count -ge 256){Set-Status 'Cache en attente sature. Les donnees restent visibles mais non enregistrees.' 'WARN';return $false}
    $key='Index|'+[string]$script:DatabaseScopedPath+'|'+[string]$Row.Guid+'|'+[string]$Row.DN
    $script:Persistence.Pending[$key]=[pscustomobject]@{QueueKey=$key;Kind='Index';Path=[string]$script:DatabaseScopedPath;Row=$Row;Server=[string]$script:Conn.Server;At=[datetime]::UtcNow.ToString('o');Epoch=[long]$script:SessionEpoch}
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
    return $true
}
function Request-DomeniaLinkPersistence {
    # D028: coalesces link persistence requested by background observations; the single writer runs after a quiet
    # period, in batches of 64 at most. One owned timer, created once and reused.
    if ($null -eq $script:Persistence) { Initialize-DomeniaPersistence }
    $timer = $script:Persistence.LinkRequestTimer
    if ($null -eq $timer) {
        $timer = [Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
        $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $timer.Add_Tick({
            param($sender,$eventArgs)
            $sender.Stop()
            if ($null -eq $script:Persistence) { return }
            # Busy writer or refused batch: try again later, silently. A partial batch re-arms for the rest.
            if ($script:Persistence.LinkBusy) { $sender.Start(); return }
            $ok = Queue-DomeniaLinkChanges -Quiet -MaxItems 64
            if ((-not $ok) -or [bool]$script:Persistence.LinkPersistenceMore) { $sender.Start() }
        })
        $script:Persistence.LinkRequestTimer = $timer
        if ($null -ne (Get-Command Register-DomeniaOwnedTimer -CommandType Function -ErrorAction SilentlyContinue)) {
            try { [void](Register-DomeniaOwnedTimer -Owner 'Timer:LinkPersistence' -Timer $timer) } catch { }
        }
    }
    if (-not $timer.IsEnabled) { $timer.Start() }
}

function Start-DomeniaStorageWork {
    # Same liveness rule as the receipts: a save that left the engine without a callback frees the slot.
    # D113: keep the lock while a detached worker still runs; a lost completion never replays an import.
    if($null -ne $script:Persistence -and $script:Persistence.Job -and $null -ne $script:AsyncJobs -and -not $script:AsyncJobs.Contains([string]$script:Persistence.Job)){
        if(@($script:DetachedReadJobs | Where-Object { $_.Id -eq $script:Persistence.Job }).Count){return}
        if($script:Persistence.LegacyImportJob){
            $script:Persistence.LegacyImportJob=''
            Set-Status 'Resultat reprise des anciennes donnees non recu. Verifiez le stockage puis refaites la simulation avant toute nouvelle demande.' 'WARN'
            Add-DomeniaUiLog -Area 'Import' -Text 'Resultat reprise des anciennes donnees non recu ; aucun rejeu automatique.' -Level 'WARN'
        }
        $script:Persistence.Job=''
        $script:Persistence.InFlight=0
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
    if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('LocalStore','LiveCache','IndexBuild','LegacyMigration','StoragePurge')}).Count -or @($script:DetachedReadJobs|Where-Object{$_.OperationId -in @('LocalStore','LiveCache','IndexBuild','LegacyMigration','StoragePurge')}).Count){return}
    if(@($script:AsyncJobs.Keys).Count -ge 4){return}
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
    $state=[pscustomobject]@{Items=$items;Epoch=[long]$script:SessionEpoch}
    try {
        $script:Persistence.Job=Start-UiTask -Name 'Enregistrement cache et liens' -OperationId 'LocalStore' -Code (Get-DomeniaStorageWorkerCode) -Payload ([pscustomobject]@{Path=$path;Items=$items}) -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageWork' -ErrorHandler 'Fail-DomeniaStorageWork' -NonCancellable -TimeoutSeconds 120
        foreach($i in $items){[void]$script:Persistence.Pending.Remove($i.QueueKey)}
        # D028: the batch left Pending but is not on disk yet; the label keeps counting it until the callback.
        $script:Persistence.InFlight=@($items).Count
    }catch{$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(5);$script:Persistence.Fault=$_.Exception.Message}
}
function Complete-DomeniaStorageWork {
    param($Result,$State)
    if($null -eq $script:Persistence){return}
    $script:Persistence.Job='';$script:Persistence.InFlight=0
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Saved','Conflicts')
    if($null -eq $r -or -not $r.Saved){Fail-DomeniaStorageWork 'Resultat stockage non confirme.' $State;return}
    $items=@();if($null -ne $State){$items=@($State.Items)}
    $isImport=@($items|Where-Object{$_.Kind -eq 'LegacyImport'}).Count -gt 0
    if(-not $isImport){$script:Persistence.Fault='';$script:Persistence.Failures=0}
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
    $hasLinkWork=$false
    if($script:Persistence.LegacyImportJob){$hasLinkWork=$true}
    foreach($v in @($script:Persistence.Pending.Values)){if($v.Kind -eq 'Link' -or $v.Kind -eq 'LegacyImport'){$hasLinkWork=$true;break}}
    $script:Persistence.LinkBusy=$hasLinkWork
    if(-not $isImport){Add-DomeniaUiLog -Area 'Cache' -Text ('Lot enregistre : '+[int]$r.Count+' element(s), conflits : '+@($r.Conflicts).Count)}
}
function Fail-DomeniaStorageWork {
    param($Message,$State)
    if($null -eq $script:Persistence){return}
    $items=@();if($null -ne $State){$items=@($State.Items)}
    $isImport=@($items|Where-Object{$_.Kind -eq 'LegacyImport'}).Count -gt 0
    if($isImport){
        $script:Persistence.Job='';$script:Persistence.InFlight=0
        $script:Persistence.LegacyImportJob=''
        foreach($i in $items){if($script:Persistence.Pending.ContainsKey($i.QueueKey)){[void]$script:Persistence.Pending.Remove($i.QueueKey)}}
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
    foreach($i in $items){if(-not $script:Persistence.Pending.ContainsKey($i.QueueKey)){$script:Persistence.Pending[$i.QueueKey]=$i}}
    if($script:Persistence.Failures -ge 3){Set-Status 'Cache non enregistre : trois echecs. Les donnees restent en memoire ; corrigez le stockage puis Reprendre les sauvegardes dans Fiabilite.' 'WARN';return}
    Set-Status 'Cache non enregistre sur disque. Les observations sont encore en memoire ; une nouvelle tentative bornee sera faite.' 'WARN'
}
function Queue-DomeniaMetadata {
    param([ValidateSet('Presence','UserScan','Park','ParkSession','SecretMeta','Sample','IndexBulk','LegacyImport')][string]$Kind,$Row,[string]$Key='')
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
        if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.ContainsKey($queueKey)){Set-Status 'File locale pleine : reprise des anciennes donnees non enregistre.' 'WARN';return $false}
        $script:Persistence.Pending[$queueKey]=[pscustomobject]@{QueueKey=$queueKey;Kind=$Kind;Path=[string]$script:DatabaseScopedPath;Row=$Row;Epoch=[long]$script:SessionEpoch}
        $script:Persistence.LinkBusy=$true
        return $true
    }
    if(-not $Key){$Key=[guid]::NewGuid().ToString('N')}
    if($Kind -eq 'SecretMeta'){$Key+='|'+$(if([string]$Row.LapsScheme){'LAPS'}else{'BitLocker'})}
    $queueKey=$Kind+'|'+[string]$script:DatabaseScopedPath+'|'+$Key
    if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.ContainsKey($queueKey)){Set-Status 'File locale pleine : les dernieres informations sont en memoire, pas encore enregistrees.' 'WARN';return $false}
    $script:Persistence.Pending[$queueKey]=[pscustomobject]@{QueueKey=$queueKey;Kind=$Kind;Path=[string]$script:DatabaseScopedPath;Row=$Row;Epoch=[long]$script:SessionEpoch}
    return $true
}
function Get-DomeniaPersistenceState {
    # D028: the single place that builds the local save label, read by Fiabilite (Guard.UI) and the Live state line.
    # Pure read: never calls Initialize-DomeniaPersistence (timer, Closed handler); $script:Persistence and
    # $script:Live may be $null. Counts include the batches already sent and not yet confirmed (InFlight, SaveInFlight).
    $pending=0;$failed=0;$suspended=$false;$unavailable=$false;$conflicts=0
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
    return [pscustomobject]@{Pending=$pending;Failed=$failed;Suspended=[bool]$suspended;Unavailable=[bool]$unavailable;Conflicts=$conflicts;Label=[string]$label}
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
    param($Usage)
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
        $text=Format-DomeniaStorageUsage $usage
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
                $script:IndexRows=@();$script:IndexInfo=$null
                $script:IndexDbCount=0;$script:IndexDbUsers=0;$script:IndexDbComputers=0
                Rebuild-DomeniaIndexLookup
            }
            if($State.Selection -contains 'Observations'){
                $script:PresenceCache=@{};$script:ParkState=@{}
                if($null -ne $script:Live){$script:Live.Observations.Clear();$script:Live.ObservationsLoaded=$false;$script:Live.SaveQueue=@{};$script:Live.Done=@{};$script:Live.PresenceSeen=@{}}
            }
            if($State.Selection -contains 'Snapshots' -and $null -ne $script:Live){$script:Live.MemoryQueries=@{};$script:Live.QueryToSave=$null}
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
        $payload=[pscustomobject]@{Database=$path;BackupDirectory=(Join-Path ([IO.Path]::GetDirectoryName($path)) 'Backups');BudgetSeconds=[int](Get-CfgValue 'LocalStore' 'BackupTimeoutSeconds' 30);Keep=[int](Get-CfgValue 'LocalStore' 'DatabaseBackupCount' 7);CopyTo=$destination}
        [void](Start-UiTask -Name 'Sauvegarder la base' -OperationId 'StorageBackup' -Code (Get-DomeniaStorageBackupWorkerCode) -Payload $payload -CallbackState ([pscustomobject]@{CopyTo=$destination}) -ReplaceKey 'storage:backup' -TimeoutSeconds 150 -StatusText 'Sauvegarde de la base en cours...' -SuccessHandler 'Complete-DomeniaIndexBackupUi' -ErrorHandler 'Fail-DomeniaIndexBackupUi')
    }catch{Set-Status ('Sauvegarde de la base impossible : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaIndexBackupUi {
    param($Result,$State)
    if([string]$Result.CopiedTo){Set-Status ('Sauvegarde de la base copiee : '+[string]$Result.CopiedTo)}
    else{Set-Status ('Sauvegarde de la base enregistree : '+[string]$Result.Backup)}
    Update-DomeniaIndexLocation
}
function Fail-DomeniaIndexBackupUi {
    param([string]$Message,$State)
    Set-Status ('Sauvegarde de la base impossible : '+$Message) 'WARN'
}
