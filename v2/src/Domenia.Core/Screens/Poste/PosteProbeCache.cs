using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core.Poste;

/// <summary>Merge by individual probe and date, inside the SQLite transaction. Failures keep dated previous payloads.</summary>
public static class PosteProbeCache
{
    public const int MaxRows = 2000;
    public const int ProjectionBytes = 96 * 1024;
    public const int MaxCellBytes = 16 * 1024;
    public const int MaxProbeBytes = 192 * 1024;

    public static string? Display(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.String => value.GetString(),
        _ => value.GetRawText(),
    };

    public static void Validate(ProbeStore store, DateTimeOffset now)
    {
        bool Date(DateTimeOffset? at) => at is null || at > DateTimeOffset.MinValue && at <= now.AddMinutes(2);
        if ((store.Values.Count > 0 && string.IsNullOrWhiteSpace(store.ReportedName)) || store.ReportedName?.Length > 255 || store.ReportedName?.Any(char.IsControl) == true
            || !Date(store.CollectedAt) || !Date(store.MonitorAt) || store.Probes.Length > ProbeCatalog.Probes.Length || store.Values.Count > ProbeCatalog.Probes.Length
            || store.SystemVolumeHistory.Length > 60 || store.MonitorHistory.Length > 20
            || store.SystemVolumeHistory.Any(s => !Date(s.At) || s.SizeBytes <= 0 || s.FreeBytes < 0 || s.FreeBytes > s.SizeBytes)
            || store.MonitorHistory.Any(s => !Date(s.At) || s.Text.Length > 2048)
            || store.MonitorSignature is { } signature && (signature.Length != 64 || signature.Any(c => !Uri.IsHexDigit(c)))
            || store.Probes.Select(p => p.ProbeId).Distinct(StringComparer.Ordinal).Count() != store.Probes.Length)
        { throw new InvalidDataException("Identité ou dates de sondes invalides."); }
        foreach (var p in store.Probes)
        {
            if (ProbeCatalog.Find(p.ProbeId) is null || !Enum.IsDefined(p.State) || !Date(p.LastSuccess) || !Date(p.LastAttempt) || !Date(p.DataAt)
                || p.LastSuccess > p.LastAttempt || p.DataAt > p.LastAttempt || p.Rows is < 0 or > MaxRows || p.Error?.Length > 2048 || !ProbeDefinitionIdentity.Valid(p.DefinitionHash))
            { throw new InvalidDataException("Statut de sonde invalide."); }
        }
        foreach (var (id, values) in store.Values)
        {
            var probe = ProbeCatalog.Find(id) ?? throw new InvalidDataException("Sonde inconnue.");
            if (!Date(values.At) || values.OmittedRows < 0 || values.OmittedCells < 0 || values.SecretsRemoved < 0
                || values.Complete && (values.OmittedRows > 0 || values.OmittedCells > 0 || values.SecretsRemoved > 0) || values.Rows.IsDefault || values.Rows.Length > MaxRows || values.Rows.Any(row => row.IsDefault || row.Length > 256
                    || !values.Columns.IsDefault && row.Length != values.Columns.Length || Current(probe.Id, values) && row.Length != probe.Properties.Length)
                || Current(probe.Id, values) && !values.Columns.IsDefault && !values.Columns.SequenceEqual(probe.Properties)
                || !ProbeDefinitionIdentity.Valid(values.DefinitionHash) || !values.Columns.IsDefault && (values.Columns.Length > 256 || values.Columns.Any(c => string.IsNullOrWhiteSpace(c) || c.Length > 128))
                || values.Rows.SelectMany(r => r).Any(v => !ValidCell(v)) || Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(values.Rows)) > MaxProbeBytes)
            { throw new InvalidDataException("Valeurs de sonde hors du contrat local."); }
        }
    }

    public static bool Current(string id, ProbeValues? value) => value is not null && ProbeCatalog.Find(id) is { } definition
        && ProbeDefinitionIdentity.Current(definition, value.DefinitionHash);
    public static ProbeStatus Qualified(ProbeStatus status) => ProbeCatalog.Find(status.ProbeId) is { } definition
        && ProbeDefinitionIdentity.Current(definition, status.DefinitionHash) ? status
        : status.LastAttempt is null && status.LastSuccess is null && status.DataAt is null ? status
        : status with { State = ProbeState.NotRead, Error = "Relevé historique : définition ancienne ou inconnue ; relancez explicitement la sonde." };

    public static bool ValidCell(JsonElement value, bool array = true) => value.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False => true,
        JsonValueKind.Number => value.GetRawText().Length <= 64,
        JsonValueKind.String => Encoding.UTF8.GetByteCount(value.GetString()!) <= MaxCellBytes,
        JsonValueKind.Array => array && value.GetArrayLength() <= 256 && value.EnumerateArray().All(v => ValidCell(v, false)),
        _ => false,
    };

    public static ProbeStore Merge(ProbeStore? old, ProbeStore next)
    {
        var values = old?.Values ?? ImmutableDictionary<string, ProbeValues>.Empty;
        foreach (var (id, data) in next.Values)
        { if (!values.TryGetValue(id, out var previous) || data.At > previous.At || data.At == previous.At && (data.Complete || !previous.Complete)) { values = values.SetItem(id, data); } }
        var statuses = (old?.Probes ?? []).ToDictionary(p => p.ProbeId, StringComparer.Ordinal);
        foreach (var probe in next.Probes)
        {
            if (!statuses.TryGetValue(probe.ProbeId, out var previous)) { statuses[probe.ProbeId] = probe; continue; }
            if (probe.LastAttempt >= previous.LastAttempt || previous.LastAttempt is null)
            { statuses[probe.ProbeId] = probe with { LastSuccess = probe.DefinitionHash == previous.DefinitionHash ? Max(probe.LastSuccess, previous.LastSuccess) : probe.LastSuccess,
                DataAt = values.GetValueOrDefault(probe.ProbeId) is { } data && data.DefinitionHash == probe.DefinitionHash ? data.At : null }; }
        }
        var latest = Max(old?.CollectedAt, next.CollectedAt);
        var volumes = old?.SystemVolumeHistory ?? [];
        if (values.GetValueOrDefault("disk.volumes") is { Complete: true } disks && Current("disk.volumes", disks))
        {
            var definition = ProbeCatalog.Find("disk.volumes")!;
            var rows = disks.Rows.Where(r => string.Equals(Display(r[definition.Properties.IndexOf("DeviceID")]), "C:", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (rows.Length == 1 && Number(rows[0][definition.Properties.IndexOf("Size")]) is > 0 and var size
                && Number(rows[0][definition.Properties.IndexOf("FreeSpace")]) is >= 0 and var free && free <= size
                && (volumes.IsEmpty || disks.At - volumes.Max(s => s.At) >= TimeSpan.FromHours(6)))
            { volumes = [.. volumes, new(disks.At, size, free)]; }
        }
        volumes = [.. volumes.Where(s => latest is null || s.At >= latest.Value.AddDays(-400)).OrderBy(s => s.At).TakeLast(60)];
        var monitors = old?.MonitorHistory ?? [];
        var current = values.GetValueOrDefault("hw.monitors"); var signature = old?.MonitorSignature; var monitorAt = old?.MonitorAt;
        if (current is { Complete: true } && Current("hw.monitors", current) && (monitorAt is null || current.At > monitorAt))
        {
            var fingerprint = Fingerprint(current);
            if (signature != fingerprint)
            {
                var active = ProbeCatalog.Find("hw.monitors")!.Properties.IndexOf("Active");
                var count = current.Rows.Count(r => r[active].ValueKind == JsonValueKind.True);
                var unknown = current.Rows.Count(r => r[active].ValueKind is not (JsonValueKind.True or JsonValueKind.False));
                monitors = [.. monitors, new(current.At, FrenchText.Count(count, "écran déclaré actif", "écrans déclarés actifs")
                    + (unknown > 0 ? " · " + FrenchText.Count(unknown, "état non lu", "états non lus") : "")
                    + (signature is null ? " · premier ensemble EDID conservé." : " · ensemble EDID modifié (identités déclarées par le pilote)."))];
            }
            signature = fingerprint; monitorAt = current.At;
        }
        return new(next.Computer, null, [.. statuses.Values.OrderBy(p => p.ProbeId, StringComparer.Ordinal)], volumes,
            [.. monitors.OrderBy(m => m.At).TakeLast(20)], [], latest)
        { HostIdentity = next.CollectedAt >= old?.CollectedAt || old is null ? next.HostIdentity : old.HostIdentity, ReportedName = next.CollectedAt >= old?.CollectedAt || old is null ? next.ReportedName ?? old?.ReportedName : old.ReportedName, Values = values, MonitorSignature = signature, MonitorAt = monitorAt };
    }

    private static DateTimeOffset? Max(DateTimeOffset? a, DateTimeOffset? b) => a is null || b > a ? b : a;
    private static long? Number(JsonElement value) => long.TryParse(Display(value), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : null;
    private static string? Fingerprint(ProbeValues? value) => value is null ? null : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
        string.Join('\n', value.Rows.Select(r => JsonSerializer.Serialize(r)).Order(StringComparer.Ordinal)))));
}
