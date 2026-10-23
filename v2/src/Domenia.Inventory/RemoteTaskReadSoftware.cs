using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal static class RemoteTaskReadSoftware
{
    internal const int Cap = 512;
    internal static string Body(SoftwareRequest request) => "$readUsers=" + Flag(request.PerUser) + ";$readStore=" + Flag(request.Store) + ";$readUpdates=" + Flag(request.Updates) + "\n" + """
        $watch=[Diagnostics.Stopwatch]::StartNew();$rows=[Collections.Generic.List[object]]::new();$scopes=[Collections.Generic.List[object]]::new()
        function Domenia-Text($value) {
            if($null -eq $value){return $null};if($value -isnot [string] -or $value.Length -gt 4096 -or $value -match '[\x00-\x1f\x7f]'){throw 'Texte illisible'};return $value
        }
        function Domenia-Roots($hive,$prefix,$profile,$scope) {
            foreach($view in @(@('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','64 bits'),@('SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','32 bits'))) {
                $root=$null
                try {
                    $root=$hive.OpenSubKey(($prefix+$view[0]),$false)
                    if(-not $root){continue}
                    foreach($child in $root.GetSubKeyNames()) {
                        if($script:scanned -ge 512 -or $watch.Elapsed.TotalSeconds -gt 22){$script:partial=$true;break};$script:scanned++
                        $key=$null
                        try {
                            $key=$root.OpenSubKey($child,$false);if(-not $key){throw 'Cle disparue'}
                            $name=Domenia-Text ($key.GetValue('DisplayName',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames));if(-not $name){continue}
                            $component=$key.GetValue('SystemComponent',$null);if($null -ne $component -and $component -isnot [int]){throw 'Filtre illisible'}
                            $release=Domenia-Text ($key.GetValue('ReleaseType',$null));$parent=Domenia-Text ($key.GetValue('ParentKeyName',$null))
                            if(-not $readUpdates -and ($component -eq 1 -or $parent -or $release -match '(?i)update|hotfix|security')){continue}
                            $version=Domenia-Text ($key.GetValue('DisplayVersion',$null));$publisher=Domenia-Text ($key.GetValue('Publisher',$null))
                            $date=Domenia-Text ($key.GetValue('InstallDate',$null));$location=Domenia-Text ($key.GetValue('InstallLocation',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
                            $size=$key.GetValue('EstimatedSize',$null);if($null -ne $size -and $size -isnot [int]){throw 'Taille illisible'}
                            if($null -ne $size){$size=([uint32]([int64]$size -band 0xffffffff)).ToString([Globalization.CultureInfo]::InvariantCulture)}
                            $rows.Add([pscustomobject]@{Name=$name;Version=$version;Publisher=$publisher;Date=$date;SizeKb=$size;Architecture=$view[1];Scope=$scope;Profile=$profile;Location=$location;Source='Uninstall'})
                        } catch {$script:partial=$true} finally {if($key){$key.Dispose()}}
                    }
                } catch {$script:partial=$true;$script:scopeCode=$_.Exception.HResult} finally {if($root){$root.Dispose()}}
            }
        }
        foreach($scope in @('Machine','Utilisateur','Store')) {
            $script:partial=$false;$script:scopeCode=0;$script:scanned=0;$before=$rows.Count;$skipped=($scope -eq 'Utilisateur' -and -not $readUsers) -or ($scope -eq 'Store' -and -not $readStore)
            if(-not $skipped) {
                try {
                    if($scope -eq 'Store') {
                        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -First 513 | ForEach-Object {
                            if($rows.Count-$before -ge 512 -or $watch.Elapsed.TotalSeconds -gt 22){$script:partial=$true}
                            else {$rows.Add([pscustomobject]@{Name=(Domenia-Text ([string]$_.Name));Version=(Domenia-Text ([string]$_.Version));Publisher=(Domenia-Text ([string]$_.Publisher));Date=$null;SizeKb=$null;Architecture=[string]$_.Architecture;Scope='Store';Profile=$null;Location=(Domenia-Text ([string]$_.InstallLocation));Source='Appx'})}
                        }
                    }
                    else {
                        $hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey($(if($scope -eq 'Machine'){[Microsoft.Win32.RegistryHive]::LocalMachine}else{[Microsoft.Win32.RegistryHive]::Users}),[Microsoft.Win32.RegistryView]::Registry64)
                        try {
                            if($scope -eq 'Machine'){Domenia-Roots $hive '' $null $scope}
                            else {$profiles=@($hive.GetSubKeyNames() | Where-Object {$_ -match '^S-1-(5-21|12-1)-[0-9-]+$'} | Select-Object -First 65);if($profiles.Count -gt 64){$script:partial=$true};foreach($sid in ($profiles | Select-Object -First 64)){Domenia-Roots $hive ($sid+'\') $sid $scope}}
                        } finally {$hive.Dispose()}
                    }
                } catch {$script:scopeCode=$_.Exception.HResult;$script:partial=$true}
            }
            $scopes.Add([pscustomobject]@{Scope=$scope;Code=$script:scopeCode;Truncated=$script:partial;Skipped=$skipped;Items=($rows.Count-$before)})
        }
        $domeniaResult=[pscustomobject]@{Format='Domenia.TaskSoftware/1';Computer=[Environment]::MachineName;Scopes=$scopes.ToArray();Rows=$rows.ToArray()}
        """;
    private static string Flag(bool value) => value ? "$true" : "$false";

    internal static WorkstationSoftwareReading Parse(JsonElement root, RemoteTaskReadPlan plan, DateTimeOffset now)
    {
        var request = plan.Software ?? throw new JsonException();
        RemoteTaskReadJson.Object(root, "Format", "Computer", "Scopes", "Rows");
        if (RemoteTaskReadJson.Text(root, "Format") != "Domenia.TaskSoftware/1"
            || !string.Equals(RemoteTaskReadJson.Text(root, "Computer"), plan.Host.Split('.')[0], StringComparison.OrdinalIgnoreCase)) { throw new JsonException(); }
        var rows = root.GetProperty("Rows"); var scopes = root.GetProperty("Scopes");
        if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > Cap * 3 || scopes.ValueKind != JsonValueKind.Array || scopes.GetArrayLength() != 3) { throw new JsonException(); }
        var entries = ImmutableArray.CreateBuilder<SoftwareEntry>(); var invalidDates = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows.EnumerateArray())
        {
            RemoteTaskReadJson.Object(row, "Name", "Version", "Publisher", "Date", "SizeKb", "Architecture", "Scope", "Profile", "Location", "Source");
            string? T(string key) => RemoteTaskReadJson.Text(row, key);
            var name = T("Name"); var scope = T("Scope"); var profile = T("Profile"); var origin = T("Source"); var architecture = T("Architecture");
            if (string.IsNullOrWhiteSpace(name) || scope is not ("Machine" or "Utilisateur" or "Store")
                || scope == "Utilisateur" && (!request.PerUser || profile is null || !InventoryRegistry.ProfileSid(profile))
                || scope != "Utilisateur" && profile is not null || scope == "Store" && !request.Store
                || (scope == "Store" ? origin != "Appx" : origin != "Uninstall")
                || architecture is null || architecture.Length > 64 || scope != "Store" && architecture is not ("64 bits" or "32 bits")) { throw new JsonException(); }
            DateOnly? date = null;
            if (T("Date") is { Length: > 0 } rawDate)
            {
                if (DateOnly.TryParseExact(rawDate, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)) { date = parsed; }
                else { invalidDates.Add(scope); }
            }
            long? size = null;
            if (T("SizeKb") is { } sizeKb)
            { if (!uint.TryParse(sizeKb, NumberStyles.None, CultureInfo.InvariantCulture, out var kb)) { throw new JsonException(); } size = kb * 1024L; }
            entries.Add(new(name, T("Version"), T("Publisher"), date, size, architecture, scope, profile, T("Location"), null,
                scope == "Store" ? "Appx" : scope == "Utilisateur" ? "UserHives" : architecture == "64 bits" ? "Uninstall64" : "Uninstall32"));
        }
        var access = ImmutableArray.CreateBuilder<SoftwareScopeAccess>();
        foreach (var item in scopes.EnumerateArray())
        {
            RemoteTaskReadJson.Object(item, "Scope", "Code", "Truncated", "Skipped", "Items"); var scope = RemoteTaskReadJson.Text(item, "Scope");
            if (scope is not ("Machine" or "Utilisateur" or "Store") || access.Any(a => a.Scope == scope)) { throw new JsonException(); }
            var count = entries.Count(e => e.Scope == scope); var code = RemoteTaskReadJson.Int(item, "Code"); var partial = RemoteTaskReadJson.Bool(item, "Truncated"); var skipped = RemoteTaskReadJson.Bool(item, "Skipped");
            if (count > Cap || RemoteTaskReadJson.Int(item, "Items") != count || skipped != (scope == "Utilisateur" && !request.PerUser || scope == "Store" && !request.Store)
                || skipped && (count != 0 || code != 0 || partial)) { throw new JsonException(); }
            var status = skipped ? SourceStatus.Skipped : code != 0 && count == 0 ? code is 5 or unchecked((int)0x80070005) ? SourceStatus.Refused : SourceStatus.Error
                : partial || code != 0 || invalidDates.Contains(scope) ? SourceStatus.Partial : count == 0 ? SourceStatus.Empty : SourceStatus.Ok;
            access.Add(new(scope, status, PosteLabels.SourceStatusLabel(status), count,
                "Tâche SYSTEM · " + (scope == "Utilisateur" ? "Ruches déjà chargées, profils par SID, sans montage." : scope == "Store" ? "Packages Appx déclarés pour tous les utilisateurs." : "Registre Uninstall 64 et 32 bits, une entrée par clé.")
                + (skipped ? " Portée non demandée." : status is SourceStatus.Ok or SourceStatus.Empty ? " Lecture reçue." : " Lecture incomplète ou refusée ; aucune absence supposée.") + " Désinstallation non lue ; aucune commande exposée."));
        }
        return new(plan.Host, plan.Host.Split('.')[0], now, entries.ToImmutable(), access.ToImmutable());
    }
}
