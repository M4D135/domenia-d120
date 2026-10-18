# Shared presentation rules. No WPF, LDAP, credential or filesystem mutation.
$script:SuiteThemeRoot = $PSScriptRoot
$script:SuiteDesign = $null
$script:SuitePaletteCache = $null

function ConvertTo-SuiteFlag {
    param($Value,[bool]$Default=$false)
    if ($Value -is [bool]) { return $Value }
    $parsed=$false
    if ($null -ne $Value -and [bool]::TryParse([string]$Value,[ref]$parsed)) { return $parsed }
    return $Default
}

function ConvertTo-SuiteNumber {
    param($Value,[double]$Default=0,[double]$Minimum=0,[double]$Maximum=10000)
    $number=0.0
    $text=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
    if (-not [double]::TryParse($text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $Default }
    return [Math]::Max($Minimum,[Math]::Min($Maximum,$number))
}

function Test-DomeniaScopedSettingName {
    # Persist only the named storage policy and closed domain/store-scoped keys outside the declared defaults.
    # Backup receipts use the store SHA-256 (path + domain); their last success must survive a restart too.
    param([AllowEmptyString()][string]$Name)
    return ([string]$Name -cmatch '^(Storage\.PolicyJson|(Storage\.Database|Storage\.Backup\.(Last|LastDetail)|Dashboard\.HealthPolicies|Inventory\.BiosReferences)\.[0-9a-f]{64})$')
}

function ConvertTo-DomeniaExperienceSettings {
    param([System.Collections.IDictionary]$Values,[System.Collections.IDictionary]$Defaults)
    $out=[ordered]@{}
    $choices=@{
        # UX-03: PresenceFilter is no longer a preference (session filter only).
        # FO-22: Auto follows the Windows choice (AppsUseLightTheme), read locally at each resolution.
        UxDensity=@('Confort','Compact');Theme=@('Light','Dark','Auto');UiProfile=@('Tech','Admin')
        IndexAutoBuild=@('Ask','Always','Never');SearchType=@('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')
    }
    $numbers=@{
        WindowWidth=@(0,10000);WindowHeight=@(0,10000);WindowLeft=@(-32768,32768);WindowTop=@(-32768,32768)
        TreeWidth=@(0,900);LogHeight=@(42,600);UxLogExpandedHeight=@(100,600);UxLogFontSize=@(10,18)
        SearchLimit=@(1,20000);WmiLimit=@(1,500)
        'Ui.ZoomPercent'=@(80,150)
        'Collection.Concurrency'=@(1,8);'Collection.CacheMinutes'=@(0,1440)
    }
    foreach($key in $Defaults.Keys) {
        $value=$Defaults[$key]
        if($null -ne $Values -and $Values.Contains($key) -and $null -ne $Values[$key]){$value=$Values[$key]}
        if($Defaults[$key] -is [bool]){$value=ConvertTo-SuiteFlag $value -Default ([bool]$Defaults[$key])}
        elseif($choices.ContainsKey($key) -and [string]$value -notin $choices[$key]){$value=$Defaults[$key]}
        elseif($numbers.ContainsKey($key)){
            $range=$numbers[$key]
            $value=ConvertTo-SuiteNumber $value -Default ([double]$Defaults[$key]) -Minimum $range[0] -Maximum $range[1]
        }
        $out[$key]=$value
    }
    # Approved extra preferences pass through unchanged: string values only, at most 1 MiB each and 256 keys.
    if($null -ne $Values){
        $scoped=0
        foreach($key in @($Values.Keys)){
            if(($Defaults.Contains($key)) -or (-not (Test-DomeniaScopedSettingName ([string]$key)))){continue}
            $value=$Values[$key]
            if((-not ($value -is [string])) -or ($value.Length -gt 1048576) -or ($scoped -ge 256)){continue}
            $out[[string]$key]=$value;$scoped++
        }
    }
    return $out
}

function Get-SuiteDesign {
    if($null -ne $script:SuiteDesign){return $script:SuiteDesign}
    $path=Join-Path $script:SuiteThemeRoot 'SupportSuite.UI.json'
    $info=[IO.FileInfo]::new($path)
    if(-not $info.Exists -or $info.Length -gt 32768){throw 'Contrat visuel absent ou trop volumineux.'}
    $data=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json
    if([int]$data.SchemaVersion -ne 1){throw 'Version de contrat visuel non prise en charge.'}
    foreach($theme in @('Light','Dark')){
        if($null -eq $data.Palettes.$theme){throw 'Palette absente.'}
        foreach($prop in $data.Palettes.$theme.PSObject.Properties){
            if([string]$prop.Value -notmatch '^#[0-9A-Fa-f]{6}$'){throw ('Couleur invalide : '+$prop.Name)}
        }
        foreach($required in @('BgCard','BgInput','BgReadonly','BorderColor','TextColor','MutedColor','AccentColor','AccentSoft','DangerColor','WindowBg','DataGridBg','DataGridAlt','HeaderBg','LogBg','LogFg','BtnBg','BtnFg','TileBg','SplitterBg','InfoBg','InfoBorder','InfoFg','AccentText','RowSelBg','RowSelFg','RowHoverBg','PrivilegeFg','UxSidebar','StatusError','StatusWarning','StatusSuccess','StateOk','StateWarn','StateAlert','StateOff','StateInfo','StateOkMark','StateWarnMark','StateAlertMark','StateOffMark','StateInfoMark','ChartOther','ChartDisabled','ChartBlue','ChartViolet','ChartTeal','ChartPink','ChartSky','ChartPeach','ChartLilac','ChartSage','OnAccent','AccentHover','DangerHover','TooltipBg','TooltipFg','TooltipBorder','ScrollThumb','ScrollThumbHover','ChartBlueEdge','ChartVioletEdge','ChartTealEdge','ChartPinkEdge','ChartSkyEdge','ChartPeachEdge','ChartLilacEdge','ChartSageEdge','PillNeutralBg','PillNeutralFg','PillBlueBg','PillBlueFg','PillGreenBg','PillGreenFg','PillAmberBg','PillAmberFg','PillOrangeBg','PillOrangeFg','PillRedBg','PillRedFg','PillSkyBg','PillSkyFg')){
            if($null -eq $data.Palettes.$theme.PSObject.Properties[$required]){throw ('Couleur requise absente : '+$required)}
        }
    }
    $script:SuiteDesign=$data
    return $data
}

function Get-SuitePalette {
    param([ValidateSet('Light','Dark')][string]$Theme='Light')
    $data=Get-SuiteDesign
    $palette=[ordered]@{}
    foreach($prop in $data.Palettes.$Theme.PSObject.Properties){$palette[$prop.Name]=[string]$prop.Value}
    return $palette
}

# ---------------------------------------------------------------- CD-05 one palette, DS-14 chart series
function Get-DomeniaActiveThemeName {
    # Theme painted in this session (Light or Dark). Read without failing where the core state is absent (rule tests).
    $current=[string](Get-Variable -Name CurrentTheme -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if($current -eq 'Dark'){return 'Dark'}
    return 'Light'
}

function Get-DomeniaThemeColor {
    # CD-05: SupportSuite.UI.json is the only source of colours. Returns the '#RRGGBB' value of one token for the given
    # theme, or for the palette painted in this session (high contrast included, FO-22). A '#RRGGBB' value passes
    # through unchanged: it is a colour stored by an earlier version (board snapshots). An unknown token returns '',
    # never a guessed colour; the caller keeps its resource-based default.
    param([AllowEmptyString()][AllowNull()][string]$Key,[AllowEmptyString()][string]$Theme='')
    $name=([string]$Key).Trim()
    if(-not $name){return ''}
    if($name -match '^#[0-9A-Fa-f]{6}$'){return $name.ToUpperInvariant()}
    $palette=$null
    if($Theme -notin @('Light','Dark')){
        $palette=Get-Variable -Name DomeniaPaintedPalette -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if($null -eq $palette){$Theme=Get-DomeniaActiveThemeName}
    }
    if($null -eq $palette){
        if($null -eq $script:SuitePaletteCache){$script:SuitePaletteCache=@{}}
        if(-not $script:SuitePaletteCache.ContainsKey($Theme)){$script:SuitePaletteCache[$Theme]=Get-SuitePalette -Theme $Theme}
        $palette=$script:SuitePaletteCache[$Theme]
    }
    if($palette.Contains($name)){return [string]$palette[$name]}
    return ''
}

# ---------------------------------------------------------------- FO-22 automatic theme and high contrast
function ConvertTo-DomeniaThemePreference {
    # Stored choice of theme: Light, Dark or Auto (follow Windows). Case and spaces are ignored; '' when unknown.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $text=([string]$Value).Trim()
    foreach($known in @('Light','Dark','Auto')){if($text -ieq $known){return $known}}
    return ''
}

function Resolve-DomeniaEffectiveTheme {
    # FO-22: theme painted for a stored choice. Auto takes the Windows choice of the applications (WindowsTheme Light or
    # Dark, read by the caller from AppsUseLightTheme); without a readable Windows choice, or without a valid preference,
    # the theme is Light, as before. High contrast is carried apart: it replaces the colours, not the choice.
    param([AllowEmptyString()][AllowNull()][string]$Preference='',[AllowEmptyString()][AllowNull()][string]$WindowsTheme='',[bool]$HighContrast=$false)
    $choice=ConvertTo-DomeniaThemePreference $Preference
    $windows=ConvertTo-DomeniaThemePreference $WindowsTheme
    if($windows -eq 'Auto'){$windows=''}
    $theme='Light';$source='Défaut'
    if($choice -in @('Light','Dark')){$theme=$choice;$source='Choix'}
    elseif($choice -eq 'Auto'){
        if($windows){$theme=$windows;$source='Windows'}else{$source='Windows illisible'}
    }
    if(-not $choice){$choice='Light'}
    return [pscustomobject]@{Preference=$choice;Theme=$theme;HighContrast=[bool]$HighContrast;Source=$source}
}

function Get-DomeniaThemeChoices {
    # FO-22: the choices of the menu of the theme button, in this order.
    return @(
        [pscustomobject]@{Value='Light';Label='Clair'}
        [pscustomobject]@{Value='Dark';Label='Sombre'}
        [pscustomobject]@{Value='Auto';Label='Automatique (suit Windows)'}
    )
}

function Get-DomeniaHighContrastRoles {
    # FO-22: in a Windows high contrast theme every token of SupportSuite.UI.json takes a system colour (Window,
    # WindowText, Control, ControlText, Highlight, HighlightText, HotTrack, GrayText). Categories and states then read
    # by their words and symbols only (P116), as Windows asks. Every token has a role: rules/Theme.Tests.ps1 checks it.
    return [ordered]@{
        BgCard='Window'
        BgInput='Window'
        BgReadonly='Window'
        BorderColor='WindowText'
        TextColor='WindowText'
        MutedColor='WindowText'
        AccentColor='Highlight'
        AccentSoft='Window'
        DangerColor='Highlight'
        WindowBg='Window'
        DataGridBg='Window'
        DataGridAlt='Window'
        HeaderBg='Control'
        LogBg='Window'
        LogFg='WindowText'
        BtnBg='Control'
        BtnFg='ControlText'
        TileBg='Control'
        SplitterBg='WindowText'
        InfoBg='Window'
        InfoBorder='WindowText'
        InfoFg='WindowText'
        AccentText='HotTrack'
        RowSelBg='Highlight'
        RowSelFg='HighlightText'
        RowHoverBg='Window'
        PrivilegeFg='WindowText'
        UxSidebar='Window'
        StatusError='WindowText'
        StatusWarning='WindowText'
        StatusSuccess='WindowText'
        StateOk='Highlight'
        StateWarn='Highlight'
        StateAlert='Highlight'
        StateOff='GrayText'
        StateInfo='Highlight'
        StateOkMark='WindowText'
        StateWarnMark='WindowText'
        StateAlertMark='WindowText'
        StateOffMark='GrayText'
        StateInfoMark='WindowText'
        ChartOther='GrayText'
        ChartDisabled='GrayText'
        ChartBlue='Highlight'
        ChartViolet='Highlight'
        ChartTeal='Highlight'
        ChartPink='Highlight'
        ChartSky='Highlight'
        ChartPeach='Highlight'
        ChartLilac='Highlight'
        ChartSage='Highlight'
        OnAccent='HighlightText'
        AccentHover='Highlight'
        DangerHover='Highlight'
        TooltipBg='Window'
        TooltipFg='WindowText'
        TooltipBorder='WindowText'
        ScrollThumb='WindowText'
        ScrollThumbHover='Highlight'
        ChartBlueEdge='WindowText'
        ChartVioletEdge='WindowText'
        ChartTealEdge='WindowText'
        ChartPinkEdge='WindowText'
        ChartSkyEdge='WindowText'
        ChartPeachEdge='WindowText'
        ChartLilacEdge='WindowText'
        ChartSageEdge='WindowText'
        PillNeutralBg='Window'
        PillNeutralFg='WindowText'
        PillBlueBg='Window'
        PillBlueFg='WindowText'
        PillGreenBg='Window'
        PillGreenFg='WindowText'
        PillAmberBg='Window'
        PillAmberFg='WindowText'
        PillOrangeBg='Window'
        PillOrangeFg='WindowText'
        PillRedBg='Window'
        PillRedFg='WindowText'
        PillSkyBg='Window'
        PillSkyFg='WindowText'
    }
}

function ConvertTo-DomeniaHighContrastPalette {
    # FO-22: the palette of a high contrast session. $SystemColors: role -> '#RRGGBB' (read by the caller from WPF
    # SystemColors). A token whose role colour is missing or invalid keeps its own colour; nothing is guessed.
    param($Palette,$SystemColors)
    $roles=Get-DomeniaHighContrastRoles
    $out=[ordered]@{}
    if($null -eq $Palette){return $out}
    foreach($key in @($Palette.Keys)){
        $value=[string]$Palette[$key]
        if($roles.Contains([string]$key) -and ($null -ne $SystemColors)){
            $role=[string]$roles[[string]$key]
            $system=''
            if($SystemColors -is [Collections.IDictionary]){if($SystemColors.Contains($role)){$system=[string]$SystemColors[$role]}}
            elseif($null -ne $SystemColors.PSObject.Properties[$role]){$system=[string]$SystemColors.$role}
            if($system -match '^#[0-9A-Fa-f]{6}$'){$value=$system.ToUpperInvariant()}
        }
        $out[[string]$key]=$value
    }
    return $out
}

function Get-DomeniaChartSeriesNames {
    # DS-14: order of the categorical series of the charts. Pastels outside the state hues: yellow, green and red keep
    # their meaning (Attention, Correct, Alerte) and never name a category such as a publisher or an architecture.
    return @('ChartBlue','ChartViolet','ChartTeal','ChartPink','ChartSky','ChartPeach','ChartLilac','ChartSage')
}

function Get-DomeniaChartSeries {
    # DS-14: fill and 1-unit edge of each categorical series for a theme. On the light theme the pastel fill stays
    # under 3:1 against the card, its darker edge reaches it; on the dark theme the fill itself is above 3:1.
    param([AllowEmptyString()][string]$Theme='')
    foreach($name in @(Get-DomeniaChartSeriesNames)){
        [pscustomobject]@{Token=$name;Fill=(Get-DomeniaThemeColor -Key $name -Theme $Theme);Edge=(Get-DomeniaThemeColor -Key ($name+'Edge') -Theme $Theme)}
    }
}

function Test-DomeniaExperienceRow {
    param($Row,[AllowEmptyString()][string]$Query='')
    if($null -eq $Row){return $false}
    if([string]::IsNullOrWhiteSpace($Query)){return $true}
    # A literal filter over known result fields only. No regex/wildcards, no secrets.
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach($name in @('Type','Name','Login','UPN','Association','Presence','SessionDisplay','SessionState')){
        $value='';try{$value=[string]$Row.$name}catch{if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Experience' 'Test-DomeniaExperienceRow' $_ }}
        if($value.Length -gt 2048){$value=$value.Substring(0,2048)}
        $parts.Add($value)
    }
    $haystack=[string]::Join(' ',$parts.ToArray())
    if($Query.Length -gt 120){$Query=$Query.Substring(0,120)}
    foreach($term in ($Query.Trim() -split '\s+')){
        if($haystack.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -lt 0){return $false}
    }
    return $true
}

function Get-DomeniaFilteredEmptyState {
    # UX-03 / UI-15: every loaded row is hidden by a filter of the list (its text or the presence). The empty list then
    # says how many rows the filter hides and offers to clear it, instead of looking like an empty directory.
    # Display rule only: clearing the filter shows the rows already loaded again, without any request.
    param([int]$Loaded=0,[int]$Visible=0,[AllowEmptyString()][AllowNull()][string]$LocalText='',[AllowEmptyString()][AllowNull()][string]$Presence='Tous')
    $text = ([string]$LocalText).Trim()
    $presenceKey = ([string]$Presence).Trim()
    $presenceActive = ([bool]$presenceKey) -and ($presenceKey -notin @('Tous','Toute présence'))
    if (($Loaded -le 0) -or ($Visible -gt 0) -or ((-not $text) -and (-not $presenceActive))) {
        return [pscustomobject]@{Show=$false;Text='';Detail=''}
    }
    $culture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $title = 'Le filtre masque ' + $Loaded.ToString('N0',$culture) + $(if ($Loaded -gt 1) { ' lignes' } else { ' ligne' })
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($text) { $parts.Add('texte « ' + $text + ' »') }
    if ($presenceActive) { $parts.Add('présence : ' + $presenceKey) }
    $detail = 'Filtre de la liste : ' + ($parts.ToArray() -join ' · ') + '. Effacer le filtre réaffiche les lignes déjà chargées, sans requête AD.'
    return [pscustomobject]@{Show=$true;Text=$title;Detail=$detail}
}

function Test-DomeniaExperienceCanCancel {
    param($Job,[long]$SessionEpoch)
    if($null -eq $Job){return $false}
    foreach($required in @('Id','IsWrite','NonCancellable','CancelRequested','SessionEpoch')){
        if($null -eq $Job.PSObject.Properties[$required]){return $false}
    }
    if($Job.IsWrite -isnot [bool] -or $Job.NonCancellable -isnot [bool] -or $Job.CancelRequested -isnot [bool]){return $false}
    return (-not $Job.IsWrite -and -not $Job.NonCancellable -and -not $Job.CancelRequested -and
        [long]$Job.SessionEpoch -eq $SessionEpoch -and -not [string]::IsNullOrWhiteSpace([string]$Job.Id))
}

function Get-DomeniaExperienceTaskRow {
    param($Job,[datetime]$Now=(Get-Date),[switch]$Detached,[long]$SessionEpoch=0)
    if($null -eq $Job){return $null}
    $state='En cours';$detail='Traitement actif. Aucun résultat final annoncé.'
    if($Detached){$state='Nettoyage';$detail='Lecture détachée, appel natif encore en cours de nettoyage.'}
    # D015/D017: an entry of the engine queue has sent nothing yet.
    elseif($null -ne $Job.PSObject.Properties['State'] -and [string]$Job.State -eq 'Queued'){$state='En attente';$detail='Demande en file : aucune lecture envoyée pour l''instant.'}
    elseif([bool]$Job.IsWrite -and ([bool]$Job.CancelRequested -or [bool]$Job.TimeoutNotified -or [bool]$Job.TimeoutErrorDelivered)){$state='À vérifier';$detail='Écriture envoyée : son résultat reste à vérifier. Aucun rejeu automatique.'}
    elseif([bool]$Job.CancelRequested){$state='Arrêt demandé';$detail='La demande est envoyée ; la fin du worker n''est pas confirmée.'}
    elseif([bool]$Job.TimeoutNotified -or [bool]$Job.TimeoutErrorDelivered){$state='À vérifier';$detail='Délai dépassé. Ne pas déduire une réussite ou relancer une écriture.'}
    # Point 46: the right this operation needs, so that a refusal reads against it. Resolved at call time
    # (Domenia-Access.Model.ps1); without that rule the row keeps its state sentence only.
    try{$need=Get-DomeniaOperationRequirement ([string]$Job.OperationId);if([bool]$need.Known){$detail+=' Accès requis : '+[string]$need.Right}}catch{if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Experience' 'Get-DomeniaExperienceTaskRow' $_ }}
    $seconds=0.0;try{$seconds=[Math]::Max(0,($Now-[datetime]$Job.Started).TotalSeconds)}catch{if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Experience' 'Get-DomeniaExperienceTaskRow' $_ }}
    $duration=[TimeSpan]::FromSeconds([Math]::Min($seconds,315360000))
    $durationLabel=if($duration.TotalHours -ge 1){'{0:0} h {1:00} min' -f [Math]::Floor($duration.TotalHours),$duration.Minutes}else{'{0:00}:{1:00}' -f [Math]::Floor($duration.TotalMinutes),$duration.Seconds}
    # Do not copy CallbackState, Payload, output, credential or script source.
    [pscustomobject]@{
        Id=[string]$Job.Id;Name=[string]$Job.Name;Operation=[string]$Job.OperationId
        Kind=$(if([bool]$Job.IsWrite){'Écriture'}elseif([string]$Job.OperationId -eq 'LiveCache'){'Cache local'}else{'Lecture'})
        State=$state;Duration=$durationLabel;Detail=$detail;Detached=[bool]$Detached
        CanCancel=((-not $Detached) -and (Test-DomeniaExperienceCanCancel $Job $SessionEpoch))
    }
}

function Get-DomeniaExperienceBatchRows {
    # The logical collection remains visible between workers and until its last local save is confirmed.
    # Only scalar presentation fields leave this projection; no targets, credentials or payloads are copied.
    param([object[]]$Runs=@(),$Refresh=$null,[long]$SessionEpoch=0,[string]$Path='',[long]$AccountGeneration=0)
    $linked=@{}
    foreach($run in $Runs){
        if($null -eq $run -or [bool]$run.Completed -or [long]$run.Epoch -ne $SessionEpoch -or [string]$run.Path -cne $Path -or [long]$run.AccountGeneration -ne $AccountGeneration){continue}
        if([string]$run.RefreshOperationId){$linked[[string]$run.RefreshOperationId]=$true}
        $kind=if([bool]$run.PingOnly){'Ping'}elseif([bool]$run.WmiOnly){'WMI'}else{'Postes'}
        $total=@($run.Targets).Count;$done=[int]$run.Done
        $state=if([bool]$run.Stopping){'Arrêt demandé'}elseif([bool]$run.Loading -or [bool](Get-DomeniaMember $run 'Planning' $false)){'Préparation'}elseif(-not [bool]$run.Approved){'À confirmer'}elseif($run.Pending.Count -gt 0){'En cours'}elseif($run.StorePending.Count -gt 0){'Enregistrement'}else{'En attente'}
        $progress=if([bool]$run.Loading){'préparation'}else{[string]$done+'/'+[string]$total}
        $detail=[string]$done+'/'+[string]$total+' postes traités · '+[string][int]$run.Failed+' lecture(s) non confirmée(s) · '+[string][int]$run.Errors+' erreur(s) de ping · '+[string]$run.Pending.Count+' lecture(s) en cours · '+[string]$run.StorePending.Count+' enregistrement(s) en attente.'
        $skipped=[int](Get-DomeniaMember $run 'SkippedTargets' 0)
        if($skipped -gt 0){$detail+=' '+$skipped+' poste(s) non relu(s) : capacité indisponible.'}
        if([string]$run.StatusText){$detail+=' '+[string]$run.StatusText}
        [pscustomobject]@{Id=('batch:'+ [string]$run.Id);Name=('Lot '+$kind+' · '+[string]$run.ScopeLabel);Operation='Collection';Kind='Lot';State=$state;Duration='';Detail=$detail;Detached=$false;CanCancel=(-not [bool]$run.Stopping);Header=($kind+' · '+$progress);RunId=[string]$run.Id;RefreshId=[string]$run.RefreshOperationId}
    }
    # An OU batch exists before Park has resolved its targets (AD, preparation, confirmation).
    if($null -ne $Refresh -and -not [bool]$Refresh.Completed -and [long]$Refresh.Epoch -eq $SessionEpoch -and [string]$Refresh.Path -ceq $Path -and -not $linked.ContainsKey([string]$Refresh.Id)){
        $kind=switch([string]$Refresh.Mode){'Wmi'{'WMI'};'Ping'{'Ping'};'AD'{'Objets AD'};'Base'{'Objets AD'};default{'Actualisation'}}
        $state=switch([string]$Refresh.Phase){'Directory'{'Lecture AD'};'WaitingCollection'{'En attente'};'Confirming'{'À confirmer'};'Collecting'{'En cours'};'Saving'{'Enregistrement'};default{'Préparation'}}
        [pscustomobject]@{Id=('refresh:'+ [string]$Refresh.Id);Name=('Lot '+$kind+' · '+[string]$Refresh.Label);Operation='Collection';Kind='Lot';State=$state;Duration='';Detail=[string]$Refresh.Status;Detached=$false;CanCancel=(-not [bool]$Refresh.Cancelled);Header=($kind+' · '+$state.ToLowerInvariant());RunId='';RefreshId=[string]$Refresh.Id}
    }
}

function Find-SuiteLiteralText {
    param([AllowEmptyString()][string]$Text,[AllowEmptyString()][string]$Query,[int]$Start=0)
    if([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Query)){return -1}
    $from=[Math]::Max(0,[Math]::Min($Start,$Text.Length))
    $index=$Text.IndexOf($Query,$from,[StringComparison]::OrdinalIgnoreCase)
    if($index -lt 0 -and $from -gt 0){$index=$Text.IndexOf($Query,[StringComparison]::OrdinalIgnoreCase)}
    return $index
}
