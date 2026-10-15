# Point 129: rules of the native GUI journey qualification (engineering/d120/lab/Invoke-DomeniaGuiJourney.ps1).
# Test-only file: dot-sourced by wad/tests/rules and by the lab harness, never loaded by the application. Pure: no UI
# Automation, no input injection, no disk. The harness drives the real window; these rules decide what a journey may
# contain, what a capture must be, and keep simulated events apart from the human journey.
#
# Two kinds of evidence, never merged:
#   Simulated  events produced by the harness: UI Automation patterns (Invoke, Value, Scroll, Window) or operating system
#              input (keybd_event, mouse_event) sent by a program. They prove that the window reacts to those events.
#   Human      a person performs the same journey with the mouse and the keyboard and records each step in the human
#              record. The harness checks that the record is complete; it cannot verify that a person did it.
# A journey is qualified only when both are complete and successful and every capture is a 1920x1080 image taken with
# no tooltip on screen.

$script:DomeniaGuiStepKinds = @('Window','Click','Invoke','Focus','Type','Keys','Scroll','Assert','Capture')
$script:DomeniaGuiKeys = [ordered]@{
    Tab=0x09; Enter=0x0D; Escape=0x1B; Space=0x20; PageUp=0x21; PageDown=0x22; End=0x23; Home=0x24
    Left=0x25; Up=0x26; Right=0x27; Down=0x28; Delete=0x2E; F1=0x70; F5=0x76
}
$script:DomeniaGuiWindowStates = @('Normal1080','Minimize','Restore','Maximize')

function ConvertTo-DomeniaGuiKeyChord {
    # 'Tab', 'Shift+Tab', 'Ctrl+F', 'Ctrl+Shift+End': one closed key with optional Shift and Ctrl. Letters and digits are
    # accepted only with Ctrl (shortcuts); text goes through Type.
    param([Parameter(Mandatory=$true)][string]$Text)
    $parts = @($Text.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (($parts.Count -lt 1) -or ($parts.Count -gt 3)) { throw ('Combinaison de touches invalide : ' + $Text) }
    $shift = $false; $control = $false
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        switch ($parts[$i]) {
            'Shift' { if ($shift) { throw ('Shift en double : ' + $Text) }; $shift = $true }
            'Ctrl' { if ($control) { throw ('Ctrl en double : ' + $Text) }; $control = $true }
            default { throw ('Modificateur inconnu : ' + $parts[$i]) }
        }
    }
    $key = $parts[$parts.Count - 1]
    $code = $null
    if ($script:DomeniaGuiKeys.Contains($key)) { $code = [int]$script:DomeniaGuiKeys[$key] }
    elseif ($control -and ($key -cmatch '^[A-Z0-9]$')) { $code = [int][char]$key }
    if ($null -eq $code) { throw ('Touche hors liste fermée : ' + $key) }
    return [pscustomobject]@{ Key=$key; VirtualKey=$code; Shift=$shift; Control=$control; Text=$Text }
}

function Test-DomeniaGuiTypedText {
    # Text typed character by character as Unicode keyboard events (KEYEVENTF_UNICODE), so the result does not depend on
    # the keyboard layout of the test machine. Letters, digits, space and . _ @ \ - only, 1 to 200 characters.
    param([AllowEmptyString()][string]$Text)
    if (($Text.Length -lt 1) -or ($Text.Length -gt 200)) { throw 'Texte à saisir vide ou trop long (200 caractères au plus).' }
    if ($Text -cnotmatch '^[\p{L}\p{Nd} ._@\\-]+$') { throw ('Caractère non saisissable par le banc dans « ' + $Text + ' ».') }
    return $Text
}

function Test-DomeniaGuiJourneyDefinition {
    # Errors of a journey file (DomeniaGuiJourneys/1). Empty array when valid.
    param($Definition)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Definition) { $errors.Add('Définition absente.'); return ,($errors.ToArray()) }
    if ([string](Get-DomeniaGuiMember $Definition 'Schema') -cne 'DomeniaGuiJourneys/1') { $errors.Add('Schéma attendu DomeniaGuiJourneys/1.') }
    $journeys = @(Get-DomeniaGuiMember $Definition 'Journeys')
    $journeys = @($journeys | Where-Object { $null -ne $_ })
    if (-not $journeys.Count) { $errors.Add('Aucun parcours.') }
    $ids = @{}; $captures = @{}
    foreach ($journey in $journeys) {
        $id = [string](Get-DomeniaGuiMember $journey 'Id')
        if ($id -cnotmatch '^[a-z][a-z0-9-]{1,40}$') { $errors.Add('Identifiant de parcours invalide : ' + $id); continue }
        if ($ids.ContainsKey($id)) { $errors.Add('Parcours en double : ' + $id) }
        $ids[$id] = $true
        if (-not [string](Get-DomeniaGuiMember $journey 'Label')) { $errors.Add($id + ' : libellé absent.') }
        $steps = @(@(Get-DomeniaGuiMember $journey 'Steps') | Where-Object { $null -ne $_ })
        if (-not $steps.Count) { $errors.Add($id + ' : aucune étape.') }
        $index = 0
        foreach ($step in $steps) {
            $index++
            $where = $id + ' étape ' + $index
            $kind = [string](Get-DomeniaGuiMember $step 'Kind')
            if ($kind -cnotin $script:DomeniaGuiStepKinds) { $errors.Add($where + ' : type inconnu ' + $kind); continue }
            $control = [string](Get-DomeniaGuiMember $step 'Id')
            if (($kind -cin @('Click','Invoke','Focus','Scroll','Assert')) -and ($control -cnotmatch '^[A-Za-z][A-Za-z0-9_]{1,80}$')) { $errors.Add($where + ' : contrôle (AutomationId) absent ou invalide.') }
            switch ($kind) {
                'Window' { if ([string](Get-DomeniaGuiMember $step 'State') -cnotin $script:DomeniaGuiWindowStates) { $errors.Add($where + ' : état de fenêtre inconnu.') } }
                'Type' { try { [void](Test-DomeniaGuiTypedText ([string](Get-DomeniaGuiMember $step 'Text'))) } catch { $errors.Add($where + ' : ' + $_.Exception.Message) } }
                'Keys' {
                    $keys = @(Get-DomeniaGuiMember $step 'Keys')
                    if (-not $keys.Count) { $errors.Add($where + ' : aucune touche.') }
                    foreach ($key in $keys) { try { [void](ConvertTo-DomeniaGuiKeyChord ([string]$key)) } catch { $errors.Add($where + ' : ' + $_.Exception.Message) } }
                }
                'Scroll' {
                    $notches = 0
                    if ((-not [int]::TryParse([string](Get-DomeniaGuiMember $step 'Notches'),[ref]$notches)) -or ($notches -eq 0) -or ([Math]::Abs($notches) -gt 50)) { $errors.Add($where + ' : crans de molette entre -50 et 50, non nuls.') }
                }
                'Capture' {
                    $name = [string](Get-DomeniaGuiMember $step 'Name')
                    if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{1,40}$') { $errors.Add($where + ' : nom de capture invalide.') }
                    elseif ($captures.ContainsKey($id + '/' + $name)) { $errors.Add($where + ' : capture en double ' + $name) }
                    else { $captures[$id + '/' + $name] = $true }
                }
            }
        }
    }
    return ,($errors.ToArray())
}

function Get-DomeniaGuiMember {
    # Member of a PSCustomObject or dictionary; $null when absent (no StrictMode failure).
    param($InputObject,[string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) { if ($InputObject.Contains($Name)) { return $InputObject[$Name] }; return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-DomeniaGuiCapture {
    # A qualifying capture is exactly 1920x1080 and was taken while no tooltip was on screen.
    param([int]$Width,[int]$Height,[int]$TooltipCount)
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if (($Width -ne 1920) -or ($Height -ne 1080)) { $reasons.Add('Capture de ' + $Width + '×' + $Height + ' au lieu de 1920×1080.') }
    if ($TooltipCount -gt 0) { $reasons.Add([string]$TooltipCount + ' infobulle(s) à lʼécran au moment de la capture.') }
    if ($TooltipCount -lt 0) { $reasons.Add('Présence dʼinfobulle non vérifiée.') }
    return [pscustomobject]@{ Valid=($reasons.Count -eq 0); Reasons=$reasons.ToArray() }
}

function New-DomeniaGuiHumanTemplate {
    # Record a person fills while doing the journeys by hand. Result: OK or KO per step; nothing is pre-filled.
    param($Definition)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($journey in @(Get-DomeniaGuiMember $Definition 'Journeys')) {
        $index = 0
        foreach ($step in @(Get-DomeniaGuiMember $journey 'Steps')) {
            $index++
            $rows.Add([pscustomobject]@{ Journey=[string]$journey.Id; Step=$index; Action=(Format-DomeniaGuiStep $step); Result=''; Note='' })
        }
    }
    return [pscustomobject]@{
        Schema='DomeniaGuiHumanRecord/1'; Tester=''; Date=''; Computer=''; Screen=''
        Statement='Parcours réalisé à la main, à la souris et au clavier, sans outil dʼautomatisation.'
        Steps=$rows.ToArray()
    }
}

function Format-DomeniaGuiStep {
    # French description of one step, for the human record and the report.
    param($Step)
    $id = [string](Get-DomeniaGuiMember $Step 'Id')
    switch ([string](Get-DomeniaGuiMember $Step 'Kind')) {
        'Window' { return ('Fenêtre : ' + [string](Get-DomeniaGuiMember $Step 'State')) }
        'Click' { return ('Cliquer sur ' + $id) }
        'Invoke' { return ('Activer ' + $id) }
        'Focus' { return ('Placer le focus sur ' + $id) }
        'Type' { return ('Saisir « ' + [string](Get-DomeniaGuiMember $Step 'Text') + ' »') }
        'Keys' { return ('Touches : ' + (@(Get-DomeniaGuiMember $Step 'Keys') -join ', ')) }
        'Scroll' { return ('Molette sur ' + $id + ' : ' + [string](Get-DomeniaGuiMember $Step 'Notches') + ' cran(s)') }
        'Assert' { return ('Vérifier ' + $id) }
        'Capture' { return ('Capture ' + [string](Get-DomeniaGuiMember $Step 'Name') + ' (1920×1080, sans infobulle)') }
    }
    return 'Étape inconnue'
}

function Test-DomeniaGuiHumanRecord {
    # Completeness of a human record against the journey file. Declared evidence: the content is the tester's word.
    param($Record,$Definition)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Record) { return [pscustomobject]@{ Complete=$false; Passed=0; Failed=0; Errors=@('Aucun relevé humain.'); Tester=''; Date='' } }
    if ([string](Get-DomeniaGuiMember $Record 'Schema') -cne 'DomeniaGuiHumanRecord/1') { $errors.Add('Schéma attendu DomeniaGuiHumanRecord/1.') }
    $tester = ([string](Get-DomeniaGuiMember $Record 'Tester')).Trim()
    if (-not $tester) { $errors.Add('Nom du testeur absent.') }
    $date = ([string](Get-DomeniaGuiMember $Record 'Date')).Trim()
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { $errors.Add('Date attendue AAAA-MM-JJ.') }
    $expected = @{}
    foreach ($row in @((New-DomeniaGuiHumanTemplate $Definition).Steps)) { $expected[[string]$row.Journey + '#' + [string]$row.Step] = $true }
    $passed = 0; $failed = 0; $seen = @{}
    foreach ($row in @(Get-DomeniaGuiMember $Record 'Steps')) {
        if ($null -eq $row) { continue }
        $key = [string](Get-DomeniaGuiMember $row 'Journey') + '#' + [string](Get-DomeniaGuiMember $row 'Step')
        if (-not $expected.ContainsKey($key)) { $errors.Add('Étape inconnue du relevé : ' + $key); continue }
        if ($seen.ContainsKey($key)) { $errors.Add('Étape en double : ' + $key); continue }
        $seen[$key] = $true
        switch ([string](Get-DomeniaGuiMember $row 'Result')) {
            'OK' { $passed++ }
            'KO' { $failed++ }
            default { $errors.Add('Résultat OK ou KO attendu : ' + $key) }
        }
    }
    foreach ($key in @($expected.Keys)) { if (-not $seen.ContainsKey($key)) { $errors.Add('Étape non relevée : ' + $key) } }
    return [pscustomobject]@{ Complete=($errors.Count -eq 0); Passed=$passed; Failed=$failed; Errors=$errors.ToArray(); Tester=$tester; Date=$date }
}

function Get-DomeniaGuiJourneyVerdict {
    # Overall verdict. 'Qualifié' needs every declared journey run (Selected covers Defined), every simulated step
    # successful, every capture valid AND a complete human record without KO. Simulated events alone never qualify a
    # journey; a run limited to some journeys (-Journeys, for diagnosis) is 'Partiel' and names what did not run.
    param([int]$SimulatedPassed,[int]$SimulatedFailed,[int]$CapturesValid,[int]$CapturesInvalid,$Human,[string[]]$Selected=@(),[string[]]$Defined=@())
    if (($SimulatedFailed -gt 0) -or ($CapturesInvalid -gt 0)) { return [pscustomobject]@{ Status='Échec'; Qualified=$false; Text='Au moins une étape simulée ou une capture a échoué.' } }
    if ($SimulatedPassed -le 0) { return [pscustomobject]@{ Status='Non exécuté'; Qualified=$false; Text='Aucune étape simulée exécutée.' } }
    $declared = @($Defined | Where-Object { [string]$_ })
    if (-not $declared.Count) { return [pscustomobject]@{ Status='Partiel'; Qualified=$false; Text='Parcours déclarés non indiqués : couverture du passage inconnue.' } }
    $notRun = @($declared | Where-Object { @($Selected) -cnotcontains [string]$_ })
    if ($notRun.Count) {
        $ran = @($declared | Where-Object { @($Selected) -ccontains [string]$_ })
        return [pscustomobject]@{ Status='Partiel'; Qualified=$false; Text=('Passage partiel : ' + ($ran -join ', ') + ' exécuté(s) ; ' + ($notRun -join ', ') + ' non exécuté(s). Seul un passage de tous les parcours qualifie.') }
    }
    $complete = $false; $humanFailed = 0
    if ($null -ne $Human) { $complete = [bool](Get-DomeniaGuiMember $Human 'Complete'); $humanFailed = [int](Get-DomeniaGuiMember $Human 'Failed') }
    if (-not $complete) { return [pscustomobject]@{ Status='Simulé seulement'; Qualified=$false; Text='Événements simulés réussis ; parcours humain non relevé ou incomplet.' } }
    if ($humanFailed -gt 0) { return [pscustomobject]@{ Status='Échec humain'; Qualified=$false; Text='Le relevé humain signale au moins une étape KO.' } }
    return [pscustomobject]@{ Status='Qualifié'; Qualified=$true; Text='Événements simulés, captures et parcours humain concordants.' }
}
