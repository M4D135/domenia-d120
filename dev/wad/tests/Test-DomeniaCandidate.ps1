#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$Wpf)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Windows PowerShell 5.1 requis, pas pwsh.'}
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$wad=Join-Path $root 'wad';$core=Join-Path $wad 'Domenia-Core.ps1'
$script:CandidateResults=[Collections.Generic.List[object]]::new()
function Case {param([string]$CaseLabel,[scriptblock]$Body)
    try{$v=& $Body;if($null -ne $v -and -not [bool]$v){throw 'Assertion fausse.'};$script:CandidateResults.Add([pscustomobject]@{Name=$CaseLabel;Passed=$true;Error=''})}
    catch{$script:CandidateResults.Add([pscustomobject]@{Name=$CaseLabel;Passed=$false;Error=$_.Exception.Message})}
}
function Expect {param([bool]$Value,[string]$Message='Assertion fausse.');if(-not $Value){throw $Message}}
function ExpectThrow {param([scriptblock]$Code);$did=$false;try{& $Code|Out-Null}catch{$did=$true};Expect $did 'Une exception etait attendue.'}
$script:Parsed=@{}
$sourceFiles=@($core)+@(Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File|ForEach-Object{$_.FullName})+@(Join-Path $wad 'Domenia-Start.ps1')+@(Join-Path $wad 'Domenia-Modules.ps1')+@(Join-Path $root 'INSTALLER-MISE-A-JOUR.ps1')
foreach($path in $sourceFiles){
    Case ('Parseur natif : '+[IO.Path]::GetFileName($path)) {
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
        if(@($e).Count){throw (($e|ForEach-Object{'ligne '+$_.Extent.StartLineNumber+' : '+$_.Message}) -join "`r`n")}
        $script:Parsed[$path]=$ast
    }
}
$ast=$script:Parsed[$core]
if($null -ne $ast){
    # Definition-only extraction. Never dot-source the application bootstrap.
    foreach($name in @('Get-MainXaml','Get-DomeniaStandardLoginXaml','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme','Get-UacStatusLabel','New-DomeniaAttributeChange','Protect-DomeniaLogText','Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode')){
        Case ('Extraire sans demarrage : '+$name) {
            $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
            Expect ($fn.Count -eq 1) ('Fonction introuvable/ambigue : '+$name)
            # Definition in script scope must survive the local Case scope.
            $text=$fn[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($name)+'\b'),('function script:'+$name)
            Invoke-Expression $text
        }
    }
}
# Pure modules define functions only. Their optional file readers are not called here.
. (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Guard.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Continuity.Model.ps1')
function Convert-ADLargeIntegerToInt64 {param($Value) return [long]$Value}
function Get-DomeniaOriginalValue {param($Name) return $script:OriginalValue}
function Get-DomeniaStoredTheme {return 'Light'}
function Get-DomeniaLiveHash {param($Text);$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
Case 'Pas de verrouillage deduit de lockoutTime seul' {Expect ((Get-UacStatusLabel 512 123456) -notmatch '^Verrouille| / Verrouille$')}
Case 'Verrouillage calcule courant' {Expect ((Get-UacStatusLabel 512 123456 16) -match 'Verrouill')}
Case 'Ancien verrouillage expire' {Expect ((Get-UacStatusLabel 512 123456 0) -notmatch 'Verrouill')}
Case 'Compte desactive independant du verrouillage' {Expect ((Get-UacStatusLabel 514 123456 16) -match 'Desactiv')}
Case 'Compte incomplet non assimile a actif' {Expect ((Get-UacStatusLabel $null $null $null) -notmatch '^Actif')}
Case 'Correction de casse conservee' {$script:OriginalValue='Support';$c=New-DomeniaAttributeChange 'description' 'SUPPORT';Expect ($null -ne $c -and $c.New -ceq 'SUPPORT')}
Case 'Valeur identique ignoree' {$script:OriginalValue='Support';Expect ($null -eq (New-DomeniaAttributeChange 'description' 'Support'))}
Case 'Effacement explicite' {$script:OriginalValue='Support';Expect ([bool](New-DomeniaAttributeChange 'description' '').Clear)}
Case 'Blancs ne sont pas suppression implicite' {$script:OriginalValue='Support';Expect (-not [bool](New-DomeniaAttributeChange 'description' '  ').Clear)}
Case 'Nom attribut invalide refuse' {ExpectThrow {New-DomeniaAttributeChange 'description;Write-Host' 'x'}}
Case 'Code natif refus acces' {$e=[ComponentModel.Win32Exception]::new(5);Expect ((Get-DomeniaStructuredError $e).Kind -eq 'AccessDenied')}
Case 'Code natif mauvais identifiants' {$e=[ComponentModel.Win32Exception]::new(1326);Expect ((Get-DomeniaStructuredError $e).Kind -eq 'LogonFailure')}
Case 'Compte verrouille pas cascade credentials' {$e=[ComponentModel.Win32Exception]::new(1909);$x=Get-DomeniaStructuredError $e;Expect ($x.Kind -eq 'AccountLocked' -and -not $x.CanOfferCredential)}
Case 'Delai pas mauvais mot de passe' {$x=Get-DomeniaStructuredError 'timeout';Expect ($x.Kind -eq 'Unavailable' -and -not $x.CanOfferCredential)}
Case 'Issue incertaine explicite' {Expect ((Get-DomeniaStructuredError 'ETAT INCONNU apres envoi').Uncertain)}
Case 'Erreur inconnu sans verdict invente' {Expect ((Get-DomeniaStructuredError 'xyz').Kind -eq 'Unknown')}
Case 'Contrat code transporte par texte' {Expect ((Get-DomeniaStructuredError '[DOMENIA:AccessDenied;5;0x80070005] aucun detail').CanOfferCredential)}
Case 'Aucun secret dans objet erreur structure' {$x=Get-DomeniaStructuredError 'password=FAUX-MARQUEUR';Expect (($x|ConvertTo-Json) -notmatch 'FAUX-MARQUEUR')}
Case 'Masquage option /p' {Expect ((Protect-DomeniaLogText 'schtasks /p "FAUX-MARQUEUR" /query') -notmatch 'FAUX-MARQUEUR')}
Case 'Masquage option /rp' {Expect ((Protect-DomeniaLogText 'schtasks /rp FAUX-MARQUEUR /create') -notmatch 'FAUX-MARQUEUR')}
Case 'Masquage option -p' {Expect ((Protect-DomeniaLogText 'psexec -p FAUX-MARQUEUR') -notmatch 'FAUX-MARQUEUR')}
Case 'Masquage JSON mot de passe' {Expect ((Protect-DomeniaLogText '{"password":"FAUX-MARQUEUR"}') -notmatch 'FAUX-MARQUEUR')}
Case 'Bool false texte ne devient pas true' {Expect (-not (ConvertTo-SuiteFlag 'false'))}
Case 'Nombre NaN rejete' {Expect ((ConvertTo-SuiteNumber 'NaN' -Default 13) -eq 13)}
Case 'Nombre infini rejete' {Expect ((ConvertTo-SuiteNumber 'Infinity' -Default 13) -eq 13)}
Case 'Nombre borne' {Expect ((ConvertTo-SuiteNumber 999 -Maximum 100) -eq 100)}
Case 'Percentile mesures reellement entrees' {Expect ((Get-DomeniaPercentile @(1,2,3,4,100) 95) -eq 100)}
Case 'Mediane mesures reellement entrees' {Expect ((Get-DomeniaPercentile @(1,2,3,4,100) 50) -eq 3)}
Case 'Favori domaine valide' {$v=[pscustomobject]@{Name='Test';DN='OU=Test,DC=example,DC=invalid';Query='pc';Type='Machines';Limit=100;Subtree=$true};Expect ($null -ne (ConvertTo-DomeniaSavedSearch $v 'DC=example,DC=invalid'))}
Case 'Favori autre domaine refuse' {$v=[pscustomobject]@{Name='Test';DN='OU=Test,DC=else,DC=invalid';Query='pc';Type='Machines';Limit=100;Subtree=$true};Expect ($null -eq (ConvertTo-DomeniaSavedSearch $v 'DC=example,DC=invalid'))}
Case 'Favori volume borne' {$v=[pscustomobject]@{Name='Test';DN='DC=example,DC=invalid';Query='';Type='Tous';Limit=999999;Subtree=$true};Expect ((ConvertTo-DomeniaSavedSearch $v 'DC=example,DC=invalid').Limit -eq 20000)}
Case 'Favori requete excessive refusee' {$v=[pscustomobject]@{Name='Test';DN='DC=example,DC=invalid';Query=('x'*257);Type='Tous';Limit=100;Subtree=$true};Expect ($null -eq (ConvertTo-DomeniaSavedSearch $v 'DC=example,DC=invalid'))}
# Parse each exact pinned worker, and both non-write/write forms used by the runtime.
$contracts=Get-Content -LiteralPath (Join-Path $root 'tools\operation-contracts.json') -Raw|ConvertFrom-Json
$registry=Get-DomeniaWorkerOperationHashes
foreach($item in $contracts){
    Case ('Worker exact : '+$item.Operation) {
        $source=[IO.File]::ReadAllText((Join-Path $root $item.File))
        $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e)
        $fn=@($a.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $item.Function},$true))
        Expect ($fn.Count -eq 1)
        $literal=[regex]::Matches($fn[0].Extent.Text,'(?ms)@([''"])\r?\n(.*?)\r?\n^\1@')[[int]$item.LiteralIndex].Groups[2].Value
        Expect ((Get-DomeniaWorkerCodeHash $literal) -eq $registry.([string]$item.Operation)) 'Empreinte differente.'
        $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($literal,[ref]$t,[ref]$e)
        if(@($e).Count){throw $e[0].Message}
    }
}
# Parse the assembled wrapper too: the two fragments alone intentionally have open braces.
Case 'Common complet : parseur natif sans execution' {
    $source=[IO.File]::ReadAllText($core)
    $parts=[regex]::Matches($source,'(?ms)^\$script:WorkerCommon (?:=|\+=) @''\r?\n(.*?)\r?\n''@')
    $combined=(@($parts|ForEach-Object{$_.Groups[1].Value}) -join "`r`n")
    Expect ($combined.Length -gt 1000)
    $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($combined,[ref]$t,[ref]$e)
    if(@($e).Count){throw $e[0].Message}
}
Case 'Encadrement durable des ecritures : parseur natif' {
    $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-DomeniaWorkerRunspace'},$true))[0]
    $l=[regex]::Matches($fn.Extent.Text,'(?ms)@([''"])\r?\n(.*?)\r?\n^\1@')
    Expect ($l.Count -ge 4)
    $code=$l[0].Groups[2].Value+"`r`n"+'$null=$Context; [pscustomobject]@{Verified=$false}'+"`r`n"+$l[1].Groups[2].Value
    $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$e)
    if(@($e).Count){throw $e[0].Message}
}
Case 'Matrice native : aucun code reseau ne propose un mot de passe' {
    foreach($code in @(53,64,1722,1460)){$e=[ComponentModel.Win32Exception]::new($code);$r=Get-DomeniaStructuredError $e;Expect (-not $r.CanOfferCredential)}
}
Case 'Matrice champs secrets masques' {
    foreach($prefix in @('password=','pwd:','token=','/p ','/rp ','-p ')){$text=$prefix+'FAUX_MARQUEUR_123';Expect ((Protect-DomeniaLogText $text) -notmatch 'FAUX_MARQUEUR_123')}
}
Case 'Colonnes invalides ignorees' {
    $bad=@([pscustomobject]@{Key='A';Index=0;Unit='Pixel';Width='NaN'},[pscustomobject]@{Key='B';Index=-1;Unit='Pixel';Width=100})
    $layout=ConvertTo-DomeniaColumnLayout $bad;Expect ($layout.Count -eq 0)
}
Case 'Colonne conservee et bornee' {
    $out=ConvertTo-DomeniaColumnLayout @([pscustomobject]@{Key='A';Index=0;Unit='Pixel';Width=99999})
    Expect ($out.Count -eq 1 -and $out[0].Width -eq 2000)
}
Case 'Arbre autre domaine refuse' {
    Expect ($null -eq (ConvertTo-DomeniaTreeBookmark ([pscustomobject]@{Selected='DC=autre,DC=invalid';Expanded=@()}) 'DC=example,DC=invalid'))
}
Case 'Worker altere refuse' {ExpectThrow {Assert-DomeniaWorkerOperationCode -OperationId EngineSelfTest -Code 'Write-Output faux'}}
Case 'Operation non enregistree refusee' {ExpectThrow {Assert-DomeniaWorkerOperationCode -OperationId Inconnue -Code '1'}}
Case 'Nouveaux types C# compilent sans appel Windows' {
    Add-Type -Path (Join-Path $wad 'modules\Domenia-Sessions.Native.cs')
    Add-Type -Path (Join-Path $wad 'modules\Domenia-Clipboard.Native.cs')
    Expect ($null -ne ('Domenia.Sessions.Reader' -as [type]))
}
if($Wpf){
    Case 'WPF principal : chargement natif sans demarrage' {
        if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'WPF exige STA.'}
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $xml=Get-MainXaml;$reader=[Xml.XmlNodeReader]::new([xml]$xml);$w=$null
        try{$w=[Windows.Markup.XamlReader]::Load($reader);Expect ($null -ne $w.FindName('DgGuardReceipts'));Expect ($null -ne $w.FindName('DgSessions'));$w.Measure([Windows.Size]::new(1440,900));$w.Arrange([Windows.Rect]::new(0,0,1440,900));$w.UpdateLayout()}
        finally{$reader.Close();if($null -ne $w){$w.Close()}}
    }
}
$fail=@($script:CandidateResults|Where-Object{-not $_.Passed})
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.2-MODULES';Host=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString;Passed=$script:CandidateResults.Count-$fail.Count;Failed=$fail.Count;WpfRequested=[bool]$Wpf;ADAccess=$false;CimAccess=$false;Mutations=$false;Tests=$script:CandidateResults.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-native-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:CandidateResults|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($fail.Count){exit 1};exit 0
