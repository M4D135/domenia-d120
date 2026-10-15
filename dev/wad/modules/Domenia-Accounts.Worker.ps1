function Get-DomeniaAccountAliasWorkerCode {
return @'
# Point 45: reads the SID and the other names of ONE validated account, with the directory account of the session.
# One object is looked up by its exact sAMAccountName or userPrincipalName: no scan, no wildcard, and nothing is
# authenticated with the looked-up account itself.
$sam=([string]$Payload.Sam).Trim();$upn=([string]$Payload.Upn).Trim()
if((-not $sam) -and (-not $upn)){throw 'Aucun nom de compte a rechercher.'}
if(($sam.Length -gt 256) -or ($upn.Length -gt 256)){throw 'Nom de compte trop long.'}
$clauses=''
if($sam){$clauses+='(sAMAccountName='+(Escape-WLdap $sam)+')'}
if($upn){$clauses+='(userPrincipalName='+(Escape-WLdap $upn)+')'}
$filter='(&(objectCategory=person)(objectClass=user)(|'+$clauses+'))'
$searcher=New-WSearcher $Context ([string]$Context.BaseDn) $filter @('objectSid','sAMAccountName','userPrincipalName','distinguishedName') 'Subtree' 3
$owned=$searcher.SearchRoot;$found=$null;$rows=[Collections.Generic.List[object]]::new()
try{
    $found=$searcher.FindAll()
    foreach($r in $found){
        $rows.Add([pscustomobject]@{Sid=[string](Convert-WSid (Get-WPropFirst $r.Properties 'objectsid' $null));Sam=[string](Get-WPropFirst $r.Properties 'samaccountname' '');Upn=[string](Get-WPropFirst $r.Properties 'userprincipalname' '');Dn=[string](Get-WPropFirst $r.Properties 'distinguishedname' '')})
        if($rows.Count -ge 3){break}
    }
}finally{if($found -is [IDisposable]){$found.Dispose()};if($searcher -is [IDisposable]){$searcher.Dispose()};if($owned -is [IDisposable]){$owned.Dispose()}}
$state='NotFound';if($rows.Count -eq 1){$state='Resolved'}elseif($rows.Count -gt 1){$state='Ambiguous'}
$one=$null;if($rows.Count -eq 1){$one=$rows[0]}
$answer=[pscustomobject]@{State=$state;Count=$rows.Count;Sid='';Sam='';Upn='';Dn='';RequestSam=$sam;RequestUpn=$upn;ObservedUtc=[datetime]::UtcNow.ToString('o')}
if($null -ne $one){$answer.Sid=[string]$one.Sid;$answer.Sam=[string]$one.Sam;$answer.Upn=[string]$one.Upn;$answer.Dn=[string]$one.Dn}
$answer
'@
}
