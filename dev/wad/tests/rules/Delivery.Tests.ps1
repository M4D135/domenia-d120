# Points 143, 144 et 147 : schema de donnees annonce par la mise a jour, plan de desinstallation avec choix explicite
# des donnees locales, politique des donnees locales. Regles pures de Domenia-Release.Model ; manifestes et empreintes fictifs.
function New-DlvManifest {
    $hash = { param([string]$Text) (Get-DomeniaTextHash $Text) }
    return [pscustomobject]@{ Format = 1; Build = '2026.10.15-DOMENIA-1.0-TEST'; Files = @(
        [pscustomobject]@{ Path = 'Domenia.exe'; Sha256 = (& $hash 'exe'); Runtime = $true; PreserveExisting = $false }
        [pscustomobject]@{ Path = 'wad/Domenia-Core.ps1'; Sha256 = (& $hash 'core'); Runtime = $true; PreserveExisting = $false }
        [pscustomobject]@{ Path = 'wad/modules/Domenia-Common.Model.ps1'; Sha256 = (& $hash 'common'); Runtime = $true; PreserveExisting = $false }
        [pscustomobject]@{ Path = 'wad/Domenia.config.json'; Sha256 = (& $hash 'config'); Runtime = $true; PreserveExisting = $true }
        [pscustomobject]@{ Path = 'wad/Support/.lifecycle.lock'; Sha256 = (& $hash 'lock'); Runtime = $true; PreserveExisting = $false }
    ) }
}
function New-DlvObserved {
    $observed = @{}
    foreach ($file in @((New-DlvManifest).Files)) { if (-not $file.PreserveExisting) { $observed[$file.Path] = $file.Sha256 } }
    return $observed
}

Test-Case 'DLV-001' 'Mise a jour avec migration : annoncee avant la reponse, retour arriere averti' {
    $t = Get-DomeniaDataSchemaTransition -ActiveSchema '10' -TargetSchema '11'
    Assert-Equal 'Migration' $t.Direction
    Assert-False $t.RestoreReadsBase
    Assert-True ($t.UpdateNotice -like 'Base locale : migration du schéma 10 vers 11 au premier démarrage, après une sauvegarde vérifiée*') $t.UpdateNotice
    Assert-True ($t.RestoreNotice -like '*refusera une base migrée, sans la modifier*Restaurer une sauvegarde*') $t.RestoreNotice
}

Test-Case 'DLV-002' 'Meme schema, retour a une version plus ancienne et schema inconnu' {
    $same = Get-DomeniaDataSchemaTransition -ActiveSchema '11' -TargetSchema '11'
    Assert-Equal 'Identique' $same.Direction; Assert-True $same.RestoreReadsBase
    Assert-Equal 'Base locale : même schéma de données (11) ; aucune migration.' $same.UpdateNotice
    $older = Get-DomeniaDataSchemaTransition -ActiveSchema '11' -TargetSchema '10'
    Assert-Equal 'Retour' $older.Direction; Assert-True $older.RestoreReadsBase
    Assert-True ($older.UpdateNotice -like '*refusera une base déjà migrée, sans la modifier*') $older.UpdateNotice
    foreach ($pair in @(@('','11'),@('11',''),@('abc','11'),@('0','11'),@('11','999999'))) {
        $unknown = Get-DomeniaDataSchemaTransition -ActiveSchema $pair[0] -TargetSchema $pair[1]
        Assert-Equal 'Inconnu' $unknown.Direction ([string]::Join('/',[string[]]$pair))
        Assert-False $unknown.RestoreReadsBase
        Assert-True ($unknown.UpdateNotice -like '*aucune migration nʼest annoncée*') $unknown.UpdateNotice
    }
}

Test-Case 'DLV-003' 'Desinstallation par defaut : code intact retire, donnees et preferences conservees, verrou en dernier' {
    $plan = Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed (New-DlvObserved)
    Assert-True $plan.Allowed ([string]::Join(' ',[string[]]$plan.Blockers))
    Assert-Equal 'Domenia.exe,wad/Domenia-Core.ps1,wad/modules/Domenia-Common.Model.ps1,wad/package-manifest.json,wad/Support/.lifecycle.lock' ([string]::Join(',',[string[]]$plan.RemoveCode))
    Assert-Equal 0 @($plan.LocalFolders).Count; Assert-Equal 0 @($plan.RemoveSettings).Count; Assert-Equal 0 @($plan.ProfileFolders).Count
    Assert-Equal 'wad/Domenia.config.json' ([string]::Join(',',[string[]]$plan.Settings))
    Assert-False $plan.RemovesFolder
    $text = [string]::Join(' | ',[string[]]$plan.Lines)
    foreach ($needle in @('Données de ce dossier conservées','Données Domenia du profil Windows conservées','Gestionnaire dʼidentification Windows : jamais supprimés')) { Assert-True ($text -like ('*' + $needle + '*')) ($needle + ' : ' + $text) }
}

Test-Case 'DLV-004' 'Choix explicites : donnees du dossier et du profil supprimees seulement sur demande' {
    $plan = Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed (New-DlvObserved) -LocalData Supprimer -ProfileData Supprimer
    Assert-Equal 'wad/data,wad/maintenance/backups' ([string]::Join(',',[string[]]$plan.LocalFolders))
    Assert-Equal 'wad/Domenia.config.json' ([string]::Join(',',[string[]]$plan.RemoveSettings))
    Assert-Equal 'Domenia\Data,Domenia\Receipts' ([string]::Join(',',[string[]]$plan.ProfileFolders))
    Assert-True $plan.RemovesFolder
    $local = Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed (New-DlvObserved) -LocalData Supprimer
    Assert-Equal 0 @($local.ProfileFolders).Count 'le profil reste sans choix explicite'
    Assert-Throws { Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed (New-DlvObserved) -LocalData Peut-etre } 'choix inconnu accepte'
}

Test-Case 'DLV-005' 'Fichier modifie conserve et nomme, fichier absent ignore, le dossier reste' {
    $observed = New-DlvObserved
    $observed['wad/modules/Domenia-Common.Model.ps1'] = Get-DomeniaTextHash 'modifie localement'
    $observed.Remove('Domenia.exe')
    $plan = Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed $observed -LocalData Supprimer
    Assert-Equal 'wad/modules/Domenia-Common.Model.ps1' ([string]::Join(',',[string[]]$plan.KeepModified))
    Assert-Equal 'Domenia.exe' ([string]::Join(',',[string[]]$plan.Absent))
    Assert-True (@($plan.RemoveCode) -notcontains 'wad/modules/Domenia-Common.Model.ps1')
    Assert-False $plan.RemovesFolder
    Assert-True (([string]::Join(' ',[string[]]$plan.Lines)) -like '*modifié(s) depuis lʼinstallation : conservé(s)*')
}

Test-Case 'DLV-006' 'Refus : arbre DEV, mise a jour inachevee, manifeste incomplet ou visant les donnees' {
    Assert-False (Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed (New-DlvObserved) -DevTree $true).Allowed
    Assert-False (Get-DomeniaUninstallPlan -Manifest (New-DlvManifest) -Observed (New-DlvObserved) -PendingInstall $true).Allowed
    Assert-False (Get-DomeniaUninstallPlan -Manifest ([pscustomobject]@{ Format = 1; Build = ''; Files = @() }) -Observed @{}).Allowed
    $bad = New-DlvManifest
    $bad.Files = @($bad.Files) + @([pscustomobject]@{ Path = 'wad/data/Domenia.db'; Sha256 = (Get-DomeniaTextHash 'db'); Runtime = $true; PreserveExisting = $false })
    $plan = Get-DomeniaUninstallPlan -Manifest $bad -Observed (New-DlvObserved)
    Assert-False $plan.Allowed
    Assert-True (([string]::Join(' ',[string[]]$plan.Blockers)) -like '*wad/data/Domenia.db*')
    $escape = New-DlvManifest
    $escape.Files = @($escape.Files) + @([pscustomobject]@{ Path = '../Windows/system.ini'; Sha256 = (Get-DomeniaTextHash 'x'); Runtime = $true; PreserveExisting = $false })
    Assert-False (Get-DomeniaUninstallPlan -Manifest $escape -Observed (New-DlvObserved)).Allowed
}

# Point 147 : politique des donnees locales (Domenia-DataPolicy.Model, reglages de Domenia-Store.Model).
. (Join-Path $modules 'Domenia-Store.Model.ps1')
. (Join-Path $modules 'Domenia-DataPolicy.Model.ps1')

Test-Case 'DPO-001' 'Chaque donnee gardee sur le poste a son contenu, son emplacement, sa conservation, son export et sa suppression' {
    $view = Get-DomeniaLocalDataPolicy -DataRoot 'C:\Users\agent\AppData\Local\Domenia\Data' -ReceiptRoot 'C:\Users\agent\AppData\Local\Domenia\Receipts'
    $rows = @($view.Rows)
    Assert-Equal 12 $rows.Count
    Assert-Equal 12 @($rows | ForEach-Object { $_.Category } | Sort-Object -Unique).Count 'categories en double'
    foreach ($row in $rows) { foreach ($field in @('Label','Content','Location','Retention','Export','Deletion')) { Assert-True ([string]$row.$field) ($row.Category + ' : ' + $field + ' vide') } }
    Assert-True ($view.Statement -like 'Domenia nʼenvoie aucune donnée hors de ce poste*') $view.Statement
    Assert-Equal 'C:\Users\agent\AppData\Local\Domenia\Data\Logs' @($rows | Where-Object { $_.Category -eq 'Log' })[0].Location
    Assert-Equal 'C:\Users\agent\AppData\Local\Domenia\Receipts' @($rows | Where-Object { $_.Category -eq 'Receipt' })[0].Location
}

Test-Case 'DPO-002' 'La conservation affichee vient des reglages enregistres : 0 sans limite, sinon jours confirmes' {
    $policy = [pscustomobject]@{ Version = 1; AutomaticBackup = $true; BackupHours = 12; BackupKeep = 5; PresenceDays = 0; ConsoleDays = 90; InventoryDays = 200; ProbeDays = 90; DetailDays = 30 }
    $rows = @((Get-DomeniaLocalDataPolicy -Policy $policy).Rows)
    $byCategory = @{}; foreach ($row in $rows) { $byCategory[$row.Category] = $row }
    Assert-Equal 'Sans limite de durée.' $byCategory['Presence'].Retention
    Assert-True ($byCategory['Inventory'].Retention -like '200 jours, appliqués après prévisualisation et confirmation*') $byCategory['Inventory'].Retention
    Assert-True ($byCategory['Backup'].Retention -like 'Toutes les 12 h pendant que Domenia est ouvert, 5 copies conservées.*hors rotation.') $byCategory['Backup'].Retention
    $manual = @((Get-DomeniaLocalDataPolicy).Rows | Where-Object { $_.Category -eq 'Backup' })[0]
    Assert-True ($manual.Retention -like 'Sauvegarde automatique désactivée*') $manual.Retention
}

Test-Case 'DPO-003' 'Emplacements : inconnus annonces comme tels, sauvegardes a cote de la base active' {
    $rows = @((Get-DomeniaLocalDataPolicy).Rows)
    foreach ($category in @('Directory','Backup','Log','Receipt','Preference')) {
        Assert-True (@($rows | Where-Object { $_.Category -eq $category })[0].Location -like 'Emplacement non déterminé*') $category
    }
    $withBase = @((Get-DomeniaLocalDataPolicy -DataRoot 'D:\Domenia\Data' -DatabasePath 'D:\Bases\cnamts\Domenia.db').Rows)
    Assert-Equal 'D:\Bases\cnamts\Backups' @($withBase | Where-Object { $_.Category -eq 'Backup' })[0].Location
    Assert-Equal 'D:\Bases\cnamts\Domenia.db' @($withBase | Where-Object { $_.Category -eq 'Inventory' })[0].Location
}

Test-Case 'DPO-004' 'Reglages illisibles : conservation inconnue, jamais une valeur par defaut presentee comme reglee' {
    $rows = @((Get-DomeniaLocalDataPolicy -PolicyUnreadable).Rows)
    foreach ($category in @('Presence','Console','Inventory','Probe','Detail')) {
        Assert-Equal 'Réglages de conservation illisibles : durée inconnue.' @($rows | Where-Object { $_.Category -eq $category })[0].Retention $category
    }
    Assert-True (@($rows | Where-Object { $_.Category -eq 'Backup' })[0].Retention -like 'Réglages de sauvegarde illisibles*')
    Assert-Throws { Get-DomeniaLocalDataPolicy -Policy ([pscustomobject]@{ Version = 1; BackupHours = 0 }) } 'reglage hors limites accepte'
}

# Point 148 : premiers pas (Domenia-FirstRun.Model).
. (Join-Path $modules 'Domenia-FirstRun.Model.ps1')

Test-Case 'FRN-001' 'Quatre etapes dans lʼordre : connexion, OU de travail, premiere lecture, tableau de bord' {
    $plan = Get-DomeniaFirstRunPlan
    Assert-Equal 'Connection,Ou,Base,Dashboard' ([string]::Join(',',[string[]]@($plan.Steps | ForEach-Object { $_.Name })))
    Assert-Equal 'Connection' $plan.Next
    Assert-False $plan.Done
    foreach ($step in @($plan.Steps)) { Assert-False $step.Done $step.Name }
    Assert-False @($plan.Steps)[1].Enabled 'OU proposee sans connexion'
    Assert-False @($plan.Steps)[3].Enabled 'tableau de bord propose sans premiere lecture'
    Assert-True ($plan.Deferred -like 'Plus tard, au moment où ils servent*Comptes et accès*Stockage*') $plan.Deferred
}

Test-Case 'FRN-002' 'Progression : chaque etape est lue dans la session, la suivante est mise en avant' {
    $plan = Get-DomeniaFirstRunPlan -Domain 'example.invalid' -Account 'EXAMPLE\agent'
    Assert-Equal 'Ou' $plan.Next
    Assert-Equal 'Connecté à example.invalid avec EXAMPLE\agent.' @($plan.Steps)[0].Text
    $plan = Get-DomeniaFirstRunPlan -Domain 'example.invalid' -ScopeDn 'OU=Postes,DC=example,DC=invalid' -ScopeName 'Postes'
    Assert-Equal 'Base' $plan.Next
    Assert-Equal 'OU de travail : Postes.' @($plan.Steps)[1].Text
    $plan = Get-DomeniaFirstRunPlan -Domain 'example.invalid' -ScopeDn 'OU=Postes,DC=example,DC=invalid' -IndexedObjects 1200
    Assert-Equal 'Dashboard' $plan.Next
    Assert-True @($plan.Steps)[3].Enabled
    Assert-Equal 'Première lecture faite : 1200 objet(s) dans la base locale.' @($plan.Steps)[2].Text
    $plan = Get-DomeniaFirstRunPlan -Domain 'example.invalid' -ScopeDn 'OU=Postes,DC=example,DC=invalid' -IndexedObjects 1200 -DashboardSeen $true
    Assert-True $plan.Done; Assert-Equal '' $plan.Next
}

Test-Case 'FRN-003' 'Un tableau de bord vu sans base lue nʼest pas une etape faite ; une OU sans nom affiche son DN' {
    $plan = Get-DomeniaFirstRunPlan -Domain 'example.invalid' -ScopeDn 'OU=Postes,DC=example,DC=invalid' -DashboardSeen $true
    Assert-False @($plan.Steps)[3].Done
    Assert-Equal 'OU de travail : OU=Postes,DC=example,DC=invalid.' @($plan.Steps)[1].Text
    Assert-Equal 'Connecté à example.invalid.' @((Get-DomeniaFirstRunPlan -Domain 'example.invalid').Steps)[0].Text
}
