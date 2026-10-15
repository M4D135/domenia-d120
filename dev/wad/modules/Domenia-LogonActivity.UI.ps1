# Point 27: logon activity of the open fiche. The approximate date (lastLogonTimestamp) is explained when the fiche is
# shown; the exact lastLogon of each controller is read only on an explicit gesture, for the open object only.
$script:DomeniaLogonTargets=@{}

function Get-DomeniaLogonPanelNames {
    param([ValidateSet('User','Computer')][string]$Kind)
    if($Kind -eq 'User'){return [pscustomobject]@{Button='BtnUserLogonByDc';Text='TxtUserLogonByDc'}}
    return [pscustomobject]@{Button='BtnCompLogonByDc';Text='TxtCompLogonByDc'}
}

function Update-DomeniaLogonActivityPanel {
    # Called when a user or computer fiche is filled. Nothing is read here: the text explains the value already loaded.
    param([ValidateSet('User','Computer')][string]$Kind,$Entry)
    $names=Get-DomeniaLogonPanelNames $Kind
    $button=Get-DomeniaControl $names.Button
    $script:DomeniaLogonTargets[$Kind]=$null
    try{
        if($null -eq $Entry){[void](Set-DomeniaControlText $names.Text '');if($null -ne $button){$button.IsEnabled=$false};return}
        $timestamp=Get-DeProp $Entry 'lastLogonTimestamp' $null
        $guid=ConvertTo-DomeniaGuidText (Get-DeProp $Entry 'objectGUID' '')
        $dn=[string](Get-DeProp $Entry 'distinguishedName' '')
        $summary=Get-DomeniaLogonActivitySummary -LastLogonTimestamp $timestamp -NowUtc ([datetime]::UtcNow)
        [void](Set-DomeniaControlText $names.Text ([string]$summary.Text))
        if($guid -and $dn){$script:DomeniaLogonTargets[$Kind]=[pscustomobject]@{Guid=$guid;Dn=$dn;Generation=[long]$script:SelectedObjectGeneration;Epoch=[long]$script:SessionEpoch;LastLogonTimestamp=$timestamp}}
        if($null -ne $button){$button.IsEnabled=(($null -ne $script:DomeniaLogonTargets[$Kind]) -and (-not [bool]$script:DemoMode))}
    }catch{
        [void](Set-DomeniaControlText $names.Text ('Activité de connexion non expliquée : '+$_.Exception.Message))
        if($null -ne $button){$button.IsEnabled=$false}
    }
}

function Test-DomeniaLogonTargetCurrent {
    param($State)
    if($null -eq $State){return $false}
    $target=$script:DomeniaLogonTargets[[string]$State.Kind]
    return (($null -ne $target) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch) -and ([long]$State.Generation -eq [long]$script:SelectedObjectGeneration) -and ([string]$target.Guid -ieq [string]$State.Guid))
}

function Start-DomeniaLogonByDcRead {
    # Explicit gesture: one bounded read of lastLogon on each controller of the domain, for the open object only.
    param([ValidateSet('User','Computer')][string]$Kind)
    $names=Get-DomeniaLogonPanelNames $Kind
    $target=$script:DomeniaLogonTargets[$Kind]
    if(($null -eq $target) -or ($null -eq $script:SelectedObject) -or ([string]$script:SelectedObject.DN -ine [string]$target.Dn) -or ([long]$target.Generation -ne [long]$script:SelectedObjectGeneration)){
        [void](Set-DomeniaControlText $names.Text 'Rechargez la fiche avant de lire les connexions par contrôleur.')
        return
    }
    if([bool]$script:DemoMode){[void](Set-DomeniaControlText $names.Text 'Lecture par contrôleur indisponible en démonstration : aucun contrôleur réel.');return}
    $state=[pscustomobject]@{Kind=$Kind;Guid=[string]$target.Guid;Dn=[string]$target.Dn;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration}
    $payload=[pscustomobject]@{ObjectGuid=[string]$target.Guid;MaxControllers=50;BudgetSeconds=75}
    [void](Set-DomeniaControlText $names.Text 'Lecture de lastLogon sur chaque contrôleur du domaine… (50 contrôleurs au plus ; aucun nʼest plus interrogé après 75 secondes)')
    try{
        $job=Start-UiTask -Name 'Connexions par contrôleur' -OperationId 'LogonByDcRead' -Code (Get-DomeniaLogonByDcWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaLogonByDcRead' -ErrorHandler 'Fail-DomeniaLogonByDcRead' -DisableControls @($names.Button) -TimeoutSeconds 150 -TaskClass 'Explicit'
        if(-not $job){throw 'Lecture non admise par le moteur.'}
    }catch{[void](Set-DomeniaControlText $names.Text ('Lecture par contrôleur non lancée : '+$_.Exception.Message))}
}

function Complete-DomeniaLogonByDcRead {
    param($Result,$State)
    if(-not (Test-DomeniaLogonTargetCurrent $State)){return}
    $names=Get-DomeniaLogonPanelNames ([string]$State.Kind)
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('ObjectGuid','Controllers','KnownCount')
        if(($null -eq $r) -or ([string]$r.ObjectGuid -ine [string]$State.Guid)){throw 'Résultat absent ou provenant dʼun autre objet.'}
        $target=$script:DomeniaLogonTargets[[string]$State.Kind]
        $interval=Get-DomeniaLogonSyncInterval -Value ([string]$r.IntervalValue) -ReadState ([string]$r.IntervalState)
        $merge=Merge-DomeniaLogonReadings -Readings @($r.Controllers) -KnownCount ([int]$r.KnownCount) -ListTruncated ([bool]$r.ListTruncated) -LastLogonTimestamp $target.LastLogonTimestamp
        $observed=ConvertTo-DomeniaUtcDate ([string]$r.ObservedUtc)
        # The approximate activity is explained again with the interval read on the domain, then the exact readings.
        $summary=Get-DomeniaLogonActivitySummary -LastLogonTimestamp $target.LastLogonTimestamp -Interval $interval -NowUtc ([datetime]::UtcNow)
        $head='Lecture par contrôleur du '+$(if($null -ne $observed){$observed.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{'moment'})+'. '
        [void](Set-DomeniaControlText $names.Text ([string]$summary.Text+[Environment]::NewLine+$head+(Format-DomeniaLogonReadingsText -Merge $merge -Interval $interval)))
    }catch{[void](Set-DomeniaControlText $names.Text ('Lecture par contrôleur non exploitable : '+$_.Exception.Message))}
}

function Fail-DomeniaLogonByDcRead {
    param($Message,$State)
    if(-not (Test-DomeniaLogonTargetCurrent $State)){return}
    $names=Get-DomeniaLogonPanelNames ([string]$State.Kind)
    [void](Set-DomeniaControlText $names.Text ('Lecture par contrôleur impossible : '+[string]$Message+' Aucune conclusion sur les connexions.'))
}
