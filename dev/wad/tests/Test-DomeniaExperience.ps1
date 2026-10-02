#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Check-Suite {param([string]$Name,[scriptblock]$Code)
    try{if(-not (& $Code)){throw 'Condition non verifiee.'};$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
# Dot-sourcing definitions in script scope avoids executing application startup.
foreach($source in @(
    @{File=(Join-Path $wad 'Domenia-Core.ps1');Names=@('Get-DomeniaDefaultSettings','Load-DomeniaSettings','Save-DomeniaSettings','Get-DomeniaBootThemePalette')},
    @{File=(Join-Path $wad 'modules\Domenia-Experience.UI.ps1');Names=@('Get-DomeniaExperienceExportRows','Stop-DomeniaExperienceSelectedRead')}
)){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source.File,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw $errors[0].Message}
    foreach($name in $source.Names){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($nodes.Count -ne 1){throw ('Definition absente : '+$name)}
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
}
function Write-AppLog {param($Text,$Level)}
function Read-DomeniaPreference {param($FileName) if($FileName -eq 'Domenia.settings.json'){return $script:FixtureJson};if($FileName -eq 'Domenia.ui-profile.cfg'){return $script:FixtureLegacy};return ''}
function Get-DomeniaStoredTheme {return 'Light'}
function Write-DomeniaPreference {param($FileName,$Value) return $script:Writable}
$script:SettingsTimer=$null
Check-Suite 'Parseur natif : tous les scripts du pack' {
    foreach($file in Get-ChildItem -LiteralPath (Split-Path -Parent $wad) -Filter '*.ps1' -Recurse -File){
        $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e)
        if(@($e).Count){throw ($file.Name+': '+$e[0].Message)}
    };$true
}
Check-Suite 'false textuel reste faux' {-not (ConvertTo-SuiteFlag 'false')}
Check-Suite 'Bool invalide utilise le defaut' {ConvertTo-SuiteFlag 'oops' -Default $true}
Check-Suite 'NaN refuse' {(ConvertTo-SuiteNumber 'NaN' -Default 12) -eq 12}
Check-Suite 'Infini refuse' {(ConvertTo-SuiteNumber 'Infinity' -Default 12) -eq 12}
Check-Suite 'Nombre borne' {(ConvertTo-SuiteNumber 9999 -Minimum 10 -Maximum 18) -eq 18}
Check-Suite 'Nombre negatif borne' {(ConvertTo-SuiteNumber -9 -Minimum 1 -Maximum 500) -eq 1}
Check-Suite 'Expert JSON prime sur ancien Tech' {
    $script:FixtureJson='{"UiProfile":"Admin"}';$script:FixtureLegacy='Tech'
    (Load-DomeniaSettings).UiProfile -eq 'Admin'
}
Check-Suite 'Essentiel JSON prime sur ancien Admin' {
    $script:FixtureJson='{"UiProfile":"Tech"}';$script:FixtureLegacy='Admin'
    (Load-DomeniaSettings).UiProfile -eq 'Tech'
}
Check-Suite 'Migration du profil absent' {
    $script:FixtureJson='{}';$script:FixtureLegacy='Admin'
    (Load-DomeniaSettings).UiProfile -eq 'Admin'
}
Check-Suite 'Profil invalide revient au defaut' {
    $script:FixtureJson='{"UiProfile":"bad"}';$script:FixtureLegacy='bad'
    (Load-DomeniaSettings).UiProfile -eq 'Tech'
}
Check-Suite 'Preferences nouvelles rechargees' {
    $script:FixtureJson='{"UxLogWrap":true,"UxLogCollapsed":true,"UxLogFontSize":14,"UxDensity":"Compact"}';$script:FixtureLegacy=''
    $v=Load-DomeniaSettings;$v.UxLogWrap -and $v.UxLogCollapsed -and $v.UxLogFontSize -eq 14 -and $v.UxDensity -eq 'Compact'
}
Check-Suite 'Configuration arbitraire et secret non importes' {
    $v=ConvertTo-DomeniaExperienceSettings @{Password='SENTINEL';Anything='bad'} (Get-DomeniaDefaultSettings)
    -not $v.Contains('Password') -and -not $v.Contains('Anything')
}
Check-Suite 'Enregistrement refuse remonte explicitement' {
    $script:Writable=$false
    try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{return $true};$false
}
Check-Suite 'Enregistrement accepte ne leve pas erreur' {$script:Writable=$true;Save-DomeniaSettings -Immediate -ThrowOnFailure;$true}
Check-Suite 'Palette claire et sombre chargees' {(Get-SuitePalette Light).BgCard -eq '#FFFFFF' -and (Get-SuitePalette Dark).BgCard -eq '#182538'}
Check-Suite 'Login et principale partagent le bleu' {(Get-DomeniaBootThemePalette Dark).Accent -ceq (Get-SuitePalette Dark).AccentColor}
Check-Suite 'Login et principale partagent le fond' {(Get-DomeniaBootThemePalette Light).Window -ceq (Get-SuitePalette Light).WindowBg}
$row=[pscustomobject]@{Type='Machine';Name='PC-PARIS-01';Login='Paris';UPN='pc-paris-01.example.invalid';Association='Alex Martin';Presence='En ligne';Password='HIDDEN_SENTINEL'}
Check-Suite 'Filtre insensible a la casse' {Test-DomeniaExperienceRow $row 'paris'}
Check-Suite 'Filtre plusieurs mots combine les colonnes' {Test-DomeniaExperienceRow $row 'machine martin'}
Check-Suite 'Filtre ne cherche pas dans les secrets' {-not (Test-DomeniaExperienceRow $row 'HIDDEN_SENTINEL')}
Check-Suite 'Filtre ne traite pas etoile comme joker' {-not (Test-DomeniaExperienceRow $row '*')}
Check-Suite 'Filtre ne traite pas crochet comme regex' {-not (Test-DomeniaExperienceRow $row '[Paris]')}
Check-Suite 'Filtre vide affiche la ligne' {Test-DomeniaExperienceRow $row ''}
Check-Suite 'Ligne nulle exclue' {-not (Test-DomeniaExperienceRow $null '')}
$a=[pscustomobject]@{Name='A'};$b=[pscustomobject]@{Name='B'};$hidden=[pscustomobject]@{Name='Hidden'}
Check-Suite 'Export sans selection prend seulement les lignes visibles' {$v=@(Get-DomeniaExperienceExportRows @($a,$b) @());$v.Count -eq 2 -and $v[0].Name -eq 'A'}
Check-Suite 'Export selection preserve ordre de la grille' {$v=@(Get-DomeniaExperienceExportRows @($a,$b) @($b,$a));$v.Count -eq 2 -and $v[0].Name -eq 'A'}
Check-Suite 'Selection obsolete ne fuit pas dans export' {@(Get-DomeniaExperienceExportRows @($a,$b) @($hidden)).Count -eq 0}
Check-Suite 'Grille vide exporte zero ligne' {@(Get-DomeniaExperienceExportRows @() @($a)).Count -eq 0}
function New-JobFixture {
    [pscustomobject]@{Id='job1';Name='Lecture exemple';OperationId='ExampleRead';IsWrite=$false;NonCancellable=$false;CancelRequested=$false;SessionEpoch=3;Started=[datetime]'2026-09-30T10:00:00';TimeoutNotified=$false;TimeoutErrorDelivered=$false;CallbackState=[pscustomobject]@{Password='SECRET_CALLBACK'}}
}
Check-Suite 'Lecture courante annulable' {Test-DomeniaExperienceCanCancel (New-JobFixture) 3}
Check-Suite 'Autre session non annulable' {-not (Test-DomeniaExperienceCanCancel (New-JobFixture) 4)}
Check-Suite 'Mutation refusee meme si NonCancellable faux' {$j=New-JobFixture;$j.IsWrite=$true;-not (Test-DomeniaExperienceCanCancel $j 3)}
Check-Suite 'Lecture protegee refusee' {$j=New-JobFixture;$j.NonCancellable=$true;-not (Test-DomeniaExperienceCanCancel $j 3)}
Check-Suite 'Annulation repetee refusee' {$j=New-JobFixture;$j.CancelRequested=$true;-not (Test-DomeniaExperienceCanCancel $j 3)}
Check-Suite 'Metadonnees manquantes refus par defaut' {-not (Test-DomeniaExperienceCanCancel ([pscustomobject]@{Id='unsafe'}) 3)}
Check-Suite 'Faux booleen textuel refuse' {$j=New-JobFixture;$j.IsWrite='false';-not (Test-DomeniaExperienceCanCancel $j 3)}
Check-Suite 'Projection contient duree exacte' {(Get-DomeniaExperienceTaskRow (New-JobFixture) -Now ([datetime]'2026-09-30T10:01:15')).Duration -eq '01:15'}
Check-Suite 'Projection ne recopie pas callback ni secret' {$v=Get-DomeniaExperienceTaskRow (New-JobFixture);-not ($v|ConvertTo-Json).Contains('SECRET_CALLBACK') -and $null -eq $v.PSObject.Properties['CallbackState']}
Check-Suite 'Detach reste nettoyage et non annulable' {$v=Get-DomeniaExperienceTaskRow (New-JobFixture) -Detached -SessionEpoch 3;$v.State -eq 'Nettoyage' -and -not $v.CanCancel}
Check-Suite 'Mutation interrompue reste a verifier' {$j=New-JobFixture;$j.IsWrite=$true;$j.CancelRequested=$true;(Get-DomeniaExperienceTaskRow $j).State -eq 'À vérifier'}
Check-Suite 'Lecture stoppee reste arret demande' {$j=New-JobFixture;$j.CancelRequested=$true;(Get-DomeniaExperienceTaskRow $j).State -eq 'Arrêt demandé'}
Check-Suite 'Recherche journal trouve une occurrence' {(Find-SuiteLiteralText 'alpha BETA gamma' 'beta' 0) -eq 6}
Check-Suite 'Recherche journal reboucle' {(Find-SuiteLiteralText 'alpha beta' 'alpha' 9) -eq 0}
Check-Suite 'Recherche journal borne indice negatif' {(Find-SuiteLiteralText 'abc' 'a' -100) -eq 0}
Check-Suite 'Recherche journal sans resultat retourne -1' {(Find-SuiteLiteralText 'abc' 'x') -eq -1}
Check-Suite 'Recherche journal vide ne selectionne rien' {(Find-SuiteLiteralText 'abc' '') -eq -1}
# Exercise the real cancellation adapter with fake controls/jobs. No worker is launched.
function Get-DomeniaControl {param($Name) if($Name -eq 'DgSuiteActivity'){return $script:GridFixture};return $null}
function Request-UiTaskStop {param($Id,$Reason) $script:StopCalls++;$script:StoppedId=$Id}
function Update-DomeniaExperienceActivity {param([switch]$Force)}
Check-Suite 'Bouton arret recontrole la vraie mutation' {
    $j=New-JobFixture;$j.IsWrite=$true;$script:AsyncJobs=@{job1=$j};$script:SessionEpoch=3;$script:StopCalls=0
    $script:GridFixture=[pscustomobject]@{SelectedItem=[pscustomobject]@{Id='job1';Detached=$false;CanCancel=$true}}
    Stop-DomeniaExperienceSelectedRead;$script:StopCalls -eq 0
}
Check-Suite 'Bouton arret demande une seule lecture par clic' {
    $script:AsyncJobs=@{job1=(New-JobFixture)};$script:StopCalls=0
    Stop-DomeniaExperienceSelectedRead;$script:StopCalls -eq 1 -and $script:StoppedId -eq 'job1'
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Build='2026.09.30-R1.11-SUITE';Runtime=$PSVersionTable.PSVersion.ToString();Executed=(Get-Date).ToString('o');Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;WpfExecuted=$false;NoADAccess=$true;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-suite-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($failed.Count){throw ('Tests Experience en echec : '+$failed.Count)}
