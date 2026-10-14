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
}
