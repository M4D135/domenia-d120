# Support recipes (point 110): Outils > Assistance. Loaded from Domenia-Assistance.xaml the first time its tab is
# chosen. A step runs only on its own click, only for the kind of object it concerns, and only through one of the
# existing explicit reads listed by Get-DomeniaAssistanceActions; its result is read in the view it opens.
$script:DomeniaAssistanceModuleRoot=$PSScriptRoot
$script:AssistanceView=$null
$script:AssistanceLaunched=@{}

function Register-DomeniaAssistanceTool {
    # Called once by Wire-Events. Nothing is loaded before the operator opens the tab.
    $tabs=Get-DomeniaControl 'ApplicationToolTabs'
    if(($null -eq $tabs) -or ($null -eq (Get-DomeniaControl 'WsAssistance'))){return}
    $tabs.Add_SelectionChanged({
        param($sender,$eventArgs)
        if(($null -ne $eventArgs) -and ($eventArgs.OriginalSource -ne $sender)){return}
        if($sender.SelectedItem -eq (Get-DomeniaControl 'WsAssistance')){Invoke-DomeniaSafeUiAction -Operation 'Assistance' -Action {Show-DomeniaAssistanceTool} -NoPopup}
    })
}

function Show-DomeniaAssistanceTool {
    Initialize-DomeniaAssistanceView
    if($null -eq $script:AssistanceView){return}
    Update-DomeniaAssistanceView
}

function Initialize-DomeniaAssistanceView {
    $tab=Get-DomeniaControl 'WsAssistance'
    if(($null -eq $tab) -or ($null -ne $script:AssistanceView)){return}
    $problems=@(Test-DomeniaAssistanceRecipes -Recipes @(Get-DomeniaAssistanceRecipes))
    if($problems.Count){throw ('Recettes dʼassistance invalides : '+($problems -join ' ; '))}
    [xml]$document=[IO.File]::ReadAllText((Join-Path $script:DomeniaAssistanceModuleRoot 'Domenia-Assistance.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $controls=@{}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if(-not $name){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de contrôle déjà présent : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Contrôle de lʼassistance introuvable : '+$name)}
        $controls[$name]=$control
    }
    foreach($name in $controls.Keys){$script:Ctrl[$name]=$controls[$name]}
    $tab.Content=$view
    $script:AssistanceView=$view
    [void](Set-DomeniaItemsSource 'CmbAssistanceRecipe' @(Get-DomeniaAssistanceRecipes))
    (Get-DomeniaControl 'CmbAssistanceRecipe').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Assistance' -Action {Update-DomeniaAssistanceView} -NoPopup})
    (Get-DomeniaControl 'DgAssistanceSteps').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Assistance' -Action {Update-DomeniaAssistanceStepDetail} -NoPopup})
    (Get-DomeniaControl 'BtnAssistanceRun').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Étape dʼassistance' -Action {Invoke-DomeniaAssistanceStep}})
    (Get-DomeniaControl 'BtnAssistanceOpen').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Étape dʼassistance' -Action {Open-DomeniaAssistanceStepView}})
    # Coming back to Outils with this tab already chosen raises no SelectionChanged: the view itself follows.
    $view.Add_IsVisibleChanged({
        param($sender,$eventArgs)
        if([bool]$sender.IsVisible){Invoke-DomeniaSafeUiAction -Operation 'Assistance' -Action {Update-DomeniaAssistanceView} -NoPopup}
    })
    $script:UxLayoutSignature=''
    if($null -ne (Get-Command Update-DomeniaUxLayout -CommandType Function -ErrorAction SilentlyContinue)){Update-DomeniaUxLayout}
}

function Get-DomeniaAssistanceSelection {
    # The object the steps apply to: the fiche currently open, with its session and generation.
    $selected=$script:SelectedObject
    if($null -eq $selected){return $null}
    $type=[string](Get-DomeniaMember $selected 'Type' '')
    if($type -notin @('Utilisateur','Machine')){return $null}
    return [pscustomobject]@{Type=$type;Name=[string](Get-DomeniaMember $selected 'Name' '');Dn=[string](Get-DomeniaMember $selected 'DN' '');Key=([string]$script:SessionEpoch+'|'+[string](Get-DomeniaMember $selected 'DN' ''))}
}

function Get-DomeniaAssistanceLaunchedMap {
    param($Selection,$Recipe)
    $map=@{}
    if(($null -eq $Selection) -or ($null -eq $Recipe)){return $map}
    $prefix=[string]$Selection.Key+'|'+[string]$Recipe.Id+'|'
    foreach($key in @($script:AssistanceLaunched.Keys)){if(([string]$key).StartsWith($prefix,[StringComparison]::Ordinal)){$map[([string]$key).Substring($prefix.Length)]=$script:AssistanceLaunched[$key]}}
    return $map
}

function Update-DomeniaAssistanceView {
    if($null -eq $script:AssistanceView){return}
    $selection=Get-DomeniaAssistanceSelection
    $type=''
    if($null -eq $selection){[void](Set-DomeniaControlText 'LblAssistanceSubject' 'Aucune sélection : ouvrez la fiche du compte ou du poste concerné.')}
    else{
        $type=[string]$selection.Type
        [void](Set-DomeniaControlText 'LblAssistanceSubject' ('Pour : '+(Get-DomeniaAssistanceSubjectLabel $type)+' · '+[string]$selection.Name))
    }
    $recipe=(Get-DomeniaControl 'CmbAssistanceRecipe').SelectedItem
    if($null -eq $recipe){
        [void](Set-DomeniaItemsSource 'DgAssistanceSteps' @())
        [void](Set-DomeniaControlText 'LblAssistanceRecipe' 'Choisissez une recette.')
        Update-DomeniaAssistanceStepDetail
        return
    }
    $grid=Get-DomeniaControl 'DgAssistanceSteps'
    $selectedId=if(($null -ne $grid) -and ($null -ne $grid.SelectedItem)){[string]$grid.SelectedItem.Id}else{''}
    $rows=@(ConvertTo-DomeniaAssistanceStepRows -Recipe $recipe -SelectionType $type -Launched (Get-DomeniaAssistanceLaunchedMap $selection $recipe))
    [void](Set-DomeniaItemsSource 'DgAssistanceSteps' $rows)
    if($selectedId -and ($null -ne $grid)){foreach($row in $rows){if([string]$row.Id -ceq $selectedId){$grid.SelectedItem=$row;break}}}
    [void](Set-DomeniaControlText 'LblAssistanceRecipe' ([string]$recipe.Symptom+' '+(Get-DomeniaAssistancePlanText $recipe)))
    Update-DomeniaAssistanceStepDetail
}

function Update-DomeniaAssistanceStepDetail {
    $row=$null
    $grid=Get-DomeniaControl 'DgAssistanceSteps'
    if($null -ne $grid){$row=$grid.SelectedItem}
    [void](Set-DomeniaControlEnabled 'BtnAssistanceRun' (($null -ne $row) -and [bool]$row.CanRun))
    [void](Set-DomeniaControlEnabled 'BtnAssistanceOpen' (($null -ne $row) -and [bool]$row.CanOpen))
    if($null -eq $row){[void](Set-DomeniaControlText 'LblAssistanceStep' 'Choisissez une étape.');return}
    [void](Set-DomeniaControlText 'LblAssistanceStep' ([string]$row.Title+' : '+[string]$row.State+'. Lit : '+[string]$row.Reads+' Coût : '+[string]$row.Cost))
}

function Open-DomeniaAssistanceRoute {
    # Opens the view of a step. A view that does not exist in this version is said as such, never guessed.
    param($Step)
    $workspace=[string]$Step.Workspace
    if(-not $workspace){return $false}
    if($null -eq (Get-DomeniaControl $workspace)){return $false}
    $inner=[string]$Step.Inner;$tab=[string]$Step.Tab
    # UX-21 (X04): a former tab of Assistance poste (TabSessions) is a known route to its view and section.
    $routed=(($inner -eq 'ComputerTabs') -and [bool](Resolve-DomeniaComputerViewRoute -Tab $tab).Known)
    if($tab -and (-not $routed) -and ($null -eq (Get-DomeniaControl $tab))){$inner='';$tab=''}
    Select-DomeniaWorkspace -Workspace $workspace -Inner $inner -Tab $tab
    if([string]$Step.AuditTab){
        # The Audit AD view is built at its first opening; its inner tab is chosen once it exists.
        Show-DomeniaAdAuditTool
        $outer=Get-DomeniaControl 'AdAuditTabs';$objectTab=Get-DomeniaControl 'TabAdAuditObject'
        if(($null -ne $outer) -and ($null -ne $objectTab)){$outer.SelectedItem=$objectTab}
        $innerTabs=Get-DomeniaControl 'AdAuditObjectTabs';$target=Get-DomeniaControl ([string]$Step.AuditTab)
        if(($null -ne $innerTabs) -and ($null -ne $target)){$innerTabs.SelectedItem=$target}
    }
    return $true
}

function Open-DomeniaAssistanceStepView {
    $row=(Get-DomeniaControl 'DgAssistanceSteps').SelectedItem
    if(($null -eq $row) -or (-not [bool]$row.CanOpen)){return}
    if(-not (Open-DomeniaAssistanceRoute $row.Step)){[void](Set-DomeniaControlText 'LblAssistanceStep' 'Vue de cette étape indisponible dans cette version.')}
}

function Get-DomeniaAssistanceTaskMarks {
    # Engine tasks of one operation, queued or running: task id -> number of subscribers of a shared read (D015).
    # Compared before and after a step by Test-DomeniaAssistanceDispatched.
    param([string]$OperationId)
    $marks=@{}
    if((-not $OperationId) -or ($null -eq $script:AsyncJobs)){return $marks}
    foreach($id in @($script:AsyncJobs.Keys)){
        $job=$script:AsyncJobs[$id]
        if(($null -eq $job) -or ([string](Get-DomeniaMember $job 'OperationId' '') -cne $OperationId)){continue}
        $subscribers=Get-DomeniaMemberValue $job 'Subscribers' $null
        $count=0
        if($null -ne $subscribers){$count=@($subscribers).Count}
        $marks[[string]$id]=$count
    }
    return $marks
}

function Invoke-DomeniaAssistanceStep {
    # One click, one read: the step's view is opened, then its single explicit read is started for the selection.
    $row=(Get-DomeniaControl 'DgAssistanceSteps').SelectedItem
    $recipe=(Get-DomeniaControl 'CmbAssistanceRecipe').SelectedItem
    if(($null -eq $row) -or ($null -eq $recipe)){return}
    $selection=Get-DomeniaAssistanceSelection
    $type=if($null -ne $selection){[string]$selection.Type}else{''}
    $state=Get-DomeniaAssistanceStepState -Step $row.Step -SelectionType $type
    if(-not $state.CanRun){[void](Set-DomeniaControlText 'LblAssistanceStep' ([string]$state.Text));return}
    $step=$row.Step
    $actions=Get-DomeniaAssistanceActions
    if(-not $actions.Contains([string]$step.Action)){throw 'Action dʼassistance non autorisée.'}
    $command=Get-Command -Name ([string]$step.Action) -CommandType Function -ErrorAction SilentlyContinue
    if($null -eq $command){[void](Set-DomeniaControlText 'LblAssistanceStep' 'Lecture indisponible dans cette version : rien nʼa été lancé.');return}
    [void](Open-DomeniaAssistanceRoute $step)
    $arguments=@{}
    foreach($key in @($step.Arguments.Keys)){$arguments[[string]$key]=$step.Arguments[$key]}
    # The operation comes from the closed list, never from the row: only a task of that read counts as a launch.
    $operation=[string]$actions[[string]$step.Action]
    $before=Get-DomeniaAssistanceTaskMarks $operation
    & $command @arguments
    if(-not (Test-DomeniaAssistanceDispatched -Before $before -After (Get-DomeniaAssistanceTaskMarks $operation))){
        # The action returned without sending its read (target not loaded, engine busy, refusal): its own view says why.
        [void](Set-DomeniaControlText 'LblAssistanceStep' ([string]$row.Title+' : rien nʼa été lancé, voir le message de la vue ouverte.'))
        return
    }
    $script:AssistanceLaunched[[string]$selection.Key+'|'+[string]$recipe.Id+'|'+[string]$step.Id]=[datetime]::UtcNow
    Update-DomeniaAssistanceView
    [void](Set-DomeniaControlText 'LblAssistanceStep' ([string]$row.Title+' : lecture demandée. Son résultat sʼaffiche dans la vue ouverte ; revenez ici pour lʼétape suivante.'))
}
