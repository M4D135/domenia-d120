#requires -Version 5.1
# RC1.17.14 point 127 : identite des sondes seules et presence brute, banc hors Windows. Les regles d'identite et
# l'etat d'identite sont exercees par leurs fonctions reelles (extraites par AST du corps epinglee du worker et du
# module Live) sur des paquets en memoire, sans CIM, reseau ni SQLite : une incoherence confirmee rejette
# nominalement toute valeur de la lecture mais conserve le fait brut du ping ; une comparaison impossible n'est
# jamais un refus. Le code du worker est controle dans son texte reel : porte d'identite des sondes avant le plan.
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
# The identity rules live inside the pinned worker body of the Live module; extract them from that here-string.
foreach($spec in @(
 @('Domenia-Live.Model.ps1','function Get-LiveHostIdentityCheck','Get-LiveHostIdentityCheck'),
 @('Domenia-Live.Model.ps1','function Get-LiveHostIdentityCheck','Get-LiveHostMismatch'),
 @('Domenia-Live.Model.ps1','function Set-LiveIdentityMismatch','Set-LiveIdentityMismatch'))){
 . ([scriptblock]::Create((Get-NestedFunctionText $spec[0] $spec[1] $spec[2])))
}
# The probe worker code is assembled from the ProbeDetails prelude, which reads its own module's functions.
. (Join-Path $wad 'modules/Domenia-ProbeDetails.Model.ps1')
. ([scriptblock]::Create((Get-NestedFunctionText 'Domenia-Storage.Worker.ps1' 'function Get-StoreWMap' 'Get-StoreWMap')))
. ([scriptblock]::Create((Get-NestedFunctionText 'Domenia-Storage.Worker.ps1' 'function Get-StoreWMap' 'Get-StoreWObservationSummaryJson')))
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Condition,[string]$Text);$script:checks++;if(-not $Condition){throw $Text}}
function Case {param([string]$Name,[scriptblock]$Code);if($CaseFilter -and $Name -notmatch $CaseFilter){return};try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
$guid='00000000-0000-0000-0000-000000000001'
function New-Result {param([string]$Outcome='Observed',[string]$User='EXAMPLE\alice',[string]$Source='CIM/DCOM · Win32_ComputerSystem.UserName',[string]$Transport='CIM/DCOM',[string]$IdentityState='Vérifiée',[string]$Presence='En ligne',[string]$PresenceAt='2026-10-17T08:00:00.0000000Z',[string]$PresenceDetail='Réponse ICMP · 3 ms · 10.77.0.20',[string]$Detail='Compte console observe.')
 return [pscustomobject]@{Key='cn=pc-01,ou=test,dc=example,dc=invalid';Computer='pc-01';Guid=$guid;Outcome=$Outcome;User=$User;Source=$Source;Transport=$Transport;IdentityState=$IdentityState;Detail=$Detail;Presence=$Presence;PresenceCheckedUtc=$PresenceAt;PresenceDetail=$PresenceDetail}
}
try{
 Case 'RC14 Point 127 : identite des sondes seules, presence brute conservee' {
  # Identity rules as executed by the worker: same responder verifies, another responder mismatches.
  $same=Get-LiveHostIdentityCheck 'pc-01.example.invalid' ([pscustomobject]@{DNSHostName='pc-01.example.invalid';Name='PC-01'})
  Expect (([bool]$same.Comparable) -and (([string]$same.Mismatch) -eq '')) 'meme poste : comparaison possible sans divergence'
  $other=Get-LiveHostIdentityCheck 'pc-01.example.invalid' ([pscustomobject]@{DNSHostName='other-09.example.invalid';Name='OTHER-09'})
  Expect (([bool]$other.Comparable) -and (([string]$other.Mismatch).Contains('other-09')) -and (([string]$other.Mismatch).Contains('Aucune donnée'))) ('autre poste : divergence nommee : '+$other.Mismatch)
  # Impossible comparison stays impossible: never a refusal, never a verification.
  $addr=Get-LiveHostIdentityCheck '10.77.0.20' ([pscustomobject]@{DNSHostName='other-09.example.invalid';Name='OTHER-09'})
  Expect ((-not [bool]$addr.Comparable) -and (([string]$addr.Mismatch) -eq '')) 'cible adresse : comparaison impossible'
  $nul=Get-LiveHostIdentityCheck 'pc-01' $null
  Expect ((-not [bool]$nul.Comparable) -and (([string]$nul.Mismatch) -eq '')) 'reponse nulle : comparaison impossible'
  $noname=Get-LiveHostIdentityCheck 'pc-01' ([pscustomobject]@{DNSHostName='';Name=''})
  Expect ((-not [bool]$noname.Comparable) -and (([string]$noname.Mismatch) -eq '')) 'reponse sans noms : comparaison impossible'
  # Accepted identities preserved: cn NetBIOS cut at 15 against a longer DNS label, and Name alone.
  $cut=Get-LiveHostIdentityCheck 'PC-01-LONGHOSTN' ([pscustomobject]@{DNSHostName='PC-01-LONGHOSTNAME.example.invalid';Name='PC-01-LONGHOSTNAME'})
  Expect (([bool]$cut.Comparable) -and (([string]$cut.Mismatch) -eq '')) 'cn NetBIOS tronque face au nom long : accepte'
  $byname=Get-LiveHostIdentityCheck 'pc-01' ([pscustomobject]@{Name='PC-01'})
  Expect (([bool]$byname.Comparable) -and (([string]$byname.Mismatch) -eq '')) 'Name seul : accepte'
  Expect (([string](Get-LiveHostMismatch 'pc-01.example.invalid' ([pscustomobject]@{DNSHostName='other-09.example.invalid';Name='OTHER-09'}))) -ne '') 'Get-LiveHostMismatch reste lenveloppe'
  # Set-LiveIdentityMismatch on the real answer shape: the raw ICMP fact survives beside the contradicted identity.
  $script:answer=[pscustomobject]@{Presence='En ligne';PresenceDetail='Réponse ICMP · 3 ms · 10.77.0.20';IdentityState=''}
  Set-LiveIdentityMismatch
  Expect (([string]$script:answer.Presence) -eq 'En ligne') ('presence brute conservee : '+$script:answer.Presence)
  Expect (([string]$script:answer.PresenceDetail).StartsWith('Réponse ICMP · 3 ms')) 'le fait brut du ping reste en tete du detail'
  Expect (([string]$script:answer.PresenceDetail).Contains('identité du poste contredite') -and ([string]$script:answer.PresenceDetail).Contains('fait brut')) ('note de contradiction : '+$script:answer.PresenceDetail)
  Expect (([string]$script:answer.IdentityState) -eq 'Incohérente') ('etat pose : '+$script:answer.IdentityState)
  # No ICMP reply: nothing to note on the presence, the identity state is still recorded.
  $script:answer=[pscustomobject]@{Presence='Sans réponse au ping';PresenceDetail='ICMP : TimedOut · 10.77.0.20';IdentityState=''}
  Set-LiveIdentityMismatch
  Expect (([string]$script:answer.PresenceDetail) -eq 'ICMP : TimedOut · 10.77.0.20') 'pas de ping : detail de presence inchange'
  Expect (([string]$script:answer.IdentityState) -eq 'Incohérente') 'pas de ping : identite neeanmoins incoherente'
  # Propagation and display: verified, contradicted, unknown are three distinct explicit states.
  $o1=ConvertTo-DomeniaLiveObservation (New-Result) $null '2026-10-17T08:00:00.0000000Z'
  Expect (([string]$o1.IdentityState) -eq 'Vérifiée') 'identite verifiee propagee'
  $v1=Get-DomeniaLiveObservationView $o1
  Expect ($v1.Detail.Contains('Identité du poste : confirmée par la lecture CIM')) 'vue : identite confirmee'
  Expect (([string]$v1.Identity) -eq 'Vérifiée') 'vue expose le champ Identity'
  $o2=ConvertTo-DomeniaLiveObservation (New-Result -IdentityState 'Incohérente' -User '' -Outcome 'Unavailable' -Detail 'Le poste qui répond à pc-01 se nomme other-09.') $o1 '2026-10-17T09:00:00.0000000Z'
  $v2=Get-DomeniaLiveObservationView $o2
  Expect ($v2.Detail.Contains('Identité du poste : incohérente')) 'vue : identite incoherente'
  Expect (([string]$o2.LastUser) -eq 'EXAMPLE\alice') 'incoherence ne remplace pas le dernier compte observe'
  # Ping alone keeps the last identity state, never invents or erases one.
  $o3=ConvertTo-DomeniaLiveObservation (New-Result -Outcome 'PresenceOnly' -User '' -Source '' -Transport '' -IdentityState '' -PresenceAt='2026-10-17T10:00:00.0000000Z') $o1 '2026-10-17T10:00:00.0000000Z'
  Expect (([string]$o3.IdentityState) -eq 'Vérifiée') ('ping seul conserve l identite : '+$o3.IdentityState)
  # Legacy stored measure without any IdentityState field: unknown is shown, never a certainty.
  $legacy=[pscustomobject]@{Key='cn=pc-02,ou=test,dc=example,dc=invalid';Computer='pc-02';Guid='00000000-0000-0000-0000-000000000002';Outcome='Observed';CurrentUser='EXAMPLE\bob';LastUser='EXAMPLE\bob';Source='CIM/DCOM';Transport='CIM/DCOM';Detail='Ancienne mesure sans champ IdentityState.';Presence='En ligne';PresenceCheckedUtc='2026-10-16T08:00:00.0000000Z'}
  $o4=ConvertTo-DomeniaLiveObservation $legacy $null '2026-10-16T08:00:00.0000000Z'
  $v4=Get-DomeniaLiveObservationView $o4
  Expect ($v4.Detail.Contains('Identité du poste : inconnue')) 'donnees anciennes sans IdentityState : inconnue'
  # A failed read asserts no identity: the real Fail-DomeniaLiveProbe packet leaves IdentityState empty.
  $state=[pscustomobject]@{Key='cn=pc-01,ou=test,dc=example,dc=invalid';Computer='pc-01';Guid=$guid;RemoteStartedUtc='2026-10-17T11:00:00.0000000Z';ProbeUser=$true}
  $script:Captured=$null
  Fail-DomeniaLiveProbe 'Session distante interrompue.' $state
  $fail=$script:Captured
  Expect ($null -ne $fail) 'paquet d echec produit'
  Expect (([string]$fail.IdentityState) -eq '') ('identite affirmee sur echec : '+$fail.IdentityState)
  $o5=ConvertTo-DomeniaLiveObservation $fail $o1 '2026-10-17T11:00:00.0000000Z'
  $v5=Get-DomeniaLiveObservationView $o5
  Expect ($v5.Detail.Contains('Identité du poste : inconnue')) 'echec : identite affichee inconnue'
  Expect (([string]$o5.LastUser) -eq 'EXAMPLE\alice') 'echec ne remplace pas le dernier compte observe'
  # Persistence whitelist: IdentityState survives the SQLite summary payload.
  $json=Get-StoreWObservationSummaryJson 'Observation' $o2
  Expect ($json.Contains('"IdentityState":"Incohérente"')) 'persistance SQLite conserve IdentityState : '+$json
  # Worker code as executed: probes alone pass the identity gate before any probe plan is built.
  $code=Get-DomeniaLiveProbeCode
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
  Expect ($errors.Count -eq 0) 'here-string du worker : erreurs de parsing'
  Expect ($code.Contains("IdentityState=''")) 'le worker initialise IdentityState vide'
  $iGate=$code.IndexOf("@('Name','DNSHostName')")
  $iPlan=$code.IndexOf('$planned=[Collections.Generic.List[object]]::new()')
  Expect (($iGate -ge 0) -and ($iPlan -ge 0) -and ($iGate -lt $iPlan)) 'porte d identite des sondes avant le plan de sondes'
  Expect ($code.Contains('Set-LiveIdentityMismatch;throw')) 'incoherence confirmee : presence notee puis rejet nominal'
  Expect ($code.Contains("if(`$identityCheck.Comparable){`$answer.IdentityState='Vérifiée'}")) 'verifiee seulement quand la comparaison a reussi'
 }
}finally{
 $report=[pscustomobject]@{Suite='LiveIdentity';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$cases.ToArray();Total=$cases.Count;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object{-not $_.Passed}).Count;Assertions=$script:checks;NoNetwork=$true;Scope='Real Live module and pinned worker-body functions extracted by AST over in-memory packets; worker code checked as text; no CIM, network or SQLite.'}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
}
$report|Select-Object Total,Passed,Failed,Assertions|Format-List
if($report.Failed -gt 0){exit 1};exit 0
