#requires -Version 5.1
# Point 1 (feuille de route du 13/10/2026) : chaque collecte AD, ping, WMI ou détail n'atteint l'interface qu'après
# validation SQLite. Preuve statique sur les sources livrées : appariement opération / corps épinglé, enregistrement
# de chaque rappel de collecte, publication depuis la seule relecture validée, horloges d'OU publiées après reçu,
# et absence d'appel au vieux ping de résultats non enregistré. Aucun AD, réseau, SQLite ni WPF.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules';$dev=Split-Path -Parent $wad
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect([bool]$Ok,[string]$Message='Assertion failed'){if(-not $Ok){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$true;Error=''})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$false;Error=$_.Exception.Message})}}
function Read-Ast([string]$Path){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);if($errors.Count){throw ('Analyse impossible : '+$Path)};return $ast}
$script:Sources=[ordered]@{}
foreach($path in @((Join-Path $wad 'Domenia-Core.ps1'))+@(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File|Sort-Object Name|ForEach-Object{$_.FullName})){$script:Sources[$path]=Read-Ast $path}
function Get-SourceFunction([string]$Name){
    # Top-level definitions only: here-string worker bodies are text, not functions of the interface.
    $found=@(foreach($ast in $script:Sources.Values){foreach($statement in @($ast.EndBlock.Statements)){if($statement -is [Management.Automation.Language.FunctionDefinitionAst] -and $statement.Name -ceq $Name){$statement}}})
    if($found.Count -ne 1){throw ('Fonction absente ou ambiguë : '+$Name+' ('+$found.Count+')')}
    return $found[0]
}
function Get-CalledNames($Ast){@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})}
function Get-ParameterArgument($Command,[string]$Name){
    $elements=@($Command.CommandElements)
    for($i=0;$i -lt $elements.Count;$i++){
        $element=$elements[$i]
        if(($element -is [Management.Automation.Language.CommandParameterAst]) -and ($element.ParameterName -ieq $Name)){
            if($null -ne $element.Argument){return $element.Argument}
            if($i+1 -lt $elements.Count){return $elements[$i+1]}
        }
    }
    return $null
}

Case 'Chaque collecte lancée exécute le corps épinglé pour son opération' {
    $contracts=@{};foreach($item in @(Get-Content -LiteralPath (Join-Path $dev 'tools/operation-contracts.json') -Raw -Encoding UTF8|ConvertFrom-Json)){$contracts[[string]$item.Operation]=[string]$item.Function}
    $pairs=0;$mismatches=[Collections.Generic.List[string]]::new()
    foreach($path in $script:Sources.Keys){
        foreach($command in @($script:Sources[$path].FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-UiTask'},$true))){
            $operation=Get-ParameterArgument $command 'OperationId';$code=Get-ParameterArgument $command 'Code'
            if(($operation -isnot [Management.Automation.Language.StringConstantExpressionAst]) -or ($code -isnot [Management.Automation.Language.ParenExpressionAst])){continue}
            $inner=@($code.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
            if($inner.Count -ne 1){continue}
            $pairs++;$name=[string]$operation.Value;$body=[string]$inner[0].GetCommandName()
            if(-not $contracts.ContainsKey($name)){$mismatches.Add($name+' : opération non épinglée ('+[IO.Path]::GetFileName($path)+')');continue}
            if($contracts[$name] -cne $body){$mismatches.Add($name+' : corps '+$body+', contrat '+$contracts[$name]+' ('+[IO.Path]::GetFileName($path)+')')}
        }
    }
    Expect ($pairs -ge 10) ('Trop peu de lancements analysés : '+$pairs)
    Expect ($mismatches.Count -eq 0) ('Appariements refusés par le moteur : '+($mismatches -join ' ; '))
}
Case 'Le ping du poste sélectionné utilise le corps de sonde épinglé sans identifiants' {
    $start=Get-SourceFunction 'Start-DomeniaCommittedPresence'
    $command=@($start.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-UiTask'},$true))
    Expect ($command.Count -eq 1) 'Lancement du ping sélectionné introuvable'
    Expect ([string](Get-ParameterArgument $command[0] 'OperationId').Value -ceq 'LiveSelectedPing') 'Opération du ping sélectionné inattendue'
}
Case 'Chaque rappel de collecte enregistre dans SQLite avant toute publication' {
    $publishers=@('Set-DomeniaResultRowPresence','Update-DomeniaParkResultRows','Set-DomeniaLiveObservationOnRow','Complete-DomeniaInventoryUi','Set-DomeniaPresenceText','Update-DomeniaObjectPresence')
    $routes=@{
        'Complete-DomeniaParkSession'='Submit-DomeniaRemoteObservations';'Fail-DomeniaParkSession'='Complete-DomeniaParkSession'
        'Complete-DomeniaLiveProbe'='Submit-DomeniaRemoteObservations';'Fail-DomeniaLiveProbe'='Complete-DomeniaLiveProbe'
        'Complete-DomeniaCommittedPresence'='Submit-DomeniaRemoteObservations';'Fail-DomeniaCommittedPresence'='Complete-DomeniaCommittedPresence'
        'Complete-DomeniaLastUserCollected'='Submit-DomeniaRemoteDetail';'Fail-DomeniaLastUserCollected'='Submit-DomeniaRemoteDetail'
        'Complete-DomeniaClassicCollected'='Submit-DomeniaRemoteDetail';'Fail-DomeniaClassicCollected'='Submit-DomeniaRemoteDetail'
        'Complete-DomeniaSessionsCollected'='Submit-DomeniaRemoteDetail';'Fail-DomeniaSessionsCollected'='Submit-DomeniaRemoteDetail'
    }
    foreach($name in @($routes.Keys)){
        $called=@(Get-CalledNames (Get-SourceFunction $name))
        Expect ($called -ccontains $routes[$name]) ($name+' ne passe pas par '+$routes[$name])
        foreach($publisher in $publishers){Expect ($called -cnotcontains $publisher) ($name+' publie sans relecture SQLite : '+$publisher)}
    }
    $writer=@(Get-CalledNames (Get-SourceFunction 'Submit-DomeniaRemoteChanges'))
    Expect (($writer -ccontains 'ConvertTo-DomeniaStoreBatch') -and ((@(Get-CalledNames (Get-SourceFunction 'Invoke-DomeniaRemoteStoreQueue'))) -ccontains 'Submit-DomeniaStoreBatch')) 'File distante hors du lot SQLite'
}
Case 'Les mesures publiées sont relues dans le reçu SQLite du lot' {
    foreach($name in @('Complete-DomeniaParkStored','Complete-DomeniaLiveStored','Publish-DomeniaCommittedPresence')){
        Expect ((@(Get-CalledNames (Get-SourceFunction $name))) -ccontains 'Get-DomeniaCommittedObservation') ($name+' publie autre chose que la relecture validée')
    }
    $receipt=(Get-SourceFunction 'Complete-DomeniaRemoteStoreBatch').Extent.Text
    Expect ($receipt.Contains("-cne 'SQLite'") -and $receipt.Contains('BatchId') -and $receipt.Contains('StoreId')) 'Reçu SQLite non vérifié avant publication'
    $context=(Get-SourceFunction 'Test-DomeniaRemoteStoreContext').Extent.Text
    Expect ($context.Contains("DataSource -cne 'SQLite'") -and $context.Contains('RequestId')) 'Contexte de publication sans source SQLite'
    Expect ((@(Get-CalledNames (Get-SourceFunction 'Complete-DomeniaRemoteDetailStored'))) -ccontains 'Test-DomeniaRemoteStoreContext') 'Détail publié sans contrôle du reçu'
}
Case 'Les horloges des relevés d OU ne sont affichées qu après leur reçu SQLite' {
    Expect ((@(Get-CalledNames (Get-SourceFunction 'Submit-DomeniaOuRefreshRuns'))) -ccontains 'Submit-DomeniaStoreBatch') 'Horloges hors du lot SQLite'
    $complete=Get-SourceFunction 'Complete-DomeniaOuRefreshRunsStored'
    Expect ($complete.Extent.Text.Contains("'SQLite'") -and ((@(Get-CalledNames $complete)) -ccontains 'Request-DomeniaFleetRefresh')) 'Horloges publiées sans relecture'
    $dashboard=(Get-SourceFunction 'Start-DomeniaFleetDashboard').Extent.Text
    Expect ($dashboard.Contains("Action='FleetStats'") -and $dashboard.Contains('RunKeys=$runKeys') -and $dashboard.Contains('Get-DomeniaLocalIndexReadWorkerCode')) 'Tableau de bord hors instantané SQLite'
}
Case 'Le vieux ping de résultats non enregistré n a plus aucun appelant' {
    $callers=@(foreach($path in $script:Sources.Keys){@($script:Sources[$path].FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-DomeniaResultPresenceScan'},$true))})
    Expect ($callers.Count -eq 0) 'Start-DomeniaResultPresenceScan publie un ping sans SQLite et classe une erreur en hors ligne : ne pas le rappeler'
}
$failed=@($script:Checks|Where-Object{-not $_.Pass})
$report=[pscustomobject]@{Suite='Domenia.CollectCircuit';Platform=[Environment]::OSVersion.Platform.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();Pass=$script:Checks.Count-$failed.Count;Fail=$failed.Count;Tests=$script:Checks.ToArray();Limitations='Preuve statique sur les sources (AST) : aucune exécution de worker, d AD, de réseau, de SQLite ni de WPF.'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 6
if($failed.Count){exit 1}
