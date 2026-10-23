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

    private const int MaxText = 2000;

    /// <summary>
    /// Plan ready for confirmation. A draft without target identity, without change, with an unknown or oversized field is a
    /// programming error of its executor (ArgumentException), never a silent fix.
    /// </summary>
    public static WritePlan Seal(WritePlanDraft draft, string id, string operatorLogin, AppMode mode, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(zone);
        ArgumentException.ThrowIfNullOrEmpty(operatorLogin);
        Validate(draft);
        if (!IsPlanId(id))
        {
            throw new ArgumentException("A plan id is 32 lower-case hexadecimal characters.", nameof(id));
        }
        var created = TruncateToSecond(now);
        var expires = created + Lifetime;
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
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        return Convert.ToHexStringLower(SHA256.HashData(buffer.ToArray()));
    }

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
            "Cible" + c + plan.Target.KindLabel + " " + plan.Target.Name,
            "DN" + c + plan.Target.Dn,
            "GUID" + c + plan.Target.ObjectGuid,
        };
        if (plan.Target.SamAccountName is string sam)
        {
            lines.Add("Compte" + c + sam);
        }
        lines.Add("Contrôleur" + c + (plan.Controller ?? "non indiqué"));
        lines.Add("Opérateur" + c + plan.Operator);
        lines.Add("Mode" + c + (plan.Simulated ? "simulation (annuaire fictif en mémoire, aucun effet réel)" : "annuaire Active Directory"));
        foreach (var change in plan.Changes)
        {
            lines.Add("Changement" + c + change.Attribute + " (" + KindText(change.Kind) + ")" + c
                + (change.BeforeValue ?? "(vide)") + " → " + (change.AfterValue ?? "(vide)"));
        }
        lines.Add("Préparé le" + c + LocalTime(plan.CreatedAt, zone) + " · valable jusqu’à " + LocalTime(plan.ExpiresAt, zone, timeOnly: true));
        lines.Add("Empreinte du plan" + c + plan.Fingerprint[..Math.Min(12, plan.Fingerprint.Length)]);
        return string.Join('\n', lines);
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
        if (draft.Target is null || string.IsNullOrWhiteSpace(draft.Target.Dn) || !Guid.TryParseExact(draft.Target.ObjectGuid, "D", out var guid) || guid == Guid.Empty
            || string.IsNullOrWhiteSpace(draft.Target.Name) || string.IsNullOrWhiteSpace(draft.Target.Kind))
        {
            throw new ArgumentException("A plan needs the exact identity of its target (DN, GUID, name, kind).", nameof(draft));
        }
        if (draft.Changes.IsDefaultOrEmpty || draft.Changes.Length > MaxChanges)
        {
            throw new ArgumentException("A plan has between 1 and 64 changes.", nameof(draft));
        }
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
    }

    private static bool IsKind(string? kind) =>
        !string.IsNullOrEmpty(kind) && kind.Length <= 64
        && kind.Split('.') is { Length: >= 2 } segments
        && segments.All(s => s.Length > 0 && char.IsAsciiLetterLower(s[0]) && s.All(char.IsAsciiLetterOrDigit));
}
