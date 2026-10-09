# D041-D050 : relations utilisateur / poste. Donnees fictives uniquement.
$script:U=[pscustomobject]@{Domain='example.test';Guid='f4dc5a91-c11b-46b5-893d-9a2cbbad31ad';Type='Utilisateur';Reader='reader';Session='s1';Generation='1'}
$script:M=[pscustomobject]@{Domain='example.test';Guid='3a760e2f-315a-4155-a1d0-26a319a64cf2';Type='Machine';Reader='reader';Session='s1';Generation='1'}
Test-Case 'D041' 'Meme modele dans les deux sens' {
    $u=Get-DomeniaRelationDirection 'Utilisateur';$m=Get-DomeniaRelationDirection 'Machine'
    Assert-Equal 'Machine' $u.TargetType;Assert-Equal 'Utilisateur' $m.TargetType;Assert-Equal 'Associer cet utilisateur' $m.Action
    Assert-True ($m.SearchLabel -match 'utilisateur') 'Depuis un poste la recherche vise un utilisateur'
}
Test-Case 'D041' 'Association confirmee dans les deux sens' {
    Assert-True (Test-DomeniaRelationConfirmation $script:U $script:U $script:M $script:M)
    Assert-True (Test-DomeniaRelationConfirmation $script:M $script:M $script:U $script:U)
    Assert-False (Test-DomeniaRelationConfirmation $script:U $script:U $script:U $script:U) 'Deux objets du meme type ne s associent pas'
}
Test-Case 'D044' 'Toute difference d identite invalide la confirmation' {
    foreach($field in @('Domain','Guid','Type','Reader','Session','Generation')){
        $copy=$script:U.PSObject.Copy();$copy.$field='changed'
        Assert-False (Test-DomeniaSameSubject $script:U $copy) ('Champ '+$field)
    }
    Assert-False (Test-DomeniaSameSubject $script:U $null)
    $noGuid=$script:U.PSObject.Copy();$noGuid.Guid='';Assert-False (Test-DomeniaSameSubject $noGuid $noGuid)
}
Test-Case 'D044' 'Chercher un poste a associer ne transforme pas le sujet utilisateur' {
    $machineSelected=[pscustomobject]@{Type='Machine';Guid=$script:M.Guid}
    Assert-False (Resolve-DomeniaRelationSubjectChange $script:U $machineSelected $true $false).Change
    Assert-False (Resolve-DomeniaRelationSubjectChange $script:U $machineSelected $false $true).Change
    Assert-True (Resolve-DomeniaRelationSubjectChange $script:U $machineSelected $false $false).Change
    Assert-False (Resolve-DomeniaRelationSubjectChange $script:U ([pscustomobject]@{Type='Groupe';Guid='x'})).Change
}
Test-Case 'D042' 'Natures distinctes : affectation, console, session distante, historique, indice, import' {
    Assert-Equal 'Affectation' (Get-DomeniaRelationKind 'Saisie manuelle');Assert-Equal 'Console' (Get-DomeniaRelationKind 'Console CIM/DCOM')
    Assert-Equal 'SessionRdp' (Get-DomeniaRelationKind 'Session RDP (WTS)');Assert-Equal 'Importe' (Get-DomeniaRelationKind 'Import CSV')
    Assert-Equal 'Indice' (Get-DomeniaRelationKind 'Attribut description');Assert-Equal 'Historique' (Get-DomeniaRelationKind 'Journal 4624');Assert-Equal 'Inconnu' (Get-DomeniaRelationKind '97')
}
Test-Case 'D042' 'La session d un administrateur ne remplace pas l affectation declaree' {
    $owner=[pscustomobject]@{UserLogin='jdupont';UserGuid=$script:U.Guid;Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Saisie manuelle'}
    $admin=[pscustomobject]@{UserLogin='adm-x';UserGuid='99999999-9999-9999-9999-999999999999';Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Console CIM/DCOM'}
    $r=Resolve-DomeniaRelationUpsert @($owner) $admin
    Assert-Equal 'Add' $r.Action;Assert-True ($null -eq $r.Replace) 'Le proprietaire declare reste en place'
    $again=Resolve-DomeniaRelationUpsert @($owner,$admin) $admin;Assert-Equal 'Refresh' $again.Action;Assert-True ([object]::ReferenceEquals($again.Replace,$admin))
}
Test-Case 'D043' 'Qualification par badge et regle, sans pourcentage' {
    $b=Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Console CIM/DCOM';When='2026-01-01';Confidence=97})
    Assert-Equal 'Observe' $b.Badge;Assert-True ($b.Rule.Length -gt 20);Assert-False (($b.Badge+$b.Rule+$b.Provenance) -match '97|%')
    Assert-Equal 'Declare' (Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Saisie manuelle'})).Badge
    Assert-Equal 'Contradictoire' (Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Saisie manuelle'}) $true).Badge
    Assert-Equal 'Source a verifier' (Get-DomeniaEvidenceKind '97');Assert-Equal 'Declare' (Get-DomeniaEvidenceKind 'Manuel');Assert-Equal 'Observe' (Get-DomeniaEvidenceKind 'Console CIM/DCOM')
}
Test-Case 'D045' 'Parcours d association dans la page : etats et refus explicites' {
    $s='Idle'
    foreach($e in @('Search','Results','Pick','Confirm','Verified')){$step=Step-DomeniaAssociationState $s $e;Assert-True $step.Accepted ($e+' depuis '+$s);$s=$step.State}
    Assert-Equal 'Saved' $s
    Assert-False (Step-DomeniaAssociationState 'Idle' 'Confirm').Accepted 'Confirmer sans cible choisie est refuse'
    Assert-Equal 'Idle' (Step-DomeniaAssociationState 'Pending' 'SubjectChanged').State 'Un changement de sujet annule la confirmation en attente'
    Assert-Equal 'Failed' (Step-DomeniaAssociationState 'Verifying' 'VerifyFailed').State
}
Test-Case 'D046' 'Un candidat indique pourquoi il est propose ; IP ou nom partiel ne suffisent pas' {
    $c=@(Merge-DomeniaRelationCandidates -Known @([pscustomobject]@{Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Saisie manuelle'}) -Observations @([pscustomobject]@{Computer='PC-1';Guid=$script:M.Guid;Detail='console le 01/01'}) -Hints @([pscustomobject]@{Computer='PC-2';Guid='';Address='10.0.0.5';Detail='description'}) -Domain 'example.test')
    Assert-Equal 2 $c.Count
    $pc1=@($c|Where-Object{$_.Computer -eq 'PC-1'})[0];Assert-True $pc1.Associable;Assert-True ($pc1.Origins -match 'memorisee' -and $pc1.Origins -match 'Observation');Assert-True ($pc1.Why.Length -gt 10)
    $pc2=@($c|Where-Object{$_.Computer -eq 'PC-2'})[0];Assert-False $pc2.Associable;Assert-True ($pc2.Blocker -match 'ne suffit pas')
}
Test-Case 'D047' 'Aucune substitution silencieuse du perimetre' {
    $root=Get-DomeniaDetectionScopePlan -RequestedScope OU -OuDn 'DC=example,DC=test' -DomainDn 'DC=example,DC=test'
    Assert-False $root.Allowed;Assert-Equal 'OU' $root.Scope
    $none=Get-DomeniaDetectionScopePlan -RequestedScope Candidates
    Assert-False $none.Allowed;Assert-Equal 'Candidates' $none.Scope 'Le perimetre demande n est pas remplace';Assert-True ($none.ZeroMeaning -match 'aucune source')
    $emptyOu=Get-DomeniaDetectionScopePlan -RequestedScope OU -OuDn 'OU=X,DC=example,DC=test' -DomainDn 'DC=example,DC=test'
    Assert-False $emptyOu.Allowed;Assert-Equal 'OU' $emptyOu.Scope
}
Test-Case 'D047' 'La liste interrogee correspond a celle confirmee' {
    $t2=[pscustomobject]@{Domain='example.test';Guid='55555555-5555-5555-5555-555555555555'}
    $plan=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @($script:M,$script:M,$t2) -Limit 20
    Assert-True $plan.Allowed;Assert-Equal 2 $plan.Candidates.Count;Assert-True $plan.RequiresConfirmation
    Assert-True (Test-DomeniaDetectionMatchesPlan $plan @($t2,$script:M));Assert-False (Test-DomeniaDetectionMatchesPlan $plan @($script:M))
    Assert-False (Test-DomeniaDetectionMatchesPlan $plan @($script:M,$t2,[pscustomobject]@{Guid='66666666-6666-6666-6666-666666666666'}))
    $limited=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @($script:M,$t2) -Limit 1;Assert-True $limited.Truncated;Assert-Equal 2 $limited.Eligible
}
Test-Case 'D048' 'La liste generale ne declenche aucune sonde' {
    Assert-False (Test-DomeniaProbeAllowed 'ListRender');Assert-False (Test-DomeniaProbeAllowed 'Scroll');Assert-False (Test-DomeniaProbeAllowed 'Refresh')
    Assert-True (Test-DomeniaProbeAllowed 'ExplicitDetect')
}
Test-Case 'D048' 'Compteurs interroges / refuses / confirmes et resultat partiel' {
    $c=New-DomeniaDetectionCounters 5
    foreach($o in @('Confirmed','Refused','NoSession')){[void](Add-DomeniaDetectionOutcome $c $o)}
    $text=Get-DomeniaDetectionCounterText $c
    Assert-True ($text -match '3 interroge\(s\) sur 5' -and $text -match '1 confirme' -and $text -match '1 refuse' -and $text -match '2 restant')
    [void](Add-DomeniaDetectionOutcome $c 'Stopped');Assert-True ((Get-DomeniaDetectionCounterText $c) -match 'partiel')
    Assert-False (Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @($script:M)).IncludeRdp 'Sessions RDP : option separee, non cochee par defaut'
}
Test-Case 'D049' 'Un compte local ou homonyme d un autre domaine n est pas le compte AD cherche' {
    $t=[pscustomobject]@{Login='jdupont';NetbiosDomain='EXAMPLE';DnsDomain='example.test';Sid='S-1-5-21-1-2-3-1104'}
    Assert-False (Test-DomeniaAccountIdentityMatch $t 'PC-1\jdupont' '' 'PC-1.example.test').Match
    Assert-False (Test-DomeniaAccountIdentityMatch $t '.\jdupont' '' 'PC-1').Match
    Assert-False (Test-DomeniaAccountIdentityMatch $t 'AUTRE\jdupont' '' 'PC-1').Match
    Assert-False (Test-DomeniaAccountIdentityMatch $t 'jdupont' '' 'PC-1').Match 'Nom non qualifie : pas une confirmation'
    Assert-True (Test-DomeniaAccountIdentityMatch $t 'EXAMPLE\JDupont' '' 'PC-1').Match
    Assert-True (Test-DomeniaAccountIdentityMatch $t 'jdupont@example.test' '' 'PC-1').Match
}
Test-Case 'D049' 'Le SID tranche : renommage accepte, homonyme refuse' {
    $t=[pscustomobject]@{Login='jdupont';NetbiosDomain='EXAMPLE';DnsDomain='example.test';Sid='S-1-5-21-1-2-3-1104'}
    $renamed=Test-DomeniaAccountIdentityMatch $t 'EXAMPLE\jmartin' 'S-1-5-21-1-2-3-1104' 'PC-1';Assert-True ($renamed.Match -and $renamed.Certain)
    $other=Test-DomeniaAccountIdentityMatch $t 'EXAMPLE\jdupont' 'S-1-5-21-1-2-3-9999' 'PC-1';Assert-True (-not $other.Match -and $other.Certain)
}
Test-Case 'D049' 'Postes partages et plusieurs postes par utilisateur : cles distinctes' {
    $a=[pscustomobject]@{UserGuid=$script:U.Guid;ComputerGuid=$script:M.Guid;Source='Console CIM/DCOM'}
    $b=[pscustomobject]@{UserGuid='99999999-9999-9999-9999-999999999999';ComputerGuid=$script:M.Guid;Source='Console CIM/DCOM'}
    $c=[pscustomobject]@{UserGuid=$script:U.Guid;ComputerGuid='55555555-5555-5555-5555-555555555555';Source='Console CIM/DCOM'}
    Assert-Equal 3 (@((Get-DomeniaRelationKey $a),(Get-DomeniaRelationKey $b),(Get-DomeniaRelationKey $c))|Select-Object -Unique).Count
}
Test-Case 'D050' 'Une suppression locale est tracee et restaurable' {
    $rel=[pscustomobject]@{UserLogin='jdupont';UserGuid=$script:U.Guid;Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Saisie manuelle';When='2026-01-01'}
    $entry=New-DomeniaLinkHistoryEntry Removed $rel 'operateur'
    Assert-Equal 'Removed' $entry.Action;Assert-Equal 'operateur' $entry.Declarant;Assert-Equal 'Affectation' $entry.Relation.Kind
    $restore=Get-DomeniaLinkRestoreCandidate $entry @();Assert-True $restore.Restorable;Assert-Equal 'PC-1' $restore.Relation.Computer
    Assert-False (Get-DomeniaLinkRestoreCandidate $entry @($rel)).Restorable 'Deja presente : pas de doublon'
    Assert-False (Get-DomeniaLinkRestoreCandidate (New-DomeniaLinkHistoryEntry Added $rel 'x') @()).Restorable
}
Test-Case 'D050' 'Observations contradictoires signalees sans fusion' {
    $owner=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Saisie manuelle'}
    $seen=[pscustomobject]@{UserLogin='mmartin';Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Console CIM/DCOM'}
    $same=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Console CIM/DCOM'}
    $conflicts=@(Get-DomeniaLinkConflicts @($owner,$seen,$same))
    Assert-Equal 1 $conflicts.Count;Assert-Equal 'mmartin' $conflicts[0].Observed;Assert-Equal 2 $conflicts[0].Relations.Count
    Assert-Equal 0 @(Get-DomeniaLinkConflicts @($owner,$same)).Count
}
Test-Case 'D043' 'Sources reelles du dernier utilisateur : historique distinct de la console' {
    foreach($s in @('CIM dernier utilisateur LogonUI','CIM profil recent','Registre LogonUI','Security 4624','Tache locale LogonUI','Tache locale profil recent','WinRM dernier utilisateur LogonUI')){Assert-Equal 'Historique' (Get-DomeniaRelationKind $s) $s}
    foreach($s in @('CIM utilisateur courant','WinRM utilisateur courant','WinRM session explorer','Tache locale QUSER','Tache locale ComputerSystem','Console CIM/DCOM')){Assert-Equal 'Console' (Get-DomeniaRelationKind $s) $s}
    Assert-Equal 'Indice' (Get-DomeniaRelationKind 'Responsable déclaré') 'managedBy n est pas une affectation declaree'
    Assert-Equal 'Indice' (Get-DomeniaRelationKind 'Événement Kerberos 4768')
}
Test-Case 'D049' 'UPN explicite different du login : accepte seulement s il est identique' {
    $t=[pscustomobject]@{Login='jdupont';NetbiosDomain='EXAMPLE';DnsDomain='example.test';Upn='jean.dupont@example.test'}
    Assert-True (Test-DomeniaAccountIdentityMatch $t 'jean.dupont@example.test' '' 'PC-1').Match 'UPN explicite avec le suffixe du domaine'
    Assert-True (Test-DomeniaAccountIdentityMatch $t 'jdupont@example.test' '' 'PC-1').Match 'UPN implicite login@domaine'
    Assert-False (Test-DomeniaAccountIdentityMatch $t 'jean.dupond@example.test' '' 'PC-1').Match 'Autre prefixe'
    Assert-False (Test-DomeniaAccountIdentityMatch $t 'jdupont@autre.test' '' 'PC-1').Match 'Autre suffixe'
}
Test-Case 'D042' 'Meme relation avec ou sans GUID : rafraichie, pas dupliquee' {
    $legacy=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Console CIM/DCOM'}
    $known=[pscustomobject]@{UserLogin='EXAMPLE\jdupont';UserGuid=$script:U.Guid;Computer='pc-1.example.test';ComputerGuid=$script:M.Guid;Source='CIM utilisateur courant'}
    Assert-True (Test-DomeniaSameRelation $legacy $known) 'Ligne historique sans GUID'
    $r=Resolve-DomeniaRelationUpsert @($legacy) $known;Assert-Equal 'Refresh' $r.Action
    $recreated=[pscustomobject]@{UserLogin='jdupont';UserGuid='99999999-9999-9999-9999-999999999999';Computer='PC-1';ComputerGuid=$script:M.Guid;Source='Console CIM/DCOM'}
    Assert-False (Test-DomeniaSameRelation $known $recreated) 'Compte recree : autre relation'
    Assert-False (Test-DomeniaSameRelation $legacy ([pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Saisie manuelle'})) 'Autre nature'
}
Test-Case 'D042' 'Stockage a une relation par poste : l affectation declaree n est jamais remplacee' {
    $owner=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Saisie manuelle';When='2026-01-01 08:00:00'}
    $admin=[pscustomobject]@{UserLogin='adm-x';Computer='PC-1';Source='Console CIM/DCOM';When='2026-02-01T08:00:00Z'}
    $p=Resolve-DomeniaRelationStoragePlacement $owner $admin;Assert-Equal 'Session' $p.Placement
    $p=Resolve-DomeniaRelationStoragePlacement $admin $owner;Assert-Equal 'Replace' $p.Placement;Assert-True ([object]::ReferenceEquals($p.Demoted,$admin))
    $old=[pscustomobject]@{UserLogin='mmartin';Computer='PC-1';Source='Console CIM/DCOM';When='2026-01-05T08:00:00Z'}
    Assert-Equal 'Replace' (Resolve-DomeniaRelationStoragePlacement $old $admin).Placement 'Observation plus recente'
    Assert-Equal 'Session' (Resolve-DomeniaRelationStoragePlacement $admin $old).Placement 'Observation plus ancienne'
    Assert-Equal 'Stored' (Resolve-DomeniaRelationStoragePlacement $owner $admin $true).Placement 'Stockage par relation'
    Assert-True ([object]::ReferenceEquals((Select-DomeniaPrimaryRelation @($admin,$owner,$old)),$owner))
    Assert-True ([object]::ReferenceEquals((Select-DomeniaPrimaryRelation @($old,$admin)),$admin))
}
Test-Case 'D049' 'Cle de stockage : poste pour la relation principale, relation pour les autres' {
    $a=[pscustomobject]@{UserLogin='jdupont';Computer='pc-1.example.test';Source='Saisie manuelle'}
    Assert-Equal 'PC-1' (Get-DomeniaRelationStorageKey $a $true)
    $k=Get-DomeniaRelationStorageKey $a $false;Assert-True ($k.StartsWith('PC-1|') -and $k -match 'Affectation')
}
Test-Case 'D047' 'Sonde arretee tot : dans le plan ; cible hors plan : refusee' {
    $t2=[pscustomobject]@{Domain='example.test';Guid='55555555-5555-5555-5555-555555555555'}
    $plan=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @($script:M,$t2)
    Assert-True (Test-DomeniaDetectionWithinPlan $plan @($script:M.Guid)) 'Arret apres le premier poste'
    Assert-True (Test-DomeniaDetectionWithinPlan $plan @())
    Assert-False (Test-DomeniaDetectionWithinPlan $plan @('66666666-6666-6666-6666-666666666666')) 'Hors plan'
    Assert-False (Test-DomeniaDetectionWithinPlan $null @()) 'Sans plan confirme'
}
Test-Case 'D048' 'Statuts de lecture console convertis en compteurs' {
    Assert-Equal 'Confirmed' (ConvertTo-DomeniaDetectionOutcome 'CONFIRME');Assert-Equal 'NoSession' (ConvertTo-DomeniaDetectionOutcome 'LU')
    Assert-Equal 'Refused' (ConvertTo-DomeniaDetectionOutcome 'AUTH_REJETEE');Assert-Equal 'Refused' (ConvertTo-DomeniaDetectionOutcome 'REFUSE')
    Assert-Equal 'Unreachable' (ConvertTo-DomeniaDetectionOutcome 'DELAI');Assert-Equal '' (ConvertTo-DomeniaDetectionOutcome 'NON_DEMANDE')
}
Test-Case 'D045' 'Apres enregistrement, une autre ligne de la meme liste peut etre choisie' {
    Assert-Equal 'Pending' (Step-DomeniaAssociationState 'Saved' 'Pick').State
    Assert-Equal 'Pending' (Step-DomeniaAssociationState 'Failed' 'Pick').State
    Assert-False (Step-DomeniaAssociationState 'Searching' 'Pick').Accepted
}
# ---------------------------------------------------------------- L04 (RC1.14) : pistes CO-08, CO-28, CO-29, CO-30, DS-17, FO-14, UX-40
Test-Case 'CO-29' 'Ancienne date locale relue en heure locale, date ISO UTC inchangee' {
    $local=[datetime]::SpecifyKind([datetime]::ParseExact('2026-10-08 09:15:00','yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture),[DateTimeKind]::Local).ToUniversalTime()
    Assert-Equal $local (ConvertTo-DomeniaRelationUtcDate '2026-10-08 09:15:00') 'Texte sans fuseau lu comme UTC'
    Assert-Equal $local (ConvertTo-DomeniaRelationUtcDate '2026-10-08T09:15:00') 'Format s du Live lu comme UTC'
    $utc=[datetime]::SpecifyKind([datetime]::ParseExact('2026-10-08 07:15:00','yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture),[DateTimeKind]::Utc)
    Assert-Equal $utc (ConvertTo-DomeniaRelationUtcDate '2026-10-08T07:15:00.0000000Z')
    Assert-Equal ($local.ToString('o',[Globalization.CultureInfo]::InvariantCulture)) (ConvertTo-DomeniaRelationWhenText '2026-10-08 09:15:00') 'Reecriture en UTC ISO'
    Assert-True ((ConvertTo-DomeniaRelationWhenText '2026-10-08 09:15:00').EndsWith('Z')) 'Forme stockee sans Z'
    Assert-Equal '' (ConvertTo-DomeniaRelationWhenText 'illisible')
    Assert-Equal $utc (ConvertTo-DomeniaUtcDate '2026-10-08 07:15:00') 'Les autres domaines gardent la lecture UTC par defaut'
}
Test-Case 'CO-29' 'Affichage local court et tri sur l instant, formats melanges' {
    $old='2026-10-08 09:15:00'
    $instant=ConvertTo-DomeniaRelationUtcDate $old
    $newer=$instant.AddMinutes(30).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    Assert-Equal ($instant.ToLocalTime().ToString('dd/MM HH:mm',[Globalization.CultureInfo]::InvariantCulture)) (Format-DomeniaRelationWhen $old $instant) 'Affichage local de l annee courante'
    Assert-Equal '08/10 09:15' (Format-DomeniaRelationWhen $old $instant)
    Assert-Equal ($instant.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)) (Format-DomeniaRelationWhen $old $instant.AddYears(1)) 'Annee affichee pour une autre annee'
    $a=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Console CIM/DCOM';When=$old}
    $b=[pscustomobject]@{UserLogin='mmartin';Computer='PC-1';Source='Console CIM/DCOM';When=$newer}
    Assert-True ([object]::ReferenceEquals((Select-DomeniaPrimaryRelation @($a,$b)),$b)) 'La plus recente doit gagner, quel que soit le format'
    Assert-Equal 'Replace' (Resolve-DomeniaRelationStoragePlacement $a $b).Placement 'Observation plus recente non retenue'
    Assert-Equal 'Session' (Resolve-DomeniaRelationStoragePlacement $b $a).Placement 'Observation plus ancienne retenue'
    $sorted=@(@($a,$b)|Sort-Object -Property @{Expression={Get-DomeniaRelationWhenSortKey $_.When};Descending=$true})
    Assert-True ([object]::ReferenceEquals($sorted[0],$b)) 'Tri de la colonne Date faux'
    Assert-Equal ([datetime]::MinValue) (Get-DomeniaRelationWhenSortKey '')
}
Test-Case 'CO-30' 'Pick depuis Pending : message francais sans nom d etat interne' {
    $t=Step-DomeniaAssociationState 'Pending' 'Pick'
    Assert-False $t.Accepted
    Assert-True ($t.Reason -match 'confirm') ('Message : '+$t.Reason)
    Assert-False ($t.Reason -cmatch '\b(Idle|Searching|Candidate|Pending|Verifying|Saved|Failed|Pick|Confirm|Search)\b' -or $t.Reason.Contains('«')) ('Nom interne affiche : '+$t.Reason)
    Assert-True ($t.Detail -match 'Pick' -and $t.Detail -match 'Pending') 'Noms internes absents du journal'
    foreach($pair in @(@('Idle','Confirm'),@('Idle','Pick'),@('Searching','Pick'),@('Verifying','Pick'),@('Pending','Search'),@('Idle','Results'),@('Idle','Verified'),@('Idle','Cancel'))){
        $r=Step-DomeniaAssociationState $pair[0] $pair[1]
        Assert-False $r.Accepted ($pair -join ' ')
        Assert-False ($r.Reason -cmatch '\b(Idle|Searching|Candidate|Pending|Verifying|Saved|Failed|Pick|Search|Results|Verified|Cancel)\b') ('Nom interne : '+$r.Reason)
        Assert-True ($r.Reason.Length -gt 15) ($pair -join ' ')
    }
    Assert-True ((Step-DomeniaAssociationState 'Idle' 'Confirm').Reason -match 'choisissez')
}
Test-Case 'DS-17' 'Cle interne separee du libelle de la puce' {
    $declared=Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Saisie manuelle'})
    Assert-Equal 'Declare' $declared.Badge;Assert-Equal 'Déclaré' $declared.Label
    Assert-Equal 'Observé' (Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Console CIM/DCOM'})).Label
    Assert-Equal 'Importé' (Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Import CSV'})).Label
    Assert-Equal 'Contradictoire' (Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Saisie manuelle'}) $true).Label
    Assert-Equal 'À vérifier' (Get-DomeniaEvidenceLabel 'Source a verifier')
    Assert-True ($declared.Rule -match 'déclarée') 'Regle non accentuee'
}
Test-Case 'CO-08' 'Import CSV : source forcee Import CSV, jamais une affectation declaree' {
    $row=[pscustomobject]@{UserLogin='EXAMPLE\jdupont';Computer='pc-1.example.test';Source='Saisie manuelle';Confidence='100';VerifiedInAD='True';When='2026-10-08 09:15:00';Details='Bureau 12'}
    $v=ConvertFrom-DomeniaLinkCsvRow $row
    Assert-Equal 'EXAMPLE\jdupont' $v.User;Assert-Equal 'pc-1.example.test' $v.Computer;Assert-Equal 'Saisie manuelle' $v.FileSource
    $rel=New-DomeniaImportedRelation -User 'jdupont' -Computer 'PC-1' -FileName 'liens.csv' -Line 2 -FileSource $v.FileSource -FileDetails $v.Details -When $v.When -Verified $false
    Assert-Equal 'Import CSV' $rel.Source;Assert-Equal 'Importe' $rel.Kind;Assert-Equal 'Importe' (Get-DomeniaRelationKind $rel.Source)
    Assert-False ((Get-DomeniaRelationKind $rel.Source) -eq 'Affectation') 'Source du fichier reprise'
    Assert-Equal 'Importe' (Get-DomeniaEvidenceBadge $rel).Badge
    Assert-Equal 0 ([int]$rel.Confidence);Assert-False $rel.VerifiedInAD 'VerifiedInAD repris du fichier'
    Assert-True ($rel.Details -match 'Saisie manuelle' -and $rel.Details -match 'non reprise' -and $rel.Details -match 'enregistrement 2' -and -not ($rel.Details -match 'ligne')) $rel.Details
    Assert-Equal (ConvertTo-DomeniaRelationWhenText '2026-10-08 09:15:00') $rel.When 'Date ISO du fichier non convertie en UTC'
    $ambiguous=New-DomeniaImportedRelation -User 'jdupont' -Computer 'PC-1' -FileName 'liens.csv' -When '08/10/2026 09:15' -NowUtc '2026-10-08T07:00:00Z'
    Assert-Equal '2026-10-08T07:00:00.0000000Z' $ambiguous.When 'Date ambigue reprise'
    Assert-True ($ambiguous.Details -match 'non reconnue') 'Date ambigue non signalee'
}
Test-Case 'CO-08' 'Import CSV : apercu ligne par ligne, poste deja associe jamais remplace' {
    Assert-Equal 'Ignorée' (Get-DomeniaLinkImportStatus -User '' -Computer 'PC-1').Status
    Assert-Equal 'Ignorée' (Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -DuplicateInFile $true).Status
    $same=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -StoredLogin 'JDupont';Assert-False $same.Import;Assert-True ($same.Reason -match 'déjà connue')
    $other=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -StoredLogin 'mmartin';Assert-False $other.Import;Assert-True ($other.Reason -match 'mmartin') 'Le titulaire actuel doit etre nomme'
    $unknown=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -IndexAvailable $true -UserKnown $true -ComputerKnown $false
    Assert-Equal 'Inconnue' $unknown.Status;Assert-False $unknown.Import;Assert-True ($unknown.Reason -match 'poste absent')
    $ok=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -IndexAvailable $true -UserKnown $true -ComputerKnown $true;Assert-True ($ok.Import -and $ok.Verified)
    $blind=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1';Assert-True ($blind.Import -and -not $blind.Verified -and $blind.Reason -match 'non vérifiée')
    $empty=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -Unverified 'index local vide';Assert-True ($empty.Import -and $empty.Reason -match 'non vérifiée : index local vide') $empty.Reason
}
Test-Case 'CO-08' 'Import CSV : 64 associations au plus par import, la suite reste pour un second import' {
    $last=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -ReadyBefore 63;Assert-True $last.Import '64e ligne refusee'
    $over=Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -ReadyBefore 64
    Assert-False $over.Import '65e ligne importee';Assert-Equal 'Ignorée' $over.Status;Assert-True ($over.Reason -match 'Au-delà de 64' -and $over.Reason -match 'même fichier') $over.Reason
    # A row unknown in the index or already associated keeps its own reason, whatever the count.
    Assert-Equal 'Inconnue' (Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -IndexAvailable $true -UserKnown $false -ComputerKnown $true -ReadyBefore 64).Status
    Assert-True ((Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -StoredLogin 'jdupont' -ReadyBefore 64).Reason -match 'déjà connue')
}
Test-Case 'CO-29' 'Lecture memorisee des dates : meme instant, une seule lecture par texte, tri en un appel' {
    $first=ConvertTo-DomeniaRelationUtcDate '2026-10-08 09:15:00'
    Assert-Equal $first (ConvertTo-DomeniaRelationUtcDate '2026-10-08 09:15:00') 'Deuxieme lecture differente'
    Assert-Equal ([DateTimeKind]::Utc) $first.Kind
    Assert-True ($null -eq (ConvertTo-DomeniaRelationUtcDate 'illisible') -and $null -eq (ConvertTo-DomeniaRelationUtcDate 'illisible')) 'Texte illisible memorise comme une date'
    Assert-Equal ([datetime]::SpecifyKind([datetime]'2026-10-08 07:15:00',[DateTimeKind]::Utc)) (ConvertTo-DomeniaRelationUtcDate ([datetime]::SpecifyKind([datetime]'2026-10-08 07:15:00',[DateTimeKind]::Utc))) 'DateTime UTC'
    $ticks=Get-DomeniaRelationWhenTicks -Values @('2026-10-08T07:45:00.0000000Z','','2026-10-08 09:15:00')
    Assert-Equal 3 $ticks.Length;Assert-Equal 0L $ticks[1]
    Assert-Equal $first.Ticks $ticks[2];Assert-True ($ticks[0] -gt $ticks[2]) 'Ordre des instants'
    Assert-Equal 0 (Get-DomeniaRelationWhenTicks -Values @()).Length
    Assert-Equal (Format-DomeniaRelationWhen '2026-10-08 09:15:00' '2026-10-08T07:00:00Z') (Format-DomeniaRelationWhen $first '2026-10-08T07:00:00Z') 'Affichage depuis l instant deja lu'
}
Test-Case 'FO-14' 'Filtre texte et puces de Toutes les associations' {
    $a=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Saisie manuelle';Details='';Badge='Declare';BadgeLabel='Déclaré'}
    $b=[pscustomobject]@{UserLogin='mmartin';Computer='PC-2';Source='Console CIM/DCOM';Details='Bureau 12';Badge='Observe';BadgeLabel='Observé'}
    Assert-True (Test-DomeniaRelationMatchesFilter $a '' @())
    Assert-True (Test-DomeniaRelationMatchesFilter $b 'bureau' @());Assert-False (Test-DomeniaRelationMatchesFilter $a 'bureau' @())
    Assert-True (Test-DomeniaRelationMatchesFilter $a 'pc-1' @('Declare'));Assert-False (Test-DomeniaRelationMatchesFilter $b '' @('Declare','Contradictoire'))
    Assert-False (Test-DomeniaRelationMatchesFilter $null '' @())
}
Test-Case 'UX-40' 'Motif clair d une association orpheline' {
    Assert-True ((Get-DomeniaOrphanReason $false $true) -match '^Compte absent')
    Assert-True ((Get-DomeniaOrphanReason $true $false) -match '^Poste absent')
    Assert-True ((Get-DomeniaOrphanReason $false $false) -match 'Compte et poste')
    Assert-Equal '' (Get-DomeniaOrphanReason $true $true)
}
Test-Case 'CO-28' 'Le bouton Restaurer nomme l association' {
    $rel=[pscustomobject]@{UserLogin='jdupont';Computer='PC01';Source='Saisie manuelle'}
    Assert-Equal 'Restaurer jdupont → PC01' (Get-DomeniaRelationRestoreLabel (New-DomeniaLinkHistoryEntry Removed $rel 'operateur'))
    Assert-Equal 'Restaurer la suppression' (Get-DomeniaRelationRestoreLabel $null)
}
