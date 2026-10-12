#requires -Version 5.1
# Actual SQLite global ordering + production callbacks with inert UI doubles. No AD/WPF/network.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules';$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
$tokens=$null;$errors=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Core parse error'}
function Import-Core {param([string]$Name,[switch]$Native)
 $f=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true));if($f.Count -ne 1){throw $Name}
 $text=$f[0].Extent.Text
 if($Native -and $PSVersionTable.PSEdition -eq 'Core'){
  $text=$text.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
  if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$text=$text.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$text=$text.Replace('winsqlite3.dll','libsqlite3.so.0')}
 }
 . ([scriptblock]::Create(($text -replace ('^function '+[regex]::Escape($Name)),('function script:'+$Name))))
}
Import-Core Initialize-DomeniaWinSqliteNative -Native;[void](Initialize-DomeniaWinSqliteNative)
. (Join-Path $modules 'Domenia-Storage.Worker.ps1');. (Join-Path $modules 'Domenia-Engine.Worker.ps1')
$storageAst=[Management.Automation.Language.Parser]::ParseInput((Get-DomeniaStorageWorkerCode),[ref]$tokens,[ref]$errors)
foreach($f in $storageAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$worker=Get-DomeniaLocalIndexReadWorkerCode
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-sort-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
$path=Join-Path $folder 'sort.sqlite'
try{
 $schema=@($core.FindAll({param($n)($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match '^PRAGMA journal_mode=WAL;' -and $n.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'},$true))[0].Value
 $db=Open-DomeniaDatabase $path
 try{
  [void](Invoke-DomeniaDbExec $schema $db);$sql=[Text.StringBuilder]::new();[void]$sql.Append('BEGIN;')
  for($n=1;$n -le 503;$n++){
   $name='PC-'+(503-$n).ToString('0000');$dn='CN='+$name+',OU=Test,DC=test';$guid='00000000-0000-0000-0000-'+$n.ToString('000000000000')
   $date=([datetime]'2025-01-01').AddDays($n)
   $logon=if($n -ge 500){''}elseif($n%2){$date.ToString('dd/MM/yyyy HH:mm:ss')}else{$date.ToString('yyyy-MM-ddTHH:mm:ssZ')}
   $modified=$date.AddHours($n%24).ToString('dd/MM/yyyy HH:mm:ss')
   $values=@($guid,$guid,$(if($n%3){'Machine'}else{'Utilisateur'}),$name,('account-'+$n),('u'+$n+'@test'),('Description '+$n),$(if($n%2){'Actif'}else{'Desactive'}),$dn,$modified,$n,$logon,$name.ToLowerInvariant())
   [void]$sql.Append(('INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,upn,description,state,distinguished_name,when_changed,usn_changed,last_logon,search_key) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'))
  }
  [void]$sql.Append('COMMIT;');[void](Invoke-DomeniaDbExec $sql.ToString() $db)
 }finally{Close-DomeniaDatabase $db}
 function Read-SortPage {param([string]$Field='',[bool]$Descending=$false,[int]$Offset=0,[string]$Term='',[string]$Scope='')
  $Payload=[pscustomobject]@{Action='Search';Path=$path;BusyTimeoutMs=50;Term=$Term;Scope=$Scope;Browse=$true;Limit=200;Offset=$Offset;SortField=$Field;Descending=$Descending}
  return & ([scriptblock]::Create($worker))
 }
 $ids=[Collections.Generic.HashSet[string]]::new();$all=[Collections.Generic.List[object]]::new()
 foreach($offset in @(0,200,400)){
  $page=Read-SortPage Name $false $offset;Expect ($page.Total -eq 503 -and $page.Offset -eq $offset) ('same population and offset '+$offset)
  Expect ($page.Rows.Count -eq [Math]::Min(200,503-$offset)) ('exact page count '+$offset)
  foreach($r in $page.Rows){Expect ($ids.Add($r.Guid)) ('unique global page identity '+$r.Guid);$all.Add($r)}
 }
 Expect (@($all|Where-Object{$_.Score -ne 0 -or $_.Reason -ne 'Perimetre local'}).Count -eq 0) 'browse has no fabricated prefix-match score or reason'
 Expect ($all[0].Name -eq 'PC-0000' -and $all[502].Name -eq 'PC-0502') 'name sort covers all pages'
 $page=Read-SortPage Name $true;Expect ($page.Rows[0].Name -eq 'PC-0502' -and $page.Rows[199].Name -eq 'PC-0303') 'descending name sort applied before first limit'
 $page=Read-SortPage LastLogon;Expect ($page.Rows[0].Usn -eq 1 -and $page.Rows[199].Usn -eq 200) 'French and ISO dates sorted chronologically across page boundary'
 $page=Read-SortPage LastLogon $true;Expect ($page.Rows[0].Usn -eq 499 -and $page.Rows[199].Usn -eq 300) 'date descending uses numeric date value'
 $page=Read-SortPage LastLogon $false 400;Expect ($page.Rows[98].Usn -eq 499 -and @($page.Rows|Select-Object -Last 4|Where-Object{$_.LastLogon}).Count -eq 0) 'unknown dates last in ascending order'
 $page=Read-SortPage LastLogon $true 400;Expect ($page.Rows[98].Usn -eq 1 -and @($page.Rows|Select-Object -Last 4|Where-Object{$_.LastLogon}).Count -eq 0) 'unknown dates last in descending order'
 $page=Read-SortPage WhenChanged $true;Expect ($page.Rows[0].Usn -eq 503) 'modification dates typed globally'
 foreach($field in @('Type','Login','Upn','State','Description','Score','Reason')){$page=Read-SortPage $field;Expect ($page.Total -eq 503 -and $page.Rows.Count -eq 200) ('whitelisted column '+$field)}
 foreach($field in @('Association','Name DESC; DELETE FROM ad_objects;--','object_key')){$refused=$false;try{Read-SortPage $field|Out-Null}catch{$refused=$_.Exception.Message -like '*tri locale*'};Expect $refused ('unknown SQL sort refused '+$field)}
 $page=Read-SortPage Name $false 0 '' 'OU=Other,DC=test';Expect ($page.Total -eq 0) 'sorting retains OU filter'
 $page=Read-SortPage Name $false 800;Expect ($page.Offset -eq 0 -and $page.Total -eq 503) 'outdated page returns to first page'
 $page=Read-SortPage '' $false 0 'PC-0001';Expect ($page.Rows[0].Score -eq 100) 'default relevance ordering retained'

 # Source UI and callbacks, isolated from WPF and task execution.
 . (Join-Path $modules 'Domenia-Common.Model.ps1');. (Join-Path $modules 'Domenia-Engine.UI.ps1')
 Import-Core Search-DomeniaIndexUi;Import-Core New-DomeniaIndexProgressChannel
 $script:Controls=@{TxtIndexSearch=[pscustomobject]@{Text='pc'};BtnIndexPrevious=[pscustomobject]@{IsEnabled=$true};BtnIndexNext=[pscustomobject]@{IsEnabled=$true}}
 function Get-DomeniaControl {param($Name);return $script:Controls[$Name]}
 function Set-DomeniaControlText {param($Name,$Text);$script:LastText=$Text;return $true}
 function Set-DomeniaItemsSource {param($Name,$Rows);$script:DisplayedRows=@($Rows);return $true}
 function Get-DomeniaIndexScope {return [pscustomobject]@{IsDomain=$true;BaseDn='DC=test'}}
 function Get-DomeniaLocalDatabasePathForRead {return $path}
 function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
 function Get-DomeniaIndexAssociationText {param($Row);return ''}
 function Add-DomeniaUiLog {param($Level,$Area,$Text)}
 function New-DomeniaTimer {
  param($Owner,$IntervalMs,$Tick,[switch]$SessionBound)
  $timer=[pscustomobject]@{Starts=0;Stops=0;Tick=$Tick}
  $timer|Add-Member ScriptMethod Start {$this.Starts++};$timer|Add-Member ScriptMethod Stop {$this.Stops++};return $timer
 }
 function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,$TaskClass);$script:Dispatch=[pscustomobject]@{Payload=$Payload;State=$CallbackState};return 'synthetic-job'}
 $script:SessionEpoch=7L;$script:DomeniaIndexSearchGeneration=0L;$script:DomeniaIndexSearchTimer=$null;$script:DomeniaIndexSort=$null;$script:DomeniaIndexSearchRetry=$null
 $column=[pscustomobject]@{SortMemberPath='LastLogon';SortDirection=$null};$other=[pscustomobject]@{SortMemberPath='Name';SortDirection=$null};$grid=[pscustomobject]@{Columns=@($column,$other)}
 $event=[pscustomobject]@{Column=$column;Handled=$false}
 Set-DomeniaIndexSearchSort $grid $event
 Expect ($event.Handled -and $script:DomeniaIndexSort.Field -eq 'LastLogon' -and -not $script:DomeniaIndexSort.Descending) 'header suppresses page-only sort and chooses typed field'
 Expect ($script:DomeniaIndexSearchGeneration -eq 1 -and $null -eq $script:DomeniaIndexSearchPage) 'sort invalidates callbacks and old pagination immediately'
 Search-DomeniaIndexUi
 Expect ($script:Dispatch.Payload.SortField -eq 'LastLogon' -and $script:Dispatch.State.SortField -eq 'LastLogon' -and $script:Dispatch.Payload.Offset -eq 0) 'SQL worker and callback receive same sort on first page'
 $firstState=$script:Dispatch.State
 Complete-DomeniaIndexSearchUi ([pscustomobject]@{Rows=@([pscustomobject]@{Name='shown';Guid='id'});Busy=$false;Total=503;Offset=0;HasMore=$true}) $firstState
 Expect ($script:DomeniaIndexSearchPage.SortField -eq 'LastLogon' -and $script:Controls.BtnIndexNext.IsEnabled) 'page remembers completed sort'
 Move-DomeniaIndexSearchPage 1
 Expect ($script:Dispatch.Payload.Offset -eq 200 -and $script:Dispatch.Payload.SortField -eq 'LastLogon') 'next page preserves global sort'
 $busyState=$script:Dispatch.State
 Complete-DomeniaIndexSearchUi ([pscustomobject]@{Rows=@();Busy=$true}) $busyState
 Search-DomeniaIndexUi
 Expect ($script:Dispatch.Payload.Offset -eq 200 -and $script:Dispatch.State.Attempt -eq 1 -and $script:Dispatch.Payload.SortField -eq 'LastLogon') 'busy retry keeps page and sort together'
 Set-DomeniaIndexSearchSort $grid $event
 Expect ($script:DomeniaIndexSort.Descending -and $column.SortDirection -eq [ComponentModel.ListSortDirection]::Descending) 'second click reverses direction'
 $script:DisplayedRows=@('sentinel');Complete-DomeniaIndexSearchUi ([pscustomobject]@{Rows=@();Busy=$false}) $firstState
 Expect ($script:DisplayedRows[0] -eq 'sentinel') 'late callback from previous sort cannot replace rows'
 Search-DomeniaIndexUi;Expect ($script:Dispatch.Payload.Offset -eq 0 -and $script:Dispatch.Payload.Descending) 'changed sort starts first page without stale retry'
 $script:DomeniaIndexSearchRetry=[pscustomobject]@{Term='pc';Scope='';Epoch=7L;Generation=$script:DomeniaIndexSearchGeneration;Attempt=1;Offset=400;Limit=200;SortField='Name';Descending=$false}
 Search-DomeniaIndexUi;Expect ($script:Dispatch.Payload.Offset -eq 0 -and $script:Dispatch.State.Attempt -eq 0) 'retry with different sort cannot restore old offset'
 $associationEvent=[pscustomobject]@{Column=[pscustomobject]@{SortMemberPath='Association';SortDirection=$null};Handled=$false}
 Set-DomeniaIndexSearchSort $grid $associationEvent;Expect ($script:DomeniaIndexSort.Field -eq 'LastLogon') 'computed association never becomes a misleading page sort'
 Set-DomeniaIndexSearchSort -Grid $grid -Reset;Search-DomeniaIndexUi
 Expect ($script:Dispatch.Payload.SortField -eq '' -and $null -eq $column.SortDirection) 'reset restores relevance ordering and clears glyphs'
 function Set-DomeniaIndexProgress {param($Mode,$Current,$Total,$Message);$script:ProgressText=$Message;$script:ProgressMode=$Mode}
 $script:IndexProgressTimer=$null;$progress=New-DomeniaIndexProgressChannel;$progress.Phase='Recensement GUID';$progress.Count=42
 & $script:IndexProgressTimer.Tick
 Expect ($script:ProgressMode -eq 'Busy' -and $script:ProgressText -like '*42 GUID*') 'real timer displays census phase without a fabricated total'
 $source=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
 $start=$source.IndexOf('<DataGrid x:Name="DgIndex"');$end=$source.IndexOf('</DataGrid>',$start);$gridSource=$source.Substring($start,$end-$start)
 Expect ($gridSource -match 'CanUserSortColumns="True"' -and $gridSource -match 'Binding="\{Binding Association\}" CanUserSort="False"') 'real grid enables global sorting except computed association'
 # The compact Base grid uses a single-line 28px cell; assert its own attributes, not another column.
 $detailColumn=[regex]::Match($gridSource,'<DataGridTemplateColumn\b(?=[^>]*\bSortMemberPath="Description")[^>]*>').Value
 $detailCell=[regex]::Match($gridSource,'<TextBlock\b(?=[^>]*\bText="\{Binding Description\}")[^>]*>').Value
 Expect ($detailColumn -match 'MinWidth="260"' -and $detailCell -match 'MaxHeight="28"' -and $detailCell -match 'TextWrapping="NoWrap"' -and $detailCell -match 'TextTrimming="CharacterEllipsis"') 'compact detail layout preserves width, single-line height and overflow bounds'
 $report=[ordered]@{Kind='IndexSorting';Passed=$script:checks;Failed=0;NativeWindowsPowerShell51=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5);WpfExecuted=$false;NetworkAccessed=$false;Objects=503;Summary='Real SQLite all-page sorting, mixed typed dates, scope, whitelist, production callbacks, retry/generation and census UI timer.'}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
 Write-Output ('PASS Base global sorting: '+$script:checks+' assertions; actual SQLite + inert UI callbacks, no WPF/AD')
}finally{if([IO.Directory]::Exists($folder)){Remove-Item -LiteralPath $folder -Recurse -Force}}
