# Definition-only module. Network work is started solely by an explicit search action.
# D041-D050: the relation rules of Domenia-Relations.Model.ps1 drive this page: both directions, stable subject,
# in-page association states, upsert without replacement, journal, and the perimeter shown before any workstation
# is contacted. CD-06 (RC1.14): the RC1.10.7 path and its switches Features.RelationsSymmetry and
# Features.DetectionPreview are removed; the relation model is the only path.
$script:Relations=$null
function Initialize-DomeniaRelationsState {
    if($null -eq $script:Relations){
        $script:Relations=[pscustomobject]@{
            Epoch=[long]$script:SessionEpoch;Subject=$null;Generation=0L;Query=$null;Completed=@{};Timer=$null;Bound=$false;Rendering=$false;PendingConfirmed=$null
            ManualSearchJob='';ManualSearchRequest='';ManualSearchRows=@();PendingAssociation=$null
            AssociationState='Idle';PendingPlan=$null;PendingRemoval=$null;SubjectNotice='';LastOutcome=$null;Revision=0L
            Observations=[Collections.Generic.List[object]]::new();History=[Collections.Generic.List[object]]::new();RestoreKnown=$false;RestoreEntry=$null
            DirtyComputers=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            RefreshPending=$false;ImportPlan=$null;LastImport=$null;Orphans=@();OrphanConfirm=$false;EvidenceMemo=$null;LastRefusal=''
        }
    }
    if($script:Relations.Epoch -ne [long]$script:SessionEpoch){
        if($null -ne $script:Relations.Timer){$script:Relations.Timer.Stop()}
        foreach($job in @([string]$script:Relations.ManualSearchJob, $(if($null -ne $script:Relations.Query){[string]$script:Relations.Query.Job}else{''}))){if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Session Relations remplacée'}catch{}}}
        $script:Relations.Epoch=[long]$script:SessionEpoch;$script:Relations.Subject=$null;$script:Relations.Query=$null
        $script:Relations.Completed=@{};$script:Relations.Generation++;$script:Relations.PendingConfirmed=$null
        $script:Relations.ManualSearchJob='';$script:Relations.ManualSearchRequest='';$script:Relations.ManualSearchRows=@();$script:Relations.PendingAssociation=$null
        # Session-only relations and the in-memory journal belong to the former session and its store.
        $script:Relations.AssociationState=[string](Step-DomeniaAssociationState ([string]$script:Relations.AssociationState) 'Reset').State
        $script:Relations.PendingPlan=$null;$script:Relations.PendingRemoval=$null;$script:Relations.SubjectNotice='';$script:Relations.LastOutcome=$null
        $script:Relations.Observations.Clear();$script:Relations.History.Clear();$script:Relations.DirtyComputers.Clear();$script:Relations.RestoreKnown=$false;$script:Relations.RestoreEntry=$null;$script:Relations.Revision++
        # An import preview, the last import and an orphan list belong to the former session and its store too.
        # Their panels are hidden at once and the operator is told why (review L04: they stayed shown and inert).
        $abandoned=($null -ne $script:Relations.ImportPlan -or $null -ne $script:Relations.LastImport -or @($script:Relations.Orphans).Count -gt 0)
        $script:Relations.ImportPlan=$null;$script:Relations.LastImport=$null;$script:Relations.Orphans=@();$script:Relations.OrphanConfirm=$false;$script:Relations.RefreshPending=$true
        $script:Relations.EvidenceMemo=$null;$script:Relations.LastRefusal=''
        if($abandoned){
            try{
                Update-DomeniaLinkImportUi;Update-DomeniaOrphanUi
                Set-Status 'Session ou domaine modifié : aperçu dʼimport, « Annuler lʼimport » et liste des orphelines fermés. Rien nʼa été enregistré ni retiré.' 'INFO'
            }catch{}
        }
    }
}
function Set-DomeniaRelationsSelection {
    param($Row,$Object,$SelectionIdentity=$null)
    Initialize-DomeniaRelationsState
    if($script:SuppressGridSelectionEvents){return}
    $rowType=if($null -ne $Row){ConvertTo-DomeniaRelationType ([string]$Row.Type)}else{''};$objectType=if($null -ne $Object){ConvertTo-DomeniaRelationType ([string]$Object.Type)}else{''}
    $s=$null
    if($null -ne $Row -and $rowType -in @('Utilisateur','Machine')){
        $s=[pscustomobject]@{Type=$rowType;Login=[string]$Row.Login;Name=[string]$Row.Name;DN=[string]$Row.DN;Guid=[string]$Row.Guid}
    }elseif($null -ne $Object -and $objectType -in @('Utilisateur','Machine')){
        $s=[pscustomobject]@{Type=$objectType;Login=(Get-DomeniaEntryFirstString $Object.Entry 'sAMAccountName');Name=[string]$Object.Name;DN=[string]$Object.DN;Guid=[string]$Object.Safety.Guid}
    }
    if($null -ne $SelectionIdentity){$s=$SelectionIdentity}
    elseif($null -ne $Object -and [object]::ReferenceEquals($Object,$script:SelectedObject)){$s=Get-DomeniaCurrentSelectionIdentity -Workspace 'WsObject'}
    elseif($null -ne $s){$s=Get-DomeniaRowSelectionIdentity -Row $s}
    if($null -eq $s -or $s -isnot [Domenia.SelectionIdentity] -or -not $s.DN -or $s.Type -notin @('Utilisateur','Machine') -or $s.Epoch -ne [long]$script:SessionEpoch -or $s.Reader -cne (Get-DomeniaObjectReadIdentity)){return}
    if($null -ne $script:Relations.Subject -and $script:Relations.Subject.DN -ieq $s.DN -and $script:Relations.Subject.Guid -ieq $s.Guid){$script:Relations.Subject=$s;Refresh-DomeniaRelationViews;return}
    $r=$script:Relations
    # A manual search cancelled from the task panel ends without a callback: it must not keep the subject locked.
    if($r.ManualSearchJob -and $null -ne $script:AsyncJobs -and ((-not $script:AsyncJobs.Contains([string]$r.ManualSearchJob)) -or [bool]$script:AsyncJobs[[string]$r.ManualSearchJob].CancelRequested)){$r.ManualSearchJob='';if($null -eq $r.PendingAssociation){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}}
    # D044: a target is being searched while the manual search runs or while its results are listed. The detection
    # query does not lock the subject (a new selection still stops it, as in RC1.10.7).
    $searching=((-not [string]::IsNullOrWhiteSpace([string]$r.ManualSearchJob)) -or (@($r.ManualSearchRows).Count -gt 0 -and [string]$r.AssociationState -in @('Searching','Candidate')))
    if($null -ne $r.Subject -and ($null -ne $r.PendingAssociation -or $searching)){
        # While a target is searched or awaits confirmation, a global selection does not replace the source subject.
        $d=Resolve-DomeniaRelationSubjectChange -CurrentSubject $r.Subject -NewSelection $s -TargetSearchActive $searching -PendingAssociation ($null -ne $r.PendingAssociation)
        if(-not $d.Change){
            $label=if($r.Subject.Type -eq 'Utilisateur'){[string]$r.Subject.Login}else{[string]$r.Subject.Name}
            $r.SubjectNotice=([string]$d.Reason+' Sujet conservé : '+$label+'. Annulez lʼassociation ou videz la recherche de cible pour changer de sujet.')
            [void](Set-DomeniaControlText 'LblRelationAssociateHint' $r.SubjectNotice)
            return
        }
    }
    foreach($job in @([string]$r.ManualSearchJob,$(if($null -ne $r.Query){[string]$r.Query.Job}else{''}))){if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Sélection Relations modifiée'}catch{}}}
    if($null -ne $r.Timer){$r.Timer.Stop()}
    $r.Subject=$s;$r.Generation++;$r.Query=$null;$r.PendingConfirmed=$null;$r.PendingAssociation=$null
    $r.ManualSearchJob='';$r.ManualSearchRequest='';$r.ManualSearchRows=@()
    $r.AssociationState=[string](Step-DomeniaAssociationState ([string]$r.AssociationState) 'SubjectChanged').State;$r.PendingPlan=$null;$r.SubjectNotice=''
    $tabs=Get-DomeniaControl 'RelationTabs';$tab=Get-DomeniaControl 'TabLinksSelected'
    if($null -ne $tabs -and $null -ne $tab){$tabs.SelectedItem=$tab}
    $intro=if($s.Type -eq 'Machine'){'Associations connues ; lecture de la session du poste ou recherche dʼun utilisateur dans le panneau Ajouter.'}else{'Associations connues ; détection ou recherche dʼun poste dans le panneau Ajouter.'}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' $intro)
    Refresh-DomeniaRelationViews
}
function Set-DomeniaRelationsGridSelection {
    if($script:SuppressGridSelectionEvents -or (Test-DomeniaAccessBusyWrite)){return}
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -ne $grid -and @($grid.SelectedItems).Count -eq 1){
        $identity=Get-DomeniaCurrentSelectionIdentity -Workspace 'WsSearch'
        if($null -ne $identity){Set-DomeniaRelationsSelection -SelectionIdentity $identity}
    }
}
function Clear-DomeniaRelationsSelection {
    # Field report 2026-10-05: once nothing is selected any more, Relations no longer shows the former subject.
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    if($null -eq $r.Subject){return}
    foreach($job in @([string]$r.ManualSearchJob,$(if($null -ne $r.Query){[string]$r.Query.Job}else{''}))){if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Selection videe'}catch{}}}
    if($null -ne $r.Timer){$r.Timer.Stop()}
    $r.Subject=$null;$r.Generation++;$r.Query=$null;$r.PendingConfirmed=$null;$r.PendingAssociation=$null;$r.PendingPlan=$null
    $r.ManualSearchJob='';$r.ManualSearchRequest='';$r.ManualSearchRows=@();$r.SubjectNotice=''
    $r.AssociationState=[string](Step-DomeniaAssociationState ([string]$r.AssociationState) 'SubjectChanged').State
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Aucune recherche complémentaire en cours.')
    Refresh-DomeniaRelationViews
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
function Get-DomeniaRelationsSubjectIdentity {
    # D044: domain, GUID, type, reader, session and generation of the Relations subject (Test-DomeniaSameSubject).
    param($Subject=$null)
    Initialize-DomeniaRelationsState
    if($null -eq $Subject){$Subject=$script:Relations.Subject}
    if($null -eq $Subject){return $null}
    return [pscustomobject]@{Domain=[string]$script:Conn.BaseDn;Guid=[string]$Subject.Guid;Type=[string]$Subject.Type;Reader=(Get-DomeniaRelationsIdentity);Session=[string]$script:SessionEpoch;Generation=[string]$script:Relations.Generation;DN=[string]$Subject.DN}
}
function Get-DomeniaRelationsTargetIdentity {
    param([string]$Type,[string]$Guid,[string]$Dn)
    Initialize-DomeniaRelationsState
    return [pscustomobject]@{Domain=[string]$script:Conn.BaseDn;Guid=$Guid;Type=(ConvertTo-DomeniaRelationType $Type);Reader=(Get-DomeniaRelationsIdentity);Session=[string]$script:SessionEpoch;Generation=[string]$script:Relations.Generation;DN=$Dn}
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
function Test-DomeniaRelationsListContains {
    param([object[]]$List=@(),$Item)
    if($null -eq $Item){return $false}
    foreach($x in @($List)){if([object]::ReferenceEquals($x,$Item)){return $true}}
    return $false
}
function Get-DomeniaRelationsAllRelations {
    # Stored relations, then relations kept for this session only (one stored relation per workstation, see Add-DomeniaRelation).
    foreach($l in @($script:UserMachineLinks)){if($null -ne $l){Write-Output $l}}
    if($null -ne $script:Relations -and $null -ne $script:Relations.Observations){foreach($o in @($script:Relations.Observations)){if($null -ne $o){Write-Output $o}}}
}
function Get-DomeniaRelationsSelectedLinks {
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s){return}
    $links=if($s.Type -eq 'Utilisateur'){@(Get-LinksForUser $s.Login)}else{@(Get-LinksForComputer $s.Name)}
    if($null -ne $script:Relations -and $null -ne $script:Relations.Observations -and $script:Relations.Observations.Count){
        $subjectKey=if($s.Type -eq 'Utilisateur'){ConvertTo-DomeniaRelationLoginKey $s.Login}else{ConvertTo-DomeniaRelationComputerKey $s.Name}
        foreach($o in @($script:Relations.Observations)){
            $key=if($s.Type -eq 'Utilisateur'){ConvertTo-DomeniaRelationLoginKey ([string]$o.UserLogin)}else{ConvertTo-DomeniaRelationComputerKey ([string]$o.Computer)}
            if($subjectKey -and $key -eq $subjectKey){$links+=$o}
        }
    }
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
function Test-DomeniaRelationsPageVisible {
    # PF-16: the Relations views are bound only while Relations is the selected workspace. Without the shell
    # (tests, start), the page counts as visible.
    $workspace=Get-DomeniaControl 'WorkspaceTabs';$page=Get-DomeniaControl 'TabRelations'
    if($null -eq $workspace -or $null -eq $page){return $true}
    return [object]::ReferenceEquals($workspace.SelectedItem,$page)
}
function Open-DomeniaRelationsPage {
    # PF-16: a refresh noted while the page was hidden runs when it opens.
    Initialize-DomeniaRelationsState
    if($script:Relations.RefreshPending){Refresh-DomeniaRelationViews}else{Update-DomeniaRelationsActions}
}
function Show-DomeniaRelationsAddPanel {
    # UI-09: the Ajouter panel sits beside the associations of the subject; Détecter | Rechercher is its only selector.
    param([ValidateSet('Detect','Search')][string]$Mode='Detect')
    $tabs=Get-DomeniaControl 'RelationTabs';$tab=Get-DomeniaControl 'TabLinksSelected';if($null -ne $tabs -and $null -ne $tab){$tabs.SelectedItem=$tab}
    $modes=Get-DomeniaControl 'RelationAssociateModeTabs';$target=Get-DomeniaControl $(if($Mode -eq 'Search'){'TabRelationSearch'}else{'TabRelationDetect'})
    if($null -ne $modes -and $null -ne $target){$modes.SelectedItem=$target}
}
function Switch-DomeniaRelationsHelp {
    # UI-09: the warnings of the page stay one click away, behind « ? », instead of filling the header.
    $panel=Get-DomeniaControl 'RelationsHelpPanel';if($null -eq $panel){return}
    $panel.Visibility=if([string]$panel.Visibility -eq 'Visible'){'Collapsed'}else{'Visible'}
}
function Step-DomeniaRelationsAssociation {
    # D045: every step of the in-page association goes through Step-DomeniaAssociationState; a refusal is explained.
    # CO-30: the operator reads a French sentence; the internal state and event names go to the log only.
    param([Parameter(Mandatory=$true)][string]$Event,[switch]$Quiet)
    Initialize-DomeniaRelationsState
    $t=Step-DomeniaAssociationState ([string]$script:Relations.AssociationState) $Event
    if(-not $t.Accepted){
        if(-not $Quiet){[void](Set-DomeniaControlText 'LblRelationConfirm' ([string]$t.Reason));Set-Status ('Relations : '+[string]$t.Reason) 'INFO';Write-AppLog ('Relations · étape refusée : '+[string](Get-DomeniaMember $t 'Detail' '')) 'INFO'}
        return $false
    }
    $script:Relations.AssociationState=[string]$t.State
    return $true
}
function Update-DomeniaRelationsActions {
    $s=Get-DomeniaRelationsSubject;$r=$script:Relations
    $isUser=($null -ne $s -and $s.Type -eq 'Utilisateur')
    $dir=$null;if($null -ne $s -and $s.Type -in @('Utilisateur','Machine')){$dir=Get-DomeniaRelationDirection $s.Type}
    $hasSubject=($null -ne $dir)
    $busyDetect=($null -ne $r.Query -and -not $r.Query.Ended)
    if($r.ManualSearchJob -and $null -ne $script:AsyncJobs -and ((-not $script:AsyncJobs.Contains([string]$r.ManualSearchJob)) -or [bool]$script:AsyncJobs[[string]$r.ManualSearchJob].CancelRequested)){$r.ManualSearchJob='';if($null -eq $r.PendingAssociation){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}}
    $busySearch=(-not [string]::IsNullOrWhiteSpace([string]$r.ManualSearchJob))
    $locked=Test-DomeniaAccessBusyWrite
    $planOpen=($null -ne $r.PendingPlan)
    $detect=Get-DomeniaControl 'BtnDetectUserComputers'
    if($null -ne $detect){$detect.IsEnabled=($hasSubject -and -not $busyDetect -and -not $locked -and -not $planOpen);if($null -ne $dir){$detect.Content=$dir.DetectLabel}}
    foreach($n in @('CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents')){
        # Perimeter options only exist for a user subject: a workstation reads its own session.
        $c=Get-DomeniaControl $n;if($null -eq $c){continue};$c.IsEnabled=($isUser -and -not $busyDetect -and -not $locked -and -not $planOpen)
    }
    $stop=Get-DomeniaControl 'BtnRelationsStop';if($null -ne $stop){$stop.IsEnabled=$busyDetect;$stop.Visibility=if($busyDetect){'Visible'}else{'Hidden'}}
    $remove=Get-DomeniaControl 'BtnRemoveLink';$grid=Get-DomeniaRelationsActiveGrid
    if($null -ne $remove){$remove.IsEnabled=($null -ne $grid -and $null -ne $grid.SelectedItem -and -not $locked)}
    # CO-28: active only when a local removal can be put back, and named after it. The same button sits in
    # Associations and in Toutes les associations, where the import is undone and the orphans are removed.
    $entry=$null;$entryRead=$false
    foreach($name in @('BtnRestoreLink','BtnRestoreLinkAll')){
        $restore=Get-DomeniaControl $name;if($null -eq $restore){continue}
        if(-not $entryRead){$entry=Get-DomeniaRelationsRestoreCandidate;$entryRead=$true}
        $restore.IsEnabled=($null -ne $entry -and -not $locked)
        $restore.Content=Get-DomeniaRelationRestoreLabel $entry
        $restore.ToolTip=if($null -ne $entry){'Remet lʼassociation '+[string]$entry.Relation.UserLogin+' → '+[string]$entry.Relation.Computer+' supprimée localement ('+(Format-DomeniaRelationWhen ([string]$entry.WhenUtc))+'), depuis le journal ; une association par clic. Aucun objet Active Directory nʼest lu ni modifié.'}else{'Aucune suppression locale à restaurer.'}
    }
    $d=Get-DomeniaControl 'DgRelationCandidates';$candidate=if($null -ne $d){$d.SelectedItem}else{$null}
    $associable=[bool](Get-DomeniaMember $candidate 'Associable' $false)
    $open=Get-DomeniaControl 'BtnRelationOpenCandidate';if($null -ne $open){$open.IsEnabled=($isUser -and $null -ne $candidate -and $associable -and -not $busyDetect -and -not $locked)}
    $adopt=Get-DomeniaControl 'BtnRelationAdopt';if($null -ne $adopt){$adopt.IsEnabled=($isUser -and $null -ne $candidate -and $associable -and -not $busyDetect -and -not $locked)}
    $box=Get-DomeniaControl 'TxtRelationComputerSearch';$go=Get-DomeniaControl 'BtnRelationComputerSearch';$mg=Get-DomeniaControl 'DgRelationComputerSearch';$ma=Get-DomeniaControl 'BtnRelationAssociateSearchResult'
    if($null -ne $box){$box.IsEnabled=($hasSubject -and -not $busySearch -and -not $locked);if($null -ne $dir){$box.ToolTip=($dir.SearchLabel+' : nom, identifiant ou DNS, dans tout le domaine.')}}
    if($null -ne $go){$go.IsEnabled=($hasSubject -and -not $busySearch -and -not $locked)}
    if($null -ne $mg){
        $mg.IsEnabled=(-not $busySearch)
        if($null -ne $dir -and @($mg.Columns).Count -ge 2){
            if($dir.TargetType -eq 'Utilisateur'){$mg.Columns[0].Header='Utilisateur';$mg.Columns[1].Header='Identifiant'}else{$mg.Columns[0].Header='Poste';$mg.Columns[1].Header='DNS'}
        }
    }
    if($null -ne $ma){$ma.IsEnabled=($hasSubject -and $null -ne $mg -and $null -ne $mg.SelectedItem -and -not $busySearch -and -not $locked);if($null -ne $dir){$ma.Content=$dir.Action}}
    $addPanel=Get-DomeniaControl 'RelationAddPanel';if($null -ne $addPanel){$addPanel.IsEnabled=$hasSubject}
    $hint=Get-DomeniaControl 'LblRelationAssociateHint'
    if($null -ne $hint){
        $text=if($null -eq $s){'Sélectionnez un utilisateur ou un poste dans Rechercher pour associer.'}elseif($isUser){'Utilisateur : '+$s.Login+' · Détecter lit ses postes connus et les indices AD puis montre le périmètre avant toute lecture de poste ; ou recherchez un poste.'}else{'Poste : '+$s.Name+' · Détecter lit la session de ce poste ; ou recherchez un utilisateur à lui associer.'}
        if($r.SubjectNotice){$text=$r.SubjectNotice+' '+$text}
        $hint.Text=$text
    }
    $confirm=Get-DomeniaControl 'RelationConfirmPanel';if($null -ne $confirm){$confirm.Visibility=if($null -ne $r.PendingAssociation){'Visible'}else{'Collapsed'}}
    $plan=Get-DomeniaControl 'RelationPlanPanel';if($null -ne $plan){$plan.Visibility=if($planOpen){'Visible'}else{'Collapsed'}}
    $planRun=Get-DomeniaControl 'BtnRelationPlanRun';if($null -ne $planRun){$planRun.IsEnabled=($planOpen -and -not $busyDetect -and -not $locked)}
}
function Update-DomeniaRelationEvidence {
    # D043: a badge and the rule that produced it, never a percentage. D050: workstations where sources
    # designate different accounts are flagged Contradictoire; nothing is merged or removed.
    # Only the workstations changed since the last pass, or rows never qualified, are recomputed. Review L04: after a
    # save every stored row is a new canonical copy, so the qualification of identical content is kept for the session
    # (EvidenceMemo) and the notes are set without Add-Member.
    param([object[]]$Rows=@())
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    $dirty=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($k in @($r.DirtyComputers)){[void]$dirty.Add([string]$k)}
    foreach($row in @($Rows)){if($null -ne $row -and $null -eq $row.PSObject.Properties['Badge']){$key=ConvertTo-DomeniaRelationComputerKey ([string]$row.Computer);if($key){[void]$dirty.Add($key)}}}
    $r.DirtyComputers.Clear()
    if(-not $dirty.Count){return}
    $session=$r.Observations.ToArray()
    $groups=[Collections.Generic.Dictionary[string,Collections.Generic.List[object]]]::new([StringComparer]::OrdinalIgnoreCase)
    if($dirty.Count -gt 32){
        # Many workstations: one pass over every relation instead of one index lookup per workstation.
        foreach($l in @(Get-DomeniaRelationsAllRelations)){
            $key=ConvertTo-DomeniaRelationComputerKey ([string]$l.Computer)
            if(-not $key -or -not $dirty.Contains($key)){continue}
            $list=$null;if(-not $groups.TryGetValue($key,[ref]$list)){$list=[Collections.Generic.List[object]]::new();$groups[$key]=$list}
            $list.Add($l)
        }
    }else{
        foreach($key in $dirty){
            $list=[Collections.Generic.List[object]]::new()
            foreach($l in @(Get-LinksForComputer $key)){if($null -ne $l){$list.Add($l)}}
            foreach($o in $session){if($null -ne $o -and (ConvertTo-DomeniaRelationComputerKey ([string]$o.Computer)) -eq $key){$list.Add($o)}}
            $groups[$key]=$list
        }
    }
    $memo=$r.EvidenceMemo
    if($null -eq $memo -or $memo.Count -gt 20000){$memo=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$r.EvidenceMemo=$memo}
    $separator=[string][char]31
    foreach($group in $groups.Values){
        $items=$group.ToArray()
        # A conflict needs two relations of the same workstation.
        $contradicted=@();if($items.Count -gt 1){foreach($c in @(Get-DomeniaLinkConflicts $items)){$contradicted+=@($c.Relations)}}
        foreach($row in $items){
            $isContradicted=($contradicted.Count -gt 0 -and (Test-DomeniaRelationsListContains $contradicted $row))
            $isSession=($session.Count -gt 0 -and (Test-DomeniaRelationsListContains $session $row))
            $props=$row.PSObject.Properties
            $when='';$p=$props['When'];if($null -ne $p){$when=[string]$p.Value}
            $source='';$p=$props['Source'];if($null -ne $p){$source=[string]$p.Value}
            $kind='';$p=$props['Kind'];if($null -ne $p){$kind=[string]$p.Value}
            $signature='row'+$separator+$source+$separator+$kind+$separator+$when+$separator+[string]$isContradicted
            $q=$null
            if(-not $memo.TryGetValue($signature,[ref]$q)){
                # The badge depends on the source and the conflict only (few distinct values); the date is read once
                # per text (ConvertTo-DomeniaRelationUtcDate). Provenance is written as in Get-DomeniaEvidenceBadge.
                $badgeKey='badge'+$separator+$source+$separator+$kind+$separator+[string]$isContradicted;$b=$null
                if(-not $memo.TryGetValue($badgeKey,[ref]$b)){$b=Get-DomeniaEvidenceBadge ([pscustomobject]@{Source=$source;Kind=$kind}) $isContradicted;$memo[$badgeKey]=$b}
                # CO-29: the Date column shows local time and sorts on the instant, whatever the stored form.
                $utc=ConvertTo-DomeniaRelationUtcDate $when
                $display=Format-DomeniaRelationWhen $utc
                $provenance=$source
                if($when){$whenText=if($display){$display}else{$when};$provenance=($source+' · '+$whenText).Trim(' ','·')}
                $q=[pscustomobject]@{Badge=$b.Badge;BadgeLabel=$b.Label;BadgeRule=($b.Rule+' Provenance : '+$provenance+'.');Provenance=$provenance;WhenDisplay=$display;WhenSort=$(if($null -ne $utc){$utc}else{[datetime]::MinValue})}
                $memo[$signature]=$q
            }
            $persistence=if($isSession){'Session uniquement'}else{'Enregistrée'}
            $p=$props['Badge'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('Badge',$q.Badge))}else{$p.Value=$q.Badge}
            $p=$props['BadgeLabel'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('BadgeLabel',$q.BadgeLabel))}else{$p.Value=$q.BadgeLabel}
            $p=$props['BadgeRule'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('BadgeRule',$q.BadgeRule))}else{$p.Value=$q.BadgeRule}
            $p=$props['WhenDisplay'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('WhenDisplay',$q.WhenDisplay))}else{$p.Value=$q.WhenDisplay}
            $p=$props['WhenSort'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('WhenSort',$q.WhenSort))}else{$p.Value=$q.WhenSort}
            $p=$props['Provenance'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('Provenance',$q.Provenance))}else{$p.Value=$q.Provenance}
            $p=$props['Persistence'];if($null -eq $p){$props.Add([Management.Automation.PSNoteProperty]::new('Persistence',$persistence))}else{$p.Value=$persistence}
        }
    }
}
function Update-DomeniaRelationCandidateEvidence {
    # D046: each candidate states why it is proposed and whether it can be associated. An IP address or a
    # partial name never allows an association: only an AD object identified by its GUID does.
    param($Query)
    if($null -eq $Query){return}
    $rows=@(@($Query.Candidates.Values)+@($Query.Hints)|Where-Object{$null -ne $_})
    if(-not $rows.Count){return}
    $stored=@(Get-DomeniaRelationsSelectedLinks)
    $known=@();$observed=@();$hints=@()
    foreach($c in $rows){
        $guid=[string]$c.Guid;$name=[string]$c.Computer
        if([bool]$c.Known){
            $source=[string]$c.Source
            foreach($l in $stored){if(([string]$l.ComputerGuid -and $guid -and [string]$l.ComputerGuid -ieq $guid) -or ((ConvertTo-DomeniaRelationComputerKey ([string]$l.Computer)) -eq (ConvertTo-DomeniaRelationComputerKey $name))){$source=[string]$l.Source;break}}
            $known+=[pscustomobject]@{Guid=$guid;Computer=$name;DN=[string]$c.DN;Source=$source}
        }
        if([bool]$c.Confirmed){$observed+=[pscustomobject]@{Guid=$guid;Computer=$name;DN=[string]$c.DN;Source=[string]$c.Source;Detail=('console '+[string]$c.CurrentUser+' lue le '+[string]$c.ObservedUtc)}}
        if(-not [bool]$c.Known -and -not [bool]$c.Confirmed){
            $detail=if([string]$c.Status){[string]$c.Status+' ('+[string]$c.Source+')'}else{[string]$c.Source}
            $hints+=[pscustomobject]@{Guid=$guid;Computer=$name;DN=[string]$c.DN;Address=$(if(-not $guid){$name}else{''});Source=[string]$c.Source;Detail=$detail}
        }
    }
    $merged=@(Merge-DomeniaRelationCandidates -Known $known -Observations $observed -Hints $hints -Inventory @() -Domain ([string]$script:Conn.BaseDn))
    foreach($c in $rows){
        $guid=ConvertTo-DomeniaGuidText ([string]$c.Guid);$m=$null
        foreach($x in $merged){
            if($guid){if([string]$x.Guid -ieq $guid){$m=$x;break}}
            elseif(-not [string]$x.Guid -and ([string]$x.Computer -ieq [string]$c.Computer)){$m=$x;break}
        }
        if($null -eq $m){continue}
        $projection=if([bool]$c.Confirmed){[pscustomobject]@{Source='Console CIM/DCOM';When=[string]$c.ObservedUtc}}elseif([bool]$c.Known){[pscustomobject]@{Source=@($known|Where-Object{$_.Guid -ieq [string]$c.Guid}|ForEach-Object{$_.Source}|Select-Object -First 1)[0];When=[string]$c.ObservedUtc}}else{[pscustomobject]@{Source=[string]$c.Source;Kind='Indice';When=[string]$c.ObservedUtc}}
        $b=Get-DomeniaEvidenceBadge $projection
        $c|Add-Member -NotePropertyName Why -NotePropertyValue ([string]$m.Why) -Force
        $c|Add-Member -NotePropertyName Origins -NotePropertyValue ([string]$m.Origins) -Force
        $c|Add-Member -NotePropertyName Associable -NotePropertyValue ([bool]$m.Associable) -Force
        $c|Add-Member -NotePropertyName Blocker -NotePropertyValue ([string]$m.Blocker) -Force
        $c|Add-Member -NotePropertyName Badge -NotePropertyValue $b.Badge -Force
        $c|Add-Member -NotePropertyName BadgeLabel -NotePropertyValue $b.Label -Force
        $c|Add-Member -NotePropertyName BadgeRule -NotePropertyValue $b.Rule -Force
        $c|Add-Member -NotePropertyName WhenDisplay -NotePropertyValue (Format-DomeniaRelationWhen ([string]$c.ObservedUtc)) -Force
        $c|Add-Member -NotePropertyName WhenSort -NotePropertyValue (Get-DomeniaRelationWhenSortKey ([string]$c.ObservedUtc)) -Force
    }
}
function Get-DomeniaAllLinksBadgeFilter {
    # FO-14: qualification chips checked above Toutes les associations (internal keys).
    $badges=[Collections.Generic.List[string]]::new()
    foreach($pair in @(@('ChkAllLinksDeclared','Declare'),@('ChkAllLinksObserved','Observe'),@('ChkAllLinksConflict','Contradictoire'))){
        $chip=Get-DomeniaControl $pair[0];if($null -ne $chip -and [bool]$chip.IsChecked){$badges.Add([string]$pair[1])}
    }
    return $badges.ToArray()
}
function Clear-DomeniaAllLinksFilter {
    # FO-14: « Exporter tout » exports every association, so the text filter and the chips are cleared first (visibly).
    $box=Get-DomeniaControl 'TxtAllLinksFilter';if($null -ne $box){$box.Text=''}
    foreach($name in @('ChkAllLinksDeclared','ChkAllLinksObserved','ChkAllLinksConflict')){$chip=Get-DomeniaControl $name;if($null -ne $chip){$chip.IsChecked=$false}}
    Update-DomeniaAllLinksView
}
function Update-DomeniaAllLinksView {
    # FO-14: Toutes les associations, filtered by text and qualification chips, with its counter.
    param([object[]]$Rows=$null)
    if($null -eq $Rows){$Rows=@(Get-DomeniaRelationsAllRelations)}
    $box=Get-DomeniaControl 'TxtAllLinksFilter';$text=if($null -ne $box){[string]$box.Text}else{''}
    $badges=@(Get-DomeniaAllLinksBadgeFilter)
    $shown=@($Rows|Where-Object{Test-DomeniaRelationMatchesFilter $_ $text $badges})
    $grid=Get-DomeniaControl 'DgAllLinks';$selected=if($null -ne $grid){$grid.SelectedItem}else{$null}
    [void](Set-DomeniaItemsSource 'DgAllLinks' $shown);if($null -ne $selected -and $shown -contains $selected){$grid.SelectedItem=$selected}
    $total=@($Rows).Count
    $count=if($shown.Count -eq $total){[string]$total+' association(s)'}else{[string]$shown.Count+' association(s) sur '+$total}
    [void](Set-DomeniaControlText 'LblAllLinksCount' $count)
}
function Refresh-DomeniaRelationViews {
    param([switch]$ProgressOnly)
    Initialize-DomeniaRelationsState
    if($script:Relations.Rendering){return}
    # PF-16: while the page is hidden nothing is bound or qualified; the refresh is noted and runs when the page opens.
    if(-not (Test-DomeniaRelationsPageVisible)){$script:Relations.RefreshPending=$true;return}
    $script:Relations.Rendering=$true
    try{
        if(-not $ProgressOnly){
            $script:Relations.RefreshPending=$false
            $s=Get-DomeniaRelationsSubject;$rows=@(Get-DomeniaRelationsSelectedLinks);$all=@(Get-DomeniaRelationsAllRelations)
            Update-DomeniaRelationEvidence -Rows $all
            $grid=Get-DomeniaControl 'DgLinks';$selected=if($null -ne $grid){$grid.SelectedItem}else{$null}
            [void](Set-DomeniaItemsSource 'DgLinks' $rows);if($null -ne $selected -and $rows -contains $selected){$grid.SelectedItem=$selected}
            Update-DomeniaAllLinksView -Rows $all
            # Point 138: the rollback batch of an earlier session stays reachable from Toutes les associations.
            Update-DomeniaLinkImportUndo
            $title=if($null -eq $s){'Sélectionnez un utilisateur ou un poste depuis Rechercher.'}elseif($s.Type -eq 'Utilisateur'){'Utilisateur : '+$s.Login}else{'Poste : '+$s.Name}
            [void](Set-DomeniaControlText 'LblRelationsSelection' $title)
            $context=$title+' · '+$rows.Count+' association(s) mémorisée(s).'
            $sessionOnly=@($rows|Where-Object{[string]$_.Persistence -eq 'Session uniquement'}).Count
            $contradicted=@($rows|Where-Object{[string]$_.Badge -eq 'Contradictoire'}).Count
            if($sessionOnly){$context+=' '+$sessionOnly+' visible(s) pour cette session seulement : le stockage local garde une relation par poste.'}
            if($contradicted){$context+=' '+$contradicted+' qualification(s) contradictoire(s) : sources différentes conservées, sans fusion.'}
            [void](Set-DomeniaControlText 'LblLinkContext' $context)
            $lbl=Get-DomeniaControl 'LblRelationsSelection';if($null -ne $lbl -and $null -ne $s){$lbl.ToolTip=$s.DN}
            $emptyText=if($null -eq $s){'Recherchez un utilisateur ou un poste en haut, sélectionnez sa ligne, puis ouvrez Relations.'}else{(Get-DomeniaRelationDirection $s.Type).EmptyHint+' Utilisez le panneau Ajouter pour détecter ou rechercher.'}
            [void](Set-DomeniaControlText 'LblLinkEmpty' $emptyText)
            $empty=Get-DomeniaControl 'LinkEmptyPanel';if($null -ne $empty){$empty.Visibility=if($rows.Count){'Collapsed'}else{'Visible'}}
            [void](Set-DomeniaItemsSource 'DgRelationComputerSearch' @($script:Relations.ManualSearchRows))
        }
        $q=$script:Relations.Query
        # D047: a plan awaiting confirmation is the list really aimed at; it wins over the previous (ended) query.
        if($null -ne $script:Relations.PendingPlan){
            [void](Set-DomeniaItemsSource 'DgRelationCandidates' @($script:Relations.PendingPlan.Rows));[void](Set-DomeniaItemsSource 'DgLinkAttempts' @())
        }elseif($null -ne $q){
            Update-DomeniaRelationCandidateEvidence $q
            [void](Set-DomeniaItemsSource 'DgRelationCandidates' @(@($q.Candidates.Values|Sort-Object Computer)+@($q.Hints)));[void](Set-DomeniaItemsSource 'DgLinkAttempts' @($q.Attempts))
        }else{[void](Set-DomeniaItemsSource 'DgRelationCandidates' @());[void](Set-DomeniaItemsSource 'DgLinkAttempts' @())}
        [void](Set-DomeniaControlText 'LblRelationPlan' $(if($null -ne $script:Relations.PendingPlan){[string]$script:Relations.PendingPlan.Text}else{''}))
        if($null -ne $script:Relations.PendingAssociation){
            $p=$script:Relations.PendingAssociation
            [void](Set-DomeniaControlText 'LblRelationConfirm' ($p.User+' → '+$p.Computer+' · '+$p.Source+'. Cette association est locale à Domenia et ne modifie pas Active Directory.'))
        }
        Update-DomeniaRelationsActions
    }finally{$script:Relations.Rendering=$false}
}
function Update-DomeniaRelationDetectionCounters {
    # D048: queried / refused / unreachable / confirmed / remaining, shown while the detection progresses.
    param($Query,$Attempt)
    if($null -eq $Query -or $null -eq $Attempt){return}
    $counters=Get-DomeniaMember $Query 'Counters' $null
    if($null -eq $counters -or [string]$Attempt.Method -ne 'Console CIM/DCOM'){return}
    $outcome=ConvertTo-DomeniaDetectionOutcome ([string]$Attempt.Status)
    if(-not $outcome){return}
    [void](Add-DomeniaDetectionOutcome $counters $outcome)
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Détection en cours : '+(Get-DomeniaDetectionCounterText $counters)+'.'))
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
            'Attempt'{[void]$q.Attempts.Add($ev.Value);$changed=$true;Update-DomeniaRelationDetectionCounters $q $ev.Value}
            'Status'{if($null -eq (Get-DomeniaMember $q 'Counters' $null)){[void](Set-DomeniaControlText 'LblLinkProbeStatus' ([string]$ev.Value))}}
        }
    }
    if($changed){Refresh-DomeniaRelationViews -ProgressOnly}
    if($null -ne $r.PendingConfirmed -and ($null -eq $script:Persistence -or -not $script:Persistence.LinkBusy)){
        $pending=$r.PendingConfirmed;$r.PendingConfirmed=$null
        if(Test-DomeniaRelationsCurrent $pending.State){Save-DomeniaRelationConfirmations $pending.Result $pending.State}
    }
    if($q.Ended -and $q.Progress.Count -eq 0 -and $null -eq $r.PendingConfirmed -and $null -ne $r.Timer){$r.Timer.Stop()}
}
function Update-DomeniaRelationLinkIndex {
    # Incremental maintenance of the workstation and user lookups, without rebuilding the whole links table.
    param($Link,[switch]$Remove)
    if($null -eq $Link){return}
    if($null -eq $script:LinkByComputer -or $null -eq $script:LinksByUser){Rebuild-UserMachineLinkIndex;return}
    $computer=Normalize-LinkComputer ([string]$Link.Computer);$user=Normalize-LinkUser ([string]$Link.UserLogin)
    $userKey=if($user){$user.ToLowerInvariant()}else{''}
    foreach($pair in @(@($script:LinkByComputer,$computer),@($script:LinksByUser,$userKey))){
        $map=$pair[0];$key=[string]$pair[1];if(-not $key){continue}
        $list=[Collections.ArrayList]::new()
        if($map.ContainsKey($key)){foreach($item in @($map[$key])){if(-not [object]::ReferenceEquals($item,$Link)){[void]$list.Add($item)}}}
        if(-not $Remove){[void]$list.Add($Link)}
        if($list.Count){$map[$key]=$list}elseif($map.ContainsKey($key)){[void]$map.Remove($key)}
    }
    $script:LinkIndexCount=@($script:UserMachineLinks).Count;$script:LinkIndexGeneration=[int]$script:LinkIndexGeneration+1
}
function Get-DomeniaRelationsJournalPath {
    $base=[string]$script:DatabaseScopedPath
    if([string]::IsNullOrWhiteSpace($base)){return ''}
    return ($base+'.relations-journal.jsonl')
}
function Add-DomeniaRelationHistory {
    # D050: local journal of relation changes. Removals and restorations are also appended to a JSON-lines
    # file beside the scoped database, so that a removal stays traceable and restorable after a restart.
    param($Entry,[switch]$Quiet)
    if($null -eq $Entry){return}
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$r.History.Add($Entry);while($r.History.Count -gt 500){$r.History.RemoveAt(0)}
    # CO-28: what « Restaurer » can put back changes only with a removal or a restoration.
    if([string]$Entry.Action -in @('Removed','Restored')){Reset-DomeniaRelationsRestoreCache}
    $rel=$Entry.Relation
    if(-not $Quiet){
        $by=if([string]$Entry.Declarant){[string]$Entry.Declarant}else{'Domenia'}
        Write-AppLog ('Relations · journal '+[string]$Entry.Action+' : '+[string]$rel.UserLogin+' -> '+[string]$rel.Computer+' ('+[string]$rel.Kind+', '+[string]$rel.Source+') par '+$by+'. '+[string]$Entry.Note) 'INFO'
    }
    if([string]$Entry.Action -notin @('Removed','Restored')){return}
    $path=Get-DomeniaRelationsJournalPath
    if(-not $path){return}
    try{
        $line=([pscustomobject]@{Id=[string]$Entry.Id;Action=[string]$Entry.Action;WhenUtc=[string]$Entry.WhenUtc;Declarant=[string]$Entry.Declarant;Note=[string]$Entry.Note;Key=[string]$Entry.Key;BaseDn=[string]$script:Conn.BaseDn;Relation=$rel}|ConvertTo-Json -Depth 4 -Compress)
        [IO.File]::AppendAllText($path,($line+"`n"),[Text.UTF8Encoding]::new($false))
    }catch{Write-AppLog ('Journal des relations non écrit sur disque : '+$_.Exception.Message+' ; entrée conservée en mémoire pour cette session.') 'WARN'}
}
function Get-DomeniaRelationsRestorableEntry {
    # Most recent local removal that has not been restored yet: memory first, then the journal file.
    param([switch]$MemoryOnly)
    Initialize-DomeniaRelationsState
    $entries=@($script:Relations.History.ToArray())
    if(-not $MemoryOnly){
        $path=Get-DomeniaRelationsJournalPath
        if($path -and [IO.File]::Exists($path)){
            try{
                $lines=@([IO.File]::ReadAllLines($path,[Text.UTF8Encoding]::new($false))|Select-Object -Last 400)
                $fromDisk=@()
                foreach($line in $lines){if([string]::IsNullOrWhiteSpace($line)){continue};try{$x=$line|ConvertFrom-Json;if([string]$x.BaseDn -ieq [string]$script:Conn.BaseDn){$fromDisk+=$x}}catch{}}
                $known=@{};foreach($e in $entries){$known[[string]$e.Id]=$true}
                $entries=@(@($fromDisk|Where-Object{-not $known.ContainsKey([string]$_.Id)})+$entries)
            }catch{Write-AppLog ('Journal des relations illisible : '+$_.Exception.Message) 'WARN'}
        }
    }
    $restored=@{}
    for($i=$entries.Count-1;$i -ge 0;$i--){
        $e=$entries[$i]
        if([string]$e.Action -eq 'Restored'){$restored[[string]$e.Note]=$true;continue}
        if([string]$e.Action -eq 'Removed' -and -not $restored.ContainsKey([string]$e.Id)){return $e}
    }
    return $null
}
function Reset-DomeniaRelationsRestoreCache {
    if($null -eq $script:Relations){return}
    $script:Relations.RestoreKnown=$false;$script:Relations.RestoreEntry=$null
}
function Get-DomeniaRelationsRestoreCandidate {
    # CO-28: the removal that « Restaurer » puts back (Get-DomeniaRelationsRestorableEntry), computed once and kept
    # until the next removal or restoration (Add-DomeniaRelationHistory) or session change.
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    if(-not $r.RestoreKnown){$r.RestoreEntry=Get-DomeniaRelationsRestorableEntry;$r.RestoreKnown=$true}
    return $r.RestoreEntry
}
function Test-DomeniaRelationsRestoreAvailable {
    return ($null -ne (Get-DomeniaRelationsRestoreCandidate))
}
function Add-DomeniaRelation {
    # D042/D049/D050: upsert of one user/workstation relation through Resolve-DomeniaRelationUpsert. A relation never
    # removes another one. While the local store keeps one row per workstation, the declared assignment stays stored
    # (Resolve-DomeniaRelationStoragePlacement) and the other relation is kept, visible and marked, for the session.
    param($Relation,[string]$Declarant='',[switch]$NoSave,[switch]$Quiet)
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    $result=[pscustomobject]@{Action='Ignore';Placement='';StoredChanged=$false;SaveFailed=$false;Relation=$null;Demoted=$null;Reason='Relation incomplète : utilisateur et poste requis.'}
    if($null -eq $Relation -or -not (ConvertTo-DomeniaRelationComputerKey ([string]$Relation.Computer)) -or -not (ConvertTo-DomeniaRelationLoginKey ([string]$Relation.UserLogin))){$r.LastOutcome=$result;return $result}
    if(-not [string](Get-DomeniaMember $Relation 'Kind' '')){$Relation|Add-Member -NotePropertyName Kind -NotePropertyValue (Get-DomeniaRelationKind ([string]$Relation.Source)) -Force}
    $computerKey=ConvertTo-DomeniaRelationComputerKey ([string]$Relation.Computer)
    $stored=@(Get-LinksForComputer ([string]$Relation.Computer)|Where-Object{$null -ne $_})
    $session=@(@($r.Observations)|Where-Object{(ConvertTo-DomeniaRelationComputerKey ([string]$_.Computer)) -eq $computerKey})
    $decision=Resolve-DomeniaRelationUpsert -Existing @($stored+$session) -Incoming $Relation
    $previousLinks=@($script:UserMachineLinks);$previousObservations=$r.Observations.ToArray()
    if($decision.Action -eq 'Refresh'){
        $target=$decision.Replace
        foreach($name in @('When','Details','Source')){$value=[string](Get-DomeniaMember $Relation $name '');if($value){Set-DomeniaRelationValue $target $name $value}}
        if([bool](Get-DomeniaMember $Relation 'VerifiedInAD' $false)){Set-DomeniaRelationValue $target 'VerifiedInAD' $true}
        foreach($name in @('UserGuid','ComputerGuid','UserDn','ComputerDn')){$value=[string](Get-DomeniaMember $Relation $name '');if($value -and -not [string](Get-DomeniaMember $target $name '')){Set-DomeniaRelationValue $target $name $value}}
        $isStored=Test-DomeniaRelationsListContains $stored $target
        if(-not $isStored){
            # A -> B -> A: refreshing the former session observation must make A current again,
            # while a declared assignment still has priority over every console observation.
            $primary=Select-DomeniaPrimaryRelation $stored
            $placement=Resolve-DomeniaRelationStoragePlacement -Stored $primary -Incoming $target -MultiRelationStorage ([bool]$script:DomeniaLinkStoreMultiRelation)
            if($placement.Placement -in @('Stored','Replace')){
                $old=$placement.Demoted
                if($null -ne $old){
                    $script:UserMachineLinks=@($script:UserMachineLinks|Where-Object{-not [object]::ReferenceEquals($_,$old)})
                    Update-DomeniaRelationLinkIndex -Link $old -Remove
                    $r.Observations.Add($old)
                }
                [void]$r.Observations.Remove($target)
                $script:UserMachineLinks=@($script:UserMachineLinks)+$target
                Update-DomeniaRelationLinkIndex -Link $target
                $isStored=$true;$result.Demoted=$old
            }
        }
        $result.Action='Refresh';$result.Placement=$(if($isStored){'Stored'}else{'Session'});$result.StoredChanged=$isStored;$result.Relation=$target;$result.Reason=[string]$decision.Reason
        Add-DomeniaRelationHistory (New-DomeniaLinkHistoryEntry -Action Refreshed -Relation $target -Declarant $Declarant) -Quiet
    }else{
        $primary=Select-DomeniaPrimaryRelation $stored
        $placement=Resolve-DomeniaRelationStoragePlacement -Stored $primary -Incoming $Relation -MultiRelationStorage ([bool]$script:DomeniaLinkStoreMultiRelation)
        switch([string]$placement.Placement){
            'Stored'{$script:UserMachineLinks=@($script:UserMachineLinks)+$Relation;Update-DomeniaRelationLinkIndex -Link $Relation;$result.StoredChanged=$true}
            'Replace'{
                $old=$placement.Demoted
                $script:UserMachineLinks=@(@($script:UserMachineLinks|Where-Object{-not [object]::ReferenceEquals($_,$old)})+$Relation)
                Update-DomeniaRelationLinkIndex -Link $old -Remove;Update-DomeniaRelationLinkIndex -Link $Relation
                $r.Observations.Add($old);$result.StoredChanged=$true
            }
            'Session'{$r.Observations.Add($Relation)}
        }
        $result.Action='Add';$result.Placement=[string]$placement.Placement;$result.Relation=$Relation;$result.Demoted=$placement.Demoted;$result.Reason=[string]$placement.Reason
        Add-DomeniaRelationHistory (New-DomeniaLinkHistoryEntry -Action Added -Relation $Relation -Declarant $Declarant -Note ([string]$placement.Reason)) -Quiet:$Quiet
    }
    $r.Revision++;[void]$r.DirtyComputers.Add($computerKey)
    if($result.StoredChanged -and -not $NoSave){
        # Review L04: a busy storage queue is named before the change is undone, instead of a generic refusal.
        $why=Get-DomeniaRelationSaveRefusal -Changes 1
        if($why -or -not (Save-UserMachineLinks)){
            $script:UserMachineLinks=$previousLinks;$r.Observations.Clear();foreach($o in $previousObservations){$r.Observations.Add($o)};Rebuild-UserMachineLinkIndex
            $result.SaveFailed=$true;$result.StoredChanged=$false
            $result.Reason=if($why){'Relation non enregistrée : '+$why+'.'}else{'Stockage local refusé : relation non enregistrée (motif dans le message précédent).'}
        }
    }
    $r.LastOutcome=$result
    return $result
}
function Set-DomeniaRelationValue {
    param($Target,[string]$Name,$Value)
    if($null -eq $Target){return}
    $p=$Target.PSObject.Properties[$Name]
    if($null -eq $p){$Target.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new($Name,$Value))}else{$p.Value=$Value}
}
function Get-DomeniaRelationSaveRefusal {
    # Review L04: the storage queue (Queue-DomeniaLinkChanges) takes one request at a time and 64 changed workstations
    # per request. Both limits are checked before any change, so that nothing is half applied and the operator reads
    # the real reason instead of a generic refusal.
    param([int]$Changes=1)
    if($null -ne $script:Persistence -and [bool]$script:Persistence.LinkBusy){return 'lʼenregistrement précédent des associations est encore en cours ; réessayez dans quelques secondes'}
    if($Changes -gt 64){return ([string]$Changes+' associations à modifier, 64 au plus par enregistrement')}
    return ''
}
function Find-DomeniaRelationInstance {
    # The stored row or the session row that is this relation: the same object first, then the same user,
    # workstation and nature (the storage queue replaces the stored objects by canonical copies). Review L04: only the
    # rows of the same workstation are compared (index by workstation), plus the few rows that carry its GUID.
    param($Relation)
    if($null -eq $Relation){return $null}
    $computer=[string](Get-DomeniaMember $Relation 'Computer' '')
    $candidates=@(Get-LinksForComputer $computer|Where-Object{$null -ne $_})
    foreach($l in $candidates){if([object]::ReferenceEquals($l,$Relation)){return [pscustomobject]@{Item=$l;Stored=$true}}}
    foreach($l in $candidates){if(Test-DomeniaSameRelation $l $Relation){return [pscustomobject]@{Item=$l;Stored=$true}}}
    # A GUID known on both sides decides even after a rename of the workstation.
    $guid=([string](Get-DomeniaMember $Relation 'ComputerGuid' '')).Trim()
    if($guid){
        foreach($l in @($script:UserMachineLinks)){
            if($null -eq $l -or ([string]$l.ComputerGuid).Trim() -ine $guid -or (Test-DomeniaRelationsListContains $candidates $l)){continue}
            if([object]::ReferenceEquals($l,$Relation) -or (Test-DomeniaSameRelation $l $Relation)){return [pscustomobject]@{Item=$l;Stored=$true}}
        }
    }
    if($null -ne $script:Relations){
        $key=ConvertTo-DomeniaRelationComputerKey $computer
        foreach($o in @($script:Relations.Observations)){
            if($null -eq $o){continue}
            if([object]::ReferenceEquals($o,$Relation)){return [pscustomobject]@{Item=$o;Stored=$false}}
            $same=(((ConvertTo-DomeniaRelationComputerKey ([string]$o.Computer)) -eq $key) -or ($guid -and ([string]$o.ComputerGuid).Trim() -ieq $guid))
            if($same -and (Test-DomeniaSameRelation $o $Relation)){return [pscustomobject]@{Item=$o;Stored=$false}}
        }
    }
    return $null
}
function Remove-DomeniaRelations {
    # D050, UX-40, CO-08: several local removals in one storage request. Each one is journaled and restorable;
    # Active Directory is never touched. Returns the number removed, or -1 when nothing was removed because the store
    # refused: LastRefusal then names the reason when it was known before the change (Get-DomeniaRelationSaveRefusal).
    param([object[]]$Relations=@(),[string]$Declarant='',[string[]]$Notes=@())
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$list=@($Relations);$noteList=@($Notes);$r.LastRefusal=''
    $entries=[Collections.Generic.List[object]]::new();$computers=[Collections.Generic.List[string]]::new()
    # Stored rows to remove, keyed by object identity (one pass over the store afterwards, not one per removal).
    $storedTargets=[Collections.Generic.Dictionary[int,Collections.Generic.List[object]]]::new();$storedCount=0
    $sessionTargets=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $list.Count;$i++){
        $found=Find-DomeniaRelationInstance $list[$i]
        if($null -eq $found){continue}
        $target=$found.Item;$hash=[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($target)
        $bucket=$null;$already=$false
        if($found.Stored -and $storedTargets.TryGetValue($hash,[ref]$bucket)){$already=(Test-DomeniaRelationsListContains $bucket.ToArray() $target)}
        if(-not $found.Stored){$already=(Test-DomeniaRelationsListContains $sessionTargets.ToArray() $target)}
        if($already){continue}
        $note=if($i -lt $noteList.Count -and [string]$noteList[$i]){[string]$noteList[$i]+' '}else{''}
        $note+=$(if($found.Stored){'Retirée du stockage local.'}else{'Retirée de la liste de session.'})
        $entries.Add((New-DomeniaLinkHistoryEntry -Action Removed -Relation $target -Declarant $Declarant -Note $note))
        if($found.Stored){
            if($null -eq $bucket){$bucket=[Collections.Generic.List[object]]::new();$storedTargets[$hash]=$bucket}
            $bucket.Add($target);$storedCount++
        }else{$sessionTargets.Add($target)}
        $computers.Add((ConvertTo-DomeniaRelationComputerKey ([string]$target.Computer)))
    }
    if(-not $entries.Count){return 0}
    if($storedCount){
        $why=Get-DomeniaRelationSaveRefusal -Changes $storedCount
        if($why){$r.LastRefusal=$why;return -1}
    }
    $previous=@($script:UserMachineLinks);$previousObservations=$r.Observations.ToArray()
    if($storedCount){
        $kept=[Collections.Generic.List[object]]::new()
        foreach($l in $previous){
            $bucket=$null
            if($null -ne $l -and $storedTargets.TryGetValue([Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($l),[ref]$bucket) -and (Test-DomeniaRelationsListContains $bucket.ToArray() $l)){continue}
            $kept.Add($l)
        }
        $script:UserMachineLinks=$kept.ToArray()
        foreach($bucket in $storedTargets.Values){foreach($target in $bucket){Update-DomeniaRelationLinkIndex -Link $target -Remove}}
    }
    foreach($target in $sessionTargets){for($j=0;$j -lt $r.Observations.Count;$j++){if([object]::ReferenceEquals($r.Observations[$j],$target)){$r.Observations.RemoveAt($j);break}}}
    if($storedCount -and -not (Save-UserMachineLinks)){
        $script:UserMachineLinks=$previous;$r.Observations.Clear();foreach($o in $previousObservations){$r.Observations.Add($o)};Rebuild-UserMachineLinkIndex;Refresh-DomeniaRelationViews
        return -1
    }
    foreach($e in $entries){Add-DomeniaRelationHistory $e}
    $r.Revision++;foreach($k in $computers){if($k){[void]$r.DirtyComputers.Add($k)}}
    Refresh-DomeniaRelationViews
    return $entries.Count
}
function Get-DomeniaRelationRefusalText {
    # Message of a refused removal: the reason known before the change, otherwise the queue already said why.
    param([string]$Prefix,[string]$Suffix)
    $why=if($null -ne $script:Relations){[string]$script:Relations.LastRefusal}else{''}
    if($why){return ($Prefix+' : '+$why+'. '+$Suffix)}
    return ($Prefix+' : le stockage local a refusé la modification (motif dans le message précédent). '+$Suffix)
}
function Remove-DomeniaRelation {
    # D050: the removal touches only the local store or the session list. It is journaled and can be restored.
    param($Relation,[string]$Declarant='')
    Initialize-DomeniaRelationsState
    if($null -eq $Relation){return $false}
    $label=[string]$Relation.UserLogin+' → '+[string]$Relation.Computer
    $n=Remove-DomeniaRelations -Relations @($Relation) -Declarant $Declarant
    if($n -eq 0){Set-Status 'Association introuvable : déjà retirée ou rechargée. Aucune modification.' 'WARN';return $false}
    if($n -lt 0){Set-Status (Get-DomeniaRelationRefusalText 'Suppression non enregistrée' 'Association conservée.') 'WARN';return $false}
    Set-Status ('Association retirée localement : '+$label+'. Aucun objet Active Directory modifié ; « Restaurer '+$label+' » la remet en place.')
    return $true
}
function Request-DomeniaRelationRemoval {
    # Asked in the page when the inline confirmation of the shell exists (Features.InlineConfirm), otherwise by the legacy confirmation.
    param($Relation)
    Initialize-DomeniaRelationsState
    if($null -eq $Relation -or (Test-DomeniaAccessBusyWrite)){return}
    $label=[string]$Relation.UserLogin+' → '+[string]$Relation.Computer
    $inline=Get-Command -Name 'Request-DomeniaInlineConfirmation' -CommandType Function -ErrorAction SilentlyContinue
    if($null -ne $inline -and (Get-DomeniaFeatureFlag 'InlineConfirm' $true)){
        $script:Relations.PendingRemoval=$Relation
        $message='Supprimer cette association locale ('+$label+') ? Aucun objet Active Directory nʼest modifié ; la suppression est journalisée et peut être restaurée.'
        [void](Request-DomeniaInlineConfirmation -Title 'Supprimer lʼassociation' -Message $message -Target ('relation:'+(Get-DomeniaRelationKey $Relation)) -ConfirmText 'Supprimer' -CancelText 'Annuler' -OnConfirm {Complete-DomeniaRelationRemoval} -OnCancel {Cancel-DomeniaRelationRemoval} -Risk 'Normal')
        return
    }
    if(-not (Confirm-Action ("Supprimer ce lien user-machine ?`n"+$label+"`nAucun objet Active Directory n'est modifie ; la suppression est journalisee et restaurable."))){return}
    [void](Remove-DomeniaRelation -Relation $Relation -Declarant ([string]$script:Conn.BindUser))
}
function Complete-DomeniaRelationRemoval {
    Initialize-DomeniaRelationsState
    $p=$script:Relations.PendingRemoval;$script:Relations.PendingRemoval=$null
    if($null -eq $p -or (Test-DomeniaAccessBusyWrite)){return}
    [void](Remove-DomeniaRelation -Relation $p -Declarant ([string]$script:Conn.BindUser))
}
function Cancel-DomeniaRelationRemoval {
    Initialize-DomeniaRelationsState
    $script:Relations.PendingRemoval=$null
    Set-Status 'Suppression annulée : aucune association modifiée.'
}
function Restore-DomeniaRemovedLink {
    # D050: puts back the last local removal from the journal. Nothing is read from or written to Active Directory.
    param($Entry=$null)
    Initialize-DomeniaRelationsState
    if(Test-DomeniaAccessBusyWrite){return $false}
    # CO-28: by default, exactly the removal named on the button.
    if($null -eq $Entry){$Entry=Get-DomeniaRelationsRestoreCandidate}
    if($null -eq $Entry){Set-Status 'Aucune suppression locale à restaurer.' 'INFO';Update-DomeniaRelationsActions;return $false}
    $c=Get-DomeniaLinkRestoreCandidate $Entry @(Get-DomeniaRelationsAllRelations)
    if(-not $c.Restorable){Set-Status ('Restauration non effectuée : '+[string]$c.Reason) 'INFO';Add-DomeniaRelationHistory (New-DomeniaLinkHistoryEntry -Action Restored -Relation $Entry.Relation -Declarant ([string]$script:Conn.BindUser) -Note ([string]$Entry.Id)) -Quiet;Update-DomeniaRelationsActions;return $false}
    $v=$c.Relation
    # CO-29: a restored row is written again, so its date takes the UTC form.
    $when=ConvertTo-DomeniaRelationWhenText ([string]$v.When);if(-not $when){$when=[string]$v.When}
    $relation=[pscustomobject]@{UserLogin=[string]$v.UserLogin;Computer=[string]$v.Computer;Source=[string]$v.Source;Confidence=0;VerifiedInAD=([string]$v.VerifiedInAD -ieq 'True');When=$when;Details=[string]$v.Details;UserGuid=[string]$v.UserGuid;ComputerGuid=[string]$v.ComputerGuid;UserDn=[string]$v.UserDn;ComputerDn=[string]$v.ComputerDn;Kind=[string]$v.Kind}
    $o=Add-DomeniaRelation -Relation $relation -Declarant ([string]$script:Conn.BindUser) -Quiet
    if($o.SaveFailed -or $o.Action -eq 'Ignore'){Set-Status ('Restauration non enregistrée : '+[string]$o.Reason) 'WARN';return $false}
    Add-DomeniaRelationHistory (New-DomeniaLinkHistoryEntry -Action Restored -Relation $relation -Declarant ([string]$script:Conn.BindUser) -Note ([string]$Entry.Id))
    $where=if($o.Placement -eq 'Session'){' '+[string]$o.Reason}else{''}
    Set-Status ('Association restaurée localement : '+$relation.UserLogin+' → '+$relation.Computer+'. Aucun objet Active Directory modifié.'+$where)
    Refresh-DomeniaRelationViews
    return $true
}
function Save-DomeniaRelationConfirmations {
    param($Result,$State)
    if(-not (Test-DomeniaRelationsCurrent $State) -or (Test-DomeniaAccessBusyWrite)){return}
    $changes=@($Result.Candidates|Where-Object{$_.Confirmed -eq $true -and $_.Guid -and $_.DN}|Select-Object -First 50)
    if(-not $changes.Count){return}
    if($null -ne $script:Persistence -and $script:Persistence.LinkBusy){$script:Relations.PendingConfirmed=[pscustomobject]@{Result=$Result;State=$State};return}
    # D042: an observed console is added next to the existing relations through the upsert rule;
    # it never removes a relation and never replaces a declared assignment. No fixed score is written.
    $r=$script:Relations;$before=@($script:UserMachineLinks);$beforeObservations=$r.Observations.ToArray()
    $stored=0;$sessionOnly=0;$computers=[Collections.Generic.List[string]]::new()
    foreach($c in $changes){
        $incoming=[pscustomobject]@{UserLogin=$State.Login;Computer=(Normalize-LinkComputer $c.Computer);Source='Console CIM/DCOM';Confidence=0;VerifiedInAD=$true;When=[string]$c.ObservedUtc;Details=[string]$c.Detail;UserGuid=[string]$Result.UserGuid;UserDn=[string]$State.DN;ComputerGuid=[string]$c.Guid;ComputerDn=[string]$c.DN;Kind='Console'}
        $o=Add-DomeniaRelation -Relation $incoming -Declarant ([string]$script:Conn.BindUser) -NoSave -Quiet
        if($o.StoredChanged){$stored++}elseif($o.Placement -eq 'Session'){$sessionOnly++}
        $computers.Add([string]$incoming.Computer)
    }
    if($stored){
        if(-not (Save-UserMachineLinks)){
            $script:UserMachineLinks=$before;$r.Observations.Clear();foreach($o in $beforeObservations){$r.Observations.Add($o)};Rebuild-UserMachineLinkIndex
            [void](Show-DomeniaRouteNotice -Kind Warning -Text 'Consoles observées, mais associations non enregistrées dans la base locale.' -RouteText 'Voir le stockage' -Route 'StorageResume' -Key 'links-not-saved');return
        }
        Write-AppLog ($stored.ToString()+' association(s) de console confirmée(s) en mémoire ; sauvegarde demandée en arrière-plan.') 'INFO'
    }
    $conflicts=@(Get-DomeniaLinkConflicts @(Get-DomeniaRelationsAllRelations)|Where-Object{$computers -contains (Normalize-LinkComputer ([string]$_.Computer))})
    if($sessionOnly -or $conflicts.Count){
        $text=$sessionOnly.ToString()+' console(s) observée(s) conservée(s) pour la session : lʼaffectation déclarée ou la relation plus récente reste enregistrée.'
        foreach($k in $conflicts){$text+=' '+[string]$k.Computer+' : affecté à '+[string]$k.Declared+', session de '+[string]$k.Observed+' (Contradictoire, les deux sont conservées).'}
        Set-Status $text 'INFO';Write-AppLog $text 'INFO'
    }
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
    $phase=[string](Get-DomeniaMember $q 'Phase' '');$plan=Get-DomeniaMember $q 'Plan' $null
    $known=@(Get-DomeniaRelationsSelectedLinks).Count;$confirmed=@($r.Candidates|Where-Object{$_.Confirmed -eq $true}).Count
    $save=[bool]$r.Success
    if($phase -eq 'Collect' -and $r.Success){
        # D047 phase 1: known associations and AD clues only, nothing contacted. The plan is shown before any probe.
        $cands=@(@($r.Candidates|Where-Object{[string]$_.Guid})|Sort-Object -Property @{Expression={[bool]$_.Known};Descending=$true},Computer|ForEach-Object{[pscustomobject]@{Guid=[string]$_.Guid;Computer=[string]$_.Computer;DN=[string]$_.DN;Domain=[string]$script:Conn.BaseDn;Source=[string]$_.Source}})
        $limit=[int](Get-DomeniaMember $State 'Limit' 20);if($limit -lt 1 -or $limit -gt 50){$limit=20}
        $newPlan=Get-DomeniaDetectionScopePlan -RequestedScope Candidates -OuDn '' -DomainDn ([string]$script:Conn.BaseDn) -Candidates $cands -Limit $limit -IncludeRdp $false
        $message='Annuaire lu : '+$known+' association(s) connue(s), '+@($r.Candidates).Count+' candidat(s) AD. Aucun poste contacté.'
        if($r.Partial){$message+=' Résultat partiel : limites ou erreurs dans Détail de la recherche.'}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $message);Write-AppLog $message 'INFO'
        $save=$false
        [void](Step-DomeniaRelationsAssociation 'Results' -Quiet)
        Show-DomeniaRelationDetectionPlan -Plan $newPlan -Subject $script:Relations.Subject -Events $false -Limit $limit -Prefix ($message+' ')
    }elseif($phase -eq 'Probe' -and $null -ne $plan){
        # D047/D048: the probed list must stay inside the confirmed plan; counters come from the attempts, which are authoritative.
        $probed=@($r.ProbedGuids)
        $within=Test-DomeniaDetectionWithinPlan $plan $probed
        $complete=Test-DomeniaDetectionMatchesPlan $plan $probed
        $counters=New-DomeniaDetectionCounters @($plan.Candidates).Count
        foreach($a in @($r.Attempts|Where-Object{[string]$_.Method -eq 'Console CIM/DCOM'})){$o=ConvertTo-DomeniaDetectionOutcome ([string]$a.Status);if($o){[void](Add-DomeniaDetectionOutcome $counters $o)}}
        if($null -ne (Get-DomeniaMember $q 'Counters' $null) -and [bool]$q.Counters.Stopped){[void](Add-DomeniaDetectionOutcome $counters 'Stopped')}
        $q|Add-Member -NotePropertyName Counters -NotePropertyValue $counters -Force
        $message=if(-not $r.Success){
            $first=@($r.Attempts|Where-Object{$_.Status -notin @('OK','VIDE','NON_DEMANDE')}|Select-Object -First 1)
            $reason=if($first.Count){' '+[string]$first[0].Method+' : '+[string]$first[0].Detail}else{''}
            'Recherche AD non confirmée.'+$reason+' Les associations connues restent conservées.'
        }else{'Détection terminée : '+(Get-DomeniaDetectionCounterText $counters)+'.'}
        if($r.Success -and -not $within){$save=$false;$message='Liste interrogée différente de la liste confirmée : aucun résultat enregistré. '+$message}
        elseif($r.Success -and -not $complete){$message+=' Liste confirmée interrogée en partie seulement (limite, délai ou refus).'}
        if($r.Success -and -not $counters.Confirmed){$message+=' '+[string]$plan.ZeroMeaning}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $message);Set-Status $message;Write-AppLog $message 'INFO'
        [void](Step-DomeniaRelationsAssociation 'Results' -Quiet)
    }else{
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
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $message);Set-Status $message;Write-AppLog $message 'INFO'
        [void](Step-DomeniaRelationsAssociation 'Results' -Quiet)
    }
    if($save){Save-DomeniaRelationConfirmations $r $State}
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
    [void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)
    Write-AppLog ('Recherche inverse non terminée : '+[string]$Message) 'WARN';Refresh-DomeniaRelationViews
}
function Get-DomeniaRelationScopeCandidates {
    # D047: the machines of the requested perimeter, as loaded and displayed. Nothing else is substituted.
    param([ValidateSet('Loaded','OU')][string]$Scope)
    $domain=[string]$script:Conn.BaseDn;$ou=[string]$script:SelectedBranchDn
    foreach($row in @($script:BranchObjects)){
        if($null -eq $row -or [string]$row.Type -ne 'Machine' -or -not [string]$row.Guid){continue}
        if($Scope -eq 'OU' -and (-not $ou -or -not ([string]$row.DN).EndsWith(','+$ou,[StringComparison]::OrdinalIgnoreCase))){continue}
        [pscustomobject]@{Guid=[string]$row.Guid;Computer=[string]$row.Name;DN=[string]$row.DN;Domain=$domain;Source=$(if($Scope -eq 'OU'){'OU choisie'}else{'Liste chargée'})}
    }
}
function Show-DomeniaRelationDetectionPlan {
    # D047: the list really aimed at is shown in the page before any workstation is contacted. A refused plan
    # explains the absence of source; the requested perimeter is never replaced by another one.
    param($Plan,$Subject,[bool]$Events=$false,[int]$Limit=20,[string]$Prefix='')
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$r.PendingPlan=$null
    if($null -eq $Plan -or -not [bool]$Plan.Allowed){
        $why=if($null -ne $Plan){[string]$Plan.Reason}else{'Périmètre non calculé.'}
        if($null -ne $Plan -and [string]$Plan.ZeroMeaning -and $Plan.Scope -ne 'OU'){$why+=' '+[string]$Plan.ZeroMeaning}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' ($Prefix+$why+' Aucun poste contacté.'))
        Refresh-DomeniaRelationViews;return
    }
    $scopeText=switch([string]$Plan.Scope){'OU'{'OU '+[string]$Plan.OuDn}'Loaded'{'machines de la liste chargée'}default{'postes connus et candidats AD'}}
    $text=([string]@($Plan.Candidates).Count+' poste(s) à interroger ('+$scopeText+'), limite '+[string]$Plan.Limit+'.')
    if([bool]$Plan.Truncated){$text+=' Liste tronquée : '+[string]$Plan.Eligible+' poste(s) éligible(s), seuls les '+[string]$Plan.Limit+' premiers seront lus.'}
    $text+=' Lecture de la console uniquement ; sessions RDP non lues (option séparée, non disponible). Aucun poste nʼest contacté avant « Lancer la détection ».'
    $rows=@(@($Plan.Candidates)|ForEach-Object{[pscustomobject]@{Computer=[string]$_.Computer;Status='À confirmer';CurrentUser='';Source=[string]$_.Source;ObservedUtc='';Detail='Dans le périmètre affiché ; aucune lecture effectuée.';Guid=[string]$_.Guid;DN=[string]$_.DN;Badge='Périmètre';BadgeLabel='Périmètre';WhenDisplay='';WhenSort=[datetime]::MinValue;BadgeRule='Poste du périmètre à confirmer.';Why=('Périmètre demandé : '+$scopeText+'.');Associable=$false;Blocker='Aperçu : lancez la détection ou recherchez le poste.'}})
    $r.PendingPlan=[pscustomobject]@{Plan=$Plan;Rows=$rows;Text=$text;Epoch=[long]$script:SessionEpoch;Generation=$r.Generation;SubjectDn=[string]$Subject.DN;SubjectGuid=[string]$Subject.Guid;Login=[string]$Subject.Login;Events=$Events;Limit=$Limit}
    Show-DomeniaRelationsAddPanel -Mode Detect
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' ($Prefix+'Périmètre à confirmer : '+$text))
    Refresh-DomeniaRelationViews
}
function Confirm-DomeniaRelationDetectionPlan {
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$p=$r.PendingPlan
    if($null -eq $p){return}
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s -or $s.Type -ne 'Utilisateur' -or $p.Epoch -ne [long]$script:SessionEpoch -or $p.Generation -ne $r.Generation -or $p.SubjectDn -ine $s.DN -or $p.SubjectGuid -ine $s.Guid){
        $r.PendingPlan=$null;[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Sélection ou session modifiée : périmètre annulé, aucun poste contacté.');Refresh-DomeniaRelationViews;return
    }
    if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Une écriture reste active ou à vérifier.');return}
    if($null -ne $r.Query -and -not $r.Query.Ended){return}
    $plan=$p.Plan;$r.PendingPlan=$null
    $names=@(@($plan.Candidates)|ForEach-Object{[string]$_.Computer});$targets=@(@($plan.Candidates)|ForEach-Object{[string]$_.Guid})
    Submit-DomeniaRelationsQuery -Subject $s -Phase 'Probe' -Scan $true -Scope 'Loaded' -Loaded $names -Targets $targets -Limit @($plan.Candidates).Count -Events ([bool]$p.Events) -Plan $plan
}
function Cancel-DomeniaRelationDetectionPlan {
    Initialize-DomeniaRelationsState
    if($null -eq $script:Relations.PendingPlan){return}
    $script:Relations.PendingPlan=$null
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Détection annulée avant toute lecture : aucun poste contacté.')
    Refresh-DomeniaRelationViews
}
function Submit-DomeniaRelationsQuery {
    param($Subject,[string]$Phase,[bool]$Scan,[string]$Scope,[string[]]$Loaded=@(),[string[]]$Targets=@(),[int]$Limit=20,[bool]$Events=$false,$Plan=$null)
    $r=$script:Relations
    if($r.AssociationState -ne 'Searching'){
        if($r.AssociationState -in @('Pending','Verifying')){Cancel-DomeniaRelationAssociation}
        [void](Step-DomeniaRelationsAssociation 'Search' -Quiet)
    }
    $known=@(Get-DomeniaRelationsSelectedLinks|Where-Object{[string]$_.Persistence -ne 'Session uniquement'})
    $request=[guid]::NewGuid().ToString('N')
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$r.Generation;DN=$Subject.DN;Guid=$Subject.Guid;Login=$Subject.Login;BaseDn=[string]$script:Conn.BaseDn;RequestId=$request;Identity=(Get-DomeniaRelationsIdentity);Phase=$Phase;Limit=$Limit}
    $progress=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $counters=if($null -ne $Plan){New-DomeniaDetectionCounters @($Plan.Candidates).Count}else{$null}
    $r.Query=[pscustomobject]@{RequestId=$request;State=$state;Progress=$progress;Candidates=@{};Hints=[Collections.ArrayList]::new();Attempts=[Collections.ArrayList]::new();Ended=$false;AcceptResults=$true;Job='';Phase=$Phase;Plan=$Plan;Counters=$counters}
    $base=[string]$script:SelectedBranchDn;if(-not $base){$base=[string]$script:Conn.BaseDn}
    $payload=[pscustomobject]@{RequestId=$request;Login=$Subject.Login;UserDn=$Subject.DN;UserGuid=$Subject.Guid;KnownLinks=@($known|ForEach-Object{[pscustomobject]@{Computer=[string]$_.Computer;ComputerGuid=[string]$_.ComputerGuid;When=[string]$_.When;Source=[string]$_.Source}});ScanPark=$Scan;ScanScope=$Scope;ScanBaseDn=$base;ScanDepth='Subtree';LoadedComputers=@($Loaded);LoadedTargets=@($Targets);MaxProbes=[Math]::Max(1,[Math]::Min(50,$Limit));UseSecurityLog=$Events;BudgetMs=$(if($Scan){120000}else{45000});Progress=$progress}
    Show-DomeniaRelationsAddPanel -Mode Detect
    $status=if($Scan){'Détection de '+$Subject.Login+' : '+(Get-DomeniaDetectionCounterText $counters)+'.'}else{'Lecture des associations connues et des indices AD de '+$Subject.Login+' ; aucun poste contacté…'}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' $status)
    try{
        $r.Query.Job=Start-UiTask -Name ('Postes de '+$Subject.Login) -OperationId 'UserComputerProbe' -Code (Get-DomeniaRelationsWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'userprobe' -DisableControls @('BtnDetectUserComputers','CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents') -TimeoutSeconds $(if($Scan){140}else{65}) -SuccessHandler 'Complete-DomeniaUserComputersUi' -ErrorHandler 'Fail-DomeniaUserComputersUi'
    }catch{
        # Refused before any call (admission, worker limit, rejected account): the detection ends, nothing stays busy.
        $r.Query.Ended=$true;$r.Query.Job=''
        [void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Détection non lancée : '+$_.Exception.Message+' Aucun poste contacté.'))
        Update-DomeniaRelationsActions;Refresh-DomeniaRelationViews
        return
    }
    if($null -ne $r.Timer){$r.Timer.Start()};Refresh-DomeniaRelationViews
}
function Start-DomeniaRelationsComputerDetect {
    # D041/D049, workstation side: Détecter reads the session of the selected workstation through the
    # ComputerLastUser resolver; the result is attached to the Relations subject, even if the Fiche changed.
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s -or $s.Type -ne 'Machine'){return}
    if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Une écriture reste active ou à vérifier.');return}
    $name=Normalize-LinkComputer ([string]$s.Name)
    if(-not $name){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Nom du poste illisible : aucune lecture lancée.');return}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Lecture de la session de '+$name+' (geste explicite) ; les associations enregistrées restent affichées.'))
    Start-ComputerUserLinkProbe -Computer $name -Force -Origin 'ExplicitDetect' -RelationsSubject (Get-DomeniaRelationsSubjectIdentity)
    Update-DomeniaRelationsActions
}
function Complete-DomeniaRelationsComputerProbe {
    # D049: success handler of ComputerLastUser. A local account, a namesake from another authority or a bare
    # name is never the AD account (Test-DomeniaAccountIdentityMatch). Only a current session (Console or
    # SessionRdp) creates a relation; LogonUI, profiles and logon events are history and stay a clue.
    param($Result,$State)
    if([string](Get-DomeniaMemberValue $Result 'DataSource') -cne 'SQLite'){return}
    $computer='';$probeId=''
    try{$computer=Normalize-LinkComputer ([string]$State.Computer)}catch{}
    try{$probeId=[string]$State.ProbeId}catch{}
    if([string]::IsNullOrWhiteSpace($computer)){$computer='machine inconnue'}
    if(-not [string]::IsNullOrWhiteSpace($probeId) -and [string]$script:ActiveLinkProbeId -ne $probeId){Write-AppLog ('Resultat obsolete ignore pour '+$computer+' (probe='+$probeId+').') 'INFO';return}
    $captured=Get-DomeniaMember $State 'RelationsSubject' $null
    $relationsCurrent=($null -ne $captured -and (Test-DomeniaSameSubject $captured (Get-DomeniaRelationsSubjectIdentity)))
    $ficheCurrent=$false
    try{if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.Type -eq 'Machine'){$ficheCurrent=((Get-CurrentSelectedComputerName) -ieq $computer)}}catch{}
    if(-not $relationsCurrent -and -not $ficheCurrent){Write-AppLog ('Resultat user-machine ignore : ni la fiche ni le sujet Relations ne designent '+$computer+'.') 'INFO';return}
    try{
        $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Computer','Success','Attempts')
        if($null -eq $effective){throw 'Le worker n a retourne aucun resultat de detection exploitable.'}
        $attempts=[Collections.ArrayList]::new();foreach($a in @($effective.Attempts)){[void]$attempts.Add($a)}
        foreach($a in @($effective.Attempts)){if([string]$a.Status -eq 'OK'){continue};try{Add-DomeniaUiLog -Area 'Association' -Level $(if([string]$a.Status -in @('KO','VALIDATION AD KO')){'WARN'}else{'INFO'}) -Text (ConvertTo-DomeniaFlatText ($computer+' | '+[string]$a.Method+' ['+[string]$a.Status+'] | '+[string]$a.Detail) 1600)}catch{}}
        $user=Normalize-LinkUser ([string]$effective.UserLogin)
        if(-not ([bool]$effective.Success -and [bool]$effective.VerifiedInAD -and $user)){
            $message="Aucune session AD lue pour $computer. Voir les tentatives ; aucune association modifiée."
            if([bool](Get-DomeniaMember $effective 'RemoteAccessFailed' $false)){
                $cached=Get-ExistingLinkForComputer $computer
                $message=if($null -ne $cached -and [string]$cached.UserLogin){"Lecture distante indisponible pour $computer ; association enregistrée conservée : "+[string]$cached.UserLogin+'.'}else{"Utilisateur non déterminé pour $computer : lecture distante indisponible. Aucune association modifiée."}
            }
            [void](Set-DomeniaItemsSource 'DgLinkAttempts' $attempts.ToArray());[void](Set-DomeniaControlText 'LblLinkProbeStatus' $message);Set-Status $message 'WARN';Write-AppLog $message 'WARN'
            return
        }
        $raw=[string](Get-DomeniaMember $effective 'RawAccount' '');if(-not $raw){$raw=[string]$effective.UserLogin}
        $source=[string]$effective.Source;$kind=Get-DomeniaRelationKind $source
        $target=[pscustomobject]@{Login=$user;NetbiosDomain=[string]$script:Conn.Netbios;DnsDomain=[string]$script:Conn.Domain;Sid=[string](Get-DomeniaMember $effective 'UserSid' '');Upn=[string](Get-DomeniaMember $effective 'UserUpn' '')}
        $match=Test-DomeniaAccountIdentityMatch $target $raw ([string](Get-DomeniaMember $effective 'ObservedSid' '')) $computer
        $badge=Get-DomeniaEvidenceBadge ([pscustomobject]@{Source=$source;Kind=$kind;When=[string]$effective.SourceCompletedUtc})
        if(-not $match.Match){
            [void]$attempts.Add([pscustomobject]@{Method='Identité du compte';Status=$(if($match.Certain){'HORS DOMAINE'}else{'NON QUALIFIE'});User=$raw;Score='';DurationMs=0;Detail=[string]$match.Reason})
            $message="Compte lu sur $computer : $raw ($source). "+[string]$match.Reason+" Aucune association créée : un compte local, dʼun autre domaine ou non qualifié nʼest pas le compte AD $user."
        }elseif($kind -notin @('Console','SessionRdp')){
            $message="Indice pour $computer : $user ($source · "+$badge.Label+'). '+$badge.Rule+' Aucune association créée automatiquement ; associez-le explicitement si besoin.'
        }else{
            $added=Add-DomeniaRelation -Relation ([pscustomobject]@{UserLogin=$user;Computer=[string]$effective.Computer;Source=$source;Details=[string]$effective.Details;Confidence=0;VerifiedInAD=$true;When=[string]$effective.SourceCompletedUtc;ComputerGuid=[string]$State.StoreGuid;ComputerDn=[string]$State.StoreDn}) -NoSave -Quiet
            $outcome=if($null -ne $script:Relations){$script:Relations.LastOutcome}else{$null}
            $message=if($added){"Session observée sur $computer : $user ($source · "+$badge.Label+').'}elseif($null -ne $outcome -and [bool]$outcome.SaveFailed){"Session observée sur $computer : $user. Relation non enregistrée : "+[string]$outcome.Reason}elseif($null -ne $outcome -and [string]$outcome.Placement -eq 'Session'){"Session observée sur $computer : $user. "+[string]$outcome.Reason}else{"Session observée sur $computer : $user. Relation déjà connue : date mise à jour, aucune autre association modifiée."}
            try{Register-DomeniaOperationSample -Operation 'ComputerLastUser' -Mode $(if([string](Get-DomeniaMember $effective 'FallbackTransport' '') -eq 'PsExec'){'Classic+PsExec'}elseif([string](Get-DomeniaMember $effective 'FallbackTransport' '')){'Classic+TaskScheduler'}else{'Classic'}) -ItemCount 1 -DurationMs 0 -BytesEstimated $(if([long](Get-DomeniaMember $effective 'TaskBytes' 0) -gt 0){[long]$effective.TaskBytes}else{16000}) -RemoteAttempts 1 -FallbackTasks ([int](Get-DomeniaMember $effective 'FallbackTasks' 0)) -SuccessCount 1}catch{}
        }
        [void](Set-DomeniaItemsSource 'DgLinkAttempts' $attempts.ToArray())
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $message);Set-Status $message;Write-AppLog $message 'INFO'
    }catch{
        Fail-DomeniaComputerUserProbeUi -Message $_.Exception.Message -State ([pscustomobject]@{Computer=$computer;ProbeId=$probeId})
    }finally{
        if([string]$script:ActiveLinkProbeId -eq $probeId){$script:ActiveLinkProbeId='';$script:ActiveLinkProbeComputer=''}
        try{Refresh-AssociationContext -SkipResultRefresh}catch{}
        try{Refresh-DomeniaRelationViews}catch{}
    }
}
function Fail-DomeniaRelationsComputerProbe {
    param($Message,$State)
    $captured=Get-DomeniaMember $State 'RelationsSubject' $null
    $probeId=[string](Get-DomeniaMember $State 'ProbeId' '')
    if($null -ne $captured -and (Test-DomeniaSameSubject $captured (Get-DomeniaRelationsSubjectIdentity)) -and (-not $probeId -or [string]$script:ActiveLinkProbeId -eq $probeId)){
        $computer=Normalize-LinkComputer ([string]$State.Computer)
        if([string]$script:ActiveLinkProbeId -eq $probeId){$script:ActiveLinkProbeId='';$script:ActiveLinkProbeComputer=''}
        $text='Lecture de session non confirmée pour '+$computer+' : '+([string]$Message).Trim()+'. Aucune association modifiée.'
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $text);Set-Status $text 'WARN';Write-AppLog $text 'WARN'
        try{Refresh-DomeniaRelationViews}catch{}
        return
    }
    Fail-DomeniaComputerUserProbeUi -Message $Message -State $State
}
function Start-DomeniaRelationsSearch {
    try{
        $s=Get-DomeniaRelationsSubject
        if($null -ne $s -and $s.Type -eq 'Machine'){Start-DomeniaRelationsComputerDetect;return}
        if($null -eq $s -or $s.Type -ne 'Utilisateur'){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Sélectionnez dʼabord un utilisateur ou un poste dans Rechercher.');return}
        if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Une écriture reste active ou à vérifier.');return}
        $r=$script:Relations;if($null -ne $r.Query -and -not $r.Query.Ended){return}
        # D048: only an explicit gesture may start a probe; rendering or scrolling a list never does.
        if(-not (Test-DomeniaProbeAllowed 'ExplicitDetect')){return}
        $events=[bool](Get-DomeniaControl 'ChkRelationEvents').IsChecked
        $scope=[string](Get-DomeniaControl 'CmbRelationScanScope').SelectedItem.Tag;if($scope -notin @('Candidates','Loaded','OU')){$scope='Candidates'}
        $limit=20;$raw=[string](Get-DomeniaControl 'TxtRelationScanLimit').Text
        if(-not [int]::TryParse($raw,[ref]$limit) -or $limit -lt 1 -or $limit -gt 50){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Maximum invalide : choisissez une valeur de 1 à 50.');return}
        # D047/CD-06: no silent change of perimeter. Candidates first reads the directory only (phase 1);
        # Loaded and OU take the machines displayed for that perimeter. A plan is confirmed before any probe.
        $r.PendingPlan=$null
        if($scope -eq 'Candidates'){Submit-DomeniaRelationsQuery -Subject $s -Phase 'Collect' -Scan $false -Scope 'Candidates' -Limit $limit -Events $events;return}
        $cands=@(Get-DomeniaRelationScopeCandidates -Scope $scope)
        $plan=Get-DomeniaDetectionScopePlan -RequestedScope $scope -OuDn ([string]$script:SelectedBranchDn) -DomainDn ([string]$script:Conn.BaseDn) -Candidates $cands -Limit $limit -IncludeRdp $false
        Show-DomeniaRelationDetectionPlan -Plan $plan -Subject $s -Events $events -Limit $limit
    }catch{if($null -ne $script:Relations.Query){$script:Relations.Query.Ended=$true;$script:Relations.Query.Job=''};[void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Détection impossible : '+$_.Exception.Message));Write-AppLog ('Relations : '+$_.Exception.ToString()) 'WARN'}
}
function Stop-DomeniaRelationsSearch {
    if($null -ne $script:Relations -and $null -ne $script:Relations.Query -and $script:Relations.Query.Job){
        $q=$script:Relations.Query
        Request-UiTaskStop -Id $q.Job -Reason 'Recherche inverse annulée par l opérateur'
        $q.AcceptResults=$false;$q.Ended=$true;$q.Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();$script:Relations.PendingConfirmed=$null
        if($null -ne $script:Relations.Timer){$script:Relations.Timer.Stop()}
        $counters=Get-DomeniaMember $q 'Counters' $null
        if($null -ne $counters){[void](Add-DomeniaDetectionOutcome $counters 'Stopped')}
        [void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)
        Update-DomeniaRelationsActions
        $text='Arrêt demandé. Les liens enregistrés sont conservés ; attente de la fin réelle de la lecture.'
        if($null -ne $counters){$text+=' '+(Get-DomeniaDetectionCounterText $counters)+'.'}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $text)
    }
}
function Use-DomeniaRelationCandidate {
    param([switch]$Open)
    $s=Get-DomeniaRelationsSubject;$d=Get-DomeniaControl 'DgRelationCandidates';$c=if($null -ne $d){$d.SelectedItem}else{$null}
    if($null -eq $s -or $s.Type -ne 'Utilisateur' -or $null -eq $c -or -not $c.DN -or (Test-DomeniaAccessBusyWrite)){return}
    if(-not [bool](Get-DomeniaMember $c 'Associable' $false)){
        # D046: a candidate without AD identity (an IP address, a partial name) cannot be associated.
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Association impossible : '+[string](Get-DomeniaMember $c 'Blocker' 'objet AD non identifié par son GUID.')));return
    }
    if($Open){Open-AdObject -Dn ([string]$c.DN) -Type Machine;return}
    Set-DomeniaRelationPendingAssociation -Computer ([string]$c.Computer) -DN ([string]$c.DN) -Guid ([string]$c.Guid) -Source ([string]$c.Source)
}
function Initialize-DomeniaRelationsUi {
    Initialize-DomeniaRelationsState
    if($script:Relations.Bound){return};$script:Relations.Bound=$true
    # FI-05: protected heartbeat timer, owned and registered by the factory; it runs only while a detection is shown.
    $script:Relations.Timer=New-DomeniaTimer -Owner 'Timer:Relations' -IntervalMs 120 -Tick {Invoke-DomeniaRelationsTick}
    $script:Window.Add_Closed({if($null -ne $script:Relations){$script:Relations.Timer.Stop();$script:Relations.Query=$null;$script:Relations.Subject=$null;$script:Relations.PendingConfirmed=$null;$script:Relations.PendingAssociation=$null;$script:Relations.PendingPlan=$null}})
    $tabs=Get-DomeniaControl 'RelationTabs';if($null -ne $tabs){$tabs.Add_SelectionChanged({param($sender,$e) if($e.OriginalSource -eq $sender){Update-DomeniaRelationsActions}})}
    foreach($name in @('DgAllLinks','DgRelationCandidates','DgRelationComputerSearch','DgLinks')){$g=Get-DomeniaControl $name;if($null -ne $g){$g.Add_SelectionChanged({Update-DomeniaRelationsActions})}}
    $search=Get-DomeniaControl 'BtnRelationComputerSearch';if($null -ne $search){$search.Add_Click({Start-DomeniaRelationComputerSearch})}
    $term=Get-DomeniaControl 'TxtRelationComputerSearch';if($null -ne $term){$term.Add_KeyDown({param($s,$e)if($e.Key -eq 'Return'){$e.Handled=$true;Start-DomeniaRelationComputerSearch}});$term.Add_TextChanged({Clear-DomeniaRelationManualResults})}
    $assoc=Get-DomeniaControl 'BtnRelationAssociateSearchResult';if($null -ne $assoc){$assoc.Add_Click({Request-DomeniaRelationManualAssociation})}
    $exportAll=Get-DomeniaControl 'BtnExportAllLinks';if($null -ne $exportAll){$exportAll.Add_Click({$tabs=Get-DomeniaControl 'RelationTabs';$all=Get-DomeniaControl 'TabLinksAll';if($null -ne $tabs -and $null -ne $all){$tabs.SelectedItem=$all};Clear-DomeniaAllLinksFilter;Export-DomeniaLinksCsv})}
    $cancel=Get-DomeniaControl 'BtnRelationConfirmCancel';if($null -ne $cancel){$cancel.Add_Click({Cancel-DomeniaRelationAssociation})}
    $apply=Get-DomeniaControl 'BtnRelationConfirmApply';if($null -ne $apply){$apply.Add_Click({Confirm-DomeniaRelationAssociation})}
    $planRun=Get-DomeniaControl 'BtnRelationPlanRun';if($null -ne $planRun){$planRun.Add_Click({Confirm-DomeniaRelationDetectionPlan})}
    $planCancel=Get-DomeniaControl 'BtnRelationPlanCancel';if($null -ne $planCancel){$planCancel.Add_Click({Cancel-DomeniaRelationDetectionPlan})}
    foreach($name in @('BtnRestoreLink','BtnRestoreLinkAll')){$restore=Get-DomeniaControl $name;if($null -ne $restore){$restore.Add_Click({[void](Restore-DomeniaRemovedLink)})}}
    (Get-DomeniaControl 'BtnRelationsStop').Add_Click({Stop-DomeniaRelationsSearch})
    (Get-DomeniaControl 'BtnRelationOpenCandidate').Add_Click({Use-DomeniaRelationCandidate -Open})
    (Get-DomeniaControl 'BtnRelationAdopt').Add_Click({Use-DomeniaRelationCandidate})
    $workspace=Get-DomeniaControl 'WorkspaceTabs';if($null -ne $workspace){$workspace.Add_SelectionChanged({param($sender,$e) if($e.OriginalSource -eq $sender -and [string]$sender.SelectedItem.Name -eq 'TabRelations'){Open-DomeniaRelationsPage}})}
    $help=Get-DomeniaControl 'BtnRelationsHelp';if($null -ne $help){$help.Add_Click({Switch-DomeniaRelationsHelp})}
    $filter=Get-DomeniaControl 'TxtAllLinksFilter';if($null -ne $filter){$filter.Add_TextChanged({Update-DomeniaAllLinksView})}
    foreach($name in @('ChkAllLinksDeclared','ChkAllLinksObserved','ChkAllLinksConflict')){$chip=Get-DomeniaControl $name;if($null -ne $chip){$chip.Add_Click({Update-DomeniaAllLinksView})}}
    foreach($pair in @(@('BtnLinkImportApply',{Confirm-DomeniaLinkImport}),@('BtnLinkImportCancel',{Cancel-DomeniaLinkImportPreview}),@('BtnUndoImport',{Request-DomeniaLinkImportUndo}),@('BtnLinkOrphanRemove',{Request-DomeniaOrphanRemoval}),@('BtnLinkOrphanClose',{Close-DomeniaOrphanLinks}),@('BtnLinkOrphanConfirmApply',{Complete-DomeniaOrphanRemoval}),@('BtnLinkOrphanConfirmCancel',{Cancel-DomeniaOrphanRemoval}))){$button=Get-DomeniaControl $pair[0];if($null -ne $button){$button.Add_Click($pair[1])}}
    $allLinks=Get-DomeniaControl 'DgAllLinks'
    if($null -ne $allLinks){
        # FO-14: right click selects the row under the pointer, then offers the fiche of the user or of the workstation.
        $allLinks.ContextMenu=New-DomeniaAllLinksContextMenu
        $allLinks.Add_PreviewMouseRightButtonDown({param($sender,$e) $hit=Get-DomeniaGridHit $e.OriginalSource;if($null -ne $hit -and $null -ne $hit.Row){$sender.SelectedItem=$hit.Row.Item}})
    }
    Refresh-DomeniaRelationViews
}
function Clear-DomeniaRelationManualResults {
    # A new term invalidates the previous results and any association prepared from them.
    if($null -eq $script:Relations){return}
    $script:Relations.ManualSearchRows=@()
    if($null -ne $script:Relations.PendingAssociation){Cancel-DomeniaRelationAssociation;return}
    if([string]$script:Relations.AssociationState -eq 'Candidate' -and -not $script:Relations.ManualSearchJob){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
    Refresh-DomeniaRelationViews
}

function Start-DomeniaRelationComputerSearch {
    Initialize-DomeniaRelationsState;$r=$script:Relations;$s=Get-DomeniaRelationsSubject
    $dir=$null;if($null -ne $s -and $s.Type -in @('Utilisateur','Machine')){$dir=Get-DomeniaRelationDirection $s.Type}
    if($null -eq $dir){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Sélectionnez dʼabord un utilisateur ou un poste dans Rechercher.');return}
    if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Une écriture reste active ou à vérifier.');return}
    if($r.ManualSearchJob -and $null -ne $script:AsyncJobs -and ((-not $script:AsyncJobs.Contains([string]$r.ManualSearchJob)) -or [bool]$script:AsyncJobs[[string]$r.ManualSearchJob].CancelRequested)){$r.ManualSearchJob='';if($null -eq $r.PendingAssociation){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}}
    if($r.ManualSearchJob){return}
    $term=([string](Get-DomeniaControl 'TxtRelationComputerSearch').Text).Trim()
    if($term.Length -lt 2){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Saisissez au moins deux caractères.');return}
    # D045: a new search cancels the association waiting for confirmation, then enters Searching.
    if($null -ne $r.PendingAssociation){Cancel-DomeniaRelationAssociation}
    if($r.AssociationState -ne 'Searching' -and -not (Step-DomeniaRelationsAssociation 'Search')){return}
    $kind=$dir.TargetType
    $request=[guid]::NewGuid().ToString('N');$r.ManualSearchRequest=$request;$r.ManualSearchRows=@();$r.PendingAssociation=$null
    [void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' $(if($kind -eq 'Utilisateur'){'Recherche des utilisateurs dans tout le domaine…'}else{'Recherche des postes dans tout le domaine…'}))
    $state=[pscustomobject]@{RequestId=$request;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;Generation=$r.Generation;SubjectDn=$s.DN;SubjectGuid=$s.Guid;Kind=$kind}
    $payload=[pscustomobject]@{Kind=$kind;Term=$term;Verify=$false;RequestId=$request;DN='';Guid=''}
    $r.ManualSearchJob=Start-UiTask -Name $(if($kind -eq 'Utilisateur'){'Recherche d utilisateur à associer'}else{'Recherche de poste à associer'}) -OperationId 'EmbeddedDirectoryLookup' -Code (Get-DomeniaEmbeddedLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'relations:computer-search' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaRelationComputerSearch' -ErrorHandler 'Fail-DomeniaRelationComputerSearch'
    Update-DomeniaRelationsActions
}
function Test-DomeniaRelationManualState {
    param($State)
    $r=$script:Relations;$s=Get-DomeniaRelationsSubject
    $typeOk=($null -ne $s -and $s.Type -in @('Utilisateur','Machine'))
    return ($null -ne $r -and $typeOk -and $State.Epoch -eq [long]$script:SessionEpoch -and $State.BaseDn -ieq [string]$script:Conn.BaseDn -and $State.Generation -eq $r.Generation -and $State.RequestId -ceq $r.ManualSearchRequest -and $State.SubjectDn -ieq $s.DN -and $State.SubjectGuid -ieq $s.Guid)
}
function Complete-DomeniaRelationComputerSearch {
    param($Result,$State)
    if(-not (Test-DomeniaRelationManualState $State)){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','RequestId','Verified')
    $script:Relations.ManualSearchJob=''
    if($null -eq $data -or $data.RequestId -cne $State.RequestId -or [bool]$data.Verified){Fail-DomeniaRelationComputerSearch 'Retour de recherche incohérent.' $State;return}
    $script:Relations.ManualSearchRows=@($data.Rows)
    $users=([string](Get-DomeniaMember $State 'Kind' 'Machine') -eq 'Utilisateur')
    $msg=if($script:Relations.ManualSearchRows.Count){$script:Relations.ManualSearchRows.Count.ToString()+$(if($users){' utilisateur(s) trouvé(s). Sélectionnez une ligne puis Associer cet utilisateur.'}else{' poste(s) trouvé(s). Sélectionnez une ligne puis Associer ce poste.'})}else{if($users){'Aucun utilisateur correspondant dans le domaine.'}else{'Aucun poste correspondant dans le domaine.'}}
    if($data.Capped){$msg+=' Limite atteinte : affinez la recherche.'}
    if([string]$script:Relations.AssociationState -eq 'Searching'){[void](Step-DomeniaRelationsAssociation 'Results' -Quiet)}
    [void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' $msg);Refresh-DomeniaRelationViews
}
function Fail-DomeniaRelationComputerSearch {
    param($Message,$State)
    if(-not (Test-DomeniaRelationManualState $State)){return}
    $script:Relations.ManualSearchJob='';$script:Relations.ManualSearchRows=@();[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' ('Recherche non confirmée : '+[string]$Message))
    [void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)
    Refresh-DomeniaRelationViews
}
function Set-DomeniaRelationPendingAssociation {
    param([string]$Computer,[string]$DN,[string]$Guid,[string]$Source='Recherche AD',[string]$Login='',[string]$TargetType='Machine')
    $s=Get-DomeniaRelationsSubject
    if($null -eq $s -or $s.Type -notin @('Utilisateur','Machine') -or -not $DN){return}
    $dir=Get-DomeniaRelationDirection $s.Type
    $TargetType=ConvertTo-DomeniaRelationType $TargetType
    if($TargetType -ne $dir.TargetType){[void](Set-DomeniaControlText 'LblRelationConfirm' ('Cible incompatible : depuis ce sujet, choisissez un objet de type '+$dir.TargetType+'.'));return}
    if($TargetType -eq 'Machine' -and -not $Computer){return}
    if($TargetType -eq 'Utilisateur' -and -not $Login){[void](Set-DomeniaControlText 'LblRelationConfirm' 'Identifiant de lʼutilisateur illisible : association impossible.');return}
    if(-not (Step-DomeniaRelationsAssociation 'Pick')){return}
    if($s.Type -eq 'Utilisateur'){$user=$s.Login;$userDn=$s.DN;$userGuid=$s.Guid;$pc=Normalize-LinkComputer $Computer;$pcDn=$DN;$pcGuid=$Guid}
    else{$user=$Login;$userDn=$DN;$userGuid=$Guid;$pc=Normalize-LinkComputer ([string]$s.Name);$pcDn=$s.DN;$pcGuid=$s.Guid}
    $script:Relations.PendingAssociation=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$script:Relations.Generation;User=$user;UserDn=$userDn;UserGuid=$userGuid;Computer=$pc;ComputerDn=$pcDn;ComputerGuid=$pcGuid;DN=$DN;Guid=$Guid;TargetType=$TargetType;Source=$Source;Job='';SourceIdentity=(Get-DomeniaRelationsSubjectIdentity);TargetIdentity=(Get-DomeniaRelationsTargetIdentity $TargetType $Guid $DN)}
    $script:Relations.SubjectNotice=''
    Refresh-DomeniaRelationViews
}
function Request-DomeniaRelationManualAssociation {
    $g=Get-DomeniaControl 'DgRelationComputerSearch';$row=if($null -ne $g){$g.SelectedItem}else{$null}
    if($null -eq $row){return}
    $type=ConvertTo-DomeniaRelationType ([string]$row.Type);if(-not $type){$type='Machine'}
    Set-DomeniaRelationPendingAssociation -Computer ([string]$row.Name) -Login ([string]$row.Login) -DN ([string]$row.DN) -Guid ([string]$row.Guid) -Source 'Recherche AD manuelle' -TargetType $type
}
function Cancel-DomeniaRelationAssociation {
    if($null -ne $script:Relations){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
    if($null -ne $script:Relations -and $null -ne $script:Relations.PendingAssociation){$job=[string]$script:Relations.PendingAssociation.Job;if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Association annulée'}catch{}};$script:Relations.PendingAssociation=$null;Refresh-DomeniaRelationViews}
}
function Confirm-DomeniaRelationAssociation {
    $p=$script:Relations.PendingAssociation
    if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblRelationConfirm' 'Une écriture reste active ou à vérifier : confirmation reportée.');return}
    if($null -ne $p -and $p.Job){return}
    # D045: Confirm is only accepted from Pending; the refusal is shown in the page.
    if(-not (Step-DomeniaRelationsAssociation 'Confirm')){return}
    if($null -eq $p){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet);return}
    # D044: the subject captured when the target was picked and the target itself must still be the same objects.
    if(-not (Test-DomeniaRelationConfirmation $p.SourceIdentity (Get-DomeniaRelationsSubjectIdentity) $p.TargetIdentity $p.TargetIdentity)){
        Cancel-DomeniaRelationAssociation
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Le sujet, la session ou le compte de lecture a changé depuis le choix : association annulée, rien nʼest enregistré.');return
    }
    [void](Set-DomeniaControlText 'LblRelationConfirm' ($p.User+' → '+$p.Computer+' · vérification de la cible dans Active Directory…'))
    $request=[guid]::NewGuid().ToString('N')
    $state=[pscustomobject]@{RequestId=$request;Epoch=$p.Epoch;BaseDn=[string]$script:Conn.BaseDn;Generation=$p.Generation;Pending=$p}
    $payload=[pscustomobject]@{Kind=[string]$p.TargetType;Term='';Verify=$true;RequestId=$request;DN=$p.DN;Guid=$p.Guid}
    $p.Job=Start-UiTask -Name 'Vérification de l association' -OperationId 'EmbeddedDirectoryLookup' -Code (Get-DomeniaEmbeddedLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'relations:verify-association' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaRelationAssociationVerify' -ErrorHandler 'Fail-DomeniaRelationAssociationVerify'
    Update-DomeniaRelationsActions
}
function Complete-DomeniaRelationAssociationVerify {
    param($Result,$State)
    $p=$State.Pending;$s=Get-DomeniaRelationsSubject
    if($null -eq $p -or -not [object]::ReferenceEquals($script:Relations.PendingAssociation,$p) -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $script:Relations.Generation -or $null -eq $s){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Verified')
    if($null -eq $data -or -not [bool]$data.Verified -or @($data.Rows).Count -ne 1){Fail-DomeniaRelationAssociationVerify 'La cible nʼa pas pu être revérifiée.' $State;return}
    $row=@($data.Rows)[0]
    $actual=Get-DomeniaRelationsTargetIdentity ([string]$row.Type) ([string]$row.Guid) ([string]$row.DN)
    if($row.DN -ine $p.DN -or -not (Test-DomeniaRelationConfirmation $p.SourceIdentity (Get-DomeniaRelationsSubjectIdentity) $p.TargetIdentity $actual)){Fail-DomeniaRelationAssociationVerify 'La cible ou le sujet a changé depuis la sélection. Relancez la recherche.' $State;return}
    if(-not (Step-DomeniaRelationsAssociation 'Verified')){return}
    $p.Job=''
    $added=Add-UserMachineLinkIfMissing -UserLogin $p.User -Computer $p.Computer -Source 'Saisie manuelle' -Details ('Association confirmée dans Relations depuis '+$p.Source+'.') -Confidence 0 -VerifiedInAD $true -UserGuid ([string]$p.UserGuid) -ComputerGuid ([string]$p.ComputerGuid) -UserDn ([string]$p.UserDn) -ComputerDn ([string]$p.ComputerDn) -Declarant ([string]$script:Conn.BindUser)
    $outcome=$script:Relations.LastOutcome
    $script:Relations.PendingAssociation=$null
    $text=if($added){'Association enregistrée : '+$p.User+' → '+$p.Computer+' (Déclaré).'}elseif($null -ne $outcome -and [string]$outcome.Placement -eq 'Session'){'Association déclarée : '+$p.User+' → '+$p.Computer+'. '+[string]$outcome.Reason}elseif($null -ne $outcome -and $outcome.Action -eq 'Refresh'){'Association déjà déclarée : '+$p.User+' → '+$p.Computer+' ; date mise à jour.'}else{'Association non enregistrée : '+$(if($null -ne $outcome){[string]$outcome.Reason}else{'stockage local indisponible.'})}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' $text);Refresh-DomeniaRelationViews
}
function Fail-DomeniaRelationAssociationVerify {
    param($Message,$State)
    $p=$State.Pending;if($null -eq $p -or -not [object]::ReferenceEquals($script:Relations.PendingAssociation,$p)){return}
    $p.Job=''
    [void](Step-DomeniaRelationsAssociation 'VerifyFailed' -Quiet)
    [void](Set-DomeniaControlText 'LblRelationConfirm' ('Vérification impossible : '+[string]$Message+'. Aucune association enregistrée.'));Update-DomeniaRelationsActions
}

function Get-DomeniaLinkQualification {
    # D043/DS-17: how a stored user/workstation link is qualified wherever it is shown outside Relations (fiche, lists,
    # summaries): its label and the rule behind it, never a percentage (no reliability rate was ever measured).
    # CO-29: When is the local display of its date (« 08/10 09:15 »), the stored text when it cannot be read.
    param($Link)
    if($null -eq $Link){return [pscustomobject]@{Value='';Suffix='';Rule='';Label='Qualification';When=''}}
    $badge=Get-DomeniaEvidenceBadge $Link
    $stored=[string](Get-DomeniaMember $Link 'When' '');$when=Format-DomeniaRelationWhen $stored;if(-not $when){$when=$stored}
    return [pscustomobject]@{Value=[string]$badge.Label;Suffix=('  '+[string]$badge.Label);Rule=[string]$badge.Rule;Label='Qualification';When=$when}
}
function Select-DomeniaBestLink {
    # The link shown first for a user: a declared assignment, otherwise the most recent relation (D042/D043).
    param([object[]]$Links=@())
    $items=@($Links|Where-Object{$null -ne $_})
    if(-not $items.Count){return $null}
    return (Select-DomeniaPrimaryRelation $items)
}
# ---------------------------------------------------------------- FO-14 open the fiche from Toutes les associations
function Get-DomeniaGridHit {
    # The DataGrid cell and row that contain a clicked element (visual tree, then logical tree for text runs).
    param($Source)
    $node=$Source;$cell=$null
    for($i=0;$i -lt 64 -and $null -ne $node;$i++){
        if($null -eq $cell -and $node -is [Windows.Controls.DataGridCell]){$cell=$node}
        if($node -is [Windows.Controls.DataGridRow]){return [pscustomobject]@{Cell=$cell;Row=$node}}
        $parent=$null
        if($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]){$parent=[Windows.Media.VisualTreeHelper]::GetParent($node)}
        if($null -eq $parent -and $node -is [Windows.DependencyObject]){$parent=[Windows.LogicalTreeHelper]::GetParent($node)}
        $node=$parent
    }
    return $null
}
function Open-DomeniaRelationEnd {
    # FO-14: opens the fiche of the user or of the workstation of an association (explicit gesture). The DN kept with
    # the association is opened directly; an association without DN is looked up by its name.
    param($Relation,[ValidateSet('User','Computer')][string]$End)
    if($null -eq $Relation){return}
    if($End -eq 'User'){$dn=[string](Get-DomeniaMember $Relation 'UserDn' '');$type='Utilisateur';$name=[string](Get-DomeniaMember $Relation 'UserLogin' '')}
    else{$dn=[string](Get-DomeniaMember $Relation 'ComputerDn' '');$type='Machine';$name=[string](Get-DomeniaMember $Relation 'Computer' '')}
    if($dn){Open-AdObject -Dn $dn -Type $type;return}
    if($name){Start-OpenLinkedObject -Type $type -Identity $name}
}
function Open-DomeniaAllLinksCell {
    # FO-14: a double click opens the fiche of the column clicked, user or workstation; elsewhere it says how.
    param($Source)
    $hit=Get-DomeniaGridHit $Source
    if($null -eq $hit -or $null -eq $hit.Row -or $null -eq $hit.Row.Item){return}
    $end=''
    if($null -ne $hit.Cell -and $null -ne $hit.Cell.Column){
        $path=[string]$hit.Cell.Column.SortMemberPath
        if($path -eq 'UserLogin'){$end='User'}elseif($path -eq 'Computer'){$end='Computer'}
    }
    if(-not $end){Set-Status 'Double-cliquez sur lʼutilisateur ou sur le poste pour ouvrir sa fiche ; le clic droit propose les deux.' 'INFO';return}
    Open-DomeniaRelationEnd -Relation $hit.Row.Item -End $end
}
function New-DomeniaAllLinksContextMenu {
    # FO-14: « Ouvrir lʼutilisateur » / « Ouvrir le poste » for the selected association.
    $menu=New-Object System.Windows.Controls.ContextMenu
    foreach($pair in @(@('Ouvrir lʼutilisateur','User'),@('Ouvrir le poste','Computer'))){
        $item=New-Object System.Windows.Controls.MenuItem
        $item.Header=$pair[0];$item.Tag=$pair[1]
        $item.Add_Click({param($sender,$e) $grid=Get-DomeniaControl 'DgAllLinks';if($null -ne $grid -and $null -ne $grid.SelectedItem){Open-DomeniaRelationEnd -Relation $grid.SelectedItem -End ([string]$sender.Tag)}})
        [void]$menu.Items.Add($item)
    }
    $menu.Add_Opened({param($sender,$e) $grid=Get-DomeniaControl 'DgAllLinks';$has=($null -ne $grid -and $null -ne $grid.SelectedItem);foreach($i in @($sender.Items)){$i.IsEnabled=$has}})
    return $menu
}

# ---------------------------------------------------------------- CO-08 CSV import: preview, forced source, undo
function New-DomeniaLinkImportPlan {
    # CO-08, points 137-138: every record of the file in a preview (valid, conflict, reject, duplicate, already known,
    # unknown in the local index, deferred). Nothing is written, nothing is read on the network. -Index is the answer of
    # the local index (LocalIndexRead, ResolveNames: State Verified, Empty or Unavailable, Users by login, Computers by
    # name), or $null while it is being read: the presence in Active Directory is then not checked and the preview says
    # why. -Items are inventory records (Domenia-InventoryImport.Model.ps1) or raw CSV rows, read as the generic CSV.
    # -Adapter imposes the provenance; -BatchId names the rollback batch written in the details of each association.
    param([object[]]$Items=@(),[string]$FileName='',$Index=$null,[string]$Id='',[int]$Total=-1,[ValidateSet('Csv','Glpi','Osquery')][string]$Adapter='Csv',[string]$BatchId='',[string]$ParseNote='')
    $adapterInfo=Get-DomeniaInventoryAdapter $Adapter
    $state=if($null -ne $Index){[string]$Index.State}else{'Pending'}
    $indexAvailable=($state -eq 'Verified')
    $unverified=switch($state){'Pending'{'vérification dans lʼindex local en cours'}'Empty'{'index local vide'}'Unavailable'{[string]$Index.Detail}default{''}}
    $users=@{};$computers=@{};if($indexAvailable){$users=$Index.Users;$computers=$Index.Computers}
    if(-not $Id){$Id=[guid]::NewGuid().ToString('N')}
    if(-not $BatchId){$BatchId=New-DomeniaImportBatchId -Id $Id}
    $domainDns=[string](Get-DomeniaMember $script:Conn 'Domain' '');$netbios=[string](Get-DomeniaMember $script:Conn 'Netbios' '')
    # Identity, normalisation and date of every record first: the source priority of the file needs all of them.
    $records=[Collections.Generic.List[object]]::new();$number=0
    foreach($item in @($Items)){
        # Import-Csv skips blank lines and joins quoted multi-line fields: rows are numbered by record, not by line.
        $number++
        if(($null -ne $item) -and ($null -ne $item.PSObject.Properties['InventoryAdapter'])){$records.Add($item)}else{$records.Add((ConvertFrom-DomeniaCsvInventoryRow $item $number))}
    }
    $prepared=[Collections.Generic.List[object]]::new()
    foreach($rec in $records){
        $reject=[string]$rec.Reject
        if(-not $reject){$reject=[string](Test-DomeniaInventoryIdentity -User ([string]$rec.User) -Computer ([string]$rec.Computer) -DomainDns $domainDns -Netbios $netbios).Reject}
        $user='';$computer=''
        if(-not $reject){$user=Normalize-LinkUser ([string]$rec.User);$computer=Normalize-LinkComputer ([string]$rec.Computer)}
        $when=ConvertTo-DomeniaInventoryWhen -Value ([string]$rec.When) -UnixTime ([bool]$rec.UnixTime)
        $both=(($user) -and ($computer))
        $prepared.Add([pscustomobject]@{Item=$rec;User=$user;Computer=$computer;Reject=$reject;When=$when;Record=[int]$rec.Record;ComputerKey=$(if($both){ConvertTo-DomeniaRelationComputerKey $computer}else{''});UserKey=$(if($both){ConvertTo-DomeniaRelationLoginKey $user}else{''});Ticks=[long]$when.Ticks})
    }
    $decisions=Resolve-DomeniaInventoryPriority -Items $prepared.ToArray()
    $rows=[Collections.Generic.List[object]]::new();$ready=0
    for($i=0;$i -lt $prepared.Count;$i++){
        $entry=$prepared[$i];$rec=$entry.Item;$user=$entry.User;$computer=$entry.Computer;$decision=$decisions[$i]
        $stored='';$userRow=$null;$computerRow=$null
        if($user -and $computer){
            $existing=@(Get-LinksForComputer $computer|Where-Object{$null -ne $_}|Select-Object -First 1)
            if($existing.Count){$stored=[string]$existing[0].UserLogin}
            if($indexAvailable){$userRow=$users[$user.ToLowerInvariant()];$computerRow=$computers[$computer]}
        }
        $conflict=if([string]$decision.Kind -eq 'Conflit'){[string]$decision.Reason}else{''}
        $superseded=if([string]$decision.Kind -in @('Doublon','Remplacée')){[string]$decision.Reason}else{''}
        $status=Get-DomeniaLinkImportStatus -User $user -Computer $computer -StoredLogin $stored -IndexAvailable $indexAvailable -UserKnown ($null -ne $userRow) -ComputerKnown ($null -ne $computerRow) -Unverified $unverified -ReadyBefore $ready -Rejected ([string]$entry.Reject) -FileConflict $conflict -FileSuperseded $superseded
        $relation=$null
        if($status.Import){
            $ready++
            $relation=New-DomeniaImportedRelation -User $user -Computer $computer -FileName $FileName -Line ([int]$rec.Record) -FileSource ([string]$rec.FileSource) -FileDetails ([string]$rec.Details) -When ([string]$entry.When.Text) -WhenNote ([string]$entry.When.Note) -Verified ([bool]$status.Verified) -UserGuid $(if($null -ne $userRow){[string]$userRow.Guid}else{''}) -ComputerGuid $(if($null -ne $computerRow){[string]$computerRow.Guid}else{''}) -UserDn $(if($null -ne $userRow){[string]$userRow.DN}else{''}) -ComputerDn $(if($null -ne $computerRow){[string]$computerRow.DN}else{''}) -Source ([string]$adapterInfo.Source) -BatchId $BatchId
        }
        $rows.Add([pscustomobject]@{Record=[int]$rec.Record;User=$(if($user){$user}else{[string]$rec.User});Computer=$(if($computer){$computer}else{[string]$rec.Computer});UserKey=$user;ComputerKey=$computer;Status=[string]$status.Status;Category=[string]$status.Category;Reason=[string]$status.Reason;Import=[bool]$status.Import;Relation=$relation})
    }
    $all=$rows.ToArray()
    if($Total -lt $all.Count){$Total=$all.Count}
    $count={param($Category) @($all|Where-Object{[string]$_.Category -ceq $Category}).Count}
    return [pscustomobject]@{Id=$Id;BatchId=$BatchId;Adapter=$Adapter;AdapterLabel=[string]$adapterInfo.Label;Source=[string]$adapterInfo.Source;ParseNote=$ParseNote;FileName=$FileName;Items=$records.ToArray();Rows=$all;Total=$Total;Ready=$ready;Unknown=@($all|Where-Object{$_.Status -eq 'Inconnue'}).Count;Ignored=@($all|Where-Object{(-not $_.Import) -and ($_.Status -ne 'Inconnue')}).Count;Conflicts=(& $count 'Conflit');Rejected=(& $count 'Rejet');Duplicates=(& $count 'Doublon');Known=(& $count 'Déjà connue');Deferred=(& $count 'Reportée');IndexAvailable=$indexAvailable;IndexState=$state;Unverified=$unverified;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn}
}
function Update-DomeniaLinkImportUi {
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$p=$r.ImportPlan
    $panel=Get-DomeniaControl 'LinkImportPanel';if($null -ne $panel){$panel.Visibility=if($null -ne $p){'Visible'}else{'Collapsed'}}
    if($null -ne $p){
        # Point 138: valid rows, conflicts and rejects are counted before anything is applied.
        $label=[string](Get-DomeniaMember $p 'AdapterLabel' 'CSV générique')
        $text=[string]$p.FileName+' ('+$label+') : '+$p.Ready+' ligne(s) à importer, '+[int](Get-DomeniaMember $p 'Conflicts' 0)+' conflit(s), '+[int](Get-DomeniaMember $p 'Rejected' 0)+' rejet(s), '+[int](Get-DomeniaMember $p 'Duplicates' 0)+' doublon(s), '+[int](Get-DomeniaMember $p 'Known' 0)+' déjà connue(s), '+$p.Unknown+' inconnue(s) dans lʼindex local de lʼannuaire.'
        $deferred=[int](Get-DomeniaMember $p 'Deferred' 0);if($deferred -gt 0){$text+=' '+$deferred+' reportée(s) au-delà de 64.'}
        $note=[string](Get-DomeniaMember $p 'ParseNote' '');if($note){$text+=' '+$note}
        if([int]$p.Total -gt @($p.Rows).Count){$text+=' Aperçu limité aux '+@($p.Rows).Count+' premiers enregistrements sur '+$p.Total+'.'}
        switch([string]$p.IndexState){
            'Pending'{$text+=' Vérification des comptes et des postes dans lʼindex local en cours, sans accès réseau…'}
            'Verified'{$text+=' Comptes et postes vérifiés dans lʼindex local, sans accès réseau.'}
            default{$text+=' Présence des comptes et des postes dans Active Directory non vérifiée : '+[string]$p.Unverified+'.'}
        }
        if([int]$p.Ready -ge 64){$text+=' 64 associations au plus par import : importez à nouveau le même fichier pour les suivantes.'}
        $source=[string](Get-DomeniaMember $p 'Source' 'Import CSV')
        $text+=' Les lignes importées portent la source « '+$source+' » (Importé), quelle que soit la colonne Source du fichier ; aucun poste déjà associé nʼest remplacé. Dans le fichier, la date la plus récente départage un poste ; sans date pour départager deux comptes, la ligne est en conflit.'
        $batch=[string](Get-DomeniaMember $p 'BatchId' '');if($batch){$text+=' Lot de retour arrière : '+$batch+'.'}
        # FI-13: the saved import is preceded by a verified backup of the local base.
        $text+=' '+(Get-DomeniaGestureBackupNotice (Get-DomeniaGestureBackupState))
        [void](Set-DomeniaControlText 'LblLinkImportSummary' $text)
        [void](Set-DomeniaItemsSource 'DgLinkImportPreview' @($p.Rows))
        $apply=Get-DomeniaControl 'BtnLinkImportApply'
        if($null -ne $apply){
            $pending=([string]$p.IndexState -eq 'Pending')
            $apply.IsEnabled=([int]$p.Ready -gt 0 -and -not $pending -and -not (Test-DomeniaAccessBusyWrite))
            $apply.Content=if($pending){'Vérification…'}else{'Importer '+$p.Ready+' association(s)'}
        }
    }else{[void](Set-DomeniaItemsSource 'DgLinkImportPreview' @())}
    Update-DomeniaLinkImportUndo
}
function Get-DomeniaRelationsLatestImportBatch {
    # Point 138: the most recent rollback batch still present in the stored associations (survives a restart).
    $batches=@(Get-DomeniaImportBatches -Links @($script:UserMachineLinks))
    if($batches.Count){return $batches[0]}
    return $null
}
function Update-DomeniaLinkImportUndo {
    # « Annuler lʼimport » targets the import of this session, otherwise the last batch found in the local store.
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    $undo=Get-DomeniaControl 'BtnUndoImport'
    if($null -eq $undo){return}
    $target=$r.LastImport
    if($null -eq $target){$target=Get-DomeniaRelationsLatestImportBatch}
    $undo.Visibility=if($null -ne $target){'Visible'}else{'Collapsed'}
    if($null -ne $target){
        $when=Format-DomeniaRelationWhen ([string](Get-DomeniaMember $target 'ImportedUtc' (Get-DomeniaMember $target 'WhenUtc' '')))
        $undo.ToolTip=('Retire les '+@($target.Relations).Count+' association(s) importée(s) depuis '+[string]$target.FileName+$(if($when){' le '+$when}else{''})+', après confirmation dans la page. Chaque retrait est journalisé et restaurable ; Active Directory nʼest pas modifié.')
    }
}
function Set-DomeniaLinkImportPlan {
    param($Plan)
    Initialize-DomeniaRelationsState
    $script:Relations.ImportPlan=$Plan
    Update-DomeniaLinkImportUi
}
function Show-DomeniaLinkImportPreview {
    # CO-08, point 137: the file is read with the adapter chosen by the operator and shown in the page before any change.
    # Nothing is saved until « Importer ». The accounts and workstations are then looked up in the local index by the
    # LocalIndexRead worker (no network). The file is read on this thread, so its size is bounded first.
    param([Parameter(Mandatory=$true)][string]$Path,[ValidateSet('Csv','Glpi','Osquery')][string]$Adapter='Csv')
    Initialize-DomeniaRelationsState
    $limits=Get-DomeniaInventoryLimits
    $adapterInfo=Get-DomeniaInventoryAdapter $Adapter
    $maxBytes=if($Adapter -eq 'Osquery'){[long]$limits.MaxJsonBytes}else{[long]$limits.MaxCsvBytes}
    $length=([IO.FileInfo]::new($Path)).Length
    if($length -gt $maxBytes){throw ('fichier trop volumineux pour un aperçu '+[string]$adapterInfo.Label+' : '+$length+' octets, limite '+$maxBytes+' octets ('+[Math]::Round($maxBytes/1MB,1)+' Mio). Découpez le fichier ou filtrez lʼexport.')}
    $notes=[Collections.Generic.List[string]]::new()
    $records=@();$total=0
    if($Adapter -eq 'Osquery'){
        $parsed=ConvertFrom-DomeniaOsqueryText -Text ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)) -MaxRecords ([int]$limits.MaxRecords)
        if(-not [string]$parsed.Format){throw 'fichier osquery vide.'}
        $latest=Select-DomeniaLatestInventoryRecords -Records @($parsed.Records)
        $records=@($latest.Records);$total=$records.Count
        if(@($parsed.Rejected).Count){$notes.Add([string]@($parsed.Rejected).Count+' ligne(s) JSON illisible(s) écartée(s).')}
        if([int]$parsed.Skipped -gt 0){$notes.Add([string]$parsed.Skipped+' fin(s) de session ou session(s) sans compte ignorée(s).')}
        if([int]$latest.Dropped -gt 0){$notes.Add([string]$latest.Dropped+' relevé(s) plus ancien(s) des mêmes postes écarté(s) : la date la plus récente départage.')}
        if([bool]$parsed.Truncated){$notes.Add('Lecture arrêtée à '+$limits.MaxRecords+' enregistrements.')}
    }else{
        # CO-04: Domenia exports use a semicolon; older exports and other tools keep the comma (GLPI uses the semicolon).
        $rows=@(Import-Csv -LiteralPath $Path -Encoding UTF8 -Delimiter (Get-DomeniaCsvDelimiter -Path $Path))
        $total=$rows.Count
        # At most 64 rows are imported at once; the preview stays short enough for the interface thread.
        $shown=[Math]::Min($rows.Count,[int]$limits.PreviewRecords)
        $records=@(for($i=0;$i -lt $shown;$i++){if($Adapter -eq 'Glpi'){ConvertFrom-DomeniaGlpiRow $rows[$i] ($i+1)}else{ConvertFrom-DomeniaCsvInventoryRow $rows[$i] ($i+1)}})
    }
    $items=if($records.Count -gt [int]$limits.PreviewRecords){@($records[0..([int]$limits.PreviewRecords-1)])}else{$records}
    $plan=New-DomeniaLinkImportPlan -Items $items -FileName ([IO.Path]::GetFileName($Path)) -Total $total -Adapter $Adapter -ParseNote ($notes.ToArray() -join ' ')
    Set-DomeniaLinkImportPlan $plan
    Write-AppLog ([string]$plan.Source+' : aperçu de '+[string]$plan.FileName+', '+$plan.Total+' enregistrement(s), vérification dans lʼindex local demandée. Rien nʼest encore enregistré.') 'INFO'
    $tabs=Get-DomeniaControl 'RelationTabs';$all=Get-DomeniaControl 'TabLinksAll';if($null -ne $tabs -and $null -ne $all){$tabs.SelectedItem=$all}
    Start-DomeniaLinkImportIndexCheck $plan
    Set-Status ('Aperçu de lʼimport : '+$plan.Total+' enregistrement(s) lus. Vérification dans lʼindex local, puis « Importer » ou « Annuler ».')
}
function Get-DomeniaLinkImportAdapterChoice {
    # Point 137: the adapter is an explicit choice of the operator (Format de lʼimport), the generic CSV by default.
    $combo=Get-DomeniaControl 'CmbLinkImportFormat'
    $choice=''
    if(($null -ne $combo) -and ($null -ne $combo.SelectedItem)){$choice=[string](Get-DomeniaMember $combo.SelectedItem 'Tag' '')}
    if($null -eq (Get-DomeniaInventoryAdapter $choice)){$choice='Csv'}
    return $choice
}
function Start-DomeniaLinkImportIndexCheck {
    # CO-08: exact names of the file, looked up in the local index (read only, never the network). FI-12: the SQLite lock
    # wait is the one of the worker context (LocalStore.DatabaseBusyTimeoutMs): this preview is not retried by itself.
    param($Plan)
    if($null -eq $Plan){return}
    $users=[Collections.Generic.List[string]]::new();$computers=[Collections.Generic.List[string]]::new()
    $seenUsers=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$seenComputers=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($row in @($Plan.Rows)){
        if([string]$row.UserKey -and [string]$row.ComputerKey){
            if($seenUsers.Add([string]$row.UserKey)){$users.Add(([string]$row.UserKey).ToLowerInvariant())}
            if($seenComputers.Add([string]$row.ComputerKey)){$computers.Add([string]$row.ComputerKey)}
        }
    }
    $state=[pscustomobject]@{PlanId=[string]$Plan.Id;Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn}
    # No row names both an account and a workstation: nothing to look up, nothing can be imported.
    if(-not $users.Count){Set-DomeniaLinkImportPlan (New-DomeniaLinkImportPlan -Items @($Plan.Items) -FileName ([string]$Plan.FileName) -Adapter ([string]$Plan.Adapter) -BatchId ([string]$Plan.BatchId) -ParseNote ([string]$Plan.ParseNote) -Index ([pscustomobject]@{State='Verified';Detail='';Users=@{};Computers=@{}}) -Id ([string]$Plan.Id) -Total ([int]$Plan.Total));return}
    try{
        $payload=[pscustomobject]@{Action='ResolveNames';Path=(Get-DomeniaLocalDatabasePathForRead);Users=$users.ToArray();Computers=$computers.ToArray()}
        [void](Start-UiTask -Name ([string](Get-DomeniaMember $Plan 'Source' 'Import CSV')+' : vérification dans lʼindex local') -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'link-import-index' -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaLinkImportIndexCheck' -ErrorHandler 'Fail-DomeniaLinkImportIndexCheck' -TaskClass 'Explicit')
    }catch{Fail-DomeniaLinkImportIndexCheck -Message $_.Exception.Message -State $state}
}
function Test-DomeniaLinkImportIndexState {
    param($State)
    Initialize-DomeniaRelationsState
    $p=$script:Relations.ImportPlan
    return ($null -ne $p -and $null -ne $State -and [string]$State.PlanId -eq [string]$p.Id -and [long]$State.Epoch -eq [long]$script:SessionEpoch -and [string]$State.BaseDn -ieq [string]$script:Conn.BaseDn)
}
function Complete-DomeniaLinkImportIndexCheck {
    param($Result,$State)
    if(-not (Test-DomeniaLinkImportIndexState $State)){return}
    $p=$script:Relations.ImportPlan
    $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Busy')
    if($null -eq $effective){Fail-DomeniaLinkImportIndexCheck -Message 'réponse de lʼindex local illisible' -State $State;return}
    $index=$null
    if([bool]$effective.Busy){$index=[pscustomobject]@{State='Unavailable';Detail='base locale occupée, rouvrez lʼaperçu dans un instant pour la vérifier';Users=@{};Computers=@{}}}
    elseif([bool](Get-DomeniaMember $effective 'Missing' $false)){$index=[pscustomobject]@{State='Unavailable';Detail='base locale absente';Users=@{};Computers=@{}}}
    elseif([int](Get-DomeniaMember $effective 'IndexCount' 0) -le 0){$index=[pscustomobject]@{State='Empty';Detail='';Users=@{};Computers=@{}}}
    else{
        $users=@{};$computers=@{}
        foreach($u in @(Get-DomeniaMember $effective 'Users' @())){
            if($null -eq $u){continue}
            $login=Normalize-LinkUser ([string]$u.login)
            if($login){$users[$login.ToLowerInvariant()]=[pscustomobject]@{Guid=[string]$u.object_guid;DN=[string]$u.distinguished_name}}
        }
        foreach($c in @(Get-DomeniaMember $effective 'Computers' @())){
            if($null -eq $c){continue}
            $row=[pscustomobject]@{Guid=[string]$c.object_guid;DN=[string]$c.distinguished_name}
            foreach($name in @([string]$c.name,[string]$c.login)){$key=Normalize-LinkComputer $name;if($key){$computers[$key]=$row}}
        }
        $index=[pscustomobject]@{State='Verified';Detail='';Users=$users;Computers=$computers}
    }
    $plan=New-DomeniaLinkImportPlan -Items @($p.Items) -FileName ([string]$p.FileName) -Adapter ([string]$p.Adapter) -BatchId ([string]$p.BatchId) -ParseNote ([string]$p.ParseNote) -Index $index -Id ([string]$p.Id) -Total ([int]$p.Total)
    Set-DomeniaLinkImportPlan $plan
    Write-AppLog ([string](Get-DomeniaMember $plan 'Source' 'Import CSV')+' : '+[string]$plan.FileName+', '+$plan.Ready+' ligne(s) à importer, '+$plan.Ignored+' ignorée(s), '+$plan.Unknown+' inconnue(s) dans lʼindex local ('+[string]$plan.IndexState+'). Rien nʼest encore enregistré.') 'INFO'
}
function Fail-DomeniaLinkImportIndexCheck {
    param($Message,$State)
    if(-not (Test-DomeniaLinkImportIndexState $State)){return}
    $p=$script:Relations.ImportPlan
    $detail=([string]$Message).Trim();if(-not $detail){$detail='erreur inconnue'}
    Write-AppLog ([string](Get-DomeniaMember $p 'Source' 'Import CSV')+' : index local non lu ('+$detail+') ; présence dans Active Directory non vérifiée.') 'WARN'
    $index=[pscustomobject]@{State='Unavailable';Detail=('index local non lu ('+$detail.TrimEnd('.')+')');Users=@{};Computers=@{}}
    Set-DomeniaLinkImportPlan (New-DomeniaLinkImportPlan -Items @($p.Items) -FileName ([string]$p.FileName) -Adapter ([string]$p.Adapter) -BatchId ([string]$p.BatchId) -ParseNote ([string]$p.ParseNote) -Index $index -Id ([string]$p.Id) -Total ([int]$p.Total))
}
function Cancel-DomeniaLinkImportPreview {
    Initialize-DomeniaRelationsState
    if($null -eq $script:Relations.ImportPlan){Update-DomeniaLinkImportUi;return}
    $script:Relations.ImportPlan=$null
    Update-DomeniaLinkImportUi
    Set-Status 'Import abandonné : aucune association ajoutée.'
}
function Confirm-DomeniaLinkImport {
    # CO-08: the rows to import join the store through Add-DomeniaRelation (one journal line each), in one save.
    # FI-13: once the checks pass, a verified backup of the base (StorageBackup worker) comes first; the save runs from
    # its success callback (-BackupDone), which checks the preview again. Only the preview confirmed by the click
    # (-PlanId) is saved: another file previewed during the backup waits for its own « Importer ».
    param([switch]$BackupDone,[string]$PlanId='')
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$p=$r.ImportPlan
    if($null -eq $p){Update-DomeniaLinkImportUi;return}
    if($BackupDone -and ((-not $PlanId) -or ([string]$p.Id -cne $PlanId))){Set-Status 'Lʼaperçu a changé pendant la sauvegarde : rien nʼest importé. Vérifiez lʼaperçu affiché puis cliquez « Importer ».' 'WARN';return}
    if(Test-DomeniaAccessBusyWrite){return}
    if($p.Epoch -ne [long]$script:SessionEpoch -or [string]$p.BaseDn -ine [string]$script:Conn.BaseDn){$r.ImportPlan=$null;Update-DomeniaLinkImportUi;Set-Status 'Session ou domaine modifié depuis lʼaperçu : import abandonné, rien nʼest enregistré.' 'WARN';return}
    if([string]$p.IndexState -eq 'Pending'){Set-Status 'Vérification dans lʼindex local encore en cours : attendez la fin de lʼaperçu.' 'INFO';return}
    # A workstation associated since the preview is not replaced.
    $rows=@(@($p.Rows)|Where-Object{$_.Import -and $null -ne $_.Relation -and -not @(Get-LinksForComputer ([string]$_.Relation.Computer)|Where-Object{$null -ne $_}).Count})
    $why=Get-DomeniaRelationSaveRefusal -Changes $rows.Count
    if($why){Set-Status ('Import non enregistré : '+$why+'. Aucune association ajoutée ; lʼaperçu reste ouvert.') 'WARN';return}
    if(-not $BackupDone){
        # Closures capture the functions they call: a closure does not see the functions of the module scope.
        $confirm=${function:Confirm-DomeniaLinkImport};$confirmedPlan=[string]$p.Id
        [void](Invoke-DomeniaGestureBackup -Gesture 'LinkImport' -Then ({& $confirm -BackupDone -PlanId $confirmedPlan}.GetNewClosure()))
        return
    }
    $previous=@($script:UserMachineLinks);$previousObservations=$r.Observations.ToArray()
    $added=[Collections.Generic.List[object]]::new();$stored=$false
    foreach($row in $rows){
        $o=Add-DomeniaRelation -Relation $row.Relation -Declarant ([string]$script:Conn.BindUser) -NoSave
        if($o.Action -eq 'Add'){$added.Add($o.Relation);if($o.StoredChanged){$stored=$true}}
    }
    if($stored -and -not (Save-UserMachineLinks)){
        $script:UserMachineLinks=$previous;$r.Observations.Clear();foreach($o in $previousObservations){$r.Observations.Add($o)};Rebuild-UserMachineLinkIndex
        $text='Import non enregistré : le stockage local a refusé la modification (motif dans le message précédent). Aucune association ajoutée ; lʼaperçu reste ouvert.'
        Set-Status $text 'WARN';Write-AppLog ([string](Get-DomeniaMember $p 'Source' 'Import CSV')+' '+[string]$p.FileName+' : '+$text) 'WARN';Refresh-DomeniaRelationViews;return
    }
    $r.ImportPlan=$null
    $source=[string](Get-DomeniaMember $p 'Source' 'Import CSV')
    if($added.Count){$r.LastImport=[pscustomobject]@{Id=[string]$p.Id;BatchId=[string](Get-DomeniaMember $p 'BatchId' '');FileName=[string]$p.FileName;Relations=$added.ToArray();WhenUtc=[datetime]::UtcNow.ToString('o');Epoch=[long]$script:SessionEpoch}}
    $message=$source+' '+[string]$p.FileName+' : '+$added.Count+' association(s) ajoutée(s) avec la source « '+$source+' » (Importé)'
    $notDone=[int]$p.Total-$added.Count
    if($notDone -gt 0){$message+=', '+$notDone+' enregistrement(s) non importé(s)'}
    $message+='. Aucun objet Active Directory modifié.'
    if($added.Count){$message+=' « Annuler lʼimport » retire ces associations, y compris après un redémarrage (lot '+[string](Get-DomeniaMember $p 'BatchId' '')+').'}
    Set-Status $message;Write-AppLog $message 'INFO'
    Update-DomeniaLinkImportUi;Refresh-DomeniaRelationViews
}
function Request-DomeniaLinkImportUndo {
    # Review L04: removing up to 64 associations in one click is confirmed in the page first, naming the count.
    Initialize-DomeniaRelationsState
    $last=$script:Relations.LastImport
    if($null -eq $last){
        # Point 138: after a restart, the last batch still present in the local store is the one undone.
        $batch=Get-DomeniaRelationsLatestImportBatch
        if($null -ne $batch){$last=[pscustomobject]@{Id=[string]$batch.Id;BatchId=[string]$batch.Id;FileName=[string]$batch.FileName;Relations=@($batch.Relations);WhenUtc=[string]$batch.ImportedUtc;Epoch=[long]$script:SessionEpoch};$script:Relations.LastImport=$last}
    }
    if($null -eq $last){Update-DomeniaLinkImportUi;return}
    if(Test-DomeniaAccessBusyWrite){return}
    $n=@($last.Relations).Count
    $batchText=[string](Get-DomeniaMember $last 'BatchId' '');$whenText=Format-DomeniaRelationWhen ([string](Get-DomeniaMember $last 'WhenUtc' ''))
    $origin=[string]$last.FileName;if($batchText){$origin+=' (lot '+$batchText+$(if($whenText){', '+$whenText}else{''})+')'}
    $message='Retirer les '+$n+' association(s) ajoutée(s) par lʼimport de '+$origin+' ? Chaque retrait est journalisé ; « Restaurer » les remet une par une. Aucun objet Active Directory nʼest modifié.'
    $inline=Get-Command -Name 'Request-DomeniaInlineConfirmation' -CommandType Function -ErrorAction SilentlyContinue
    if($null -ne $inline -and (Get-DomeniaFeatureFlag 'InlineConfirm' $true)){
        [void](Request-DomeniaInlineConfirmation -Title 'Annuler lʼimport' -Message $message -Target ('relation-import:'+[string]$last.Id) -ConfirmText ('Retirer '+$n+' association(s)') -CancelText 'Conserver' -OnConfirm {Undo-DomeniaLinkImport} -OnCancel {Set-Status 'Annulation de lʼimport abandonnée : associations conservées.'} -Risk 'Danger')
        return
    }
    if(Confirm-Action $message){Undo-DomeniaLinkImport}else{Set-Status 'Annulation de lʼimport abandonnée : associations conservées.'}
}
function Undo-DomeniaLinkImport {
    # CO-08: removes the associations added by the last import, if still present. Each removal is journaled and restorable.
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$last=$r.LastImport
    if($null -eq $last){Update-DomeniaLinkImportUi;return}
    if(Test-DomeniaAccessBusyWrite){return}
    $targets=@(@($last.Relations)|Where-Object{$null -ne $_})
    $notes=@($targets|ForEach-Object{'Import '+[string]$last.FileName+' annulé.'})
    $n=Remove-DomeniaRelations -Relations $targets -Declarant ([string]$script:Conn.BindUser) -Notes $notes
    if($n -lt 0){Set-Status (Get-DomeniaRelationRefusalText 'Annulation de lʼimport non enregistrée' 'Associations conservées ; « Annuler lʼimport » reste disponible.') 'WARN';return}
    $r.LastImport=$null
    $message='Import '+[string]$last.FileName+' annulé : '+$n+' association(s) importée(s) retirée(s) localement'
    if($n -lt $targets.Count){$message+=' ; '+($targets.Count-$n)+' déjà retirée(s) ou modifiée(s) depuis'}
    $message+='. Chaque retrait est journalisé ; « Restaurer » (onglets Associations et Toutes les associations) les remet une par une. Active Directory nʼest pas modifié.'
    Set-Status $message;Write-AppLog $message 'INFO'
    Update-DomeniaLinkImportUi;Update-DomeniaRelationsActions
}

# ---------------------------------------------------------------- UX-40 orphan associations, listed and restorable
function Update-DomeniaOrphanUi {
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$rows=@($r.Orphans)
    $panel=Get-DomeniaControl 'LinkOrphanPanel';if($null -ne $panel){$panel.Visibility=if($rows.Count){'Visible'}else{'Collapsed'}}
    [void](Set-DomeniaItemsSource 'DgLinkOrphans' $rows)
    $text=[string]$rows.Count+' association(s) orpheline(s) : le compte ou le poste nʼest plus trouvé dans Active Directory. Les associations déclarées et importées ne sont jamais proposées ; rien nʼest retiré sans confirmation.'
    # Review L04: the storage takes 64 changes per request.
    if($rows.Count -gt 64){$text+=' 64 au plus par retrait : les premières sont cochées ; retirez-les, puis les suivantes.'}
    [void](Set-DomeniaControlText 'LblLinkOrphanSummary' $text)
    $confirm=Get-DomeniaControl 'LinkOrphanConfirm';if($null -ne $confirm){$confirm.Visibility=if($r.OrphanConfirm){'Visible'}else{'Collapsed'}}
    $remove=Get-DomeniaControl 'BtnLinkOrphanRemove';if($null -ne $remove){$remove.IsEnabled=($rows.Count -gt 0 -and -not $r.OrphanConfirm -and -not (Test-DomeniaAccessBusyWrite))}
}
function Select-DomeniaOrphanBatch {
    # The first 64 rows are checked (one storage request); the others wait for the next removal.
    Initialize-DomeniaRelationsState
    $i=0;foreach($row in @($script:Relations.Orphans)){$row.Selected=($i -lt 64);$i++}
}
function Show-DomeniaOrphanLinks {
    # UX-40: result of the read-only check (PruneLinks), listed in the page with a reason and a box per row.
    # Nothing is removed here. Declared and imported associations are never proposed.
    param($Result)
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    $byKey=@{}
    foreach($l in @($script:UserMachineLinks)){if($null -eq $l -or (Test-DomeniaProtectedAssociationSource ([string]$l.Source))){continue};$byKey[([string]$l.UserLogin+'|'+[string]$l.Computer+'|'+[string]$l.When)]=$l}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($o in @(Get-DomeniaMember $Result 'Rows' @())){
        if($null -eq $o -or ([bool]$o.UserExists -and [bool]$o.ComputerExists)){continue}
        $key=[string]$o.UserLogin+'|'+[string]$o.Computer+'|'+[string]$o.When
        if(-not $byKey.ContainsKey($key)){continue}
        $link=$byKey[$key];$utc=ConvertTo-DomeniaRelationUtcDate ([string]$link.When)
        $rows.Add([pscustomobject]@{Selected=$false;UserLogin=[string]$link.UserLogin;Computer=[string]$link.Computer;Source=[string]$link.Source;Reason=(Get-DomeniaOrphanReason ([bool]$o.UserExists) ([bool]$o.ComputerExists));WhenDisplay=(Format-DomeniaRelationWhen $utc);WhenSort=$(if($null -ne $utc){$utc}else{[datetime]::MinValue});Relation=$link})
    }
    $r.Orphans=$rows.ToArray();$r.OrphanConfirm=$false;Select-DomeniaOrphanBatch
    $checked=[int](Get-DomeniaMember $Result 'Checked' 0)
    if(-not $rows.Count){Update-DomeniaOrphanUi;Set-Status ([string]$checked+' association(s) vérifiée(s) dans Active Directory : aucune orpheline. Associations déclarées et importées non concernées.');return}
    $tabs=Get-DomeniaControl 'RelationTabs';$all=Get-DomeniaControl 'TabLinksAll';if($null -ne $tabs -and $null -ne $all){$tabs.SelectedItem=$all}
    Update-DomeniaOrphanUi
    $message=[string]$rows.Count+' association(s) orpheline(s) sur '+$checked+' vérifiée(s) : cochez celles à retirer du stockage local.'
    if($rows.Count -gt 64){$message+=' Les 64 premières sont cochées (64 au plus par retrait).'}
    Set-Status $message;Write-AppLog $message 'INFO'
}
function Request-DomeniaOrphanRemoval {
    # UX-40: the removal is confirmed in the panel itself (no window).
    Initialize-DomeniaRelationsState
    $r=$script:Relations;$selected=@(@($r.Orphans)|Where-Object{[bool]$_.Selected})
    if(-not $selected.Count){Set-Status 'Cochez au moins une association orpheline à retirer.' 'INFO';return}
    # Review L04: checked before the confirmation, so that a confirmed removal is never refused by the storage.
    $why=Get-DomeniaRelationSaveRefusal -Changes $selected.Count
    if($why){Set-Status ('Retrait impossible pour lʼinstant : '+$why+'. Décochez des lignes ou réessayez ; rien nʼest retiré.') 'INFO';return}
    $r.OrphanConfirm=$true
    [void](Set-DomeniaControlText 'LblLinkOrphanConfirm' ('Retirer '+$selected.Count+' association(s) du stockage local ? Chaque retrait est journalisé et restaurable avec « Restaurer » ; aucun objet Active Directory nʼest modifié. '+(Get-DomeniaGestureBackupNotice (Get-DomeniaGestureBackupState))))
    Update-DomeniaOrphanUi
}
function Cancel-DomeniaOrphanRemoval {
    Initialize-DomeniaRelationsState
    $script:Relations.OrphanConfirm=$false
    Update-DomeniaOrphanUi
    Set-Status 'Retrait annulé : aucune association modifiée.'
}
function Complete-DomeniaOrphanRemoval {
    # UX-40: removal through Remove-DomeniaRelations: journaled with its reason, restorable one by one.
    # FI-13: a verified backup of the base comes first; the removal runs from its success callback (-BackupDone), and
    # only while the confirmation is still open (« Annuler » during the backup removes nothing). Exactly the rows checked
    # at the click (-Keys) are removed: a box changed during the backup changes nothing.
    param([switch]$BackupDone,[string[]]$Keys=@())
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    if(-not $r.OrphanConfirm){Update-DomeniaOrphanUi;return}
    if(Test-DomeniaAccessBusyWrite){return}
    if(-not $BackupDone){
        $chosen=@(@($r.Orphans)|Where-Object{[bool]$_.Selected}|ForEach-Object{[string]$_.Relation.UserLogin+'|'+[string]$_.Relation.Computer+'|'+[string]$_.Relation.When})
        if(-not $chosen.Count){Set-Status 'Cochez au moins une association orpheline à retirer.' 'INFO';return}
        # Closures capture the functions they call: a closure does not see the functions of the module scope.
        $complete=${function:Complete-DomeniaOrphanRemoval}
        [void](Invoke-DomeniaGestureBackup -Gesture 'LinkPrune' -Then ({& $complete -BackupDone -Keys $chosen}.GetNewClosure()))
        return
    }
    $r.OrphanConfirm=$false
    $confirmed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($key in @($Keys)){if([string]$key){[void]$confirmed.Add([string]$key)}}
    $targets=[Collections.Generic.List[object]]::new();$notes=[Collections.Generic.List[string]]::new();$kept=0
    foreach($row in @(@($r.Orphans)|Where-Object{$confirmed.Contains(([string]$_.Relation.UserLogin+'|'+[string]$_.Relation.Computer+'|'+[string]$_.Relation.When))})){
        $found=Find-DomeniaRelationInstance $row.Relation
        # A source declared or imported after the check is never removed.
        if($null -eq $found -or (Test-DomeniaProtectedAssociationSource ([string]$found.Item.Source))){$kept++;continue}
        $targets.Add($found.Item);$notes.Add(('Orpheline : '+[string]$row.Reason))
    }
    $n=0;if($targets.Count){$n=Remove-DomeniaRelations -Relations $targets.ToArray() -Declarant ([string]$script:Conn.BindUser) -Notes $notes.ToArray()}
    if($n -lt 0){Update-DomeniaOrphanUi;Set-Status (Get-DomeniaRelationRefusalText 'Retrait non enregistré' 'Associations conservées ; la liste reste ouverte.') 'WARN';return}
    $r.Orphans=@(@($r.Orphans)|Where-Object{-not $confirmed.Contains(([string]$_.Relation.UserLogin+'|'+[string]$_.Relation.Computer+'|'+[string]$_.Relation.When))});Select-DomeniaOrphanBatch
    $message=[string]$n+' association(s) orpheline(s) retirée(s) du stockage local. Chaque retrait est journalisé et restaurable ; Active Directory nʼest pas modifié.'
    if($kept){$message+=' '+$kept+' conservée(s) : déjà retirée(s), ou devenue(s) déclarée(s) ou importée(s).'}
    if(@($r.Orphans).Count){$message+=' '+@($r.Orphans).Count+' restante(s) dans la liste, les suivantes sont cochées.'}
    Set-Status $message;Write-AppLog $message 'INFO'
    Update-DomeniaOrphanUi;Update-DomeniaRelationsActions
}
function Close-DomeniaOrphanLinks {
    Initialize-DomeniaRelationsState
    $script:Relations.Orphans=@();$script:Relations.OrphanConfirm=$false
    Update-DomeniaOrphanUi
}

function Get-DomeniaRelationsWorkerCode {
return @'
# Read-only inverse lookup. The exact user and the two credential channels stay separate.
$clock=[Diagnostics.Stopwatch]::StartNew()
$attempts=[Collections.Generic.List[object]]::new()
$items=@{};$eventHints=[Collections.Generic.List[object]]::new()
$partial=$false;$directoryReads=0;$probed=0;$matched=0;$denied=0;$remoteStopped=$false;$script:RelationDirectoryBlocked=$false
$probedGuids=[Collections.Generic.List[string]]::new()
# D047: when the operator confirmed a list, only those AD objects (by GUID) may be probed.
$loadedTargets=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if($null -ne $Payload.PSObject.Properties['LoadedTargets']){foreach($t in @($Payload.LoadedTargets)){if($t){[void]$loadedTargets.Add([string]$t)}}}
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
    return [pscustomobject]@{Login=$login;UserDn=$userDn;UserGuid=$userGuid;RequestId=$Payload.RequestId;Candidates=@();Hints=@();Attempts=$attempts.ToArray();Success=$false;Partial=$true;Scanned=$false;ScanStats=[pscustomobject]@{Candidates=0;Reachable=0;Probed=0};ProbedGuids=@();DurationMs=[long]$clock.ElapsedMilliseconds;DirectoryReads=$directoryReads}
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
                    $g=Convert-WGuid $rows[0].objectguid
                    if($loadedTargets.Count -gt 0 -and (-not $g -or -not $loadedTargets.Contains($g))){Add-RelationAttempt 'Liste chargée' 'A_REVOIR' ([string]$n) 'Objet AD résolu différent de celui confirmé (GUID) : poste non sondé.';continue}
                    Add-RelationComputer $rows[0] 'Liste chargée' 'Cible de vérification choisie explicitement.' 'À vérifier'
                    if($g -and $items.ContainsKey($g.ToLowerInvariant())){[void]$probeKeys.Add($g.ToLowerInvariant())}
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
            $probed++;$probedGuids.Add([string]$c.Guid);$session=$null;$target=if($c.Dns){$c.Dns}else{$c.Computer}
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
[pscustomobject]@{Login=$login;UserDn=$userDn;UserGuid=$userGuid;RequestId=$Payload.RequestId;Candidates=@($items.Values|Sort-Object Computer);Hints=$eventHints.ToArray();Attempts=$attempts.ToArray();Success=$true;Partial=$partial;Scanned=[bool]$Payload.ScanPark;ScanStats=[pscustomobject]@{Candidates=$items.Count;Reachable=0;Probed=$probed;Matched=$matched;Denied=$denied};ProbedGuids=$probedGuids.ToArray();DurationMs=[long]$clock.ElapsedMilliseconds;DirectoryReads=$directoryReads}
'@
}
