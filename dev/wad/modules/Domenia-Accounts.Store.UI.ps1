# Optional account names only. Passwords and credentials never enter this queue or SQLite.
function Initialize-DomeniaAccountPreferences {
    if($null -eq $script:AccountPreferences){
        $script:AccountPreferences=[pscustomobject]@{Identity='';Rows=@{};Revision=-1L;ReadId='';ReadAfter=[datetime]::MinValue;Pending=[ordered]@{};FieldSeeds=@{}}
    }
}
function Get-DomeniaAccountPreferenceScope {
    param([string]$Scope,[string]$Target='',[string]$UserName='')
    switch($Scope){
        'ReadLaps' {return 'Laps'}
        'ReadBitLocker' {return 'BitLocker'}
        'Remote' {
            if($Target -and $UserName -and (Test-DomeniaLocalAccountName -UserName $UserName -Target $Target)){
                $machine=(ConvertTo-DomeniaMachineKey $Target).ToLowerInvariant()
                if($machine -notmatch '^[a-z0-9][a-z0-9._-]{0,252}$'){throw 'Nom du poste invalide pour memoriser ce compte.'}
                return 'RemoteLocal:'+$machine
            }
        }
    }
    if($Scope -in @('Directory','Remote','Laps','BitLocker') -or $Scope -match '^AD:[A-Za-z][A-Za-z0-9_.-]{0,63}$' -or $Scope -cmatch '^RemoteLocal:[a-z0-9][a-z0-9._-]{0,252}$'){return $Scope}
    throw 'Usage du compte inconnu.'
}
function Test-DomeniaAccountPreferenceContext {
    param($Context)
    return ($null -ne $Context -and [long]$Context.SessionEpoch -eq [long]$script:SessionEpoch -and [string]$Context.Path -ceq [string]$script:DatabaseScopedPath -and [string]$Context.DomainDn -ieq ([string]$script:Conn.BaseDn).Trim())
}
function Get-DomeniaAccountPreferenceIdentity {
    return ([string]$script:SessionEpoch+'|'+[string]$script:DatabaseScopedPath+'|'+([string]$script:Conn.BaseDn).Trim().ToLowerInvariant())
}
function Get-DomeniaRememberedAccount {
    param([string]$Scope,[string]$Target='')
    Initialize-DomeniaAccountPreferences
    if($script:AccountPreferences.Identity -cne (Get-DomeniaAccountPreferenceIdentity)){return ''}
    if($Scope -eq 'Remote' -and $Target){
        $key='RemoteLocal:'+(ConvertTo-DomeniaMachineKey $Target).ToLowerInvariant()
        if($script:AccountPreferences.Rows.ContainsKey($key) -and [string]$script:AccountPreferences.Rows[$key]){return [string]$script:AccountPreferences.Rows[$key]}
    }
    $key=Get-DomeniaAccountPreferenceScope -Scope $Scope
    return [string]$script:AccountPreferences.Rows[$key]
}
function Update-DomeniaRememberedAccountFields {
    # An asynchronous read must never overwrite text typed while it was running.
    Initialize-DomeniaAccountPreferences
    $values=@{TxtAccountRemoteUser=(Get-DomeniaRememberedAccount -Scope Remote);TxtAccountSecretsUser=(Get-DomeniaRememberedAccount -Scope Laps)}
    foreach($name in $values.Keys){
        $field=Get-DomeniaControl $name;if($null -eq $field){continue}
        $seed=[string]$script:AccountPreferences.FieldSeeds[$name]
        if(-not [bool]$field.IsKeyboardFocusWithin -and [string]$field.Text -ceq $seed){
            $field.Text=[string]$values[$name];$script:AccountPreferences.FieldSeeds[$name]=[string]$values[$name]
        }
    }
}
function Set-DomeniaCommittedAccountPreferences {
    param($Result,$Context)
    if(-not (Test-DomeniaAccountPreferenceContext $Context)){return $false}
    if([string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne [string]$Context.StoreId -or [string]$Result.Path -cne [string]$Context.Path -or [string]$Result.DomainDn -ine [string]$Context.DomainDn){return $false}
    Initialize-DomeniaAccountPreferences
    if([long]$Result.SnapshotRevision -lt [long]$script:AccountPreferences.Revision){return $false}
    $rows=@{}
    foreach($row in @($Result.AccountPreferences)){
        if([string]$row.DomainDn -ine [string]$Context.DomainDn){return $false}
        $scope=Get-DomeniaAccountPreferenceScope ([string]$row.Scope)
        $rows[$scope]=[string]$row.UserName
    }
    $script:AccountPreferences.Identity=Get-DomeniaAccountPreferenceIdentity
    $script:AccountPreferences.Rows=$rows;$script:AccountPreferences.Revision=[long]$Result.SnapshotRevision
    Update-DomeniaRememberedAccountFields
    return $true
}
function Save-DomeniaAccountPreference {
    param([string]$Scope,[AllowEmptyString()][string]$UserName,[string]$Target='')
    Initialize-DomeniaAccountPreferences
    try{
        if($script:AccountPreferences.Pending.Count -ge 64){throw 'File des identifiants a memoriser pleine.'}
        $id=[guid]::NewGuid().ToString('D');$context=New-DomeniaStoreContext -RequestId ('account-'+$id)
        $scopes=if($Scope -eq 'Secrets'){@('Laps','BitLocker')}else{@(Get-DomeniaAccountPreferenceScope -Scope $Scope -Target $Target -UserName $UserName)}
        $changes=@(foreach($usage in $scopes){[pscustomobject]@{Kind='AccountPreference';Scope=$usage;UserName=$UserName.Trim();DomainDn=$context.DomainDn;UpdatedAtUtc=[datetime]::UtcNow.ToString('o')}})
        $state=[pscustomobject]@{Context=$context;BatchId=$id;Changes=$changes;Accepted=$false;Warned=$false}
        # Validate before retaining anything. ConvertTo-DomeniaStoreBatch projects the exact permitted fields.
        [void](ConvertTo-DomeniaStoreBatch -Context $context -BatchId $id -Sequence 0 -Changes $changes)
        $script:AccountPreferences.Pending[$id]=$state
        Sync-DomeniaAccountPreferences
        return $true
    }catch{
        Set-Status 'Compte actif pour cette session ; identifiant non memorise. Verifiez la base locale dans Outils.' 'WARN'
        Write-AppLog ('Memorisation de l identifiant impossible : '+$_.Exception.Message) 'WARN'
        return $false
    }
}
function Sync-DomeniaAccountPreferences {
    # Uses the existing access heartbeat. All SQLite work runs through LocalStore/LocalIndexRead.
    if([bool]$script:AsyncEngineClosing){return}
    Initialize-DomeniaAccountPreferences
    $p=$script:AccountPreferences
    foreach($state in @($p.Pending.Values)){
        if([bool]$state.Accepted){continue}
        try{
            $admission=Submit-DomeniaStoreBatch -Context $state.Context -BatchId $state.BatchId -Sequence 0 -Changes $state.Changes -SuccessHandler 'Complete-DomeniaAccountPreferenceSave' -ErrorHandler 'Fail-DomeniaAccountPreferenceSave' -CallbackState $state
            $state.Accepted=[bool]$admission.Accepted
            if(-not $state.Accepted){break}
        }catch{Fail-DomeniaAccountPreferenceSave -Message $_.Exception.Message -State $state;break}
    }
    $identity=Get-DomeniaAccountPreferenceIdentity
    if($p.Identity -cne $identity){
        $p.Identity=$identity;$p.Rows=@{};$p.Revision=-1;$p.ReadId='';$p.ReadAfter=[datetime]::MinValue
    }
    if($p.ReadId -or $p.ReadAfter -gt [datetime]::UtcNow -or -not $script:DatabaseScopedPath -or -not [string]$script:Conn.BaseDn){return}
    $id=[guid]::NewGuid().ToString('D');$p.ReadId=$id
    try{
        $context=New-DomeniaStoreContext -RequestId ('account-read-'+$id)
        $state=[pscustomobject]@{Context=$context;ReadId=$id}
        $job=Request-DomeniaStoreRead -Context $context -Query @{Kind='AccountPreference'} -SuccessHandler 'Complete-DomeniaAccountPreferenceRead' -ErrorHandler 'Fail-DomeniaAccountPreferenceRead' -CallbackState $state
        if(-not $job){throw 'Lecture des identifiants non admise.'}
    }catch{
        $p.ReadId='';$p.ReadAfter=[datetime]::UtcNow.AddSeconds(30)
    }
}
function Complete-DomeniaAccountPreferenceRead {
    param($Result,$State)
    if($null -eq $script:AccountPreferences -or [string]$State.ReadId -cne [string]$script:AccountPreferences.ReadId -or -not (Test-DomeniaAccountPreferenceContext $State.Context)){return}
    $script:AccountPreferences.ReadId=''
    if([bool]$Result.Missing -or [bool]$Result.Busy){$script:AccountPreferences.ReadAfter=[datetime]::UtcNow.AddSeconds(30);return}
    if(Set-DomeniaCommittedAccountPreferences -Result $Result -Context $State.Context){$script:AccountPreferences.ReadAfter=[datetime]::MaxValue}
    else{$script:AccountPreferences.ReadAfter=[datetime]::UtcNow.AddSeconds(30)}
}
function Fail-DomeniaAccountPreferenceRead {
    param([string]$Message,$State)
    if($null -eq $script:AccountPreferences -or [string]$State.ReadId -cne [string]$script:AccountPreferences.ReadId){return}
    $script:AccountPreferences.ReadId='';$script:AccountPreferences.ReadAfter=[datetime]::UtcNow.AddSeconds(30)
}
function Complete-DomeniaAccountPreferenceSave {
    param($Result,$State)
    if(-not [bool]$Result.Saved -or [string]$Result.BatchId -cne [string]$State.BatchId -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne [string]$State.Context.StoreId -or [string]$Result.Path -cne [string]$State.Context.Path){
        Fail-DomeniaAccountPreferenceSave -Message 'Recu de sauvegarde non confirme.' -State $State;return
    }
    if($null -ne $script:AccountPreferences){[void]$script:AccountPreferences.Pending.Remove([string]$State.BatchId)}
    [void](Set-DomeniaCommittedAccountPreferences -Result $Result -Context $State.Context)
}
function Fail-DomeniaAccountPreferenceSave {
    param([string]$Message,$State)
    # The central writer retains accepted batches for retry with the same ID. Do not requeue a new copy.
    if($null -eq $State -or [bool]$State.Warned){return}
    $State.Warned=$true
    if(Test-DomeniaAccountPreferenceContext $State.Context){Set-Status 'Compte disponible pour cette session. Memorisation de son identifiant en attente dans la base locale.' 'WARN'}
}
