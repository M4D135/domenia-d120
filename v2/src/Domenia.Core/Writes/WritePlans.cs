using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Sealing of a plan (pure): identifier, account, mode, dates, fingerprint and folded technical text are added to the draft of
/// the executor. The fingerprint is the SHA-256 of a canonical JSON of everything the write depends on (Domenia 1
/// InterventionPlan.ComputeFingerprint): operation, exact target, destination, account, mode, ordered changes with their raw
/// values, dates. The confirmation token is bound to it (<see cref="ConfirmationTokens"/>).
/// </summary>
public static class WritePlans
{
    /// <summary>Validity of a plan and of its confirmation token (decision of the write circuit, 21/10: five minutes).</summary>
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(5);

    /// <summary>Most changes in one plan; a collective write needs its own plan with an exact preview (TRV-229).</summary>
    public const int MaxChanges = 64;
    public const int MaxBytes = 4 * 1024 * 1024;

    private const int MaxText = 2000;

    /// <summary>
    /// Plan ready for confirmation. A draft without target identity, without change, with an unknown or oversized field is a
    /// programming error of its executor (ArgumentException), never a silent fix.
    /// </summary>
    public static WritePlan Seal(WritePlanDraft draft, string id, string operatorLogin, AppMode mode, DateTimeOffset now, TimeZoneInfo zone, TimeSpan? maximumAge = null)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(zone);
        ArgumentException.ThrowIfNullOrEmpty(operatorLogin);
        Validate(draft);
        if (!IsPlanId(id))
        {
            throw new ArgumentException("A plan id is 32 lower-case hexadecimal characters.", nameof(id));
        }
        var age = maximumAge ?? Lifetime;
        if (age < TimeSpan.FromMinutes(1) || age > Lifetime || now <= DateTimeOffset.UnixEpoch)
            throw new ArgumentException("Horloge absente ou durée de confirmation hors de 1 à 5 minutes.", nameof(maximumAge));
        var created = TruncateToSecond(now);
        var expires = created + age;
        var modeText = mode == AppMode.Simulation ? AppInfoBuilder.SimulationModeText : AppInfoBuilder.DirectoryModeText;
        var plan = new WritePlan(
            id,
            draft.Kind,
            draft.Title,
            draft.Label,
            draft.Summary,
            draft.Target,
            draft.Changes,
            draft.Risks,
            draft.Confirmation,
            draft.Reversibility,
            draft.Controller,
            operatorLogin,
            modeText,
            mode == AppMode.Simulation,
            created,
            expires,
            "",
            "");
        var fingerprint = ComputeFingerprint(plan);
        plan = plan with { Fingerprint = fingerprint };
        return plan with { Details = DescribeTechnical(plan, zone) };
    }

    /// <summary>
    /// SHA-256 (lower-case hex) of the canonical form of the plan. Texts for the operator (title, summary, labels, risks,
    /// details) are left out on purpose: the fingerprint protects what is sent and to whom, not the wording.
    /// </summary>
    public static string ComputeFingerprint(WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false }))
        {
            writer.WriteStartObject();
            writer.WriteString("format", "domenia.writePlan");
            writer.WriteNumber("version", 1);
            writer.WriteString("id", plan.Id);
            writer.WriteString("kind", plan.Kind);
            writer.WriteString("targetKind", plan.Target.Kind);
            writer.WriteString("targetDn", plan.Target.Dn);
            writer.WriteString("targetGuid", plan.Target.ObjectGuid);
            if (plan.Target.DirectoryUsn is { } usn) writer.WriteNumber("directoryUsn", usn);
            writer.WriteString("targetSam", plan.Target.SamAccountName);
            writer.WriteString("controller", plan.Controller);
            writer.WriteString("operator", plan.Operator);
            writer.WriteString("mode", plan.Mode);
            writer.WriteBoolean("simulated", plan.Simulated);
            writer.WriteBoolean("typedNameRequired", plan.Confirmation.TypedNameRequired);
            writer.WriteString("typedName", plan.Confirmation.TypedName);
            writer.WriteString("createdAt", plan.CreatedAt.UtcDateTime.ToString("o", CultureInfo.InvariantCulture));
            writer.WriteString("expiresAt", plan.ExpiresAt.UtcDateTime.ToString("o", CultureInfo.InvariantCulture));
            writer.WriteStartArray("changes");
            foreach (var change in plan.Changes)
            {
                writer.WriteStartObject();
                writer.WriteString("attribute", change.Attribute);
                writer.WriteString("kind", change.Kind.ToString());
                writer.WriteString("beforeValue", change.BeforeValue);
                writer.WriteString("afterValue", change.AfterValue);
                // Omitted for legacy/simulation plans: their durable fingerprints remain valid.
                if (change.ReferenceGuid is not null) { writer.WriteString("referenceGuid", change.ReferenceGuid); }
                if (change.ReferenceUsn is { } referenceUsn) writer.WriteNumber("referenceUsn", referenceUsn);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        return Convert.ToHexStringLower(SHA256.HashData(buffer.ToArray()));
    }

    /// <summary>Stable key of the requested change, independent of a fresh confirmation identifier and wall clock.</summary>
    public static string ComputeRequestFingerprint(WritePlan plan) => ComputeFingerprint(plan with
    { Id = new string('0', 32), CreatedAt = DateTimeOffset.UnixEpoch, ExpiresAt = DateTimeOffset.UnixEpoch + Lifetime });

    /// <summary>True when the plan still matches its fingerprint (nothing was changed after sealing).</summary>
    public static bool IsIntact(WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(ComputeFingerprint(plan)),
            Encoding.ASCII.GetBytes(plan.Fingerprint));
    }

    /// <summary>New plan or receipt identifier: 32 lower-case hexadecimal characters from 16 random bytes.</summary>
    public static string NewId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    /// <summary>32 lower-case hexadecimal characters.</summary>
    public static bool IsPlanId(string? value) =>
        value is { Length: 32 } && value.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    /// <summary>Folded technical text of the confirmation (TRV-225): one line per fact, first 12 characters of the fingerprint.</summary>
    public static string DescribeTechnical(WritePlan plan, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var lines = new List<string>
        {
            "Opération" + c + plan.Kind,
            "Cible" + c + plan.Target.KindLabel + " " + Flat(plan.Target.Name),
            "DN" + c + Flat(plan.Target.Dn),
            "Domaine" + c + DomainText(plan.Target.Dn),
            "GUID" + c + plan.Target.ObjectGuid,
        };
        if (plan.Target.SamAccountName is string sam)
        {
            lines.Add("Compte" + c + Flat(sam));
        }
        lines.Add("Contrôleur" + c + (plan.Controller ?? "non indiqué"));
        lines.Add("Opérateur" + c + Flat(plan.Operator));
        lines.Add("Mode" + c + (plan.Simulated ? "simulation (annuaire fictif en mémoire, aucun effet réel)" : "annuaire Active Directory"));
        foreach (var change in plan.Changes)
        {
            lines.Add("Changement" + c + change.Attribute + " (" + KindText(change.Kind) + ")" + c
                + TechnicalValue(plan, change.Attribute, change.BeforeValue) + " → " + TechnicalValue(plan, change.Attribute, change.AfterValue));
        }
        foreach (var risk in plan.Risks) lines.Add("Effet ou risque" + c + Flat(risk.Text));
        lines.Add("Préparé le" + c + LocalTime(plan.CreatedAt, zone) + " · valable jusqu’à " + LocalTime(plan.ExpiresAt, zone, timeOnly: true));
        lines.Add("Empreinte du plan" + c + plan.Fingerprint[..Math.Min(12, plan.Fingerprint.Length)]);
        return string.Join('\n', lines);
    }

    // The exact annex/proof is already carried and hashed in Changes. Duplicating megabytes into the human-readable
    // Details would defeat the ordinary receipt-field bound. This summary does not replace or truncate the actual value.
    private static string TechnicalValue(WritePlan plan, string attribute, string? value)
    {
        if (value is null) return "(vide)";
        var storagePayload = plan.Target.Kind == StorageWritePlans.TargetKind
            && (attribute == "backup.preferences" && plan.Kind is StorageWritePlans.Backup or StorageWritePlans.BackupCopy
                || attribute == "switch.proof" && plan.Kind is StorageWritePlans.Move or StorageWritePlans.Restore or StorageWritePlans.Resume or StorageWritePlans.Rollback);
        return storagePayload ? "Document exact joint au plan, " + Encoding.UTF8.GetByteCount(value).ToString(CultureInfo.InvariantCulture)
            + " octets, SHA-256 " + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value))) : Flat(value);
    }

    private static string Flat(string text) => string.Join(' ', text.Replace("\r\n", "\n", StringComparison.Ordinal).Split(['\r', '\n', '\u0085', '\u2028', '\u2029'], StringSplitOptions.None));
    private static string DomainText(string dn)
    {
        try
        {
            var labels = DistinguishedName.Parse(dn).Where(r => r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(r => r.Value).ToArray();
            return labels.Length == 0 ? "sans domaine AD (opération locale)" : Flat(string.Join('.', labels));
        }
        catch (FormatException) { return "non déterminé"; }
    }

    /// <summary>« 21/10/2026 à 18:12 » (or « 18:12 ») in the given zone, independent of the culture.</summary>
    public static string LocalTime(DateTimeOffset at, TimeZoneInfo zone, bool timeOnly = false)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(at, zone);
        var time = local.ToString("HH':'mm", CultureInfo.InvariantCulture);
        return timeOnly ? time : local.ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture) + " à " + time;
    }

    public static DateTimeOffset TruncateToSecond(DateTimeOffset value) =>
        new(value.UtcTicks - value.UtcTicks % TimeSpan.TicksPerSecond, TimeSpan.Zero);

    private static string KindText(WriteChangeKind kind) => kind switch
    {
        WriteChangeKind.Replace => "remplacement",
        WriteChangeKind.Clear => "remise à zéro",
        WriteChangeKind.Add => "ajout",
        WriteChangeKind.Remove => "retrait",
        WriteChangeKind.Move => "déplacement",
        _ => "réinitialisation",
    };

    private static void Validate(WritePlanDraft draft)
    {
        if (!IsKind(draft.Kind))
        {
            throw new ArgumentException("The kind of a write is a dotted lower camel case name (« account.unlock »).", nameof(draft));
        }
        if (draft.Target is null || draft.Target.DirectoryUsn is <= 0 || string.IsNullOrWhiteSpace(draft.Target.Dn) || !Guid.TryParseExact(draft.Target.ObjectGuid, "D", out var guid) || guid == Guid.Empty
            || string.IsNullOrWhiteSpace(draft.Target.Name) || string.IsNullOrWhiteSpace(draft.Target.Kind))
        {
            throw new ArgumentException("A plan needs the exact identity of its target (DN, GUID, name, kind).", nameof(draft));
        }
        if (draft.Changes.IsDefaultOrEmpty || draft.Changes.Length > MaxChanges)
        {
            throw new ArgumentException("A plan has between 1 and 64 changes.", nameof(draft));
        }
        if (draft.Changes.Any(change => !Enum.IsDefined(change.Kind)))
            throw new ArgumentException("Nature de changement inconnue ; aucun plan préparé.", nameof(draft));
        if (draft.Changes.Any(change => change.ReferenceUsn is <= 0))
            throw new ArgumentException("La version USN de l’objet référencé doit être strictement positive.", nameof(draft));
        if (draft.Changes.Any(change => SecretAttributes.Contains(change.Attribute)
            && (change.BeforeValue is not null || change.AfterValue is not null)))
            throw new ArgumentException("Valeur secrète interdite dans un plan ; seul le geste de réinitialisation sans valeur peut être conservé.", nameof(draft));
        if (draft.Risks.IsDefault)
        {
            throw new ArgumentException("The risks of a plan are an array (empty when none).", nameof(draft));
        }
        if (draft.Confirmation is null || draft.Reversibility is null)
        {
            throw new ArgumentException("A plan says how it is confirmed and whether it can be undone.", nameof(draft));
        }
        if (draft.Confirmation.TypedNameRequired && string.IsNullOrEmpty(draft.Confirmation.TypedName))
        {
            throw new ArgumentException("A typed confirmation needs the name to type.", nameof(draft));
        }
        foreach (var text in new[] { draft.Title, draft.Label, draft.Summary })
        {
            if (string.IsNullOrWhiteSpace(text) || text.Length > MaxText)
            {
                throw new ArgumentException("Title, label and summary are short French texts.", nameof(draft));
            }
        }
        if (JsonSerializer.SerializeToUtf8Bytes(draft).Length > MaxBytes)
            throw new ArgumentException("Plan supérieur à 4 Mio ; réduisez le périmètre avant de préparer l’opération.", nameof(draft));
    }

    private static bool IsKind(string? kind) =>
        !string.IsNullOrEmpty(kind) && kind.Length <= 64
        && kind.Split('.') is { Length: >= 2 } segments
        && segments.All(s => s.Length > 0 && char.IsAsciiLetterLower(s[0]) && s.All(char.IsAsciiLetterOrDigit));
}
