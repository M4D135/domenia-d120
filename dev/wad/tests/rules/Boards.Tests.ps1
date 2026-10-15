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
    Assert-Equal (@(Get-DomeniaBoardCatalog -Board Computer).Count) $layout.Count
    Assert-Equal 'computer.health' ([string]$layout[0].Key)
    Assert-Equal 'Vue d ensemble' ([string]$layout[0].Group)
    # Lot L01: the home overview is delivered without the observation widgets nor any WMI query.
    $fleet = @(ConvertTo-DomeniaBoardLayout -Board Fleet -Json '')
    Assert-Equal 'fleet.health,fleet.attention,fleet.machines,fleet.enabled,fleet.accountstatus,fleet.stale,fleet.disabled,fleet.created,fleet.pwdold,fleet.laps,fleet.bitlocker,fleet.versions,fleet.eos,fleet.win10,fleet.os,fleet.lastlogon,fleet.ou' (@($fleet | ForEach-Object { [string]$_.Key }) -join ',')
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
    Assert-Equal (@(Get-DomeniaBoardCatalog -Board Computer).Count) @(ConvertTo-DomeniaBoardLayout -Board Computer -Json 'pas du json').Count 'texte illisible : disposition livree'
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
    Assert-Equal '2 point(s) a verifier' ([string]$list.Title)
    $calm = New-DomeniaBoardData -Board Fleet
    [void](Complete-DomeniaBoardData -Data $calm)
    Assert-Equal 'Rien a signaler' ([string]$calm.Entries['fleet.attention'].Title)
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
    Assert-Equal 'fleet.health,fleet.attention,fleet.machines' ((@(ConvertTo-DomeniaBoardLayout -Board Fleet -Json (ConvertTo-Json -InputObject $renamed -Depth 3 -Compress)) | Select-Object -First 3 | ForEach-Object { $_.Key }) -join ',') 'identifiants seuls differents : migree'
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
