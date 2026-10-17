#requires -Version 5.1
# RC1.17.14 point 9 : identite des associations utilisateur/poste, banc hors Windows. Les fonctions reelles du coeur
# (extraites par AST) et les regles pures de Domenia-Relations.Model.ps1 repondent sur des liens en memoire, sans AD,
# reseau, CIM ni SQLite. La regle de la fiche (Test-DomeniaLinkIdentity) est centralisee par Get-DomeniaLinkIdentityNote :
# un lien herite sans GUID dont l'identite n'est pas etablie sur l'objet affiche est annonce « identite non verifiable »,
# jamais presente comme une association ordinaire ni remplacee par « aucun lien ». Le banc jumeau
# Test-DomeniaWiringRelations.ps1 exerce les memes fonctions sous Windows PowerShell 5.1 avec la grille WPF.
param([string]$ReportPath='',[string]$CaseFilter='')
$ErrorActionPreference='Stop'
# P-CD-09 : les blocs catch des fonctions extraites tracent une erreur ignoree avec Write-DomeniaSwallowed, definie dans
# la portee script de Domenia-Core.ps1. Double no-op ici (la trace elle-meme est testee dans Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot;$t=$null;$e=$null
$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Condition,[string]$Text);$script:checks++;if(-not $Condition){throw $Text}}
function Case {param([string]$Name,[scriptblock]$Code);if($CaseFilter -and $Name -notmatch $CaseFilter){return};try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Get-CoreFunctionText {param([string]$Name)
 $nodes=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
 Expect ($nodes.Count -eq 1) ('Fonction introuvable ou ambigue : '+$Name)
 return [string]$nodes[0].Extent.Text
}
foreach($module in @('Common.Model','Relations.Model')){. (Join-Path $wad ('modules/Domenia-'+$module+'.ps1'))}
foreach($name in @('Normalize-LinkComputer','Normalize-LinkUser','Rebuild-UserMachineLinkIndex','Ensure-UserMachineLinkIndex','Get-LinksForComputer','Get-LinksForUser','Get-DeProp','Get-DomeniaLinkIdentityNote','Get-AssociationForRow','Get-DomeniaIndexAssociationText','Get-SelectedAssociationSummary')){. ([scriptblock]::Create((Get-CoreFunctionText $name)))}
$note=' · identité non vérifiable'
function Reset-Links {param([object[]]$Links=@())
 $script:UserMachineLinks=@($Links);$script:LinkByComputer=$null;$script:LinksByUser=$null;$script:LinkIndexCount=-1;$script:LinkIndexGeneration=0
 $script:SelectedObject=$null;$script:Ctrl=@{}
}
function New-Link {param([string]$User='alice',[string]$Computer='PC-R',[string]$UserGuid='',[string]$ComputerGuid='',[string]$When='2026-01-01T08:00:00.0000000Z',[string]$Source='Saisie manuelle')
 return [pscustomobject]@{UserLogin=$User;Computer=$Computer;Source=$Source;Confidence=100;VerifiedInAD=$true;When=$When;Details='';UserGuid=$UserGuid;ComputerGuid=$ComputerGuid;UserDn='';ComputerDn=''}
}
try{
 Case 'RC14 Point 9 : identite des associations annoncee en inconnu, jamais comme une association fiable' {
  $old='11111111-aaaa-aaaa-aaaa-111111111111';$new='22222222-bbbb-bbbb-bbbb-222222222222'
  # Legacy link without a stored GUID, creation date of the displayed object unknown: identity Unknown.
  Reset-Links -Links @(New-Link)
  $t=Get-AssociationForRow ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new})
  Expect ($t -eq ('alice'+$note)) ('colonne de grille sur lien herite : '+$t)
  $t=Get-DomeniaIndexAssociationText ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new})
  Expect ($t -eq ('alice'+$note)) ('index sur lien herite : '+$t)
  # Without the GUID of the object, nothing is claimed either way: no annotation, no silent rejection.
  $t=Get-AssociationForRow ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=''})
  Expect ($t -eq 'alice') ('sans GUID de l objet : '+$t)
  # Same object (stored GUID): plain association; a reassigned name (other GUID) never inherits it.
  Reset-Links -Links @(New-Link -ComputerGuid $old)
  $t=Get-AssociationForRow ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=$old})
  Expect ($t -eq 'alice') ('meme GUID annote a tort : '+$t)
  $t=Get-AssociationForRow ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new})
  Expect ($t -eq 'Non detecte') ('nom reattribue herite : '+$t)
  # A link without a readable date proves nothing: Unknown announced, never treated as a proven former holder.
  Reset-Links -Links @(New-Link -When '')
  $t=Get-AssociationForRow ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new})
  Expect ($t -eq ('alice'+$note)) ('date manquante : '+$t)
  # Selected-machine summary: the same link carries the same note as the grid (fiche/résumé coherence).
  Reset-Links -Links @(New-Link)
  $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new}
  $script:Ctrl=@{TxtCompName=[pscustomobject]@{Text='PC-R'}}
  $s=Get-SelectedAssociationSummary
  Expect ($s.StartsWith('alice') -and $s.EndsWith($note)) ('resume poste : '+$s)
  Expect ((Get-AssociationForRow ([pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new})).EndsWith($note)) 'coherence grille/resume sur le meme lien'
  # whenCreated already read on the loaded fiche: a link predating the creation is a proven former holder, filtered.
  Reset-Links -Links @(New-Link -When '2025-01-01T08:00:00.0000000Z')
  $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-R';Guid=$new;Entry=[pscustomobject]@{Properties=@{whenCreated=@('2026-06-01T00:00:00Z')}}}
  $script:Ctrl=@{TxtCompName=[pscustomobject]@{Text='PC-R'}}
  $s=Get-SelectedAssociationSummary
  Expect ($s -eq 'Aucun utilisateur lie') ('lien anterieur a la creation non filtre : '+$s)
  # User side: the same rule for a recreated account.
  Reset-Links -Links @(New-Link -User 'bob' -Computer 'PC-U' -Source 'Console CIM/DCOM')
  $t=Get-DomeniaIndexAssociationText ([pscustomobject]@{Type='Utilisateur';Name='Bob';Login='bob';Guid=$new})
  Expect ($t -eq ('PC-U'+$note)) ('cote utilisateur : '+$t)
  $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';Name='Bob';Login='bob';Guid=$new}
  $script:Ctrl=@{TxtUserSam=[pscustomobject]@{Text='bob'}}
  $s=Get-SelectedAssociationSummary
  Expect ($s.StartsWith('PC-U [Console CIM/DCOM]') -and $s.EndsWith($note)) ('resume utilisateur : '+$s)
 }
}finally{
 $report=[pscustomobject]@{Suite='LinkIdentity';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$cases.ToArray();Total=$cases.Count;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object{-not $_.Passed}).Count;Assertions=$script:checks;NoNetwork=$true;Scope='Real core functions extracted by AST over in-memory links; no Active Directory, CIM, SQLite or real-user data.'}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
}
$report|Select-Object Total,Passed,Failed,Assertions|Format-List
if($report.Failed -gt 0){exit 1};exit 0
