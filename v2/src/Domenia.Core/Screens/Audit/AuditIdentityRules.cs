using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Identities (AUD-009, AUD-018, AUD-019, AUD-020; Domenia 1 Find-DomeniaIdentityConflicts, Test-DomeniaMachineIdentityCoherence,
/// Get-DomeniaRelationOverview, ConvertTo-DomeniaRelationHistoryRows, Get-DomeniaEvidenceBadge). Every finding is « À revoir »:
/// nothing is merged, renamed or deleted, and observations stay with the GUID they were read for. Pure.
/// </summary>
public static class AuditIdentityRules
{
    public const int DefaultScanLimit = 5000;
    public const int MinScanLimit = 100;
    public const int MaxScanLimit = 20000;

    public static string ShortName(string? name)
    {
        var value = (name ?? string.Empty).Trim().TrimEnd('.');
        var slash = value.LastIndexOf('\\');
        if (slash >= 0)
        {
            value = value[(slash + 1)..];
        }
        var dot = value.IndexOf('.', StringComparison.Ordinal);
        if (dot > 0)
        {
            value = value[..dot];
        }
        return value.TrimEnd('$').ToUpperInvariant();
    }

    public static AuditIdentities ScanView(IdentityScanRead scan, LocalNamesRead? local, string path)
    {
        ArgumentNullException.ThrowIfNull(scan);
        var findings = ImmutableArray.CreateBuilder<AuditIdentityFinding>();
        var limit = scan.Truncated ? "Périmètre lu partiellement : la liste des constats est incomplète." : "Périmètre choisi uniquement.";
        var n = 0;
        string NextId() => "f" + (++n).ToString(System.Globalization.CultureInfo.InvariantCulture);
        AuditIdentityObject Obj(IdentityScanObject o) => new(o.Name, o.Dn);

        foreach (var (field, label) in new (Func<IdentityScanObject, string?> Field, string Label)[]
        {
            (o => o.Mail, "Adresse de messagerie"),
            (o => o.UserPrincipalName, "Nom de connexion"),
            (o => o.EmployeeId, "Matricule"),
        })
        {
            foreach (var group in scan.Objects.Where(o => !string.IsNullOrWhiteSpace(field(o)))
                .GroupBy(o => field(o)!.ToLowerInvariant()).Where(g => g.Count() > 1).OrderBy(g => g.Key, StringComparer.Ordinal))
            {
                var objects = group.Select(Obj).ToImmutableArray();
                findings.Add(new AuditIdentityFinding(NextId(), "Valeur en double", label + " : " + group.Key, objects, string.Join(", ", objects.Select(o => o.Name)),
                    "À revoir", limit + " Un doublon visible ne désigne pas l’objet à corriger.", Tone.Warn));
            }
        }
        var computers = scan.Objects.Where(o => o.Kind == AuditObjectKind.Computer).ToList();
        foreach (var group in computers.Where(c => !string.IsNullOrWhiteSpace(c.DnsHostName))
            .GroupBy(c => c.DnsHostName!.Trim().TrimEnd('.').ToLowerInvariant()).Where(g => g.Count() > 1).OrderBy(g => g.Key, StringComparer.Ordinal))
        {
            var objects = group.Select(Obj).ToImmutableArray();
            findings.Add(new AuditIdentityFinding(NextId(), "Nom DNS partagé", "dNSHostName : " + group.Key, objects, string.Join(", ", objects.Select(o => o.Name)),
                "À revoir", limit + " Deux comptes ordinateur pour un même nom DNS : une adresse peut répondre pour l’un ou l’autre.", Tone.Warn));
        }
        foreach (var computer in computers)
        {
            if (!string.IsNullOrEmpty(computer.DnsHostName) && !string.Equals(ShortName(computer.DnsHostName), ShortName(computer.Name), StringComparison.Ordinal))
            {
                findings.Add(new AuditIdentityFinding(NextId(), "Nom AD et nom DNS divergents", computer.Name + " / " + computer.DnsHostName, [Obj(computer)], computer.Name,
                    "À revoir", "Renommage en cours ou compte réutilisé : vérifier l’identité du poste avant d’y attribuer une lecture.", Tone.Warn));
            }
        }
        var localState = local?.State ?? ReadState.NotRead;
        if (local is not null && localState == ReadState.Read)
        {
            var current = new Dictionary<string, IdentityScanObject>(StringComparer.Ordinal);
            foreach (var o in scan.Objects)
            {
                var key = o.Kind == AuditObjectKind.Computer ? "m:" + ShortName(o.Name) : o.Kind == AuditObjectKind.User ? "u:" + (o.SamAccountName ?? string.Empty).ToLowerInvariant() : string.Empty;
                if (key.Length > 2)
                {
                    current[key] = o;
                }
            }
            var reported = new HashSet<string>(StringComparer.Ordinal);
            foreach (var (items, prefix) in new[] { (local.Computers, "m:"), (local.Users, "u:") })
            {
                foreach (var item in items)
                {
                    var key = prefix == "m:" ? "m:" + ShortName(item.Name) : "u:" + item.Name.ToLowerInvariant();
                    if (!current.TryGetValue(key, out var live) || live.ObjectGuid == item.ObjectGuid || !reported.Add(key + "|" + item.ObjectGuid.ToString("D")))
                    {
                        continue;
                    }
                    findings.Add(new AuditIdentityFinding(NextId(), "Nom recyclé ou objet recréé",
                        live.Name + " : la base locale associe ce nom à un autre objet (" + item.ObjectGuid.ToString("D") + ")", [Obj(live)], live.Name, "À revoir",
                        "Les relevés, associations et observations restent liés au GUID qui les a produits : rien n’est reporté sur le nouvel objet.", Tone.Info));
                }
            }
        }
        var localText = localState switch
        {
            ReadState.Read when local!.Compared >= 0 && local.Compared < local.Total =>
                FrenchText.Integer(local.Compared) + " noms sur " + FrenchText.Integer(local.Total) + " comparés avec la base locale de Domenia : les autres ne sont pas recherchés, analysez une OU plus petite.",
            ReadState.Read => local!.Simulated ? "Noms comparés avec la copie locale fictive de la simulation." : "Noms comparés avec la base locale de Domenia.",
            ReadState.Unavailable => "Base locale non lue (" + (string.IsNullOrWhiteSpace(local?.Message) ? "raison non renvoyée" : local!.Message!.Trim().TrimEnd('.')) + ") : noms recyclés non recherchés.",
            ReadState.Empty => "Base locale absente : noms recyclés non recherchés.",
            ReadState.Refused => "Base locale occupée : noms recyclés non recherchés, relancez l’analyse.",
            _ => "Base locale non consultée : noms recyclés non recherchés.",
        };
        var all = findings.ToImmutable();
        var categories = all.GroupBy(f => f.Category).Select(g => new AuditCategoryCount(g.Key, g.Count())).OrderByDescending(c => c.Count).ThenBy(c => c.Category, StringComparer.Ordinal).ToImmutableArray();
        var summary = FrenchText.Count(all.Length, "constat à revoir", "constats à revoir") + " sur " + FrenchText.Count(scan.Objects.Length, "objet", "objets") + ". "
            + localText + " Aucune fusion ni correction automatique.";
        if (scan.Truncated)
        {
            summary += " Lecture bornée à " + FrenchText.Integer(scan.Limit) + " objets.";
        }
        return new AuditIdentities(scan.BaseDn, path, scan.Subtree, scan.Limit, scan.Objects.Length, scan.Truncated, all, categories, localState, localText, summary, scan.Controller, scan.ReadAt);
    }

    public static AuditMachineIdentity MachineView(string dn, AuditTarget target, MachineIdentityRead read)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(read);
        var reasons = new List<string>();
        var warnings = new List<string>();
        var facts = ImmutableArray.CreateBuilder<AuditFact>();
        var dnsName = (target.DnsHostName ?? string.Empty).Trim().TrimEnd('.');
        var samName = target.SamAccountName ?? target.Name;
        var expected = ShortName(dnsName);
        if (expected.Length == 0)
        {
            expected = ShortName(samName);
        }
        var dot = dnsName.IndexOf('.', StringComparison.Ordinal);
        var domainSuffix = dot > 0 ? dnsName[(dot + 1)..].ToLowerInvariant() : string.Empty;
        if (samName.Length > 0 && expected.Length > 0 && ShortName(samName) != expected)
        {
            warnings.Add("Nom AD (" + samName + ") et dNSHostName (" + dnsName + ") diffèrent : renommage ou mise à jour en attente.");
        }
        facts.Add(AuditPolicyRules.Fact("Nom dans l’annuaire", dnsName.Length > 0 ? dnsName : samName, expected.Length > 0 ? FactState.Observed : FactState.Unknown, "Attributs sAMAccountName et dNSHostName", id: "adName"));
        var state = IdentityCoherence.Coherent;
        if (expected.Length == 0)
        {
            state = IdentityCoherence.Unverified;
            reasons.Add("Nom AD du poste absent : identité non vérifiable.");
        }
        var address = read.Resolution.Addresses.FirstOrDefault();
        if (read.Resolution.State != ReadState.Read || read.Resolution.Addresses.Length == 0)
        {
            if (state == IdentityCoherence.Coherent)
            {
                state = IdentityCoherence.Unverified;
            }
            reasons.Add("Résolution DNS non obtenue : aucune adresse à confronter.");
            facts.Add(AuditPolicyRules.Fact("Résolution DNS", "Non obtenue", read.Resolution.State == ReadState.Read ? FactState.Unknown : FactState.Unavailable, "DNS", read.Resolution.Message, "dnsForward"));
            facts.Add(AuditPolicyRules.Fact("Nom inverse (PTR)", "Non interrogé", FactState.Unknown, "DNS inverse", "Sans adresse, aucun enregistrement inverse n’est cherché.", "dnsReverse"));
        }
        else
        {
            facts.Add(AuditPolicyRules.Fact("Résolution DNS", string.Join(", ", read.Resolution.Addresses), FactState.Observed, "DNS", "Un enregistrement DNS peut être périmé.", "dnsForward"));
            facts.Add(string.IsNullOrEmpty(read.Resolution.PtrName)
                ? AuditPolicyRules.Fact("Nom inverse (PTR)", "Aucun enregistrement inverse", FactState.Unknown, "DNS inverse de " + address, "Une absence d’enregistrement inverse ne prouve rien sur le poste.", "dnsReverse")
                : AuditPolicyRules.Fact("Nom inverse (PTR)", read.Resolution.PtrName.Trim().TrimEnd('.'), FactState.Observed, "DNS inverse de " + address, "Un enregistrement inverse peut être périmé.", "dnsReverse"));
            if (!string.IsNullOrEmpty(read.Resolution.PtrName) && expected.Length > 0 && ShortName(read.Resolution.PtrName) != expected)
            {
                warnings.Add("L’enregistrement inverse de " + address + " désigne " + read.Resolution.PtrName + " : DNS inverse périmé possible.");
            }
        }
        var reportedName = !string.IsNullOrEmpty(read.Reported.DnsHostName) ? read.Reported.DnsHostName : read.Reported.ComputerName ?? string.Empty;
        var reportedShort = ShortName(reportedName);
        if (read.Reported.State != ReadState.Read || reportedShort.Length == 0)
        {
            if (state == IdentityCoherence.Coherent)
            {
                state = IdentityCoherence.Unverified;
            }
            reasons.Add("Identité renvoyée par le poste non lue : les observations ne sont pas attribuées.");
            var reportedState = read.Reported.State switch
            {
                ReadState.Refused => FactState.Refused,
                ReadState.Unavailable => FactState.Unavailable,
                _ => FactState.Unknown,
            };
            facts.Add(AuditPolicyRules.Fact("Identité renvoyée par le poste", "Non lue", reportedState, "CIM Win32_ComputerSystem", read.Reported.Message, "reported"));
        }
        else
        {
            facts.Add(AuditPolicyRules.Fact("Identité renvoyée par le poste", reportedName, FactState.Observed, "CIM Win32_ComputerSystem", id: "reported"));
            if (expected.Length > 0 && reportedShort != expected)
            {
                state = IdentityCoherence.Incoherent;
                reasons.Add((address is null ? "L’adresse interrogée" : "L’adresse " + address) + " répond sous le nom " + reportedName + ", l’annuaire attend " + expected
                    + " : DNS périmé, adresse réattribuée ou poste renommé.");
            }
            var reportedDomain = (read.Reported.Domain ?? string.Empty).Trim().TrimEnd('.').ToLowerInvariant();
            if (reportedDomain.Length == 0)
            {
                var fqdn = reportedName.Trim().TrimEnd('.');
                var at = fqdn.IndexOf('.', StringComparison.Ordinal);
                if (!fqdn.Contains('\\', StringComparison.Ordinal) && at > 0)
                {
                    reportedDomain = fqdn[(at + 1)..].ToLowerInvariant();
                }
            }
            if (state != IdentityCoherence.Incoherent && reportedDomain.Length > 0 && domainSuffix.Length > 0 && reportedDomain != domainSuffix)
            {
                state = IdentityCoherence.Incoherent;
                reasons.Add("Le poste se déclare dans le domaine " + reportedDomain + ", l’annuaire attend " + domainSuffix + " : homonyme d’un autre domaine.");
            }
        }
        var (label, tone, summary) = state switch
        {
            IdentityCoherence.Coherent => ("Cohérente", Tone.Ok, "Identité cohérente : les observations peuvent être attribuées à ce poste."),
            IdentityCoherence.Incoherent => ("Incohérente", Tone.Alert, "Identité incohérente : aucune observation ni relation n’est attribuée à ce poste."),
            _ => ("Non vérifiée", Tone.Warn, "Identité non vérifiée : observations affichées sans attribution."),
        };
        return new AuditMachineIdentity(dn, state, label, tone, summary, [.. reasons], [.. warnings], facts.ToImmutable(), address, expected.Length > 0 ? expected : null,
            reportedName.Length > 0 ? reportedName : null, read.ReadAt);
    }

    public static (string Badge, string Label, string Rule) Badge(RelationKind kind) => kind switch
    {
        RelationKind.Declared => ("declared", "Déclarée", "Association déclarée par un opérateur dans Domenia."),
        RelationKind.Console => ("observed", "Observée", "Session console lue sur le poste à la date indiquée. Une observation ne vaut pas affectation."),
        RelationKind.RemoteSession => ("observed", "Observée", "Session distante lue sur le poste à la date indiquée. Une observation ne vaut pas affectation."),
        RelationKind.History => ("history", "Historique", "Ouverture de session ancienne relevée dans un journal ou un profil. Historique, pas présence actuelle."),
        RelationKind.Imported => ("imported", "Importée", "Ligne reprise d’un fichier importé. Exactitude dépendante du fichier source."),
        _ => ("clue", "Indice", "Attribut AD ou inventaire qui suggère un lien, sans observation de session."),
    };

    /// <summary>Three separate statements, each with its origin and date (Get-DomeniaRelationOverview).</summary>
    public static AuditRelations RelationsView(AuditTarget target, ImmutableArray<RelationRecord> relations, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(zone);
        if (target.Kind is not (AuditObjectKind.User or AuditObjectKind.Computer))
        {
            return new AuditRelations(target.Dn, false, [], 0, 0, 0, "Sélectionnez un utilisateur ou un ordinateur.");
        }
        // Never joined across GUIDs: a relation recorded for another object of the same name stays out.
        var kept = relations.Where(r =>
        {
            var guid = target.Kind == AuditObjectKind.User ? r.UserGuid : r.ComputerGuid;
            return guid is null || target.ObjectGuid is null || guid == target.ObjectGuid;
        }).ToList();
        var declared = kept.Where(r => r.Kind == RelationKind.Declared).ToList();
        var observed = kept.Where(r => r.Kind is RelationKind.Console or RelationKind.RemoteSession).ToList();
        var history = kept.Where(r => r.Kind == RelationKind.History).ToList();
        var clues = kept.Count - declared.Count - observed.Count - history.Count;
        string Describe(RelationRecord r)
        {
            var party = target.Kind == AuditObjectKind.Computer ? r.UserLogin : r.Computer;
            if (string.IsNullOrEmpty(party))
            {
                party = "non renseigné";
            }
            var when = r.When is DateTimeOffset w ? Relative(w, now, zone) : "date inconnue";
            var text = party + " · " + when;
            var source = AuditText.Flat(r.Source, 60);
            return source.Length > 0 ? text + " · source : " + source : text;
        }
        static RelationRecord Latest(List<RelationRecord> list) => list.OrderByDescending(r => r.When ?? DateTimeOffset.MinValue).First();
        var lines = ImmutableArray.CreateBuilder<AuditRelationLine>();
        var declaredText = declared.Count == 0 ? "Aucune affectation déclarée" : Describe(Latest(declared)) + (declared.Count > 1 ? " (" + FrenchText.Integer(declared.Count) + " affectations déclarées)" : string.Empty);
        var (b1, l1, r1) = Badge(RelationKind.Declared);
        lines.Add(new AuditRelationLine("Affectation déclarée", declaredText, b1, l1, r1));
        var (b2, l2, r2) = Badge(RelationKind.Console);
        lines.Add(new AuditRelationLine("Dernière session observée", observed.Count == 0 ? "Aucune session observée en mémoire" : Describe(Latest(observed)), b2, l2, r2));
        var (b3, l3, r3) = Badge(RelationKind.History);
        lines.Add(new AuditRelationLine("Historique", history.Count == 0 ? "Aucune ouverture de session ancienne relevée" : FrenchText.Count(history.Count, "relevé", "relevés") + ", le plus récent : " + Describe(Latest(history)), b3, l3, r3));
        if (clues > 0)
        {
            var (b4, l4, r4) = Badge(RelationKind.Clue);
            lines.Add(new AuditRelationLine("Autres indices", FrenchText.Count(clues, "indice ou ligne importée", "indices ou lignes importées") + ", à confirmer", b4, l4, r4));
        }
        var all = lines.ToImmutable();
        return new AuditRelations(target.Dn, true, all, declared.Count, observed.Count, history.Count, string.Join("\n", all.Select(l => l.Fact + " : " + l.Value)));
    }

    public static AuditHistory HistoryView(string dn, RelationHistoryRead read, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(zone);
        var rows = read.Rows.OrderByDescending(r => r.ObservedAt ?? DateTimeOffset.MinValue).Select(r =>
        {
            var (badge, label, rule) = Badge(r.Kind);
            return new AuditHistoryRow(r.ObservedAt, r.ObservedAt is DateTimeOffset at ? AuditText.LocalDateTime(at, zone) : "Date illisible", r.UserLogin, r.Computer, label, badge, rule, r.Source,
                r.VerifiedInAd switch { true => "Oui", false => "Non", _ => string.Empty }, AuditText.Flat(r.Details, 200));
        }).ToImmutableArray();
        var (stateLabel, summary) = read.State switch
        {
            ReadState.Refused => ("Occupée", "Base locale occupée : relancez la lecture dans un instant."),
            ReadState.Empty => ("Vide", "Aucun historique enregistré dans la base locale de Domenia pour cet objet."),
            ReadState.Unavailable => ("Non lue", "Lecture de l’historique impossible : " + read.Message),
            _ => ("Lu", FrenchText.Count(rows.Length, "ligne affichée", "lignes affichées") + " sur " + FrenchText.Count(read.Total, "enregistrée", "enregistrées")
                + " dans la base locale. La présence dans l’historique ne prouve pas une session actuelle."),
        };
        return new AuditHistory(dn, read.State, stateLabel, read.Total, rows.Length, read.Limit, rows, summary);
    }

    /// <summary>« aujourd’hui à 08:15 », « hier à 17:40 », « le 08/10 à 08:15 » (year shown when not the current one).</summary>
    public static string Relative(DateTimeOffset at, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(at, zone);
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        var time = local.ToString("HH':'mm", System.Globalization.CultureInfo.InvariantCulture);
        if (local.Date == today)
        {
            return "aujourd’hui à " + time;
        }
        if (local.Date == today.AddDays(-1))
        {
            return "hier à " + time;
        }
        var format = local.Year == today.Year ? "dd'/'MM" : "dd'/'MM'/'yyyy";
        return "le " + local.ToString(format, System.Globalization.CultureInfo.InvariantCulture) + " à " + time;
    }
}
