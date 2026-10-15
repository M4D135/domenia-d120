#requires -Version 5.1
# Pure presentation of estimates and reviewed intervention plans.

function Format-DomeniaByteEstimate {
    param([long]$Bytes)
    if($Bytes -ge 1GB){return ("{0:N2} Go" -f ($Bytes/1GB))}
    if($Bytes -ge 1MB){return ("{0:N1} Mo" -f ($Bytes/1MB))}
    if($Bytes -ge 1KB){return ("{0:N1} Ko" -f ($Bytes/1KB))}
    return "$Bytes octets"
}

function Format-DomeniaOperationImpact {
    # UX-07: the estimate in one sentence for the operator, « Environ 2 min · 238 objets lus dans lʼannuaire ·
    # aucun poste contacté », and the technical figures apart for the folded Expert part. No engine vocabulary.
    param($Estimate)
    if ($null -eq $Estimate) { return [pscustomobject]@{Sentence='';Details=''} }
    $seconds = [Math]::Max(1,[int][Math]::Ceiling([long]$Estimate.DurationMs/1000.0))
    $duration = 'Moins dʼune minute'
    if ($seconds -ge 3600) { $duration = 'Environ ' + ('{0:N1}' -f ($seconds/3600.0)) + ' h' }
    elseif ($seconds -ge 60) { $duration = 'Environ ' + [int][Math]::Ceiling($seconds/60.0) + ' min' }
    $items = [int]$Estimate.ItemCount
    $operation = [string]$Estimate.Operation
    $directory = 'aucune lecture dans lʼannuaire'
    if ($operation -eq 'IndexBuild') { $directory = ('{0:N0}' -f $items) + ' objet(s) lu(s) dans lʼannuaire' }
    elseif ($operation -eq 'LogonHarvest') { $directory = 'jusquʼà ' + ('{0:N0}' -f $items) + ' événement(s) lu(s) dans le journal du contrôleur' }
    elseif ([int]$Estimate.AdQueries -gt 0) { $directory = ('{0:N0}' -f [int]$Estimate.AdQueries) + ' lecture(s) dans lʼannuaire' }
    $workstations = 'aucun poste contacté'
    if ([int]$Estimate.RemoteAttempts -gt 0) { $workstations = ('{0:N0}' -f [int]$Estimate.RemoteAttempts) + ' poste(s) contacté(s)' }
    $dot = ' ' + [string][char]0x00B7 + ' '
    $sentence = $duration + $dot + $directory + $dot + $workstations
    $impactText = @{Eleve='élevée';Modere='modérée';Faible='faible'}
    $load = [string]$Estimate.Impact
    if ($impactText.ContainsKey($load)) { $load = [string]$impactText[$load] } elseif ($load -match '(?i)aucun') { $load = 'aucune lecture directe de lʼannuaire' }
    $rate = 'quasi nul'
    if ([double]$Estimate.AverageMbitPerSecond -ge 1) { $rate = ('{0:N2} Mbit/s' -f [double]$Estimate.AverageMbitPerSecond) }
    elseif ([double]$Estimate.AverageMbitPerSecond -gt 0) { $rate = ('{0:N1} kbit/s' -f ([double]$Estimate.AverageMbitPerSecond*1000)) }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('Éléments à traiter : ' + ('{0:N0}' -f $items))
    $lines.Add('Volume réseau estimé : ' + (Format-DomeniaByteEstimate ([long]$Estimate.Bytes)) + ' ; débit moyen : ' + $rate)
    $lines.Add('Traitements en parallèle : ' + [int]$Estimate.Concurrency + ' ; débit de pointe estimé : ' + ('{0:N2} Mbit/s' -f [double]$Estimate.PeakMbitPerSecond))
    if ([int]$Estimate.AdQueries -gt 0) { $lines.Add('Lectures dans lʼannuaire : ' + [int]$Estimate.AdQueries + ', environ ' + ('{0:N2}' -f [double]$Estimate.AdQueriesPerSecond) + ' par seconde') }
    if ([int]$Estimate.RemoteAttempts -gt 0) { $lines.Add('Repli à distance : ' + [int]$Estimate.FallbackTasks + ' tâche(s) planifiée(s) probable(s) sur ' + [int]$Estimate.RemoteAttempts + ' poste(s), environ ' + [int]$Estimate.SchedulerRpc + ' appel(s) au Planificateur de tâches') }
    $lines.Add('Charge estimée du contrôleur : ' + $load)
    $basis = 'initiale, aucune exécution comparable mesurée'
    if ([int]$Estimate.Samples -gt 0) { $basis = ([string]$Estimate.Confidence).ToLowerInvariant() + ', calibrée sur ' + [int]$Estimate.Samples + ' exécution(s) réelle(s)' }
    $lines.Add('Fiabilité de lʼestimation : ' + $basis)
    if ([int]$Estimate.Samples -gt 0) {
        $history = 'Historique : ' + [Math]::Round([double]$Estimate.AverageMsPerItem,0) + ' ms par élément en moyenne'
        if (([double]$Estimate.MinMsPerItem -gt 0) -and ([double]$Estimate.MaxMsPerItem -gt 0)) { $history += ', de ' + [Math]::Round([double]$Estimate.MinMsPerItem,0) + ' à ' + [Math]::Round([double]$Estimate.MaxMsPerItem,0) + ' ms' }
        if ([double]$Estimate.SuccessPct -gt 0) { $history += ', ' + [int]$Estimate.SuccessPct + ' % de réussite' }
        $lines.Add($history)
    }
    $lines.Add('Domenia enregistre la durée, le volume estimé et les réussites dans Domenia.db pour affiner les prochaines estimations.')
    return [pscustomobject]@{Sentence=$sentence;Details=($lines.ToArray() -join "`r`n")}
}

function Format-DomeniaPlanConfirmation {
    param($Plan)
    if ($Plan -isnot [Domenia.InterventionPlan]) { return '' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('Cible : ' + [string]$Plan.Target.Type + ' | ' + [string]$Plan.Target.Name + ' | ' + [string]$Plan.Target.DN)
    [void]$lines.Add('Domaine : ' + [string]$Plan.Target.Domain)
    [void]$lines.Add('GUID : ' + [string]$Plan.Target.Guid)
    [void]$lines.Add('Destinataire : ' + [string]$Plan.Server)
    [void]$lines.Add('Compte : ' + [string]$Plan.Account)
    foreach ($change in @($Plan.Changes)) {
        $before = ([string]$change.Before) -replace '[\r\n]+',' '
        $after = ([string]$change.After) -replace '[\r\n]+',' '
        [void]$lines.Add([string]$change.Attribute + ' (' + [string]$change.Kind + ') : [' + $before + '] -> [' + $after + ']')
    }
    foreach ($effect in @($Plan.Effects)) {
        # The replacement is computed apart: inside .Add(...) its comma would be read as a second argument.
        $effectLine = ([string]$effect) -replace '[\r\n]+',' '
        [void]$lines.Add($effectLine)
    }
    $fp = [string]$Plan.Fingerprint
    if ($fp) {
        if ($fp.Length -gt 12) { $fp = $fp.Substring(0,12) }
        [void]$lines.Add('Empreinte du plan : ' + $fp)
    }
    return ($lines.ToArray() -join "`r`n")
}
