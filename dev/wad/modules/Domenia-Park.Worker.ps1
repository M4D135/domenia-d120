# MO-08: pinned worker bodies of the surveys of a list (Domenia-Park.UI.ps1 starts them, Domenia-Engine.Model.ps1
# classifies them). A body is a here-string pinned by SHA-256: any change goes through the worker contracts.
function Get-DomeniaParkPingWorkerCode {
    # ParkPing: the echoes of a list leave in parallel, BatchSize at a time (32 by default), one Ping instance per
    # echo, TimeoutMs each (1 s by default), after a bounded parallel name resolution (IPv4 first, as the check of a
    # single workstation). A name that cannot be resolved is an error, never a missing reply. Each batch is reported
    # through the Progress queue of the payload, then the whole result is returned. No credential, no CIM, no write.
    return @'
$items=@($Payload.Targets)
$timeout=1000;try{$timeout=[int]$Payload.TimeoutMs}catch{$timeout=1000}
$timeout=[Math]::Max(250,[Math]::Min(3000,$timeout))
$batch=32;try{$batch=[int]$Payload.BatchSize}catch{$batch=32}
$batch=[Math]::Max(1,[Math]::Min(64,$batch))
$progress=$null
if($null -ne $Payload.PSObject.Properties['Progress']){$progress=$Payload.Progress}
function Get-ParkPingInnerMessage($ErrorValue){
    $inner=$ErrorValue
    if($inner -is [Management.Automation.ErrorRecord]){$inner=$inner.Exception}
    while(($null -ne $inner) -and ($null -ne $inner.InnerException)){$inner=$inner.InnerException}
    if($null -eq $inner){return 'erreur inconnue'}
    return [string]$inner.Message
}
$all=New-Object Collections.ArrayList
for($index=0;$index -lt $items.Count;$index+=$batch){
    $last=[Math]::Min($index+$batch,$items.Count)-1
    $entries=New-Object Collections.ArrayList
    for($i=$index;$i -le $last;$i++){
        $item=$items[$i]
        $entry=[pscustomobject]@{Key=[string]$item.Key;Guid=[string]$item.Guid;Computer=[string]$item.Computer;Address=$null;Dns=$null;Ping=$null;Task=$null;Presence='';PresenceDetail=''}
        $target=$entry.Computer
        if(($target.Length -lt 1) -or ($target.Length -gt 253) -or ($target -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$')){$entry.Presence='Erreur de ping';$entry.PresenceDetail='Nom de poste invalide : aucun écho envoyé.'}
        else{
            $literal=$null
            if([Net.IPAddress]::TryParse($target,[ref]$literal)){$entry.Address=$literal}
            else{
                try{$entry.Dns=[Net.Dns]::GetHostAddressesAsync($target)}
                catch{$entry.Presence='Erreur de ping';$entry.PresenceDetail='Résolution DNS impossible : '+(Get-ParkPingInnerMessage $_)}
            }
        }
        [void]$entries.Add($entry)
    }
    # Parallel name resolution, bounded. Each task is then read on its own: one failure never hides the others.
    $dnsTasks=@($entries|Where-Object{$null -ne $_.Dns}|ForEach-Object{$_.Dns})
    if($dnsTasks.Count){try{[void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$dnsTasks,2500)}catch{}}
    foreach($entry in $entries){
        if(($null -eq $entry.Dns) -or $entry.Presence){continue}
        try{
            if(-not $entry.Dns.IsCompleted){$entry.Presence='Erreur de ping';$entry.PresenceDetail='Résolution DNS trop lente : aucun écho envoyé.';continue}
            if($entry.Dns.IsFaulted -or $entry.Dns.IsCanceled){$entry.Presence='Erreur de ping';$entry.PresenceDetail='Résolution DNS impossible : '+(Get-ParkPingInnerMessage $entry.Dns.Exception);continue}
            $addresses=@($entry.Dns.Result)
            $ipv4=@($addresses|Where-Object{$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|Select-Object -First 1)
            if($ipv4.Count){$entry.Address=$ipv4[0]}elseif($addresses.Count){$entry.Address=$addresses[0]}
            else{$entry.Presence='Erreur de ping';$entry.PresenceDetail='Résolution DNS sans adresse : aucun écho envoyé.'}
        }catch{$entry.Presence='Erreur de ping';$entry.PresenceDetail='Résolution DNS impossible : '+(Get-ParkPingInnerMessage $_)}
    }
    # One Ping instance per echo, all sent before the bounded wait.
    foreach($entry in $entries){
        if(($null -eq $entry.Address) -or $entry.Presence){continue}
        try{$entry.Ping=New-Object Net.NetworkInformation.Ping;$entry.Task=$entry.Ping.SendPingAsync($entry.Address,$timeout)}
        catch{
            $entry.Presence='Erreur de ping';$entry.PresenceDetail='Le contrôle ICMP nʼa pas abouti : '+(Get-ParkPingInnerMessage $_)
            if($null -ne $entry.Ping){try{$entry.Ping.Dispose()}catch{}};$entry.Ping=$null
        }
    }
    $pingTasks=@($entries|Where-Object{$null -ne $_.Task}|ForEach-Object{$_.Task})
    if($pingTasks.Count){try{[void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$pingTasks,($timeout+1000))}catch{}}
    $checked=[datetime]::UtcNow.ToString('o')
    $results=New-Object Collections.ArrayList
    foreach($entry in $entries){
        try{
            if($null -ne $entry.Task){
                $address=[string]$entry.Address
                if($entry.Task.IsCompleted -and (-not $entry.Task.IsFaulted) -and (-not $entry.Task.IsCanceled) -and ($null -ne $entry.Task.Result)){
                    if([string]$entry.Task.Result.Status -eq 'Success'){$entry.Presence='En ligne';$entry.PresenceDetail='Réponse ICMP · '+[string]$entry.Task.Result.RoundtripTime+' ms · '+$address}
                    else{$entry.Presence='Sans réponse au ping';$entry.PresenceDetail='ICMP : '+[string]$entry.Task.Result.Status+' · '+$address}
                }elseif($entry.Task.IsFaulted -or $entry.Task.IsCanceled){$entry.Presence='Erreur de ping';$entry.PresenceDetail='Le contrôle ICMP nʼa pas abouti : '+(Get-ParkPingInnerMessage $entry.Task.Exception)}
                else{
                    try{$entry.Ping.SendAsyncCancel()}catch{}
                    $entry.Presence='Sans réponse au ping';$entry.PresenceDetail='ICMP : délai dépassé · '+$address
                }
            }
        }catch{$entry.Presence='Erreur de ping';$entry.PresenceDetail='Le contrôle ICMP nʼa pas abouti : '+(Get-ParkPingInnerMessage $_)}
        finally{if($null -ne $entry.Ping){try{$entry.Ping.Dispose()}catch{}}}
        [void]$results.Add([pscustomobject]@{Key=$entry.Key;Guid=$entry.Guid;Computer=$entry.Computer;Presence=$entry.Presence;PresenceDetail=$entry.PresenceDetail;PresenceCheckedUtc=$checked})
    }
    if($null -ne $progress){$progress.Enqueue([pscustomobject]@{Results=$results.ToArray()})}
    [void]$all.AddRange($results)
}
[pscustomobject]@{Results=$all.ToArray();Count=$all.Count;Completed=$true}
'@
}
