# Tableau de bord du parc en widgets (decision David 2026-10-07) : fournisseur de donnees Fleet.
# Donnees fictives uniquement (domaine example.test).
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-BoardFleet.Model.ps1')
$script:BfInvariant = [Globalization.CultureInfo]::InvariantCulture
$script:BfNow = [datetime]::SpecifyKind([datetime]'2026-10-07T10:00:00',[DateTimeKind]::Local)
$script:BfScope = 'OU=Postes,OU=Lyon,DC=example,DC=test'
function New-BfMachine {
    param([string]$Name,[string]$Container,[string]$Os,[double]$Days = -1)
    $logon = ''
    if ($Days -ge 0) { $logon = $script:BfNow.AddDays(0 - $Days).ToString('dd/MM/yyyy HH:mm:ss',$script:BfInvariant) }
    return [pscustomobject]@{ name = $Name; object_guid = ('guid-' + $Name); extra = $Os; last_logon = $logon; distinguished_name = ('CN=' + $Name + ',' + $Container) }
}
function New-BfInventory {
    param([string]$Model,[string]$Build,[double]$RamGb,[double]$DiskGb,[double]$FreeGb,[double]$BootDays)
    return [pscustomobject]@{ Model = $Model; Build = $Build; RamBytes = $RamGb * 1GB; DiskSize = $DiskGb * 1GB; DiskFree = $FreeGb * 1GB; LastBootUtc = $script:BfNow.ToUniversalTime().AddDays(0 - $BootDays).ToString('o') }
}
function New-BfPresence {
    param([string]$Dn,[double]$HoursAgo,$Payload)
    $text = if ($Payload -is [string]) { $Payload } else { ConvertTo-Json -InputObject $Payload -Depth 5 -Compress }
    return [pscustomobject]@{ object_key = $Dn; checked_utc = $script:BfNow.ToUniversalTime().AddHours(0 - $HoursAgo).ToString('o'); payload = $text }
}
function New-BfResult {
    param([object[]]$Machines = @(),[object[]]$Presence = @())
    $types = @([pscustomobject]@{ t = 'Utilisateur'; s = 'Actif'; n = 40 }, [pscustomobject]@{ t = 'Utilisateur'; s = 'Desactive'; n = 3 }, [pscustomobject]@{ t = 'Machine'; s = 'Actif'; n = 10 })
    return [pscustomobject]@{ Rows = @(); Busy = $false; Missing = $false; MachineCount = @($Machines).Count; Types = $types; Machines = @($Machines); Links = 12; LinkSources = @(); Presence = @($Presence) }
}
function Get-BfMachines {
    # Seven workstations in OU=Postes,OU=Lyon (sub-OU, nested sub-OU, directly in the OU) and three outside.
    return @(
        (New-BfMachine 'PC-L01' ('OU=Compta,' + $script:BfScope) 'Microsoft Windows 10 Professionnel / 10.0 (19045)' 3)
        (New-BfMachine 'PC-L02' ('OU=Compta,' + $script:BfScope) 'Windows 11 Professional' 10)
        (New-BfMachine 'PC-L03' ('OU=Accueil,' + $script:BfScope) 'Windows 11 Pro' 45)
        (New-BfMachine 'PC-L04' ('OU=Etage2,OU=Compta,' + $script:BfScope) 'Windows 11 Pro' 100)
        (New-BfMachine 'PC-L05' $script:BfScope 'Windows 10 Pro' 200)
        (New-BfMachine 'PC-L06' ('OU=Compta,' + $script:BfScope) 'Windows 11 Entreprise')
        (New-BfMachine 'PC-L07' ('OU=Compta,' + $script:BfScope) '' 1)
        (New-BfMachine 'PC-P01' 'OU=Postes,OU=Paris,DC=example,DC=test' 'Windows 10 Pro' 2)
        (New-BfMachine 'PC-X01' 'OU=XPostes,OU=Lyon,DC=example,DC=test' 'Windows 11 Pro' 2)
        (New-BfMachine 'PC-C01' 'CN=Computers,DC=example,DC=test' 'Windows 11 Pro' 5)
    )
}
function Get-BfPresenceRows {
    # Observations: online with WMI, no answer, unreadable payload, empty payload, inventory without figures, outside.
    return @(
        (New-BfPresence ('CN=PC-L01,OU=Compta,' + $script:BfScope) 2 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\jdupont'; Inventory = (New-BfInventory 'Latitude 5440' '19045' 8 256 20 40) }))
        (New-BfPresence ('CN=PC-L02,OU=Compta,' + $script:BfScope) 5 ([pscustomobject]@{ Presence = 'Sans reponse au ping'; LinkUser = '' }))
        (New-BfPresence ('CN=PC-L03,OU=Accueil,' + $script:BfScope) 24 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = ''; Inventory = (New-BfInventory 'latitude 5440' '26100' 16 512 300 2) }))
        (New-BfPresence ('CN=PC-L04,OU=Etage2,OU=Compta,' + $script:BfScope) 3 '{pas du json')
        (New-BfPresence ('CN=PC-L05,' + $script:BfScope) 30 '{}')
        (New-BfPresence ('CN=PC-L07,OU=Compta,' + $script:BfScope) 6 ([pscustomobject]@{ Presence = 'En ligne'; Inventory = [pscustomobject]@{ Model = ''; Build = '' } }))
        (New-BfPresence 'CN=PC-P01,OU=Postes,OU=Paris,DC=example,DC=test' 0.5 ([pscustomobject]@{ Presence = 'En ligne'; LinkUser = 'EX\pmartin'; Inventory = (New-BfInventory 'OptiPlex 7010' '19045' 4 100 5 60) }))
    )
}
function Get-BfBoard {
    param([string]$Scope = $script:BfScope)
    return Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines) -Presence @(Get-BfPresenceRows)) -Scope $Scope -Now $script:BfNow
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

Test-Case -Id 'BF-001' -Name 'Parc : cles exactes du catalogue Fleet, toutes presentes avec des releves' -Body {
    $board = Get-BfBoard
    $catalog = @(Get-DomeniaBoardCatalog -Board Fleet | ForEach-Object { [string]$_.Key })
    foreach ($key in @($board.Entries.Keys)) { Assert-True ($catalog -contains [string]$key) ('Cle hors catalogue : ' + $key) }
    foreach ($key in $catalog) { Assert-True ($board.Entries.ContainsKey($key)) ('Cle absente : ' + $key) }
    Assert-Equal 'Fleet' ([string]$board.Board)
    Assert-Equal 0 $board.Hints.Count
    $source = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-BoardFleet.Model.ps1'))
    Assert-False ($source -match '\$script:') 'Fournisseur pur : aucun etat de script'
    Assert-False ($source -match 'System\.Windows') 'Fournisseur pur : aucun WPF'
}
Test-Case -Id 'BF-002' -Name 'Parc : perimetre en sous-arbre, cibles des analyses et observations de toutes les lignes' -Body {
    $board = Get-BfBoard
    Assert-Equal $script:BfScope ([string]$board.Last.Scope)
    Assert-Equal 'PC-L01,PC-L02,PC-L03,PC-L04,PC-L05,PC-L06,PC-L07' (@(@($board.Last.Targets) | ForEach-Object { [string]$_.name }) -join ',')
    Assert-Equal 'guid-PC-L03' ([string]@($board.Last.Targets)[2].object_guid)
    Assert-Equal ('CN=PC-L05,' + $script:BfScope) ([string]@($board.Last.Targets)[4].distinguished_name)
    Assert-Equal '7' ([string]$board.Entries['fleet.machines'].Value)
    Assert-Equal 'dans l OU choisie' ([string]$board.Entries['fleet.machines'].Detail)
    Assert-Equal 6 $board.Observations.Count
    Assert-True ($board.Observations.ContainsKey('cn=pc-p01,ou=postes,ou=paris,dc=example,dc=test')) 'Observation hors perimetre conservee'
    Assert-False ($board.Observations.ContainsKey('cn=pc-l04,ou=etage2,ou=compta,ou=postes,ou=lyon,dc=example,dc=test')) 'Charge illisible ignoree'
    foreach ($key in @($board.Observations.Keys)) { $lower = ([string]$key).ToLowerInvariant(); Assert-Equal $lower ([string]$key) }
    $all = Get-BfBoard -Scope ''
    Assert-Equal '' ([string]$all.Last.Scope)
    Assert-Equal 10 @($all.Last.Targets).Count
    Assert-Equal '10' ([string]$all.Entries['fleet.machines'].Value)
    Assert-Equal '40 utilisateurs actifs au total' ([string]$all.Entries['fleet.machines'].Detail)
}
Test-Case -Id 'BF-003' -Name 'Parc : derniere connexion en tranches ordonnees, tranches vides gardees, inactifs et jamais connectes' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.lastlogon']
    Assert-Equal 'Series' ([string]$entry.Kind)
    Assert-Equal '<7j|7-30j|30-90j|90-180j|>180j|Jamais' (Get-BfJoined $entry 'Label')
    Assert-Equal '2|1|1|1|1|1' (Get-BfJoined $entry 'Value')
    Assert-Equal '<7j' ([string]$entry.Value)
    Assert-Equal '2 poste(s) sur 7' ([string]$entry.Detail)
    Assert-Equal '2' ([string]$board.Entries['fleet.stale'].Value)
    Assert-Equal 'Warn' ([string]$board.Entries['fleet.stale'].State)
    $texts = @(@($board.Attention) | ForEach-Object { [string]$_.Level + ':' + [string]$_.Text })
    Assert-True ($texts -contains 'Warn:2 poste(s) sans connexion au domaine depuis 90 jours ou plus : a verifier ou nettoyer.') 'Inactifs signales'
    Assert-True ($texts -contains 'Warn:1 compte(s) ordinateur jamais connecte(s).') 'Jamais connectes signales'
    $two = @((New-BfMachine 'PC-A' $script:BfScope 'Windows 11 Pro' 3), (New-BfMachine 'PC-B' $script:BfScope 'Windows 11 Pro'))
    $small = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines $two) -Scope $script:BfScope -Now $script:BfNow
    Assert-Equal '1|0|0|0|0|1' (Get-BfJoined $small.Entries['fleet.lastlogon'] 'Value')
    Assert-Equal '0' ([string]$small.Entries['fleet.stale'].Value)
    Assert-Equal 'Ok' ([string]$small.Entries['fleet.stale'].State)
}
Test-Case -Id 'BF-004' -Name 'Parc : systemes normalises, Windows 10 en alerte, six premiers puis Autres' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.os']
    Assert-Equal 'Distribution' ([string]$entry.Kind)
    Assert-Equal 'Windows 11 Pro' ([string]@($entry.Items)[0].Label)
    Assert-Equal 'Windows 10 Pro' ([string]@($entry.Items)[1].Label)
    Assert-Equal 3 (Get-BfPart $entry 'Windows 11 Pro')
    Assert-Equal 2 (Get-BfPart $entry 'Windows 10 Pro')
    Assert-Equal 1 (Get-BfPart $entry 'Systeme non renseigne')
    Assert-Equal 1 (Get-BfPart $entry 'Windows 11 Entreprise')
    Assert-Equal '7 postes' ([string]$entry.CenterText)
    Assert-Equal 'Windows 11 Pro' ([string]$entry.Value)
    Assert-Equal '3 poste(s) sur 7' ([string]$entry.Detail)
    Assert-Equal '2' ([string]$board.Entries['fleet.win10'].Value)
    Assert-Equal 'Alert' ([string]$board.Entries['fleet.win10'].State)
    $texts = @(@($board.Attention) | ForEach-Object { [string]$_.Level + ':' + [string]$_.Text })
    Assert-True ($texts -contains 'Alert:2 poste(s) sous Windows 10, fin de support depuis le 14/10/2025.') 'Windows 10 signale'
    $index = 0
    $many = @(foreach ($os in @('OS A','OS A','OS A','OS B','OS B','OS C','OS D','OS E','OS F','OS G','OS H')) { $index++; New-BfMachine ('PC-O' + $index) $script:BfScope $os 1 })
    $wide = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines $many) -Scope '' -Now $script:BfNow
    $os = $wide.Entries['fleet.os']
    Assert-Equal 'OS A|OS B|OS C|OS D|OS E|OS F|Autres' (Get-BfJoined $os 'Label')
    Assert-Equal 2 (Get-BfPart $os 'Autres')
    Assert-Equal '3 poste(s) sur 11' ([string]$os.Detail)
    Assert-Equal '0' ([string]$wide.Entries['fleet.win10'].Value)
    Assert-Equal 'Ok' ([string]$wide.Entries['fleet.win10'].State)
}
Test-Case -Id 'BF-005' -Name 'Parc : postes par sous-OU (liste a un element non deroulee), par OU sur le domaine, dix au plus' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.ou']
    Assert-Equal 'Postes par sous-OU' ([string]$entry.Title)
    Assert-Equal 3 @($entry.Items).Count
    Assert-Equal 5 (Get-BfPart $entry 'Compta')
    Assert-Equal 1 (Get-BfPart $entry 'Accueil')
    Assert-Equal 1 (Get-BfPart $entry '(directement dans l OU)')
    Assert-Equal 'Compta' ([string]$entry.Value)
    $all = Get-BfBoard -Scope ''
    $ou = $all.Entries['fleet.ou']
    Assert-Equal '' ([string]$ou.Title)
    Assert-Equal 4 (Get-BfPart $ou 'Compta')
    Assert-Equal 1 (Get-BfPart $ou 'Etage2')
    Assert-Equal 1 (Get-BfPart $ou 'Accueil')
    Assert-Equal 2 (Get-BfPart $ou 'Postes')
    Assert-Equal 1 (Get-BfPart $ou 'XPostes')
    Assert-Equal 1 (Get-BfPart $ou 'Hors OU')
    $many = @(foreach ($i in 1..12) { New-BfMachine ('PC-S' + $i) ('OU=Site' + ('{0:00}' -f $i) + ',' + $script:BfScope) 'Windows 11 Pro' 1 })
    $sites = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines $many) -Scope $script:BfScope -Now $script:BfNow
    $items = @($sites.Entries['fleet.ou'].Items)
    Assert-Equal 11 $items.Count
    Assert-Equal 'Site01' ([string]$items[0].Label)
    Assert-Equal 'Site10' ([string]$items[9].Label)
    Assert-Equal 'Autres' ([string]$items[10].Label)
    Assert-Equal 2 ([double]$items[10].Value)
    Assert-Equal 'Site01' ([string]$sites.Entries['fleet.ou'].Value)
    Assert-Equal '12 postes' ([string]$sites.Entries['fleet.ou'].CenterText)
}
Test-Case -Id 'BF-006' -Name 'Parc : presence reseau en couleurs pastel de sens, postes non observes comptes non verifies' -Body {
    $board = Get-BfBoard
    $entry = $board.Entries['fleet.presence']
    Assert-Equal 'En ligne|Sans reponse|Non verifie' (Get-BfJoined $entry 'Label')
    Assert-Equal '3|1|3' (Get-BfJoined $entry 'Value')
    Assert-Equal ((Get-DomeniaBoardColor 'Ok') + '|' + (Get-DomeniaBoardColor 'Warn') + '|' + (Get-DomeniaBoardColor 'Off')) (Get-BfJoined $entry 'Color')
    foreach ($part in @($entry.Items)) { Assert-True ([string]$part.Color -notin @('#16A34A','#F59E0B','#64748B')) ('Couleur saturee : ' + [string]$part.Color) }
    Assert-Equal '7 postes' ([string]$entry.CenterText)
    Assert-Equal 'En ligne' ([string]$entry.Value)
    Assert-Equal '3 poste(s) sur 7' ([string]$entry.Detail)
    foreach ($part in @($board.Entries['fleet.os'].Items)) { Assert-True ($null -eq $part.PSObject.Properties['Color']) 'Couleur seulement quand elle a un sens' }
    $texts = @(@($board.Attention) | ForEach-Object { [string]$_.Level + ':' + [string]$_.Text })
    Assert-True ($texts -contains 'Info:1 poste(s) sans reponse au dernier releve.') 'Sans reponse signale'
    $quiet = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines)) -Scope '' -Now $script:BfNow
    $alone = $quiet.Entries['fleet.presence']
    Assert-Equal 'Non verifie' (Get-BfJoined $alone 'Label')
    Assert-Equal '10' (Get-BfJoined $alone 'Value')
    Assert-Equal (Get-DomeniaBoardColor 'Off') ([string]@($alone.Items)[0].Color)
}
Test-Case -Id 'BF-007' -Name 'Parc : utilisateurs detectes, derniere analyse et phrase de synthese' -Body {
    $board = Get-BfBoard
    Assert-Equal '1' ([string]$board.Entries['fleet.users'].Value)
    Assert-Equal '12 associations au total' ([string]$board.Entries['fleet.users'].Detail)
    $expected = [datetime]::Parse([string]@(Get-BfPresenceRows)[0].checked_utc).ToLocalTime().ToString('dd/MM HH:mm',$script:BfInvariant)
    Assert-Equal $expected ([string]$board.Entries['fleet.lastcheck'].Value)
    Assert-Equal '3 postes avec releve WMI' ([string]$board.Entries['fleet.lastcheck'].Detail)
    Assert-Equal 'Base autonome locale et derniers releves : 7 postes actifs dans le perimetre, calcul du 07/10/2026 10:00. Parc incomplet ? Outils, Base autonome, Mettre a jour tout.' ([string]$board.Summary)
    $all = Get-BfBoard -Scope ''
    Assert-Equal '2' ([string]$all.Entries['fleet.users'].Value)
    Assert-Equal '4 postes avec releve WMI' ([string]$all.Entries['fleet.lastcheck'].Detail)
}
Test-Case -Id 'BF-008' -Name 'Parc : releves WMI (modeles, versions, memoire, espace libre, disque plein, redemarrage)' -Body {
    $board = Get-BfBoard
    $models = $board.Entries['fleet.models']
    Assert-Equal 2 (Get-BfPart $models 'Latitude 5440')
    Assert-Equal 1 (Get-BfPart $models 'Modele inconnu')
    Assert-Equal 'Latitude 5440' ([string]$models.Value)
    Assert-Equal '2 poste(s) sur 3' ([string]$models.Detail)
    Assert-Equal '3 postes' ([string]$models.CenterText)
    $releases = $board.Entries['fleet.releases']
    Assert-Equal 1 (Get-BfPart $releases 'Windows 10 22H2')
    Assert-Equal 1 (Get-BfPart $releases 'Windows 11 24H2')
    Assert-Equal 1 (Get-BfPart $releases 'Version inconnue')
    $ram = $board.Entries['fleet.ram']
    Assert-Equal 'Series' ([string]$ram.Kind)
    Assert-Equal '4 Go et -|8 Go|16 Go|32 Go|+ de 32 Go' (Get-BfJoined $ram 'Label')
    Assert-Equal '0|1|1|0|0' (Get-BfJoined $ram 'Value')
    $disk = $board.Entries['fleet.diskfree']
    Assert-Equal 'Series' ([string]$disk.Kind)
    Assert-Equal '< 10 %|10-25 %|25-50 %|> 50 %' (Get-BfJoined $disk 'Label')
    Assert-Equal '1|0|0|1' (Get-BfJoined $disk 'Value')
    Assert-Equal '1' ([string]$board.Entries['fleet.lowdisk'].Value)
    Assert-Equal 'Alert' ([string]$board.Entries['fleet.lowdisk'].State)
    Assert-Equal 'Moins de 10 % libre' ([string]$board.Entries['fleet.lowdisk'].Detail)
    Assert-Equal '1' ([string]$board.Entries['fleet.uptime'].Value)
    Assert-Equal 'Warn' ([string]$board.Entries['fleet.uptime'].State)
    $texts = @(@($board.Attention) | ForEach-Object { [string]$_.Level + ':' + [string]$_.Text })
    Assert-True ($texts -contains 'Alert:1 poste(s) avec moins de 10 % libre sur C:.') 'Disque plein signale'
    Assert-True ($texts -contains 'Warn:1 poste(s) non redemarre(s) depuis plus de 30 jours.') 'Redemarrage signale'
}
Test-Case -Id 'BF-009' -Name 'Parc : sans releve WMI, section remplacee par une indication et widgets omis' -Body {
    $result = New-BfResult -Machines @(Get-BfMachines) -Presence @(@(Get-BfPresenceRows)[1])
    $board = Get-DomeniaFleetBoardData -Result $result -Scope $script:BfScope -Now $script:BfNow
    Assert-Equal 'Analysez l OU (WMI) pour remplir cette section : modeles, memoire, disques, versions et demarrages.' ([string]$board.Hints['Releves WMI'])
    foreach ($key in @('fleet.models','fleet.releases','fleet.ram','fleet.diskfree','fleet.lowdisk','fleet.uptime')) { Assert-False ($board.Entries.ContainsKey($key)) ('Widget sans donnees emis : ' + $key) }
    Assert-Equal '0 postes avec releve WMI' ([string]$board.Entries['fleet.lastcheck'].Detail)
    $none = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines)) -Scope '' -Now $script:BfNow
    Assert-True (([string]$none.Hints['Releves WMI']).StartsWith('Choisissez une OU')) 'Domaine entier : choisir une OU'
    Assert-Equal 'Aucune' ([string]$none.Entries['fleet.lastcheck'].Value)
}
Test-Case -Id 'BF-013' -Name 'Parc : WMI sans disque ni demarrage lisibles, tuiles omises ; modeles, huit premiers puis Autres' -Body {
    # A failed WMI probe stores DiskSize 0 and LastBootUtc '': no "0 full disk" nor "0 to restart".
    $blind = New-BfPresence ('CN=PC-L01,OU=Compta,' + $script:BfScope) 1 ([pscustomobject]@{ Presence = 'En ligne'; Inventory = [pscustomobject]@{ Model = 'Latitude 5440'; Build = '26100'; RamBytes = 0; DiskSize = 0; DiskFree = 0; LastBootUtc = '' } })
    $board = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines) -Presence @($blind)) -Scope $script:BfScope -Now $script:BfNow
    Assert-True ($board.Entries.ContainsKey('fleet.models')) 'Modeles emis'
    foreach ($key in @('fleet.lowdisk','fleet.uptime','fleet.diskfree','fleet.ram')) { Assert-False ($board.Entries.ContainsKey($key)) ('Widget sans donnees emis : ' + $key) }
    $many = @(foreach ($i in 1..10) { New-BfPresence ('CN=PC-M' + $i + ',' + $script:BfScope) 1 ([pscustomobject]@{ Presence = 'En ligne'; Inventory = (New-BfInventory ('Modele ' + ('{0:00}' -f $i)) '26100' 16 256 100 2) }) })
    $wide = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines) -Presence $many) -Scope $script:BfScope -Now $script:BfNow
    $models = $wide.Entries['fleet.models']
    Assert-Equal 9 @($models.Items).Count
    Assert-Equal 'Modele 08' ([string]@($models.Items)[7].Label)
    Assert-Equal 'Autres' ([string]@($models.Items)[8].Label)
    Assert-Equal 2 (Get-BfPart $models 'Autres')
    Assert-Equal '10 postes' ([string]$models.CenterText)
    Assert-Equal '0' ([string]$wide.Entries['fleet.lowdisk'].Value)
    Assert-Equal 'Ok' ([string]$wide.Entries['fleet.uptime'].State)
}
Test-Case -Id 'BF-010' -Name 'Parc : perimetre vide, repartition remplacee par une indication et etat sain' -Body {
    $board = Get-DomeniaFleetBoardData -Result (New-BfResult -Machines @(Get-BfMachines)) -Scope 'OU=Vide,DC=example,DC=test' -Now $script:BfNow
    Assert-Equal '0' ([string]$board.Entries['fleet.machines'].Value)
    Assert-Equal 0 @($board.Last.Targets).Count
    foreach ($key in @('fleet.os','fleet.lastlogon','fleet.ou','fleet.presence')) { Assert-False ($board.Entries.ContainsKey($key)) ('Widget sans donnees emis : ' + $key) }
    Assert-True ([string]$board.Hints['Repartition']) 'Indication de repartition'
    Assert-Equal 'Bon etat' ([string]$board.Entries['fleet.health'].Value)
    Assert-Equal 100 $board.Entries['fleet.health'].Number
    Assert-Equal 'Rien a signaler' ([string]$board.Entries['fleet.attention'].Value)
    Assert-True (([string]$board.Summary).Contains(': 0 postes actifs dans le perimetre')) 'Synthese du perimetre vide'
}
Test-Case -Id 'BF-011' -Name 'Parc : score et points d attention tries du plus grave au moins grave' -Body {
    $board = Get-BfBoard
    $health = $board.Entries['fleet.health']
    Assert-Equal 'Critique' ([string]$health.Value)
    Assert-Equal 20 $health.Number
    Assert-Equal 'Alert' ([string]$health.State)
    $list = $board.Entries['fleet.attention']
    Assert-Equal 'Alert|Alert|Warn|Warn|Warn|Info' (@(@($list.Items) | ForEach-Object { [string]$_.Level }) -join '|')
    Assert-Equal '2 poste(s) sous Windows 10, fin de support depuis le 14/10/2025.' ([string]@($list.Items)[0].Text)
    Assert-Equal '1 poste(s) avec moins de 10 % libre sur C:.' ([string]@($list.Items)[1].Text)
    Assert-Equal '5 point(s) a verifier' ([string]$list.Value)
}
Test-Case -Id 'BF-012' -Name 'Parc : resultat du worker en tableau, base occupee et reponse incomplete' -Body {
    $result = New-BfResult -Machines @(Get-BfMachines) -Presence @(Get-BfPresenceRows)
    $board = Get-DomeniaFleetBoardData -Result @('sortie intermediaire', $result) -Scope $script:BfScope -Now $script:BfNow
    Assert-Equal '7' ([string]$board.Entries['fleet.machines'].Value)
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
    $locked = New-BfResult -Machines @(Get-BfMachines)
    $locked.Busy = $true
    $message = ''
    try { [void](Get-DomeniaFleetBoardData -Result $locked -Scope '' -Now $script:BfNow) } catch { $message = $_.Exception.Message }
    Assert-Equal 'base occupee, reessayez dans un instant.' $message
}
