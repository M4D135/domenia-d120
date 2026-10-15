#requires -Version 5.1
<# Point 106 : qualification de l'etat Windows LAPS (schema, expiration, capacite de lecture, secret a la demande).
   Partie hors ligne, toujours executee : vraies regles et vrai code du coeur analyses (AST), sans reseau.
   Partie en direct, seulement avec -Live -Computer NOM, dans le domaine de laboratoire : lecture LDAP du schema et des
   SEULS attributs d'expiration du poste, avec l'identite Windows courante. Aucun mot de passe n'est demande, lu,
   affiche ni ecrit ; Get-LapsADPassword n'est jamais appele (seule sa presence est constatee).
   Les quatre scenarios de qualification manuelle sont rendus comme non executes : jamais comptes comme reussis.
#>
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet,[switch]$Live,[string]$Computer='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Condition,[string]$Message='Assertion fausse');if(-not $Condition){throw $Message}}
function Case {
    param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)})}
}
function Read-SourceAst {
    param([string]$Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ($Path+' ligne '+$errors[0].Extent.StartLineNumber+' : '+$errors[0].Message)}
    return $ast
}
function Get-FunctionText {
    param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $Name)},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $nodes[0].Extent.Text
}
function Get-CallSites {
    # Names of the functions that contain a call to $Command (file level when outside any function).
    param($Ast,[string]$Command)
    foreach($call in @($Ast.FindAll({param($n)($n -is [Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq $Command)},$true))){
        $parent=$call.Parent
        while(($null -ne $parent) -and ($parent -isnot [Management.Automation.Language.FunctionDefinitionAst])){$parent=$parent.Parent}
        if($null -eq $parent){'(fichier)'}else{$parent.Name}
    }
}
$infrastructure=$true
try{
    if(($PSVersionTable.PSEdition -ne 'Desktop') -or ($PSVersionTable.PSVersion.Major -ne 5) -or (-not [Environment]::Is64BitProcess)){
        throw 'Windows PowerShell 5.1 x64 requis ; une execution sous un autre moteur ne vaut pas qualification.'
    }
    foreach($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Search.Model.ps1','Domenia-Directory.Model.ps1','Domenia-Safety.Model.ps1')){
        [void](Read-SourceAst (Join-Path $modules $file))
        . (Join-Path $modules $file)
    }
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    $script:CoreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    $script:AccessUiAst=Read-SourceAst (Join-Path $modules 'Domenia-Access.UI.ps1')
    . ([scriptblock]::Create((Get-FunctionText $script:CoreAst 'Test-DomeniaSensitiveAttributeName')))
}catch{
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1 et sources analysees';Status='Failed';Detail=$_.Exception.ToString()})
}
$script:Secrets=@('ms-Mcs-AdmPwd','msLAPS-Password','msLAPS-EncryptedPassword','msLAPS-EncryptedPasswordHistory','msLAPS-EncryptedDSRMPassword')
$script:Expirations=@('ms-Mcs-AdmPwdExpirationTime','msLAPS-PasswordExpirationTime')

if($infrastructure){
    Case 'Schema et expiration lus avec les postes, jamais le mot de passe' {
        $plan=[regex]::Match($script:CoreText,'\$computerPlan\s*=\s*@\{[^\r\n]*')
        Expect $plan.Success 'Plan de lecture des postes introuvable'
        foreach($name in $script:Expirations){Expect ($plan.Value -match ("'"+[regex]::Escape($name)+"'")) ('Expiration non lue : '+$name)}
        foreach($name in $script:Secrets){Expect (-not ($plan.Value -match ("'"+[regex]::Escape($name)+"'"))) ('Secret lu avec les postes : '+$name)}
        Expect ($script:CoreText -match [regex]::Escape("(&(objectClass=attributeSchema)(|(lDAPDisplayName=ms-Mcs-AdmPwdExpirationTime)(lDAPDisplayName=msLAPS-PasswordExpirationTime)))")) 'Detection du schema absente'
        Expect (($script:CoreText -match "\`$lapsKind = 'NoSchema'") -and ($script:CoreText -match "\`$lapsKind = 'None'")) 'Absence de schema et absence de valeur non distinguees'
    }
    Case 'Attributs secrets exclus de la fiche, expirations conservees' {
        foreach($name in $script:Secrets){Expect (Test-DomeniaSensitiveAttributeName $name) ('Secret non filtre : '+$name)}
        foreach($name in $script:Expirations){Expect (-not (Test-DomeniaSensitiveAttributeName $name)) ('Expiration filtree a tort : '+$name)}
    }
    Case 'Secret lu seulement sur un geste explicite, avec le compte LAPS' {
        $sites=@(@(Get-CallSites $script:CoreAst 'Start-LoadComputerSecrets')+@(Get-CallSites $script:AccessUiAst 'Start-LoadComputerSecrets')|Sort-Object -Unique)
        Expect ((@($sites|Where-Object{$_ -notin @('Wire-Events','Build-DomeniaObjectsContextMenu','Invoke-DomeniaAccessRecovery')})).Count -eq 0) ('Appel non explicite : '+($sites -join ', '))
        $wire=Get-FunctionText $script:CoreAst 'Wire-Events'
        Expect ($wire -match [regex]::Escape('$script:Ctrl["BtnLoadLaps"].Add_Click({ Start-LoadComputerSecrets -Mode "LAPS" })')) 'Bouton LAPS non raccorde au geste'
        $needs=Get-DomeniaOperationCredentialNeeds 'ReadLaps'
        Expect ($needs.Secrets -and ($needs.Resource -eq 'Laps')) 'Compte ou ressource LAPS non distincts'
        Expect ((Get-DomeniaOperationEffect 'ReadLaps') -eq 'Read')
    }
    Case 'Etats LAPS explicables sans secret : historique, Windows LAPS, module absent, droit refuse, expiration' {
        $now=[datetime]::SpecifyKind([datetime]'2026-10-15T10:00:00',[DateTimeKind]::Utc)
        $legacy=ConvertTo-DomeniaLapsView ([pscustomobject]@{Source='LegacyLaps';Published=$true;ReadStatus='OK';DecryptStatus='NotEncrypted';PasswordPresent=$true;ExpirationUtc=$now.AddDays(-1)}) $now
        Expect ($legacy.State -eq 'Available' -and (@($legacy.Facts|Where-Object{$_.Fait -eq 'Expiration'})[0].Valeur -match 'echue'))
        $windows=ConvertTo-DomeniaLapsView ([pscustomobject]@{Source='WindowsLaps';Published=$true;ReadStatus='OK';DecryptStatus='OK';PasswordPresent=$true;ExpirationUtc=$now.AddDays(10)}) $now
        Expect ($windows.State -eq 'Available' -and $windows.CanReveal)
        $module=ConvertTo-DomeniaLapsView ([pscustomobject]@{Source='WindowsLaps';ReadStatus='ModuleMissing'}) $now
        Expect ($module.State -eq 'Prerequisite' -and -not $module.CanReveal)
        $denied=ConvertTo-DomeniaLapsView ([pscustomobject]@{Source='WindowsLaps';Published=$true;ReadStatus='OK';DecryptStatus='Unauthorized';PasswordPresent=$false}) $now
        Expect ($denied.State -eq 'DecryptDenied' -and $denied.OfferOtherAccount -and -not $denied.HasPassword)
        $hidden=ConvertTo-DomeniaLapsView ([pscustomobject]@{ReadStatus='Unconfirmed'}) $now
        Expect ($hidden.State -eq 'Unconfirmed' -and $hidden.OfferOtherAccount) 'Attribut confidentiel illisible presente comme absent'
        foreach($view in @($legacy,$windows,$module,$denied,$hidden)){Expect (-not (($view|ConvertTo-Json -Depth 4) -match '"Password"')) 'Valeur secrete dans la vue'}
    }
    if($Live){
        Case 'En direct : schema LAPS et expiration du poste lus avec l identite courante, sans secret' {
            if($Computer -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'){throw 'Parametre -Computer requis (nom court du poste de laboratoire).'}
            $requested=@('name','distinguishedName')+$script:Expirations
            foreach($name in $requested){Expect (-not (Test-DomeniaSensitiveAttributeName $name)) ('Attribut secret demande : '+$name)}
            $root=New-Object DirectoryServices.DirectoryEntry 'LDAP://RootDSE'
            try{$schemaNc=[string]$root.Properties['schemaNamingContext'].Value;$defaultNc=[string]$root.Properties['defaultNamingContext'].Value}finally{$root.Dispose()}
            $schema=New-Object DirectoryServices.DirectorySearcher -ArgumentList @((New-Object DirectoryServices.DirectoryEntry ('LDAP://'+$schemaNc)),'(&(objectClass=attributeSchema)(|(lDAPDisplayName=ms-Mcs-AdmPwdExpirationTime)(lDAPDisplayName=msLAPS-PasswordExpirationTime)))')
            [void]$schema.PropertiesToLoad.Add('lDAPDisplayName');$schema.SearchScope='OneLevel'
            $present=@($schema.FindAll()|ForEach-Object{[string]$_.Properties['ldapdisplayname'][0]})
            $searcher=New-Object DirectoryServices.DirectorySearcher -ArgumentList @((New-Object DirectoryServices.DirectoryEntry ('LDAP://'+$defaultNc)),('(&(objectCategory=computer)(sAMAccountName='+$Computer+'$))'))
            foreach($name in $requested){[void]$searcher.PropertiesToLoad.Add($name)}
            $hit=$searcher.FindOne()
            Expect ($null -ne $hit) ('Poste introuvable : '+$Computer)
            $legacy=$hit.Properties['ms-mcs-admpwdexpirationtime'].Count -gt 0;$windows=$hit.Properties['mslaps-passwordexpirationtime'].Count -gt 0
            $script:LiveFacts=[ordered]@{Computer=$Computer;SchemaLegacy=($present -contains 'ms-Mcs-AdmPwdExpirationTime');SchemaWindows=($present -contains 'msLAPS-PasswordExpirationTime');LegacyExpirationVisible=$legacy;WindowsExpirationVisible=$windows;LapsModuleCommand=($null -ne (Get-Command Get-LapsADPassword -ErrorAction SilentlyContinue))}
            foreach($name in @($hit.Properties.PropertyNames)){Expect (-not (Test-DomeniaSensitiveAttributeName ([string]$name))) ('Attribut secret renvoye : '+$name)}
        }
    }
}
$manual=@(
    [pscustomobject]@{Scenario='Domaine sans schéma LAPS';Expected='Index : état NoSchema (code X des requêtes), « Expiration LAPS non disponible dans ce domaine » ; aucun « sans LAPS » compté à tort.';Status='NotExecuted'}
    [pscustomobject]@{Scenario='LAPS historique (ms-Mcs-AdmPwd)';Expected='Expiration affichée sur la fiche et le tableau du poste ; secret lu seulement par « Charger LAPS », masqué jusquʼà la révélation.';Status='NotExecuted'}
    [pscustomobject]@{Scenario='Windows LAPS chiffré, module présent puis absent';Expected='Avec le module : déchiffrement par Get-LapsADPassword et le compte LAPS ; sans le module : état « Prérequis absent », aucune autre méthode tentée.';Status='NotExecuted'}
    [pscustomobject]@{Scenario='Compte non délégué';Expected='« Lecture refusée », « non confirmée » ou « déchiffrement refusé » selon le cas, proposition dʼun autre compte LAPS, jamais « aucun mot de passe ».';Status='NotExecuted'}
)
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$liveFacts=$null
if($null -ne (Get-Variable -Name LiveFacts -Scope Script -ErrorAction SilentlyContinue)){$liveFacts=$script:LiveFacts}
$report=[ordered]@{
    Suite='Domenia.LapsQualification';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition
    LiveRequested=[bool]$Live;SecretRead=$false;Passed=$passed;Failed=$failed;Tests=$script:Checks.ToArray();Live=$liveFacts;ManualScenarios=$manual
    Limitations='Hors ligne : regles et code source. En direct (option) : schema et expiration seulement. Les quatre scenarios manuels restent a executer dans le laboratoire et ne sont pas comptes.'
}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))}
if(-not $Quiet){
    Write-Host ('LAPS : '+$passed+' reussis, '+$failed+' en echec, '+$manual.Count+' scenarios manuels non executes.')
    $script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}
}
if(($failed -gt 0) -or ($passed -eq 0)){exit 1}
exit 0
