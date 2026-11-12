using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>State of one measurement (Domenia 1 vocabulary, Domenia-Collection.Model.ps1).</summary>
public enum MeasureState
{
    Known,
    Absent,
    NotRead,
    Refused,
    Expired,
    Incomplete,
    Error,
}

/// <summary>
/// Last presence reading (ping) of a workstation. A reading exists only when <see cref="State"/> is Known with a date and an
/// answer; a missing answer is never a verdict. <see cref="LastOnlineAt"/> is the last time the workstation answered.
/// </summary>
public sealed record PresenceMeasure(MeasureState State, bool? Answered, DateTimeOffset? CheckedAt, DateTimeOffset? LastOnlineAt)
{
    public static PresenceMeasure Unread { get; } = new(MeasureState.NotRead, null, null, null);

    /// <summary>Closed diagnostic vocabulary: no target, address, credentials or native exception message.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public PresenceDiagnostic? Diagnostic { get; init; }

    public bool HasReading => State == MeasureState.Known && CheckedAt is not null && Answered is not null;

    /// <summary>The reading as one explainable fact (TRV-138): source, limit, date and reader account travel with it.</summary>
    public DomeniaFact AsFact(string label = "Présence du poste", string source = "Relevé ICMP enregistré", string? reader = null) =>
        DomeniaFact.OfPresence(label, this, source, reader);
}

public enum PresenceReadOutcome
{
    Reply, NoReply, InvalidTarget, DnsNotFound, DnsUnavailable, DnsTimeout,
    AddressUnavailable, NetworkUnavailable, IcmpError, DeadlineExceeded,
}

/// <summary>The numeric code is an IPStatus/SocketError/native error, never raw error text.</summary>
public sealed record PresenceDiagnostic(PresenceReadOutcome Outcome, string Stage, int? NativeCode = null)
{
    /// <summary>Stage of a target refused from its directory account alone, before any DNS or ICMP request.</summary>
    public const string DirectoryStage = "directory";

    public string Text => Outcome switch
    {
        PresenceReadOutcome.Reply => "Réponse ICMP reçue.",
        PresenceReadOutcome.NoReply => "Aucune réponse ICMP dans le délai ; cela ne prouve pas que le poste est éteint.",
        PresenceReadOutcome.InvalidTarget when Stage == DirectoryStage => "Nom DNS absent de l’annuaire ou différent du nom du compte ordinateur ; aucun test ICMP envoyé.",
        PresenceReadOutcome.InvalidTarget => "Nom ou adresse du poste invalide ; aucun test ICMP envoyé.",
        PresenceReadOutcome.DnsNotFound => "Nom du poste non résolu ; aucun test ICMP envoyé, présence inconnue.",
        PresenceReadOutcome.DnsUnavailable => "Résolution DNS en erreur ; aucun test ICMP envoyé, présence inconnue.",
        PresenceReadOutcome.DnsTimeout => "Délai de résolution DNS dépassé ; aucun test ICMP envoyé, présence inconnue.",
        PresenceReadOutcome.AddressUnavailable => "Adresse absente ou non utilisable pour ICMP ; présence inconnue.",
        PresenceReadOutcome.NetworkUnavailable => "Le transport réseau n’a pas permis le test ICMP ; présence inconnue.",
        PresenceReadOutcome.IcmpError => "Le test ICMP a échoué ; aucune réponse négative n’est déduite.",
        PresenceReadOutcome.DeadlineExceeded => "Budget du test ICMP dépassé ; présence non confirmée.",
        _ => "Présence non confirmée.",
    };
}

/// <summary>
/// The one classification of the presence outcomes, shared by every consumer (field report of version 2.0.7, 30/10/2026).
/// Definitive: the resolver answered that the name has no address (DnsNotFound), or the name is not a valid host name
/// (InvalidTarget). No ICMP echo was sent and presence stays unknown: never « sans réponse », never eligible for WMI. Asking
/// again for the same name changes nothing, so a dated definitive answer settles its target for a refresh: it is not retried,
/// not counted as a failed or unconfirmed reading, and does not make a refresh partial. Transient: DNS unavailable or late,
/// unusable address, transport or ICMP error, budget exceeded; a later attempt can give a reading, so these stay to be measured.
/// Reply and NoReply are readings. A static rule on purpose: PresenceMeasure and PresenceDiagnostic are serialized as they are.
/// </summary>
public static class PresenceOutcomes
{
    /// <summary>Clock keys of the definitive answers, in display order (CollectionClocks.StatesText).</summary>
    public static ImmutableArray<string> DefinitiveKeys { get; } = ["dnsAbsent", "dnsNoAddress", "invalidName"];

    public static bool IsDefinitive(PresenceReadOutcome outcome) => outcome is PresenceReadOutcome.DnsNotFound or PresenceReadOutcome.InvalidTarget;

    public static bool IsTransient(PresenceReadOutcome outcome) => outcome is PresenceReadOutcome.DnsUnavailable or PresenceReadOutcome.DnsTimeout
        or PresenceReadOutcome.AddressUnavailable or PresenceReadOutcome.NetworkUnavailable or PresenceReadOutcome.IcmpError or PresenceReadOutcome.DeadlineExceeded;

    /// <summary>A dated definitive answer about the name (no reading), measured at or after <paramref name="since"/> when given.</summary>
    public static bool Definitive(PresenceMeasure? measure, DateTimeOffset? since = null) =>
        measure is { State: MeasureState.Error, Answered: null, CheckedAt: { } at, Diagnostic: { } diagnostic }
        && IsDefinitive(diagnostic.Outcome) && (since is null || at >= since);

    /// <summary>
    /// Nothing left to ask this target since <paramref name="since"/>: a reading or a definitive answer dated in [since, latest].
    /// An older definitive answer never settles a target the current refresh did not reach.
    /// </summary>
    public static bool Settled(PresenceMeasure? measure, DateTimeOffset since, DateTimeOffset? latest = null) =>
        measure is { CheckedAt: { } at } && at >= since && (latest is null || at <= latest) && (measure.HasReading || Definitive(measure));

    /// <summary>« dnsAbsent » (11001 or no code), « dnsNoAddress » (11004: the name exists without an address record), « invalidName ».</summary>
    public static string Key(PresenceDiagnostic diagnostic)
    {
        ArgumentNullException.ThrowIfNull(diagnostic);
        return diagnostic.Outcome == PresenceReadOutcome.InvalidTarget ? "invalidName"
            : diagnostic.NativeCode == (int)System.Net.Sockets.SocketError.NoData ? "dnsNoAddress" : "dnsAbsent";
    }

    /// <summary>Noun of a definitive key, singular or plural: « nom absent du DNS », « noms de poste invalides »; null for another key.</summary>
    public static string? Label(string key, long count) => key switch
    {
        "dnsAbsent" => count >= 2 ? "noms absents du DNS" : "nom absent du DNS",
        "dnsNoAddress" => count >= 2 ? "noms sans adresse dans le DNS" : "nom sans adresse dans le DNS",
        "invalidName" => count >= 2 ? "noms de poste invalides" : "nom de poste invalide",
        _ => null,
    };

    /// <summary>« 1 nom absent du DNS · 2 noms de poste invalides »: the definitive answers by reason, empty without any.</summary>
    public static string DefinitiveText(IEnumerable<PresenceMeasure?> measures, DateTimeOffset? since = null)
    {
        ArgumentNullException.ThrowIfNull(measures);
        var counts = measures.Where(m => Definitive(m, since)).GroupBy(m => Key(m!.Diagnostic!), StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal);
        return string.Join(" · ", DefinitiveKeys.Where(counts.ContainsKey).Select(k => FrenchText.Integer(counts[k]) + " " + Label(k, counts[k])));
    }

    /// <summary>
    /// Why a target has no settled result since <paramref name="since"/>: the transient cause of its dated attempt, « cause non
    /// enregistrée » for a dated attempt without one, or « aucun résultat pour ce relevé » when nothing is dated since then.
    /// </summary>
    public static string Cause(PresenceMeasure? measure, DateTimeOffset since)
    {
        if (measure is not { CheckedAt: { } at } || at < since) { return "aucun résultat pour ce relevé"; }
        return measure.Diagnostic is { } diagnostic && IsTransient(diagnostic.Outcome) ? diagnostic.Outcome switch
        {
            PresenceReadOutcome.DnsUnavailable => "DNS indisponible",
            PresenceReadOutcome.DnsTimeout => "délai DNS dépassé",
            PresenceReadOutcome.AddressUnavailable => "adresse inutilisable",
            PresenceReadOutcome.NetworkUnavailable => "réseau indisponible",
            PresenceReadOutcome.IcmpError => "erreur ICMP",
            _ => "délai du ping dépassé",
        } : "cause non enregistrée";
    }

    /// <summary>« DNS indisponible, délai DNS dépassé »: distinct causes, the most frequent first.</summary>
    public static string Causes(IEnumerable<string> causes)
    {
        ArgumentNullException.ThrowIfNull(causes);
        return string.Join(", ", causes.GroupBy(c => c, StringComparer.Ordinal).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).Select(g => g.Key));
    }
}

/// <summary>Last inventory reading (WMI). A disk size of 0 or unreadable is « no reading », never a full disk.</summary>
public sealed record InventoryMeasure(
    MeasureState State,
    DateTimeOffset? CheckedAt,
    long? SystemDiskSizeBytes,
    long? SystemDiskFreeBytes,
    DateTimeOffset? LastBootAt,
    string? Model,
    long? MemoryBytes,
    string? OsCaption,
    string? Build)
{
    public static InventoryMeasure Unread { get; } = new(MeasureState.NotRead, null, null, null, null, null, null, null, null);

    public bool HasReading => State == MeasureState.Known && CheckedAt is not null;

    /// <summary>One dated successful inventory only; the current attempt keeps its own state and date.</summary>
    public InventoryMeasure? LastSuccessful { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public InventoryMeasure? LastKnown => HasReading ? this : LastSuccessful is { HasReading: true, LastSuccessful: null } previous && previous.CheckedAt <= CheckedAt ? previous : null;

    public static InventoryMeasure Merge(InventoryMeasure previous, InventoryMeasure next)
    {
        var latest = next.CheckedAt >= previous.CheckedAt || previous.CheckedAt is null ? next : previous;
        if (latest.HasReading) return latest with { LastSuccessful = null };
        var successful = new[] { previous, next, previous.LastSuccessful, next.LastSuccessful }
            .OfType<InventoryMeasure>().Where(v => v.HasReading && v.CheckedAt <= latest.CheckedAt)
            .MaxBy(v => v.CheckedAt);
        return latest with { LastSuccessful = successful is null ? null : successful with { LastSuccessful = null } };
    }

    /// <summary>
    /// The inventory as one explainable fact (TRV-138): the readings module states its measures like every other module,
    /// with a source, the limit that says an inventory dates from its reading, and the date of that reading.
    /// </summary>
    public DomeniaFact AsFact(string label = "Inventaire du poste", string source = "Lecture CIM enregistrée", string? reader = null) =>
        DomeniaFact.OfMeasure(label, State switch
        {
            MeasureState.Known => HasReading ? "Inventaire lu" : "Inventaire non daté",
            MeasureState.Absent => "Poste sans inventaire à rendre",
            MeasureState.Refused => "Lecture d’inventaire refusée",
            MeasureState.Expired => "Inventaire trop ancien",
            MeasureState.Incomplete => "Inventaire incomplet",
            MeasureState.Error => "Lecture d’inventaire en erreur",
            _ => "Jamais relevé",
        }, State == MeasureState.Known && !HasReading ? MeasureState.NotRead : State, source,
        HasReading
            ? "Un inventaire date de sa lecture" + FrenchText.Colon + "il ne mesure pas l’état du poste à l’instant."
            : LastKnown is not null ? "La dernière tentative n’a pas fourni d’inventaire ; le dernier succès reste disponible à sa date d’origine."
            : "Aucune mesure utilisable" + FrenchText.Colon + "rien n’est conclu sur l’inventaire du poste.",
        null, CheckedAt, reader);
}

public sealed record WorkstationObservation(Guid ComputerGuid, PresenceMeasure Presence, InventoryMeasure Inventory);

/// <summary>Local observations of the workstations (presence and inventory), keyed by computer GUID.</summary>
public sealed record FleetObservations
{
    private readonly ImmutableArray<WorkstationObservation> entries;
    private readonly ImmutableDictionary<Guid, WorkstationObservation>? indexed;
    private sealed class Index(ImmutableDictionary<Guid, WorkstationObservation> byId)
    {
        internal ImmutableDictionary<Guid, WorkstationObservation> ById { get; } = byId;
        internal Lazy<ImmutableArray<WorkstationObservation>> Rows { get; } = new(() => [.. byId.Values]);
    }
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<FleetObservations, Index> Indexes = new();
    [System.Text.Json.Serialization.JsonConstructor]
    public FleetObservations(DateTimeOffset? takenAt, ImmutableArray<WorkstationObservation> workstations)
    { TakenAt = takenAt; entries = workstations; }
    private FleetObservations(DateTimeOffset? takenAt, ImmutableDictionary<Guid, WorkstationObservation> workstations, bool indexedSnapshot)
    { TakenAt = takenAt; entries = default; indexed = workstations; }
    public DateTimeOffset? TakenAt { get; init; }
    public ImmutableArray<WorkstationObservation> Workstations
    {
        get => !entries.IsDefault ? entries : GetIndex().Rows.Value;
        init { entries = value; indexed = null; }
    }
    public void Deconstruct(out DateTimeOffset? takenAt, out ImmutableArray<WorkstationObservation> workstations)
    { takenAt = TakenAt; workstations = Workstations; }
    private Index GetIndex() => Indexes.GetValue(this, value => new(value.indexed ?? value.entries.ToImmutableDictionary(row => row.ComputerGuid)));
    public WorkstationObservation? Find(Guid computer) => GetIndex().ById.GetValueOrDefault(computer);
    public static FleetObservations Indexed(DateTimeOffset? takenAt, ImmutableDictionary<Guid, WorkstationObservation> workstations) => new(takenAt, workstations, true);
    public FleetObservations Merge(FleetObservations patch)
    {
        var at = patch.TakenAt >= TakenAt || TakenAt is null ? patch.TakenAt : TakenAt;
        if (patch.Workstations.IsEmpty) { return at == TakenAt ? this : this with { TakenAt = at }; }
        var result = GetIndex().ById;
        foreach (var next in patch.Workstations)
        {
            if (!result.TryGetValue(next.ComputerGuid, out var old)) { result = result.SetItem(next.ComputerGuid, next); continue; }
            var presence = next.Presence.CheckedAt >= old.Presence.CheckedAt || old.Presence.CheckedAt is null ? next.Presence : old.Presence;
            presence = presence with { LastOnlineAt = old.Presence.LastOnlineAt >= next.Presence.LastOnlineAt || next.Presence.LastOnlineAt is null
                ? old.Presence.LastOnlineAt : next.Presence.LastOnlineAt };
            var inventory = InventoryMeasure.Merge(old.Inventory, next.Inventory);
            result = result.SetItem(next.ComputerGuid, new(next.ComputerGuid, presence, inventory));
        }
        return new(at, result, true);
    }
    public static FleetObservations Empty { get; } = new(null, []);
}

/// <summary>Daily snapshot of the home figures. A null figure is missing, never zero.</summary>
public sealed record DailyFigures(
    DateOnly Day,
    int? WorkstationsOnline,
    int? WorkstationsSeen,
    int? ActiveAccounts,
    int? LockedAccounts,
    int? PasswordsExpiring,
    int? DiskAlerts);

/// <summary>Local calendar days in a given time zone, robust to daylight saving transitions.</summary>
public static class LocalDays
{
    public static DateOnly DateOf(DateTimeOffset instant, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        return DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, timeZone).DateTime);
    }

    /// <summary>UTC instant of the first valid local minute of <paramref name="day"/>.</summary>
    public static DateTimeOffset StartOf(DateOnly day, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var local = day.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        while (timeZone.IsInvalidTime(local))
        {
            local = local.AddMinutes(1);
        }
        var offset = timeZone.IsAmbiguousTime(local) ? timeZone.GetAmbiguousTimeOffsets(local).Max() : timeZone.GetUtcOffset(local);
        return new DateTimeOffset(local, offset).ToUniversalTime();
    }
}
