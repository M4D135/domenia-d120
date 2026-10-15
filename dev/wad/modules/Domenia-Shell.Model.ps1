# Shell rules: page and target in the title, layout that does not move, in-page requests with a
# continuation, explicit column views, selection preview, operation summary, informative empty states,
# help for disabled controls, controlled activation, contrast, bounded window restore and status glyphs.
# Pure decisions: no WPF object, no window, no timer, no clock and no disk access is used here.
# Relies on Domenia-Common (Get-DomeniaMember, ConvertTo-DomeniaFlatText, Get-DomeniaTextHash,
# ConvertTo-DomeniaGuidText), Domenia-Relations (ConvertTo-DomeniaRelationType) and Domenia-Access
# (Get-DomeniaCapabilityExplanation, Protect-DomeniaSecretText).

# ---------------------------------------------------------------- shared helpers of this module
function Get-DomeniaShellFirstValue {
    # First non-empty member among several possible names, as one bounded line.
    param($InputObject,[string[]]$Names=@(),[int]$Maximum=80)
    foreach ($name in $Names) {
        $value = Get-DomeniaMember $InputObject $name $null
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return (ConvertTo-DomeniaFlatText ([string]$value) $Maximum) }
    }
    return ''
}

function ConvertTo-DomeniaShellValueText {
    # Display text of an option value: Oui/Non, list joined, date in a fixed format, one bounded line.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return 'Oui' }; return 'Non' }
    if ($Value -is [datetime]) { return $Value.ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture) }
    # A dictionary is shown as one text: the foreach statement would not enumerate it.
    if ($Value -is [Collections.IDictionary]) { return (ConvertTo-DomeniaFlatText ([string]$Value) 160) }
    if (($Value -is [Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $parts = @(foreach ($item in $Value) { ConvertTo-DomeniaShellValueText $item })
        return (ConvertTo-DomeniaFlatText ($parts -join ', ') 160)
    }
    if (($Value -is [double]) -or ($Value -is [single]) -or ($Value -is [decimal])) {
        return ([double]$Value).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR'))
    }
    return (ConvertTo-DomeniaFlatText ([string]$Value) 160)
}

function ConvertTo-DomeniaShellRect {
    # {Left, Top, Width, Height} as finite doubles, or $null when a member is missing or not a number.
    param($Value)
    if ($null -eq $Value) { return $null }
    $parts = @{}
    foreach ($name in @('Left','Top','Width','Height')) {
        $raw = Get-DomeniaMember $Value $name $null
        if ($null -eq $raw) { return $null }
        $number = 0.0
        try { $number = [double]$raw } catch { return $null }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        $parts[$name] = $number
    }
    return [pscustomobject]@{Left=$parts['Left'];Top=$parts['Top'];Width=$parts['Width'];Height=$parts['Height']}
}

# ---------------------------------------------------------------- D081 page and target in the title
function Get-DomeniaShellPages {
    # Top-level destinations. Only Rechercher and Parcourir choose the subject; every other page shows the
    # global selection. Relations may search an association target, which is not a second subject picker.
    return @(
        [pscustomobject]@{Id='TabDashboard';Label='Accueil';Subject='Selection';SubjectPicker=$false;TargetPicker=$false}
        [pscustomobject]@{Id='WsQueryWorkshop';Label='Atelier de requêtes';Subject='Selection';SubjectPicker=$false;TargetPicker=$false}
        [pscustomobject]@{Id='WsSearch';Label='Rechercher';Subject='Selection';SubjectPicker=$true;TargetPicker=$false}
        [pscustomobject]@{Id='TabDirectory';Label='Parcourir';Subject='Selection';SubjectPicker=$true;TargetPicker=$false}
        [pscustomobject]@{Id='WsObject';Label='Fiche';Subject='Selection';SubjectPicker=$false;TargetPicker=$false}
        [pscustomobject]@{Id='WsComputer';Label='Poste';Subject='Machine';SubjectPicker=$false;TargetPicker=$false}
        [pscustomobject]@{Id='TabRelations';Label='Utilisateurs et postes';Subject='Selection';SubjectPicker=$false;TargetPicker=$true}
        [pscustomobject]@{Id='TabAccounts';Label='Comptes';Subject='Selection';SubjectPicker=$false;TargetPicker=$false}
        [pscustomobject]@{Id='TabApplicationTools';Label='Outils';Subject='Selection';SubjectPicker=$false;TargetPicker=$false}
        # L08 (UI-29): the page title is the menu label; the support workshop keeps its own label when it is shown.
        [pscustomobject]@{Id='TabSupport';Label='Atelier support';Subject='Selection';SubjectPicker=$false;TargetPicker=$false}
    )
}

function Test-DomeniaSelectorAllowed {
    # A subject picker belongs to Rechercher and Parcourir only; an association target picker to Relations only.
    param([Parameter(Mandatory=$true)][string]$Page,[ValidateSet('Subject','AssociationTarget')][string]$Role='Subject')
    $row = @(Get-DomeniaShellPages | Where-Object { $_.Id -eq $Page })
    if ($row.Count -ne 1) { return $false }
    if ($Role -eq 'Subject') { return [bool]$row[0].SubjectPicker }
    return [bool]$row[0].TargetPicker
}

function Get-DomeniaPageTitle {
    # The page header and the window title always carry the active page AND its target ("Fiche · Jean Dupont").
    # Without a target the title says so; it never keeps the name of a previous target.
    # L08 (UI-01, UI-29): the label is the menu label; the window title reads "Fiche · Camille Martin — Domenia".
    param(
        [Parameter(Mandatory=$true)][string]$Page,
        [AllowEmptyString()][AllowNull()][string]$TargetName='',
        [AllowEmptyString()][AllowNull()][string]$TargetType='',
        [bool]$WriteEnabled=$false,
        [AllowEmptyString()][string]$ApplicationName='Domenia'
    )
    $row = @(Get-DomeniaShellPages | Where-Object { $_.Id -eq $Page })
    $label = ConvertTo-DomeniaFlatText $Page 40
    $subject = 'Selection'
    if ($row.Count -eq 1) { $label = [string]$row[0].Label; $subject = [string]$row[0].Subject }
    $name = ConvertTo-DomeniaFlatText $TargetName 80
    $hasTarget = -not [string]::IsNullOrWhiteSpace($name)
    # Workstation support only ever targets a workstation: a selected user is not its target.
    if ($hasTarget -and ($subject -eq 'Machine') -and ((ConvertTo-DomeniaRelationType $TargetType) -ne 'Machine')) { $hasTarget = $false }
    $target = $name
    if (-not $hasTarget) {
        if ($subject -eq 'Machine') { $target = 'Aucun poste sélectionné' } else { $target = 'Aucune sélection' }
    }
    $header = $label + ' · ' + $target
    $windowTitle = $header
    if (-not [string]::IsNullOrWhiteSpace($ApplicationName)) { $windowTitle = $header + ' — ' + $ApplicationName.Trim() }
    if ($WriteEnabled) { $windowTitle += '  [ÉCRITURE AD ACTIVE]' }
    # Chip near the page title (UI-01): "Poste · PC-COMPTA-014", only with a real target of this page.
    $chip = ''
    if ($hasTarget) {
        $kind = ConvertTo-DomeniaRelationType $TargetType
        $kindLabel = 'Fiche'
        if ($kind -eq 'Machine') { $kindLabel = 'Poste' } elseif ($kind -eq 'Utilisateur') { $kindLabel = 'Utilisateur' }
        elseif ([string]$TargetType -eq 'Groupe') { $kindLabel = 'Groupe' }
        $chip = $kindLabel + ' · ' + $name
    }
    return [pscustomobject]@{Page=$Page;PageLabel=$label;Target=$target;HasTarget=$hasTarget;Header=$header;WindowTitle=$windowTitle;Chip=$chip}
}

# ---------------------------------------------------------------- D082 layout that does not move
function Get-DomeniaCounterText {
    # Badge text: nothing for zero, the number up to 99, then "99+". Same contract as the former isolated module.
    # -ZeroText '0' keeps the text of a hidden badge at zero (the main window badges are Hidden at zero, so the
    # rendering is identical); any other zero text is refused.
    [CmdletBinding()]
    param([ValidateRange(0,2147483647)][int]$Count,[AllowEmptyString()][string]$ZeroText='')
    if (($ZeroText -cne '') -and ($ZeroText -cne '0')) { throw 'Texte a zero non pris en charge : seul 0 ou vide.' }
    if ($Count -eq 0) { return $ZeroText }
    if ($Count -gt 99) { return '99+' }
    return $Count.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Get-DomeniaActivityStripSlots {
    # Fixed slots of the main window activity strip (in the page header bar) and header badges (device-independent units), as reserved in
    # the main XAML. Busy, idle, 0, 1, 10 or 100 tasks and a long message only change texts and visibility inside
    # these slots: an empty slot is Hidden, never Collapsed, so no neighbour moves.
    # L08 (DS-01): Accès and Opérations are 40-unit icon buttons; their counter is a pill laid over the icon corner,
    # shown above zero only, so it takes no room of its own.
    return [pscustomobject]@{
        HostName='UxPageHeaderBar';HostMinHeight=44.0;StripName='UxActivityStrip';StripHeight=44.0
        StripColumns=@('*','252','144','96')
        Slots=@(
            [pscustomobject]@{Name='PbTop';Width=130.0;Height=8.0;Role='Activite'}
            [pscustomobject]@{Name='BtnCancelTask';Width=96.0;Height=32.0;Role='Action'}
            [pscustomobject]@{Name='LblTaskElapsed';Width=[double]::NaN;Height=24.0;Role='Message'}
            [pscustomobject]@{Name='WriteModeBanner';Width=240.0;Height=32.0;Role='Etat'}
            [pscustomobject]@{Name='BtnAccessRecovery';Width=40.0;Height=40.0;Role='Action'}
            [pscustomobject]@{Name='BtnSuiteActivity';Width=40.0;Height=40.0;Role='Action'}
            [pscustomobject]@{Name='BadgeAccessRecovery';Width=24.0;Height=16.0;Role='Compteur'}
            [pscustomobject]@{Name='BadgeSuiteActivity';Width=24.0;Height=16.0;Role='Compteur'}
        )
        EmptySlotVisibility='Hidden'
    }
}

function Compare-DomeniaReservedSlots {
    # Differences between the reserved slots and the measured declaration of the real controls.
    # $Measured: name -> {Width, MinWidth, MaxWidth, Height, MinHeight, MaxHeight} (NaN when not declared).
    # A slot whose width is NaN only reserves its height (stretching message column).
    param($Expected,$Measured)
    $issues = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Expected) { $issues.Add('Disposition reservee absente.'); return $issues.ToArray() }
    foreach ($slot in @(Get-DomeniaMember $Expected 'Slots' @())) {
        $name = [string](Get-DomeniaMember $slot 'Name' '')
        $actual = Get-DomeniaMember $Measured $name $null
        if ($null -eq $actual) { $issues.Add($name + ' : controle absent.'); continue }
        foreach ($axis in @('Width','Height')) {
            $wanted = [double](Get-DomeniaMember $slot $axis ([double]::NaN))
            if ([double]::IsNaN($wanted)) { continue }
            $declared = [double](Get-DomeniaMember $actual $axis ([double]::NaN))
            if ([double]::IsNaN($declared) -or ([Math]::Abs($declared - $wanted) -gt 0.01)) {
                $issues.Add($name + ' : ' + $axis + ' declare ' + [string]$declared + ' au lieu de ' + [string]$wanted + '.')
                continue
            }
            # A fixed slot is not allowed to grow: when a maximum is declared it must equal the reserved size.
            $maximum = [double](Get-DomeniaMember $actual ('Max' + $axis) ([double]::PositiveInfinity))
            if ((-not [double]::IsInfinity($maximum)) -and ([Math]::Abs($maximum - $wanted) -gt 0.01)) {
                $issues.Add($name + ' : Max' + $axis + ' ' + [string]$maximum + ' different de ' + [string]$wanted + '.')
            }
        }
    }
    $columns = @(Get-DomeniaMember $Measured '__StripColumns' @())
    $wantedColumns = @(Get-DomeniaMember $Expected 'StripColumns' @())
    if ($columns.Count -ne $wantedColumns.Count) { $issues.Add('Bandeau d activite : ' + [string]$columns.Count + ' colonne(s) au lieu de ' + [string]$wantedColumns.Count + '.') }
    else {
        for ($i = 0; $i -lt $columns.Count; $i++) {
            if ([string]$columns[$i] -cne [string]$wantedColumns[$i]) { $issues.Add('Bandeau d activite : colonne ' + [string]$i + ' = ' + [string]$columns[$i] + ' au lieu de ' + [string]$wantedColumns[$i] + '.') }
        }
    }
    foreach ($pair in @(@('__RowHeight','RowHeight'),@('__StripHeight','StripHeight'))) {
        $value = [double](Get-DomeniaMember $Measured $pair[0] ([double]::NaN))
        $wantedValue = [double](Get-DomeniaMember $Expected $pair[1] ([double]::NaN))
        if ([double]::IsNaN($value) -or ([Math]::Abs($value - $wantedValue) -gt 0.01)) { $issues.Add($pair[1] + ' = ' + [string]$value + ' au lieu de ' + [string]$wantedValue + '.') }
    }
    return $issues.ToArray()
}

function Get-DomeniaReservedLayout {
    # Fixed slots for the activity indicator, the task counter, the status message and the actions.
    # Sizes depend on the scale and the available width only, never on the number of tasks or on the text:
    # 0, 1, 10 or 100 tasks and a long message move no neighbour. An empty slot is Hidden, never Collapsed.
    # When the width is short (small window, 200 %), actions move to an overflow menu: none is clipped down to
    # MinimumWidth (fixed slots + overflow button + shortest message). Below it the bar cannot hold its slots:
    # Clipped is reported and the window must not be allowed narrower than MinimumWidth.
    param(
        [ValidateRange(0,2147483647)][int]$TaskCount=0,
        [AllowEmptyString()][AllowNull()][string]$Message='',
        [ValidateRange(1,8)][int]$ActionCount=3,
        [double]$Scale=1.0,
        [double]$AvailableWidth=0
    )
    $s = $Scale
    if ([double]::IsNaN($s) -or [double]::IsInfinity($s) -or $s -lt 1.0) { $s = 1.0 }
    if ($s -gt 4.0) { $s = 4.0 }
    $activity = 20.0 * $s
    $counter = 36.0 * $s
    $gaps = 36.0 * $s
    $button = 112.0 * $s
    $buttonGap = 8.0 * $s
    $overflowButton = 40.0 * $s
    $messagePreferred = 360.0 * $s
    $messageMinimum = 160.0 * $s
    $fixed = $activity + $counter + $gaps
    $visible = $ActionCount
    $actions = ($ActionCount * $button) + (($ActionCount - 1) * $buttonGap)
    $messageWidth = $messagePreferred
    if (($AvailableWidth -gt 0) -and -not [double]::IsInfinity($AvailableWidth)) {
        $room = $AvailableWidth - $fixed - $actions
        if ($room -lt $messagePreferred) {
            if ($room -ge $messageMinimum) {
                $messageWidth = $room
            } else {
                while (($visible -gt 0) -and (($fixed + $messageMinimum + $actions) -gt $AvailableWidth)) {
                    $visible = $visible - 1
                    $actions = $overflowButton + ($visible * ($button + $buttonGap))
                }
                $room = $AvailableWidth - $fixed - $actions
                if ($room -lt 0) { $room = 0.0 }
                $messageWidth = [Math]::Min($messagePreferred,$room)
            }
        }
    }
    $minimumWidth = $fixed + $overflowButton + $messageMinimum
    $clipped = (($AvailableWidth -gt 0) -and (-not [double]::IsInfinity($AvailableWidth)) -and ($AvailableWidth -lt $minimumWidth))
    $maxChars = [int][Math]::Floor($messageWidth / (7.0 * $s))
    if ($maxChars -lt 4) { $maxChars = 4 }
    $counterText = Get-DomeniaCounterText $TaskCount
    $activityVisibility = 'Hidden'; if ($TaskCount -gt 0) { $activityVisibility = 'Visible' }
    $counterVisibility = 'Hidden'; if ($counterText) { $counterVisibility = 'Visible' }
    # Search box: the hint starts exactly where typed text starts (border + padding + text view margin).
    $searchPadding = 8.0 * $s
    $searchBorder = 1.0 * $s
    $textLeft = $searchBorder + $searchPadding + (2.0 * $s)
    return [pscustomobject]@{
        Scale=$s
        Activity=[pscustomobject]@{Width=$activity;Visibility=$activityVisibility}
        Counter=[pscustomobject]@{Width=$counter;Text=$counterText;MaxChars=3;Visibility=$counterVisibility}
        Message=[pscustomobject]@{Width=$messageWidth;MaxChars=$maxChars;Text=(ConvertTo-DomeniaFlatText $Message $maxChars);ToolTip=(ConvertTo-DomeniaFlatText $Message 1000);Trimming='CharacterEllipsis';Wrapping='NoWrap'}
        Actions=[pscustomobject]@{Width=$actions;Count=$ActionCount;Visible=$visible;InOverflow=($ActionCount - $visible);Overflow=($visible -lt $ActionCount)}
        Search=[pscustomobject]@{Height=(34.0 * $s);Padding=$searchPadding;BorderThickness=$searchBorder;TextLeft=$textLeft;HintLeft=$textLeft;VerticalContentAlignment='Center'}
        TotalWidth=($fixed + $messageWidth + $actions)
        MinimumWidth=$minimumWidth
        Clipped=$clipped
        EmptySlotVisibility='Hidden'
    }
}

# ---------------------------------------------------------------- D083 in-page requests, no window
function New-DomeniaInlineRequest {
    # A confirmation, an association or an account change is a panel of the current page with a continuation.
    # It creates no window, starts no nested modal loop and blocks only the writes of its own scope.
    # The safe answer (also the Escape answer) and the confirming answer are named, never guessed from the
    # position of the choices: with custom -Choices, -SafeChoice is mandatory, and -ConfirmChoice as well for
    # Confirm, Associate and AccountChange. Only the confirming answer reports Confirmed.
    # -TypedConfirmation (L07, typed confirmation of a risky write): the confirming answer is accepted only with this
    # exact text typed by the operator; the safe answer never needs it.
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Confirm','Associate','AccountChange','Choice')][string]$Kind,
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][string]$Title,
        [AllowEmptyString()][string]$Message='',
        [string[]]$Choices=@(),
        [AllowEmptyString()][string]$SafeChoice='',
        [AllowEmptyString()][string]$ConfirmChoice='',
        [Parameter(Mandatory=$true)][string]$ContinuationId,
        [AllowEmptyString()][string]$Scope='',
        [AllowEmptyString()][string]$Generation='',
        [AllowEmptyString()][string]$TypedConfirmation=''
    )
    $list = @(@($Choices) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    $safe = ([string]$SafeChoice).Trim()
    $confirm = ([string]$ConfirmChoice).Trim()
    if ($list.Count -eq 0) {
        $defaults = $null
        switch ($Kind) {
            'Confirm'       { $defaults = @('Confirmer','Annuler') }
            'Associate'     { $defaults = @('Associer','Annuler') }
            'AccountChange' { $defaults = @('Utiliser ce compte','Conserver le compte actuel') }
            default         { throw 'Une demande de choix exige ses choix.' }
        }
        $list = $defaults
        # Default choices carry their own roles: the caller cannot swap them.
        if ($safe -and ($safe -cne [string]$defaults[1])) { throw 'Choix sur different du choix par defaut de cette demande.' }
        if ($confirm -and ($confirm -cne [string]$defaults[0])) { throw 'Choix de confirmation different du choix par defaut de cette demande.' }
        $confirm = [string]$defaults[0]
        $safe = [string]$defaults[1]
    } else {
        if (-not $safe) { throw 'Choix personnalises : le choix sur (Echap) doit etre nomme.' }
        if ((-not $confirm) -and ($Kind -ne 'Choice')) { throw 'Choix personnalises : le choix qui confirme doit etre nomme.' }
    }
    if ($list.Count -lt 2) { throw 'Une demande dans la page propose au moins deux choix.' }
    if (@($list | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique).Count -ne $list.Count) { throw 'Deux choix identiques ne sont pas distinguables.' }
    if ($list -cnotcontains $safe) { throw 'Le choix sur doit figurer parmi les choix proposes.' }
    if ($confirm -and ($list -cnotcontains $confirm)) { throw 'Le choix de confirmation doit figurer parmi les choix proposes.' }
    if ($confirm -and ($confirm -ieq $safe)) { throw 'Le choix sur ne peut pas confirmer.' }
    $text = [string]$Message
    if ($text.Length -gt 2000) { $text = $text.Substring(0,1999) + [string][char]0x2026 }
    $id = (Get-DomeniaTextHash ($Kind + '|' + $HostName + '|' + $ContinuationId + '|' + $Scope + '|' + $Generation)).Substring(0,16)
    return [pscustomobject]@{
        Id=$id;Kind=$Kind;HostName=$HostName;Title=(ConvertTo-DomeniaFlatText $Title 120);Message=$text
        Choices=$list;SafeChoice=$safe;ConfirmChoice=$confirm;Choice='';State='Pending'
        Presentation='Inline';CreatesWindow=$false;Modal=$false;BlocksNavigation=$false
        Scope=$Scope;Generation=$Generation;ContinuationId=$ContinuationId;TypedConfirmation=([string]$TypedConfirmation).Trim()
    }
}

function Resolve-DomeniaInlineRequest {
    # Answers a pending request once: its continuation runs at most once. A request bound to a generation is
    # answered only when the caller states the current generation and it is the same; otherwise (another target,
    # a new search, or no generation given) the request is withdrawn and its continuation never runs.
    # -Dismiss (Escape) picks the safe choice. Confirmed is true for the named confirming choice only.
    # A request with a typed confirmation is confirmed only when -Typed is that exact text (case-sensitive);
    # otherwise it stays pending and nothing runs.
    param($Request,[AllowEmptyString()][string]$Choice='',[switch]$Dismiss,[AllowEmptyString()][AllowNull()][string]$CurrentGeneration='',[AllowEmptyString()][AllowNull()][string]$Typed='')
    if ($null -eq $Request) { return [pscustomobject]@{Continue=$false;Confirmed=$false;Choice='';ContinuationId='';State='Missing';Reason='Aucune demande en attente.'} }
    $state = [string](Get-DomeniaMember $Request 'State' '')
    $continuation = [string](Get-DomeniaMember $Request 'ContinuationId' '')
    if ($state -ne 'Pending') {
        return [pscustomobject]@{Continue=$false;Confirmed=$false;Choice='';ContinuationId=$continuation;State=$state;Reason='Demande deja traitee : la suite ne s execute pas une seconde fois.'}
    }
    $requestGeneration = [string](Get-DomeniaMember $Request 'Generation' '')
    $givenGeneration = $PSBoundParameters.ContainsKey('CurrentGeneration')
    if ($requestGeneration -and (-not $givenGeneration)) {
        $Request.State = 'Expired'
        return [pscustomobject]@{Continue=$false;Confirmed=$false;Choice='';ContinuationId=$continuation;State='Expired';Reason='Contexte de la demande non verifie : rien n est execute.'}
    }
    if ($givenGeneration -and ([string]$CurrentGeneration -cne $requestGeneration)) {
        $Request.State = 'Expired'
        return [pscustomobject]@{Continue=$false;Confirmed=$false;Choice='';ContinuationId=$continuation;State='Expired';Reason='Le contexte a change depuis la demande : rien n est execute.'}
    }
    $safe = [string](Get-DomeniaMember $Request 'SafeChoice' '')
    $confirm = [string](Get-DomeniaMember $Request 'ConfirmChoice' '')
    $wanted = $Choice.Trim()
    if ($Dismiss) { $wanted = $safe }
    $picked = ''
    if ($wanted) { foreach ($candidate in @(Get-DomeniaMember $Request 'Choices' @())) { if ([string]$candidate -ieq $wanted) { $picked = [string]$candidate } } }
    if (-not $picked) {
        return [pscustomobject]@{Continue=$false;Confirmed=$false;Choice='';ContinuationId=$continuation;State='Pending';Reason='Choix non propose : la demande reste affichee.'}
    }
    $expectedTyped = [string](Get-DomeniaMember $Request 'TypedConfirmation' '')
    if ($expectedTyped -and $confirm -and ($picked -ceq $confirm) -and (([string]$Typed).Trim() -cne $expectedTyped)) {
        return [pscustomobject]@{Continue=$false;Confirmed=$false;Choice='';ContinuationId=$continuation;State='Pending';Reason='Saisie de confirmation différente du texte demandé : la demande reste affichée.'}
    }
    $Request.State = 'Answered'
    $Request.Choice = $picked
    $confirmed = ([bool]$confirm -and ($picked -ceq $confirm) -and ($picked -cne $safe))
    return [pscustomobject]@{Continue=$true;Confirmed=$confirmed;Choice=$picked;ContinuationId=$continuation;State='Answered';Reason=''}
}

function Test-DomeniaInlineRequestBlocks {
    # While a request waits, navigation, reads, selection and other targets stay available.
    # Only writes and edits of the request scope wait for the answer. A request without a scope cannot say
    # which target it protects: it holds every write and edit until it is answered (fail closed).
    param($Request,[Parameter(Mandatory=$true)][ValidateSet('Navigate','Read','Select','Write','Edit')][string]$Action,[AllowEmptyString()][string]$Scope='')
    if ($null -eq $Request) { return $false }
    if ([string](Get-DomeniaMember $Request 'State' '') -ne 'Pending') { return $false }
    if ($Action -notin @('Write','Edit')) { return $false }
    $requestScope = [string](Get-DomeniaMember $Request 'Scope' '')
    if ([string]::IsNullOrWhiteSpace($requestScope)) { return $true }
    return ($requestScope -ieq $Scope)
}

function Test-DomeniaInlineCodeSafe {
    # Static check of a business handler: no new window, no nested modal loop, no message box, no modal dialog.
    # Text patterns only: a call through an unlisted wrapper is not seen. Window::GetWindow (finding the host
    # window of a control) creates nothing and is allowed.
    param([AllowEmptyString()][AllowNull()][string]$SourceText)
    $patterns = [ordered]@{
        # Any use of the Window type (::new, cast of a hashtable, CreateInstance) or a WinForms form.
        'Nouvelle fenetre WPF'='(?i)\[\s*(System\.)?Windows\.(Navigation\.)?(Navigation)?Window\s*\](?!\s*::\s*GetWindow\b)|New-Object\s+(-TypeName\s+)?[''"]?(System\.)?Windows\.(Navigation\.)?(Navigation)?Window\b'
        'Formulaire WinForms'='(?i)Windows\.Forms\.Form\b'
        # A Window root loaded through XamlReader is a window as well, whatever its namespace prefix.
        'Fenetre XAML'='(?i)<([A-Za-z_][\w.-]*:)?(Navigation)?Window[\s>/]'
        'Boucle modale imbriquee'='(?i)\.ShowDialog\s*\(|\bPushFrame\s*\(|\bDispatcherFrame\b|Forms\.Application\s*\]\s*::\s*Run\b'
        'Boite de message native'='(?i)MessageBox\s*\]\s*::\s*Show\b|Interaction\s*\]\s*::\s*(MsgBox|InputBox)\b'
        'Fenetre systeme'='(?i)\bGet-Credential\b|\.PromptForCredential\s*\(|\bOut-GridView\b'
        # Repository wrappers that open a modal window or a transposed Window with its own modal frame.
        'Dialogue modal Domenia'='(?i)\b(Show-Domenia(Form|Rimotte)?Dialog|Show-DomeniaEmbeddedWindow|Show-DomeniaAlternateCredential|Show-DomeniaOperationError|Show-(Info|Error|Warning)Box|Confirm-(Warning|Text)?Action|Confirm-DomeniaOperationImpact)\b'
    }
    $findings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $patterns.Keys) { if ([regex]::IsMatch([string]$SourceText,$patterns[$name])) { $findings.Add($name) } }
    return [pscustomobject]@{Safe=($findings.Count -eq 0);Findings=$findings.ToArray()}
}

# ---------------------------------------------------------------- D084 explicit column views
function Get-DomeniaResultColumns {
    # Column keys per explicit view, as the result grid names them (binding path or sort member of DgObjects).
    # A user list carries no workstation console column (SessionDisplay, SessionState, Presence) nor the operating
    # system; a workstation list carries no mail. The mixed view keeps every column. A view never removes a
    # column from the grid: the others are only hidden, with their width and position kept.
    # DS-20: the association, its source and its qualification share one column (Association) since SP-02.
    # -Profile stays accepted as an alias.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][Alias('Profile')][ValidateSet('Utilisateur','Machine','Mixte')][string]$ColumnProfile)
    switch ($ColumnProfile) {
        'Utilisateur' { return @('Type','Name','DirectoryState','Login','UPN','Association','State','LastLogon','Mail','Description','Changed','DN') }
        'Machine'     { return @('Type','Name','SessionDisplay','SessionState','DirectoryState','UPN','Association','Presence','State','OS','LastLogon','Description','Changed','DN') }
        default       { return @('Type','Name','SessionDisplay','SessionState','DirectoryState','Login','UPN','Association','Presence','State','OS','LastLogon','Mail','Description','Changed','DN') }
    }
}

function Get-DomeniaResultProfileLabels {
    # Display labels of the explicit views, in the order of the selector.
    return [ordered]@{Mixte='Vue mixte';Utilisateur='Vue utilisateurs';Machine='Vue postes'}
}

function Resolve-DomeniaColumnPreferences {
    # Applies saved width, order and sort to the columns of one view. Preferences are kept per column id and are
    # never rewritten here: a column hidden by one view keeps its width and position for the next view showing it.
    # $Preferences: dictionary id -> {Width, Order}. $Sort: {Column, Direction}.
    param([Parameter(Mandatory=$true)][ValidateSet('Utilisateur','Machine','Mixte')][string]$ColumnProfile,$Preferences=$null,$Sort=$null)
    $defaults = @{Type=105;Name=260;SessionDisplay=230;SessionState=175;DirectoryState=72;Login=150;UPN=235;Association=260;Presence=200;State=120;OS=180;LastLogon=145;Mail=220;Description=250;Changed=145;DN=520}
    $ids = @(Get-DomeniaResultColumns -ColumnProfile $ColumnProfile)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $id = [string]$ids[$i]
        $saved = Get-DomeniaMember $Preferences $id $null
        $width = [double]$defaults[$id]
        $savedWidth = 0.0
        try { $savedWidth = [double](Get-DomeniaMember $saved 'Width' 0) } catch { $savedWidth = 0.0 }
        if (($savedWidth -ge 40) -and ($savedWidth -le 1600)) { $width = $savedWidth }
        $key = 1000 + $i
        $savedOrder = -1
        try { $savedOrder = [int](Get-DomeniaMember $saved 'Order' (-1)) } catch { $savedOrder = -1 }
        if (($null -ne $saved) -and ($savedOrder -ge 0)) { $key = $savedOrder }
        $rows.Add([pscustomobject]@{Id=$id;Width=$width;Key=$key;Index=$i})
    }
    $ordered = @($rows.ToArray() | Sort-Object -Property Key,Index)
    $columns = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $ordered.Count; $i++) { $columns.Add([pscustomobject]@{Id=$ordered[$i].Id;Width=$ordered[$i].Width;DisplayIndex=$i}) }
    $sortColumn = [string](Get-DomeniaMember $Sort 'Column' '')
    $direction = [string](Get-DomeniaMember $Sort 'Direction' 'Ascending')
    if ($direction -notin @('Ascending','Descending')) { $direction = 'Ascending' }
    $effective = $null
    foreach ($id in $ids) { if ($sortColumn -and ([string]$id -ieq $sortColumn)) { $effective = [pscustomobject]@{Column=[string]$id;Direction=$direction} } }
    return [pscustomobject]@{Profile=$ColumnProfile;Columns=$columns.ToArray();Sort=$effective;StoredSort=$Sort;Preferences=$Preferences}
}

function Test-DomeniaProfileChangeAllowed {
    # A view is chosen explicitly by the operator. It never changes during typing or while a batch of results
    # arrives: the explicit request is then deferred to the end of the typing or of the last batch.
    param(
        [ValidateSet('Explicit','Automatic')][string]$Trigger='Explicit',
        [bool]$Typing=$false,
        [bool]$BatchArriving=$false,
        [AllowEmptyString()][string]$CurrentProfile='',
        [AllowEmptyString()][string]$RequestedProfile=''
    )
    if ($Trigger -eq 'Automatic') { return [pscustomobject]@{Allowed=$false;Deferred=$false;Reason='La vue se choisit explicitement : aucune bascule automatique.'} }
    if ($RequestedProfile -notin @('Utilisateur','Machine','Mixte')) { return [pscustomobject]@{Allowed=$false;Deferred=$false;Reason='Vue inconnue.'} }
    if ($RequestedProfile -ieq $CurrentProfile) { return [pscustomobject]@{Allowed=$false;Deferred=$false;Reason='Vue deja active.'} }
    if ($Typing) { return [pscustomobject]@{Allowed=$false;Deferred=$true;Reason='Saisie en cours : la vue changera a la fin de la saisie.'} }
    if ($BatchArriving) { return [pscustomobject]@{Allowed=$false;Deferred=$true;Reason='Resultats en cours d arrivee : la vue changera apres le dernier lot.'} }
    return [pscustomobject]@{Allowed=$true;Deferred=$false;Reason=''}
}

# ---------------------------------------------------------------- DS-20 / SP-02 columns chosen by the operator
function Get-DomeniaResultColumnCatalog {
    # DS-20: the columns of the result grid that the operator may show or hide, in grid order. Key is the persisted
    # key of the column (Get-DomeniaGridColumnKey: sort member, else binding path). SP-02: six columns by default
    # (Type, Nom, Utilisateur connecté, Association mémorisée, Présence réseau, État). Relevance: a workstation
    # column appears only when the list holds a workstation, an association column only with users or workstations,
    # Compte only when a row has an account (former automatic rule, kept under the choice). Nom cannot be hidden.
    $rows = @(
        @('Type','Type',$true,'All'),@('Name','Nom',$true,'All'),@('SessionDisplay','Utilisateur connecté (console)',$true,'Machine'),
        @('SessionState','Vérification utilisateur',$false,'Machine'),@('DirectoryState','Fraîcheur AD',$false,'All'),@('Login','Compte',$false,'Account'),
        @('UPN','UPN / DNS',$false,'All'),@('Association','Association mémorisée',$true,'Linkable'),@('Presence','Présence réseau',$true,'Machine'),
        @('State','État',$true,'All'),@('OS','Système',$false,'Machine'),@('LastLogonSort','Dernière connexion',$false,'Linkable'),
        @('Mail','Mail',$false,'All'),@('Description','Description',$false,'All'),@('ChangedSort','Modifié',$false,'All'),@('DN','Chemin complet',$false,'All')
    )
    return @($rows | ForEach-Object { [pscustomobject]@{Key=[string]$_[0];Label=[string]$_[1];Default=[bool]$_[2];Locked=([string]$_[0] -eq 'Name');Relevance=[string]$_[3]} })
}

function Resolve-DomeniaResultColumnChoice {
    # DS-20: the columns chosen by the operator, from the stored preference (JSON {Version:1;Visible:[keys]}).
    # Unknown keys are dropped, Nom is always kept; the columns merged by SP-02 (LinkSource, LinkConfidence) count as
    # Association and the former keys LastLogon / Changed as their sort keys. No preference, or an unreadable one,
    # gives the six SP-02 columns: earlier versions only stored width and order (kept by the grid layout).
    param($Saved=$null)
    $catalog = @(Get-DomeniaResultColumnCatalog)
    $known = @{}; foreach ($entry in $catalog) { $known[[string]$entry.Key] = $true }
    $aliases = @{LinkSource='Association';LinkConfidence='Association';LastLogon='LastLogonSort';Changed='ChangedSort'}
    $value = $Saved
    if ($value -is [string]) {
        $text = ([string]$value).Trim()
        $value = $null
        if ($text -and ($text.Length -le 8192)) { try { $value = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { $value = $null } }
    }
    $keys = $null
    if ($null -ne $value) {
        $version = 0
        try { $version = [int](Get-DomeniaMember $value 'Version' 0) } catch { $version = 0 }
        $listed = Get-DomeniaMember $value 'Visible' $null
        if (($version -eq 1) -and ($null -ne $listed)) {
            $keys = @{}
            foreach ($item in @($listed)) {
                $key = [string]$item
                if ($aliases.ContainsKey($key)) { $key = [string]$aliases[$key] }
                if ($known.ContainsKey($key)) { $keys[$key] = $true }
            }
        }
    }
    $source = 'Saved'
    if ($null -eq $keys) {
        $source = 'Default'
        $keys = @{}; foreach ($entry in $catalog) { if ([bool]$entry.Default) { $keys[[string]$entry.Key] = $true } }
    }
    $keys['Name'] = $true
    return [pscustomobject]@{Visible=@($catalog | Where-Object { $keys.ContainsKey([string]$_.Key) } | ForEach-Object { [string]$_.Key });Source=$source}
}

function Set-DomeniaResultColumnChoice {
    # DS-20: shows or hides one column in the choice, in grid order. Nom stays shown; an unknown key changes nothing.
    param([string[]]$Visible=@(),[Parameter(Mandatory=$true)][string]$Key,[bool]$Show=$true)
    $catalog = @(Get-DomeniaResultColumnCatalog)
    $keys = @{}; foreach ($item in @($Visible)) { $keys[[string]$item] = $true }
    if (@($catalog | Where-Object { [string]$_.Key -ceq $Key }).Count -eq 1) {
        if ($Show) { $keys[$Key] = $true } elseif ($Key -cne 'Name') { [void]$keys.Remove($Key) }
    }
    $keys['Name'] = $true
    return @($catalog | Where-Object { $keys.ContainsKey([string]$_.Key) } | ForEach-Object { [string]$_.Key })
}

function ConvertTo-DomeniaResultColumnChoiceText {
    # DS-20: the stored form of the choice (column keys only: no data, no account, no secret).
    param([string[]]$Visible=@())
    $keys = @(Set-DomeniaResultColumnChoice -Visible $Visible -Key 'Name' -Show $true)
    return (ConvertTo-Json -InputObject ([pscustomobject]@{Version=1;Visible=$keys}) -Compress)
}

function Test-DomeniaResultColumnShown {
    # DS-20: a column is shown when the operator chose it AND it applies to the list (Relevance of the catalog).
    # $Visible = $null: no choice loaded yet, every managed column follows its relevance only (former behaviour).
    # A column outside the catalog is not managed here: shown.
    param([Parameter(Mandatory=$true)][string]$Key,$Visible=$null,[bool]$HasMachine=$false,[bool]$HasLinkable=$false,[bool]$HasAccount=$false)
    $entry = @(Get-DomeniaResultColumnCatalog | Where-Object { [string]$_.Key -ceq $Key })
    if ($entry.Count -ne 1) { return $true }
    if (($null -ne $Visible) -and (@($Visible) -notcontains $Key)) { return $false }
    switch ([string]$entry[0].Relevance) {
        'Machine'  { return $HasMachine }
        'Linkable' { return $HasLinkable }
        'Account'  { return $HasAccount }
    }
    return $true
}

function Expand-DomeniaResultExportColumns {
    # DS-20: the association cell shows the association, its qualification and its source (tooltip), but the CSV of
    # the result list keeps the three columns it had before the merge: Source lien and Qualification follow
    # Association mémorisée, which stays where the operator placed it. A list without the association column exports
    # neither; a column already exported is never repeated. $Columns: {Property; Header} in export order.
    param([object[]]$Columns=@())
    $present = @{}
    foreach ($column in @($Columns)) { if ($null -ne $column) { $present[[string]$column.Property] = $true } }
    foreach ($column in @($Columns)) {
        if ($null -eq $column) { continue }
        $column
        if ([string]$column.Property -cne 'Association') { continue }
        foreach ($extra in @(@('LinkSource','Source lien'),@('LinkConfidence','Qualification'))) {
            if ($present.ContainsKey($extra[0])) { continue }
            $present[$extra[0]] = $true
            [pscustomobject]@{ Property=$extra[0]; Header=$extra[1] }
        }
    }
}

# ---------------------------------------------------------------- D085 selection preview in Rechercher
function Get-DomeniaSelectionPreview {
    # Summary shown in Rechercher for the selected row. Users and workstations share one contract: same members,
    # same states, same destinations. A detail read for another object or another generation is never shown.
    # $Selection: {Type, Name, Guid, Generation}. $Detail: the read object, carrying its own Guid and Generation.
    param($Selection,[ValidateSet('Idle','Loading','Loaded','Error','Refused')][string]$LoadState='Idle',$Detail=$null,[AllowEmptyString()][AllowNull()][string]$ErrorText='')
    $rawType = [string](Get-DomeniaMember $Selection 'Type' '')
    $type = ConvertTo-DomeniaRelationType $rawType
    $typeLabel = $type
    if (-not $typeLabel) { $typeLabel = ConvertTo-DomeniaFlatText $rawType 40 }
    $name = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $Selection 'Name' '')) 80
    $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Selection 'Guid' '')
    $generation = [string](Get-DomeniaMember $Selection 'Generation' '')
    $state = $LoadState
    if (($null -eq $Selection) -or ((-not $guid) -and (-not $name))) { $state = 'None' }
    $stale = $false
    $matching = $false
    if (($state -ne 'None') -and ($null -ne $Detail)) {
        $detailGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Detail 'Guid' '')
        $detailGeneration = [string](Get-DomeniaMember $Detail 'Generation' '')
        $matching = ([bool]$guid -and ($detailGuid -eq $guid) -and ($detailGeneration -ceq $generation))
        if (-not $matching) { $stale = $true }
    }
    # "Loaded" without the detail of THIS selection means the right detail has not arrived yet.
    if (($state -eq 'Loaded') -and (-not $matching)) { $state = 'Loading' }
    $lines = New-Object 'System.Collections.Generic.List[object]'
    if ($state -eq 'Loaded') {
        $missing = 'Non renseigne'
        if ($type -eq 'Machine') {
            $rows = @(
                @('Identifiant',@('DnsName','DnsHostName','Name')),@('Systeme',@('OperatingSystem','OS')),
                @('Etat',@('State')),@('Emplacement',@('Container','OU','ParentDn')),@('Presence',@('Presence'))
            )
        } elseif ($type -eq 'Utilisateur') {
            $rows = @(@('Identifiant',@('Login','SamAccountName')),@('UPN',@('Upn','UserPrincipalName')),@('Etat',@('State')),@('Emplacement',@('Container','OU','ParentDn')))
        } else {
            $rows = @(@('Identifiant',@('Login','SamAccountName','Name')),@('Etat',@('State')),@('Emplacement',@('Container','OU','ParentDn')))
        }
        foreach ($row in $rows) {
            $value = Get-DomeniaShellFirstValue $Detail ([string[]]$row[1])
            if (-not $value) { $value = $missing; if ($row[0] -eq 'Presence') { $value = 'Non verifiee' } }
            $lines.Add([pscustomobject]@{Label=[string]$row[0];Value=$value})
        }
    }
    $errorLine = ConvertTo-DomeniaFlatText (Protect-DomeniaSecretText ([string]$ErrorText)) 160
    $stateText = ''
    switch ($state) {
        'None'    { $stateText = 'Aucune selection.' }
        'Idle'    { $stateText = 'Selection : ' + $name + '. Fiche non encore lue.' }
        'Loading' { $stateText = 'Chargement de la fiche de ' + $name + '...' }
        'Loaded'  { $stateText = 'Fiche lue.' }
        'Error'   { $stateText = 'Lecture en erreur.'; if ($errorLine) { $stateText = 'Lecture en erreur : ' + $errorLine } }
        'Refused' { $stateText = 'Lecture refusee pour ce compte : la fiche n est pas affichee.' }
    }
    $destinations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($route in @(@('WsObject','Ouvrir la fiche'),@('TabRelations','Utilisateurs et postes'),@('WsComputer','Poste'))) {
        $applicable = $true; $notApplicable = ''
        if (($route[0] -eq 'TabRelations') -and ($type -notin @('Utilisateur','Machine'))) { $applicable = $false; $notApplicable = 'Reserve aux utilisateurs et aux postes.' }
        if (($route[0] -eq 'WsComputer') -and ($type -ne 'Machine')) { $applicable = $false; $notApplicable = 'Reserve aux postes.' }
        $enabled = $false; $reason = ''
        if ($state -eq 'None') { $reason = 'Selectionnez une ligne.' }
        elseif (-not $applicable) { $reason = $notApplicable }
        elseif ($state -eq 'Loaded') { $enabled = $true }
        elseif ($state -eq 'Loading') { $reason = 'Chargement de la fiche en cours.' }
        elseif ($state -eq 'Idle') { $reason = 'Fiche non encore lue.' }
        elseif ($state -eq 'Error') { $reason = 'Lecture en erreur : relancez la lecture.' }
        else { $reason = 'Lecture refusee pour ce compte.' }
        $destinations.Add([pscustomobject]@{Route=$route[0];Label=$route[1];Enabled=$enabled;Reason=$reason})
    }
    return [pscustomobject]@{
        Contract='DomeniaSelectionPreview/1';Type=$typeLabel;Name=$name;State=$state;StateText=$stateText
        ShowDetail=($state -eq 'Loaded');Stale=$stale;Lines=$lines.ToArray();Destinations=$destinations.ToArray()
        CanRetry=($state -in @('Error','Refused'))
    }
}

function ConvertTo-DomeniaPreviewLoadState {
    # Maps the phase of the selection read (Queued, Loading, Cached, Paused, Ready, Failed) to the preview contract.
    # A cached display is still a loading state: only the fresh read of THIS selection is "Loaded". A failure whose
    # message is an access refusal is "Refused" (never presented as an absence).
    param([AllowEmptyString()][AllowNull()][string]$Phase='',[AllowEmptyString()][AllowNull()][string]$Message='')
    switch ([string]$Phase) {
        'Ready'   { return 'Loaded' }
        'Failed'  {
            if ([regex]::IsMatch([string]$Message,'(?i)acc(e|è)s\s+refus|access\s+(is\s+)?denied|refus(e|é)e?\s+pour\s+ce\s+compte|unauthori[sz]ed|insufficient\s+access|0x80070005')) { return 'Refused' }
            return 'Error'
        }
        'Queued'  { return 'Idle' }
        ''        { return 'Idle' }
        default   { return 'Loading' }
    }
}

function ConvertTo-DomeniaSelectionPreviewText {
    # One line for the fixed 20-unit row under the results (no growth while loading) and the detail for its tool
    # tip: state, the read lines of THIS selection and the reason of each unavailable destination.
    param($Preview,[ValidateRange(40,400)][int]$Maximum=160)
    if ($null -eq $Preview) { return [pscustomobject]@{Line='Aucune selection.';Detail='Aucune selection.'} }
    $state = [string](Get-DomeniaMember $Preview 'State' 'None')
    $type = [string](Get-DomeniaMember $Preview 'Type' '')
    $name = [string](Get-DomeniaMember $Preview 'Name' '')
    $stateText = [string](Get-DomeniaMember $Preview 'StateText' '')
    $prefix = ''
    if ($state -ne 'None') { $prefix = (ConvertTo-DomeniaFlatText (($type + ' : ' + $name).Trim()) 90) + ' | ' }
    $line = $prefix + $stateText
    $lines = @(Get-DomeniaMember $Preview 'Lines' @())
    if ([bool](Get-DomeniaMember $Preview 'ShowDetail' $false) -and ($lines.Count -gt 0)) {
        $parts = @(foreach ($item in $lines) { [string](Get-DomeniaMember $item 'Label' '') + ' ' + [string](Get-DomeniaMember $item 'Value' '') })
        $line = $line + ' ' + ($parts -join ' · ')
    }
    $detailLines = New-Object 'System.Collections.Generic.List[string]'
    $detailLines.Add(($prefix + $stateText).Trim())
    if ([bool](Get-DomeniaMember $Preview 'ShowDetail' $false)) {
        foreach ($item in $lines) { $detailLines.Add([string](Get-DomeniaMember $item 'Label' '') + ' : ' + [string](Get-DomeniaMember $item 'Value' '')) }
    }
    foreach ($destination in @(Get-DomeniaMember $Preview 'Destinations' @())) {
        $label = [string](Get-DomeniaMember $destination 'Label' '')
        if ([bool](Get-DomeniaMember $destination 'Enabled' $false)) { $detailLines.Add($label + ' : disponible.') }
        else { $detailLines.Add($label + ' : ' + [string](Get-DomeniaMember $destination 'Reason' '')) }
    }
    return [pscustomobject]@{Line=(ConvertTo-DomeniaFlatText $line $Maximum);Detail=(($detailLines.ToArray()) -join "`r`n")}
}

# ---------------------------------------------------------------- D086 operation summary before execution
function Test-DomeniaShellSensitiveOption {
    # True when an option must not show its value: flagged Sensitive, holding a SecureString or a credential,
    # or named or labelled like a secret (fail closed: the caller does not have to remember the flag).
    # A yes/no or date value carries no secret and stays visible (for example "Changer le mot de passe : Oui").
    param($Option)
    if ($null -eq $Option) { return $false }
    $value = Get-DomeniaMember $Option 'Value' $null
    if (($value -is [Security.SecureString]) -or ($value -is [Management.Automation.PSCredential])) { return $true }
    if ([bool](Get-DomeniaMember $Option 'Sensitive' $false)) { return $true }
    if (($value -is [bool]) -or ($value -is [datetime])) { return $false }
    $words = [string](Get-DomeniaMember $Option 'Name' '') + ' ' + [string](Get-DomeniaMember $Option 'Label' '')
    # Split CamelCase names (NewPassword, AdmPwd, msLAPS-Password) into words before matching.
    $words = [regex]::Replace($words,'([a-z0-9])([A-Z])','$1 $2')
    $words = [regex]::Replace($words,'[_\-\.:/]',' ')
    $pattern = '(?i)\b(pass|passe|password|passwd|passphrase|pwd|motdepasse|secrets?|tokens?|jetons?|apikey|credentials?|cl(e|\u00e9)s?|pin|laps|recovery|r(e|\u00e9)cup(e|\u00e9)ration)\b|\bmot\s+de\s+passe\b|\bapi\s+key\b|\bbit\s*locker\b'
    return [regex]::IsMatch($words,$pattern)
}

function Get-DomeniaOperationSummary {
    # Every value that changes what an operation does is listed before execution, whether its option is folded
    # away or not. Folding changes the form only, never the summary. A sensitive value is never displayed, even
    # when the caller did not flag it: see Test-DomeniaShellSensitiveOption.
    # $Options: {Name, Label, Value, Default, Influences (default true), Advanced, Sensitive}.
    param([Parameter(Mandatory=$true)][string]$Operation,[object[]]$Options=@(),[bool]$Collapsed=$true)
    $lines = New-Object 'System.Collections.Generic.List[object]'
    $folded = 0
    foreach ($option in @($Options)) {
        if ($null -eq $option) { continue }
        $name = [string](Get-DomeniaMember $option 'Name' '')
        $label = [string](Get-DomeniaMember $option 'Label' '')
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $valueText = ConvertTo-DomeniaShellValueText (Get-DomeniaMember $option 'Value' $null)
        $defaultText = ConvertTo-DomeniaShellValueText (Get-DomeniaMember $option 'Default' $null)
        $influences = [bool](Get-DomeniaMember $option 'Influences' $true)
        $advanced = [bool](Get-DomeniaMember $option 'Advanced' $false)
        $sensitive = Test-DomeniaShellSensitiveOption $option
        $changed = ($valueText -cne $defaultText)
        # An option without effect left at its default does not load the summary; anything else is listed.
        if ((-not $influences) -and (-not $changed)) { continue }
        if ($advanced -and $Collapsed) { $folded++ }
        $shown = Protect-DomeniaSecretText $valueText
        if ($sensitive) { $shown = '(masque)' } elseif (-not $shown) { $shown = 'Non defini' }
        $lines.Add([pscustomobject]@{Name=$name;Label=(ConvertTo-DomeniaFlatText $label 80);Value=$shown;Advanced=$advanced;Changed=$changed})
    }
    $operationText = ConvertTo-DomeniaFlatText $Operation 120
    $text = $operationText + ' : aucune option particuliere.'
    if ($lines.Count -gt 0) { $text = $operationText + ' : ' + ((@($lines.ToArray() | ForEach-Object { $_.Label + ' : ' + $_.Value })) -join ' · ') }
    return [pscustomobject]@{Operation=$operationText;Lines=$lines.ToArray();Text=$text;Collapsed=$Collapsed;FoldedListed=$folded}
}

# ---------------------------------------------------------------- D087 informative empty states
function Test-DomeniaNoAbsenceClaim {
    # True when a text makes no claim that an object, an account or a session does not exist.
    # Covers "n existe pas/plus", "inexistant", "introuvable", "il n y a pas", "absent", "n est pas dans/present",
    # "inconnu dans/de l annuaire", "ne figure pas", "supprime" and their English forms, whatever the apostrophe.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $true }
    $pattern = '(?i)\bn[^a-z0-9]{0,2}existe(nt)?\s+(pas|plus)\b|\binexistant|\bintrouvable|\bn[^a-z0-9]{0,2}y\s+a\s+(pas|plus|aucun)|\babsente?s?\b|\bn[^a-z0-9]{0,2}(est|sont)\s+(pas|plus)\s+(dans|present|presente|presents|presentes|connu|connue|connus|enregistre|enregistree|repertorie)\b|\binconnue?s?\s+(dans|de|du|des|au)\b|\bne\s+figuren?t?\s+(pas|plus)\b|\bsupprime(e|s|es)?\b|\bdoes\s+not\s+exist|\bno\s+longer\s+exists?\b|\bnot\s+found\b|\bmissing\b'
    return (-not [regex]::IsMatch($Text,$pattern))
}

function Get-DomeniaEmptyState {
    # Distinguishes an empty answer from an empty display. Each state names what was (not) read and proposes
    # one next action that is never started by itself. No state claims that an object or a session does not exist.
    param(
        [Parameter(Mandatory=$true)][ValidateSet('NoResult','LocalFilterEmpty','NoSource','NothingQueried','Refused','Partial')][string]$Kind,
        [ValidateSet('Objet','Session')][string]$Subject='Objet',
        [AllowEmptyString()][AllowNull()][string]$Query='',
        [AllowEmptyString()][AllowNull()][string]$Scope='',
        [AllowEmptyString()][AllowNull()][string]$LocalFilter='',
        [ValidateRange(0,2147483647)][int]$Answered=0,
        [ValidateRange(0,2147483647)][int]$Total=0
    )
    $queryText = ConvertTo-DomeniaFlatText $Query 60
    $scopeText = ConvertTo-DomeniaFlatText $Scope 80
    $scopePart = ''
    if ($scopeText) { $scopePart = ' (' + $scopeText + ')' }
    $title = ''; $text = ''; $etat = 'Inconnu'; $next = $null
    switch ($Kind) {
        'NoResult' {
            $etat = 'Constate'
            if ($Subject -eq 'Session') {
                $title = 'Aucune session renvoyee'
                $text = 'La source interrogee' + $scopePart + ' n a renvoye aucune session. Une session RDP ou deconnectee peut ne pas figurer dans cette lecture.'
                $next = @('Lire les sessions RDP de ce poste','ReadRdpSessions','TabSessions')
            } else {
                $title = 'Aucun resultat'
                $text = 'Aucun resultat dans le perimetre interroge' + $scopePart
                if ($queryText) { $text = 'Aucun resultat pour « ' + $queryText + ' » dans le perimetre interroge' + $scopePart }
                $text += '. Un objet hors de ce perimetre, ou masque pour ce compte, ne peut pas apparaitre ici.'
                $next = @('Elargir le perimetre ou corriger la saisie','WidenScope','WsSearch')
            }
        }
        'LocalFilterEmpty' {
            $etat = 'Constate'
            $title = 'Filtre local sans correspondance'
            $text = 'Les resultats lus sont tous masques par le filtre local'
            if ($Total -gt 0) { $text = [string]$Total + ' resultat(s) lu(s), tous masques par le filtre local' }
            $filterText = ConvertTo-DomeniaFlatText $LocalFilter 60
            if ($filterText) { $text += ' « ' + $filterText + ' »' }
            $text += '. Aucune nouvelle lecture n a ete faite.'
            $next = @('Effacer le filtre local','ClearLocalFilter','WsSearch')
        }
        'NoSource' {
            $etat = 'Indisponible'
            $title = 'Aucune source disponible'
            $text = 'Aucune source n est configuree ou joignable pour cette vue : rien n a pu etre lu, l etat reel est inconnu.'
            $next = @('Choisir ou configurer une source','ChooseSource','TabApplicationTools')
        }
        'NothingQueried' {
            $etat = 'Inconnu'
            $title = 'Rien n a encore ete interroge'
            $text = 'Aucun poste ni aucune source n a encore ete interroge pour cette vue : l affichage vide ne renseigne pas sur l etat reel.'
            if ($Subject -eq 'Session') { $text = 'Ce poste n a pas encore ete interroge : l affichage vide ne renseigne pas sur ses sessions.' }
            $next = @('Lancer la lecture','StartRead','')
        }
        'Refused' {
            $etat = 'Refuse'
            $title = 'Lecture refusee'
            $text = 'La lecture a ete refusee pour ce compte' + $scopePart + ' : le contenu reel est inconnu.'
            if ($Subject -eq 'Session') { $text = 'La lecture des sessions a ete refusee pour ce compte' + $scopePart + ' : les sessions reelles sont inconnues.' }
            $next = @('Utiliser un autre compte pour cette ressource','ChangeAccount','TabAccounts')
        }
        'Partial' {
            $etat = 'Inconnu'
            $title = 'Resultats partiels'
            $text = 'Une partie seulement des sources a repondu'
            if ($Total -gt 0) { $text = [string]$Answered + ' source(s) sur ' + [string]$Total + ' ont repondu' }
            $text += '. Un element present dans une source sans reponse peut manquer ici.'
            $next = @('Relire les sources sans reponse','RetryMissing','')
        }
    }
    return [pscustomobject]@{
        Kind=$Kind;Subject=$Subject;Title=$title;Text=$text;Etat=$etat;ProvesAbsence=$false
        NextAction=[pscustomobject]@{Label=$next[0];Command=$next[1];Route=$next[2];Automatic=$false}
    }
}

function Resolve-DomeniaSearchEmptyKind {
    # Chooses which empty state the result list shows, from what was really observed. Returns '' when rows are
    # displayed or while a read is still running (the activity row shows it), never a verdict on a refusal.
    # $ErrorKind: Kind of ConvertTo-DomeniaErrorInfo for the current search (AccessDenied, LogonFailure, Timeout...).
    # $Partial: the read stopped before its end (interrupted, partial LDAP answer).
    param(
        [ValidateRange(0,2147483647)][int]$Displayed=0,
        [ValidateRange(0,2147483647)][int]$Loaded=0,
        [bool]$InFlight=$false,
        [bool]$Completed=$false,
        [AllowEmptyString()][AllowNull()][string]$ErrorKind='',
        [bool]$Partial=$false
    )
    if ($Displayed -gt 0) { return '' }
    if ([string]$ErrorKind -in @('AccessDenied','LogonFailure')) { return 'Refused' }
    if ($Loaded -gt 0) { return 'LocalFilterEmpty' }
    if ($InFlight) { return '' }
    if ($Partial) { return 'Partial' }
    if (-not [string]::IsNullOrEmpty([string]$ErrorKind)) { return 'NoSource' }
    if (-not $Completed) { return 'NothingQueried' }
    return 'NoResult'
}

# ---------------------------------------------------------------- D088 help for disabled controls
function Get-DomeniaDisabledHelpDetails {
    # Fixed catalogue of the optional detail of a disabled control. Free text is not accepted: a field value, an
    # error message or a secret can never reach a tool tip through this rule.
    return [ordered]@{
        NeedsUser='Selectionnez un utilisateur.'
        NeedsWorkstation='Selectionnez un poste.'
        NeedsGroup='Selectionnez un groupe.'
        ReadInProgress='Lecture en cours sur cette cible.'
        WriteInProgress='Ecriture en cours sur cette cible.'
        ReceiptToReview='Un recu attend sa verification.'
        CacheOnly='Valeurs issues du cache local.'
        OtherAccountNeeded='Un autre compte est necessaire pour cette ressource.'
        RemoteAccessUnavailable='Acces distant non disponible pour ce poste.'
        ToolMissing='Outil d administration non installe sur ce poste.'
        FeatureDisabled='Fonction desactivee dans la configuration.'
        RequiredFieldEmpty='Un champ obligatoire est vide.'
    }
}

function Get-DomeniaDisabledHelp {
    # Short reason for a greyed control, readable with the mouse (tool tip shown on a disabled control) and with
    # the keyboard (F1 and the help panel), without a technical popup. The text never carries the content of a
    # field: the action is an interface label, the reason and the detail come from fixed catalogues, and the
    # control name is returned apart, never written into the text.
    param(
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][ValidateSet('ReadOnly','NoSelection','WrongType','Busy','Refused','Stale','Offline','Prerequisite','Pending','Running')][string]$Reason,
        [AllowEmptyString()][AllowNull()][string]$DetailCode='',
        [AllowEmptyString()][string]$ControlName=''
    )
    $detailText = ''
    if (-not [string]::IsNullOrEmpty($DetailCode)) {
        $catalogue = Get-DomeniaDisabledHelpDetails
        $known = $null
        foreach ($code in @($catalogue.Keys)) { if ([string]$code -ceq $DetailCode) { $known = [string]$catalogue[$code] } }
        # The rejected value is not repeated in the message: it may be the very content that must not leak.
        if ($null -eq $known) { throw 'Motif detaille hors catalogue : seul un code du catalogue est accepte.' }
        $detailText = $known
    }
    $actionText = ConvertTo-DomeniaFlatText $Action 60
    $route = ''
    $text = ''
    if ($Reason -in @('ReadOnly','NoSelection','Busy','Refused','Stale')) {
        $explanation = Get-DomeniaCapabilityExplanation -Action $actionText -State $Reason
        $text = [string]$explanation.Text
        $route = [string]$explanation.Route
    } else {
        $label = ''
        switch ($Reason) {
            'WrongType'    { $label = 'Action reservee a un autre type d objet.'; $route = 'WsSearch' }
            'Offline'      { $label = 'Hors ligne : seules les donnees deja lues sont consultables.'; $route = 'TabGuard' }
            'Prerequisite' { $label = 'Prerequis non rempli sur ce poste ou sur la cible.'; $route = 'TabSelfCheck' }
            'Pending'      { $label = 'Une operation precedente reste a verifier sur cette cible.'; $route = 'TabGuard' }
            # A read or a remote action started from this control is still running (Busy is an AD write).
            # UX-32: the operations are followed in the drop-down panel of the Opérations button.
            'Running'      { $label = 'Operation en cours, action de nouveau disponible a sa fin.'; $route = 'Operations' }
        }
        $text = $actionText + ' : ' + $label
    }
    if ($detailText) { $text = $text + ' ' + $detailText }
    $short = ConvertTo-DomeniaFlatText $text 160
    return [pscustomobject]@{
        Control=$ControlName;Action=$actionText;Reason=$Reason;DetailCode=([string]$DetailCode);Short=$short;ToolTip=$short
        HelpText=($short + ' F1 : aide detaillee.');ShowOnDisabled=$true;KeyboardHint='F1 : motif dans le panneau d aide'
        Route=$route;Popup=$false
    }
}

function Get-DomeniaMissingDisabledHelp {
    # Names of the disabled controls that give no reason, or whose tool tip is not shown while disabled.
    # $Controls: {Name, IsEnabled, ToolTip, ShowOnDisabled}.
    param([object[]]$Controls=@())
    foreach ($control in @($Controls)) {
        if ($null -eq $control) { continue }
        if ([bool](Get-DomeniaMember $control 'IsEnabled' $true)) { continue }
        $tip = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $control 'ToolTip' '')) 400
        $shown = [bool](Get-DomeniaMember $control 'ShowOnDisabled' $false)
        if ((-not $tip) -or (-not $shown)) { [string](Get-DomeniaMember $control 'Name' '') }
    }
}

# ---------------------------------------------------------------- D089 focus and foreground
function Get-DomeniaActivationDecision {
    # Foreground requests are limited to the two moments the operator waits for the window: an explicit launch
    # and the switch from login to the main window. One attempt per moment: a refusal by Windows is final (at
    # most one taskbar flash), Topmost is never kept, a voluntary Alt-Tab is respected, and the end of a task
    # never takes the foreground.
    # $AttemptsByTrigger: the attempts already made, keyed by moment ({ExplicitLaunch=1}); the caller keeps one
    # log for the process and only the entry of THIS moment counts, so the launch attempt never consumes the
    # login-to-main one. $PreviousRefused: the attempt of this moment was refused by Windows.
    param(
        [Parameter(Mandatory=$true)][ValidateSet('ExplicitLaunch','LoginToMain','TaskCompleted','Background','Notification')][string]$Trigger,
        $AttemptsByTrigger=$null,
        [bool]$UserSwitchedAway=$false,
        [bool]$PreviousRefused=$false
    )
    $previousAttempts = 0
    $rawAttempts = Get-DomeniaMember $AttemptsByTrigger $Trigger 0
    try { $previousAttempts = [int]$rawAttempts } catch { $previousAttempts = 1 }
    # An unreadable count is treated as an attempt already made (fail closed: no second request).
    if ($previousAttempts -lt 0) { $previousAttempts = 1 }
    $activate = $false; $flash = $false; $reason = ''
    if ($Trigger -notin @('ExplicitLaunch','LoginToMain')) {
        $reason = 'Pas de premier plan pour ce moment : l etat reste visible dans la page.'
    } elseif ($UserSwitchedAway) {
        $flash = $true
        $reason = 'L operateur a change de fenetre : Alt-Tab respecte, simple signal dans la barre des taches.'
    } elseif ($previousAttempts -ge 1) {
        $flash = $PreviousRefused
        $reason = 'Une seule tentative d activation : aucune nouvelle demande.'
    } else {
        $activate = $true
        $reason = 'Activation demandee une fois, sans Topmost.'
    }
    return [pscustomobject]@{Trigger=$Trigger;Activate=$activate;AttemptsForTrigger=$previousAttempts;Topmost=$false;PermanentTopmost=$false;FlashTaskbar=$flash;Retry=$false;MaxAttempts=1;Reason=$reason}
}

# ---------------------------------------------------------------- D090 contrast, bounded restore, status glyphs
function ConvertFrom-DomeniaHexColor {
    # '#RGB', '#RRGGBB' or '#AARRGGBB' (WPF order), or any object with R, G, B and optional A members.
    # Returns {A, R, G, B} or $null when the value is not a colour.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if (-not [regex]::IsMatch($text,'^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$')) { return $null }
        $hex = $text.Substring(1)
        if ($hex.Length -eq 3) { $hex = 'FF' + $hex[0] + $hex[0] + $hex[1] + $hex[1] + $hex[2] + $hex[2] }
        elseif ($hex.Length -eq 6) { $hex = 'FF' + $hex }
        return [pscustomobject]@{
            A=[Convert]::ToInt32($hex.Substring(0,2),16);R=[Convert]::ToInt32($hex.Substring(2,2),16)
            G=[Convert]::ToInt32($hex.Substring(4,2),16);B=[Convert]::ToInt32($hex.Substring(6,2),16)
        }
    }
    $channels = @{}
    foreach ($name in @('A','R','G','B')) {
        $raw = Get-DomeniaMember $Value $name $null
        if ($null -eq $raw) {
            if ($name -eq 'A') { $channels[$name] = 255; continue }
            return $null
        }
        $number = 0
        try { $number = [int]$raw } catch { return $null }
        if (($number -lt 0) -or ($number -gt 255)) { return $null }
        $channels[$name] = $number
    }
    return [pscustomobject]@{A=$channels['A'];R=$channels['R'];G=$channels['G'];B=$channels['B']}
}

function Get-DomeniaRelativeLuminance {
    # WCAG 2.x relative luminance of an sRGB colour (linearised channels, Rec. 709 weights).
    param($Color)
    $c = ConvertFrom-DomeniaHexColor $Color
    if ($null -eq $c) { throw ('Couleur invalide : ' + [string]$Color) }
    $linear = @(foreach ($component in @($c.R,$c.G,$c.B)) {
        $v = [double]$component / 255.0
        if ($v -le 0.04045) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055,2.4) }
    })
    return ((0.2126 * $linear[0]) + (0.7152 * $linear[1]) + (0.0722 * $linear[2]))
}

function Get-DomeniaContrastRatio {
    # WCAG 2.x contrast ratio (L1 + 0.05) / (L2 + 0.05), from 1 to 21. A translucent text colour is composited
    # over its background first. A translucent background is refused: what lies below it is unknown here.
    param([Parameter(Mandatory=$true)]$Foreground,[Parameter(Mandatory=$true)]$Background)
    $back = ConvertFrom-DomeniaHexColor $Background
    if ($null -eq $back) { throw ('Couleur de fond invalide : ' + [string]$Background) }
    if ($back.A -ne 255) { throw 'Fond non opaque : le contraste depend de ce qui se trouve dessous.' }
    $fore = ConvertFrom-DomeniaHexColor $Foreground
    if ($null -eq $fore) { throw ('Couleur de texte invalide : ' + [string]$Foreground) }
    if ($fore.A -lt 255) {
        $alpha = [double]$fore.A / 255.0
        $fore = [pscustomobject]@{
            A=255;R=[int][Math]::Round(($fore.R * $alpha) + ($back.R * (1.0 - $alpha)))
            G=[int][Math]::Round(($fore.G * $alpha) + ($back.G * (1.0 - $alpha)));B=[int][Math]::Round(($fore.B * $alpha) + ($back.B * (1.0 - $alpha)))
        }
    }
    $first = Get-DomeniaRelativeLuminance $fore
    $second = Get-DomeniaRelativeLuminance $back
    return (([Math]::Max($first,$second) + 0.05) / ([Math]::Min($first,$second) + 0.05))
}

function Test-DomeniaPaletteContrast {
    # WCAG 2.x minimums: 4.5:1 for normal text, 3:1 for large text and for graphical elements.
    # $Palette: name -> colour. $Pairs: {Name, Foreground, Background, Kind = Text | LargeText | Graphic}; a colour
    # starting with '#' is literal, otherwise it is a palette name. A missing or invalid colour fails, never skips.
    param($Palette,[object[]]$Pairs=@())
    $culture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in @($Pairs)) {
        if ($null -eq $pair) { continue }
        $foregroundName = [string](Get-DomeniaMember $pair 'Foreground' '')
        $backgroundName = [string](Get-DomeniaMember $pair 'Background' '')
        $kind = [string](Get-DomeniaMember $pair 'Kind' 'Text')
        $required = 4.5
        if ($kind -in @('LargeText','Graphic')) { $required = 3.0 } else { $kind = 'Text' }
        $foreground = $foregroundName
        if (-not $foregroundName.StartsWith('#',[StringComparison]::Ordinal)) { $foreground = Get-DomeniaMember $Palette $foregroundName $null }
        $background = $backgroundName
        if (-not $backgroundName.StartsWith('#',[StringComparison]::Ordinal)) { $background = Get-DomeniaMember $Palette $backgroundName $null }
        $ratio = 0.0; $passed = $false; $reason = ''
        if (($null -eq $foreground) -or ($null -eq $background)) {
            $reason = 'Couleur absente de la palette.'
        } else {
            try { $ratio = Get-DomeniaContrastRatio $foreground $background; $passed = ($ratio -ge $required) }
            catch { $reason = $_.Exception.Message }
        }
        # Truncated, never rounded up: a displayed 4,50 always means at least 4.5.
        $display = ([Math]::Floor($ratio * 100.0) / 100.0).ToString('0.00',$culture)
        if ((-not $passed) -and (-not $reason)) { $reason = 'Contraste ' + $display + ':1 inferieur a ' + $required.ToString('0.0',$culture) + ':1.' }
        $name = [string](Get-DomeniaMember $pair 'Name' '')
        if (-not $name) { $name = $foregroundName + ' / ' + $backgroundName }
        $rows.Add([pscustomobject]@{Name=$name;Foreground=$foregroundName;Background=$backgroundName;Kind=$kind;Ratio=$ratio;Display=$display;Required=$required;Passed=$passed;Reason=$reason})
    }
    $results = $rows.ToArray()
    $failures = @($results | Where-Object { -not $_.Passed })
    $minimum = 0.0
    $measured = @($results | Where-Object { $_.Ratio -gt 0 } | ForEach-Object { $_.Ratio } | Sort-Object)
    if ($measured.Count -gt 0) { $minimum = [double]$measured[0] }
    return [pscustomobject]@{Passed=(($results.Count -gt 0) -and ($failures.Count -eq 0));Results=$results;Failures=$failures;Minimum=$minimum}
}

function Get-DomeniaSuiteContrastPairs {
    # Text and background pairs that the main window really paints with the shared palette (SupportSuite.UI.json).
    # Kind Text = 4.5:1, LargeText or Graphic = 3:1 (WCAG 2.x).
    $pairs = @(
        @('Texte sur carte','TextColor','BgCard','Text'),@('Texte sur fond','TextColor','WindowBg','Text'),@('Texte saisi','TextColor','BgInput','Text')
        @('Texte secondaire sur carte','MutedColor','BgCard','Text'),@('Texte secondaire sur fond','MutedColor','WindowBg','Text'),@('Texte secondaire saisi','MutedColor','BgInput','Text')
        @('Lien et accent','AccentText','BgCard','Text'),@('Accent sur pastille','AccentText','AccentSoft','Text'),@('Information','InfoFg','InfoBg','Text'),@('Information sur pastille','InfoFg','AccentSoft','Text')
        @('Statut erreur','StatusError','BgCard','Text'),@('Statut attention','StatusWarning','BgCard','Text'),@('Statut confirme','StatusSuccess','BgCard','Text')
        @('Ligne selectionnee','RowSelFg','RowSelBg','Text'),@('Bouton','BtnFg','BtnBg','Text'),@('Journal','LogFg','LogBg','Text'),@('Privilege','PrivilegeFg','BgCard','Text')
        @('Ligne alternee','TextColor','DataGridAlt','Text'),@('En-tete de grille','TextColor','HeaderBg','Text'),@('Menu lateral','TextColor','UxSidebar','Text'),@('Menu lateral secondaire','MutedColor','UxSidebar','Text')
        @('Tuile','TextColor','TileBg','Text'),@('Bordure de saisie','MutedColor','BorderColor','Graphic'),@('Bouton principal','#FFFFFF','AccentColor','Text')
    )
    foreach ($pair in $pairs) { [pscustomobject]@{Name=$pair[0];Foreground=$pair[1];Background=$pair[2];Kind=$pair[3]} }
}

function Get-DomeniaBootContrastPairs {
    # Pairs painted by the login, startup and fatal-error windows with the boot palette (Get-DomeniaBootThemePalette).
    # The check box pairs are those of the fixed login template: text, box border and tick on the accent.
    $pairs = @(
        @('Texte de connexion','Text','Surface','Text'),@('Texte sur fond','Text','Window','Text'),@('Saisie','Text','Input','Text'),@('Texte secondaire','Muted','Surface','Text')
        @('Bouton','ButtonText','Button','Text'),@('Bouton principal','OnAccent','Accent','Text'),@('Accent','AccentText','Surface','Text')
        @('Erreur','Error','Surface','Text'),@('Attention','Warning','Surface','Text'),@('Succes','Success','Surface','Text')
        @('Case a cocher : texte','Text','Input','Text'),@('Case a cocher : bordure','Muted','Input','Graphic'),@('Case a cocher : coche','OnAccent','Accent','Graphic')
    )
    foreach ($pair in $pairs) { [pscustomobject]@{Name=$pair[0];Foreground=$pair[1];Background=$pair[2];Kind=$pair[3]} }
}

function Get-DomeniaBoundedWindowRect {
    # Restores a saved window rectangle inside the work area of a monitor that still exists.
    # $Monitors: work areas in device-independent units {Left, Top, Width, Height, Primary}, as WPF reports them.
    # The window is never larger than its monitor and never placed where no monitor shows it (an unplugged
    # monitor, the gap of an L-shaped layout): title bar and actions stay reachable, including at 200 %.
    param($Saved,[object[]]$Monitors=@(),[double]$MinWidth=640,[double]$MinHeight=420,[double]$DefaultWidth=1280,[double]$DefaultHeight=800)
    $screens = New-Object 'System.Collections.Generic.List[object]'
    foreach ($monitor in @($Monitors)) {
        $area = ConvertTo-DomeniaShellRect $monitor
        if (($null -ne $area) -and ($area.Width -gt 0) -and ($area.Height -gt 0)) {
            $screens.Add([pscustomobject]@{Left=$area.Left;Top=$area.Top;Width=$area.Width;Height=$area.Height;Primary=[bool](Get-DomeniaMember $monitor 'Primary' $false)})
        }
    }
    if ($screens.Count -eq 0) {
        return [pscustomobject]@{Left=0.0;Top=0.0;Width=$DefaultWidth;Height=$DefaultHeight;Monitor=-1;Adjusted=$true;UseSystemPlacement=$true;Reason='Aucun ecran connu : placement par defaut du systeme.'}
    }
    $primary = 0
    for ($i = 0; $i -lt $screens.Count; $i++) { if ($screens[$i].Primary) { $primary = $i; break } }
    $rect = ConvertTo-DomeniaShellRect $Saved
    $index = -1
    $best = 0.0
    if (($null -ne $rect) -and ($rect.Width -gt 0) -and ($rect.Height -gt 0)) {
        for ($i = 0; $i -lt $screens.Count; $i++) {
            $screen = $screens[$i]
            $overlapWidth = [Math]::Min($rect.Left + $rect.Width,$screen.Left + $screen.Width) - [Math]::Max($rect.Left,$screen.Left)
            $overlapHeight = [Math]::Min($rect.Top + $rect.Height,$screen.Top + $screen.Height) - [Math]::Max($rect.Top,$screen.Top)
            if (($overlapWidth -gt 0) -and ($overlapHeight -gt 0) -and (($overlapWidth * $overlapHeight) -gt $best)) { $best = $overlapWidth * $overlapHeight; $index = $i }
        }
    }
    $center = $false
    $reason = ''
    if (($null -eq $rect) -or ($rect.Width -le 0) -or ($rect.Height -le 0)) {
        $index = $primary; $center = $true
        $reason = 'Position enregistree invalide : fenetre centree sur l ecran principal.'
        $rect = [pscustomobject]@{Left=0.0;Top=0.0;Width=$DefaultWidth;Height=$DefaultHeight}
    } elseif ($index -lt 0) {
        $index = $primary; $center = $true
        $reason = 'Ecran d origine absent ou zone non affichee : fenetre ramenee sur l ecran principal.'
    }
    $screen = $screens[$index]
    $width = [Math]::Max($rect.Width,$MinWidth)
    $height = [Math]::Max($rect.Height,$MinHeight)
    if ($width -gt $screen.Width) { $width = $screen.Width }
    if ($height -gt $screen.Height) { $height = $screen.Height }
    if ($center) {
        $left = $screen.Left + (($screen.Width - $width) / 2.0)
        $top = $screen.Top + (($screen.Height - $height) / 2.0)
    } else {
        $left = [Math]::Min([Math]::Max($rect.Left,$screen.Left),$screen.Left + $screen.Width - $width)
        $top = [Math]::Min([Math]::Max($rect.Top,$screen.Top),$screen.Top + $screen.Height - $height)
    }
    $moved = (([Math]::Abs($left - $rect.Left) -gt 0.5) -or ([Math]::Abs($top - $rect.Top) -gt 0.5))
    $resized = (([Math]::Abs($width - $rect.Width) -gt 0.5) -or ([Math]::Abs($height - $rect.Height) -gt 0.5))
    if ((-not $reason) -and $resized) { $reason = 'Taille ramenee a la zone de travail de l ecran.' }
    elseif ((-not $reason) -and $moved) { $reason = 'Fenetre ramenee dans la zone visible de son ecran.' }
    return [pscustomobject]@{Left=$left;Top=$top;Width=$width;Height=$height;Monitor=$index;Adjusted=($center -or $moved -or $resized);UseSystemPlacement=$false;Reason=$reason}
}

function Get-DomeniaStatusGlyph {
    # A status is carried by a glyph AND a word; colour only reinforces them. Two statuses sharing a colour
    # (an error and a refusal) still differ by glyph and text. The words the repository actually produces are
    # recognised (New-DomeniaFact states, Verifie/Echec/Partiel/A verifier of the postconditions, Unconfirmed of
    # the continuity reader, OK/VIDE/PARTIEL/ERREUR/REFUSE/INDISPONIBLE of the core collectors), whatever the
    # case or the accents. An unrecognised status is shown as Inconnu (Recognized=false), never as a success.
    param([AllowEmptyString()][AllowNull()][string]$Status='')
    $aliases = @{
        'Ok'='Success';'Verifie'='Success';'Verified'='Success';'Reussi'='Success';'Succes'='Success';'Confirme'='Success'
        'Constate'='Observed';'Estime'='Estimated';'Attention'='Warning';'Avertissement'='Warning'
        'Partiel'='Partial';'Failed'='Error';'Failure'='Error';'Echec'='Error';'Erreur'='Error'
        'Refuse'='Refused';'Denied'='Refused';'Acces refuse'='Refused'
        'A verifier'='Uncertain';'Incertain'='Uncertain';'Unconfirmed'='Uncertain';'Non confirme'='Uncertain'
        'En cours'='Pending';'InProgress'='Pending';'Running'='Pending'
        'Inconnu'='Unknown';'Indetermine'='Unknown'
        'Indisponible'='Unavailable';'Injoignable'='Unavailable';'Unreachable'='Unavailable'
        'Vide'='Empty';'Aucun changement'='NoChange';'Information'='Info'
    }
    $catalog = @(
        @('Success',0x2713,'Confirme','StatusSuccess'),@('Observed',0x25CF,'Constate','TextColor'),@('Estimated',0x2248,'Estime','MutedColor'),
        @('Warning',0x26A0,'Attention','StatusWarning'),@('Partial',0x25D0,'Partiel','StatusWarning'),@('Error',0x2715,'Erreur','StatusError'),
        @('Refused',0x2298,'Refuse','StatusError'),@('Uncertain',0x2691,'A verifier','StatusWarning'),@('Pending',0x25F7,'En cours','AccentText'),
        @('Unknown',0x003F,'Inconnu','MutedColor'),@('Unavailable',0x25CB,'Indisponible','MutedColor'),@('Empty',0x2205,'Vide','MutedColor'),
        @('NoChange',0x003D,'Aucun changement','MutedColor'),@('Info',0x0069,'Information','InfoFg')
    )
    # Fold case, accents and inner spaces: an accented, upper-case or double-spaced form is the same word.
    $key = (([string]$Status).Trim() -replace '\s+',' ').Normalize([Text.NormalizationForm]::FormD)
    $key = [regex]::Replace($key,'\p{Mn}','')
    if ($aliases.ContainsKey($key)) { $key = [string]$aliases[$key] }
    $entry = $null
    foreach ($row in $catalog) { if ([string]$row[0] -ieq $key) { $entry = $row } }
    $recognized = ($null -ne $entry)
    if ($null -eq $entry) { $entry = @($catalog | Where-Object { $_[0] -eq 'Unknown' })[0] }
    return [pscustomobject]@{
        Status=[string]$entry[0];Requested=[string]$Status;Recognized=$recognized;Glyph=[string][char][int]$entry[1];Text=[string]$entry[2]
        ColorKey=[string]$entry[3];AutomationName=[string]$entry[2];FontFamily='Segoe UI Symbol'
    }
}

# ---------------------------------------------------------------- L08 header, read-only return, profile and session badge
function Get-DomeniaReadOnlyReturnPlan {
    # SE-06: write mode goes back to read-only after a delay without any write (15 min by default, bounded to 5-120).
    # The delay counts from the later of the activation and the last write seen. A write in progress is never
    # interrupted: the return waits for its end. Pure: the caller gives the clock and the dates.
    param(
        [bool]$WriteEnabled=$false,
        $EnabledAt=$null,
        $LastWriteAt=$null,
        [datetime]$Now=[datetime]::MinValue,
        $DelayMinutes=15,
        [bool]$WriteInProgress=$false
    )
    $delay = 15
    try { $delay = [int]$DelayMinutes } catch { $delay = 15 }
    if ($delay -lt 5) { $delay = 5 }
    if ($delay -gt 120) { $delay = 120 }
    if (-not $WriteEnabled) {
        return [pscustomobject]@{WriteEnabled=$false;DelayMinutes=$delay;Since=$null;RemainingSeconds=0;RemainingMinutes=0;Expired=$false;Deferred=$false
            Label='Lecture seule';ToolTip='Lecture seule : les modifications AD et les actions distantes modificatrices sont bloquées. Cliquez pour autoriser les modifications, après confirmation.'}
    }
    $since = $null
    foreach ($value in @($EnabledAt,$LastWriteAt)) {
        if ($null -eq $value) { continue }
        $date = $null
        try { $date = [datetime]$value } catch { $date = $null }
        if ($null -eq $date) { continue }
        if (($null -eq $since) -or ($date -gt $since)) { $since = $date }
    }
    # Without a known start the delay starts now: an unknown date never shortens the write window to nothing.
    if ($null -eq $since) { $since = $Now }
    $remaining = [int][Math]::Ceiling(($since.AddMinutes($delay) - $Now).TotalSeconds)
    if ($remaining -lt 0) { $remaining = 0 }
    $minutes = [int][Math]::Ceiling($remaining / 60.0)
    $deferred = (($remaining -le 0) -and $WriteInProgress)
    $expired = (($remaining -le 0) -and (-not $WriteInProgress))
    $label = 'Écriture active · ' + [string]$minutes + ' min'
    if ($deferred) { $label = 'Écriture active · écriture en cours' }
    $tip = 'Écriture active : les modifications sont autorisées, avec leurs confirmations. Retour automatique en lecture seule après ' + [string]$delay + ' min sans écriture ; une écriture en cours nʼest jamais interrompue. Cliquez pour repasser en lecture seule.'
    return [pscustomobject]@{WriteEnabled=$true;DelayMinutes=$delay;Since=$since;RemainingSeconds=$remaining;RemainingMinutes=$minutes;Expired=$expired;Deferred=$deferred;Label=$label;ToolTip=$tip}
}

function Get-DomeniaThemeToggleIcon {
    # DS-10: one convention for the main window and the login, the icon of the theme the button switches TO
    # (sun while dark, moon while light), drawn as a Path with the stroke of the menu icons.
    param([AllowEmptyString()][AllowNull()][string]$CurrentTheme='Light')
    $sun = 'M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12 M12,2 L12,4 M12,20 L12,22 M2,12 L4,12 M20,12 L22,12 M4.9,4.9 L6.3,6.3 M17.7,17.7 L19.1,19.1 M4.9,19.1 L6.3,17.7 M17.7,6.3 L19.1,4.9'
    $moon = 'M20,14.5 A8,8 0 1 1 9.5,4 A6.5,6.5 0 0 0 20,14.5 Z'
    if (([string]$CurrentTheme).Trim() -ieq 'Dark') {
        return [pscustomobject]@{Current='Dark';Target='Light';Glyph='Sun';Data=$sun;SunData=$sun;MoonData=$moon;Name='Passer au thème clair';ToolTip='Passer au thème clair. Le choix est enregistré pour Domenia.'}
    }
    return [pscustomobject]@{Current='Light';Target='Dark';Glyph='Moon';Data=$moon;SunData=$sun;MoonData=$moon;Name='Passer au thème sombre';ToolTip='Passer au thème sombre. Le choix est enregistré pour Domenia.'}
}

function Get-DomeniaSessionBadge {
    # UI-29 / SP-04: distinguish a query deadline from a confirmed network failure.
    # Both warnings clear at the next directory success. Nothing is retried from here.
    param(
        [AllowEmptyString()][AllowNull()][string]$Domain='',
        # Point 26: the domain controller actually queried is named in the tooltip.
        [AllowEmptyString()][AllowNull()][string]$Server='',
        [bool]$Offline=$false,
        $OfflineSince=$null,
        [bool]$Demo=$false,
        [AllowEmptyString()][AllowNull()][string]$DemoText='',
        [bool]$Slow=$false
    )
    if ($Demo -and (-not [string]::IsNullOrWhiteSpace($DemoText))) {
        $text = ConvertTo-DomeniaFlatText $DemoText 120
        return [pscustomobject]@{State='Demo';Text=$text;ToolTip=$text}
    }
    $domainText = ConvertTo-DomeniaFlatText $Domain 80
    if ($Offline) {
        $time = ''
        if ($null -ne $OfflineSince) { try { $time = ([datetime]$OfflineSince).ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture) } catch { $time = '' } }
        $text = 'AD injoignable'
        if ($time) { $text += ' depuis ' + $time }
        $text += ' · données déjà lues seulement'
        $tip = 'Le contrôleur de domaine ne répond plus : seules les données déjà lues sont consultables et les modifications attendent son retour. Aucune relance automatique ; le badge revient seul à la prochaine lecture réussie.'
        return [pscustomobject]@{State='Offline';Text=$text;ToolTip=$tip}
    }
    if ($Slow) {
        return [pscustomobject]@{State='Slow';Text='Dernière requête AD : délai dépassé';ToolTip='Une requête Active Directory a dépassé le délai prévu. Cela ne confirme pas une coupure de connexion. Ses résultats peuvent être incomplets ; consultez le journal. Le bandeau revient à la normale après une lecture AD réussie.'}
    }
    if ([string]::IsNullOrWhiteSpace($domainText)) {
        return [pscustomobject]@{State='Pending';Text='Session AD en préparation';ToolTip='La session AD nʼest pas encore établie.'}
    }
    $serverText = ConvertTo-DomeniaFlatText $Server 120
    $tip = 'Session Active Directory ouverte sur ' + $domainText + '.'
    if ($serverText) { $tip += ' Contrôleur interrogé : ' + $serverText + '. Un changement de contrôleur relit les repères de mise à jour au lieu de les extrapoler.' }
    return [pscustomobject]@{State='Connected';Text=('Connecté à ' + $domainText);ToolTip=$tip}
}

function ConvertFrom-DomeniaRecentJson {
    # FO-03 / UX-09: recent searches and fiches kept in the local preferences (JSON list). An unreadable or foreign
    # value gives an empty list, never an error; only the known members are kept, bounded on one line.
    # The list helpers of this section return their rows on the pipeline: callers wrap them in @().
    param([AllowEmptyString()][AllowNull()][string]$Json='')
    $out = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Json)) { return $out.ToArray() }
    $parsed = $null
    try { $parsed = $Json | ConvertFrom-Json } catch { return $out.ToArray() }
    foreach ($item in @($parsed)) {
        if ($null -eq $item) { continue }
        $kind = [string](Get-DomeniaMember $item 'Kind' '')
        if ($kind -notin @('Recherche','Fiche')) { continue }
        $text = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $item 'Text' '')) 80
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $out.Add([pscustomobject]@{Kind=$kind;Text=$text;Type=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $item 'Type' '')) 20);Dn=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $item 'Dn' '')) 400)})
    }
    return $out.ToArray()
}

function Add-DomeniaRecentEntry {
    # Newest first, one entry per kind and text (per DN for a fiche), at most $Maximum entries of each kind.
    # Returns a new list; the input list is never modified.
    param(
        [object[]]$Entries=@(),
        [ValidateSet('Recherche','Fiche')][string]$Kind='Recherche',
        [AllowEmptyString()][AllowNull()][string]$Text='',
        [AllowEmptyString()][AllowNull()][string]$Type='',
        [AllowEmptyString()][AllowNull()][string]$Dn='',
        [ValidateRange(1,50)][int]$Maximum=8
    )
    $clean = ConvertTo-DomeniaFlatText ([string]$Text) 80
    $list = New-Object 'System.Collections.Generic.List[object]'
    if (-not [string]::IsNullOrWhiteSpace($clean)) {
        $list.Add([pscustomobject]@{Kind=$Kind;Text=$clean;Type=(ConvertTo-DomeniaFlatText ([string]$Type) 20);Dn=(ConvertTo-DomeniaFlatText ([string]$Dn) 400)})
    }
    $count = $list.Count
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $entryKind = [string](Get-DomeniaMember $entry 'Kind' '')
        $entryText = [string](Get-DomeniaMember $entry 'Text' '')
        $entryDn = [string](Get-DomeniaMember $entry 'Dn' '')
        if ($entryKind -eq $Kind) {
            $same = ($entryText -ieq $clean)
            if (($Kind -eq 'Fiche') -and (-not [string]::IsNullOrWhiteSpace($Dn)) -and (-not [string]::IsNullOrWhiteSpace($entryDn))) { $same = ($entryDn -ieq [string]$Dn) }
            if ($same) { continue }
            if ($count -ge $Maximum) { continue }
            $count++
        }
        $list.Add($entry)
    }
    return $list.ToArray()
}

function Select-DomeniaRecentEntries {
    # Entries shown under the top search (and on the empty Fiche / Poste pages): those of the asked kinds whose
    # text starts with, or contains, the typed text. Local memory only: nothing here reads the directory.
    param([object[]]$Entries=@(),[string[]]$Kind=@('Recherche','Fiche'),[AllowEmptyString()][AllowNull()][string]$Text='',[AllowEmptyString()][string]$Type='',[ValidateRange(1,50)][int]$Maximum=8)
    $needle = ([string]$Text).Trim()
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Entries)) {
        if ($out.Count -ge $Maximum) { break }
        if ($null -eq $entry) { continue }
        if ([string](Get-DomeniaMember $entry 'Kind' '') -notin $Kind) { continue }
        if ($Type -and ((ConvertTo-DomeniaRelationType ([string](Get-DomeniaMember $entry 'Type' ''))) -ne (ConvertTo-DomeniaRelationType $Type))) { continue }
        $value = [string](Get-DomeniaMember $entry 'Text' '')
        if ($needle -and ($value.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        $out.Add($entry)
    }
    return $out.ToArray()
}

function Get-DomeniaSearchSuggestionItems {
    # FO-03: the list under the top search. Recent entries first (local memory), then rows of the local base read by the
    # LocalIndexRead worker; one line per text (case ignored), at most $Maximum lines. Each line names its source:
    # nothing in it comes from a directory request, and picking one only copies its text into the field.
    param([object[]]$Recent=@(),[object[]]$LocalRows=@(),[ValidateRange(1,50)][int]$Maximum=8)
    $seen = @{}
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Recent)) {
        if ($out.Count -ge $Maximum) { break }
        if ($null -eq $entry) { continue }
        $text = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $entry 'Text' '')) 80
        if ([string]::IsNullOrWhiteSpace($text) -or $seen.ContainsKey($text.ToLowerInvariant())) { continue }
        $seen[$text.ToLowerInvariant()] = $true
        $detail = 'Recherche récente'
        if ([string](Get-DomeniaMember $entry 'Kind' '') -eq 'Fiche') {
            $detail = 'Fiche récente'
            $type = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $entry 'Type' '')) 20
            if ($type) { $detail += ' · ' + $type }
        }
        $out.Add([pscustomobject]@{Source='Recent';Text=$text;Label=$text;Detail=$detail})
    }
    foreach ($row in @($LocalRows)) {
        if ($out.Count -ge $Maximum) { break }
        if ($null -eq $row) { continue }
        $text = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $row 'Name' '')) 80
        if ([string]::IsNullOrWhiteSpace($text)) { $text = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $row 'Login' '')) 80 }
        if ([string]::IsNullOrWhiteSpace($text) -or $seen.ContainsKey($text.ToLowerInvariant())) { continue }
        $seen[$text.ToLowerInvariant()] = $true
        $detail = 'Base locale'
        $type = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $row 'Type' '')) 20
        if ($type) { $detail += ' · ' + $type }
        $display = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $row 'Display' '')) 60
        if ($display -and ($display -ine $text)) { $detail += ' · ' + $display }
        $out.Add([pscustomobject]@{Source='Local';Text=$text;Label=$text;Detail=$detail})
    }
    return $out.ToArray()
}

function Get-DomeniaExpertTabDecision {
    # CO-06: a shortcut, a menu or the palette never changes the interface profile. An Expert view asked from
    # Essentiel is shown alone, for this navigation only (the profile and its saved value stay Essentiel). It is
    # refused, with its reason, when the administrator hides the Expert profile (UI.AllowExpertProfile = false) or
    # when the view does not apply to the selected object.
    param(
        [AllowEmptyString()][AllowNull()][string]$Tab='',
        [AllowEmptyString()][AllowNull()][string]$Profile='Tech',
        [bool]$AllowExpert=$true,
        [AllowEmptyString()][AllowNull()][string]$ObjectType=''
    )
    $expertTabs = @('TabRaw','TabPermissions','TabWmi','TabSelfCheck','TabCmdlets','TabLog')
    if ([string]$Tab -notin $expertTabs) {
        return [pscustomobject]@{Tab=$Tab;Expert=$false;Show=$true;Temporary=$false;ChangesProfile=$false;Reason=''}
    }
    $type = ConvertTo-DomeniaRelationType ([string]$ObjectType)
    $hasObject = -not [string]::IsNullOrWhiteSpace([string]$ObjectType)
    $notApplicable = ''
    if ($Tab -eq 'TabCmdlets') { $notApplicable = 'Vue retirée des outils.' }
    elseif (($Tab -in @('TabRaw','TabPermissions')) -and (-not $hasObject)) { $notApplicable = 'Ouvrez dʼabord une fiche.' }
    elseif (($Tab -eq 'TabWmi') -and ($type -ne 'Machine')) { $notApplicable = 'Vue réservée aux postes.' }
    if ($notApplicable) {
        return [pscustomobject]@{Tab=$Tab;Expert=$true;Show=$false;Temporary=$false;ChangesProfile=$false;Reason=$notApplicable}
    }
    if (-not $AllowExpert) {
        return [pscustomobject]@{Tab=$Tab;Expert=$true;Show=$false;Temporary=$false;ChangesProfile=$false;Reason='Vue réservée au profil Expert, masqué par lʼadministrateur.'}
    }
    if ([string]$Profile -eq 'Admin') {
        return [pscustomobject]@{Tab=$Tab;Expert=$true;Show=$true;Temporary=$false;ChangesProfile=$false;Reason=''}
    }
    return [pscustomobject]@{Tab=$Tab;Expert=$true;Show=$true;Temporary=$true;ChangesProfile=$false;Reason='Vue Expert affichée pour cette consultation ; le profil Essentiel est conservé.'}
}

# ---------------------------------------------------------------- SP-05 copy of result rows for a ticket
function ConvertTo-DomeniaTicketOuPath {
    # Readable path of the container of an object, from the domain down ('Lyon / Postes'). Display only: never a
    # search root. Escaped characters of the DN are decoded; the domain components are left out.
    param([AllowEmptyString()][string]$Dn)
    $parent = Get-DomeniaRawDnParent ([string]$Dn)
    if (-not $parent) { return '' }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in @(Split-DomeniaRawDn $parent)) {
        $equals = $part.IndexOf('=')
        if ($equals -lt 1) { continue }
        if ($part.Substring(0,$equals).Trim() -ieq 'DC') { continue }
        $names.Insert(0,(ConvertFrom-DomeniaDnLabel ($part.Substring($equals + 1).Trim())))
    }
    return ($names.ToArray() -join ' / ')
}

function ConvertTo-DomeniaTicketLine {
    # SP-05: one readable line per object for a ticket: Type · Nom · Compte · Présence · Utilisateur console · OU.
    # Allow-list projection: no GUID, no DN, no internal field of the grid. A value never spans several lines.
    param($Row)
    if ($null -eq $Row) { return '' }
    $flat = { param($Value,[int]$Max=120) ConvertTo-DomeniaFlatText ([string]$Value) $Max }
    $type = [string](Get-DomeniaMember $Row 'Type' '')
    $machine = ($type -eq 'Machine')
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $typeLabel = switch ($type) { 'Machine' { 'Poste' } 'Utilisateur' { 'Utilisateur' } 'Groupe' { 'Groupe' } 'OU' { 'OU' } 'Conteneur' { 'Conteneur' } default { 'Objet' } }
    $parts.Add($typeLabel)
    $name = & $flat (Get-DomeniaMember $Row 'Name' '')
    if ($name) { $parts.Add($name) }
    # The account column of the grid: the linked user of a workstation, the account name of a user or a group.
    $account = if ($machine) { & $flat (Get-DomeniaMember $Row 'Association' '') } elseif ($type -in @('Utilisateur','Groupe')) { & $flat (Get-DomeniaMember $Row 'Login' '') } else { '' }
    if ($account) { $parts.Add('Compte : ' + $account) }
    if ($machine) {
        $presence = & $flat (Get-DomeniaMember $Row 'Presence' '') 60
        if ($presence) {
            $age = & $flat (Get-DomeniaMember $Row 'PresenceAge' '') 30
            if ($age) { $presence += ' (' + $age + ')' }
            $parts.Add('Présence : ' + $presence)
        }
        $console = & $flat (Get-DomeniaMember $Row 'SessionDisplay' '')
        if ($console -and $console -notin @('Non déterminé','Non determine')) { $parts.Add('Utilisateur console : ' + $console) }
    }
    $ou = ConvertTo-DomeniaTicketOuPath ([string](Get-DomeniaMember $Row 'DN' ''))
    if ($ou) { $parts.Add('OU : ' + (& $flat $ou 240)) }
    return ($parts.ToArray() -join ' · ')
}

function ConvertTo-DomeniaTicketText {
    # SP-05: the text copied for a ticket, one line per selected row, masked by the secret rule before it leaves
    # Domenia (a description or an account name can carry a pasted secret).
    param([object[]]$Rows)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $line = ConvertTo-DomeniaTicketLine $row
        if ($line) { $lines.Add($line) }
    }
    return (Protect-DomeniaSecretText ($lines.ToArray() -join "`r`n"))
}
