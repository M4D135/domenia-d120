# Audit AD worker bodies (points 102 to 109). Each function returns ONE single-quoted here-string pinned by SHA-256
# in the closed worker registry; it receives $Context and $Payload. Every body is a bounded read started by an
# explicit gesture: no write, no secret attribute, no whole-domain enumeration.

function Get-DomeniaPasswordPolicyReadWorkerCode {
    return @'
# Point 102: the password policy that applies to ONE account. Reads the constructed msDS-ResultantPSO and the
# computed expiry of the account, the fine-grained policy it names (when readable), how many fine-grained policies
# this account can see, and the domain policy. No password and no secret attribute is requested.
$dn=[string]$Payload.Dn
if((-not $dn) -or ($dn.Length -gt 2048)){throw 'DN du compte absent ou invalide : aucune lecture.'}
$base=[string]$Context.BaseDn
function ConvertTo-PolicyInt64 {
    param($Value)
    if($null -eq $Value){return $null}
    if(($Value -is [long]) -or ($Value -is [int])){return [long]$Value}
    if($Value -is [string]){$n=0L;if([long]::TryParse($Value,[ref]$n)){return $n};return $null}
    try{
        $t=$Value.GetType();$flags=[Reflection.BindingFlags]::GetProperty
        $h=[long]$t.InvokeMember('HighPart',$flags,$null,$Value,$null);$l=[long]$t.InvokeMember('LowPart',$flags,$null,$Value,$null)
        if($l -lt 0){$l+=4294967296L}
        return (($h -shl 32) -bor $l)
    }catch{return $null}
}
function Read-PolicyBag {
    param($Entry,[string[]]$Names,[string[]]$Large)
    $bag=@{}
    $props=$Entry.psbase.get_Properties()
    foreach($name in $Names){
        if(-not $props.Contains($name)){continue}
        $values=$props.get_Item($name)
        if(($null -eq $values) -or ($values.Count -eq 0)){continue}
        $first=$values[0]
        if($Large -contains $name){$number=ConvertTo-PolicyInt64 $first;if($null -ne $number){$bag[$name]=$number}}
        else{$bag[$name]=[string]$first}
    }
    return $bag
}
function Get-PolicyMessage {
    param($ErrorValue)
    $text=[string]$ErrorValue.Exception.Message
    if($text.Length -gt 300){$text=$text.Substring(0,300)}
    return $text
}
$userNames=@('userAccountControl','msDS-User-Account-Control-Computed','pwdLastSet','msDS-UserPasswordExpiryTimeComputed','msDS-ResultantPSO')
$user=@{};$resultant='';$resultantError=''
$entry=New-WEntry $Context $dn
try{
    try{$entry.psbase.RefreshCache([string[]]$userNames)}
    catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        # A constructed attribute refused or unknown must not hide the plain ones.
        $resultantError=Get-PolicyMessage $_
        $entry.psbase.RefreshCache([string[]]@('userAccountControl','pwdLastSet'))
    }
    $user=Read-PolicyBag $entry @('userAccountControl','msDS-User-Account-Control-Computed','pwdLastSet','msDS-UserPasswordExpiryTimeComputed') @('pwdLastSet','msDS-UserPasswordExpiryTimeComputed')
    $props=$entry.psbase.get_Properties()
    if($props.Contains('msDS-ResultantPSO')){$resultant=[string]$props.get_Item('msDS-ResultantPSO').Value}
}finally{$entry.Dispose()}
$visible=-1;$visibleError=''
$searcher=$null
try{
    $searcher=New-WSearcher $Context ('CN=Password Settings Container,CN=System,'+$base) '(objectClass=msDS-PasswordSettings)' @('distinguishedName') 'OneLevel' 200
    $found=$searcher.FindAll()
    try{$visible=0;foreach($item in $found){$visible++}}finally{$found.Dispose()}
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    $visible=-1;$visibleError=Get-PolicyMessage $_
}finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
$psoNames=@('name','msDS-PasswordSettingsPrecedence','msDS-MinimumPasswordLength','msDS-PasswordHistoryLength','msDS-PasswordComplexityEnabled','msDS-PasswordReversibleEncryptionEnabled','msDS-MaximumPasswordAge','msDS-MinimumPasswordAge','msDS-LockoutThreshold','msDS-LockoutDuration','msDS-LockoutObservationWindow')
$psoLarge=@('msDS-MaximumPasswordAge','msDS-MinimumPasswordAge','msDS-LockoutDuration','msDS-LockoutObservationWindow')
$pso=$null;$psoError=''
if($resultant){
    $psoEntry=$null
    try{
        $psoEntry=New-WEntry $Context $resultant
        $psoEntry.psbase.RefreshCache([string[]]$psoNames)
        $pso=Read-PolicyBag $psoEntry $psoNames $psoLarge
        if($pso.Count -eq 0){$pso=$null;$psoError='Aucun attribut de la stratégie fine renvoyé.'}
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $pso=$null;$psoError=Get-PolicyMessage $_
    }finally{if($null -ne $psoEntry){$psoEntry.Dispose()}}
}
$domainNames=@('maxPwdAge','minPwdAge','minPwdLength','pwdHistoryLength','pwdProperties','lockoutThreshold','lockoutDuration','lockOutObservationWindow')
$domainLarge=@('maxPwdAge','minPwdAge','lockoutDuration','lockOutObservationWindow')
$domain=$null;$domainError=''
$domainEntry=$null
try{
    $domainEntry=New-WEntry $Context $base
    $domainEntry.psbase.RefreshCache([string[]]$domainNames)
    $domain=Read-PolicyBag $domainEntry $domainNames $domainLarge
    if($domain.Count -eq 0){$domain=$null;$domainError='Attributs de stratégie du domaine non renvoyés.'}
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    $domain=$null;$domainError=Get-PolicyMessage $_
}finally{if($null -ne $domainEntry){$domainEntry.Dispose()}}
[pscustomobject]@{Dn=$dn;User=$user;ResultantPso=$resultant;ResultantError=$resultantError;PsoVisibleCount=$visible;PsoVisibleError=$visibleError;Pso=$pso;PsoError=$psoError;Domain=$domain;DomainError=$domainError;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaGroupPathReadWorkerCode {
    return @'
# Point 103: nested group memberships of ONE object, read on demand and bounded: breadth-first over memberOf, 40
# groups per LDAP request (exact distinguished names only), at most MaxNodes groups, MaxDepth levels and Seconds
# seconds. A group that cannot be read is named with its reason. With a target group, the controller answers the
# transitive question itself (LDAP_MATCHING_RULE_IN_CHAIN). Nothing outside the named groups is enumerated.
$dn=[string]$Payload.Dn
if((-not $dn) -or ($dn.Length -gt 2048)){throw 'DN absent ou invalide : aucune lecture.'}
$maxNodes=[int]$Payload.MaxNodes;if(($maxNodes -lt 10) -or ($maxNodes -gt 5000)){$maxNodes=2000}
$maxDepth=[int]$Payload.MaxDepth;if(($maxDepth -lt 1) -or ($maxDepth -gt 32)){$maxDepth=16}
$seconds=[int]$Payload.Seconds;if(($seconds -lt 2) -or ($seconds -gt 60)){$seconds=10}
$target=[string]$Payload.TargetDn
if($target.Length -gt 2048){throw 'DN du groupe cible invalide : aucune lecture.'}
# Mode Confirm asks the controller about one group only, without walking the memberships again.
$mode=[string]$Payload.Mode
if($mode -notin @('Expand','Confirm')){$mode='Expand'}
if(($mode -eq 'Confirm') -and (-not $target)){throw 'Groupe cible absent : aucune lecture.'}
$base=[string]$Context.BaseDn
$watch=[Diagnostics.Stopwatch]::StartNew()
function Get-GroupMessage {
    param($ErrorValue)
    $text=[string]$ErrorValue.Exception.Message
    if($text.Length -gt 200){$text=$text.Substring(0,200)}
    return $text
}
function Read-GroupValues {
    # Values of an attribute in a search result, ranged answers included; Partial when the range is not the last one.
    param($Properties,[string]$Name)
    $values=[Collections.Generic.List[string]]::new();$partial=$false
    foreach($key in @($Properties.PropertyNames)){
        $k=[string]$key
        if(($k -ieq $Name) -or ($k -like ($Name+';range=*'))){
            if(($k -like '*;range=*') -and (-not $k.EndsWith('-*'))){$partial=$true}
            foreach($v in $Properties[$k]){if($null -ne $v){$values.Add([string]$v)}}
        }
    }
    return [pscustomobject]@{Values=$values.ToArray();Partial=$partial}
}
$startParents=@();$startComplete=$true;$startNote='';$startSid='';$primaryId=''
$nodes=[Collections.Generic.List[object]]::new()
$unread=[Collections.Generic.List[object]]::new()
$frontier=[Collections.Generic.List[string]]::new()
$depth=1;$truncated=$false;$truncatedReason=''
if($mode -eq 'Expand'){
    $startEntry=New-WEntry $Context $dn
    try{$start=Get-WAllProperties -Entry $startEntry -PropertyNames @('memberOf','objectSid','primaryGroupID','name','distinguishedName')}finally{$startEntry.Dispose()}
    $startParents=@($start['memberOf'])
    if($start.ContainsKey('__memberOfComplete')){$startComplete=[bool]@($start['__memberOfComplete'])[0];$startNote=[string]@($start['__memberOfNote'])[0]}
    $startSid=[string]@($start['objectSid'])[0]
    $primaryId=[string]@($start['primaryGroupID'])[0]
}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$seen.Add($dn)
foreach($parent in $startParents){if($parent -and $seen.Add([string]$parent)){$frontier.Add([string]$parent)}}
while($frontier.Count -gt 0){
    if($depth -gt $maxDepth){
        $truncated=$true;$truncatedReason='Profondeur maximale atteinte ('+$maxDepth+' niveaux).'
        foreach($left in $frontier){$unread.Add([pscustomobject]@{Dn=$left;Reason='Au-delà de la profondeur lue'})}
        break
    }
    $next=[Collections.Generic.List[string]]::new()
    for($i=0;$i -lt $frontier.Count;$i+=40){
        if($watch.Elapsed.TotalSeconds -gt $seconds){
            $truncated=$true;$truncatedReason='Temps de lecture épuisé ('+$seconds+' s).'
            for($j=$i;$j -lt $frontier.Count;$j++){$unread.Add([pscustomobject]@{Dn=$frontier[$j];Reason='Lecture arrêtée par la limite de temps'})}
            break
        }
        $chunk=$frontier.GetRange($i,[Math]::Min(40,$frontier.Count-$i))
        $local=[Collections.Generic.List[string]]::new()
        foreach($group in $chunk){
            if(($group -ieq $base) -or $group.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase)){$local.Add($group)}
            else{$unread.Add([pscustomobject]@{Dn=$group;Reason='Autre domaine ou partition : non lu depuis ce contrôleur'})}
        }
        if($local.Count -eq 0){continue}
        $filter='(|'+((@($local)|ForEach-Object{'(distinguishedName='+(Escape-WLdap $_)+')'}) -join '')+')'
        $found=@{}
        $searcher=$null
        try{
            $searcher=New-WSearcher $Context $base $filter @('distinguishedName','memberOf','objectSid','name','sAMAccountName','groupType','adminCount') 'Subtree' 0
            $results=$searcher.FindAll()
            try{
                foreach($r in $results){
                    $p=$r.Properties
                    $foundDn=[string](Get-WPropFirst $p 'distinguishedname' '')
                    if(-not $foundDn){continue}
                    $member=Read-GroupValues $p 'memberof'
                    $found[$foundDn.ToLowerInvariant()]=[pscustomobject]@{
                        Dn=$foundDn;Name=[string](Get-WPropFirst $p 'name' '');Sam=[string](Get-WPropFirst $p 'samaccountname' '')
                        Sid=(Convert-WSid (Get-WPropFirst $p 'objectsid' $null));GroupType=[string](Get-WPropFirst $p 'grouptype' '')
                        AdminCount=[string](Get-WPropFirst $p 'admincount' '');Parents=$member.Values;Partial=$member.Partial;Depth=$depth
                    }
                }
            }finally{$results.Dispose()}
        }catch{
            if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
            $why='Lecture refusée ou impossible : '+(Get-GroupMessage $_)
            foreach($group in $local){$unread.Add([pscustomobject]@{Dn=$group;Reason=$why})}
            continue
        }finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
        foreach($group in $local){
            $key=$group.ToLowerInvariant()
            if(-not $found.ContainsKey($key)){$unread.Add([pscustomobject]@{Dn=$group;Reason='Introuvable ou non lisible avec ce compte'});continue}
            $node=$found[$key]
            $nodes.Add($node)
            if($nodes.Count -ge $maxNodes){$truncated=$true;$truncatedReason='Limite de '+$maxNodes+' groupes atteinte.';break}
            foreach($parent in @($node.Parents)){if($parent -and $seen.Add([string]$parent)){$next.Add([string]$parent)}}
        }
        if($truncated){break}
    }
    if($truncated){
        foreach($left in $next){$unread.Add([pscustomobject]@{Dn=$left;Reason='Non lu : limite de lecture atteinte'})}
        break
    }
    $frontier=$next;$depth++
}
$primary=[pscustomobject]@{Sid='';Dn='';Name='';Error=''}
$rid=0L
if(($startSid -match '^S-1-5-21(-\d{1,10}){4}$') -and ([long]::TryParse($primaryId,[ref]$rid)) -and ($rid -gt 0)){
    $primarySid=$startSid.Substring(0,$startSid.LastIndexOf('-'))+'-'+$rid
    $primary.Sid=$primarySid
    $searcher=$null
    try{
        $searcher=New-WSearcher $Context $base ('(objectSid='+$primarySid+')') @('distinguishedName','name') 'Subtree' 1
        $hit=$searcher.FindOne()
        if($null -ne $hit){$primary.Dn=[string](Get-WPropFirst $hit.Properties 'distinguishedname' '');$primary.Name=[string](Get-WPropFirst $hit.Properties 'name' '')}
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $primary.Error=Get-GroupMessage $_
    }finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
}
$serverAnswer=$null;$serverError=''
if($target){
    $searcher=$null
    try{
        $searcher=New-WSearcher $Context $target ('(member:1.2.840.113556.1.4.1941:='+(Escape-WLdap $dn)+')') @('distinguishedName') 'Base' 1
        $hit=$searcher.FindOne()
        $serverAnswer=($null -ne $hit)
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $serverAnswer=$null;$serverError=Get-GroupMessage $_
    }finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
}
[pscustomobject]@{
    Dn=$dn;Mode=$mode;StartParents=$startParents;StartComplete=$startComplete;StartNote=$startNote;Nodes=$nodes.ToArray();Unread=$unread.ToArray()
    Truncated=$truncated;TruncatedReason=$truncatedReason;MaxNodes=$maxNodes;MaxDepth=$maxDepth;Seconds=$seconds;ElapsedMs=[long]$watch.ElapsedMilliseconds
    PrimaryGroup=$primary;TargetDn=$target;ServerAnswer=$serverAnswer;ServerError=$serverError;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')
}
'@
}

function Get-DomeniaDelegationReadWorkerCode {
    return @'
# Point 104: delegations on ONE object. Action Acl reads its security descriptor (owner and DACL, no SACL), keeps at
# most MaxAces entries with their origin, names the directory accounts they designate (one search per 40 SIDs) and
# the schema objects and extended rights they target (GUIDs present only, bounded). Action Token reads the
# transitive security groups (tokenGroups) of ONE trustee chosen by the operator, for the access estimate.
# Read only: no access control list is written.
$action=[string]$Payload.Action
if($action -notin @('Acl','Token')){throw 'Lecture des délégations inconnue.'}
$base=[string]$Context.BaseDn
function Get-AclMessage {
    param($ErrorValue)
    $text=[string]$ErrorValue.Exception.Message
    if($text.Length -gt 300){$text=$text.Substring(0,300)}
    return $text
}
function Invoke-AclSearch {
    param([string]$Root,[string]$Filter,[string[]]$Properties,[string]$Scope,[scriptblock]$OnResult)
    $searcher=$null
    try{
        $searcher=New-WSearcher $Context $Root $Filter $Properties $Scope 0
        $results=$searcher.FindAll()
        try{foreach($r in $results){& $OnResult $r.Properties}}finally{$results.Dispose()}
    }finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
}
if($action -eq 'Token'){
    $sid=[string]$Payload.Sid
    if($sid -notmatch '^S-1-5-21(-\d{1,10}){4}$'){throw 'SID de bénéficiaire invalide : seuls les comptes dʼun domaine se calculent.'}
    $state='Read';$message='';$groups=[Collections.Generic.List[string]]::new();$name=''
    $entry=$null
    try{
        $entry=New-WEntry $Context ('<SID='+$sid+'>')
        $entry.psbase.RefreshCache([string[]]@('tokenGroups','sAMAccountName','name'))
        $props=$entry.psbase.get_Properties()
        if($props.Contains('sAMAccountName')){$name=[string]$props.get_Item('sAMAccountName').Value}
        if(-not $name -and $props.Contains('name')){$name=[string]$props.get_Item('name').Value}
        if($props.Contains('tokenGroups')){foreach($value in $props.get_Item('tokenGroups')){$text=Convert-WSid $value;if($text){$groups.Add($text)}}}
        if($groups.Count -eq 0){$state='Unread';$message='tokenGroups non renvoyé : droit de lecture absent pour ce compte.'}
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $state=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
        $message=Get-AclMessage $_
    }finally{if($null -ne $entry){$entry.Dispose()}}
    return [pscustomobject]@{Action='Token';Sid=$sid;Name=$name;State=$state;Message=$message;GroupSids=$groups.ToArray();Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')}
}
$dn=[string]$Payload.Dn
if((-not $dn) -or ($dn.Length -gt 2048)){throw 'DN absent ou invalide : aucune lecture.'}
$max=[int]$Payload.MaxAces;if(($max -lt 10) -or ($max -gt 5000)){$max=1000}
$state='Read';$message='';$security=$null
try{$security=Get-WActiveDirectorySecurity -Context $Context -Dn $dn -IncludeOwner $true}
catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    $state=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
    $message=Get-AclMessage $_
}
$aces=[Collections.Generic.List[object]]::new();$total=0;$ownerSid='';$protected=$false;$classes=@()
$sidNames=@{};$sidError='';$guidNames=@{};$guidError=''
if($null -ne $security){
    $rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $total=$rules.Count
    try{$protected=[bool]$security.AreAccessRulesProtected}catch{$protected=$false}
    try{$ownerSid=[string]$security.GetOwner([Security.Principal.SecurityIdentifier]).Value}catch{$ownerSid=''}
    foreach($rule in $rules){
        if($aces.Count -ge $max){break}
        $aces.Add([pscustomobject]@{
            Sid=[string]$rule.IdentityReference.Value;AccessControlType=[string]$rule.AccessControlType;ActiveDirectoryRights=[string]$rule.ActiveDirectoryRights
            ObjectType=[string]$rule.ObjectType;InheritedObjectType=[string]$rule.InheritedObjectType;IsInherited=[bool]$rule.IsInherited
            InheritanceType=[string]$rule.InheritanceType;InheritanceFlags=[string]$rule.InheritanceFlags;PropagationFlags=[string]$rule.PropagationFlags
        })
    }
    $entry=$null
    try{
        $entry=New-WEntry $Context $dn
        $entry.psbase.RefreshCache([string[]]@('objectClass'))
        $classes=@(foreach($value in $entry.psbase.get_Properties().get_Item('objectClass')){[string]$value})
    }catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}}
    finally{if($null -ne $entry){$entry.Dispose()}}
    # Directory accounts named by the entries: exact SIDs of this domain family only, 40 per request.
    $sids=@(@($aces|ForEach-Object{$_.Sid})+@($ownerSid)|Where-Object{$_ -match '^S-1-5-21-'}|Select-Object -Unique -First 400)
    try{
        for($i=0;$i -lt $sids.Count;$i+=40){
            $chunk=@($sids[$i..([Math]::Min($i+39,$sids.Count-1))])
            $filter='(|'+(($chunk|ForEach-Object{'(objectSid='+$_+')'}) -join '')+')'
            Invoke-AclSearch $base $filter @('objectSid','sAMAccountName','name') 'Subtree' {
                param($p)
                $found=Convert-WSid (Get-WPropFirst $p 'objectsid' $null)
                if($found){$sam=[string](Get-WPropFirst $p 'samaccountname' '');if(-not $sam){$sam=[string](Get-WPropFirst $p 'name' '')};$sidNames[$found]=$sam}
            }
        }
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $sidError=Get-AclMessage $_
    }
    # Schema objects and extended rights actually present in the entries, 20 per request, 120 at most.
    $guids=@(@($aces|ForEach-Object{$_.ObjectType;$_.InheritedObjectType})|Where-Object{$_ -and ($_ -ne '00000000-0000-0000-0000-000000000000')}|ForEach-Object{$_.ToLowerInvariant()}|Select-Object -Unique -First 120)
    if($guids.Count){
        $root=$null
        try{
            $root=New-WRootDse $Context
            $root.psbase.RefreshCache([string[]]@('schemaNamingContext','configurationNamingContext'))
            $schemaNc=[string]$root.psbase.get_Properties().get_Item('schemaNamingContext').Value
            $configNc=[string]$root.psbase.get_Properties().get_Item('configurationNamingContext').Value
            for($i=0;$i -lt $guids.Count;$i+=20){
                $chunk=@($guids[$i..([Math]::Min($i+19,$guids.Count-1))])
                if($schemaNc){
                    $filter='(|'+(($chunk|ForEach-Object{'(schemaIDGUID='+((([guid]$_).ToByteArray()|ForEach-Object{'\'+$_.ToString('x2')}) -join '')+')'}) -join '')+')'
                    Invoke-AclSearch $schemaNc $filter @('lDAPDisplayName','schemaIDGUID') 'OneLevel' {
                        param($p)
                        $g=Convert-WGuid (Get-WPropFirst $p 'schemaidguid' $null)
                        if($g){$guidNames[$g.ToLowerInvariant()]=[string](Get-WPropFirst $p 'ldapdisplayname' '')}
                    }
                }
                if($configNc){
                    $filter='(|'+(($chunk|ForEach-Object{'(rightsGuid='+$_+')'}) -join '')+')'
                    Invoke-AclSearch ('CN=Extended-Rights,'+$configNc) $filter @('displayName','rightsGuid') 'OneLevel' {
                        param($p)
                        $g=([string](Get-WPropFirst $p 'rightsguid' '')).ToLowerInvariant()
                        if($g -and (-not $guidNames.ContainsKey($g))){$guidNames[$g]=[string](Get-WPropFirst $p 'displayname' '')}
                    }
                }
            }
        }catch{
            if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
            $guidError=Get-AclMessage $_
        }finally{if($null -ne $root){$root.Dispose()}}
    }
}
[pscustomobject]@{
    Action='Acl';Dn=$dn;State=$state;Message=$message;Total=$total;Truncated=($total -gt $aces.Count);MaxAces=$max;Aces=$aces.ToArray()
    OwnerSid=$ownerSid;Protected=$protected;ObjectClasses=$classes;SidNames=$sidNames;SidNamesError=$sidError;GuidNames=$guidNames;GuidNamesError=$guidError
    Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')
}
'@
}

function Get-DomeniaGpoLinksReadWorkerCode {
    return @'
# Point 105: GPO links of ONE object, read in AD only. Payload.Containers is the chain computed by
# Get-DomeniaGpoContainerChain (OU levels then domain root, closest first): each level is read on its own (gPLink,
# gPOptions) and a refused level is reported, never skipped silently. The names and states of the GPOs found are
# read under CN=Policies with bounded searches. Site links are not read.
$base=[string]$Context.BaseDn
$containers=@(@($Payload.Containers)|ForEach-Object{[string]$_}|Where-Object{$_})
if(($containers.Count -lt 1) -or ($containers.Count -gt 40)){throw 'Chaîne de conteneurs absente ou trop longue : aucune lecture.'}
foreach($container in $containers){
    if(($container -ine $base) -and (-not $container.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase))){throw 'Conteneur hors du domaine connecté : aucune lecture.'}
}
function Get-GpoMessage {
    param($ErrorValue)
    $text=[string]$ErrorValue.Exception.Message
    if($text.Length -gt 300){$text=$text.Substring(0,300)}
    return $text
}
$rows=[Collections.Generic.List[object]]::new()
$guids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($container in $containers){
    $row=[pscustomobject]@{Dn=$container;GpLink='';GpOptions=0;ReadStatus='OK';Error=''}
    $entry=$null
    try{
        $entry=New-WEntry $Context $container
        $entry.psbase.RefreshCache([string[]]@('gPLink','gPOptions'))
        $p=$entry.psbase.get_Properties()
        if($p.Contains('gPLink')){$row.GpLink=[string]$p.get_Item('gPLink').Value}
        if($p.Contains('gPOptions')){$row.GpOptions=[int]$p.get_Item('gPOptions').Value}
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $row.ReadStatus=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'AccessDenied'}else{'Error'}
        $row.Error=Get-GpoMessage $_
    }finally{if($null -ne $entry){$entry.Dispose()}}
    foreach($m in [regex]::Matches([string]$row.GpLink,'(?i)cn=\{([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}')){[void]$guids.Add($m.Groups[1].Value.ToLowerInvariant())}
    $rows.Add($row)
}
$gpos=[Collections.Generic.List[object]]::new();$namesStatus='OK';$namesError=''
$list=@($guids|Select-Object -First 200)
if($list.Count){
    try{
        for($i=0;$i -lt $list.Count;$i+=40){
            $chunk=@($list[$i..([Math]::Min($i+39,$list.Count-1))])
            $filter='(|'+(($chunk|ForEach-Object{'(cn={'+$_+'})'}) -join '')+')'
            $searcher=$null
            try{
                $searcher=New-WSearcher $Context ('CN=Policies,CN=System,'+$base) $filter @('cn','displayName','flags','whenChanged') 'OneLevel' 0
                $results=$searcher.FindAll()
                try{
                    foreach($r in $results){
                        $p=$r.Properties
                        $cn=([string](Get-WPropFirst $p 'cn' '')).Trim('{','}')
                        $gpos.Add([pscustomobject]@{Guid=$cn;Name=[string](Get-WPropFirst $p 'displayname' '');Flags=[string](Get-WPropFirst $p 'flags' '');WhenChanged=(Convert-WDate (Get-WPropFirst $p 'whenchanged' $null))})
                    }
                }finally{$results.Dispose()}
            }finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
        }
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $namesStatus='Error';$namesError=Get-GpoMessage $_
    }
}
[pscustomobject]@{Containers=$rows.ToArray();Gpos=$gpos.ToArray();NamesStatus=$namesStatus;NamesError=$namesError;SitesRead=$false;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaGpoAppliedReadWorkerCode {
    return @'
# Point 105: the result last applied on ONE workstation, read by CIM in root\rsop\computer (RSOP_GPO and
# RSOP_GPLink) on an explicit gesture. No gpresult, no method call and no policy refresh. An empty or partial answer
# is reported as such: it never means "nothing applied".
$computer=[string]$Payload.Computer
if($computer -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'){throw 'Nom de poste invalide : aucune lecture.'}
function Get-RsopMessage {
    param($ErrorValue)
    $text=[string]$ErrorValue.Exception.Message
    if($text.Length -gt 300){$text=$text.Substring(0,300)}
    return $text
}
$credential=Get-WMachineCredential $Context
$session=$null;$status='OK';$message='';$gpos=$null;$links=$null;$linksError=''
try{
    try{$session=New-WDomeniaCimSession $Context $computer $credential 20}
    catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}
        $status=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'AccessDenied'}else{'Unavailable'}
        $message=Get-RsopMessage $_
    }
    if($null -ne $session){
        try{
            $gpos=@(Get-CimInstance -CimSession $session -Namespace 'root\rsop\computer' -ClassName 'RSOP_GPO' -OperationTimeoutSec 30 -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{Name=[string]$_.name;GuidName=[string]$_.guidName;Id=[string]$_.id;AccessDenied=$_.accessDenied;FilterAllowed=$_.filterAllowed;Enabled=$_.enabled}
            })
        }catch{
            if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}
            $status=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'AccessDenied'}else{'Unavailable'}
            $message=Get-RsopMessage $_;$gpos=$null
        }
        if($status -eq 'OK'){
            try{
                $links=@(Get-CimInstance -CimSession $session -Namespace 'root\rsop\computer' -ClassName 'RSOP_GPLink' -OperationTimeoutSec 30 -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{Gpo=[string]$_.GPO;Som=[string]$_.SOM;AppliedOrder=$_.appliedOrder;LinkOrder=$_.linkOrder;Enabled=$_.enabled;NoOverride=$_.noOverride}
                })
            }catch{
                if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}
                $links=$null;$linksError=Get-RsopMessage $_
            }
        }
    }
}finally{Remove-WDomeniaCimSession $session}
[pscustomobject]@{Computer=$computer;ReadStatus=$status;Message=$message;Gpos=$gpos;Links=$links;LinksError=$linksError;ReadUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaAdHealthReadWorkerCode {
    return @'
# Point 108: targeted controller diagnosis without administrative rights. Action List reads the controller accounts
# of the domain (at most 100) and the PDC emulator. Action Probe takes at most 10 controllers chosen by the operator:
# DNS name resolution, TCP 389 and 88, RootDSE (time, synchronisation, highest USN) and inbound replication
# (msDS-ReplAllInboundNeighbors), plus the SRV records of the domain. Nothing runs on the controllers.
$action=[string]$Payload.Action
if($action -notin @('List','Probe')){throw 'Diagnostic des contrôleurs inconnu.'}
$base=[string]$Context.BaseDn
function Get-HealthMessage {
    param($ErrorValue)
    $text=[string]$ErrorValue.Exception.Message
    if($text.Length -gt 300){$text=$text.Substring(0,300)}
    return $text
}
function Get-HealthPdc {
    $pdc=''
    $domainEntry=New-WEntry $Context $base
    try{$domainEntry.psbase.RefreshCache([string[]]@('fSMORoleOwner'));$owner=[string]$domainEntry.psbase.get_Properties().get_Item('fSMORoleOwner').Value}finally{$domainEntry.Dispose()}
    if($owner -match '^CN=NTDS Settings,(CN=[^,]+,CN=Servers,.+)$'){
        $serverEntry=New-WEntry $Context $matches[1]
        try{$serverEntry.psbase.RefreshCache([string[]]@('dNSHostName'));$pdc=[string]$serverEntry.psbase.get_Properties().get_Item('dNSHostName').Value}finally{$serverEntry.Dispose()}
    }
    return $pdc
}
if($action -eq 'List'){
    $rows=[Collections.Generic.List[object]]::new()
    $filter='(&(objectCategory=computer)(|(userAccountControl:1.2.840.113556.1.4.803:=8192)(userAccountControl:1.2.840.113556.1.4.803:=67108864)))'
    $searcher=$null
    try{
        $searcher=New-WSearcher $Context $base $filter @('name','dNSHostName','operatingSystem','serverReferenceBL','userAccountControl','distinguishedName') 'Subtree' 101
        $results=$searcher.FindAll()
        try{
            foreach($r in $results){
                $p=$r.Properties
                $reference=[string](Get-WPropFirst $p 'serverreferencebl' '')
                $site=''
                if($reference -match '^CN=[^,]+,CN=Servers,CN=([^,]+),CN=Sites,'){$site=$matches[1]}
                $uac=[long](Convert-WLargeInteger (Get-WPropFirst $p 'useraccountcontrol' 0))
                $rows.Add([pscustomobject]@{Name=[string](Get-WPropFirst $p 'name' '');DnsHostName=[string](Get-WPropFirst $p 'dnshostname' '');Os=[string](Get-WPropFirst $p 'operatingsystem' '');Site=$site;ReadOnly=(($uac -band 67108864) -ne 0);Dn=[string](Get-WPropFirst $p 'distinguishedname' '')})
            }
        }finally{$results.Dispose()}
    }finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
    $pdc='';$pdcError=''
    try{$pdc=Get-HealthPdc}catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw};$pdcError=Get-HealthMessage $_}
    $list=@($rows.ToArray()|Select-Object -First 100)
    return [pscustomobject]@{Action='List';Dcs=$list;Truncated=($rows.Count -gt 100);Pdc=$pdc;PdcError=$pdcError;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')}
}
$dcs=@(@($Payload.Dcs)|ForEach-Object{([string]$_).Trim()}|Where-Object{$_}|Select-Object -Unique)
if(($dcs.Count -lt 1) -or ($dcs.Count -gt 10)){throw 'Choisissez de 1 à 10 contrôleurs.'}
foreach($dc in $dcs){if($dc -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'){throw 'Nom de contrôleur invalide : aucune lecture.'}}
$domainDns=[string]$Payload.DomainDns
if($domainDns -and ($domainDns -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$')){$domainDns=''}
$timeout=[int]$Context.PortTimeoutMs;if(($timeout -lt 500) -or ($timeout -gt 3000)){$timeout=1500}
$srv=@();$srvState='NotChecked';$srvError=''
if($domainDns){
    if($null -ne (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)){
        try{
            $srv=@(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.'+$domainDns) -Type SRV -DnsOnly -ErrorAction Stop | Where-Object{[string]$_.Type -eq 'SRV'} | ForEach-Object{([string]$_.NameTarget).TrimEnd('.')})
            $srvState='Read'
        }catch{$srvState='Error';$srvError=Get-HealthMessage $_}
    }else{$srvState='ModuleMissing'}
}
$results=[Collections.Generic.List[object]]::new()
$originalServer=[string]$Context.Server
try{
    foreach($dc in $dcs){
        $r=[pscustomobject]@{Dc=$dc;Addresses=@();DnsError='';Ldap=$false;Kerberos=$false;RootDse='NotRead';RootDseError='';CurrentTime='';LocalUtc='';RoundTripMs=0;IsSynchronized='';IsGlobalCatalogReady='';HighestUsn='';ReplState='NotRead';ReplError='';Neighbors=@()}
        try{$r.Addresses=@([Net.Dns]::GetHostAddresses($dc)|ForEach-Object{$_.IPAddressToString})}catch{$r.DnsError=Get-HealthMessage $_}
        $r.Ldap=[bool](Test-WTcpPort $dc 389 $timeout)
        $r.Kerberos=[bool](Test-WTcpPort $dc 88 $timeout)
        if($r.Ldap){
            $Context.Server=$dc
            $root=$null
            try{
                $watch=[Diagnostics.Stopwatch]::StartNew()
                $root=New-WRootDse $Context
                $root.psbase.RefreshCache([string[]]@('currentTime','isSynchronized','isGlobalCatalogReady','highestCommittedUSN','dnsHostName'))
                $watch.Stop();$localUtc=[datetime]::UtcNow
                $p=$root.psbase.get_Properties()
                $time=$p.get_Item('currentTime').Value
                if($time -is [datetime]){$r.CurrentTime=[datetime]::SpecifyKind($time,[DateTimeKind]::Utc).ToString('o')}else{$r.CurrentTime=[string]$time}
                $r.LocalUtc=$localUtc.ToString('o');$r.RoundTripMs=[int]$watch.ElapsedMilliseconds
                $r.IsSynchronized=[string]$p.get_Item('isSynchronized').Value
                $r.IsGlobalCatalogReady=[string]$p.get_Item('isGlobalCatalogReady').Value
                $r.HighestUsn=[string]$p.get_Item('highestCommittedUSN').Value
                $r.RootDse='Read'
                try{
                    $root.psbase.RefreshCache([string[]]@('msDS-ReplAllInboundNeighbors'))
                    $values=@(foreach($value in $root.psbase.get_Properties().get_Item('msDS-ReplAllInboundNeighbors')){[string]$value})
                    if($values.Count){$r.Neighbors=$values;$r.ReplState='Read'}else{$r.ReplState='Empty'}
                }catch{
                    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
                    $r.ReplState='Error';$r.ReplError=Get-HealthMessage $_
                }
            }catch{
                if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
                $r.RootDse=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Error'}
                $r.RootDseError=Get-HealthMessage $_
            }finally{
                if($null -ne $root){$root.Dispose()}
                $Context.Server=$originalServer
            }
        }
        $results.Add($r)
    }
}finally{$Context.Server=$originalServer}
[pscustomobject]@{Action='Probe';Results=$results.ToArray();Srv=$srv;SrvState=$srvState;SrvError=$srvError;DomainDns=$domainDns;Pdc=[string]$Payload.Pdc;ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaDcServicesReadWorkerCode {
    return @'
# Point 108: privileged probe, on its own explicit gesture. State of the directory services of at most 10 chosen
# controllers (NTDS, Netlogon, KDC, W32Time, ADWS, DNS, DFSR, NtFrs) read by CIM. It needs administrative rights on
# each controller; a refusal is reported per controller. Nothing is started, stopped or changed.
$dcs=@(@($Payload.Dcs)|ForEach-Object{([string]$_).Trim()}|Where-Object{$_}|Select-Object -Unique)
if(($dcs.Count -lt 1) -or ($dcs.Count -gt 10)){throw 'Choisissez de 1 à 10 contrôleurs.'}
foreach($dc in $dcs){if($dc -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'){throw 'Nom de contrôleur invalide : aucune lecture.'}}
$filter=(@('NTDS','Netlogon','Kdc','W32Time','ADWS','DNS','DFSR','NtFrs')|ForEach-Object{"Name='"+$_+"'"}) -join ' OR '
$credential=Get-WMachineCredential $Context
$results=[Collections.Generic.List[object]]::new()
foreach($dc in $dcs){
    $state='Read';$message='';$services=@();$session=$null
    try{
        $session=New-WDomeniaCimSession $Context $dc $credential 15
        $services=@(Get-CimInstance -CimSession $session -ClassName Win32_Service -Filter $filter -Property Name,State,StartMode -OperationTimeoutSec 20 -ErrorAction Stop | ForEach-Object {[pscustomobject]@{Name=[string]$_.Name;State=[string]$_.State;StartMode=[string]$_.StartMode}})
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}
        $state=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
        $message=[string]$_.Exception.Message;if($message.Length -gt 300){$message=$message.Substring(0,300)}
    }finally{Remove-WDomeniaCimSession $session}
    $results.Add([pscustomobject]@{Dc=$dc;State=$state;Message=$message;Services=$services})
}
[pscustomobject]@{Results=$results.ToArray();ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaAdConsistencyScanWorkerCode {
    return @'
# Point 109: identity attributes of the users and computers of ONE organisational unit (subtree on request),
# bounded to Limit objects, for the consistency review. No password and no secret attribute; the domain root is
# refused as a base with its whole subtree.
$ou=[string]$Payload.BaseDn
$subtree=[bool]$Payload.Subtree
$limit=[int]$Payload.Limit;if(($limit -lt 100) -or ($limit -gt 20000)){$limit=5000}
$base=[string]$Context.BaseDn
if((-not $ou) -or (($ou -ine $base) -and (-not $ou.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase)))){throw 'OU hors du domaine connecté : aucune lecture.'}
if(($ou -ieq $base) -and $subtree){throw 'Le domaine entier nʼest pas analysé : choisissez une OU.'}
$properties=@('objectGUID','name','sAMAccountName','userPrincipalName','mail','employeeID','dNSHostName','objectClass','userAccountControl','lastLogonTimestamp','pwdLastSet','description','department','manager','whenCreated','distinguishedName')
$filter='(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer))'
$rows=[Collections.Generic.List[object]]::new();$truncated=$false
$searcher=$null
try{
    $searcher=New-WSearcher $Context $ou $filter $properties $(if($subtree){'Subtree'}else{'OneLevel'}) ($limit+1)
    $results=$searcher.FindAll()
    try{
        foreach($r in $results){
            if($rows.Count -ge $limit){$truncated=$true;break}
            $p=$r.Properties
            $classes=@(Get-WPropAll $p 'objectclass'|ForEach-Object{([string]$_).ToLowerInvariant()})
            $pwdRaw=Get-WPropFirst $p 'pwdlastset' $null
            $logonRaw=Get-WPropFirst $p 'lastlogontimestamp' $null
            $rows.Add([pscustomobject]@{
                Guid=(Convert-WGuid (Get-WPropFirst $p 'objectguid' $null));Name=[string](Get-WPropFirst $p 'name' '');Sam=[string](Get-WPropFirst $p 'samaccountname' '')
                Upn=[string](Get-WPropFirst $p 'userprincipalname' '');Mail=[string](Get-WPropFirst $p 'mail' '');EmployeeId=[string](Get-WPropFirst $p 'employeeid' '')
                DnsHostName=[string](Get-WPropFirst $p 'dnshostname' '');Type=$(if($classes -contains 'computer'){'Machine'}else{'Utilisateur'})
                Uac=[string](Get-WPropFirst $p 'useraccountcontrol' '');LastLogon=$(if($null -ne $logonRaw){[long](Convert-WLargeInteger $logonRaw)}else{$null})
                PwdLastSet=$(if($null -ne $pwdRaw){[long](Convert-WLargeInteger $pwdRaw)}else{$null})
                Description=[string](Get-WPropFirst $p 'description' '');Department=[string](Get-WPropFirst $p 'department' '');Manager=[string](Get-WPropFirst $p 'manager' '')
                WhenCreated=(Convert-WDate (Get-WPropFirst $p 'whencreated' $null));Dn=[string](Get-WPropFirst $p 'distinguishedname' '')
            })
        }
    }finally{$results.Dispose()}
}finally{if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}}
[pscustomobject]@{BaseDn=$ou;Subtree=$subtree;Limit=$limit;Rows=$rows.ToArray();Truncated=$truncated;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaMachineIdentityReadWorkerCode {
    return @'
# Point 109: identity of ONE workstation as seen by DNS from this computer (forward and reverse resolution) and by
# the workstation itself (CIM Win32_ComputerSystem), on an explicit gesture. The AD side comes from the payload.
# Feeds Test-DomeniaMachineIdentityCoherence: nothing is attributed, merged or renamed here.
$name=[string]$Payload.DnsHostName
if(-not $name){$name=[string]$Payload.Name}
$name=$name.Trim().TrimEnd('.')
if($name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'){throw 'Nom de poste invalide : aucune lecture.'}
$resolution=[pscustomobject]@{Status='OK';Addresses=@();PtrName='';Message=''}
try{
    $resolution.Addresses=@([Net.Dns]::GetHostAddresses($name)|Where-Object{$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|ForEach-Object{$_.IPAddressToString})
    if($resolution.Addresses.Count -gt 0){try{$resolution.PtrName=[string][Net.Dns]::GetHostEntry([string]$resolution.Addresses[0]).HostName}catch{$resolution.PtrName=''}}
}catch{$resolution.Status='NotFound';$resolution.Message=[string]$_.Exception.Message}
$reported=[pscustomobject]@{Status='OK';ComputerName='';DnsHostName='';Domain='';Message=''}
$session=$null
try{
    $session=New-WDomeniaCimSession $Context $name (Get-WMachineCredential $Context) 15
    $system=@(Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -OperationTimeoutSec 20 -ErrorAction Stop)[0]
    $reported.ComputerName=[string]$system.Name;$reported.Domain=[string]$system.Domain
    if($null -ne $system.PSObject.Properties['DNSHostName']){$reported.DnsHostName=[string]$system.DNSHostName}
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}
    $reported.Status=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'AccessDenied'}else{'Unavailable'}
    $reported.Message=[string]$_.Exception.Message
}finally{Remove-WDomeniaCimSession $session}
[pscustomobject]@{Name=$name;Resolution=$resolution;Reported=$reported;ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}

function Get-DomeniaRelationHistoryReadWorkerCode {
    return @'
# Point 107: stored history of the user / workstation relations (table user_machine_history) of ONE user login or
# ONE workstation, read only from the local base with a short busy timeout, most recent first, Limit rows at most.
$kind=[string]$Payload.Kind
if($kind -notin @('User','Computer')){throw 'Historique demandé pour un sujet inconnu.'}
$key=([string]$Payload.Key).Trim()
if((-not $key) -or ($key.Length -gt 256)){throw 'Sujet de lʼhistorique absent ou invalide.'}
$limit=[int]$Payload.Limit;if(($limit -lt 1) -or ($limit -gt 1000)){$limit=200}
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
if($path.StartsWith('\\')){throw 'Base locale réseau non prise en charge.'}
if(-not [IO.File]::Exists($path)){return [pscustomobject]@{Rows=@();Total=0;Busy=$false;Missing=$true;Kind=$kind;Key=$key;Limit=$limit}}
$busyMs=[Math]::Max(10,[Math]::Min(1000,[int]$Payload.BusyTimeoutMs))
function New-HistUtf8 {
    param([AllowEmptyString()][string]$Text)
    $bytes=[Text.Encoding]::UTF8.GetBytes(([string]$Text)+[char]0)
    $ptr=[Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-HistUtf8 {
    param([IntPtr]$Pointer,[int]$Length=-1)
    if($Pointer -eq [IntPtr]::Zero){return ''}
    if($Length -lt 0){$Length=0;while([Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0){$Length++}}
    if($Length -le 0){return ''}
    $bytes=New-Object byte[] $Length
    [Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function Invoke-HistQuery {
    param([IntPtr]$Db,[string]$Sql)
    $sqlPtr=[IntPtr]::Zero;$stmt=[IntPtr]::Zero
    $rows=[Collections.Generic.List[object]]::new()
    try{
        $sqlPtr=New-HistUtf8 $Sql
        $rc=[Domenia.WinSqliteNative]::sqlite3_prepare_v2($Db,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if(($rc -eq 5) -or ($rc -eq 6)){throw 'SQLITE_BUSY'}
        if($rc -ne 0){throw ('SQLite prepare code '+$rc+' : '+(ConvertFrom-HistUtf8 ([Domenia.WinSqliteNative]::sqlite3_errmsg($Db))))}
        $count=[Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        $names=New-Object 'string[]' ([Math]::Max(0,$count))
        for($i=0;$i -lt $count;$i++){$names[$i]=ConvertFrom-HistUtf8 ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))}
        while(($step=[Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100){
            $o=[ordered]@{}
            for($i=0;$i -lt $count;$i++){
                $type=[Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i);$value=$null
                if($type -eq 1){$value=[long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i)}
                elseif($type -eq 2){$value=[double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i)}
                elseif($type -ne 5){$p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i);$n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i);$value=ConvertFrom-HistUtf8 $p $n}
                $o[$names[$i]]=$value
            }
            $rows.Add([pscustomobject]$o)
        }
        if(($step -eq 5) -or ($step -eq 6)){throw 'SQLITE_BUSY'}
        if($step -ne 101){throw ('SQLite step code '+$step+' : '+(ConvertFrom-HistUtf8 ([Domenia.WinSqliteNative]::sqlite3_errmsg($Db))))}
        return $rows.ToArray()
    }finally{
        if($stmt -ne [IntPtr]::Zero){try{[void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt)}catch{}}
        if($sqlPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr)}
    }
}
$literal="'"+($key -replace "'","''")+"'"
$where=if($kind -eq 'User'){'user_login='+$literal+' COLLATE NOCASE'}else{'computer_key='+$literal+' COLLATE NOCASE'}
$db=[IntPtr]::Zero
try{
    $pathPtr=New-HistUtf8 $path
    try{$rc=[Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,(1 -bor 65536),[IntPtr]::Zero)}
    finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr)}
    if(($rc -ne 0) -or ($db -eq [IntPtr]::Zero)){throw ('Ouverture SQLite en lecture impossible (code '+$rc+').')}
    [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
    if(@(Invoke-HistQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='user_machine_history';").Count -eq 0){
        return [pscustomobject]@{Rows=@();Total=0;Busy=$false;Missing=$true;Kind=$kind;Key=$key;Limit=$limit}
    }
    [void](Invoke-HistQuery $db 'BEGIN;')
    $total=[long](@(Invoke-HistQuery $db ('SELECT count(*) AS n FROM user_machine_history WHERE '+$where+';'))[0].n)
    $rows=@(Invoke-HistQuery $db ('SELECT user_login,computer_key,computer,source,verified_in_ad,observed_at,details,user_guid,computer_guid FROM user_machine_history WHERE '+$where+' ORDER BY observed_at DESC,id DESC LIMIT '+$limit+';'))
    [void](Invoke-HistQuery $db 'COMMIT;')
    [pscustomobject]@{Rows=$rows;Total=$total;Busy=$false;Missing=$false;Kind=$kind;Key=$key;Limit=$limit}
}catch{
    if([string]$_.Exception.Message -eq 'SQLITE_BUSY'){[pscustomobject]@{Rows=@();Total=0;Busy=$true;Missing=$false;Kind=$kind;Key=$key;Limit=$limit}}
    else{throw}
}finally{if($db -ne [IntPtr]::Zero){try{[void][Domenia.WinSqliteNative]::sqlite3_close($db)}catch{}}}
'@
}
