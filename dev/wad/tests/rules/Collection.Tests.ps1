# Points 11, 13 a 20, 159 et 160 : collecte adaptee aux reseaux lents. Regles pures de Domenia-Collection.Model,
# sans reseau ni base. Donnees fictives uniquement (domaine example.test).
. (Join-Path $modules 'Domenia-Collection.Model.ps1')
. (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-Park.Model.ps1')
$script:CT0 = [datetime]::SpecifyKind([datetime]'2026-10-14T10:00:00',[DateTimeKind]::Utc)

# ---------------------------------------------------------------- point 11
Test-Case 'P11' 'Profils : chaque famille a une durée, Standard reprend les durées historiques' {
    foreach ($profile in @(Get-DomeniaCollectionProfiles)) {
        foreach ($family in @(Get-DomeniaFreshnessFamilies)) { Assert-True ($profile.Seconds.ContainsKey([string]$family.Id)) ($profile.Id + ' sans ' + $family.Id) }
        Assert-True ([bool](ConvertFrom-DomeniaCollectionWindowText ([string]$profile.Windows)).Valid) ('Fenêtre par défaut invalide : ' + $profile.Id)
    }
    $standard = Resolve-DomeniaFreshnessTable 'Standard' $null
    Assert-Equal 120 $standard.Seconds['Presence']; Assert-Equal 300 $standard.Seconds['Console']; Assert-Equal 900 $standard.Seconds['Attributes']
    Assert-Equal 300 $standard.Seconds['Inventory']; Assert-Equal 60 $standard.Seconds['VolatileProbe']; Assert-Equal 900 $standard.Seconds['StaticProbe']
    Assert-Equal 'Presence,Console,Attributes,Inventory,StaticProbe,VolatileProbe' (@(Get-DomeniaFreshnessFamilies | ForEach-Object { [string]$_.Id }) -join ',') 'Seules les familles appliquées par un lecteur sont proposées'
    Assert-False $standard.Seconds.ContainsKey('Identity') 'Aucune durée sans lecteur'
    Assert-Equal 'Standard' (Resolve-DomeniaFreshnessTable 'Inexistant' $null).Profile 'Profil inconnu : Standard'
}
Test-Case 'P11' 'Durées personnalisées : famille inconnue, valeur non entière ou hors bornes ignorées et signalées' {
    $o = ConvertFrom-DomeniaFreshnessOverrides '{"Presence":600,"Inconnue":5,"Console":"abc","Identity":10}'
    Assert-Equal 600 $o.Values['Presence']
    Assert-False $o.Values.ContainsKey('Console'); Assert-False $o.Values.ContainsKey('Identity')
    Assert-Equal 3 @($o.Errors).Count
    $bad = ConvertFrom-DomeniaFreshnessOverrides '{pas du json'
    Assert-Equal 0 $bad.Values.Count; Assert-Equal 1 @($bad.Errors).Count
    Assert-Equal 0 (ConvertFrom-DomeniaFreshnessOverrides '').Values.Count
}
Test-Case 'P11' 'Une durée personnalisée remplace celle du profil et le tableau le dit' {
    $t = Resolve-DomeniaFreshnessTable 'SlowNetwork' @{Inventory=60}
    Assert-Equal 60 $t.Seconds['Inventory']
    $row = @($t.Rows | Where-Object { $_.Family -eq 'Inventory' })[0]
    Assert-Equal 'Personnalisé' $row.Source; Assert-Equal 3600 $row.ProfileSeconds; Assert-Equal '1 min' $row.Duration
    Assert-Equal 'Profil' (@($t.Rows | Where-Object { $_.Family -eq 'Presence' })[0]).Source
    $text = ConvertTo-DomeniaFreshnessOverridesText @{VolatileProbe=30;Presence=600}
    Assert-Equal '{"Presence":600,"VolatileProbe":30}' $text
    Assert-Equal 30 (ConvertFrom-DomeniaFreshnessOverrides $text).Values['VolatileProbe']
    Assert-Equal '' (ConvertTo-DomeniaFreshnessOverridesText @{})
}
Test-Case 'P11' 'Fraîcheur : la table du profil remplace la durée de la nature, lʼhistorique ne vieillit pas' {
    $t = Resolve-DomeniaFreshnessTable 'Troubleshooting' $null
    Assert-Equal 'Stale' (Get-DomeniaFreshness 'Presence' $script:CT0 $null $script:CT0.AddSeconds(60) $t).State
    Assert-Equal 'Fresh' (Get-DomeniaFreshness 'Presence' $script:CT0 $null $script:CT0.AddSeconds(60)).State 'Sans table : 120 s'
    Assert-Equal 'Historical' (Get-DomeniaFreshness 'History' $script:CT0 $null $script:CT0.AddDays(30) $t).State
    Assert-Equal 'Fresh' (Get-DomeniaFreshness 'Presence' $script:CT0 $null $script:CT0.AddSeconds(500) @{Presence=600}).State 'Dictionnaire famille vers secondes'
    $record = [pscustomobject]@{Times=@{Attributes=[pscustomobject]@{ObservedUtc=$script:CT0.ToString('o');LastAttemptUtc=$script:CT0.ToString('o')}}}
    Assert-Equal 'Fresh' (Get-DomeniaRecordFreshness $record 'Attributes' $script:CT0.AddMinutes(30) (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)).State
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $record 'Attributes' $script:CT0.AddMinutes(30)).State
}
Test-Case 'P11' 'Plan de collecte : durée retenue la plus courte du profil et du plafond, zéro force la relecture' {
    $previous = [pscustomobject]@{Guid='g1';Key='cn=pc-1';InventoryError='';Inventory=[pscustomobject]@{CheckedUtc=$script:CT0.AddMinutes(-20).ToString('o')}
        Probes=[pscustomobject]@{'hw.bios'=[pscustomobject]@{CheckedUtc=$script:CT0.AddMinutes(-20).ToString('o');DefinitionHash='h1'};'net.adapter'=[pscustomobject]@{CheckedUtc=$script:CT0.AddMinutes(-4).ToString('o');DefinitionHash='h2'}}}
    $probes = @([pscustomobject]@{Id='hw.bios';DefinitionHash='h1'},[pscustomobject]@{Id='net.adapter';DefinitionHash='h2'})
    $standard = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 15 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'Standard' $null)
    Assert-Equal 0 $standard.Reused; Assert-True $standard.Inventory; Assert-Equal 2 @($standard.Probes).Count
    $slow = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 60 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)
    Assert-Equal 3 $slow.Reused; Assert-False $slow.Inventory; Assert-Equal 0 @($slow.Probes).Count
    $capped = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 5 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)
    Assert-Equal 1 $capped.Reused 'Le plafond de 5 min ne garde que la sonde de 4 min'
    $forced = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 0 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)
    Assert-Equal 0 $forced.Reused
    $legacy = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 15 -NowUtc $script:CT0
    Assert-Equal $standard.Reused $legacy.Reused 'Sans table : durées historiques'
}

# ---------------------------------------------------------------- point 159
$script:Monday10 = [datetime]'2026-10-12T10:00:00'
$script:Monday1230 = [datetime]'2026-10-12T12:30:00'
Test-Case 'P159' 'Fenêtre : syntaxe des jours et des plages, erreurs nommées' {
    $w = ConvertFrom-DomeniaCollectionWindowText 'lun-ven 07:30-12:00 13:30-18:00; sam 08:00-12:00'
    Assert-True $w.Valid; Assert-Equal 'Rules' $w.Mode; Assert-Equal 3 @($w.Rules).Count
    Assert-Equal 5 @(@($w.Rules)[0].Days).Count
    Assert-Equal 'Always' (ConvertFrom-DomeniaCollectionWindowText '').Mode
    Assert-Equal 'Always' (ConvertFrom-DomeniaCollectionWindowText 'Toujours').Mode
    Assert-Equal 'Never' (ConvertFrom-DomeniaCollectionWindowText 'jamais').Mode
    $wrap = ConvertFrom-DomeniaCollectionWindowText 'ven-lun'
    Assert-Equal 4 @(@($wrap.Rules)[0].Days).Count 'Vendredi, samedi, dimanche, lundi'
    $bad = ConvertFrom-DomeniaCollectionWindowText 'lundo 07:00-08:00; mar 25:00-26:00; mer 10:00-10:00'
    Assert-False $bad.Valid; Assert-Equal 3 @($bad.Errors).Count
}
Test-Case 'P159' 'Fenêtre : ouverte ou fermée selon le jour et lʼheure locale, plage de nuit' {
    $w = ConvertFrom-DomeniaCollectionWindowText 'lun-ven 12:00-14:00 22:00-06:00; sam-dim'
    Assert-True (Test-DomeniaCollectionWindowOpen $w $script:Monday1230).Open
    Assert-False (Test-DomeniaCollectionWindowOpen $w $script:Monday10).Open
    Assert-True (Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-13T03:00:00')).Open 'Nuit de lundi à mardi'
    Assert-False (Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-12T03:00:00')).Open 'Dimanche nʼouvre pas la nuit du lundi'
    Assert-True (Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-17T15:00:00')).Open 'Samedi entier'
    Assert-True (Test-DomeniaCollectionWindowOpen (ConvertFrom-DomeniaCollectionWindowText '') $script:Monday10).Open
    Assert-False (Test-DomeniaCollectionWindowOpen (ConvertFrom-DomeniaCollectionWindowText 'jamais') $script:Monday10).Open
    $quick = Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-13T03:00:00') -StateOnly
    Assert-True $quick.Open 'État seul identique'; Assert-True ($null -eq $quick.NextChange) 'État seul : prochain changement non calculé'
}
Test-Case 'P159' 'Fenêtre : prochain changement et texte sans promesse' {
    $w = ConvertFrom-DomeniaCollectionWindowText 'lun-ven 12:00-14:00'
    $closed = Test-DomeniaCollectionWindowOpen $w $script:Monday10
    Assert-Equal ([datetime]'2026-10-12T12:00:00') $closed.NextChange
    Assert-True ((Format-DomeniaCollectionWindowState $closed $script:Monday10) -match 'reprise à 12:00')
    $open = Test-DomeniaCollectionWindowOpen $w $script:Monday1230
    Assert-Equal ([datetime]'2026-10-12T14:00:00') $open.NextChange
    Assert-True ((Format-DomeniaCollectionWindowState $open $script:Monday1230) -match 'ouverte jusqu.à 14:00')
    $friday = Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-16T15:00:00')
    Assert-True ((Format-DomeniaCollectionWindowState $friday ([datetime]'2026-10-16T15:00:00')) -match 'reprise lundi à 12:00')
}
Test-Case 'P159' 'Fenêtre : seules les sources de fond réseau sont retenues ; une fenêtre invalide les suspend' {
    $never = ConvertFrom-DomeniaCollectionWindowText 'jamais'
    Assert-False (Test-DomeniaCollectionWindowAllows $never 'Reconcile' $script:Monday10)
    Assert-False (Test-DomeniaCollectionWindowAllows $never 'ObjectChanges' $script:Monday10)
    Assert-True (Test-DomeniaCollectionWindowAllows $never 'Live' $script:Monday10) 'Une sélection nʼest pas un travail de fond'
    Assert-True (Test-DomeniaCollectionWindowAllows $never 'Storage' $script:Monday10)
    Assert-True (Test-DomeniaCollectionWindowAllows $never 'Dashboard' $script:Monday10)
    Assert-False (Test-DomeniaCollectionWindowAllows (ConvertFrom-DomeniaCollectionWindowText 'xx') 'Park' $script:Monday10)
    Assert-True (Test-DomeniaCollectionWindowAllows (ConvertFrom-DomeniaCollectionWindowText '') 'Park' $script:Monday10)
}

# ---------------------------------------------------------------- point 14
Test-Case 'P14' 'Concurrence : moitié moins après un délai, une place de plus après une série de réponses' {
    $p = New-DomeniaSourcePolicy -MaxLimit 8 -FailureThreshold 0 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    $e = Get-DomeniaSourceEntry $h $k $p
    Assert-Equal 8 $e.Limit 'Départ à la borne choisie'
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0)
    Assert-Equal 4 $e.Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(1))
    Assert-Equal 2 $e.Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 100 $p $script:CT0.AddSeconds(2))
    Assert-Equal 2 $e.Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 100 $p $script:CT0.AddSeconds(3))
    Assert-Equal 3 $e.Limit
    Assert-Equal 'Closed' $e.State 'Sans seuil de suspension'
}
Test-Case 'P14' 'Concurrence : une latence qui double ralentit, la remontée reste sous la borne choisie' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 0 -DecreaseCooldownSeconds 0 -SlowFloorMs 500
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($i in 1..3) { [void](Register-DomeniaSourceOutcome $h $k 'Success' 200 $p $script:CT0.AddSeconds($i)) }
    Assert-Equal 4 $h[$k].Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 2000 $p $script:CT0.AddSeconds(4))
    Assert-Equal 2 $h[$k].Limit 'Latence décuplée'
    foreach ($i in 5..30) { [void](Register-DomeniaSourceOutcome $h $k 'Success' 200 $p $script:CT0.AddSeconds($i)) }
    Assert-Equal 4 $h[$k].Limit 'Jamais au-delà de la borne'
}
Test-Case 'P14' 'Concurrence : une seule baisse par intervalle, les réponses sans valeur ne changent rien' {
    $p = New-DomeniaSourcePolicy -MaxLimit 8 -FailureThreshold 0 -DecreaseCooldownSeconds 10
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0)
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(2))
    Assert-Equal 4 $h[$k].Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(11))
    Assert-Equal 2 $h[$k].Limit
    foreach ($i in 1..10) { [void](Register-DomeniaSourceOutcome $h $k 'Neutral' -1 $p $script:CT0.AddSeconds(20 + $i)) }
    Assert-Equal 2 $h[$k].Limit; Assert-Equal 3 $h[$k].ConsecutiveFailures
}

# ---------------------------------------------------------------- point 15
Test-Case 'P15' 'Budgets par site : un sous-réseau lent ne prend pas les places des autres' {
    $s = New-DomeniaCampaignSources -MaxLimit 4
    $slow = 'site:10.1.2.0/24'; $fast = 'site:10.9.9.0/24'
    [void](Register-DomeniaSourceOutcome $s.Health $slow 'Timeout' -1 (Get-DomeniaCampaignSourcePolicy $s $slow) $script:CT0)
    [void](Register-DomeniaSourceOutcome $s.Health $slow 'Timeout' -1 (Get-DomeniaCampaignSourcePolicy $s $slow) $script:CT0.AddSeconds(11))
    Assert-Equal 1 $s.Health[$slow].Limit
    Assert-False (Test-DomeniaSourceAdmission $s.Health $slow 1 (Get-DomeniaCampaignSourcePolicy $s $slow) $script:CT0.AddSeconds(12)).Allowed
    Assert-True (Test-DomeniaSourceAdmission $s.Health $fast 3 (Get-DomeniaCampaignSourcePolicy $s $fast) $script:CT0.AddSeconds(12)).Allowed
    Assert-False (Test-DomeniaSourceAdmission $s.Health $fast 4 (Get-DomeniaCampaignSourcePolicy $s $fast) $script:CT0.AddSeconds(12)).Allowed 'Borne choisie'
    Assert-True ((Get-DomeniaCampaignSourceSummary $s $script:CT0.AddSeconds(12)) -match 'sous-réseau présumé 10\.1\.2\.0/24 ralenti à 1/4')
}
Test-Case 'P15' 'Adresses : sous-réseau présumé, adresses invalides ignorées, clé par fournisseur' {
    Assert-Equal '10.1.2.0/24' (Get-DomeniaSubnetKey '10.1.2.37')
    Assert-Equal '10.1.0.0/16' (Get-DomeniaSubnetKey '10.1.2.37' 16)
    Assert-Equal '' (Get-DomeniaSubnetKey '127.0.0.1'); Assert-Equal '' (Get-DomeniaSubnetKey '256.1.1.1'); Assert-Equal '' (Get-DomeniaSubnetKey 'fe80::1')
    Assert-Equal '10.77.0.20' (Get-DomeniaAddressFromText 'Réponse ICMP · 12 ms · 10.77.0.20')
    Assert-Equal '' (Get-DomeniaAddressFromText 'ICMP : TimedOut · PC-1')
    Assert-Equal 'site:10.77.0.0/24' (Get-DomeniaCollectionSourceKey 'Cim' '' '10.77.0.20')
    Assert-Equal 'site:?' (Get-DomeniaCollectionSourceKey 'Cim' '' '')
    Assert-Equal 'dc:dc01.example.test' (Get-DomeniaCollectionSourceKey 'Directory' 'DC01.example.test' '')
    Assert-False (Test-DomeniaSourceAdmission $null 'site:?' 4 (New-DomeniaCampaignSources -MaxLimit 4).UnknownPolicy).Allowed
}

# ---------------------------------------------------------------- point 160
Test-Case 'P160' 'Suspension : échecs répétés suspendent la source seule, puis une lecture dʼessai et une reprise progressive' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -OpenSeconds 60 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($i in 0..2) { [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds($i)) }
    $closed = Test-DomeniaSourceAdmission $h $k 0 $p $script:CT0.AddSeconds(10)
    Assert-False $closed.Allowed; Assert-Equal 'Open' $closed.State; Assert-True ($null -ne $closed.RetryAfterUtc)
    Assert-True (Test-DomeniaSourceAdmission $h 'site:10.9.9.0/24' 0 $p $script:CT0.AddSeconds(10)).Allowed 'Un autre site continue'
    $trial = Test-DomeniaSourceAdmission $h $k 0 $p $script:CT0.AddSeconds(70)
    Assert-True $trial.Allowed; Assert-Equal 'HalfOpen' $trial.State
    Assert-False (Test-DomeniaSourceAdmission $h $k 1 $p $script:CT0.AddSeconds(70)).Allowed 'Une seule lecture dʼessai'
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 300 $p $script:CT0.AddSeconds(72))
    Assert-Equal 'Closed' $h[$k].State; Assert-Equal 1 $h[$k].Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 300 $p $script:CT0.AddSeconds(73))
    Assert-Equal 2 $h[$k].Limit 'Reprise progressive'
}
Test-Case 'P160' 'Suspension : un échec pendant lʼessai suspend plus longtemps, sans dépasser la borne' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -OpenSeconds 60 -MaxOpenSeconds 900 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'dc:dc01.example.test'
    foreach ($i in 0..2) { [void](Register-DomeniaSourceOutcome $h $k 'Failure' -1 $p $script:CT0) }
    Assert-Equal 60 ([int]($h[$k].OpenUntilUtc - $script:CT0).TotalSeconds)
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(70))
    Assert-Equal 120 ([int]($h[$k].OpenUntilUtc - $script:CT0.AddSeconds(70)).TotalSeconds)
    $at = $script:CT0.AddSeconds(70)
    foreach ($i in 1..12) { $at = $h[$k].OpenUntilUtc.AddSeconds(1); [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $at) }
    Assert-True ((($h[$k].OpenUntilUtc) - $at).TotalSeconds -le 900)
    Assert-True ([int]$h[$k].Suspensions -ge 14)
}
Test-Case 'P160' 'Suspension : machine éteinte, droit refusé ou compte rejeté ne comptent pas contre le site' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($outcome in @('Offline','AccessDenied','Credential')) {
        $class = ConvertTo-DomeniaCollectionFailure -Outcome $(switch ($outcome) { 'Offline' { 'Timeout' } 'AccessDenied' { 'Denied' } default { 'AuthRejected' } }) -Presence 'Sans réponse au ping'
        foreach ($i in 1..5) { [void](Register-DomeniaSourceOutcome $h $k ([string]$class.Health) 100 $p $script:CT0.AddSeconds($i)) }
    }
    Assert-Equal 'Closed' $h[$k].State; Assert-Equal 0 $h[$k].ConsecutiveFailures
    Assert-True (Test-DomeniaSourceAdmission $h $k 0 $p $script:CT0.AddSeconds(30)).Allowed
}

# ---------------------------------------------------------------- point 17
Test-Case 'P17' 'Progression : résultats validés, temps écoulé, attente réelle et absence de progrès' {
    $state = Get-DomeniaCampaignProgressState -Total 400 -Validated 120 -Pending 4 -Waiting 276 -StartedUtc $script:CT0 -LastValidatedUtc $script:CT0.AddSeconds(200) -HeldSeconds 35 -NowUtc $script:CT0.AddSeconds(250)
    Assert-False $state.Stalled; Assert-Equal 50 ([int]$state.IdleSeconds); Assert-Equal 250 ([int]$state.ElapsedSeconds)
    Assert-True ($state.Text -match '120/400'); Assert-True ($state.Text -match 'attente réelle 35 s'); Assert-True ($state.Text -match '4 min 10 s')
    $stall = Get-DomeniaCampaignProgressState -Total 400 -Validated 120 -Pending 4 -StartedUtc $script:CT0 -LastValidatedUtc $script:CT0.AddSeconds(10) -NowUtc $script:CT0.AddSeconds(250) -StallSeconds 120
    Assert-True $stall.Stalled; Assert-True ($stall.Text -match 'aucun progrès depuis')
    $none = Get-DomeniaCampaignProgressState -Total 10 -Validated 0 -Pending 2 -StartedUtc $script:CT0 -NowUtc $script:CT0.AddSeconds(5)
    Assert-True ($none.Text -match 'aucun résultat validé'); Assert-False $none.Stalled
    $done = Get-DomeniaCampaignProgressState -Total 10 -Validated 10 -StartedUtc $script:CT0 -LastValidatedUtc $script:CT0 -NowUtc $script:CT0.AddHours(1)
    Assert-False $done.Stalled 'Rien en cours : pas de blocage'
}

# ---------------------------------------------------------------- point 18
Test-Case 'P18' 'Classement : seul un incident transitoire est repris, borné et espacé' {
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence 'En ligne').Category
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence '' -PingCollected $false).Category 'WMI seul'
    Assert-Equal 'Offline' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence 'Sans réponse au ping').Category
    Assert-Equal 'Credential' (ConvertTo-DomeniaCollectionFailure -Outcome 'AuthRejected').Category
    Assert-Equal 'AccessDenied' (ConvertTo-DomeniaCollectionFailure -Outcome 'Denied').Category
    Assert-Equal 'ProtocolUnreachable' (ConvertTo-DomeniaCollectionFailure -Outcome 'Unavailable' -Presence 'En ligne').Category
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Délai dépassé : Console du parc').Category
    Assert-Equal 'Credential' (ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Identifiants rejetés pour cette ressource').Category
    Assert-Equal 'Success' (ConvertTo-DomeniaCollectionFailure -Outcome 'Observed' -Presence 'En ligne').Category
    $first = Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 1 -NowUtc $script:CT0
    Assert-True $first.Retry; Assert-Equal 30 $first.DelaySeconds; Assert-Equal $script:CT0.AddSeconds(30) $first.NotBeforeUtc
    Assert-Equal 120 (Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 2 -NowUtc $script:CT0).DelaySeconds
    Assert-False (Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 3 -NowUtc $script:CT0).Retry 'Trois essais au plus'
    foreach ($category in @('Credential','AccessDenied','Offline','ProtocolUnreachable','Permanent','ClassAbsent','Success')) { Assert-False (Get-DomeniaCollectionRetryDecision -Category $category -Attempt 1).Retry $category }
    Assert-False (Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 1 -IsWrite $true).Retry 'Une écriture nʼest jamais rejouée'
}

# ---------------------------------------------------------------- point 19
Test-Case 'P19' 'Capacités : classe absente liée à la version de Windows, refus lié aux comptes, durée limitée' {
    $m = New-DomeniaCapabilityMemory
    $class = 'class:root\cimv2:Win32_Battery'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability $class -Kind 'ClassAbsent' -NowUtc $script:CT0 -Build '22631' -AccountGeneration 3)
    Assert-True (Test-DomeniaCapabilityFact $m 'pc-1' 'CLASS:root\cimv2:Win32_Battery' $script:CT0.AddHours(1) '22631' 3).Known
    Assert-False (Test-DomeniaCapabilityFact $m 'pc-1' $class $script:CT0.AddHours(1) '26100' 3).Known 'Nouvelle version de Windows'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability $class -Kind 'ClassAbsent' -NowUtc $script:CT0 -Build '22631' -AccountGeneration 3)
    Assert-False (Test-DomeniaCapabilityFact $m 'pc-1' $class $script:CT0.AddDays(8) '22631' 3).Known 'Expire après sept jours'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability 'cim' -Kind 'RightDenied' -NowUtc $script:CT0 -AccountGeneration 3)
    Assert-True (Test-DomeniaCapabilityFact $m 'PC-1' 'cim' $script:CT0.AddMinutes(10) '' 3).Known
    Assert-False (Test-DomeniaCapabilityFact $m 'PC-1' 'cim' $script:CT0.AddMinutes(10) '' 4).Known 'Changement de compte'
    Assert-True (Test-DomeniaWmiClassAbsentText 'Classe non valide') ; Assert-True (Test-DomeniaWmiClassAbsentText 'Invalid namespace (0x8004100E)')
    Assert-False (Test-DomeniaWmiClassAbsentText 'Accès refusé')
}
Test-Case 'P19' 'Capacités : plan sans les lectures impossibles, relecture forcée, mémoire semée par le dernier relevé' {
    $battery = [pscustomobject]@{Id='hw.battery';Namespace='root\cimv2';Class='Win32_Battery'}
    $bios = [pscustomobject]@{Id='hw.bios';Namespace='root\cimv2';Class='Win32_BIOS'}
    $previous = [pscustomobject]@{Probes=[pscustomobject]@{'hw.battery'=[pscustomobject]@{Error='Classe non valide (0x80041010)';CheckedUtc=$script:CT0.AddHours(-2).ToString('o')}}}
    $m = New-DomeniaCapabilityMemory
    $plan = Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($battery,$bios) -Previous $previous -NowUtc $script:CT0 -Build '22631' -AccountGeneration 1
    Assert-Equal 1 @($plan.Probes).Count; Assert-Equal 'hw.bios' @($plan.Probes)[0].Id; Assert-Equal 1 @($plan.Skipped).Count; Assert-False $plan.SkipCim
    Assert-Equal 2 @((Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($battery,$bios) -Previous $previous -NowUtc $script:CT0 -Force $true).Probes).Count 'Relecture forcée'
    $old = [pscustomobject]@{Probes=[pscustomobject]@{'hw.battery'=[pscustomobject]@{Error='Classe non valide';CheckedUtc=$script:CT0.AddDays(-9).ToString('o')}}}
    Assert-Equal 2 @((Get-DomeniaCapabilityPlan -Memory (New-DomeniaCapabilityMemory) -Target 'PC-2' -Probes @($battery,$bios) -Previous $old -NowUtc $script:CT0).Probes).Count 'Constat trop ancien'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability 'cim' -Kind 'ProtocolUnreachable' -NowUtc $script:CT0 -AccountGeneration 1)
    Assert-True (Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($bios) -NowUtc $script:CT0.AddMinutes(5) -AccountGeneration 1).SkipCim
    Assert-False (Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($bios) -NowUtc $script:CT0.AddMinutes(16) -AccountGeneration 1).SkipCim 'Quinze minutes au plus'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability 'cim' -Kind 'ProtocolUnreachable' -NowUtc $script:CT0 -AccountGeneration 1)
    Assert-Equal 1 (Clear-DomeniaCapabilityFact $m 'PC-1' 'cim')
    Assert-False (Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($bios) -NowUtc $script:CT0.AddMinutes(5) -AccountGeneration 1).SkipCim 'Une réussite efface le constat'
}

# ---------------------------------------------------------------- point 13
Test-Case 'P13' 'Regroupement WMI : console, inventaire et sondes de même classe partagent leurs lectures' {
    $probes = @(
        [pscustomobject]@{Id='hw.maker';Namespace='root\cimv2';Class='Win32_ComputerSystem';Filter='';Skip=''}
        [pscustomobject]@{Id='hw.model';Namespace='root\cimv2';Class='Win32_ComputerSystem';Filter='';Skip=''}
        [pscustomobject]@{Id='disk.cfree';Namespace='root\cimv2';Class='Win32_LogicalDisk';Filter="DeviceID='C:'";Skip=''}
        [pscustomobject]@{Id='sec.av';Namespace='root\SecurityCenter2';Class='AntiVirusProduct';Filter='';Skip='DomainController'}
    )
    $plan = Measure-DomeniaCimQueryPlan -ProbeUser $true -Inventory $true -Probes $probes
    Assert-Equal 9 $plan.Requested; Assert-Equal 4 $plan.Executed; Assert-Equal 5 $plan.Avoided
    Assert-Equal 0 (Measure-DomeniaCimQueryPlan -ProbeUser $true -Inventory $false -Probes @()).Avoided
    Assert-Equal (Get-DomeniaCimGroupKey 'ROOT\CIMV2' 'win32_logicaldisk' "DeviceID='C:'") (Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_LogicalDisk' "DeviceID='C:'")
    Assert-True ((Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_Service' "Name='A'") -cne (Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_Service' "Name='a'")) 'Filtres distincts : lectures distinctes'
}

# ---------------------------------------------------------------- point 20
function New-CltPlan {
    $targets = @(for ($i = 1; $i -le 300; $i++) { [pscustomobject]@{Computer=('PC-' + $i);Key=('CN=PC-' + $i + ',OU=Postes,DC=example,DC=test');Guid=('00000000-0000-0000-0000-' + $i.ToString('d12'))} })
    $targets += $targets[0]
    return (New-DomeniaCampaignPlan -Kind 'Analysis' -Targets $targets -ProbeIds @('hw.bios','id invalide!') -Inventory $true -ScopeLabel 'OU=Postes' -DomainDn 'DC=example,DC=test' -DatabasePath 'C:\fixture\base.db' -NowUtc $script:CT0)
}
Test-Case 'P20' 'Plan durable : relu à lʼidentique, compressé, sans doublon et refusé sʼil est altéré' {
    $plan = New-CltPlan
    Assert-Equal 300 @($plan.Targets).Count 'Doublon retiré'
    Assert-Equal 1 @($plan.ProbeIds).Count
    $text = ConvertTo-DomeniaCampaignPlanText $plan
    Assert-True ($text.Length -lt 20000) 'Liste compressée'
    $back = ConvertFrom-DomeniaCampaignPlanText $text
    Assert-Equal 300 @($back.Targets).Count; Assert-Equal 'PC-300' $back.Targets[299].N; Assert-Equal $plan.Id $back.Id
    Assert-Equal 'Analysis' $back.Kind; Assert-True $back.Inventory; Assert-Equal 'hw.bios' @($back.ProbeIds)[0]
    $head = ConvertFrom-Json $text; $head.TargetsSha256 = '00'
    Assert-Throws { ConvertFrom-DomeniaCampaignPlanText ($head | ConvertTo-Json -Compress) } 'Empreinte altérée acceptée'
    $head = ConvertFrom-Json $text; $head.Kind = 'Write'
    Assert-Throws { ConvertFrom-DomeniaCampaignPlanText ($head | ConvertTo-Json -Compress) } 'Type non autorisé accepté'
    Assert-Throws { ConvertFrom-DomeniaCampaignPlanText 'pas du json' }
    $odd = New-DomeniaCampaignPlan -Kind 'Ping' -Targets @([pscustomobject]@{Computer='PC 1';Key='CN=PC 1,DC=example,DC=test';Guid='00000000-0000-0000-0000-000000000001'},[pscustomobject]@{Computer='PC-2';Key=('CN=PC-2' + [char]10 + ',DC=example,DC=test');Guid='00000000-0000-0000-0000-000000000002'},[pscustomobject]@{Computer='PC-3';Key='CN=PC-3,DC=example,DC=test';Guid='00000000-0000-0000-0000-000000000003'})
    Assert-Equal 1 @($odd.Targets).Count 'Nom dʼhôte ou DN non relisible à lʼidentique : poste écarté, plan signalé non enregistré'
    Assert-Equal 'PC-3' (ConvertFrom-DomeniaCampaignPlanText (ConvertTo-DomeniaCampaignPlanText $odd)).Targets[0].N
}
Test-Case 'P20' 'Avancement : un poste validé nʼest jamais relu, le compteur vient des bits' {
    $plan = New-CltPlan
    $progress = New-DomeniaCampaignProgress $plan $script:CT0
    Assert-True (Set-DomeniaCampaignTargetDone $progress 0); Assert-False (Set-DomeniaCampaignTargetDone $progress 0) 'Double livraison'
    Assert-True (Set-DomeniaCampaignTargetDone $progress 299); Assert-False (Set-DomeniaCampaignTargetDone $progress 300)
    Assert-Equal 2 $progress.DoneCount
    $data = ConvertFrom-Json (ConvertTo-DomeniaCampaignProgressText $progress); $data.DoneCount = 0
    $back = ConvertFrom-DomeniaCampaignProgressText ($data | ConvertTo-Json -Compress) $plan
    Assert-Equal 2 $back.DoneCount
    $remaining = @(Get-DomeniaCampaignRemainingTargets $plan $back)
    Assert-Equal 298 $remaining.Count; Assert-Equal 'PC-2' $remaining[0].name
    Assert-Equal 0 @($remaining | Where-Object { $_.name -eq 'PC-300' }).Count
    Assert-Throws { ConvertFrom-DomeniaCampaignProgressText (ConvertTo-DomeniaCampaignProgressText $progress) ([pscustomobject]@{Id='ffffffffffffffffffffffffffffffff';Targets=@()}) } 'Avancement dʼun autre plan accepté'
}
Test-Case 'P20' 'Reprise : proposée seulement sur le même domaine et la même base, avec le motif' {
    $plan = New-CltPlan
    $progress = New-DomeniaCampaignProgress $plan $script:CT0
    [void](Set-DomeniaCampaignTargetDone $progress 0); [void](Set-DomeniaCampaignTargetDone $progress 1)
    $progress.State = 'Paused'
    $state = Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'dc=example,dc=test' -DatabasePath 'C:\fixture\base.db'
    Assert-True $state.Resumable; Assert-Equal 298 $state.Remaining; Assert-True ($state.Reason -match 'arrêté par lʼopérateur'); Assert-True ($state.Reason -match 'lecture seule')
    Assert-False (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'DC=autre,DC=test' -DatabasePath 'C:\fixture\base.db').Resumable
    Assert-False (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'DC=example,DC=test' -DatabasePath 'C:\autre.db').Resumable
    for ($i = 2; $i -lt 300; $i++) { [void](Set-DomeniaCampaignTargetDone $progress $i) }
    Assert-False (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'DC=example,DC=test' -DatabasePath 'C:\fixture\base.db').Resumable 'Tout est validé'
    Assert-False (Get-DomeniaCampaignResumeState -Progress $null).Resumable
}
