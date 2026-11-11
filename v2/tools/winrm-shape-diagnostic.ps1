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

$result = [ordered]@{ format = 'Domenia.WinRmShapeDiagnostic/1'; machineIsDomainJoined = $null; service = $null; listeners = @(); maxTimeoutMs = $null; trials = @() }
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
}

$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $json
exit 0
