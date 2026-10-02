# Per-resource credentials and user-approved recovery. No credentials are persisted.
$script:AccessState=$null
$script:AccessCurrentJob=$null
function Get-DomeniaAccessFailureKind {
    param($ErrorValue)
    $r=Get-DomeniaStructuredError $ErrorValue
    if($r.CanOfferCredential){return $r.Kind}
    return ''
}
function Get-DomeniaAccessScope {
    param([string]$OperationId)
    if($OperationId -eq 'UserComputerProbe'){return 'AD:UserComputerProbe'}
    if($OperationId -eq 'LiveSelectedPing'){return 'Presence'}
    if($OperationId -eq 'EmbeddedPathBrowse'){return 'LocalFile'}
    if($OperationId -in @('LiveDirectoryCheck','ScopeReconcile')){return 'AD:GlobalSearch'}
    if($OperationId -in @('ReadLaps','ReadBitLocker')){return $OperationId}
    if($OperationId -in @('SessionsList','LiveConsole','ComputerDiagnostics','ComputerLastUser','ComputerInventory','SoftwareInventory','WmiNamespaces','WmiClasses','WmiQuery','ComputerGpUpdate','ComputerRestart','RimotteRun','UserComputerProbe','BatchNetworkDiag','ParkSweep')){return 'Remote'}
    if($OperationId){return 'AD:'+ $OperationId}
    return 'Directory'
}
function Get-DomeniaRetryCredential {
    param([string]$OperationId)
    if($OperationId -in @('LiveSelectedPing','EmbeddedPathBrowse')){return $null}
    if($null -eq $script:AccessState){return $null}
    if($script:AccessState.Epoch -ne [long]$script:SessionEpoch -or $script:AccessState.BaseDn -ine [string]$script:Conn.BaseDn){return $null}
    $scope=Get-DomeniaAccessScope $(if($OperationId -in @('LiveDirectoryCheck','ScopeReconcile')){'GlobalSearch'}else{$OperationId})
    if($script:AccessState.Expires.ContainsKey($scope) -and $script:AccessState.Expires[$scope] -le [datetime]::UtcNow -and -not (Test-DomeniaAccessBusyWrite)){[void]$script:AccessState.Credentials.Remove($scope);[void]$script:AccessState.Expires.Remove($scope)}
    if($script:AccessState.Credentials.ContainsKey($scope)){return $script:AccessState.Credentials[$scope]}
    return $null
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
function Request-DomeniaAccessRecovery {
    param([string]$Operation,$ErrorValue,[string]$OperationId='',[string]$DN='',[switch]$Interactive,[switch]$Force,[switch]$IsWrite,[switch]$Possible,[string]$Target='')
    if($null -eq $script:AccessState -or $script:AccessState.Showing -or $script:AsyncEngineClosing){return $false}
    $kind=Get-DomeniaAccessFailureKind $ErrorValue
    if(-not $kind -and $Possible){$kind='Unconfirmed'}
    if(-not $kind){return $false}
    if($Operation.Length -gt 180){$Operation=$Operation.Substring(0,180)}
    $job=$script:AccessCurrentJob
    if($null -ne $job -and $null -ne $job.PSObject.Properties['SessionEpoch'] -and [long]$job.SessionEpoch -ne [long]$script:SessionEpoch){return $false}
    if(-not $OperationId -and $null -ne $job){$OperationId=[string]$job.OperationId}
    if($OperationId -in @('LiveSelectedPing','EmbeddedPathBrowse')){return $false}
    if($null -ne $job -and $job.OperationId -in @('ReadLaps','ReadBitLocker')){
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
    if($script:AccessState.Pending.Count -ge 16 -and -not $script:AccessState.Pending.ContainsKey($key)){$script:AccessState.Pending.Remove(@($script:AccessState.Pending.Keys)[0])}
    if(-not $Force -and $script:AccessState.Prompted.ContainsKey($key)){$record.Interactive=$false}
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
    param([string]$Scope,[string]$Operation,[string]$Target='')
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
    $connect={
        if($null -ne $state.Session){return}
        try{
            if(-not $ui.User.Text.Trim() -or $ui.Password.SecurePassword.Length -eq 0){$ui.Status.Text='Renseignez le compte et son mot de passe.';return}
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
        if(-not (Confirm-Action -Message $question -Title 'Autre compte')){return}
        if($Record.Scope -eq 'Directory'){
            Start-DomeniaAccountRelogin
            return
        }
        $target=''
        if($Record.OperationId -eq 'LiveConsole'){
            $candidateTarget=[string]$Record.Target
            if($candidateTarget.Length -le 253 -and $candidateTarget -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'){$target=$candidateTarget}
        }elseif($Record.DN -ieq [string]$script:SelectedObject.DN){$target=Get-DomeniaSelectedMachineName}
        $credential=Show-DomeniaAlternateCredential -Scope $Record.Scope -Operation $Record.Operation -Target $target
        if($null -eq $credential){return}
        if($Record.Epoch -ne [long]$script:SessionEpoch -or (Test-DomeniaAccessBusyWrite)){return}
        $credentialKey=$Record.Scope
        if($Record.Scope -eq 'Remote' -and $target -and $credential.UserName.Contains('\') -and $credential.UserName.Split('\',2)[0] -ieq $target.Split('.')[0]){$credentialKey='RemoteLocal|'+$target.Split('.')[0].ToUpperInvariant()}
        $script:AccessState.Credentials[$credentialKey]=$credential
        $script:AccessState.Expires[$credentialKey]=[datetime]::UtcNow.AddMinutes(30)
        foreach($pendingKey in @($script:AccessState.Pending.Keys)){if($script:AccessState.Pending[$pendingKey].Scope -eq $Record.Scope){[void]$script:AccessState.Pending.Remove($pendingKey)}}
        [void]$script:AccessState.Faults.Remove($Record.Scope)
        foreach($k in @($script:AccessState.Denied.Keys)){
            if(($Record.Scope -eq 'ReadLaps' -and $k.StartsWith('laps|')) -or ($Record.Scope -eq 'ReadBitLocker' -and $k.StartsWith('bitlocker|'))){[void]$script:AccessState.Denied.Remove($k)}
        }
        if($Record.DN -and $Record.Scope.StartsWith('AD:')){Clear-DomeniaActualCapabilityDenials -Dn $Record.DN}
        if($Record.Scope -eq 'Remote' -and $null -ne $script:Live){$script:Live.RemoteFaulted=$false}
        Update-DomeniaSecretActionUi;Apply-CurrentPermissionUi
        Write-AppLog ('Autre compte valide pour '+$Record.Scope+' : '+$credential.UserName+'. Aucun secret persiste.') 'INFO'
        if($Record.OperationId -in @('ReadLaps','ReadBitLocker') -and $null -ne $script:SelectedObject -and $Record.DN -ieq [string]$script:SelectedObject.DN -and $Record.Generation -eq [long]$script:SelectedObjectGeneration){
            $mode=if($Record.OperationId -eq 'ReadLaps'){'LAPS'}else{'BitLocker'}
            Start-LoadComputerSecrets -Mode $mode -RetryAttempt 1
        }else{Set-Status 'Compte valide et memorise pour cette ressource. Relancez volontairement l action ; ses controles et confirmations restent obligatoires.'}
    }finally{$script:AccessState.Showing=$false;Update-DomeniaAccessButton}
}
function Initialize-DomeniaAccess {
    if($null -ne $script:AccessState){return}
    $script:AccessState=[pscustomobject]@{Credentials=@{};Expires=@{};Faults=@{};Denied=@{};Pending=@{};Prompted=@{};Showing=$false;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;AuthSession=$null;Timer=$null}
    $b=Get-DomeniaControl 'BtnAccessRecovery'
    if($null -ne $b){$b.Add_Click({
        $record=@($script:AccessState.Pending.Values|Sort-Object At|Select-Object -First 1)
        if($record.Count){Invoke-DomeniaAccessRecovery $record[0]}
        else{
            $names=@($script:AccessState.Credentials.Keys|Sort-Object|ForEach-Object{$_+' : '+$script:AccessState.Credentials[$_].UserName})
            $message=if($names.Count){($names -join "`r`n")+"`r`n`r`nOublier ces comptes temporaires ?"}else{'Aucun compte temporaire actif. Un refus proposera un autre compte.'}
            if($names.Count -and (Confirm-Action -Message $message -Title 'Comptes temporaires')){
                if(Test-DomeniaAccessBusyWrite){Show-InfoBox 'Verification d ecriture requise avant de changer les comptes.';return}
                $script:AccessState.Credentials=@{};$script:AccessState.Expires=@{};$script:AccessState.Denied=@{};$script:AccessState.Faults=@{};$script:AccessState.Prompted=@{}
                Set-Status 'Comptes temporaires oublies. Les comptes configurés dans Comptes sont de nouveau utilisés.'
            }elseif(-not $names.Count){Show-InfoBox $message}
        }
    })}
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$timer.Interval=[timespan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if($null -eq $script:AccessState -or $script:AccessState.Showing -or $script:AsyncEngineClosing){return}
        if($script:AccessState.Epoch -ne [long]$script:SessionEpoch -or $script:AccessState.BaseDn -ine [string]$script:Conn.BaseDn){
            $script:AccessState.Credentials=@{};$script:AccessState.Expires=@{};$script:AccessState.Faults=@{};$script:AccessState.Denied=@{};$script:AccessState.Pending=@{};$script:AccessState.Prompted=@{}
            $script:AccessState.Epoch=[long]$script:SessionEpoch;$script:AccessState.BaseDn=[string]$script:Conn.BaseDn;Update-DomeniaAccessButton
        }
        if(-not (Test-DomeniaAccessBusyWrite)){
            foreach($key in @($script:AccessState.Expires.Keys)){
                if($script:AccessState.Expires[$key] -le [datetime]::UtcNow){
                    [void]$script:AccessState.Credentials.Remove($key);[void]$script:AccessState.Expires.Remove($key)
                    # Already-dispatched jobs own their copy. Never dispose a SecureString still in use.
                }
            }
        }
        if($null -ne $script:DomeniaSurfaceState -and -not $script:DomeniaSurfaceState.Done){return}
        if(-not (Test-DomeniaAccessBusyWrite) -and $script:Window.IsActive){
            $next=@($script:AccessState.Pending.Values|Where-Object{$_.Interactive}|Sort-Object At|Select-Object -First 1)
            if($next.Count){Invoke-DomeniaAccessRecovery $next[0]}
        }
    });$script:AccessState.Timer=$timer;$timer.Start()
    $script:Window.Add_Closed({
        if($null -ne $script:AccessState){$script:AccessState.Timer.Stop();if($null -ne $script:AccessState.AuthSession){Stop-DomeniaLoginAuthRunspace -Session $script:AccessState.AuthSession -Terminate};$script:AccessState.Credentials=@{};$script:AccessState.Pending=@{}}
    })
    Update-DomeniaAccessButton
}

function Inspect-DomeniaAccessResult {
    param($Job,$Output)
    if($null -eq $Job -or [string]$Job.OperationId -in @('ReadLaps','ReadBitLocker','LiveCache')){return}
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
