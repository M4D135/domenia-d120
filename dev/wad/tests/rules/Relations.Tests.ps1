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
