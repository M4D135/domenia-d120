# One account validation at a time; no Dispatcher wait and no silent identity variants.
$script:AccountValidation=$null
function Start-DomeniaAccountValidation {
    param([string]$UserName,[Security.SecureString]$Password,[string]$Operation='Test compte',[string]$ActivateScope='',[int]$TimeoutSeconds=12)
    if(Test-DomeniaAccessBusyWrite){throw 'Verification d ecriture en cours. Aucun compte ne peut etre change.'}
    if($null -ne $script:AccountValidation){throw 'Une validation est deja active ou en nettoyage.'}
    if(-not $UserName.Trim() -or $null -eq $Password -or $Password.Length -eq 0){throw 'Compte et mot de passe requis.'}
    $copy=$Password.Copy();$copy.MakeReadOnly();$session=$null
    try {
        $request=New-DomeniaAccountAuthRequest -UserName $UserName -Password $copy -TimeoutSeconds $TimeoutSeconds
        $session=Start-DomeniaLoginAuthRunspace -Request $request
        $script:AccountValidation=[pscustomobject]@{Session=$session;Started=[datetime]::UtcNow;Epoch=[long]$script:SessionEpoch;Base=[string]$script:Conn.BaseDn;Scope=$ActivateScope;Operation=$Operation;Password=$copy;Timeout=$TimeoutSeconds;Abandoned=$false;Timer=$null;Busy=@('BtnAccountAdTest','BtnAccountRemoteTest','BtnAccountRemoteSave','BtnAccountRemoteClear','BtnAccountSecretsTest','BtnAccountSecretsSave','BtnAccountSecretsClear','TxtAccountRemoteUser','PwdAccountRemote','TxtAccountSecretsUser','PwdAccountSecrets')}
        Set-ControlsBusy -Names $script:AccountValidation.Busy -Busy $true
        $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
        $timer.Interval=[timespan]::FromMilliseconds(100);$timer.Add_Tick({Complete-DomeniaAccountValidation})
        $script:AccountValidation.Timer=$timer;$timer.Start()
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
            if($v.Scope -eq 'Remote'){$script:RemoteAdminCredential=$cred;Set-DomeniaSetting 'RemoteCredentialUser' $cred.UserName}
            else{$script:SecretsCredential=$cred;Set-DomeniaSetting 'SecretsCredentialUser' $cred.UserName}
            if($null -ne $script:AccessState){
                # D051: activating the Secrets account replaces only the LAPS and BitLocker temporary accounts
                # (Get-DomeniaAccessScope of their resources); the directory and workstation accounts are kept.
                $scopes=if($v.Scope -eq 'Remote'){@('Remote')}else{@((Get-DomeniaAccessScope 'ReadLaps'),(Get-DomeniaAccessScope 'ReadBitLockerKey'))}
                foreach($k in $scopes){Remove-DomeniaAccessCredential -Key $k;[void]$script:AccessState.Faults.Remove($k)}
                # Refusals recorded for the previous identity do not apply to the newly activated Secrets account.
                if($v.Scope -eq 'Secrets'){foreach($d in @($script:AccessState.Denied.Keys)){if(([string]$d).StartsWith('laps|') -or ([string]$d).StartsWith('bitlocker|')){[void]$script:AccessState.Denied.Remove($d)}}}
            }
            $field=Get-DomeniaControl $(if($v.Scope -eq 'Remote'){'PwdAccountRemote'}else{'PwdAccountSecrets'});if($null -ne $field){$field.Clear()}
            Set-Status ('Compte '+$v.Scope+' active : '+$cred.UserName+'. Droits sur la ressource non certifies par ce test AD.')
        }else{Set-Status ('Identite AD validee : '+$r.BindUser+'. Droits poste et secrets non testes.')}
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
