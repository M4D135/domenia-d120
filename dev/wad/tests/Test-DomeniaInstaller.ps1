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
 # -Answers: the operator's typed answers, one per line, read by Read-Host from the redirected input (interactive host).
 param([string]$Path,[string[]]$Extra=@(),[string[]]$Answers=$null)
 $log=$Path+'.'+[guid]::NewGuid().ToString('N')
 $arguments=@('-NoLogo','-NoProfile','-STA')
 if($null -eq $Answers){$arguments+='-NonInteractive'}
 $arguments+=@('-ExecutionPolicy','Bypass','-File',('"'+$Path+'"'))+$Extra
 $redirect=@{RedirectStandardOutput=($log+'.out');RedirectStandardError=($log+'.err')}
 if($null -ne $Answers){[IO.File]::WriteAllText(($log+'.in'),(($Answers -join "`r`n")+"`r`n"));$redirect.RedirectStandardInput=($log+'.in')}
 $p=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -NoNewWindow -PassThru @redirect;$null=$p.Handle
 if(-not $p.WaitForExit(90000)){try{$p.Kill()}catch{};throw ('Processus de test hors delai : '+$log)}
 $p.WaitForExit();return [pscustomobject]@{Code=$p.ExitCode;Output=([IO.File]::ReadAllText($log+'.out')+[IO.File]::ReadAllText($log+'.err'))}
}
function Install {
 # ARGS defaults to an update of the fixture target with the question waived (-Confirm:$false). -Relay goes through the
 # DEV entry point (dev\INSTALLER-MISE-A-JOUR.ps1); -Prelude runs first (for instance a Set-Location).
 param($Fixture,[string]$Mode='Normal',[string]$Arguments='-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false',[string[]]$Answers=$null,[switch]$Relay,[string]$Prelude='')
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
PRELUDE
& $(if($global:relay){Join-Path $PSScriptRoot 'source\INSTALLER-MISE-A-JOUR.ps1'}else{$installer}) ARGS
exit ([int]$LASTEXITCODE)
'@
 $text=$text.Replace('$global:mode=''MODE''',('$global:mode='''+$Mode+''';$global:relay=$'+([bool]$Relay).ToString().ToLowerInvariant()))
 Save $runner ($text.Replace('PRELUDE',$Prelude).Replace('ARGS',$Arguments));return Run-Script $runner @() $Answers
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
function Set-ReleaseSchema {
 # Point 143: DataSchemaVersion of the active copy (as an older version would declare it) and its manifest hash.
 param($Fixture,[int]$Schema)
 $path=Join-Path $Fixture.Target 'wad\Domenia.release.json'
 $text=[IO.File]::ReadAllText($path) -replace '"DataSchemaVersion":\s*\d+',('"DataSchemaVersion": '+$Schema)
 [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
 $active=[IO.File]::ReadAllText((Join-Path $Fixture.Target 'wad\package-manifest.json'))|ConvertFrom-Json
 ($active.Files|Where-Object Path -eq 'wad/Domenia.release.json').Sha256=Hash $path
 Save (Join-Path $Fixture.Target 'wad\package-manifest.json') ($active|ConvertTo-Json -Depth 8)
}
function New-InstalledCopy {
 # Point 144: a copy installed by the real installer (-Install) from a PROD fixture, into the fixture folder.
 param([string]$Name,[ValidateSet('Non','Oui')][string]$Shortcuts='Non')
 $f=New-Fixture -Prod;$path=Join-Path $f.Dir $Name
 $r=Install $f -Arguments ('-Install -Destination '''+$path+''' -Confirm:$false -Shortcuts '+$Shortcuts)
 if($r.Code -ne 0){throw ('Installation de la copie de test en echec : '+$r.Output)}
 return [pscustomobject]@{Fixture=$f;Path=$path}
}
$script:Schema=[int](([IO.File]::ReadAllText((Join-Path $dev 'wad\Domenia.release.json'))|ConvertFrom-Json).DataSchemaVersion)
$script:ElevatedSession=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function New-QualifiedPackage {
 # Test double of a delivered PROD ZIP (every runtime file and its manifest, or the manifest alone with -ManifestOnly)
 # and of a release_guard report bound to it. -Edit changes the report before it is written. Temporary test data only:
 # neither is a Windows qualification of the real delivery.
 param($Fixture,[string]$BoundSha='',[scriptblock]$Edit=$null,[switch]$ManifestOnly)
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $zipPath=Join-Path $Fixture.Dir $(if($ManifestOnly){'Domenia_PROD_manifeste.zip'}else{'Domenia_PROD.zip'})
 if(-not [IO.File]::Exists($zipPath)){
  $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
  try{
   if(-not $ManifestOnly){foreach($entry in $manifest.Files){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $dev $entry.Path),('prod/'+$entry.Path))}}
   [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $dev 'tools\prod-manifest.json'),'prod/wad/package-manifest.json')
  }finally{$zip.Dispose()}
 }
 if(-not $BoundSha){$BoundSha=(Hash $zipPath).ToLowerInvariant()}
 $scenarios=@($script:RequiredScenarios|ForEach-Object{[pscustomobject][ordered]@{Id=$_;Status='PASS';Executed=$true;StartedUtc='2026-10-08T10:00:00Z';EndedUtc='2026-10-08T10:01:00Z';EvidenceSHA256=('b'*64)}})
 $report=[pscustomobject][ordered]@{Build=[string]$manifest.Build;ArchiveSHA256=$BoundSha;Host=[pscustomobject][ordered]@{Platform='Windows';PSEdition='Desktop';PSVersion=$PSVersionTable.PSVersion.ToString()};OverallStatus='PASS';Scenarios=$scenarios}
 if($null -ne $Edit){& $Edit $report}
 $reportPath=Join-Path $Fixture.Dir ('qualification-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
 Save $reportPath ($report|ConvertTo-Json -Depth 6)
 return [pscustomobject]@{Zip=$zipPath;Report=$reportPath}
}
# Floor of engineering/d120/release_guard.py REQUIRED, read from the installer itself (a Python test compares them).
$script:InstallerPath=Join-Path $dev 'wad\Support\INSTALLER-MISE-A-JOUR.ps1'
$installerTokens=$null;$installerErrors=$null
$script:InstallerAst=[Management.Automation.Language.Parser]::ParseFile($script:InstallerPath,[ref]$installerTokens,[ref]$installerErrors)
$script:RequiredScenarios=@(& ([scriptblock]::Create($script:InstallerAst.Find({param($n) ($n -is [Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -ceq '$qualificationScenarios')},$true).Right.Extent.Text)))
function Get-InstallerFunctionText {
 # Real function text of the installer, for direct checks of its offline rules (the script itself has top-level code).
 # The caller dot-sources the returned text, so no helper variable leaks into its scope.
 param([string[]]$FunctionNames)
 $texts=foreach($wanted in $FunctionNames){$script:InstallerAst.Find({param($x) ($x -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($x.Name -ceq $wanted)},$true).Extent.Text}
 return ($texts -join "`n")
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
  Assert (Test-Path (Join-Path $f.Target 'wad\Support\.update.pending'))
  # The startup refusal names the restore script of that backup and the complete fallback command.
  $c=Start-Check $f;Assert ($c.Code -ne 0) $c.Output
  Assert (($c.Output -match 'RESTAURER-CODE\.ps1') -and ($c.Output -match '-RestoreBackup') -and ($c.Output -match '-RestoreLatest -Destination')) $c.Output
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
  # A supplied report that is refused stops the installation even without -RequireQualification.
  $failed=New-QualifiedPackage $f -Edit {param($r) $r.OverallStatus='FAIL'}
  $r=Install $f -Arguments ('-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false -Package '''+$failed.Zip+''' -QualificationReport '''+$failed.Report+'''')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'fourni refus') $r.Output;Assert ($r.Output -notmatch 'Aucun rapport') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  Assert (-not (Test-Path (Join-Path $f.Target 'wad\maintenance\backups'))) 'Sauvegarde creee malgre le refus.'
  $good=New-QualifiedPackage $f
  $r=Install $f -Arguments ('-Destination (Join-Path $PSScriptRoot ''active'') -Confirm:$false -RequireQualification -Package '''+$good.Zip+''' -QualificationReport '''+$good.Report+'''')
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'Qualification : rapport Windows PowerShell 5.1') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq (Hash (Join-Path $dev 'wad\Domenia-Core.ps1')))
 }
 Case 'UX-29 sans reponse de l operateur rien n est installe, code 2 transmis par l entree DEV' {
  # Through dev\INSTALLER-MISE-A-JOUR.ps1 (relay): the exit code 2 reaches a scripted deployment.
  $f=New-Fixture;$r=Install $f -Relay -Arguments '-Destination (Join-Path $PSScriptRoot ''active'')'
  Assert ($r.Code -eq 2) ('Code '+$r.Code+' : '+$r.Output);Assert ($r.Output -match 'Installation annul') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  Assert (-not (Test-Path (Join-Path $f.Target 'wad\maintenance\backups'))) 'Sauvegarde creee sans reponse.'
 }
 Case 'UX-29 reponse reelle de l operateur : N refuse (code 2), O installe par l entree DEV' {
  $f=New-Fixture
  $r=Install $f -Arguments '-Destination (Join-Path $PSScriptRoot ''active'')' -Answers @('N')
  Assert ($r.Code -eq 2) ('Code '+$r.Code+' : '+$r.Output);Assert ($r.Output -match 'Installation annul') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
  $r=Install $f -Relay -Arguments '-Destination (Join-Path $PSScriptRoot ''active'')' -Answers @('O')
  Assert ($r.Code -eq 0) ('Code '+$r.Code+' : '+$r.Output);Assert ($r.Output -match 'Version avant') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq (Hash (Join-Path $dev 'wad\Domenia-Core.ps1')))
 }
 Case 'UX-29 cinq sauvegardes completes gardees, preparation abandonnee retiree, RestoreLatest' {
  $f=New-Fixture;$parent=Join-Path $f.Target 'wad\maintenance\backups'
  for($i=1;$i -le 6;$i++){Save (Join-Path $parent ('2020010'+$i+'-000000-0000000'+$i+'\transaction.json')) ('{"Format":1,"Build":"old-'+$i+'","Status":"Installed","Destination":"'+$f.Target.Replace('\','\\')+'","Files":[]}')}
  Save (Join-Path $parent '20200107-000000-00000007\transaction.json') ('{"Format":1,"Build":"old-7","Status":"Prepared","Destination":"'+$f.Target.Replace('\','\\')+'","Files":[]}')
  Save (Join-Path $parent '20200108-000000-00000008\prepared\wad\x.txt') 'abandoned'
  # Backups of an earlier installer kept their prepared copy: removed from kept complete backups, never from an
  # unfinished journal.
  foreach($old in @('20200106-000000-00000006','20200107-000000-00000007')){Save (Join-Path $parent ($old+'\prepared\wad\Domenia-Core.ps1')) 'old prepared copy'}
  $r=Install $f;Assert ($r.Code -eq 0) $r.Output
  Assert (-not (Test-Path (Join-Path $parent '20200106-000000-00000006\prepared'))) 'Copie prepared conservee dans une sauvegarde complete.'
  Assert (Test-Path (Join-Path $parent '20200106-000000-00000006\transaction.json')) 'Journal de sauvegarde retire.'
  Assert (Test-Path (Join-Path $parent '20200107-000000-00000007\prepared')) 'Copie prepared retiree d un journal inacheve.'
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
  # Relative destination: resolved from the PowerShell location (Set-Location), not from the process directory.
  $r=Install $f -Prelude 'Set-Location -LiteralPath $PSScriptRoot' -Arguments '-Install -Destination fresh -Confirm:$false'
  Assert ($r.Code -eq 0) $r.Output
  foreach($entry in $manifest.Files){Assert ((Hash (Join-Path $fresh $entry.Path)) -eq $entry.Sha256) ('Empreinte differente : '+$entry.Path)}
  Assert ((Hash (Join-Path $fresh 'wad\package-manifest.json')) -eq (Hash (Join-Path $dev 'tools\prod-manifest.json')))
  # Child output is read back in the console code page: the checks avoid accented characters.
  Assert (@([regex]::Matches($r.Output,'question non pos')).Count -eq 2) $r.Output
  Assert ((Start-Check $f $fresh).Code -eq 0)
  $r=Install $f -Arguments ('-Install -Destination '''+$fresh+''' -Confirm:$false')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'pas vide') $r.Output
  $r=Install $f -Arguments ('-Install -Destination '''+(Join-Path $f.Dir 'fresh-non')+''' -Confirm:$false -Shortcuts Non')
  Assert (($r.Code -eq 0) -and (@([regex]::Matches($r.Output,'non cr\S*\.')).Count -eq 2)) $r.Output
 }
 Case 'FO-20 reponses reelles : installation O, raccourci Bureau O cree par COM, menu Demarrer N' {
  # The shortcut is really created in the Desktop of the test account, then removed; an existing Domenia.lnk is kept.
  $f=New-Fixture -Prod;$fresh=Join-Path $f.Dir 'fresh-ui'
  $desktop=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Domenia.lnk';$programs=Join-Path ([Environment]::GetFolderPath('Programs')) 'Domenia.lnk'
  $hadDesktop=[IO.File]::Exists($desktop);$hadPrograms=[IO.File]::Exists($programs)
  try{
   $r=Install $f -Arguments ('-Install -Destination '''+$fresh+'''') -Answers @('O','O','N')
   Assert ($r.Code -eq 0) ('Code '+$r.Code+' : '+$r.Output)
   if($hadDesktop){Assert ($r.Output -match 'Un raccourci Domenia existe') $r.Output}
   else{
    Assert ([IO.File]::Exists($desktop)) ('Raccourci Bureau absent : '+$r.Output)
    $shell=New-Object -ComObject WScript.Shell
    # The shell stores long paths while TEMP may be a short (8.3) path: compare the unique tail of the fixture path.
    $tail='\'+(Split-Path $f.Dir -Leaf)+'\fresh-ui'
    try{$link=$shell.CreateShortcut($desktop);Assert ($link.TargetPath -like ('*'+$tail+'\Domenia.exe')) ('Cible : '+$link.TargetPath);Assert ($link.WorkingDirectory -like ('*'+$tail)) $link.WorkingDirectory;Assert ([IO.File]::Exists($link.TargetPath)) 'Cible absente.'}
    finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
   }
   Assert ($r.Output -match 'menu D\S+ non cr\S*\.') $r.Output
   Assert ([IO.File]::Exists($programs) -eq $hadPrograms) 'Raccourci du menu Demarrer cree malgre la reponse N.'
  }finally{
   foreach($pair in @(@($desktop,$hadDesktop),@($programs,$hadPrograms))){
    if((-not $pair[1]) -and [IO.File]::Exists($pair[0])){[IO.File]::Delete($pair[0])}
   }
  }
 }
 Case 'FI-06 controles hors ligne du rapport : memes regles que release_guard.require_evidence' {
  . ([scriptblock]::Create((Get-InstallerFunctionText 'Get-CodeHash','Get-QualificationState')))
  $qualificationScenarios=$script:RequiredScenarios
  $f=New-Fixture -Prod
  $good=New-QualifiedPackage $f
  $state=Get-QualificationState $good.Report $good.Zip $manifest
  Assert $state.Bound $state.Reason;Assert ($state.Edition -eq 'prod') $state.Edition
  $zipSha=(Hash $good.Zip).ToLowerInvariant();$devSha=('d'*64)
  $both={param($r) $r.PSObject.Properties.Remove('ArchiveSHA256');$r|Add-Member -NotePropertyName Archives -NotePropertyValue @([pscustomobject]@{Edition='dev';SHA256=$devSha},[pscustomobject]@{Edition='prod';SHA256=$zipSha});foreach($x in $r.Scenarios){$x|Add-Member -NotePropertyName ArchiveSHA256 -NotePropertyValue $zipSha}}
  $paired=New-QualifiedPackage $f -Edit $both
  $state=Get-QualificationState $paired.Report $paired.Zip $manifest;Assert $state.Bound ('DEV et PROD : '+$state.Reason)
  $cases=[ordered]@{
   'campagne en echec'=@({param($r) $r.OverallStatus='FAIL'},'chec')
   'autre Build'=@({param($r) $r.Build='2020.01.01-AUTRE'},'Build du rapport')
   'scenario manquant'=@({param($r) $r.Scenarios=@($r.Scenarios|Where-Object{$_.Id -ne 'race.selection'})},'race\.selection')
   'scenario en echec'=@({param($r) @($r.Scenarios|Where-Object{$_.Id -eq 'data.sqlite'})[0].Status='FAIL'},'data\.sqlite')
   'hote non 5.1'=@({param($r) $r.Host.PSVersion='7.4.6';$r.Host.PSEdition='Core'},'5\.1')
   'rapport de test'=@({param($r) $r|Add-Member -NotePropertyName FixtureOnly -NotePropertyValue $true},'FixtureOnly')
   'horodatage incoherent'=@({param($r) @($r.Scenarios|Where-Object{$_.Id -eq 'parser.ps51'})[0].EndedUtc='2026-10-08T09:00:00Z'},'incoh')
   'horodatage absent'=@({param($r) @($r.Scenarios|Where-Object{$_.Id -eq 'parser.ps51'})[0].StartedUtc=''},'horodatage')
   'preuve sans empreinte'=@({param($r) @($r.Scenarios|Where-Object{$_.Id -eq 'worker.contracts'})[0].EvidenceSHA256=''},'empreinte de preuve')
   'scenario lie a une autre archive'=@({param($r) @($r.Scenarios|Where-Object{$_.Id -eq 'ui.actual_events'})[0]|Add-Member -NotePropertyName ArchiveSHA256 -NotePropertyValue ('e'*64)},'autre archive')
   'archive PROD seule'=@({param($r) $r.PSObject.Properties.Remove('ArchiveSHA256');$r|Add-Member -NotePropertyName Archives -NotePropertyValue @([pscustomobject]@{Edition='prod';SHA256=$zipSha})},'DEV et PROD')
   'prod.standalone sur l archive DEV'=@({param($r) & $both $r;@($r.Scenarios|Where-Object{$_.Id -eq 'prod.standalone'})[0].ArchiveSHA256=$devSha},'prod\.standalone')
   'archive modifiee pendant la campagne'=@({param($r) & $both $r;@($r.Archives|Where-Object{$_.Edition -eq 'prod'})[0]|Add-Member -NotePropertyName SHA256End -NotePropertyValue ('f'*64)},'modifi')
  }
  foreach($name in @($cases.Keys)){
   $bad=New-QualifiedPackage $f -Edit $cases[$name][0]
   $state=Get-QualificationState $bad.Report $bad.Zip $manifest
   Assert (-not $state.Bound) ('Accepte a tort : '+$name);Assert ($state.Reason -match $cases[$name][1]) ($name+' : '+$state.Reason)
  }
  $thin=New-QualifiedPackage $f -ManifestOnly
  $state=Get-QualificationState $thin.Report $thin.Zip $manifest
  Assert ((-not $state.Bound) -and ($state.Reason -match 'absent du ZIP')) ('ZIP reduit au manifeste : '+$state.Reason)
  $other=$manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json;($other.Files|Where-Object Path -eq 'wad/Domenia-Core.ps1').Sha256=('A'*64)
  $state=Get-QualificationState $good.Report $good.Zip $other
  Assert ((-not $state.Bound) -and ($state.Reason -match 'différent du ZIP qualifié')) ('Paquet different du ZIP qualifie : '+$state.Reason)
  $state=Get-QualificationState $good.Report '' $manifest
  Assert ((-not $state.Bound) -and $state.Provided) 'Rapport sans ZIP accepte.'
 }
 Case 'FI-14 plafond du runtime lu dans wad/Domenia.release.json' {
  $f=New-Fixture
  Set-ReleaseLimit $f 50;$r=Start-Check $f
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'plafond de 50') $r.Output
  Set-ReleaseLimit $f 250;$r=Start-Check $f
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'plafond 250') $r.Output
 }

 # ---------------------------------------------------------------- point 143 : schema de donnees et retour arriere
 Case 'P143 migration du schema annoncee avant la reponse, consignee au journal et rappelee au retour arriere' {
  $f=New-Fixture;Set-ReleaseSchema $f 10
  $r=Install $f -Arguments '-Destination (Join-Path $PSScriptRoot ''active'') -WhatIf'
  Assert ($r.Code -eq 0) $r.Output
  # Child output is read back in the console code page: the patterns avoid accented characters.
  Assert ($r.Output -match ('migration du sch\S+ 10 vers '+$script:Schema)) $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash) 'WhatIf a modifie le code.'
  $r=Install $f;Assert ($r.Code -eq 0) $r.Output
  Assert ($r.Output -match 'Avant un retour arri') $r.Output
  $journal=[IO.File]::ReadAllText((Join-Path (Backup $f) 'transaction.json'))|ConvertFrom-Json
  Assert (([int]$journal.DataSchema.Before -eq 10) -and ([int]$journal.DataSchema.After -eq $script:Schema) -and ([string]$journal.DataSchema.Direction -eq 'Migration')) ($journal.DataSchema|ConvertTo-Json -Compress)
  Assert ([string]$journal.RestoreNotice -match 'refusera une base migrée') ([string]$journal.RestoreNotice)
  $r=Restore $f (Backup $f);Assert ($r.Code -eq 0) $r.Output
  Assert ($r.Output -match 'refusera une base migr') $r.Output
  Assert ((Hash (Join-Path $f.Target 'wad\Domenia-Core.ps1')) -eq $f.OldHash)
 }
 Case 'P143 meme schema : aucune migration annoncee ni avertissement de retour arriere' {
  $f=New-Fixture;$r=Install $f;Assert ($r.Code -eq 0) $r.Output
  Assert ($r.Output -match ('donn\S+ \('+$script:Schema+'\) ; aucune migration')) $r.Output
  Assert ($r.Output -notmatch 'Avant un retour arri') $r.Output
  $journal=[IO.File]::ReadAllText((Join-Path (Backup $f) 'transaction.json'))|ConvertFrom-Json
  Assert ([string]$journal.DataSchema.Direction -eq 'Identique') ([string]$journal.DataSchema.Direction)
 }
 # ---------------------------------------------------------------- point 144 : desinstallation
 Case 'P144 desinstallation sans reponse : rien nʼest supprime, code 2' {
  $u=New-InstalledCopy 'fresh-noanswer'
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+'''')
  Assert ($r.Code -eq 2) ('Code '+$r.Code+' : '+$r.Output);Assert ($r.Output -match 'annul') $r.Output
  foreach($entry in $manifest.Files){Assert ([IO.File]::Exists((Join-Path $u.Path $entry.Path))) ('Fichier retire sans reponse : '+$entry.Path)}
 }
 Case 'P144 -Confirm:$false : code, manifeste et verrou retires ; donnees du dossier conservees sans choix explicite' {
  $u=New-InstalledCopy 'fresh-keep'
  Save (Join-Path $u.Path 'wad\data\preserve-me.txt') 'test-data'
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -ProfileData Conserver -Confirm:$false')
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'question non pos') $r.Output
  foreach($rel in @('Domenia.exe','wad\Domenia-Core.ps1','wad\modules\Domenia-Common.Model.ps1','wad\package-manifest.json','wad\Support\.lifecycle.lock','wad\Support\INSTALLER-MISE-A-JOUR.ps1')){Assert (-not [IO.File]::Exists((Join-Path $u.Path $rel))) ('Code conserve : '+$rel)}
  Assert ([IO.File]::ReadAllText((Join-Path $u.Path 'wad\data\preserve-me.txt')) -eq 'test-data') 'Donnees supprimees sans choix.'
  Assert ([IO.File]::Exists((Join-Path $u.Path 'wad\Domenia.config.json'))) 'Preferences supprimees sans choix.'
 }
 Case 'P144 choix explicite -LocalData Supprimer : le dossier installe disparait entierement' {
  $u=New-InstalledCopy 'fresh-remove'
  Save (Join-Path $u.Path 'wad\data\a\b.txt') 'test-data';Save (Join-Path $u.Path 'wad\maintenance\backups\20200101-000000-00000001\transaction.json') '{}'
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -LocalData Supprimer -ProfileData Conserver -Confirm:$false')
  Assert ($r.Code -eq 0) $r.Output
  Assert (-not (Test-Path -LiteralPath $u.Path)) ('Dossier restant : '+(@(Get-ChildItem -LiteralPath $u.Path -Recurse -Force|ForEach-Object FullName) -join ', '))
 }
 Case 'P144 choix saisis en minuscules : -LocalData supprimer supprime, -LocalData demander conserve sans question' {
  $u=New-InstalledCopy 'fresh-lowercase'
  Save (Join-Path $u.Path 'wad\data\a\b.txt') 'test-data'
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -LocalData supprimer -ProfileData conserver -Confirm:$false')
  Assert ($r.Code -eq 0) $r.Output
  Assert (-not (Test-Path -LiteralPath $u.Path)) ('Donnees conservees malgre -LocalData supprimer : '+(@(Get-ChildItem -LiteralPath $u.Path -Recurse -Force|ForEach-Object FullName) -join ', '))
  $k=New-InstalledCopy 'fresh-lowercase-ask'
  Save (Join-Path $k.Path 'wad\data\keep.txt') 'test-data'
  $r=Install $k.Fixture -Arguments ('-Uninstall -Destination '''+$k.Path+''' -LocalData demander -ProfileData conserver -Confirm:$false')
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'question non pos') $r.Output
  Assert ([IO.File]::Exists((Join-Path $k.Path 'wad\data\keep.txt'))) 'Donnees supprimees sans choix explicite.'
 }
 Case 'P144 recus a verifier : suppression des donnees du profil refusee avant toute suppression' {
  # The real profile is never deleted by this suite (KI-005): the receipt rule of the installer runs on a fixture
  # folder, and its place in the uninstall is checked on the installer text.
  . ([scriptblock]::Create((Get-InstallerFunctionText 'Get-OpenReceipts')))
  $folder=Join-Path $root ('receipts-'+[guid]::NewGuid().ToString('N'))
  Save (Join-Path $folder (('a'*32)+'.json')) '{"Format":1,"Stage":"Verified"}'
  Save (Join-Path $folder (('b'*32)+'.json')) '{"Format":1,"Stage":"Sent"}'
  Save (Join-Path $folder (('c'*32)+'.json')) '{illisible'
  Save (Join-Path $folder ('archive\'+('d'*32)+'.json')) '{"Format":1,"Stage":"Delivered"}'
  Save (Join-Path $folder 'writer.lock') ''
  $state=Get-OpenReceipts $folder
  Assert ($state.Count -eq 4) ('Recus comptes : '+$state.Count)
  $names=[string]::Join(',',[string[]]@(@($state.Open)|Sort-Object))
  Assert ($names -ceq ((('b'*32)+'.json')+','+(('c'*32)+'.json'))) ('Recus a verifier : '+$names)
  Assert ((Get-OpenReceipts $null).Count -eq 0) 'Dossier absent : aucun recu attendu.'
  $text=Get-InstallerFunctionText 'Invoke-DomeniaUninstall'
  $check=$text.IndexOf('$receipts=Get-OpenReceipts',$text.IndexOf('Assert-NoDomeniaRunning'))
  $firstDelete=$text.IndexOf('::Delete(')
  Assert (($check -gt 0) -and ($firstDelete -gt 0) -and ($check -lt $firstDelete)) 'Recus non relus avant la premiere suppression.'
  Assert ($text -like '*Une écriture AD a pu partir sans vérification*Rien nʼest supprimé.*') 'Refus sans motif ni mention de lʼabsence de suppression.'
 }
 Case 'P144 fichier de code modifie conserve et nomme, jonction dans les donnees refusee avant toute suppression' {
  $u=New-InstalledCopy 'fresh-changed'
  [IO.File]::AppendAllText((Join-Path $u.Path 'wad\modules\Domenia-Common.Model.ps1'),"`n# Local change`n",$utf8)
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -LocalData Supprimer -ProfileData Conserver -Confirm:$false')
  Assert ($r.Code -eq 0) $r.Output;Assert ($r.Output -match 'Domenia-Common\.Model\.ps1') $r.Output
  Assert ([IO.File]::Exists((Join-Path $u.Path 'wad\modules\Domenia-Common.Model.ps1'))) 'Fichier modifie supprime.'
  Assert (-not [IO.File]::Exists((Join-Path $u.Path 'Domenia.exe'))) 'Code intact conserve.'
  $j=New-InstalledCopy 'fresh-junction'
  $outside=Join-Path $j.Fixture.Dir 'outside';Save (Join-Path $outside 'precious.txt') 'outside-data'
  [void][IO.Directory]::CreateDirectory((Join-Path $j.Path 'wad\data'))
  cmd /c mklink /J (Join-Path $j.Path 'wad\data\link') $outside | Out-Null
  $r=Install $j.Fixture -Arguments ('-Uninstall -Destination '''+$j.Path+''' -LocalData Supprimer -ProfileData Conserver -Confirm:$false')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'jonction') $r.Output
  Assert ([IO.File]::ReadAllText((Join-Path $outside 'precious.txt')) -eq 'outside-data') 'Cible de la jonction touchee.'
  Assert ([IO.File]::Exists((Join-Path $j.Path 'Domenia.exe'))) 'Code supprime malgre le refus.'
  [IO.Directory]::Delete((Join-Path $j.Path 'wad\data\link'))
 }
 Case 'P144 copie DEV et mise a jour inachevee refusees : rien nʼest supprime' {
  $u=New-InstalledCopy 'fresh-refused'
  [void][IO.Directory]::CreateDirectory((Join-Path $u.Path 'tools'))
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -Confirm:$false')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'Copie DEV') $r.Output
  [IO.Directory]::Delete((Join-Path $u.Path 'tools'))
  Save (Join-Path $u.Path 'wad\Support\.update.pending') '{"Backup":"x","Status":"Installing"}'
  $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -Confirm:$false')
  Assert ($r.Code -ne 0) $r.Output;Assert ($r.Output -match 'inachev') $r.Output
  foreach($entry in $manifest.Files){Assert ([IO.File]::Exists((Join-Path $u.Path $entry.Path))) ('Fichier retire malgre le refus : '+$entry.Path)}
 }
 Case 'P144 reponses reelles : O desinstalle, N conserve les donnees, raccourcis de cette copie retires' {
  $desktop=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Domenia.lnk';$programs=Join-Path ([Environment]::GetFolderPath('Programs')) 'Domenia.lnk'
  $hadDesktop=[IO.File]::Exists($desktop);$hadPrograms=[IO.File]::Exists($programs)
  $u=New-InstalledCopy 'fresh-links' 'Oui'
  try{
   Save (Join-Path $u.Path 'wad\data\keep.txt') 'test-data'
   $r=Install $u.Fixture -Arguments ('-Uninstall -Destination '''+$u.Path+''' -ProfileData Conserver') -Answers @('O','N')
   Assert ($r.Code -eq 0) ('Code '+$r.Code+' : '+$r.Output)
   Assert ([IO.File]::Exists($desktop) -eq $hadDesktop) 'Raccourci Bureau : etat inattendu apres desinstallation.'
   Assert ([IO.File]::Exists($programs) -eq $hadPrograms) 'Raccourci Demarrer : etat inattendu apres desinstallation.'
   Assert ([IO.File]::Exists((Join-Path $u.Path 'wad\data\keep.txt'))) 'Donnees supprimees malgre la reponse N.'
   Assert (-not [IO.File]::Exists((Join-Path $u.Path 'Domenia.exe'))) 'Code conserve malgre la reponse O.'
  }finally{
   foreach($pair in @(@($desktop,$hadDesktop),@($programs,$hadPrograms))){if((-not $pair[1]) -and [IO.File]::Exists($pair[0])){[IO.File]::Delete($pair[0])}}
  }
 }
 Case 'P144 droits standards : aucun recours a lʼelevation dans lʼinstallateur' {
  $source=[IO.File]::ReadAllText($script:InstallerPath)
  Assert ($source -notmatch '(?i)#requires\s+-RunAsAdministrator') 'Elevation exigee.'
  Assert ($source -notmatch '(?i)-Verb\s+RunAs') 'Elevation demandee.'
  # The other cases install and uninstall under %TEMP% with the session account; the report says whether that account
  # was elevated, so a run as administrator is never presented as a standard-user proof.
  Assert ($null -ne $script:ElevatedSession) 'Elevation de la session non relevee.'
 }
}finally{
 # All processes are bounded; the temporary fixtures contain no real installation or AD data.
 Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
$passed=@($checks|Where-Object Status -eq 'Passed').Count;$failed=@($checks|Where-Object Status -eq 'Failed').Count
$expected=if($RestoreOnly){2}else{26}
# ElevatedSession: install and uninstall ran with this account; true means they do not prove standard-user rights.
$report=[ordered]@{Suite='Test-DomeniaInstaller';Passed=$passed;Failed=$failed;Skipped=0;Expected=$expected;Complete=($checks.Count -eq $expected);NativeWindowsPowerShell51=$true;PSVersion=$PSVersionTable.PSVersion.ToString();ElevatedSession=[bool]$script:ElevatedSession;ProfileDataDeletionExecuted=$false;Checks=$checks.ToArray()}
if($ReportPath){Save $ReportPath ($report|ConvertTo-Json -Depth 7)}
Write-Host ('Installer : '+$passed+' reussis, '+$failed+' echecs')
if($failed -gt 0 -or $checks.Count -ne $expected){exit 1};exit 0
