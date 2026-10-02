#requires -Version 5.1
<# R1.7.2. Tests des fonctions reelles extraites par AST, sans executer le coeur.
   Les DirectoryEntry sont remplaces par une classe C# locale inerte.
   L'appel statique GetComputerDomain est remplace DANS LES TESTS SEULEMENT.
   Aucun domaine, aucun compte reel, aucun cache et aucun poste ne sont touches.
   Le test SelfTestOnly utilise le vrai transport MTA mais sort avant tout appel AD.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$corePath=Join-Path $root 'wad\Domenia-Core.ps1'
$source=[IO.File]::ReadAllText($corePath)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw ('Syntaxe du coeur : '+$errors[0].Message) }
$nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
function Get-TestDefinition {
    param([string]$Name)
    $found=@($nodes | Where-Object { $_.Name -eq $Name })
    if ($found.Count -ne 1) { throw ('Definition unique attendue : '+$Name) }
    return [string]$found[0].Extent.Text
}
$wanted=@('Get-AuthOptionalFlag','Get-AuthAdsiAttributeFirst','Read-AuthAdsiBase','Get-DeepestException',
          'Get-AuthNativeFailure','Protect-AuthDiagnosticText','Get-AuthFailureDiagnostic','Get-AuthFailureCategory','Convert-DomeniaLoginFailureMessage','Get-DomeniaLoginFailureHint',
          'Start-DomeniaLoginAuthRunspace','Read-DomeniaAuthRunspaceResult','Complete-DomeniaLoginAuthRunspaceCleanup')
foreach ($name in $wanted) { . ([scriptblock]::Create((Get-TestDefinition $name))) }
$realProbe=Get-TestDefinition 'Invoke-DomeniaInProcessAuthProbe'
$original=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\AuthProbe-R1.7.ps1'))
$previous=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\AuthProbe-R1.7.1.ps1'))
$staticBoundary='[System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()'
foreach ($body in @($realProbe,$original,$previous)) {
    if ([regex]::Matches($body,[regex]::Escape($staticBoundary)).Count -ne 1) {
        throw 'Frontiere de decouverte modifiee : arret avant tout appel AD.'
    }
}
$testProbe=$realProbe.Replace($staticBoundary,'(Get-TestComputerDomain)')
$testOriginal=$original.Replace($staticBoundary,'(Get-TestComputerDomain)').Replace(
    'function Invoke-DomeniaInProcessAuthProbe {','function Invoke-DomeniaR17AuthProbe {')
. ([scriptblock]::Create($testProbe))
. ([scriptblock]::Create($testOriginal))
$testPrevious=$previous.Replace($staticBoundary,'(Get-TestComputerDomain)').Replace(
    'function Invoke-DomeniaInProcessAuthProbe {','function Invoke-DomeniaR171AuthProbe {')
. ([scriptblock]::Create($testPrevious))
# Enum seulement. Aucun constructeur SDS reel n'est appele dans les fixtures.
Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop
Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
if ($null -eq ('Domenia.LoginTests172.Entry' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Runtime.InteropServices;
namespace Domenia.LoginTests172 {
    public sealed class ThrowingBag : Hashtable {
        public override object this[object key] {
            get { throw new COMException("TEST_INDEXER_NATIVE_ERROR",unchecked((int)0x80070005)); }
            set { base[key]=value; }
        }
    }
    public sealed class Entry : IDisposable {
        public static string Scenario = "Success";
        public static int DiscoveryFactories, ExplicitFactories, ExplicitBinds, Reads, Disposals;
        public static void Reset(string scenario) {
            Scenario=scenario; DiscoveryFactories=0; ExplicitFactories=0; ExplicitBinds=0; Reads=0; Disposals=0;
        }
        public bool IsDiscovery;
        public readonly Hashtable Data = new Hashtable(StringComparer.OrdinalIgnoreCase);
        public Entry(bool discovery) {
            IsDiscovery=discovery;
            if(discovery) {
                DiscoveryFactories++;
                Data["defaultNamingContext"]=new object[]{"DC=example,DC=test"};
                Data["configurationNamingContext"]=new object[]{"CN=Configuration,DC=example,DC=test"};
                Data["dnsHostName"]=new object[]{Scenario=="SelectedDcFailure" ? "selected-dc.example.test" : "dc.example.test"};
            } else {
                ExplicitFactories++;
                Data["distinguishedName"]=new object[]{"DC=example,DC=test"};
            }
        }
        public object NativeObject {
            get {
                if(!IsDiscovery) {
                    ExplicitBinds++;
                    if(Scenario=="BadPassword") throw new COMException("TEST invalid credentials",unchecked((int)0x8007052e));
                    if(Scenario=="OpaqueLogon" || Scenario=="SelectedDcFailure") throw new COMException("TEST_OPAQUE_NATIVE_MESSAGE",unchecked((int)0x8007052e));
                    if(Scenario=="NativeAccessDenied") throw new COMException("TEST_OPAQUE_ACCESS",unchecked((int)0x80070005));
                    if(Scenario=="NativeWorkstation") throw new COMException("TEST_OPAQUE_POLICY",unchecked((int)0x80070531));
                    if(Scenario=="NativeLocked") throw new COMException("TEST_OPAQUE_STATUS",unchecked((int)0x80070775));
                    if(Scenario=="NativeServerDown") throw new COMException("TEST_OPAQUE_SERVER",unchecked((int)0x8007203a));
                    if(Scenario=="NativeUnknown") throw new COMException("TEST_UNKNOWN_PROVIDER",unchecked((int)0x80004005));
                    if(Scenario=="SecretInNativeError") throw new COMException("TEST message TEST-ONLY ! Never a real password",unchecked((int)0x80004005));
                    if(Scenario=="NullNative") return null;
                }
                return this;
            }
        }
        public Hashtable Properties {
            get {
                if(Scenario=="ThrowRootGetter" && IsDiscovery) throw new COMException("TEST_ROOT_GETTER_ERROR",unchecked((int)0x80004005));
                if(Scenario=="ThrowPropertiesGetter" && !IsDiscovery) throw new COMException("TEST_PROPERTIES_GETTER_ERROR",unchecked((int)0x80070005));
                if(Scenario=="ThrowIndexer" && !IsDiscovery) return new ThrowingBag();
                if(Scenario=="NullRootCollection" && IsDiscovery) return null;
                if(Scenario=="MaskRefreshError" && !IsDiscovery) return null;
                return Data;
            }
        }
        public void RefreshCache(string[] names) {
            Reads++;
            if(Scenario=="MaskRefreshError") throw new COMException("TEST_REFRESH_ACCESS_DENIED",unchecked((int)0x80070005));
            if(Scenario=="MissingBaseDn") Data["distinguishedName"]=new object[0];
        }
        public void Dispose() { Disposals++; }
    }
}
'@
}
$script:LoginTestResults=New-Object 'System.Collections.Generic.List[object]'
$script:TestCredential=New-Object Management.Automation.PSCredential -ArgumentList @('EXAMPLE\tech',(ConvertTo-SecureString 'TEST-ONLY ! Never a real password' -AsPlainText -Force))
function Assert-Login { param([bool]$Condition,[string]$Message='Assertion fausse.'); if (-not $Condition) { throw $Message } }
function Assert-LoginThrows {
    param([scriptblock]$Action,[string]$Pattern)
    $text=''
    try { & $Action | Out-Null } catch { $text=[string]$_.Exception.Message }
    Assert-Login (-not [string]::IsNullOrWhiteSpace($text)) 'Exception attendue.'
    Assert-Login ($text -match $Pattern) ('Exception inattendue : '+$text)
}
function Test-LoginCase {
    param([string]$Name,[scriptblock]$Action)
    [Domenia.LoginTests172.Entry]::Reset('Success')
    try { & $Action | Out-Null; $status='PASS'; $detail='' }
    catch { $status='FAIL'; $detail=[string]$_.Exception.Message }
    $script:LoginTestResults.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})
    if (-not $Quiet -or $status -eq 'FAIL') { Write-Host ("$status | $Name | $detail") }
}
function Get-TestComputerDomain { throw 'TEST ONLY: OS domain discovery disabled.' }
# Reject every unmocked DirectoryServices creation to make network regressions fail closed.
function New-Object {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$TypeName,[Parameter(Position=1)][object[]]$ArgumentList)
    if ($TypeName -eq 'System.DirectoryServices.DirectoryEntry') {
        $isDiscovery=($ArgumentList.Count -eq 1)
        if (-not $isDiscovery) {
            Assert-Login ($ArgumentList.Count -eq 4) 'Surcharge ADSI explicite attendue.'
            Assert-Login ([string]$ArgumentList[1] -eq 'EXAMPLE\tech') 'Identite changee pendant le bind.'
            Assert-Login ([string]$ArgumentList[2] -ceq 'TEST-ONLY ! Never a real password') 'Mot de passe transforme.'
        }
        $entry=[Domenia.LoginTests172.Entry]::new($isDiscovery)
        if ([Domenia.LoginTests172.Entry]::Scenario -eq 'AdaptedCollision' -and -not $isDiscovery) {
            # Simulate adapted members shadowing CLR members (not a live ADSI adapter test).
            $entry | Add-Member -MemberType NoteProperty -Name Properties -Value $null -Force
            $entry | Add-Member -MemberType ScriptMethod -Name RefreshCache -Value { param($names) throw 'TEST_ADAPTED_REFRESH' } -Force
        }
        return $entry
    }
    if ($TypeName -like 'System.DirectoryServices.*') { throw ('Network constructor forbidden in test: '+$TypeName) }
    return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Invoke-TestProbe {
    param([switch]$Original,[switch]$Previous,[string]$Scenario='Success')
    [Domenia.LoginTests172.Entry]::Reset($Scenario)
    $request=[pscustomobject]@{
        Login='tech'; Credential=$script:TestCredential; UseCurrentCredentials=$false
        ConfiguredServer='dc.example.test'; ConfiguredBase=''; Domain='example.test'; Netbios='EXAMPLE'
        MaxServers=2; OverallTimeoutSeconds=8; PerServerTimeoutSeconds=2
    }
    $progress=[hashtable]::Synchronized(@{Stage='';Detail='';Sequence=0;UpdatedAt=[datetime]::UtcNow})
    if ($Original) { return Invoke-DomeniaR17AuthProbe -Request $request -Progress $progress }
    if ($Previous) { return Invoke-DomeniaR171AuthProbe -Request $request -Progress $progress }
    return Invoke-DomeniaInProcessAuthProbe -Request $request -Progress $progress
}
Test-LoginCase 'Flag optionnel : requete absente' { Assert-Login (-not (Get-AuthOptionalFlag -Object $null -Name SelfTestOnly)) }
Test-LoginCase 'Flag optionnel : objet sans le membre' { Assert-Login (-not (Get-AuthOptionalFlag -Object ([pscustomobject]@{}) -Name SelfTestOnly)) }
Test-LoginCase 'Flag optionnel : dictionnaire vide' { Assert-Login (-not (Get-AuthOptionalFlag -Object @{} -Name SelfTestOnly)) }
Test-LoginCase 'Flag optionnel : valeur vraie conservee' { Assert-Login (Get-AuthOptionalFlag -Object ([pscustomobject]@{SelfTestOnly=$true}) -Name SelfTestOnly) }
Test-LoginCase 'Attribut ADSI : entree absente, erreur explicite' { Assert-LoginThrows { Get-AuthAdsiAttributeFirst -Entry $null -Name a } 'DOMENIA_AUTH_ENTRY_NULL' }
Test-LoginCase 'Attribut ADSI : collection absente, erreur explicite' {
    [Domenia.LoginTests172.Entry]::Reset('NullRootCollection'); $e=[Domenia.LoginTests172.Entry]::new($true)
    Assert-LoginThrows { Get-AuthAdsiAttributeFirst -Entry $e -Name a } 'DOMENIA_AUTH_PROPERTIES_NULL'
}
Test-LoginCase 'Attribut ADSI : valeur absente' {
    $e=[Domenia.LoginTests172.Entry]::new($true)
    Assert-Login ((Get-AuthAdsiAttributeFirst -Entry $e -Name nonexistent) -eq '')
}
Test-LoginCase 'Attribut ADSI : premiere valeur lue' {
    $e=[Domenia.LoginTests172.Entry]::new($true)
    Assert-Login ((Get-AuthAdsiAttributeFirst -Entry $e -Name dnsHostName) -eq 'dc.example.test')
}
Test-LoginCase 'Attribut ADSI : nom adapte ne masque pas PSBase' {
    $e=[Domenia.LoginTests172.Entry]::new($true)
    $e | Add-Member -MemberType NoteProperty -Name Properties -Value $null -Force
    Assert-Login ((Get-AuthAdsiAttributeFirst -Entry $e -Name dnsHostName) -eq 'dc.example.test')
}
Test-LoginCase 'Lecture base : acces refuse initial conserve' {
    [Domenia.LoginTests172.Entry]::Reset('MaskRefreshError');$e=[Domenia.LoginTests172.Entry]::new($false)
    Assert-LoginThrows { Read-AuthAdsiBase -Entry $e } 'TEST_REFRESH_ACCESS_DENIED'
}
Test-LoginCase 'Lecture base : metadata vide refusee' {
    [Domenia.LoginTests172.Entry]::Reset('MissingBaseDn');$e=[Domenia.LoginTests172.Entry]::new($false)
    Assert-LoginThrows { Read-AuthAdsiBase -Entry $e } 'DOMENIA_AUTH_METADATA_MISSING'
}
Test-LoginCase 'Probe complet simule : succes, bind unique, nettoyage' {
    $r=Invoke-TestProbe
    Assert-Login $r.Success
    Assert-Login ($r.BindUser -eq 'EXAMPLE\tech' -and $r.AuthMethod -eq 'ADSI.DirectoryEntry+ContextDiscovery')
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitFactories -eq 1 -and [Domenia.LoginTests172.Entry]::ExplicitBinds -eq 1)
    Assert-Login ([Domenia.LoginTests172.Entry]::Reads -eq 1 -and [Domenia.LoginTests172.Entry]::Disposals -eq 2)
    Assert-Login ($null -eq $r.Diagnostic)
}
Test-LoginCase 'R1.7 simulee : erreur de refresh masquee par NullArray' {
    $r=Invoke-TestProbe -Original -Scenario MaskRefreshError
    Assert-Login (-not $r.Success)
    Assert-Login ($r.Error -match '(?i)null array|tableau Null') ('Erreur recue : '+$r.Error)
}
Test-LoginCase 'Correctif actuel : vraie erreur de refresh conservee' {
    $r=Invoke-TestProbe -Scenario MaskRefreshError
    Assert-Login (-not $r.Success -and $r.Diagnostic.NativeMessage -eq 'TEST_REFRESH_ACCESS_DENIED')
    Assert-Login ($r.Error -notmatch '(?i)null array|tableau Null')
    Assert-Login ($r.ErrorCategory -eq 'AccessDenied')
    Assert-Login ($r.Diagnostic.Stage -eq 'Explicit.ReadBase' -and $r.Diagnostic.CredentialAttempted)
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitFactories -eq 1) 'Pas de deuxieme DC apres bind.'
}
Test-LoginCase 'R1.7 simulee : collision de membres, echec' {
    $r=Invoke-TestProbe -Original -Scenario AdaptedCollision
    Assert-Login (-not $r.Success)
}
Test-LoginCase 'Correctif actuel : collision de membres, CLR utilise' {
    $r=Invoke-TestProbe -Scenario AdaptedCollision
    Assert-Login $r.Success
    Assert-Login ([Domenia.LoginTests172.Entry]::Reads -eq 1)
}
Test-LoginCase 'RootDSE nul : erreur interne, aucun mot de passe envoye' {
    $r=Invoke-TestProbe -Scenario NullRootCollection
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'Internal')
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitFactories -eq 0 -and [Domenia.LoginTests172.Entry]::DiscoveryFactories -eq 1)
    Assert-Login (-not $r.Diagnostic.CredentialAttempted)
}
Test-LoginCase 'Refus simule : refuse, aucun repli Windows ni second DC' {
    $r=Invoke-TestProbe -Scenario BadPassword
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'Credentials')
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitFactories -eq 1 -and [Domenia.LoginTests172.Entry]::Disposals -eq 2)
}
Test-LoginCase 'Objet natif absent : jamais de faux succes' {
    $r=Invoke-TestProbe -Scenario NullNative
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'Internal')
    Assert-Login ([Domenia.LoginTests172.Entry]::Reads -eq 0)
}
Test-LoginCase 'DN de base absent : jamais de faux succes' {
    $r=Invoke-TestProbe -Scenario MissingBaseDn
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'Metadata')
}
Test-LoginCase 'Diagnostic : etape, erreur et ligne conserves sans credential' {
    $r=Invoke-TestProbe -Scenario MaskRefreshError
    Assert-Login ($r.Diagnostic.WorkerLine -gt 0 -and $r.Diagnostic.ExceptionType -match 'COMException')
    $json=$r.Diagnostic | ConvertTo-Json -Depth 5
    Assert-Login ($json -notmatch 'TEST-ONLY|Never a real password')
    Assert-Login ($r.Diagnostic.BindIdentity -eq 'EXAMPLE\tech')
    Assert-Login (@($r.Diagnostic.PSObject.Properties.Name).Count -eq 13)
}
Test-LoginCase 'Erreur interne francaise : aucun verdict mauvais mot de passe' {
    $m=Convert-DomeniaLoginFailureMessage -Message 'Indexation impossible dans un tableau Null. (LDAP=-1, serveur=test)'
    Assert-Login ($m -like 'Erreur interne*')
    Assert-Login ((Get-DomeniaLoginFailureHint -Message $m) -like '*ne prouve pas*')
}
Test-LoginCase 'Erreur interne anglaise : aucun changement de compte suggere' {
    $m=Convert-DomeniaLoginFailureMessage -Message 'Cannot index into a null array.'
    Assert-Login ($m -like 'Erreur interne*')
    Assert-Login ((Get-DomeniaLoginFailureHint -Message $m) -notmatch 'autre mode|Corrige')
}
Test-LoginCase 'Categorie interne prioritaire sur texte approximatif' {
    $m=Convert-DomeniaLoginFailureMessage -Message 'Mot de passe incorrect ? Diagnostic interne.' -Category Internal
    Assert-Login ($m -like 'Erreur interne*')
}
Test-LoginCase 'Credentials reels : message de refus conserve' {
    $m=Convert-DomeniaLoginFailureMessage -Message 'TEST invalid credentials' -Category Credentials
    Assert-Login ($m -eq 'Identifiant ou mot de passe incorrect.')
}
Test-LoginCase 'Reseau : orientation reseau plutot que mot de passe' {
    Assert-Login ((Get-DomeniaLoginFailureHint -Category DomainUnavailable -Message 'Controleur injoignable') -like '*reseau*')
}
Test-LoginCase 'Erreur inconnue : diagnostic plutot que changement de compte' {
    Assert-Login ((Get-DomeniaLoginFailureHint -Message 'TEST unknown') -like 'Ouvre le journal*')
}
Test-LoginCase 'Refus de lecture : message distinct des identifiants' {
    $m=Convert-DomeniaLoginFailureMessage -Message 'TEST_REFRESH_ACCESS_DENIED' -Category AccessDenied
    Assert-Login ($m -eq 'Acces refuse par AD. Consulte le diagnostic.')
}
Test-LoginCase 'Refus de lecture : orientation droits plutot que DNS' {
    $m=Get-DomeniaLoginFailureHint -Category AccessDenied -Message 'Acces refuse par AD.'
    Assert-Login ($m -match 'droits du compte' -and $m -notmatch 'DNS|mot de passe')
}
Test-LoginCase 'R1.7.1 : getter COM refusant masque par NATIVE_NULL' {
    $r=Invoke-TestProbe -Previous -Scenario OpaqueLogon
    Assert-Login (-not $r.Success -and $r.Error -match 'DOMENIA_AUTH_NATIVE_NULL')
    Assert-Login ($r.Diagnostic.HResult -eq '0x80131509') 'Le wrapper ancien masque le vrai HRESULT.'
}
Test-LoginCase 'R1.7.2 : meme getter, erreur COM et HRESULT originaux conserves' {
    $r=Invoke-TestProbe -Scenario OpaqueLogon
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'Credentials')
    Assert-Login ($r.Diagnostic.HResult -eq '0x8007052E')
    Assert-Login ($r.Diagnostic.ExceptionType -eq 'System.Runtime.InteropServices.COMException')
    Assert-Login ($r.Diagnostic.NativeMessage -eq 'TEST_OPAQUE_NATIVE_MESSAGE')
    Assert-Login ($r.Error -notmatch 'DOMENIA_AUTH_NATIVE_NULL')
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitBinds -eq 1 -and [Domenia.LoginTests172.Entry]::Reads -eq 0)
}
Test-LoginCase 'CLR : acces propriete masque effectivement une exception de getter' {
    [Domenia.LoginTests172.Entry]::Reset('OpaqueLogon'); $e=[Domenia.LoginTests172.Entry]::new($false)
    $v=$e.psbase.NativeObject
    Assert-Login ($null -eq $v) 'Ce runtime ne reproduit pas la suppression attendue.'
}
Test-LoginCase 'CLR : appel de methode getter propage la meme exception' {
    [Domenia.LoginTests172.Entry]::Reset('OpaqueLogon'); $e=[Domenia.LoginTests172.Entry]::new($false)
    Assert-LoginThrows { $e.psbase.get_NativeObject() } 'TEST_OPAQUE_NATIVE_MESSAGE'
}
Test-LoginCase 'CLR Properties : exception du getter conservee' {
    $r=Invoke-TestProbe -Scenario ThrowPropertiesGetter
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'AccessDenied')
    Assert-Login ($r.Diagnostic.NativeMessage -eq 'TEST_PROPERTIES_GETTER_ERROR')
    Assert-Login ($r.Error -notmatch 'DOMENIA_AUTH_PROPERTIES_NULL')
}
Test-LoginCase 'CLR indexeur : exception native conservee par get_Item' {
    $r=Invoke-TestProbe -Scenario ThrowIndexer
    Assert-Login (-not $r.Success -and $r.Diagnostic.NativeMessage -eq 'TEST_INDEXER_NATIVE_ERROR')
    Assert-Login ($r.Diagnostic.HResult -eq '0x80070005')
}
Test-LoginCase 'Discovery getter : erreur avant utilisation du credential' {
    $r=Invoke-TestProbe -Scenario ThrowRootGetter
    Assert-Login (-not $r.Success -and $r.Diagnostic.NativeMessage -eq 'TEST_ROOT_GETTER_ERROR')
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitFactories -eq 0)
    Assert-Login (-not $r.Diagnostic.CredentialAttempted)
}
Test-LoginCase 'Bind refuse par droits : code numerique prime sur texte opaque' {
    $r=Invoke-TestProbe -Scenario NativeAccessDenied
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'AccessDenied')
    Assert-Login ($r.Diagnostic.Stage -eq 'Explicit.NativeBind')
}
Test-LoginCase 'Restriction poste : jamais presentee comme mauvais mot de passe' {
    $r=Invoke-TestProbe -Scenario NativeWorkstation
    Assert-Login ($r.ErrorCategory -eq 'AccountRestriction' -and $r.Error -match 'depuis ce poste')
    Assert-Login ((Convert-DomeniaLoginFailureMessage -Message $r.Error -Category $r.ErrorCategory) -notmatch 'mot de passe incorrect')
}
Test-LoginCase 'Compte verrouille : restriction, aucune affirmation sur le mot de passe' {
    $r=Invoke-TestProbe -Scenario NativeLocked
    Assert-Login ($r.ErrorCategory -eq 'AccountRestriction' -and $r.Error -match 'verrouill')
    Assert-Login ($r.Error -notmatch 'pas en cause')
}
Test-LoginCase 'Serveur indisponible pendant bind : aucun second bind automatique' {
    $r=Invoke-TestProbe -Scenario NativeServerDown
    Assert-Login ($r.ErrorCategory -eq 'DomainUnavailable')
    Assert-Login ([Domenia.LoginTests172.Entry]::ExplicitFactories -eq 1 -and $r.Attempts -eq 1)
}
Test-LoginCase 'Erreur bind inconnue : diagnostic sans verdict DNS ou credentials' {
    $r=Invoke-TestProbe -Scenario NativeUnknown
    Assert-Login (-not $r.Success -and $r.ErrorCategory -eq 'Authentication')
    Assert-Login ($r.Diagnostic.HResult -eq '0x80004005')
    Assert-Login ((Get-DomeniaLoginFailureHint -Category $r.ErrorCategory -Message $r.Error) -match 'diagnostic natif')
}
Test-LoginCase 'Identite canonique et DC du refus explicite traces sans changer le compte' {
    $r=Invoke-TestProbe -Scenario SelectedDcFailure
    Assert-Login ($r.Diagnostic.BindIdentity -eq 'EXAMPLE\tech')
    Assert-Login ($r.Server -eq $r.Diagnostic.Server -and $r.Server -eq 'selected-dc.example.test')
}
Test-LoginCase 'Secret dans message simule : retire du resultat et du diagnostic' {
    $r=Invoke-TestProbe -Scenario SecretInNativeError
    $json=$r | ConvertTo-Json -Depth 8
    Assert-Login ($json -notmatch 'TEST-ONLY|Never a real password')
    Assert-Login ($r.Diagnostic.NativeMessage -match '\[SECRET MASQUE\]')
}
Test-LoginCase 'Un code dans le nom du DC ne cree pas de faux verrouillage' {
    $m='TEST serveur=dc775.example.test'
    Assert-Login ((Convert-DomeniaLoginFailureMessage -Message $m) -eq $m)
}
Test-LoginCase 'Getter vraiment nul : garde fail-closed conservee apres le correctif' {
    $r=Invoke-TestProbe -Scenario NullNative
    Assert-Login (-not $r.Success -and $r.Error -match 'DOMENIA_AUTH_NATIVE_NULL')
    Assert-Login ($r.Diagnostic.ExceptionType -eq 'System.InvalidOperationException')
    Assert-Login ([Domenia.LoginTests172.Entry]::Reads -eq 0 -and [Domenia.LoginTests172.Entry]::ExplicitFactories -eq 1)
}
Test-LoginCase 'Aucun diagnostic echec ne contient une requete ou un objet credential' {
    $r=Invoke-TestProbe -Scenario NativeUnknown
    Assert-Login (@($r.Diagnostic.PSObject.Properties.Name | Where-Object { $_ -in @('Request','Credential','Password','InvocationInfo','Exception','Data') }).Count -eq 0)
    Assert-Login ($r.Diagnostic.WorkerLine -gt 0)
}

Test-LoginCase 'Transport MTA reel : SelfTestOnly sans dependance AD' {
    # Restore the actual probe before the real isolated runspace is created.
    . ([scriptblock]::Create($realProbe))
    $session=$null
    try {
        $session=Start-DomeniaLoginAuthRunspace -Request ([pscustomobject]@{SelfTestOnly=$true;Credential=$null})
        Assert-Login ($session.AsyncResult.AsyncWaitHandle.WaitOne(8000)) 'Delai self-test transport.'
        $r=Read-DomeniaAuthRunspaceResult -Session $session
        Assert-Login ($r.Success -and $r.AuthMode -eq 'SelfTest' -and $r.Attempts -eq 0)
        Assert-Login ($r.Apartment -eq 'MTA')
    } finally {
        if ($null -ne $session) {
            if ($session.AsyncResult.IsCompleted) { Complete-DomeniaLoginAuthRunspaceCleanup -Session $session }
            else { [void]$session.PowerShell.BeginStop($null,$null) }
        }
    }
}
$passed=@($script:LoginTestResults | Where-Object Status -eq PASS).Count
$failed=@($script:LoginTestResults | Where-Object Status -eq FAIL).Count
$report=[ordered]@{
    Build='2026.09.22-R1.7.2-NATIVE'; PowerShellVersion=$PSVersionTable.PSVersion.ToString()
    Runtime=[Environment]::OSVersion.VersionString; LiveDirectoryExecuted=$false; WpfExecuted=$false
    Mode='AST-extracted source + throwing CLR getters before/after + inert ADSI fixtures + real MTA SelfTestOnly'
    Passed=$passed;Failed=$failed;Tests=$script:LoginTestResults.ToArray()
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-LoginTests-'+[guid]::NewGuid().ToString('N')+'.json')
}
$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath))
[void][IO.Directory]::CreateDirectory($parent)
[IO.File]::WriteAllText($ReportPath,($report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host ("Connexion : $passed reussis, $failed echecs. Rapport : $ReportPath")
if ($failed -gt 0) { throw 'Tests de connexion en echec. Aucun bind LDAP reel effectue.' }
