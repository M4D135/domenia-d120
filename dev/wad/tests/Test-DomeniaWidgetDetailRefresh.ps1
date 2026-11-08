# WDR — refresh des widgets Query a champs detail:* (relire la requete WMI memorisee, pas « relancez l'atelier »).
# Doubles et callbacks uniquement : aucun reseau, aucune WPF, aucune VM. Les fonctions d'interface testees sont
# extraites de Domenia-Widgets.UI.ps1 par l'AST (aucun type WPF n'est instancie) ; les regles pures viennent des
# modeles rellement charges. Asserts de comportement : qui est lance, dans quel ordre, ce qui est commit avant
# affichage, ce qui est conserve en echec.
param([switch]$Quiet)
$ErrorActionPreference='Stop'
$script:WdrPass=0;$script:WdrFail=0
function Assert-Wdr([bool]$Condition,[string]$Name){
    if($Condition){$script:WdrPass++;if(-not $Quiet){Write-Host ('  ok   '+$Name)}}
    else{$script:WdrFail++;Write-Host ('  FAIL '+$Name);throw ('assertion echouee : '+$Name)}
}
function Test-WdrCase([string]$Name,[scriptblock]$Body){
    if(-not $Quiet){Write-Host ('CAS '+$Name)}
    try{& $Body;if(-not $Quiet){Write-Host ('PASS '+$Name)}}
    catch{$script:WdrFail++;Write-Host ('FAIL '+$Name+' : '+$_.Exception.Message)}
}
$modules=Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'

# Portee minimale attendue par les modeles (les vrais objets sont toujours des pscustomobject ici).
function Get-DomeniaMember($Object,[string]$Name,$Default=$null){if($null -eq $Object){return $Default};$p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $Default}
function Get-DomeniaMemberValue($Object,[string]$Name){if($null -eq $Object){return $null};$p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $null}
function Get-DomeniaQueryTimestampKey([string]$Field){$i=$Field.LastIndexOf(':');if($i -gt 0){return '_at:'+($Field.Substring(0,$i))};return '_at:'+$Field}

. (Join-Path $modules 'Domenia-Query.Model.ps1')
. (Join-Path $modules 'Domenia-QuerySchema.Model.ps1')
. (Join-Path $modules 'Domenia-WidgetCollect.Model.ps1')

function Get-WdrFunctionText([string]$Path,[string[]]$Names){
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(($null -ne $errors)-and($errors.Count)){throw ('fichier non analyse : '+$Path)}
    foreach($name in $Names){
        $found=@($ast.FindAll({param($n)($n -is [System.Management.Automation.Language.FunctionDefinitionAst])},$true))|Where-Object{$_.Name -eq $name}|Select-Object -First 1
        if($null -eq $found){throw ('fonction absente de '+$Path+' : '+$name)}
        $found.Extent.Text
    }
}
foreach($wdrText in @(Get-WdrFunctionText (Join-Path $modules 'Domenia-Widgets.UI.ps1') @('Get-DomeniaWidgetNeed','Test-DomeniaWidgetOperationRunning','Get-DomeniaWidgetPopulationKey','Add-DomeniaWidgetCollectQueue','Get-DomeniaWidgetPopulation','Start-DomeniaWidgetRemoteCollect','Start-DomeniaWidgetDetailCollect','Complete-DomeniaWidgetDetailCollected','Fail-DomeniaWidgetDetailCollected','Complete-DomeniaWidgetDetailStored','Fail-DomeniaWidgetDetailStored','Start-DomeniaWidgetRefresh','Get-DomeniaWidgetDataDates'))){Invoke-Expression $wdrText}

# ---------------------------------------------------------------- doubles (defines apres les imports : ils gagnent)
$script:Calls=@();$script:Statuses=@();$script:Dialogs=0;$script:DialogAnswer='Yes';$script:UiTaskAdmits=$true
$script:ParkRunActive=$false;$script:StoreContextOk=$true;$script:SessionEpoch=7;$script:GlobalSearchGeneration=3
$script:DomeniaQueryModuleRoot='';$script:AsyncJobs=@{};$script:FleetStale=$false;$script:FleetJobId=''
$script:DomeniaWidgetCollectQueue=[Collections.ArrayList]::new();$script:DomeniaWidgetCollects=@{}
$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC1';DN='CN=PC1,OU=Test';Safety=[pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111'}}
$script:FleetTargets=@(
    [pscustomobject]@{name='PC1';distinguished_name='CN=PC1,OU=Test';object_guid='11111111-1111-1111-1111-111111111111'},
    [pscustomobject]@{name='PC2';distinguished_name='CN=PC2,OU=Test';object_guid='22222222-2222-2222-2222-222222222222'})
$script:Recipe=$null
function Reset-WdrState{$script:Calls=@();$script:Statuses=@();$script:Dialogs=0;$script:UiTaskAdmits=$true;$script:ParkRunActive=$false;$script:StoreContextOk=$true;$script:AsyncJobs=@{};[void]$script:DomeniaWidgetCollectQueue.Clear();$script:DomeniaWidgetCollects=@{}}
function Set-Status([string]$Text,[string]$Level='INFO'){$script:Statuses+=[pscustomobject]@{Text=$Text;Level=$Level}}
function Write-AppLog([string]$Text,[string]$Level='INFO'){}
function Show-DomeniaBoard {[CmdletBinding()]param([string]$Board,[switch]$Quiet,[switch]$DeferIfHidden);$script:Calls+=[pscustomobject]@{Kind='Board';Board=$Board}}
function Show-DomeniaDialog {param([string]$Title,[string]$Message,$Kind,[string]$Buttons);$script:Dialogs++;return $script:DialogAnswer}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,[int]$TimeoutSeconds,[int]$HardTimeoutSeconds,$TaskClass)
    $script:Calls+=[pscustomobject]@{Kind='UiTask';OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler}
    if(-not $script:UiTaskAdmits){return $null}
    return ('job-'+[string]$script:Calls.Count)}
function Start-DomeniaOnlinePark {[CmdletBinding()]param($ScopeTargets,$ScopeLabel,$Slot,$WidgetBoard,$WidgetIds,[switch]$PassThru,[switch]$Preapproved,[switch]$PingOnly,[switch]$WmiOnly,[switch]$NoConsole,[switch]$Inventory,$Probes,[switch]$ForceRefresh,$ReuseMaxAgeDays,$Out)
    $script:Calls+=[pscustomobject]@{Kind='Park';WidgetBoard=$WidgetBoard;WidgetIds=$WidgetIds};return 'run-1'}
function Test-DomeniaParkRunActive {[CmdletBinding()]param([string]$Slot,[switch]$Any)$script:ParkRunActive}
function Register-DomeniaWidgetCollect {param([string]$Board,[string[]]$Ids,[string]$Kind,[string]$RunId='',[string]$PopulationKey='');$script:Calls+=[pscustomobject]@{Kind='Register';Board=$Board;Ids=$Ids;RegisterKind=$Kind}}
function Initialize-DomeniaRemoteStoreState($State,$Guid,$Dn,$Generation){$State|Add-Member -NotePropertyName StoreGuid -NotePropertyValue $Guid -Force;$State|Add-Member -NotePropertyName StoreDn -NotePropertyValue $Dn -Force;$State|Add-Member -NotePropertyName StoreContext -NotePropertyValue ([pscustomobject]@{StoreId='store-1'}) -Force;return $true}
function Submit-DomeniaRemoteDetail {param($Data,$State,[bool]$Succeeded,[string]$SourceCompletedUtc,[string]$ErrorText='');$script:Calls+=[pscustomobject]@{Kind='Submit';Data=$Data;State=$State;Succeeded=$Succeeded};return $true}
function Test-DomeniaRemoteStoreContext($State,$Result){$script:StoreContextOk}
function Get-DomeniaFleetCollectionContext{[pscustomobject]@{Scope=[pscustomobject]@{Name='OU Test';Key='ou-test'};Targets=$script:FleetTargets}}
function Get-DomeniaFleetScope{[pscustomobject]@{Key='ou-test'}}
function Get-DomeniaWidgetRecipe([string]$Id){$script:Recipe}
function Get-DomeniaQueryRequestedFields($Recipe){$script:Fields}
function Get-DomeniaBoardLayout {[CmdletBinding()]param([string]$Board)@($script:Item)}
function Get-DomeniaBoardState([string]$Board){[pscustomobject]@{Data=$null;DataAtUtc=$null}}
function Get-DomeniaBoardItemIdentity {[CmdletBinding()]param([string]$Board,$Item)[pscustomobject]@{Title='Widget test';Kind='Number'}}
function Test-DomeniaBoardItemPaused {[CmdletBinding()]param($Item)$false}
function Get-DomeniaMsiProviderClassNames{@('MSI_Class')}
function Assert-DomeniaContractFormat {[CmdletBinding()]param([string]$Format,[string]$Family)if($Format -notlike ($Family+'/*')){throw 'format inconnu'};$Format}
function Get-DomeniaEffectiveWorkerResult {[CmdletBinding()]param($Result,[string[]]$RequiredProperties)$Result}
function Get-DomeniaQuerySchemaWorkerCode{'WORKER-CODE'}
function Get-DomeniaObservationMaxAgeDays{30}
function Get-DomeniaWidgetMaxTargets {return 500}
function Test-DomeniaParkTargetAdmission {[CmdletBinding()]param([int]$Count,[int]$Maximum)@{Allowed=$true;Maximum=500;Code=''}}
function Invoke-DomeniaOuRefresh {[CmdletBinding()]param([string]$Source,[string]$Mode,[string]$WidgetId,$WidgetNeed)}
function ConvertTo-DomeniaProbePayload {[CmdletBinding()]param([string[]]$Ids)@($Ids|ForEach-Object{[pscustomobject]@{Id=$_}})}
function ConvertFrom-DomeniaUtcText([string]$Text){$d=[datetime]::MinValue;if([datetime]::TryParse($Text,[ref]$d)){return $d.ToUniversalTime()};return $null}
function ConvertTo-DomeniaUtcDate($Value){if($Value -is [datetime]){return $Value.ToUniversalTime()};$d=[datetime]::MinValue;if(($null -ne $Value) -and [datetime]::TryParse([string]$Value,[ref]$d)){return $d.ToUniversalTime()};return $null}

# ---------------------------------------------------------------- preparation des recettes
$script:Definition=New-DomeniaQueryReadDefinition -Namespace 'root\cimv2' -Query 'SELECT DeviceID, Size FROM Win32_LogicalDisk' -Limit 10
$script:RequestKey=[string]$script:Definition.RequestKey
$script:Item=[pscustomobject]@{Id='w1';Source='Query';Key='recipe.test';Title='Widget test';Visual='Kpi'}

function New-WdrWorkerResult([string]$Computer){
    [pscustomobject]@{Computer=$Computer;Success=$true;Mode='Select';Namespace='root\cimv2';ClassName='Win32_LogicalDisk';CanonicalQuery=[string]$script:Definition.CanonicalQuery;RequestKey=$script:RequestKey;Rows=@();StoredCount=2;CountComplete=$true;Truncated=$false;Limit=10;DurationMs=12;SourceCompletedUtc=[datetime]::UtcNow.ToString('o')}
}

Test-WdrCase 'WDR-001 champ detail seul : une seule tache WMI bornee sur le poste selectionne, releve enregistre avant affichage' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    $need=Get-DomeniaWidgetNeed -Board Computer -Item $script:Item
    Assert-Wdr (([string]$need.Kind -eq 'WmiDetail') -and (@($need.DetailKeys).Count -eq 1)) 'besoin WmiDetail'
    $started=Start-DomeniaWidgetRefresh -Board Computer -Id 'w1' -Reason Add
    Assert-Wdr ([bool]$started) 'collecte demarree'
    $tasks=@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'})
    Assert-Wdr ($tasks.Count -eq 1) 'une seule tache'
    Assert-Wdr ($tasks[0].OperationId -eq 'WidgetWmiDetail') 'operation WidgetWmiDetail'
    Assert-Wdr (([string]$tasks[0].Payload.Mode -eq 'Select') -and ([string]$tasks[0].Payload.Query -ceq [string]$script:Definition.CanonicalQuery) -and ([string]$tasks[0].Payload.Computer -eq 'PC1')) 'requete = SELECT memorise de la recette, sur le poste selectionne'
    Assert-Wdr (([string]$tasks[0].State.ResultKind -eq 'WmiQuery') -and ([string]$tasks[0].State.RequestKey -ceq $script:RequestKey)) 'identite du releve : WmiQuery + RequestKey de la recette'
    Assert-Wdr ($tasks[0].SuccessHandler -eq 'Complete-DomeniaWidgetDetailCollected') 'commit d abord, affichage apres'
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'Register'}).RegisterKind -contains 'WmiDetail') 'progression du widget suivie'
    Assert-Wdr ($script:Dialogs -eq 0) 'Ajout explicite : aucune confirmation jusqu a la limite'
}

Test-WdrCase 'WDR-002 widget a sources melees : releves poste ET requete memorisee, aucune source ignoree' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@('probe:p1',('detail:'+$script:RequestKey+':exists'))
    $need=Get-DomeniaWidgetNeed -Board Fleet -Item $script:Item
    Assert-Wdr (([string]$need.Kind -eq 'Remote') -and (@($need.DetailKeys).Count -eq 1)) 'besoin Remote portant le releve memorise'
    $started=Start-DomeniaWidgetRefresh -Board Fleet -Id 'w1' -Reason Refresh
    Assert-Wdr ([bool]$started) 'collecte demarree'
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'Park'}).Count -eq 1) 'releve des postes lance'
    $tasks=@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'})
    Assert-Wdr ($tasks.Count -eq 2) 'releve WMI memorise lance pour chaque poste de l OU'
    Assert-Wdr ((@($tasks|Where-Object{[string]$_.Payload.Computer -in @('PC1','PC2')}).Count -eq 2)) 'les deux postes de l OU sont couverts'
}

Test-WdrCase 'WDR-003 contexte perime : rien n est affiche ni annonce' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    [void](Start-DomeniaWidgetRefresh -Board Computer -Id 'w1' -Reason Add)
    $task=@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'})[0]
    Reset-WdrState
    $script:StoreContextOk=$false
    Complete-DomeniaWidgetDetailStored -Result ([pscustomobject]@{SourceCompletedUtc=[datetime]::UtcNow.ToString('o')}) -State $task.State
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'Board'}).Count -eq 0) 'aucun redessin sur contexte perime'
    Assert-Wdr ($script:Statuses.Count -eq 0) 'aucune annonce sur contexte perime'
    $script:SessionEpoch=8
    $script:StoreContextOk=$true
    Complete-DomeniaWidgetDetailStored -Result ([pscustomobject]@{SourceCompletedUtc=[datetime]::UtcNow.ToString('o')}) -State $task.State
    Assert-Wdr ($script:Statuses.Count -eq 0) 'session ecoulee : rien non plus'
}

Test-WdrCase 'WDR-004 delai puis poste suivant : valeurs conservees, autres postes lus' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    $started=Start-DomeniaWidgetRefresh -Board Fleet -Id 'w1' -Reason Refresh
    Assert-Wdr ([bool]$started) 'relecture admise apres confirmation'
    Assert-Wdr ($script:Dialogs -eq 1) 'Actualiser d une OU confirme le nombre de postes'
    $tasks=@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'})
    Assert-Wdr ($tasks.Count -eq 2) 'les deux postes sont partis independamment'
    $pc1=@($tasks|Where-Object{[string]$_.Payload.Computer -eq 'PC1'})[0]
    Fail-DomeniaWidgetDetailCollected -Message 'delai depasse' -State $pc1.State
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'Submit'}).Count -eq 0) 'aucune ligne d erreur commitee : les valeurs precedentes restent la mesure'
    Assert-Wdr (@($script:Statuses|Where-Object{$_.Text -like '*PC1*'}).Count -eq 1) 'le poste en echec est nomme'
    Assert-Wdr (@($tasks|Where-Object{[string]$_.Payload.Computer -eq 'PC2'}).Count -eq 1) 'le poste suivant est lu'
}

Test-WdrCase 'WDR-005 persistance avant affichage, puis source et date reelles' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    [void](Start-DomeniaWidgetRefresh -Board Computer -Id 'w1' -Reason Add)
    $task=@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'})[0]
    Reset-WdrState
    Complete-DomeniaWidgetDetailCollected -Result (New-WdrWorkerResult 'PC1') -State $task.State
    $order=@($script:Calls|Where-Object{$_.Kind -in @('Submit','Board')})
    Assert-Wdr (($order.Count -eq 1) -and ($order[0].Kind -eq 'Submit')) 'commit demande, aucun affichage depuis le resultat reseau'
    Assert-Wdr (([bool]$order[0].Succeeded) -and ([string]$order[0].State.PublishHandler -eq 'Complete-DomeniaWidgetDetailStored')) 'affichage branche apres le commit'
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'Board'}).Count -eq 0) 'rien affiche avant le commit'
    Complete-DomeniaWidgetDetailStored -Result ([pscustomobject]@{SourceCompletedUtc=[datetime]::UtcNow.ToString('o')}) -State $task.State
    $order=@($script:Calls|Where-Object{$_.Kind -in @('Submit','Board')})
    Assert-Wdr (($order.Count -eq 2) -and ($order[0].Kind -eq 'Submit') -and ($order[1].Kind -eq 'Board')) 'redessine seulement apres commit'
    Assert-Wdr (@($script:Statuses|Where-Object{$_.Text -like '*dans la base locale le*'}).Count -eq 1) 'source et date reelles annoncees'
    Reset-WdrState
    $bad=New-WdrWorkerResult 'AUTRE-POSTE'
    Complete-DomeniaWidgetDetailCollected -Result $bad -State $task.State
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'Submit'}).Count -eq 0) 'resultat d un autre poste refuse, rien commit'
}

Test-WdrCase 'WDR-006 releve deja en cours : le widget est mis en file, jamais oublie' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    $script:AsyncJobs=@{j1=[pscustomobject]@{OperationId='WidgetWmiDetail'}}
    $started=Start-DomeniaWidgetRefresh -Board Computer -Id 'w1' -Reason Refresh
    Assert-Wdr ([bool]$started) 'demande acceptee'
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'}).Count -eq 0) 'aucune seconde campagne demarree'
    Assert-Wdr (($script:DomeniaWidgetCollectQueue.Count -eq 1) -and ([string]$script:DomeniaWidgetCollectQueue[0].Id -eq 'w1')) 'le widget attend dans la file'
}

Test-WdrCase 'WDR-007 recette sans definition exploitable : refus nomme, aucune collecte' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$null}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    $need=Get-DomeniaWidgetNeed -Board Computer -Item $script:Item
    Assert-Wdr (([string]$need.Kind -ne 'WmiDetail') -and ([string]$need.DetailBlocked)) 'le modele refuse deja'
    $started=Start-DomeniaWidgetDetailCollect -Board Computer -Item $script:Item -Need $need -Reason Refresh
    Assert-Wdr ((-not [bool]$started) -and (@($script:Calls|Where-Object{$_.Kind -eq 'UiTask'}).Count -eq 0)) 'aucune lecture lancee'
    Assert-Wdr (@($script:Statuses|Where-Object{$_.Text -like '*refus*'}).Count -eq 1) 'refus nomme'
}

Test-WdrCase 'WDR-008 pied de page : dates reelles du releve memorise reprises de la base locale, sans relecture' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    $old=([datetime]::UtcNow).AddHours(-5)
    $new=([datetime]::UtcNow).AddHours(-2)
    $script:DomeniaQueryState=[pscustomobject]@{SnapshotKey='snap-1';Widgets=@{'recipe.test'=[pscustomobject]@{DataSources=@(
        [pscustomobject]@{Source='SELECT WMI mémorisé';OldestUtc=$old.ToString('o');NewestUtc=$new.ToString('o');Missing=2})}}}
    $shown=Get-DomeniaWidgetDataDates -Board Computer -Item $script:Item -State (Get-DomeniaBoardState Computer) -Entry $null
    $expected=$old.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)
    Assert-Wdr (($shown.Text -like '*WMI · requête mémorisée*') -and ($shown.Text -like ('*'+$expected+'*'))) 'la date reelle du releve memorise apparait au pied de page'
    Assert-Wdr ($shown.Text -notlike '*non daté*') 'plus de « non daté » quand la base porte l horloge'
    Assert-Wdr ($shown.Text -like '*2 non lu(s)*') 'les postes non lus du releve sont reportes'
    Assert-Wdr (@($script:Calls|Where-Object{$_.Kind -in @('UiTask','Park')}).Count -eq 0) 'le simple affichage ne declenche aucune lecture'
    $script:DomeniaQueryState=$null
    $blank=Get-DomeniaWidgetDataDates -Board Computer -Item $script:Item -State (Get-DomeniaBoardState Computer) -Entry $null
    Assert-Wdr ($blank.Text -like '*non daté*') 'sans horloge conservee le pied de page dit non date, sans rien inventer'
}

Test-WdrCase 'WDR-009 board Software : la date de la liste des logiciels n ecrase jamais l horloge du releve memorise' {
    Reset-WdrState
    $script:Recipe=[pscustomobject]@{Name='Recette test';ReadDefinition=$script:Definition}
    $script:Fields=@(('detail:'+$script:RequestKey+':count'))
    $old=([datetime]::UtcNow).AddHours(-5)
    $new=([datetime]::UtcNow).AddHours(-2)
    $soft=([datetime]::UtcNow).AddMinutes(-9)
    $script:DomeniaQueryState=[pscustomobject]@{SnapshotKey='snap-1';Widgets=@{'recipe.test'=[pscustomobject]@{DataSources=@(
        [pscustomobject]@{Source='SELECT WMI mémorisé';OldestUtc=$old.ToString('o');NewestUtc=$new.ToString('o');Missing=0})}}}
    $state=[pscustomobject]@{Data=[pscustomobject]@{ObservedAtUtc=$soft.ToString('o')}}
    $shown=Get-DomeniaWidgetDataDates -Board Software -Item $script:Item -State $state -Entry $null
    $expected=$old.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)
    $softText=$soft.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)
    Assert-Wdr (($shown.Text -like '*WMI · requête mémorisée*') -and ($shown.Text -like ('*'+$expected+'*'))) 'l horloge reelle du releve memorise reste affichee'
    Assert-Wdr ($shown.Text -notlike ('*'+$softText+'*')) 'la date de la liste des logiciels n ecrase pas le releve'
    $script:DomeniaQueryState=$null
}

Write-Host ('WDR : '+[string]$script:WdrPass+' reussis, '+[string]$script:WdrFail+' en echec')
if($script:WdrFail){exit 1}
exit 0
