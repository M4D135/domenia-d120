using System.Globalization;

namespace Domenia.Inventory;

internal sealed partial class WsmanReadChannel
{
    internal ShellReading ReadMetadata(WmiMetadataKind kind, string ns, string? className, TimeSpan timeout) => ReadScript(MetadataScript(kind, ns, className), timeout);

    internal static string MetadataScript(WmiMetadataKind kind, string ns, string? className)
    {
        CimSession.CheckMetadata(kind, ns, className);
        var cap = CimSession.MetadataCap(kind).ToString(CultureInfo.InvariantCulture);
        // Names have been validated as identifiers; no user filter, code, method or property value enters this script.
        return """
            $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
            [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
            $rows=[Collections.Generic.List[object]]::new();$code=0;$partial=$false
            """ + "\n$kind='" + kind + "';$ns='" + ns + "';$class=" + (className is null ? "$null" : "'" + className + "'") + ";$cap=" + cap + "\n"
            + """
            try {
                if($kind -eq 'Namespaces'){
                    Get-CimInstance -Namespace $ns -ClassName __Namespace -Property Name -OperationTimeoutSec 12 | Select-Object -First ($cap+1) | ForEach-Object {
                        if($rows.Count -ge $cap){$partial=$true}else{$rows.Add([pscustomobject]@{Name=[string]$_.Name})}
                    }
                } elseif($kind -eq 'Classes'){
                    Get-CimClass -Namespace $ns -OperationTimeoutSec 12 | Select-Object -First ($cap+1) | ForEach-Object {
                        if($rows.Count -ge $cap){$partial=$true}else{$rows.Add([pscustomobject]@{Name=[string]$_.CimClassName})}
                    }
                } else {
                    $definition=Get-CimClass -Namespace $ns -ClassName $class -OperationTimeoutSec 12
                    $definition.CimClassProperties | Select-Object -First ($cap+1) | ForEach-Object {
                        if($rows.Count -ge $cap){$partial=$true}
                        else{$rows.Add([pscustomobject]@{Name=[string]$_.Name;Type=[string]$_.CimType;Key=([bool](($_.Flags.ToString() -split ',\s*') -contains 'Key'));Qualifiers=([string](($_.Qualifiers | ForEach-Object {$_.Name} | Sort-Object) -join ', '))})}
                    }
                }
            } catch {$err=$_.Exception;while($err.InnerException){$err=$err.InnerException};$code=$err.HResult;if($_.CategoryInfo.Category -eq 'PermissionDenied' -or $err -is [UnauthorizedAccessException]){$code=-2147024891};if($code -eq 0){$code=-2147467259}}
            [Console]::Out.Write(([pscustomobject]@{Format='Domenia.WmiMetadata/1';Kind=$kind;Computer=[Environment]::MachineName;Namespace=$ns;Class=$class;Code=$code;Partial=$partial;Rows=$rows.ToArray()} | ConvertTo-Json -Depth 5 -Compress))
            exit 0
            """;
    }
}
