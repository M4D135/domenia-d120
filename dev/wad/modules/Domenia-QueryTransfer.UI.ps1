function Initialize-DomeniaQueryTransferUi {
    foreach($entry in @(@('BtnQueryPackExport','ExportPack'),@('BtnQueryScriptExport','ExportPowerShell'),@('BtnQueryPackImport','ImportPreview'),@('BtnQueryImportApply','Apply'),@('BtnQueryImportNew','SelectNew'),@('BtnQueryImportRollback','Rollback'))){
        $control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($sender,$args)Invoke-DomeniaQueryTransfer ([string]$sender.Tag)})}
    }
}
function Invoke-DomeniaQueryTransfer {
    param([string]$Action)
    try{
        $store=Initialize-DomeniaQueryLibraryStore;if($null -eq $store -or -not $store.Loaded -or $store.Saving){throw 'Attendez la disponibilité de la bibliothèque locale.'}
        $q=$script:DomeniaQueryState
        if($Action -eq 'SelectNew'){foreach($item in @((Get-DomeniaControl 'DgQueryImport').ItemsSource)){if($item.Status -eq 'Nouvelle'){$item.Action='Créer'}};(Get-DomeniaControl 'DgQueryImport').Items.Refresh();return}
        if($Action -in @('Apply','Rollback')){Start-DomeniaQueryImport -Rollback:($Action -eq 'Rollback');return}
        $dialog=if($Action -eq 'ImportPreview'){New-Object Microsoft.Win32.OpenFileDialog}else{New-Object Microsoft.Win32.SaveFileDialog}
        $dialog.Filter=if($Action -eq 'ExportPowerShell'){'Script PowerShell (*.ps1)|*.ps1'}else{'Pack de requêtes (*.json)|*.json'}
        if($Action -ne 'ImportPreview'){$dialog.FileName=if($Action -eq 'ExportPowerShell'){'Domenia-requete.ps1'}else{'Domenia-requetes.json'}}
        if(-not $dialog.ShowDialog()){return}
        $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Mode=$Action;Path=$dialog.FileName;Context=$store.Context;ExistingRows=@($store.Rows.Values);Recipes=@($store.Recipes);Recipe=$(if($Action -eq 'ExportPowerShell'){Get-DomeniaQueryDraft}else{$null})}
        $state=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation}
        $job=Start-UiTask -Name 'Transfert de requêtes' -OperationId 'QueryTransfer' -Code (Get-DomeniaQueryTransferWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaQueryTransfer' -ErrorHandler 'Fail-DomeniaQueryTransfer' -TimeoutSeconds 120 -TaskClass Explicit
        if(-not $job){throw 'Transfert non admis.'}
        [void](Set-DomeniaControlText 'LblQueryImportStatus' 'Préparation locale du transfert…')
    }catch{[void](Set-DomeniaControlText 'LblQueryImportStatus' $_.Exception.Message)}
}
function Complete-DomeniaQueryTransfer {
    param($Result,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $packet=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Mode','Path');if($null -eq $packet){Fail-DomeniaQueryTransfer 'Résultat de transfert incomplet.' $State;return}
    if($packet.Mode -eq 'ImportPreview'){
        $plan=$packet.Plan
        if($plan.StoreId -cne $State.StoreId){Fail-DomeniaQueryTransfer 'Le pack ne vise pas cette base.' $State;return}
        $script:DomeniaQueryState|Add-Member NoteProperty ImportPlan $plan -Force
        (Get-DomeniaControl 'DgQueryImport').ItemsSource=@($plan.Items)
        [void](Set-DomeniaControlText 'LblQueryImportStatus' ($plan.Items.Count.ToString()+' recettes dans le pack · provenance déclarée : '+$plan.Origin+'. Choisissez explicitement les créations ou remplacements. Aucune recette n’est importée pour le moment.'))
    }else{[void](Set-DomeniaControlText 'LblQueryImportStatus' ('Fichier créé : '+$packet.Path+'. Aucun script exécuté.'))}
}
function Fail-DomeniaQueryTransfer {param($Message,$State)if(Test-DomeniaQueryLibraryStoreState $State){[void](Set-DomeniaControlText 'LblQueryImportStatus' ('Transfert interrompu : '+[string]$Message))}}
function Start-DomeniaQueryImport {
    param([switch]$Rollback)
    $q=$script:DomeniaQueryState;$store=$script:DomeniaQueryLibraryStoreState;$items=[Collections.Generic.List[object]]::new()
    if($Rollback){
        $previous=Get-DomeniaMemberValue $q 'ImportRun'
        if($null -eq $previous -or $previous.StoreId -cne $store.Context.StoreId -or $previous.Running -or -not $previous.Applied.Count){throw 'Aucun import de cette session ne peut être annulé.'}
        foreach($change in @($previous.Applied|Sort-Object Sequence -Descending)){
            $current=$store.Rows[[string]$change.Id]
            if($null -eq $current -or [long]$current.Revision -ne [long]$change.Revision){throw 'Une recette importée a été modifiée depuis. Restauration globale refusée pour préserver cette modification.'}
            $items.Add([pscustomobject]@{Id=$change.Id;ExpectedRevision=[long]$change.Revision;Recipe=$(if($null -ne $change.Before){ConvertFrom-Json $change.Before.DefinitionJson}else{ConvertFrom-Json $current.DefinitionJson});Archive=($null -eq $change.Before -or [bool]$change.Before.Archived);Before=$current})
        }
    }else{
        $plan=Get-DomeniaMemberValue $q 'ImportPlan';if($null -eq $plan -or $plan.StoreId -cne $store.Context.StoreId){throw 'Préparez un aperçu du pack pour cette base.'}
        $grid=Get-DomeniaControl 'DgQueryImport';[void]$grid.CommitEdit()
        foreach($choice in @($grid.ItemsSource)){
            if($choice.Action -eq 'Ignorer'){continue};if($choice.Action -notin $choice.AllowedActions){throw 'Choix d’import non autorisé.'}
            $recipe=ConvertFrom-Json -InputObject $choice.After.DefinitionJson
            $expected=[long]$choice.ExpectedRevision;$before=$choice.Before
            if($choice.Action -eq 'Nouvelle copie'){$recipe=Copy-DomeniaQueryRecipe $recipe -Id ([guid]::NewGuid().ToString('N'));$expected=0L;$before=$null}
            $items.Add([pscustomobject]@{Id=$recipe.Id;ExpectedRevision=$expected;Recipe=$recipe;Archive=$false;Before=$before})
        }
    }
    if(-not $items.Count){throw 'Aucune modification sélectionnée.'}
    $details=($items|Select-Object -First 20|ForEach-Object{$_.Recipe.Name+' · révision attendue '+$_.ExpectedRevision}) -join "`r`n"
    $answer=Show-DomeniaDialog -Title $(if($Rollback){'Restaurer avant l’import'}else{'Importer les recettes choisies'}) -Message ($items.Count.ToString()+' modification(s) dans la bibliothèque. Chaque écriture vérifie sa révision. En cas d’arrêt, les éléments déjà confirmés restent visibles et peuvent être restaurés depuis cet écran pendant la session.') -Details $details -Kind Question -Buttons YesNo
    if([string]$answer -ne 'Yes'){return}
    $run=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation;Items=$items.ToArray();Index=0;Applied=[Collections.Generic.List[object]]::new();Running=$true;Rollback=[bool]$Rollback;Error=''}
    $q|Add-Member NoteProperty ImportRun $run -Force
    Submit-DomeniaQueryImportNext $run
}
function Submit-DomeniaQueryImportNext {
    param($Run)
    if(-not (Test-DomeniaQueryLibraryStoreState $Run)){return}
    if($Run.Index -ge $Run.Items.Count){$Run.Running=$false;[void](Set-DomeniaControlText 'LblQueryImportStatus' ($Run.Index.ToString()+' recette(s) confirmée(s) par la base. Les révisions précédentes sont conservées.'));return}
    try{
        $item=$Run.Items[$Run.Index];$current=$script:DomeniaQueryLibraryStoreState.Rows[[string]$item.Id];$revision=if($null -ne $current){[long]$current.Revision}else{0L}
        if($revision -ne [long]$item.ExpectedRevision){throw ('La recette '+$item.Recipe.Name+' a changé depuis l’aperçu. Repréparez l’import.')}
        [void](Save-DomeniaQueryRecipe -Recipe $item.Recipe -Archive:([bool]$item.Archive) -SuccessHandler 'Complete-DomeniaQueryImportItem' -ErrorHandler 'Fail-DomeniaQueryImportItem' -CallbackState $Run)
        [void](Set-DomeniaControlText 'LblQueryImportStatus' ('Enregistrement '+($Run.Index+1)+' / '+$Run.Items.Count+'…'))
    }catch{$Run.Running=$false;$Run.Error=$_.Exception.Message;[void](Set-DomeniaControlText 'LblQueryImportStatus' ('Import arrêté après '+$Run.Applied.Count+' confirmations : '+$Run.Error))}
}
function Complete-DomeniaQueryImportItem {
    param($Recipe,$Record,$State)
    $run=$State;if(-not (Test-DomeniaQueryLibraryStoreState $run)){return}
    $item=$run.Items[$run.Index]
    $run.Applied.Add([pscustomobject]@{Id=$Record.Id;Revision=[long]$Record.Revision;Before=$item.Before;Sequence=$run.Index})
    $run.Index++;Submit-DomeniaQueryImportNext $run
}

function Fail-DomeniaQueryImportItem {
    param($Message,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $State.Running=$false;$State.Error=[string]$Message
    [void](Set-DomeniaControlText 'LblQueryImportStatus' ('Import arrêté après '+$State.Applied.Count+' confirmation(s) : '+[string]$Message+'. Les écritures confirmées peuvent être restaurées.'))
}
