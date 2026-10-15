#requires -Version 5.1
# Points 24, 27 and 28: the real directory-read workers (disappeared objects, lastLogon per controller, schema) run
# against an in-memory directory double. The common worker helpers are the real ones, extracted from the core.
# No domain, no network, no WPF, no write: synthetic data only. Not a qualification of a real directory.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Expect {param([bool]$Good,[string]$Name);$script:Assertions++;if(-not $Good){throw $Name}}
function Case {param([string]$Name,[scriptblock]$Body)
    $failure='';try{& $Body|Out-Null}catch{$failure=$_.Exception.Message+' @ '+$_.ScriptStackTrace}
    $script:Results.Add([pscustomobject]@{Name=$Name;Passed=(-not $failure);Error=$failure});Write-Host ($(if($failure){'FAIL '}else{'PASS '})+$Name)
}
# Real helpers: rule modules, credential guard and the common worker functions of the core here-string.
foreach($name in @('Common.Model','Guard.Model','DirectorySync.Model','LogonActivity.Model','DirectorySchema.Model','DirectorySync.Worker','LogonActivity.Worker','DirectorySchema.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$tokens=$null;$errors=$null
$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Core parse error'}
$common=@($core.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:WorkerCommon' -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals},$true))
if($common.Count -ne 1){throw 'Common worker code not found'}
$commonText=[string]$common[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true).Value
$commonAst=[Management.Automation.Language.Parser]::ParseInput($commonText,[ref]$tokens,[ref]$errors)
foreach($name in @('Get-WPropFirst','Get-WPropAll','Convert-WLargeInteger','Convert-WGuid','Convert-WFileTime','Convert-WDate')){
    $node=@($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($node.Count -ne 1){throw ('Common worker function not found: '+$name)}
    . ([scriptblock]::Create($node[0].Extent.Text))
}
if($null -eq ('DomeniaTest.FakeEntry' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
namespace DomeniaTest {
    public sealed class FakeValues : ArrayList {
        public object Value { get { if (Count == 0) { return null; } return this[0]; } }
    }
    public sealed class FakeProps {
        private readonly Dictionary<string, FakeValues> values = new Dictionary<string, FakeValues>(StringComparer.OrdinalIgnoreCase);
        public void Set(string name, object value) { FakeValues list = new FakeValues(); if (value != null) { list.Add(value); } values[name] = list; }
        public FakeValues get_Item(string name) { FakeValues list; if (values.TryGetValue(name, out list)) { return list; } return new FakeValues(); }
    }
    public sealed class FakeEntry : IDisposable {
        private readonly FakeProps props = new FakeProps();
        public string Path;
        public string Failure;
        public int Refreshes;
        public void RefreshCache(string[] names) { Refreshes++; if (Failure == "AccessDenied") { throw new UnauthorizedAccessException("TEST access denied"); } if (!String.IsNullOrEmpty(Failure)) { throw new InvalidOperationException(Failure); } }
        public FakeProps get_Properties() { return props; }
        public void Dispose() { }
    }
    public sealed class FakeResults : List<object>, IDisposable {
        public bool Disposed;
        public void Dispose() { Disposed = true; }
    }
}
'@
}
# ---------------------------------------------------------------- directory double
$script:Searches=New-Object 'System.Collections.Generic.List[object]'
$script:Directory=$null
function ConvertFrom-TestGuidFilter {
    # GUIDs written as escaped bytes in an LDAP filter, in order.
    param([string]$Filter)
    $out=New-Object 'System.Collections.Generic.List[string]'
    foreach($m in [regex]::Matches($Filter,'\(objectGUID=((?:\\[0-9A-Fa-f]{2}){16})\)')){
        $bytes=[byte[]]@(([regex]::Matches($m.Groups[1].Value,'[0-9A-Fa-f]{2}')|ForEach-Object{[Convert]::ToByte($_.Value,16)}))
        $out.Add(([guid]::new($bytes)).ToString('D'))
    }
    return ,$out.ToArray()
}
function New-TestResult {param([hashtable]$Properties);$p=@{};foreach($k in $Properties.Keys){$p[$k.ToLowerInvariant()]=@($Properties[$k])};return [pscustomobject]@{Properties=$p}}
function Invoke-TestSearch {
    param($Searcher)
    $record=[pscustomobject]@{Server=$Searcher.Server;BaseDn=$Searcher.BaseDn;Filter=$Searcher.Filter;Scope=$Searcher.Scope;Limit=$Searcher.Limit;Tombstone=[bool]$Searcher.Tombstone}
    $script:Searches.Add($record)
    return @(& $script:Directory $record)
}
function New-WSearcher {
    param($Context,[string]$BaseDn,[string]$Filter,[string[]]$Properties,[string]$Scope='OneLevel',[int]$Limit=0)
    $root=[pscustomobject]@{Path=$BaseDn};$root|Add-Member ScriptMethod Dispose {}
    $searcher=[pscustomobject]@{Server=[string]$Context.Server;BaseDn=$BaseDn;Filter=$Filter;Scope=$Scope;Limit=$Limit;Properties=$Properties;Tombstone=$false;PageSize=300;CacheResults=$true;ServerTimeLimit=$null;ClientTimeout=$null;SearchRoot=$root}
    $searcher|Add-Member ScriptMethod FindAll {$list=New-Object DomeniaTest.FakeResults;foreach($r in @(Invoke-TestSearch $this)){if($null -ne $r){$list.Add($r)}};return ,$list}
    $searcher|Add-Member ScriptMethod FindOne {$all=@(Invoke-TestSearch $this|Where-Object{$null -ne $_});if($all.Count){return $all[0]};return $null}
    $searcher|Add-Member ScriptMethod Dispose {}
    return $searcher
}
$script:Entries=@{}
function New-WEntry {param($Context,[string]$Dn);$e=$script:Entries[$Dn];if($null -eq $e){throw ('TEST no such object '+$Dn)};return $e}
function New-WRootDse {param($Context);$e=$script:Entries['RootDSE'];if($null -eq $e){throw 'TEST RootDSE unavailable'};return $e}
function Get-WDirectoryVersionSource {param($Context);return ([string]$Context.Server+'|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')}
$domain='DC=example,DC=invalid'
# Test identities and directory state live in the script scope and are always read with $script:, so that a variable
# of the worker under test (same dynamic scope chain) never shadows them.
$script:G1='0f6c3a8e-2b8d-4c1e-9a77-5d2b9f1e0a11';$script:G2='1a2b3c4d-0000-4000-8000-000000000002';$script:G3='1a2b3c4d-0000-4000-8000-000000000003'
$g1=$script:G1;$g2=$script:G2;$g3=$script:G3
$script:DeletedWhen=[datetime]::SpecifyKind([datetime]::new(2026,10,10,9,30,0),[DateTimeKind]::Unspecified)
# Facts of the moved computer (point 23): directory dates as the reader returns them (generalized time, FILETIME).
$script:CreatedWhen=[datetime]::SpecifyKind([datetime]::new(2025,1,2,8,0,0),[DateTimeKind]::Utc)
$script:PwdSetTicks=([datetime]::new(2026,9,1,12,0,0,[DateTimeKind]::Utc)).ToFileTimeUtc()
$script:LapsTicks=([datetime]::new(2026,11,1,0,0,0,[DateTimeKind]::Utc)).ToFileTimeUtc()
$script:AbsenceState=$null
$script:AbsenceDirectory={
    # G1 moved to another OU, G2 deleted, every other identity missing. The state decides the visibility probe and faults.
    param($q)
    $state=$script:AbsenceState
    if(-not $q.Tombstone){
        if($state.DomainFailure){throw $state.DomainFailure}
        foreach($guid in @(ConvertFrom-TestGuidFilter $q.Filter)){if($guid -eq $script:G1){New-TestResult @{objectGUID=$script:G1;distinguishedName='CN=PC1,OU=Paris,DC=example,DC=invalid';objectClass=@('top','person','organizationalPerson','user','computer');name='PC1';sAMAccountName='PC1$';dNSHostName='pc1.example.invalid';userAccountControl=4096;uSNChanged=88;operatingSystemVersion='10.0 (26100)';whenCreated=$script:CreatedWhen;pwdLastSet=$script:PwdSetTicks;'msLAPS-PasswordExpirationTime'=$script:LapsTicks}}}
        return
    }
    if($q.Filter -match 'isCriticalSystemObject=TRUE'){
        if($state.Container){New-TestResult @{name='Deleted Objects';objectGUID='18e2ea80-684f-11d2-b9aa-00c04f79f805'}}else{New-TestResult @{distinguishedName='CN=Deleted Objects,DC=example,DC=invalid'}}
        return
    }
    $state.DeletedBatches++
    if($state.DeletedFailure -and ($state.DeletedBatches -ge $state.FailBatch)){throw $state.DeletedFailure}
    foreach($guid in @(ConvertFrom-TestGuidFilter $q.Filter)){if($guid -eq $script:G2){New-TestResult @{objectGUID=$script:G2;whenChanged=$script:DeletedWhen;lastKnownParent='OU=Postes,OU=Lyon,DC=example,DC=invalid';isRecycled=$false}}}
}
function Set-TestAbsenceDirectory {
    param([bool]$ContainerReadable=$true,[string]$DomainFailure='',[string]$DeletedFailureAfter='',[int]$FailBatch=0)
    $script:AbsenceState=@{Container=$ContainerReadable;DomainFailure=$DomainFailure;DeletedFailure=$DeletedFailureAfter;FailBatch=$FailBatch;DeletedBatches=0}
    $script:Directory=$script:AbsenceDirectory
}
function Invoke-AbsenceWorker {param([string[]]$Guids,[bool]$CheckDeleted=$true)
    $Payload=[pscustomobject]@{Items=@($Guids|ForEach-Object{[pscustomobject]@{Guid=$_}});CheckDeleted=$CheckDeleted}
    $Context=[pscustomobject]@{BaseDn=$domain;Server='dc1.example.invalid';OperationId='DirectoryAbsenceCheck'}
    return (& ([scriptblock]::Create((Get-DomeniaAbsenceCheckWorkerCode))))
}
function Get-TestAnswer {param($Result,[string]$Guid);return @(@($Result.Results)|Where-Object{[string]$_.Guid -eq $Guid})[0]}
function Resolve-TestAnswer {param($Answer);return (Resolve-DomeniaDirectoryAbsence -Absence ([pscustomobject]@{Guid=[string]$Answer.Guid;LastDn='CN=X,OU=Postes,OU=Lyon,DC=example,DC=invalid';ScopeDn='OU=Lyon,DC=example,DC=invalid'}) -Check $Answer)}
try{
    Case 'P24 moved, deleted and missing objects: proofs read by GUID from the domain head' {
        $script:Searches.Clear();Set-TestAbsenceDirectory -ContainerReadable $true
        $r=Invoke-AbsenceWorker @($g1,$g2,$g3)
        Expect ($r.DomainRead -eq 'Read' -and $r.DeletedRead -eq 'Read') ('Read states: '+$r.DomainRead+'/'+$r.DeletedRead)
        $moved=Get-TestAnswer $r $g1
        Expect ($moved.FoundDn -eq 'CN=PC1,OU=Paris,DC=example,DC=invalid' -and $moved.Type -eq 'Machine' -and $moved.Record.DN -eq $moved.FoundDn -and $moved.Record.Guid -eq $g1) 'Moved object and its index record'
        Expect ((Resolve-TestAnswer $moved).Status -eq 'Deplace') 'Moved object resolved as moved'
        # Point 23: the facts removed with the row by the complete read come back with the record, in index formats.
        Expect ([bool]$moved.Record.Facts -and $moved.Record.OsVersion -eq '10.0 (26100)' -and $moved.Record.WhenCreated -eq '2025-01-02T08:00:00Z' -and $moved.Record.PwdLastSet -eq '2026-09-01T12:00:00Z') ('Computer facts re-read: '+$moved.Record.WhenCreated+' / '+$moved.Record.PwdLastSet)
        Expect ($moved.Record.LapsKind -eq 'Windows' -and $moved.Record.LapsExpiry -eq '2026-11-01T00:00:00Z') 'Windows LAPS expiry re-read, never the password'
        $deleted=Get-TestAnswer $r $g2
        Expect ($deleted.Deleted -and $deleted.DeletedRead -eq 'Read' -and $deleted.LastKnownParent -eq 'OU=Postes,OU=Lyon,DC=example,DC=invalid' -and $deleted.DeletedWhenUtc -eq '2026-10-10T09:30:00.0000000Z') 'Deleted entry with its date and last parent'
        Expect ((Resolve-TestAnswer $deleted).Status -eq 'Supprime') 'Deletion proven by the deleted entry only'
        $missing=Get-TestAnswer $r $g3
        Expect (-not $missing.Deleted -and $missing.DeletedRead -eq 'Read' -and (Resolve-TestAnswer $missing).Status -eq 'Introuvable') 'Missing object with readable deleted objects'
        $tomb=@($script:Searches|Where-Object{$_.Tombstone})
        Expect ($tomb.Count -eq 2 -and @($tomb|Where-Object{$_.BaseDn -ne $domain}).Count -eq 0) 'Deleted objects read from the domain head, never by binding CN=Deleted Objects'
        Expect (@($tomb|Where-Object{$_.Filter -notmatch 'isDeleted=TRUE'}).Count -eq 0) 'Every show-deleted search keeps isDeleted=TRUE'
        $lookup=@($tomb|Where-Object{$_.Filter -match 'objectGUID'})[0]
        Expect ($lookup.Scope -eq 'Subtree' -and @(ConvertFrom-TestGuidFilter $lookup.Filter).Count -eq 2) 'Only the two objects absent from the domain are looked up among deleted objects'
        Expect (@($script:Searches|Where-Object{-not $_.Tombstone}).Count -eq 1) 'One domain lookup for three identities'
    }
    Case 'P24 without visible deleted objects, absence is never a deletion' {
        $script:Searches.Clear();Set-TestAbsenceDirectory -ContainerReadable $false
        $r=Invoke-AbsenceWorker @($g3)
        $a=Get-TestAnswer $r $g3
        Expect ($a.DeletedRead -eq 'Empty' -and $r.DeletedRead -eq 'Empty') ('Probe state: '+$a.DeletedRead)
        Expect ((Resolve-TestAnswer $a).Status -eq 'NonVisible') 'Deletion and loss of rights stay indistinguishable'
        Set-TestAbsenceDirectory -ContainerReadable $false
        $r=Invoke-AbsenceWorker @($g2,$g3)
        Expect ((Get-TestAnswer $r $g2).Deleted -and (Get-TestAnswer $r $g3).DeletedRead -eq 'Read') 'A deleted entry found proves that deleted objects are visible'
    }
    Case 'P24 refused domain read: no conclusion and no deleted-object read' {
        $script:Searches.Clear();Set-TestAbsenceDirectory -DomainFailure 'TEST access denied'
        $r=Invoke-AbsenceWorker @($g1,$g3)
        Expect ($r.DomainRead -eq 'Refused' -and @($script:Searches|Where-Object{$_.Tombstone}).Count -eq 0) ('Domain state: '+$r.DomainRead)
        foreach($answer in @($r.Results)){Expect ((Resolve-TestAnswer $answer).Status -eq 'NonConfirme') 'A refused read concludes nothing'}
    }
    Case 'P24 a cut deleted-object lookup leaves the unread identities unconfirmed' {
        $many=@(1..30|ForEach-Object{'2b2b2b2b-0000-4000-8000-'+$_.ToString('000000000000')})
        $script:Searches.Clear();Set-TestAbsenceDirectory -ContainerReadable $true -DeletedFailureAfter 'TEST server unavailable' -FailBatch 2
        $r=Invoke-AbsenceWorker $many
        $first=@($many[0..23]|ForEach-Object{(Get-TestAnswer $r $_).DeletedRead});$rest=@($many[24..29]|ForEach-Object{(Get-TestAnswer $r $_).DeletedRead})
        Expect (@($first|Where-Object{$_ -ne 'Read'}).Count -eq 0) 'First batch searched'
        Expect (@($rest|Where-Object{$_ -ne 'Unavailable'}).Count -eq 0) ('Second batch must stay unread: '+($rest -join ','))
        Expect ((Resolve-TestAnswer (Get-TestAnswer $r $many[29])).Status -eq 'NonConfirme') 'An unread identity is not declared missing'
    }
    Case 'P22 census gaps read by GUID in the domain only' {
        $script:Searches.Clear();Set-TestAbsenceDirectory -ContainerReadable $true
        $r=Invoke-AbsenceWorker @($g1,$g3) -CheckDeleted $false
        Expect (@($script:Searches|Where-Object{$_.Tombstone}).Count -eq 0) 'A gap read never reads the deleted objects'
        $at=[datetime]::new(2026,10,14,10,0,0,[DateTimeKind]::Utc)
        $found=New-DomeniaCensusGapStoreRow -Guid $g1 -Check (Get-TestAnswer $r $g1) -CheckedUtc $at -Server 'dc1.example.invalid'
        Expect ($found.Status -eq 'Visible' -and [bool]$found.Gap -and $found.FoundDn -eq 'CN=PC1,OU=Paris,DC=example,DC=invalid' -and $found.Record.Guid -eq $g1 -and [bool]$found.Record.Facts) 'Found gap kept with its index record and facts'
        $gone=New-DomeniaCensusGapStoreRow -Guid $g3 -Check (Get-TestAnswer $r $g3) -CheckedUtc $at
        Expect ($gone.Status -eq 'Introuvable' -and $null -eq $gone.Record -and $gone.Detail -match 'sans conclusion') 'Gap not returned by the domain read leaves the list without conclusion'
        Set-TestAbsenceDirectory -DomainFailure 'TEST server unavailable'
        $r=Invoke-AbsenceWorker @($g1) -CheckDeleted $false
        Expect ((New-DomeniaCensusGapStoreRow -Guid $g1 -Check (Get-TestAnswer $r $g1)).Status -eq 'NonConfirme') 'An unread gap stays to read'
    }
    Case 'P24 payload limits' {
        Set-TestAbsenceDirectory
        $refused=$false;try{[void](Invoke-AbsenceWorker @())}catch{$refused=$true};Expect $refused 'Empty batch refused'
        $refused=$false;try{[void](Invoke-AbsenceWorker @(1..201|ForEach-Object{[guid]::NewGuid().ToString('D')}))}catch{$refused=$true};Expect $refused 'Batch over 200 refused'
        $r=Invoke-AbsenceWorker @($g3) -CheckDeleted $false
        Expect ((Get-TestAnswer $r $g3).DeletedRead -eq 'NotRequested' -and (Resolve-TestAnswer (Get-TestAnswer $r $g3)).Status -eq 'NonConfirme') 'Deleted objects not read: no conclusion'
    }
    # ---------------------------------------------------------------- point 27
    $script:LogonTarget='5c5c5c5c-0000-4000-8000-000000000027'
    $script:LastDc1=[datetime]::new(2026,10,14,7,45,0,[DateTimeKind]::Utc)
    $script:LogonDirectory={
        # Three controllers: DC1 knows a logon, DC2 does not hold the object, RODC1 does not answer.
        param($q)
        if($q.Filter -match 'userAccountControl:1\.2\.840\.113556\.1\.4\.803:=8192'){
            New-TestResult @{name='DC1';dNSHostName='dc1.example.invalid';userAccountControl=532480}
            New-TestResult @{name='DC2';dNSHostName='dc2.example.invalid';userAccountControl=532480}
            New-TestResult @{name='RODC1';dNSHostName='rodc1.example.invalid';userAccountControl=83890176}
            return
        }
        $guids=@(ConvertFrom-TestGuidFilter $q.Filter)
        if(($guids.Count -ne 1) -or ($guids[0] -ne $script:LogonTarget)){throw 'TEST unexpected filter'}
        switch($q.Server){
            'dc1.example.invalid' {return (New-TestResult @{lastLogon=$script:LastDc1.ToFileTimeUtc();logonCount=12})}
            'dc2.example.invalid' {return}
            'rodc1.example.invalid' {throw 'TEST server unavailable'}
        }
        throw ('TEST unknown server '+$q.Server)
    }
    function Invoke-LogonWorker {param([string]$Guid=$script:LogonTarget,[int]$Max=50)
        $Payload=[pscustomobject]@{ObjectGuid=$Guid;MaxControllers=$Max;BudgetSeconds=75}
        $Context=[pscustomobject]@{BaseDn=$domain;Server='dc1.example.invalid';OperationId='LogonByDcRead'}
        $answer=& ([scriptblock]::Create((Get-DomeniaLogonByDcWorkerCode)))
        return [pscustomobject]@{Answer=$answer;Context=$Context}
    }
    Case 'P27 lastLogon read on each controller, with its coverage' {
        $script:Searches.Clear();$script:Directory=$script:LogonDirectory
        $head=New-Object DomeniaTest.FakeEntry;$head.get_Properties().Set('msDS-LogonTimeSyncInterval','7');$script:Entries=@{$domain=$head}
        $run=Invoke-LogonWorker;$r=$run.Answer
        Expect ($r.ObjectGuid -eq $script:LogonTarget -and $r.KnownCount -eq 3 -and -not $r.ListTruncated) 'Controllers listed'
        Expect ($r.IntervalState -eq 'Read' -and $r.IntervalValue -eq '7') ('Interval: '+$r.IntervalState)
        $byDc=@{};foreach($reading in @($r.Controllers)){$byDc[[string]$reading.Dc]=$reading}
        Expect ($byDc['dc1.example.invalid'].State -eq 'Read' -and $byDc['dc1.example.invalid'].LastLogonUtc -eq $script:LastDc1.ToString('o') -and $byDc['dc1.example.invalid'].LogonCount -eq 12) 'Exact lastLogon of DC1'
        Expect ($byDc['dc2.example.invalid'].State -eq 'Absent') 'Object absent from DC2'
        Expect ($byDc['rodc1.example.invalid'].State -eq 'Unavailable' -and $byDc['rodc1.example.invalid'].Kind -eq 'RODC') 'Unreachable RODC'
        $perDc=@($script:Searches|Where-Object{$_.Filter -match 'objectGUID'})
        Expect (((@($perDc|ForEach-Object{$_.Server})|Sort-Object) -join ',') -eq 'dc1.example.invalid,dc2.example.invalid,rodc1.example.invalid') 'Each controller read on its own server'
        Expect ($run.Context.Server -eq 'dc1.example.invalid') 'The session context keeps its controller'
        $merge=Merge-DomeniaLogonReadings -Readings @($r.Controllers) -KnownCount ([int]$r.KnownCount) -ListTruncated ([bool]$r.ListTruncated)
        Expect ($merge.MostRecentDc -eq 'dc1.example.invalid' -and -not $merge.Complete -and $merge.ReadCount -eq 1) 'Most recent value and incomplete coverage'
        Expect ($merge.Text -match 'rodc1\.example\.invalid') 'Unread controllers named'
    }
    Case 'P27 bounds: controller list truncated, refused interval, invalid object' {
        $script:Searches.Clear();$script:Directory=$script:LogonDirectory
        $head=New-Object DomeniaTest.FakeEntry;$head.Failure='AccessDenied';$script:Entries=@{$domain=$head}
        $r=(Invoke-LogonWorker -Max 2).Answer
        Expect ($r.ListTruncated -and @($r.Controllers).Count -eq 2 -and $r.KnownCount -eq 2) 'Only the bounded number of controllers is read'
        Expect ($r.IntervalState -eq 'Refused') ('Interval state: '+$r.IntervalState)
        Expect (-not (Merge-DomeniaLogonReadings -Readings @($r.Controllers) -KnownCount 2 -ListTruncated $true).Complete) 'A truncated list never covers the domain'
        $refused=$false;try{[void](Invoke-LogonWorker -Guid 'pas-un-guid')}catch{$refused=$true};Expect $refused 'Invalid GUID refused before any read'
    }
    # ---------------------------------------------------------------- point 28
    Case 'P28 schema read once, definitions only, converted to a catalog' {
        $script:Searches.Clear()
        $root=New-Object DomeniaTest.FakeEntry;$root.get_Properties().Set('schemaNamingContext','CN=Schema,CN=Configuration,DC=example,DC=invalid');$script:Entries=@{RootDSE=$root}
        $script:Directory={
            param($q)
            if($q.Filter -eq '(objectClass=attributeSchema)'){
                New-TestResult @{lDAPDisplayName='sAMAccountName';adminDescription='SAM-Account-Name';attributeSyntax='2.5.5.12';isSingleValued=$true;searchFlags=13;systemFlags=18;isMemberOfPartialAttributeSet=$true}
                New-TestResult @{lDAPDisplayName='description';adminDescription='Description';attributeSyntax='2.5.5.12';isSingleValued=$false;searchFlags=0;systemFlags=16}
                New-TestResult @{lDAPDisplayName='bad name';attributeSyntax='2.5.5.12'}
                return
            }
            if($q.Filter -eq '(objectClass=classSchema)'){
                New-TestResult @{lDAPDisplayName='top';subClassOf='top';objectClassCategory=2;mayContain=@('description')}
                New-TestResult @{lDAPDisplayName='user';subClassOf='top';objectClassCategory=1;systemMayContain=@('sAMAccountName')}
                return
            }
            throw 'TEST unexpected schema filter'
        }
        $Payload=[pscustomobject]@{Request='Schema'};$Context=[pscustomobject]@{BaseDn=$domain;Server='dc1.example.invalid';OperationId='AdSchemaRead'}
        $r=& ([scriptblock]::Create((Get-DomeniaAdSchemaWorkerCode)))
        Expect ($r.SchemaNc -eq 'CN=Schema,CN=Configuration,DC=example,DC=invalid' -and -not $r.Truncated -and $r.Server -eq 'dc1.example.invalid') 'Schema context and controller'
        Expect (@($r.Attributes).Count -eq 2 -and @($r.Classes).Count -eq 2) 'Invalid names left out'
        Expect (@($script:Searches|Where-Object{($_.BaseDn -ne 'CN=Schema,CN=Configuration,DC=example,DC=invalid') -or ($_.Scope -ne 'OneLevel')}).Count -eq 0) 'Only the schema container is read, one level'
        # PF-02 (X02): each read is bounded by the server at its limit + 1, the extra definition proving the cut.
        $attributeSearch=@($script:Searches|Where-Object{$_.Filter -eq '(objectClass=attributeSchema)'});$classSearch=@($script:Searches|Where-Object{$_.Filter -eq '(objectClass=classSchema)'})
        Expect (($attributeSearch.Count -eq 1) -and ([int]$attributeSearch[0].Limit -eq 8001) -and ($classSearch.Count -eq 1) -and ([int]$classSearch[0].Limit -eq 3001)) 'Schema reads bounded at their limit + 1'
        $catalog=ConvertTo-DomeniaAdSchemaCatalog -Attributes @($r.Attributes) -Classes @($r.Classes) -Server $r.Server -ObservedUtc $r.ObservedUtc -DomainDn $domain
        Expect ((Get-DomeniaAdSchemaAttribute $catalog 'sAMAccountName').Indexed -and -not (Get-DomeniaAdSchemaAttribute $catalog 'description').Indexed) 'Index flags read from searchFlags'
        Expect (@((Get-DomeniaAdClassAttributes -Catalog $catalog -ClassName 'user').Rows|ForEach-Object{$_.Attribut}) -contains 'description') 'Inherited attributes listed'
        $root.get_Properties().Set('schemaNamingContext','CN=Other,DC=example,DC=invalid')
        $refused=$false;try{[void](& ([scriptblock]::Create((Get-DomeniaAdSchemaWorkerCode))))}catch{$refused=$true};Expect $refused 'Unexpected schema context refused'
    }
}finally{$script:Entries=@{}}
$failed=@($script:Results|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{Kind='DirectoryReads';Passed=@($script:Results|Where-Object{$_.Passed}).Count;Failed=$failed;Assertions=$script:Assertions;Results=$script:Results.ToArray();NativeWindowsPowerShell51=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);DomainAccessed=$false;NetworkAccessed=$false;WpfExecuted=$false}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
Write-Output ('Directory read workers: '+$report.Passed+' passed, '+$failed+' failed, '+$script:Assertions+' assertions; in-memory directory double, no AD/WPF/network')
if($failed -gt 0){exit 1}
