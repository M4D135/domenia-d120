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
Test-Case 'FO-22' 'Theme automatique : le choix de Windows pour Auto, le choix fixe sinon, Clair par defaut' {
    $cases = @(
        @('Light','Dark','Light','Choix'),@('Dark','Light','Dark','Choix'),@('Auto','Dark','Dark','Windows'),@('Auto','Light','Light','Windows'),
        @(' auto ','Dark','Dark','Windows'),@('Auto','','Light','Windows illisible'),@('Auto','Auto','Light','Windows illisible'),@('Sepia','Dark','Light','Défaut'),@('','Dark','Light','Défaut')
    )
    foreach ($c in $cases) {
        $r = Resolve-DomeniaEffectiveTheme -Preference $c[0] -WindowsTheme $c[1]
        Assert-Equal $c[2] $r.Theme ('Theme pour ' + $c[0] + '/' + $c[1])
        Assert-Equal $c[3] $r.Source ('Source pour ' + $c[0] + '/' + $c[1])
        Assert-False $r.HighContrast
    }
    Assert-Equal 'Auto' (Resolve-DomeniaEffectiveTheme -Preference ' AUTO ' -WindowsTheme 'Dark').Preference 'Choix canonique'
    Assert-Equal 'Light' (Resolve-DomeniaEffectiveTheme -Preference 'Sepia').Preference 'Choix inconnu ramene a Clair'
    Assert-True (Resolve-DomeniaEffectiveTheme -Preference 'Dark' -HighContrast $true).HighContrast 'Contraste eleve porte a part'
    Assert-Equal 'Dark' (Resolve-DomeniaEffectiveTheme -Preference 'Dark' -HighContrast $true).Theme 'Le contraste eleve ne change pas le choix'
    Assert-Equal '' (ConvertTo-DomeniaThemePreference 'Sepia');Assert-Equal 'Dark' (ConvertTo-DomeniaThemePreference ' dark ')
}
Test-Case 'FO-22' 'Preferences : Automatique est un choix enregistrable, une valeur inconnue revient au defaut' {
    $defaults = [ordered]@{Theme='Light';UxDensity='Confort'}
    Assert-Equal 'Auto' ([string](ConvertTo-DomeniaExperienceSettings -Values ([ordered]@{Theme='Auto'}) -Defaults $defaults)['Theme'])
    Assert-Equal 'Light' ([string](ConvertTo-DomeniaExperienceSettings -Values ([ordered]@{Theme='Sepia'}) -Defaults $defaults)['Theme'])
    $choices = @(Get-DomeniaThemeChoices)
    Assert-Equal 'Light,Dark,Auto' (($choices | ForEach-Object { $_.Value }) -join ',')
    Assert-Equal 'Automatique (suit Windows)' ([string]$choices[2].Label)
}
Test-Case 'FO-22' 'Contraste eleve : chaque jeton prend une couleur systeme, aucune couleur devinee' {
    $roles = Get-DomeniaHighContrastRoles
    $tokens = @($script:ThmDesign.Palettes.Light.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Equal ($tokens.Count) (@($roles.Keys).Count) 'Un role par jeton'
    foreach ($token in $tokens) {
        Assert-True ($roles.Contains($token)) ('Jeton sans role : ' + $token)
        Assert-True ([string]$roles[$token] -in @('Window','WindowText','Control','ControlText','Highlight','HighlightText','HotTrack','GrayText')) ('Role inconnu : ' + $token)
    }
    $system = [ordered]@{Window='#000000';WindowText='#FFFFFF';Control='#000000';ControlText='#FFFFFF';Highlight='#1AEBFF';HighlightText='#000000';HotTrack='#FFFF00';GrayText='#3FF23F'}
    $hc = ConvertTo-DomeniaHighContrastPalette -Palette (Get-SuitePalette -Theme Light) -SystemColors $system
    Assert-Equal $tokens.Count @($hc.Keys).Count
    Assert-Equal '#000000' ([string]$hc['WindowBg']);Assert-Equal '#FFFFFF' ([string]$hc['TextColor']);Assert-Equal '#FFFFFF' ([string]$hc['MutedColor'])
    Assert-Equal '#1AEBFF' ([string]$hc['AccentColor']);Assert-Equal '#000000' ([string]$hc['OnAccent']);Assert-Equal '#FFFF00' ([string]$hc['AccentText'])
    Assert-Equal '#FFFFFF' ([string]$hc['StatusError']) 'Un etat se lit par son mot et son symbole'
    foreach ($pair in @(@('TextColor','BgCard'),@('OnAccent','AccentColor'),@('MutedColor','BgReadonly'),@('RowSelFg','RowSelBg'),@('BtnFg','BtnBg'))) {
        Assert-True ((Get-DomeniaContrastRatio $hc[$pair[0]] $hc[$pair[1]]) -ge 4.5) ('Contraste eleve : ' + ($pair -join '/'))
    }
    $partial = ConvertTo-DomeniaHighContrastPalette -Palette ([ordered]@{TextColor='#17243A';BgCard='#FFFFFF'}) -SystemColors ([ordered]@{WindowText='bleu'})
    Assert-Equal '#17243A' ([string]$partial['TextColor']) 'Couleur systeme invalide : jeton conserve'
    Assert-Equal '#FFFFFF' ([string]$partial['BgCard']) 'Role absent : jeton conserve'
}
Test-Case 'FO-22' 'Bouton de theme : Automatique annonce, le clic fixe le theme oppose, une infobulle d une ligne' {
    $auto = Get-DomeniaThemeToggleIcon -CurrentTheme 'Dark' -Preference 'Auto'
    Assert-Equal 'Passer au thème clair' $auto.Name 'Nom = action du clic'
    Assert-True $auto.Auto;Assert-True ($auto.ToolTip -match 'automatique') $auto.ToolTip
    Assert-False ($auto.ToolTip -match "`n") 'Une ligne'
    $fixed = Get-DomeniaThemeToggleIcon -CurrentTheme 'Light' -Preference 'Light'
    Assert-False $fixed.Auto;Assert-True ($fixed.ToolTip -match 'Clic droit') $fixed.ToolTip
    Assert-Equal 'Passer au thème sombre' (Get-DomeniaThemeToggleIcon 'Light').Name 'Appel historique sans choix'
}
Test-Case 'UI-11' 'Panneau d aide : chaque page du menu mene a un chapitre du guide' {
    foreach ($page in @(Get-DomeniaShellPages)) {
        $c = Get-DomeniaHelpGuideChapter -Page $page.Id
        Assert-True ($c.Guide -in @('technicien','administrateur')) $page.Id
        Assert-True (($c.Chapter -ge 1) -and [bool]$c.Title) $page.Id
        Assert-Equal ('Domenia-1.0-Guide-' + $c.Guide + '.pdf') $c.File
        Assert-Equal ($c.GuideTitle + ', chapitre ' + $c.Chapter + ' : ' + $c.Title) $c.Text
        Assert-False ($c.Title -eq 'Repères') ('Page sans chapitre propre : ' + $page.Id)
    }
    Assert-Equal 'Repères' (Get-DomeniaHelpGuideChapter -Page 'PageInconnue').Title 'Page inconnue : carte de la fenetre'
    Assert-Equal 'Guide de lʼadministrateur' (Get-DomeniaHelpGuideChapter -Page 'TabAccounts').GuideTitle
}
Test-Case 'UI-11' 'Pastille sur « ? » : premier lancement seulement, jamais quand l aide est ouverte' {
    $first = Get-DomeniaHelpBadgeState -IntroSeen $false -HelpShown $false
    Assert-True $first.Show;Assert-True $first.MarkSeen;Assert-True ([bool]$first.ItemStatus)
    $open = Get-DomeniaHelpBadgeState -IntroSeen $false -HelpShown $true
    Assert-False $open.Show;Assert-True $open.MarkSeen 'Aide deja ouverte : la decouverte est faite'
    $next = Get-DomeniaHelpBadgeState -IntroSeen $true -HelpShown $false
    Assert-False $next.Show;Assert-False $next.MarkSeen;Assert-Equal '' $next.ItemStatus
}
Test-Case 'PF-24' 'Aide du catalogue : aucune infobulle sur un conteneur, une ligne pour un bouton-icone (UI-10)' {
    $text = 'Affiche ou masque les explications à droite. Sur une fenêtre étroite, lʼaide sʼouvre au-dessus du contenu.'
    $c = Get-DomeniaHelpPresentation -Text $text -Role Container
    Assert-Equal '' $c.ToolTip 'Conteneur sans infobulle';Assert-Equal $text $c.HelpText 'Texte d aide entier';Assert-False $c.HoverHelp 'Pas d aide au survol d un conteneur'
    $i = Get-DomeniaHelpPresentation -Text $text -Role IconButton
    Assert-Equal 'Affiche ou masque les explications à droite.' $i.ToolTip;Assert-Equal $text $i.HelpText;Assert-True $i.HoverHelp
    Assert-Equal 'Bascule entre clair et sombre.' (Get-DomeniaHelpPresentation -Text 'Bascule entre clair et sombre ; le choix est gardé.' -Role IconButton).ToolTip 'Point-virgule : premiere proposition'
    Assert-Equal 'Revenir à 100 %' (Get-DomeniaHelpPresentation -Text 'Revenir à 100 %' -Role IconButton).ToolTip 'Une seule phrase gardee entiere'
    $n = Get-DomeniaHelpPresentation -Text $text
    Assert-Equal $text $n.ToolTip 'Controle ordinaire : texte entier';Assert-Equal 'Control' $n.Role
    Assert-Equal '' (Get-DomeniaHelpPresentation -Text '   ' -Role IconButton).ToolTip 'Texte vide'
}
