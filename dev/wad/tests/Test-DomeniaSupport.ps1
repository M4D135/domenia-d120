#requires -Version 5.1
<# R1.5: actual local model/UI functions, no domain, no network, no application startup.
   Optional -Wpf loads the actual host XAML and local view, never the main program.
   All account/object names and data below are synthetic. No real credentials.
#>
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet,[switch]$Wpf)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$moduleRoot=Join-Path $root 'wad\modules'
$script:TestResults=New-Object Collections.ArrayList
$script:CoreSource=[IO.File]::ReadAllText((Join-Path $root 'wad\Domenia-Core.ps1'))
function Assert-SupportTest { param([bool]$Condition,[string]$Message='Assertion fausse');if(-not $Condition){throw $Message} }
function Assert-SupportThrows {
    param([scriptblock]$Action,[string]$Pattern='.')
    $message='';try {& $Action | Out-Null} catch {$message=$_.Exception.Message}
    Assert-SupportTest ($message -match $Pattern) ('Exception attendue : '+$Pattern+' ; recue : '+$message)
}
function Invoke-SupportTest {
    param([string]$Name,[scriptblock]$Action)
    try {& $Action | Out-Null;$status='PASS';$detail=''} catch {$status='FAIL';$detail=$_.Exception.ToString()}
    [void]$script:TestResults.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})
    if(-not $Quiet -or $status -eq 'FAIL'){Write-Host ($status+' | '+$Name+' | '+$detail)}
}
# Native parsing is required before dot-sourcing the additive files.
foreach($path in @((Join-Path $moduleRoot 'Domenia-Support.Model.ps1'),(Join-Path $moduleRoot 'Domenia-Support.UI.ps1'),(Join-Path $root 'wad\Domenia-Core.ps1'))){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -gt 0){throw ('Syntaxe native : '+$path+' : '+$errors[0].Message)}
}
. (Join-Path $moduleRoot 'Domenia-Support.Model.ps1')
. (Join-Path $moduleRoot 'Domenia-Support.UI.ps1')
function New-SupportFixture {
    param([Collections.IDictionary]$Properties=@{},[string]$Type='Utilisateur',[string]$Source='Live',[string]$Dn='CN=Alice,DC=example,DC=test')
    New-DomeniaSupportSnapshot -Properties $Properties -Scope 'DC=example,DC=test' -Dn $Dn -Name 'Alice Test' -Type $Type -Source $Source
}
function Get-FixtureCodes { param($Snapshot);return @(Get-DomeniaSupportFindings -Snapshot $Snapshot | ForEach-Object {$_.Code}) }
Invoke-SupportTest 'Allowlist excludes dedicated secrets and free-text notes' {
    $names=@(Get-DomeniaSupportFieldNames)
    Assert-SupportTest ($names.Count -eq 29)
    foreach($name in @('unicodePwd','msLAPS-Password','ms-Mcs-AdmPwd','msFVE-RecoveryPassword','description','info','userCertificate')){Assert-SupportTest ($names -notcontains $name) $name}
}
Invoke-SupportTest 'Snapshot does not mutate source and does not retain its arrays' {
    $props=@{memberOf=@('CN=A','CN=B');department=@('Support');'msLAPS-Password'=@('NOT-FOR-EXPORT')}
    $snap=New-SupportFixture $props
    Assert-SupportTest ($props['msLAPS-Password'][0] -eq 'NOT-FOR-EXPORT')
    $props.memberOf[0]='CN=Changed'
    Assert-SupportTest ($snap.Fields.memberOf[0] -eq 'CN=A')
    Assert-SupportTest (-not $snap.Fields.Contains('msLAPS-Password'))
}
Invoke-SupportTest 'Missing attribute and explicit empty attribute have different coverage' {
    $a=New-SupportFixture @{};$b=New-SupportFixture @{department=@()}
    Assert-SupportTest ($a.Coverage.department -eq 'NotProvided')
    Assert-SupportTest ($b.Coverage.department -eq 'Provided')
    $diff=@(Compare-DomeniaSupportSnapshots $a $b)
    Assert-SupportTest ($diff.Count -eq 1 -and $diff[0].Status -eq 'Indetermine')
}
Invoke-SupportTest 'Explicit empty values compare as known empty' {
    $a=New-SupportFixture @{department=@()};$b=New-SupportFixture @{department=@('Support')}
    $row=@(Compare-DomeniaSupportSnapshots $a $b)[0]
    Assert-SupportTest ($row.Status -eq 'Different' -and $row.Before -eq '')
}
Invoke-SupportTest 'Dedicated credentials, secure strings and opaque bytes are excluded' {
    $secret=ConvertTo-SecureString 'SYNTHETIC-SECRET' -AsPlainText -Force
    $credential=New-Object Management.Automation.PSCredential('EXAMPLE\test',$secret)
    Assert-SupportTest ((ConvertTo-DomeniaSupportText $credential) -eq '[valeur exclue]')
    Assert-SupportTest ((ConvertTo-DomeniaSupportText $secret) -eq '[valeur exclue]')
    Assert-SupportTest ((ConvertTo-DomeniaSupportText ([byte[]]@(1,2,3))) -eq '[valeur exclue]')
}
Invoke-SupportTest 'Truncated text is marked partial and bounded' {
    $snap=New-SupportFixture @{department=@(('X'*8000))}
    Assert-SupportTest ($snap.Coverage.department -eq 'Partial')
    Assert-SupportTest ($snap.Fields.department[0].Length -lt 1050)
}
Invoke-SupportTest 'Accidental credential text is masked and never compared as complete' {
    $snap=New-SupportFixture @{department=@('password=SYNTHETIC-SECRET')}
    Assert-SupportTest ($snap.Coverage.department -eq 'Partial')
    Assert-SupportTest ((Get-DomeniaSupportField $snap department) -notmatch 'SYNTHETIC-SECRET')
}
Invoke-SupportTest 'Recovery password and bearer patterns are masked' {
    $text=ConvertTo-DomeniaSupportText '111111-222222-333333-444444-555555-666666-777777-888888 Bearer TESTONLY'
    Assert-SupportTest ($text -notmatch '111111|TESTONLY')
}
Invoke-SupportTest 'Multivalue capture is bounded to 128 values' {
    $vals=@(1..200 | ForEach-Object {'CN=G'+$_})
    $s=New-SupportFixture @{memberOf=$vals}
    Assert-SupportTest ($s.Coverage.memberOf -eq 'Partial' -and $s.Fields.memberOf.Count -eq 128)
}
Invoke-SupportTest 'Ranged memberships are not treated as complete' {
    $s=New-SupportFixture @{'memberOf;range=0-1499'=@('CN=A')}
    Assert-SupportTest ($s.Coverage.memberOf -eq 'Partial')
}
Invoke-SupportTest 'Group ordering and case are not a change' {
    $a=New-SupportFixture @{memberOf=@('CN=A','CN=B')};$b=New-SupportFixture @{memberOf=@('cn=b','cn=a','CN=A')}
    $row=@(Compare-DomeniaSupportSnapshots $a $b)[0]
    Assert-SupportTest ($row.Status -eq 'Identique' -and $row.Added -eq '' -and $row.Removed -eq '')
}
Invoke-SupportTest 'Direct group additions and removals are separate' {
    $a=New-SupportFixture @{memberOf=@('CN=A','CN=B')};$b=New-SupportFixture @{memberOf=@('CN=B','CN=C')}
    $row=@(Compare-DomeniaSupportSnapshots $a $b)[0]
    Assert-SupportTest ($row.Status -eq 'Different' -and $row.Added -eq 'CN=C' -and $row.Removed -eq 'CN=A')
}
Invoke-SupportTest 'Partial membership never yields a deletion claim' {
    $a=New-SupportFixture @{memberOf=@('CN=A')};$b=New-SupportFixture @{'memberOf;range=0-9'=@('CN=B')}
    $row=@(Compare-DomeniaSupportSnapshots $a $b)[0]
    Assert-SupportTest ($row.Status -eq 'Indetermine' -and $row.Removed -eq '')
}
Invoke-SupportTest 'Different domain scopes are refused' {
    $a=New-SupportFixture @{};$b=New-DomeniaSupportSnapshot -Properties @{} -Scope 'DC=other,DC=test' -Dn 'CN=B,DC=other,DC=test'
    Assert-SupportThrows {Compare-DomeniaSupportSnapshots $a $b} 'perimetres'
}
Invoke-SupportTest 'Different object types are refused' {
    $a=New-SupportFixture @{};$b=New-SupportFixture @{} -Type 'Machine'
    Assert-SupportThrows {Compare-DomeniaSupportSnapshots $a $b} 'types'
}
Invoke-SupportTest 'Object GUID preserves identity through DN changes' {
    $props=@{objectGUID=@('00000000-1111-2222-3333-444444444444')}
    $a=New-SupportFixture $props;$b=New-SupportFixture $props -Dn 'CN=Renamed,DC=example,DC=test'
    Assert-SupportTest ($a.Identity -eq $b.Identity -and $a.Identity -like 'guid:*')
}
Invoke-SupportTest 'Difference-only excludes identical fields' {
    $a=New-SupportFixture @{name=@('A');department=@('X')};$b=New-SupportFixture @{name=@('A');department=@('Y')}
    $diff=@(Compare-DomeniaSupportSnapshots $a $b -DifferencesOnly)
    Assert-SupportTest ($diff.Count -eq 1 -and $diff[0].Attribute -eq 'department')
}
Invoke-SupportTest 'Unknown UAC is not interpreted as enabled' {
    $codes=Get-FixtureCodes (New-SupportFixture @{})
    Assert-SupportTest ($codes -contains 'UAC_UNKNOWN' -and $codes -notcontains 'NO_FINDING')
}
Invoke-SupportTest 'ACCOUNTDISABLE uses bit 2, not any nonzero UAC' {
    Assert-SupportTest ((Get-FixtureCodes (New-SupportFixture @{userAccountControl=@(514)})) -contains 'ACCOUNT_DISABLED')
    Assert-SupportTest ((Get-FixtureCodes (New-SupportFixture @{userAccountControl=@(512)})) -notcontains 'ACCOUNT_DISABLED')
}
Invoke-SupportTest 'Historical lockoutTime alone is not a current lock' {
    $codes=Get-FixtureCodes (New-SupportFixture @{userAccountControl=@(512);lockoutTime=@(12345)})
    Assert-SupportTest ($codes -contains 'LOCKOUT_HISTORY' -and $codes -notcontains 'ACCOUNT_LOCKED')
}
Invoke-SupportTest 'Computed lock and expiration flags are distinct' {
    $codes=Get-FixtureCodes (New-SupportFixture @{'msDS-User-Account-Control-Computed'=@(8388624)})
    Assert-SupportTest ($codes -contains 'ACCOUNT_LOCKED' -and $codes -contains 'PASSWORD_EXPIRED')
}
Invoke-SupportTest 'pwdLastSet zero accounts for DONT_EXPIRE_PASSWORD' {
    $yes=Get-FixtureCodes (New-SupportFixture @{pwdLastSet=@(0);userAccountControl=@(512)})
    $review=Get-FixtureCodes (New-SupportFixture @{pwdLastSet=@(0);userAccountControl=@(66048)})
    Assert-SupportTest ($yes -contains 'PASSWORD_CHANGE_REQUIRED')
    Assert-SupportTest ($review -notcontains 'PASSWORD_CHANGE_REQUIRED' -and $review -contains 'PASSWORD_STATE_REVIEW')
}
Invoke-SupportTest 'accountExpires sentinel values are not expiration dates' {
    foreach($value in @([long]0,[long]::MaxValue)){
        $codes=Get-FixtureCodes (New-SupportFixture @{accountExpires=@($value);userAccountControl=@(512)})
        Assert-SupportTest ($codes -notcontains 'ACCOUNT_EXPIRED' -and $codes -notcontains 'EXPIRY_INVALID')
    }
}
Invoke-SupportTest 'Past and upcoming account expirations are distinct' {
    $past=Get-FixtureCodes (New-SupportFixture @{accountExpires=@([datetime]::UtcNow.AddDays(-2).ToFileTimeUtc())})
    $soon=Get-FixtureCodes (New-SupportFixture @{accountExpires=@([datetime]::UtcNow.AddDays(3).ToFileTimeUtc())})
    Assert-SupportTest ($past -contains 'ACCOUNT_EXPIRED' -and $soon -contains 'ACCOUNT_EXPIRING')
}
Invoke-SupportTest 'Out-of-range expiration is unknown, not expired' {
    $codes=Get-FixtureCodes (New-SupportFixture @{accountExpires=@(([long]::MaxValue-1))})
    Assert-SupportTest ($codes -contains 'EXPIRY_INVALID' -and $codes -notcontains 'ACCOUNT_EXPIRED')
}
Invoke-SupportTest 'Fresh capture does not make cache a fresh AD read' {
    $s=New-SupportFixture @{userAccountControl=@(512)} -Source 'Cache'
    Assert-SupportTest ((Get-FixtureCodes $s) -contains 'DATA_NOT_LIVE')
}
Invoke-SupportTest 'Old live read is signaled after local threshold' {
    $s=New-DomeniaSupportSnapshot -Properties @{userAccountControl=@(512)} -Scope 'DC=example,DC=test' -Dn 'CN=A' -Type 'Utilisateur' -Source Live -ObservedAtUtc ([datetime]::UtcNow.AddMinutes(-16))
    Assert-SupportTest ((Get-FixtureCodes $s) -contains 'DATA_OLD')
}
Invoke-SupportTest 'Missing machine DNS is not called offline' {
    $findings=@(Get-DomeniaSupportFindings (New-SupportFixture @{userAccountControl=@(4096)} -Type 'Machine'))
    Assert-SupportTest (@($findings | Where-Object {$_.Code -eq 'DNS_NOT_PROVIDED'}).Count -eq 1)
    Assert-SupportTest (@($findings | Where-Object {$_.Title -match 'hors ligne'}).Count -eq 0)
}
Invoke-SupportTest 'adminCount is a review marker, not a privilege verdict' {
    $f=@(Get-DomeniaSupportFindings (New-SupportFixture @{adminCount=@(1)})) | Where-Object {$_.Code -eq 'ADMINCOUNT'}
    Assert-SupportTest ($f.Level -eq 'Information' -and $f.Basis -eq 'Limite')
}
Invoke-SupportTest 'Invalid numeric flags stay unknown' {
    $codes=Get-FixtureCodes (New-SupportFixture @{userAccountControl=@('not a number')})
    Assert-SupportTest ($codes -contains 'UAC_UNKNOWN' -and $codes -notcontains 'ACCOUNT_DISABLED')
}
Invoke-SupportTest 'Each incident rule recognizes a representative message' {
    $cases=@{SMB_SESSION_CONFLICT='error 1219';CANCELLED='BeginStop sans retour';AUTH_CONTEXT='0x8007052e';ACCESS_DENIED='0x80070005';RPC_UNAVAILABLE='0x800706ba';TIMEOUT='timeout';DNS_NETWORK='0x80070035';ENGINE_BUSY='limite physique';PSEXEC_LICENSE='SYSINTERNALS SOFTWARE LICENSE'}
    foreach($key in $cases.Keys){Assert-SupportTest (@((Get-DomeniaSupportIncidentHints $cases[$key]).Code) -contains $key) $key}
}
Invoke-SupportTest 'Incident can keep multiple contributing observations' {
    $hints=@(Get-DomeniaSupportIncidentHints 'Annulation apres timeout, acces refuse 0x80070005')
    Assert-SupportTest ($hints.Code -contains 'CANCELLED' -and $hints.Code -contains 'TIMEOUT' -and $hints.Code -contains 'ACCESS_DENIED')
}
Invoke-SupportTest 'Unrecognized incident is not assigned an invented cause' {
    $hints=@(Get-DomeniaSupportIncidentHints 'Synthetic unclassified message')
    Assert-SupportTest ($hints.Count -eq 1 -and $hints[0].Code -eq 'UNCLASSIFIED')
}
Invoke-SupportTest 'Very long incident text stays bounded' {
    $i=New-DomeniaSupportIncident ('x'*100000)
    Assert-SupportTest ($i.Detail.Length -lt 4120)
}
Invoke-SupportTest 'Bounded ring accepts empty ArrayList and keeps the newest 200' {
    $list=New-Object Collections.ArrayList
    foreach($n in 1..350){Add-DomeniaSupportBoundedItem -Items $list -Item $n -Limit 200}
    Assert-SupportTest ($list.Count -eq 200 -and $list[0] -eq 151 -and $list[199] -eq 350)
}
Invoke-SupportTest 'Incident filtering is literal, not regex or wildcards' {
    Assert-SupportTest (Test-DomeniaSupportLiteralMatch -Text 'Message [test]' -Query '[test]')
    Assert-SupportTest (-not (Test-DomeniaSupportLiteralMatch -Text 'Message test' -Query '.*'))
    Assert-SupportTest (Test-DomeniaSupportLiteralMatch -Text 'MESSAGE test' -Query 'message')
}
Invoke-SupportTest 'Report excludes dedicated secrets and raw log details' {
    $s=New-SupportFixture @{name=@('Alice');department=@('Helpdesk');'msFVE-RecoveryPassword'=@('DO-NOT-EXPORT');description=@('DO-NOT-EXPORT')}
    $incident=New-DomeniaSupportIncident 'timeout RAW-LOG-MUST-NOT-LEAVE'
    $report=New-DomeniaSupportReport -Snapshot $s -Incident $incident
    Assert-SupportTest ($report -notmatch 'DO-NOT-EXPORT|RAW-LOG-MUST-NOT-LEAVE')
    Assert-SupportTest ($report -match 'Helpdesk' -and $report -match 'TIMEOUT')
}
Invoke-SupportTest 'Different-object report is not labeled as object history' {
    $a=New-SupportFixture @{};$b=New-SupportFixture @{} -Dn 'CN=Bob,DC=example,DC=test'
    $report=New-DomeniaSupportReport -Before $a -After $b
    Assert-SupportTest ($report -match 'PAS un historique')
}
Invoke-SupportTest 'HTML escapes report markup, quotes and ampersands' {
    $html=ConvertTo-DomeniaSupportHtml '<script>alert("TEST")</script>&<img src=x onerror=alert(1)>'
    Assert-SupportTest ($html -notmatch '<script|<img')
    Assert-SupportTest ($html -match '&lt;script&gt;' -and $html -match '&amp;')
    Assert-SupportTest ($html -match 'default-src &#39;none&#39;|default-src ''none''')
}
# UI adapter tests: in-memory mocks, never WPF and never a domain request.
function Get-DomeniaControl {param([string]$Name);if($script:Ctrl.ContainsKey($Name)){return $script:Ctrl[$Name]};return $null}
function Set-DomeniaControlText {param([string]$Name,[AllowEmptyString()][string]$Text);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Set-DomeniaItemsSource {param([string]$Name,$Rows);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Items=@($Rows);$c.SelectedItem=$null;$c.SelectedIndex=-1};return $true}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:LastWorkspace=$Workspace}
function Open-AdObject {param($Dn,$Type);$script:OpenCalls++;$script:OpenedDn=$Dn}
function Reset-SupportUiFixture {
    $script:Ctrl=@{}
    [xml]$xaml=[IO.File]::ReadAllText((Join-Path $moduleRoot 'Domenia-Support.xaml'))
    foreach($el in $xaml.SelectNodes('//*')){
        $name=$el.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if($name){$script:Ctrl[$name]=[pscustomobject]@{Text='';Items=@();SelectedItem=$null;SelectedIndex=-1;IsChecked=$false;IsSelected=$true}}
    }
    $script:Ctrl['TabSupport']=[pscustomobject]@{IsSelected=$true}
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test';BindUser='EXAMPLE\reader'}
    $script:SessionEpoch=1L;$script:Window=$null;$script:SupportView=[pscustomobject]@{};$script:SupportTimer=$null
    $script:SelectedObject=$null;$script:CurrentObjectRequestDn='';$script:SelectedObjectGeneration=0L
    $script:OpenCalls=0;$script:OpenedDn='';$script:MasterBuild='SYNTHETIC-TEST'
    Reset-DomeniaSupportSession
}
function Set-SupportUiFixtureObject {
    param([string]$Dn='CN=Alice,DC=example,DC=test')
    $script:SelectedObject=[pscustomobject]@{DN=$Dn;Name='Alice';Type='Utilisateur';Entry=[pscustomobject]@{Properties=@{name=@('Alice');userAccountControl=@(512)}}}
    $script:SelectedObjectGeneration++
    Set-DomeniaSupportObjectSource -Dn $Dn -IsLive $true
}
Invoke-SupportTest 'Session epoch resets captures even for the same account' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;Set-DomeniaSupportCapture A
    $script:SessionEpoch++;Sync-DomeniaSupportSession
    Assert-SupportTest ($null -eq $script:SupportState.A -and $script:SupportState.Pins.Count -eq 0)
}
Invoke-SupportTest 'Account or domain changes clear local incidents and pins' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;Add-DomeniaSupportPin;Add-DomeniaSupportIncidentFromLog 'timeout' WARN Test
    $script:Conn.BaseDn='DC=other,DC=test';Sync-DomeniaSupportSession
    Assert-SupportTest ($script:SupportState.Pins.Count -eq 0 -and $script:SupportState.Incidents.Count -eq 0)
}
Invoke-SupportTest 'Capture refuses the stale object while another DN is loading' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;$script:CurrentObjectRequestDn='CN=Bob,DC=example,DC=test'
    Assert-SupportThrows {Set-DomeniaSupportCapture B} 'chargement'
    Assert-SupportTest ($null -eq $script:SupportState.B)
}
Invoke-SupportTest 'Automatic local view can wait for another object without failing' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;$script:CurrentObjectRequestDn='CN=Bob,DC=example,DC=test'
    Update-DomeniaSupportView -Force
    Assert-SupportTest ($script:Ctrl.LblSupportContext.Text -match 'chargement')
}
Invoke-SupportTest 'Manual A and B captures are distinct and stable' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;Set-DomeniaSupportCapture A
    $script:SelectedObject.Entry.Properties.name[0]='Updated';Set-DomeniaSupportCapture B
    Assert-SupportTest ($script:SupportState.A.Fields.name[0] -eq 'Alice' -and $script:SupportState.B.Fields.name[0] -eq 'Updated')
}
Invoke-SupportTest 'Pinning an existing object deduplicates without a read' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;Add-DomeniaSupportPin;Add-DomeniaSupportPin
    Assert-SupportTest ($script:SupportState.Pins.Count -eq 1 -and $script:OpenCalls -eq 0)
}
Invoke-SupportTest 'Pins enforce their 24 item limit' {
    Reset-SupportUiFixture
    foreach($i in 1..24){Set-SupportUiFixtureObject ('CN=User'+$i+',DC=example,DC=test');Add-DomeniaSupportPin}
    Set-SupportUiFixtureObject 'CN=Overflow,DC=example,DC=test'
    Assert-SupportThrows {Add-DomeniaSupportPin} '24'
    Assert-SupportTest ($script:SupportState.Pins.Count -eq 24)
}
Invoke-SupportTest 'Only opening a selected pin invokes the existing read path' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;Add-DomeniaSupportPin
    $script:Ctrl.DgSupportPins.SelectedItem=$script:SupportState.Pins[0]
    Open-DomeniaSupportPin
    Assert-SupportTest ($script:OpenCalls -eq 1 -and $script:OpenedDn -eq 'CN=Alice,DC=example,DC=test')
}
Invoke-SupportTest 'Pin keeps its exact real DN, not the redacted display representation' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject 'CN=password=fiction,DC=example,DC=test';Add-DomeniaSupportPin
    Assert-SupportTest ($script:SupportState.Pins[0].Dn -eq $script:SelectedObject.DN)
}
Invoke-SupportTest 'Capture provenance distinguishes cache from AD' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject
    Set-DomeniaSupportObjectSource -Dn $script:SelectedObject.DN -IsLive $false
    Assert-SupportTest ((Get-DomeniaSupportCurrentSnapshot).Source -eq 'Cache')
}
Invoke-SupportTest 'Adjacent duplicate warnings are coalesced, info is ignored' {
    Reset-SupportUiFixture
    Add-DomeniaSupportIncidentFromLog 'timeout' WARN Test
    Add-DomeniaSupportIncidentFromLog 'timeout' WARN Test
    Add-DomeniaSupportIncidentFromLog 'info' INFO Test
    Assert-SupportTest ($script:SupportState.Incidents.Count -eq 1)
}
Invoke-SupportTest 'Incident inclusion requires explicit manual selection' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject
    $script:Ctrl.ChkSupportIncludeIncident.IsChecked=$true
    Assert-SupportThrows {New-DomeniaSupportUiReport} 'Choisis un incident'
}
Invoke-SupportTest 'Clear workspace leaves the original selected object unchanged' {
    Reset-SupportUiFixture;Set-SupportUiFixtureObject;Set-DomeniaSupportCapture A
    $before=$script:SelectedObject
    Reset-DomeniaSupportSession
    Assert-SupportTest ([object]::ReferenceEquals($before,$script:SelectedObject))
    Assert-SupportTest ($null -eq $script:SupportState.A)
}
if($Wpf){
    # A real Window/XAML test, deliberately separate from the no-WPF installer tests.
    Invoke-SupportTest 'WPF host and Atelier view load with native namescopes and both themes' {
        Assert-SupportTest ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') 'Lancer Windows PowerShell avec -STA.'
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($script:CoreSource,[ref]$tokens,[ref]$errors)
        $defs=New-Object Collections.Generic.List[string]
        foreach($name in @('Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Set-DomeniaItemsSource','Apply-DomeniaTheme','Select-DomeniaWorkspace')){
            $wanted=$name;$nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted},$true))
            Assert-SupportTest ($nodes.Count -eq 1) ('Unique : '+$name)
            $defs.Add($nodes[0].Extent.Text)
        }
        . ([scriptblock]::Create(($defs.ToArray() -join "`n")))
        function Add-DomeniaUiLog {param($Area,$Level,$Text)}
        function Write-AppLog {param($Message,$Level);if($Level -eq 'WARN' -or $Level -eq 'ERROR'){throw $Message}}
        $script:Ctrl=@{};$script:SupportView=$null;$script:SupportTimer=$null
        $hostXml=Get-MainXaml
        $script:Window=[Windows.Markup.XamlReader]::Parse($hostXml)
        foreach($name in @('WorkspaceTabs','TxtUiLog','LogPanel','BtnThemeToggle','ThemeIconCircle','ThemeIconGlyph')){
            $ctrl=$script:Window.FindName($name);if($null -ne $ctrl){$script:Ctrl[$name]=$ctrl}
        }
        $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test';BindUser='EXAMPLE\test'};$script:SelectedObject=$null
        try{
            Initialize-DomeniaSupportUi
            $script:SupportTimer.Stop()
            $script:Ctrl.TabSupport.IsSelected=$true
            foreach($theme in @('Dark','Light','Dark')){
                Apply-DomeniaTheme $theme
                $script:Window.Measure((New-Object Windows.Size(1200,800)))
                $script:Window.Arrange((New-Object Windows.Rect(0,0,1200,800)))
                $script:Window.UpdateLayout()
                $view=$script:SupportView
                Assert-SupportTest ($view.Foreground.Color -eq $script:Window.Resources['TextColor'].Color) ('Texte vue : '+$theme)
                $script:Ctrl.SupportTabs.SelectedItem=$script:Ctrl.SupportReportTab
                $script:Window.UpdateLayout()
                Assert-SupportTest ($script:Ctrl.TxtSupportReport.Foreground.Color -eq $script:Window.Resources['TextColor'].Color) ('Texte rapport : '+$theme)
                Assert-SupportTest ($script:Ctrl.TxtSupportReport.Background.Color -ne $script:Ctrl.TxtSupportReport.Foreground.Color) ('Contraste rapport : '+$theme)
            }
            $script:Ctrl.SupportTabs.SelectedItem=$script:Ctrl.SupportAnalysisTab
            [void](Set-DomeniaItemsSource DgSupportFindings @([pscustomobject]@{Level='Information';Title='Test';Evidence='Synthetic'}))
            Assert-SupportTest ($script:Ctrl.DgSupportFindings.Items.Count -eq 1)
            Assert-SupportTest ($script:Ctrl.DgSupportFindings.EnableRowVirtualization -and $script:Ctrl.DgSupportFindings.IsReadOnly)
        } finally {
            Stop-DomeniaSupportUi
            if($null -ne $script:Window){$script:Window.Close()}
        }
    }
}
$passed=@($script:TestResults | Where-Object {$_.Status -eq 'PASS'}).Count
$failed=@($script:TestResults | Where-Object {$_.Status -eq 'FAIL'}).Count
if([string]::IsNullOrWhiteSpace($ReportPath)){
    $folder=Join-Path $root 'wad\data\TestReports'
    [void][IO.Directory]::CreateDirectory($folder)
    $ReportPath=Join-Path $folder ('Support-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
}
$report=[ordered]@{Build='R1.5-ATELIER';PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();Utc=[datetime]::UtcNow.ToString('o');DomainContacted=$false;WpfRequested=[bool]$Wpf;Passed=$passed;Failed=$failed;Results=$script:TestResults.ToArray()}
$json=$report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($ReportPath,$json,(New-Object Text.UTF8Encoding($false)))
Write-Host ('Atelier : '+$passed+' PASS, '+$failed+' FAIL. Rapport : '+$ReportPath)
if($failed -gt 0){throw ('Tests Atelier en echec : '+$failed)}
