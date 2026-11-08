# Points 137 et 138 : adaptateurs explicites (CSV generique, export GLPI, resultats osquery), correspondance d identite,
# dates, priorite des sources dans le fichier, categories de l apercu et lot de retour arriere durable. Regles pures,
# donnees fictives (domaine corp.example), sans reseau, sans base, sans WPF.
. (Join-Path $modules 'Domenia-InventoryImport.Model.ps1')

Test-Case 'IMP-001' 'Point 137 : trois adaptateurs explicites, provenance imposee par l adaptateur' {
    $adapters = @(Get-DomeniaInventoryAdapters)
    Assert-Equal 3 $adapters.Count
    Assert-Equal 'Import CSV' (Get-DomeniaInventoryAdapter 'Csv').Source
    Assert-Equal 'Import GLPI' (Get-DomeniaInventoryAdapter 'Glpi').Source
    Assert-Equal 'Import osquery' (Get-DomeniaInventoryAdapter 'Osquery').Source
    Assert-True ($null -eq (Get-DomeniaInventoryAdapter 'Excel')) 'adaptateur inconnu accepte'
    foreach ($adapter in $adapters) { Assert-True ([string]$adapter.FileFilter -match '^[^|]+\|[^|]+$') ('filtre de fichier : ' + $adapter.Id) }
    $limits = Get-DomeniaInventoryLimits
    Assert-True (($limits.MaxJsonBytes -le 2097152) -and ($limits.PreviewRecords -eq 1000) -and ($limits.BatchLimit -eq 64)) 'limites explicites'
}
Test-Case 'IMP-002' 'Point 137 : noms de colonnes compares sans accents ni variantes d apostrophe' {
    Assert-Equal (ConvertTo-DomeniaInventoryHeaderKey 'numero de serie') (ConvertTo-DomeniaInventoryHeaderKey 'Numéro de série')
    Assert-Equal (ConvertTo-DomeniaInventoryHeaderKey ('Nom d' + [char]0x2019 + 'usager')) (ConvertTo-DomeniaInventoryHeaderKey 'Nom dʼusager')
    Assert-Equal 'last inventory date' (ConvertTo-DomeniaInventoryHeaderKey ' Last_Inventory-Date ')
}
Test-Case 'IMP-003' 'Point 137 : export GLPI, identifiant de connexion et jamais le nom affiche' {
    $row = [pscustomobject]@{'Nom'='PC-01';'Entité'='Siège';'Usager'='CORP\alice';'Utilisateur'='Dupont Alice';'Dernière modification'='2026-10-14 09:30';'Numéro de série'='SN-123'}
    $r = ConvertFrom-DomeniaGlpiRow $row 3
    Assert-Equal 'Glpi' $r.InventoryAdapter
    Assert-Equal 3 $r.Record
    Assert-Equal 'CORP\alice' $r.User
    Assert-Equal 'PC-01' $r.Computer
    Assert-Equal '2026-10-14 09:30' $r.When
    Assert-Equal 'SN-123' $r.Serial
    Assert-Equal '' $r.Reject
    Assert-True (($r.Details -match 'SN-123') -and ($r.Details -match 'Siège') -and ($r.Details -match 'Dernière modification')) $r.Details
    $display = ConvertFrom-DomeniaGlpiRow ([pscustomobject]@{'Nom'='PC-02';'Utilisateur'='Dupont Alice'}) 1
    Assert-True ($display.Reject -match 'Nom affiché') 'nom affiche pris pour un identifiant'
    $login = ConvertFrom-DomeniaGlpiRow ([pscustomobject]@{'Nom'='PC-03';'Utilisateur'='bmartin'}) 1
    Assert-True (($login.User -eq 'bmartin') -and (-not $login.Reject)) 'identifiant GLPI sans espace refuse'
    $english = ConvertFrom-DomeniaGlpiRow ([pscustomobject]@{'Name'='PC-04';'Alternate username'='carol';'Last inventory date'='2026-10-13 18:00';'Last update'='2026-10-14 08:00'}) 1
    Assert-True (($english.User -eq 'carol') -and ($english.Computer -eq 'PC-04') -and ($english.When -eq '2026-10-13 18:00')) 'export GLPI en anglais ou date d inventaire non preferee'
}
Test-Case 'IMP-004' 'Point 137 : resultats osquery, journal et tableau, fins de session et lignes illisibles' {
    $log = @'
{"name":"pack_sessions","hostIdentifier":"PC-10.corp.example","unixTime":1760500000,"action":"added","columns":{"user":"alice","type":"user","time":"1760499000"}}
{"name":"pack_sessions","hostIdentifier":"PC-10.corp.example","unixTime":1760503600,"action":"removed","columns":{"user":"alice","type":"user","time":"1760499000"}}
{"name":"pack_sessions","hostIdentifier":"PC-11","unixTime":1760510000,"action":"snapshot","snapshot":[{"user":"bob","type":"active"},{"user":"","type":"boot_time"}]}
{ ceci n est pas du JSON
'@
    $parsed = ConvertFrom-DomeniaOsqueryText -Text $log
    Assert-Equal 'ResultsLog' $parsed.Format
    Assert-Equal 2 @($parsed.Records).Count ('enregistrements : ' + @($parsed.Records).Count)
    Assert-Equal 1 @($parsed.Rejected).Count 'ligne illisible non signalee'
    Assert-Equal 2 ([int]$parsed.Skipped) 'fin de session ou type sans compte non ignores'
    $alice = @($parsed.Records)[0]
    Assert-True (($alice.User -eq 'alice') -and ($alice.Computer -eq 'PC-10.corp.example') -and ($alice.When -eq '1760499000') -and $alice.UnixTime) 'ouverture de session osquery'
    Assert-True ($alice.Details -match 'Ouverture de session') $alice.Details
    $bob = @($parsed.Records)[1]
    Assert-True (($bob.User -eq 'bob') -and ($bob.Computer -eq 'PC-11') -and ($bob.When -eq '1760510000')) 'instantane osquery'
    $array = ConvertFrom-DomeniaOsqueryText -Text '[{"hostname":"PC-12","user":"carol","type":"user","time":"1760400000"},{"user":"dave","type":"user"}]'
    Assert-Equal 'Array' $array.Format
    Assert-Equal 2 @($array.Records).Count
    Assert-True (@($array.Records)[1].Reject -match 'Poste absent') 'poste absent non refuse'
    $bounded = ConvertFrom-DomeniaOsqueryText -Text '[{"hostname":"A","user":"a"},{"hostname":"B","user":"b"},{"hostname":"C","user":"c"}]' -MaxRecords 2
    Assert-True ((@($bounded.Records).Count -eq 2) -and $bounded.Truncated) 'borne d enregistrements'
    Assert-Equal '' (ConvertFrom-DomeniaOsqueryText -Text '   ').Format
    # Windows snapshot: the services session has an empty user and time 0; it takes the snapshot time, later than the
    # logon of alice. It is skipped and counted, never a record that would hide alice.
    $windows = ConvertFrom-DomeniaOsqueryText -Text '{"name":"pack_sessions","hostIdentifier":"PC-20","unixTime":1760500000,"action":"snapshot","snapshot":[{"user":"alice","type":"active","time":"1760490000"},{"user":"","type":"disconnected","time":"0"},{"user":"  ","type":"active","time":"0"},{"user":"SYSTEM","type":"active","time":"0"},{"user":"DWM-1","type":"active","time":"0"}]}'
    Assert-Equal 1 @($windows.Records).Count ('sessions sans personne retenues : ' + @($windows.Records).Count)
    Assert-Equal 4 ([int]$windows.Skipped) 'sessions sans personne non comptees'
    Assert-True ((@($windows.Records)[0].User -eq 'alice') -and (@($windows.Records)[0].When -eq '1760490000')) 'session de alice perdue'
    $restart = ConvertFrom-DomeniaOsqueryText -Text ('{"hostIdentifier":"PC-21","unixTime":1760500000,"action":"added","columns":{"user":"bob","type":"active","time":"1760480000"}}' + "`n" + '{"hostIdentifier":"PC-21","unixTime":1760500000,"action":"added","columns":{"user":"","type":"disconnected","time":"0"}}')
    $kept = Select-DomeniaLatestInventoryRecords -Records @($restart.Records) -NowUtc '2026-10-15T10:00:00Z'
    Assert-True ((@($kept.Records).Count -eq 1) -and (@($kept.Records)[0].User -eq 'bob') -and ([int]$kept.Dropped -eq 0)) 'relance d osqueryd : compte du poste masque'
}
Test-Case 'IMP-005' 'Point 137 : dates ISO, secondes Unix, formats ambigus et dates futures' {
    $now = '2026-10-15T10:00:00Z'
    $unix = ConvertTo-DomeniaInventoryWhen -Value '1760500000' -UnixTime $true -NowUtc $now
    Assert-Equal '2025-10-15T03:46:40.0000000Z' $unix.Text
    Assert-True ($unix.Ticks -gt 0) 'ticks absents'
    $iso = ConvertTo-DomeniaInventoryWhen -Value '2026-10-14T08:00:00Z' -NowUtc $now
    Assert-Equal '2026-10-14T08:00:00.0000000Z' $iso.Text
    $ambiguous = ConvertTo-DomeniaInventoryWhen -Value '08/10/2026 09:15' -NowUtc $now
    Assert-True (($ambiguous.Ticks -eq 0) -and ($ambiguous.Text -eq '08/10/2026 09:15')) 'date ambigue interpretee'
    $future = ConvertTo-DomeniaInventoryWhen -Value '2027-01-01T00:00:00Z' -NowUtc $now
    Assert-True (($future.Ticks -eq 0) -and ($future.Text -eq '') -and ($future.Note -match 'futur')) 'date future retenue'
    Assert-Equal 0 ([long](ConvertTo-DomeniaInventoryWhen -Value '0' -UnixTime $true -NowUtc $now).Ticks)
}
Test-Case 'IMP-006' 'Point 137 : correspondance d identite, autre domaine refuse au lieu d etre tronque' {
    $ok = { param($u,$c) -not (Test-DomeniaInventoryIdentity -User $u -Computer $c -DomainDns 'corp.example' -Netbios 'CORP').Reject }
    Assert-True (& $ok 'CORP\alice' 'PC-01') 'NetBIOS du domaine refuse'
    Assert-True (& $ok 'corp\alice' 'PC-01.corp.example') 'nom DNS du domaine refuse'
    Assert-True (& $ok 'alice@corp.example' 'PC-01') 'UPN du domaine refuse'
    Assert-True (& $ok 'alice' 'PC-01') 'nom simple refuse'
    Assert-True ((Test-DomeniaInventoryIdentity -User 'OTHER\bob' -Computer 'PC-01' -DomainDns 'corp.example' -Netbios 'CORP').Reject -match 'autre domaine') 'compte d un autre domaine'
    Assert-True ((Test-DomeniaInventoryIdentity -User 'bob@mail.example' -Computer 'PC-01' -DomainDns 'corp.example' -Netbios 'CORP').Reject -match 'Suffixe UPN') 'suffixe UPN etranger'
    Assert-True ((Test-DomeniaInventoryIdentity -User 'bob' -Computer 'PC-01.other.example' -DomainDns 'corp.example' -Netbios 'CORP').Reject -match 'autre domaine DNS') 'poste d un autre domaine DNS'
    Assert-True ((Test-DomeniaInventoryIdentity -User 'bob' -Computer '10.0.0.5' -DomainDns 'corp.example' -Netbios 'CORP').Reject -match 'Adresse IP') 'adresse IP prise pour un poste'
    Assert-True ((Test-DomeniaInventoryIdentity -User 'CORP\bob' -Computer 'PC-01').Reject -match 'domaine courant inconnu') 'qualification devinee sans domaine'
    Assert-True ((Test-DomeniaInventoryIdentity -User 'bob' -Computer '4C4C4544-0042-3510-8051-B4C04F4E4E32' -DomainDns 'corp.example' -Netbios 'CORP').Reject -match 'Identifiant matériel') 'UUID osquery pris pour un poste'
}
Test-Case 'IMP-007' 'Point 137 : priorite des sources dans le fichier' {
    $items = @(
        [pscustomobject]@{Record=1;ComputerKey='pc1';UserKey='alice';Ticks=100L},
        [pscustomobject]@{Record=2;ComputerKey='pc1';UserKey='bob';Ticks=200L},
        [pscustomobject]@{Record=3;ComputerKey='pc2';UserKey='carol';Ticks=0L},
        [pscustomobject]@{Record=4;ComputerKey='pc2';UserKey='dave';Ticks=0L},
        [pscustomobject]@{Record=5;ComputerKey='pc3';UserKey='erin';Ticks=50L},
        [pscustomobject]@{Record=6;ComputerKey='pc3';UserKey='erin';Ticks=50L},
        [pscustomobject]@{Record=7;ComputerKey='pc4';UserKey='x';Ticks=10L},
        [pscustomobject]@{Record=8;ComputerKey='pc4';UserKey='y';Ticks=10L},
        [pscustomobject]@{Record=9;ComputerKey='pc4';UserKey='z';Ticks=5L},
        [pscustomobject]@{Record=10;ComputerKey='';UserKey='';Ticks=0L}
    )
    $d = Resolve-DomeniaInventoryPriority -Items $items
    Assert-Equal 10 $d.Count
    Assert-Equal 'Remplacée' $d[0].Kind; Assert-True ($d[0].Reason -match 'plus bas') $d[0].Reason
    Assert-Equal 'Retenue' $d[1].Kind
    Assert-True (($d[2].Kind -eq 'Conflit') -and ($d[3].Kind -eq 'Conflit') -and ($d[2].Reason -match 'aucune date')) 'conflit sans date'
    Assert-Equal 'Retenue' $d[4].Kind; Assert-Equal 'Doublon' $d[5].Kind; Assert-True ($d[5].Reason -match 'plus haut') $d[5].Reason
    Assert-True (($d[6].Kind -eq 'Conflit') -and ($d[7].Kind -eq 'Conflit') -and ($d[6].Reason -match 'même date')) 'conflit a date egale'
    Assert-Equal 'Remplacée' $d[8].Kind
    Assert-Equal 'Retenue' $d[9].Kind
    Assert-Equal 0 @(Resolve-DomeniaInventoryPriority -Items @()).Count
    $latest = Select-DomeniaLatestInventoryRecords -NowUtc '2026-10-15T10:00:00Z' -Records @(
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 1 -User 'alice' -Computer 'PC-10.corp.example' -When '1760400000' -UnixTime $true),
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 2 -User 'bob' -Computer 'PC-10' -When '1760500000' -UnixTime $true),
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 3 -User 'carol' -Computer 'PC-11' -When '1760500000' -UnixTime $true),
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 4 -User 'dave' -Computer '' -When '1760500000' -UnixTime $true)
    )
    Assert-Equal 1 ([int]$latest.Dropped)
    Assert-Equal '2,3,4' ((@($latest.Records) | ForEach-Object { [string]$_.Record }) -join ',')
    # A record without a user or already rejected never competes for the most recent slot: it is kept for the preview
    # (shown as a rejection) and never hides the account of the workstation.
    $mixed = Select-DomeniaLatestInventoryRecords -NowUtc '2026-10-15T10:00:00Z' -Records @(
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 1 -User 'alice' -Computer 'PC-30' -When '1760490000' -UnixTime $true),
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 2 -User '' -Computer 'PC-30' -When '1760500000' -UnixTime $true),
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 3 -User 'eve' -Computer 'PC-30' -When '1760510000' -UnixTime $true -Reject 'Poste dʼun autre domaine.'),
        (New-DomeniaInventoryRecord -Adapter 'Osquery' -Record 4 -User 'old' -Computer 'PC-30' -When '1760400000' -UnixTime $true)
    )
    Assert-Equal 1 ([int]$mixed.Dropped) 'releve plus ancien compte'
    Assert-Equal '1,2,3' ((@($mixed.Records) | ForEach-Object { [string]$_.Record }) -join ',')
}
Test-Case 'IMP-008' 'Point 138 : valides, conflits et rejets classes avant application' {
    Assert-Equal 'Rejet' (Get-DomeniaLinkImportStatus -User 'a' -Computer 'PC-1' -Rejected 'Compte dʼun autre domaine.').Category
    Assert-Equal 'Rejetée' (Get-DomeniaLinkImportStatus -User 'a' -Computer 'PC-1' -Rejected 'x').Status
    Assert-Equal 'Rejet' (Get-DomeniaLinkImportStatus -User '' -Computer 'PC-1').Category
    $conflict = Get-DomeniaLinkImportStatus -User 'a' -Computer 'PC-1' -FileConflict 'Conflit dans le fichier.'
    Assert-True (($conflict.Status -eq 'Conflit') -and ($conflict.Category -eq 'Conflit') -and (-not $conflict.Import)) 'conflit du fichier'
    Assert-Equal 'Doublon' (Get-DomeniaLinkImportStatus -User 'a' -Computer 'PC-1' -FileSuperseded 'Plus ancien.').Category
    $stored = Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -StoredLogin 'mmartin'
    Assert-True (($stored.Status -eq 'Conflit') -and ($stored.Category -eq 'Conflit') -and ($stored.Reason -match 'mmartin')) 'poste deja associe a un autre compte'
    Assert-Equal 'Déjà connue' (Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -StoredLogin 'JDupont').Category
    Assert-Equal 'Reportée' (Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -ReadyBefore 64).Category
    Assert-Equal 'Inconnue' (Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -IndexAvailable $true -UserKnown $false -ComputerKnown $true).Category
    $valid = Get-DomeniaLinkImportStatus -User 'jdupont' -Computer 'PC-1' -IndexAvailable $true -UserKnown $true -ComputerKnown $true
    Assert-True (($valid.Category -eq 'Valide') -and $valid.Import -and $valid.Verified) 'ligne valide'
}
Test-Case 'IMP-009' 'Point 138 : provenance imposee et lot de retour arriere dans chaque association' {
    $batch = New-DomeniaImportBatchId -Id 'ABCDEF0123456789abcdef0123456789' -NowUtc '2026-10-15T09:41:30.250Z'
    Assert-Equal '20261015T094130250Z-abcdef01' $batch
    Assert-True ((New-DomeniaImportBatchId -Id '') -match '^\d{8}T\d{9}Z-[0-9a-f]{8}$') 'lot sans identifiant'
    $rel = New-DomeniaImportedRelation -User 'alice' -Computer 'PC-01' -FileName 'glpi.csv' -Line 4 -When '2026-10-14T08:00:00Z' -Source 'Import GLPI' -BatchId $batch -FileDetails 'Numéro de série GLPI : SN-1.'
    Assert-Equal 'Import GLPI' $rel.Source
    Assert-Equal 'Importe' $rel.Kind
    Assert-Equal 'Importe' (Get-DomeniaRelationKind $rel.Source)
    Assert-True ($rel.Details.StartsWith('Lot dʼimport ' + $batch + '. Importé depuis glpi.csv, enregistrement 4.')) $rel.Details
    Assert-Equal $batch (Get-DomeniaImportBatchToken $rel.Details)
    Assert-Equal '' (Get-DomeniaImportBatchToken 'Importé depuis liens.csv, enregistrement 1.')
    Assert-Throws { New-DomeniaImportedRelation -User 'a' -Computer 'b' -Source 'Saisie manuelle' } 'source declaree acceptee pour un import'
    $future = New-DomeniaImportedRelation -User 'a' -Computer 'b' -FileName 'x.json' -When '' -WhenNote 'Date du fichier dans le futur (2027) : ignorée.' -NowUtc '2026-10-15T10:00:00Z' -Source 'Import osquery'
    Assert-True (($future.When -eq '2026-10-15T10:00:00.0000000Z') -and ($future.Details -match 'futur')) 'date future non signalee'
    foreach ($source in @('Import CSV','Import GLPI','Import osquery')) { Assert-True (Test-DomeniaProtectedAssociationSource $source) ('source importee non protegee : ' + $source) }
}
Test-Case 'IMP-010' 'Point 138 : lots de retour arriere retrouves dans les associations stockees' {
    $links = @(
        [pscustomobject]@{UserLogin='a';Computer='PC-A';Source='Import GLPI';Details='Lot dʼimport 20261014T080000000Z-aaaaaaaa. Importé depuis glpi.csv, enregistrement 1.'},
        [pscustomobject]@{UserLogin='b';Computer='PC-B';Source='Import osquery';Details='Lot dʼimport 20261015T090012500Z-bbbbbbbb. Importé depuis sessions.log, enregistrement 2. Ouverture de session osquery.'},
        [pscustomobject]@{UserLogin='c';Computer='PC-C';Source='Import osquery';Details='Lot dʼimport 20261015T090012500Z-bbbbbbbb. Importé depuis sessions.log, enregistrement 3.'},
        [pscustomobject]@{UserLogin='d';Computer='PC-D';Source='Import CSV';Details='Importé depuis ancien.csv, enregistrement 1.'},
        [pscustomobject]@{UserLogin='e';Computer='PC-E';Source='Saisie manuelle';Details='Lot dʼimport 20261016T090000000Z-cccccccc. Copie.'},
        $null
    )
    $batches = @(Get-DomeniaImportBatches -Links $links)
    Assert-Equal 2 $batches.Count
    Assert-Equal '20261015T090012500Z-bbbbbbbb' $batches[0].Id
    Assert-Equal 'sessions.log' $batches[0].FileName
    Assert-Equal 2 @($batches[0].Relations).Count
    Assert-True ([object]::ReferenceEquals(@($batches[0].Relations)[0],$links[1])) 'les associations stockees elles-memes sont retirees'
    Assert-Equal '2026-10-15T09:00:12.5000000Z' $batches[0].ImportedUtc
    Assert-Equal 'glpi.csv' $batches[1].FileName
    Assert-Equal 0 @(Get-DomeniaImportBatches -Links @()).Count
    # Two imports confirmed in the same minute: the later one is the most recent batch after a restart, whatever the
    # random part of the identifiers.
    $first = New-DomeniaImportBatchId -Id 'ffffffff000000000000000000000000' -NowUtc '2026-10-15T09:41:05.100Z'
    $second = New-DomeniaImportBatchId -Id '00000000ffffffffffffffffffffffff' -NowUtc '2026-10-15T09:41:40.900Z'
    $sameMinute = @(
        (New-DomeniaImportedRelation -User 'f' -Computer 'PC-F' -FileName 'premier.csv' -Line 1 -BatchId $first -NowUtc '2026-10-15T09:41:05Z'),
        (New-DomeniaImportedRelation -User 'g' -Computer 'PC-G' -FileName 'second.csv' -Line 1 -BatchId $second -NowUtc '2026-10-15T09:41:40Z')
    )
    $ordered = @(Get-DomeniaImportBatches -Links $sameMinute)
    Assert-Equal 2 $ordered.Count
    Assert-Equal $second $ordered[0].Id 'lot plus ancien de la meme minute choisi'
    Assert-Equal 'second.csv' $ordered[0].FileName
}
