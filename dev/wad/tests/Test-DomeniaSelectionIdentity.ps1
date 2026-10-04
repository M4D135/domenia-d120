#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'Domenia-Modules.ps1')
if($null -eq ('Domenia.SelectionIdentity' -as [type])){Add-Type -Path (Join-Path $wad 'modules\Domenia-Identity.Types.cs')}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Get-DomeniaControl','Get-SelectedComputerTarget','Get-CurrentSelectedComputerName','Assert-DomeniaComputerTarget','Normalize-LinkComputer')){
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
 . ([scriptblock]::Create($f.Extent.Text))
}
function Assert {param($Value,[string]$Message='Assertion fausse')if(-not $Value){throw $Message}}
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)try{Reset-Fixture;& $Body|Out-Null;$status='Passed';$detail=''}catch{$status='Failed';$detail=$_.Exception.Message+' '+$_.ScriptStackTrace};$checks.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})}
# Every external boundary is inert. Only identities and WPF controls are exercised.
function Get-DomeniaRetryCredential {param($OperationId)return $null}
function Get-DomeniaEntryFirstString {param($Entry,$Name)return [string]$Entry[$Name]}
function Get-CfgValue {param($Section,$Key,$Default)return $Default}
function Test-DomeniaAccessBusyWrite {return $false}
function Refresh-DomeniaRelationViews {}
function Set-DomeniaControlText {param($Name,$Text)return $true}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)}
function New-Row {param([string]$Name='PC-A',[string]$Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',[string]$Type='Machine')
 return [pscustomobject]@{Type=$Type;Name=$Name;DN=('CN='+$Name+',DC=example,DC=invalid');Guid=$Guid;Login=($Name+'$')}
}
function Reset-Fixture {
 $script:SessionEpoch=1L;$script:GlobalSearchGeneration=3L;$script:SelectedObjectGeneration=7L;$script:SuppressGridSelectionEvents=$false;$script:CurrentObjectRequestDn='';$script:AsyncJobs=@{};$script:Relations=$null
 $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid';BindUser='EXAMPLE\reader';Credential=$null}
 $script:Ctrl=@{DgObjects=[Windows.Controls.DataGrid]::new();TxtCompDns=[Windows.Controls.TextBox]::new();TxtCompName=[Windows.Controls.TextBox]::new()}
 $script:Ctrl.DgObjects.CanUserAddRows=$false;$script:Ctrl.DgObjects.SelectionMode='Single';$script:Ctrl.TxtCompDns.Text='PC-B.example.invalid';$script:Ctrl.TxtCompName.Text='PC-B'
 $script:Row=New-Row;$script:Captured=Get-DomeniaRowSelectionIdentity $script:Row
 $script:SelectedObject=[pscustomobject]@{DN=$script:Row.DN;Type='Machine';Name='PC-A';Safety=[pscustomobject]@{Guid=$script:Row.Guid};Entry=@{sAMAccountName='PC-A$'}}
 $script:SelectionLoad=[pscustomobject]@{Phase='Ready';SelectionIdentity=$script:Captured}
}
Case 'D012 Assistance : les libelles modifies ne changent pas le poste' {
 Assert ((Get-CurrentSelectedComputerName) -eq 'PC-A');$script:Ctrl.TxtCompDns.Text='PC-C';$script:Ctrl.TxtCompName.Text='PC-C';Assert ((Get-SelectedComputerTarget) -eq 'PC-A')
}
Case 'D012 Assistance : une autre ligne de recherche ne remplace pas la fiche chargee' {
 $r=New-Row 'PC-C' 'cccccccc-cccc-cccc-cccc-cccccccccccc';[void]$script:Ctrl.DgObjects.Items.Add($r);$script:Ctrl.DgObjects.SelectedItem=$r
 Assert ((Get-CurrentSelectedComputerName) -eq 'PC-A')
}
Case 'D012 Assistance : aucune cible sans fiche meme si les champs restent remplis' {$script:SelectedObject=$null;Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))}
Case 'D012 Assistance : une fiche utilisateur ne fournit pas une cible machine' {$script:SelectedObject.Type='Utilisateur';$script:SelectionLoad=$null;Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))}
Case 'D012 Assistance : objet recree sous le meme DN refuse' {$script:SelectedObject.Safety.Guid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))}
Case 'D012 Assistance : identite capturee dans une ancienne session refusee' {$script:SessionEpoch++;Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))}
Case 'D012 Assistance : changement de lecteur impose une nouvelle fiche' {$script:Conn.BindUser='EXAMPLE\other';Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))}
Case 'D012 Assistance : autre fiche en chargement interdit une cible ancienne' {$script:CurrentObjectRequestDn='CN=PC-C,DC=example,DC=invalid';Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))}
Case 'D012 Assistance : nom de compte invalide ne retombe pas sur un champ affiche' {
 $script:Row.Login='PC-A;other$';$script:SelectionLoad.SelectionIdentity=Get-DomeniaRowSelectionIdentity $script:Row;Assert ([string]::IsNullOrEmpty((Get-CurrentSelectedComputerName)))
}
Case 'D012 Relations : sujet immuable capture depuis la ligne' {
 Set-DomeniaRelationsSelection -Row $script:Row;$subject=Get-DomeniaRelationsSubject
 Assert ($subject -is [Domenia.SelectionIdentity]);$script:Row.Name='PC-C';Assert ($subject.Name -eq 'PC-A')
 $refused=$false;try{$subject.Guid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}catch{$refused=$true};Assert $refused
}
Case 'D012 Relations : selection WPF consomme la meme identite commune' {
 [void]$script:Ctrl.DgObjects.Items.Add($script:Row);$script:Ctrl.DgObjects.SelectedItem=$script:Row;Set-DomeniaRelationsGridSelection
 $subject=Get-DomeniaRelationsSubject;Assert ($subject -is [Domenia.SelectionIdentity] -and $subject.SameContext((Get-DomeniaCurrentSelectionIdentity -Workspace 'WsSearch')))
}
Case 'D012 Relations : fiche chargee transmet son identite capturee' {Set-DomeniaRelationsSelection -Object $script:SelectedObject;Assert ([object]::ReferenceEquals($script:Relations.Subject,$script:Captured))}
Case 'D012 Relations : ligne sans GUID ne devient pas un nouveau sujet' {$script:SelectedObject=$null;$script:Row.Guid='';Set-DomeniaRelationsSelection -Row $script:Row;Assert ($null -eq $script:Relations.Subject)}
Case 'D012 Relations : ancien contexte explicite refuse apres changement de session' {$script:SessionEpoch++;$script:SelectedObject=$null;Set-DomeniaRelationsSelection -SelectionIdentity $script:Captured;Assert ($null -eq $script:Relations.Subject)}
$failed=@($checks|Where-Object Status -eq 'Failed').Count
$report=[ordered]@{Kind='SelectionIdentity';Expected=14;Complete=($checks.Count -eq 14 -and $failed -eq 0);NativeWindowsPowerShell51=$true;LiveAD=$false;MockedNetwork=$true;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path $env:TEMP 'domenia-selection-identity-tests.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ($report.Passed.ToString()+' reussis, '+$failed+' echecs. '+$ReportPath);$checks|Where-Object Status -eq 'Failed'|ForEach-Object{Write-Host ($_.Name+': '+$_.Detail)}}
if(-not $report.Complete){exit 1};exit 0
