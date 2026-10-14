# Pure, bounded models. No WPF, credentials, remote calls or file writes.
function Get-DomeniaStructuredError {
    param($ErrorValue,[string]$Phase='Unknown',[string]$Provider='Unknown',[string]$Target='')
    # Self-contained on purpose: this definition is copied alone into every worker runspace.
    $ex=$null;$text='';$native=0L;$code=0L;$allText=''
    if($ErrorValue -is [Management.Automation.ErrorRecord]){$ex=$ErrorValue.Exception}
    elseif($ErrorValue -is [Exception]){$ex=$ErrorValue}
    else{$text=[string]$ErrorValue;$allText=$text}
    for($i=0;$null -ne $ex -and $i -lt 8;$i++){
        $code=([long]$ex.HResult -band 0xffffffffL)
        if($ex.PSObject.Properties['NativeErrorCode']){$native=[long]$ex.NativeErrorCode}
        elseif($ex.GetType().FullName -eq 'System.DirectoryServices.Protocols.LdapException'){$native=[long]$ex.ErrorCode}
        $text=[string]$ex.Message
        $allText=$allText+' '+$text
        foreach($property in @('ServerErrorMessage','ExtendedErrorMessage')){
            if($null -ne $ex.PSObject.Properties[$property]){$allText+=' '+[string]$ex.$property}
        }
        if($native -in @(5,49,50,1326,1330,1331,1909) -or $code -in @(2147942405,2147943726,2147950744,2148074252,2148074254)){break}
        $ex=$ex.InnerException
    }
    # The worker marker may be wrapped by EndInvoke ("Exception calling ...") or by an outer exception:
    # it is searched anywhere in the whole exception chain, not only at the start of the last message.
    $tagKind=''
    if($allText -match '\[DOMENIA:([A-Za-z]+);([0-9]+);(0x[0-9A-Fa-f]{8})\]'){$tagKind=$matches[1];$native=[long]$matches[2];$code=[Convert]::ToInt64($matches[3].Substring(2),16)}
    $kind='Unknown';$retry=$false
    $subCode=''
    if($allText -match '(?i)\bdata\s+(525|52e|52f|530|531|532|533|701|773|775)\b'){$subCode=$matches[1].ToLowerInvariant()}
    if($tagKind -eq 'CredentialPaused'){$kind='CredentialPaused'}
    elseif($subCode -eq '775'){$kind='AccountLocked'}
    elseif($subCode -in @('52f','530','531','532','533','701','773')){$kind='AccountUnavailable'}
    elseif($subCode -in @('525','52e')){$kind='LogonFailure'}
    elseif($native -in @(1326,49) -or $code -in @(2147943726,2148074252,2148074254)){$kind='LogonFailure'}
    elseif($native -eq 1909 -or $code -eq 2147944309){$kind='AccountLocked'}
    elseif($native -in @(1327,1328,1329,1330,1331,1793,1907) -or $code -in @(0x8007052FL,0x80070530L,0x80070531L,0x80070532L,0x80070533L,0x80070701L,0x80070773L)){$kind='AccountUnavailable'}
    elseif($native -in @(5,50) -or $code -in @(2147942405,2147950744)){$kind='AccessDenied'}
    elseif($native -in @(53,64,1722,1460) -or $code -in @(2147944122,2147943860)){$kind='Unavailable';$retry=$true}
    # Compatibility fallback for old string-only workers. A timeout never implies wrong credentials.
    elseif($text -match '(?i)ETAT INCONNU|resultat.*non confirme'){$kind='Uncertain'}
    elseif($text -match '(?i)timeout|timed out|delai.*depasse|délai.*dépassé|RPC.*indisponible'){$kind='Unavailable';$retry=$true}
    elseif($text -match '(?i)ModuleMissing|module.*(?:absent|manquant|missing)'){$kind='ModuleUnavailable'}
    elseif($text -match '(?i)access.*denied|unauthorized|d[eé]chiffrement.*refus|droit de d[eé]chiffrement|d[eé]chiffreur.*autoris|acc[eè]s.*refus|insufficient.*access|0x80070005|0x80072098'){$kind='AccessDenied'}
    elseif($text -match '(?i)invalid credentials|logon failure|0x8007052e|identifiants.*rejet|user name or password is incorrect|nom d.utilisateur ou (?:le )?mot de passe (?:est )?incorrect'){$kind='LogonFailure'}
    elseif($allText -match '(?i)0x80070775|account.{0,30}locked|compte.{0,30}verrouill'){$kind='AccountLocked'}
    elseif($allText -match '(?i)0x8007053[23]|password.{0,20}expired|account.{0,20}(expired|disabled)|mot de passe.{0,20}expir|compte.{0,20}(expir|d[eé]sactiv)'){$kind='AccountUnavailable'}
    if($kind -eq 'Unknown' -and $tagKind -in @('AccessDenied','LogonFailure','AccountLocked','AccountUnavailable','ModuleUnavailable','Unavailable','Uncertain')){$kind=$tagKind}
    [pscustomobject]@{Kind=$kind;Code=('0x{0:X8}' -f $code);NativeCode=$native;Phase=$Phase;Provider=$Provider;Target=$Target;Retryable=$retry;CanOfferCredential=($kind -in @('AccessDenied','LogonFailure'));Uncertain=($kind -eq 'Uncertain')}
}
function Get-DomeniaCredentialAccountKey {
    # Match only aliases of the known domain. No password, credential hash or network resolution.
    param([string]$UserName,[string]$Domain,[string]$Netbios,[string]$Target='')
    $user=$UserName.Trim().ToLowerInvariant();$dns=$Domain.Trim().TrimEnd('.').ToLowerInvariant()
    $nb=$Netbios.Trim().ToLowerInvariant()
    if(-not $user){return ''}
    if($user.StartsWith('.\') -and $Target){$user=$Target.Trim().ToLowerInvariant()+'\'+$user.Substring(2)}
    if($user.Contains('\')){
        $parts=$user.Split([char]92,2)
        if($dns -and $parts[0] -in @($dns,$nb)){return ($parts[1]+'@'+$dns)}
        return $user
    }
    if($user.Contains('@')){return $user}
    if($dns){return ($user+'@'+$dns)}
    return $user
}
function Set-WCredentialAttemptIdentity {
    # Remember the account actually selected by this transport, not every optional credential on the job.
    param($Context,$Credential,[ValidateSet('Directory','Remote')][string]$Channel,[string]$UserName='',[string]$Target='')
    if($null -eq $Context){return}
    if(-not $UserName -and $null -ne $Credential){$UserName=[string]$Credential.UserName}
    if(-not $UserName){$UserName=[string]$Context.ProcessIdentity}
    $key=''
    if($UserName){
        if($UserName.StartsWith('.\') -and $Target){$UserName=$Target.Trim().ToLowerInvariant()+'\'+$UserName.Substring(2)}
        $key=Get-DomeniaCredentialAccountKey $UserName ([string]$Context.Domain) ([string]$Context.Netbios)
    }else{
        $existing=@(Get-WCredentialGuardKeys $Context $Channel)
        if($existing.Count -eq 1){$key=[string]$existing[0]}
    }
    if(-not $key){return}
    $name=if($Channel -eq 'Directory'){'DirectoryAuthKey'}else{'ActiveRemoteAuthKey'}
    if($Context -is [Collections.IDictionary]){$Context[$name]=$key;$Context['LastAuthChannel']=$Channel}
    else{$Context|Add-Member -NotePropertyName $name -NotePropertyValue $key -Force;$Context|Add-Member -NotePropertyName LastAuthChannel -NotePropertyValue $Channel -Force}
}
function Get-WCredentialGuardKeys {
    # This and the two following functions are injected into workers, sharing the same synchronized map.
    param($Context,[ValidateSet('All','Directory','Remote')][string]$Channel='All')
    if($null -eq $Context){return}
    $active=if($Context -is [Collections.IDictionary]){[string]$Context['ActiveRemoteAuthKey']}elseif($null -ne $Context.PSObject.Properties['ActiveRemoteAuthKey']){[string]$Context.ActiveRemoteAuthKey}else{''}
    $remoteNames=if($active){@('ActiveRemoteAuthKey')}else{@('RemoteAuthKey','RemoteAdminAuthKey')}
    $names=if($Channel -eq 'Directory'){@('DirectoryAuthKey')}elseif($Channel -eq 'Remote'){$remoteNames}else{@('DirectoryAuthKey')+$remoteNames}
    $seen=@{}
    foreach($name in $names){
        $value=''
        if($Context -is [Collections.IDictionary]){$value=[string]$Context[$name]}
        elseif($null -ne $Context.PSObject.Properties[$name]){$value=[string]$Context.$name}
        if($value -and -not $seen.ContainsKey($value)){$seen[$value]=$true;$value}
    }
}
function Assert-WCredentialAllowed {
    param($Context,[ValidateSet('All','Directory','Remote')][string]$Channel='All')
    $guard=$null
    if($Context -is [Collections.IDictionary]){$guard=$Context['CredentialGuard']}
    elseif($null -ne $Context -and $null -ne $Context.PSObject.Properties['CredentialGuard']){$guard=$Context.CredentialGuard}
    if($null -eq $guard){return}
    $keys=@(Get-WCredentialGuardKeys $Context $Channel)
    $generation=0L
    if($Context -is [Collections.IDictionary]){[void][long]::TryParse([string]$Context['CredentialGeneration'],[ref]$generation)}
    elseif($null -ne $Context.PSObject.Properties['CredentialGeneration']){[void][long]::TryParse([string]$Context.CredentialGeneration,[ref]$generation)}
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{
        $operation=[string]$Context.OperationId;if(-not $operation){$operation='UnknownOperation'}
        if($guard.ContainsKey('AmbiguousOperations') -and $guard.AmbiguousOperations.ContainsKey($operation)){throw '[DOMENIA:CredentialPaused;0;0x00000000] Origine du refus d authentification indeterminee : cette operation est suspendue. Reconnectez-vous pour reprendre.'}
        # Point 45: names of one account confirmed by a validated identity (same SID) share one pause.
        $checked=[Collections.Generic.List[string]]::new()
        foreach($key in $keys){
            $checked.Add([string]$key)
            if(($guard.ContainsKey('Aliases')) -and ($guard.Aliases.ContainsKey($key))){foreach($alias in @($guard.Groups[[string]$guard.Aliases[$key]])){$checked.Add([string]$alias)}}
        }
        foreach($key in $checked){
            if($guard.Faults.ContainsKey($key)){
                # Stable marker survives legacy string-only wrappers; no new authentication is attempted.
                throw '[DOMENIA:CredentialPaused;0;0x00000000] Protection du compte : collectes suspendues apres un refus d authentification. Corrigez ce compte dans Comptes ou reconnectez-vous pour reprendre. Les donnees locales restent consultables.'
            }
            # Point 44: a job that left before the operator corrected this account still holds the previous password.
            if(($guard.ContainsKey('Released')) -and ($guard.Released.ContainsKey($key)) -and ([long]$guard.Released[$key] -gt $generation)){
                throw '[DOMENIA:CredentialPaused;0;0x00000000] Compte corrige apres le depart de cette operation : aucun nouvel essai avec l ancien mot de passe. Relancez-la pour utiliser le compte valide.'
            }
        }
    }finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
}
function Enter-WCredentialAttempt {
    # Serialize authentication, not the subsequent inventory queries. Never wait on the GUI thread.
    # Point 41 rule: every worker call that sends an explicit account (LDAP bind, CIM session and its first query,
    # WinRM, remote event log, Task Scheduler logon, SMB share, LDAP write bind) holds this lease until the first
    # authenticated answer, and records a refusal with Register-WCredentialFailure. Queries reusing an authenticated
    # connection do not take it again: the index pass, the park sweep and the query schema reads get it through
    # New-WEntry, New-WRootDse and New-WDomeniaCimSession. Test-DomeniaCredentialGuard audits every such call.
    param($Context,[ValidateSet('All','Directory','Remote')][string]$Channel='All',[int]$WaitSeconds=120)
    $guard=$null
    if($Context -is [Collections.IDictionary]){$guard=$Context['CredentialGuard']}
    elseif($null -ne $Context -and $null -ne $Context.PSObject.Properties['CredentialGuard']){$guard=$Context.CredentialGuard}
    $held=[Collections.Generic.List[object]]::new();$objects=[Collections.Generic.List[object]]::new()
    if($null -eq $guard){return [pscustomobject]@{Locks=@()}}
    $keys=[string[]]@(Get-WCredentialGuardKeys $Context $Channel)
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{
        if(-not $guard.ContainsKey('AttemptLocks')){$guard.AttemptLocks=@{}}
        # Point 45: confirmed aliases of one account share one lock, taken in ordinal order to avoid any deadlock.
        $names=[Collections.Generic.List[string]]::new()
        foreach($key in $keys){
            $name=[string]$key
            if(($guard.ContainsKey('Aliases')) -and ($guard.Aliases.ContainsKey($key))){$name=[string]$guard.Aliases[$key]}
            if(-not $names.Contains($name)){$names.Add($name)}
        }
        $ordered=$names.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
        foreach($name in $ordered){
            if(-not $guard.AttemptLocks.ContainsKey($name)){$guard.AttemptLocks[$name]=[object]::new()}
            $objects.Add($guard.AttemptLocks[$name])
        }
    }finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
    $watch=[Diagnostics.Stopwatch]::StartNew();$acquired=$false
    try{
        foreach($lock in $objects){
            while(-not [Threading.Monitor]::TryEnter($lock,100)){
                Assert-WCredentialAllowed $Context $Channel
                if($watch.Elapsed.TotalSeconds -ge [Math]::Max(1,$WaitSeconds)){throw [TimeoutException]::new('Attente locale du canal d authentification depassee. Aucun identifiant envoye par cette tentative.')}
            }
            $held.Add($lock)
            Assert-WCredentialAllowed $Context $Channel
        }
        $acquired=$true
        return [pscustomobject]@{Locks=$held.ToArray();WaitedMs=$watch.ElapsedMilliseconds}
    }finally{
        if(-not $acquired){for($i=$held.Count-1;$i -ge 0;$i--){[Threading.Monitor]::Exit($held[$i])}}
    }
}
function Exit-WCredentialAttempt {
    param($Lease)
    if($null -eq $Lease){return}
    for($i=@($Lease.Locks).Count-1;$i -ge 0;$i--){[Threading.Monitor]::Exit($Lease.Locks[$i])}
}
function Register-WCredentialFailure {
    param($Context,$ErrorValue,[ValidateSet('All','Directory','Remote')][string]$Channel='All')
    $diagnostic=Get-DomeniaStructuredError $ErrorValue
    if([string]$diagnostic.Kind -notin @('LogonFailure','AccountLocked','AccountUnavailable','CredentialPaused')){return $false}
    if([string]$diagnostic.Kind -eq 'CredentialPaused'){return $true}
    $guard=$null
    if($Context -is [Collections.IDictionary]){$guard=$Context['CredentialGuard']}
    elseif($null -ne $Context -and $null -ne $Context.PSObject.Properties['CredentialGuard']){$guard=$Context.CredentialGuard}
    if($null -ne $guard){
        $exception=if($ErrorValue -is [Management.Automation.ErrorRecord]){$ErrorValue.Exception}elseif($ErrorValue -is [Exception]){$ErrorValue}else{$null}
        $keys=@();$provenance=$false
        for($inner=$exception;$null -ne $inner;$inner=$inner.InnerException){
            if($inner.Data.Contains('Domenia.CredentialKeys')){$keys=@($inner.Data['Domenia.CredentialKeys']);$provenance=$true;break}
        }
        if(-not $provenance){
            if($Channel -eq 'All' -and [string]$Context.LastAuthChannel -in @('Directory','Remote')){$Channel=[string]$Context.LastAuthChannel}
            $keys=@(Get-WCredentialGuardKeys $Context $Channel)
        }
        [Threading.Monitor]::Enter($guard.SyncRoot)
        try{
            # Point 45: confirmed aliases of one account (same SID) are one owner, so their refusal is located.
            $owners=[Collections.Generic.List[string]]::new()
            foreach($key in $keys){
                $owner=[string]$key
                if(($guard.ContainsKey('Aliases')) -and ($guard.Aliases.ContainsKey($key))){$owner=[string]$guard.Aliases[$key]}
                if(-not $owners.Contains($owner)){$owners.Add($owner)}
            }
            if(-not $provenance -and $owners.Count -gt 1){
                # Missing transport provenance is not proof that every optional account is wrong.
                if(-not $guard.ContainsKey('AmbiguousOperations')){$guard.AmbiguousOperations=@{}}
                $operation=[string]$Context.OperationId;if(-not $operation){$operation='UnknownOperation'}
                if(-not $guard.AmbiguousOperations.ContainsKey($operation)){
                    $guard.AmbiguousOperations[$operation]=[pscustomobject]@{Kind=[string]$diagnostic.Kind;Code=[string]$diagnostic.Code;AtUtc=[datetime]::UtcNow}
                    $guard.Revision=[long]$guard.Revision+1
                }
                return $true
            }
            if($null -ne $exception -and $keys.Count){$exception.Data['Domenia.CredentialKeys']=[string[]]$keys}
            $generation=0L
            if($Context -is [Collections.IDictionary]){[void][long]::TryParse([string]$Context['CredentialGeneration'],[ref]$generation)}
            elseif($null -ne $Context.PSObject.Properties['CredentialGeneration']){[void][long]::TryParse([string]$Context.CredentialGeneration,[ref]$generation)}
            foreach($key in $keys){
                # Point 44: the refusal of a password the operator has since corrected pauses nothing.
                if(($guard.ContainsKey('Released')) -and ($guard.Released.ContainsKey($key)) -and ([long]$guard.Released[$key] -gt $generation)){continue}
                # Point 45: the pause covers every confirmed alias of the refused account.
                $covered=@([string]$key)
                if(($guard.ContainsKey('Aliases')) -and ($guard.Aliases.ContainsKey($key))){$covered=@($guard.Groups[[string]$guard.Aliases[$key]])}
                foreach($name in $covered){
                    if(-not $guard.Faults.ContainsKey($name)){
                        # Whitelisted diagnostics only. Never keep the exception, request or credentials.
                        $guard.Faults[$name]=[pscustomobject]@{Kind=[string]$diagnostic.Kind;Code=[string]$diagnostic.Code;AtUtc=[datetime]::UtcNow}
                        $guard.Revision=[long]$guard.Revision+1
                    }
                }
            }
        }finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
    }
    return $true
}
function Clear-DomeniaCredentialGuardFault {
    # Point 44: releases ONE account the operator has just corrected and validated (one explicit attempt), with its
    # confirmed aliases. Jobs that left before generation $Generation keep the previous password: the worker helpers
    # refuse their next attempt and ignore their refusal. Pauses of operations without a located account stay.
    # Returns the faults removed (key, kind, time) so that the lockout diagnosis keeps them.
    param($Guard,[string[]]$Keys=@(),[long]$Generation=0)
    $removed=[Collections.Generic.List[object]]::new()
    if($null -eq $Guard){return ,$removed.ToArray()}
    [Threading.Monitor]::Enter($Guard.SyncRoot)
    try{
        if(-not $Guard.ContainsKey('Released')){$Guard.Released=@{}}
        $names=[Collections.Generic.List[string]]::new()
        foreach($key in @($Keys|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})){
            $key=([string]$key).Trim().ToLowerInvariant()
            if(-not $names.Contains($key)){$names.Add($key)}
            if(($Guard.ContainsKey('Aliases')) -and ($Guard.Aliases.ContainsKey($key))){foreach($alias in @($Guard.Groups[[string]$Guard.Aliases[$key]])){if(-not $names.Contains([string]$alias)){$names.Add([string]$alias)}}}
        }
        foreach($name in $names){
            if($Guard.Faults.ContainsKey($name)){
                $fault=$Guard.Faults[$name]
                $removed.Add([pscustomobject]@{Key=$name;Kind=[string]$fault.Kind;AtUtc=$fault.AtUtc})
                [void]$Guard.Faults.Remove($name)
            }
            $previous=0L;if($Guard.Released.ContainsKey($name)){$previous=[long]$Guard.Released[$name]}
            $Guard.Released[$name]=[Math]::Max($previous,$Generation)
        }
    }finally{[Threading.Monitor]::Exit($Guard.SyncRoot)}
    return ,$removed.ToArray()
}
function Get-DomeniaCredentialGroupKeys {
    # Point 45: one guard key and the names confirmed for the same account (same SID), read under the guard lock.
    param($Guard,[AllowEmptyString()][string]$Key)
    $keys=[Collections.Generic.List[string]]::new()
    $Key=([string]$Key).Trim().ToLowerInvariant()
    if(-not $Key){return ,$keys.ToArray()}
    $keys.Add($Key)
    if($null -eq $Guard){return ,$keys.ToArray()}
    [Threading.Monitor]::Enter($Guard.SyncRoot)
    try{
        if(($Guard.ContainsKey('Aliases')) -and ($Guard.Aliases.ContainsKey($Key))){foreach($alias in @($Guard.Groups[[string]$Guard.Aliases[$Key]])){if(-not $keys.Contains([string]$alias)){$keys.Add([string]$alias)}}}
    }finally{[Threading.Monitor]::Exit($Guard.SyncRoot)}
    return ,$keys.ToArray()
}
function ConvertTo-DomeniaAccountLookup {
    # Point 45: how a validated account name is looked up in the connected domain to read its SID and its other
    # names. Pure. A local account (.\x or POSTE\x) or an account of another NetBIOS domain is not looked up.
    param([AllowEmptyString()][string]$UserName,[AllowEmptyString()][string]$Domain='',[AllowEmptyString()][string]$Netbios='')
    $name=([string]$UserName).Trim();$dns=([string]$Domain).Trim().TrimEnd('.').ToLowerInvariant();$nb=([string]$Netbios).Trim().ToLowerInvariant()
    if((-not $name) -or ($name.Length -gt 256) -or ($name -match '[\x00-\x1f*()]')){return [pscustomobject]@{Valid=$false;Sam='';Upn='';Reason='Nom de compte vide ou invalide.'}}
    if($name.Contains('\')){
        $parts=$name.Split([char]92,2);$authority=$parts[0].ToLowerInvariant()
        $known=(($authority -eq $nb) -or ($dns -and (($authority -eq $dns) -or ($authority -eq $dns.Split('.')[0]))))
        if((-not $known) -or (-not $parts[1]) -or ($parts[1].Contains('\')) -or ($parts[1].Contains('@'))){return [pscustomobject]@{Valid=$false;Sam='';Upn='';Reason='Compte local ou dʼun autre domaine : aucun alias recherché.'}}
        return [pscustomobject]@{Valid=$true;Sam=$parts[1];Upn='';Reason=''}
    }
    if($name.Contains('@')){
        $at=$name.LastIndexOf('@');$prefix=$name.Substring(0,$at);$suffix=$name.Substring($at+1).ToLowerInvariant()
        if((-not $prefix) -or (-not $suffix) -or ($prefix.Contains('@'))){return [pscustomobject]@{Valid=$false;Sam='';Upn='';Reason='Nom de compte vide ou invalide.'}}
        # An UPN with the DNS suffix of the domain is also the sAMAccountName form of the guard keys.
        $sam='';if($dns -and ($suffix -eq $dns)){$sam=$prefix}
        return [pscustomobject]@{Valid=$true;Sam=$sam;Upn=$name;Reason=''}
    }
    return [pscustomobject]@{Valid=$true;Sam=$name;Upn='';Reason=''}
}
function Get-DomeniaCredentialAliasKeys {
    # Point 45: the guard keys of one account read in the directory: NETBIOS\sam (the same key as sam@dns) and the UPN.
    param([AllowEmptyString()][string]$Sam='',[AllowEmptyString()][string]$Upn='',[AllowEmptyString()][string]$Domain='',[AllowEmptyString()][string]$Netbios='',[string[]]$Also=@())
    $keys=[Collections.Generic.List[string]]::new()
    $names=@()
    if(([string]$Sam).Trim()){if(([string]$Netbios).Trim()){$names+=([string]$Netbios).Trim()+'\'+([string]$Sam).Trim()}else{$names+=([string]$Sam).Trim()}}
    if(([string]$Upn).Trim()){$names+=([string]$Upn).Trim()}
    $names+=@($Also)
    foreach($name in $names){
        if([string]::IsNullOrWhiteSpace([string]$name)){continue}
        $key=Get-DomeniaCredentialAccountKey ([string]$name) ([string]$Domain) ([string]$Netbios)
        if($key -and (-not $keys.Contains($key))){$keys.Add($key)}
    }
    return ,$keys.ToArray()
}
function Register-DomeniaCredentialAliases {
    # Point 45: names of ONE account confirmed by the directory for a validated identity (same SID). From now on a
    # pause recorded under any of them covers all of them, and their authentications share one lock. Nothing is
    # released and no authentication is attempted. A name already bound to another SID is never moved silently.
    param($Guard,[AllowEmptyString()][string]$Sid,[string[]]$Keys=@(),[ValidateRange(1,256)][int]$MaxGroups=64)
    $answer=[pscustomobject]@{Registered=$false;Group='';Keys=@();Conflicts=@();Propagated=0;Reason=''}
    if($null -eq $Guard){$answer.Reason='Protection des comptes non initialisée.';return $answer}
    if([string]$Sid -notmatch '^S-1-5-21(-\d{1,10}){4}$'){$answer.Reason='SID de domaine attendu.';return $answer}
    $clean=@($Keys|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Select-Object -Unique)
    if($clean.Count -lt 1){$answer.Reason='Aucun nom de compte.';return $answer}
    if($clean.Count -gt 16){$answer.Reason='Trop de noms pour un seul compte.';return $answer}
    $group='sid:'+([string]$Sid).ToUpperInvariant()
    [Threading.Monitor]::Enter($Guard.SyncRoot)
    try{
        if(-not $Guard.ContainsKey('Aliases')){$Guard.Aliases=@{}}
        if(-not $Guard.ContainsKey('Groups')){$Guard.Groups=@{}}
        if((-not $Guard.Groups.ContainsKey($group)) -and ($Guard.Groups.Count -ge $MaxGroups)){$answer.Reason='Limite de comptes rapprochés atteinte pour cette session.';return $answer}
        $members=[Collections.Generic.List[string]]::new()
        if($Guard.Groups.ContainsKey($group)){foreach($k in @($Guard.Groups[$group])){$members.Add([string]$k)}}
        $conflicts=[Collections.Generic.List[string]]::new()
        foreach($key in $clean){
            if(($Guard.Aliases.ContainsKey($key)) -and ([string]$Guard.Aliases[$key] -cne $group)){$conflicts.Add($key);continue}
            if(-not $members.Contains($key)){$members.Add($key)}
        }
        if($members.Count -gt 16){$answer.Reason='Trop de noms pour un seul compte.';return $answer}
        $Guard.Groups[$group]=$members.ToArray()
        foreach($key in $members){$Guard.Aliases[$key]=$group}
        # A pause already recorded under one name now covers the others: a queued read of an alias is withdrawn.
        $fault=$null
        foreach($key in $members){if($Guard.Faults.ContainsKey($key)){$fault=$Guard.Faults[$key];break}}
        $propagated=0
        if($null -ne $fault){
            foreach($key in $members){
                if(-not $Guard.Faults.ContainsKey($key)){$Guard.Faults[$key]=[pscustomobject]@{Kind=[string]$fault.Kind;Code=[string]$fault.Code;AtUtc=$fault.AtUtc};$propagated++}
            }
            if($propagated -gt 0){$Guard.Revision=[long]$Guard.Revision+1}
        }
        $answer.Registered=$true;$answer.Group=$group;$answer.Keys=$members.ToArray();$answer.Conflicts=$conflicts.ToArray();$answer.Propagated=$propagated
    }finally{[Threading.Monitor]::Exit($Guard.SyncRoot)}
    return $answer
}
function Get-DomeniaLinkFingerprint {
    param($Link)
    if($null -eq $Link){return ''}
    $v=[ordered]@{}
    foreach($n in @('UserLogin','Computer','Source','Confidence','VerifiedInAD','When','Details','UserGuid','ComputerGuid','UserDn','ComputerDn')){$v[$n]=[string]$Link.$n}
    return Get-DomeniaLiveHash ($v|ConvertTo-Json -Compress)
}
function ConvertTo-DomeniaLinkRecord {
    param($Link)
    $v=[ordered]@{}
    foreach($n in @('UserLogin','Computer','Source','Confidence','VerifiedInAD','When','Details','UserGuid','ComputerGuid','UserDn','ComputerDn')){$v[$n]=[string]$Link.$n}
    return [pscustomobject]$v
}
function Get-DomeniaDraftFieldMap {
    return [ordered]@{
        TxtUserGivenName='givenName';TxtUserSurname='sn';TxtUserDisplayName='displayName';TxtUserMail='mail';TxtUserPhone='telephoneNumber'
        TxtUserDescription='description';TxtUserDepartment='department';TxtUserTitle='title';TxtUserOffice='physicalDeliveryOfficeName'
        TxtUserCompany='company';TxtUserStreet='streetAddress';TxtUserCity='l';TxtUserState2='st';TxtUserPostalCode='postalCode';TxtUserCountry='co';TxtUserHomePhone='homePhone';TxtUserMobile='mobile';TxtUserFax='facsimileTelephoneNumber';TxtUserIPPhone='ipPhone';TxtUserWebPage='wWWHomePage';TxtUserEmployeeId='employeeID';TxtUserProfilePath='profilePath';TxtUserScriptPath='scriptPath';TxtUserHomeDirectory='homeDirectory';TxtUserHomeDrive='homeDrive';TxtUserWorkstations='userWorkstations';TxtGroupDescription='description';TxtCompDescription='description';TxtCompLocation='location'
    }
}
function ConvertTo-DomeniaSavedSearch {
    param($Value,[string]$BaseDn)
    if($null -eq $Value -or -not $BaseDn){return $null}
    $dn=[string]$Value.DN;$query=[string]$Value.Query;$name=[string]$Value.Name
    if($name.Length -lt 1 -or $name.Length -gt 80 -or $query.Length -gt 256 -or $dn.Length -gt 4096){return $null}
    if($dn -ine $BaseDn -and -not $dn.EndsWith(','+$BaseDn,[StringComparison]::OrdinalIgnoreCase)){return $null}
    if([string]$Value.Type -notin @('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')){return $null}
    $limit=100;[void][int]::TryParse([string]$Value.Limit,[ref]$limit);$limit=[Math]::Max(1,[Math]::Min(20000,$limit))
    $mode=if([string]$Value.SearchMode -eq 'Global'){'Global'}else{'OU'}
    return [pscustomobject]@{SearchMode=$mode;Name=$name;DN=$dn;Query=$query;Type=[string]$Value.Type;Limit=$limit;Subtree=(ConvertTo-SuiteFlag $Value.Subtree -Default $true)}
}
function Get-DomeniaPercentile {
    param([double[]]$Samples,[double]$Percent=95)
    if(-not $Samples.Count){return 0.0}
    $s=@($Samples|Sort-Object);$index=[Math]::Min($s.Count-1,[Math]::Max(0,[Math]::Ceiling($Percent/100*$s.Count)-1))
    return [Math]::Round($s[$index],2)
}
