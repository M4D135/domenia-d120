# Widgets un par un (decision David 2026-10-14, points 6, 73 et 80) : mesure suspendue enregistree avec la
# disposition, source et collecte propres a chaque widget, collecte des seules mesures manquantes, admission sans
# confirmation bornee, textes d'etat honnetes, explication d'un chiffre, liste exacte, clavier et largeur.
# Regles pures, aucune interface, aucun reseau.
. (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-Park.Model.ps1')
# The field families of a query widget come from the collection planner shared with the workshop (Query.Model).
. (Join-Path $modules 'Domenia-Query.Model.ps1')
. (Join-Path $modules 'Domenia-WidgetCollect.Model.ps1')
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
# The catalog cache of Probes.Model starts empty (StrictMode of this runner: the variable must exist).
$script:DomeniaProbeCatalog = $null

Test-Case 'WGC-001' 'Mesure suspendue : enregistree avec la disposition, gardee par les deplacements, exclue des collectes' {
    $layout = @(
        New-DomeniaBoardItem -Source Builtin -Key 'fleet.machines' -Visual Kpi -Size S -Group 'G1' -Id '1'
        New-DomeniaBoardItem -Source Probe -Key 'disk.free' -Visual Column -Size M -Group 'G1' -Id '2'
        New-DomeniaBoardItem -Source Builtin -Key 'fleet.stale' -Visual Kpi -Size S -Group 'G2' -Id '3'
    )
    Assert-False (Test-DomeniaBoardItemPaused -Item $layout[1]) 'actif par defaut'
    $paused = @(Update-DomeniaBoardItem -Layout $layout -Id '2' -Changes @{ Paused = $true })
    Assert-Equal '1,2,3' (@($paused | ForEach-Object { $_.Id }) -join ',') 'la place est gardee'
    Assert-True (Test-DomeniaBoardItemPaused -Item $paused[1]) 'suspendu'
    Assert-Equal 'Column' ([string]$paused[1].Visual) 'representation gardee'
    Assert-Equal '1,3' (@(Select-DomeniaActiveBoardItems -Layout $paused | ForEach-Object { $_.Id }) -join ',') 'exclu des collectes'
    $json = ConvertTo-DomeniaBoardLayoutJson -Layout $paused
    Assert-True ($json -like '*"Paused":true*') ('JSON : ' + $json)
    Assert-Equal 1 ([regex]::Matches($json, '"Paused"').Count) 'seul le widget suspendu porte Paused'
    Assert-False ((ConvertTo-DomeniaBoardLayoutJson -Layout $layout) -like '*Paused*') 'une disposition active garde son texte'
    $again = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json $json -ProbeCatalog @([pscustomobject]@{ Id = 'disk.free'; Category = 'Disques'; Name = 'Libre'; Mode = 'Value'; Transform = 'PercentFree'; Visual = 'Column' }))
    Assert-True (Test-DomeniaBoardItemPaused -Item @($again | Where-Object { $_.Id -eq '2' })[0]) 'relu suspendu'
    Assert-False (Test-DomeniaBoardItemPaused -Item @($again | Where-Object { $_.Id -eq '1' })[0]) 'les autres restent actifs'
    $moved = @(Move-DomeniaBoardItem -Layout $paused -Id '2' -Onto '3')
    Assert-True (Test-DomeniaBoardItemPaused -Item @($moved | Where-Object { $_.Id -eq '2' })[0]) 'deplace, toujours suspendu'
    Assert-True (Test-DomeniaBoardItemPaused -Item @(Move-DomeniaBoardItem -Layout $paused -Id '2' -Before '1' | Where-Object { $_.Id -eq '2' })[0]) 'avant un autre, toujours suspendu'
    Assert-True (Test-DomeniaBoardItemPaused -Item @(Update-DomeniaBoardItem -Layout $paused -Id '2' -Changes @{ Size = 'L' } | Where-Object { $_.Id -eq '2' })[0]) 'redimensionne, toujours suspendu'
    $resumed = @(Update-DomeniaBoardItem -Layout $paused -Id '2' -Changes @{ Paused = $false })
    Assert-Equal 3 @(Select-DomeniaActiveBoardItems -Layout $resumed).Count 'repris'
    Assert-False (Test-DomeniaBoardItemPaused -Item ([pscustomobject]@{ Id = 'x'; Source = 'Builtin'; Key = 'k' })) 'ancienne disposition sans Paused'
    Assert-False (Test-DomeniaBoardItemPaused -Item ([pscustomobject]@{ Id = 'x'; Paused = 'true' })) 'seul un booleen suspend'
    Assert-False (Test-DomeniaBoardItemPaused -Item $null)
}
Test-Case 'WGC-002' 'Chaque widget livre nomme sa source ; la collecte dʼun widget ne relit que cette source' {
    foreach ($board in @('Computer','Fleet','Software')) {
        foreach ($item in @(Get-DomeniaBoardCatalog -Board $board)) {
            $row = Get-DomeniaWidgetSource -Key ([string]$item.Key)
            Assert-True ($null -ne $row) ('source absente : ' + $item.Key)
            Assert-True ([string]$row.Source -in @('Directory','Presence','Console','Inventory','BitLocker','Local','ComputerQuick','ComputerDeep','Card','Software')) ('source inconnue : ' + $item.Key)
            foreach ($text in @($row.Formula, $row.Criteria, $row.Exclusions)) { Assert-True ([string]$text) ('explication vide : ' + $item.Key) }
            $need = Get-DomeniaWidgetCollectionNeed -Board $board -Item (New-DomeniaBoardItem -Source Builtin -Key ([string]$item.Key) -Visual Kpi -Id ('b-' + $item.Key))
            Assert-True ([string]$need.Kind -ne 'Unknown') ('collecte inconnue : ' + $item.Key)
            Assert-True ([string]$need.Label) ('libelle vide : ' + $item.Key)
        }
    }
    $item = { param([string]$Key) New-DomeniaBoardItem -Source Builtin -Key $Key -Visual Kpi -Id ('b-' + $Key) }
    $presence = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.presence')
    Assert-Equal 'Remote' ([string]$presence.Kind); Assert-True $presence.Ping; Assert-False $presence.Console; Assert-False $presence.Inventory
    Assert-Equal 0 @($presence.ProbeIds).Count 'aucune requete WMI pour un ping'
    $models = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.models')
    Assert-True $models.Inventory; Assert-False $models.Ping; Assert-False $models.Console
    Assert-True (Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.users')).Console
    Assert-Equal 'Directory' ([string](Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.machines')).Kind)
    Assert-Equal 'BitLocker' ([string](Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.bitlocker')).Kind)
    Assert-Equal 'Local' ([string](Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.health')).Kind)
    $deep = Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item 'computer.processes')
    Assert-Equal 'ComputerInventory' ([string]$deep.Kind); Assert-True $deep.Deep
    Assert-True ([string]$deep.Label -like 'Inventaire complet*')
    Assert-False (Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item 'computer.os')).Deep
    Assert-Equal 'Card' ([string](Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item 'computer.ad.laps')).Kind)
    Assert-Equal 'ComputerInventory' ([string](Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item 'computer.ad.clock')).Kind) 'horloge lue par lʼinventaire'
    Assert-Equal 'Software' ([string](Get-DomeniaWidgetCollectionNeed -Board Software -Item (& $item 'software.count')).Kind)
    $unknown = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (& $item 'fleet.inconnu')
    Assert-Equal 'Unknown' ([string]$unknown.Kind)
    Assert-True ([string]$unknown.Label -like '*aucune collecte*') ([string]$unknown.Label)
    Assert-True ([string]$presence.Label -like '*postes actifs de lʼOU affichée*') 'population du parc nommee'
    Assert-True ([string]$models.Label -like '*lecture seule*') 'lecture seule annoncee'
}
Test-Case 'WGC-003' 'Requete ou sonde : seuls ses champs distants sont collectes, ses champs AD restent ceux de la base' {
    $probe = Get-DomeniaWidgetCollectionNeed -Board Computer -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.free' -Visual Kpi -Id 'p1')
    Assert-Equal 'Remote' ([string]$probe.Kind); Assert-Equal 'disk.free' (@($probe.ProbeIds) -join ','); Assert-False $probe.Console
    Assert-True ([string]$probe.Label -like '*le poste sélectionné*') ([string]$probe.Label)
    $query = New-DomeniaBoardItem -Source Query -Key 'q1' -Visual Bar -Id 'w1'
    $mixed = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $query -Fields @('probe:sec.tpm','instance:svc.list:Name','probe:sec.tpm','model','presence','user','os')
    Assert-Equal 'Remote' ([string]$mixed.Kind)
    Assert-Equal 'sec.tpm,svc.list' (@($mixed.ProbeIds) -join ',') 'sondes dedoublonnees et triees'
    Assert-True ($mixed.Inventory -and $mixed.Ping -and $mixed.Console -and $mixed.Directory)
    Assert-True ([string]$mixed.Label -like '*attributs AD restent ceux de la base locale*') ([string]$mixed.Label)
    Assert-Equal 'Directory' ([string](Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $query -Fields @('os','logonDays')).Kind)
    Assert-Equal 'Card' ([string](Get-DomeniaWidgetCollectionNeed -Board Computer -Item $query -Fields @('os')).Kind)
    Assert-Equal 'Local' ([string](Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $query -Fields @()).Kind)
    Assert-Equal 'Unknown' ([string](Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $query -Fields @('probe:x') -RecipeMissing).Kind) 'requete absente'
    $custom = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $query -Fields @('detail:abc')
    Assert-Equal 'Unknown' ([string]$custom.Kind); Assert-True $custom.Workshop
    Assert-True ([string]$custom.Label -like '*depuis lʼatelier*') ([string]$custom.Label)
    Assert-Equal 'Unknown' ([string](Get-DomeniaWidgetCollectionNeed -Board Software -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.free' -Visual Kpi -Id 'p2')).Kind) 'aucune sonde sur le tableau des logiciels'
}
Test-Case 'WGC-004' 'Ajouter un widget part sans confirmation jusquʼa la limite, au-dela le nombre est confirme ; plafond du releve (SE-05) toujours applique' {
    Assert-True (Get-DomeniaWidgetCollectAdmission -TargetCount 1).Direct
    Assert-True (Get-DomeniaWidgetCollectAdmission -TargetCount 200).Direct
    $over = Get-DomeniaWidgetCollectAdmission -TargetCount 201
    Assert-True ($over.Allowed -and (-not $over.Direct)) 'au-dela de la limite : admis apres confirmation'
    $empty = Get-DomeniaWidgetCollectAdmission -TargetCount 0
    Assert-False ($empty.Direct -or $empty.Allowed) 'aucune cible, rien ne part'
    # The preapproval never goes beyond the ceiling of a survey (Park.MaxTargets, 500 by default, 5000 at most).
    Assert-Equal 500 (Get-DomeniaWidgetCollectAdmission -TargetCount 10 -Limit 50000).Limit 'limite bornee par le plafond'
    Assert-Equal 2000 (Get-DomeniaWidgetCollectAdmission -TargetCount 10 -Limit 50000 -Maximum 5000).Limit 'limite bornee'
    Assert-Equal 1 (Get-DomeniaWidgetCollectAdmission -TargetCount 10 -Limit 0).Limit
    Assert-False (Get-DomeniaWidgetCollectAdmission -TargetCount 2 -Limit 1).Direct
    Assert-Equal 5 (Get-DomeniaWidgetCollectAdmission -TargetCount 3 -Maximum 5).Limit 'limite sous un plafond regle bas'
    $ceiling = Get-DomeniaWidgetCollectAdmission -TargetCount 501
    Assert-False ($ceiling.Allowed -or $ceiling.Direct) 'au-dela du plafond : rien nʼest lu'
    Assert-Equal '501 postes à lire pour ce widget : plafond 500 (réglage Park.MaxTargets). Choisissez une OU plus petite dans Rechercher.' ([string]$ceiling.Reason)
    Assert-True (Get-DomeniaWidgetCollectAdmission -TargetCount 500).Allowed 'plafond inclus'
    Assert-False (Get-DomeniaWidgetCollectAdmission -TargetCount 6 -Maximum 5).Allowed 'plafond regle par Park.MaxTargets'
}
Test-Case 'WGC-005' 'Collecter seulement le manquant : le releve juge chaque poste sur ses mesures enregistrees, sonde non applicable comprise' {
    $now = [datetime]::new(2026, 10, 14, 10, 0, 0, [DateTimeKind]::Utc)
    $fresh = $now.AddDays(-2).ToString('o'); $old = $now.AddDays(-40).ToString('o')
    $guid = '00000000-0000-4000-8000-000000000001'; $key = 'cn=pc-1,ou=p,dc=x,dc=y'; $other = '00000000-0000-4000-8000-0000000000ff'
    $probes = @([pscustomobject]@{ Id = 'disk.free'; DefinitionHash = 'H1' })
    $answered = {
        param($Previous,[bool]$Ping = $false,[bool]$Console = $false,[object[]]$Requested = $probes,[int]$Days = 30,[string]$Identity = $guid)
        $plan = New-DomeniaCollectionPlan -Previous $Previous -Guid $Identity -Key $key -Probes $Requested -CacheMinutes 15 -NowUtc $now -ReuseMaxAgeDays $Days
        Test-DomeniaParkTargetAnswered -Previous $Previous -Guid $Identity -Key $key -Plan $plan -Ping $Ping -Console $Console -ReuseMaxAgeDays $Days -NowUtc $now
    }
    $with = { param($Probe,[hashtable]$Extra = @{}) $p = [ordered]@{ Guid = $guid; Key = $key; Probes = [pscustomobject]@{ 'disk.free' = $Probe } }; foreach ($name in @($Extra.Keys)) { $p[$name] = $Extra[$name] }; [pscustomobject]$p }
    # Shapes of the Park projection read by ParkTargets (Convert-IdxWParkObservationSummary): success, stored error,
    # probe not applicable to the system (stored as an error, no success date and no definition hash).
    $success = [pscustomobject]@{ CheckedUtc = $fresh; Error = ''; DefinitionHash = 'H1'; Succeeded = $true }
    Assert-True (& $answered (& $with $success)) 'mesure de 2 jours : poste non contacte'
    Assert-False (& $answered (& $with ([pscustomobject]@{ CheckedUtc = $old; Error = ''; DefinitionHash = 'H1'; Succeeded = $true }))) 'mesure expiree relue'
    Assert-False (& $answered (& $with ([pscustomobject]@{ CheckedUtc = ''; AttemptedUtc = $fresh; Error = 'Acces refuse'; Succeeded = $false }))) 'erreur relue'
    $notApplicable = [pscustomobject]@{ CheckedUtc = ''; AttemptedUtc = $fresh; Error = 'Sonde non applicable au systeme.'; Succeeded = $false }
    Assert-True (& $answered (& $with $notApplicable)) 'sonde non applicable enregistree (controleur de domaine) : une reponse'
    Assert-False (& $answered (& $with ([pscustomobject]@{ CheckedUtc = ''; AttemptedUtc = $old; Error = 'Sonde non applicable au systeme.'; Succeeded = $false }))) 'reponse non applicable expiree'
    Assert-False (& $answered (& $with $success) -Identity $other) 'poste recree sous le meme DN'
    Assert-False (& $answered $null) 'jamais mesure'
    Assert-False (& $answered (& $with $success) -Days 0) 'actualisation forcee : jamais repondu'
    # Ping and console are judged on their own dates, for the same identity.
    Assert-True (& $answered (& $with $success @{ PresenceCheckedUtc = $fresh }) -Ping $true)
    Assert-False (& $answered (& $with $success @{ PresenceCheckedUtc = $old }) -Ping $true) 'ping expire'
    Assert-False (& $answered (& $with $success) -Ping $true) 'jamais pingue'
    Assert-True (& $answered (& $with $success @{ UserCheckedUtc = $fresh }) -Console $true)
    Assert-False (& $answered (& $with $success @{ ConsoleCheckedUtc = $old }) -Console $true) 'console expiree'
    Assert-True (& $answered ([pscustomobject]@{ Guid = $guid; Key = $key; PresenceCheckedUtc = $fresh }) -Ping $true -Requested @()) 'ping seul'
    Assert-False (& $answered ([pscustomobject]@{ Guid = $other; Key = $key; PresenceCheckedUtc = $fresh }) -Ping $true -Requested @()) 'ping d un autre GUID'
    # Answer dates.
    Assert-Equal $fresh (Get-DomeniaProbeAnswerUtc -Value $notApplicable) 'non applicable date par sa tentative'
    Assert-Equal '' (Get-DomeniaProbeAnswerUtc -Value ([pscustomobject]@{ CheckedUtc = $fresh; Error = ''; Truncated = $true })) 'lecture partielle'
    Assert-Equal $fresh (Get-DomeniaProbeAnswerUtc -Value ([pscustomobject]@{ CheckedUtc = $fresh; Error = ''; Skipped = 'SummaryUnavailable'; SummaryMissing = $true })) 'resume trop grand : mesure lue'
    Assert-False (Test-DomeniaProbeNotApplicable -Value ([pscustomobject]@{ Error = ''; Skipped = 'SummaryUnavailable' }))
    Assert-True (Test-DomeniaProbeNotApplicable -Value ([pscustomobject]@{ Error = ''; Skipped = 'DomainController'; CheckedUtc = $fresh })) 'en memoire avant enregistrement'
}
Test-Case 'WGC-006' 'Releve du widget : une mesure exploitable de moins de N jours est reutilisee, jamais une erreur ni une definition changee' {
    $now = [datetime]::new(2026, 10, 14, 10, 0, 0, [DateTimeKind]::Utc)
    $at = $now.AddDays(-3).ToString('o')
    $guid = '00000000-0000-4000-8000-000000000001'; $key = 'cn=pc-1,ou=p,dc=x,dc=y'
    $previous = [pscustomobject]@{ Guid = $guid; Key = $key; Inventory = [pscustomobject]@{ CheckedUtc = $at }; InventoryError = ''; Probes = [pscustomobject]@{ 'disk.free' = [pscustomobject]@{ CheckedUtc = $at; Error = ''; DefinitionHash = 'H1' }; 'sec.tpm' = [pscustomobject]@{ CheckedUtc = $at; Error = 'refus'; DefinitionHash = 'H2' }; 'sec.cut' = [pscustomobject]@{ CheckedUtc = $at; Error = ''; Truncated = $true; DefinitionHash = 'H3' } } }
    $probes = @([pscustomobject]@{ Id = 'disk.free'; DefinitionHash = 'H1' }, [pscustomobject]@{ Id = 'sec.tpm'; DefinitionHash = 'H2' }, [pscustomobject]@{ Id = 'sec.cut'; DefinitionHash = 'H3' })
    $cache = New-DomeniaCollectionPlan -Previous $previous -Guid $guid -Key $key -Probes $probes -Inventory $true -CacheMinutes 15 -NowUtc $now
    Assert-Equal 3 @($cache.Probes).Count 'sans age de reutilisation, la regle des minutes seule'
    Assert-True $cache.Inventory
    $missing = New-DomeniaCollectionPlan -Previous $previous -Guid $guid -Key $key -Probes $probes -Inventory $true -CacheMinutes 15 -NowUtc $now -ReuseMaxAgeDays 30
    Assert-Equal 'sec.tpm,sec.cut' (@($missing.Probes | ForEach-Object { $_.Id }) -join ',') 'erreur et lecture partielle relues'
    Assert-False $missing.Inventory 'inventaire de 3 jours reutilise'
    Assert-Equal 2 ([int]$missing.Reused)
    $changed = New-DomeniaCollectionPlan -Previous $previous -Guid $guid -Key $key -Probes @([pscustomobject]@{ Id = 'disk.free'; DefinitionHash = 'H9' }) -CacheMinutes 15 -NowUtc $now -ReuseMaxAgeDays 30
    Assert-Equal 1 @($changed.Probes).Count 'definition changee relue'
    $forced = New-DomeniaCollectionPlan -Previous $previous -Guid $guid -Key $key -Probes $probes -Inventory $true -CacheMinutes 0 -NowUtc $now
    Assert-Equal 3 @($forced.Probes).Count 'actualisation forcee'
    $short = New-DomeniaCollectionPlan -Previous $previous -Guid $guid -Key $key -Probes $probes -CacheMinutes 15 -NowUtc $now -ReuseMaxAgeDays 2
    Assert-Equal 3 @($short.Probes).Count 'au-dela de lʼage, relu'
    $other = New-DomeniaCollectionPlan -Previous $previous -Guid '00000000-0000-4000-8000-000000000009' -Key $key -Probes $probes -CacheMinutes 15 -NowUtc $now -ReuseMaxAgeDays 30
    Assert-Equal 3 @($other.Probes).Count 'autre identite : rien de reutilise'
}
Test-Case 'WGC-007' 'Widget sans chiffre : suspendu, en collecte, inventaire complet, absent ou pas encore collecte, jamais Non lu par cet inventaire' {
    $remote = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.free' -Visual Column -Id 'p')
    $paused = Get-DomeniaWidgetPlaceholder -Need $remote -Paused $true -Progress 'Collecte en cours'
    Assert-Equal 'Paused' ([string]$paused.State); Assert-Equal 'Resume' ([string]$paused.Action); Assert-Equal 'Reprendre la mesure' ([string]$paused.ActionText)
    Assert-True ([string]$paused.Message -like 'Mesure suspendue : aucune requête WMI*') ([string]$paused.Message)
    $running = Get-DomeniaWidgetPlaceholder -Need $remote -Progress 'Collecte en cours · 2/9 poste(s)'
    Assert-Equal 'Collecting' ([string]$running.State); Assert-Equal '' ([string]$running.Action)
    $deep = Get-DomeniaWidgetCollectionNeed -Board Computer -Item (New-DomeniaBoardItem -Source Builtin -Key 'computer.events' -Visual Bar -Id 'e')
    $quick = Get-DomeniaWidgetPlaceholder -Need $deep -Collected $true -DeepRead $false
    Assert-Equal 'Deep' ([string]$quick.State); Assert-Equal 'Inventaire complet' ([string]$quick.ActionText)
    $absent = Get-DomeniaWidgetPlaceholder -Need $deep -Collected $true -DeepRead $true -CollectedAt '14/10 09:30'
    Assert-Equal 'Absent' ([string]$absent.State)
    Assert-Equal 'Absent du dernier relevé du 14/10 09:30 : information non renvoyée pour ce poste.' ([string]$absent.Message)
    $fleetAbsent = Get-DomeniaWidgetPlaceholder -Need $remote -Collected $true
    Assert-True ([string]$fleetAbsent.Message -like '*pour ce périmètre.') ([string]$fleetAbsent.Message)
    $missing = Get-DomeniaWidgetPlaceholder -Need $remote
    Assert-Equal 'Missing' ([string]$missing.State); Assert-Equal 'Collecter' ([string]$missing.ActionText); Assert-Equal 'Refresh' ([string]$missing.Action)
    $local = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (New-DomeniaBoardItem -Source Builtin -Key 'fleet.trend' -Visual Line -Id 't')
    Assert-Equal 'Recalculer' ([string](Get-DomeniaWidgetPlaceholder -Need $local).ActionText)
    $unknown = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (New-DomeniaBoardItem -Source Builtin -Key 'fleet.inconnu' -Visual Kpi -Id 'u')
    Assert-Equal '' ([string](Get-DomeniaWidgetPlaceholder -Need $unknown).Action) 'source inconnue : aucun bouton'
    foreach ($state in @($paused,$running,$quick,$absent,$fleetAbsent,$missing)) { Assert-False ([string]$state.Message -like '*Non lu par cet inventaire*') }
}
Test-Case 'WGC-008' 'Suspendre dit ce qui change : requete arretee, releve commun ou inventaire commun conserves' {
    $inventory = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item (New-DomeniaBoardItem -Source Builtin -Key 'fleet.models' -Visual Bar -Id 'm')
    Assert-True ((Get-DomeniaWidgetPauseText -Need $inventory) -like '*relevé commun (WMI léger) reste lu*') (Get-DomeniaWidgetPauseText -Need $inventory)
    $computer = Get-DomeniaWidgetCollectionNeed -Board Computer -Item (New-DomeniaBoardItem -Source Builtin -Key 'computer.battery' -Visual Gauge -Id 'b')
    Assert-True ((Get-DomeniaWidgetPauseText -Need $computer) -like '*inventaire du poste reste une lecture commune*')
    $probe = Get-DomeniaWidgetCollectionNeed -Board Computer -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.free' -Visual Kpi -Id 'p')
    Assert-Equal 'Mesure suspendue : aucune requête WMI nʼest lancée pour ce widget.' (Get-DomeniaWidgetPauseText -Need $probe)
}
Test-Case 'WGC-009' 'Progression affichee sur le widget, chiffre garde jusquʼa lʼenregistrement' {
    Assert-Equal 'Collecte en cours · 3/40 poste(s) · 12 déjà à jour · 1 non confirmé(s)' (Format-DomeniaWidgetCollectProgress -Phase Running -Done 3 -Total 40 -Fresh 12 -Failed 1)
    Assert-Equal 'Collecte en cours · 0/2 poste(s)' (Format-DomeniaWidgetCollectProgress -Phase Running -Total 2)
    Assert-Equal 'Collecte en attente de confirmation · 450 poste(s)' (Format-DomeniaWidgetCollectProgress -Phase Confirming -Total 450)
    Assert-True ((Format-DomeniaWidgetCollectProgress -Phase Queued) -like 'En file*')
    Assert-Equal 'En file : en attente du recalcul de lʼOU.' (Format-DomeniaWidgetCollectProgress -Phase Waiting)
    Assert-Equal 'Recherche des mesures manquantes · 120/450 poste(s) · 80 déjà à jour' (Format-DomeniaWidgetCollectProgress -Phase Planning -Done 120 -Total 450 -Fresh 80)
    foreach ($phase in @('Preparing','Planning','Inventory','Directory','BitLocker','Card','Software','Local')) { Assert-True (Format-DomeniaWidgetCollectProgress -Phase $phase) $phase }
}
Test-Case 'WGC-010' 'Point 80 : clavier du widget, taille pas a pas et largeur tenue a haute resolution' {
    Assert-Equal 'L' (Get-DomeniaBoardNextSize -Size M -Step 1); Assert-Equal 'L' (Get-DomeniaBoardNextSize -Size L -Step 1)
    Assert-Equal 'S' (Get-DomeniaBoardNextSize -Size M -Step -1); Assert-Equal 'S' (Get-DomeniaBoardNextSize -Size S -Step -5)
    Assert-Equal 'L' (Get-DomeniaBoardNextSize -Size 'X' -Step 1) 'taille inconnue lue comme Moyenne'
    $g = { param($Key,$Alt,$Shift,$Editing) Get-DomeniaBoardKeyGesture -Key $Key -Alt $Alt -Shift $Shift -Editing $Editing }
    Assert-Equal 'Refresh' ([string](& $g 'F5' $false $false $false).Action) 'F5 hors personnalisation'
    Assert-Equal $null (& $g 'Delete' $false $false $false) 'Suppr ne retire rien hors personnalisation'
    Assert-Equal 'Remove' ([string](& $g 'Delete' $false $false $true).Action)
    Assert-Equal 'Move:Back' (@((& $g 'Left' $true $false $true) | ForEach-Object { $_.Action + ':' + $_.Value }) -join '')
    Assert-Equal 'Move:Last' (@((& $g 'End' $true $false $true) | ForEach-Object { $_.Action + ':' + $_.Value }) -join '')
    Assert-Equal 'Size:Grow' (@((& $g 'Up' $true $true $true) | ForEach-Object { $_.Action + ':' + $_.Value }) -join '')
    Assert-Equal 'Size:Shrink' (@((& $g 'Left' $true $true $true) | ForEach-Object { $_.Action + ':' + $_.Value }) -join '')
    Assert-Equal $null (& $g 'Left' $true $false $false) 'deplacer seulement en personnalisation'
    Assert-Equal $null (Get-DomeniaBoardKeyGesture -Key 'F5' -Control $true) 'Ctrl laisse la touche a la fenetre'
    Assert-Equal $null (& $g 'A' $true $false $true)
    # Fewer device-independent pixels (150 or 200 %, narrow window): a wider widget is scaled down, never below 60 %.
    Assert-Equal 1.0 (Get-DomeniaBoardFitScale -Needed 674 -Available 1200)
    Assert-Equal 0.89 (Get-DomeniaBoardFitScale -Needed 674 -Available 600) 'arrondi vers le bas pour tenir'
    Assert-True ((674 * (Get-DomeniaBoardFitScale -Needed 674 -Available 600)) -le 600) 'tient dans la page'
    Assert-Equal 0.6 (Get-DomeniaBoardFitScale -Needed 674 -Available 200) 'jamais illisible'
    Assert-Equal 1.0 (Get-DomeniaBoardFitScale -Needed 674 -Available 0) 'page non mesuree : rien ne change'
}
Test-Case 'WGC-011' 'Point 6 : explication dʼun chiffre, formule, perimetre, criteres, exclusions, couverture, dates et postes' {
    $item = New-DomeniaBoardItem -Source Builtin -Key 'fleet.stale' -Visual Kpi -Id 'b-fleet.stale'
    $need = Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $item
    $entry = New-DomeniaBoardEntry -Key 'fleet.stale' -Kind Value -Value '3' -Detail 'lastLogonTimestamp approximatif'
    $e = Get-DomeniaWidgetExplanation -Board Fleet -Item $item -Title 'Sans connexion AD depuis 90 j' -Entry $entry -Need $need -Scope 'OU Postes et ses sous-OU' -Coverage 'Base complete du 13/10' -ComputedAtUtc ([datetime]::new(2026, 10, 14, 8, 0, 0, [DateTimeKind]::Utc)) -TargetCount 3
    Assert-Equal 'Valeur affichée,Formule,Périmètre,Critères,Exclusions,Couverture,Dates,Postes du total,Actualiser ce widget' (@($e.Rows | ForEach-Object { $_.Aspect }) -join ',')
    Assert-Equal '3 · lastLogonTimestamp approximatif' ([string]$e.Rows[0].Text)
    Assert-Equal ([string](Get-DomeniaWidgetSource -Key 'fleet.stale').Formula) ([string]$e.Rows[1].Text)
    Assert-True ([string]$e.Rows[6].Text -like 'Calcul local du 14/10/2026*') ([string]$e.Rows[6].Text)
    Assert-True ([string]$e.Rows[6].Text -like '*un recalcul ne la rajeunit pas*') 'les dates de collecte ne rajeunissent pas'
    Assert-True ([string]$e.Rows[7].Text -like '3 poste(s) : liste exacte des GUID*') ([string]$e.Rows[7].Text)
    Assert-Equal ([string]$need.Label) ([string]$e.Rows[8].Text)
    $probe = New-DomeniaBoardItem -Source Probe -Key 'disk.free' -Visual Column -Id 'p'
    $p = Get-DomeniaWidgetExplanation -Board Fleet -Item $probe -Need (Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $probe) -MaxAgeDays 30
    Assert-Equal 'Aucune valeur : ce widget nʼa pas encore de donnée.' ([string]$p.Rows[0].Text)
    Assert-True ([string]$p.Rows[4].Text -like '*Relevés de plus de 30 jours ignorés.') ([string]$p.Rows[4].Text)
    Assert-Equal 'Liste nominative non conservée pour ce chiffre.' ([string]$p.Rows[7].Text)
    Assert-Equal 'Non mesurée pour ce chiffre.' ([string]$p.Rows[5].Text) 'couverture inconnue dite inconnue'
    Assert-Equal 'Exact' ([string]$e.Members)
    # A probe or a saved query keeps no frozen list: the button recomputes it, and the text never promises GUIDs.
    $again = Get-DomeniaWidgetExplanation -Board Fleet -Item $probe -Need (Get-DomeniaWidgetCollectionNeed -Board Fleet -Item $probe) -Coverage '19 postes analysés sur 26' -Members Recomputed
    Assert-Equal 'Recomputed' ([string]$again.Members)
    Assert-True ([string]$again.Rows[7].Text -like 'Aucune liste figée*Afficher les postes la recalcule*') ([string]$again.Rows[7].Text)
    Assert-False ([string]$again.Rows[7].Text -like '*GUID*') 'liste exacte promise sans liste conservee'
    Assert-Equal '19 postes analysés sur 26' ([string]$again.Rows[5].Text)
    # The workstation board has no list button: its text does not mention one.
    $computer = Get-DomeniaWidgetExplanation -Board Computer -Item (New-DomeniaBoardItem -Source Builtin -Key 'computer.os' -Visual Kpi -Id 'c') -TargetCount 1 -Members Selected
    Assert-Equal 'Le poste sélectionné seulement.' ([string]$computer.Rows[7].Text)
    Assert-Equal 'None' ([string](Get-DomeniaWidgetExplanation -Board Fleet -Item $item -Members Exact).Members) 'liste exacte sans compte : rien de promis'
}
Test-Case 'WGC-012' 'Point 73 : la liste ouverte porte le compte et le calcul du chiffre, jamais dʼun calcul remplace' {
    $label = Format-DomeniaWidgetDetailLabel -Title 'Sans connexion AD depuis 90 j' -Count 12 -ComputedAtUtc ([datetime]::new(2026, 10, 14, 8, 0, 0, [DateTimeKind]::Utc))
    Assert-True ($label -like 'Sans connexion AD depuis 90 j · 12 postes · calcul du 14/10 *') $label
    Assert-True ((Format-DomeniaWidgetDetailLabel -Title 'X' -Count 1) -ceq 'X · 1 poste') 'singulier, sans date inconnue'
    $long = Format-DomeniaWidgetDetailLabel -Title ('T' * 300) -Count 20000 -ComputedAtUtc ([datetime]::new(2026, 10, 14, 8, 0, 0, [DateTimeKind]::Utc))
    Assert-True ($long.Length -le 110) ('longueur ' + $long.Length)
    Assert-True ($long -like '*· 20000 postes · calcul du*') 'le compte reste visible'
    Assert-True (Test-DomeniaWidgetSnapshotCurrent -Drawn 'abc' -Current 'abc')
    Assert-False (Test-DomeniaWidgetSnapshotCurrent -Drawn 'abc' -Current 'abd')
    Assert-False (Test-DomeniaWidgetSnapshotCurrent -Drawn '' -Current '') 'aucun calcul : aucune liste exacte'
}
Test-Case 'WGC-013' 'Inventaire complet reconnu a ses categories, un rapide nʼest pas pris pour un complet' {
    Assert-False (Test-DomeniaComputerInventoryDeep -Result $null)
    Assert-False (Test-DomeniaComputerInventoryDeep -Result ([pscustomobject]@{ Rows = @([pscustomobject]@{ Category = 'Systeme'; Item = 'Modele'; Value = 'X' }) }))
    Assert-True (Test-DomeniaComputerInventoryDeep -Result ([pscustomobject]@{ Rows = @([pscustomobject]@{ Category = 'Systeme'; Item = 'Modele'; Value = 'X' }, [pscustomobject]@{ Category = 'Evenements systeme'; Item = 'Etat'; Value = 'Aucune' }) }))
}
Test-Case 'WGC-014' 'Collecte dʼun widget dans le modele des releves : portee du poste ou de la liste, texte de confirmation en trois lignes' {
    # FI-18: the OU shown on Accueil is read in the scope of the lists, the open workstation in its own scope.
    Assert-Equal 'List' (Get-DomeniaWidgetCollectSlot -Board Fleet)
    Assert-Equal 'Computer' (Get-DomeniaWidgetCollectSlot -Board Computer)
    Assert-Equal 'Computer' (Get-DomeniaWidgetCollectSlot -Board Software)
    # UX-24: three lines; the widget names its own reads (no console user), what is reused and why it is confirmed.
    $text = New-DomeniaParkConfirmationText -Count 201 -ScopeKind Scope -ScopeLabel 'Comptabilité' -WmiOnly $true -NoConsole $true -ProbeCount 1 -ReuseMaxAgeDays 30 -AlreadyFresh 10 -Widget $true -DirectLimit 200
    Assert-Equal 3 @($text.Lines).Count
    Assert-Equal '201 postes de Comptabilité · 10 postes déjà à jour, non contactés · plus de 200 postes à lire : nombre confirmé avant toute lecture' ([string]$text.Lines[0])
    Assert-Equal 'Ce qui sera lu : 1 requête du widget, en lecture seule.' ([string]$text.Lines[1])
    Assert-True ([string]$text.Lines[2] -like 'Durée estimée : *Seules les mesures absentes, en erreur ou de plus de 30 jours sont relues.') ([string]$text.Lines[2])
    Assert-Equal 'Collecter pour le widget' ([string]$text.Title)
    Assert-Equal 'Collecter 201 postes' ([string]$text.ConfirmText)
    Assert-Equal 'Comptabilité' ([string]$text.Target)
    # A widget with ping and console, one workstation already up to date, under its direct limit: nothing more said.
    $one = New-DomeniaParkConfirmationText -Count 1 -ScopeKind Scope -ScopeLabel 'PC-01' -AlreadyFresh 1 -Widget $true -DirectLimit 200
    Assert-Equal '1 poste de PC-01 · 1 poste déjà à jour, non contacté' ([string]$one.Lines[0])
    Assert-Equal 'Ce qui sera lu : présence · utilisateur connecté, en lecture seule.' ([string]$one.Lines[1])
    Assert-Equal 'Collecter 1 poste' ([string]$one.ConfirmText)
    # The surveys of the list are unchanged.
    $list = New-DomeniaParkConfirmationText -Count 48 -ScopeLabel 'OU Postes' -PingOnly $true
    Assert-Equal 'Vérifier la liste : qui répond ?' ([string]$list.Title)
    Assert-Equal 'Pinger 48 postes' ([string]$list.ConfirmText)
}
Test-Case 'WGC-015' 'Points 81 a 100 : widgets et sondes de lʼinventaire du poste avec leur source, leurs limites, leur collecte et leur pause' {
    $item = { param([string]$Key) New-DomeniaBoardItem -Source Builtin -Key $Key -Visual Kpi -Id ('b-' + $Key) }
    foreach ($key in @('computer.secureboot','computer.updates','computer.memory','computer.firewall','computer.bitlocker','computer.wsus','computer.reboot')) {
        $need = Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item $key)
        Assert-Equal 'ComputerInventory' ([string]$need.Kind) $key
        Assert-False $need.Deep ('inventaire rapide : ' + $key)
    }
    foreach ($key in @('computer.processes','computer.certificates')) { Assert-True (Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item $key)).Deep ('inventaire complet : ' + $key) }
    Assert-Equal 'Software' ([string](Get-DomeniaWidgetCollectionNeed -Board Software -Item (& $item 'software.duplicates')).Kind)
    Assert-True ([string](Get-DomeniaWidgetSource -Key 'computer.processes').Formula).Contains('processeurs logiques') 'part du processeur decrite'
    Assert-True ([string](Get-DomeniaWidgetSource -Key 'computer.reboot').Exclusions).Contains('Indices partiels') 'indices partiels exclus'
    Assert-True ([string](Get-DomeniaWidgetSource -Key 'computer.updates').Exclusions).Contains('Aucune conformité') 'aucune conformite conclue'
    # A paused inventory widget is a paused card with its own text and the resume button, like every other widget.
    $paused = Get-DomeniaWidgetPlaceholder -Need (Get-DomeniaWidgetCollectionNeed -Board Computer -Item (& $item 'computer.secureboot')) -Paused $true
    Assert-Equal 'Paused' ([string]$paused.State); Assert-Equal 'Resume' ([string]$paused.Action)
    # The eight probes added for the inventory explain their figure from their documented catalog entry.
    foreach ($id in @('hw.memoryusage','hw.computersystem','hw.batterystatic','hw.batteryfullcharge','hw.batterycycles','hw.monitorconnections','net.connectionprofiles','sec.avproducts')) {
        $probe = Get-DomeniaProbe -Id $id
        Assert-True ($null -ne $probe) ('sonde absente : ' + $id)
        $source = Get-DomeniaProbeWidgetSource -Probe $probe -Board Fleet
        Assert-True ([string]$source.Formula).Contains([string]$probe.Name) ('formule : ' + $id)
        Assert-True ([string]$source.Criteria).Contains('classe ' + [string]$probe.Class + ' (' + [string]$probe.Namespace + ')') ('criteres : ' + $id)
        Assert-True ([string]$source.Exclusions).EndsWith('Limites documentées : ' + ([string]$probe.Limitations).Trim()) ('limites : ' + $id)
        $widget = New-DomeniaBoardItem -Source Probe -Key $id -Visual Kpi -Id ('p-' + $id)
        $need = Get-DomeniaWidgetCollectionNeed -Board Computer -Item $widget
        Assert-Equal $id (@($need.ProbeIds) -join ',') ('collecte de la seule sonde : ' + $id)
        $e = Get-DomeniaWidgetExplanation -Board Computer -Item $widget -Need $need -Formula $source.Formula -Criteria $source.Criteria -Exclusions $source.Exclusions -Members Selected
        Assert-True ([string]$e.Rows[4].Text).Contains('Limites documentées') ('explication : ' + $id)
    }
    Assert-Equal $null (Get-DomeniaProbeWidgetSource -Probe $null)
}
