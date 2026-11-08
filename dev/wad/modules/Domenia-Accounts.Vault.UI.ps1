# Explicit user actions only. This adapter never reads the vault at startup or during a background probe.
function Save-DomeniaSecondaryVault {
    param([string]$Scope,[Management.Automation.PSCredential]$Credential,[switch]$Remember,[string]$Target='')
    if(-not $Remember -or [bool]$script:DemoMode){return $false}
    $scopes=if($Scope -eq 'Secrets'){@('Laps','BitLocker')}else{@(Get-DomeniaAccountPreferenceScope -Scope $Scope -Target $Target -UserName $Credential.UserName)}
    $saved=0
    try{
        foreach($usage in $scopes){
            $receipt=Save-DomeniaCredentialVaultCredential -DomainDn ([string]$script:Conn.BaseDn) -Scope $usage -Credential $Credential -Enabled -AuthenticationConfirmed
            if(-not [bool]$receipt.Saved){throw 'Enregistrement dans le coffre non confirme.'};$saved++
        }
        Set-Status 'Compte valide. Mot de passe memorise dans le coffre Windows de ce PC.'
        return $true
    }catch{
        Set-Status ('Compte disponible pour cette session. Coffre Windows : '+$saved+'/'+$scopes.Count+' usage(s) enregistres ; verifiez le coffre avant de fermer.') 'WARN'
        return $false
    }
}
function Invoke-DomeniaSecondaryVaultLogin {
    param([ValidateSet('Remote','Secrets')][string]$Scope)
    $credential=$null
    try{
        if([bool]$script:DemoMode){throw 'Le coffre n est pas utilise en demonstration.'}
        if($null -ne $script:AccountValidation){throw 'Attendez la fin de la validation en cours.'}
        $user=([string](Get-DomeniaControl ('TxtAccount'+$Scope+'User')).Text).Trim()
        if(-not $user){throw 'Choisissez d abord l identifiant memorise.'}
        $usage=if($Scope -eq 'Secrets'){'Laps'}else{'Remote'}
        $credential=Get-DomeniaCredentialVaultCredential -DomainDn ([string]$script:Conn.BaseDn) -Scope $usage -UserName $user -Enabled
        if($null -eq $credential){throw 'Aucun mot de passe memorise pour ce compte et cet usage sur ce PC.'}
        # Start copies the SecureString before returning. No secret is assigned to a text or password box.
        [void](Start-DomeniaAccountValidation -UserName $credential.UserName -Password $credential.Password -ActivateScope $Scope -Operation ('Connexion avec le coffre : '+$Scope))
    }catch{Set-Status $_.Exception.Message 'WARN'}
    finally{if($null -ne $credential){$credential.Password.Dispose()}}
}
function Remove-DomeniaSecondaryVault {
    param([ValidateSet('Remote','Secrets')][string]$Scope)
    try{
        if([bool]$script:DemoMode){throw 'Le coffre n est pas utilise en demonstration.'}
        $user=([string](Get-DomeniaControl ('TxtAccount'+$Scope+'User')).Text).Trim()
        if(-not $user){throw 'Choisissez d abord l identifiant a oublier dans le coffre.'}
        $scopes=if($Scope -eq 'Secrets'){@('Laps','BitLocker')}else{@('Remote')}
        foreach($usage in $scopes){[void](Remove-DomeniaCredentialVaultCredential -DomainDn ([string]$script:Conn.BaseDn) -Scope $usage -UserName $user -Enabled)}
        $choice=Get-DomeniaControl ('ChkAccount'+$Scope+'Remember');if($null -ne $choice){$choice.IsChecked=$false}
        Set-Status 'Mot de passe oublie dans le coffre Windows. Le compte de la session reste actif jusqu a sa deconnexion.'
        return $true
    }catch{Set-Status ('Suppression du coffre non confirmee : '+$_.Exception.Message) 'WARN';return $false}
}
function Initialize-DomeniaAccountVaultUi {
    foreach($scope in @('Remote','Secrets')){
        $use=Get-DomeniaControl ('BtnAccount'+$scope+'Vault');$forget=Get-DomeniaControl ('BtnAccount'+$scope+'ForgetVault')
        if($null -ne $use){$use.Tag=$scope;$use.Add_Click({param($sender,$eventArgs)Invoke-DomeniaSecondaryVaultLogin -Scope ([string]$sender.Tag)})}
        if($null -ne $forget){$forget.Tag=$scope;$forget.Add_Click({param($sender,$eventArgs)[void](Remove-DomeniaSecondaryVault -Scope ([string]$sender.Tag))})}
    }
}
