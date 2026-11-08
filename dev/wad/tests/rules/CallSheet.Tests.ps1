# R40 (fiche dʼappel) : regles pures de la fiche dʼappel d un compte utilisateur (Domenia-CallSheet.Model.ps1).
# Donnees fictives (domaine example.test), horloge fixe : aucun reseau, aucun disque, aucune fenetre.
. (Join-Path $modules 'Domenia-Collection.Model.ps1')
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
. (Join-Path $modules 'Domenia-Readings.Model.ps1')
. (Join-Path $modules 'Domenia-CallSheet.Model.ps1')
# The catalog cache of Probes.Model starts empty (StrictMode of this runner: the variable must exist).
$script:DomeniaProbeCatalog = $null

$script:CsNow = [datetime]::SpecifyKind([datetime]'2026-10-19T09:30:00',[DateTimeKind]::Utc)  # lundi 09:30 UTC
$script:CsDash = [string][char]0x2013
function New-CsLogonHours {
    # 21 octets : les heures UTC (0 = dimanche 00:00) listees sont autorisees.
    param([int[]]$Hours=@())
    $bytes = New-Object 'byte[]' 21
    foreach ($hour in $Hours) { $bytes[[int][Math]::Floor($hour / 8)] = [byte]($bytes[[int][Math]::Floor($hour / 8)] -bor (1 -shl ($hour % 8))) }
    return ,$bytes
}
function Get-CsWeekdayHours {
    param([int]$From,[int]$To)
    $list = New-Object 'System.Collections.Generic.List[int]'
    foreach ($day in 1..5) { for ($h = $From; $h -lt $To; $h++) { $list.Add($day * 24 + $h) } }
    return ,$list.ToArray()
}
function New-CsUser {
    param([hashtable]$Extra=@{})
    $p = @{
        sAMAccountName='jdupont';userPrincipalName='jdupont@example.test';displayName='Jeanne Dupont'
        userAccountControl='512';'msDS-User-Account-Control-Computed'='0';lockoutTime='0';badPwdCount='0'
        pwdLastSet=[string]$script:CsNow.AddDays(-20).ToFileTimeUtc();accountExpires='0'
        'msDS-UserPasswordExpiryTimeComputed'=[string]$script:CsNow.AddDays(70).ToFileTimeUtc()
        lastLogonTimestamp=[string]$script:CsNow.AddDays(-2).ToFileTimeUtc()
        memberOf=@('CN=Compta,OU=Groupes,DC=example,DC=test','CN=Admins du domaine,CN=Users,DC=example,DC=test');primaryGroupID='513'
    }
    foreach ($key in $Extra.Keys) { if ($null -eq $Extra[$key]) { $p.Remove($key) } else { $p[$key] = $Extra[$key] } }
    return $p
}
function Get-CsFact {
    param([object[]]$Facts,[string]$Label)
    $found = @($Facts | Where-Object { [string]$_.Label -ceq $Label })
    if ($found.Count -ne 1) { throw ('Fait absent ou en double : ' + $Label + ' (' + $found.Count + ')') }
    return $found[0]
}

Test-Case 'R40' 'Heures dʼouverture : decodage UTC, plages locales groupees et heure courante' {
    $bytes = New-CsLogonHours (Get-CsWeekdayHours 8 18)
    $view = Get-DomeniaLogonHoursView -Value $bytes -UtcOffsetMinutes 0 -NowUtc $script:CsNow
    Assert-Equal 'Known' $view.State
    Assert-Equal 50 $view.AllowedHours
    Assert-Equal ('Du lundi au vendredi : 08:00' + $script:CsDash + '18:00 ; samedi et dimanche : aucune heure') $view.Summary
    Assert-True ($view.AllowedNow) 'Lundi 09:30 UTC est dans la plage'
    Assert-Equal 'UTC+00:00' $view.Offset
    Assert-Equal 7 @($view.Days).Count
    Assert-Equal 'lundi' ([string]@($view.Days)[0].Day)
    $shifted = Get-DomeniaLogonHoursView -Value $bytes -UtcOffsetMinutes 120 -NowUtc $script:CsNow.AddHours(9)
    Assert-Equal ('Du lundi au vendredi : 10:00' + $script:CsDash + '20:00 ; samedi et dimanche : aucune heure') $shifted.Summary
    Assert-False ($shifted.AllowedNow) 'Lundi 18:30 UTC est hors plage'
    Assert-Equal 'UTC+02:00' $shifted.Offset
}

Test-Case 'R40' 'Heures dʼouverture : texte hexadecimal, toutes ou aucune heure, valeur illisible, absence lue ou non lue' {
    $bytes = New-CsLogonHours (Get-CsWeekdayHours 8 18)
    $hex = [BitConverter]::ToString($bytes)
    Assert-Equal (Get-DomeniaLogonHoursView -Value $bytes).Summary (Get-DomeniaLogonHoursView -Value $hex).Summary
    Assert-Equal (Get-DomeniaLogonHoursView -Value $bytes).Summary (Get-DomeniaLogonHoursView -Value @($hex)).Summary
    $all = New-Object 'byte[]' 21; for ($i = 0; $i -lt 21; $i++) { $all[$i] = 255 }
    $full = Get-DomeniaLogonHoursView -Value $all
    Assert-True ($full.Unrestricted); Assert-Equal 'Toutes les heures sont autorisées' $full.Summary
    $none = Get-DomeniaLogonHoursView -Value (New-Object 'byte[]' 21) -NowUtc $script:CsNow
    Assert-True ($none.NeverAllowed); Assert-False ($none.AllowedNow); Assert-Equal 0 $none.AllowedHours
    Assert-Equal 'Error' (Get-DomeniaLogonHoursView -Value 'FF-FF').State
    Assert-Equal 'Error' (Get-DomeniaLogonHoursView -Value (New-Object 'byte[]' 20)).State
    $absent = Get-DomeniaLogonHoursView -Value $null -Read $true
    Assert-True ($absent.Unrestricted); Assert-Equal 'Aucune restriction horaire' $absent.Summary
    Assert-Equal 'NotRead' (Get-DomeniaLogonHoursView -Value $null -Read $false).State
    Assert-Equal 21 @(ConvertFrom-DomeniaLogonHoursValue @(1..21)).Count
    Assert-True ($null -eq (ConvertFrom-DomeniaLogonHoursValue @(1..20))) '20 nombres refuses'
}

Test-Case 'R40' 'Heures dʼouverture : une plage qui franchit minuit ou la fin de semaine change de jour' {
    # Dimanche 00:00-01:00 UTC vu en UTC-01:00 : samedi 23:00-24:00 local.
    $view = Get-DomeniaLogonHoursView -Value (New-CsLogonHours @(0)) -UtcOffsetMinutes -60
    Assert-Equal ('Du lundi au vendredi : aucune heure ; samedi : 23:00' + $script:CsDash + '24:00 ; dimanche : aucune heure') $view.Summary
    # Lundi 23:00 UTC en UTC+05:30 : mardi 04:30-05:30.
    $india = Get-DomeniaLogonHoursView -Value (New-CsLogonHours @(47)) -UtcOffsetMinutes 330
    Assert-True ($india.Summary -match ('mardi : 04:30' + [regex]::Escape($script:CsDash) + '05:30')) $india.Summary
    Assert-Equal 'UTC+05:30' $india.Offset
}

Test-Case 'R40' 'Postes autorises : liste, tous les postes, non lu, postes associes hors liste' {
    $view = Get-DomeniaUserWorkstationsView -Value 'PC-01, PC-02,pc-01' -LinkedComputers @('pc-03.example.test')
    Assert-Equal 2 @($view.Names).Count
    Assert-Equal '2 poste(s) autorisé(s) : PC-01, PC-02' $view.Summary
    Assert-True ($view.Attention) 'Aucun poste associe dans la liste'
    $ok = Get-DomeniaUserWorkstationsView -Value 'PC-01,PC-02' -LinkedComputers @('PC-01.example.test','PC-09')
    Assert-False ($ok.Attention); Assert-True ($ok.Detail -match 'PC-09') $ok.Detail
    $all = Get-DomeniaUserWorkstationsView -Value $null -Read $true
    Assert-True ($all.Unrestricted); Assert-Equal 'Tous les postes' $all.Summary
    Assert-Equal 'NotRead' (Get-DomeniaUserWorkstationsView -Value @() -Read $false).State
}

Test-Case 'R40' 'Origine de la fiche : lecture AD, base locale recente ou ancienne, origine ou date inconnue' {
    Assert-Equal 'Known' (Get-DomeniaCallSheetOrigin -Origin 'Live' -ObservedUtc $script:CsNow.AddHours(-3) -NowUtc $script:CsNow).State
    Assert-Equal 'Known' (Get-DomeniaCallSheetOrigin -Origin 'Cache' -ObservedUtc $script:CsNow.AddMinutes(-5) -NowUtc $script:CsNow).State
    $old = Get-DomeniaCallSheetOrigin -Origin 'Cache' -ObservedUtc $script:CsNow.AddMinutes(-40) -NowUtc $script:CsNow
    Assert-Equal 'Expired' $old.State; Assert-True ($old.Text -match 'relisez') $old.Text
    Assert-Equal 'Expired' (Get-DomeniaCallSheetOrigin -Origin 'Unknown' -ObservedUtc $script:CsNow -NowUtc $script:CsNow).State
    Assert-Equal 'Expired' (Get-DomeniaCallSheetOrigin -Origin 'Cache' -ObservedUtc $script:CsNow.AddHours(2) -NowUtc $script:CsNow).State
    Assert-Equal 'Expired' (Get-DomeniaCallSheetOrigin -Origin 'Cache' -NowUtc $script:CsNow).State
}

Test-Case 'R40' 'Compte lu dans lʼannuaire : actif, verrouille, echecs, echeances et restrictions absentes' {
    $lockedAt = $script:CsNow.AddMinutes(-30)
    $props = New-CsUser @{'msDS-User-Account-Control-Computed'='16';lockoutTime=[string]$lockedAt.ToFileTimeUtc();badPwdCount='4';badPasswordTime=[string]$lockedAt.ToFileTimeUtc()}
    $facts = @(Get-DomeniaCallSheetAccountFacts -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow -Server 'dc01.example.test')
    $state = Get-CsFact $facts 'État du compte'
    Assert-Equal 'Activé' $state.Value; Assert-Equal 'Known' $state.State; Assert-False ($state.Attention)
    Assert-True ($state.Source -match 'dc01') $state.Source
    $lock = Get-CsFact $facts 'Verrouillage'
    Assert-Equal ('Verrouillé depuis le ' + (Format-DomeniaCallSheetDate $lockedAt)) $lock.Value; Assert-True ($lock.Attention)
    $bad = Get-CsFact $facts 'Échecs de mot de passe'
    Assert-True ($bad.Value -like '4 (dernier échec le *') $bad.Value; Assert-True ($bad.Attention)
    $expiry = Get-CsFact $facts 'Expiration du mot de passe'
    Assert-True ($expiry.Value -like 'Expire le * (dans 70 j)') $expiry.Value; Assert-False ($expiry.Attention)
    Assert-Equal 'Nʼexpire jamais' (Get-CsFact $facts 'Expiration du compte').Value
    Assert-Equal 'Aucune restriction horaire' (Get-CsFact $facts 'Heures dʼouverture de session').Value
    Assert-Equal 'Tous les postes' (Get-CsFact $facts 'Postes autorisés').Value
    Assert-Equal 'Non exigée' (Get-CsFact $facts 'Carte à puce').Value
    Assert-Equal 'Non' (Get-CsFact $facts 'Mot de passe non requis').Value
    Assert-True ((Get-CsFact $facts 'Dernière ouverture de session').Value -like 'Vers le *')
    foreach ($fact in $facts) { Assert-True ([string]$fact.Section -in @('Compte','Restrictions')) $fact.Label }
    $attention = @(Get-DomeniaCallSheetAttention -Facts $facts)
    Assert-Equal 2 $attention.Count ($attention -join ' | ')
    Assert-True ($attention[0] -like 'Verrouillage : Verrouillé depuis le *') $attention[0]
}

Test-Case 'R40' 'Compte : desactive, mot de passe a changer, expire, carte a puce, mot de passe non requis, compte expire' {
    $props = New-CsUser @{userAccountControl=[string](2 -bor 32 -bor 262144);pwdLastSet='0';accountExpires=[string]$script:CsNow.AddDays(-1).ToFileTimeUtc()}
    $facts = @(Get-DomeniaCallSheetAccountFacts -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
    Assert-Equal 'Désactivé' (Get-CsFact $facts 'État du compte').Value
    Assert-Equal 'À changer à la prochaine ouverture de session' (Get-CsFact $facts 'Mot de passe changé').Value
    Assert-Equal 'À changer à la prochaine ouverture de session' (Get-CsFact $facts 'Expiration du mot de passe').Value
    Assert-True ((Get-CsFact $facts 'Expiration du compte').Value -like 'Expiré depuis le *')
    Assert-True ((Get-CsFact $facts 'Carte à puce').Attention)
    Assert-True ((Get-CsFact $facts 'Mot de passe non requis').Attention)
    $expired = @(Get-DomeniaCallSheetAccountFacts -Properties (New-CsUser @{'msDS-UserPasswordExpiryTimeComputed'=[string]$script:CsNow.AddDays(-3).ToFileTimeUtc()}) -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
    $fact = Get-CsFact $expired 'Expiration du mot de passe'
    Assert-True ($fact.Value -like 'Expiré depuis le *') $fact.Value; Assert-True ($fact.Attention)
    $never = @(Get-DomeniaCallSheetAccountFacts -Properties (New-CsUser @{userAccountControl=[string](512 -bor 65536)}) -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
    Assert-Equal 'Nʼexpire jamais (option du compte)' (Get-CsFact $never 'Expiration du mot de passe').Value
}

Test-Case 'R40' 'Compte : fiche de la base locale ancienne, etat calcule ou attribut absent, valeur illisible' {
    $props = New-CsUser @{'msDS-User-Account-Control-Computed'=$null;'msDS-UserPasswordExpiryTimeComputed'=$null;badPwdCount=$null;lastLogonTimestamp=$null}
    $facts = @(Get-DomeniaCallSheetAccountFacts -Properties $props -Origin 'Cache' -ObservedUtc $script:CsNow.AddHours(-2) -NowUtc $script:CsNow)
    $state = Get-CsFact $facts 'État du compte'
    Assert-Equal 'Expired' $state.State; Assert-True ($state.Detail -match 'relisez') $state.Detail
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Verrouillage').State
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Échecs de mot de passe').State
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Expiration du mot de passe').State
    Assert-Equal 'Inconnue' (Get-CsFact $facts 'Expiration du mot de passe').Value
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Heures dʼouverture de session').State
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Postes autorisés').State
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Dernière ouverture de session').State
    $bad = @(Get-DomeniaCallSheetAccountFacts -Properties (New-CsUser @{badPwdCount='x'}) -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
    Assert-Equal 'Error' (Get-CsFact $bad 'Échecs de mot de passe').State
    $noUac = @(Get-DomeniaCallSheetAccountFacts -Properties (New-CsUser @{userAccountControl=$null}) -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
    Assert-Equal 'NotRead' (Get-CsFact $noUac 'État du compte').State
    Assert-Equal 'NotRead' (Get-CsFact $noUac 'Carte à puce').State
}

Test-Case 'R40' 'Compte : heures restreintes, hors plage maintenant, postes associes hors liste' {
    $hex = [BitConverter]::ToString((New-CsLogonHours (Get-CsWeekdayHours 12 14)))
    $props = New-CsUser @{logonHours=$hex;userWorkstations='PC-01'}
    $facts = @(Get-DomeniaCallSheetAccountFacts -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow -UtcOffsetMinutes 0 -LinkedComputers @('PC-02'))
    $hours = Get-CsFact $facts 'Heures dʼouverture de session'
    Assert-True ($hours.Value -like '*en ce moment : hors des heures autorisées') $hours.Value
    Assert-True ($hours.Attention); Assert-True ($hours.Detail -match 'UTC\+00:00') $hours.Detail
    $posts = Get-CsFact $facts 'Postes autorisés'
    Assert-True ($posts.Attention); Assert-Equal '1 poste(s) autorisé(s) : PC-01' $posts.Value
}

Test-Case 'R40' 'Compte : lʼecheance de la strategie lue porte sa propre source et sa date' {
    $policy = [pscustomobject]@{ExpiresUtc=$script:CsNow.AddDays(3);Summary='Aucune stratégie fine ne vise ce compte : la stratégie du domaine sʼapplique.';Facts=@((New-DomeniaFact -Fait 'Expiration du mot de passe' -Valeur 'x' -Etat Estime))}
    $props = New-CsUser @{'msDS-UserPasswordExpiryTimeComputed'=$null}
    $facts = @(Get-DomeniaCallSheetAccountFacts -Properties $props -Origin 'Cache' -ObservedUtc $script:CsNow.AddHours(-5) -NowUtc $script:CsNow -PolicyView $policy -PolicyObservedUtc $script:CsNow -PolicyServer 'dc02')
    $fact = Get-CsFact $facts 'Expiration du mot de passe'
    Assert-Equal 'Known' $fact.State; Assert-True ($fact.Attention) 'Moins de 7 jours'
    Assert-Equal 'Stratégie de mot de passe lue sur dc02' $fact.Source
    Assert-True ($fact.Detail -match 'Estimée') $fact.Detail
    Assert-Equal (Format-DomeniaCallSheetDate $script:CsNow) $fact.DateText
}

Test-Case 'R40' 'Verrouillages 4740 : non demandes, lus, refuses, injoignables, echec de lecture' {
    Assert-Equal 'NotRead' (Get-DomeniaCallSheetLockoutFact).State
    $read = [pscustomobject]@{State='Read';Server='dc01';Events=@([pscustomobject]@{TimeUtc='2026-10-19T08:00:00Z';CallerComputer='PC-01'},[pscustomobject]@{TimeUtc='2026-10-19T08:10:00Z';CallerComputer='PC-01'});Truncated=$false;ObservedUtc='2026-10-19T09:00:00Z'}
    $fact = Get-DomeniaCallSheetLockoutFact -Read $read -Diagnosis ([pscustomobject]@{Origins=@('PC-01 (2)')})
    Assert-Equal 'Known' $fact.State; Assert-Equal '2 verrouillage(s) · postes : PC-01 (2)' $fact.Value; Assert-True ($fact.Attention)
    Assert-Equal 'Journal Sécurité de dc01' $fact.Source
    $read.Truncated = $true
    Assert-Equal 'Incomplete' (Get-DomeniaCallSheetLockoutFact -Read $read -Diagnosis $null).State
    Assert-Equal 'Known' (Get-DomeniaCallSheetLockoutFact -Read ([pscustomobject]@{State='Read';Server='dc01';Events=@();ObservedUtc=''})).State
    Assert-Equal 'Refused' (Get-DomeniaCallSheetLockoutFact -Read ([pscustomobject]@{State='Refused';Server='dc01';Events=@()})).State
    Assert-Equal 'Error' (Get-DomeniaCallSheetLockoutFact -Read ([pscustomobject]@{State='Unavailable';Server='dc01';Events=@()})).State
    Assert-Equal 'Refused' (Get-DomeniaCallSheetLockoutFact -Failure 'Access is denied').State
    Assert-Equal 'Error' (Get-DomeniaCallSheetLockoutFact -Failure 'Délai dépassé').State
}

Test-Case 'R40' 'Postes associes : relation declaree dʼabord, presence et console datees, instant perime' {
    $declared = [pscustomobject]@{UserLogin='jdupont';Computer='PC-01';Source='Saisie manuelle';Kind='Affectation';When='2026-09-01T08:00:00Z'}
    $observed = [pscustomobject]@{UserLogin='jdupont';Computer='PC-02';Source='Console (CIM)';Kind='Console';When='2026-10-18T08:00:00Z'}
    $fresh = [pscustomobject]@{Presence='En ligne';PresenceCheckedUtc=$script:CsNow.AddMinutes(-3).ToString('o');CurrentUser='EXAMPLE\jdupont';UserCheckedUtc=$script:CsNow.AddMinutes(-3).ToString('o');Outcome='Observed'}
    $old = [pscustomobject]@{Presence='Sans réponse au ping';PresenceCheckedUtc=$script:CsNow.AddHours(-2).ToString('o')}
    $rows = @(ConvertTo-DomeniaCallSheetComputerRows -Targets @(
        [pscustomobject]@{Computer='PC-02';Dn='CN=PC-02,OU=Postes,DC=example,DC=test';Guid='';Link=$observed;Observation=$old;Sessions=$null}
        [pscustomobject]@{Computer='PC-01';Dn='CN=PC-01,OU=Postes,DC=example,DC=test';Guid='';Link=$declared;Observation=$fresh;Sessions=$null}
    ) -UserLogin 'jdupont' -NowUtc $script:CsNow)
    Assert-Equal 2 $rows.Count
    Assert-Equal 'PC-01' $rows[0].Computer; Assert-True ($rows[0].Primary)
    Assert-Equal 'Déclaré · principal' $rows[0].Qualification
    Assert-Equal 'En ligne' $rows[0].PresenceValue; Assert-Equal 'Known' $rows[0].PresenceState
    Assert-Equal 'Ce compte est en console' $rows[0].ConsoleValue
    Assert-Equal 'NotRead' $rows[0].SessionState; Assert-Equal 'Non lues' $rows[0].SessionValue
    Assert-Equal 'Observé' $rows[1].Qualification
    Assert-Equal 'Expired' $rows[1].PresenceState; Assert-Equal 'Sans réponse au ping' $rows[1].PresenceValue
    $none = @(ConvertTo-DomeniaCallSheetComputerRows -Targets @([pscustomobject]@{Computer='PC-03';Dn='';Guid='';Link=$observed;Observation=$null;Sessions=$null}) -UserLogin 'jdupont' -NowUtc $script:CsNow)
    Assert-Equal 'Absent' $none[0].PresenceState; Assert-Equal 'Jamais relevé' $none[0].PresenceValue
}

Test-Case 'R40' 'Sessions du compte : session lue, aucune session, lecture partielle, refus' {
    $view = [pscustomobject]@{ReadState='Constate';Partial=$false;UnreadSessions=0;Rows=@(
        [pscustomobject]@{User='jdupont';Etat='Active';Protocole='RDP';Ouverte='09:12';Inactive=''}
        [pscustomobject]@{User='mmartin';Etat='Déconnectée';Protocole='RDP';Ouverte='';Inactive='2 h'}
    )}
    $mine = Get-DomeniaCallSheetSessionSummary -View $view -UserLogin 'EXAMPLE\jdupont' -ObservedUtc $script:CsNow
    Assert-Equal 'Known' $mine.State; Assert-Equal 'Session de ce compte : Active (RDP) ouverte à 09:12' $mine.Value; Assert-Equal 1 $mine.Mine
    $other = Get-DomeniaCallSheetSessionSummary -View $view -UserLogin 'pdurand'
    Assert-Equal 'Aucune session de ce compte ; 2 autre(s) session(s) avec compte' $other.Value
    $view.UnreadSessions = 1
    Assert-Equal 'Incomplete' (Get-DomeniaCallSheetSessionSummary -View $view -UserLogin 'pdurand').State
    Assert-Equal 'Refused' (Get-DomeniaCallSheetSessionSummary -Failure 'Accès refusé' -UserLogin 'jdupont').State
    Assert-Equal 'NotRead' (Get-DomeniaCallSheetSessionSummary -UserLogin 'jdupont').State
    Assert-Equal 'Incomplete' (Get-DomeniaCallSheetSessionSummary -View ([pscustomobject]@{ReadState='Inconnu';Rows=@()}) -UserLogin 'jdupont').State
}

Test-Case 'R40' 'Groupes : groupes directs, privilegies, changements de la session sans historique invente' {
    $props = New-CsUser
    $first = Get-DomeniaCallSheetGroupSummary -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow
    Assert-Equal 2 $first.Count
    Assert-Equal 'Admins du domaine' ([string]@($first.Privileged)[0])
    Assert-Equal 'Admins du domaine' ([string]@($first.Rows)[0].Name) 'Privilegies en premier'
    Assert-Equal 'NotRead' (Get-CsFact $first.Facts 'Changements récents').State
    Assert-Equal 'Utilisateurs du domaine (RID 513)' (Get-CsFact $first.Facts 'Groupe principal').Value
    $baseline = @('CN=Compta,OU=Groupes,DC=example,DC=test','CN=Paie,OU=Groupes,DC=example,DC=test')
    $later = Get-DomeniaCallSheetGroupSummary -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -Baseline $baseline -BaselineUtc $script:CsNow.AddHours(-1) -NowUtc $script:CsNow
    Assert-Equal 1 $later.Added; Assert-Equal 1 $later.Removed
    $change = Get-CsFact $later.Facts 'Changements récents'
    Assert-True ($change.Attention); Assert-True ($change.Value -like '1 ajout(s), 1 retrait(s) depuis *') $change.Value
    Assert-True (@($later.Rows | Where-Object { ([bool]$_.Removed) -and ([string]$_.Name -eq 'Paie') }).Count -eq 1) 'Retrait liste'
    $same = Get-DomeniaCallSheetGroupSummary -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -Baseline @($props.memberOf) -BaselineUtc $script:CsNow -NowUtc $script:CsNow
    Assert-True ((Get-CsFact $same.Facts 'Changements récents').Value -like 'Aucun depuis *')
    $partial = Get-DomeniaCallSheetGroupSummary -Properties (New-CsUser @{'__memberOfComplete'=@($false);'__memberOfNote'=@('Limite de temps')}) -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow
    Assert-Equal 'Incomplete' $partial.State
    $cache = Get-DomeniaCallSheetGroupSummary -Properties (New-CsUser @{memberOf=$null}) -Origin 'Cache' -ObservedUtc $script:CsNow -NowUtc $script:CsNow
    Assert-Equal 'NotRead' $cache.State
}

Test-Case 'R40' 'Operations Domenia : recus non lus, recus du compte, a verifier, plus recents dʼabord' {
    $none = ConvertTo-DomeniaCallSheetReceiptSummary -Views $null -Dn 'CN=Jeanne Dupont,OU=Users,DC=example,DC=test'
    Assert-Equal 'NotRead' $none.Fact.State
    $dn = 'CN=Jeanne Dupont,OU=Users,DC=example,DC=test'
    $views = @(
        [pscustomobject]@{DN=$dn;UpdatedUtc='2026-10-18T10:00:00Z';UpdatedLabel='18/10/2026 12:00';OperationLabel='Déverrouillage';StageLabel='Vérifiée';Pending=$false;Explanation=''}
        [pscustomobject]@{DN=$dn.ToUpperInvariant();UpdatedUtc='2026-10-19T08:00:00Z';UpdatedLabel='19/10/2026 10:00';OperationLabel='Réinitialisation du mot de passe';StageLabel='Envoyée, à vérifier';Pending=$true;Explanation=''}
        [pscustomobject]@{DN='CN=Autre,OU=Users,DC=example,DC=test';UpdatedUtc='2026-10-19T09:00:00Z';UpdatedLabel='19/10/2026 11:00';OperationLabel='Déverrouillage';StageLabel='Vérifiée';Pending=$false;Explanation=''}
    )
    $summary = ConvertTo-DomeniaCallSheetReceiptSummary -Views $views -Dn $dn -ReadUtc $script:CsNow
    Assert-Equal 2 $summary.Total; Assert-Equal 1 $summary.Pending
    Assert-Equal '2 reçu(s) sur ce compte, dont 1 à vérifier' $summary.Fact.Value
    Assert-True ($summary.Fact.Attention)
    Assert-Equal 'Réinitialisation du mot de passe' ([string]@($summary.Rows)[0].Operation) 'Plus recent en premier'
    Assert-Equal 'Aucun reçu sur ce compte' (ConvertTo-DomeniaCallSheetReceiptSummary -Views @() -Dn $dn).Fact.Value
}

Test-Case 'R40' 'Tri du poste lent : aucun inventaire, inventaire recent, seuils, redemarrage et echec plus recent' {
    $absent = @(Get-DomeniaCallSheetTriageFacts -Computer 'PC-01' -NowUtc $script:CsNow)
    Assert-Equal 7 $absent.Count
    foreach ($fact in $absent) { Assert-Equal 'Absent' $fact.State $fact.Label }
    $inventory = [pscustomobject]@{
        SourceCompletedUtc=$script:CsNow.AddMinutes(-10).ToString('o')
        Metrics=[pscustomobject]@{CpuLoad=95;MemoryTotal=8GB;MemoryFree=0.25GB;Disks=@([pscustomobject]@{Name='C:';Size=100GB;Free=5GB},[pscustomobject]@{Name='D:';Size=200GB;Free=150GB});Processes=@([pscustomobject]@{Name='chrome';Mb=900},[pscustomobject]@{Name='chrome';Mb=300},[pscustomobject]@{Name='teams';Mb=700})}
        Rows=@(
            [pscustomobject]@{Category='Systeme d exploitation';Item='Duree de fonctionnement';Value='45 j 2 h 3 min'}
            [pscustomobject]@{Category='Systeme d exploitation';Item='Dernier demarrage';Value='04/09/2026 07:27'}
            [pscustomobject]@{Category='Redemarrage en attente';Item='Windows Update';Value='Present (obligation confirmee)'}
        )
    }
    $facts = @(Get-DomeniaCallSheetTriageFacts -Inventory $inventory -Computer 'PC-01' -NowUtc $script:CsNow)
    Assert-Equal 7 $facts.Count
    $cpu = Get-CsFact $facts 'Processeur'; Assert-Equal 'Known' $cpu.State; Assert-True ($cpu.Attention); Assert-Equal '95 % de charge' $cpu.Value
    Assert-True ((Get-CsFact $facts 'Mémoire').Attention) 'Plus de 90 %'
    $disk = Get-CsFact $facts 'Disque système'; Assert-True ($disk.Attention); Assert-True ($disk.Value -like 'C: : 5 % libres*presque plein') $disk.Value
    Assert-True ((Get-CsFact $facts 'Autres volumes').Value -like '1 volume(s), le moins libre D: : 75 % libres') (Get-CsFact $facts 'Autres volumes').Value
    Assert-True ((Get-CsFact $facts 'Processus les plus actifs').Value -like 'chrome 1*200 Mo · teams 700 Mo') (Get-CsFact $facts 'Processus les plus actifs').Value
    $start = Get-CsFact $facts 'Démarrage'; Assert-True ($start.Attention); Assert-True ($start.Value -like 'Démarré le 04/09/2026 07:27 (depuis 45 j*') $start.Value
    $reboot = Get-CsFact $facts 'Redémarrage en attente'; Assert-Equal 'Oui : Windows Update' $reboot.Value; Assert-True ($reboot.Attention)
    foreach ($fact in $facts) { Assert-Equal 'Inventaire rapide de PC-01' $fact.Source $fact.Label }
    $older = @(Get-DomeniaCallSheetTriageFacts -Inventory $inventory -Computer 'PC-01' -NowUtc $script:CsNow.AddHours(3))
    Assert-Equal 'Expired' (Get-CsFact $older 'Processeur').State
    Assert-False ((Get-CsFact $older 'Processeur').Attention) 'Une mesure perimee ne leve pas le point'
    Assert-Equal 'Known' (Get-CsFact $older 'Disque système').State
    $failed = @(Get-DomeniaCallSheetTriageFacts -Inventory $inventory -Computer 'PC-01' -Failure 'Access is denied' -FailureUtc $script:CsNow -NowUtc $script:CsNow)
    Assert-Equal 8 $failed.Count; Assert-Equal 'Refused' (Get-CsFact $failed 'Dernière tentative').State
    $neverRead = @(Get-DomeniaCallSheetTriageFacts -Computer 'PC-01' -Failure 'RPC indisponible' -FailureUtc $script:CsNow -NowUtc $script:CsNow)
    Assert-Equal 'Error' (Get-CsFact $neverRead 'Processeur').State
    $limits = [pscustomobject]@{DiskFreeAlert=3;DiskFreeWarn=4;MemoryUsedWarn=99;UptimeDays=60}
    $relaxed = @(Get-DomeniaCallSheetTriageFacts -Inventory $inventory -Computer 'PC-01' -NowUtc $script:CsNow -Thresholds $limits)
    Assert-False ((Get-CsFact $relaxed 'Disque système').Attention); Assert-False ((Get-CsFact $relaxed 'Démarrage').Attention); Assert-False ((Get-CsFact $relaxed 'Mémoire').Attention)
    $future = @(Get-DomeniaCallSheetTriageFacts -Inventory ([pscustomobject]@{SourceCompletedUtc=$script:CsNow.AddHours(1).ToString('o');Rows=@();Metrics=$null}) -Computer 'PC-01' -NowUtc $script:CsNow)
    Assert-Equal 'Error' (Get-CsFact $future 'Processeur').State
}

Test-Case 'R40' 'Tri du poste lent : part du processeur mesuree sur intervalle quand lʼinventaire la porte' {
    $sample = [pscustomobject]@{IntervalMs=1000;LogicalProcessors=2;SampledUtc=$script:CsNow.AddMinutes(-5).ToString('o');Items=@(
        [pscustomobject]@{Pid=0;Name='Idle';FirstTime=0;SecondTime=5000000}
        [pscustomobject]@{Pid=10;Name='chrome';FirstTime=0;SecondTime=10000000;WorkingSet=1GB}
        [pscustomobject]@{Pid=11;Name='defender';FirstTime=0;SecondTime=2000000;WorkingSet=100MB}
    )}
    $inventory = [pscustomobject]@{SourceCompletedUtc=$script:CsNow.AddMinutes(-5).ToString('o');Rows=@();Metrics=[pscustomobject]@{CpuLoad=-1;ProcessSample=$sample}}
    $facts = @(Get-DomeniaCallSheetTriageFacts -Inventory $inventory -Computer 'PC-01' -NowUtc $script:CsNow)
    Assert-Equal 'chrome 50 % · defender 10 %' (Get-CsFact $facts 'Processus les plus actifs').Value
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Processeur').State
    Assert-Equal 'NotRead' (Get-CsFact $facts 'Redémarrage en attente').State
}

Test-Case 'R40' 'Modele du ticket : defaut, configuration en lignes, modeles refuses avec leur motif' {
    $default = Resolve-DomeniaCallSheetTemplate $null
    Assert-Equal 'Défaut' $default.Source
    foreach ($name in @(Get-DomeniaCallSheetTemplatePlaceholders)) { Assert-True ($default.Text.Contains('{' + $name + '}')) $name }
    $lines = Resolve-DomeniaCallSheetTemplate @('Appel de {NomAffiche}','{Compte}')
    Assert-Equal 'Configuration' $lines.Source; Assert-Equal ("Appel de {NomAffiche}`n{Compte}") $lines.Text
    $long = Resolve-DomeniaCallSheetTemplate ('{Compte}' + ('x' * 4000))
    Assert-Equal 'Défaut' $long.Source; Assert-True ($long.Warning -match '4 000') $long.Warning
    Assert-True ((Resolve-DomeniaCallSheetTemplate 'Texte fixe sans champ').Warning -match 'aucun champ') 'Sans champ'
    Assert-True ((Resolve-DomeniaCallSheetTemplate ('{Compte}' + [char]7)).Warning -match 'contrôle') 'Caractere de controle'
    Assert-Equal 'Défaut' (Resolve-DomeniaCallSheetTemplate '   ').Source
}

Test-Case 'R40' 'Texte du ticket : champs remplaces, champ inconnu garde, secret masque, fins de ligne CRLF, borne' {
    $values = [ordered]@{NomAffiche='Jeanne Dupont';Compte="- État du compte : Activé`n- password=Secret123"}
    $ticket = ConvertTo-DomeniaCallSheetTicket -Template "Appel de {nomaffiche} {Inconnu}`n{Compte}" -Values $values
    Assert-True ($ticket.Text.StartsWith('Appel de Jeanne Dupont {Inconnu}' + "`r`n")) $ticket.Text
    Assert-Equal 'Inconnu' ([string]@($ticket.Unknown)[0])
    Assert-True ($ticket.Masked) 'Secret masque'
    Assert-False ($ticket.Text.Contains('Secret123')) $ticket.Text
    Assert-False ($ticket.Text -match "(?<!`r)`n") 'Fins de ligne CRLF seulement'
    $long = ConvertTo-DomeniaCallSheetTicket -Template '{Compte}' -Values @{Compte=('a' * 9000)} -MaxLength 1000
    Assert-True ($long.Truncated); Assert-True ($long.Text.Length -lt 1100) ([string]$long.Text.Length)
    Assert-False (ConvertTo-DomeniaCallSheetTicket -Template '{Compte}' -Values @{Compte='rien'}).Masked
}

Test-Case 'R40' 'Valeurs du ticket : sections, points dʼattention, sections vides dites en mots' {
    $props = New-CsUser @{'msDS-User-Account-Control-Computed'='16';lockoutTime=[string]$script:CsNow.AddMinutes(-5).ToFileTimeUtc()}
    $sheet = [pscustomobject]@{
        Subject=[pscustomobject]@{DisplayName='Jeanne Dupont';Login='jdupont';Upn='jdupont@example.test'}
        AccountFacts=@(Get-DomeniaCallSheetAccountFacts -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
        ComputerRows=@();GroupSummary=(Get-DomeniaCallSheetGroupSummary -Properties $props -Origin 'Live' -ObservedUtc $script:CsNow -NowUtc $script:CsNow)
        ReceiptSummary=(ConvertTo-DomeniaCallSheetReceiptSummary -Views $null);TriageComputer='';TriageFacts=@()
    }
    $values = Get-DomeniaCallSheetTicketValues -Sheet $sheet -NowUtc $script:CsNow
    Assert-True ($values['PointsAttention'] -like 'Verrouillage : Verrouillé depuis le *') $values['PointsAttention']
    Assert-Equal '- Aucun poste associé à ce compte.' $values['Postes']
    Assert-Equal '- Aucun poste associé : tri non disponible.' $values['Triage']
    Assert-True ($values['Compte'] -match '- État du compte : Activé \(Fiche lue dans lʼannuaire') $values['Compte']
    Assert-True ($values['Operations'] -match '\[Non lu\]') $values['Operations']
    Assert-True ($values['Restrictions'] -match 'Heures dʼouverture de session') $values['Restrictions']
    $ticket = ConvertTo-DomeniaCallSheetTicket -Template (Get-DomeniaCallSheetDefaultTemplate) -Values $values
    Assert-Equal 0 @($ticket.Unknown).Count (@($ticket.Unknown) -join ',')
    Assert-True ($ticket.Text.StartsWith('Fiche dʼappel Domenia du ')) $ticket.Text
}

Test-Case 'R40' 'Faits : etat du vocabulaire unique, valeur vide dite par son etat, ligne de texte' {
    Assert-Throws { New-DomeniaCallSheetFact -Section 'Compte' -Label 'X' -State 'Fresh' } 'Etat hors vocabulaire refuse'
    $fact = New-DomeniaCallSheetFact -Section 'Compte' -Label 'X' -State 'NotRead'
    Assert-Equal 'Non lu' $fact.Value; Assert-Equal 'Non lu' $fact.StateLabel
    Assert-Equal 'Non renseigné' (New-DomeniaCallSheetFact -Section 'Compte' -Label 'X').Value
    $line = ConvertTo-DomeniaCallSheetFactLine (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillage' -Value 'Inconnu' -State 'Expired' -Source 'Base locale' -ObservedUtc $script:CsNow)
    Assert-Equal ('- Verrouillage : Inconnu [Périmé] (Base locale, ' + (Format-DomeniaCallSheetDate $script:CsNow) + ')') $line
}

Test-Case 'R40' 'Regles pures : aucun reseau, aucun disque, aucune fenetre dans le modele de la fiche dʼappel' {
    $text = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-CallSheet.Model.ps1'),[Text.Encoding]::UTF8)
    # Comment lines are left out: they may name what the module does not do. Default parameter values stay allowed.
    $code = [regex]::Replace($text,'(?m)^\s*#.*$','')
    foreach ($pattern in @('Start-UiTask','\[IO\.File\]','\[IO\.Directory\]','Get-CimInstance','Get-WinEvent','Test-Connection','DirectoryEntry','DirectorySearcher','Windows\.Controls','Get-Date','Set-ClipboardSafe','Get-CfgValue','\$script:')) {
        Assert-False ($code -match $pattern) ('Motif interdit dans les regles pures : ' + $pattern)
    }
}
