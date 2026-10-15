# Interpreted readings of one workstation (points 81 to 100). Pure rules: no CIM, no WPF, no disk and no clock read.
# A reading turns stored probe entries (typed instances kept by the collector) or inventory rows into explainable
# facts (New-DomeniaFact): what was reported, when, by which source, and what it does not prove. A value that was
# not read stays unknown, a computed value is an estimate, and an absent provider is never a healthy state.
# Relies on Domenia-Common.Model.ps1 (facts, dates, members) and Domenia-Probes.Model.ps1 (numbers, EDID texts).

# ---------------------------------------------------------------- catalogue and shared helpers
function Get-DomeniaReadingCatalog {
    # Id|Title|detailed probes read by the reading|historical single-value probes that open the same reading.
    $text = @'
memory|Mémoire : capacité et occupation|hw.memorymodules,hw.memoryarrays,hw.memoryusage|hw.ram,os.freeram,os.visiblememory,os.virtualfree
volumes|Volumes et prévision de saturation|disk.volumes|disk.cfree,disk.csize,disk.count
storage|Santé du stockage|disk.physical,disk.reliability|disk.media,disk.health
battery|Batteries|hw.batteries,hw.batterystatic,hw.batteryfullcharge,hw.batterycycles|hw.batterylevel,hw.battery
bios|BIOS et micrologiciel|hw.biosdetails,hw.computersystem|hw.bios,hw.biosyear,hw.serialmissing,hw.maker,hw.model
processor|Processeurs et virtualisation|hw.processors,hw.computersystem|hw.cpu,hw.cpuload,hw.cpumhz,hw.virtualization,hw.slat,hw.cores,hw.threads,hw.chassis
displays|Écrans, raccordements et stations dʼaccueil|hw.monitors,hw.monitorconnections,hw.dockhints|hw.screens,hw.gpu
network|Interfaces réseau|net.interfaces,net.configurations|net.adapter,net.speed,net.dhcp,net.dns,net.gateway,net.wifi
devices|Imprimantes et périphériques en erreur|soft.printerdetails,hw.deviceerrors|soft.printers,soft.defaultprinter,soft.spooler
services|Services et profil attendu|soft.servicedetails|soft.stoppedauto,soft.running,soft.wuauserv,soft.winrm,soft.bits,soft.w32time,soft.rdp,soft.dnsclient
tasks|Tâches planifiées et démarrage automatique|soft.scheduledtasks,soft.startupdetails|soft.startup
antivirus|Antivirus et Defender|sec.avproducts,sec.defenderdetails|sec.av,sec.defender,sec.realtime,sec.behavior,sec.signatures,sec.quickscan,sec.fullscan,sec.defenderversion,soft.defender
firewall|Pare-feu et profils réseau|sec.firewallprofiles,net.connectionprofiles|soft.firewall
protection|BitLocker, TPM et sécurité du démarrage|sec.bitlockervolumes,sec.tpmdetails,sec.deviceguard|sec.bitlocker,sec.tpmversion,sec.tpmenabled,sec.tpmactivated
processes|Processus au relevé|soft.processdetails|soft.processes
'@
    foreach ($line in ($text -split "`n")) {
        $cells = @($line.Trim().Split('|'))
        if ($cells.Count -ne 4) { continue }
        [pscustomobject]@{ Id = $cells[0]; Title = $cells[1]; Probes = @($cells[2].Split(',')); Related = @($cells[3].Split(',')) }
    }
}

function Get-DomeniaReadingForProbe {
    # The reading a probe belongs to, by its detailed probes first, then by the historical probes it replaces.
    param([string]$ProbeId)
    $catalog = @(Get-DomeniaReadingCatalog)
    foreach ($reading in $catalog) { if (@($reading.Probes) -ccontains $ProbeId) { return $reading } }
    foreach ($reading in $catalog) { if (@($reading.Related) -ccontains $ProbeId) { return $reading } }
    return $null
}

function ConvertTo-DomeniaReadingErrorState {
    # Read status of a failed probe from its error text: refused, provider absent, or failed for another reason.
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(?i)access is denied|acc[eè]s refus|refus|denied|0x80070005|unauthori') { return 'Refused' }
    if ($Text -match '(?i)invalid class|classe non valide|invalid namespace|espace de noms non valide|not found|introuvable|0x80041010|0x8004100e|not supported|non pris en charge') { return 'Absent' }
    return 'Failed'
}

function ConvertTo-DomeniaReadingSource {
    # One stored probe entry as a reading source: typed rows, completeness, date, history and read status.
    # $AttemptError: error of a later attempt; the values then come from the last success and the facts say so.
    param([string]$ProbeId,$Entry,[AllowEmptyString()][string]$AttemptError='')
    $rows = New-Object System.Collections.Generic.List[object]
    $state = 'NotRead'; $detail = ''
    if ($null -ne $Entry) {
        $failure = [string](Get-DomeniaMember $Entry 'Error' '')
        $skipped = [string](Get-DomeniaMember $Entry 'Skipped' '')
        if ($failure) { $state = ConvertTo-DomeniaReadingErrorState $failure; $detail = $failure }
        elseif ($skipped) { $state = 'Skipped'; $detail = $skipped }
        else {
            $state = 'Read'
            $instances = @(Get-DomeniaMember $Entry 'Instances' @())
            if ($instances.Count) {
                foreach ($instance in $instances) { $values = Get-DomeniaMemberValue $instance 'Values'; if ($null -ne $values) { $rows.Add($values) } }
            } else {
                # Older entries kept positional rows with their column names.
                $names = @(Get-DomeniaMember $Entry 'Properties' @())
                if ($names.Count) {
                    foreach ($row in @(Get-DomeniaMember $Entry 'Rows' @())) {
                        $cells = @($row); $map = [ordered]@{}
                        for ($column = 0; $column -lt $names.Count; $column++) { $map[[string]$names[$column]] = $(if ($column -lt $cells.Count) { $cells[$column] } else { $null }) }
                        $rows.Add([pscustomobject]$map)
                    }
                }
            }
        }
    }
    $complete = (($state -eq 'Read') -and (-not [bool](Get-DomeniaMember $Entry 'Truncated' $false)))
    return [pscustomobject]@{
        ProbeId = $ProbeId; State = $state; Detail = $detail; Rows = $rows.ToArray(); Complete = $complete
        CheckedUtc = (ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Entry 'CheckedUtc' $null))
        LimitReason = [string](Get-DomeniaMember $Entry 'LimitReason' ''); AttemptError = [string]$AttemptError
        History = @(Get-DomeniaMember $Entry 'History' @())
    }
}

function Get-DomeniaReadingNumber {
    # Invariant number of one provider value, $null when absent or not a number.
    param($Row,[string]$Name)
    return (ConvertTo-DomeniaProbeNumber (Get-DomeniaMemberValue $Row $Name))
}

function Get-DomeniaReadingText {
    param($Row,[string]$Name)
    $value = Get-DomeniaMemberValue $Row $Name
    if ($null -eq $value) { return '' }
    if ($value -is [array]) { return ((@($value) | ForEach-Object { [string]$_ }) -join ', ').Trim() }
    return ([string]$value).Trim()
}

function Get-DomeniaReadingBool {
    # $true, $false, or $null when the provider gave nothing readable.
    param($Row,[string]$Name)
    $value = Get-DomeniaMemberValue $Row $Name
    if ($value -is [bool]) { return $value }
    $text = ([string]$value).Trim()
    if ($text -match '^(?i:true|1)$') { return $true }
    if ($text -match '^(?i:false|0)$') { return $false }
    return $null
}

function Format-DomeniaReadingSize {
    # Binary units written the French way (Go, Mo), whatever the culture of the session.
    param([double]$Bytes)
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    if ($Bytes -ge 1TB) { return (($Bytes / 1TB).ToString('0.##',$fr) + ' To') }
    if ($Bytes -ge 1GB) { return (($Bytes / 1GB).ToString('0.#',$fr) + ' Go') }
    if ($Bytes -ge 1MB) { return (($Bytes / 1MB).ToString('0',$fr) + ' Mo') }
    return (($Bytes / 1KB).ToString('0',$fr) + ' Ko')
}

function Format-DomeniaReadingNumber {
    param([double]$Value,[string]$Format='0')
    return $Value.ToString($Format,[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))
}

function Format-DomeniaReadingDate {
    # Local date of a UTC instant, or '' when unknown.
    param($Utc,[string]$Format='dd/MM/yyyy')
    $date = ConvertTo-DomeniaUtcDate $Utc
    if ($null -eq $date) { return '' }
    return $date.ToLocalTime().ToString($Format,[Globalization.CultureInfo]::InvariantCulture)
}

function Get-DomeniaReadingCode {
    # Label of a provider code from 'code=label;code=label'; an unknown code keeps its number.
    param($Code,[string]$Table)
    if ($null -eq $Code) { return 'non renseigné' }
    $key = ([string]$Code).Trim()
    foreach ($pair in $Table.Split(';')) { $cells = $pair.Split('='); if (($cells.Count -eq 2) -and ($cells[0] -ceq $key)) { return $cells[1] } }
    return ('code ' + $key)
}

function Get-DomeniaReadingBoolText {
    # Word for a read boolean; '' when the provider gave nothing (an unknown flag is not written as false).
    param($Value,[string]$WhenTrue,[string]$WhenFalse)
    if ($Value -is [bool]) { if ($Value) { return $WhenTrue }; return $WhenFalse }
    return ''
}

function ConvertTo-DomeniaReadingCodes {
    # Labels of the numeric codes of an array property; elements that are not numbers are skipped.
    param($Values,[string]$Table)
    foreach ($item in @($Values)) {
        $number = ConvertTo-DomeniaProbeNumber $item
        if ($null -eq $number) { continue }
        Get-DomeniaReadingCode ([string][long]$number) $Table
    }
}

function Add-DomeniaReadingFact {
    param($Facts,[string]$Fait,[AllowEmptyString()][string]$Valeur='',[string]$Etat='Constate',[AllowEmptyString()][string]$Source='',[AllowEmptyString()][string]$Limite='',[AllowEmptyString()][string]$Hypothese='',$Date=$null)
    $Facts.Add((New-DomeniaFact -Fait $Fait -Valeur $Valeur -Etat $Etat -Source $Source -Limite $Limite -Hypothese $Hypothese -Date $Date))
}

function Add-DomeniaReadingSourceFact {
    # A source without usable values is said as such: not read, refused, provider absent, not applicable or failed.
    param($Facts,$Source,[string]$Fait,[string]$Class)
    $probe = [string]$Source.ProbeId
    switch ([string]$Source.State) {
        'NotRead' { Add-DomeniaReadingFact $Facts $Fait 'Non relevé' 'Inconnu' $Class ('Ajoutez la requête ' + $probe + ' au tableau du poste, puis actualisez les requêtes.') ; return }
        'Refused' { Add-DomeniaReadingFact $Facts $Fait 'Lecture refusée' 'Refuse' $Class 'Un refus ne dit rien de lʼétat du poste.' '' $Source.CheckedUtc; return }
        'Absent' { Add-DomeniaReadingFact $Facts $Fait 'Fournisseur absent sur ce poste' 'Indisponible' $Class 'Classe ou espace de noms indisponible : ni panne, ni bon état.' '' $Source.CheckedUtc; return }
        'Skipped' { Add-DomeniaReadingFact $Facts $Fait 'Non applicable à ce système' 'Inconnu' $Class (ConvertTo-DomeniaFlatText ([string]$Source.Detail) 160); return }
    }
    Add-DomeniaReadingFact $Facts $Fait ('Lecture impossible : ' + (ConvertTo-DomeniaFlatText ([string]$Source.Detail) 160)) 'Indisponible' $Class 'Aucune conclusion sur ce point.' '' $Source.CheckedUtc
}

function Get-DomeniaReadingPartialText {
    # Limitation added to every fact built from a partial source.
    param($Source)
    if ($Source.Complete) { return '' }
    $reason = [string]$Source.LimitReason
    if (-not $reason) { $reason = 'détails incomplets' }
    return ('Lecture partielle (' + $reason + ') : la liste peut être incomplète.')
}

function Join-DomeniaReadingText {
    # Joins the non-empty parts with a separator.
    param([string[]]$Parts,[string]$Separator=' · ')
    return ((@($Parts) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join $Separator)
}

# ---------------------------------------------------------------- point 81: memory capacity and use
function Get-DomeniaMemoryReading {
    # Hardware capacity (modules, slots, firmware maximum) and the instantaneous use are separate facts: the first
    # comes from the SMBIOS tables, the second is one dated measure that says nothing about the usual load.
    param($Modules,$Arrays,$Usage)
    $facts = New-Object System.Collections.Generic.List[object]
    $installed = $null
    $moduleCount = -1
    if ($Modules.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Modules 'Mémoire installée (barrettes)' 'Win32_PhysicalMemory' }
    elseif (-not @($Modules.Rows).Count) {
        Add-DomeniaReadingFact $facts 'Mémoire installée (barrettes)' 'Aucune barrette exposée par le firmware' 'Inconnu' 'Win32_PhysicalMemory' 'Fréquent en machine virtuelle : la capacité matérielle reste inconnue ; la mémoire visible par Windows est donnée à part.' '' $Modules.CheckedUtc
    } else {
        $total = 0.0; $unknown = 0; $slots = New-Object System.Collections.Generic.List[string]
        foreach ($module in @($Modules.Rows)) {
            $capacity = Get-DomeniaReadingNumber $module 'Capacity'
            if (($null -eq $capacity) -or ($capacity -le 0)) { $unknown++; continue }
            $total += $capacity
            $speed = Get-DomeniaReadingNumber $module 'ConfiguredClockSpeed'
            $slots.Add((Join-DomeniaReadingText @((Get-DomeniaReadingText $module 'DeviceLocator'),(Format-DomeniaReadingSize $capacity),$(if (($null -ne $speed) -and ($speed -gt 0)) { (Format-DomeniaReadingNumber $speed) + ' MHz' } else { '' })) ' '))
        }
        $moduleCount = @($Modules.Rows).Count
        $partial = Get-DomeniaReadingPartialText $Modules
        if ($unknown -or $partial) {
            $text = 'Au moins ' + (Format-DomeniaReadingSize $total) + ' (' + [string]$moduleCount + ' barrette(s) lue(s), ' + [string]$unknown + ' sans capacité déclarée)'
            Add-DomeniaReadingFact $facts 'Mémoire installée (barrettes)' $text 'Estime' 'Win32_PhysicalMemory' (Join-DomeniaReadingText @('Total minimal : une barrette sans capacité ou une lecture partielle nʼest pas comptée.',$partial) ' ') '' $Modules.CheckedUtc
        } else {
            $installed = $total
            Add-DomeniaReadingFact $facts 'Mémoire installée (barrettes)' ((Format-DomeniaReadingSize $total) + ' en ' + [string]$moduleCount + ' barrette(s) : ' + ($slots.ToArray() -join ' ; ')) 'Constate' 'Win32_PhysicalMemory' 'Capacité déclarée par le firmware (SMBIOS).' '' $Modules.CheckedUtc
        }
    }
    # Only system memory arrays (Use 3) hold RAM slots; a video, flash or NVRAM array is left out. An older reading
    # without the Use column keeps every array.
    $systemArrays = @()
    if ($Arrays.State -eq 'Read') { $systemArrays = @(@($Arrays.Rows) | Where-Object { $use = Get-DomeniaReadingNumber $_ 'Use'; ($null -eq $use) -or ($use -eq 3) }) }
    if ($Arrays.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Arrays 'Emplacements et capacité maximale' 'Win32_PhysicalMemoryArray' }
    elseif (-not @($Arrays.Rows).Count) { Add-DomeniaReadingFact $facts 'Emplacements et capacité maximale' 'Aucune table mémoire exposée' 'Inconnu' 'Win32_PhysicalMemoryArray' 'Firmware incomplet ou machine virtuelle : aucun emplacement libre nʼest déduit.' '' $Arrays.CheckedUtc }
    elseif (-not $systemArrays.Count) { Add-DomeniaReadingFact $facts 'Emplacements et capacité maximale' ('Aucun groupe de mémoire système déclaré (' + [string]@($Arrays.Rows).Count + ' groupe(s) dʼun autre usage)') 'Inconnu' 'Win32_PhysicalMemoryArray' 'Groupes vidéo, flash ou NVRAM seulement : aucun emplacement libre nʼest déduit.' '' $Arrays.CheckedUtc }
    else {
        $slotTotal = 0; $slotKnown = $true; $maximum = 0.0; $maximumKnown = $true
        foreach ($array in $systemArrays) {
            $devices = Get-DomeniaReadingNumber $array 'MemoryDevices'
            if (($null -eq $devices) -or ($devices -le 0)) { $slotKnown = $false } else { $slotTotal += [int]$devices }
            $kilobytes = Get-DomeniaReadingNumber $array 'MaxCapacityEx'
            if (($null -eq $kilobytes) -or ($kilobytes -le 0)) { $maximumKnown = $false } else { $maximum += $kilobytes * 1KB }
        }
        $slotLimit = 'Table SMBIOS du firmware ; une mémoire soudée compte comme un emplacement occupé.'
        if (-not $slotKnown) { Add-DomeniaReadingFact $facts 'Emplacements mémoire' 'Nombre dʼemplacements non déclaré' 'Inconnu' 'Win32_PhysicalMemoryArray' $slotLimit '' $Arrays.CheckedUtc }
        elseif (($moduleCount -lt 0) -or (-not $Modules.Complete)) { Add-DomeniaReadingFact $facts 'Emplacements mémoire' ([string]$slotTotal + ' emplacement(s) déclaré(s), occupation non lue') 'Constate' 'Win32_PhysicalMemoryArray' $slotLimit '' $Arrays.CheckedUtc }
        elseif ($moduleCount -gt $slotTotal) { Add-DomeniaReadingFact $facts 'Emplacements mémoire' ([string]$moduleCount + ' barrette(s) pour ' + [string]$slotTotal + ' emplacement(s) déclaré(s)') 'Inconnu' 'Win32_PhysicalMemoryArray' 'Tables du firmware incohérentes : aucun emplacement libre nʼest déduit.' '' $Arrays.CheckedUtc }
        else {
            $free = $slotTotal - $moduleCount
            Add-DomeniaReadingFact $facts 'Emplacements mémoire' ([string]$slotTotal + ' emplacement(s) : ' + [string]$moduleCount + ' occupé(s), ' + [string]$free + ' libre(s)') 'Constate' 'Win32_PhysicalMemoryArray, Win32_PhysicalMemory' $slotLimit '' $Arrays.CheckedUtc
        }
        if ($maximumKnown) { Add-DomeniaReadingFact $facts 'Capacité maximale déclarée' (Format-DomeniaReadingSize $maximum) 'Constate' 'Win32_PhysicalMemoryArray' 'Déclaration du firmware : ce nʼest pas une garantie de compatibilité avec une barrette donnée.' '' $Arrays.CheckedUtc }
        else { Add-DomeniaReadingFact $facts 'Capacité maximale déclarée' 'Non déclarée par le firmware' 'Inconnu' 'Win32_PhysicalMemoryArray' '' '' $Arrays.CheckedUtc }
    }
    if ($Usage.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Usage 'Mémoire visible et utilisation' 'Win32_OperatingSystem' }
    elseif (-not @($Usage.Rows).Count) { Add-DomeniaReadingFact $facts 'Mémoire visible et utilisation' 'Aucune valeur renvoyée' 'Inconnu' 'Win32_OperatingSystem' '' '' $Usage.CheckedUtc }
    else {
        $row = @($Usage.Rows)[0]
        $visible = Get-DomeniaReadingNumber $row 'TotalVisibleMemorySize'
        $freeKb = Get-DomeniaReadingNumber $row 'FreePhysicalMemory'
        if (($null -eq $visible) -or ($visible -le 0)) { Add-DomeniaReadingFact $facts 'Mémoire visible par Windows' 'Non renvoyée' 'Inconnu' 'Win32_OperatingSystem' '' '' $Usage.CheckedUtc }
        else {
            $reserved = ''
            if (($null -ne $installed) -and ($installed -gt ($visible * 1KB))) { $reserved = (Format-DomeniaReadingSize ($installed - $visible * 1KB)) + ' réservés au matériel ou au firmware' }
            Add-DomeniaReadingFact $facts 'Mémoire visible par Windows' (Format-DomeniaReadingSize ($visible * 1KB)) 'Constate' 'Win32_OperatingSystem' 'Part de la mémoire installée que Windows peut utiliser.' $reserved $Usage.CheckedUtc
            if (($null -eq $freeKb) -or ($freeKb -lt 0) -or ($freeKb -gt $visible)) { Add-DomeniaReadingFact $facts 'Mémoire utilisée au relevé' 'Mémoire libre absente ou incohérente' 'Inconnu' 'Win32_OperatingSystem' '' '' $Usage.CheckedUtc }
            else {
                $percent = 100.0 * ($visible - $freeKb) / $visible
                $value = (Format-DomeniaReadingNumber $percent) + ' % (' + (Format-DomeniaReadingSize (($visible - $freeKb) * 1KB)) + ' sur ' + (Format-DomeniaReadingSize ($visible * 1KB)) + ')'
                $hint = if ($percent -ge 90) { 'Pression mémoire au moment du relevé : à confirmer par plusieurs relevés avant de conclure.' } else { '' }
                Add-DomeniaReadingFact $facts 'Mémoire utilisée au relevé' $value 'Constate' 'Win32_OperatingSystem' 'Mesure instantanée datée : elle ne décrit pas lʼusage habituel du poste.' $hint $Usage.CheckedUtc
            }
        }
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 82: volumes and saturation forecast
function Get-DomeniaVolumeSaturationForecast {
    # Linear trend of the free space of one volume over its stored samples ({AtUtc;Size;Free}). No figure without
    # enough history: MinSamples samples spread over MinSpanDays days, one constant size, a falling trend and a fit
    # (coefficient of determination) at least MinFit. The date is the last free space divided by the average fall.
    param([object[]]$Samples=@(),[int]$MinSamples=4,[int]$MinSpanDays=14,[double]$MinFit=0.6,[int]$HorizonDays=730)
    $points = New-Object System.Collections.Generic.List[object]
    foreach ($sample in @($Samples)) {
        if ($null -eq $sample) { continue }
        $at = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $sample 'AtUtc' $null)
        $size = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $sample 'Size' $null)
        $free = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $sample 'Free' $null)
        if (($null -eq $at) -or ($null -eq $size) -or ($null -eq $free) -or ($size -le 0) -or ($free -lt 0) -or ($free -gt $size)) { continue }
        $points.Add([pscustomobject]@{ At = $at; Size = [double]$size; Free = [double]$free })
    }
    $sorted = @($points.ToArray() | Sort-Object { $_.At.Ticks })
    $result = [ordered]@{ Status = 'Insufficient'; Count = $sorted.Count; SpanDays = 0.0; FirstUtc = $null; LastUtc = $null; SlopeBytesPerDay = $null; Fit = $null; DaysLeft = $null; SaturationUtc = $null; LastFree = $null }
    if ($sorted.Count) { $result.FirstUtc = $sorted[0].At; $result.LastUtc = $sorted[$sorted.Count - 1].At; $result.SpanDays = ($result.LastUtc - $result.FirstUtc).TotalDays; $result.LastFree = $sorted[$sorted.Count - 1].Free }
    if (($sorted.Count -lt $MinSamples) -or ($result.SpanDays -lt $MinSpanDays)) { return [pscustomobject]$result }
    $sizes = @($sorted | ForEach-Object { [Math]::Round($_.Size / 1MB) } | Select-Object -Unique)
    if ($sizes.Count -gt 1) { $result.Status = 'SizeChanged'; return [pscustomobject]$result }
    $n = [double]$sorted.Count; $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0; $syy = 0.0
    foreach ($point in $sorted) {
        $x = ($point.At - $result.FirstUtc).TotalDays; $y = $point.Free
        $sx += $x; $sy += $y; $sxx += $x * $x; $sxy += $x * $y; $syy += $y * $y
    }
    $denominator = $n * $sxx - $sx * $sx
    if ($denominator -le 0) { return [pscustomobject]$result }
    $covariance = $n * $sxy - $sx * $sy
    $slope = $covariance / $denominator
    $result.SlopeBytesPerDay = $slope
    $variance = $n * $syy - $sy * $sy
    # A fall of less than 1 Mo per day is no trend at all.
    if (($slope -ge (-1.0 * 1MB)) -or ($variance -le 0)) { $result.Status = 'Stable'; return [pscustomobject]$result }
    $fit = ($covariance * $covariance) / ($denominator * $variance)
    $result.Fit = $fit
    if ($fit -lt $MinFit) { $result.Status = 'Irregular'; return [pscustomobject]$result }
    $daysLeft = $result.LastFree / (-1.0 * $slope)
    $result.DaysLeft = $daysLeft
    if ($daysLeft -gt $HorizonDays) { $result.Status = 'BeyondHorizon'; return [pscustomobject]$result }
    $result.Status = 'Forecast'
    $result.SaturationUtc = $result.LastUtc.AddDays($daysLeft)
    return [pscustomobject]$result
}

function Get-DomeniaVolumeReading {
    # Free space of each fixed volume at the reading, then a forecast only from the stored history of that volume.
    param($Volumes,[int]$WarnPercent=20,[int]$AlertPercent=10)
    $facts = New-Object System.Collections.Generic.List[object]
    if ($Volumes.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Volumes 'Volumes locaux' 'Win32_LogicalDisk'; return $facts.ToArray() }
    if (-not @($Volumes.Rows).Count) { Add-DomeniaReadingFact $facts 'Volumes locaux' 'Aucun volume fixe renvoyé' 'Inconnu' 'Win32_LogicalDisk' (Get-DomeniaReadingPartialText $Volumes) '' $Volumes.CheckedUtc; return $facts.ToArray() }
    $partial = Get-DomeniaReadingPartialText $Volumes
    foreach ($volume in @($Volumes.Rows)) {
        $id = (Get-DomeniaReadingText $volume 'DeviceID').ToUpperInvariant()
        $label = Get-DomeniaReadingText $volume 'VolumeName'
        $system = Get-DomeniaReadingText $volume 'FileSystem'
        $name = 'Volume ' + $id + $(if ($label) { ' (' + $label + ')' } else { '' })
        $size = Get-DomeniaReadingNumber $volume 'Size'
        $free = Get-DomeniaReadingNumber $volume 'FreeSpace'
        if (($null -eq $size) -or ($null -eq $free) -or ($size -le 0) -or ($free -lt 0) -or ($free -gt $size)) {
            Add-DomeniaReadingFact $facts $name 'Taille ou espace libre absent ou incohérent' 'Inconnu' 'Win32_LogicalDisk' $partial '' $Volumes.CheckedUtc
            continue
        }
        $percent = 100.0 * $free / $size
        $hint = if ($percent -lt $AlertPercent) { 'Espace critique : les mises à jour et les profils peuvent échouer.' } elseif ($percent -lt $WarnPercent) { 'Espace faible : à surveiller.' } else { '' }
        $value = (Format-DomeniaReadingSize $free) + ' libres sur ' + (Format-DomeniaReadingSize $size) + ' (' + (Format-DomeniaReadingNumber $percent) + ' %)' + $(if ($system) { ' · ' + $system } else { '' })
        Add-DomeniaReadingFact $facts $name $value 'Constate' 'Win32_LogicalDisk' (Join-DomeniaReadingText @('Espace libre au relevé.',$partial) ' ') $hint $Volumes.CheckedUtc
        # History samples of this volume, plus the current reading when it is newer than the last stored sample.
        $samples = New-Object System.Collections.Generic.List[object]
        foreach ($stored in @($Volumes.History)) {
            $at = Get-DomeniaMember $stored 'AtUtc' $null
            foreach ($item in @(Get-DomeniaMember $stored 'Items' @())) {
                if (([string](Get-DomeniaMember $item 'Id' '')).ToUpperInvariant() -ceq $id) { $samples.Add([pscustomobject]@{ AtUtc = $at; Size = (Get-DomeniaMember $item 'Size' $null); Free = (Get-DomeniaMember $item 'Free' $null) }) }
            }
        }
        $current = $Volumes.CheckedUtc
        $newest = $null
        foreach ($sample in $samples) { $at = ConvertTo-DomeniaUtcDate $sample.AtUtc; if (($null -ne $at) -and (($null -eq $newest) -or ($at -gt $newest))) { $newest = $at } }
        if (($null -ne $current) -and (($null -eq $newest) -or ($current -gt $newest))) { $samples.Add([pscustomobject]@{ AtUtc = $current; Size = $size; Free = $free }) }
        $forecast = Get-DomeniaVolumeSaturationForecast -Samples $samples.ToArray()
        $title = 'Prévision de saturation de ' + $id
        $span = Format-DomeniaReadingNumber ([Math]::Floor([double]$forecast.SpanDays))
        $basis = 'Relevés enregistrés de ce poste uniquement (au plus un toutes les 6 h).'
        switch ([string]$forecast.Status) {
            'Insufficient' { Add-DomeniaReadingFact $facts $title ('Aucune prévision : ' + [string]$forecast.Count + ' relevé(s) sur ' + $span + ' jour(s) ; il en faut au moins 4 sur 14 jours.') 'Inconnu' 'Historique des relevés' $basis }
            'SizeChanged' { Add-DomeniaReadingFact $facts $title 'Aucune prévision : la taille du volume a changé pendant la période.' 'Inconnu' 'Historique des relevés' $basis }
            'Stable' { Add-DomeniaReadingFact $facts $title ('Pas de baisse de lʼespace libre sur ' + [string]$forecast.Count + ' relevés (' + $span + ' jours).') 'Estime' 'Historique des relevés' $basis }
            'Irregular' { Add-DomeniaReadingFact $facts $title ('Aucune prévision : évolution irrégulière sur ' + [string]$forecast.Count + ' relevés (ajustement ' + (Format-DomeniaReadingNumber ([double]$forecast.Fit) '0.00') + ').') 'Inconnu' 'Historique des relevés' $basis }
            'BeyondHorizon' { Add-DomeniaReadingFact $facts $title ('Baisse lente : au rythme observé, pas de saturation avant deux ans (' + [string]$forecast.Count + ' relevés sur ' + $span + ' jours).') 'Estime' 'Historique des relevés' 'Projection linéaire : une installation ou un nettoyage change la tendance.' }
            'Forecast' {
                $rate = Format-DomeniaReadingSize (-1.0 * [double]$forecast.SlopeBytesPerDay)
                $value = 'Saturation estimée vers le ' + (Format-DomeniaReadingDate $forecast.SaturationUtc) + ' (baisse moyenne de ' + $rate + ' par jour sur ' + [string]$forecast.Count + ' relevés, du ' + (Format-DomeniaReadingDate $forecast.FirstUtc) + ' au ' + (Format-DomeniaReadingDate $forecast.LastUtc) + ')'
                $hint = if ([double]$forecast.DaysLeft -lt 30) { 'Saturation possible dans moins de 30 jours : libérer de lʼespace ou agrandir le volume.' } else { '' }
                Add-DomeniaReadingFact $facts $title $value 'Estime' 'Historique des relevés' 'Projection linéaire : une installation ou un nettoyage change la tendance.' $hint
            }
        }
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 83: storage health
function Get-DomeniaStorageHealthReading {
    # Health and counters as reported by the storage drivers. "Unknown", a virtual disk or a missing counter is
    # never presented as a healthy disk; no remaining life is computed from an absent value.
    param($Physical,$Reliability)
    $facts = New-Object System.Collections.Generic.List[object]
    if ($Physical.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Physical 'Disques physiques' 'MSFT_PhysicalDisk'; return $facts.ToArray() }
    if (-not @($Physical.Rows).Count) { Add-DomeniaReadingFact $facts 'Disques physiques' 'Aucun disque renvoyé par le fournisseur de stockage' 'Inconnu' 'MSFT_PhysicalDisk' 'Aucun disque nʼest déclaré sain ou défaillant sans lecture.' '' $Physical.CheckedUtc; return $facts.ToArray() }
    $media = '0=type non précisé;3=disque dur;4=SSD;5=mémoire de classe stockage'
    $bus = '1=SCSI;2=ATAPI;3=ATA;4=IEEE 1394;5=SSA;6=Fibre Channel;7=USB;8=RAID;9=iSCSI;10=SAS;11=SATA;12=SD;13=MMC;14=virtuel;15=fichier virtuel;16=espaces de stockage;17=NVMe'
    $operational = '0=inconnu;1=autre;2=OK;3=dégradé;4=sous contrainte;5=défaillance prévue;6=erreur;7=erreur non récupérable;8=démarrage;9=arrêt en cours;10=arrêté;11=en service;12=sans contact;13=communication perdue;14=interrompu;15=en veille;16=élément associé en erreur;17=terminé;18=mode dʼalimentation'
    $counters = @{}
    if ($Reliability.State -eq 'Read') { foreach ($row in @($Reliability.Rows)) { $key = Get-DomeniaReadingText $row 'DeviceId'; if ($key) { $counters[$key] = $row } } }
    $partial = Get-DomeniaReadingPartialText $Physical
    foreach ($disk in @($Physical.Rows)) {
        $name = Get-DomeniaReadingText $disk 'FriendlyName'
        $id = Get-DomeniaReadingText $disk 'DeviceId'
        if (-not $name) { $name = 'Disque ' + $id }
        $health = Get-DomeniaReadingNumber $disk 'HealthStatus'
        $busCode = Get-DomeniaReadingNumber $disk 'BusType'
        $size = Get-DomeniaReadingNumber $disk 'Size'
        $states = @(@(Get-DomeniaMemberValue $disk 'OperationalStatus') | Where-Object { $null -ne $_ } | ForEach-Object { Get-DomeniaReadingCode $_ $operational })
        $describe = Join-DomeniaReadingText @((Get-DomeniaReadingCode (Get-DomeniaReadingNumber $disk 'MediaType') $media),$(if ($null -ne $busCode) { 'bus ' + (Get-DomeniaReadingCode $busCode $bus) } else { '' }),$(if (($null -ne $size) -and ($size -gt 0)) { Format-DomeniaReadingSize $size } else { '' }),$(if ($states.Count) { 'état opérationnel : ' + ($states -join ', ') } else { '' }))
        $limit = 'État rapporté par le pilote de stockage.'
        if (($busCode -eq 14) -or ($busCode -eq 15)) { $limit = 'Disque virtuel : la santé du support physique nʼest pas visible depuis ce système.' }
        elseif (($busCode -eq 8) -or ($busCode -eq 16)) { $limit = 'Volume RAID ou espace de stockage : la santé des disques membres nʼest pas détaillée ici.' }
        $limit = Join-DomeniaReadingText @($limit,$partial) ' '
        if ($health -eq 0) { Add-DomeniaReadingFact $facts $name ('Sain selon le pilote · ' + $describe) 'Constate' 'MSFT_PhysicalDisk' $limit '' $Physical.CheckedUtc }
        elseif ($health -eq 1) { Add-DomeniaReadingFact $facts $name ('Avertissement · ' + $describe) 'Constate' 'MSFT_PhysicalDisk' $limit 'Le pilote signale un problème : sauvegarder puis vérifier le disque.' $Physical.CheckedUtc }
        elseif ($health -eq 2) { Add-DomeniaReadingFact $facts $name ('Défaillant · ' + $describe) 'Constate' 'MSFT_PhysicalDisk' $limit 'Disque déclaré défaillant : sauvegarder les données et prévoir son remplacement.' $Physical.CheckedUtc }
        else { Add-DomeniaReadingFact $facts $name ('État de santé inconnu (' + (Get-DomeniaReadingCode $health '') + ') · ' + $describe) 'Inconnu' 'MSFT_PhysicalDisk' (Join-DomeniaReadingText @($limit,'Un état inconnu nʼest pas un disque sain.') ' ') '' $Physical.CheckedUtc }
        $counterTitle = 'Compteurs de fiabilité de ' + $name
        if ($Reliability.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Reliability $counterTitle 'MSFT_StorageReliabilityCounter'; continue }
        if (-not $counters.ContainsKey($id)) { Add-DomeniaReadingFact $facts $counterTitle 'Aucun compteur exposé pour ce disque' 'Inconnu' 'MSFT_StorageReliabilityCounter' 'Pilote ou contrôleur sans compteurs SMART exploitables : aucune conclusion.' '' $Reliability.CheckedUtc; continue }
        $row = $counters[$id]
        $parts = New-Object System.Collections.Generic.List[string]; $hints = New-Object System.Collections.Generic.List[string]
        $wear = Get-DomeniaReadingNumber $row 'Wear'; $temperature = Get-DomeniaReadingNumber $row 'Temperature'; $hours = Get-DomeniaReadingNumber $row 'PowerOnHours'
        $readErrors = Get-DomeniaReadingNumber $row 'ReadErrorsUncorrected'; $writeErrors = Get-DomeniaReadingNumber $row 'WriteErrorsUncorrected'
        $parts.Add($(if ($null -ne $wear) { 'usure ' + (Format-DomeniaReadingNumber $wear) + ' %' } else { 'usure non exposée' }))
        $parts.Add($(if (($null -ne $temperature) -and ($temperature -gt 0)) { (Format-DomeniaReadingNumber $temperature) + ' °C' } else { 'température non exposée' }))
        $parts.Add($(if ($null -ne $hours) { (Format-DomeniaReadingNumber $hours) + ' h de fonctionnement' } else { 'durée de fonctionnement non exposée' }))
        if (($null -ne $readErrors) -or ($null -ne $writeErrors)) {
            $uncorrected = 0.0; if ($null -ne $readErrors) { $uncorrected += $readErrors }; if ($null -ne $writeErrors) { $uncorrected += $writeErrors }
            $parts.Add((Format-DomeniaReadingNumber $uncorrected) + ' erreur(s) non corrigée(s)')
            if ($uncorrected -gt 0) { $hints.Add('Erreurs non corrigées signalées : sauvegarder et vérifier le disque.') }
        } else { $parts.Add('erreurs non corrigées non exposées') }
        if (($null -ne $wear) -and ($wear -ge 90)) { $hints.Add('Usure déclarée élevée : prévoir le remplacement.') }
        Add-DomeniaReadingFact $facts $counterTitle ($parts.ToArray() -join ' · ') 'Constate' 'MSFT_StorageReliabilityCounter' 'Valeurs du pilote ; une valeur non exposée reste inconnue.' ($hints.ToArray() -join ' ') $Reliability.CheckedUtc
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 84: laptop batteries
function Get-DomeniaBatteryReading {
    # Charge and status from Win32_Battery; nominal capacity, full charge capacity and cycles from the battery driver
    # (root\wmi), joined by instance name. Wear is an estimate computed only from two valid capacities.
    param($Batteries,$Static,$FullCharge,$Cycles)
    $facts = New-Object System.Collections.Generic.List[object]
    $status = '1=sur batterie;2=sur secteur;3=chargée;4=faible;5=critique;6=en charge;7=en charge (haute);8=en charge (faible);9=en charge (critique);10=non défini;11=partiellement chargée'
    if ($Batteries.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Batteries 'Batteries' 'Win32_Battery' }
    elseif (-not @($Batteries.Rows).Count) {
        if ($Batteries.Complete) { Add-DomeniaReadingFact $facts 'Batteries' 'Aucune batterie déclarée' 'Constate' 'Win32_Battery' 'Poste fixe, ou batterie non exposée par le firmware.' '' $Batteries.CheckedUtc }
        else { Add-DomeniaReadingFact $facts 'Batteries' 'Aucune batterie dans une lecture partielle' 'Inconnu' 'Win32_Battery' (Get-DomeniaReadingPartialText $Batteries) '' $Batteries.CheckedUtc }
        return $facts.ToArray()
    } else {
        foreach ($battery in @($Batteries.Rows)) {
            $name = Get-DomeniaReadingText $battery 'Name'; if (-not $name) { $name = Get-DomeniaReadingText $battery 'DeviceID' }
            $charge = Get-DomeniaReadingNumber $battery 'EstimatedChargeRemaining'
            $value = Join-DomeniaReadingText @($(if ($null -ne $charge) { 'charge ' + (Format-DomeniaReadingNumber $charge) + ' %' } else { 'charge non renseignée' }),(Get-DomeniaReadingCode (Get-DomeniaReadingNumber $battery 'BatteryStatus') $status))
            Add-DomeniaReadingFact $facts ('Batterie ' + $name) $value 'Constate' 'Win32_Battery' 'Valeurs au relevé ; la charge change en continu.' '' $Batteries.CheckedUtc
        }
    }
    $instances = New-Object System.Collections.Generic.List[string]
    $designed = @{}; $full = @{}; $cycles = @{}; $labels = @{}
    foreach ($pair in @(@($Static,'DesignedCapacity',$designed,$true),@($FullCharge,'FullChargedCapacity',$full,$false),@($Cycles,'CycleCount',$cycles,$false))) {
        $source = $pair[0]; $table = $pair[2]
        if ($source.State -ne 'Read') { continue }
        foreach ($row in @($source.Rows)) {
            $instance = Get-DomeniaReadingText $row 'InstanceName'
            if (-not $instance) { continue }
            if (-not $instances.Contains($instance)) { $instances.Add($instance) }
            $table[$instance] = Get-DomeniaReadingNumber $row ([string]$pair[1])
            if ([bool]$pair[3]) { $labels[$instance] = Join-DomeniaReadingText @((Get-DomeniaReadingText $row 'DeviceName'),(Get-DomeniaReadingText $row 'ManufactureName')) ' ' }
        }
    }
    foreach ($pair in @(@($Static,'Capacité nominale','BatteryStaticData'),@($FullCharge,'Capacité à pleine charge','BatteryFullChargedCapacity'),@($Cycles,'Cycles de charge','BatteryCycleCount'))) {
        if ($pair[0].State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $pair[0] ([string]$pair[1] + ' (pilote de batterie)') ([string]$pair[2]) }
    }
    $wearLimit = 'Usure estimée = 1 − capacité à pleine charge / capacité nominale ; la calibration de la batterie fait varier ce calcul.'
    foreach ($instance in $instances) {
        $label = [string]$labels[$instance]; if (-not $label) { $label = $instance }
        $design = $designed[$instance]; $fullValue = $full[$instance]
        $title = 'Usure de la batterie ' + $label
        if (($null -ne $design) -and ($null -ne $fullValue) -and ($design -gt 0) -and ($fullValue -gt 0)) {
            if ($fullValue -gt ($design * 1.05)) { Add-DomeniaReadingFact $facts $title ('Capacité à pleine charge (' + (Format-DomeniaReadingNumber $fullValue) + ' mWh) supérieure à la nominale (' + (Format-DomeniaReadingNumber $design) + ' mWh) : usure non calculable') 'Inconnu' 'root\wmi' 'Valeur de calibration ou unités différentes : aucune usure nʼest déduite.' '' $FullCharge.CheckedUtc }
            else {
                $wear = [Math]::Max(0.0, 100.0 * (1.0 - $fullValue / $design))
                $hint = if ($wear -ge 40) { 'Autonomie fortement réduite : remplacement de la batterie à envisager.' } else { '' }
                Add-DomeniaReadingFact $facts $title ((Format-DomeniaReadingNumber $wear) + ' % (' + (Format-DomeniaReadingNumber $fullValue) + ' mWh à pleine charge sur ' + (Format-DomeniaReadingNumber $design) + ' mWh nominaux)') 'Estime' 'BatteryStaticData, BatteryFullChargedCapacity' $wearLimit $hint $FullCharge.CheckedUtc
            }
        } else { Add-DomeniaReadingFact $facts $title 'Usure non calculable : capacité nominale ou à pleine charge non exposée' 'Inconnu' 'root\wmi' 'Aucune usure nʼest calculée à partir dʼune valeur absente ou nulle.' }
        $count = $cycles[$instance]
        if (($null -ne $count) -and ($count -gt 0)) { Add-DomeniaReadingFact $facts ('Cycles de la batterie ' + $label) ((Format-DomeniaReadingNumber $count) + ' cycles') 'Constate' 'BatteryCycleCount' 'Compteur déclaré par la batterie.' '' $Cycles.CheckedUtc }
        elseif ($Cycles.State -eq 'Read') { Add-DomeniaReadingFact $facts ('Cycles de la batterie ' + $label) 'Compteur non renseigné par la batterie' 'Inconnu' 'BatteryCycleCount' 'Zéro ou absence ne signifie pas une batterie neuve.' '' $Cycles.CheckedUtc }
    }
    if ((-not $instances.Count) -and ($Batteries.State -eq 'Read')) {
        # Without the driver classes, Win32_Battery capacities are used when both are exposed (zero means not exposed).
        foreach ($battery in @($Batteries.Rows)) {
            $design = Get-DomeniaReadingNumber $battery 'DesignCapacity'; $fullValue = Get-DomeniaReadingNumber $battery 'FullChargeCapacity'
            $name = Get-DomeniaReadingText $battery 'Name'
            if (($null -ne $design) -and ($null -ne $fullValue) -and ($design -gt 0) -and ($fullValue -gt 0) -and ($fullValue -le ($design * 1.05))) {
                $wear = [Math]::Max(0.0, 100.0 * (1.0 - $fullValue / $design))
                Add-DomeniaReadingFact $facts ('Usure de la batterie ' + $name) ((Format-DomeniaReadingNumber $wear) + ' %') 'Estime' 'Win32_Battery' $wearLimit '' $Batteries.CheckedUtc
            } else { Add-DomeniaReadingFact $facts ('Usure de la batterie ' + $name) 'Usure non calculable : capacités non exposées par Win32_Battery' 'Inconnu' 'Win32_Battery' 'Zéro signifie « non exposé » pour ces capacités.' '' $Batteries.CheckedUtc }
        }
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 85: BIOS and approved references
function Compare-DomeniaBiosVersion {
    # Equal, Older, Newer, Different (formats that cannot be ordered) or Unknown. Two versions are ordered only when
    # they share the same skeleton once their digit runs are masked ('N1CET#W (#.# )', '#.#.#', 'A#'): then their
    # numbers are compared in order. No vendor format is guessed beyond that.
    param([AllowEmptyString()][string]$Observed,[AllowEmptyString()][string]$Reference)
    $left = (([string]$Observed) -replace '\s+',' ').Trim()
    $right = (([string]$Reference) -replace '\s+',' ').Trim()
    if ((-not $left) -or (-not $right)) { return 'Unknown' }
    if ([string]::Equals($left,$right,[StringComparison]::OrdinalIgnoreCase)) { return 'Equal' }
    if (-not [string]::Equals(($left -replace '\d+','#'),($right -replace '\d+','#'),[StringComparison]::OrdinalIgnoreCase)) { return 'Different' }
    $a = @([regex]::Matches($left,'\d+') | ForEach-Object { $_.Value })
    $b = @([regex]::Matches($right,'\d+') | ForEach-Object { $_.Value })
    for ($i = 0; $i -lt $a.Count; $i++) {
        if (($a[$i].Length -gt 9) -or ($b[$i].Length -gt 9)) { return 'Different' }
        $x = [long]$a[$i]; $y = [long]$b[$i]
        if ($x -lt $y) { return 'Older' }
        if ($x -gt $y) { return 'Newer' }
    }
    # Same numbers written differently ('1.05' and '1.5'): not ordered.
    return 'Different'
}

function ConvertTo-DomeniaBiosReferenceBook {
    # Approved BIOS versions per maker and model, kept as a local setting of one domain. Invalid entries are dropped;
    # -Strict refuses them instead. At most 500 models, short single-line texts only.
    param($Value,[switch]$Strict)
    if ($Value -is [string]) {
        if (-not $Value.Trim()) { $Value = $null }
        else { try { $Value = $Value | ConvertFrom-Json -ErrorAction Stop } catch { if ($Strict) { throw 'Références BIOS illisibles.' }; $Value = $null } }
    }
    $references = New-Object System.Collections.Generic.List[object]; $seen = @{}
    foreach ($item in @(Get-DomeniaMember $Value 'References' @())) {
        $maker = ([string](Get-DomeniaMember $item 'Manufacturer' '')).Trim()
        $model = ([string](Get-DomeniaMember $item 'Model' '')).Trim()
        $version = ([string](Get-DomeniaMember $item 'Version' '')).Trim()
        $approved = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $item 'ApprovedUtc' $null)
        $key = ($maker + '|' + $model).ToLowerInvariant()
        $valid = ($model.Length -ge 1) -and ($model.Length -le 128) -and ($maker.Length -le 128) -and ($version.Length -ge 1) -and ($version.Length -le 128) -and (($maker + $model + $version) -notmatch '[\p{Cc}]') -and ($null -ne $approved) -and (-not $seen.ContainsKey($key)) -and ($references.Count -lt 500)
        if (-not $valid) { if ($Strict) { throw 'Référence BIOS invalide (modèle et version de 1 à 128 caractères, 500 modèles au plus).' }; continue }
        $seen[$key] = $true
        $references.Add([pscustomobject]@{ Manufacturer = $maker; Model = $model; Version = $version; ApprovedUtc = $approved.ToString('o') })
    }
    return [pscustomobject]@{ Version = 1; References = $references.ToArray() }
}

function Get-DomeniaBiosReference {
    param($Book,[AllowEmptyString()][string]$Manufacturer,[AllowEmptyString()][string]$Model)
    $key = (([string]$Manufacturer).Trim() + '|' + ([string]$Model).Trim()).ToLowerInvariant()
    foreach ($item in @(Get-DomeniaMember $Book 'References' @())) { if ((([string]$item.Manufacturer) + '|' + ([string]$item.Model)).ToLowerInvariant() -ceq $key) { return $item } }
    return $null
}

function Set-DomeniaBiosReference {
    # New book where the maker and model approve this version (replacing a previous approval of the same model).
    param($Book,[AllowEmptyString()][string]$Manufacturer,[string]$Model,[string]$Version,[datetime]$NowUtc)
    $items = New-Object System.Collections.Generic.List[object]
    $key = (([string]$Manufacturer).Trim() + '|' + ([string]$Model).Trim()).ToLowerInvariant()
    foreach ($item in @(Get-DomeniaMember $Book 'References' @())) { if ((([string]$item.Manufacturer) + '|' + ([string]$item.Model)).ToLowerInvariant() -cne $key) { $items.Add($item) } }
    $items.Add([pscustomobject]@{ Manufacturer = ([string]$Manufacturer).Trim(); Model = ([string]$Model).Trim(); Version = ([string]$Version).Trim(); ApprovedUtc = $NowUtc.ToUniversalTime().ToString('o') })
    return (ConvertTo-DomeniaBiosReferenceBook ([pscustomobject]@{ Version = 1; References = $items.ToArray() }) -Strict)
}

function Remove-DomeniaBiosReference {
    param($Book,[AllowEmptyString()][string]$Manufacturer,[AllowEmptyString()][string]$Model)
    $items = New-Object System.Collections.Generic.List[object]
    $key = (([string]$Manufacturer).Trim() + '|' + ([string]$Model).Trim()).ToLowerInvariant()
    foreach ($item in @(Get-DomeniaMember $Book 'References' @())) { if ((([string]$item.Manufacturer) + '|' + ([string]$item.Model)).ToLowerInvariant() -cne $key) { $items.Add($item) } }
    return (ConvertTo-DomeniaBiosReferenceBook ([pscustomobject]@{ Version = 1; References = $items.ToArray() }))
}

function Get-DomeniaBiosReading {
    # Declared BIOS version and date, the model it belongs to, and the comparison with the version approved for that
    # model. Without an approved reference, no conclusion is drawn from a version or a date.
    param($Bios,$System,$References=$null)
    $facts = New-Object System.Collections.Generic.List[object]
    $context = [pscustomobject]@{ Manufacturer = ''; Model = ''; Version = ''; Reference = $null }
    if ($Bios.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Bios 'Version du BIOS' 'Win32_BIOS' }
    elseif (-not @($Bios.Rows).Count) { Add-DomeniaReadingFact $facts 'Version du BIOS' 'Aucune instance renvoyée' 'Inconnu' 'Win32_BIOS' '' '' $Bios.CheckedUtc }
    else {
        $row = @($Bios.Rows)[0]
        $context.Version = Get-DomeniaReadingText $row 'SMBIOSBIOSVersion'
        $maker = Get-DomeniaReadingText $row 'Manufacturer'
        Add-DomeniaReadingFact $facts 'Version du BIOS' $(if ($context.Version) { Join-DomeniaReadingText @($context.Version,$maker) } else { 'Non renseignée' }) $(if ($context.Version) { 'Constate' } else { 'Inconnu' }) 'Win32_BIOS' 'Version déclarée par le micrologiciel.' '' $Bios.CheckedUtc
        $date = ConvertTo-DomeniaUtcDate (Get-DomeniaMemberValue $row 'ReleaseDate')
        if ($null -ne $date) { Add-DomeniaReadingFact $facts 'Date du BIOS' ($date.ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture)) 'Constate' 'Win32_BIOS' 'Une date ancienne ne prouve pas une vulnérabilité ; seule une référence approuvée permet de conclure.' '' $Bios.CheckedUtc }
        else { Add-DomeniaReadingFact $facts 'Date du BIOS' 'Non renseignée' 'Inconnu' 'Win32_BIOS' '' '' $Bios.CheckedUtc }
        $major = Get-DomeniaReadingNumber $row 'SMBIOSMajorVersion'; $minor = Get-DomeniaReadingNumber $row 'SMBIOSMinorVersion'
        if (($null -ne $major) -and ($null -ne $minor)) { Add-DomeniaReadingFact $facts 'Spécification SMBIOS' ([string][int]$major + '.' + [string][int]$minor) 'Constate' 'Win32_BIOS' '' '' $Bios.CheckedUtc }
    }
    if ($System.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $System 'Modèle du poste' 'Win32_ComputerSystem' }
    elseif (-not @($System.Rows).Count) { Add-DomeniaReadingFact $facts 'Modèle du poste' 'Aucune instance renvoyée' 'Inconnu' 'Win32_ComputerSystem' '' '' $System.CheckedUtc }
    else {
        $row = @($System.Rows)[0]
        $context.Manufacturer = Get-DomeniaReadingText $row 'Manufacturer'
        $context.Model = Get-DomeniaReadingText $row 'Model'
        $family = Get-DomeniaReadingText $row 'SystemFamily'
        Add-DomeniaReadingFact $facts 'Modèle du poste' $(if ($context.Model) { Join-DomeniaReadingText @($context.Model,$context.Manufacturer,$family) } else { 'Non renseigné' }) $(if ($context.Model) { 'Constate' } else { 'Inconnu' }) 'Win32_ComputerSystem' 'Les postes dʼun même modèle se comparent à la même référence.' '' $System.CheckedUtc
    }
    $title = 'Référence approuvée'
    if ((-not $context.Model) -or (-not $context.Version)) { Add-DomeniaReadingFact $facts $title 'Comparaison impossible : modèle ou version du BIOS non lu' 'Inconnu' 'Références BIOS locales' ; return [pscustomobject]@{ Facts = $facts.ToArray(); Context = $context } }
    $reference = Get-DomeniaBiosReference $References $context.Manufacturer $context.Model
    $context.Reference = $reference
    $who = Join-DomeniaReadingText @($context.Manufacturer,$context.Model) ' '
    if ($null -eq $reference) { Add-DomeniaReadingFact $facts $title ('Aucune référence approuvée pour ' + $who + ' : aucune conclusion') 'Inconnu' 'Références BIOS locales' 'Approuvez la version dʼun poste validé de ce modèle pour comparer les autres.' }
    else {
        $approved = 'référence ' + [string]$reference.Version + ' approuvée le ' + (Format-DomeniaReadingDate $reference.ApprovedUtc)
        switch (Compare-DomeniaBiosVersion $context.Version ([string]$reference.Version)) {
            'Equal' { Add-DomeniaReadingFact $facts $title ('Conforme à la ' + $approved) 'Constate' 'Références BIOS locales' 'Comparaison à une version approuvée localement, pas aux publications du constructeur.' }
            'Older' { Add-DomeniaReadingFact $facts $title ('Antérieure à la ' + $approved) 'Constate' 'Références BIOS locales' 'Ordre déduit de versions au même format.' 'Mise à jour du BIOS attendue selon la référence approuvée.' }
            'Newer' { Add-DomeniaReadingFact $facts $title ('Plus récente que la ' + $approved) 'Constate' 'Références BIOS locales' 'Ordre déduit de versions au même format.' 'Si cette version est validée, mettez à jour la référence du modèle.' }
            default { Add-DomeniaReadingFact $facts $title ('Différente de la ' + $approved + ' : formats non comparables') 'Estime' 'Références BIOS locales' 'Aucun ordre nʼest supposé entre deux formats de version différents.' 'Vérification manuelle de la version attendue.' }
        }
    }
    return [pscustomobject]@{ Facts = $facts.ToArray(); Context = $context }
}

# ---------------------------------------------------------------- point 86: processors and virtualization
function Get-DomeniaVirtualPlatform {
    # Hypervisor named by the declared maker and model, or '' when no known signature is present. A generic model
    # or a hidden signature is possible: the result is an estimate, never a proof.
    param([AllowEmptyString()][string]$Manufacturer,[AllowEmptyString()][string]$Model)
    $text = ([string]$Manufacturer + ' ' + [string]$Model)
    if (($Model -match '(?i)\bVirtual Machine\b') -and ($Manufacturer -match '(?i)Microsoft')) { return 'Hyper-V' }
    if ($text -match '(?i)VMware') { return 'VMware' }
    if ($text -match '(?i)VirtualBox|innotek') { return 'VirtualBox' }
    if ($text -match '(?i)\bKVM\b|QEMU|Standard PC \(') { return 'KVM / QEMU' }
    if ($text -match '(?i)HVM domU|\bXen\b') { return 'Xen' }
    if ($text -match '(?i)Amazon EC2') { return 'Amazon EC2' }
    if ($text -match '(?i)Google Compute Engine') { return 'Google Compute Engine' }
    if ($text -match '(?i)Parallels') { return 'Parallels' }
    if ($text -match '(?i)\bBochs\b') { return 'Bochs' }
    return ''
}

function Get-DomeniaProcessorReading {
    # Sockets, architecture, cores and capabilities, a dated instantaneous load, and whether the platform looks
    # physical or virtual. Inside a virtual machine every value describes the processor presented to the guest.
    param($Processors,$System)
    $facts = New-Object System.Collections.Generic.List[object]
    $architecture = '0=x86;1=MIPS;2=Alpha;3=PowerPC;5=ARM;6=Itanium;9=x64;12=ARM64'
    if ($Processors.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Processors 'Processeurs' 'Win32_Processor' }
    elseif (-not @($Processors.Rows).Count) { Add-DomeniaReadingFact $facts 'Processeurs' 'Aucune instance renvoyée' 'Inconnu' 'Win32_Processor' '' '' $Processors.CheckedUtc }
    else {
        $cores = 0; $logical = 0; $countKnown = $true
        foreach ($cpu in @($Processors.Rows)) {
            $name = (Get-DomeniaReadingText $cpu 'Name') -replace '\s+',' '
            $c = Get-DomeniaReadingNumber $cpu 'NumberOfCores'; $l = Get-DomeniaReadingNumber $cpu 'NumberOfLogicalProcessors'
            if (($null -eq $c) -or ($null -eq $l)) { $countKnown = $false } else { $cores += [int]$c; $logical += [int]$l }
            $mhz = Get-DomeniaReadingNumber $cpu 'MaxClockSpeed'
            $vt = Get-DomeniaReadingBool $cpu 'VirtualizationFirmwareEnabled'; $slat = Get-DomeniaReadingBool $cpu 'SecondLevelAddressTranslationExtensions'
            $value = Join-DomeniaReadingText @($name,(Get-DomeniaReadingCode (Get-DomeniaReadingNumber $cpu 'Architecture') $architecture),$(if (($null -ne $c) -and ($null -ne $l)) { [string][int]$c + ' cœurs, ' + [string][int]$l + ' processeurs logiques' } else { '' }),$(if (($null -ne $mhz) -and ($mhz -gt 0)) { (Format-DomeniaReadingNumber $mhz) + ' MHz max' } else { '' }),$(if ($null -ne $vt) { 'virtualisation firmware ' + $(if ($vt) { 'activée' } else { 'non signalée' }) } else { '' }),$(if ($null -ne $slat) { 'SLAT ' + $(if ($slat) { 'oui' } else { 'non' }) } else { '' }))
            Add-DomeniaReadingFact $facts ('Processeur ' + (Get-DomeniaReadingText $cpu 'DeviceID')) $value 'Constate' 'Win32_Processor' 'Quand un hyperviseur est actif, la virtualisation firmware peut être signalée absente : elle est alors utilisée par lʼhyperviseur.' '' $Processors.CheckedUtc
            $load = Get-DomeniaReadingNumber $cpu 'LoadPercentage'
            if ($null -ne $load) { Add-DomeniaReadingFact $facts ('Charge de ' + (Get-DomeniaReadingText $cpu 'DeviceID') + ' au relevé') ((Format-DomeniaReadingNumber $load) + ' %') 'Constate' 'Win32_Processor' 'Mesure instantanée datée ; la charge sur un intervalle se mesure dans lʼinventaire complet.' '' $Processors.CheckedUtc }
        }
        if ($countKnown) { Add-DomeniaReadingFact $facts 'Total' ([string]@($Processors.Rows).Count + ' processeur(s), ' + [string]$cores + ' cœurs, ' + [string]$logical + ' processeurs logiques') 'Constate' 'Win32_Processor' (Get-DomeniaReadingPartialText $Processors) '' $Processors.CheckedUtc }
    }
    if ($System.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $System 'Machine physique ou virtuelle' 'Win32_ComputerSystem'; return $facts.ToArray() }
    if (-not @($System.Rows).Count) { Add-DomeniaReadingFact $facts 'Machine physique ou virtuelle' 'Système non renvoyé' 'Inconnu' 'Win32_ComputerSystem' '' '' $System.CheckedUtc; return $facts.ToArray() }
    $row = @($System.Rows)[0]
    $platform = Get-DomeniaVirtualPlatform (Get-DomeniaReadingText $row 'Manufacturer') (Get-DomeniaReadingText $row 'Model')
    $hypervisor = Get-DomeniaReadingBool $row 'HypervisorPresent'
    $limit = 'Estimation fondée sur le fabricant et le modèle déclarés ; un modèle générique ou masqué reste possible.'
    if ($platform) { Add-DomeniaReadingFact $facts 'Machine physique ou virtuelle' ('Machine virtuelle (' + $platform + ') dʼaprès le modèle déclaré') 'Estime' 'Win32_ComputerSystem' $limit '' $System.CheckedUtc }
    elseif ($hypervisor -eq $true) { Add-DomeniaReadingFact $facts 'Machine physique ou virtuelle' 'Machine physique probable, avec un hyperviseur actif (Hyper-V ou sécurité basée sur la virtualisation)' 'Estime' 'Win32_ComputerSystem' $limit '' $System.CheckedUtc }
    elseif ($hypervisor -eq $false) { Add-DomeniaReadingFact $facts 'Machine physique ou virtuelle' 'Machine physique probable : aucune signature dʼhyperviseur connue' 'Estime' 'Win32_ComputerSystem' $limit '' $System.CheckedUtc }
    else { Add-DomeniaReadingFact $facts 'Machine physique ou virtuelle' 'Non déterminé : modèle sans signature connue et hyperviseur non signalé' 'Inconnu' 'Win32_ComputerSystem' $limit '' $System.CheckedUtc }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 87: screens and docking
function Get-DomeniaDockHintFacts {
    # Point 87: what can honestly be said about a docking station. No standard Windows class identifies one: the Plug
    # and Play devices of the Dock class, or whose name mentions a dock, Thunderbolt, USB4 or DisplayLink, are hints
    # (Estime), each named with its class and maker; their absence proves nothing (Inconnu), and a missing read is said.
    param($Docks)
    $facts = New-Object System.Collections.Generic.List[object]
    $limit = 'Indice seulement : aucune classe Windows normalisée nʼidentifie une station dʼaccueil ; une station USB-C ou Thunderbolt peut nʼapparaître que comme concentrateur USB, carte réseau ou carte audio, et un contrôleur intégré au portable nʼest pas une station.'
    if (($null -eq $Docks) -or ([string]$Docks.State -ne 'Read')) {
        if ($null -ne $Docks) { Add-DomeniaReadingSourceFact $facts $Docks 'Indices de station dʼaccueil' 'Win32_PnPEntity' }
        Add-DomeniaReadingFact $facts 'Station dʼaccueil' 'Non identifiable par une classe Windows normalisée' 'Inconnu' 'Aucune' 'Seuls les écrans et leur raccordement sont décrits ; un écran externe peut passer par une station dʼaccueil.'
        return $facts.ToArray()
    }
    $rows = @($Docks.Rows)
    if (-not $rows.Count) {
        Add-DomeniaReadingFact $facts 'Station dʼaccueil' 'Aucun indice parmi les périphériques présents' 'Inconnu' 'Win32_PnPEntity' (Join-DomeniaReadingText @('Lʼabsence dʼindice ne prouve pas lʼabsence de station.',(Get-DomeniaReadingPartialText $Docks)) ' ') '' $Docks.CheckedUtc
        return $facts.ToArray()
    }
    $index = 0
    foreach ($row in @($rows | Select-Object -First 8)) {
        $index++
        $class = Get-DomeniaReadingText $row 'PNPClass'
        $maker = Get-DomeniaReadingText $row 'Manufacturer'
        $value = Join-DomeniaReadingText @((Get-DomeniaReadingText $row 'Name'),$(if ($class) { 'classe ' + $class } else { '' }),$(if ($maker) { 'fabricant ' + $maker } else { '' }))
        if (-not $value) { $value = 'Périphérique sans nom déclaré' }
        $kind = if ($class -ieq 'Dock') { 'Station dʼaccueil déclarée par Windows (classe Dock)' } else { 'Indice par le nom du périphérique' }
        Add-DomeniaReadingFact $facts ('Indice de station dʼaccueil ' + [string]$index) $value 'Estime' 'Win32_PnPEntity' $limit $kind $Docks.CheckedUtc
    }
    if ($rows.Count -gt 8) { Add-DomeniaReadingFact $facts 'Autres indices' ([string]($rows.Count - 8) + ' autre(s) périphérique(s) évocateur(s)') 'Estime' 'Win32_PnPEntity' $limit '' $Docks.CheckedUtc }
    $partial = Get-DomeniaReadingPartialText $Docks
    if ($partial) { Add-DomeniaReadingFact $facts 'Lecture des indices' $partial 'Inconnu' 'Win32_PnPEntity' '' '' $Docks.CheckedUtc }
    return $facts.ToArray()
}

function Get-DomeniaVideoOutputText {
    # D3DKMDT_VIDEO_OUTPUT_TECHNOLOGY of WmiMonitorConnectionParams, with the internal flag 0x80000000.
    param($Code)
    $number = ConvertTo-DomeniaProbeNumber $Code
    if ($null -eq $number) { return [pscustomobject]@{ Text = 'raccordement non lu'; Internal = $null } }
    $table = '0=VGA;1=S-Vidéo;2=composite;3=composantes;4=DVI;5=HDMI;6=LVDS;8=D-JPN;9=SDI;10=DisplayPort externe;11=DisplayPort intégré;12=UDI externe;13=UDI intégré;14=adaptateur SDTV;15=Miracast;16=indirect filaire;17=indirect virtuel;2147483648=écran interne;4294967295=autre'
    $internal = ($number -eq 2147483648) -or ($number -eq 6) -or ($number -eq 11) -or ($number -eq 13)
    $external = ($number -in @(0,1,2,3,4,5,8,9,10,12,14,15,16))
    return [pscustomobject]@{ Text = (Get-DomeniaReadingCode ([string][long]$number) $table); Internal = $(if ($internal) { $true } elseif ($external) { $false } else { $null }) }
}

function Get-DomeniaDisplayReading {
    # Screens identified by their EDID when it is readable, their connection, and the changes between the stored
    # readings of this workstation. A docking station itself is never claimed: no standard Windows class names it;
    # the Plug and Play devices whose class or name hint at one (hw.dockhints) are listed as hints, never as proof.
    param($Monitors,$Connections,$Docks=$null)
    $facts = New-Object System.Collections.Generic.List[object]
    $links = @{}
    if ($Connections.State -eq 'Read') { foreach ($row in @($Connections.Rows)) { $key = Get-DomeniaReadingText $row 'InstanceName'; if ($key) { $links[$key.ToLowerInvariant()] = $row } } }
    if ($Monitors.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Monitors 'Écrans' 'WmiMonitorID' }
    elseif (-not @($Monitors.Rows).Count) { Add-DomeniaReadingFact $facts 'Écrans' 'Aucun écran déclaré' $(if ($Monitors.Complete) { 'Constate' } else { 'Inconnu' }) 'WmiMonitorID' 'Session sans écran actif, poste distant ou pilote sans EDID.' '' $Monitors.CheckedUtc }
    else {
        $index = 0; $externalCount = 0; $internalCount = 0; $unknownCount = 0
        foreach ($monitor in @($Monitors.Rows)) {
            $index++
            $identity = Get-DomeniaMonitorIdentity $monitor
            $instance = (Get-DomeniaReadingText $monitor 'InstanceName').ToLowerInvariant()
            $link = $null; if (($instance) -and ($links.ContainsKey($instance))) { $link = $links[$instance] }
            $output = if ($null -ne $link) { Get-DomeniaVideoOutputText (Get-DomeniaMemberValue $link 'VideoOutputTechnology') } else { [pscustomobject]@{ Text = 'raccordement non lu'; Internal = $null } }
            if ($output.Internal -eq $true) { $internalCount++ } elseif ($output.Internal -eq $false) { $externalCount++ } else { $unknownCount++ }
            $year = Get-DomeniaReadingNumber $monitor 'YearOfManufacture'; $week = Get-DomeniaReadingNumber $monitor 'WeekOfManufacture'
            $made = if (($null -ne $year) -and ($year -gt 1990)) { 'fabriqué en ' + [string][int]$year + $(if (($null -ne $week) -and ($week -ge 1) -and ($week -le 53)) { ' (semaine ' + [string][int]$week + ')' } else { '' }) } else { '' }
            if ($identity) { Add-DomeniaReadingFact $facts ('Écran ' + [string]$index) (Join-DomeniaReadingText @($identity,$output.Text,$made)) 'Constate' 'WmiMonitorID, WmiMonitorConnectionParams' 'Identité lue dans lʼEDID de lʼécran.' '' $Monitors.CheckedUtc }
            else { Add-DomeniaReadingFact $facts ('Écran ' + [string]$index) (Join-DomeniaReadingText @('EDID illisible',$output.Text)) 'Inconnu' 'WmiMonitorID' 'Écran virtuel, adaptateur ou station dʼaccueil qui ne transmet pas lʼEDID : écran non identifié.' '' $Monitors.CheckedUtc }
        }
        Add-DomeniaReadingFact $facts 'Raccordements' ([string]$internalCount + ' interne(s), ' + [string]$externalCount + ' externe(s), ' + [string]$unknownCount + ' non déterminé(s)') $(if ($unknownCount) { 'Estime' } else { 'Constate' }) 'WmiMonitorConnectionParams' (Join-DomeniaReadingText @('Type de sortie vu par la carte graphique.',(Get-DomeniaReadingPartialText $Monitors)) ' ') '' $Monitors.CheckedUtc
    }
    if (($Connections.State -ne 'Read') -and ($Monitors.State -eq 'Read')) { Add-DomeniaReadingSourceFact $facts $Connections 'Type de raccordement' 'WmiMonitorConnectionParams' }
    foreach ($fact in @(Get-DomeniaDockHintFacts $Docks)) { $facts.Add($fact) }
    # Changes between the stored readings: each sample is the sorted set of identified screens.
    $history = @($Monitors.History)
    if ($history.Count -lt 2) { Add-DomeniaReadingFact $facts 'Changements dʼécrans' ('Aucun changement comparable : ' + [string]$history.Count + ' ensemble(s) dʼécrans enregistré(s)') 'Inconnu' 'Historique des relevés' 'Un changement se constate entre deux relevés enregistrés de ce poste.' }
    else {
        $changes = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -lt $history.Count; $i++) {
            $earlier = $history[$i - 1]; $later = $history[$i]
            $before = @(@(Get-DomeniaMember $earlier 'Items' @()) | ForEach-Object { [string]$_ })
            $after = @(@(Get-DomeniaMember $later 'Items' @()) | ForEach-Object { [string]$_ })
            $when = Format-DomeniaReadingDate (Get-DomeniaMember $later 'AtUtc' $null)
            foreach ($name in $after) { if ($before -cnotcontains $name) { $changes.Add('apparu au relevé du ' + $when + ' : ' + $name) } }
            foreach ($name in $before) { if ($after -cnotcontains $name) { $changes.Add('absent au relevé du ' + $when + ' : ' + $name) } }
        }
        $recent = @($changes.ToArray() | Select-Object -Last 6)
        Add-DomeniaReadingFact $facts 'Changements dʼécrans' $(if ($recent.Count) { $recent -join ' ; ' } else { 'Aucun changement entre les relevés enregistrés' }) 'Constate' 'Historique des relevés' ('Comparaison des ' + [string]$history.Count + ' ensembles dʼécrans enregistrés ; un relevé manqué peut masquer un passage.')
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 88: network interfaces
function Test-DomeniaVirtualAdapterName {
    # Software adapters recognised by their usual names; Windows' own PhysicalAdapter flag is preferred when read.
    param([AllowEmptyString()][string]$Name)
    return ([string]$Name -match '(?i)Hyper-V|vEthernet|VMware|VirtualBox|\bTAP\b|TAP-Windows|WireGuard|Wintun|WAN Miniport|Loopback|Teredo|ISATAP|6to4|Npcap|Kernel Debug|Virtual Adapter|Microsoft Wi-Fi Direct')
}

function Get-DomeniaNetworkReading {
    # Physical adapters first with their status, declared speed, MAC and IP configuration; virtual adapters apart.
    # Configuration is joined to the adapter by its index; nothing here proves that a service is reachable.
    param($Interfaces,$Configurations)
    $facts = New-Object System.Collections.Generic.List[object]
    $status = '0=déconnectée;1=connexion en cours;2=connectée;3=déconnexion en cours;4=matériel absent;5=matériel désactivé;6=défaillance matérielle;7=câble ou média déconnecté;8=authentification en cours;9=authentification réussie;10=échec de lʼauthentification;11=adresse non valide;12=identifiants requis'
    $configs = @{}
    if ($Configurations.State -eq 'Read') { foreach ($row in @($Configurations.Rows)) { $index = Get-DomeniaReadingNumber $row 'Index'; if ($null -ne $index) { $configs[[string][long]$index] = $row } } }
    if ($Interfaces.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Interfaces 'Cartes réseau' 'Win32_NetworkAdapter' }
    elseif (-not @($Interfaces.Rows).Count) { Add-DomeniaReadingFact $facts 'Cartes réseau' 'Aucune carte renvoyée' 'Inconnu' 'Win32_NetworkAdapter' '' '' $Interfaces.CheckedUtc }
    else {
        $virtual = New-Object System.Collections.Generic.List[string]
        foreach ($adapter in @($Interfaces.Rows)) {
            $name = Get-DomeniaReadingText $adapter 'Name'
            $physical = Get-DomeniaReadingBool $adapter 'PhysicalAdapter'
            $pnp = Get-DomeniaReadingText $adapter 'PNPDeviceID'
            $isVirtual = if ($physical -eq $false) { $true } elseif (($physical -eq $true) -and ($pnp -notmatch '^(?i)(ROOT|SWD)\\')) { $false } else { Test-DomeniaVirtualAdapterName $name }
            $connection = Get-DomeniaReadingText $adapter 'NetConnectionID'
            $state = Get-DomeniaReadingNumber $adapter 'NetConnectionStatus'
            if ($isVirtual) { if ($state -eq 2) { $virtual.Add($name + ' (connectée)') } elseif ($name) { $virtual.Add($name) }; continue }
            if (($null -eq $state) -and (-not $connection)) { continue }
            $speed = Get-DomeniaReadingNumber $adapter 'Speed'
            $speedText = ''
            if (($null -ne $speed) -and ($speed -gt 0) -and ($speed -lt 9.2e18)) { $speedText = if ($speed -ge 1e9) { (Format-DomeniaReadingNumber ($speed / 1e9) '0.#') + ' Gbit/s déclarés' } else { (Format-DomeniaReadingNumber ($speed / 1e6)) + ' Mbit/s déclarés' } }
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add((Get-DomeniaReadingCode $state $status)); if ($speedText) { $parts.Add($speedText) }
            $mac = Get-DomeniaReadingText $adapter 'MACAddress'; if ($mac) { $parts.Add('MAC ' + $mac) }
            $config = $null; $deviceId = Get-DomeniaReadingText $adapter 'DeviceID'
            if (($deviceId) -and ($configs.ContainsKey($deviceId))) { $config = $configs[$deviceId] }
            if ($null -ne $config) {
                $ips = Get-DomeniaReadingText $config 'IPAddress'; if ($ips) { $parts.Add('IP ' + $ips) }
                $gateway = Get-DomeniaReadingText $config 'DefaultIPGateway'; if ($gateway) { $parts.Add('passerelle ' + $gateway) }
                $dns = Get-DomeniaReadingText $config 'DNSServerSearchOrder'; if ($dns) { $parts.Add('DNS ' + $dns) }
                $dhcp = Get-DomeniaReadingBool $config 'DHCPEnabled'
                if ($dhcp -eq $true) { $server = Get-DomeniaReadingText $config 'DHCPServer'; $parts.Add('DHCP' + $(if ($server) { ' (' + $server + ')' } else { '' })) } elseif ($dhcp -eq $false) { $parts.Add('adresse fixe') }
            }
            $title = 'Carte ' + $(if ($connection) { $connection + ' (' + $name + ')' } else { $name })
            $hint = if (($state -in @(6,10,11)) -or (($state -eq 7) -and ($connection -match '(?i)ethernet'))) { 'État à vérifier sur le poste.' } else { '' }
            Add-DomeniaReadingFact $facts $title ($parts.ToArray() -join ' · ') 'Constate' 'Win32_NetworkAdapter, Win32_NetworkAdapterConfiguration' (Join-DomeniaReadingText @('Vitesse déclarée par le pilote, pas un débit mesuré ; la configuration ne prouve pas lʼaccès à un service.',(Get-DomeniaReadingPartialText $Interfaces)) ' ') $hint $Interfaces.CheckedUtc
        }
        if ($virtual.Count) { Add-DomeniaReadingFact $facts 'Cartes virtuelles' ([string]$virtual.Count + ' : ' + ($virtual.ToArray() -join ', ')) 'Constate' 'Win32_NetworkAdapter' 'Classées par lʼindicateur PhysicalAdapter de Windows, sinon par leur nom.' '' $Interfaces.CheckedUtc }
    }
    if (($Configurations.State -ne 'Read') -and ($Interfaces.State -eq 'Read')) { Add-DomeniaReadingSourceFact $facts $Configurations 'Configuration IP' 'Win32_NetworkAdapterConfiguration' }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 89: printers and devices in error
function Get-DomeniaDeviceErrorText {
    # Device manager problem code: label and whether it is an anomaly (disabled or disconnected devices are not).
    param($Code)
    $table = '1=mal configuré;3=pilote endommagé ou ressources insuffisantes;10=ne peut pas démarrer;12=ressources insuffisantes ou en conflit;14=redémarrage nécessaire;18=pilotes à réinstaller;19=configuration du registre endommagée;21=en cours de suppression;22=désactivé;24=absent ou mal installé;28=pilote non installé;29=désactivé par le micrologiciel;31=pilote non chargé;32=service du pilote désactivé;37=initialisation du pilote échouée;39=pilote manquant ou endommagé;43=arrêté après un problème signalé;45=non connecté actuellement;47=retiré, en attente;48=bloqué (incompatible);52=signature du pilote non vérifiée'
    $number = ConvertTo-DomeniaProbeNumber $Code
    $key = if ($null -ne $number) { [string][long]$number } else { $null }
    return [pscustomobject]@{ Text = (Get-DomeniaReadingCode $key $table); Anomaly = ($key -notin @('22','45')) }
}

function Get-DomeniaDeviceReading {
    # Printers as reported by their driver (another user session may hide some), and devices with a problem code.
    param($Printers,$Devices)
    $facts = New-Object System.Collections.Generic.List[object]
    $extended = '1=autre;2=inconnu;3=prête;4=impression;5=préchauffage;6=impression arrêtée;7=hors ligne;8=en pause;9=erreur;10=occupée;11=indisponible;12=en attente;13=traitement;14=initialisation;15=économie dʼénergie;16=suppression en attente;17=entrée-sortie active;18=alimentation manuelle'
    $sessionLimit = 'Les imprimantes propres à une autre session utilisateur peuvent manquer ; lʼétat vient du pilote et peut être ancien.'
    if ($Printers.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Printers 'Imprimantes' 'Win32_Printer' }
    else {
        $rows = @($Printers.Rows); $problems = 0; $default = ''
        foreach ($printer in $rows) {
            $name = Get-DomeniaReadingText $printer 'Name'
            if ((Get-DomeniaReadingBool $printer 'Default') -eq $true) { $default = $name }
            $code = Get-DomeniaReadingNumber $printer 'ExtendedPrinterStatus'
            $offline = ((Get-DomeniaReadingBool $printer 'WorkOffline') -eq $true) -or ($code -eq 7)
            $faulty = ($code -in @(6,9,11))
            if (-not ($offline -or $faulty)) { continue }
            $problems++
            $kind = if ((Get-DomeniaReadingBool $printer 'Network') -eq $true) { 'réseau' } elseif ((Get-DomeniaReadingBool $printer 'Local') -eq $true) { 'locale' } else { '' }
            Add-DomeniaReadingFact $facts ('Imprimante ' + $name) (Join-DomeniaReadingText @($(if ($offline) { 'hors ligne' } else { Get-DomeniaReadingCode $code $extended }),$kind,('pilote ' + (Get-DomeniaReadingText $printer 'DriverName')),('port ' + (Get-DomeniaReadingText $printer 'PortName')))) 'Constate' 'Win32_Printer' $sessionLimit 'Vérifier lʼimprimante, son port ou la file dʼimpression.' $Printers.CheckedUtc
        }
        $summary = [string]$rows.Count + ' imprimante(s), ' + [string]$problems + ' hors ligne ou en erreur' + $(if ($default) { ' · par défaut : ' + $default } else { '' })
        Add-DomeniaReadingFact $facts 'Imprimantes' $summary 'Constate' 'Win32_Printer' (Join-DomeniaReadingText @($sessionLimit,(Get-DomeniaReadingPartialText $Printers)) ' ') '' $Printers.CheckedUtc
    }
    if ($Devices.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Devices 'Périphériques en erreur' 'Win32_PnPEntity'; return $facts.ToArray() }
    $partial = Get-DomeniaReadingPartialText $Devices
    $anomalies = 0; $informative = 0
    foreach ($device in @($Devices.Rows)) {
        $code = Get-DomeniaDeviceErrorText (Get-DomeniaMemberValue $device 'ConfigManagerErrorCode')
        $name = Get-DomeniaReadingText $device 'Name'; if (-not $name) { $name = Get-DomeniaReadingText $device 'DeviceID' }
        if ($code.Anomaly) { $anomalies++ } else { $informative++ }
        if (($anomalies + $informative) -gt 25) { continue }
        Add-DomeniaReadingFact $facts ('Périphérique ' + $name) (Join-DomeniaReadingText @($code.Text,(Get-DomeniaReadingText $device 'PNPClass'),(Get-DomeniaReadingText $device 'Manufacturer'))) 'Constate' 'Win32_PnPEntity' (Join-DomeniaReadingText @('Code du gestionnaire de périphériques, pas une cause certaine.',$partial) ' ') $(if ($code.Anomaly) { 'Vérifier le pilote de ce périphérique.' } else { '' }) $Devices.CheckedUtc
    }
    $value = if (-not @($Devices.Rows).Count) { 'Aucun périphérique signalé en erreur' } else { [string]$anomalies + ' en anomalie, ' + [string]$informative + ' désactivé(s) ou déconnecté(s)' }
    Add-DomeniaReadingFact $facts 'Périphériques en erreur' $value $(if ((-not @($Devices.Rows).Count) -and (-not $Devices.Complete)) { 'Inconnu' } else { 'Constate' }) 'Win32_PnPEntity' (Join-DomeniaReadingText @('Une lecture refusée ou interrompue nʼest pas une liste vide.',$partial) ' ') '' $Devices.CheckedUtc
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 94: services and expected profile
function Get-DomeniaServiceProfile {
    # Services expected to run on a workstation joined to the domain (short name|reason). Kept as data in this
    # module; a deviation is a lead to check, never an action: no service is started or changed by Domenia.
    $text = @'
Winmgmt|Instrumentation WMI : nécessaire aux lectures à distance
RpcSs|Appel de procédure distante (RPC)
RpcEptMapper|Mappeur de points de terminaison RPC
Dnscache|Client DNS
Dhcp|Client DHCP (actif même avec une adresse fixe)
NlaSvc|Connaissance des emplacements réseau : choix du profil de pare-feu
LanmanWorkstation|Station de travail : accès aux partages et à SYSVOL
Netlogon|Ouverture de session réseau du domaine
gpsvc|Client de stratégie de groupe
EventLog|Journal dʼévénements Windows
Schedule|Planificateur de tâches
BFE|Moteur de filtrage de base (pare-feu et IPsec)
mpssvc|Pare-feu Windows Defender
CryptSvc|Services de chiffrement
ProfSvc|Service de profil utilisateur
'@
    foreach ($line in ($text -split "`n")) { $cells = @($line.Trim().Split('|')); if ($cells.Count -eq 2) { [pscustomobject]@{ Name = $cells[0]; Reason = $cells[1] } } }
}

function Get-DomeniaServiceReading {
    # State and start mode compared with the expected profile, and automatic services stopped with an error code.
    # Exit code 1077 (never started since boot) is the normal state of trigger-start services.
    param($Services,[object[]]$Expected=$null)
    $facts = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Expected) { $Expected = @(Get-DomeniaServiceProfile) }
    if ($Services.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Services 'Services' 'Win32_Service'; return $facts.ToArray() }
    if (-not @($Services.Rows).Count) { Add-DomeniaReadingFact $facts 'Services' 'Aucun service renvoyé' 'Inconnu' 'Win32_Service' (Get-DomeniaReadingPartialText $Services) '' $Services.CheckedUtc; return $facts.ToArray() }
    $byName = @{}
    foreach ($service in @($Services.Rows)) { $name = Get-DomeniaReadingText $service 'Name'; if ($name) { $byName[$name.ToLowerInvariant()] = $service } }
    $partial = Get-DomeniaReadingPartialText $Services
    $stateText = @{ 'running' = 'démarré'; 'stopped' = 'arrêté'; 'paused' = 'en pause'; 'start pending' = 'démarrage en cours'; 'stop pending' = 'arrêt en cours' }
    $modeText = @{ 'auto' = 'automatique'; 'manual' = 'manuel'; 'disabled' = 'désactivé'; 'boot' = 'démarrage'; 'system' = 'système' }
    $conform = 0; $checked = 0
    foreach ($expected in @($Expected)) {
        $key = ([string]$expected.Name).ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) {
            if ($Services.Complete) { $checked++; Add-DomeniaReadingFact $facts ('Service ' + [string]$expected.Name) 'Absent du poste' 'Constate' 'Win32_Service' ([string]$expected.Reason) 'Service attendu absent : vérifier lʼimage du poste.' $Services.CheckedUtc }
            continue
        }
        $checked++
        $service = $byName[$key]
        $state = (Get-DomeniaReadingText $service 'State').ToLowerInvariant(); $mode = (Get-DomeniaReadingText $service 'StartMode').ToLowerInvariant()
        if ($state -eq 'running') { $conform++; continue }
        $stateLabel = if ($stateText.ContainsKey($state)) { $stateText[$state] } else { $state }
        $modeLabel = if ($modeText.ContainsKey($mode)) { $modeText[$mode] } else { $mode }
        Add-DomeniaReadingFact $facts ('Service ' + (Get-DomeniaReadingText $service 'DisplayName') + ' (' + [string]$expected.Name + ')') ('Attendu démarré, constaté ' + $stateLabel + ' (démarrage ' + $modeLabel + ')') 'Constate' 'Win32_Service' ([string]$expected.Reason + '. Aucune action nʼest lancée depuis lʼinventaire.') 'Écart au profil attendu : vérifier le service et ses dépendances.' $Services.CheckedUtc
    }
    Add-DomeniaReadingFact $facts 'Profil attendu' ([string]$conform + ' service(s) conforme(s) sur ' + [string]$checked + ' vérifié(s) (' + [string]@($Expected).Count + ' attendus)') 'Constate' 'Win32_Service' (Join-DomeniaReadingText @('Profil intégré dʼun poste joint au domaine ; un service propre au parc nʼy figure pas.',$partial) ' ') '' $Services.CheckedUtc
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($service in @($Services.Rows)) {
        if ((Get-DomeniaReadingText $service 'StartMode') -ine 'Auto') { continue }
        if ((Get-DomeniaReadingText $service 'State') -ine 'Stopped') { continue }
        $exit = Get-DomeniaReadingNumber $service 'ExitCode'
        if (($null -eq $exit) -or ($exit -eq 0) -or ($exit -eq 1077)) { continue }
        $failed.Add((Get-DomeniaReadingText $service 'Name') + ' (code ' + [string][long]$exit + ')')
    }
    if ($failed.Count) { Add-DomeniaReadingFact $facts 'Services automatiques arrêtés sur erreur' (@($failed.ToArray() | Select-Object -First 10) -join ', ') 'Constate' 'Win32_Service' 'Code de sortie Win32 du dernier arrêt ; 1077 (jamais démarré) est exclu.' 'Arrêt anormal possible : consulter le journal Système du poste.' $Services.CheckedUtc }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 96: scheduled tasks and autostart
function Get-DomeniaTaskReading {
    # Inventory, author and state of the tasks, with the non-Microsoft ones listed; startup entries by location.
    # Commands, arguments and principals are never read: they may hold secrets.
    param($Tasks,$Startup)
    $facts = New-Object System.Collections.Generic.List[object]
    $taskState = '0=inconnue;1=désactivée;2=en file;3=prête;4=en cours'
    if ($Tasks.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Tasks 'Tâches planifiées' 'MSFT_ScheduledTask' }
    else {
        $all = @($Tasks.Rows); $foreign = New-Object System.Collections.Generic.List[object]; $active = 0
        foreach ($task in $all) {
            $path = Get-DomeniaReadingText $task 'TaskPath'
            if ($path -like '\Microsoft\*') { continue }
            $foreign.Add($task)
            if ((Get-DomeniaReadingNumber $task 'State') -ne 1) { $active++ }
        }
        Add-DomeniaReadingFact $facts 'Tâches planifiées' ([string]$all.Count + ' tâche(s) visibles, dont ' + [string]$foreign.Count + ' hors Microsoft (' + [string]$active + ' non désactivée(s))') 'Constate' 'MSFT_ScheduledTask' (Join-DomeniaReadingText @('Certaines tâches restent invisibles selon les droits du compte de lecture.',(Get-DomeniaReadingPartialText $Tasks)) ' ') '' $Tasks.CheckedUtc
        foreach ($task in @($foreign.ToArray() | Select-Object -First 15)) {
            $author = Get-DomeniaReadingText $task 'Author'
            $registered = ConvertTo-DomeniaUtcDate (Get-DomeniaMemberValue $task 'Date')
            $value = Join-DomeniaReadingText @(('état ' + (Get-DomeniaReadingCode (Get-DomeniaReadingNumber $task 'State') $taskState)),$(if ($author) { 'auteur ' + $author } else { 'auteur non déclaré' }),$(if ($null -ne $registered) { 'enregistrée le ' + $registered.ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture) } else { '' }))
            Add-DomeniaReadingFact $facts ('Tâche ' + (Get-DomeniaReadingText $task 'TaskPath') + (Get-DomeniaReadingText $task 'TaskName')) $value 'Constate' 'MSFT_ScheduledTask' 'Auteur déclaré par la tâche, non vérifié.' '' $Tasks.CheckedUtc
        }
        Add-DomeniaReadingFact $facts 'Dernière exécution et dernier résultat' 'Non lus par cette requête : la classe dʼénumération des tâches ne les fournit pas' 'Inconnu' 'MSFT_ScheduledTask' 'Aucun résultat dʼexécution nʼest déduit de lʼétat. Lʼinventaire complet les lit par WinRM ; sans WinRM, il relève seulement la date du dernier démarrage dans le cache du Planificateur (registre, format non documenté), jamais le résultat.'
    }
    if ($Startup.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Startup 'Démarrage automatique' 'Win32_StartupCommand' }
    else {
        $byLocation = @{}
        foreach ($entry in @($Startup.Rows)) { $location = Get-DomeniaReadingText $entry 'Location'; if (-not $location) { $location = 'emplacement non déclaré' }; if (-not $byLocation.ContainsKey($location)) { $byLocation[$location] = New-Object System.Collections.Generic.List[string] }; $byLocation[$location].Add((Get-DomeniaReadingText $entry 'Name') + ' (' + (Get-DomeniaReadingText $entry 'User') + ')') }
        Add-DomeniaReadingFact $facts 'Démarrage automatique' ([string]@($Startup.Rows).Count + ' programme(s) déclaré(s)') 'Constate' 'Win32_StartupCommand' 'Commandes et arguments volontairement non collectés ; toutes les persistances ne passent pas par ce fournisseur.' '' $Startup.CheckedUtc
        foreach ($location in @($byLocation.Keys | Sort-Object)) { Add-DomeniaReadingFact $facts ('Démarrage depuis ' + $location) (@($byLocation[$location].ToArray() | Select-Object -First 10) -join ', ') 'Constate' 'Win32_StartupCommand' '' '' $Startup.CheckedUtc }
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 97: antivirus and Defender
function ConvertFrom-DomeniaAvProductState {
    # Usual reading of the undocumented productState word: bit 0x10 of the middle byte (0x1000 of the word) marks an
    # active scanner, a low byte of 0x00 marks up-to-date signatures. Both results are estimates.
    param($State)
    $number = ConvertTo-DomeniaProbeNumber $State
    if (($null -eq $number) -or ($number -lt 0) -or ($number -gt 16777215)) { return [pscustomobject]@{ Enabled = $null; UpToDate = $null } }
    $value = [long]$number
    $middle = ($value -shr 8) -band 0xFF
    $low = $value -band 0xFF
    return [pscustomobject]@{ Enabled = (($middle -band 0x10) -ne 0); UpToDate = ($low -eq 0) }
}

function Get-DomeniaAntivirusReading {
    # Products declared to the Security Center (Defender included) and the detailed Defender status. No provider is
    # assumed universal: a third-party product may put Defender in passive mode, and servers have no Security Center.
    param($Products,$Defender)
    $facts = New-Object System.Collections.Generic.List[object]
    $thirdActive = New-Object System.Collections.Generic.List[string]
    $productsRead = $false; $productCount = 0
    if ($Products.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Products 'Antivirus déclarés' 'root\SecurityCenter2 AntiVirusProduct' }
    else {
        $productsRead = $true
        foreach ($product in @($Products.Rows)) {
            $productCount++
            $name = Get-DomeniaReadingText $product 'displayName'
            $decoded = ConvertFrom-DomeniaAvProductState (Get-DomeniaMemberValue $product 'productState')
            $enabledText = if ($decoded.Enabled -eq $true) { 'actif (estimé)' } elseif ($decoded.Enabled -eq $false) { 'inactif (estimé)' } else { 'état non décodé' }
            $signatures = if ($decoded.UpToDate -eq $true) { 'signatures à jour (estimé)' } elseif ($decoded.UpToDate -eq $false) { 'signatures anciennes (estimé)' } else { '' }
            $stamp = Get-DomeniaReadingText $product 'timestamp'
            Add-DomeniaReadingFact $facts ('Antivirus ' + $name) (Join-DomeniaReadingText @($enabledText,$signatures,$(if ($stamp) { 'déclaré le ' + $stamp } else { '' }))) 'Estime' 'root\SecurityCenter2 AntiVirusProduct' 'Décodage non documenté de productState : estimation.' $(if ($decoded.UpToDate -eq $false) { 'Signatures possiblement anciennes : vérifier la console du produit.' } else { '' }) $Products.CheckedUtc
            if (($decoded.Enabled -eq $true) -and ($name -notmatch '(?i)Windows Defender|Microsoft Defender')) { $thirdActive.Add($name) }
        }
    }
    $defenderActive = $null
    if ($Defender.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Defender 'Microsoft Defender' 'MSFT_MpComputerStatus' }
    elseif (-not @($Defender.Rows).Count) { Add-DomeniaReadingFact $facts 'Microsoft Defender' 'Aucun état renvoyé' 'Inconnu' 'MSFT_MpComputerStatus' '' '' $Defender.CheckedUtc }
    else {
        $row = @($Defender.Rows)[0]
        $av = Get-DomeniaReadingBool $row 'AntivirusEnabled'; $rtp = Get-DomeniaReadingBool $row 'RealTimeProtectionEnabled'; $behavior = Get-DomeniaReadingBool $row 'BehaviorMonitorEnabled'
        if (($av -eq $true) -and ($rtp -eq $true)) { $defenderActive = $true } elseif ($av -eq $false) { $defenderActive = $false }
        $flags = Join-DomeniaReadingText @($(if ($null -ne $av) { 'antivirus ' + $(if ($av) { 'activé' } else { 'désactivé' }) } else { '' }),$(if ($null -ne $rtp) { 'temps réel ' + $(if ($rtp) { 'activé' } else { 'désactivé' }) } else { '' }),$(if ($null -ne $behavior) { 'surveillance comportementale ' + $(if ($behavior) { 'activée' } else { 'désactivée' }) } else { '' }))
        Add-DomeniaReadingFact $facts 'Microsoft Defender' $(if ($flags) { $flags } else { 'Indicateurs non renvoyés' }) $(if ($flags) { 'Constate' } else { 'Inconnu' }) 'MSFT_MpComputerStatus' 'Déclarations du fournisseur Defender.' $(if (($rtp -eq $false) -and ($thirdActive.Count -eq 0)) { 'Protection en temps réel désactivée sans autre antivirus déclaré actif.' } else { '' }) $Defender.CheckedUtc
        $versions = Join-DomeniaReadingText @($(if (Get-DomeniaReadingText $row 'AMProductVersion') { 'produit ' + (Get-DomeniaReadingText $row 'AMProductVersion') } else { '' }),$(if (Get-DomeniaReadingText $row 'AMEngineVersion') { 'moteur ' + (Get-DomeniaReadingText $row 'AMEngineVersion') } else { '' }),$(if (Get-DomeniaReadingText $row 'AntivirusSignatureVersion') { 'signatures ' + (Get-DomeniaReadingText $row 'AntivirusSignatureVersion') } else { '' }))
        if ($versions) { Add-DomeniaReadingFact $facts 'Versions de Defender' $versions 'Constate' 'MSFT_MpComputerStatus' '' '' $Defender.CheckedUtc }
        $age = Get-DomeniaReadingNumber $row 'AntivirusSignatureAge'
        $updated = ConvertTo-DomeniaUtcDate (Get-DomeniaMemberValue $row 'AntivirusSignatureLastUpdated')
        if (($null -ne $age) -and ($age -ne 65535)) { Add-DomeniaReadingFact $facts 'Âge des signatures Defender' ((Format-DomeniaReadingNumber $age) + ' jour(s)' + $(if ($null -ne $updated) { ' (mises à jour le ' + $updated.ToLocalTime().ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture) + ')' } else { '' })) 'Constate' 'MSFT_MpComputerStatus' 'Âge déclaré au relevé.' $(if ($age -gt 7) { 'Signatures de plus de 7 jours : vérifier la mise à jour de Defender.' } else { '' }) $Defender.CheckedUtc }
        elseif ($age -eq 65535) { Add-DomeniaReadingFact $facts 'Âge des signatures Defender' 'Jamais mises à jour selon Defender' 'Constate' 'MSFT_MpComputerStatus' '' 'Signatures jamais mises à jour : Defender est peut-être en mode passif ou désactivé.' $Defender.CheckedUtc }
        foreach ($scan in @(@('QuickScanAge','Dernière analyse rapide'),@('FullScanAge','Dernière analyse complète'))) {
            $days = Get-DomeniaReadingNumber $row ([string]$scan[0])
            if ($null -eq $days) { continue }
            Add-DomeniaReadingFact $facts ([string]$scan[1]) $(if ($days -eq 65535) { 'Jamais réalisée selon Defender' } else { 'Il y a ' + (Format-DomeniaReadingNumber $days) + ' jour(s)' }) 'Constate' 'MSFT_MpComputerStatus' '' '' $Defender.CheckedUtc
        }
    }
    # Coverage: what the two sources say together, with the limit of each.
    $coverage = 'Couverture antivirus'
    if ($thirdActive.Count) { Add-DomeniaReadingFact $facts $coverage ('Protection tierce déclarée active : ' + ($thirdActive.ToArray() -join ', ') + '. Defender peut fonctionner en mode passif.') 'Estime' 'Centre de sécurité, Defender' 'Fondé sur le décodage non documenté de productState.' }
    elseif ($defenderActive -eq $true) { Add-DomeniaReadingFact $facts $coverage 'Defender actif avec la protection en temps réel' 'Constate' 'MSFT_MpComputerStatus' 'Ne dit rien de la qualité des exclusions ni des stratégies appliquées.' }
    elseif ($productsRead -and ($productCount -eq 0) -and ($defenderActive -eq $false)) { Add-DomeniaReadingFact $facts $coverage 'Aucun antivirus déclaré au Centre de sécurité et Defender désactivé' 'Constate' 'Centre de sécurité, Defender' 'Un produit qui ne se déclare pas au Centre de sécurité reste invisible ici.' 'Poste possiblement sans protection antivirus : vérifier sans attendre.' }
    elseif ($Products.State -eq 'Absent') { Add-DomeniaReadingFact $facts $coverage 'Centre de sécurité absent (Windows Server) : couverture tierce non lisible' 'Indisponible' 'root\SecurityCenter2' 'Seul lʼétat de Defender peut être lu sur ce système.' }
    else { Add-DomeniaReadingFact $facts $coverage 'Non déterminée avec les relevés disponibles' 'Inconnu' 'Centre de sécurité, Defender' 'Relevez les deux requêtes pour conclure.' }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 98: firewall profiles
function Get-DomeniaFirewallReading {
    # Profile settings of the local store and the profile Windows applies to each active connection. The group
    # policy origin and the merged active store are read by the full inventory (registry), not by this class.
    param($Profiles,$Connections)
    $facts = New-Object System.Collections.Generic.List[object]
    $applied = @{}
    if ($Connections.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Connections 'Profils appliqués' 'MSFT_NetConnectionProfile' }
    elseif (-not @($Connections.Rows).Count) { Add-DomeniaReadingFact $facts 'Profils appliqués' 'Aucune connexion active au relevé' $(if ($Connections.Complete) { 'Constate' } else { 'Inconnu' }) 'MSFT_NetConnectionProfile' '' '' $Connections.CheckedUtc }
    else {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($connection in @($Connections.Rows)) {
            $category = Get-DomeniaReadingNumber $connection 'NetworkCategory'
            $profileName = if ($category -eq 2) { 'Domain' } elseif ($category -eq 1) { 'Private' } elseif ($category -eq 0) { 'Public' } else { '' }
            $alias = Get-DomeniaReadingText $connection 'InterfaceAlias'
            if ($profileName) { if (-not $applied.ContainsKey($profileName)) { $applied[$profileName] = New-Object System.Collections.Generic.List[string] }; $applied[$profileName].Add($alias) }
            $parts.Add($alias + ' : ' + (Get-DomeniaReadingCode $category '0=public;1=privé;2=domaine') + $(if (Get-DomeniaReadingText $connection 'Name') { ' (' + (Get-DomeniaReadingText $connection 'Name') + ')' } else { '' }))
        }
        Add-DomeniaReadingFact $facts 'Profils appliqués' ($parts.ToArray() -join ' ; ') 'Constate' 'MSFT_NetConnectionProfile' 'Catégorie de chaque connexion active au relevé.' '' $Connections.CheckedUtc
    }
    if ($Profiles.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Profiles 'Profils du pare-feu' 'MSFT_NetFirewallProfile'; return $facts.ToArray() }
    $labels = @{ 'domain' = 'Domaine'; 'private' = 'Privé'; 'public' = 'Public' }
    $gpo = '0=désactivé;1=activé;2=non configuré dans ce magasin'
    $action = '0=non configurée;2=autoriser;4=bloquer'
    foreach ($profileRow in @($Profiles.Rows)) {
        $name = Get-DomeniaReadingText $profileRow 'Name'
        $label = if ($labels.ContainsKey($name.ToLowerInvariant())) { $labels[$name.ToLowerInvariant()] } else { $name }
        $enabled = Get-DomeniaReadingNumber $profileRow 'Enabled'
        $isApplied = $false; $aliases = ''
        foreach ($key in @($applied.Keys)) { if ($key -ieq $name) { $isApplied = $true; $aliases = $applied[$key].ToArray() -join ', ' } }
        $value = Join-DomeniaReadingText @((Get-DomeniaReadingCode $enabled $gpo),('entrant par défaut : ' + (Get-DomeniaReadingCode (Get-DomeniaReadingNumber $profileRow 'DefaultInboundAction') $action)),('sortant par défaut : ' + (Get-DomeniaReadingCode (Get-DomeniaReadingNumber $profileRow 'DefaultOutboundAction') $action)),$(if ($isApplied) { 'appliqué à ' + $aliases } else { '' }))
        $hint = if ($isApplied -and ($enabled -eq 0)) { 'Pare-feu désactivé sur un réseau actif dans ce magasin : vérifier la stratégie effective dans lʼinventaire complet.' } else { '' }
        Add-DomeniaReadingFact $facts ('Profil ' + $label) $value 'Constate' 'MSFT_NetFirewallProfile' 'Magasin local persistant : une stratégie de groupe peut lʼemporter ; lʼorigine se lit dans lʼinventaire complet.' $hint $Profiles.CheckedUtc
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 99: BitLocker, TPM and boot security
function Get-DomeniaProtectionReading {
    # Encryption and protection are two facts: an encrypted volume with suspended protection is not protected.
    # TPM states are those at provider start-up; Secure Boot availability for VBS is not its activation.
    param($Volumes,$Tpm,$Guard)
    $facts = New-Object System.Collections.Generic.List[object]
    $conversion = '0=non chiffré;1=entièrement chiffré;2=chiffrement en cours;3=déchiffrement en cours;4=chiffrement en pause;5=déchiffrement en pause'
    $method = '0=aucune;1=AES 128 avec diffuseur;2=AES 256 avec diffuseur;3=AES 128;4=AES 256;5=chiffrement matériel;6=XTS-AES 128;7=XTS-AES 256'
    if ($Volumes.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Volumes 'BitLocker' 'Win32_EncryptableVolume' }
    elseif (-not @($Volumes.Rows).Count) { Add-DomeniaReadingFact $facts 'BitLocker' 'Aucun volume chiffrable renvoyé' 'Inconnu' 'Win32_EncryptableVolume' 'Fournisseur BitLocker absent ou lecture sans droits administrateur.' '' $Volumes.CheckedUtc }
    else {
        foreach ($volume in @($Volumes.Rows)) {
            $letter = Get-DomeniaReadingText $volume 'DriveLetter'; if (-not $letter) { $letter = 'volume sans lettre' }
            $protection = Get-DomeniaReadingNumber $volume 'ProtectionStatus'; $state = Get-DomeniaReadingNumber $volume 'ConversionStatus'
            $methodText = Get-DomeniaReadingCode (Get-DomeniaReadingNumber $volume 'EncryptionMethod') $method
            $title = 'BitLocker ' + $letter
            $source = 'Win32_EncryptableVolume'
            $limit = 'Valeurs à lʼinstanciation du fournisseur ; aucune clé ni protecteur nʼest lu.'
            if ($protection -eq 2) { Add-DomeniaReadingFact $facts $title ('Protection inconnue (volume verrouillé ?) · ' + (Get-DomeniaReadingCode $state $conversion)) 'Inconnu' $source $limit '' $Volumes.CheckedUtc }
            elseif (($state -eq 1) -and ($protection -eq 1)) { Add-DomeniaReadingFact $facts $title ('Chiffré et protégé (' + $methodText + ')') 'Constate' $source $limit '' $Volumes.CheckedUtc }
            elseif (($state -eq 1) -and ($protection -eq 0)) { Add-DomeniaReadingFact $facts $title ('Chiffré, protection suspendue (' + $methodText + ')') 'Constate' $source $limit 'Tant que la protection reste suspendue, la clé du volume est accessible sans protecteur.' $Volumes.CheckedUtc }
            elseif (($state -eq 0) -and ($protection -eq 0)) { Add-DomeniaReadingFact $facts $title 'Non chiffré' 'Constate' $source $limit $(if ($letter -ieq 'C:') { 'Volume système non chiffré.' } else { '' }) $Volumes.CheckedUtc }
            elseif ($null -ne $state) { Add-DomeniaReadingFact $facts $title ((Get-DomeniaReadingCode $state $conversion) + ' · protection ' + $(if ($protection -eq 1) { 'active' } elseif ($protection -eq 0) { 'inactive' } else { 'non renseignée' })) 'Constate' $source $limit $(if ($state -in @(4,5)) { 'Conversion en pause : à reprendre ou terminer.' } else { '' }) $Volumes.CheckedUtc }
            else { Add-DomeniaReadingFact $facts $title 'État de conversion non renvoyé' 'Inconnu' $source $limit '' $Volumes.CheckedUtc }
        }
    }
    if ($Tpm.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Tpm 'TPM' 'Win32_Tpm' }
    elseif (-not @($Tpm.Rows).Count) { Add-DomeniaReadingFact $facts 'TPM' $(if ($Tpm.Complete) { 'Aucun TPM exposé' } else { 'Aucune valeur dans une lecture partielle' }) $(if ($Tpm.Complete) { 'Constate' } else { 'Inconnu' }) 'Win32_Tpm' 'TPM absent, désactivé dans le micrologiciel ou masqué.' '' $Tpm.CheckedUtc }
    else {
        $row = @($Tpm.Rows)[0]
        $spec = @((Get-DomeniaReadingText $row 'SpecVersion').Split(','))[0].Trim()
        $flags = Join-DomeniaReadingText @((Get-DomeniaReadingBoolText (Get-DomeniaReadingBool $row 'IsEnabled_InitialValue') 'activé' 'désactivé'),(Get-DomeniaReadingBoolText (Get-DomeniaReadingBool $row 'IsActivated_InitialValue') 'opérationnel' 'non opérationnel'),(Get-DomeniaReadingBoolText (Get-DomeniaReadingBool $row 'IsOwned_InitialValue') 'propriétaire défini' 'sans propriétaire'))
        Add-DomeniaReadingFact $facts 'TPM' (Join-DomeniaReadingText @($(if ($spec) { 'version ' + $spec } else { '' }),$flags)) 'Constate' 'Win32_Tpm' 'États relevés au démarrage du fournisseur (InitialValue), sans appel de méthode.' '' $Tpm.CheckedUtc
    }
    if ($Guard.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Guard 'Sécurité basée sur la virtualisation' 'Win32_DeviceGuard' }
    elseif (@($Guard.Rows).Count) {
        $row = @($Guard.Rows)[0]
        $running = @(ConvertTo-DomeniaReadingCodes (Get-DomeniaMemberValue $row 'SecurityServicesRunning') '0=aucun;1=Credential Guard;2=intégrité du code protégée par lʼhyperviseur;3=lancement sécurisé System Guard;4=mesure du micrologiciel SMM')
        $available = @(ConvertTo-DomeniaReadingCodes (Get-DomeniaMemberValue $row 'AvailableSecurityProperties') '')
        $value = Join-DomeniaReadingText @((Get-DomeniaReadingCode (Get-DomeniaReadingNumber $row 'VirtualizationBasedSecurityStatus') '0=VBS désactivée;1=VBS configurée, non exécutée;2=VBS en cours dʼexécution'),$(if ($running.Count) { 'services : ' + ($running -join ', ') } else { '' }),$(if ($available -contains 'code 2') { 'Secure Boot disponible pour VBS' } else { '' }))
        Add-DomeniaReadingFact $facts 'Sécurité basée sur la virtualisation' $value 'Constate' 'Win32_DeviceGuard' 'La disponibilité de Secure Boot pour VBS ne prouve pas son activation.' '' $Guard.CheckedUtc
    }
    Add-DomeniaReadingFact $facts 'Démarrage sécurisé (Secure Boot)' 'Activation non lisible par ces classes' 'Inconnu' 'Win32_DeviceGuard' 'Lʼétat réel se lit dans le registre par lʼinventaire du poste (BIOS et micrologiciel).'
    return $facts.ToArray()
}

# ---------------------------------------------------------------- point 95: process snapshot
function Get-DomeniaProcessSnapshotReading {
    # Largest working sets at the reading. No processor rate from a single snapshot: that needs two measures.
    param($Processes,[int]$Top=8)
    $facts = New-Object System.Collections.Generic.List[object]
    if ($Processes.State -ne 'Read') { Add-DomeniaReadingSourceFact $facts $Processes 'Processus' 'Win32_Process'; return $facts.ToArray() }
    $rows = @($Processes.Rows | Where-Object { $null -ne (Get-DomeniaReadingNumber $_ 'WorkingSetSize') } | Sort-Object { [double](Get-DomeniaReadingNumber $_ 'WorkingSetSize') } -Descending)
    Add-DomeniaReadingFact $facts 'Processus' ([string]@($Processes.Rows).Count + ' processus au relevé') 'Constate' 'Win32_Process' (Join-DomeniaReadingText @('Photographie : les processus évoluent pendant la lecture ; les lignes de commande ne sont pas collectées.',(Get-DomeniaReadingPartialText $Processes)) ' ') '' $Processes.CheckedUtc
    $parts = @($rows | Select-Object -First $Top | ForEach-Object { (Get-DomeniaReadingText $_ 'Name') + ' (PID ' + (Get-DomeniaReadingText $_ 'ProcessId') + ') ' + (Format-DomeniaReadingSize ([double](Get-DomeniaReadingNumber $_ 'WorkingSetSize'))) })
    if ($parts.Count) { Add-DomeniaReadingFact $facts 'Plus grande mémoire de travail' ($parts -join ' ; ') 'Constate' 'Win32_Process' 'Mémoire de travail au relevé, pas une consommation moyenne.' '' $Processes.CheckedUtc }
    Add-DomeniaReadingFact $facts 'Charge processeur par processus' 'Non mesurée par une photographie unique' 'Inconnu' 'Win32_Process' 'La charge sur un intervalle borné se mesure dans lʼinventaire complet du poste.'
    return $facts.ToArray()
}

# ---------------------------------------------------------------- dispatcher and grid rows
function Invoke-DomeniaReading {
    # One reading of one workstation. $Sources: probe id -> ConvertTo-DomeniaReadingSource; a missing id is "not read".
    # $Options: DiskFreeWarn, DiskFreeAlert (percent), BiosReferences (book), ServiceProfile (rows).
    param([Parameter(Mandatory=$true)][string]$Id,[hashtable]$Sources=@{},$Options=$null)
    $reading = @(Get-DomeniaReadingCatalog | Where-Object { $_.Id -ceq $Id })
    if ($reading.Count -ne 1) { throw ('Lecture interprétée inconnue : ' + $Id) }
    $source = { param([string]$ProbeId) if ($Sources.ContainsKey($ProbeId) -and ($null -ne $Sources[$ProbeId])) { return $Sources[$ProbeId] }; return (ConvertTo-DomeniaReadingSource -ProbeId $ProbeId -Entry $null) }
    $context = $null
    $facts = @()
    switch -CaseSensitive ($Id) {
        'memory' { $facts = Get-DomeniaMemoryReading (& $source 'hw.memorymodules') (& $source 'hw.memoryarrays') (& $source 'hw.memoryusage') }
        'volumes' {
            $warn = 20; $alert = 10
            $w = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $Options 'DiskFreeWarn' $null); if (($null -ne $w) -and ($w -ge 1) -and ($w -le 100)) { $warn = [int]$w }
            $a = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $Options 'DiskFreeAlert' $null); if (($null -ne $a) -and ($a -ge 1) -and ($a -le $warn)) { $alert = [int]$a }
            $facts = Get-DomeniaVolumeReading (& $source 'disk.volumes') -WarnPercent $warn -AlertPercent $alert
        }
        'storage' { $facts = Get-DomeniaStorageHealthReading (& $source 'disk.physical') (& $source 'disk.reliability') }
        'battery' { $facts = Get-DomeniaBatteryReading (& $source 'hw.batteries') (& $source 'hw.batterystatic') (& $source 'hw.batteryfullcharge') (& $source 'hw.batterycycles') }
        'bios' { $result = Get-DomeniaBiosReading (& $source 'hw.biosdetails') (& $source 'hw.computersystem') (Get-DomeniaMemberValue $Options 'BiosReferences'); $facts = $result.Facts; $context = $result.Context }
        'processor' { $facts = Get-DomeniaProcessorReading (& $source 'hw.processors') (& $source 'hw.computersystem') }
        'displays' { $facts = Get-DomeniaDisplayReading (& $source 'hw.monitors') (& $source 'hw.monitorconnections') (& $source 'hw.dockhints') }
        'network' { $facts = Get-DomeniaNetworkReading (& $source 'net.interfaces') (& $source 'net.configurations') }
        'devices' { $facts = Get-DomeniaDeviceReading (& $source 'soft.printerdetails') (& $source 'hw.deviceerrors') }
        'services' { $facts = Get-DomeniaServiceReading (& $source 'soft.servicedetails') (Get-DomeniaMemberValue $Options 'ServiceProfile') }
        'tasks' { $facts = Get-DomeniaTaskReading (& $source 'soft.scheduledtasks') (& $source 'soft.startupdetails') }
        'antivirus' { $facts = Get-DomeniaAntivirusReading (& $source 'sec.avproducts') (& $source 'sec.defenderdetails') }
        'firewall' { $facts = Get-DomeniaFirewallReading (& $source 'sec.firewallprofiles') (& $source 'net.connectionprofiles') }
        'protection' { $facts = Get-DomeniaProtectionReading (& $source 'sec.bitlockervolumes') (& $source 'sec.tpmdetails') (& $source 'sec.deviceguard') }
        'processes' { $facts = Get-DomeniaProcessSnapshotReading (& $source 'soft.processdetails') }
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($probeId in @($reading[0].Probes)) {
        $item = & $source $probeId
        if ([string]$item.AttemptError) { Add-DomeniaReadingFact $list ('Dernière tentative sur ' + $probeId) ('Non confirmée : ' + (ConvertTo-DomeniaFlatText ([string]$item.AttemptError) 160)) 'Indisponible' $probeId 'Les valeurs affichées viennent de la dernière réussite, à la date indiquée.' }
    }
    foreach ($fact in @($facts)) { if ($null -ne $fact) { $list.Add($fact) } }
    return [pscustomobject]@{ Id = $Id; Title = [string]$reading[0].Title; Probes = @($reading[0].Probes); Facts = $list.ToArray(); Context = $context }
}

function Get-DomeniaReadingStateLabel {
    param([string]$State)
    switch ($State) { 'Constate' { return 'Constaté' } 'Estime' { return 'Estimé' } 'Refuse' { return 'Refusé' } 'Indisponible' { return 'Indisponible' } default { return 'Inconnu' } }
}

function ConvertTo-DomeniaReadingRows {
    # Rows of the reading grid, French column names in reading order.
    param($Reading)
    foreach ($fact in @(Get-DomeniaMember $Reading 'Facts' @())) {
        [pscustomobject]@{ Point = [string]$fact.Fait; Valeur = [string]$fact.Valeur; Etat = (Get-DomeniaReadingStateLabel ([string]$fact.Etat)); Date = [string]$fact.Date; Source = [string]$fact.Source; Limite = [string]$fact.Limite; Piste = [string]$fact.Hypothese }
    }
}

# ---------------------------------------------------------------- full inventory rows (Category, Item, Value, Source)
function Get-DomeniaInventoryCategoryRows {
    param($Rows,[string]$Category)
    return @(@($Rows) | Where-Object { ($null -ne $_) -and ([string]$_.Category -ceq $Category) })
}

function Get-DomeniaPendingRebootReading {
    # Point 93. Since this lot the inventory writes one row per indicator ('Present (obligation confirmee)',
    # 'Present (indice partiel)', 'Absent', 'Non lu') and an 'Etat' row; older inventories kept the 'Etat' row only,
    # whose reasons are sorted here with the same rule. State: Required, Partial, None or Unknown (not read).
    param($Rows)
    $items = @(Get-DomeniaInventoryCategoryRows $Rows 'Redemarrage en attente')
    $confirmed = New-Object System.Collections.Generic.List[string]
    $partial = New-Object System.Collections.Generic.List[string]
    $unread = New-Object System.Collections.Generic.List[string]
    $indicators = @($items | Where-Object { [string]$_.Item -cne 'Etat' })
    $legacy = $false
    foreach ($row in $indicators) {
        $value = [string]$row.Value
        if ($value -like 'Present (obligation confirmee)*') { $confirmed.Add([string]$row.Item) }
        elseif ($value -like 'Present (indice partiel)*') { $partial.Add([string]$row.Item) }
        elseif ($value -cne 'Absent') { $unread.Add([string]$row.Item) }
    }
    $stateRow = @($items | Where-Object { [string]$_.Item -ceq 'Etat' } | Select-Object -First 1)
    if ((-not $indicators.Count) -and $stateRow.Count) {
        $legacy = $true
        $text = [string]$stateRow[0].Value
        if ($text -match '^Redemarrage requis : (.+)$') {
            foreach ($reason in @($Matches[1].Split(','))) {
                $name = $reason.Trim()
                if (-not $name) { continue }
                if ($name -in @('Maintenance de composants','Windows Update')) { $confirmed.Add($name) } else { $partial.Add($name) }
            }
        }
    }
    $read = ($indicators.Count -gt 0) -or ($stateRow.Count -gt 0)
    $state = if (-not $read) { 'Unknown' } elseif ($confirmed.Count) { 'Required' } elseif ($partial.Count) { 'Partial' } else { 'None' }
    $detail = switch ($state) {
        'Required' { 'Confirmé par : ' + ($confirmed.ToArray() -join ', ') + $(if ($partial.Count) { ' · indices partiels : ' + ($partial.ToArray() -join ', ') } else { '' }) }
        'Partial' { 'Indices partiels : ' + ($partial.ToArray() -join ', ') + ' (pas une obligation à eux seuls)' }
        'None' { 'Aucun indice parmi les sources lues' + $(if ($unread.Count) { ' · non lu : ' + ($unread.ToArray() -join ', ') } else { '' }) }
        default { 'Non lu pendant cet inventaire' }
    }
    if ($legacy -and ($state -ne 'Unknown')) { $detail += ' · inventaire antérieur : indices reclassés depuis son texte' }
    return [pscustomobject]@{ State = $state; Confirmed = $confirmed.ToArray(); Partial = $partial.ToArray(); Unread = $unread.ToArray(); Detail = $detail; Legacy = $legacy }
}

function Get-DomeniaAppliedFirewallProfiles {
    # Point 98: profile row name ('Profil domaine', 'Profil prive', 'Profil public') -> interfaces it is applied to,
    # from the 'Profil applique a <interface>' rows of the inventory. Empty when the connections were not read.
    param($Rows)
    $applied = @{}
    $names = @{ 'Domaine' = 'Profil domaine'; 'Prive' = 'Profil prive'; 'Public' = 'Profil public' }
    foreach ($row in @(Get-DomeniaInventoryCategoryRows $Rows 'Pare-feu')) {
        $item = [string]$row.Item
        if (-not $item.StartsWith('Profil applique a ',[StringComparison]::Ordinal)) { continue }
        $category = ([string]$row.Value).Split(' ')[0]
        if (-not $names.ContainsKey($category)) { continue }
        $profileName = [string]$names[$category]
        if (-not $applied.ContainsKey($profileName)) { $applied[$profileName] = New-Object System.Collections.Generic.List[string] }
        $applied[$profileName].Add($item.Substring(18))
    }
    return $applied
}

function Get-DomeniaBitLockerInventoryState {
    # Point 99: protection and encryption of one volume from the 'BitLocker' rows. An encrypted volume whose
    # protection is off is suspended, not unencrypted; a volume read before this lot has no encryption row.
    param($Rows,[string]$Volume='Volume C:')
    $rows = @(Get-DomeniaInventoryCategoryRows $Rows 'BitLocker')
    $protectionRow = @($rows | Where-Object { [string]$_.Item -ceq $Volume } | Select-Object -First 1)
    $conversionRow = @($rows | Where-Object { [string]$_.Item -ceq ($Volume + ' chiffrement') } | Select-Object -First 1)
    if (-not $protectionRow.Count) { return [pscustomobject]@{ Read = $false; Protected = $null; Suspended = $false; Encryption = ''; Text = '' } }
    $protectionText = [string]$protectionRow[0].Value
    $protected = $null
    if ($protectionText -ceq 'Protection Active') { $protected = $true } elseif ($protectionText -ceq 'Protection Desactive') { $protected = $false }
    $encryption = if ($conversionRow.Count) { [string]$conversionRow[0].Value } else { '' }
    $suspended = (($protected -eq $false) -and ($encryption -ceq 'Entierement chiffre'))
    $text = if ($protected -eq $true) { 'Protégé' + $(if ($encryption -and ($encryption -cne 'Entierement chiffre')) { ' (' + $encryption + ')' } else { '' }) } elseif ($suspended) { 'Chiffré, protection suspendue' } elseif (($protected -eq $false) -and ($encryption -ceq 'Non chiffre')) { 'Non chiffré' } elseif ($protected -eq $false) { 'Non protégé' + $(if ($encryption) { ' (' + $encryption + ')' } else { '' }) } else { 'État inconnu' }
    return [pscustomobject]@{ Read = $true; Protected = $protected; Suspended = $suspended; Encryption = $encryption; Text = $text }
}

function Get-DomeniaSecureBootInventoryState {
    # Point 99: Secure Boot state written by Windows in the registry (UEFISecureBootEnabled) and the firmware type.
    param($Rows)
    $rows = @(Get-DomeniaInventoryCategoryRows $Rows 'BIOS et firmware')
    $secure = @($rows | Where-Object { [string]$_.Item -ceq 'Secure Boot' } | Select-Object -First 1)
    $firmware = @($rows | Where-Object { [string]$_.Item -ceq 'Type de firmware' } | Select-Object -First 1)
    $firmwareText = if ($firmware.Count) { [string]$firmware[0].Value } else { '' }
    if (-not $secure.Count) { return [pscustomobject]@{ Read = $false; Enabled = $null; Text = ''; Detail = '' } }
    $value = [string]$secure[0].Value
    $enabled = $null; $text = 'Non exposé'
    if ($value -ceq 'Active') { $enabled = $true; $text = 'Activé' }
    elseif ($value -ceq 'Desactive') { $enabled = $false; $text = 'Désactivé' }
    elseif ($value -like 'Cle presente*') { $text = 'Valeur non lisible' }
    $detail = Join-DomeniaReadingText @('Registre SecureBoot\State',$(if ($firmwareText) { 'micrologiciel ' + $firmwareText } else { '' }))
    return [pscustomobject]@{ Read = $true; Enabled = $enabled; Text = $text; Detail = $detail }
}

function Get-DomeniaCertificateReading {
    # Point 100: expiry of the computer certificates read in the registry store (Personal store only). Expired,
    # expiring within SoonDays, or valid; nothing is exported and the private key is never read.
    param($Certificates,[Parameter(Mandatory=$true)][datetime]$NowUtc,[int]$SoonDays=30)
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    if ($null -eq $Certificates) { return [pscustomobject]@{ Read = $false; Total = 0; Expired = @(); Soon = @(); Valid = 0; Facts = @(); Truncated = $false; StoreCount = $null } }
    $facts = New-Object System.Collections.Generic.List[object]
    # A read cut short (more than 50 certificates, or the collector budget) lists part of the store only.
    $truncated = [bool](Get-DomeniaMember $Certificates 'Truncated' $false)
    $storeCount = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $Certificates 'StoreCount' $null)
    $expired = New-Object System.Collections.Generic.List[string]; $soon = New-Object System.Collections.Generic.List[string]; $valid = 0; $total = 0
    $source = [string](Get-DomeniaMember $Certificates 'Source' 'Registre')
    foreach ($item in @(Get-DomeniaMember $Certificates 'Items' @())) {
        $total++
        $subject = [string](Get-DomeniaMember $item 'Subject' ''); if (-not $subject) { $subject = 'Sujet non renseigné' }
        $end = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $item 'NotAfterUtc' $null)
        $usages = @(@(Get-DomeniaMember $item 'Usages' @()) | ForEach-Object { [string]$_ })
        $details = Join-DomeniaReadingText @(('émetteur ' + [string](Get-DomeniaMember $item 'Issuer' '')),$(if ($usages.Count) { 'usages : ' + ($usages -join ', ') } else { '' }),$(if ([bool](Get-DomeniaMember $item 'KeyDeclared' $false)) { 'clé privée associée déclarée (non lue)' } else { '' }),('empreinte ' + [string](Get-DomeniaMember $item 'Thumbprint' '')))
        if ($null -eq $end) { Add-DomeniaReadingFact $facts ('Certificat ' + $subject) ('Échéance illisible · ' + $details) 'Inconnu' $source ''; continue }
        $days = [int][Math]::Floor(($end - $now).TotalDays)
        $when = $end.ToLocalTime().ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture)
        if ($end -le $now) { $expired.Add($subject); Add-DomeniaReadingFact $facts ('Certificat ' + $subject) ('Expiré le ' + $when + ' · ' + $details) 'Constate' $source 'Magasin Personnel de lʼordinateur.' 'Certificat expiré : le renouveler, ou le retirer sʼil nʼest plus utilisé.' }
        elseif ($days -le $SoonDays) { $soon.Add($subject); Add-DomeniaReadingFact $facts ('Certificat ' + $subject) ('Expire le ' + $when + ' (dans ' + [string]$days + ' jour(s)) · ' + $details) 'Constate' $source 'Magasin Personnel de lʼordinateur.' 'Échéance proche : vérifier le renouvellement automatique.' }
        else { $valid++; Add-DomeniaReadingFact $facts ('Certificat ' + $subject) ('Valide jusquʼau ' + $when + ' · ' + $details) 'Constate' $source 'Magasin Personnel de lʼordinateur.' '' }
    }
    if ($truncated) { Add-DomeniaReadingFact $facts 'Lecture du magasin Personnel' ('Partielle : ' + [string]$total + ' certificat(s) lu(s)' + $(if ($null -ne $storeCount) { ' sur ' + [string][int]$storeCount } else { '' })) 'Inconnu' $source 'Les certificats non lus ne sont ni comptés ni déclarés valides.' }
    return [pscustomobject]@{ Read = $true; Total = $total; Expired = $expired.ToArray(); Soon = $soon.ToArray(); Valid = $valid; Facts = $facts.ToArray(); Truncated = $truncated; StoreCount = $(if ($null -ne $storeCount) { [int]$storeCount } else { $null }) }
}

function Measure-DomeniaProcessLoad {
    # Point 95: processor share of each process between two reads of Win32_Process taken IntervalMs apart.
    # Share = processor time used meanwhile / (interval x logical processors). A process started, ended or whose
    # identifier was reused during the interval has no share; nothing is extrapolated. The idle pseudo-process (PID 0)
    # counts the unused processor time: it is neither a consumer nor part of the measured total.
    param($Sample,[int]$Top=10)
    $interval = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $Sample 'IntervalMs' $null)
    $logical = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $Sample 'LogicalProcessors' $null)
    $result = [ordered]@{ Measured = $false; Reason = ''; IntervalMs = $interval; SampledUtc = (ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Sample 'SampledUtc' $null)); LogicalProcessors = $logical; Items = @(); TotalPercent = $null; Unmatched = 0; Truncated = [bool](Get-DomeniaMember $Sample 'Truncated' $false) }
    if ($null -eq $Sample) { $result.Reason = 'Aucune mesure sur intervalle dans cet inventaire.'; return [pscustomobject]$result }
    if (($null -eq $interval) -or ($interval -lt 500)) { $result.Reason = 'Intervalle de mesure absent ou trop court.'; return [pscustomobject]$result }
    if (($null -eq $logical) -or ($logical -lt 1)) { $result.Reason = 'Nombre de processeurs logiques non lu : part de processeur non calculable.'; return [pscustomobject]$result }
    $items = New-Object System.Collections.Generic.List[object]; $total = 0.0; $unmatched = 0
    foreach ($item in @(Get-DomeniaMember $Sample 'Items' @())) {
        $processId = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $item 'Pid' $null)
        if ((($null -ne $processId) -and ($processId -eq 0)) -or ([string](Get-DomeniaMember $item 'Name' '') -in @('System Idle Process','Idle'))) { continue }
        $first = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $item 'FirstTime' $null)
        $second = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $item 'SecondTime' $null)
        if (($null -eq $first) -or ($null -eq $second) -or ($second -lt $first)) { $unmatched++; continue }
        $percent = 100.0 * ($second - $first) / ($interval * 10000.0 * $logical)
        $total += $percent
        $workingSet = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $item 'WorkingSet' $null)
        $items.Add([pscustomobject]@{ Name = [string](Get-DomeniaMember $item 'Name' ''); Pid = (Get-DomeniaMember $item 'Pid' $null); Percent = [Math]::Round($percent,1); WorkingSetMb = $(if ($null -ne $workingSet) { [Math]::Round($workingSet / 1MB) } else { $null }) })
    }
    $result.Measured = $true
    $result.Items = @($items.ToArray() | Sort-Object { [double]$_.Percent } -Descending | Select-Object -First $Top)
    $result.TotalPercent = [Math]::Round($total,1)
    $result.Unmatched = $unmatched
    return [pscustomobject]$result
}

function Get-DomeniaUpdateReading {
    # Point 92: version (build and revision), CBS hotfixes, Windows Update results and the configured source, each
    # with its source. Compliance is never concluded: Win32_QuickFixEngineering does not list every update.
    param($Rows,[object[]]$Hotfixes=@(),[Parameter(Mandatory=$true)][datetime]$NowUtc)
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $facts = New-Object System.Collections.Generic.List[object]
    $system = @(Get-DomeniaInventoryCategoryRows $Rows 'Systeme d exploitation')
    $value = { param([object[]]$List,[string]$Item) $found = @($List | Where-Object { [string]$_.Item -ceq $Item } | Select-Object -First 1); if ($found.Count) { return ([string]$found[0].Value).Trim() }; return '' }
    $build = & $value $system 'Build'; $revision = & $value $system 'Revision de build'; $display = & $value $system 'Version commerciale'
    $version = ''
    if ($build) { $version = 'Build ' + $build + $(if ($revision -match '^\d+$') { '.' + $revision } else { '' }) }
    if ($version) { Add-DomeniaReadingFact $facts 'Version installée' (Join-DomeniaReadingText @($display,$version)) 'Constate' 'Win32_OperatingSystem, registre CurrentVersion (UBR)' 'La révision de build reflète la dernière mise à jour cumulative installée ; sans référence approuvée, aucune conformité nʼest conclue.' }
    else { Add-DomeniaReadingFact $facts 'Version installée' 'Build non lu' 'Inconnu' 'Win32_OperatingSystem' '' }
    $latest = $null; $count = 0
    foreach ($text in @($Hotfixes)) {
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$text,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) { $count++; if (($null -eq $latest) -or ($date -gt $latest)) { $latest = $date } }
    }
    if ($null -ne $latest) { Add-DomeniaReadingFact $facts 'Correctifs CBS' ([string]$count + ' correctif(s) daté(s), le plus récent installé le ' + $latest.ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture)) 'Constate' 'Win32_QuickFixEngineering' 'Vue de la maintenance des composants seulement : elle ne couvre pas toutes les mises à jour Windows ni les produits MSI.' }
    else { Add-DomeniaReadingFact $facts 'Correctifs CBS' 'Aucune date de correctif lisible' 'Inconnu' 'Win32_QuickFixEngineering' 'Une liste vide ou non datée ne prouve ni lʼabsence ni la présence de mises à jour.' }
    $update = @(Get-DomeniaInventoryCategoryRows $Rows 'Windows Update')
    foreach ($pair in @(@('Derniere recherche','Dernière recherche'),@('Dernier telechargement','Dernier téléchargement'),@('Derniere installation','Dernière installation'))) {
        $raw = & $value $update ([string]$pair[0])
        if (-not $raw) { continue }
        $at = ConvertTo-DomeniaUtcDate $raw
        $age = if ($null -ne $at) { [int][Math]::Floor(($now - $at).TotalDays) } else { $null }
        Add-DomeniaReadingFact $facts ([string]$pair[1] + ' Windows Update') $(if ($null -ne $at) { $at.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture) + ' (il y a ' + [string]$age + ' j)' } else { $raw }) 'Constate' 'Registre WindowsUpdate\Auto Update\Results' 'Clé historique que les versions récentes de Windows ne tiennent plus toujours à jour.' $(if (($null -ne $age) -and ($age -gt 30)) { 'Information de plus de 30 jours : lʼétat actuel nʼest pas connu.' } else { '' })
    }
    $server = & $value $update 'Serveur WSUS'; $policy = & $value $update 'Strategie WSUS appliquee'
    $sourceText = if ($server -and ($policy -ceq 'Oui')) { 'WSUS ' + $server } elseif ($server -and ($policy -ceq 'Non')) { 'Windows Update (adresse WSUS ' + $server + ' déclarée mais non appliquée)' } elseif ($server) { 'WSUS ' + $server + ' (application de la stratégie non lue)' } elseif ($update.Count) { 'Windows Update, aucun serveur WSUS configuré' } else { '' }
    if ($sourceText) { Add-DomeniaReadingFact $facts 'Source des mises à jour' $sourceText 'Constate' 'Registre Policies\WindowsUpdate' 'Configuration lue, pas un contact avec le serveur.' }
    else { Add-DomeniaReadingFact $facts 'Source des mises à jour' 'Non lue' 'Inconnu' 'Registre Policies\WindowsUpdate' '' }
    Add-DomeniaReadingFact $facts 'Conformité des mises à jour' 'Non évaluée' 'Inconnu' 'Domenia' 'Ni les correctifs CBS ni les dates Windows Update ne prouvent quʼun poste a reçu toutes les mises à jour attendues.'
    $detail = Join-DomeniaReadingText @($(if ($null -ne $latest) { 'dernier correctif CBS le ' + $latest.ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture) } else { '' }),$sourceText)
    return [pscustomobject]@{ Read = [bool]$version; Version = $(if ($version) { Join-DomeniaReadingText @($display,$version) } else { '' }); Detail = $detail; Facts = $facts.ToArray() }
}
