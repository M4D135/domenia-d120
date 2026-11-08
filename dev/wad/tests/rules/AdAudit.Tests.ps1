# Points 102 a 109 (audit AD) et 107 (relation poste / utilisateur) : regles pures sur des lectures fictives.
# Aucune lecture AD, CIM, DNS ni disque. Domaine example.invalid, SID et GUID inventes.
. (Join-Path $modules 'Domenia-AdAudit.Model.ps1')
$script:AaNow=[datetime]::SpecifyKind([datetime]'2026-10-15T10:00:00',[DateTimeKind]::Utc)
$script:AaDomain='DC=example,DC=invalid'
$script:AaSid='S-1-5-21-1000-2000-3000'

Test-Case '102' 'Strategie fine lue : elle seule s applique, avec sa priorite' {
    $user=@{userAccountControl='512';'msDS-User-Account-Control-Computed'='0';pwdLastSet=$script:AaNow.AddDays(-10).ToFileTimeUtc();'msDS-UserPasswordExpiryTimeComputed'=$script:AaNow.AddDays(20).ToFileTimeUtc()}
    $pso=@{name='PSO-Support';'msDS-PasswordSettingsPrecedence'='10';'msDS-MinimumPasswordLength'='14';'msDS-MaximumPasswordAge'=-25920000000000L;'msDS-PasswordComplexityEnabled'='True';'msDS-LockoutThreshold'='5';'msDS-LockoutDuration'=-18000000000L}
    $read=[pscustomobject]@{Dn=('CN=Jean,OU=Support,'+$script:AaDomain);User=$user;ResultantPso=('CN=PSO-Support,CN=Password Settings Container,CN=System,'+$script:AaDomain);Pso=$pso;PsoVisibleCount=1;Domain=@{minPwdLength='8';maxPwdAge=-36288000000000L}}
    $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -Reader 'EX\lecteur' -NowUtc $script:AaNow
    Assert-Equal 'Applies' $view.State;Assert-True $view.PolicyKnown
    Assert-True ($view.Summary -match 'PSO-Support')
    $rows=@(ConvertTo-DomeniaAdAuditFactRows $view.Facts)
    Assert-Equal '14 caractères' (@($rows|Where-Object{$_.Fait -eq 'Longueur minimale'})[0].Valeur)
    Assert-Equal '30 jours' (@($rows|Where-Object{$_.Fait -eq 'Durée de validité'})[0].Valeur)
    Assert-Equal '10' (@($rows|Where-Object{$_.Fait -eq 'Priorité de la stratégie fine'})[0].Valeur)
    Assert-Equal 'Constaté' (@($rows|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat)
    Assert-Equal 0 @($rows|Where-Object{$_.Fait -like 'Domaine (référence)*'}).Count 'La strategie du domaine n est pas montree quand une strategie fine s applique'
    Assert-Equal 'Stratégie applicable' $rows[0].Fait
}
Test-Case '102' 'Aucune strategie fine visible : strategie inconnue, domaine montre en reference seulement' {
    $read=[pscustomobject]@{Dn='CN=Jean';User=@{userAccountControl='512';pwdLastSet=$script:AaNow.AddDays(-10).ToFileTimeUtc()};ResultantPso='';Pso=$null;PsoVisibleCount=0;Domain=@{minPwdLength='8';maxPwdAge=-36288000000000L;pwdProperties='1';lockoutThreshold='0'}}
    $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -NowUtc $script:AaNow
    Assert-Equal 'Unreadable' $view.State;Assert-False $view.PolicyKnown
    $rows=@(ConvertTo-DomeniaAdAuditFactRows $view.Facts)
    Assert-Equal 'Inconnu' (@($rows|Where-Object{$_.Fait -eq 'Stratégie applicable'})[0].Etat)
    Assert-True ((@($rows|Where-Object{$_.Fait -eq 'Pourquoi inconnue'})[0].Valeur) -match 'pas présumée')
    Assert-Equal 0 @($rows|Where-Object{$_.Fait -eq 'Longueur minimale'}).Count 'Aucune valeur du domaine presentee comme applicable'
    $reference=@($rows|Where-Object{$_.Fait -eq 'Domaine (référence) · Longueur minimale'})
    Assert-Equal 1 $reference.Count;Assert-Equal 'Inconnu' $reference[0].Etat;Assert-True ($reference[0].Limite -match 'Référence seulement')
    Assert-Equal 'Inconnu' (@($rows|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat)
}
Test-Case '102' 'Strategies fines visibles et aucune ne vise le compte : strategie du domaine, expiration estimee' {
    $read=[pscustomobject]@{Dn='CN=Jean';User=@{userAccountControl='512';pwdLastSet=$script:AaNow.AddDays(-10).ToFileTimeUtc()};ResultantPso='';Pso=$null;PsoVisibleCount=2;Domain=@{minPwdLength='8';maxPwdAge=-36288000000000L;pwdProperties='1';lockoutThreshold='0'}}
    $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -NowUtc $script:AaNow
    Assert-Equal 'None' $view.State;Assert-True $view.PolicyKnown;Assert-True ($view.Summary -match 'domaine sʼapplique')
    $rows=@(ConvertTo-DomeniaAdAuditFactRows $view.Facts)
    Assert-Equal '8 caractères' (@($rows|Where-Object{$_.Fait -eq 'Longueur minimale'})[0].Valeur)
    Assert-Equal 'Estimé' (@($rows|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat)
    Assert-Equal 0 @($rows|Where-Object{$_.Fait -like 'Domaine (référence)*'}).Count
}
Test-Case '102' 'msDS-ResultantPSO non lu : strategie inconnue meme si des strategies fines sont visibles' {
    # The worker fell back to the plain attributes: an empty ResultantPso is "not read", never "none applies".
    $read=[pscustomobject]@{Dn='CN=Jean';User=@{userAccountControl='512';pwdLastSet=$script:AaNow.AddDays(-10).ToFileTimeUtc()};ResultantPso='';ResultantError='Attribut construit refusé.';Pso=$null;PsoVisibleCount=2;Domain=@{minPwdLength='8';maxPwdAge=-36288000000000L;pwdProperties='1';lockoutThreshold='0'}}
    $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -NowUtc $script:AaNow
    Assert-Equal 'Unreadable' $view.State;Assert-False $view.PolicyKnown
    Assert-True ($view.Summary -match 'msDS-ResultantPSO non lu \(Attribut construit refusé\)') $view.Summary
    Assert-False ($view.Summary -match 'domaine sʼapplique') 'Strategie du domaine presentee comme applicable'
    $rows=@(ConvertTo-DomeniaAdAuditFactRows $view.Facts)
    Assert-Equal 0 @($rows|Where-Object{$_.Fait -eq 'Longueur minimale'}).Count 'Valeur du domaine presentee comme applicable'
    Assert-Equal 1 @($rows|Where-Object{$_.Fait -eq 'Domaine (référence) · Longueur minimale'}).Count 'Domaine montre en reference seulement'
    Assert-Equal 'Inconnu' (@($rows|Where-Object{$_.Fait -eq 'Expiration du mot de passe'})[0].Etat)
    Assert-True ($null -eq $view.ExpiresUtc) 'Expiration estimee a partir du domaine'
}
Test-Case '102' 'Strategie fine nommee mais illisible : inconnue, nommee, jamais remplacee par le domaine' {
    $read=[pscustomobject]@{Dn='CN=Jean';User=@{userAccountControl='512'};ResultantPso=('CN=PSO-Direction,CN=Password Settings Container,CN=System,'+$script:AaDomain);Pso=$null;PsoVisibleCount=0;Domain=@{minPwdLength='8'}}
    $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -NowUtc $script:AaNow
    Assert-Equal 'Unreadable' $view.State;Assert-True ($view.Summary -match 'PSO-Direction')
    Assert-Equal 0 @(@(ConvertTo-DomeniaAdAuditFactRows $view.Facts)|Where-Object{$_.Fait -eq 'Longueur minimale'}).Count
    Assert-Equal 'NotRead' (ConvertTo-DomeniaPasswordPolicyView -Read $null).State
}
Test-Case '102' 'Textes historiques affiches avec accents et apostrophes, sans changer leur sens' {
    Assert-Equal 'Stratégie non lisible avec ce compte : aucune valeur nʼest déduite de la stratégie du domaine.' (Format-DomeniaLegacyFactText 'Strategie non lisible avec ce compte : aucune valeur n est deduite de la strategie du domaine.')
    Assert-Equal 'Nʼexpire jamais (option du compte)' (Format-DomeniaLegacyFactText 'N expire jamais (option du compte)')
    Assert-Equal 'À changer à la prochaine ouverture de session' (Format-DomeniaLegacyFactText 'A changer a la prochaine ouverture de session')
    Assert-Equal 'Calculé à partir de la stratégie lue ; valeur du contrôleur non disponible.' (Format-DomeniaLegacyFactText 'Calcule a partir de la strategie lue ; valeur du controleur non disponible.')
    Assert-Equal 'Mot de passe non requis (PASSWD_NOTREQD) : à revoir.' (Format-DomeniaLegacyFactText 'Mot de passe non requis (PASSWD_NOTREQD) : a revoir.')
    Assert-Equal '5 échecs, durée 30 min' (Format-DomeniaLegacyFactText '5 echecs, duree 30 min')
    Assert-Equal 'Date approximative (réplication différée). Une date ancienne ne suffit pas à déclarer un objet supprimable.' (Format-DomeniaLegacyFactText 'Date approximative (replication differee). Une date ancienne ne suffit pas a declarer un objet supprimable.')
    Assert-Equal 'Texte inconnu inchangé' (Format-DomeniaLegacyFactText 'Texte inconnu inchangé')
    Assert-Equal '' (Format-DomeniaLegacyFactText $null)
}

# ---------------------------------------------------------------- 103
function New-AaGroupRead {
    param([bool]$Truncated=$false)
    $u='CN=Jean,OU=Support,'+$script:AaDomain
    return [pscustomobject]@{
        Dn=$u;StartParents=@(('CN=G1,'+$script:AaDomain),('CN=G3,'+$script:AaDomain));StartComplete=$true;StartNote=''
        Nodes=@(
            [pscustomobject]@{Dn=('CN=G1,'+$script:AaDomain);Name='G1';Sid=($script:AaSid+'-1101');AdminCount='';Parents=@(('CN=G2,'+$script:AaDomain));Partial=$false}
            [pscustomobject]@{Dn=('cn=g2,'+$script:AaDomain);Name='G2';Sid=($script:AaSid+'-1102');AdminCount='';Parents=@(('CN=G1,'+$script:AaDomain),('CN=Cible,'+$script:AaDomain));Partial=$false}
            [pscustomobject]@{Dn=('CN=G3,'+$script:AaDomain);Name='G3';Sid=($script:AaSid+'-1103');AdminCount='';Parents=@('CN=Autre,DC=autre,DC=invalid');Partial=$true}
            [pscustomobject]@{Dn=('CN=Cible,'+$script:AaDomain);Name='Cible';Sid=($script:AaSid+'-512');AdminCount='1';Parents=@();Partial=$false}
        )
        Unread=@([pscustomobject]@{Dn='CN=Autre,DC=autre,DC=invalid';Reason='Autre domaine ou partition : non lu depuis ce contrôleur'})
        Truncated=$Truncated;TruncatedReason=$(if($Truncated){'Temps de lecture épuisé (10 s).'}else{''})
        PrimaryGroup=[pscustomobject]@{Sid=($script:AaSid+'-513');Dn=('CN=Domain Users,CN=Users,'+$script:AaDomain);Name='Domain Users';Error=''}
    }
}
Test-Case '103' 'Cycles trouves une seule fois, sans recursion, quel que soit le point de depart' {
    $edges=@{a=@('b');b=@('a','c');c=@('d');d=@('e');e=@('c');f=@('f')}
    $cycles=Find-DomeniaGroupCycles -Edges $edges
    Assert-Equal 3 $cycles.Count ('Cycles : '+(@($cycles|ForEach-Object{$_ -join '>'}) -join ' | '))
    $keys=@($cycles|ForEach-Object{(@($_[0..($_.Count-2)])|Sort-Object) -join ','}|Sort-Object)
    Assert-Equal 'a,b|c,d,e|f' ($keys -join '|')
    foreach($cycle in $cycles){Assert-Equal $cycle[0] $cycle[$cycle.Count-1] 'Un cycle se referme sur son premier groupe'}
    $chain=@{};for($i=0;$i -lt 3000;$i++){$chain['g'+$i]=@('g'+($i+1))}
    Assert-Equal 0 (Find-DomeniaGroupCycles -Edges $chain).Count 'Chaine longue parcourue sans debordement de pile'
    Assert-Equal 2 (Find-DomeniaGroupCycles -Edges $edges -MaxCycles 2).Count
}
Test-Case '103' 'Appartenances imbriquees : profondeur, chemin, cycle, groupe non lu et groupe principal' {
    $view=ConvertTo-DomeniaNestedGroupView (New-AaGroupRead)
    Assert-Equal 5 @($view.Rows).Count
    $byName=@{};foreach($row in @($view.Rows)){$byName[$row.Groupe]=$row}
    Assert-Equal 1 $byName['G1'].Profondeur;Assert-Equal 'Appartenance directe' $byName['G1'].Via
    Assert-Equal 2 $byName['G2'].Profondeur;Assert-Equal 'Par G1' $byName['G2'].Via
    Assert-Equal 3 $byName['Cible'].Profondeur;Assert-Equal 'Oui' $byName['Cible'].Privilegie
    Assert-Equal 'Oui' $byName['G1'].Cycle;Assert-Equal 'Oui' $byName['G2'].Cycle;Assert-Equal '' $byName['G3'].Cycle
    Assert-True ($byName['Autre'].Etat -match '^Non lu : Autre domaine') $byName['Autre'].Etat
    Assert-True ($byName['G3'].Etat -match 'partiellement')
    Assert-Equal 1 $view.CycleCount;Assert-True ($view.Cycles[0] -match 'G1 → G2 → G1|G2 → G1 → G2')
    Assert-True ($view.Summary -match '1 groupe\(s\) non lu') $view.Summary
    Assert-True ($view.Summary -match 'Groupe principal : Domain Users')
    Assert-False $view.Truncated
}
Test-Case '103' 'Groupe audite pris dans une boucle : le cycle qui passe par lui est signale' {
    $g0='CN=G0,'+$script:AaDomain;$g1='CN=G1,'+$script:AaDomain
    $read=[pscustomobject]@{
        Dn=$g0;StartParents=@($g1);StartComplete=$true;StartNote='';Truncated=$false;TruncatedReason='';PrimaryGroup=$null;Unread=@()
        Nodes=@([pscustomobject]@{Dn=$g1;Name='G1';Sid=($script:AaSid+'-1201');AdminCount='';Parents=@($g0);Partial=$false})
    }
    $view=ConvertTo-DomeniaNestedGroupView $read
    Assert-Equal 1 $view.CycleCount ('Cycles : '+($view.Cycles -join ' | '))
    Assert-True ($view.Cycles[0] -match '^(G0 → G1 → G0|G1 → G0 → G1)$') $view.Cycles[0]
    Assert-Equal 1 @($view.Rows).Count 'Le groupe audite nʼest pas une ligne de ses propres appartenances'
    Assert-Equal 'Oui' @($view.Rows)[0].Cycle
    Assert-True ($view.Summary -match '1 cycle\(s\)') $view.Summary
    # A user is never the parent of a group: the same graph started from a user has no cycle through it.
    $user=[pscustomobject]@{Dn=('CN=Jean,'+$script:AaDomain);StartParents=@($g1);StartComplete=$true;StartNote='';Truncated=$false;TruncatedReason='';PrimaryGroup=$null;Unread=@()
        Nodes=@([pscustomobject]@{Dn=$g1;Name='G1';Sid=($script:AaSid+'-1201');AdminCount='';Parents=@();Partial=$false})}
    Assert-Equal 0 (ConvertTo-DomeniaNestedGroupView $user).CycleCount
}
Test-Case '103' 'Pourquoi membre : chemin lu, reponse du controleur, lecture bornee et groupe principal' {
    $view=ConvertTo-DomeniaNestedGroupView (New-AaGroupRead)
    $why=Get-DomeniaGroupMembershipExplanation -View $view -TargetDn ('CN=Cible,'+$script:AaDomain)
    Assert-Equal 'Jean,G1,G2,Cible' ($why.Path -join ',');Assert-True $why.Member;Assert-True ($why.Text -match 'Chemin : Jean → G1 → G2 → Cible')
    Assert-True ((Get-DomeniaGroupMembershipExplanation -View $view -TargetDn ('CN=Cible,'+$script:AaDomain) -ServerAnswer $true).Text -match 'confirmé par le contrôleur')
    $no=Get-DomeniaGroupMembershipExplanation -View $view -TargetDn ('CN=Absent,'+$script:AaDomain) -ServerAnswer $false
    Assert-False $no.Member;Assert-True $no.Certain;Assert-True ($no.Text -match 'Non membre selon le contrôleur')
    $cut=ConvertTo-DomeniaNestedGroupView (New-AaGroupRead -Truncated $true)
    $unknown=Get-DomeniaGroupMembershipExplanation -View $cut -TargetDn ('CN=Absent,'+$script:AaDomain)
    Assert-True ($null -eq $unknown.Member) 'Lecture bornee : jamais non membre';Assert-True ($unknown.Text -match 'Indéterminé')
    $primary=Get-DomeniaGroupMembershipExplanation -View $view -TargetDn ('CN=Domain Users,CN=Users,'+$script:AaDomain)
    Assert-True $primary.Member;Assert-True ($primary.Text -match 'groupe principal')
    Assert-True ((Get-DomeniaGroupMembershipExplanation -View $view -TargetDn ('CN=G1,'+$script:AaDomain)).Text -match 'appartenance directe')
}

# ---------------------------------------------------------------- 104
function New-AaAclRead {
    $reset='00299570-246d-11d0-a768-00aa006e0529';$member='bf9679c0-0de6-11d0-a285-00aa003049e2';$pwd='bf967a0a-0de6-11d0-a285-00aa003049e2'
    return [pscustomobject]@{
        Action='Acl';Dn=('CN=Jean,OU=Support,'+$script:AaDomain);State='Read';Message='';Total=5;Truncated=$false;MaxAces=1000;Protected=$false
        OwnerSid=($script:AaSid+'-512');SidNames=@{($script:AaSid+'-1500')='GG-Support'};SidNamesError='';GuidNames=@{'11111111-2222-3333-4444-555555555555'='ms-Mcs-AdmPwd'};GuidNamesError=''
        Aces=@(
            [pscustomobject]@{Sid=($script:AaSid+'-1500');AccessControlType='Allow';ActiveDirectoryRights='ExtendedRight';ObjectType=$reset;InheritedObjectType='';IsInherited=$false;InheritanceType='None'}
            [pscustomobject]@{Sid=($script:AaSid+'-1500');AccessControlType='Allow';ActiveDirectoryRights='WriteProperty';ObjectType=$pwd;InheritedObjectType='';IsInherited=$false;InheritanceType='None'}
            [pscustomobject]@{Sid='S-1-1-0';AccessControlType='Deny';ActiveDirectoryRights='WriteProperty';ObjectType=$member;InheritedObjectType='';IsInherited=$true;InheritanceType='All'}
            [pscustomobject]@{Sid=($script:AaSid+'-512');AccessControlType='Allow';ActiveDirectoryRights='GenericAll';ObjectType='';InheritedObjectType='bf967aba-0de6-11d0-a285-00aa003049e2';IsInherited=$true;InheritanceType='Descendents'}
            [pscustomobject]@{Sid=($script:AaSid+'-1600');AccessControlType='Allow';ActiveDirectoryRights='ReadProperty';ObjectType='11111111-2222-3333-4444-555555555555';InheritedObjectType='';IsInherited=$false;InheritanceType='None'}
        )
    }
}
Test-Case '104' 'Delegations : explicites et heritees distinguees, droits et cibles en clair' {
    $view=ConvertTo-DomeniaDelegationView (New-AaAclRead)
    Assert-Equal 5 @($view.Rows).Count;Assert-Equal 3 $view.Explicit;Assert-Equal 2 $view.Inherited;Assert-Equal 1 $view.Deny
    $rows=@($view.Rows)
    Assert-Equal 'GG-Support' $rows[0].Beneficiaire;Assert-Equal 'Réinitialiser le mot de passe' $rows[0].Cible;Assert-Equal 'Posée sur cet objet' $rows[0].Origine
    Assert-Equal 'Tout le monde' $rows[2].Beneficiaire;Assert-Equal 'Refus' $rows[2].Type;Assert-Equal 'Héritée dʼun conteneur parent' $rows[2].Origine;Assert-Equal 'Membres du groupe (member)' $rows[2].Cible
    Assert-Equal 'Admins du domaine' $rows[3].Beneficiaire;Assert-Equal 'Objets utilisateur' $rows[3].SappliqueA;Assert-False $rows[3].SurObjet
    Assert-Equal 'ms-Mcs-AdmPwd' $rows[4].Cible 'GUID resolu par le schema';Assert-Equal ($script:AaSid+'-1600') $rows[4].Beneficiaire 'Compte non resolu : SID garde'
    Assert-Equal 'Contrôle total' $rows[3].Droits;Assert-Equal 'Lire des propriétés, Écrire des propriétés' (Format-DomeniaAdRights 'ReadProperty, WriteProperty')
    Assert-True ($view.Summary -match 'Propriétaire : Admins du domaine');Assert-True ($view.Summary -match 'nʼest pas un droit effectif')
    Assert-Equal 3 @(Select-DomeniaDelegationRows -Rows $rows -ExplicitOnly $true).Count
    Assert-Equal 2 @(Select-DomeniaDelegationRows -Rows $rows -Text 'gg-support').Count
}
Test-Case '104' 'Lecture refusee : aucune absence deduite' {
    $view=ConvertTo-DomeniaDelegationView ([pscustomobject]@{Action='Acl';Dn='CN=X';State='Refused';Message='Accès refusé';Aces=@();Total=0})
    Assert-Equal 0 @($view.Rows).Count;Assert-True ($view.Summary -match 'refusée : aucune délégation') $view.Summary
}
Test-Case '104' 'Estimation pour un beneficiaire : ordre canonique, partiel, heritage seul et limites dites' {
    $aces=(New-AaAclRead).Aces
    $estimate=Get-DomeniaAccessEstimate -Aces $aces -Sids @($script:AaSid+'-1500') -Trustee 'GG-Support'
    $by=@{};foreach($row in @($estimate.Rows)){$by[$row.Droit]=$row}
    Assert-Equal 'Autorisé' $by['Réinitialiser le mot de passe'].Resultat;Assert-True ($by['Réinitialiser le mot de passe'].Par -match 'posée sur lʼobjet')
    Assert-Equal 'Refusé' $by['Modifier les membres dʼun groupe'].Resultat 'Refus herite de Tout le monde'
    Assert-True ($by['Modifier des attributs'].Resultat -match '^Partiel')
    Assert-Equal 'Non accordé par les entrées lues' $by['Contrôle total'].Resultat
    Assert-True ($estimate.Limits -match 'Groupes du bénéficiaire non lus')
    $admins=Get-DomeniaAccessEstimate -Aces $aces -Sids @($script:AaSid+'-512') -IncludesGroups $true
    Assert-Equal 'Non accordé par les entrées lues' (@($admins.Rows|Where-Object{$_.Droit -eq 'Contrôle total'})[0].Resultat) 'Une entree heritee seulement pour les descendants ne vaut pas sur l objet'
    Assert-True ($admins.Limits -match 'tokenGroups')
    Assert-Equal 'Tout le monde' (Get-DomeniaWellKnownSidName 'S-1-1-0');Assert-Equal 'Admins du domaine' (Get-DomeniaWellKnownSidName ($script:AaSid+'-512'));Assert-Equal '' (Get-DomeniaWellKnownSidName ($script:AaSid+'-1500'))
}

# ---------------------------------------------------------------- 105
Test-Case '105' 'Chaine des conteneurs : OU au-dessus de l objet puis domaine, conteneurs CN ignores' {
    Assert-Equal ('OU=Compta,OU=Paris,'+$script:AaDomain+'|OU=Paris,'+$script:AaDomain+'|'+$script:AaDomain) ((Get-DomeniaGpoContainerChain ('CN=PC-01,OU=Compta,OU=Paris,'+$script:AaDomain) $script:AaDomain 'Machine') -join '|')
    Assert-Equal $script:AaDomain ((Get-DomeniaGpoContainerChain ('CN=Jean,CN=Users,'+$script:AaDomain) $script:AaDomain 'Utilisateur') -join '|')
    Assert-Equal ('OU=Paris,'+$script:AaDomain+'|'+$script:AaDomain) ((Get-DomeniaGpoContainerChain ('OU=Paris,'+$script:AaDomain) $script:AaDomain 'OU') -join '|')
    Assert-Equal 0 (Get-DomeniaGpoContainerChain 'CN=X,DC=autre,DC=invalid' $script:AaDomain 'Machine').Count
    Assert-Equal ('OU=A\,B,'+$script:AaDomain+'|'+$script:AaDomain) ((Get-DomeniaGpoContainerChain ('CN=PC,OU=A\,B,'+$script:AaDomain) $script:AaDomain 'Machine') -join '|') 'Virgule echappee'
}
Test-Case '105' 'Liens lus et resultat du poste presentes separement ; liens de site non lus dits' {
    $a='aaaaaaaa-1111-4111-8111-111111111111';$b='bbbbbbbb-2222-4222-8222-222222222222'
    $links=[pscustomobject]@{Containers=@(
        [pscustomobject]@{Dn=('OU=Postes,'+$script:AaDomain);GpLink=('[LDAP://cn={'+$a+'},cn=policies,cn=system,'+$script:AaDomain+';2]');GpOptions=0;ReadStatus='OK'}
        [pscustomobject]@{Dn=$script:AaDomain;GpLink=('[LDAP://cn={'+$b+'},cn=policies,cn=system,'+$script:AaDomain+';0]');GpOptions=0;ReadStatus='OK'}
    );Gpos=@([pscustomobject]@{Guid=$a;Name='Sécurité postes';Flags='2'},[pscustomobject]@{Guid=$b;Name='Default Domain Policy';Flags='0'});NamesStatus='OK'}
    $view=ConvertTo-DomeniaGpoAuditView -Links $links
    Assert-Equal 2 @($view.Rows).Count;Assert-False $view.AppliedProven
    $first=@($view.Rows)[0]
    Assert-Equal 'Sécurité postes' $first.Gpo;Assert-Equal 'Postes' $first.LieA;Assert-Equal 'Oui' $first.Force;Assert-Equal 'Paramètres ordinateur désactivés' $first.EtatGpo
    Assert-True ($first.Resultat -match 'non demandé');Assert-Equal 'Domaine' @($view.Rows)[1].LieA
    $site=@($view.Facts|Where-Object{$_.Fait -eq 'Liens de site'})[0];Assert-Equal 'Non lus' $site.Valeur;Assert-Equal 'Inconnu' $site.Etat
    $rsop=[pscustomobject]@{ReadStatus='OK';Gpos=@([pscustomobject]@{GuidName=('{'+$a+'}');Name='Sécurité postes';AccessDenied=$false;FilterAllowed=$true;Enabled=$true});Links=@([pscustomobject]@{Gpo=('RSOP_GPO.id="cn={'+$a+'},cn=policies"');AppliedOrder=1});ReadUtc=$script:AaNow}
    $applied=ConvertTo-DomeniaGpoAuditView -Links $links -Rsop $rsop
    Assert-True $applied.AppliedProven
    Assert-True (@($applied.Rows)[0].Resultat -match '^Appliquée selon RSoP');Assert-True (@($applied.Rows)[1].Resultat -match '^Absente du résultat RSoP')
    $refused=ConvertTo-DomeniaGpoAuditView -Links $links -Rsop ([pscustomobject]@{ReadStatus='AccessDenied';Gpos=$null;Links=$null})
    Assert-True (@($refused.Rows)[0].Resultat -match 'refusée') 'Un refus RSoP ne devient jamais une absence'
}

# ---------------------------------------------------------------- 108
function New-AaNeighbor {
    param([string]$Source,[string]$Success,[string]$Attempt,[int]$Result=0,[int]$Failures=0)
    return ('<DS_REPL_NEIGHBOR><pszNamingContext>'+$script:AaDomain+'</pszNamingContext><pszSourceDsaDN>CN=NTDS Settings,CN='+$Source+',CN=Servers,CN=Paris,CN=Sites,CN=Configuration,'+$script:AaDomain+'</pszSourceDsaDN><ftimeLastSyncSuccess>'+$Success+'</ftimeLastSyncSuccess><ftimeLastSyncAttempt>'+$Attempt+'</ftimeLastSyncAttempt><dwLastSyncResult>'+$Result+'</dwLastSyncResult><cNumConsecutiveSyncFailures>'+$Failures+'</cNumConsecutiveSyncFailures></DS_REPL_NEIGHBOR>')
}
Test-Case '108' 'Heure du RootDSE et voisins de replication lus sans entite externe' {
    Assert-Equal ([datetime]::SpecifyKind([datetime]'2026-10-15T10:15:30',[DateTimeKind]::Utc)) (ConvertFrom-DomeniaGeneralizedTime '20261015101530.0Z')
    Assert-True ($null -eq (ConvertFrom-DomeniaGeneralizedTime 'pas une date'))
    $values=@((New-AaNeighbor 'DC2' '2026-10-15T09:50:00Z' '2026-10-15T09:50:00Z'),(New-AaNeighbor 'DC3' '1601-01-01T00:00:00Z' '2026-10-15T09:55:00Z' 8453 4),'<!DOCTYPE x [<!ENTITY e SYSTEM "file:///c:/x">]><DS_REPL_NEIGHBOR>&e;</DS_REPL_NEIGHBOR>','pas du xml')
    $n=@(ConvertFrom-DomeniaReplNeighbor $values)
    Assert-Equal 2 $n.Count 'Fragments invalides ou a entite externe ignores'
    Assert-Equal 'DC2' $n[0].Source;Assert-False $n[0].Never;Assert-Equal 0 $n[0].LastResult
    Assert-True $n[1].Never;Assert-Equal 8453 $n[1].LastResult;Assert-Equal 4 $n[1].ConsecutiveFailures
    Assert-Equal '8453 (accès à la réplication refusé)' (Get-DomeniaReplResultText 8453);Assert-Equal 'code 77' (Get-DomeniaReplResultText 77)
}
Test-Case '108' 'Synthese des controleurs : injoignable non lu, ecart d heure, replication et SRV a verifier' {
    $probe=[pscustomobject]@{SrvState='Read';Srv=@('dc1.example.invalid','dc2.example.invalid','dc9.example.invalid');Pdc='dc1.example.invalid';Results=@(
        [pscustomobject]@{Dc='dc1.example.invalid';Addresses=@('192.0.2.1');Ldap=$true;Kerberos=$true;RootDse='Read';CurrentTime='20261015100002.0Z';LocalUtc=$script:AaNow.ToString('o');IsSynchronized='TRUE';ReplState='Read';Neighbors=@((New-AaNeighbor 'DC3' '2026-10-15T09:50:00Z' '2026-10-15T09:50:00Z'))}
        [pscustomobject]@{Dc='dc2.example.invalid';Addresses=@('192.0.2.2');Ldap=$false;Kerberos=$false;RootDse='NotRead';ReplState='NotRead';Neighbors=@()}
        [pscustomobject]@{Dc='dc3.example.invalid';Addresses=@('192.0.2.3');Ldap=$true;Kerberos=$true;RootDse='Read';CurrentTime='20261015100640.0Z';LocalUtc=$script:AaNow.ToString('o');IsSynchronized='TRUE';ReplState='Read';Neighbors=@((New-AaNeighbor 'DC1' '2026-10-13T08:00:00Z' '2026-10-15T09:55:00Z' 1722 12))}
    )}
    $view=Get-DomeniaAdHealthView -Probe $probe -NowUtc $script:AaNow
    $rows=@($view.Rows)
    Assert-Equal 'Sans écart constaté' $rows[0].Verdict $rows[0].Detail;Assert-Equal '+2 s par rapport à ce poste' $rows[0].Heure
    Assert-Equal 'Non lu' $rows[1].Verdict;Assert-True ($rows[1].Detail -match 'aucune conclusion')
    Assert-Equal 'À vérifier' $rows[2].Verdict
    foreach($expected in @('Écart dʼheure','échec répété','sans succès depuis plus de 24 h','Absent des enregistrements SRV')){Assert-True ($rows[2].Detail -match [regex]::Escape($expected)) ('Absent : '+$expected+' / '+$rows[2].Detail)}
    Assert-Equal 2 @($view.Neighbors).Count;Assert-True (@($view.Neighbors)[1].Resultat -match '1722')
    Assert-True (@($view.Facts|Where-Object{$_.Fait -like 'Écart avec lʼémulateur PDC*'}).Count -eq 1) 'Ecart avec le PDC calcule'
    Assert-True ((@($view.Facts|Where-Object{$_.Fait -eq 'Enregistrements SRV des contrôleurs'})[0].Valeur) -match 'dc9\.example\.invalid')
    Assert-True ($view.Summary -match '1 sans écart, 1 à vérifier, 1 non lu')
}
Test-Case '108' 'Services des controleurs : refus distinct d un arret, DNS absent normal, SYSVOL par DFSR' {
    $read=[pscustomobject]@{Results=@(
        [pscustomobject]@{Dc='dc1';State='Refused';Message='Accès refusé';Services=@()}
        [pscustomobject]@{Dc='dc2';State='Read';Message='';Services=@([pscustomobject]@{Name='NTDS';State='Running';StartMode='Auto'},[pscustomobject]@{Name='Netlogon';State='Running';StartMode='Auto'},[pscustomobject]@{Name='Kdc';State='Running';StartMode='Auto'},[pscustomobject]@{Name='W32Time';State='Stopped';StartMode='Manual'},[pscustomobject]@{Name='ADWS';State='Running';StartMode='Auto'},[pscustomobject]@{Name='DFSR';State='Running';StartMode='Auto'})}
    )}
    $rows=Get-DomeniaDcServiceView -Read $read
    $refused=@($rows|Where-Object{$_.Controleur -eq 'dc1'})
    Assert-Equal 1 $refused.Count;Assert-True ($refused[0].Etat -match 'droits dʼadministration')
    $dc2=@{};foreach($row in @($rows|Where-Object{$_.Controleur -eq 'dc2'})){$dc2[$row.Service]=$row}
    Assert-Equal 'Conforme' $dc2['NTDS'].Constat;Assert-Equal 'Non démarré : à vérifier' $dc2['W32Time'].Constat;Assert-Equal 'Arrêté' $dc2['W32Time'].Etat
    Assert-True ($dc2['DNS'].Constat -match 'normal si le DNS');Assert-True ($dc2['NtFrs'].Constat -match 'DFSR réplique SYSVOL');Assert-True ($dc2['DFSR'].Constat -match '^Conforme')
}
Test-Case '108' 'Services : controleur non interroge faute de temps, sans conclusion sur son etat' {
    $read=[pscustomobject]@{BudgetSeconds=65;Results=@([pscustomobject]@{Dc='dc3';State='NotRead';Message='Budget de temps épuisé (65 s) : contrôleur non interrogé, relancez la lecture pour lui seul.';Services=@()})}
    $rows=@(Get-DomeniaDcServiceView -Read $read)
    Assert-Equal 1 $rows.Count 'Aucun service suppose pour un controleur non interroge'
    Assert-Equal 'Non interrogé' $rows[0].Etat;Assert-True ($rows[0].Constat -match 'Budget de temps épuisé') $rows[0].Constat
    Assert-False ($rows[0].Etat -match 'refusée|Arrêté') 'Un controleur non interroge nʼest ni refuse ni arrete'
}

# ---------------------------------------------------------------- 109
Test-Case '109' 'Identites : doublons, nom DNS partage, noms divergents et noms recycles, tous a revoir' {
    $guidOld='99999999-9999-4999-8999-999999999999'
    $rows=@(
        [pscustomobject]@{Guid='11111111-1111-4111-8111-111111111111';Name='Jean Dupont';Sam='jdupont';Type='Utilisateur';Mail='j.dupont@example.invalid';Upn='jdupont@example.invalid';Uac='512';Description='';Department='';Manager='CN=Hors,OU=Ailleurs,DC=example,DC=invalid';Dn='CN=Jean Dupont,OU=Support,DC=example,DC=invalid'}
        [pscustomobject]@{Guid='22222222-2222-4222-8222-222222222222';Name='Jeanne Dupont';Sam='jdupont2';Type='Utilisateur';Mail='J.Dupont@example.invalid';Upn='jdupont2@example.invalid';Uac='512';Description='x';Department='y';Manager='';Dn='CN=Jeanne Dupont,OU=Support,DC=example,DC=invalid'}
        [pscustomobject]@{Guid='33333333-3333-4333-8333-333333333333';Name='PC-01';Sam='PC-01$';Type='Machine';DnsHostName='pc-01.example.invalid';Uac='4096';Dn='CN=PC-01,OU=Support,DC=example,DC=invalid'}
        [pscustomobject]@{Guid='44444444-4444-4444-8444-444444444444';Name='PC-02';Sam='PC-02$';Type='Machine';DnsHostName='PC-01.example.invalid';Uac='4096';Dn='CN=PC-02,OU=Support,DC=example,DC=invalid'}
    )
    $index=[pscustomobject]@{Busy=$false;Missing=$false;Computers=@([pscustomobject]@{name='PC-01';login='PC-01$';object_guid=$guidOld},[pscustomobject]@{name='PC-02';login='PC-02$';object_guid='44444444-4444-4444-8444-444444444444'});Users=@()}
    $result=Find-DomeniaIdentityConflicts -Rows $rows -LocalIndex $index -NowUtc $script:AaNow
    $categories=@($result.Findings|ForEach-Object{$_.Categorie})
    foreach($expected in @('Valeur en double','Nom DNS partagé','Nom AD et nom DNS divergents','Nom recyclé ou objet recréé')){Assert-True ($categories -contains $expected) ('Absent : '+$expected+' / '+($categories -join ', '))}
    Assert-Equal 1 @($result.Findings|Where-Object{$_.Categorie -eq 'Nom recyclé ou objet recréé'}).Count 'Meme GUID : pas un nom recycle'
    Assert-True (@($result.Findings|Where-Object{$_.Categorie -eq 'Nom recyclé ou objet recréé'})[0].Element -match [regex]::Escape($guidOld))
    Assert-Equal 0 @($result.Findings|Where-Object{$_.Conclusion -ne 'À revoir'}).Count
    Assert-Equal 0 @($result.Findings|Where-Object{$_.Categorie -match 'Responsable|Information manquante|peu utilis'}).Count 'Hors du sujet des identites'
    Assert-False (($result.Findings|ConvertTo-Json -Depth 3) -match 'Supprim|Fusionn') 'Aucune suppression ni fusion proposee'
    Assert-True ($result.Summary -match 'comparés avec la base locale')
    Assert-True ((Find-DomeniaIdentityConflicts -Rows $rows -LocalIndex ([pscustomobject]@{Busy=$true;Missing=$false})).Summary -match 'occupée')
    $failed=Find-DomeniaIdentityConflicts -Rows $rows -LocalIndex ([pscustomobject]@{Busy=$false;Missing=$false;Failed=$true;Message='Délai dépassé.'})
    Assert-Equal 'Failed' $failed.LocalIndex
    Assert-True ($failed.Summary -match 'Base locale non lue \(Délai dépassé\) : noms recyclés non recherchés') $failed.Summary
    Assert-False ($failed.Summary -match 'occupée') 'Un echec de lecture nʼest pas une base occupee'
    Assert-Equal 0 @($failed.Findings|Where-Object{$_.Categorie -eq 'Nom recyclé ou objet recréé'}).Count
    $partial=Find-DomeniaIdentityConflicts -Rows $rows -LocalIndex $index -NowUtc $script:AaNow -ComparedNames 2000 -TotalNames 3000
    Assert-True ($partial.Summary -match '2000 noms sur 3000 comparés avec la base locale') $partial.Summary
    $full=Find-DomeniaIdentityConflicts -Rows $rows -LocalIndex $index -NowUtc $script:AaNow -ComparedNames 4 -TotalNames 4
    Assert-True ($full.Summary -match 'Noms comparés avec la base locale de ce poste\.') $full.Summary
    Assert-False ($full.Summary -match 'noms sur') 'Comparaison complete presentee comme partielle'
    Assert-True ((Find-DomeniaIdentityConflicts -Rows $rows).Summary -match 'non consultée')
    Assert-True (@((Find-DomeniaIdentityConflicts -Rows $rows -Truncated $true).Findings)[0].Limite -match 'partiellement')
}

# ---------------------------------------------------------------- 107
Test-Case '107' 'Historique distinct de l observation : badge, contradiction et vue en trois lignes' {
    $history=Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='CIM dernier utilisateur LogonUI';When='2026-10-01T08:00:00Z'})
    Assert-Equal 'Historique' $history.Badge;Assert-Equal 'Historique' $history.Label;Assert-True ($history.Rule -match 'pas présence actuelle')
    Assert-Equal 'Observe' (Get-DomeniaEvidenceBadge ([pscustomobject]@{Source='Console CIM/DCOM'})).Badge
    $owner=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Saisie manuelle';When='2026-09-01T08:00:00Z'}
    $old=[pscustomobject]@{UserLogin='ancien';Computer='PC-1';Source='Registre LogonUI';When='2026-08-01T08:00:00Z'}
    Assert-Equal 0 @(Get-DomeniaLinkConflicts @($owner,$old)).Count 'Une ancienne ouverture de session ne contredit pas une affectation'
    $console=[pscustomobject]@{UserLogin='jdupont';Computer='PC-1';Source='Console CIM/DCOM';When='2026-10-14T08:00:00Z'}
    $clue=[pscustomobject]@{UserLogin='x';Computer='PC-1';Source='Attribut description';When=''}
    $overview=Get-DomeniaRelationOverview -Relations @($owner,$old,$console,$clue) -SubjectType Machine -NowUtc $script:AaNow
    Assert-Equal 4 @($overview.Lines).Count;Assert-Equal 1 $overview.Declared;Assert-Equal 1 $overview.Observed;Assert-Equal 1 $overview.History
    $lines=@($overview.Lines)
    Assert-True ($lines[0].Valeur -match '^jdupont · 01/09 ') $lines[0].Valeur;Assert-True ($lines[0].Valeur -match 'source : Saisie manuelle')
    Assert-True ($lines[1].Valeur -match '^jdupont · 14/10 ') $lines[1].Valeur
    Assert-True ($lines[2].Valeur -match '^1 relevé\(s\), le plus récent : ancien') $lines[2].Valeur
    Assert-Equal 'Autres indices' $lines[3].Fait
    $empty=Get-DomeniaRelationOverview -Relations @() -SubjectType Utilisateur
    Assert-Equal 'Aucune affectation déclarée' @($empty.Lines)[0].Valeur;Assert-Equal 3 @($empty.Lines).Count
}
Test-Case '107' 'Historique enregistre : nature et origine visibles, aucun pourcentage' {
    $rows=@(ConvertTo-DomeniaRelationHistoryRows @(
        [pscustomobject]@{user_login='jdupont';computer='PC-1';source='Saisie manuelle';confidence=100;verified_in_ad=1;observed_at='2026-10-01T08:00:00.0000000Z';details='Bureau 12'}
        [pscustomobject]@{user_login='ancien';computer='PC-1';source='Registre LogonUI';confidence=40;verified_in_ad=0;observed_at='illisible';details=''}
    ))
    Assert-Equal 2 $rows.Count
    Assert-Equal 'Déclaré' $rows[0].Nature;Assert-Equal 'Oui' $rows[0].VerifieAd;Assert-True ($rows[0].Date -match '^01/10/2026 ')
    Assert-Equal 'Historique' $rows[1].Nature;Assert-Equal 'Date illisible' $rows[1].Date;Assert-Equal 'Non' $rows[1].VerifieAd
    Assert-False (($rows|ConvertTo-Json -Depth 3) -match '%|"100"|"40"') 'Aucune confiance chiffree affichee'
}

# ---------------------------------------------------------------- commun
Test-Case '102' 'Cible figee au geste, disponibilite par type et rappel ignore pour une autre fiche' {
    $selected=[pscustomobject]@{DN=('CN=Jean,OU=Support,'+$script:AaDomain);Type='Utilisateur';Name='Jean';Guid='11111111-1111-4111-8111-111111111111';Entry=[pscustomobject]@{Properties=@{objectSid=@(($script:AaSid+'-1104'));sAMAccountName=@('jdupont');primaryGroupID=@('513')}}}
    $target=New-DomeniaAdAuditTarget -Selected $selected -Generation 7 -Epoch 3
    Assert-Equal ($script:AaSid+'-1104') $target.Sid;Assert-Equal 'jdupont' $target.Sam;Assert-Equal '513' $target.PrimaryGroupId
    $state=[pscustomobject]@{Epoch=3;Generation=7;Dn=$selected.DN}
    Assert-True (Test-DomeniaAdAuditStateCurrent $state $target 3)
    Assert-False (Test-DomeniaAdAuditStateCurrent $state $target 4) 'Nouvelle session'
    Assert-False (Test-DomeniaAdAuditStateCurrent ([pscustomobject]@{Epoch=3;Generation=6;Dn=$selected.DN}) $target 3) 'Autre generation de fiche'
    Assert-False (Test-DomeniaAdAuditStateCurrent $state $null 3)
    Assert-True ($null -eq (New-DomeniaAdAuditTarget -Selected $null))
    Assert-True (Get-DomeniaAdAuditAvailability -Type 'Utilisateur' -Check Policy).Allowed
    Assert-False (Get-DomeniaAdAuditAvailability -Type 'Machine' -Check Policy).Allowed
    Assert-True (Get-DomeniaAdAuditAvailability -Type 'Machine' -Check GpoApplied).Allowed
    Assert-False (Get-DomeniaAdAuditAvailability -Type 'Groupe' -Check GpoLinks).Allowed
    Assert-True ((Get-DomeniaAdAuditAvailability -Type '' -Check Acl).Reason -match 'Ouvrez dʼabord une fiche')
}
Test-Case '108' 'Copie pour un ticket : resume, colonnes, lignes bornees' {
    $sections=@([pscustomobject]@{Summary='Résumé';Columns=@([pscustomobject]@{Header='Contrôleur';Property='Controleur'},[pscustomobject]@{Header='Verdict';Property='Verdict'});Rows=@([pscustomobject]@{Controleur='dc1';Verdict='Non lu'},[pscustomobject]@{Controleur='dc2';Verdict='À vérifier'},$null)})
    $text=ConvertTo-DomeniaAdAuditCopyText -Sections $sections -Title 'Audit AD'
    $lines=@($text -split "\r?\n")
    Assert-Equal 'Audit AD' $lines[0];Assert-Equal 'Résumé' $lines[2];Assert-Equal ("Contrôleur`tVerdict") $lines[3];Assert-Equal ("dc1`tNon lu") $lines[4];Assert-Equal 6 $lines.Count
    Assert-True ((ConvertTo-DomeniaAdAuditCopyText -Sections $sections -MaxRows 1) -match '1 ligne\(s\) non copiée')
    Assert-Equal '3 h' (Get-DomeniaDurationText ([TimeSpan]::FromMinutes(200)));Assert-Equal '2 j' (Get-DomeniaDurationText ([TimeSpan]::FromHours(50)))
}
