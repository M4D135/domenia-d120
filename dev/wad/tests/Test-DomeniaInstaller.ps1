#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet,[switch]$RestoreOnly)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
$dev=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root=Join-Path $env:TEMP ('Domenia-install-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$manifest=[IO.File]::ReadAllText((Join-Path $dev 'tools\prod-manifest.json'))|ConvertFrom-Json
$utf8=[Text.UTF8Encoding]::new($true)
$checks=[Collections.Generic.List[object]]::new()
function Assert {param($Value,[string]$Message='Assertion fausse')if(-not $Value){throw $Message}}
function Hash {param($Path)return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Save {param($Path,$Text)[void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,$Text,$utf8)}
function Copy-One {param($From,$To)[void][IO.Directory]::CreateDirectory((Split-Path $To -Parent));[IO.File]::Copy($From,$To,$true)}
function Case {param($Name,[scriptblock]$Body)
 if($RestoreOnly -and $Name -notmatch 'retour verifie|restauration complete disponible'){return}
 try{& $Body|Out-Null;$status='Passed';$detail=''}catch{$status='Failed';$detail=$_.Exception.Message+' '+$_.ScriptStackTrace}
 $checks.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail});if(-not $Quiet){Write-Host ($status+' '+$Name+' '+$detail)}
}
function New-Fixture {
 $case=Join-Path $root ([guid]::NewGuid().ToString('N'));$src=Join-Path $case 'source';$dst=Join-Path $case 'active'
 foreach($entry in $manifest.Files){foreach($base in @($src,$dst)){Copy-One (Join-Path $dev $entry.Path) (Join-Path $base $entry.Path)}}
 Copy-One (Join-Path $dev 'INSTALLER-MISE-A-JOUR.ps1') (Join-Path $src 'INSTALLER-MISE-A-JOUR.ps1')
 Copy-One (Join-Path $dev 'tools\prod-manifest.json') (Join-Path $src 'tools\prod-manifest.json')
 Copy-One (Join-Path $dev 'tools\operation-contracts.json') (Join-Path $src 'tools\operation-contracts.json')
 # Isolate the installer from the already-covered preloader suite. This is an explicit test double,
 # not a Windows qualification report. Real staged and installed startup checks still run below.
 $gate=@'
param([string]$ReportPath,[switch]$Quiet)
[IO.File]::WriteAllText($ReportPath,('{"FixtureOnly":true,"Complete":true,"NativeWindowsPowerShell":true,"Wpf":true,"Failed":0,"Skipped":0,"Passed":40}'))
exit 0
'@
 Save (Join-Path $src 'wad\tests\Test-DomeniaPreload.ps1') $gate
 Copy-One (Join-Path $dev 'tools\prod-manifest.json') (Join-Path $src 'wad\package-manifest.json')
 $old=$manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json;$old.Build+='-previous-test'
 $oldCore=Join-Path $dst 'wad\Domenia-Core.ps1';[IO.File]::AppendAllText($oldCore,"`n# Previous fixture version.`n",$utf8)
 ($old.Files|Where-Object Path -eq 'wad/Domenia-Core.ps1').Sha256=Hash $oldCore
 Save (Join-Path $dst 'wad\package-manifest.json') ($old|ConvertTo-Json -Depth 8)
 Save (Join-Path $dst 'wad\Domenia.config.json') '{"OperatorPreference":"preserve-me"}'
 Save (Join-Path $dst 'wad\data\preserve-me.txt') 'test-data'
 return [pscustomobject]@{Dir=$case;Source=$src;Target=$dst;OldHash=(Hash $oldCore)}
}
function Run-Script {
 param([string]$Path,[string[]]$Extra=@())
 $log=$Path+'.'+[guid]::NewGuid().ToString('N');$arguments=@('-NoLogo','-NoProfile','-STA','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$Path+'"'))+$Extra
 $p=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput ($log+'.out') -RedirectStandardError ($log+'.err');$null=$p.Handle
 if(-not $p.WaitForExit(90000)){try{$p.Kill()}catch{};throw ('Processus de test hors delai : '+$log)}
 $p.WaitForExit();return [pscustomobject]@{Code=$p.ExitCode;Output=([IO.File]::ReadAllText($log+'.out')+[IO.File]::ReadAllText($log+'.err'))}
}
function Install {
 param($Fixture,[string]$Mode='Normal')
 $runner=Join-Path $Fixture.Dir 'invoke.ps1'
 $text=@'
$ErrorActionPreference='Stop'
$global:fixtureRoot=$PSScriptRoot
$global:mode='MODE'
$installer=Join-Path $PSScriptRoot 'source\INSTALLER-MISE-A-JOUR.ps1'
$lines=[IO.File]::ReadAllLines($installer)
for($i=0;$i -lt $lines.Length;$i++){
 if($lines[$i].Trim() -eq '$started=$true'){
  Set-PSBreakpoint -Script $installer -Line ($i+1) -Action {
   $m=[IO.File]::ReadAllText((Join-Path $staged 'wad/package-manifest.json'))|ConvertFrom-Json
   foreach($e in $m.Files){if(-not [IO.File]::Exists((Join-Path $staged $e.Path))){throw 'Preparation incomplete avant activation.'}}
   [IO.File]::WriteAllText((Join-Path $global:fixtureRoot 'prepared.txt'),[string]@($m.Files).Count)
   if($global:mode -eq 'MutateSource'){[IO.File]::AppendAllText((Join-Path $global:fixtureRoot 'source\wad\Domenia-Core.ps1'),'# Source changed after staging')}
  }|Out-Null
 }
 if($lines[$i].Trim() -eq "if((Get-CodeHash `$to) -cne [string]`$entry.NewSha256) {throw 'Verification apres copie en echec.'}"){
  Set-PSBreakpoint -Script $installer -Line ($i+1) -Action {
   if($global:mode -eq 'Interrupt' -and $entry.Path -eq 'wad/Domenia-Core.ps1'){[Environment]::Exit(77)}
  }|Out-Null
 }
 if($lines[$i].Trim() -eq 'Assert-CodeVersion $targetRoot $manifest $lock'){
  Set-PSBreakpoint -Script $installer -Line ($i+1) -Action {
   if($global:mode -eq 'ForeignTarget'){[IO.File]::AppendAllText((Join-Path $global:fixtureRoot 'active\wad\modules\Domenia-Common.Model.ps1'),'# External change')}
  }|Out-Null
 }
}
& $installer -Destination (Join-Path $PSScriptRoot 'active') -Confirm:$false
'@
 Save $runner ($text.Replace('MODE',$Mode));return Run-Script $runner
}
function Start-Check {param($Fixture)return Run-Script (Join-Path $Fixture.Target 'wad\Domenia-Start.ps1') @('-CheckOnly')}
function Backup {param($Fixture)return @(Get-ChildItem (Join-Path $Fixture.Target 'wad\maintenance\backups') -Directory|Where-Object {Test-Path (Join-Path $_.FullName 'transaction.json')})[0].FullName}
function Restore {param($Fixture,$Backup)return Run-Script (Join-Path $Fixture.Source 'INSTALLER-MISE-A-JOUR.ps1') @('-RestoreBackup',('"'+$Backup+'"'))}
try{
 Case 'D114 version complete preparee, activation, preferences et donnees conservees, retour verifie' {
  $f=New-Fixture;$r=Install $f;Assert ($r.Code -eq 0) $r.Output
  Assert ([IO.File]::ReadAllText((Join-Path $f.Dir 'prepared.txt')) -eq [string]$manifest.Files.Count)
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq (Hash (Join-Path $f.Source 'wad\Domenia-Core.ps1')))
  Assert ([IO.File]::ReadAllText((Join-Path $f.Target 'wad\Domenia.config.json')) -match 'preserve-me')
  Assert ([IO.File]::ReadAllText((Join-Path $f.Target 'wad\data\preserve-me.txt')) -eq 'test-data')
  Assert ((Start-Check $f).Code -eq 0);$backup=Backup $f;$r=Restore $f $backup;Assert ($r.Code -eq 0) $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash);Assert ((Start-Check $f).Code -eq 0)
 }
 Case 'D114 source corrompue refusee avant modification du code actif' {
  $f=New-Fixture;[IO.File]::AppendAllText((Join-Path $f.Source 'wad\Domenia-Core.ps1'),'# broken')
  $r=Install $f;Assert ($r.Code -ne 0);Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  Assert (-not (Test-Path (Join-Path $f.Target 'wad\Support\.update.pending')))
 }
 Case 'D114 verrou exclusif interdit le lancement et la mise a jour concurrents' {
  $f=New-Fixture;$lock=[IO.File]::Open((Join-Path $f.Target 'wad\Support\.lifecycle.lock'),'Open','ReadWrite','None')
  try{Assert ((Start-Check $f).Code -ne 0);Assert ((Install $f).Code -ne 0)}finally{$lock.Dispose()}
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
 }
 Case 'D114 interruption au milieu des copies bloque le lancement, restauration complete disponible' {
  $f=New-Fixture;$r=Install $f 'Interrupt';Assert ($r.Code -eq 77) $r.Output
  Assert (Test-Path (Join-Path $f.Target 'wad\Support\.update.pending'));Assert ((Start-Check $f).Code -ne 0)
  $r=Restore $f (Backup $f);Assert ($r.Code -eq 0) $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash);Assert ((Start-Check $f).Code -eq 0)
 }
 Case 'D114 copie preparee independante des modifications ulterieures de la source' {
  $f=New-Fixture;$r=Install $f 'MutateSource';Assert ($r.Code -eq 0) $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq (Hash (Join-Path $dev 'wad\Domenia-Core.ps1')))
  Assert ((Hash (Join-Path $f.Source 'wad\Domenia-Core.ps1')) -ne (Hash (Join-Path $dev 'wad\Domenia-Core.ps1')))
  Assert ((Start-Check $f).Code -eq 0)
 }
 Case 'D114 controle final couvre aussi les fichiers inchanges, conflit conserve et lancement bloque' {
  $f=New-Fixture;$r=Install $f 'ForeignTarget';Assert ($r.Code -ne 0)
  Assert (Test-Path (Join-Path $f.Target 'wad\Support\.update.pending'));Assert ((Start-Check $f).Code -ne 0)
  Assert ((Hash (Join-Path $f.Target 'wad\modules\Domenia-Common.Model.ps1')) -ne (Hash (Join-Path $dev 'wad\modules\Domenia-Common.Model.ps1')))
 }
}finally{
 # All processes are bounded; the temporary fixtures contain no real installation or AD data.
 Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
$passed=@($checks|Where-Object Status -eq 'Passed').Count;$failed=@($checks|Where-Object Status -eq 'Failed').Count
$expected=if($RestoreOnly){2}else{6}
$report=[ordered]@{Suite='Test-DomeniaInstaller';Passed=$passed;Failed=$failed;Skipped=0;Expected=$expected;Complete=($checks.Count -eq $expected);NativeWindowsPowerShell51=$true;PSVersion=$PSVersionTable.PSVersion.ToString();Checks=$checks.ToArray()}
if($ReportPath){Save $ReportPath ($report|ConvertTo-Json -Depth 7)}
Write-Host ('Installer : '+$passed+' reussis, '+$failed+' echecs')
if($failed -gt 0 -or $checks.Count -ne $expected){exit 1};exit 0
