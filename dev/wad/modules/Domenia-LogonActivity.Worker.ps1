function Get-DomeniaLogonByDcWorkerCode {
return @'
# Point 27: lastLogon of one object, read on each domain controller of the domain on explicit request. lastLogon is
# not replicated: each controller only knows the logons it validated. Bounded: 50 controllers, 75 seconds by default,
# short limits per controller, one authentication lease per bind. Nothing is written.
$guid=[guid]::Empty
if((-not [guid]::TryParse([string]$Payload.ObjectGuid,[ref]$guid)) -or ($guid -eq [guid]::Empty)){throw 'GUID dʼobjet invalide : aucune lecture.'}
$max=[int]$Payload.MaxControllers;if(($max -lt 1) -or ($max -gt 50)){$max=50}
$budgetSeconds=[int]$Payload.BudgetSeconds;if(($budgetSeconds -lt 10) -or ($budgetSeconds -gt 120)){$budgetSeconds=75}
$watch=[Diagnostics.Stopwatch]::StartNew()
$baseDn=[string]$Context.BaseDn
if(-not $baseDn){throw 'Domaine non connecté : aucune lecture.'}
$guidFilter='(objectGUID='+(($guid.ToByteArray()|ForEach-Object{'\'+$_.ToString('X2')}) -join '')+')'
# Update interval of lastLogonTimestamp, read on the domain head (absent: default of 14 days).
$intervalState='NotRead';$intervalValue=''
$head=$null
try{
    $head=New-WEntry $Context $baseDn
    $head.psbase.RefreshCache(@('msDS-LogonTimeSyncInterval'))
    $values=$head.psbase.get_Properties().get_Item('msDS-LogonTimeSyncInterval')
    if(($null -ne $values) -and ($values.Count -gt 0)){$intervalState='Read';$intervalValue=[string]$values[0]}else{$intervalState='Absent'}
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    $intervalState=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'NotRead'}
}finally{if($null -ne $head){$head.Dispose()}}
# Controllers of this domain: writable (SERVER_TRUST_ACCOUNT) and read-only (PARTIAL_SECRETS_ACCOUNT).
$controllers=[Collections.Generic.List[object]]::new();$listTruncated=$false
$searcher=$null;$searchRoot=$null;$results=$null
try{
    $filter='(&(objectCategory=computer)(|(userAccountControl:1.2.840.113556.1.4.803:=8192)(userAccountControl:1.2.840.113556.1.4.803:=67108864)))'
    $searcher=New-WSearcher $Context $baseDn $filter @('dNSHostName','name','userAccountControl') 'Subtree' ($max+1)
    $searchRoot=$searcher.SearchRoot;$searcher.CacheResults=$false
    $searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(15);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(20)
    $results=$searcher.FindAll()
    foreach($r in $results){
        if($controllers.Count -ge $max){$listTruncated=$true;break}
        $dns=[string](Get-WPropFirst $r.Properties 'dnshostname' '')
        if($dns -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'){$dns=''}
        $uac=0L;try{$uac=[long](Get-WPropFirst $r.Properties 'useraccountcontrol' 0)}catch{$uac=0L}
        $kind=if(($uac -band 67108864) -ne 0){'RODC'}else{'RWDC'}
        $controllers.Add([pscustomobject]@{Dns=$dns;Name=[string](Get-WPropFirst $r.Properties 'name' '');Kind=$kind})
    }
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    throw ('Liste des contrôleurs du domaine illisible : '+[string]$_.Exception.Message)
}finally{
    if($null -ne $results){$results.Dispose()}
    if($null -ne $searcher){$searcher.Dispose()}
    if($null -ne $searchRoot){$searchRoot.Dispose()}
}
$readings=[Collections.Generic.List[object]]::new()
foreach($dc in @($controllers.ToArray()|Sort-Object Dns,Name)){
    $label=if($dc.Dns){[string]$dc.Dns}else{[string]$dc.Name}
    if(-not $dc.Dns){$readings.Add([pscustomobject]@{Dc=$label;Kind=$dc.Kind;State='Unavailable';LastLogonUtc='';LogonCount=$null;Error='Nom DNS du contrôleur absent de sa fiche.'});continue}
    if($watch.Elapsed.TotalSeconds -ge $budgetSeconds){$readings.Add([pscustomobject]@{Dc=$label;Kind=$dc.Kind;State='NotRead';LastLogonUtc='';LogonCount=$null;Error='Budget de temps atteint.'});continue}
    # The same account and credential guard, bound to this controller only for this read.
    $dcContext=$Context.PSObject.Copy();$dcContext.Server=[string]$dc.Dns
    $s=$null;$root=$null
    $state='Unavailable';$last='';$count=$null;$message=''
    try{
        $s=New-WSearcher $dcContext $baseDn $guidFilter @('lastLogon','logonCount') 'Subtree' 2
        $root=$s.SearchRoot;$s.CacheResults=$false
        $s.ServerTimeLimit=[TimeSpan]::FromSeconds(8);$s.ClientTimeout=[TimeSpan]::FromSeconds(12)
        $found=$s.FindOne()
        if($null -eq $found){$state='Absent'}
        else{
            $state='Read'
            $ticks=Convert-WLargeInteger (Get-WPropFirst $found.Properties 'lastlogon' 0)
            if(($ticks -gt 0) -and ($ticks -ne [long]::MaxValue)){$last=[DateTime]::FromFileTimeUtc($ticks).ToString('o')}
            $countValue=Get-WPropFirst $found.Properties 'logoncount' $null
            if($null -ne $countValue){try{$count=[long]$countValue}catch{$count=$null}}
        }
    }catch{
        if(Register-WCredentialFailure -Context $dcContext -ErrorValue $_ -Channel Directory){throw}
        $state=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
        $message=[string]$_.Exception.Message;if($message.Length -gt 200){$message=$message.Substring(0,200)}
    }finally{
        if($null -ne $s){$s.Dispose()}
        if($null -ne $root){$root.Dispose()}
    }
    $readings.Add([pscustomobject]@{Dc=$label;Kind=$dc.Kind;State=$state;LastLogonUtc=$last;LogonCount=$count;Error=$message})
}
[pscustomobject]@{ObjectGuid=$guid.ToString('D');Controllers=$readings.ToArray();KnownCount=$controllers.Count;ListTruncated=$listTruncated;IntervalState=$intervalState;IntervalValue=$intervalValue;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o');DurationMs=[long]$watch.ElapsedMilliseconds}
'@
}
