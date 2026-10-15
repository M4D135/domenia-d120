function Get-DomeniaGroupPathWorkerCode {
return @'
# UI-06 / D064: « Pourquoi membre ? » and « Afficher les groupes imbriqués », on an explicit gesture only. Breadth-first
# walk of the memberOf of the groups of ONE object, one Base read per group, bounded (groups, depth, time); never a
# search of the domain. For a chosen target group, the controller is also asked for the transitive answer (in-chain rule).
$objectDn=([string]$Payload.ObjectDn).Trim()
if((-not $objectDn) -or ($objectDn.Length -gt 4096)){throw 'DN de lʼobjet invalide : aucune lecture.'}
$targetDn=([string]$Payload.TargetDn).Trim()
if($targetDn.Length -gt 4096){throw 'DN du groupe invalide : aucune lecture.'}
$maxNodes=[int]$Payload.MaxNodes;if(($maxNodes -lt 1) -or ($maxNodes -gt 2000)){$maxNodes=2000}
$maxDepth=[int]$Payload.MaxDepth;if(($maxDepth -lt 1) -or ($maxDepth -gt 16)){$maxDepth=16}
$budgetMs=[int]$Payload.BudgetSeconds*1000;if(($budgetMs -lt 1000) -or ($budgetMs -gt 60000)){$budgetMs=10000}
$baseDn=([string]$Context.BaseDn).Trim()
$watch=[Diagnostics.Stopwatch]::StartNew()
$edges=@{}
$depthOf=@{}
$unread=[Collections.Generic.List[object]]::new()
$queue=[Collections.Generic.Queue[string]]::new()
$start=[Collections.Generic.List[string]]::new()
foreach($item in @($Payload.StartGroups)){
    $dn=([string]$item).Trim()
    if((-not $dn) -or ($dn.Length -gt 4096) -or $depthOf.ContainsKey($dn)){continue}
    if($start.Count -ge 2000){break}
    $start.Add($dn);$depthOf[$dn]=1;$queue.Enqueue($dn)
}
$edges[$objectDn]=$start.ToArray()
$truncated=$false
$serverAnswer=$null
$lease=$null
try{
    # One authentication attempt at a time (credential guard); released after the first answer of the controller.
    $lease=Enter-WCredentialAttempt -Context $Context -Channel Directory
    while($queue.Count -gt 0){
        if($watch.ElapsedMilliseconds -ge $budgetMs){$truncated=$true;break}
        $group=$queue.Dequeue();$depth=[int]$depthOf[$group]
        if($depth -ge $maxDepth){$truncated=$true;continue}
        if(($baseDn) -and (-not $group.EndsWith(','+$baseDn,[StringComparison]::OrdinalIgnoreCase))){$unread.Add([pscustomobject]@{Dn=$group;Reason='Autre domaine'});continue}
        $searcher=$null;$root=$null;$found=$null;$parents=@()
        try{
            $searcher=New-WSearcher $Context $group '(objectClass=group)' @('memberOf','distinguishedName') 'Base' 1
            $root=$searcher.SearchRoot
            $found=$searcher.FindOne()
            if($null -eq $found){$unread.Add([pscustomobject]@{Dn=$group;Reason='Introuvable'});continue}
            $parents=@(Get-WPropAll $found.Properties 'memberof' | ForEach-Object {[string]$_} | Where-Object {$_})
        }catch{
            if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
            $kind=[string](Get-DomeniaStructuredError $_ -Phase 'GroupPathRead' -Provider 'LDAP').Kind
            $reason=if($kind -eq 'AccessDenied'){'Refusé'}else{'Non lu'}
            $detail=[string]$_.Exception.Message;if($detail.Length -gt 200){$detail=$detail.Substring(0,200)}
            $unread.Add([pscustomobject]@{Dn=$group;Reason=$reason;Detail=$detail})
            continue
        }finally{
            if($null -ne $searcher){try{$searcher.Dispose()}catch{}}
            if($null -ne $root){try{$root.Dispose()}catch{}}
            if($null -ne $lease){Exit-WCredentialAttempt $lease;$lease=$null}
        }
        $edges[$group]=$parents
        foreach($parent in $parents){
            if($depthOf.ContainsKey($parent)){continue}
            if($depthOf.Count -ge $maxNodes){$truncated=$true;break}
            $depthOf[$parent]=$depth+1;$queue.Enqueue($parent)
        }
    }
    if($queue.Count -gt 0){$truncated=$true}
    if($targetDn){
        $searcher=$null;$root=$null
        try{
            # LDAP_MATCHING_RULE_IN_CHAIN on the target only (Base): the controller follows the nesting itself.
            $searcher=New-WSearcher $Context $targetDn ('(member:1.2.840.113556.1.4.1941:='+(Escape-WLdap $objectDn)+')') @('distinguishedName') 'Base' 1
            $root=$searcher.SearchRoot
            $serverAnswer=($null -ne $searcher.FindOne())
        }catch{
            if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
            $serverAnswer=$null
        }finally{
            if($null -ne $searcher){try{$searcher.Dispose()}catch{}}
            if($null -ne $root){try{$root.Dispose()}catch{}}
        }
    }
}finally{if($null -ne $lease){Exit-WCredentialAttempt $lease}}
[pscustomobject]@{ObjectDn=$objectDn;TargetDn=$targetDn;Edges=$edges;Unread=$unread.ToArray();Truncated=[bool]$truncated;Visited=$depthOf.Count;ServerAnswer=$serverAnswer;DurationMs=[long]$watch.ElapsedMilliseconds;ObservedUtc=[datetime]::UtcNow.ToString('o')}
'@
}
