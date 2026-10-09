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
    foreach($name in @('Type','Name','Login','UPN','Mail','Description','Changed','DN','State','OS','LastLogon','Guid','Association','LinkSource','LinkConfidence','Presence','PresenceDetail','SessionDisplay','SessionState','SessionSource','SessionChecked','SessionObserved','SessionDetail','DirectoryState','DirectoryChecked','Rank','Admin')){$values[$name]=''}
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
function Get-DomeniaLivePresenceView {
    param($Observation,[switch]$Cached)
    $state=Get-DomeniaLiveField $Observation 'Presence' 'Non vérifié'
    if($state -in @('','Inconnu')){$state='Non vérifié'}
    if($state -eq 'Hors ligne'){$state='Sans réponse au ping'}
    $at=Get-DomeniaLiveField $Observation 'PresenceCheckedUtc' (Get-DomeniaLiveField $Observation 'CheckedUtc')
    $message=Get-DomeniaLiveField $Observation 'PresenceDetail'
    if($state -eq 'Non vérifié'){$at='';$message='Sélectionnez ce poste pour envoyer un seul ping. Aucun contrôle collectif.'}
    if($state -eq 'Sans réponse au ping'){$message+=' Pas de réponse ICMP : poste indisponible ou ICMP filtré, sans preuve qu''il est éteint.'}
    $display=$state
    if($Cached -and $at -and $state -ne 'Non vérifié'){$display+=' (cache)'}
    [pscustomobject]@{Display=$display;State=$state;Checked=$at;Detail=($message+"`r`nVérification réseau UTC : "+$at+$(if($Cached){"`r`nObservation historique, pas un état actuel confirmé."}else{''}))}
}
function Test-DomeniaPresenceMatch {
    param([string]$State,[string]$Filter)
    if(-not $Filter -or $Filter -eq 'Tous'){return $true}
    $state=($State -replace ' \(cache\)$','').Trim()
    if($state -in @('','Inconnu')){$state='Non vérifié'}
    if($Filter -eq 'Inconnu'){$Filter='Non vérifié'}
    if($Filter -eq 'Hors ligne'){$Filter='Sans réponse au ping'}
    if($state -eq 'Hors ligne'){$state='Sans réponse au ping'}
    return ($state -eq $Filter)
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
        return ($rest -notmatch '(?<!\\),')
    }
    return $true
}
function Get-DomeniaLiveProbeCode {
    return @'
$target=[string]$Payload.Computer
if($target.Length -gt 253 -or $target -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$'){throw 'Cible distante invalide.'}
$answer=[ordered]@{Key=[string]$Payload.Key;Guid=[string]$Payload.Guid;Computer=$target;Outcome='Unavailable';User='';Source='CIM/DCOM · Win32_ComputerSystem.UserName';Detail='';Presence='Non vérifié';PresenceCheckedUtc='';PresenceDetail='';LinkUser='';UserDn='';UserGuid='';UserUsn='';CacheReused=$false;DirectoryAuthRejected=$false}
$cim=$null;$ping=$null
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
# One ICMP echo, on the worker. Publish it before any possibly slow CIM call.
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
if($null -ne $Payload.PSObject.Properties['PresenceProgress'] -and $null -ne $Payload.PresenceProgress){
    $packet=[pscustomobject]@{Outcome='PresenceOnly';Key=$answer.Key;Guid=$answer.Guid;Computer=$target;Presence=$answer.Presence;PresenceCheckedUtc=$answer.PresenceCheckedUtc;PresenceDetail=$answer.PresenceDetail}
    $Payload.PresenceProgress.Enqueue([pscustomobject]@{Result=$packet;State=$Payload.PresenceState})
}
$probeUser=($null -eq $Payload.PSObject.Properties['ProbeUser'] -or [bool]$Payload.ProbeUser)
if(-not $probeUser -or ($null -ne $Context.PSObject.Properties['UseCim'] -and -not [bool]$Context.UseCim)){
    $answer.Outcome='PresenceOnly';$answer.Detail='Contrôle réseau uniquement. Aucune lecture du compte console.'
    [pscustomobject]$answer;return
}
try{
    # Missing ICMP reply does not block a separately requested CIM read.
    $credential=Get-WMachineCredential $Context
    $timeout=[Math]::Max(2,[Math]::Min(8,[int]$Payload.MethodSeconds))
    # One credential, one read-only transport in this automatic path. No SMB staging.
    $option=New-CimSessionOption -Protocol Dcom -ErrorAction Stop
    $parameters=@{ComputerName=$target;SessionOption=$option;OperationTimeoutSec=$timeout;ErrorAction='Stop'}
    if($null -ne $credential){$parameters.Credential=$credential}
    $cim=New-CimSession @parameters
    $cs=Get-CimInstance -CimSession $cim -ClassName Win32_ComputerSystem -Property UserName -OperationTimeoutSec $timeout -ErrorAction Stop
    if($null -eq $cs){throw 'Le fournisseur CIM ne retourne pas Win32_ComputerSystem.'}
    $answer.Presence='En ligne';$answer.PresenceCheckedUtc=[datetime]::UtcNow.ToString('o');$answer.PresenceDetail='Réponse CIM/DCOM reçue ; '+$answer.PresenceDetail
    $answer.User=([string]$cs.UserName).Trim()
    $answer.Outcome=if($answer.User){'Observed'}else{'NoConsole'}
    # Fleet analysis (decision David 2026-10-07): light WMI reading in the same session, kept with the observation.
    if($null -ne $Payload.PSObject.Properties['Inventory'] -and [bool]$Payload.Inventory){
        try{
            $os=Get-CimInstance -CimSession $cim -ClassName Win32_OperatingSystem -Property Caption,BuildNumber,LastBootUpTime -OperationTimeoutSec $timeout -ErrorAction Stop
            $system=Get-CimInstance -CimSession $cim -ClassName Win32_ComputerSystem -Property Manufacturer,Model,TotalPhysicalMemory -OperationTimeoutSec $timeout -ErrorAction Stop
            $disk=Get-CimInstance -CimSession $cim -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -Property Size,FreeSpace -OperationTimeoutSec $timeout -ErrorAction Stop
            $answer.Inventory=[pscustomobject]@{OsCaption=[string]$os.Caption;Build=[string]$os.BuildNumber;LastBootUtc=$(try{([datetime]$os.LastBootUpTime).ToUniversalTime().ToString('o')}catch{''});Manufacturer=([string]$system.Manufacturer).Trim();Model=([string]$system.Model).Trim();RamBytes=[double]$system.TotalPhysicalMemory;DiskSize=[double]$disk.Size;DiskFree=[double]$disk.FreeSpace;CheckedUtc=[datetime]::UtcNow.ToString('o')}
        }catch{$answer.InventoryError=[string]$_.Exception.Message}
    }
    # Widget probes (decision David 2026-10-07): catalog queries run read-only in the same CIM session. Only class,
    # namespace, property names and a filter come from the catalog; names are checked before the call.
    if($null -ne $Payload.PSObject.Properties['Probes'] -and @($Payload.Probes).Count){
        $since=@{'{SINCE_24H}'=(Get-Date).AddHours(-24).ToUniversalTime().ToString('yyyyMMddHHmmss.000000+000');'{SINCE_7D}'=(Get-Date).AddDays(-7).ToUniversalTime().ToString('yyyyMMddHHmmss.000000+000')}
        $probeResults=[ordered]@{}
        $productType=$null;$productTypeRead=$false
        foreach($probe in @($Payload.Probes)){
            $entry=[ordered]@{Rows=@();Count=0;Error='';CheckedUtc=[datetime]::UtcNow.ToString('o')}
            try{
                if([string]$probe.Class -notmatch '^[A-Za-z0-9_]+$' -or [string]$probe.Namespace -notmatch '^[A-Za-z0-9_\\]+$'){throw 'Requete refusee.'}
                # FI-17: a query flagged for the controllers never runs on one (ProductType 2), where it would walk the directory.
                if([string]$probe.Skip -eq 'DomainController'){
                    if(-not $productTypeRead){$productTypeRead=$true;try{$productType=[int]@(Get-CimInstance -CimSession $cim -ClassName Win32_OperatingSystem -Property ProductType -OperationTimeoutSec $timeout -ErrorAction Stop)[0].ProductType}catch{$productType=$null}}
                    if($null -eq $productType){throw 'Type de systeme non lu : requete ignoree par prudence.'}
                    if($productType -eq 2){$entry.Skipped='DomainController';$probeResults[[string]$probe.Id]=[pscustomobject]$entry;continue}
                }
                $properties=@(@($probe.Properties)|Where-Object{[string]$_ -match '^[A-Za-z0-9_]+$'})
                $filter=[string]$probe.Filter;foreach($token in $since.Keys){$filter=$filter.Replace($token,$since[$token])}
                $query=@{CimSession=$cim;Namespace=[string]$probe.Namespace;ClassName=[string]$probe.Class;OperationTimeoutSec=[Math]::Max(10,$timeout);ErrorAction='Stop'}
                if($properties.Count){$query.Property=$properties}
                if($filter){$query.Filter=$filter}
                $items=@(Get-CimInstance @query)
                $entry.Count=$items.Count
                $entry.Rows=@($items|Select-Object -First 20|ForEach-Object{$instance=$_;,@($properties|ForEach-Object{$value=$instance.$_;if($value -is [datetime]){$value.ToUniversalTime().ToString('o')}elseif($value -is [array]){[string]@($value)[0]}else{$text=[string]$value;if($text.Length -gt 200){$text.Substring(0,200)}else{$text}}})})
            }catch{$entry.Error=[string]$_.Exception.Message}
            $probeResults[[string]$probe.Id]=[pscustomobject]$entry
        }
        $answer.Probes=[pscustomobject]$probeResults
    }
    $answer.Detail=if($answer.User){'Compte de la console observé maintenant. Les sessions RDP ne sont pas recensées.'}else{'Lecture réussie : aucun compte renvoyé pour la console. Cela ne prouve pas l''absence de sessions RDP.'}
}catch{
    $code=Get-NativeCode $_
    if($code -in @(2147943726,2147944309,2147943730,2147943731,2147943732,2147943734)){$answer.Outcome='AuthRejected'}
    elseif($code -in @(2147942405,2147749891)){$answer.Outcome='Denied'}
    elseif($_.Exception.Message -match '(?i)(timed out|timeout|délai|delai)'){$answer.Outcome='Timeout'}
    $answer.Detail='Lecture CIM/DCOM non confirmée. '+$_.Exception.Message
}finally{if($null -ne $cim){Remove-CimSession -CimSession $cim -ErrorAction Ignore}}
# Validate only a qualified account belonging to the AD domain of this session.
# A local account or a bare username is never reinterpreted as an AD user.
if($answer.Outcome -eq 'Observed'){
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
        if($null -ne $previous -and [int]$previous.Version -eq 1 -and [string]$previous.Key -ieq $answer.Key -and [string]$previous.Guid -ieq $answer.Guid -and $answer.Guid -and [string]$previous.RawAccount -ieq $answer.User -and $previous.LinkUser -and $previous.UserDn -and $previous.UserGuid -and -not [bool]$previous.DirectoryChanged){
            foreach($field in @('LinkUser','UserDn','UserGuid','UserUsn')){$answer[$field]=[string]$previous.$field}
            $answer.CacheReused=$true
            [pscustomobject]$answer;return
        }
        $searcher=$null;$results=$null;$root=$null
        try{
            $searcher=New-WSearcher $Context ([string]$Context.BaseDn) $filter @('sAMAccountName','distinguishedName','objectGUID','uSNChanged') 'Subtree' 2
            $root=$searcher.SearchRoot;$searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(3);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(4)
            $results=$searcher.FindAll();$found=@($results)
            if($found.Count -eq 1){$answer.UserUsn=[string](Get-WPropFirst $found[0].Properties 'usnchanged' '');$answer.LinkUser=[string](Get-WPropFirst $found[0].Properties 'samaccountname' '');$answer.UserDn=[string](Get-WPropFirst $found[0].Properties 'distinguishedname' '');$g=Get-WPropFirst $found[0].Properties 'objectguid' $null;$answer.UserGuid=if($g -is [array] -and $g.Count -eq 16){([guid]([byte[]]$g)).ToString('D')}else{Convert-WGuid $g}}
        }catch{
            $code=Get-NativeCode $_
            $answer.DirectoryAuthRejected=($code -in @(2147943726,2147944309,2147943730,2147943731,2147943732,2147943734))
            $answer.Detail+=' Validation AD non confirmée : '+$_.Exception.Message
        }finally{try{if($null -ne $results){$results.Dispose()}}catch{};try{if($null -ne $searcher){$searcher.Dispose()}}catch{};try{if($null -ne $root){$root.Dispose()}}catch{}}
    }
}
[pscustomobject]$answer
'@
}

function Get-DomeniaLiveCacheCode {
    return @'
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
    if ($DatabaseHandle -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle) } catch { } }
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
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 4 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,300)
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
        throw
    }
    finally { if ($pathPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) } }
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
            if($cached.Count -eq 1 -and ([string]$cached[0].payload).Length -le 33554432){
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
            $records=@(Invoke-DomeniaDbQuery ("SELECT object_key,payload FROM adcc_live_observations WHERE scope_key=$qScope AND checked_utc>=strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days') ORDER BY checked_utc DESC LIMIT 5000;") $db)
            foreach($item in $records){
                if(([string]$item.payload).Length -gt 16384){continue}
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
BEGIN IMMEDIATE;
"@ $db)
    $transaction=$true
    if($null -ne $Payload.Query){
        $query=$Payload.Query
        $json=$query|ConvertTo-Json -Depth 5 -Compress
        if($json.Length -gt 33554432 -or @($query.Rows).Count -gt 20000){throw 'Cache de recherche trop volumineux.'}
        $sql='INSERT OR REPLACE INTO adcc_live_queries(scope_key,query_key,observed_utc,payload) VALUES('+((@($scope,[string]$query.QueryKey,[string]$query.ObservedUtc,$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
        [void](Invoke-DomeniaDbExec $sql $db)
    }
    foreach($observation in @($Payload.Observations)){
        if($null -eq $observation -or [string]::IsNullOrWhiteSpace([string]$observation.Key)){continue}
        $checkedForRetention=[string]$observation.UserCheckedUtc
        if([string]::IsNullOrWhiteSpace($checkedForRetention)){$checkedForRetention=[string]$observation.CheckedUtc}
        $json=$observation|ConvertTo-Json -Depth 3 -Compress
        if($json.Length -gt 16384){throw 'Observation trop volumineuse.'}
        $sql='INSERT OR REPLACE INTO adcc_live_observations(scope_key,object_key,checked_utc,payload) VALUES('+((@($scope,[string]$observation.Key,$checkedForRetention,$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
        [void](Invoke-DomeniaDbExec $sql $db)
        # D028: user_machine_links is written only by the single LocalStore writer.
    }
    # Retention affects only these new cache tables, never the existing AD index/history.
    [void](Invoke-DomeniaDbExec ("DELETE FROM adcc_live_queries WHERE scope_key=$qScope AND query_key IN (SELECT query_key FROM adcc_live_queries WHERE scope_key=$qScope ORDER BY observed_utc DESC LIMIT -1 OFFSET 20); DELETE FROM adcc_live_queries WHERE observed_utc<strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days'); DELETE FROM adcc_live_observations WHERE scope_key=$qScope AND object_key IN (SELECT object_key FROM adcc_live_observations WHERE scope_key=$qScope ORDER BY checked_utc DESC LIMIT -1 OFFSET 5000); DELETE FROM adcc_live_observations WHERE checked_utc<strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days'); COMMIT;") $db)
    $transaction=$false
    [pscustomobject]@{Mode='Write';Saved=@($Payload.Observations).Count}
}finally{
    if($transaction -and $db -ne [IntPtr]::Zero){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}}
    if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db}
}

'@
}
