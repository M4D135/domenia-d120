# Read-only projections and bounded cache records. No UI or network calls here.
function Get-DomeniaLiveHash {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-DomeniaLiveField {
    param($Object,[string]$Name,[string]$Default='')
    if($null -eq $Object){return $Default}
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $Default}
    return [string]$p.Value
}
function Set-DomeniaLiveRowValue {
    param($Row,[string]$Name,$Value)
    if($null -eq $Row){return}
    if($Row.GetType().FullName -eq 'Domenia.Live.ResultRow') { $Row.Set($Name,[string]$Value); return }
    $p=$Row.PSObject.Properties[$Name]
    if($null -ne $p -and $p.IsSettable){$p.Value=$Value}
    else {Add-Member -InputObject $Row -NotePropertyName $Name -NotePropertyValue $Value -Force}
}
function New-DomeniaLiveResultRow {
    $rowType='Domenia.Live.ResultRow' -as [type]
    if($null -ne $rowType){return [Activator]::CreateInstance($rowType)}
    # In a restricted desktop, lack of runtime compilation must not prevent searching.
    $values=[ordered]@{}
    foreach($name in @('Type','Name','Login','UPN','Mail','Description','Changed','DN','State','OS','LastLogon','Guid','Association','LinkSource','LinkConfidence','Presence','PresenceDetail','SessionDisplay','SessionState','SessionSource','SessionChecked','SessionObserved','SessionDetail','DirectoryState','DirectoryChecked','Rank','Admin','PresenceState','PresenceAge','PresenceCached','ProbePending','DirectoryFresh')){$values[$name]=''}
    return [pscustomobject]$values
}
function ConvertTo-DomeniaLiveSnapshot {
    param($Row)
    # Fixed projection: a row cannot smuggle a password/secret into the cache.
    $values=[ordered]@{}
    foreach($name in @('Type','Name','Login','UPN','Mail','Description','Changed','DN','State','OS','LastLogon','Guid')) {
        $v=Get-DomeniaLiveField $Row $name
        $max=if($name -in @('DN','Description')){4096}else{512}
        if($v.Length -gt $max){$v=$v.Substring(0,$max)}
        $values[$name]=$v
    }
    return [pscustomobject]$values
}
function Add-DomeniaLiveMemoryQuery {
    # The 20-query bound alone could retain 400 000 duplicated PSCustomObject rows.
    # Bound the total snapshot rows too; this never truncates the current results or the SQLite index.
    param([Collections.IDictionary]$Queries,$Query,[int]$MaxQueries=20,[int]$MaxRows=20000)
    if($null -eq $Queries -or $null -eq $Query -or -not [string]$Query.QueryKey){return}
    $MaxQueries=[Math]::Max(1,$MaxQueries);$MaxRows=[Math]::Max(1,$MaxRows)
    $key=[string]$Query.QueryKey
    if(@($Query.Rows).Count -gt $MaxRows){[void]$Queries.Remove($key);return}
    $Queries[$key]=$Query
    $rows=0L;foreach($value in $Queries.Values){$rows+=@($value.Rows).Count}
    foreach($entry in @($Queries.Values|Where-Object{[string]$_.QueryKey -cne $key}|Sort-Object ObservedUtc,QueryKey)){
        if($Queries.Count -le $MaxQueries -and $rows -le $MaxRows){break}
        $rows-=@($entry.Rows).Count;[void]$Queries.Remove([string]$entry.QueryKey)
    }
}
function Get-DomeniaLiveObjectKey {
    param($Row)
    # Full DN, not a short hostname shared by several domains/OU scopes.
    return (Get-DomeniaLiveField $Row 'DN').Trim().ToLowerInvariant()
}
function ConvertTo-DomeniaLiveObservation {
    param($Result,$Previous,[string]$NowUtc=([datetime]::UtcNow.ToString('o')))
    if($null -ne $Previous -and $Previous.Guid -and $Result.Guid -and [string]$Previous.Guid -ine [string]$Result.Guid){$Previous=$null}
    $presenceOnly=((Get-DomeniaLiveField $Result 'Outcome') -eq 'PresenceOnly')
    $outcome=Get-DomeniaLiveField $Result 'Outcome' 'Unavailable'
    if($presenceOnly){$outcome=Get-DomeniaLiveField $Previous 'Outcome' 'NotRequested'}
    if($outcome -notin @('Observed','NoConsole','Denied','AuthRejected','Timeout','Unavailable','NotRequested')){$outcome='Unavailable'}
    $user=if($presenceOnly){Get-DomeniaLiveField $Previous 'CurrentUser'}else{(Get-DomeniaLiveField $Result 'User').Trim()}
    if($user.Length -gt 256){$user=$user.Substring(0,256)}
    if($outcome -eq 'Observed' -and [string]::IsNullOrWhiteSpace($user)){$outcome='Unavailable'}
    if($null -ne $Previous -and $Previous.Guid -and $Result.Guid -and [string]$Previous.Guid -ine [string]$Result.Guid){$Previous=$null}
    $last=Get-DomeniaLiveField $Previous 'LastUser'
    $lastAt=Get-DomeniaLiveField $Previous 'ObservedUtc'
    $lastSource=Get-DomeniaLiveField $Previous 'LastSource'
    if(-not $presenceOnly -and $outcome -eq 'Observed'){$last=$user;$lastAt=$NowUtc;$lastSource=Get-DomeniaLiveField $Result 'Source'}
    $detail=if($presenceOnly){Get-DomeniaLiveField $Previous 'Detail'}else{Get-DomeniaLiveField $Result 'Detail'}
    if($detail.Length -gt 1000){$detail=$detail.Substring(0,1000)}
    $presence=Get-DomeniaLiveField $Previous 'Presence' 'Non vérifié'
    $presenceAt=Get-DomeniaLiveField $Previous 'PresenceCheckedUtc' (Get-DomeniaLiveField $Previous 'CheckedUtc')
    $presenceDetail=Get-DomeniaLiveField $Previous 'PresenceDetail'
    $newPresenceAt=Get-DomeniaLiveField $Result 'PresenceCheckedUtc'
    $newStamp=[datetimeoffset]::MinValue;$oldStamp=[datetimeoffset]::MinValue
    $newValid=[datetimeoffset]::TryParse($newPresenceAt,[ref]$newStamp)
    $oldValid=[datetimeoffset]::TryParse($presenceAt,[ref]$oldStamp)
    if($newValid -and (-not $oldValid -or $newStamp -ge $oldStamp)){
        $presence=Get-DomeniaLiveField $Result 'Presence' 'Erreur de ping'
        $presenceAt=$newPresenceAt;$presenceDetail=Get-DomeniaLiveField $Result 'PresenceDetail'
    }
    $userChecked=if($presenceOnly){Get-DomeniaLiveField $Previous 'UserCheckedUtc' (Get-DomeniaLiveField $Previous 'CheckedUtc')}else{$NowUtc}
    return [pscustomobject]@{
        Key=Get-DomeniaLiveField $Result 'Key'; Computer=Get-DomeniaLiveField $Result 'Computer'
        Guid=Get-DomeniaLiveField $Result 'Guid'; Outcome=$outcome
        CurrentUser=$(if($outcome -eq 'Observed'){$user}else{''})
        LastUser=$last; ObservedUtc=$lastAt; CheckedUtc=$NowUtc; UserCheckedUtc=$userChecked
        LastSource=$lastSource; Source=$(if($presenceOnly){Get-DomeniaLiveField $Previous 'Source'}else{Get-DomeniaLiveField $Result 'Source'}); Detail=$detail
        Presence=$presence;PresenceCheckedUtc=$presenceAt;PresenceDetail=$presenceDetail
        LinkUser=$(if($presenceOnly){Get-DomeniaLiveField $Previous 'LinkUser'}else{Get-DomeniaLiveField $Result 'LinkUser'}); UserDn=$(if($presenceOnly){Get-DomeniaLiveField $Previous 'UserDn'}else{Get-DomeniaLiveField $Result 'UserDn'}); UserGuid=$(if($presenceOnly){Get-DomeniaLiveField $Previous 'UserGuid'}else{Get-DomeniaLiveField $Result 'UserGuid'})
        DirectoryAuthRejected=((Get-DomeniaLiveField $Result 'DirectoryAuthRejected') -eq 'True')
    }
}
function Get-DomeniaLiveObservationView {
    param($Observation,[switch]$Cached,[switch]$Pending)
    $outcome=Get-DomeniaLiveField $Observation 'Outcome'
    $last=Get-DomeniaLiveField $Observation 'LastUser'
    $current=Get-DomeniaLiveField $Observation 'CurrentUser'
    $state=if($null -eq $Observation){'Non vérifié · sélectionner le poste'}else{'À vérifier'};$display=if($last){$last+' (cache)'}else{'Non déterminé'}
    if(-not $Cached){
        switch($outcome){
            'NotRequested' {$state='Utilisateur non vérifié';$display='Non déterminé'}
            'Observed' {$display=$current;$state='Console observée'}
            'NoConsole' {$display='Aucun compte console';$state='Lecture réussie'}
            'Denied' {$state='Accès refusé'}
            'AuthRejected' {$state='Compte distant refusé'}
            'Timeout' {$state='Délai dépassé'}
            default {$state='Non confirmé'}
        }
    }
    if($Pending){$state='Vérification en cours'}
    $checked=Get-DomeniaLiveField $Observation 'UserCheckedUtc' (Get-DomeniaLiveField $Observation 'CheckedUtc')
    $seen=Get-DomeniaLiveField $Observation 'ObservedUtc'
    $detail="État : $state`r`nDernier compte observé : $last`r`nObservation UTC : $seen`r`nDernière tentative UTC : $checked`r`nSource : $(Get-DomeniaLiveField $Observation 'Source')`r`n$(Get-DomeniaLiveField $Observation 'Detail')`r`nConsole Windows uniquement : ne recense pas toutes les sessions RDP."
    [pscustomobject]@{Display=$display;State=$state;Detail=$detail;Checked=$checked;Observed=$seen;Source=Get-DomeniaLiveField $Observation 'Source'}
}
function Test-DomeniaLiveIdentity {
    param($State,[long]$SessionEpoch,[string]$Identity)
    return ($null -ne $State -and [long]$State.Epoch -eq $SessionEpoch -and [string]$State.Identity -ceq $Identity)
}
function Get-DomeniaPresenceStateKeys {
    # FI-16: the state of a presence is one of these keys. Colour, pill, filter and counters read the key, never
    # the label shown to the operator, so a label can be reworded without changing what it means.
    return @('Online','NoReply','Error','Pending','Unknown','None')
}
function ConvertTo-DomeniaPresenceStateKey {
    # The only place that reads a presence value as text: values written by the workers and the store ('En ligne',
    # 'Sans réponse au ping', 'Erreur de ping'), older stored values ('Hors ligne', 'Inconnu', 'Test en cours...'),
    # the filter choices and the fiche labels that start with a state. A key is returned unchanged.
    param([AllowNull()][AllowEmptyString()][string]$Presence)
    $value=([string]$Presence).Trim()
    if($value -in @(Get-DomeniaPresenceStateKeys)){return $value}
    $value=($value -replace '\s*\(cache\)$','').Trim()
    if(-not $value -or $value -in @('Inconnu','Unknown')){return 'Unknown'}
    if($value -like 'En ligne*'){return 'Online'}
    if($value -like 'Sans r*ponse*' -or $value -like 'Hors ligne*'){return 'NoReply'}
    if($value -like 'Erreur de ping*'){return 'Error'}
    if($value -like 'V*rification*' -or $value -like 'Test*'){return 'Pending'}
    if($value -like 'Sans objet*' -or $value -like 'Aucun poste*'){return 'None'}
    return 'Unknown'
}
function Get-DomeniaPresenceStateLabel {
    # Short label of a state key, as the grid, the pills and the filter show it.
    param([AllowEmptyString()][string]$State)
    switch(ConvertTo-DomeniaPresenceStateKey $State){
        'Online' {return 'En ligne'}
        'NoReply' {return 'Sans réponse au ping'}
        'Error' {return 'Erreur de ping'}
        'Pending' {return 'Vérification en cours'}
        'None' {return 'Sans objet'}
        default {return 'Non vérifié'}
    }
}
function Get-DomeniaLiveAgeText {
    # DS-15: discreet age of a measure, 'il y a 2 h', in place of the former '(cache)' suffix. Same wording as
    # Format-DomeniaAge (Boards), kept here so that this model stays loadable on its own. Empty when unreadable.
    param([AllowEmptyString()][string]$CheckedUtc,[datetime]$NowUtc=[datetime]::UtcNow)
    $stamp=[datetimeoffset]::MinValue
    if(-not [datetimeoffset]::TryParse([string]$CheckedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$stamp)){return ''}
    $span=$NowUtc.ToUniversalTime()-$stamp.UtcDateTime
    if($span.TotalMinutes -lt 1){return 'à lʼinstant'}
    if($span.TotalHours -lt 1){return 'il y a '+[int][Math]::Floor($span.TotalMinutes)+' min'}
    if($span.TotalDays -lt 1){return 'il y a '+[int][Math]::Floor($span.TotalHours)+' h'}
    return 'il y a '+[int][Math]::Floor($span.TotalDays)+' j'
}
function Get-DomeniaLivePresenceView {
    # FI-16 / DS-15: the view carries the state key (PresenceState), whether the value comes from an earlier session
    # (IsCached), the time of the measure (ObservedUtc) and its age. Display is the short label without '(cache)'.
    param($Observation,[switch]$Cached,[datetime]$NowUtc=[datetime]::UtcNow)
    $key=ConvertTo-DomeniaPresenceStateKey (Get-DomeniaLiveField $Observation 'Presence' 'Non vérifié')
    if($key -in @('Pending','None')){$key='Unknown'}
    $state=Get-DomeniaPresenceStateLabel $key
    $at=Get-DomeniaLiveField $Observation 'PresenceCheckedUtc' (Get-DomeniaLiveField $Observation 'CheckedUtc')
    $message=Get-DomeniaLiveField $Observation 'PresenceDetail'
    if($key -eq 'Unknown'){$at='';$message='Sélectionnez ce poste puis Revérifier ce poste pour envoyer un seul ping. Aucun contrôle collectif.'}
    if($key -eq 'NoReply'){$message+=' Pas de réponse ICMP : poste indisponible ou ICMP filtré, sans preuve quʼil est éteint.'}
    $historical=([bool]$Cached -and [bool]$at -and $key -ne 'Unknown')
    $age=if($at){Get-DomeniaLiveAgeText -CheckedUtc $at -NowUtc $NowUtc}else{''}
    $detail=$message+"`r`nVérification réseau UTC : "+$at
    if($age){$detail+=' ('+$age+')'}
    if($historical){$detail+="`r`nObservation historique, pas un état actuel confirmé."}
    [pscustomobject]@{Display=$state;State=$state;PresenceState=$key;IsCached=$historical;ObservedUtc=$at;Age=$age;Checked=$at;Detail=$detail}
}
function Get-DomeniaRowPresenceState {
    # State key of a result row: its PresenceState property, or for a row built before FI-16, the key of its text.
    param($Row)
    if($null -eq $Row){return 'Unknown'}
    $key=Get-DomeniaLiveField $Row 'PresenceState'
    if($key -in @(Get-DomeniaPresenceStateKeys)){return $key}
    return (ConvertTo-DomeniaPresenceStateKey (Get-DomeniaLiveField $Row 'Presence'))
}
function Test-DomeniaPresenceMatch {
    # FI-16: compares state keys. -State takes a key (PresenceState of a row) or, for an older row, its text.
    param([string]$State,[string]$Filter)
    if(-not $Filter -or $Filter -in @('Tous','All')){return $true}
    return ((ConvertTo-DomeniaPresenceStateKey $State) -ceq (ConvertTo-DomeniaPresenceStateKey $Filter))
}
function Test-DomeniaLiveRowInScope {
    # A displayed row must belong to the scope of the running search: a row from another OU (cache or late
    # result) is never shown. An empty base accepts everything (no scope to enforce).
    param([AllowNull()][string]$Dn,[AllowNull()][string]$BaseDn,[AllowNull()][string]$Scope)
    $base=([string]$BaseDn).Trim()
    if(-not $base){return $true}
    $dn=([string]$Dn).Trim()
    if(-not $dn){return $false}
    if($dn -ieq $base){return $true}
    if(-not $dn.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase)){return $false}
    if([string]$Scope -ieq 'OneLevel'){
        # Direct children only: the remaining part is a single RDN (no unescaped comma).
        $rest=$dn.Substring(0,$dn.Length-$base.Length-1)
        # A comma is escaped only after an odd number of backslashes. A literal backslash
        # (\\) before a comma must not hide a real RDN separator.
        $escaped=$false
        foreach($ch in $rest.ToCharArray()){
            if($ch -eq [char]'\'){$escaped=-not $escaped;continue}
            if($ch -eq [char]',' -and -not $escaped){return $false}
            $escaped=$false
        }
        return $true
    }
    return $true
}
function Get-DomeniaLiveProbeCode {
    $body = @'
$target=[string]$Payload.Computer
if($target.Length -gt 253 -or $target -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$'){throw 'Cible distante invalide.'}
$answer=[ordered]@{Key=[string]$Payload.Key;Guid=[string]$Payload.Guid;Computer=$target;Outcome='Unavailable';User='';Source='CIM/DCOM · Win32_ComputerSystem.UserName';Detail='';Presence='Non vérifié';PresenceCheckedUtc='';PresenceDetail='';LinkUser='';UserDn='';UserGuid='';UserUsn='';IdentityCheckedUtc='';CacheReused=$false;DirectoryAuthRejected=$false}
$cim=$null;$ping=$null;$authLease=$null
$collectPing=($null -eq $Payload.PSObject.Properties['CollectPing'] -or [bool]$Payload.CollectPing)
$probeUser=($null -eq $Payload.PSObject.Properties['ProbeUser'] -or [bool]$Payload.ProbeUser)
$collectInventory=($null -ne $Payload.PSObject.Properties['Inventory'] -and [bool]$Payload.Inventory)
$collectProbes=($null -ne $Payload.PSObject.Properties['Probes'] -and @($Payload.Probes).Count -gt 0)
$answer.PingAttempted=$collectPing;$answer.ConsoleAttempted=$false
$answer.InventoryAttempted=$collectInventory;$answer.ProbesAttempted=$collectProbes
$answer.ConsoleCheckedUtc='';$answer.InventoryCheckedUtc=''
$answer.AttemptedAtUtc=[datetime]::UtcNow.ToString('o')
# Point 17: a campaign passes a progress channel; every finished ping or CIM query is one step, so the engine tells a
# slow but advancing workstation from a stalled one. Same three fields and lock as the GlobalSearch channel.
# Point 18: the ping step also leaves its answer there, so a read stopped later by the engine is retried only when
# the workstation answered.
$readProgress=$null
if($null -ne $Payload.PSObject.Properties['ReadProgress'] -and $Payload.ReadProgress -is [Collections.IDictionary]){$readProgress=$Payload.ReadProgress}
function Step-WReadProgress{
    param([string]$Presence='')
    if($null -eq $readProgress){return}
    $locked=$false
    try{[Threading.Monitor]::Enter($readProgress.SyncRoot);$locked=$true;if($Presence){$readProgress['Presence']=$Presence};$readProgress['RowsRead']=[long]$readProgress['RowsRead']+1;$readProgress['LastRowTimestamp']=[Diagnostics.Stopwatch]::GetTimestamp()}catch{}finally{if($locked){[Threading.Monitor]::Exit($readProgress.SyncRoot)}}
}

function Get-NativeCode($ErrorValue){
    $ex=$ErrorValue.Exception
    for($n=0;$n -lt 8 -and $null -ne $ex;$n++){
        $native=$ex.PSObject.Properties['NativeErrorCode']
        if($null -ne $native -and [long]$native.Value -in @(1326,1909,1330,1331,1332,1334)){return (2147942400L+[long]$native.Value)}
        $code=([long]$ex.HResult -band 4294967295)
        if($code -in @(2147943726,2147944309,2147943730,2147943731,2147943732,2147943734,2147942405,2147749891)){return $code}
        $ex=$ex.InnerException
    }
    return 0L
}
# Ping is an independent collection. A WMI-only request never sends ICMP.
if($collectPing){
try {
    $ping=New-Object Net.NetworkInformation.Ping
    # Resolve first and prefer IPv4: when a name also resolves to IPv6, Ping.Send(name) can fail with a generic
    # PingException where ping.exe falls back to IPv4 (field report 2026-10-05).
    # When the resolution itself fails, the name is pinged as before and the error names the cause.
    $addresses=@();try{$addresses=@([Net.Dns]::GetHostAddresses($target))}catch{$addresses=@()}
    $address=@($addresses|Where-Object{$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|Select-Object -First 1)
    if(-not $address.Count){$address=@($addresses|Select-Object -First 1)}
    if(-not $address.Count){$address=@($target)}
    $p=$ping.Send($address[0],900)
    if($null -ne $p -and [string]$p.Status -eq 'Success') {
        $answer.Presence='En ligne';$answer.PresenceDetail='Réponse ICMP · '+[string]$p.RoundtripTime+' ms · '+[string]$address[0]
    } else {
        $answer.Presence='Sans réponse au ping';$answer.PresenceDetail='ICMP : '+$(if($null -ne $p){[string]$p.Status}else{'aucune réponse'})+' · '+[string]$address[0]
    }
} catch {
    # The innermost message names the real cause (unknown host, protocol not configured...).
    $inner=$_.Exception;while($null -ne $inner.InnerException){$inner=$inner.InnerException}
    $answer.Presence='Erreur de ping';$answer.PresenceDetail='Le contrôle ICMP n''a pas abouti (résolution DNS ou erreur réseau). '+[string]$inner.Message
} finally {if($null -ne $ping){$ping.Dispose()}}
$answer.PresenceCheckedUtc=[datetime]::UtcNow.ToString('o')
Step-WReadProgress ([string]$answer.Presence)
if($null -ne $Payload.PSObject.Properties['PresenceProgress'] -and $null -ne $Payload.PresenceProgress){
    $packet=[pscustomobject]@{Outcome='PresenceOnly';Key=$answer.Key;Guid=$answer.Guid;Computer=$target;Presence=$answer.Presence;PresenceCheckedUtc=$answer.PresenceCheckedUtc;PresenceDetail=$answer.PresenceDetail}
    $Payload.PresenceProgress.Enqueue([pscustomobject]@{Result=$packet;State=$Payload.PresenceState})
}
}
if(-not $probeUser -and -not $collectInventory -and -not $collectProbes){
    $answer.Outcome='PresenceOnly';$answer.Detail='Contrôle réseau uniquement. Aucune lecture du compte console.'
    [pscustomobject]$answer;return
}
# Point 13: needs (console, inventory parts, controller check, each probe) and the CIM queries really sent. The
# difference is the number of queries avoided by grouping; it is returned with the measurement.
$cimStats=[pscustomobject]@{Consumers=0;Executed=0}
$preRead=@{};$sharedProbeProps=@{};$productType=$null;$productTypeRead=$false
function Get-WCimGroupKey([string]$Namespace,[string]$ClassName,[string]$Filter){
    # Same rule as Get-DomeniaCimGroupKey (Domenia-Collection.Model.ps1), kept in this pinned body: namespace and class
    # names are case-insensitive, the filter is compared byte for byte (two literals never share a result).
    return ($Namespace.ToUpperInvariant()+'|'+$ClassName.ToUpperInvariant()+'|'+$Filter)
}
function Test-WInvalidCimQuery($ErrorValue){
    $ex=$ErrorValue.Exception
    for($n=0;$n -lt 8 -and $null -ne $ex;$n++){
        $native=$ex.PSObject.Properties['NativeErrorCode']
        if($null -ne $native -and [string]$native.Value -in @('InvalidQuery','InvalidParameter','InvalidProperty','NotSupported')){return $true}
        if([string]$ex.Message -match '(?i)invalid query|requ.te non valide|invalid property|propri.t. non valide|0x80041017|0x80041011'){return $true}
        $ex=$ex.InnerException
    }
    return $false
}
function Invoke-WSharedRead([string]$Key,[string]$ClassName,[string]$Filter,[string[]]$Base){
    # One read of a singleton class for every consumer: base properties first, then the properties of catalog probes
    # of the same class and filter. If the joined read is refused as an invalid query, the base read is sent alone,
    # so that the console and the inventory never fail because of a probe.
    $extra=@();if($sharedProbeProps.ContainsKey($Key)){$extra=@($sharedProbeProps[$Key]|Where-Object{$Base -notcontains $_})}
    $all=@($Base)+@($extra)
    $query=@{CimSession=$cim;ClassName=$ClassName;Property=$all;OperationTimeoutSec=$timeout;ErrorAction='Stop'}
    if($Filter){$query.Filter=$Filter}
    $instance=$null
    try{
        $cimStats.Executed++
        try{$instance=@(Get-CimInstance @query)[0]}
        catch{
            if(-not $extra.Count -or -not (Test-WInvalidCimQuery $_)){throw}
            $all=@($Base);$query.Property=$all;$cimStats.Executed++
            $instance=@(Get-CimInstance @query)[0]
        }
    }finally{Step-WReadProgress}
    if($null -ne $instance){$preRead[$Key]=[pscustomobject]@{Instance=$instance;Properties=@($all);At=[datetime]::UtcNow.ToString('o')}}
    return $instance
}
if($collectProbes){
    $sharedClasses=@();if($null -ne $Payload.PSObject.Properties['AllowedClasses']){$sharedClasses=@(@($Payload.AllowedClasses)|ForEach-Object{[string]$_})}
    foreach($probe in @($Payload.Probes)){
        if($null -eq $probe -or [string]$probe.Skip -eq 'DomainController'){continue}
        if($sharedClasses -notcontains [string]$probe.Class -or [string]$probe.Class -notmatch '^[A-Za-z0-9_]+$' -or [string]$probe.Namespace -notmatch '^[A-Za-z0-9_\\]+$'){continue}
        $sharedKey=Get-WCimGroupKey ([string]$probe.Namespace) ([string]$probe.Class) ([string]$probe.Filter)
        if(-not $sharedProbeProps.ContainsKey($sharedKey)){$sharedProbeProps[$sharedKey]=[Collections.Generic.List[string]]::new()}
        foreach($sharedProperty in @(@($probe.Properties)|Where-Object{[string]$_ -match '^[A-Za-z0-9_]+$'})){if(-not $sharedProbeProps[$sharedKey].Contains([string]$sharedProperty)){$sharedProbeProps[$sharedKey].Add([string]$sharedProperty)}}
    }
}
$csKey=Get-WCimGroupKey 'root\cimv2' 'Win32_ComputerSystem' ''
$osKey=Get-WCimGroupKey 'root\cimv2' 'Win32_OperatingSystem' ''
$diskKey=Get-WCimGroupKey 'root\cimv2' 'Win32_LogicalDisk' "DeviceID='C:'"
$needProductType=($collectProbes -and @(@($Payload.Probes)|Where-Object{$null -ne $_ -and [string]$_.Skip -eq 'DomainController'}).Count -gt 0)
try{
    # Missing ICMP reply does not block a separately requested CIM read.
    if($null -ne $Context.PSObject.Properties['UseCim'] -and -not [bool]$Context.UseCim){throw 'Lecture CIM desactivee dans les comptes distants.'}
    Assert-WCredentialAllowed -Context $Context -Channel Remote
    $credential=Get-WMachineCredential $Context
    $timeout=[Math]::Max(2,[Math]::Min(8,[int]$Payload.MethodSeconds))
    # One credential, one read-only transport in this automatic path. No SMB staging.
    $option=New-CimSessionOption -Protocol Dcom -ErrorAction Stop
    $parameters=@{ComputerName=$target;SessionOption=$option;OperationTimeoutSec=$timeout;ErrorAction='Stop'}
    if($null -ne $credential){$parameters.Credential=$credential}
    Assert-WCredentialAllowed -Context $Context -Channel Remote
    $authLease=Enter-WCredentialAttempt -Context $Context -Channel Remote
    $cim=New-CimSession @parameters
    # Console, inventory and catalog probes share one session but fail independently.
    # CIM reachability is not an ICMP measurement and must not refresh the Ping family.
    $system=$null
    if($probeUser){
        $answer.ConsoleAttempted=$true
        try{
            $csProperties=@('UserName');if($collectInventory){$csProperties+=@('Manufacturer','Model','TotalPhysicalMemory')}
            $cimStats.Consumers++;if($collectInventory){$cimStats.Consumers++}
            $system=Invoke-WSharedRead $csKey 'Win32_ComputerSystem' '' $csProperties
            if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null}
            if($null -eq $system){throw 'Le fournisseur CIM ne retourne pas Win32_ComputerSystem.'}
            $answer.User=([string]$system.UserName).Trim()
            $answer.Outcome=if($answer.User){'Observed'}else{'NoConsole'}
        }catch{
            if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}
            $code=Get-NativeCode $_
            $answer.Outcome=if($code -in @(2147943726,2147944309,2147943730,2147943731,2147943732,2147943734)){'AuthRejected'}elseif($code -in @(2147942405,2147749891)){'Denied'}elseif($_.Exception.Message -match '(?i)timeout|timed out|délai|delai'){'Timeout'}else{'Unavailable'}
            $answer.Detail='Console non confirmée : '+$_.Exception.Message
        }finally{if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null};$answer.ConsoleCheckedUtc=[datetime]::UtcNow.ToString('o')}
    }else{$answer.Outcome='NotRequested'}
    # Fleet analysis (decision David 2026-10-07): light WMI reading in the same session, kept with the observation.
    if($collectInventory){
        try{
            # The system type needed by the controller check of the probes joins this read (one query instead of two).
            $osProperties=@('Caption','BuildNumber','LastBootUpTime');if($needProductType){$osProperties+='ProductType'}
            $cimStats.Consumers+=2
            $os=Invoke-WSharedRead $osKey 'Win32_OperatingSystem' '' $osProperties
            if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null}
            if($needProductType -and -not $productTypeRead -and $null -ne $os -and @($preRead[$osKey].Properties) -contains 'ProductType'){$productTypeRead=$true;try{$observedProductType=[int]$os.ProductType;if($observedProductType -in @(1,2,3)){$productType=$observedProductType}}catch{$productType=$null}}
            if($null -eq $system){$cimStats.Consumers++;$system=Invoke-WSharedRead $csKey 'Win32_ComputerSystem' '' @('Manufacturer','Model','TotalPhysicalMemory')}
            $disk=Invoke-WSharedRead $diskKey 'Win32_LogicalDisk' "DeviceID='C:'" @('Size','FreeSpace')
            if($null -eq $os -or $null -eq $system){throw 'Le fournisseur CIM nʼa pas retourné les informations système demandées.'}
            $answer.Inventory=[pscustomobject]@{OsCaption=[string]$os.Caption;Build=[string]$os.BuildNumber;LastBootUtc=$(try{([datetime]$os.LastBootUpTime).ToUniversalTime().ToString('o')}catch{''});Manufacturer=([string]$system.Manufacturer).Trim();Model=([string]$system.Model).Trim();RamBytes=$(if($null -ne $system -and $null -ne $system.TotalPhysicalMemory){[double]$system.TotalPhysicalMemory}else{$null});DiskSize=$(if($null -ne $disk -and $null -ne $disk.Size){[double]$disk.Size}else{$null});DiskFree=$(if($null -ne $disk -and $null -ne $disk.FreeSpace){[double]$disk.FreeSpace}else{$null});CheckedUtc=[datetime]::UtcNow.ToString('o')}
        }catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw};$answer.InventoryError=[string]$_.Exception.Message}finally{if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null};$answer.InventoryCheckedUtc=[datetime]::UtcNow.ToString('o')}
    }
    # Widget probes (decision David 2026-10-07): catalog queries run read-only in the same CIM session. Only class,
    # namespace, property names and a filter come from the catalog; names are checked before the call.
    if($collectProbes){
        $since=@{'{SINCE_24H}'=(Get-Date).AddHours(-24).ToUniversalTime().ToString('yyyyMMddHHmmss.000000+000');'{SINCE_7D}'=(Get-Date).AddDays(-7).ToUniversalTime().ToString('yyyyMMddHHmmss.000000+000')}
        $probeResults=[ordered]@{}
        $allowedClasses=@();if($null-ne$Payload.PSObject.Properties['AllowedClasses']){foreach($allowedClass in @($Payload.AllowedClasses)){if(-not[string]::IsNullOrWhiteSpace([string]$allowedClass)){$allowedClasses+=[string]$allowedClass}}}
        # $productType and $productTypeRead may already come from the inventory read of Win32_OperatingSystem.
        if($needProductType){$cimStats.Consumers++}
        # Build the plan once. Namespace/class/property names are case-insensitive, but filter values
        # must remain byte-for-byte identical: different string literals must not share a result.
        $groups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $planned=[Collections.Generic.List[object]]::new()
        foreach($probe in @($Payload.Probes)){
            $entry=[ordered]@{Rows=@();Count=0;Error='';Truncated=$false;DefinitionHash=[string]$probe.DefinitionHash;CheckedUtc=[datetime]::UtcNow.ToString('o')}
            try{
                # Only validated, eligible catalog probes contribute properties to a shared read.
                if(-not $allowedClasses.Count){throw 'Catalogue de sondes absent de la charge utile : lecture refusee.'}
                if($allowedClasses -notcontains [string]$probe.Class){throw ('Classe absente du catalogue de sondes : '+[string]$probe.Class)}
                if([string]$probe.Class -notmatch '^[A-Za-z0-9_]+$' -or [string]$probe.Namespace -notmatch '^[A-Za-z0-9_\\]+$'){throw 'Requete refusee.'}
                $properties=@(@($probe.Properties)|Where-Object{[string]$_ -match '^[A-Za-z0-9_]+$'})
                if(-not $properties.Count){throw 'Aucune propriete valide pour cette sonde : lecture refusee.'}
                # Do not walk controller providers, and do not merge their properties into another probe.
                if([string]$probe.Skip -eq 'DomainController'){
                    if(-not $productTypeRead){$productTypeRead=$true;$cimStats.Executed++;try{$observedProductType=[int]@(Get-CimInstance -CimSession $cim -ClassName Win32_OperatingSystem -Property ProductType -OperationTimeoutSec $timeout -ErrorAction Stop)[0].ProductType;Step-WReadProgress;if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null};if($observedProductType -in @(1,2,3)){$productType=$observedProductType}}catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw};$productType=$null}finally{if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null}}}
                    if($null -eq $productType){throw 'Type de systeme non lu : requete ignoree par prudence.'}
                    if($productType -eq 2){$entry.Skipped='DomainController';$probeResults[[string]$probe.Id]=[pscustomobject]$entry;continue}
                }
                $filter=[string]$probe.Filter;foreach($token in $since.Keys){$filter=$filter.Replace($token,$since[$token])}
                $cacheKey=Get-WCimGroupKey ([string]$probe.Namespace) ([string]$probe.Class) $filter
                $cimStats.Consumers++
                if(-not $groups.ContainsKey($cacheKey)){
                    $groups[$cacheKey]=[pscustomobject]@{Namespace=[string]$probe.Namespace;Class=[string]$probe.Class;Filter=$filter;Properties=[Collections.Generic.List[string]]::new();PropertyNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);Read=$false;Items=@();Count=0L;EnumerationComplete=$false;Error='';At=''}
                }
                $group=$groups[$cacheKey]
                foreach($property in $properties){if($group.PropertyNames.Add([string]$property)){$group.Properties.Add([string]$property)}}
                $planned.Add([pscustomobject]@{Probe=$probe;Properties=$properties;Group=$group;Entry=$entry})
            }catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw};$entry.Error=[string]$_.Exception.Message}
            $probeResults[[string]$probe.Id]=[pscustomobject]$entry
        }
        foreach($plan in $planned){
            $probe=$plan.Probe;$properties=$plan.Properties;$cached=$plan.Group;$entry=$plan.Entry
            # A singleton already read for the console or the inventory serves the probes whose properties it holds.
            $shared=$null;$sharedKeyOf=Get-WCimGroupKey ([string]$cached.Namespace) ([string]$cached.Class) ([string]$cached.Filter)
            if(-not $cached.Read -and $preRead.ContainsKey($sharedKeyOf)){$shared=$preRead[$sharedKeyOf];foreach($needed in $cached.Properties){if(@($shared.Properties) -notcontains $needed){$shared=$null;break}}}
            if($null -ne $shared){
                $cached.Read=$true
                $cached.Items=@(ConvertTo-DomeniaProbeDetailInstance -Instance $shared.Instance -Properties $cached.Properties.ToArray() -Index 1);$cached.Count=1L;$cached.EnumerationComplete=$true;$cached.At=[string]$shared.At
            }
            if(-not $cached.Read){
                $cached.Read=$true
                $cimStats.Executed++
                $query=@{CimSession=$cim;Namespace=$cached.Namespace;ClassName=$cached.Class;Property=$cached.Properties.ToArray();OperationTimeoutSec=[Math]::Max(10,$timeout);ErrorAction='Stop'}
                if($cached.Filter){$query.Filter=$cached.Filter}
                try{
                    # Count the full stream, retaining detached typed details within explicit memory budgets.
                    $details=[Collections.Generic.List[object]]::new();$instanceCount=0L;$detailBytes=0L;$detailFull=$false
                    Assert-WCredentialAllowed -Context $Context -Channel Remote
                    Get-CimInstance @query | ForEach-Object {
                        if($null -ne $_){
                            $instanceCount++
                            if(-not $detailFull){
                                $detached=ConvertTo-DomeniaProbeDetailInstance -Instance $_ -Properties $cached.Properties.ToArray() -Index $instanceCount
                                $bytes=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $detached -Depth 8 -Compress))
                                if($details.Count -ge 2000 -or $detailBytes+$bytes -gt 262144){$detailFull=$true}else{$details.Add($detached);$detailBytes+=$bytes}
                            }
                        }
                    }
                    $cached.Items=$details.ToArray();$cached.Count=$instanceCount;$cached.EnumerationComplete=$true
                }catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw};$cached.Error=[string]$_.Exception.Message}finally{if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null};Step-WReadProgress}
                $cached.At=[datetime]::UtcNow.ToString('o')
            }
            $entry.CheckedUtc=$cached.At
            try{
                if($cached.Error){throw $cached.Error}
                $projection=New-DomeniaProbeDetailProjection -Instances @($cached.Items) -Properties $properties -TotalCount $cached.Count -EnumerationComplete $cached.EnumerationComplete -Mode ([string]$probe.Mode)
                foreach($property in $projection.PSObject.Properties){$entry[$property.Name]=$property.Value}
            }catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw};$entry.Error=[string]$_.Exception.Message}
            $probeResults[[string]$probe.Id]=[pscustomobject]$entry
        }
        $answer.Probes=[pscustomobject]$probeResults
    }
    if($answer.Outcome -in @('Observed','NoConsole')){$answer.Detail=if($answer.User){'Compte de la console observé maintenant. Les sessions RDP ne sont pas recensées.'}else{'Lecture réussie : aucun compte renvoyé pour la console. Cela ne prouve pas l''absence de sessions RDP.'}}
}catch{
    $authRejected=Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote
    $code=Get-NativeCode $_
    if($authRejected -or $code -in @(2147943726,2147944309,2147943730,2147943731,2147943732,2147943734)){$answer.Outcome='AuthRejected'}
    elseif($code -in @(2147942405,2147749891)){$answer.Outcome='Denied'}
    elseif($_.Exception.Message -match '(?i)(timed out|timeout|délai|delai)'){$answer.Outcome='Timeout'}
    $answer.Detail='Lecture CIM/DCOM non confirmée. '+$_.Exception.Message
    if($probeUser){$answer.ConsoleAttempted=$true;$answer.ConsoleCheckedUtc=[datetime]::UtcNow.ToString('o')}
    if($collectInventory -and -not $answer.Contains('Inventory')){$answer.InventoryError=$answer.Detail;$answer.InventoryCheckedUtc=[datetime]::UtcNow.ToString('o')}
    if($collectProbes){$errors=[ordered]@{};foreach($probe in @($Payload.Probes)){if($null -ne $answer.Probes -and $null -ne $answer.Probes.PSObject.Properties[[string]$probe.Id]){$errors[[string]$probe.Id]=$answer.Probes.([string]$probe.Id);continue};$errors[[string]$probe.Id]=[pscustomobject]@{Rows=@();Count=0;Error=$answer.Detail;Truncated=$false;CheckedUtc=[datetime]::UtcNow.ToString('o')}};$answer.Probes=[pscustomobject]$errors}
}finally{if($null -ne $authLease){Exit-WCredentialAttempt -Lease $authLease;$authLease=$null};if($null -ne $cim){Remove-CimSession -CimSession $cim -ErrorAction Ignore}}
$answer.CimQueries=[pscustomobject]@{Consumers=[int]$cimStats.Consumers;Executed=[int]$cimStats.Executed;Avoided=[int][Math]::Max(0,$cimStats.Consumers-$cimStats.Executed)}
# Validate only a qualified account belonging to the AD domain of this session.
# A local account or a bare username is never reinterpreted as an AD user.
if($answer.Outcome -eq 'Observed' -and ($null -eq $Payload.PSObject.Properties['ValidateConsoleIdentity'] -or [bool]$Payload.ValidateConsoleIdentity)){
    $user=[string]$answer.User;$sam='';$filter=''
    if($user -match '^([^\\]+)\\([^\\]+)$'){
        $dom=$matches[1];$sam=$matches[2]
        if(($Context.Netbios -and $dom -ieq [string]$Context.Netbios) -or ($Context.Domain -and $dom -ieq [string]$Context.Domain)){
            $escaped=$sam.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
            $filter='(&(objectCategory=person)(objectClass=user)(sAMAccountName='+$escaped+'))'
        }
    }elseif($user.Contains('@') -and $Context.Domain -and $user.EndsWith('@'+[string]$Context.Domain,[StringComparison]::OrdinalIgnoreCase)){
        $escaped=$user.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
        $filter='(&(objectCategory=person)(objectClass=user)(userPrincipalName='+$escaped+'))'
    }
    if($sam -match '^(?i:administrator|administrateur|defaultuser0|system)$'){$filter=''}
    if($filter){
        # An explicit park run checks the raw console every time; only the unchanged LDAP identity is reused.
        $previous=$Payload.Previous
        $identityAt=[datetime]::MinValue
        $identityText=if($null -ne $previous -and $null -ne $previous.PSObject.Properties['IdentityCheckedUtc']){[string]$previous.IdentityCheckedUtc}else{''}
        $identityFresh=[datetime]::TryParse($identityText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$identityAt)
        $identityNow=[datetime]::UtcNow
        $identityFresh=$identityFresh -and $identityAt.ToUniversalTime() -le $identityNow.AddMinutes(1) -and ($identityNow-$identityAt.ToUniversalTime()).TotalMinutes -lt 5
        $allowIdentityCache=($null -eq $Payload.PSObject.Properties['AllowIdentityCache'] -or [bool]$Payload.AllowIdentityCache)
        if($allowIdentityCache -and $identityFresh -and $null -ne $previous -and [int]$previous.Version -eq 1 -and [string]$previous.Key -ieq $answer.Key -and [string]$previous.Guid -ieq $answer.Guid -and $answer.Guid -and [string]$previous.RawAccount -ieq $answer.User -and $previous.LinkUser -and $previous.UserDn -and $previous.UserGuid -and -not [bool]$previous.DirectoryChanged){
            foreach($field in @('LinkUser','UserDn','UserGuid','UserUsn','IdentityCheckedUtc')){$answer[$field]=[string]$previous.$field}
            $answer.CacheReused=$true
            [pscustomobject]$answer;return
        }
        $searcher=$null;$results=$null;$root=$null
        try{
            $searcher=New-WSearcher $Context ([string]$Context.BaseDn) $filter @('sAMAccountName','distinguishedName','objectGUID','uSNChanged') 'Subtree' 2
            $root=$searcher.SearchRoot;$searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(3);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(4)
            $results=$searcher.FindAll();$found=@($results)
            if($found.Count -eq 1){$answer.IdentityCheckedUtc=[datetime]::UtcNow.ToString('o');$answer.UserUsn=[string](Get-WPropFirst $found[0].Properties 'usnchanged' '');$answer.LinkUser=[string](Get-WPropFirst $found[0].Properties 'samaccountname' '');$answer.UserDn=[string](Get-WPropFirst $found[0].Properties 'distinguishedname' '');$g=Get-WPropFirst $found[0].Properties 'objectguid' $null;$answer.UserGuid=if($g -is [array] -and $g.Count -eq 16){([guid]([byte[]]$g)).ToString('D')}else{Convert-WGuid $g}}
        }catch{
            $directoryRejected=Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory
            $code=Get-NativeCode $_
            $answer.DirectoryAuthRejected=($directoryRejected -or $code -in @(2147943726,2147944309,2147943730,2147943731,2147943732,2147943734))
            $answer.Detail+=' Validation AD non confirmée : '+$_.Exception.Message
        }finally{try{if($null -ne $results){$results.Dispose()}}catch{};try{if($null -ne $searcher){$searcher.Dispose()}}catch{};try{if($null -ne $root){$root.Dispose()}}catch{}}
    }
}
$answer.AttemptedAtUtc=[datetime]::UtcNow.ToString('o')
[pscustomobject]$answer
'@
    return (Get-DomeniaProbeDetailWorkerPrelude)+[Environment]::NewLine+$body
}

function Get-DomeniaLiveCacheCode {
    $body = @'
function Initialize-DomeniaWinSqliteNative { return [Domenia.WinSqliteNative] }
function New-DomeniaUtf8Ptr {
    param([AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$Text) + [char]0)
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-DomeniaUtf8Ptr {
    param([IntPtr]$Pointer,[int]$Length = -1)
    if ($Pointer -eq [IntPtr]::Zero) { return "" }
    if ($Length -lt 0) {
        $Length = 0
        while ([System.Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0) { $Length++ }
    }
    if ($Length -le 0) { return "" }
    $bytes = New-Object byte[] $Length
    [System.Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Close-DomeniaDatabase {
    param([IntPtr]$DatabaseHandle)
    if($DatabaseHandle -eq [IntPtr]::Zero){return}
    Initialize-DomeniaWinSqliteNative | Out-Null
    $rc=[Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle)
    if($rc -ne 0){throw ('Fermeture SQLite non confirmee (code '+$rc+'). Verrou local conserve.')}
    if($null -ne $script:DomeniaDatabaseLeases -and $script:DomeniaDatabaseLeases.ContainsKey($DatabaseHandle.ToInt64())){
        $lease=$script:DomeniaDatabaseLeases[$DatabaseHandle.ToInt64()];$script:DomeniaDatabaseLeases.Remove($DatabaseHandle.ToInt64())
        Exit-StoreWDatabaseLease $lease
    }
}

function ConvertTo-DomeniaSqlLiteral {
    param($Value)
    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [bool]) { return $(if ($Value) { "1" } else { "0" }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) { return ([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)) }
    return "'" + (([string]$Value) -replace "'","''") + "'"
}
function Open-DomeniaDatabase {
    param([string]$Path = '',[switch]$ReadOnly)
    $native = Initialize-DomeniaWinSqliteNative
    $db = [IntPtr]::Zero
    $pathPtr = [IntPtr]::Zero
    $lease=$null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        if(-not $ReadOnly){$lease=Enter-StoreWDatabaseLease -Path $Path -TimeoutMs 1000}
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 4 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        # FI-12: lock wait from the worker context (LocalStore.DatabaseBusyTimeoutMs), 2 500 ms without one.
        $busyMs=2500;$workerContext=Get-Variable -Name Context -ValueOnly -ErrorAction SilentlyContinue
        if(($null -ne $workerContext) -and ($null -ne $workerContext.PSObject.Properties['BusyTimeoutMs'])){$busyMs=[Math]::Max(100,[Math]::Min(5000,[int]$workerContext.BusyTimeoutMs))}
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
        if(-not $ReadOnly){
            Assert-StoreWDatabaseWritable -Db $db
            if($null -eq $script:DomeniaDatabaseLeases){$script:DomeniaDatabaseLeases=@{}}
            $script:DomeniaDatabaseLeases[$db.ToInt64()]=$lease;$lease=$null
        }
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
        throw
    }
    finally { if($null -ne $lease){Exit-StoreWDatabaseLease $lease}; if ($pathPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) } }
}
function Invoke-DomeniaDbExec {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $errPtr = [IntPtr]::Zero
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_exec($DatabaseHandle,$sqlPtr,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$errPtr)
        if ($rc -ne 0) {
            $msg = if ($errPtr -ne [IntPtr]::Zero) { ConvertFrom-DomeniaUtf8Ptr $errPtr } else { ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)) }
            throw "SQLite code $rc : $msg"
        }
        return $true
    }
    finally {
        if ($errPtr -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [Domenia.WinSqliteNative]::sqlite3_free($errPtr) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}
function Invoke-DomeniaDbQuery {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_prepare_v2($DatabaseHandle,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if ($rc -ne 0) { throw "SQLite prepare code $rc : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        $count = [Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i=0;$i -lt $count;$i++) {
                $name = ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))
                $type = [Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i)
                $value = $null
                switch ($type) {
                    1 { $value = [long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i) }
                    2 { $value = [double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i) }
                    3 { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                    5 { $value = $null }
                    default { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                }
                $o[$name] = $value
            }
            $rows.Add([pscustomobject]$o)
        }
        if ($step -ne 101) { throw "SQLite step code $step : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        return $rows.ToArray()
    }
    finally {
        if ($stmt -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}

function Assert-DomeniaLiveCacheSchema {
    # D115: the worker never writes (nor reads) a base whose schema_info is not exactly this version (11/1).
    param([IntPtr]$Db)
    if (@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_info';" $Db).Count -eq 0) { return }
    $versionRows = @(Invoke-DomeniaDbQuery "SELECT value FROM schema_info WHERE key='schema_version';" $Db)
    $revisionRows = @(Invoke-DomeniaDbQuery "SELECT value FROM schema_info WHERE key='domenia_schema';" $Db)
    if (($versionRows.Count -ne 1) -or ($revisionRows.Count -ne 1) -or ([string]$versionRows[0].value -cne '11') -or ([string]$revisionRows[0].value -cne '1')) {
        throw 'Cache refuse : schema de base different de cette version (11/1), aucune ecriture.'
    }
}
$path=[string]$Payload.Path
if([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)){throw 'Chemin de cache invalide.'}
$scope=[string]$Payload.Scope
if($scope -notmatch '^[a-f0-9]{64}$'){throw 'Périmètre du cache invalide.'}
$qScope=ConvertTo-DomeniaSqlLiteral $scope
$db=[IntPtr]::Zero
$transaction=$false
try{
    if($Payload.Mode -eq 'Read'){
        if(-not [IO.File]::Exists($path)){[pscustomobject]@{Mode='Read';CacheHit=$false};return}
        $db=Open-DomeniaDatabase -Path $path -ReadOnly
        Assert-DomeniaLiveCacheSchema $db
        $tables=@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('adcc_live_queries','adcc_live_observations');" $db)
        $queryHit=$false
        if(@($tables|Where-Object {$_.name -eq 'adcc_live_queries'}).Count -gt 0){
            $queryKey=ConvertTo-DomeniaSqlLiteral ([string]$Payload.QueryKey)
            $cached=@(Invoke-DomeniaDbQuery ("SELECT observed_utc,payload FROM adcc_live_queries WHERE scope_key=$qScope AND query_key=$queryKey AND observed_utc>=strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days') LIMIT 1;") $db)
            if($cached.Count -eq 1 -and [Text.Encoding]::UTF8.GetByteCount([string]$cached[0].payload) -le 33554432){
                $envelope=([string]$cached[0].payload)|ConvertFrom-Json -ErrorAction Stop
                if([string]$envelope.QueryKey -cne [string]$Payload.QueryKey){throw 'Périmètre du cache incohérent.'}
                $rowCount=0
                foreach($row in @($envelope.Rows)){
                    if($rowCount -ge [Math]::Min(20000,[int]$Payload.Limit)){break}
                    if($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.DN)){continue}
                    $Payload.Progress.Enqueue([pscustomobject]@{Kind='CachedRow';Row=$row;ObservedUtc=[string]$cached[0].observed_utc})
                    $rowCount++
                }
                $queryHit=$true
            }
        }
        if($Payload.LoadObservations -and @($tables|Where-Object {$_.name -eq 'adcc_live_observations'}).Count -gt 0){
            $records=@(Invoke-DomeniaDbQuery ("SELECT object_key,payload FROM adcc_live_observations WHERE scope_key=$qScope AND checked_utc>=strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days') ORDER BY checked_utc DESC LIMIT 20000;") $db)
            foreach($item in $records){
                if([Text.Encoding]::UTF8.GetByteCount([string]$item.payload) -gt 16384){continue}
                $entry=([string]$item.payload)|ConvertFrom-Json -ErrorAction Stop
                if([string]$entry.Key -cne [string]$item.object_key){continue}
                # Do not overwrite a newer live result that arrived while SQLite was read.
                [void]$Payload.ObservationStore.TryAdd([string]$entry.Key,$entry)
            }
        }
        [pscustomobject]@{Mode='Read';CacheHit=$queryHit}
        return
    }
    if($Payload.Mode -ne 'Write'){throw 'Mode de cache inconnu.'}
    $db=Open-DomeniaDatabase -Path $path
    Assert-DomeniaLiveCacheSchema $db
    [void](Invoke-DomeniaDbExec @"
CREATE TABLE IF NOT EXISTS adcc_live_queries(scope_key TEXT NOT NULL,query_key TEXT NOT NULL,observed_utc TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(scope_key,query_key));
CREATE TABLE IF NOT EXISTS adcc_live_observations(scope_key TEXT NOT NULL,object_key TEXT NOT NULL,checked_utc TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(scope_key,object_key));
CREATE INDEX IF NOT EXISTS idx_live_queries_retention ON adcc_live_queries(scope_key,observed_utc DESC);
CREATE INDEX IF NOT EXISTS idx_live_observations_retention ON adcc_live_observations(scope_key,checked_utc DESC);
BEGIN IMMEDIATE;
"@ $db)
    $transaction=$true
    if($null -ne $Payload.Query){
        $query=$Payload.Query
        $json=$query|ConvertTo-Json -Depth 5 -Compress
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 33554432 -or @($query.Rows).Count -gt 20000){throw 'Cache de recherche trop volumineux.'}
        $sql='INSERT OR REPLACE INTO adcc_live_queries(scope_key,query_key,observed_utc,payload) VALUES('+((@($scope,[string]$query.QueryKey,[string]$query.ObservedUtc,$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
        [void](Invoke-DomeniaDbExec $sql $db)
    }
    foreach($observation in @($Payload.Observations)){
        if($null -eq $observation -or [string]::IsNullOrWhiteSpace([string]$observation.Key)){continue}
        $checkedForRetention=[string]$observation.UserCheckedUtc
        if([string]::IsNullOrWhiteSpace($checkedForRetention)){$checkedForRetention=[string]$observation.CheckedUtc}
        $json=$observation|ConvertTo-Json -Depth 3 -Compress
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 16384){throw 'Observation trop volumineuse.'}
        $sql='INSERT OR REPLACE INTO adcc_live_observations(scope_key,object_key,checked_utc,payload) VALUES('+((@($scope,[string]$observation.Key,$checkedForRetention,$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
        [void](Invoke-DomeniaDbExec $sql $db)
        # D028: user_machine_links is written only by the single LocalStore writer.
    }
    # Retention affects only these new cache tables, never the existing AD index/history.
    [void](Invoke-DomeniaDbExec ("DELETE FROM adcc_live_queries WHERE scope_key=$qScope AND query_key IN (SELECT query_key FROM adcc_live_queries WHERE scope_key=$qScope ORDER BY observed_utc DESC LIMIT -1 OFFSET 20); DELETE FROM adcc_live_queries WHERE observed_utc<strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days'); DELETE FROM adcc_live_observations WHERE scope_key=$qScope AND object_key IN (SELECT object_key FROM adcc_live_observations WHERE scope_key=$qScope ORDER BY checked_utc DESC LIMIT -1 OFFSET 20000); DELETE FROM adcc_live_observations WHERE checked_utc<strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days'); COMMIT;") $db)
    $transaction=$false
    [pscustomobject]@{Mode='Write';Saved=@($Payload.Observations).Count}
}finally{
    if($transaction -and $db -ne [IntPtr]::Zero){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}}
    if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db}
}

'@
    return (Get-DomeniaStorageLeaseWorkerCode)+[Environment]::NewLine+$body
}
