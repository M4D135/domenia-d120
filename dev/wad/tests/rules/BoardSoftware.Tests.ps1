# Software board provider (dashboards made of widgets, decision David 2026-10-07): parity with the old synthesis
# of the software list (Update-DomeniaSoftwareDashboard). Fictitious products and publishers only: no network, no disk.
# The board contract and the provider are not in the launcher list: they are loaded here.
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-BoardSoftware.Model.ps1')
function New-DomeniaSoftwareBoardTestRow {
    param([string]$Name,[string]$Publisher = '',[string]$Version = '1.0',[string]$Architecture = '64 bits',[string]$Scope = 'Machine',$SizeKb = 0)
    return [pscustomobject]@{ Name = $Name; Publisher = $Publisher; Version = $Version; Architecture = $Architecture; Scope = $Scope; SizeKb = $SizeKb }
}
function Get-DomeniaSoftwareBoardTestColored {
    # Items that carry their own colour property (the renderer keeps their order and colours).
    param($Entry)
    return @(@($Entry.Items) | Where-Object { $null -ne $_.PSObject.Properties['Color'] })
}

Test-Case -Id 'BS-001' -Name 'Aucun logiciel : aucune tuile, sections expliquees, resume Aucun logiciel lu' -Body {
    $cases = @($null, @(), @($null, (New-DomeniaSoftwareBoardTestRow -Name '   '), [pscustomobject]@{ Publisher = 'Contoso' }, 'texte brut'))
    foreach ($rows in $cases) {
        $d = Get-DomeniaSoftwareBoardData -Rows $rows
        Assert-False ($d -is [array]) 'Un seul objet attendu'
        Assert-Equal 'Software' $d.Board
        Assert-Equal 'Aucun logiciel lu.' $d.Summary
        foreach ($key in @('software.count','software.size','software.multiversion','software.nopublisher','software.publishers','software.architecture','software.scope','software.largest')) {
            Assert-False $d.Entries.ContainsKey($key) ('Tuile sans donnees : ' + $key)
        }
        Assert-True ([string]$d.Hints['Synthese'] -match 'chargez les logiciels') 'Indication Synthese'
        Assert-True ([string]$d.Hints['Repartition'] -match 'chargez les logiciels') 'Indication Repartition'
        Assert-True $d.Entries.ContainsKey('software.health') 'Complete-DomeniaBoardData appele'
        Assert-True $d.Entries.ContainsKey('software.attention') 'Complete-DomeniaBoardData appele'
    }
}
Test-Case -Id 'BS-002' -Name 'Logiciels : nombre, editeurs declares sans le groupe non renseigne, resume' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Alpha' -Publisher 'Contoso'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Beta' -Publisher 'contoso'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Gamma' -Publisher 'Fabrikam'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Delta' -Publisher ''),
        (New-DomeniaSoftwareBoardTestRow -Name 'Epsilon' -Publisher '   ')
    )
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $count = $d.Entries['software.count']
    Assert-Equal 'Value' $count.Kind
    Assert-Equal '5' $count.Value
    Assert-Equal '2 editeurs' $count.Detail 'Contoso (casse ignoree) et Fabrikam'
    Assert-Equal '' $count.Title 'Titre du catalogue'
    Assert-Equal '5 logiciels lus. Synthese calculee sur la liste chargee.' $d.Summary
    Assert-Equal 0 $d.Hints.Count 'Aucune section vide'
    $one = Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Seul' -Publisher 'Contoso'))
    Assert-Equal '1 editeur' $one.Entries['software.count'].Detail
    Assert-Equal '1 logiciel lu. Synthese calculee sur la liste chargee.' $one.Summary
    $none = Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Anonyme'))
    Assert-Equal 'Aucun editeur declare' $none.Entries['software.count'].Detail
}
Test-Case -Id 'BS-003' -Name 'Editeurs : six premiers puis Autres en gris ardoise, distinct du gris non renseigne' -Body {
    $rows = @(for ($p = 1; $p -le 8; $p++) { for ($n = 1; $n -le (9 - $p); $n++) { New-DomeniaSoftwareBoardTestRow -Name ('Produit ' + $p + '-' + $n) -Publisher ('Editeur ' + $p) } })
    Assert-Equal 36 $rows.Count 'Jeu de test'
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.publishers']
    Assert-Equal 'Distribution' $e.Kind
    $items = @($e.Items)
    Assert-Equal 7 $items.Count 'Six editeurs + Autres'
    Assert-Equal 'Editeur 1' ([string]$items[0].Label)
    Assert-Equal 8 ([double]$items[0].Value)
    Assert-Equal 'Editeur 6' ([string]$items[5].Label)
    Assert-Equal 3 ([double]$items[5].Value)
    Assert-Equal 'Autres' ([string]$items[6].Label)
    Assert-Equal 3 ([double]$items[6].Value) 'Editeurs 7 (2) et 8 (1)'
    Assert-Equal '#94A3B8' ([string]$items[6].Color) 'Gris de la part Autres du rendu'
    Assert-Equal 1 @(Get-DomeniaSoftwareBoardTestColored $e).Count 'Seule la part Autres porte une couleur'
    Assert-Equal 'Editeur 1' $e.Value
    Assert-Equal '8 logiciels sur 36' $e.Detail
    Assert-Equal '36 logiciels' $e.CenterText
    # Unknown publisher in the top 6 and an "Autres" part together: two meanings, two different greys.
    $rows += @(for ($n = 1; $n -le 5; $n++) { New-DomeniaSoftwareBoardTestRow -Name ('Sans editeur ' + $n) })
    $items = @((Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.publishers'].Items)
    Assert-Equal 7 $items.Count 'Six groupes + Autres'
    Assert-Equal 'Editeur non renseigne' ([string]$items[4].Label) 'Egalite 5/5 avec Editeur 4 : ordre alphabetique'
    Assert-Equal (Get-DomeniaBoardColor 'Off') ([string]$items[4].Color)
    Assert-Equal 'Autres' ([string]$items[6].Label)
    Assert-Equal 6 ([double]$items[6].Value) 'Editeurs 6 (3), 7 (2) et 8 (1)'
    Assert-Equal '#94A3B8' ([string]$items[6].Color)
    Assert-True ([string]$items[4].Color -ne [string]$items[6].Color) 'Non renseigne et Autres : couleurs differentes'
}
Test-Case -Id 'BS-004' -Name 'Editeurs : pas de part Autres jusqu a six, egalites triees par nom, non renseigne en gris' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Z1' -Publisher 'Zeta'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Z2' -Publisher 'Zeta'),
        (New-DomeniaSoftwareBoardTestRow -Name 'A1' -Publisher 'Alpha'),
        (New-DomeniaSoftwareBoardTestRow -Name 'A2' -Publisher 'Alpha'),
        (New-DomeniaSoftwareBoardTestRow -Name 'F1' -Publisher 'Fabrikam')
    )
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.publishers']
    $items = @($e.Items)
    Assert-Equal 3 $items.Count
    Assert-Equal 'Alpha' ([string]$items[0].Label) 'Egalite : ordre alphabetique, stable d un appel a l autre'
    Assert-Equal 'Zeta' ([string]$items[1].Label)
    Assert-Equal 0 @($items | Where-Object { [string]$_.Label -eq 'Autres' }).Count
    Assert-Equal 0 @(Get-DomeniaSoftwareBoardTestColored $e).Count 'Aucune couleur sans signification'
    Assert-Equal 'Alpha' $e.Value
    Assert-Equal '2 logiciels sur 5' $e.Detail
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Sans editeur 1'
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Sans editeur 2'
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Sans editeur 3'
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.publishers']
    $items = @($e.Items)
    Assert-Equal 'Editeur non renseigne' ([string]$items[0].Label)
    Assert-Equal (Get-DomeniaBoardColor 'Off') ([string]$items[0].Color)
    Assert-Equal 'Editeur non renseigne' $e.Value
    Assert-Equal '3 logiciels sur 8' $e.Detail
}
Test-Case -Id 'BS-005' -Name 'Architecture et portee : valeurs vides Non precise en gris, part dominante en figure' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'P1' -Architecture '64 bits' -Scope 'Machine'),
        (New-DomeniaSoftwareBoardTestRow -Name 'P2' -Architecture '64 bits' -Scope 'Utilisateur'),
        (New-DomeniaSoftwareBoardTestRow -Name 'P3' -Architecture '64 bits' -Scope 'Utilisateur'),
        (New-DomeniaSoftwareBoardTestRow -Name 'P4' -Architecture '32 bits' -Scope 'Machine'),
        (New-DomeniaSoftwareBoardTestRow -Name 'P5' -Architecture '' -Scope 'Store')
    )
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $arch = $d.Entries['software.architecture']
    $items = @($arch.Items)
    Assert-Equal 3 $items.Count
    Assert-Equal '64 bits' ([string]$items[0].Label)
    Assert-Equal 3 ([double]$items[0].Value)
    Assert-Equal '32 bits' ([string]$items[1].Label) 'Egalite 1/1 : ordre alphabetique'
    Assert-Equal 'Non precise' ([string]$items[2].Label)
    Assert-Equal (Get-DomeniaBoardColor 'Off') ([string]$items[2].Color)
    Assert-Equal '64 bits' $arch.Value
    Assert-Equal '3 logiciels sur 5' $arch.Detail
    Assert-Equal '5 logiciels' $arch.CenterText
    $scope = $d.Entries['software.scope']
    $labels = @(@($scope.Items) | ForEach-Object { [string]$_.Label })
    Assert-Equal 'Machine|Utilisateur|Store' ($labels -join '|')
    Assert-Equal 'Machine' $scope.Value
    Assert-Equal '2 logiciels sur 5' $scope.Detail
    Assert-Equal 0 @(Get-DomeniaSoftwareBoardTestColored $scope).Count
}
Test-Case -Id 'BS-006' -Name 'Plusieurs versions : nom sans casse, meme version dans deux portees ignoree, le plus duplique d abord' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil A' -Version '1.0' -Scope 'Machine'),
        (New-DomeniaSoftwareBoardTestRow -Name 'outil a' -Version '2.0' -Scope 'Utilisateur'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil B' -Version '3.1' -Scope 'Machine'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil B' -Version '3.1' -Scope 'Utilisateur'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil C' -Version '1'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil C' -Version '2'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil C' -Version '3')
    )
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.multiversion']
    Assert-Equal 'Value' $e.Kind
    Assert-Equal '2' $e.Value
    Assert-Equal 'Outil C et 1 autre(s)' $e.Detail
    $e = (Get-DomeniaSoftwareBoardData -Rows @($rows | Select-Object -First 4)).Entries['software.multiversion']
    Assert-Equal '1' $e.Value
    Assert-Equal 'Outil A : 2 versions' $e.Detail
    $e = (Get-DomeniaSoftwareBoardData -Rows @($rows | Select-Object -Skip 2 -First 2)).Entries['software.multiversion']
    Assert-Equal '0' $e.Value
    Assert-Equal 'Aucun doublon de version' $e.Detail
}
Test-Case -Id 'BS-007' -Name 'Sans editeur declare : nombre et premier nom, sinon tous renseignes' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Connu' -Publisher 'Contoso'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Inconnu 1' -Publisher ''),
        (New-DomeniaSoftwareBoardTestRow -Name 'Inconnu 2' -Publisher '  ')
    )
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.nopublisher']
    Assert-Equal '2' $e.Value
    Assert-Equal 'Inconnu 1 et 1 autre(s)' $e.Detail
    $e = (Get-DomeniaSoftwareBoardData -Rows @($rows | Select-Object -First 2)).Entries['software.nopublisher']
    Assert-Equal '1' $e.Value
    Assert-Equal 'Inconnu 1' $e.Detail
    $e = (Get-DomeniaSoftwareBoardData -Rows @($rows | Select-Object -First 1)).Entries['software.nopublisher']
    Assert-Equal '0' $e.Value
    Assert-Equal 'Tous les editeurs sont renseignes' $e.Detail
}
Test-Case -Id 'BS-008' -Name 'Taille declaree et plus gros logiciels : tailles connues seulement, huit premiers en Mo' -Body {
    $rows = @(for ($i = 1; $i -le 10; $i++) { New-DomeniaSoftwareBoardTestRow -Name ('Gros ' + $i) -Publisher 'Contoso' -SizeKb ([double]($i * 20480)) })
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Sans taille' -SizeKb 0
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Taille invalide' -SizeKb 'abc'
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Taille negative' -SizeKb (-5)
    $rows += New-DomeniaSoftwareBoardTestRow -Name 'Taille texte' -SizeKb '2048'
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $size = $d.Entries['software.size']
    Assert-Equal (Format-DomeniaDashboardSize ((20480.0 * 55 + 2048) * 1KB)) $size.Value
    Assert-Equal 'Somme des tailles connues (11 sur 14)' $size.Detail
    $e = $d.Entries['software.largest']
    Assert-Equal 'Distribution' $e.Kind
    Assert-Equal 'Mo' $e.Unit
    $items = @($e.Items)
    Assert-Equal 8 $items.Count
    Assert-Equal 'Gros 10' ([string]$items[0].Label)
    Assert-Equal 200 ([double]$items[0].Value)
    Assert-Equal 'Gros 3' ([string]$items[7].Label)
    Assert-Equal 60 ([double]$items[7].Value)
    Assert-Equal 0 @(Get-DomeniaSoftwareBoardTestColored $e).Count 'Une seule serie : couleur d accent du rendu'
    Assert-Equal 'Gros 10' $e.Value
    Assert-Equal (Format-DomeniaDashboardSize (204800.0 * 1KB)) $e.Detail
    $all = @($rows | ForEach-Object { New-DomeniaSoftwareBoardTestRow -Name $_.Name -Publisher 'Contoso' -SizeKb 0 })
    $d = Get-DomeniaSoftwareBoardData -Rows $all
    $full = Get-DomeniaSoftwareBoardData -Rows @($rows | Select-Object -First 3)
    Assert-Equal 'Somme des tailles connues' $full.Entries['software.size'].Detail 'Toutes les tailles connues'
    Assert-False $d.Entries.ContainsKey('software.size') 'Aucune taille : tuile omise'
    Assert-False $d.Entries.ContainsKey('software.largest') 'Aucune taille : graphique omis'
    Assert-True $d.Entries.ContainsKey('software.count')
}
Test-Case -Id 'BS-009' -Name 'Plus gros logiciels : petites tailles a une decimale, homonymes distingues par version, portee, architecture' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Petit' -SizeKb 512),
        (New-DomeniaSoftwareBoardTestRow -Name 'Suite' -Version '2.0' -SizeKb 40960),
        (New-DomeniaSoftwareBoardTestRow -Name 'suite' -Version '1.0' -SizeKb 30720)
    )
    $items = @((Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.largest'].Items)
    Assert-Equal 3 $items.Count
    Assert-Equal 'Suite 2.0' ([string]$items[0].Label)
    Assert-Equal 40 ([double]$items[0].Value)
    Assert-Equal 'suite 1.0' ([string]$items[1].Label)
    Assert-Equal 'Petit' ([string]$items[2].Label)
    Assert-Equal 0.5 ([double]$items[2].Value)
    # Same name and version in two scopes, then same scope in two architectures: labels stay distinct
    # and do not depend on the input order (every field breaks ties).
    $twins = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil B' -Version '3.1' -Scope 'Machine' -SizeKb 20480),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil B' -Version '3.1' -Scope 'Utilisateur' -SizeKb 20480),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil D' -Version '' -Scope 'Machine' -Architecture '64 bits' -SizeKb 10240),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil D' -Version '' -Scope 'Machine' -Architecture '32 bits' -SizeKb 10240)
    )
    $expected = 'Outil B 3.1 (Machine)|Outil B 3.1 (Utilisateur)|Outil D (Machine, 32 bits)|Outil D (Machine, 64 bits)'
    foreach ($rows in @(,$twins) + @(,@($twins[3], $twins[2], $twins[1], $twins[0]))) {
        $labels = @(@((Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.largest'].Items) | ForEach-Object { [string]$_.Label })
        Assert-Equal $expected ($labels -join '|')
    }
}
Test-Case -Id 'BS-010' -Name 'Lignes incompletes ou en table de hachage lues sans erreur sous StrictMode' -Body {
    $rows = @(
        [pscustomobject]@{ Name = 'Seul nom' },
        @{ Name = 'Table de hachage'; Publisher = 'Contoso'; SizeKb = 1024 },
        [pscustomobject]@{ Name = 'Taille absente'; Publisher = 'Fabrikam'; Version = $null; SizeKb = $null }
    )
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    Assert-Equal '3' $d.Entries['software.count'].Value
    Assert-Equal '1' $d.Entries['software.nopublisher'].Value
    Assert-Equal 'Seul nom' $d.Entries['software.nopublisher'].Detail
    Assert-Equal (Format-DomeniaDashboardSize (1024.0 * 1KB)) $d.Entries['software.size'].Value
    Assert-Equal 'Somme des tailles connues (1 sur 3)' $d.Entries['software.size'].Detail
    $arch = @($d.Entries['software.architecture'].Items)
    Assert-Equal 1 $arch.Count
    Assert-Equal 'Non precise' ([string]$arch[0].Label)
    Assert-Equal 'Table de hachage' ([string]@($d.Entries['software.largest'].Items)[0].Label)
}
Test-Case -Id 'BS-011' -Name 'Un seul logiciel : objet unique, listes non deroulees, textes au singulier' -Body {
    $d = Get-DomeniaSoftwareBoardData -Rows (New-DomeniaSoftwareBoardTestRow -Name 'Unique' -Publisher 'Contoso' -SizeKb 2048)
    Assert-False ($d -is [array])
    foreach ($key in @('software.publishers','software.architecture','software.scope','software.largest')) {
        Assert-True ($d.Entries[$key].Items -is [array]) ('Items en tableau : ' + $key)
        Assert-Equal 1 @($d.Entries[$key].Items).Count $key
    }
    Assert-Equal '1 logiciel' $d.Entries['software.publishers'].CenterText
    Assert-Equal '1 logiciel sur 1' $d.Entries['software.publishers'].Detail
}
Test-Case -Id 'BS-012' -Name 'Cles du catalogue uniquement, aucun point d attention (comme l ancien tableau), sante complete' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Alpha' -Publisher 'Contoso' -SizeKb 4096),
        (New-DomeniaSoftwareBoardTestRow -Name 'Alpha' -Publisher 'Contoso' -Version '2.0' -SizeKb 4096),
        (New-DomeniaSoftwareBoardTestRow -Name 'Beta' -Architecture '32 bits' -Scope 'Utilisateur')
    )
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $catalog = @(Get-DomeniaBoardCatalog -Board Software | ForEach-Object { [string]$_.Key })
    foreach ($key in @($d.Entries.Keys)) {
        Assert-True (($catalog -contains $key) -or ($key -in @('software.health','software.attention'))) ('Cle hors catalogue : ' + $key)
        Assert-Equal $key ([string]$d.Entries[$key].Key)
    }
    foreach ($key in $catalog) { Assert-True $d.Entries.ContainsKey($key) ('Cle du catalogue remplie : ' + $key) }
    Assert-Equal 0 @($d.Attention).Count
    Assert-Equal 100 ([int]$d.Entries['software.health'].Number)
    Assert-Equal 'Ok' $d.Entries['software.health'].State
}
