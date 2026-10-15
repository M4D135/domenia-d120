#requires -Version 5.1
# Point 43: qualification of the optional Windows vault. Explicit consent, targeted use and forget, and no secret value
# in the SQLite batches, the journal, the status messages, the form fields or an export. Synthetic markers generated at
# run time only: no real password, domain or network is used.
# Without -NativeWindows the native vault is replaced by an in-memory double keyed by the REAL vault targets; with
# -NativeWindows (Windows PowerShell 5.1 in the user session of the qualification VM) the real Windows vault is used on
# an isolated fictional domain and every entry written is removed again.
[CmdletBinding()]param([string]$ReportPath='',[switch]$NativeWindows)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
foreach($name in @('Common.Model','Relations.Model','Guard.Model','Safety.Model','Access.Model','Accounts.Model','Store.Model','CredentialVault.Model','Accounts.Store.UI','Accounts.Vault.UI')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new()
$script:RealVaultRead=${function:Get-DomeniaCredentialVaultCredential}
$script:RealVaultSave=${function:Save-DomeniaCredentialVaultCredential}
$script:RealVaultRemove=${function:Remove-DomeniaCredentialVaultCredential}
# Runtime-generated marker: it exists only in this process and is never written to the repository or a report.
$script:Marker=[guid]::NewGuid().ToString('N')+'-Qv!'
$script:Domain='DC=vault-qualification,DC=invalid'

function Assert {param($Value,[string]$Why='Assertion failed')if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
    Reset-Fixture
    try{& $Body|Out-Null;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=([string]$_.Exception.Message).Replace($script:Marker,'[MARQUEUR]')})}
}
function New-MarkerSecret {$s=[Security.SecureString]::new();foreach($c in $script:Marker.ToCharArray()){$s.AppendChar($c)};$s.MakeReadOnly();return $s}
function New-MarkerCredential {param([string]$User) return [Management.Automation.PSCredential]::new($User,(New-MarkerSecret))}
function Test-SecretIsMarker {
    # Compares a SecureString with the marker without creating a managed string of the secret.
    param([Security.SecureString]$Secret)
    if(($null -eq $Secret) -or ($Secret.Length -ne $script:Marker.Length)){return $false}
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try{for($i=0;$i -lt $script:Marker.Length;$i++){if([char][Runtime.InteropServices.Marshal]::ReadInt16($ptr,$i*2) -cne $script:Marker[$i]){return $false}};return $true}
    finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
}
function New-Field {
    $field=[pscustomobject]@{Text='';Password='';IsChecked=$true;IsKeyboardFocusWithin=$false}
    Add-Member -InputObject $field -MemberType ScriptMethod -Name Clear -Value {$this.Password=''}
    return $field
}
function Target {param([string]$Scope,[string]$User,[string]$Domain=$script:Domain) Get-DomeniaCredentialVaultTarget -DomainDn $Domain -Scope $Scope -UserName $User}
function Add-MemoryEntry {param([string]$Scope,[string]$User) $script:Vault[(Target $Scope $User)]=[pscustomobject]@{User=$User;Secret=(New-MarkerSecret)}}
function Use-MemoryVault {
    Set-Item -Path function:script:Get-DomeniaCredentialVaultCredential -Value {
        param([string]$DomainDn,[string]$Scope,[string]$UserName,[switch]$Enabled)
        if(-not $Enabled){return $null}
        $target=Get-DomeniaCredentialVaultTarget -DomainDn $DomainDn -Scope $Scope -UserName $UserName
        $script:VaultReads.Add($target)
        if(-not $script:Vault.ContainsKey($target)){return $null}
        $entry=$script:Vault[$target]
        return [Management.Automation.PSCredential]::new([string]$entry.User,$entry.Secret.Copy())
    }
    Set-Item -Path function:script:Save-DomeniaCredentialVaultCredential -Value {
        param([string]$DomainDn,[string]$Scope,[Management.Automation.PSCredential]$Credential,[switch]$Enabled,[switch]$AuthenticationConfirmed)
        if(-not $Enabled){return [pscustomobject]@{Saved=$false;Disabled=$true}}
        if(-not $AuthenticationConfirmed){throw 'Enregistrement refuse : authentification non confirmee.'}
        if($script:VaultWriteFails){throw 'Coffre indisponible (doublure).'}
        $target=Get-DomeniaCredentialVaultTarget -DomainDn $DomainDn -Scope $Scope -UserName $Credential.UserName
        $script:VaultWrites.Add($target)
        $copy=$Credential.Password.Copy();$copy.MakeReadOnly()
        $script:Vault[$target]=[pscustomobject]@{User=$Credential.UserName.Trim();Secret=$copy}
        return [pscustomobject]@{Saved=$true;Disabled=$false}
    }
    Set-Item -Path function:script:Remove-DomeniaCredentialVaultCredential -Value {
        param([string]$DomainDn,[string]$Scope,[string]$UserName,[switch]$Enabled)
        if(-not $Enabled){return [pscustomobject]@{Removed=$false;Disabled=$true}}
        $target=Get-DomeniaCredentialVaultTarget -DomainDn $DomainDn -Scope $Scope -UserName $UserName
        $script:VaultDeletes.Add($target)
        $removed=$script:Vault.ContainsKey($target);[void]$script:Vault.Remove($target)
        return [pscustomobject]@{Removed=$removed;Disabled=$false}
    }
}
function Use-NativeVault {
    Set-Item -Path function:script:Get-DomeniaCredentialVaultCredential -Value $script:RealVaultRead
    Set-Item -Path function:script:Save-DomeniaCredentialVaultCredential -Value $script:RealVaultSave
    Set-Item -Path function:script:Remove-DomeniaCredentialVaultCredential -Value $script:RealVaultRemove
}
# Boundaries of the adapters: interface, journal, account validation and the SQLite writer. Nothing else is doubled.
function Get-DomeniaControl {param($Name) return $script:Controls[[string]$Name]}
function Set-Status {param($Text,$Level) $script:Messages.Add([string]$Text)}
function Write-AppLog {param($Text,$Level) $script:Messages.Add([string]$Text)}
function Add-DomeniaUiLog {param($Area,$Level,$Text) $script:Messages.Add([string]$Text)}
function Start-DomeniaAccountValidation {
    param([string]$UserName,[Security.SecureString]$Password,[string]$Operation='',[string]$ActivateScope='',[int]$TimeoutSeconds=12,[switch]$RememberSecret)
    $copy=$Password.Copy();$copy.MakeReadOnly()
    $script:Validations.Add([pscustomobject]@{User=$UserName;Secret=$copy;Scope=$ActivateScope;Operation=$Operation})
    return [pscustomobject]@{Started=$true;Pending=$true}
}
function New-DomeniaStoreContext {
    param($RequestId)
    return [pscustomobject]@{Version=1;Path=$script:DatabaseScopedPath;DomainDn=([string]$script:Conn.BaseDn).ToLowerInvariant();StoreId=(Get-DomeniaStoreId $script:DatabaseScopedPath $script:Conn.BaseDn);SessionEpoch=$script:SessionEpoch;RequestId=$RequestId;Generation=1}
}
function Submit-DomeniaStoreBatch {
    param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)
    $batch=ConvertTo-DomeniaStoreBatch -Context $Context -BatchId $BatchId -Sequence $Sequence -Changes $Changes
    $script:Submissions.Add([pscustomobject]@{Batch=$batch;State=$CallbackState})
    return [pscustomobject]@{Accepted=$true;Backpressure=$false}
}
function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState) return 'read-job'}
function Reset-Fixture {
    $script:Vault=@{};$script:VaultWriteFails=$false
    $script:VaultReads=[Collections.Generic.List[string]]::new();$script:VaultWrites=[Collections.Generic.List[string]]::new();$script:VaultDeletes=[Collections.Generic.List[string]]::new()
    $script:Messages=[Collections.Generic.List[string]]::new();$script:Validations=[Collections.Generic.List[object]]::new();$script:Submissions=[Collections.Generic.List[object]]::new()
    $script:DemoMode=$false;$script:AccountValidation=$null;$script:SessionEpoch=1L;$script:AsyncEngineClosing=$false;$script:AccountPreferences=$null
    $script:Conn=[pscustomobject]@{BaseDn=$script:Domain}
    $script:DatabaseScopedPath=Join-Path ([IO.Path]::GetTempPath()) 'domenia-vault-qualification.db'
    $script:Controls=@{}
    foreach($name in @('TxtAccountRemoteUser','TxtAccountSecretsUser','PwdAccountRemote','PwdAccountSecrets','ChkAccountRemoteRemember','ChkAccountSecretsRemember')){$script:Controls[$name]=New-Field}
    Use-MemoryVault
}
function Assert-NoMarker {
    # Every text that leaves the adapters: status and journal lines, SQLite batches, form fields.
    param([string]$Where)
    $texts=New-Object 'System.Collections.Generic.List[string]'
    foreach($m in $script:Messages){$texts.Add([string]$m)}
    foreach($s in $script:Submissions){$texts.Add([string]$s.Batch.Json)}
    foreach($c in $script:Controls.Values){$texts.Add([string]$c.Text);$texts.Add([string]$c.Password)}
    foreach($t in $texts){if($t.Contains($script:Marker)){throw ('Valeur secrete trouvee : '+$Where)}}
}

Case 'Consentement : sans case cochee ni en demonstration, rien n entre dans le coffre' {
    $credential=New-MarkerCredential 'EXAMPLE\postes'
    Assert (-not (Save-DomeniaSecondaryVault -Scope Remote -Credential $credential)) 'Ecriture sans consentement'
    $script:DemoMode=$true
    Assert (-not (Save-DomeniaSecondaryVault -Scope Remote -Credential $credential -Remember)) 'Ecriture en demonstration'
    Assert ($script:VaultWrites.Count -eq 0) 'Le coffre a recu une valeur'
    Assert-NoMarker 'consentement absent'
}
Case 'Consentement : apres validation, exactement les usages choisis, compte local lie a son poste' {
    Assert (Save-DomeniaSecondaryVault -Scope Remote -Credential (New-MarkerCredential 'EXAMPLE\postes') -Remember) 'Usage poste non enregistre'
    Assert (($script:VaultWrites -join ',') -ceq (Target 'Remote' 'EXAMPLE\postes')) 'Usage poste mal cible'
    $script:VaultWrites.Clear()
    Assert (Save-DomeniaSecondaryVault -Scope Secrets -Credential (New-MarkerCredential 'EXAMPLE\secrets') -Remember) 'Usages secrets non enregistres'
    Assert (($script:VaultWrites -join ',') -ceq ((Target 'Laps' 'EXAMPLE\secrets')+','+(Target 'BitLocker' 'EXAMPLE\secrets'))) 'Usages LAPS et BitLocker mal cibles'
    $script:VaultWrites.Clear()
    Assert (Save-DomeniaSecondaryVault -Scope Remote -Credential (New-MarkerCredential 'PC-01\admin') -Target 'PC-01' -Remember) 'Compte local non enregistre'
    Assert (($script:VaultWrites -join ',') -ceq (Target 'RemoteLocal:pc-01' 'PC-01\admin')) 'Compte local non lie a son poste'
    Assert-NoMarker 'enregistrement'
}
Case 'Utilisation ciblee : un seul usage lu, une seule validation, secret transmis sans champ texte' {
    Add-MemoryEntry 'Remote' 'EXAMPLE\postes';Add-MemoryEntry 'Laps' 'EXAMPLE\postes'
    $script:Controls.TxtAccountRemoteUser.Text='EXAMPLE\postes'
    Invoke-DomeniaSecondaryVaultLogin -Scope Remote
    Assert (($script:VaultReads -join ',') -ceq (Target 'Remote' 'EXAMPLE\postes')) ('Lectures : '+$script:VaultReads.Count)
    Assert ($script:Validations.Count -eq 1 -and $script:Validations[0].Scope -eq 'Remote' -and $script:Validations[0].User -ceq 'EXAMPLE\postes') 'Validation absente ou multiple'
    Assert (Test-SecretIsMarker $script:Validations[0].Secret) 'Secret transmis altere'
    Assert-NoMarker 'utilisation'
    $script:Controls.TxtAccountSecretsUser.Text='EXAMPLE\absent'
    Invoke-DomeniaSecondaryVaultLogin -Scope Secrets
    Assert ($script:Validations.Count -eq 1) 'Validation lancee sans valeur memorisee'
    Assert (@($script:VaultReads).Count -eq 2 -and $script:VaultReads[1] -ceq (Target 'Laps' 'EXAMPLE\absent')) 'Lecture d un autre usage'
    Assert (@($script:Messages|Where-Object{$_ -match 'Aucun mot de passe memorise'}).Count -eq 1) 'Absence non expliquee'
}
Case 'Oubli cible : seul l identifiant affiche et ses usages, les autres comptes restent' {
    Add-MemoryEntry 'Laps' 'EXAMPLE\secrets';Add-MemoryEntry 'BitLocker' 'EXAMPLE\secrets';Add-MemoryEntry 'Remote' 'EXAMPLE\postes';Add-MemoryEntry 'Laps' 'EXAMPLE\autre'
    $script:Controls.TxtAccountSecretsUser.Text='EXAMPLE\secrets'
    Assert (Remove-DomeniaSecondaryVault -Scope Secrets) 'Oubli non confirme'
    Assert (($script:VaultDeletes -join ',') -ceq ((Target 'Laps' 'EXAMPLE\secrets')+','+(Target 'BitLocker' 'EXAMPLE\secrets'))) 'Oubli mal cible'
    Assert ($script:Vault.ContainsKey((Target 'Remote' 'EXAMPLE\postes')) -and $script:Vault.ContainsKey((Target 'Laps' 'EXAMPLE\autre'))) 'Un autre compte a ete oublie'
    Assert ($script:Vault.Count -eq 2) 'Valeur oubliee encore presente'
    Assert (-not [bool]$script:Controls.ChkAccountSecretsRemember.IsChecked) 'Choix de memorisation encore coche'
    Assert ($script:Validations.Count -eq 0) 'L oubli a lance une authentification'
}
Case 'Aucune valeur secrete dans le lot SQLite ni dans le journal, meme quand le coffre echoue' {
    $credential=New-MarkerCredential 'EXAMPLE\postes'
    Assert (Save-DomeniaSecondaryVault -Scope Remote -Credential $credential -Remember)
    Assert (Save-DomeniaAccountPreference -Scope Remote -UserName 'EXAMPLE\postes') 'Identifiant non memorise'
    Assert ($script:Submissions.Count -eq 1) 'Lot SQLite absent'
    Assert ([string]$script:Submissions[0].Batch.Json -match 'postes') 'Le lot ne porte pas l identifiant'
    Assert ([string]$script:Submissions[0].Batch.Json -notmatch '(?i)password|securestring|pscredential') 'Le lot porte un champ de mot de passe'
    $script:VaultWriteFails=$true
    Assert (-not (Save-DomeniaSecondaryVault -Scope Secrets -Credential (New-MarkerCredential 'EXAMPLE\secrets') -Remember)) 'Echec du coffre non signale'
    Assert (@($script:Messages|Where-Object{$_ -match '0/2'}).Count -eq 1) 'Etat partiel du coffre non annonce'
    Assert-NoMarker 'SQLite et journal'
}
Case 'Aucune valeur secrete dans un export, meme ecrite par erreur dans un champ' {
    # The rows of « En ce moment » (accounts in use, origin and state), plus a field filled by mistake.
    $rows=@((Get-DomeniaAccountsInUseRows -DirectoryAccount 'EXAMPLE\operateur' -DirectoryMode 'Explicit' -Machine (Get-DomeniaMachineAccountLabel -Source 'Remote' -Account 'EXAMPLE\postes') -Domain 'vault-qualification.invalid' -Netbios 'EXAMPLE').Now)
    $rows+=@([pscustomobject]@{Resource='Note';Account=('password='+$script:Marker);Origin='saisie';State='';'ms-Mcs-AdmPwd'=$script:Marker})
    $export=Protect-DomeniaExportRows -Rows $rows
    Assert (-not ((@($export.Rows)|ConvertTo-Json -Depth 4).Contains($script:Marker))) 'Valeur secrete exportee'
    Assert ([int]$export.Masked -eq 2) ('Valeurs masquees : '+[string]$export.Masked)
}
$nativeExecuted=$false
if($NativeWindows){
    Case 'Coffre Windows reel : enregistre apres consentement, relu pour une seule validation, oublie' {
        Assert ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'NativeWindows demande hors de Windows'
        Use-NativeVault
        $script:Domain='DC=vault-qualification-'+[guid]::NewGuid().ToString('N')+',DC=invalid';$script:Conn.BaseDn=$script:Domain
        $user='FIXTURE\vault-qualif'
        try{
            Assert ($null -eq (Get-DomeniaCredentialVaultCredential -DomainDn $script:Domain -Scope Remote -UserName $user -Enabled)) 'Entree de qualification deja presente'
            Assert (Save-DomeniaSecondaryVault -Scope Remote -Credential (New-MarkerCredential $user) -Remember) 'Ecriture native non confirmee'
            $script:Controls.TxtAccountRemoteUser.Text=$user
            Invoke-DomeniaSecondaryVaultLogin -Scope Remote
            Assert ($script:Validations.Count -eq 1 -and (Test-SecretIsMarker $script:Validations[0].Secret)) 'Valeur native relue alteree ou validation absente'
            Assert (Remove-DomeniaSecondaryVault -Scope Remote) 'Oubli natif non confirme'
            Assert ($null -eq (Get-DomeniaCredentialVaultCredential -DomainDn $script:Domain -Scope Remote -UserName $user -Enabled)) 'Valeur native encore presente apres oubli'
            Assert-NoMarker 'coffre natif'
            $script:nativeExecuted=$true
        }finally{
            try{[void](Remove-DomeniaCredentialVaultCredential -DomainDn $script:Domain -Scope Remote -UserName $user -Enabled)}catch{}
            $script:Domain='DC=vault-qualification,DC=invalid'
        }
    }
}
foreach($v in @($script:Validations)){try{$v.Secret.Dispose()}catch{}}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='VaultQualification';Point=43;Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;NativeWindowsRequested=[bool]$NativeWindows;NativeWindowsExecuted=$nativeExecuted;NetworkUsed=$false;PowerShell=[string]$PSVersionTable.PSVersion;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$report.Checks|Format-Table -Property Name,Passed,Error -Wrap|Out-String|Write-Output
if($failed){exit 1}
