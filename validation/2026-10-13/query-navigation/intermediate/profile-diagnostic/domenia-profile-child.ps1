param([string]$Case='control',[int]$WaitSeconds=25)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\query-navigation-20261013-r5'
$out=Join-Path $root 'profile-diagnostic'
[void][IO.Directory]::CreateDirectory($out)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$started=[datetime]::UtcNow
$cached=[Microsoft.Win32.Registry]::CurrentUser
function Read-ProfileState([string]$Stage) {
 $r=[ordered]@{Stage=$Stage;Utc=[datetime]::UtcNow.ToString('o');PID=$PID;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;SID=$sid}
 foreach($kind in @('Cached','Fresh')) {
  try {
   $key=if($kind -eq 'Cached'){$cached}else{[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Default)}
   $r[$kind]=@{Readable=$true;Name=$key.Name;SubKeyCount=$key.SubKeyCount;SoftwareExists=($null-ne $key.OpenSubKey('Software'))}
   if($kind -eq 'Fresh'){$key.Dispose()}
  } catch {$r[$kind]=@{Readable=$false;Error=$_.Exception.ToString();HResult=$_.Exception.HResult}}
 }
 try {$u=[Microsoft.Win32.Registry]::Users.OpenSubKey($sid);$r.Hku=@{Exists=($null-ne $u);SubKeyCount=$(if($u){$u.SubKeyCount}else{0})};if($u){$u.Dispose()}}catch{$r.Hku=@{Error=$_.Exception.ToString()}}
 try {$r.Profile='CIM omitted before load in child timing diagnostic'}catch{$r.ProfileError=$_.Exception.ToString()}
 [pscustomobject]$r
}
$stages=[Collections.Generic.List[object]]::new()
$stages.Add((Read-ProfileState 'BeforeWait'))
[IO.File]::WriteAllText((Join-Path $out ($Case+'-started.json')),(@{Case=$Case;UTC=$started.ToString('o');PID=$PID;WaitSeconds=$WaitSeconds}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds $WaitSeconds
$stages.Add((Read-ProfileState 'AfterWaitBeforeLoad'))
$path=Join-Path $root 'source\dev\wad\modules\M4D.Admin.Common.Query.dll'
$load=[ordered]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;UTC=[datetime]::UtcNow.ToString('o');LoadedBefore=@([AppDomain]::CurrentDomain.GetAssemblies()|Where-Object{$_.GetName().Name -eq 'M4D.Admin.Common.Query'}).Count}
try {Add-Type -Path $path -ErrorAction Stop;$load.Passed=$true;$load.Assembly=[M4D.Admin.Common.Query.QueryRecord].Assembly.FullName}catch{$load.Passed=$false;$load.Error=$_.Exception.ToString();$load.HResult=$_.Exception.HResult;$load.ErrorId=$_.FullyQualifiedErrorId}
$stages.Add((Read-ProfileState 'AfterLoad'))
$events=[Collections.Generic.List[object]]::new()
foreach($log in @('Microsoft-Windows-User Profile Service/Operational','Application','System')) {
 try {foreach($e in @(Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=$started.AddMinutes(-35).ToLocalTime()} -MaxEvents 150 -ErrorAction Stop | Where-Object {$_.ProviderName -match 'User Profile|User Profiles|UserProfiles|ProfSvc'})){$events.Add([pscustomobject]@{Log=$log;UTC=$e.TimeCreated.ToUniversalTime().ToString('o');Id=$e.Id;Provider=$e.ProviderName;Level=$e.LevelDisplayName;Message=$e.Message})}}catch{}
}
$report=[ordered]@{Kind='ReadOnlyProfileLoadDiagnostic';Case=$Case;StartedUtc=$started.ToString('o');FinishedUtc=[datetime]::UtcNow.ToString('o');NoRegistryOrSecurityChanges=$true;NoADAccess=$true;Stages=$stages.ToArray();Load=[pscustomobject]$load;Events=$events.ToArray()}
[IO.File]::WriteAllText((Join-Path $out ($Case+'.json')),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
