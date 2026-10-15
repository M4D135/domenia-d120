function Get-DomeniaGroupPathWorkerCode {
return @'
# UI-06 / D064 (« Pourquoi membre ? », « Afficher les groupes imbriqués » on the fiche) and point 103 (Outils > Audit
# AD): nested group memberships of ONE object, read on an explicit gesture only and bounded: breadth-first over
# memberOf, 40 groups per LDAP request (exact distinguished names only), at most MaxNodes groups, MaxDepth levels and
# Seconds seconds. A group that cannot be read is named with its reason. With a target group, the controller answers
# the transitive question itself (LDAP_MATCHING_RULE_IN_CHAIN). Nothing outside the named groups is enumerated.
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
# One authentication attempt at a time (credential guard): the lease is released after the first answer of the
# controller (the object read in mode Expand, the target question in mode Confirm), and always at the end.
$lease=Enter-WCredentialAttempt -Context $Context -Channel Directory
try{
    if($mode -eq 'Expand'){
        $startEntry=$null
        try{
            $startEntry=New-WEntry $Context $dn
            $start=Get-WAllProperties -Entry $startEntry -PropertyNames @('memberOf','objectSid','primaryGroupID','name','distinguishedName')
        }catch{
            [void](Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory)
            throw
        }finally{
            if($null -ne $startEntry){$startEntry.Dispose()}
            Exit-WCredentialAttempt $lease;$lease=$null
        }
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
                if(($group -ieq $base) -or ($group.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase))){$local.Add($group)}
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
        }finally{
            if($null -ne $searcher){try{$searcher.SearchRoot.Dispose()}catch{};$searcher.Dispose()}
            if($null -ne $lease){Exit-WCredentialAttempt $lease;$lease=$null}
        }
    }
}finally{if($null -ne $lease){Exit-WCredentialAttempt $lease}}
[pscustomobject]@{
    Dn=$dn;Mode=$mode;StartParents=$startParents;StartComplete=$startComplete;StartNote=$startNote;Nodes=$nodes.ToArray();Unread=$unread.ToArray()
    Truncated=$truncated;TruncatedReason=$truncatedReason;MaxNodes=$maxNodes;MaxDepth=$maxDepth;Seconds=$seconds;ElapsedMs=[long]$watch.ElapsedMilliseconds
    PrimaryGroup=$primary;TargetDn=$target;ServerAnswer=$serverAnswer;ServerError=$serverError;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o')
}
'@
}
