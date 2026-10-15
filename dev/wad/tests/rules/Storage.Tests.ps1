# Points 31-40 : stockage local, sauvegardes, intégrité, conservation et limites. Données fictives uniquement.
. (Join-Path $modules 'Domenia-Store.Model.ps1')
$script:StorageNow=[datetime]::SpecifyKind([datetime]'2026-03-10T12:00:00',[DateTimeKind]::Utc)
function New-StorageTestInspection {
    param([long]$SourceObjects=120,$Active=$null,[bool]$Writable=$true)
    $counts=[pscustomobject]@{ad_objects=$SourceObjects;domenia_observations=40;domenia_details=0;user_machine_links=3;domenia_query_recipes=1;domenia_store_batches=9}
    return [pscustomobject]@{
        Source=[pscustomobject]@{Path='C:\Base\a.db';DomainDn='dc=test';Revision=7;Integrity='ok';Bytes=1048576;Fingerprint=('a'*64);LastWriteUtc=$script:StorageNow.ToString('o');LastCommitUtc='';LastObservationUtc='';Counts=$counts}
        Active=$Active
        Target=[pscustomobject]@{Path='D:\Base\b.db';FreeBytes=10737418240;RequiredBytes=35651584;Writable=$Writable}
    }
}
function New-StorageTestReport {
    param([hashtable]$Status=@{},[bool]$Readable=$true)
    $checks=@(foreach($id in @('Open','Schema','Tables','Identity','Redirect','Receipts','ForeignKeys','QuickCheck','Wal')){$value='Ok';if($Status.ContainsKey($id)){$value=[string]$Status[$id]};[pscustomobject]@{Id=$id;Status=$value;Detail='détail'}})
    return [pscustomobject]@{Kind='StorageIntegrity';ReadOnly=$true;Readable=$Readable;CheckedUtc=$script:StorageNow.ToString('o');DurationMs=12;Checks=$checks}
}

Test-Case 'P37' 'La politique ajoute lʼhistorique des associations sans changer de version' {
    $p=ConvertTo-DomeniaStoragePolicy
    Assert-Equal 0 $p.LinkHistoryDays 'défaut : historique conservé sans limite'
    Assert-Equal 1 $p.Version 'version inchangée'
    $old=ConvertTo-DomeniaStoragePolicy ([pscustomobject]@{Version=1;AutomaticBackup=$true;BackupHours=12;BackupKeep=5;PresenceDays=10;ConsoleDays=20;InventoryDays=30;ProbeDays=40;DetailDays=50})
    Assert-Equal 0 $old.LinkHistoryDays 'politique enregistrée avant la clé : aucun résumé sans choix explicite'
    Assert-Equal 365 (ConvertTo-DomeniaStoragePolicy ([pscustomobject]@{LinkHistoryDays=365})).LinkHistoryDays 'durée choisie'
    Assert-Throws {ConvertTo-DomeniaStoragePolicy ([pscustomobject]@{LinkHistoryDays=-1})} 'négatif refusé'
    Assert-Throws {ConvertTo-DomeniaStoragePolicy ([pscustomobject]@{LinkHistoryDays=36501})} 'trop grand refusé'
}
Test-Case 'P31' 'La réserve de copie vaut deux fois la base plus 32 Mo' {
    Assert-Equal 33554432L (Get-DomeniaStorageCopyReserve 0) 'base vide'
    Assert-Equal 33556432L (Get-DomeniaStorageCopyReserve 1000) 'deux fois plus marge'
    Assert-Throws {Get-DomeniaStorageCopyReserve -1} 'taille inconnue'
}
Test-Case 'P36' 'Seule une corruption prouvée rend la base illisible' {
    foreach($text in @('SQLite prepare code 26 : file is not a database','SQLite step code 11 : database disk image is malformed','Integrite SQLite non confirmee.','Controle du stockage impossible : SQLite 26')){Assert-True (Test-DomeniaStorageUnreadableMessage $text) $text}
    foreach($text in @('SQLite step code 5 : database is locked','Domaine de base absent ou different.','SQLite code 110','')){Assert-False (Test-DomeniaStorageUnreadableMessage $text) $text}
}
Test-Case 'P36' 'Les manques du schéma sont nommés table par table et colonne par colonne' {
    $expected=Get-DomeniaStorageSchemaExpectation
    $columns=@{};foreach($table in @($expected.Columns.Keys)){$columns[$table]=@($expected.Columns[$table])}
    Assert-Equal 0 @(Get-DomeniaStorageSchemaGaps -Tables @($expected.Tables) -Columns $columns).Count 'schéma complet'
    $gaps=@(Get-DomeniaStorageSchemaGaps -Tables @($expected.Tables|Where-Object{$_ -ne 'domenia_details'}) -Columns $columns)
    Assert-Equal 1 $gaps.Count 'une seule table manquante, sans ses colonnes'
    Assert-Equal 'table domenia_details' $gaps[0] 'table nommée'
    $partial=@{};foreach($table in @($columns.Keys)){$partial[$table]=@($columns[$table])}
    $partial['domenia_observations']=@($columns['domenia_observations']|Where-Object{$_ -ne 'summary_payload'})
    $gaps=@(Get-DomeniaStorageSchemaGaps -Tables @($expected.Tables) -Columns $partial)
    Assert-Equal 'colonne domenia_observations.summary_payload' $gaps[0] 'colonne nommée'
}
Test-Case 'P31' 'Lʼaperçu du déplacement montre destination, réserve et retour arrière' {
    $preview=Get-DomeniaStorageMaintenancePreview -Mode Move -Inspection (New-StorageTestInspection)
    Assert-True ($preview.Text -like '*Base à déplacer*') 'source'
    Assert-True ($preview.Text -like '*D:\Base\b.db*') 'destination'
    Assert-True ($preview.Text -like '*réserve exigée*') 'réserve'
    Assert-True ($preview.Text -like '*Retour arrière*') 'retour arrière'
    Assert-Equal 'Déplacer la base locale' $preview.Title 'titre'
}
Test-Case 'P34' 'Lʼaperçu de restauration compare la sauvegarde à la base active' {
    $active=[pscustomobject]@{Readable=$true;Problem='';Info=[pscustomobject]@{Revision=12;Counts=[pscustomobject]@{ad_objects=150;domenia_observations=40;domenia_details=0;user_machine_links=3;domenia_query_recipes=1;domenia_store_batches=20}}}
    $text=(Get-DomeniaStorageMaintenancePreview -Mode Restore -Inspection (New-StorageTestInspection -Active $active)).Text
    Assert-True ($text -like '*30 objet(s) AD de moins*') 'écart annoncé'
    Assert-True ($text -like '*Sauvegarde choisie*') 'sauvegarde datée'
    Assert-True ($text -like '*aucun reçu daté*') 'date inconnue dite inconnue'
}
Test-Case 'P34' 'Une base active illisible est annoncée intacte, sans marque' {
    $active=[pscustomobject]@{Readable=$false;Problem='SQLite prepare code 26 : file is not a database';Info=$null}
    $text=(Get-DomeniaStorageMaintenancePreview -Mode Restore -Inspection (New-StorageTestInspection -Active $active)).Text
    Assert-True ($text -like '*Base active illisible*') 'illisible'
    Assert-True ($text -like '*file is not a database*') 'raison'
    Assert-False ($text -like '*Revenir à la base précédente*') 'aucun retour promis vers une base illisible'
}
Test-Case 'P31' 'Le retour arrière annoncé est celui que lʼassistant offre après la bascule' {
    $move=(Get-DomeniaStorageMaintenancePreview -Mode Move -Inspection (New-StorageTestInspection)).Text
    Assert-True ($move -like '*après la bascule, « Revenir à la base précédente »*aucune écriture*') 'déplacement'
    $active=[pscustomobject]@{Readable=$true;Problem='';Info=[pscustomobject]@{Revision=12;Counts=[pscustomobject]@{ad_objects=120;domenia_observations=40;user_machine_links=3}}}
    $restore=(Get-DomeniaStorageMaintenancePreview -Mode Restore -Inspection (New-StorageTestInspection -Active $active)).Text
    Assert-True ($restore -like '*Retour arrière : après la bascule*base restaurée*') 'restauration sur base lisible'
}
Test-Case 'P31' 'Lʼaperçu exige une destination testée et une source intègre' {
    Assert-Throws {Get-DomeniaStorageMaintenancePreview -Mode Move -Inspection (New-StorageTestInspection -Writable $false)} 'écriture non testée'
    $bad=New-StorageTestInspection;$bad.Source.Integrity='ko'
    Assert-Throws {Get-DomeniaStorageMaintenancePreview -Mode Move -Inspection $bad} 'intégrité non confirmée'
    $missing=New-StorageTestInspection;$missing.Source.Counts=[pscustomobject]@{ad_objects=1}
    Assert-True ((Get-DomeniaStorageMaintenancePreview -Mode Move -Inspection $missing).Text -like '*nombre inconnu*') 'compteur absent inconnu'
}
Test-Case 'P32' 'Les boutons de lʼassistant suivent lʼétat de la maintenance' {
    $s=Get-DomeniaStorageMaintenanceControlState
    Assert-True ($s.Move -and $s.Restore) 'au repos'
    Assert-False ($s.Resume -or $s.Rollback) 'rien à reprendre'
    $s=Get-DomeniaStorageMaintenanceControlState -DemoMode $true
    Assert-False ($s.Move -or $s.Restore -or $s.Resume -or $s.Rollback) 'démonstration'
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance ([pscustomobject]@{Id='x';Locked=$true;TargetPath='D:\b.db';Job='';Draining=$false})
    Assert-False ($s.Move -or $s.Restore) 'bascule en attente'
    Assert-True ($s.Resume -and $s.Rollback) 'reprise ou retour'
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance ([pscustomobject]@{Id='x';Locked=$false;Draining=$true})
    Assert-False ($s.Move -or $s.Restore -or $s.Resume -or $s.Rollback) 'vidage de la file'
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance ([pscustomobject]@{Id='x';Locked=$true;TargetPath='D:\b.db';Job='job-1'})
    Assert-False ($s.Move -or $s.Restore -or $s.Resume -or $s.Rollback) 'étape en cours'
}
Test-Case 'P31' 'Une bascule terminée reste annulable tant que rien ne tourne' {
    $done=[pscustomobject]@{Id='x';Locked=$false;Hold=$false;TargetPath='D:\b.db';Job='';Draining=$false}
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance $done -CanUndo $true
    Assert-True ($s.Rollback -and $s.Move -and $s.Restore) 'retour offert au repos'
    Assert-False $s.Resume 'rien à reprendre'
    Assert-True ($s.Text -like '*aucune écriture*') 'condition dite'
    Assert-False (Get-DomeniaStorageMaintenanceControlState -Maintenance $done).Rollback 'sans bascule annulable'
    $running=[pscustomobject]@{Id='x';Locked=$true;TargetPath='D:\b.db';Job='job-2';Draining=$false}
    Assert-False (Get-DomeniaStorageMaintenanceControlState -Maintenance $running -CanUndo $true).Rollback 'étape en cours'
    Assert-False (Get-DomeniaStorageMaintenanceControlState -Maintenance $done -CanUndo $true -DemoMode $true).Rollback 'démonstration'
}
Test-Case 'P34' 'Une base illisible au démarrage nʼaccepte quʼune restauration puis sa reprise' {
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance ([pscustomobject]@{Id='recovery-unreadable';Locked=$true;Recovery=$true;TargetPath='';Receipt=$null})
    Assert-True $s.Restore 'restauration'
    Assert-False ($s.Move -or $s.Resume -or $s.Rollback) 'rien dʼautre'
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance ([pscustomobject]@{Id='r';Locked=$true;Recovery=$true;TargetPath='D:\b.db';Receipt=[pscustomobject]@{RedirectWritten=$false}})
    Assert-True $s.Resume 'reprise de la bascule'
    Assert-False ($s.Restore -or $s.Rollback) 'pas de retour vers une base illisible'
    $s=Get-DomeniaStorageMaintenanceControlState -Maintenance ([pscustomobject]@{Id='recovery-pending';Locked=$true;TargetPath=''})
    Assert-False ($s.Move -or $s.Restore -or $s.Resume -or $s.Rollback) 'lecture de la bascule interrompue'
}
Test-Case 'P33' 'La sauvegarde automatique désactivée le dit' {
    $r=Get-DomeniaStorageBackupSchedule -NowUtc $script:StorageNow
    Assert-False $r.Enabled 'désactivée'
    Assert-Equal 'Disabled' $r.Reason 'raison'
    Assert-True ($r.Text -like '*désactivée*') 'texte'
}
Test-Case 'P33' 'Sans succès vérifié, la première sauvegarde est due' {
    $r=Get-DomeniaStorageBackupSchedule -Policy ([pscustomobject]@{AutomaticBackup=$true}) -NowUtc $script:StorageNow
    Assert-True $r.Due 'due'
    Assert-Equal 'Scheduled' $r.Reason 'planifiée'
    Assert-True ($r.Text -like '*Aucune sauvegarde vérifiée*') 'aucun succès'
    Assert-Equal 'Busy' (Get-DomeniaStorageBackupSchedule -Policy ([pscustomobject]@{AutomaticBackup=$true}) -Busy $true -NowUtc $script:StorageNow).Reason 'occupée'
}
Test-Case 'P33' 'Le dernier succès vérifié donne la prochaine échéance et sa preuve' {
    $last=$script:StorageNow.AddHours(-2).ToString('o');$sha=('0123456789ab'+('c'*52))
    $r=Get-DomeniaStorageBackupSchedule -Policy ([pscustomobject]@{AutomaticBackup=$true;BackupHours=24}) -LastSuccessUtc $last -LastDetail ([pscustomobject]@{Bytes=2048;Sha256=$sha}) -NowUtc $script:StorageNow
    Assert-Equal 'Recent' $r.Reason 'récente'
    Assert-Equal ($script:StorageNow.AddHours(22)) ([datetime]::Parse($r.NextUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) 'échéance'
    Assert-True ($r.Text -like '*2 Ko*') 'taille'
    Assert-True ($r.Text -like '*0123456789ab*') 'empreinte'
}
Test-Case 'P33' 'Juste après un succès, la prochaine échéance nʼest pas présentée comme un nouvel essai' {
    $attempt=$script:StorageNow.AddMinutes(-5);$success=$script:StorageNow.AddMinutes(-3)
    $r=Get-DomeniaStorageBackupSchedule -Policy ([pscustomobject]@{AutomaticBackup=$true;BackupHours=24}) -LastSuccessUtc $success.ToString('o') -LastAttemptUtc $attempt.ToString('o') -NowUtc $script:StorageNow
    Assert-Equal 'RetryCooldown' $r.Reason 'délai de la règle'
    Assert-False ($r.Text -like '*Nouvel essai*') 'pas un échec'
    Assert-Equal ($success.AddHours(24)) ([datetime]::Parse($r.NextUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) 'échéance de la fréquence'
    $failed=Get-DomeniaStorageBackupSchedule -Policy ([pscustomobject]@{AutomaticBackup=$true;BackupHours=24}) -LastSuccessUtc ($script:StorageNow.AddDays(-2).ToString('o')) -LastAttemptUtc $attempt.ToString('o') -NowUtc $script:StorageNow
    Assert-True ($failed.Text -like '*Nouvel essai au plus tôt*') 'essai échoué'
    Assert-Equal ($attempt.AddMinutes(15)) ([datetime]::Parse($failed.NextUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) 'quinze minutes'
}
Test-Case 'P33' 'Un échec de la session est affiché sans double point' {
    $r=Get-DomeniaStorageBackupSchedule -Policy ([pscustomobject]@{AutomaticBackup=$true}) -LastFailure ([pscustomobject]@{AtUtc=$script:StorageNow.ToString('o');Message='disque plein.'}) -NowUtc $script:StorageNow
    Assert-True ($r.Text -like '*Dernier échec*') 'échec'
    Assert-True ($r.Text -like '*disque plein.*') 'message'
    Assert-False ($r.Text -like '*disque plein..*') 'un seul point'
}
Test-Case 'P35' 'Sans mesure, lʼespace disque reste inconnu et ne bloque rien' {
    $s=Get-DomeniaStorageSpaceState -NowUtc $script:StorageNow
    Assert-Equal 'Unknown' $s.State 'inconnu'
    Assert-False $s.BlocksCollections 'aucun blocage'
    Assert-True ($s.Text -like '*non mesuré*') 'texte honnête'
}
Test-Case 'P35' 'Les seuils suspendent les collectes avant les écritures' {
    $at=$script:StorageNow.AddMinutes(-1).ToString('o')
    $critical=Get-DomeniaStorageSpaceState -FreeBytes 10485760 -MeasuredUtc $at -NowUtc $script:StorageNow
    Assert-True (($critical.State -eq 'Critical') -and $critical.BlocksCollections) 'critique'
    $suspend=Get-DomeniaStorageSpaceState -FreeBytes 104857600 -MeasuredUtc $at -NowUtc $script:StorageNow
    Assert-True (($suspend.State -eq 'Suspend') -and $suspend.BlocksCollections) 'suspension'
    $low=Get-DomeniaStorageSpaceState -FreeBytes 1073741824 -MeasuredUtc $at -NowUtc $script:StorageNow
    Assert-True (($low.State -eq 'Low') -and (-not $low.BlocksCollections)) 'à surveiller'
    Assert-Equal 'Ok' (Get-DomeniaStorageSpaceState -FreeBytes 10737418240 -MeasuredUtc $at -NowUtc $script:StorageNow).State 'confortable'
}
Test-Case 'P35' 'La file en attente relève les seuils et une mesure ancienne est signalée' {
    $at=$script:StorageNow.AddMinutes(-1).ToString('o')
    $s=Get-DomeniaStorageSpaceState -FreeBytes 838860800 -MeasuredUtc $at -QueuedBytes 104857600 -NowUtc $script:StorageNow
    Assert-Equal (536870912L+4L*104857600L) $s.SuspendBelowBytes 'seuil relevé'
    Assert-Equal 'Suspend' $s.State '800 Mo insuffisants avec 100 Mo en file'
    $old=Get-DomeniaStorageSpaceState -FreeBytes 10737418240 -MeasuredUtc ($script:StorageNow.AddHours(-2).ToString('o')) -NowUtc $script:StorageNow
    Assert-True ($old.Stale -and ($old.Text -like '*Mesure ancienne*')) 'mesure ancienne'
}
Test-Case 'P35' 'Ce qui reste en mémoire est dit précisément' {
    Assert-Equal 'Aucune donnée en attente dʼenregistrement.' (Format-DomeniaStorageUnsaved ([pscustomobject]@{Pending=0;QueuedChanges=0;QueuedBytes=0;Suspended=$false})) 'rien'
    $text=Format-DomeniaStorageUnsaved ([pscustomobject]@{Pending=3;QueuedChanges=10;QueuedBytes=2048;Suspended=$true})
    foreach($part in @('3 élément(s)','10 changement(s)','2 Ko','Fiabilité')){Assert-True ($text -like ('*'+$part+'*')) $part}
}
Test-Case 'P36' 'Le verdict dʼintégrité exige un rapport complet et cohérent' {
    Assert-Equal 'Sain' (Get-DomeniaStorageIntegrityVerdict (New-StorageTestReport)).Verdict 'sain'
    Assert-Equal 'À surveiller' (Get-DomeniaStorageIntegrityVerdict (New-StorageTestReport -Status @{Wal='Warning'})).Verdict 'alerte'
    $defect=Get-DomeniaStorageIntegrityVerdict (New-StorageTestReport -Status @{QuickCheck='Failed'})
    Assert-Equal 'Défaut' $defect.Verdict 'défaut'
    Assert-True ($defect.Text -like '*Restaurer une sauvegarde*') 'renvoi vers la restauration'
    $wrong=New-StorageTestReport;$wrong.Kind='StorageUsage';Assert-Throws {Get-DomeniaStorageIntegrityVerdict $wrong} 'type'
    $notBool=New-StorageTestReport;$notBool.ReadOnly='oui';Assert-Throws {Get-DomeniaStorageIntegrityVerdict $notBool} 'lecture seule non booléenne'
}
Test-Case 'P36' 'Un contrôle incomplet, doublé ou inconnu est refusé' {
    $dup=New-StorageTestReport;$dup.Checks=@($dup.Checks)+@([pscustomobject]@{Id='Wal';Status='Ok';Detail=''});Assert-Throws {Get-DomeniaStorageIntegrityVerdict $dup} 'doublon'
    $unknown=New-StorageTestReport;$unknown.Checks=@($unknown.Checks)+@([pscustomobject]@{Id='Other';Status='Ok';Detail=''});Assert-Throws {Get-DomeniaStorageIntegrityVerdict $unknown} 'inconnu'
    $missing=New-StorageTestReport;$missing.Checks=@($missing.Checks|Where-Object{$_.Id -ne 'Wal'});Assert-Throws {Get-DomeniaStorageIntegrityVerdict $missing} 'incomplet'
    $open=[pscustomobject]@{Kind='StorageIntegrity';ReadOnly=$true;Readable=$false;CheckedUtc=$script:StorageNow.ToString('o');DurationMs=1;Checks=@([pscustomobject]@{Id='Open';Status='Failed';Detail='base illisible'})}
    Assert-Equal 'Défaut' (Get-DomeniaStorageIntegrityVerdict $open).Verdict 'base illisible'
}
Test-Case 'P37' 'Une date limite par famille, vide pour une famille sans limite' {
    $c=Get-DomeniaStorageRetentionCutoffs -NowUtc $script:StorageNow
    Assert-Equal ($script:StorageNow.AddDays(-30).ToString('o')) $c.Presence 'présence 30 jours'
    Assert-Equal '' $c.LinkHistory 'historique conservé sans limite par défaut'
    Assert-Equal ($script:StorageNow.AddDays(-365).ToString('o')) (Get-DomeniaStorageRetentionCutoffs -Policy ([pscustomobject]@{LinkHistoryDays=365}) -NowUtc $script:StorageNow).LinkHistory 'historique 365 jours choisi'
}
Test-Case 'P37' 'La perte de détail est annoncée famille par famille avant toute suppression' {
    $cut=$script:StorageNow.AddDays(-30).ToString('o')
    $cutoffs=[pscustomobject]@{Presence=$cut;Console='';Inventory=$cut;Probe='';Detail='';LinkHistory=$cut}
    $counts=@([pscustomobject]@{Family='Presence';Rows=7;CutoffUtc=$cut},[pscustomobject]@{Family='Inventory';Rows=0;CutoffUtc=$cut},[pscustomobject]@{Family='LinkHistory';Rows=5;CutoffUtc=$cut})
    $preview=@(Get-DomeniaStorageRetentionLines -Counts $counts -Cutoffs $cutoffs -SkippedLegacyRows 2 -DryRun $true)
    Assert-Equal 1 @($preview|Where-Object{$_ -like 'Utilisateur connecté : conservé sans limite de durée.'}).Count 'famille sans limite'
    Assert-Equal 1 @($preview|Where-Object{$_ -like 'Inventaire : rien dʼantérieur*'}).Count 'rien à retirer'
    $history=@($preview|Where-Object{$_ -like 'Historique des associations*'})[0]
    Assert-True (($history -like '*observation(s) répétée(s)*') -and ($history -like '*à retirer*') -and ($history -like '*changement*')) 'résumé de lʼhistorique'
    Assert-Equal 1 @($preview|Where-Object{$_ -like '*non migrés*'}).Count 'anciens relevés conservés'
    $applied=@(Get-DomeniaStorageRetentionLines -Counts $counts -Cutoffs $cutoffs -DryRun $false)
    $presence=@($applied|Where-Object{$_ -like 'Présence ping*'})[0]
    Assert-True (($presence -like '*retirée(s)*') -and ($presence -like '*dernier état*')) 'perte du dernier état'
    Assert-Throws {Get-DomeniaStorageRetentionLines -Counts @($counts[0]) -Cutoffs $cutoffs} 'famille datée absente du comptage'
}
Test-Case 'P40' 'Les limites sont explicites et ne promettent pas un stockage infini' {
    $lines=@(Get-DomeniaStorageLimitLines)
    Assert-True (@($lines|Where-Object{$_ -like '*nʼest pas illimité*'}).Count -eq 1) 'pas dʼinfini'
    Assert-True (@($lines|Where-Object{$_ -like '*non mesurée*'}).Count -eq 1) 'taille non mesurée dite'
    Assert-True (@($lines|Where-Object{$_ -like '*4 096 changements*'}).Count -eq 1) 'file bornée'
    Assert-True (@($lines|Where-Object{$_ -like 'Conservation :*cache de recherche : 20 requêtes par périmètre*'}).Count -eq 1) 'cache de recherche sur disque, borné'
}
Test-Case 'P40' 'Les collections les plus volumineuses viennent de la dernière mesure' {
    $usage=[pscustomobject]@{MeasuredUtc=$script:StorageNow.ToString('o');DatabaseBytes=1048576;WalBytes=0;DbstatAvailable=$true;Categories=@([pscustomobject]@{Category='Observations';Bytes=3000;Rows=10},[pscustomobject]@{Category='Index';Bytes=5000;Rows=20},[pscustomobject]@{Category='History';Bytes=10;Rows=1},[pscustomobject]@{Category='Snapshots';Bytes=1;Rows=1})}
    $lines=@(Get-DomeniaStorageLimitLines -Policy ([pscustomobject]@{LinkHistoryDays=0}) -Engine ([pscustomobject]@{MaxConcurrent=6;MaxQueued=32}) -Usage $usage)
    $top=@($lines|Where-Object{$_ -like 'Collections les plus volumineuses*'})[0]
    Assert-True ($top.IndexOf('Index') -lt $top.IndexOf('Observations')) 'tri par taille'
    Assert-True (@($lines|Where-Object{$_ -like '*6 tâches simultanées*'}).Count -eq 1) 'moteur'
    Assert-True (@($lines|Where-Object{$_ -like '*Historique des associations sans limite*'}).Count -eq 1) 'conservation sans limite'
    Assert-True (@($lines|Where-Object{$_ -like 'Disque : base de 1 Mo*'}).Count -eq 1) 'taille mesurée'
}
Test-Case 'P39' 'Les lectures mesurées disent comment SQLite les a servies' {
    $probes=@([pscustomobject]@{Name='DirectoryPage';Rows=250;Ms=0.27;Plan='SEARCH ad_objects USING INDEX ix_ad_objects_type_name (object_type=?) | USE TEMP B-TREE FOR DISTINCT | USE TEMP B-TREE FOR LAST TERM OF ORDER BY'},[pscustomobject]@{Name='ActiveMachines';Rows=8571;Ms=12.5;Plan='SEARCH ad_objects USING INDEX ix_ad_objects_type (object_type=?) | USE TEMP B-TREE FOR ORDER BY'},[pscustomobject]@{Name='TextSearch';Rows=20000;Ms=35;Plan='SCAN ad_objects'},[pscustomobject]@{Name='Unknown';Rows=1;Ms=1;Plan=''})
    $text=Format-DomeniaStorageReadProbes -Probes $probes
    Assert-True ($text -like 'Lectures mesurées sur cette base : *') 'titre'
    Assert-True ($text -like '*page de lʼindex par type (250 ligne(s)) : 0,27 ms, index*') 'index'
    Assert-True ($text -like '*postes actifs triés (8571 ligne(s)) : 12,5 ms, tri complet en mémoire*') 'tri'
    Assert-True ($text -like '*recherche de texte (20000 ligne(s)) : 35 ms, parcours complet*') 'parcours'
    Assert-False ($text -like '*Unknown*') 'mesure inconnue ignorée'
    Assert-Equal '' (Format-DomeniaStorageReadProbes -Probes @()) 'aucune mesure, aucune ligne'
}
Test-Case 'P32' 'Le verrou de maintenance refuse les écrivains de la base, pas le journal des reçus' {
    foreach($id in @('LocalStore','LinkHistoryStore','LiveCache','IndexBuild','IndexRefresh','StoragePurge','StorageBackup')){Assert-True (Test-DomeniaStorageLockedWriter -OperationId $id) $id}
    foreach($id in @('ReceiptStore','DocumentStore','StorageMaintenance','StorageRetention','StorageIntegrity','StorageUsage','LocalIndexRead','WriteUserAttribute','')){Assert-False (Test-DomeniaStorageLockedWriter -OperationId $id) ('admis : '+$id)}
}
Test-Case 'P32' 'Une modification saisie pendant le verrou est refusée avec son motif' {
    Assert-Equal '' (Get-DomeniaStorageInputRefusal) 'aucune maintenance'
    Assert-Equal '' (Get-DomeniaStorageInputRefusal -Maintenance ([pscustomobject]@{Id='m';Locked=$false;Hold=$true;Recovery=$false})) 'attente de confirmation : la file sera enregistrée avant la copie'
    $copy=Get-DomeniaStorageInputRefusal -Maintenance ([pscustomobject]@{Id='m';Locked=$true;Recovery=$false;Receipt=$null})
    Assert-True (($copy -like 'Maintenance de la base locale en cours : modification non enregistrée*') -and ($copy -like '*Outils > Base autonome > Stockage*')) 'copie en cours'
    $unreadable=Get-DomeniaStorageInputRefusal -Maintenance ([pscustomobject]@{Id='recovery-unreadable';Locked=$true;Recovery=$true;Receipt=$null})
    Assert-True ($unreadable -like 'Base locale illisible : modification non enregistrée*') 'base illisible'
}
