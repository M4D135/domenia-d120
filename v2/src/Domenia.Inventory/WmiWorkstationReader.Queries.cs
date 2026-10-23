using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Inventory;

/// <summary>Explicit projection of the query workshop; returned values retain their native scalar types for probes.</summary>
public sealed record WorkstationQueryRead(string? ReportedName, SourceStatus Status, string Detail, DateTimeOffset At,
    ImmutableArray<WmiProperty> Schema, ImmutableArray<WmiInstance> Rows, string CanonicalQuery)
{
    public bool AuthenticationRejected { get; init; }
    public bool Complete => Status is SourceStatus.Ok or SourceStatus.Empty;
}

public sealed partial class WmiWorkstationReader
{
    public static WqlSelect CheckWorkshopSelect(string ns, WqlSelect select, int limit)
    {
        ArgumentNullException.ThrowIfNull(select);
        if (limit is < 1 or > 2000) { throw new QueryDefinitionException("Lecture limitée à 2 000 instances."); }
        // The DTO is not evidence that the parser ran. Reparse its canonical text and ignore caller-supplied AST fields.
        var parsed = WqlRules.Parse(select.CanonicalQuery);
        WqlRules.CheckTarget(ns, parsed.ClassName);
        if (!CimQuery.IsReadOnlySelect(parsed.CanonicalQuery, ns) || parsed.ReferencedProperties.Any(ExplorerSensitive))
        { throw new QueryDefinitionException("Projection trop longue ou attribut sensible : aucun contact envoyé."); }
        return parsed;
    }

    public async Task<WorkstationQueryRead> ReadWorkshopSelectAsync(string host, string ns, WqlSelect select, int limit,
        CancellationToken token, RemoteProbeCredential? credential = null)
    {
        var parsed = CheckWorkshopSelect(ns, select, limit);
        if (!CimQuery.IsHostName(host)) { throw new QueryDefinitionException("Nom DNS du poste invalide."); }
        var budget = TimeSpan.FromSeconds(40);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        var latest = new WorkstationQueryRead(null, SourceStatus.Interrupted, "Lecture non commencée.", clock.GetUtcNow(), [], [], parsed.CanonicalQuery);
        Task<WorkstationQueryRead> work;
        try
        {
            work = WmiReadWorkers.Start(credential, owned =>
            {
                using var session = Session(host, budget, stop.Token, owned);
                var identity = session.Read("Identité WMI", Cimv2, "SELECT Name FROM Win32_ComputerSystem", 2, TimeSpan.FromSeconds(3));
                var name = identity.Status == SourceStatus.Ok && identity.Instances.Count == 1 ? identity.Instances[0].Text("Name") : null;
                var current = latest with { ReportedName = name, AuthenticationRejected = identity.AuthenticationRejected };
                if (!string.Equals(name, host.Split('.')[0], StringComparison.OrdinalIgnoreCase))
                { return current with { Status = identity.Answered ? SourceStatus.Unavailable : identity.Status, Detail = "Identité Windows non confirmée ; SELECT non envoyé." }; }
                Volatile.Write(ref latest, current);
                var metadata = session.ReadMetadata(WmiMetadataKind.Properties, ns, parsed.ClassName);
                if (!metadata.Answered)
                { return current with { Status = metadata.Status, Detail = metadata.Detail, AuthenticationRejected = metadata.AuthenticationRejected }; }
                var schema = metadata.Instances.Select(p => new WmiProperty(p.Text("Name")!, p.Text("Type")!, p.Bool("Key") == true, p.Text("Qualifiers") ?? "")).ToImmutableArray();
                WqlSelect checkedPlan;
                try { checkedPlan = WqlRules.Parse(parsed.CanonicalQuery, schema.Select(p => p.Name).ToArray()); }
                catch (QueryDefinitionException)
                { return current with { Status = SourceStatus.Error, Detail = "Propriété absente du schéma reçu ; SELECT non envoyé." }; }
                var columns = checkedPlan.Properties.ToList();
                foreach (var key in schema.Where(p => p.Key && !ExplorerSensitive(p.Name)))
                { if (!columns.Contains(key.Name, StringComparer.OrdinalIgnoreCase)) { columns.Add(key.Name); } }
                if (columns.Count > 64) { return current with { Status = SourceStatus.Error, Detail = "Projection et clés dépassant 64 propriétés ; SELECT non envoyé." }; }
                var whereAt = checkedPlan.CanonicalQuery.IndexOf(" WHERE ", StringComparison.Ordinal);
                var query = "SELECT " + string.Join(", ", columns) + " FROM " + checkedPlan.ClassName + (whereAt < 0 ? "" : checkedPlan.CanonicalQuery[whereAt..]);
                if (!CimQuery.IsReadOnlySelect(query, ns))
                { return current with { Status = SourceStatus.Error, Detail = "Projection et clés hors limites ; SELECT non envoyé." }; }
                var selected = columns.Select(c => schema.Single(p => p.Name.Equals(c, StringComparison.OrdinalIgnoreCase))).ToImmutableArray();
                if (selected.Any(p => p.Type.Contains("Object", StringComparison.OrdinalIgnoreCase) || p.Type.Contains("Instance", StringComparison.OrdinalIgnoreCase)))
                { return current with { Status = SourceStatus.Error, Detail = "Propriété objet embarqué refusée ; SELECT non envoyé." }; }
                var reading = session.Read("SELECT WMI", ns, query, limit, TimeSpan.FromSeconds(20));
                current = current with { Schema = selected, Rows = [.. reading.Instances], Status = reading.Status, Detail = reading.Detail,
                    AuthenticationRejected = reading.AuthenticationRejected, At = clock.GetUtcNow() };
                Volatile.Write(ref latest, current);
                if (!reading.Answered || reading.AuthenticationRejected) { return current; }
                var after = session.Read("Identité WMI", Cimv2, "SELECT Name FROM Win32_ComputerSystem", 2, TimeSpan.FromSeconds(3));
                if (after.Status != SourceStatus.Ok || after.Instances.Count != 1 || !string.Equals(after.Instances[0].Text("Name"), name, StringComparison.OrdinalIgnoreCase))
                { return current with { Rows = [], Status = after.AuthenticationRejected ? SourceStatus.Refused : SourceStatus.Unavailable,
                    Detail = "Identité Windows non confirmée après lecture ; instances écartées.", AuthenticationRejected = after.AuthenticationRejected }; }
                return current with { Status = metadata.Status == SourceStatus.Partial && current.Complete ? SourceStatus.Partial : current.Status };
            }, stop.Token);
        }
        catch { stop.Dispose(); throw; }
        try { return await work.WaitAsync(budget + CimBudgets.GiveUpMargin, clock, token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            stop.Cancel();
            return Volatile.Read(ref latest) with { Rows = [], Status = SourceStatus.Interrupted, Detail = "Lecture arrêtée avant la vérification finale ; aucune instance publiée." };
        }
        finally { DisposeAfter(work, stop); }
    }

    public static (ImmutableArray<WmiInstanceRow> Rows, bool Truncated) WorkshopRows(WorkstationQueryRead reading)
    {
        var partial = false; var bytes = 0; var rows = ImmutableArray.CreateBuilder<WmiInstanceRow>();
        var identities = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in reading.Rows)
        {
            var values = ImmutableDictionary.CreateBuilder<string, string?>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in reading.Schema) { values[p.Name] = ExplorerValue(item.Raw(p.Name), ref partial); }
            bytes += values.Sum(v => (v.Value?.Length ?? 0) * sizeof(char));
            if (bytes > 2_097_152) { partial = true; break; }
            var keys = reading.Schema.Where(p => p.Key).ToArray();
            var id = keys.Length == 0 ? rows.Count.ToString(CultureInfo.InvariantCulture)
                : string.Join("|", keys.Select(k => k.Name + "=" + (values[k.Name] ?? "∅")));
            if (keys.Any(k => values[k.Name] is null) || !identities.Add(id)) { partial = true; continue; }
            rows.Add(new(id, values.ToImmutable()));
        }
        return (rows.ToImmutable(), partial || !reading.Complete);
    }
}
