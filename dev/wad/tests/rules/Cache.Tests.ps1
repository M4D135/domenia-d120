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
    # UX-19 (X04): the suspended state names the button that resumes the saves and its place, not the hidden tab.
    $suspended=Get-DomeniaPersistenceLabel -Pending 4 -Failed 2 -Suspended $true -Conflicts 1
    Assert-Equal 'En mémoire uniquement : enregistrement suspendu après des échecs. Reprise : « Reprendre les sauvegardes », Base autonome, onglet Stockage.' $suspended
    Assert-True (($suspended -match 'suspendu') -and ($suspended -match 'Reprendre les sauvegardes') -and ($suspended -notmatch 'Fiabilit')) ('Libelle suspendu : '+$suspended)
    Assert-Equal 'En memoire : 3 association(s) modifiee(s) ailleurs, non enregistree(s). Rechargez les associations : Comptes > Changer de compte, ou redemarrage.' (Get-DomeniaPersistenceLabel -Pending 4 -Failed 2 -Conflicts 3)
    Assert-Equal 'En memoire : 2 enregistrement(s) en echec, nouvel essai prevu.' (Get-DomeniaPersistenceLabel -Pending 4 -Failed 2)
    Assert-Equal 'En memoire : 4 modification(s) a enregistrer.' (Get-DomeniaPersistenceLabel -Pending 4)
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceLabel)
    # The historical positional calls keep their outputs.
    Assert-Equal 'En memoire : 5 modification(s) a enregistrer.' (Get-DomeniaPersistenceLabel 5)
    Assert-Equal 'En memoire : 1 enregistrement(s) en echec, nouvel essai prevu.' (Get-DomeniaPersistenceLabel 5 1)
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceLabel 0 0 $false $false 0)
    # One printable line each. The suspended label (UX-19) is written with its accents; the others keep their text.
    foreach($label in @($unavailable,(Get-DomeniaPersistenceLabel 0 0 $true),(Get-DomeniaPersistenceLabel 0 0 $false $false 7),(Get-DomeniaPersistenceLabel 0 3),(Get-DomeniaPersistenceLabel 9))){
        Assert-False ($label -match '[\x00-\x1F\x7F]') ('Libelle sur plusieurs lignes ou avec un caractere de controle : '+$label)
        Assert-True ($label -cmatch '^En m(e|\u00e9)moire') ('Un etat non enregistre doit le dire : '+$label)
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
    # Point 4: the scope clocks (domenia_domain_metadata) go with the measures (Presence, Inventory) and the index (Directory).
    Assert-Equal 15 $targets.Count
    $clocks=@($targets | Where-Object {$_.Table -eq 'domenia_domain_metadata'})
    Assert-Equal 'WorkstationRuns|DirectoryRuns' (@($clocks | ForEach-Object {$_.Filter}) -join '|')
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

# ---------------------------------------------------------------- point 21 : repère de synchronisation par contrôleur et instance
Test-Case 'P21' 'Repère réutilisé seulement sur son contrôleur et son instance, avec les données quʼil décrit' {
    $now=[datetime]::SpecifyKind([datetime]'2026-10-14T10:00:00',[DateTimeKind]::Utc)
    $cp=[pscustomobject]@{Server='dc1.example.test';BaseDn='DC=example,DC=test';Date='2026-10-14T09:00:00Z';Count=5000;Usn=12345L;InvocationId='11111111-2222-3333-4444-555555555555'}
    Assert-True (Test-DomeniaSyncCheckpoint $cp 'DC1.example.test' 'dc=example,dc=test' 5100 0 $now).Usable
    Assert-True (Test-DomeniaSyncCheckpoint $cp 'dc1.example.test' 'DC=example,DC=test' 5000 20000 $now).Usable 'USN de lʼinstance supérieur au repère'
    $other=Test-DomeniaSyncCheckpoint $cp 'dc2.example.test' 'DC=example,DC=test' 5000 0 $now
    Assert-Equal 'OtherController' $other.Code;Assert-True ($other.Reason -match 'aucun USN reporté')
    Assert-Equal 'UsnAhead' (Test-DomeniaSyncCheckpoint $cp 'dc1.example.test' 'DC=example,DC=test' 5000 1000 $now).Code
    Assert-Equal 'EmptyBase' (Test-DomeniaSyncCheckpoint $cp 'dc1.example.test' 'DC=example,DC=test' 0 0 $now).Code
    Assert-Equal 'BaseShrunk' (Test-DomeniaSyncCheckpoint $cp 'dc1.example.test' 'DC=example,DC=test' 1000 0 $now).Code
    Assert-Equal 'OtherScope' (Test-DomeniaSyncCheckpoint $cp 'dc1.example.test' 'DC=autre,DC=test' 5000 0 $now).Code
    Assert-Equal 'Missing' (Test-DomeniaSyncCheckpoint $null 'dc1.example.test' 'DC=example,DC=test' 5000 0 $now).Code
    $noInstance=$cp.PSObject.Copy();$noInstance.InvocationId=''
    Assert-Equal 'NoInstance' (Test-DomeniaSyncCheckpoint $noInstance 'dc1.example.test' 'DC=example,DC=test' 5000 0 $now).Code
    $noUsn=$cp.PSObject.Copy();$noUsn.Usn=0L
    Assert-Equal 'NoUsn' (Test-DomeniaSyncCheckpoint $noUsn 'dc1.example.test' 'DC=example,DC=test' 5000 0 $now).Code
    $future=$cp.PSObject.Copy();$future.Date='2026-10-20T09:00:00Z'
    Assert-Equal 'FutureDate' (Test-DomeniaSyncCheckpoint $future 'dc1.example.test' 'DC=example,DC=test' 5000 0 $now).Code
}
Test-Case 'P21' 'Synchronisation : un repère dʼun autre contrôleur ou sans instance nʼavance jamais sur des données partielles' {
    $cp=[pscustomobject]@{Dc='dc1';InvocationId='11111111-2222-3333-4444-555555555555';Usn='100';ScopeDn='DC=example,DC=test'}
    $r=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc2';InvocationId='99999999-2222-3333-4444-555555555555';HighestUsn='5000';ScopeDn='DC=example,DC=test';ScopeComplete=$true;Rows=@();KnownGuids=@()})
    Assert-Equal 'FullRescan' $r.Mode;Assert-Equal '99999999-2222-3333-4444-555555555555' $r.CheckpointNext.InvocationId
    $partial=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc1';InvocationId='11111111-2222-3333-4444-555555555555';HighestUsn='150';ScopeDn='DC=example,DC=test';Partial=$true;Rows=@();KnownGuids=@()})
    Assert-False $partial.CheckpointAdvanced;Assert-Equal '100' $partial.CheckpointNext.Usn
    $unknown=Resolve-DomeniaIncrementalSync $cp ([pscustomobject]@{Dc='dc1';InvocationId='';HighestUsn='150';ScopeDn='DC=example,DC=test';Rows=@();KnownGuids=@()})
    Assert-False $unknown.CheckpointAdvanced 'Instance inconnue : pas de repère'
}

# ---------------------------------------------------------------- Lot X06 : base locale (FI-12, FI-13, UI-19, DS-09)
$script:X06Now=[datetime]::SpecifyKind([datetime]'2026-10-14T12:00:00',[DateTimeKind]::Utc)
Test-Case 'FI-12' 'Le delai SQLite configure est borne et garde le defaut documente' {
    Assert-Equal 2500 (Get-DomeniaSqliteBusyTimeoutMs $null)
    Assert-Equal 2500 (Get-DomeniaSqliteBusyTimeoutMs 'illisible')
    Assert-Equal 2500 (Get-DomeniaSqliteBusyTimeoutMs '')
    Assert-Equal 1200 (Get-DomeniaSqliteBusyTimeoutMs '1200')
    Assert-Equal 1200 (Get-DomeniaSqliteBusyTimeoutMs ' 1200 ')
    Assert-Equal 100 (Get-DomeniaSqliteBusyTimeoutMs 10)
    Assert-Equal 5000 (Get-DomeniaSqliteBusyTimeoutMs 99999)
}
Test-Case 'FI-12' 'Seules les attentes de verrou SQLite depassees sont reconnues' {
    foreach($text in @('SQLite code 5 : database is locked','SQLite step code 6 : database table is locked','SQLite prepare code 5 : database is locked','SQLITE_BUSY','Erreur : database is locked')){Assert-True (Test-DomeniaSqliteBusyText $text) $text}
    foreach($text in @('SQLite code 50 : x','SQLite code 13 : database or disk is full','StorageBusy : autre ecriture ou maintenance locale en cours.','Sauvegarde SQLite : code 5.','',$null)){Assert-False (Test-DomeniaSqliteBusyText $text) ([string]$text)}
}
Test-Case 'FI-12' 'Le resume des attentes dit le nombre, la derniere heure et le delai' {
    Assert-Equal 'Base locale : aucune attente de verrou SQLite dépassée dans cette session (délai 2500 ms).' (Format-DomeniaSqliteBusySummary -Count 0)
    $text=Format-DomeniaSqliteBusySummary -Count 3 -LastUtc $script:X06Now -TimeoutMs 1200
    Assert-True ($text.StartsWith('Base locale occupée : 3 attente(s) de verrou SQLite dépassée(s) dans cette session, la dernière à ')) $text
    Assert-True ($text.EndsWith(' (délai 1200 ms, réglage LocalStore.DatabaseBusyTimeoutMs).')) $text
    Assert-True ((Format-DomeniaSqliteBusySummary -Count 1 -TimeoutMs 'x').Contains('délai 2500 ms')) 'Delai illisible non ramene au defaut'
}
Test-Case 'FI-13' 'Les quatre gestes qui modifient la base ont un libelle, un autre est refuse' {
    Assert-Equal 'la mise à jour de lʼOU choisie' (Get-DomeniaGestureBackupLabel 'IndexUpdate')
    Assert-Equal 'lʼimport CSV des associations' (Get-DomeniaGestureBackupLabel 'LinkImport')
    Assert-Equal 'le retrait des associations orphelines' (Get-DomeniaGestureBackupLabel 'LinkPrune')
    Assert-Equal 'lʼoubli des relevés du parc' (Get-DomeniaGestureBackupLabel 'ParkReset')
    Assert-Throws {Get-DomeniaGestureBackupLabel 'StoragePurge'} 'Geste inconnu accepte'
}
Test-Case 'FI-13' 'Une copie verifiee de moins de 30 min sert de point de retour, sinon une copie est due' {
    $none=Get-DomeniaGestureBackupDecision -LastSuccessUtc '' -NowUtc $script:X06Now
    Assert-True $none.Due;Assert-Equal 'NoBackup' $none.Reason
    $recent=Get-DomeniaGestureBackupDecision -LastSuccessUtc ($script:X06Now.AddMinutes(-10).ToString('o')) -NowUtc $script:X06Now
    Assert-False $recent.Due;Assert-Equal 'Recent' $recent.Reason;Assert-Equal 30 $recent.ReuseMinutes
    $stale=Get-DomeniaGestureBackupDecision -LastSuccessUtc ($script:X06Now.AddHours(-2).ToString('o')) -NowUtc $script:X06Now
    Assert-True $stale.Due;Assert-Equal 'Stale' $stale.Reason
    $future=Get-DomeniaGestureBackupDecision -LastSuccessUtc ($script:X06Now.AddHours(3).ToString('o')) -NowUtc $script:X06Now
    Assert-True $future.Due;Assert-Equal 'InvalidClock' $future.Reason
    $bad=Get-DomeniaGestureBackupDecision -LastSuccessUtc 'hier' -NowUtc $script:X06Now
    Assert-True $bad.Due;Assert-Equal 'NoBackup' $bad.Reason
    Assert-True (Get-DomeniaGestureBackupDecision -LastSuccessUtc ($script:X06Now.AddMinutes(-10).ToString('o')) -NowUtc $script:X06Now -ReuseMinutes 5).Due 'Fenetre de reutilisation ignoree'
}
Test-Case 'FI-13' 'La confirmation annonce la sauvegarde ou le point de retour reel' {
    Assert-Equal 'Une sauvegarde vérifiée de la base sera faite avant.' (Get-DomeniaGestureBackupNotice $null)
    Assert-Equal 'Une sauvegarde vérifiée de la base sera faite avant.' (Get-DomeniaGestureBackupNotice (Get-DomeniaGestureBackupDecision -NowUtc $script:X06Now))
    $notice=Get-DomeniaGestureBackupNotice (Get-DomeniaGestureBackupDecision -LastSuccessUtc ($script:X06Now.AddMinutes(-10).ToString('o')) -NowUtc $script:X06Now)
    Assert-True ($notice.StartsWith('Point de retour : la sauvegarde vérifiée de ')) $notice
    Assert-True ($notice.EndsWith(' a moins de 30 min ; aucune nouvelle copie.')) $notice
}
Test-Case 'UI-19' 'Le temps ecoule se lit en minutes, heures ou jours' {
    Assert-Equal 'à lʼinstant' (Get-DomeniaElapsedText -FromUtc $script:X06Now.AddSeconds(-30) -NowUtc $script:X06Now)
    Assert-Equal 'il y a 5 min' (Get-DomeniaElapsedText -FromUtc $script:X06Now.AddMinutes(-5) -NowUtc $script:X06Now)
    Assert-Equal 'il y a 3 h' (Get-DomeniaElapsedText -FromUtc $script:X06Now.AddHours(-3).AddMinutes(-20) -NowUtc $script:X06Now)
    Assert-Equal 'il y a 2 j' (Get-DomeniaElapsedText -FromUtc $script:X06Now.AddDays(-2).AddHours(-5) -NowUtc $script:X06Now)
    Assert-Equal 'à une date future (horloge à vérifier)' (Get-DomeniaElapsedText -FromUtc $script:X06Now.AddHours(1) -NowUtc $script:X06Now)
}
Test-Case 'UI-19' 'Le resume de la base donne domaine, taille et derniere sauvegarde, avec une alerte douce' {
    $recent=Get-DomeniaDatabaseLocationSummary -Domain 'example.local' -Bytes 4404019 -LastBackupUtc $script:X06Now.AddHours(-2) -NowUtc $script:X06Now
    Assert-Equal 'Base du domaine example.local · 4,2 Mo · sauvegardée il y a 2 h' $recent.Text
    Assert-False $recent.Alert;Assert-Equal '' $recent.AlertText
    $old=Get-DomeniaDatabaseLocationSummary -Domain 'example.local' -Bytes 4404019 -LastBackupUtc $script:X06Now.AddDays(-8) -NowUtc $script:X06Now
    Assert-Equal 'Base du domaine example.local · 4,2 Mo · sauvegardée il y a 8 j' $old.Text
    Assert-True $old.Alert;Assert-True ($old.AlertText.Contains('plus de 7 jours')) $old.AlertText
    $never=Get-DomeniaDatabaseLocationSummary -Domain 'example.local' -Bytes 512 -NowUtc $script:X06Now
    Assert-Equal 'Base du domaine example.local · 512 o · jamais sauvegardée' $never.Text
    Assert-True $never.Alert
    $demo=Get-DomeniaDatabaseLocationSummary -Domain 'demo.invalid' -Bytes 512 -NowUtc $script:X06Now -Demo
    Assert-Equal 'Base de démonstration · 512 o · jamais sauvegardée' $demo.Text
    Assert-False $demo.Alert 'Alerte de sauvegarde pour la base de demonstration'
    $unknown=Get-DomeniaDatabaseLocationSummary -Domain '' -Bytes -1 -LastBackupUtc $script:X06Now.AddMinutes(-3) -NowUtc $script:X06Now
    Assert-Equal 'Base locale · taille inconnue · sauvegardée il y a 3 min' $unknown.Text
    $missing=Get-DomeniaDatabaseLocationSummary -Domain 'example.local' -Missing
    Assert-Equal 'Aucune base locale pour ce domaine pour lʼinstant.' $missing.Text
    Assert-False $missing.Alert
}
Test-Case 'DS-09' 'Les quatre tuiles de la base autonome, sans USN ni duree' {
    $fr=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $tiles=@(Get-DomeniaIndexTiles -Users 1000 -Computers 234 -Active 200 -Disabled 34 -Links 3 -LastUtc $script:X06Now.AddMinutes(-65) -NowUtc $script:X06Now)
    Assert-Equal 4 $tiles.Count
    Assert-Equal 'Accounts,Computers,Links,Updated' (($tiles|ForEach-Object{$_.Key}) -join ',')
    Assert-Equal 'Comptes,Postes,Associations,Dernière mise à jour' (($tiles|ForEach-Object{$_.Caption}) -join ',')
    Assert-Equal ((1000L).ToString('N0',$fr)) $tiles[0].Value
    Assert-Equal '234' $tiles[1].Value;Assert-Equal '200 actifs · 34 désactivés' $tiles[1].Detail
    Assert-Equal '3' $tiles[2].Value
    Assert-Equal 'il y a 1 h' $tiles[3].Value;Assert-True ($tiles[3].Detail.StartsWith('le ')) $tiles[3].Detail
    $never=@(Get-DomeniaIndexTiles -NowUtc $script:X06Now)
    Assert-Equal '0' $never[0].Value;Assert-Equal 'Jamais' $never[3].Value;Assert-Equal 'aucune lecture complète de ce périmètre' $never[3].Detail
    $negative=@(Get-DomeniaIndexTiles -Users -4 -Computers -1 -Links -2 -NowUtc $script:X06Now)
    Assert-Equal '0' $negative[0].Value;Assert-Equal '0' $negative[1].Value;Assert-Equal '0' $negative[2].Value
    $unreadable=@(Get-DomeniaIndexTiles -Unreadable)
    Assert-Equal 4 $unreadable.Count
    foreach($tile in $unreadable){Assert-Equal '—' $tile.Value;Assert-Equal 'base illisible' $tile.Detail}
}
# FI-19 (L20) : lectures locales hors du fil de l interface. Reponses du worker LocalIndexRead, donnees fictives.
Test-Case 'FI-19' 'Metadonnees : base absente lue comme vide, reponse incomplete refusee' {
    $state=ConvertTo-DomeniaIndexMetadataState -Result ([pscustomobject]@{Rows=@();Busy=$false;Missing=$true;MachineCount=0})
    Assert-True $state.Missing;Assert-Equal 0 $state.Counts.Total;Assert-Equal 0 $state.SyncStates.Count
    Assert-True ($null -eq $state.Info) 'Aucun repere sans base'
    Assert-Throws { ConvertTo-DomeniaIndexMetadataState -Result ([pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0}) } 'Une reponse sans compteurs serait presentee comme une base vide'
    Assert-Throws { ConvertTo-DomeniaIndexMetadataState -Result $null } 'Reponse absente acceptee'
}
Test-Case 'FI-19' 'Metadonnees : repere du domaine, identifiant d invocation et portees indexees' {
    $sync=@(
        [pscustomobject]@{scope='directory';server='dc1.example.invalid';base_dn='DC=example,DC=invalid';highest_usn=4242L;last_sync='2026-10-01T08:00:00Z';item_count=3L;details='reconcile=1;inv=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'},
        [pscustomobject]@{scope='ou:ou=parc,dc=example,dc=invalid';server='dc1.example.invalid';base_dn='OU=Parc,DC=example,DC=invalid';highest_usn=4242L;last_sync='2026-10-01T08:00:00Z';item_count=2L;details=''},
        [pscustomobject]@{scope='attempt:ou=parc,dc=example,dc=invalid';server='';base_dn='';highest_usn=0L;last_sync='2026-10-02T08:00:00Z';item_count=0L;details=''})
    $counts=[pscustomobject]@{Total=3L;Users=1L;Computers=2L;MachinesActive=1L;MachinesDisabled=1L}
    $state=ConvertTo-DomeniaIndexMetadataState -Result ([pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=1;SyncStates=$sync;Counts=$counts})
    Assert-False $state.Missing
    Assert-Equal 3 $state.SyncStates.Count
    Assert-True $state.SyncStates.ContainsKey('attempt:ou=parc,dc=example,dc=invalid')
    Assert-Equal 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' $state.Info.InvocationId
    Assert-Equal 4242 $state.Info.Usn;Assert-Equal 3 $state.Info.Count;Assert-Equal 'dc1.example.invalid' $state.Info.Server;Assert-Equal '2026-10-01T08:00:00Z' $state.Info.Date
    Assert-Equal 3 $state.Counts.Total;Assert-Equal 1 $state.Counts.Users;Assert-Equal 2 $state.Counts.Computers;Assert-Equal 1 $state.Counts.MachinesActive;Assert-Equal 1 $state.Counts.MachinesDisabled
    $noInv=ConvertTo-DomeniaIndexMetadataState -Result ([pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0;SyncStates=@([pscustomobject]@{scope='directory';server='dc1';base_dn='DC=example,DC=invalid';highest_usn=1L;last_sync='';item_count=0L;details='inv=pas-un-guid'});Counts=$counts})
    Assert-Equal '' $noInv.Info.InvocationId 'Un identifiant mal forme ne devient pas un repere'
    $noDirectory=ConvertTo-DomeniaIndexMetadataState -Result ([pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0;SyncStates=@($sync[1]);Counts=$counts})
    Assert-True ($null -eq $noDirectory.Info) 'Une OU seule ne fournit pas le repere du domaine'
}
Test-Case 'FI-19' 'Resume des secrets : nombre de cles, LAPS, verdict et age, sans aucune valeur' {
    $now=[datetime]'2026-01-04T10:00:00Z'
    $entry=[pscustomobject]@{computer='PC-1';checked_at='2026-01-01T10:00:00Z';bitlocker_keys=2L;bitlocker_last='31/12/2025';laps_scheme='LAPS Windows';laps_expiry='15/01/2026';verdict='Lecture autorisée'}
    $text=Format-DomeniaSecretIndexSummary -Entry $entry -Now $now
    Assert-Equal 'Relevé il y a 3 jour(s) : 2 clé(s) BitLocker, la plus récente du 31/12/2025, LAPS Windows, expiration 15/01/2026. Lecture autorisée. Les valeurs ne sont jamais conservées : il faut les recharger.' $text
    $hours=Format-DomeniaSecretIndexSummary -Entry $entry -Now ([datetime]'2026-01-01T15:00:00Z')
    Assert-True ($hours.StartsWith('Relevé il y a 5 heure(s) : ')) $hours
    $none=[pscustomobject]@{checked_at='2026-01-01T10:00:00Z';bitlocker_keys=0L;bitlocker_last='';laps_scheme='';laps_expiry='';verdict=''}
    Assert-Equal 'Relevé il y a 3 jour(s) : aucune clé BitLocker. Les valeurs ne sont jamais conservées : il faut les recharger.' (Format-DomeniaSecretIndexSummary -Entry $none -Now $now)
    $unknown=[pscustomobject]@{checked_at='2026-01-01T10:00:00Z';bitlocker_keys=-1L;bitlocker_last='';laps_scheme='';laps_expiry='';verdict='Accès refusé'}
    Assert-Equal '' (Format-DomeniaSecretIndexSummary -Entry $unknown -Now $now) 'Rien de releve : aucun resume'
    Assert-Equal '' (Format-DomeniaSecretIndexSummary -Entry $null -Now $now)
    $badDate=Format-DomeniaSecretIndexSummary -Entry ([pscustomobject]@{checked_at='date illisible';bitlocker_keys=1L;bitlocker_last='';laps_scheme='';laps_expiry='';verdict=''}) -Now $now
    Assert-True ($badDate.StartsWith('Relevé le date illisible : 1 clé(s) BitLocker.')) $badDate
}
Test-Case 'FI-19' 'Historique des mesures : un modele par operation, valeurs absentes conservees' {
    $rows=@(
        [pscustomobject]@{operation='IndexBuild';n=2L;ms_per_item=30.0;min_ms_per_item=20.0;max_ms_per_item=40.0;bytes_per_item=20.0;fallback_ratio=$null;success_ratio=0.95},
        [pscustomobject]@{operation='ParkSweep';n=0L;ms_per_item=$null;min_ms_per_item=$null;max_ms_per_item=$null;bytes_per_item=$null;fallback_ratio=$null;success_ratio=$null},
        [pscustomobject]@{operation='';n=5L},
        $null)
    $models=ConvertTo-DomeniaOperationHistoryModels -Rows $rows
    Assert-Equal 2 $models.Count 'Une operation sans nom est ignoree'
    Assert-Equal 2 $models['IndexBuild'].n;Assert-Equal 30.0 $models['IndexBuild'].ms_per_item
    Assert-True ($null -eq $models['IndexBuild'].fallback_ratio) 'Un ratio absent ne devient pas zero'
    Assert-Equal 0 $models['ParkSweep'].n
    Assert-True ($null -eq $models['ParkSweep'].ms_per_item)
    Assert-Equal 0 (ConvertTo-DomeniaOperationHistoryModels -Rows @()).Count
}
Test-Case 'FI-19' 'Couverture du parc : index en memoire d abord, compte relu sinon, inconnu signale' {
    $state=@{
        'PC-1'=[pscustomobject]@{Computer='PC-1';LastProbe='2026-10-01T08:00:00';Status='Session';User='alice';Attempts=1}
        'PC-2'=[pscustomobject]@{Computer='PC-2';LastProbe='2026-10-03T08:00:00';Status='Aucune';User='';Attempts=2}
        'PC-3'=[pscustomobject]@{Computer='PC-3';LastProbe='illisible';Status='Session';User='bob';Attempts=1}
    }
    $index=@([pscustomobject]@{Type='Machine';State='Actif'},[pscustomobject]@{Type='Machine';State='Desactive'},[pscustomobject]@{Type='Utilisateur';State='Actif'},[pscustomobject]@{Type='Machine';State=''})
    $fromIndex=Get-DomeniaParkCoverageFigures -State $state -IndexRows $index -KnownMachineCount 50 -Dormants 4
    Assert-Equal 2 $fromIndex.Machines 'Postes actifs de l index en memoire'
    Assert-Equal 3 $fromIndex.Releves;Assert-Equal 2 $fromIndex.AvecSession;Assert-Equal 4 $fromIndex.Dormants
    Assert-Equal '2026-10-03T08:00:00' $fromIndex.Dernier 'Releve le plus recent'
    Assert-Equal 50 (Get-DomeniaParkCoverageFigures -State $state -KnownMachineCount 50).Machines 'Compte relu avec le releve'
    Assert-Equal (-1) (Get-DomeniaParkCoverageFigures -State $state).Machines 'Compte inconnu signale'
    $empty=Get-DomeniaParkCoverageFigures -State $null -KnownMachineCount 0
    Assert-Equal 0 $empty.Releves;Assert-Equal '' $empty.Dernier;Assert-Equal 0 $empty.Machines
}
