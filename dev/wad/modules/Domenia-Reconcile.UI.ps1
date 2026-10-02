# Periodic reconciliation is bounded to the last explicit search, never a hidden forest scan.
$script:Reconcile=$null
function Get-DomeniaReconcileWorkerCode {
return @'
if(-not $Payload.Filter -or ([string]$Payload.Filter).Length -gt 32768 -or $Payload.Limit -lt 1 -or $Payload.Limit -gt 500){throw 'Reconciliation hors limites.'}
if($Payload.Scope -notin @('OneLevel','Subtree')){throw 'Portee invalide.'}
if([string]$Payload.BaseDn -ine [string]$Context.BaseDn -and -not ([string]$Payload.BaseDn).EndsWith(','+[string]$Context.BaseDn,[StringComparison]::OrdinalIgnoreCase)){throw 'Perimetre hors du domaine courant.'}
$s=$null;$root=$null;$all=$null;$rows=[Collections.Generic.List[object]]::new();$capped=$false
try{
    $props=@('objectGUID','uSNChanged','name','distinguishedName','objectClass','sAMAccountName','userPrincipalName','dNSHostName','userAccountControl','lockoutTime','msDS-User-Account-Control-Computed','operatingSystem','lastLogonTimestamp','mail','description','whenChanged')
    $s=New-WSearcher $Context ([string]$Payload.BaseDn) ([string]$Payload.Filter) $props ([string]$Payload.Scope) ([int]$Payload.Limit+1)
    $root=$s.SearchRoot;$s.PageSize=40;$s.CacheResults=$false;$s.ServerTimeLimit=[timespan]::FromSeconds(8);$s.ClientTimeout=[timespan]::FromSeconds(12)
    $all=$s.FindAll()
    foreach($item in $all){
        if($rows.Count -ge [int]$Payload.Limit){$capped=$true;break}
        $row=New-WBranchRow $item;$row|Add-Member -NotePropertyName Guid -NotePropertyValue (Convert-WGuid (Get-WPropFirst $item.Properties 'objectguid' ''))
        $rows.Add($row)
    }
    [pscustomobject]@{Rows=$rows.ToArray();Capped=$capped;BaseDn=[string]$Payload.BaseDn;Scope=[string]$Payload.Scope;Filter=[string]$Payload.Filter;ObservedUtc=[datetime]::UtcNow.ToString('o')}
}finally{if($null -ne $all){$all.Dispose()};if($null -ne $s){$s.Dispose()};if($null -ne $root){$root.Dispose()}}
'@
}
function Complete-DomeniaReconcile {
    param($Result,$State)
    $script:Reconcile.Job=''
    if(-not (Test-DomeniaLiveSearchActive) -or $State.Epoch -ne $script:SessionEpoch -or $State.Identity -cne $script:Live.Identity -or -not [object]::ReferenceEquals($script:Live.Search,$State.Search) -or $State.Mutation -ne $script:Continuity.Mutation){return}
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Capped','Filter')
    if($null -eq $r -or [string]$r.Filter -cne $State.Filter){return}
    $s=$script:Live.Search;$seen=@{}
    foreach($row in @($r.Rows)){
        $key=Get-DomeniaLiveObjectKey $row;$seen[$key]=$true
        $script:Reconcile.Events.Enqueue([pscustomobject]@{Kind='Row';Row=$row;ObservedUtc=$r.ObservedUtc;Search=$s;Identity=$State.Identity;Mutation=$State.Mutation})
    }
    if(-not $r.Capped){
        foreach($row in $s.Rows){$key=Get-DomeniaLiveObjectKey $row;if(-not $seen.ContainsKey($key)){$script:Reconcile.Events.Enqueue([pscustomobject]@{Kind='Missing';Row=$row;ObservedUtc=$r.ObservedUtc;Search=$s;Identity=$State.Identity;Mutation=$State.Mutation})}}
    }
    Set-Status ('Perimetre relu en arriere-plan : '+@($r.Rows).Count+' lignes'+$(if($r.Capped){' ; limite atteinte, liste non exhaustive.'}else{'. Les absences restent a verifier, sans suppression automatique.'}))
}
function Fail-DomeniaReconcile {
    param($Message,$State)
    $script:Reconcile.Job='';$script:Reconcile.Next=[datetime]::UtcNow.AddMinutes(5)
    if($State.Epoch -eq $script:SessionEpoch){Write-AppLog ('Reconciliation non confirmee, cache conserve : '+$Message) 'WARN';[void](Request-DomeniaAccessRecovery -Operation 'Reconciliation du perimetre' -OperationId 'GlobalSearch' -ErrorValue $Message)}
}
function Invoke-DomeniaReconcileTick {
    if($null -eq $script:Reconcile -or $script:AsyncEngineClosing -or -not (Test-DomeniaLiveSearchActive) -or (Test-DomeniaAccessBusyWrite)){return}
    $s=$script:Live.Search;$r=$script:Reconcile;$grid=Get-DomeniaControl 'DgObjects'
    if(-not [object]::ReferenceEquals($r.Search,$s)){$r.Search=$s;$r.Events.Clear();$r.Next=[datetime]::UtcNow.AddSeconds(180)}
    # A job withdrawn from the queue, cancelled or superseded calls no handler: forget it so the next pass can run.
    if($r.Job -and -not $script:AsyncJobs.Contains([string]$r.Job) -and @(@($script:DetachedReadJobs)|Where-Object{$null -ne $_ -and [string]$_.Id -eq [string]$r.Job}).Count -eq 0){$r.Job='';$r.Next=[datetime]::UtcNow.AddMinutes(5)}
    if(-not $grid.IsEnabled){return}
    $watch=[Diagnostics.Stopwatch]::StartNew();$n=0
    while($r.Events.Count -and $n -lt 8 -and $watch.ElapsedMilliseconds -lt 5){
        $e=$r.Events.Dequeue();$n++
        if(-not [object]::ReferenceEquals($e.Search,$s) -or $e.Identity -cne $script:Live.Identity -or $e.Mutation -ne $script:Continuity.Mutation){continue}
        if($e.Kind -eq 'Missing'){$e.Row.DirectoryState='Absent du dernier retour : a reverifier';continue}
        Add-DomeniaLiveRow $e
        if($null -ne $script:Continuity){$script:Continuity.CacheDirty=$true}
    }
    if($r.Job -or $r.Events.Count -or -not $s.Finalized -or $s.Error -or [datetime]::UtcNow -lt $r.Next -or -not $grid.IsVisible -or -not $script:Window.IsActive){return}
    $enabled=Get-DomeniaControl 'ChkGuardReconcile';if($null -ne $enabled -and -not $enabled.IsChecked){return}
    if($script:DirectoryCredentialFaulted -or @($script:AsyncJobs.Keys).Count -ge 4){return}
    # D020 (C1): the idle policy may also hold the pass (write in flight, other page). Never more permissive than the window check above.
    if($null -ne (Get-Command Test-DomeniaBackgroundWorkAllowed -CommandType Function -ErrorAction SilentlyContinue)){try{if(-not (Test-DomeniaBackgroundWorkAllowed -Source 'Reconcile')){return}}catch{}}
    $filter=[string]$s.Final.FilterUsed;if(-not $filter){return}
    $state=[pscustomobject]@{Search=$s;Epoch=[long]$script:SessionEpoch;Identity=$script:Live.Identity;Filter=$filter;Mutation=$script:Continuity.Mutation}
    try{
        $r.Job=Start-UiTask -Name 'Reconciliation du perimetre' -OperationId 'ScopeReconcile' -Code (Get-DomeniaReconcileWorkerCode) -Payload ([pscustomobject]@{BaseDn=$s.State.BaseDn;Scope=$s.State.Scope;Limit=$s.State.Limit;Filter=$filter}) -CallbackState $state -SuccessHandler 'Complete-DomeniaReconcile' -ErrorHandler 'Fail-DomeniaReconcile' -TimeoutSeconds 20 -ReplaceKey 'scope-reconcile' -TaskClass 'Background'
        $r.Next=[datetime]::UtcNow.AddSeconds([Math]::Max(120,[Math]::Min(900,[int](Get-CfgValue 'Streaming' 'ReconcileSeconds' 180))))
    }catch{$r.Job='';$r.Next=[datetime]::UtcNow.AddMinutes(5);Write-AppLog ('Reconciliation differee : '+$_.Exception.Message) 'WARN'}
}
function Initialize-DomeniaReconcile {
    if($null -ne $script:Reconcile){return}
    $script:Reconcile=[pscustomobject]@{Search=$null;Job='';Events=[Collections.Generic.Queue[object]]::new();Next=[datetime]::UtcNow.AddMinutes(3);Timer=$null}
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$timer.Interval=[timespan]::FromMilliseconds(250)
    $timer.Add_Tick({try{Invoke-DomeniaReconcileTick}catch{Write-AppLog ('Reconciliation : '+$_.Exception.Message) 'WARN'}});$timer.Start();$script:Reconcile.Timer=$timer
    # D019: owned timer, stopped by the resource registry at shutdown.
    if($null -ne (Get-Command Register-DomeniaOwnedTimer -CommandType Function -ErrorAction SilentlyContinue)){try{[void](Register-DomeniaOwnedTimer -Owner 'Timer:Reconcile' -Timer $timer)}catch{}}
    $script:Window.Add_Closed({if($null -ne $script:Reconcile){$script:Reconcile.Timer.Stop();$script:Reconcile.Events.Clear()}})
}
