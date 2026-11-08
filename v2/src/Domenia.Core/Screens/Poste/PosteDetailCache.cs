using Domenia.Core.Queries.Wmi;
using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Queries;
using System.Text.RegularExpressions;
using System.Text;

namespace Domenia.Core.Poste;

/// <summary>Closed, dated projections of families not present in the inventory/probe cache. Never executable.</summary>
public sealed record PosteDetailSnapshot(string Family, DateTimeOffset At, string ReportedName, bool Complete,
    int OriginalRows, int OmittedRows, int OmittedCells, int SecretsRemoved)
{
    public SoftwareResult? Software { get; init; }
    public NativeWorkstationIdentity? HostIdentity { get; init; }
    public ServicesResult? Services { get; init; }
    public QuickDiagResult? Quick { get; init; }
    public WmiQueryResult? Wmi { get; init; }
    [JsonIgnore]
    public bool Usable => Complete || (Quick is { } q ? q.Facts.Any(f => f.State == FactState.Observed) : Rows > 0);
    [JsonIgnore]
    public int Rows => Software?.Rows.Length ?? Services?.Rows.Length ?? Wmi?.Instances.Length ?? Quick?.Facts.Length ?? 0;
    [JsonIgnore]
    public string Notice => $"Relevé local du {At:dd/MM/yyyy HH:mm:ss zzz} · {(Complete ? "complet" : "partiel ou non concluant")} · {Rows}/{OriginalRows} ligne(s) · {OmittedRows} écartée(s), {OmittedCells} cellule(s) hors limites, {SecretsRemoved} champ(s) sensible(s) retiré(s)." + (HostIdentity is null ? " Identité native historique, non confirmée par DNS." : " Identité native : " + HostIdentity.Label + ".");
}

public sealed record PosteDetailMemory(PosteDetailSnapshot Latest, PosteDetailSnapshot? LastUsable)
{
    [JsonIgnore]
    public PosteDetailSnapshot Display => Latest.Usable ? Latest : LastUsable ?? Latest;
    [JsonIgnore]
    public string Notice => Display.Notice + (Display.At != Latest.At ? $" Dernière tentative le {Latest.At:dd/MM/yyyy HH:mm:ss zzz}, sans nouveau relevé exploitable." : "");
}

public static class PosteDetailPrivacy
{
    public static bool Sensitive(string name) => WqlRules.IsSecret(name) || new[]
    { "CommandLine", "Command", "Arguments", "CommandParameters", "UninstallString", "QuietUninstallString", "Uninstall" }
        .Contains(name, StringComparer.OrdinalIgnoreCase);
}

public static class PosteDetailCache
{
    public const int MaxBytes = 96 * 1024;
    public const int MaxRows = 2000;
    public const int MaxCellBytes = 16 * 1024;
    public static bool Family(string value) => value is "software" or "services" or "quick" or "wmi";
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    // The output is the persisted projection. No clipping of strings: an over-limit value is visibly absent.
    public static PosteDetailSnapshot Project(PosteDetailSnapshot input)
    {
        if (!Shape(input)) throw new InvalidDataException("Structure de relevé détaillé invalide.");
        var omitted = input.OmittedCells; var secrets = input.SecretsRemoved;
        string? Cell(string? value)
        {
            if (value is null) return null;
            if (Encoding.UTF8.GetByteCount(value) > MaxCellBytes) { omitted++; return null; }
            try
            {
                var masked = SupportSecretMask.Protect(value);
                if (masked != value) secrets++;
                return masked;
            }
            catch (RegexMatchTimeoutException) { omitted++; return null; }
        }
        var result = input;
        if (input.Software is { } software)
        {
            var rows = software.Rows.Take(MaxRows).Select(r =>
            {
                if (r.Uninstall is not null) secrets++;
                return r with { Name = Cell(r.Name) ?? "Valeur hors limite", Version = Cell(r.Version), Publisher = Cell(r.Publisher),
                    Location = Cell(r.Location), Profile = Cell(r.Profile), Uninstall = null };
            }).ToImmutableArray();
            result = result with { Software = software with { Rows = rows, Board = new([], [], [], [], []), Facts = [],
                Notice = null, NoticeAction = null, Columns = PosteSoftware.Columns(rows) } };
        }
        if (input.Services is { } services)
        {
            var rows = services.Rows.Take(MaxRows).Select(r => r with { Name = Cell(r.Name) ?? "Valeur hors limite", DisplayName = Cell(r.DisplayName) ?? "Valeur hors limite",
                Description = Cell(r.Description), Account = Cell(r.Account), CanStart = false, CanRestart = false, CanStop = false }).ToImmutableArray();
            result = result with { Services = services with { Rows = rows, Profile = [] } };
        }
        if (input.Quick is { } quick)
            result = result with { Quick = quick with { Facts = quick.Facts.Select(f => f with { Value = Cell(f.Value) ?? "Valeur hors limite", Limit = Cell(f.Limit), Hint = Cell(f.Hint) }).ToImmutableArray() } };
        if (input.Wmi is { } wmi)
        {
            if (wmi.Schema.Length > 256 || wmi.Instances.Any(r => r.Length != wmi.Schema.Length)) throw new InvalidDataException("Colonnes WMI incohérentes.");
            var indices = Enumerable.Range(0, wmi.Schema.Length).Where(i => !PosteDetailPrivacy.Sensitive(wmi.Schema[i].Name)).ToArray();
            secrets += wmi.Schema.Length - indices.Length;
            var schema = indices.Select(i => wmi.Schema[i] with { Qualifiers = "" }).ToImmutableArray();
            var rows = wmi.Instances.Take(MaxRows).Select(r => indices.Select(i => Cell(r[i])).ToImmutableArray()).ToImmutableArray();
            result = result with { Wmi = wmi with { Schema = schema, Instances = rows, Where = null,
                Query = "Projection locale de " + wmi.Namespace + "\\" + wmi.Class + " ; filtre et commande non conservés." } };
        }
        // Metadata is also untrusted provider text: qualifiers, access errors, facts and summaries
        // pass through the same bounded sanitizer before any SQLite serialization.
        using (var output = new MemoryStream())
        {
            using (var writer = new Utf8JsonWriter(output))
            {
                void Write(JsonElement value)
                {
                    if (value.ValueKind == JsonValueKind.Object)
                    { writer.WriteStartObject(); foreach (var p in value.EnumerateObject()) { writer.WritePropertyName(p.Name); Write(p.Value); } writer.WriteEndObject(); }
                    else if (value.ValueKind == JsonValueKind.Array)
                    { writer.WriteStartArray(); foreach (var v in value.EnumerateArray()) Write(v); writer.WriteEndArray(); }
                    else if (value.ValueKind == JsonValueKind.String) writer.WriteStringValue(Cell(value.GetString()) ?? "Valeur hors limite");
                    else value.WriteTo(writer);
                }
                Write(JsonSerializer.SerializeToElement(result, Json));
            }
            result = JsonSerializer.Deserialize<PosteDetailSnapshot>(output.ToArray(), Json) ?? throw new InvalidDataException("Relevé vide.");
        }
        result = result with { OmittedCells = omitted, SecretsRemoved = secrets };
        var total = result.Rows;
        // Binary search retains a prefix of complete rows, never a truncated JSON or a partly serialized object.
        if (Bytes(result) > MaxBytes)
        {
            var low = 0; var high = total;
            while (low < high)
            {
                var middle = (low + high + 1) / 2;
                if (Bytes(Take(result, middle)) <= MaxBytes - 1024) low = middle; else high = middle - 1;
            }
            result = Take(result, low);
        }
        var lost = Math.Max(0, input.OriginalRows - result.Rows);
        result = result with { OmittedRows = lost, Complete = input.Complete && lost == 0 && omitted == 0 && secrets == 0 };
        if (result.Software is { } s) result = result with { Software = s with { Complete = result.Complete, Total = s.Rows.Length } };
        if (result.Services is { } v) result = result with { Services = v with { Capped = v.Capped || lost > 0, SecretsRemoved = secrets, Total = v.Rows.Length } };
        if (result.Wmi is { } w) result = result with { Wmi = w with { Truncated = w.Truncated || lost > 0 || omitted > 0, NoInstancesConfirmed = result.Complete && w.NoInstancesConfirmed == true } };
        if (Bytes(result) > MaxBytes) throw new InvalidDataException("Métadonnées du relevé supérieures à 96 Kio ; aucune écriture partielle.");
        return result;
    }

    private static PosteDetailSnapshot Take(PosteDetailSnapshot value, int count) => value with
    {
        Software = value.Software is { } s ? s with { Rows = s.Rows.Take(count).ToImmutableArray() } : null,
        Services = value.Services is { } v ? v with { Rows = v.Rows.Take(count).ToImmutableArray(), Profile = [] } : null,
        Wmi = value.Wmi is { } w ? w with { Instances = w.Instances.Take(count).ToImmutableArray() } : null,
        Quick = value.Quick is { } q ? q with { Facts = q.Facts.Take(count).ToImmutableArray(), Complete = false } : null,
    };
    public static int Bytes(PosteDetailSnapshot value) => JsonSerializer.SerializeToUtf8Bytes(value, Json).Length;

    public static PosteDetailMemory Merge(PosteDetailMemory? previous, PosteDetailMemory next)
    {
        if (previous is not null && previous.Latest.At > next.Latest.At) return previous;
        var latest = next.Latest;
        var candidates = new[] { previous?.LastUsable, previous?.Latest, next.LastUsable, latest }
            .OfType<PosteDetailSnapshot>().Where(r => r.Usable).OrderByDescending(r => r.At).ThenByDescending(r => r.Complete);
        var useful = candidates.FirstOrDefault();
        return new(latest, useful is null || useful == latest ? null : useful);
    }

    private static bool Shape(PosteDetailSnapshot value) =>
        (value.Software is not { } s || !s.Rows.IsDefault && !s.Access.IsDefault && !s.Facts.IsDefault && s.Rows.All(r => r is not null))
        && (value.Services is not { } v || !v.Rows.IsDefault && !v.Profile.IsDefault && !v.Facts.IsDefault && v.Rows.All(r => r is not null && !r.DependsOn.IsDefault && !r.Dependents.IsDefault))
        && (value.Quick is not { } q || !q.Facts.IsDefault && q.Facts.All(f => f is not null))
        && (value.Wmi is not { } w || !w.Schema.IsDefault && !w.Instances.IsDefault && w.Schema.All(p => p is not null) && w.Instances.All(r => !r.IsDefault));

    public static void Validate(PosteDetailMemory memory, string family, DateTimeOffset now)
    {
        foreach (var item in new[] { memory.Latest, memory.LastUsable }.OfType<PosteDetailSnapshot>())
        {
            if (!Shape(item) || !Family(family) || item.Family != family || item.At <= DateTimeOffset.MinValue || item.At > now.AddMinutes(2)
                || string.IsNullOrWhiteSpace(item.ReportedName) || item.ReportedName.Length > 255 || item.ReportedName.Any(char.IsControl)
                || item.OriginalRows is < 0 or > 100000 || item.OmittedRows < 0 || item.OmittedCells < 0 || item.SecretsRemoved < 0
                || item.Rows > MaxRows || item.Rows + item.OmittedRows != item.OriginalRows || Bytes(item) > MaxBytes
                || new object?[] { item.Software, item.Services, item.Quick, item.Wmi }.Count(v => v is not null) != 1
                || (family == "software") != (item.Software is not null) || (family == "services") != (item.Services is not null)
                || (family == "quick") != (item.Quick is not null) || (family == "wmi") != (item.Wmi is not null)
                || item.Software?.Rows.Any(r => r.Uninstall is not null) == true
                || item.Wmi is { } w && (w.Where is not null || w.Schema.Any(p => PosteDetailPrivacy.Sensitive(p.Name)) || w.Instances.Any(r => r.Length != w.Schema.Length)))
                throw new InvalidDataException("Relevé détaillé hors du contrat local ; aucune écriture.");
            if (JsonSerializer.Serialize(item, Json) != JsonSerializer.Serialize(Project(item), Json))
                throw new InvalidDataException("Projection détaillée non nettoyée ou hors limites ; aucune écriture.");
        }
        if (memory.LastUsable?.At > memory.Latest.At) throw new InvalidDataException("Historique postérieur à la dernière tentative.");
    }
}
