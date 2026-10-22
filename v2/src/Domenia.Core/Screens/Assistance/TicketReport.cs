using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>One known name and its keyed pseudonym; the table stays beside the local preview, never inside the text.</summary>
public sealed record PseudonymEntry(string Kind, string Original, string Pseudonym);

/// <summary>A name to pseudonymise and its family (Utilisateur, Machine, Groupe, Objet, Compte, Identifiant).</summary>
public sealed record KnownName(string Value, string Kind, string Family);

/// <summary>
/// Keyed pseudonyms (Domenia 1 ConvertTo-DomeniaPseudonym, ConvertTo-DomeniaInsightMaskedNames): HMAC-SHA256 under the
/// operator key, case ignored as in the directory. Without a key of 8 characters or more, a hash of a name could be reversed
/// from a list of names, so it is refused. Names are replaced on whole words, longest first, in two passes so that a pseudonym
/// already written is never rewritten.
/// </summary>
public static partial class Pseudonyms
{
    public const int MinKeyLength = 8;

    public static bool IsValidKey(string? key) => !string.IsNullOrWhiteSpace(key) && key.Length >= MinKeyLength;

    public static string Of(string? value, string key, string kind, int length = 8)
    {
        if (!IsValidKey(key))
        {
            throw new DomeniaOperationException(AssistanceErrors.KeyMissing, AssistanceErrors.KeyMissingMessage);
        }
        ArgumentOutOfRangeException.ThrowIfLessThan(length, 6);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(length, 32);
        var text = (value ?? "").Trim();
        if (text.Length == 0)
        {
            return "";
        }
        var label = new string((kind ?? "").Where(char.IsAsciiLetter).ToArray());
        if (label.Length == 0)
        {
            label = "Valeur";
        }
        var hash = HMACSHA256.HashData(Encoding.UTF8.GetBytes(key), Encoding.UTF8.GetBytes("domenia-pseudonym|" + text.ToLowerInvariant()));
        return label + "-" + Convert.ToHexString(hash)[..length];
    }

    /// <summary>The correspondence table of the known names whose kind is chosen, without duplicates, longest first.</summary>
    public static ImmutableArray<PseudonymEntry> Map(IEnumerable<KnownName> known, string key, IReadOnlyCollection<string> kinds)
    {
        ArgumentNullException.ThrowIfNull(known);
        ArgumentNullException.ThrowIfNull(kinds);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var map = new List<PseudonymEntry>();
        foreach (var item in known)
        {
            var value = (item.Value ?? "").Trim();
            if (value.Length == 0 || !kinds.Contains(item.Kind) || !seen.Add(value))
            {
                continue;
            }
            map.Add(new PseudonymEntry(item.Kind, value, Of(value, key, item.Family)));
        }
        return [.. map.OrderByDescending(e => e.Original.Length)];
    }

    /// <summary>Replaces every known identifier by its pseudonym on whole names, longest first, in two passes.</summary>
    public static string Mask(string? text, IReadOnlyList<PseudonymEntry> map)
    {
        ArgumentNullException.ThrowIfNull(map);
        var result = text ?? "";
        if (result.Length == 0 || map.Count == 0)
        {
            return result;
        }
        var entries = map.Where(e => e.Original.Length > 0).OrderByDescending(e => e.Original.Length).ToList();
        const char open = '\u0001';
        const char close = '\u0002';
        for (var i = 0; i < entries.Count; i++)
        {
            var pattern = @"(?<![\p{L}\p{N}_])" + Regex.Escape(entries[i].Original) + @"(?![\p{L}\p{N}_])";
            var marker = open + i.ToString(CultureInfo.InvariantCulture) + close;
            result = Regex.Replace(result, pattern, marker.Replace("$", "$$", StringComparison.Ordinal), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));
        }
        for (var i = 0; i < entries.Count; i++)
        {
            result = result.Replace(open + i.ToString(CultureInfo.InvariantCulture) + close, entries[i].Pseudonym, StringComparison.Ordinal);
        }
        return result;
    }

    /// <summary>
    /// The only way a free text enters a ticket (Domenia 1 ConvertTo-DomeniaInsightText): one line, known names replaced on the
    /// whole text, secrets masked twice, and only then bounded, so that a cut never leaves part of a known name in clear.
    /// </summary>
    public static string Clean(string? value, int maximum, IReadOnlyList<PseudonymEntry>? map = null)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "";
        }
        var source = Spaces().Replace(value, " ").Trim();
        if (map is { Count: > 0 })
        {
            source = Mask(source, map);
        }
        var text = SecretMask.Protect(SupportText.Clean(source, 8192));
        return SupportText.Flat(text, maximum);
    }

    [GeneratedRegex(@"[\x00-\x20\x7F\s]+", RegexOptions.CultureInvariant, 100)]
    private static partial Regex Spaces();
}

/// <summary>Closed vocabulary of a ticket: attempted, confirmed, refused, not tested (Domenia 1 ConvertTo-DomeniaInsightStepStatus).</summary>
public enum TicketStatus
{
    Attempted,
    Confirmed,
    Refused,
    NotTested,
}

/// <summary>
/// One thing done (or not) for the ticket: the object it targeted (GUID), its raw status, when, a label and a detail, whether
/// the detail is sensitive (then only the label is kept) and the account that ran it.
/// </summary>
public sealed record TicketStep(string? TargetGuid, string Status, DateTimeOffset? When, string Label, string? Detail, bool Sensitive, string? Reader);

/// <summary>Object of the ticket: its GUID, kind (« user », « computer »…), name and aliases (login, UPN, mail).</summary>
public sealed record TicketSubject(string? Guid, string Kind, string Name, ImmutableArray<string> Aliases);

public sealed record TicketCounts(int Attempted, int Confirmed, int Refused, int NotTested);

public sealed record TicketExcluded(int OtherObject, int Unlinked);

/// <summary>Result of the ticket report (format DomeniaTicket/1); refused with a reason, never a preview in clear instead.</summary>
public sealed record TicketReportResult(
    string Format,
    bool Ready,
    string Reason,
    string Text,
    string Sha256,
    ImmutableArray<string> Sections,
    TicketCounts? Counts,
    TicketExcluded? Excluded,
    bool Pseudonymized,
    ImmutableArray<PseudonymEntry> Map);

/// <summary>
/// Reviewable ticket summary (Domenia 1 New-DomeniaTicketReport, D104): attempted, confirmed, refused and not tested, in the
/// sections the operator selects. Only steps tied to the object by its GUID are kept; texts go through the support cleaning
/// and the secret masks; a sensitive step keeps its label only. Domenia 1 never called it; Domenia 2 feeds it with the steps
/// of the recipes launched for the object and the write receipts of that object.
/// </summary>
public static class TicketReport
{
    public const string Format = "DomeniaTicket/1";

    /// <summary>Section identifiers, in their order in the text.</summary>
    public static ImmutableArray<string> SectionIds { get; } = ["context", "attempted", "confirmed", "refused", "notTested", "limits"];

    /// <summary>Kinds of names pseudonymised by default.</summary>
    public static ImmutableArray<string> DefaultKinds { get; } = ["Utilisateur", "Machine", "Groupe", "Objet", "Compte"];

    public static TicketStatus StatusOf(string? raw) => (raw ?? "").Trim() switch
    {
        "Confirme" or "Confirmed" or "Verifie" or "Verified" => TicketStatus.Confirmed,
        "Refuse" or "Refused" or "Denied" or "AccessDenied" or "CredentialsRejected" or "DecryptionDenied" => TicketStatus.Refused,
        "NonTeste" or "NotTested" or "Skipped" or "NotRun" or "NotAttempted" => TicketStatus.NotTested,
        _ => TicketStatus.Attempted,
    };

    /// <summary>What is known of the outcome of an attempted action. Sent is not done.</summary>
    public static string OutcomeText(string? raw) => (raw ?? "").Trim() switch
    {
        "Confirmed" or "Confirme" or "Verified" or "Verifie" => "Confirmé",
        "Refused" or "Refuse" or "AccessDenied" or "Denied" => "Refusé",
        "Failed" or "Failure" or "Echec" or "Timeout" => "Échec signalé",
        "Sent" or "Envoye" or "Queued" => "Envoyé, issue non confirmée",
        _ => "Issue non confirmée",
    };

    public static string KindLabel(string kind) => kind switch
    {
        "user" => "Utilisateur",
        "computer" => "Machine",
        "group" => "Groupe",
        _ => "Objet",
    };

    public static TicketReportResult Build(
        TicketSubject subject,
        IEnumerable<TicketStep> steps,
        IReadOnlyCollection<string> sections,
        bool pseudonymize,
        string? key,
        IReadOnlyCollection<string>? kinds,
        IEnumerable<KnownName>? identifiers,
        DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(steps);
        ArgumentNullException.ThrowIfNull(sections);
        var chosen = SectionIds.Where(s => sections.Contains(s)).ToImmutableArray();
        var contextGuid = Guid.TryParse(subject.Guid, out var parsedGuid) && parsedGuid != Guid.Empty ? parsedGuid.ToString("D") : null;
        string? refusal = null;
        if (contextGuid is null)
        {
            refusal = "Objet du ticket non identifié par son GUID" + FrenchText.Colon + "aucun compte rendu.";
        }
        else if (pseudonymize && !Pseudonyms.IsValidKey(key))
        {
            refusal = "Clé de pseudonymisation requise (8 caractères au moins)" + FrenchText.Colon + "aucun aperçu en clair n’est produit à la place.";
        }
        if (refusal is not null)
        {
            return new TicketReportResult(Format, false, refusal, "", "", chosen, null, null, false, []);
        }
        var kindLabel = KindLabel(subject.Kind);
        var known = new List<KnownName>
        {
            new(Pseudonyms.Clean(subject.Name, 1024), kindLabel, kindLabel),
            new(contextGuid!, kindLabel, "Identifiant"),
        };
        known.AddRange(subject.Aliases.Select(a => new KnownName(Pseudonyms.Clean(a, 1024), kindLabel, kindLabel)));
        known.AddRange((identifiers ?? []).Select(i => new KnownName(Pseudonyms.Clean(i.Value, 1024), i.Kind, i.Family)));

        var kept = new List<(TicketStatus Status, string When, TicketStep Step, string Reader, string Outcome)>();
        int attempted = 0, confirmed = 0, refused = 0, notTested = 0, other = 0, unlinked = 0;
        foreach (var step in steps)
        {
            if (step is null)
            {
                continue;
            }
            if (!Guid.TryParse(step.TargetGuid, out var stepGuid) || stepGuid == Guid.Empty)
            {
                unlinked++;
                continue;
            }
            if (stepGuid.ToString("D") != contextGuid)
            {
                other++;
                continue;
            }
            var status = StatusOf(step.Status);
            var reader = Pseudonyms.Clean(step.Reader, 1024);
            if (reader.Length > 0)
            {
                known.Add(new KnownName(reader, "Compte", "Compte"));
            }
            var when = step.When is DateTimeOffset at ? at.ToUniversalTime().ToString("yyyy'-'MM'-'dd' 'HH':'mm", CultureInfo.InvariantCulture) + " UTC" : "date inconnue";
            kept.Add((status, when, step, reader, status == TicketStatus.Attempted ? OutcomeText(step.Status) : ""));
            switch (status)
            {
                case TicketStatus.Confirmed: confirmed++; break;
                case TicketStatus.Refused: refused++; break;
                case TicketStatus.NotTested: notTested++; break;
                default: attempted++; break;
            }
        }
        var map = pseudonymize ? Pseudonyms.Map(known, key!, kinds ?? DefaultKinds) : [];
        var lines = new List<string>
        {
            "DOMENIA | COMPTE RENDU DE TICKET",
            "Généré" + FrenchText.Colon + now.ToUniversalTime().ToString("yyyy'-'MM'-'dd' 'HH':'mm", CultureInfo.InvariantCulture) + " UTC",
            "Aperçu local" + FrenchText.Colon + "relire avant tout envoi.",
        };
        if (chosen.Contains("context"))
        {
            lines.Add("");
            lines.Add("[CONTEXTE]");
            lines.Add("Objet" + FrenchText.Colon + Pseudonyms.Clean(subject.Name, 160, map) + " | Type" + FrenchText.Colon + kindLabel);
            lines.Add("Identifiant" + FrenchText.Colon + Pseudonyms.Mask(contextGuid, map));
            lines.Add(pseudonymize ? "Pseudonymisation" + FrenchText.Colon + "active, clé fournie par l’opérateur." : "Pseudonymisation" + FrenchText.Colon + "inactive.");
        }
        var titles = new Dictionary<TicketStatus, (string Id, string Title, int Count)>
        {
            [TicketStatus.Attempted] = ("attempted", "TENTÉ (sans confirmation)", attempted),
            [TicketStatus.Confirmed] = ("confirmed", "CONFIRMÉ", confirmed),
            [TicketStatus.Refused] = ("refused", "REFUSÉ", refused),
            [TicketStatus.NotTested] = ("notTested", "NON TESTÉ", notTested),
        };
        foreach (var status in new[] { TicketStatus.Attempted, TicketStatus.Confirmed, TicketStatus.Refused, TicketStatus.NotTested })
        {
            var (id, title, count) = titles[status];
            if (!chosen.Contains(id))
            {
                continue;
            }
            lines.Add("");
            lines.Add("[" + title + "] " + FrenchText.Integer(count));
            var items = kept.Where(k => k.Status == status).ToList();
            if (items.Count == 0)
            {
                lines.Add("- aucun élément");
            }
            foreach (var item in items)
            {
                var line = "- " + Pseudonyms.Clean(item.Step.Label, 160, map) + " (" + item.When + ")";
                if (item.Outcome.Length > 0)
                {
                    line += " [" + item.Outcome + "]";
                }
                var detail = item.Step.Sensitive ? "[détail sensible retiré]" : Pseudonyms.Clean(item.Step.Detail, 400, map);
                if (detail.Length > 0)
                {
                    line += FrenchText.Colon + detail;
                }
                var reader = Pseudonyms.Clean(item.Reader, 120, map);
                if (reader.Length > 0)
                {
                    line += " [compte" + FrenchText.Colon + reader + "]";
                }
                lines.Add(line);
            }
        }
        if (chosen.Contains("limits"))
        {
            lines.Add("");
            lines.Add("[LIMITES]");
            lines.Add("Seuls les éléments rattachés à cet objet par son GUID figurent ici.");
            lines.Add("Secrets masqués" + FrenchText.Colon + "aucun mot de passe, aucune clé BitLocker, aucun identifiant de connexion.");
            lines.Add("Un refus n’est pas une absence" + FrenchText.Nbsp + "; un élément non testé reste inconnu.");
            if (other + unlinked > 0)
            {
                lines.Add(FrenchText.Count(other + unlinked, "élément écarté", "éléments écartés") + FrenchText.Colon + "autre objet ou rattachement non vérifiable.");
            }
        }
        var text = string.Join("\r\n", lines);
        return new TicketReportResult(Format, true, "", text, Hash(text), chosen, new TicketCounts(attempted, confirmed, refused, notTested),
            new TicketExcluded(other, unlinked), pseudonymize, map);
    }

    /// <summary>SHA-256 of a text in UTF-8, lower-case hexadecimal.</summary>
    public static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text ?? "")));
}
