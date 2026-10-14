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
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{
        $operation=[string]$Context.OperationId;if(-not $operation){$operation='UnknownOperation'}
        if($guard.ContainsKey('AmbiguousOperations') -and $guard.AmbiguousOperations.ContainsKey($operation)){throw '[DOMENIA:CredentialPaused;0;0x00000000] Origine du refus d authentification indeterminee : cette operation est suspendue. Reconnectez-vous pour reprendre.'}
        foreach($key in $keys){
            if($guard.Faults.ContainsKey($key)){
                # Stable marker survives legacy string-only wrappers; no new authentication is attempted.
                throw '[DOMENIA:CredentialPaused;0;0x00000000] Protection du compte : collectes suspendues apres un refus d authentification. Reconnectez-vous pour reprendre. Les donnees locales restent consultables.'
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
    $keys=[string[]]@(Get-WCredentialGuardKeys $Context $Channel);[Array]::Sort($keys,[StringComparer]::Ordinal)
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{
        if(-not $guard.ContainsKey('AttemptLocks')){$guard.AttemptLocks=@{}}
        foreach($key in $keys){
            if(-not $guard.AttemptLocks.ContainsKey($key)){$guard.AttemptLocks[$key]=[object]::new()}
            $objects.Add($guard.AttemptLocks[$key])
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
            if(-not $provenance -and $keys.Count -gt 1){
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
            foreach($key in $keys){
                if(-not $guard.Faults.ContainsKey($key)){
                    # Whitelisted diagnostics only. Never keep the exception, request or credentials.
                    $guard.Faults[$key]=[pscustomobject]@{Kind=[string]$diagnostic.Kind;Code=[string]$diagnostic.Code;AtUtc=[datetime]::UtcNow}
                    $guard.Revision=[long]$guard.Revision+1
                }
            }
        }finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
    }
    return $true
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
