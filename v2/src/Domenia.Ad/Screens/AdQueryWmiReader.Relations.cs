using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdQueryWmiReader
{
    private readonly Lock evidenceGate = new();
    private readonly Dictionary<string, (DateTimeOffset At, long Epoch)> evidence = new(StringComparer.Ordinal);
    private static string RowKey(Guid computer, string ns, string className, WmiInstanceRow row) => computer.ToString("N") + "|" + ns.ToUpperInvariant() + "|" + className.ToUpperInvariant() + "|"
        + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(row.Values.OrderBy(p => p.Key, StringComparer.Ordinal)))));

    private void Forget(Guid computer)
    {
        lock (evidenceGate)
        {
            foreach (var key in evidence.Keys.Where(k => k.StartsWith(computer.ToString("N") + "|", StringComparison.Ordinal)).ToArray()) { evidence.Remove(key); }
        }
    }

    private void Remember(WmiSelectResult result, long epoch)
    {
        lock (evidenceGate)
        {
            foreach (var row in result.Rows) { evidence[RowKey(result.ComputerGuid, result.Namespace, result.ClassName, row)] = (result.ReadAt, epoch); }
            while (evidence.Count > 4096) { evidence.Remove(evidence.MinBy(p => p.Value.At).Key); }
        }
    }

    public async Task<WmiSelectResult> RelatedAsync(Guid computer, string ns, string sourceClass, WmiInstanceRow sourceRow, WmiRelationPreset preset, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(sourceRow); ArgumentNullException.ThrowIfNull(preset);
        var declared = WqlRules.RelationPresets(sourceClass).SingleOrDefault(p => p.Id == preset.Id)
            ?? throw new QueryDefinitionException("Relation absente du catalogue fermé ; aucun contact.");
        // Only the catalog controls the target class, properties and join. A forged DTO cannot extend the operation.
        preset = declared;
        if (!ns.Equals(@"root\cimv2", StringComparison.OrdinalIgnoreCase) || sourceRow.Values.Count > 64 || sourceRow.Values.Any(v => v.Value?.Length > 2048))
        { throw new QueryDefinitionException("Relation hors espace de noms ou instance hors limites."); }
        lock (evidenceGate)
        {
            if (!evidence.TryGetValue(RowKey(computer, ns, sourceClass, sourceRow), out var proof) || proof.Epoch != source.Epoch
                || proof.At < source.Clock.GetUtcNow().AddMinutes(-5) || proof.At > source.Clock.GetUtcNow())
            { throw new QueryDefinitionException("Relisez ce SELECT : l’instance n’a pas de lecture récente dans cette session."); }
        }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(150), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var sourceKey = Key(sourceClass);
        var sourceValue = sourceRow.Values.GetValueOrDefault(sourceKey) ?? throw new QueryDefinitionException("Clé de l’instance absente ; relisez le SELECT.");
        var extra = sourceClass.Equals("Win32_Process", StringComparison.OrdinalIgnoreCase) ? ", CreationDate" : sourceClass.Equals("Win32_Service", StringComparison.OrdinalIgnoreCase) ? ", ProcessId" : "";
        var (_, fresh) = await ReadAsync(computer, ns, WqlRules.Parse("SELECT " + sourceKey + extra + " FROM " + sourceClass + " WHERE " + sourceKey + " = " + Literal(sourceClass, sourceValue)), 2, stop.Token).ConfigureAwait(false);
        if (!fresh.Complete || fresh.Rows.Length != 1)
        { throw new QueryDefinitionException("Instance source absente ou ambiguë à la relecture ; relation non poursuivie."); }
        if (sourceClass.Equals("Win32_Process", StringComparison.OrdinalIgnoreCase)
            && (!sourceRow.Values.TryGetValue("CreationDate", out var before) || before is null || fresh.Rows[0].Text("CreationDate") != before))
        { throw new QueryDefinitionException("Date de création du processus absente ou modifiée ; PID potentiellement réutilisé, relation non poursuivie."); }
        if (preset.Kind == "Reference")
        {
            var value = WqlRules.ReferenceValue(preset, fresh.Rows[0].Text(preset.SourceProperty));
            if (sourceRow.Values.GetValueOrDefault(preset.SourceProperty) != value)
            { throw new QueryDefinitionException("Processus hébergeant l’instance modifié ; relisez le SELECT."); }
            return await SelectAsync(computer, ns, WqlRules.Parse("SELECT " + string.Join(", ", preset.Properties) + " FROM " + preset.Result + " WHERE "
                + preset.TargetProperty + " = " + (preset.ValueKind == "Number" ? value : CimQuery.Literal(value))), 500, stop.Token).ConfigureAwait(false);
        }
        var (pc, links) = await ReadAsync(computer, ns, WqlRules.Parse("SELECT Antecedent, Dependent FROM " + preset.Association), 1000, stop.Token).ConfigureAwait(false);
        var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var incomplete = !links.Complete;
        foreach (var link in links.Rows)
        {
            var left = WorkshopRelationPath.Parse(link.Text("Antecedent"), pc.DnsHostName!, ns);
            var right = WorkshopRelationPath.Parse(link.Text("Dependent"), pc.DnsHostName!, ns);
            if (left is null || right is null) { incomplete = true; continue; }
            Add(left, right); Add(right, left);
        }
        void Add(WorkshopRelationPath side, WorkshopRelationPath other)
        {
            if (side.ClassName.Equals(sourceClass, StringComparison.OrdinalIgnoreCase) && side.Property.Equals(sourceKey, StringComparison.OrdinalIgnoreCase)
                && side.Value.Equals(sourceValue, StringComparison.OrdinalIgnoreCase) && other.ClassName.Equals(preset.Result, StringComparison.OrdinalIgnoreCase)
                && other.Property.Equals(Key(preset.Result), StringComparison.OrdinalIgnoreCase)) { targets.Add(other.Value); }
        }
        if (targets.Count > 32) { throw new QueryDefinitionException("Plus de 32 instances liées ; affinez le SELECT source avant de poursuivre."); }
        var schema = await SchemaAsync(computer, ns, preset.Result, stop.Token).ConfigureAwait(false);
        var columns = schema.Properties.Where(p => !p.CimType.Contains("ref", StringComparison.OrdinalIgnoreCase)).OrderByDescending(p => p.Key).Take(16).Select(p => p.Name).ToImmutableArray();
        if (columns.IsEmpty) { throw new QueryDefinitionException("Schéma cible sans projection sûre."); }
        if (targets.Count == 0)
        {
            var canonical = "SELECT " + string.Join(", ", columns) + " FROM " + preset.Result + " WHERE " + Key(preset.Result) + " = " + Literal(preset.Result, sourceValue);
            return new(pc.Name, computer, ns, preset.Result, "Relation déclarée : " + preset.Id, columns, [], incomplete, 0, source.Clock.GetUtcNow(), WqlRules.RequestKey(ns, canonical),
                incomplete ? "Liste des liens incomplète ; aucune absence confirmée." : "Aucun lien dans la classe d’association lue complètement.");
        }
        var query = WqlRules.Parse("SELECT " + string.Join(", ", columns) + " FROM " + preset.Result + " WHERE " + string.Join(" OR ", targets.Order(StringComparer.OrdinalIgnoreCase).Select(v => Key(preset.Result) + " = " + Literal(preset.Result, v))));
        var result = await SelectAsync(computer, ns, query, 500, stop.Token).ConfigureAwait(false);
        return result with { Truncated = result.Truncated || incomplete, Note = result.Note + (incomplete ? " Classe de liens partielle ; liste liée non exhaustive." : " Relation du catalogue lue par projections explicites.") };
    }

    private static string Key(string className) => className.ToUpperInvariant() switch
    {
        "WIN32_DISKDRIVE" or "WIN32_DISKPARTITION" or "WIN32_LOGICALDISK" => "DeviceID",
        "WIN32_NETWORKADAPTER" or "WIN32_NETWORKADAPTERCONFIGURATION" => "Index",
        "WIN32_PROCESS" => "Handle",
        "WIN32_SERVICE" => "Name",
        _ => throw new QueryDefinitionException("Classe de relation non déclarée."),
    };
    private static string Literal(string className, string value)
    {
        if (Key(className) == "Index")
        { return uint.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) ? number.ToString(CultureInfo.InvariantCulture) : throw new QueryDefinitionException("Index de relation invalide."); }
        return CimQuery.Literal(value);
    }
}
