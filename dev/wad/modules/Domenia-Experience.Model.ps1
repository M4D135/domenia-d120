# Shared presentation rules. No WPF, LDAP, credential or filesystem mutation.
$script:SuiteThemeRoot = $PSScriptRoot
$script:SuiteDesign = $null

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

function ConvertTo-DomeniaExperienceSettings {
    param([System.Collections.IDictionary]$Values,[System.Collections.IDictionary]$Defaults)
    $out=[ordered]@{}
    $choices=@{
        UxDensity=@('Confort','Compact');Theme=@('Light','Dark');UiProfile=@('Tech','Admin');PresenceFilter=@('Tous','En ligne','Hors ligne','Inconnu')
        IndexAutoBuild=@('Ask','Always','Never');SearchType=@('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')
    }
    $numbers=@{
        WindowWidth=@(0,10000);WindowHeight=@(0,10000);WindowLeft=@(-32768,32768);WindowTop=@(-32768,32768)
        TreeWidth=@(0,900);LogHeight=@(42,600);UxLogExpandedHeight=@(100,600);UxLogFontSize=@(10,18)
        SearchLimit=@(1,500);WmiLimit=@(1,500)
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
        foreach($required in @('BgCard','BgInput','BgReadonly','BorderColor','TextColor','MutedColor','AccentColor','AccentSoft','DangerColor','WindowBg','DataGridBg','DataGridAlt','HeaderBg','LogBg','LogFg','BtnBg','BtnFg','TileBg','SplitterBg','InfoBg','InfoBorder','InfoFg','AccentText','RowSelBg','RowSelFg','RowHoverBg','PrivilegeFg','UxSidebar','StatusError','StatusWarning','StatusSuccess')){
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

function Test-DomeniaExperienceRow {
    param($Row,[AllowEmptyString()][string]$Query='')
    if($null -eq $Row){return $false}
    if([string]::IsNullOrWhiteSpace($Query)){return $true}
    # A literal filter over known result fields only. No regex/wildcards, no secrets.
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach($name in @('Type','Name','Login','UPN','Association','Presence','SessionDisplay','SessionState')){
        $value='';try{$value=[string]$Row.$name}catch{}
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
    $seconds=0.0;try{$seconds=[Math]::Max(0,($Now-[datetime]$Job.Started).TotalSeconds)}catch{}
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

function Find-SuiteLiteralText {
    param([AllowEmptyString()][string]$Text,[AllowEmptyString()][string]$Query,[int]$Start=0)
    if([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Query)){return -1}
    $from=[Math]::Max(0,[Math]::Min($Start,$Text.Length))
    $index=$Text.IndexOf($Query,$from,[StringComparison]::OrdinalIgnoreCase)
    if($index -lt 0 -and $from -gt 0){$index=$Text.IndexOf($Query,[StringComparison]::OrdinalIgnoreCase)}
    return $index
}
