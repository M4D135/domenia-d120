# Regles de sante du tableau de bord (points 75 a 79) : explication du score, politiques par OU, suspensions,
# comparaison de deux releves et tableaux croises. Donnees fictives uniquement (domaine example.invalid).
. (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-BoardFleet.Model.ps1')
$script:HrNow = ([datetime]'2026-10-13T12:00:00Z').ToUniversalTime()
$script:HrDomain = 'DC=example,DC=invalid'
$script:HrScope = 'OU=Fleet,' + $script:HrDomain
$script:HrLifecycle = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-WindowsLifecycle.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
function New-HrSource {
    # Four active workstations of one group; m1 critical disk, m2 tight disk, m3 never collected, m4 inactive in AD.
    param([double[]]$FreeGb = @(5, 15, -1, 40))
    $rows = @(); $presence = @()
    for ($i = 1; $i -le 4; $i++) {
        $dn = 'CN=HR-' + $i + ',' + $script:HrScope; $guid = '00000000-0000-0000-0001-' + $i.ToString('000000000000')
        $logon = if ($i -eq 4) { '2026-01-01' } else { '2026-10-12' }
        $rows += , [pscustomobject]@{ name = ('HR-' + $i); distinguished_name = $dn; object_guid = $guid; gid = '1'; st = 'A'; logon = $logon }
        if ($FreeGb[$i - 1] -lt 0) { continue }
        $stamp = $script:HrNow.AddHours(-1).ToString('o')
        $inventory = [pscustomobject]@{ CheckedUtc = $stamp; Model = 'Modele-HR'; RamBytes = 8GB; DiskSize = 100GB; DiskFree = ($FreeGb[$i - 1] * 1GB); LastBootUtc = $script:HrNow.AddDays(-2).ToString('o'); OsCaption = 'Windows 11 Enterprise'; Build = '26100' }
        $presence += , [pscustomobject]@{ object_key = $dn.ToLowerInvariant(); object_guid = $guid; name = ('HR-' + $i); distinguished_name = $dn; gid = '1'; in_scope = $true; observation = [pscustomobject]@{ Guid = $guid; Presence = 'En ligne'; PresenceCheckedUtc = $stamp; ObservedUtc = $stamp; Inventory = $inventory } }
    }
    return [pscustomobject]@{ Types = @(); Groups = @([pscustomobject]@{ gid = '1'; st = 'A'; n = 4; os = 'Windows 11 Enterprise'; ver = '10.0 (26100)'; lb = 0; cr = 'O'; pw = 'R'; lk = 'O'; bk = 'K' }); Machines = $rows; Targets = $rows; Presence = $presence; Parents = @([pscustomobject]@{ p = $script:HrScope; n = 4 }); Coverage = [pscustomobject]@{ FactsFresh = 4; FactsStale = 0; BitLockerRead = 4; BitLockerAt = $script:HrNow.ToString('o') }; History = @(); Links = 0; DomainDn = $script:HrDomain }
}
function Get-HrRow { param($Board,[string]$Id) return @(@($Board.HealthExplanation.Rows) | Where-Object { [string]$_.Id -ceq $Id })[0] }
function New-HrTarget { param([string]$Id) return [pscustomobject]@{ object_guid = $Id; name = $Id } }
function Save-HrEditorScope {
    # Same composition as the "Appliquer" button of the rules editor: rows loaded from the resolved policy, optional
    # edits, the editor policy (purge included), then the scoped save.
    param($Book, [string]$ScopeDn, [hashtable]$Thresholds = @{}, $Suspensions = $null)
    $p = Resolve-DomeniaHealthPolicy $Book $ScopeDn
    $limits = @{}; foreach ($q in $p.Thresholds.PSObject.Properties) { $limits[$q.Name] = [string]$q.Value }
    foreach ($key in $Thresholds.Keys) { $limits[$key] = [string]$Thresholds[$key] }
    $list = @($p.Suspensions); if ($null -ne $Suspensions) { $list = @($Suspensions) }
    $policy = New-DomeniaHealthEditorPolicy -Thresholds $limits -DisabledRules @($p.DisabledRules) -CustomRules @($p.CustomRules) -Suspensions $list -NowUtc $script:HrNow
    return Set-DomeniaHealthScopePolicy $Book $ScopeDn $policy -NowUtc $script:HrNow
}

Test-Case -Id 'HR-001' -Name 'Point 75 : contributions, population evaluable et consequences des regles desactivees ou suspendues' -Body {
    $suspension = [pscustomobject]@{ RuleId = 'stale'; Reason = 'Migration en cours'; UntilUtc = $script:HrNow.AddDays(1).ToString('o') }
    $policy = ConvertTo-DomeniaHealthPolicy @{ DisabledRules = @('disk.tight'); Suspensions = @($suspension) } -Strict
    $board = Get-DomeniaFleetBoardData -Result (New-HrSource) -Scope $script:HrScope -Now $script:HrNow -Lifecycle $script:HrLifecycle -HealthPolicy $policy
    Assert-Equal 'HR-1' ((@($board.Last.ProblemTargets) | ForEach-Object { $_.name }) -join ',') 'Seule une regle active compte dans le score'
    Assert-Equal 'HR-2,HR-4' ((@($board.Last.HealthyTargets) | ForEach-Object { $_.name } | Sort-Object) -join ',') 'Regle masquee sans effet sur le score'
    $low = Get-HrRow $board 'lowdisk'
    Assert-Equal 'Activée' ([string]$low.Status); Assert-Equal 1 ([int]$low.Machines); Assert-Equal 1 ([int]$low.Exclusive); Assert-Equal '3 / 4' ([string]$low.Eligible)
    $tight = Get-HrRow $board 'disk.tight'
    Assert-Equal 'Désactivée' ([string]$tight.Status); Assert-Equal 0 ([int]$tight.Machines); Assert-Equal 1 ([int]$tight.Masked)
    Assert-Equal '1 poste(s) seraient signalés si la règle était activée' ([string]$tight.Consequence)
    Assert-Equal '00000000-0000-0000-0001-000000000002' ([string]@($tight.MaskedGuids)[0])
    $stale = Get-HrRow $board 'stale'
    Assert-Equal 'Suspendue' ([string]$stale.Status); Assert-Equal '4 / 4' ([string]$stale.Eligible)
    Assert-True ([string]$stale.Effect -match '^Suspendue jusquʼau \d{2}/\d{2}/\d{4} \d{2}:\d{2} : Migration en cours$') ('Echeance et motif : ' + $stale.Effect)
    Assert-Equal '1 poste(s) seraient signalés pendant la suspension' ([string]$stale.Consequence)
    Assert-Equal 'Non mesuré sur le parc' ([string](Get-HrRow $board 'memory').Eligible)
    Assert-Equal 1 ([int]$board.HealthExplanation.SuspendedRules); Assert-Equal 2 ([int]$board.HealthExplanation.MaskedMachines)
    Assert-True ([string]$board.Entries['fleet.health'].Badge -match 'suspendue') 'Suspension visible sous le score'
    Assert-Equal 0 @($board.Attention | Where-Object { [string]$_.Point -in @('stale','disk.tight') }).Count 'Aucune alerte affichee pour une regle masquee'
}
Test-Case -Id 'HR-002' -Name 'Point 75 : un poste signale par deux regles n est le seul fait d aucune, les colonnes ne s additionnent pas' -Body {
    $custom = [pscustomobject]@{ Id = ('custom.' + ('b' * 32)); Name = 'Disque sous 10 %'; Measure = 'DiskFree'; Operator = 'LessThan'; Threshold = 10; Severity = 'Warn'; Enabled = $true }
    $board = Get-DomeniaFleetBoardData -Result (New-HrSource) -Scope $script:HrScope -Now $script:HrNow -Lifecycle $script:HrLifecycle -HealthPolicy (ConvertTo-DomeniaHealthPolicy @{ CustomRules = @($custom) } -Strict)
    $low = Get-HrRow $board 'lowdisk'; $mine = Get-HrRow $board $custom.Id
    Assert-Equal 1 ([int]$low.Machines); Assert-Equal 0 ([int]$low.Exclusive) 'Deux regles sur le meme poste'
    Assert-Equal 1 ([int]$mine.Machines); Assert-Equal 0 ([int]$mine.Exclusive); Assert-Equal '3 / 4' ([string]$mine.Eligible) 'Alerte disque evaluable sur les postes au disque lu'
    Assert-Equal 1 @($board.Last.ProblemTargets | Where-Object { $_.name -eq 'HR-1' }).Count 'Un poste compte une fois dans le score'
}
Test-Case -Id 'HR-003' -Name 'Point 75 : explication du poste, controle mesure ou non mesure, regle desactivee chiffree sans penalite' -Body {
    $data = New-DomeniaBoardData -Board Computer
    $data.HealthPolicy = ConvertTo-DomeniaHealthPolicy @{ DisabledRules = @('uptime') } -Strict
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'computer.uptime' -Kind Value -Value '45 j 2 h' -Detail '' -State Warn)
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'computer.os' -Kind Value -Value 'Windows 11 24H2' -Detail 'Build 26100 · date de fin inconnue')
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'computer.ad.account' -Kind Value -Value 'État inconnu' -State Off)
    Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'Pas de redemarrage depuis 45 jours.' -Point 'uptime'
    [void](Complete-DomeniaBoardData -Data $data)
    Assert-Equal 0 @($data.Attention).Count 'Regle desactivee absente des points'
    Assert-Equal 100 $data.Entries['computer.health'].Number 'Aucune penalite'
    $explanation = $data.HealthExplanation
    $uptime = @($explanation.Rows | Where-Object { $_.Id -eq 'uptime' })[0]
    Assert-Equal 'Mesuré' ([string]$uptime.Eligible); Assert-Equal 'Désactivée' ([string]$uptime.Status)
    Assert-Equal 'Signalerait ce poste si la règle était activée (−10 point(s))' ([string]$uptime.Consequence)
    Assert-Equal 'Non mesuré' ([string]@($explanation.Rows | Where-Object { $_.Id -eq 'eos.ended' })[0].Eligible) 'Date de fin inconnue'
    Assert-Equal 'Non mesuré' ([string]@($explanation.Rows | Where-Object { $_.Id -eq 'ad.disabled' })[0].Eligible) 'Etat AD inconnu'
    Assert-Equal 'Contrôle du parc' ([string]@($explanation.Rows | Where-Object { $_.Id -eq 'never' })[0].Eligible)
    Assert-Equal 1 ([int]$explanation.MaskedMachines)
}
Test-Case -Id 'HR-004' -Name 'Point 76 : origine de chaque reglage, exceptions locales visibles et portees de l editeur' -Body {
    $alpha = 'OU=Alpha,' + $script:HrScope; $sub = 'OU=Sub,' + $alpha
    $book = ConvertTo-DomeniaHealthPolicyBook @{ Default = (ConvertTo-DomeniaHealthPolicy) } $script:HrDomain
    $p = Resolve-DomeniaHealthPolicy $book $alpha; $p.Thresholds.StaleDays = 45; $p.DisabledRules = @('uptime'); $book = Set-DomeniaHealthScopePolicy $book $alpha $p
    $p = Resolve-DomeniaHealthPolicy $book $sub; $p.Thresholds.PasswordDays = 30; $book = Set-DomeniaHealthScopePolicy $book $sub $p
    $origins = @{}; foreach ($row in @(Get-DomeniaHealthPolicyOrigins -Book $book -ScopeDn $sub)) { $origins[$row.Kind + '|' + $row.Id] = $row }
    Assert-Equal 'Hérité de OU=Alpha,OU=Fleet' ([string]$origins['Seuil|StaleDays'].Origin); Assert-Equal '45' ([string]$origins['Seuil|StaleDays'].Value); Assert-False $origins['Seuil|StaleDays'].Local
    Assert-Equal 'Exception locale' ([string]$origins['Seuil|PasswordDays'].Origin); Assert-True $origins['Seuil|PasswordDays'].Local
    Assert-Equal 'Désactivé' ([string]$origins['Contrôle|uptime'].Value); Assert-Equal 'Hérité de OU=Alpha,OU=Fleet' ([string]$origins['Contrôle|uptime'].Origin)
    Assert-Equal 'Règles par défaut du domaine' ([string]$origins['Seuil|DiskFreeAlert'].Origin)
    Assert-Equal 'Règles par défaut du domaine' ([string]$origins['Liste|CustomRules'].Origin)
    $exceptions = @(Get-DomeniaHealthPolicyExceptions -Book $book -NowUtc $script:HrNow)
    Assert-Equal ($alpha + '|' + $sub) ((@($exceptions) | ForEach-Object { $_.ScopeDn }) -join '|') 'Exceptions de la plus haute a la plus basse'
    Assert-True ([string]$exceptions[0].Changes -match 'Connexion AD ancienne \(jours, date approximative\) : 45 \(hérité : 90\)') ('Seuil hors heritage : ' + $exceptions[0].Changes)
    Assert-True ([string]$exceptions[0].Changes -match 'Redémarrage ancien : désactivé') 'Regle desactivee localement'
    Assert-True ([string]$exceptions[1].Changes -match 'Mot de passe machine ancien \(jours\) : 30 \(hérité : 60\)') 'Exception de la sous-OU'
    $scopes = @(Get-DomeniaHealthEditorScopes -Book $book -CurrentDn $sub)
    Assert-Equal ('|' + $script:HrScope + '|' + $alpha + '|' + $sub) ((@($scopes) | ForEach-Object { $_.Dn }) -join '|') 'Domaine, OU parentes puis OU courante'
    Assert-Equal 'Domain,Ancestor,Ancestor,Current' ((@($scopes) | ForEach-Object { $_.Kind }) -join ',')
    $fromDomain = @(Get-DomeniaHealthEditorScopes -Book $book -CurrentDn '')
    Assert-Equal 'Domain,Exception,Exception' ((@($fromDomain) | ForEach-Object { $_.Kind }) -join ',') 'Exceptions existantes atteignables depuis le domaine'
    Assert-Throws { Get-DomeniaHealthPolicyOrigins -Book $book -ScopeDn 'OU=Ailleurs,DC=other,DC=invalid' } 'OU hors du domaine refusee'
}
Test-Case -Id 'HR-005' -Name 'Point 77 : suspension avec motif et echeance, reactivation, purge apres 30 jours, distincte d une suppression' -Body {
    $active = [pscustomobject]@{ RuleId = 'lowdisk'; Reason = 'Remplacement du disque'; UntilUtc = $script:HrNow.AddDays(2).ToString('o') }
    $recent = [pscustomobject]@{ RuleId = 'uptime'; Reason = 'Fenetre de maintenance'; UntilUtc = $script:HrNow.AddDays(-5).ToString('o') }
    $old = [pscustomobject]@{ RuleId = 'pwdold'; Reason = 'Ancienne campagne'; UntilUtc = $script:HrNow.AddDays(-45).ToString('o') }
    $kept = @(Optimize-DomeniaHealthSuspensions -Suspensions @($active, $recent, $old, $null, [pscustomobject]@{ RuleId = 'stale'; Reason = 'xxx'; UntilUtc = 'illisible' }) -NowUtc $script:HrNow)
    Assert-Equal 'lowdisk,uptime' ((@($kept) | ForEach-Object { $_.RuleId }) -join ',') 'Suspensions actives et recentes gardees'
    $policy = ConvertTo-DomeniaHealthPolicy @{ DisabledRules = @('pwdold'); Suspensions = @($active, $recent, ([pscustomobject]@{ RuleId = 'pwdold'; Reason = 'Double choix'; UntilUtc = $script:HrNow.AddDays(1).ToString('o') })); EvaluatedAtUtc = $script:HrNow.ToString('o') } -Strict
    Assert-Equal 'Suspended' (Get-DomeniaHealthRuleState $policy 'lowdisk')
    Assert-Equal 'On' (Get-DomeniaHealthRuleState $policy 'uptime') 'Reactivee a l echeance'
    Assert-Equal 'Disabled' (Get-DomeniaHealthRuleState $policy 'pwdold') 'La desactivation l emporte sur la suspension'
    Assert-True ((Format-DomeniaHealthSuspensionText $active) -match '^jusquʼau \d{2}/\d{2}/\d{4} \d{2}:\d{2} : Remplacement du disque$')
    $custom = [pscustomobject]@{ Id = ('custom.' + ('c' * 32)); Name = 'Disque'; Measure = 'DiskFree'; Operator = 'LessThan'; Threshold = 50; Severity = 'Warn'; Enabled = $true }
    $suspended = ConvertTo-DomeniaHealthPolicy @{ CustomRules = @($custom); Suspensions = @([pscustomobject]@{ RuleId = $custom.Id; Reason = 'Analyse en cours'; UntilUtc = $script:HrNow.AddDays(1).ToString('o') }); EvaluatedAtUtc = $script:HrNow.ToString('o') } -Strict
    Assert-Equal 1 @($suspended.CustomRules).Count 'Suspendre ne supprime pas la regle personnalisee'
    Assert-Equal 'Suspended' (Get-DomeniaHealthRuleState $suspended $custom.Id)
    Assert-Equal 'Disabled' (Get-DomeniaHealthRuleState (ConvertTo-DomeniaHealthPolicy @{ CustomRules = @() } -Strict) $custom.Id) 'Regle supprimee : plus rien a reactiver'
    $ended = ConvertTo-DomeniaEndedHealthSuspension -Suspension $active -NowUtc $script:HrNow
    Assert-Equal 'lowdisk' ([string]$ended.RuleId); Assert-Equal 'Remplacement du disque' ([string]$ended.Reason) 'Motif conserve a la reactivation'
    Assert-Equal $script:HrNow.ToString('o') ([string]$ended.UntilUtc) 'Reactiver maintenant termine la suspension a cet instant'
    $back = ConvertTo-DomeniaHealthPolicy @{ Suspensions = @($ended); EvaluatedAtUtc = $script:HrNow.ToString('o') } -Strict
    Assert-Equal 'On' (Get-DomeniaHealthRuleState $back 'lowdisk') 'Le controle compte de nouveau'
    Assert-Equal 1 @($back.Suspensions).Count 'La trace de la suspension reste dans la politique'
    Assert-Equal 1 @(Optimize-DomeniaHealthSuspensions -Suspensions @($ended) -NowUtc $script:HrNow.AddDays(29)).Count 'Trace gardee 30 jours'
    Assert-Equal 0 @(Optimize-DomeniaHealthSuspensions -Suspensions @($ended) -NowUtc $script:HrNow.AddDays(31)).Count 'Trace purgee ensuite'
    Assert-Equal ([string]$recent.UntilUtc) ([string](ConvertTo-DomeniaEndedHealthSuspension -Suspension $recent -NowUtc $script:HrNow).UntilUtc) 'Suspension deja terminee : echeance d origine'
    Assert-Throws { ConvertTo-DomeniaEndedHealthSuspension -Suspension $null -NowUtc $script:HrNow } 'Aucune suspension choisie'
}
Test-Case -Id 'HR-006' -Name 'Point 78 : changement reel, perimetre, couverture et regles distingues, ordre chronologique' -Body {
    $base = @{ Machines = 100; Assessed = 80; Unassessed = 20; Healthy = 60; Problems = 20; Score = 75; PingRead = 50; WmiRead = 80; PopulationHash = 'p'; AssessedHash = 'a'; CoverageHash = 'c'; PolicyHash = 'r'; ComputedUtc = '2026-10-01T08:00:00.0000000Z' }
    $reading = { param([hashtable]$Changes,[string]$Label = 'Second',[string]$At = '2026-10-02T08:00:00.0000000Z') $f = @{}; foreach ($k in $base.Keys) { $f[$k] = $base[$k] }; foreach ($k in $Changes.Keys) { $f[$k] = $Changes[$k] }; $f['ComputedUtc'] = $At; [pscustomobject]@{ Label = $Label; Day = $At.Substring(0, 10); Figures = [pscustomobject]$f } }
    $first = & $reading @{} 'Premier' '2026-10-01T08:00:00.0000000Z'
    $same = Compare-DomeniaHealthSnapshots $first (& $reading @{})
    Assert-Equal 'Stable' $same.Category; Assert-True $same.Comparable
    $real = Compare-DomeniaHealthSnapshots $first (& $reading @{ Healthy = 55; Problems = 25; Score = 68 })
    Assert-Equal 'Réel' $real.Category; Assert-True $real.Comparable
    Assert-Equal 'Avec un problème : 20 → 25 (+5) · sans problème détecté : 60 → 55 (-5) · score : 75 → 68 (-7)' ([string]@($real.Factors)[3].Text)
    $better = Compare-DomeniaHealthSnapshots $first (& $reading @{ Assessed = 90; Unassessed = 10; AssessedHash = 'a2'; CoverageHash = 'c2'; Healthy = 62; Problems = 28; Score = 68 })
    Assert-Equal 'Couverture' $better.Category; Assert-False $better.Comparable
    Assert-True ($better.Summary.StartsWith('Amélioration de la couverture')) $better.Summary
    Assert-Equal 'Postes évalués : 80 → 90 (+10) · part évaluée : 80 % → 90 % (+10 %) ; des postes jusque-là non mesurés entrent dans le score' ([string]@($better.Factors)[1].Text)
    $worse = Compare-DomeniaHealthSnapshots $first (& $reading @{ Assessed = 70; Unassessed = 30; AssessedHash = 'a3'; CoverageHash = 'c3' })
    Assert-True ($worse.Summary.StartsWith('Couverture réduite')) $worse.Summary
    Assert-Equal 'Périmètre' (Compare-DomeniaHealthSnapshots $first (& $reading @{ Machines = 104; PopulationHash = 'p2' })).Category
    $moved = Compare-DomeniaHealthSnapshots $first (& $reading @{ PopulationHash = 'p3' })
    Assert-True ([string]@($moved.Factors)[0].Text -match 'même nombre, composition différente') 'Entrees et sorties sans variation du nombre'
    Assert-Equal 'Règles' (Compare-DomeniaHealthSnapshots $first (& $reading @{ PolicyHash = 'r2' })).Category
    $mixed = Compare-DomeniaHealthSnapshots $first (& $reading @{ PolicyHash = 'r2'; PopulationHash = 'p2'; Machines = 90 })
    Assert-Equal 'Mixte' $mixed.Category; Assert-True ($mixed.Summary -match 'périmètre, règles') $mixed.Summary
    $legacy = Compare-DomeniaHealthSnapshots ([pscustomobject]@{ Label = 'Ancien'; Day = '2026-09-01'; Figures = [pscustomobject]@{ Machines = 100; Healthy = 60; Problems = 20 } }) $first
    Assert-Equal 'Limitée' $legacy.Category; Assert-True (@($legacy.Limits) -contains 'Le premier relevé ne conserve pas lʼempreinte de la population : comparaison limitée aux compteurs.') 'Releve ancien sans empreinte'
    $swapped = Compare-DomeniaHealthSnapshots (& $reading @{ Healthy = 55; Problems = 25 }) $first
    Assert-True $swapped.Swapped; Assert-Equal 'Premier' $swapped.BeforeLabel; Assert-True (@($swapped.Limits) -contains 'Relevés remis dans lʼordre chronologique.')
    Assert-Equal '+5' ([string]@($swapped.Rows | Where-Object { $_.Measure -eq 'Avec un problème' })[0].Delta) 'Variation dans le sens du temps'
}
Test-Case -Id 'HR-007' -Name 'Point 79 : matrice avec totaux coherents, ordre naturel des colonnes, filtre et colonnes regroupees' -Body {
    $cell = { param([string]$Row,[string]$Column,[string[]]$Ids) [pscustomobject]@{ Row = $Row; Column = $Column; Count = $Ids.Count; Targets = @($Ids | ForEach-Object { New-HrTarget $_ }) } }
    $table = [pscustomobject]@{ Rows = @((& $cell 'A' 'x' @('g1','g2')), (& $cell 'A' 'y' @('g3')), (& $cell 'B' 'x' @('g4')), (& $cell 'C' 'z' @('g5','g6','g7'))); Total = 7; ColumnOrder = @('z','y'); RowTitle = 'OU'; ColumnTitle = 'Version' }
    $m = ConvertTo-DomeniaPivotMatrix -Table $table
    Assert-Equal 'z,y,x' (@($m.Columns) -join ',') 'Ordre naturel puis taille'
    Assert-Equal 'A,B,C' ((@($m.Rows) | ForEach-Object { $_.Label }) -join ',')
    Assert-Equal '0,1,2' (@($m.Rows[0].Counts) -join ','); Assert-Equal '3,0,0' (@($m.Rows[2].Counts) -join ',')
    Assert-Equal '3,1,3' (@($m.ColumnTotals) -join ','); Assert-Equal 7 $m.GrandTotal
    $rowSum = 0; foreach ($row in @($m.Rows)) { $rowSum += $row.Total }; Assert-Equal 7 $rowSum 'Somme des lignes = total general'
    Assert-Equal 'g1,g2' ((@($m.Rows[0].Targets[2]) | ForEach-Object { $_.object_guid }) -join ',') 'Cellule ouvrant ses postes'
    Assert-Equal 3 @($m.ColumnTargets[0]).Count; Assert-Equal 3 @($m.Rows[0].AllTargets).Count
    $filtered = ConvertTo-DomeniaPivotMatrix -Table $table -Filter 'a'
    Assert-Equal 3 $filtered.GrandTotal; Assert-True $filtered.Filtered; Assert-Equal 7 $filtered.Total
    $folded = ConvertTo-DomeniaPivotMatrix -Table $table -MaxColumns 2
    Assert-Equal 'z,Autres colonnes (2)' (@($folded.Columns) -join ','); Assert-Equal 2 $folded.Folded
    Assert-Equal '0,3' (@($folded.Rows[0].Counts) -join ','); Assert-Equal 7 $folded.GrandTotal 'Aucune colonne perdue'
    $empty = ConvertTo-DomeniaPivotMatrix -Table ([pscustomobject]@{ Rows = @(); Total = 0 })
    Assert-Equal 0 @($empty.Columns).Count; Assert-Equal 0 $empty.GrandTotal
}
Test-Case -Id 'HR-008' -Name 'Point 79 : tableaux croises du parc, chaque matrice retrouve tous les comptes actives' -Body {
    $board = Get-DomeniaFleetBoardData -Result (New-HrSource) -Scope $script:HrScope -Now $script:HrNow -Lifecycle $script:HrLifecycle
    foreach ($key in @('OuWindows','ModelRam','SiteCoverage')) {
        $m = ConvertTo-DomeniaPivotMatrix -Table $board.Pivots[$key]
        Assert-Equal 4 $m.GrandTotal ('Total ' + $key)
        $columnSum = 0; foreach ($n in @($m.ColumnTotals)) { $columnSum += $n }; Assert-Equal 4 $columnSum ('Colonnes ' + $key)
        $ids = @{}; foreach ($row in @($m.Rows)) { foreach ($t in @($row.AllTargets)) { $ids[[string]$t.object_guid] = $true } }; Assert-Equal 4 $ids.Count ('Postes uniques ' + $key)
    }
    $ram = ConvertTo-DomeniaPivotMatrix -Table $board.Pivots['ModelRam']
    Assert-Equal '5 à 8 Go,RAM non lue' (@($ram.Columns) -join ',') 'Tranches de memoire dans leur ordre, inconnu en dernier'
    Assert-Equal 'Modèle' $ram.RowTitle
}
Test-Case -Id 'HR-009' -Name 'Point 77 : la purge des suspensions terminees ne cree pas d exception locale quand une OU est enregistree' -Body {
    $ou = 'OU=Compta,' + $script:HrScope
    $old = [pscustomobject]@{ RuleId = 'lowdisk'; Reason = 'Ancienne campagne'; UntilUtc = $script:HrNow.AddDays(-40).ToString('o') }
    $book = ConvertTo-DomeniaHealthPolicyBook @{ Default = @{ Suspensions = @($old) } } $script:HrDomain -Strict
    $inherited = Resolve-DomeniaHealthPolicy $book $ou
    Assert-Equal 1 @($inherited.Suspensions).Count 'Trace terminee heritee du domaine'
    Assert-Equal 0 @((New-DomeniaHealthEditorPolicy -Suspensions @($inherited.Suspensions) -NowUtc $script:HrNow).Suspensions).Count 'L editeur purge la trace terminee depuis 40 jours'
    Assert-Equal 0 @((Save-HrEditorScope $book $ou).Scopes).Count 'OU enregistree sans changement : aucune exception'
    $book = Save-HrEditorScope $book $ou @{ StaleDays = 45 }
    Assert-Equal 1 @($book.Scopes).Count 'Seule l OU modifiee porte une exception'
    $record = @($book.Scopes)[0]
    Assert-True ($null -eq $record.Overrides.Suspensions) 'La purge seule ne cree pas de liste de suspensions locale'
    Assert-Equal 'StaleDays' ((@($record.Overrides.Thresholds.PSObject.Properties) | ForEach-Object { $_.Name }) -join ',') 'Seul le seuil change devient une exception'
    $origins = @{}; foreach ($row in @(Get-DomeniaHealthPolicyOrigins -Book $book -ScopeDn $ou)) { $origins[$row.Kind + '|' + $row.Id] = $row }
    Assert-Equal 'Règles par défaut du domaine' ([string]$origins['Liste|Suspensions'].Origin) 'Suspensions toujours heritees'
    $fresh = [pscustomobject]@{ RuleId = 'stale'; Reason = 'Migration des comptes'; UntilUtc = $script:HrNow.AddDays(7).ToString('o') }
    $book = Save-HrEditorScope $book '' -Suspensions @(@((Resolve-DomeniaHealthPolicy $book '').Suspensions) + $fresh)
    $resolved = Resolve-DomeniaHealthPolicy $book $ou
    Assert-Equal 'stale' ((@($resolved.Suspensions) | ForEach-Object { $_.RuleId }) -join ',') 'La suspension ajoutee ensuite au domaine atteint l OU'
    Assert-True ($null -ne (Get-DomeniaHealthSuspension $resolved 'stale' -NowUtc $script:HrNow)) 'Suspension active dans l OU'
    Assert-Equal 45 ([int]$resolved.Thresholds.StaleDays) 'L exception de seuil reste'
    $ended = ConvertTo-DomeniaEndedHealthSuspension -Suspension @($resolved.Suspensions)[0] -NowUtc $script:HrNow
    $book = Save-HrEditorScope $book $ou -Suspensions @($ended)
    $record = @(@($book.Scopes) | Where-Object { [string]$_.ScopeDn -ieq $ou })[0]
    Assert-Equal 1 @($record.Overrides.Suspensions).Count 'Une reactivation propre a l OU reste une exception locale'
    Assert-True ($null -eq (Get-DomeniaHealthSuspension (Resolve-DomeniaHealthPolicy $book $ou) 'stale' -NowUtc $script:HrNow)) 'Le controle compte de nouveau dans l OU'
    Assert-True ($null -ne (Get-DomeniaHealthSuspension (Resolve-DomeniaHealthPolicy $book '') 'stale' -NowUtc $script:HrNow)) 'Le domaine garde sa suspension'
}

Test-Case -Id 'HR-DICT' -Name 'Les observations SQLite en dictionnaire generique gardent leurs valeurs et tableaux' -Body {
    $values=New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $values['Count']=0
    $values['Inventory']=[pscustomobject]@{Build='26100'}
    $items=[object[]]@(1,2,3);$values['Items']=$items
    Assert-Equal 0 (Get-DomeniaHealthValue $values 'Count' 99)
    Assert-Equal '26100' (Get-DomeniaHealthValue $values 'Inventory').Build
    Assert-Equal 'absent' (Get-DomeniaHealthValue $values 'Missing' 'absent')
    $actual=Get-DomeniaHealthValue $values 'Items' -NoEnumerate
    Assert-True ([object]::ReferenceEquals($items,$actual)) 'Le tableau doit rester le meme objet'
}
