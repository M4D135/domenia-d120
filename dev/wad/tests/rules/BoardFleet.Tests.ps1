# Tableau de bord du parc en widgets (decision David 2026-10-07) : fournisseur de donnees Fleet sur les agregats du
# worker FleetStats (decision David 2026-10-08, lot L01). Donnees fictives uniquement (domaine example.test).
. (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-BoardFleet.Model.ps1')
$script:BfInvariant = [Globalization.CultureInfo]::InvariantCulture
$script:BfNow = [datetime]::SpecifyKind([datetime]'2026-10-07T10:00:00',[DateTimeKind]::Local)
$script:BfScope = 'OU=Postes,OU=Lyon,DC=example,DC=test'
$script:BfLifecycle = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-WindowsLifecycle.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
function New-BfMachine {
    # One workstation as the worker groups it: system, version, logon bucket (0 <7 j ... 4 >180 j, 5 never), facts
    # (cr: created R recent / O older, pw: password O older than 60 j / R recent), LAPS (O valid, E expired, N none
    # visible, X absent from the schema, '' not read) and BitLocker (K keys, N none visible, X class absent, U unread).
    param([string]$Name,[string]$Container,[string]$Os,[string]$Ver = '',[int]$Lb = 0,[string]$Cr = 'O',[string]$Pw = 'R',[string]$Lk = 'O',[string]$Bk = 'U',[string]$St = 'A',[string]$Logon = '')
    return [pscustomobject]@{ name = $Name; distinguished_name = ('CN=' + $Name + ',' + $Container); object_guid = ('guid-' + $Name); st = $St; os = $Os; ver = $Ver; lb = $Lb; cr = $Cr; pw = $Pw; lk = $Lk; bk = $Bk; logon = $Logon }
}
function New-BfResult {
    # Test pivot shaped like the FleetStats output: the machines given are those the worker kept for the OU.
    param([object[]]$Machines = @(),[object[]]$Presence = @(),$Coverage = $null,[object[]]$History = @(),[switch]$Busy)
    $groups = New-Object System.Collections.ArrayList; $byKey = @{}; $rows = New-Object System.Collections.ArrayList; $gidByDn = @{}
    foreach ($machine in @($Machines)) {
        $key = (@($machine.st,$machine.os,$machine.ver,[string]$machine.lb,$machine.cr,$machine.pw,$machine.lk,$machine.bk) -join '|')
        if (-not $byKey.ContainsKey($key)) {
            $group = [pscustomobject]@{ gid = [string]($groups.Count + 1); st = $machine.st; os = $machine.os; ver = $machine.ver; lb = $machine.lb; cr = $machine.cr; pw = $machine.pw; lk = $machine.lk; bk = $machine.bk; n = 0 }
            $byKey[$key] = $group; [void]$groups.Add($group)
        }
        $byKey[$key].n = [int]$byKey[$key].n + 1
        $gidByDn[([string]$machine.distinguished_name).ToLowerInvariant()] = [string]$byKey[$key].gid
        [void]$rows.Add([pscustomobject]@{ name = $machine.name; distinguished_name = $machine.distinguished_name; object_guid = $machine.object_guid; gid = [string]$byKey[$key].gid; st = $machine.st; logon = $machine.logon })
    }
    $parents = @{}
    foreach ($machine in @($Machines | Where-Object { $_.st -ne 'D' })) { $parent = ([string]$machine.distinguished_name).Substring(([string]$machine.distinguished_name).IndexOf(',') + 1); $parents[$parent] = 1 + [int]$parents[$parent] }
    foreach ($row in @($Presence)) { if ([string]$row.gid -eq '' -and $gidByDn.ContainsKey([string]$row.object_key)) { $row.gid = $gidByDn[[string]$row.object_key] } }
    if ($null -eq $Coverage) {
        $active = @($Machines | Where-Object { $_.st -ne 'D' })
        $Coverage = [pscustomobject]@{ BitLockerRead = @($active | Where-Object { $_.bk -ne 'U' }).Count; BitLockerAt = $script:BfNow.ToUniversalTime().AddDays(-1).ToString('o'); FactsFresh = @($active | Where-Object { $_.cr -or $_.pw }).Count; FactsStale = 0; FactsAt = '' }
    }
    $types = @([pscustomobject]@{ t = 'Utilisateur'; s = 'Actif'; n = 40 }, [pscustomobject]@{ t = 'Utilisateur'; s = 'Desactive'; n = 3 }, [pscustomobject]@{ t = 'Machine'; s = 'Actif'; n = 10 })
    return [pscustomobject]@{ Rows = @(); Busy = [bool]$Busy; Missing = $false; MachineCount = @($Machines | Where-Object { $_.st -ne 'D' }).Count; Types = $types; Groups = @($groups); Machines = @($rows); Parents = @(foreach ($p in $parents.Keys) { [pscustomobject]@{ p = $p; n = $parents[$p] } }); Coverage = $Coverage; Links = 12; LinkSources = @(); Presence = @($Presence); History = @($History) }
}
function New-BfInventory {
    param([string]$Model,[string]$Build,[double]$RamGb,[double]$DiskGb,[double]$FreeGb,[double]$BootDays)
    return [pscustomobject]@{ CheckedUtc=$script:BfNow.ToUniversalTime().AddHours(-2).ToString('o'); Model = $Model; Build = $Build; RamBytes = $RamGb * 1GB; DiskSize = $DiskGb * 1GB; DiskFree = $FreeGb * 1GB; LastBootUtc = $script:BfNow.ToUniversalTime().AddDays(0 - $BootDays).ToString('o') }
}
function New-BfPresence {
    # Observation already parsed and attached by GUID by the worker (in_scope false: selected workstation elsewhere).
    param($Machine,[double]$HoursAgo,$Observation,[bool]$InScope = $true)
    $Observation|Add-Member NoteProperty PresenceCheckedUtc ($script:BfNow.ToUniversalTime().AddHours(0 - $HoursAgo).ToString('o')) -Force
    $Observation|Add-Member NoteProperty ObservedUtc ($script:BfNow.ToUniversalTime().AddHours(0 - $HoursAgo).ToString('o')) -Force
    return [pscustomobject]@{ object_key = ([string]$Machine.distinguished_name).ToLowerInvariant(); checked_utc = $script:BfNow.ToUniversalTime().AddHours(0 - $HoursAgo).ToString('o'); observation = $Observation; gid = ''; name = $Machine.name; distinguished_name = $Machine.distinguished_name; object_guid = $Machine.object_guid; in_scope = $InScope }
}
function Get-BfMachines {
    # Seven active workstations of OU=Postes,OU=Lyon (sub-OU, nested sub-OU, directly in the OU) and one disabled.
    return @(
        (New-BfMachine 'PC-L01' ('OU=Compta,' + $script:BfScope) 'Microsoft Windows 10 Professionnel' '10.0 (19045)' 0 'O' 'R' 'O' 'K' -Logon '2026-10-05')
        (New-BfMachine 'PC-L02' ('OU=Compta,' + $script:BfScope) 'Windows 11 Professional' '10.0 (26100)' 1 'O' 'R' 'N' 'N' -Logon '2026-09-20')
        (New-BfMachine 'PC-L03' ('OU=Accueil,' + $script:BfScope) 'Windows 11 Pro' '10.0 (22631)' 2 'R' 'R' 'O' 'K' -Logon '2026-08-20')
        (New-BfMachine 'PC-L04' ('OU=Etage2,OU=Compta,' + $script:BfScope) 'Windows 11 Entreprise' '10.0 (26100)' 3 'O' 'O' 'O' 'U' -Logon '2026-06-20')
        (New-BfMachine 'PC-L05' $script:BfScope 'Windows 10 Entreprise LTSC' '10.0 (19044)' 4 'O' 'O' 'E' 'U' -Logon '2026-01-20')
        (New-BfMachine 'PC-L06' ('OU=Compta,' + $script:BfScope) 'Windows 11 Entreprise' '10.0 (26100)' 5 'O' 'R' 'O' 'U')
        (New-BfMachine 'PC-L07' ('OU=Compta,' + $script:BfScope) '' '' 0 '' '' '' 'U' -Logon '2026-10-06')
        (New-BfMachine 'PC-L08' ('OU=Compta,' + $script:BfScope) 'Windows 10 Pro' '10.0 (19045)' 4 'O' 'O' 'O' 'U' 'D')
    )
}
function Get-BfPresenceRows {
    $m = @{}; foreach ($machine in @(Get-BfMachines)) { $m[$machine.name] = $machine }
    $paris = New-BfMachine 'PC-P01' 'OU=Postes,OU=Paris,DC=example,DC=test' 'Windows 10 Pro' '10.0 (19045)' 0
    return @(
        (New-BfPresence $m['PC-L01'] 2 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\jdupont'; Guid = 'guid-PC-L01'; Inventory = (New-BfInventory 'Latitude 5440' '19045' 8 256 20 40) }))
        (New-BfPresence $m['PC-L02'] 5 ([pscustomobject]@{ Presence = 'Sans reponse au ping'; LinkUser = 'ex\JDUPONT'; Guid = 'guid-PC-L02' }))
        (New-BfPresence $m['PC-L03'] 24 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = ''; Guid = 'guid-PC-L03'; Inventory = (New-BfInventory 'latitude 5440' '26100' 16 512 300 2) }))
        (New-BfPresence $m['PC-L04'] (10 * 24) ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\mmartin'; Guid = 'guid-PC-L04' }))
        (New-BfPresence $m['PC-L05'] (40 * 24) ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\ancien'; Guid = 'guid-PC-L05' }))
        (New-BfPresence $paris 0.5 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\pmartin'; Guid = 'guid-PC-P01' }) $false)
    )
}
function Get-BfBoard {
    param([string]$Scope = $script:BfScope,$Lifecycle = $script:BfLifecycle,[object[]]$Machines = @(Get-BfMachines),[object[]]$Presence = @(Get-BfPresenceRows),[object[]]$History = @(),$HealthPolicy=$null)
    return Get-DomeniaFleetBoardData -Result (New-BfResult -Machines $Machines -Presence $Presence -History $History) -Scope $Scope -Now $script:BfNow -Lifecycle $Lifecycle -HealthPolicy $HealthPolicy
}
function Get-BfPart {
    param($Entry,[string]$Label)
    foreach ($part in @($Entry.Items)) { if ([string]$part.Label -ceq $Label) { return [double]$part.Value } }
    return -1
}
function Get-BfJoined {
    param($Entry,[string]$Field)
    return (@(@($Entry.Items) | ForEach-Object { if ($Field -eq 'Value') { [string][int]$_.Value } else { [string]$_.$Field } }) -join '|')
}
function Get-BfTexts { param($Board) return @(@($Board.Attention) | ForEach-Object { [string]$_.Level + ':' + [string]$_.Text }) }

Test-Case -Id 'BF-001' -Name 'Parc : cles du catalogue Fleet, disposition livree remplie, fournisseur pur' -Body {
    $board = Get-BfBoard
    $catalog = @(Get-DomeniaBoardCatalog -Board Fleet | ForEach-Object { [string]$_.Key })
    foreach ($key in @($board.Entries.Keys)) { Assert-True ($catalog -contains [string]$key) ('Cle hors catalogue : ' + $key) }
    foreach ($item in @(Get-DomeniaBoardDefaultLayout -Board Fleet)) { Assert-True ($board.Entries.ContainsKey([string]$item.Key)) ('Widget livre sans donnees : ' + $item.Key) }
    Assert-Equal 'Fleet' ([string]$board.Board)
    $source = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-BoardFleet.Model.ps1'))
    Assert-False ($source -match '\$script:') 'Fournisseur pur : aucun etat de script'
    Assert-False ($source -match 'System\.Windows') 'Fournisseur pur : aucun WPF'
    Assert-False ($source -match 'ReadAllText|Get-Content|\[IO\.File\]') 'Fournisseur pur : aucun disque'
}
Test-Case -Id 'BF-002' -Name 'Parc : cibles = postes actifs du perimetre, comptes desactives a part, observations en minuscules' -Body {
    $board = Get-BfBoard
    Assert-Equal $script:BfScope ([string]$board.Last.Scope)
    Assert-Equal 'PC-L01,PC-L02,PC-L03,PC-L04,PC-L05,PC-L06,PC-L07' (@(@($board.Last.Targets) | ForEach-Object { [string]$_.name }) -join ',')
    Assert-Equal 'guid-PC-L03' ([string]@($board.Last.Targets)[2].object_guid)
    Assert-Equal 8 @($board.Last.Machines).Count 'Lignes du worker conservees pour les points'
    Assert-Equal '8' ([string]$board.Entries['fleet.machines'].Value)
    Assert-Equal '7 activés · 1 désactivés · 0 état inconnu · OU et sous-OU' ([string]$board.Entries['fleet.machines'].Detail)
    Assert-Equal '1' ([string]$board.Entries['fleet.disabled'].Value) 'Comptes desactives comptes a part'
    Assert-True ((Get-BfTexts $board) -contains 'Info:1 compte(s) ordinateur désactivé(s) encore dans lʼOU : à déplacer ou supprimer.') 'Point des comptes desactives'
    Assert-Equal 4 $board.Observations.Count 'Observations expirées ou hors du périmètre exclues de la projection du parc'
    Assert-False ($board.Observations.ContainsKey('cn=pc-p01,ou=postes,ou=paris,dc=example,dc=test')) 'La fiche hors OU est relue séparément par GUID depuis SQLite'
    Assert-False ($board.Observations.ContainsKey('cn=pc-l05,ou=postes,ou=lyon,dc=example,dc=test')) 'Observation de plus de 30 jours ecartee'
    foreach ($key in @($board.Observations.Keys)) { Assert-Equal ([string]$key).ToLowerInvariant() ([string]$key) }
}
Test-Case -Id 'BF-003' -Name 'Parc : derniere connexion en tranches, tranches vides gardees, inactifs a 14 jours pres et jamais connectes' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.lastlogon']
    Assert-Equal 'Series' ([string]$entry.Kind)
    # Lot L06 (CO-16): buckets named with their unit.
    Assert-Equal '0 à 6 j|7 à 29 j|30 à 89 j|90 à 179 j|180 j et plus|non renseignée' (Get-BfJoined $entry 'Label')
    Assert-Equal '2|1|1|1|1|1' (Get-BfJoined $entry 'Value')
    Assert-Equal '2 poste(s) sur 7' ([string]$entry.Detail)
    Assert-Equal '2' ([string]$board.Entries['fleet.stale'].Value)
    Assert-Equal 'Warn' ([string]$board.Entries['fleet.stale'].State)
    $texts = Get-BfTexts $board
    Assert-True ($texts -contains 'Warn:2 poste(s) sans connexion au domaine depuis 90 jours ou plus (date AD approximative) : à vérifier.') 'Inactifs signales'
    Assert-True ($texts -contains 'Warn:1 compte(s) ordinateur sans date de connexion AD renseignée.') 'Jamais connectes signales'
    Assert-True ($texts -contains 'Warn:2 poste(s) avec un mot de passe machine de plus de 60 jours.') 'Mot de passe machine ancien'
    Assert-True ($texts -contains 'Info:1 poste(s) créé(s) ces 30 derniers jours.') 'Postes recents'
    Assert-Equal '1' ([string]$board.Entries['fleet.created'].Value)
    Assert-Equal '2' ([string]$board.Entries['fleet.pwdold'].Value)
}
Test-Case -Id 'BF-004' -Name 'Parc : versions de Windows et fin de service, Windows 10 hors LTSC compte seul' -Body {
    $board = Get-BfBoard
    $os = $board.Entries['fleet.os']
    Assert-Equal 2 (Get-BfPart $os 'Windows 11 Entreprise')
    Assert-Equal 1 (Get-BfPart $os 'Systeme non renseigne')
    $versions = $board.Entries['fleet.versions']
    Assert-Equal 2 (Get-BfPart $versions 'Windows 11 24H2 Entreprise')
    Assert-Equal 1 (Get-BfPart $versions 'Windows 10 LTSC 2021')
    Assert-Equal 1 (Get-BfPart $versions 'Version non lue')
    Assert-Equal '7 postes' ([string]$versions.CenterText)
    Assert-Equal '2' ([string]$board.Entries['fleet.eos'].Value) 'Windows 10 22H2 Pro et Windows 11 23H2 Pro hors service'
    Assert-Equal 'Alert' ([string]$board.Entries['fleet.eos'].State)
    Assert-Equal '1' ([string]$board.Entries['fleet.win10'].Value) 'La LTSC 2021 nʼest pas comptee comme Windows 10 en fin de service'
    $texts = Get-BfTexts $board
    Assert-True ($texts -contains 'Alert:1 poste(s) sous Windows 10 22H2 Pro, fin de service le 14/10/2025 : à migrer.') 'Windows 10 22H2 critique'
    Assert-True ($texts -contains 'Alert:1 poste(s) sous Windows 11 23H2 Pro, fin de service le 11/11/2025 : à migrer.') 'Windows 11 23H2 Pro critique'
    Assert-True ($texts -contains 'Warn:1 poste(s) sous Windows 11 24H2 Pro, fin de service le 13/10/2026.') '24H2 Pro a surveiller'
    Assert-Equal 0 @($texts | Where-Object { $_ -like '*LTSC*' }).Count 'LTSC 2021 jamais signalee avant 2027'
}
Test-Case -Id 'BF-005' -Name 'Parc : postes par sous-OU depuis les DN parents, par OU sur le domaine, dix au plus' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.ou']
    Assert-Equal 'Postes par sous-OU' ([string]$entry.Title)
    Assert-Equal 3 @($entry.Items).Count
    Assert-Equal 5 (Get-BfPart $entry 'Compta')
    Assert-Equal 1 (Get-BfPart $entry 'Accueil')
    Assert-Equal 1 (Get-BfPart $entry '(directement dans l OU)')
    $whole = @(Get-BfMachines) + @((New-BfMachine 'PC-P01' 'OU=Postes,OU=Paris,DC=example,DC=test' 'Windows 11 Pro' '10.0 (26200)' 0), (New-BfMachine 'PC-C01' 'CN=Computers,DC=example,DC=test' 'Windows 11 Pro' '10.0 (26200)' 0))
    $all = Get-BfBoard -Scope '' -Machines $whole
    $ou = $all.Entries['fleet.ou']
    Assert-Equal '' ([string]$ou.Title)
    Assert-Equal 4 (Get-BfPart $ou 'Compta')
    Assert-Equal 1 (Get-BfPart $ou 'Etage2')
    Assert-Equal 2 (Get-BfPart $ou 'Postes')
    Assert-Equal 1 (Get-BfPart $ou 'Hors OU')
    Assert-Equal '9 activés · 1 désactivés · 0 état inconnu · domaine indexé' ([string]$all.Entries['fleet.machines'].Detail)
    $many = @(foreach ($i in 1..12) { New-BfMachine ('PC-S' + $i) ('OU=Site' + ('{0:00}' -f $i) + ',' + $script:BfScope) 'Windows 11 Pro' '10.0 (26200)' 0 })
    $items = @((Get-BfBoard -Machines $many -Presence @()).Entries['fleet.ou'].Items)
    Assert-Equal 11 $items.Count
    Assert-Equal 'Site01' ([string]$items[0].Label)
    Assert-Equal 'Autres' ([string]$items[10].Label)
    Assert-Equal 2 ([double]$items[10].Value)
}
Test-Case -Id 'BF-006' -Name 'Parc : presence des postes analyses (moins de 30 j), couverture N sur M, jamais plus que les postes' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.presence']
    Assert-Equal 'En ligne|Sans réponse|Non vérifié' (Get-BfJoined $entry 'Label')
    Assert-Equal '3|1|3' (Get-BfJoined $entry 'Value')
    Assert-Equal '7 postes' ([string]$entry.CenterText)
    $expected = '4 postes analysés sur 7, le ' + $script:BfNow.AddHours(-2).ToString('dd/MM',$script:BfInvariant)
    Assert-Equal $expected ([string]$entry.Detail)
    Assert-Equal 'Off' ([string]$entry.State) 'Le relevé récent ne masque pas celui datant de dix jours'
    Assert-True ((Get-BfTexts $board) -contains 'Info:1 poste(s) sans réponse au dernier relevé.') 'Sans reponse signale'
    $old = @(foreach ($row in @(Get-BfPresenceRows)) { $copy = $row.PSObject.Copy(); $copy.checked_utc = $script:BfNow.ToUniversalTime().AddDays(-10).ToString('o'); $copy })
    Assert-Equal 'Off' ([string](Get-BfBoard -Presence $old).Entries['fleet.presence'].State) 'Releves de plus de 7 jours grises'
}
Test-Case -Id 'BF-007' -Name 'Parc : utilisateurs distincts sans la casse, meme utilisateur sur deux postes = 1' -Body {
    $board = Get-BfBoard
    Assert-Equal '2' ([string]$board.Entries['fleet.users'].Value)
    Assert-Equal 'sur 3 poste(s) avec une session · 12 associations au total' ([string]$board.Entries['fleet.users'].Detail)
    $expected = $script:BfNow.AddHours(-2).ToString('dd/MM HH:mm',$script:BfInvariant)
    Assert-Equal $expected ([string]$board.Entries['fleet.lastcheck'].Value)
    Assert-Equal '8 comptes ordinateur dans le périmètre : 7 activés · 1 désactivés · 0 état inconnu · OU et sous-OU.' ([string]$board.Summary)
}
Test-Case -Id 'BF-008' -Name 'Parc : releves WMI des postes analyses (modeles, memoire, disque plein, redemarrage)' -Body {
    $board = Get-BfBoard
    $models = $board.Entries['fleet.models']
    Assert-Equal 2 (Get-BfPart $models 'Latitude 5440')
    Assert-Equal '2 postes' ([string]$models.CenterText)
    $releases = $board.Entries['fleet.releases']
    Assert-Equal 1 (Get-BfPart $releases 'Windows 10 22H2')
    Assert-Equal 1 (Get-BfPart $releases 'Windows 11 24H2')
    Assert-Equal '0|1|1|0|0' (Get-BfJoined $board.Entries['fleet.ram'] 'Value')
    Assert-Equal '1|0|0|1' (Get-BfJoined $board.Entries['fleet.diskfree'] 'Value')
    Assert-Equal '1' ([string]$board.Entries['fleet.lowdisk'].Value)
    Assert-Equal 'Alert' ([string]$board.Entries['fleet.lowdisk'].State)
    Assert-Equal '1' ([string]$board.Entries['fleet.uptime'].Value)
    $texts = Get-BfTexts $board
    Assert-True ($texts -contains 'Alert:1 poste(s) avec moins de 10 % libre sur C:.') 'Disque plein signale'
    Assert-True ($texts -contains 'Warn:1 poste(s) non redémarré(s) depuis plus de 30 jours.') 'Redemarrage signale'
    $point = @(@($board.Attention) | Where-Object { [string]$_.Point -eq 'lowdisk' })[0]
    Assert-Equal 'PC-L01' ([string]@($point.Machines)[0].name) 'Poste du point d attention observe'
}
Test-Case -Id 'BF-009' -Name 'Parc : sans releve WMI, section remplacee par une indication et widgets omis' -Body {
    $rows = @(Get-BfPresenceRows)
    $board = Get-BfBoard -Presence @($rows[1])
    Assert-True (([string]$board.Hints['Relevés des postes']).StartsWith('Relever ce périmètre')) 'Indication de la section'
    Assert-Equal ([string]$board.Hints['Relevés des postes']) ([string]$board.Hints['Releves WMI']) 'Ancienne section des dispositions personnalisees'
    foreach ($key in @('fleet.models','fleet.releases','fleet.ram','fleet.diskfree','fleet.lowdisk','fleet.uptime')) { Assert-False ($board.Entries.ContainsKey($key)) ('Widget sans donnees emis : ' + $key) }
    $none = Get-BfBoard -Presence @()
    Assert-Equal 'Aucune' ([string]$none.Entries['fleet.lastcheck'].Value)
    Assert-Equal '0 poste analysé sur 7' ([string]$none.Entries['fleet.lastcheck'].Detail)
}
Test-Case -Id 'BF-010' -Name 'Parc : perimetre vide, indication explicite sans score invente' -Body {
    $board = Get-BfBoard -Machines @() -Presence @()
    Assert-Equal '0' ([string]$board.Entries['fleet.machines'].Value)
    Assert-Equal 0 @($board.Last.Targets).Count
    foreach ($key in @('fleet.os','fleet.lastlogon','fleet.ou','fleet.presence','fleet.versions')) { Assert-False ($board.Entries.ContainsKey($key)) ('Widget sans donnees emis : ' + $key) }
    Assert-True ([string]$board.Hints['Répartition']) 'Indication de repartition'
    Assert-Equal 'Aucun poste évalué' ([string]$board.Entries['fleet.health'].Value)
    Assert-Equal $null $board.Entries['fleet.health'].Number
    Assert-Equal 'Aucun problème établi' ([string]$board.Entries['fleet.attention'].Value)
}
Test-Case -Id 'BF-011' -Name 'Parc : score proportionnel aux postes, points du plus grave au moins grave' -Body {
    $board = Get-BfBoard
    $health = $board.Entries['fleet.health']
    Assert-Equal 'Critique' ([string]$health.Value)
    Assert-Equal 0 $health.Number '6 postes avec probleme etablis, 1 poste encore incomplet'
    # Point 74: one workstation not evaluated, the share evaluated is shown beside the score (6 of 7, 85 %).
    Assert-Equal '0 poste sur 6 évalués sans point détecté · 1 non évalué(s) · couverture 85 % (6 évalué(s) sur 7)' ([string]$health.Detail)
    $list = $board.Entries['fleet.attention']
    $levels = @(@($list.Items) | ForEach-Object { [string]$_.Level })
    Assert-Equal 'Alert' $levels[0]
    Assert-Equal 'Info' $levels[$levels.Count - 1]
    # 26 workstations, 4 with a point to watch: 22 out of 26, 84 %.
    $machines = @(foreach ($i in 1..22) { New-BfMachine ('PC-OK' + $i) $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 0 -Logon '2026-10-06' }) + @(foreach ($i in 1..4) { New-BfMachine ('PC-OLD' + $i) $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 3 -Logon '2026-06-01' })
    $fleet = Get-BfBoard -Machines $machines -Presence @() -HealthPolicy (ConvertTo-DomeniaHealthPolicy @{DisabledRules=@('bitlocker.none','lowdisk','disk.tight','uptime')})
    Assert-Equal 'À surveiller' ([string]$fleet.Entries['fleet.health'].Value)
    Assert-Equal 84 $fleet.Entries['fleet.health'].Number
    Assert-Equal '22 postes sur 26 évalués sans point détecté · 0 non évalué(s)' ([string]$fleet.Entries['fleet.health'].Detail)
}
Test-Case -Id 'BF-012' -Name 'Parc : resultat du worker en tableau, base occupee et reponse incomplete' -Body {
    $result = New-BfResult -Machines @(Get-BfMachines) -Presence @(Get-BfPresenceRows)
    $board = Get-DomeniaFleetBoardData -Result @('sortie intermediaire', $result) -Scope $script:BfScope -Now $script:BfNow -Lifecycle $script:BfLifecycle
    Assert-Equal '8' ([string]$board.Entries['fleet.machines'].Value)
    $cases = @(
        @([pscustomobject]@{ Rows = @(); Busy = $true; Missing = $false; MachineCount = 0 }, 'base occupee, reessayez dans un instant.'),
        @([pscustomobject]@{ Rows = @(); Busy = $false; Missing = $true; MachineCount = 0 }, 'reponse incomplete.'),
        @($null, 'reponse incomplete.')
    )
    foreach ($case in $cases) {
        $message = ''
        try { [void](Get-DomeniaFleetBoardData -Result $case[0] -Scope '' -Now $script:BfNow) } catch { $message = $_.Exception.Message }
        Assert-Equal ([string]$case[1]) $message
    }
    $message = ''
    try { [void](Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines) -Busy) -Scope '' -Now $script:BfNow) } catch { $message = $_.Exception.Message }
    Assert-Equal 'base occupee, reessayez dans un instant.' $message
}
Test-Case -Id 'BF-014' -Name 'Parc : OU sans les sous-OU, profondeur gardee pour les widgets de requete' -Body {
    $direct = @(@(Get-BfMachines) | Where-Object { $_.name -eq 'PC-L05' })
    $board = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines $direct) -Scope $script:BfScope -Subtree $false -Now $script:BfNow -Lifecycle $script:BfLifecycle
    Assert-Equal '1' ([string]$board.Entries['fleet.machines'].Value)
    Assert-Equal '1 activés · 0 désactivés · 0 état inconnu · OU directe' ([string]$board.Entries['fleet.machines'].Detail)
    Assert-False ([bool]$board.Last.Subtree) 'Profondeur conservee pour les widgets de requete'
}
Test-Case -Id 'BF-015' -Name 'Parc : un point deplie ses postes depuis la memoire, 200 au plus, par ordre de nom' -Body {
    $board = Get-BfBoard
    $stale = @(@($board.Attention) | Where-Object { [string]$_.Point -eq 'stale' })[0]
    $targets = @(Get-DomeniaFleetPointTargets -Machines @($board.Last.Machines) -Point $stale)
    Assert-Equal 'PC-L04,PC-L05' (@($targets | ForEach-Object { [string]$_.name }) -join ',')
    $disabled = @(@($board.Attention) | Where-Object { [string]$_.Point -eq 'disabled' })[0]
    Assert-Equal 'PC-L08' ([string]@(Get-DomeniaFleetPointTargets -Machines @($board.Last.Machines) -Point $disabled)[0].name)
    $many = @(foreach ($i in 1..250) { New-BfMachine ('PC-N' + ('{0:000}' -f $i)) $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 5 })
    $wide = Get-BfBoard -Machines $many -Presence @()
    $never = @(@($wide.Attention) | Where-Object { [string]$_.Point -eq 'never' })[0]
    $capped = @(Get-DomeniaFleetPointTargets -Machines @($wide.Last.Machines) -Point $never)
    Assert-Equal 200 $capped.Count
    Assert-Equal 'PC-N001' ([string]$capped[0].name)
}
Test-Case -Id 'BF-016' -Name 'Fin de service : LTSC 2019/2021, LTSB 2016 et IoT non critiques avec leur date, table absente jamais critique' -Body {
    $now = $script:BfNow
    $ltsc2019 = Get-DomeniaWindowsRelease -Build '10.0 (17763)' -Caption 'Windows 10 Entreprise LTSC' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Windows 10 LTSC 2019' ([string]$ltsc2019.Name); Assert-Equal 'Ok' ([string]$ltsc2019.Status); Assert-Equal '09/01/2029' ([string]$ltsc2019.End)
    $ltsc2021 = Get-DomeniaWindowsRelease -Build '19044' -Caption 'Microsoft Windows 10 Enterprise LTSC' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Windows 10 LTSC 2021' ([string]$ltsc2021.Name); Assert-True ([string]$ltsc2021.Status -in @('Ok','Soon')) 'LTSC 2021 maintenue'
    $ltsb = Get-DomeniaWindowsRelease -Build '14393' -Caption 'Windows 10 Entreprise 2016 LTSB' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Windows 10 LTSB 2016' ([string]$ltsb.Name); Assert-Equal 'Soon' ([string]$ltsb.Status) 'LTSB 2016 : fin le 13/10/2026'; Assert-Equal '13/10/2026' ([string]$ltsb.End)
    $iot = Get-DomeniaWindowsRelease -Build '19044' -Caption 'Windows 10 IoT Entreprise LTSC' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Windows 10 IoT LTSC 2021' ([string]$iot.Name); Assert-Equal 'Ok' ([string]$iot.Status); Assert-Equal '13/01/2032' ([string]$iot.End)
    $pro = Get-DomeniaWindowsRelease -Build '19044' -Caption 'Windows 10 Professionnel' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Ended' ([string]$pro.Status) 'Windows 10 21H2 Pro hors service'
    $unread = Get-DomeniaWindowsRelease -Build '' -Caption 'Windows 10 Professionnel' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Ended' ([string]$unread.Status) 'Windows 10 sans build : toutes les versions Pro sont hors service'
    Assert-True ([string]$unread.Note -like 'Fin de service au plus tard le 14/10/2025*') ('Note : ' + [string]$unread.Note)
    $blind = Get-DomeniaWindowsRelease -Build '19045' -Caption 'Windows 10 Professionnel' -Lifecycle $null -Now $now
    Assert-Equal 'Unknown' ([string]$blind.Status) 'Sans table : date inconnue'
    Assert-True ([string]$blind.Note -like '*date de fin inconnue*') ('Note : ' + [string]$blind.Note)
    $board = Get-BfBoard -Lifecycle $null
    Assert-Equal 'Non déterminé' ([string]$board.Entries['fleet.eos'].Value)
    Assert-Equal 'Table des fins de service absente : date de fin inconnue.' ([string]$board.Entries['fleet.eos'].Detail)
    Assert-Equal 0 @(@($board.Attention) | Where-Object { [string]$_.Point -like 'eos*' }).Count 'Jamais critique sans table'
    $server = Get-DomeniaWindowsRelease -Build '26100' -Caption 'Microsoft Windows Server 2025 Datacenter' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Windows Server 2025' ([string]$server.Name); Assert-Equal 'Ok' ([string]$server.Status)
    # Pro Education follows the Pro dates (table Families.Pro), not the Education ones: 23H2 Pro ended on 11/11/2025.
    foreach ($caption in @('Windows 11 Professionnel Éducation','Microsoft Windows 11 Pro Education','Windows 10 Pro for Workstations')) { Assert-Equal 'Pro' (Get-DomeniaWindowsFamily $caption) $caption }
    Assert-Equal 'Enterprise' (Get-DomeniaWindowsFamily 'Windows 11 Éducation'); Assert-Equal 'Enterprise' (Get-DomeniaWindowsFamily 'Windows 10 Education')
    $proEdu = Get-DomeniaWindowsRelease -Build '10.0 (22631)' -Caption 'Windows 11 Professionnel Éducation' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Ended' ([string]$proEdu.Status) 'Windows 11 23H2 Pro Education hors service'; Assert-Equal '11/11/2025' ([string]$proEdu.End)
    $edu = Get-DomeniaWindowsRelease -Build '10.0 (22631)' -Caption 'Windows 11 Éducation' -Lifecycle $script:BfLifecycle -Now $now
    Assert-Equal 'Enterprise' ([string]$edu.Family); Assert-True ([string]$edu.Status -in @('Ok','Soon')) 'Windows 11 23H2 Education maintenue'
}
Test-Case -Id 'BF-017' -Name 'LAPS et BitLocker : rien de visible sur M postes = non determine, jamais M postes sans' -Body {
    $machines = @(foreach ($i in 1..5) { New-BfMachine ('PC-S' + $i) $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 0 'O' 'R' 'N' 'N' })
    $board = Get-BfBoard -Machines $machines -Presence @()
    Assert-Equal 'Non déterminé' ([string]$board.Entries['fleet.laps'].Value)
    Assert-True ([string]$board.Entries['fleet.laps'].Detail -like 'Aucune expiration LAPS visible avec ce compte sur 5 poste(s)*') ([string]$board.Entries['fleet.laps'].Detail)
    Assert-Equal 'Non déterminé' ([string]$board.Entries['fleet.bitlocker'].Value)
    Assert-True ([string]$board.Entries['fleet.bitlocker'].Detail -like 'Aucune clé visible avec ce compte (droits ou clés non sauvegardées dans AD)*') ([string]$board.Entries['fleet.bitlocker'].Detail)
    Assert-Equal 0 @(@($board.Attention) | Where-Object { [string]$_.Point -in @('laps.none','bitlocker.none') }).Count 'Aucun point sans valeur visible'
    Assert-Equal 'Données insuffisantes' ([string]$board.Entries['fleet.health'].Value) 'Non determine ne fabrique pas un bon etat'
    $absent = @(foreach ($i in 1..3) { New-BfMachine ('PC-X' + $i) $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 0 'O' 'R' 'X' 'X' })
    $missing = Get-BfBoard -Machines $absent -Presence @()
    Assert-Equal 'Non disponible' ([string]$missing.Entries['fleet.laps'].Value)
    Assert-True ([string]$missing.Entries['fleet.laps'].Detail -like 'Non disponible dans ce domaine*') 'LAPS absent du schema'
    Assert-Equal 'Non disponible' ([string]$missing.Entries['fleet.bitlocker'].Value)
    $unread = @(foreach ($i in 1..3) { New-BfMachine ('PC-U' + $i) $script:BfScope 'Windows 11 Entreprise' '' 0 '' '' '' 'U' })
    $old = Get-BfBoard -Machines $unread -Presence @()
    Assert-Equal 'Non lu' ([string]$old.Entries['fleet.laps'].Value) 'Base construite avant ce lot'
    Assert-Equal 'Non lu' ([string]$old.Entries['fleet.created'].Value)
    Assert-Equal 'Non lu' ([string]$old.Entries['fleet.bitlocker'].Value)
    Assert-Equal 'BitLockerPresence' ([string]$old.Entries['fleet.bitlocker'].Action.Id) 'Bouton de lecture sur une OU'
    $domain = Get-BfBoard -Scope '' -Machines $unread -Presence @()
    Assert-True ($null -eq $domain.Entries['fleet.bitlocker'].Action) 'Pas de lecture a la racine du domaine'
    $stale = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines $unread -Coverage ([pscustomobject]@{ BitLockerRead = 0; BitLockerAt = ''; FactsFresh = 0; FactsStale = 3; FactsAt = '' })) -Scope $script:BfScope -Now $script:BfNow -Lifecycle $script:BfLifecycle
    Assert-Equal 'À relire' ([string]$stale.Entries['fleet.laps'].Value) 'Faits plus anciens que la derniere mise a jour'
    $mixed = @((New-BfMachine 'PC-A' $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 0 'O' 'R' 'O' 'K'), (New-BfMachine 'PC-B' $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 0 'O' 'R' 'N' 'N'))
    $seen = Get-BfBoard -Machines $mixed -Presence @()
    Assert-Equal '1' ([string]$seen.Entries['fleet.laps'].Value)
    Assert-Equal '1' ([string]$seen.Entries['fleet.bitlocker'].Value)
    Assert-True ([string]$seen.Entries['fleet.bitlocker'].Detail -like '2 postes analysés sur 2, le *') ([string]$seen.Entries['fleet.bitlocker'].Detail)
    Assert-True ((Get-BfTexts $seen) -contains 'Warn:1 poste(s) sans clé BitLocker visible.') 'Cle absente des qu une cle est visible'
}
Test-Case -Id 'BF-018' -Name 'Couverture, age des observations et plan de calcul du worker' -Body {
    $last = [datetime]::SpecifyKind([datetime]'2026-10-05T08:00:00',[DateTimeKind]::Utc)
    Assert-Equal ('12 postes analysés sur 40, le ' + $last.ToLocalTime().ToString('dd/MM',$script:BfInvariant)) (Get-DomeniaCoverageText -Analysed 12 -Total 40 -LastUtc $last)
    Assert-Equal '1 poste analysé sur 3' (Get-DomeniaCoverageText -Analysed 1 -Total 3)
    $now = $script:BfNow.ToUniversalTime()
    Assert-Equal 'Fresh' (Test-DomeniaObservationAge -CheckedUtc $now.AddDays(-2).ToString('o') -NowUtc $now)
    Assert-Equal 'Old' (Test-DomeniaObservationAge -CheckedUtc $now.AddDays(-8).ToString('o') -NowUtc $now)
    Assert-Equal 'Expired' (Test-DomeniaObservationAge -CheckedUtc $now.AddDays(-31).ToString('o') -NowUtc $now)
    Assert-Equal 'Fresh' (Test-DomeniaObservationAge -CheckedUtc $now.AddDays(-31).ToString('o') -NowUtc $now -MaxDays 60 -GreyDays 40)
    Assert-Equal 'Expired' (Test-DomeniaObservationAge -CheckedUtc 'illisible' -NowUtc $now)
    $plan = Get-DomeniaFleetQueryPlan -Now $script:BfNow -ObservationMaxAgeDays 30
    Assert-Equal '2026-09-30|2026-09-07|2026-07-09|2026-04-10' (@($plan.LogonBounds) -join '|')
    Assert-Equal '2026-10-07' ([string]$plan.Today)
    Assert-True ([string]$plan.PasswordBefore -like '2026-08-08T*Z') ([string]$plan.PasswordBefore)
    Assert-True ([string]$plan.ObservationsSince -like '2026-09-07T*') ([string]$plan.ObservationsSince)
}
Test-Case -Id 'BF-019' -Name 'Instantane quotidien : chiffres de l annuaire, courbe seulement apres 90 jours d historique' -Body {
    $board = Get-BfBoard
    Assert-Equal '2026-10-07' ([string]$board.Snapshot.Day)
    Assert-False ([bool]$board.Snapshot.Taken) 'Premier calcul du jour'
    Assert-Equal 7 ([int]$board.Snapshot.Figures.Machines)
    Assert-Equal 6 ([int]$board.Snapshot.Figures.Problems)
    Assert-False ($board.Entries.ContainsKey('fleet.trend')) 'Pas de courbe sans 90 jours'
    Assert-True ([string]$board.Hints['Évolution'] -like '*90 jours*') 'Indication de la courbe'
    $history = @(foreach ($d in 0..95) { [pscustomobject]@{ day = $script:BfNow.Date.AddDays(0 - $d).ToString('yyyy-MM-dd',$script:BfInvariant); figures = ('{"Machines":7,"Problems":' + [string]($d % 5) + '}') } })
    $trend = Get-BfBoard -History $history
    Assert-True ([bool]$trend.Snapshot.Taken) 'Instantane du jour deja pris'
    $entry = $trend.Entries['fleet.trend']
    Assert-Equal 'Timeline' ([string]$entry.Kind)
    Assert-Equal 90 @($entry.Items).Count
    Assert-Equal 'Line' (@(Get-DomeniaBoardVisuals -Kind Timeline)[0]) 'Courbe pour des valeurs datees'
    # FO-10: Windows 10, inactive and nearly full disks have their own curve; a snapshot without the figure (older
    # delivery, disks not read) is left out of that curve, never drawn as 0.
    Assert-Equal 1 ([int]$board.Snapshot.Figures.Windows10) 'Windows 10 hors LTSC dans l instantane'
    Assert-Equal 2 ([int]$board.Snapshot.Figures.Stale)
    Assert-Equal 1 ([int]$board.Snapshot.Figures.LowDisk) 'Disque plein des postes analyses'
    $noDisk = Get-BfBoard -Presence @()
    Assert-True ($null -eq $noDisk.Snapshot.Figures.LowDisk) 'Disques non lus : chiffre inconnu, jamais 0'
    Assert-False ($trend.Entries.ContainsKey('fleet.trend.win10')) 'Courbe sans aucun chiffre Windows 10'
    $rich = @(foreach ($d in 0..95) { [pscustomobject]@{ day = $script:BfNow.Date.AddDays(0 - $d).ToString('yyyy-MM-dd',$script:BfInvariant); figures = $(if ($d % 2) { '{"Machines":7,"Problems":1,"Windows10":' + [string]($d % 3) + ',"Stale":2,"LowDisk":null}' } else { '{"Machines":7,"Problems":1,"Windows10":1,"Stale":3,"LowDisk":1}' }) } })
    $curves = Get-BfBoard -History $rich
    Assert-Equal 90 @($curves.Entries['fleet.trend.win10'].Items).Count
    Assert-Equal 90 @($curves.Entries['fleet.trend.stale'].Items).Count
    Assert-Equal 45 @($curves.Entries['fleet.trend.lowdisk'].Items).Count 'Jours sans disque lu ecartes de la courbe'
    Assert-Equal '1' ([string]$curves.Entries['fleet.trend.lowdisk'].Value)
    foreach ($key in @('fleet.trend.win10','fleet.trend.stale','fleet.trend.lowdisk')) { Assert-Equal 'Timeline' ([string]$curves.Entries[$key].Kind) $key; Assert-True (@(Get-DomeniaBoardCatalog -Board Fleet | Where-Object { $_.Key -eq $key -and $_.Kind -eq 'Timeline' }).Count -eq 1) ('Courbe absente du catalogue : ' + $key) }
}
Test-Case -Id 'BF-020' -Name 'Windows 10 : etat tire de la table des fins de service, sans table jamais critique' -Body {
    $board = Get-BfBoard
    Assert-Equal 'Alert' ([string]$board.Entries['fleet.win10'].State)
    Assert-Equal 'Hors LTSC, LTSB et IoT : fin de service le 14/10/2025' ([string]$board.Entries['fleet.win10'].Detail)
    $blind = Get-BfBoard -Lifecycle $null
    Assert-Equal '1' ([string]$blind.Entries['fleet.win10'].Value)
    Assert-Equal 'Off' ([string]$blind.Entries['fleet.win10'].State) 'Sans table : jamais critique'
    Assert-True ([string]$blind.Entries['fleet.win10'].Detail -like '*date de fin inconnue*') ([string]$blind.Entries['fleet.win10'].Detail)
    $none = Get-BfBoard -Machines @((New-BfMachine 'PC-N1' $script:BfScope 'Windows 11 Entreprise' '10.0 (26100)' 0)) -Presence @()
    Assert-Equal 'Ok' ([string]$none.Entries['fleet.win10'].State)
    Assert-True (@(Get-DomeniaBoardDefaultLayout -Board Fleet | Where-Object { $_.Key -eq 'fleet.win10' }).Count -eq 1) 'Widget Windows 10 garde dans la disposition livree'
}
Test-Case -Id 'BF-021' -Name 'Serveurs / postes : tire de operatingSystem, au catalogue seulement' -Body {
    $machines = @(Get-BfMachines) + @((New-BfMachine 'SRV-L01' $script:BfScope 'Windows Server 2022 Standard' '10.0 (20348)' 0), (New-BfMachine 'SRV-L02' $script:BfScope 'Microsoft Windows Server 2025 Datacenter' '10.0 (26100)' 0))
    $board = Get-BfBoard -Machines $machines -Presence @()
    $entry = $board.Entries['fleet.servers']
    Assert-Equal 'Distribution' ([string]$entry.Kind)
    Assert-Equal '2 serveurs' ([string]$entry.Value)
    Assert-Equal 2 (Get-BfPart $entry 'Serveurs')
    Assert-Equal 6 (Get-BfPart $entry 'Postes de travail')
    Assert-Equal 1 (Get-BfPart $entry 'Système non renseigné')
    Assert-Equal '6 poste(s) de travail sur 9 comptes actifs' ([string]$entry.Detail)
    $item = Get-DomeniaBoardCatalogItem -Board Fleet -Key 'fleet.servers'
    Assert-True (($null -ne $item) -and (-not [bool]$item.Default)) 'Serveurs / postes au catalogue, hors disposition livree'
}
Test-Case -Id 'BF-022' -Name 'TE-07 : seuil disque du parc aligne sur le poste, tranches avec unites, cas du lot L01' -Body {
    # One workstation at 15 % free on C: is to watch, as on its own board (critical under 10 %, to watch under 20 %).
    $m = @{}; foreach ($machine in @(Get-BfMachines)) { $m[$machine.name] = $machine }
    $rows = @(
        (New-BfPresence $m['PC-L01'] 2 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\jdupont'; Guid = 'guid-PC-L01'; Inventory = (New-BfInventory 'Latitude 5440' '26100' 12 100 15 2) }))
        (New-BfPresence $m['PC-L02'] 2 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'ex\JDUPONT'; Guid = 'guid-PC-L02'; Inventory = (New-BfInventory 'Latitude 5440' '26100' 4 100 8 2) }))
    )
    $board = Get-BfBoard -Presence $rows
    Assert-Equal ('moins de 10 %|10 à 20 %|20 à 50 %|50 % et plus') (Get-BfJoined $board.Entries['fleet.diskfree'] 'Label')
    Assert-Equal '1|1|0|0' (Get-BfJoined $board.Entries['fleet.diskfree'] 'Value')
    Assert-Equal (Get-DomeniaBoardColor 'Warn') ([string]@($board.Entries['fleet.diskfree'].Items)[1].Color) 'tranche a surveiller coloree comme sur le poste'
    $texts = Get-BfTexts $board
    Assert-True ($texts -contains ('Warn:1 poste(s) avec peu d' + [char]0x02BC + 'espace sur C: (moins de 20 % libre).')) ($texts -join ' | ')
    Assert-True ($texts -contains 'Alert:1 poste(s) avec moins de 10 % libre sur C:.') ($texts -join ' | ')
    Assert-Equal '1' ([string]$board.Entries['fleet.lowdisk'].Value) 'presque plein : sous 10 % seulement'
    Assert-Equal 1 ([int]$board.Snapshot.Figures.LowDisk) 'instantane inchange : disques presque pleins'
    # Memory buckets with their unit: 12 Go is in 9 to 16 Go, never in 16 Go.
    Assert-Equal ([string][char]0x2264 + ' 4 Go|5 à 8 Go|9 à 16 Go|17 à 32 Go|> 32 Go') (Get-BfJoined $board.Entries['fleet.ram'] 'Label')
    Assert-Equal '1|0|1|0|0' (Get-BfJoined $board.Entries['fleet.ram'] 'Value')
    # Cases of lot L01 kept in this suite: one user seen on two workstations, an observation of a workstation outside the
    # displayed perimeter, LTSC never critical.
    Assert-Equal '1' ([string]$board.Entries['fleet.users'].Value) 'meme utilisateur sur deux postes = 1'
    $outside = @(Get-BfPresenceRows | Where-Object { [string]$_.name -eq 'PC-P01' })
    $alone = Get-BfBoard -Presence $outside
    Assert-Equal '0' ([string]$alone.Entries['fleet.users'].Value) 'poste hors perimetre non compte'
    Assert-Equal 0 @(Get-BfTexts (Get-BfBoard) | Where-Object { ($_ -like '*LTSC*') -and ($_ -like 'Alert:*') }).Count 'LTSC jamais critique'
}

Test-Case -Id 'BF-023' -Name 'Parc : detail sante exact sans doublon, tous les actifs repartis' -Body {
    $board=Get-BfBoard
    Assert-Equal ([int]$board.Population.Healthy) @($board.Last.HealthyTargets).Count 'Detail des postes sans point'
    Assert-Equal ([int]$board.Population.Total-[int]$board.Population.Healthy-[int]$board.Population.Unassessed) @($board.Last.ProblemTargets).Count 'Detail des postes avec points'
    $ids=@(@($board.Last.HealthyTargets)+@($board.Last.ProblemTargets)+@($board.Last.UnknownTargets)|ForEach-Object{$_.object_guid})
    Assert-Equal @($board.Last.Targets).Count @($ids|Select-Object -Unique).Count 'Chaque actif une fois'
}
