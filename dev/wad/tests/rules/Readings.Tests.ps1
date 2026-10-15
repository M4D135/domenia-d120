# Points 81 to 100 : lectures interpretees du poste (Domenia-Readings.Model.ps1) et historique borne des sondes
# (Add-DomeniaProbeHistory, Domenia-Probes.Model.ps1). Valeurs fictives uniquement : aucun reseau, aucun disque.
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
. (Join-Path $modules 'Domenia-Readings.Model.ps1')
# The catalog cache of Probes.Model starts empty (StrictMode of this runner: the variable must exist).
$script:DomeniaProbeCatalog = $null
function New-RdgSource {
    param([string]$ProbeId,[object[]]$Values=@(),[string]$CheckedUtc='2026-10-14T10:00:00Z',[switch]$Truncated,$History=$null)
    $instances = @(for ($i = 0; $i -lt $Values.Count; $i++) { [pscustomobject]@{ Id = ''; Index = ($i + 1); Values = $Values[$i]; IncompleteProperties = @() } })
    $entry = [pscustomobject]@{ CheckedUtc = $CheckedUtc; Truncated = [bool]$Truncated; Instances = $instances }
    if ($null -ne $History) { $entry | Add-Member -NotePropertyName History -NotePropertyValue @($History) }
    return (ConvertTo-DomeniaReadingSource -ProbeId $ProbeId -Entry $entry)
}
function Get-RdgFact {
    param([object[]]$Facts,[string]$Name)
    $found = @($Facts | Where-Object { [string]$_.Fait -ceq $Name })
    if ($found.Count -ne 1) { throw ('Fait attendu une fois : ' + $Name + ' (' + $found.Count + ') parmi : ' + ((@($Facts) | ForEach-Object { [string]$_.Fait }) -join ' | ')) }
    return $found[0]
}
function New-RdgCodes {
    param([string]$Text,[int]$Length=16)
    $codes = New-Object System.Collections.Generic.List[object]
    foreach ($ch in $Text.ToCharArray()) { $codes.Add([int]$ch) }
    while ($codes.Count -lt $Length) { $codes.Add(0) }
    return ,($codes.ToArray())
}
function New-RdgRow { param([string]$Category,[string]$Item,[string]$Value) return [pscustomobject]@{ Category = $Category; Item = $Item; Value = $Value; Source = 'test' } }

Test-Case -Id 'RDG-001' -Name 'Points 81-99 : chaque lecture cite des requetes du catalogue et se retrouve depuis ses sondes' -Body {
    foreach ($reading in @(Get-DomeniaReadingCatalog)) {
        foreach ($probeId in @(@($reading.Probes) + @($reading.Related))) { Assert-True ($null -ne (Get-DomeniaProbe $probeId)) ('Requete absente du catalogue : ' + $probeId) }
    }
    Assert-Equal 'memory' ([string](Get-DomeniaReadingForProbe 'hw.memoryarrays').Id)
    Assert-Equal 'memory' ([string](Get-DomeniaReadingForProbe 'hw.ram').Id) 'sonde historique rattachee a la lecture'
    Assert-Equal 'bios' ([string](Get-DomeniaReadingForProbe 'hw.computersystem').Id) 'premiere lecture qui lit la sonde'
    Assert-True ($null -eq (Get-DomeniaReadingForProbe 'user.console')) 'sonde sans lecture interpretee'
    Assert-Throws { Invoke-DomeniaReading -Id 'inconnue' } 'lecture inconnue refusee'
}
Test-Case -Id 'RDG-002' -Name 'Source de lecture : lignes typees, anciennes lignes, refus, fournisseur absent et lecture partielle' -Body {
    $read = New-RdgSource 'disk.volumes' @([pscustomobject]@{ DeviceID = 'C:'; Size = 100; FreeSpace = 10 })
    Assert-Equal 'Read' $read.State
    Assert-True $read.Complete
    Assert-Equal 'C:' ([string]@($read.Rows)[0].DeviceID)
    $legacy = ConvertTo-DomeniaReadingSource -ProbeId 'x' -Entry ([pscustomobject]@{ CheckedUtc = '2026-10-01T00:00:00Z'; Properties = @('A','B'); Rows = @(,@('1','2')) })
    Assert-Equal '2' ([string]@($legacy.Rows)[0].B) 'colonnes nommees par le schema conserve'
    Assert-Equal 'Refused' (ConvertTo-DomeniaReadingSource -ProbeId 'x' -Entry ([pscustomobject]@{ Error = 'Access is denied. 0x80070005' })).State
    Assert-Equal 'Absent' (ConvertTo-DomeniaReadingSource -ProbeId 'x' -Entry ([pscustomobject]@{ Error = 'Invalid class' })).State
    Assert-Equal 'Failed' (ConvertTo-DomeniaReadingSource -ProbeId 'x' -Entry ([pscustomobject]@{ Error = 'Le serveur RPC nʼest pas disponible' })).State
    Assert-Equal 'NotRead' (ConvertTo-DomeniaReadingSource -ProbeId 'x' -Entry $null).State
    Assert-False (New-RdgSource 'x' @([pscustomobject]@{ A = 1 }) -Truncated).Complete 'lecture partielle'
}
Test-Case -Id 'RDG-081' -Name 'Point 81 : capacite des barrettes, emplacements, maximum et utilisation instantanee distincts' -Body {
    $modules = New-RdgSource 'hw.memorymodules' @([pscustomobject]@{ DeviceLocator = 'DIMM A'; Capacity = 8589934592; ConfiguredClockSpeed = 3200 }, [pscustomobject]@{ DeviceLocator = 'DIMM B'; Capacity = 8589934592; ConfiguredClockSpeed = 3200 })
    $arrays = New-RdgSource 'hw.memoryarrays' @([pscustomobject]@{ MemoryDevices = 4; MaxCapacityEx = 67108864 })
    $usage = New-RdgSource 'hw.memoryusage' @([pscustomobject]@{ TotalVisibleMemorySize = 16000000; FreePhysicalMemory = 4000000 })
    $facts = @(Get-DomeniaMemoryReading $modules $arrays $usage)
    Assert-True ([string](Get-RdgFact $facts 'Mémoire installée (barrettes)').Valeur -like '16 Go en 2 barrette(s)*') 'capacite installee'
    Assert-Equal '4 emplacement(s) : 2 occupé(s), 2 libre(s)' ([string](Get-RdgFact $facts 'Emplacements mémoire').Valeur)
    Assert-Equal '64 Go' ([string](Get-RdgFact $facts 'Capacité maximale déclarée').Valeur)
    $used = Get-RdgFact $facts 'Mémoire utilisée au relevé'
    Assert-True ([string]$used.Valeur -like '75 %*') ([string]$used.Valeur)
    Assert-True ([string]$used.Limite -like '*instantanée*') 'mesure instantanee annoncee'
    Assert-True ([string]$used.Date) 'mesure datee'
    Assert-True ([string](Get-RdgFact $facts 'Mémoire visible par Windows').Hypothese -like '*réservés*') 'part reservee au materiel'
    $vm = @(Get-DomeniaMemoryReading (New-RdgSource 'hw.memorymodules' @()) (ConvertTo-DomeniaReadingSource -ProbeId 'hw.memoryarrays' -Entry $null) $usage)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $vm 'Mémoire installée (barrettes)').Etat) 'machine virtuelle : capacite materielle inconnue'
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $vm 'Emplacements et capacité maximale').Etat) 'tables non relevees'
    $partial = @(Get-DomeniaMemoryReading (New-RdgSource 'hw.memorymodules' @([pscustomobject]@{ DeviceLocator = 'A'; Capacity = 0 }, [pscustomobject]@{ DeviceLocator = 'B'; Capacity = 4294967296 })) $arrays $usage)
    Assert-Equal 'Estime' ([string](Get-RdgFact $partial 'Mémoire installée (barrettes)').Etat) 'capacite inconnue : total minimal'
    # Review: a flash or video array (Use other than 3) declares no RAM slot and no RAM maximum.
    $mixed = New-RdgSource 'hw.memoryarrays' @([pscustomobject]@{ MemoryDevices = 4; MaxCapacityEx = 67108864; Use = 3 }, [pscustomobject]@{ MemoryDevices = 2; MaxCapacityEx = 16384; Use = 5 })
    $withFlash = @(Get-DomeniaMemoryReading $modules $mixed $usage)
    Assert-Equal '4 emplacement(s) : 2 occupé(s), 2 libre(s)' ([string](Get-RdgFact $withFlash 'Emplacements mémoire').Valeur) 'groupe flash compte comme emplacement'
    Assert-Equal '64 Go' ([string](Get-RdgFact $withFlash 'Capacité maximale déclarée').Valeur) 'groupe flash ajoute au maximum'
    $flashOnly = @(Get-DomeniaMemoryReading $modules (New-RdgSource 'hw.memoryarrays' @([pscustomobject]@{ MemoryDevices = 2; MaxCapacityEx = 16384; Use = 5 })) $usage)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $flashOnly 'Emplacements et capacité maximale').Etat) 'aucun groupe systeme : emplacements inconnus'
}
Test-Case -Id 'RDG-082' -Name 'Point 82 : prevision seulement avec un historique suffisant, regulier et de taille constante' -Body {
    $base = [datetime]::SpecifyKind([datetime]'2026-09-01T12:00:00',[DateTimeKind]::Utc)
    $make = { param([double[]]$Free,[double[]]$Size) for ($i = 0; $i -lt $Free.Count; $i++) { [pscustomobject]@{ AtUtc = $base.AddDays(5 * $i).ToString('o'); Size = $Size[[Math]::Min($i,$Size.Count - 1)] * 1GB; Free = $Free[$i] * 1GB } } }
    Assert-Equal 'Insufficient' ([string](Get-DomeniaVolumeSaturationForecast -Samples @(& $make @(30,25,20) @(100))).Status) 'trois releves'
    $forecast = Get-DomeniaVolumeSaturationForecast -Samples @(& $make @(30,25,20,15,10) @(100))
    Assert-Equal 'Forecast' ([string]$forecast.Status)
    Assert-True (([double]$forecast.DaysLeft -gt 9.99) -and ([double]$forecast.DaysLeft -lt 10.01)) ('jours restants : ' + $forecast.DaysLeft)
    Assert-Equal '2026-10-01' ($forecast.SaturationUtc.ToString('yyyy-MM-dd'))
    Assert-Equal 'SizeChanged' ([string](Get-DomeniaVolumeSaturationForecast -Samples @(& $make @(30,25,20,15,10) @(100,100,200))).Status)
    Assert-Equal 'Stable' ([string](Get-DomeniaVolumeSaturationForecast -Samples @(& $make @(30,30,30,30,30) @(100))).Status)
    Assert-Equal 'Irregular' ([string](Get-DomeniaVolumeSaturationForecast -Samples @(& $make @(30,10,29,11,28) @(100))).Status)
    $history = @(
        [pscustomobject]@{ AtUtc = $base.ToString('o'); Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 30GB }) },
        [pscustomobject]@{ AtUtc = $base.AddDays(5).ToString('o'); Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 25GB }) },
        [pscustomobject]@{ AtUtc = $base.AddDays(10).ToString('o'); Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 20GB }) },
        [pscustomobject]@{ AtUtc = $base.AddDays(15).ToString('o'); Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 15GB }) })
    $volumes = New-RdgSource 'disk.volumes' @([pscustomobject]@{ DeviceID = 'C:'; VolumeName = 'Système'; FileSystem = 'NTFS'; Size = 100GB; FreeSpace = 10GB }) -CheckedUtc $base.AddDays(20).ToString('o') -History $history
    $facts = @(Get-DomeniaVolumeReading $volumes)
    $prediction = Get-RdgFact $facts 'Prévision de saturation de C:'
    Assert-Equal 'Estime' ([string]$prediction.Etat)
    Assert-True ([string]$prediction.Valeur -like 'Saturation estimée vers le *') ([string]$prediction.Valeur)
    Assert-True ([string](Get-RdgFact $facts 'Volume C: (Système)').Hypothese -like 'Espace faible*') 'seuil de surveillance'
    $alone = @(Get-DomeniaVolumeReading (New-RdgSource 'disk.volumes' @([pscustomobject]@{ DeviceID = 'D:'; Size = 100GB; FreeSpace = 5GB })) -AlertPercent 10)
    $none = Get-RdgFact $alone 'Prévision de saturation de D:'
    Assert-Equal 'Inconnu' ([string]$none.Etat) 'aucune prevision chiffree sans historique'
    Assert-True ([string]$none.Valeur -like 'Aucune prévision : 1 relevé(s)*') ([string]$none.Valeur)
}
Test-Case -Id 'RDG-082B' -Name 'Point 82 : historique borne dans la charge enregistree, sans modifier le lot entrant' -Body {
    $entry = { param([string]$At,[double]$Free,[switch]$Truncated) [pscustomobject]@{ CheckedUtc = $At; Truncated = [bool]$Truncated; Instances = @([pscustomobject]@{ Id = ''; Index = 1; Values = [pscustomobject]@{ DeviceID = 'c:'; Size = 100GB; FreeSpace = $Free } }) } }
    $data = [pscustomobject]@{ Computer = 'PC'; Probes = [pscustomobject]@{ 'disk.volumes' = (& $entry '2026-10-10T12:00:00Z' 40GB) } }
    $old = @(
        [pscustomobject]@{ AtUtc = '2026-10-01T12:00:00Z'; Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 50GB }) },
        [pscustomobject]@{ AtUtc = '2026-10-05T12:00:00Z'; Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 45GB }) },
        [pscustomobject]@{ AtUtc = '2026-10-06T12:00:00Z'; Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 150GB }) },
        [pscustomobject]@{ AtUtc = '2026-10-11T12:00:00Z'; Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 30GB }) })
    $previousEntry = & $entry '2026-10-05T12:00:00Z' 45GB
    $previousEntry | Add-Member -NotePropertyName History -NotePropertyValue $old
    $previous = [pscustomobject]@{ Computer = 'PC'; Probes = [pscustomobject]@{ 'disk.volumes' = $previousEntry } }
    $merged = Add-DomeniaProbeHistory -Data $data -PreviousData $previous -ProbeId 'disk.volumes'
    $history = @($merged.Probes.'disk.volumes'.History)
    Assert-Equal 3 $history.Count 'echantillon incoherent et echantillon posterieur retires'
    Assert-Equal 'C:' ([string]@($history[2].Items)[0].Id)
    Assert-Equal ([double]40GB) ([double]@($history[2].Items)[0].Free)
    Assert-True ($null -eq $data.Probes.'disk.volumes'.PSObject.Properties['History']) 'lot entrant modifie'
    Assert-Equal 1 @($merged.Probes.'disk.volumes'.Instances).Count 'detail conserve'
    $close = [pscustomobject]@{ Computer = 'PC'; Probes = [pscustomobject]@{ 'disk.volumes' = (& $entry '2026-10-10T15:00:00Z' 39GB) } }
    $again = Add-DomeniaProbeHistory -Data $close -PreviousData $merged -ProbeId 'disk.volumes'
    Assert-Equal 3 @($again.Probes.'disk.volumes'.History).Count 'un releve toutes les 6 h au plus'
    Assert-True ($null -eq (Add-DomeniaProbeHistory -Data $data -PreviousData $previous -ProbeId 'hw.ram')) 'sonde sans historique'
    $partial = [pscustomobject]@{ Probes = [pscustomobject]@{ 'disk.volumes' = (& $entry '2026-10-12T12:00:00Z' 38GB -Truncated) } }
    Assert-True ($null -eq (Add-DomeniaProbeHistory -Data $partial -PreviousData $previous -ProbeId 'disk.volumes')) 'lecture partielle sans echantillon'
    $long = New-Object System.Collections.Generic.List[object]
    for ($day = 0; $day -lt 70; $day++) { $long.Add([pscustomobject]@{ AtUtc = ([datetime]::SpecifyKind([datetime]'2026-07-01T12:00:00',[DateTimeKind]::Utc)).AddDays($day).ToString('o'); Items = @([pscustomobject]@{ Id = 'C:'; Size = 100GB; Free = 50GB }) }) }
    $longEntry = & $entry '2026-09-08T12:00:00Z' 50GB; $longEntry | Add-Member -NotePropertyName History -NotePropertyValue $long.ToArray()
    $capped = Add-DomeniaProbeHistory -Data $data -PreviousData ([pscustomobject]@{ Probes = [pscustomobject]@{ 'disk.volumes' = $longEntry } }) -ProbeId 'disk.volumes'
    Assert-Equal 60 @($capped.Probes.'disk.volumes'.History).Count 'historique borne a 60 releves'
}
Test-Case -Id 'RDG-083' -Name 'Point 83 : etat du pilote, disque virtuel, compteurs absents ou refuses distincts d un disque sain' -Body {
    $physical = New-RdgSource 'disk.physical' @([pscustomobject]@{ FriendlyName = 'NVMe 1'; DeviceId = '0'; MediaType = 4; BusType = 17; HealthStatus = 0; OperationalStatus = @(2); Size = 512GB }, [pscustomobject]@{ FriendlyName = 'Disque VM'; DeviceId = '1'; MediaType = 0; BusType = 14; HealthStatus = 5; OperationalStatus = @(2) })
    $reliability = New-RdgSource 'disk.reliability' @([pscustomobject]@{ DeviceId = '0'; Temperature = 41; Wear = 3; PowerOnHours = 1200; ReadErrorsUncorrected = 2; WriteErrorsUncorrected = 0 })
    $facts = @(Get-DomeniaStorageHealthReading $physical $reliability)
    $healthy = Get-RdgFact $facts 'NVMe 1'
    Assert-True ([string]$healthy.Valeur -like 'Sain selon le pilote*NVMe*') ([string]$healthy.Valeur)
    $virtual = Get-RdgFact $facts 'Disque VM'
    Assert-Equal 'Inconnu' ([string]$virtual.Etat) 'etat 5 : inconnu, jamais sain'
    Assert-True ([string]$virtual.Limite -like 'Disque virtuel*') 'support physique invisible annonce'
    Assert-True ([string]$virtual.Limite -like '*état inconnu nʼest pas un disque sain*') ([string]$virtual.Limite)
    Assert-True ([string](Get-RdgFact $facts 'Compteurs de fiabilité de NVMe 1').Hypothese -like '*non corrigées*') 'erreurs non corrigees signalees'
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $facts 'Compteurs de fiabilité de Disque VM').Etat) 'aucun compteur pour ce disque'
    $refused = @(Get-DomeniaStorageHealthReading $physical (ConvertTo-DomeniaReadingSource -ProbeId 'disk.reliability' -Entry ([pscustomobject]@{ Error = 'Access denied' })))
    Assert-Equal 'Refuse' ([string](Get-RdgFact $refused 'Compteurs de fiabilité de NVMe 1').Etat)
}
Test-Case -Id 'RDG-084' -Name 'Point 84 : usure estimee de deux capacites valides, cycles a zero non renseignes' -Body {
    $batteries = New-RdgSource 'hw.batteries' @([pscustomobject]@{ DeviceID = 'B1'; Name = 'DELL 7FJ'; EstimatedChargeRemaining = 80; BatteryStatus = 2 })
    $static = New-RdgSource 'hw.batterystatic' @([pscustomobject]@{ InstanceName = 'ACPI\PNP0C0A\1_0'; DeviceName = 'DELL 7FJ'; ManufactureName = 'SMP'; DesignedCapacity = 50000 })
    $full = New-RdgSource 'hw.batteryfullcharge' @([pscustomobject]@{ InstanceName = 'ACPI\PNP0C0A\1_0'; FullChargedCapacity = 40000 })
    $cycles = New-RdgSource 'hw.batterycycles' @([pscustomobject]@{ InstanceName = 'ACPI\PNP0C0A\1_0'; CycleCount = 0 })
    $facts = @(Get-DomeniaBatteryReading $batteries $static $full $cycles)
    Assert-True ([string](Get-RdgFact $facts 'Batterie DELL 7FJ').Valeur -like 'charge 80 %*secteur*') 'charge et etat dates'
    $wear = Get-RdgFact $facts 'Usure de la batterie DELL 7FJ SMP'
    Assert-Equal 'Estime' ([string]$wear.Etat)
    Assert-True ([string]$wear.Valeur -like '20 %*') ([string]$wear.Valeur)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $facts 'Cycles de la batterie DELL 7FJ SMP').Etat) 'zero cycle : non renseigne'
    $odd = @(Get-DomeniaBatteryReading $batteries $static (New-RdgSource 'hw.batteryfullcharge' @([pscustomobject]@{ InstanceName = 'ACPI\PNP0C0A\1_0'; FullChargedCapacity = 60000 })) $cycles)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $odd 'Usure de la batterie DELL 7FJ SMP').Etat) 'capacite superieure a la nominale'
    $desktop = @(Get-DomeniaBatteryReading (New-RdgSource 'hw.batteries' @()) $static $full $cycles)
    Assert-Equal 'Aucune batterie déclarée' ([string](Get-RdgFact $desktop 'Batteries').Valeur)
    $legacy = @(Get-DomeniaBatteryReading (New-RdgSource 'hw.batteries' @([pscustomobject]@{ Name = 'B'; DesignCapacity = 0; FullChargeCapacity = 0 })) (ConvertTo-DomeniaReadingSource -ProbeId 'hw.batterystatic' -Entry $null) (ConvertTo-DomeniaReadingSource -ProbeId 'hw.batteryfullcharge' -Entry $null) (ConvertTo-DomeniaReadingSource -ProbeId 'hw.batterycycles' -Entry $null))
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $legacy 'Usure de la batterie B').Etat) 'zero signifie non expose'
}
Test-Case -Id 'RDG-085' -Name 'Point 85 : comparaison a une reference approuvee par modele, formats non comparables signales' -Body {
    Assert-Equal 'Newer' (Compare-DomeniaBiosVersion '1.15.0' '1.9.2')
    Assert-Equal 'Older' (Compare-DomeniaBiosVersion 'N1CET89W (1.57 )' 'N1CET90W (1.58 )')
    Assert-Equal 'Equal' (Compare-DomeniaBiosVersion 'A23' 'a23')
    Assert-Equal 'Different' (Compare-DomeniaBiosVersion 'F.52' '1.52') 'formats differents'
    Assert-Equal 'Different' (Compare-DomeniaBiosVersion '1.05' '1.5') 'memes nombres, ecriture differente'
    Assert-Equal 'Unknown' (Compare-DomeniaBiosVersion '' '1.0')
    $book = Set-DomeniaBiosReference -Book (ConvertTo-DomeniaBiosReferenceBook $null) -Manufacturer 'Dell Inc.' -Model 'Latitude 7440' -Version '1.15.0' -NowUtc ([datetime]'2026-10-01T10:00:00Z')
    Assert-Equal 1 @($book.References).Count
    $again = Set-DomeniaBiosReference -Book $book -Manufacturer 'Dell Inc.' -Model 'LATITUDE 7440' -Version '1.16.0' -NowUtc ([datetime]'2026-10-02T10:00:00Z')
    Assert-Equal '1.16.0' ([string]@($again.References)[0].Version) 'une seule reference par modele'
    $bios = New-RdgSource 'hw.biosdetails' @([pscustomobject]@{ SMBIOSBIOSVersion = '1.9.2'; Manufacturer = 'Dell Inc.'; ReleaseDate = '2024-03-05T00:00:00Z'; SMBIOSMajorVersion = 3; SMBIOSMinorVersion = 4 })
    $system = New-RdgSource 'hw.computersystem' @([pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 7440'; HypervisorPresent = $false })
    $older = Get-DomeniaBiosReading $bios $system $book
    $fact = Get-RdgFact @($older.Facts) 'Référence approuvée'
    Assert-True ([string]$fact.Valeur -like 'Antérieure à la référence 1.15.0*') ([string]$fact.Valeur)
    Assert-True ([string]$fact.Hypothese) 'mise a jour attendue selon la reference'
    Assert-Equal 'Latitude 7440' ([string]$older.Context.Model)
    $none = Get-DomeniaBiosReading $bios $system (Remove-DomeniaBiosReference $book 'Dell Inc.' 'Latitude 7440')
    Assert-Equal 'Inconnu' ([string](Get-RdgFact @($none.Facts) 'Référence approuvée').Etat) 'sans reference : aucune conclusion'
    Assert-Throws { ConvertTo-DomeniaBiosReferenceBook ([pscustomobject]@{ References = @([pscustomobject]@{ Manufacturer = 'X'; Model = ('M' + [char]7); Version = '1'; ApprovedUtc = '2026-10-01T00:00:00Z' }) }) -Strict } 'caractere de controle refuse'
}
Test-Case -Id 'RDG-086' -Name 'Point 86 : signature d hyperviseur, machine physique probable et charge datee' -Body {
    Assert-Equal 'Hyper-V' (Get-DomeniaVirtualPlatform 'Microsoft Corporation' 'Virtual Machine')
    Assert-Equal 'VirtualBox' (Get-DomeniaVirtualPlatform 'innotek GmbH' 'VirtualBox')
    Assert-Equal 'VMware' (Get-DomeniaVirtualPlatform 'VMware, Inc.' 'VMware7,1')
    Assert-Equal '' (Get-DomeniaVirtualPlatform 'Microsoft Corporation' 'Surface Laptop 5') 'materiel Microsoft physique'
    $cpu = New-RdgSource 'hw.processors' @([pscustomobject]@{ Name = 'Intel Core i7'; DeviceID = 'CPU0'; Architecture = 9; NumberOfCores = 4; NumberOfLogicalProcessors = 8; MaxClockSpeed = 2800; VirtualizationFirmwareEnabled = $false; SecondLevelAddressTranslationExtensions = $true; LoadPercentage = 12 })
    $facts = @(Get-DomeniaProcessorReading $cpu (New-RdgSource 'hw.computersystem' @([pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 7440'; HypervisorPresent = $true })))
    $platform = Get-RdgFact $facts 'Machine physique ou virtuelle'
    Assert-Equal 'Estime' ([string]$platform.Etat)
    Assert-True ([string]$platform.Valeur -like 'Machine physique probable, avec un hyperviseur actif*') ([string]$platform.Valeur)
    Assert-Equal '12 %' ([string](Get-RdgFact $facts 'Charge de CPU0 au relevé').Valeur)
    Assert-True ([string](Get-RdgFact $facts 'Processeur CPU0').Valeur -like '*x64*4 cœurs, 8 processeurs logiques*') 'architecture et coeurs'
    $guest = @(Get-DomeniaProcessorReading $cpu (New-RdgSource 'hw.computersystem' @([pscustomobject]@{ Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine'; HypervisorPresent = $true })))
    Assert-True ([string](Get-RdgFact $guest 'Machine physique ou virtuelle').Valeur -like 'Machine virtuelle (Hyper-V)*') 'machine virtuelle nommee'
}
Test-Case -Id 'RDG-087' -Name 'Point 87 : identite EDID, raccordement interne ou externe, changements entre releves, station non revendiquee' -Body {
    $monitors = New-RdgSource 'hw.monitors' @(
        [pscustomobject]@{ InstanceName = 'DISPLAY\DELA0F1\1'; UserFriendlyName = (New-RdgCodes 'DELL U2419H' 13); ManufacturerName = (New-RdgCodes 'DEL'); ProductCodeID = (New-RdgCodes 'A0F1'); SerialNumberID = (New-RdgCodes '123ABC'); YearOfManufacture = 2021; WeekOfManufacture = 10 },
        [pscustomobject]@{ InstanceName = 'DISPLAY\BOE0974\2'; UserFriendlyName = @(); ManufacturerName = (New-RdgCodes 'BOE'); ProductCodeID = (New-RdgCodes '0974'); SerialNumberID = (New-RdgCodes '0'); YearOfManufacture = 2020; WeekOfManufacture = 0 }
    ) -History @([pscustomobject]@{ AtUtc = '2026-10-01T12:00:00Z'; Items = @('A') }, [pscustomobject]@{ AtUtc = '2026-10-10T12:00:00Z'; Items = @('A','B') })
    $links = New-RdgSource 'hw.monitorconnections' @([pscustomobject]@{ InstanceName = 'display\dela0f1\1'; VideoOutputTechnology = 10 }, [pscustomobject]@{ InstanceName = 'DISPLAY\BOE0974\2'; VideoOutputTechnology = 2147483648 })
    $facts = @(Get-DomeniaDisplayReading $monitors $links)
    Assert-True ([string](Get-RdgFact $facts 'Écran 1').Valeur -like 'DELL U2419H · fabricant DEL · produit A0F1 · n° 123ABC · DisplayPort externe · fabriqué en 2021 (semaine 10)') ([string](Get-RdgFact $facts 'Écran 1').Valeur)
    Assert-True ([string](Get-RdgFact $facts 'Écran 2').Valeur -like '*sans numéro de série*écran interne*') ([string](Get-RdgFact $facts 'Écran 2').Valeur)
    Assert-Equal '1 interne(s), 1 externe(s), 0 non déterminé(s)' ([string](Get-RdgFact $facts 'Raccordements').Valeur)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $facts 'Station dʼaccueil').Etat) 'station d accueil jamais revendiquee'
    Assert-True ([string](Get-RdgFact $facts 'Changements dʼécrans').Valeur -like '*apparu au relevé du 10/10/2026 : B*') ([string](Get-RdgFact $facts 'Changements dʼécrans').Valeur)
    $history = @(
        (Add-DomeniaProbeHistory -Data ([pscustomobject]@{ Probes = [pscustomobject]@{ 'hw.monitors' = [pscustomobject]@{ CheckedUtc = '2026-10-12T12:00:00Z'; Truncated = $false; Instances = @([pscustomobject]@{ Values = [pscustomobject]@{ UserFriendlyName = (New-RdgCodes 'X'); ManufacturerName = (New-RdgCodes 'AAA'); ProductCodeID = (New-RdgCodes '1'); SerialNumberID = (New-RdgCodes '9') } }) } } }) -PreviousData $null -ProbeId 'hw.monitors').Probes.'hw.monitors'.History)
    Assert-Equal 1 $history.Count
    Assert-Equal 'X · fabricant AAA · produit 1 · n° 9' ([string]@($history[0].Items)[0])
}
Test-Case -Id 'RDG-087B' -Name 'Point 87 : indices de station d accueil nommes comme indices, absence sans conclusion, lecture manquante dite' -Body {
    $docks = New-RdgSource 'hw.dockhints' @(
        [pscustomobject]@{ Name = 'Dell WD19 Dock'; PNPClass = 'USB'; Manufacturer = 'Dell Inc.'; DeviceID = 'USB\VID_413C&PID_B06E\1'; Status = 'OK' },
        [pscustomobject]@{ Name = 'Station dʼaccueil'; PNPClass = 'Dock'; Manufacturer = '(Standard system devices)'; DeviceID = 'ACPI\PNP0C15\1'; Status = 'OK' })
    $facts = @(Get-DomeniaDockHintFacts $docks)
    $first = Get-RdgFact $facts 'Indice de station dʼaccueil 1'
    Assert-Equal 'Estime' ([string]$first.Etat) 'un nom de peripherique reste un indice'
    Assert-Equal 'Dell WD19 Dock · classe USB · fabricant Dell Inc.' ([string]$first.Valeur)
    Assert-True ([string]$first.Limite -like 'Indice seulement : aucune classe Windows normalisée*') ([string]$first.Limite)
    $second = Get-RdgFact $facts 'Indice de station dʼaccueil 2'
    Assert-Equal 'Estime' ([string]$second.Etat)
    Assert-True ([string]$second.Hypothese -like '*classe Dock*') ([string]$second.Hypothese)
    Assert-False (@($facts | Where-Object { [string]$_.Etat -eq 'Constate' }).Count) 'aucune station revendiquee comme constatee'
    $none = @(Get-DomeniaDockHintFacts (New-RdgSource 'hw.dockhints' @()))
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $none 'Station dʼaccueil').Etat) 'absence d indice : aucune conclusion'
    Assert-True ([string](Get-RdgFact $none 'Station dʼaccueil').Limite -like '*ne prouve pas lʼabsence*') 'absence non expliquee'
    $unread = @(Get-DomeniaDockHintFacts (ConvertTo-DomeniaReadingSource -ProbeId 'hw.dockhints' -Entry $null))
    Assert-Equal 'Non relevé' ([string](Get-RdgFact $unread 'Indices de station dʼaccueil').Valeur)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $unread 'Station dʼaccueil').Etat)
    Assert-Equal 'displays' ([string](Get-DomeniaReadingForProbe 'hw.dockhints').Id) 'indices lus avec les ecrans'
    $reading = Invoke-DomeniaReading -Id 'displays' -Sources @{ 'hw.dockhints' = $docks }
    Assert-Equal 1 @($reading.Facts | Where-Object { [string]$_.Fait -ceq 'Indice de station dʼaccueil 1' }).Count 'lecture des ecrans sans les indices'
}
Test-Case -Id 'RDG-088' -Name 'Point 88 : carte physique avec configuration jointe, cartes virtuelles a part, vitesse declaree' -Body {
    $interfaces = New-RdgSource 'net.interfaces' @(
        [pscustomobject]@{ Name = 'Intel Ethernet'; DeviceID = '1'; NetConnectionID = 'Ethernet'; NetConnectionStatus = 2; PhysicalAdapter = $true; MACAddress = '00-11-22-33-44-55'; Speed = 1000000000; PNPDeviceID = 'PCI\VEN_8086' },
        [pscustomobject]@{ Name = 'Hyper-V Virtual Ethernet Adapter'; DeviceID = '5'; NetConnectionID = 'vEthernet'; NetConnectionStatus = 2; PhysicalAdapter = $false; MACAddress = ''; Speed = 10000000000; PNPDeviceID = 'ROOT\VMS_MP\0000' })
    $configs = New-RdgSource 'net.configurations' @([pscustomobject]@{ Index = 1; IPAddress = @('10.0.0.5','fe80::1'); DefaultIPGateway = @('10.0.0.1'); DNSServerSearchOrder = @('10.0.0.10'); DHCPEnabled = $true; DHCPServer = '10.0.0.2' })
    $facts = @(Get-DomeniaNetworkReading $interfaces $configs)
    $card = Get-RdgFact $facts 'Carte Ethernet (Intel Ethernet)'
    Assert-Equal 'connectée · 1 Gbit/s déclarés · MAC 00-11-22-33-44-55 · IP 10.0.0.5, fe80::1 · passerelle 10.0.0.1 · DNS 10.0.0.10 · DHCP (10.0.0.2)' ([string]$card.Valeur)
    Assert-True ([string]$card.Limite -like '*pas un débit mesuré*') 'vitesse declaree'
    Assert-Equal '1 : Hyper-V Virtual Ethernet Adapter (connectée)' ([string](Get-RdgFact $facts 'Cartes virtuelles').Valeur)
    Assert-True (Test-DomeniaVirtualAdapterName 'TAP-Windows Adapter V9')
    Assert-False (Test-DomeniaVirtualAdapterName 'Realtek PCIe GbE')
}
Test-Case -Id 'RDG-089' -Name 'Point 89 : imprimante hors ligne, periphe desactive ou deconnecte hors anomalie, limite de session' -Body {
    $printers = New-RdgSource 'soft.printerdetails' @([pscustomobject]@{ Name = 'HP Accueil'; DriverName = 'HP UPD'; PortName = 'IP_10.0.0.9'; ExtendedPrinterStatus = 7; WorkOffline = $true; Default = $false; Network = $true; Local = $false }, [pscustomobject]@{ Name = 'PDF'; DriverName = 'PDF'; PortName = 'PORTPROMPT:'; ExtendedPrinterStatus = 3; WorkOffline = $false; Default = $true; Network = $false; Local = $true })
    $devices = New-RdgSource 'hw.deviceerrors' @([pscustomobject]@{ Name = 'Bluetooth'; DeviceID = 'USB\1'; PNPClass = 'Bluetooth'; ConfigManagerErrorCode = 22 }, [pscustomobject]@{ Name = 'Lecteur'; DeviceID = 'PCI\2'; PNPClass = 'SmartCardReader'; ConfigManagerErrorCode = 28 })
    $facts = @(Get-DomeniaDeviceReading $printers $devices)
    Assert-True ([string](Get-RdgFact $facts 'Imprimante HP Accueil').Valeur -like 'hors ligne · réseau*') 'imprimante hors ligne'
    $summary = Get-RdgFact $facts 'Imprimantes'
    Assert-Equal '2 imprimante(s), 1 hors ligne ou en erreur · par défaut : PDF' ([string]$summary.Valeur)
    Assert-True ([string]$summary.Limite -like '*autre session*') 'limite de session annoncee'
    Assert-Equal '1 en anomalie, 1 désactivé(s) ou déconnecté(s)' ([string](Get-RdgFact $facts 'Périphériques en erreur').Valeur)
    Assert-Equal '' ([string](Get-RdgFact $facts 'Périphérique Bluetooth').Hypothese) 'desactive : pas une anomalie'
    Assert-True ([string](Get-RdgFact $facts 'Périphérique Lecteur').Hypothese) 'pilote non installe : anomalie'
}
Test-Case -Id 'RDG-094' -Name 'Point 94 : ecarts au profil attendu, arret sur erreur, aucune action' -Body {
    $services = New-RdgSource 'soft.servicedetails' @(
        [pscustomobject]@{ Name = 'Winmgmt'; DisplayName = 'WMI'; State = 'Running'; StartMode = 'Auto'; ExitCode = 0 },
        [pscustomobject]@{ Name = 'Netlogon'; DisplayName = 'Netlogon'; State = 'Stopped'; StartMode = 'Auto'; ExitCode = 0 },
        [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Spouleur'; State = 'Stopped'; StartMode = 'Auto'; ExitCode = 1067 },
        [pscustomobject]@{ Name = 'edgeupdate'; DisplayName = 'Edge Update'; State = 'Stopped'; StartMode = 'Auto'; ExitCode = 1077 })
    $expected = @([pscustomobject]@{ Name = 'Winmgmt'; Reason = 'WMI' }, [pscustomobject]@{ Name = 'Netlogon'; Reason = 'Domaine' }, [pscustomobject]@{ Name = 'gpsvc'; Reason = 'Strategie' })
    $facts = @(Get-DomeniaServiceReading $services $expected)
    Assert-Equal 'Attendu démarré, constaté arrêté (démarrage automatique)' ([string](Get-RdgFact $facts 'Service Netlogon (Netlogon)').Valeur)
    Assert-Equal 'Absent du poste' ([string](Get-RdgFact $facts 'Service gpsvc').Valeur)
    Assert-True ([string](Get-RdgFact $facts 'Profil attendu').Valeur -like '1 service(s) conforme(s) sur 3*') 'synthese du profil'
    Assert-Equal 'Spooler (code 1067)' ([string](Get-RdgFact $facts 'Services automatiques arrêtés sur erreur').Valeur) '1077 exclu'
    Assert-True (@(Get-DomeniaServiceProfile).Count -ge 10) 'profil integre'
}
Test-Case -Id 'RDG-096' -Name 'Point 96 : taches hors Microsoft, derniere execution non inventee, aucune commande' -Body {
    $tasks = New-RdgSource 'soft.scheduledtasks' @([pscustomobject]@{ TaskName = 'Sauvegarde'; TaskPath = '\Contoso\'; State = 3; Author = 'CONTOSO\admin'; Date = '2026-01-02T08:00:00' }, [pscustomobject]@{ TaskName = 'Defrag'; TaskPath = '\Microsoft\Windows\Defrag\'; State = 3; Author = 'Microsoft'; Date = '' })
    $startup = New-RdgSource 'soft.startupdetails' @([pscustomobject]@{ Name = 'OneDrive'; Location = 'HKU\S-1-5-21\Run'; User = 'CONTOSO\jdoe' })
    $facts = @(Get-DomeniaTaskReading $tasks $startup)
    Assert-Equal '2 tâche(s) visibles, dont 1 hors Microsoft (1 non désactivée(s))' ([string](Get-RdgFact $facts 'Tâches planifiées').Valeur)
    Assert-True ([string](Get-RdgFact $facts 'Tâche \Contoso\Sauvegarde').Valeur -like 'état prête · auteur CONTOSO\admin*') 'tache hors Microsoft decrite'
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $facts 'Dernière exécution et dernier résultat').Etat) 'derniere execution non inventee'
    Assert-True ([string](Get-RdgFact $facts 'Démarrage automatique').Limite -like 'Commandes et arguments volontairement non collectés*') 'secrets evites'
}
Test-Case -Id 'RDG-097' -Name 'Point 97 : decodage estime, couverture tierce, Defender detaille, absence de protection signalee' -Body {
    Assert-True ((ConvertFrom-DomeniaAvProductState 397568).Enabled) 'scanner actif'
    Assert-True ((ConvertFrom-DomeniaAvProductState 397568).UpToDate) 'signatures a jour'
    Assert-False ((ConvertFrom-DomeniaAvProductState 393472).Enabled) 'scanner inactif'
    Assert-False ((ConvertFrom-DomeniaAvProductState 397584).UpToDate) 'signatures anciennes'
    Assert-True ($null -eq (ConvertFrom-DomeniaAvProductState 'n/a').Enabled) 'etat non decode'
    $products = New-RdgSource 'sec.avproducts' @([pscustomobject]@{ displayName = 'Contoso Endpoint'; productState = 397568; timestamp = 'Tue, 14 Oct 2026 08:00:00 GMT' }, [pscustomobject]@{ displayName = 'Microsoft Defender Antivirus'; productState = 393472 })
    $defender = New-RdgSource 'sec.defenderdetails' @([pscustomobject]@{ AntivirusEnabled = $false; RealTimeProtectionEnabled = $false; BehaviorMonitorEnabled = $false; AntivirusSignatureAge = 65535; QuickScanAge = 65535; AMProductVersion = '4.18.1' })
    $facts = @(Get-DomeniaAntivirusReading $products $defender)
    $coverage = Get-RdgFact $facts 'Couverture antivirus'
    Assert-Equal 'Estime' ([string]$coverage.Etat)
    Assert-True ([string]$coverage.Valeur -like 'Protection tierce déclarée active : Contoso Endpoint*') ([string]$coverage.Valeur)
    Assert-Equal 'Estime' ([string](Get-RdgFact $facts 'Antivirus Contoso Endpoint').Etat) 'decodage non documente : estimation'
    Assert-Equal 'Jamais réalisée selon Defender' ([string](Get-RdgFact $facts 'Dernière analyse rapide').Valeur)
    $alone = @(Get-DomeniaAntivirusReading (New-RdgSource 'sec.avproducts' @()) $defender)
    $bare = Get-RdgFact $alone 'Couverture antivirus'
    Assert-Equal 'Aucun antivirus déclaré au Centre de sécurité et Defender désactivé' ([string]$bare.Valeur)
    Assert-True ([string]$bare.Hypothese) 'absence de protection signalee'
    $server = @(Get-DomeniaAntivirusReading (ConvertTo-DomeniaReadingSource -ProbeId 'sec.avproducts' -Entry ([pscustomobject]@{ Error = 'Invalid namespace' })) (ConvertTo-DomeniaReadingSource -ProbeId 'sec.defenderdetails' -Entry $null))
    Assert-Equal 'Indisponible' ([string](Get-RdgFact $server 'Couverture antivirus').Etat) 'Windows Server sans Centre de securite'
}
Test-Case -Id 'RDG-098' -Name 'Point 98 : profil applique a la connexion active et etat du magasin, origine renvoyee a l inventaire' -Body {
    $profiles = New-RdgSource 'sec.firewallprofiles' @([pscustomobject]@{ Name = 'Domain'; Enabled = 0; DefaultInboundAction = 4; DefaultOutboundAction = 2 }, [pscustomobject]@{ Name = 'Private'; Enabled = 1; DefaultInboundAction = 4; DefaultOutboundAction = 2 }, [pscustomobject]@{ Name = 'Public'; Enabled = 2; DefaultInboundAction = 0; DefaultOutboundAction = 0 })
    $connections = New-RdgSource 'net.connectionprofiles' @([pscustomobject]@{ NetworkCategory = 2; InterfaceAlias = 'Ethernet'; Name = 'contoso.test' })
    $facts = @(Get-DomeniaFirewallReading $profiles $connections)
    $domain = Get-RdgFact $facts 'Profil Domaine'
    Assert-True ([string]$domain.Valeur -like 'désactivé · entrant par défaut : bloquer*appliqué à Ethernet') ([string]$domain.Valeur)
    Assert-True ([string]$domain.Hypothese) 'profil applique desactive signale'
    Assert-True ([string]$domain.Limite -like '*stratégie de groupe*') 'origine non revendiquee'
    Assert-True ([string](Get-RdgFact $facts 'Profil Public').Valeur -like 'non configuré dans ce magasin*') 'GpoBoolean 2'
    Assert-Equal 'Ethernet : domaine (contoso.test)' ([string](Get-RdgFact $facts 'Profils appliqués').Valeur)
}
Test-Case -Id 'RDG-099' -Name 'Point 99 : chiffrement et protection distincts, TPM, VBS et Secure Boot non deduit' -Body {
    $volumes = New-RdgSource 'sec.bitlockervolumes' @([pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = 0; ConversionStatus = 1; EncryptionMethod = 7 }, [pscustomobject]@{ DriveLetter = 'D:'; ProtectionStatus = 1; ConversionStatus = 1; EncryptionMethod = 6 }, [pscustomobject]@{ DriveLetter = 'E:'; ProtectionStatus = 0; ConversionStatus = 0; EncryptionMethod = 0 })
    $tpm = New-RdgSource 'sec.tpmdetails' @([pscustomobject]@{ SpecVersion = '2.0, 0, 1.38'; IsEnabled_InitialValue = $true; IsActivated_InitialValue = $true; IsOwned_InitialValue = $true })
    $guard = New-RdgSource 'sec.deviceguard' @([pscustomobject]@{ VirtualizationBasedSecurityStatus = 2; SecurityServicesRunning = @(1,2); AvailableSecurityProperties = @(1,2,3) })
    $facts = @(Get-DomeniaProtectionReading $volumes $tpm $guard)
    $c = Get-RdgFact $facts 'BitLocker C:'
    Assert-Equal 'Chiffré, protection suspendue (XTS-AES 256)' ([string]$c.Valeur)
    Assert-True ([string]$c.Hypothese) 'suspension expliquee'
    Assert-Equal 'Chiffré et protégé (XTS-AES 128)' ([string](Get-RdgFact $facts 'BitLocker D:').Valeur)
    Assert-Equal 'Non chiffré' ([string](Get-RdgFact $facts 'BitLocker E:').Valeur)
    Assert-Equal 'version 2.0 · activé · opérationnel · propriétaire défini' ([string](Get-RdgFact $facts 'TPM').Valeur)
    $vbs = [string](Get-RdgFact $facts 'Sécurité basée sur la virtualisation').Valeur
    Assert-True (($vbs -like 'VBS en cours dʼexécution*Credential Guard*') -and ($vbs -like '*Secure Boot disponible pour VBS')) $vbs
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $facts 'Démarrage sécurisé (Secure Boot)').Etat) 'disponibilite non prise pour activation'
}
Test-Case -Id 'RDG-093' -Name 'Point 93 : obligation confirmee, indices partiels et anciens inventaires' -Body {
    $rows = @((New-RdgRow 'Redemarrage en attente' 'Windows Update' 'Present (obligation confirmee)'), (New-RdgRow 'Redemarrage en attente' 'Renommages de fichiers en attente' 'Present (indice partiel) : 3 operation(s)'), (New-RdgRow 'Redemarrage en attente' 'Paquets CBS en attente' 'Absent'), (New-RdgRow 'Redemarrage en attente' 'Etat' 'Redemarrage requis : Windows Update'))
    $required = Get-DomeniaPendingRebootReading $rows
    Assert-Equal 'Required' ([string]$required.State)
    Assert-True ([string]$required.Detail -like 'Confirmé par : Windows Update · indices partiels : Renommages de fichiers en attente') ([string]$required.Detail)
    $hint = Get-DomeniaPendingRebootReading @((New-RdgRow 'Redemarrage en attente' 'Renommages de fichiers en attente' 'Present (indice partiel) : 1 operation(s)'), (New-RdgRow 'Redemarrage en attente' 'Windows Update' 'Absent'))
    Assert-Equal 'Partial' ([string]$hint.State) 'indice partiel seul : pas une obligation'
    $legacy = Get-DomeniaPendingRebootReading @(New-RdgRow 'Redemarrage en attente' 'Etat' 'Redemarrage requis : Maintenance de composants, Renommage de fichiers en attente')
    Assert-Equal 'Required' ([string]$legacy.State)
    Assert-True $legacy.Legacy
    Assert-Equal 'Renommage de fichiers en attente' ([string]@($legacy.Partial)[0])
    Assert-Equal 'None' ([string](Get-DomeniaPendingRebootReading @(New-RdgRow 'Redemarrage en attente' 'Etat' 'Aucun redemarrage en attente')).State)
    Assert-Equal 'Unknown' ([string](Get-DomeniaPendingRebootReading @()).State)
}
Test-Case -Id 'RDG-095' -Name 'Point 95 : part du processeur sur un intervalle borne, processus non apparies exclus' -Body {
    $sample = [pscustomobject]@{ IntervalMs = 2000; SampledUtc = '2026-10-14T10:00:00Z'; LogicalProcessors = 4; Items = @(
        [pscustomobject]@{ Pid = 10; Name = 'calc.exe'; FirstTime = 10000000; SecondTime = 50000000; WorkingSet = 104857600 },
        [pscustomobject]@{ Pid = 11; Name = 'new.exe'; FirstTime = $null; SecondTime = 900000; WorkingSet = 1048576 },
        [pscustomobject]@{ Pid = 12; Name = 'idle.exe'; FirstTime = 20000000; SecondTime = 22000000; WorkingSet = $null },
        [pscustomobject]@{ Pid = 0; Name = 'System Idle Process'; FirstTime = 1000000000; SecondTime = 1070000000; WorkingSet = 8192 }) }
    $load = Measure-DomeniaProcessLoad -Sample $sample
    Assert-True $load.Measured
    Assert-Equal 'calc.exe' ([string]@($load.Items)[0].Name)
    Assert-Equal 50.0 ([double]@($load.Items)[0].Percent)
    Assert-Equal 2.5 ([double]@($load.Items)[1].Percent)
    Assert-Equal 1 ([int]$load.Unmatched) 'processus demarre pendant la mesure'
    Assert-Equal 52.5 ([double]$load.TotalPercent) 'temps inactif (PID 0) hors du total mesure'
    Assert-Equal 0 @(@($load.Items) | Where-Object { ([string]$_.Name -eq 'System Idle Process') -or ([string]$_.Pid -eq '0') }).Count 'processus inactif liste comme consommateur'
    Assert-Equal 2 @($load.Items).Count
    Assert-Equal 100.0 ([double]@($load.Items)[0].WorkingSetMb)
    Assert-False (Measure-DomeniaProcessLoad -Sample ([pscustomobject]@{ IntervalMs = 2000; LogicalProcessors = 0; Items = @() })).Measured 'processeurs logiques inconnus'
    Assert-False (Measure-DomeniaProcessLoad -Sample $null).Measured 'aucune mesure'
    $snapshot = @(Get-DomeniaProcessSnapshotReading (New-RdgSource 'soft.processdetails' @([pscustomobject]@{ Name = 'a.exe'; ProcessId = 1; WorkingSetSize = 2097152 })))
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $snapshot 'Charge processeur par processus').Etat) 'photographie unique sans taux'
}
Test-Case -Id 'RDG-100' -Name 'Point 100 : echeances des certificats machine, sans cle exportee' -Body {
    $now = [datetime]::SpecifyKind([datetime]'2026-10-15T12:00:00',[DateTimeKind]::Utc)
    $store = [pscustomobject]@{ Source = 'Registre SystemCertificates\MY'; Items = @(
        [pscustomobject]@{ Subject = 'CN=PC-1.contoso.test'; Issuer = 'CN=Contoso CA'; NotAfterUtc = '2026-10-01T12:00:00Z'; Thumbprint = 'AA'; Usages = @('Authentification du client'); KeyDeclared = $true },
        [pscustomobject]@{ Subject = 'CN=PC-1'; Issuer = 'CN=Contoso CA'; NotAfterUtc = '2026-10-30T00:00:00Z'; Thumbprint = 'BB'; Usages = @(); KeyDeclared = $false },
        [pscustomobject]@{ Subject = 'CN=WMSvc'; Issuer = 'CN=WMSvc'; NotAfterUtc = '2027-06-01T00:00:00Z'; Thumbprint = 'CC'; Usages = @(); KeyDeclared = $false }) }
    $reading = Get-DomeniaCertificateReading -Certificates $store -NowUtc $now
    Assert-True $reading.Read
    Assert-Equal 3 ([int]$reading.Total)
    Assert-Equal 'CN=PC-1.contoso.test' ([string]@($reading.Expired)[0])
    Assert-Equal 'CN=PC-1' ([string]@($reading.Soon)[0])
    Assert-Equal 1 ([int]$reading.Valid)
    $expired = Get-RdgFact @($reading.Facts) 'Certificat CN=PC-1.contoso.test'
    Assert-True ([string]$expired.Valeur -like 'Expiré le 01/10/2026*clé privée associée déclarée (non lue)*') ([string]$expired.Valeur)
    Assert-False (Get-DomeniaCertificateReading -Certificates $null -NowUtc $now).Read 'non lu'
    Assert-False $reading.Truncated 'lecture complete'
    $store | Add-Member -NotePropertyName StoreCount -NotePropertyValue 73
    $store | Add-Member -NotePropertyName Truncated -NotePropertyValue $true
    $cut = Get-DomeniaCertificateReading -Certificates $store -NowUtc $now
    Assert-True $cut.Truncated 'lecture partielle non signalee'
    Assert-Equal 73 ([int]$cut.StoreCount)
    $partial = Get-RdgFact @($cut.Facts) 'Lecture du magasin Personnel'
    Assert-Equal 'Inconnu' ([string]$partial.Etat)
    Assert-Equal 'Partielle : 3 certificat(s) lu(s) sur 73' ([string]$partial.Valeur)
}
Test-Case -Id 'RDG-092' -Name 'Point 92 : version, correctifs CBS, source WSUS, conformite jamais deduite' -Body {
    $rows = @((New-RdgRow 'Systeme d exploitation' 'Build' '22631'), (New-RdgRow 'Systeme d exploitation' 'Revision de build' '4317'), (New-RdgRow 'Systeme d exploitation' 'Version commerciale' '23H2'), (New-RdgRow 'Windows Update' 'Serveur WSUS' 'http://wsus.contoso.test:8530'), (New-RdgRow 'Windows Update' 'Strategie WSUS appliquee' 'Oui'), (New-RdgRow 'Windows Update' 'Derniere recherche' '2026-10-14 06:00:00'))
    $reading = Get-DomeniaUpdateReading -Rows $rows -Hotfixes @('2026-09-10','2026-10-08','date illisible') -NowUtc ([datetime]::SpecifyKind([datetime]'2026-10-15T12:00:00',[DateTimeKind]::Utc))
    Assert-Equal '23H2 · Build 22631.4317' ([string]$reading.Version)
    $facts = @($reading.Facts)
    Assert-True ([string](Get-RdgFact $facts 'Correctifs CBS').Valeur -like '2 correctif(s) daté(s), le plus récent installé le 08/10/2026') 'correctifs dates'
    Assert-Equal 'WSUS http://wsus.contoso.test:8530' ([string](Get-RdgFact $facts 'Source des mises à jour').Valeur)
    Assert-Equal 'Inconnu' ([string](Get-RdgFact $facts 'Conformité des mises à jour').Etat) 'conformite non deduite des correctifs'
    Assert-True ([string](Get-RdgFact $facts 'Dernière recherche Windows Update').Valeur -like '*(il y a 1 j)') 'date et age'
    $declared = Get-DomeniaUpdateReading -Rows @((New-RdgRow 'Windows Update' 'Serveur WSUS' 'http://w'), (New-RdgRow 'Windows Update' 'Strategie WSUS appliquee' 'Non')) -NowUtc ([datetime]::UtcNow)
    Assert-True ([string](Get-RdgFact @($declared.Facts) 'Source des mises à jour').Valeur -like '*déclarée mais non appliquée*') 'adresse WSUS sans UseWUServer'
}
Test-Case -Id 'RDG-099B' -Name 'Points 98 et 99 : profils appliques, BitLocker suspendu et Secure Boot lus dans l inventaire' -Body {
    $rows = @(
        (New-RdgRow 'Pare-feu' 'Profil domaine' 'Active (strategie)'),
        (New-RdgRow 'Pare-feu' 'Profil applique a Ethernet' 'Domaine (reseau contoso.test)'),
        (New-RdgRow 'Pare-feu' 'Profil applique a Wi-Fi' 'Prive (reseau Maison)'),
        (New-RdgRow 'BitLocker' 'Volume C:' 'Protection Desactive'),
        (New-RdgRow 'BitLocker' 'Volume C: chiffrement' 'Entierement chiffre'),
        (New-RdgRow 'BIOS et firmware' 'Secure Boot' 'Desactive'),
        (New-RdgRow 'BIOS et firmware' 'Type de firmware' 'UEFI'))
    $applied = Get-DomeniaAppliedFirewallProfiles $rows
    Assert-Equal 'Ethernet' ([string]@($applied['Profil domaine'])[0])
    Assert-Equal 'Wi-Fi' ([string]@($applied['Profil prive'])[0])
    $volume = Get-DomeniaBitLockerInventoryState $rows 'Volume C:'
    Assert-True $volume.Suspended 'chiffre et protection desactivee : suspendu'
    Assert-Equal 'Chiffré, protection suspendue' ([string]$volume.Text)
    $old = Get-DomeniaBitLockerInventoryState @(New-RdgRow 'BitLocker' 'Volume C:' 'Protection Desactive') 'Volume C:'
    Assert-False $old.Suspended 'ancien inventaire sans etat de chiffrement'
    $secure = Get-DomeniaSecureBootInventoryState $rows
    Assert-False $secure.Enabled
    Assert-Equal 'Désactivé' ([string]$secure.Text)
    Assert-True ([string]$secure.Detail -like '*UEFI*') 'type de micrologiciel'
}
Test-Case -Id 'RDG-002B' -Name 'Lecture assemblee : tentative en echec signalee, grille en francais' -Body {
    $failed = ConvertTo-DomeniaReadingSource -ProbeId 'disk.volumes' -Entry ([pscustomobject]@{ CheckedUtc = '2026-10-01T10:00:00Z'; Truncated = $false; Instances = @([pscustomobject]@{ Values = [pscustomobject]@{ DeviceID = 'C:'; Size = 100; FreeSpace = 50 } }) }) -AttemptError 'Le délai est dépassé'
    $reading = Invoke-DomeniaReading -Id 'volumes' -Sources @{ 'disk.volumes' = $failed } -Options @{ DiskFreeWarn = 30; DiskFreeAlert = 15 }
    Assert-Equal 'Indisponible' ([string]@($reading.Facts)[0].Etat) 'tentative en echec en tete'
    $rows = @(ConvertTo-DomeniaReadingRows $reading)
    Assert-Equal 'Indisponible' ([string]$rows[0].Etat)
    Assert-Equal 'Constaté' ([string]$rows[1].Etat)
    Assert-Equal 'Point,Valeur,Etat,Date,Source,Limite,Piste' ((@($rows[0].PSObject.Properties) | ForEach-Object { $_.Name }) -join ',')
    $memory = Invoke-DomeniaReading -Id 'memory'
    Assert-Equal 3 @($memory.Facts | Where-Object { [string]$_.Etat -eq 'Inconnu' }).Count 'trois requetes non relevees'
}
