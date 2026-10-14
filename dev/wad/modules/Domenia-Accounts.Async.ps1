# One account validation at a time; no Dispatcher wait and no silent identity variants.
$script:AccountValidation=$null
function Start-DomeniaAccountValidation {
    param([string]$UserName,[Security.SecureString]$Password,[string]$Operation='Test compte',[string]$ActivateScope='',[int]$TimeoutSeconds=12,[switch]$RememberSecret)
    if(Test-DomeniaAccessBusyWrite){throw 'Verification d ecriture en cours. Aucun compte ne peut etre change.'}
    if($null -ne $script:AccountValidation){throw 'Une validation est deja active ou en nettoyage.'}
    if(-not $UserName.Trim() -or $null -eq $Password -or $Password.Length -eq 0){throw 'Compte et mot de passe requis.'}
    $copy=$Password.Copy();$copy.MakeReadOnly();$session=$null
    try {
        $request=New-DomeniaAccountAuthRequest -UserName $UserName -Password $copy -TimeoutSeconds $TimeoutSeconds
        $session=Start-DomeniaLoginAuthRunspace -Request $request
        $script:AccountValidation=[pscustomobject]@{Session=$session;Started=[datetime]::UtcNow;Epoch=[long]$script:SessionEpoch;Base=[string]$script:Conn.BaseDn;Scope=$ActivateScope;Operation=$Operation;Password=$copy;Timeout=$TimeoutSeconds;Abandoned=$false;Timer=$null;Busy=@('BtnAccountAdTest','BtnAccountAdCorrect','PwdAccountAdCorrection','BtnAccountRemoteTest','BtnAccountRemoteSave','BtnAccountRemoteClear','BtnAccountSecretsTest','BtnAccountSecretsSave','BtnAccountSecretsClear','TxtAccountRemoteUser','PwdAccountRemote','TxtAccountSecretsUser','PwdAccountSecrets')}
        $script:AccountValidation|Add-Member -NotePropertyName RememberSecret -NotePropertyValue ([bool]$RememberSecret)
        $script:AccountValidation.Busy+=@('ChkAccountRemoteRemember','ChkAccountSecretsRemember','BtnAccountRemoteVault','BtnAccountSecretsVault','BtnAccountRemoteForgetVault','BtnAccountSecretsForgetVault')
        Set-ControlsBusy -Names $script:AccountValidation.Busy -Busy $true
        # FI-05: protected heartbeat timer, owned and registered by the factory; it also runs minimized.
        $script:AccountValidation.Timer=New-DomeniaTimer -Owner 'Timer:AccountValidation' -IntervalMs 100 -RunWhenHidden -Start -Tick {Complete-DomeniaAccountValidation}
        Set-Status ($Operation+' en cours. La fenetre reste disponible.')
        return [pscustomobject]@{Started=$true;Success=$false;Pending=$true}
    }catch{
        if($null -ne $session){Stop-DomeniaLoginAuthRunspace -Session $session -Terminate}
        if($null -ne $script:AccountValidation){if($null -ne $script:AccountValidation.Timer){$script:AccountValidation.Timer.Stop()};Set-ControlsBusy -Names $script:AccountValidation.Busy -Busy $false;$script:AccountValidation=$null}
        $copy.Dispose();throw
    }
}
function Complete-DomeniaAccountValidation {
    $v=$script:AccountValidation;if($null -eq $v){return}
    if($v.Epoch -ne [long]$script:SessionEpoch -or $v.Base -ine [string]$script:Conn.BaseDn -or $script:AsyncEngineClosing){$v.Abandoned=$true}
    if(-not [bool]$v.Session.Cleaned -and -not $v.Session.AsyncResult.IsCompleted){
        if(-not $v.Abandoned -and ([datetime]::UtcNow-$v.Started).TotalSeconds -ge $v.Timeout){
            $v.Abandoned=$true;Set-Status 'Validation trop longue. Compte precedent conserve ; nettoyage en cours.' 'WARN'
        }
        if($v.Abandoned -and -not $v.Session.CancelRequested){Stop-DomeniaLoginAuthRunspace -Session $v.Session -Terminate}
        return
    }
    try {
        if($v.Abandoned){return}
        $r=Read-DomeniaAuthRunspaceResult -Session $v.Session
        if($null -eq $r -or -not $r.Success){throw ('Validation non confirmee : '+[string]$r.Error)}
        if($r.AuthMode -ne 'Explicit' -or -not [string]$r.BindUser -or [string]$r.BaseDn -ine $v.Base){throw 'Identite AD non confirmee.'}
        if(Test-DomeniaAccessBusyWrite){throw 'Une ecriture a commence. Compte conserve ; relancez volontairement le test.'}
        if($v.Scope -in @('Remote','Secrets')){
            $owned=$v.Password.Copy();$owned.MakeReadOnly();$cred=[Management.Automation.PSCredential]::new([string]$r.BindUser,$owned)
            if($v.Scope -eq 'Remote'){$script:RemoteAdminCredential=$cred}
            else{$script:SecretsCredential=$cred}
            $scopes=if($v.Scope -eq 'Remote'){@('Remote')}else{@((Get-DomeniaAccessScope 'ReadLaps'),(Get-DomeniaAccessScope 'ReadBitLockerKey'))}
            if($null -ne $script:AccessState){
                # D051: activating the Secrets account replaces only the LAPS and BitLocker temporary accounts
                # (Get-DomeniaAccessScope of their resources); the directory and workstation accounts are kept.
                foreach($k in $scopes){Remove-DomeniaAccessCredential -Key $k;[void]$script:AccessState.Faults.Remove($k)}
                # Refusals recorded for the previous identity do not apply to the newly activated Secrets account.
                if($v.Scope -eq 'Secrets'){foreach($d in @($script:AccessState.Denied.Keys)){if(([string]$d).StartsWith('laps|') -or ([string]$d).StartsWith('bitlocker|')){[void]$script:AccessState.Denied.Remove($d)}}}
            }
            $field=Get-DomeniaControl $(if($v.Scope -eq 'Remote'){'PwdAccountRemote'}else{'PwdAccountSecrets'});if($null -ne $field){$field.Clear()}
            # Point 44: the same path as every other correction: generation, protection of this account only, old reads.
            $summary=Complete-DomeniaAccountCorrection -UserName ([string]$cred.UserName) -Scopes $scopes
            Set-Status ('Compte '+$v.Scope+' active : '+$cred.UserName+'. Droits sur la ressource non certifies par ce test AD. '+$summary)
            [void](Save-DomeniaAccountPreference -Scope $v.Scope -UserName $cred.UserName)
            $userField=Get-DomeniaControl ('TxtAccount'+$v.Scope+'User')
            if($null -ne $userField){$userField.Text=$cred.UserName}
            if($null -ne $script:AccountPreferences){$script:AccountPreferences.FieldSeeds['TxtAccount'+$v.Scope+'User']=$cred.UserName}
            if([bool]$v.RememberSecret){[void](Save-DomeniaSecondaryVault -Scope $v.Scope -Credential $cred -Remember)}
        }elseif($v.Scope -eq 'Directory'){
            # Point 44: the password of the connection account, corrected in place for the SAME identity only.
            $domain=[string]$script:Conn.Domain;$netbios=[string]$script:Conn.Netbios
            $same=((Get-DomeniaCredentialAccountKey ([string]$r.BindUser) $domain $netbios) -ceq (Get-DomeniaCredentialAccountKey ([string]$script:Conn.BindUser) $domain $netbios))
            if((-not $same) -or (-not [bool]$script:Conn.UseCredential)){throw 'Identité différente de celle de la session : rien nʼest remplacé. Pour un autre compte, utilisez Se connecter.'}
            $owned=$v.Password.Copy();$owned.MakeReadOnly()
            $script:Conn.Credential=[Management.Automation.PSCredential]::new([string]$script:Conn.BindUser,$owned)
            $script:DirectoryCredentialFaulted=$false;$script:DirectoryCredentialFaultMessage=''
            $field=Get-DomeniaControl 'PwdAccountAdCorrection';if($null -ne $field){$field.Clear()}
            $summary=Complete-DomeniaAccountCorrection -UserName ([string]$script:Conn.BindUser) -Scopes @('Directory')
            Set-Status ('Mot de passe du compte de connexion corrigé sans reconnecter Domenia. '+$summary+' Sʼil est mémorisé dans le coffre Windows pour la connexion, ressaisissez-le à la prochaine connexion.')
        }else{
            Set-Status ('Identite AD validee : '+$r.BindUser+'. Droits poste et secrets non testes.')
            # Point 45: a validated identity lets the directory confirm its other names (same SID). This read is an
            # addition: its failure never undoes the validation.
            try{[void](Request-DomeniaAccountAliasRead -UserName ([string]$r.BindUser))}catch{}
        }
        Update-DomeniaAccountUi;Update-DomeniaSecretActionUi
    }catch{[void](Show-DomeniaOperationError -Operation $v.Operation -ErrorRecordOrException $_)}
    finally {
        $v.Timer.Stop();Stop-DomeniaLoginAuthRunspace -Session $v.Session -Terminate
        $v.Password.Dispose();Set-ControlsBusy -Names $v.Busy -Busy $false;$script:AccountValidation=$null
    }
}
function Stop-DomeniaAccountValidation {
    if($null -eq $script:AccountValidation){return}
    $script:AccountValidation.Abandoned=$true
    Stop-DomeniaLoginAuthRunspace -Session $script:AccountValidation.Session -Terminate
}
function Start-DomeniaDirectoryCorrection {
    # Point 44: after a password change in the directory, the connection account is corrected in place with ONE
    # validation of the same identity, at the operator's request. Another account goes through Se connecter.
    if([bool]$script:DemoMode){throw 'Démonstration : aucun compte de connexion à corriger.'}
    if((-not [bool]$script:Conn.UseCredential) -or ($null -eq $script:Conn.Credential)){throw 'Session Windows : son mot de passe se corrige dans Windows. Pour un autre compte, utilisez Se connecter.'}
    $bind=([string]$script:Conn.BindUser).Trim()
    if(-not $bind){throw 'Identité de la session inconnue : utilisez Se connecter.'}
    $domain=[string]$script:Conn.Domain;$netbios=[string]$script:Conn.Netbios
    $typed='';$field=Get-DomeniaControl 'TxtAccountAdUser';if($null -ne $field){$typed=([string]$field.Text).Trim()}
    if($typed -and ((Get-DomeniaCredentialAccountKey $typed $domain $netbios) -cne (Get-DomeniaCredentialAccountKey $bind $domain $netbios))){throw 'Lʼidentifiant affiché nʼest pas celui de la session. Pour changer de compte, utilisez Se connecter.'}
    $box=Get-DomeniaControl 'PwdAccountAdCorrection'
    if(($null -eq $box) -or ($box.SecurePassword.Length -eq 0)){throw 'Saisissez le mot de passe actuel du compte de connexion.'}
    [void](Start-DomeniaAccountValidation -UserName $bind -Password $box.SecurePassword -Operation 'Correction du compte de connexion' -ActivateScope 'Directory')
}
function Show-DomeniaDirectoryCorrection {
    # Point 44: route of a refused connection account: the correction field of Comptes, never a new window.
    try{Select-DomeniaWorkspace -Workspace 'TabAccounts'}catch{}
    $box=Get-DomeniaControl 'PwdAccountAdCorrection'
    if($null -ne $box){try{[void]$box.Focus()}catch{}}
    Set-Status 'Compte de connexion refusé : saisissez son mot de passe actuel dans Comptes, puis Corriger le mot de passe. Pour un autre compte, utilisez Se connecter.' 'WARN'
}
function Get-DomeniaAccountCorrectionJobs {
    # Point 44: the running and queued tasks as the correction plan reads them: keys and generation of the account
    # each task left with. Never the context, the payload or a credential.
    $rows=[Collections.Generic.List[object]]::new()
    if($null -eq $script:AsyncJobs){return ,$rows.ToArray()}
    foreach($job in @($script:AsyncJobs.Values)){
        if($null -eq $job){continue}
        $context=Get-DomeniaMember $job 'CredentialGuardContext' $null
        $keys=@();$generation=0L
        if($null -ne $context){$keys=@(Get-WCredentialGuardKeys $context);$generation=[long](Get-DomeniaMember $context 'CredentialGeneration' 0)}
        $rows.Add([pscustomobject]@{Id=[string]$job.Id;IsWrite=[bool]$job.IsWrite;NonCancellable=[bool]$job.NonCancellable;State=[string]$job.State;Keys=$keys;Generation=$generation})
    }
    return ,$rows.ToArray()
}
function Complete-DomeniaAccountCorrection {
    # Point 44: the single path of every account validated by the operator without reconnecting Domenia (connection
    # account, workstation account, secrets account, temporary account of one resource). The account generation
    # moves; this account alone, with its confirmed aliases, leaves the protection; reads that left with the
    # previous password are stopped and can no longer authenticate; queued reads leave later with the validated
    # account. A write is never stopped nor replayed. Operations paused without a located account stay paused.
    param([Parameter(Mandatory=$true)][string]$UserName,[string[]]$Scopes=@(),[string]$Target='')
    $script:DomeniaAccountGeneration=[long]$script:DomeniaAccountGeneration+1
    $generation=[long]$script:DomeniaAccountGeneration
    $guard=Initialize-DomeniaCredentialGuard
    $key=Get-DomeniaCredentialAccountKey $UserName ([string]$script:Conn.Domain) ([string]$script:Conn.Netbios) $Target
    $keys=@(Get-DomeniaCredentialGroupKeys -Guard $guard -Key $key)
    $plan=Get-DomeniaAccountCorrectionPlan -Jobs @(Get-DomeniaAccountCorrectionJobs) -Keys $keys -Generation $generation
    $released=@(Clear-DomeniaCredentialGuardFault -Guard $guard -Keys $keys -Generation $generation)
    if($released.Count){Add-DomeniaCredentialFailureHistory $released}
    foreach($id in @($plan.Stop)){try{Request-UiTaskStop -Id ([string]$id) -Silent -Reason 'Compte corrigé : lecture partie avec lʼancien mot de passe'}catch{}}
    if($null -ne $script:AccessState){
        foreach($scope in @($Scopes|Where-Object{$_})){
            [void]$script:AccessState.Faults.Remove([string]$scope)
            foreach($pendingKey in @($script:AccessState.Pending.Keys)){if([string]$script:AccessState.Pending[$pendingKey].Scope -eq [string]$scope){[void]$script:AccessState.Pending.Remove($pendingKey)}}
        }
        try{Update-DomeniaAccessButton}catch{}
    }
    $ambiguous=0
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{if($guard.ContainsKey('AmbiguousOperations')){$ambiguous=[int]$guard.AmbiguousOperations.Count}}finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
    $text=[string]$plan.Text
    if($released.Count){$text='Protection levée pour ce compte seulement. '+$text}
    if($ambiguous -eq 1){$text+=' Une opération suspendue sans compte identifié reste arrêtée jusquʼà la reconnexion.'}
    elseif($ambiguous -gt 1){$text+=' '+[string]$ambiguous+' opérations suspendues sans compte identifié restent arrêtées jusquʼà la reconnexion.'}
    Write-AppLog ('Compte corrigé sans reconnexion : '+$UserName+'. '+$text) 'INFO'
    # Point 45: the validated identity lets the directory confirm its other names; never a reason to undo the correction.
    try{[void](Request-DomeniaAccountAliasRead -UserName $UserName)}catch{}
    return $text
}
$script:DomeniaAccountAlias=$null
$script:DomeniaCredentialAliasBook=$null
function Request-DomeniaAccountAliasRead {
    # Point 45: once per session and per validated identity, the directory confirms the SID and the other names of
    # that account (one exact lookup, with the session directory account). Bounded queue, one read at a time.
    param([string]$UserName)
    if([bool]$script:DemoMode){return $false}
    if(-not ([string]$script:Conn.BaseDn)){return $false}
    $lookup=ConvertTo-DomeniaAccountLookup -UserName $UserName -Domain ([string]$script:Conn.Domain) -Netbios ([string]$script:Conn.Netbios)
    if(-not [bool]$lookup.Valid){return $false}
    $state=$script:DomeniaAccountAlias
    if(($null -eq $state) -or ([long]$state.Epoch -ne [long]$script:SessionEpoch) -or ([string]$state.BaseDn -ine [string]$script:Conn.BaseDn)){
        $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;Done=@{};Queue=[Collections.Generic.Queue[object]]::new();Job=''}
        $script:DomeniaAccountAlias=$state
    }
    $key=Get-DomeniaCredentialAccountKey $UserName ([string]$script:Conn.Domain) ([string]$script:Conn.Netbios)
    if((-not $key) -or $state.Done.ContainsKey($key) -or ($state.Queue.Count -ge 8)){return $false}
    $state.Done[$key]=$true
    $state.Queue.Enqueue([pscustomobject]@{UserName=$UserName;Key=$key;Sam=[string]$lookup.Sam;Upn=[string]$lookup.Upn})
    Invoke-DomeniaAccountAliasQueue
    return $true
}
function Invoke-DomeniaAccountAliasQueue {
    $state=$script:DomeniaAccountAlias
    if(($null -eq $state) -or $script:AsyncEngineClosing){return}
    # A job withdrawn without callback (session change) never blocks the queue.
    if($state.Job -and (($null -eq $script:AsyncJobs) -or (-not $script:AsyncJobs.Contains([string]$state.Job)))){$state.Job=''}
    if($state.Job -or ($state.Queue.Count -eq 0)){return}
    $next=$state.Queue.Dequeue()
    $callback=[pscustomobject]@{Epoch=[long]$state.Epoch;BaseDn=[string]$state.BaseDn;UserName=[string]$next.UserName;Key=[string]$next.Key}
    try{
        $state.Job=[string](Start-UiTask -Name ('Alias du compte '+[string]$next.UserName) -OperationId 'AccountAliasRead' -Code (Get-DomeniaAccountAliasWorkerCode) -Payload ([pscustomobject]@{Sam=[string]$next.Sam;Upn=[string]$next.Upn}) -CallbackState $callback -SuccessHandler 'Complete-DomeniaAccountAliasRead' -ErrorHandler 'Fail-DomeniaAccountAliasRead' -TimeoutSeconds 30 -TaskClass 'Background')
    }catch{$state.Job='';try{Write-AppLog ('Rapprochement des noms du compte non lancé : '+$_.Exception.Message) 'WARN'}catch{}}
}
function Complete-DomeniaAccountAliasRead {
    param($Result,$State)
    if($null -ne $script:DomeniaAccountAlias){$script:DomeniaAccountAlias.Job=''}
    try{
        if(($null -eq $State) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.BaseDn -ine [string]$script:Conn.BaseDn)){return}
        $r=Get-DomeniaEffectiveWorkerResult $Result @('State','Sid')
        if(($null -eq $r) -or ([string]$r.State -ne 'Resolved')){
            $why='compte introuvable'
            if($null -eq $r){$why='résultat absent'}elseif([string]$r.State -eq 'Ambiguous'){$why='plusieurs comptes correspondent'}
            Write-AppLog ('Noms du compte '+[string]$State.UserName+' non rapprochés : '+$why+'. Aucune association supposée.') 'INFO'
            return
        }
        $domain=[string]$script:Conn.Domain;$netbios=[string]$script:Conn.Netbios
        $keys=@(Get-DomeniaCredentialAliasKeys -Sam ([string]$r.Sam) -Upn ([string]$r.Upn) -Domain $domain -Netbios $netbios -Also @([string]$State.UserName))
        $answer=Register-DomeniaCredentialAliases -Guard (Initialize-DomeniaCredentialGuard) -Sid ([string]$r.Sid) -Keys $keys
        if(-not [bool]$answer.Registered){Write-AppLog ('Noms du compte '+[string]$State.UserName+' non rapprochés : '+[string]$answer.Reason) 'INFO';return}
        if($null -eq $script:DomeniaCredentialAliasBook){$script:DomeniaCredentialAliasBook=@{}}
        $sid=([string]$r.Sid).ToUpperInvariant()
        if(($script:DomeniaCredentialAliasBook.Count -lt 32) -or $script:DomeniaCredentialAliasBook.ContainsKey($sid)){$script:DomeniaCredentialAliasBook[$sid]=[pscustomobject]@{Sid=$sid;BaseDn=[string]$State.BaseDn;Keys=@($answer.Keys)}}
        $text='Noms rapprochés par SID pour '+[string]$State.UserName+' : '+(@($answer.Keys) -join ', ')+'.'
        if(@($answer.Conflicts).Count){$text+=' Déjà associés à un autre compte, non déplacés : '+(@($answer.Conflicts) -join ', ')+'.'}
        Write-AppLog $text 'INFO'
        # A pause already recorded under one of these names now covers the others: withdraw their queued reads.
        if([int]$answer.Propagated -gt 0){Sync-DomeniaCredentialGuardUi}
        try{Update-DomeniaAccountUi}catch{}
    }finally{Invoke-DomeniaAccountAliasQueue}
}
function Fail-DomeniaAccountAliasRead {
    param($Message,$State)
    if($null -ne $script:DomeniaAccountAlias){$script:DomeniaAccountAlias.Job=''}
    try{
        if(($null -ne $State) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch)){Write-AppLog ('Noms du compte '+[string]$State.UserName+' non rapprochés : '+[string]$Message+'. Aucune association supposée.') 'INFO'}
    }finally{Invoke-DomeniaAccountAliasQueue}
}
function Get-DomeniaAccountAliasSummary {
    # Point 45: the names confirmed for one account, for the Comptes tab. Read under the guard lock.
    $guard=$script:DomeniaCredentialGuard
    $lines=[Collections.Generic.List[string]]::new()
    if($null -eq $guard){return ,$lines.ToArray()}
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{
        if($guard.ContainsKey('Groups')){foreach($group in @($guard.Groups.Keys|Sort-Object)){$names=@($guard.Groups[$group]);if($names.Count -gt 1){$lines.Add((($names|Sort-Object) -join ' = ')+' (même SID)')}}}
    }finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
    return ,$lines.ToArray()
}
