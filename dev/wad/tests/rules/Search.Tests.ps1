# D031-D040 : recherche et navigation. Donnees fictives uniquement.
$script:DomainDn='DC=example,DC=invalid'
Test-Case 'D031' 'La recherche globale vise toujours le domaine entier, sans OU ni filtre herite' {
    $r=New-DomeniaGlobalSearchRequest 'dupont' $script:DomainDn 100 'reader' 4
    Assert-True (Test-DomeniaGlobalSearchRequest $r $script:DomainDn);Assert-Equal 'Subtree' $r.Scope;Assert-Equal '' $r.OuDn;Assert-Equal 'Domaine entier' $r.ScopeLabel
    $tampered=$r.PSObject.Copy();$tampered.OuDn='OU=Lyon,DC=example,DC=invalid';Assert-False (Test-DomeniaGlobalSearchRequest $tampered $script:DomainDn)
    $tampered2=$r.PSObject.Copy();$tampered2.PresenceFilter='En ligne';Assert-False (Test-DomeniaGlobalSearchRequest $tampered2 $script:DomainDn)
}
Test-Case 'D031' 'Meme saisie, meme perimetre logique quelle que soit la page' {
    $a=New-DomeniaGlobalSearchRequest 'dupont' $script:DomainDn 100 'reader' 1;$b=New-DomeniaGlobalSearchRequest ' dupont ' $script:DomainDn 100 'reader' 1
    Assert-Equal $a.Filter $b.Filter;Assert-Equal $a.BaseDn $b.BaseDn
}
Test-Case 'D032' 'Cliquer une OU ne filtre pas cette OU par le texte de la recherche globale' {
    $s=New-DomeniaSearchState;$s.Global.Text='dupont'
    [void](Set-DomeniaBrowseOu $s 'OU=Lyon,DC=example,DC=invalid')
    Assert-Equal '' $s.Browse.Filter;Assert-Equal 'dupont' $s.Global.Text;Assert-Equal 'Browse' $s.Mode
    Assert-Equal 'Domaine entier' (Get-DomeniaScopeLabel Global);Assert-True ((Get-DomeniaScopeLabel Browse 'Lyon' $false) -match 'Dans cette OU : Lyon')
    Assert-True ((Get-DomeniaScopeLabel Browse 'Lyon' $false).Contains('Enfants directs'));Assert-True ((Get-DomeniaScopeLabel Browse 'Lyon' $true).Contains('Sous-OU incluses'))
}
Test-Case 'D033' 'Jetons explicites reconnus et visibles' {
    $s=ConvertFrom-DomeniaSearchSyntax 'poste:PC-01 dupont mail:"jean dupont"'
    Assert-Equal 2 $s.Tokens.Count;Assert-Equal 'Machine' $s.Tokens[0].Kind;Assert-Equal 'PC-01' $s.Tokens[0].Value
    Assert-Equal 'Mail' $s.Tokens[1].Kind;Assert-Equal 'jean dupont' $s.Tokens[1].Value;Assert-Equal 'dupont' $s.FreeText;Assert-Equal 'Machine' $s.Type
}
Test-Case 'D033' 'Une expression non reconnue reste un texte explicable, sans filtre cache' {
    $s=ConvertFrom-DomeniaSearchSyntax 'service:compta dupont'
    Assert-Equal 0 $s.Tokens.Count;Assert-Equal 'service:compta dupont' $s.FreeText;Assert-True (($s.Notes -join ' ') -match 'pas un jeton reconnu');Assert-False $s.HasSyntax
    $plain=ConvertFrom-DomeniaSearchSyntax 'jean dupont';Assert-Equal 0 $plain.Tokens.Count;Assert-Equal 0 $plain.Notes.Count
}
Test-Case 'D034' 'Un compte exact arrive avant les correspondances larges' {
    $rows=@([pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111';Name='Dupontel Marc';Login='mdupontel';UPN='mdupontel@example.invalid'},
            [pscustomobject]@{Guid='22222222-2222-2222-2222-222222222222';Name='Jean Dupont';Login='jdupont';UPN='jdupont@example.invalid'},
            [pscustomobject]@{Guid='33333333-3333-3333-3333-333333333333';Name='Dupont';Login='dupont';UPN='dupont@example.invalid'})
    $sorted=Sort-DomeniaSearchResults $rows 'dupont'
    Assert-Equal 'dupont' $sorted[0].Login;Assert-Equal 3 $sorted.Count
    Assert-Equal 'jdupont' $sorted[1].Login 'Un mot entier du nom passe avant un mot plus long qui commence par la saisie'
}
Test-Case 'D034' 'Deduplication par identite, pas par libelle' {
    $rows=@([pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111';Name='Jean Dupont';Login='jdupont'},
            [pscustomobject]@{Guid='22222222-2222-2222-2222-222222222222';Name='Jean Dupont';Login='jdupont2'},
            [pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111';Name='Jean Dupont (copie)';Login='jdupont'})
    Assert-Equal 2 (Sort-DomeniaSearchResults $rows 'jean').Count 'Deux homonymes restent deux lignes ; un meme GUID une seule'
}
Test-Case 'D034' 'Les comptes d administration restent identifiables' {
    Assert-True (Test-DomeniaAdminAccountRow ([pscustomobject]@{Login='adm-jdupont'}));Assert-True (Test-DomeniaAdminAccountRow ([pscustomobject]@{Login='jdupont';AdminCount='1'}))
    Assert-False (Test-DomeniaAdminAccountRow ([pscustomobject]@{Login='jdupont'}))
}
Test-Case 'D035' 'Les caracteres speciaux sont echappes et ne deviennent pas du code' {
    Assert-Equal 'a\2a\28b\29\5cc' (ConvertTo-DomeniaLdapLiteral 'a*(b)\c');Assert-Equal '\00' (ConvertTo-DomeniaLdapLiteral ([string][char]0))
    Assert-Equal "O'Neil" (ConvertTo-DomeniaLdapLiteral "O'Neil");Assert-Equal 'Jean-Marc' (ConvertTo-DomeniaLdapLiteral 'Jean-Marc')
    $f=ConvertTo-DomeniaSearchFilter 'x)(objectClass=*' 'Utilisateur'
    Assert-True $f.Valid;Assert-False ($f.Filter -match '\(objectClass=\*\)') 'Injection de filtre impossible';Assert-True ($f.Filter -match 'x\\29\\28objectClass=')
}
Test-Case 'D035' 'Noms composes, apostrophes, accents et plusieurs mots' {
    $f=ConvertTo-DomeniaSearchFilter "Jean-Marc O'Neil" 'Utilisateur'
    Assert-True $f.Valid;Assert-True ($f.Filter -match 'cn=Jean-Marc\*');Assert-True ($f.Filter -match "sn=O'Neil\*")
    Assert-Equal 2 (Split-DomeniaSearchWords "  Éloïse   d'Arc ").Count
    Assert-True ((ConvertTo-DomeniaSearchFilter 'Éloïse').Filter -match 'Éloïse\*')
}
Test-Case 'D035' 'Pas de joker initial implicite ni de recherche trop courte sur tout le domaine' {
    $f=ConvertTo-DomeniaSearchFilter 'dupont';Assert-False ($f.Filter -match '=\*dupont');Assert-False $f.Costly
    $short=ConvertTo-DomeniaSearchFilter 'a';Assert-False $short.Valid;Assert-True $short.Costly
    $explicit=ConvertTo-DomeniaSearchFilter '*pont';Assert-True $explicit.Costly;Assert-True ($explicit.Filter -match 'cn=\*pont\*')
    Assert-False (ConvertTo-DomeniaSearchFilter '').Valid
}
Test-Case 'D035' 'Les parentheses du filtre restent equilibrees' {
    foreach($text in @('jean dupont','a(b','x)y','(((','poste:PC-1 dupont','mail:a@b.c')){
        $s=ConvertFrom-DomeniaSearchSyntax $text;$f=ConvertTo-DomeniaSearchFilter $s.FreeText $s.Type $s.Tokens
        if(-not $f.Valid){continue}
        $depth=0;$min=0;foreach($ch in ($f.Filter -replace '\\[0-9a-f]{2}','').ToCharArray()){if($ch -eq '('){$depth++}elseif($ch -eq ')'){$depth--;if($depth -lt $min){$min=$depth}}}
        Assert-Equal 0 $depth ('Filtre desequilibre pour '+$text);Assert-Equal 0 $min
    }
}
Test-Case 'D036' 'GUID, SID, DN, UPN, DOMAINE\compte et FQDN reconnus avec explication' {
    Assert-Equal 'Guid' (Get-DomeniaPastedIdentifier '{F4DC5A91-C11B-46B5-893D-9A2CBBAD31AD}').Kind
    Assert-True ((Get-DomeniaPastedIdentifier 'f4dc5a91-c11b-46b5-893d-9a2cbbad31ad').Filter -match '^\(objectGUID=(\\[0-9a-f]{2}){16}\)$')
    Assert-Equal 'Sid' (Get-DomeniaPastedIdentifier 'S-1-5-21-1-2-3-1104').Kind
    Assert-Equal 'DN' (Get-DomeniaPastedIdentifier 'CN=Jean Dupont,OU=Lyon,DC=example,DC=invalid').Kind
    Assert-Equal 'DN' (Get-DomeniaPastedIdentifier 'CN=Dupont\, Jean,OU=Lyon,DC=example,DC=invalid').Kind 'Une virgule echappee reste dans son RDN'
    Assert-Equal 'None' (Get-DomeniaPastedIdentifier 'CN=Jean Dupont').Kind 'Un seul RDN ne suffit pas'
    Assert-Equal 'Upn' (Get-DomeniaPastedIdentifier 'jdupont@example.invalid').Kind
    Assert-Equal 'DownLevel' (Get-DomeniaPastedIdentifier 'EXAMPLE\jdupont').Kind
    Assert-Equal 'Fqdn' (Get-DomeniaPastedIdentifier 'pc-01.example.invalid').Kind
    Assert-Equal 'None' (Get-DomeniaPastedIdentifier 'jean dupont').Kind;Assert-Equal 'None' (Get-DomeniaPastedIdentifier 'pc-01').Kind
    Assert-True ((Get-DomeniaPastedIdentifier 'S-1-5-21-1-2-3-1104').Explanation.Length -gt 10)
}
Test-Case 'D036' 'Une saisie reconnue ou ambigue n ouvre jamais automatiquement un resultat' {
    foreach($text in @('jdupont@example.invalid','EXAMPLE\jdupont','S-1-5-21-1-2-3-1104','pc-01.example.invalid','jean')){Assert-False (Get-DomeniaPastedIdentifier $text).AutoOpen}
    Assert-True (Get-DomeniaPastedIdentifier 'jdupont@example.invalid').Ambiguous
    $r=New-DomeniaGlobalSearchRequest 'S-1-5-21-1-2-3-1104' $script:DomainDn;Assert-Equal '(objectSid=S-1-5-21-1-2-3-1104)' $r.Filter
    Assert-True (Get-DomeniaPastedIdentifier 'jean.marc.dupont').Ambiguous 'Un identifiant a points peut etre un compte'
    Assert-False ((New-DomeniaGlobalSearchRequest 'jean.marc.dupont' $script:DomainDn).Filter -match '^\(dNSHostName=') 'Un identifiant a points ne doit pas etre reduit au nom DNS'
    Assert-False ((New-DomeniaGlobalSearchRequest 'alex@example.invalid' $script:DomainDn).Filter -match '^\(\|\(userPrincipalName=alex@example\.invalid\)') 'Une adresse reste une recherche par prefixe'
}
Test-Case 'D037' 'Le compteur precise charge, limite ou complet' {
    Assert-True ((Get-DomeniaResultCounterText 100 100 $false) -match 'limitée à 100');Assert-True ((Get-DomeniaResultCounterText 42 100 $true) -match 'liste complète')
    Assert-True ((Get-DomeniaResultCounterText 20000 20000 $false) -match 'affinez la recherche');Assert-False ((Get-DomeniaResultCounterText 20000 20000 $false) -match 'chargez la suite')
    Assert-True ((Get-DomeniaResultCounterText 10 100 $false $true) -match 'lecture en cours');Assert-True ((Get-DomeniaResultCounterText 42 100 $true $false 7) -match '7 visible')
}
Test-Case 'D037' 'La suite reprend apres le dernier nom et refuse un ancien contexte' {
    $c=New-DomeniaContinuation '(objectCategory=computer)' 'PC-100 (a)' 100 'reader' 5 $script:DomainDn
    Assert-Equal '(&(objectCategory=computer)(name>=PC-100 \28a\29))' $c.Filter;Assert-Equal 'name' $c.SortAttribute
    Assert-True (Test-DomeniaContinuationCurrent $c 'reader' 5 $script:DomainDn);Assert-False (Test-DomeniaContinuationCurrent $c 'reader' 6 $script:DomainDn)
    Assert-False (Test-DomeniaContinuationCurrent $c 'autre' 5 $script:DomainDn);Assert-False (Test-DomeniaContinuationCurrent $c 'reader' 5 'OU=X,DC=example,DC=invalid')
}
Test-Case 'D038' 'Une vue enregistree ne restaure ni compte privilegie ni permission d ecriture' {
    $v=ConvertTo-DomeniaSavedView ([pscustomobject]@{Name='Ma vue';Text='dupont';Type='Utilisateur';OuDn='OU=X';Limit=50000;Credential='secret';ReadOnlyMode=$false;AdminAccount='adm'})
    $names=@($v.PSObject.Properties|ForEach-Object{$_.Name})
    Assert-False ($names -contains 'Credential');Assert-False ($names -contains 'ReadOnlyMode');Assert-False ($names -contains 'AdminAccount');Assert-Equal 20000 $v.Limit
}
Test-Case 'D038' 'Vues de travail : filtres bornes et lecture seule' {
    $views=@(Get-DomeniaWorkViews ([datetime]::SpecifyKind([datetime]'2026-01-01',[DateTimeKind]::Utc)))
    Assert-True ($views.Count -ge 4);Assert-True (@($views|Where-Object{$_.Id -eq 'expiring'})[0].Filter -match 'accountExpires>=\d+')
    Assert-True (@($views|Where-Object{$_.Id -eq 'recent'})[0].Filter -match 'whenChanged>=20251225000000\.0Z')
    Assert-True (@($views|Where-Object{$_.Id -eq 'stalecomputers'})[0].Note -match 'supprimable')
}
Test-Case 'D039' 'Chemin d OU lisible, DN exact conserve' {
    Assert-Equal 'example.invalid / Marseille / Support' (Get-DomeniaOuDisplayPath 'OU=Support,OU=Marseille,DC=example,DC=invalid')
    Assert-Equal 3 (Split-DomeniaDn 'OU=A\, B,DC=example,DC=invalid').Count
}
Test-Case 'D039' 'Separateurs echappes et octets UTF-8 decodes comme dans l explorateur' {
    Assert-Equal 4 (Split-DomeniaDn 'OU=Back\\,OU=Sites,DC=example,DC=invalid').Count 'Un antislash echappe termine le RDN'
    Assert-True ((Get-DomeniaOuDisplayPath 'OU=\C3\89quipe,DC=example,DC=invalid').EndsWith(([string][char]0x00C9)+'quipe'))
    Assert-True ((Get-DomeniaOuDisplayPath 'OU=Help\2CDesk,DC=example,DC=invalid').EndsWith('Help,Desk'))
    Assert-True ((Get-DomeniaOuDisplayPath 'OU=Back\\,OU=Sites,DC=example,DC=invalid').EndsWith('Sites / Back\'))
    Assert-Equal 'A\41' (ConvertFrom-DomeniaDnValue 'A\\41') 'Un antislash echappe n est pas le debut d un octet'
    Assert-Equal 'OU=Sites,DC=example,DC=invalid' (Get-DomeniaDnParent 'OU=Paris\, Est,OU=Sites,DC=example,DC=invalid')
    Assert-Equal '' (Get-DomeniaDnParent 'DC=invalid')
}
Test-Case 'D039' 'OU supprimee ou deplacee : choix explicite, jamais le domaine entier en silence' {
    $missing=Resolve-DomeniaOuRestore 'OU=X,DC=example,DC=invalid' $false
    Assert-Equal 'AskMissing' $missing.Action;Assert-True $missing.RequiresChoice;Assert-Equal '' $missing.TargetDn
    $moved=Resolve-DomeniaOuRestore 'OU=X,DC=example,DC=invalid' $false 'OU=X,OU=Y,DC=example,DC=invalid'
    Assert-Equal 'AskMoved' $moved.Action;Assert-True $moved.RequiresChoice
    Assert-Equal 'Restore' (Resolve-DomeniaOuRestore 'OU=X,DC=example,DC=invalid' $true).Action
    Assert-Equal 'AskRetry' (Resolve-DomeniaOuRestore 'OU=X,DC=example,DC=invalid' $false '' $true).Action
}
Test-Case 'D040' 'Precedent / suivant restituent le contexte sans relancer de balayage' {
    $h=New-DomeniaNavHistory
    [void](Push-DomeniaNavState $h ([pscustomobject]@{Page='WsSearch';Text='dupont';SelectionGuid='g1';Scroll=120}))
    [void](Push-DomeniaNavState $h ([pscustomobject]@{Page='WsObject';Text='dupont';SelectionGuid='g1';Tab='TabUser'}))
    Assert-False (Push-DomeniaNavState $h ([pscustomobject]@{Page='WsObject';Text='dupont';SelectionGuid='g1';Tab='TabUser'})) 'Meme lieu : pas de nouvelle entree'
    $back=Step-DomeniaNavHistory $h Back
    Assert-True $back.Moved;Assert-Equal 'WsSearch' $back.State.Page;Assert-Equal 120 $back.State.Scroll;Assert-True $back.RestoreWithoutScan
    Assert-Equal 'WsObject' (Step-DomeniaNavHistory $h Forward).State.Page
    Assert-False (Step-DomeniaNavHistory $h Forward).Moved
}
Test-Case 'D040' 'Un brouillon n est pas abandonne par la navigation' {
    $h=New-DomeniaNavHistory
    [void](Push-DomeniaNavState $h ([pscustomobject]@{Page='WsSearch'}));[void](Push-DomeniaNavState $h ([pscustomobject]@{Page='WsObject'}))
    $blocked=Step-DomeniaNavHistory $h Back $true
    Assert-False $blocked.Moved;Assert-True $blocked.Blocked;Assert-Equal 'WsObject' $h.Current.Page
    Assert-True (Step-DomeniaNavHistory $h Back $true $true).Moved
}
Test-Case 'D037' 'Charger la suite : seulement pour une liste limitee, terminee et sous le plafond' {
    $d=Get-DomeniaContinuationDecision $true $false $true 100;Assert-True $d.Allowed;Assert-Equal 200 $d.NextLimit
    Assert-Equal 600 (Get-DomeniaContinuationDecision $true $false $true 300).NextLimit
    Assert-Equal 20000 (Get-DomeniaContinuationDecision $true $false $true 15000).NextLimit
    Assert-False (Get-DomeniaContinuationDecision $true $false $true 20000).Allowed
    Assert-False (Get-DomeniaContinuationDecision $true $false $false 100).Allowed
    Assert-False (Get-DomeniaContinuationDecision $false $false $true 100).Allowed
    Assert-False (Get-DomeniaContinuationDecision $true $true $true 100).Allowed
}
Test-Case 'D033' 'Plan global : jetons explicites seulement, texte inconnu explique sans filtre cache' {
    $type='(objectCategory=computer)'
    $p=Get-DomeniaGlobalSearchPlan 'poste:PC-01' $type 2 $true
    Assert-Equal 'Syntax' $p.Kind;Assert-True ($p.Filter.StartsWith('(&'+$type));Assert-True ($p.Filter.Contains('PC-01*'));Assert-True ($p.Hint -match 'Machine : PC-01')
    $u=Get-DomeniaGlobalSearchPlan 'service:compta dupont' $type 2 $true
    Assert-Equal 'Default' $u.Kind;Assert-Equal '' $u.Filter;Assert-True ($u.Hint -match 'pas un jeton reconnu')
    $off=Get-DomeniaGlobalSearchPlan 'poste:PC-01' $type 2 $false;Assert-Equal 'Default' $off.Kind;Assert-Equal '' $off.Filter
    $empty=Get-DomeniaGlobalSearchPlan 'utilisateur: dupont' $type 2 $true;Assert-Equal 'Default' $empty.Kind;Assert-True ($empty.Hint -match 'sans valeur')
}
Test-Case 'D035' 'Plan global : plusieurs mots exigent chacun une correspondance, sans joker initial' {
    $p=Get-DomeniaGlobalSearchPlan "Jean-Marc O'Neil" '(objectClass=user)' 2 $true
    Assert-True ($p.MultiWordFilter.StartsWith('(&(objectClass=user)(|(cn=Jean-Marc*)'));Assert-True ($p.MultiWordFilter.Contains("(sn=O'Neil*)"))
    Assert-False ($p.MultiWordFilter -match '=\*');Assert-Equal '' (Get-DomeniaGlobalSearchPlan 'dupont' '(objectClass=user)').MultiWordFilter
    Assert-Equal '' (Get-DomeniaGlobalSearchPlan 'jean *pont' '(objectClass=user)').MultiWordFilter
}
Test-Case 'D036' 'Plan global : GUID, SID et DN deviennent une recherche exacte, jamais une ouverture automatique' {
    $type='(objectClass=user)'
    $sid=Get-DomeniaGlobalSearchPlan 'S-1-5-21-1-2-3-1104' $type;Assert-Equal 'Identifier' $sid.Kind;Assert-Equal ('(&'+$type+'(objectSid=S-1-5-21-1-2-3-1104))') $sid.Filter;Assert-False $sid.AutoOpen
    $dn=Get-DomeniaGlobalSearchPlan 'CN=Jean Dupont,OU=Lyon,DC=example,DC=invalid' $type;Assert-Equal 'Identifier' $dn.Kind
    $upn=Get-DomeniaGlobalSearchPlan 'jdupont@example.invalid' $type;Assert-Equal 'Default' $upn.Kind;Assert-True ($upn.Hint.Length -gt 10)
    Assert-Equal 'Default' (Get-DomeniaGlobalSearchPlan 'S-1-5-21-1-2-3-1104' $type 2 $false).Kind
}
Test-Case 'D038' 'Nom de favori construit sans fenetre ni compte' {
    Assert-Equal 'Domaine entier : dupont' (Get-DomeniaFavouriteName Global 'dupont');Assert-Equal 'Vue : Comptes desactives' (Get-DomeniaFavouriteName Global '' '' 'Comptes desactives')
    Assert-Equal 'Postes : PC' (Get-DomeniaFavouriteName OU 'PC' 'Postes');Assert-True ((Get-DomeniaFavouriteName Global ('x'*200)).Length -le 80)
}

# ---------------------------------------------------------------- L03 : arbre des OU, perimetre et vues de travail
Test-Case 'CO-20' 'Postes sans connexion : les postes jamais connectes sont inclus' {
    $now=[datetime]::SpecifyKind([datetime]'2026-01-01',[DateTimeKind]::Utc)
    $stale=@(Get-DomeniaWorkViews $now|Where-Object{$_.Id -eq 'stalecomputers'})[0]
    $limit=$now.AddDays(-90).ToFileTimeUtc()
    Assert-Equal ('(&(objectCategory=computer)(|(lastLogonTimestamp<='+$limit+')(!(lastLogonTimestamp=*))))') $stale.Filter
    Assert-True ($stale.Note -match 'jamais connect') 'La note doit dire que les postes jamais connectes sont inclus'
    $depth=0;foreach($ch in $stale.Filter.ToCharArray()){if($ch -eq '('){$depth++}elseif($ch -eq ')'){$depth--}};Assert-Equal 0 $depth 'Filtre desequilibre'
}
Test-Case 'UX-33' 'Chaque vue de travail s applique a l OU choisie par defaut' {
    $ou='OU=Postes,DC=example,DC=invalid'
    foreach($view in @(Get-DomeniaWorkViews)){
        Assert-True $view.NeedsOu ('Vue sans OU : '+$view.Id)
        $plan=Get-DomeniaWorkViewPlan $view 'OU' $ou $script:DomainDn $true 'Postes'
        Assert-Equal 'OU' $plan.SearchMode $view.Id;Assert-Equal $ou $plan.BaseDn $view.Id;Assert-True $plan.SurveyAllowed $view.Id
        Assert-Equal 'Dans : Postes' $plan.ChipText
    }
}
Test-Case 'UX-33' 'Le domaine entier est un choix explicite, sans releve possible' {
    $view=@(Get-DomeniaWorkViews|Where-Object{$_.Id -eq 'stalecomputers'})[0]
    $domain=Get-DomeniaWorkViewPlan $view 'Domain' 'OU=Postes,DC=example,DC=invalid' $script:DomainDn
    Assert-Equal 'Global' $domain.SearchMode;Assert-Equal $script:DomainDn $domain.BaseDn;Assert-False $domain.SurveyAllowed;Assert-True $domain.WholeDomain
    Assert-True ($domain.Reason -match 'aucun relev') 'Le refus du releve doit etre explique'
    $root=Get-DomeniaWorkViewPlan $view 'OU' $script:DomainDn $script:DomainDn $true
    Assert-False $root.SurveyAllowed 'La racine avec sous-OU vaut le domaine entier';Assert-Equal 'Dans : tout le domaine' $root.ChipText
    Assert-True (Get-DomeniaWorkViewPlan $view 'OU' $script:DomainDn $script:DomainDn $false).SurveyAllowed 'Enfants directs de la racine : pas le domaine entier'
    Assert-Equal $null (Get-DomeniaWorkViewPlan $null 'OU' '' $script:DomainDn)
}
Test-Case 'UI-16' 'Conteneurs systeme regroupes, Users et Computers visibles' {
    $rows=@(
        [pscustomobject]@{Name='Computers';DN=('CN=Computers,'+$script:DomainDn);Kind='Conteneur'}
        [pscustomobject]@{Name='Domain Controllers';DN=('OU=Domain Controllers,'+$script:DomainDn);Kind='OU'}
        [pscustomobject]@{Name='ForeignSecurityPrincipals';DN=('CN=ForeignSecurityPrincipals,'+$script:DomainDn);Kind='Conteneur'}
        [pscustomobject]@{Name='LostAndFound';DN=('CN=LostAndFound,'+$script:DomainDn);Kind='Conteneur'}
        [pscustomobject]@{Name='Program Data';DN=('CN=Program Data,'+$script:DomainDn);Kind='Conteneur'}
        [pscustomobject]@{Name='System';DN=('CN=System,'+$script:DomainDn);Kind='Conteneur'}
        [pscustomobject]@{Name='Users';DN=('CN=Users,'+$script:DomainDn);Kind='Conteneur'}
    )
    $split=Split-DomeniaTreeRows $rows $script:DomainDn $script:DomainDn
    Assert-Equal 'Computers|Domain Controllers|Users' ((@($split.Visible)|ForEach-Object{$_.Name}) -join '|')
    Assert-Equal 'ForeignSecurityPrincipals|LostAndFound|Program Data|System' ((@($split.System)|ForEach-Object{$_.Name}) -join '|')
    $deeper=Split-DomeniaTreeRows @([pscustomobject]@{Name='System';DN=('CN=System,OU=Sites,'+$script:DomainDn);Kind='Conteneur'}) ('OU=Sites,'+$script:DomainDn) $script:DomainDn
    Assert-Equal 1 @($deeper.Visible).Count 'Un conteneur nomme System hors de la racine reste visible'
    Assert-False (Test-DomeniaSystemContainer ('OU=System,'+$script:DomainDn) $script:DomainDn 'OU') 'Une OU nest jamais un conteneur systeme'
}
Test-Case 'PF-14' 'Clavier et type temporises a 300 ms, souris immediate' {
    Assert-Equal 300 (Get-DomeniaTreeSelectionDelay 'Keyboard');Assert-Equal 300 (Get-DomeniaTreeSelectionDelay 'Type')
    Assert-Equal 0 (Get-DomeniaTreeSelectionDelay 'Mouse');Assert-Equal 0 (Get-DomeniaTreeSelectionDelay '')
}
Test-Case 'DS-07' 'Filtre local des OU : litteral, sans casse ni accents' {
    Assert-True (Test-DomeniaOuTreeMatch 'Comptabilité' 'compta');Assert-True (Test-DomeniaOuTreeMatch 'Comptabilité' 'COMPTABILITE')
    Assert-False (Test-DomeniaOuTreeMatch 'Postes' 'compta');Assert-True (Test-DomeniaOuTreeMatch 'Postes' '  ')
    Assert-False (Test-DomeniaOuTreeMatch 'Postes' '*') 'Le joker nest pas interprete'
}
Test-Case 'FO-04' 'Favori d OU : perimetre seulement, domaine verifie' {
    $f=ConvertTo-DomeniaOuFavourite ([pscustomobject]@{DN=('OU=Postes,'+$script:DomainDn);Name='';Subtree='False';Type='Machines';Term='pc';Credential='secret';Rows=@(1,2)}) $script:DomainDn
    Assert-Equal 'Postes' $f.Name;Assert-False $f.Subtree;Assert-Equal 'Machines' $f.Type;Assert-Equal 'pc' $f.Term
    Assert-Equal 'DN,Name,Subtree,Term,Type' ((@($f.PSObject.Properties|ForEach-Object{$_.Name}|Sort-Object)) -join ',')
    Assert-Equal $null (ConvertTo-DomeniaOuFavourite ([pscustomobject]@{DN='OU=Postes,DC=autre,DC=invalid'}) $script:DomainDn) 'Un autre domaine est refuse'
    Assert-Equal $null (ConvertTo-DomeniaOuFavourite ([pscustomobject]@{DN='OU=Postes'}) '') 'Un DN sans domaine est refuse'
    Assert-Equal 'Tous' (ConvertTo-DomeniaOuFavourite ([pscustomobject]@{DN=('OU=Postes,'+$script:DomainDn);Type='Inconnu'})).Type
}
Test-Case 'FO-04' 'Favoris repris une fois des recherches enregistrees, sans perte' {
    $saved=@(
        [pscustomobject]@{SearchMode='OU';Name='Postes : PC';DN=('OU=Postes,'+$script:DomainDn);Query='PC';Type='Machines';Limit=100;Subtree=$false}
        [pscustomobject]@{SearchMode='Global';Name='Domaine entier : dupont';DN=$script:DomainDn;Query='dupont';Type='Tous';Limit=100;Subtree=$true}
        [pscustomobject]@{SearchMode='OU';Name='Postes bis';DN=('OU=Postes,'+$script:DomainDn);Query='';Type='Tous';Limit=100;Subtree=$true}
        [pscustomobject]@{SearchMode='OU';Name='Lyon';DN=('OU=Lyon,'+$script:DomainDn);Query='';Type='Tous';Limit=100;Subtree=$true}
    )
    $existing=@([pscustomobject]@{DN=('OU=Lyon,'+$script:DomainDn);Name='Mon Lyon';Subtree=$true;Type='Tous';Term=''})
    $r=Import-DomeniaOuFavourites $existing $saved
    Assert-Equal 1 $r.Imported 'Une seule OU nouvelle : la recherche globale et les doublons ne sont pas repris'
    Assert-Equal 'Mon Lyon|Postes : PC' ((@($r.Favourites)|ForEach-Object{$_.Name}) -join '|')
    $postes=@($r.Favourites)[1];Assert-Equal 'PC' $postes.Term 'Le terme passe au filtre local visible';Assert-False $postes.Subtree;Assert-Equal 'Machines' $postes.Type
    Assert-Equal 4 $saved.Count 'Les recherches enregistrees restent intactes'
    Assert-Equal 0 (Import-DomeniaOuFavourites @() @()).Imported
}
Test-Case 'FO-04' 'Epingler et retirer une OU, borne a 50' {
    $fav=[pscustomobject]@{DN=('OU=Postes,'+$script:DomainDn);Name='Postes'}
    $pin=Set-DomeniaOuFavouriteState @() $fav $true $script:DomainDn;Assert-True $pin.Changed;Assert-Equal 1 @($pin.Favourites).Count
    $again=Set-DomeniaOuFavouriteState $pin.Favourites $fav $true $script:DomainDn;Assert-False $again.Changed;Assert-True ($again.Reason -match 'déjà')
    $off=Set-DomeniaOuFavouriteState $pin.Favourites $fav $false $script:DomainDn;Assert-True $off.Changed;Assert-Equal 0 @($off.Favourites).Count
    $outside=Set-DomeniaOuFavouriteState @() ([pscustomobject]@{DN='OU=X,DC=autre,DC=invalid'}) $true $script:DomainDn;Assert-False $outside.Changed
    $full=@(1..50|ForEach-Object{[pscustomobject]@{DN=('OU=O'+$_+','+$script:DomainDn);Name=('O'+$_)}})
    $over=Set-DomeniaOuFavouriteState $full $fav $true $script:DomainDn;Assert-False $over.Changed;Assert-True ($over.Reason -match '50')
}
Test-Case 'FO-04' 'Le plafond de 50 favoris compte le seul domaine de l OU' {
    Assert-Equal 'dc=example,dc=invalid' (Get-DomeniaDnDomainKey ('OU=A,OU=B,'+$script:DomainDn));Assert-Equal '' (Get-DomeniaDnDomainKey 'OU=A')
    $other=@(1..50|ForEach-Object{[pscustomobject]@{DN=('OU=O'+$_+',DC=autre,DC=invalid');Name=('O'+$_)}})
    $pin=Set-DomeniaOuFavouriteState $other ([pscustomobject]@{DN=('OU=Postes,'+$script:DomainDn);Name='Postes'}) $true $script:DomainDn
    Assert-True $pin.Changed 'Les favoris d un autre domaine, invisibles ici, ne bloquent pas l epinglage';Assert-Equal 51 @($pin.Favourites).Count
    $saved=@(1..3|ForEach-Object{[pscustomobject]@{SearchMode='OU';Name=('S'+$_);DN=('OU=S'+$_+','+$script:DomainDn)}})
    $r=Import-DomeniaOuFavourites $other $saved
    Assert-Equal 3 $r.Imported 'La reprise compte par domaine';Assert-Equal 53 @($r.Favourites).Count
    $same=@(1..50|ForEach-Object{[pscustomobject]@{DN=('OU=O'+$_+','+$script:DomainDn);Name=('O'+$_)}})
    Assert-Equal 0 (Import-DomeniaOuFavourites $same $saved).Imported 'Domaine deja plein : rien n est repris'
}
# W08 navigation (points 52 to 55). Donnees fictives uniquement.
Test-Case 'P52' 'Deux OU de meme nom se distinguent par leur parent le plus proche' {
    $dns=@(('OU=Postes,OU=Lyon,OU=Sites,'+$script:DomainDn),('OU=Postes,OU=Paris,OU=Sites,'+$script:DomainDn),('OU=Serveurs,'+$script:DomainDn))
    $labels=@(Get-DomeniaOuDistinctLabels -Dn $dns)
    Assert-Equal 3 $labels.Count;Assert-Equal 'Postes (Lyon)' $labels[0].Label;Assert-Equal 'Postes (Paris)' $labels[1].Label
    Assert-True $labels[0].Ambiguous;Assert-Equal 'Serveurs' $labels[2].Label;Assert-False $labels[2].Ambiguous
    Assert-Equal $dns[0] $labels[0].DN 'Le DN exact reste l identite'
}
Test-Case 'P52' 'Meme parent direct : le libelle remonte jusqu au premier parent different' {
    $dns=@(('OU=Postes,OU=Nord,OU=Lyon,'+$script:DomainDn),('OU=Postes,OU=Nord,OU=Paris,'+$script:DomainDn),('OU=Postes,'+$script:DomainDn))
    $labels=@(Get-DomeniaOuDistinctLabels -Dn $dns)
    Assert-Equal 'Postes (Lyon / Nord)' $labels[0].Label;Assert-Equal 'Postes (Paris / Nord)' $labels[1].Label
    Assert-Equal 'Postes (racine du domaine)' $labels[2].Label
}
Test-Case 'P52' 'Libelles : doublons, casse, valeurs echappees et noms identiques jusqu au domaine' {
    $labels=@(Get-DomeniaOuDistinctLabels -Dn @(('OU=A\,B,'+$script:DomainDn),('ou=a\,b,'+$script:DomainDn.ToLowerInvariant()),'',('OU=Postes,DC=autre,DC=invalid'),('OU=Postes,'+$script:DomainDn)))
    Assert-Equal 3 $labels.Count 'Un meme DN en casse differente compte une fois et une valeur vide est ignoree'
    Assert-Equal 'A,B' $labels[0].Label 'La virgule echappee fait partie du nom'
    Assert-True ($labels[1].Label.StartsWith('Postes (') -and $labels[1].Label -ne $labels[2].Label) ('Libelles : '+$labels[1].Label+' / '+$labels[2].Label)
    Assert-Equal 'P' (@(Get-DomeniaOuPathNames ('OU=P,OU=Q,'+$script:DomainDn)))[0];Assert-Equal 2 @(Get-DomeniaOuPathNames ('OU=P,OU=Q,'+$script:DomainDn)).Count
}
Test-Case 'P54' 'Le choix d OU dit le chemin, la portee imposee ou choisie et la verification' {
    $dn='OU=Postes,OU=Lyon,'+$script:DomainDn
    $fixed=Get-DomeniaOuChoiceSummary -Dn $dn -DomainDn $script:DomainDn -DepthMode Subtree -Purpose 'La base relira cette branche.'
    Assert-True ($fixed.Contains('example.invalid / Lyon / Postes') -and $fixed.Contains('imposée') -and $fixed.Contains('La base relira') -and $fixed.Contains('revérifie')) $fixed
    Assert-True ((Get-DomeniaOuChoiceSummary -Dn $dn -DomainDn $script:DomainDn -DepthMode Choice -Subtree $false).Contains('sans ses sous-OU'))
    Assert-True ((Get-DomeniaOuChoiceSummary -Dn $dn -DomainDn $script:DomainDn -DepthMode Choice -Subtree $true).Contains('et ses sous-OU'))
    Assert-False ((Get-DomeniaOuChoiceSummary -Dn $dn -DomainDn $script:DomainDn -DepthMode None).Contains('Portée')) 'Une page sans profondeur n en affiche pas'
    Assert-True ((Get-DomeniaOuChoiceSummary -Dn '' -DomainDn $script:DomainDn).StartsWith('Aucune OU'))
    Assert-True ((Get-DomeniaOuChoiceSummary -Dn 'OU=X,DC=autre,DC=invalid' -DomainDn $script:DomainDn).Contains('nʼappartient pas'))
}
Test-Case 'P55' 'Identite d une ligne : GUID, sinon DN exact, sinon aucune' {
    Assert-Equal 'g:11111111-1111-1111-1111-111111111111' (Get-DomeniaNavRowKey ([pscustomobject]@{Guid='{11111111-1111-1111-1111-111111111111}';DN='CN=A'}))
    Assert-Equal ('d:cn=a,'+$script:DomainDn.ToLowerInvariant()) (Get-DomeniaNavRowKey ([pscustomobject]@{Guid='';DN=('CN=A,'+$script:DomainDn)}))
    Assert-Equal '' (Get-DomeniaNavRowKey ([pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000';DN=''}))
    Assert-Equal '' (Get-DomeniaNavRowKey $null)
}
Test-Case 'P55' 'Selection memorisee : ordre, doublons, lignes sans identite et borne' {
    $rows=@([pscustomobject]@{Guid='22222222-2222-2222-2222-222222222222';DN='CN=B'},[pscustomobject]@{Guid='';DN='CN=A'},[pscustomobject]@{Guid='22222222-2222-2222-2222-222222222222';DN='CN=B'},[pscustomobject]@{Guid='';DN=''})
    $r=Get-DomeniaNavSelectionKeys -Rows $rows
    Assert-Equal 2 @($r.Keys).Count;Assert-Equal 'g:22222222-2222-2222-2222-222222222222' $r.Keys[0];Assert-Equal 1 $r.Unidentified;Assert-False $r.Truncated
    $many=@(1..12|ForEach-Object{[pscustomobject]@{Guid='';DN=('CN=R'+$_)}})
    $b=Get-DomeniaNavSelectionKeys -Rows $many -Maximum 10;Assert-Equal 10 @($b.Keys).Count;Assert-True $b.Truncated
}
Test-Case 'P55' 'Tri memorise : champs valides, sans doublon, borne a huit' {
    $sort=@(Get-DomeniaNavSortState -Sort @([pscustomobject]@{Field='Name';Direction='Descending'},[pscustomobject]@{Field='Name';Direction='Ascending'},[pscustomobject]@{Field='a b';Direction='Ascending'},[pscustomobject]@{Field='OS';Direction='Sideways'},[pscustomobject]@{Field='LastLogonSort';Direction='Ascending'}))
    Assert-Equal 2 $sort.Count;Assert-Equal 'Name' $sort[0].Field;Assert-Equal 'Descending' $sort[0].Direction;Assert-Equal 'LastLogonSort' $sort[1].Field
    Assert-Equal 8 @(Get-DomeniaNavSortState -Sort @(1..12|ForEach-Object{[pscustomobject]@{Field=('F'+$_);Direction='Ascending'}})).Count
    Assert-Equal 0 @(Get-DomeniaNavSortState -Sort @()).Count
}
Test-Case 'P55' 'Branches ouvertes : seules les branches lues se rouvrent, les autres se replient, aucune lecture' {
    $a='OU=A,'+$script:DomainDn;$b='OU=B,'+$script:DomainDn;$c='OU=C,'+$script:DomainDn;$d='OU=D,'+$script:DomainDn
    $nodes=@([pscustomobject]@{DN=$a;Loaded=$true;Expanded=$false},[pscustomobject]@{DN=$b;Loaded=$true;Expanded=$true},[pscustomobject]@{DN=$c;Loaded=$false;Expanded=$false},[pscustomobject]@{DN='';Loaded=$true;Expanded=$true})
    $plan=Get-DomeniaNavTreePlan -Remembered @($a.ToUpperInvariant(),$c,$d) -Nodes $nodes
    Assert-Equal 1 @($plan.Expand).Count;Assert-Equal $a $plan.Expand[0] 'La branche lue et fermee se rouvre'
    Assert-Equal 1 @($plan.Collapse).Count;Assert-Equal $b $plan.Collapse[0] 'La branche ouverte depuis se replie'
    Assert-Equal 2 $plan.UnreadCount 'Une branche non lue ou absente est comptee, jamais lue'
    $none=Get-DomeniaNavTreePlan -Remembered @() -Nodes @();Assert-Equal 0 @($none.Expand).Count;Assert-Equal 0 $none.UnreadCount
}
Test-Case 'P54' 'Favoris proposes par le selecteur d OU : domaine de la session, sans la racine, libelles distincts' {
    $favs=@([pscustomobject]@{DN=('OU=Postes,OU=Lyon,'+$script:DomainDn);Name='Postes'},[pscustomobject]@{DN=$script:DomainDn;Name='Domaine'},
        [pscustomobject]@{DN='OU=Postes,DC=autre,DC=invalid';Name='Postes'},[pscustomobject]@{DN=('OU=Postes,OU=Paris,'+$script:DomainDn);Name='Postes'},
        [pscustomobject]@{DN=('ou=postes,ou=lyon,'+$script:DomainDn.ToLowerInvariant());Name='Doublon'},[pscustomobject]@{DN=('OU=Serveurs,'+$script:DomainDn);Name='Serveurs'})
    $choices=@(Get-DomeniaOuFavouriteChoices -Favourites $favs -DomainDn $script:DomainDn)
    Assert-Equal 3 $choices.Count 'Racine, autre domaine et doublon ecartes'
    Assert-Equal 'Postes (Lyon)' $choices[0].Label;Assert-Equal 'Postes (Paris)' $choices[1].Label;Assert-Equal 'Serveurs' $choices[2].Label
    Assert-Equal 'example.invalid / Lyon / Postes' $choices[0].FullPath
    Assert-Equal 0 @(Get-DomeniaOuFavouriteChoices -Favourites @() -DomainDn $script:DomainDn).Count
}
