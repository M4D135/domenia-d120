#!/usr/bin/env python3
"""Offline source/XML/contrast checks of the theme, NOT a PowerShell or WPF runtime test.

Reads the real presentation contract (wad/modules/SupportSuite.UI.json), the main XAML (Get-MainXaml), the boot window
factories and the runtime sources. Native Windows checks are in Test-DomeniaTheme.ps1 and rules/Theme.Tests.ps1.

  CD-05  one palette: both themes declare the same tokens, the runtime reader requires them all, the start-up brushes
         of the main XAML equal the Light palette, every resource the XAML names exists, and a ratchet keeps the count
         of literal '#RRGGBB' colours of the runtime sources from growing (--update lowers the reference, never raises).
  DS-14  categorical chart series: 3:1 against the card in both themes (pastel fill or its darker edge), hues away
         from the state colours, none equal to a state token.
  DS-11  readable disabled buttons and visible dark cards (contrast and template rules).
  All    the text pairs of Get-DomeniaSuiteContrastPairs reach 4.5:1 (3:1 for graphics) in both themes, and the login
         and startup windows built with the boot roles keep 4.5:1 for every text.
"""
from __future__ import annotations
from pathlib import Path
import argparse, colorsys, json, re, sys, xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parent))
from powershell_lex import functions, mask_ps

WPF = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
X = 'http://schemas.microsoft.com/winfx/2006/xaml'
HEX = re.compile(r'#[0-9A-Fa-f]{6}\b')
BASELINE = Path('wad/tests/theme-hex-baseline.json')


def luminance(color):
    channels = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return sum((c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4) * w for c, w in zip(channels, (0.2126, 0.7152, 0.0722)))


def contrast(foreground, background):
    a, b = sorted((luminance(foreground), luminance(background)))
    return (b + 0.05) / (a + 0.05)


def hue(color):
    r, g, b = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return h * 360.0, s


def hue_distance(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


def local(element):
    return element.tag.rsplit('}', 1)[-1]


def scoped_duplicates(root):
    """x:Name must be unique per namescope: a template opens its own scope."""
    seen, duplicates = set(), []

    def visit(node, scope):
        if local(node) in ('ControlTemplate', 'DataTemplate', 'ItemsPanelTemplate'):
            scope = id(node)
        name = node.get('{' + X + '}Name')
        if name:
            if (scope, name) in seen:
                duplicates.append(name)
            seen.add((scope, name))
        for child in node:
            visit(child, scope)
    visit(root, 'window')
    return duplicates


def hex_counts(root):
    """Literal colours of the runtime sources: Core, modules (.ps1, .xaml). The palette JSON is the source itself."""
    counts = {}
    core = root / 'wad/Domenia-Core.ps1'
    files = [core, root / 'wad/Domenia-Main.xaml'] + sorted((root / 'wad/modules').glob('*.ps1')) + sorted((root / 'wad/modules').glob('*.xaml'))
    for path in files:
        text = path.read_text(encoding='utf-8-sig')
        if path.name == 'Domenia-Main.xaml':
            # The start-up brushes of the main XAML mirror the Light palette and are checked for equality below.
            text = re.sub(r'<SolidColorBrush x:Key="\w+" Color="#[0-9A-Fa-f]{6}"/>', '', text)
        number = len(HEX.findall(text))
        if number:
            counts[path.relative_to(root).as_posix()] = number
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--report', type=Path, default=None, help='Rapport JSON facultatif.')
    ap.add_argument('--update', action='store_true', help='Abaisse la reference des couleurs fixes (jamais de hausse).')
    args = ap.parse_args()
    root = args.root.resolve()
    core = (root / 'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig')
    spans = functions(core)
    shell = (root / 'wad/modules/Domenia-Shell.Model.ps1').read_text(encoding='utf-8-sig')
    shell_spans = functions(shell)
    experience = (root / 'wad/modules/Domenia-Experience.Model.ps1').read_text(encoding='utf-8-sig')
    charts = (root / 'wad/modules/Domenia-Charts.UI.ps1').read_text(encoding='utf-8-sig')
    design = json.loads((root / 'wad/modules/SupportSuite.UI.json').read_text(encoding='utf-8'))
    palettes = design['Palettes']

    def fn(name, source=core, table=spans):
        (a, b), = [table[name][0]]
        return source[a:b]

    def literal(name):
        if name == 'Get-MainXaml':
            return (root / 'wad/Domenia-Main.xaml').read_text(encoding='utf-8-sig')
        match = re.search(r'@"\n(.*?)\n"@', fn(name), re.S)
        assert match, name
        return match[1]

    results, observations = [], {}

    def require(test, message='Assertion fausse'):
        if not test:
            raise AssertionError(message)

    def check(name, body):
        try:
            detail = body() or ''
            status = 'PASS'
        except Exception as exc:  # noqa: BLE001 - every failure is reported, none hidden
            detail, status = str(exc), 'FAIL'
        results.append({'Name': name, 'Status': status, 'Detail': detail})
        print(status, name, detail)

    def delimiters():
        masked, issues = mask_ps(core)
        require(not issues, str(issues))
        stack, pairs = [], {')': '(', ']': '[', '}': '{'}
        for i, c in enumerate(masked):
            if c in '([{':
                stack.append(c)
            elif c in ')]}':
                require(stack and stack.pop() == pairs[c], 'Delimiteur a ' + str(i))
        require(not stack)
    check('Core : lexique et delimiteurs (pas un parseur natif)', delimiters)

    # ------------------------------------------------------------------ CD-05
    def contract():
        light, dark = palettes['Light'], palettes['Dark']
        require(list(light) == list(dark), 'Jetons differents ou dans un autre ordre entre clair et sombre')
        for theme, palette in palettes.items():
            bad = [k for k, v in palette.items() if not re.fullmatch(r'#[0-9A-F]{6}', v)]
            require(not bad, theme + ' : couleurs invalides ' + ', '.join(bad))
        listed = re.search(r"foreach\(\$required in @\(([^)]*)\)\)", fn('Get-SuiteDesign', experience, functions(experience)))
        require(listed, 'Liste des jetons requis introuvable')
        required = re.findall(r"'([A-Za-z]+)'", listed[1])
        require(set(required) == set(light), 'Jetons non exiges par le lecteur : ' + ', '.join(sorted(set(light) - set(required))) +
                ' ; exiges mais absents : ' + ', '.join(sorted(set(required) - set(light))))
        return '%d jetons par theme, tous exiges par Get-SuiteDesign' % len(light)
    check('CD-05 : un seul contrat de couleurs, memes jetons dans les deux themes', contract)

    main_xaml = literal('Get-MainXaml')
    document = ET.fromstring(main_xaml)

    def startup_brushes():
        brushes = re.findall(r'<SolidColorBrush x:Key="(\w+)" Color="(#[0-9A-Fa-f]{6})"/>', main_xaml)
        require(brushes, 'Aucun pinceau de demarrage')
        wrong = [k + '=' + v for k, v in brushes if palettes['Light'].get(k) != v.upper()]
        require(not wrong, 'Pinceaux de demarrage differents de la palette claire : ' + ', '.join(wrong))
        return '%d pinceaux de demarrage egaux a la palette claire' % len(brushes)
    check('CD-05 : pinceaux de demarrage de la fenetre principale = palette claire du JSON', startup_brushes)

    def resource_names():
        keys = {e.get('{' + X + '}Key') for e in document.iter() if e.get('{' + X + '}Key')}
        used = set(re.findall(r'\{(?:Dynamic|Static)Resource\s+([A-Za-z]\w*)\}', main_xaml))
        missing = sorted(used - keys - set(palettes['Light']))
        require(not missing, 'Ressources inconnues : ' + ', '.join(missing))
        return '%d ressources nommees, toutes declarees' % len(used)
    check('CD-05 : chaque ressource nommee par le XAML principal existe', resource_names)

    def no_table():
        apply = fn('Apply-DomeniaTheme')
        require(not HEX.search(apply), 'Apply-DomeniaTheme garde des couleurs')
        require('Set-DomeniaUxPalette -Window $window -Theme $Theme' in apply, 'Apply-DomeniaTheme ne peint pas la palette partagee')
        boot = fn('Get-DomeniaBootThemePalette')
        require(not HEX.search(boot), 'La palette d amorcage garde une copie des couleurs')
        require(not HEX.search(fn('Get-DomeniaPresenceColor')), 'Couleurs de presence en dur')
        return ''
    check('CD-05 : ni table de theme, ni copie d amorcage, ni presence en dur', no_table)

    def ratchet():
        current = hex_counts(root)
        path = root / BASELINE
        reference = json.loads(path.read_text(encoding='utf-8')) if path.exists() else None
        observations['HexCounts'] = current
        total = sum(current.values())
        if args.update:
            if reference is not None:
                grown = [f for f, n in current.items() if n > reference['Counts'].get(f, 0)]
                require(not grown, 'Hausse refusee : ' + ', '.join(grown))
            path.write_text(json.dumps({'Kind': 'Couleurs fixes #RRGGBB des sources runtime (cliquet CD-05)',
                                        'Total': total, 'Counts': current}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            return 'reference ecrite : %d couleurs fixes' % total
        require(reference is not None, 'Reference absente : ' + BASELINE.as_posix() + ' (creer avec --update)')
        grown = ['%s %d > %d' % (f, n, reference['Counts'].get(f, 0)) for f, n in current.items() if n > reference['Counts'].get(f, 0)]
        require(not grown, 'Nouvelles couleurs fixes (utiliser un jeton de SupportSuite.UI.json) : ' + ', '.join(grown))
        return '%d couleurs fixes (reference %d)' % (total, reference['Total'])
    check('CD-05 : cliquet des couleurs fixes hors palette', ratchet)

    # ------------------------------------------------------------------ DS-14
    series = re.findall(r"'(Chart[A-Za-z]+)'", fn('Get-DomeniaChartSeriesNames', experience, functions(experience)))

    def chart_series():
        require(len(series) == 8 and len(set(series)) == 8, 'Huit series categorielles attendues')
        require('Get-DomeniaChartSeries' in fn('Get-DomeniaChartPalette', charts, functions(charts)), 'Les graphiques ne lisent pas les series du JSON')
        states = ['StateOk', 'StateWarn', 'StateAlert', 'StatusSuccess', 'StatusWarning', 'StatusError']
        lines = []
        for theme, palette in palettes.items():
            state_values = {palette[s] for s in states}
            state_hues = [hue(palette[s])[0] for s in ('StateOk', 'StateWarn', 'StateAlert')]
            card = palette['BgCard']
            worst = 99.0
            for name in series:
                fill, edge = palette[name], palette[name + 'Edge']
                require(fill not in state_values, theme + ' : ' + name + ' reprend une couleur d etat')
                h, s = hue(fill)
                gap = min(hue_distance(h, x) for x in state_hues)
                require(s < 0.15 or gap >= 15.0, '%s : %s trop proche d une teinte d etat (%.0f degres)' % (theme, name, gap))
                best = max(contrast(fill, card), contrast(edge, card))
                require(best >= 3.0, '%s : %s a %.2f:1 contre la carte' % (theme, name, best))
                if contrast(fill, card) < 3.0:
                    require(luminance(edge) < luminance(fill), theme + ' : le contour de ' + name + ' n est pas plus fonce')
                worst = min(worst, best)
            lines.append('%s minimum %.2f:1' % (theme, worst))
        return ' ; '.join(lines)
    check('DS-14 : series categorielles a 3:1, hors teintes d etat', chart_series)

    # ------------------------------------------------------------------ contrast pairs
    pairs = re.findall(r"@\('([^']*)','([^']*)','([^']*)','([^']*)'\)", fn('Get-DomeniaSuiteContrastPairs', shell, shell_spans))

    def suite_pairs():
        require(len(pairs) >= 30, 'Couples de contraste introuvables')
        lines = []
        for theme, palette in palettes.items():
            worst = (99.0, '')
            for name, fg, bg, kind in pairs:
                f = fg if fg.startswith('#') else palette[fg]
                b = bg if bg.startswith('#') else palette[bg]
                ratio = contrast(f, b)
                need = 3.0 if kind in ('Graphic', 'LargeText') else 4.5
                require(ratio >= need, '%s : %s %.2f:1 < %.1f:1' % (theme, name, ratio, need))
                worst = min(worst, (ratio, name))
            observations[theme + 'MinimumPair'] = round(worst[0], 3)
            lines.append('%s minimum %.2f:1 (%s)' % (theme, worst[0], worst[1]))
        return '%d couples ; ' % len(pairs) + ' ; '.join(lines)
    check('Palette : couples de Get-DomeniaSuiteContrastPairs dans les deux themes', suite_pairs)

    # ------------------------------------------------------------------ DS-11
    def disabled_and_cards():
        for theme, palette in palettes.items():
            require(contrast(palette['MutedColor'], palette['BgReadonly']) >= 4.5, theme + ' : texte desactive sous 4,5:1')
        dark = palettes['Dark']
        require(contrast(dark['BgCard'], dark['WindowBg']) >= 1.2, 'Carte sombre trop proche du fond')
        base = re.search(r'<Style x:Key="BaseButton".*?<Style TargetType="Button" BasedOn="\{StaticResource BaseButton\}"/>', main_xaml, re.S)[0]
        filled = re.search(r'<ControlTemplate x:Key="UxFilledButtonTemplate".*?</ControlTemplate>', main_xaml, re.S)
        require(filled and 'BgReadonly' in filled[0] and 'MutedColor' in filled[0], 'Boutons pleins sans style desactive lisible')
        stop = re.search(r'<Style x:Key="UxStopButton".*?</Style>', main_xaml, re.S)
        require(stop and 'Property="Visibility" Value="Hidden"' in stop[0], 'Arreter reste visible quand rien ne tourne')
        for name in ('BtnFleetRefreshStop', 'BtnSearchRefreshStop', 'BtnComputerParkStop'):
            require(re.search(r'x:Name="%s"[^>]*Style="\{StaticResource UxStopButton\}"' % name, main_xaml), name + ' sans style UxStopButton')
        require('Property="Opacity" Value="0.45"' not in base and 'Property="Opacity" Value="0.92"' not in base, 'Opacite au survol ou a la desactivation')
        disabled = re.search(r'<Trigger Property="IsEnabled" Value="False">(.*?)</Trigger>', base, re.S)
        require(disabled and 'BgReadonly' in disabled[1] and 'MutedColor' in disabled[1], 'Style desactive dedie absent')
        require('IsKeyboardFocused' not in base, 'Deux anneaux de focus (bordure et FocusVisualStyle)')
        return 'carte/fond sombre %.2f:1' % contrast(dark['BgCard'], dark['WindowBg'])
    check('DS-11 : boutons desactives lisibles, cartes sombres visibles, un seul anneau de focus', disabled_and_cards)

    # ------------------------------------------------------------------ DS-18
    def frame_and_scrollbars():
        native = (root / 'wad/modules/Domenia-Identity.Types.cs').read_text(encoding='utf-8-sig')
        require('class WindowFrame' in native and 'DwmSetWindowAttribute(hwnd, 20,' in native and 'DwmSetWindowAttribute(hwnd, 19,' in native, 'Appel DWM absent')
        require(not re.search(r'\$"|\?\.|nameof\(|=>', native), 'Syntaxe posterieure a C# 5')
        plan = (root / 'wad/Domenia-Modules.ps1').read_text(encoding='utf-8-sig')
        require(re.search(r"File='Domenia-Identity\.Types\.cs'; Types=@\([^)]*'Domenia\.WindowFrame'", plan), 'Type non declare au chargeur')
        require('Set-DomeniaWindowFrameTheme -Window $window -Theme $Theme' in fn('Apply-DomeniaTheme'), 'Theme applique sans la barre de titre')
        require('Set-DomeniaWindowFrameTheme' in fn('ConvertFrom-DomeniaXaml'), 'Fenetres d amorcage sans barre de titre du theme')
        style = re.search(r'<Style TargetType="ScrollBar">.*?\n    </Style>', main_xaml, re.S)
        require(style, 'Style ScrollBar absent')
        body = style[0]
        require('Property="Width" Value="8"' in body and 'Property="Height" Value="8"' in body, 'Barres plus larges que 8')
        require('LineUpCommand' not in body and 'LineDownCommand' not in body and 'LineLeftCommand' not in body, 'Fleches presentes')
        thumb = re.search(r'<Style x:Key="UxScrollThumb".*?</Style>', main_xaml, re.S)[0]
        require('{DynamicResource ScrollThumb}' in thumb and '{DynamicResource ScrollThumbHover}' in thumb and 'CornerRadius' in thumb, 'Pouce hors jetons')
        return ''
    check('DS-18 : barre de titre du theme et barres de defilement fines sans fleches', frame_and_scrollbars)

    # ------------------------------------------------------------------ FO-22
    def automatic_and_high_contrast():
        exp = functions(experience)
        settings = fn('ConvertTo-DomeniaExperienceSettings', experience, exp)
        require("Theme=@('Light','Dark','Auto')" in settings, 'Choix Automatique refuse par les preferences')
        reader = fn('Get-DomeniaWindowsAppTheme')
        require("OpenSubKey('Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize',$false)" in reader, 'Lecture du registre non bornee a HKCU en lecture seule')
        require('SetValue' not in reader and 'CreateSubKey' not in reader, 'Ecriture dans le registre')
        roles = dict(re.findall(r"^\s+(\w+)='(\w+)'$", fn('Get-DomeniaHighContrastRoles', experience, exp), re.M))
        require(set(roles) == set(palettes['Light']), 'Jetons sans role de contraste eleve : ' + ', '.join(sorted(set(palettes['Light']) - set(roles))))
        allowed = {'Window', 'WindowText', 'Control', 'ControlText', 'Highlight', 'HighlightText', 'HotTrack', 'GrayText'}
        require(set(roles.values()) <= allowed, 'Role systeme inconnu')
        palette = fn('Set-DomeniaUxPalette', (root / 'wad/modules/Domenia-UX.UI.ps1').read_text(encoding='utf-8-sig'), functions((root / 'wad/modules/Domenia-UX.UI.ps1').read_text(encoding='utf-8-sig')))
        require('[Windows.SystemParameters]::HighContrast' in palette and 'ConvertTo-DomeniaHighContrastPalette' in palette, 'Contraste eleve non suivi')
        return '%d jetons avec un role systeme' % len(roles)
    check('FO-22 : theme automatique (HKCU, lecture seule) et contraste eleve sur chaque jeton', automatic_and_high_contrast)

    # ------------------------------------------------------------------ UI-11
    def help_panel():
        defaults = fn('Get-DomeniaDefaultSettings')
        require('UxHelpVisible    = $false' in defaults and 'UxHelpIntroSeen  = $false' in defaults, 'Aide ouverte par defaut ou pastille sans preference')
        require('<ColumnDefinition x:Name="UxHelpColumn" Width="0"/>' in main_xaml, 'Colonne d aide ouverte avant le premier calcul')
        panel = re.search(r'x:Name="UxHelpPanel".*?</ScrollViewer>', main_xaml, re.S)[0]
        require(panel.index('LblContextTitle') < panel.index('LblUxSelected') < panel.index('BtnUxStep1'), 'La carte utile n est pas en tete')
        require('Aucune action n’est lancée par ce panneau.' not in panel, 'Phrase de reassurance')
        shell_chapters = re.findall(r"(\w+)=@\('(technicien|administrateur)',(\d+),'([^']+)'\)", fn('Get-DomeniaHelpGuideChapter', shell, shell_spans))
        require(len(shell_chapters) >= 10, 'Chapitres du guide introuvables')
        guides = root.parent / 'guides'
        if guides.is_dir():
            for page, guide, number, title in shell_chapters + [('', 'technicien', '9', 'Repères')]:
                text = (guides / (guide + '.md')).read_text(encoding='utf-8')
                require(re.search(r'^# %s %s\s*$' % (number, re.escape(title.replace('ʼ', '’'))), text, re.M) or re.search(r'^# %s %s\s*$' % (number, re.escape(title)), text, re.M),
                        'Chapitre absent du guide %s : %s %s' % (guide, number, title))
            return '%d pages reliees a un chapitre existant des guides' % len(shell_chapters)
        return '%d pages reliees (guides non disponibles ici)' % len(shell_chapters)
    check('UI-11 : aide fermee au depart, carte utile en tete, chapitres reels des guides', help_panel)

    # ------------------------------------------------------------------ PF-24 / UI-10
    def single_help_source():
        sys.path.insert(0, str(root / 'tools'))
        import strip_xaml_help
        summary = strip_xaml_help.run(root, False)
        require(summary['Status'] == 'PASS', 'Aides revenues dans le XAML : ' + ', '.join(summary['Controls'][:8]))
        for style in ('DataGridColumnHeader', 'DataGridRow', 'TreeViewItem', 'MenuItem'):
            body = re.search(r'\n    <Style TargetType="%s">.*?\n    </Style>' % style, main_xaml, re.S)
            require(body and 'Property="ToolTip"' not in body[0], 'Infobulle generique dans le style ' + style)
        ux = (root / 'wad/modules/Domenia-UX.UI.ps1').read_text(encoding='utf-8-sig')
        init = fn('Initialize-DomeniaUxControlHelp', ux, functions(ux))
        require('Set-DomeniaUxCatalogueToolTip' in init and '$entry.Text' not in init.split('Set-DomeniaUxCatalogueToolTip')[0], 'Infobulle posee hors de la regle de presentation')
        return 'XAML principal %d octets ; %d controles dynamiques gardent leur infobulle' % (summary['XamlBytesAfter'], len(summary['UncataloguedWithToolTip']))
    check('PF-24 / UI-10 : aides en source unique, aucune infobulle generique de style', single_help_source)

    # ------------------------------------------------------------------ boot windows
    roles = dict(re.findall(r"(\w+)='(\w+)'", re.search(r'\$roles = \[ordered\]@\{(.*?)\}', fn('Get-DomeniaBootThemePalette'), re.S)[1]))
    styles = re.search(r"\$styles = @'\n(.*?)\n'@", fn('Get-DomeniaBootThemeResources'), re.S)[1]
    for theme, palette in palettes.items():
        boot = {role: palette[token] for role, token in roles.items()}
        for factory in ('Get-DomeniaStandardLoginXaml', 'Get-DomeniaStartupXaml'):
            raw = literal(factory)
            brushes = '\n'.join('<SolidColorBrush x:Key="DomeniaBoot%s" Color="%s"/>' % kv for kv in boot.items())
            xml = raw.replace('<Window.Resources>', '<Window.Resources>\n' + brushes + '\n' + styles, 1)

            def validate(xml=xml, boot=boot):
                doc = ET.fromstring(xml)
                resources = doc.find('{' + WPF + '}Window.Resources')
                require(resources is not None)
                # Every resource dictionary of the window (Window.Resources and the nested Grid.Resources...).
                resource_map = {}
                for dictionary in [d for d in doc.iter() if d.tag.endswith('.Resources')]:
                    local_keys = set()
                    for item in dictionary:
                        key = item.get('{' + X + '}Key')
                        if key is None and item.tag.endswith('}Style'):
                            key = 'Type:' + item.get('TargetType')
                        require(key is not None, 'Ressource sans cle')
                        require(key not in local_keys, 'Ressource en double ' + key)
                        local_keys.add(key)
                        resource_map.setdefault(key, item)
                duplicates = scoped_duplicates(doc)
                require(not duplicates, 'x:Name en double : ' + ', '.join(duplicates))
                for key in re.findall(r'\{(?:Static|Dynamic)Resource\s+([^}]+)\}', xml):
                    require(key.startswith('{x:Type') or key in resource_map, 'Ressource absente ' + key)

                def style_values(style, seen=()):
                    values = {}
                    base = style.get('BasedOn')
                    if base:
                        match = re.fullmatch(r'\{StaticResource ([^}]+)\}', base)
                        if match and match[1] in resource_map:
                            require(match[1] not in seen, 'Cycle de styles')
                            values.update(style_values(resource_map[match[1]], seen + (match[1],)))
                    for setter in style.findall('{' + WPF + '}Setter'):
                        if 'Value' in setter.attrib:
                            values[setter.get('Property')] = setter.get('Value')
                    return values

                def resolve(value):
                    if not value or value == 'Transparent':
                        return None
                    if value.startswith('#'):
                        return value
                    match = re.fullmatch(r'\{(?:Static|Dynamic)Resource ([^}]+)\}', value)
                    if not match or match[1] not in resource_map:
                        return None
                    return resource_map[match[1]].get('Color')

                parents = {child: parent for parent in doc.iter() for child in parent}

                def effective(item, prop):
                    if prop in item.attrib:
                        return resolve(item.get(prop))
                    key = 'Type:' + local(item)
                    if 'Style' in item.attrib:
                        match = re.fullmatch(r'\{StaticResource ([^}]+)\}', item.get('Style'))
                        key = match[1] if match else key
                    if key in resource_map:
                        value = style_values(resource_map[key]).get(prop)
                        if value:
                            return resolve(value)
                    if prop == 'Foreground' and item in parents:
                        return effective(parents[item], prop)
                    return None

                def background(item):
                    value = effective(item, 'Background')
                    if value:
                        return value
                    return background(parents[item]) if item in parents else boot['Window']

                measured = []
                for item in doc.iter():
                    if local(item) not in ('TextBlock', 'TextBox', 'PasswordBox', 'Button', 'CheckBox', 'Run'):
                        continue
                    node, inside = item, False
                    while node in parents:
                        node = parents[node]
                        if node.tag.endswith('.Resources') or local(node) in ('ControlTemplate', 'DataTemplate'):
                            inside = True
                            break
                    if inside:
                        continue
                    f = effective(item, 'Foreground')
                    if f is None:
                        continue
                    b = background(item)
                    ratio = contrast(f, b)
                    measured.append(ratio)
                    require(ratio >= 4.5, '%s : %s/%s = %.2f:1' % (item.get('{' + X + '}Name', local(item)), f, b, ratio))
                require(measured, 'Aucun texte mesure')
                return '%d textes ; minimum %.2f:1' % (len(measured), min(measured))
            check(theme + ' : ' + factory + ' (XML, ressources, contraste avec les roles du JSON)', validate)

    report = {'Environment': 'Python, analyse source et XML uniquement', 'NativePowerShellExecuted': False, 'WpfExecuted': False,
              'Passed': sum(r['Status'] == 'PASS' for r in results), 'Failed': sum(r['Status'] == 'FAIL' for r in results),
              'Observations': observations, 'Results': results}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('%d PASS / %d FAIL' % (report['Passed'], report['Failed']))
    return int(report['Failed'] != 0)


if __name__ == '__main__':
    raise SystemExit(main())
