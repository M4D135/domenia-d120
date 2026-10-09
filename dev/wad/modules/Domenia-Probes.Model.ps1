# Ready-made read-only probes for the dashboard widgets (decision David 2026-10-07, phase 1).
# One line per probe: Id|Category|Name|Namespace|Class|Properties|Filter|Mode|Transform|Visual[|Flags]
# Mode: First (first instance) or Count (number of instances) or All (every instance counted).
# Transform: Text, GB, MB, DaysSince, Year, PercentFree, Release, Map:a=b;c=d, Number.
# Flags (FI-17, decision David 2026-10-08): Slow = flagged in the editor; NoDC = never run on a domain controller
# (ProductType 2), where the class would walk the whole directory. This catalog is the list of allowed classes.
function Get-DomeniaProbeCatalog {
    if ($null -ne $script:DomeniaProbeCatalog) { return $script:DomeniaProbeCatalog }
    $table = @'
hw.maker|Materiel|Fabricant|root\cimv2|Win32_ComputerSystem|Manufacturer||First|Text|Pie
hw.model|Materiel|Modele|root\cimv2|Win32_ComputerSystem|Model||First|Text|Bar
hw.ram|Materiel|Memoire installee|root\cimv2|Win32_ComputerSystem|TotalPhysicalMemory||First|GB|Column
hw.cpu|Materiel|Processeur|root\cimv2|Win32_Processor|Name||First|Text|Bar
hw.cores|Materiel|Coeurs du processeur|root\cimv2|Win32_Processor|NumberOfCores||First|Number|Column
hw.threads|Materiel|Processeurs logiques|root\cimv2|Win32_ComputerSystem|NumberOfLogicalProcessors||First|Number|Column
hw.bios|Materiel|Version du BIOS|root\cimv2|Win32_BIOS|SMBIOSBIOSVersion||First|Text|Bar
hw.biosyear|Materiel|Annee du BIOS|root\cimv2|Win32_BIOS|ReleaseDate||First|Year|Column
hw.gpu|Materiel|Carte graphique|root\cimv2|Win32_VideoController|Name||First|Text|Bar
hw.screens|Materiel|Nombre d ecrans|root\wmi|WmiMonitorID|InstanceName||Count|Number|Column
hw.battery|Materiel|Batterie presente|root\cimv2|Win32_Battery|Name||Count|Map:0=Non;1=Oui;2=Oui|Pie
hw.chassis|Materiel|Type de systeme|root\cimv2|Win32_ComputerSystem|PCSystemTypeEx||First|Map:0=Non précisé;1=Bureau;2=Portable;3=Station de travail;4=Serveur;5=Serveur;6=Appareil;7=Serveur;8=Tablette|Pie
hw.serialmissing|Materiel|Numero de serie|root\cimv2|Win32_BIOS|SerialNumber||First|Text|Text
os.caption|Systeme|Edition de Windows|root\cimv2|Win32_OperatingSystem|Caption||First|Text|Pie
os.release|Systeme|Version de Windows|root\cimv2|Win32_OperatingSystem|BuildNumber,ProductType||First|Release|Pie
os.arch|Systeme|Architecture|root\cimv2|Win32_OperatingSystem|OSArchitecture||First|Text|Pie
os.uptime|Systeme|Jours depuis le dernier demarrage|root\cimv2|Win32_OperatingSystem|LastBootUpTime||First|DaysSince|Column
os.installyear|Systeme|Annee d installation de Windows|root\cimv2|Win32_OperatingSystem|InstallDate||First|Year|Column
os.lang|Systeme|Langue du systeme|root\cimv2|Win32_OperatingSystem|OSLanguage||First|Map:1036=Francais;1033=Anglais (US);2057=Anglais (UK);1031=Allemand;1034=Espagnol;1040=Italien|Pie
os.tz|Systeme|Fuseau horaire|root\cimv2|Win32_TimeZone|Caption||First|Text|Bar
os.pagefile|Systeme|Fichier d echange (Mo)|root\cimv2|Win32_PageFileUsage|AllocatedBaseSize||First|Number|Column
os.freeram|Systeme|Memoire libre (Go)|root\cimv2|Win32_OperatingSystem|FreePhysicalMemory||First|GBfromKB|Column
disk.cfree|Disques|Espace libre sur C: (%)|root\cimv2|Win32_LogicalDisk|FreeSpace,Size|DeviceID='C:'|First|PercentFree|Column
disk.csize|Disques|Taille de C: (Go)|root\cimv2|Win32_LogicalDisk|Size|DeviceID='C:'|First|GB|Column
disk.count|Disques|Nombre de volumes locaux|root\cimv2|Win32_LogicalDisk|DeviceID|DriveType=3|Count|Number|Column
disk.media|Disques|Type de disque physique|root\Microsoft\Windows\Storage|MSFT_PhysicalDisk|MediaType||First|Map:3=Disque dur;4=SSD;5=SCM;0=Non precise|Pie
disk.health|Disques|Sante du disque physique|root\Microsoft\Windows\Storage|MSFT_PhysicalDisk|HealthStatus||First|Map:0=Sain;1=Avertissement;2=Defaillant;5=Inconnu|Pie
disk.removable|Disques|Supports amovibles connectes|root\cimv2|Win32_LogicalDisk|DeviceID|DriveType=2|Count|Number|Column
sec.bitlocker|Securite|Chiffrement BitLocker de C:|root\cimv2\Security\MicrosoftVolumeEncryption|Win32_EncryptableVolume|ProtectionStatus|DriveLetter='C:'|First|Map:0=Non protege;1=Protege;2=Inconnu|Pie
sec.av|Securite|Antivirus declare|root\SecurityCenter2|AntiVirusProduct|displayName||All|Text|Bar
sec.localusers|Securite|Comptes locaux actives|root\cimv2|Win32_UserAccount|Name|LocalAccount=TRUE AND Disabled=FALSE|Count|Number|Column|NoDC
sec.shares|Securite|Partages hors administratifs|root\cimv2|Win32_Share|Name|Type=0|Count|Number|Column
sec.uac|Securite|Contrôle de compte (EnableLUA)|root\cimv2|Win32_OperatingSystem|Caption||Count|Number|Text
net.adapter|Reseau|Carte reseau connectee|root\cimv2|Win32_NetworkAdapter|Name|NetConnectionStatus=2 AND PhysicalAdapter=TRUE|All|Text|Bar
net.speed|Reseau|Vitesse du lien (Mbit/s)|root\cimv2|Win32_NetworkAdapter|Speed|NetConnectionStatus=2 AND PhysicalAdapter=TRUE|First|Mbps|Column
net.dhcp|Reseau|Adresse DHCP|root\cimv2|Win32_NetworkAdapterConfiguration|DHCPEnabled|IPEnabled=TRUE|First|Map:True=DHCP;False=Fixe|Pie
net.dns|Reseau|Premier serveur DNS|root\cimv2|Win32_NetworkAdapterConfiguration|DNSServerSearchOrder|IPEnabled=TRUE|First|Text|Bar
net.gateway|Reseau|Passerelle|root\cimv2|Win32_NetworkAdapterConfiguration|DefaultIPGateway|IPEnabled=TRUE|First|Text|Bar
net.wifi|Reseau|Wi-Fi connecte|root\StandardCimv2|MSFT_NetAdapter|Name|NdisPhysicalMedium=9 AND MediaConnectState=1|Count|Map:0=Non;1=Oui;2=Oui|Pie
soft.printers|Logiciels et services|Nombre d imprimantes|root\cimv2|Win32_Printer|Name||Count|Number|Column
soft.defaultprinter|Logiciels et services|Imprimante par defaut|root\cimv2|Win32_Printer|Name|Default=TRUE|First|Text|Bar
soft.startup|Logiciels et services|Programmes au demarrage|root\cimv2|Win32_StartupCommand|Name||Count|Number|Column
soft.stoppedauto|Logiciels et services|Services automatiques arretes|root\cimv2|Win32_Service|Name|StartMode='Auto' AND State='Stopped'|Count|Number|Column
soft.running|Logiciels et services|Services en cours d execution|root\cimv2|Win32_Service|Name|State='Running'|Count|Number|Column
soft.spooler|Logiciels et services|Service Spouleur d impression|root\cimv2|Win32_Service|State|Name='Spooler'|First|Text|Pie
soft.wuauserv|Logiciels et services|Service Windows Update|root\cimv2|Win32_Service|State|Name='wuauserv'|First|Text|Pie
soft.hotfixcount|Logiciels et services|Nombre de correctifs installes|root\cimv2|Win32_QuickFixEngineering|HotFixID||Count|Number|Column
soft.processes|Logiciels et services|Processus en cours|root\cimv2|Win32_Process|Name||Count|Number|Column
user.console|Utilisateurs|Utilisateur de la console|root\cimv2|Win32_ComputerSystem|UserName||First|Text|Text
user.profiles|Utilisateurs|Profils utilisateurs sur le poste|root\cimv2|Win32_UserProfile|LocalPath|Special=FALSE|Count|Number|Column
user.sessions|Utilisateurs|Sessions ouvertes|root\cimv2|Win32_LogonSession|LogonId|(LogonType=2 OR LogonType=10) AND AuthenticationPackage<>'Negotiate'|Count|Number|Column
evt.syserrors|Evenements|Erreurs systeme (24 h)|root\cimv2|Win32_NTLogEvent|EventCode|Logfile='System' AND EventType=1 AND TimeGenerated>='{SINCE_24H}'|Count|Number|Column|Slow
evt.unexpected|Evenements|Arrets inattendus (7 j)|root\cimv2|Win32_NTLogEvent|EventCode|Logfile='System' AND EventCode=6008 AND TimeGenerated>='{SINCE_7D}'|Count|Number|Column|Slow
'@
    $catalog = New-Object Collections.ArrayList
    foreach ($line in ($table -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $p = $line.Split('|')
        if ($p.Count -lt 10) { continue }
        $flags = @(if ($p.Count -ge 11) { $p[10].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
        [void]$catalog.Add([pscustomobject]@{ Id=$p[0]; Category=$p[1]; Name=$p[2]; Namespace=$p[3]; Class=$p[4]; Properties=@($p[5].Split(',') | Where-Object { $_ }); Filter=$p[6]; Mode=$p[7]; Transform=$p[8]; Visual=$p[9]; Slow=('Slow' -in $flags); SkipOnDc=('NoDC' -in $flags) })
    }
    $script:DomeniaProbeCatalog = @($catalog | Where-Object { $_.Id -ne 'sec.uac' })
    return $script:DomeniaProbeCatalog
}
function Get-DomeniaProbeVisuals {
    # Representations that make sense for this kind of data (decision David 2026-10-07): text values can be shared out,
    # measures are bucketed; a single workstation only gets a figure or a text.
    param($Probe,[string]$Board = 'Fleet')
    if ($null -eq $Probe) { return @() }
    if ($Board -eq 'Computer') { return @('Kpi','Text') }
    $numeric = ([string]$Probe.Mode -eq 'Count' -or [string]$Probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree)$')
    if ($numeric) { return @('Column','Kpi','Text') }
    return @('Pie','Bar','Text','Kpi')
}
function Get-DomeniaProbe {
    param([string]$Id)
    foreach ($probe in @(Get-DomeniaProbeCatalog)) { if ($probe.Id -ceq $Id) { return $probe } }
    return $null
}
function ConvertTo-DomeniaProbePayload {
    # Only what the worker needs: the query parts, never a free WQL text (read-only SELECT built by the worker).
    # Skip = 'DomainController': the worker reads ProductType first and leaves the query out on a controller (FI-17).
    param([string[]]$Ids)
    return @(foreach ($id in @($Ids | Select-Object -Unique)) { $probe = Get-DomeniaProbe $id; if ($null -ne $probe) { [pscustomobject]@{ Id=$probe.Id; Namespace=$probe.Namespace; Class=$probe.Class; Properties=@($probe.Properties); Filter=$probe.Filter; Mode=$probe.Mode; Skip=$(if ([bool]$probe.SkipOnDc) { 'DomainController' } else { '' }) } } })
}
function ConvertTo-DomeniaProbeNumber {
    # Invariant number of a raw WMI value, $null when the value is not a number (a bad reading is left out, never 0).
    param($Value)
    $number = 0.0
    if ([double]::TryParse(([string]$Value).Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { return $number }
    return $null
}
function Get-DomeniaProbeValues {
    # Values of one probe for one workstation, after the transform: strings (categories) or numbers. A result in error,
    # skipped on a domain controller or not readable gives no value: the workstation is then not counted.
    param($Probe,$Result)
    if ($null -eq $Probe -or $null -eq $Result -or [string]$Result.Error) { return @() }
    $skipped = $Result.PSObject.Properties['Skipped']
    if (($null -ne $skipped) -and [string]$skipped.Value) { return @() }
    $rows = @($Result.Rows)
    $transform = [string]$Probe.Transform
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $raw = switch ($Probe.Mode) { 'Count' { @([string][int]$Result.Count) } 'All' { @($rows | ForEach-Object { [string]@($_)[0] }) } default { if ($rows.Count) { @([string]@($rows[0])[0]) } else { @() } } }
    $values = foreach ($value in $raw) {
        if ([string]::IsNullOrWhiteSpace([string]$value) -and $transform -notlike 'Map:*') { continue }
        switch -Regex ($transform) {
            '^GB$' { $n = ConvertTo-DomeniaProbeNumber $value; if ($null -ne $n) { [Math]::Round($n / 1GB,1) }; break }
            '^GBfromKB$' { $n = ConvertTo-DomeniaProbeNumber $value; if ($null -ne $n) { [Math]::Round($n / 1MB,1) }; break }
            '^MB$' { $n = ConvertTo-DomeniaProbeNumber $value; if ($null -ne $n) { [Math]::Round($n / 1MB) }; break }
            '^Mbps$' { $n = ConvertTo-DomeniaProbeNumber $value; if ($null -ne $n) { [Math]::Round($n / 1000000) }; break }
            '^Number$' { $n = ConvertTo-DomeniaProbeNumber $value; if ($null -ne $n) { $n }; break }
            '^DaysSince$' { try { [Math]::Round(([datetime]::UtcNow - [datetime]::Parse([string]$value,$invariant).ToUniversalTime()).TotalDays) } catch { }; break }
            '^Year$' { try { [string]([datetime]::Parse([string]$value,$invariant).Year) } catch { }; break }
            '^PercentFree$' { $cells = @($rows[0]); if ($cells.Count -ge 2) { $free = ConvertTo-DomeniaProbeNumber $cells[0]; $size = ConvertTo-DomeniaProbeNumber $cells[1]; if (($null -ne $free) -and ($null -ne $size) -and ($size -gt 0)) { [Math]::Round(100.0 * $free / $size) } }; break }
            # ProductType 2 or 3 = domain controller or server: same builds as Windows 11, other release names.
            '^Release$' { $cells = @($rows[0]); $kind = if ($cells.Count -ge 2 -and [string]$cells[1] -notin @('','1')) { 'Server' } else { '' }; $name = (Get-DomeniaWindowsRelease -Build ([string]$value) -Caption $kind).Name; if ($name) { $name } else { 'Build ' + $value }; break }
            # A value outside the map keeps its raw text: nothing is invented.
            '^Map:' { $map = @{}; foreach ($pair in $transform.Substring(4).Split(';')) { $kv = $pair.Split('='); if ($kv.Count -eq 2) { $map[$kv[0]] = $kv[1] } }; if ($map.ContainsKey([string]$value)) { $map[[string]$value] } else { [string]$value }; break }
            default { ([string]$value).Trim() }
        }
    }
    return @($values)
}
function Measure-DomeniaWidgetData {
    # Aggregates one probe over workstations for a widget: categories counted, numbers bucketed or summarised.
    # Buckets carry their unit and whole bounds ('≤ 4 Go', '5 à 8 Go', '> 512 Go'; decision David 2026-10-08, CO-16).
    param($Probe,[object[]]$Results,[string]$Visual)
    $values = New-Object Collections.ArrayList; $machines = 0; $skipped = 0
    foreach ($result in @($Results)) {
        if (($null -ne $result) -and ($null -ne $result.PSObject.Properties['Skipped']) -and [string]$result.Skipped) { $skipped++; continue }
        $v = @(Get-DomeniaProbeValues $Probe $result); if ($v.Count) { $machines++; foreach ($x in $v) { [void]$values.Add($x) } }
    }
    $numeric = ($values.Count -gt 0 -and @($values | Where-Object { $_ -isnot [double] -and $_ -isnot [int] -and $_ -isnot [long] }).Count -eq 0)
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $unit = Get-DomeniaProbeUnit -Probe $Probe
    $format = { param([double]$Number) return $Number.ToString('0.#', $fr) }
    $items = @()
    # Distinct numbers only once the values are known to be numeric (text such as a version or an address stays text).
    $distinct = if ($numeric) { @($values | ForEach-Object { [double]$_ } | Sort-Object -Unique) } else { @() }
    if ($numeric -and $Visual -ne 'Pie' -and $distinct.Count -le 8 -and [string]$Probe.Transform -match '^(Number|DaysSince)$') {
        # Few distinct values (screens, printers, cores...): one bar per value, in order.
        $items = @(foreach ($d in $distinct) { [pscustomobject]@{ Label = ((& $format $d) + $unit); Value = [double]@($values | Where-Object { [double]$_ -eq $d }).Count } })
        $sum = 0.0; foreach ($x in $values) { $sum += [double]$x }
        $summary = 'Moyenne ' + (& $format ([Math]::Round($sum / $values.Count,1))) + ' · min ' + (& $format $distinct[0]) + ' · max ' + (& $format $distinct[-1])
    }
    elseif ($numeric -and $Visual -ne 'Pie') {
        $sorted = @($values | Sort-Object)
        $max = [double]$sorted[-1]
        # Rounded edges for a plain number (1, 2 or 5 x 10^n), fixed edges for sizes, ages, shares and speeds.
        $niceEdges = @((Get-DomeniaChartTicks -Maximum $max -Integer -Count 5).Ticks | Where-Object { ($_ -gt 0) -and ($_ -lt $max) })
        $edges = switch -Regex ([string]$Probe.Transform) { '^GB' { @(4,8,16,32,64,128,256,512) } '^DaysSince$' { @(1,7,30,90,180,365) } '^PercentFree$' { @(10,25,50,75) } '^Mbps$' { @(100,1000) } default { if ($max -le 10) { @(0,1,2,3,5,10) } else { $niceEdges } } }
        $edges = @($edges | Select-Object -Unique)
        if (-not $edges.Count) { $edges = @([Math]::Ceiling($max)) }
        $items = for ($i = 0; $i -le $edges.Count; $i++) {
            $low = if ($i -eq 0) { [double]::NegativeInfinity } else { [double]$edges[$i-1] }
            $high = if ($i -eq $edges.Count) { [double]::PositiveInfinity } else { [double]$edges[$i] }
            $label = if ($i -eq 0) { [string][char]0x2264 + ' ' + (& $format $edges[0]) + $unit } elseif ($i -eq $edges.Count) { '> ' + (& $format $edges[$i-1]) + $unit } elseif (([double]$edges[$i] - [double]$edges[$i-1]) -le 1) { (& $format $edges[$i]) + $unit } else { (& $format ([double]$edges[$i-1] + 1)) + ' à ' + (& $format $edges[$i]) + $unit }
            [pscustomobject]@{ Label = $label; Value = [double]@($values | Where-Object { [double]$_ -gt $low -and [double]$_ -le $high }).Count }
        }
        $sum = 0.0; foreach ($x in $values) { $sum += [double]$x }
        $summary = 'Moyenne ' + (& $format ([Math]::Round($sum / $values.Count,1))) + ' · min ' + (& $format $sorted[0]) + ' · max ' + (& $format $sorted[-1])
    } else {
        $groups = @($values | Group-Object { [string]$_ } | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
        $items = @($groups | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
        $others = 0; foreach ($g in @($groups | Select-Object -Skip 8)) { $others += $g.Count }
        if ($others -gt 0) { $items += [pscustomobject]@{ Label = 'Autres'; Value = [double]$others } }
        $summary = if ($groups.Count) { 'Le plus fréquent : ' + [string]$groups[0].Name + ' (' + $groups[0].Count + ')' } else { 'Aucune valeur' }
    }
    return [pscustomobject]@{ Items = @($items); Machines = $machines; Summary = $summary; Numeric = $numeric; Values = @($values); Skipped = $skipped }
}
