$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification'
$wad='C:\DomeniaLab\RC1.17.35\dev\wad'
[void][IO.Directory]::CreateDirectory((Join-Path $root 'live-timeout-addressed'))
$source=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
$marker=$source.IndexOf('# Main autoritaire')
if($marker -lt 0){throw 'Application entrypoint not found'}
if(Test-Path (Join-Path $root 'live-out\LiveBatch.json')){Copy-Item (Join-Path $root 'live-out\LiveBatch.json') (Join-Path $root 'live-out\NativeTransportAttempt.json')}
$driver=@'
$ErrorActionPreference='Stop'
$out='C:\DomeniaLab\RC35-qualification\live-timeout-addressed'
function Save-LiveProof($Name,$Value){[IO.File]::WriteAllText((Join-Path $out $Name),($Value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
$proof=[ordered]@{Build='RC1.17.35';Passed=$false;LiveAD=$true;LiveRemoteWmi=$true;MockedNetwork=$false;MockedCallbacks=$false;MockedStorage=$false;Utc=[datetime]::UtcNow.ToString('o');FaultMethod='First endpoint only: real network call with engine idle timeout shortened from 25 to 2 seconds; no callback/result injection';Steps=@()}
$events=[Collections.Generic.List[object]]::new();$seen=@{};$run=$null
try{
 . (Join-Path $PSScriptRoot 'Domenia-Modules.ps1')
 $script:WorkerCommon+="`r`n"+(Get-DomeniaReceiptsCommon)
 $script:WorkerCommon+="`r`n"+(Get-DomeniaWorkerRulesCommon)
 Load-AppConfig|Out-Null
 # Isolate the local data/preference path only. All engine, network and storage functions remain real.
 function Get-DomeniaUserLocalRoot {return 'C:\DomeniaLab\RC35-qualification\live-timeout-addressed\profile'}
 $script:Config.LocalStore.Mode='UserLocal'
 $script:Settings=@{'Collection.Concurrency'='1'}
 $script:Window=[Windows.Window]::new()
 $script:Ctrl=@{LblParkStatus=[Windows.Controls.TextBlock]::new();LblParkDetectionStatus=[Windows.Controls.TextBlock]::new()}
 $script:Conn.Connected=$true;$script:Conn.AuthMode='Windows';$script:Conn.UseCredential=$false
 $script:Conn.Server='dc01.cnamts.local';$script:Conn.Domain='cnamts.local';$script:Conn.Netbios='CNAMTS';$script:Conn.BaseDn='DC=cnamts,DC=local';$script:Conn.RootPath='LDAP://dc01.cnamts.local/DC=cnamts,DC=local'
 $script:Conn.User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;$script:Conn.BindUser=$script:Conn.User
 $script:SessionEpoch=1L;$script:DomeniaAccountGeneration=1L;$script:GlobalSearchGeneration=1L
 $script:DemoMode=$false;$script:ReadOnlyMode=$true
 Initialize-DomeniaDataStore|Out-Null
 Initialize-DomeniaWinSqliteNative|Out-Null
 Initialize-DomeniaDatabase|Out-Null
 Initialize-DomeniaPersistence
 Initialize-AsyncEngine
 $proof.Steps+=@('Native application engine and isolated SQLite initialized')
 Import-Module (Join-Path $PSScriptRoot 'Microsoft.ActiveDirectory.Management.dll')
 $dc=Get-ADComputer -Identity 'DC01' -Server 'dc01.cnamts.local' -Properties DNSHostName
 $proof.DirectorySample=@(Get-ADComputer -Filter * -Server 'dc01.cnamts.local' -ResultSetSize 8 | Select-Object Name,DistinguishedName,ObjectGuid)
 $proof.DirectoryObject=[pscustomobject]@{Name=$dc.Name;DNSHostName=$dc.DNSHostName;DN=$dc.DistinguishedName;Guid=$dc.ObjectGuid.ToString()}
 $targets=@([pscustomobject]@{name='10.77.0.254';distinguished_name='CN=TimeoutEndpoint,OU=Qualification,DC=cnamts,DC=local';object_guid='11716000-0000-0000-0000-000000000001'},[pscustomobject]@{name=$dc.DNSHostName;distinguished_name=$dc.DistinguishedName;object_guid=$dc.ObjectGuid.ToString()})
 # The first identity is confined to this test database, never created in AD. Its unused lab address receives a real CIM request.
 $probe=@(ConvertTo-DomeniaProbePayload -Ids @('hw.memoryusage'))[0]
 $id=Start-DomeniaOnlinePark -IncludeUnaddressed -ScopeTargets $targets -ScopeLabel 'Qualification RC35 deux cibles' -WmiOnly -NoConsole -Probes @($probe) -ForceRefresh -Preapproved -WidgetBoard Fleet -Slot List -PassThru
 if(-not $id){throw ('Batch not created: '+$script:Ctrl.LblParkStatus.Text)}
 $run=Get-DomeniaParkRunById $id;$run.Concurrency=1
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.Elapsed.TotalSeconds -lt 210){
  Complete-UiTasks
  if(-not $run.Loading -and -not $run.Approved -and -not $run.Completed){Start-DomeniaParkRunTimer $id}
  if(-not $run.Loading -and -not $run.Completed){Invoke-DomeniaParkRunTick -Slot List}
  Start-DomeniaStorageWork
  foreach($job in @($script:AsyncJobs.Values)){
   if($job.OperationId -eq 'LiveConsole' -and -not $seen.ContainsKey([string]$job.Id)){
    if([string]$job.Name -like '*10.77.0.254'){$job.TimeoutSeconds=2;$job.HardTimeoutSeconds=42}
    $seen[[string]$job.Id]=$true
    $events.Add([pscustomobject]@{Event='WorkerStarted';AtMs=$clock.ElapsedMilliseconds;Id=$job.Id;Name=$job.Name;Operation=$job.OperationId;TimeoutSeconds=$job.TimeoutSeconds})
   }
  }
  $state=[pscustomobject]@{ElapsedMs=$clock.ElapsedMilliseconds;Loading=$run.Loading;Approved=$run.Approved;Completed=$run.Completed;Stopping=$run.Stopping;Done=$run.Done;Failed=$run.Failed;Next=$run.Next;Status=$run.StatusText;StopReason=$run.StopReason;FailureMessage=$run.FailureMessage;Pending=$run.Pending.Count;StorePending=$run.StorePending.Count;Events=$events.ToArray();PersistenceFault=$script:Persistence.Fault}
  Save-LiveProof 'BatchProgress.json' $state
  if($run.Completed){break}
  $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(100);$handler=[EventHandler]({$frame.Continue=$false}.GetNewClosure());$timer.Add_Tick($handler);$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame);$timer.Stop();$timer.Remove_Tick($handler)
 }
 $proof.Run=$state
 $proof.DatabasePath=$script:DatabaseScopedPath
 $proof.StoredRows=@(Invoke-DomeniaDbQuery 'SELECT object_key,payload FROM park_session_cache;')
 $proof.RuntimeHashes=@(foreach($rel in @('Domenia-Core.ps1','modules\Domenia-Park.UI.ps1','modules\Domenia-Live.Model.ps1')){[pscustomobject]@{Path=$rel;SHA256=(Get-FileHash (Join-Path $PSScriptRoot $rel) -Algorithm SHA256).Hash}})
 $proof.CanonicalRows=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_observations;')
 $proof.Tables=@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%observation%' OR name LIKE '%session%');")
 $proof.Passed=($run.Completed -and -not $run.Stopping -and $run.Done -eq 2 -and $run.Failed -eq 1 -and $events.Count -ge 2)
 if(-not $proof.Passed){throw ('Batch incomplete: '+$run.StatusText+' '+$run.FailureMessage)}
}catch{$proof.Error=$_.Exception.Message;$proof.Stack=$_.ScriptStackTrace}
finally{
 if($run -and -not $run.Completed){try{Stop-DomeniaOnlinePark -RunId $run.Id}catch{}}
 try{Dispose-AsyncEngine}catch{}
 if($script:Window){try{$script:Window.Close()}catch{}}
 Save-LiveProof 'LiveBatch.json' $proof
}
if(-not $proof.Passed){exit 1}
'@
$path=Join-Path $wad '_qualification-engine-timeout-rc35.ps1'
[IO.File]::WriteAllText($path,($source.Substring(0,$marker)+$driver),[Text.UTF8Encoding]::new($true))
try{& $path;exit $LASTEXITCODE}finally{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
