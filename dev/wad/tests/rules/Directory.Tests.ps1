# D061-D070 : utilisateurs, groupes et domaine. Donnees fictives uniquement.
$script:D0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
$script:UserProps=@{displayName=@('Jean Dupont');sAMAccountName=@('jdupont');userPrincipalName=@('jdupont@example.invalid');department=@('Support');title=@('Technicien');manager=@('CN=Marie Martin,OU=Lyon,DC=example,DC=invalid');mail=@('jdupont@example.invalid');telephoneNumber=@('0100000000');userAccountControl=@(512);'msDS-User-Account-Control-Computed'=@(0);whenCreated=@([datetime]'2024-05-01');pwdLastSet=@($script:D0.AddDays(-10).ToFileTimeUtc());lastLogonTimestamp=@($script:D0.AddDays(-2).ToFileTimeUtc());objectSid=@('S-1-5-21-1-2-3-1104');nTSecurityDescriptor=@('x');memberOf=@('CN=G1')}
Test-Case 'D061' 'Resume support : identite, service, contact, etat, dates ; pas de grille brute' {
    $facts=@(Get-DomeniaUserSupportSummary $script:UserProps 'EX\lecteur' 'Lecture AD' $script:D0 $script:D0)
    $labels=@($facts|ForEach-Object{$_.Fait})
    foreach($expected in @('Nom affiche','Identifiant','Service','Responsable','Messagerie','Etat du compte','Mot de passe change le')){Assert-True ($labels -contains $expected) ('Absent : '+$expected)}
    Assert-Equal 'Marie Martin' (@($facts|Where-Object{$_.Fait -eq 'Responsable'})[0].Valeur)
    Assert-True ($facts.Count -le 16) 'Resume court'
    Assert-False ($labels -contains 'nTSecurityDescriptor');Assert-False ($labels -contains 'memberOf');Assert-False ($labels -contains 'objectSid')
    Assert-True (@($facts|Where-Object{$_.Fait -match 'approx'})[0].Limite -match '14 jours')
}
Test-Case 'D061' 'Attributs en collection a un element ou scalaires lus de la meme facon' {
    Assert-Equal 'x' (Get-DomeniaAttr @{name=@('x')} 'NAME');Assert-Equal 'x' (Get-DomeniaAttr @{name='x'} 'name');Assert-Equal 'd' (Get-DomeniaAttr @{name=@()} 'name' 'd')
    Assert-Equal 'd' (Get-DomeniaAttr @{} 'name' 'd');Assert-Equal 2 @(Get-DomeniaAttrAll @{member=@('a','b')} 'member').Count;Assert-Equal 1 @(Get-DomeniaAttrAll @{member='a'} 'member').Count
    $bytes=[byte[]](1,2,3);Assert-True ((Get-DomeniaAttr @{objectSid=@(,$bytes)} 'objectSid') -is [byte[]]) 'Un tableau d octets reste entier'
}
Test-Case 'D062' 'Strategie non lisible : inconnue, jamais deduite du domaine' {
    $r=Resolve-DomeniaPasswordPolicy $script:UserProps 'Unreadable' $null @{minPwdLength=@(8);maxPwdAge=@(-36288000000000)} 'EX\l' $script:D0
    Assert-False $r.PolicyKnown
    $policy=@($r.Facts|Where-Object{$_.Fait -eq 'Strategie applicable'})[0];Assert-Equal 'Inconnu' $policy.Etat
    Assert-True (@($r.Facts|Where-Object{$_.Fait -eq 'Longueur minimale'}).Count -eq 0) 'Aucune valeur du domaine n est affichee'
    Assert-Equal 'Inconnu' (@($r.Facts|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat)
}
Test-Case 'D062' 'Strategie fine appliquee et expiration calculee par le controleur' {
    $user=$script:UserProps.Clone();$user['msDS-UserPasswordExpiryTimeComputed']=@($script:D0.AddDays(20).ToFileTimeUtc())
    $pso=@{name=@('PSO-Support');'msDS-MinimumPasswordLength'=@(14);'msDS-MaximumPasswordAge'=@(-25920000000000);'msDS-PasswordComplexityEnabled'=@('TRUE');'msDS-LockoutThreshold'=@(5);'msDS-LockoutDuration'=@(-18000000000)}
    $r=Resolve-DomeniaPasswordPolicy $user 'Applies' $pso $null 'EX\l' $script:D0
    Assert-True $r.PolicyKnown;Assert-True ($r.PolicySource -match 'PSO-Support')
    Assert-Equal '14 caracteres' (@($r.Facts|Where-Object{$_.Fait -eq 'Longueur minimale'})[0].Valeur);Assert-Equal '30 jours' (@($r.Facts|Where-Object{$_.Fait -eq 'Duree de validite'})[0].Valeur)
    Assert-True ((@($r.Facts|Where-Object{$_.Fait -eq 'Verrouillage'})[0].Valeur) -match '5 echecs, duree 30 min')
    Assert-Equal $script:D0.AddDays(20) $r.ExpiresUtc;Assert-Equal 'Constate' (@($r.Facts|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat)
}
Test-Case 'D062' 'Strategie du domaine : expiration estimee et signalee comme telle ; option sans expiration respectee' {
    $domain=@{minPwdLength=@(8);maxPwdAge=@(-36288000000000);pwdProperties=@(1);lockoutThreshold=@(0);pwdHistoryLength=@(24)}
    $r=Resolve-DomeniaPasswordPolicy $script:UserProps 'None' $null $domain 'EX\l' $script:D0
    Assert-Equal 'Estime' (@($r.Facts|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat);Assert-Equal $script:D0.AddDays(32) $r.ExpiresUtc
    Assert-Equal 'Aucun verrouillage' (@($r.Facts|Where-Object{$_.Fait -eq 'Verrouillage'})[0].Valeur)
    $never=$script:UserProps.Clone();$never['userAccountControl']=@(66048)
    Assert-True ((@((Resolve-DomeniaPasswordPolicy $never 'None' $null $domain).Facts|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Valeur) -match 'jamais')
    Assert-True ($null -eq (ConvertFrom-DomeniaAdInterval 0));Assert-True ($null -eq (ConvertFrom-DomeniaAdInterval ([long]::MinValue)));Assert-Equal 42 ([int](ConvertFrom-DomeniaAdInterval -36288000000000).TotalDays)
}
Test-Case 'D063' 'Un lockoutTime non nul seul ne prouve pas un verrouillage actuel' {
    $u=@{userAccountControl=@(512);lockoutTime=@($script:D0.AddHours(-3).ToFileTimeUtc());badPwdCount=@(2)}
    $d=Get-DomeniaLockoutDiagnosis $u 'dc1' $null 'NotRequested' ([TimeSpan]::Zero) $false 'EX\l' $script:D0
    Assert-Equal 'Inconnu' $d.Verdict
    $locked=@{userAccountControl=@(512);'msDS-User-Account-Control-Computed'=@(16);lockoutTime=@($script:D0.AddMinutes(-3).ToFileTimeUtc())}
    Assert-Equal 'Verrouille' (Get-DomeniaLockoutDiagnosis $locked 'dc1').Verdict
    $free=@{userAccountControl=@(512);'msDS-User-Account-Control-Computed'=@(0);lockoutTime=@($script:D0.AddDays(-3).ToFileTimeUtc())}
    Assert-Equal 'NonVerrouille' (Get-DomeniaLockoutDiagnosis $free 'dc1').Verdict
    Assert-True (@($d.Facts|Where-Object{$_.Fait -eq 'Echecs de mot de passe'})[0].Limite -match 'pas replique')
}
Test-Case 'D063' 'Aucune lecture de journal sans demande ; refus de lecture sans verdict ; recidive comptee' {
    $u=@{userAccountControl=@(512);'msDS-User-Account-Control-Computed'=@(0)}
    Assert-True (@((Get-DomeniaLockoutDiagnosis $u 'dc1').Facts|Where-Object{$_.Fait -eq 'Verrouillages journalises'})[0].Valeur -eq 'Non demandes')
    $refused=@((Get-DomeniaLockoutDiagnosis $u 'dc1' $null 'Refused').Facts|Where-Object{$_.Fait -eq 'Verrouillages journalises'})[0]
    Assert-Equal 'Refuse' $refused.Etat;Assert-True ($refused.Limite -match 'ne signifie pas')
    $events=@([pscustomobject]@{TimeUtc=$script:D0;CallerComputer='PC-1'},[pscustomobject]@{TimeUtc=$script:D0;CallerComputer='PC-1'},[pscustomobject]@{TimeUtc=$script:D0;CallerComputer='SRV-2'})
    $d=Get-DomeniaLockoutDiagnosis $u 'dc1' $events 'Read';Assert-Equal 3 $d.Recurrence;Assert-Equal 'PC-1 (2)' $d.Origins[0]
}
Test-Case 'P47' 'Verrouillages 4740 rapproches des refus de Domenia du meme compte, sans conclusion' {
    $u=@{userAccountControl=@(512);'msDS-User-Account-Control-Computed'=@(16)}
    $t0=[datetime]::new(2026,10,14,8,0,0,[DateTimeKind]::Utc)
    $events=@([pscustomobject]@{TimeUtc=$t0.ToString('o');CallerComputer='PC-7';Dc='dc1'},[pscustomobject]@{TimeUtc=$t0.AddHours(2).ToString('o');CallerComputer='';Dc='dc1'})
    $failures=@([pscustomobject]@{Key='jdupont@example.invalid';Kind='LogonFailure';AtUtc=$t0.AddSeconds(-40)},[pscustomobject]@{Key='autre@example.invalid';Kind='LogonFailure';AtUtc=$t0.AddHours(2).AddSeconds(-10)})
    $line=Get-DomeniaLockoutTimeline -Events $events -DomeniaFailures $failures -AccountKeys @('JDUPONT@example.invalid')
    Assert-Equal 1 $line.NearCount;Assert-Equal 1 $line.FailureCount
    Assert-True ($line.Rows[0].TimeUtc -gt $line.Rows[1].TimeUtc) 'Ordre antichronologique attendu.'
    Assert-True (-not $line.Rows[0].DomeniaProche -and $line.Rows[0].Poste -eq 'non renseigné') 'Refus d un autre compte rapproche a tort.'
    Assert-True ($line.Rows[1].DomeniaProche -and $line.Rows[1].Domenia -match '40 s avant') ('Refus du compte non rapproche : '+$line.Rows[1].Domenia)
    $late=Get-DomeniaLockoutTimeline -Events @($events[0]) -DomeniaFailures @([pscustomobject]@{Key='jdupont@example.invalid';Kind='LogonFailure';AtUtc=$t0.AddMinutes(5)}) -AccountKeys @('jdupont@example.invalid')
    Assert-Equal 0 $late.NearCount
    $amb=Get-DomeniaLockoutTimeline -Events @($events[0]) -DomeniaFailures @([pscustomobject]@{Key='';Kind='LogonFailure';AtUtc=$t0.AddSeconds(-3)}) -AccountKeys @('jdupont@example.invalid')
    Assert-True ($amb.Rows[0].Domenia -match 'non attribu') 'Refus non attribue non signale.'
    $d=Get-DomeniaLockoutDiagnosis -User $u -Dc 'dc1' -Events $events -EventReadState 'Read' -DomeniaFailures $failures -AccountKeys @('jdupont@example.invalid')
    $fact=@($d.Facts|Where-Object{$_.Fait -eq 'Refus de Domenia avant un verrouillage'})
    Assert-True ($fact.Count -eq 1 -and $fact[0].Valeur -eq '1 sur 2' -and $fact[0].Hypothese) 'Fait de rapprochement absent ou affirme comme preuve.'
    Assert-Equal 0 @((Get-DomeniaLockoutDiagnosis $u 'dc1' $events 'Read').Facts|Where-Object{$_.Fait -eq 'Refus de Domenia avant un verrouillage'}).Count
}
Test-Case 'D064' 'Chemin direct, imbrique, cycle et limites' {
    $edges=@{'CN=U'=@('CN=G1');'CN=G1'=@('CN=G2','CN=G3');'CN=G2'=@('CN=G1','CN=Cible');'CN=G3'=@()}
    $p=Find-DomeniaMembershipPath $edges 'CN=U' 'CN=Cible';Assert-True $p.Found;Assert-Equal 4 $p.Path.Count;Assert-Equal 'CN=G2' $p.Path[2];Assert-False $p.Direct
    Assert-True (Find-DomeniaMembershipPath $edges 'cn=u' 'CN=G1').Direct
    $none=Find-DomeniaMembershipPath $edges 'CN=U' 'CN=Absent';Assert-False $none.Found;Assert-False $none.Truncated 'Le cycle G1-G2 ne boucle pas'
    $cut=Find-DomeniaMembershipPath $edges 'CN=U' 'CN=Cible' -MaxDepth 1;Assert-False $cut.Found;Assert-True $cut.Truncated
}
Test-Case 'D064' 'Un grand groupe tronque ne conduit pas a annoncer une absence' {
    $r=Resolve-DomeniaMembershipAnswer $null ([pscustomobject]@{Found=$false;Truncated=$true})
    Assert-True ($null -eq $r.Member);Assert-False $r.Certain;Assert-True ($r.Text -match 'Indetermine')
    Assert-True (Resolve-DomeniaMembershipAnswer $true).Certain;Assert-False (Resolve-DomeniaMembershipAnswer $false).Member
    Assert-True ($null -eq (Resolve-DomeniaMembershipAnswer $null $null $true).Member)
    Assert-Equal 'S-1-5-21-1-2-3-513' (Get-DomeniaPrimaryGroupSid 'S-1-5-21-1-2-3-1104' '513')
}
Test-Case 'D065' 'Comparaison en lecture, groupes a privileges signales, rien d appliquable' {
    $l=[pscustomobject]@{Attributes=@{department='Support';title='Tech'};Groups=@([pscustomobject]@{Name='GG-Support';Dn='CN=GG-Support'},[pscustomobject]@{Name='Admins du domaine';Dn='CN=DA';Sid='S-1-5-21-1-2-3-512'})}
    $r=[pscustomobject]@{Attributes=@{department='Support';title='Chef'};Groups=@([pscustomobject]@{Name='GG-Support';Dn='CN=GG-Support'})}
    $c=Compare-DomeniaUserAccess $l $r
    Assert-False $c.CanApply;Assert-Equal 1 $c.PrivilegedDifferences
    $da=@($c.Rows|Where-Object{$_.Element -eq 'Admins du domaine'})[0];Assert-True $da.Privilegie;Assert-True ($da.Alerte.Length -gt 10);Assert-False $da.Identique
    Assert-True (@($c.Rows|Where-Object{$_.Element -eq 'GG-Support'})[0].Identique);Assert-False (@($c.Rows|Where-Object{$_.Element -eq 'Fonction'})[0].Identique)
    Assert-True (Test-DomeniaPrivilegedGroup ([pscustomobject]@{Name='x';Sid='S-1-5-32-544'}));Assert-False (Test-DomeniaPrivilegedGroup ([pscustomobject]@{Name='GG-Support';Sid='S-1-5-21-1-2-3-2001'}))
}
Test-Case 'D066' 'Seuls les ajouts et retraits choisis ; jamais la liste complete' {
    $d=New-DomeniaGroupDelta @('CN=G1','CN=G2','CN=G3') @('CN=G4') @('CN=G2') 'CN=U'
    Assert-Equal 2 $d.Operations.Count;Assert-False $d.WritesFullList
    Assert-Equal 'Add' $d.Operations[0].Action;Assert-Equal 'CN=G4' $d.Operations[0].GroupDn;Assert-Equal 'Remove' $d.Operations[1].Action
    Assert-True (@($d.Operations|Where-Object{$_.GroupDn -in @('CN=G1','CN=G3')}).Count -eq 0) 'Les groupes non choisis ne sont pas touches'
    Assert-Equal 0 (New-DomeniaGroupDelta @('CN=G1') @('CN=G9') @('CN=G9')).Operations.Count
}
Test-Case 'D066' 'Postconditions verifiees par relecture, groupe modifie ailleurs non ecrase' {
    $d=New-DomeniaGroupDelta @('CN=G1','CN=G2') @('CN=G4') @('CN=G2') 'CN=U'
    Assert-Equal 'Verifie' (Test-DomeniaGroupDeltaPostcondition $d @{'CN=G4'=$true;'cn=g2'=$false}).Overall
    Assert-Equal 'Partiel' (Test-DomeniaGroupDeltaPostcondition $d @{'CN=G4'=$true;'CN=G2'=$true}).Overall
    Assert-Equal 'A verifier' (Test-DomeniaGroupDeltaPostcondition $d @{'CN=G4'=$true}).Overall
}
Test-Case 'D067' 'ACE observee distincte d une capacite verifiee ; origine et portee visibles' {
    $rows=@(ConvertTo-DomeniaAceView @([pscustomobject]@{IdentityReference='EX\GG-Support';ActiveDirectoryRights='WriteProperty';AccessControlType='Allow';IsInherited=$true;InheritanceType='Descendents';ObjectType='bf967a0a-0de6-11d0-a285-00aa003049e2'},[pscustomobject]@{IdentityReference='EX\adm';ActiveDirectoryRights='GenericAll';AccessControlType='Deny';IsInherited=$false;InheritanceType='None'}) @{'bf967a0a-0de6-11d0-a285-00aa003049e2'='pwdLastSet'})
    Assert-Equal 2 $rows.Count;Assert-Equal 'ACE observee' $rows[0].Statut;Assert-True ($rows[0].Origine -match 'Heritee');Assert-Equal 'pwdLastSet' $rows[0].Cible
    Assert-Equal 'Refus' $rows[1].Type;Assert-True ($rows[1].Origine -match 'Posee');Assert-True ($rows[0].Limite -match 'droit effectif')
}
Test-Case 'D068' 'Etapes sensibles confirmees une a une ; ni suppression ni migration' {
    $p=New-DomeniaLifecyclePlan Suspension ([pscustomobject]@{Name='Jean'}) ([pscustomobject]@{TargetOu='OU=Suspendus,DC=example,DC=invalid';Attributes=@{description='Suspendu'}})
    Assert-False $p.Deletes;Assert-False $p.Migrates;Assert-Equal 3 $p.Steps.Count
    Assert-True (@($p.Steps|Where-Object{$_.Sensitive}).Count -eq 3);Assert-True (@($p.Steps|Where-Object{$_.Operation -match 'Delete|Migrate'}).Count -eq 0)
    Assert-Equal 1 (Get-DomeniaLifecycleNextStep $p).Id
}
Test-Case 'D068' 'Une issue incertaine bloque la suite et n est pas rejouee' {
    $p=New-DomeniaLifecyclePlan ChangementService ([pscustomobject]@{Name='Jean'}) ([pscustomobject]@{AddGroups=@('CN=G1');TargetOu='OU=X'})
    [void](Set-DomeniaLifecycleStep $p 1 Verified);Assert-Equal 2 (Get-DomeniaLifecycleNextStep $p).Id
    [void](Set-DomeniaLifecycleStep $p 2 Uncertain);Assert-True $p.Blocked;Assert-True ($null -eq (Get-DomeniaLifecycleNextStep $p))
    [void](Set-DomeniaLifecycleStep $p 2 Resolved 'verifie a la main');Assert-False $p.Blocked;Assert-Equal 3 (Get-DomeniaLifecycleNextStep $p).Id 'L etape 2 n est pas reproposee'
}
Test-Case 'D069' 'Doublons et dates anciennes : a revoir, jamais supprimable' {
    $objects=@([pscustomobject]@{Name='A';Type='Utilisateur';Mail='x@example.invalid';Upn='a@example.invalid';Description='d';LastLogonUtc=$script:D0.AddDays(-400)},
               [pscustomobject]@{Name='B';Type='Utilisateur';Mail='X@example.invalid';Upn='b@example.invalid';Description='d';ManagerDn='CN=Parti,DC=example,DC=invalid';LastLogonUtc=$script:D0.AddDays(-2)})
    $f=@(Find-DomeniaDirectoryInconsistencies $objects @('CN=A,DC=example,DC=invalid') 180 $script:D0)
    Assert-True (@($f|Where-Object{$_.Categorie -eq 'Valeur en double'}).Count -eq 1);Assert-True (@($f|Where-Object{$_.Categorie -eq 'Objet peu utilise'}).Count -eq 1)
    Assert-True (@($f|Where-Object{$_.Categorie -eq 'Responsable a verifier'}).Count -eq 1)
    Assert-True (@($f|Where-Object{$_.Conclusion -ne 'A revoir'}).Count -eq 0);Assert-False (($f|ConvertTo-Json -Depth 3) -match '"Conclusion":\s*"Supprim')
    Assert-True (@(Find-DomeniaDirectoryInconsistencies $objects @() 180 $script:D0 $true)[0].Limite -match 'partiellement')
}
Test-Case 'D070' 'Differences datees par controleur, USN non compares, controleur injoignable non compte comme difference' {
    $xml='<DS_REPL_ATTR_META_DATA><pszAttributeName>description</pszAttributeName><dwVersion>3</dwVersion><ftimeLastOriginatingChange>2025-12-30T09:00:00Z</ftimeLastOriginatingChange><usnOriginatingChange>500</usnOriginatingChange><usnLocalChange>900</usnLocalChange><pszLastOriginatingDsaDN>CN=NTDS Settings,CN=DC1,CN=Servers,CN=Site,CN=Sites,CN=Configuration,DC=example,DC=invalid</pszLastOriginatingDsaDN></DS_REPL_ATTR_META_DATA>'
    $meta=@(ConvertFrom-DomeniaReplMetadata @($xml,'pas du xml'));Assert-Equal 1 $meta.Count;Assert-Equal 'DC1' $meta[0].OriginatingDc;Assert-Equal '3' $meta[0].Version
    $readings=@([pscustomobject]@{Dc='dc1';Reachable=$true;Attributes=@{description=@('Nouveau');title=@('T')};Metadata=$meta},
                [pscustomobject]@{Dc='dc2';Reachable=$true;Attributes=@{description=@('Ancien');title=@('T')};Metadata=@()},
                [pscustomobject]@{Dc='dc3';Reachable=$false;Error='injoignable'})
    $c=Compare-DomeniaDcReadings $readings @('description','title')
    Assert-Equal 1 $c.Differences;Assert-True $c.Comparable;Assert-Equal 1 $c.NotRead.Count
    $row=@($c.Rows|Where-Object{$_.Attribut -eq 'description'})[0];Assert-True ($row.ParControleur['dc1'] -match 'origine DC1');Assert-Equal 2 $row.Lus
    Assert-True ($c.Note -match 'USN sont locaux')
    Assert-False (Compare-DomeniaDcReadings @($readings[0]) @('description')).Comparable
}
Test-Case 'MO-04' 'Totaux du domaine lus dans la copie locale, avec leur date, sans denombrer l annuaire' {
    $now=[datetime]::SpecifyKind([datetime]'2026-10-14T12:00:00',[DateTimeKind]::Utc)
    $types=@([pscustomobject]@{t='Utilisateur';s='Actif';n=120},[pscustomobject]@{t='Utilisateur';s='Desactive';n=3},[pscustomobject]@{t='Machine';s='Actif';n=1},[pscustomobject]@{t='Groupe';s='Inconnu';n=40},[pscustomobject]@{t='OU';s='Inconnu';n=0})
    $r=Get-DomeniaLocalTotalsSummary -Types $types -LastSyncUtc '2026-10-14T06:15:00.0000000Z' -NowUtc $now
    $when=Format-DomeniaRelationWhen '2026-10-14T06:15:00.0000000Z' $now
    Assert-True $r.Known;Assert-Equal 164 $r.Total
    Assert-Equal ('Totaux de la copie locale au '+$when+' : 123 utilisateurs (dont 3 désactivés) · 1 poste · 40 groupes.') $r.Text
    $big=Get-DomeniaLocalTotalsSummary -Types @([pscustomobject]@{t='Machine';s='Actif';n=1234}) -LastSyncUtc '2026-10-14T06:15:00Z' -NowUtc $now
    Assert-True ($big.Text -match ' : 1\D234 postes\.$') ('Separateur de milliers : '+$big.Text)
    $unknown=Get-DomeniaLocalTotalsSummary -Types @([pscustomobject]@{t='Machine';s='Actif';n=2}) -LastSyncUtc ''
    Assert-False $unknown.Known;Assert-True ($unknown.Text.StartsWith('Totaux de la copie locale, date de synchronisation inconnue : 2 postes'))
    $empty=Get-DomeniaLocalTotalsSummary -Types @() -LastSyncUtc ''
    Assert-False $empty.Known;Assert-Equal 0 $empty.Total;Assert-True ($empty.Text.Contains('aucun dénombrement'))
}
Test-Case 'UI-06' 'Appartenances lisibles : nom, type, OU, DN conserve' {
    Assert-Equal 'Dupont, Jean' (Get-DomeniaDnDisplayName 'CN=Dupont\, Jean,OU=RH,DC=example,DC=invalid')
    Assert-Equal 'Équipe' (Get-DomeniaDnDisplayName 'CN=\C3\89quipe,DC=example,DC=invalid')
    $groups=ConvertTo-DomeniaMembershipRows @('CN=GG-Compta,OU=Groupes,OU=Lyon,DC=example,DC=invalid','cn=gg-compta,ou=groupes,ou=lyon,dc=example,dc=invalid','') MemberOf
    Assert-Equal 1 @($groups).Count 'Doublon ecarte sans tenir compte de la casse'
    Assert-Equal 'GG-Compta' $groups[0].Name;Assert-Equal 'Groupe' $groups[0].Type;Assert-Equal 'example.invalid / Lyon / Groupes' $groups[0].Ou
    Assert-Equal 'CN=GG-Compta,OU=Groupes,OU=Lyon,DC=example,DC=invalid' $groups[0].Dn;Assert-Equal 'Directe' $groups[0].Membership
    $types=@{'CN=PC-01,OU=Postes,DC=example,DC=invalid'='Machine'}
    $members=ConvertTo-DomeniaMembershipRows @('cn=pc-01,ou=postes,dc=example,dc=invalid','CN=Inconnu,OU=Postes,DC=example,DC=invalid') Members $types
    Assert-Equal 'Machine' $members[0].Type 'Type lu dans la copie locale'
    Assert-Equal 'Non lu' $members[1].Type 'Type jamais devine depuis le nom'
    Assert-Equal 2 (ConvertTo-DomeniaMembershipRows @(1..5|ForEach-Object{'CN=M'+$_+',DC=x'}) Members $null 2).Count 'Borne du nombre de lignes'
    # The rows come back as one array: a caller iterates the assigned value (an @() around the call would nest it).
    $none=ConvertTo-DomeniaMembershipRows @() MemberOf
    Assert-Equal 0 $none.Count 'Aucun DN : aucune ligne'
    $iterated=0;foreach($row in $members){$iterated++};Assert-Equal 2 $iterated 'Une ligne par DN a lʼitération'
    Assert-True (Test-DomeniaMembershipRow $groups[0] 'compta lyon');Assert-False (Test-DomeniaMembershipRow $groups[0] 'compta paris')
    Assert-True (Test-DomeniaMembershipRow $groups[0] '  ') 'Filtre vide'
}
Test-Case 'UI-06' 'Groupes imbriques et « Pourquoi membre ? » depuis les appartenances lues' {
    $u='CN=Jean Dupont,OU=RH,DC=example,DC=invalid';$g1='CN=GG-Lyon,DC=example,DC=invalid';$g2='CN=GG-RH,DC=example,DC=invalid';$g3='CN=GG-Compta,DC=example,DC=invalid';$g4='CN=GU-Tous,DC=example,DC=invalid'
    $json=[pscustomobject]@{}
    foreach($pair in @(@($u,@($g1,$g2)),@($g1,@($g3)),@($g2,@($g3)),@($g3,$g4),@($g4,@($g1)))){Add-Member -InputObject $json -NotePropertyName $pair[0] -NotePropertyValue $pair[1]}
    $edges=ConvertTo-DomeniaMembershipEdges $json
    Assert-Equal 1 @($edges[$g3]).Count 'Un parent unique reste un DN';Assert-Equal $g4 @($edges[$g3])[0]
    Assert-Equal 2 @((ConvertTo-DomeniaMembershipEdges @{$u=@($g1,$g2)})[$u]).Count 'Dictionnaire accepte'
    $nested=Get-DomeniaNestedMembershipRows $edges $u
    Assert-Equal 2 $nested.Count 'Seuls les groupes atteints par imbrication, cycle G4-G1 sans boucle'
    Assert-Equal 'GG-Compta' $nested[0].Name;Assert-Equal 2 $nested[0].Depth;Assert-Equal 'GG-Lyon' $nested[0].Via;Assert-Equal 'Imbriquée' $nested[0].Membership
    Assert-Equal 'GU-Tous' $nested[1].Name;Assert-Equal 3 $nested[1].Depth
    $direct=Get-DomeniaMembershipWhy -ObjectDn $u -GroupDn $g1 -Direct $true
    Assert-True $direct.Member;Assert-False $direct.NeedsRead;Assert-True ($direct.Text.Contains('membre direct de « GG-Lyon »'))
    Assert-True (Get-DomeniaMembershipWhy -ObjectDn $u -GroupDn $g4).NeedsRead 'Lecture au clic seulement'
    $path=Get-DomeniaMembershipWhy -Edges $edges -ObjectDn $u -GroupDn $g4 -Read $true -ServerAnswer $true
    Assert-True $path.Member;Assert-Equal 'Jean Dupont,GG-Lyon,GG-Compta,GU-Tous' ($path.Path -join ',')
    Assert-True ($path.Text.Contains('Jean Dupont → GG-Lyon → GG-Compta → GU-Tous (3 niveaux)') -and $path.Text.Contains('Le contrôleur confirme')) $path.Text
    $cut=Get-DomeniaMembershipWhy -Edges @{$u=@($g1)} -ObjectDn $u -GroupDn $g4 -Read $true -Truncated $true
    Assert-True ($null -eq $cut.Member);Assert-True ($cut.Text.Contains('indéterminée')) 'Une lecture bornee ne conclut pas a une absence'
    $no=Get-DomeniaMembershipWhy -Edges @{$u=@($g1)} -ObjectDn $u -GroupDn $g4 -Read $true -ServerAnswer $false
    Assert-False $no.Member;Assert-True ($no.Text.Contains('nʼest pas membre'))
    $unknown=Get-DomeniaMembershipWhy -Edges @{$u=@($g1)} -ObjectDn $u -GroupDn $g4 -Read $true
    Assert-False $unknown.Known;Assert-True ($unknown.Text.Contains('groupe principal'))
}
Test-Case 'UI-06' 'Reponse GroupPathRead partagee avec l audit AD : aretes de l objet et des groupes lus' {
    $u='CN=Jean Dupont,OU=RH,DC=example,DC=invalid';$g1='CN=GG-Lyon,DC=example,DC=invalid';$g2='CN=GG-RH,DC=example,DC=invalid';$g3='CN=GG-Compta,DC=example,DC=invalid'
    # Answer of the pinned body (point 103 shape): StartParents for the object, Parents for each group read.
    $read=[pscustomobject]@{Dn=$u;StartParents=@($g1,$g2);Nodes=@([pscustomobject]@{Dn=$g1;Parents=@($g3)},[pscustomobject]@{Dn=$g2;Parents=$g3},[pscustomobject]@{Dn=$g3;Parents=@()});Unread=@()}
    $edges=ConvertTo-DomeniaGroupPathEdges $read
    Assert-Equal 4 $edges.Count 'Objet et trois groupes lus'
    Assert-Equal 2 @($edges[$u]).Count;Assert-Equal $g3 @($edges[$g2])[0] 'Un parent unique reste un DN'
    Assert-Equal 0 @($edges[$g3]).Count 'Groupe lu sans parent'
    $nested=Get-DomeniaNestedMembershipRows $edges $u
    Assert-Equal 1 $nested.Count;Assert-Equal 'GG-Compta' $nested[0].Name 'Casse des DN conservee pour les noms'
    # A group that could not be read has no edge: its parents stay unknown, never an empty list.
    $partial=ConvertTo-DomeniaGroupPathEdges ([pscustomobject]@{Dn=$u;StartParents=@($g1);Nodes=@();Unread=@([pscustomobject]@{Dn=$g1;Reason='Introuvable ou non lisible avec ce compte'})})
    Assert-Equal 1 $partial.Count;Assert-False $partial.ContainsKey($g1)
    Assert-Equal 0 (ConvertTo-DomeniaGroupPathEdges $null).Count 'Aucune reponse : aucune arete'
}
