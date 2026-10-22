using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Delegations of one object and the access estimate of a trustee (AUD-021, AUD-014, AUD-015; Domenia 1
/// ConvertTo-DomeniaDelegationView, ConvertTo-DomeniaAceView, Get-DomeniaAccessEstimate, Get-DomeniaAdRightCategories).
/// An entry is an observation of the list, never a verified capability. Pure.
/// </summary>
public static class AuditAclRules
{
    public const string ObservationLimit = "Une entrée observée n’est pas un droit effectif : groupes, refus, propriétaire et privilèges changent le résultat.";

    private const string Everyone = "S-1-1-0";
    private const string AuthenticatedUsers = "S-1-5-11";

    private sealed record Category(string Id, string Label, string[] Rights, Guid[] Guids, string[] PartialRights);

    private static readonly Category[] Categories =
    [
        new("full", "Contrôle total", ["GenericAll"], [], []),
        new("read", "Lire l’objet", ["GenericRead", "ReadProperty"], [], []),
        new("write", "Modifier des attributs", ["GenericWrite", "WriteProperty"], [], ["WriteProperty"]),
        new("reset", "Réinitialiser le mot de passe", ["ExtendedRight"], [new Guid("00299570-246d-11d0-a768-00aa006e0529")], []),
        new("members", "Modifier les membres d’un groupe", ["GenericWrite", "WriteProperty"], [new Guid("bf9679c0-0de6-11d0-a285-00aa003049e2"), new Guid("bc0ac240-79a9-11d0-9020-00c04fc2d4cf")], []),
        new("create", "Créer des objets enfants", ["CreateChild"], [], ["CreateChild"]),
        new("delete", "Supprimer l’objet", ["Delete", "DeleteTree"], [], []),
        new("dacl", "Modifier les autorisations", ["WriteDacl"], [], []),
        new("owner", "Changer le propriétaire", ["WriteOwner"], [], []),
    ];

    /// <summary>An inherit-only entry (Descendents, Children) is carried by the object for its children, not applied to it.</summary>
    public static bool AppliesToObject(AceRead ace)
    {
        ArgumentNullException.ThrowIfNull(ace);
        return ace.InheritanceType is "None" or "All" or "SelfAndChildren";
    }

    public static string ScopeLabel(string inheritanceType) => inheritanceType switch
    {
        "All" => "Cet objet et tous ses descendants",
        "Descendents" => "Descendants uniquement",
        "Children" => "Enfants directs uniquement",
        "SelfAndChildren" => "Cet objet et ses enfants directs",
        _ => "Cet objet uniquement",
    };

    /// <summary>Name of a trustee: the directory name read for a domain SID, else the well-known label, else the SID.</summary>
    public static string TrusteeName(string sid, IReadOnlyDictionary<string, string> names)
    {
        ArgumentNullException.ThrowIfNull(sid);
        ArgumentNullException.ThrowIfNull(names);
        var known = AuditText.WellKnownSidName(sid);
        if (names.TryGetValue(sid, out var resolved) && !string.IsNullOrEmpty(resolved) && (known is null || sid.StartsWith("S-1-5-21-", StringComparison.Ordinal)))
        {
            return resolved;
        }
        return known ?? sid;
    }

    private static string GuidText(Guid? guid, IReadOnlyDictionary<Guid, string> names) =>
        guid is not Guid g || g == Guid.Empty ? string.Empty : AuditText.GuidLabel(g) ?? (names.TryGetValue(g, out var n) ? n : g.ToString("D"));

    public static AuditAcl View(AclRead read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var rows = ImmutableArray.CreateBuilder<AuditAceRow>();
        for (var i = 0; i < read.Aces.Length; i++)
        {
            var ace = read.Aces[i];
            var rights = AuditText.RightNames(ace.Rights);
            string target;
            if (ace.ObjectType is Guid type && type != Guid.Empty)
            {
                target = GuidText(type, read.GuidNames);
            }
            else if (rights.Contains("ExtendedRight"))
            {
                target = "Tous les droits étendus";
            }
            else if (rights.Contains("WriteProperty") || rights.Contains("ReadProperty"))
            {
                target = "Toutes les propriétés";
            }
            else if (rights.Contains("CreateChild") || rights.Contains("DeleteChild"))
            {
                target = "Tous les types d’objets";
            }
            else
            {
                target = string.Empty;
            }
            var appliesTo = ace.InheritedObjectType is Guid inherited && inherited != Guid.Empty ? GuidText(inherited, read.GuidNames) : "Tous les objets";
            rows.Add(new AuditAceRow(
                i,
                TrusteeName(ace.Sid, read.SidNames),
                ace.Sid,
                ace.Allow,
                ace.Allow ? "Autorisation" : "Refus",
                AuditText.FormatRights(ace.Rights),
                target,
                appliesTo,
                ace.IsInherited ? "Héritée d’un conteneur parent" : "Posée sur cet objet",
                ScopeLabel(ace.InheritanceType),
                !ace.IsInherited,
                AppliesToObject(ace),
                AuditText.IsDomainAccountSid(ace.Sid),
                RiskOf(ace, rights)));
        }
        var all = rows.ToImmutable();
        var owner = read.OwnerSid is null ? null : TrusteeName(read.OwnerSid, read.SidNames);
        var explicitCount = all.Count(r => r.Explicit);
        var deny = all.Count(r => !r.Allow);
        var lines = new List<string>();
        switch (read.State)
        {
            case ReadState.Refused:
                lines.Add("Lecture de la liste de contrôle d’accès refusée : aucune délégation n’est affichée et aucune absence n’est déduite.");
                break;
            case ReadState.Read:
            case ReadState.Empty:
                lines.Add(FrenchText.Count(all.Length, "entrée", "entrées") + " : " + FrenchText.Integer(explicitCount) + " posée" + (explicitCount > 1 ? "s" : string.Empty)
                    + " sur l’objet, " + FrenchText.Integer(all.Length - explicitCount) + " héritée" + (all.Length - explicitCount > 1 ? "s" : string.Empty) + ", " + FrenchText.Integer(deny) + " refus.");
                if (owner is not null)
                {
                    lines.Add("Propriétaire : " + owner + " (droits implicites de lecture et de modification des autorisations).");
                }
                if (read.Protected)
                {
                    lines.Add("Héritage désactivé sur cet objet : seules ses entrées propres comptent.");
                }
                if (read.Truncated)
                {
                    lines.Add("Liste bornée à " + FrenchText.Integer(read.MaxAces) + " entrées sur " + FrenchText.Integer(read.Total) + ".");
                }
                if (!string.IsNullOrEmpty(read.SidNamesError))
                {
                    lines.Add("Noms de certains comptes non lus : leur SID est affiché.");
                }
                break;
            default:
                lines.Add("Liste de contrôle d’accès non lue : " + read.Message);
                break;
        }
        var trustees = all.GroupBy(r => r.Sid, StringComparer.OrdinalIgnoreCase)
            .Select(g => new AuditTrustee(g.Key, g.First().Trustee, g.Count(), g.First().DomainAccount))
            .OrderBy(t => FrenchText.Fold(t.Name), StringComparer.Ordinal)
            .ToImmutableArray();
        var stateLabel = read.State switch
        {
            ReadState.Read or ReadState.Empty => "Lue",
            ReadState.Refused => "Refusée",
            _ => "Non lue",
        };
        return new AuditAcl(read.Dn, read.State, stateLabel, owner, read.OwnerSid, read.Protected, read.Total, read.Truncated, read.MaxAces,
            explicitCount, all.Length - explicitCount, deny, all, trustees, string.Join("\n", lines), ObservationLimit, read.Controller, read.ReadAt);
    }

    private static readonly Guid[] ReplicationRights =
    [
        new Guid("1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"),
        new Guid("1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"),
        new Guid("89e95b76-444d-4c62-991a-0facbeda640c"),
    ];

    /// <summary>
    /// What an entry says that deserves a look (improvement of AUD-021): replication rights given outside the controllers and
    /// administrators (DCSync), or a broad write given to every account. An observation, never a verified capability.
    /// </summary>
    public static string? RiskOf(AceRead ace, IReadOnlyList<string> rights)
    {
        ArgumentNullException.ThrowIfNull(ace);
        ArgumentNullException.ThrowIfNull(rights);
        if (!ace.Allow)
        {
            return null;
        }
        var sid = ace.Sid;
        var replication = rights.Contains("ExtendedRight") && ace.ObjectType is Guid type && ReplicationRights.Contains(type);
        var expected = sid is "S-1-5-9" or "S-1-5-18" or "S-1-5-32-544"
            || sid.EndsWith("-498", StringComparison.Ordinal) || sid.EndsWith("-512", StringComparison.Ordinal) || sid.EndsWith("-516", StringComparison.Ordinal)
            || sid.EndsWith("-519", StringComparison.Ordinal) || sid.EndsWith("-521", StringComparison.Ordinal);
        if (replication && !expected)
        {
            return "Réplication de l’annuaire hors administrateurs (DCSync)";
        }
        var everyone = sid is "S-1-1-0" or "S-1-5-7" or "S-1-5-11" or "S-1-5-32-545" or "S-1-5-32-546"
            || sid.EndsWith("-513", StringComparison.Ordinal) || sid.EndsWith("-514", StringComparison.Ordinal) || sid.EndsWith("-515", StringComparison.Ordinal);
        var broadWrite = rights.Contains("GenericAll") || rights.Contains("GenericWrite") || rights.Contains("WriteDacl") || rights.Contains("WriteOwner")
            || (rights.Contains("WriteProperty") && ace.ObjectType is null);
        return everyone && broadWrite ? "Écriture large accordée à tous les comptes" : null;
    }

    /// <summary>Local filter of the entries: explicit only, and a text on trustee, SID, rights, target, objects (Select-DomeniaDelegationRows).</summary>
    public static IEnumerable<AuditAceRow> Select(IEnumerable<AuditAceRow> rows, bool explicitOnly, string? text)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var needle = text?.Trim() ?? string.Empty;
        foreach (var row in rows)
        {
            if (explicitOnly && !row.Explicit)
            {
                continue;
            }
            if (needle.Length > 0 && !new[] { row.Trustee, row.Sid, row.Rights, row.Target, row.AppliesTo }.Any(v => v.Contains(needle, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            yield return row;
        }
    }

    /// <summary>
    /// Estimate of what one trustee (and, when read, its groups) may do on the object, from the entries read. Canonical
    /// order: entries posed on the object first, then inherited ones; within each, a refusal wins. An object-specific write
    /// counts as « partial ». The result names its limits: owner, privileges and unread groups.
    /// </summary>
    public static AuditEstimate Estimate(AclRead read, string sid, TokenGroupsRead? token)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(sid);
        var trustee = TrusteeName(sid, read.SidNames);
        var withGroups = token is { State: ReadState.Read } && string.Equals(token.Sid, sid, StringComparison.OrdinalIgnoreCase);
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { sid.Trim(), Everyone, AuthenticatedUsers };
        if (withGroups)
        {
            set.UnionWith(token!.GroupSids);
        }
        var applicable = read.Aces.Where(a => AppliesToObject(a) && set.Contains(a.Sid)).ToList();
        var rows = ImmutableArray.CreateBuilder<AuditRightRow>();
        foreach (var category in Categories)
        {
            var result = EstimateResult.NotGranted;
            AceRead? by = null;
            foreach (var inheritedPass in new[] { false, true })
            {
                AceRead? deny = null;
                AceRead? allow = null;
                AceRead? partial = null;
                foreach (var ace in applicable.Where(a => a.IsInherited == inheritedPass))
                {
                    var rights = AuditText.RightNames(ace.Rights);
                    var anyObject = ace.ObjectType is null || ace.ObjectType == Guid.Empty;
                    var matched = false;
                    var isPartial = false;
                    if (rights.Contains("GenericAll"))
                    {
                        matched = true;
                    }
                    else
                    {
                        foreach (var right in category.Rights)
                        {
                            if (!rights.Contains(right))
                            {
                                continue;
                            }
                            if (anyObject || right.StartsWith("Generic", StringComparison.Ordinal))
                            {
                                matched = true;
                                break;
                            }
                            if (category.Guids.Length > 0 && ace.ObjectType is Guid g && category.Guids.Contains(g))
                            {
                                matched = true;
                                break;
                            }
                            if (category.PartialRights.Contains(right))
                            {
                                isPartial = true;
                            }
                        }
                    }
                    if (matched && !ace.Allow && deny is null)
                    {
                        deny = ace;
                    }
                    else if (matched && ace.Allow && allow is null)
                    {
                        allow = ace;
                    }
                    else if (isPartial && ace.Allow && partial is null)
                    {
                        partial = ace;
                    }
                }
                if (deny is not null)
                {
                    result = EstimateResult.Denied;
                    by = deny;
                    break;
                }
                if (allow is not null)
                {
                    result = EstimateResult.Allowed;
                    by = allow;
                    break;
                }
                if (partial is not null)
                {
                    result = EstimateResult.Partial;
                    by = partial;
                    break;
                }
            }
            var (label, tone) = result switch
            {
                EstimateResult.Allowed => ("Autorisé", Tone.Ok),
                EstimateResult.Denied => ("Refusé", Tone.Alert),
                EstimateResult.Partial => ("Partiel : certains attributs ou types seulement", Tone.Warn),
                _ => ("Non accordé par les entrées lues", Tone.Off),
            };
            var decidedBy = by is null ? null : TrusteeName(by.Sid, read.SidNames) + (by.IsInherited ? " · entrée héritée" : " · entrée posée sur l’objet");
            rows.Add(new AuditRightRow(category.Id, category.Label, result, label, tone, decidedBy));
        }
        var limits = new List<string>
        {
            "Estimation sur les entrées lues : le propriétaire (droits implicites), les privilèges (sauvegarde, restauration, prise de possession) et les refus portant sur des attributs précis ne sont pas évalués.",
            withGroups
                ? "Groupes du bénéficiaire lus par tokenGroups (groupes de sécurité de ce domaine et universels connus du contrôleur)."
                : "Groupes du bénéficiaire non lus : seules les entrées qui le désignent directement, et celles de Tout le monde et des Utilisateurs authentifiés, sont comptées.",
        };
        var groupsState = token is null || !string.Equals(token.Sid, sid, StringComparison.OrdinalIgnoreCase) ? ReadState.NotRead : token.State;
        var head = "Estimation pour " + trustee + ".";
        if (groupsState is not ReadState.NotRead and not ReadState.Read)
        {
            head += " Groupes non lus : " + token!.Message;
        }
        return new AuditEstimate(read.Dn, sid, trustee, withGroups, groupsState, groupsState == ReadState.NotRead ? null : token!.Message,
            withGroups ? token!.GroupSids.Length : 0, rows.ToImmutable(), string.Join(" ", limits), head);
    }
}
