using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Security findings of the domain overview (AUD-023 and its improvement: findings by severity, health score, comparison
/// with the previous view). Each check of the catalogue is a bounded search of the overview (Domenia 1 « Comptes à
/// surveiller », « Groupes privilégiés », stratégie, corbeille…), graded here by a fixed rule. A refused check is said as
/// such, never counted as « no finding ». Pure.
/// </summary>
public static class AuditFindings
{
    /// <summary>One check of the catalogue: what it reads, what it means and how its result is graded.</summary>
    public sealed record CheckDefinition(
        string Id,
        string Category,
        string Title,
        AuditObjectKind? ObjectKind,
        string Source,
        string Limit,
        string Advice,
        string One,
        string Many,
        Func<SecurityCheckRead, Severity?> Grade);

    private static Severity? Any(SecurityCheckRead r, Severity severity) => r.Total > 0 ? severity : null;

    /// <summary>The catalogue, in display order inside each severity.</summary>
    public static ImmutableArray<CheckDefinition> Catalogue { get; } =
    [
        new("dcsyncRights", "Délégations", "Droits de réplication (DCSync) hors administrateurs", AuditObjectKind.Other,
            "DACL de la racine du domaine : droits étendus « Répliquer les modifications » et « Répliquer toutes les modifications »",
            "Entrées lues sur la racine seulement ; les contrôleurs, administrateurs et contrôleurs d’entreprise sont attendus et exclus.",
            "Retirer ces droits sauf besoin documenté (outil de synchronisation d’annuaire) : ils permettent d’extraire tous les secrets du domaine.",
            "bénéficiaire", "bénéficiaires", r => Any(r, Severity.Critical)),
        new("unconstrainedDelegation", "Kerberos", "Délégation non contrainte hors contrôleurs", AuditObjectKind.Computer,
            "userAccountControl:1.2.840.113556.1.4.803:=524288, contrôleurs exclus",
            "Comptes utilisateurs et ordinateurs du domaine, 60 au plus.",
            "Passer en délégation contrainte ou basée sur la ressource : un compte autorisé ici peut réutiliser le ticket de quiconque s’y connecte.",
            "compte", "comptes", r => Any(r, Severity.Critical)),
        new("krbtgtPassword", "Kerberos", "Mot de passe du compte krbtgt", AuditObjectKind.User,
            "pwdLastSet du compte krbtgt",
            "Âge calculé depuis la dernière modification lue ; un changement récent peut ne pas être encore répliqué.",
            "Changer le mot de passe de krbtgt deux fois, à un intervalle supérieur à la durée de vie des tickets.",
            "jour", "jours", r => r.Value switch { > 365 * 3 => Severity.High, > 365 => Severity.Medium, > 180 => Severity.Low, _ => null }),
        new("constrainedDelegation", "Kerberos", "Délégation contrainte avec transition de protocole", AuditObjectKind.User,
            "msDS-AllowedToDelegateTo renseigné et userAccountControl TRUSTED_TO_AUTH_FOR_DELEGATION",
            "Comptes du domaine, 60 au plus ; les cibles de délégation sont dans le détail.",
            "Vérifier que chaque cible est nécessaire : la transition de protocole permet d’obtenir un ticket pour n’importe quel utilisateur.",
            "compte", "comptes", r => Any(r, Severity.High)),
        new("asrepRoast", "Kerberos", "Comptes sans pré-authentification Kerberos", AuditObjectKind.User,
            "userAccountControl:1.2.840.113556.1.4.803:=4194304",
            "Comptes utilisateurs du domaine, 60 au plus.",
            "Réactiver la pré-authentification : sans elle, un attaquant obtient de quoi casser le mot de passe hors ligne (AS-REP roasting).",
            "compte", "comptes", r => Any(r, r.Objects.Any(o => o.Detail?.Contains("privilège", StringComparison.Ordinal) == true) ? Severity.Critical : Severity.High)),
        new("passwordNotRequired", "Mots de passe", "Mot de passe non requis (PASSWD_NOTREQD)", AuditObjectKind.User,
            "userAccountControl:1.2.840.113556.1.4.803:=32, comptes actifs",
            "Comptes utilisateurs actifs du domaine, 60 au plus.",
            "Retirer l’option et imposer un mot de passe conforme à la stratégie.",
            "compte", "comptes", r => Any(r, Severity.High)),
        new("reversibleEncryption", "Mots de passe", "Chiffrement réversible des mots de passe", AuditObjectKind.User,
            "pwdProperties du domaine (bit 16) et userAccountControl:1.2.840.113556.1.4.803:=128",
            "Stratégie du domaine et comptes actifs, 60 au plus.",
            "Désactiver le chiffrement réversible et faire changer les mots de passe concernés.",
            "compte", "comptes", r => Any(r, Severity.High)),
        new("kerberoast", "Kerberos", "Comptes utilisateurs avec SPN (Kerberoasting)", AuditObjectKind.User,
            "(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*))",
            "Comptes utilisateurs du domaine, 60 au plus ; krbtgt exclu.",
            "Préférer des comptes de service gérés (gMSA) ou des mots de passe longs et aléatoires ; jamais de SPN sur un compte à privilèges.",
            "compte", "comptes", r => Any(r, r.Objects.Any(o => o.Detail?.Contains("privilège", StringComparison.Ordinal) == true) ? Severity.High : Severity.Medium)),
        new("domainPasswordPolicy", "Mots de passe", "Stratégie de mot de passe du domaine", null,
            "minPwdLength, lockoutThreshold et pwdProperties de la racine du domaine",
            "Stratégie du domaine seulement ; les stratégies fines sont dans la section dédiée.",
            "Viser au moins 12 caractères, la complexité et un seuil de verrouillage.",
            "écart", "écarts", r => Any(r, Severity.Medium)),
        new("privilegedNotProtected", "Comptes à privilèges", "Comptes à privilèges hors de « Protected Users »", AuditObjectKind.User,
            "Membres actifs des groupes privilégiés absents du groupe Protected Users (RID 525)",
            "Appartenances directes et imbriquées lues dans la copie de l’analyse ; krbtgt exclu.",
            "Ajouter les comptes d’administration à Protected Users après avoir vérifié leurs usages (pas de NTLM, pas de délégation).",
            "compte", "comptes", r => Any(r, Severity.Medium)),
        new("passwordNeverExpires", "Mots de passe", "Mots de passe sans expiration", AuditObjectKind.User,
            "userAccountControl:1.2.840.113556.1.4.803:=65536, comptes actifs",
            "Comptes utilisateurs actifs, 60 au plus.",
            "Réserver l’option aux comptes de service documentés, de préférence des gMSA.",
            "compte", "comptes", r => Any(r, Severity.Medium)),
        new("machineAccountQuota", "Délégations", "Quota de jonction de postes (ms-DS-MachineAccountQuota)", null,
            "ms-DS-MachineAccountQuota de la racine du domaine",
            "Valeur du domaine ; une délégation de jonction sur une OU est une autre voie, non lue ici.",
            "Mettre le quota à 0 et déléguer la jonction à un groupe dédié.",
            "poste par utilisateur", "postes par utilisateur", r => r.Value is > 0 ? Severity.Medium : null),
        new("staleUsers", "Hygiène des comptes", "Comptes actifs sans connexion depuis 90 jours", AuditObjectKind.User,
            "lastLogonTimestamp antérieur à 90 jours, comptes actifs",
            "Date approximative (réplication différée de 9 à 14 jours) ; une date ancienne ne suffit pas à déclarer un compte supprimable.",
            "Désactiver après vérification auprès du responsable, puis supprimer selon la procédure.",
            "compte", "comptes", r => Any(r, Severity.Medium)),
        new("lapsMissing", "Postes", "Postes sans mot de passe LAPS", AuditObjectKind.Computer,
            "Postes actifs sans msLAPS-PasswordExpirationTime ni ms-Mcs-AdmPwdExpirationTime",
            "Postes actifs du domaine ; seules les dates d’expiration sont lues, jamais un mot de passe.",
            "Appliquer la stratégie LAPS aux OU concernées et vérifier le relevé sur ces postes.",
            "poste", "postes", r => Any(r, Severity.Medium)),
        new("recycleBin", "Annuaire", "Corbeille Active Directory désactivée", null,
            "msDS-EnabledFeature de CN=Partitions",
            "Fonctionnalité de la forêt.",
            "Activer la corbeille (irréversible, sans impact sur les objets existants).",
            "écart", "écarts", r => Any(r, Severity.Medium)),
        new("adminCountOrphans", "Comptes à privilèges", "adminCount résiduel (anciens comptes à privilèges)", AuditObjectKind.User,
            "adminCount=1 sans appartenance actuelle à un groupe protégé",
            "Appartenances lues dans la copie de l’analyse ; l’héritage reste désactivé sur ces comptes.",
            "Remettre adminCount à 0 et réactiver l’héritage des autorisations après vérification.",
            "compte", "comptes", r => Any(r, Severity.Low)),
        new("builtinAdminActive", "Comptes à privilèges", "Compte Administrateur intégré utilisé", AuditObjectKind.User,
            "Compte RID 500 actif avec une connexion récente",
            "lastLogonTimestamp approximatif.",
            "Utiliser des comptes d’administration nominatifs et garder le compte intégré pour le secours.",
            "compte", "comptes", r => Any(r, Severity.Low)),
        new("neverLoggedUsers", "Hygiène des comptes", "Comptes actifs jamais utilisés", AuditObjectKind.User,
            "Comptes actifs sans lastLogonTimestamp",
            "Comptes créés récemment compris.",
            "Vérifier l’arrivée prévue ; désactiver les comptes sans usage.",
            "compte", "comptes", r => Any(r, Severity.Low)),
        new("staleComputers", "Postes", "Postes actifs sans connexion depuis 90 jours", AuditObjectKind.Computer,
            "lastLogonTimestamp antérieur à 90 jours ou absent, postes actifs",
            "Date approximative ; un poste rangé ou en réparation est aussi concerné.",
            "Vérifier puis désactiver et déplacer en quarantaine.",
            "poste", "postes", r => Any(r, Severity.Low)),
        new("lapsExpired", "Postes", "Mots de passe LAPS expirés", AuditObjectKind.Computer,
            "msLAPS-PasswordExpirationTime dépassé",
            "Le poste renouvelle son mot de passe à sa prochaine connexion au domaine.",
            "Vérifier que ces postes joignent encore le domaine.",
            "poste", "postes", r => Any(r, Severity.Low)),
        new("disabledInGroups", "Hygiène des comptes", "Comptes désactivés encore membres de groupes", AuditObjectKind.User,
            "Comptes désactivés avec memberOf non vide (hors groupe principal)",
            "Appartenances directes seulement.",
            "Retirer les appartenances à la sortie, selon la procédure de départ.",
            "compte", "comptes", r => Any(r, Severity.Low)),
        new("privilegedMembers", "Comptes à privilèges", "Membres des groupes privilégiés", AuditObjectKind.User,
            "Membres directs et imbriqués d’Admins du domaine, Administrateurs, Administrateurs de l’entreprise et du schéma, opérateurs",
            "Groupes intégrés du domaine ; les délégations sur des OU ne sont pas comptées ici.",
            "Garder ces groupes aussi petits que possible et revoir leur composition régulièrement.",
            "membre", "membres", r => Any(r, Severity.Info)),
        new("lockedAccounts", "Hygiène des comptes", "Comptes verrouillés", AuditObjectKind.User,
            "État calculé par le contrôleur (msDS-User-Account-Control-Computed, bit 0x10)",
            "Un lockoutTime non nul sans cet état ne prouve pas un verrouillage actuel.",
            "Vérifier l’identité du demandeur avant tout déverrouillage (écran Comptes).",
            "compte", "comptes", r => Any(r, Severity.Info)),
        new("disabledAccounts", "Hygiène des comptes", "Comptes désactivés", AuditObjectKind.User,
            "userAccountControl:1.2.840.113556.1.4.803:=2",
            "Comptes utilisateurs du domaine, 200 au plus.",
            "Supprimer après la durée de conservation prévue.",
            "compte", "comptes", r => Any(r, Severity.Info)),
        new("trusts", "Annuaire", "Approbations de domaine", AuditObjectKind.Domain,
            "(objectClass=trustedDomain) sous CN=System",
            "Approbations déclarées dans ce domaine ; l’état des canaux n’est pas testé.",
            "Vérifier la nécessité et le filtrage des SID de chaque approbation.",
            "approbation", "approbations", r => Any(r, Severity.Info)),
    ];

    private static readonly FrozenDictionary<string, CheckDefinition> ById = Catalogue.ToFrozenDictionary(c => c.Id, StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, int> Positions = Catalogue.Select((c, i) => (c.Id, i)).ToFrozenDictionary(p => p.Id, p => p.i, StringComparer.Ordinal);

    public static CheckDefinition? Find(string id) => ById.GetValueOrDefault(id);

    public static string SeverityLabel(Severity severity) => severity switch
    {
        Severity.Critical => "Critique",
        Severity.High => "Élevée",
        Severity.Medium => "Moyenne",
        Severity.Low => "Faible",
        _ => "Information",
    };

    public static Tone ToneOf(Severity severity) => severity switch
    {
        Severity.Critical or Severity.High => Tone.Alert,
        Severity.Medium => Tone.Warn,
        Severity.Low => Tone.Info,
        _ => Tone.Off,
    };

    /// <summary>Points taken from 100 by one finding of this severity (« score de santé », indicative).</summary>
    public static int Weight(Severity severity) => severity switch
    {
        Severity.Critical => 15,
        Severity.High => 6,
        Severity.Medium => 3,
        Severity.Low => 1,
        _ => 0,
    };

    public static AuditScore Score(IEnumerable<AuditFinding> findings)
    {
        ArgumentNullException.ThrowIfNull(findings);
        var list = findings.ToList();
        var lost = list.Where(f => !f.Passed && f.State == ReadState.Read).Sum(f => Weight(f.Severity));
        var value = Math.Clamp(100 - lost, 0, 100);
        var (tone, label) = value switch
        {
            >= 85 => (Tone.Ok, "Bon"),
            >= 65 => (Tone.Info, "Correct"),
            >= 40 => (Tone.Warn, "À améliorer"),
            _ => (Tone.Alert, "Préoccupant"),
        };
        var refused = list.Count(f => f.State is ReadState.Refused or ReadState.Unavailable);
        var detail = "Indicatif : 100 moins 15 par constat critique, 6 par constat élevé, 3 par constat moyen et 1 par constat faible."
            + (refused > 0 ? " " + FrenchText.Count(refused, "contrôle non lu n’est pas compté", "contrôles non lus ne sont pas comptés") + " : le score peut être optimiste." : string.Empty);
        return new AuditScore(value, tone, label, detail);
    }

    /// <summary>The catalogue as the page shows it before an analysis: each control with the severity it has when found.</summary>
    public static ImmutableArray<AuditCheck> Checks() =>
    [
        .. Catalogue.Select(d =>
        {
            var severity = FallbackSeverity(d);
            return new AuditCheck(d.Id, d.Category, d.Title, severity, SeverityLabel(severity), ToneOf(severity), d.Source, d.Advice);
        }),
    ];

    public static AuditFinding Finding(CheckDefinition definition, SecurityCheckRead read, int? previousCount)
    {
        ArgumentNullException.ThrowIfNull(definition);
        ArgumentNullException.ThrowIfNull(read);
        var readable = read.State is ReadState.Read or ReadState.Empty;
        var graded = readable ? definition.Grade(read) : null;
        var passed = readable && graded is null;
        var severity = graded ?? FallbackSeverity(definition);
        // A scalar check (krbtgt age, quota) counts its value; a list check counts the objects its search found.
        var scalar = read.Value is not null;
        var count = scalar ? (int)Math.Clamp(read.Value!.Value, 0, int.MaxValue) : read.Total;
        var truncated = !scalar && read.Total > read.Objects.Length;
        string summary;
        string countLabel;
        if (!readable)
        {
            summary = (read.State == ReadState.Refused ? "Lecture refusée : " : "Lecture impossible : ") + (read.Message ?? "raison non renvoyée") + " Aucune absence n’est déduite.";
            countLabel = read.State == ReadState.Refused ? "Refusé" : "Non lu";
        }
        else
        {
            countLabel = FrenchText.Count(count, definition.One, definition.Many);
            summary = read.ValueText is not null && (scalar || read.Objects.IsEmpty)
                ? read.ValueText + (passed ? " : sans écart." : ".")
                : passed ? "Aucun " + definition.One + " concerné." : FrenchText.Count(read.Total, definition.One, definition.Many) + " concerné" + (read.Total > 1 ? "s" : string.Empty) + ".";
            if (truncated && read.Objects.Length > 0)
            {
                summary += " Lecture bornée à " + FrenchText.Integer(read.Objects.Length) + " objets.";
            }
        }
        int? delta = previousCount is int before && readable ? count - before : null;
        return new AuditFinding(
            definition.Id,
            passed ? Severity.Info : severity,
            passed ? "Sans écart" : SeverityLabel(severity),
            passed ? Tone.Ok : readable ? ToneOf(severity) : Tone.Off,
            definition.Category,
            definition.Title,
            summary,
            count,
            countLabel,
            passed,
            read.State,
            definition.Source,
            definition.Limit,
            definition.Advice,
            definition.ObjectKind,
            readable && read.Objects.Length > 0,
            truncated,
            delta,
            readable && !passed ? [.. read.Objects.Take(3).Select(o => o.Name)] : []);
    }

    /// <summary>Severity a check would have when found (for a refused check: shown greyed, never counted).</summary>
    private static Severity FallbackSeverity(CheckDefinition definition) =>
        definition.Grade(new SecurityCheckRead(definition.Id, ReadState.Read, null, [], 1, 1, long.MaxValue, null)) ?? Severity.Info;

    public static AuditOverview Overview(DomainOverviewRead read, AuditOverview? previous)
    {
        ArgumentNullException.ThrowIfNull(read);
        var before = previous?.Findings.ToDictionary(f => f.Id, f => f.State == ReadState.Read ? f.Count : (int?)null, StringComparer.Ordinal);
        var findings = new List<AuditFinding>();
        foreach (var definition in Catalogue)
        {
            var check = read.Checks.FirstOrDefault(c => c.Id == definition.Id)
                ?? new SecurityCheckRead(definition.Id, ReadState.NotRead, "Contrôle non lu par cette version du lecteur.", [], 0, 0, null, null);
            findings.Add(Finding(definition, check, before?.GetValueOrDefault(definition.Id)));
        }
        var order = findings
            .OrderBy(f => f.Passed ? 1 : 0)
            .ThenBy(f => f.State is ReadState.Read or ReadState.Empty ? 0 : 1)
            .ThenBy(f => f.Severity)
            .ThenBy(f => Positions[f.Id])
            .ToImmutableArray();
        var counted = order.Where(f => !f.Passed && f.State is ReadState.Read or ReadState.Empty).ToList();
        var counts = new SeverityCounts(
            counted.Count(f => f.Severity == Severity.Critical),
            counted.Count(f => f.Severity == Severity.High),
            counted.Count(f => f.Severity == Severity.Medium),
            counted.Count(f => f.Severity == Severity.Low),
            counted.Count(f => f.Severity == Severity.Info),
            order.Count(f => f.Passed));
        var score = Score(order);
        var sections = read.Sections.Select(Section).ToImmutableArray();
        var refused = sections.Count(s => s.State == ReadState.Refused) + order.Count(f => f.State == ReadState.Refused);
        var anomalies = sections.Count(s => s.State is ReadState.Unavailable or ReadState.Refused or ReadState.NotRead);
        AuditPrevious? previousView = null;
        if (previous is not null)
        {
            var delta = score.Value - previous.Score.Value;
            var label = delta == 0 ? "Score inchangé depuis la vue précédente"
                : (delta > 0 ? "En hausse de " : "En baisse de ") + FrenchText.Count(Math.Abs(delta), "point", "points") + " depuis la vue précédente";
            previousView = new AuditPrevious(previous.ReadAt, previous.Score.Value, delta, label);
        }
        var summary = "Analyse de " + read.Controller + " : " + FrenchText.Count(counted.Count, "constat", "constats") + " ("
            + FrenchText.Integer(counts.Critical) + " critique" + (counts.Critical > 1 ? "s" : string.Empty) + ", "
            + FrenchText.Integer(counts.High) + " élevé" + (counts.High > 1 ? "s" : string.Empty) + ", "
            + FrenchText.Integer(counts.Medium) + " moyen" + (counts.Medium > 1 ? "s" : string.Empty) + "), "
            + FrenchText.Count(counts.Passed, "contrôle sans écart", "contrôles sans écart") + ", "
            + FrenchText.Count(sections.Length, "section", "sections") + ", " + FrenchText.Count(refused, "refus", "refus") + ". Lecture seule : l’annuaire n’est jamais compté en entier.";
        return new AuditOverview(read.ReadAt, read.Controller, read.DurationMs, score, counts, order, sections, refused, anomalies, summary, previousView);
    }

    private static readonly FrozenDictionary<string, string> SectionIcons = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["directory"] = "database",
        ["fsmo"] = "key",
        ["passwordPolicy"] = "lock",
        ["fineGrained"] = "sliders",
        ["recycleBin"] = "trash",
        ["controllers"] = "server",
        ["sites"] = "domain",
        ["trusts"] = "link",
        ["gpo"] = "layers",
        ["privilegedGroups"] = "shield",
        ["watchlist"] = "eye",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    public static AuditSection Section(OverviewSectionRead read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var (label, tone) = read.State switch
        {
            ReadState.Read => ("Lu", Tone.Ok),
            ReadState.Empty => ("Vide", Tone.Off),
            ReadState.Refused => ("Refusé", Tone.Alert),
            ReadState.Unavailable => ("Indisponible", Tone.Warn),
            _ => ("Non lu", Tone.Off),
        };
        var items = read.Items.Select(i => new AuditSectionItem(i.Label, string.IsNullOrWhiteSpace(i.Value) ? "Non renseigné" : i.Value, i.Tone)).ToImmutableArray();
        if (items.IsEmpty && read.State == ReadState.Empty)
        {
            items = [new AuditSectionItem("Résultat", "Aucune donnée retournée", null)];
        }
        return new AuditSection(read.Id, read.Title, SectionIcons.GetValueOrDefault(read.Id, "info"), read.State, label, tone, read.Message, items);
    }

    public const int ObjectsLimit = 500;

    public static AuditFindingObjects Objects(AuditFinding finding, SecurityCheckRead read, DateTimeOffset readAt)
    {
        ArgumentNullException.ThrowIfNull(finding);
        ArgumentNullException.ThrowIfNull(read);
        var rows = read.Objects.Take(ObjectsLimit).Select(o => new AuditObjectRow(
            o.Dn,
            o.Name,
            o.Kind,
            AuditTargets.KindLabel(o.Kind),
            o.SamAccountName,
            o.Enabled,
            o.LastLogon,
            o.PasswordLastSet,
            o.Detail,
            ContainerOf(o.Dn))).ToImmutableArray();
        var truncated = read.Total > rows.Length;
        var summary = FrenchText.Count(rows.Length, "objet lu", "objets lus") + " par l’analyse"
            + (truncated ? " sur " + FrenchText.Integer(read.Total) + " : lecture bornée, la liste est incomplète." : ".")
            + " Exploration sans relecture : ces objets sont ceux de la dernière analyse.";
        return new AuditFindingObjects(finding.Id, finding.Title, finding.Severity, finding.SeverityLabel, read.Total, rows.Length, truncated, ObjectsLimit, readAt, summary, rows);
    }

    /// <summary>Readable container of an object (« Utilisateurs › Paris »), the domain shown by its DNS form only.</summary>
    public static string ContainerOf(string dn)
    {
        try
        {
            var parts = DistinguishedName.Parse(dn);
            var names = parts.Skip(1).Where(p => !string.Equals(p.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value).Reverse().ToList();
            return names.Count == 0 ? "Racine du domaine" : string.Join(FrenchText.PathSeparator, names);
        }
        catch (FormatException)
        {
            return string.Empty;
        }
    }

    public static AuditLocalTotals LocalTotals(LocalTotalsRead read)
    {
        ArgumentNullException.ThrowIfNull(read);
        string[] order = ["Utilisateur", "Ordinateur", "Groupe", "OU", "Conteneur"];
        var labels = new Dictionary<string, (string One, string Many)>(StringComparer.Ordinal)
        {
            ["Utilisateur"] = ("utilisateur", "utilisateurs"),
            ["Ordinateur"] = ("ordinateur", "ordinateurs"),
            ["Groupe"] = ("groupe", "groupes"),
            ["OU"] = ("OU", "OU"),
            ["Conteneur"] = ("conteneur", "conteneurs"),
        };
        var types = read.Types.Where(t => t.Count > 0).GroupBy(t => t.Type, StringComparer.Ordinal)
            .Select(g => new AuditTotalRow(g.Key, labels.TryGetValue(g.Key, out var l) ? l.Many : g.Key, g.Sum(t => t.Count), g.Where(t => t.Disabled).Sum(t => t.Count)))
            .OrderBy(t => Array.IndexOf(order, t.Type) is var i && i >= 0 ? i : order.Length).ThenBy(t => t.Type, StringComparer.Ordinal)
            .ToImmutableArray();
        var total = types.Sum(t => t.Count);
        var (stateLabel, summary) = read.State switch
        {
            ReadState.Read when total == 0 => ("Vide", "Copie locale vide : aucune synchronisation enregistrée."),
            ReadState.Read => ("Lue", string.Join(", ", types.Select(t =>
            {
                (string One, string Many) words = labels.TryGetValue(t.Type, out var l) ? l : (t.Type, t.Type);
                var text = FrenchText.Count(t.Count, words.One, words.Many);
                return t.Disabled > 0 ? text + " (dont " + FrenchText.Integer(t.Disabled) + " désactivé" + (t.Disabled > 1 ? "s" : string.Empty) + ")" : text;
            })) + (read.Simulated ? ". Copie fictive de la simulation : aucune base locale n’est ouverte." : ". Totaux de la copie locale, jamais un dénombrement de l’annuaire.")),
            ReadState.Empty => ("Absente", "Base locale absente : aucun total à afficher."),
            ReadState.Refused => ("Occupée", "Base locale occupée : relancez l’analyse dans un instant."),
            _ => ("Non lue", "Base locale non lue : " + read.Message),
        };
        return new AuditLocalTotals(read.State, stateLabel, read.LastSyncAt, read.Complete, read.Simulated, total, types, summary);
    }
}
