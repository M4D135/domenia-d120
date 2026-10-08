#requires -Version 5.1
<# D120 lot "suites" : preuve de raccordement.
   D004 : fixtures fideles aux types AD (wad\tests\fixtures\Domenia-AdFixtures.ps1) passees aux VRAIES fonctions
          de lecture : code commun des workers (extrait du litteral $script:WorkerCommon), coeur et modules du plan ferme.
   D008 : sequences generees A/B/C, changement de compte, nouvelle session, nouvelle recherche, annulation et
          navigation, rejouees sur le vrai parcours selection -> lecture -> rappel (Selection.UI + coeur).
   Suites : les nouvelles suites existent, respectent le contrat de rapport et sont decouvertes par la campagne.
   Aucune connexion AD, aucun acces distant, aucune ecriture. Fonctions extraites par AST, frontieres doublees.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$script:Checks=[Collections.Generic.List[object]]::new()
function Assert-True {param([bool]$Value,[string]$Why='Assertion fausse');if(-not $Value){throw $Why}}
function Test-Case {param([string]$CaseLabel,[scriptblock]$Body)
    try { & $Body | Out-Null; $script:Checks.Add([pscustomobject]@{Name=$CaseLabel;Status='Passed';Detail=''}) }
    catch { $script:Checks.Add([pscustomobject]@{Name=$CaseLabel;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)}) }
}
function Read-SourceAst {param([string]$Path)
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if(@($e).Count){throw ($Path+' : '+$e[0].Message)}
    return $a
}
function Get-FunctionText {param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $nodes[0].Extent.Text
}
$infrastructure=$true
try {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
        throw 'Windows PowerShell 5.1 x64 -STA requis ; une execution sous PowerShell 7 ne vaut pas preuve.'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    # Closed module plan: real Common, Engine, Directory, Selection and Access modules, origin verified.
    . (Join-Path $wad 'Domenia-Modules.ps1')
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    # Worker common code: the very literal assigned to $script:WorkerCommon, parsed then dot-sourced by function.
    $assignment=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:WorkerCommon' -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals},$true))
    if($assignment.Count -ne 1){throw 'Code commun des workers introuvable.'}
    $commonLiteral=$assignment[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
    $ct=$null;$ce=$null;$commonAst=[Management.Automation.Language.Parser]::ParseInput([string]$commonLiteral.Value,[ref]$ct,[ref]$ce)
    if(@($ce).Count){throw 'Code commun des workers non analysable.'}
    foreach($name in @('Get-WPropFirst','Get-WPropAll','Convert-WLargeInteger','Convert-WFileTime','Convert-WDate','Convert-WGuid','Convert-WSid','Convert-WDirectoryValue','Get-WAllProperties')){
        . ([scriptblock]::Create((Get-FunctionText $commonAst $name)))
    }
    foreach($name in @('Get-DeProp','Get-DePropAll','Get-DomeniaEntryFirstString','Convert-GuidLabel',
        'Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSelectedGridRow','Test-DomeniaGridSelectionMatches','Queue-DomeniaSelectedObjectOpen',
        'Invoke-DomeniaPendingSelectionOpen','Open-SelectedObject','Stop-DomeniaSelectionOpenTimer','Clear-DomeniaCurrentObjectRequest',
        'Test-DomeniaObjectCallbackIsCurrent','Open-AdObject','Complete-DomeniaOpenObjectTaskUi','Fail-DomeniaOpenObjectTaskUi')){
        . ([scriptblock]::Create((Get-FunctionText $script:CoreAst $name)))
    }
    . (Join-Path $PSScriptRoot 'fixtures\Domenia-AdFixtures.ps1')
}
catch {
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1, plan ferme et extraction AST';Status='Failed';Detail=$_.Exception.ToString()})
}

# Boundaries of the selection path, as in Test-DomeniaPreload: no worker, no cache file, no network.
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Test-DomeniaAccessBusyWrite {return [bool]$script:BusyWrite}
function Get-DomeniaSelectedGridRows {return @($script:Ctrl.DgObjects.SelectedItems)}
function Test-DomeniaDraftNavigation {param($DN,[switch]$Refresh);return $true}
function Restore-DomeniaRefusedSelection {param($DN)}
function Clear-Secrets {}
# D085: a new selection purges the views bound to the previous object (core function, inert here).
function Reset-DomeniaSelectionBoundViews {param($Dn,$Type,$Name)}
function Clear-DomeniaLiveProbeIntent {}
function Select-DomeniaLiveResult {param([switch]$Force,[switch]$Manual)}
function Set-DomeniaRelationsGridSelection {}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)}
function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:Page=[string]$Workspace}
function Set-Status {param($Text,$Level)}
function Write-AppLog {param($Text,$Level)}
function Get-DomeniaSafeObjectPropertyNames {return @('name','objectGUID','distinguishedName','objectClass')}
function Get-VisitCacheValue {param($Key);return $null}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Complete-DomeniaOpenObjectUi {param($Result,$CacheKey,$Dn,$Type,[switch]$NoNavigate,[switch]$SuppressRemoteProbes)
    $script:SelectedObject=[pscustomobject]@{DN=$Dn;Type=$Type;Entry=$Result}
    $script:Renders.Add([pscustomobject]@{DN=$Dn;Guid=(Get-DomeniaObjectResultGuid $Result)})
}
function Fail-DomeniaOpenObjectUi {param($Message,$Dn);$script:Failures.Add([string]$Dn)}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException)}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    if($OperationId -ne 'OpenAdObject'){throw ('Operation inattendue : '+$OperationId)}
    $job=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');State=$CallbackState;Payload=$Payload;Delivered=$false;Context=$script:RaceContext}
    $script:Requests.Add($job);$script:AsyncJobs[$job.Id]=$job;return $job.Id
}
function Reset-SelectionFixture {
    # The debounce DispatcherTimer is never pumped here; stop it so no tick can run later.
    if($null -ne $script:SelectionOpenTimer){$script:SelectionOpenTimer.Stop()}
    $script:SelectionOpenTimer=$null;$script:SelectionLoad=$null;$script:PendingObjectSelection=$null
    $script:CurrentObjectRequestId='';$script:CurrentObjectRequestDn='';$script:CurrentObjectRequestState=$null
    $script:SelectedObject=$null;$script:LastLoadedEntry=$null;$script:SelectionResetDn='';$script:DraftState=$null
    $script:SessionEpoch=4L;$script:GlobalSearchGeneration=9;$script:SelectedObjectGeneration=0L
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';BindUser='EXAMPLE\lecteur';Credential=$null}
    $script:AccessState=$null;$script:BusyWrite=$false;$script:SuppressGridSelectionEvents=$false;$script:AsyncEngineClosing=$false
    $script:AsyncJobs=@{};$script:Page='WsSearch';$script:RaceContext=''
    $script:Requests=[Collections.Generic.List[object]]::new();$script:Renders=[Collections.Generic.List[object]]::new();$script:Failures=[Collections.Generic.List[string]]::new()
    $script:Ctrl=@{
        DgObjects=[pscustomobject]@{IsEnabled=$true;SelectedItem=$null;SelectedItems=@();Items=@()}
        WsObject=[pscustomobject]@{Visibility='Collapsed'};WsComputer=[pscustomobject]@{Visibility='Collapsed'}
        LblSelectionReadState=[pscustomobject]@{Text='';ToolTip=$null}
    }
    foreach($kind in @('Object','Computer')){
        $script:Ctrl[$kind+'ReadContent']=[pscustomobject]@{Visibility='Collapsed';IsEnabled=$false}
        $script:Ctrl[$kind+'ReadPlaceholder']=[pscustomobject]@{Visibility='Visible'}
        $script:Ctrl['Lbl'+$kind+'ReadStatus']=[pscustomobject]@{Text='';ToolTip=''}
        $script:Ctrl['Btn'+$kind+'ReadRetry']=[pscustomobject]@{Visibility='Hidden';IsEnabled=$false}
    }
}
function Get-RaceRow {param([string]$Letter)
    $guids=@{A='aaaaaaaa-0000-4000-8000-000000000001';B='bbbbbbbb-0000-4000-8000-000000000002';C='cccccccc-0000-4000-8000-000000000003'}
    return [pscustomobject]@{DN=('CN=Objet '+$Letter+',OU=Test,DC=example,DC=invalid');Name=('Objet '+$Letter);Type='Utilisateur';Guid=$guids[$Letter];Login=('objet.'+$Letter.ToLowerInvariant())}
}
function Get-RaceContextKey {
    # Everything a fresh read depends on: selected object, session, account, search generation.
    $row=$script:Ctrl.DgObjects.SelectedItem
    $dn=if($null -ne $row){[string]$row.DN}else{''}
    return ($dn+'|'+[string]$script:SessionEpoch+'|'+[string]$script:Conn.BindUser+'|'+[string]$script:GlobalSearchGeneration).ToLowerInvariant()
}
function Select-RaceRow {param($Row)
    $script:Ctrl.DgObjects.SelectedItem=$Row;$script:Ctrl.DgObjects.SelectedItems=if($null -ne $Row){@($Row)}else{@()}
    $script:RaceContext=Get-RaceContextKey
    Queue-DomeniaSelectedObjectOpen
}
function Send-RacePending {$script:RaceContext=Get-RaceContextKey;Stop-DomeniaSelectionOpenTimer;Invoke-DomeniaPendingSelectionOpen}
function Get-RaceResult {param($Job)
    $letter=([string]$Job.State.Dn).Substring(9,1)
    $row=Get-RaceRow $letter
    return [pscustomobject]@{DN=$row.DN;Type=$row.Type;Live=$true;Properties=@{name=@($row.Name);objectGUID=@($row.Guid);distinguishedName=@($row.DN)}}
}

if($infrastructure){
    $cat=Get-DomeniaFixtureCatalog
    $guidText=$cat.UserGuid.ToString('D')

    # ------------------------------------------------------------------ D004 : fixtures fideles aux types AD
    Test-Case 'D004 : GUID binaire unique rendu en un seul tableau de 16 octets' {
        $p=New-DomeniaFixtureProperties @{objectguid=(New-DomeniaFixtureSingleValue (New-DomeniaFixtureGuidBytes $cat.UserGuid))}
        $v=Get-WPropFirst $p 'objectGUID'
        Assert-True ($v -is [byte[]] -and $v.Length -eq 16) ('Valeur deroulee : '+$(if($null -eq $v){'null'}else{$v.GetType().FullName}))
        Assert-True ((Convert-WGuid $v) -eq $guidText) 'GUID mal converti.'
        Assert-True ((Convert-WDirectoryValue 'objectGUID' $v) -eq $guidText) 'Conversion worker du GUID incorrecte.'
    }
    Test-Case 'D004 : une valeur d un seul octet reste un tableau d un octet' {
        $p=New-DomeniaFixtureProperties @{'msds-fixtureflag'=(New-DomeniaFixtureSingleValue ([byte[]]@(42)))}
        $v=Get-WPropFirst $p 'msDS-FixtureFlag'
        Assert-True ($v -is [byte[]] -and $v.Length -eq 1 -and $v[0] -eq 42) 'Un octet seul a ete confondu avec un scalaire.'
        $text=Convert-WDirectoryValue 'msDS-FixtureFlag' $v
        Assert-True ($text -is [string] -and $text -ceq '2A') ('Conversion inattendue : '+[string]$text)
    }
    Test-Case 'D004 : tokenGroups a zero, un et plusieurs SID' {
        $sid1=New-DomeniaFixtureSidBytes $cat.UserSid;$sid2=New-DomeniaFixtureSidBytes $cat.GroupSid
        $none=New-DomeniaFixtureProperties @{tokengroups=(New-DomeniaFixtureValues @())}
        $one=New-DomeniaFixtureProperties @{tokengroups=(New-DomeniaFixtureSingleValue $sid1)}
        $many=New-DomeniaFixtureProperties @{tokengroups=(New-DomeniaFixtureValues @($sid1,$sid2,$sid1))}
        Assert-True (@(Get-WPropAll $none 'tokenGroups').Count -eq 0) 'Collection vide non vide.'
        $single=@(Get-WPropAll $one 'tokenGroups')
        Assert-True ($single.Count -eq 1 -and $single[0] -is [byte[]]) ('Un SID unique a ete deroule : '+$single.Count+' element(s).')
        Assert-True ((Convert-WSid $single[0]) -ceq $cat.UserSid) 'SID unique mal converti.'
        $all=@(Get-WPropAll $many 'tokenGroups'|ForEach-Object{Convert-WSid $_})
        Assert-True ($all.Count -eq 3 -and $all[1] -ceq $cat.GroupSid) ('Valeurs multiples : '+($all -join ', '))
    }
    Test-Case 'D004 : attribut absent ou vide rend la valeur par defaut sans erreur' {
        $p=New-DomeniaFixtureProperties @{description=(New-DomeniaFixtureValues @())}
        Assert-True ((Get-WPropFirst $p 'absent' 'defaut') -ceq 'defaut') 'Absent non distingue.'
        Assert-True ((Get-WPropFirst $p 'description' 'defaut') -ceq 'defaut') 'Collection vide non distinguee.'
        Assert-True (@(Get-WPropAll $p 'absent').Count -eq 0)
        Assert-True ((Get-DomeniaMember ([pscustomobject]@{A=1}) 'Absent' 'defaut') -ceq 'defaut')
        Assert-True ((Get-DomeniaMember @{A=1} 'Absent' 'defaut') -ceq 'defaut')
    }
    Test-Case 'D004 : memberOf a une seule valeur rend une chaine, pas ses caracteres' {
        $p=New-DomeniaFixtureProperties @{memberof=(New-DomeniaFixtureSingleValue $cat.GroupDns[0])}
        $all=@(Get-WPropAll $p 'memberOf')
        Assert-True ($all.Count -eq 1 -and $all[0] -ceq $cat.GroupDns[0]) ('Valeur unique deroulee : '+$all.Count)
        $three=New-DomeniaFixtureProperties @{memberof=(New-DomeniaFixtureValues $cat.GroupDns)}
        Assert-True (@(Get-WPropAll $three 'memberOf').Count -eq 3)
    }
    Test-Case 'D004 : FILETIME, jamais et grand entier COM a partie basse negative' {
        $ft=ConvertTo-DomeniaFixtureFileTime $cat.LogonUtc
        $expected=[datetime]::FromFileTimeUtc($ft).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')
        Assert-True ((Convert-WFileTime (New-DomeniaFixtureLargeInteger $ft)) -ceq $expected) 'Grand entier COM mal converti.'
        Assert-True ((Convert-WFileTime $ft) -ceq $expected) 'Entier 64 bits mal converti.'
        Assert-True ((Convert-WFileTime 0L) -ceq 'Jamais' -and (Convert-WFileTime ([long]::MaxValue)) -ceq 'Jamais') 'Valeur jamais non reconnue.'
        $negativeLow=([long]30000000 -shl 32) -bor 0x80000001L
        $large=New-DomeniaFixtureLargeInteger $negativeLow
        Assert-True ($large.LowPart -lt 0) 'La fixture doit porter une partie basse negative.'
        Assert-True ((Convert-WLargeInteger $large) -eq $negativeLow) 'Partie basse negative mal recombinee.'
        $utc=ConvertTo-DomeniaUtcDate $ft
        Assert-True ($null -ne $utc -and $utc.Kind -eq [DateTimeKind]::Utc -and $utc -eq $cat.LogonUtc) 'Date UTC du modele incorrecte.'
        Assert-True ($null -eq (ConvertTo-DomeniaUtcDate 0L)) 'Zero doit signifier jamais.'
    }
    Test-Case 'D004 : lecture d objet par Get-WAllProperties sans deroulement ni valeur binaire brute' {
        $entry=New-DomeniaFixtureDirectoryEntry @{
            objectGUID=(New-DomeniaFixtureSingleValue (New-DomeniaFixtureGuidBytes $cat.UserGuid))
            objectSid=(New-DomeniaFixtureSingleValue (New-DomeniaFixtureSidBytes $cat.UserSid))
            proxyAddresses=(New-DomeniaFixtureSingleValue 'SMTP:alex.demo@example.invalid')
            description=(New-DomeniaFixtureValues @())
            name=(New-DomeniaFixtureSingleValue 'Alex Demo')
            lastLogonTimestamp=(New-DomeniaFixtureSingleValue (ConvertTo-DomeniaFixtureFileTime $cat.LogonUtc))
        }
        $h=Get-WAllProperties -Entry $entry -PropertyNames @('objectGUID','objectSid','proxyAddresses','description','name','mail','lastLogonTimestamp')
        Assert-True (@($entry.Refreshed).Count -ge 7) 'Liste explicite de proprietes non demandee.'
        Assert-True (@($h['objectGUID']).Count -eq 1 -and @($h['objectGUID'])[0] -ceq $guidText) 'GUID non converti en texte.'
        Assert-True (@($h['objectSid']).Count -eq 1 -and @($h['objectSid'])[0] -ceq $cat.UserSid) 'SID non converti en texte.'
        Assert-True (@($h['proxyAddresses']).Count -eq 1 -and @($h['proxyAddresses'])[0] -ceq 'SMTP:alex.demo@example.invalid') 'Valeur unique deroulee.'
        Assert-True (-not $h.ContainsKey('description') -and -not $h.ContainsKey('mail')) 'Attribut vide ou absent publie comme valeur.'
        foreach($key in @($h.Keys)){foreach($value in @($h[$key])){Assert-True (-not ($value -is [byte[]])) ('Valeur binaire brute publiee : '+$key)}}
    }
    Test-Case 'D004 : du resultat worker a la fiche, GUID et premiere valeur sans confusion' {
        $entry=New-DomeniaFixtureDirectoryEntry @{
            objectGUID=(New-DomeniaFixtureSingleValue (New-DomeniaFixtureGuidBytes $cat.UserGuid))
            proxyAddresses=(New-DomeniaFixtureSingleValue 'SMTP:alex.demo@example.invalid')
            memberOf=(New-DomeniaFixtureSingleValue $cat.GroupDns[0])
        }
        $h=Get-WAllProperties -Entry $entry -PropertyNames @('objectGUID','proxyAddresses')
        $result=[pscustomobject]@{DN=$cat.UserDn;Type='Utilisateur';Live=$true;Properties=$h}
        Assert-True ((Get-DomeniaObjectResultGuid $result) -eq $guidText) 'GUID de la fiche incorrect.'
        Assert-True ((Get-DomeniaEntryFirstString $result 'proxyAddresses') -ceq 'SMTP:alex.demo@example.invalid') 'Premiere valeur tronquee.'
        Assert-True (@(Get-DePropAll $result 'proxyAddresses').Count -eq 1) 'Collection d un element deroulee.'
        Assert-True ((Convert-GuidLabel (Get-DeProp $result 'objectGUID')) -eq $guidText) 'Libelle GUID incorrect.'
        # A binary GUID still present in a result (cache of an older version) is read whole, never byte by byte.
        $binary=[pscustomobject]@{DN=$cat.UserDn;Properties=@{objectGUID=(New-DomeniaFixtureGuidBytes $cat.UserGuid)}}
        Assert-True ((Get-DomeniaObjectResultGuid $binary) -eq $guidText) 'GUID binaire deroule dans le resultat.'
        $wrapped=[pscustomobject]@{DN=$cat.UserDn;Properties=@{objectGUID=@(,(New-DomeniaFixtureGuidBytes $cat.UserGuid))}}
        Assert-True ((Get-DomeniaObjectResultGuid $wrapped) -eq $guidText) 'GUID binaire dans une collection d un element mal lu.'
    }
    Test-Case 'D004 : identite de selection et sacs de proprietes du modele annuaire' {
        $row=[pscustomobject]@{Type='Utilisateur';Name='Alex Demo';Login='alex.demo';DN=$cat.UserDn;Guid=@(,(New-DomeniaFixtureGuidBytes $cat.UserGuid));Sid=(New-DomeniaFixtureSidBytes $cat.UserSid)}
        $id=New-DomeniaSelectionIdentity $row 'example.invalid' 'EXAMPLE\lecteur' 1 1
        Assert-True ($null -ne $id -and $id.Guid -eq $guidText -and $id.Sid -ceq $cat.UserSid) 'Identite construite sur une valeur deroulee.'
        $bag=@{objectSid=(New-DomeniaFixtureSidBytes $cat.UserSid);memberOf=$cat.GroupDns;mail='alex.demo@example.invalid';proxyAddresses=@('SMTP:alex.demo@example.invalid')}
        $sid=Get-DomeniaAttr $bag 'objectsid'
        Assert-True ($sid -is [byte[]] -and $sid.Length -eq (New-DomeniaFixtureSidBytes $cat.UserSid).Length) 'SID binaire deroule par Get-DomeniaAttr.'
        Assert-True (@(Get-DomeniaAttrAll $bag 'memberOf').Count -eq 3 -and @(Get-DomeniaAttrAll $bag 'mail').Count -eq 1 -and @(Get-DomeniaAttrAll $bag 'objectSid').Count -eq 1) 'Nombre de valeurs incorrect.'
        Assert-True ((Get-DomeniaAttr $bag 'proxyAddresses') -ceq 'SMTP:alex.demo@example.invalid') 'Premiere valeur d une collection incorrecte.'
    }

    # ------------------------------------------------------------------ D008 : courses sur le vrai parcours
    Test-Case 'D008 : sequences A/B/C generees, une reponse d un ancien contexte ne change rien' {
        $random=New-Object Random 20261003
        $steps=@('PickA','PickB','PickC','PickA','PickB','PickC','Send','Send','Deliver','Deliver','Deliver','Fail','ChangeAccount','Relogin','NewSearch','Cancel','Navigate')
        $stale=0;$current=0;$violations=[Collections.Generic.List[string]]::new()
        for($sequence=0;$sequence -lt 120;$sequence++){
            Reset-SelectionFixture
            $trace=[Collections.Generic.List[string]]::new()
            for($i=0;$i -lt 16;$i++){
                $step=$steps[$random.Next($steps.Count)];$trace.Add($step)
                switch($step){
                    'PickA' {Select-RaceRow (Get-RaceRow 'A')}
                    'PickB' {Select-RaceRow (Get-RaceRow 'B')}
                    'PickC' {Select-RaceRow (Get-RaceRow 'C')}
                    'Send' {Send-RacePending}
                    'ChangeAccount' {$script:Conn.BindUser=if($script:Conn.BindUser -eq 'EXAMPLE\lecteur'){'EXAMPLE\autre-lecteur'}else{'EXAMPLE\lecteur'}}
                    'Relogin' {$script:SessionEpoch=[long]$script:SessionEpoch+1}
                    'NewSearch' {$script:GlobalSearchGeneration=[int]$script:GlobalSearchGeneration+1}
                    'Cancel' {Clear-DomeniaCurrentObjectRequest ([string]$script:CurrentObjectRequestId)}
                    'Navigate' {Select-DomeniaWorkspace -Workspace 'TabRelations'}
                    default {
                        $open=@($script:Requests|Where-Object{-not $_.Delivered})
                        if($open.Count -eq 0){break}
                        $job=$open[$random.Next($open.Count)];$job.Delivered=$true
                        $isStale=([string]$job.Context -cne (Get-RaceContextKey))
                        $selectedBefore=$script:SelectedObject;$rendersBefore=$script:Renders.Count;$failuresBefore=$script:Failures.Count
                        if($step -eq 'Fail'){Fail-DomeniaOpenObjectTaskUi 'Lecture refusee (simulation)' $job.State}
                        else{Complete-DomeniaOpenObjectTaskUi (Get-RaceResult $job) $job.State}
                        if($isStale){
                            $stale++
                            if(-not [object]::ReferenceEquals($selectedBefore,$script:SelectedObject) -or $script:Renders.Count -ne $rendersBefore -or $script:Failures.Count -ne $failuresBefore){
                                $violations.Add(('sequence '+$sequence+' : '+($trace -join '>')+' ; reponse de '+[string]$job.State.Dn+' appliquee hors contexte'))
                            }
                        }else{
                            $current++
                            if($script:Renders.Count -gt $rendersBefore -and [string]$script:Renders[$script:Renders.Count-1].DN -ine [string]$script:Ctrl.DgObjects.SelectedItem.DN){
                                $violations.Add(('sequence '+$sequence+' : fiche affichee pour une autre ligne que la selection'))
                            }
                        }
                    }
                }
            }
        }
        Assert-True ($violations.Count -eq 0) ((@($violations)|Select-Object -First 3) -join ' | ')
        Assert-True ($stale -gt 30 -and $current -gt 10) ('Couverture insuffisante : '+$stale+' reponses perimees, '+$current+' courantes')
    }
    Test-Case 'D008 : reponse du contexte courant toujours affichee (preuve non vide)' {
        Reset-SelectionFixture
        $a=Get-RaceRow 'A';Select-RaceRow $a;Send-RacePending
        $job=$script:Requests[0]
        Complete-DomeniaOpenObjectTaskUi (Get-RaceResult $job) $job.State
        Assert-True ($script:Renders.Count -eq 1 -and $script:SelectedObject.DN -eq $a.DN) 'La reponse courante n a pas ete affichee.'
    }
    Test-Case 'D008 : changement de compte pendant la lecture, la reponse n est pas affichee' {
        Reset-SelectionFixture
        $a=Get-RaceRow 'A';Select-RaceRow $a;Send-RacePending;$job=$script:Requests[0]
        $script:Conn.BindUser='EXAMPLE\autre-lecteur'
        Complete-DomeniaOpenObjectTaskUi (Get-RaceResult $job) $job.State
        Assert-True ($script:Renders.Count -eq 0 -and $null -eq $script:SelectedObject) 'Lecture d un autre compte affichee.'
    }

    # ------------------------------------------------------------------ Suites : raccordement a la campagne
    # SE-15: the lab tools stay in the repository and are not shipped in the DEV archive; the discovery check needs them.
    $runnerPath=Join-Path $root 'engineering\d120\lab\Invoke-LabRun.ps1'
    $runner=if([IO.File]::Exists($runnerPath)){[IO.File]::ReadAllText($runnerPath)}else{$null}
    foreach($suite in @('Test-DomeniaRegressions.ps1','Test-DomeniaGeometry.ps1','Test-DomeniaFaults.ps1','Test-DomeniaWiringSuites.ps1')){
        $suitePath=Join-Path $PSScriptRoot $suite
        Test-Case ('Suites : '+$suite+' presente, analysable et au contrat de rapport') {
            Assert-True ([IO.File]::Exists($suitePath)) 'Suite absente.'
            $suiteAst=Read-SourceAst $suitePath
            $parameters=@($suiteAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
            Assert-True ($parameters -contains 'ReportPath' -and $parameters -contains 'Quiet') 'Parametres -ReportPath et -Quiet requis.'
            $text=[IO.File]::ReadAllText($suitePath)
            Assert-True ($text.Contains('Tests=') -and $text.Contains('exit 1') -and $text.Contains("Status='Failed'")) 'Rapport Tests[Name,Status,Detail] ou code de sortie absent.'
            Assert-True (($suite -like 'Test-*.ps1') -and (($null -eq $runner) -or $runner.Contains("-Filter 'Test-*.ps1'"))) 'Suite non decouverte par Invoke-LabRun.'
        }
    }
    Test-Case 'Suites : regles de courses chargees par le lanceur de regles' {
        $rules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-DomeniaRules.ps1'))
        $races=Join-Path $PSScriptRoot 'rules\Races.Tests.ps1'
        Assert-True ($rules.Contains("-Filter '*.Tests.ps1'") -and [IO.File]::Exists($races)) 'Races.Tests.ps1 non charge.'
        $null=Read-SourceAst $races
        Assert-True ([IO.File]::ReadAllText($races).Contains("Test-Case 'D008'")) 'Aucun cas D008.'
    }
    Test-Case 'Suites : aucun nombre d operations ecrit en dur dans les suites' {
        $offenders=[Collections.Generic.List[string]]::new()
        foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File)){
            $lineNumber=0
            foreach($line in [IO.File]::ReadAllLines($file.FullName)){
                $lineNumber++
                if($line -match '(?i)(OperationHashes|WorkerRegistry|registry|registre)[^\r\n]{0,80}-eq\s*(47|48|55|57)\b' -or $line -match "(?i)'(47|48|55|57) operations"){$offenders.Add($file.Name+':'+$lineNumber)}
            }
        }
        Assert-True ($offenders.Count -eq 0) ('Compteurs figes : '+($offenders -join ', '))
    }
    Test-Case 'Suites : bibliotheque de fixtures AD utilisee par les suites du lot' {
        $users=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File|Where-Object{[IO.File]::ReadAllText($_.FullName).Contains('Domenia-AdFixtures.ps1')})
        Assert-True ($users.Count -ge 2) ('Fixtures AD referencees par '+$users.Count+' suite(s).')
    }
}

$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$report=[ordered]@{
    Kind='WiringSuites';Lot='suites';Points=@('D004','D008','D005','D006','D007')
    Host=@{PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString();Sta=([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA')}
    NoADAccess=$true;NoNetwork=$true;NoWrite=$true
    Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0);Tests=$script:Checks.ToArray()
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-suites-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Status -AutoSize|Out-String|Write-Host;Write-Host ('Rapport : '+$ReportPath)}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
