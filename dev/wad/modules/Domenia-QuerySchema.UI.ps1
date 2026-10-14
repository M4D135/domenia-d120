function Initialize-DomeniaQuerySchemaUi {
    foreach($entry in @(@('BtnQuerySchemaRead','Schema'),@('BtnQueryWqlRun','Select'),@('BtnQueryAssociations','Associations'),@('BtnQueryWqlBuild','Build'),@('BtnQueryWqlRecipe','Recipe'))){
        $control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($sender,$args)Invoke-DomeniaQuerySchemaAction ([string]$sender.Tag)})}
    }
    $q=$script:DomeniaQueryState;$q|Add-Member NoteProperty SchemaGeneration 0L -Force;$q|Add-Member NoteProperty SchemaReceipt $null -Force
}
function Invoke-DomeniaQuerySchemaAction {
    param([string]$Action)
    try{
        $q=$script:DomeniaQueryState
        if($Action -eq 'Build'){
            $selected=@((Get-DomeniaControl 'DgQuerySchema').ItemsSource|Where-Object Selected|ForEach-Object Property)
            if(-not $selected.Count){throw 'Cochez au moins une propriété du schéma enregistré.'}
            $receipt=$q.SchemaReceipt;if($null -eq $receipt -or $receipt.Data.DataSource -cne 'SQLite'){throw 'Relisez d’abord le schéma de ce poste.'}
            (Get-DomeniaControl 'TxtQueryWql').Text='SELECT '+($selected -join ', ')+' FROM '+[string]$receipt.Data.ClassName;return
        }
        if($Action -eq 'Recipe'){
            $receipt=$q.SchemaReceipt
            if($null -eq $receipt -or $receipt.Data.DataSource -cne 'SQLite' -or $receipt.Data.Mode -cne 'Select'){throw 'Exécutez puis enregistrez d’abord un SELECT sur le poste choisi.'}
            $definition=New-DomeniaQueryReadDefinition -Namespace ([string]$receipt.Data.Namespace) -Query ([string]$receipt.Data.CanonicalQuery) -Limit ([int]$receipt.Data.Limit)
            $recipe=New-DomeniaQueryRecipe -Name ('WMI · '+[string]$receipt.Data.ClassName) -ReadDefinition $definition -Clauses @([pscustomobject]@{Field=('detail:'+$definition.RequestKey+':exists');Operator='Equal';Value=$true})
            Set-DomeniaQueryDraft $recipe
            (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryPublish'
            [void](Set-DomeniaControlText 'LblQueryStatus' 'Recette préparée depuis le résultat confirmé par la base. L’aperçu et les widgets utilisent uniquement les SELECT déjà mémorisés ; la lecture distante reste explicite.');return
        }
        if($script:DemoMode){throw 'Lecture distante indisponible en démonstration.'}
        $computer=Get-DomeniaWmiComputer;if(-not $computer){return}
        $namespace=([string](Get-DomeniaControl 'TxtQueryWmiNamespace').Text).Trim();$class=([string](Get-DomeniaControl 'TxtQueryWmiClass').Text).Trim();$limit=0
        if(-not [int]::TryParse([string](Get-DomeniaControl 'TxtQueryWmiLimit').Text,[ref]$limit) -or $limit -lt 1 -or $limit -gt 2000){throw 'Choisissez une limite entre 1 et 2 000 instances.'}
        $query=([string](Get-DomeniaControl 'TxtQueryWql').Text).Trim();$msi=@(Get-DomeniaMsiProviderClassNames)
        if($Action -eq 'Select'){$plan=ConvertFrom-DomeniaWqlSelect $query;$class=$plan.ClassName;$query=$plan.CanonicalQuery}
        $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Mode=$Action;Computer=$computer;Namespace=$namespace;ClassName=$class;Query=$query;Limit=$limit;MsiClassNames=$msi;StopToken=$null;KeyValues=$null;AssociationClass='';ResultClass=''}
        if($Action -eq 'Associations'){
            $row=(Get-DomeniaControl 'DgQueryWmiRows').SelectedItem;$receipt=$q.SchemaReceipt
            $guid=[string](Get-DomeniaMember (Get-DomeniaMemberValue $script:SelectedObject 'Safety') 'Guid')
            if($null -eq $row -or $null -eq $receipt -or $receipt.Guid -ine $guid -or $receipt.Computer -ine $computer){throw 'Sélectionnez une instance du dernier résultat enregistré pour ce même poste.'}
            $payload.Namespace=[string]$receipt.Data.Namespace;$payload.ClassName=[string]$row.ClassName;$payload.KeyValues=$row.KeyValues
            $payload.AssociationClass=([string](Get-DomeniaControl 'TxtQueryAssociationClass').Text).Trim();$payload.ResultClass=([string](Get-DomeniaControl 'TxtQueryAssociationResult').Text).Trim()
            Assert-DomeniaQuerySchemaTarget $payload.Namespace $payload.AssociationClass $msi
            Assert-DomeniaQuerySchemaTarget $payload.Namespace $payload.ResultClass $msi
        }
        Assert-DomeniaQuerySchemaTarget $payload.Namespace $payload.ClassName $msi
        $label=if($Action -eq 'Schema'){'Lire le schéma de '+$payload.ClassName}elseif($Action -eq 'Associations'){'Lire les associations '+$payload.AssociationClass+' vers '+$payload.ResultClass}else{$query}
        $answer=Show-DomeniaDialog -Title 'Lecture WMI sur un poste' -Message ($label+"`r`nPoste : "+$computer+"`r`nLimite : "+$limit+' instances et 1 Mio de données. La lecture peut prendre jusqu’à une minute. Les résultats seront enregistrés dans la base locale avant affichage.') -Kind Question -Buttons YesNo
        if([string]$answer -ne 'Yes'){return}
        $q.SchemaGeneration++;$q.SchemaReceipt=$null;(Get-DomeniaControl 'BtnQueryWqlRecipe').IsEnabled=$false
        $canonical=if($Action -eq 'Schema'){'SCHEMA '+$payload.ClassName}else{$query}
        $resultKind=if($Action -eq 'Schema'){'WmiSchema'}else{'WmiQuery'}
        $state=New-DomeniaClassicCollectionState -Computer $computer -ResultKind $resultKind -RequestKey (Get-DomeniaQuerySchemaRequestKey $payload.Namespace $canonical) -PublishHandler 'Complete-DomeniaQuerySchemaStored' -PublishErrorHandler 'Fail-DomeniaQuerySchemaRead'
        $state|Add-Member NoteProperty SchemaGeneration $q.SchemaGeneration;$state|Add-Member NoteProperty Mode $Action;$state|Add-Member NoteProperty Namespace $payload.Namespace
        $stop=[Threading.CancellationTokenSource]::new();$payload.StopToken=$stop.Token;$state|Add-Member NoteProperty StopSource $stop
        $job=Start-UiTask -Name ('Atelier WMI : '+$Action) -OperationId 'QuerySchema' -Code (Get-DomeniaQuerySchemaWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'query:wmi' -SuccessHandler 'Complete-DomeniaQuerySchemaCollected' -ErrorHandler 'Fail-DomeniaQuerySchemaCollected' -TimeoutSeconds 65 -HardTimeoutSeconds 80 -TaskClass Explicit
        if(-not $job){$stop.Dispose();throw 'Lecture WMI non admise.'}
        [void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Lecture de '+$computer+' en cours… Les valeurs seront affichées après enregistrement.'))
    }catch{[void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Lecture non lancée : '+$_.Exception.Message))}
}
function Complete-DomeniaQuerySchemaCollected {
    param($Result,$State)
    try{
        $data=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Mode','Namespace','RequestKey','SourceCompletedUtc','Rows','Schema')
        if($null -eq $data -or $data.Computer -ine $State.Computer -or $data.Namespace -cne $State.Namespace -or $data.Mode -cne $State.Mode -or $data.RequestKey -cne (Get-DomeniaQuerySchemaRequestKey $data.Namespace $data.CanonicalQuery)){throw 'Identité ou définition du résultat WMI incohérente.'}
        $State.RequestKey=[string]$data.RequestKey
        $safe=[ordered]@{};foreach($name in @('Computer','Success','Mode','Namespace','ClassName','CanonicalQuery','RequestKey','Schema','Rows','StoredCount','ObservedCountMinimum','CountComplete','Truncated','BudgetBytes','Limit','DurationMs')){$safe[$name]=Get-DomeniaMemberValue $data $name}
        [void](Submit-DomeniaRemoteDetail -Data ([pscustomobject]$safe) -State $State -Succeeded $true -SourceCompletedUtc ([string]$data.SourceCompletedUtc))
    }catch{Fail-DomeniaQuerySchemaRead $_.Exception.Message $State}
    finally{if($null -ne $State.StopSource){$State.StopSource.Dispose()}}
}
function Fail-DomeniaQuerySchemaCollected {
    param($Message,$State)
    try{if($null -ne $State.StopSource){$State.StopSource.Cancel();$State.StopSource.Dispose()};[void](Submit-DomeniaRemoteDetail -Data ([pscustomobject]@{CollectionError=[string]$Message}) -State $State -Succeeded $false -SourceCompletedUtc ([datetime]::UtcNow.ToString('o')) -ErrorText ([string]$Message))}catch{Fail-DomeniaQuerySchemaRead $_.Exception.Message $State}
}
function Complete-DomeniaQuerySchemaStored {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration -or -not (Test-DomeniaClassicResultCurrent $Result $State)){return}
    if([string]$Result.DataSource -cne 'SQLite'){throw 'Le résultat WMI doit provenir de la base locale.'}
    $q.SchemaReceipt=[pscustomobject]@{Computer=$State.Computer;Guid=$State.StoreGuid;Data=$Result}
    (Get-DomeniaControl 'DgQuerySchema').ItemsSource=@(foreach($field in @($Result.Schema)){[pscustomobject]@{Selected=$false;Property=$field.Property;Type=$field.Type;IsKey=$field.IsKey}})
    (Get-DomeniaControl 'DgQueryWmiRows').ItemsSource=@(foreach($row in @($Result.Rows)){[pscustomobject]@{Id=$row.Id;ClassName=$row.ClassName;KeyValues=$row.KeyValues;Values=$row.Values;ValueText=(ConvertTo-Json -InputObject $row.Values -Depth 5 -Compress);Completeness=$(if(@($row.IncompleteProperties).Count){'Propriétés incomplètes : '+($row.IncompleteProperties -join ', ')}else{'Valeurs conservées'})}})
    (Get-DomeniaControl 'BtnQueryWqlRecipe').IsEnabled=($Result.Mode -ceq 'Select')
    [void](Set-DomeniaControlText 'LblQueryWmiStatus' ($State.Computer+' · '+$Result.StoredCount+' instance(s) mémorisée(s) · '+$(if($Result.Truncated){'lecture partielle, limite atteinte'}else{'lecture complète'})+' · base confirmée · '+$Result.SourceCompletedUtc))
}
function Fail-DomeniaQuerySchemaRead {
    param($Message,$State)
    $q=$script:DomeniaQueryState;if($null -eq $q -or [long]$q.SchemaGeneration -ne [long]$State.SchemaGeneration){return}
    [void](Set-DomeniaControlText 'LblQueryWmiStatus' ('Résultat WMI indisponible : '+[string]$Message))
}
