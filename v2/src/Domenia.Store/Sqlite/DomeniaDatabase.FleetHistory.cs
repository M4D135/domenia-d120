using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    /// <summary>Reads Domenia 1 daily figures without guessing missing coverage or policy fingerprints.</summary>
    public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Task.Run(() =>
    {
        if (!InDomain(scope.Dn)) { throw new InvalidDataException("Historique demandé hors du domaine de cette base."); }
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return ImmutableArray<FleetSnapshot>.Empty; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "fleet_snapshots")) { return ImmutableArray<FleetSnapshot>.Empty; }
        var key = ScopeRules.IsDomainRoot(scope, DomainDn) ? "*" : scope.Dn.ToLowerInvariant() + (scope.Subtree ? "|Subtree" : "|OneLevel");
        var today = LocalDays.DateOf(clock.GetUtcNow(), clock.LocalTimeZone);
        var rows = db.Query("SELECT snapshot_day,taken_at,scope_dn,figures FROM fleet_snapshots WHERE scope_key=?1 AND snapshot_day>=?2 AND snapshot_day<=?3 ORDER BY snapshot_day;", key,
            today.AddDays(-89).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        var result = ImmutableArray.CreateBuilder<FleetSnapshot>();
        foreach (var row in rows)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!DateOnly.TryParseExact(row["snapshot_day"] as string, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day)
                || !DateTimeOffset.TryParse(row["taken_at"] as string, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)
                || at > clock.GetUtcNow().AddMinutes(2) || row["figures"] is not string json) { continue; }
            if (row["scope_dn"] is string dn && dn.Length > 0 && !ScopeRules.IsDomainRoot(scope, dn)) { continue; }
            try
            {
                using var document = JsonDocument.Parse(json);
                var cells = document.RootElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value, StringComparer.OrdinalIgnoreCase);
                int? Number(string name) => cells.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var n) && n >= 0 ? n : null;
                var machines = Number("Machines");
                var required = new[] { "Healthy", "Problems", "Stale", "StaleDays", "EndOfService", "Disabled", "Windows10" }.Select(Number).ToArray();
                if (machines is null || required.Any(n => n is null)) { continue; }
                // Version 1 cannot establish comparable coverage: score and fingerprints stay unknown.
                var figures = new FleetFigures(machines.Value, required[0]!.Value, required[1]!.Value, required[2]!.Value, required[3]!.Value, required[4]!.Value,
                    required[5]!.Value, required[6]!.Value, Number("LowDisk"), 0, machines.Value, null, 0, 0, "", "", "", "", 1);
                result.Add(new("legacy:" + key + ":" + day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), "daily", "Instantané Domenia 1", day, at, figures));
            }
            catch (JsonException) { /* An unreadable historical row is not a zero-filled snapshot. */ }
            catch (ArgumentException) { /* Duplicate field names make the historical figures ambiguous. */ }
            catch (InvalidOperationException) { /* A non-object payload is not a snapshot. */ }
        }
        db.Commit();
        return result.ToImmutable();
    }, cancellationToken);
}
