function Start-DomeniaDocumentTask {
    param([string]$Action,[string]$Path,[string]$Text='',[string]$Slot='')
    if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -eq 'DocumentStore'}).Count){throw 'Un document est deja en lecture ou enregistrement.'}
    Start-UiTask -Name 'Document local choisi' -OperationId 'DocumentStore' -Code (Get-DomeniaDocumentWorkerCode) -Payload ([pscustomobject]@{Action=$Action;Path=$Path;Text=$Text}) -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;Action=$Action;Slot=$Slot;Domain=[string]$script:Conn.BaseDn}) -SuccessHandler 'Complete-DomeniaDocumentTask' -ErrorHandler 'Fail-DomeniaDocumentTask' -NonCancellable -TimeoutSeconds 30 | Out-Null
}
function Complete-DomeniaDocumentTask {
    param($Result,$State)
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Saved','Path','Content')
    if($null -eq $r){throw 'Lecture ou enregistrement du document non confirme.'}
    if($State.Epoch -ne $script:SessionEpoch){return}
    if($State.Action -eq 'Read'){
        $value=$r.Content|ConvertFrom-Json
        [void](Assert-DomeniaContractFormat -Format ([string](Get-DomeniaMember $value 'Format' '')) -Family 'Domenia.Capture')
        $capture=ConvertTo-DomeniaStoredCapture $value.Capture $State.Domain
        if($State.Slot -notin @('A','B')){throw 'Emplacement de capture invalide.'}
        Sync-DomeniaSupportSession;$script:SupportState.($State.Slot)=$capture;Update-DomeniaSupportComparison
        Set-Status 'Capture historique chargee ; aucune information ne devient une verification AD actuelle.'
    }elseif($r.Saved){Set-Status ('Document enregistre : '+$r.Path)}else{throw 'Enregistrement non confirme.'}
}
function Fail-DomeniaDocumentTask {
    param($Message,$State)
    Write-AppLog ('Document non confirme : '+$Message) 'WARN'
    Set-Status 'Document non confirme. Verifiez le fichier choisi ; les sources et la base ne sont pas supprimees.' 'WARN'
}
function Use-DomeniaCaptureFile {
    param([ValidateSet('Read','Write')][string]$Action)
    Sync-DomeniaSupportSession
    $combo=Get-DomeniaControl 'CmbSupportFileSlot';$slot=[string]$combo.SelectedItem.Content
    if($slot -notin @('A','B')){$slot='A'}
    if($Action -eq 'Write'){
        $capture=$script:SupportState.$slot;if($null -eq $capture){throw 'Capturez une fiche dans cet emplacement avant de l enregistrer.'}
        $clean=ConvertTo-DomeniaStoredCapture $capture ([string]$script:Conn.BaseDn)
        $text=[pscustomobject]@{Format='Domenia.Capture.1';Capture=$clean}|ConvertTo-Json -Depth 8
        if(-not (Confirm-Action 'Enregistrer cette capture historique ? Elle contient des noms et appartenances internes, pas les champs secrets dedies. Choisissez un dossier protege.')){return}
        $dialog=(New-DomeniaFileRequest -Mode Save);$dialog.FileName='Domenia-Capture-'+$slot+'.json';$dialog.OverwritePrompt=$true
    }else{$dialog=(New-DomeniaFileRequest -Mode Open);$dialog.CheckFileExists=$true}
    $dialog.Filter='Capture Domenia (*.json)|*.json';$dialog.Title='Capture historique '+$slot
    if($dialog.ShowDialog($script:Window) -ne $true){return}
    Start-DomeniaDocumentTask -Action $Action -Path $dialog.FileName -Text $text -Slot $slot
}
function Export-DomeniaTechnicalDossier {
    # W13 (point 124): redacted diagnostic (New-DomeniaRedactedDiagnostic). The operator reads exactly what will be
    # written, and what is never included, then confirms and chooses a local file. Nothing is sent anywhere.
    # Point 145: the compatibility of this workstation (versions and statuses only) is part of the diagnostic.
    $session=New-DomeniaSessionDiagnostic
    [void](Show-DomeniaDialog -Title 'Aperçu du diagnostic expurgé' -Message ([string]$session.Preview) -Details ([string]$session.Json))
    if(-not (Confirm-Action 'Enregistrer exactement ce diagnostic dans un fichier local ? Aucun envoi automatique.')){return}
    $d=(New-DomeniaFileRequest -Mode Save);$d.Filter='Diagnostic Domenia (*.json)|*.json';$d.FileName='Domenia-Diagnostic.json';$d.OverwritePrompt=$true
    if($d.ShowDialog($script:Window) -eq $true){Start-DomeniaDocumentTask -Action Write -Path $d.FileName -Text ([string]$session.Json)}
}
