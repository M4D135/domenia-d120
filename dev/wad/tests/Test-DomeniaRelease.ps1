#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
# Isolated regression suite. Never starts the application or an AD/SMB/CIM request.
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 -STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if(@($e).Count){throw $e[0].Message}
# D120 resync: the access, guard, sessions and continuity functions live in modules of the closed plan.
# Import that real plan (definitions only, verified origin) instead of a hand-picked file list:
# a function removed from the plan now fails the suite with DOMENIA_MODULE_EXPORT.
. (Join-Path $wad 'Domenia-Modules.ps1')
$sourceFunctions=@{}
foreach($n in @('Get-WorkerContext','Get-MainXaml','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode','Get-DomeniaDefaultSettings','Get-DomeniaEntryFirstString','Get-DeProp')){
    $fn=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n},$true))
    if($fn.Count -ne 1){throw ('Fonction absente : '+$n)}
    $sourceFunctions[$n]=$fn[0].Extent.Text
    . ([scriptblock]::Create($fn[0].Extent.Text))
}
# Explicit doubles for UI and mutation boundaries, not alternative implementations of the models.
# They are declared after the module import, so they replace only these boundaries.
function Get-DomeniaControl {param($Name) if($script:Ctrl.ContainsKey($Name)){return $script:Ctrl[$Name]};return $null}
function Set-DomeniaSetting {param($Name,$Value) $script:SettingsFixture[$Name]=$Value}
function Get-DomeniaSetting {param($Name,$Default) return $Default}
function Initialize-DomeniaWorkerContextCache {$script:WorkerContextStatic=[pscustomobject]@{}}
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level)}
function Show-InfoBox {param($Message)}
function Confirm-Action {param($Message,$Title) $script:ConsentCalls++;return $script:Consent}
function Show-DomeniaAlternateCredential {param($Scope,$Operation,$Target) $script:DialogCalls++;$script:DialogTarget=[string]$Target;return $script:NextCredential}
function Start-DomeniaAccountRelogin {$script:ReloginCalls++}
function Start-LoadComputerSecrets {param($Mode,$RetryAttempt) $script:RetryCalls.Add([pscustomobject]@{Mode=$Mode;RetryAttempt=$RetryAttempt})}
function Update-DomeniaSecretActionUi {}
function Apply-CurrentPermissionUi {}
function Clear-DomeniaActualCapabilityDenials {param($Dn)}
# Contract C4 (in-page confirmation): same consent counter as Confirm-Action. The operator answer is immediate here.
function Request-DomeniaInlineConfirmation {
    param([string]$Title,[string]$Message,[string]$Target,[string]$ConfirmText='Confirmer',[string]$CancelText='Annuler',[scriptblock]$OnConfirm,[scriptblock]$OnCancel,[string]$Risk='Normal')
    $script:ConsentCalls++
    if($script:Consent){if($null -ne $OnConfirm){& $OnConfirm}}elseif($null -ne $OnCancel){& $OnCancel}
    return [pscustomobject]@{Title=$Title;Target=$Target;Answered=$true;Confirmed=[bool]$script:Consent}
}
# Minimal main-window stand-in for the real Initialize-DomeniaAccess (no WPF window, never active).
function New-FixtureWindowStub {
    $w=[pscustomobject]@{IsActive=$false}
    Add-Member -InputObject $w -MemberType ScriptMethod -Name Add_Closed -Value {param($Handler)}
    return $w
}
$script:Tests=[Collections.Generic.List[object]]::new()
function Assert-Release {param([bool]$Condition,[string]$Message='Assertion en echec') if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$ok=$true;$detail=''}catch{$ok=$false;$detail=$_.Exception.Message}
    $script:Tests.Add([pscustomobject]@{Name=$Name;Passed=$ok;Detail=$detail})
    if(-not $Quiet -or -not $ok){Write-Host ("$ok | $Name | $detail")}
}
function Reset-Fixture {
    $script:SessionEpoch=1L;$script:SelectedObjectGeneration=3L;$script:ActiveWriteTaskId='';$script:WriteState='Idle';$script:AsyncEngineClosing=$false
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';BindUser='EXAMPLE\user'}
    $script:AccessCurrentJob=$null;$script:DirectoryCredentialFaulted=$false;$script:SecretsCredential=$null;$script:Live=$null;$script:Ctrl=@{};$script:SettingsFixture=@{}
    # The access state is built by the REAL Initialize-DomeniaAccess (same shape as the application:
    # Expires, Timer and any later field), then its DispatcherTimer is stopped: nothing ticks in this suite.
    if($null -ne $script:AccessState -and $null -ne $script:AccessState.PSObject.Properties['Timer'] -and $null -ne $script:AccessState.Timer){$script:AccessState.Timer.Stop()}
    $script:Window=New-FixtureWindowStub;$script:AccessState=$null
    Initialize-DomeniaAccess
    if($null -eq $script:AccessState){throw 'Etat des acces non initialise par Initialize-DomeniaAccess.'}
    if($null -ne $script:AccessState.PSObject.Properties['Timer'] -and $null -ne $script:AccessState.Timer){$script:AccessState.Timer.Stop()}
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC,OU=Test,DC=example,DC=invalid'}
    $script:Consent=$true;$script:ConsentCalls=0;$script:DialogCalls=0;$script:ReloginCalls=0;$script:NextCredential=$null
    $script:RetryCalls=[Collections.Generic.List[object]]::new()
}
function Fixture-Credential {param([string]$Name='EXAMPLE\helper') [Management.Automation.PSCredential]::new($Name,(ConvertTo-SecureString 'TEST-ONLY-never-used-on-network' -AsPlainText -Force))}
function Fixture-Record {param([string]$Op='ReadLaps',[switch]$Write)
    [pscustomobject]@{Key=$Op+'|'+$script:SelectedObject.DN;Scope=(Get-DomeniaAccessScope $Op);OperationId=$Op;Operation=$Op;DN=$script:SelectedObject.DN;Kind='AccessDenied';Epoch=1L;Generation=3L;IsWrite=[bool]$Write;Interactive=$true;At=[datetime]::UtcNow}
}
Reset-Fixture
Case 'Parseur natif : scripts runtime et nouvelle suite' {
    $man=[IO.File]::ReadAllText((Join-Path $wad 'package-manifest.json'))|ConvertFrom-Json
    $paths=@($man.Files|Where-Object{$_.Runtime -and $_.Path -like '*.ps1'}|ForEach-Object{Join-Path $root $_.Path}) + @($PSCommandPath)
    foreach($p in $paths){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);Assert-Release (@($e).Count -eq 0) ($p+': '+(@($e)|Out-String))}
}
Case 'Registre ferme conforme au contrat DEV' {
    # Count and names come from tools/operation-contracts.json (parsed in two steps for 5.1), never from a constant.
    $c=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
    $contracts=@($c)
    $names=@((Get-DomeniaWorkerOperationHashes).Keys|ForEach-Object{[string]$_}|Sort-Object)
    Assert-Release ((Assert-DomeniaWorkerRegistry) -eq $contracts.Count) ('Registre / contrat : '+$names.Count+' / '+$contracts.Count)
    Assert-Release (@(Compare-Object $names @($contracts|ForEach-Object{[string]$_.Operation}|Sort-Object)).Count -eq 0) 'Noms du registre differents du contrat DEV.'
}
Case 'Empreinte et syntaxe du worker de revalidation' {
    $code=Get-DomeniaChangeWorkerCode
    [void](Assert-DomeniaWorkerOperationCode 'LiveDirectoryCheck' $code)
    $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$e);Assert-Release (@($e).Count -eq 0)
}
Case 'Syntaxe et empreintes des deux workers secrets' {
    $fn=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Start-LoadComputerSecrets'},$true))[0]
    $bodies=@($fn.FindAll({param($a)$a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.StringConstantType -eq 'SingleQuotedHereString'},$true))
    Assert-Release ($bodies.Count -eq 2)
    $names=@('ReadBitLocker','ReadLaps')
    for($i=0;$i -lt 2;$i++){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($bodies[$i].Value,[ref]$t,[ref]$e);Assert-Release (@($e).Count -eq 0);[void](Assert-DomeniaWorkerOperationCode $names[$i] $bodies[$i].Value)}
}
Case 'Acces refuse reconnu en francais' {Assert-Release ((Get-DomeniaAccessFailureKind 'L acces est refuse') -eq 'AccessDenied')}
Case 'Acces refuse reconnu en anglais' {Assert-Release ((Get-DomeniaAccessFailureKind 'Access is denied') -eq 'AccessDenied')}
Case 'HRESULT acces refuse sans texte connu' {Assert-Release ((Get-DomeniaAccessFailureKind ([Runtime.InteropServices.COMException]::new('test',-2147024891))) -eq 'AccessDenied')}
Case 'HRESULT mot de passe refuse sans texte connu' {Assert-Release ((Get-DomeniaAccessFailureKind ([Runtime.InteropServices.COMException]::new('test',-2147023570))) -eq 'LogonFailure')}
Case 'D029 : mesure et purge locales ne recoivent aucun compte, meme de remplacement' {
    foreach($operation in @('StorageUsage','StoragePurge')){
        Reset-Fixture
        $credential=Fixture-Credential
        $script:Conn|Add-Member NoteProperty UseCredential $true -Force
        $script:Conn|Add-Member NoteProperty Credential $credential -Force
        $script:RemoteAdminCredential=$credential;$script:MachineCredential=$credential;$script:SecretsCredential=$credential
        $script:DirectoryCredentialFaulted=$true
        $scope=Get-DomeniaRetryScopeKey $operation
        $script:AccessState.Credentials[$scope]=$credential
        $script:AccessState.Leases[$scope]=New-DomeniaCredentialLease -Scope $scope -Account $credential.UserName -Mode Inactivity -InactivityMinutes 5 -Epoch $script:SessionEpoch -NowUtc (Get-DomeniaAccessNow)
        $script:AccessState.Faults[(Get-DomeniaAccessScope $operation)]='Refus precedent sans rapport avec la base locale'
        $context=Get-WorkerContext $operation
        Assert-Release ($null -eq $context.Credential -and $null -eq $context.MachineCredential -and $null -eq $context.RemoteAdminCredential -and -not $context.UseCredential) 'Un compte a ete transmis a une operation locale.'
    }
}
Case 'D029 : erreur locale ne propose pas un compte AD' {
    foreach($operation in @('StorageUsage','StoragePurge')){
        Reset-Fixture
        $offered=Request-DomeniaAccessRecovery -Operation 'Stockage local' -OperationId $operation -ErrorValue 'Access is denied' -Interactive
        Assert-Release (-not $offered -and $script:AccessState.Pending.Count -eq 0 -and $script:DialogCalls -eq 0)
    }
}

Case 'Timeout ne signifie pas mauvais compte' {Assert-Release (-not (Get-DomeniaAccessFailureKind 'RPC timeout serveur injoignable'))}
Case 'Refus de dechiffrement LAPS reconnu' {Assert-Release ((Get-DomeniaAccessFailureKind 'Le compte ne dispose pas du droit de dechiffrement LAPS.') -eq 'AccessDenied')}
Case 'LAPS et BitLocker ont des portees distinctes' {Assert-Release ((Get-DomeniaAccessScope 'ReadLaps') -ne (Get-DomeniaAccessScope 'ReadBitLocker'))}
Case 'Diagnostics distant partage la portee remote' {Assert-Release ((Get-DomeniaAccessScope 'ComputerDiagnostics') -eq (Get-DomeniaAccessScope 'LiveConsole'))}
Case 'Revalidation reutilise le compte de recherche' {Assert-Release ((Get-DomeniaAccessScope 'LiveDirectoryCheck') -eq (Get-DomeniaAccessScope 'GlobalSearch'))}
Case 'Refus LAPS ne marque pas BitLocker refuse' {Reset-Fixture;Set-DomeniaSecretDenied 'LAPS' $script:SelectedObject.DN;Assert-Release (Test-DomeniaSecretDenied 'LAPS' $script:SelectedObject.DN);Assert-Release (-not (Test-DomeniaSecretDenied 'BitLocker' $script:SelectedObject.DN))}
Case 'Autre cible ne reprend pas un refus local' {Assert-Release (-not (Test-DomeniaSecretDenied 'LAPS' 'CN=OTHER,DC=example,DC=invalid'))}
Case 'Compte LAPS conserve uniquement pour sa ressource' {Reset-Fixture;$c=Fixture-Credential;$script:AccessState.Credentials.ReadLaps=$c;Assert-Release ([object]::ReferenceEquals($c,(Get-DomeniaRetryCredential 'ReadLaps')));Assert-Release ($null -eq (Get-DomeniaRetryCredential 'ReadBitLocker'))}
Case 'Ancienne session ne reutilise pas le credential' {$script:SessionEpoch=2;Assert-Release ($null -eq (Get-DomeniaRetryCredential 'ReadLaps'))}
Case 'Autre domaine ne reutilise pas le credential' {Reset-Fixture;$script:AccessState.Credentials.ReadLaps=Fixture-Credential;$script:Conn.BaseDn='DC=other,DC=invalid';Assert-Release ($null -eq (Get-DomeniaRetryCredential 'ReadLaps'))}
Case 'Remplacement distant ne remplace pas le compte LDAP' {
    Reset-Fixture;$c=Fixture-Credential;$ad=Fixture-Credential 'EXAMPLE\reader';$script:AccessState.Credentials.Remote=$c
    $ctx=[pscustomobject]@{MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser='';Credential=$ad;BindUser=$ad.UserName;UseCredential=$true;AuthMode='Explicit'}
    $new=Set-DomeniaRetryWorkerContext $ctx 'ComputerLastUser'
    Assert-Release ([object]::ReferenceEquals($new.Credential,$ad) -and [object]::ReferenceEquals($new.MachineCredential,$c))
}
Case 'Compte distant temporaire ne reactive pas un bind AD rejete' {
    Reset-Fixture;$script:DirectoryCredentialFaulted=$true;$script:AccessState.Credentials.Remote=Fixture-Credential
    $blocked=$false;try{Get-WorkerContext 'LiveConsole'}catch{$blocked=$_.Exception.Message -like 'Canal Active Directory suspendu*'}
    Assert-Release $blocked
}
Case 'Rejet global du canal AD renvoie au login principal' {
    Reset-Fixture
    [void](Request-DomeniaAccessRecovery -Operation 'Sonde' -OperationId 'LiveConsole' -ErrorValue 'Canal Active Directory suspendu apres un rejet : authentification AD rejetee')
    Assert-Release (@($script:AccessState.Pending.Values)[0].Scope -eq 'Directory')
}
Case 'Notification de fond sans fenetre automatique' {Reset-Fixture;[void](Request-DomeniaAccessRecovery -Operation 'sonde' -OperationId 'LiveConsole' -ErrorValue 'Acces refuse' -Interactive);Assert-Release (-not @($script:AccessState.Pending.Values)[0].Interactive)}
Case 'Un seul avis par ressource et cible' {for($i=0;$i -lt 8;$i++){[void](Request-DomeniaAccessRecovery -Operation 'sonde' -OperationId 'LiveConsole' -ErrorValue 'Acces refuse')};Assert-Release ($script:AccessState.Pending.Count -eq 1)}
Case 'Avis sans erreur brute ni mot de passe dans son modele' {$r=@($script:AccessState.Pending.Values)[0];Assert-Release ($null -eq $r.PSObject.Properties['ErrorValue'] -and $null -eq $r.PSObject.Properties['Credential'])}
Case 'Avis de droits limite a 16 cibles' {Reset-Fixture;for($i=0;$i -lt 30;$i++){[void](Request-DomeniaAccessRecovery -Operation 'sonde' -OperationId 'LiveConsole' -DN ('CN='+$i) -ErrorValue 'Acces refuse')};Assert-Release ($script:AccessState.Pending.Count -eq 16)}
Case 'Valeur absente distinguee d un refus certain' {Reset-Fixture;[void](Request-DomeniaAccessRecovery -Operation 'LAPS' -OperationId 'ReadLaps' -Possible -ErrorValue 'aucune valeur');Assert-Release (@($script:AccessState.Pending.Values)[0].Kind -eq 'Unconfirmed')}
Case 'Annuler la proposition ne lance pas le login' {Reset-Fixture;$script:Consent=$false;Invoke-DomeniaAccessRecovery (Fixture-Record);Assert-Release ($script:ConsentCalls -eq 1 -and $script:DialogCalls -eq 0 -and $script:AccessState.Credentials.Count -eq 0)}
Case 'Annuler le login conserve le precedent credential' {Reset-Fixture;$old=Fixture-Credential 'EXAMPLE\old';$script:AccessState.Credentials.ReadLaps=$old;Invoke-DomeniaAccessRecovery (Fixture-Record);Assert-Release ([object]::ReferenceEquals($script:AccessState.Credentials.ReadLaps,$old) -and $script:RetryCalls.Count -eq 0)}
Case 'Validation LAPS relance seulement la lecture et une fois' {Reset-Fixture;$script:NextCredential=Fixture-Credential;Invoke-DomeniaAccessRecovery (Fixture-Record);Assert-Release ($script:RetryCalls.Count -eq 1 -and $script:RetryCalls[0].Mode -eq 'LAPS' -and $script:RetryCalls[0].RetryAttempt -eq 1 -and $script:AccessState.Credentials.ContainsKey('ReadLaps'))}
Case 'Ancienne selection ne relance pas sa lecture' {Reset-Fixture;$r=Fixture-Record;$script:SelectedObjectGeneration++;$script:NextCredential=Fixture-Credential;Invoke-DomeniaAccessRecovery $r;Assert-Release ($script:RetryCalls.Count -eq 0)}
Case 'Action ecriture jamais rejouee par le login' {Reset-Fixture;$script:NextCredential=Fixture-Credential;Invoke-DomeniaAccessRecovery (Fixture-Record 'WriteRename' -Write);Assert-Release ($script:AccessState.Credentials.ContainsKey('AD:WriteRename') -and $script:RetryCalls.Count -eq 0)}
Case 'Etat d ecriture inconnu empeche le changement de compte' {Reset-Fixture;$script:WriteState='Unknown';$script:NextCredential=Fixture-Credential;Invoke-DomeniaAccessRecovery (Fixture-Record);Assert-Release ($script:DialogCalls -eq 0 -and $script:AccessState.Credentials.Count -eq 0)}
Case 'Erreur d une ancienne session n ouvre pas un login' {Reset-Fixture;$r=Fixture-Record;$script:SessionEpoch=2;Invoke-DomeniaAccessRecovery $r;Assert-Release ($script:ConsentCalls -eq 0)}
Case 'Largeurs invalides ignorees et bornes appliquees' {
    $input=@([pscustomobject]@{Key='A';Unit='Pixel';Width='-50';Index='0'},[pscustomobject]@{Key='B';Unit='Star';Width='900';Index='1'},[pscustomobject]@{Key='C';Unit='Pixel';Width='NaN';Index='2'})
    $out=ConvertTo-DomeniaColumnLayout $input
    Assert-Release ($out.Count -eq 2 -and $out[0].Width -eq 32 -and $out[1].Width -eq 20)
}
Case 'Unites de largeur inconnues refusees' {$out=ConvertTo-DomeniaColumnLayout @([pscustomobject]@{Key='A';Unit='Other';Width=20;Index=0});Assert-Release ($out.Count -eq 0)}
Case 'Colonnes dupliquees ignorees' {$out=ConvertTo-DomeniaColumnLayout @([pscustomobject]@{Key='A';Unit='Pixel';Width=70;Index=0},[pscustomobject]@{Key='A';Unit='Pixel';Width=80;Index=1});Assert-Release ($out.Count -eq 1)}
Case 'JSON de preferences trop grand ignore' {Assert-Release ((ConvertTo-DomeniaStateMap (' '*524289)).Count -eq 0)}
Case 'JSON invalide ignore sans reinitialiser le programme' {Assert-Release ((ConvertTo-DomeniaStateMap '{nope').Count -eq 0)}
Case 'OU hors du domaine non restauree' {$r=ConvertTo-DomeniaTreeBookmark ([pscustomobject]@{Selected='OU=X,DC=other,DC=invalid';Expanded=@();Subtree=$true}) 'DC=example,DC=invalid';Assert-Release ($null -eq $r)}
Case 'OU exacte et branches conservees sans reconstruction LDAP' {
    $r=ConvertTo-DomeniaTreeBookmark ([pscustomobject]@{Selected='OU=A\,B,DC=example,DC=invalid';Expanded=@('DC=example,DC=invalid','DC=other,DC=invalid');Subtree='false'}) 'DC=example,DC=invalid'
    Assert-Release ($r.Selected -ceq 'OU=A\,B,DC=example,DC=invalid' -and $r.Expanded.Count -eq 1 -and -not $r.Subtree)
}
Case 'WPF : ordre et tailles font un aller retour JSON sans lignes' {
    Reset-Fixture
    $g=[Windows.Controls.DataGrid]::new();$g.Name='TestGrid'
    foreach($key in @('Name','Login','DN')){$c=[Windows.Controls.DataGridTextColumn]::new();$c.Header=$key;$c.SortMemberPath=$key;$c.Width=[Windows.Controls.DataGridLength]::new(150);[void]$g.Columns.Add($c)}
    $script:Continuity=[pscustomobject]@{Applying=$false;Grids=@{};Layouts=@{}}
    Register-DomeniaGridLayout $g;$g.Columns[2].DisplayIndex=0;$g.Columns[1].Width=[Windows.Controls.DataGridLength]::new(257)
    Save-DomeniaGridLayout $g
    $serialized=[string]$script:SettingsFixture.GridLayoutsJson
    Assert-Release ($serialized -and -not $serialized.Contains('ItemsSource'))
    $script:Continuity.Layouts=ConvertTo-DomeniaStateMap $serialized
    $g.Columns[2].DisplayIndex=2;$g.Columns[1].Width=[Windows.Controls.DataGridLength]::new(40)
    Register-DomeniaGridLayout $g
    Assert-Release ($g.Columns[2].DisplayIndex -eq 0 -and $g.Columns[1].Width.Value -eq 257)
}
Case 'WPF : XAML principal charge et boutons conserves' {
    $r=[Xml.XmlNodeReader]::new([xml](Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)));$w=$null
    try{$w=[Windows.Markup.XamlReader]::Load($r);Assert-Release ($null -ne $w.FindName('BtnAccessRecovery') -and $null -ne $w.FindName('BtnLoadLaps') -and $null -ne $w.FindName('BtnLoadBitLocker') -and $null -ne $w.FindName('TvDirectory'))}finally{$r.Close();if($null -ne $w){$w.Close()}}
}
Case 'WPF : dialogue credentials reel en clair et sombre sans authentification' {
    $a=$null;$z=$null;$accessAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Access.UI.ps1'),[ref]$a,[ref]$z)
    $x=@($accessAst.FindAll({param($a)$a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.Value.StartsWith('<Window ')},$true))[0].Value
    foreach($theme in @('Light','Dark')){
        $text=Convert-DomeniaXamlToBootTheme -Xaml $x -Theme $theme
        $reader=[Xml.XmlNodeReader]::new([xml]$text);$window=$null
        try{$window=[Windows.Markup.XamlReader]::Load($reader);Assert-Release ($null -ne $window.FindName('Password') -and $window.ResizeMode -eq 'NoResize')}finally{$reader.Close();if($null -ne $window){$window.Close()}}
    }
}
Case 'FI-14 plafond du runtime lu dans le contrat, alerte a 80 %' {
    $contract=[IO.File]::ReadAllText((Join-Path $root 'tools\release-contract.json'))|ConvertFrom-Json
    $release=[IO.File]::ReadAllText((Join-Path $wad 'Domenia.release.json'))|ConvertFrom-Json
    $limit=[int]$contract.RuntimeFileLimit
    Assert-Release ($limit -ge 10) 'RuntimeFileLimit absent du contrat de release.'
    Assert-Release ([int]$release.RuntimeFileLimit -eq $limit) 'wad\Domenia.release.json non estampille depuis le contrat (release_contract.py --stamp).'
    Assert-Release ([IO.File]::ReadAllText((Join-Path $wad 'Domenia-Start.ps1')) -match 'RuntimeFileLimit') 'Domenia-Start ne lit pas le plafond du contrat.'
    $prod=[IO.File]::ReadAllText((Join-Path $root 'tools\prod-manifest.json'))|ConvertFrom-Json
    $count=@($prod.Files|Where-Object{$_.Runtime -eq $true}).Count
    # Alert before the ceiling: a lot that adds runtime files (CD-01) must raise the reviewed limit first.
    Assert-Release ($count -lt (0.8*$limit)) ('Alerte : '+$count+' fichiers runtime pour un plafond de '+$limit+' (80 % atteints). Relever RuntimeFileLimit dans tools\release-contract.json.')
}
Case 'SP-09 Test-DomeniaSignature rend integrite et editeur separement, hors ligne' {
    $dist=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-signature-test-'+[guid]::NewGuid().ToString('N'))
    try {
        $content=[ordered]@{'wad/Domenia-Start.ps1'="Write-Output 'fixture'`n";'wad/modules/Kit.json'='{"Kit":1}'}
        $entries=@()
        foreach($rel in @($content.Keys)){
            $path=Join-Path $dist $rel;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::WriteAllText($path,$content[$rel],[Text.UTF8Encoding]::new($true))
            $entries+=[pscustomobject]@{Path=$rel;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]::new($path)).Length;Runtime=$true;PreserveExisting=$false}
        }
        [IO.File]::WriteAllText((Join-Path $dist 'wad\package-manifest.json'),([pscustomobject]@{Format=1;Build='fixture-signature';Files=$entries}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        $tool=Join-Path $root 'tools\Test-DomeniaSignature.ps1'
        $v=@(& $tool -Root $dist -PassThru -Quiet -ReportPath (Join-Path $dist 'r1.json'))|Select-Object -Last 1
        Assert-Release ($LASTEXITCODE -eq 0) 'Distribution intacte refusee alors que la signature est facultative.'
        Assert-Release (($v.Integrity.Status -eq 'Conforme') -and ($v.Publisher.Status -eq 'Editeur attendu non configure')) ($v.Integrity.Status+' / '+$v.Publisher.Status)
        Assert-Release ($v.Offline -and (-not $v.RevocationChecked)) 'Controle annonce en ligne.'
        $p=@(& $tool -Root $dist -PublisherThumbprint ('AB'*20) -RequireSignature -PassThru -Quiet -ReportPath (Join-Path $dist 'r2.json'))|Select-Object -Last 1
        Assert-Release ($LASTEXITCODE -ne 0) 'Signature exigee mais distribution non signee acceptee.'
        Assert-Release (($p.Integrity.Status -eq 'Conforme') -and ($p.Publisher.Status -eq 'Editeur non prouve') -and $p.Publisher.Pinned) ($p.Integrity.Status+' / '+$p.Publisher.Status)
        [IO.File]::AppendAllText((Join-Path $dist 'wad\modules\Kit.json'),' ')
        $m=@(& $tool -Root $dist -PassThru -Quiet -ReportPath (Join-Path $dist 'r3.json'))|Select-Object -Last 1
        Assert-Release ($LASTEXITCODE -ne 0) 'Fichier modifie accepte.'
        Assert-Release (($m.Integrity.Status -eq 'Modifiee') -and ($m.Publisher.Status -eq 'Editeur attendu non configure') -and (@($m.Integrity.Modified) -contains 'wad/modules/Kit.json')) ($m.Integrity.Status+' / '+$m.Publisher.Status)
        [IO.File]::WriteAllText((Join-Path $dist 'wad\modules\Kit.json'),'{"Kit":1}',[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $dist 'wad\Ajout.ps1'),'1',[Text.UTF8Encoding]::new($true))
        $u=@(& $tool -Root $dist -PassThru -Quiet -ReportPath (Join-Path $dist 'r4.json'))|Select-Object -Last 1
        Assert-Release (($LASTEXITCODE -ne 0) -and ($u.Integrity.Status -eq 'Modifiee') -and (@($u.Integrity.Undeclared) -contains 'wad/Ajout.ps1')) 'Script ajoute non signale.'
        # Lab tools and history stay in the repository, out of the DEV package (SE-15): never an undeclared addition.
        Remove-Item -LiteralPath (Join-Path $dist 'wad\Ajout.ps1') -Force
        [void][IO.Directory]::CreateDirectory((Join-Path $dist 'engineering\d120\lab'));[IO.File]::WriteAllText((Join-Path $dist 'engineering\d120\lab\Outil-Labo.ps1'),'1',[Text.UTF8Encoding]::new($true))
        $l=@(& $tool -Root $dist -PassThru -Quiet -ReportPath (Join-Path $dist 'r5.json'))|Select-Object -Last 1
        Assert-Release (($LASTEXITCODE -eq 0) -and ($l.Integrity.Status -eq 'Conforme')) ('Outil du labo compte comme ajout : '+(@($l.Integrity.Undeclared) -join ', '))
        # Beside a PROD manifest, code left by a previous version (installer never deletes it) is reported apart.
        [IO.File]::WriteAllText((Join-Path $dist 'wad\package-manifest.json'),([pscustomobject]@{Format=1;Build='fixture-signature';Edition='prod';Files=$entries}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        [void][IO.Directory]::CreateDirectory((Join-Path $dist 'wad\tests'));[IO.File]::WriteAllText((Join-Path $dist 'wad\tests\Test-Ancien.ps1'),'1',[Text.UTF8Encoding]::new($true))
        $k=@(& $tool -Root $dist -PassThru -Quiet -ReportPath (Join-Path $dist 'r6.json'))|Select-Object -Last 1
        Assert-Release (($LASTEXITCODE -eq 0) -and ($k.Integrity.Status -eq 'Conforme') -and (@($k.Integrity.KeptOutsideManifest) -contains 'wad/tests/Test-Ancien.ps1')) ('Copie DEV mise a jour en PROD : '+$k.Integrity.Status)
    } finally {Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue}
}
Case 'SP-09 Verifier-Paquet : outil de signature du verificateur seulement, jamais lance sur une copie en erreur' {
    # Run as VERIFIER-PACK.cmd does (powershell -File). The examined copy carries its own tools\Test-DomeniaSignature.ps1,
    # which must never run: it would write the marker file.
    $dist=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-verifier-test-'+[guid]::NewGuid().ToString('N'))
    $marker=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-verifier-marker-'+[guid]::NewGuid().ToString('N')+'.txt')
    try {
        $content=[ordered]@{
            'wad/Domenia-Start.ps1'="Write-Output 'fixture'`n";'wad/Domenia-Core.ps1'="Write-Output 'core'`n";'wad/modules/Kit.json'='{"Kit":1}'
            'wad/modules/Fixture.Model.ps1'="function Get-Fixture {1}`n";'tools/Test-DomeniaSignature.ps1'=("[IO.File]::WriteAllText('"+$marker+"','copie')`n")
        }
        $entries=@()
        foreach($rel in @($content.Keys)){
            $path=Join-Path $dist $rel;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::WriteAllText($path,$content[$rel],[Text.UTF8Encoding]::new($true))
            $entries+=[pscustomobject]@{Path=$rel;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]::new($path)).Length;Runtime=$true;PreserveExisting=$false}
        }
        [IO.File]::WriteAllText((Join-Path $dist 'wad\package-manifest.json'),([pscustomobject]@{Format=1;Build='fixture-verifier';Edition='dev';Files=$entries}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        $verifier=Join-Path $wad 'maintenance\Verifier-Paquet.ps1'
        # The verifier reports a failure on stderr: read as data here, not as an error of this suite.
        $run={param([string]$Report) $ErrorActionPreference='Continue';$null=& (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -File $verifier -Root $dist -Quiet -ReportPath $Report 2>&1;return $LASTEXITCODE}
        $errorsOf={param($Report) (@($Report.Files|Where-Object{$_.State -eq 'ERROR'}|ForEach-Object{$_.File+' : '+$_.Detail}) -join ' | ')}
        $code=& $run (Join-Path $dist 'v1.json')
        $v=[IO.File]::ReadAllText((Join-Path $dist 'v1.json'))|ConvertFrom-Json
        Assert-Release (($code -eq 0) -and ($v.Failed -eq 0) -and ($v.Signature.Integrity -eq 'Conforme')) ('Copie intacte : code '+$code+' / '+(& $errorsOf $v)+' / '+($v.Signature|ConvertTo-Json -Compress))
        Assert-Release (-not [IO.File]::Exists($marker)) 'Outil de signature pris dans la copie examinee.'
        [IO.File]::AppendAllText((Join-Path $dist 'wad\modules\Kit.json'),' ')
        $code=& $run (Join-Path $dist 'v2.json')
        $e=[IO.File]::ReadAllText((Join-Path $dist 'v2.json'))|ConvertFrom-Json
        Assert-Release (($code -ne 0) -and ($e.Failed -eq 1) -and ([string]$e.Signature.Skipped -match 'non lanc')) ('Copie en erreur : code '+$code+' / '+($e.Signature|ConvertTo-Json -Compress))
        Assert-Release (-not [IO.File]::Exists($marker)) 'Code de la copie execute malgre les erreurs.'
    } finally {Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue}
}
Case 'SP-09 preuve reelle : copie signee de la composition PROD, certificat de test jamais approuve' {
    # Real Authenticode on the real PROD composition. The test certificate is self-signed with an ephemeral CNG key held
    # in memory (CertificateRequest): it is placed in no certificate store, Root included, so Windows does not trust it.
    # The publisher therefore stays unproven while the signer thumbprint, the pinned binaries, the signed catalog and a
    # modified byte are all read for real. (New-SelfSignedCertificate needs CertEnroll and a loaded profile, absent from
    # the guest sessions of the lab.)
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-sign-proof-'+[guid]::NewGuid().ToString('N'))
    $cert=$null;$key=$null
    try {
        $prod=[IO.File]::ReadAllText((Join-Path $root 'tools\prod-manifest.json'))|ConvertFrom-Json
        foreach($f in @($prod.Files)){
            $to=Join-Path $stage ([string]$f.Path);[void][IO.Directory]::CreateDirectory((Split-Path $to -Parent));[IO.File]::Copy((Join-Path $root ([string]$f.Path)),$to,$false)
        }
        [void][IO.Directory]::CreateDirectory((Join-Path $stage 'tools'));[IO.File]::Copy((Join-Path $root 'tools\prod-manifest.json'),(Join-Path $stage 'tools\prod-manifest.json'),$false)
        $key=[Security.Cryptography.RSACng]::new(2048)
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new(('CN=Domenia test signature '+[guid]::NewGuid().ToString('N').Substring(0,8)),$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $usage=New-Object Security.Cryptography.OidCollection;[void]$usage.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usage,$false))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
        $cert=$request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-5),[DateTimeOffset]::Now.AddDays(1))
        # Same signing as Signer-Distribution (scripts only, SHA-256), then the delivered manifest of the signed copy.
        $scripts=@($prod.Files|Where-Object{[string]$_.Path -match '\.ps1$'})
        foreach($f in $scripts){[void](Set-AuthenticodeSignature -FilePath (Join-Path $stage ([string]$f.Path)) -Certificate $cert -HashAlgorithm SHA256)}
        $entries=@($prod.Files|ForEach-Object{$p=Join-Path $stage ([string]$_.Path);[pscustomobject]@{Path=[string]$_.Path;Sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]::new($p)).Length;Runtime=$true;PreserveExisting=[bool]$_.PreserveExisting}})
        $manifestFile=Join-Path $stage 'wad\package-manifest.json'
        [IO.File]::WriteAllText($manifestFile,([pscustomobject]@{Format=1;Build=[string]$prod.Build;Edition='prod';Files=$entries}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        $tool=Join-Path $root 'tools\Test-DomeniaSignature.ps1'
        $v=@(& $tool -Root $stage -PublisherThumbprint $cert.Thumbprint -PassThru -Quiet -ReportPath (Join-Path $stage 'r1.json'))|Select-Object -Last 1
        Assert-Release ($LASTEXITCODE -eq 0) 'Copie intacte refusee alors que la signature est facultative.'
        Assert-Release ($v.Integrity.Status -eq 'Conforme') ('Integrite : '+$v.Integrity.Status+' '+(@($v.Integrity.Modified) -join ', '))
        $signedRows=@($v.Files|Where-Object{$_.Path -match '\.ps1$'})
        Assert-Release ($signedRows.Count -eq $scripts.Count) ('Scripts examines : '+$signedRows.Count)
        Assert-Release (@($signedRows|Where-Object{$_.SignerThumbprint -cne $cert.Thumbprint}).Count -eq 0) 'Empreinte du signataire non lue sur un script signe.'
        Assert-Release (@($signedRows|Where-Object{$_.AuthenticodeStatus -eq 'Valid'}).Count -eq 0) 'Certificat de test approuve par le poste : il ne doit jamais etre dans Root.'
        Assert-Release ($v.Publisher.Status -eq 'Editeur non prouve') ('Editeur : '+$v.Publisher.Status)
        $contract=[IO.File]::ReadAllText((Join-Path $root 'tools\release-contract.json'))|ConvertFrom-Json
        $expectedPinned=@($contract.Components|Where-Object{$_.Pinned -eq $true})
        $actualPinned=@($v.Publisher.PinnedComponents)
        Assert-Release (($expectedPinned.Count -gt 0) -and ($actualPinned.Count -eq $expectedPinned.Count)) 'Nombre de binaires figes different du contrat de livraison.'
        foreach($component in $expectedPinned){
            $componentPath=([string]$component.Path).Replace('\','/')
            Assert-Release (@($actualPinned|Where-Object{([string]$_).Replace('\','/') -ceq $componentPath}).Count -eq 1) ('Binaire fige absent ou duplique : '+$componentPath)
            $componentRows=@($v.Files|Where-Object{([string]$_.Path).Replace('\','/') -ceq $componentPath})
            $actualComponentSha=(Get-FileHash -LiteralPath (Join-Path $stage $componentPath) -Algorithm SHA256).Hash
            Assert-Release (($componentRows.Count -eq 1) -and ($componentRows[0].Scope -ceq 'Empreinte epinglee') -and ($actualComponentSha -ieq [string]$component.Sha256)) ('Empreinte differente du contrat : '+$componentPath)
        }
        Assert-Release (@($v.Files|Where-Object{($_.Scope -eq 'Empreinte epinglee') -and (-not $_.PublisherVerified)}).Count -eq 0) 'Binaire fige different de son empreinte epinglee.'
        Assert-Release (@($v.Publisher.ManifestOnly).Count -ge 8) 'Fichiers non signables non listes a part.'
        $null=@(& $tool -Root $stage -PublisherThumbprint $cert.Thumbprint -RequireSignature -PassThru -Quiet -ReportPath (Join-Path $stage 'r2.json'))
        Assert-Release ($LASTEXITCODE -ne 0) 'Signature exigee acceptee avec un certificat non approuve.'
        # Signed catalog of the delivered manifest: read for real, bound to this exact manifest.
        $catalog=[IO.Path]::ChangeExtension($manifestFile,'.cat')
        [void](New-FileCatalog -Path $manifestFile -CatalogFilePath $catalog -CatalogVersion 2.0)
        [void](Set-AuthenticodeSignature -FilePath $catalog -Certificate $cert -HashAlgorithm SHA256)
        $c=@(& $tool -Root $stage -PublisherThumbprint $cert.Thumbprint -PassThru -Quiet -ReportPath (Join-Path $stage 'r3.json'))|Select-Object -Last 1
        Assert-Release (($c.Publisher.ManifestCatalogMatch -eq 'Valid') -and (-not $c.Publisher.ManifestSigned)) ('Catalogue : '+$c.Publisher.ManifestCatalogMatch+' / '+$c.Publisher.ManifestSigned)
        # One byte changed in one signed script: HashMismatch for that file only, distribution modified.
        $target=Join-Path $stage 'wad\modules\Domenia-Common.Model.ps1'
        $bytes=[IO.File]::ReadAllBytes($target);$index=[Array]::IndexOf($bytes,[byte]0x65,3);$bytes[$index]=[byte]0x45;[IO.File]::WriteAllBytes($target,$bytes)
        $m=@(& $tool -Root $stage -PublisherThumbprint $cert.Thumbprint -PassThru -Quiet -ReportPath (Join-Path $stage 'r4.json'))|Select-Object -Last 1
        Assert-Release ($LASTEXITCODE -ne 0) 'Octet modifie accepte.'
        $mismatch=@($m.Files|Where-Object{$_.AuthenticodeStatus -eq 'HashMismatch'}|ForEach-Object{$_.Path})
        Assert-Release (($mismatch.Count -eq 1) -and ($mismatch[0] -eq 'wad/modules/Domenia-Common.Model.ps1')) ('HashMismatch : '+($mismatch -join ', '))
        Assert-Release (($m.Integrity.Status -eq 'Modifiee') -and (@($m.Integrity.Modified).Count -eq 1) -and ($m.Publisher.Status -eq 'Signature invalide')) ($m.Integrity.Status+' / '+$m.Publisher.Status)
        # The manifest changed after its catalog was signed: the catalog no longer matches.
        [IO.File]::AppendAllText($manifestFile,' ')
        $x=@(& $tool -Root $stage -PublisherThumbprint $cert.Thumbprint -PassThru -Quiet -ReportPath (Join-Path $stage 'r5.json'))|Select-Object -Last 1
        Assert-Release (($x.Publisher.ManifestCatalogMatch -ne 'Valid') -and ($x.Publisher.Status -eq 'Signature invalide')) ('Catalogue apres modification : '+$x.Publisher.ManifestCatalogMatch+' / '+$x.Publisher.Status)
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        if($null -ne $cert){$cert.Dispose()};if($null -ne $key){$key.Dispose()}
    }
}
$bad=@($script:Tests|Where-Object{-not $_.Passed})
$report=[ordered]@{Build='2026.09.30-DOMENIA-1.0-RC1';Environment='Windows PowerShell 5.1 / WPF';NoNetwork=$true;Passed=$script:Tests.Count-$bad.Count;Failed=$bad.Count;Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-R1.13-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host ('Rapport : '+$ReportPath)
if($bad.Count){throw ('Echecs : '+$bad.Count)}
