namespace Domenia.Inventory;

internal enum InventoryShellRead { Certificates, Tasks, UserIdentity }

internal sealed partial class WsmanReadChannel
{
    internal ShellReading ReadInventory(InventoryShellRead kind, TimeSpan timeout) => ReadScript(kind switch
    {
        InventoryShellRead.Certificates => CertificatesScript,
        InventoryShellRead.Tasks => TasksScript,
        InventoryShellRead.UserIdentity => UserIdentityScript,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    }, timeout);

    // These scripts contain no interpolation and admit no argument from the workstation, directory or bridge.
    // Only public certificate metadata and task status leave the host: no key, task action or principal credential.
    private const string CertificatesScript = """
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $rows=[Collections.Generic.List[object]]::new();$code=0;$truncated=$false
        try {
            Get-ChildItem -LiteralPath 'Cert:\LocalMachine\My' -ErrorAction Stop | Select-Object -First 513 | ForEach-Object {
                if($rows.Count -ge 512){$truncated=$true}
                else {$rows.Add([pscustomobject]@{Subject=[string]$_.Subject;Issuer=[string]$_.Issuer;NotAfter=$_.NotAfter.ToUniversalTime().ToString('o');Usages=@($_.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.37'} | ForEach-Object {$_.EnhancedKeyUsages} | ForEach-Object {[string]$_.Value});Thumbprint=[string]$_.Thumbprint})}
            }
        } catch {$code=$_.Exception.HResult}
        [Console]::Out.Write(([pscustomobject]@{Format='Domenia.CertificatesRead/1';Computer=[Environment]::MachineName;Code=$code;Truncated=$truncated;Rows=$rows.ToArray()} | ConvertTo-Json -Depth 5 -Compress))
        exit 0
        """;

    private const string TasksScript = """
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $rows=[Collections.Generic.List[object]]::new();$code=0;$truncated=$false
        try {
            Get-ScheduledTask -ErrorAction Stop | Select-Object -First 1001 | ForEach-Object {
                if($rows.Count -ge 1000){$truncated=$true}
                else {
                    $task=$_;$last=$null;$next=$null;$result=$null
                    try {
                        $info=Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
                        $result=([uint32]$info.LastTaskResult).ToString([Globalization.CultureInfo]::InvariantCulture)
                        if($info.LastRunTime -and $info.LastRunTime.Year -gt 1900 -and $info.LastTaskResult -ne 267011){$last=$info.LastRunTime.ToUniversalTime().ToString('o')}
                        if($info.NextRunTime -and $info.NextRunTime.Year -gt 1900){$next=$info.NextRunTime.ToUniversalTime().ToString('o')}
                    } catch {$truncated=$true}
                    $rows.Add([pscustomobject]@{Name=[string]$task.TaskName;Path=[string]$task.TaskPath;Author=[string]$task.Author;State=([int]$task.State).ToString([Globalization.CultureInfo]::InvariantCulture);LastResult=$result;LastRun=$last;NextRun=$next})
                }
            }
        } catch {$code=$_.Exception.HResult}
        [Console]::Out.Write(([pscustomobject]@{Format='Domenia.TasksRead/1';Computer=[Environment]::MachineName;Code=$code;Truncated=$truncated;Rows=$rows.ToArray()} | ConvertTo-Json -Depth 4 -Compress))
        exit 0
        """;

    internal const string UserIdentityBody = """
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $rows=[Collections.Generic.List[object]]::new();$code=0;$truncated=$false
        try {
            try {
                $cs=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property Name,UserName -OperationTimeoutSec 1 -ErrorAction Stop)
                if($cs.Count -ne 1 -or $cs[0].Name -ine [Environment]::MachineName){throw 'Identite systeme non confirmee'}
                if($cs[0].UserName){$rows.Add([pscustomobject]@{Kind='Console';Account=[string]$cs[0].UserName;Sid=$null;ProcessId=$null;CreatedUtc=$null})}
            } catch {$truncated=$true;$code=$_.Exception.HResult}
            $examined=0
            Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -Property Name,ProcessId,CreationDate -OperationTimeoutSec 1 -ErrorAction Stop | Select-Object -First 17 | ForEach-Object {
                $examined++
                if($examined -gt 16){$truncated=$true}
                else {
                    try {
                        $p=$_;if(-not $p.CreationDate){throw 'Creation du processus inconnue'}
                        $owner=Invoke-CimMethod -InputObject $p -MethodName GetOwner -OperationTimeoutSec 1 -ErrorAction Stop
                        $sid=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -OperationTimeoutSec 1 -ErrorAction Stop
                        $again=@(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId='+([uint32]$p.ProcessId).ToString([Globalization.CultureInfo]::InvariantCulture)) -Property Name,ProcessId,CreationDate -OperationTimeoutSec 1 -ErrorAction Stop)
                        if($owner.ReturnValue -ne 0 -or $sid.ReturnValue -ne 0 -or -not $owner.User -or -not $owner.Domain -or -not $sid.Sid -or $again.Count -ne 1 -or $again[0].Name -ine 'explorer.exe' -or $again[0].CreationDate -ne $p.CreationDate){throw 'Identite du processus non confirmee'}
                        $rows.Add([pscustomobject]@{Kind='Explorer';Account=([string]$owner.Domain+'\'+[string]$owner.User);Sid=[string]$sid.Sid;ProcessId=[uint32]$p.ProcessId;CreatedUtc=$p.CreationDate.ToUniversalTime().ToString('o')})
                    } catch {$truncated=$true}
                }
            }
        } catch {$truncated=$true;$code=$_.Exception.HResult}
        $domeniaResult=[pscustomobject]@{Format='Domenia.UserIdentityRead/1';Computer=[Environment]::MachineName;Code=$code;Truncated=$truncated;Rows=$rows.ToArray()}
        """;

    private const string UserIdentityScript = UserIdentityBody + "\n[Console]::Out.Write(($domeniaResult | ConvertTo-Json -Depth 4 -Compress));exit 0";
}
