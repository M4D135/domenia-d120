#requires -Version 5.1
# RC1.17.14 point 10 : provenance du transport reellement execute, banc hors Windows. Les fonctions reelles du module
# Live (extraites par AST) repondent sur des paquets en memoire, sans CIM, reseau ni SQLite : le transport n'est
# affiche que quand une lecture a reellement retourne ; un echec, une donnee ancienne ou un ping seul ne posent
# aucune certitude (Transport et Source restent vides, affiches inconnus) et ne remplacent jamais le dernier compte
# observe. Le code du worker est controle dans son texte reel : aucune certitude avant lecture.
param([string]$ReportPath='',[string]$CaseFilter='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null
function Get-ModuleFunctionText {param([string]$File,[string]$Name)
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad ('modules/'+$File)),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('Parse failed: '+$File)}
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
 if($nodes.Count -ne 1){throw ('Fonction introuvable ou ambigue : '+$Name)}
 return [string]$nodes[0].Extent.Text
}
# Worker bodies are pinned here-strings: locate the one carrying the anchor, then extract the function from its text.
function Get-NestedFunctionText {param([string]$File,[string]$Anchor,[string]$Name)
 $text=[IO.File]::ReadAllText((Join-Path $wad ('modules/'+$File)))
 $bodies=@([regex]::Matches($text,"@'[\r\n]+([\s\S]*?)[\r\n]+'@")|ForEach-Object{$_.Groups[1].Value})
 $hits=@($bodies|Where-Object{$_.Contains($Anchor)})
 if($hits.Count -ne 1){throw ('Here-string introuvable ou ambigu pour : '+$Anchor)}
 $innerTokens=$null;$innerErrors=$null
 $innerAst=[Management.Automation.Language.Parser]::ParseInput([string]$hits[0],[ref]$innerTokens,[ref]$innerErrors)
 if($innerErrors.Count){throw ('Here-string non parseable dans '+$File)}
 $nodes=@($innerAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
 if($nodes.Count -ne 1){throw ('Fonction introuvable ou ambigue dans la here-string : '+$Name)}
 return [string]$nodes[0].Extent.Text
}
# Complete-DomeniaLiveProbe is the UI sink; the bench captures the packet instead of touching WPF.
$script:Captured=$null
function Complete-DomeniaLiveProbe {param($Result,$State)$script:Captured=$Result}
. (Join-Path $wad 'modules/Domenia-Common.Model.ps1')
foreach($spec in @(
 @('Domenia-Live.Model.ps1','Get-DomeniaLiveField'),
 @('Domenia-Live.Model.ps1','Test-DomeniaLiveAttemptAfter'),
 @('Domenia-Live.Model.ps1','ConvertTo-DomeniaLiveObservation'),
 @('Domenia-Live.Model.ps1','Get-DomeniaLiveObservationView'),
 @('Domenia-Live.Model.ps1','Get-DomeniaLiveProbeCode'),
 @('Domenia-Live.UI.ps1','Fail-DomeniaLiveProbe'))){
 . ([scriptblock]::Create((Get-ModuleFunctionText $spec[0] $spec[1])))
}
# The probe worker code is assembled from the ProbeDetails prelude, which reads its own module's functions.
. (Join-Path $wad 'modules/Domenia-ProbeDetails.Model.ps1')
. ([scriptblock]::Create((Get-NestedFunctionText 'Domenia-Storage.Worker.ps1' 'function Get-StoreWMap' 'Get-StoreWMap')))
. ([scriptblock]::Create((Get-NestedFunctionText 'Domenia-Storage.Worker.ps1' 'function Get-StoreWMap' 'Get-StoreWObservationSummaryJson')))
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Condition,[string]$Text);$script:checks++;if(-not $Condition){throw $Text}}
function Case {param([string]$Name,[scriptblock]$Code);if($CaseFilter -and $Name -notmatch $CaseFilter){return};try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
$guid='00000000-0000-0000-0000-000000000001'
function New-Result {param([string]$Outcome='Observed',[string]$User='EXAMPLE\alice',[string]$Source='CIM/DCOM · Win32_ComputerSystem.UserName',[string]$Transport='CIM/DCOM',[string]$Presence='En ligne',[string]$PresenceAt='2026-10-17T08:00:00.0000000Z',[string]$Detail='Compte console observe.')
 return [pscustomobject]@{Key='cn=pc-01,ou=test,dc=example,dc=invalid';Computer='pc-01';Guid=$guid;Outcome=$Outcome;User=$User;Source=$Source;Transport=$Transport;Detail=$Detail;Presence=$Presence;PresenceCheckedUtc=$PresenceAt;PresenceDetail=''}
}
try{
 Case 'RC14 Point 10 : transport affiche seulement quand une lecture a reellement retourne' {
  # Success path: the transport of the read that executed is merged and shown.
  $o1=ConvertTo-DomeniaLiveObservation (New-Result) $null '2026-10-17T08:00:00.0000000Z'
  Expect (([string]$o1.Transport) -eq 'CIM/DCOM') ('transport propage : '+$o1.Transport)
  $v1=Get-DomeniaLiveObservationView $o1
  Expect ($v1.Detail.Contains('Transport : CIM/DCOM')) 'vue affiche le transport reellement execute'
  Expect ($v1.Detail.Contains('Source : CIM/DCOM')) 'vue affiche la source'
  # Failure path: the real Fail-DomeniaLiveProbe packet asserts no transport and no source.
  $state=[pscustomobject]@{Key='cn=pc-01,ou=test,dc=example,dc=invalid';Computer='pc-01';Guid=$guid;RemoteStartedUtc='2026-10-17T09:00:00.0000000Z';ProbeUser=$true}
  $script:Captured=$null
  Fail-DomeniaLiveProbe 'Lecture CIM/DCOM non confirmee.' $state
  $fail=$script:Captured
  Expect ($null -ne $fail) 'paquet d echec produit'
  Expect (([string]$fail.Source) -eq '') ('source affirmee sur echec : '+$fail.Source)
  Expect (([string]$fail.Transport) -eq '') ('transport affirme sur echec : '+$fail.Transport)
  Expect (([string]$fail.Outcome) -eq 'Unavailable') ('outcome echec : '+$fail.Outcome)
  $o2=ConvertTo-DomeniaLiveObservation $fail $o1 '2026-10-17T09:00:00.0000000Z'
  $v2=Get-DomeniaLiveObservationView $o2
  Expect ($v2.Detail.Contains('Transport : inconnu')) 'echec : transport affiche inconnu'
  Expect ($v2.Detail.Contains('Source : inconnue')) 'echec : source affichee inconnue'
  Expect (([string]$o2.LastUser) -eq 'EXAMPLE\alice') 'echec ne remplace pas le dernier compte observe'
  # A timeout message keeps its own outcome, still without asserting a transport.
  $script:Captured=$null
  Fail-DomeniaLiveProbe 'Timeout de la session distante.' $state
  Expect (([string]$script:Captured.Outcome) -eq 'Timeout') ('outcome timeout : '+$script:Captured.Outcome)
  Expect (([string]$script:Captured.Transport) -eq '') 'timeout : aucun transport affirme'
  # PresenceOnly (ping alone) keeps the last measured transport, never invents one.
  $o4=ConvertTo-DomeniaLiveObservation (New-Result -Outcome 'PresenceOnly' -User '' -Source '' -Transport '' -PresenceAt='2026-10-17T10:00:00.0000000Z') $o1 '2026-10-17T10:00:00.0000000Z'
  Expect (([string]$o4.Transport) -eq 'CIM/DCOM') ('ping seul conserve le transport : '+$o4.Transport)
  # Legacy stored measure without any Transport field: unknown is shown, never a certainty.
  $legacy=[pscustomobject]@{Key='cn=pc-02,ou=test,dc=example,dc=invalid';Computer='pc-02';Guid='00000000-0000-0000-0000-000000000002';Outcome='Observed';User='EXAMPLE\bob';Source='CIM/DCOM';Detail='Ancienne mesure sans champ Transport.';Presence='En ligne';PresenceCheckedUtc='2026-10-16T08:00:00.0000000Z'}
  $o3=ConvertTo-DomeniaLiveObservation $legacy $null '2026-10-16T08:00:00.0000000Z'
  $v3=Get-DomeniaLiveObservationView $o3
  Expect ($v3.Detail.Contains('Transport : inconnu')) 'donnees anciennes sans Transport : inconnu'
  # Persistence whitelist: Transport survives the SQLite summary payload.
  $json=Get-StoreWObservationSummaryJson 'Observation' $o1
  Expect ($json.Contains('"Transport":"CIM/DCOM"')) 'persistance SQLite conserve Transport : '+$json
  # Worker code as executed: no certainty before a read really returned.
  $code=Get-DomeniaLiveProbeCode
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
  Expect ($errors.Count -eq 0) 'here-string du worker : erreurs de parsing'
  Expect ($code.Contains("Transport=''")) 'le worker initialise Transport vide'
  Expect ($code.Contains("Source=''")) 'le worker initialise Source vide'
  $iRead=$code.IndexOf('Get-CimInstance');$iTransport=$code.IndexOf("Transport='CIM/DCOM'")
  Expect (($iRead -ge 0) -and ($iTransport -gt $iRead)) 'le transport est pose seulement apres une lecture CIM'
  $iShared=$code.IndexOf('Invoke-WSharedRead');$iSource=$code.IndexOf("Source='CIM/DCOM")
  Expect (($iShared -ge 0) -and ($iSource -gt $iShared)) 'la source du compte est posee seulement apres une lecture'
 }
}finally{
 $report=[pscustomobject]@{Suite='LiveTransport';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$cases.ToArray();Total=$cases.Count;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object{-not $_.Passed}).Count;Assertions=$script:checks;NoNetwork=$true;Scope='Real Live module functions extracted by AST over in-memory packets; worker code checked as text; no CIM, network or SQLite.'}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
}
$report|Select-Object Total,Passed,Failed,Assertions|Format-List
if($report.Failed -gt 0){exit 1};exit 0
