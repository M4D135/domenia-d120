# Per-resource credentials and user-approved recovery. No credentials are persisted.
$script:AccessState=$null
$script:AccessCurrentJob=$null
function Get-DomeniaAccessFailureKind {
    # D052: decision by native code first (Get-DomeniaErrorDecision), text last. The same code gives the same
    # answer in French and in English; a delay or a missing module never offers another account.
    # Vocabulary kept for the callers: 'LogonFailure', 'AccessDenied' or '' (nothing to offer).
    param($ErrorValue)
    $decision=Get-DomeniaErrorDecision -Structured (Get-DomeniaStructuredError $ErrorValue) -Text ([string]$ErrorValue)
    if($decision.Category -eq 'CredentialsRejected'){return 'LogonFailure'}
    if($decision.Category -in @('AccessDenied','DecryptionDenied')){return 'AccessDenied'}
    return ''
}
function Get-DomeniaAccessScope {
    param([string]$OperationId)
    if($OperationId -eq 'UserComputerProbe'){return 'AD:UserComputerProbe'}
    if($OperationId -eq 'LiveSelectedPing'){return 'Presence'}
    if($OperationId -eq 'EmbeddedPathBrowse'){return 'LocalFile'}
    if($OperationId -in @('LiveDirectoryCheck','ScopeReconcile')){return 'AD:GlobalSearch'}
    if($OperationId){
        # D051: LAPS and BitLocker keep their own account, whatever the operation that reads them
        # (ReadBitLockerList and ReadBitLockerKey share the BitLocker account and its refusals).
        $resource=Get-DomeniaOperationResource $OperationId
        if($resource -eq 'Laps'){return 'ReadLaps'}
        if($resource -eq 'BitLocker'){return 'ReadBitLocker'}
    }
    if($OperationId -in @('SessionsList','LiveConsole','ComputerDiagnostics','ComputerLastUser','ComputerInventory','SoftwareInventory','WmiNamespaces','WmiClasses','WmiQuery','ComputerGpUpdate','ComputerRestart','RimotteRun','UserComputerProbe','BatchNetworkDiag','ParkSweep')){return 'Remote'}
    if($OperationId){return 'AD:'+ $OperationId}
    return 'Directory'
}
function Get-DomeniaAccessNow {
    # Substitutable clock of the account leases (the wiring suite replaces it).
    return [datetime]::UtcNow
}
function Get-DomeniaAccessIdleMinutes {
    $minutes=30
    try{$minutes=[int](Get-CfgValue 'Security' 'AlternateCredentialIdleMinutes' 30)}catch{$minutes=30}
    return [Math]::Max(1,[Math]::Min(480,$minutes))
}
function Get-DomeniaRetryScopeKey {
    param([string]$OperationId)
    return (Get-DomeniaAccessScope $(if($OperationId -in @('LiveDirectoryCheck','ScopeReconcile')){'GlobalSearch'}else{$OperationId}))
}
function Test-DomeniaAccessLeaseUsable {
    # D054: a NEW use needs a live lease (inactivity measured from the last worker departure).
    param([string]$Key)
    if($null -eq $script:AccessState){return $false}
    $leases=Get-DomeniaMember $script:AccessState 'Leases' $null
    if($null -eq $leases -or -not $leases.ContainsKey($Key)){return $true}
    $check=Test-DomeniaCredentialLease -Lease $leases[$Key] -Epoch ([long]$script:SessionEpoch) -NowUtc (Get-DomeniaAccessNow) -ForNewCall $true
    return [bool]$check.Usable
}
function Use-DomeniaAccessLease {
    # Called only when a worker leaves with this account. A passive read by a timer never extends a lease.
    param([string]$Key)
    if($null -eq $script:AccessState){return}
    $leases=Get-DomeniaMember $script:AccessState 'Leases' $null
    if($null -ne $leases -and $leases.ContainsKey($Key)){[void](Use-DomeniaCredentialLease -Lease $leases[$Key] -NowUtc (Get-DomeniaAccessNow))}
}
function Remove-DomeniaAccessCredential {
    # Forget one temporary account. Jobs already dispatched own their copy: the SecureString is never disposed here.
    param([string]$Key)
    if($null -eq $script:AccessState){return}
    [void]$script:AccessState.Credentials.Remove($Key)
    $leases=Get-DomeniaMember $script:AccessState 'Leases' $null
    if($null -ne $leases -and $leases.ContainsKey($Key)){[void](Clear-DomeniaCredentialLease -Lease $leases[$Key]);[void]$leases.Remove($Key)}
}
function Get-DomeniaRetryCredential {
    param([string]$OperationId)
    if($OperationId -in @('LiveSelectedPing','EmbeddedPathBrowse')){return $null}
    if($null -eq $script:AccessState){return $null}
    if($script:AccessState.Epoch -ne [long]$script:SessionEpoch -or $script:AccessState.BaseDn -ine [string]$script:Conn.BaseDn){return $null}
    $scope=Get-DomeniaRetryScopeKey $OperationId
    if(-not $script:AccessState.Credentials.ContainsKey($scope)){return $null}
    # D054: an expired account is refused for any new use, also while a write is pending or uncertain.
    # The write already sent keeps its own copy and is never interrupted by this expiry.
    if(-not (Test-DomeniaAccessLeaseUsable -Key $scope)){Remove-DomeniaAccessCredential -Key $scope;return $null}
    return $script:AccessState.Credentials[$scope]
}
function Set-DomeniaRetryWorkerContext {
    param($Context,[string]$OperationId)
    $credential=Get-DomeniaRetryCredential $OperationId
    if($null -eq $credential){return $Context}
    if((Get-DomeniaAccessScope $OperationId) -eq 'Remote'){
        $Context.MachineCredential=$credential;$Context.RemoteAdminCredential=$credential;$Context.RemoteAdminUser=$credential.UserName
    }else{
        $Context.Credential=$credential;$Context.BindUser=$credential.UserName;$Context.UseCredential=$true;$Context.AuthMode='Explicit'
    }
    # The account leaves with a worker: this is the only use that extends its lease.
    Use-DomeniaAccessLease -Key (Get-DomeniaRetryScopeKey $OperationId)
    return $Context
}
function Test-DomeniaSecretDenied {
    param([string]$Mode,[string]$DN)
    if($null -eq $script:AccessState){return $false}
    return $script:AccessState.Denied.ContainsKey(($Mode+'|'+$DN).ToLowerInvariant())
}
function Set-DomeniaSecretDenied {
    param([string]$Mode,[string]$DN,[bool]$Denied=$true)
    if($null -eq $script:AccessState){return}
    $key=($Mode+'|'+$DN).ToLowerInvariant()
    if($Denied){$script:AccessState.Denied[$key]=$true}else{[void]$script:AccessState.Denied.Remove($key)}
}
function Test-DomeniaAccessBusyWrite {
    return ([bool]$script:ActiveWriteTaskId -or $script:WriteState -in @('Running','Unknown','UnknownPending'))
}
function Test-DomeniaSecretOperation {
    param([string]$OperationId)
    if(-not $OperationId){return $false}
    return ((Get-DomeniaOperationResource $OperationId) -in @('Laps','BitLocker'))
}
function ConvertTo-DomeniaAccessCategory {
    param([string]$Kind)
    if($Kind -eq 'LogonFailure'){return 'CredentialsRejected'}
    if($Kind -eq 'Unconfirmed'){return 'Unconfirmed'}
    return 'AccessDenied'
}
function Get-DomeniaAccessCoalescer {
    if($null -eq $script:AccessState){return $null}
    $coalescer=Get-DomeniaMember $script:AccessState 'Coalescer' $null
    if($null -eq $coalescer){
        $coalescer=New-DomeniaDenialCoalescer 60
        $script:AccessState|Add-Member -NotePropertyName Coalescer -NotePropertyValue $coalescer -Force
    }
    return $coalescer
}
function Add-DomeniaAccessDenialUi {
    # D053: twenty refusals for one resource give one request (Add-DomeniaAccessDenial).
    param([string]$Scope,[string]$Kind)
    $coalescer=Get-DomeniaAccessCoalescer
    if($null -eq $coalescer){return [pscustomobject]@{Prompt=$true;Count=1;Scope=$Scope;Reason=''}}
    # A request dropped without being shown (session change) must not mute its resource for good.
    if($coalescer.Entries.ContainsKey($Scope) -and [string]$coalescer.Entries[$Scope].State -eq 'Open' -and -not $script:AccessState.Showing){
        $waiting=@($script:AccessState.Pending.Values|Where-Object{[string]$_.Scope -eq $Scope -and [bool]$_.Interactive}).Count
        if($waiting -eq 0){[void]$coalescer.Entries.Remove($Scope)}
    }
    return (Add-DomeniaAccessDenial -Coalescer $coalescer -Scope $Scope -Category (ConvertTo-DomeniaAccessCategory $Kind) -NowUtc (Get-DomeniaAccessNow))
}
function Complete-DomeniaAccessPromptUi {
    param([string]$Scope,[ValidateSet('Accepted','Cancelled')][string]$Outcome)
    $coalescer=Get-DomeniaAccessCoalescer
    if($null -eq $coalescer -or -not $Scope){return $null}
    return (Complete-DomeniaAccessPrompt -Coalescer $coalescer -Scope $Scope -Outcome $Outcome -NowUtc (Get-DomeniaAccessNow))
}
function Request-DomeniaAccessRecovery {
    param([string]$Operation,$ErrorValue,[string]$OperationId='',[string]$DN='',[switch]$Interactive,[switch]$Force,[switch]$IsWrite,[switch]$Possible,[string]$Target='')
    if($null -eq $script:AccessState -or $script:AccessState.Showing -or $script:AsyncEngineClosing){return $false}
    $kind=Get-DomeniaAccessFailureKind $ErrorValue
    # The suspended AD channel is the consequence of a rejected sign-in: it leads back to the main login.
    if(-not $kind -and [string]$ErrorValue -match '(?i)Canal Active Directory suspendu'){$kind='LogonFailure'}
    if(-not $kind -and $Possible){$kind='Unconfirmed'}
    if(-not $kind){return $false}
    if($Operation.Length -gt 180){$Operation=$Operation.Substring(0,180)}
    $job=$script:AccessCurrentJob
    if($null -ne $job -and $null -ne $job.PSObject.Properties['SessionEpoch'] -and [long]$job.SessionEpoch -ne [long]$script:SessionEpoch){return $false}
    if(-not $OperationId -and $null -ne $job){$OperationId=[string]$job.OperationId}
    if($OperationId -in @('LiveSelectedPing','EmbeddedPathBrowse')){return $false}
    if($null -ne $job -and (Test-DomeniaSecretOperation ([string]$job.OperationId))){
        if($null -ne $job.CallbackState -and [long]$job.CallbackState.Generation -ne [long]$script:SelectedObjectGeneration){return $false}
    }
    if($null -ne $job -and $job.OperationId -eq 'LiveConsole' -and $null -ne $script:Live){
        if($null -ne $job.CallbackState -and [string]$job.CallbackState.Identity -cne [string]$script:Live.Identity){return $false}
    }
    $resourceTarget=''
    if((Get-DomeniaAccessScope $OperationId) -eq 'Remote' -and $Target.Length -le 253 -and $Target -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'){$resourceTarget=$Target}
    if($null -ne $job -and $OperationId -eq 'LiveConsole'){
        # The selected result may differ from the last opened fiche.
        # Attribute a probe failure to its captured target, never to that fiche.
        if(-not $DN){$DN=[string]$job.CallbackState.Key}
        $candidateTarget=[string]$job.CallbackState.Computer
        if($candidateTarget.Length -le 253 -and $candidateTarget -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'){$resourceTarget=$candidateTarget}
    }
    if(-not $DN -and $null -ne $job){
        try{$DN=[string]$job.CallbackState.DN;if(-not $DN){$DN=[string]$job.CallbackState.TargetDn}}catch{}
    }
    if(-not $DN -and $OperationId -ne 'LiveConsole' -and $null -ne $script:SelectedObject){$DN=[string]$script:SelectedObject.DN}
    if($OperationId -in @('LiveConsole','LiveCache','LiveDirectoryCheck','ScopeReconcile','TreeChildren','PresenceScan','SelectedPresence','ParkSweep','IndexBuild')){$Interactive=$false}
    $scope=if([string]$ErrorValue -match '(?i)Canal Active Directory suspendu'){'Directory'}else{Get-DomeniaAccessScope $OperationId}
    $key=$scope+'|'+$DN
    $record=[pscustomobject]@{Key=$key;Scope=$scope;OperationId=$OperationId;Operation=$Operation;DN=$DN;Target=$resourceTarget;Kind=$kind;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;IsWrite=([bool]$IsWrite -or ($null -ne $job -and [bool]$job.IsWrite));Interactive=[bool]$Interactive;At=[datetime]::UtcNow}
    # One item per resource/target; no stored raw error, payload or credential.
    if($script:AccessState.Pending.Count -ge 16 -and -not $script:AccessState.Pending.ContainsKey($key)){
        # Bounded list: the oldest background notice goes first, the request waiting for the operator stays.
        $victim=@($script:AccessState.Pending.Values|Sort-Object @{Expression={[bool]$_.Interactive}},At|Select-Object -First 1)
        if($victim.Count){$script:AccessState.Pending.Remove([string]$victim[0].Key)}
    }
    if(-not $Force -and $script:AccessState.Prompted.ContainsKey($key)){$record.Interactive=$false}
    $alreadyInteractive=($script:AccessState.Pending.ContainsKey($key) -and [bool]$script:AccessState.Pending[$key].Interactive)
    if($record.Interactive -and -not $alreadyInteractive){
        # D053: one request per resource however many refusals arrive together. The others are listed in the
        # access badge and never interrupt the operator.
        $grouped=Add-DomeniaAccessDenialUi -Scope $scope -Kind $kind
        if(-not $grouped.Prompt -and -not $Force){$record.Interactive=$false}
    }
    if($script:AccessState.Pending.ContainsKey($key)){$record.Interactive=($record.Interactive -or [bool]$script:AccessState.Pending[$key].Interactive)}
    $script:AccessState.Pending[$key]=$record
    Update-DomeniaAccessButton
    return $true
}
function Update-DomeniaAccessButton {
    $b=Get-DomeniaControl 'BtnAccessRecovery'
    if($null -eq $b -or $null -eq $script:AccessState){return}
    $n=$script:AccessState.Pending.Count
    $counter=Get-DomeniaControl 'LblAccessRecoveryCount';$badge=Get-DomeniaControl 'BadgeAccessRecovery'
    $label=if($n -gt 99){'99+'}else{([long]$n).ToString([Globalization.CultureInfo]::InvariantCulture)}
    $visibility=if($n -gt 0){'Visible'}else{'Hidden'}
    if($null -ne $counter -and $counter.Text -cne $label){$counter.Text=$label}
    if($null -ne $badge -and [string]$badge.Visibility -ne $visibility){$badge.Visibility=$visibility}
    $help=if($n){"$n accès à revoir. Proposer un autre compte après un refus, sans rejouer une écriture."}else{'Comptes temporaires : consulter ou oublier les comptes en mémoire. Aucun accès en attente.'}
    if([string]$b.ToolTip -cne $help){$b.ToolTip=$help}
    [Windows.Automation.AutomationProperties]::SetHelpText($b,$help)
}
function Test-DomeniaAccessSessionCurrent {
    param([long]$Epoch,[string]$BaseDn)
    return ($Epoch -eq [long]$script:SessionEpoch -and $BaseDn -ieq [string]$script:Conn.BaseDn)
}
function Show-DomeniaAlternateCredential {
    param([string]$Scope,[string]$Operation,[string]$Target='',[string]$OperationId='')
    if($null -ne $script:AccessState.AuthSession){
        $previous=$script:AccessState.AuthSession
        if(-not $previous.AsyncResult.IsCompleted){Show-InfoBox 'Une validation precedente termine encore son appel Windows. Aucun nouvel essai envoye.';return $null}
        Stop-DomeniaLoginAuthRunspace -Session $previous -Terminate;$script:AccessState.AuthSession=$null
    }
    $x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="DOMENIA | Autre compte" Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
 Background="{DynamicResource DomeniaBootSurface}" Foreground="{DynamicResource DomeniaBootText}" FontFamily="Segoe UI" FontSize="13">
 <Window.Resources>
 <Style TargetType="TextBox" BasedOn="{StaticResource DomeniaBootTextBoxBase}"><Setter Property="MinHeight" Value="36"/><Setter Property="Padding" Value="9,7"/></Style>
 <Style TargetType="PasswordBox" BasedOn="{StaticResource DomeniaBootPasswordBoxBase}"><Setter Property="MinHeight" Value="36"/><Setter Property="Padding" Value="9,7"/></Style>
 <Style TargetType="Button" BasedOn="{StaticResource DomeniaBootButtonBase}"><Setter Property="MinHeight" Value="38"/><Setter Property="Padding" Value="14,7"/></Style>
 </Window.Resources>
 <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24">
 <TextBlock Text="Utiliser un autre compte" FontSize="21" FontWeight="SemiBold"/>
 <TextBlock x:Name="Purpose" Margin="0,8,0,16" TextWrapping="Wrap"/>
 <TextBlock Text="Compte de la ressource" Margin="0,0,0,5"/>
 <TextBox x:Name="User" MaxLength="256" ToolTip="DOMAINE\compte ou compte@domaine. Compte AD, ou MACHINE\compte local pour le poste choisi."/>
 <TextBlock Text="Mot de passe" Margin="0,12,0,5"/>
 <PasswordBox x:Name="Password" ToolTip="Ni journalise ni enregistre sur disque. Le compte actuel reste conserve en cas d annulation."/>
 <TextBlock x:Name="Status" Margin="0,12,0,12" TextWrapping="Wrap"/>
 <ProgressBar x:Name="Progress" Height="4" IsIndeterminate="True" Visibility="Hidden" Margin="0,0,0,12"/>
 <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
 <Button x:Name="Cancel" Content="Annuler" IsCancel="True" ToolTip="Fermer sans remplacer le compte actif."/>
 <Button x:Name="Connect" Grid.Column="2" Content="Valider ce compte" IsDefault="True" ToolTip="Un seul essai de validation : AD pour l annuaire, CIM/DCOM sur la machine pour un compte poste. Cela ne certifie pas tous les autres droits."/>
 </Grid></StackPanel></ScrollViewer>
</Window>
'@
    $x=Convert-DomeniaXamlToBootTheme -Xaml $x -Theme $script:CurrentTheme
    $w=ConvertFrom-DomeniaXaml -XamlText $x -Context 'Autre compte'
    $w.Owner=$script:Window;$w.MaxHeight=[Math]::Max(320,[System.Windows.SystemParameters]::WorkArea.Height-48)
    $ui=@{};foreach($n in @('User','Password','Purpose','Status','Progress','Cancel','Connect')){$ui[$n]=$w.FindName($n)}
    $ui.Purpose.Text="$Operation`r`nPortee : $Scope. Usage en memoire pour cette session uniquement."
    $ui.Status.Text='La validation de l identite ne garantit pas ses droits sur la ressource.'
    $state=[pscustomobject]@{Session=$null;Started=[datetime]::MinValue;Credential=$null;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;Done=$false}
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(120)
    $access=$script:AccessState
    $remoteValidation=($Scope -eq 'Remote' -and -not [string]::IsNullOrWhiteSpace($Target))
    # D051: context per resource AND target, checked before any validation call. The rule is captured as a
    # script block so that the closure below does not depend on function lookup from its own module scope.
    $credentialScope='';if($OperationId){$credentialScope=Get-DomeniaCredentialScope -OperationId $OperationId -Target $Target}
    $credentialCheck=${function:Test-DomeniaCredentialContext}
    $knownDomains=@(@([string]$script:Conn.Netbios,[string]$script:Conn.Domain)|Where-Object{$_})
    $connect={
        if($null -ne $state.Session){return}
        try{
            if(-not $ui.User.Text.Trim() -or $ui.Password.SecurePassword.Length -eq 0){$ui.Status.Text='Renseignez le compte et son mot de passe.';return}
            if($credentialScope){
                $contextCheck=& $credentialCheck -Scope $credentialScope -UserName $ui.User.Text.Trim() -Target $Target -KnownDomains $knownDomains
                if(-not [bool]$contextCheck.Valid){$ui.Status.Text=[string]$contextCheck.Reason+' Aucun essai envoye.';return}
            }
            if($remoteValidation){$state.Session=Start-DomeniaRemoteCredentialSession -User $ui.User.Text.Trim() -Password $ui.Password.SecurePassword -Computer $Target}
            else {
            $request=New-DomeniaAccountAuthRequest -UserName $ui.User.Text.Trim() -Password $ui.Password.SecurePassword -TimeoutSeconds 12
            $state.Session=Start-DomeniaLoginAuthRunspace -Request $request
            }
            $state.Started=[datetime]::UtcNow
            $access.AuthSession=$state.Session
            $ui.Connect.IsEnabled=$false;$ui.User.IsEnabled=$false;$ui.Password.IsEnabled=$false;$ui.Progress.Visibility='Visible'
            $ui.Status.Text='Validation en cours...';$timer.Start()
        }catch{$ui.Status.Text=$_.Exception.Message}
    }.GetNewClosure()
    $tick={
        if($null -eq $state.Session){return}
        try{
            if(-not $state.Session.AsyncResult.IsCompleted){
                if(([datetime]::UtcNow-$state.Started).TotalSeconds -lt 14){return}
                $timer.Stop();Stop-DomeniaLoginAuthRunspace -Session $state.Session -Terminate
                $ui.Progress.Visibility='Hidden';$ui.Status.Text='Delai depasse. Aucun compte remplace. Fermez ce panneau et attendez le nettoyage avant un nouvel essai.';return
            }
            $timer.Stop();$r=Read-DomeniaAuthRunspaceResult -Session $state.Session
            if(-not (Test-DomeniaAccessSessionCurrent -Epoch $state.Epoch -BaseDn $state.BaseDn)){throw 'La session a change. Aucun compte remplace.'}
            if($null -eq $r -or -not $r.Success){throw ('Validation refusee : '+[string]$r.Error)}
            if(($r.AuthMode -ne $(if($remoteValidation){'Remote'}else{'Explicit'})) -or -not [string]$r.BindUser -or [string]$r.BaseDn -ine $state.BaseDn){throw 'Contexte AD non confirme. Aucun compte remplace.'}
            $secure=$ui.Password.SecurePassword.Copy();$secure.MakeReadOnly()
            $state.Credential=[Management.Automation.PSCredential]::new([string]$r.BindUser,$secure)
            $state.Done=$true;Set-DomeniaSurfaceResult $w $true
        }catch{$ui.Status.Text=$_.Exception.Message;$ui.Connect.IsEnabled=$true;$ui.User.IsEnabled=$true;$ui.Password.IsEnabled=$true}
        finally{
            if($null -ne $state.Session -and $state.Session.AsyncResult.IsCompleted){Stop-DomeniaLoginAuthRunspace -Session $state.Session -Terminate;$access.AuthSession=$null;$state.Session=$null}
            if($null -eq $state.Session -or $state.Session.AsyncResult.IsCompleted){$ui.Progress.Visibility='Hidden'}
        }
    }.GetNewClosure()
    $ui.Connect.Add_Click($connect);$timer.Add_Tick($tick)
    Register-DomeniaSurfaceReady $w ({$ui.User.Focus()}.GetNewClosure())
    try{[void](Show-DomeniaEmbeddedWindow -Window $w);return $state.Credential}
    finally{
        $timer.Stop();$ui.Password.Clear()
        if($null -ne $state.Session){Stop-DomeniaLoginAuthRunspace -Session $state.Session -Terminate}
    }
}
function Invoke-DomeniaAccessRecovery {
    param($Record)
    if($null -eq $Record -or $null -eq $script:AccessState -or $script:AccessState.Showing){return}
    if($null -ne $script:DomeniaSurfaceState -and -not $script:DomeniaSurfaceState.Done){return}
    if($Record.Epoch -ne [long]$script:SessionEpoch){return}
    if(Test-DomeniaAccessBusyWrite){Show-InfoBox 'Une ecriture reste active ou a verifier. Le compte ne peut pas etre change avant sa verification.';return}
    $script:AccessState.Showing=$true
    try{
        [void]$script:AccessState.Pending.Remove($Record.Key);$script:AccessState.Prompted[$Record.Key]=$true
        $failure=if($Record.Kind -eq 'Unconfirmed'){'aucune valeur visible, publication ou droits a verifier'}else{'identifiants ou droits refuses'}
        $question="$($Record.Operation) : $failure.`r`n`r`nUtiliser un autre compte ?`r`nLes autres fonctions restent disponibles. Aucune ecriture ne sera rejouee."
        if(-not (Confirm-Action -Message $question -Title 'Autre compte')){
            # D053: cancelling keeps the previous account and freezes new requests for this resource for a while.
            [void](Complete-DomeniaAccessPromptUi -Scope ([string]$Record.Scope) -Outcome Cancelled)
            return
        }
        if($Record.Scope -eq 'Directory'){
            [void](Complete-DomeniaAccessPromptUi -Scope ([string]$Record.Scope) -Outcome Accepted)
            Start-DomeniaAccountRelogin
            return
        }
        $target=''
        if($Record.OperationId -eq 'LiveConsole'){
            $candidateTarget=[string]$Record.Target
            if($candidateTarget.Length -le 253 -and $candidateTarget -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'){$target=$candidateTarget}
        }elseif($Record.DN -ieq [string]$script:SelectedObject.DN){$target=Get-DomeniaSelectedMachineName}
        $credential=Show-DomeniaAlternateCredential -Scope $Record.Scope -Operation $Record.Operation -Target $target -OperationId ([string]$Record.OperationId)
        if($null -eq $credential){[void](Complete-DomeniaAccessPromptUi -Scope ([string]$Record.Scope) -Outcome Cancelled);return}
        if($Record.Epoch -ne [long]$script:SessionEpoch -or (Test-DomeniaAccessBusyWrite)){return}
        if($Record.OperationId){
            # D051: an account is kept only for the resource and the target it belongs to.
            $knownDomains=@(@([string]$script:Conn.Netbios,[string]$script:Conn.Domain)|Where-Object{$_})
            $context=Test-DomeniaCredentialContext -Scope (Get-DomeniaCredentialScope -OperationId ([string]$Record.OperationId) -Target $target) -UserName ([string]$credential.UserName) -Target $target -KnownDomains $knownDomains
            if(-not [bool]$context.Valid){
                [void](Complete-DomeniaAccessPromptUi -Scope ([string]$Record.Scope) -Outcome Cancelled)
                Set-Status ([string]$context.Reason+' Compte non memorise ; le compte precedent reste utilise.') 'WARN'
                return
            }
        }
        $credentialKey=$Record.Scope
        if($Record.Scope -eq 'Remote' -and $target -and (Test-DomeniaLocalAccountName -UserName ([string]$credential.UserName) -Target $target)){$credentialKey='RemoteLocal|'+(ConvertTo-DomeniaMachineKey $target).ToUpperInvariant()}
        $script:AccessState.Credentials[$credentialKey]=$credential
        # D054: sliding inactivity lease, measured from the last worker departure, and bound to this session.
        $leases=Get-DomeniaMember $script:AccessState 'Leases' $null
        if($null -eq $leases){$leases=@{};$script:AccessState|Add-Member -NotePropertyName Leases -NotePropertyValue $leases -Force}
        $leases[$credentialKey]=New-DomeniaCredentialLease -Scope $credentialKey -Account ([string]$credential.UserName) -Mode Inactivity -InactivityMinutes (Get-DomeniaAccessIdleMinutes) -Epoch ([long]$script:SessionEpoch) -NowUtc (Get-DomeniaAccessNow)
        foreach($pendingKey in @($script:AccessState.Pending.Keys)){if($script:AccessState.Pending[$pendingKey].Scope -eq $Record.Scope){[void]$script:AccessState.Pending.Remove($pendingKey)}}
        [void]$script:AccessState.Faults.Remove($Record.Scope)
        foreach($k in @($script:AccessState.Denied.Keys)){
            if(($Record.Scope -eq 'ReadLaps' -and $k.StartsWith('laps|')) -or ($Record.Scope -eq 'ReadBitLocker' -and $k.StartsWith('bitlocker|'))){[void]$script:AccessState.Denied.Remove($k)}
        }
        if($Record.DN -and $Record.Scope.StartsWith('AD:')){Clear-DomeniaActualCapabilityDenials -Dn $Record.DN}
        if($Record.Scope -eq 'Remote' -and $null -ne $script:Live){$script:Live.RemoteFaulted=$false}
        [void](Complete-DomeniaAccessPromptUi -Scope ([string]$Record.Scope) -Outcome Accepted)
        Update-DomeniaSecretActionUi;Apply-CurrentPermissionUi
        Write-AppLog ('Autre compte valide pour '+$Record.Scope+' : '+$credential.UserName+'. Aucun secret persiste.') 'INFO'
        # One read may be replayed once after acceptance (Get-DomeniaReauthPlan). A write never is.
        $plan=Get-DomeniaReauthPlan -Category (ConvertTo-DomeniaAccessCategory ([string]$Record.Kind)) -IsWrite ([bool]$Record.IsWrite) -Attempt 0
        if($plan.RetryOnce -and $Record.Scope -in @('ReadLaps','ReadBitLocker') -and $null -ne $script:SelectedObject -and $Record.DN -ieq [string]$script:SelectedObject.DN -and $Record.Generation -eq [long]$script:SelectedObjectGeneration){
            $mode=if($Record.Scope -eq 'ReadLaps'){'LAPS'}else{'BitLocker'}
            Start-LoadComputerSecrets -Mode $mode -RetryAttempt 1
        }else{Set-Status 'Compte valide et memorise pour cette ressource. Relancez volontairement l action ; ses controles et confirmations restent obligatoires.'}
    }finally{$script:AccessState.Showing=$false;Update-DomeniaAccessButton}
}
function Resolve-DomeniaCapabilityRoute {
    # D056: the routes named by Get-DomeniaCapabilityExplanation, resolved to real places of the main window.
    param([AllowEmptyString()][string]$Route)
    switch ($Route) {
        'WsSearch'           { return [pscustomobject]@{Route=$Route;Workspace='WsSearch';Inner='';Tab='';Focus='TxtGlobalSearch';Label='Rechercher'} }
        'TabAccounts'        { return [pscustomobject]@{Route=$Route;Workspace='TabAccounts';Inner='';Tab='';Focus='';Label='Comptes'} }
        'TabPermissions'     { return [pscustomobject]@{Route=$Route;Workspace='WsObject';Inner='DetailTabs';Tab='TabPermissions';Focus='';Label='Fiche > Permissions'} }
        'TabGuard'           { return [pscustomobject]@{Route=$Route;Workspace='TabApplicationTools';Inner='ApplicationToolTabs';Tab='TabGuard';Focus='';Label='Outils > Fiabilite'} }
        'ChkReadOnlyMode'    { return [pscustomobject]@{Route=$Route;Workspace='';Inner='';Tab='';Focus='ChkReadOnlyMode';Label='Protection lecture seule'} }
        'BtnObjectReadRetry' { return [pscustomobject]@{Route=$Route;Workspace='WsObject';Inner='';Tab='';Focus='BtnObjectReadRetry';Label='Fiche > Relire'} }
    }
    return $null
}
function Invoke-DomeniaCapabilityRoute {
    # Navigation only: no right, setting or protection is changed, nothing is read or written.
    param([AllowEmptyString()][string]$Route)
    $target=Resolve-DomeniaCapabilityRoute -Route $Route
    if($null -eq $target){return $false}
    if($target.Workspace){Select-DomeniaWorkspace -Workspace $target.Workspace -Inner $target.Inner -Tab $target.Tab}
    if($target.Focus){$control=Get-DomeniaControl $target.Focus;if($null -ne $control){try{[void]$control.Focus()}catch{}}}
    return $true
}
function Get-DomeniaControlCapabilityExplanation {
    # D056: why a write control is greyed, with the same session facts as Apply-CurrentPermissionUi, and a safe
    # route when one exists. A protection chosen by configuration has no route: it is stated as such.
    param([Parameter(Mandatory=$true)][string]$Name)
    $control=Get-DomeniaControl $Name
    $label=$Name
    try{$entry=Get-DomeniaUxHelpEntry -Control $control -Name $Name;if($null -ne $entry -and [string]$entry.Title){$label=[string]$entry.Title}}catch{}
    $readOnly=[bool]$script:ReadOnlyMode
    $writeActive=((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ($script:WriteState -in @('Unknown','UnknownPending')))
    $busy=$false;try{$busy=($script:ControlBusyRef.ContainsKey($Name) -and [int]$script:ControlBusyRef[$Name] -gt 0)}catch{}
    $capability='';$state='Indetermine'
    try{$map=Get-WriteControlMap;foreach($cap in @($map.Keys)){if(@($map[$cap]) -contains $Name){$capability=[string]$cap}}}catch{}
    $lookup=if($capability -eq 'Raw'){'Edit'}else{$capability}
    try{if($lookup -and $script:CurrentCapabilities.ContainsKey($lookup)){$state=[string]$script:CurrentCapabilities[$lookup]}}catch{}
    $currentDn='';try{$currentDn=[string]$script:SelectedObject.DN}catch{}
    $actualDenied=$false;try{if($lookup){$actualDenied=[bool](Test-DomeniaActualCapabilityDenied -Dn $currentDn -Capability $lookup)}}catch{}
    $protected=$false;try{$protected=([string]$script:SelectedObject.Safety.AdminCount -eq '1') -or [bool]$script:SelectedObject.Safety.Critical}catch{}
    if($null -eq $script:SelectedObject -and $capability){return (Get-DomeniaCapabilityExplanation -Action $label -State NoSelection)}
    if($readOnly){return (Get-DomeniaCapabilityExplanation -Action $label -State ReadOnly)}
    if($writeActive){return (Get-DomeniaCapabilityExplanation -Action $label -State Busy)}
    if($busy){return [pscustomobject]@{Action=$label;State='Busy';Text=($label+' : action en cours.');Definitive=$false;Route=''}}
    if([bool]$script:ShowingCachedObject){return (Get-DomeniaCapabilityExplanation -Action $label -State Stale)}
    if($protected -and $capability -in @('Edit','Raw','Account','Password','Group','Move','Delete')){return [pscustomobject]@{Action=$label;State='Refused';Text=($label+' : objet protege (adminCount ou objet critique), ecriture bloquee par la configuration de securite. Protection voulue : aucune route.');Definitive=$true;Route=''}}
    if($capability -eq 'Raw' -and -not [bool](Get-CfgValue 'Security' 'AllowRawAttributeWrite' $false)){return [pscustomobject]@{Action=$label;State='Refused';Text=($label+' : ecriture brute desactivee par la configuration de securite. Protection voulue : aucune route.');Definitive=$true;Route=''}}
    if($actualDenied){return (Get-DomeniaCapabilityExplanation -Action $label -State Refused -Detail 'Refus reel du controleur de domaine pour l identite connectee.')}
    if($state -eq 'Refuse'){return (Get-DomeniaCapabilityExplanation -Action $label -State Estimated -Route 'TabPermissions')}
    return (Get-DomeniaCapabilityExplanation -Action $label -State Unknown)
}
function Get-DomeniaUnavailableReasonLines {
    # D056: one line per greyed control with its reason and a safe route; D055: identity of the secret reads;
    # D060: transports used and kept off. Session facts only: nothing is tested, read or changed.
    $lines=[Collections.Generic.List[string]]::new();$routes=[Collections.Generic.List[string]]::new()
    $add={param([string]$Text,[string]$Route)
        $target=$null;if($Route){$target=Resolve-DomeniaCapabilityRoute -Route $Route}
        if($null -ne $target){$lines.Add($Text+' Aller a : '+[string]$target.Label+'.');$routes.Add($Route)}else{$lines.Add($Text)}
    }
    if($script:ReadOnlyMode){& $add ((Get-DomeniaCapabilityExplanation -Action 'Modifications AD' -State ReadOnly).Text) 'ChkReadOnlyMode'}
    if(-not $script:ReceiptReady){& $add 'Les recus locaux ne sont pas encore confirmes. Les nouvelles ecritures sont bloquees.' 'TabGuard'}
    if($script:ReceiptPending -gt 0){& $add 'Une operation precedente reste a verifier. Consultez les recus, pas une relance automatique.' 'TabGuard'}
    if($script:ActiveWriteTaskId){& $add ((Get-DomeniaCapabilityExplanation -Action 'Changement de contexte' -State Busy).Text) 'TabGuard'}
    if($null -eq $script:SelectedObject){& $add ((Get-DomeniaCapabilityExplanation -Action 'Actions de fiche' -State NoSelection).Text) 'WsSearch'}
    foreach($n in @('BtnLoadLaps','BtnLoadBitLocker')){
        $c=Get-DomeniaControl $n
        if($null -ne $c -and -not $c.IsEnabled){$x=Get-DomeniaSecretButtonExplanation -Name $n -Busy (Test-DomeniaControlIsBusy -Name $n);& $add ([string]$x.ToolTip) ([string]$x.Route)}
    }
    foreach($n in @('BtnUserSave','BtnCompRestart','BtnRawSet')){
        $c=Get-DomeniaControl $n
        if($null -ne $c -and -not $c.IsEnabled){$x=Get-DomeniaControlCapabilityExplanation -Name $n;& $add ([string]$x.Text) ([string]$x.Route)}
    }
    if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.Type -eq 'Machine'){
        foreach($mode in @('LAPS','BitLocker')){$need=Get-DomeniaSecretIdentityReason -Mode $mode;$lines.Add('Lecture '+$mode+' : '+[string]$need.Reason)}
    }
    if(-not $lines.Count){$lines.Add('Aucun blocage commun observe. Un droit specifique reste verifie par la ressource lors de l action ; consultez son infobulle ou son erreur native.')}
    $lines.Add('')
    $lines.Add('Transports (aucun reglage Windows modifie, aucun repli intrusif sans autorisation explicite) :')
    foreach($row in @(Get-DomeniaTransportPolicyRows)){$lines.Add('- '+[string]$row.Transport+' : '+[string]$row.Etat+'. '+[string]$row.Regle)}
    return [pscustomobject]@{Lines=$lines.ToArray();Routes=$routes.ToArray()}
}
function New-DomeniaAccessState {
    return [pscustomobject]@{Credentials=@{};Leases=@{};Coalescer=(New-DomeniaDenialCoalescer 60);Faults=@{};Denied=@{};Pending=@{};Prompted=@{};Showing=$false;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;AuthSession=$null;Timer=$null;PolicySignature=''}
}
function Clear-DomeniaAccessAccounts {
    # Oublier / new session: every temporary account and its lease are forgotten together.
    param([switch]$KeepPending)
    if($null -eq $script:AccessState){return}
    foreach($key in @($script:AccessState.Credentials.Keys)){Remove-DomeniaAccessCredential -Key ([string]$key)}
    $script:AccessState.Credentials=@{}
    $script:AccessState|Add-Member -NotePropertyName Leases -NotePropertyValue @{} -Force
    $script:AccessState|Add-Member -NotePropertyName Coalescer -NotePropertyValue (New-DomeniaDenialCoalescer 60) -Force
    $script:AccessState.Denied=@{};$script:AccessState.Faults=@{};$script:AccessState.Prompted=@{}
    if(-not $KeepPending){$script:AccessState.Pending=@{}}
}
function Invoke-DomeniaAccessLeaseSweep {
    # D054: expiry is applied even while a write is active or uncertain. Only NEW uses are refused: a job already
    # dispatched owns its copy of the account, and a SecureString still in use is never disposed.
    if($null -eq $script:AccessState){return 0}
    $removed=0
    foreach($key in @($script:AccessState.Credentials.Keys)){
        if(-not (Test-DomeniaAccessLeaseUsable -Key ([string]$key))){Remove-DomeniaAccessCredential -Key ([string]$key);$removed++}
    }
    return $removed
}
function Get-DomeniaTransportPolicyRows {
    # D060: what Domenia uses and what stays off, from the configuration and the current explicit consent.
    $consent=($null -ne $script:ArtifactConsent -and $script:ArtifactConsent.Epoch -eq $script:SessionEpoch -and $script:ArtifactConsent.Expires -gt [datetime]::UtcNow)
    return @(Get-DomeniaTransportPolicy -UseCim ([bool](Get-CfgValue 'Remote' 'UseCim' $true)) -UseWinRM ([bool](Get-CfgValue 'Remote' 'UseWinRM' $true)) -UsePsExecFallback ([bool](Get-CfgValue 'Remote' 'UsePsExecFallback' $true)) -UseTaskFallback ([bool](Get-CfgValue 'Remote' 'UseTaskFallback' $true)) -ArtifactConsent $consent)
}
function Update-DomeniaTransportPolicyView {
    param([switch]$Force)
    $grid=Get-DomeniaControl 'DgTransportPolicy'
    if($null -eq $grid){return $false}
    $rows=@(Get-DomeniaTransportPolicyRows)
    $signature=(@($rows|ForEach-Object{[string]$_.Transport+'='+[string]$_.Etat}) -join '|')
    $previous=[string](Get-DomeniaMember $script:AccessState 'PolicySignature' '')
    if(-not $Force -and $signature -ceq $previous -and $null -ne $grid.ItemsSource){return $false}
    [void](Set-DomeniaItemsSource -Name 'DgTransportPolicy' -Rows $rows)
    $target='';if($null -ne $script:ArtifactConsent -and $script:ArtifactConsent.Expires -gt [datetime]::UtcNow){$target=[string]$script:ArtifactConsent.Target}
    $note=if($target){'Autorisation explicite en cours pour '+$target+' (5 min au plus). Aucun autre poste n en beneficie.'}else{'Aucun transport intrusif sans autorisation explicite et ciblee (Outils > Fiabilite). Aucun reglage Windows n est modifie par Domenia.'}
    [void](Set-DomeniaControlText 'LblTransportPolicy' $note)
    if($null -ne $script:AccessState){$script:AccessState|Add-Member -NotePropertyName PolicySignature -NotePropertyValue $signature -Force}
    return $true
}
function Initialize-DomeniaAccess {
    if($null -ne $script:AccessState){return}
    $script:AccessState=New-DomeniaAccessState
    $b=Get-DomeniaControl 'BtnAccessRecovery'
    if($null -ne $b){$b.Add_Click({
        $record=@($script:AccessState.Pending.Values|Sort-Object At|Select-Object -First 1)
        if($record.Count){Invoke-DomeniaAccessRecovery $record[0]}
        else{
            [void](Invoke-DomeniaAccessLeaseSweep)
            $idle=Get-DomeniaAccessIdleMinutes
            $names=@($script:AccessState.Credentials.Keys|Sort-Object|ForEach-Object{$_+' : '+$script:AccessState.Credentials[$_].UserName})
            $message=if($names.Count){($names -join "`r`n")+"`r`n`r`nChaque compte est oublie apres $idle min sans utilisation, a la fin de la session ou a votre demande.`r`nOublier ces comptes temporaires ?"}else{'Aucun compte temporaire actif. Un refus proposera un autre compte.'}
            if($names.Count -and (Confirm-Action -Message $message -Title 'Comptes temporaires')){
                if(Test-DomeniaAccessBusyWrite){Show-InfoBox 'Verification d ecriture requise avant de changer les comptes.';return}
                Clear-DomeniaAccessAccounts -KeepPending
                Set-Status 'Comptes temporaires oublies. Les comptes configurés dans Comptes sont de nouveau utilisés.'
            }elseif(-not $names.Count){Show-InfoBox $message}
        }
    })}
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$timer.Interval=[timespan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if($null -eq $script:AccessState -or $script:AccessState.Showing -or $script:AsyncEngineClosing){return}
        if($script:AccessState.Epoch -ne [long]$script:SessionEpoch -or $script:AccessState.BaseDn -ine [string]$script:Conn.BaseDn){
            Clear-DomeniaAccessAccounts
            $script:AccessState.Epoch=[long]$script:SessionEpoch;$script:AccessState.BaseDn=[string]$script:Conn.BaseDn;Update-DomeniaAccessButton
        }
        [void](Invoke-DomeniaAccessLeaseSweep)
        try{$policy=Get-DomeniaControl 'DgTransportPolicy';if($null -ne $policy -and $policy.IsVisible){[void](Update-DomeniaTransportPolicyView)}}catch{}
        if($null -ne $script:DomeniaSurfaceState -and -not $script:DomeniaSurfaceState.Done){return}
        if(-not (Test-DomeniaAccessBusyWrite) -and $script:Window.IsActive){
            $next=@($script:AccessState.Pending.Values|Where-Object{$_.Interactive}|Sort-Object At|Select-Object -First 1)
            if($next.Count){Invoke-DomeniaAccessRecovery $next[0]}
        }
    });$script:AccessState.Timer=$timer;$timer.Start()
    $script:Window.Add_Closed({
        if($null -ne $script:AccessState){$script:AccessState.Timer.Stop();if($null -ne $script:AccessState.AuthSession){Stop-DomeniaLoginAuthRunspace -Session $script:AccessState.AuthSession -Terminate};Clear-DomeniaAccessAccounts}
    })
    try{[void](Update-DomeniaTransportPolicyView -Force)}catch{Write-AppLog ('Politique de transport : '+$_.Exception.Message) 'WARN'}
    # Secrets view (BitLocker key selection, single reveal, prerequisite route). Its failure never blocks access recovery.
    try{Initialize-DomeniaSecretsUi}catch{Write-AppLog ('Initialisation des secrets : '+$_.Exception.Message) 'WARN'}
    Update-DomeniaAccessButton
}

function Inspect-DomeniaAccessResult {
    param($Job,$Output)
    if($null -eq $Job -or [string]$Job.OperationId -eq 'LiveCache' -or (Test-DomeniaSecretOperation ([string]$Job.OperationId))){return}
    # Inspect only dedicated status/error fields, never data values or credentials.
    $records=[Collections.Generic.List[object]]::new()
    foreach($item in @($Output)){
        if($records.Count -ge 64){break};if($null -eq $item){continue};$records.Add($item)
        if($null -ne $item.PSObject.Properties['Rows']){foreach($row in @($item.Rows)){if($records.Count -ge 64){break};$records.Add($row)}}
    }
    foreach($r in $records){
        foreach($field in @('ErrorMessage','Error','Failure','Detail')){
            $p=$r.PSObject.Properties[$field]
            if($null -ne $p -and $p.Value -is [string] -and (Get-DomeniaAccessFailureKind $p.Value)){
                [void](Request-DomeniaAccessRecovery -Operation ([string]$Job.Name) -OperationId ([string]$Job.OperationId) -ErrorValue $p.Value)
                return
            }
        }
    }
}
