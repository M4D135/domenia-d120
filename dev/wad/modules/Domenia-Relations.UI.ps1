# Definition-only module. Network work is started solely by an explicit search action.
# D041-D050: the relation rules of Domenia-Relations.Model.ps1 drive this page. Features.RelationsSymmetry
# (default on) switches the relation model (both directions, stable subject, in-page association states,
# upsert without replacement, journal); Features.DetectionPreview (default on) shows the perimeter before
# any workstation is contacted. Off, each switch restores the RC1.10.7 path.
$script:Relations=$null
function Initialize-DomeniaRelationsState {
    if($null -eq $script:Relations){
        $script:Relations=[pscustomobject]@{
            Epoch=[long]$script:SessionEpoch;Subject=$null;Generation=0L;Query=$null;Completed=@{};Timer=$null;Bound=$false;Rendering=$false;PendingConfirmed=$null
            ManualSearchJob='';ManualSearchRequest='';ManualSearchRows=@();PendingAssociation=$null
            AssociationState='Idle';PendingPlan=$null;PendingRemoval=$null;SubjectNotice='';LastOutcome=$null;Revision=0L
            Observations=[Collections.Generic.List[object]]::new();History=[Collections.Generic.List[object]]::new();JournalPresent=$null
            DirtyComputers=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
        $script:Relations.Observations.Clear();$script:Relations.History.Clear();$script:Relations.DirtyComputers.Clear();$script:Relations.JournalPresent=$null;$script:Relations.Revision++
    }
}
function Set-DomeniaRelationsSelection {
    param($Row,$Object)
    Initialize-DomeniaRelationsState
    if($script:SuppressGridSelectionEvents){return}
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
    $rowType=if($null -ne $Row){[string]$Row.Type}else{''};$objectType=if($null -ne $Object){[string]$Object.Type}else{''}
    if($model){$rowType=ConvertTo-DomeniaRelationType $rowType;$objectType=ConvertTo-DomeniaRelationType $objectType}
    $s=$null
    if($null -ne $Row -and $rowType -in @('Utilisateur','Machine')){
        $s=[pscustomobject]@{Type=$rowType;Login=[string]$Row.Login;Name=[string]$Row.Name;DN=[string]$Row.DN;Guid=[string]$Row.Guid}
    }elseif($null -ne $Object -and $objectType -in @('Utilisateur','Machine')){
        $s=[pscustomobject]@{Type=$objectType;Login=(Get-DomeniaEntryFirstString $Object.Entry 'sAMAccountName');Name=[string]$Object.Name;DN=[string]$Object.DN;Guid=[string]$Object.Safety.Guid}
    }
    if($null -eq $s -or -not $s.DN){return}
    if($null -ne $script:Relations.Subject -and $script:Relations.Subject.DN -ieq $s.DN -and $script:Relations.Subject.Guid -ieq $s.Guid){$script:Relations.Subject=$s;Refresh-DomeniaRelationViews;return}
    $r=$script:Relations
    $searching=(-not [string]::IsNullOrWhiteSpace([string]$r.ManualSearchJob))
    if($model -and $null -ne $r.Subject -and ($null -ne $r.PendingAssociation -or $searching)){
        # D044: while a target is searched or awaits confirmation, a global selection does not replace the source subject.
        $d=Resolve-DomeniaRelationSubjectChange -CurrentSubject $r.Subject -NewSelection $s -TargetSearchActive $searching -PendingAssociation ($null -ne $r.PendingAssociation)
        if(-not $d.Change){
            $label=if($r.Subject.Type -eq 'Utilisateur'){[string]$r.Subject.Login}else{[string]$r.Subject.Name}
            $r.SubjectNotice=([string]$d.Reason+' Sujet conservé : '+$label+'.')
            [void](Set-DomeniaControlText 'LblRelationAssociateHint' $r.SubjectNotice)
            return
        }
    }
    foreach($job in @([string]$r.ManualSearchJob,$(if($null -ne $r.Query){[string]$r.Query.Job}else{''}))){if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Sélection Relations modifiée'}catch{}}}
    if($null -ne $r.Timer){$r.Timer.Stop()}
    $r.Subject=$s;$r.Generation++;$r.Query=$null;$r.PendingConfirmed=$null;$r.PendingAssociation=$null
    $r.ManualSearchJob='';$r.ManualSearchRequest='';$r.ManualSearchRows=@()
    if($model){$r.AssociationState=[string](Step-DomeniaAssociationState ([string]$r.AssociationState) 'SubjectChanged').State;$r.PendingPlan=$null;$r.SubjectNotice=''}
    $tabs=Get-DomeniaControl 'RelationTabs';$tab=Get-DomeniaControl 'TabLinksSelected'
    if($null -ne $tabs -and $null -ne $tab){$tabs.SelectedItem=$tab}
    $intro=if($model -and $s.Type -eq 'Machine'){'Associations connues ; lecture de la session du poste ou recherche dʼun utilisateur dans lʼonglet Associer.'}else{'Associations connues ; détection ou recherche dʼun poste dans lʼonglet Associer.'}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' $intro)
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
function Step-DomeniaRelationsAssociation {
    # D045: every step of the in-page association goes through Step-DomeniaAssociationState; a refusal is explained.
    param([Parameter(Mandatory=$true)][string]$Event,[switch]$Quiet)
    Initialize-DomeniaRelationsState
    $t=Step-DomeniaAssociationState ([string]$script:Relations.AssociationState) $Event
    if(-not $t.Accepted){
        if(-not $Quiet){[void](Set-DomeniaControlText 'LblRelationConfirm' ([string]$t.Reason));Set-Status ('Relations : '+[string]$t.Reason) 'INFO'}
        return $false
    }
    $script:Relations.AssociationState=[string]$t.State
    return $true
}
function Update-DomeniaRelationsActions {
    $s=Get-DomeniaRelationsSubject;$r=$script:Relations
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
    $isUser=($null -ne $s -and $s.Type -eq 'Utilisateur')
    $dir=$null;if($model -and $null -ne $s -and $s.Type -in @('Utilisateur','Machine')){$dir=Get-DomeniaRelationDirection $s.Type}
    $hasSubject=if($model){$null -ne $dir}else{$isUser}
    $busyDetect=($null -ne $r.Query -and -not $r.Query.Ended)
    $busySearch=(-not [string]::IsNullOrWhiteSpace([string]$r.ManualSearchJob))
    $locked=Test-DomeniaAccessBusyWrite
    $planOpen=($model -and $null -ne $r.PendingPlan)
    $detect=Get-DomeniaControl 'BtnDetectUserComputers'
    if($null -ne $detect){$detect.IsEnabled=($hasSubject -and -not $busyDetect -and -not $locked -and -not $planOpen);if($null -ne $dir){$detect.Content=$dir.DetectLabel}}
    foreach($n in @('CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents')){
        # Perimeter options only exist for a user subject: a workstation reads its own session.
        $c=Get-DomeniaControl $n;if($null -eq $c){continue};$c.IsEnabled=($isUser -and -not $busyDetect -and -not $locked -and -not $planOpen)
    }
    $stop=Get-DomeniaControl 'BtnRelationsStop';if($null -ne $stop){$stop.IsEnabled=$busyDetect;$stop.Visibility=if($busyDetect){'Visible'}else{'Hidden'}}
    $remove=Get-DomeniaControl 'BtnRemoveLink';$grid=Get-DomeniaRelationsActiveGrid
    if($null -ne $remove){$remove.IsEnabled=($null -ne $grid -and $null -ne $grid.SelectedItem -and -not $locked)}
    $restore=Get-DomeniaControl 'BtnRestoreLink'
    if($null -ne $restore){$restore.IsEnabled=($model -and -not $locked -and (Test-DomeniaRelationsRestoreAvailable))}
    $d=Get-DomeniaControl 'DgRelationCandidates';$candidate=if($null -ne $d){$d.SelectedItem}else{$null}
    $associable=if($model){[bool](Get-DomeniaMember $candidate 'Associable' $false)}else{($null -ne $candidate -and [bool]$candidate.DN)}
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
    $associateTab=Get-DomeniaControl 'TabLinksAssociate';if($null -ne $associateTab){$associateTab.IsEnabled=$hasSubject}
    $hint=Get-DomeniaControl 'LblRelationAssociateHint'
    if($null -ne $hint){
        if($model){
            $text=if($null -eq $s){'Sélectionnez un utilisateur ou un poste dans Rechercher pour associer.'}elseif($isUser){'Utilisateur : '+$s.Login+' · Détecter lit ses postes connus et les indices AD puis montre le périmètre avant toute lecture de poste ; ou recherchez un poste.'}else{'Poste : '+$s.Name+' · Détecter lit la session de ce poste ; ou recherchez un utilisateur à lui associer.'}
            if($r.SubjectNotice){$text=$r.SubjectNotice+' '+$text}
            $hint.Text=$text
        }else{$hint.Text=if($isUser){'Utilisateur : '+$s.Login+' · choisissez Détecter ou Rechercher un poste.'}else{'Sélectionnez un utilisateur dans Rechercher pour associer un poste.'}}
    }
    $confirm=Get-DomeniaControl 'RelationConfirmPanel';if($null -ne $confirm){$confirm.Visibility=if($null -ne $r.PendingAssociation){'Visible'}else{'Collapsed'}}
    $plan=Get-DomeniaControl 'RelationPlanPanel';if($null -ne $plan){$plan.Visibility=if($planOpen){'Visible'}else{'Collapsed'}}
    $planRun=Get-DomeniaControl 'BtnRelationPlanRun';if($null -ne $planRun){$planRun.IsEnabled=($planOpen -and -not $busyDetect -and -not $locked)}
}
function Update-DomeniaRelationEvidence {
    # D043: a badge and the rule that produced it, never a percentage. D050: workstations where sources
    # designate different accounts are flagged Contradictoire; nothing is merged or removed.
    # Only the workstations changed since the last pass, or rows never qualified, are recomputed.
    param([object[]]$Rows=@())
    Initialize-DomeniaRelationsState
    $r=$script:Relations
    $dirty=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($k in @($r.DirtyComputers)){[void]$dirty.Add([string]$k)}
    foreach($row in @($Rows)){if($null -ne $row -and $null -eq $row.PSObject.Properties['Badge']){$key=ConvertTo-DomeniaRelationComputerKey ([string]$row.Computer);if($key){[void]$dirty.Add($key)}}}
    $session=$r.Observations.ToArray()
    foreach($key in @($dirty)){
        $group=@(@(Get-LinksForComputer $key)+@($session|Where-Object{(ConvertTo-DomeniaRelationComputerKey ([string]$_.Computer)) -eq $key})|Where-Object{$null -ne $_})
        $contradicted=@();foreach($c in @(Get-DomeniaLinkConflicts $group)){$contradicted+=@($c.Relations)}
        foreach($row in $group){
            $b=Get-DomeniaEvidenceBadge $row (Test-DomeniaRelationsListContains $contradicted $row)
            $row|Add-Member -NotePropertyName Badge -NotePropertyValue $b.Badge -Force
            $row|Add-Member -NotePropertyName BadgeRule -NotePropertyValue ($b.Rule+' Provenance : '+$b.Provenance+'.') -Force
            $row|Add-Member -NotePropertyName Provenance -NotePropertyValue $b.Provenance -Force
            $row|Add-Member -NotePropertyName Persistence -NotePropertyValue $(if(Test-DomeniaRelationsListContains $session $row){'Session uniquement'}else{'Enregistrée'}) -Force
        }
    }
    $r.DirtyComputers.Clear()
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
        $c|Add-Member -NotePropertyName BadgeRule -NotePropertyValue $b.Rule -Force
    }
}
function Refresh-DomeniaRelationViews {
    param([switch]$ProgressOnly)
    Initialize-DomeniaRelationsState
    if($script:Relations.Rendering){return}
    $script:Relations.Rendering=$true
    try{
        $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
        if(-not $ProgressOnly){
            $s=Get-DomeniaRelationsSubject;$rows=@(Get-DomeniaRelationsSelectedLinks);$all=@(Get-DomeniaRelationsAllRelations)
            Update-DomeniaRelationEvidence -Rows $all
            $grid=Get-DomeniaControl 'DgLinks';$selected=if($null -ne $grid){$grid.SelectedItem}else{$null}
            [void](Set-DomeniaItemsSource 'DgLinks' $rows);if($null -ne $selected -and $rows -contains $selected){$grid.SelectedItem=$selected}
            $allGrid=Get-DomeniaControl 'DgAllLinks';$allSelected=if($null -ne $allGrid){$allGrid.SelectedItem}else{$null}
            $allRows=if($model){$all}else{@($script:UserMachineLinks)}
            [void](Set-DomeniaItemsSource 'DgAllLinks' $allRows);if($null -ne $allSelected -and $allRows -contains $allSelected){$allGrid.SelectedItem=$allSelected}
            $title=if($null -eq $s){'Sélectionnez un utilisateur ou un poste depuis Rechercher.'}elseif($s.Type -eq 'Utilisateur'){'Utilisateur : '+$s.Login}else{'Poste : '+$s.Name}
            [void](Set-DomeniaControlText 'LblRelationsSelection' $title)
            $context=$title+' · '+$rows.Count+' association(s) mémorisée(s).'
            if($model){
                $sessionOnly=@($rows|Where-Object{[string]$_.Persistence -eq 'Session uniquement'}).Count
                $contradicted=@($rows|Where-Object{[string]$_.Badge -eq 'Contradictoire'}).Count
                if($sessionOnly){$context+=' '+$sessionOnly+' visible(s) pour cette session seulement : le stockage local garde une relation par poste.'}
                if($contradicted){$context+=' '+$contradicted+' qualification(s) contradictoire(s) : sources différentes conservées, sans fusion.'}
            }
            [void](Set-DomeniaControlText 'LblLinkContext' $context)
            $lbl=Get-DomeniaControl 'LblRelationsSelection';if($null -ne $lbl -and $null -ne $s){$lbl.ToolTip=$s.DN}
            $emptyText=if($null -eq $s){'Recherchez un utilisateur ou un poste en haut, sélectionnez sa ligne, puis ouvrez Relations.'}elseif($model){(Get-DomeniaRelationDirection $s.Type).EmptyHint+' Utilisez lʼonglet Associer pour détecter ou rechercher.'}else{'Aucune association mémorisée pour cette sélection. Utilisez lʼonglet Associer pour détecter ou rechercher un poste.'}
            [void](Set-DomeniaControlText 'LblLinkEmpty' $emptyText)
            $empty=Get-DomeniaControl 'LinkEmptyPanel';if($null -ne $empty){$empty.Visibility=if($rows.Count){'Collapsed'}else{'Visible'}}
            [void](Set-DomeniaItemsSource 'DgRelationComputerSearch' @($script:Relations.ManualSearchRows))
        }
        $q=$script:Relations.Query
        if($null -ne $q){
            if($model){Update-DomeniaRelationCandidateEvidence $q}
            [void](Set-DomeniaItemsSource 'DgRelationCandidates' @(@($q.Candidates.Values|Sort-Object Computer)+@($q.Hints)));[void](Set-DomeniaItemsSource 'DgLinkAttempts' @($q.Attempts))
        }elseif($model -and $null -ne $script:Relations.PendingPlan){
            [void](Set-DomeniaItemsSource 'DgRelationCandidates' @($script:Relations.PendingPlan.Rows));[void](Set-DomeniaItemsSource 'DgLinkAttempts' @())
        }else{[void](Set-DomeniaItemsSource 'DgRelationCandidates' @());[void](Set-DomeniaItemsSource 'DgLinkAttempts' @())}
        [void](Set-DomeniaControlText 'LblRelationPlan' $(if($model -and $null -ne $script:Relations.PendingPlan){[string]$script:Relations.PendingPlan.Text}else{''}))
        if($null -ne $script:Relations.PendingAssociation){
            $p=$script:Relations.PendingAssociation
            [void](Set-DomeniaControlText 'LblRelationConfirm' ($p.User+' → '+$p.Computer+' · '+$p.Source+'. Cette association est locale à Domenia et ne modifie pas Active Directory.'))
        }elseif(-not $model){[void](Set-DomeniaControlText 'LblRelationConfirm' '')}
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
        $r.JournalPresent=$true
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
function Test-DomeniaRelationsRestoreAvailable {
    Initialize-DomeniaRelationsState
    if($null -ne (Get-DomeniaRelationsRestorableEntry -MemoryOnly)){return $true}
    if($null -eq $script:Relations.JournalPresent){
        $path=Get-DomeniaRelationsJournalPath
        $script:Relations.JournalPresent=[bool]($path -and [IO.File]::Exists($path))
    }
    return [bool]$script:Relations.JournalPresent
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
        if(-not (Save-UserMachineLinks)){
            $script:UserMachineLinks=$previousLinks;$r.Observations.Clear();foreach($o in $previousObservations){$r.Observations.Add($o)};Rebuild-UserMachineLinkIndex
            $result.SaveFailed=$true;$result.StoredChanged=$false;$result.Reason='Stockage local refusé : relation non enregistrée.'
        }
    }
    $r.LastOutcome=$result
    return $result
}
function Set-DomeniaRelationValue {
    param($Target,[string]$Name,$Value)
    if($null -eq $Target){return}
    if($null -eq $Target.PSObject.Properties[$Name]){$Target|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force}else{$Target.PSObject.Properties[$Name].Value=$Value}
}
function Remove-DomeniaRelation {
    # D050: the removal touches only the local store or the session list. It is journaled and can be restored.
    param($Relation,[string]$Declarant='')
    Initialize-DomeniaRelationsState
    if($null -eq $Relation){return $false}
    $r=$script:Relations
    $stored=$null;foreach($l in @($script:UserMachineLinks)){if([object]::ReferenceEquals($l,$Relation)){$stored=$l;break}}
    if($null -eq $stored){foreach($l in @($script:UserMachineLinks)){if($null -ne $l -and (Test-DomeniaSameRelation $l $Relation)){$stored=$l;break}}}
    $session=$null
    if($null -eq $stored){foreach($o in @($r.Observations)){if([object]::ReferenceEquals($o,$Relation) -or (Test-DomeniaSameRelation $o $Relation)){$session=$o;break}}}
    if($null -eq $stored -and $null -eq $session){Set-Status 'Association introuvable : déjà retirée ou rechargée. Aucune modification.' 'WARN';return $false}
    $target=if($null -ne $stored){$stored}else{$session}
    $entry=New-DomeniaLinkHistoryEntry -Action Removed -Relation $target -Declarant $Declarant -Note $(if($null -ne $stored){'Retirée du stockage local.'}else{'Retirée de la liste de session.'})
    if($null -ne $stored){
        $previous=@($script:UserMachineLinks)
        $script:UserMachineLinks=@($previous|Where-Object{-not [object]::ReferenceEquals($_,$stored)})
        Update-DomeniaRelationLinkIndex -Link $stored -Remove
        if(-not (Save-UserMachineLinks)){$script:UserMachineLinks=$previous;Rebuild-UserMachineLinkIndex;Refresh-DomeniaRelationViews;Set-Status 'Suppression non enregistrée : le stockage local a refusé la modification. Association conservée.' 'WARN';return $false}
    }else{for($i=0;$i -lt $r.Observations.Count;$i++){if([object]::ReferenceEquals($r.Observations[$i],$session)){$r.Observations.RemoveAt($i);break}}}
    Add-DomeniaRelationHistory $entry
    $r.Revision++;[void]$r.DirtyComputers.Add((ConvertTo-DomeniaRelationComputerKey ([string]$target.Computer)))
    Set-Status ('Association retirée localement : '+[string]$target.UserLogin+' -> '+[string]$target.Computer+'. Aucun objet Active Directory modifié ; « Restaurer la suppression » la remet en place.')
    Refresh-DomeniaRelationViews
    return $true
}
function Request-DomeniaRelationRemoval {
    # Asked in the page when the inline confirmation of the shell exists (Features.InlineConfirm), otherwise by the legacy confirmation.
    param($Relation)
    Initialize-DomeniaRelationsState
    if($null -eq $Relation -or (Test-DomeniaAccessBusyWrite)){return}
    $label=[string]$Relation.UserLogin+' -> '+[string]$Relation.Computer
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
    if($null -eq $Entry){$Entry=Get-DomeniaRelationsRestorableEntry}
    if($null -eq $Entry){Set-Status 'Aucune suppression locale à restaurer.' 'INFO';Update-DomeniaRelationsActions;return $false}
    $c=Get-DomeniaLinkRestoreCandidate $Entry @(Get-DomeniaRelationsAllRelations)
    if(-not $c.Restorable){Set-Status ('Restauration non effectuée : '+[string]$c.Reason) 'INFO';Add-DomeniaRelationHistory (New-DomeniaLinkHistoryEntry -Action Restored -Relation $Entry.Relation -Declarant ([string]$script:Conn.BindUser) -Note ([string]$Entry.Id)) -Quiet;Update-DomeniaRelationsActions;return $false}
    $v=$c.Relation
    $relation=[pscustomobject]@{UserLogin=[string]$v.UserLogin;Computer=[string]$v.Computer;Source=[string]$v.Source;Confidence=0;VerifiedInAD=([string]$v.VerifiedInAD -ieq 'True');When=[string]$v.When;Details=[string]$v.Details;UserGuid=[string]$v.UserGuid;ComputerGuid=[string]$v.ComputerGuid;UserDn=[string]$v.UserDn;ComputerDn=[string]$v.ComputerDn;Kind=[string]$v.Kind}
    $o=Add-DomeniaRelation -Relation $relation -Declarant ([string]$script:Conn.BindUser) -Quiet
    if($o.SaveFailed -or $o.Action -eq 'Ignore'){Set-Status ('Restauration non enregistrée : '+[string]$o.Reason) 'WARN';return $false}
    Add-DomeniaRelationHistory (New-DomeniaLinkHistoryEntry -Action Restored -Relation $relation -Declarant ([string]$script:Conn.BindUser) -Note ([string]$Entry.Id))
    $where=if($o.Placement -eq 'Session'){' '+[string]$o.Reason}else{''}
    Set-Status ('Association restaurée localement : '+$relation.UserLogin+' -> '+$relation.Computer+'. Aucun objet Active Directory modifié.'+$where)
    Refresh-DomeniaRelationViews
    return $true
}
function Save-DomeniaRelationConfirmations {
    param($Result,$State)
    if(-not (Test-DomeniaRelationsCurrent $State) -or (Test-DomeniaAccessBusyWrite)){return}
    $changes=@($Result.Candidates|Where-Object{$_.Confirmed -eq $true -and $_.Guid -and $_.DN}|Select-Object -First 50)
    if(-not $changes.Count){return}
    if($null -ne $script:Persistence -and $script:Persistence.LinkBusy){$script:Relations.PendingConfirmed=[pscustomobject]@{Result=$Result;State=$State};return}
    if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){
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
                Set-Status 'Consoles observées, mais associations non enregistrées. Voir le stockage dans Fiabilité.' 'WARN';return
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
        return
    }
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
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
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
        if($model){[void](Step-DomeniaRelationsAssociation 'Results' -Quiet)}
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
        if($model){[void](Step-DomeniaRelationsAssociation 'Results' -Quiet)}
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
        if($model){[void](Step-DomeniaRelationsAssociation 'Results' -Quiet)}
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
    if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
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
    $rows=@(@($Plan.Candidates)|ForEach-Object{[pscustomobject]@{Computer=[string]$_.Computer;Status='À confirmer';CurrentUser='';Source=[string]$_.Source;ObservedUtc='';Detail='Dans le périmètre affiché ; aucune lecture effectuée.';Guid=[string]$_.Guid;DN=[string]$_.DN;Badge='Périmètre';BadgeRule='Poste du périmètre à confirmer.';Why=('Périmètre demandé : '+$scopeText+'.');Associable=$false;Blocker='Aperçu : lancez la détection ou recherchez le poste.'}})
    $r.PendingPlan=[pscustomobject]@{Plan=$Plan;Rows=$rows;Text=$text;Epoch=[long]$script:SessionEpoch;Generation=$r.Generation;SubjectDn=[string]$Subject.DN;SubjectGuid=[string]$Subject.Guid;Login=[string]$Subject.Login;Events=$Events;Limit=$Limit}
    $tabs=Get-DomeniaControl 'RelationTabs';if($null -ne $tabs){$tabs.SelectedItem=Get-DomeniaControl 'TabLinksAssociate'}
    $modes=Get-DomeniaControl 'RelationAssociateModeTabs';if($null -ne $modes){$modes.SelectedItem=Get-DomeniaControl 'TabRelationDetect'}
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
    $tabs=Get-DomeniaControl 'RelationTabs';if($null -ne $tabs){$tabs.SelectedItem=Get-DomeniaControl 'TabLinksAssociate'}
    $modes=Get-DomeniaControl 'RelationAssociateModeTabs';if($null -ne $modes){$modes.SelectedItem=Get-DomeniaControl 'TabRelationDetect'}
    $status=if($Scan){'Détection de '+$Subject.Login+' : '+(Get-DomeniaDetectionCounterText $counters)+'.'}else{'Lecture des associations connues et des indices AD de '+$Subject.Login+' ; aucun poste contacté…'}
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' $status)
    $r.Query.Job=Start-UiTask -Name ('Postes de '+$Subject.Login) -OperationId 'UserComputerProbe' -Code (Get-DomeniaRelationsWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'userprobe' -DisableControls @('BtnDetectUserComputers','CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents') -TimeoutSeconds $(if($Scan){140}else{65}) -SuccessHandler 'Complete-DomeniaUserComputersUi' -ErrorHandler 'Fail-DomeniaUserComputersUi'
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
        $badge=Get-DomeniaEvidenceBadge ([pscustomobject]@{Source=$source;Kind=$kind;When=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')})
        if(-not $match.Match){
            [void]$attempts.Add([pscustomobject]@{Method='Identité du compte';Status=$(if($match.Certain){'HORS DOMAINE'}else{'NON QUALIFIE'});User=$raw;Score='';DurationMs=0;Detail=[string]$match.Reason})
            $message="Compte lu sur $computer : $raw ($source). "+[string]$match.Reason+" Aucune association créée : un compte local, dʼun autre domaine ou non qualifié nʼest pas le compte AD $user."
        }elseif($kind -notin @('Console','SessionRdp')){
            $message="Indice pour $computer : $user ($source · "+$badge.Badge+'). '+$badge.Rule+' Aucune association créée automatiquement ; associez-le explicitement si besoin.'
        }else{
            $added=Add-UserMachineLinkIfMissing -UserLogin $user -Computer ([string]$effective.Computer) -Source $source -Details ([string]$effective.Details) -Confidence 0 -VerifiedInAD $true
            $outcome=if($null -ne $script:Relations){$script:Relations.LastOutcome}else{$null}
            $message=if($added){"Session observée sur $computer : $user ($source · "+$badge.Badge+').'}elseif($null -ne $outcome -and [string]$outcome.Placement -eq 'Session'){"Session observée sur $computer : $user. "+[string]$outcome.Reason}else{"Session observée sur $computer : $user. Relation déjà connue : date mise à jour, aucune autre association modifiée."}
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
        $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
        if($model -and $null -ne $s -and $s.Type -eq 'Machine'){Start-DomeniaRelationsComputerDetect;return}
        if($null -eq $s -or $s.Type -ne 'Utilisateur'){[void](Set-DomeniaControlText 'LblLinkProbeStatus' $(if($model){'Sélectionnez dʼabord un utilisateur ou un poste dans Rechercher.'}else{'Sélectionnez dʼabord un utilisateur dans Rechercher.'}));return}
        if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Une écriture reste active ou à vérifier.');return}
        $r=$script:Relations;if($null -ne $r.Query -and -not $r.Query.Ended){return}
        # D048: only an explicit gesture may start a probe; rendering or scrolling a list never does.
        if(-not (Test-DomeniaProbeAllowed 'ExplicitDetect')){return}
        $scan=$true;$events=[bool](Get-DomeniaControl 'ChkRelationEvents').IsChecked
        $scope=[string](Get-DomeniaControl 'CmbRelationScanScope').SelectedItem.Tag;if($scope -notin @('Candidates','Loaded','OU')){$scope='Candidates'}
        $limit=20;$raw=[string](Get-DomeniaControl 'TxtRelationScanLimit').Text
        if(-not [int]::TryParse($raw,[ref]$limit) -or $limit -lt 1 -or $limit -gt 50){[void](Set-DomeniaControlText 'LblLinkProbeStatus' 'Maximum invalide : choisissez une valeur de 1 à 50.');return}
        if(Get-DomeniaFeatureFlag 'DetectionPreview' $true){
            # D047: no silent change of perimeter. Candidates first reads the directory only (phase 1);
            # Loaded and OU take the machines displayed for that perimeter. A plan is confirmed before any probe.
            $r.PendingPlan=$null
            if($scope -eq 'Candidates'){Submit-DomeniaRelationsQuery -Subject $s -Phase 'Collect' -Scan $false -Scope 'Candidates' -Limit $limit -Events $events;return}
            $cands=@(Get-DomeniaRelationScopeCandidates -Scope $scope)
            $plan=Get-DomeniaDetectionScopePlan -RequestedScope $scope -OuDn ([string]$script:SelectedBranchDn) -DomainDn ([string]$script:Conn.BaseDn) -Candidates $cands -Limit $limit -IncludeRdp $false
            Show-DomeniaRelationDetectionPlan -Plan $plan -Subject $s -Events $events -Limit $limit
            return
        }
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
        $counters=Get-DomeniaMember $q 'Counters' $null
        if($null -ne $counters){[void](Add-DomeniaDetectionOutcome $counters 'Stopped')}
        if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
        Update-DomeniaRelationsActions
        $text='Arrêt demandé. Les liens enregistrés sont conservés ; attente de la fin réelle de la lecture.'
        if($null -ne $counters){$text+=' '+(Get-DomeniaDetectionCounterText $counters)+'.'}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' $text)
    }
}
function Use-DomeniaRelationCandidate {
    param([switch]$Open)
    $s=Get-DomeniaRelationsSubject;$d=Get-DomeniaControl 'DgRelationCandidates';$c=if($null -ne $d){$d.SelectedItem}else{$null}
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
    if($null -eq $s -or $s.Type -ne 'Utilisateur' -or $null -eq $c -or -not $c.DN -or (Test-DomeniaAccessBusyWrite)){return}
    if($model -and -not [bool](Get-DomeniaMember $c 'Associable' $false)){
        # D046: a candidate without AD identity (an IP address, a partial name) cannot be associated.
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Association impossible : '+[string](Get-DomeniaMember $c 'Blocker' 'objet AD non identifié par son GUID.')));return
    }
    if($Open){Open-AdObject -Dn ([string]$c.DN) -Type Machine;return}
    Set-DomeniaRelationPendingAssociation -Computer ([string]$c.Computer) -DN ([string]$c.DN) -Guid ([string]$c.Guid) -Source ([string]$c.Source)
}
function Initialize-DomeniaRelationsUi {
    Initialize-DomeniaRelationsState
    if($script:Relations.Bound){return};$script:Relations.Bound=$true
    $t=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$t.Interval=[timespan]::FromMilliseconds(120);$t.Add_Tick({try{Invoke-DomeniaRelationsTick}catch{Write-AppLog ('Affichage des relations : '+$_.Exception.Message) 'WARN'}});$script:Relations.Timer=$t
    $script:Window.Add_Closed({if($null -ne $script:Relations){$script:Relations.Timer.Stop();$script:Relations.Query=$null;$script:Relations.Subject=$null;$script:Relations.PendingConfirmed=$null;$script:Relations.PendingAssociation=$null;$script:Relations.PendingPlan=$null}})
    $tabs=Get-DomeniaControl 'RelationTabs';if($null -ne $tabs){$tabs.Add_SelectionChanged({param($sender,$e) if($e.OriginalSource -eq $sender){Update-DomeniaRelationsActions}})}
    foreach($name in @('DgAllLinks','DgRelationCandidates','DgRelationComputerSearch','DgLinks')){$g=Get-DomeniaControl $name;if($null -ne $g){$g.Add_SelectionChanged({Update-DomeniaRelationsActions})}}
    $search=Get-DomeniaControl 'BtnRelationComputerSearch';if($null -ne $search){$search.Add_Click({Start-DomeniaRelationComputerSearch})}
    $term=Get-DomeniaControl 'TxtRelationComputerSearch';if($null -ne $term){$term.Add_KeyDown({param($s,$e)if($e.Key -eq 'Return'){$e.Handled=$true;Start-DomeniaRelationComputerSearch}});$term.Add_TextChanged({Clear-DomeniaRelationManualResults})}
    $assoc=Get-DomeniaControl 'BtnRelationAssociateSearchResult';if($null -ne $assoc){$assoc.Add_Click({Request-DomeniaRelationManualAssociation})}
    $exportAll=Get-DomeniaControl 'BtnExportAllLinks';if($null -ne $exportAll){$exportAll.Add_Click({$tabs=Get-DomeniaControl 'RelationTabs';$all=Get-DomeniaControl 'TabLinksAll';if($null -ne $tabs -and $null -ne $all){$tabs.SelectedItem=$all};Export-DomeniaLinksCsv})}
    $cancel=Get-DomeniaControl 'BtnRelationConfirmCancel';if($null -ne $cancel){$cancel.Add_Click({Cancel-DomeniaRelationAssociation})}
    $apply=Get-DomeniaControl 'BtnRelationConfirmApply';if($null -ne $apply){$apply.Add_Click({Confirm-DomeniaRelationAssociation})}
    $planRun=Get-DomeniaControl 'BtnRelationPlanRun';if($null -ne $planRun){$planRun.Add_Click({Confirm-DomeniaRelationDetectionPlan})}
    $planCancel=Get-DomeniaControl 'BtnRelationPlanCancel';if($null -ne $planCancel){$planCancel.Add_Click({Cancel-DomeniaRelationDetectionPlan})}
    $restore=Get-DomeniaControl 'BtnRestoreLink';if($null -ne $restore){$restore.Add_Click({[void](Restore-DomeniaRemovedLink)})}
    (Get-DomeniaControl 'BtnRelationsStop').Add_Click({Stop-DomeniaRelationsSearch})
    (Get-DomeniaControl 'BtnRelationOpenCandidate').Add_Click({Use-DomeniaRelationCandidate -Open})
    (Get-DomeniaControl 'BtnRelationAdopt').Add_Click({Use-DomeniaRelationCandidate})
    $workspace=Get-DomeniaControl 'WorkspaceTabs';if($null -ne $workspace){$workspace.Add_SelectionChanged({param($sender,$e) if($e.OriginalSource -eq $sender -and [string]$sender.SelectedItem.Name -eq 'TabRelations'){Refresh-DomeniaRelationViews}})}
    Refresh-DomeniaRelationViews
}
function Clear-DomeniaRelationManualResults {
    # A new term invalidates the previous results and any association prepared from them.
    if($null -eq $script:Relations){return}
    $script:Relations.ManualSearchRows=@()
    if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){
        if($null -ne $script:Relations.PendingAssociation){Cancel-DomeniaRelationAssociation;return}
        if([string]$script:Relations.AssociationState -eq 'Candidate' -and -not $script:Relations.ManualSearchJob){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
    }else{$script:Relations.PendingAssociation=$null}
    Refresh-DomeniaRelationViews
}

function Start-DomeniaRelationComputerSearch {
    Initialize-DomeniaRelationsState;$r=$script:Relations;$s=Get-DomeniaRelationsSubject
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
    $dir=$null;if($model -and $null -ne $s -and $s.Type -in @('Utilisateur','Machine')){$dir=Get-DomeniaRelationDirection $s.Type}
    if(($model -and $null -eq $dir) -or (-not $model -and ($null -eq $s -or $s.Type -ne 'Utilisateur'))){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' $(if($model){'Sélectionnez dʼabord un utilisateur ou un poste dans Rechercher.'}else{'Sélectionnez dʼabord un utilisateur dans Rechercher.'}));return}
    if(Test-DomeniaAccessBusyWrite){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Une écriture reste active ou à vérifier.');return}
    if($r.ManualSearchJob){return}
    $term=([string](Get-DomeniaControl 'TxtRelationComputerSearch').Text).Trim()
    if($term.Length -lt 2){[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' 'Saisissez au moins deux caractères.');return}
    $kind='Machine'
    if($model){
        # D045: a new search cancels the association waiting for confirmation, then enters Searching.
        if($null -ne $r.PendingAssociation){Cancel-DomeniaRelationAssociation}
        if($r.AssociationState -ne 'Searching' -and -not (Step-DomeniaRelationsAssociation 'Search')){return}
        $kind=$dir.TargetType
    }
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
    $typeOk=($null -ne $s -and ($s.Type -eq 'Utilisateur' -or ($s.Type -eq 'Machine' -and (Get-DomeniaFeatureFlag 'RelationsSymmetry' $true))))
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
    if((Get-DomeniaFeatureFlag 'RelationsSymmetry' $true) -and [string]$script:Relations.AssociationState -eq 'Searching'){[void](Step-DomeniaRelationsAssociation 'Results' -Quiet)}
    [void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' $msg);Refresh-DomeniaRelationViews
}
function Fail-DomeniaRelationComputerSearch {
    param($Message,$State)
    if(-not (Test-DomeniaRelationManualState $State)){return}
    $script:Relations.ManualSearchJob='';$script:Relations.ManualSearchRows=@();[void](Set-DomeniaControlText 'LblRelationComputerSearchStatus' ('Recherche non confirmée : '+[string]$Message))
    if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
    Refresh-DomeniaRelationViews
}
function Set-DomeniaRelationPendingAssociation {
    param([string]$Computer,[string]$DN,[string]$Guid,[string]$Source='Recherche AD',[string]$Login='',[string]$TargetType='Machine')
    $s=Get-DomeniaRelationsSubject
    if(-not (Get-DomeniaFeatureFlag 'RelationsSymmetry' $true)){
        if($null -eq $s -or $s.Type -ne 'Utilisateur' -or -not $Computer -or -not $DN){return}
        $script:Relations.PendingAssociation=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$script:Relations.Generation;User=$s.Login;UserDn=$s.DN;UserGuid=$s.Guid;Computer=(Normalize-LinkComputer $Computer);DN=$DN;Guid=$Guid;Source=$Source;Job=''}
        Refresh-DomeniaRelationViews;return
    }
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
    if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){
        $type=ConvertTo-DomeniaRelationType ([string]$row.Type);if(-not $type){$type='Machine'}
        Set-DomeniaRelationPendingAssociation -Computer ([string]$row.Name) -Login ([string]$row.Login) -DN ([string]$row.DN) -Guid ([string]$row.Guid) -Source 'Recherche AD manuelle' -TargetType $type
        return
    }
    Set-DomeniaRelationPendingAssociation -Computer ([string]$row.Name) -DN ([string]$row.DN) -Guid ([string]$row.Guid) -Source 'Recherche AD manuelle'
}
function Cancel-DomeniaRelationAssociation {
    if($null -ne $script:Relations -and (Get-DomeniaFeatureFlag 'RelationsSymmetry' $true)){[void](Step-DomeniaRelationsAssociation 'Cancel' -Quiet)}
    if($null -ne $script:Relations -and $null -ne $script:Relations.PendingAssociation){$job=[string]$script:Relations.PendingAssociation.Job;if($job){try{Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Association annulée'}catch{}};$script:Relations.PendingAssociation=$null;Refresh-DomeniaRelationViews}
}
function Confirm-DomeniaRelationAssociation {
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
    $p=$script:Relations.PendingAssociation
    if(-not $model){
        if($null -eq $p -or $p.Job -or (Test-DomeniaAccessBusyWrite)){return}
        $s=Get-DomeniaRelationsSubject
        if($null -eq $s -or $s.Type -ne 'Utilisateur' -or $p.Epoch -ne [long]$script:SessionEpoch -or $p.Generation -ne $script:Relations.Generation -or $p.UserDn -ine $s.DN -or $p.UserGuid -ine $s.Guid){Cancel-DomeniaRelationAssociation;return}
        [void](Set-DomeniaControlText 'LblRelationConfirm' ($p.User+' → '+$p.Computer+' · vérification du poste dans Active Directory…'))
        $request=[guid]::NewGuid().ToString('N')
        $state=[pscustomobject]@{RequestId=$request;Epoch=$p.Epoch;BaseDn=[string]$script:Conn.BaseDn;Generation=$p.Generation;Pending=$p}
        $payload=[pscustomobject]@{Kind='Machine';Term='';Verify=$true;RequestId=$request;DN=$p.DN;Guid=$p.Guid}
        $p.Job=Start-UiTask -Name 'Vérification de l association' -OperationId 'EmbeddedDirectoryLookup' -Code (Get-DomeniaEmbeddedLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'relations:verify-association' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaRelationAssociationVerify' -ErrorHandler 'Fail-DomeniaRelationAssociationVerify'
        Update-DomeniaRelationsActions;return
    }
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
    $model=Get-DomeniaFeatureFlag 'RelationsSymmetry' $true
    if(-not $model){
        if($null -eq $p -or $script:Relations.PendingAssociation -ne $p -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $script:Relations.Generation -or $null -eq $s -or $s.DN -ine $p.UserDn){return}
        $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Verified')
        if($null -eq $data -or -not [bool]$data.Verified -or @($data.Rows).Count -ne 1){Fail-DomeniaRelationAssociationVerify 'Le poste n a pas pu être revérifié.' $State;return}
        $row=@($data.Rows)[0]
        if($row.DN -ine $p.DN -or $row.Guid -ine $p.Guid){Fail-DomeniaRelationAssociationVerify 'Le poste a changé depuis la sélection. Relancez la recherche.' $State;return}
        $p.Job='';[void](Add-UserMachineLinkIfMissing -UserLogin $p.User -Computer $p.Computer -Source 'Saisie manuelle' -Details ('Association confirmée dans Relations depuis '+$p.Source+'.') -Confidence 100 -VerifiedInAD $true)
        $script:Relations.PendingAssociation=$null;[void](Set-DomeniaControlText 'LblLinkProbeStatus' ('Association enregistrée : '+$p.User+' → '+$p.Computer+'.'));Refresh-DomeniaRelationViews;return
    }
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
    if(Get-DomeniaFeatureFlag 'RelationsSymmetry' $true){[void](Step-DomeniaRelationsAssociation 'VerifyFailed' -Quiet)}
    [void](Set-DomeniaControlText 'LblRelationConfirm' ('Vérification impossible : '+[string]$Message+'. Aucune association enregistrée.'));Update-DomeniaRelationsActions
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
