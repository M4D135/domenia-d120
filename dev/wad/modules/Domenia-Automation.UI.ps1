# Point 139: « Dossier hors ligne » of the Atelier. Explicit gesture only; the OfflineDossier worker calls the local
# automation interface (wad\Domenia-Automate.ps1) which reads the local base read-only and writes a new dated folder in
# the Exports area. No network, no directory bind, no credential; the perimeter is what the operator chose on screen.
$script:DomeniaAutomationModuleRoot=$PSScriptRoot
$script:DomeniaOfflineDossierJob=$null

function Set-DomeniaOfflineDossierStatus {
    param([string]$Text)
    [void](Set-DomeniaControlText 'LblSupportOfflineStatus' $Text)
}

function Get-DomeniaOfflineDossierSections {
    # « État » and « Postes » are always written: without them the other sections cannot be read in context.
    $sections=[Collections.Generic.List[string]]::new()
    foreach($name in @('etat','postes')){$sections.Add($name)}
    foreach($pair in @(@('ChkSupportOfflineObservations','observations'),@('ChkSupportOfflineLinks','associations'),@('ChkSupportOfflineQueries','requetes'))){
        $box=Get-DomeniaControl $pair[0]
        if(($null -eq $box) -or [bool]$box.IsChecked){$sections.Add($pair[1])}
    }
    return ,$sections.ToArray()
}

function Start-DomeniaOfflineDossier {
    # Point 139: one dossier at a time, for the perimeter chosen in « Périmètre du dossier ».
    # A dossier of a former session never blocks this one: its late answer is dropped by Test-DomeniaOfflineDossierState.
    if(($null -ne $script:DomeniaOfflineDossierJob) -and ([long]$script:DomeniaOfflineDossierJob.Epoch -eq [long]$script:SessionEpoch)){Set-DomeniaOfflineDossierStatus 'Un dossier est déjà en préparation : attendez sa fin.';return}
    $combo=Get-DomeniaControl 'CmbSupportOfflineScope'
    $scope='Selected'
    if(($null -ne $combo) -and ($null -ne $combo.SelectedItem)){$tag=[string](Get-DomeniaMember $combo.SelectedItem 'Tag' '');if($tag -in @('Selected','Displayed','Branch')){$scope=$tag}}
    $grid=Get-DomeniaControl 'DgObjects'
    $rows=@();if($null -ne $grid){$rows=@($grid.Items)}
    $perimeter=Get-DomeniaOfflineDossierPerimeter -Scope $scope -SelectedObject $script:SelectedObject -DisplayedRows $rows -BranchDn ([string]$script:SelectedBranchDn) -DomainDn ([string](Get-DomeniaMember $script:Conn 'BaseDn' ''))
    if(-not $perimeter.Valid){Set-DomeniaOfflineDossierStatus ([string]$perimeter.Error);return}
    $database=Get-DomeniaLocalDatabasePathForRead
    if(-not [string]$database){Set-DomeniaOfflineDossierStatus 'Aucune base locale active : connectez-vous à un domaine avant de préparer un dossier.';return}
    $sections=Get-DomeniaOfflineDossierSections
    $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Epoch=[long]$script:SessionEpoch;BaseDn=[string](Get-DomeniaMember $script:Conn 'BaseDn' '');Label=[string]$perimeter.Label;Truncated=[bool]$perimeter.Truncated}
    $payload=[pscustomobject]@{ScriptPath=(Join-Path (Split-Path -Parent $script:DomeniaAutomationModuleRoot) 'Domenia-Automate.ps1');DatabasePath=[string]$database;OutputPath=(Get-DomeniaExportDirectory);OrganizationalUnit=[string]$perimeter.OrganizationalUnit;Guids=@($perimeter.Guids);Sections=$sections;Limit=[int](Get-DomeniaAutomationLimits).DefaultRows;Build=[string]$script:MasterBuild}
    try{
        $job=Start-UiTask -Name ('Dossier hors ligne : '+[string]$perimeter.Label) -OperationId 'OfflineDossier' -Code (Get-DomeniaOfflineDossierWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaOfflineDossier' -ErrorHandler 'Fail-DomeniaOfflineDossier' -TimeoutSeconds 300 -TaskClass 'Explicit' -DisableControls @('BtnSupportOfflineDossier')
        if(-not $job){throw 'Préparation non admise par le moteur.'}
        $script:DomeniaOfflineDossierJob=$state
        Set-DomeniaOfflineDossierStatus ('Préparation du dossier ('+[string]$perimeter.Label+') : lecture seule de la base locale, sans accès réseau…')
    }catch{
        $script:DomeniaOfflineDossierJob=$null
        Set-DomeniaOfflineDossierStatus ('Dossier hors ligne non produit : '+[string]$_.Exception.Message)
    }
}

function Test-DomeniaOfflineDossierState {
    # The answer of the running dossier ends it in every case; it is shown only for the same session and domain.
    param($State)
    $current=$script:DomeniaOfflineDossierJob
    if(($null -eq $State) -or ($null -eq $current) -or ([string]$current.Id -cne [string]$State.Id)){return $false}
    $script:DomeniaOfflineDossierJob=$null
    return (([long]$State.Epoch -eq [long]$script:SessionEpoch) -and ([string]$State.BaseDn -ieq [string](Get-DomeniaMember $script:Conn 'BaseDn' '')))
}

function Complete-DomeniaOfflineDossier {
    param($Result,$State)
    if(-not (Test-DomeniaOfflineDossierState $State)){return}
    $answer=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Path','Files','Sections')
    if(($null -eq $answer) -or (-not [string]$answer.Path)){Set-DomeniaOfflineDossierStatus 'Dossier hors ligne non confirmé par le moteur : vérifiez le dossier Exports avant de le transmettre.';return}
    $parts=@(@($answer.Sections)|ForEach-Object{[string]$_.Section+' '+[string]$_.Elements+$(if([bool]$_.Tronque){' (limite atteinte)'}else{''})})
    $text='Dossier hors ligne prêt ('+[string]$State.Label+') : '+($parts -join ', ')+'. Empreintes dans SHA256SUMS.txt ; secrets exclus (liste dans manifeste.json).'
    if([bool]$State.Truncated){$text+=' Postes affichés limités au périmètre maximal.'}
    Set-DomeniaOfflineDossierStatus $text
    Write-AppLog ('Dossier hors ligne écrit : '+[string]$answer.Path) 'INFO'
    Set-Status ('Dossier hors ligne : '+[string]$answer.Path)
    [void](Show-DomeniaPageBanner -Kind Success -Message $text -ActionText 'Ouvrir le dossier' -ActionPath ([string]$answer.Path))
}

function Fail-DomeniaOfflineDossier {
    param($Message,$State)
    if(-not (Test-DomeniaOfflineDossierState $State)){return}
    $detail=([string]$Message).Trim();if(-not $detail){$detail='erreur inconnue'}
    Set-DomeniaOfflineDossierStatus ('Dossier hors ligne non produit : '+$detail+' Aucun dossier final nʼest créé.')
    Write-AppLog ('Dossier hors ligne non produit : '+$detail) 'WARN'
}
