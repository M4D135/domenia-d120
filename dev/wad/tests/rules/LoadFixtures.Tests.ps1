# Points 122 et 125 : fixtures de charge generees et regles de stabilite (memoire, files bornees). Donnees fictives.
# Le fichier de fixtures n est pas charge par l application : il sert a Test-DomeniaLoadStability.ps1.
$script:LoadFixtureFile = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures') 'Domenia-LoadFixtures.ps1'
. $script:LoadFixtureFile

Test-Case 'P125' 'Charge : profils fermes, 10 000 postes minimum, charge decrite au-dela du nombre de postes' {
    $profiles = @(Get-DomeniaLoadProfiles -Computers 10000)
    Assert-Equal 'ColdStart,WarmCache,LargeHistory,HeavyInventory' (($profiles | ForEach-Object { [string]$_.Id }) -join ',')
    foreach ($p in $profiles) {
        Assert-Equal 10000 ([int]$p.Computers) $p.Id
        Assert-True ([string]$p.Description) ('Description absente : ' + $p.Id)
        Assert-True ([string]$p.Database -in @('Base','History','Heavy')) ('Base inconnue : ' + $p.Id)
    }
    $heavy = @($profiles | Where-Object { $_.Id -eq 'HeavyInventory' })[0]
    Assert-Equal 500 ([int]$heavy.HeavyComputers) '5 % de postes tres equipes'
    Assert-True ([int]$heavy.HeavyProbes -gt [int]$heavy.ProbesPerComputer) 'Sondes plus nombreuses sur les postes tres equipes'
    Assert-True ([int]$heavy.SoftwareRows -ge 1000) 'Liste logicielle longue'
    $history = @($profiles | Where-Object { $_.Id -eq 'LargeHistory' })[0]
    Assert-True (([int]$history.HistoryDays -ge 365) -and ([int]$history.Receipts -ge 10000)) 'Historique volumineux'
    Assert-Equal 20000 ([int]@(Get-DomeniaLoadProfiles -Computers 20000)[0].Computers) 'Qualification a 20 000 postes'
    Assert-Throws { Get-DomeniaLoadProfiles -Computers 5000 } 'Moins de 10 000 postes accepte'
}
Test-Case 'P125' 'Charge : generation deterministe et attentes calculees depuis les seules regles' {
    $a = Get-DomeniaLoadComputer -Index 26; $b = Get-DomeniaLoadComputer -Index 26
    Assert-Equal ($a | ConvertTo-Json -Compress) ($b | ConvertTo-Json -Compress) 'Meme index, meme poste'
    Assert-Equal 'PC-000026' $a.Name
    $g = [guid]::Empty
    Assert-True ([guid]::TryParse([string]$a.Guid,[ref]$g)) 'GUID genere invalide'
    Assert-True $a.Recreated 'n % 13 = 0 : objet recree'
    Assert-True (Get-DomeniaLoadComputer -Index 22).StaleInventory 'n % 11 = 0 : inventaire perime'
    Assert-False (Get-DomeniaLoadComputer -Index 70).Observed 'Poste desactive jamais observe'
    Assert-False (Get-DomeniaLoadComputer -Index 23).Heavy 'Profil standard sans poste tres equipe'
    Assert-True (Get-DomeniaLoadComputer -Index 23 -HeavyProfile).Heavy 'n % 20 = 3 : poste tres equipe'
    $e = Get-DomeniaLoadExpectations -Computers 100
    Assert-Equal 90 ([int]$e.Active); Assert-Equal 10 ([int]$e.Disabled); Assert-Equal 77 ([int]$e.Observed)
    Assert-Equal 63 ([int]$e.KnownInventory); Assert-Equal 37 ([int]$e.UnknownInventory); Assert-Equal 14 ([int]$e.LowRam)
    Assert-Equal 6 ([int]$e.Models['Model 0']) 'Repartition par modele'
    Assert-Equal 5 ([int](Get-DomeniaLoadExpectations -Computers 100 -HeavyProfile).Heavy)
}
Test-Case 'P125' 'Charge : lignes d index et observations lisibles par ConvertFrom-Json' {
    $now = [datetime]::SpecifyKind([datetime]'2026-10-15T08:00:00',[DateTimeKind]::Utc)
    $at = $now.ToString('o'); $stale = $now.AddDays(-40).ToString('o')
    $c = Get-DomeniaLoadComputer -Index 26
    $row = ConvertTo-DomeniaLoadIndexLine -Computer $c -At $at -NowUtc $now | ConvertFrom-Json
    Assert-Equal $c.Guid ([string]$row.Guid); Assert-Equal 'PC-000026$' ([string]$row.Login); Assert-Equal 'Actif' ([string]$row.State)
    Assert-Equal $c.Dn ([string]$row.DN); Assert-Equal 26 ([int]$row.Usn); Assert-True ([bool]$row.Facts)
    $obs = ConvertTo-DomeniaLoadObservationJson -Computer $c -At $at -StaleAt $stale -ProbeIds @('hw.maker','hw.model') | ConvertFrom-Json
    Assert-Equal 'recreated' ([string]$obs.Guid) 'Observation d un ancien GUID conservee comme telle'
    Assert-Equal 2 @($obs.Probes.PSObject.Properties).Count
    Assert-Equal '42' ([string]$obs.Probes.'hw.model'.Rows[0][0])
    Assert-Equal ([long]16 * 1073741824L) ([long]$obs.Inventory.RamBytes)
    $old = ConvertTo-DomeniaLoadObservationJson -Computer (Get-DomeniaLoadComputer -Index 22) -At $at -StaleAt $stale | ConvertFrom-Json
    Assert-Equal $stale ([string]$old.Inventory.CheckedUtc) 'Inventaire perime date de 40 jours'
    Assert-Equal 0 @($old.Probes.PSObject.Properties).Count
}
Test-Case 'P125' 'Charge : liste logicielle longue avec editeurs et tailles non renseignes' {
    $rows = New-DomeniaLoadSoftwareRows -Count 2500 -NowUtc ([datetime]::SpecifyKind([datetime]'2026-10-15T08:00:00',[DateTimeKind]::Utc))
    Assert-Equal 2500 $rows.Count
    Assert-True (@($rows | Where-Object { -not $_.Publisher }).Count -gt 0) 'Editeur non renseigne absent du jeu'
    Assert-True (@($rows | Where-Object { [int]$_.SizeKb -eq 0 }).Count -gt 0) 'Taille non renseignee absente du jeu'
    Assert-True (@($rows | Where-Object { -not $_.InstallDate }).Count -gt 0) 'Date absente du jeu'
}
Test-Case 'P125' 'Stabilite : memoire jugee apres le prechauffage, jamais validee sans deux cycles juges' {
    $ok = Test-DomeniaMemoryStabilized -SamplesMB ([double[]]@(100,140,145,150))
    Assert-True $ok.Stable; Assert-Equal 'Stable' $ok.Verdict; Assert-Equal 10 ([int]$ok.GrowthMB); Assert-Equal 32 ([int]$ok.LimitMB)
    $grow = Test-DomeniaMemoryStabilized -SamplesMB ([double[]]@(100,140,200,260))
    Assert-False $grow.Stable; Assert-Equal 'Growing' $grow.Verdict
    $short = Test-DomeniaMemoryStabilized -SamplesMB ([double[]]@(100,140))
    Assert-False $short.Stable 'Un seul cycle juge ne prouve rien'; Assert-Equal 'Insufficient' $short.Verdict
    Assert-Equal 'Invalid' (Test-DomeniaMemoryStabilized -SamplesMB ([double[]]@(100,[double]::NaN,120))).Verdict
    $large = Test-DomeniaMemoryStabilized -SamplesMB ([double[]]@(500,1000,1090))
    Assert-True $large.Stable 'Tolerance proportionnelle a la base'; Assert-Equal 100 ([int]$large.LimitMB)
}
Test-Case 'P125' 'Files bornees : une rafale de collectes de fond ne depasse jamais la file' {
    $burst = Measure-DomeniaLoadAdmissionBurst -Requests 2000
    Assert-True $burst.Bounded ('File non bornee : ' + ($burst | ConvertTo-Json -Compress))
    Assert-Equal 32 ([int]$burst.Queued); Assert-Equal 1968 ([int]$burst.Refused); Assert-Equal 0 ([int]$burst.Started)
}
