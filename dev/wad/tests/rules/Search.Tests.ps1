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
Test-Case 'CO-33' 'Une barre oblique dans un DN est echappee dans le chemin ADSI, sans double echappement' {
    Assert-Equal 'OU=Compta\/Paie,DC=x' (ConvertTo-DomeniaAdsPathDn 'OU=Compta/Paie,DC=x')
    Assert-Equal 'OU=Compta\/Paie,DC=x' (ConvertTo-DomeniaAdsPathDn 'OU=Compta\/Paie,DC=x') 'Un DN deja echappe reste inchange'
    Assert-Equal ('OU=Lyon,'+$script:DomainDn) (ConvertTo-DomeniaAdsPathDn ('OU=Lyon,'+$script:DomainDn)) 'Un DN sans barre oblique reste inchange'
    Assert-Equal 'CN=Dupont\, Jean\/RH,OU=A\/B\/C,DC=x' (ConvertTo-DomeniaAdsPathDn 'CN=Dupont\, Jean/RH,OU=A/B\/C,DC=x') 'Virgule echappee conservee, chaque barre echappee une fois'
    Assert-Equal 'OU=Back\\\/x,DC=x' (ConvertTo-DomeniaAdsPathDn 'OU=Back\\/x,DC=x') 'Une contre-oblique echappee ne protege pas la barre qui suit'
    Assert-Equal 'OU=\C3\89quipe\/Paie,DC=x' (ConvertTo-DomeniaAdsPathDn 'OU=\C3\89quipe/Paie,DC=x') 'Les paires hexadecimales restent intactes'
    Assert-Equal '' (ConvertTo-DomeniaAdsPathDn $null);Assert-Equal '' (ConvertTo-DomeniaAdsPathDn '')
}
Test-Case 'CO-34' 'Etoiles consecutives fusionnees dans un litteral LDAP avec joker' {
    Assert-Equal 'jean*' (ConvertTo-DomeniaLdapLiteral 'jean**' -KeepWildcard)
    Assert-Equal 'a*b' (ConvertTo-DomeniaLdapLiteral 'a**b' -KeepWildcard)
    Assert-Equal '*a*' (ConvertTo-DomeniaLdapLiteral '***a***' -KeepWildcard)
    Assert-Equal '*\28*' (ConvertTo-DomeniaLdapLiteral '**(**' -KeepWildcard) 'Un caractere echappe separe deux jokers'
    Assert-Equal 'a\2a\2ab' (ConvertTo-DomeniaLdapLiteral 'a**b') 'Sans joker, chaque etoile reste un caractere echappe'
    $f=Get-DomeniaWordFilter 'jean**'
    Assert-False ($f -match '\*\*') ('Double joker envoye : '+$f);Assert-True ($f.Contains('(cn=jean*)'))
}
Test-Case 'CO-34' 'Un texte fait seulement d etoiles est refuse en global et liste l OU en parcours' {
    Assert-True (Test-DomeniaWildcardOnly '***');Assert-True (Test-DomeniaWildcardOnly ' * * ')
    Assert-False (Test-DomeniaWildcardOnly '');Assert-False (Test-DomeniaWildcardOnly 'a*');Assert-False (Test-DomeniaWildcardOnly $null)
    $g=Get-DomeniaSearchTextCheck '***' Global 2
    Assert-False $g.Valid;Assert-Equal 'Saisissez au moins un caractère en plus de * : une étoile seule listerait tout le domaine.' $g.Reason
    $o=Get-DomeniaSearchTextCheck '**' OU 2;Assert-True $o.Valid;Assert-True $o.Browse 'Dans une OU, des etoiles seules listent l OU'
    Assert-False (Get-DomeniaSearchTextCheck 'a*' Global 2).Valid 'Les etoiles ne comptent pas dans le minimum'
    Assert-True ((Get-DomeniaSearchTextCheck 'a' OU 2).Reason.Contains('ou * pour lister toute'))
    Assert-False ((Get-DomeniaSearchTextCheck 'a' Global 2).Reason.Contains('*')) 'L aide globale ne propose pas l etoile'
    $ok=Get-DomeniaSearchTextCheck 'jean**' Global 2;Assert-True $ok.Valid;Assert-False $ok.Browse
    Assert-True (Get-DomeniaSearchTextCheck '' Global 2).Browse
    Assert-False ((Get-DomeniaSearchTextCheck 'a' Global 2).Reason -match '\bSaisis\b') 'Message vouvoye'
}
Test-Case 'FO-05' 'La puce de la barre ne nomme qu une OU du domaine, sous-OU incluses' {
    $ou='OU=Postes,OU=Lyon,'+$script:DomainDn
    $b=Get-DomeniaSearchBarScope -Choice Ou -OuDn $ou -DomainDn $script:DomainDn
    Assert-True $b.Explicit;Assert-Equal $ou $b.BaseDn;Assert-Equal 'Subtree' $b.Scope;Assert-False $b.IsDomain
    $root=Get-DomeniaSearchBarScope -Choice Ou -OuDn $script:DomainDn -DomainDn $script:DomainDn
    Assert-False $root.Explicit 'La racine du domaine reste Partout';Assert-Equal $script:DomainDn $root.BaseDn;Assert-False $root.OuAvailable
    $other=Get-DomeniaSearchBarScope -Choice Ou -OuDn 'OU=X,DC=autre,DC=invalid' -DomainDn $script:DomainDn
    Assert-False $other.Explicit 'Une OU d un autre domaine est refusee';Assert-False $other.OuAvailable
    $none=Get-DomeniaSearchBarScope -Choice Ou -OuDn '' -DomainDn $script:DomainDn;Assert-False $none.Explicit
    $everywhere=Get-DomeniaSearchBarScope -Choice Everywhere -OuDn $ou -DomainDn $script:DomainDn
    Assert-False $everywhere.Explicit;Assert-True $everywhere.OuAvailable 'Partout garde la possibilite de choisir Dans'
}
Test-Case 'FO-05' 'Le texte d attente et le resume disent le perimetre et le type' {
    $a=Get-DomeniaSearchBarText -Choice Everywhere -Type Tous
    Assert-Equal 'Personne, poste ou groupe, dans tout le domaine…' $a.Placeholder;Assert-Equal 'Partout' $a.Chip
    Assert-Equal 'Recherche · Partout · Tous les types · Aucun filtre de liste' $a.Summary
    $b=Get-DomeniaSearchBarText -Choice Ou -OuName 'Postes' -Type Machines
    Assert-Equal 'Poste, dans « Postes » et ses sous-OU…' $b.Placeholder;Assert-Equal 'Dans « Postes »' $b.Chip
    Assert-Equal 'Recherche · Dans « Postes » · Postes · Aucun filtre de liste' $b.Summary
    Assert-Equal 'Personnes' (Get-DomeniaSearchBarText -Type Utilisateurs).TypeLabel
    Assert-Equal 'Tout' (@(Get-DomeniaSearchBarTypes)[0]).Label;Assert-Equal 4 @(Get-DomeniaSearchBarTypes).Count
}
Test-Case 'FO-05' 'Le contrat global accepte une OU nommee par la puce et refuse une OU heritee' {
    $ou='OU=Postes,'+$script:DomainDn
    $r=New-DomeniaGlobalSearchRequest 'dupont' $script:DomainDn 100 'reader' 4 -ScopeDn $ou -OuName 'Postes' -Type Machines
    Assert-Equal $ou $r.BaseDn;Assert-Equal $ou $r.ExplicitScopeDn;Assert-True (Test-DomeniaGlobalSearchRequest $r $script:DomainDn)
    Assert-True ($r.ScopeLabel.Contains('Postes'));Assert-True ($r.Filter.Contains('(objectCategory=computer)')) 'Le type de la barre restreint le filtre'
    $inherited=$r.PSObject.Copy();$inherited.ExplicitScopeDn='';Assert-False (Test-DomeniaGlobalSearchRequest $inherited $script:DomainDn) 'Une OU sans puce est heritee'
    $outside=$r.PSObject.Copy();$outside.BaseDn='OU=X,DC=autre,DC=invalid';$outside.ExplicitScopeDn='OU=X,DC=autre,DC=invalid'
    Assert-False (Test-DomeniaGlobalSearchRequest $outside $script:DomainDn) 'Une OU d un autre domaine est refusee'
    $oneLevel=$r.PSObject.Copy();$oneLevel.Scope='OneLevel';Assert-False (Test-DomeniaGlobalSearchRequest $oneLevel $script:DomainDn)
    $plain=New-DomeniaGlobalSearchRequest 'dupont' $script:DomainDn;Assert-Equal $script:DomainDn $plain.BaseDn;Assert-Equal '' $plain.ExplicitScopeDn
}
