function Get-DomeniaLockoutEventWorkerCode {
return @'
# Point 47: lockout events 4740 for one account SID, read on demand. The PDC emulator receives every lockout of
# the domain; when it cannot be resolved, the bound controller is read and the result says so.
$sid=[string]$Payload.UserSid
if($sid -notmatch '^S-1-5-21(-\d{1,10}){4}$'){throw 'SID de compte invalide : aucune lecture du journal.'}
$hours=[int]$Payload.Hours;if(($hours -lt 1) -or ($hours -gt 720)){$hours=168}
$max=[int]$Payload.MaxEvents;if(($max -lt 1) -or ($max -gt 500)){$max=200}
$server=[string]$Context.Server;$serverSource='Controleur interroge'
try{
    $owner=''
    $domainEntry=New-WEntry $Context ([string]$Context.BaseDn)
    try{$domainEntry.RefreshCache(@('fSMORoleOwner'));$owner=[string]$domainEntry.Properties['fSMORoleOwner'].Value}finally{$domainEntry.Dispose()}
    if($owner -match '^CN=NTDS Settings,(CN=[^,]+,CN=Servers,.+)$'){
        $dns=''
        $serverEntry=New-WEntry $Context $matches[1]
        try{$serverEntry.RefreshCache(@('dNSHostName'));$dns=[string]$serverEntry.Properties['dNSHostName'].Value}finally{$serverEntry.Dispose()}
        if($dns -match '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'){$server=$dns;$serverSource='Emulateur PDC'}
    }
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
}
if(-not $server){throw 'Aucun controleur a interroger.'}
$ms=[long][timespan]::FromHours($hours).TotalMilliseconds
$xpath="*[System[EventID=4740 and TimeCreated[timediff(@SystemTime) <= $ms]]] and *[EventData[Data[@Name='TargetSid']='$sid']]"
$par=@{ComputerName=$server;LogName='Security';FilterXPath=$xpath;MaxEvents=$max;ErrorAction='Stop'}
$adCredential=Get-WAdCredential $Context;if($null -ne $adCredential){$par.Credential=$adCredential}
$state='Read';$message='';$events=@()
$lease=Enter-WCredentialAttempt -Context $Context -Channel Directory
try{$events=@(Get-WinEvent @par)}
catch{
    if([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){$events=@()}
    elseif(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    else{
        $state=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
        $message=[string]$_.Exception.Message
        if($message.Length -gt 400){$message=$message.Substring(0,400)}
    }
}finally{Exit-WCredentialAttempt $lease}
$rows=[Collections.Generic.List[object]]::new()
foreach($ev in $events){
    $x=[xml]$ev.ToXml();$d=@{};foreach($v in @($x.Event.EventData.Data)){$d[[string]$v.Name]=[string]$v.'#text'}
    if([string]$d.TargetSid -ine $sid){continue}
    # In event 4740, TargetDomainName carries the caller computer name.
    $caller=[string]$d.TargetDomainName;if($caller.Length -gt 255){$caller=$caller.Substring(0,255)}
    $rows.Add([pscustomobject]@{TimeUtc=$ev.TimeCreated.ToUniversalTime().ToString('o');CallerComputer=$caller;Dc=[string]$ev.MachineName;RecordId=[long]$ev.RecordId})
}
[pscustomobject]@{State=$state;Server=$server;ServerSource=$serverSource;Hours=$hours;MaxEvents=$max;Truncated=($events.Count -ge $max);Events=$rows.ToArray();Message=$message;ObservedUtc=[datetime]::UtcNow.ToString('o');UserSid=$sid}
'@
}
