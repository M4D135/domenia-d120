# Windows PowerShell 5.1, lab bench only, run in the operator's own Windows session (Kerberos needs its logon).
# Read-only timing of the WinRM reads Domenia makes against one workstation name. Nothing is changed: no service,
# listener, TrustedHosts, firewall, policy or registry. Only stages, timings, codes and item counts are written;
# instance values, fault messages and the workstation name are never written. Each trial runs in its own hidden
# powershell.exe, stopped after TrialSeconds, so a blocked COM call cannot outlive the measurement.
param(
    [Parameter(Mandatory = $true)][string]$ComputerName,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [ValidateRange(15, 120)][int]$TrialSeconds = 45,
    [string]$Trial = '',
    [string]$Query = '',
    [int]$TimeoutMs = 0,
    [int]$Repeat = 1
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

if (($ComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') -or ($ComputerName -match '^[0-9.]+$')) {
    throw 'Nom DNS ou NetBIOS attendu.'
}

# Same text as WmiWorkstationReader (Systeme, then Carte mere).
$Queries = @{
    os = 'SELECT Caption, Version, BuildNumber, OSLanguage, OSArchitecture, InstallDate, LastBootUpTime, LocalDateTime, TotalVisibleMemorySize, FreePhysicalMemory, SystemDrive FROM Win32_OperatingSystem'
    cs = 'SELECT Name, Domain, Manufacturer, Model, TotalPhysicalMemory, NumberOfLogicalProcessors, UserName, DomainRole, SystemType, PCSystemType, DNSHostName FROM Win32_ComputerSystem'
    enclosure = 'SELECT SerialNumber, ChassisTypes FROM Win32_SystemEnclosure'
}
$Wildcard = 'http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/*'
$Wql = 'http://schemas.microsoft.com/wbem/wsman/1/WQL'
$Kerberos = 0x80000

function Hex([int]$value) { return ('0x{0:X8}' -f $value) }

function Chain($record) {
    $out = @()
    $e = $record.Exception
    while ($null -ne $e) {
        $out += ($e.GetType().FullName + ' ' + (Hex $e.HResult))
        $e = $e.InnerException
    }
    return ,$out
}

function Fault-Code($session) {
    if ($null -eq $session) { return $null }
    try {
        $xml = [string]$session.Error
        if ($xml.Length -eq 0) { return $null }
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.LoadXml($xml)
        $node = $doc.SelectSingleNode("//*[local-name()='WSManFault']")
        if ($null -ne $node) { return $node.GetAttribute('Code') }
        return 'none'
    } catch { return 'unreadable' }
}

# ---------------------------------------------------------------- one trial, in its own process
if ($Trial.Length -gt 0) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $steps = New-Object System.Collections.ArrayList
    $result = [ordered]@{ trial = $Trial; query = $Query; timeoutMs = $TimeoutMs; ok = $false; stage = 'Start'; items = 0
        elapsedMs = 0; errorChain = $null; wsmanFaultCode = $null; steps = $steps }
    $session = $null
    try {
        if (-not $Queries.ContainsKey($Query)) { throw 'Requete inconnue.' }
        $text = $Queries[$Query]
        if ($Trial -eq 'dcom') {
            $result['stage'] = 'Query'
            for ($i = 0; $i -lt $Repeat; $i++) {
                $items = @(Get-WmiObject -ComputerName $ComputerName -Namespace 'root\cimv2' -Query $text)
                $result['items'] = $items.Count
                [void]$steps.Add('Query' + $i + '@' + $watch.ElapsedMilliseconds)
            }
        } elseif ($Trial -eq 'cim') {
            $result['stage'] = 'NewCimSession'
            $option = New-CimSessionOption -Protocol Wsman
            $cim = New-CimSession -ComputerName $ComputerName -SessionOption $option -Authentication Kerberos -OperationTimeoutSec 30
            [void]$steps.Add('NewCimSession@' + $watch.ElapsedMilliseconds)
            try {
                for ($i = 0; $i -lt $Repeat; $i++) {
                    $result['stage'] = 'Query'
                    $items = @(Get-CimInstance -CimSession $cim -Namespace 'root/cimv2' -Query $text -OperationTimeoutSec 30)
                    $result['items'] = $items.Count
                    [void]$steps.Add('Query' + $i + '@' + $watch.ElapsedMilliseconds)
                }
            } finally { Remove-CimSession -CimSession $cim }
        } elseif ($Trial -eq 'wsman') {
            # Domenia's calls: two-argument CreateSession with Kerberos, Timeout from the budget, WQL on the wildcard resource,
            # then AtEndOfStream / ReadItem until the end.
            $result['stage'] = 'CreateObject'
            $automation = New-Object -ComObject WSMan.Automation
            $result['stage'] = 'CreateSession'
            $session = $automation.CreateSession('http://' + $ComputerName + ':5985/wsman', $Kerberos)
            $session.Timeout = $TimeoutMs
            [void]$steps.Add('CreateSession@' + $watch.ElapsedMilliseconds)
            $result['stage'] = 'Identify'
            [void]$session.Identify(0)
            [void]$steps.Add('Identify@' + $watch.ElapsedMilliseconds)
            for ($i = 0; $i -lt $Repeat; $i++) {
                $result['stage'] = 'Enumerate'
                $enumerator = $session.Enumerate($Wildcard, $text, $Wql, 0)
                [void]$steps.Add('Enumerate' + $i + '@' + $watch.ElapsedMilliseconds)
                $count = 0
                while ($true) {
                    $result['stage'] = 'AtEndOfStream'
                    if ($enumerator.AtEndOfStream) { break }
                    $result['stage'] = 'ReadItem'
                    [void]$enumerator.ReadItem()
                    $count++
                    [void]$steps.Add('ReadItem' + $i + '@' + $watch.ElapsedMilliseconds)
                }
                [void]$steps.Add('End' + $i + '@' + $watch.ElapsedMilliseconds)
                $result['items'] = $count
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($enumerator)
            }
        } else { throw 'Essai inconnu.' }
        $result['ok'] = $true
        $result['stage'] = 'Done'
    } catch {
        $result['errorChain'] = Chain $_
        $result['wsmanFaultCode'] = Fault-Code $session
        [void]$steps.Add('Failed:' + $result['stage'] + '@' + $watch.ElapsedMilliseconds)
    }
    $result['elapsedMs'] = [int]$watch.ElapsedMilliseconds
    [IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $result -Depth 6), (New-Object Text.UTF8Encoding($false)))
    exit 0
}

# ---------------------------------------------------------------- driver
$plan = @(
    @{ name = 'dcom-os'; trial = 'dcom'; query = 'os'; timeoutMs = 0; repeat = 2 },
    @{ name = 'cim-wsman-os'; trial = 'cim'; query = 'os'; timeoutMs = 0; repeat = 2 },
    @{ name = 'wsman-os-30s'; trial = 'wsman'; query = 'os'; timeoutMs = 30000; repeat = 2 },
    @{ name = 'wsman-os-10s'; trial = 'wsman'; query = 'os'; timeoutMs = 10000; repeat = 1 },
    @{ name = 'wsman-cs-10s'; trial = 'wsman'; query = 'cs'; timeoutMs = 10000; repeat = 1 },
    @{ name = 'wsman-enclosure-10s'; trial = 'wsman'; query = 'enclosure'; timeoutMs = 10000; repeat = 1 },
    @{ name = 'dcom-cs'; trial = 'dcom'; query = 'cs'; timeoutMs = 0; repeat = 1 }
)
$report = [ordered]@{ format = 'Domenia.WinRmBenchTiming/1'; startedUtc = [DateTime]::UtcNow.ToString('o')
    psVersion = $PSVersionTable.PSVersion.ToString(); trialSeconds = $TrialSeconds
    nameKind = $(if ($ComputerName.Contains('.')) { 'dns' } else { 'netbios' }); trials = @() }
$powershell = Join-Path $PSHOME 'powershell.exe'
foreach ($step in $plan) {
    $trialFile = $OutFile + '.' + $step.name + '.json'
    if (Test-Path -LiteralPath $trialFile) { throw ('Fichier d''essai deja present : ' + $trialFile) }
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-ComputerName', $ComputerName, '-OutFile', ('"' + $trialFile + '"'), '-Trial', $step.trial, '-Query', $step.query,
        '-TimeoutMs', [string]$step.timeoutMs, '-Repeat', [string]$step.repeat)
    $entry = [ordered]@{ name = $step.name; state = $null; wallMs = 0; exitCode = $null; result = $null }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if ($process.WaitForExit($TrialSeconds * 1000)) {
        $entry['state'] = 'Exited'
        $entry['exitCode'] = $process.ExitCode
    } else {
        $entry['state'] = 'Hung'
        try { $process.Kill(); [void]$process.WaitForExit(10000) } catch { $entry['state'] = 'HungNotKilled' }
    }
    $entry['wallMs'] = [int]$watch.ElapsedMilliseconds
    if (Test-Path -LiteralPath $trialFile) {
        $entry['result'] = Get-Content -LiteralPath $trialFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $report['trials'] += $entry
}
$report['endedUtc'] = [DateTime]::UtcNow.ToString('o')
[IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $report -Depth 8), (New-Object Text.UTF8Encoding($false)))
