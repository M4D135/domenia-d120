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
    # A job that left the engine without a callback (withdrawn from the queue, or ended after a session change)
    # must not keep the receipts, hence every write, blocked for the rest of the session.
    if($null -ne $script:Guard -and $script:Guard.ReceiptJob -and $null -ne $script:AsyncJobs -and -not $script:AsyncJobs.Contains([string]$script:Guard.ReceiptJob)){$script:Guard.ReceiptJob=''}
    if($null -eq $script:Guard -or $script:Guard.ReceiptJob -or $script:AsyncEngineClosing){return}
    if(@($script:AsyncJobs.Values|Where-Object{$_.IsWrite -or $_.OperationId -eq 'ReceiptStore'}).Count){return}
    if($Action -ne 'List' -and [string]$Id -notmatch '^[a-f0-9]{32}$'){throw 'Selectionnez un recu valide.'}
    $script:ReceiptReady=$false
    try{
        $script:Guard.ReceiptJob=Start-UiTask -Name 'Verifier les recus locaux' -OperationId 'ReceiptStore' -Code (Get-DomeniaReceiptWorkerCode) -Payload ([pscustomobject]@{Action=$Action;Id=$Id;Reason=$Reason}) -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;Action=$Action}) -SuccessHandler 'Complete-DomeniaReceiptRefresh' -ErrorHandler 'Fail-DomeniaReceiptRefresh' -NonCancellable -TimeoutSeconds 25 -TaskClass 'Explicit'
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
function Set-DomeniaReadFallbackConsent {
    # SE-07 : demande propre a une lecture. L'autorisation d'intervention ne dit rien d'une
    # lecture ; sans cette demande, le worker rend un « non lu » au lieu de basculer.
    if(Test-DomeniaAccessBusyWrite){Show-InfoBox 'Terminez la vérification de lʼécriture avant de modifier une autorisation.';return}
    $target='';try{if($script:SelectedObject.Type -eq 'Machine'){$target=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'dNSHostName');if(-not $target){$target=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'name')}}}catch{}
    if(-not $target){Show-InfoBox 'Sélectionnez une machine dans la recherche.';return}
    if(-not (Confirm-Action -Message ('CIM ne répond pas sur '+$target+'. Lire ce poste par tâche planifiée ? Cette autorisation ne vaudra que pour la prochaine lecture de ce poste et sera retirée après elle. Le Planificateur utilise une API ; PsExec exige une session Windows intégrée autorisée. Aucun secret ne sera transmis dans les arguments.') -Title 'Lecture par tâche planifiée')){return}
    $aliases=@($target);$short=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'name');if($short -and $short -notmatch '[\/]'){$aliases+=@($short)}
    $script:ReadFallbackConsent=[pscustomobject]@{Target=$target;Aliases=$aliases;Epoch=[long]$script:SessionEpoch;Expires=[datetime]::UtcNow.AddMinutes(5)}
    [void](Set-DomeniaControlText 'LblGuardReadFallback' ('Autorisation de lecture accordée pour '+$target+'. Lancez la lecture : cette autorisation ne servira quʼà cette lecture.'))
}
function Read-DomeniaOuFavouriteStore {
    # FO-04: every OU favourite kept locally (all domains), as validated perimeters. Never a result or an account.
    $text=[string](Get-DomeniaSetting 'OuFavouritesJson' '[]')
    if([string]::IsNullOrWhiteSpace($text)){return @()}
    $parsed=$null;try{$parsed=ConvertFrom-Json -InputObject $text}catch{return @()}
    $list=[Collections.Generic.List[object]]::new()
    foreach($value in @($parsed)){$v=ConvertTo-DomeniaOuFavourite $value;if($null -ne $v){$list.Add($v)}}
    return $list.ToArray()
}
function Write-DomeniaOuFavouriteStore {
    param($Favourites)
    $items=@(foreach($f in @($Favourites)){if($null -ne $f){[ordered]@{DN=[string]$f.DN;Name=[string]$f.Name;Subtree=[bool]$f.Subtree;Type=[string]$f.Type;Term=[string]$f.Term}}})
    $json=if($items.Count -eq 0){'[]'}else{ConvertTo-Json -InputObject $items -Depth 3 -Compress}
    Set-DomeniaSetting 'OuFavouritesJson' $json;Save-DomeniaSettings -Immediate
}
function Import-DomeniaFavouriteSearchesOnce {
    # FO-04: the former saved searches (hidden Fiabilité block) become OU favourites once. SavedSearches itself is
    # kept as it was; a whole-domain text search has no OU to pin and is not taken over.
    if(ConvertTo-SuiteFlag (Get-DomeniaSetting 'OuFavouritesImported' $false) -Default $false){return 0}
    $result=Import-DomeniaOuFavourites -Existing @(Read-DomeniaOuFavouriteStore) -SavedSearches @(Get-DomeniaSetting 'SavedSearches' @())
    if([int]$result.Imported -gt 0){Write-DomeniaOuFavouriteStore -Favourites $result.Favourites}
    Set-DomeniaSetting 'OuFavouritesImported' $true;Save-DomeniaSettings -Immediate
    if([int]$result.Imported -gt 0){Write-AppLog ('Favoris dʼOU repris des recherches enregistrées : '+[int]$result.Imported+'. Les recherches enregistrées sont conservées.') 'INFO'}
    return [int]$result.Imported
}
function Get-DomeniaFavouriteSearches {
    # FO-04: OU favourites of the current domain, in their pinned order.
    $domain=[string]$script:Conn.BaseDn;$list=[Collections.Generic.List[object]]::new()
    if(-not $domain){return $list.ToArray()}
    foreach($value in @(Read-DomeniaOuFavouriteStore)){$v=ConvertTo-DomeniaOuFavourite $value $domain;if($null -ne $v){$list.Add($v)}}
    return $list.ToArray()
}
function Test-DomeniaOuFavourite {
    param([string]$Dn)
    if(-not $Dn){return $false}
    return (@(Get-DomeniaFavouriteSearches|Where-Object{[string]$_.DN -ieq $Dn}).Count -gt 0)
}
function Save-DomeniaFavouriteSearch {
    # FO-04: pins the OU chosen in the tree (or -Dn) above the tree; -Remove forgets it, -Toggle switches. A local
    # preference only: no dialog window, no directory read, never a result, an account, a right or a write mode.
    param([string]$Dn='',[switch]$Remove,[switch]$Toggle)
    if(-not $Dn){$Dn=[string]$script:SelectedBranchDn}
    $domain=[string]$script:Conn.BaseDn
    if(-not $Dn -or -not $domain){Set-Status 'Choisissez dʼabord une OU dans lʼarbre.' 'WARN';return $false}
    $pinned=(-not $Remove)
    if($Toggle){$pinned=(-not (Test-DomeniaOuFavourite -Dn $Dn))}
    $name='';try{$name=[string](Get-DomeniaUxOuDisplay -DistinguishedName $Dn -IsDomain ($Dn -ieq $domain)).Name}catch{}
    $candidate=[pscustomobject]@{DN=$Dn;Name=$name;Subtree=$true;Type='Tous';Term=''}
    $r=Set-DomeniaOuFavouriteState -Favourites @(Read-DomeniaOuFavouriteStore) -Favourite $candidate -Pinned $pinned -DomainDn $domain
    if(-not [bool]$r.Changed){Set-Status ([string]$r.Reason) 'WARN';return $false}
    Write-DomeniaOuFavouriteStore -Favourites $r.Favourites
    Update-DomeniaOuFavouritesUi
    if($pinned){Set-Status ('OU épinglée dans les favoris : '+$(if($name){$name}else{$Dn})+'. Préférence locale, rien nʼest lu ni modifié dans lʼannuaire.')}
    else{Set-Status 'OU retirée des favoris. Rien nʼest modifié dans lʼannuaire.'}
    return $true
}
function Load-DomeniaFavouriteSearch {
    # FO-04 / CO-21: shows a favourite OU. Its depth and type go to their visible controls and its term, if any, to
    # the visible local filter of the results: nothing filters the list out of sight. One read of that OU follows.
    param([string]$Dn='')
    $v=@(Get-DomeniaFavouriteSearches|Where-Object{[string]$_.DN -ieq $Dn}|Select-Object -First 1)
    if($v.Count -eq 0){Set-Status 'Favori ignoré : il ne correspond pas au domaine de cette session.' 'WARN';return}
    $v=$v[0]
    if(-not (Test-DomeniaDraftNavigation '')){return}
    if(Test-DomeniaAccessBusyWrite){Set-Status 'Favori non affiché : une écriture est active ou à vérifier.' 'WARN';return}
    Stop-DomeniaFavouriteTreeReveal
    if($null -ne $script:Continuity){$script:Continuity.Restoring=$false;$script:Continuity.RestoreSearch=$null}
    # UX-25: the list being left is saved before the favourite changes the type and the local filter shown with it.
    $navEntered=$false
    if($null -ne (Get-Command Enter-DomeniaNavSearch -CommandType Function -ErrorAction SilentlyContinue)){Enter-DomeniaNavSearch;$navEntered=[bool]$script:NavSearchLaunching}
    try {
        $oldRestore=$script:RestoringSettings;$oldSuppress=$script:SuppressBranchAutoLoad
        $script:RestoringSettings=$true;$script:SuppressBranchAutoLoad=$true
        try {
            $script:SelectedBranchDn=[string]$v.DN
            [void](Set-DomeniaControlText 'TxtBranchSearch' '')
            $check=Get-DomeniaControl 'ChkSubtree';if($null -ne $check){$check.IsChecked=[bool]$v.Subtree}
            $combo=Get-DomeniaControl 'CmbGlobalType';if($null -ne $combo){foreach($item in $combo.Items){if([string]$item.Content -eq [string]$v.Type){$combo.SelectedItem=$item;break}}}
            $filter=Get-DomeniaControl 'TxtSuiteResultFilter';if($null -ne $filter){$filter.Text=[string]$v.Term}
        } finally {$script:RestoringSettings=$oldRestore;$script:SuppressBranchAutoLoad=$oldSuppress}
        Update-DomeniaSearchScopeUi;Select-DomeniaWorkspace -Workspace 'WsSearch'
        $generation=[int]$script:GlobalSearchGeneration
        Invoke-GlobalSearch -SearchMode OU
        Start-DomeniaFavouriteTreeReveal -Dn ([string]$v.DN)
        # CO-21: the term of a favourite filters only the rows read (within the result limit), not the directory.
        if([string]$v.Term -and [int]$script:GlobalSearchGeneration -ne $generation){
            $limitBox=Get-DomeniaControl 'TxtGlobalLimit';$limit=if($null -ne $limitBox){[string]$limitBox.Text}else{''}
            $note='Favori '+[string]$v.Name+' : le filtre local '+[string]$v.Term+' porte sur les lignes lues seulement'+$(if($limit){' (limite '+$limit+')'}else{''})+', pas sur lʼannuaire.'
            [void](Set-DomeniaControlText 'LblSearchHint' $note);Set-Status $note
        }
    } finally {
        # A search refused before its start leaves no launch open behind it (nothing is recorded then).
        if($navEntered -and [bool]$script:NavSearchLaunching){$script:NavSearchLaunching=$false}
    }
}
function Update-DomeniaOuFavouritesUi {
    # FO-04: the favourites section pinned above the OU tree, the stars of the tree and the pin button of the menu.
    [void](Import-DomeniaFavouriteSearchesOnce)
    $favourites=@(Get-DomeniaFavouriteSearches)
    $keys=@{};foreach($f in $favourites){$keys[([string]$f.DN).ToLowerInvariant()]=$true}
    $script:OuFavouriteKeys=$keys
    if($null -ne (Get-Command Get-DomeniaRealizedTreeNodes -CommandType Function -ErrorAction SilentlyContinue)){
        # Get-DomeniaRealizedTreeNodes returns its array as one object: enumerate it, do not wrap it again.
        foreach($n in (Get-DomeniaRealizedTreeNodes)){
            $dn=[string]$n.Tag.DN;if(-not $dn){continue}
            $status=if($keys.ContainsKey($dn.ToLowerInvariant())){'Favori'}else{''}
            if([string][Windows.Automation.AutomationProperties]::GetItemStatus($n) -cne $status){[Windows.Automation.AutomationProperties]::SetItemStatus($n,$status)}
        }
    }
    $toggle=Get-DomeniaControl 'BtnOuFavouriteToggle'
    if($null -ne $toggle){$toggle.Content=if($keys.ContainsKey(([string]$script:SelectedBranchDn).ToLowerInvariant())){'Retirer des favoris'}else{'Épingler cette OU'}}
    $panel=Get-DomeniaControl 'PnlOuFavourites';$section=Get-DomeniaControl 'UxOuFavourites'
    if($null -eq $panel){return}
    $panel.Children.Clear()
    foreach($f in $favourites){
        $path=[string]$f.DN;try{$path=[string](Get-DomeniaUxOuDisplay -DistinguishedName ([string]$f.DN)).FullPath}catch{}
        $row=[Windows.Controls.DockPanel]::new();$row.Margin=[Windows.Thickness]::new(0,0,0,2)
        $remove=[Windows.Controls.Button]::new();$remove.Content=[string][char]0x00D7;$remove.Tag=[string]$f.DN;$remove.MinWidth=0;$remove.MinHeight=0;$remove.Padding=[Windows.Thickness]::new(6,0,6,0);$remove.Margin=[Windows.Thickness]::new(4,0,0,0)
        $remove.ToolTip='Retirer '+[string]$f.Name+' des favoris. Rien nʼest modifié dans lʼannuaire.'
        [Windows.Automation.AutomationProperties]::SetName($remove,'Retirer le favori '+[string]$f.Name)
        $remove.Add_Click({param($sender,$eventArgs) try{[void](Save-DomeniaFavouriteSearch -Dn ([string]$sender.Tag) -Remove)}catch{Write-AppLog ('Favori : '+$_.Exception.Message) 'WARN'}})
        [Windows.Controls.DockPanel]::SetDock($remove,[Windows.Controls.Dock]::Right)
        $open=[Windows.Controls.Button]::new();$open.Tag=[string]$f.DN;$open.HorizontalContentAlignment=[Windows.HorizontalAlignment]::Left;$open.MinHeight=0;$open.Padding=[Windows.Thickness]::new(8,2,8,2)
        $label=[Windows.Controls.TextBlock]::new();$label.Text=[string][char]0x2605+' '+[string]$f.Name;$label.TextTrimming=[Windows.TextTrimming]::CharacterEllipsis;$open.Content=$label
        $tip='Affiche le contenu de '+$path+'.';if([string]$f.Term){$tip+=' Filtre local repris : '+[string]$f.Term+'.'}
        $open.ToolTip=$tip
        [Windows.Automation.AutomationProperties]::SetName($open,'Favori '+[string]$f.Name)
        $open.Add_Click({param($sender,$eventArgs) try{Load-DomeniaFavouriteSearch -Dn ([string]$sender.Tag)}catch{Write-AppLog ('Favori : '+$_.Exception.Message) 'WARN';Set-Status ('Favori non affiché : '+$_.Exception.Message) 'WARN'}})
        [void]$row.Children.Add($remove);[void]$row.Children.Add($open)
        [void]$panel.Children.Add($row)
    }
    if($null -ne $section){$section.Visibility=if($favourites.Count -gt 0){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
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
        BtnGuardDraft={Show-DomeniaDraftComparison};BtnGuardRemote={Set-DomeniaArtifactConsent};BtnGuardRemoteOff={$script:ArtifactConsent=$null;[void](Set-DomeniaControlText 'LblGuardRemote' 'Depots et services non autorises par defaut.')};BtnGuardReadFallback={Set-DomeniaReadFallbackConsent}
        BtnGuardStoreResume={Resume-DomeniaStorage};BtnGuardLegacyImport={Request-DomeniaLegacyImport};BtnGuardWhy={Show-DomeniaUnavailableReasons};BtnGuardExport={Export-DomeniaTechnicalDossier}
        BtnGuardPesto={Open-DomeniaSuiteTool Pesto};BtnGuardFilPro={Open-DomeniaSuiteTool FilPro}
        # FO-04: the former saved searches block is gone; OU favourites are pinned above the tree (Rechercher).
        BtnOuFavouriteToggle={try{[void](Save-DomeniaFavouriteSearch -Toggle)}catch{Write-AppLog ('Favori : '+$_.Exception.Message) 'WARN'}}
    }
    foreach($n in $actions.Keys){$c=Get-DomeniaControl $n;if($null -ne $c){$body=$actions[$n];$c.Add_Click($body)}}
    try{Update-DomeniaOuFavouritesUi}catch{Write-AppLog ('Favoris dʼOU : '+$_.Exception.Message) 'WARN'}
    # FI-05 / PF-06: protected heartbeat timer, owned and registered by the factory, once per second and aligned on the
    # other subscribers at rest. The Dispatcher delay is the lateness measured by the heartbeat itself.
    $script:Guard.Timer=New-DomeniaTimer -Owner 'Timer:Guard' -IntervalMs 1000 -IdleIntervalMs 1000 -Tick {
        param($sender,$eventArgs)
        if($script:AsyncEngineClosing -or $null -eq $script:Guard){return}
        $now=[datetime]::UtcNow;$delay=[Math]::Round([double]$sender.LateMs,1);$script:Guard.Last=$now
        $script:Guard.Samples.Add($delay);if($script:Guard.Samples.Count -gt 240){$script:Guard.Samples.RemoveAt(0)}
        try{Add-DomeniaRuntimeMetric -Provenance 'Dispatcher' -OperationId 'Pulse' -DurationMs $delay}catch{}
        # W13 (point 121): a late heartbeat is explained by the interface work that overlapped it, or said unattributed.
        try{[void](Register-DomeniaDispatcherLateness -LateMs $delay)}catch { $script:DomeniaTraceFaults = [int]$script:DomeniaTraceFaults + 1 }
        if($script:Guard.Epoch -ne [long]$script:SessionEpoch){$script:Guard.Epoch=[long]$script:SessionEpoch;$script:ReceiptReady=$false;$script:ReceiptRefreshNeeded=$true;$script:ArtifactConsent=$null;$script:DraftState=$null}
        if(($script:ReceiptRefreshNeeded -or -not $script:ReceiptReady) -and $now -ge $script:Guard.NextReceipt){Start-DomeniaReceiptRefresh}
        $tab=Get-DomeniaControl 'TabGuard'
        if($null -ne $tab -and $tab.IsSelected){
            $p95=Get-DomeniaPercentile $script:Guard.Samples.ToArray() 95;$p50=Get-DomeniaPercentile $script:Guard.Samples.ToArray() 50
            # D028: the local save state comes from the rule, through the same reader as the Live state line.
            [void](Set-DomeniaControlText 'LblGuardMetrics' ('Retard du Dispatcher (local) p50/p95 : '+$p50+' / '+$p95+' ms. Taches : '+$script:AsyncJobs.Count+'. Enregistrement local : '+(Get-DomeniaPersistenceState).Label+' Mesure indicative, pas un benchmark reseau.'))
        }
    };$script:Guard.Timer.Start()
    $script:Window.Add_Closed({if($null -ne $script:Guard){$script:Guard.Timer.Stop()};$script:DraftState=$null;$script:ArtifactConsent=$null})
    $script:ReceiptRefreshNeeded=$true;Start-DomeniaReceiptRefresh
}
function Set-DomeniaProtectedClipboard {
    # D059: one bounded value. The native writer excludes it from the Windows clipboard history and cloud sync;
    # third-party clipboard managers remain outside Domenia's control (Get-DomeniaSecretExposurePolicy).
    param([string]$Value,[int]$MaxLength=8192)
    $limit=[Math]::Max(1,[Math]::Min(8192,$MaxLength))
    if([string]::IsNullOrEmpty($Value) -or $Value.Length -gt $limit){throw 'Valeur de copie absente ou hors limite.'}
    if($null -eq ('Domenia.Secrets.ClipboardWriter' -as [type])){Add-Type -Path (Join-Path $script:RootDir 'modules\Domenia-Clipboard.Native.cs') -ErrorAction Stop}
    $owner=[Windows.Interop.WindowInteropHelper]::new($script:Window).Handle
    [Domenia.Secrets.ClipboardWriter]::Set($owner,$Value)
}

function Remove-DomeniaFavouriteSearch {
    # FO-04: forgets one OU favourite (local preference, reversible with the star). Nothing changes in the directory.
    param([string]$Dn='')
    return (Save-DomeniaFavouriteSearch -Dn $Dn -Remove)
}
function Resume-DomeniaStorage {
    if($null -eq $script:Persistence){return}
    if($script:Persistence.Job){Show-InfoBox 'Un enregistrement est encore actif.';return}
    $script:Persistence.Failures=0;$script:Persistence.Fault='';$script:Persistence.Next=[datetime]::UtcNow
    # MO-03: the save timer stopped while the writer was suspended; it is armed again here.
    try{Request-DomeniaStorageWork}catch{}
    Set-Status 'Reprise demandee pour les lots de cache en memoire. Aucune ecriture AD.'
}
function Show-DomeniaUnavailableReasons {
    $reasons=Get-DomeniaUnavailableReasonLines
    $first=@($reasons.Routes|Where-Object{$_}|Select-Object -First 1)
    $details=(@($reasons.Lines) -join "`r`n")
    if($first.Count){
        $target=Resolve-DomeniaCapabilityRoute -Route ([string]$first[0])
        $answer=Show-DomeniaDialog -Title 'Pourquoi une action est indisponible ?' -Message ('Ce bilan lit uniquement les etats de la session. Il ne teste ni ne modifie les droits. Ouvrir le premier prerequis : '+[string]$target.Label+' ?') -Details $details -Kind Question -Buttons YesNo
        if($answer -eq [Windows.MessageBoxResult]::Yes){[void](Invoke-DomeniaCapabilityRoute -Route ([string]$first[0]))}
        return
    }
    Show-DomeniaDialog -Title 'Pourquoi une action est indisponible ?' -Message 'Ce bilan lit uniquement les etats de la session. Il ne teste ni ne modifie les droits.' -Details $details -Kind Info | Out-Null
}
