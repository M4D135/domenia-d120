# Ready-made read-only probes for the dashboard widgets (decision David 2026-10-07, phase 1).
# One line per probe: Id|Category|Name|Namespace|Class|Properties|Filter|Mode|Transform|Visual[|Flags]
# Mode: First (first instance) or Count (number of instances) or All (every instance counted).
# Transform: Text, GB, MB, DaysSince, Year, PercentFree, Release, Map:a=b;c=d, Number.
# Flags (FI-17, decision David 2026-10-08): Slow = flagged in the editor; NoDC = never run on a domain controller
# (ProductType 2), where the class would walk the whole directory. This catalog is the list of allowed classes.
if($null -eq (Get-Command Get-DomeniaExtendedProbeCatalog -CommandType Function -ErrorAction SilentlyContinue)){
    . (Join-Path $PSScriptRoot 'Domenia-ProbeCatalog.Model.ps1')
}
function Get-DomeniaProbeCatalog {
    $cached=Get-Variable -Name DomeniaProbeCatalog -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $cached -and $null -ne $cached.Value) { return $cached.Value }
    $table = @'
hw.maker|Materiel|Fabricant|root\cimv2|Win32_ComputerSystem|Manufacturer||First|Text|Pie
hw.model|Materiel|Modele|root\cimv2|Win32_ComputerSystem|Model||First|Text|Bar
hw.ram|Materiel|Memoire installee|root\cimv2|Win32_ComputerSystem|TotalPhysicalMemory||First|GB|Column
hw.cpu|Materiel|Processeur|root\cimv2|Win32_Processor|Name||First|Text|Bar
hw.cpuload|Materiel|Charge CPU du premier processeur (%)|root\cimv2|Win32_Processor|LoadPercentage||First|Number|Column
hw.cpumhz|Materiel|Frequence maximale CPU (MHz)|root\cimv2|Win32_Processor|MaxClockSpeed||First|Number|Column
hw.virtualization|Materiel|Virtualisation activee dans le firmware|root\cimv2|Win32_Processor|VirtualizationFirmwareEnabled||First|Map:True=Oui;False=Non|Pie
hw.slat|Materiel|Traduction SLAT du processeur|root\cimv2|Win32_Processor|SecondLevelAddressTranslationExtensions||First|Map:True=Oui;False=Non|Pie
hw.batterylevel|Materiel|Charge restante de la premiere batterie (%)|root\cimv2|Win32_Battery|EstimatedChargeRemaining||First|Number|Column
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
os.virtualfree|Systeme|Memoire virtuelle libre (Go)|root\cimv2|Win32_OperatingSystem|FreeVirtualMemory||First|GBfromKB|Column
os.visiblememory|Systeme|Memoire visible par Windows (Go)|root\cimv2|Win32_OperatingSystem|TotalVisibleMemorySize||First|GBfromKB|Column
os.users|Systeme|Utilisateurs declares connectes par Windows|root\cimv2|Win32_OperatingSystem|NumberOfUsers||First|Number|Column
os.producttype|Systeme|Role Windows|root\cimv2|Win32_OperatingSystem|ProductType||First|Map:1=Poste;2=Controleur de domaine;3=Serveur|Pie
disk.cfree|Disques|Espace libre sur C: (%)|root\cimv2|Win32_LogicalDisk|FreeSpace,Size|DeviceID='C:'|First|PercentFree|Column
disk.csize|Disques|Taille de C: (Go)|root\cimv2|Win32_LogicalDisk|Size|DeviceID='C:'|First|GB|Column
disk.count|Disques|Nombre de volumes locaux|root\cimv2|Win32_LogicalDisk|DeviceID|DriveType=3|Count|Number|Column
disk.media|Disques|Type de disque physique|root\Microsoft\Windows\Storage|MSFT_PhysicalDisk|MediaType||First|Map:3=Disque dur;4=SSD;5=SCM;0=Non precise|Pie
disk.health|Disques|Sante du disque physique|root\Microsoft\Windows\Storage|MSFT_PhysicalDisk|HealthStatus||First|Map:0=Sain;1=Avertissement;2=Defaillant;5=Inconnu|Pie
disk.removable|Disques|Supports amovibles connectes|root\cimv2|Win32_LogicalDisk|DeviceID|DriveType=2|Count|Number|Column
sec.bitlocker|Securite|Protection BitLocker de C:|root\cimv2\Security\MicrosoftVolumeEncryption|Win32_EncryptableVolume|ProtectionStatus|DriveLetter='C:'|First|Map:0=Non protege;1=Protege;2=Inconnu|Pie
sec.av|Securite|Antivirus declare|root\SecurityCenter2|AntiVirusProduct|displayName||All|Text|Bar
sec.localusers|Securite|Comptes locaux actives|root\cimv2|Win32_UserAccount|Name|LocalAccount=TRUE AND Disabled=FALSE|Count|Number|Column|NoDC
sec.shares|Securite|Partages de fichiers déclarés|root\cimv2|Win32_Share|Name|Type=0|Count|Number|Column
sec.defender|Securite|Antivirus Defender actif|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|AntivirusEnabled||First|Map:True=Oui;False=Non|Pie
sec.realtime|Securite|Protection temps reel Defender|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|RealTimeProtectionEnabled||First|Map:True=Oui;False=Non|Pie
sec.behavior|Securite|Surveillance comportementale Defender|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|BehaviorMonitorEnabled||First|Map:True=Oui;False=Non|Pie
sec.signatures|Securite|Age signatures Defender (j, 65535 jamais)|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|AntivirusSignatureAge||First|Number|Column
sec.quickscan|Securite|Age analyse rapide Defender (j, 65535 jamais)|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|QuickScanAge||First|Number|Column
sec.fullscan|Securite|Age analyse complete Defender (j, 65535 jamais)|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|FullScanAge||First|Number|Column
sec.defenderversion|Securite|Version du produit Defender|root\Microsoft\Windows\Defender|MSFT_MpComputerStatus|AMProductVersion||First|Text|Bar
sec.tpmversion|Securite|Specification TPM|root\CIMV2\Security\MicrosoftTpm|Win32_Tpm|SpecVersion||First|Text|Pie
sec.tpmenabled|Securite|TPM active au releve|root\CIMV2\Security\MicrosoftTpm|Win32_Tpm|IsEnabled_InitialValue||First|Map:True=Oui;False=Non|Pie
sec.tpmactivated|Securite|TPM operationnel au releve|root\CIMV2\Security\MicrosoftTpm|Win32_Tpm|IsActivated_InitialValue||First|Map:True=Oui;False=Non|Pie
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
soft.winrm|Logiciels et services|Service WinRM|root\cimv2|Win32_Service|State|Name='WinRM'|First|Text|Pie
soft.bits|Logiciels et services|Service BITS|root\cimv2|Win32_Service|State|Name='BITS'|First|Text|Pie
soft.w32time|Logiciels et services|Service Heure Windows|root\cimv2|Win32_Service|State|Name='W32Time'|First|Text|Pie
soft.rdp|Logiciels et services|Service Bureau a distance|root\cimv2|Win32_Service|State|Name='TermService'|First|Text|Pie
soft.firewall|Logiciels et services|Service Pare-feu Windows|root\cimv2|Win32_Service|State|Name='MpsSvc'|First|Text|Pie
soft.defender|Logiciels et services|Service Antivirus Defender|root\cimv2|Win32_Service|State|Name='WinDefend'|First|Text|Pie
soft.dnsclient|Logiciels et services|Service Client DNS|root\cimv2|Win32_Service|State|Name='Dnscache'|First|Text|Pie
soft.hotfixcount|Logiciels et services|Nombre de correctifs CBS visibles|root\cimv2|Win32_QuickFixEngineering|HotFixID||Count|Number|Column
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
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($probe in $catalog){[void]$ids.Add([string]$probe.Id)}
    foreach($probe in @(Get-DomeniaExtendedProbeCatalog)){
        if(-not $ids.Add([string]$probe.Id)){throw 'Identifiant de sonde répété entre les catalogues.'}
        [void]$catalog.Add($probe)
    }
    $script:DomeniaProbeCatalog = @($catalog | ForEach-Object { Add-DomeniaProbeMetadata $_ })
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
function New-DomeniaObservationReader {
    $definitions=[Collections.Generic.List[Domenia.Native.ProbeDefinition]]::new()
    foreach($probe in @(Get-DomeniaProbeCatalog)){
        $numeric=([string]$probe.Transform -notlike 'Map:*') -and ([string]$probe.Mode -eq 'Count' -or [string]$probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree|Year)$')
        $definitions.Add([Domenia.Native.ProbeDefinition]@{Id=$probe.Id;Mode=$probe.Mode;Transform=$probe.Transform;QueryNumeric=$numeric})
    }
    return [Domenia.Native.ObservationReader]::new($definitions.ToArray())
}
function ConvertTo-DomeniaProbeNumber {
    # Invariant number of a raw WMI value, $null when the value is not a number (a bad reading is left out, never 0).
    param($Value)
    $number = 0.0
    if ([double]::TryParse(([string]$Value).Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) { return $number }
    return $null
}
function Get-DomeniaProbeValues {
    # Values of one probe for one workstation, after the transform: strings (categories) or numbers. A result in error,
    # skipped on a domain controller or not readable gives no value: the workstation is then not counted.
    param($Probe,$Result)
    if ($null -eq $Probe -or $null -eq $Result -or [string]$Result.Error) { return @() }
    if($Result -is [Domenia.Native.ProbeResult] -and $Result.Prepared){return @($Result.Values)}
    $skipped = $Result.PSObject.Properties['Skipped']
    if (($null -ne $skipped) -and [string]$skipped.Value) { return @() }
    if([string]$Probe.Mode -ne 'Count' -and $null -ne $Result.PSObject.Properties['Truncated'] -and [bool]$Result.Truncated){return @()}
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
    param($Probe,[object[]]$Results,[string]$Visual,$Samples=$null)
    if($null -eq $Samples){
        $Samples=[Domenia.Native.ProbeSamples]::new()
        foreach($result in @($Results)){
            if($null -ne $result -and [string](Get-DomeniaMember $result 'Skipped')){$Samples.Skip();continue}
            if($Probe.Mode -eq 'All'){$Samples.AddUnique(@(Get-DomeniaProbeValues $Probe $result),[datetime]::UtcNow)}else{$Samples.Add(@(Get-DomeniaProbeValues $Probe $result),[datetime]::UtcNow)}
        }
    }
    $values=$Samples.Values;$machines=$Samples.Machines;$skipped=$Samples.Skipped;$numeric=$Samples.Numeric
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $unit = Get-DomeniaProbeUnit -Probe $Probe
    $format = { param([double]$Number) return $Number.ToString('0.#', $fr) }
    $items = @()
    # Distinct numbers only once the values are known to be numeric (text such as a version or an address stays text).
    $distinct = if ($numeric) { @($Samples.Distinct) } else { @() }
    if ($numeric -and $Visual -ne 'Pie' -and $distinct.Count -le 8 -and [string]$Probe.Transform -match '^(Number|DaysSince)$') {
        # Few distinct values (screens, printers, cores...): one bar per value, in order.
        $items = @(foreach ($d in $distinct) { [pscustomobject]@{ Label = ((& $format $d) + $unit); Value = [double]$Samples.CountEqual($d); ExactValue=[double]$d } })
        $sum = $Samples.Sum
        $summary = 'Moyenne ' + (& $format ([Math]::Round($sum / $values.Count,1))) + ' · min ' + (& $format $distinct[0]) + ' · max ' + (& $format $distinct[-1])
    }
    elseif ($numeric -and $Visual -ne 'Pie') {
        $sorted = @($Samples.Min,$Samples.Max)
        $max = [double]$sorted[-1]
        # Rounded edges for a plain number (1, 2 or 5 x 10^n), fixed edges for sizes, ages, shares and speeds.
        $niceEdges = @((Get-DomeniaChartTicks -Maximum $max -Integer -Count 5).Ticks | Where-Object { ($_ -gt 0) -and ($_ -lt $max) })
        $edges = switch -Regex ([string]$Probe.Transform) { '^GB' { @(4,8,16,32,64,128,256,512) } '^DaysSince$' { @(1,7,30,90,180,365) } '^PercentFree$' { @(10,25,50,75) } '^Mbps$' { @(100,1000) } default { if ($max -le 10) { @(0,1,2,3,5,10) } else { $niceEdges } } }
        $edges = @($edges | Select-Object -Unique)
        if (-not $edges.Count) { $edges = @([Math]::Ceiling($max)) }
        $items = for ($i = 0; $i -le $edges.Count; $i++) {
            $low = if ($i -eq 0) { [double]::NegativeInfinity } else { [double]$edges[$i-1] }
            $high = if ($i -eq $edges.Count) { [double]::PositiveInfinity } else { [double]$edges[$i] }
            $label = if ($i -eq 0) { [string][char]0x2264 + ' ' + (& $format $edges[0]) + $unit } elseif ($i -eq $edges.Count) { '> ' + (& $format $edges[$i-1]) + $unit } elseif (([double]$edges[$i] - [double]$edges[$i-1]) -le 1) { (& $format $edges[$i]) + $unit } else { '> ' + (& $format $edges[$i-1]) + ' à ' + (& $format $edges[$i]) + $unit }
            [pscustomobject]@{ Label = $label; Value = [double]$Samples.CountRange($low,$high); Low=$low; High=$high }
        }
        $sum = $Samples.Sum
        $summary = 'Moyenne ' + (& $format ([Math]::Round($sum / $values.Count,1))) + ' · min ' + (& $format $sorted[0]) + ' · max ' + (& $format $sorted[-1])
    } else {
        $groups = @($Samples.Groups())
        $items = @($groups | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label; Value = [double]$_.Value } })
        $others = $Samples.CountOther([string[]]@($groups|Select-Object -First 8|ForEach-Object{$_.Label}))
        if ($others -gt 0) { $items += [pscustomobject]@{ Label = 'Autres'; Value = [double]$others; Excluded=@($groups|Select-Object -First 8|ForEach-Object{$_.Label}) } }
        $summary = if ($groups.Count) { 'Le plus fréquent : ' + [string]$groups[0].Label + ' (' + $groups[0].Value + ')' } else { 'Aucune valeur' }
    }
    return [pscustomobject]@{ Items = @($items); Machines = $machines; Summary = $summary; Numeric = $numeric; Values = $values.ToArray(); Skipped = $skipped; Samples=$Samples }
}
function Measure-DomeniaFleetProbeEntries {
    # Pure worker aggregation. Identity checks and observation traversal are shared by all requested widgets.
    param($Fleet,[hashtable]$Observations=@{},[object[]]$Requests=@(),[int]$MaxAgeDays=30,[datetime]$NowUtc=[datetime]::UtcNow)
    if($null -eq $Observations){$Observations=@{}}
    $buckets=@{};$entries=@{}
    foreach($request in $Requests){
        $id=[string]$request.Key
        if($buckets.ContainsKey($id)){continue}
        $probe=Get-DomeniaProbe $id;if($null -eq $probe){continue}
        $buckets[$id]=[pscustomobject]@{Probe=$probe;Samples=[Domenia.Native.ProbeSamples]::new()}
    }
    if(-not $buckets.Count){return $entries}
    $nativeBatch=[Domenia.Native.ProbeBatch]::new([string[]]@($buckets.Keys))
    foreach($id in $buckets.Keys){$buckets[$id].Samples=$nativeBatch.Buckets[$id]}
    $targets=Get-DomeniaMemberValue $Fleet 'Targets' @()
    foreach($target in $targets){
        $observation=$Observations[([string]$target.distinguished_name).ToLowerInvariant()]
        $observedGuid=[string](Get-DomeniaMember $observation 'Guid');$expectedGuid=[string]$target.object_guid
        if(-not $expectedGuid -or -not $observedGuid -or $expectedGuid.Trim().Trim('{','}').ToLowerInvariant() -ne $observedGuid.Trim().Trim('{','}').ToLowerInvariant()){continue}
        $probes=Get-DomeniaMemberValue $observation 'Probes'
        $ids=if($observation -is [Domenia.Native.Observation]){@($nativeBatch.Add($observation,$NowUtc,$MaxAgeDays))}else{@($buckets.Keys)}
        foreach($id in $ids){
            $result=Get-DomeniaMemberValue $probes $id;if($null -eq $result){continue}
            $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
            if((Test-DomeniaObservationAge -CheckedUtc $at -NowUtc $NowUtc -MaxDays $MaxAgeDays) -eq 'Expired'){continue}
            $bucket=$buckets[$id]
            if([string](Get-DomeniaMember $result 'Skipped')){$bucket.Samples.Skip();continue}
            if($bucket.Probe.Mode -eq 'All'){$bucket.Samples.AddUnique(@(Get-DomeniaProbeValues $bucket.Probe $result),$at)}else{$bucket.Samples.Add(@(Get-DomeniaProbeValues $bucket.Probe $result),$at)}
        }
    }
    foreach($request in $Requests){
        $id=[string]$request.Key;$visual=[string]$request.Visual;$key=$id+'|'+$visual
        if($entries.ContainsKey($key) -or -not $buckets.ContainsKey($id)){continue}
        $bucket=$buckets[$id]
        $measure=Measure-DomeniaWidgetData -Probe $bucket.Probe -Samples $bucket.Samples -Visual $visual
        $entry=ConvertFrom-DomeniaProbeMeasure -Probe $bucket.Probe -Measured $measure -Board Fleet -Key $id
        if($measure.Machines){
            $coverage=Get-DomeniaCoverageText -Analysed $measure.Machines -Total $targets.Count -LastUtc $bucket.Samples.Newest
            $entry.Detail=([string]$entry.Detail+' · '+$coverage);$entry.Subtitle=$coverage
            if($bucket.Probe.Mode -eq 'All'){$entry.Detail+=' · Un poste peut figurer dans plusieurs catégories.'}
            if($null -ne $bucket.Samples.Oldest -and ($NowUtc-$bucket.Samples.Oldest).TotalDays -gt 7){$entry.State='Off'}
        }
        $entries[$key]=$entry
    }
    return $entries
}
function ConvertFrom-DomeniaEdidText {
    # EDID text fields of WmiMonitorID are arrays of character codes ended by zeros. Only printable ASCII is kept;
    # an absent or unreadable array gives '' (unknown), never an invented name.
    param($Codes)
    if ($null -eq $Codes) { return '' }
    if ($Codes -is [string]) { return ([string]$Codes).Trim() }
    $builder = New-Object System.Text.StringBuilder
    foreach ($code in @($Codes)) {
        $number = ConvertTo-DomeniaProbeNumber $code
        if ($null -eq $number -or $number -eq 0) { break }
        if (($number -ge 32) -and ($number -le 126)) { [void]$builder.Append([char][int]$number) }
        if ($builder.Length -ge 64) { break }
    }
    return $builder.ToString().Trim()
}
function Get-DomeniaMonitorIdentity {
    # Stable text of one WmiMonitorID instance: name, maker code, product code and serial when the EDID gives them.
    # Two screens of the same model without serial number cannot be told apart, and the text says so.
    param($Values)
    if ($null -eq $Values) { return '' }
    $name = ConvertFrom-DomeniaEdidText (Get-DomeniaMemberValue $Values 'UserFriendlyName')
    $maker = ConvertFrom-DomeniaEdidText (Get-DomeniaMemberValue $Values 'ManufacturerName')
    $product = ConvertFrom-DomeniaEdidText (Get-DomeniaMemberValue $Values 'ProductCodeID')
    $serial = ConvertFrom-DomeniaEdidText (Get-DomeniaMemberValue $Values 'SerialNumberID')
    if (-not $maker -and -not $product -and -not $name) { return '' }
    $label = if ($name) { $name } else { 'Écran sans nom EDID' }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($label)
    if ($maker) { $parts.Add('fabricant ' + $maker) }
    if ($product) { $parts.Add('produit ' + $product) }
    if ($serial -and $serial -ne '0') { $parts.Add('n° ' + $serial) } else { $parts.Add('sans numéro de série') }
    return ($parts.ToArray() -join ' · ')
}
function Get-DomeniaProbeHistoryPolicy {
    # Probes whose committed payload keeps a bounded history (points 82 and 87); every other probe keeps none.
    # Series: at most one sample per MinSpacingHours. Changes: a sample only when the observed set differs.
    param([string]$ProbeId)
    if ($ProbeId -ceq 'disk.volumes') { return [pscustomobject]@{ Kind = 'Series'; MinSpacingHours = 6; MaxSamples = 60; MaxAgeDays = 400; MaxItems = 26 } }
    if ($ProbeId -ceq 'hw.monitors') { return [pscustomobject]@{ Kind = 'Changes'; MinSpacingHours = 0; MaxSamples = 20; MaxAgeDays = 400; MaxItems = 16 } }
    return $null
}
function ConvertTo-DomeniaProbeHistoryItem {
    # Validated copy of one stored sample, or $null. Stored history is checked again: a damaged sample is dropped.
    param($Item,[string]$ProbeId,$Policy)
    if ($null -eq $Item -or $null -eq $Policy) { return $null }
    $at = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Item 'AtUtc' $null)
    if ($null -eq $at) { return $null }
    $raw = @(Get-DomeniaMember $Item 'Items' @())
    if ($raw.Count -gt [int]$Policy.MaxItems) { return $null }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($value in $raw) {
        if ($Policy.Kind -ceq 'Series') {
            $id = ([string](Get-DomeniaMember $value 'Id' '')).Trim().ToUpperInvariant()
            $size = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $value 'Size' $null)
            $free = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $value 'Free' $null)
            if (($id -notmatch '^[A-Z]:$') -or ($null -eq $size) -or ($null -eq $free) -or ($size -le 0) -or ($free -lt 0) -or ($free -gt $size)) { return $null }
            $items.Add([pscustomobject]@{ Id = $id; Size = [double]$size; Free = [double]$free })
        } else {
            $text = [string]$value
            if ((-not $text) -or ($text.Length -gt 200)) { return $null }
            $items.Add($text)
        }
    }
    return [pscustomobject]@{ AtUtc = $at.ToString('o'); Items = $items.ToArray() }
}
function Get-DomeniaProbeHistorySample {
    # One sample from a complete probe entry; $null for an error, a skip, a partial read or an undated entry.
    param([string]$ProbeId,$Entry,$Policy)
    if ($null -eq $Entry -or $null -eq $Policy) { return $null }
    if (([string](Get-DomeniaMember $Entry 'Error' '')) -or ([string](Get-DomeniaMember $Entry 'Skipped' '')) -or ([bool](Get-DomeniaMember $Entry 'Truncated' $false))) { return $null }
    $at = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Entry 'CheckedUtc' $null)
    if ($null -eq $at) { return $null }
    $instances = @(Get-DomeniaMember $Entry 'Instances' @())
    if ($instances.Count -gt [int]$Policy.MaxItems) { return $null }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($instance in $instances) {
        $values = Get-DomeniaMemberValue $instance 'Values'
        if ($ProbeId -ceq 'disk.volumes') {
            $id = ([string](Get-DomeniaMember $values 'DeviceID' '')).Trim().ToUpperInvariant()
            $size = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $values 'Size' $null)
            $free = ConvertTo-DomeniaProbeNumber (Get-DomeniaMember $values 'FreeSpace' $null)
            if (($id -notmatch '^[A-Z]:$') -or ($null -eq $size) -or ($null -eq $free) -or ($size -le 0) -or ($free -lt 0) -or ($free -gt $size)) { continue }
            $items.Add([pscustomobject]@{ Id = $id; Size = [double]$size; Free = [double]$free })
        } elseif ($ProbeId -ceq 'hw.monitors') {
            $identity = Get-DomeniaMonitorIdentity $values
            if ($identity -and -not $items.Contains($identity)) { $items.Add($identity) }
        }
    }
    $list = $items.ToArray()
    if ($ProbeId -ceq 'hw.monitors') {
        # Ordinal order: the same set compares equal whatever the culture of the session that stored it.
        $names = [string[]]@($list)
        [Array]::Sort($names,[StringComparer]::Ordinal)
        $list = [object[]]$names
    }
    return [pscustomobject]@{ AtUtc = $at.ToString('o'); Items = @($list) }
}
function Copy-DomeniaProbeHistoryMap {
    # Shallow ordered copy of a PSCustomObject or dictionary, so a frozen batch object is never modified in place.
    param($Value)
    $map = [ordered]@{}
    if ($Value -is [Collections.IDictionary]) { foreach ($key in @($Value.Keys)) { $map[[string]$key] = $Value[$key] } }
    elseif ($null -ne $Value) { foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = $property.Value } }
    return $map
}
function Add-DomeniaProbeHistory {
    # Points 82 and 87: bounded per-workstation history kept inside the newest successful family payload, oldest
    # first, built from the previous committed payload of the same family. Pure: the storage worker supplies both.
    # Returns a new payload, or $null when the probe keeps no history or the new entry is not a complete reading
    # (the payload is then stored as it came). Samples dated after the new reading are dropped, never reordered.
    param($Data,$PreviousData,[string]$ProbeId)
    $policy = Get-DomeniaProbeHistoryPolicy $ProbeId
    if ($null -eq $policy -or $null -eq $Data) { return $null }
    $probes = Get-DomeniaMemberValue $Data 'Probes'
    $entry = Get-DomeniaMemberValue $probes $ProbeId
    $sample = Get-DomeniaProbeHistorySample -ProbeId $ProbeId -Entry $entry -Policy $policy
    if ($null -eq $sample) { return $null }
    $now = ConvertTo-DomeniaUtcDate $sample.AtUtc
    $previousEntry = Get-DomeniaMemberValue (Get-DomeniaMemberValue $PreviousData 'Probes') $ProbeId
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($old in @(Get-DomeniaMember $previousEntry 'History' @())) {
        $checked = ConvertTo-DomeniaProbeHistoryItem -Item $old -ProbeId $ProbeId -Policy $policy
        if ($null -eq $checked) { continue }
        $at = ConvertTo-DomeniaUtcDate $checked.AtUtc
        if (($at -ge $now) -or (($now - $at).TotalDays -gt [double]$policy.MaxAgeDays)) { continue }
        $kept.Add($checked)
    }
    $ordered = @($kept.ToArray() | Sort-Object { (ConvertTo-DomeniaUtcDate $_.AtUtc).Ticks })
    $append = $true
    if ($ordered.Count) {
        $last = $ordered[$ordered.Count - 1]
        if ($policy.Kind -ceq 'Series') { $append = (($now - (ConvertTo-DomeniaUtcDate $last.AtUtc)).TotalHours -ge [double]$policy.MinSpacingHours) }
        else { $append = ((@($last.Items) -join "`n") -cne (@($sample.Items) -join "`n")) }
    }
    $history = New-Object System.Collections.Generic.List[object]
    foreach ($item in $ordered) { $history.Add($item) }
    if ($append) { $history.Add($sample) }
    while ($history.Count -gt [int]$policy.MaxSamples) { $history.RemoveAt(0) }
    $entryCopy = Copy-DomeniaProbeHistoryMap $entry
    $entryCopy['History'] = $history.ToArray()
    $probesCopy = Copy-DomeniaProbeHistoryMap $probes
    $probesCopy[$ProbeId] = [pscustomobject]$entryCopy
    $dataCopy = Copy-DomeniaProbeHistoryMap $Data
    $dataCopy['Probes'] = [pscustomobject]$probesCopy
    return [pscustomobject]$dataCopy
}
