# Lot X03 (connexion et comptes) : regles de presentation pures. Aucune fenetre, aucun compte reel, aucun reseau.
# Les identites et les codes sont des donnees synthetiques (domaine example.invalid).
. (Join-Path $modules 'Domenia-Accounts.Model.ps1')

# ---------------------------------------------------------------- UI-20 refus de connexion en clair
Test-Case 'X03-UI20' 'Compte verrouille : phrase vouvoyee avec action, code AD seulement pour le diagnostic' {
    $raw='Ce compte est verrouille (code AD 775). Arrete les essais et verifie son etat. (HRESULT=0x8007052E; serveur=dc1.example.invalid)'
    $r=Get-DomeniaLoginFailureText -Category 'AccountRestriction' -Message $raw
    Assert-Equal 'Locked' $r.Kind
    Assert-Equal 'Compte verrouillé. Demandez son déverrouillage puis réessayez.' $r.Text
    Assert-Equal '775' $r.Code
    Assert-False ($r.Text -match '775|0x8007|code AD') 'Le code AD apparait a l ecran'
}
Test-Case 'X03-UI20' 'Identifiants refuses : 52e, HRESULT seul ou texte anglais donnent la meme phrase' {
    foreach($raw in @('Identifiant ou mot de passe refuse (code AD 52e). (HRESULT=0x8007052E; serveur=dc1)','TEST invalid credentials','Logon failure: unknown user name or bad password.','x (HRESULT=0x8007052E; serveur=dc1)')){
        $r=Get-DomeniaLoginFailureText -Category 'Credentials' -Message $raw
        Assert-Equal 'BadCredentials' $r.Kind $raw
        Assert-Equal 'Identifiant ou mot de passe refusé. Vérifiez la saisie avant un nouvel essai.' $r.Text $raw
    }
}
Test-Case 'X03-UI20' 'Chaque sous-code AD connu a sa phrase et garde son code pour le diagnostic' {
    $expected=@{'525'='UnknownAccount';'52f'='Restricted';'530'='Hours';'531'='Workstation';'532'='PasswordExpired';'533'='Disabled';'701'='AccountExpired';'773'='MustChange';'775'='Locked'}
    foreach($code in @($expected.Keys)){
        $r=Get-DomeniaLoginFailureText -Category 'AccountRestriction' -Message ('AcceptSecurityContext error, data '+$code+', v3839')
        Assert-Equal $expected[$code] $r.Kind ('code '+$code)
        Assert-Equal $code $r.Code ('code '+$code)
        Assert-False ($r.Text.Contains($code)) ('Code affiche : '+$code)
        Assert-True ($r.Text.EndsWith('.')) ('Phrase incomplete : '+$r.Text)
    }
}
Test-Case 'X03-UI20' 'Restriction lue par HRESULT seul : jamais presentee comme un mauvais mot de passe' {
    $r=Get-DomeniaLoginFailureText -Category 'AccountRestriction' -Message 'Connexion interdite depuis ce poste pour ce compte. (HRESULT=0x80070531; serveur=dc1)'
    Assert-Equal 'Workstation' $r.Kind
    Assert-Equal '0x80070531' $r.Code
    Assert-False ($r.Text -match '(?i)mot de passe refus|incorrect') $r.Text
}
Test-Case 'X03-UI20' 'Code 52f : le changement de mot de passe est la premiere piste donnee' {
    $r=Get-DomeniaLoginFailureText -Category 'AccountRestriction' -Message 'Connexion refusee par une restriction du compte (code AD 52f). (HRESULT=0x8007052E; serveur=w-ro.example.invalid)'
    Assert-Equal 'Restricted' $r.Kind
    Assert-True ($r.Hint.Contains('Ctrl+Alt+Suppr')) $r.Hint
    Assert-False ($r.Text -match '(?i)incorrect') $r.Text
}
Test-Case 'X03-UI20' 'Un code dans le nom du controleur ne cree pas de faux verrouillage' {
    $r=Get-DomeniaLoginFailureText -Message 'TEST serveur=dc775.example.invalid'
    Assert-Equal 'Unknown' $r.Kind
    Assert-Equal '' $r.Code
    Assert-False ($r.Text -match '(?i)verrouill') $r.Text
}
Test-Case 'X03-UI20' 'Erreur interne : categorie prioritaire, aucun verdict sur le mot de passe' {
    foreach($raw in @('Indexation impossible dans un tableau Null.','Cannot index into a null array.','Mot de passe incorrect ? Diagnostic interne.')){
        $category=if($raw -like 'Mot*'){'Internal'}else{''}
        $r=Get-DomeniaLoginFailureText -Category $category -Message $raw
        Assert-Equal 'Internal' $r.Kind $raw
        Assert-True ($r.Hint.Contains('ne prouve pas un mauvais mot de passe')) $r.Hint
    }
}
Test-Case 'X03-UI20' 'Refus de lecture, reseau et delai : orientation distincte des identifiants' {
    $denied=Get-DomeniaLoginFailureText -Category 'AccessDenied' -Message 'TEST_REFRESH_ACCESS_DENIED'
    Assert-Equal 'AccessDenied' $denied.Kind
    Assert-True ($denied.Hint -match 'droits du compte') $denied.Hint
    Assert-False ($denied.Text -match 'DNS|mot de passe') $denied.Text
    foreach($c in @('DomainUnavailable','Timeout')){
        $r=Get-DomeniaLoginFailureText -Category $c -Message 'Controleur injoignable'
        Assert-True ($r.Hint -match 'réseau, le DNS ou le VPN') ($c+' : '+$r.Hint)
    }
}
Test-Case 'X03-UI20' 'Saisie incomplete, demonstration et message vide : phrases propres' {
    Assert-Equal 'Identifiant ou mot de passe manquant. Complétez les champs demandés.' (Get-DomeniaLoginFailureText -Category 'Input' -Message 'Identifiant ou mot de passe manquant.').Text
    Assert-True ((Get-DomeniaLoginFailureText -Category 'Input' -Message 'Identite de demonstration attendue (DEMO\nom).').Message.StartsWith('Identité de démonstration'))
    Assert-Equal 'Échec de validation du compte.' (Get-DomeniaLoginFailureText).Message
}
Test-Case 'X03-UI20' 'Aucune phrase tutoyee, sans accent ou avec un code technique' {
    $samples=@('code AD 525','code AD 52e','code AD 52f','code AD 530','code AD 531','code AD 532','code AD 533','code AD 701','code AD 773','code AD 775','x')
    $texts=New-Object 'System.Collections.Generic.List[string]'
    foreach($s in $samples){$texts.Add((Get-DomeniaLoginFailureText -Message $s).Text)}
    foreach($c in @('Internal','Metadata','AccessDenied','DomainUnavailable','Timeout','Authentication','Input','Credentials','AccountRestriction')){$texts.Add((Get-DomeniaLoginFailureText -Category $c -Message 'x').Text)}
    foreach($t in $texts){
        Assert-False ($t -match '(?<![\w])(tu|ton|ta|tes|Verifie|Consulte|Arrete|Corrige|Ouvre)(?![\w])') ('Tutoiement : '+$t)
        Assert-False ($t -match '(?i)\b(verrouille|desactive|refuse|reessayez|acces|delai|etape)\b') ('Accent manquant : '+$t)
        Assert-False ($t -match '(?i)HRESULT|0x8007|LDAP=') ('Technique : '+$t)
    }
}

# ---------------------------------------------------------------- UX-28 la session Windows d abord
Test-Case 'X03-UX28' 'Session de domaine : Continuer en tant que DOMAINE\nom devient l action principale' {
    $c=Get-DomeniaLoginChoice -WindowsIdentity ' EXAMPLE\jdupont ' -AllowWindowsSession $true
    Assert-True ($c.Offered -and $c.Available -and $c.WindowsFirst) 'Session Windows non proposee en premier'
    Assert-Equal 'Continuer en tant que EXAMPLE\jdupont' $c.WindowsLabel
    Assert-True ($c.WindowsToolTip.Contains('EXAMPLE\jdupont') -and $c.WindowsToolTip.Contains('sans mot de passe')) $c.WindowsToolTip
    Assert-Equal 'Utiliser un autre compte' $c.OtherAccountLabel
}
Test-Case 'X03-UX28' 'Changement de compte : le formulaire d abord, la session Windows reste proposee dessous' {
    $c=Get-DomeniaLoginChoice -WindowsIdentity 'EXAMPLE\jdupont' -PreferForm $true
    Assert-True ($c.Available -and (-not $c.WindowsFirst)) 'Formulaire non prioritaire'
    Assert-Equal 'Continuer en tant que EXAMPLE\jdupont' $c.WindowsLabel
}
Test-Case 'X03-UX28' 'Hors session de domaine, session interdite ou demonstration : formulaire seul' {
    $none=Get-DomeniaLoginChoice -WindowsIdentity ''
    Assert-True ($none.Offered -and (-not $none.Available) -and (-not $none.WindowsFirst)) 'Session absente proposee'
    Assert-Equal 'Utiliser mon compte Windows' $none.WindowsLabel
    Assert-True ($none.WindowsToolTip.StartsWith('Indisponible')) $none.WindowsToolTip
    $off=Get-DomeniaLoginChoice -WindowsIdentity 'EXAMPLE\jdupont' -AllowWindowsSession $false
    Assert-True ((-not $off.Offered) -and (-not $off.Available) -and (-not $off.WindowsFirst)) 'Auth.AllowWindowsSession ignore'
    $demo=Get-DomeniaLoginChoice -WindowsIdentity 'EXAMPLE\jdupont' -Demo $true
    Assert-True ((-not $demo.Offered) -and (-not $demo.WindowsFirst)) 'Session Windows proposee en demonstration'
}
