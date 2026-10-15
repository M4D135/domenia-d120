# Secrets view: BitLocker key selection (D058), single reveal and bounded copy (D059), explained buttons and
# a safe route to the missing prerequisite (D056), identity used for a read (D055). Values stay in memory only.
$script:BitLockerKeyList=@()
$script:BitLockerKeyContext=$null
$script:RevealedSecretIndex=-1
$script:SecretReveal=$null
$script:SecretCountdownTimer=$null

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
    # UI-31: the explanation starts with the name of the button itself.
    $action=if($mode -eq 'LAPS'){'Lire le mot de passe LAPS'}else{'Lister les clés BitLocker'}
    $isMachine=($null -ne $script:SelectedObject -and [string]$script:SelectedObject.Type -eq 'Machine' -and -not [string]::IsNullOrWhiteSpace([string]$script:SelectedObject.DN))
    $writeActive=((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ($script:WriteState -in @('Unknown','UnknownPending')))
    $estimated=''
    try{if($script:CurrentCapabilities.ContainsKey('Secrets')){$estimated=[string]$script:CurrentCapabilities['Secrets']}}catch{}
    if(-not $isMachine){$x=Get-DomeniaCapabilityExplanation -Action $action -State NoSelection -Detail 'Choisissez un poste dans Rechercher. Cette action lit AD sans rien modifier.';return [pscustomobject]@{Enabled=$false;ToolTip=$x.Text;Route=$x.Route;State='NoSelection'}}
    if($Busy){return [pscustomobject]@{Enabled=$false;ToolTip=($action+' : lecture en cours en arrière-plan.');Route='';State='Reading'}}
    if($writeActive){$x=Get-DomeniaCapabilityExplanation -Action $action -State Busy -Detail 'La lecture reprend après la vérification de lʼécriture.';return [pscustomobject]@{Enabled=$false;ToolTip=$x.Text;Route=$x.Route;State='Busy'}}
    $need=Get-DomeniaSecretIdentityReason -Mode $mode
    $identity=' Identité utilisée : '+[string]$need.Reason
    if($need.Prompt){$x=Get-DomeniaCapabilityExplanation -Action $action -State Refused -Detail 'Cliquez pour proposer un autre compte pour cette ressource uniquement.';return [pscustomobject]@{Enabled=$true;ToolTip=($x.Text+$identity);Route=$x.Route;State='Refused'}}
    if($estimated -eq 'Refuse'){$x=Get-DomeniaCapabilityExplanation -Action $action -State Estimated -Detail 'Le bouton reste disponible : le contrôleur de domaine ou Windows LAPS décide.';return [pscustomobject]@{Enabled=$true;ToolTip=($x.Text+$identity);Route='';State='Estimated'}}
    return [pscustomobject]@{Enabled=$true;ToolTip=($action+' : lecture AD uniquement, disponible même en lecture seule ; aucune écriture.'+$identity);Route='';State='Available'}
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
    $seconds=[int]$policy.RevealSeconds
    $script:SecretsVisible=$true;$script:RevealedSecretIndex=$Index
    # UX-18: deadline and single extension of this reveal; a new reveal starts a new count.
    $script:SecretReveal=[pscustomobject]@{Index=$Index;DeadlineUtc=[datetime]::UtcNow.AddSeconds($seconds);TotalSeconds=$seconds;Extended=$false}
    Start-DomeniaSecretRevealExpiry -Milliseconds ($seconds*1000)
    Update-SecretsGrid
    Select-DomeniaSecretRow -Index $Index
    return $true
}
function Start-DomeniaSecretRevealExpiry {
    # D059: the one-shot timer that hides the revealed value. FI-05: protected heartbeat timer, owned and registered
    # by the factory, also running minimized; created again (same owner, the previous one is stopped) when the single
    # extension moves the deadline.
    param([int]$Milliseconds)
    $script:SecretRevealTimer=New-DomeniaTimer -Owner 'Timer:SecretReveal' -IntervalMs ([Math]::Max(1,$Milliseconds)) -RunWhenHidden -Start -Tick {
        param($sender,$eventArgs)
        try{$sender.Stop()}catch{}
        Hide-DomeniaRevealedSecret
    }
}
function Hide-DomeniaRevealedSecret {
    # D059 / UX-18: ends the reveal, whoever asks for it (expiry, Masquer maintenant, the countdown finding the
    # deadline past). The grid and the card are redrawn masked; the value itself stays in memory only until the
    # secret lifetime ends, as before.
    try{if($null -ne $script:SecretRevealTimer){$script:SecretRevealTimer.Stop()}}catch{}
    try{if($null -ne $script:SecretCountdownTimer){$script:SecretCountdownTimer.Stop()}}catch{}
    $index=-1;if($null -ne $script:RevealedSecretIndex){$index=[int]$script:RevealedSecretIndex}
    $script:SecretsVisible=$false;$script:RevealedSecretIndex=-1;$script:SecretReveal=$null
    Update-SecretsGrid
    # The line stays chosen, masked: showing it again is one explicit click, without reading anything again.
    if($index -ge 0){Select-DomeniaSecretRow -Index $index}
}
function Get-DomeniaRevealedBitLockerKey {
    # UX-18: the BitLocker row revealed alone, split into its eight blocks, or $null: nothing revealed, a LAPS value,
    # the whole-grid reveal of Features.SecretSingleCopy off, or a value that is not a recovery password.
    if(-not [bool]$script:SecretsVisible){return $null}
    if(-not (Test-DomeniaSecretSingleExposure)){return $null}
    $index=-1;if($null -ne $script:RevealedSecretIndex){$index=[int]$script:RevealedSecretIndex}
    $rows=@($script:SecretRows)
    if(($index -lt 0) -or ($index -ge $rows.Count)){return $null}
    $row=$rows[$index]
    if([string](Get-DomeniaMember $row 'Kind' '') -notmatch '(?i)BitLocker'){return $null}
    $blocks=@(ConvertTo-DomeniaBitLockerKeyBlocks ([string](Get-DomeniaMember $row 'Value' '')))
    if($blocks.Count -ne 8){return $null}
    return [pscustomobject]@{Index=$index;Blocks=$blocks;RecoveryId=[string](Get-DomeniaMember $row 'Account' '');KeyGuid=[string](Get-DomeniaMember $row 'KeyGuid' '')}
}
function Update-DomeniaSecretRevealCountdown {
    # UX-18: seconds left and ring of the key shown in the card, once a second. Display only: the expiry timer hides
    # the value, and this tick hides it too if it ever finds the deadline past. $true while the key stays shown.
    # Without a key in the card (LAPS, whole-grid reveal, nothing shown) it only stops itself.
    $key=Get-DomeniaRevealedBitLockerKey
    if($null -eq $key){try{if($null -ne $script:SecretCountdownTimer){$script:SecretCountdownTimer.Stop()}}catch{};return $false}
    $reveal=$script:SecretReveal
    if(($null -eq $reveal) -or ([int]$reveal.Index -ne [int]$key.Index)){Hide-DomeniaRevealedSecret;return $false}
    $c=Get-DomeniaSecretRevealCountdown -DeadlineUtc $reveal.DeadlineUtc -NowUtc ([datetime]::UtcNow) -TotalSeconds ([int]$reveal.TotalSeconds) -Extended ([bool]$reveal.Extended)
    if([bool]$c.Expired){Hide-DomeniaRevealedSecret;return $false}
    [void](Set-DomeniaControlText 'LblBitLockerKeyCountdown' ([string]$c.Text))
    $ring=Get-DomeniaControl 'BitLockerKeyRing'
    if($null -ne $ring){
        # Dash lengths are counted in stroke thicknesses: the whole ring is pi*(diameter-thickness)/thickness.
        $thickness=[Math]::Max(1.0,[double]$ring.StrokeThickness)
        $units=[Math]::PI*([double]$ring.Width-$thickness)/$thickness
        $dashes=New-Object Windows.Media.DoubleCollection
        $dashes.Add($units*[double]$c.Fraction);$dashes.Add($units+1.0)
        $ring.StrokeDashArray=$dashes
        [Windows.Automation.AutomationProperties]::SetName($ring,('Clé masquée dans '+[string]$c.Remaining+' s'))
    }
    $extend=Get-DomeniaControl 'BtnBitLockerKeyExtend'
    if($null -ne $extend){
        $extend.IsEnabled=[bool]$c.CanExtend
        $extend.Content=if([bool]$reveal.Extended){'Prolongation utilisée'}else{'Prolonger '+[string]$c.ExtensionSeconds+' s'}
    }
    return $true
}
function Update-DomeniaSecretsView {
    # UX-18: what surrounds the rows of the secrets grid. The card shows the BitLocker key revealed alone, in eight
    # numbered blocks with its recovery identifier and its countdown; the identity column is named after the rows
    # (recovery identifier for BitLocker, account for LAPS). Called by Update-SecretsGrid and Clear-Secrets: whatever
    # ends a reveal (expiry, Masquer, another selection, window deactivation, Vider) hides and empties the card here,
    # before anything else can fail.
    $card=Get-DomeniaControl 'BitLockerKeyCard'
    if($null -ne $card){
        $key=Get-DomeniaRevealedBitLockerKey
        $blocksHost=Get-DomeniaControl 'BitLockerKeyBlocks'
        if($null -eq $key){
            $card.Visibility=[Windows.Visibility]::Collapsed
            try{if($null -ne $script:SecretCountdownTimer){$script:SecretCountdownTimer.Stop()}}catch{}
            if($null -ne $blocksHost){$blocksHost.ItemsSource=$null}
            [void](Set-DomeniaControlText 'LblBitLockerKeyCardId' '')
            [void](Set-DomeniaControlText 'LblBitLockerKeyCountdown' '')
        }else{
            if($null -ne $blocksHost){$items=[Collections.ArrayList]::new();foreach($block in @($key.Blocks)){[void]$items.Add($block)};$blocksHost.ItemsSource=$items}
            $id=[string]$key.RecoveryId
            if(([string]$key.KeyGuid) -and ([string]$key.KeyGuid -cne $id)){$id+=' ('+[string]$key.KeyGuid+')'}
            if(-not $id){$id='non lu'}
            [void](Set-DomeniaControlText 'LblBitLockerKeyCardId' ('Identifiant de récupération : '+$id+'. Vérifiez quʼil correspond à celui affiché par le poste avant de dicter les huit blocs.'))
            $card.Visibility=[Windows.Visibility]::Visible
            if((Update-DomeniaSecretRevealCountdown) -and (($null -eq $script:SecretCountdownTimer) -or (-not [bool]$script:SecretCountdownTimer.IsEnabled))){
                # FI-05: protected heartbeat timer; display only, the expiry timer stays the one that hides the key.
                $script:SecretCountdownTimer=New-DomeniaTimer -Owner 'Timer:SecretCountdown' -IntervalMs 1000 -Start -Tick {
                    param($sender,$eventArgs)
                    [void](Update-DomeniaSecretRevealCountdown)
                }
            }
        }
    }
    $grid=Get-DomeniaControl 'DgSecrets'
    if($null -eq $grid){return}
    $header=Get-DomeniaSecretColumnHeader -Kinds @(@($script:SecretRows)|ForEach-Object{[string](Get-DomeniaMember $_ 'Kind' '')})
    foreach($column in @($grid.Columns)){
        if(($column -is [Windows.Controls.DataGridBoundColumn]) -and ($null -ne $column.Binding) -and ([string]$column.Binding.Path.Path -eq 'Account') -and ([string]$column.Header -cne $header)){$column.Header=$header}
    }
}
function Invoke-DomeniaSecretRevealExtension {
    # UX-18: one extension of the BitLocker key shown in the card, by the policy duration, on an explicit click and
    # while the key is still shown. The deadline moves and the expiry timer is armed again for the time left; a second
    # extension is refused. Nothing is read again and nothing is copied.
    $key=Get-DomeniaRevealedBitLockerKey
    $reveal=$script:SecretReveal
    if(($null -eq $key) -or ($null -eq $reveal)){return $false}
    if([int]$reveal.Index -ne [int]$key.Index){return $false}
    $now=[datetime]::UtcNow
    $c=Get-DomeniaSecretRevealCountdown -DeadlineUtc $reveal.DeadlineUtc -NowUtc $now -TotalSeconds ([int]$reveal.TotalSeconds) -Extended ([bool]$reveal.Extended)
    if(-not [bool]$c.CanExtend){Set-Status 'Prolongation déjà utilisée : la clé sera masquée à lʼéchéance.' 'WARN';[void](Update-DomeniaSecretRevealCountdown);return $false}
    $extra=[int]$c.ExtensionSeconds
    $reveal.DeadlineUtc=([datetime]$reveal.DeadlineUtc).AddSeconds($extra)
    $reveal.TotalSeconds=[int]$reveal.TotalSeconds+$extra
    $reveal.Extended=$true
    Start-DomeniaSecretRevealExpiry -Milliseconds ([int][Math]::Ceiling((([datetime]$reveal.DeadlineUtc)-$now).TotalMilliseconds))
    [void](Update-DomeniaSecretRevealCountdown)
    Set-Status ('Affichage de la clé prolongé de '+[string]$extra+' s, une seule fois.')
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
        # UX-18: the DN stays in KeyDn for the read of the chosen key; the operator reads the full recovery identifier.
        $rows.Add([pscustomobject]@{Kind='BitLocker';Account=[string]$key.RecoveryId;Value='';Timestamp=[string]$key.Created;Source='Métadonnées : clé non lue';Detail=('Identifiant complet : '+[string]$key.KeyGuid);KeyDn=[string]$key.DN;KeyGuid=[string]$key.KeyGuid;Metadata=$true})
    }
    $script:SecretRows=$rows.ToArray()
    $script:BitLockerKeyList=$keys
    $script:BitLockerKeyContext=[pscustomobject]@{DN=$dn;Generation=[long]$State.Generation;ObjectGuid=[string]$State.ObjectGuid;Reader=[string]$effective.Reader}
    $script:SecretsVisible=$false;$script:RevealedSecretIndex=-1
    Restart-DomeniaSecretLifetime
    Update-SecretsGrid
    if($keys.Count -eq 0){
        [void](Set-DomeniaControlText 'LblSecretsStatus' 'Aucun objet de récupération visible avec ce compte. Lʼabsence de résultat ne prouve pas lʼabsence de clé.')
        Set-Status 'BitLocker : aucun objet de récupération visible avec ce compte.' 'WARN'
        [void](Request-DomeniaAccessRecovery -Operation 'Lecture BitLocker' -ErrorValue 'Aucune cle visible.' -OperationId 'ReadBitLockerList' -DN $dn -Possible -Interactive:([int]$State.RetryAttempt -eq 0))
        try{[void](Save-DomeniaSecretIndexEntry -Computer (Get-CurrentSelectedComputerName) -BitLockerKeys 0 -Verdict 'aucune cle visible avec ce compte')}catch{}
        Update-DomeniaSecretActionUi
        return
    }
    [void](Set-DomeniaControlText 'LblSecretsStatus' ([string]$keys.Count+' clé(s) BitLocker listée(s) : métadonnées seulement, aucune clé lue. Saisissez lʼidentifiant de récupération affiché par le poste ou choisissez une ligne, puis « Lire et afficher cette clé » ou « Copier la clé BitLocker ».'))
    try{[void](Update-DomeniaSecretIndexFromRows -Computer (Get-CurrentSelectedComputerName) -Mode 'BitLocker' -Rows $script:SecretRows -Verdict 'objets de recuperation visibles, cles non lues')}catch{}
    $box=Get-DomeniaControl 'TxtBitLockerRecoveryId'
    if($null -ne $box){$box.IsEnabled=$true;if(-not [string]::IsNullOrWhiteSpace([string]$box.Text)){Invoke-DomeniaBitLockerRecoveryIdFilter}}
    Update-DomeniaSecretActionUi
    Set-Status ('BitLocker : '+[string]$keys.Count+' clé(s) listée(s), aucune affichée.')
}
function Invoke-DomeniaBitLockerRecoveryIdFilter {
    # Local filter on the metadata already read: no network call, nothing revealed.
    $box=Get-DomeniaControl 'TxtBitLockerRecoveryId'
    $hint=Get-DomeniaControl 'LblBitLockerRecoveryHint'
    $text='';if($null -ne $box){$text=[string]$box.Text}
    if([string]::IsNullOrWhiteSpace($text)){if($null -ne $hint){$hint.Text='Les huit premiers caractères de lʼidentifiant suffisent. Rien nʼest lu ni révélé par cette recherche.'};return $null}
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
    if(-not (Test-DomeniaSecretRevealAllowed -Trigger $Trigger -SelectedCount $selected)){Set-Status 'Sélectionnez dʼabord la clé BitLocker à lire.';return $false}
    $row=Get-DomeniaSelectedSecretSource
    if($null -eq $row -or -not [bool](Get-DomeniaMember $row 'Metadata' $false)){return $false}
    $context=$script:BitLockerKeyContext
    if($null -eq $script:SelectedObject -or $null -eq $context -or [string]$script:SelectedObject.DN -ine [string]$context.DN -or [long]$script:SelectedObjectGeneration -ne [long]$context.Generation){
        Set-Status 'La sélection a changé : relancez « Lister les clés BitLocker » avant de lire une clé.' 'WARN';return $false
    }
    $keyDn=[string]$row.KeyDn
    if(-not (Test-DomeniaDirectChildDn -ParentDn ([string]$context.DN) -ChildDn $keyDn)){Set-Status 'Clé hors du poste sélectionné : lecture refusée.' 'WARN';return $false}
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
        [void](Set-DomeniaControlText 'LblSecretsStatus' ('Clé non lue : '+$detail))
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
            $script:SecretRows[$i].Source='Clé lue à votre demande'
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
            [void](Set-DomeniaControlText 'LblSecretsStatus' ('Clé copiée, effacement automatique programmé. '+[string]$policy.ClipboardLimit))
        }catch{Show-ErrorBox ('Erreur copie secret : '+$_.Exception.Message)}
        finally{$value=''}
    }else{
        [void](Start-DomeniaSecretReveal -Index $index)
        $policy=Get-DomeniaSecretExposurePolicy
        $where=if($null -ne (Get-DomeniaRevealedBitLockerKey)){' dans la carte ci-dessus pendant '+[string]$policy.RevealSeconds+' s, prolongeable une fois de '+[string]$policy.RevealExtensionSeconds+' s.'}else{' pendant '+[string]$policy.RevealSeconds+' s.'}
        [void](Set-DomeniaControlText 'LblSecretsStatus' ('Clé '+[string]$script:SecretRows[$index].Account+' affichée'+$where+' Les autres clés ne sont pas lues.'))
    }
    Update-DomeniaSecretActionUi
}
function Fail-DomeniaBitLockerKeyUi {
    param($Message,$State)
    if($null -ne $State -and -not (Test-DomeniaSecretCallbackCurrent -State $State)){return}
    $script:ActiveSecretRequestId=''
    $kind=Get-DomeniaAccessFailureKind $Message
    if($kind -eq 'AccessDenied' -and $null -ne $State){Set-DomeniaSecretDenied -Mode 'BitLocker' -DN ([string]$State.DN)}
    [void](Set-DomeniaControlText 'LblSecretsStatus' ('Clé non lue, issue non confirmée : '+[string]$Message))
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
        $limit.Text=('Une valeur à la fois, affichée '+[string]$policy.RevealSeconds+' s (une clé BitLocker peut être prolongée une fois de '+[string]$policy.RevealExtensionSeconds+' s), jamais journalisée ni mise en cache. '+[string]$policy.ClipboardLimit)
    }
    # UX-18: the two buttons of the BitLocker key card. Neither reads nor copies anything.
    $extend=Get-DomeniaControl 'BtnBitLockerKeyExtend'
    if($null -ne $extend){$extend.Add_Click({try{[void](Invoke-DomeniaSecretRevealExtension)}catch{Write-AppLog ('Prolongation de la cle : '+$_.Exception.Message) 'WARN'}})}
    $hide=Get-DomeniaControl 'BtnBitLockerKeyHide'
    if($null -ne $hide){$hide.Add_Click({try{Hide-DomeniaRevealedSecret;Set-Status 'Clé masquée.'}catch{Write-AppLog ('Masquage de la cle : '+$_.Exception.Message) 'WARN'}})}
}
