# Tableaux de bord en widgets (decision David 2026-10-07) : catalogue, representations par type de donnee,
# tailles, disposition enregistree et migration des widgets de la premiere version. Regles pures, aucune interface.
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
    Assert-Equal 'fleet.health,fleet.attention,fleet.machines,fleet.stale,fleet.disabled,fleet.created,fleet.pwdold,fleet.laps,fleet.bitlocker,fleet.versions,fleet.eos,fleet.os,fleet.lastlogon,fleet.ou' (@($fleet | ForEach-Object { [string]$_.Key }) -join ',')
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
    Assert-Equal '22 postes sur 26 sans problème' $h.Detail
    Assert-Equal 'Bon état' (Get-DomeniaFleetHealth -Total 10 -Healthy 9 -Attention $warn).Verdict
    Assert-Equal 'Dégradé' (Get-DomeniaFleetHealth -Total 4 -Healthy 2 -Attention $warn).Verdict
    Assert-Equal 'Alert' (Get-DomeniaFleetHealth -Total 4 -Healthy 2 -Attention $warn).State
    $critical = Get-DomeniaFleetHealth -Total 2000 -Healthy 1999 -Attention @([pscustomobject]@{ Level = 'Alert'; Text = 'x' })
    Assert-Equal 99 $critical.Score 'Un poste sur 2000 ne fait pas tomber le score'
    Assert-Equal 'Critique' $critical.Verdict
    Assert-Equal 'Bon état' (Get-DomeniaFleetHealth -Total 0 -Healthy 0).Verdict
    $data = New-DomeniaBoardData -Board Fleet
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Population' -Value ([pscustomobject]@{ Total = 26; Healthy = 22 })
    Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'Quatre postes inactifs.'
    [void](Complete-DomeniaBoardData -Data $data)
    Assert-Equal 84 $data.Entries['fleet.health'].Number
    Assert-Equal '22 postes sur 26 sans problème' ([string]$data.Entries['fleet.health'].Detail)
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
