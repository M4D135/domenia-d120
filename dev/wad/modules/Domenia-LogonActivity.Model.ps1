# Point 27: explaining Active Directory logon data. lastLogonTimestamp is replicated but only refreshed once it is
# older than msDS-LogonTimeSyncInterval minus a random part of up to five days; lastLogon is exact but kept by each
# controller for the logons it validated, and never replicated. Pure rules: no LDAP, no clock read.

function Get-DomeniaLogonSyncInterval {
    # Interval of the domain head. ReadState: Read (value present), Absent (attribute not set, default of 14 days),
    # Refused or NotRead (unknown: the default of 14 days is assumed and said so).
    param($Value=$null,[ValidateSet('Read','Absent','Refused','NotRead')][string]$ReadState='NotRead')
    $days=14;$state='NotRead'
    if($ReadState -eq 'Read'){
        $number=0L
        if([long]::TryParse(([string]$Value).Trim(),[ref]$number) -and ($number -ge 0) -and ($number -le 100000)){$days=[int]$number;$state='Read'}
    }elseif($ReadState -eq 'Absent'){$state='Default'}
    elseif($ReadState -eq 'Refused'){$state='Refused'}
    $text='Intervalle de mise à jour non lu : 14 jours par défaut supposés.'
    if($state -eq 'Read'){
        $text=if($days -eq 0){'msDS-LogonTimeSyncInterval vaut 0 sur ce domaine : Domenia nʼen déduit aucun délai.'}else{'Intervalle de mise à jour lu sur le domaine : '+$days+' jour(s).'}
    }elseif($state -eq 'Default'){$text='Intervalle de mise à jour non défini sur le domaine : 14 jours par défaut.'}
    elseif($state -eq 'Refused'){$text='Intervalle de mise à jour non lisible avec ce compte : 14 jours par défaut supposés.'}
    return [pscustomobject]@{Days=$days;State=$state;Text=$text}
}

function Get-DomeniaLogonLagText {
    # How late lastLogonTimestamp may be: the interval minus a random part of up to five days.
    param([int]$Days=14)
    if($Days -le 0){return 'un délai que Domenia ne détermine pas'}
    if($Days -gt 5){return ([string]($Days-5)+' à '+[string]$Days+' jours')}
    return ('au plus '+[string]$Days+' jour(s)')
}

function Get-DomeniaLogonActivitySummary {
    # Approximate activity from lastLogonTimestamp alone. Never a presence measure; an empty value does not prove
    # that no logon happened.
    param($LastLogonTimestamp=$null,$Interval=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    if($null -eq $Interval){$Interval=Get-DomeniaLogonSyncInterval -ReadState 'NotRead'}
    $days=[int](Get-DomeniaMember $Interval 'Days' 14)
    $lag=Get-DomeniaLogonLagText $days
    $at=ConvertTo-DomeniaUtcDate $LastLogonTimestamp
    if($null -eq $at){
        return [pscustomobject]@{State='Empty';ApproxUtc=$null;AgeDays=-1;Text=('Activité approximative : lastLogonTimestamp est vide. Cela ne prouve pas quʼaucune connexion nʼa eu lieu ; la lecture par contrôleur donne la valeur exacte de chacun.')}
    }
    $ageDays=[int][Math]::Floor(($NowUtc-$at).TotalDays)
    $text='Activité approximative : dernière connexion connue vers le '+$at.ToLocalTime().ToString('dd/MM/yyyy')+' (lastLogonTimestamp, répliqué). Cette date nʼest actualisée que lorsquʼelle a plus de '+$lag+' : une connexion plus récente peut ne pas y figurer. Elle ne prouve pas une présence actuelle.'
    if($at -gt $NowUtc.AddMinutes(5)){$text='Activité approximative : date de connexion dans le futur ('+$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm')+') ; vérifiez lʼhorloge avant de vous y fier.'}
    return [pscustomobject]@{State='Approx';ApproxUtc=$at;AgeDays=$ageDays;Text=$text}
}

function Merge-DomeniaLogonReadings {
    # Exact lastLogon of each controller, read on demand, with the coverage of the controllers listed when the read
    # started. The most recent value is the last logon known to the domain only when every listed controller answered.
    # $Readings: {Dc, Kind (RWDC or RODC), State (Read, Absent, Refused, Unavailable, NotRead), LastLogonUtc, Error}.
    param([object[]]$Readings=@(),[int]$KnownCount=0,[bool]$ListTruncated=$false,$LastLogonTimestamp=$null)
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $missing=New-Object 'System.Collections.Generic.List[string]'
    $read=0;$best=$null;$bestDc=''
    foreach($reading in @($Readings)){
        if($null -eq $reading){continue}
        $dc=[string](Get-DomeniaMember $reading 'Dc' '')
        $state=[string](Get-DomeniaMember $reading 'State' 'NotRead')
        $kind=[string](Get-DomeniaMember $reading 'Kind' '')
        $at=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $reading 'LastLogonUtc' $null)
        $value=''
        if($state -eq 'Read'){
            $read++
            if($null -ne $at){
                $value=$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')
                if(($null -eq $best) -or ($at -gt $best)){$best=$at;$bestDc=$dc}
            }else{$value='Aucune connexion enregistrée par ce contrôleur'}
        }elseif($state -eq 'Absent'){$missing.Add($dc);$value='Objet absent de ce contrôleur (réplication en cours ou droits)'}
        elseif($state -eq 'Refused'){$missing.Add($dc);$value='Lecture refusée pour ce compte'}
        elseif($state -eq 'Unavailable'){
            $missing.Add($dc)
            $detail=ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $reading 'Error' '')) 160
            $value='Contrôleur non joint'+$(if($detail){' : '+$detail}else{''})
        }else{$missing.Add($dc);$value='Non lu : budget de temps atteint'}
        $rows.Add([pscustomobject]@{Controleur=$dc;Type=$kind;Etat=$state;Valeur=$value;DateUtc=$at})
    }
    $known=[Math]::Max($KnownCount,$rows.Count)
    $complete=(($known -gt 0) -and ($read -eq $known) -and (-not $ListTruncated))
    $lines=New-Object 'System.Collections.Generic.List[string]'
    if($null -ne $best){$lines.Add('Connexion la plus récente lue : '+$best.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')+' sur '+$bestDc+'.')}
    elseif($read -gt 0){$lines.Add('Aucune connexion enregistrée par les contrôleurs qui ont répondu.')}
    else{$lines.Add('Aucun contrôleur nʼa répondu : aucune valeur exacte.')}
    $coverage='Couverture : '+$read+' contrôleur(s) lu(s) sur '+$known+' recensé(s)'
    if($ListTruncated){$coverage+=', liste des contrôleurs tronquée'}
    $lines.Add($coverage+'.')
    if($complete){$lines.Add('Tous les contrôleurs recensés ont répondu : la date la plus récente est la dernière connexion connue du domaine au moment de la lecture.')}
    elseif($missing.Count){$lines.Add('Une connexion plus récente peut avoir été validée par un contrôleur non lu : '+(($missing.ToArray()|Select-Object -First 10) -join ', ')+$(if($missing.Count -gt 10){'…'}else{''})+'.')}
    $timestamp=ConvertTo-DomeniaUtcDate $LastLogonTimestamp
    if(($null -ne $best) -and ($null -ne $timestamp) -and ($best -gt $timestamp)){
        $lagDays=[int][Math]::Floor(($best-$timestamp).TotalDays)
        if($lagDays -ge 1){$lines.Add('lastLogonTimestamp a '+$lagDays+' jour(s) de retard sur cette date : écart attendu de sa mise à jour espacée.')}
    }
    $lines.Add('lastLogon nʼest pas répliqué : chaque contrôleur ne connaît que les connexions quʼil a validées. Une connexion ne prouve pas une présence actuelle.')
    $ordered=@($rows.ToArray()|Sort-Object @{Expression={if($null -ne $_.DateUtc){$_.DateUtc}else{[datetime]::MinValue}};Descending=$true},@{Expression={$_.Controleur}})
    return [pscustomobject]@{Rows=$ordered;MostRecentUtc=$best;MostRecentDc=$bestDc;ReadCount=$read;KnownCount=$known;Complete=$complete;Missing=$missing.ToArray();Text=($lines.ToArray() -join ' ')}
}

function Format-DomeniaLogonReadingsText {
    # Text of the fiche panel: summary first, then one line per controller (bounded).
    param($Merge,$Interval=$null,[int]$MaxLines=50)
    $nl=[Environment]::NewLine
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add([string](Get-DomeniaMember $Merge 'Text' ''))
    $count=0
    foreach($row in @(Get-DomeniaMember $Merge 'Rows' @())){
        if($count -ge $MaxLines){$lines.Add('… '+(@(Get-DomeniaMember $Merge 'Rows' @()).Count-$MaxLines)+' contrôleur(s) de plus.');break}
        $kind=[string]$row.Type
        $lines.Add('• '+[string]$row.Controleur+$(if($kind -eq 'RODC'){' (lecture seule)'}else{''})+' : '+[string]$row.Valeur)
        $count++
    }
    if($null -ne $Interval){$lines.Add([string](Get-DomeniaMember $Interval 'Text' ''))}
    return ($lines.ToArray() -join $nl)
}
