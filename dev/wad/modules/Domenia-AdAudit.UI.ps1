# Audit AD view (points 102 to 109): Outils > Audit AD. Loaded from Domenia-AdAudit.xaml the first time its tab
# is chosen (model: Initialize-DomeniaQueryView). Every read starts on a click, runs in a pinned worker of
# Domenia-AdAudit.Worker.ps1 and is applied only when the session, the selection generation and the target are the
# ones it was started for. What a reading proves is decided in Domenia-AdAudit.Model.ps1.
$script:DomeniaAdAuditModuleRoot=$PSScriptRoot
$script:AdAuditView=$null
$script:AdAuditTarget=$null
$script:AdAuditData=$null

function Register-DomeniaAdAuditTool {
    # Called once by Wire-Events. The view is built the first time the tab Outils > Audit AD is chosen.
    $tabs=Get-DomeniaControl 'ApplicationToolTabs'
    if(($null -eq $tabs) -or ($null -eq (Get-DomeniaControl 'WsAdAudit'))){return}
    $tabs.Add_SelectionChanged({
        param($sender,$eventArgs)
        # SelectionChanged is routed: the inner tab controls of the view raise it too.
        if(($null -ne $eventArgs) -and ($eventArgs.OriginalSource -ne $sender)){return}
        if($sender.SelectedItem -eq (Get-DomeniaControl 'WsAdAudit')){Invoke-DomeniaSafeUiAction -Operation 'Audit AD' -Action {Show-DomeniaAdAuditTool} -NoPopup}
    })
}

function Show-DomeniaAdAuditTool {
    Initialize-DomeniaAdAuditView
    if($null -eq $script:AdAuditView){return}
    Sync-DomeniaAdAuditTarget
    Update-DomeniaAdAuditScopeLabel
}

function Initialize-DomeniaAdAuditView {
    $tab=Get-DomeniaControl 'WsAdAudit'
    if(($null -eq $tab) -or ($null -ne $script:AdAuditView)){return}
    [xml]$document=[IO.File]::ReadAllText((Join-Path $script:DomeniaAdAuditModuleRoot 'Domenia-AdAudit.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $controls=@{}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if(-not $name){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de contrôle déjà présent : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Contrôle de lʼaudit AD introuvable : '+$name)}
        $controls[$name]=$control
    }
    foreach($name in $controls.Keys){$script:Ctrl[$name]=$controls[$name]}
    $tab.Content=$view
    $script:AdAuditView=$view
    Reset-DomeniaAdAuditData
    Register-DomeniaAdAuditEvents
    # Coming back to Outils with this tab already chosen raises no SelectionChanged: the view itself follows.
    $view.Add_IsVisibleChanged({
        param($sender,$eventArgs)
        if([bool]$sender.IsVisible){Invoke-DomeniaSafeUiAction -Operation 'Audit AD' -Action {Sync-DomeniaAdAuditTarget;Update-DomeniaAdAuditScopeLabel} -NoPopup}
    })
    # Newly attached controls receive the current compact or zoomed layout.
    $script:UxLayoutSignature=''
    if($null -ne (Get-Command Update-DomeniaUxLayout -CommandType Function -ErrorAction SilentlyContinue)){Update-DomeniaUxLayout}
}

function Register-DomeniaAdAuditEvents {
    # Named functions only: no closure over a variable that would expire.
    (Get-DomeniaControl 'BtnAdAuditCopy').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Copier lʼaudit AD' -Action {Copy-DomeniaAdAuditView}})
    (Get-DomeniaControl 'BtnAdAuditUseSelection').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Audit AD' -Action {Sync-DomeniaAdAuditTarget -Force}})
    (Get-DomeniaControl 'BtnAdAuditPolicy').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Stratégie de mot de passe' -Action {Start-DomeniaAdAuditPolicyRead}})
    (Get-DomeniaControl 'BtnAdAuditGroups').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Appartenances imbriquées' -Action {Start-DomeniaAdAuditGroupRead}})
    (Get-DomeniaControl 'BtnAdAuditGroupConfirm').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Confirmation dʼappartenance' -Action {Start-DomeniaAdAuditGroupConfirm}})
    (Get-DomeniaControl 'CmbAdAuditGroupTarget').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Appartenances imbriquées' -Action {Update-DomeniaAdAuditGroupPath} -NoPopup})
    (Get-DomeniaControl 'BtnAdAuditAcl').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Délégations' -Action {Start-DomeniaAdAuditAclRead}})
    (Get-DomeniaControl 'BtnAdAuditAclToken').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Groupes du bénéficiaire' -Action {Start-DomeniaAdAuditTokenRead}})
    (Get-DomeniaControl 'ChkAdAuditAclExplicit').Add_Checked({Invoke-DomeniaSafeUiAction -Operation 'Délégations' -Action {Update-DomeniaAdAuditAclGrid} -NoPopup})
    (Get-DomeniaControl 'ChkAdAuditAclExplicit').Add_Unchecked({Invoke-DomeniaSafeUiAction -Operation 'Délégations' -Action {Update-DomeniaAdAuditAclGrid} -NoPopup})
    (Get-DomeniaControl 'TxtAdAuditAclFilter').Add_TextChanged({Invoke-DomeniaSafeUiAction -Operation 'Délégations' -Action {Update-DomeniaAdAuditAclGrid} -NoPopup})
    (Get-DomeniaControl 'DgAdAuditAcl').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Estimation des droits' -Action {Update-DomeniaAdAuditEstimate} -NoPopup})
    (Get-DomeniaControl 'BtnAdAuditGpoLinks').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Liens GPO' -Action {Start-DomeniaAdAuditGpoLinks}})
    (Get-DomeniaControl 'BtnAdAuditGpoApplied').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Résultat GPO du poste' -Action {Start-DomeniaAdAuditGpoApplied}})
    (Get-DomeniaControl 'BtnAdAuditMachineIdentity').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Identité du poste' -Action {Start-DomeniaAdAuditMachineIdentity}})
    (Get-DomeniaControl 'BtnAdAuditHistory').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Historique des associations' -Action {Start-DomeniaAdAuditHistoryRead}})
    (Get-DomeniaControl 'BtnAdAuditDcList').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Contrôleurs du domaine' -Action {Start-DomeniaAdAuditDcList}})
    (Get-DomeniaControl 'BtnAdAuditDcProbe').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Diagnostic des contrôleurs' -Action {Start-DomeniaAdAuditDcProbe}})
    (Get-DomeniaControl 'BtnAdAuditDcServices').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Services des contrôleurs' -Action {Start-DomeniaAdAuditDcServices}})
    (Get-DomeniaControl 'BtnAdAuditScan').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Identités de lʼOU' -Action {Start-DomeniaAdAuditScan}})
}

function Get-DomeniaAdAuditTimeText {
    param($Value)
    $utc=ConvertTo-DomeniaUtcDate $Value
    if($null -eq $utc){return 'heure inconnue'}
    return $utc.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')
}

function Reset-DomeniaAdAuditData {
    # A new session or a new target starts empty: nothing read for another account or object is kept.
    $script:AdAuditData=[pscustomobject]@{
        Epoch=[long]$script:SessionEpoch;GroupView=$null;Acl=$null;AclView=$null;Token=$null;GpoLinks=$null;GpoRsop=$null
        DcList=@();DcPdc='';DcRequest=0L;ScanRequest=0L;ScanRead=$null;ScanIndex=$null
    }
    $script:AdAuditTarget=$null
    if($null -eq $script:AdAuditView){return}
    Clear-DomeniaAdAuditObjectResults
    foreach($grid in @('DgAdAuditDcList','DgAdAuditHealth','DgAdAuditRepl','DgAdAuditServices','DgAdAuditDcFacts','DgAdAuditScan')){[void](Set-DomeniaItemsSource $grid @())}
    [void](Set-DomeniaControlText 'LblAdAuditDc' 'Listez les contrôleurs, choisissez-en jusquʼà 10, puis lancez le diagnostic.')
    [void](Set-DomeniaControlText 'LblAdAuditScan' 'Analyse à la demande. Chaque constat est à revoir : rien nʼest fusionné, renommé ni supprimé.')
}

function Clear-DomeniaAdAuditObjectResults {
    $script:AdAuditData.GroupView=$null;$script:AdAuditData.Acl=$null;$script:AdAuditData.AclView=$null;$script:AdAuditData.Token=$null
    $script:AdAuditData.GpoLinks=$null;$script:AdAuditData.GpoRsop=$null
    foreach($grid in @('DgAdAuditPolicy','DgAdAuditGroups','DgAdAuditAcl','DgAdAuditAclEstimate','DgAdAuditGpo','DgAdAuditGpoFacts','DgAdAuditMachineIdentity','DgAdAuditHistory','CmbAdAuditGroupTarget')){[void](Set-DomeniaItemsSource $grid @())}
    [void](Set-DomeniaControlText 'LblAdAuditPolicy' 'Lecture à la demande pour un compte utilisateur.')
    [void](Set-DomeniaControlText 'LblAdAuditGroups' 'Lecture à la demande pour un utilisateur, un poste ou un groupe.')
    [void](Set-DomeniaControlText 'LblAdAuditGroupPath' 'Lisez dʼabord les appartenances, puis choisissez un groupe.')
    [void](Set-DomeniaControlText 'LblAdAuditAcl' 'Lecture à la demande pour lʼobjet sélectionné.')
    [void](Set-DomeniaControlText 'LblAdAuditAclEstimate' 'Sélectionnez une entrée pour estimer les droits de son bénéficiaire.')
    [void](Set-DomeniaControlText 'LblAdAuditGpo' 'Lecture à la demande pour un utilisateur, un poste ou une unité dʼorganisation.')
    [void](Set-DomeniaControlText 'LblAdAuditMachineIdentity' 'Lecture à la demande pour un poste.')
    [void](Set-DomeniaControlText 'LblAdAuditHistory' 'Historique non lu.')
}

function Sync-DomeniaAdAuditTarget {
    # The target follows the fiche: a new object or a new session clears what was read for the previous one.
    param([switch]$Force)
    if($null -eq $script:AdAuditView){return}
    if(($null -eq $script:AdAuditData) -or ([long]$script:AdAuditData.Epoch -ne [long]$script:SessionEpoch)){Reset-DomeniaAdAuditData}
    $selected=$script:SelectedObject
    $generation=[long]$script:SelectedObjectGeneration
    $current=$script:AdAuditTarget
    $selectedDn=if($null -ne $selected){[string](Get-DomeniaMember $selected 'DN' '')}else{''}
    $same=(($null -ne $current) -and ($selectedDn -ieq [string]$current.Dn) -and ([long]$current.Generation -eq $generation))
    if((-not $same) -and (($null -ne $current) -or $selectedDn)){
        $script:AdAuditTarget=New-DomeniaAdAuditTarget -Selected $selected -Generation $generation -Epoch ([long]$script:SessionEpoch)
        Clear-DomeniaAdAuditObjectResults
    }
    elseif($Force -and $same){Set-Status 'Audit AD : la cible est déjà lʼobjet de la fiche ouverte.'}
    Update-DomeniaAdAuditTargetUi
    Update-DomeniaAdAuditRelationOverview
}

function Update-DomeniaAdAuditTargetUi {
    $target=$script:AdAuditTarget
    $type=''
    if($null -eq $target){[void](Set-DomeniaControlText 'LblAdAuditTarget' 'Aucun objet : ouvrez une fiche depuis Rechercher, puis revenez ici.')}
    else{
        $type=[string]$target.Type
        [void](Set-DomeniaControlText 'LblAdAuditTarget' ($type+' · '+[string]$target.Name+' · '+[string]$target.Dn))
    }
    foreach($pair in @(@('BtnAdAuditPolicy','Policy','LblAdAuditPolicy'),@('BtnAdAuditGroups','Groups','LblAdAuditGroups'),@('BtnAdAuditAcl','Acl','LblAdAuditAcl'),@('BtnAdAuditGpoLinks','GpoLinks','LblAdAuditGpo'),@('BtnAdAuditGpoApplied','GpoApplied',''),@('BtnAdAuditMachineIdentity','MachineIdentity','LblAdAuditMachineIdentity'),@('BtnAdAuditHistory','History','LblAdAuditHistory'))){
        $availability=Get-DomeniaAdAuditAvailability -Type $type -Check $pair[1]
        [void](Set-DomeniaControlEnabled $pair[0] ([bool]$availability.Allowed))
        if((-not $availability.Allowed) -and $pair[2]){[void](Set-DomeniaControlText $pair[2] ([string]$availability.Reason))}
    }
    [void](Set-DomeniaControlEnabled 'BtnAdAuditGroupConfirm' ($null -ne $script:AdAuditData.GroupView))
    $selectedAce=$null
    $aclGrid=Get-DomeniaControl 'DgAdAuditAcl'
    if($null -ne $aclGrid){$selectedAce=$aclGrid.SelectedItem}
    [void](Set-DomeniaControlEnabled 'BtnAdAuditAclToken' (($null -ne $selectedAce) -and ([string]$selectedAce.Sid -match '^S-1-5-21-')))
}

function Get-DomeniaAdAuditCheckedTarget {
    # The current target when the check applies to it; otherwise the reason is shown and nothing starts.
    param([string]$Check,[string]$Label)
    Sync-DomeniaAdAuditTarget
    $target=$script:AdAuditTarget
    $type=if($null -ne $target){[string]$target.Type}else{''}
    $availability=Get-DomeniaAdAuditAvailability -Type $type -Check $Check
    if(-not $availability.Allowed){
        if($Label){[void](Set-DomeniaControlText $Label ([string]$availability.Reason))}
        Set-Status ('Audit AD : '+[string]$availability.Reason) 'WARN'
        return $null
    }
    return $target
}

function New-DomeniaAdAuditState {
    param($Target,[string]$Kind,$Extra=$null)
    return [pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=[long]$Target.Generation;Dn=[string]$Target.Dn;Kind=$Kind;Extra=$Extra}
}

function Test-DomeniaAdAuditCallback {
    param($State)
    return (Test-DomeniaAdAuditStateCurrent -State $State -Target $script:AdAuditTarget -Epoch ([long]$script:SessionEpoch))
}

function Invoke-DomeniaAdAuditStart {
    # A read that cannot even start (engine closing, operation not registered) leaves no "Lecture…" text behind.
    param([string]$Label,[scriptblock]$Start)
    try{[void](& $Start)}
    catch{
        if($Label){[void](Set-DomeniaControlText $Label ('Lecture non lancée : '+[string]$_.Exception.Message))}
        throw
    }
}

function Get-DomeniaAdAuditReader {
    return [string](Get-DomeniaMember $script:Conn 'User' '')
}

# ---------------------------------------------------------------- point 102
function Start-DomeniaAdAuditPolicyRead {
    $target=Get-DomeniaAdAuditCheckedTarget 'Policy' 'LblAdAuditPolicy'
    if($null -eq $target){return}
    [void](Set-DomeniaControlText 'LblAdAuditPolicy' 'Lecture de la stratégie applicable à ce compte…')
    Invoke-DomeniaAdAuditStart 'LblAdAuditPolicy' {Start-UiTask -Name ('Audit AD : stratégie de mot de passe de '+[string]$target.Name) -OperationId 'PasswordPolicyRead' -Code (Get-DomeniaPasswordPolicyReadWorkerCode) -Payload ([pscustomobject]@{Dn=[string]$target.Dn}) -CallbackState (New-DomeniaAdAuditState $target 'Policy') -ReplaceKey 'adaudit-policy' -DisableControls @('BtnAdAuditPolicy') -TimeoutSeconds 45 -SuccessHandler 'Complete-DomeniaAdAuditPolicyRead' -ErrorHandler 'Fail-DomeniaAdAuditPolicyRead' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditPolicyRead {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Dn','User','PsoVisibleCount')
    if(($null -eq $read) -or ([string]$read.Dn -ine [string]$State.Dn)){[void](Set-DomeniaControlText 'LblAdAuditPolicy' 'Résultat absent ou provenant dʼun autre objet : rien nʼest affiché.');return}
    $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -Reader (Get-DomeniaAdAuditReader) -NowUtc ([datetime]::UtcNow)
    [void](Set-DomeniaItemsSource 'DgAdAuditPolicy' @(ConvertTo-DomeniaAdAuditFactRows $view.Facts))
    [void](Set-DomeniaControlText 'LblAdAuditPolicy' ([string]$view.Summary+' Lu sur '+[string]$read.Server+' le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)+'. Aucun mot de passe nʼest lu.'))
    Update-DomeniaAdAuditTargetUi
}

function Fail-DomeniaAdAuditPolicyRead {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditPolicy' ('Lecture de la stratégie impossible : '+[string]$Message))
    Update-DomeniaAdAuditTargetUi
}

# ---------------------------------------------------------------- point 103
function Start-DomeniaAdAuditGroupRead {
    $target=Get-DomeniaAdAuditCheckedTarget 'Groups' 'LblAdAuditGroups'
    if($null -eq $target){return}
    [void](Set-DomeniaControlText 'LblAdAuditGroups' 'Lecture des appartenances imbriquées (2 000 groupes, 16 niveaux, 10 secondes au plus)…')
    $payload=[pscustomobject]@{Dn=[string]$target.Dn;Mode='Expand';MaxNodes=2000;MaxDepth=16;Seconds=10;TargetDn=''}
    Invoke-DomeniaAdAuditStart 'LblAdAuditGroups' {Start-UiTask -Name ('Audit AD : groupes de '+[string]$target.Name) -OperationId 'GroupPathRead' -Code (Get-DomeniaGroupPathReadWorkerCode) -Payload $payload -CallbackState (New-DomeniaAdAuditState $target 'Groups') -ReplaceKey 'adaudit-groups' -DisableControls @('BtnAdAuditGroups') -TimeoutSeconds 60 -SuccessHandler 'Complete-DomeniaAdAuditGroupRead' -ErrorHandler 'Fail-DomeniaAdAuditGroupRead' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditGroupRead {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Dn','Nodes','Unread')
    if(($null -eq $read) -or ([string]$read.Dn -ine [string]$State.Dn)){[void](Set-DomeniaControlText 'LblAdAuditGroups' 'Résultat absent ou provenant dʼun autre objet : rien nʼest affiché.');return}
    $view=ConvertTo-DomeniaNestedGroupView -Read $read
    $script:AdAuditData.GroupView=$view
    [void](Set-DomeniaItemsSource 'DgAdAuditGroups' @($view.Rows))
    $choices=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in @($view.Rows)){$choices.Add($row)}
    if([string]$view.PrimaryGroupDn){$choices.Add([pscustomobject]@{Groupe=((Get-DomeniaCnFromDn ([string]$view.PrimaryGroupDn))+' (groupe principal)');Dn=[string]$view.PrimaryGroupDn})}
    [void](Set-DomeniaItemsSource 'CmbAdAuditGroupTarget' $choices.ToArray())
    [void](Set-DomeniaControlText 'LblAdAuditGroups' ([string]$view.Summary+[Environment]::NewLine+'Lu sur '+[string]$read.Server+' le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)+' en '+[string]$read.ElapsedMs+' ms.'))
    [void](Set-DomeniaControlText 'LblAdAuditGroupPath' 'Choisissez un groupe pour voir le chemin dʼappartenance.')
    Update-DomeniaAdAuditTargetUi
}

function Fail-DomeniaAdAuditGroupRead {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditGroups' ('Lecture des appartenances impossible : '+[string]$Message))
    Update-DomeniaAdAuditTargetUi
}

function Update-DomeniaAdAuditGroupPath {
    param($ServerAnswer=$null,[string]$ServerError='')
    $choice=(Get-DomeniaControl 'CmbAdAuditGroupTarget').SelectedItem
    if(($null -eq $choice) -or ($null -eq $script:AdAuditData.GroupView)){return}
    $explanation=Get-DomeniaGroupMembershipExplanation -View $script:AdAuditData.GroupView -TargetDn ([string]$choice.Dn) -ServerAnswer $ServerAnswer -ServerError $ServerError
    [void](Set-DomeniaControlText 'LblAdAuditGroupPath' ([string]$explanation.Text))
}

function Start-DomeniaAdAuditGroupConfirm {
    $target=Get-DomeniaAdAuditCheckedTarget 'Groups' 'LblAdAuditGroupPath'
    if($null -eq $target){return}
    $choice=(Get-DomeniaControl 'CmbAdAuditGroupTarget').SelectedItem
    if($null -eq $choice){[void](Set-DomeniaControlText 'LblAdAuditGroupPath' 'Choisissez dʼabord un groupe dans la liste.');return}
    [void](Set-DomeniaControlText 'LblAdAuditGroupPath' ('Question posée au contrôleur pour '+[string]$choice.Groupe+'…'))
    $payload=[pscustomobject]@{Dn=[string]$target.Dn;Mode='Confirm';MaxNodes=2000;MaxDepth=16;Seconds=10;TargetDn=[string]$choice.Dn}
    Invoke-DomeniaAdAuditStart 'LblAdAuditGroupPath' {Start-UiTask -Name ('Audit AD : appartenance de '+[string]$target.Name) -OperationId 'GroupPathRead' -Code (Get-DomeniaGroupPathReadWorkerCode) -Payload $payload -CallbackState (New-DomeniaAdAuditState $target 'GroupConfirm' ([string]$choice.Dn)) -ReplaceKey 'adaudit-group-confirm' -DisableControls @('BtnAdAuditGroupConfirm') -TimeoutSeconds 45 -SuccessHandler 'Complete-DomeniaAdAuditGroupConfirm' -ErrorHandler 'Fail-DomeniaAdAuditGroupConfirm' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditGroupConfirm {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Dn','TargetDn','ServerAnswer')
    $choice=(Get-DomeniaControl 'CmbAdAuditGroupTarget').SelectedItem
    if(($null -eq $read) -or ([string]$read.TargetDn -ine [string]$State.Extra) -or ($null -eq $choice) -or ([string]$choice.Dn -ine [string]$State.Extra)){return}
    Update-DomeniaAdAuditGroupPath -ServerAnswer $read.ServerAnswer -ServerError ([string]$read.ServerError)
    Update-DomeniaAdAuditTargetUi
}

function Fail-DomeniaAdAuditGroupConfirm {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    Update-DomeniaAdAuditGroupPath -ServerError ([string]$Message)
    Update-DomeniaAdAuditTargetUi
}

# ---------------------------------------------------------------- point 104
function Start-DomeniaAdAuditAclRead {
    $target=Get-DomeniaAdAuditCheckedTarget 'Acl' 'LblAdAuditAcl'
    if($null -eq $target){return}
    [void](Set-DomeniaControlText 'LblAdAuditAcl' 'Lecture de la liste de contrôle dʼaccès de lʼobjet…')
    Invoke-DomeniaAdAuditStart 'LblAdAuditAcl' {Start-UiTask -Name ('Audit AD : délégations de '+[string]$target.Name) -OperationId 'DelegationRead' -Code (Get-DomeniaDelegationReadWorkerCode) -Payload ([pscustomobject]@{Action='Acl';Dn=[string]$target.Dn;MaxAces=1000}) -CallbackState (New-DomeniaAdAuditState $target 'Acl') -ReplaceKey 'adaudit-acl' -DisableControls @('BtnAdAuditAcl') -TimeoutSeconds 60 -SuccessHandler 'Complete-DomeniaAdAuditAclRead' -ErrorHandler 'Fail-DomeniaAdAuditAclRead' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditAclRead {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Action','Dn','Aces')
    if(($null -eq $read) -or ([string]$read.Dn -ine [string]$State.Dn)){[void](Set-DomeniaControlText 'LblAdAuditAcl' 'Résultat absent ou provenant dʼun autre objet : rien nʼest affiché.');return}
    $script:AdAuditData.Acl=$read
    $script:AdAuditData.AclView=ConvertTo-DomeniaDelegationView -Read $read
    $script:AdAuditData.Token=$null
    Update-DomeniaAdAuditAclGrid
    [void](Set-DomeniaControlText 'LblAdAuditAcl' ([string]$script:AdAuditData.AclView.Summary+[Environment]::NewLine+'Lu sur '+[string]$read.Server+' le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)+'.'))
    Update-DomeniaAdAuditEstimate
}

function Fail-DomeniaAdAuditAclRead {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditAcl' ('Lecture des délégations impossible : '+[string]$Message))
    Update-DomeniaAdAuditTargetUi
}

function Update-DomeniaAdAuditAclGrid {
    $view=$script:AdAuditData.AclView
    if($null -eq $view){[void](Set-DomeniaItemsSource 'DgAdAuditAcl' @());return}
    $explicit=[bool](Get-DomeniaControl 'ChkAdAuditAclExplicit').IsChecked
    $text=[string](Get-DomeniaControl 'TxtAdAuditAclFilter').Text
    [void](Set-DomeniaItemsSource 'DgAdAuditAcl' @(Select-DomeniaDelegationRows -Rows @($view.Rows) -ExplicitOnly $explicit -Text $text))
}

function Update-DomeniaAdAuditEstimate {
    $row=(Get-DomeniaControl 'DgAdAuditAcl').SelectedItem
    Update-DomeniaAdAuditTargetUi
    if(($null -eq $row) -or ($null -eq $script:AdAuditData.Acl)){
        [void](Set-DomeniaItemsSource 'DgAdAuditAclEstimate' @())
        [void](Set-DomeniaControlText 'LblAdAuditAclEstimate' 'Sélectionnez une entrée pour estimer les droits de son bénéficiaire.')
        return
    }
    $sids=New-Object 'System.Collections.Generic.List[string]'
    $sids.Add([string]$row.Sid)
    $token=$script:AdAuditData.Token
    $withGroups=(($null -ne $token) -and ([string]$token.Sid -ieq [string]$row.Sid) -and ([string]$token.State -eq 'Read'))
    if($withGroups){foreach($sid in @($token.GroupSids)){$sids.Add([string]$sid)}}
    $estimate=Get-DomeniaAccessEstimate -Aces @($script:AdAuditData.Acl.Aces) -Sids $sids.ToArray() -IncludesGroups $withGroups -Trustee ([string]$row.Beneficiaire)
    [void](Set-DomeniaItemsSource 'DgAdAuditAclEstimate' @($estimate.Rows))
    $head='Estimation pour '+[string]$estimate.Trustee+'. '
    if(($null -ne $token) -and ([string]$token.Sid -ieq [string]$row.Sid) -and ([string]$token.State -ne 'Read')){$head+='Groupes non lus : '+[string]$token.Message+' '}
    [void](Set-DomeniaControlText 'LblAdAuditAclEstimate' ($head+[string]$estimate.Limits))
}

function Start-DomeniaAdAuditTokenRead {
    $target=Get-DomeniaAdAuditCheckedTarget 'Acl' 'LblAdAuditAclEstimate'
    if($null -eq $target){return}
    $row=(Get-DomeniaControl 'DgAdAuditAcl').SelectedItem
    if(($null -eq $row) -or ([string]$row.Sid -notmatch '^S-1-5-21(-\d{1,10}){4}$')){
        [void](Set-DomeniaControlText 'LblAdAuditAclEstimate' 'Les groupes se lisent pour un compte ou un groupe dʼun domaine, pas pour une identité intégrée.')
        return
    }
    [void](Set-DomeniaControlText 'LblAdAuditAclEstimate' ('Lecture des groupes de '+[string]$row.Beneficiaire+'…'))
    Invoke-DomeniaAdAuditStart 'LblAdAuditAclEstimate' {Start-UiTask -Name ('Audit AD : groupes de '+[string]$row.Beneficiaire) -OperationId 'DelegationRead' -Code (Get-DomeniaDelegationReadWorkerCode) -Payload ([pscustomobject]@{Action='Token';Sid=[string]$row.Sid}) -CallbackState (New-DomeniaAdAuditState $target 'Token' ([string]$row.Sid)) -ReplaceKey 'adaudit-token' -DisableControls @('BtnAdAuditAclToken') -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaAdAuditTokenRead' -ErrorHandler 'Fail-DomeniaAdAuditTokenRead' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditTokenRead {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Action','Sid','GroupSids')
    if(($null -eq $read) -or ([string]$read.Sid -ine [string]$State.Extra)){return}
    $script:AdAuditData.Token=$read
    Update-DomeniaAdAuditEstimate
}

function Fail-DomeniaAdAuditTokenRead {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $script:AdAuditData.Token=[pscustomobject]@{Sid=[string]$State.Extra;State='Unavailable';Message=[string]$Message;GroupSids=@()}
    Update-DomeniaAdAuditEstimate
}

# ---------------------------------------------------------------- point 105
function Start-DomeniaAdAuditGpoLinks {
    $target=Get-DomeniaAdAuditCheckedTarget 'GpoLinks' 'LblAdAuditGpo'
    if($null -eq $target){return}
    $chain=Get-DomeniaGpoContainerChain -Dn ([string]$target.Dn) -DomainDn ([string]$script:Conn.BaseDn) -Type ([string]$target.Type)
    if(@($chain).Count -eq 0){[void](Set-DomeniaControlText 'LblAdAuditGpo' 'Objet hors du domaine connecté : aucun lien à lire.');return}
    [void](Set-DomeniaControlText 'LblAdAuditGpo' ('Lecture des liens sur '+[string]@($chain).Count+' conteneur(s)…'))
    Invoke-DomeniaAdAuditStart 'LblAdAuditGpo' {Start-UiTask -Name ('Audit AD : liens GPO de '+[string]$target.Name) -OperationId 'GpoLinksRead' -Code (Get-DomeniaGpoLinksReadWorkerCode) -Payload ([pscustomobject]@{Containers=@($chain)}) -CallbackState (New-DomeniaAdAuditState $target 'GpoLinks') -ReplaceKey 'adaudit-gpo-links' -DisableControls @('BtnAdAuditGpoLinks') -TimeoutSeconds 45 -SuccessHandler 'Complete-DomeniaAdAuditGpoLinks' -ErrorHandler 'Fail-DomeniaAdAuditGpoLinks' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditGpoLinks {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Containers','Gpos')
    if($null -eq $read){[void](Set-DomeniaControlText 'LblAdAuditGpo' 'Résultat absent : rien nʼest affiché.');return}
    $script:AdAuditData.GpoLinks=$read
    Update-DomeniaAdAuditGpoView
}

function Fail-DomeniaAdAuditGpoLinks {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditGpo' ('Lecture des liens GPO impossible : '+[string]$Message))
    Update-DomeniaAdAuditTargetUi
}

function Start-DomeniaAdAuditGpoApplied {
    $target=Get-DomeniaAdAuditCheckedTarget 'GpoApplied' 'LblAdAuditGpo'
    if($null -eq $target){return}
    $computer=[string]$target.DnsHostName
    if(-not $computer){$computer=[string]$target.Name}
    [void](Set-DomeniaControlText 'LblAdAuditGpo' ('Lecture du résultat appliqué sur '+$computer+' (RSoP par CIM)…'))
    Invoke-DomeniaAdAuditStart 'LblAdAuditGpo' {Start-UiTask -Name ('Audit AD : résultat GPO de '+$computer) -OperationId 'GpoAppliedRead' -Code (Get-DomeniaGpoAppliedReadWorkerCode) -Payload ([pscustomobject]@{Computer=$computer}) -CallbackState (New-DomeniaAdAuditState $target 'GpoApplied' $computer) -ReplaceKey 'adaudit-gpo-applied' -DisableControls @('BtnAdAuditGpoApplied') -TimeoutSeconds 90 -SuccessHandler 'Complete-DomeniaAdAuditGpoApplied' -ErrorHandler 'Fail-DomeniaAdAuditGpoApplied' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditGpoApplied {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Computer','ReadStatus')
    if(($null -eq $read) -or ([string]$read.Computer -ine [string]$State.Extra)){[void](Set-DomeniaControlText 'LblAdAuditGpo' 'Résultat absent ou provenant dʼun autre poste : rien nʼest affiché.');return}
    $script:AdAuditData.GpoRsop=$read
    Update-DomeniaAdAuditGpoView
}

function Fail-DomeniaAdAuditGpoApplied {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $script:AdAuditData.GpoRsop=[pscustomobject]@{Computer=[string]$State.Extra;ReadStatus='Unavailable';Message=[string]$Message;Gpos=$null;Links=$null;ReadUtc=[datetime]::UtcNow.ToString('o')}
    Update-DomeniaAdAuditGpoView
}

function Update-DomeniaAdAuditGpoView {
    $links=$script:AdAuditData.GpoLinks
    $rsop=$script:AdAuditData.GpoRsop
    $note=''
    if($null -eq $links){$links=[pscustomobject]@{Containers=@();Gpos=@();NamesStatus='OK'};$note='Liens AD non lus : lisez les liens pour les comparer au résultat. '}
    $view=ConvertTo-DomeniaGpoAuditView -Links $links -Rsop $rsop -Reader (Get-DomeniaAdAuditReader)
    [void](Set-DomeniaItemsSource 'DgAdAuditGpo' @($view.Rows))
    [void](Set-DomeniaItemsSource 'DgAdAuditGpoFacts' @(ConvertTo-DomeniaAdAuditFactRows $view.Facts))
    $text=$note+[string]@($view.Rows).Count+' ligne(s). '
    if($null -eq $rsop){$text+='Résultat sur le poste non lu : seuls les liens sont présentés.'}
    elseif([string]$rsop.ReadStatus -ne 'OK'){$text+='Résultat sur le poste non obtenu : '+[string]$rsop.Message}
    elseif([bool]$view.AppliedProven){$text+='Résultat appliqué lu sur '+[string]$rsop.Computer+' le '+(Get-DomeniaAdAuditTimeText $rsop.ReadUtc)+'.'}
    else{$text+='Résultat lu sur '+[string]$rsop.Computer+' mais application non prouvée : '+[string]$rsop.LinksError}
    [void](Set-DomeniaControlText 'LblAdAuditGpo' $text.Trim())
    Update-DomeniaAdAuditTargetUi
}

# ---------------------------------------------------------------- point 109 : one workstation
function Start-DomeniaAdAuditMachineIdentity {
    $target=Get-DomeniaAdAuditCheckedTarget 'MachineIdentity' 'LblAdAuditMachineIdentity'
    if($null -eq $target){return}
    [void](Set-DomeniaControlText 'LblAdAuditMachineIdentity' 'Résolution DNS et lecture de lʼidentité renvoyée par le poste…')
    Invoke-DomeniaAdAuditStart 'LblAdAuditMachineIdentity' {Start-UiTask -Name ('Audit AD : identité de '+[string]$target.Name) -OperationId 'MachineIdentityRead' -Code (Get-DomeniaMachineIdentityReadWorkerCode) -Payload ([pscustomobject]@{Name=[string]$target.Name;DnsHostName=[string]$target.DnsHostName}) -CallbackState (New-DomeniaAdAuditState $target 'MachineIdentity') -ReplaceKey 'adaudit-machine' -DisableControls @('BtnAdAuditMachineIdentity') -TimeoutSeconds 60 -SuccessHandler 'Complete-DomeniaAdAuditMachineIdentity' -ErrorHandler 'Fail-DomeniaAdAuditMachineIdentity' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditMachineIdentity {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Resolution','Reported')
    if($null -eq $read){[void](Set-DomeniaControlText 'LblAdAuditMachineIdentity' 'Résultat absent : rien nʼest affiché.');return}
    $target=$script:AdAuditTarget
    $directoryName=[string]$target.Sam
    if(-not $directoryName){$directoryName=[string]$target.Name}
    $coherence=Test-DomeniaMachineIdentityCoherence -Directory ([pscustomobject]@{Name=$directoryName;DnsHostName=[string]$target.DnsHostName;Guid=[string]$target.Guid}) -Resolution $read.Resolution -Reported $read.Reported -Reader (Get-DomeniaAdAuditReader)
    [void](Set-DomeniaItemsSource 'DgAdAuditMachineIdentity' @(ConvertTo-DomeniaAdAuditFactRows $coherence.Facts))
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add([string]$coherence.Summary)
    foreach($reason in @($coherence.Reasons)){$lines.Add('• '+[string]$reason)}
    foreach($warning in @($coherence.Warnings)){$lines.Add('À vérifier : '+[string]$warning)}
    $lines.Add('Lu le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)+'. Rien nʼest attribué ni fusionné par cette vérification.')
    [void](Set-DomeniaControlText 'LblAdAuditMachineIdentity' ($lines.ToArray() -join [Environment]::NewLine))
    Update-DomeniaAdAuditTargetUi
}

function Fail-DomeniaAdAuditMachineIdentity {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditMachineIdentity' ('Vérification impossible : '+[string]$Message))
    Update-DomeniaAdAuditTargetUi
}

# ---------------------------------------------------------------- point 107
function Get-DomeniaAdAuditRelations {
    # Relations of the target kept in memory (stored ones and those of this session), never joined across GUIDs.
    $target=$script:AdAuditTarget
    if($null -eq $target){return}
    $links=@()
    if([string]$target.Type -eq 'Utilisateur'){if([string]$target.Sam){$links=@(Get-LinksForUser ([string]$target.Sam))}}
    elseif([string]$target.Type -eq 'Machine'){$links=@(Get-LinksForComputer ([string]$target.Name))}
    else{return}
    $observations=Get-DomeniaMember $script:Relations 'Observations' $null
    if($null -ne $observations){
        $subjectKey=if([string]$target.Type -eq 'Utilisateur'){ConvertTo-DomeniaRelationLoginKey ([string]$target.Sam)}else{ConvertTo-DomeniaRelationComputerKey ([string]$target.Name)}
        foreach($observation in @($observations)){
            if($null -eq $observation){continue}
            $key=if([string]$target.Type -eq 'Utilisateur'){ConvertTo-DomeniaRelationLoginKey ([string](Get-DomeniaMember $observation 'UserLogin' ''))}else{ConvertTo-DomeniaRelationComputerKey ([string](Get-DomeniaMember $observation 'Computer' ''))}
            if($subjectKey -and ($key -eq $subjectKey)){$links+=$observation}
        }
    }
    foreach($link in $links){
        if($null -eq $link){continue}
        $guid=if([string]$target.Type -eq 'Utilisateur'){[string](Get-DomeniaMember $link 'UserGuid' '')}else{[string](Get-DomeniaMember $link 'ComputerGuid' '')}
        if($guid -and [string]$target.Guid -and ($guid -ine [string]$target.Guid)){continue}
        Write-Output $link
    }
}

function Update-DomeniaAdAuditRelationOverview {
    $target=$script:AdAuditTarget
    if(($null -eq $target) -or ([string]$target.Type -notin @('Utilisateur','Machine'))){
        [void](Set-DomeniaControlText 'LblAdAuditRelationOverview' 'Sélectionnez un utilisateur ou un poste.')
        return
    }
    $overview=Get-DomeniaRelationOverview -Relations @(Get-DomeniaAdAuditRelations) -SubjectType ([string]$target.Type)
    [void](Set-DomeniaControlText 'LblAdAuditRelationOverview' ([string]$overview.Text))
}

function Start-DomeniaAdAuditHistoryRead {
    $target=Get-DomeniaAdAuditCheckedTarget 'History' 'LblAdAuditHistory'
    if($null -eq $target){return}
    $path=[string](Get-DomeniaLocalDatabasePathForRead)
    if(-not $path){[void](Set-DomeniaControlText 'LblAdAuditHistory' 'Base locale non configurée : aucun historique à lire.');return}
    $kind='Computer';$key=[string]$target.Name
    if([string]$target.Type -eq 'Utilisateur'){$kind='User';$key=[string]$target.Sam}
    if(-not $key){[void](Set-DomeniaControlText 'LblAdAuditHistory' 'Identifiant du sujet non lu : historique non recherché.');return}
    [void](Set-DomeniaControlText 'LblAdAuditHistory' 'Lecture de lʼhistorique dans la base locale…')
    Invoke-DomeniaAdAuditStart 'LblAdAuditHistory' {Start-UiTask -Name ('Audit AD : historique de '+[string]$target.Name) -OperationId 'RelationHistoryRead' -Code (Get-DomeniaRelationHistoryReadWorkerCode) -Payload ([pscustomobject]@{Kind=$kind;Key=$key;Limit=200;Path=$path;BusyTimeoutMs=250}) -CallbackState (New-DomeniaAdAuditState $target 'History' $key) -ReplaceKey 'adaudit-history' -DisableControls @('BtnAdAuditHistory') -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaAdAuditHistoryRead' -ErrorHandler 'Fail-DomeniaAdAuditHistoryRead' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditHistoryRead {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Busy','Missing')
    if(($null -eq $read) -or ([string](Get-DomeniaMember $read 'Key' '') -ine [string]$State.Extra)){[void](Set-DomeniaControlText 'LblAdAuditHistory' 'Résultat absent ou provenant dʼun autre sujet : rien nʼest affiché.');return}
    if([bool]$read.Busy){[void](Set-DomeniaControlText 'LblAdAuditHistory' 'Base locale occupée : relancez la lecture dans un instant.');return}
    if([bool]$read.Missing){[void](Set-DomeniaItemsSource 'DgAdAuditHistory' @());[void](Set-DomeniaControlText 'LblAdAuditHistory' 'Aucun historique enregistré dans la base locale de ce poste.');return}
    $rows=@(ConvertTo-DomeniaRelationHistoryRows @($read.Rows))
    [void](Set-DomeniaItemsSource 'DgAdAuditHistory' $rows)
    [void](Set-DomeniaControlText 'LblAdAuditHistory' ([string]$rows.Count+' ligne(s) affichée(s) sur '+[string]$read.Total+' enregistrée(s) dans la base locale de ce poste. La présence dans lʼhistorique ne prouve pas une session actuelle.'))
    Update-DomeniaAdAuditRelationOverview
    Update-DomeniaAdAuditTargetUi
}

function Fail-DomeniaAdAuditHistoryRead {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditCallback $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditHistory' ('Lecture de lʼhistorique impossible : '+[string]$Message))
    Update-DomeniaAdAuditTargetUi
}

# ---------------------------------------------------------------- point 108
function New-DomeniaAdAuditRequestState {
    param([string]$Kind)
    if($Kind -eq 'Scan'){$script:AdAuditData.ScanRequest=[long]$script:AdAuditData.ScanRequest+1;$request=[long]$script:AdAuditData.ScanRequest}
    else{$script:AdAuditData.DcRequest=[long]$script:AdAuditData.DcRequest+1;$request=[long]$script:AdAuditData.DcRequest}
    return [pscustomobject]@{Epoch=[long]$script:SessionEpoch;Kind=$Kind;Request=$request}
}

function Test-DomeniaAdAuditRequestCurrent {
    param($State)
    if(($null -eq $State) -or ($null -eq $script:AdAuditData)){return $false}
    if(([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([long]$script:AdAuditData.Epoch -ne [long]$script:SessionEpoch)){return $false}
    if([string]$State.Kind -eq 'Scan'){return ([long]$State.Request -eq [long]$script:AdAuditData.ScanRequest)}
    return ([long]$State.Request -eq [long]$script:AdAuditData.DcRequest)
}

function Start-DomeniaAdAuditDcList {
    Sync-DomeniaAdAuditTarget
    if(-not [string]$script:Conn.BaseDn){[void](Set-DomeniaControlText 'LblAdAuditDc' 'Connectez-vous dʼabord à un domaine.');return}
    [void](Set-DomeniaControlText 'LblAdAuditDc' 'Lecture des comptes des contrôleurs…')
    Invoke-DomeniaAdAuditStart 'LblAdAuditDc' {Start-UiTask -Name 'Audit AD : contrôleurs du domaine' -OperationId 'AdHealthRead' -Code (Get-DomeniaAdHealthReadWorkerCode) -Payload ([pscustomobject]@{Action='List'}) -CallbackState (New-DomeniaAdAuditRequestState 'DcList') -ReplaceKey 'adaudit-dc-list' -DisableControls @('BtnAdAuditDcList') -TimeoutSeconds 45 -SuccessHandler 'Complete-DomeniaAdAuditDcList' -ErrorHandler 'Fail-DomeniaAdAuditDcList' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditDcList {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Action','Dcs')
    if($null -eq $read){[void](Set-DomeniaControlText 'LblAdAuditDc' 'Résultat absent : rien nʼest affiché.');return}
    $pdc=[string]$read.Pdc
    $rows=foreach($dc in @($read.Dcs)){
        $roles=New-Object 'System.Collections.Generic.List[string]'
        if($pdc -and ([string]$dc.DnsHostName -ieq $pdc)){$roles.Add('Émulateur PDC')}
        if([bool]$dc.ReadOnly){$roles.Add('Lecture seule (RODC)')}
        $name=[string]$dc.DnsHostName;if(-not $name){$name=[string]$dc.Name}
        [pscustomobject]@{DnsHostName=$name;Name=[string]$dc.Name;Site=[string]$dc.Site;Os=[string]$dc.Os;Role=($roles.ToArray() -join ', ');Dn=[string]$dc.Dn}
    }
    $script:AdAuditData.DcList=@($rows);$script:AdAuditData.DcPdc=$pdc
    [void](Set-DomeniaItemsSource 'DgAdAuditDcList' @($rows))
    $text=[string]@($rows).Count+' contrôleur(s) lu(s)'
    if([bool]$read.Truncated){$text+=' (liste bornée à 100)'}
    if($pdc){$text+=', émulateur PDC : '+$pdc}elseif([string]$read.PdcError){$text+=', émulateur PDC non lu'}
    $text+='. Choisissez-en jusquʼà 10 (Ctrl ou Maj), puis lancez le diagnostic.'
    [void](Set-DomeniaControlText 'LblAdAuditDc' $text)
}

function Fail-DomeniaAdAuditDcList {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditDc' ('Lecture des contrôleurs impossible : '+[string]$Message))
}

function Get-DomeniaAdAuditChosenDcs {
    $grid=Get-DomeniaControl 'DgAdAuditDcList'
    if($null -eq $grid){return}
    foreach($row in @($grid.SelectedItems)){if(($null -ne $row) -and [string]$row.DnsHostName){[string]$row.DnsHostName}}
}

function Start-DomeniaAdAuditDcProbe {
    Sync-DomeniaAdAuditTarget
    $dcs=@(Get-DomeniaAdAuditChosenDcs | Select-Object -Unique)
    if($dcs.Count -eq 0){[void](Set-DomeniaControlText 'LblAdAuditDc' 'Choisissez au moins un contrôleur dans la liste.');return}
    if($dcs.Count -gt 10){[void](Set-DomeniaControlText 'LblAdAuditDc' ('Diagnostic borné à 10 contrôleurs : '+[string]$dcs.Count+' sont choisis.'));return}
    [void](Set-DomeniaControlText 'LblAdAuditDc' ('Diagnostic de '+[string]$dcs.Count+' contrôleur(s) : DNS, ports, heure et réplication…'))
    $payload=[pscustomobject]@{Action='Probe';Dcs=$dcs;DomainDns=[string](Get-DomeniaMember $script:Conn 'Domain' '');Pdc=[string]$script:AdAuditData.DcPdc}
    Invoke-DomeniaAdAuditStart 'LblAdAuditDc' {Start-UiTask -Name 'Audit AD : diagnostic des contrôleurs' -OperationId 'AdHealthRead' -Code (Get-DomeniaAdHealthReadWorkerCode) -Payload $payload -CallbackState (New-DomeniaAdAuditRequestState 'DcProbe') -ReplaceKey 'adaudit-dc-probe' -DisableControls @('BtnAdAuditDcProbe') -TimeoutSeconds 120 -SuccessHandler 'Complete-DomeniaAdAuditDcProbe' -ErrorHandler 'Fail-DomeniaAdAuditDcProbe' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditDcProbe {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Action','Results')
    if($null -eq $read){[void](Set-DomeniaControlText 'LblAdAuditDc' 'Résultat absent : rien nʼest affiché.');return}
    $view=Get-DomeniaAdHealthView -Probe $read -NowUtc ([datetime]::UtcNow)
    [void](Set-DomeniaItemsSource 'DgAdAuditHealth' @($view.Rows))
    [void](Set-DomeniaItemsSource 'DgAdAuditRepl' @($view.Neighbors))
    [void](Set-DomeniaItemsSource 'DgAdAuditDcFacts' @(ConvertTo-DomeniaAdAuditFactRows $view.Facts))
    [void](Set-DomeniaControlText 'LblAdAuditDc' ([string]$view.Summary+' Lu le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)+'.'))
}

function Fail-DomeniaAdAuditDcProbe {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditDc' ('Diagnostic des contrôleurs impossible : '+[string]$Message))
}

function Start-DomeniaAdAuditDcServices {
    Sync-DomeniaAdAuditTarget
    $dcs=@(Get-DomeniaAdAuditChosenDcs | Select-Object -Unique)
    if($dcs.Count -eq 0){[void](Set-DomeniaControlText 'LblAdAuditDc' 'Choisissez au moins un contrôleur dans la liste.');return}
    if($dcs.Count -gt 10){[void](Set-DomeniaControlText 'LblAdAuditDc' ('Lecture bornée à 10 contrôleurs : '+[string]$dcs.Count+' sont choisis.'));return}
    if(-not (Confirm-Action ('Lire par CIM lʼétat des services de lʼannuaire sur '+[string]$dcs.Count+' contrôleur(s) ? Cette sonde demande des droits dʼadministration sur chaque contrôleur ; aucun service nʼest modifié.'))){return}
    [void](Set-DomeniaControlText 'LblAdAuditDc' ('Lecture des services de '+[string]$dcs.Count+' contrôleur(s)…'))
    Invoke-DomeniaAdAuditStart 'LblAdAuditDc' {Start-UiTask -Name 'Audit AD : services des contrôleurs' -OperationId 'DcServicesRead' -Code (Get-DomeniaDcServicesReadWorkerCode) -Payload ([pscustomobject]@{Dcs=$dcs}) -CallbackState (New-DomeniaAdAuditRequestState 'DcServices') -ReplaceKey 'adaudit-dc-services' -DisableControls @('BtnAdAuditDcServices') -TimeoutSeconds 120 -SuccessHandler 'Complete-DomeniaAdAuditDcServices' -ErrorHandler 'Fail-DomeniaAdAuditDcServices' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditDcServices {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Results')
    if($null -eq $read){[void](Set-DomeniaControlText 'LblAdAuditDc' 'Résultat absent : rien nʼest affiché.');return}
    $rows=Get-DomeniaDcServiceView -Read $read
    [void](Set-DomeniaItemsSource 'DgAdAuditServices' @($rows))
    $tabs=Get-DomeniaControl 'AdAuditDcResultTabs'
    $tab=Get-DomeniaControl 'TabAdAuditDcServices'
    if(($null -ne $tabs) -and ($null -ne $tab)){$tabs.SelectedItem=$tab}
    [void](Set-DomeniaControlText 'LblAdAuditDc' ('Services lus le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)+'. Un refus signale un manque de droits, pas un service arrêté.'))
}

function Fail-DomeniaAdAuditDcServices {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditDc' ('Lecture des services impossible : '+[string]$Message))
}

# ---------------------------------------------------------------- point 109 : one organisational unit
function Update-DomeniaAdAuditScopeLabel {
    $ou=[string]$script:SelectedBranchDn
    if((-not [string]$script:Conn.BaseDn) -or (-not $ou)){[void](Set-DomeniaControlText 'LblAdAuditScope' 'Périmètre : choisissez une OU dans lʼarbre de Rechercher.');return}
    [void](Set-DomeniaControlText 'LblAdAuditScope' ('Périmètre : '+(Get-DomeniaOuDisplayPath $ou)+' (OU choisie dans lʼarbre de Rechercher)'))
}

function Start-DomeniaAdAuditScan {
    Sync-DomeniaAdAuditTarget
    Update-DomeniaAdAuditScopeLabel
    $ou=[string]$script:SelectedBranchDn
    $domain=[string]$script:Conn.BaseDn
    if((-not $domain) -or (-not $ou)){[void](Set-DomeniaControlText 'LblAdAuditScan' 'Choisissez dʼabord une OU dans lʼarbre de Rechercher.');return}
    $subtree=[bool](Get-DomeniaControl 'ChkAdAuditScanSubtree').IsChecked
    if($subtree -and ($ou -ieq $domain)){[void](Set-DomeniaControlText 'LblAdAuditScan' 'Le domaine entier nʼest pas analysé : choisissez une OU, ou décochez « Inclure les sous-OU ».');return}
    $script:AdAuditData.ScanRead=$null;$script:AdAuditData.ScanIndex=$null
    [void](Set-DomeniaItemsSource 'DgAdAuditScan' @())
    [void](Set-DomeniaControlText 'LblAdAuditScan' 'Lecture des utilisateurs et postes de lʼOU (5 000 au plus)…')
    $payload=[pscustomobject]@{BaseDn=$ou;Subtree=$subtree;Limit=5000}
    $state=New-DomeniaAdAuditRequestState 'Scan'
    $state|Add-Member -NotePropertyName BaseDn -NotePropertyValue $ou
    Invoke-DomeniaAdAuditStart 'LblAdAuditScan' {Start-UiTask -Name 'Audit AD : identités de lʼOU' -OperationId 'AdConsistencyScan' -Code (Get-DomeniaAdConsistencyScanWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'adaudit-scan' -DisableControls @('BtnAdAuditScan') -TimeoutSeconds 120 -SuccessHandler 'Complete-DomeniaAdAuditScan' -ErrorHandler 'Fail-DomeniaAdAuditScan' -TaskClass 'Explicit'}
}

function Complete-DomeniaAdAuditScan {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('BaseDn','Rows','Truncated')
    if(($null -eq $read) -or ([string]$read.BaseDn -ine [string]$State.BaseDn)){[void](Set-DomeniaControlText 'LblAdAuditScan' 'Résultat absent ou provenant dʼune autre OU : rien nʼest affiché.');return}
    $script:AdAuditData.ScanRead=$read
    Update-DomeniaAdAuditScanFindings
    $path=[string](Get-DomeniaLocalDatabasePathForRead)
    if(-not $path){return}
    $users=@(@($read.Rows)|Where-Object{[string]$_.Type -eq 'Utilisateur'}|ForEach-Object{[string]$_.Sam}|Where-Object{$_}|Select-Object -First 1000)
    $computers=@(@($read.Rows)|Where-Object{[string]$_.Type -eq 'Machine'}|ForEach-Object{[string]$_.Name}|Where-Object{$_}|Select-Object -First 1000)
    if(($users.Count -eq 0) -and ($computers.Count -eq 0)){return}
    $payload=[pscustomobject]@{Action='ResolveNames';Path=$path;BusyTimeoutMs=250;Users=$users;Computers=$computers}
    # The AD findings are already shown: a local read that cannot start only leaves the recycled names unsearched.
    try{[void](Start-UiTask -Name 'Audit AD : noms dans la base locale' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $State -ReplaceKey 'adaudit-scan-index' -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaAdAuditScanIndex' -ErrorHandler 'Fail-DomeniaAdAuditScanIndex' -TaskClass 'Explicit')}
    catch{Write-AppLog ('Audit AD : base locale non consultée : '+$_.Exception.Message) 'WARN'}
}

function Fail-DomeniaAdAuditScan {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    [void](Set-DomeniaControlText 'LblAdAuditScan' ('Lecture des identités impossible : '+[string]$Message))
}

function Complete-DomeniaAdAuditScanIndex {
    param($Result,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Busy','Missing')
    if($null -eq $read){return}
    $script:AdAuditData.ScanIndex=$read
    Update-DomeniaAdAuditScanFindings
}

function Fail-DomeniaAdAuditScanIndex {
    param($Message,$State)
    if(-not (Test-DomeniaAdAuditRequestCurrent $State)){return}
    $script:AdAuditData.ScanIndex=[pscustomobject]@{Busy=$true;Missing=$false;Message=[string]$Message}
    Update-DomeniaAdAuditScanFindings
}

function Update-DomeniaAdAuditScanFindings {
    $read=$script:AdAuditData.ScanRead
    if($null -eq $read){return}
    $result=Find-DomeniaIdentityConflicts -Rows @($read.Rows) -LocalIndex $script:AdAuditData.ScanIndex -Truncated ([bool]$read.Truncated) -NowUtc ([datetime]::UtcNow)
    [void](Set-DomeniaItemsSource 'DgAdAuditScan' @($result.Findings))
    $text=[string]$result.Summary+' Lu sur '+[string]$read.Server+' le '+(Get-DomeniaAdAuditTimeText $read.ObservedUtc)
    if([bool]$read.Truncated){$text+=' ; lecture bornée à '+[string]$read.Limit+' objets'}
    [void](Set-DomeniaControlText 'LblAdAuditScan' ($text+'.'))
}

# ---------------------------------------------------------------- copy for a ticket
function Get-DomeniaAdAuditGridSection {
    param([string]$Grid,[string]$Label='')
    $summary=''
    if($Label){$labelControl=Get-DomeniaControl $Label;if($null -ne $labelControl){$summary=[string]$labelControl.Text}}
    $columns=@();$rows=@()
    $control=Get-DomeniaControl $Grid
    if($null -ne $control){
        $columns=@(foreach($column in @($control.Columns)){
            $path=''
            try{$path=[string]$column.Binding.Path.Path}catch{$path=''}
            if($path){[pscustomobject]@{Header=[string]$column.Header;Property=$path}}
        })
        $rows=@($control.ItemsSource|Where-Object{$null -ne $_})
    }
    return [pscustomobject]@{Summary=$summary;Columns=$columns;Rows=$rows}
}

function Copy-DomeniaAdAuditView {
    $tabs=Get-DomeniaControl 'AdAuditTabs'
    if(($null -eq $tabs) -or ($null -eq $tabs.SelectedItem)){return}
    $page=[string]$tabs.SelectedItem.Name
    $sections=New-Object 'System.Collections.Generic.List[object]'
    $title='Audit AD'
    if($page -eq 'TabAdAuditObject'){
        $target=$script:AdAuditTarget
        if($null -ne $target){$title+=' · '+[string]$target.Type+' · '+[string]$target.Name+' · '+[string]$target.Dn}
        $inner=Get-DomeniaControl 'AdAuditObjectTabs'
        $innerName=if(($null -ne $inner) -and ($null -ne $inner.SelectedItem)){[string]$inner.SelectedItem.Name}else{''}
        switch($innerName){
            'TabAdAuditPolicy' {$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditPolicy' 'LblAdAuditPolicy'))}
            'TabAdAuditGroups' {$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditGroups' 'LblAdAuditGroups'));$sections.Add([pscustomobject]@{Summary=[string](Get-DomeniaControl 'LblAdAuditGroupPath').Text;Columns=@();Rows=@()})}
            'TabAdAuditAcl' {$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditAcl' 'LblAdAuditAcl'));$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditAclEstimate' 'LblAdAuditAclEstimate'))}
            'TabAdAuditGpo' {$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditGpo' 'LblAdAuditGpo'));$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditGpoFacts'))}
            'TabAdAuditMachine' {$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditMachineIdentity' 'LblAdAuditMachineIdentity'))}
            'TabAdAuditHistory' {$sections.Add([pscustomobject]@{Summary=[string](Get-DomeniaControl 'LblAdAuditRelationOverview').Text;Columns=@();Rows=@()});$sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditHistory' 'LblAdAuditHistory'))}
        }
    }
    elseif($page -eq 'TabAdAuditDcs'){
        $title+=' · contrôleurs'
        $sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditHealth' 'LblAdAuditDc'))
        $sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditDcFacts'))
        $sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditRepl'))
        $sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditServices'))
    }
    elseif($page -eq 'TabAdAuditIdentity'){
        $title+=' · '+[string](Get-DomeniaControl 'LblAdAuditScope').Text
        $sections.Add((Get-DomeniaAdAuditGridSection 'DgAdAuditScan' 'LblAdAuditScan'))
    }
    $text=ConvertTo-DomeniaAdAuditCopyText -Sections $sections.ToArray() -Title $title
    Set-ClipboardSafe $text
    Set-Status 'Audit AD : vue copiée dans le presse-papiers (données déjà affichées, aucune relecture).'
}
