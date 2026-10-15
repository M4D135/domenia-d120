function Initialize-DomeniaQueryTransferUi {
    foreach($entry in @(@('BtnQueryPackExport','ExportPack'),@('BtnQueryScriptExport','ExportPowerShell'),@('BtnQueryPackImport','ImportPreview'),@('BtnQueryImportApply','Apply'),@('BtnQueryImportNew','SelectNew'),@('BtnQueryImportRollback','Rollback'))){
        $control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($sender,$args)Invoke-DomeniaQueryTransfer ([string]$sender.Tag)})}
    }
    $grid=Get-DomeniaControl 'DgQueryImport';if($null -ne $grid){$grid.Add_SelectionChanged({Show-DomeniaQueryImportChanges})}
    $history=Get-DomeniaControl 'CmbQueryImportHistory';if($null -ne $history){$history.Add_SelectionChanged({Update-DomeniaQueryImportHistoryControls})}
    $expander=Get-DomeniaControl 'ExpQueryTransfer';if($null -ne $expander){$expander.Add_Expanded({Request-DomeniaQueryImportHistory})}
}
function Get-DomeniaQueryImportJournalPath {
    # Local journal beside the scoped database, like the relation journal: never in the repository or a share.
    param($Store)
    return ([string]$Store.Context.Path+'.query-imports.jsonl')
}
function Invoke-DomeniaQueryTransfer {
    param([string]$Action)
    try{
        $store=Initialize-DomeniaQueryLibraryStore;if($null -eq $store -or -not $store.Loaded -or $store.Saving){throw 'Attendez la disponibilité de la bibliothèque locale.'}
        if($Action -eq 'SelectNew'){foreach($item in @((Get-DomeniaControl 'DgQueryImport').ItemsSource)){if($item.Status -eq 'Nouvelle'){$item.Action='Créer'}};(Get-DomeniaControl 'DgQueryImport').Items.Refresh();return}
        if($Action -in @('Apply','Rollback')){Start-DomeniaQueryImport -Rollback:($Action -eq 'Rollback');return}
        $packName='';$packVersion=0L
        if($Action -eq 'ExportPack'){
            if(-not @($store.Recipes).Count){throw 'Aucune requête personnelle à exporter.'}
            $packName=([string](Get-DomeniaControl 'TxtQueryPackName').Text).Trim()
            if(-not [long]::TryParse(([string](Get-DomeniaControl 'TxtQueryPackVersion').Text).Trim(),[ref]$packVersion)){throw 'Version de pack invalide (nombre entier de 1 à 1 000 000).'}
            Assert-DomeniaQueryPackIdentity -PackName $packName -PackVersion $packVersion
        }
        $path=Select-DomeniaQueryTransferPath -Action $Action -PackVersion $packVersion
        if(-not $path){return}
        [void](Start-DomeniaQueryTransferTask -Action $Action -Path $path -PackName $packName -PackVersion $packVersion)
    }catch{[void](Set-DomeniaControlText 'LblQueryImportStatus' $_.Exception.Message)}
}
function Select-DomeniaQueryTransferPath {
    # The operator names the file: an existing pack to examine, or a new pack or script to create. '' when cancelled.
    param([string]$Action,[long]$PackVersion=0)
    $dialog=if($Action -eq 'ImportPreview'){New-Object Microsoft.Win32.OpenFileDialog}else{New-Object Microsoft.Win32.SaveFileDialog}
    $dialog.Filter=if($Action -eq 'ExportPowerShell'){'Script PowerShell (*.ps1)|*.ps1'}else{'Pack de requêtes (*.json)|*.json'}
    if($Action -ne 'ImportPreview'){$dialog.FileName=if($Action -eq 'ExportPowerShell'){'Domenia-requete.ps1'}else{'Domenia-requetes-v'+[string]$PackVersion+'.json'}}
    if(-not $dialog.ShowDialog()){return ''}
    return [string]$dialog.FileName
}
function Start-DomeniaQueryTransferTask {
    # Point 69: export of a versioned pack or of a script, or preview of a pack, by the pinned QueryTransfer worker
    # (local files only, no network, nothing executed). The callback is bound to this library store and generation.
    param([Parameter(Mandatory=$true)][ValidateSet('ExportPack','ExportPowerShell','ImportPreview')][string]$Action,[Parameter(Mandatory=$true)][string]$Path,[string]$PackName='',[long]$PackVersion=0)
    $store=$script:DomeniaQueryLibraryStoreState
    if(($null -eq $store) -or (-not [bool]$store.Loaded) -or ([bool]$store.Saving)){throw 'Attendez la disponibilité de la bibliothèque locale.'}
    $q=$script:DomeniaQueryState
    $history=@(@(Get-DomeniaMember $q 'ImportHistory' @())|ForEach-Object{[pscustomobject]@{PackId=[string]$_.PackId;PackVersion=[long]$_.PackVersion}})
    $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Mode=$Action;Path=$Path;Context=$store.Context;ExistingRows=@($store.Rows.Values);Recipes=@($store.Recipes);Recipe=$(if($Action -eq 'ExportPowerShell'){Get-DomeniaQueryDraft}else{$null});PackName=$PackName;PackVersion=$PackVersion;History=$history}
    $state=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation}
    # Said before the start: a callback that answers at once (refusal, short file) keeps the last word.
    [void](Set-DomeniaControlText 'LblQueryImportStatus' 'Préparation locale du transfert…')
    $job=Start-UiTask -Name 'Transfert de requêtes' -OperationId 'QueryTransfer' -Code (Get-DomeniaQueryTransferWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaQueryTransfer' -ErrorHandler 'Fail-DomeniaQueryTransfer' -TimeoutSeconds 120 -TaskClass Explicit
    if(-not $job){throw 'Transfert non admis.'}
    return $job
}
function Format-DomeniaQueryImportPackText {
    param($Plan)
    $origin=if([string]$Plan.Origin){[string]$Plan.Origin}else{'non déclarée'}
    if(-not [bool]$Plan.Verified){return 'Pack sans version (format 1) : intégrité non vérifiable · provenance déclarée : '+$origin+'.'}
    $at=ConvertFrom-DomeniaUtcText ([string]$Plan.ExportedAtUtc)
    $text='Pack « '+[string]$Plan.PackName+' » version '+[string]$Plan.PackVersion+' · empreinte du contenu vérifiée'+$(if($null -ne $at){' · exporté le '+$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{''})+' · provenance déclarée : '+$origin+'.'
    if([long]$Plan.PreviousVersion -gt 0){$text+=' Version déjà importée dans cette base : '+[string]$Plan.PreviousVersion+$(if([long]$Plan.PreviousVersion -ge [long]$Plan.PackVersion){' (ce pack nʼest pas plus récent).'}else{'.'})}
    return $text
}
function Complete-DomeniaQueryTransfer {
    param($Result,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $packet=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Mode','Path');if($null -eq $packet){Fail-DomeniaQueryTransfer 'Résultat de transfert incomplet.' $State;return}
    $q=$script:DomeniaQueryState
    switch([string]$packet.Mode){
        'ImportPreview'{
            $plan=$packet.Plan
            if($plan.StoreId -cne $State.StoreId){Fail-DomeniaQueryTransfer 'Le pack ne vise pas cette base.' $State;return}
            $q|Add-Member NoteProperty ImportPlan $plan -Force
            (Get-DomeniaControl 'DgQueryImport').ItemsSource=@($plan.Items)
            [void](Set-DomeniaControlText 'LblQueryImportPack' (Format-DomeniaQueryImportPackText $plan))
            [void](Set-DomeniaControlText 'LblQueryImportStatus' (@($plan.Items).Count.ToString()+' recette(s) dans le pack. Sélectionnez une ligne pour voir ses différences, puis choisissez explicitement les créations ou remplacements. Aucune recette nʼest importée pour le moment.'))
        }
        'JournalRead'{
            # Durable entries replace the list; imports of this session not yet journaled stay available.
            $read=@($packet.Entries);$ids=@{};foreach($entry in $read){$ids[[string]$entry.ImportId]=$true}
            $session=@(@(Get-DomeniaMember $q 'ImportHistory' @())|Where-Object{([string]$_.StoreId -ceq [string]$State.StoreId) -and -not $ids.ContainsKey([string]$_.ImportId) -and -not [bool](Get-DomeniaMember $_ 'Journaled' $false)})
            $q|Add-Member NoteProperty ImportHistory (@($session)+@($read)) -Force
            $q|Add-Member NoteProperty ImportHistoryLoaded ([string]$State.StoreId) -Force
            Update-DomeniaQueryImportHistoryList
            if([int]$packet.Rejected -gt 0){[void](Set-DomeniaControlText 'LblQueryImportStatus' ([string]$packet.Rejected+' ligne(s) illisible(s) ignorée(s) dans le journal local des imports.'))}
        }
        'JournalAppend'{
            if(-not [bool]$packet.Journaled){[void](Set-DomeniaControlText 'LblQueryImportPack' ('Retour arrière disponible pendant cette session seulement : '+[string]$packet.Reason+'.'))}
            else{foreach($entry in @(Get-DomeniaMember $q 'ImportHistory' @())){if([string]$entry.ImportId -ceq [string](Get-DomeniaMember $State 'ImportId' '')){$entry|Add-Member NoteProperty Journaled $true -Force}}}
        }
        default{
            if([string]$packet.Mode -eq 'ExportPack'){
                $next=[long]$packet.PackVersion+1;$version=Get-DomeniaControl 'TxtQueryPackVersion';if($null -ne $version -and $next -le 1000000){$version.Text=[string]$next}
                [void](Set-DomeniaControlText 'LblQueryImportStatus' ('Pack version '+[string]$packet.PackVersion+' créé : '+$packet.Path+'. La prochaine diffusion du même pack portera la version '+[string]$next+'. Aucun script exécuté.'))
            }else{[void](Set-DomeniaControlText 'LblQueryImportStatus' ('Fichier créé : '+$packet.Path+'. Aucun script exécuté.'))}
        }
    }
}
function Fail-DomeniaQueryTransfer {param($Message,$State)if(Test-DomeniaQueryLibraryStoreState $State){[void](Set-DomeniaControlText 'LblQueryImportStatus' ('Transfert interrompu : '+[string]$Message))}}
function Show-DomeniaQueryImportChanges {
    $row=(Get-DomeniaControl 'DgQueryImport').SelectedItem;$grid=Get-DomeniaControl 'DgQueryImportChanges'
    if($null -ne $grid){$grid.ItemsSource=@(if($null -ne $row){@($row.Changes)})}
}
function Request-DomeniaQueryImportHistory {
    # Reads the local journal once per store; a later import updates the list in memory immediately.
    Close-DomeniaQueryStaleImportRun
    $store=$script:DomeniaQueryLibraryStoreState;$q=$script:DomeniaQueryState
    if($null -eq $store -or -not $store.Loaded -or $null -eq $q -or [string](Get-DomeniaMember $q 'ImportHistoryLoaded' '') -ceq [string]$store.Context.StoreId){return}
    $state=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation}
    try{
        $job=Start-UiTask -Name 'Lire le journal des imports de requêtes' -OperationId 'QueryTransfer' -Code (Get-DomeniaQueryTransferWorkerCode) -Payload ([pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Mode='JournalRead';Path=(Get-DomeniaQueryImportJournalPath $store);StoreId=$store.Context.StoreId}) -CallbackState $state -SuccessHandler 'Complete-DomeniaQueryTransfer' -ErrorHandler 'Fail-DomeniaQueryTransfer' -TimeoutSeconds 60 -TaskClass Explicit
        if(-not $job){throw 'lecture non admise.'}
    }catch{[void](Set-DomeniaControlText 'LblQueryImportStatus' ('Journal des imports non lu : '+$_.Exception.Message))}
}
function Update-DomeniaQueryImportHistoryList {
    $combo=Get-DomeniaControl 'CmbQueryImportHistory';if($null -eq $combo){return}
    # Only the imports of the database in use are offered; another database keeps its own journal.
    $store=$script:DomeniaQueryLibraryStoreState;$storeId=if($null -ne $store){[string]$store.Context.StoreId}else{''}
    $entries=@(@(Get-DomeniaMember $script:DomeniaQueryState 'ImportHistory' @())|Where-Object{(-not $storeId) -or ([string]$_.StoreId -ceq $storeId)})
    $combo.ItemsSource=$entries;$combo.SelectedIndex=$(if($entries.Count){0}else{-1})
    Update-DomeniaQueryImportHistoryControls
}
function Update-DomeniaQueryImportHistoryControls {
    $button=Get-DomeniaControl 'BtnQueryImportRollback';if($null -eq $button){return}
    $combo=Get-DomeniaControl 'CmbQueryImportHistory';$entry=if($null -ne $combo){$combo.SelectedItem}else{$null};$run=Get-DomeniaMemberValue $script:DomeniaQueryState 'ImportRun'
    $button.IsEnabled=(($null -ne $entry) -and [bool](Get-DomeniaMember $entry 'Restorable' $false) -and -not (Test-DomeniaQueryImportRunActive $run))
}
function Test-DomeniaQueryImportRunActive {
    # A run belongs to the library store it started on. After a new session or a database switch the engine drops
    # its callbacks, so it can no longer finish and must not block a later import or rollback.
    param($Run)
    return (($null -ne $Run) -and [bool]$Run.Running -and (Test-DomeniaQueryLibraryStoreState $Run))
}
function Close-DomeniaQueryStaleImportRun {
    # Ends a run whose callbacks were dropped. Its confirmed writes are journaled beside their own database so they
    # stay restorable; the write in flight is not replayed and its outcome is read again from the database.
    $q=$script:DomeniaQueryState;$run=Get-DomeniaMemberValue $q 'ImportRun'
    if(($null -eq $run) -or -not [bool]$run.Running -or (Test-DomeniaQueryLibraryStoreState $run)){return}
    $run.Running=$false;$run.Error='session ou base locale changée pendant les écritures'
    Save-DomeniaQueryImportJournal $run
}
function Format-DomeniaQueryImportStopText {
    param($Run,[string]$Message)
    $done=[int]$Run.Applied.Count;$left=[Math]::Max(0,@($Run.Items).Count-[int]$Run.Index)
    if([bool]$Run.Rollback){return ('Restauration arrêtée après '+$done+' confirmation(s) : '+$Message.TrimEnd('.')+'.'+$(if($done){' Les '+$left+' recette(s) non restaurées restent proposées dans lʼhistorique des imports.'}else{''}))}
    return ('Import arrêté après '+$done+' confirmation(s) : '+$Message.TrimEnd('.')+'.'+$(if($done){' Les écritures confirmées peuvent être restaurées.'}else{''}))
}
function Start-DomeniaQueryImport {
    param([switch]$Rollback)
    Close-DomeniaQueryStaleImportRun
    $q=$script:DomeniaQueryState;$store=$script:DomeniaQueryLibraryStoreState;$items=[Collections.Generic.List[object]]::new();$plan=$null;$source=$null
    if(Test-DomeniaQueryImportRunActive (Get-DomeniaMemberValue $q 'ImportRun')){throw 'Un import ou une restauration est déjà en cours.'}
    if($Rollback){
        $source=(Get-DomeniaControl 'CmbQueryImportHistory').SelectedItem
        if($null -eq $source -or [string]$source.StoreId -cne $store.Context.StoreId -or -not [bool](Get-DomeniaMember $source 'Restorable' $false)){throw 'Choisissez un import restaurable de cette base.'}
        foreach($change in @($source.Items|Sort-Object Sequence -Descending)){
            $current=$store.Rows[[string]$change.Id]
            if($null -eq $current -or [long]$current.Revision -ne [long]$change.Revision){throw 'Une recette importée a été modifiée depuis. Restauration globale refusée pour préserver cette modification.'}
            $before=Get-DomeniaMemberValue $change 'Before'
            # Source keeps the journal item: an interrupted rollback journals the items it did not reach.
            $items.Add([pscustomobject]@{Id=[string]$change.Id;ExpectedRevision=[long]$change.Revision;Recipe=$(if($null -ne $before){ConvertFrom-Json -InputObject ([string]$before.DefinitionJson) -ErrorAction Stop}else{ConvertFrom-Json -InputObject ([string]$current.DefinitionJson) -ErrorAction Stop});Archive=($null -eq $before -or [bool]$before.Archived);Before=$current;Category=$(if($null -ne $before){[string]$before.Category}else{''});Source=$change})
        }
    }else{
        $plan=Get-DomeniaMemberValue $q 'ImportPlan';if($null -eq $plan -or $plan.StoreId -cne $store.Context.StoreId){throw 'Préparez un aperçu du pack pour cette base.'}
        $category=if([string]$plan.PackName){'Import · '+[string]$plan.PackName}else{'Import de pack'};if($category.Length -gt 80){$category=$category.Substring(0,80)}
        $grid=Get-DomeniaControl 'DgQueryImport';[void]$grid.CommitEdit()
        foreach($choice in @($grid.ItemsSource)){
            if($choice.Action -eq 'Ignorer'){continue};if($choice.Action -notin $choice.AllowedActions){throw 'Choix d''import non autorisé.'}
            $recipe=ConvertFrom-Json -InputObject $choice.After.DefinitionJson
            $expected=[long]$choice.ExpectedRevision;$before=$choice.Before;$target=''
            if($choice.Action -eq 'Nouvelle copie'){$recipe=Copy-DomeniaQueryRecipe $recipe -Id ([guid]::NewGuid().ToString('N'));$expected=0L;$before=$null}
            if($null -eq $before){$target=$category}
            $items.Add([pscustomobject]@{Id=$recipe.Id;ExpectedRevision=$expected;Recipe=$recipe;Archive=$false;Before=$before;Category=$target})
        }
    }
    if(-not $items.Count){throw 'Aucune modification sélectionnée.'}
    $details=($items|Select-Object -First 20|ForEach-Object{$_.Recipe.Name+' · révision attendue '+$_.ExpectedRevision}) -join "`r`n"
    $answer=Show-DomeniaDialog -Title $(if($Rollback){'Restaurer avant l''import'}else{'Importer les recettes choisies'}) -Message ($items.Count.ToString()+' modification(s) dans la bibliothèque. Chaque écriture vérifie sa révision. Le journal local conserve les définitions remplacées pour permettre un retour arrière, y compris après un redémarrage. Aucune requête nʼest exécutée.') -Details $details -Kind Question -Buttons YesNo
    if([string]$answer -ne 'Yes'){return}
    # The run keeps its own store context and journal path: its journal line never lands beside another database.
    $run=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation;Context=$store.Context;JournalPath=(Get-DomeniaQueryImportJournalPath $store);Items=$items.ToArray();Index=0;Applied=[Collections.Generic.List[object]]::new();Running=$true;Rollback=[bool]$Rollback;Error='';Plan=$(if($Rollback){$source}else{$plan});SourceImportId=$(if($Rollback){[string]$source.ImportId}else{''})}
    $q|Add-Member NoteProperty ImportRun $run -Force
    Update-DomeniaQueryImportHistoryControls
    Submit-DomeniaQueryImportNext $run
}
function Submit-DomeniaQueryImportNext {
    param($Run)
    if(-not (Test-DomeniaQueryLibraryStoreState $Run)){return}
    if($Run.Index -ge $Run.Items.Count){
        $Run.Running=$false;Save-DomeniaQueryImportJournal $Run
        [void](Set-DomeniaControlText 'LblQueryImportStatus' ($Run.Index.ToString()+' recette(s) '+$(if([bool]$Run.Rollback){'restaurée(s)'}else{'confirmée(s)'})+' par la base. Les révisions précédentes sont conservées.'))
        return
    }
    try{
        $item=$Run.Items[$Run.Index];$current=$script:DomeniaQueryLibraryStoreState.Rows[[string]$item.Id];$revision=if($null -ne $current){[long]$current.Revision}else{0L}
        if($revision -ne [long]$item.ExpectedRevision){throw ('La recette '+$item.Recipe.Name+' a changé depuis l''aperçu. Repréparez l''import.')}
        [void](Save-DomeniaQueryRecipe -Recipe $item.Recipe -Archive:([bool]$item.Archive) -Category ([string](Get-DomeniaMember $item 'Category' '')) -SuccessHandler 'Complete-DomeniaQueryImportItem' -ErrorHandler 'Fail-DomeniaQueryImportItem' -CallbackState $Run)
        [void](Set-DomeniaControlText 'LblQueryImportStatus' ('Enregistrement '+($Run.Index+1)+' / '+$Run.Items.Count+'…'))
    }catch{$Run.Running=$false;$Run.Error=$_.Exception.Message;Save-DomeniaQueryImportJournal $Run;[void](Set-DomeniaControlText 'LblQueryImportStatus' (Format-DomeniaQueryImportStopText -Run $Run -Message $Run.Error))}
}
function Complete-DomeniaQueryImportItem {
    param($Recipe,$Record,$State)
    $run=$State;if(-not (Test-DomeniaQueryLibraryStoreState $run)){return}
    $item=$run.Items[$run.Index]
    $run.Applied.Add([pscustomobject]@{Id=$Record.Id;Name=[string]$Record.Name;Revision=[long]$Record.Revision;Before=$item.Before;Sequence=$run.Index})
    $run.Index++;Submit-DomeniaQueryImportNext $run
}
function Fail-DomeniaQueryImportItem {
    param($Message,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $State.Running=$false;$State.Error=[string]$Message;Save-DomeniaQueryImportJournal $State
    [void](Set-DomeniaControlText 'LblQueryImportStatus' (Format-DomeniaQueryImportStopText -Run $State -Message ([string]$Message)))
}
function Save-DomeniaQueryImportJournal {
    # Confirmed writes become restorable at once in memory, then durably in the local journal (worker, no network).
    # A rollback hides its source import; when it stopped early, the items it did not restore stay offered.
    param($Run)
    if($null -eq $Run -or -not $Run.Applied.Count -or [bool](Get-DomeniaMember $Run 'Journaled' $false)){Update-DomeniaQueryImportHistoryControls;return}
    $Run|Add-Member -NotePropertyName Journaled -NotePropertyValue $true -Force
    $q=$script:DomeniaQueryState
    $remaining=@(if([bool]$Run.Rollback){for($index=[int]$Run.Index;$index -lt @($Run.Items).Count;$index++){Get-DomeniaMemberValue $Run.Items[$index] 'Source'}})
    $entry=New-DomeniaQueryImportJournalEntry -Context $Run.Context -Applied @($Run.Applied) -Plan $Run.Plan -RollsBack ([string]$Run.SourceImportId) -Remaining $remaining
    $history=@(Get-DomeniaMember $q 'ImportHistory' @())
    if([string]$entry.Kind -ceq 'Rollback'){$history=@($history|Where-Object{[string]$_.ImportId -cne [string]$Run.SourceImportId})}
    $point=New-DomeniaQueryImportRestorePoint -Entry $entry -Trusted
    if([bool]$point.Restorable){$point|Add-Member -NotePropertyName Journaled -NotePropertyValue $false -Force;$history=@($point)+$history}
    $q|Add-Member NoteProperty ImportHistory $history -Force
    Update-DomeniaQueryImportHistoryList
    $state=[pscustomobject]@{StoreId=[string]$Run.StoreId;Epoch=$Run.Epoch;Generation=$Run.Generation;ImportId=[string]$entry.ImportId}
    try{
        $job=Start-UiTask -Name 'Journaliser lʼimport de requêtes' -OperationId 'QueryTransfer' -Code (Get-DomeniaQueryTransferWorkerCode) -Payload ([pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Mode='JournalAppend';Path=[string]$Run.JournalPath;Entry=$entry}) -CallbackState $state -SuccessHandler 'Complete-DomeniaQueryTransfer' -ErrorHandler 'Fail-DomeniaQueryTransfer' -TimeoutSeconds 60 -TaskClass Explicit
        if(-not $job){throw 'écriture du journal non admise.'}
    }catch{[void](Set-DomeniaControlText 'LblQueryImportPack' ('Retour arrière disponible pendant cette session seulement : '+$_.Exception.Message))}
}
