# Single queue for legacy index/link deltas; Live cache writes share the same worker admission gate.
$script:Persistence=$null
$script:LinkBaseline=@{}
function Initialize-DomeniaPersistence {
    if($null -ne $script:Persistence){return}
    $script:Persistence=[pscustomobject]@{Pending=@{};Job='';Next=[datetime]::MinValue;Fault='';Failures=0;LinkBusy=$false;Timer=$null}
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval=[timespan]::FromMilliseconds(350);$timer.Add_Tick({Start-DomeniaStorageWork});$script:Persistence.Timer=$timer;$timer.Start()
    $script:Window.Add_Closed({if($null -ne $script:Persistence){$script:Persistence.Timer.Stop()}})
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
    foreach($l in @($script:UserMachineLinks)){$key=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant();if($key){$script:LinkBaseline[$key]=ConvertTo-DomeniaLinkRecord $l}}
}
function Queue-DomeniaLinkChanges {
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    if($script:Persistence.LinkBusy){Set-Status 'Enregistrement des liens encore actif. Attendez son resultat avant une nouvelle modification.' 'WARN';return $false}
    $valid=@(ConvertTo-DomeniaCanonicalLinks -Links $script:UserMachineLinks);$current=@{};$items=[Collections.Generic.List[object]]::new()
    foreach($l in $valid){$key=(Normalize-LinkComputer ([string]$l.Computer)).ToUpperInvariant();if($key){$current[$key]=ConvertTo-DomeniaLinkRecord $l}}
    foreach($key in @(@($script:LinkBaseline.Keys)+@($current.Keys)|Select-Object -Unique)){
        $before=$script:LinkBaseline[$key];$after=$current[$key]
        $old=Get-DomeniaLinkFingerprint $before;$new=Get-DomeniaLinkFingerprint $after
        if($old -ceq $new){continue}
        $items.Add([pscustomobject]@{QueueKey=('Link|'+[string]$script:DatabaseScopedPath+'|'+$key);Kind='Link';Key=$key;Path=[string]$script:DatabaseScopedPath;Expected=$old;Row=$after;Remove=($null -eq $after);Epoch=[long]$script:SessionEpoch})
    }
    if($items.Count -gt 64 -or $script:Persistence.Pending.Count+$items.Count -gt 256){Set-Status 'Trop de modifications de liens pour ce lot (64 maximum). Aucune sauvegarde globale effectuee.' 'WARN';return $false}
    foreach($i in $items){$script:Persistence.Pending[$i.QueueKey]=$i}
    $script:Persistence.LinkBusy=($items.Count -gt 0)
    $script:UserMachineLinks=[object[]]$valid;Rebuild-UserMachineLinkIndex;Refresh-LinkGrid;Refresh-AssociationContext -SkipResultRefresh
    if($items.Count){Set-Status ($items.Count.ToString()+' lien(s) en memoire, enregistrement en arriere-plan en attente.')}
    return $true
}
function Start-DomeniaStorageWork {
    if($null -eq $script:Persistence -or $script:AsyncEngineClosing -or $script:Persistence.Job -or $script:Persistence.Failures -ge 3 -or -not $script:Persistence.Pending.Count -or [datetime]::UtcNow -lt $script:Persistence.Next){return}
    if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('LocalStore','LiveCache','IndexBuild')}).Count -or @($script:DetachedReadJobs|Where-Object{$_.OperationId -in @('LocalStore','LiveCache','IndexBuild')}).Count){return}
    if(@($script:AsyncJobs.Keys).Count -ge 4){return}
    $items=@($script:Persistence.Pending.Values|Select-Object -First 1);$path=[string]$items[0].Path
    $items=@($script:Persistence.Pending.Values|Where-Object{$_.Path -ceq $path}|Select-Object -First 64)
    if(-not $path){$script:Persistence.Fault='Base du contexte non disponible.';$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(10);return}
    $state=[pscustomobject]@{Items=$items;Epoch=[long]$script:SessionEpoch}
    try {
        $script:Persistence.Job=Start-UiTask -Name 'Enregistrement cache et liens' -OperationId 'LocalStore' -Code (Get-DomeniaStorageWorkerCode) -Payload ([pscustomobject]@{Path=$path;Items=$items}) -CallbackState $state -SuccessHandler 'Complete-DomeniaStorageWork' -ErrorHandler 'Fail-DomeniaStorageWork' -NonCancellable -TimeoutSeconds 120
        foreach($i in $items){[void]$script:Persistence.Pending.Remove($i.QueueKey)}
    }catch{$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(5);$script:Persistence.Fault=$_.Exception.Message}
}
function Complete-DomeniaStorageWork {
    param($Result,$State)
    $script:Persistence.Job=''
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Saved','Conflicts')
    if($null -eq $r -or -not $r.Saved){Fail-DomeniaStorageWork 'Resultat stockage non confirme.' $State;return}
    $script:Persistence.Fault='';$script:Persistence.Failures=0
    foreach($i in @($State.Items)){
        if($i.Kind -ne 'Link'){continue};$script:Persistence.LinkBusy=$false
        if($i.Epoch -ne [long]$script:SessionEpoch){continue}
        if(@($r.Conflicts) -contains $i.Key){Set-Status ('Association modifiee ailleurs : '+$i.Key+'. Votre version n a pas ecrase celle du disque. Rechargez les associations.') 'WARN';continue}
        if($i.Remove){[void]$script:LinkBaseline.Remove($i.Key)}else{$script:LinkBaseline[$i.Key]=$i.Row}
    }
    Add-DomeniaUiLog -Area 'Cache' -Text ('Lot enregistre : '+$r.Count+' element(s), conflits : '+@($r.Conflicts).Count)
}
function Fail-DomeniaStorageWork {
    param($Message,$State)
    $script:Persistence.Failures++;$script:Persistence.Job='';$script:Persistence.Fault=[string]$Message;$script:Persistence.Next=[datetime]::UtcNow.AddSeconds(15)
    foreach($i in @($State.Items)){if(-not $script:Persistence.Pending.ContainsKey($i.QueueKey)){$script:Persistence.Pending[$i.QueueKey]=$i}}
    if($script:Persistence.Failures -ge 3){Set-Status 'Cache non enregistre : trois echecs. Les donnees restent en memoire ; corrigez le stockage puis Reprendre les sauvegardes dans Fiabilite.' 'WARN';return}
    Set-Status 'Cache non enregistre sur disque. Les observations sont encore en memoire ; une nouvelle tentative bornee sera faite.' 'WARN'
}
function Queue-DomeniaMetadata {
    param([ValidateSet('Presence','UserScan','Park','SecretMeta','Sample','IndexBulk')][string]$Kind,$Row,[string]$Key='')
    if($null -eq $script:Persistence){Initialize-DomeniaPersistence}
    if(-not $script:DatabaseScopedPath){return $false}
    if(-not $Key){$Key=[guid]::NewGuid().ToString('N')}
    if($Kind -eq 'SecretMeta'){$Key+='|'+$(if([string]$Row.LapsScheme){'LAPS'}else{'BitLocker'})}
    $queueKey=$Kind+'|'+[string]$script:DatabaseScopedPath+'|'+$Key
    if($script:Persistence.Pending.Count -ge 256 -and -not $script:Persistence.Pending.ContainsKey($queueKey)){Set-Status 'File locale pleine : les dernieres informations sont en memoire, pas encore enregistrees.' 'WARN';return $false}
    $script:Persistence.Pending[$queueKey]=[pscustomobject]@{QueueKey=$queueKey;Kind=$Kind;Path=[string]$script:DatabaseScopedPath;Row=$Row;Epoch=[long]$script:SessionEpoch}
    return $true
}
