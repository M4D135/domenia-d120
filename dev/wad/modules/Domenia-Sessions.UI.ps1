function Get-DomeniaSessionsWorkerCode {
return @'
if($null -eq ('Domenia.Sessions.Reader' -as [type])){Add-Type -Path (Join-Path $Context.RootDir 'modules\Domenia-Sessions.Native.cs') -ErrorAction Stop}
$cred=Get-WMachineCredential $Context;$user=$null;$domain=$null;$password=$null
if($null -ne $cred){
    $qualified=[string]$cred.UserName
    if($qualified.Contains('\')){$parts=$qualified.Split('\',2);$domain=$parts[0];$user=$parts[1]}
    else{$user=$qualified;$domain=$null}
    $password=$cred.Password
}
$rows=[Domenia.Sessions.Reader]::Read([string]$Payload.Computer,$user,$domain,$password)
[pscustomobject]@{Rows=$rows;Computer=[string]$Payload.Computer;ObservedUtc=[datetime]::UtcNow.ToString('o');Source='WTS, lecture a la demande';Identity=$(if($cred){$cred.UserName}else{$Context.ProcessIdentity})}
'@
}
function Get-DomeniaSelectedMachineName {
    if($null -eq $script:SelectedObject -or $script:SelectedObject.Type -ne 'Machine'){return ''}
    $name=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'dNSHostName')
    if(-not $name){$name=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'name')}
    return $name
}
function Start-DomeniaSessionsRead {
    $name=Get-DomeniaSelectedMachineName
    if(-not $name){
        # UX-39 : la page le dit. Une fenetre modale pendant qu'on cherche un poste dans l'arbre vole le focus,
        # et elle revient a chaque clic rate sur un objet qui n'est pas une machine.
        [void](Set-DomeniaItemsSource 'DgSessions' @())
        [void](Set-DomeniaControlText 'LblSessionsState' 'Aucun poste choisi : sélectionnez une machine dans lʼarbre, puis « Lire les sessions ».')
        return
    }
    $state=New-DomeniaClassicCollectionState -Computer $name -ResultKind 'Sessions' -RequestKey 'WTS' -PublishHandler 'Complete-DomeniaSessionsRead' -PublishErrorHandler 'Fail-DomeniaSessionsRead'
    $state|Add-Member Epoch ([long]$script:SessionEpoch)
    $state|Add-Member Generation ([long]$script:SelectedObjectGeneration)
    Start-UiTask -Name ('Sessions '+$name) -OperationId 'SessionsList' -Code (Get-DomeniaSessionsWorkerCode) -Payload ([pscustomobject]@{Computer=$name}) -CallbackState $state -SuccessHandler 'Complete-DomeniaSessionsCollected' -ErrorHandler 'Fail-DomeniaSessionsCollected' -TimeoutSeconds 30 -ReplaceKey 'sessions-selected' -DisableControls @('BtnSessionsRead') | Out-Null
}
function Complete-DomeniaSessionsCollected {
    param($Result,$State)
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Computer')
        if($null -eq $r -or $null -eq $r.Rows -or [string]$r.Computer -ine [string]$State.Computer){throw 'Resultat WTS absent ou provenant d une autre cible.'}
        $at=ConvertTo-DomeniaStoreUtc ([string]$r.ObservedUtc)
        $rows=[Collections.Generic.List[object]]::new()
        foreach($row in @($r.Rows)){
            if($null -eq $row){throw 'Session WTS invalide.'}
            # Keep the explicit WTS presentation contract, never an arbitrary remote object graph.
            $safe=[ordered]@{}
            foreach($field in @('Id','Station','User','Domain','State','Protocol','Detail','LogonTicks','IdleTicks')){$safe[$field]=Get-DomeniaMemberValue $row $field}
            $rows.Add([pscustomobject]$safe)
        }
        $data=[pscustomobject]@{Rows=$rows.ToArray();Computer=[string]$State.Computer;ObservedUtc=$at;Source='WTS, lecture a la demande';Identity=[string]$r.Identity}
        [void](Submit-DomeniaRemoteDetail -Data $data -State $State -Succeeded $true -SourceCompletedUtc $at)
    }catch{Fail-DomeniaRemoteDetailStored -Message $_.Exception.Message -State $State}
}
function Fail-DomeniaSessionsCollected {
    param($Message,$State)
    $data=[pscustomobject]@{Computer=[string]$State.Computer;CollectionError=[string]$Message}
    try{[void](Submit-DomeniaRemoteDetail -Data $data -State $State -Succeeded $false -SourceCompletedUtc ([string]$State.RemoteStartedUtc) -ErrorText ([string]$Message))}
    catch{Fail-DomeniaRemoteDetailStored -Message $_.Exception.Message -State $State}
}
function Complete-DomeniaSessionsRead {
    param($Result,$State)
    if(-not (Test-DomeniaClassicResultCurrent -Result $Result -State $State)){return}
    if($State.Epoch -ne $script:SessionEpoch -or $State.Generation -ne $script:SelectedObjectGeneration -or $State.DN -ine [string]$script:SelectedObject.DN){return}
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Computer')
    if($null -eq $r){throw 'Resultat WTS absent.'}
    # UX-39 : la vue de D072 est celle qui remplit la page. Elle masquait deja les lignes sans compte,
    # comptait les sessions systeme et rendait l'heure locale ; rien n'etait branche. La grille recevait
    # les lignes brutes du poste et l'etat son horodatage ISO.
    $view=ConvertTo-DomeniaSessionView $r
    [void](Set-DomeniaItemsSource 'DgSessions' @($view.Rows))
    $texte=[string]$view.StatusText
    # Page vide : EmptyText passe devant, car c'est lui qui dit ce que l'absence veut dire. L'etat reste
    # derriere avec les lignes masquees — sans lui, un poste qui rend deux sessions sans compte se lit
    # comme un poste sans activite, ce qui est exactement le mensonge que D072 devait empecher.
    if(@($view.Rows).Count -eq 0 -and [string]$view.EmptyText){$texte=(([string]$view.EmptyText+' '+$texte).Trim())}
    [void](Set-DomeniaControlText 'LblSessionsState' $texte)
}
function Fail-DomeniaSessionsRead {
    param($Message,$State)
    if(-not (Test-DomeniaClassicResultCurrent -Result $null -State $State -ContextOnly)){return}
    if($State.Epoch -ne $script:SessionEpoch -or $State.Generation -ne $script:SelectedObjectGeneration){return}
    [void](Set-DomeniaControlText 'LblSessionsState' 'Lecture non confirmee : absence de resultat ne signifie pas absence de sessions.')
    [void](Request-DomeniaAccessRecovery -Operation 'Lecture des sessions' -OperationId 'SessionsList' -ErrorValue $Message -DN $State.DN -Interactive)
    Write-AppLog ('WTS : '+[string]$Message) 'WARN'
}
function Open-DomeniaSessionFiche {
    # UX-39 : double-clic sur une ligne de session : la fiche de l'utilisateur, comme sur les associations
    # (FO-14). Le compte est cherche par sAMAccountName : la session ne donne pas de DN, et un compte local
    # du poste n'a pas de fiche dans l'annuaire — la recherche le dira.
    param($Source)
    $hit=Get-DomeniaGridHit $Source
    if($null -eq $hit -or $null -eq $hit.Row -or $null -eq $hit.Row.Item){return}
    $user=Get-DomeniaSessionAccountName -Row $hit.Row.Item
    if(-not $user){Set-Status 'Aucun compte sur cette ligne : services, écran de connexion et écouteur RDP nʼont pas de fiche.' 'INFO';return}
    Start-OpenLinkedObject -Type 'Utilisateur' -Identity $user
}
function New-DomeniaSessionsContextMenu {
    # UX-39 : le meme geste au clic droit, pour celui qui ne devine pas le double-clic.
    $menu=New-Object System.Windows.Controls.ContextMenu
    $item=New-Object System.Windows.Controls.MenuItem
    $item.Header='Ouvrir la fiche du compte'
    $item.Add_Click({param($sender,$e) $grid=Get-DomeniaControl 'DgSessions';if($null -ne $grid -and $null -ne $grid.SelectedItem){$user=Get-DomeniaSessionAccountName -Row $grid.SelectedItem;if($user){Start-OpenLinkedObject -Type 'Utilisateur' -Identity $user}}})
    [void]$menu.Items.Add($item)
    $menu.Add_Opened({param($sender,$e) $grid=Get-DomeniaControl 'DgSessions';$has=($null -ne $grid -and $null -ne $grid.SelectedItem -and [bool](Get-DomeniaSessionAccountName -Row $grid.SelectedItem));foreach($i in @($sender.Items)){$i.IsEnabled=$has}})
    return $menu
}
function Get-DomeniaRemoteCredentialCheckCode {
return @'
$session=$null
try{
    $session=New-CimSession -ComputerName ([string]$Payload.Computer) -Credential $Payload.Credential -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 5 -ErrorAction Stop
    $result=Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -Property Name -OperationTimeoutSec 5 -ErrorAction Stop
    if($null -eq $result){throw 'Aucune reponse du poste.'}
    [pscustomobject]@{Success=$true;AuthMode='Remote';BindUser=[string]$Payload.Credential.UserName;BaseDn=[string]$Context.BaseDn;Computer=[string]$Payload.Computer;Error=''}
}catch{[pscustomobject]@{Success=$false;AuthMode='Remote';BindUser='';BaseDn=[string]$Context.BaseDn;Error=$_.Exception.Message;Code=$_.Exception.HResult}}
finally{if($null -ne $session){Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue}}
'@
}
function Start-DomeniaRemoteCredentialSession {
    param([string]$User,[Security.SecureString]$Password,[string]$Computer)
    if(-not $Computer -or $Computer -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$'){throw 'Selectionnez la machine cible avant de valider un compte poste.'}
    if($User.StartsWith('.\')){$User=$Computer.Split('.')[0]+$User.Substring(1)}
    $ownedSecret=$null;$w=$null;$ps=$null
    try{
        $ownedSecret=$Password.Copy();$ownedSecret.MakeReadOnly()
        $credential=[Management.Automation.PSCredential]::new($User,$ownedSecret)
        $w=New-DomeniaWorkerRunspace -OperationId 'RemoteCredentialCheck' -Code (Get-DomeniaRemoteCredentialCheckCode)
        $ps=[Management.Automation.PowerShell]::Create();$ps.Runspace=$w.Runspace
        [void]$ps.AddCommand($w.CommandName);[void]$ps.AddParameter('Context',([pscustomobject]@{BaseDn=[string]$script:Conn.BaseDn}));[void]$ps.AddParameter('Payload',([pscustomobject]@{Computer=$Computer;Credential=$credential}))
        $handle=$ps.BeginInvoke()
    }catch{
        if($null -ne $ps){try{$ps.Dispose()}catch{}}
        if($null -ne $w -and $null -ne $w.Runspace){try{$w.Runspace.Dispose()}catch{}}
        if($null -ne $ownedSecret){$ownedSecret.Dispose()}
        throw
    }
    return [pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Request=$null;OwnedSecret=$ownedSecret;Progress=$null;PowerShell=$ps;Runspace=$w.Runspace;AsyncResult=$handle;StartedAt=Get-Date;EndInvoked=$false;Cleaned=$false;CancelRequested=$false;CleanupRetryAt=[datetime]::MinValue;CleanupGiveUpAt=[datetime]::MinValue}
}
function Set-DomeniaTargetCredentialContext {
    # Last step before a worker leaves (Start-UiTask). D051: the account is chosen per resource AND target
    # (Get-DomeniaCredentialScope). A local account bound to one workstation is only handed to an operation
    # whose resource is that workstation, never to LDAP, LAPS or BitLocker, and never to another workstation.
    param($Context,$Payload)
    if($null -eq $Context){return $Context}
    $operationId=[string](Get-DomeniaMember $Context 'OperationId' '')
    $resource='';if($operationId){$resource=Get-DomeniaOperationResource $operationId}
    if($resource -in @('Laps','BitLocker') -and $null -ne $script:SecretsCredential -and $null -eq (Get-DomeniaRetryCredential $operationId)){
        # Every LAPS or BitLocker read (ReadBitLockerList and ReadBitLockerKey included) uses the Secrets account
        # of the Accounts tab when one is active; a temporary account accepted for that resource still wins.
        $Context.Credential=$script:SecretsCredential;$Context.BindUser=[string]$script:SecretsCredential.UserName;$Context.UseCredential=$true
    }
    if($null -eq $script:AccessState -or $null -eq $Payload){return $Context}
    $target=[string](Get-DomeniaMember $Payload 'Computer' '')
    if(-not $target -or -not $operationId){return $Context}
    $scope=Get-DomeniaCredentialScope -OperationId $operationId -Target $target
    if(-not $scope.StartsWith('Remote:',[StringComparison]::Ordinal)){return $Context}
    $key='RemoteLocal|'+(ConvertTo-DomeniaMachineKey $target).ToUpperInvariant()
    if(-not $script:AccessState.Credentials.ContainsKey($key)){return $Context}
    $cred=$script:AccessState.Credentials[$key]
    if($null -eq $cred){return $Context}
    # D054: a new use needs a live lease; D051: the local account must belong to this very workstation.
    if(-not (Test-DomeniaAccessLeaseUsable -Key $key)){Remove-DomeniaAccessCredential -Key $key;return $Context}
    $check=Test-DomeniaCredentialContext -Scope $scope -UserName ([string]$cred.UserName) -Target $target
    if(-not [bool]$check.Valid){return $Context}
    $Context.MachineCredential=$cred;$Context.RemoteAdminCredential=$cred;$Context.RemoteAdminUser=$cred.UserName
    Use-DomeniaAccessLease -Key $key
    return $Context
}
