# Points 151-158 (moteur de requêtes avancé) : règles pures sans DLL de requête, sans WMI ni réseau. Les cas qui
# évaluent des QueryRecord sont dans Test-DomeniaQueryAdvanced.ps1 (DLL réelle).
. (Join-Path $modules 'Domenia-QuerySchema.Model.ps1')
. (Join-Path $modules 'Domenia-Query.Model.ps1')
. (Join-Path $modules 'Domenia-QueryLibrary.Model.ps1')

Test-Case -Id 'P155' -Name 'Analyse WQL : propriétés, clés ajoutées, condition, préconditions, limites et prudence' -Body {
    $report = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query "SELECT State, StartMode FROM Win32_Service WHERE StartMode = 'Auto'" -Limit 50 -KnownProperties @('Name','State','StartMode','ProcessId') -KeyProperties @('Name') -SchemaClass 'Win32_Service' -Computer 'PC-01'
    Assert-True $report.Valid 'requête valide'
    Assert-Equal 'Win32_Service' $report.ClassName
    Assert-Equal 'Name' (@($report.KeyProperties) -join ',') 'la clé non demandée est ajoutée pour conserver lʼidentité'
    Assert-Equal 0 @($report.MissingProperties).Count 'propriétés présentes dans le schéma relu'
    Assert-True ($report.Text -like '*Condition WHERE sur : StartMode*') 'condition WHERE nommée'
    Assert-True ($report.Text -like '*(+ clés : Name)*') 'clé annoncée'
    Assert-True ($report.Text -like '*50 instances au plus, 1 Mio*50 secondes*') 'limites explicites'
    Assert-True ($report.Text -like '*ne garantit pas quʼun fournisseur est sans effet de bord*') 'prudence sur les fournisseurs'
    Assert-False $report.Ready 'jamais prête sans test sur le poste'
    Assert-True ($report.Text -like '*Pas encore testée sous cette forme sur ce poste*') 'statut de test annoncé'
}
Test-Case -Id 'P155' -Name 'Analyse WQL : propriété absente, MSI, instruction multiple, limite et fournisseur coûteux' -Body {
    $missing = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Foo FROM Win32_Service' -KnownProperties @('Name','State') -KeyProperties @('Name') -SchemaClass 'Win32_Service'
    Assert-Equal 'Foo' (@($missing.MissingProperties) -join ',')
    Assert-True ($missing.Text -like '*Propriétés absentes du schéma relu : Foo*') 'propriété absente signalée avant lecture'
    $msi = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Name FROM Win32_Product'
    Assert-False $msi.Valid 'fournisseur MSI refusé'
    Assert-True ($msi.Text -like 'Requête non exécutable : Fournisseur MSI interdit*') 'refus MSI expliqué'
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Name FROM Win32_Service; SELECT Name FROM Win32_Process').Valid 'une seule instruction'
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Name FROM Win32_Service' -Limit 0).Valid 'limite explicite'
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\..\x' -Query 'SELECT Name FROM Win32_Service').Valid 'espace de noms contrôlé'
    $costly = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Name FROM CIM_DataFile'
    Assert-True ($costly.Valid -and @($costly.Warnings | Where-Object { $_ -like 'Classe CIM_DataFile*Sans clause WHERE*' }).Count -eq 1) 'parcours du disque signalé'
    $schemaUnknown = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Name FROM Win32_Service'
    Assert-True ($schemaUnknown.Text -like '*non relu pour ce poste*plus les clés du fournisseur*') 'schéma non relu annoncé'
}
Test-Case -Id 'P155' -Name 'Analyse WQL : une recette exige un test de la même requête sur le même poste' -Body {
    $query = "SELECT Name, State FROM Win32_Service WHERE State = 'Running'"
    $canonical = (ConvertFrom-DomeniaWqlSelect $query).CanonicalQuery
    $tested = [pscustomobject]@{ Mode = 'Select'; CanonicalQuery = $canonical; Namespace = 'ROOT\CIMV2'; Computer = 'PC-01'; At = '15/10/2026 08:00' }
    Assert-True (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query $query -Tested $tested -Computer 'pc-01').Ready 'même requête, même poste'
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query "SELECT Name FROM Win32_Service" -Tested $tested -Computer 'PC-01').Ready 'requête modifiée'
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query $query -Tested $tested -Computer 'PC-02').Ready 'autre poste'
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query $query -Tested $tested -Computer '').Ready 'aucun poste choisi'
    $schema = [pscustomobject]@{ Mode = 'Schema'; CanonicalQuery = $canonical; Namespace = 'root\cimv2'; Computer = 'PC-01'; At = '' }
    Assert-False (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query $query -Tested $schema -Computer 'PC-01').Ready 'un schéma lu nʼest pas un test'
    Assert-Equal 'State' ((ConvertFrom-DomeniaWqlSelect $query).WhereProperties -join ',') 'propriétés de la condition distinguées'
}
Test-Case -Id 'P155' -Name 'Analyse WQL : jamais tous les comptes ou groupes du domaine depuis un poste' -Body {
    $domainWide = @(
        'SELECT Name FROM Win32_UserAccount',
        "SELECT Name FROM Win32_Group WHERE Name = 'Administrateurs'",
        'SELECT Name FROM Win32_Account WHERE LocalAccount = FALSE',
        'SELECT Name FROM Win32_UserAccount WHERE NOT LocalAccount = TRUE',
        "SELECT Name FROM Win32_UserAccount WHERE LocalAccount = TRUE OR Name = 'Invité'",
        "SELECT Name FROM win32_useraccount WHERE Domain = 'PC-01'",
        "SELECT Name FROM Win32_UserAccount WHERE LocalAccount = 'TRUE'")
    foreach ($query in $domainWide) {
        $report = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query $query -Computer 'PC-01'
        Assert-False $report.Valid ('lecture du domaine refusée : ' + $query)
        Assert-True ($report.Message -like '*refusée sans LocalAccount = TRUE*comptes locaux du poste*') ('remède indiqué : ' + $query)
        Assert-Throws { New-DomeniaQueryReadDefinition -Namespace 'root\cimv2' -Query $query } ('aucune recette possible : ' + $query)
    }
    $localOnly = @(
        'SELECT Name FROM Win32_UserAccount WHERE LocalAccount = TRUE',
        'SELECT Name, Disabled FROM Win32_UserAccount WHERE localaccount = true AND Disabled = FALSE',
        "SELECT Name FROM Win32_Group WHERE Name = 'Administrateurs' AND LocalAccount = TRUE",
        "SELECT Name FROM Win32_Account WHERE (LocalAccount = TRUE AND Disabled = FALSE) OR (Name = 'Invité' AND LocalAccount = TRUE)")
    foreach ($query in $localOnly) {
        Assert-True (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query $query -Computer 'PC-01').Valid ('comptes locaux acceptés : ' + $query)
        Assert-Equal 'Domenia.WmiRead/1' (New-DomeniaQueryReadDefinition -Namespace 'root\cimv2' -Query $query).Format ('recette possible : ' + $query)
    }
    foreach ($class in @('Win32_GroupUser', 'Win32_GroupInDomain', 'Win32_UserInDomain', 'Win32_AccountSID', 'cim_logicalelement', 'CIM_ManagedSystemElement')) {
        $report = Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query ('SELECT Name FROM ' + $class + ' WHERE LocalAccount = TRUE')
        Assert-False $report.Valid ('classe refusée même avec une condition : ' + $class)
        Assert-True ($report.Message -like ('Classe ' + $class + ' refusée*domaine*')) ('refus expliqué : ' + $class)
    }
    Assert-True (Get-DomeniaWqlPlanReport -Namespace 'root\cimv2' -Query 'SELECT Name FROM Win32_SystemAccount').Valid 'comptes système, toujours locaux'
}
Test-Case -Id 'P154' -Name 'Exploration WMI : espace de noms et filtre de classes contrôlés' -Body {
    Assert-Throws { Assert-DomeniaQuerySchemaNamespace 'root\cimv2;x' } 'espace de noms invalide'
    Assert-Throws { Assert-DomeniaQuerySchemaNamespace 'cimv2' } 'racine obligatoire'
    Assert-DomeniaQuerySchemaNamespace 'root\Microsoft\Windows\Storage'
    foreach ($filter in @('', 'Win32_*', 'MSFT_PhysicalDisk', '__NAMESPACE')) { Assert-DomeniaQuerySchemaClassFilter $filter }
    foreach ($filter in @('*', 'Win32_* OR 1=1', "Win32_Service'", 'Win*32', '%')) { Assert-Throws { Assert-DomeniaQuerySchemaClassFilter $filter } ('filtre refusé : ' + $filter) }
}
Test-Case -Id 'P154' -Name 'Opérations de lʼatelier classées : QuerySchema lecture CIM du poste, QueryTransfer fichiers locaux' -Body {
    $schema = Get-DomeniaOperationCredentialNeeds 'QuerySchema'
    Assert-Equal 'Cim' $schema.Provider
    Assert-Equal 'Remote' $schema.Resource
    Assert-True ($schema.Machine -and $schema.Remote -and $schema.NonDirectory) 'compte distant du poste, sans canal AD'
    Assert-False $schema.DirectoryBreaker 'un refus sur le poste ne suspend pas lʼannuaire'
    Assert-Equal 'Read' (Get-DomeniaOperationEffect 'QuerySchema')
    Assert-Equal '' (Get-DomeniaTaskDedupKey -OperationId 'QuerySchema' -Payload ([pscustomobject]@{ Computer = 'PC-01' })) 'lecture explicite jamais mutualisée'
    $transfer = Get-DomeniaOperationCredentialNeeds 'QueryTransfer'
    Assert-Equal 'Storage' $transfer.Provider
    Assert-Equal 'Local' $transfer.Resource
    Assert-False ($transfer.Directory -or $transfer.RemoteAdmin) 'aucun compte AD ni distant pour un export de fichier'
}
Test-Case -Id 'P156' -Name 'Relations WMI : associations déclarées, références par identité, aucune jointure libre' -Body {
    Assert-Equal 'Win32_DiskDriveToDiskPartition' (@(Get-DomeniaWmiRelationPresets 'win32_diskdrive')[0].Association)
    Assert-Equal 2 @(Get-DomeniaWmiRelationPresets 'Win32_DiskPartition').Count 'partition vers disque et vers volume'
    Assert-Equal 'Win32_DiskPartition' (@(Get-DomeniaWmiRelationPresets 'Win32_LogicalDisk')[0].Result)
    $service = Get-DomeniaWmiRelationPreset -SourceClass 'Win32_Service' -SourceProperty 'ProcessId' -TargetClass 'Win32_Process' -TargetProperty 'Handle'
    Assert-True ($null -ne $service -and $service.ValueKind -ceq 'String' -and @($service.Properties) -notcontains 'CommandLine') 'processus hôte lu par sa clé, sans ligne de commande'
    Assert-True ($null -eq (Get-DomeniaWmiRelationPreset -SourceClass 'Win32_Service' -SourceProperty 'Name' -TargetClass 'Win32_Process' -TargetProperty 'Name')) 'aucun rapprochement par nom'
    Assert-True ($null -eq (Get-DomeniaWmiRelationPreset -SourceClass 'Win32_DiskDrive' -SourceProperty 'DeviceID' -TargetClass 'Win32_DiskPartition' -TargetProperty 'DeviceID')) 'une association nʼest pas une référence'
    Assert-Equal '1234' (ConvertTo-DomeniaWmiReferenceValue -Preset $service -Value 1234)
    Assert-Equal '42' (ConvertTo-DomeniaWmiReferenceValue -Preset $service -Value ' 42 ')
    foreach ($bad in @("1 OR 1=1", "1'", '-1', '1.5', '99999999999')) { Assert-Throws { ConvertTo-DomeniaWmiReferenceValue -Preset $service -Value $bad } ('valeur refusée : ' + $bad) }
    Assert-Throws { ConvertTo-DomeniaWmiReferenceValue -Preset $service -Value 0 } 'service arrêté : pas de processus hôte'
    Assert-Throws { ConvertTo-DomeniaWmiReferenceValue -Preset $service -Value $null } 'propriété non lue'
}
Test-Case -Id 'P151' -Name 'Fenêtre commune proposée : seuil, plafond des mesures instantanées et cas sans date' -Body {
    $proposal = Get-DomeniaQueryCoherenceProposal -Spreads (@(2.0) * 9 + @(100.0)) -SourceCount 3 -Volatile $true
    Assert-True ($proposal.Needed -and $proposal.Hours -eq 6 -and $proposal.Covered -eq 9) 'plus petite fenêtre couvrant 90 %'
    Assert-Equal 1 (Get-DomeniaQueryCoherenceProposal -Spreads @(0.2, 0.5) -SourceCount 2).Hours 'sources quasi simultanées'
    Assert-True ($null -eq (Get-DomeniaQueryCoherenceProposal -Spreads @(10000.0) -SourceCount 2).Hours) 'pas de fenêtre au-delà dʼun an'
    Assert-False (Get-DomeniaQueryCoherenceProposal -Spreads @(1.0) -SourceCount 1).Needed 'une seule source'
    Assert-Equal '168 h (7 jours)' (Format-DomeniaQueryHours 168)
    Assert-Equal '1,5 h' (Format-DomeniaQueryHours 1.5)
    Assert-True (Test-DomeniaQueryVolatileKey '_at:probe:hw.batterylevel') 'batterie instantanée'
    Assert-False (Test-DomeniaQueryVolatileKey '_at:detail:abc') 'SELECT mémorisé daté par sa lecture'
}
Test-Case -Id 'P158' -Name 'Répartition : page bornée, filtre, inconnu en dernier et graphique au total exact' -Body {
    $categories = @(for ($i = 1; $i -le 250; $i++) { [pscustomobject]@{ Rank = $i; Label = ('Modèle ' + $i); Value = ('Modèle ' + $i); Count = [long](300 - $i); Missing = $false } })
    $known = 0L; foreach ($category in $categories) { $known += $category.Count }
    $summary = [pscustomobject]@{ Field = 'model'; Categories = $categories; CategoryCount = [long]250; Missing = [long]7; Matched = ($known + 7); Total = ($known + 7); Unknown = [long]0; NotMatched = [long]0 }
    $page = Get-DomeniaQueryGroupPage -Summary $summary -Offset 200 -Limit 100
    Assert-Equal 51 @($page.Rows).Count 'cinquante valeurs et la valeur inconnue'
    Assert-Equal 'Valeur inconnue' $page.Rows[50].Label
    Assert-True $page.Rows[50].Select.Missing 'sélection de lʼinconnu'
    Assert-False $page.HasNext 'dernière page'
    $filtered = Get-DomeniaQueryGroupPage -Summary $summary -Text 'modele 25'
    Assert-Equal 4 $filtered.Filtered 'filtre sans accent ni casse sur toute la répartition (25, 125, 225, 250)'
    $items = @(ConvertTo-DomeniaQueryGroupItems -Summary $summary -Top 10)
    $sum = 0L; foreach ($item in $items) { $sum += [long]$item.Value }
    Assert-Equal 12 $items.Count 'dix valeurs, reste et inconnu'
    Assert-Equal ([long]$summary.Matched) $sum 'total exact conservé'
    Assert-Equal 10 @($items[10].Select.Excluded).Count 'le reste exclut exactement les dix valeurs affichées'
    Assert-Throws { Get-DomeniaQueryGroupPage -Summary $summary -Limit 0 } 'page vide refusée'
    Assert-Throws { ConvertTo-DomeniaQueryGroupItems -Summary $summary -Top 65 } 'nombre de valeurs affichées borné'
    Assert-Equal 'Oui' (ConvertTo-DomeniaQueryGroupLabel $true)
    Assert-Equal '7,5' (ConvertTo-DomeniaQueryGroupLabel ([decimal]7.5))
}
Test-Case -Id 'P153' -Name 'Impact dʼune recette : widgets liés ou non, lien orphelin, vue de Recherche, autres recettes exclues' -Body {
    $layouts = @{ Fleet = @([pscustomobject]@{ Id = 'w1'; Source = 'Query'; Key = 'r.a'; Title = 'A' }, [pscustomobject]@{ Id = 'w2'; Source = 'Query'; Key = 'r.b'; Title = 'B' }); Computer = @([pscustomobject]@{ Id = 'w3'; Source = 'Query'; Key = 'r.a'; Title = '' }) }
    $links = @([pscustomobject]@{ RecipeId = 'r.a'; ConsumerKind = 'Fleet'; ConsumerId = 'w1'; BoundRevision = 4 }, [pscustomobject]@{ RecipeId = 'r.a'; ConsumerKind = 'Computer'; ConsumerId = 'gone'; BoundRevision = 2 })
    $impact = Get-DomeniaQueryRecipeImpact -RecipeId 'r.a' -Dependencies $links -Layouts $layouts -SearchFavorites @('local:r.a') -CurrentRevision 4
    Assert-Equal 4 $impact.Count
    Assert-Equal 2 $impact.Widgets
    Assert-Equal 1 $impact.Orphans
    Assert-Equal 1 $impact.Views
    Assert-Equal 'Lié à la révision 4' (@($impact.Rows | Where-Object { $_.ConsumerId -eq 'w1' })[0].Link)
    Assert-True ((@($impact.Rows | Where-Object { $_.ConsumerId -eq 'w3' })[0].Link) -like 'Widget sans lien*') 'widget sans lien transactionnel'
    Assert-Equal 0 @($impact.Rows | Where-Object { $_.ConsumerId -eq 'w2' }).Count 'autre recette exclue'
}
Test-Case -Id 'P157' -Name 'Export PowerShell : commentaires sur une ligne et littéral JSON ASCII' -Body {
    Assert-Equal 'a b c' (ConvertTo-DomeniaScriptCommentText ("a`r`nb" + [char]0x2029 + 'c'))
    Assert-Equal ('x' * 10 + '…') (ConvertTo-DomeniaScriptCommentText ('x' * 20) -MaxLength 10)
    Assert-Equal '"\u2019\u00e9"' (ConvertTo-DomeniaAsciiJson ('"' + [char]0x2019 + [char]0xE9 + '"'))
    Assert-Equal 'paramètre Seuil' (ConvertTo-DomeniaQueryValueText ([pscustomobject]@{ Parameter = 'Seuil' }))
    Assert-Equal 'Non' (ConvertTo-DomeniaQueryValueText $false)
    Assert-Equal '7.5' (ConvertTo-DomeniaQueryValueText ([decimal]7.5))
}
