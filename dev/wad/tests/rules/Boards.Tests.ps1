# Tableaux de bord en widgets (decision David 2026-10-07) : catalogue, representations par type de donnee,
# tailles, disposition enregistree et migration des widgets de la premiere version. Regles pures, aucune interface.
. (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
. (Join-Path $modules 'Domenia-Boards.Model.ps1')

Test-Case 'BRD-001' 'Le catalogue de chaque tableau a des cles uniques, un type et une representation permise' {
    foreach ($board in @('Computer','Fleet','Software')) {
        $items = @(Get-DomeniaBoardCatalog -Board $board)
        Assert-True ($items.Count -ge 8) ('catalogue trop court : ' + $board)
        Assert-Equal $items.Count (@($items | ForEach-Object { $_.Key } | Sort-Object -Unique).Count) ('cles en double : ' + $board)
        foreach ($item in $items) {
            Assert-True ($item.Key -like (($board.ToLowerInvariant()) + '.*')) ('prefixe : ' + $item.Key)
            Assert-True ($item.Visual -in @(Get-DomeniaBoardVisuals -Kind $item.Kind -HasMaximum)) ('representation non permise : ' + $item.Key)
            Assert-True ($item.Size -in @('S','M','L')) ('taille : ' + $item.Key)
        }
    }
}
Test-Case 'BRD-002' 'Les representations dependent du type de donnee' {
    Assert-Equal 'Kpi,Text' (@(Get-DomeniaBoardVisuals -Kind Value) -join ',')
    Assert-False ('Gauge' -in @(Get-DomeniaBoardVisuals -Kind Number)) 'jauge sans maximum'
    Assert-True ('Gauge' -in @(Get-DomeniaBoardVisuals -Kind Number -HasMaximum)) 'jauge avec maximum'
    Assert-False ('Pie' -in @(Get-DomeniaBoardVisuals -Kind Measure)) 'anneau sur des mesures'
    # Lot L01 (FO-10): a curve only for dated values, never for buckets or shares.
    foreach ($kind in @('Distribution','Measure','Series','Value','Number')) { Assert-False ('Line' -in @(Get-DomeniaBoardVisuals -Kind $kind -HasMaximum)) ('courbe sur ' + $kind) }
    Assert-Equal 'Line' (@(Get-DomeniaBoardVisuals -Kind Timeline)[0])
    Assert-Equal 'Column' (Resolve-DomeniaBoardVisual -Visual 'Line' -Kind Series) 'courbe enregistree remplacee'
    Assert-Equal 'List' (@(Get-DomeniaBoardVisuals -Kind List) -join ',')
    Assert-Equal 'Kpi' (Resolve-DomeniaBoardVisual -Visual 'Pie' -Kind Value)
    Assert-Equal 'Bar' (Resolve-DomeniaBoardVisual -Visual 'Bar' -Kind Distribution)
}
Test-Case 'BRD-003' 'Deux tuiles compactes empilees s alignent sur une carte haute' {
    $kpi = Get-DomeniaBoardSize -Visual Kpi -Size S
    $pie = Get-DomeniaBoardSize -Visual Pie -Size M
    Assert-Equal ([double](2 * ($kpi.Height + 14))) ([double]($pie.Height + 14))
    Assert-Equal ([double]0) ([double](Get-DomeniaBoardSize -Visual List -Size L).Height) 'liste a hauteur libre'
}
Test-Case 'BRD-004' 'Sans reglage, la disposition livree contient le catalogue livre dans l ordre' {
    $layout = @(ConvertTo-DomeniaBoardLayout -Board Computer -Json '')
    Assert-Equal (@(Get-DomeniaBoardCatalog -Board Computer | Where-Object { $_.Default }).Count) $layout.Count
    Assert-Equal 'computer.health' ([string]$layout[0].Key)
    Assert-Equal 'Vue d ensemble' ([string]$layout[0].Group)
    # DS-05: the score and its points in one Santé card.
    Assert-Equal 'HealthSummary' ([string]$layout[0].Visual)
    # Lot L01: the home overview is delivered without the observation widgets nor any WMI query.
    $fleet = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json '')
    Assert-Equal 'fleet.health,fleet.machines,fleet.enabled,fleet.accountstatus,fleet.stale,fleet.disabled,fleet.created,fleet.pwdold,fleet.laps,fleet.bitlocker,fleet.versions,fleet.eos,fleet.win10,fleet.os,fleet.lastlogon,fleet.ou' (@($fleet | ForEach-Object { [string]$_.Key }) -join ',')
    Assert-Equal 'Santé' ([string]$fleet[0].Group)
    Assert-Equal 0 @($fleet | Where-Object { ([string]$_.Source -eq 'Probe') -or ([string]$_.Key -in @('fleet.presence','fleet.users','fleet.lastcheck','fleet.models','fleet.releases','fleet.ram','fleet.diskfree','fleet.lowdisk','fleet.uptime')) }).Count 'aucun widget d observation livre'
    Assert-True (@(Get-DomeniaBoardCatalog -Board Fleet | Where-Object { $_.Key -eq 'fleet.presence' }).Count -eq 1) 'widget d observation toujours au catalogue'
}
Test-Case 'BRD-005' 'Une disposition enregistree est relue, nettoyee et reecrite a l identique' {
    $json = '[{"Id":"a1","Source":"Builtin","Key":"computer.os","Visual":"Pie","Title":"","Size":"Z","Group":""},{"Id":"a1","Source":"Builtin","Key":"computer.inconnu","Visual":"Kpi"},{"Id":"b2","Source":"Builtin","Key":"computer.services","Visual":"Bar","Size":"L","Group":"Activite"}]'
    $layout = @(ConvertTo-DomeniaBoardLayout -Board Computer -Json $json)
    Assert-Equal 2 $layout.Count 'cle inconnue retiree'
    Assert-Equal 'Kpi' ([string]$layout[0].Visual) 'representation corrigee'
    Assert-Equal 'S' ([string]$layout[0].Size) 'taille corrigee'
    Assert-Equal 'Identite du poste' ([string]$layout[0].Group) 'section du catalogue'
    $again = @(ConvertTo-DomeniaBoardLayout -Board Computer -Json (ConvertTo-DomeniaBoardLayoutJson -Layout $layout))
    Assert-Equal (ConvertTo-DomeniaBoardLayoutJson -Layout $layout) (ConvertTo-DomeniaBoardLayoutJson -Layout $again)
    Assert-Equal 1 @(ConvertTo-DomeniaBoardLayout -Board Computer -Json '[{"Id":"x","Source":"Builtin","Key":"computer.os","Visual":"Kpi","Size":"S","Group":"G"}]').Count 'tableau JSON d un seul element'
    Assert-Equal 0 @(ConvertTo-DomeniaBoardLayout -Board Computer -Json '[]').Count 'tableau vide volontairement'
    Assert-Equal '[]' (ConvertTo-DomeniaBoardLayoutJson -Layout @())
    Assert-Equal (@(Get-DomeniaBoardDefaultLayout -Board Computer).Count) @(ConvertTo-DomeniaBoardLayout -Board Computer -Json 'pas du json').Count 'texte illisible : disposition livree'
}
Test-Case 'BRD-006' 'Les widgets de la premiere version rejoignent la disposition, dans la section de leur categorie' {
    $catalog = @([pscustomobject]@{ Id = 'net.dns'; Category = 'Reseau'; Name = 'Serveur DNS'; Mode = 'Value'; Transform = 'Text'; Visual = 'Text' })
    $legacy = @([pscustomobject]@{ Id = 'w1'; ProbeId = 'net.dns'; Visual = 'Pie'; Title = 'DNS' })
    $layout = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json '' -LegacyWidgets $legacy -ProbeCatalog $catalog)
    $probe = @($layout | Where-Object { $_.Source -eq 'Probe' })
    Assert-Equal 1 $probe.Count
    Assert-Equal 'Reseau' ([string]$probe[0].Group)
    Assert-Equal 'Pie' ([string]$probe[0].Visual)
    Assert-Equal 'p-w1' ([string]$probe[0].Id)
    $computer = @(ConvertTo-DomeniaBoardLayout -Board Computer -Json '' -LegacyWidgets $legacy -ProbeCatalog $catalog | Where-Object { $_.Source -eq 'Probe' })
    Assert-Equal 'Kpi' ([string]$computer[0].Visual) 'un seul poste : valeur'
}
Test-Case 'BRD-007' 'Ajouter, deplacer, modifier et retirer gardent les sections groupees' {
    $layout = @(
        New-DomeniaBoardItem -Source Builtin -Key 'a' -Visual Kpi -Size S -Group 'G1' -Id '1'
        New-DomeniaBoardItem -Source Builtin -Key 'b' -Visual Kpi -Size S -Group 'G1' -Id '2'
        New-DomeniaBoardItem -Source Builtin -Key 'c' -Visual Kpi -Size S -Group 'G2' -Id '3'
    )
    $added = @(Add-DomeniaBoardItem -Layout $layout -Item (New-DomeniaBoardItem -Source Builtin -Key 'd' -Visual Kpi -Group 'G1' -Id '4'))
    Assert-Equal '1,2,4,3' (@($added | ForEach-Object { $_.Id }) -join ',') 'fin de sa section'
    Assert-Equal '2,1,4,3' (@(Move-DomeniaBoardItem -Layout $added -Id '2' -Step First | ForEach-Object { $_.Id }) -join ',')
    Assert-Equal '1,4,2,3' (@(Move-DomeniaBoardItem -Layout $added -Id '2' -Step Forward | ForEach-Object { $_.Id }) -join ',')
    $moved = @(Move-DomeniaBoardItem -Layout $added -Id '1' -Before '3')
    Assert-Equal '2,4,1,3' (@($moved | ForEach-Object { $_.Id }) -join ',')
    Assert-Equal 'G2' ([string]@($moved | Where-Object { $_.Id -eq '1' })[0].Group) 'prend la section de la cible'
    $changed = @(Update-DomeniaBoardItem -Layout $added -Id '3' -Changes @{ Group = 'G1'; Size = 'M' })
    Assert-Equal '1,2,4,3' (@($changed | ForEach-Object { $_.Id }) -join ',')
    Assert-Equal 'M' ([string]@($changed | Where-Object { $_.Id -eq '3' })[0].Size)
    Assert-Equal '1,4,3' (@(Remove-DomeniaBoardItem -Layout $added -Id '2' | ForEach-Object { $_.Id }) -join ',')
    Assert-Equal 'G1,G2' (@(Get-DomeniaBoardGroups -Layout $added) -join ',')
    Assert-Equal '2,4,3,1' (@(Move-DomeniaBoardItem -Layout $added -Id '1' -Onto '3' | ForEach-Object { $_.Id }) -join ',') 'vers l avant : prend la place de la cible'
    Assert-Equal '1,3,2,4' (@(Move-DomeniaBoardItem -Layout $added -Id '3' -Onto '2' | ForEach-Object { $_.Id }) -join ',') 'vers l arriere : avant la cible'
    $mixed = @($added) + @(New-DomeniaBoardItem -Source Builtin -Key 'e' -Visual Kpi -Group 'g1' -Id '5')
    Assert-Equal 'G1,G2' (@(Get-DomeniaBoardGroups -Layout $mixed) -join ',') 'sections comparees sans la casse'
}
Test-Case 'BRD-008' 'Le score de sante et la liste des points se calculent sur toutes les verifications' {
    $data = New-DomeniaBoardData -Board Computer
    Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'Redemarrage en attente.'
    Add-DomeniaBoardAttention -Data $data -Level Alert -Text 'Disque presque plein.'
    Add-DomeniaBoardAttention -Data $data -Level Info -Text 'Information.'
    [void](Complete-DomeniaBoardData -Data $data)
    $health = $data.Entries['computer.health']
    Assert-Equal ([double]65) ([double]$health.Number)
    Assert-Equal 'Critique' ([string]$health.Value)
    Assert-Equal 'Alert' ([string]$health.State)
    $list = $data.Entries['computer.attention']
    Assert-Equal 'Alert' ([string]@($list.Items)[0].Level) 'le plus grave d abord'
    # DS-05: the information line is counted apart, never as a point to check.
    Assert-Equal ('2 points ' + [char]0x00E0 + ' v' + [char]0x00E9 + 'rifier ' + [char]0x00B7 + ' 1 information') ([string]$list.Title)
    Assert-Equal ([string]$list.Title) ([string]$health.PointsTitle) 'meme titre sur la carte Sante'
    Assert-Equal 'Alert,Warn,Info' (@($health.Points | ForEach-Object { [string]$_.Level }) -join ',') 'points de la carte Sante, le plus grave d abord'
    $calm = New-DomeniaBoardData -Board Fleet
    [void](Complete-DomeniaBoardData -Data $calm)
    Assert-Equal ('Rien ' + [char]0x00E0 + ' signaler') ([string]$calm.Entries['fleet.attention'].Title)
    Assert-Equal 0 @($calm.Entries['fleet.health'].Points).Count
    Assert-Equal ([double]100) ([double]$calm.Entries['fleet.health'].Number)
}
Test-Case 'BRD-009' 'Une requete mesuree devient une valeur pour un poste, une repartition ou une mesure pour le parc' {
    $text = [pscustomobject]@{ Id = 'os.release'; Category = 'Systeme'; Name = 'Version'; Mode = 'Value'; Transform = 'Release'; Visual = 'Pie' }
    $numeric = [pscustomobject]@{ Id = 'disk.free'; Category = 'Disques'; Name = 'Libre sur C:'; Mode = 'Value'; Transform = 'PercentFree'; Visual = 'Column' }
    $measured = [pscustomobject]@{ Machines = 3; Items = @([pscustomobject]@{ Label = '24H2'; Value = 2 }, [pscustomobject]@{ Label = '23H2'; Value = 1 }); Summary = ''; Numeric = $false; Values = @('24H2','24H2','23H2') }
    $fleet = ConvertFrom-DomeniaProbeMeasure -Probe $text -Measured $measured -Board Fleet
    Assert-Equal 'Distribution' ([string]$fleet.Kind)
    Assert-Equal '24H2' ([string]$fleet.Value)
    Assert-Equal 'Value' ([string](ConvertFrom-DomeniaProbeMeasure -Probe $text -Measured $measured -Board Computer).Kind)
    $values = [pscustomobject]@{ Machines = 2; Items = @([pscustomobject]@{ Label = '40'; Value = 1 }, [pscustomobject]@{ Label = '60'; Value = 1 }); Summary = ''; Numeric = $true; Values = @('40','60') }
    $measure = ConvertFrom-DomeniaProbeMeasure -Probe $numeric -Measured $values -Board Fleet
    Assert-Equal 'Measure' ([string]$measure.Kind)
    Assert-True ([string]$measure.Value -like '50*%') ('moyenne : ' + [string]$measure.Value)
    Assert-Equal 'Off' ([string](ConvertFrom-DomeniaProbeMeasure -Probe $numeric -Measured $null -Board Fleet).State) 'en attente'
}
Test-Case 'BRD-011' 'Recherche sans accents et requetes comptees en mots' {
    Assert-Equal 'memoire installee' (ConvertTo-DomeniaSearchText ('M' + [char]0x00C9 + 'moire install' + [char]0x00E9 + 'e'))
    Assert-Equal 'Distribution' (Get-DomeniaProbeKind -Probe ([pscustomobject]@{ Mode = 'Count'; Transform = 'Map:0=Non;1=Oui' }))
    Assert-Equal 'Measure' (Get-DomeniaProbeKind -Probe ([pscustomobject]@{ Mode = 'Count'; Transform = 'Number' }))
    $ram = [pscustomobject]@{ Id = 'hw.ram'; Category = 'Materiel'; Name = 'Memoire'; Mode = 'First'; Transform = 'GB'; Visual = 'Column' }
    $one = [pscustomobject]@{ Machines = 1; Items = @([pscustomobject]@{ Label = '<= 4'; Value = 1 }, [pscustomobject]@{ Label = '4-8'; Value = 0 }); Summary = ''; Numeric = $true; Values = @(2.9) }
    Assert-Equal '2,9 Go' ([string](ConvertFrom-DomeniaProbeMeasure -Probe $ram -Measured $one -Board Computer).Value) 'un poste : sa valeur, pas sa tranche'
}
Test-Case 'BRD-010' 'Version commerciale de Windows et taille lisible' {
    Assert-Equal 'Windows 11 24H2' ([string](Get-DomeniaWindowsRelease '26100').Name)
    # Lot L01 (FO-08): end of service from the delivered table only; without it the date is unknown.
    Assert-True ([string](Get-DomeniaWindowsRelease '19045').Note -like '*date de fin inconnue') ([string](Get-DomeniaWindowsRelease '19045').Note)
    $table = [pscustomobject]@{ Entries = @([pscustomobject]@{ Build = '19045'; Family = 'Pro'; Name = 'Windows 10 22H2'; End = '2025-10-14' }) }
    $ended = Get-DomeniaWindowsRelease -Build '19045' -Caption 'Windows 10 Pro' -Lifecycle $table -Now ([datetime]'2026-10-08')
    Assert-Equal 'Ended' ([string]$ended.Status)
    Assert-True ([string]$ended.Note -like 'Fin de service le 14/10/2025*') ([string]$ended.Note)
    Assert-Equal '19045' (ConvertFrom-DomeniaOsVersion '10.0 (19045)')
    Assert-Equal '22631' (ConvertFrom-DomeniaOsVersion '10.0.22631')
    Assert-Equal '' ([string](Get-DomeniaWindowsRelease '12345').Name)
    Assert-Equal 'Windows Server 2025' ([string](Get-DomeniaWindowsRelease -Build '26100' -Caption 'Microsoft Windows Server 2025 Datacenter Evaluation').Name) 'serveur au meme build que Windows 11'
    Assert-Equal 'Windows 11 24H2' ([string](Get-DomeniaWindowsRelease -Build '26100' -Caption 'Microsoft Windows 11 Entreprise').Name)
    Assert-True ((Format-DomeniaDashboardSize (8GB)) -like '8*Go')
}
Test-Case 'BRD-012' 'Score du parc proportionnel : 22 sur 26 et paliers' {
    $warn = @([pscustomobject]@{ Level = 'Warn'; Text = 'x' })
    $h = Get-DomeniaFleetHealth -Total 26 -Healthy 22 -Attention $warn
    Assert-Equal 84 $h.Score; Assert-Equal 'À surveiller' $h.Verdict; Assert-Equal 'Warn' $h.State
    Assert-Equal '22 postes sur 26 évalués sans point détecté · 0 non évalué(s)' $h.Detail
    Assert-Equal 'Bon état' (Get-DomeniaFleetHealth -Total 10 -Healthy 9 -Attention $warn).Verdict
    Assert-Equal 'Dégradé' (Get-DomeniaFleetHealth -Total 4 -Healthy 2 -Attention $warn).Verdict
    Assert-Equal 'Alert' (Get-DomeniaFleetHealth -Total 4 -Healthy 2 -Attention $warn).State
    $critical = Get-DomeniaFleetHealth -Total 2000 -Healthy 1999 -Attention @([pscustomobject]@{ Level = 'Alert'; Text = 'x' })
    Assert-Equal 99 $critical.Score 'Un poste sur 2000 ne fait pas tomber le score'
    Assert-Equal 'Critique' $critical.Verdict
    Assert-Equal 'Aucun poste évalué' (Get-DomeniaFleetHealth -Total 0 -Healthy 0).Verdict
    $data = New-DomeniaBoardData -Board Fleet
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Population' -Value ([pscustomobject]@{ Total = 26; Healthy = 22 })
    Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'Quatre postes inactifs.'
    [void](Complete-DomeniaBoardData -Data $data)
    Assert-Equal 84 $data.Entries['fleet.health'].Number
    Assert-Equal '22 postes sur 26 évalués sans point détecté · 0 non évalué(s)' ([string]$data.Entries['fleet.health'].Detail)
}
Test-Case 'BRD-013' 'Ancienne disposition livree du parc migree, disposition personnalisee conservee' {
    $old = @(foreach ($line in ([string]$script:DomeniaFleetLegacyLayoutText -split "`n")) { $text = $line.Trim(); if ($text) { $c = $text -split '\|'; [pscustomobject]@{ Id = ('b-' + $c[0]); Source = 'Builtin'; Key = $c[0]; Visual = $c[2]; Title = ''; Size = $c[3]; Group = $c[1] } } })
    Assert-Equal 17 $old.Count
    $json = ConvertTo-Json -InputObject $old -Depth 3 -Compress
    $migrated = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json $json)
    Assert-Equal (@(Get-DomeniaBoardDefaultLayout -Board Fleet | ForEach-Object { $_.Key }) -join ',') (@($migrated | ForEach-Object { $_.Key }) -join ',') 'ancienne disposition livree remplacee'
    $renamed = @($old | ForEach-Object { $_.PSObject.Copy() }); $renamed[0].Id = 'x1'
    Assert-Equal 'fleet.health,fleet.machines,fleet.enabled' ((@(ConvertTo-DomeniaBoardLayout -Board Fleet -Json (ConvertTo-Json -InputObject $renamed -Depth 3 -Compress)) | Select-Object -First 3 | ForEach-Object { $_.Key }) -join ',') 'identifiants seuls differents : migree'
    $custom = @($old | Where-Object { $_.Key -ne 'fleet.users' })
    $kept = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json (ConvertTo-Json -InputObject $custom -Depth 3 -Compress))
    Assert-Equal 16 $kept.Count 'disposition personnalisee conservee'
    Assert-True (@($kept | Where-Object { $_.Key -eq 'fleet.presence' -and $_.Group -eq 'Repartition' }).Count -eq 1) 'widget d observation garde dans sa section'
    $titled = @($old | ForEach-Object { $_.PSObject.Copy() }); $titled[3].Title = 'Mes inactifs'
    Assert-Equal 17 @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json (ConvertTo-Json -InputObject $titled -Depth 3 -Compress)).Count 'titre change : conservee'
}

# ---------------------------------------------------------------------------------------------------------------------
# Lot L06 (TE-07) : tableau du poste, seuils partages, verdicts et graduations. Le fournisseur du poste
# (Domenia-BoardComputer.UI.ps1, sans WPF) lit l inventaire par deux aides de Domenia-Dashboard.UI.ps1 : seules ces
# deux fonctions en sont lues, par l AST, sans rien charger de l interface.
# ---------------------------------------------------------------------------------------------------------------------
. (Join-Path $modules 'Domenia-BoardComputer.UI.ps1')
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
. (Join-Path $modules 'Domenia-Readings.Model.ps1')
# The catalog cache of Probes.Model starts empty (StrictMode of this runner: the variable must exist).
$script:DomeniaProbeCatalog = $null
$script:BrdDashboardAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $modules 'Domenia-Dashboard.UI.ps1'), [ref]$null, [ref]$null)
foreach ($script:BrdName in @('Get-DomeniaInventoryValue','Get-DomeniaCategorySummary','Get-DomeniaEntryFileTimeUtc')) {
    $script:BrdNode = @($script:BrdDashboardAst.FindAll({ param($n) ($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $script:BrdName) }, $true))[0]
    . ([scriptblock]::Create($script:BrdNode.Extent.Text))
}
# Directory entry read by the object card (core function): a plain table of attributes in these tests.
function Get-DomeniaEntryFirstString { param($Entry,[string]$Name) if (($Entry -is [hashtable]) -and $Entry.ContainsKey($Name)) { return [string]$Entry[$Name] }; return '' }
function New-BrdRow { param([string]$Category,[string]$Item,[string]$Value) return [pscustomobject]@{ Category = $Category; Item = $Item; Value = $Value; Source = 'test' } }
function New-BrdInventory {
    # Inventory result shaped like the ComputerInventory worker (rows and CIM measures), fictitious values only.
    param([object[]]$Rows = @(),[double]$FreePercent = 50,[double]$MemoryUsedPercent = 40,$ClockSkew = $null,[string]$ClockReference = '',[double]$Battery = -1)
    $metrics = [pscustomobject]@{ MemoryTotal = [double]16GB; MemoryFree = [double](16GB * (100 - $MemoryUsedPercent) / 100); LastBoot = ''; CpuLoad = 35.0; Battery = $Battery; ClockSkewSeconds = $ClockSkew; ClockReference = $ClockReference
        Disks = @([pscustomobject]@{ Name = 'C:'; Size = [double]100GB; Free = [double](100GB * $FreePercent / 100) }); Hotfixes = @(); Processes = @(); Services = @{ 'En cours' = 100; 'Arretes (automatiques)' = 2; 'Arretes (manuels)' = 50; 'Desactives' = 5 } }
    return [pscustomobject]@{ Rows = @($Rows); Metrics = $metrics }
}
function Get-BrdTexts { param($Data) return @(@($Data.Attention) | ForEach-Object { [string]$_.Level + ':' + [string]$_.Text }) }
function Get-BrdSecureRows {
    # A security reading that raises nothing: firewall forced by the policy, BitLocker on, antivirus declared.
    return @((New-BrdRow 'Pare-feu' 'Profil domaine' 'Active (strategie)'), (New-BrdRow 'Pare-feu' 'Profil prive' 'Active (strategie)'), (New-BrdRow 'Pare-feu' 'Profil public' 'Active (strategie)'), (New-BrdRow 'BitLocker' 'Volume C:' 'Protection Active'), (New-BrdRow 'Antivirus' 'Defender' 'Actif, A jour'))
}

Test-Case 'BRD-014' 'TE-07 : un seul point a surveiller donne le verdict A surveiller, de la couleur de son etat' {
    $one = Get-DomeniaBoardHealth -Attention @([pscustomobject]@{ Level = 'Warn'; Text = 'x' })
    Assert-Equal 90 $one.Score
    Assert-Equal ([string][char]0x00C0 + ' surveiller') $one.Verdict 'verdict tire de l etat, jamais Bon etat en orange'
    Assert-Equal 'Warn' $one.State
    Assert-Equal ('Bon ' + [char]0x00E9 + 'tat') (Get-DomeniaBoardHealth -Attention @([pscustomobject]@{ Level = 'Info'; Text = 'i' })).Verdict 'une information ne compte pas'
    Assert-Equal 'Ok' (Get-DomeniaBoardHealth).State
    Assert-Equal 'Critique' (Get-DomeniaBoardHealth -Attention @([pscustomobject]@{ Level = 'Alert'; Text = 'a' })).Verdict
    $many = Get-DomeniaBoardHealth -Attention @(1..5 | ForEach-Object { [pscustomobject]@{ Level = 'Warn'; Text = 'w' } })
    Assert-Equal ('D' + [char]0x00E9 + 'grad' + [char]0x00E9) $many.Verdict 'score sous 60'
    Assert-Equal 'Alert' $many.State
    $data = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -FreePercent 13)
    $health = $data.Entries['computer.health']
    Assert-Equal 'Warn' ([string]$health.State)
    Assert-Equal ([string][char]0x00C0 + ' surveiller') ([string]$health.Value) 'poste avec un seul point : verdict et couleur concordent'
}
Test-Case 'BRD-015' 'TE-07 : libelle du disque Peu d espace sur C: (13 % libre), sans double deux-points' {
    $data = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -FreePercent 13)
    $texts = Get-BrdTexts $data
    Assert-True ($texts -contains ('Warn:Peu d' + [char]0x02BC + 'espace sur C: (13 % libre).')) ($texts -join ' | ')
    Assert-Equal 0 @($texts | Where-Object { $_ -like '*: :*' }).Count 'double deux-points'
    $full = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -FreePercent 8)
    Assert-True ((Get-BrdTexts $full) -contains 'Alert:C: presque plein (8 % libre).') ((Get-BrdTexts $full) -join ' | ')
    Assert-Equal 'Alert' ([string]$full.Entries['computer.disk.system'].State)
}
Test-Case 'BRD-016' 'TE-07 : seuils partages par la jauge, la tuile et l alerte, sur le poste et le parc' {
    $limits = Get-DomeniaBoardThresholds
    Assert-Equal 'Warn' (Get-DomeniaThresholdState -Measure DiskFree -Percent ($limits.DiskFreeWarn - 1))
    Assert-Equal 'Alert' (Get-DomeniaThresholdState -Measure DiskFree -Percent ($limits.DiskFreeAlert - 1))
    Assert-Equal 'Ok' (Get-DomeniaThresholdState -Measure DiskFree -Percent $limits.DiskFreeWarn)
    # Memory used between 81 and 90 %: no point, so no orange ring either; past 90 %: the point and the Warn state.
    $calm = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -MemoryUsedPercent 85)
    Assert-Equal '' ([string]$calm.Entries['computer.memory.usage'].State) 'jauge sans couleur sans point'
    Assert-Equal 0 @(Get-BrdTexts $calm | Where-Object { $_ -like '*moire*' }).Count
    $busy = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -MemoryUsedPercent 95)
    Assert-Equal 'Warn' ([string]$busy.Entries['computer.memory.usage'].State)
    Assert-Equal 1 @(Get-BrdTexts $busy | Where-Object { $_ -like 'Warn:M*moire utilis*' }).Count
    $battery = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -Battery 12)
    Assert-Equal 'Warn' ([string]$battery.Entries['computer.battery'].State)
    # The ring of free space takes the colour of the same state.
    $disk = (Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -FreePercent 13)).Entries['computer.disk.system']
    Assert-Equal (Get-DomeniaBoardColor 'Warn') ([string]@($disk.Items)[1].Color)
}
Test-Case 'BRD-017' 'TE-07 : pare-feu, etat effectif par profil, la strategie prime sur la cle locale' {
    # Older rows: policy key 1 and local key 0 on the domain profile, no false alert.
    $old = @((New-BrdRow 'Pare-feu' 'Profil domaine (strategie)' 'Active'), (New-BrdRow 'Pare-feu' 'Profil prive (strategie)' 'Active'), (New-BrdRow 'Pare-feu' 'Profil public (strategie)' 'Active'), (New-BrdRow 'Pare-feu' 'Profil domaine' 'Desactive'), (New-BrdRow 'Pare-feu' 'Profil prive' 'Desactive'), (New-BrdRow 'Pare-feu' 'Profil public' 'Active'))
    $data = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows $old)
    $entry = $data.Entries['computer.firewall']
    Assert-Equal ('3 profils sur 3 actifs (strat' + [char]0x00E9 + 'gie)') ([string]$entry.Value)
    Assert-Equal 'Ok' ([string]$entry.State)
    Assert-Equal 0 @(Get-BrdTexts $data | Where-Object { $_ -like '*Pare-feu*' }).Count 'cle locale a 0 sous une strategie a 1 : aucune alerte'
    # Current rows of the worker, one per profile.
    $current = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows @((New-BrdRow 'Pare-feu' 'Profil domaine' 'Active (strategie)'), (New-BrdRow 'Pare-feu' 'Profil prive' 'Active (local)'), (New-BrdRow 'Pare-feu' 'Profil public' 'Desactive (local)')))
    Assert-Equal '2 profils sur 3 actifs' ([string]$current.Entries['computer.firewall'].Value)
    Assert-True ((Get-BrdTexts $current) -contains ('Warn:Pare-feu d' + [char]0x00E9 + 'sactiv' + [char]0x00E9 + ' : Public.')) ((Get-BrdTexts $current) -join ' | ')
    # Values are compared exactly: an unknown word is not counted as an active profile.
    $odd = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows @((New-BrdRow 'Pare-feu' 'Profil domaine' 'Inconnu'), (New-BrdRow 'Pare-feu' 'Profil prive' 'Active (local)')))
    Assert-Equal '1 profil sur 1 actif (local)' ([string]$odd.Entries['computer.firewall'].Value)
}
Test-Case 'BRD-018' 'UX-23 : score partiel sans lecture de la securite, badge et bouton Inventaire complet' {
    $partial = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows @())
    $health = $partial.Entries['computer.health']
    Assert-Equal 'Partiel : antivirus, pare-feu ou BitLocker non lu' ([string]$health.Badge)
    Assert-Equal 'InventoryFull' ([string]$health.Action.Id) 'inventaire complet propose, lance seulement au clic'
    $read = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows))
    Assert-Equal '' ([string]$read.Entries['computer.health'].Badge)
    Assert-True ($null -eq $read.Entries['computer.health'].Action) 'pas de bouton quand la securite est lue'
    # SP-17: an empty section offers the existing action that fills it, never run by the rule.
    $task = Get-DomeniaComputerBoardData -Result ([pscustomobject]@{ Rows = @(Get-BrdSecureRows); Metrics = $null })
    Assert-True ($task.HintActions.ContainsKey('Activite')) 'section Activite vide sans action'
    Assert-Equal 'InventoryFull' ([string]$task.HintActions['Activite'].Id)
    Assert-Equal 'OpenCard' ([string]$task.HintActions['Compte machine dans Active Directory'].Id)
    Assert-False ($task.HintActions.ContainsKey('Ressources')) 'mesures indisponibles : aucun bouton qui ne les donnerait pas'
    Assert-False ($read.HintActions.ContainsKey('Activite')) 'section remplie : aucun bouton'
    $none = Get-DomeniaComputerBoardData
    Assert-Equal 'InventoryQuick' ([string]$none.HintActions['Identite du poste'].Id)
}
Test-Case 'BRD-019' 'MO-06 : erreurs connues ignorees, disque NTFS et Kernel-Power 41 a surveiller, services sur declencheur' {
    $rows = @(Get-BrdSecureRows) + @(
        (New-BrdRow 'Evenements systeme' 'DCOM ID 10016' '01/10/2026 : autorisation'),
        (New-BrdRow 'Evenements systeme' 'disk ID 7' '01/10/2026 : bloc defectueux'),
        (New-BrdRow 'Evenements systeme' 'Microsoft-Windows-Kernel-Power ID 41' '02/10/2026 : arret inattendu'),
        (New-BrdRow 'Evenements systeme' 'Service Control Manager ID 7000' '02/10/2026 : service'),
        (New-BrdRow 'Services en defaut' 'Google Update' 'Demarrage automatique mais arrete. Nom : gupdate'),
        (New-BrdRow 'Services en defaut' 'Optimisation .NET' 'Demarrage automatique mais arrete. Nom : clr_optimization_v4.0.30319_64'),
        (New-BrdRow 'Services en defaut' 'Spouleur' 'Demarrage automatique mais arrete. Nom : Spooler'))
    $data = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows $rows)
    $texts = Get-BrdTexts $data
    Assert-True (@($texts | Where-Object { $_ -like 'Warn:2 erreur(s) critique(s)*' }).Count -eq 1) ($texts -join ' | ')
    Assert-True (@($texts | Where-Object { $_ -like 'Info:1 autre(s) erreur(s)*' }).Count -eq 1) ($texts -join ' | ')
    $events = $data.Entries['computer.events']
    Assert-Equal 3 @($events.Items).Count 'DCOM 10016 ignore'
    Assert-Equal 'Warn' ([string]$events.State)
    Assert-Equal '1' ([string]$data.Entries['computer.services.stopped'].Value) 'services sur declencheur ou differes ignores'
    Assert-True (@($texts | Where-Object { $_ -like 'Warn:1 service(s) automatique(s)*' }).Count -eq 1) ($texts -join ' | ')
    Assert-Equal 'Ignore' (Get-DomeniaSystemEventLevel -Source 'DCOM' -EventId '10016')
    Assert-Equal 'Info' (Get-DomeniaSystemEventLevel -Source 'Microsoft-Windows-Kernel-Power' -EventId '42')
    Assert-Equal 'Warn' (Get-DomeniaSystemEventLevel -Source 'Ntfs' -EventId '55')
    Assert-True (Test-DomeniaServiceStopExpected -Name 'OneSyncSvc_1a2b3') 'service par utilisateur'
    Assert-False (Test-DomeniaServiceStopExpected -Name 'Spooler')
    $quiet = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (@(Get-BrdSecureRows) + @(New-BrdRow 'Evenements systeme' 'DCOM ID 10016' 'x')))
    Assert-Equal 'Ok' ([string]$quiet.Entries['computer.events'].State) 'seulement du bruit connu'
    Assert-Equal ('Bon ' + [char]0x00E9 + 'tat') ([string]$quiet.Entries['computer.health'].Value)
}
Test-Case 'BRD-020' 'CO-09 : horloge comparee au controleur, libelles du compte machine' {
    $object = [pscustomobject]@{ Entry = @{ userAccountControl = '4096'; whenCreated = '2020-01-15T10:00:00Z' }; DN = 'CN=PC-1,OU=Postes,DC=example,DC=test' }
    $dc = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -ClockSkew 14 -ClockReference 'Controleur') -Object $object
    Assert-Equal ([string][char]0x00C9 + 'cart avec le contr' + [char]0x00F4 + 'leur de domaine') ([string]$dc.Entries['computer.ad.clock'].Detail)
    Assert-Equal '+14 s' ([string]$dc.Entries['computer.ad.clock'].Value)
    $late = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -ClockSkew 400 -ClockReference 'Controleur') -Object $object
    Assert-True (@(Get-BrdTexts $late | Where-Object { $_ -like 'Alert:Horloge d*cal*e de 400 s par rapport au contr*leur*Kerberos*' }).Count -eq 1) ((Get-BrdTexts $late) -join ' | ')
    $admin = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -ClockSkew 0) -Object $object
    Assert-Equal ([string][char]0x00C0 + ' l' + [char]0x02BC + 'heure') ([string]$admin.Entries['computer.ad.clock'].Value)
    Assert-Equal 'Activé' ([string]$admin.Entries['computer.ad.account'].Value)
    Assert-True ([string]$admin.Entries['computer.ad.clock'].Detail -like '*poste d*administration (contr*leur non lu)') ([string]$admin.Entries['computer.ad.clock'].Detail)
    $localLate = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -ClockSkew 400 -ClockReference 'Poste') -Object $object
    Assert-Equal 'Warn' ([string]$localLate.Entries['computer.ad.clock'].State) 'local comparison cannot establish domain authentication failure'
    Assert-True ([string]$localLate.Entries['computer.ad.clock'].Detail -like '*poste d*administration (contr*leur non lu)')
    Assert-False (@(Get-BrdTexts $localLate | Where-Object { $_ -like 'Alert:Horloge*' }).Count -gt 0) 'no domain-clock critical alert without controller comparison'

}
Test-Case 'BRD-021' 'CO-16 : graduations 1, 2 ou 5 x 10^n, entieres pour les comptes' {
    Assert-Equal '0,1,2' ((Get-DomeniaChartTicks -Maximum 1.5 -Integer).Ticks -join ',') 'jamais 1,5 poste'
    Assert-Equal '0,10,20,30,40' ((Get-DomeniaChartTicks -Maximum 37 -Integer).Ticks -join ',')
    Assert-Equal 2 (Get-DomeniaChartTicks -Maximum 7 -Integer).Step
    Assert-Equal 8 (Get-DomeniaChartTicks -Maximum 7 -Integer).Top
    Assert-Equal 50 (Get-DomeniaChartTicks -Maximum 100).Step
    Assert-Equal 0.5 (Get-DomeniaChartTicks -Maximum 1.5).Step 'demi-graduation seulement hors comptes'
    foreach ($max in @(1, 3, 7, 12, 37, 99, 101, 250, 999, 1234, 0.37)) {
        $scale = Get-DomeniaChartTicks -Maximum $max -Integer
        Assert-True ($scale.Top -ge $max) ('sommet sous le maximum : ' + $max)
        $mantissa = [double]$scale.Step / [Math]::Pow(10, [Math]::Floor([Math]::Log10([double]$scale.Step)))
        Assert-True ([Math]::Round($mantissa, 6) -in @(1.0, 2.0, 5.0)) ('pas non arrondi : ' + $scale.Step + ' pour ' + $max)
        Assert-True ([double]$scale.Step -eq [Math]::Floor([double]$scale.Step)) ('pas non entier : ' + $max)
        Assert-True (@($scale.Ticks).Count -le 6) ('trop de graduations : ' + $max)
    }
}
Test-Case 'BRD-022' 'DS-13 : chiffres en grand, textes en taille de lecture' {
    foreach ($text in @('16 Go', '35 %', '+12 s', '128 postes', '0', '1 234', '3,5 Go')) { Assert-True (Test-DomeniaBoardNumberText $text) ('chiffre : ' + $text) }
    foreach ($text in @('Intel Core i5-1345U', 'il y a 3 j', 'Windows 11 24H2', 'Service informatique', '3 j 4 h', '', '24H2')) { Assert-False (Test-DomeniaBoardNumberText $text) ('texte : ' + $text) }
}
Test-Case 'BRD-023' 'CO-16 : requete mesuree titree par son nom, nombre de postes en sous-titre' {
    $probe = Get-DomeniaProbe 'disk.cfree'
    $measured = [pscustomobject]@{ Machines = 19; Items = @([pscustomobject]@{ Label = 'x'; Value = 19 }); Summary = ''; Numeric = $true; Values = @('40') }
    $entry = ConvertFrom-DomeniaProbeMeasure -Probe $probe -Measured $measured -Board Fleet
    Assert-Equal 'Espace libre sur C: (%)' ([string]$entry.Title) 'jamais Nom (%) (19 postes)'
    Assert-Equal '19 postes' ([string]$entry.Subtitle)
    $skipped = ConvertFrom-DomeniaProbeMeasure -Probe (Get-DomeniaProbe 'sec.localusers') -Measured ([pscustomobject]@{ Machines = 0; Items = @(); Summary = ''; Numeric = $false; Values = @(); Skipped = 1 }) -Board Computer
    Assert-Equal 'Non lu' ([string]$skipped.Value) 'requete ignoree sur un controleur'
    Assert-Equal 'Off' ([string]$skipped.State)
}

Test-Case 'BRD-024' 'CO-24 : une section vide dit ce qui n a pas ete lu, sans promettre au complet ce que le rapide lit deja' {
    # Le collecteur ne garde cinq sources que pour l inventaire complet (Core, bloc if ($deep)) : processus,
    # erreurs systeme, taches planifiees, certificats machine, connexions reseau. Correctifs, antivirus,
    # pare-feu et BitLocker se lisent des l inventaire rapide : aucune de ces deux sections ne peut les
    # presenter comme le supplement du complet.
    $metrics = [pscustomobject]@{ MemoryTotal = [double]16GB; MemoryFree = [double]8GB; LastBoot = ''; CpuLoad = 35.0; Battery = -1.0; ClockSkewSeconds = $null; ClockReference = ''
        Disks = @([pscustomobject]@{ Name = 'C:'; Size = [double]100GB; Free = [double]50GB }); Hotfixes = @(); Processes = @(); Services = @{} }
    $data = Get-DomeniaComputerBoardData -Result ([pscustomobject]@{ Rows = @(); Metrics = $metrics })
    Assert-True ($data.Summary -notlike '*correctif*') ('resume : ' + [string]$data.Summary)
    $e = [string][char]0x00E9; $a = [string][char]0x00E2; $g = [string][char]0x00E8
    foreach ($ajout in @('processus', 'erreurs syst' + $g + 'me', 't' + $a + 'ches planifi' + $e + 'es', 'certificats', 'connexions r' + $e + 'seau')) {
        Assert-True ($data.Summary -like ('*' + $ajout + '*')) ('resume muet sur ' + $ajout + ' : ' + [string]$data.Summary)
    }
    foreach ($section in @('Activite', 'Securite et etat')) {
        Assert-True ($data.Hints.ContainsKey($section)) ('section vide sans indice : ' + $section)
        $hint = [string]$data.Hints[$section]
        Assert-True ($hint -like '*non lu*') ($section + ' : ' + $hint)
        Assert-True ($hint -notlike '*correctif*') ($section + ' promet les correctifs au complet : ' + $hint)
        Assert-True ($hint -notlike '*protection*') ($section + ' promet la protection au complet : ' + $hint)
    }
    # Ce que chaque section attend vraiment du complet, et rien d autre.
    Assert-True ([string]$data.Hints['Activite'] -like '*processus*') ('Activite : ' + [string]$data.Hints['Activite'])
    Assert-True ([string]$data.Hints['Securite et etat'] -like '*certificats*') ('Securite et etat : ' + [string]$data.Hints['Securite et etat'])
}
Test-Case 'BRD-081' 'Points 81, 92, 93, 95, 98, 99 et 100 : le tableau du poste lit les nouvelles lignes de l inventaire' {
    $rows = @(Get-BrdSecureRows) + @(
        (New-BrdRow 'Memoire' 'Barrette 1' '8 Go a 3200 MHz, emplacement DIMM A'),
        (New-BrdRow 'Redemarrage en attente' 'Renommages de fichiers en attente' 'Present (indice partiel) : 2 operation(s)'),
        (New-BrdRow 'Redemarrage en attente' 'Windows Update' 'Absent'),
        (New-BrdRow 'Redemarrage en attente' 'Etat' 'Indices partiels seulement : Renommages de fichiers en attente'),
        (New-BrdRow 'Pare-feu' 'Profil applique a Ethernet' 'Domaine (reseau contoso.test)'),
        (New-BrdRow 'BitLocker' 'Volume C: chiffrement' 'Entierement chiffre'),
        (New-BrdRow 'BIOS et firmware' 'Secure Boot' 'Active'),
        (New-BrdRow 'BIOS et firmware' 'Type de firmware' 'UEFI'),
        (New-BrdRow 'Systeme d exploitation' 'Build' '22631'),
        (New-BrdRow 'Systeme d exploitation' 'Revision de build' '4317'))
    $result = New-BrdInventory -Rows $rows
    $result.Metrics | Add-Member -NotePropertyName MemorySlots -NotePropertyValue 4
    $result.Metrics | Add-Member -NotePropertyName MemorySource -NotePropertyValue 'Barrettes'
    $result.Metrics | Add-Member -NotePropertyName ProcessSample -NotePropertyValue ([pscustomobject]@{ IntervalMs = 2000; SampledUtc = '2026-10-14T10:00:00Z'; LogicalProcessors = 4; Items = @([pscustomobject]@{ Pid = 10; Name = 'calc.exe'; FirstTime = 10000000; SecondTime = 50000000; WorkingSet = 1048576 }) })
    $result.Metrics | Add-Member -NotePropertyName Certificates -NotePropertyValue ([pscustomobject]@{ Source = 'Registre'; Items = @([pscustomobject]@{ Subject = 'CN=old'; Issuer = 'CN=CA'; NotAfterUtc = '2020-01-01T12:00:00Z'; Thumbprint = 'AA'; Usages = @(); KeyDeclared = $false }, [pscustomobject]@{ Subject = 'CN=new'; Issuer = 'CN=CA'; NotAfterUtc = '2099-01-01T12:00:00Z'; Thumbprint = 'BB'; Usages = @(); KeyDeclared = $false }) })
    $data = Get-DomeniaComputerBoardData -Result $result
    $texts = Get-BrdTexts $data
    Assert-Equal '1 barrette(s) sur 4 emplacement(s)' ([string]$data.Entries['computer.memory'].Detail)
    Assert-Equal 'Indices partiels' ([string]$data.Entries['computer.reboot'].Value)
    Assert-Equal '' ([string]$data.Entries['computer.reboot'].State) 'indice partiel : aucun point'
    Assert-Equal 0 @($texts | Where-Object { $_ -like '*marrage en attente*' }).Count ($texts -join ' | ')
    Assert-True ([string]$data.Entries['computer.firewall'].Detail -like '*appliqué à Ethernet*') ([string]$data.Entries['computer.firewall'].Detail)
    Assert-Equal ('Prot' + [char]0x00E9 + 'g' + [char]0x00E9) ([string]$data.Entries['computer.bitlocker'].Value)
    Assert-Equal 'Ok' ([string]$data.Entries['computer.secureboot'].State)
    Assert-Equal 'Build 22631.4317' ([string]$data.Entries['computer.updates'].Value)
    Assert-Equal 'calc.exe' ([string]$data.Entries['computer.processes'].Value)
    Assert-True ([string]$data.Entries['computer.processes'].Detail -like '50 % du processeur sur 2 s*') ([string]$data.Entries['computer.processes'].Detail)
    Assert-Equal '2' ([string]$data.Entries['computer.certificates'].Value)
    Assert-Equal 'Warn' ([string]$data.Entries['computer.certificates'].State)
    Assert-True (@($texts | Where-Object { $_ -like 'Warn:1 certificat(s) machine expir*CN=old.' }).Count -eq 1) ($texts -join ' | ')
    $suspended = @((New-BrdRow 'Pare-feu' 'Profil domaine' 'Active (strategie)'), (New-BrdRow 'Antivirus' 'Defender' 'Actif, A jour'), (New-BrdRow 'BitLocker' 'Volume C:' 'Protection Desactive'), (New-BrdRow 'BitLocker' 'Volume C: chiffrement' 'Entierement chiffre'), (New-BrdRow 'Redemarrage en attente' 'Windows Update' 'Present (obligation confirmee)'), (New-BrdRow 'BIOS et firmware' 'Secure Boot' 'Desactive'), (New-BrdRow 'BIOS et firmware' 'Type de firmware' 'UEFI'))
    $other = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows $suspended)
    $otherTexts = Get-BrdTexts $other
    Assert-True (@($otherTexts | Where-Object { $_ -like 'Warn:BitLocker : protection suspendue sur C:*' }).Count -eq 1) ($otherTexts -join ' | ')
    Assert-True (@($otherTexts | Where-Object { $_ -like 'Warn:Red*marrage en attente, confirm* par : Windows Update.' }).Count -eq 1) ($otherTexts -join ' | ')
    Assert-True (@($otherTexts | Where-Object { $_ -like 'Warn:Secure Boot d*sactiv* sur un micrologiciel UEFI.' }).Count -eq 1) ($otherTexts -join ' | ')
    Assert-Equal 'Warn' ([string]$other.Entries['computer.secureboot'].State)
}
Test-Case 'BRD-081B' 'Points 98 a 100 (revue) : BitLocker suspendu, Secure Boot et certificats se desactivent dans les regles de sante' {
    $ids = @('bitlocker.suspended', 'secureboot', 'certificates')
    $catalog = @(Get-DomeniaHealthRuleCatalog | ForEach-Object { [string]$_.Id })
    foreach ($id in $ids) { Assert-True ($catalog -contains $id) ('regle absente du catalogue : ' + $id) }
    $rows = @((New-BrdRow 'Pare-feu' 'Profil domaine' 'Active (strategie)'), (New-BrdRow 'Antivirus' 'Defender' 'Actif, A jour'), (New-BrdRow 'BitLocker' 'Volume C:' 'Protection Desactive'), (New-BrdRow 'BitLocker' 'Volume C: chiffrement' 'Entierement chiffre'), (New-BrdRow 'BIOS et firmware' 'Secure Boot' 'Desactive'), (New-BrdRow 'BIOS et firmware' 'Type de firmware' 'UEFI'))
    $store = [pscustomobject]@{ Source = 'Registre'; Items = @([pscustomobject]@{ Subject = 'CN=old'; Issuer = 'CN=CA'; NotAfterUtc = '2020-01-01T12:00:00Z'; Thumbprint = 'AA'; Usages = @(); KeyDeclared = $false }) }
    $raised = New-BrdInventory -Rows $rows
    $raised.Metrics | Add-Member -NotePropertyName Certificates -NotePropertyValue $store
    $raisedData = Get-DomeniaComputerBoardData -Result $raised
    $before = @(@($raisedData.Attention) | ForEach-Object { [string]$_.Point })
    foreach ($id in $ids) { Assert-True ($before -contains $id) ('point attendu : ' + $id + ' / ' + ($before -join ', ')) }
    # Point 75 (W02): the workstation explanation reads each new rule from its own tile, never as a fleet-only control.
    foreach ($id in $ids) { Assert-Equal 'Mesuré' ([string]@($raisedData.HealthExplanation.Rows | Where-Object { $_.Id -eq $id })[0].Eligible) ('regle du poste : ' + $id) }
    $policy = ConvertTo-DomeniaHealthPolicy @{ DisabledRules = $ids }
    Assert-Equal 3 @($policy.DisabledRules).Count 'regles ignorees par la politique'
    $quiet = New-BrdInventory -Rows $rows
    $quiet.Metrics | Add-Member -NotePropertyName Certificates -NotePropertyValue $store
    $after = @(@((Get-DomeniaComputerBoardData -Result $quiet -HealthPolicy $policy).Attention) | ForEach-Object { [string]$_.Point })
    foreach ($id in $ids) { Assert-False ($after -contains $id) ('point desactive encore compte : ' + $id) }
}
Test-Case 'BRD-081C' 'Points 92 et 100 (revue) : adresse WSUS non appliquee et magasin de certificats lu en partie' {
    $declared = @((New-BrdRow 'Windows Update' 'Serveur WSUS' 'http://wsus.contoso.test:8530'), (New-BrdRow 'Windows Update' 'Strategie WSUS appliquee' 'Non'))
    $result = New-BrdInventory -Rows $declared
    $result.Metrics | Add-Member -NotePropertyName Certificates -NotePropertyValue ([pscustomobject]@{ Source = 'Registre'; StoreCount = 73; Truncated = $true; Items = @([pscustomobject]@{ Subject = 'CN=new'; Issuer = 'CN=CA'; NotAfterUtc = '2099-01-01T12:00:00Z'; Thumbprint = 'BB'; Usages = @(); KeyDeclared = $false }) })
    $data = Get-DomeniaComputerBoardData -Result $result
    Assert-Equal 'Windows Update' ([string]$data.Entries['computer.wsus'].Value) 'adresse WSUS sans UseWUServer annoncee comme WSUS'
    Assert-True ([string]$data.Entries['computer.wsus'].Detail -like '*UseWUServer*wsus.contoso.test*') ([string]$data.Entries['computer.wsus'].Detail)
    $applied = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows @((New-BrdRow 'Windows Update' 'Serveur WSUS' 'http://wsus.contoso.test:8530'), (New-BrdRow 'Windows Update' 'Strategie WSUS appliquee' 'Oui')))
    Assert-Equal 'WSUS' ([string]$applied.Entries['computer.wsus'].Value)
    Assert-Equal '1' ([string]$data.Entries['computer.certificates'].Value)
    Assert-Equal '' ([string]$data.Entries['computer.certificates'].State) 'lecture partielle affichee en bon etat'
    Assert-True ([string]$data.Entries['computer.certificates'].Detail -like '*lecture partielle : 1 lu(s) sur 73') ([string]$data.Entries['computer.certificates'].Detail)
}
Test-Case 'BRD-025' 'Point 74 : couverture a cote de la sante, aucune note rassurante pour un parc peu renseigne' {
    $c = Get-DomeniaHealthCoverage -Total 26 -Assessed 12
    Assert-Equal 46 ([int]$c.Percent); Assert-False $c.Sufficient
    Assert-True (Get-DomeniaHealthCoverage -Total 26 -Assessed 13).Sufficient '50 % exactement'
    Assert-Equal 49 ([int](Get-DomeniaHealthCoverage -Total 1000 -Assessed 499).Percent) 'arrondi vers le bas'
    Assert-False (Get-DomeniaHealthCoverage -Total 0 -Assessed 0).Sufficient
    $thin = Get-DomeniaFleetHealth -Total 100 -Healthy 5 -Unassessed 95
    Assert-Equal $null $thin.Score 'aucun score sur 5 % du parc'
    Assert-Equal 'Couverture insuffisante' ([string]$thin.Verdict); Assert-Equal 'Off' ([string]$thin.State)
    Assert-True ([string]$thin.Detail -like '*couverture 5 % (5 évalué(s) sur 100)*') ([string]$thin.Detail)
    $critical = Get-DomeniaFleetHealth -Total 100 -Healthy 4 -Unassessed 95 -Attention @([pscustomobject]@{ Level = 'Alert'; Text = 'x' })
    Assert-Equal 'Critique' ([string]$critical.Verdict); Assert-Equal 'Alert' ([string]$critical.State); Assert-Equal $null $critical.Score
    $partial = Get-DomeniaFleetHealth -Total 20 -Healthy 17 -Unassessed 2
    Assert-Equal 94 ([int]$partial.Score); Assert-Equal 'Évaluation partielle' ([string]$partial.Verdict)
    Assert-True ([string]$partial.Detail -like '*· couverture 90 % (18 évalué(s) sur 20)') ([string]$partial.Detail)
    Assert-Equal '22 postes sur 26 évalués sans point détecté · 0 non évalué(s)' ([string](Get-DomeniaFleetHealth -Total 26 -Healthy 22).Detail) 'parc entierement evalue inchange'
    $data = New-DomeniaBoardData -Board Fleet
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Population' -Value ([pscustomobject]@{ Total = 40; Healthy = 3; Unassessed = 36 })
    [void](Complete-DomeniaBoardData -Data $data)
    Assert-Equal $null $data.Entries['fleet.health'].Number 'le widget ne montre aucun score'
    Assert-Equal 'Couverture insuffisante' ([string]$data.Entries['fleet.health'].Value)
}

# ---------------------------------------------------------------------------------------------------------------------
# Lot Z03 (15/10/2026) : grille fluide (DS-04), carte Sante (DS-05), poste allege (UX-11), copie pour un ticket (FO-13),
# disposition d equipe (FO-17), catalogue de l editeur sans jargon, filtres et synonymes (UI-14, SP-07, SP-19).
# ---------------------------------------------------------------------------------------------------------------------
function Get-BrdCells {
    # Placement as 'row:column:span:items' for compact assertions.
    param([object[]]$Units,[int]$Columns)
    return (@(Get-DomeniaBoardGridPlacement -Units $Units -Columns $Columns) | ForEach-Object { [string]$_.Row + ':' + [string]$_.Column + ':' + [string]$_.Span + ':' + (@($_.Items) -join '+') }) -join ' '
}
function New-BrdUnit { param([int]$Span,[bool]$Short) return [pscustomobject]@{ Span = $Span; Short = $Short } }

Test-Case 'BRD-026' 'DS-04 : 4, 3 ou 2 colonnes selon la largeur, sans bascule au passage dʼune barre de défilement' {
    foreach ($case in @(@(1920,4),@(1440,4),@(1100,4),@(1099,3),@(1000,3),@(780,3),@(779,2),@(600,2),@(440,2),@(439,1),@(300,1))) { Assert-Equal ([int]$case[1]) (Get-DomeniaBoardColumnCount -Width ([double]$case[0])) ('largeur ' + $case[0]) }
    Assert-Equal 1 (Get-DomeniaBoardColumnCount -Width ([double]::NaN)) 'page non mesuree'
    # Hysteresis of 24 px around each boundary: a scroll bar (17 px) never switches the layout.
    Assert-Equal 4 (Get-DomeniaBoardColumnCount -Width 1083 -Current 4) 'garde 4 colonnes a 17 px sous le seuil'
    Assert-Equal 3 (Get-DomeniaBoardColumnCount -Width 1117 -Current 3) 'garde 3 colonnes a 17 px au-dessus du seuil'
    Assert-Equal 3 (Get-DomeniaBoardColumnCount -Width 1070 -Current 4) 'au-dela de la marge : 3 colonnes'
    Assert-Equal 4 (Get-DomeniaBoardColumnCount -Width 1130 -Current 3)
    Assert-Equal 2 (Get-DomeniaBoardColumnCount -Width 700 -Current 4) 'saut de deux paliers : pas de marge'
    Assert-Equal '1,2,3' ((@('S','M','L') | ForEach-Object { Get-DomeniaBoardSpan -Size $_ }) -join ',')
    Assert-Equal 2 (Get-DomeniaBoardSpan -Size 'L' -Columns 2) 'jamais plus large que la grille'
    Assert-Equal 2 (Get-DomeniaBoardSpan -Size '') 'taille inconnue : moyenne'
    Assert-True (Test-DomeniaBoardShortWidget -Visual 'Kpi') 'chiffre cle compact'
    Assert-True (Test-DomeniaBoardShortWidget -Visual 'Text' -Kind 'Value') 'valeur unique en liste compacte'
    Assert-False (Test-DomeniaBoardShortWidget -Visual 'Text' -Kind 'Distribution') 'liste de repartition haute'
    Assert-False (Test-DomeniaBoardShortWidget -Visual 'HealthSummary' -Kind 'Health')
    Assert-True (Test-DomeniaBoardShortWidget -Visual 'Pie' -Compact $true) 'place compacte d un widget sans chiffre'
    # Redraw measured at card scale: 6 px more per column moves a card of 4 columns by 24 px.
    Assert-True (Test-DomeniaBoardRedrawNeeded -Columns 4 -BuiltColumns 4 -Cell 296 -BuiltCell 290) 'carte de 4 colonnes decalee de 24 px'
    Assert-False (Test-DomeniaBoardRedrawNeeded -Columns 4 -BuiltColumns 4 -Cell 294 -BuiltCell 290) '16 px : pas de redessin'
    Assert-False (Test-DomeniaBoardRedrawNeeded -Columns 1 -BuiltColumns 1 -Cell 515 -BuiltCell 500) 'une colonne : 15 px'
    Assert-True (Test-DomeniaBoardRedrawNeeded -Columns 3 -BuiltColumns 4 -Cell 290 -BuiltCell 290) 'autre nombre de colonnes'
}
Test-Case 'BRD-027' 'DS-04 : rangées pleines, tuiles compactes empilées à côté dʼune carte haute, ordre de lecture gardé' {
    $k = New-BrdUnit 1 $true; $pie = New-BrdUnit 2 $false; $large = New-BrdUnit 3 $false; $gauge = New-BrdUnit 1 $false
    Assert-Equal '0:0:1:0+1 0:1:2:2 0:3:1:3+4 1:0:2:5 1:2:2:6' (Get-BrdCells @($k,$k,$pie,$k,$k,$k,$k) 4) 'inventaire du perimetre'
    Assert-Equal '0:0:4:0' (Get-BrdCells @($k) 4) 'une tuile seule remplit sa rangee'
    Assert-Equal '0:0:3:0 0:3:1:1+2' (Get-BrdCells @($pie,$k,$k) 4) 'deux tuiles empilees, la carte haute prend la colonne libre'
    Assert-Equal '0:0:1:0+1 0:1:3:2' (Get-BrdCells @($k,$k,$pie) 4) 'paire en tete : la colonne libre va a la carte haute, pas a la paire'
    Assert-Equal '0:0:2:0 0:2:1:1 0:3:1:2 1:0:2:3 1:2:2:4' (Get-BrdCells @($gauge,$gauge,$gauge,$pie,$pie) 4) 'ressources'
    Assert-Equal '0:0:1:0 0:1:1:1 0:2:1:2 0:3:1:3 1:0:1:4 1:1:1:5 1:2:1:6 1:3:1:7' (Get-BrdCells @($k,$k,$k,$k,$k,$k,$k,$k) 4) 'tuiles seules : jamais empilees'
    Assert-Equal '0:0:1:0 0:1:1:1 1:0:2:2 2:0:2:3 3:0:2:4' (Get-BrdCells @($k,$k,$pie,$k,$large) 2) 'deux colonnes'
    Assert-Equal '0:0:1:0 1:0:1:1 2:0:1:2' (Get-BrdCells @($k,$pie,$large) 1) 'une colonne'
    Assert-Equal '0:0:1:0 0:1:1:1 0:2:1:2 1:0:2:3 1:2:1:4' (Get-BrdCells @($k,$k,$k,$k,$k) 3) 'trois colonnes'
    Assert-Equal '' (Get-BrdCells @() 4) 'section vide'
    # Every row is full and every widget is placed once, in order, whatever the mix.
    $pool = @($k, $pie, $large, $gauge, (New-BrdUnit 2 $true))
    foreach ($columns in @(1,2,3,4)) {
        for ($seed = 0; $seed -lt 12; $seed++) {
            $units = @(for ($i = 0; $i -lt (3 + $seed); $i++) { $pool[($i * 7 + $seed * 3) % $pool.Count] })
            $cells = @(Get-DomeniaBoardGridPlacement -Units $units -Columns $columns)
            $placed = @($cells | ForEach-Object { @($_.Items) } | Sort-Object)
            Assert-Equal ((0..($units.Count - 1)) -join ',') ($placed -join ',') ('placement incomplet : ' + $columns + '/' + $seed)
            foreach ($row in @($cells | Group-Object Row)) {
                $sum = 0; foreach ($cell in $row.Group) { $sum += [int]$cell.Span }
                Assert-Equal $columns $sum ('rangee incomplete : ' + $columns + ' colonnes, essai ' + $seed)
            }
            foreach ($cell in @($cells | Where-Object { $_.Stacked })) { Assert-Equal 2 @($cell.Items).Count 'deux tuiles au plus par colonne' }
        }
    }
}
Test-Case 'BRD-028' 'DS-05 : une carte Santé, « 4 points à vérifier · 1 information », rien de rassurant sans score établi' {
    Assert-Equal '4 points à vérifier · 1 information' (Get-DomeniaHealthPointsTitle -Points 4 -Information 1)
    Assert-Equal '1 point à vérifier' (Get-DomeniaHealthPointsTitle -Points 1)
    Assert-Equal 'Rien à signaler' (Get-DomeniaHealthPointsTitle)
    Assert-Equal 'Aucun point à vérifier · 2 informations' (Get-DomeniaHealthPointsTitle -Information 2)
    Assert-Equal 'Aucun problème établi' (Get-DomeniaHealthPointsTitle -Reliable $false) 'score retenu ou incomplet'
    Assert-Equal 'HealthSummary,Health,Kpi' (@(Get-DomeniaBoardVisuals -Kind Health) -join ',')
    Assert-Equal 'Health' (Resolve-DomeniaBoardVisual -Visual 'Health' -Kind Health) 'score seul garde dans une disposition personnalisee'
    Assert-Equal 'Score et points' ([string](Get-DomeniaBoardVisualNames)['HealthSummary'])
    foreach ($board in @('Computer','Fleet')) {
        $prefix = $board.ToLowerInvariant()
        $delivered = @(Get-DomeniaBoardDefaultLayout -Board $board)
        Assert-Equal 1 @($delivered | Where-Object { ($_.Key -eq ($prefix + '.health')) -and ($_.Visual -eq 'HealthSummary') -and ($_.Size -eq 'L') }).Count ('carte Sante livree : ' + $board)
        Assert-Equal 0 @($delivered | Where-Object { $_.Key -eq ($prefix + '.attention') }).Count ('liste des points en double : ' + $board)
        Assert-True ($null -ne (Get-DomeniaBoardCatalogItem -Board $board -Key ($prefix + '.attention'))) ('liste des points toujours au catalogue : ' + $board)
    }
    # A score withheld (coverage under 50 %) keeps its points but never the green line.
    $thin = New-DomeniaBoardData -Board Fleet
    Add-Member -InputObject $thin -MemberType NoteProperty -Name 'Population' -Value ([pscustomobject]@{ Total = 40; Healthy = 3; Unassessed = 36 })
    [void](Complete-DomeniaBoardData -Data $thin)
    Assert-Equal 'Aucun problème établi' ([string]$thin.Entries['fleet.health'].PointsTitle)
    # The sample of the editor preview shows a score beside its points.
    $sample = New-DomeniaBoardSample -Key 'computer.health' -Kind Health
    Assert-Equal 2 @($sample.Points).Count
    Assert-Equal '1 point à vérifier · 1 information' ([string]$sample.PointsTitle)
}
Test-Case 'BRD-029' 'DS-05, UX-11 : anciennes dispositions livrées remplacées, dispositions personnalisées conservées' {
    $toItems = { param([string]$Text) @(foreach ($line in ($Text -split "`n")) { $value = $line.Trim(); if ($value) { $c = $value -split '\|'; [pscustomobject]@{ Id = ('b-' + $c[0]); Source = 'Builtin'; Key = $c[0]; Visual = $c[2]; Title = ''; Size = $c[3]; Group = $c[1] } } }) }
    # Widgets of a saved layout that this build knows: the W11 tiles count only once its catalog has them.
    $known = { param([string]$Board,[object[]]$Items) @($Items | Where-Object { $null -ne (Get-DomeniaBoardCatalogItem -Board $Board -Key ([string]$_.Key)) }).Count }
    $cases = @(
        @('Computer', [string]$script:DomeniaComputerLegacyLayoutText, 42, 'Health'),
        @('Computer', [string]$script:DomeniaComputerW11LayoutText, 44, 'Health'),
        @('Fleet', [string]$script:DomeniaFleetPairLayoutText, 17, 'Health'),
        @('Fleet', [string]$script:DomeniaFleetLegacyLayoutText, 17, 'Health')
    )
    foreach ($case in $cases) {
        $board = [string]$case[0]
        $old = @(& $toItems ([string]$case[1]))
        Assert-Equal ([int]$case[2]) $old.Count ('ancienne disposition : ' + $board)
        Assert-True (Test-DomeniaBoardLegacyLayout -Board $board -Items $old) ('ancienne disposition reconnue : ' + $board + ' ' + $old.Count)
        $migrated = @(ConvertTo-DomeniaBoardLayout -Board $board -Json (ConvertTo-Json -InputObject $old -Depth 3 -Compress))
        Assert-Equal (@(Get-DomeniaBoardDefaultLayout -Board $board | ForEach-Object { $_.Key }) -join ',') (@($migrated | ForEach-Object { $_.Key }) -join ',') ('ancienne disposition livree remplacee : ' + $board + ' ' + $old.Count)
        # The last widget removed: a customised layout, kept as it is, its score card included.
        $fewer = @($old | Select-Object -First ($old.Count - 1))
        $kept = @(ConvertTo-DomeniaBoardLayout -Board $board -Json (ConvertTo-Json -InputObject $fewer -Depth 3 -Compress))
        Assert-Equal (& $known $board $fewer) $kept.Count ('widget retire : conservee ' + $board + ' ' + $old.Count)
        $health = @($kept | Where-Object { [string]$_.Key -eq ($board.ToLowerInvariant() + '.health') })
        Assert-Equal 1 $health.Count ('score garde : ' + $board)
        Assert-Equal ([string]$case[3]) ([string]$health[0].Visual) ('aucune carte remplacee dans une disposition personnalisee : ' + $board + ' ' + $old.Count)
        $paused = @($old | ForEach-Object { $_.PSObject.Copy() }); $paused[2] | Add-Member -NotePropertyName Paused -NotePropertyValue $true
        $kept = @(ConvertTo-DomeniaBoardLayout -Board $board -Json (ConvertTo-Json -InputObject $paused -Depth 3 -Compress))
        Assert-Equal (& $known $board $paused) $kept.Count ('mesure suspendue : conservee ' + $board + ' ' + $old.Count)
        Assert-True (Test-DomeniaBoardItemPaused -Item @($kept | Where-Object { [string]$_.Key -eq [string]$old[2].Key })[0]) 'pause gardee'
    }
    Assert-False (Test-DomeniaBoardLegacyLayout -Board Software -Items @(Get-DomeniaBoardDefaultLayout -Board Software)) 'logiciels : rien a migrer'
}
Test-Case 'BRD-030' 'UX-11 : poste livré avec 14 widgets, fiches Identité et Compte machine, liste dʼétat à coches' {
    $delivered = @(Get-DomeniaBoardDefaultLayout -Board Computer)
    Assert-Equal 'computer.health,computer.identity,computer.adaccount,computer.memory.usage,computer.cpu.load,computer.battery,computer.disk.system,computer.disk.volumes,computer.services,computer.processes,computer.events,computer.status,computer.services.stopped,computer.devices' (@($delivered | ForEach-Object { $_.Key }) -join ',')
    # Every tile delivered before stays in the catalog, whatever this build adds to it.
    foreach ($line in ([string]$script:DomeniaComputerLegacyLayoutText -split "`n")) { $key = ($line.Trim() -split '\|')[0]; if ($key) { Assert-True ($null -ne (Get-DomeniaBoardCatalogItem -Board Computer -Key $key)) ('tuile retiree du catalogue : ' + $key) } }
    Assert-Equal 'Sheet,Text' (@(Get-DomeniaBoardVisuals -Kind Sheet) -join ',')
    Assert-Equal 'Checklist,Sheet,Text' (@(Get-DomeniaBoardVisuals -Kind Checklist) -join ',')
    $object = [pscustomobject]@{ Entry = @{ userAccountControl = '4096'; whenCreated = '2020-01-15T10:00:00Z' }; DN = 'CN=PC-1,OU=Postes,DC=example,DC=test' }
    $rows = @(Get-BrdSecureRows) + @((New-BrdRow 'Systeme d exploitation' 'Nom' 'Microsoft Windows 11 Entreprise'), (New-BrdRow 'Systeme d exploitation' 'Build' '26100'), (New-BrdRow 'Systeme' 'Modele' 'Latitude fictif'))
    $data = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows $rows) -Object $object
    $identity = $data.Entries['computer.identity']
    Assert-Equal 'Sheet' ([string]$identity.Kind)
    Assert-Equal 'Système' ([string]@($identity.Items)[0].Label)
    Assert-Equal ([string]$data.Entries['computer.os'].Value) ([string]@($identity.Items)[0].Value) 'meme valeur que le widget Systeme'
    Assert-True (@($identity.Items | Where-Object { $_.Label -eq 'Mémoire installée' }).Count -eq 1)
    $account = $data.Entries['computer.adaccount']
    Assert-Equal 'Compte ordinateur' ([string]@($account.Items)[0].Label)
    Assert-Equal 'Activé' ([string]@($account.Items)[0].Value)
    $status = $data.Entries['computer.status']
    Assert-Equal 'Checklist' ([string]$status.Kind)
    Assert-Equal 'BitLocker,Démarrage sécurisé,Pare-feu,Antivirus,Redémarrage en attente,Dernier correctif' (@($status.Items | ForEach-Object { $_.Label }) -join ',')
    Assert-Equal 'Ok,Off,Ok,,Off,Off' (@($status.Items | ForEach-Object { [string]$_.State }) -join ',') 'non lu jamais compte comme conforme'
    Assert-Equal 'Non lu' ([string]@($status.Items)[1].Value) 'Secure Boot absent de la lecture'
    Assert-Equal 'Non lu' ([string]@($status.Items)[4].Value)
    Assert-Equal '3 contrôles lus sur 6' ([string]$status.Detail)
    Assert-Equal '' ([string]$status.State)
    $off = @((New-BrdRow 'Pare-feu' 'Profil domaine' 'Desactive (local)'), (New-BrdRow 'BitLocker' 'Volume C:' 'Protection Active'))
    $warned = (Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows $off)).Entries['computer.status']
    Assert-Equal 'Warn' ([string]$warned.State) 'pare-feu desactive : a verifier'
    Assert-Equal '1 à vérifier' ([string]$warned.Value)
    # Secure Boot (W11 tile, catalog only since this layout) stays visible as a line of the checklist, same state.
    $uefi = @(Get-BrdSecureRows) + @((New-BrdRow 'BIOS et firmware' 'Secure Boot' 'Desactive'), (New-BrdRow 'BIOS et firmware' 'Type de firmware' 'UEFI'))
    $uefiData = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows $uefi)
    $secureLine = @($uefiData.Entries['computer.status'].Items | Where-Object { [string]$_.Key -eq 'computer.secureboot' })
    Assert-Equal 1 $secureLine.Count 'ligne Secure Boot'
    Assert-Equal ([string]$uefiData.Entries['computer.secureboot'].Value) ([string]$secureLine[0].Value) 'meme valeur que le widget Demarrage securise'
    Assert-Equal 'Warn' ([string]$secureLine[0].State)
    Assert-Equal 'Warn' ([string]$uefiData.Entries['computer.status'].State) 'Secure Boot desactive sur UEFI : a verifier'
    foreach ($key in @('computer.secureboot','computer.updates')) { Assert-False ([bool](Get-DomeniaBoardCatalogItem -Board Computer -Key $key).Default) ('tuile W11 au catalogue seulement : ' + $key) }
    $none = Get-DomeniaComputerBoardData
    foreach ($key in @('computer.identity','computer.adaccount','computer.status')) { Assert-False ($none.Entries.ContainsKey($key)) ('fiche sans lecture : ' + $key) }
}
Test-Case 'BRD-031' 'FO-13 : un widget et le résumé du tableau en texte brut pour un ticket, secrets masqués' {
    $object = [pscustomobject]@{ Entry = @{ userAccountControl = '4096'; whenCreated = '2020-01-15T10:00:00Z' }; DN = 'CN=PC-1,OU=Postes,DC=example,DC=test' }
    $data = Get-DomeniaComputerBoardData -Result (New-BrdInventory -Rows (Get-BrdSecureRows) -FreePercent 8) -Object $object
    $at = [datetime]::new(2026, 10, 15, 12, 30, 0, [DateTimeKind]::Utc)
    $widget = ConvertTo-DomeniaWidgetText -Title 'Disque C:' -Entry $data.Entries['computer.disk.system'] -AtUtc $at
    $lines = @($widget -split "`r`n")
    Assert-Equal 'Disque C: : 8 % libre' $lines[0]
    Assert-True ($widget -like '*- Libre 8 Go (8 %)*') ('part du tout, jamais des octets bruts : ' + $widget)
    Assert-Equal ('Données du ' + $at.ToLocalTime().ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)) $lines[$lines.Count - 1]
    $health = ConvertTo-DomeniaWidgetText -Title 'Santé du poste' -Entry $data.Entries['computer.health']
    Assert-True ($health -like ('Santé du poste : ' + [string][int]$data.Entries['computer.health'].Number + ' sur 100 · *')) $health
    Assert-True ($health -like '*- Critique : C: presque plein (8 % libre).*') $health
    $checks = ConvertTo-DomeniaWidgetText -Title 'État de protection' -Entry $data.Entries['computer.status']
    Assert-True ($checks -like '*- `[OK`] BitLocker : Protection Active (Volume C:)*') $checks
    Assert-True ($checks -like '*- `[Non lu`] Dernier correctif : Non lu*') $checks
    $summary = ConvertTo-DomeniaBoardSummaryText -Board Computer -Data $data -Subject 'PC-1' -AtUtc $at -AtLabel 'inventaire du'
    $summaryLines = @($summary -split "`r`n")
    Assert-Equal ('Poste PC-1 · inventaire du ' + $at.ToLocalTime().ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)) $summaryLines[0]
    Assert-True ($summaryLines[1] -like 'Santé : * sur 100 · Critique*') $summaryLines[1]
    foreach ($expected in @('Identité du poste','Compte machine','État de protection','- Compte ordinateur : Activé*','- Critique : C: presque plein (8 % libre).')) { Assert-True (@($summaryLines | Where-Object { $_ -like $expected }).Count -ge 1) ('ligne absente : ' + $expected) }
    Assert-True ($summary -match '1 point à vérifier') $summary
    # A secret that a value would hold is masked before the clipboard (Protect-DomeniaSecretText, as the interface does).
    $data.Entries['computer.os'].Detail = 'password=Abc123!'
    $leak = ConvertTo-DomeniaBoardSummaryText -Board Computer -Data (& { $copy = $data; Add-DomeniaComputerSheetEntries -Data $copy; $copy }) -Subject 'PC-1'
    Assert-True ($leak -like '*Abc123!*') 'la valeur passe par le texte avant le masquage'
    Assert-False ((Protect-DomeniaSecretText -Text $leak) -like '*Abc123!*') 'secret masque avant le presse-papiers'
    $fleet = New-DomeniaBoardData -Board Fleet
    Add-DomeniaBoardEntry $fleet (New-DomeniaBoardEntry -Key 'fleet.machines' -Kind Value -Value '26' -Detail '24 activés')
    Add-DomeniaBoardAttention -Data $fleet -Level Warn -Text 'Quatre postes inactifs.'
    [void](Complete-DomeniaBoardData -Data $fleet)
    $fleetText = ConvertTo-DomeniaBoardSummaryText -Board Fleet -Data $fleet -Subject 'Postes'
    Assert-True ($fleetText -like 'Vue dʼensemble · Postes*') $fleetText
    Assert-True ((ConvertTo-DomeniaBoardSummaryText -Board Software -Data (New-DomeniaBoardData -Board Software) -Subject 'PC-1' -AtUtc $at -AtLabel 'liste lue le') -like ('Logiciels de PC-1 · liste lue le ' + $at.ToLocalTime().ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture))) 'entete du resume des logiciels'
    Assert-True ($fleetText -like '*- À surveiller : Quatre postes inactifs.*') $fleetText
    Assert-True ($fleetText -like '*- Comptes ordinateur : 26 (24 activés)*') $fleetText
    # The subject of the overview comes from the scope of its data, never from the OU chosen since.
    Assert-Equal 'Postes' (Get-DomeniaBoardScopeName -Dn 'OU=Postes,OU=Siege,DC=example,DC=test')
    Assert-Equal 'Postes, Siège' (Get-DomeniaBoardScopeName -Dn 'OU=Postes\, Siège,DC=example,DC=test') 'virgule echappee'
    Assert-Equal 'Tout le domaine' (Get-DomeniaBoardScopeName -Dn '')
    Assert-Equal 'Tout le domaine' (Get-DomeniaBoardScopeName -Dn 'DC=example,DC=test') 'racine du domaine'
}
Test-Case 'BRD-032' 'FO-17 : disposition dʼéquipe de la configuration, JSON invalide ou inconnu : disposition du catalogue' {
    $team = '[{"Id":"t1","Source":"Builtin","Key":"software.largest","Visual":"Bar","Size":"L","Group":"Equipe"},{"Id":"t2","Source":"Builtin","Key":"software.count","Visual":"Kpi","Size":"S","Group":"Equipe"},{"Id":"t3","Source":"Query","Key":"q1","Visual":"Kpi"}]'
    $layout = @(Get-DomeniaBoardDefaultLayout -Board Software -TeamJson $team)
    Assert-Equal 'software.largest,software.count' (@($layout | ForEach-Object { $_.Key }) -join ',') 'disposition d equipe, sans requete personnelle'
    Assert-Equal 'Equipe' ([string]$layout[0].Group)
    $catalog = (@(Get-DomeniaBoardDefaultLayout -Board Software) | ForEach-Object { $_.Key }) -join ','
    foreach ($bad in @('pas du json', '[]', '[{"Source":"Builtin","Key":"inconnu"}]', '{"Format":"Domenia.BoardLayout.1","Board":"Fleet","Layout":[{"Source":"Builtin","Key":"software.count"}]}', '{"Format":"Autre.2","Layout":[{"Source":"Builtin","Key":"software.count"}]}', '42')) {
        Assert-Equal $catalog ((@(Get-DomeniaBoardDefaultLayout -Board Software -TeamJson $bad) | ForEach-Object { $_.Key }) -join ',') ('valeur refusee : ' + $bad)
    }
    Assert-Equal 'software.largest,software.count' ((@(ConvertTo-DomeniaBoardLayout -Board Software -Json '' -TeamJson $team) | ForEach-Object { $_.Key }) -join ',') 'tableau jamais personnalise : disposition d equipe'
    Assert-Equal 'software.size' ((@(ConvertTo-DomeniaBoardLayout -Board Software -Json '[{"Id":"x","Source":"Builtin","Key":"software.size","Visual":"Kpi","Size":"S","Group":"G"}]' -TeamJson $team) | ForEach-Object { $_.Key }) -join ',') 'disposition personnalisee prioritaire'
    # Export then import: the same widgets, of this board only.
    $document = ConvertTo-DomeniaBoardLayoutDocument -Board Software -Layout $layout -AtUtc ([datetime]::new(2026, 10, 15, 8, 0, 0, [DateTimeKind]::Utc))
    $parsed = ConvertFrom-Json -InputObject $document
    Assert-Equal 'Domenia.BoardLayout.1' ([string]$parsed.Format)
    Assert-Equal '2026-10-15T08:00:00Z' ([string]$parsed.ExportedUtc)
    $read = ConvertFrom-DomeniaBoardLayoutDocument -Board Software -Text $document
    Assert-True $read.Valid
    Assert-Equal (ConvertTo-DomeniaBoardLayoutJson -Layout $layout) (ConvertTo-DomeniaBoardLayoutJson -Layout @(ConvertTo-DomeniaBoardCleanLayout -Board Software -Items @($read.Items)))
    Assert-Equal 'software.largest,software.count' ((@(Get-DomeniaBoardDefaultLayout -Board Software -TeamJson $document) | ForEach-Object { $_.Key }) -join ',') 'document exporte accepte comme disposition d equipe'
    $other = ConvertFrom-DomeniaBoardLayoutDocument -Board Computer -Text $document
    Assert-False $other.Valid 'document d un autre tableau'
    Assert-Equal 'Disposition du tableau des logiciels, pas de celui-ci.' ([string]$other.Reason)
    Assert-Equal 'Texte JSON illisible.' ([string](ConvertFrom-DomeniaBoardLayoutDocument -Board Software -Text '{').Reason)
    Assert-Equal 'Aucun widget dans ce fichier.' ([string](ConvertFrom-DomeniaBoardLayoutDocument -Board Software -Text '{"Layout":[]}').Reason)
    Assert-Equal 'Domenia-disposition-poste-20261015-0930.json' (Get-DomeniaBoardLayoutFileName -Board Computer -Time ([datetime]::new(2026, 10, 15, 9, 30, 0)))
    # A team layout without identifiers, rebuilt on every reading: the same identifiers each time, unique.
    $bare = '[{"Source":"Builtin","Key":"software.count"}]'
    $once = @(ConvertTo-DomeniaBoardLayout -Board Software -Json '' -TeamJson $bare)
    $twice = @(ConvertTo-DomeniaBoardLayout -Board Software -Json '' -TeamJson $bare)
    Assert-Equal 1 $once.Count
    Assert-Equal ([string]$once[0].Id) ([string]$twice[0].Id) 'identifiant stable d une lecture a l autre'
    Assert-Equal 't-software.count-0' ([string]$once[0].Id)
    $mixedIds = '[{"Id":"a","Source":"Builtin","Key":"software.count"},{"Id":"a","Source":"Builtin","Key":"software.size"},{"Source":"Builtin","Key":"software.largest"},{"Id":"t-software.largest-2","Source":"Builtin","Key":"software.recent"}]'
    $repeated = @(Get-DomeniaBoardDefaultLayout -Board Software -TeamJson $mixedIds)
    Assert-Equal 'a,t-software.size-1,t-software.largest-2-2,t-software.largest-2' (@($repeated | ForEach-Object { [string]$_.Id }) -join ',') 'identifiant repete ou absent remplace sans prendre celui d un autre widget'
    Assert-Equal (@($repeated | ForEach-Object { [string]$_.Id }) -join ',') (@(Get-DomeniaBoardDefaultLayout -Board Software -TeamJson $mixedIds | ForEach-Object { [string]$_.Id }) -join ',') 'meme texte, memes identifiants'
    # A team layout of one widget beside a widget of the first version: never unrolled to a single object.
    $probes = @([pscustomobject]@{ Id = 'net.dns'; Category = 'Reseau'; Name = 'Serveur DNS'; Mode = 'Value'; Transform = 'Text'; Visual = 'Text' })
    $legacy = @([pscustomobject]@{ ProbeId = 'net.dns'; Visual = 'Kpi'; Title = 'DNS' })
    $oneTeam = '[{"Source":"Builtin","Key":"fleet.machines","Visual":"Kpi","Size":"S","Group":"Equipe"}]'
    $mixed = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json '' -TeamJson $oneTeam -LegacyWidgets $legacy -ProbeCatalog $probes)
    Assert-Equal 'fleet.machines,net.dns' (@($mixed | ForEach-Object { [string]$_.Key }) -join ',') 'disposition d equipe d un widget et widget de la premiere version'
    $again = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json '' -TeamJson $oneTeam -LegacyWidgets $legacy -ProbeCatalog $probes)
    Assert-Equal (@($mixed | ForEach-Object { [string]$_.Id }) -join ',') (@($again | ForEach-Object { [string]$_.Id }) -join ',') 'widget de la premiere version sans identifiant : stable aussi'
    # Refusals of the DocumentStore worker in the words of a layout file; any other message unchanged.
    Assert-Equal 'fichier absent ou trop volumineux (1 Mo maximum).' (Get-DomeniaBoardDocumentMessage -Message 'Capture absente ou trop volumineuse (1 Mo maximum).')
    Assert-Equal 'chemin redirigé refusé.' (Get-DomeniaBoardDocumentMessage -Message 'Exception calling "Invoke": "Document ou dossier redirige refuse."')
    Assert-Equal 'disposition trop volumineuse (1 Mo maximum).' (Get-DomeniaBoardDocumentMessage -Message 'Export invalide ou trop volumineux (1 Mo maximum).')
    Assert-Equal 'choisissez un fichier .json.' (Get-DomeniaBoardDocumentMessage -Message 'Chemin de document non pris en charge.')
    Assert-Equal 'Accès refusé.' (Get-DomeniaBoardDocumentMessage -Message 'Accès refusé.')
}
Test-Case 'BRD-033' 'SP-07, SP-19, UI-14 : synonymes du catalogue, filtres par origine et catégorie, catégories accentuées' {
    $memory = [pscustomobject]@{ Source = 'Builtin'; Category = 'Identite du poste'; Search = (ConvertTo-DomeniaSearchText 'Memoire installee Memoire physique et barrettes Identite du poste') }
    $reboot = [pscustomobject]@{ Source = 'Builtin'; Category = 'Securite et etat'; Search = (ConvertTo-DomeniaSearchText 'Redemarrage en attente Redemarrage demande par une installation') }
    $probe = [pscustomobject]@{ Source = 'Probe'; Category = 'Matériel'; Search = (ConvertTo-DomeniaSearchText 'Barrettes mémoire Matériel Win32_PhysicalMemory') }
    $terms = @(Get-DomeniaBoardSearchTerms -Text 'RAM')
    Assert-Equal 1 $terms.Count
    Assert-True (@($terms[0].Forms) -contains 'memoire') 'RAM trouve Memoire'
    Assert-True (Test-DomeniaBoardSourceMatch -Row $memory -Terms $terms)
    Assert-True (Test-DomeniaBoardSourceMatch -Row $reboot -Terms @(Get-DomeniaBoardSearchTerms -Text 'Reboot')) 'reboot trouve le redemarrage en attente'
    Assert-False (Test-DomeniaBoardSourceMatch -Row $reboot -Terms @(Get-DomeniaBoardSearchTerms -Text 'RAM'))
    Assert-True (Test-DomeniaBoardSourceMatch -Row $memory -Terms @(Get-DomeniaBoardSearchTerms -Text 'ram installee')) 'chaque mot doit trouver une forme'
    Assert-False (Test-DomeniaBoardSourceMatch -Row $memory -Terms @(Get-DomeniaBoardSearchTerms -Text 'ram ssd'))
    foreach ($word in @('ssd','defender','ip','uptime','maj')) { Assert-True (@((Get-DomeniaBoardSearchTerms -Text $word)[0].Forms).Count -gt 1) ('synonyme absent : ' + $word) }
    Assert-Equal 0 @(Get-DomeniaBoardSearchTerms -Text '   ').Count 'recherche vide'
    Assert-True (Test-DomeniaBoardSourceMatch -Row $probe -Terms @() -Origin 'Probe' -Category 'Materiel') 'categorie comparee sans accents'
    Assert-False (Test-DomeniaBoardSourceMatch -Row $memory -Terms @() -Origin 'Probe') 'origine filtree'
    Assert-False (Test-DomeniaBoardSourceMatch -Row $memory -Terms @() -Category 'Securite et etat') 'categorie filtree'
    Assert-Equal 'Sécurité et état' (Get-DomeniaBoardCategoryLabel -Name 'Securite et etat')
    Assert-Equal 'Matériel' (Get-DomeniaBoardCategoryLabel -Name 'Materiel')
    Assert-Equal 'Santé' (Get-DomeniaBoardCategoryLabel -Name 'Santé') 'nom deja accentue garde'
}
Test-Case 'BRD-034' 'FO-13 : Ctrl+C copie le widget qui a le focus, Ctrl avec une autre touche reste à la fenêtre' {
    $copy = Get-DomeniaBoardKeyGesture -Key 'C' -Control $true
    Assert-Equal 'Copy' ([string]$copy.Action)
    Assert-Equal 'Copy' ([string](Get-DomeniaBoardKeyGesture -Key 'C' -Control $true -Editing $true).Action) 'aussi en personnalisation'
    Assert-Equal $null (Get-DomeniaBoardKeyGesture -Key 'C' -Control $true -Shift $true)
    Assert-Equal $null (Get-DomeniaBoardKeyGesture -Key 'V' -Control $true)
    Assert-Equal $null (Get-DomeniaBoardKeyGesture -Key 'C') 'C seul ne fait rien'
}
