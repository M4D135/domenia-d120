#requires -Version 5.1
param([string]$DevRoot='C:\Windows\Temp\Domenia-RC21-Completion\dev',[string]$OutDir='C:\Windows\Temp\Domenia-RC21-Completion\full-volume')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[void][IO.Directory]::CreateDirectory($OutDir)
$report=[ordered]@{Suite='RC21.ActualFullVolume';Passed=$false;PowerShell=$PSVersionTable.PSVersion.ToString();StartedUtc=[datetime]::UtcNow.ToString('o');Checks=@();Error='';Cleanup=$false}
$diskFile=Join-Path $OutDir ('disposable-'+[guid]::NewGuid().ToString('N')+'.vhd')
function Check {param([bool]$Value,[string]$Name);$report.Checks += [pscustomobject]@{Name=$Name;Passed=$Value};if(-not $Value){throw $Name}}
function DiskPart {param([string[]]$Lines,[string]$Name);$f=Join-Path $OutDir ($Name+'.txt');$Lines|Set-Content $f -Encoding ASCII;& diskpart.exe /s $f | Out-File (Join-Path $OutDir ($Name+'.log'));if($LASTEXITCODE -ne 0){throw ('Diskpart '+$Name+' failed')}}
try{
 Check (-not (Test-Path $diskFile)) 'Fresh disposable VHD path'
 $letter=@(90..68|ForEach-Object{[string][char]$_}|Where-Object{-not (Test-Path ($_+':\')) -and -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue)})[0]
 Check ([bool]$letter) 'Unused non-system drive letter'
 DiskPart @(('create vdisk file="'+$diskFile+'" maximum=128 type=fixed'),('select vdisk file="'+$diskFile+'"'),'attach vdisk','create partition primary','format fs=ntfs label=DOMENIA_RC21 quick',('assign letter='+$letter)) 'create'
 $image=Get-DiskImage -ImagePath $diskFile;$disk=$image|Get-Disk;$partition=Get-Partition -DriveLetter $letter
 Check ($image.Attached -and $disk.Number -eq $partition.DiskNumber -and -not $disk.IsSystem -and -not $disk.IsBoot) 'Selected volume belongs only to disposable VHD'
 $folder=$letter+':\';$report.Volume=[pscustomobject]@{BackingFile=$diskFile;Drive=$letter;SizeBytes=[long]$disk.Size;DiskNumber=$disk.Number;FileSystem=(Get-Volume -DriveLetter $letter).FileSystem}
 $wad=Join-Path $DevRoot 'wad';$modules=Join-Path $wad 'modules'
 function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord,$Now)}
 $t=$null;$e=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
 foreach($name in @('Initialize-DomeniaWinSqliteNative','Get-DomeniaSqliteSchemaText')){$fn=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($fn.Count -ne 1){throw ('Missing '+$name)};. ([scriptblock]::Create($fn[0].Extent.Text))}
 [void](Initialize-DomeniaWinSqliteNative)
 foreach($name in @('Common.Model','Probes.Model','QueryLibrary.Model','Store.Model','Cache.Model','Storage.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
 . (Join-Path $wad 'tests\fixtures\Domenia-LoadFixtures.ps1')
 $script:SchemaText=Get-DomeniaSqliteSchemaText;$script:Worker=Get-DomeniaStorageWorkerCode;$script:Domain='DC=example,DC=invalid'
 $ast=[Management.Automation.Language.Parser]::ParseInput($script:Worker,[ref]$t,[ref]$e)
 foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
 $faults=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'tests\Test-DomeniaStorageFaults.ps1'),[ref]$t,[ref]$e)
 foreach($name in @('New-FaultBase','New-FaultDirectoryChange','New-FaultPing','New-FaultBatch','Invoke-FaultWorker','Read-FaultBase','Get-FaultState','Get-FaultBatchId')){$fn=@($faults.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($fn.Count -ne 1){throw ('Missing '+$name)};. ([scriptblock]::Create($fn[0].Extent.Text))}
 $base=New-FaultBase 'actual-full';$before=Get-FaultState $base
 $c=Get-DomeniaLoadComputer -Index 3;$change=New-FaultDirectoryChange $c '2026-03-01T00:00:00Z';$change.Data.Details=[pscustomobject]@{description=('X'*524288)}
 $payload=New-FaultBatch $base @($change);$id=Get-FaultBatchId $payload
 $filler=Join-Path $folder 'domenia-filler.bin';$stream=[IO.File]::Open($filler,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$fillError='';$fillCode=0
 try{foreach($size in @(1048576,4096)){ $bytes=[byte[]]::new($size);while($true){try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}catch{$ex=$_.Exception;while($ex.InnerException){$ex=$ex.InnerException};$fillError=$ex.Message;$fillCode=$ex.HResult -band 65535;break}}}}finally{$stream.Dispose()}
 $free=[IO.DriveInfo]::new($folder).AvailableFreeSpace;$report.FullVolume=[pscustomobject]@{FreeBytes=$free;Win32Error=$fillCode;Message=$fillError}
 Check ($fillCode -eq 112 -and $free -lt 4096) 'NTFS genuinely full (Windows ERROR_DISK_FULL), no SQLite quota'
 $errorText='';try{$write=Invoke-FaultWorker $base $payload}catch{$errorText=$_.Exception.Message}
 $report.Refusal=$errorText
 Check ($errorText -match 'StorageInsufficientSpace|SQLite code 13') 'Production writer explicitly refuses the full volume'
 Remove-Item -LiteralPath $filler -Force
 $after=Get-FaultState $base $id
 Check ($after.Integrity -eq 'ok' -and $after.Revision -eq $before.Revision -and $after.BatchReceipts -eq 0) 'No partial revision or receipt after failed write'
 Check (@(Read-FaultBase $base ("SELECT 1 AS x FROM domenia_directory_data WHERE object_guid="+(ConvertTo-DomeniaSqlLiteral $c.Guid)+" AND payload LIKE '%XXXX%';")).Count -eq 0) 'No partial payload'
 $retry=Invoke-FaultWorker $base $payload;Check ([bool]$retry.Saved -and -not [bool]$retry.Already) 'Same batch writes successfully after space is freed'
 $replay=Invoke-FaultWorker $base $payload;Check ([bool]$replay.Already) 'Second replay does not duplicate the batch'
 $final=Get-FaultState $base $id;Check ($final.Integrity -eq 'ok' -and $final.Revision -eq $before.Revision+1 -and $final.BatchReceipts -eq 1) 'Exactly one committed revision and one receipt'
 $report.Before=$before;$report.AfterFailure=$after;$report.Final=$final;$report.Passed=$true
}catch{$report.Error=$_.Exception.Message+' @ '+$_.ScriptStackTrace}finally{
 if(Test-Path $diskFile){try{DiskPart @(('select vdisk file="'+$diskFile+'"'),'detach vdisk') 'detach';$attached=(Get-DiskImage -ImagePath $diskFile).Attached;if($attached){throw 'VHD remains attached'};Remove-Item -LiteralPath $diskFile -Force;$report.Cleanup=$true}catch{$report.Passed=$false;$report.Error+='; cleanup: '+$_.Exception.Message}}
 $report.EndedUtc=[datetime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 8|Set-Content (Join-Path $OutDir 'ActualFullVolume.json') -Encoding UTF8
}
if(-not $report.Passed){exit 1}
