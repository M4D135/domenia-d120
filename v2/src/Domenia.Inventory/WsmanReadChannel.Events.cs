using System.Globalization;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed partial class WsmanReadChannel
{
    internal ShellReading ReadEvents(EventQuery query, TimeSpan timeout) => ReadScript(EventScript(query), timeout);

    internal static string EventScript(EventQuery query)
    {
        var preset = CheckedEventPreset(query);
        // All string literals originate in the compiled preset catalog. The only variable data is bounded numbers and UTC dates.
        var logs = string.Join(',', preset.Logs.Select(l => "'" + l + "'"));
        var providers = string.Join(',', preset.Providers.Select(p => "'" + p + "'"));
        var ids = string.Join(',', preset.EventIds.Select(id => id.ToString(CultureInfo.InvariantCulture)));
        var start = query.Start.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);
        var end = query.End.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);
        var cap = (query.MaxEvents + 1).ToString(CultureInfo.InvariantCulture);
        return """
            $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
            [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
            function Flat([string]$s){if($null -eq $s){return ''};$s=($s -replace '[\x00-\x1f\x7f]',' ');if($s.Length -gt 500){return $s.Substring(0,500)};return $s}
            $rows=[Collections.Generic.List[object]]::new();$access=[Collections.Generic.List[object]]::new()
            """ + "\n$logs=@(" + logs + ");$providers=@(" + providers + ");$ids=@(" + ids + ")\n"
            + "$start=[datetime]::Parse('" + start + "',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)\n"
            + "$end=[datetime]::Parse('" + end + "',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)\n"
            + "$cap=" + cap + "\n" + """
            foreach($log in $logs){
                $code=0;$count=0;$partial=$false
                try {
                    Get-WinEvent -FilterHashtable @{LogName=$log;ProviderName=$providers;Id=$ids;StartTime=$start;EndTime=$end} -MaxEvents $cap -ErrorAction Stop | ForEach-Object {
                        $event=$_;$count++;$message=''
                        try{$message=Flat $event.Message}catch{$partial=$true}
                        if($null -eq $event.TimeCreated){$partial=$true}
                        else{$rows.Add([pscustomobject]@{Id=[int]$event.Id;Provider=[string]$event.ProviderName;Log=[string]$event.LogName;Level=[int]$event.Level;At=$event.TimeCreated.ToUniversalTime().ToString('o');Machine=[string]$event.MachineName;Message=$message})}
                    }
                } catch {if($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*'){$errorObject=$_.Exception;while($errorObject.InnerException){$errorObject=$errorObject.InnerException};$code=$errorObject.HResult;if($_.CategoryInfo.Category -eq 'PermissionDenied' -or $errorObject -is [UnauthorizedAccessException]){$code=-2147024891};if($code -eq 0){$code=-2147467259}}}
                $access.Add([pscustomobject]@{Log=$log;Code=$code;Partial=($partial -or $count -ge $cap)})
            }
            [Console]::Out.Write(([pscustomobject]@{Format='Domenia.EventsRead/1';Computer=[Environment]::MachineName;Access=$access.ToArray();Rows=$rows.ToArray()} | ConvertTo-Json -Depth 5 -Compress))
            exit 0
            """;
    }

    internal static EventPreset CheckedEventPreset(EventQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);
        var preset = PosteEvents.Preset(query.PresetId) ?? throw new ArgumentException("Préréglage d’événements inconnu.");
        if (query.WindowHours is < 1 or > 720 || query.MaxEvents is < 1 or > 200 || query.End - query.Start != TimeSpan.FromHours(query.WindowHours))
        { throw new ArgumentException("Fenêtre d’événements hors limites."); }
        return preset;
    }
}
