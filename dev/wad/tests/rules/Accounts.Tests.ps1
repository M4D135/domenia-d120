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

# ---------------------------------------------------------------- CO-31 carte Annuaire en lecture seule
Test-Case 'X03-CO31' 'Carte Annuaire : identite liee, mode, controleur et domaine, sans champ a modifier' {
    $c=Get-DomeniaDirectoryAccountText -Account ' EXAMPLE\jdupont ' -AuthMode 'Windows' -Server 'dc1.example.invalid' -Domain 'example.invalid'
    Assert-True $c.Connected 'Session non reconnue'
    Assert-Equal 'EXAMPLE\jdupont' $c.Identity
    Assert-Equal 'Session Windows · contrôleur dc1.example.invalid · domaine example.invalid' $c.Detail
    Assert-Equal 'Compte saisi à la connexion' (Get-DomeniaDirectoryAccountText -Account 'EXAMPLE\adm' -AuthMode 'Explicit').Detail
    Assert-True ((Get-DomeniaDirectoryAccountText -Account 'DEMO\demo' -AuthMode 'Demo').Mode.StartsWith('Démonstration'))
}
Test-Case 'X03-CO31' 'Sans connexion : le seul chemin propose est Changer de compte' {
    $c=Get-DomeniaDirectoryAccountText -Account '' -AuthMode 'Explicit' -Server 'dc1.example.invalid'
    Assert-False $c.Connected 'Connexion inventee'
    Assert-Equal 'Aucune identité active.' $c.Identity
    Assert-True ($c.Detail.Contains('« Changer de compte »')) $c.Detail
}

# ---------------------------------------------------------------- UX-15 / UI-27 / FO-19 compte des postes
Test-Case 'X03-FO19' 'Compte des postes nomme selon sa source, jamais de secret' {
    Assert-Equal 'Compte poste : session Windows ▾' (Get-DomeniaMachineAccountLabel -Source 'Windows' -Account 'EXAMPLE\jdupont').Pill
    Assert-Equal 'session Windows (EXAMPLE\jdupont)' (Get-DomeniaMachineAccountLabel -Source 'Windows' -Account 'EXAMPLE\jdupont').Long
    $typed=Get-DomeniaMachineAccountLabel -Source 'Typed' -Account 'EXAMPLE\adm-poste'
    Assert-Equal 'Compte poste : EXAMPLE\adm-poste ▾' $typed.Pill
    Assert-Equal 'EXAMPLE\adm-poste (compte poste saisi, en mémoire seulement)' $typed.Long
    Assert-Equal 'compte Postes de la page Comptes' (Get-DomeniaMachineAccountLabel -Source 'Remote' -Account 'x').Origin
    Assert-Equal 'compte de connexion' (Get-DomeniaMachineAccountLabel -Source 'Connection' -Account 'x').Origin
    Assert-Equal 'compte local temporaire de ce poste' (Get-DomeniaMachineAccountLabel -Source 'TemporaryLocal' -Account 'PC-01\admin').Origin
    Assert-Equal 'Windows' (Get-DomeniaMachineAccountLabel -Source 'Inconnue').Source
}
Test-Case 'X03-FO19' 'Essai sur un poste : seul un succes explicite dit acces administrateur OK' {
    $ok=Get-DomeniaRemoteAccessTrialVerdict -Outcome 'NotRequested' -Computer 'PC-01' -Account 'EXAMPLE\adm' -Caption 'Windows 11 Pro'
    Assert-True $ok.Success 'Succes non reconnu'
    Assert-Equal 'Accès administrateur OK sur PC-01 avec EXAMPLE\adm. Système : Windows 11 Pro.' $ok.Text
    Assert-False (Get-DomeniaRemoteAccessTrialVerdict -Outcome 'NotRequested' -ErrorText 'Lecture du système non renvoyée par le poste.' -Computer 'PC-01').Success 'Lecture absente prise pour un succes'
    Assert-False (Get-DomeniaRemoteAccessTrialVerdict -Outcome 'Unavailable' -Computer 'PC-01').Success 'Echec sans motif pris pour un succes'
}
Test-Case 'X03-FO19' 'Refus classes : droit administrateur, identifiants, etat du compte, poste injoignable' {
    $denied=Get-DomeniaRemoteAccessTrialVerdict -Outcome 'Denied' -Computer 'PC-01' -Account 'EXAMPLE\adm'
    Assert-Equal 'Denied' $denied.Verdict
    Assert-Equal 'Accès refusé sur PC-01 avec EXAMPLE\adm : droit administrateur requis sur ce poste.' $denied.Text
    Assert-Equal 'Denied' (Get-DomeniaRemoteAccessTrialVerdict -Outcome 'NotRequested' -ErrorText 'Accès refusé.' -Category 'AccessDenied').Verdict
    Assert-Equal 'Rejected' (Get-DomeniaRemoteAccessTrialVerdict -Outcome 'AuthRejected').Verdict
    Assert-Equal 'Rejected' (Get-DomeniaRemoteAccessTrialVerdict -Outcome 'Unavailable' -ErrorText 'Logon failure' -Category 'CredentialsRejected').Verdict
    Assert-Equal 'AccountState' (Get-DomeniaRemoteAccessTrialVerdict -Outcome 'Unavailable' -Category 'AccountState').Verdict
    foreach($case in @(@('Timeout',''),@('Unavailable','Network'),@('Unavailable',''))){
        $text=if($case[1]){''}else{'The RPC server is unavailable. (0x800706BA)'}
        $r=Get-DomeniaRemoteAccessTrialVerdict -Outcome $case[0] -Category $case[1] -ErrorText $text -Computer 'PC-01'
        Assert-Equal 'Unreachable' $r.Verdict ($case -join '/')
        Assert-True ($r.Text.StartsWith('Poste PC-01 injoignable')) $r.Text
    }
    $unknown=Get-DomeniaRemoteAccessTrialVerdict -Outcome 'Unavailable' -ErrorText ('x'*400) -Computer 'PC-01'
    Assert-True ($unknown.Verdict -eq 'Unknown' -and $unknown.Text.Length -lt 220) 'Motif inconnu non borne'
}

# ---------------------------------------------------------------- UI-27 comptes utilises en ce moment
Test-Case 'X03-UI27' 'Ressource d un compte temporaire nommee en clair, jamais par sa cle interne' {
    Assert-Equal 'Postes' (Get-DomeniaAccessScopeLabel 'Remote')
    Assert-Equal 'Poste PC-01 (compte local)' (Get-DomeniaAccessScopeLabel 'RemoteLocal|PC-01')
    Assert-Equal 'Secrets : LAPS' (Get-DomeniaAccessScopeLabel 'ReadLaps')
    Assert-Equal 'Secrets : BitLocker' (Get-DomeniaAccessScopeLabel 'ReadBitLocker')
    Assert-Equal 'Annuaire : recherche' (Get-DomeniaAccessScopeLabel 'AD:GlobalSearch')
    Assert-Equal 'Annuaire : opération WriteRenameComputer' (Get-DomeniaAccessScopeLabel 'AD:WriteRenameComputer')
    Assert-Equal 'Autre ressource' (Get-DomeniaAccessScopeLabel 'remote')
}
Test-Case 'X03-UI27' 'Duree restante en minutes entieres, alignee sur la regle du bail' {
    $t0=[datetime]::SpecifyKind([datetime]'2026-10-02T08:00:00',[DateTimeKind]::Utc)
    $lease=New-DomeniaCredentialLease -Scope 'Remote' -Account 'EXAMPLE\temp' -Mode Inactivity -InactivityMinutes 30 -Epoch 7 -NowUtc $t0
    Assert-Equal 'encore 30 min sans utilisation' (Get-DomeniaLeaseRemainingText -Lease $lease -Epoch 7 -NowUtc $t0).Text
    Assert-Equal 'encore 21 min sans utilisation' (Get-DomeniaLeaseRemainingText -Lease $lease -Epoch 7 -NowUtc $t0.AddMinutes(9).AddSeconds(30)).Text
    Assert-Equal 'encore 1 min sans utilisation' (Get-DomeniaLeaseRemainingText -Lease $lease -Epoch 7 -NowUtc $t0.AddMinutes(30)).Text
    $spent=Get-DomeniaLeaseRemainingText -Lease $lease -Epoch 7 -NowUtc $t0.AddMinutes(31)
    Assert-False $spent.Usable 'Bail expire encore utilisable'
    Assert-False (Get-DomeniaLeaseRemainingText -Lease $lease -Epoch 8 -NowUtc $t0).Usable 'Bail d une autre session encore utilisable'
    Assert-Equal 'jusquʼà la fin de la session' (Get-DomeniaLeaseRemainingText -Lease $null -Epoch 7 -NowUtc $t0).Text
    $once=New-DomeniaCredentialLease -Scope 'ReadLaps' -Account 'EXAMPLE\laps' -Mode OneShot -Epoch 7 -NowUtc $t0
    Assert-Equal 'une seule utilisation' (Get-DomeniaLeaseRemainingText -Lease $once -Epoch 7 -NowUtc $t0).Text
}
Test-Case 'X03-UI27' 'En ce moment : compte par ressource, comptes en memoire avec duree, aucun secret' {
    $t0=[datetime]::SpecifyKind([datetime]'2026-10-02T08:00:00',[DateTimeKind]::Utc)
    $machine=Get-DomeniaMachineAccountLabel -Source 'Typed' -Account 'EXAMPLE\adm-poste'
    $laps=[pscustomobject]@{Key='ReadLaps';UserName='EXAMPLE\laps-temp';Lease=(New-DomeniaCredentialLease -Scope 'ReadLaps' -Account 'EXAMPLE\laps-temp' -Mode Inactivity -InactivityMinutes 30 -Epoch 7 -NowUtc $t0)}
    $r=Get-DomeniaAccountsInUseRows -DirectoryAccount 'EXAMPLE\jdupont' -DirectoryMode 'Windows' -Machine $machine -SecretsAccount 'EXAMPLE\secrets' -TypedMachineAccount 'EXAMPLE\adm-poste' -Temporary @($laps) -Epoch 7 -NowUtc $t0.AddMinutes(4)
    Assert-Equal 4 @($r.Now).Count
    Assert-Equal 'Annuaire|EXAMPLE\jdupont|session Windows' (@($r.Now)[0].Resource+'|'+@($r.Now)[0].Account+'|'+@($r.Now)[0].Origin)
    Assert-Equal 'EXAMPLE\adm-poste|compte poste saisi, en mémoire seulement' (@($r.Now)[1].Account+'|'+@($r.Now)[1].Origin)
    Assert-Equal 'Secrets : LAPS|EXAMPLE\laps-temp|compte temporaire accepté après un refus' (@($r.Now)[2].Resource+'|'+@($r.Now)[2].Account+'|'+@($r.Now)[2].Origin)
    Assert-Equal 'Secrets : BitLocker|EXAMPLE\secrets|compte Secrets de la page Comptes' (@($r.Now)[3].Resource+'|'+@($r.Now)[3].Account+'|'+@($r.Now)[3].Origin)
    Assert-Equal 2 @($r.Memory).Count
    Assert-Equal 'Typed:Machine|Compte poste saisi' (@($r.Memory)[0].Key+'|'+@($r.Memory)[0].Resource)
    Assert-Equal 'ReadLaps|Secrets : LAPS|encore 26 min sans utilisation' (@($r.Memory)[1].Key+'|'+@($r.Memory)[1].Resource+'|'+@($r.Memory)[1].Remaining)
    foreach($row in @($r.Now)+@($r.Memory)){foreach($p in $row.PSObject.Properties){Assert-True ($p.Value -is [string]) ('Valeur non textuelle : '+$p.Name)}}
    $none=Get-DomeniaAccountsInUseRows -Machine (Get-DomeniaMachineAccountLabel -Source 'Windows' -Account '')
    Assert-Equal 'Aucune identité active|aucune connexion' (@($none.Now)[0].Account+'|'+@($none.Now)[0].Origin)
    Assert-Equal 'même compte que lʼannuaire' @($none.Now)[2].Origin
    Assert-Equal 0 @($none.Memory).Count
}
