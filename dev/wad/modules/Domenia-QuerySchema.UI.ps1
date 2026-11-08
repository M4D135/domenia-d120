function Initialize-DomeniaQuerySchemaUi {
    foreach($entry in @(@('BtnQuerySchemaRead','Schema'),@('BtnQueryWqlRun','Select'),@('BtnQueryAssociations','Relation'),@('BtnQueryWqlBuild','Build'),@('BtnQueryWqlRecipe','Recipe'),@('BtnQueryWmiNamespaces','Namespaces'),@('BtnQueryWmiClasses','Classes'),@('BtnQueryWmiRemoteRead','Remote'))){
        $control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($sender,$args)Invoke-DomeniaQuerySchemaAction ([string]$sender.Tag)})}
    }
    $q=$script:DomeniaQueryState;$q|Add-Member NoteProperty SchemaGeneration 0L -Force
    foreach($name in @('SchemaReceipt','RowsReceipt','WqlTested','SchemaPendingRemote')){$q|Add-Member NoteProperty $name $null -Force}
    foreach($name in @('TxtQueryWql','TxtQueryWmiNamespace','TxtQueryWmiLimit')){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_TextChanged({Update-DomeniaQueryWqlPlan})}}
    $namespaces=Get-DomeniaControl 'LstQueryWmiNamespaces'
    if($null -ne $namespaces){$namespaces.Add_SelectionChanged({$item=(Get-DomeniaControl 'LstQueryWmiNamespaces').SelectedItem;if($null -ne $item){(Get-DomeniaControl 'TxtQueryWmiNamespace').Text=[string]$item.Namespace}})}
    $classes=Get-DomeniaControl 'DgQueryWmiClasses'
    if($null -ne $classes){
        $classes.Add_SelectionChanged({$item=(Get-DomeniaControl 'DgQueryWmiClasses').SelectedItem;if($null -ne $item){(Get-DomeniaControl 'TxtQueryWmiClass').Text=[string]$item.Class}})
        $classes.Add_MouseDoubleClick({Invoke-DomeniaQuerySchemaAction 'Schema'})
    }
    $rows=Get-DomeniaControl 'DgQueryWmiRows';if($null -ne $rows){$rows.Add_SelectionChanged({Update-DomeniaQueryRelationPresets})}
    $preset=Get-DomeniaControl 'CmbQueryAssociationPreset';if($null -ne $preset){$preset.Add_SelectionChanged({Use-DomeniaQueryRelationPreset})}
    Update-DomeniaQueryRelationPresets
    Update-DomeniaQueryWqlPlan
}
function Get-DomeniaQuerySchemaSelectedGuid {
    return [string](Get-DomeniaMemberValue (Get-DomeniaMemberValue $script:SelectedObject 'Safety') 'Guid')
}
function Get-DomeniaQueryWqlPlanState {
    # Local analysis of the displayed SELECT for the selected workstation; no network.
    $q=$script:DomeniaQueryState
    $namespace=([string](Get-DomeniaControl 'TxtQueryWmiNamespace').Text).Trim()
    $limit=0;[void][int]::TryParse(([string](Get-DomeniaControl 'TxtQueryWmiLimit').Text).Trim(),[ref]$limit)
    $guid=Get-DomeniaQuerySchemaSelectedGuid
    $known=@();$keys=@();$schemaClass=''
    $receipt=Get-DomeniaMemberValue $q 'SchemaReceipt'
    if($null -ne $receipt -and $guid -and [string]$receipt.Guid -ieq $guid -and [string]$receipt.Data.Namespace -ieq $namespace){
        $schemaClass=[string]$receipt.Data.ClassName
        $known=@(@($receipt.Data.Schema)|ForEach-Object{[string]$_.Property})
        $keys=@(@($receipt.Data.Schema)|Where-Object{[bool]$_.IsKey}|ForEach-Object{[string]$_.Property})
    }
    $tested=Get-DomeniaMemberValue $q 'WqlTested'
    $computer=if($null -ne $script:SelectedObject -and [string](Get-DomeniaMember $script:SelectedObject 'Type') -eq 'Machine'){[string](Get-DomeniaMember $script:SelectedObject 'Name')}else{''}
    # A test belongs to one AD identity: another or a recreated workstation must be tested again.
    if($null -ne $tested -and $guid -and [string]$tested.Guid -ieq $guid){$computer=[string]$tested.Computer}else{$tested=$null}
    return (Get-DomeniaWqlPlanReport -Namespace $namespace -Query ([string](Get-DomeniaControl 'TxtQueryWql').Text) -Limit $limit -KnownProperties $known -KeyProperties $keys -SchemaClass $schemaClass -Tested $tested -Computer $computer)
}
function Update-DomeniaQueryWqlPlan {
    $q=$script:DomeniaQueryState;if($null -eq $q -or $null -eq (Get-DomeniaControl 'LblQueryWqlPlan')){return}
    try{$report=Get-DomeniaQueryWqlPlanState}catch{[void](Set-DomeniaControlText 'LblQueryWqlPlan' ('Analyse indisponible : '+$_.Exception.Message));return}
    [void](Set-DomeniaControlText 'LblQueryWqlPlan' ([string]$report.Text))
    $button=Get-DomeniaControl 'BtnQueryWqlRecipe';if($null -ne $button){$button.IsEnabled=[bool]$report.Ready}
}
function Update-DomeniaQueryRelationPresets {
    $combo=Get-DomeniaControl 'CmbQueryAssociationPreset';if($null -eq $combo){return}
    $grid=Get-DomeniaControl 'DgQueryWmiRows';$row=if($null -ne $grid){$grid.SelectedItem}else{$null}
    $class=if($null -ne $row){[string](Get-DomeniaMember $row 'ClassName')}else{''}
    $items=@(if($class){Get-DomeniaWmiRelationPresets $class})+@([pscustomobject]@{Kind='Manual';Label='Saisie libre : classe dʼassociation déclarée par le fournisseur';Association='';Result=''})
    $combo.ItemsSource=$items;$combo.SelectedIndex=0
    Use-DomeniaQueryRelationPreset
}
function Use-DomeniaQueryRelationPreset {
    $combo=Get-DomeniaControl 'CmbQueryAssociationPreset';$association=Get-DomeniaControl 'TxtQueryAssociationClass';$result=Get-DomeniaControl 'TxtQueryAssociationResult'
    if($null -eq $combo -or $null -eq $association -or $null -eq $result){return}
    $preset=$combo.SelectedItem;$kind=[string](Get-DomeniaMember $preset 'Kind')
    $association.IsEnabled=($kind -ne 'Reference');$result.IsEnabled=($kind -ne 'Reference')
    if($kind -eq 'Association'){$association.Text=[string]$preset.Association;$result.Text=[string]$preset.Result}
    elseif($kind -eq 'Reference'){$association.Text='';$result.Text=[string]$preset.Result}
}
function Hide-DomeniaQuerySchemaRemoteOffer {
    $q=$script:DomeniaQueryState;if($null -ne $q -and $null -ne $q.PSObject.Properties['SchemaPendingRemote']){$q.SchemaPendingRemote=$null}
    $button=Get-DomeniaControl 'BtnQueryWmiRemoteRead';if($null -ne $button){$button.Visibility='Collapsed'}
}
function Invoke-DomeniaQuerySchemaAction {
    param([string]$Action)
    try{
        $q=$script:DomeniaQueryState
        if($Action -eq 'Build'){
            $selected=@((Get-DomeniaControl 'DgQuerySchema').ItemsSource|Where-Object Selected|ForEach-Object Property)
            if(-not $selected.Count){throw 'Cochez au moins une propriété du schéma enregistré.'}
            $receipt=$q.SchemaReceipt;if($null -eq $receipt -or $receipt.Data.DataSource -cne 'SQLite'){throw 'Relisez dʼabord le schéma de ce poste.'}
            (Get-DomeniaControl 'TxtQueryWql').Text='SELECT '+($selected -join ', ')+' FROM '+[string]$receipt.Data.ClassName;return
        }
        if($Action -eq 'Recipe'){
            $report=Get-DomeniaQueryWqlPlanState;$tested=$q.WqlTested
            if(-not [bool]$report.Ready -or $null -eq $tested){throw 'Cette requête nʼa pas été testée sous cette forme sur le poste choisi : exécutez-la dʼabord.'}
            $definition=New-DomeniaQueryReadDefinition -Namespace ([string]$tested.Namespace) -Query ([string]$tested.CanonicalQuery) -Limit ([int]$tested.Limit)
            $recipe=New-DomeniaQueryRecipe -Name ('WMI · '+[string]$tested.ClassName) -ReadDefinition $definition -Clauses @([pscustomobject]@{Field=('detail:'+$definition.RequestKey+':exists');Operator='Equal';Value=$true})
            Set-DomeniaQueryDraft $recipe
            (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryPublish'
            [void](Set-DomeniaControlText 'LblQueryStatus' 'Recette préparée depuis le résultat confirmé par la base. Lʼaperçu et les widgets utilisent uniquement les SELECT déjà mémorisés ; la lecture distante reste explicite.');return
        }
        if($Action -eq 'Remote'){
            $pending=Get-DomeniaMemberValue $q 'SchemaPendingRemote';Hide-DomeniaQuerySchemaRemoteOffer
            if($null -eq $pending -or [long]$pending.SchemaGeneration -ne [long]$q.SchemaGeneration){throw 'Relancez lʼaction : le poste ou la demande a changé.'}
            Start-DomeniaQuerySchemaRemoteRead $pending;return
        }
        Hide-DomeniaQuerySchemaRemoteOffer
        if($script:DemoMode){throw 'Lecture distante indisponible en démonstration.'}
        $computer=Get-DomeniaWmiComputer;if(-not $computer){return}
        $namespace=([string](Get-DomeniaControl 'TxtQueryWmiNamespace').Text).Trim();$class=([string](Get-DomeniaControl 'TxtQueryWmiClass').Text).Trim()
        $msi=@(Get-DomeniaMsiProviderClassNames);$query=([string](Get-DomeniaControl 'TxtQueryWql').Text).Trim();$limit=100
        if($Action -in @('Select','Relation')){
            if(-not [int]::TryParse([string](Get-DomeniaControl 'TxtQueryWmiLimit').Text,[ref]$limit) -or $limit -lt 1 -or $limit -gt 2000){throw 'Choisissez une limite entre 1 et 2 000 instances.'}
        }
        $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Mode=$Action;Computer=$computer;Namespace=$namespace;ClassName=$class;Query=$query;Limit=$limit;MsiClassNames=$msi;StopToken=$null;KeyValues=$null;AssociationClass='';ResultClass='';ClassFilter='';SourceProperty='';SourceValue=$null;TargetProperty=''}
        $canonical='';$label='';$budget=''
        switch($Action){
            'Namespaces'{Assert-DomeniaQuerySchemaNamespace $namespace;$canonical='NAMESPACES '+$namespace;$label='Lister les espaces de noms directement sous '+$namespace;$budget='Un seul niveau, 500 espaces au plus.'}
            'Classes'{
                $filter=([string](Get-DomeniaControl 'TxtQueryWmiClassFilter').Text).Trim();Assert-DomeniaQuerySchemaNamespace $namespace;Assert-DomeniaQuerySchemaClassFilter $filter
                $payload.ClassFilter=$filter;$canonical='CLASSES '+$namespace+' '+$(if($filter){$filter}else{'*'})
                $label='Lister les classes de '+$namespace+$(if($filter){' correspondant à '+$filter}else{''});$budget='Définitions de classes seulement, aucune instance : 2 000 classes et 1 Mio au plus.'
            }
            'Schema'{Assert-DomeniaQuerySchemaTarget $namespace $class $msi;$canonical='SCHEMA '+$class;$label='Lire le schéma de '+$class;$budget='Définition de la classe, unités et descriptions, sans aucune instance.'}
            'Select'{
                $plan=ConvertFrom-DomeniaWqlSelect $query;$payload.ClassName=$plan.ClassName;$payload.Query=$plan.CanonicalQuery
                Assert-DomeniaQuerySchemaTarget $namespace $plan.ClassName $msi
                $canonical=$plan.CanonicalQuery;$label=$plan.CanonicalQuery;$budget='Limite : '+$limit+' instances et 1 Mio de données.'
            }
            'Relation'{
                $row=(Get-DomeniaControl 'DgQueryWmiRows').SelectedItem;$receipt=$q.RowsReceipt;$guid=Get-DomeniaQuerySchemaSelectedGuid
                if($null -eq $row -or $null -eq $receipt -or [string]$receipt.Guid -ine $guid -or [string]$receipt.Computer -ine $computer){throw 'Sélectionnez une instance du dernier résultat enregistré pour ce même poste.'}
                $payload.Namespace=[string]$receipt.Data.Namespace;$payload.ClassName=[string]$row.ClassName;$payload.KeyValues=$row.KeyValues
                $preset=(Get-DomeniaControl 'CmbQueryAssociationPreset').SelectedItem
                if([string](Get-DomeniaMember $preset 'Kind') -eq 'Reference'){
                    $value=Get-DomeniaMemberValue $row.KeyValues ([string]$preset.SourceProperty);if($null -eq $value){$value=Get-DomeniaMemberValue $row.Values ([string]$preset.SourceProperty)}
                    $text=ConvertTo-DomeniaWmiReferenceValue -Preset $preset -Value $value
                    $payload.Mode='Reference';$payload.ResultClass=[string]$preset.Result;$payload.SourceProperty=[string]$preset.SourceProperty;$payload.TargetProperty=[string]$preset.TargetProperty;$payload.SourceValue=$value
                    Assert-DomeniaQuerySchemaTarget $payload.Namespace ([string]$preset.Result) $msi
                    $canonical='REFERENCE '+$payload.ClassName+'.'+[string]$preset.SourceProperty+'='+$text+' TO '+[string]$preset.Result+'.'+[string]$preset.TargetProperty
                    $label=[string]$preset.Label+"`r`nInstance source : "+[string]$row.Id
                }else{
                    $payload.Mode='Associations';$payload.AssociationClass=([string](Get-DomeniaControl 'TxtQueryAssociationClass').Text).Trim();$payload.ResultClass=([string](Get-DomeniaControl 'TxtQueryAssociationResult').Text).Trim()
                    Assert-DomeniaQuerySchemaTarget $payload.Namespace $payload.AssociationClass $msi
                    Assert-DomeniaQuerySchemaTarget $payload.Namespace $payload.ResultClass $msi
                    $canonical='ASSOCIATION '+$payload.AssociationClass+' FROM '+[string]$row.Id+' TO '+$payload.ResultClass
                    $label='Lire les associations '+$payload.AssociationClass+' vers '+$payload.ResultClass+"`r`nInstance source : "+[string]$row.Id
                }
                Assert-DomeniaQuerySchemaTarget $payload.Namespace $payload.ClassName $msi
                $budget='Limite : '+$limit+' instances et 1 Mio de données.'
            }
            default{throw 'Action WMI inconnue.'}
        }
        $metadata=($payload.Mode -in @('Namespaces','Classes','Schema'))
        $q.SchemaGeneration++
        switch($payload.Mode){'Schema'{$q.SchemaReceipt=$null};'Select'{$q.SchemaReceipt=$null;$q.RowsReceipt=$null;$q.WqlTested=$null};'Associations'{$q.RowsReceipt=$null};'Reference'{$q.RowsReceipt=$null}}
        Update-DomeniaQueryWqlPlan
        $state=New-DomeniaClassicCollectionState -Computer $computer -ResultKind $(if($metadata){'WmiSchema'}else{'WmiQuery'}) -RequestKey (Get-DomeniaQuerySchemaRequestKey $payload.Namespace $canonical) -PublishHandler 'Complete-DomeniaQuerySchemaStored' -PublishErrorHandler 'Fail-DomeniaQuerySchemaRead'
        foreach($pair in @(@('SchemaGeneration',$q.SchemaGeneration),@('Mode',$payload.Mode),@('Namespace',$payload.Namespace),@('Payload',$payload),@('Label',$label),@('Budget',$budget),@('FromCache',$false))){$state|Add-Member NoteProperty $pair[0] $pair[1] -Force}
        if($metadata -and -not [bool](Get-DomeniaControl 'ChkQueryWmiForceRead').IsChecked){
            # Metadata already read for this workstation is reused from the local database, with its date.
            $read=[pscustomobject]@{Kind='Detail';Guids=@($state.StoreGuid);ResultKind='WmiSchema';RequestKey=[string]$state.RequestKey;Offset=0;Limit=1}
            $job=Request-DomeniaStoreRead -Context $state.StoreContext -Query $read -SuccessHandler 'Complete-DomeniaQuerySchemaCacheRead' -ErrorHandler 'Fail-DomeniaQuerySchemaCacheRead' -CallbackState $state
            if(-not $job){Show-DomeniaQuerySchemaRemoteOffer $state 'Base locale occupée : les métadonnées enregistrées nʼont pas pu être relues.';return}
            [void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Recherche des métadonnées enregistrées pour '+$computer+'…'));return
        }
        Start-DomeniaQuerySchemaRemoteRead $state
    }catch{[void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Lecture non lancée : '+$_.Exception.Message))}
}
function Show-DomeniaQuerySchemaRemoteOffer {
    # No remote read starts from a callback: the operator gets an explicit in-page button instead.
    param($State,[string]$Reason)
    $q=$script:DomeniaQueryState;if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration){return}
    $q.SchemaPendingRemote=$State
    $button=Get-DomeniaControl 'BtnQueryWmiRemoteRead';if($null -ne $button){$button.Visibility='Visible'}
    [void](Set-DomeniaControlText 'LblQueryWmiStatus' ($Reason+' Utilisez « Lire sur le poste… » pour une lecture explicite de '+[string]$State.Computer+' seulement.'))
}
function Start-DomeniaQuerySchemaRemoteRead {
    param($State)
    $q=$script:DomeniaQueryState;if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration){return}
    $payload=$State.Payload
    $answer=Show-DomeniaDialog -Title 'Lecture WMI sur un poste' -Message ([string]$State.Label+"`r`nPoste : "+[string]$State.Computer+"`r`n"+[string]$State.Budget+' La lecture peut prendre jusquʼà une minute. Les résultats seront enregistrés dans la base locale avant affichage.') -Kind Question -Buttons YesNo
    if([string]$answer -ne 'Yes'){[void](Set-DomeniaControlText 'LblQueryWmiStatus' 'Lecture sur le poste non lancée.');return}
    $stop=[Threading.CancellationTokenSource]::new();$payload.StopToken=$stop.Token;$State|Add-Member NoteProperty StopSource $stop -Force
    $job=Start-UiTask -Name ('Atelier WMI : '+[string]$payload.Mode) -OperationId 'QuerySchema' -Code (Get-DomeniaQuerySchemaWorkerCode) -Payload $payload -CallbackState $State -ReplaceKey 'query:wmi' -SuccessHandler 'Complete-DomeniaQuerySchemaCollected' -ErrorHandler 'Fail-DomeniaQuerySchemaCollected' -TimeoutSeconds 65 -HardTimeoutSeconds 80 -TaskClass Explicit
    if(-not $job){$stop.Dispose();throw 'Lecture WMI non admise.'}
    [void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Lecture de '+[string]$State.Computer+' en cours… Les valeurs seront affichées après enregistrement.'))
}
function Complete-DomeniaQuerySchemaCacheRead {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration -or -not (Test-DomeniaRemoteStoreContext $State $null)){return}
    $saved=@()
    if(-not [bool](Get-DomeniaMember $Result 'Busy' $false) -and -not [bool](Get-DomeniaMember $Result 'Missing' $false) -and [string](Get-DomeniaMember $Result 'DataSource') -ceq 'SQLite' -and [string](Get-DomeniaMember $Result 'StoreId') -ceq [string]$State.StoreContext.StoreId){
        $saved=@(@(Get-DomeniaMember $Result 'Details' @())|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.ResultKind -ceq 'WmiSchema' -and [string]$_.RequestKey -ceq [string]$State.RequestKey -and [string]$_.Status -eq 'Success' -and $null -ne $_.Data -and [string]$_.LastSuccessAtUtc}|Sort-Object LastSuccessAtUtc -Descending|Select-Object -First 1)
    }
    if($saved.Count){
        $data=$saved[0].Data
        if([string](Get-DomeniaMember $data 'Mode') -ceq [string]$State.Mode -and [string](Get-DomeniaMember $data 'RequestKey') -ceq [string]$State.RequestKey){
            $data|Add-Member -NotePropertyName DataSource -NotePropertyValue 'SQLite' -Force
            $data|Add-Member -NotePropertyName SourceCompletedUtc -NotePropertyValue ([string]$saved[0].LastSuccessAtUtc) -Force
            $data|Add-Member -NotePropertyName StoreRevision -NotePropertyValue ([long](Get-DomeniaMember $Result 'SnapshotRevision' 0)) -Force
            $State.FromCache=$true
            Complete-DomeniaQuerySchemaStored -Result $data -State $State
            return
        }
    }
    Show-DomeniaQuerySchemaRemoteOffer $State 'Aucune métadonnée enregistrée pour ce poste et cette demande.'
}
function Fail-DomeniaQuerySchemaCacheRead {
    param($Message,$State)
    Show-DomeniaQuerySchemaRemoteOffer $State ('Métadonnées enregistrées non relues : '+[string]$Message+'.')
}
function Complete-DomeniaQuerySchemaCollected {
    param($Result,$State)
    try{
        $data=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Mode','Namespace','RequestKey','SourceCompletedUtc','Rows','Schema')
        if($null -eq $data -or $data.Computer -ine $State.Computer -or $data.Namespace -cne $State.Namespace -or $data.Mode -cne $State.Mode -or $data.RequestKey -cne (Get-DomeniaQuerySchemaRequestKey $data.Namespace $data.CanonicalQuery)){throw 'Identité ou définition du résultat WMI incohérente.'}
        $State.RequestKey=[string]$data.RequestKey
        $safe=[ordered]@{};foreach($name in @('Computer','Success','Mode','Namespace','ClassName','CanonicalQuery','RequestKey','Schema','Rows','Namespaces','Classes','ClassDescription','DescriptionsAvailable','Filter','Relation','StoredCount','ObservedCountMinimum','CountComplete','Truncated','BudgetBytes','Limit','DurationMs')){$safe[$name]=Get-DomeniaMemberValue $data $name}
        [void](Submit-DomeniaRemoteDetail -Data ([pscustomobject]$safe) -State $State -Succeeded $true -SourceCompletedUtc ([string]$data.SourceCompletedUtc))
    }catch{Fail-DomeniaQuerySchemaRead $_.Exception.Message $State}
    finally{if($null -ne (Get-DomeniaMemberValue $State 'StopSource')){$State.StopSource.Dispose()}}
}
function Fail-DomeniaQuerySchemaCollected {
    param($Message,$State)
    try{if($null -ne (Get-DomeniaMemberValue $State 'StopSource')){$State.StopSource.Cancel();$State.StopSource.Dispose()};[void](Submit-DomeniaRemoteDetail -Data ([pscustomobject]@{CollectionError=[string]$Message}) -State $State -Succeeded $false -SourceCompletedUtc ([datetime]::UtcNow.ToString('o')) -ErrorText ([string]$Message))}catch{Fail-DomeniaQuerySchemaRead $_.Exception.Message $State}
}
function Format-DomeniaQuerySchemaDate {
    param([string]$Text)
    $at=ConvertFrom-DomeniaUtcText $Text
    if($null -eq $at){return 'date inconnue'}
    return $at.ToLocalTime().ToString('dd/MM/yyyy HH:mm')
}
function Complete-DomeniaQuerySchemaStored {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration -or -not (Test-DomeniaClassicResultCurrent $Result $State)){return}
    if([string]$Result.DataSource -cne 'SQLite'){throw 'Le résultat WMI doit provenir de la base locale.'}
    $when=Format-DomeniaQuerySchemaDate ([string]$Result.SourceCompletedUtc)
    $origin=if([bool](Get-DomeniaMember $State 'FromCache' $false)){'métadonnées enregistrées le '+$when+', sans nouvelle lecture du poste (cochez « Relire sur le poste » pour les actualiser)'}else{'lecture du poste enregistrée dans la base le '+$when}
    $coverage=if([bool]$Result.Truncated){'liste partielle, limite atteinte'}else{'liste complète'}
    $mode=[string]$Result.Mode
    if($mode -eq 'Namespaces'){
        (Get-DomeniaControl 'LstQueryWmiNamespaces').ItemsSource=@($Result.Namespaces)
        [void](Set-DomeniaControlText 'LblQueryWmiStatus' ($State.Computer+' · '+[string]$Result.Namespace+' : '+@($Result.Namespaces).Count+' espace(s) de noms enfant(s), un seul niveau · '+$coverage+' · '+$origin+'.'))
        return
    }
    if($mode -eq 'Classes'){
        (Get-DomeniaControl 'DgQueryWmiClasses').ItemsSource=@($Result.Classes)
        [void](Set-DomeniaControlText 'LblQueryWmiStatus' ($State.Computer+' · '+[string]$Result.Namespace+' : '+@($Result.Classes).Count+' classe(s)'+$(if([string]$Result.Filter){' pour '+[string]$Result.Filter}else{''})+' · '+$coverage+' · '+$origin+'.'))
        return
    }
    if($mode -in @('Schema','Select')){
        $q.SchemaReceipt=[pscustomobject]@{Computer=$State.Computer;Guid=$State.StoreGuid;Data=$Result}
        (Get-DomeniaControl 'DgQuerySchema').ItemsSource=@(foreach($field in @($Result.Schema)){[pscustomobject]@{Selected=$false;Property=$field.Property;Type=$field.Type;IsKey=[bool]$field.IsKey;Unit=[string](Get-DomeniaMember $field 'Unit');Description=$(if([string](Get-DomeniaMember $field 'Description')){[string]$field.Description}else{'Description non fournie'})}})
        $description=[string](Get-DomeniaMember $Result 'ClassDescription')
        if($mode -eq 'Schema'){[void](Set-DomeniaControlText 'LblQueryWmiClassDescription' ([string]$Result.ClassName+' : '+$(if($description){$description}elseif([bool](Get-DomeniaMember $Result 'DescriptionsAvailable' $false)){'le fournisseur ne publie pas de description pour cette classe.'}else{'descriptions non fournies par ce poste ; types, clés et unités restent affichés.'})))}
    }
    if($mode -eq 'Schema'){
        [void](Set-DomeniaControlText 'LblQueryWmiStatus' ($State.Computer+' · schéma de '+[string]$Result.ClassName+' : '+@($Result.Schema).Count+' propriété(s) · '+$origin+'.'))
        Update-DomeniaQueryWqlPlan;return
    }
    if($mode -eq 'Select'){$q.WqlTested=[pscustomobject]@{Computer=$State.Computer;Guid=$State.StoreGuid;Namespace=[string]$Result.Namespace;ClassName=[string]$Result.ClassName;CanonicalQuery=[string]$Result.CanonicalQuery;Limit=[int]$Result.Limit;At=$when;Mode='Select'}}
    $q.RowsReceipt=[pscustomobject]@{Computer=$State.Computer;Guid=$State.StoreGuid;Data=$Result}
    (Get-DomeniaControl 'DgQueryWmiRows').ItemsSource=@(foreach($row in @($Result.Rows)){[pscustomobject]@{Id=$row.Id;ClassName=$row.ClassName;KeyValues=$row.KeyValues;Values=$row.Values;ValueText=(ConvertTo-Json -InputObject $row.Values -Depth 5 -Compress);Completeness=$(if(@($row.IncompleteProperties).Count){'Propriétés incomplètes : '+($row.IncompleteProperties -join ', ')}else{'Valeurs conservées'})}})
    $relation=if($mode -in @('Associations','Reference')){' · relation '+[string](Get-DomeniaMember $Result 'Relation')+' lue depuis lʼidentité de lʼinstance source ; les instances gardent leurs clés de fournisseur'+$(if($mode -eq 'Reference'){', valable au moment de la lecture'}else{''})}else{''}
    [void](Set-DomeniaControlText 'LblQueryWmiStatus' ($State.Computer+' · '+$Result.StoredCount+' instance(s) mémorisée(s) · '+$(if($Result.Truncated){'lecture partielle, limite atteinte'}else{'lecture complète'})+$relation+' · '+$origin+'.'))
    Update-DomeniaQueryRelationPresets
    Update-DomeniaQueryWqlPlan
}
function Fail-DomeniaQuerySchemaRead {
    param($Message,$State)
    $q=$script:DomeniaQueryState;if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration){return}
    [void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Résultat WMI indisponible : '+[string]$Message))
}
