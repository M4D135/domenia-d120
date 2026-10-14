# Vues de presence et d observation du poste (lot L06, TE-06) : projections en lecture seule de Domenia-Live.Model,
# sans reseau ni base. Donnees fictives uniquement (domaine example.test).
. (Join-Path $modules 'Domenia-Live.Model.ps1')
function New-LivObservation {
    param([string]$Outcome = 'Observed',[string]$CurrentUser = '',[string]$LastUser = '',[string]$Presence = '',[string]$PresenceCheckedUtc = '',[string]$PresenceDetail = '')
    return [pscustomobject]@{ Outcome = $Outcome; CurrentUser = $CurrentUser; LastUser = $LastUser; ObservedUtc = '2026-10-08T09:00:00.0000000Z'; CheckedUtc = '2026-10-08T09:00:00.0000000Z'; UserCheckedUtc = '2026-10-08T09:00:00.0000000Z'; Source = 'CIM/DCOM'; Detail = 'essai'; Presence = $Presence; PresenceCheckedUtc = $PresenceCheckedUtc; PresenceDetail = $PresenceDetail; Guid = 'guid-a' }
}
function New-LivResult {
    param([string]$Outcome = 'Observed',[string]$User = '',[string]$Guid = 'guid-a',[string]$Presence = 'En ligne',[string]$PresenceCheckedUtc = '2026-10-08T10:00:00.0000000Z')
    return [pscustomobject]@{ Key = 'cn=pc-1,dc=example,dc=test'; Computer = 'PC-1'; Guid = $Guid; Outcome = $Outcome; User = $User; Source = 'CIM/DCOM'; Detail = 'lu'; Presence = $Presence; PresenceCheckedUtc = $PresenceCheckedUtc; PresenceDetail = 'Réponse ICMP'; LinkUser = ''; UserDn = ''; UserGuid = ''; DirectoryAuthRejected = $false }
}

Test-Case -Id 'LIV-001' -Name 'Presence : non verifie sans releve, un seul ping propose, aucun controle collectif' -Body {
    $none = Get-DomeniaLivePresenceView -Observation $null
    Assert-Equal ('Non v' + [char]0x00E9 + 'rifi' + [char]0x00E9) ([string]$none.State)
    Assert-Equal '' ([string]$none.Checked)
    Assert-True ([string]$none.Detail -like '*un seul ping*Aucun contr*le collectif*') ([string]$none.Detail)
    $unknown = Get-DomeniaLivePresenceView -Observation (New-LivObservation -Presence 'Inconnu' -PresenceCheckedUtc '2026-10-08T09:00:00Z')
    Assert-Equal ([string]$none.State) ([string]$unknown.State) 'Inconnu lu comme non verifie'
    Assert-Equal '' ([string]$unknown.Checked) 'aucune date pour un etat non verifie'
}
Test-Case -Id 'LIV-002' -Name 'Presence : sans reponse au ping sans preuve d arret, releve ancien marque en cache' -Body {
    $off = Get-DomeniaLivePresenceView -Observation (New-LivObservation -Presence 'Hors ligne' -PresenceCheckedUtc '2026-10-08T09:00:00Z' -PresenceDetail 'ICMP : TimedOut.')
    Assert-Equal ('Sans r' + [char]0x00E9 + 'ponse au ping') ([string]$off.State)
    Assert-True ([string]$off.Detail -like '*sans preuve*teint*') ([string]$off.Detail)
    $cached = Get-DomeniaLivePresenceView -Observation (New-LivObservation -Presence 'En ligne' -PresenceCheckedUtc '2026-10-08T09:00:00Z') -Cached
    Assert-Equal 'En ligne (cache)' ([string]$cached.Display)
    Assert-Equal 'En ligne' ([string]$cached.State)
    Assert-True ([string]$cached.Detail -like '*Observation historique*') 'releve ancien jamais presente comme un etat actuel'
    $fresh = Get-DomeniaLivePresenceView -Observation (New-LivObservation -Presence 'En ligne' -PresenceCheckedUtc '2026-10-08T09:00:00Z')
    Assert-Equal 'En ligne' ([string]$fresh.Display)
    Assert-Equal '2026-10-08T09:00:00Z' ([string]$fresh.Checked)
}
Test-Case -Id 'LIV-003' -Name 'Observation : chaque resultat de lecture a son etat, le cache et la lecture en cours se disent' -Body {
    # Nothing read yet for this workstation (view built from the cache): the next step is said.
    $none = Get-DomeniaLiveObservationView -Observation $null -Cached
    Assert-True ([string]$none.State -like 'Non v*rifi* · s*lectionner le poste') ([string]$none.State)
    Assert-Equal ('Non d' + [char]0x00E9 + 'termin' + [char]0x00E9) ([string]$none.Display)
    $seen = Get-DomeniaLiveObservationView -Observation (New-LivObservation -Outcome 'Observed' -CurrentUser 'EX\bob' -LastUser 'EX\bob')
    Assert-Equal 'EX\bob' ([string]$seen.Display)
    Assert-Equal ('Console observ' + [char]0x00E9 + 'e') ([string]$seen.State)
    Assert-Equal 'Aucun compte console' ([string](Get-DomeniaLiveObservationView -Observation (New-LivObservation -Outcome 'NoConsole')).Display)
    $states = @{ 'Denied' = ('Acc' + [char]0x00E8 + 's refus' + [char]0x00E9); 'AuthRejected' = ('Compte distant refus' + [char]0x00E9); 'Timeout' = ('D' + [char]0x00E9 + 'lai d' + [char]0x00E9 + 'pass' + [char]0x00E9); 'Unavailable' = 'Non confirm' + [char]0x00E9; 'NotRequested' = ('Utilisateur non v' + [char]0x00E9 + 'rifi' + [char]0x00E9) }
    foreach ($outcome in @($states.Keys)) { Assert-Equal ([string]$states[$outcome]) ([string](Get-DomeniaLiveObservationView -Observation (New-LivObservation -Outcome $outcome)).State) $outcome }
    $cached = Get-DomeniaLiveObservationView -Observation (New-LivObservation -Outcome 'Observed' -CurrentUser 'EX\bob' -LastUser 'EX\ann') -Cached
    Assert-Equal 'EX\ann (cache)' ([string]$cached.Display) 'dernier compte observe, marque cache'
    Assert-Equal ([string][char]0x00C0 + ' v' + [char]0x00E9 + 'rifier') ([string]$cached.State)
    Assert-Equal ('V' + [char]0x00E9 + 'rification en cours') ([string](Get-DomeniaLiveObservationView -Observation (New-LivObservation) -Pending).State)
    Assert-True ([string]$seen.Detail -like '*ne recense pas toutes les sessions RDP*') 'limite de la console rappelee'
}
Test-Case -Id 'LIV-004' -Name 'Observation enregistree : poste recree oublie, presence seule garde le compte, compte vide jamais observe' -Body {
    $now = '2026-10-08T10:00:00.0000000Z'
    $previous = New-LivObservation -Outcome 'Observed' -CurrentUser 'EX\ann' -LastUser 'EX\ann' -Presence 'En ligne' -PresenceCheckedUtc '2026-10-08T09:00:00.0000000Z'
    $kept = ConvertTo-DomeniaLiveObservation -Result (New-LivResult -Outcome 'PresenceOnly' -Presence 'Sans réponse au ping') -Previous $previous -NowUtc $now
    Assert-Equal 'EX\ann' ([string]$kept.CurrentUser) 'presence seule : compte precedent garde'
    Assert-Equal 'Observed' ([string]$kept.Outcome)
    Assert-Equal ('Sans r' + [char]0x00E9 + 'ponse au ping') ([string]$kept.Presence) 'presence plus recente retenue'
    $recreated = ConvertTo-DomeniaLiveObservation -Result (New-LivResult -Outcome 'NoConsole' -Guid 'guid-b') -Previous $previous -NowUtc $now
    Assert-Equal '' ([string]$recreated.LastUser) 'poste recree sous le meme nom : ancien compte oublie'
    $empty = ConvertTo-DomeniaLiveObservation -Result (New-LivResult -Outcome 'Observed' -User '   ') -Previous $null -NowUtc $now
    Assert-Equal 'Unavailable' ([string]$empty.Outcome) 'compte vide jamais observe'
    Assert-Equal 'Unavailable' ([string](ConvertTo-DomeniaLiveObservation -Result (New-LivResult -Outcome 'Pirate') -Previous $null -NowUtc $now).Outcome) 'resultat inconnu'
    $older = ConvertTo-DomeniaLiveObservation -Result (New-LivResult -Outcome 'NoConsole' -Presence 'Hors ligne' -PresenceCheckedUtc '2026-10-08T08:00:00.0000000Z') -Previous $previous -NowUtc $now
    Assert-Equal 'En ligne' ([string]$older.Presence) 'presence plus ancienne ignoree'
}
Test-Case -Id 'LIV-005' -Name 'Filtre de presence, perimetre de la recherche et cliche du cache' -Body {
    Assert-True (Test-DomeniaPresenceMatch -State 'En ligne (cache)' -Filter 'En ligne')
    Assert-True (Test-DomeniaPresenceMatch -State '' -Filter 'Inconnu')
    Assert-True (Test-DomeniaPresenceMatch -State 'Hors ligne' -Filter 'Hors ligne')
    Assert-False (Test-DomeniaPresenceMatch -State 'En ligne' -Filter 'Hors ligne')
    Assert-True (Test-DomeniaPresenceMatch -State 'En ligne' -Filter 'Tous')
    $base = 'OU=Postes,DC=example,DC=test'
    Assert-True (Test-DomeniaLiveRowInScope -Dn ('CN=PC-1,' + $base) -BaseDn $base -Scope 'OneLevel')
    Assert-False (Test-DomeniaLiveRowInScope -Dn ('CN=PC-2,OU=Etage,' + $base) -BaseDn $base -Scope 'OneLevel') 'sous-OU hors du niveau'
    Assert-True (Test-DomeniaLiveRowInScope -Dn ('CN=PC-2,OU=Etage,' + $base) -BaseDn $base -Scope 'Subtree')
    Assert-True (Test-DomeniaLiveRowInScope -Dn ('CN=Dupont\, Jean,' + $base) -BaseDn $base -Scope 'OneLevel') 'virgule echappee'
    Assert-False (Test-DomeniaLiveRowInScope -Dn 'CN=PC-3,OU=Autre,DC=example,DC=test' -BaseDn $base -Scope 'Subtree') 'autre OU'
    Assert-True (Test-DomeniaLiveRowInScope -Dn 'CN=PC-3,OU=Autre,DC=example,DC=test' -BaseDn '' -Scope 'Subtree') 'sans perimetre'
    $row = [pscustomobject]@{ Type = 'Machine'; Name = 'PC-1'; DN = ('CN=PC-1,' + $base); Description = ('x' * 5000); Password = 'jamais'; Guid = 'g' }
    $snapshot = ConvertTo-DomeniaLiveSnapshot -Row $row
    Assert-False ($null -ne $snapshot.PSObject.Properties['Password']) 'projection fixe : aucun champ libre'
    Assert-Equal 4096 ([string]$snapshot.Description).Length
    Assert-Equal ('cn=pc-1,' + $base.ToLowerInvariant()) (Get-DomeniaLiveObjectKey -Row $row)
    Assert-Equal 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' (Get-DomeniaLiveHash 'abc')
}
Test-Case -Id 'LIV-006' -Name 'Point 5 : une tentative plus recente en echec garde la derniere reussite datee et montre son erreur' -Body {
    # Committed projection: last success (PresenceCheckedUtc) and newer failed attempt (PresenceAttemptUtc, PresenceError).
    $failed = New-LivObservation -Presence 'Erreur de ping' -PresenceCheckedUtc '2026-10-08T09:00:00.0000000Z' -PresenceDetail 'DNS'
    $failed | Add-Member -NotePropertyName PresenceAttemptUtc -NotePropertyValue '2026-10-08T10:00:00.0000000Z'
    $failed | Add-Member -NotePropertyName PresenceError -NotePropertyValue 'Nom introuvable'
    $view = Get-DomeniaLivePresenceView -Observation $failed
    Assert-True ([string]$view.Detail -like '*Derni*re tentative UTC : 2026-10-08T10:00:00*non confirm*e : Nom introuvable*') ([string]$view.Detail)
    Assert-True ([string]$view.Detail -like '*Derni*re v*rification r*ussie UTC : 2026-10-08T09:00:00*conserv*e*') ([string]$view.Detail)
    Assert-Equal '2026-10-08T09:00:00.0000000Z' ([string]$view.Checked) 'date de la derniere reussite remplacee'
    $older = New-LivObservation -Presence 'En ligne' -PresenceCheckedUtc '2026-10-08T11:00:00.0000000Z'
    $older | Add-Member -NotePropertyName PresenceAttemptUtc -NotePropertyValue '2026-10-08T10:00:00.0000000Z'
    $older | Add-Member -NotePropertyName PresenceError -NotePropertyValue 'ancien echec'
    Assert-False ([string](Get-DomeniaLivePresenceView -Observation $older).Detail -like '*ancien echec*') 'echec plus ancien affiche'
    $console = New-LivObservation -Outcome 'Unavailable' -LastUser 'EX\ann'
    $console.UserCheckedUtc = '2026-10-08T08:00:00.0000000Z'
    $console | Add-Member -NotePropertyName ConsoleAttemptUtc -NotePropertyValue '2026-10-08T10:30:00.0000000Z'
    $console | Add-Member -NotePropertyName ConsoleError -NotePropertyValue 'RPC indisponible'
    $detail = [string](Get-DomeniaLiveObservationView -Observation $console).Detail
    Assert-True ($detail -like '*Derni*re tentative UTC : 2026-10-08T10:30:00*non confirm*e : RPC indisponible*Derni*re lecture r*ussie UTC : 2026-10-08T08:00:00*') $detail
    Assert-False (Test-DomeniaLiveAttemptAfter -Attempt 'pas une date' -Success '' -ErrorText 'x') 'date illisible jugee recente'
    Assert-True (Test-DomeniaLiveAttemptAfter -Attempt '2026-10-08T10:00:00Z' -Success '' -ErrorText 'x') 'echec sans reussite masque'
    Assert-False (Test-DomeniaLiveAttemptAfter -Attempt '2026-10-08T10:00:00Z' -Success '2026-10-08T09:00:00Z' -ErrorText '') 'tentative reussie prise pour un echec'
}
