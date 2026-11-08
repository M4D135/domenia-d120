function Get-DomeniaLockoutAccountKeys {
    # Aliases under which the credential guard may have recorded this account (sAMAccountName and UPN).
    param([string]$Sam,[string]$Upn)
    $domain=[string]$script:Conn.Domain;$netbios=[string]$script:Conn.Netbios
    $keys=[Collections.Generic.List[string]]::new()
    foreach($name in @($Sam,$Upn)){
        if([string]::IsNullOrWhiteSpace($name)){continue}
        $key=Get-DomeniaCredentialAccountKey $name $domain $netbios
        if(($key) -and (-not $keys.Contains($key))){$keys.Add($key)}
    }
    return ,$keys.ToArray()
}
function Show-DomeniaLockoutText {
    param([string]$Text)
    $block=Get-DomeniaControl -Name 'TxtUserSupportLockouts'
    if($null -eq $block){return}
    $block.Text=$Text
    $block.Visibility=if($Text){[System.Windows.Visibility]::Visible}else{[System.Windows.Visibility]::Collapsed}
}
function Start-DomeniaLockoutEventRead {
    # Point 47: explicit gesture only. Reads the 4740 events of the selected account, never a whole-domain scan.
    $target=$script:UserSupportLockoutTarget
    if(($null -eq $target) -or ($null -eq $script:SelectedObject) -or ([string]$script:SelectedObject.DN -ine [string]$target.Dn)){
        Show-DomeniaLockoutText 'Rechargez la fiche du compte avant de lire ses verrouillages.'
        return
    }
    if(-not [string]$target.Sid){Show-DomeniaLockoutText 'SID du compte non lu : le journal ne peut pas être filtré sur ce compte.';return}
    Show-DomeniaLockoutText 'Lecture du journal Sécurité de lʼémulateur PDC (7 derniers jours)…'
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;Dn=[string]$target.Dn;Sid=[string]$target.Sid}
    $payload=[pscustomobject]@{UserSid=[string]$target.Sid;Hours=168;MaxEvents=200}
    Start-UiTask -Name ('Verrouillages '+[string]$target.Sam) -OperationId 'LockoutDiagnosis' -Code (Get-DomeniaLockoutEventWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaLockoutEventRead' -ErrorHandler 'Fail-DomeniaLockoutEventRead' -DisableControls @('BtnUserSupportLockouts') -TimeoutSeconds 60 -TaskClass 'Explicit'
}
function Test-DomeniaLockoutStateCurrent {
    param($State)
    $target=$script:UserSupportLockoutTarget
    return (($null -ne $State) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch) -and ([long]$State.Generation -eq [long]$script:SelectedObjectGeneration) -and ($null -ne $target) -and ([string]$target.Dn -ieq [string]$State.Dn))
}
function Format-DomeniaLockoutReport {
    # Pure presentation of a 4740 read and of the diagnosis built on it.
    param($Result,$Diagnosis)
    $nl=[Environment]::NewLine
    $source=if([string]$Result.ServerSource -eq 'Emulateur PDC'){'émulateur PDC'}else{'contrôleur interrogé, émulateur PDC non résolu'}
    $head='Journal Sécurité de '+[string]$Result.Server+' ('+$source+'), '+[string]([int]$Result.Hours/24)+' derniers jours'
    switch([string]$Result.State){
        'Refused' {return ($head+' : lecture refusée. Un refus ne prouve pas lʼabsence de verrouillage ; le compte doit pouvoir lire le journal Sécurité du contrôleur (Lecteurs des journaux dʼévénements).')}
        'Unavailable' {return ($head+' : journal injoignable. Aucune conclusion sur les verrouillages passés. '+[string]$Result.Message)}
    }
    $rows=@($Diagnosis.Timeline.Rows)
    if($null -eq $Diagnosis.Timeline){$rows=@()}
    if(@($Result.Events).Count -eq 0){return ($head+' : aucun verrouillage de ce compte dans la fenêtre lue.')}
    $lines=[Collections.Generic.List[string]]::new()
    $count=@($Result.Events).Count
    $lines.Add($head+' : '+[string]$count+' verrouillage(s)'+$(if([bool]$Result.Truncated){' (fenêtre bornée à '+[string]$Result.MaxEvents+' événements)'}else{''})+'.')
    foreach($row in $rows){$lines.Add('• '+[string]$row.Heure+'  ·  poste '+[string]$row.Poste+'  ·  '+[string]$row.Domenia)}
    foreach($fact in @($Diagnosis.Facts|Where-Object{[string]$_.Fait -in @('Postes a l origine','Refus de Domenia avant un verrouillage')})){
        $text=[string]$fact.Fait+' : '+[string]$fact.Valeur
        if([string]$fact.Hypothese){$text+='. '+[string]$fact.Hypothese}
        $lines.Add($text)
    }
    $lines.Add('Le poste indiqué est celui que le contrôleur a noté ; une session, un lecteur réseau ou un service peut y garder un ancien mot de passe.')
    return ($lines -join $nl)
}
function Complete-DomeniaLockoutEventRead {
    param($Result,$State)
    if(-not (Test-DomeniaLockoutStateCurrent $State)){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('State','Server','Events')
        if(($null -eq $r) -or ([string]$r.UserSid -cne [string]$State.Sid)){throw 'Résultat du journal absent ou provenant dʼun autre compte.'}
        $target=$script:UserSupportLockoutTarget
        $diag=Get-DomeniaLockoutDiagnosis -User $target.Properties -Dc ([string]$r.Server) -Events @($r.Events) -EventReadState ([string]$r.State) -Reader ([string]$script:Conn.User) -DomeniaFailures @(Get-DomeniaCredentialFailureHistory) -AccountKeys @($target.AccountKeys)
        Show-DomeniaLockoutText (Format-DomeniaLockoutReport $r $diag)
    }catch{Show-DomeniaLockoutText ('Lecture des verrouillages non exploitable : '+$_.Exception.Message)}
}
function Fail-DomeniaLockoutEventRead {
    param($Message,$State)
    if(-not (Test-DomeniaLockoutStateCurrent $State)){return}
    Show-DomeniaLockoutText ('Lecture des verrouillages impossible : '+[string]$Message)
}
