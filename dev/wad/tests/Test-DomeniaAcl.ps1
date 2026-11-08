#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Ce test local exige Windows PowerShell 5.1. Il ne demande pas une elevation.'
}
$wad=Split-Path -Parent $PSScriptRoot
$script:AclChecks=[Collections.Generic.List[object]]::new()
$script:AclAst=@{}
$script:AclCalls=@{}
$script:AclBuilt=@{}
$script:AclFixture=''
$script:AclFixtureOwned=$false
$script:AclNativeCalled=$false
$script:AclNativeSucceeded=$false
$fixtureId=[guid]::NewGuid().ToString('N')
$script:AclFixture=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-AclTest-'+$fixtureId)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $script:AclSid=$identity.User.Value
    $elevated=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} finally { $identity.Dispose() }

function Check {
    param([string]$Label,[scriptblock]$Body)
    try { & $Body | Out-Null; $script:AclChecks.Add([pscustomobject]@{Name=$Label;Passed=$true;Error=''}) }
    catch { $script:AclChecks.Add([pscustomobject]@{Name=$Label;Passed=$false;Error=$_.Exception.Message}) }
}
function Require { param([bool]$Value,[string]$Message='Assertion non verifiee.'); if(-not $Value){throw $Message} }
function Parse-AclTestText {
    param([string]$Text)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){ throw (($errors | ForEach-Object {'Ligne '+$_.Extent.StartLineNumber+' : '+$_.Message}) -join '; ') }
    return $ast
}
function Find-AclTestFunction {
    param($Ast,[string]$Name)
    $found=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    Require ($found.Count -eq 1) ('Fonction absente ou ambigue : '+$Name)
    return $found[0]
}
function Find-AclCall {
    param($Ast)
    $found=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'SetSecurityDescriptorSddlForm'},$true))
    Require ($found.Count -eq 1) 'Un appel SDDL etait attendu.'
    return $found[0]
}
function Get-AclDirtyFlags {
    param([Security.AccessControl.DirectorySecurity]$Acl)
    $result=@{}
    foreach($n in @('_daclModified','_saclModified','_ownerModified','_groupModified')){
        $field=[Security.AccessControl.ObjectSecurity].GetField($n,[Reflection.BindingFlags]'Instance,NonPublic')
        Require ($null -ne $field) ('Champ de test .NET absent : '+$n)
        $result[$n]=[bool]$field.GetValue($Acl)
    }
    return $result
}
function Apply-AclProductionExpression {
    param([string]$Site,[Security.AccessControl.DirectorySecurity]$Acl)
    # Exactement l'expression extraite du runtime. Rien d'autre n'est execute.
    $sid=$script:AclSid
    & ([scriptblock]::Create($script:AclCalls[$Site].Extent.Text))
}
function Read-AclBasic {
    param([string]$Path)
    $parts=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    return [IO.Directory]::GetAccessControl($Path,$parts)
}
function Require-PrivateDacl {
    param([Security.AccessControl.DirectorySecurity]$Acl)
    Require $Acl.AreAccessRulesProtected 'La DACL doit etre protegee contre l heritage.'
    $rules=@($Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $expected=@($script:AclSid,'S-1-5-18','S-1-5-32-544' | Sort-Object -Unique)
    $actual=@($rules | ForEach-Object {$_.IdentityReference.Value} | Sort-Object -Unique)
    Require (($actual -join '|') -ceq ($expected -join '|')) 'Principaux inattendus dans la DACL.'
    foreach($rule in $rules){
        Require ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow)
        Require (-not $rule.IsInherited)
        Require (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
        Require ($rule.InheritanceFlags -eq ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit))
    }
}

try {
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
    Check 'Analyse native du coeur, sans demarrage' { $script:AclAst.Core=Parse-AclTestText $coreText }
    $receiptText=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Receipts.Worker.ps1'))
    Check 'Analyse native du module recus' { $script:AclAst.ReceiptModule=Parse-AclTestText $receiptText }
    Check 'Extraction du worker recus, sans mutation' {
        $fn=Find-AclTestFunction $script:AclAst.ReceiptModule 'Get-DomeniaReceiptsCommon'
        $literals=[regex]::Matches($fn.Extent.Text,'(?ms)@''\r?\n(.*?)\r?\n''@')
        Require ($literals.Count -eq 1)
        $script:AclAst.Receipts=Parse-AclTestText $literals[0].Groups[1].Value
    }
    Check 'Analyse du worker distant assemble, sans acces reseau' {
        $parts=[regex]::Matches($coreText,'(?ms)^\$script:WorkerCommon (?:=|\+=) @''\r?\n(.*?)\r?\n''@')
        Require ($parts.Count -gt 0)
        $script:AclAst.Remote=Parse-AclTestText ((@($parts | ForEach-Object {$_.Groups[1].Value})) -join "`r`n")
    }
    $sites=@(
        @{Name='DataStore';Ast='Core';Function='Initialize-DomeniaDataStore'},
        @{Name='Receipts';Ast='Receipts';Function='Get-WReceiptRoot'},
        @{Name='Remote';Ast='Remote';Function='Invoke-WRemoteScheduledTaskScript'}
    )
    foreach($site in $sites){
        $name=$site.Name
        Check ($name+' : surcharge a deux arguments, Access seul') {
            $fn=Find-AclTestFunction $script:AclAst[$site.Ast] $site.Function
            $call=Find-AclCall $fn
            Require ($call.Arguments.Count -eq 2)
            Require ($call.Arguments[1].Extent.Text -match '^\[Security\.AccessControl\.AccessControlSections\]::Access$')
            $script:AclCalls[$name]=$call
            $acl=[Security.AccessControl.DirectorySecurity]::new()
            Apply-AclProductionExpression $name $acl
            $script:AclBuilt[$name]=$acl
        }
        Check ($name+' : DACL marquee modifiee') { Require (Get-AclDirtyFlags $script:AclBuilt[$name])._daclModified }
        Check ($name+' : audit non marque modifie') { Require (-not (Get-AclDirtyFlags $script:AclBuilt[$name])._saclModified) }
        Check ($name+' : proprietaire non marque modifie') { Require (-not (Get-AclDirtyFlags $script:AclBuilt[$name])._ownerModified) }
        Check ($name+' : groupe non marque modifie') { Require (-not (Get-AclDirtyFlags $script:AclBuilt[$name])._groupModified) }
        Check ($name+' : DACL explicite et protegee') {
            Require $script:AclBuilt[$name].AreAccessRulesProtected
            Require ($script:AclBuilt[$name].GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access).StartsWith('D:P'))
        }
        Check ($name+' : SACL, proprietaire et groupe conserves en memoire') {
            # Descriptor temoin uniquement en memoire. Aucune SACL n'est lue/ecrite sur disque.
            $acl=[Security.AccessControl.DirectorySecurity]::new()
            $acl.SetSecurityDescriptorSddlForm(('O:'+$script:AclSid+'G:'+$script:AclSid+'D:P(A;OICI;FA;;;SY)S:(AU;OICISAFA;FA;;;WD)'),[Security.AccessControl.AccessControlSections]::All)
            $untouched=[Security.AccessControl.AccessControlSections]::Audit -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
            $before=$acl.GetSecurityDescriptorSddlForm($untouched)
            Apply-AclProductionExpression $name $acl
            Require ($before -ceq $acl.GetSecurityDescriptorSddlForm($untouched))
        }
    }
    Check 'Regression RC1 : surcharge courte marque Audit, Owner et Group' {
        $old=[Security.AccessControl.DirectorySecurity]::new()
        $old.SetSecurityDescriptorSddlForm(('O:'+$script:AclSid+'G:'+$script:AclSid+'D:P(A;OICI;FA;;;'+$script:AclSid+')(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'))
        $flags=Get-AclDirtyFlags $old
        Require ($flags._saclModified -and $flags._ownerModified -and $flags._groupModified)
        # Ne jamais persister ce descriptor volontairement defectueux.
    }
    Check 'Permissions locales privees inchangees' { Require-PrivateDacl $script:AclBuilt.DataStore }
    Check 'Permissions des recus privees inchangees' { Require-PrivateDacl $script:AclBuilt.Receipts }
    Check 'Depot distant restreint a SYSTEM et Administrateurs' {
        $rules=@($script:AclBuilt.Remote.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Require ($rules.Count -eq 2)
        Require ((@($rules | ForEach-Object {$_.IdentityReference.Value} | Sort-Object) -join '|') -eq 'S-1-5-18|S-1-5-32-544')
    }
    Check 'Creation du bac a sable local unique' {
        Require (-not $script:AclFixture.StartsWith('\\')) 'Le dossier temporaire doit etre local.'
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:AclFixture))
        Require ($drive.DriveType -ne [IO.DriveType]::Network) 'Les dossiers temporaires reseau ne sont pas testes.'
        Require (-not (Test-Path -LiteralPath $script:AclFixture))
        $cursor=[IO.DirectoryInfo]::new([IO.Path]::GetFullPath($script:AclFixture))
        while($null -ne $cursor){if($cursor.Exists){Require (-not ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint))};$cursor=$cursor.Parent}
        [void][IO.Directory]::CreateDirectory($script:AclFixture)
        $script:AclFixtureOwned=$true
    }
    if(-not $script:AclFixtureOwned){throw 'Bac a sable indisponible : aucun test de persistance lance.'}
    Check 'Enregistrement natif DACL seulement sur dossier local de test' {
        $path=Join-Path $script:AclFixture 'Local'
        [void][IO.Directory]::CreateDirectory($path)
        $before=Read-AclBasic $path
        $script:AclNativeCalled=$true
        [IO.Directory]::SetAccessControl($path,$script:AclBuilt.DataStore)
        $script:AclNativeSucceeded=$true
        $after=Read-AclBasic $path
        Require-PrivateDacl $after
        Require ($before.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $after.GetOwner([Security.Principal.SecurityIdentifier]).Value)
        Require ($before.GetGroup([Security.Principal.SecurityIdentifier]).Value -eq $after.GetGroup([Security.Principal.SecurityIdentifier]).Value)
    }
    Check 'Nouvelle application de la meme DACL sans privilege supplementaire' {
        $path=Join-Path $script:AclFixture 'Local'
        $acl=[Security.AccessControl.DirectorySecurity]::new();Apply-AclProductionExpression 'DataStore' $acl
        [IO.Directory]::SetAccessControl($path,$acl)
        Require-PrivateDacl (Read-AclBasic $path)
    }
    Check 'Fichier enfant inscriptible apres protection' {
        $path=Join-Path $script:AclFixture 'Local\temoin.txt'
        [IO.File]::WriteAllText($path,'contenu de test sans secret')
        Require ([IO.File]::ReadAllText($path) -ceq 'contenu de test sans secret')
    }
    Check 'Racine des recus : vraie fonction sur chemin de test' {
        $fn=Find-AclTestFunction $script:AclAst.Receipts 'Get-WReceiptRoot'
        $definition=$fn.Extent.Text -replace '^function\s+Get-WReceiptRoot\b','function script:Get-WReceiptRoot'
        Invoke-Expression $definition
        $path=Join-Path $script:AclFixture 'Receipts'
        $result=Get-WReceiptRoot ([pscustomobject]@{ReceiptRoot=$path})
        Require ($result -eq $path)
        Require-PrivateDacl (Read-AclBasic $path)
    }
    Check 'Racine des recus : nouvelle ouverture idempotente' {
        $path=Join-Path $script:AclFixture 'Receipts'
        $null=Get-WReceiptRoot ([pscustomobject]@{ReceiptRoot=$path})
        Require-PrivateDacl (Read-AclBasic $path)
    }
    Check 'Erreur de racine des recus non ignoree' {
        $failed=$false
        try { Get-WReceiptRoot ([pscustomobject]@{ReceiptRoot=''}) | Out-Null } catch { $failed=$true }
        Require $failed
    }
    Check 'Le stockage ne doit pas etre valide si la protection echoue' {
        $fn=Find-AclTestFunction $script:AclAst.Core 'Initialize-DomeniaDataStore'
        $text=$fn.Extent.Text
        Require ($text.IndexOf('DOMENIA_STORE_DACL') -lt $text.IndexOf('$script:DataStoreValidated=$true'))
        Require ($text -match 'throw \[InvalidOperationException\]::new')
    }
} catch {
    $script:AclChecks.Add([pscustomobject]@{Name='Preparation de la suite';Passed=$false;Error=$_.Exception.Message})
} finally {
    Check 'Nettoyage limite au bac a sable cree par ce test' {
        if($script:AclFixtureOwned -and [IO.Directory]::Exists($script:AclFixture)){
            Require (([IO.Path]::GetFileName($script:AclFixture)) -ceq ('Domenia-AclTest-'+$fixtureId))
            Require (-not ((Get-Item -LiteralPath $script:AclFixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))
            Remove-Item -LiteralPath $script:AclFixture -Recurse -Force -ErrorAction Stop
        }
        Require (-not (Test-Path -LiteralPath $script:AclFixture))
    }
}
$failed=@($script:AclChecks | Where-Object {-not $_.Passed})
$result=[ordered]@{
    Build='2026.10.01-DOMENIA-1.0-RC1.1-ACL';Host=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString
    ExpectedTests=38;Complete=($script:AclChecks.Count -eq 38);Elevated=[bool]$elevated;Passed=$script:AclChecks.Count-$failed.Count;Failed=$failed.Count
    NativeAclAttempted=[bool]$script:AclNativeCalled;NativeAclSucceeded=[bool]$script:AclNativeSucceeded;LiveSaclReadOrWrite=$false;WpfExecuted=$false;ADAccess=$false;RemoteAccess=$false
    ProductionDataAccess=$false;Tests=$script:AclChecks.ToArray()
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-ACL-'+$fixtureId+'.json')}
[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:AclChecks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($failed.Count -or $script:AclChecks.Count -ne 38){exit 1};exit 0
