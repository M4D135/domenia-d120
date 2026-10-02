# Secrets view: BitLocker key selection (D058), single reveal and bounded copy (D059), explained buttons and
# a safe route to the missing prerequisite (D056), identity used for a read (D055). Values stay in memory only.
$script:BitLockerKeyList=@()
$script:BitLockerKeyContext=$null
$script:RevealedSecretIndex=-1

function Test-DomeniaBitLockerKeySelection {
    # Features.BitLockerKeySelection (default true): metadata first, then ONE chosen key. False = previous read.
    # The key selection relies on the single exposure (one chosen value revealed): with SecretSingleCopy off,
    # the previous whole read is kept, otherwise 'Afficher les secrets' would show metadata rows without values.
    return ([bool](Get-DomeniaFeatureFlag 'BitLockerKeySelection' $true) -and [bool](Get-DomeniaFeatureFlag 'SecretSingleCopy' $true))
}
function Test-DomeniaSecretSingleExposure {
    # Features.SecretSingleCopy (default true): one revealed value at a time, no "copy all".
    return [bool](Get-DomeniaFeatureFlag 'SecretSingleCopy' $true)
}
function Get-DomeniaSecretIdentityReason {
    # D055: which identity a LAPS or BitLocker read will use, and whether a prompt is needed. No privileged
    # account is required up front: the current Windows token is used until a refusal says otherwise.
    param([ValidateSet('LAPS','BitLocker')][string]$Mode)
    $operationId=if($Mode -eq 'LAPS'){'ReadLaps'}else{'ReadBitLocker'}
    $dn='';if($null -ne $script:SelectedObject){$dn=[string]$script:SelectedObject.DN}
    $denied=Test-DomeniaSecretDenied -Mode $Mode -DN $dn
    $faulted=($null -ne $script:AccessState -and $script:AccessState.Faults.ContainsKey((Get-DomeniaAccessScope $operationId)))
    $alternate=($null -ne (Get-DomeniaRetryCredential $operationId) -or $null -ne $script:SecretsCredential)
    $integrated=([string]$script:Conn.AuthMode -eq 'Windows' -or -not [bool]$script:Conn.UseCredential)
    return (Get-DomeniaOperationAuthNeed -OperationId $operationId -IntegratedSession $integrated -RefusedForScope ($denied -or $faulted) -AlternateAvailable $alternate -AlternateRefused ($denied -or $faulted))
}
function Get-DomeniaSecretButtonExplanation {
    # D056: state, reason and safe route of BtnLoadLaps / BtnLoadBitLocker, from the same session facts the
    # buttons use. An ACL estimate never disables the button: the domain controller decides.
    param([ValidateSet('BtnLoadLaps','BtnLoadBitLocker')][string]$Name,[bool]$Busy=$false)
    $mode=if($Name -eq 'BtnLoadLaps'){'LAPS'}else{'BitLocker'}
    $action=if($mode -eq 'LAPS'){'Lire LAPS'}else{'Lire BitLocker'}
    $isMachine=($null -ne $script:SelectedObject -and [string]$script:SelectedObject.Type -eq 'Machine' -and -not [string]::IsNullOrWhiteSpace([string]$script:SelectedObject.DN))
    $writeActive=((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ($script:WriteState -in @('Unknown','UnknownPending')))
    $estimated=''
    try{if($script:CurrentCapabilities.ContainsKey('Secrets')){$estimated=[string]$script:CurrentCapabilities['Secrets']}}catch{}
    if(-not $isMachine){$x=Get-DomeniaCapabilityExplanation -Action $action -State NoSelection -Detail 'Choisissez un poste dans Rechercher. Cette action lit AD sans rien modifier.';return [pscustomobject]@{Enabled=$false;ToolTip=$x.Text;Route=$x.Route;State='NoSelection'}}
    if($Busy){return [pscustomobject]@{Enabled=$false;ToolTip=($action+' : lecture en cours dans un runspace separe.');Route='';State='Reading'}}
    if($writeActive){$x=Get-DomeniaCapabilityExplanation -Action $action -State Busy -Detail 'La lecture reprend apres la verification de l ecriture.';return [pscustomobject]@{Enabled=$false;ToolTip=$x.Text;Route=$x.Route;State='Busy'}}
    $need=Get-DomeniaSecretIdentityReason -Mode $mode
    $identity=' Identite utilisee : '+[string]$need.Reason
    if($need.Prompt){$x=Get-DomeniaCapabilityExplanation -Action $action -State Refused -Detail 'Cliquez pour proposer un autre compte pour cette ressource uniquement.';return [pscustomobject]@{Enabled=$true;ToolTip=($x.Text+$identity);Route=$x.Route;State='Refused'}}
    if($estimated -eq 'Refuse'){$x=Get-DomeniaCapabilityExplanation -Action $action -State Estimated -Detail 'Le bouton reste disponible : le controleur de domaine ou Windows LAPS decide.';return [pscustomobject]@{Enabled=$true;ToolTip=($x.Text+$identity);Route='';State='Estimated'}}
    return [pscustomobject]@{Enabled=$true;ToolTip=($action+' : lecture AD uniquement, disponible meme en lecture seule ; aucune ecriture.'+$identity);Route='';State='Available'}
}
function Update-DomeniaSecretsPrerequisite {
    # In-page route to the missing prerequisite of a greyed secrets button (no window, nothing is read or written).
    param([string]$Route='',[string]$Reason='')
    $button=Get-DomeniaControl 'BtnSecretsPrerequisite'
    if($null -eq $button){return}
    $target=$null;if($Route){$target=Resolve-DomeniaCapabilityRoute -Route $Route}
    if($null -eq $target){$button.Visibility=[Windows.Visibility]::Collapsed;$button.Tag='';return}
    $button.Content='Ouvrir : '+[string]$target.Label
    $button.Tag=$Route
    $button.ToolTip=$Reason
    [Windows.Automation.AutomationProperties]::SetHelpText($button,$Reason)
    $button.Visibility=[Windows.Visibility]::Visible
}
function Select-DomeniaSecretRow {
    param([int]$Index)
    $grid=Get-DomeniaControl 'DgSecrets'
    if($null -eq $grid -or $Index -lt 0){return}
    foreach($item in @($grid.Items)){if($null -ne $item -and $null -ne $item.PSObject.Properties['SecretIndex'] -and [int]$item.SecretIndex -eq $Index){$grid.SelectedItem=$item;try{$grid.ScrollIntoView($item)}catch{};return}}
}
function Start-DomeniaSecretReveal {
    # D059: reveal ONE value, after an explicit gesture, for the exposure policy duration only.
    param([int]$Index)
    if($Index -lt 0 -or $Index -ge @($script:SecretRows).Count){return $false}
    if([string]::IsNullOrWhiteSpace([string]$script:SecretRows[$Index].Value)){return $false}
    $policy=Get-DomeniaSecretExposurePolicy
    try{if($null -ne $script:SecretRevealTimer){$script:SecretRevealTimer.Stop()}}catch{}
    $script:SecretsVisible=$true;$script:RevealedSecretIndex=$Index
    $timer=New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromSeconds([int]$policy.RevealSeconds)
    $timer.Add_Tick({
        try{$script:SecretRevealTimer.Stop()}catch{}
        $script:SecretsVisible=$false;$script:RevealedSecretIndex=-1
        Update-SecretsGrid
    })
    $script:SecretRevealTimer=$timer;$timer.Start()
    Update-SecretsGrid
    Select-DomeniaSecretRow -Index $Index
    return $true
}
function Get-DomeniaSelectedSecretIndex {
    $grid=Get-DomeniaControl 'DgSecrets'
    if($null -eq $grid -or $null -eq $grid.SelectedItem){return -1}
    $row=$grid.SelectedItem
    if($null -eq $row.PSObject.Properties['SecretIndex']){return -1}
    return [int]$row.SecretIndex
}
function Complete-DomeniaBitLockerListUi {
    param($Result,$State)
    $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Entries','Mode','Success')
    if($null -eq $effective){Fail-DomeniaSecretLoadUi -Message 'Le worker n a retourne aucun resultat exploitable.' -State $State;return}
    if(-not (Test-DomeniaSecretCallbackCurrent -State $State)){Write-AppLog ('Liste BitLocker obsolete ignoree pour '+[string]$State.DN+'.') 'WARN';return}
    $script:ActiveSecretRequestId=''
    $dn=[string]$State.DN
    if(-not [bool]$effective.Success){
        $kind=[string]$effective.ErrorKind;$detail=[string]$effective.ErrorMessage
        if($kind -eq 'LogonFailure' -and $null -ne $script:AccessState){$script:AccessState.Faults[(Get-DomeniaAccessScope 'ReadBitLockerList')]=$true}
        if($kind -eq 'AccessDenied'){Set-DomeniaSecretDenied -Mode 'BitLocker' -DN $dn}
        Update-SecretsGrid
        [void](Set-DomeniaControlText 'LblSecretsStatus' ('Lecture BitLocker non aboutie : '+$detail))
        $offered=Request-DomeniaAccessRecovery -Operation 'Lecture BitLocker' -ErrorValue $detail -OperationId 'ReadBitLockerList' -DN $dn -Interactive:([int]$State.RetryAttempt -eq 0)
        [void](Show-DomeniaOperationError -Operation 'Lecture BitLocker' -ErrorRecordOrException $detail -NoPopup:$offered)
        return
    }
    Set-DomeniaSecretDenied -Mode 'BitLocker' -DN $dn -Denied $false
    $keys=@(ConvertTo-DomeniaBitLockerKeyList -Entries @($effective.Entries))
    foreach($oldSecret in @($script:SecretRows)){try{$oldSecret.Value=''}catch{}}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in $keys){
        $rows.Add([pscustomobject]@{Kind='BitLocker';Account=[string]$key.RecoveryId;Value='';Timestamp=[string]$key.Created;Source='Metadonnees : cle non lue';Detail=[string]$key.DN;KeyDn=[string]$key.DN;KeyGuid=[string]$key.KeyGuid;Metadata=$true})
    }
    $script:SecretRows=$rows.ToArray()
    $script:BitLockerKeyList=$keys
    $script:BitLockerKeyContext=[pscustomobject]@{DN=$dn;Generation=[long]$State.Generation;ObjectGuid=[string]$State.ObjectGuid;Reader=[string]$effective.Reader}
    $script:SecretsVisible=$false;$script:RevealedSecretIndex=-1
    Restart-DomeniaSecretLifetime
    Update-SecretsGrid
    if($keys.Count -eq 0){
        [void](Set-DomeniaControlText 'LblSecretsStatus' 'Aucun objet de recuperation visible avec ce compte. L absence de resultat ne prouve pas l absence de cle.')
        Set-Status 'BitLocker : aucun objet de recuperation visible avec ce compte.' 'WARN'
        [void](Request-DomeniaAccessRecovery -Operation 'Lecture BitLocker' -ErrorValue 'Aucune cle visible.' -OperationId 'ReadBitLockerList' -DN $dn -Possible -Interactive:([int]$State.RetryAttempt -eq 0))
        try{[void](Save-DomeniaSecretIndexEntry -Computer (Get-CurrentSelectedComputerName) -BitLockerKeys 0 -Verdict 'aucune cle visible avec ce compte')}catch{}
        Update-DomeniaSecretActionUi
        return
    }
    [void](Set-DomeniaControlText 'LblSecretsStatus' ([string]$keys.Count+' cle(s) BitLocker : metadonnees seulement, aucune cle lue. Saisissez l identifiant de recuperation affiche par le poste ou choisissez une ligne, puis Afficher ou Copier.'))
    try{[void](Update-DomeniaSecretIndexFromRows -Computer (Get-CurrentSelectedComputerName) -Mode 'BitLocker' -Rows $script:SecretRows -Verdict 'objets de recuperation visibles, cles non lues')}catch{}
    $box=Get-DomeniaControl 'TxtBitLockerRecoveryId'
    if($null -ne $box){$box.IsEnabled=$true;if(-not [string]::IsNullOrWhiteSpace([string]$box.Text)){Invoke-DomeniaBitLockerRecoveryIdFilter}}
    Update-DomeniaSecretActionUi
    Set-Status ('BitLocker : '+[string]$keys.Count+' cle(s) listee(s), aucune revelee.')
}
function Invoke-DomeniaBitLockerRecoveryIdFilter {
    # Local filter on the metadata already read: no network call, nothing revealed.
    $box=Get-DomeniaControl 'TxtBitLockerRecoveryId'
    $hint=Get-DomeniaControl 'LblBitLockerRecoveryHint'
    $text='';if($null -ne $box){$text=[string]$box.Text}
    if([string]::IsNullOrWhiteSpace($text)){if($null -ne $hint){$hint.Text='Les huit premiers caracteres de l identifiant suffisent. Rien n est lu ni revele par cette recherche.'};return $null}
    $found=Find-DomeniaBitLockerKey -Keys @($script:BitLockerKeyList) -RecoveryId $text
    if($null -ne $hint){$hint.Text=[string]$found.Message}
    if($found.Unique){
        $wanted=[string]@($found.Matches)[0].DN
        for($i=0;$i -lt @($script:SecretRows).Count;$i++){if([string](Get-DomeniaMember $script:SecretRows[$i] 'KeyDn' '') -ieq $wanted){Select-DomeniaSecretRow -Index $i;break}}
    }
    Update-DomeniaSecretActionUi
    return $found
}
function Request-DomeniaBitLockerKey {
    # D058: read ONE key, the selected one, after an explicit gesture (reveal or copy). Never at tab opening.
    param([ValidateSet('ExplicitReveal','ExplicitCopy')][string]$Trigger)
    $grid=Get-DomeniaControl 'DgSecrets'
    $selected=0;if($null -ne $grid -and $null -ne $grid.SelectedItem){$selected=1}
    if(-not (Test-DomeniaSecretRevealAllowed -Trigger $Trigger -SelectedCount $selected)){Set-Status 'Selectionnez d abord la cle BitLocker a lire.';return $false}
    $row=Get-DomeniaSelectedSecretSource
    if($null -eq $row -or -not [bool](Get-DomeniaMember $row 'Metadata' $false)){return $false}
    $context=$script:BitLockerKeyContext
    if($null -eq $script:SelectedObject -or $null -eq $context -or [string]$script:SelectedObject.DN -ine [string]$context.DN -or [long]$script:SelectedObjectGeneration -ne [long]$context.Generation){
        Set-Status 'La selection a change : rechargez BitLocker avant de lire une cle.' 'WARN';return $false
    }
    $keyDn=[string]$row.KeyDn
    if(-not (Test-DomeniaDirectChildDn -ParentDn ([string]$context.DN) -ChildDn $keyDn)){Set-Status 'Cle hors du poste selectionne : lecture refusee.' 'WARN';return $false}
    if((Test-DomeniaSecretDenied -Mode 'BitLocker' -DN ([string]$context.DN)) -or ($null -ne $script:AccessState -and $script:AccessState.Faults.ContainsKey((Get-DomeniaAccessScope 'ReadBitLockerKey')))){
        [void](Request-DomeniaAccessRecovery -Operation 'Lecture BitLocker' -ErrorValue 'Acces refuse avec ce compte.' -OperationId 'ReadBitLockerKey' -DN ([string]$context.DN) -Interactive -Force)
        return $false
    }
    $requestId=[guid]::NewGuid().ToString('N')
    $script:ActiveSecretRequestId=$requestId
    $state=[pscustomobject]@{RequestId=$requestId;DN=[string]$context.DN;ObjectGuid=[string]$context.ObjectGuid;Generation=[int64]$context.Generation;Mode='BitLocker';RetryAttempt=0;Trigger=$Trigger;KeyDn=$keyDn;KeyGuid=[string]$row.KeyGuid}
    try{
        Start-UiTask -Name 'Lecture d une cle BitLocker' -OperationId 'ReadBitLockerKey' -Code (Get-DomeniaBitLockerKeyWorkerCode) -Payload ([pscustomobject]@{DN=[string]$context.DN;KeyDn=$keyDn;KeyGuid=[string]$row.KeyGuid}) -CallbackState $state -ReplaceKey 'secrets' -DisableControls @('BtnLoadBitLocker','BtnLoadLaps','BtnToggleSecrets','BtnCopySecret') -TimeoutSeconds 40 -StatusText 'Lecture de la cle choisie...' -SuccessHandler 'Complete-DomeniaBitLockerKeyUi' -ErrorHandler 'Fail-DomeniaBitLockerKeyUi' | Out-Null
    }catch{
        $script:ActiveSecretRequestId=''
        [void](Show-DomeniaOperationError -Operation 'Lecture BitLocker' -ErrorRecordOrException $_)
        return $false
    }
    return $true
}
function Complete-DomeniaBitLockerKeyUi {
    param($Result,$State)
    $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Mode','Success')
    if($null -eq $effective){Fail-DomeniaBitLockerKeyUi -Message 'Le worker n a retourne aucun resultat exploitable.' -State $State;return}
    if(-not (Test-DomeniaSecretCallbackCurrent -State $State)){Clear-DomeniaSecretResultValues -Result $effective;Write-AppLog ('Cle BitLocker obsolete ignoree pour '+[string]$State.DN+'.') 'WARN';return}
    $script:ActiveSecretRequestId=''
    if(-not [bool]$effective.Success){
        Clear-DomeniaSecretResultValues -Result $effective
        $kind=[string]$effective.ErrorKind;$detail=[string]$effective.ErrorMessage
        if($kind -eq 'LogonFailure' -and $null -ne $script:AccessState){$script:AccessState.Faults[(Get-DomeniaAccessScope 'ReadBitLockerKey')]=$true}
        if($kind -eq 'AccessDenied'){Set-DomeniaSecretDenied -Mode 'BitLocker' -DN ([string]$State.DN)}
        [void](Set-DomeniaControlText 'LblSecretsStatus' ('Cle non lue : '+$detail))
        # Same classification as the list path (Core): the worker detail alone is not recognised as a refusal.
        $offerValue=if($kind -eq 'AccessDenied'){'Acces refuse. '+$detail}else{$detail}
        $offered=Request-DomeniaAccessRecovery -Operation 'Lecture BitLocker' -ErrorValue $offerValue -OperationId 'ReadBitLockerKey' -DN ([string]$State.DN) -Interactive -Possible:($kind -eq 'NoReadableValue')
        [void](Show-DomeniaOperationError -Operation 'Lecture BitLocker' -ErrorRecordOrException $detail -NoPopup:$offered)
        Update-DomeniaSecretActionUi
        return
    }
    $key=@($effective.Rows)[0]
    $index=-1
    for($i=0;$i -lt @($script:SecretRows).Count;$i++){
        if([string](Get-DomeniaMember $script:SecretRows[$i] 'KeyDn' '') -ieq [string]$State.KeyDn){
            $script:SecretRows[$i].Value=[string]$key.Value
            $script:SecretRows[$i].Source='msFVE-RecoveryInformation : cle lue a la demande'
            $index=$i;break
        }
    }
    Clear-DomeniaSecretResultValues -Result $effective
    if($index -lt 0){Update-SecretsGrid;return}
    Restart-DomeniaSecretLifetime
    if([string]$State.Trigger -eq 'ExplicitCopy'){
        Update-SecretsGrid;Select-DomeniaSecretRow -Index $index
        $policy=Get-DomeniaSecretExposurePolicy
        $value=[string]$script:SecretRows[$index].Value
        try{
            Set-DomeniaProtectedClipboard -Value $value -MaxLength 1024
            Start-SecretClipboardAutoClear $value
            Write-AppLog ('Cle BitLocker copiee temporairement : '+[string]$script:SecretRows[$index].Account) 'WARN'
            [void](Set-DomeniaControlText 'LblSecretsStatus' ('Cle copiee, effacement automatique programme. '+[string]$policy.ClipboardLimit))
        }catch{Show-ErrorBox ('Erreur copie secret : '+$_.Exception.Message)}
        finally{$value=''}
    }else{
        [void](Start-DomeniaSecretReveal -Index $index)
        [void](Set-DomeniaControlText 'LblSecretsStatus' ('Cle '+[string]$script:SecretRows[$index].Account+' affichee pour '+[string](Get-DomeniaSecretExposurePolicy).RevealSeconds+' s. Les autres cles ne sont pas lues.'))
    }
    Update-DomeniaSecretActionUi
}
function Fail-DomeniaBitLockerKeyUi {
    param($Message,$State)
    if($null -ne $State -and -not (Test-DomeniaSecretCallbackCurrent -State $State)){return}
    $script:ActiveSecretRequestId=''
    $kind=Get-DomeniaAccessFailureKind $Message
    if($kind -eq 'AccessDenied' -and $null -ne $State){Set-DomeniaSecretDenied -Mode 'BitLocker' -DN ([string]$State.DN)}
    [void](Set-DomeniaControlText 'LblSecretsStatus' ('Cle non lue, issue non confirmee : '+[string]$Message))
    $offered=$false
    if($null -ne $State){$offered=Request-DomeniaAccessRecovery -Operation 'Lecture BitLocker' -ErrorValue $Message -OperationId 'ReadBitLockerKey' -DN ([string]$State.DN) -Interactive}
    [void](Show-DomeniaOperationError -Operation 'Lecture BitLocker' -ErrorRecordOrException $Message -NoPopup:$offered)
    Update-DomeniaSecretActionUi
}
function Invoke-DomeniaSecretsPrerequisite {
    $button=Get-DomeniaControl 'BtnSecretsPrerequisite'
    if($null -eq $button){return}
    $route=[string]$button.Tag
    if($route){[void](Invoke-DomeniaCapabilityRoute -Route $route)}
}
function Initialize-DomeniaSecretsUi {
    $box=Get-DomeniaControl 'TxtBitLockerRecoveryId'
    if($null -ne $box){$box.Add_TextChanged({try{[void](Invoke-DomeniaBitLockerRecoveryIdFilter)}catch{Write-AppLog ('Recherche de cle BitLocker : '+$_.Exception.Message) 'WARN'}})}
    $button=Get-DomeniaControl 'BtnSecretsPrerequisite'
    if($null -ne $button){$button.Add_Click({try{Invoke-DomeniaSecretsPrerequisite}catch{Write-AppLog ('Route du prerequis : '+$_.Exception.Message) 'WARN'}})}
    $limit=Get-DomeniaControl 'LblSecretsExposure'
    if($null -ne $limit){
        $policy=Get-DomeniaSecretExposurePolicy
        $limit.Text=('Une valeur a la fois, affichee '+[string]$policy.RevealSeconds+' s, jamais journalisee ni mise en cache. '+[string]$policy.ClipboardLimit)
    }
}
