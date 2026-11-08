#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Check-Suite {param([string]$Name,[scriptblock]$Code)
    try{if(-not (& $Code)){throw 'Condition non verifiee.'};$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
# Dot-sourcing definitions in script scope avoids executing application startup.
foreach($source in @(
    @{File=(Join-Path $wad 'Domenia-Core.ps1');Names=@('Get-DomeniaDefaultSettings','Load-DomeniaSettings','Save-DomeniaSettings','Get-DomeniaBootThemePalette','Get-DomeniaSetting','Set-DomeniaSetting')},
    @{File=(Join-Path $wad 'modules\Domenia-ProbeDetails.UI.ps1');Names=@('Get-DomeniaBiosReferenceSettingKey','Get-DomeniaStoredBiosReferences')},
    @{File=(Join-Path $wad 'modules\Domenia-Readings.Model.ps1');Names=@('ConvertTo-DomeniaBiosReferenceBook','Get-DomeniaBiosReference','Set-DomeniaBiosReference')},
    @{File=(Join-Path $wad 'modules\Domenia-Experience.UI.ps1');Names=@('Get-DomeniaExperienceExportRows','Stop-DomeniaExperienceSelectedRead','ConvertTo-DomeniaExperienceLogEntry','ConvertTo-DomeniaMaskedLogText',
        'Add-DomeniaExperienceLogEntry','Update-DomeniaExperienceLogBadge')}
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
function Write-DomeniaPreference {param($FileName,$Value) if($script:Writable){$script:LastWrittenJson=[string]$Value};return $script:Writable}
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
Check-Suite 'Configuration de domaine : nom ferme, texte borne' {
    $hash='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    $upper='FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210'
    $v=ConvertTo-DomeniaExperienceSettings @{('Inventory.BiosReferences.'+$hash)='{"Version":1}';('Dashboard.HealthPolicies.'+$hash)=@('pas','du','texte');('Inventory.BiosReferences.'+$upper)='x';'Inventory.BiosReferences.court'='x'} (Get-DomeniaDefaultSettings)
    ($v[('Inventory.BiosReferences.'+$hash)] -ceq '{"Version":1}') -and (-not $v.Contains(('Dashboard.HealthPolicies.'+$hash))) -and (-not $v.Contains(('Inventory.BiosReferences.'+$upper))) -and (-not $v.Contains('Inventory.BiosReferences.court'))
}
# Point 85 (review): an approved BIOS reference, stored under its domain-scoped key, survives a save and a reload.
Check-Suite 'Reference BIOS approuvee conservee apres enregistrement et rechargement' {
    $script:FixtureJson='{}';$script:FixtureLegacy='';$script:Writable=$true;$script:LastWrittenJson=''
    $script:Conn=[pscustomobject]@{BaseDn='DC=contoso,DC=test'}
    [void](Load-DomeniaSettings)
    $key=Get-DomeniaBiosReferenceSettingKey ([string]$script:Conn.BaseDn)
    $book=Set-DomeniaBiosReference -Book (Get-DomeniaStoredBiosReferences) -Manufacturer 'Dell Inc.' -Model 'Latitude 7440' -Version '1.15.0' -NowUtc ([datetime]::UtcNow)
    $script:Settings[$key]=($book|ConvertTo-Json -Depth 5 -Compress)
    Save-DomeniaSettings -Immediate -ThrowOnFailure
    $script:Settings=$null;$script:FixtureJson=$script:LastWrittenJson
    [void](Load-DomeniaSettings)
    $reference=Get-DomeniaBiosReference (Get-DomeniaStoredBiosReferences) 'Dell Inc.' 'Latitude 7440'
    $kept=($null -ne $reference) -and ([string]$reference.Version -ceq '1.15.0')
    # The next unrelated save writes the approval again instead of dropping it.
    Save-DomeniaSettings -Immediate -ThrowOnFailure
    $kept -and ([string]$script:LastWrittenJson).Contains($key)
}
Check-Suite 'Enregistrement refuse remonte explicitement' {
    $script:Writable=$false
    try{Save-DomeniaSettings -Immediate -ThrowOnFailure}catch{return $true};$false
}
Check-Suite 'Enregistrement accepte ne leve pas erreur' {$script:Writable=$true;Save-DomeniaSettings -Immediate -ThrowOnFailure;$true}
Check-Suite 'Palette claire et sombre chargees' {(Get-SuitePalette Light).BgCard -eq '#FFFFFF' -and (Get-SuitePalette Dark).BgCard -eq '#1E2D44'}
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
# L02 (UX-02): a stale selection never reaches the file; with less than two selected visible rows the whole list goes.
Check-Suite 'Selection obsolete ne fuit pas dans export' {$v=@(Get-DomeniaExperienceExportRows @($a,$b) @($hidden,[pscustomobject]@{Name='Autre'}));($v.Count -eq 2) -and (@($v|Where-Object{[object]::ReferenceEquals($_,$hidden)}).Count -eq 0)}
Check-Suite 'Grille vide exporte zero ligne' {@(Get-DomeniaExperienceExportRows @() @($a)).Count -eq 0}
$c=[pscustomobject]@{Name='C'}
Check-Suite 'Un clic sur une ligne puis Exporter = toute la liste' {$v=@(Get-DomeniaExperienceExportRows @($a,$b,$c) @($b));($v.Count -eq 3) -and ($v[0].Name -eq 'A') -and ($v[2].Name -eq 'C')}
Check-Suite 'Deux lignes selectionnees : la selection seule' {$v=@(Get-DomeniaExperienceExportRows @($a,$b,$c) @($c,$a));($v.Count -eq 2) -and ($v[0].Name -eq 'A') -and ($v[1].Name -eq 'C')}
# L02 (UI-22): readable journal line and optional masking of the copied journal.
Check-Suite 'Journal lisible : heure HH:mm, icone et premiere ligne' {
    $e=ConvertTo-DomeniaExperienceLogEntry -Time ([datetime]'2026-10-08T14:32:51.123') -Level 'error' -Area 'Statut' -Text "Lecture impossible.`r`nSystem.Exception: detail"
    ($e.Time -eq '14:32') -and ($e.Level -eq 'ERROR') -and ($e.Icon -eq [string][char]0x2715) -and ($e.Text -eq 'Lecture impossible.')
}
Check-Suite 'Journal lisible : avertissement et information' {
    ((ConvertTo-DomeniaExperienceLogEntry -Time (Get-Date) -Level 'WARN' -Text 'a').Icon -eq [string][char]0x26A0) -and ((ConvertTo-DomeniaExperienceLogEntry -Time (Get-Date) -Level 'INFO' -Text 'b').Icon -eq [string][char]0x2713) -and ((ConvertTo-DomeniaExperienceLogEntry -Time (Get-Date) -Level 'DEBUG' -Text 'c').Level -eq 'INFO')
}
Check-Suite 'Journal lisible : phrase longue bornee' {(ConvertTo-DomeniaExperienceLogEntry -Time (Get-Date) -Text ('x'*400)).Text.Length -eq 280}
Check-Suite 'Copie masquee : chemins AD, comptes, DNS, adresses et noms connus' {
    $m=ConvertTo-DomeniaMaskedLogText -Text 'CN=PC-PARIS-01,OU=Postes,DC=cnamts,DC=local ; CNAMTS\alex.martin ; alex.martin@cnamts.local ; dc01.cnamts.local ; 10.77.0.20 ; PC-LYON-02 vu' -KnownNames @('PC-LYON-02')
    (-not ($m -match 'PARIS|alex|dc01|10\.77|LYON')) -and $m.Contains('[chemin AD]') -and $m.Contains('[compte]') -and $m.Contains('[adresse IP]') -and $m.Contains('[nom]')
}
Check-Suite 'Copie masquee : texte ordinaire conserve' {(ConvertTo-DomeniaMaskedLogText -Text 'Recherche terminee : 48 resultat(s) en 1.2 s.') -eq 'Recherche terminee : 48 resultat(s) en 1.2 s.'}
# L02 review: a local path, a version, a script name and a .NET type name stay readable for the support.
Check-Suite 'Copie masquee : chemins locaux, versions et noms .NET conserves' {
    $text='Journal : C:\Domenia\Logs\Domenia.log ; partage \\srv01\Domenia\Exports ; Domenia 1.0 RC1.13.0 ; System.Management.Automation.RuntimeException ; Domenia-Experience.UI.ps1'
    (ConvertTo-DomeniaMaskedLogText -Text $text) -ceq $text
}
Check-Suite 'Copie masquee : hote UNC et nom DNS en fin de phrase masques' {
    $m=ConvertTo-DomeniaMaskedLogText -Text 'Lecture de \\dc01.cnamts.local\SYSVOL puis de srv02.cnamts.local.'
    (-not ($m -match 'dc01|srv02')) -and $m.Contains('\\[nom]\SYSVOL') -and $m.EndsWith('[nom].')
}
# L02 review (UX-01): WARN and ERROR written only by Write-AppLog stay readable and keep the red pill; its INFO
# lines and the technical twins of a sentence already shown (area Technique) stay out of the readable view.
function Get-DomeniaControl {param($Name) if($Name -eq 'DgSuiteActivity'){return $script:GridFixture};return $null}
Check-Suite 'Journal lisible : WARN et ERROR de Write-AppLog visibles et comptes' {
    $script:Window=$null;$script:UiLogReadableItems=$null;$script:UiLogVisuallyCollapsed=$true;$script:UiLogUnreadErrors=0;$script:UiLogMaxLines=2500
    $t=Get-Date
    Add-DomeniaExperienceLogEntry -Time $t -Level 'INFO' -Area 'Journal' -Text 'Pret. Base=DC=example,DC=invalid'
    Add-DomeniaExperienceLogEntry -Time $t -Level 'ERROR' -Area 'Journal' -Text 'Clic Recherche : panne (test).'
    Add-DomeniaExperienceLogEntry -Time $t -Level 'WARN' -Area 'Journal' -Text 'Lecture des liens impossible (test).'
    Add-DomeniaExperienceLogEntry -Time $t -Level 'ERROR' -Area 'Technique' -Text '[INC-1A2B] Lecture [Unexpected] : System.Exception: detail'
    Add-DomeniaExperienceLogEntry -Time $t -Level 'ERROR' -Area 'Statut' -Text 'Lecture impossible (INC-1A2B).'
    $texts=@($script:UiLogReadableItems|ForEach-Object{[string]$_.Text})
    ($texts.Count -eq 3) -and ($texts[0] -ceq 'Clic Recherche : panne (test).') -and ($texts[1] -ceq 'Lecture des liens impossible (test).') -and ([int]$script:UiLogUnreadErrors -eq 2) -and (-not ($texts -join ' ').Contains('System.Exception'))
}
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
# UX-03: unwired if Load-DomeniaSettings restores a remembered presence filter again.
Check-Suite 'UX-03 : le filtre de presence repart sur Toute presence a chaque demarrage' {
    $script:FixtureJson='{"PresenceFilter":"En ligne","UiProfile":"Tech"}';$script:FixtureLegacy=''
    $script:CurrentPresenceFilter='En ligne'
    $v=Load-DomeniaSettings
    ($script:CurrentPresenceFilter -eq 'Tous') -and (-not $v.Contains('PresenceFilter')) -and (-not (Get-DomeniaDefaultSettings).Contains('PresenceFilter'))
}
Check-Suite 'UX-03 : un filtre qui masque toutes les lignes le dit et propose de l effacer' {
    $s=Get-DomeniaFilteredEmptyState -Loaded 48 -Visible 0 -LocalText 'compta' -Presence 'En ligne'
    $s.Show -and ($s.Text -eq 'Le filtre masque 48 lignes') -and $s.Detail.Contains('texte « compta »') -and $s.Detail.Contains('présence : En ligne') -and $s.Detail.Contains('sans requête AD')
}
Check-Suite 'UX-03 : une ligne, ou aucune ligne masquee, ou pas de filtre' {
    ((Get-DomeniaFilteredEmptyState -Loaded 1 -Visible 0 -LocalText 'x').Text -eq 'Le filtre masque 1 ligne') -and
    (-not (Get-DomeniaFilteredEmptyState -Loaded 48 -Visible 3 -LocalText 'x').Show) -and
    (-not (Get-DomeniaFilteredEmptyState -Loaded 0 -Visible 0 -LocalText 'x').Show) -and
    (-not (Get-DomeniaFilteredEmptyState -Loaded 48 -Visible 0 -LocalText '  ' -Presence 'Tous').Show) -and
    (-not (Get-DomeniaFilteredEmptyState -Loaded 48 -Visible 0 -Presence 'Toute présence').Show)
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Build='2026.09.30-R1.11-SUITE';Runtime=$PSVersionTable.PSVersion.ToString();Executed=(Get-Date).ToString('o');Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;WpfExecuted=$false;NoADAccess=$true;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-suite-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($failed.Count){throw ('Tests Experience en echec : '+$failed.Count)}
