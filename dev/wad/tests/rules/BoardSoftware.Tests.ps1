# Software board provider (dashboards made of widgets, decision David 2026-10-07): parity with the old synthesis
# of the software list (Update-DomeniaSoftwareDashboard). Fictitious products and publishers only: no network, no disk.
# The board contract and the provider are not in the launcher list: they are loaded here.
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-BoardSoftware.Model.ps1')
function New-DomeniaSoftwareBoardTestRow {
    param([string]$Name,[string]$Publisher = '',[string]$Version = '1.0',[string]$Architecture = '64 bits',[string]$Scope = 'Machine',$SizeKb = 0,[string]$InstallDate = '')
    return [pscustomobject]@{ Name = $Name; Publisher = $Publisher; Version = $Version; Architecture = $Architecture; Scope = $Scope; SizeKb = $SizeKb; InstallDate = $InstallDate }
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
        foreach ($key in @('software.count','software.size','software.multiversion','software.nopublisher','software.publishers','software.architecture','software.scope','software.largest','software.recent','software.runtime','software.browsers')) {
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
    Assert-Equal (Get-DomeniaBoardColor 'Other') ([string]$items[6].Color) 'Gris de la part Autres du rendu'
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
    Assert-Equal (Get-DomeniaBoardColor 'Other') ([string]$items[6].Color)
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

Test-Case -Id 'FO-09a' -Name 'Clic sur une part : les quatre colonnes connues filtrent, une valeur inconnue ne laisse rien passer' -Body {
    $row = New-DomeniaSoftwareBoardTestRow -Name 'Acme Reader' -Publisher 'Adobe' -Architecture '64 bits' -Scope 'Machine'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select $null) 'Sans selection, la liste reste entiere'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select ([pscustomobject]@{ Field = 'Publisher'; Value = 'adobe' })) 'Editeur : la casse ne compte pas'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select ([pscustomobject]@{ Field = 'Scope'; Value = 'Machine' })) 'Portee'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select ([pscustomobject]@{ Field = 'Name'; Value = '  Acme Reader  ' })) 'Nom : les espaces du libelle ne comptent pas'
    Assert-False (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select ([pscustomobject]@{ Field = 'Publisher'; Value = 'Contoso' })) 'Un autre editeur laisse la ligne passer'
    Assert-False (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select ([pscustomobject]@{ Field = 'Kind'; Value = 'Machine' })) 'Un champ que la liste na pas ne doit pas tout laisser passer'
    Assert-False (Test-DomeniaSoftwareRowMatchesSelect -Row $row -Select ([pscustomobject]@{ Field = 'Publisher'; Value = '   ' })) 'Un libelle vide ne doit rien filtrer du tout'
    Assert-False (Test-DomeniaSoftwareRowMatchesSelect -Row $null -Select ([pscustomobject]@{ Field = 'Publisher'; Value = 'Adobe' })) 'Une ligne vide est ecartee'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row (@{ Name = 'Acme Reader'; Publisher = 'Adobe' }) -Select ([pscustomobject]@{ Field = 'Publisher'; Value = 'Adobe' })) 'Une ligne lue en hashtable filtre comme un objet'
    Assert-False (Test-DomeniaSoftwareRowMatchesSelect -Row (@{ Name = 'Sans editeur' }) -Select ([pscustomobject]@{ Field = 'Publisher'; Value = 'Adobe' })) 'Une ligne sans le champ est filtree'
}

Test-Case -Id 'FO-09b' -Name 'Pastille et bascule : le second clic retire le filtre, un autre critere le remplace' -Body {
    $adobe = [pscustomobject]@{ Field = 'Publisher'; Value = 'Adobe' }
    Assert-Equal ('Filtr' + [char]0x00E9 + ' : Adobe') (Get-DomeniaSoftwareSelectLabel -Select $adobe) 'Texte de la pastille'
    Assert-Equal '' (Get-DomeniaSoftwareSelectLabel -Select $null) 'Sans filtre, la pastille ne se montre pas'
    Assert-Equal '' (Get-DomeniaSoftwareSelectLabel -Select ([pscustomobject]@{ Field = 'Publisher'; Value = '   ' })) 'Un libelle vide ne se montre pas'
    $first = Get-DomeniaSoftwareSelectToggle -Current $null -Incoming $adobe
    Assert-Equal 'Publisher' ([string]$first.Field) 'Le premier clic installe le filtre'
    Assert-Equal 'Adobe' ([string]$first.Value) 'Le filtre garde le critere clique'
    Assert-True ($null -eq (Get-DomeniaSoftwareSelectToggle -Current $first -Incoming $adobe)) 'Le second clic sur la meme part retire le filtre'
    Assert-True ($null -eq (Get-DomeniaSoftwareSelectToggle -Current $first -Incoming ([pscustomobject]@{ Field = 'Publisher'; Value = 'adobe' }))) 'La meme part ecrite autrement reste la meme part'
    $replaced = Get-DomeniaSoftwareSelectToggle -Current $first -Incoming ([pscustomobject]@{ Field = 'Scope'; Value = 'Machine' })
    Assert-Equal 'Scope' ([string]$replaced.Field) 'Un autre critere remplace le precedent'
    Assert-True ($null -eq (Get-DomeniaSoftwareSelectToggle -Current $first -Incoming $null)) 'Un clic sans critere ne laisse aucun filtre'
    Assert-True ($null -eq (Get-DomeniaSoftwareSelectToggle -Current $first -Incoming ([pscustomobject]@{ Field = ''; Value = 'Adobe' }))) 'Un critere sans champ ne filtre rien'
}

Test-Case -Id 'FO-09c' -Name 'Le fournisseur publie le critere de clic de chaque part, jamais sur la part Autres' -Body {
    $rows = @(for ($p = 1; $p -le 8; $p++) { for ($n = 1; $n -le (9 - $p); $n++) { New-DomeniaSoftwareBoardTestRow -Name ('Produit ' + $p + '-' + $n) -Publisher ('Editeur ' + $p) -Architecture '64 bits' -Scope 'Machine' } })
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $items = @($d.Entries['software.publishers'].Items)
    Assert-Equal 'Publisher' ([string]$items[0].Select.Field) 'Un editeur cliquable porte le champ qui le filtre'
    Assert-Equal 'Editeur 1' ([string]$items[0].Select.Value) 'Le critere est le libelle de la part'
    Assert-True ($null -eq $items[6].PSObject.Properties['Select']) 'La part Autres ne porte aucun critere : elle melange plusieurs editeurs'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $rows[0] -Select $items[0].Select) 'Le critere publie retrouve bien sa ligne'
    $arch = @($d.Entries['software.architecture'].Items)
    Assert-Equal 'Architecture' ([string]$arch[0].Select.Field) 'Lanneau Architecture filtre sur sa colonne'
    Assert-Equal '64 bits' ([string]$arch[0].Select.Value)
    $scopes = @($d.Entries['software.scope'].Items)
    Assert-Equal 'Scope' ([string]$scopes[0].Select.Field) 'Lanneau Portee filtre sur sa colonne'
    # Le libelle d'une barre peut porter une version et une portee ajoutees pour distinguer deux barres :
    # le critere, lui, reste le nom du logiciel.
    $twins = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Double' -Publisher 'Adobe' -Version '1.0' -SizeKb 2048),
        (New-DomeniaSoftwareBoardTestRow -Name 'Double' -Publisher 'Adobe' -Version '2.0' -SizeKb 1024)
    )
    $bars = @((Get-DomeniaSoftwareBoardData -Rows $twins).Entries['software.largest'].Items)
    Assert-Equal 2 $bars.Count 'Deux barres'
    Assert-Equal 'Name' ([string]$bars[0].Select.Field) 'La barre filtre sur le nom du logiciel'
    Assert-Equal 'Double' ([string]$bars[0].Select.Value)
    Assert-True ([string]$bars[0].Label -ne [string]$bars[0].Select.Value) 'Le libelle habille de la barre ne devient pas le critere'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $twins[0] -Select $bars[0].Select) 'Le critere de la barre retrouve bien ses lignes'
}

Test-Case -Id 'FO-09d' -Name 'Les parts qui inventent une valeur ne publient aucun critere de clic' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Sans editeur' -Publisher '' -Architecture '' -Scope ''),
        (New-DomeniaSoftwareBoardTestRow -Name 'Avec editeur' -Publisher 'Adobe' -Architecture '64 bits' -Scope 'Machine')
    )
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $pub = @($d.Entries['software.publishers'].Items | Where-Object { [string]$_.Label -eq 'Editeur non renseigne' })
    Assert-Equal 1 $pub.Count 'La part de l editeur inconnu se montre'
    Assert-True ($null -eq $pub[0].PSObject.Properties['Select']) 'Cliquer l editeur inconnu laisserait la liste vide : aucun critere ne doit la proposer'
    $arch = @($d.Entries['software.architecture'].Items | Where-Object { [string]$_.Label -eq 'Non precise' })
    Assert-Equal 1 $arch.Count 'La part de l architecture absente se montre'
    Assert-True ($null -eq $arch[0].PSObject.Properties['Select']) 'Cliquer une architecture absente laisserait la liste vide'
    $scope = @($d.Entries['software.scope'].Items | Where-Object { [string]$_.Label -eq 'Non precise' })
    Assert-Equal 1 $scope.Count 'La part de la portee absente se montre'
    Assert-True ($null -eq $scope[0].PSObject.Properties['Select']) 'Cliquer une portee absente laisserait la liste vide'
    $reelle = @($d.Entries['software.publishers'].Items | Where-Object { [string]$_.Label -eq 'Adobe' })
    Assert-Equal 1 $reelle.Count 'La part d un vrai editeur se montre'
    Assert-Equal 'Publisher' ([string]$reelle[0].Select.Field) 'Une part qui porte une valeur des lignes reste cliquable'
    Assert-True (Test-DomeniaSoftwareRowMatchesSelect -Row $rows[1] -Select $reelle[0].Select) 'Le critere publie retrouve bien sa ligne'
}

Test-Case -Id 'FO-15a' -Name 'Installés ces 30 derniers jours : borne à 30 jours incluse, dates absentes comptées à part' -Body {
    $now = [datetime]::new(2026, 10, 8)
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Recent' -InstallDate '01/10/2026'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Borne' -InstallDate '08/09/2026'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Vieux' -InstallDate '07/09/2026'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Sans date')
    )
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows -Now $now).Entries['software.recent']
    Assert-Equal 'Value' $e.Kind
    Assert-Equal '2' $e.Value
    Assert-Equal 'Dernier : Recent, 01/10/2026 · dates connues pour 3 sur 4' $e.Detail
    $seul = Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Annoté' -InstallDate '02/01/2026')) -Now $now
    Assert-Equal '0' $seul.Entries['software.recent'].Value
    Assert-Equal 'Ok' $seul.Entries['software.recent'].State
    Assert-Equal 'Rien dʼinstallé dans les 30 derniers jours' $seul.Entries['software.recent'].Detail
    $aucune = Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Sans date')) -Now $now
    Assert-Equal 'Sans date' $aucune.Entries['software.recent'].Value
    Assert-Equal 'Off' $aucune.Entries['software.recent'].State
    Assert-Equal 'Aucun logiciel lu ne déclare de date dʼinstallation' $aucune.Entries['software.recent'].Detail
    $date = Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Format brut' -InstallDate ([datetime]::new(2026, 10, 1)))) -Now $now
    Assert-Equal '1' $date.Entries['software.recent'].Value 'Une date rendue par le worker comme un objet se lit'
}
Test-Case -Id 'FO-15b' -Name 'Composants dʼexécution : familles comptées sur le nom déclaré, WebView2 compte comme composant' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.36.42' -Publisher 'Microsoft Corporation' -Version '14.36.42'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.30501' -Publisher 'Microsoft Corporation' -Version '12.0.30501'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Microsoft .NET Runtime 8.0.10'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Microsoft Edge WebView2 Runtime' -Version '129.0.2792.89'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Outil metier' -Publisher 'Contoso')
    )
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.runtime']
    Assert-Equal '4' $e.Value
    Assert-Equal 'Visual C++ 2, .NET 1, WebView2 1' $e.Detail
    Assert-Equal '' $e.State
    $seul = (Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Outil metier'))).Entries['software.runtime']
    Assert-Equal 'Aucun' $seul.Value
    Assert-Equal 'Off' $seul.State
    Assert-Equal 'Aucun socle Visual C++, .NET ou WebView2 dans la liste lue' $seul.Detail
    $doublon = (Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Microsoft .NET Runtime 8.0.10' -Scope 'Machine'), (New-DomeniaSoftwareBoardTestRow -Name 'Microsoft .NET Runtime 8.0.10' -Scope 'Utilisateur'))).Entries['software.runtime']
    Assert-Equal '1' $doublon.Value 'La meme version lue dans deux portees compte une fois'
}
Test-Case -Id 'FO-15c' -Name 'Navigateurs et versions : un nom par navigateur, version majeure et mineure seulement' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Google Chrome' -Version '129.0.6668.100'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Mozilla Firefox' -Version '130.0.1'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Microsoft Edge' -Version '129.0.2792.89'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Chromium' -Version '128.0.0.0'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Navigateur sans version')
    )
    $e = (Get-DomeniaSoftwareBoardData -Rows $rows).Entries['software.browsers']
    Assert-Equal '4' $e.Value
    Assert-Equal 'Chrome 129.0, Chromium 128.0, Edge 129.0, Firefox 130.0' $e.Detail
    $seul = (Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Outil metier'))).Entries['software.browsers']
    Assert-Equal 'Aucun' $seul.Value
    Assert-Equal 'Off' $seul.State
    Assert-Equal 'Aucun navigateur reconnu dans la liste lue' $seul.Detail
    $sansVersion = (Get-DomeniaSoftwareBoardData -Rows @((New-DomeniaSoftwareBoardTestRow -Name 'Mozilla Firefox' -Version ''))).Entries['software.browsers']
    Assert-Equal 'Firefox' $sansVersion.Detail 'Une version absente ne fabrique pas un numero'
}
Test-Case -Id 'FO-15d' -Name 'Tuiles à 0 réduites à une coche ; famille inconnue rendue nulle, jamais devinée' -Body {
    $propres = @((New-DomeniaSoftwareBoardTestRow -Name 'Alpha' -Publisher 'Contoso' -Version '1.0'))
    $d = Get-DomeniaSoftwareBoardData -Rows $propres
    Assert-Equal 'Ok' $d.Entries['software.multiversion'].State
    Assert-Equal 'Ok' $d.Entries['software.nopublisher'].State
    $doubles = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Alpha' -Publisher 'Contoso' -Version '1.0'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Alpha' -Publisher 'Contoso' -Version '2.0'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Beta')
    )
    $d = Get-DomeniaSoftwareBoardData -Rows $doubles
    Assert-Equal 'Warn' $d.Entries['software.multiversion'].State
    Assert-Equal 'Warn' $d.Entries['software.nopublisher'].State
    Assert-True ($null -eq (Get-DomeniaSoftwareFamily -Name 'Outil metier' -Publisher 'Contoso')) 'Hors famille : rien d invente'
    Assert-True ($null -eq (Get-DomeniaSoftwareFamily -Name '' -Publisher '   ')) 'Nom vide : rien d invente'
    $famille = Get-DomeniaSoftwareFamily -Name 'Mozilla Firefox'
    Assert-Equal 'Browser' $famille.Family
    Assert-Equal 'Firefox' $famille.Label
    $famille = Get-DomeniaSoftwareFamily -Name 'Runtime' -Publisher 'Microsoft Visual C++ 2013 Redistributable'
    Assert-Equal 'Runtime' $famille.Family
    Assert-Equal 'Visual C++' $famille.Label
}
Test-Case -Id 'BS-091' -Name 'Point 91 : meme logiciel et meme version installes deux fois, architecture et portee nommees' -Body {
    $rows = @(
        (New-DomeniaSoftwareBoardTestRow -Name 'Contoso Agent' -Publisher 'Contoso' -Version '2.1' -Architecture 'x64'),
        (New-DomeniaSoftwareBoardTestRow -Name 'contoso agent' -Publisher 'Contoso' -Version '2.1' -Architecture 'x86'),
        (New-DomeniaSoftwareBoardTestRow -Name 'Fabrikam Viewer' -Publisher 'Fabrikam' -Version '1.0'))
    $d = Get-DomeniaSoftwareBoardData -Rows $rows
    $entry = $d.Entries['software.duplicates']
    Assert-Equal '1' ([string]$entry.Value)
    Assert-Equal 'Contoso Agent : Machine x64 ; Machine x86' ([string]$entry.Detail)
    $user = [pscustomobject]@{ Name = 'Fabrikam Viewer'; Publisher = 'Fabrikam'; Version = '1.0'; Architecture = ''; Scope = 'Utilisateur'; Kind = 'EX\jdupont'; SizeKb = 0; InstallDate = '' }
    $mixed = Get-DomeniaSoftwareBoardData -Rows @($rows[2], $user)
    Assert-Equal 'Fabrikam Viewer : Machine 64 bits ; Utilisateur EX\jdupont' ([string]$mixed.Entries['software.duplicates'].Detail)
    $none = Get-DomeniaSoftwareBoardData -Rows @($rows[0], $rows[2])
    Assert-Equal 'Aucune installation en double' ([string]$none.Entries['software.duplicates'].Detail)
}
