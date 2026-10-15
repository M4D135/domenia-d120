function Get-DomeniaAbsenceCheckWorkerCode {
return @'
# Points 23 and 24: objects that a complete read did not return, read again by GUID on explicit request. First in the
# whole domain (an object found elsewhere was moved, not deleted), then among the deleted objects (isDeleted proves a
# deletion). An empty answer from the deleted objects proves nothing unless this account can read them.
# Bounded: 200 identities, batches of 24, 60 seconds. Nothing is written in the directory.
$items=@($Payload.Items)
if(($items.Count -lt 1) -or ($items.Count -gt 200)){throw 'Lot de vérification invalide : de 1 à 200 objets.'}
$baseDn=[string]$Context.BaseDn
if(-not $baseDn){throw 'Domaine non connecté : aucune vérification.'}
$requested=[ordered]@{}
foreach($item in $items){
    $g=[guid]::Empty
    if((-not [guid]::TryParse([string]$item.Guid,[ref]$g)) -or ($g -eq [guid]::Empty)){continue}
    $requested[$g.ToString('D').ToLowerInvariant()]=$g
}
if(-not $requested.Count){throw 'Aucun GUID valide à vérifier.'}
$watch=[Diagnostics.Stopwatch]::StartNew();$budgetSeconds=60
function Get-AbsenceGuidClause {
    param([guid]$Value)
    return '(objectGUID='+(($Value.ToByteArray()|ForEach-Object{'\'+$_.ToString('X2')}) -join '')+')'
}
function Clean-AbsenceField {
    param($Value)
    $text='';if($null -ne $Value){$text=[string]$Value}
    return ($text -replace '[\t\r\n]',' ').Trim()
}
function New-AbsenceIndexRecord {
    # Same columns and formats as the index read, so that a found object replaces its old row under the same GUID.
    param($Props,[string]$Type,[string]$Guid)
    $upn='';$extra=''
    if($Type -eq 'Utilisateur'){
        $upn=Clean-AbsenceField (Get-WPropFirst $Props 'userprincipalname' '')
        $extra=Clean-AbsenceField (Get-WPropFirst $Props 'department' '')
        $title=Clean-AbsenceField (Get-WPropFirst $Props 'title' '')
        if($title){if($extra){$extra=$extra+' / '+$title}else{$extra=$title}}
    }else{
        $upn=Clean-AbsenceField (Get-WPropFirst $Props 'dnshostname' '')
        $extra=Clean-AbsenceField (Get-WPropFirst $Props 'operatingsystem' '')
        $location=Clean-AbsenceField (Get-WPropFirst $Props 'location' '')
        if($location){if($extra){$extra=$extra+' / '+$location}else{$extra=$location}}
    }
    $uac=0;try{$uac=[int](Get-WPropFirst $Props 'useraccountcontrol' 0)}catch{$uac=0}
    $usn=0L;try{$usn=[int64](Get-WPropFirst $Props 'usnchanged' 0)}catch{$usn=0L}
    $lastLogon='';try{$lastLogon=Clean-AbsenceField (Convert-WFileTime (Get-WPropFirst $Props 'lastlogontimestamp' 0))}catch{$lastLogon=''}
    return [pscustomobject]@{
        Type=$Type;WhenChanged=(Clean-AbsenceField (Convert-WDate (Get-WPropFirst $Props 'whenchanged' '')));Usn=$usn;LastLogon=$lastLogon
        Name=(Clean-AbsenceField (Get-WPropFirst $Props 'name' ''));Login=(Clean-AbsenceField (Get-WPropFirst $Props 'samaccountname' ''));Upn=$upn
        Display=(Clean-AbsenceField (Get-WPropFirst $Props 'displayname' ''));Description=(Clean-AbsenceField (Get-WPropFirst $Props 'description' ''));Extra=$extra
        State=$(if(($uac -band 2) -ne 0){'Desactive'}else{'Actif'});DN=(Clean-AbsenceField (Get-WPropFirst $Props 'distinguishedname' ''));Guid=$Guid
    }
}
$keys=@($requested.Keys)
$found=@{};$checked=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$domainRead='Read';$domainError=''
$props=@('objectGUID','distinguishedName','objectClass','name','sAMAccountName','userPrincipalName','dNSHostName','displayName','description','department','title','operatingSystem','location','userAccountControl','whenChanged','uSNChanged','lastLogonTimestamp')
for($offset=0;$offset -lt $keys.Count;$offset+=24){
    if($watch.Elapsed.TotalSeconds -ge $budgetSeconds){$domainRead='Unavailable';$domainError='Budget de temps atteint avant la fin des lectures.';break}
    $last=[Math]::Min($keys.Count,$offset+24)-1
    $batch=@($keys[$offset..$last])
    $filter='(|'+(@($batch|ForEach-Object{Get-AbsenceGuidClause $requested[$_]}) -join '')+')'
    $searcher=$null;$searchRoot=$null;$results=$null
    try{
        $searcher=New-WSearcher $Context $baseDn $filter $props 'Subtree' 0
        $searchRoot=$searcher.SearchRoot;$searcher.PageSize=24;$searcher.CacheResults=$false
        $searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(15);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(20)
        $results=$searcher.FindAll()
        foreach($r in $results){
            $p=$r.Properties
            $id=([string](Convert-WGuid (Get-WPropFirst $p 'objectguid' ''))).ToLowerInvariant()
            if((-not $id) -or (-not $requested.Contains($id))){continue}
            $classes=@(Get-WPropAll $p 'objectclass'|ForEach-Object{([string]$_).ToLowerInvariant()})
            $type=''
            if($classes -contains 'computer'){$type='Machine'}elseif(($classes -contains 'user') -and ($classes -contains 'person')){$type='Utilisateur'}
            $record=$null
            if($type){$record=New-AbsenceIndexRecord $p $type $id}
            $found[$id]=[pscustomobject]@{Dn=(Clean-AbsenceField (Get-WPropFirst $p 'distinguishedname' ''));Type=$type;Record=$record}
        }
        foreach($key in $batch){[void]$checked.Add([string]$key)}
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $domainRead=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
        $domainError=[string]$_.Exception.Message;if($domainError.Length -gt 300){$domainError=$domainError.Substring(0,300)}
        break
    }finally{
        if($null -ne $results){$results.Dispose()}
        if($null -ne $searcher){$searcher.Dispose()}
        if($null -ne $searchRoot){$searchRoot.Dispose()}
    }
}
$missing=@($keys|Where-Object{($checked.Contains([string]$_)) -and (-not $found.ContainsKey([string]$_))})
# Deleted-object reads: visibility of the container, then the GUID lookups. Each GUID keeps the state of its own lookup:
# a lookup cut by the budget or an error never turns into "searched and not found".
$deletedProbe='NotRequested';$deletedFailure='';$deletedError='';$deleted=@{}
$deletedChecked=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if(($missing.Count -gt 0) -and ([bool]$Payload.CheckDeleted)){
    # Deleted objects are read from the domain head with the "show deleted" control: binding to CN=Deleted Objects
    # itself would need a fast bind, which the common worker bind does not do. The objectGUID clauses keep each
    # search on the GUID index; isDeleted=TRUE keeps live objects out.
    $searcher=$null;$searchRoot=$null;$results=$null
    try{
        # Visibility probe: the Deleted Objects container (a critical system object directly under the domain head) is
        # returned with its attributes only to an account allowed to read it. Without that right, an empty answer cannot
        # tell "not deleted" from "not visible".
        $searcher=New-WSearcher $Context $baseDn '(&(isDeleted=TRUE)(isCriticalSystemObject=TRUE))' @('name','objectGUID') 'OneLevel' 5
        $searchRoot=$searcher.SearchRoot;$searcher.Tombstone=$true;$searcher.CacheResults=$false
        $searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(10);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(15)
        $results=$searcher.FindAll()
        $deletedProbe='Empty'
        foreach($r in $results){if([string](Get-WPropFirst $r.Properties 'name' '')){$deletedProbe='Read';break}}
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $deletedProbe=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
        $deletedError=[string]$_.Exception.Message;if($deletedError.Length -gt 300){$deletedError=$deletedError.Substring(0,300)}
    }finally{
        if($null -ne $results){$results.Dispose()}
        if($null -ne $searcher){$searcher.Dispose()}
        if($null -ne $searchRoot){$searchRoot.Dispose()}
    }
    # The GUID lookup runs even when the probe saw nothing: one entry found among the deleted objects is a proof by
    # itself, and it also shows that this account sees deleted objects.
    if($deletedProbe -ne 'Unavailable'){
        for($offset=0;$offset -lt $missing.Count;$offset+=24){
            if($watch.Elapsed.TotalSeconds -ge $budgetSeconds){$deletedFailure='Unavailable';$deletedError='Budget de temps atteint avant la fin des lectures.';break}
            $last=[Math]::Min($missing.Count,$offset+24)-1
            $batch=@($missing[$offset..$last])
            $filter='(&(isDeleted=TRUE)(|'+(@($batch|ForEach-Object{Get-AbsenceGuidClause $requested[[string]$_]}) -join '')+'))'
            $searcher=$null;$searchRoot=$null;$results=$null
            try{
                $searcher=New-WSearcher $Context $baseDn $filter @('objectGUID','whenChanged','lastKnownParent','isRecycled') 'Subtree' 0
                $searchRoot=$searcher.SearchRoot;$searcher.Tombstone=$true;$searcher.PageSize=24;$searcher.CacheResults=$false
                $searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(15);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(20)
                $results=$searcher.FindAll()
                foreach($r in $results){
                    $p=$r.Properties
                    $id=([string](Convert-WGuid (Get-WPropFirst $p 'objectguid' ''))).ToLowerInvariant()
                    if((-not $id) -or (-not $requested.Contains($id))){continue}
                    $when='';$changed=Get-WPropFirst $p 'whenchanged' $null
                    if($changed -is [datetime]){
                        # A directory time without kind is UTC (same reading as the index pass).
                        $utc=if($changed.Kind -eq [DateTimeKind]::Local){$changed.ToUniversalTime()}else{[DateTime]::SpecifyKind($changed,[DateTimeKind]::Utc)}
                        $when=$utc.ToString('o')
                    }
                    $parent=Clean-AbsenceField (Get-WPropFirst $p 'lastknownparent' '');if($parent.Length -gt 500){$parent=$parent.Substring(0,500)}
                    $recycled=$false;$flag=Get-WPropFirst $p 'isrecycled' $null
                    if($flag -is [bool]){$recycled=$flag}elseif($null -ne $flag){$recycled=([string]$flag -ieq 'TRUE')}
                    $deleted[$id]=[pscustomobject]@{WhenUtc=$when;LastKnownParent=$parent;Recycled=$recycled}
                }
                foreach($key in $batch){[void]$deletedChecked.Add([string]$key)}
            }catch{
                if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
                $deletedFailure=if([string](Get-DomeniaStructuredError $_).Kind -eq 'AccessDenied'){'Refused'}else{'Unavailable'}
                $deletedError=[string]$_.Exception.Message;if($deletedError.Length -gt 300){$deletedError=$deletedError.Substring(0,300)}
                break
            }finally{
                if($null -ne $results){$results.Dispose()}
                if($null -ne $searcher){$searcher.Dispose()}
                if($null -ne $searchRoot){$searchRoot.Dispose()}
            }
        }
    }
}
# What a lookup that found nothing means: 'Read' when this account sees deleted objects (container readable, or one
# requested GUID found among them), otherwise the probe state (Empty or Refused: no conclusion possible).
$deletedVisibility=$deletedProbe
if(($deletedProbe -eq 'Read') -or ($deleted.Count -gt 0)){$deletedVisibility='Read'}
$deletedRead=$deletedVisibility
if(-not $deletedChecked.Count){if($deletedFailure){$deletedRead=$deletedFailure}}
$answers=[Collections.Generic.List[object]]::new()
foreach($key in $keys){
    $own='NotRequested'
    if($deleted.ContainsKey([string]$key)){$own='Read'}
    elseif($deletedChecked.Contains([string]$key)){$own=$deletedVisibility}
    elseif($deletedFailure){$own=$deletedFailure}
    elseif($deletedProbe -eq 'Unavailable'){$own='Unavailable'}
    $answer=[ordered]@{Guid=[string]$key;DomainRead=$(if($checked.Contains([string]$key)){'Read'}else{$domainRead});FoundDn='';Type='';Record=$null;DeletedRead=$own;Deleted=$false;DeletedWhenUtc='';LastKnownParent='';Recycled=$false}
    if($found.ContainsKey([string]$key)){$hit=$found[[string]$key];$answer.FoundDn=[string]$hit.Dn;$answer.Type=[string]$hit.Type;$answer.Record=$hit.Record}
    elseif($deleted.ContainsKey([string]$key)){$gone=$deleted[[string]$key];$answer.Deleted=$true;$answer.DeletedWhenUtc=[string]$gone.WhenUtc;$answer.LastKnownParent=[string]$gone.LastKnownParent;$answer.Recycled=[bool]$gone.Recycled}
    $answers.Add([pscustomobject]$answer)
}
[pscustomobject]@{Results=$answers.ToArray();DomainRead=$domainRead;DomainError=$domainError;DeletedRead=$deletedRead;DeletedError=$deletedError;Server=[string]$Context.Server;ObservedUtc=[datetime]::UtcNow.ToString('o');DurationMs=[long]$watch.ElapsedMilliseconds}
'@
}
