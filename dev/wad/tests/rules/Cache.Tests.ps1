# D021-D030 : chargement, cache et performance. Donnees fictives uniquement.
$script:C0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
$script:GA='11111111-1111-1111-1111-111111111111';$script:GB='22222222-2222-2222-2222-222222222222'
Test-Case 'D021' 'La projection de liste ne demande ni appartenances ni droits' {
    $list=Get-DomeniaProjection List
    Assert-True (Test-DomeniaProjectionMinimal $list).Minimal
    Assert-False (Test-DomeniaProjectionMinimal ($list+@('memberOf'))).Minimal
    Assert-False (Test-DomeniaProjectionMinimal @('name','nTSecurityDescriptor')).Minimal
    Assert-True ((Get-DomeniaProjection Groups) -contains 'memberOf')
}
Test-Case 'D022' 'Une mise a jour de presence modifie une cellule sans reconstruire la liste' {
    $rows=@([pscustomobject]@{Guid=$script:GA;Name='PC-1';Presence='Inconnu'},[pscustomobject]@{Guid=$script:GB;Name='PC-2';Presence='Inconnu'})
    $plan=Get-DomeniaRowUpdatePlan $rows @([pscustomobject]@{Guid=$script:GA;Name='PC-1';Presence='En ligne'}) 'Guid'
    Assert-Equal 'Merge' $plan.Mode;Assert-Equal 1 $plan.Updates.Count;Assert-Equal 0 $plan.Inserts.Count
    Assert-True ([object]::ReferenceEquals($plan.Updates[0].Row,$rows[0])) 'La ligne existante est conservee'
    Assert-Equal 'En ligne' $plan.Updates[0].Changes['Presence'];Assert-False $plan.Updates[0].Changes.ContainsKey('Name')
}
Test-Case 'D022' 'Un lot ne reintroduit pas un doublon et ajoute les nouvelles identites' {
    $rows=@([pscustomobject]@{Guid=$script:GA;Name='A'})
    $plan=Get-DomeniaRowUpdatePlan $rows @([pscustomobject]@{Guid=$script:GB;Name='B'},[pscustomobject]@{Guid=$script:GB;Name='B bis'},[pscustomobject]@{Guid=$script:GA;Name='A'}) 'Guid'
    Assert-Equal 1 $plan.Inserts.Count;Assert-Equal 1 $plan.Unchanged
    Assert-Equal 'Replace' (Get-DomeniaRowUpdatePlan $rows @() 'Guid' @() $true).Mode
}
Test-Case 'D023' 'La memoire reste bornee par une politique explicite' {
    $b=New-DomeniaPageBuffer -PageSize 10 -MaxRowsInMemory 25
    $page={param($from,$n)@($from..($from+$n-1)|ForEach-Object{[pscustomobject]@{Guid=('g'+$_)}})}
    [void](Add-DomeniaPageRows $b (& $page 1 10));[void](Add-DomeniaPageRows $b (& $page 11 10))
    $r=Add-DomeniaPageRows $b (& $page 21 10) 'Guid' $true
    Assert-Equal 25 $r.Total;Assert-True $r.Limited;Assert-False $r.Complete 'Une liste limitee n est pas annoncee complete';Assert-Equal 5 $b.Dropped
}
Test-Case 'D023' 'Les pages ne reintroduisent pas de doublons' {
    $b=New-DomeniaPageBuffer -PageSize 10 -MaxRowsInMemory 100
    [void](Add-DomeniaPageRows $b @([pscustomobject]@{Guid='a'},[pscustomobject]@{Guid='b'}))
    $r=Add-DomeniaPageRows $b @([pscustomobject]@{Guid='B'},[pscustomobject]@{Guid='c'}) 'Guid' $true
    Assert-Equal 3 $r.Total;Assert-Equal 1 $r.Duplicates;Assert-True $r.Complete
}
Test-Case 'D024' 'Un ping reussi ne rajeunit ni l historique ni les attributs AD' {
    $rec=[pscustomobject]@{Guid=$script:GA}
    [void](Set-DomeniaObservationTime $rec 'Attributes' $script:C0.AddHours(-5))
    [void](Set-DomeniaObservationTime $rec 'Console' $script:C0.AddDays(-3))
    [void](Set-DomeniaObservationTime $rec 'Presence' $script:C0)
    Assert-Equal 'Fresh' (Get-DomeniaRecordFreshness $rec 'Presence' $script:C0.AddSeconds(30)).State
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $rec 'Attributes' $script:C0.AddSeconds(30)).State
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $rec 'Console' $script:C0.AddSeconds(30)).State
}
Test-Case 'D024' 'Une tentative echouee est datee sans rajeunir l observation' {
    $rec=[pscustomobject]@{Guid=$script:GA}
    [void](Set-DomeniaObservationTime $rec 'Presence' $script:C0.AddHours(-2))
    [void](Set-DomeniaObservationTime $rec 'Presence' $script:C0 $false)
    $f=Get-DomeniaRecordFreshness $rec 'Presence' $script:C0.AddSeconds(5)
    Assert-Equal 'Stale' $f.State;Assert-True ($f.Label -match 'derniere tentative')
    Assert-Equal 'Unknown' (Get-DomeniaRecordFreshness $rec 'Console' $script:C0).State
}
Test-Case 'D024' 'L historique n est jamais presente comme frais' {
    Assert-Equal 'Historical' (Get-DomeniaFreshness 'History' $script:C0 $null $script:C0.AddSeconds(1)).State
}
Test-Case 'D024' 'Les cinq natures survivent au JSON et se copient sans partager les dates' {
    $source=[pscustomobject]@{Guid=$script:GA}
    foreach($nature in Get-DomeniaDataNatures){[void](Set-DomeniaObservationTime $source $nature $script:C0)}
    $source=$source | ConvertTo-Json -Depth 3 | ConvertFrom-Json
    $copy=[pscustomobject]@{Guid=$script:GA};[void](Copy-DomeniaObservationTimes $source $copy)
    foreach($nature in Get-DomeniaDataNatures){Assert-Equal $script:C0.ToString('o') (Get-DomeniaRecordFreshness $copy $nature $script:C0).ObservedUtc.ToString('o')}
    [void](Set-DomeniaObservationTime $copy 'Presence' $script:C0.AddHours(1) $false)
    # PowerShell 7 may decode ISO JSON strings as DateTime; compare the represented instant.
    Assert-Equal $script:C0.ToString('o') (ConvertTo-DomeniaUtcDate $source.Times.Presence.LastAttemptUtc).ToString('o')
    Assert-Equal $script:C0.AddHours(1).ToString('o') $copy.Times.Presence.LastAttemptUtc
    [void](Set-DomeniaObservationTime $source 'Console' $script:C0.AddHours(1))
    Assert-Equal $script:C0.ToString('o') $copy.Times.Console.ObservedUtc
    $different=[pscustomobject]@{Guid=$script:GB};[void](Copy-DomeniaObservationTimes $source $different)
    Assert-Equal 0 $different.Times.Count
}
Test-Case 'D024' 'Une ancienne observation fournit ses dates reelles et jamais la date du rechargement' {
    $old=[pscustomobject]@{LastUser='alice';ObservedUtc=$script:C0.AddDays(-3).ToString('o');UserCheckedUtc=$script:C0.AddHours(-1).ToString('o');Presence='En ligne';PresenceCheckedUtc=$script:C0.AddHours(-2).ToString('o')}
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $old 'Console' $script:C0).State
    Assert-Equal $old.ObservedUtc (Get-DomeniaRecordFreshness $old 'Console' $script:C0).ObservedUtc.ToString('o')
    Assert-Equal $old.PresenceCheckedUtc (Get-DomeniaRecordFreshness $old 'Presence' $script:C0).ObservedUtc.ToString('o')
    Assert-Equal 'Unknown' (Get-DomeniaRecordFreshness $old 'Attributes' $script:C0).State
    $old.Presence='Erreur de ping';$old.ObservedUtc='invalide'
    Assert-Equal 'Unknown' (Get-DomeniaRecordFreshness $old 'Presence' $script:C0).State
    Assert-Equal 'Unknown' (Get-DomeniaRecordFreshness $old 'Console' $script:C0).State
}
Test-Case 'D024' 'Un paquet arrive en retard ne recule pas les dates de la meme nature' {
    $record=[pscustomobject]@{Guid=$script:GA}
    [void](Set-DomeniaObservationTime $record 'Presence' $script:C0)
    [void](Set-DomeniaObservationTime $record 'Presence' $script:C0.AddSeconds(-20))
    [void](Set-DomeniaObservationTime $record 'Presence' $script:C0.AddSeconds(-10) $false)
    Assert-Equal $script:C0.ToString('o') $record.Times.Presence.ObservedUtc
    Assert-Equal $script:C0.ToString('o') $record.Times.Presence.LastAttemptUtc
}
Test-Case 'D025' 'La cle distingue lecteur, controleur, instance et objet' {
    $k=Get-DomeniaCacheKey 'example.invalid' $script:GA '' 'reader1' 'dc1' 'inv1'
    Assert-True ($k -cne (Get-DomeniaCacheKey 'example.invalid' $script:GA '' 'reader2' 'dc1' 'inv1'))
    Assert-True ($k -cne (Get-DomeniaCacheKey 'example.invalid' $script:GA '' 'reader1' 'dc2' 'inv1'))
    Assert-True ($k -cne (Get-DomeniaCacheKey 'example.invalid' $script:GA '' 'reader1' 'dc1' 'inv2'))
    Assert-True ($k -cne (Get-DomeniaCacheKey 'example.invalid' $script:GB '' 'reader1' 'dc1' 'inv1'))
    Assert-False ($k -match 'reader1') 'Le nom du lecteur n apparait pas en clair'
    Assert-Equal '' (Get-DomeniaCacheKey 'example.invalid' '' '' 'reader1')
}
Test-Case 'D025' 'Meme DN reutilise avec un autre GUID : cache refuse' {
    $e=[pscustomobject]@{Guid=$script:GA;Domain='d';Reader='r';InvocationId='i1';Usn='10'}
    Assert-False (Test-DomeniaCacheEntryValid $e ([pscustomobject]@{Guid=$script:GB;Domain='d';Reader='r';InvocationId='i1';Usn='10'})).Valid
}
Test-Case 'D025' 'Meme USN sur deux controleurs : cache refuse' {
    $e=[pscustomobject]@{Guid=$script:GA;Domain='d';Reader='r';InvocationId='i1';Usn='10'}
    Assert-False (Test-DomeniaCacheEntryValid $e ([pscustomobject]@{Guid=$script:GA;Domain='d';Reader='r';InvocationId='i2';Usn='10'})).Valid
    Assert-False (Test-DomeniaCacheEntryValid $e ([pscustomobject]@{Guid=$script:GA;Domain='d';Reader='r';InvocationId='';Usn='10'})).Valid
    Assert-True (Test-DomeniaCacheEntryValid $e ([pscustomobject]@{Guid=$script:GA;Domain='d';Reader='r';InvocationId='i1';Usn='10'})).Valid
}
Test-Case 'D025' 'Changement de compte : cache refuse' {
    $e=[pscustomobject]@{Guid=$script:GA;Domain='d';Reader='r';InvocationId='i1';Usn=''}
    Assert-False (Test-DomeniaCacheEntryValid $e ([pscustomobject]@{Guid=$script:GA;Domain='d';Reader='autre';InvocationId='i1';Usn=''})).Valid
}
Test-Case 'D026' 'Changement de controleur : aucune suppression affirmee, relecture complete' {
    $cp=[pscustomobject]@{Dc='dc1';InvocationId='i1';Usn='100';ScopeDn='OU=X'}
    $r=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc2';InvocationId='i2';HighestUsn='5';ScopeDn='OU=X';ScopeComplete=$true;Rows=@();KnownGuids=@($script:GA)})
    Assert-Equal 'FullRescan' $r.Mode;Assert-Equal 0 @($r.DeletionsAsserted).Count;Assert-Equal 0 @($r.NotSeen).Count
}
Test-Case 'D026' 'Reponse partielle ou visibilite reduite : aucune absence deduite, repere inchange' {
    $cp=[pscustomobject]@{Dc='dc1';InvocationId='i1';Usn='100';ScopeDn='OU=X'}
    $r=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc1';InvocationId='i1';HighestUsn='150';ScopeDn='OU=X';ScopeComplete=$true;Partial=$true;Rows=@();KnownGuids=@($script:GA)})
    Assert-Equal 0 @($r.NotSeen).Count;Assert-Equal '100' $r.CheckpointNext.Usn
    $r2=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc1';InvocationId='i1';HighestUsn='150';ScopeDn='OU=X';ScopeComplete=$true;VisibilityReduced=$true;Rows=@();KnownGuids=@($script:GA)})
    Assert-Equal 0 @($r2.NotSeen).Count
}
Test-Case 'D026' 'Perimetre complet sur la meme instance : objets non revus signales, jamais supprimes' {
    $cp=[pscustomobject]@{Dc='dc1';InvocationId='i1';Usn='100';ScopeDn='OU=X'}
    $r=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc1';InvocationId='i1';HighestUsn='150';ScopeDn='OU=X';ScopeComplete=$true;Rows=@([pscustomobject]@{Guid=$script:GB;DN='CN=B,OU=Y'});KnownGuids=@($script:GA,$script:GB);KnownDnByGuid=@{$script:GB='CN=B,OU=X'}})
    Assert-Equal 1 @($r.NotSeen).Count;Assert-Equal 0 @($r.DeletionsAsserted).Count;Assert-Equal 1 @($r.Moves).Count;Assert-Equal '150' $r.CheckpointNext.Usn;Assert-True $r.SaveTogether
}
Test-Case 'D027' 'Un poste arrete n est pas sollicite en boucle par les rafraichissements' {
    $c=New-DomeniaNegativeCache
    [void](Register-DomeniaFailure $c 'pc1' 'Cim' 'Unreachable' $script:C0)
    Assert-True (Test-DomeniaNegativeCache $c 'pc1' 'Cim' $script:C0.AddSeconds(30)).Suppressed
    Assert-False (Test-DomeniaNegativeCache $c 'pc2' 'Cim' $script:C0.AddSeconds(30)).Suppressed
    Assert-False (Test-DomeniaNegativeCache $c 'pc1' 'Cim' $script:C0.AddSeconds(30) $true).Suppressed 'La nouvelle tentative volontaire passe'
    Assert-False (Test-DomeniaNegativeCache $c 'pc1' 'Cim' $script:C0.AddMinutes(10)).Suppressed 'La temporisation expire'
}
Test-Case 'D027' 'Identifiants rejetes : meme une tentative volontaire attend un changement de compte' {
    $c=New-DomeniaNegativeCache
    [void](Register-DomeniaFailure $c 'pc1' 'Cim' 'CredentialRejected' $script:C0)
    Assert-True (Test-DomeniaNegativeCache $c 'pc1' 'Cim' $script:C0.AddMinutes(5) $true).Suppressed
    Clear-DomeniaFailure $c 'pc1' 'Cim';Assert-False (Test-DomeniaNegativeCache $c 'pc1' 'Cim' $script:C0.AddMinutes(5)).Suppressed
}
Test-Case 'D028' 'Deux mises a jour independantes ne s ecrasent pas' {
    Assert-True (Resolve-DomeniaWriteConflict 'v1' 'v1').Apply
    $c=Resolve-DomeniaWriteConflict 'v2' 'v1';Assert-False $c.Apply;Assert-True $c.Conflict
    Assert-False (Resolve-DomeniaWriteConflict 'v2' '').Apply;Assert-True (Resolve-DomeniaWriteConflict '' '' $false).Apply
}
Test-Case 'D028' 'File bornee, regroupement par cle et etat En memoire / Enregistre' {
    $q=New-DomeniaWriteQueue -Capacity 8
    Assert-False (Add-DomeniaWriteRequest $q 'links' 'k1' 'v1' 'a').Coalesced
    Assert-True (Add-DomeniaWriteRequest $q 'links' 'K1' 'v1' 'b').Coalesced
    foreach($i in 2..8){[void](Add-DomeniaWriteRequest $q 'links' ('k'+$i) 'v1' $i)}
    Assert-False (Add-DomeniaWriteRequest $q 'links' 'k9' 'v1' 9).Accepted 'Aucune sauvegarde pretendue reussie au-dela de la capacite'
    $batch=Get-DomeniaWriteBatch $q 3;Assert-Equal 3 $batch.Count;Assert-Equal 'b' $batch[0].Payload
    Assert-True ((Get-DomeniaPersistenceLabel 5) -match 'En memoire');Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceLabel 0)
    Assert-True ((Get-DomeniaPersistenceLabel 0 0 $true) -match 'suspendu')
}
Test-Case 'D028' 'Libelle d enregistrement : indisponible > suspendu > conflits > echecs > attente > enregistre' {
    $unavailable=Get-DomeniaPersistenceLabel -Pending 4 -Failed 2 -Suspended $true -Unavailable $true -Conflicts 1
    Assert-Equal 'En memoire uniquement : stockage local indisponible, rien n est enregistre.' $unavailable
    Assert-False ($unavailable -match 'Fiabilite') 'Un stockage indisponible ne renvoie pas vers la reprise des sauvegardes'
    Assert-Equal 'En memoire uniquement : enregistrement suspendu apres des echecs. Reprise dans Fiabilite.' (Get-DomeniaPersistenceLabel -Pending 4 -Failed 2 -Suspended $true -Conflicts 1)
    Assert-Equal 'En memoire : 3 association(s) modifiee(s) ailleurs, non enregistree(s). Rechargez les associations : Comptes > Changer de compte, ou redemarrage.' (Get-DomeniaPersistenceLabel -Pending 4 -Failed 2 -Conflicts 3)
    Assert-Equal 'En memoire : 2 enregistrement(s) en echec, nouvel essai prevu.' (Get-DomeniaPersistenceLabel -Pending 4 -Failed 2)
    Assert-Equal 'En memoire : 4 modification(s) a enregistrer.' (Get-DomeniaPersistenceLabel -Pending 4)
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceLabel)
    # The historical positional calls keep their outputs.
    Assert-Equal 'En memoire : 5 modification(s) a enregistrer.' (Get-DomeniaPersistenceLabel 5)
    Assert-Equal 'En memoire : 1 enregistrement(s) en echec, nouvel essai prevu.' (Get-DomeniaPersistenceLabel 5 1)
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceLabel 0 0 $false $false 0)
    foreach($label in @($unavailable,(Get-DomeniaPersistenceLabel 0 0 $true),(Get-DomeniaPersistenceLabel 0 0 $false $false 7),(Get-DomeniaPersistenceLabel 0 3),(Get-DomeniaPersistenceLabel 9))){
        Assert-True ($label -cmatch '^[\x20-\x7E]+$') ('Libelle non ASCII : '+$label)
        Assert-True ($label.StartsWith('En memoire')) ('Un etat non enregistre doit le dire : '+$label)
    }
}
Test-Case 'D029' 'La purge ne touche jamais configuration, associations declarees ni recus' {
    $plan=Get-DomeniaPurgePlan @([pscustomobject]@{Category='Observations';Bytes=2048;Rows=10}) @('Observations','Configuration','ManualLinks','Receipts','Inconnue') $script:C0
    Assert-Equal 1 $plan.Actions.Count;Assert-Equal 'Observations' $plan.Actions[0].Category;Assert-Equal 4 $plan.Refused.Count
    Assert-True $plan.KeepsUnresolvedReceipts
    Assert-Equal '2 Ko' (Format-DomeniaSize 2048);Assert-Equal '1,5 Mo' (Format-DomeniaSize 1572864)
}
Test-Case 'D030' 'Hors ligne : consultation possible, aucune commande de modification' {
    $r=Get-DomeniaCacheReadPolicy $true $true $true $true $false
    Assert-True $r.CanView;Assert-True $r.CanCopy;Assert-False $r.CanEdit;Assert-False $r.CanRetry;Assert-Equal 'Consultation historique hors ligne' $r.Reason
}
Test-Case 'D030' 'Cache non relu : visible et historique, non modifiable ; identite differente : invisible' {
    $r=Get-DomeniaCacheReadPolicy $true $true $false $false $false
    Assert-True ($r.CanView -and $r.Historical -and -not $r.CanEdit)
    Assert-False (Get-DomeniaCacheReadPolicy $true $false $true $false $false).CanView
    Assert-False (Get-DomeniaCacheReadPolicy $true $true $true $false $true).CanEdit
}
Test-Case 'D030' 'Le catalogue du cache donne source, date, lecteur et usage' {
    $rows=@(Get-DomeniaCacheCatalogRows @([pscustomobject]@{Scope='OU=X';Source='LDAP';Dc='dc1';Reader='r';Rows=12;ObservedUtc=$script:C0.AddHours(-3)}) $script:C0)
    Assert-Equal 1 $rows.Count;Assert-Equal '3 h' $rows[0].Age;Assert-True ($rows[0].Usage -match 'historique')
}

Test-Case 'D030' 'Seul Directory declare une panne et le retour garde le repere de coupure' {
    $s=Resolve-DomeniaDirectoryReachability $null 'Cim' 'Timeout' $false $script:C0
    Assert-False $s.Offline;Assert-False $s.Slow;Assert-False $s.Changed
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Network' $false $script:C0
    Assert-True $s.Offline;Assert-False $s.Slow;Assert-True $s.Changed
    $back=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Success' $false $script:C0.AddSeconds(10)
    Assert-False $back.Offline;Assert-False $back.Slow;Assert-True $back.Changed
    Assert-Equal $script:C0.ToString('o') $back.LastOutageUtc
}
Test-Case 'D030' 'Annulation et refus de droits ne sont pas une nouvelle panne reseau' {
    $s=Resolve-DomeniaDirectoryReachability $null 'Directory' 'Timeout' $true $script:C0
    Assert-False $s.Offline;Assert-False $s.Slow
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'AccessDenied' $false $script:C0
    Assert-False $s.Offline;Assert-False $s.Slow
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Network' $false $script:C0
    Assert-True $s.Offline
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'CredentialsRejected' $false $script:C0.AddSeconds(1)
    Assert-True $s.Offline;Assert-False $s.Changed
}
Test-Case 'D030' 'Une nouvelle panne reseau avance le repere exigeant une relecture' {
    $s=Resolve-DomeniaDirectoryReachability $null 'Directory' 'Network' $false $script:C0
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Network' $false $script:C0.AddSeconds(10)
    Assert-True $s.Changed;Assert-Equal $script:C0.AddSeconds(10).ToString('o') $s.LastOutageUtc
}
Test-Case 'D030' 'Un delai AD ne declare pas une panne et conserve les dates de lecture et de coupure' {
    $s=Resolve-DomeniaDirectoryReachability $null 'Directory' 'Success' $false $script:C0
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Timeout' $false $script:C0.AddSeconds(45)
    Assert-False $s.Offline;Assert-True $s.Slow;Assert-True $s.Changed
    Assert-Equal $null $s.LastOutageUtc
    Assert-Equal $script:C0.ToString('o') $s.LastSuccessUtc
    Assert-Equal $script:C0.AddSeconds(45).ToString('o') $s.LastTimeoutUtc
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Success' $false $script:C0.AddSeconds(60)
    Assert-False $s.Offline;Assert-False $s.Slow;Assert-True $s.Changed
    Assert-Equal $script:C0.AddSeconds(45).ToString('o') $s.LastTimeoutUtc
    Assert-Equal $script:C0.AddSeconds(60).ToString('o') $s.LastSuccessUtc
}
Test-Case 'D030' 'Un delai apres une panne conserve la protection et ne deplace pas le repere de coupure' {
    $s=Resolve-DomeniaDirectoryReachability $null 'Directory' 'Network' $false $script:C0
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Timeout' $false $script:C0.AddSeconds(45)
    Assert-True $s.Offline;Assert-True $s.Slow
    Assert-Equal $script:C0.ToString('o') $s.LastOutageUtc
    Assert-Equal $script:C0.AddSeconds(45).ToString('o') $s.LastTimeoutUtc
    $s=Resolve-DomeniaDirectoryReachability $s 'Directory' 'Network' $false $script:C0.AddSeconds(60)
    Assert-True $s.Offline;Assert-False $s.Slow
    Assert-Equal $script:C0.AddSeconds(60).ToString('o') $s.LastOutageUtc
}

Test-Case 'D029' 'Categories canoniques dedupliquees sans tenir compte de la casse' {
    $plan=Get-DomeniaPurgePlan -Selection @('observations','Observations',' OBSERVATIONS ','snapSHOTS') -NowUtc $script:C0
    Assert-Equal 2 $plan.Actions.Count
    Assert-Equal 'Observations' $plan.Actions[0].Category;Assert-Equal 'Snapshots' $plan.Actions[1].Category
    Assert-Equal 0 $plan.Refused.Count
}
Test-Case 'D029' 'Reconstructible vide a la demande, historique borne avec date ISO' {
    $plan=Get-DomeniaPurgePlan -Selection @('Observations','Snapshots','Index','History') -NowUtc $script:C0 -HistoryAgeDays 30
    foreach($action in @($plan.Actions | Where-Object {$_.Category -ne 'History'})){
        Assert-Equal 'All' $action.Mode;Assert-Equal $null $action.OlderThanUtc
    }
    $history=@($plan.Actions | Where-Object {$_.Category -eq 'History'})[0]
    Assert-Equal 'Bounded' $history.Mode
    Assert-Equal ($script:C0.ToUniversalTime().AddDays(-30).ToString('o')) $history.OlderThanUtc
    Assert-True ($history.OlderThanUtc -is [string])
    Assert-Throws {Get-DomeniaPurgePlan -Selection History -HistoryAgeDays 0}
    Assert-Throws {Get-DomeniaPurgePlan -Selection History -HistoryAgeDays 36501}
    foreach($p in @(Get-DomeniaRetentionPolicy)){
        Assert-False ($null -ne $p.PSObject.Properties['MaxRows']) 'Aucun quota automatique invente'
        Assert-False ($null -ne $p.PSObject.Properties['MaxAgeDays']) 'Age manuel separe de la politique automatique'
    }
}
Test-Case 'D029' 'Liste de tables fermee et historique des associations declarees protege' {
    $targets=@(foreach($category in @('Observations','Snapshots','History','Index')){Get-DomeniaPurgeTargets $category})
    # Lot L01: ad_computer_facts (Index) and fleet_snapshots (History) join the closed list; secret_state never does.
    # Points 22, 24 and 30: census gaps, absences and directory snapshots (rows and manifests) join the Index category.
    Assert-Equal 17 $targets.Count
    foreach($table in @('ad_absences','ad_census_gaps','ad_snapshot_rows','ad_snapshots')){Assert-Equal 'Index' (@(foreach($category in @('Observations','Snapshots','History','Index')){foreach($t in @(Get-DomeniaPurgeTargets $category)){if($t.Table -eq $table){$category}}})[0]) $table}
    Assert-Equal 'Index' (@(foreach($category in @('Index')){foreach($t in @(Get-DomeniaPurgeTargets $category)){if($t.Table -eq 'ad_computer_facts'){$category}}})[0])
    Assert-Equal 'snapshot_day' (@(Get-DomeniaPurgeTargets History | Where-Object {$_.Table -eq 'fleet_snapshots'})[0].TimeColumn)
    foreach($target in $targets){
        Assert-False ($target.Table -in @('user_machine_links','schema_info','secret_state','receipts','configuration','preferences'))
        Assert-False ($target.Table -match '[\\/.]') 'Aucun fichier'
    }
    $history=@($targets | Where-Object {$_.Table -eq 'user_machine_history'})[0]
    Assert-Equal 'PreserveDeclaredAssociations' $history.Filter
    Assert-Equal 'observed_at' $history.TimeColumn
    $plan=Get-DomeniaPurgePlan -Selection @('Observations','Snapshots','History','Index')
    Assert-True $plan.KeepsManualLinks;Assert-True $plan.KeepsConfiguration;Assert-True $plan.KeepsUnresolvedReceipts
}
Test-Case 'D029' 'Index reinitialise seulement le suivi annuaire, marqueur import conserve' {
    $sync=@(Get-DomeniaPurgeTargets Index | Where-Object {$_.Table -eq 'sync_state'})[0]
    Assert-Equal 'Reset' $sync.Action;Assert-Equal 'DirectoryScope' $sync.Filter
    Assert-Equal '' $sync.TimeColumn
}
Test-Case 'D029' 'Journal audit, configuration, associations et recus ne sont jamais purgeables' {
    foreach($name in @('Logs','Configuration','ManualLinks','Receipts','user_machine_links','schema_info','secret_state','inconnu')){
        Assert-Throws {Get-DomeniaPurgeTargets $name} $name
        $plan=Get-DomeniaPurgePlan -Selection @($name)
        Assert-Equal 0 $plan.Actions.Count;Assert-Equal 1 $plan.Refused.Count
    }
}
Test-Case 'D029' 'Taille absente inconnue, mesure conservee sans estimation' {
    $plan=Get-DomeniaPurgePlan -Usage @([pscustomobject]@{Category='Observations';Bytes=4096L;Rows=12L}) -Selection @('Observations','Snapshots')
    Assert-Equal 4096L $plan.Actions[0].CurrentBytes;Assert-Equal 12L $plan.Actions[0].CurrentRows
    Assert-Equal (-1L) $plan.Actions[1].CurrentBytes;Assert-Equal 'inconnu' (Format-DomeniaSize $plan.Actions[1].CurrentBytes)
}
