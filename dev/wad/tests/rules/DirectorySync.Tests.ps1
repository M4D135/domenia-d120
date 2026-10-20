# Points 22, 23, 24 et 30 : recensement du perimetre, deplacements, disparitions et releves. Donnees fictives uniquement.
$script:DS0=[datetime]::new(2026,10,14,8,0,0,[DateTimeKind]::Utc)
Test-Case 'P23' 'Perimetre par frontieres RDN, virgule echappee et profondeur comprises' {
    $scope='OU=Lyon,DC=example,DC=invalid'
    Assert-True (Test-DomeniaDnInScope 'CN=PC1,OU=Lyon,DC=example,DC=invalid' $scope)
    Assert-False (Test-DomeniaDnInScope 'CN=PC1,OU=Lyon2,DC=example,DC=invalid' $scope) 'Un suffixe sans frontiere RDN nʼest pas le perimetre.'
    Assert-False (Test-DomeniaDnInScope 'CN=a\,OU=Lyon,DC=example,DC=invalid' $scope) 'Une virgule echappee nʼest pas une frontiere.'
    Assert-True (Test-DomeniaDnInScope 'CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid' $scope 'Subtree')
    Assert-False (Test-DomeniaDnInScope 'CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid' $scope 'OneLevel')
    Assert-True (Test-DomeniaDnInScope 'CN=PC1,OU=Lyon,DC=example,DC=invalid' 'ou=lyon,dc=example,dc=invalid' 'OneLevel') 'Casse ignoree.'
    Assert-True (Test-DomeniaDnInScope $scope $scope 'Base')
    Assert-False (Test-DomeniaDnInScope '' $scope)
    Assert-False (Test-DomeniaDnInScope 'CN=PC1,OU=Lyon,DC=example,DC=invalid' '')
}
Test-Case 'P23' 'Deplacement : meme GUID, nouvel emplacement, appartenance au perimetre et fil d Ariane' {
    $scope='OU=Lyon,DC=example,DC=invalid'
    $m=Get-DomeniaDirectoryMove -OldDn 'CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid' -NewDn 'CN=PC1,OU=Ateliers,OU=Lyon,DC=example,DC=invalid' -ScopeDn $scope
    Assert-Equal 'MovedWithin' $m.Kind;Assert-True $m.InScope;Assert-True $m.Moved
    Assert-Equal 'Lyon › Ateliers' $m.ToLocation;Assert-Equal 'Lyon › Postes' $m.FromLocation
    Assert-Equal 2 @($m.Breadcrumb).Count;Assert-Equal 'Lyon' @($m.Breadcrumb)[0]
    Assert-Equal 'Déplacé vers Lyon › Ateliers' (Get-DomeniaMoveStateText $m)
    $out=Get-DomeniaDirectoryMove -OldDn 'CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid' -NewDn 'CN=PC1,OU=Paris,DC=example,DC=invalid' -ScopeDn $scope
    Assert-Equal 'MovedOut' $out.Kind;Assert-False $out.InScope;Assert-True ($out.Text -match 'Paris')
    Assert-Equal 'Sorti du périmètre : Paris' (Get-DomeniaMoveStateText $out)
    Assert-Equal 'MovedIn' (Get-DomeniaDirectoryMove -OldDn 'CN=PC1,OU=Paris,DC=example,DC=invalid' -NewDn 'CN=PC1,OU=Lyon,DC=example,DC=invalid' -ScopeDn $scope).Kind
    $ren=Get-DomeniaDirectoryMove -OldDn 'CN=PC1,OU=Lyon,DC=example,DC=invalid' -NewDn 'CN=PC2,OU=Lyon,DC=example,DC=invalid' -ScopeDn $scope
    Assert-Equal 'Renamed' $ren.Kind;Assert-False $ren.Moved;Assert-True ($ren.Text -match 'PC1 → PC2')
    Assert-Equal 'Unchanged' (Get-DomeniaDirectoryMove -OldDn 'CN=PC1,OU=Lyon,DC=example,DC=invalid' -NewDn 'cn=pc1,ou=lyon,dc=example,dc=invalid').Kind
    Assert-Equal 'Unknown' (Get-DomeniaDirectoryMove -OldDn 'CN=PC1,OU=Lyon,DC=example,DC=invalid' -NewDn '').Kind
    Assert-Equal '(racine du domaine)' (Get-DomeniaDnLocation 'CN=PC1,DC=example,DC=invalid')
    Assert-Equal 'Lyon, Est' (Get-DomeniaDnLocation 'CN=PC1,OU=Lyon\, Est,DC=example,DC=invalid') 'Libelle decode.'
    Assert-Equal 'Emplacement à vérifier' (Get-DomeniaMoveStateText $null)
}
Test-Case 'P24' 'Disparition : seule une entree supprimee lue par GUID prouve une suppression' {
    $a=[pscustomobject]@{Guid='0f6c3a8e-2b8d-4c1e-9a77-5d2b9f1e0a11';LastDn='CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid';ScopeDn='OU=Lyon,DC=example,DC=invalid'}
    $refused=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Refused'})
    Assert-Equal 'NonConfirme' $refused.Status;Assert-True ($refused.Text -match 'refusée')
    $moved=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Read';FoundDn='CN=PC1,OU=Paris,DC=example,DC=invalid';DeletedRead='NotRequested'})
    Assert-Equal 'Deplace' $moved.Status;Assert-True ($moved.Text -match 'Paris');Assert-Equal 'MovedOut' $moved.Move.Kind
    $visible=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Read';FoundDn='CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid'})
    Assert-Equal 'Visible' $visible.Status;Assert-Equal 'De nouveau visible' $visible.Label
    $deleted=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Read';FoundDn='';DeletedRead='Read';Deleted=$true;DeletedWhenUtc=$script:DS0.ToString('o');LastKnownParent='OU=Postes,OU=Lyon,DC=example,DC=invalid';Recycled=$true})
    Assert-Equal 'Supprime' $deleted.Status;Assert-True ($deleted.Text -match 'Lyon › Postes');Assert-True ($deleted.Proof -match 'isDeleted');Assert-True ($deleted.Text -match 'recyclé')
    $empty=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Read';FoundDn='';DeletedRead='Empty';Deleted=$false})
    Assert-Equal 'NonVisible' $empty.Status 'Sans objet supprime visible, suppression et droits ne se distinguent pas.'
    $gone=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Read';FoundDn='';DeletedRead='Read';Deleted=$false})
    Assert-Equal 'Introuvable' $gone.Status
    $notRead=Resolve-DomeniaDirectoryAbsence $a ([pscustomobject]@{DomainRead='Read';FoundDn='';DeletedRead='Unavailable';Deleted=$false})
    Assert-Equal 'NonConfirme' $notRead.Status
    $noGuid=Resolve-DomeniaDirectoryAbsence ([pscustomobject]@{Guid='';LastDn='x';ScopeDn=''}) ([pscustomobject]@{DomainRead='Read';Deleted=$true})
    Assert-Equal 'NonConfirme' $noGuid.Status 'Sans GUID, aucune conclusion.'
    foreach($r in @($refused,$moved,$visible,$empty,$gone,$notRead,$noGuid)){Assert-True ($r.Status -ne 'Supprime') 'Aucune suppression sans preuve.'}
}
Test-Case 'P24' 'Verification bornee aux objets non revus ; fiche relue gardee seulement pour un objet existant' {
    $rows=@(1..250|ForEach-Object{[pscustomobject]@{Guid=('00000000-0000-0000-0000-'+('{0:D12}' -f $_));Status='NonVu';NoticedAt=$script:DS0.AddMinutes(-$_).ToString('o')}})
    $rows+=[pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111';Status='Supprime';NoticedAt=''}
    $rows+=[pscustomobject]@{Guid='';Status='NonVu';NoticedAt=''}
    $picked=@(Select-DomeniaAbsencesToCheck -Rows $rows -Limit 200)
    Assert-Equal 200 $picked.Count
    Assert-Equal 0 @($picked|Where-Object{($_.Status -eq 'Supprime') -or (-not $_.Guid)}).Count 'Une suppression prouvee ou une ligne sans GUID nʼest pas relue.'
    Assert-Equal ([string]$rows[249].Guid) ([string]$picked[0].Guid) 'Le plus ancien en premier.'
    $guid='0f6c3a8e-2b8d-4c1e-9a77-5d2b9f1e0a11'
    $resolution=[pscustomobject]@{Guid=$guid;Status='Deplace';FoundDn='CN=PC1,OU=Paris,DC=example,DC=invalid';Text='Objet present ailleurs.'}
    $record=[pscustomobject]@{Type='Machine';Guid=$guid;DN='CN=PC1,OU=Paris,DC=example,DC=invalid';Name='PC1'}
    $kept=New-DomeniaAbsenceStoreRow -Resolution $resolution -Record $record -CheckedUtc $script:DS0 -Server 'dc1.example.invalid'
    Assert-True ($null -ne $kept.Record);Assert-Equal 'Deplace' $kept.Status;Assert-Equal $script:DS0.ToString('o') $kept.CheckedAt
    $other=New-DomeniaAbsenceStoreRow -Resolution ([pscustomobject]@{Guid=$guid;Status='Supprime';FoundDn='';Text='Supprime.'}) -Record $record -CheckedUtc $script:DS0
    Assert-True ($null -eq $other.Record) 'Aucune fiche reinseree pour un objet supprime.'
    $wrong=New-DomeniaAbsenceStoreRow -Resolution $resolution -Record ([pscustomobject]@{Type='Machine';Guid='22222222-2222-2222-2222-222222222222';DN='x';Name='y'}) -CheckedUtc $script:DS0
    Assert-True ($null -eq $wrong.Record) 'Une fiche dʼun autre GUID est refusee.'
    $group=New-DomeniaAbsenceStoreRow -Resolution $resolution -Record ([pscustomobject]@{Type='Groupe';Guid=$guid;DN='x';Name='y'}) -CheckedUtc $script:DS0
    Assert-True ($null -eq $group.Record) 'La base ne garde que postes et comptes.'
}
Test-Case 'P24' 'Liste des disparitions : etats lisibles, totaux exacts, objets a verifier' {
    $base=@{object_guid='0f6c3a8e-2b8d-4c1e-9a77-5d2b9f1e0a11';object_type='Machine';name='PC1';last_dn='CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid';scope_dn='OU=Lyon,DC=example,DC=invalid';noticed_at=$script:DS0.ToString('o');status='NonVu';checked_at='';found_dn='';detail=''}
    $row=ConvertTo-DomeniaAbsenceRow ([pscustomobject]$base)
    Assert-Equal 'Non revu, à vérifier' $row.Etat;Assert-Equal 'Lyon › Postes' $row.Emplacement;Assert-True ($row.Detail -match 'supprimé');Assert-Equal '' $row.Verifie
    $base.status='Deplace';$base.found_dn='CN=PC1,OU=Paris,DC=example,DC=invalid';$base.detail='Objet present ailleurs.';$base.checked_at=$script:DS0.ToString('o')
    $moved=ConvertTo-DomeniaAbsenceRow ([pscustomobject]$base)
    Assert-Equal 'Lyon › Postes → Paris' $moved.Emplacement;Assert-True ([string]$moved.Verifie)
    $text=Get-DomeniaAbsenceSummary -Rows @($row,$moved) -Total 5 -Counts @([pscustomobject]@{status='NonVu';n=3},[pscustomobject]@{status='Deplace';n=2})
    Assert-True ($text -match '^5 objet');Assert-True ($text -match '3 non revu');Assert-True ($text -match '2 déplacé');Assert-True ($text -match 'Les 2 plus récents');Assert-True ($text -match '1 à vérifier')
    Assert-True ((Get-DomeniaAbsenceSummary -Rows @() -Total 0) -match 'Aucune disparition')
}
Test-Case 'P22' 'Recensement conseille : absent, partiel, ancien, ecart, horloge ; jamais lance seul' {
    $now=$script:DS0
    $absent=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Missing';At=$null;Partial=$false}) -NowUtc $now
    Assert-Equal 'Absent' $absent.State;Assert-True $absent.Due
    $recent=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now.AddDays(-2);Partial=$false}) -MaxAgeDays 7 -NowUtc $now
    Assert-Equal 'Recent' $recent.State;Assert-False $recent.Due;Assert-Equal 2 $recent.AgeDays
    $domain=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now.AddDays(-2);Partial=$false}) -NowUtc $now -IsDomain $true
    Assert-True ($domain.Text -match 'recense aussi toutes les identités')
    $old=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now.AddDays(-10);Partial=$false}) -MaxAgeDays 7 -NowUtc $now
    Assert-Equal 'Due' $old.State;Assert-True ($old.Text -match '10 jours')
    $partial=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Partial';At=$now.AddDays(-1);Partial=$true}) -NowUtc $now
    Assert-Equal 'Partial' $partial.State;Assert-True ($partial.Text -match 'Aucune disparition')
    $gap=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now;Partial=$false}) -GapCount 4 -NowUtc $now -IsDomain $true
    Assert-Equal 'Gap' $gap.State;Assert-True ($gap.Text -match '4 objet');Assert-True ($gap.Text -match 'par leur GUID')
    Assert-True ($gap.Text -match 'continue sans eux') 'Un ecart ne transforme jamais la mise a jour en relecture du domaine.'
    Assert-Equal 'Clock' (Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now.AddHours(2);Partial=$false}) -NowUtc $now).State
    Assert-Equal 90 (Get-DomeniaCensusAdvice -Coverage $null -MaxAgeDays 500 -NowUtc $now).MaxAgeDays
    Assert-Equal 'Absent' (Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='UnknownDepth';At=$now;Partial=$false}) -NowUtc $now).State 'Une profondeur inconnue ne vaut pas recensement.'
    # The census gap is a domain fact: an OU scope keeps its own advice and the gap is added to it.
    $ouRecent=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now.AddDays(-1);Partial=$false}) -GapCount 3 -MaxAgeDays 7 -NowUtc $now -IsDomain $false
    Assert-Equal 'Recent' $ouRecent.State;Assert-False $ouRecent.Due 'Le seuil de lʼOU decide de lʼechance.';Assert-True ($ouRecent.Text -match 'moins de 7 jours');Assert-True ($ouRecent.Text -match '3 objet')
    $ouOld=Get-DomeniaCensusAdvice -Coverage ([pscustomobject]@{Status='Complete';At=$now.AddDays(-9);Partial=$false}) -GapCount 3 -MaxAgeDays 7 -NowUtc $now
    Assert-Equal 'Due' $ouOld.State;Assert-True ($ouOld.Text -match 'objets manquants')
    Assert-Equal 0 (Get-DomeniaCensusAdvice -Coverage $null -GapCount -5 -NowUtc $now).GapCount 'Un ecart negatif vaut zero.'
}
Test-Case 'P22' 'Horloge douteuse : coverage reelle de Get-DomeniaFleetFreshness avec un point de reprise date dans le futur' {
    # The coverage is built as the application builds it: a sync_state row whose last_sync is in the future is ignored
    # by the freshness (ClockInvalid), so At stays empty; the advice must still say "clock", not "never read".
    if(-not ${function:Get-DomeniaFleetFreshness}){foreach($file in @('Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-BoardFleet.Model.ps1')){. (Join-Path $modules $file)}}
    $now=$script:DS0;$domain='DC=example,DC=invalid'
    $states=@{directory=[pscustomobject]@{scope='directory';server='dc1.example.invalid';base_dn=$domain;highest_usn=10;last_sync=$now.AddDays(3).ToString('o');item_count=5;details='inv=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;depth=Subtree'}}
    $coverage=Get-DomeniaFleetFreshness -ScopeDn '' -DomainDn $domain -SyncStates $states -NowUtc $now
    Assert-True ([bool]$coverage.ClockInvalid) 'Point de reprise futur signale.';Assert-True ($null -eq $coverage.At) 'Point de reprise futur ignore.'
    $advice=Get-DomeniaCensusAdvice -Coverage $coverage -NowUtc $now -IsDomain $true
    Assert-Equal 'Clock' $advice.State;Assert-True $advice.Due;Assert-True ($advice.Text -match 'horloge')
    Assert-False ($advice.Text -match 'aucune lecture complète') 'Pas de faux conseil de premiere lecture.'
    $withGap=Get-DomeniaCensusAdvice -Coverage $coverage -GapCount 2 -NowUtc $now -IsDomain $true
    Assert-Equal 'Clock' $withGap.State;Assert-True ($withGap.Text -match '2 objet') 'Lʼecart reste dit.'
    $proof=ConvertTo-DomeniaSnapshotCoverage $coverage
    Assert-Equal 'Unknown' $proof.State;Assert-True ($proof.Text -match 'horloge douteuse')
    $states.directory.last_sync=$now.AddDays(-1).ToString('o')
    Assert-Equal 'Recent' (Get-DomeniaCensusAdvice -Coverage (Get-DomeniaFleetFreshness -ScopeDn '' -DomainDn $domain -SyncStates $states -NowUtc $now) -NowUtc $now -IsDomain $true).State
}
Test-Case 'P22' 'Objets manquants lus par GUID : ajoutes, retires sans conclusion ou laisses a lire' {
    $guid='0f6c3a8e-2b8d-4c1e-9a77-5d2b9f1e0a11'
    $record=[pscustomobject]@{Type='Utilisateur';Guid=$guid;DN='CN=Ana,OU=Lyon,DC=example,DC=invalid';Name='Ana'}
    $found=New-DomeniaCensusGapStoreRow -Guid $guid.ToUpperInvariant() -Check ([pscustomobject]@{DomainRead='Read';FoundDn='CN=Ana,OU=Lyon,DC=example,DC=invalid';Record=$record}) -CheckedUtc $script:DS0 -Server 'dc1.example.invalid'
    Assert-Equal 'Visible' $found.Status;Assert-Equal $guid $found.Guid;Assert-True ([bool]$found.Gap);Assert-True ($null -ne $found.Record);Assert-Equal $script:DS0.ToString('o') $found.CheckedAt
    $gone=New-DomeniaCensusGapStoreRow -Guid $guid -Check ([pscustomobject]@{DomainRead='Read';FoundDn=''})
    Assert-Equal 'Introuvable' $gone.Status;Assert-True ($null -eq $gone.Record);Assert-True ($gone.Detail -match 'sans conclusion')
    $group=New-DomeniaCensusGapStoreRow -Guid $guid -Check ([pscustomobject]@{DomainRead='Read';FoundDn='CN=G,DC=example,DC=invalid';Record=$null})
    Assert-Equal 'Introuvable' $group.Status 'Ni utilisateur ni poste : retire, rien nʼest ajoute.'
    $other=New-DomeniaCensusGapStoreRow -Guid $guid -Check ([pscustomobject]@{DomainRead='Read';FoundDn='CN=Ana,OU=Lyon,DC=example,DC=invalid';Record=([pscustomobject]@{Type='Utilisateur';Guid='22222222-2222-2222-2222-222222222222';DN='CN=Ana,OU=Lyon,DC=example,DC=invalid';Name='Ana'})})
    Assert-True ($null -eq $other.Record) 'Une fiche dʼun autre GUID nʼest jamais ajoutee.'
    foreach($state in @('Refused','Unavailable','')){Assert-Equal 'NonConfirme' (New-DomeniaCensusGapStoreRow -Guid $guid -Check ([pscustomobject]@{DomainRead=$state})).Status ('Domaine non lu : '+$state)}
    Assert-Equal 'NonConfirme' (New-DomeniaCensusGapStoreRow -Guid '' -Check ([pscustomobject]@{DomainRead='Read'})).Status
    Assert-True ((Get-DomeniaCensusGapSummary -Total 0) -match '^Aucun objet')
    $summary=Get-DomeniaCensusGapSummary -Total 350 -Shown 200
    Assert-True ($summary -match '^350 objet');Assert-True ($summary -match '200 à la fois')
}
Test-Case 'P30' 'Releve : demande validee, couverture prouvee ou declaree incomplete, jamais une sauvegarde' {
    $id='0123456789abcdef0123456789abcdef'
    $coverage=[pscustomobject]@{Status='Complete';At=$script:DS0.AddHours(-1);SourceDn='OU=Lyon,DC=example,DC=invalid';Partial=$false}
    $r=New-DomeniaSnapshotRequest -DomainDn 'DC=example,DC=invalid' -ScopeDn 'OU=Lyon,DC=example,DC=invalid' -Label '  Avant   migration ' -Coverage $coverage -SnapshotId $id -NowUtc $script:DS0
    Assert-Equal 'Capture' $r.Action;Assert-Equal 'Avant migration' $r.Label;Assert-Equal 'Complete' $r.CoverageState;Assert-True ($r.CoverageText -match 'lecture complète')
    Assert-Equal $script:DS0.ToString('o') $r.CapturedUtc
    Assert-Throws {New-DomeniaSnapshotRequest -DomainDn 'DC=example,DC=invalid' -ScopeDn 'OU=Lyon,DC=other,DC=invalid' -SnapshotId $id} 'Perimetre hors domaine refuse.'
    Assert-Throws {New-DomeniaSnapshotRequest -DomainDn 'DC=example,DC=invalid' -ScopeDn '' -SnapshotId 'pas-un-identifiant'} 'Identifiant invalide refuse.'
    Assert-Throws {New-DomeniaSnapshotRequest -DomainDn '' -ScopeDn '' -SnapshotId $id} 'Domaine absent refuse.'
    $partial=New-DomeniaSnapshotRequest -DomainDn 'DC=example,DC=invalid' -ScopeDn '' -Coverage ([pscustomobject]@{Status='Partial';At=$null}) -SnapshotId $id -NowUtc $script:DS0
    Assert-Equal 'Partial' $partial.CoverageState;Assert-Equal 'DC=example,DC=invalid' $partial.ScopeDn;Assert-True ($partial.Label -match '^Relevé du ')
    Assert-Equal 'Missing' (New-DomeniaSnapshotRequest -DomainDn 'DC=example,DC=invalid' -ScopeDn '' -Coverage $null -SnapshotId $id).CoverageState
    Assert-True ((Get-DomeniaSnapshotNotice) -match 'ne permet pas de restaurer')
    $snap=ConvertTo-DomeniaSnapshotRow ([pscustomobject]@{snapshot_id=('a'*32);label='Avant';domain_dn='DC=example,DC=invalid';scope_dn='OU=Postes,OU=Lyon,DC=example,DC=invalid';subtree=1;captured_at=$script:DS0.ToString('o');object_count=12;coverage_state='Complete';coverage_text='x';rows_sha256='ab'})
    Assert-Equal 'Lyon › Postes' $snap.ScopeText;Assert-True $snap.Subtree;Assert-Equal 12 $snap.ObjectCount;Assert-True ($snap.Display -match '^Avant · ')
    Assert-Equal 'Domaine entier' (ConvertTo-DomeniaSnapshotRow ([pscustomobject]@{snapshot_id=('b'*32);label='Tout';scope_dn='DC=example,DC=invalid';subtree=1;captured_at=''})).ScopeText
}
Test-Case 'P30' 'Comparaison : ajouts, disparitions, deplacements et valeurs modifiees, totaux exacts et limites dites' {
    $before=[pscustomobject]@{SnapshotId=('a'*32);Label='Avant';DomainDn='DC=example,DC=invalid';ScopeDn='OU=Lyon,DC=example,DC=invalid';Subtree=$true;CapturedUtc=$script:DS0.AddDays(-7).ToString('o');CoverageState='Complete';CoverageText='Couverture : lecture complète.'}
    $after=[pscustomobject]@{SnapshotId=('b'*32);Label='Après';DomainDn='DC=example,DC=invalid';ScopeDn='OU=Lyon,DC=example,DC=invalid';Subtree=$true;CapturedUtc=$script:DS0.ToString('o');CoverageState='Partial';CoverageText='Couverture : incomplète.'}
    $check=Test-DomeniaSnapshotComparable $before $after
    Assert-True $check.Comparable;Assert-Equal 1 @($check.Warnings).Count
    $other=[pscustomobject]@{SnapshotId=('c'*32);Label='Ailleurs';DomainDn='DC=example,DC=invalid';ScopeDn='OU=Paris,DC=example,DC=invalid';Subtree=$true;CapturedUtc=$script:DS0.ToString('o');CoverageState='Complete'}
    Assert-False (Test-DomeniaSnapshotComparable $before $other).Comparable 'Perimetres differents.'
    Assert-False (Test-DomeniaSnapshotComparable $before $before).Comparable 'Un releve contre lui-meme.'
    Assert-False (Test-DomeniaSnapshotComparable $before $null).Comparable
    Assert-True ((@((Test-DomeniaSnapshotComparable $after $before).Warnings) -join ' ') -match 'plus ancien') 'Ordre inverse signale.'
    $rowA=[pscustomobject]@{object_guid='g1';object_type='Machine';name='PC1';login='PC1$';upn='pc1.example.invalid';display_name='';description='Poste A';extra='';state='Actif';distinguished_name='CN=PC1,OU=Postes,OU=Lyon,DC=example,DC=invalid';when_changed='';last_logon=''}
    $rowB=[pscustomobject]@{object_guid='g1';object_type='Machine';name='PC1';login='PC1$';upn='pc1.example.invalid';display_name='';description='Poste B';extra='';state='Desactive';distinguished_name='CN=PC1,OU=Ateliers,OU=Lyon,DC=example,DC=invalid';when_changed='x';last_logon='y'}
    $result=[pscustomobject]@{Counts=[pscustomobject]@{Added=3;Disappeared=1;Common=10;Differing=1};Added=@([pscustomobject]@{object_guid='g2';name='PC2';distinguished_name='CN=PC2,OU=Lyon,DC=example,DC=invalid'});Disappeared=@([pscustomobject]@{object_guid='g3';name='PC3';distinguished_name='CN=PC3,OU=Lyon,DC=example,DC=invalid'});Pairs=@([pscustomobject]@{Before=$rowA;After=$rowB});Limit=1}
    $report=ConvertTo-DomeniaSnapshotReport -Result $result -Before $before -After $after
    $natures=@($report.Rows|ForEach-Object{$_.Nature})
    Assert-True ($natures -contains 'Ajout');Assert-True ($natures -contains 'Disparition');Assert-True ($natures -contains 'Déplacement')
    Assert-Equal 2 @($report.Rows|Where-Object{$_.Nature -eq 'Valeur modifiée'}).Count 'whenChanged et lastLogon ne sont pas compares.'
    Assert-Equal 1 $report.Moved;Assert-Equal 1 $report.Changed
    Assert-True ($report.Summary -match '3 ajout');Assert-True ($report.Summary -match '9 inchang');Assert-True ($report.Summary -match 'Affichage limité à 1')
    Assert-True ($report.Summary -match 'non concluants');Assert-True ($report.Summary -match 'restaurer')
    Assert-True (@($report.Rows|Where-Object{$_.Nature -eq 'Disparition'})[0].Detail -match 'non prouvé') 'Une disparition nʼest jamais une suppression.'
}

Test-Case 'P60-29' 'Suppression : un indicateur sans lecture des objets supprimés ne constitue pas une preuve' {
    $absence=[pscustomobject]@{Guid='0f6c3a8e-2b8d-4c1e-9a77-5d2b9f1e0a11';LastDn='CN=PC1,DC=example,DC=invalid';ScopeDn='DC=example,DC=invalid'}
    foreach($read in @('NotRequested','Unavailable','Refused','Empty','')){
        $result=Resolve-DomeniaDirectoryAbsence $absence ([pscustomobject]@{DomainRead='Read';DeletedRead=$read;Deleted=$true})
        Assert-True ($result.Status -ne 'Supprime') ('Suppression affirmée sans lecture : '+$read)
    }
    $partial=Resolve-DomeniaDirectoryAbsence $absence ([pscustomobject]@{DomainRead='Unavailable';DeletedRead='Read';Deleted=$true})
    Assert-Equal 'NonConfirme' $partial.Status
}
