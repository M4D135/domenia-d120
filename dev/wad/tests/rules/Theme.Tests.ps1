# Lot Z04 (theme et accessibilite) : une seule palette (CD-05), series de graphiques (DS-14), boutons desactives et
# cartes sombres (DS-11), theme automatique et contraste eleve (FO-22), panneau d aide (UI-11). Regles pures : le
# contrat de presentation SupportSuite.UI.json est lu, aucune fenetre n est creee.
. (Join-Path $modules 'Domenia-Experience.Model.ps1')
if ($null -eq (Get-Command -Name Get-DomeniaBoardColor -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
    . (Join-Path $modules 'Domenia-Boards.Model.ps1')
}
$script:ThmDesign = [IO.File]::ReadAllText((Join-Path $modules 'SupportSuite.UI.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json

function Get-ThmHue {
    # Hue (degrees) and HSL saturation of a '#RRGGBB' colour.
    param([string]$Hex)
    $r = [Convert]::ToInt32($Hex.Substring(1,2),16) / 255.0
    $g = [Convert]::ToInt32($Hex.Substring(3,2),16) / 255.0
    $b = [Convert]::ToInt32($Hex.Substring(5,2),16) / 255.0
    $max = [Math]::Max($r,[Math]::Max($g,$b)); $min = [Math]::Min($r,[Math]::Min($g,$b)); $d = $max - $min
    if ($d -eq 0) { return [pscustomobject]@{Hue=0.0;Saturation=0.0} }
    $l = ($max + $min) / 2.0
    $s = if ($l -gt 0.5) { $d / (2.0 - $max - $min) } else { $d / ($max + $min) }
    if ($max -eq $r) { $h = (($g - $b) / $d) % 6 } elseif ($max -eq $g) { $h = (($b - $r) / $d) + 2 } else { $h = (($r - $g) / $d) + 4 }
    $h = $h * 60.0; if ($h -lt 0) { $h += 360.0 }
    return [pscustomobject]@{Hue=$h;Saturation=$s}
}
function Get-ThmHueGap { param([double]$A,[double]$B) $d = [Math]::Abs($A - $B) % 360.0; return [Math]::Min($d,360.0 - $d) }

Test-Case 'CD-05' 'Une seule palette : memes jetons dans les deux themes, tous exiges par le lecteur' {
    $light = @($script:ThmDesign.Palettes.Light.PSObject.Properties | ForEach-Object { $_.Name })
    $dark = @($script:ThmDesign.Palettes.Dark.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Equal ($light -join ',') ($dark -join ',') 'Jetons et ordre identiques'
    $design = Get-SuiteDesign
    Assert-Equal $light.Count @($design.Palettes.Light.PSObject.Properties).Count
    foreach ($theme in @('Light','Dark')) {
        $palette = Get-SuitePalette -Theme $theme
        foreach ($name in $light) { Assert-True ([string]$palette[$name] -cmatch '^#[0-9A-F]{6}$') ($theme + ' ' + $name) }
    }
}
Test-Case 'CD-05' 'Get-DomeniaThemeColor : jeton du theme, couleur historique conservee, jamais de couleur devinee' {
    Assert-Equal ([string](Get-SuitePalette -Theme Dark)['BgCard']) (Get-DomeniaThemeColor -Key 'BgCard' -Theme Dark)
    Assert-Equal ([string](Get-SuitePalette -Theme Light)['StateWarn']) (Get-DomeniaThemeColor -Key 'StateWarn' -Theme Light)
    Assert-Equal '#93C5FD' (Get-DomeniaThemeColor -Key '#93c5fd' -Theme Dark) 'Couleur d un instantane anterieur'
    Assert-Equal '' (Get-DomeniaThemeColor -Key 'JetonInconnu' -Theme Light) 'Jeton inconnu'
    Assert-Equal '' (Get-DomeniaThemeColor -Key '' -Theme Light) 'Vide'
    Assert-Equal '' (Get-DomeniaThemeColor -Key 'bleu' -Theme Light) 'Nom de couleur WPF refuse'
    $saved = Get-Variable -Name DomeniaPaintedPalette -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    try {
        $script:DomeniaPaintedPalette = [ordered]@{TextColor='#000000'}
        Assert-Equal '#000000' (Get-DomeniaThemeColor -Key 'TextColor') 'La palette peinte (contraste eleve) prime'
        Assert-Equal ([string](Get-SuitePalette -Theme Light)['TextColor']) (Get-DomeniaThemeColor -Key 'TextColor' -Theme Light) 'Un theme explicite lit le JSON'
    } finally { $script:DomeniaPaintedPalette = $saved }
}
Test-Case 'CD-05' 'Le modele des tableaux nomme des jetons de la palette, jamais une couleur' {
    foreach ($name in @('Ok','Warn','Alert','Off','Info','Used','Other','Disabled')) {
        $token = Get-DomeniaBoardColor $name
        Assert-False ($token -like '#*') ('Couleur en dur : ' + $name)
        foreach ($theme in @('Light','Dark')) { Assert-True ([bool](Get-DomeniaThemeColor -Key $token -Theme $theme)) ($theme + ' ' + $name + ' -> ' + $token) }
    }
    Assert-Equal '' (Get-DomeniaBoardColor 'Inconnu')
    Assert-True ((Get-DomeniaBoardColor 'Other') -cne (Get-DomeniaBoardColor 'Off')) 'Autres et inconnu restent distincts'
}
Test-Case 'DS-14' 'Series categorielles : huit pastels a 3:1 contre la carte, hors teintes d etat' {
    foreach ($theme in @('Light','Dark')) {
        $series = @(Get-DomeniaChartSeries -Theme $theme)
        Assert-Equal 8 $series.Count $theme
        Assert-Equal 8 @($series | ForEach-Object { $_.Fill } | Sort-Object -Unique).Count ($theme + ' : couleurs distinctes')
        $card = Get-DomeniaThemeColor -Key 'BgCard' -Theme $theme
        $states = @('StateOk','StateWarn','StateAlert','StatusSuccess','StatusWarning','StatusError' | ForEach-Object { Get-DomeniaThemeColor -Key $_ -Theme $theme })
        $stateHues = @('StateOk','StateWarn','StateAlert' | ForEach-Object { (Get-ThmHue (Get-DomeniaThemeColor -Key $_ -Theme $theme)).Hue })
        foreach ($item in $series) {
            Assert-True ($states -notcontains $item.Fill) ($theme + ' : ' + $item.Token + ' reprend une couleur d etat')
            $best = [Math]::Max((Get-DomeniaContrastRatio $item.Fill $card),(Get-DomeniaContrastRatio $item.Edge $card))
            Assert-True ($best -ge 3.0) ($theme + ' : ' + $item.Token + ' a ' + $best + ':1')
            if ((Get-DomeniaContrastRatio $item.Fill $card) -lt 3.0) {
                Assert-True ((Get-DomeniaRelativeLuminance $item.Edge) -lt (Get-DomeniaRelativeLuminance $item.Fill)) ($theme + ' : contour de ' + $item.Token + ' plus fonce')
            }
            $hue = Get-ThmHue $item.Fill
            $gap = @($stateHues | ForEach-Object { Get-ThmHueGap $hue.Hue $_ } | Sort-Object)[0]
            Assert-True (($hue.Saturation -lt 0.15) -or ($gap -ge 15.0)) ($theme + ' : ' + $item.Token + ' a ' + $gap + ' degres d une teinte d etat')
        }
    }
}
Test-Case 'CD-05' 'Couples de texte et de graphisme de la palette : 4,5:1 et 3:1 dans les deux themes' {
    $pairs = @(Get-DomeniaSuiteContrastPairs)
    Assert-True ($pairs.Count -ge 40) 'Couples declares'
    foreach ($theme in @('Light','Dark')) {
        $r = Test-DomeniaPaletteContrast (Get-SuitePalette -Theme $theme) $pairs
        Assert-True $r.Passed ($theme + ' : ' + ((@($r.Failures) | ForEach-Object { $_.Name + ' ' + $_.Display }) -join ', '))
    }
}
Test-Case 'DS-11' 'Bouton desactive lisible et carte sombre visible sur son fond' {
    foreach ($theme in @('Light','Dark')) {
        $p = Get-SuitePalette -Theme $theme
        Assert-True ((Get-DomeniaContrastRatio $p['MutedColor'] $p['BgReadonly']) -ge 4.5) ($theme + ' : texte desactive')
        Assert-True ((Get-DomeniaContrastRatio $p['OnAccent'] $p['AccentHover']) -ge 4.5) ($theme + ' : survol du bouton principal')
        Assert-True ((Get-DomeniaContrastRatio $p['OnAccent'] $p['DangerHover']) -ge 4.5) ($theme + ' : survol du bouton de danger')
        Assert-True ((Get-DomeniaContrastRatio $p['BtnFg'] $p['RowHoverBg']) -ge 4.5) ($theme + ' : survol teinte')
    }
    $dark = Get-SuitePalette -Theme Dark
    Assert-Equal '#1E2D44' ([string]$dark['BgCard']) 'Carte sombre eclaircie'
    Assert-True ((Get-DomeniaContrastRatio $dark['BgCard'] $dark['WindowBg']) -ge 1.2) 'Carte sombre distincte du fond'
    Assert-True ((Get-DomeniaContrastRatio $dark['BorderColor'] $dark['BgCard']) -ge 1.5) 'Bordure de carte visible'
    Assert-True ([string]$dark['BgInput'] -cne [string]$dark['BgCard']) 'Champ distinct de la carte'
}
