using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Inventory;

public sealed record WorkstationWmiReading(string? ReportedName, SourceStatus Status, string Detail,
    ImmutableArray<string> Names, ImmutableArray<WmiProperty> Schema, ImmutableArray<ImmutableArray<string?>> Rows, string? Query, int DurationMs)
{
    public bool AuthenticationRejected { get; init; }
}

public sealed partial class WmiWorkstationReader
{
    public Task<WorkstationWmiReading> ReadWmiMetadataAsync(string host, WmiMetadataKind kind, string ns, string? className,
        CancellationToken token, RemoteProbeCredential? credential = null) => ReadExplorerAsync(host, kind, ns, className, null, token, credential);

    public Task<WorkstationWmiReading> ReadWmiQueryAsync(string host, WmiRequest request, CancellationToken token, RemoteProbeCredential? credential = null)
    {
        CheckExplorerRequest(request);
        return ReadExplorerAsync(host, WmiMetadataKind.Properties, request.Namespace, request.Class, request, token, credential);
    }

    public static void CheckExplorerRequest(WmiRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var (valid, error) = PosteWmi.Validate(request.Namespace, request.Class, request.Where, request.Limit);
        if (valid is null || request.Limit is < 1 or > 500) { throw new QueryDefinitionException(error ?? "Limite de lecture WMI invalide."); }
        // Syntax, forbidden providers, domain-wide enumeration and sensitive WHERE properties are checked before any network contact.
        WqlRules.CheckTarget(request.Namespace, request.Class);
        var plan = WqlRules.Parse("SELECT Name FROM " + request.Class + (request.Where is null ? "" : " WHERE " + request.Where));
        if (plan.WhereProperties.Any(ExplorerSensitive)) { throw new QueryDefinitionException("Filtre sur attribut sensible refusé."); }
    }

    private async Task<WorkstationWmiReading> ReadExplorerAsync(string host, WmiMetadataKind kind, string ns, string? className,
        WmiRequest? request, CancellationToken token, RemoteProbeCredential? credential)
    {
        CimSession.CheckMetadata(kind, ns, className);
        if (!CimQuery.IsHostName(host)) { throw new ArgumentException("Nom de poste invalide.", nameof(host)); }
        var budget = TimeSpan.FromSeconds(request is null ? 20 : 35);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        var started = clock.GetTimestamp();
        var latest = new WorkstationWmiReading(null, SourceStatus.Interrupted, "Lecture non commencée.", [], [], [], null, 0);
        Task<WorkstationWmiReading> work;
        try
        {
            work = WmiReadWorkers.Start(credential, owned =>
            {
                using var session = Session(host, budget, stop.Token, owned);
                var identity = session.Read(InventoryCategories.System, Cimv2, "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
                var name = identity.Instances.FirstOrDefault()?.Text("Name");
                var current = latest with { ReportedName = name, AuthenticationRejected = identity.AuthenticationRejected };
                if (name is null || !name.Equals(host.Split('.')[0], StringComparison.OrdinalIgnoreCase))
                { return current with { Status = identity.Answered ? SourceStatus.Unavailable : identity.Status, Detail = "Identité Windows non confirmée ; explorateur non interrogé." }; }
                Volatile.Write(ref latest, current);
                var metadata = session.ReadMetadata(kind, ns, className);
                current = current with { Status = metadata.Status, Detail = metadata.Detail, AuthenticationRejected = metadata.AuthenticationRejected };
                if (kind != WmiMetadataKind.Properties)
                {
                    return current with { Names = [.. metadata.Instances.Select(p => p.Text("Name")!).Order(StringComparer.OrdinalIgnoreCase)] };
                }
                var schema = metadata.Instances.Select(p => new WmiProperty(p.Text("Name")!, p.Text("Type")!, p.Bool("Key") == true, p.Text("Qualifiers") ?? "")).ToImmutableArray();
                current = current with { Schema = schema };
                if (request is null || !metadata.Answered) { return current; }
                Volatile.Write(ref latest, current with { Status = SourceStatus.Interrupted, Detail = "Schéma reçu ; instances non encore lues." });
                string query;
                ImmutableArray<WmiProperty> selected;
                try { (query, selected) = ExplorerProjection(request, schema); }
                catch (QueryDefinitionException) { return current with { Status = SourceStatus.Error, Detail = "Projection ou filtre incompatible avec le schéma reçu ; aucune instance demandée." }; }
                current = current with { Schema = selected, Query = query };
                var rows = ImmutableArray.CreateBuilder<ImmutableArray<string?>>();
                var partial = metadata.Status == SourceStatus.Partial || selected.Length != schema.Length;
                var bytes = 0;
                void Receive(WmiInstance instance)
                {
                    if (bytes > 2_097_152) { partial = true; return; }
                    var row = selected.Select(p => ExplorerValue(instance.Raw(p.Name), ref partial)).ToImmutableArray();
                    bytes += row.Sum(v => (v?.Length ?? 0) * sizeof(char));
                    if (bytes > 2_097_152) { partial = true; return; }
                    rows.Add(row);
                    Volatile.Write(ref latest, current with { Rows = rows.ToImmutable(), Status = SourceStatus.Partial, Detail = "Instances reçues ; lecture en cours." });
                }
                var read = session.Read("Explorateur WMI", ns, query, request.Limit, TimeSpan.FromSeconds(20), Receive);
                partial |= read.Status == SourceStatus.Partial;
                return current with { Status = read.Answered && partial ? SourceStatus.Partial : read.Status, Rows = rows.ToImmutable(),
                    Detail = read.Detail + (partial ? " Projection, valeurs ou liste incomplètes ; limites : 64 propriétés, 500 instances, 2 Mio." : "")
                        + (schema.Length != selected.Length ? " Propriétés non projetées : " + (schema.Length - selected.Length) + "." : ""),
                    AuthenticationRejected = read.AuthenticationRejected || metadata.AuthenticationRejected };
            }, stop.Token);
        }
        catch { stop.Dispose(); throw; }
        try { return (await work.WaitAsync(budget + CimBudgets.GiveUpMargin, clock, token).ConfigureAwait(false)) with { DurationMs = (int)clock.GetElapsedTime(started).TotalMilliseconds }; }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            stop.Cancel();
            _ = work.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            var previous = Volatile.Read(ref latest);
            return previous with { Status = previous.Rows.IsEmpty && previous.Names.IsEmpty ? SourceStatus.Interrupted : SourceStatus.Partial,
                Detail = "Lecture arrêtée ou budget atteint ; aucun résultat complet déclaré.", DurationMs = (int)clock.GetElapsedTime(started).TotalMilliseconds };
        }
        finally { DisposeAfter(work, stop); }
    }

    internal static (string Query, ImmutableArray<WmiProperty> Schema) ExplorerProjection(WmiRequest request, ImmutableArray<WmiProperty> schema)
    {
        CheckExplorerRequest(request);
        var plan = WqlRules.Parse("SELECT Name FROM " + request.Class + (request.Where is null ? "" : " WHERE " + request.Where));
        var referenced = plan.WhereProperties.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var safe = schema.Where(p => PosteWmi.IsClass(p.Name) && !ExplorerSensitive(p.Name) && !p.Type.Contains("Instance", StringComparison.OrdinalIgnoreCase)
            && !p.Type.StartsWith("Object", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (safe.Length == 0 || safe.Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != safe.Length)
        { throw new QueryDefinitionException("Schéma sans projection sûre et non ambiguë."); }
        var selected = new List<WmiProperty>();
        string Query(IEnumerable<WmiProperty> fields) => "SELECT " + string.Join(", ", fields.Select(p => p.Name)) + " FROM " + request.Class + (request.Where is null ? "" : " WHERE " + request.Where);
        foreach (var property in safe.OrderByDescending(p => referenced.Contains(p.Name)).ThenByDescending(p => p.Key).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase))
        {
            if (selected.Count >= 64 || Query(selected.Append(property)).Length > CimQuery.MaxLength) { continue; }
            selected.Add(property);
        }
        if (selected.Count == 0) { throw new QueryDefinitionException("Aucune propriété projetable dans les limites."); }
        var query = Query(selected);
        _ = WqlRules.Parse(query, safe.Select(p => p.Name).ToArray());
        if (!CimQuery.IsReadOnlySelect(query, request.Namespace)) { throw new QueryDefinitionException("Requête refusée par la garde de lecture."); }
        return (query, [.. selected]);
    }

    private static bool ExplorerSensitive(string name) => WqlRules.IsSecret(name) || new[] { "CommandLine", "Command", "Arguments", "CommandParameters", "UninstallString", "QuietUninstallString" }.Contains(name, StringComparer.OrdinalIgnoreCase);

    internal static string? ExplorerValue(object? value, ref bool partial, int depth = 0)
    {
        if (value is null) { return null; }
        if (depth > 3) { partial = true; return null; }
        if (value is Array array)
        {
            var parts = new List<string>();
            foreach (var item in array)
            {
                if (parts.Count == 64) { partial = true; break; }
                parts.Add(ExplorerValue(item, ref partial, depth + 1) ?? "∅");
            }
            return ExplorerValue(string.Join(" ; ", parts), ref partial);
        }
        var text = value switch
        {
            string s => s, bool flag => flag ? "True" : "False",
            byte or sbyte or short or ushort or int or uint or long or ulong or float or double or decimal => Convert.ToString(value, CultureInfo.InvariantCulture),
            _ => null,
        };
        if (text is null) { partial = true; return null; }
        if (text.Length > 2048) { partial = true; text = text[..2047] + "…"; }
        return string.Concat(text.Select(c => char.IsControl(c) && c is not '\t' and not '\n' and not '\r' ? ' ' : c));
    }
}
