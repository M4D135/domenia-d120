function Get-DomeniaServiceControlWorkerCode {
return @'
# UX-38 (X04): start or restart one service of the selected workstation through CIM (Win32_Service). The start type
# is never changed. The CIM session is opened before any request: a refused connection sends nothing (receipt
# NotSent). A refusal returned by the service manager restarts nothing and is said as such; a timeout or an unknown
# failure keeps the receipt to verify. The state is read again afterwards: Running is the proof, nothing is replayed.
$computer=[string]$Payload.Computer;$service=[string]$Payload.Service;$action=[string]$Payload.Action
if(($service.Length -lt 1) -or ($service.Length -gt 256) -or ($service -cne $service.Trim()) -or ($service -notmatch '^[A-Za-z0-9 _.$@+#,(){}-]+$')){throw 'Nom de service refusé : aucune commande envoyée.'}
if($action -notin @('Start','Restart')){throw 'Action de service inconnue : aucune commande envoyée.'}
$codes=@{1='commande non prise en charge';2='accès refusé';3='des services dépendants sont en cours';4='commande invalide pour ce service';5='le service nʼaccepte pas cette commande maintenant';6='le service nʼest pas en cours';7='le service nʼa pas répondu à temps';8='échec inconnu';9='programme du service introuvable';10='le service est déjà en cours';11='base des services verrouillée';12='une dépendance a été supprimée';13='une dépendance nʼa pas démarré';14='le service est désactivé';15='ouverture de session du service refusée';16='le service est marqué pour suppression';17='aucun thread pour le service';18='dépendance circulaire';19='nom en double';20='nom invalide';21='paramètre invalide';22='compte du service invalide';23='le service existe déjà';24='le service est déjà en pause'}
$explain={param([int]$Code) if($codes.ContainsKey($Code)){return [string]$codes[$Code]};return ('code '+$Code)}
$states=@{'Running'='en cours';'Stopped'='arrêté';'Start Pending'='démarrage en cours';'Stop Pending'='arrêt en cours';'Paused'='en pause';'Pause Pending'='mise en pause en cours';'Continue Pending'='reprise en cours'}
$label={param([string]$State) if($states.ContainsKey($State)){return [string]$states[$State]};if($State){return $State};return 'état non lu'}
$readState={param($Session,[string]$Name) $item=@(Get-CimInstance -CimSession $Session -ClassName Win32_Service -Filter ("Name='"+$Name+"'") -ErrorAction Stop);if($item.Count -ne 1){return $null};return $item[0]}
$waitState={param($Session,[string]$Name,[string]$Wanted,[int]$Seconds) $limit=[DateTime]::UtcNow.AddSeconds($Seconds);$last=$null;do{$last=& $readState $Session $Name;if(($null -ne $last) -and ([string]$last.State -eq $Wanted)){return $last};Start-Sleep -Milliseconds 800}while([DateTime]::UtcNow -lt $limit);return $last}
$cred=Get-WMachineCredential $Context;$session=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
$lease=Enter-WCredentialAttempt -Context $Context -Channel Remote
try{
    try{$session=New-WDomeniaCimSession $Context $computer $cred 15}
    catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw};throw ('Non envoyé : le poste nʼaccepte pas la commande à distance. '+$_.Exception.Message)}
}finally{Exit-WCredentialAttempt -Lease $lease}
try{
    $svc=& $readState $session $service
    if($null -eq $svc){throw ('Service '+$service+' introuvable sur '+$computer+' : aucune commande envoyée.')}
    $display=[string]$svc.DisplayName;if(-not $display){$display=$service}
    $before=[string]$svc.State
    if([string]$svc.StartMode -eq 'Disabled'){throw ('« '+$display+' » est désactivé : aucune commande envoyée. Domenia ne change pas son type de démarrage.')}
    if(($action -eq 'Start') -and ($before -ne 'Stopped')){throw ('« '+$display+' » nʼest pas arrêté ('+(& $label $before)+') : aucune commande envoyée.')}
    if(($action -eq 'Restart') -and ($before -ne 'Running')){throw ('« '+$display+' » nʼest pas en cours ('+(& $label $before)+') : aucune commande envoyée.')}
    $DomeniaWriteDispatched=$true
    if($action -eq 'Restart'){
        $stop=Invoke-CimMethod -InputObject $svc -MethodName StopService -ErrorAction Stop
        $stopCode=[int]$stop.ReturnValue
        if($stopCode -ne 0){
            # The service manager refused the stop: nothing was stopped, except after a timeout or an unknown failure.
            if($stopCode -notin @(7,8)){$DomeniaWriteDispatched=$false}
            throw ('Arrêt de « '+$display+' » refusé : '+(& $explain $stopCode)+'. '+$(if($DomeniaWriteDispatched){'État à vérifier sur le poste.'}else{'Rien nʼa été modifié.'}))
        }
        $stopped=& $waitState $session $service 'Stopped' 30
        if(($null -eq $stopped) -or ([string]$stopped.State -ne 'Stopped')){throw ('« '+$display+' » ne sʼest pas arrêté en 30 s : il nʼa pas été relancé. État à vérifier sur le poste.')}
        $svc=$stopped
    }
    $start=Invoke-CimMethod -InputObject $svc -MethodName StartService -ErrorAction Stop
    $startCode=[int]$start.ReturnValue
    if($startCode -ne 0){
        if(($action -eq 'Start') -and ($startCode -notin @(7,8))){$DomeniaWriteDispatched=$false}
        $tail=if($action -eq 'Restart'){'Le service a été arrêté et nʼa pas redémarré : à vérifier sur le poste.'}elseif($DomeniaWriteDispatched){'État à vérifier sur le poste.'}else{'Rien nʼa été modifié.'}
        throw ('Démarrage de « '+$display+' » refusé : '+(& $explain $startCode)+'. '+$tail)
    }
    $sent=[DateTime]::UtcNow.ToString('o')
    $after=& $waitState $session $service 'Running' 20
    $state=if($null -eq $after){''}else{[string]$after.State}
    $watch.Stop()
    $verb=if($action -eq 'Restart'){'redémarré'}else{'démarré'}
    $message=if($state -eq 'Running'){'« '+$display+' » '+$verb+' sur '+$computer+'.'}else{'Commande acceptée par '+$computer+' ; « '+$display+' » est relu '+(& $label $state)+' : à vérifier.'}
    $observed=[pscustomobject]@{ReadStatus=$(if($null -eq $after){'NotRead'}else{'OK'});Server=$computer;ReadUtc=[DateTime]::UtcNow.ToString('o');Flags=[pscustomobject]@{State=$state}}
    [pscustomobject]@{Computer=$computer;Service=$service;DisplayName=$display;Action=$action;StateBefore=$before;StateAfter=$state;Message=$message;DurationMs=[long]$watch.ElapsedMilliseconds;Transport='CIM';Verified=($state -eq 'Running');Delivered=$true;Postcondition=[pscustomobject]@{Expected=[pscustomobject]@{Server=$computer;Flags=[pscustomobject]@{State='Running'}};Observed=$observed;SentUtc=$sent}}
}finally{Remove-WDomeniaCimSession $session}
'@
}
