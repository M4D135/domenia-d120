using System.Management;
using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Inventory;

public enum WmiMetadataKind { Namespaces, Classes, Properties }

public sealed partial class CimSession
{
    internal Func<WmiMetadataKind, string, string?, TimeSpan, IEnumerable<WmiInstance>>? MetadataOverride { get; init; }
    internal Func<WmiMetadataKind, string, string?, TimeSpan, ShellReading>? MetadataShellOverride { get; init; }

    internal static void CheckMetadata(WmiMetadataKind kind, string ns, string? className)
    {
        if (!Enum.IsDefined(kind) || !PosteWmi.IsNamespace(ns)) { throw new ArgumentException("Lecture de schéma invalide."); }
        WqlRules.CheckNamespace(ns);
        if (kind == WmiMetadataKind.Properties)
        {
            if (!PosteWmi.IsClass(className)) { throw new ArgumentException("Nom de classe invalide."); }
            WqlRules.CheckTarget(ns, className!);
        }
        else if (className is not null) { throw new ArgumentException("Aucun nom de classe attendu pour cette liste."); }
    }

    internal static int MetadataCap(WmiMetadataKind kind) => kind switch { WmiMetadataKind.Namespaces => 256, WmiMetadataKind.Classes => 4096, _ => 512 };

    /// <summary>Closed metadata operations only. They do not relax the guard of the public instance-query path.</summary>
    internal CimReading ReadMetadata(WmiMetadataKind kind, string ns, string? className = null)
    {
        CheckMetadata(kind, ns, className);
        ObjectDisposedException.ThrowIf(disposed, this);
        const string category = "Schéma WMI";
        if (!ReadsEnabled) { return new(category, SourceStatus.Skipped, "Lecture CIM désactivée ; aucun contact.", 0, []); }
        if (authenticationRefused) { return new(category, SourceStatus.Refused, "Authentification déjà refusée ; aucun nouvel essai.", 0, []) { AuthenticationRejected = true }; }
        if (OutOfBudget || cancellationToken.IsCancellationRequested) { return new(category, SourceStatus.Interrupted, "Lecture arrêtée ou budget atteint.", 0, []); }
        var started = clock.GetTimestamp();
        var budget = Remaining < TimeSpan.FromSeconds(15) ? Remaining : TimeSpan.FromSeconds(15);
        var rows = new List<WmiInstance>();
        try
        {
            if (Transport == InventoryTransport.WinRm)
            {
                if (System.Net.IPAddress.TryParse(Host, out _)) { return new(category, SourceStatus.Unavailable, "Le schéma WinRM demande le nom DNS du poste.", 0, []); }
                if (budget <= TimeSpan.FromSeconds(2)) { return new(category, SourceStatus.Interrupted, "Budget insuffisant pour le schéma et la fermeture du shell.", 0, []); }
                var reply = MetadataShellOverride?.Invoke(kind, ns, className, budget - TimeSpan.FromSeconds(2)) ?? WinRm.ReadMetadata(kind, ns, className, budget - TimeSpan.FromSeconds(2));
                authenticationRefused |= reply.AuthenticationRejected;
                var cleanup = reply.CleanupComplete ? "" : " Fermeture du shell non confirmée ; aucune nouvelle création.";
                if (reply.Status != SourceStatus.Ok || reply.Json is null)
                { return new(category, reply.Status, "Schéma " + PosteLabels.SourceStatusLabel(reply.Status).ToLowerInvariant() + "." + cleanup, (int)clock.GetElapsedTime(started).TotalMilliseconds, []) { AuthenticationRejected = reply.AuthenticationRejected }; }
                var parsed = ParseMetadata(kind, ns, className, Host, reply.Json);
                authenticationRefused |= parsed.AuthenticationRejected;
                return parsed with { Status = !reply.CleanupComplete && parsed.Answered ? SourceStatus.Partial : parsed.Status,
                    Detail = parsed.Detail + cleanup, DurationMs = (int)clock.GetElapsedTime(started).TotalMilliseconds };
            }
            var capped = false;
            foreach (var item in MetadataOverride?.Invoke(kind, ns, className, budget) ?? Metadata(kind, ns, className, budget))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (OutOfBudget || clock.GetElapsedTime(started) >= budget) { throw new TimeoutException(); }
                if (rows.Count == MetadataCap(kind)) { capped = true; break; }
                rows.Add(item);
            }
            return FilterMetadata(kind, rows, capped ? SourceStatus.Partial : rows.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok,
                "Définitions WMI lues ; aucune instance de la classe demandée.") with { DurationMs = (int)clock.GetElapsedTime(started).TotalMilliseconds };
        }
        catch (JsonException) { return new(category, SourceStatus.Error, "Réponse de schéma hors contrat, hors limites ou identité différente.", (int)clock.GetElapsedTime(started).TotalMilliseconds, []); }
        catch (Exception ex) when (Classify(ex) is SourceStatus status)
        {
            authenticationRefused |= WindowsAuthenticationErrors.IsRejected(ex.HResult);
            return FilterMetadata(kind, rows, rows.Count > 0 ? SourceStatus.Partial : status, Detail(ex, status)) with
            { DurationMs = (int)clock.GetElapsedTime(started).TotalMilliseconds, AuthenticationRejected = authenticationRefused };
        }
    }

    private IEnumerable<WmiInstance> Metadata(WmiMetadataKind kind, string ns, string? className, TimeSpan timeout)
    {
        var options = new ConnectionOptions { Impersonation = ImpersonationLevel.Impersonate, Authentication = AuthenticationLevel.PacketPrivacy,
            EnablePrivileges = false, Timeout = timeout < CimBudgets.Connect ? timeout : CimBudgets.Connect };
        ManagementScope? scope = null;
        ManagementObjectSearcher? searcher = null;
        ManagementClass? definition = null;
        var started = clock.GetTimestamp();
        TimeSpan Left() => timeout - clock.GetElapsedTime(started) is { } value && value > TimeSpan.Zero ? value : throw new TimeoutException();
        try
        {
            if (credential is { Session: false }) { options.Username = credential.Account; options.SecurePassword = credential.Password; }
            scope = new(@"\\" + Host + @"\" + ns, options); scope.Connect();
            cancellationToken.ThrowIfCancellationRequested();
            if (kind == WmiMetadataKind.Properties)
            {
                definition = new(scope, new ManagementPath(className!), new ObjectGetOptions { Timeout = Left(), UseAmendedQualifiers = false });
                definition.Get();
                foreach (PropertyData p in definition.Properties)
                {
                    cancellationToken.ThrowIfCancellationRequested(); _ = Left();
                    var qualifiers = p.Qualifiers.Cast<QualifierData>().ToArray();
                    yield return new(new Dictionary<string, object?> { ["Name"] = p.Name, ["Type"] = p.Type + (p.IsArray ? "[]" : ""),
                        ["Key"] = qualifiers.Any(q => q.Name.Equals("key", StringComparison.OrdinalIgnoreCase) && q.Value is true),
                        ["Qualifiers"] = string.Join(", ", qualifiers.Select(q => q.Name).Order(StringComparer.OrdinalIgnoreCase)) });
                }
                yield break;
            }
            // The strings are fixed and this method is inaccessible from the instance-query entry point.
            var query = kind == WmiMetadataKind.Namespaces ? "SELECT Name FROM __Namespace" : "SELECT * FROM meta_class";
            searcher = new(scope, new ObjectQuery(query), new System.Management.EnumerationOptions { Timeout = Left(), ReturnImmediately = true, Rewindable = false, BlockSize = 1 });
            using var results = searcher.Get();
            foreach (var item in results)
            {
                using (item)
                {
                    cancellationToken.ThrowIfCancellationRequested(); _ = Left();
                    yield return new(new Dictionary<string, object?> { ["Name"] = kind == WmiMetadataKind.Namespaces ? item["Name"] : item["__CLASS"] });
                }
            }
        }
        finally
        {
            if (definition is not null) { definition.Scope.Options.SecurePassword = null; definition.Dispose(); }
            if (searcher is not null) { searcher.Scope.Options.SecurePassword = null; searcher.Dispose(); }
            if (scope is not null) { scope.Options.SecurePassword = null; }
            options.SecurePassword = null;
        }
    }

    internal static CimReading ParseMetadata(WmiMetadataKind kind, string ns, string? className, string host, string json)
    {
        CheckMetadata(kind, ns, className);
        if (json.Length > 1_048_576) { throw new JsonException(); }
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object || Text(root, "Format") != "Domenia.WmiMetadata/1" || Text(root, "Kind") != kind.ToString()
            || !string.Equals(Text(root, "Computer"), host.Split('.')[0], StringComparison.OrdinalIgnoreCase)
            || !string.Equals(Text(root, "Namespace"), ns, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(Text(root, "Class"), className, StringComparison.OrdinalIgnoreCase)
            || !root.TryGetProperty("Code", out var codeValue) || codeValue.ValueKind != JsonValueKind.Number || !codeValue.TryGetInt32(out var code)
            || !root.TryGetProperty("Partial", out var partial) || partial.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || !root.TryGetProperty("Rows", out var array) || array.ValueKind != JsonValueKind.Array || array.GetArrayLength() > MetadataCap(kind)) { throw new JsonException(); }
        var rows = new List<WmiInstance>();
        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) { throw new JsonException(); }
            var row = new Dictionary<string, object?> { ["Name"] = Text(item, "Name") };
            if (kind == WmiMetadataKind.Properties)
            {
                if (!item.TryGetProperty("Key", out var key) || key.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) { throw new JsonException(); }
                row["Key"] = key.GetBoolean(); row["Type"] = Text(item, "Type"); row["Qualifiers"] = Text(item, "Qualifiers");
            }
            rows.Add(new(row));
        }
        var status = code != 0 ? rows.Count > 0 ? SourceStatus.Partial : Classify(new COMException("Schéma non lu.", code)) ?? SourceStatus.Error
            : partial.GetBoolean() ? SourceStatus.Partial : rows.Count > 0 ? SourceStatus.Ok : SourceStatus.Empty;
        return FilterMetadata(kind, rows, status, "Définitions WMI lues ; aucune instance de la classe demandée.") with { AuthenticationRejected = WindowsAuthenticationErrors.IsRejected(code) };
    }

    private static CimReading FilterMetadata(WmiMetadataKind kind, IReadOnlyList<WmiInstance> raw, SourceStatus status, string detail)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var rows = new List<WmiInstance>(); var invalid = false; var hidden = 0;
        foreach (var item in raw)
        {
            var name = item.Text("Name");
            if (name?.StartsWith("__", StringComparison.Ordinal) == true || kind == WmiMetadataKind.Properties && WqlRules.IsSecret(name ?? "")) { hidden++; continue; }
            if (!PosteWmi.IsClass(name) || kind == WmiMetadataKind.Properties && (item.Text("Type") is not { Length: <= 64 } || item.Bool("Key") is null || (item.Text("Qualifiers")?.Length ?? 0) > 2048))
            { invalid = true; continue; }
            if (!names.Add(name!)) { invalid = true; rows.RemoveAll(r => string.Equals(r.Text("Name"), name, StringComparison.OrdinalIgnoreCase)); continue; }
            rows.Add(item);
        }
        return new("Schéma WMI", invalid && status is SourceStatus.Ok or SourceStatus.Empty ? SourceStatus.Partial : status,
            detail + (status == SourceStatus.Partial || invalid ? " Définition partielle ou plafond atteint." : "") + (hidden > 0 ? " Attributs sensibles ou objets système exclus : " + hidden + "." : ""), 0, rows);
    }
}
