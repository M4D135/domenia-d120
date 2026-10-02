# Definition-only module. Network work is started solely by an explicit search action.
$script:Relations=$null
function Initialize-DomeniaRelationsState {
    if($null -eq $script:Relations){
        $script:Relations=[pscustomobject]@{
            Epoch=[long]$script:SessionEpoch;Subject=$null;Generation=0L;Query=$null;Completed=@{};Timer=$null;Bound=$false;Rendering=$false;PendingConfirmed=$null
            ManualSearchJob='';ManualSearchRequest='';ManualSearchRows=@();PendingAssociation=$null
        }
    }
    if($script:Relations.Epoch -ne [long]$script:SessionEpoch){
        if($null -ne $script:Relations.Timer){$script:Relations.Timer.Stop()}
        foreach($job in @([string]$script:Relations.ManualSearchJob, $(if($null -ne $script:Relations.Query){[string]$script:Relations.Query.Job}else{''}))){if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Session Relations remplacée'}catch{}}}
        $script:Relations.Epoch=[long]$script:SessionEpoch;$script:Relations.Subject=$null;$script:Relations.Query=$null
        $script:Relations.Completed=@{};$script:Relations.Generation++;$script:Relations.PendingConfirmed=$null
        $script:Relations.ManualSearchJob='';$script:Relations.ManualSearchRequest='';$script:Relations.ManualSearchRows=@();$script:Relations.PendingAssociation=$null
    }
}
function Set-DomeniaRelationsSelection {
    param($Row,$Object)
    Initialize-DomeniaRelationsState
    if($script:SuppressGridSelectionEvents){return}
    $s=$null
    if($null -ne $Row -and [string]$Row.Type -in @('Utilisateur','Machine')){
        $s=[pscustomobject]@{Type=[string]$Row.Type;Login=[string]$Row.Login;Name=[string]$Row.Name;DN=[string]$Row.DN;Guid=[string]$Row.Guid}
    }elseif($null -ne $Object -and [string]$Object.Type -in @('Utilisateur','Machine')){
        $s=[pscustomobject]@{Type=[string]$Object.Type;Login=(Get-DomeniaEntryFirstString $Object.Entry 'sAMAccountName');Name=[string]$Object.Name;DN=[string]$Object.DN;Guid=[string]$Object.Safety.Guid}
    }
    if($null -eq $s -or -not $s.DN){return}
    if($null -ne $script:Relations.Subject -and $script:Relations.Subject.DN -ieq $s.DN -and $script:Relations.Subject.Guid -ieq $s.Guid){$script:Relations.Subject=$s;Refresh-DomeniaRelationViews;return}
    $r=$script:Relations
    foreach($job in @([string]$r.ManualSearchJob,$(if($null -ne $r.Query){[string]$r.Query.Job}else{''}))){if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Sélection Relations modifiée'}catch{}}}
    if($null -ne $r.Timer){$r.Timer.Stop()}
    $r.Subject=$s;$r.Generation++;$r.Query=$null;$r.PendingConfirmed=$null;$r.PendingAssociation=$null
    $r.ManualSearchJob='';$r.ManualSearchRequest='';$r.ManualSearchRows=@()
    $tabs=Get-DomeniaControl 'RelationTabs';$tab=Get-DomeniaControl 'TabLinksSelected'
    if($null -ne $tabs -and $null -ne $tab){$tabs.SelectedItem=$tab}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Associations connues ; détection ou recherche dʼun poste dans lʼonglet Associer.')
    Refresh-DomeniaRelationViews
}
function Set-DomeniaRelationsGridSelection {
    if($script:SuppressGridSelectionEvents -or (Test-DomeniaAccessBusyWrite)){return}
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -ne $grid -and @($grid.SelectedItems).Count -eq 1){Set-DomeniaRelationsSelection -Row $grid.SelectedItem}
}
function Get-DomeniaRelationsSubject {
    Initialize-DomeniaRelationsState
    if($null -eq $script:Relations.Subject -and $null -ne $script:SelectedObject){Set-DomeniaRelationsSelection -Object $script:SelectedObject}
    return $script:Relations.Subject
}
function Get-DomeniaRelationsIdentity {
    $ad=Get-DomeniaRetryCredential 'UserComputerProbe';if($null -eq $ad){$ad=$script:Conn.Credential}
    $remote=Get-DomeniaRetryCredential 'LiveConsole';if($null -eq $remote){$remote=$script:MachineCredential};if($null -eq $remote){$remote=$script:RemoteAdminCredential};if($null -eq $remote){$remote=$script:Conn.Credential}
    $a=if($null -ne $ad){[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ad)}else{0}
    $b=if($null -ne $remote){[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($remote)}else{0}
    return ([string]$script:SessionEpoch+'|'+$script:Conn.BaseDn+'|'+$script:Conn.Server+'|'+$script:Conn.BindUser+'|'+$a+'|'+$b)
}
function Test-DomeniaRelationsCurrent {
    param($State)
    if($null -eq $State -or $null -eq $script:Relations -or $null -eq $script:Relations.Subject -or $null -eq $script:Relations.Query){return $false}
    $r=$script:Relations;$s=$r.Subject
    return ($State.Epoch -eq [long]$script:SessionEpoch -and $State.BaseDn -ieq [string]$script:Conn.BaseDn -and
        $r.Query.AcceptResults -and $State.Identity -ceq (Get-DomeniaRelationsIdentity) -and
        $State.Generation -eq $r.Generation -and $State.RequestId -ceq $r.Query.RequestId -and
        $State.DN -ieq $s.DN -and $State.Guid -ieq $s.Guid -and $State.Login -ieq $s.Login -and $s.Type -eq 'Utilisateur')
}
function Get-DomeniaRelationsSelectedLinks {
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s){return}
    $links=if($s.Type -eq 'Utilisateur'){@(Get-LinksForUser $s.Login)}else{@(Get-LinksForComputer $s.Name)}
    foreach($l in $links){
        # Legacy rows without GUID are historical. A known, different GUID must never join by a reused name.
        $guid=if($s.Type -eq 'Utilisateur'){[string]$l.UserGuid}else{[string]$l.ComputerGuid}
        if($guid -and $s.Guid -and $guid -ine $s.Guid){continue}
        Write-Output $l
    }
}
function Get-DomeniaRelationsActiveGrid {
    $tabs=Get-DomeniaControl 'RelationTabs'
    if($null -ne $tabs -and $null -ne $tabs.SelectedItem -and [string]$tabs.SelectedItem.Name -eq 'TabLinksAll'){return (Get-DomeniaControl 'DgAllLinks')}
    if($null -ne $tabs -and $null -ne $tabs.SelectedItem -and [string]$tabs.SelectedItem.Name -ne 'TabLinksSelected'){return $null}
    return (Get-DomeniaControl 'DgLinks')
}
function Update-DomeniaRelationsActions {
    $s=Get-DomeniaRelationsSubject;$r=$script:Relations
    $isUser=($null -ne $s -and $s.Type -eq 'Utilisateur')
    $busyDetect=($null -ne $r.Query -and -not $r.Query.Ended)
    $busySearch=(-not [string]::IsNullOrWhiteSpace([string]$r.ManualSearchJob))
    $locked=Test-DomeniaAccessBusyWrite
    foreach($n in @('BtnDetectUserComputers','CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents')){
        $c=Get-DomeniaControl $n;if($null -eq $c){continue};$c.IsEnabled=($isUser -and -not $busyDetect -and -not $locked)
    }
    $stop=Get-DomeniaControl 'BtnRelationsStop';if($null -ne $stop){$stop.IsEnabled=$busyDetect;$stop.Visibility=if($busyDetect){'Visible'}else{'Hidden'}}
    $remove=Get-DomeniaControl 'BtnRemoveLink';$grid=Get-DomeniaRelationsActiveGrid
    if($null -ne $remove){$remove.IsEnabled=($null -ne $grid -and $null -ne $grid.SelectedItem -and -not $locked)}
    $d=Get-DomeniaControl 'DgRelationCandidates';$candidate=if($null -ne $d){$d.SelectedItem}else{$null}
    $open=Get-DomeniaControl 'BtnRelationOpenCandidate';if($null -ne $open){$open.IsEnabled=($isUser -and $null -ne $candidate -and [bool]$candidate.DN -and -not $busyDetect -and -not $locked)}
    $adopt=Get-DomeniaControl 'BtnRelationAdopt';if($null -ne $adopt){$adopt.IsEnabled=($isUser -and $null -ne $candidate -and [bool]$candidate.DN -and -not $busyDetect -and -not $locked)}
    $box=Get-DomeniaControl 'TxtRelationComputerSearch';$go=Get-DomeniaControl 'BtnRelationComputerSearch';$mg=Get-DomeniaControl 'DgRelationComputerSearch';$ma=Get-DomeniaControl 'BtnRelationAssociateSearchResult'
    if($null -ne $box){$box.IsEnabled=($isUser -and -not $busySearch -and -not $locked)}
    if($null -ne $go){$go.IsEnabled=($isUser -and -not $busySearch -and -not $locked)}
    if($null -ne $mg){$mg.IsEnabled=(-not $busySearch)}
    if($null -ne $ma){$ma.IsEnabled=($isUser -and $null -ne $mg -and $null -ne $mg.SelectedItem -and -not $busySearch -and -not $locked)}
    $associateTab=Get-DomeniaControl 'TabLinksAssociate';if($null -ne $associateTab){$associateTab.IsEnabled=$isUser}
    $hint=Get-DomeniaControl 'LblRelationAssociateHint';if($null -ne $hint){$hint.Text=if($isUser){'Utilisateur : '+$s.Login+' · choisissez Détecter ou Rechercher un poste.'}else{'Sélectionnez un utilisateur dans Rechercher pour associer un poste.'}}
    $confirm=Get-DomeniaControl 'RelationConfirmPanel';if($null -ne $confirm){$confirm.Visibility=if($null -ne $r.PendingAssociation){'Visible'}else{'Collapsed'}}
}
function Refresh-DomeniaRelationViews {
    param([switch]$ProgressOnly)
    Initialize-DomeniaRelationsState
    if($script:Relations.Rendering){return}
    $script:Relations.Rendering=$true
    try{
        if(-not $ProgressOnly){
            $s=Get-DomeniaRelationsSubject;$rows=@(Get-DomeniaRelationsSelectedLinks)
            $grid=Get-DomeniaControl 'DgLinks';$selected=if($null -ne $grid){$grid.SelectedItem}else{$null}
            [void](Set-DomeniaItemsSource 'DgLinks' $rows);if($null -ne $selected -and $rows -contains $selected){$grid.SelectedItem=$selected}
            $allGrid=Get-DomeniaControl 'DgAllLinks';$allSelected=if($null -ne $allGrid){$allGrid.SelectedItem}else{$null}
            [void](Set-DomeniaItemsSource 'DgAllLinks' @($script:UserMachineLinks));if($null -ne $allSelected -and @($script:UserMachineLinks) -contains $allSelected){$allGrid.SelectedItem=$allSelected}
            $title=if($null -eq $s){'Sélectionnez un utilisateur ou un poste depuis Rechercher.'}elseif($s.Type -eq 'Utilisateur'){'Utilisateur : '+$s.Login}else{'Poste : '+$s.Name}
            [void](Set-DomeniaControlText 'LblRelationsSelection' $title)
            [void](Set-DomeniaControlText 'LblLinkContext' ($title+' · '+$rows.Count+' association(s) mémorisée(s).'))
            $lbl=Get-DomeniaControl 'LblRelationsSelection';if($null -ne $lbl -and $null -ne $s){$lbl.ToolTip=$s.DN}
            [void](Set-DomeniaControlText 'LblLinkEmpty' $(if($null -eq $s){'Recherchez un utilisateur en haut, sélectionnez sa ligne, puis ouvrez Relations.'}else{'Aucune association mémorisée pour cette sélection. Utilisez lʼonglet Associer pour détecter ou rechercher un poste.'}))
            $empty=Get-DomeniaControl 'LinkEmptyPanel';if($null -ne $empty){$empty.Visibility=if($rows.Count){'Collapsed'}else{'Visible'}}
            [void](Set-DomeniaItemsSource 'DgRelationComputerSearch' @($script:Relations.ManualSearchRows))
        }
        $q=$script:Relations.Query
        if($null -ne $q){[void](Set-DomeniaItemsSource 'DgRelationCandidates' @(@($q.Candidates.Values|Sort-Object Computer)+@($q.Hints)));[void](Set-DomeniaItemsSource 'DgLinkAttempts' @($q.Attempts))}
        else{[void](Set-DomeniaItemsSource 'DgRelationCandidates' @());[void](Set-DomeniaItemsSource 'DgLinkAttempts' @())}
        if($null -ne $script:Relations.PendingAssociation){
            $p=$script:Relations.PendingAssociation
            [void](Set-DomeniaControlText 'LblRelationConfirm' ($p.User+' → '+$p.Computer+' · '+$p.Source+'. Cette association est locale à Domenia et ne modifie pas Active Directory.'))
        }else{[void](Set-DomeniaControlText 'LblRelationConfirm' '')}
        Update-DomeniaRelationsActions
    }finally{$script:Relations.Rendering=$false}
}
function Invoke-DomeniaRelationsTick {
    $r=$script:Relations
    if($null -eq $r -or $script:AsyncEngineClosing){return}
    $q=$r.Query
    if($null -eq $q -or -not (Test-DomeniaRelationsCurrent $q.State)){
        if($null -ne $r.Timer){$r.Timer.Stop()};$r.PendingConfirmed=$null;return
    }
    if(-not $q.Ended -and $q.Job){
        $job=$null;if($null -ne $script:AsyncJobs){$job=$script:AsyncJobs[$q.Job]}
        if($null -eq $job -or $job.CancelRequested){
            $q.Ended=$true;$q.AcceptResults=$false;$q.Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();$r.PendingConfirmed=$null
            if($null -ne $r.Timer){$r.Timer.Stop()}
            [void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Lecture interrompue. Résultats provisoires non enregistrés ; anciennes associations conservées.')
            Update-DomeniaRelationsActions;return
        }
    }
    if(Test-DomeniaAccessBusyWrite){return}
    $watch=[Diagnostics.Stopwatch]::StartNew();$n=0;$changed=$false;$ev=$null
    while($n -lt 8 -and $watch.ElapsedMilliseconds -lt 4 -and $q.Progress.TryDequeue([ref]$ev)){
        $n++;if($ev.RequestId -cne $q.RequestId){continue}
        switch([string]$ev.Kind){
            'Candidate'{$q.Candidates[[string]$ev.Value.Guid]=$ev.Value;$changed=$true}
            'Hint'{[void]$q.Hints.Add($ev.Value);$changed=$true}
            'Attempt'{[void]$q.Attempts.Add($ev.Value);$changed=$true}
            'Status'{[void](Set-DomeniaControlText 'LblLinkProbeStatus' ([string]$ev.Value))}
        }
    }
    if($changed){Refresh-DomeniaRelationViews -ProgressOnly}
    if($null -ne $r.PendingConfirmed -and ($null -eq $script:Persistence -or -not $script:Persistence.LinkBusy)){
        $pending=$r.PendingConfirmed;$r.PendingConfirmed=$null
        if(Test-DomeniaRelationsCurrent $pending.State){Save-DomeniaRelationConfirmations $pending.Result $pending.State}
    }
    if($q.Ended -and $q.Progress.Count -eq 0 -and $null -eq $r.PendingConfirmed -and $null -ne $r.Timer){$r.Timer.Stop()}
}
function Save-DomeniaRelationConfirmations {
    param($Result,$State)
    if(-not (Test-DomeniaRelationsCurrent $State) -or (Test-DomeniaAccessBusyWrite)){return}
    $changes=@($Result.Candidates|Where-Object{$_.Confirmed -eq $true -and $_.Guid -and $_.DN}|Select-Object -First 50)
    if(-not $changes.Count){return}
    if($null -ne $script:Persistence -and $script:Persistence.LinkBusy){$script:Relations.PendingConfirmed=[pscustomobject]@{Result=$Result;State=$State};return}
    $before=@($script:UserMachineLinks);$working=[Collections.Generic.List[object]]::new()
    foreach($l in $before){$working.Add($l)}
    $count=0
    foreach($c in $changes){
        $existing=@($working|Where-Object{(Normalize-LinkComputer $_.Computer) -ieq (Normalize-LinkComputer $c.Computer)}|Select-Object -First 1)
        if($existing.Count -and [string]$existing[0].Source -match '^(?i:Saisie manuelle|Manual)'){continue}
        if($existing.Count){[void]$working.Remove($existing[0])}
        $working.Add([pscustomobject]@{UserLogin=$State.Login;Computer=(Normalize-LinkComputer $c.Computer);Source='Console CIM/DCOM';Confidence=97;VerifiedInAD=$true;When=$c.ObservedUtc;Details=$c.Detail;UserGuid=$Result.UserGuid;UserDn=$State.DN;ComputerGuid=$c.Guid;ComputerDn=$c.DN})
        $count++
    }
    if(-not $count){return}
    $script:UserMachineLinks=$working.ToArray()
    if(-not (Save-UserMachineLinks)){$script:UserMachineLinks=$before;Rebuild-UserMachineLinkIndex;Set-Status 'Consoles observées, mais associations non enregistrées. Voir le stockage dans Fiabilité.' 'WARN'}
    else{Write-AppLog ($count.ToString()+' association(s) de console confirmée en mémoire ; sauvegarde demandée en arrière-plan.') 'INFO'}
    Refresh-AssociationContext -SkipResultRefresh
}
function Complete-DomeniaRelationsSearch {
    param($Result,$State)
    if(-not (Test-DomeniaRelationsCurrent $State)){Write-AppLog 'Retour de recherche inverse ignoré : sélection ou session différente.' 'INFO';return}
    $r=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Attempts','RequestId','UserDn')
    if($null -eq $r -or $r.RequestId -cne $State.RequestId -or $r.UserDn -ine $State.DN -or $r.Login -ine $State.Login){throw 'Retour de recherche inverse incohérent.'}
    if($State.Guid -and $r.UserGuid -and $State.Guid -ine $r.UserGuid){throw 'GUID utilisateur modifié pendant la recherche inverse.'}
    $q=$script:Relations.Query;$q.Ended=$true;$q.Job='';$q.Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();$q.Candidates=@{}
    foreach($c in @($r.Candidates)){$q.Candidates[[string]$c.Guid]=$c}
    $q.Attempts=[Collections.ArrayList]::new();foreach($a in @($r.Attempts)){[void]$q.Attempts.Add($a)}
    $q.Hints=[Collections.ArrayList]::new();foreach($h in @($r.Hints)){[void]$q.Hints.Add($h)}
    $known=@(Get-DomeniaRelationsSelectedLinks).Count;$confirmed=@($r.Candidates|Where-Object{$_.Confirmed -eq $true}).Count
    $message=if(-not $r.Success){
        $first=@($r.Attempts|Where-Object{$_.Status -notin @('OK','VIDE','NON_DEMANDE')}|Select-Object -First 1)
        $reason=if($first.Count){' '+[string]$first[0].Method+' : '+[string]$first[0].Detail}else{''}
        'Recherche AD non confirmée.'+$reason+' Les associations connues restent conservées.'
    }else{
        '{0} association(s) connue(s), {1} candidat(s), {2} console(s) confirmée(s) sur {3} poste(s) interrogé(s).' -f $known,@($r.Candidates).Count,$confirmed,[int]$r.ScanStats.Probed
    }
    if($r.Partial){$message+=' Résultat partiel : limites ou erreurs dans Détail de la recherche.'}
    if($r.Success -and -not $r.Scanned){$message+=' Aucun poste contacté.'}
    if($r.Success -and -not @($r.Candidates).Count){$message+=' Aucun indice supplémentaire ; cela ne signifie pas que l utilisateur ne possède aucun poste.'}
    if($r.Success){Save-DomeniaRelationConfirmations $r $State}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' $message);Set-Status $message;Write-AppLog $message 'INFO'
    # Each resource reports its own failure. There is no automatic replay of the search.
    foreach($resource in @('Directory','Remote')){
        $fault=@($r.Attempts|Where-Object{$_.Resource -eq $resource -and $_.Status -in @('AUTH_REJETEE','REFUSE')}|Select-Object -First 1)
        if($fault.Count){
            $op=if($resource -eq 'Directory'){'UserComputerProbe'}else{'ComputerInventory'}
            $target=if($resource -eq 'Remote'){[string]$fault[0].User}else{''}
            $candidate=@($r.Candidates|Where-Object{$_.Computer -ieq $target}|Select-Object -First 1)
            $targetDn=if($resource -eq 'Remote' -and $candidate.Count){[string]$candidate[0].DN}else{$State.DN}
            $summary=if($fault[0].Status -eq 'AUTH_REJETEE'){'Identifiants invalides : '}else{'Accès refusé : '}
            [void](Request-DomeniaAccessRecovery -Operation ('Relations : '+$resource) -OperationId $op -ErrorValue ($summary+[string]$fault[0].Detail) -DN $targetDn -Target $target)
        }
    }
    Refresh-DomeniaRelationViews
    if($null -ne $script:Relations.PendingConfirmed -and $null -ne $script:Relations.Timer){$script:Relations.Timer.Start()}
}
function Fail-DomeniaRelationsSearch {
    param($Message,$State)
    if(-not (Test-DomeniaRelationsCurrent $State)){return}
    $q=$script:Relations.Query;$q.Ended=$true;$q.Job='';$q.Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    [void]$q.Attempts.Add([pscustomobject]@{Method='Recherche interrompue';Status='NON_CONFIRME';User=$State.Login;Score='';DurationMs=0;Detail=[string]$Message;Resource='';Code=0})
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Recherche non terminée : '+[string]$Message+'. Les liens existants sont conservés ; les résultats provisoires ne sont pas enregistrés.'))
    Write-AppLog ('Recherche inverse non terminée : '+[string]$Message) 'WARN';Refresh-DomeniaRelationViews
}
function Start-DomeniaRelationsSearch {
    try{
        $s=Get-DomeniaRelationsSubject
        if($null -eq $s -or $s.Type -ne 'Utilisateur'){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Sélectionnez dʼabord un utilisateur dans Rechercher.');return}
        if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Une écriture reste active ou à vérifier.');return}
        $r=$script:Relations;if($null -ne $r.Query -and -not $r.Query.Ended){return}
        $scan=$true;$events=[bool](Get-DomeniaControl 'ChkRelationEvents').IsChecked
        $scope=[string](Get-DomeniaControl 'CmbRelationScanScope').SelectedItem.Tag;if($scope -notin @('Candidates','Loaded','OU')){$scope='Candidates'}
        $limit=20;$raw=[string](Get-DomeniaControl 'TxtRelationScanLimit').Text
        if(-not [int]::TryParse($raw,[ref]$limit) -or $limit -lt 1 -or $limit -gt 50){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Maximum invalide : choisissez une valeur de 1 à 50.');return}
        $known=@(Get-DomeniaRelationsSelectedLinks);$loaded=@($script:BranchObjects|Where-Object{$_.Type -eq 'Machine'}|ForEach-Object{[string]$_.Name}|Select-Object -Unique -First 50)
        # Detect is an explicit network action. If 'known candidates' is empty, use a useful bounded scope instead of doing zero probes.
        if($scope -eq 'Candidates' -and -not $known.Count){
            if(-not [string]::IsNullOrWhiteSpace([string]$script:SelectedBranchDn)){$scope='OU'}
            elseif($loaded.Count){$scope='Loaded'}
        }
        $base=[string]$script:SelectedBranchDn;$depth=if([bool](Get-DomeniaControl 'ChkSubtree').IsChecked){'Subtree'}else{'OneLevel'};if(-not $base){$base=[string]$script:Conn.BaseDn}
        if($scope -eq 'Loaded' -and -not $loaded.Count){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Aucune machine dans la liste chargée. Choisissez une OU ou recherchez un poste manuellement.');return}
        if($scope -eq 'Candidates' -and -not $known.Count){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Aucun poste connu à vérifier. Choisissez une OU ou utilisez Rechercher.');return}
        if($scope -eq 'OU' -and ([string]::IsNullOrWhiteSpace([string]$script:SelectedBranchDn) -or [string]$script:SelectedBranchDn -ieq [string]$script:Conn.BaseDn)){
            if($loaded.Count){$scope='Loaded'}else{[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Choisissez d abord une OU contenant des postes, ou utilisez Rechercher. Aucun balayage du domaine entier n est lancé.');return}
        }
        $request=[guid]::NewGuid().ToString('N')
        $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$r.Generation;DN=$s.DN;Guid=$s.Guid;Login=$s.Login;BaseDn=[string]$script:Conn.BaseDn;RequestId=$request;Identity=(Get-DomeniaRelationsIdentity)}
        $progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();$r.Query=[pscustomobject]@{RequestId=$request;State=$state;Progress=$progress;Candidates=@{};Hints=[Collections.ArrayList]::new();Attempts=[Collections.ArrayList]::new();Ended=$false;AcceptResults=$true;Job=''}
        $payload=[pscustomobject]@{RequestId=$request;Login=$s.Login;UserDn=$s.DN;UserGuid=$s.Guid;KnownLinks=@($known|ForEach-Object{[pscustomobject]@{Computer=[string]$_.Computer;ComputerGuid=[string]$_.ComputerGuid;When=[string]$_.When;Source=[string]$_.Source}});ScanPark=$scan;ScanScope=$scope;ScanBaseDn=$base;ScanDepth=$depth;LoadedComputers=$loaded;MaxProbes=$limit;UseSecurityLog=$events;BudgetMs=$(if($scan){120000}else{45000});Progress=$progress}
        $tabs=Get-DomeniaControl 'RelationTabs';if($null -ne $tabs){$tabs.SelectedItem=Get-DomeniaControl 'TabLinksAssociate'}
        $modes=Get-DomeniaControl 'RelationAssociateModeTabs';if($null -ne $modes){$modes.SelectedItem=Get-DomeniaControl 'TabRelationDetect'}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Détection de '+$s.Login+' : préparation du périmètre '+$scope+'…'))
        $r.Query.Job=Start-UiTask -Name ('Postes de '+$s.Login) -OperationId 'UserComputerProbe' -Code (Get-DomeniaRelationsWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'userprobe' -DisableControls @('BtnDetectUserComputers','CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents') -TimeoutSeconds $(if($scan){140}else{65}) -SuccessHandler 'Complete-DomeniaUserComputersUi' -ErrorHandler 'Fail-DomeniaUserComputersUi'
        if($null -ne $r.Timer){$r.Timer.Start()};Refresh-DomeniaRelationViews
    }catch{if($null -ne $script:Relations.Query){$script:Relations.Query.Ended=$true;$script:Relations.Query.Job=''};[void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Détection impossible : '+$_.Exception.Message));Write-AppLog ('Relations : '+$_.Exception.ToString()) 'WARN'}
}
function Stop-DomeniaRelationsSearch {
    if($null -ne $script:Relations -and $null -ne $script:Relations.Query -and $script:Relations.Query.Job){
        $q=$script:Relations.Query
        Request-UiTaskStop -Id $q.Job -Reason 'Recherche inverse annulée par l opérateur'
        $q.AcceptResults=$false;$q.Ended=$true;$q.Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();$script:Relations.PendingConfirmed=$null
        if($null -ne $script:Relations.Timer){$script:Relations.Timer.Stop()}
        Update-DomeniaRelationsActions
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Arrêt demandé. Les liens enregistrés sont conservés ; attente de la fin réelle de la lecture.')
    }
}
function Use-DomeniaRelationCandidate {
    param([switch]$Open)
    $s=Get-DomeniaRelationsSubject;$d=Get-DomeniaControl 'DgRelationCandidates';$c=if($null -ne $d){$d.SelectedItem}else{$null}
    if($null -eq $s -or $s.Type -ne 'Utilisateur' -or $null -eq $c -or -not $c.DN -or (Test-DomeniaAccessBusyWrite)){return}
    if($Open){Open-AdObject -Dn ([string]$c.DN) -Type Machine;return}
    Set-DomeniaRelationPendingAssociation -Computer ([string]$c.Computer) -DN ([string]$c.DN) -Guid ([string]$c.Guid) -Source ([string]$c.Source)
}
function Initialize-DomeniaRelationsUi {
    Initialize-DomeniaRelationsState
    if($script:Relations.Bound){return};$script:Relations.Bound=$true
    $t=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$t.Interval=[timespan]::FromMilliseconds(120);$t.Add_Tick({try{Invoke-DomeniaRelationsTick}catch{Write-AppLog ('Affichage des relations : '+$_.Exception.Message) 'WARN'}});$script:Relations.Timer=$t
    $script:Window.Add_Closed({if($null -ne $script:Relations){$script:Relations.Timer.Stop();$script:Relations.Query=$null;$script:Relations.Subject=$null;$script:Relations.PendingConfirmed=$null;$script:Relations.PendingAssociation=$null}})
    $tabs=Get-DomeniaControl 'RelationTabs';if($null -ne $tabs){$tabs.Add_SelectionChanged({param($sender,$e) if($e.OriginalSource -eq $sender){Update-DomeniaRelationsActions}})}
    foreach($name in @('DgAllLinks','DgRelationCandidates','DgRelationComputerSearch')){$g=Get-DomeniaControl $name;if($null -ne $g){$g.Add_SelectionChanged({Update-DomeniaRelationsActions})}}
    $search=Get-DomeniaControl 'BtnRelationComputerSearch';if($null -ne $search){$search.Add_Click({Start-DomeniaRelationComputerSearch})}
    $term=Get-DomeniaControl 'TxtRelationComputerSearch';if($null -ne $term){$term.Add_KeyDown({param($s,$e)if($e.Key -eq 'Return'){$e.Handled=$true;Start-DomeniaRelationComputerSearch}});$term.Add_TextChanged({if($null -ne $script:Relations){$script:Relations.ManualSearchRows=@();$script:Relations.PendingAssociation=$null;Refresh-DomeniaRelationViews}})}
    $assoc=Get-DomeniaControl 'BtnRelationAssociateSearchResult';if($null -ne $assoc){$assoc.Add_Click({Request-DomeniaRelationManualAssociation})}
    $exportAll=Get-DomeniaControl 'BtnExportAllLinks';if($null -ne $exportAll){$exportAll.Add_Click({$tabs=Get-DomeniaControl 'RelationTabs';$all=Get-DomeniaControl 'TabLinksAll';if($null -ne $tabs -and $null -ne $all){$tabs.SelectedItem=$all};Export-DomeniaLinksCsv})}
    $cancel=Get-DomeniaControl 'BtnRelationConfirmCancel';if($null -ne $cancel){$cancel.Add_Click({Cancel-DomeniaRelationAssociation})}
    $apply=Get-DomeniaControl 'BtnRelationConfirmApply';if($null -ne $apply){$apply.Add_Click({Confirm-DomeniaRelationAssociation})}
    (Get-DomeniaControl 'BtnRelationsStop').Add_Click({Stop-DomeniaRelationsSearch})
    (Get-DomeniaControl 'BtnRelationOpenCandidate').Add_Click({Use-DomeniaRelationCandidate -Open})
    (Get-DomeniaControl 'BtnRelationAdopt').Add_Click({Use-DomeniaRelationCandidate})
    $workspace=Get-DomeniaControl 'WorkspaceTabs';if($null -ne $workspace){$workspace.Add_SelectionChanged({param($sender,$e) if($e.OriginalSource -eq $sender -and [string]$sender.SelectedItem.Name -eq 'TabRelations'){Refresh-DomeniaRelationViews}})}
    Refresh-DomeniaRelationViews
}

function Start-DomeniaRelationComputerSearch {
    Initialize-DomeniaRelationsState;$r=$script:Relations;$s=Get-DomeniaRelationsSubject
    if($null -eq $s -or $s.Type -ne 'Utilisateur'){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Sélectionnez dʼabord un utilisateur dans Rechercher.');return}
    if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Une écriture reste active ou à vérifier.');return}
    if($r.ManualSearchJob){return}
    $term=([string](Get-DomeniaControl 'TxtRelationComputerSearch').Text).Trim()
    if($term.Length -lt 2){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Saisissez au moins deux caractères.');return}
    $request=[guid]::NewGuid().ToString('N');$r.ManualSearchRequest=$request;$r.ManualSearchRows=@();$r.PendingAssociation=$null
    [void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Recherche des postes dans tout le domaine…')
    $state=[pscustomobject]@{RequestId=$request;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;Generation=$r.Generation;SubjectDn=$s.DN;SubjectGuid=$s.Guid}
    $payload=[pscustomobject]@{Kind='Machine';Term=$term;Verify=$false;RequestId=$request;DN='';Guid=''}
    $r.ManualSearchJob=Start-UiTask -Name 'Recherche de poste à associer' -OperationId 'EmbeddedDirectoryLookup' -Code (Get-DomeniaEmbeddedLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'relations:computer-search' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaRelationComputerSearch' -ErrorHandler 'Fail-DomeniaRelationComputerSearch'
    Update-DomeniaRelationsActions
}
function Test-DomeniaRelationManualState {
    param($State)
    $r=$script:Relations;$s=Get-DomeniaRelationsSubject
    return ($null -ne $r -and $null -ne $s -and $s.Type -eq 'Utilisateur' -and $State.Epoch -eq [long]$script:SessionEpoch -and $State.BaseDn -ieq [string]$script:Conn.BaseDn -and $State.Generation -eq $r.Generation -and $State.RequestId -ceq $r.ManualSearchRequest -and $State.SubjectDn -ieq $s.DN -and $State.SubjectGuid -ieq $s.Guid)
}
function Complete-DomeniaRelationComputerSearch {
    param($Result,$State)
    if(-not (Test-DomeniaRelationManualState $State)){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','RequestId','Verified')
    $script:Relations.ManualSearchJob=''
    if($null -eq $data -or $data.RequestId -cne $State.RequestId -or [bool]$data.Verified){Fail-DomeniaRelationComputerSearch 'Retour de recherche incohérent.' $State;return}
    $script:Relations.ManualSearchRows=@($data.Rows)
    $msg=if($script:Relations.ManualSearchRows.Count){$script:Relations.ManualSearchRows.Count.ToString()+' poste(s) trouvé(s). Sélectionnez une ligne puis Associer ce poste.'}else{'Aucun poste correspondant dans le domaine.'}
    if($data.Capped){$msg+=' Limite atteinte : affinez la recherche.'}
    [void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' $msg);Refresh-DomeniaRelationViews
}
function Fail-DomeniaRelationComputerSearch {
    param($Message,$State)
    if(-not (Test-DomeniaRelationManualState $State)){return}
    $script:Relations.ManualSearchJob='';$script:Relations.ManualSearchRows=@();[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' ('Recherche non confirmée : '+[string]$Message));Refresh-DomeniaRelationViews
}
function Set-DomeniaRelationPendingAssociation {
    param([string]$Computer,[string]$DN,[string]$Guid,[string]$Source='Recherche AD')
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s -or $s.Type -ne 'Utilisateur' -or -not $Computer -or -not $DN){return}
    $script:Relations.PendingAssociation=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$script:Relations.Generation;User=$s.Login;UserDn=$s.DN;UserGuid=$s.Guid;Computer=(Normalize-LinkComputer $Computer);DN=$DN;Guid=$Guid;Source=$Source;Job=''}
    Refresh-DomeniaRelationViews
}
function Request-DomeniaRelationManualAssociation {
    $g=Get-DomeniaControl 'DgRelationComputerSearch';$row=if($null -ne $g){$g.SelectedItem}else{$null}
    if($null -eq $row){return}
    Set-DomeniaRelationPendingAssociation -Computer ([string]$row.Name) -DN ([string]$row.DN) -Guid ([string]$row.Guid) -Source 'Recherche AD manuelle'
}
function Cancel-DomeniaRelationAssociation {
    if($null -ne $script:Relations -and $null -ne $script:Relations.PendingAssociation){$job=[string]$script:Relations.PendingAssociation.Job;if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Association annulée'}catch{}};$script:Relations.PendingAssociation=$null;Refresh-DomeniaRelationViews}
}
function Confirm-DomeniaRelationAssociation {
    $p=$script:Relations.PendingAssociation
    if($null -eq $p -or $p.Job -or (Test-DomeniaAccessBusyWrite)){return}
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s -or $s.Type -ne 'Utilisateur' -or $p.Epoch -ne [long]$script:SessionEpoch -or $p.Generation -ne $script:Relations.Generation -or $p.UserDn -ine $s.DN -or $p.UserGuid -ine $s.Guid){Cancel-DomeniaRelationAssociation;return}
    [void](Set-DomeniaControlText 'LblRelationConfirm' ($p.User+' → '+$p.Computer+' · vérification du poste dans Active Directory…'))
    $request=[guid]::NewGuid().ToString('N')
    $state=[pscustomobject]@{RequestId=$request;Epoch=$p.Epoch;BaseDn=[string]$script:Conn.BaseDn;Generation=$p.Generation;Pending=$p}
    $payload=[pscustomobject]@{Kind='Machine';Term='';Verify=$true;RequestId=$request;DN=$p.DN;Guid=$p.Guid}
    $p.Job=Start-UiTask -Name 'Vérification de l association' -OperationId 'EmbeddedDirectoryLookup' -Code (Get-DomeniaEmbeddedLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'relations:verify-association' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaRelationAssociationVerify' -ErrorHandler 'Fail-DomeniaRelationAssociationVerify'
    Update-DomeniaRelationsActions
}
function Complete-DomeniaRelationAssociationVerify {
    param($Result,$State)
    $p=$State.Pending;$s=Get-DomeniaRelationsSubject
    if($null -eq $p -or $script:Relations.PendingAssociation -ne $p -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $script:Relations.Generation -or $null -eq $s -or $s.DN -ine $p.UserDn){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Verified')
    if($null -eq $data -or -not [bool]$data.Verified -or @($data.Rows).Count -ne 1){Fail-DomeniaRelationAssociationVerify 'Le poste n a pas pu être revérifié.' $State;return}
    $row=@($data.Rows)[0]
    if($row.DN -ine $p.DN -or $row.Guid -ine $p.Guid){Fail-DomeniaRelationAssociationVerify 'Le poste a changé depuis la sélection. Relancez la recherche.' $State;return}
    $p.Job='';[void](Add-UserMachineLinkIfMissing -UserLogin $p.User -Computer $p.Computer -Source 'Saisie manuelle' -Details ('Association confirmée dans Relations depuis '+$p.Source+'.') -Confidence 100 -VerifiedInAD $true)
    $script:Relations.PendingAssociation=$null;[void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Association enregistrée : '+$p.User+' → '+$p.Computer+'.'));Refresh-DomeniaRelationViews
}
function Fail-DomeniaRelationAssociationVerify {
    param($Message,$State)
    $p=$State.Pending;if($null -eq $p -or $script:Relations.PendingAssociation -ne $p){return};$p.Job='';[void](Set-DomeniaControlText 'LblRelationConfirm' ('Vérification impossible : '+[string]$Message+'. Aucune association enregistrée.'));Update-DomeniaRelationsActions
}

function Get-DomeniaRelationsWorkerCode {
return @'
# Read-only inverse lookup. The exact user and the two credential channels stay separate.
$clock=[Diagnostics.Stopwatch]::StartNew()
$attempts=[Collections.Generic.List[object]]::new()
$items=@{};$eventHints=[Collections.Generic.List[object]]::new()
$partial=$false;$directoryReads=0;$probed=0;$matched=0;$denied=0;$remoteStopped=$false;$script:RelationDirectoryBlocked=$false
$budget=[Math]::Max(10000,[Math]::Min(180000,[int]$Payload.BudgetMs))
$limit=[Math]::Max(1,[Math]::Min(50,[int]$Payload.MaxProbes))
$login=[string]$Payload.Login;$userDn=[string]$Payload.UserDn;$userGuid=[string]$Payload.UserGuid
$domain=[string]$Context.Domain;$netbios=[string]$Context.Netbios
$base=[string]$Context.BaseDn;$upn='';$userSid=''
if(-not $login -or -not $userDn -or -not $base){throw 'Utilisateur et domaine requis pour la recherche inverse.'}
if(-not $userDn.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase)){throw 'Utilisateur hors du domaine de la session.'}
function Publish-Relation {
    param([string]$Kind,$Value)
    if($null -ne $Payload.Progress -and $Payload.Progress.Count -lt 256){
        $Payload.Progress.Enqueue([pscustomobject]@{RequestId=[string]$Payload.RequestId;Kind=$Kind;Value=$Value})
    }
}
function Add-RelationAttempt {
    param([string]$Method,[string]$Status,[string]$Target,[string]$Detail,[string]$Resource='Directory',[long]$Code=0)
    $item=[pscustomobject]@{Method=$Method;Status=$Status;User=$Target;Score='';DurationMs=[long]$clock.ElapsedMilliseconds;Detail=$Detail;Resource=$Resource;Code=$Code}
    $attempts.Add($item);Publish-Relation 'Attempt' $item
}
function Test-RelationBudget { return ($clock.ElapsedMilliseconds -lt $budget) }
function Get-RelationFailure {
    param($Record)
    $e=$Record.Exception;$code=0L;$text=[string]$Record
    for($i=0;$i -lt 8 -and $null -ne $e;$i++){
        $code=([long]$e.HResult -band 4294967295L)
        if($code -in @(2147943726L,2148074252L,2147943730L,2147944309L)){return 'AUTH_REJETEE'}
        if($code -in @(2147942405L,2147749891L)){return 'REFUSE'}
        $e=$e.InnerException
    }
    if($text -match '(?i)0x8007052e|logon failure|nom d.utilisateur ou mot de passe|identification.*valid|credentials.*invalid'){return 'AUTH_REJETEE'}
    if($text -match '(?i)0x80070005|0x80041003|access.*denied|acc[eè]s.*refus|unauthorized'){return 'REFUSE'}
    if($text -match '(?i)timeout|timed out|d[eé]lai'){return 'DELAI'}
    return 'ERREUR'
}
function Read-RelationDirectory {
    param([string]$Root,[string]$Filter,[string[]]$Properties,[string]$Scope='Subtree',[int]$Maximum=100)
    if($script:RelationDirectoryBlocked){throw [Security.Authentication.AuthenticationException]::new('Canal AD suspendu après rejet des identifiants ; aucun nouvel essai.')}
    if(-not (Test-RelationBudget)){throw [TimeoutException]::new('Budget de recherche atteint.')}
    $s=$null;$owned=$null;$collection=$null;$rows=[Collections.Generic.List[object]]::new()
    try{
        $s=New-WSearcher $Context $Root $Filter $Properties $Scope ($Maximum+1)
        $owned=$s.SearchRoot;$s.PageSize=40;$s.CacheResults=$false
        $s.ServerTimeLimit=[timespan]::FromSeconds(8);$s.ClientTimeout=[timespan]::FromSeconds(10)
        $collection=$s.FindAll()
        foreach($r in $collection){
            if($rows.Count -ge $Maximum){$script:RelationWasCapped=$true;break}
            $v=@{}
            foreach($p in $Properties){$v[$p.ToLowerInvariant()]=Get-WPropFirst $r.Properties $p $null}
            $rows.Add([pscustomobject]$v)
        }
        return $rows.ToArray()
    }catch{
        if((Get-RelationFailure $_) -eq 'AUTH_REJETEE'){$script:RelationDirectoryBlocked=$true}
        throw
    }finally{
        if($null -ne $collection){$collection.Dispose()}
        if($null -ne $s){$s.Dispose()}
        if($null -ne $owned){$owned.Dispose()}
    }
}
function Add-RelationComputer {
    param($Row,[string]$Source,[string]$Detail,[string]$Status='Indice AD')
    $name=([string]$Row.name).Trim();$dn=[string]$Row.distinguishedname
    $guid=Convert-WGuid $Row.objectguid;$dns=([string]$Row.dnshostname).Trim()
    if(-not $name -or -not $dn -or -not $guid){return}
    if($name -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$'){return}
    if($dns -and $dns -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$'){return}
    $key=$guid.ToLowerInvariant()
    if($items.ContainsKey($key)){
        $old=$items[$key]
        if($old.Source -notlike ('*'+$Source+'*')){$old.Source+=' + '+$Source}
        $old.Detail+=' | '+$Detail
        Publish-Relation 'Candidate' ([pscustomobject]@{Computer=$old.Computer;Dns=$old.Dns;DN=$old.DN;Guid=$old.Guid;Source=$old.Source;Status=$old.Status;Detail=$old.Detail;ObservedUtc=$old.ObservedUtc;CurrentUser=$old.CurrentUser;Confirmed=$old.Confirmed;Known=$old.Known})
        return
    }
    $item=[pscustomobject]@{Computer=$name;Dns=$dns;DN=$dn;Guid=$guid;Source=$Source;Status=$Status;Detail=$Detail;ObservedUtc='';CurrentUser='';Confirmed=$false;Known=($Source -eq 'Association mémorisée')}
    $items[$key]=$item;Publish-Relation 'Candidate' ($item.PSObject.Copy())
}
$script:RelationWasCapped=$false
$computerProps=@('name','dNSHostName','distinguishedName','objectGUID','description','managedBy')
# Read exactly the selected account, never its edited text fields, and never try alternate identities.
try{
    $u=@(Read-RelationDirectory $userDn '(&(objectCategory=person)(objectClass=user))' @('sAMAccountName','userPrincipalName','objectGUID','objectSid') 'Base' 1);$directoryReads++
    if($u.Count -ne 1){throw 'Compte sélectionné non retrouvé dans Active Directory.'}
    $actualGuid=Convert-WGuid $u[0].objectguid
    if(-not $actualGuid){throw 'GUID du compte non lisible : aucune association ne sera inventée.'}
    if($userGuid -and $actualGuid -ine $userGuid){throw 'Le compte a été recréé : rechargez sa fiche avant de chercher ses postes.'}
    if([string]$u[0].samaccountname -ine $login){throw 'Identifiant du compte modifié : rechargez la sélection.'}
    $userGuid=$actualGuid;$upn=[string]$u[0].userprincipalname
    try{$userSid=[Security.Principal.SecurityIdentifier]::new([byte[]]$u[0].objectsid,0).Value}catch{$userSid=''}
    Add-RelationAttempt 'Compte sélectionné' 'OK' $login ('Compte relu sur '+[string]$Context.Server+'.')
}catch{
    $kind=Get-RelationFailure $_
    Add-RelationAttempt 'Compte sélectionné' $kind $login ([string]$_.Exception.Message) 'Directory' ([long]$_.Exception.HResult)
    return [pscustomobject]@{Login=$login;UserDn=$userDn;UserGuid=$userGuid;RequestId=$Payload.RequestId;Candidates=@();Hints=@();Attempts=$attempts.ToArray();Success=$false;Partial=$true;Scanned=$false;ScanStats=[pscustomobject]@{Candidates=0;Reachable=0;Probed=0};DurationMs=[long]$clock.ElapsedMilliseconds;DirectoryReads=$directoryReads}
}
# Seed with known associations first. An old observation remains historical, not re-dated.
foreach($known in @($Payload.KnownLinks|Select-Object -First 50)){
    if($script:RelationDirectoryBlocked -or -not (Test-RelationBudget)){$partial=$true;break}
    try{
        $n=[string]$known.Computer;$e=Escape-WLdap $n
        $rows=@(Read-RelationDirectory $base ('(&(objectCategory=computer)(|(name='+$e+')(dNSHostName='+$e+')(sAMAccountName='+$e+'$)))') $computerProps 'Subtree' 2);$directoryReads++
        if($rows.Count -eq 1){
            $g=Convert-WGuid $rows[0].objectguid
            if($known.ComputerGuid -and $g -ine [string]$known.ComputerGuid){Add-RelationAttempt 'Association mémorisée' 'A_REVOIR' $n 'GUID différent : ancien lien conservé comme historique, poste non sondé.';continue}
            Add-RelationComputer $rows[0] 'Association mémorisée' ('Observation antérieure : '+[string]$known.When+' ; '+[string]$known.Source+'. Ne prouve pas une session actuelle.') 'Historique connu'
            if($items.ContainsKey($g.ToLowerInvariant())){$items[$g.ToLowerInvariant()].ObservedUtc=[string]$known.When}
        }else{Add-RelationAttempt 'Association mémorisée' 'A_REVOIR' $n 'Poste non résolu de façon unique. Le lien historique reste conservé.'}
    }catch{$partial=$true;Add-RelationAttempt 'Association mémorisée' (Get-RelationFailure $_) ([string]$known.Computer) ([string]$_.Exception.Message) 'Directory' ([long]$_.Exception.HResult)}
}
# Directory clues are candidates only. Ownership/description is not an observed session.
$escapedDn=Escape-WLdap $userDn;$escapedLogin=Escape-WLdap $login
foreach($spec in @(
    @{Name='Responsable déclaré';Filter=('(&(objectCategory=computer)(managedBy='+$escapedDn+'))');Status='Responsable déclaré'},
    @{Name='Mention du compte';Filter=('(&(objectCategory=computer)(|(description=*'+$escapedLogin+'*)(location=*'+$escapedLogin+'*)))');Status='Indice textuel'}
)){
    if($script:RelationDirectoryBlocked -or -not (Test-RelationBudget)){$partial=$true;break}
    try{
        $rows=@(Read-RelationDirectory $base $spec.Filter $computerProps 'Subtree' 100);$directoryReads++
        foreach($r in $rows){Add-RelationComputer $r $spec.Name ('Indice dans la fiche AD. '+[string]$r.description) $spec.Status}
        Add-RelationAttempt $spec.Name $(if($rows.Count){'OK'}else{'VIDE'}) '' ($rows.Count.ToString()+' candidat(s) ; aucune session déduite de cet attribut.')
    }catch{$partial=$true;Add-RelationAttempt $spec.Name (Get-RelationFailure $_) '' ([string]$_.Exception.Message) 'Directory' ([long]$_.Exception.HResult)}
}
# Optional server-side event query: preserve the IP verbatim as an authentication clue, never as a hostname.
if([bool]$Payload.UseSecurityLog -and -not $script:RelationDirectoryBlocked -and (Test-RelationBudget)){
    try{
        if(-not $userSid -or $userSid -notmatch '^S-\d(-\d+)+$'){throw 'SID indisponible : lecture des événements non effectuée.'}
        $ms=[long][timespan]::FromDays(7).TotalMilliseconds
        $xpath="*[System[EventID=4768 and TimeCreated[timediff(@SystemTime) <= $ms]]] and *[EventData[Data[@Name='TargetSid']='$userSid' and Data[@Name='Status']='0x0']]"
        $par=@{ComputerName=[string]$Context.Server;LogName='Security';FilterXPath=$xpath;MaxEvents=100;ErrorAction='Stop'}
        $adCredential=Get-WAdCredential $Context;if($null -ne $adCredential){$par.Credential=$adCredential}
        $events=@(Get-WinEvent @par);$seen=@{}
        foreach($ev in $events){
            $x=[xml]$ev.ToXml();$d=@{};foreach($v in @($x.Event.EventData.Data)){$d[[string]$v.Name]=[string]$v.'#text'}
            if([string]$d.TargetSid -ine $userSid){continue}
            $ip=[string]$d.IpAddress
            if(-not $ip -or $seen.ContainsKey($ip)){continue};$seen[$ip]=$true
            $hint=[pscustomobject]@{Computer=$ip;Dns='';DN='';Guid='';Source='Événement Kerberos 4768';Status='Indice IP, pas un poste identifié';Detail=('Authentification sur '+$Context.Server+'. Une IP ne prouve ni le poste AD ni une session ouverte.');ObservedUtc=$ev.TimeCreated.ToUniversalTime().ToString('o');CurrentUser=$login;Confirmed=$false;Known=$false}
            $eventHints.Add($hint);Publish-Relation 'Hint' $hint
        }
        if($events.Count -ge 100){$partial=$true}
        Add-RelationAttempt 'Journal du contrôleur' $(if($events.Count){'OK'}else{'VIDE'}) ([string]$Context.Server) ($events.Count.ToString()+' événement(s) ciblés sur le SID, sur ce contrôleur uniquement. Les IP ne sont pas associées automatiquement.')
    }catch{
        $noEvents=([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*')
        if(-not $noEvents){$partial=$true}
        Add-RelationAttempt 'Journal du contrôleur' $(if($noEvents){'VIDE'}else{Get-RelationFailure $_}) ([string]$Context.Server) ([string]$_.Exception.Message) 'Directory' ([long]$_.Exception.HResult)
    }
}
# An explicit scan may add the loaded list or a chosen OU. No hidden whole-domain enumeration.
if([bool]$Payload.ScanPark -and (Test-RelationBudget)){
    $mode=[string]$Payload.ScanScope
    $probeKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if($mode -notin @('Candidates','Loaded','OU')){throw 'Périmètre de vérification invalide.'}
    try{
        if($script:RelationDirectoryBlocked){throw 'Périmètre supplémentaire non lu : identifiants AD rejetés.'}
        if($mode -eq 'Loaded'){
            foreach($n in @($Payload.LoadedComputers|Select-Object -First 50)){
                if($script:RelationDirectoryBlocked -or -not (Test-RelationBudget)){$partial=$true;break}
                $escaped=Escape-WLdap ([string]$n)
                $rows=@(Read-RelationDirectory $base ('(&(objectCategory=computer)(|(name='+$escaped+')(dNSHostName='+$escaped+')(sAMAccountName='+$escaped+'$)))') $computerProps 'Subtree' 2);$directoryReads++
                if($rows.Count -eq 1){
                    Add-RelationComputer $rows[0] 'Liste chargée' 'Cible de vérification choisie explicitement.' 'À vérifier'
                    $g=Convert-WGuid $rows[0].objectguid;if($g -and $items.ContainsKey($g.ToLowerInvariant())){[void]$probeKeys.Add($g.ToLowerInvariant())}
                }
            }
        }elseif($mode -eq 'OU'){
            $root=[string]$Payload.ScanBaseDn
            if(-not $root -or ($root -ine $base -and -not $root.EndsWith(','+$base,[StringComparison]::OrdinalIgnoreCase))){throw 'OU hors du domaine courant.'}
            $scope=[string]$Payload.ScanDepth;if($scope -notin @('OneLevel','Subtree')){throw 'Profondeur de recherche invalide.'}
            $rows=@(Read-RelationDirectory $root '(objectCategory=computer)' $computerProps $scope $limit);$directoryReads++
            foreach($r in $rows){
                Add-RelationComputer $r 'OU choisie' 'Cible de vérification choisie explicitement ; ensemble borné, non exhaustif.' 'À vérifier'
                $g=Convert-WGuid $r.objectguid;if($g -and $items.ContainsKey($g.ToLowerInvariant())){[void]$probeKeys.Add($g.ToLowerInvariant())}
            }
        }
    }catch{$partial=$true;Add-RelationAttempt 'Périmètre de vérification' (Get-RelationFailure $_) ([string]$Payload.ScanBaseDn) ([string]$_.Exception.Message) 'Directory' ([long]$_.Exception.HResult)}
    $credential=Get-WMachineCredential $Context
    if([bool]$Context.RelationRemoteBlocked){$partial=$true;Add-RelationAttempt 'Consoles CIM/DCOM' 'AUTH_REJETEE' '' 'Canal distant suspendu après refus des identifiants. Choisissez un compte poste dans Accès ; aucune nouvelle tentative envoyée.' 'Remote'}
    elseif(-not [bool]$Context.UseCim){$partial=$true;Add-RelationAttempt 'Consoles CIM/DCOM' 'IGNORE' '' 'Lecture CIM désactivée par la configuration.' 'Remote'}
    else{
        $chosen=if($mode -eq 'Candidates'){@($items.Values)}else{@($probeKeys|ForEach-Object{$items[$_]})}
        $ordered=@($chosen|Sort-Object -Property @{Expression='Known';Descending=$true},Computer)
        if(-not $ordered.Count){Add-RelationAttempt 'Consoles CIM/DCOM' 'NON_EFFECTUE' '' 'Aucun poste résolu dans le périmètre choisi ; les indices hors de ce périmètre ne sont pas sondés.' 'Remote'}
        foreach($c in $ordered){
            if($probed -ge $limit -or -not (Test-RelationBudget)){$partial=$true;break}
            if($remoteStopped){$partial=$true;break}
            $probed++;$session=$null;$target=if($c.Dns){$c.Dns}else{$c.Computer}
            Publish-Relation 'Status' ('Vérification '+$probed+'/'+[Math]::Min($ordered.Count,$limit)+' : '+$c.Computer)
            try{
                # One credential, one protocol, no ICMP gate, no fallback task or registry history.
                $params=@{ComputerName=$target;SessionOption=(New-CimSessionOption -Protocol Dcom -ErrorAction Stop);OperationTimeoutSec=4;ErrorAction='Stop'}
                if($null -ne $credential){$params.Credential=$credential}
                $session=New-CimSession @params
                $cs=Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -Property UserName,Name -OperationTimeoutSec 4 -ErrorAction Stop
                if($null -eq $cs){throw 'Le poste ne renvoie pas de résultat CIM.'}
                if([string]$cs.Name -and [string]$cs.Name -ine $c.Computer){throw 'Nom du poste reçu différent de la cible AD ; résultat non attribué.'}
                $current=([string]$cs.UserName).Trim();$c.CurrentUser=$current;$c.ObservedUtc=[datetime]::UtcNow.ToString('o')
                $same=($current -and (($netbios -and $current -ieq ($netbios+'\'+$login)) -or ($domain -and $current -ieq ($domain+'\'+$login)) -or ($upn -and $current -ieq $upn)))
                if($same){$c.Confirmed=$true;$c.Status='Console confirmée';$c.Source='Console CIM/DCOM';$matched++}
                elseif($current){$c.Status='Autre compte console'}else{$c.Status='Aucun compte console'}
                $c.Detail='Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.'
                Add-RelationAttempt 'Console CIM/DCOM' $(if($same){'CONFIRME'}else{'LU'}) $c.Computer ($c.Status+'. '+$c.Detail) 'Remote'
            }catch{
                $kind=Get-RelationFailure $_;$partial=$true
                $c.Status=switch($kind){'AUTH_REJETEE'{'Identifiants rejetés'}'REFUSE'{'Lecture refusée'}'DELAI'{'Délai dépassé'}default{'Lecture non confirmée'}}
                $c.Detail=[string]$_.Exception.Message
                if($kind -in @('AUTH_REJETEE','REFUSE')){$denied++}
                if($kind -eq 'AUTH_REJETEE'){$remoteStopped=$true}
                Add-RelationAttempt 'Console CIM/DCOM' $kind $c.Computer $c.Detail 'Remote' ([long]$_.Exception.HResult)
            }finally{if($null -ne $session){Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue|Out-Null}}
            Publish-Relation 'Candidate' ($c.PSObject.Copy())
        }
    }
    if($items.Count -eq 0){Add-RelationAttempt 'Consoles CIM/DCOM' 'NON_EFFECTUE' '' 'Aucun poste candidat. Choisissez des machines dans la liste ou une OU explicite, ou associez un poste manuellement.' 'Remote'}
}else{
    Add-RelationAttempt 'Consoles CIM/DCOM' 'NON_DEMANDE' '' 'Aucun poste contacté. Cochez la vérification volontaire pour contrôler les consoles dans le périmètre choisi.' 'Remote'
}
$partial=$partial -or $script:RelationWasCapped -or -not (Test-RelationBudget)
[pscustomobject]@{Login=$login;UserDn=$userDn;UserGuid=$userGuid;RequestId=$Payload.RequestId;Candidates=@($items.Values|Sort-Object Computer);Hints=$eventHints.ToArray();Attempts=$attempts.ToArray();Success=$true;Partial=$partial;Scanned=[bool]$Payload.ScanPark;ScanStats=[pscustomobject]@{Candidates=$items.Count;Reachable=0;Probed=$probed;Matched=$matched;Denied=$denied};DurationMs=[long]$clock.ElapsedMilliseconds;DirectoryReads=$directoryReads}
'@
}
