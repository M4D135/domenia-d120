# Point 129 : parcours graphiques natifs. Regles du banc (pas d UI Automation ici) : contenu des parcours, captures
# 1920x1080 sans infobulle, releve humain separe des evenements simules. Donnees fictives uniquement.
$script:GuiFile = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures') 'Domenia-GuiJourney.ps1'
. $script:GuiFile
$script:GuiDefinitionFile = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) (Join-Path 'engineering' (Join-Path 'd120' (Join-Path 'lab' 'gui-journeys.json')))
function New-GuiTestDefinition {
    return [pscustomobject]@{ Schema='DomeniaGuiJourneys/1'; Journeys=@(
        [pscustomobject]@{ Id='navigation'; Label='Navigation'; Steps=@(
            [pscustomobject]@{ Kind='Window'; State='Normal1080' },
            [pscustomobject]@{ Kind='Click'; Id='BtnUxNavSearch' },
            [pscustomobject]@{ Kind='Type'; Text='pc-01' },
            [pscustomobject]@{ Kind='Keys'; Keys=@('Enter','Shift+Tab','Ctrl+Home') },
            [pscustomobject]@{ Kind='Scroll'; Id='DgObjects'; Notches=-3 },
            [pscustomobject]@{ Kind='Capture'; Name='recherche' }) }) }
}

Test-Case 'P129' 'Parcours graphiques : touches de la liste fermee, modificateurs explicites' {
    $tab = ConvertTo-DomeniaGuiKeyChord 'Tab'
    Assert-Equal 9 ([int]$tab.VirtualKey); Assert-False $tab.Shift; Assert-False $tab.Control
    $back = ConvertTo-DomeniaGuiKeyChord 'Shift+Tab'
    Assert-True $back.Shift; Assert-Equal 9 ([int]$back.VirtualKey)
    $find = ConvertTo-DomeniaGuiKeyChord 'Ctrl+F'
    Assert-True $find.Control; Assert-Equal 70 ([int]$find.VirtualKey)
    Assert-Equal 36 ([int](ConvertTo-DomeniaGuiKeyChord 'Ctrl+Shift+Home').VirtualKey)
    Assert-Throws { ConvertTo-DomeniaGuiKeyChord 'Alt+F4' } 'Alt+F4 ferme la fenetre : hors liste'
    Assert-Throws { ConvertTo-DomeniaGuiKeyChord 'F' } 'Une lettre seule passe par une saisie de texte'
    Assert-Throws { ConvertTo-DomeniaGuiKeyChord 'Shift+Shift+Tab' } 'Modificateur en double'
    Assert-Throws { ConvertTo-DomeniaGuiKeyChord 'Win+R' } 'Touche Windows refusee'
}
Test-Case 'P129' 'Parcours graphiques : texte saisi independant de la disposition du clavier' {
    Assert-Equal 'pc-01' (Test-DomeniaGuiTypedText 'pc-01')
    Assert-Equal 'Élodie Dupont' (Test-DomeniaGuiTypedText 'Élodie Dupont')
    Assert-Equal 'EX\alex.demo' (Test-DomeniaGuiTypedText 'EX\alex.demo')
    Assert-Throws { Test-DomeniaGuiTypedText 'a;b' } 'Point-virgule refuse'
    Assert-Throws { Test-DomeniaGuiTypedText '' } 'Texte vide refuse'
    Assert-Throws { Test-DomeniaGuiTypedText ('a' * 201) } 'Texte trop long refuse'
}
Test-Case 'P129' 'Parcours graphiques : definition valide et erreurs detectees' {
    Assert-Equal 0 (Test-DomeniaGuiJourneyDefinition (New-GuiTestDefinition)).Count
    $bad = New-GuiTestDefinition
    $bad.Schema = 'Autre'
    $bad.Journeys = @($bad.Journeys[0], [pscustomobject]@{ Id='navigation'; Label=''; Steps=@(
        [pscustomobject]@{ Kind='Drag'; Id='X1' },
        [pscustomobject]@{ Kind='Click'; Id='' },
        [pscustomobject]@{ Kind='Window'; State='Plein ecran' },
        [pscustomobject]@{ Kind='Scroll'; Id='DgObjects'; Notches=0 },
        [pscustomobject]@{ Kind='Keys'; Keys=@('F12') },
        [pscustomobject]@{ Kind='Type'; Text='a;b' },
        [pscustomobject]@{ Kind='Capture'; Name='Avec Espace' }) })
    $errors = (Test-DomeniaGuiJourneyDefinition $bad) -join ' | '
    foreach ($expected in @('Schéma','en double','libellé','type inconnu','AutomationId','état de fenêtre','crans','hors liste','non saisissable','nom de capture')) {
        Assert-True ($errors -match [regex]::Escape($expected)) ('Erreur non detectee : ' + $expected + ' dans ' + $errors)
    }
    Assert-True ((Test-DomeniaGuiJourneyDefinition $null).Count -eq 1) 'Definition absente'
}
Test-Case 'P129' 'Parcours graphiques : fichier livre valide' {
    Assert-True ([IO.File]::Exists($script:GuiDefinitionFile)) ('Fichier absent : ' + $script:GuiDefinitionFile)
    $definition = [IO.File]::ReadAllText($script:GuiDefinitionFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    # The rule returns one array (return ,...): @() around the call would nest it and count 1.
    $errors = Test-DomeniaGuiJourneyDefinition $definition
    Assert-Equal 0 $errors.Count ($errors -join ' | ')
}
Test-Case 'P129' 'Parcours graphiques : capture 1920x1080 sans infobulle, sinon refusee' {
    Assert-True (Test-DomeniaGuiCapture -Width 1920 -Height 1080 -TooltipCount 0).Valid
    Assert-False (Test-DomeniaGuiCapture -Width 1920 -Height 1040 -TooltipCount 0).Valid 'Barre des taches dans la capture'
    Assert-False (Test-DomeniaGuiCapture -Width 1920 -Height 1080 -TooltipCount 1).Valid 'Infobulle visible'
    Assert-False (Test-DomeniaGuiCapture -Width 1920 -Height 1080 -TooltipCount -1).Valid 'Infobulle non verifiee'
}
Test-Case 'P129' 'Parcours graphiques : releve humain vierge, complet ou incomplet' {
    $definition = New-GuiTestDefinition
    $template = New-DomeniaGuiHumanTemplate $definition
    Assert-Equal 6 @($template.Steps).Count
    Assert-Equal 0 @($template.Steps | Where-Object { $_.Result }).Count 'Aucun resultat prerempli'
    Assert-True ([string]$template.Statement) 'Attestation de parcours a la main'
    Assert-False (Test-DomeniaGuiHumanRecord $template $definition).Complete 'Releve vierge incomplet'
    $template.Tester = 'Testeur fictif'; $template.Date = '2026-11-03'
    foreach ($row in @($template.Steps)) { $row.Result = 'OK' }
    $done = Test-DomeniaGuiHumanRecord $template $definition
    Assert-True $done.Complete ($done.Errors -join ' | '); Assert-Equal 6 ([int]$done.Passed)
    $template.Steps[2].Result = 'KO'
    Assert-Equal 1 ([int](Test-DomeniaGuiHumanRecord $template $definition).Failed)
    $missing = $template | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $missing.Steps = @($missing.Steps | Select-Object -First 5)
    Assert-True (((Test-DomeniaGuiHumanRecord $missing $definition).Errors -join ' ') -match 'non relevée') 'Etape manquante non detectee'
    $template.Date = '03/11/2026'
    Assert-False (Test-DomeniaGuiHumanRecord $template $definition).Complete 'Date mal formee acceptee'
}
Test-Case 'P129' 'Parcours graphiques : jamais qualifie sur des evenements simules seuls' {
    $complete = [pscustomobject]@{ Complete=$true; Failed=0 }
    $all = @('navigation','defilement','fenetres')
    Assert-Equal 'Simulé seulement' (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 20 -SimulatedFailed 0 -CapturesValid 4 -CapturesInvalid 0 -Human $null).Status
    Assert-Equal 'Simulé seulement' (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 20 -SimulatedFailed 0 -CapturesValid 4 -CapturesInvalid 0 -Human ([pscustomobject]@{ Complete=$false; Failed=0 })).Status
    Assert-Equal 'Échec' (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 19 -SimulatedFailed 1 -CapturesValid 4 -CapturesInvalid 0 -Human $complete).Status
    Assert-Equal 'Échec' (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 20 -SimulatedFailed 0 -CapturesValid 3 -CapturesInvalid 1 -Human $complete).Status
    Assert-Equal 'Échec humain' (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 20 -SimulatedFailed 0 -CapturesValid 4 -CapturesInvalid 0 -Human ([pscustomobject]@{ Complete=$true; Failed=2 })).Status
    Assert-Equal 'Non exécuté' (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 0 -SimulatedFailed 0 -CapturesValid 0 -CapturesInvalid 0 -Human $complete).Status
    $ok = Get-DomeniaGuiJourneyVerdict -SimulatedPassed 20 -SimulatedFailed 0 -CapturesValid 4 -CapturesInvalid 0 -Human $complete -Selected $all -Defined $all
    Assert-Equal 'Qualifié' $ok.Status; Assert-True $ok.Qualified
}
Test-Case 'P129' 'Parcours graphiques : un passage partiel ne qualifie jamais' {
    $complete = [pscustomobject]@{ Complete=$true; Failed=0 }
    $all = @('navigation','defilement','fenetres')
    $partial = Get-DomeniaGuiJourneyVerdict -SimulatedPassed 8 -SimulatedFailed 0 -CapturesValid 1 -CapturesInvalid 0 -Human $complete -Selected @('navigation') -Defined $all
    Assert-Equal 'Partiel' $partial.Status; Assert-False $partial.Qualified
    Assert-True ($partial.Text -match 'navigation exécuté') ('Sous-ensemble non nomme : ' + $partial.Text)
    Assert-True ($partial.Text -match 'defilement, fenetres non exécuté') ('Parcours manquants non nommes : ' + $partial.Text)
    $unstated = Get-DomeniaGuiJourneyVerdict -SimulatedPassed 20 -SimulatedFailed 0 -CapturesValid 4 -CapturesInvalid 0 -Human $complete
    Assert-Equal 'Partiel' $unstated.Status 'Couverture non indiquee'
    Assert-False $unstated.Qualified
    $shipped = [IO.File]::ReadAllText($script:GuiDefinitionFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $ids = @(@($shipped.Journeys) | ForEach-Object { [string]$_.Id })
    Assert-True ($ids.Count -ge 2) 'Le fichier livre declare plusieurs parcours'
    Assert-False (Get-DomeniaGuiJourneyVerdict -SimulatedPassed 5 -SimulatedFailed 0 -CapturesValid 1 -CapturesInvalid 0 -Human $complete -Selected @($ids[0]) -Defined $ids).Qualified 'Premier parcours seul qualifie'
}
