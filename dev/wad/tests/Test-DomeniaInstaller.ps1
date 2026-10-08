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
 # -Prod: the source is an extracted PROD package (Domenia.exe and wad only, no tools folder, no test suite).
 param([switch]$Prod)
 $case=Join-Path $root ([guid]::NewGuid().ToString('N'));$src=Join-Path $case 'source';$dst=Join-Path $case 'active'
 foreach($entry in $manifest.Files){foreach($base in @($src,$dst)){Copy-One (Join-Path $dev $entry.Path) (Join-Path $base $entry.Path)}}
 if(-not $Prod){
  Copy-One (Join-Path $dev 'INSTALLER-MISE-A-JOUR.ps1') (Join-Path $src 'INSTALLER-MISE-A-JOUR.ps1')
  Copy-One (Join-Path $dev 'tools\prod-manifest.json') (Join-Path $src 'tools\prod-manifest.json')
  Copy-One (Join-Path $dev 'tools\operation-contracts.json') (Join-Path $src 'tools\operation-contracts.json')
 }
 # FI-06: no test suite exists in the source; the installer must not need one.
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
 # ARGS defaults to an update of the fixture target with the question waived (-Confirm:$false).
 param($Fixture,[string]$Mode='Normal',[string]$Arguments='-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false')
 $runner=Join-Path $Fixture.Dir ('invoke-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.ps1')
 $text=@'
$ErrorActionPreference='Stop'
$global:fixtureRoot=$PSScriptRoot
$global:mode='MODE'
$installer=Join-Path $PSScriptRoot 'source\wad\Support\INSTALLER-MISE-A-JOUR.ps1'
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
 if($lines[$i].Trim() -eq "if((Get-CodeHash `$to) -cne [string]`$entry.NewSha256) {throw 'Vérification après copie en échec.'}"){
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
& $installer ARGS
'@
 Save $runner ($text.Replace('MODE',$Mode).Replace('ARGS',$Arguments));return Run-Script $runner
}
function Start-Check {param($Fixture,[string]$Path='')if(-not $Path){$Path=$Fixture.Target};return Run-Script (Join-Path $Path 'wad\Domenia-Start.ps1') @('-CheckOnly')}
function Backup {param($Fixture)return @(Get-ChildItem (Join-Path $Fixture.Target 'wad\maintenance\backups') -Directory|Where-Object {Test-Path (Join-Path $_.FullName 'transaction.json')}|Sort-Object Name -Descending)[0].FullName}
function Restore {param($Fixture,$Backup)return Run-Script (Join-Path $Fixture.Source 'wad\Support\INSTALLER-MISE-A-JOUR.ps1') @('-RestoreBackup',('"'+$Backup+'"'))}
function Set-ReleaseLimit {
 # Rewrites RuntimeFileLimit in the target copy and its manifest hash, as a reviewed contract change would.
 param($Fixture,[int]$Limit)
 $path=Join-Path $Fixture.Target 'wad\Domenia.release.json'
 $text=[IO.File]::ReadAllText($path) -replace '"RuntimeFileLimit":\s*\d+',('"RuntimeFileLimit": '+$Limit)
 [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
 $active=[IO.File]::ReadAllText((Join-Path $Fixture.Target 'wad\package-manifest.json'))|ConvertFrom-Json
 ($active.Files|Where-Object Path -eq 'wad/Domenia.release.json').Sha256=Hash $path
 Save (Join-Path $Fixture.Target 'wad\package-manifest.json') ($active|ConvertTo-Json -Depth 8)
}
function New-QualifiedPackage {
 # Test double of a delivered ZIP (its manifest only) and of a release_guard report bound to it. Fixture only:
 # neither is a Windows qualification of the real delivery.
 param($Fixture,[string]$BoundSha='')
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $zipPath=Join-Path $Fixture.Dir 'Domenia_PROD.zip'
 if(-not [IO.File]::Exists($zipPath)){
  $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
  try{[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $dev 'tools\prod-manifest.json'),'prod/wad/package-manifest.json')}finally{$zip.Dispose()}
 }
 if(-not $BoundSha){$BoundSha=(Hash $zipPath).ToLowerInvariant()}
 $scenarios=@('parser.ps51','runtime.modules','worker.contracts','startup.exe_login_main','ui.actual_events','ui.layout_profiles','data.sqlite','security.secret_markers','race.selection','prod.standalone'|ForEach-Object{[ordered]@{Id=$_;Status='PASS';Executed=$true;StartedUtc='2026-10-08T10:00:00Z';EndedUtc='2026-10-08T10:01:00Z';EvidenceSHA256=('b'*64)}})
 $report=[ordered]@{FixtureOnly=$true;Build=[string]$manifest.Build;ArchiveSHA256=$BoundSha;Host=[ordered]@{Platform='Windows';PSEdition='Desktop';PSVersion=$PSVersionTable.PSVersion.ToString()};OverallStatus='PASS';Scenarios=$scenarios}
 $reportPath=Join-Path $Fixture.Dir ('qualification-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
 Save $reportPath ($report|ConvertTo-Json -Depth 6)
 return [pscustomobject]@{Zip=$zipPath;Report=$reportPath}
}
try{
 Case 'D114 version complete preparee, activation, preferences et donnees conservees, retour verifie' {
  $f=New-Fixture;$r=Install $f;Assert ($r.Code -eq 0) $r.Output
  Assert ([IO.File]::ReadAllText((Join-Path $f.Dir 'prepared.txt')) -eq [string]$manifest.Files.Count)
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq (Hash (Join-Path $f.Source 'wad\Domenia-Core.ps1')))
  Assert ([IO.File]::ReadAllText((Join-Path $f.Target 'wad\Domenia.config.json')) -match 'preserve-me')
  Assert ([IO.File]::ReadAllText((Join-Path $f.Target 'wad\data\preserve-me.txt')) -eq 'test-data')
  # FI-06 and UX-29: no suite on the target, missing qualification reported, prepared copy removed, versions summarised.
  Assert ($r.Output -match 'Aucun rapport de qualification') $r.Output
  Assert ($r.Output -match ('Version avant : '+[regex]::Escape([string]$manifest.Build+'-previous-test'))) $r.Output
  Assert (-not (Test-Path (Join-Path (Backup $f) 'prepared'))) 'Dossier prepared conserve apres succes.'
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
 Case 'FI-06 -RequireQualification sans rapport lie au hash du ZIP : refus avant toute modification' {
  $f=New-Fixture;$r=Install $f -Arguments '-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false -RequireQualification'
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'qualification') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  Assert (-not (Test-Path (Join-Path $f.Target 'wad\maintenance\backups'))) 'Sauvegarde creee malgre le refus.'
 }
 Case 'FI-06 rapport lie au hash du ZIP accepte, rapport d un autre ZIP refuse' {
  $f=New-Fixture
  $wrong=New-QualifiedPackage $f ('0'*64)
  $r=Install $f -Arguments ('-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false -RequireQualification -Package '''+$wrong.Zip+''' -QualificationReport '''+$wrong.Report+'''')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'non li') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  $good=New-QualifiedPackage $f
  $r=Install $f -Arguments ('-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false -RequireQualification -Package '''+$good.Zip+''' -QualificationReport '''+$good.Report+'''')
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'Qualification : rapport Windows PowerShell 5.1') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq (Hash (Join-Path $dev 'wad\Domenia-Core.ps1')))
 }
 Case 'UX-29 sans reponse de l operateur rien n est installe' {
  $f=New-Fixture;$r=Install $f -Arguments '-Destination (Join-Path $PSScriptRoot ''active'')'
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'Installation annul') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  Assert (-not (Test-Path (Join-Path $f.Target 'wad\maintenance\backups'))) 'Sauvegarde creee sans reponse.'
 }
 Case 'UX-29 cinq sauvegardes completes gardees, preparation abandonnee retiree, RestoreLatest' {
  $f=New-Fixture;$parent=Join-Path $f.Target 'wad\maintenance\backups'
  for($i=1;$i -le 6;$i++){Save (Join-Path $parent ('2020010'+$i+'-000000-0000000'+$i+'\transaction.json')) ('{"Format":1,"Build":"old-'+$i+'","Status":"Installed","Destination":"'+$f.Target.Replace('\','\\')+'","Files":[]}')}
  Save (Join-Path $parent '20200107-000000-00000007\transaction.json') ('{"Format":1,"Build":"old-7","Status":"Prepared","Destination":"'+$f.Target.Replace('\','\\')+'","Files":[]}')
  Save (Join-Path $parent '20200108-000000-00000008\prepared\wad\x.txt') 'abandoned'
  $r=Install $f;Assert ($r.Code -eq 0) $r.Output
  $names=@(Get-ChildItem $parent -Directory|ForEach-Object Name|Sort-Object)
  foreach($gone in @('20200101-000000-00000001','20200102-000000-00000002','20200108-000000-00000008')){Assert ($names -notcontains $gone) ('Sauvegarde non retiree : '+$gone)}
  foreach($kept in @('20200103-000000-00000003','20200104-000000-00000004','20200105-000000-00000005','20200106-000000-00000006','20200107-000000-00000007')){Assert ($names -contains $kept) ('Sauvegarde retiree a tort : '+$kept)}
  Assert ($names.Count -eq 6) ('Sauvegardes : '+($names -join ', '))
  $r=Run-Script (Join-Path $f.Target 'wad\Support\INSTALLER-MISE-A-JOUR.ps1') @('-RestoreLatest','-Destination',('"'+$f.Target+'"'))
  Assert ($r.Code -eq 0) $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash);Assert ((Start-Check $f).Code -eq 0)
 }
 Case 'FO-20 premiere installation PROD dans un dossier vide, raccourcis jamais crees sans reponse' {
  $f=New-Fixture -Prod;$fresh=Join-Path $f.Dir 'fresh'
  Assert (-not (Test-Path (Join-Path $f.Source 'tools'))) 'Source PROD attendue.'
  $r=Install $f -Arguments ('-Install -Destination '''+$fresh+''' -Confirm:$false')
  Assert ($r.Code -eq 0) $r.Output
  foreach($entry in $manifest.Files){Assert ((Hash (Join-Path $fresh $entry.Path)) -eq $entry.Sha256) ('Empreinte differente : '+$entry.Path)}
  Assert ((Hash (Join-Path $fresh 'wad\package-manifest.json')) -eq (Hash (Join-Path $dev 'tools\prod-manifest.json')))
  Assert (@([regex]::Matches($r.Output,'non cr')).Count -eq 2) $r.Output
  Assert ((Start-Check $f $fresh).Code -eq 0)
  $r=Install $f -Arguments ('-Install -Destination '''+$fresh+''' -Confirm:$false')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'pas vide') $r.Output
 }
 Case 'FI-14 plafond du runtime lu dans wad/Domenia.release.json' {
  $f=New-Fixture
  Set-ReleaseLimit $f 50;$r=Start-Check $f
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'plafond de 50') $r.Output
  Set-ReleaseLimit $f 250;$r=Start-Check $f
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'plafond 250') $r.Output
 }
}finally{
 # All processes are bounded; the temporary fixtures contain no real installation or AD data.
 Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
$passed=@($checks|Where-Object Status -eq 'Passed').Count;$failed=@($checks|Where-Object Status -eq 'Failed').Count
$expected=if($RestoreOnly){2}else{12}
$report=[ordered]@{Suite='Test-DomeniaInstaller';Passed=$passed;Failed=$failed;Skipped=0;Expected=$expected;Complete=($checks.Count -eq $expected);NativeWindowsPowerShell51=$true;PSVersion=$PSVersionTable.PSVersion.ToString();Checks=$checks.ToArray()}
if($ReportPath){Save $ReportPath ($report|ConvertTo-Json -Depth 7)}
Write-Host ('Installer : '+$passed+' reussis, '+$failed+' echecs')
if($failed -gt 0 -or $checks.Count -ne $expected){exit 1};exit 0
