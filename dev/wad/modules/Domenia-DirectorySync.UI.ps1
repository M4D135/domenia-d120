# Points 22, 23, 24 and 30: the Contrôles tab of the autonomous base. Reads of the local base run in the LocalIndexRead
# worker; the verification of disappeared objects is an explicit and bounded directory read; snapshots and verification
# results go through the local storage queue. No directory write and no automatic scan start from here.
$script:DomeniaDirectorySyncModuleRoot=$PSScriptRoot
$script:DomeniaDirectorySync=$null
$script:DomeniaSnapshotDeleteId=''

function Initialize-DomeniaDirectorySyncUi {
    # Loaded once, from its own XAML file, as a tab of the autonomous base page. No window is created.
    if($null -ne $script:DomeniaDirectorySync){return}
    $tabs=Get-DomeniaControl 'IndexWorkspaceTabs'
    if($null -eq $tabs){return}
    [xml]$document=[IO.File]::ReadAllText((Join-Path $script:DomeniaDirectorySyncModuleRoot 'Domenia-DirectorySync.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $controls=@{}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if(-not $name){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de contrôle déjà présent : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Contrôle des contrôles de base introuvable : '+$name)}
        $controls[$name]=$control
    }
    foreach($name in $controls.Keys){$script:Ctrl[$name]=$controls[$name]}
    $tab=New-Object Windows.Controls.TabItem
    $tab.Name='TabIndexControls';$tab.Header='Contrôles';$tab.Content=$view
    $tab.ToolTip='Recensement du périmètre, objets disparus à vérifier et relevés datés de lʼannuaire.'
    [Windows.Automation.AutomationProperties]::SetName($tab,'Contrôles de la base autonome')
    $script:Ctrl['TabIndexControls']=$tab
    [void]$tabs.Items.Add($tab)
    $script:DomeniaDirectorySync=[pscustomobject]@{ReadGeneration=0L;CompareGeneration=0L;Absences=@();AbsenceTotal=0L;Snapshots=@();CheckJob='';PendingSnapshot=$null;Gaps=@();GapTotal=0L;GapJob=''}
    [void](Set-DomeniaControlText 'LblSnapshotNotice' (Get-DomeniaSnapshotNotice))
    # Event handlers call named functions only: no closure over a local that would expire.
    # Point 22: the complete read of the chosen OU is the same explicit gesture as « Mettre à jour lʼOU choisie ».
    (Get-DomeniaControl 'BtnSyncCensusRun').Add_Click({Start-DomeniaSelectedIndexScopeBuild})
    (Get-DomeniaControl 'BtnSyncGapRead').Add_Click({Request-DomeniaCensusGapRead})
    (Get-DomeniaControl 'BtnSyncAbsencesRefresh').Add_Click({Request-DomeniaDirectorySyncRead})
    (Get-DomeniaControl 'BtnSyncAbsencesCheck').Add_Click({Request-DomeniaAbsenceCheck})
    (Get-DomeniaControl 'BtnSnapshotCapture').Add_Click({Start-DomeniaSnapshotCapture})
    (Get-DomeniaControl 'BtnSnapshotDelete').Add_Click({Request-DomeniaSnapshotDelete})
    (Get-DomeniaControl 'BtnSnapshotCompare').Add_Click({Start-DomeniaSnapshotCompare})
    (Get-DomeniaControl 'DgSnapshots').Add_SelectionChanged({Update-DomeniaSnapshotButtons})
    # Opening the tab reads the local base only (absences and snapshots); a nested grid selection is ignored.
    $tabs.Add_SelectionChanged({param($sender,$eventArgs)
        if(([object]::ReferenceEquals($sender,$eventArgs.OriginalSource)) -and ($null -ne $sender.SelectedItem) -and ([string]$sender.SelectedItem.Name -eq 'TabIndexControls')){Request-DomeniaDirectorySyncRead}
    })
}

function Test-DomeniaDirectorySyncVisible {
    $tabs=Get-DomeniaControl 'IndexWorkspaceTabs'
    return (($null -ne $tabs) -and ($null -ne $tabs.SelectedItem) -and ([string]$tabs.SelectedItem.Name -eq 'TabIndexControls'))
}

function Test-DomeniaDirectorySyncStateCurrent {
    # A callback applies only to the database, session and request generation that started it.
    param($State,[ValidateSet('Read','Compare','Check')][string]$Kind='Read')
    $s=$script:DomeniaDirectorySync
    if(($null -eq $s) -or ($null -eq $State)){return $false}
    if(([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return $false}
    if($Kind -eq 'Read'){return ([long]$State.Generation -eq [long]$s.ReadGeneration)}
    if($Kind -eq 'Compare'){return ([long]$State.Generation -eq [long]$s.CompareGeneration)}
    return $true
}

function Request-DomeniaDirectorySyncRead {
    # Local read only: objects not seen by a complete read and saved snapshots of this domain.
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    Update-DomeniaCensusAdviceUi
    $path=[string]$script:DatabaseScopedPath
    if(-not $path){[void](Set-DomeniaControlText 'LblSyncAbsences' 'Base locale non ouverte : connectez-vous à un domaine.');return}
    $s.ReadGeneration=[long]$s.ReadGeneration+1
    $state=[pscustomobject]@{Generation=[long]$s.ReadGeneration;Epoch=[long]$script:SessionEpoch;Path=$path}
    # FI-12: no fixed wait, the worker follows LocalStore.DatabaseBusyTimeoutMs from its context.
    $payload=[pscustomobject]@{Action='DirectorySync';Path=$path;DomainDn=[string]$script:Conn.BaseDn}
    try{
        $job=Start-UiTask -Name 'Contrôles de la base locale' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaDirectorySyncRead' -ErrorHandler 'Fail-DomeniaDirectorySyncRead' -ReplaceKey 'directory-sync-read' -TimeoutSeconds 60 -TaskClass 'Explicit'
        if(-not $job){throw 'Lecture locale non admise par le moteur.'}
        [void](Set-DomeniaControlText 'LblSyncAbsences' 'Lecture de la base locale…')
    }catch{[void](Set-DomeniaControlText 'LblSyncAbsences' ('Lecture locale non lancée : '+$_.Exception.Message))}
}

function Complete-DomeniaDirectorySyncRead {
    param($Result,$State)
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Read')){return}
    $s=$script:DomeniaDirectorySync
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Busy')
        if($null -eq $r){throw 'Réponse locale absente.'}
        if([bool]$r.Busy){[void](Set-DomeniaControlText 'LblSyncAbsences' 'Base locale occupée par un enregistrement : actualisez la liste dans un instant.');return}
        if([bool](Get-DomeniaMember $r 'Missing' $false)){
            $s.Absences=@();$s.AbsenceTotal=0L;$s.Snapshots=@();$s.Gaps=@();$s.GapTotal=0L
            [void](Set-DomeniaItemsSource 'DgSyncAbsences' @());[void](Set-DomeniaItemsSource 'DgSnapshots' @())
            [void](Set-DomeniaControlText 'LblSyncAbsences' 'Base locale absente : aucune disparition ni relevé.')
            [void](Set-DomeniaControlText 'LblSyncGaps' (Get-DomeniaCensusGapSummary -Total 0))
            Update-DomeniaSnapshotChoices;Update-DomeniaSnapshotButtons
            return
        }
        if([string](Get-DomeniaMember $r 'DataSource' '') -cne 'SQLite'){throw 'Réponse locale non confirmée par SQLite.'}
        # Point 22: identities of the last census still missing from the local copy (200 shown, exact total).
        $s.Gaps=@(@(Get-DomeniaMember $r 'Gaps' @())|Where-Object{($null -ne $_) -and (ConvertTo-DomeniaGuidText (Get-DomeniaMember $_ 'object_guid' ''))})
        $s.GapTotal=[long](Get-DomeniaMember $r 'GapTotal' 0)
        [void](Set-DomeniaControlText 'LblSyncGaps' (Get-DomeniaCensusGapSummary -Total ([long]$s.GapTotal) -Shown (@($s.Gaps).Count)))
        $absences=@(@($r.Absences)|Where-Object{$null -ne $_}|ForEach-Object{ConvertTo-DomeniaAbsenceRow $_})
        $s.Absences=$absences;$s.AbsenceTotal=[long]$r.AbsenceTotal
        [void](Set-DomeniaItemsSource 'DgSyncAbsences' $absences)
        [void](Set-DomeniaControlText 'LblSyncAbsences' (Get-DomeniaAbsenceSummary -Rows $absences -Total ([long]$r.AbsenceTotal) -Counts @($r.AbsenceCounts)))
        $snapshots=@(@($r.Snapshots)|Where-Object{$null -ne $_}|ForEach-Object{ConvertTo-DomeniaSnapshotRow $_})
        $s.Snapshots=$snapshots
        [void](Set-DomeniaItemsSource 'DgSnapshots' $snapshots)
        $snapshotText=if($snapshots.Count){[string]$snapshots.Count+' relevé(s) enregistré(s) pour ce domaine (50 au plus).'}else{'Aucun relevé enregistré pour ce domaine.'}
        $pending=$s.PendingSnapshot
        if(($null -ne $pending) -and ([bool]$pending.Committed)){
            # The storage receipt says the batch committed; only the base says whether the snapshot was taken.
            $taken=@($snapshots|Where-Object{[string]$_.SnapshotId -ceq [string]$pending.Id}|Select-Object -First 1)
            if($taken.Count){$snapshotText='Relevé « '+[string]$pending.Label+' » enregistré : '+[string]$taken[0].ObjectCount+' objet(s). '+[string]$taken[0].CoverageText+' '+$snapshotText}
            else{$snapshotText='Relevé « '+[string]$pending.Label+' » non enregistré : 50 relevés au plus par domaine, ou plus de 300 000 objets dans le périmètre. '+$snapshotText}
            $s.PendingSnapshot=$null
        }
        [void](Set-DomeniaControlText 'LblSnapshots' $snapshotText)
        Update-DomeniaSnapshotChoices
        Update-DomeniaSnapshotButtons
    }catch{[void](Set-DomeniaControlText 'LblSyncAbsences' ('Lecture locale non exploitable : '+$_.Exception.Message))}
}

function Fail-DomeniaDirectorySyncRead {
    param($Message,$State)
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Read')){return}
    [void](Set-DomeniaControlText 'LblSyncAbsences' ('Lecture locale impossible : '+[string]$Message))
}

function Get-DomeniaCensusMaxAgeDays {
    # Index.FullRebuildDays: age after which a complete read of the chosen scope is advised (7 days by default).
    $days=7
    try{$days=[int](Get-CfgValue 'Index' 'FullRebuildDays' 7)}catch{$days=7}
    return [Math]::Max(1,[Math]::Min(90,$days))
}

function Get-DomeniaCensusAdviceForScope {
    # Census advice of the update scope chosen in the autonomous base page, from the committed coverage in memory.
    $scope=Get-DomeniaIndexScope
    $coverage=Get-DomeniaFleetFreshness -ScopeDn $(if([bool]$scope.IsDomain){''}else{[string]$scope.BaseDn}) -DomainDn ([string]$script:Conn.BaseDn) -SyncStates $script:IndexSyncStates
    $gap=0
    if($null -ne $script:IndexInfo){$gap=[int](Get-DomeniaMember $script:IndexInfo 'CensusGap' 0)}
    return (Get-DomeniaCensusAdvice -Coverage $coverage -GapCount $gap -MaxAgeDays (Get-DomeniaCensusMaxAgeDays) -NowUtc ([datetime]::UtcNow) -IsDomain ([bool]$scope.IsDomain))
}

function Update-DomeniaCensusAdviceUi {
    try{[void](Set-DomeniaControlText 'LblSyncCensus' ([string](Get-DomeniaCensusAdviceForScope).Text))}
    catch{[void](Set-DomeniaControlText 'LblSyncCensus' ('État du recensement non calculé : '+$_.Exception.Message))}
}

# ---------------------------------------------------------------- point 22: census gaps read by GUID
function Request-DomeniaCensusGapRead {
    # Explicit and bounded: the identities the last domain census found missing are read by GUID, never the domain.
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    if([bool]$script:DemoMode){[void](Set-DomeniaControlText 'LblSyncGaps' 'Lecture indisponible en démonstration : aucun contrôleur réel.');return}
    if(([string]$s.GapJob) -and ($script:AsyncJobs.Contains([string]$s.GapJob))){[void](Set-DomeniaControlText 'LblSyncGaps' 'Une lecture des objets manquants est déjà en cours.');return}
    $count=@($s.Gaps).Count
    if(-not $count){[void](Set-DomeniaControlText 'LblSyncGaps' 'Aucun objet manquant à lire : actualisez la liste.');return}
    $message=[string]$count+' objet(s) recensé(s) mais absent(s) de la base locale seront lus par leur GUID dans le domaine (attributs de la base autonome seulement). Lecture seule : rien nʼest modifié dans lʼannuaire. Un objet lu est ajouté à la base locale ; un objet que la lecture ne renvoie plus quitte la liste, sans conclusion.'
    [void](Request-DomeniaInlineConfirmation -Title 'Lire les objets manquants' -Message $message -Target 'index:lire-objets-manquants' -OnConfirm {Start-DomeniaCensusGapRead})
}

function Start-DomeniaCensusGapRead {
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    $guids=@(@($s.Gaps)|ForEach-Object{(ConvertTo-DomeniaGuidText (Get-DomeniaMember $_ 'object_guid' '')).ToLowerInvariant()}|Where-Object{$_}|Select-Object -First 200)
    if(-not $guids.Count){return}
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;DomainDn=[string]$script:Conn.BaseDn;Guids=$guids}
    # The deleted objects are not read: a missing identity is filled in or leaves the list, it is never judged deleted.
    $payload=[pscustomobject]@{Items=@($guids|ForEach-Object{[pscustomobject]@{Guid=[string]$_}});CheckDeleted=$false}
    try{
        $s.GapJob=[string](Start-UiTask -Name 'Lecture des objets manquants' -OperationId 'DirectoryAbsenceCheck' -Code (Get-DomeniaAbsenceCheckWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaCensusGapRead' -ErrorHandler 'Fail-DomeniaCensusGapRead' -DisableControls @('BtnSyncGapRead') -TimeoutSeconds 120 -TaskClass 'Explicit')
        if(-not $s.GapJob){throw 'Lecture non admise par le moteur.'}
        [void](Set-DomeniaControlText 'LblSyncGaps' ('Lecture de '+[string]$guids.Count+' objet(s) par leur GUID en cours… (aucune nouvelle lecture après 60 secondes)'))
    }catch{$s.GapJob='';[void](Set-DomeniaControlText 'LblSyncGaps' ('Lecture non lancée : '+$_.Exception.Message))}
}

function Complete-DomeniaCensusGapRead {
    param($Result,$State)
    $s=$script:DomeniaDirectorySync
    if($null -ne $s){$s.GapJob=''}
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Check')){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Results','DomainRead')
        if($null -eq $r){throw 'Réponse de lecture absente.'}
        $asked=@{};foreach($guid in @($State.Guids)){$asked[[string]$guid]=$true}
        $checkedUtc=ConvertTo-DomeniaUtcDate ([string]$r.ObservedUtc);if($null -eq $checkedUtc){$checkedUtc=[datetime]::UtcNow}
        $store=New-Object 'System.Collections.Generic.List[object]';$added=0;$gone=0;$unread=0
        foreach($answer in @($r.Results)){
            if($null -eq $answer){continue}
            $guid=([string]$answer.Guid).ToLowerInvariant()
            if(-not $asked.ContainsKey($guid)){continue}
            $row=New-DomeniaCensusGapStoreRow -Guid $guid -Check $answer -CheckedUtc $checkedUtc -Server ([string]$r.Server)
            if([string]$row.Status -eq 'Visible'){$added++}elseif([string]$row.Status -eq 'Introuvable'){$gone++}else{$unread++}
            $store.Add($row)
        }
        if(-not $store.Count){throw 'Aucun résultat ne correspond aux objets demandés.'}
        $text='Lecture terminée : '+$added+' objet(s) à ajouter, '+$gone+' qui ne sont plus visibles, '+$unread+' non lu(s).'
        if(($added+$gone) -gt 0){
            $batch=[pscustomobject]@{Results=$store.ToArray();Server=[string]$r.Server;At=$checkedUtc.ToString('o');Source='CensusGap'}
            if(-not (Queue-DomeniaMetadata -Kind 'DirectoryAbsence' -Row $batch -Key ('census-gaps-'+[guid]::NewGuid().ToString('N')))){throw 'File dʼenregistrement locale indisponible : résultats non enregistrés.'}
            $text+=' Enregistrement local en attente de confirmation.'
        }
        if([string]$r.DomainRead -ne 'Read'){$text+=' Lecture du domaine interrompue : '+[string](Get-DomeniaMember $r 'DomainError' '')}
        [void](Set-DomeniaControlText 'LblSyncGaps' $text)
    }catch{[void](Set-DomeniaControlText 'LblSyncGaps' ('Lecture non exploitable : '+$_.Exception.Message))}
}

function Fail-DomeniaCensusGapRead {
    param($Message,$State)
    $s=$script:DomeniaDirectorySync
    if($null -ne $s){$s.GapJob=''}
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Check')){return}
    [void](Set-DomeniaControlText 'LblSyncGaps' ('Lecture impossible : '+[string]$Message+' Les objets manquants restent à lire.'))
}

# ---------------------------------------------------------------- points 23 and 24: disappeared objects
function Request-DomeniaAbsenceCheck {
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    if([bool]$script:DemoMode){[void](Set-DomeniaControlText 'LblSyncAbsences' 'Vérification indisponible en démonstration : aucun contrôleur réel.');return}
    if(([string]$s.CheckJob) -and ($script:AsyncJobs.Contains([string]$s.CheckJob))){[void](Set-DomeniaControlText 'LblSyncAbsences' 'Une vérification est déjà en cours.');return}
    $items=@(Select-DomeniaAbsencesToCheck -Rows @($s.Absences) -Limit 200)
    if(-not $items.Count){[void](Set-DomeniaControlText 'LblSyncAbsences' 'Aucun objet à vérifier parmi ceux affichés.');return}
    $message=[string]$items.Count+' objet(s) non revu(s) seront relus par leur GUID dans le domaine, puis parmi les objets supprimés visibles par ce compte. Lecture seule : rien nʼest modifié dans lʼannuaire. Un objet retrouvé reprend son emplacement dans la base locale ; une suppression nʼest retenue quʼavec sa preuve.'
    [void](Request-DomeniaInlineConfirmation -Title 'Vérifier les disparitions' -Message $message -Target 'index:verifier-disparitions' -OnConfirm {Start-DomeniaAbsenceCheck})
}

function Start-DomeniaAbsenceCheck {
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    $items=@(Select-DomeniaAbsencesToCheck -Rows @($s.Absences) -Limit 200)
    if(-not $items.Count){return}
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;DomainDn=[string]$script:Conn.BaseDn;Items=$items}
    $payload=[pscustomobject]@{Items=@($items|ForEach-Object{[pscustomobject]@{Guid=[string]$_.Guid}});CheckDeleted=$true}
    try{
        $s.CheckJob=[string](Start-UiTask -Name 'Vérification des disparitions' -OperationId 'DirectoryAbsenceCheck' -Code (Get-DomeniaAbsenceCheckWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaAbsenceCheck' -ErrorHandler 'Fail-DomeniaAbsenceCheck' -DisableControls @('BtnSyncAbsencesCheck') -TimeoutSeconds 120 -TaskClass 'Explicit')
        if(-not $s.CheckJob){throw 'Vérification non admise par le moteur.'}
        [void](Set-DomeniaControlText 'LblSyncAbsences' ('Vérification de '+[string]$items.Count+' objet(s) en cours… (aucune nouvelle lecture après 60 secondes)'))
    }catch{$s.CheckJob='';[void](Set-DomeniaControlText 'LblSyncAbsences' ('Vérification non lancée : '+$_.Exception.Message))}
}

function Complete-DomeniaAbsenceCheck {
    param($Result,$State)
    $s=$script:DomeniaDirectorySync
    if($null -ne $s){$s.CheckJob=''}
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Check')){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Results','DomainRead','DeletedRead')
        if($null -eq $r){throw 'Réponse de vérification absente.'}
        $byGuid=@{};foreach($item in @($State.Items)){$byGuid[([string]$item.Guid).ToLowerInvariant()]=$item}
        $checkedUtc=ConvertTo-DomeniaUtcDate ([string]$r.ObservedUtc);if($null -eq $checkedUtc){$checkedUtc=[datetime]::UtcNow}
        $store=New-Object 'System.Collections.Generic.List[object]';$counts=@{}
        foreach($answer in @($r.Results)){
            if($null -eq $answer){continue}
            $guid=([string]$answer.Guid).ToLowerInvariant()
            if(-not $byGuid.ContainsKey($guid)){continue}
            $item=$byGuid[$guid]
            $resolution=Resolve-DomeniaDirectoryAbsence -Absence ([pscustomobject]@{Guid=$guid;LastDn=[string]$item.LastDn;ScopeDn=[string]$item.ScopeDn}) -Check $answer
            $store.Add((New-DomeniaAbsenceStoreRow -Resolution $resolution -Record (Get-DomeniaMember $answer 'Record' $null) -CheckedUtc $checkedUtc -Server ([string]$r.Server)))
            $label=([string]$resolution.Label).ToLowerInvariant()
            if($counts.ContainsKey($label)){$counts[$label]=[int]$counts[$label]+1}else{$counts[$label]=1}
        }
        if(-not $store.Count){throw 'Aucun résultat ne correspond aux objets demandés.'}
        $row=[pscustomobject]@{Results=$store.ToArray();Server=[string]$r.Server;At=$checkedUtc.ToString('o')}
        if(-not (Queue-DomeniaMetadata -Kind 'DirectoryAbsence' -Row $row -Key ('absences-'+[guid]::NewGuid().ToString('N')))){throw 'File dʼenregistrement locale indisponible : résultats non enregistrés.'}
        $parts=@($counts.Keys|Sort-Object|ForEach-Object{[string]$counts[$_]+' '+$_})
        [void](Set-DomeniaControlText 'LblSyncAbsences' ('Vérification terminée : '+($parts -join ', ')+'. Enregistrement local en attente de confirmation.'))
    }catch{[void](Set-DomeniaControlText 'LblSyncAbsences' ('Vérification non exploitable : '+$_.Exception.Message))}
}

function Fail-DomeniaAbsenceCheck {
    param($Message,$State)
    $s=$script:DomeniaDirectorySync
    if($null -ne $s){$s.CheckJob=''}
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Check')){return}
    [void](Set-DomeniaControlText 'LblSyncAbsences' ('Vérification impossible : '+[string]$Message+' Aucune conclusion ; les objets restent à vérifier.'))
}

function Complete-DomeniaDirectorySyncStorage {
    # Storage receipt (or failure) of a batch: verification results, snapshot changes, or an index update that may
    # have recorded new absences. The list is read again from the base, never patched from memory.
    param([object[]]$Items=@(),[bool]$Saved=$true,[string]$Message='')
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    $current=@(@($Items)|Where-Object{($null -ne $_) -and ([long]$_.Epoch -eq [long]$script:SessionEpoch) -and ([string]$_.Path -ceq [string]$script:DatabaseScopedPath)})
    $mine=@($current|Where-Object{[string]$_.Kind -in @('DirectoryAbsence','DirectorySnapshot')})
    $index=@($current|Where-Object{[string]$_.Kind -eq 'IndexBulk'})
    if((-not $mine.Count) -and (-not $index.Count)){return}
    if(-not $Saved){
        foreach($item in $mine){
            if([string]$item.Kind -eq 'DirectorySnapshot'){
                if([string]$item.Row.Action -eq 'Delete'){[void](Set-DomeniaControlText 'LblSnapshots' ('Relevé non supprimé : '+$Message+' Relancez la suppression.'))}
                else{[void](Set-DomeniaControlText 'LblSnapshots' ('Relevé non enregistré : '+$Message+' Il nʼest pas relancé automatiquement ; enregistrez-le de nouveau.'))}
            }
            elseif([string](Get-DomeniaMember $item.Row 'Source' '') -eq 'CensusGap'){[void](Set-DomeniaControlText 'LblSyncGaps' ('Objets lus non enregistrés : '+$Message+' Ils restent à lire.'))}
            else{[void](Set-DomeniaControlText 'LblSyncAbsences' ('Résultats de vérification non enregistrés : '+$Message+' Les objets restent à vérifier.'))}
        }
        return
    }
    $absences=@($mine|Where-Object{[string]$_.Kind -eq 'DirectoryAbsence'})
    foreach($item in @($mine|Where-Object{[string]$_.Kind -eq 'DirectorySnapshot'})){
        if([string]$item.Row.Action -eq 'Delete'){[void](Set-DomeniaControlText 'LblSnapshots' 'Relevé supprimé de la base locale.');continue}
        if(($null -ne $s.PendingSnapshot) -and ([string]$s.PendingSnapshot.Id -ceq [string]$item.Row.SnapshotId)){$s.PendingSnapshot.Committed=$true}
        [void](Set-DomeniaControlText 'LblSnapshots' ('Enregistrement local confirmé : vérification du relevé « '+[string]$item.Row.Label+' » dans la base…'))
    }
    foreach($item in @($absences|Where-Object{[string](Get-DomeniaMember $_.Row 'Source' '') -eq 'CensusGap'})){[void](Set-DomeniaControlText 'LblSyncGaps' 'Enregistrement local confirmé : la liste des objets manquants est relue dans la base…')}
    if($absences.Count){
        # Objects found again took their place in the local copy: counters and dashboards are read again, by the
        # LocalIndexRead worker (FI-19: no SQLite read on the Dispatcher); its answer refreshes the Base locale page.
        try{Request-DomeniaIndexMetadata}catch{Write-AppLog ('Base locale non relue : '+$_.Exception.Message) 'WARN'}
        $script:FleetStale=$true
    }
    if(($mine.Count -gt 0) -or (Test-DomeniaDirectorySyncVisible)){Request-DomeniaDirectorySyncRead}
}

# ---------------------------------------------------------------- point 30: directory snapshots
function Start-DomeniaSnapshotCapture {
    # Local copy of the chosen scope with its coverage proof. No directory read: update the scope first if needed.
    try{
        if($null -eq $script:DomeniaDirectorySync){return}
        if(-not [string]$script:DatabaseScopedPath){throw 'Base locale non ouverte.'}
        if(-not [string]$script:Conn.BaseDn){throw 'Connectez-vous à un domaine.'}
        if(@($script:DomeniaDirectorySync.Snapshots).Count -ge 50){throw '50 relevés au plus par domaine : supprimez un ancien relevé avant dʼen enregistrer un nouveau.'}
        $scope=Get-DomeniaIndexScope
        $scopeDn=if([bool]$scope.IsDomain){[string]$script:Conn.BaseDn}else{[string]$scope.BaseDn}
        $coverage=Get-DomeniaFleetFreshness -ScopeDn $(if([bool]$scope.IsDomain){''}else{$scopeDn}) -DomainDn ([string]$script:Conn.BaseDn) -SyncStates $script:IndexSyncStates
        $label=[string](Get-DomeniaControl 'TxtSnapshotLabel').Text
        $request=New-DomeniaSnapshotRequest -DomainDn ([string]$script:Conn.BaseDn) -ScopeDn $scopeDn -Subtree $true -Label $label -Coverage $coverage -SnapshotId ([guid]::NewGuid().ToString('N')) -NowUtc ([datetime]::UtcNow)
        # Size of the base when asked: the storage batch of this snapshot gets a time limit that follows it.
        $estimate=0L;try{$estimate=[long]$script:IndexDbCount}catch{$estimate=0L}
        $request|Add-Member -NotePropertyName ObjectEstimate -NotePropertyValue $(if($estimate -gt 0){$estimate}else{300000L}) -Force
        if(-not (Queue-DomeniaMetadata -Kind 'DirectorySnapshot' -Row $request -Key ('snapshot-'+[string]$request.SnapshotId))){throw 'File dʼenregistrement locale indisponible.'}
        $script:DomeniaDirectorySync.PendingSnapshot=[pscustomobject]@{Id=[string]$request.SnapshotId;Label=[string]$request.Label;Committed=$false}
        [void](Set-DomeniaControlText 'LblSnapshots' ('Relevé « '+[string]$request.Label+' » en cours dʼenregistrement. '+[string]$request.CoverageText))
        [void](Set-DomeniaControlText 'TxtSnapshotLabel' '')
    }catch{[void](Set-DomeniaControlText 'LblSnapshots' ('Relevé non enregistré : '+$_.Exception.Message))}
}

function Update-DomeniaSnapshotButtons {
    $selected=(Get-DomeniaControl 'DgSnapshots').SelectedItem
    $delete=Get-DomeniaControl 'BtnSnapshotDelete';if($null -ne $delete){$delete.IsEnabled=($null -ne $selected)}
    $check=Get-DomeniaControl 'BtnSyncAbsencesCheck'
    if(($null -ne $check) -and ($null -ne $script:DomeniaDirectorySync)){$check.IsEnabled=((@(Select-DomeniaAbsencesToCheck -Rows @($script:DomeniaDirectorySync.Absences) -Limit 200).Count -gt 0) -and (-not [bool]$script:DemoMode))}
    $gapRead=Get-DomeniaControl 'BtnSyncGapRead'
    if(($null -ne $gapRead) -and ($null -ne $script:DomeniaDirectorySync)){$gapRead.IsEnabled=((@($script:DomeniaDirectorySync.Gaps).Count -gt 0) -and (-not [bool]$script:DemoMode) -and (-not [string]$script:DomeniaDirectorySync.GapJob))}
}

function Update-DomeniaSnapshotChoices {
    # Keeps the chosen snapshots when they still exist; otherwise proposes the two most recent of the same scope.
    $s=$script:DomeniaDirectorySync
    $before=Get-DomeniaControl 'CmbSnapshotBefore';$after=Get-DomeniaControl 'CmbSnapshotAfter'
    if(($null -eq $s) -or ($null -eq $before) -or ($null -eq $after)){return}
    $oldBefore='';$oldAfter=''
    if($null -ne $before.SelectedItem){$oldBefore=[string]$before.SelectedItem.SnapshotId}
    if($null -ne $after.SelectedItem){$oldAfter=[string]$after.SelectedItem.SnapshotId}
    $rows=@($s.Snapshots)
    $before.ItemsSource=@($rows);$after.ItemsSource=@($rows)
    $pickAfter=@($rows|Where-Object{[string]$_.SnapshotId -ceq $oldAfter}|Select-Object -First 1)
    $pickBefore=@($rows|Where-Object{[string]$_.SnapshotId -ceq $oldBefore}|Select-Object -First 1)
    if((-not $pickAfter.Count) -and ($rows.Count -gt 0)){$pickAfter=@($rows[0])}
    if((-not $pickBefore.Count) -and ($pickAfter.Count -gt 0)){$pickBefore=@($rows|Where-Object{([string]$_.SnapshotId -cne [string]$pickAfter[0].SnapshotId) -and ([string]$_.ScopeDn -ieq [string]$pickAfter[0].ScopeDn)}|Select-Object -First 1)}
    $after.SelectedItem=$(if($pickAfter.Count){$pickAfter[0]}else{$null})
    $before.SelectedItem=$(if($pickBefore.Count){$pickBefore[0]}else{$null})
}

function Request-DomeniaSnapshotDelete {
    $row=(Get-DomeniaControl 'DgSnapshots').SelectedItem
    if($null -eq $row){[void](Set-DomeniaControlText 'LblSnapshots' 'Choisissez dʼabord un relevé.');return}
    # The confirmation runs a named function on the identifier kept here; a newer request replaces it.
    $script:DomeniaSnapshotDeleteId=[string]$row.SnapshotId
    $message='Le relevé « '+[string]$row.Label+' » ('+[string]$row.DateText+', '+[string]$row.ObjectCount+' objets) sera supprimé de la base locale. Lʼannuaire nʼest pas concerné.'
    [void](Request-DomeniaInlineConfirmation -Title 'Supprimer un relevé' -Message $message -Target ('releve:'+[string]$row.SnapshotId) -Risk 'Danger' -OnConfirm {Remove-DomeniaSnapshot} -OnCancel {$script:DomeniaSnapshotDeleteId=''})
}

function Remove-DomeniaSnapshot {
    $id=[string]$script:DomeniaSnapshotDeleteId;$script:DomeniaSnapshotDeleteId=''
    if($id -cnotmatch '^[a-f0-9]{32}$'){return}
    try{
        if(-not (Queue-DomeniaMetadata -Kind 'DirectorySnapshot' -Row ([pscustomobject]@{Action='Delete';SnapshotId=$id}) -Key ('snapshot-delete-'+$id))){throw 'File dʼenregistrement locale indisponible.'}
        [void](Set-DomeniaControlText 'LblSnapshots' 'Suppression du relevé en attente de confirmation locale.')
    }catch{[void](Set-DomeniaControlText 'LblSnapshots' ('Relevé non supprimé : '+$_.Exception.Message))}
}

function Start-DomeniaSnapshotCompare {
    $s=$script:DomeniaDirectorySync
    if($null -eq $s){return}
    $before=(Get-DomeniaControl 'CmbSnapshotBefore').SelectedItem;$after=(Get-DomeniaControl 'CmbSnapshotAfter').SelectedItem
    $check=Test-DomeniaSnapshotComparable $before $after
    if(-not [bool]$check.Comparable){[void](Set-DomeniaControlText 'LblSnapshotCompare' ('Comparaison impossible : '+(@($check.Reasons) -join ' ')));return}
    $path=[string]$script:DatabaseScopedPath
    if(-not $path){[void](Set-DomeniaControlText 'LblSnapshotCompare' 'Base locale non ouverte.');return}
    $s.CompareGeneration=[long]$s.CompareGeneration+1
    $state=[pscustomobject]@{Generation=[long]$s.CompareGeneration;Epoch=[long]$script:SessionEpoch;Path=$path;Before=$before;After=$after}
    $payload=[pscustomobject]@{Action='SnapshotCompare';Path=$path;DomainDn=[string]$script:Conn.BaseDn;Before=[string]$before.SnapshotId;After=[string]$after.SnapshotId;Limit=500}
    try{
        $job=Start-UiTask -Name 'Comparaison de relevés' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaSnapshotCompare' -ErrorHandler 'Fail-DomeniaSnapshotCompare' -DisableControls @('BtnSnapshotCompare') -ReplaceKey 'snapshot-compare' -TimeoutSeconds 180 -TaskClass 'Explicit'
        if(-not $job){throw 'Comparaison non admise par le moteur.'}
        [void](Set-DomeniaItemsSource 'DgSnapshotDiff' @())
        [void](Set-DomeniaControlText 'LblSnapshotCompare' 'Comparaison dans la base locale en cours…')
    }catch{[void](Set-DomeniaControlText 'LblSnapshotCompare' ('Comparaison non lancée : '+$_.Exception.Message))}
}

function Complete-DomeniaSnapshotCompare {
    param($Result,$State)
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Compare')){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Busy')
        if($null -eq $r){throw 'Réponse locale absente.'}
        if([bool]$r.Busy){[void](Set-DomeniaControlText 'LblSnapshotCompare' 'Base locale occupée : relancez la comparaison dans un instant.');return}
        if([bool](Get-DomeniaMember $r 'Missing' $false)){throw 'Base locale absente.'}
        if([string](Get-DomeniaMember $r 'DataSource' '') -cne 'SQLite'){throw 'Réponse locale non confirmée par SQLite.'}
        if(-not [bool](Get-DomeniaMember $r 'Found' $false)){throw 'Un des relevés nʼexiste plus : actualisez la liste.'}
        $report=ConvertTo-DomeniaSnapshotReport -Result $r -Before $State.Before -After $State.After
        [void](Set-DomeniaItemsSource 'DgSnapshotDiff' @($report.Rows))
        [void](Set-DomeniaControlText 'LblSnapshotCompare' ([string]$report.Summary))
    }catch{[void](Set-DomeniaControlText 'LblSnapshotCompare' ('Comparaison non exploitable : '+$_.Exception.Message))}
}

function Fail-DomeniaSnapshotCompare {
    param($Message,$State)
    if(-not (Test-DomeniaDirectorySyncStateCurrent $State 'Compare')){return}
    [void](Set-DomeniaControlText 'LblSnapshotCompare' ('Comparaison impossible : '+[string]$Message))
}
