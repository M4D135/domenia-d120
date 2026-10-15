#requires -Version 5.1
# Point 127: network fault injection at the network boundary. Faults: latency within and beyond the budget, wrong
# DNS (name not resolved, another workstation answering), refusals (access, logon, connection), partial pages of a
# directory read, disconnection in the middle of a CIM session, answers arriving out of order.
# Code under test is the shipped code: the LiveConsole worker body (Get-DomeniaLiveProbeCode), the storage worker,
# the error rules (Get-DomeniaStructuredError, Get-DomeniaErrorDecision) and the selection identity rules. Only the
# transport is replaced by doubles (Ping, CIM session and CIM reads). The worker resolves its target name with
# [Net.Dns] before its ping: every target here ends in '.invalid' (RFC 6761), so that resolution fails locally by
# construction. No AD, no remote call, no WPF. Not a qualification of the target network: the doubles reproduce the
# exceptions Windows raises, not the network itself.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
$t=$null;$e=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Initialize-DomeniaWinSqliteNative')},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
    $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
    elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
if($null -eq ('Domenia.SelectionIdentity' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia-Identity.Types.cs')}
# ProbeDetails.Model: Get-DomeniaLiveProbeCode prepends its detail functions to the worker body.
foreach($name in @('Common.Model','Engine.Model','Guard.Model','Access.Model','Live.Model','Probes.Model','ProbeDetails.Model','QueryLibrary.Model','Store.Model','Cache.Model','Storage.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
foreach($name in @('Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode')){
    $nodes=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $name)},$true))
    if($nodes.Count -ne 1){throw ('Fonction du coeur absente : '+$name)}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
. (Join-Path (Join-Path $PSScriptRoot 'fixtures') 'Domenia-LoadFixtures.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'fixtures') 'Domenia-Invariants.ps1')
$script:Worker=Get-DomeniaStorageWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($script:Worker,[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$script:Domain='DC=example,DC=invalid'
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-network-faults-'+[guid]::NewGuid().ToString('N'))
$cases=[Collections.Generic.List[object]]::new();$script:Checks=0
function Expect {param([bool]$Good,[string]$Name);$script:Checks++;if(-not $Good){throw $Name}}
function Case {param([string]$Name,[scriptblock]$Code)
    try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' @ '+$_.ScriptStackTrace)});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}

# ---------------------------------------------------------------- transport doubles around the shipped LiveConsole body
function New-NetworkFault {
    # Exceptions as Windows raises them at the transport boundary.
    param([string]$Kind)
    switch($Kind){
        'DnsNotFound' {return [Net.NetworkInformation.PingException]::new('Une exception s est produite pendant une demande PING.',[Net.Sockets.SocketException]::new(11001))}
        'RpcUnavailable' {return [Runtime.InteropServices.COMException]::new('Le serveur RPC n est pas disponible (fixture).',-2147023174)}
        'RpcCallFailed' {return [Runtime.InteropServices.COMException]::new('Echec de l appel de procedure distante (fixture).',-2147023170)}
        'Timeout' {return [TimeoutException]::new('The operation timed out (fixture).')}
        'AccessDenied' {return [UnauthorizedAccessException]::new('Acces refuse (fixture).')}
        'LogonFailure' {return [Runtime.InteropServices.COMException]::new('Nom d utilisateur ou mot de passe incorrect (fixture).',-2147023570)}
        'Refused' {return [Net.Sockets.SocketException]::new(10061)}
        'Reset' {return [Net.Sockets.SocketException]::new(10054)}
    }
    throw ('Panne inconnue : '+$Kind)
}
function Invoke-NetworkProbe {
    # PingFault / SessionFault / ReadFault: where the fault is raised. ReadFaultClass limits ReadFault to one class.
    # -Ping: the worker also checks presence; it then resolves the '.invalid' target name first (local failure).
    param([string]$Target='pc-01.example.invalid',[string]$PingFault='',[string]$SessionFault='',[string]$ReadFault='',[string]$ReadFaultClass='',
        [int]$DelayMs=0,[string]$ReportedName='PC-01',[string]$ReportedDns='pc-01',[string]$User='EXAMPLE\alex.demo',[switch]$Inventory,[switch]$NoConsole,[switch]$Ping)
    $Context=[pscustomobject]@{MachineCredential=$null;Credential=$null;Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid';UseCim=$true;OperationId='LiveConsole'}
    $Payload=[pscustomobject]@{Computer=$Target;Key='cn=pc-01,ou=postes,dc=example,dc=invalid';Guid='0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3';MethodSeconds=4;ValidateConsoleIdentity=$false;Inventory=[bool]$Inventory;ProbeUser=(-not [bool]$NoConsole);CollectPing=[bool]$Ping}
    $script:NetCalls=@{Ping=0;Sessions=0;Reads=0;Closes=0;Classes=[Collections.Generic.List[string]]::new()}
    $script:NetPlan=[pscustomobject]@{PingFault=$PingFault;SessionFault=$SessionFault;ReadFault=$ReadFault;ReadFaultClass=$ReadFaultClass;DelayMs=$DelayMs;Name=$ReportedName;Dns=$ReportedDns;User=$User}
    function Get-WMachineCredential {param($Context) return $null}
    function New-Object {
        param($TypeName)
        if($TypeName -ne 'Net.NetworkInformation.Ping'){throw ('Construction inattendue : '+$TypeName)}
        $o=[pscustomobject]@{}
        Add-Member -InputObject $o ScriptMethod Send {
            param($target,$ms)
            $script:NetCalls.Ping++
            if($script:NetPlan.DelayMs -gt 0){Start-Sleep -Milliseconds $script:NetPlan.DelayMs}
            if($script:NetPlan.PingFault){throw (New-NetworkFault $script:NetPlan.PingFault)}
            return [pscustomobject]@{Status='Success';RoundtripTime=$script:NetPlan.DelayMs}
        }
        Add-Member -InputObject $o ScriptMethod Dispose { }
        return $o
    }
    function New-CimSessionOption {param($Protocol,$ErrorAction) return [pscustomobject]@{Protocol=$Protocol}}
    function New-CimSession {
        param($ComputerName,$SessionOption,$OperationTimeoutSec,$Credential,$ErrorAction)
        $script:NetCalls.Sessions++
        if($script:NetPlan.DelayMs -gt 0){Start-Sleep -Milliseconds $script:NetPlan.DelayMs}
        if($script:NetPlan.SessionFault){throw (New-NetworkFault $script:NetPlan.SessionFault)}
        return [pscustomobject]@{Fixture=$true}
    }
    function Get-CimInstance {
        param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction,$Namespace,$Filter)
        $script:NetCalls.Reads++;$script:NetCalls.Classes.Add([string]$ClassName)
        if($script:NetPlan.ReadFault -and ((-not $script:NetPlan.ReadFaultClass) -or ($script:NetPlan.ReadFaultClass -eq [string]$ClassName))){throw (New-NetworkFault $script:NetPlan.ReadFault)}
        switch([string]$ClassName){
            'Win32_ComputerSystem' {return [pscustomobject]@{UserName=$script:NetPlan.User;Name=$script:NetPlan.Name;DNSHostName=$script:NetPlan.Dns;Manufacturer='Fixture';Model='Example';TotalPhysicalMemory=8589934592}}
            'Win32_OperatingSystem' {return [pscustomobject]@{Caption='Windows fixture';BuildNumber='26100';LastBootUpTime=[datetime]'2026-10-12'}}
            'Win32_LogicalDisk' {return [pscustomobject]@{Size=100GB;FreeSpace=40GB}}
        }
        throw ('Classe inattendue : '+$ClassName)
    }
    function Remove-CimSession {param($CimSession,$ErrorAction) $script:NetCalls.Closes++}
    return (& ([scriptblock]::Create((Get-DomeniaLiveProbeCode))))
}
function Get-NetworkDecision {param([string]$Kind);return (Get-DomeniaErrorDecision -Structured (Get-DomeniaStructuredError (New-NetworkFault $Kind) -Phase 'LiveConsole' -Provider 'CIM' -Target 'pc-01') -Text ([string](New-NetworkFault $Kind).Message))}
$script:Known=[pscustomobject]@{Key='cn=pc-01,ou=postes,dc=example,dc=invalid';Computer='pc-01.example.invalid';Guid='0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3';Outcome='Observed';CurrentUser='EXAMPLE\alex.demo';LastUser='EXAMPLE\alex.demo';ObservedUtc='2026-10-01T09:00:00.0000000Z';CheckedUtc='2026-10-01T09:00:00.0000000Z';UserCheckedUtc='2026-10-01T09:00:00.0000000Z';Source='CIM';LastSource='CIM';Detail='';Presence='En ligne';PresenceCheckedUtc='2026-10-01T09:00:00.0000000Z';PresenceDetail=''}
function Assert-KnownKept {
    # A failed read never erases nor rejuvenates the last real observation.
    param($Result,[string]$Name)
    $o=ConvertTo-DomeniaLiveObservation $Result $script:Known '2026-10-15T09:00:00.0000000Z'
    Expect (-not [string]$o.CurrentUser) ($Name+' : compte invente')
    Expect (([string]$o.LastUser -eq [string]$script:Known.LastUser) -and ([string]$o.ObservedUtc -eq [string]$script:Known.ObservedUtc)) ($Name+' : derniere observation effacee ou rajeunie')
}

# ---------------------------------------------------------------- storage helpers (partial pages, out of order)
# The production schema is the text Get-DomeniaSqliteSchemaText returns (its here-string expands the query library
# schema): the function is taken from the core and run, never its raw literal.
$schemaAst=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Get-DomeniaSqliteSchemaText')},$true))
if($schemaAst.Count -ne 1){throw 'Schema de production introuvable.'}
. ([scriptblock]::Create($schemaAst[0].Extent.Text))
$script:SchemaText=Get-DomeniaSqliteSchemaText
function New-NetworkBase {
    param([string]$Name)
    if(($script:SchemaText -notmatch 'CREATE TABLE IF NOT EXISTS schema_info') -or ($script:SchemaText -match '\$\(')){throw 'Schema de production introuvable ou non developpe.'}
    $directory=Join-Path $folder $Name;[void][IO.Directory]::CreateDirectory($directory);[void][IO.Directory]::CreateDirectory((Join-Path $directory 'index-spool'))
    $path=Join-Path $directory 'network.sqlite'
    $db=Open-DomeniaDatabase $path
    try{[void](Invoke-DomeniaDbExec $script:SchemaText $db)}finally{Close-DomeniaDatabase $db}
    return [pscustomobject]@{Path=$path;Directory=$directory;Context=[pscustomobject]@{Version=1;Path=$path;DomainDn=$script:Domain;StoreId=(Get-DomeniaStoreId $path $script:Domain);RequestId='network';Generation=1;SessionEpoch=1;ScopeDn=$script:Domain;Subtree=$true}}
}
function Invoke-NetworkStorage {param($Payload);return (& ([scriptblock]::Create($script:Worker)))}
function Read-NetworkBase {param($Base,[string]$Sql);$db=Open-DomeniaDatabase $Base.Path;try{return @(Invoke-DomeniaDbQuery $Sql $db)}finally{Close-DomeniaDatabase $db}}
function New-NetworkIndexPayload {
    # IndexBulk as the directory read sends it: a transfer file of Count rows starting at index First.
    param($Base,[int]$First,[int]$Count,[string]$At,[string]$Extra='Windows 11',[bool]$Complete=$true,[bool]$ReplaceAll=$true)
    $file=Join-Path (Join-Path $Base.Directory 'index-spool') ([guid]::NewGuid().ToString('N')+'.jsonl')
    $now=[datetime]::UtcNow
    $writer=[IO.StreamWriter]::new($file,$false,[Text.UTF8Encoding]::new($false))
    try{for($n=$First;$n -lt ($First+$Count);$n++){$writer.WriteLine((ConvertTo-DomeniaLoadIndexLine -Computer (Get-DomeniaLoadComputer -Index $n) -At $At -NowUtc $now).Replace('"Extra":"Windows 11"','"Extra":"'+$Extra+'"'))}}finally{$writer.Dispose()}
    $transfer=[pscustomobject]@{Path=$file;Sha256=(Get-FileHash $file -Algorithm SHA256).Hash;RowCount=$Count}
    return [pscustomobject]@{Path=$Base.Path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@();Transfer=$transfer;At=$At;Server='dc.example.invalid';BaseDn=$script:Domain;Complete=$Complete;ReplaceAll=$ReplaceAll;HighestUsn=($First+$Count)}})}
}

try{
    [void][IO.Directory]::CreateDirectory($folder)
    Case 'Corps LiveConsole execute identique au corps epingle dans le registre' {
        [void](Assert-DomeniaWorkerOperationCode 'LiveConsole' (Get-DomeniaLiveProbeCode))
    }
    Case 'Latence dans le budget : vraie observation, aucune panne inventee' {
        $r=Invoke-NetworkProbe -DelayMs 300 -Ping
        Expect (($r.Outcome -eq 'Observed') -and ($r.User -eq 'EXAMPLE\alex.demo') -and ($r.Presence -eq 'En ligne')) ('slow answer classified as a fault: '+$r.Outcome)
        Expect (($script:NetCalls.Sessions -eq 1) -and ($script:NetCalls.Closes -eq 1)) 'one CIM session opened and closed'
    }
    Case 'Latence au-dela du delai : Delai depasse, aucun compte, derniere observation conservee' {
        $r=Invoke-NetworkProbe -ReadFault 'Timeout'
        Expect (($r.Outcome -eq 'Timeout') -and (-not $r.User)) ('timeout category lost: '+$r.Outcome)
        Assert-KnownKept $r 'Delai'
        $d=Get-NetworkDecision 'Timeout'
        Expect (($d.Category -eq 'Timeout') -and (-not $d.OfferCredential) -and $d.Retryable) ('timeout decision: '+$d.Category)
        Expect ($script:NetCalls.Closes -eq 1) 'session closed after the timeout'
    }
    Case 'DNS errone : nom non resolu, poste injoignable, jamais un probleme de compte' {
        $r=Invoke-NetworkProbe -PingFault 'DnsNotFound' -SessionFault 'RpcUnavailable' -Ping
        Expect (($r.Outcome -eq 'Unavailable') -and (-not $r.User)) ('unresolved name: '+$r.Outcome)
        Expect (($r.Presence -eq 'Erreur de ping') -and ([string]$r.PresenceDetail -match 'DNS')) ('presence: '+$r.Presence+' / '+$r.PresenceDetail)
        Assert-KnownKept $r 'DNS'
        foreach($kind in @('DnsNotFound','RpcUnavailable')){$d=Get-NetworkDecision $kind;Expect (($d.Category -eq 'Network') -and (-not $d.OfferCredential)) ($kind+' : '+$d.Category)}
    }
    Case 'DNS errone : un autre poste repond, aucune donnee attribuee au poste demande' {
        $r=Invoke-NetworkProbe -ReportedName 'PC-AUTRE' -ReportedDns 'pc-autre' -User 'EXAMPLE\bob' -Inventory
        Expect (($r.Outcome -eq 'Unavailable') -and (-not $r.User)) ('console of another workstation attributed: '+$r.Outcome+' '+$r.User)
        Expect ([string]$r.Detail -match 'se nomme pc-autre') ('reason not stated: '+$r.Detail)
        Expect (($null -eq $r.PSObject.Properties['Inventory']) -and ([string]$r.InventoryError -match 'se nomme pc-autre')) 'inventory of another workstation attributed'
        Expect (@($script:NetCalls.Classes|Where-Object{$_ -eq 'Win32_ComputerSystem'}).Count -eq 1) 'identity read with the console account, no extra call'
        Assert-KnownKept $r 'Autre poste'
        $o=ConvertTo-DomeniaLiveObservation $r $script:Known '2026-10-15T09:00:00.0000000Z'
        Expect ((Get-DomeniaLiveObservationView $o).State -eq 'Non confirmé') 'state shown for the unattributed read'
    }
    Case 'DNS errone : inventaire seul, autre poste detecte avant toute attribution' {
        $r=Invoke-NetworkProbe -ReportedName 'PC-AUTRE' -ReportedDns '' -Inventory -NoConsole
        Expect (($r.Outcome -eq 'NotRequested') -and (-not $r.User)) ('console read without request: '+$r.Outcome)
        Expect (($null -eq $r.PSObject.Properties['Inventory']) -and ([string]$r.InventoryError -match 'se nomme PC-AUTRE')) 'inventory of another workstation attributed'
        Expect (@($script:NetCalls.Classes|Where-Object{$_ -eq 'Win32_ComputerSystem'}).Count -eq 1) 'identity read with the inventory, no extra call'
    }
    Case 'Identite comparee sans faux refus : nom NetBIOS tronque, nom complet, cible adresse' {
        $long=Invoke-NetworkProbe -Target 'pc-tres-long-nom-01.example.invalid' -ReportedName 'PC-TRES-LONG-NO' -ReportedDns ''
        Expect ($long.Outcome -eq 'Observed') ('NetBIOS truncation refused: '+$long.Detail)
        $fqdn=Invoke-NetworkProbe -Target 'pc-01.example.invalid' -ReportedName 'PC-01' -ReportedDns 'PC-01.example.invalid'
        Expect ($fqdn.Outcome -eq 'Observed') ('qualified name refused: '+$fqdn.Detail)
        $address=Invoke-NetworkProbe -Target '192.0.2.10' -ReportedName 'PC-01' -ReportedDns 'pc-01'
        Expect ($address.Outcome -eq 'Observed') 'address target cannot be compared and keeps the former behaviour'
        $silent=Invoke-NetworkProbe -ReportedName '' -ReportedDns ''
        Expect ($silent.Outcome -eq 'Observed') 'reply without names is not refused'
        # Windows always returns DNSHostName: a cn target (NetBIOS name cut at 15) must match the long host name.
        $cn=Invoke-NetworkProbe -Target 'PC-TRES-LONG-NO' -ReportedDns 'pc-tres-long-nom-01' -ReportedName 'PC-TRES-LONG-NO'
        Expect ($cn.Outcome -eq 'Observed') ('cn target refused although NetBIOS name matches: '+$cn.Detail)
        $cnOnly=Invoke-NetworkProbe -Target 'LONGCOMPUTERNAM' -ReportedDns 'LONGCOMPUTERNAME01.example.invalid' -ReportedName ''
        Expect ($cnOnly.Outcome -eq 'Observed') ('cut host name refused: '+$cnOnly.Detail)
        $both=Invoke-NetworkProbe -Target 'pc-tres-long-nom-01.example.invalid' -ReportedDns 'pc-tres-long-nom-01.example.invalid' -ReportedName 'PC-TRES-LONG-NO'
        Expect ($both.Outcome -eq 'Observed') ('complete reply refused: '+$both.Detail)
        $other=Invoke-NetworkProbe -Target 'PC-TRES-LONG-NO' -ReportedDns 'pc-autre-tres-long-02' -ReportedName 'PC-AUTRE-TRES-L' -User 'EXAMPLEob'
        Expect (($other.Outcome -eq 'Unavailable') -and (-not $other.User) -and ([string]$other.Detail -match 'se nomme pc-autre-tres-long-02')) ('another long-named workstation attributed: '+$other.Outcome+' '+$other.Detail)
    }
    Case 'Refus : acces, compte et connexion gardent chacun leur categorie' {
        $denied=Invoke-NetworkProbe -SessionFault 'AccessDenied'
        Expect (($denied.Outcome -eq 'Denied') -and (-not $denied.User)) ('access refusal: '+$denied.Outcome)
        $logon=Invoke-NetworkProbe -SessionFault 'LogonFailure'
        Expect (($logon.Outcome -eq 'AuthRejected') -and (-not $logon.User)) ('logon refusal: '+$logon.Outcome)
        $refused=Invoke-NetworkProbe -SessionFault 'Refused'
        Expect (($refused.Outcome -eq 'Unavailable') -and (-not $refused.User)) ('connection refusal: '+$refused.Outcome)
        foreach($r in @($denied,$logon,$refused)){Assert-KnownKept $r 'Refus'}
        Expect ((Get-NetworkDecision 'AccessDenied').OfferCredential) 'access refusal offers another account'
        Expect ((Get-NetworkDecision 'LogonFailure').Category -eq 'CredentialsRejected') 'logon refusal category'
        $d=Get-NetworkDecision 'Refused'
        Expect (($d.Category -eq 'Network') -and (-not $d.OfferCredential)) ('connection refused is not an account problem: '+$d.Category)
    }
    Case 'Deconnexion en cours de session : la console lue reste, lʼinventaire coupe nʼest pas invente' {
        $r=Invoke-NetworkProbe -Inventory -ReadFault 'RpcCallFailed' -ReadFaultClass 'Win32_OperatingSystem'
        Expect (($r.Outcome -eq 'Observed') -and ($r.User -eq 'EXAMPLE\alex.demo')) ('console read before the cut lost: '+$r.Outcome)
        Expect (($null -eq $r.PSObject.Properties['Inventory']) -and [string]$r.InventoryError) 'inventory invented after the cut'
        Expect ($script:NetCalls.Closes -eq 1) 'session closed after the cut'
        foreach($kind in @('RpcCallFailed','Reset')){$d=Get-NetworkDecision $kind;Expect (($d.Category -eq 'Network') -and (-not $d.OfferCredential) -and $d.Retryable) ($kind+' : '+$d.Category)}
    }
    Case 'Pages partielles : aucune suppression deduite, couverture non rajeunie, tentative tracee' {
        $base=New-NetworkBase 'partial'
        $full=New-NetworkIndexPayload $base 1 1000 '2026-10-14T08:00:00.0000000Z'
        Expect ([bool](Invoke-NetworkStorage $full).Saved) 'first complete index'
        $sync=[string]@(Read-NetworkBase $base "SELECT COALESCE(last_sync,'') AS v FROM sync_state WHERE scope='directory';")[0].v
        $message='';try{[void](Invoke-NetworkStorage (New-NetworkIndexPayload $base 1 400 '2026-10-15T08:00:00.0000000Z' 'Windows 11 / page' $false $true))}catch{$message=$_.Exception.Message}
        Expect ($message -match 'lecture complete du domaine requise') ('interrupted read accepted as a rebuild: '+$message)
        Expect ([long]@(Read-NetworkBase $base "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';")[0].n -eq 1000) 'refused rebuild changed the index'
        $partial=New-NetworkIndexPayload $base 1 300 '2026-10-15T09:00:00.0000000Z' 'Windows 11 / page' $false $false
        Expect ([bool](Invoke-NetworkStorage $partial).Saved) 'pages read before the cut are kept'
        Expect ([long]@(Read-NetworkBase $base "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';")[0].n -eq 1000) 'objects missing from the partial pages deleted'
        Expect ([long]@(Read-NetworkBase $base "SELECT count(*) AS n FROM ad_objects WHERE extra='Windows 11 / page';")[0].n -eq 300) 'rows read before the cut not updated'
        Expect ([string]@(Read-NetworkBase $base "SELECT COALESCE(last_sync,'') AS v FROM sync_state WHERE scope='directory';")[0].v -ceq $sync) 'coverage rejuvenated by a partial read'
        $attempt=@(Read-NetworkBase $base "SELECT details,last_sync FROM sync_state WHERE scope='attempt:directory';")
        Expect (($attempt.Count -eq 1) -and ([string]$attempt[0].details -like 'partial*') -and ([string]$attempt[0].last_sync -eq '2026-10-15T09:00:00.0000000Z')) 'partial attempt not recorded'
    }
    Case 'Reponses dans le desordre : la mesure la plus recente gagne dans les six ordres' {
        $base=New-NetworkBase 'order'
        # Past instants relative to the run: a collection date in the future is refused by the store contract.
        $origin=[datetime]::UtcNow.AddHours(-1)
        $stamps=@($origin.ToString('o'),$origin.AddMinutes(10).ToString('o'),$origin.AddMinutes(20).ToString('o'))
        $newest=$origin.AddMinutes(20).ToString('yyyy-MM-ddTHH:mm:ss')
        $orders=@(@(0,1,2),@(0,2,1),@(1,0,2),@(1,2,0),@(2,0,1),@(2,1,0))
        $seed=@(for($k=1;$k -le $orders.Count;$k++){$c=Get-DomeniaLoadComputer -Index $k;[pscustomobject]@{Kind='DirectoryObject';Guid=$c.Guid;DN=$c.Dn;ObservedAtUtc='2026-10-01T00:00:00Z';Source='dc.example.invalid';Fields=@('Type','Name','State');Data=[pscustomobject]@{Type='Machine';Name=$c.Name;State='Actif'}}})
        $batch=ConvertTo-DomeniaStoreBatch -Context $base.Context -BatchId ([guid]::NewGuid().ToString()) -Sequence 1 -Changes $seed
        Expect ([bool](Invoke-NetworkStorage ([pscustomobject]@{Path=$base.Path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$batch.Json;Hash=$batch.Hash})})).Saved) 'computers seeded'
        for($k=0;$k -lt $orders.Count;$k++){
            $c=Get-DomeniaLoadComputer -Index ($k+1)
            foreach($position in $orders[$k]){
                $at=$stamps[$position]
                $change=[pscustomobject]@{Kind='Observation';Guid=$c.Guid;DN=$c.Dn;Family='Presence';AttemptedAtUtc=$at;ObservedAtUtc=$at;Status='Success';Error='';Data=[pscustomobject]@{Computer=$c.Name;Presence='En ligne';PresenceDetail=('reponse '+$position)}}
                $b=ConvertTo-DomeniaStoreBatch -Context $base.Context -BatchId ([guid]::NewGuid().ToString()) -Sequence 1 -Changes @($change)
                Expect ([bool](Invoke-NetworkStorage ([pscustomobject]@{Path=$base.Path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$b.Json;Hash=$b.Hash})})).Saved) 'late answer accepted without error'
            }
            $row=@(Read-NetworkBase $base ("SELECT success_at,attempt_at,payload FROM domenia_observations WHERE object_guid="+(ConvertTo-DomeniaSqlLiteral $c.Guid)+" AND family='Presence';"))
            Expect (($row.Count -eq 1) -and ([string]$row[0].success_at -like ($newest+'*')) -and ([string]$row[0].attempt_at -like ($newest+'*'))) ('order '+($orders[$k] -join ',')+' kept '+[string]$row[0].success_at)
            Expect ([string]$row[0].payload -match 'reponse 2') ('order '+($orders[$k] -join ',')+' kept an older payload')
        }
    }
    Case 'Reponses dans le desordre : aucune reponse dʼune ancienne selection appliquee' {
        $rows=@(1..3|ForEach-Object{$c=Get-DomeniaLoadComputer -Index $_;[pscustomobject]@{Type='Machine';Name=$c.Name;Login=($c.Name+'$');Guid=$c.Guid;DN=$c.Dn;Sid=('S-1-5-21-10-20-30-'+(1000+$_))}})
        $requests=New-Object 'System.Collections.Generic.List[object]';$violations=New-Object 'System.Collections.Generic.List[object]'
        $generation=0L;$current=$null
        foreach($row in $rows){$generation++;$current=New-DomeniaSelectionIdentity $row 'example.invalid' 'EX\lecteur' 1 $generation;$requests.Add([pscustomobject]@{Identity=$current;Row=$row;Generation=$generation})}
        foreach($index in @(2,0,1)){
            $request=$requests[$index]
            $applied=[bool](Test-DomeniaIdentityCurrent $request.Identity $current)
            $req=[pscustomobject]@{Epoch=1;Generation=$request.Generation;Reader='EX\lecteur';Guid=$request.Row.Guid}
            $now=[pscustomobject]@{Epoch=1;Generation=$generation;Reader='EX\lecteur';Guid=$rows[2].Guid}
            # The invariant returns its violations as one array (return ,...): enumerate it, never wrap it in @().
            $found=Test-DomeniaCurrentAnswerInvariant ('Reponse '+$index) $req $now $applied -RequireCurrentApplied
            foreach($v in $found){if($null -ne $v){$violations.Add($v)}}
        }
        Expect ($violations.Count -eq 0) ((@($violations|ForEach-Object{$_.Subject+' : '+$_.Text})) -join ' | ')
        Expect (-not (Test-DomeniaLiveIdentity ([pscustomobject]@{Epoch=1;Identity='lecteur'}) 2 'lecteur')) 'console answer of a previous session applied'
    }
}finally{
    if([IO.Directory]::Exists($folder)){try{[IO.Directory]::Delete($folder,$true)}catch{Write-Output ('Dossier temporaire non supprime : '+$folder)}}
}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{
    Suite='DomeniaNetworkFaults';Passed=(($failed -eq 0) -and ($cases.Count -gt 0));Total=$cases.Count;Failed=$failed;Assertions=$script:Checks
    Qualifying=$false
    Faults=@('Latence','DNS errone (nom non resolu, autre poste)','Refus (acces, compte, connexion)','Pages partielles','Deconnexion en cours de session','Reponses dans le desordre')
    Limitation='Transport remplace par des doubles qui levent les exceptions de Windows ; ne prouve pas le comportement du reseau cible.'
    PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition;Host=[Environment]::OSVersion.ToString();Computer=[Environment]::MachineName
    Cases=$cases.ToArray()
}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),(([pscustomobject]$report)|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('NetworkFaults: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:Checks+' assertions')
if($failed){exit 1};exit 0
