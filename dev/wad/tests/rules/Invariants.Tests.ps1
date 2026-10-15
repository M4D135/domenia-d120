# Point 128 : verification automatique des invariants (compte = GUID detailles, rendu date, inconnu conserve,
# aucune reponse d une ancienne selection). Chaque regle doit detecter une donnee volontairement fausse.
$script:InvariantFile = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures') 'Domenia-Invariants.ps1'
. $script:InvariantFile
$script:InvA = '00000000-0000-4000-8000-00000000000a'
$script:InvB = '00000000-0000-4000-8000-00000000000b'
$script:InvC = '00000000-0000-4000-8000-00000000000c'
$script:InvNow = [datetime]::SpecifyKind([datetime]'2026-10-15T08:00:00',[DateTimeKind]::Utc)
function New-InvariantTestWidget {
    param([double]$Total,[double]$Matched,[double]$NotMatched,[double]$Unknown,[object[]]$Items=@())
    return [pscustomobject]@{ Total=$Total; Matched=$Matched; NotMatched=$NotMatched; Unknown=$Unknown; Items=$Items }
}
function Get-InvariantTestTexts { param($Violations) return (@($Violations | ForEach-Object { [string]$_.Text }) -join ' ; ') }

Test-Case 'P128' 'Invariants : widget coherent avec sa liste et ses segments' {
    $items = @([pscustomobject]@{ Label='Model 1'; Value=2 },[pscustomobject]@{ Label='Valeur inconnue'; Value=1 })
    $w = New-InvariantTestWidget 5 3 1 1 $items
    $segments = @{ 'Model 1'=@($script:InvA,$script:InvB); 'Valeur inconnue'=@{ ('{' + $script:InvC.ToUpperInvariant() + '}')=$true } }
    $v = Test-DomeniaWidgetDetailInvariant 'RAM' $w @($script:InvA,$script:InvB,$script:InvC) $segments
    Assert-Equal 0 $v.Count (Get-InvariantTestTexts $v)
}
Test-Case 'P128' 'Invariants : chiffre du widget different de sa liste detaillee detecte' {
    $v = Test-DomeniaWidgetDetailInvariant 'RAM' (New-InvariantTestWidget 4 3 1 0) @($script:InvA,$script:InvB)
    Assert-Equal 1 $v.Count (Get-InvariantTestTexts $v); Assert-Equal 'WidgetDetail' ([string]$v[0].Invariant)
    $dup = Test-DomeniaWidgetDetailInvariant 'RAM' (New-InvariantTestWidget 4 3 1 0) @($script:InvA,$script:InvA.ToUpperInvariant(),$script:InvB)
    Assert-Equal 1 $dup.Count 'Un GUID en double compte une seule fois'
    $names = Test-DomeniaWidgetDetailInvariant 'RAM' (New-InvariantTestWidget 4 2 2 0) @($script:InvA,'PC-01')
    Assert-True ((Get-InvariantTestTexts $names) -match 'pas des GUID') 'Nom accepte comme identite'
    $sum = Test-DomeniaWidgetDetailInvariant 'RAM' (New-InvariantTestWidget 5 3 1 0)
    Assert-True ((Get-InvariantTestTexts $sum) -match 'Total différent') 'Inconnu perdu du total non detecte'
}
Test-Case 'P128' 'Invariants : segment faux, segment sans liste et segments incomplets detectes' {
    $items = @([pscustomobject]@{ Label='Model 1'; Value=2 },[pscustomobject]@{ Label='Model 2'; Value=1 })
    $w = New-InvariantTestWidget 3 3 0 0 $items
    $v = Test-DomeniaWidgetDetailInvariant 'Modeles' $w $null @{ 'Model 1'=@($script:InvA) }
    $text = Get-InvariantTestTexts $v
    Assert-True ($text -match 'chiffre du segment diffère') 'Segment faux non detecte'
    Assert-True ($text -match 'sans liste détaillée') 'Segment sans liste non detecte'
    $partial = Test-DomeniaWidgetDetailInvariant 'Modeles' (New-InvariantTestWidget 4 4 0 0 $items)
    Assert-True ((Get-InvariantTestTexts $partial) -match 'ne totalisent pas') 'Segments incomplets non detectes'
    Assert-Equal 1 (Test-DomeniaWidgetDetailInvariant 'Vide' $null).Count 'Widget absent'
    Assert-Equal 1 (Test-DomeniaWidgetDetailInvariant 'Sans compteur' ([pscustomobject]@{ Total=1 })).Count 'Compteur absent'
}
Test-Case 'P128' 'Invariants : rendu date en UTC, ni absent, ni ambigu, ni futur' {
    Assert-Equal 0 (Test-DomeniaRenderDatedInvariant 'Parc' $script:InvNow -NowUtc $script:InvNow).Count
    Assert-Equal 0 (Test-DomeniaRenderDatedInvariant 'Parc' '2026-10-15T07:59:00.0000000Z' -NowUtc $script:InvNow).Count
    Assert-Equal 0 (Test-DomeniaRenderDatedInvariant 'Parc' '2026-10-15T09:59:00+02:00' -NowUtc $script:InvNow).Count 'Decalage horaire explicite accepte'
    Assert-Equal 1 (Test-DomeniaRenderDatedInvariant 'Parc' $null -NowUtc $script:InvNow).Count 'Date absente'
    Assert-Equal 1 (Test-DomeniaRenderDatedInvariant 'Parc' '2026-10-15T07:59:00' -NowUtc $script:InvNow).Count 'Texte sans fuseau'
    Assert-Equal 1 (Test-DomeniaRenderDatedInvariant 'Parc' ([datetime]::new(2026,10,15,7,0,0)) -NowUtc $script:InvNow).Count 'Date de nature non precisee'
    Assert-Equal 1 (Test-DomeniaRenderDatedInvariant 'Parc' '0001-01-01T00:00:00Z' -NowUtc $script:InvNow).Count 'Date par defaut'
    Assert-Equal 1 (Test-DomeniaRenderDatedInvariant 'Parc' $script:InvNow.AddHours(1) -NowUtc $script:InvNow).Count 'Date future'
    Assert-Equal 0 (Test-DomeniaRenderDatedInvariant 'Parc' $script:InvNow.AddMinutes(4) -NowUtc $script:InvNow).Count 'Ecart d horloge tolere'
}
Test-Case 'P128' 'Invariants : inconnu conserve, ni perdu, ni invente, ni compte comme connu' {
    Assert-Equal 0 (Test-DomeniaUnknownKeptInvariant 'RAM' 37 37 63 63).Count
    Assert-Equal 1 (Test-DomeniaUnknownKeptInvariant 'RAM' 37 $null).Count 'Inconnus disparus'
    Assert-Equal 1 (Test-DomeniaUnknownKeptInvariant 'RAM' 37 0).Count 'Inconnus ramenes a zero'
    Assert-Equal 1 (Test-DomeniaUnknownKeptInvariant 'RAM' 0 5).Count 'Inconnus inventes'
    Assert-Equal 0 (Test-DomeniaUnknownKeptInvariant 'RAM' 0 $null).Count 'Aucun inconnu, aucun segment'
    Assert-Equal 2 (Test-DomeniaUnknownKeptInvariant 'RAM' 37 30 63 70).Count 'Inconnus comptes comme connus'
    Assert-Equal 0 (Test-DomeniaUnknownDisplayInvariant 'Disque' $true 'Valeur inconnue').Count
    Assert-Equal 0 (Test-DomeniaUnknownDisplayInvariant 'Disque' $true 'Non vérifié (aucune mesure)').Count
    Assert-Equal 1 (Test-DomeniaUnknownDisplayInvariant 'Disque' $true '0 Go').Count 'Inconnu affiche comme zero'
    Assert-Equal 1 (Test-DomeniaUnknownDisplayInvariant 'BitLocker' $true 'Non').Count 'Inconnu affiche comme non'
    Assert-Equal 1 (Test-DomeniaUnknownDisplayInvariant 'BitLocker' $true '').Count 'Inconnu affiche vide'
    Assert-Equal 0 (Test-DomeniaUnknownDisplayInvariant 'Disque' $false '0 Go').Count 'Zero mesure reste un zero'
}
Test-Case 'P128' 'Invariants : aucune reponse d une ancienne selection appliquee' {
    $current = [pscustomobject]@{ Epoch=2; Generation=7; Reader='EX\lecteur'; Guid=$script:InvA }
    $same = [pscustomobject]@{ Epoch=2; Generation=7; Reader='EX\lecteur'; Guid=('{' + $script:InvA.ToUpperInvariant() + '}') }
    $old = [pscustomobject]@{ Epoch=2; Generation=6; Reader='EX\lecteur'; Guid=$script:InvA }
    $otherReader = [pscustomobject]@{ Epoch=2; Generation=7; Reader='EX\support'; Guid=$script:InvA }
    Assert-Equal 0 (Test-DomeniaCurrentAnswerInvariant 'Fiche' $same $current $true).Count
    Assert-Equal 1 (Test-DomeniaCurrentAnswerInvariant 'Fiche' $old $current $true).Count 'Ancienne generation appliquee'
    Assert-Equal 1 (Test-DomeniaCurrentAnswerInvariant 'Fiche' $otherReader $current $true).Count 'Autre compte applique'
    Assert-Equal 0 (Test-DomeniaCurrentAnswerInvariant 'Fiche' $old $current $false).Count 'Ancienne reponse ecartee'
    Assert-Equal 1 (Test-DomeniaCurrentAnswerInvariant 'Fiche' $same $current $false -RequireCurrentApplied).Count 'Reponse courante perdue'
    Assert-Equal 1 (Test-DomeniaCurrentAnswerInvariant 'Fiche' ([pscustomobject]@{}) $current $true).Count 'Demande sans identite appliquee'
}
Test-Case 'P128' 'Invariants : rapport agrege par invariant, jamais reussi sans controle' {
    $all = @()
    $all += Test-DomeniaWidgetDetailInvariant 'RAM' (New-InvariantTestWidget 4 3 1 0) @($script:InvA)
    $all += Test-DomeniaUnknownKeptInvariant 'RAM' 3 $null
    $report = Get-DomeniaInvariantReport -Violations $all -Checked 2
    Assert-False $report.Passed; Assert-Equal 2 ([int]$report.ViolationCount)
    Assert-Equal 1 ([int]$report.ByInvariant.WidgetDetail); Assert-Equal 1 ([int]$report.ByInvariant.UnknownKept)
    Assert-False (Get-DomeniaInvariantReport -Violations @() -Checked 0).Passed 'Aucun controle ne vaut pas reussite'
    Assert-True (Get-DomeniaInvariantReport -Violations @() -Checked 3).Passed
}
