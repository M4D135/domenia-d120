# Windows PowerShell 5.1, hosted CI runner only. Read-only probe of WSMan.Automation call shapes against localhost.
# Nothing is changed: no service, listener, TrustedHosts, firewall or policy. Only codes, stages and element names are
# recorded; WS-Management fault messages and instance values are never written.
param([Parameter(Mandatory = $true)][string]$OutFile)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Prefix = 'http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/'
$Wql = 'http://schemas.microsoft.com/wbem/wsman/1/WQL'
$Negotiate = 0x20000
$Kerberos = 0x80000

function Hex([int]$value) { return ('0x{0:X8}' -f $value) }

function Describe($record) {
    $chain = @()
    $e = $record.Exception
    while ($null -ne $e) {
        $chain += [ordered]@{ type = $e.GetType().FullName; hresult = (Hex $e.HResult) }
        $e = $e.InnerException
    }
    return ,$chain
}

function Load-Xml([string]$xml) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.LoadXml($xml)
    return $doc
}

function Read-Fault($session) {
    $fault = [ordered]@{ errorReadable = $false; errorChain = $null; hasXml = $false; wsmanFaultCode = $null; faultChildren = @() }
    if ($null -eq $session) { return $fault }
    try {
        $xml = [string]$session.Error
        $fault['errorReadable'] = $true
        if ($xml.Length -gt 0) {
            $fault['hasXml'] = $true
            $node = (Load-Xml $xml).SelectSingleNode("//*[local-name()='WSManFault']")
            if ($null -ne $node) {
                $fault['wsmanFaultCode'] = $node.GetAttribute('Code')
                foreach ($child in $node.SelectNodes('.//*')) { $fault['faultChildren'] += $child.LocalName }
            }
        }
    } catch { $fault['errorChain'] = Describe $_ }
    return $fault
}

function Shape([string]$xml) {
    $root = (Load-Xml $xml).DocumentElement
    $children = @()
    foreach ($child in $root.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) { $children += ($child.NamespaceURI + ' | ' + $child.LocalName) }
    }
    return [ordered]@{ localName = $root.LocalName; namespace = $root.NamespaceURI; children = @($children | Select-Object -Unique) }
}

function Pattern([string]$text) {
    # Value format only: digits become 9 and letters a, capped, so a date or boolean form is visible without the value.
    if ($text.Length -gt 40) { $text = $text.Substring(0, 40) + '...' }
    return (($text -replace '[0-9]', '9') -replace '[A-Za-z]', 'a')
}

function Property-Shapes([string]$xml) {
    $root = (Load-Xml $xml).DocumentElement
    $shapes = [ordered]@{}
    foreach ($child in $root.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $kind = 'text ' + (Pattern $child.InnerText)
        if ($child.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -in @('true', '1')) { $kind = 'nil' }
        else {
            $inner = @($child.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
            if ($inner.Count -gt 0) { $kind = 'elements ' + (($child.SelectNodes('.//*') | ForEach-Object { $names = @($_.Attributes | ForEach-Object { $_.LocalName + '=' + (Pattern $_.Value) }) -join ','; $_.NamespaceURI + ' | ' + $_.LocalName + ' [' + $names + ']' + ' = ' + (Pattern $(if ($_.HasChildNodes -and $_.FirstChild.NodeType -eq [System.Xml.XmlNodeType]::Text) { $_.FirstChild.Value } else { '' })) }) -join ' ; ') }
        }
        $key = $child.LocalName
        if ($shapes.Contains($key)) { $shapes[$key] = 'repeated: ' + $kind } else { $shapes[$key] = $kind }
    }
    return [ordered]@{ root = ($root.NamespaceURI + ' | ' + $root.LocalName); childNamespaces = @($root.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element } | ForEach-Object { $_.NamespaceURI } | Select-Object -Unique); properties = $shapes }
}

function Invoke-Query([string]$ns, [string]$query) {
    $entry = [ordered]@{ namespace = $ns; query = $query; stage = 'CreateSession'; ok = $false; itemCount = 0; errorChain = $null; fault = $null; firstItem = $null }
    $automation = $null; $session = $null; $enumerator = $null
    try {
        $automation = New-Object -ComObject WSMan.Automation
        $session = $automation.CreateSession('http://localhost:5985/wsman', $Negotiate)
        $session.Timeout = 10000
        $entry['stage'] = 'Enumerate'
        $enumerator = $session.Enumerate('http://schemas.microsoft.com/wbem/wsman/1/wmi/' + $ns.Replace('\', '/') + '/*', $query, $Wql, 0)
        while ($entry['itemCount'] -lt 50) {
            $entry['stage'] = 'AtEndOfStream'
            if ($enumerator.AtEndOfStream) { break }
            $entry['stage'] = 'ReadItem'
            $xml = [string]$enumerator.ReadItem()
            $entry['itemCount'] = $entry['itemCount'] + 1
            if ($entry['itemCount'] -eq 1) { $entry['firstItem'] = Property-Shapes $xml }
        }
        $entry['stage'] = 'Done'
        $entry['ok'] = $true
    } catch {
        $entry['errorChain'] = Describe $_
        $entry['fault'] = Read-Fault $session
    } finally {
        foreach ($item in @($enumerator, $session, $automation)) {
            if ($null -ne $item) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) } catch { } }
        }
    }
    return $entry
}

function Invoke-Trial([string]$name, [int]$flags, [string]$resource, $filter, $dialect, [int]$timeoutMs) {
    $trial = [ordered]@{ name = $name; flags = (Hex $flags); resource = $resource; filter = $filter; dialect = $dialect; timeoutMs = $timeoutMs
        stage = 'CreateObject'; ok = $false; itemCount = 0; elapsedMs = 0; errorChain = $null; fault = $null; firstItem = $null }
    $automation = $null; $session = $null; $enumerator = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $automation = New-Object -ComObject WSMan.Automation
        $trial['stage'] = 'CreateSession'
        $session = $automation.CreateSession('http://localhost:5985/wsman', $flags)
        if ($timeoutMs -gt 0) { $trial['stage'] = 'Timeout'; $session.Timeout = $timeoutMs }
        $trial['stage'] = 'Enumerate'
        if ($null -eq $filter) { $enumerator = $session.Enumerate($resource) }
        else { $enumerator = $session.Enumerate($resource, $filter, $dialect, 0) }
        while ($trial['itemCount'] -lt 3) {
            $trial['stage'] = 'AtEndOfStream'
            if ($enumerator.AtEndOfStream) { break }
            $trial['stage'] = 'ReadItem'
            $xml = [string]$enumerator.ReadItem()
            $trial['itemCount'] = $trial['itemCount'] + 1
            if ($trial['itemCount'] -eq 1) { $trial['firstItem'] = Shape $xml }
        }
        $trial['stage'] = 'Done'
        $trial['ok'] = $true
    } catch {
        $trial['errorChain'] = Describe $_
        $trial['fault'] = Read-Fault $session
    } finally {
        $trial['elapsedMs'] = [int]$watch.ElapsedMilliseconds
        foreach ($item in @($enumerator, $session, $automation)) {
            if ($null -ne $item) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) } catch { } }
        }
    }
    return $trial
}

$result = [ordered]@{ format = 'Domenia.WinRmShapeDiagnostic/1'; machineIsDomainJoined = $null; service = $null; listeners = @(); maxTimeoutMs = $null; trials = @(); queries = @() }
try { $result['machineIsDomainJoined'] = [bool](Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain } catch { }
try {
    $service = Get-Service -Name WinRM
    $result['service'] = [ordered]@{ status = [string]$service.Status; startType = [string]$service.StartType }
} catch { $result['service'] = [ordered]@{ errorChain = (Describe $_) } }

if ($null -ne $result['service'] -and $result['service'].Contains('status') -and $result['service']['status'] -eq 'Running') {
    try { foreach ($listener in Get-ChildItem WSMan:\localhost\Listener) { $result['listeners'] += (@($listener.Keys) -join ';') } } catch { $result['listeners'] = @('unreadable') }
    try { $result['maxTimeoutMs'] = [string](Get-Item WSMan:\localhost\MaxTimeoutms).Value } catch { }
    $os = 'SELECT Caption, Version, BuildNumber FROM Win32_OperatingSystem'
    $result['trials'] += Invoke-Trial 'A class resource + WQL projection' $Negotiate ($Prefix + 'Win32_OperatingSystem') $os $Wql 10000
    $result['trials'] += Invoke-Trial 'B wildcard resource + WQL projection' $Negotiate ($Prefix + '*') $os $Wql 10000
    $result['trials'] += Invoke-Trial 'C wildcard resource + SELECT *' $Negotiate ($Prefix + '*') 'SELECT * FROM Win32_OperatingSystem' $Wql 10000
    $result['trials'] += Invoke-Trial 'D class resource, empty filter and dialect' $Negotiate ($Prefix + 'Win32_OperatingSystem') '' '' 10000
    $result['trials'] += Invoke-Trial 'D2 class resource, filter omitted' $Negotiate ($Prefix + 'Win32_OperatingSystem') $null $null 10000
    $result['trials'] += Invoke-Trial 'E wildcard resource + projection with WHERE' $Negotiate ($Prefix + '*') 'SELECT ProcessId, Name FROM Win32_Process WHERE ProcessId <> 0' $Wql 10000
    $result['trials'] += Invoke-Trial 'F as B, timeout 60000' $Negotiate ($Prefix + '*') $os $Wql 60000
    $result['trials'] += Invoke-Trial 'G as B, timeout not set' $Negotiate ($Prefix + '*') $os $Wql 0
    $result['trials'] += Invoke-Trial 'H class resource + SELECT *' $Negotiate ($Prefix + 'Win32_OperatingSystem') 'SELECT * FROM Win32_OperatingSystem' $Wql 10000
    $result['trials'] += Invoke-Trial 'K as B with Kerberos only (product flags)' $Kerberos ($Prefix + '*') $os $Wql 10000
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Caption, Version, BuildNumber, OSLanguage, OSArchitecture, InstallDate, LastBootUpTime, LocalDateTime, TotalVisibleMemorySize, FreePhysicalMemory, SystemDrive FROM Win32_OperatingSystem'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Name, Domain, Manufacturer, Model, TotalPhysicalMemory, NumberOfLogicalProcessors, UserName, DomainRole, SystemType, PCSystemType, DNSHostName FROM Win32_ComputerSystem'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT SerialNumber, ChassisTypes FROM Win32_SystemEnclosure'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT ProcessId, Name, CreationDate, KernelModeTime, UserModeTime, WorkingSetSize FROM Win32_Process WHERE ProcessId <> 0'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Manufacturer, BIOSVersion, SMBIOSBIOSVersion, ReleaseDate FROM Win32_BIOS'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, LoadPercentage, Architecture, VirtualizationFirmwareEnabled FROM Win32_Processor'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT DeviceLocator, Capacity, Speed, Manufacturer, PartNumber FROM Win32_PhysicalMemory'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT DeviceID, VolumeName, FileSystem, Size, FreeSpace FROM Win32_LogicalDisk WHERE DriveType=3'
    $result['queries'] += Invoke-Query 'root\Microsoft\Windows\Storage' 'SELECT DeviceId, FriendlyName, MediaType, HealthStatus, Size FROM MSFT_PhysicalDisk'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT DeviceID, Model, Size, InterfaceType, Status FROM Win32_DiskDrive'
    $result['queries'] += Invoke-Query 'root\cimv2\Security\MicrosoftVolumeEncryption' 'SELECT DriveLetter, ProtectionStatus, ConversionStatus, EncryptionMethod FROM Win32_EncryptableVolume'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Name, NetConnectionStatus, Speed, MACAddress FROM Win32_NetworkAdapter WHERE PhysicalAdapter=True'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Description, MACAddress, IPAddress, IPSubnet, DefaultIPGateway, DNSServerSearchOrder, DHCPEnabled FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=True'
    $result['queries'] += Invoke-Query 'root\Microsoft\Windows\Defender' 'SELECT AntivirusEnabled, RealTimeProtectionEnabled, BehaviorMonitorEnabled, AntivirusSignatureAge, QuickScanAge, FullScanAge, AMProductVersion FROM MSFT_MpComputerStatus'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT HotFixID, Description, InstalledOn FROM Win32_QuickFixEngineering'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT LogonId, LogonType, StartTime FROM Win32_LogonSession WHERE LogonType=2 OR LogonType=10 OR LogonType=11 OR LogonType=12'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Antecedent, Dependent FROM Win32_LoggedOnUser'
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Name, SID, LocalAccount FROM Win32_Group WHERE LocalAccount=True AND SID=''S-1-5-32-544'''
    $result['queries'] += Invoke-Query 'root\cimv2' 'SELECT Name, DisplayName, State, StartMode, ProcessId, StartName, ExitCode FROM Win32_Service WHERE Name=''WinRM'''
    $result['queries'] += Invoke-Query 'root\StandardCimv2' 'SELECT LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess FROM MSFT_NetTCPConnection'
}

$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $json
exit 0
