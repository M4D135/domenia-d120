namespace Domenia.Inventory;

internal enum InventoryShellRead { Certificates, Tasks }

internal sealed partial class WsmanReadChannel
{
    internal ShellReading ReadInventory(InventoryShellRead kind, TimeSpan timeout) => ReadScript(kind switch
    {
        InventoryShellRead.Certificates => CertificatesScript,
        InventoryShellRead.Tasks => TasksScript,
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
}
