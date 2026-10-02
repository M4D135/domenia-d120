# Presentation and coordination only. Network and durable receipt I/O run in registered workers.
$script:Guard=$null
$script:DraftState=$null
$script:ArtifactConsent=$null
function Show-DomeniaGuard {
    Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabGuard'
    $tabs=Get-DomeniaControl 'ApplicationToolTabs';$tab=Get-DomeniaControl 'TabGuard'
    if($null -ne $tabs -and $null -ne $tab){$tabs.SelectedItem=$tab}
}
function Start-DomeniaReceiptRefresh {
    param([ValidateSet('List','Verify','Review')][string]$Action='List',[string]$Id='',[string]$Reason='')
    if($null -eq $script:Guard -or $script:Guard.ReceiptJob -or $script:AsyncEngineClosing){return}
    if(@($script:AsyncJobs.Values|Where-Object{$_.IsWrite -or $_.OperationId -eq 'ReceiptStore'}).Count){return}
    if($Action -ne 'List' -and [string]$Id -notmatch '^[a-f0-9]{32}$'){throw 'Selectionnez un recu valide.'}
    $script:ReceiptReady=$false
    try{
        $script:Guard.ReceiptJob=Start-UiTask -Name 'Verifier les recus locaux' -OperationId 'ReceiptStore' -Code (Get-DomeniaReceiptWorkerCode) -Payload ([pscustomobject]@{Action=$Action;Id=$Id;Reason=$Reason}) -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;Action=$Action}) -SuccessHandler 'Complete-DomeniaReceiptRefresh' -ErrorHandler 'Fail-DomeniaReceiptRefresh' -NonCancellable -TimeoutSeconds 25
        $script:ReceiptRefreshNeeded=$false;$script:Guard.NextReceipt=[datetime]::UtcNow.AddSeconds(15)
    }catch{$script:Guard.ReceiptJob='';$script:Guard.NextReceipt=[datetime]::UtcNow.AddSeconds(15);[void](Set-DomeniaControlText 'LblGuardReceipts' 'Recus non lus. Les ecritures restent protegees. Actualisez cette vue.');Write-AppLog ('Lecture des recus : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaReceiptRefresh {
    param($Result,$State)
    $script:Guard.ReceiptJob=''
    if($State.Epoch -ne [long]$script:SessionEpoch){$script:ReceiptRefreshNeeded=$true;return}
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Pending')
    if($null -eq $r){Fail-DomeniaReceiptRefresh 'Aucun etat confirme.' $State;return}
    $script:ReceiptPending=[int]$r.Pending;$script:ReceiptReady=$true
    [void](Set-DomeniaItemsSource 'DgGuardReceipts' @($r.Rows|Sort-Object UpdatedUtc -Descending))
    [void](Set-DomeniaControlText 'LblGuardReceipts' ('Recus lus : '+@($r.Rows).Count+' ; a verifier : '+$r.Pending+'. Aucun rejeu automatique.'))
    if($script:ReceiptPending -eq 0 -and -not $script:ActiveWriteTaskId -and $script:WriteState -in @('Unknown','UnknownPending')){
        $script:WriteState='Idle';$script:UnknownWriteTargetDn=''
        Write-AppLog 'Incertitude levee uniquement apres verification ou revue explicite des recus durables.' 'WARN'
    }
    Apply-CurrentPermissionUi
}
function Fail-DomeniaReceiptRefresh {
    param($Message,$State)
    $script:Guard.ReceiptJob='';$script:ReceiptReady=$false;$script:Guard.NextReceipt=[datetime]::UtcNow.AddSeconds(30)
    [void](Set-DomeniaControlText 'LblGuardReceipts' 'Recus non confirmes : aucune nouvelle ecriture autorisee. Consultez le journal puis Actualiser.')
    Write-AppLog ('Recus non confirmes : '+[string]$Message) 'WARN'
}
function Invoke-DomeniaReceiptChoice {
    param([ValidateSet('Verify','Review')][string]$Action)
    $grid=Get-DomeniaControl 'DgGuardReceipts';$row=$grid.SelectedItem
    if($null -eq $row){Show-InfoBox 'Selectionnez un recu.';return}
    if($row.Stage -in @('Verified','NotSent','Reviewed')){Show-InfoBox 'Ce recu ne bloque plus de nouvelle operation.';return}
    if($Action -eq 'Verify'){
        if(-not (Confirm-Action -Message ('Relire les postconditions sur le controleur initial ? Aucune commande ne sera rejouee. Cible : '+$row.DN) -Title 'Verifier, sans reexecuter')){return}
        Start-DomeniaReceiptRefresh -Action Verify -Id $row.Id;return
    }
    $form=Show-DomeniaFormDialog -Title 'Revue externe du resultat' -Message 'A utiliser apres un controle reel avec un autre outil. Cette declaration ne constitue pas une verification automatique. Ne saisissez aucun secret.' -Fields @(@{Name='Reason';Label='Verification realisee (12 a 240 caracteres)';Value=''}) -AcceptText 'Continuer'
    if($null -eq $form){return};$reason=[string]$form.Reason
    if($reason.Length -lt 12 -or $reason.Length -gt 240){Show-InfoBox 'Le motif doit contenir entre 12 et 240 caracteres.';return}
    if(Confirm-Action -Message ('Confirmer votre revue du recu '+$row.Id+' ? Le recu sera conserve comme Revise, pas transforme en succes automatique.') -Title 'Revue du recu'){
        Start-DomeniaReceiptRefresh -Action Review -Id $row.Id -Reason $reason
    }
}
function Save-DomeniaDraftBaseline {
    param([string]$DN)
    $values=@{}
    foreach($n in (Get-DomeniaDraftFieldMap).Keys){$c=Get-DomeniaControl $n;if($null -ne $c){$values[$n]=[string]$c.Text}}
    $flags=@{};foreach($n in @('ChkPwdNeverExpires','ChkPwdNotRequired','ChkSmartcardRequired','ChkAccountNotDelegated','ChkNoPreAuth','ChkReversiblePwd','ChkTrustedForDelegation','ChkTrustedToAuthDelegation','ChkUseDesOnly','ChkMustChangeAtLogon','ChkUnlockAfterReset')){$c=Get-DomeniaControl $n;if($null -ne $c){$flags[$n]=[bool]$c.IsChecked}}
    $script:DraftState=[pscustomobject]@{DN=$DN;Values=$values;Flags=$flags;Pending=$null;PendingType='';Generation=[long]$script:SelectedObjectGeneration}
    [void](Set-DomeniaControlText 'LblGuardDraft' 'Aucune modification de formulaire en attente.')
}
function Get-DomeniaDirtyFields {
    if($null -eq $script:DraftState){return @()}
    $names=[Collections.Generic.List[string]]::new()
    foreach($n in $script:DraftState.Values.Keys){$c=Get-DomeniaControl $n;if($null -ne $c -and [string]$c.Text -cne [string]$script:DraftState.Values[$n]){$names.Add($n)}}
    foreach($n in $script:DraftState.Flags.Keys){$c=Get-DomeniaControl $n;if($null -ne $c -and [bool]$c.IsChecked -ne [bool]$script:DraftState.Flags[$n]){$names.Add($n)}}
    foreach($n in @('PwdUserNew','PwdUserConfirm')){$c=Get-DomeniaControl $n;if($null -ne $c -and $c.SecurePassword.Length -gt 0){$names.Add($n)}}
    return $names.ToArray()
}
function Test-DomeniaDraftNavigation {
    param([string]$DN,[switch]$Refresh)
    if($null -eq $script:DraftState -or -not @(Get-DomeniaDirtyFields).Count){return $true}
    if(-not $Refresh -and $DN -ieq $script:DraftState.DN){return $true}
    if(-not (Confirm-Action -Message 'Des champs de la fiche ont ete modifies sans enregistrement. Abandonner ces saisies pour changer de fiche ou la recharger ?' -Title 'Saisies non enregistrees')){return $false}
    $script:DraftState=$null;return $true
}
function Keep-DomeniaDraftOnResult {
    param($Result,[string]$DN,[string]$Type)
    if($null -eq $script:DraftState -or $script:DraftState.DN -ine $DN -or -not @(Get-DomeniaDirtyFields).Count){return $false}
    $script:DraftState.Pending=$Result;$script:DraftState.PendingType=$Type
    [void](Set-DomeniaControlText 'LblGuardDraft' 'Une relecture est arrivee. Vos saisies sont conservees. Comparez dans Outils > Fiabilite avant de recharger.')
    Set-Status 'Fiche plus recente disponible : saisies conservees, aucune valeur remplacee. Outils > Fiabilite > Comparer les saisies.' 'WARN'
    return $true
}
function Show-DomeniaDraftComparison {
    if($null -eq $script:DraftState){Show-InfoBox 'Aucune fiche editable ouverte.';return}
    $lines=[Collections.Generic.List[string]]::new();$map=Get-DomeniaDraftFieldMap
    foreach($n in @(Get-DomeniaDirtyFields)){
        if(-not $map.Contains($n)){$lines.Add($n+' : valeur modifiee. Les mots de passe ne sont jamais reproduits dans cette comparaison.');continue}
        $c=Get-DomeniaControl $n;$server='Non relu'
        if($null -ne $script:DraftState.Pending){try{$v=$script:DraftState.Pending.Properties[[string]$map[$n]];$server=(@($v) -join ', ')}catch{$server='Indetermine'}}
        $lines.Add(([string]$map[$n])+"`r`nLu : "+[string]$script:DraftState.Values[$n]+"`r`nVotre saisie : "+[string]$c.Text+"`r`nNouvelle lecture : "+$server+"`r`n")
    }
    if(-not $lines.Count){Show-InfoBox 'Aucun champ modifie.';return}
    Show-DomeniaDialog -Title 'Comparer les saisies' -Message 'Aucune saisie ne sera remplacee automatiquement. Rechargez volontairement pour repartir de la lecture AD, puis reappliquez seulement les changements voulus.' -Details ($lines -join "`r`n") -Kind Info | Out-Null
}
function Set-DomeniaArtifactConsent {
    if(Test-DomeniaAccessBusyWrite){Show-InfoBox 'Terminez la verification de l ecriture avant de modifier une autorisation.';return}
    $target='';try{if($script:SelectedObject.Type -eq 'Machine'){$target=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'dNSHostName');if(-not $target){$target=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'name')}}}catch{}
    if(-not $target){Show-InfoBox 'Selectionnez une machine dans la recherche.';return}
    if(-not (Confirm-Action -Message ('Autoriser pendant 5 minutes les transports avec creation de script, service ou tache sur '+$target+' ? Ils ne seront utilises que lors de votre prochaine action volontaire. Le Planificateur utilise une API ; PsExec exige une session Windows integree autorisee. Aucun secret ne sera transmis dans les arguments.') -Title 'Intervention distante avec traces')){return}
    $aliases=@($target);$short=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'name');if($short -and $short -notmatch '[\\/]'){$aliases+=@($short)}
    $script:ArtifactConsent=[pscustomobject]@{Target=$target;Aliases=$aliases;Epoch=[long]$script:SessionEpoch;Expires=[datetime]::UtcNow.AddMinutes(5)}
    [void](Set-DomeniaControlText 'LblGuardRemote' ('Autorisation temporaire : '+$target+'. Relancez volontairement votre diagnostic.'))
}
function Get-DomeniaFavouriteSearches {
    $all=Get-DomeniaSetting 'SavedSearches' @();$list=[Collections.Generic.List[object]]::new()
    foreach($value in @($all|Select-Object -First 50)){$v=ConvertTo-DomeniaSavedSearch $value ([string]$script:Conn.BaseDn);if($null -ne $v){$list.Add($v)}}
    return $list.ToArray()
}
function Save-DomeniaFavouriteSearch {
    $scope=Get-DomeniaSearchScope
    $form=Show-DomeniaFormDialog -Title 'Memoriser une recherche' -Message 'Enregistre ce perimetre et les filtres, pas les resultats ni les identifiants.' -Fields @(@{Name='Name';Label='Nom de la recherche';Value='Ma recherche'}) -AcceptText 'Enregistrer'
    if($null -eq $form){return}
    $item=[pscustomobject]@{SearchMode=(Get-DomeniaSearchMode);Name=[string]$form.Name;DN=$scope.BaseDn;Subtree=($scope.Scope -eq 'Subtree');Query=(Get-DomeniaSearchText);Type=$(if((Get-DomeniaSearchMode) -eq 'Global'){'Tous'}else{[string](Get-DomeniaControl 'CmbGlobalType').SelectedItem.Content});Limit=[string](Get-DomeniaControl 'TxtGlobalLimit').Text}
    $valid=ConvertTo-DomeniaSavedSearch $item ([string]$script:Conn.BaseDn)
    if($null -eq $valid){Show-InfoBox 'Nom ou perimetre invalide.';return}
    $all=@(Get-DomeniaSetting 'SavedSearches' @()|Where-Object{[string]$_.Name -ine $valid.Name -or [string]$_.DN -ine $valid.DN})
    if($all.Count -ge 50){Show-InfoBox '50 favoris maximum. Retirez un favori avant d en ajouter un.';return}
    Set-DomeniaSetting 'SavedSearches' @($all+$valid);Save-DomeniaSettings -Immediate
    [void](Set-DomeniaItemsSource 'LstGuardSearches' (Get-DomeniaFavouriteSearches))
}
function Load-DomeniaFavouriteSearch {
    $v=(Get-DomeniaControl 'LstGuardSearches').SelectedItem;if($null -eq $v){return}
    if(-not (Test-DomeniaDraftNavigation '')){return}
    if(Test-DomeniaAccessBusyWrite){Show-InfoBox 'Une ecriture est active ou a verifier.';return}
    $oldRestore=$script:RestoringSettings;$oldSuppress=$script:SuppressBranchAutoLoad
    $script:RestoringSettings=$true;$script:SuppressBranchAutoLoad=$true
    try {
    $mode=if([string]$v.SearchMode -eq 'Global'){'Global'}else{'OU'}
    if($mode -eq 'OU'){$script:SelectedBranchDn=[string]$v.DN}
    $field=if($mode -eq 'Global'){'TxtGlobalSearch'}else{'TxtBranchSearch'}
    (Get-DomeniaControl $field).Text=[string]$v.Query
    (Get-DomeniaControl 'TxtGlobalLimit').Text=[string]$v.Limit
    if($mode -eq 'OU'){
        (Get-DomeniaControl 'ChkSubtree').IsChecked=[bool]$v.Subtree
        $combo=Get-DomeniaControl 'CmbGlobalType';foreach($item in $combo.Items){if([string]$item.Content -eq $v.Type){$combo.SelectedItem=$item;break}}
    }
    } finally {$script:RestoringSettings=$oldRestore;$script:SuppressBranchAutoLoad=$oldSuppress}
    Update-DomeniaSearchScopeUi;Select-DomeniaWorkspace -Workspace 'WsSearch'
    Invoke-GlobalSearch -SearchMode $mode
}
function Open-DomeniaSuiteTool {
    param([ValidateSet('Pesto','FilPro')][string]$Name)
    $path=[string](Get-CfgValue 'Suite' ($Name+'Path') '')
    $expected=[string](Get-CfgValue 'Suite' ($Name+'Sha256') '')
    if(-not $path -or -not $expected){Show-InfoBox ('Configurez Suite.'+$Name+'Path et '+$Name+'Sha256 dans la configuration apres validation du logiciel.');return}
    if([IO.Path]::GetExtension($path) -ine '.exe' -or -not [IO.Path]::IsPathRooted($path) -or -not [IO.File]::Exists($path)){throw 'Chemin absolu d executable requis.'}
    $i=Get-Item -LiteralPath $path -Force
    $chain=$i;while($null -ne $chain){if($chain.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Executable ou chemin redirige refuse.'};$chain=if($chain -is [IO.FileInfo]){$chain.Directory}else{$chain.Parent}}
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected){throw 'Empreinte de l executable differente. Aucune execution.'}
    if(Confirm-Action -Title ('Ouvrir '+$Name) -Message ('Ouvrir '+$path+' ? Aucun compte, mot de passe ou commande d intervention ne sera transmis.')){
        $p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$path;$p.Arguments='';$p.WorkingDirectory=$i.DirectoryName;$p.UseShellExecute=$false;[void][Diagnostics.Process]::Start($p)
    }
}
function Initialize-DomeniaGuard {
    if($null -ne $script:Guard){return}
    $script:Guard=[pscustomobject]@{ReceiptJob='';NextReceipt=[datetime]::MinValue;Samples=[Collections.Generic.List[double]]::new();Last=[datetime]::UtcNow;Epoch=[long]$script:SessionEpoch;Timer=$null}
    $actions=@{
        BtnGuardOpen={Show-DomeniaGuard};BtnGuardReceiptRefresh={Start-DomeniaReceiptRefresh};BtnGuardReceiptVerify={Invoke-DomeniaReceiptChoice Verify};BtnGuardReceiptReview={Invoke-DomeniaReceiptChoice Review}
        BtnGuardDraft={Show-DomeniaDraftComparison};BtnGuardRemote={Set-DomeniaArtifactConsent};BtnGuardRemoteOff={$script:ArtifactConsent=$null;[void](Set-DomeniaControlText 'LblGuardRemote' 'Depots et services non autorises par defaut.')}
        BtnGuardSaveSearch={Save-DomeniaFavouriteSearch};BtnGuardLoadSearch={Load-DomeniaFavouriteSearch};BtnGuardRemoveSearch={Remove-DomeniaFavouriteSearch};BtnGuardStoreResume={Resume-DomeniaStorage};BtnGuardWhy={Show-DomeniaUnavailableReasons};BtnGuardExport={Export-DomeniaTechnicalDossier}
        BtnGuardPesto={Open-DomeniaSuiteTool Pesto};BtnGuardFilPro={Open-DomeniaSuiteTool FilPro}
    }
    foreach($n in $actions.Keys){$c=Get-DomeniaControl $n;if($null -ne $c){$body=$actions[$n];$c.Add_Click($body)}}
    [void](Set-DomeniaItemsSource 'LstGuardSearches' (Get-DomeniaFavouriteSearches))
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$timer.Interval=[timespan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if($script:AsyncEngineClosing -or $null -eq $script:Guard){return}
        $now=[datetime]::UtcNow;$delay=[Math]::Max(0,($now-$script:Guard.Last).TotalMilliseconds-500);$script:Guard.Last=$now
        $script:Guard.Samples.Add($delay);if($script:Guard.Samples.Count -gt 240){$script:Guard.Samples.RemoveAt(0)}
        if($script:Guard.Epoch -ne [long]$script:SessionEpoch){$script:Guard.Epoch=[long]$script:SessionEpoch;$script:ReceiptReady=$false;$script:ReceiptRefreshNeeded=$true;$script:ArtifactConsent=$null;$script:DraftState=$null}
        if(($script:ReceiptRefreshNeeded -or -not $script:ReceiptReady) -and $now -ge $script:Guard.NextReceipt){Start-DomeniaReceiptRefresh}
        $tab=Get-DomeniaControl 'TabGuard'
        if($null -ne $tab -and $tab.IsSelected){
            $p95=Get-DomeniaPercentile $script:Guard.Samples.ToArray() 95;$p50=Get-DomeniaPercentile $script:Guard.Samples.ToArray() 50
            $queue=0;if($null -ne $script:Persistence){$queue=$script:Persistence.Pending.Count}
            [void](Set-DomeniaControlText 'LblGuardMetrics' ('Retard du Dispatcher (local) p50/p95 : '+$p50+' / '+$p95+' ms. Taches : '+$script:AsyncJobs.Count+'. Cache en attente : '+$queue+'. Mesure indicative, pas un benchmark reseau.'))
        }
    });$script:Guard.Timer=$timer;$timer.Start()
    $script:Window.Add_Closed({if($null -ne $script:Guard){$script:Guard.Timer.Stop()};$script:DraftState=$null;$script:ArtifactConsent=$null})
    $script:ReceiptRefreshNeeded=$true;Start-DomeniaReceiptRefresh
}
function Set-DomeniaProtectedClipboard {
    param([string]$Value)
    if($null -eq ('Domenia.Secrets.ClipboardWriter' -as [type])){Add-Type -Path (Join-Path $script:RootDir 'modules\Domenia-Clipboard.Native.cs') -ErrorAction Stop}
    $owner=[Windows.Interop.WindowInteropHelper]::new($script:Window).Handle
    [Domenia.Secrets.ClipboardWriter]::Set($owner,$Value)
}

function Remove-DomeniaFavouriteSearch {
    $v=(Get-DomeniaControl 'LstGuardSearches').SelectedItem;if($null -eq $v){return}
    if(-not (Confirm-Action -Title 'Retirer ce favori' -Message ('Retirer uniquement la recherche memorisee '+$v.Name+' ? Aucun objet AD ne sera modifie.'))){return}
    $items=@(Get-DomeniaSetting 'SavedSearches' @()|Where-Object{[string]$_.Name -ine [string]$v.Name -or [string]$_.DN -ine [string]$v.DN})
    Set-DomeniaSetting 'SavedSearches' $items;Save-DomeniaSettings -Immediate
    [void](Set-DomeniaItemsSource 'LstGuardSearches' (Get-DomeniaFavouriteSearches))
}
function Resume-DomeniaStorage {
    if($null -eq $script:Persistence){return}
    if($script:Persistence.Job){Show-InfoBox 'Un enregistrement est encore actif.';return}
    $script:Persistence.Failures=0;$script:Persistence.Fault='';$script:Persistence.Next=[datetime]::UtcNow
    Set-Status 'Reprise demandee pour les lots de cache en memoire. Aucune ecriture AD.'
}
function Show-DomeniaUnavailableReasons {
    $lines=[Collections.Generic.List[string]]::new()
    if($script:ReadOnlyMode){$lines.Add('Protection lecture seule active : les modifications sont volontairement interdites.')}
    if(-not $script:ReceiptReady){$lines.Add('Les recus locaux ne sont pas encore confirmes. Les nouvelles ecritures sont bloquees.')}
    if($script:ReceiptPending -gt 0){$lines.Add('Une operation precedente reste a verifier. Consultez les recus, pas une relance automatique.')}
    if($script:ActiveWriteTaskId){$lines.Add('Une ecriture est deja active ; les changements de contexte attendent sa fin.')}
    if($null -eq $script:SelectedObject){$lines.Add('Aucune fiche selectionnee. Choisissez un objet dans Rechercher.')}
    foreach($n in @('BtnLoadLaps','BtnLoadBitLocker','BtnUserSave','BtnCompRestart','BtnRawSet')){
        $c=Get-DomeniaControl $n;if($null -ne $c -and -not $c.IsEnabled){$tip=[string]$c.ToolTip;if($tip){$lines.Add($n+' : '+$tip)}}
    }
    if(-not $lines.Count){$lines.Add('Aucun blocage commun observe. Un droit specifique reste verifie par la ressource lors de l action ; consultez son infobulle ou son erreur native.')}
    Show-DomeniaDialog -Title 'Pourquoi une action est indisponible ?' -Message 'Ce bilan lit uniquement les etats de la session. Il ne teste ni ne modifie les droits.' -Details ($lines -join "`r`n") -Kind Info | Out-Null
}
