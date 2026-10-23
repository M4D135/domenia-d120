using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Pure rules of the user/workstation relations (port of Domenia-Relations.Model.ps1, D041 to D050 and points 9 and 107):
/// nature of the proof, keys and equality, upsert without replacement, primary relation, explainable badges, contradictions,
/// the separate statements of a subject, identity across renames and recycled names, protected sources, orphans, dates. No
/// probe, no LDAP read and no storage access is started here; every date and time zone is an input.
/// </summary>
public static partial class RelationRules
{
    /// <summary>Sources an automatic check never removes and a detection never replaces (Domenia 1 Get-DomeniaProtectedAssociationSources).</summary>
    public static ImmutableArray<string> ProtectedSources { get; } = ["Manual", "Saisie manuelle", "Import CSV", "Import GLPI", "Import osquery"];

    /// <summary>Source written for an association declared in the page.</summary>
    public const string ManualSource = "Saisie manuelle";

    /// <summary>Source of a console read by CIM/DCOM (detection, « Lire la session de ce poste »).</summary>
    public const string ConsoleSource = "Console CIM/DCOM";

    /// <summary>Source of the couples read in the controller journal.</summary>
    public const string HarvestSource = "Journal du contrôleur (4768, 4769, 4624)";

    private const string Arrow = " → ";

    private static string C => FrenchText.Colon;

    // ------------------------------------------------------------------ nature of the proof (D042)

    /// <summary>
    /// Closed vocabulary from the stored source text. The order matters (Domenia 1 Get-DomeniaRelationKind): an AD owner
    /// attribute is a clue, a LogonUI value or a profile is history, the current console is an observation.
    /// </summary>
    public static RelationKind KindOf(string? source)
    {
        var text = source ?? "";
        if (OwnerPattern().IsMatch(text))
        {
            return RelationKind.Hint;
        }
        if (AssignmentPattern().IsMatch(text))
        {
            return RelationKind.Assignment;
        }
        if (ImportPattern().IsMatch(text))
        {
            return RelationKind.Imported;
        }
        if (RemotePattern().IsMatch(text))
        {
            return RelationKind.RemoteSession;
        }
        if (HistoryPattern().IsMatch(text))
        {
            return RelationKind.History;
        }
        if (ConsolePattern().IsMatch(text))
        {
            return RelationKind.Console;
        }
        return CluePattern().IsMatch(text) ? RelationKind.Hint : RelationKind.Unknown;
    }

    /// <summary>Comparable login: authority and UPN suffix removed, lower case; empty when unusable.</summary>
    public static string LoginKey(string? login)
    {
        var value = (login ?? "").Trim();
        var slash = value.LastIndexOf('\\');
        if (slash >= 0)
        {
            value = value[(slash + 1)..];
        }
        var at = value.IndexOf('@', StringComparison.Ordinal);
        if (at >= 0)
        {
            value = value[..at];
        }
        return value.Trim().ToLowerInvariant();
    }

    /// <summary>Comparable workstation name: first DNS label, no trailing « $ », lower case; empty when unusable.</summary>
    public static string ComputerKey(string? computer)
    {
        var value = (computer ?? "").Trim();
        if (value.EndsWith('$'))
        {
            value = value[..^1];
        }
        var dot = value.IndexOf('.', StringComparison.Ordinal);
        if (dot >= 0)
        {
            value = value[..dot];
        }
        return value.Trim().ToLowerInvariant();
    }

    /// <summary>Kind in the stable lower camel case used by keys, journals and the contract (« assignment »).</summary>
    public static string KindName(RelationKind kind) => JsonNamingPolicy.CamelCase.ConvertName(kind.ToString());

    /// <summary>
    /// Identifier of a relation for journals and storage: one user, one workstation, one nature of proof. Equality uses
    /// <see cref="Same"/>, because a legacy row without GUID and the same row with GUID must not become two relations.
    /// </summary>
    public static string Key(StoredRelation relation)
    {
        ArgumentNullException.ThrowIfNull(relation);
        var user = relation.UserGuid is Guid u ? u.ToString("D") : "login:" + LoginKey(relation.UserLogin);
        var computer = relation.ComputerGuid is Guid c ? c.ToString("D") : "name:" + ComputerKey(relation.Computer);
        return user + "|" + computer + "|" + KindName(relation.Kind);
    }

    /// <summary>
    /// Same user, same workstation, same nature of proof. A GUID known on both sides decides (a renamed account stays the
    /// same relation, a recreated object does not); otherwise the normalized names decide.
    /// </summary>
    public static bool Same(StoredRelation? left, StoredRelation? right)
    {
        if (left is null || right is null || left.Kind != right.Kind)
        {
            return false;
        }
        if (left.UserGuid is Guid lu && right.UserGuid is Guid ru)
        {
            if (lu != ru)
            {
                return false;
            }
        }
        else
        {
            var name = LoginKey(left.UserLogin);
            if (name.Length == 0 || name != LoginKey(right.UserLogin))
            {
                return false;
            }
        }
        if (left.ComputerGuid is Guid lc && right.ComputerGuid is Guid rc)
        {
            return lc == rc;
        }
        var computer = ComputerKey(left.Computer);
        return computer.Length > 0 && computer == ComputerKey(right.Computer);
    }

    /// <summary>
    /// Fingerprint of an association (Domenia 1 Get-DomeniaLinkFingerprint): SHA-256 of its canonical form, every stored
    /// field included. A change made elsewhere changes it: the write circuit refuses to remove or replace a row whose
    /// fingerprint is not the one planned (optimistic control, Domenia 1 REL-012).
    /// </summary>
    public static string Fingerprint(StoredRelation relation)
    {
        ArgumentNullException.ThrowIfNull(relation);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("format", "domenia.relation");
            writer.WriteNumber("version", 1);
            writer.WriteString("userLogin", relation.UserLogin);
            writer.WriteString("userGuid", relation.UserGuid?.ToString("D"));
            writer.WriteString("userDn", relation.UserDn);
            writer.WriteString("computer", relation.Computer);
            writer.WriteString("computerGuid", relation.ComputerGuid?.ToString("D"));
            writer.WriteString("computerDn", relation.ComputerDn);
            writer.WriteString("kind", KindName(relation.Kind));
            writer.WriteString("source", relation.Source);
            writer.WriteString("when", relation.When?.UtcDateTime.ToString("o", CultureInfo.InvariantCulture));
            writer.WriteString("details", relation.Details);
            writer.WriteBoolean("verifiedInAd", relation.VerifiedInAd);
            writer.WriteString("declarant", relation.Declarant);
            writer.WriteString("batchId", relation.BatchId);
            writer.WriteEndObject();
        }
        return Convert.ToHexStringLower(SHA256.HashData(buffer.ToArray()));
    }

    /// <summary>
    /// How an incoming relation joins the stored ones (Domenia 1 Resolve-DomeniaRelationUpsert): the same relation is
    /// refreshed (date and detail), anything else is added next to the existing ones. A declared assignment is never replaced
    /// by an observation: they are different relations.
    /// </summary>
    public static (bool Refresh, StoredRelation? Existing, string Reason) Upsert(IEnumerable<StoredRelation> existing, StoredRelation incoming)
    {
        ArgumentNullException.ThrowIfNull(existing);
        ArgumentNullException.ThrowIfNull(incoming);
        foreach (var relation in existing)
        {
            if (Same(relation, incoming))
            {
                return (true, relation, "Même relation, même nature" + C + "date et détail mis à jour.");
            }
        }
        return (false, null, "Nouvelle relation ajoutée sans retirer les relations existantes.");
    }

    /// <summary>
    /// The relation shown first: a declared assignment, otherwise the most recent relation (Domenia 1
    /// Select-DomeniaPrimaryRelation). Null when there is none.
    /// </summary>
    public static StoredRelation? Primary(IEnumerable<StoredRelation> relations)
    {
        ArgumentNullException.ThrowIfNull(relations);
        StoredRelation? best = null;
        foreach (var relation in relations)
        {
            if (best is null)
            {
                best = relation;
                continue;
            }
            var declared = relation.Kind == RelationKind.Assignment;
            var bestDeclared = best.Kind == RelationKind.Assignment;
            if (declared && !bestDeclared)
            {
                best = relation;
                continue;
            }
            if (declared != bestDeclared)
            {
                continue;
            }
            if (relation.When is DateTimeOffset when && (best.When is null || when > best.When))
            {
                best = relation;
            }
        }
        return best;
    }

    // ------------------------------------------------------------------ explainable qualification (D043)

    /// <summary>Badge of a kind with the rule that produced it; « Contradictoire » wins when sources disagree. No percentage.</summary>
    public static RelationBadgeInfo BadgeOf(RelationKind kind, bool contradicted = false)
    {
        if (contradicted)
        {
            return new RelationBadgeInfo(RelationBadge.Contradictory, "Contradictoire",
                "Des sources différentes désignent des comptes différents pour ce poste. Aucune fusion automatique.", Tone.Alert);
        }
        return kind switch
        {
            RelationKind.Assignment => new RelationBadgeInfo(RelationBadge.Declared, "Déclaré", "Association déclarée par un opérateur dans Domenia.", Tone.Ok),
            RelationKind.Console => new RelationBadgeInfo(RelationBadge.Observed, "Observé",
                "Session console lue sur le poste à la date indiquée. Une observation ne vaut pas affectation.", Tone.Info),
            RelationKind.RemoteSession => new RelationBadgeInfo(RelationBadge.Observed, "Observé",
                "Session distante lue sur le poste à la date indiquée. Une observation ne vaut pas affectation.", Tone.Info),
            RelationKind.History => new RelationBadgeInfo(RelationBadge.History, "Historique",
                "Ouverture de session ancienne relevée dans un journal ou un profil. Historique, pas présence actuelle.", Tone.Off),
            RelationKind.Imported => new RelationBadgeInfo(RelationBadge.Imported, "Importé",
                "Ligne reprise d’un fichier importé. Exactitude dépendante du fichier source.", Tone.Info),
            RelationKind.Hint => new RelationBadgeInfo(RelationBadge.Hint, "Indice",
                "Attribut AD ou inventaire qui suggère un lien, sans observation de session.", Tone.Off),
            _ => new RelationBadgeInfo(RelationBadge.ToCheck, "À vérifier", "Origine non reconnue" + C + "à vérifier avant de s’y fier.", Tone.Warn),
        };
    }

    /// <summary>Display label of a badge (the internal key stays stable for filters, tests and journals).</summary>
    public static string BadgeLabel(RelationBadge badge) => badge switch
    {
        RelationBadge.Declared => "Déclaré",
        RelationBadge.Observed => "Observé",
        RelationBadge.History => "Historique",
        RelationBadge.Imported => "Importé",
        RelationBadge.Hint => "Indice",
        RelationBadge.Contradictory => "Contradictoire",
        _ => "À vérifier",
    };

    /// <summary>Tone of a badge.</summary>
    public static Tone BadgeTone(RelationBadge badge) => badge switch
    {
        RelationBadge.Declared => Tone.Ok,
        RelationBadge.Observed => Tone.Info,
        RelationBadge.Imported => Tone.Info,
        RelationBadge.Contradictory => Tone.Alert,
        RelationBadge.ToCheck => Tone.Warn,
        _ => Tone.Off,
    };

    /// <summary>Phrase of a kind in a one-line summary (« console observée »).</summary>
    public static string Phrase(RelationKind kind) => kind switch
    {
        RelationKind.Assignment => "affectation déclarée",
        RelationKind.Console => "console observée",
        RelationKind.RemoteSession => "session à distance observée",
        RelationKind.History => "ouverture de session relevée",
        RelationKind.Imported => "association importée",
        RelationKind.Hint => "indice relevé",
        _ => "origine à vérifier",
    };

    /// <summary>Strength of a badge in the graph and the primary choice: declared first, then observed, imported, history, clues.</summary>
    public static int Strength(RelationBadge badge) => badge switch
    {
        RelationBadge.Contradictory => 6,
        RelationBadge.Declared => 5,
        RelationBadge.Observed => 4,
        RelationBadge.Imported => 3,
        RelationBadge.History => 2,
        RelationBadge.Hint => 1,
        _ => 0,
    };

    /// <summary>
    /// Workstations for which a declared assignment and an observed session designate different accounts (Domenia 1
    /// Get-DomeniaLinkConflicts). History never contradicts an assignment; nothing is merged or removed. Returns the keys of
    /// the relations involved, grouped by workstation.
    /// </summary>
    public static ImmutableArray<RelationConflict> Conflicts(IEnumerable<StoredRelation> relations)
    {
        ArgumentNullException.ThrowIfNull(relations);
        var groups = new Dictionary<string, List<StoredRelation>>(StringComparer.Ordinal);
        foreach (var relation in relations)
        {
            var key = relation.ComputerGuid is Guid g ? g.ToString("D") : "name:" + ComputerKey(relation.Computer);
            if (key == "name:")
            {
                continue;
            }
            if (!groups.TryGetValue(key, out var list))
            {
                list = [];
                groups.Add(key, list);
            }
            list.Add(relation);
        }
        var result = ImmutableArray.CreateBuilder<RelationConflict>();
        foreach (var (_, items) in groups.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            var declared = items.Where(r => r.Kind == RelationKind.Assignment).ToList();
            var observed = items.Where(r => r.Kind is RelationKind.Console or RelationKind.RemoteSession).ToList();
            if (declared.Count == 0 || observed.Count == 0)
            {
                continue;
            }
            var owners = declared.Select(r => LoginKey(r.UserLogin)).ToHashSet(StringComparer.Ordinal);
            var others = observed.Where(r => !owners.Contains(LoginKey(r.UserLogin))).ToList();
            if (others.Count == 0)
            {
                continue;
            }
            result.Add(new RelationConflict(
                items[0].Computer,
                string.Join(", ", declared.Select(r => r.UserLogin).Distinct(StringComparer.OrdinalIgnoreCase)),
                string.Join(", ", others.Select(r => r.UserLogin).Distinct(StringComparer.OrdinalIgnoreCase)),
                "Affectation déclarée et session observée désignent des comptes différents. Les deux sont conservées.",
                [.. declared.Concat(others).Select(Key)]));
        }
        return result.ToImmutable();
    }

    // ------------------------------------------------------------------ dates (CO-29, TRV-091)

    /// <summary>Local display of a relation date: « 08/10 09:15 » this year, « 08/10/2025 09:15 » another year, null without date.</summary>
    public static string? WhenText(DateTimeOffset? when, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (when is not DateTimeOffset at)
        {
            return null;
        }
        var local = TimeZoneInfo.ConvertTime(at, zone);
        var current = TimeZoneInfo.ConvertTime(now, zone);
        var format = local.Year == current.Year ? "dd'/'MM HH':'mm" : "dd'/'MM'/'yyyy HH':'mm";
        return local.ToString(format, CultureInfo.InvariantCulture);
    }

    /// <summary>« le 08/10 à 09:15 » (year when it is not the current one), for sentences.</summary>
    public static string WhenPhrase(DateTimeOffset when, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(when, zone);
        var current = TimeZoneInfo.ConvertTime(now, zone);
        var day = local.ToString(local.Year == current.Year ? "dd'/'MM" : "dd'/'MM'/'yyyy", CultureInfo.InvariantCulture);
        return "le " + day + " à " + local.ToString("HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Reads a stored date (Domenia 1 ConvertTo-DomeniaRelationUtcDate): ISO 8601 with offset or « Z » as UTC; a date without
    /// offset was written in local time by older versions and is read in <paramref name="zone"/>; anything else has no date.
    /// </summary>
    public static DateTimeOffset? ParseStoredWhen(string? text, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var value = (text ?? "").Trim();
        if (value.Length == 0)
        {
            return null;
        }
        if (OffsetPattern().IsMatch(value) && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var withOffset))
        {
            return withOffset.ToUniversalTime();
        }
        if (DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var local))
        {
            var unspecified = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
            if (zone.IsInvalidTime(unspecified) || zone.IsAmbiguousTime(unspecified)) { return null; }
            return new DateTimeOffset(unspecified, zone.GetUtcOffset(unspecified)).ToUniversalTime();
        }
        return null;
    }

    // ------------------------------------------------------------------ synthesis of a subject (point 107)

    /// <summary>
    /// Three separate statements for one user or workstation, each with origin and date: the declared assignment, the last
    /// observed session and the history, plus the number of other clues. An observation never becomes an assignment.
    /// </summary>
    public static RelationOverviewText Overview(IReadOnlyCollection<StoredRelation> relations, RelationSubjectKind subject, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(relations);
        ArgumentNullException.ThrowIfNull(zone);
        var declared = relations.Where(r => r.Kind == RelationKind.Assignment).ToList();
        var observed = relations.Where(r => r.Kind is RelationKind.Console or RelationKind.RemoteSession).ToList();
        var history = relations.Where(r => r.Kind == RelationKind.History).ToList();
        var clues = relations.Count - declared.Count - observed.Count - history.Count;
        string Describe(StoredRelation relation)
        {
            var party = subject == RelationSubjectKind.Computer ? relation.UserLogin : relation.Computer;
            if (string.IsNullOrWhiteSpace(party))
            {
                party = "non renseigné";
            }
            var text = party + " · " + (WhenText(relation.When, now, zone) ?? "date inconnue");
            var source = Flat(relation.Source, 60);
            return source.Length == 0 ? text : text + " · source" + C + source;
        }
        static StoredRelation Latest(List<StoredRelation> list) =>
            list.Aggregate((best, item) => item.When is DateTimeOffset w && (best.When is null || w > best.When) ? item : best);

        var lines = ImmutableArray.CreateBuilder<RelationStatement>();
        var declaredText = declared.Count == 0 ? "Aucune affectation déclarée" : Describe(Latest(declared));
        if (declared.Count > 1)
        {
            declaredText += " (" + FrenchText.Count(declared.Count, "affectation déclarée", "affectations déclarées") + ")";
        }
        lines.Add(Statement("Affectation déclarée", declaredText, RelationBadge.Declared));
        lines.Add(Statement("Dernière session observée", observed.Count == 0 ? "Aucune session observée en mémoire" : Describe(Latest(observed)), RelationBadge.Observed));
        lines.Add(Statement("Historique", history.Count == 0
            ? "Aucune ouverture de session ancienne relevée"
            : FrenchText.Count(history.Count, "relevé", "relevés") + ", le plus récent" + C + Describe(Latest(history)), RelationBadge.History));
        if (clues > 0)
        {
            lines.Add(Statement("Autres indices", FrenchText.Count(clues, "indice ou ligne importée", "indices ou lignes importées") + ", à confirmer", RelationBadge.Hint));
        }
        var all = lines.ToImmutable();
        return new RelationOverviewText(all, declared.Count, observed.Count, history.Count, clues, string.Join('\n', all.Select(l => l.Fact + C + l.Value)));
    }

    private static RelationStatement Statement(string fact, string value, RelationBadge badge) =>
        new(fact, value, badge, BadgeLabel(badge), BadgeTone(badge));

    /// <summary>
    /// The association of a workstation on one line (Domenia 1 Get-DomeniaLinkSummaryText, UI-17): « Camille Martin ·
    /// console observée le 08/10 à 08:15 », with the identity note of a legacy link that cannot be checked.
    /// </summary>
    public static (bool HasLink, string Text, string Detail, RelationBadgeInfo? Badge) Summary(StoredRelation? link, string? displayName, DateTimeOffset now, TimeZoneInfo zone, bool probing = false, bool identityUnproven = false)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (link is null)
        {
            return probing
                ? (false, "Détection de l’utilisateur en cours…", "Le poste est interrogé" + " ; la ligne se remplit à la réponse.", null)
                : (false, "Aucun utilisateur associé", "Aucune association en mémoire locale pour ce poste. « Détecter à nouveau » interroge le poste.", null);
        }
        var display = string.IsNullOrWhiteSpace(displayName) ? link.UserLogin : displayName!;
        if (string.IsNullOrWhiteSpace(display))
        {
            display = "Compte non nommé";
        }
        var badge = BadgeOf(link.Kind);
        var phrase = Phrase(link.Kind);
        if (link.When is DateTimeOffset when)
        {
            phrase += " " + WhenPhrase(when, now, zone);
        }
        var detail = badge.Rule;
        if (!string.IsNullOrWhiteSpace(link.UserLogin))
        {
            detail = "Compte " + link.UserLogin + ". " + detail;
        }
        var source = Flat(link.Source, 80);
        if (source.Length > 0)
        {
            detail += " Source" + C + source + ".";
        }
        var text = display + " · " + phrase;
        if (identityUnproven)
        {
            text += " · identité non vérifiable";
            detail += " Association sans GUID enregistré" + C + "identité non vérifiable.";
        }
        return (true, text, detail, badge);
    }

    // ------------------------------------------------------------------ identity across renames and recycled names (point 9)

    /// <summary>
    /// Whether a link belongs to the object of <paramref name="guid"/>: the same GUID decides; another GUID is a recreated or
    /// recycled object; without stored GUID the link is ambiguous unless it predates the creation of the object.
    /// </summary>
    public static (RelationIdentityMatch Match, string Reason) Identity(StoredRelation link, RelationSubjectKind kind, Guid? guid, DateTimeOffset? created)
    {
        ArgumentNullException.ThrowIfNull(link);
        var stored = kind == RelationSubjectKind.Computer ? link.ComputerGuid : link.UserGuid;
        if (guid is Guid expected && stored is Guid known)
        {
            return expected == known
                ? (RelationIdentityMatch.Same, "GUID identique" + C + "même objet, même après renommage ou déplacement.")
                : (RelationIdentityMatch.Different, "Même nom, autre GUID" + C + "objet recréé ou nom réattribué, historique non repris.");
        }
        if (created is DateTimeOffset birth && link.When is DateTimeOffset when && when < birth)
        {
            return (RelationIdentityMatch.Different, "Association antérieure à la création de cet objet" + C + "nom réattribué, historique non repris.");
        }
        return (RelationIdentityMatch.Unknown, "Association sans GUID enregistré" + C + "identité non vérifiable.");
    }

    /// <summary>True when a record keyed by name was written before the current object of that name existed.</summary>
    public static bool PredatesObject(DateTimeOffset? recorded, DateTimeOffset? created) =>
        recorded is DateTimeOffset r && created is DateTimeOffset c && r < c;

    /// <summary>Declared and imported sources: never removed by an automatic check, never replaced by a detection.</summary>
    public static bool IsProtectedSource(string? source) =>
        source is not null && ProtectedSources.Any(p => string.Equals(p, source.Trim(), StringComparison.OrdinalIgnoreCase));

    /// <summary>Why a stored association is listed as orphan; an absent name is a deleted or renamed object, never a proven deletion.</summary>
    public static string OrphanReason(bool userExists, bool computerExists) => (userExists, computerExists) switch
    {
        (false, false) => "Compte et poste absents d’Active Directory (supprimés ou renommés).",
        (false, true) => "Compte absent d’Active Directory (supprimé ou renommé).",
        (true, false) => "Poste absent d’Active Directory (supprimé ou renommé).",
        _ => "",
    };

    /// <summary>
    /// Text filter (user, workstation, source, details, label) and badge chips of « Toutes les associations » (Domenia 1
    /// Test-DomeniaRelationMatchesFilter), accent and case insensitive. A row keeps its nature: the chip « Contradictoire »
    /// selects the rows in contradiction, whatever their nature; several chips add up.
    /// </summary>
    public static bool MatchesFilter(RelationRow row, string? text, IReadOnlyCollection<RelationBadge>? badges)
    {
        ArgumentNullException.ThrowIfNull(row);
        if (badges is { Count: > 0 } && !badges.Contains(row.Badge) && !(row.Contradicted && badges.Contains(RelationBadge.Contradictory)))
        {
            return false;
        }
        var needle = FrenchText.Fold((text ?? "").Trim());
        if (needle.Length == 0)
        {
            return true;
        }
        return new[] { row.UserLogin, row.UserName, row.Computer, row.Source, row.Details, row.BadgeLabel }
            .Any(value => value is not null && FrenchText.Fold(value).Contains(needle, StringComparison.Ordinal));
    }

    /// <summary>Label of the restore button (Domenia 1 CO-28): « Restaurer jdupont → PC01 », 48 characters at most.</summary>
    public static string RestoreLabel(string? userLogin, string? computer)
    {
        if (string.IsNullOrWhiteSpace(userLogin) || string.IsNullOrWhiteSpace(computer))
        {
            return "Restaurer la suppression";
        }
        var label = "Restaurer " + userLogin + Arrow + computer;
        return label.Length > 48 ? label[..47] + "…" : label;
    }

    /// <summary>Label of a journal action.</summary>
    public static (string Label, Tone Tone) JournalAction(RelationJournalAction action) => action switch
    {
        RelationJournalAction.Added => ("Ajoutée", Tone.Ok),
        RelationJournalAction.Removed => ("Retirée", Tone.Warn),
        RelationJournalAction.Restored => ("Restaurée", Tone.Info),
        RelationJournalAction.Refreshed => ("Mise à jour", Tone.Off),
        _ => ("Conflit", Tone.Alert),
    };

    /// <summary>
    /// The most recent local removal not yet restored (Domenia 1 Get-DomeniaRelationsRestorableEntry): a restoration names
    /// the removal it put back in its note.
    /// </summary>
    public static ImmutableArray<RelationJournalRecord> Restorable(IReadOnlyList<RelationJournalRecord> journal)
    {
        ArgumentNullException.ThrowIfNull(journal);
        var restored = journal.Where(e => e.Action == RelationJournalAction.Restored && e.Note is not null).Select(e => e.Note!).ToHashSet(StringComparer.Ordinal);
        return [.. journal.Where(e => e.Action == RelationJournalAction.Removed && !restored.Contains(e.Id)).OrderByDescending(e => e.At).ThenByDescending(e => e.Id, StringComparer.Ordinal)];
    }

    // ------------------------------------------------------------------ both directions (D041) and the subject (D044)

    /// <summary>Labels that follow the subject (Domenia 1 Get-DomeniaRelationDirection).</summary>
    public static RelationDirection Direction(RelationSubjectKind subject) => subject == RelationSubjectKind.User
        ? new RelationDirection("poste", "Associer ce poste", "Rechercher un poste", "Détecter les postes", "Aucun poste associé à cet utilisateur.")
        : new RelationDirection("utilisateur", "Associer cet utilisateur", "Rechercher un utilisateur", "Lire la session de ce poste", "Aucun utilisateur associé à ce poste.");

    /// <summary>
    /// While a target is searched or awaits its confirmation, a new selection does not replace the subject (Domenia 1
    /// Resolve-DomeniaRelationSubjectChange); the reason is shown.
    /// </summary>
    public static (bool Change, string Reason) SubjectChange(Guid? current, Guid? next, bool nextIsRelationObject, bool targetSearchActive, bool pendingAssociation)
    {
        if (next is null)
        {
            return (false, "Aucune sélection.");
        }
        if (!nextIsRelationObject)
        {
            return (false, "Seuls un utilisateur ou un poste portent des relations.");
        }
        if (current is null)
        {
            return (true, "");
        }
        if (current == next)
        {
            return (false, "Même sujet.");
        }
        if (pendingAssociation)
        {
            return (false, "Une association attend sa confirmation" + C + "confirmez ou annulez avant de changer de sujet.");
        }
        return targetSearchActive ? (false, "Recherche d’une cible en cours" + C + "le sujet de départ est conservé.") : (true, "");
    }

    // ------------------------------------------------------------------ in-page association (D045)

    /// <summary>
    /// Idle → Searching → Candidate → Pending → Verifying → Saved or Failed (Domenia 1 Step-DomeniaAssociationState): every
    /// refused step is explained in one French sentence, the internal names stay in the journal.
    /// </summary>
    public static (RelationAssociationState State, bool Accepted, string Reason) Step(RelationAssociationState state, RelationAssociationEvent e)
    {
        RelationAssociationState? next = e switch
        {
            RelationAssociationEvent.Reset or RelationAssociationEvent.SubjectChanged => RelationAssociationState.Idle,
            RelationAssociationEvent.Cancel when state is RelationAssociationState.Searching or RelationAssociationState.Candidate
                or RelationAssociationState.Pending or RelationAssociationState.Verifying or RelationAssociationState.Failed => RelationAssociationState.Idle,
            RelationAssociationEvent.Search when state is RelationAssociationState.Idle or RelationAssociationState.Candidate
                or RelationAssociationState.Failed or RelationAssociationState.Saved => RelationAssociationState.Searching,
            RelationAssociationEvent.Results when state == RelationAssociationState.Searching => RelationAssociationState.Candidate,
            RelationAssociationEvent.Pick when state is RelationAssociationState.Candidate or RelationAssociationState.Saved
                or RelationAssociationState.Failed => RelationAssociationState.Pending,
            RelationAssociationEvent.Confirm when state == RelationAssociationState.Pending => RelationAssociationState.Verifying,
            RelationAssociationEvent.Verified when state == RelationAssociationState.Verifying => RelationAssociationState.Saved,
            RelationAssociationEvent.VerifyFailed when state == RelationAssociationState.Verifying => RelationAssociationState.Failed,
            _ => null,
        };
        return next is RelationAssociationState accepted ? (accepted, true, "") : (state, false, Refusal(state, e));
    }

    /// <summary>One French sentence per refused step of the association (Domenia 1 Get-DomeniaAssociationRefusal, CO-30).</summary>
    public static string Refusal(RelationAssociationState state, RelationAssociationEvent e) => e switch
    {
        RelationAssociationEvent.Pick => state switch
        {
            RelationAssociationState.Pending => "Une association attend déjà sa confirmation" + C + "confirmez-la ou annulez-la avant d’en choisir une autre.",
            RelationAssociationState.Verifying => "Vérification en cours" + C + "attendez son résultat avant de choisir une autre ligne.",
            RelationAssociationState.Searching => "Recherche en cours" + C + "attendez les résultats avant de choisir une ligne.",
            _ => "Cette liste n’est plus active (détection arrêtée, interrompue ou aucune lancée)" + C + "relancez la détection ou la recherche, puis choisissez une ligne.",
        },
        RelationAssociationEvent.Confirm => state == RelationAssociationState.Verifying
            ? "Vérification déjà en cours" + C + "attendez son résultat."
            : "Confirmation impossible" + C + "choisissez d’abord une ligne dans les résultats.",
        RelationAssociationEvent.Search when state is RelationAssociationState.Pending or RelationAssociationState.Verifying =>
            "Une association attend sa confirmation" + C + "confirmez-la ou annulez-la avant une nouvelle recherche.",
        RelationAssociationEvent.Search when state == RelationAssociationState.Searching =>
            "Une recherche est déjà en cours" + C + "attendez son résultat ou arrêtez-la.",
        RelationAssociationEvent.Results => "Résultats ignorés" + C + "aucune recherche n’est en cours.",
        RelationAssociationEvent.Verified or RelationAssociationEvent.VerifyFailed => "Résultat de vérification ignoré" + C + "aucune vérification n’est en cours.",
        RelationAssociationEvent.Cancel => "Rien à annuler" + C + "aucune association en cours.",
        _ => "Action impossible à cette étape de l’association.",
    };

    // ------------------------------------------------------------------ exact identity of an observed account (D049)

    /// <summary>Reads « DOMAINE\compte », « compte@domaine », « .\compte » and a bare login.</summary>
    public static (string Authority, string Login, string Form) ParseAccount(string? text)
    {
        var value = (text ?? "").Trim();
        if (value.Length == 0)
        {
            return ("", "", "empty");
        }
        var slash = value.IndexOf('\\', StringComparison.Ordinal);
        if (slash > 0 && slash == value.LastIndexOf('\\') && slash < value.Length - 1)
        {
            return (value[..slash], value[(slash + 1)..], "downLevel");
        }
        var at = value.IndexOf('@', StringComparison.Ordinal);
        if (at > 0 && at == value.LastIndexOf('@') && at < value.Length - 1)
        {
            return (value[(at + 1)..], value[..at], "upn");
        }
        return ("", value, "bare");
    }

    /// <summary>
    /// Compares an account read on <paramref name="machine"/> with the AD account searched (Domenia 1
    /// Test-DomeniaAccountIdentityMatch): a local account or a namesake from another domain is never the AD account.
    /// </summary>
    public static (bool Match, bool Certain, string Reason) MatchAccount(RelationAccountTarget target, string? observedAccount, string? observedSid, string? machine)
    {
        ArgumentNullException.ThrowIfNull(target);
        var targetSid = (target.Sid ?? "").Trim();
        var seenSid = (observedSid ?? "").Trim();
        if (targetSid.Length > 0 && seenSid.Length > 0)
        {
            return string.Equals(targetSid, seenSid, StringComparison.OrdinalIgnoreCase)
                ? (true, true, "SID identique.")
                : (false, true, "SID différent" + C + "autre compte.");
        }
        var identity = ParseAccount(observedAccount);
        if (identity.Login.Length == 0 || string.IsNullOrWhiteSpace(target.Login))
        {
            return (false, false, "Compte observé ou cible absent.");
        }
        if (identity.Form == "bare")
        {
            return (false, false, "Nom non qualifié" + C + "domaine du compte observé inconnu.");
        }
        var host = (machine ?? "").Split('.')[0];
        if (identity.Authority == "." || (host.Length > 0 && string.Equals(identity.Authority, host, StringComparison.OrdinalIgnoreCase)))
        {
            return (false, true, "Compte local du poste, pas un compte du domaine.");
        }
        var sameDomain = (!string.IsNullOrEmpty(target.NetbiosDomain) && string.Equals(identity.Authority, target.NetbiosDomain, StringComparison.OrdinalIgnoreCase))
            || (!string.IsNullOrEmpty(target.DnsDomain) && string.Equals(identity.Authority, target.DnsDomain, StringComparison.OrdinalIgnoreCase));
        // The explicit UPN names the account whatever its prefix: tested before the login.
        if (identity.Form == "upn" && !string.IsNullOrEmpty(target.Upn) && string.Equals(target.Upn, (observedAccount ?? "").Trim(), StringComparison.OrdinalIgnoreCase))
        {
            return (true, false, "UPN identique" + C + "à confirmer par le SID.");
        }
        if (!sameDomain)
        {
            return (false, true, "Compte d’un autre domaine ou d’une autre autorité" + C + identity.Authority + ".");
        }
        return !string.Equals(identity.Login, target.Login, StringComparison.OrdinalIgnoreCase)
            ? (false, true, "Identifiant différent.")
            : (true, false, "Domaine et identifiant identiques ; SID non comparé.");
    }

    // ------------------------------------------------------------------ candidates from several proofs (D046)

    /// <summary>
    /// Groups every source by exact object identity (Domenia 1 Merge-DomeniaRelationCandidates): a candidate that only has an
    /// address or a partial name is listed with its reason but cannot be associated.
    /// </summary>
    public static ImmutableArray<RelationMergedCandidate> MergeCandidates(IEnumerable<RelationProof> proofs)
    {
        ArgumentNullException.ThrowIfNull(proofs);
        var order = new List<string>();
        var byKey = new Dictionary<string, (string? Guid, string Computer, string? Dn, List<string> Origins, List<string> Reasons)>(StringComparer.Ordinal);
        foreach (var proof in proofs)
        {
            var key = proof.Guid is Guid g ? g.ToString("D") : "unverified:" + proof.Computer.ToLowerInvariant() + "|" + (proof.Address ?? "");
            if (key == "unverified:|")
            {
                continue;
            }
            if (!byKey.TryGetValue(key, out var entry))
            {
                entry = (proof.Guid?.ToString("D"), proof.Computer, proof.Dn, [], []);
                byKey.Add(key, entry);
                order.Add(key);
            }
            if (!entry.Origins.Contains(proof.Origin, StringComparer.Ordinal))
            {
                entry.Origins.Add(proof.Origin);
            }
            if (proof.Reason.Length > 0 && !entry.Reasons.Contains(proof.Reason, StringComparer.Ordinal))
            {
                entry.Reasons.Add(proof.Reason);
            }
            if (entry.Dn is null && proof.Dn is not null)
            {
                byKey[key] = entry with { Dn = proof.Dn };
            }
        }
        return
        [
            .. order.Select(key =>
            {
                var c = byKey[key];
                var associable = c.Guid is not null;
                return new RelationMergedCandidate(c.Guid, c.Computer, c.Dn, string.Join(" + ", c.Origins), string.Join(" ", c.Reasons), associable,
                    associable ? null : "Objet AD non identifié par son GUID" + C + "une adresse IP ou un nom partiel ne suffit pas à associer.");
            }),
        ];
    }

    // ------------------------------------------------------------------ perimeter before any probe (D047) and counters (D048)

    /// <summary>
    /// The preview shown before any probe (Domenia 1 Get-DomeniaDetectionScopePlan). The requested perimeter is never replaced:
    /// a domain root is refused; when it yields nothing the plan is refused with the reason. Candidates without GUID or domain
    /// are left out; duplicates count once.
    /// </summary>
    public static RelationDetectionPlan DetectionPlan(string scope, string? ouDn, string domainDn, IEnumerable<RelationPlanCandidate> candidates, int limit, string? id, DateTimeOffset? expiresAt)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(candidates);
        limit = Math.Clamp(limit, 1, 50);
        const string zero = "Zéro candidat signifie qu’aucune source n’en propose, pas que cet utilisateur n’a aucun poste.";
        var scopeLabel = ScopeLabel(scope, ouDn);
        if (scope == "ou" && (string.IsNullOrWhiteSpace(ouDn) || SameDn(ouDn!, domainDn)))
        {
            return new RelationDetectionPlan(null, false, scope, scopeLabel, ouDn, limit, 0, false, [], "",
                "Choisissez une OU explicite ; le domaine entier ne sera pas substitué.", zero, null);
        }
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var list = new List<RelationPlanTarget>();
        var eligible = 0;
        foreach (var candidate in candidates)
        {
            if (candidate.Guid is not Guid guid || string.IsNullOrWhiteSpace(candidate.Domain) || !seen.Add(candidate.Domain + "|" + guid.ToString("D")))
            {
                continue;
            }
            eligible++;
            if (list.Count < limit)
            {
                list.Add(new RelationPlanTarget(guid.ToString("D"), candidate.Computer, candidate.Dn, candidate.Source));
            }
        }
        if (list.Count == 0)
        {
            var reason = scope switch
            {
                "ou" => "Aucun poste lu dans cette OU. Lisez d’abord son contenu ou choisissez une autre OU.",
                "loaded" => "Aucune machine dans la liste chargée. Choisissez un autre périmètre.",
                "sweep" => "Aucun poste à relever dans l’OU de travail" + C + "tous ont un relevé récent ou ne se sont pas réauthentifiés depuis.",
                _ => "Aucun poste connu à vérifier. Choisissez un autre périmètre.",
            };
            return new RelationDetectionPlan(null, false, scope, scopeLabel, ouDn, limit, eligible, false, [], "", reason, zero, null);
        }
        var truncated = eligible > list.Count;
        var text = FrenchText.Count(list.Count, "poste à interroger", "postes à interroger") + " (" + scopeLabel + "), limite " + FrenchText.Integer(limit) + ".";
        if (truncated)
        {
            text += " Liste tronquée" + C + FrenchText.Count(eligible, "poste éligible", "postes éligibles") + ", seuls les " + FrenchText.Integer(limit) + " premiers seront lus.";
        }
        text += " Lecture de la console uniquement ; sessions RDP non lues. Aucun poste n’est contacté avant « Lancer la détection ».";
        return new RelationDetectionPlan(id, true, scope, scopeLabel, ouDn, limit, eligible, truncated, [.. list], text, "Périmètre à confirmer avant toute sonde.", zero, expiresAt);
    }

    /// <summary>Readable perimeter of a plan.</summary>
    public static string ScopeLabel(string scope, string? ouDn) => scope switch
    {
        "ou" => "OU " + (ouDn is null ? "non choisie" : FirstValue(ouDn)),
        "loaded" => "machines de la liste chargée",
        "sweep" => "relevé du parc de l’OU de travail",
        _ => "postes connus et candidats AD",
    };

    /// <summary>The list really probed stays inside the confirmed plan (a probe may stop early, never reach another workstation).</summary>
    public static bool WithinPlan(IEnumerable<string> planned, IEnumerable<string> probed)
    {
        ArgumentNullException.ThrowIfNull(planned);
        ArgumentNullException.ThrowIfNull(probed);
        var allowed = planned.ToHashSet(StringComparer.OrdinalIgnoreCase);
        return probed.All(allowed.Contains);
    }

    /// <summary>The list probed is exactly the list confirmed.</summary>
    public static bool MatchesPlan(IEnumerable<string> planned, IEnumerable<string> probed)
    {
        ArgumentNullException.ThrowIfNull(planned);
        ArgumentNullException.ThrowIfNull(probed);
        return planned.Select(p => p.ToLowerInvariant()).Order(StringComparer.Ordinal).SequenceEqual(probed.Select(p => p.ToLowerInvariant()).Order(StringComparer.Ordinal));
    }

    /// <summary>Counter of a console read status; unknown statuses are not counted (Domenia 1 ConvertTo-DomeniaDetectionOutcome).</summary>
    public static RelationProbeOutcome? Outcome(string? status) => (status ?? "").ToUpperInvariant() switch
    {
        "CONFIRME" => RelationProbeOutcome.Confirmed,
        "LU" => RelationProbeOutcome.NoSession,
        "REFUSE" or "AUTH_REJETEE" => RelationProbeOutcome.Refused,
        "DELAI" or "ERREUR" => RelationProbeOutcome.Unreachable,
        _ => null,
    };

    /// <summary>New counters for a plan of <paramref name="planned"/> workstations.</summary>
    public static RelationCounters NewCounters(int planned) => WithText(new RelationCounters(planned, 0, 0, 0, 0, 0, false, ""));

    /// <summary>Counters after one outcome (Domenia 1 Add-DomeniaDetectionOutcome).</summary>
    public static RelationCounters Count(RelationCounters counters, RelationProbeOutcome outcome)
    {
        ArgumentNullException.ThrowIfNull(counters);
        var next = outcome switch
        {
            RelationProbeOutcome.Stopped => counters with { Stopped = true },
            RelationProbeOutcome.Confirmed => counters with { Queried = counters.Queried + 1, Confirmed = counters.Confirmed + 1 },
            RelationProbeOutcome.NoSession => counters with { Queried = counters.Queried + 1, NoSession = counters.NoSession + 1 },
            RelationProbeOutcome.Refused => counters with { Queried = counters.Queried + 1, Refused = counters.Refused + 1 },
            _ => counters with { Queried = counters.Queried + 1, Unreachable = counters.Unreachable + 1 },
        };
        return WithText(next);
    }

    private static RelationCounters WithText(RelationCounters c)
    {
        var remaining = Math.Max(0, c.Planned - c.Queried);
        var text = FrenchText.Integer(c.Queried) + " interrogé" + (c.Queried > 1 ? "s" : "") + " sur " + FrenchText.Integer(c.Planned)
            + " · " + FrenchText.Count(c.Confirmed, "confirmé", "confirmés")
            + " · " + FrenchText.Count(c.Refused, "refusé", "refusés")
            + " · " + FrenchText.Count(c.Unreachable, "injoignable", "injoignables");
        if (c.Stopped)
        {
            text += " · arrêté" + C + "résultat partiel";
        }
        else if (remaining > 0)
        {
            text += " · " + FrenchText.Count(remaining, "restant", "restants");
        }
        else if (c.Refused + c.Unreachable > 0)
        {
            text += " · résultat partiel";
        }
        return c with { Text = text };
    }

    /// <summary>Label and tone of a status of the « Détail des tentatives » grid.</summary>
    public static (string Label, Tone Tone) AttemptStatus(string status) => status switch
    {
        "OK" => ("Réussi", Tone.Ok),
        "VIDE" => ("Aucun résultat", Tone.Off),
        "CONFIRME" => ("Confirmé", Tone.Ok),
        "LU" => ("Lu", Tone.Info),
        "A_REVOIR" => ("À revoir", Tone.Warn),
        "AUTH_REJETEE" => ("Identifiants rejetés", Tone.Alert),
        "REFUSE" => ("Accès refusé", Tone.Alert),
        "DELAI" => ("Délai dépassé", Tone.Warn),
        "ERREUR" => ("Erreur", Tone.Alert),
        "NON_DEMANDE" => ("Non demandé", Tone.Off),
        "NON_EFFECTUE" => ("Non effectué", Tone.Off),
        "IGNORE" => ("Ignoré", Tone.Off),
        "ARRETE" => ("Arrêté", Tone.Warn),
        _ => ("Non confirmé", Tone.Warn),
    };

    // ------------------------------------------------------------------ helpers

    /// <summary>Text on one line, at most <paramref name="max"/> characters (an ellipsis marks a cut).</summary>
    public static string Flat(string? text, int max)
    {
        var value = WhitespacePattern().Replace(text ?? "", " ").Trim();
        return value.Length <= max ? value : value[..(max - 1)] + "…";
    }

    /// <summary>Value of the first RDN of a DN (« PC-PAR-0042 »), or the text itself when it is not a DN.</summary>
    public static string FirstValue(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var parts = DistinguishedName.Parse(dn);
            return parts.Length > 0 ? parts[0].Value : dn;
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>Readable path of a DN from the domain (« example.local › Postes › Paris »), the object itself left out.</summary>
    public static string Path(string dn, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var parts = DistinguishedName.Parse(dn);
            var names = parts.Skip(1).Where(p => !string.Equals(p.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value).Reverse();
            return string.Join(FrenchText.PathSeparator, new[] { dnsName }.Concat(names));
        }
        catch (FormatException)
        {
            return dnsName;
        }
    }

    private static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    [GeneratedRegex("responsable|managedby", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex OwnerPattern();

    [GeneratedRegex("saisie manuelle|manual|manuel|declar|déclar|affect", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex AssignmentPattern();

    [GeneratedRegex("import|csv", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ImportPattern();

    [GeneratedRegex("rdp|wts|session distante|terminal", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex RemotePattern();

    [GeneratedRegex("historique|journal|event|4624|harvest|logonui|logon|profil|registre", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex HistoryPattern();

    [GeneratedRegex("console|cim|dcom|explorer|interactive|computersystem|quser|utilisateur courant|winrm", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ConsolePattern();

    [GeneratedRegex("description|kerberos|indice|attribut|inventaire|glpi|mention", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex CluePattern();

    [GeneratedRegex(@"(Z|[+-]\d{2}:?\d{2})$", RegexOptions.CultureInvariant)]
    private static partial Regex OffsetPattern();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespacePattern();
}

/// <summary>A workstation where a declared assignment and an observed session name different accounts.</summary>
public sealed record RelationConflict(string Computer, string Declared, string Observed, string Message, ImmutableArray<string> Keys);

/// <summary>Steps of the in-page association (Domenia 1 D045).</summary>
public enum RelationAssociationState
{
    Idle,
    Searching,
    Candidate,
    Pending,
    Verifying,
    Saved,
    Failed,
}

public enum RelationAssociationEvent
{
    Search,
    Results,
    Pick,
    Confirm,
    Verified,
    VerifyFailed,
    Cancel,
    SubjectChanged,
    Reset,
}

/// <summary>The AD account a detection looks for (login, NetBIOS and DNS names of its domain, SID, UPN).</summary>
public sealed record RelationAccountTarget(string Login, string? NetbiosDomain, string? DnsDomain, string? Sid, string? Upn);

/// <summary>One proof of a candidate: known association, observation, AD clue or inventory line.</summary>
public sealed record RelationProof(Guid? Guid, string Computer, string? Dn, string? Address, string Origin, string Reason);

public sealed record RelationMergedCandidate(string? Guid, string Computer, string? Dn, string Origins, string Why, bool Associable, string? Blocker);

/// <summary>A workstation that may enter a detection plan.</summary>
public sealed record RelationPlanCandidate(Guid? Guid, string Computer, string Dn, string Domain, string Source);

public enum RelationProbeOutcome
{
    Confirmed,
    NoSession,
    Refused,
    Unreachable,
    Stopped,
}
