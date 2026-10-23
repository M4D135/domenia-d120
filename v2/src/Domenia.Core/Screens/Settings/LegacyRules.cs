using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// One step of the takeover plan (Domenia 1 Get-DomeniaMigrationPlan): what is taken from which source into which table, and
/// why. Actions: « import » (rows taken into an empty table, or closed history kept read only), « add » (rows absent from
/// Domenia 2 added, existing ones kept), « keep » (Domenia 2 already holds this data: nothing merged nor replaced), « ignore »
/// (empty source, takeover already applied), « refuse » (source refused: nothing written).
/// </summary>
public sealed record LegacyStep(string Id, string Source, string Label, string Target, string Action, long Rows, string Reason);

/// <summary>A file of the older version as the page shows it, with what its reading found.</summary>
public sealed record LegacyFileView(string Kind, string Label, string Path, string Target, long Bytes, string BytesText, long Rows, int Rejected, int Duplicates, bool Locked, string Domain);

/// <summary>
/// The takeover plan: its steps, the blockers that refuse it as a whole (a refused plan writes nothing), the rows it would
/// write, whether the same takeover was already applied, and the readable lines of the simulation.
/// </summary>
public sealed record LegacyPlan(ImmutableArray<LegacyStep> Steps, ImmutableArray<string> Blockers, long WriteCount, bool Already, bool Allowed, ImmutableArray<string> Lines);

/// <summary>
/// Pure rules of the takeover of the Domenia 1 data (PAR-028), port of Domenia 1 Read-DomeniaLegacySource,
/// Get-DomeniaLegacySnapshot and Get-DomeniaMigrationPlan, extended to the local base of Domenia 1 (schema 11,
/// ARCHITECTURE.md § 6): files of 128 MiB and 250 000 lines at most, read under a shared lock, one domain only and the same
/// as the context, duplicates refused, the four target tables of the older files empty, the base at schema 11 revision 1,
/// existing associations never replaced, an applied takeover never applied again. Any blocker refuses the whole plan.
/// </summary>
public static class LegacyRules
{
    /// <summary>Largest file of the older version read (Domenia 1: 128 MB).</summary>
    public const long MaxFileBytes = 128L * 1024 * 1024;

    /// <summary>Most lines of one file of the older version (Domenia 1: 250 000).</summary>
    public const long MaxRows = 250_000;

    /// <summary>Schema version of the Domenia 1 base taken over (Domenia 1 SupportedSchemaVersions).</summary>
    public const string SupportedSchema = "11";

    /// <summary>Revision « domenia_schema » of a Domenia 1 base.</summary>
    public const string SupportedRevision = "1";

    /// <summary>The files of the older version (kind, label, path under the data folder, target table of the base).</summary>
    public static ImmutableArray<(string Kind, string Label, string File, string Target)> FileKinds { get; } =
    [
        ("Objets", "Objets de l’annuaire", @"Index\objets.tsv", "ad_objects"),
        ("Parc", "État du parc", @"Index\parc.tsv", "park_state"),
        ("Recherches", "Recherches d’utilisateurs", @"Index\recherches.tsv", "user_scan_history"),
        ("Secrets", "Métadonnées de secrets", @"Index\secrets-etat.tsv", "secret_state"),
        ("Liens", "Associations poste-utilisateur", "Domenia-user-machine-links.csv", "user_machine_links"),
    ];

    /// <summary>The four tables that must be empty before the files of the older version are taken (links excepted).</summary>
    public static ImmutableArray<string> EmptyTables { get; } = ["ad_objects", "park_state", "user_scan_history", "secret_state"];

    /// <summary>Guards of the takeover in plain words (shown by the page and the plan).</summary>
    public static ImmutableArray<string> Guards { get; } =
    [
        "Fichiers de l’ancienne version" + FrenchText.Colon + "128" + FrenchText.Nbsp + "Mo et 250" + FrenchText.ThousandsSeparator + "000 lignes au plus chacun, lus sous un verrou partagé (personne ne peut les écrire pendant la lecture).",
        "Un seul domaine, le même que celui de la session" + FrenchText.Colon + "aucune fusion entre domaines.",
        "Les quatre tables cibles (objets, parc, recherches, métadonnées de secrets) doivent être vides ; un doublon dans une source refuse tout.",
        "Base de Domenia 1" + FrenchText.Colon + "schéma 11, révision 1, lue en lecture seule ; elle reste en place, intacte.",
        "Les associations existantes ne sont jamais remplacées ; une reprise déjà appliquée ne se rejoue pas.",
        "Une sauvegarde de migration est faite juste avant, hors rotation ; la reprise part seulement d’un geste explicite.",
    ];

    /// <summary>Label of a kind of file of the older version.</summary>
    public static string FileLabel(string kind) => FileKinds.FirstOrDefault(f => string.Equals(f.Kind, kind, StringComparison.OrdinalIgnoreCase)).Label ?? kind;

    /// <summary>Target table of a kind of file of the older version, or null when the kind is unknown.</summary>
    public static string? FileTarget(string kind) => FileKinds.FirstOrDefault(f => string.Equals(f.Kind, kind, StringComparison.OrdinalIgnoreCase)).Target;

    /// <summary>« example.local » from the DC components of a DN (Domenia 1 ConvertTo-DomeniaMigrationDomain), or null.</summary>
    public static string? DomainOf(string? dn)
    {
        if (string.IsNullOrWhiteSpace(dn))
        {
            return null;
        }
        try
        {
            var dcs = DistinguishedName.Parse(dn).Where(n => string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value.Trim().ToLowerInvariant()).ToList();
            return dcs.Count == 0 ? null : string.Join('.', dcs);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static string Normalize(string? domain)
    {
        var text = (domain ?? "").Trim().TrimEnd('.');
        if (!text.Contains('=')) { return text.ToLowerInvariant(); }
        try
        {
            var parts = DistinguishedName.Parse(text);
            return parts.Length > 0 && parts.All(x => x.Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                ? string.Join('.', parts.Select(x => x.Value.ToLowerInvariant())) : "";
        }
        catch (FormatException) { return ""; }
    }

    /// <summary>The files of the older version as the page shows them.</summary>
    public static ImmutableArray<LegacyFileView> Files(LegacySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return
        [
            .. source.Files.Select(f => new LegacyFileView(f.Kind, FileLabel(f.Kind), f.Path, FileTarget(f.Kind) ?? "", f.Bytes, SettingsFormat.Size(f.Bytes), f.Rows, f.Rejected, f.Duplicates, f.Locked,
                f.Domains.Length == 0 ? "" : string.Join(", ", f.Domains))),
        ];
    }

    /// <summary>
    /// The takeover plan of a source for the domain of the session. Never reads anything: the reader of the mode inspected the
    /// sources read only; this rule only decides, and names every refusal.
    /// </summary>
    public static LegacyPlan Plan(LegacySource source, string contextDomain)
    {
        ArgumentNullException.ThrowIfNull(source);
        var steps = new List<LegacyStep>();
        var blockers = new List<string>();
        var lines = new List<string>();
        if (source.ReadProblem is { Length: > 0 } problem)
        { return new LegacyPlan([], [problem], 0, false, false, ["Lecture des sources historiques interrompue : " + problem]); }
        if (!source.Found)
        {
            lines.Add("Aucune donnée de Domenia 1 trouvée sur ce poste" + FrenchText.Colon + "rien à reprendre.");
            return new LegacyPlan([], [], 0, false, false, [.. lines]);
        }
        var current = Normalize(contextDomain);
        var already = source.AppliedMarker is string applied && applied.Length > 0 && string.Equals(applied, source.Marker, StringComparison.Ordinal);
        if (!already && source.AppliedMarker is { Length: > 0 })
        {
            blockers.Add("Une autre reprise de données a déjà été appliquée" + FrenchText.Colon + "aucun ajout automatique.");
        }
        void CheckDomain(string origin, string? domain)
        {
            if (string.IsNullOrWhiteSpace(domain))
            {
                blockers.Add("Domaine " + origin + " non identifié" + FrenchText.Colon + "aucune reprise de données.");
            }
            else if (current.Length == 0)
            {
                blockers.Add("Domaine de la session inconnu" + FrenchText.Colon + "reprise des données reportée.");
            }
            else if (!string.Equals(Normalize(domain), current, StringComparison.Ordinal))
            {
                blockers.Add("Domaine différent (" + origin + FrenchText.Colon + Normalize(domain) + " ; Domenia" + FrenchText.Colon + current + ")" + FrenchText.Colon + "aucune fusion entre domaines.");
            }
        }

        // The local base of Domenia 1 (schema 11): read only, never modified; its parts follow their rule.
        if (source.Database is LegacyDatabase database)
        {
            var schema = (database.SchemaVersion ?? "").Trim();
            var revision = (database.Revision ?? "").Trim();
            var refused = false;
            if (!string.Equals(schema, SupportedSchema, StringComparison.Ordinal))
            {
                blockers.Add("Version de base non prise en charge" + FrenchText.Colon + "<" + schema + ">. Base " + database.Name + " conservée telle quelle, aucune écriture ; schéma 11 attendu.");
                steps.Add(new LegacyStep("database", database.Name, "Base de Domenia 1", "", "refuse", 0, "Version de schéma non prise en charge" + FrenchText.Colon + "base intacte."));
                refused = true;
            }
            else if (revision.Length > 0 && !string.Equals(revision, SupportedRevision, StringComparison.Ordinal))
            {
                blockers.Add("Révision Domenia de la base non prise en charge" + FrenchText.Colon + "<" + revision + ">. Base " + database.Name + " intacte.");
                steps.Add(new LegacyStep("database", database.Name, "Base de Domenia 1", "", "refuse", 0, "Révision Domenia inconnue" + FrenchText.Colon + "base intacte."));
                refused = true;
            }
            else
            {
                CheckDomain("de la base " + database.Name, database.Domain);
            }
            if (!refused)
            {
                steps.AddRange(database.Parts.Select(p => PartStep(p, database.Name, already)));
            }
        }
        steps.AddRange(source.Settings.Select(p => PartStep(p, "Domenia.settings.json", already)));

        // Files of the older version (Domenia 1 Import-DomeniaLegacyStoreIfNeeded): guards first, then one table each.
        var files = source.Files.Where(f => f is not null).ToList();
        if (files.Count > 0)
        {
            foreach (var file in files)
            {
                var name = file.Path.Replace('/', '\\').Split('\\')[^1];
                if (file.Bytes > MaxFileBytes)
                {
                    blockers.Add("Fichier historique trop volumineux" + FrenchText.Colon + name + " (128" + FrenchText.Nbsp + "Mo au plus).");
                }
                if (file.Rows > MaxRows)
                {
                    blockers.Add("Plus de 250" + FrenchText.ThousandsSeparator + "000 lignes dans " + name + FrenchText.Colon + "reprise refusée.");
                }
                if (file.Duplicates > 0)
                {
                    blockers.Add("Doublon dans les données " + file.Kind + FrenchText.Colon + "corrigez la source avant reprise.");
                }
                if (!file.Locked)
                {
                    blockers.Add("Fichier " + name + " en cours d’écriture" + FrenchText.Colon + "il n’a pas pu être lu sous un verrou partagé ; refaites la simulation.");
                }
            }
            var domains = files.SelectMany(f => f.Domains).Select(Normalize).Where(d => d.Length > 0).Distinct(StringComparer.Ordinal).ToList();
            if (domains.Count > 1)
            {
                blockers.Add("Plusieurs domaines dans les identités historiques" + FrenchText.Colon + "reprise refusée.");
            }
            else if (!already)
            {
                CheckDomain("des fichiers historiques", domains.Count == 1 ? domains[0] : source.Domain);
            }
            if (!already)
            {
                foreach (var table in EmptyTables)
                {
                    if (!source.TargetRows.TryGetValue(table, out var rows))
                    {
                        blockers.Add("État de la table " + table + " inconnu.");
                    }
                    else if (rows > 0)
                    {
                        blockers.Add("La table " + table + " contient déjà des données" + FrenchText.Colon + "reprise des fichiers historiques refusée.");
                    }
                }
            }
            var taken = new HashSet<string>(StringComparer.Ordinal);
            foreach (var file in files)
            {
                var target = FileTarget(file.Kind);
                var label = FileLabel(file.Kind);
                if (target is null)
                {
                    steps.Add(new LegacyStep("file." + file.Kind, file.Path, file.Kind, "", "ignore", 0, "Source historique non reconnue" + FrenchText.Colon + "conservée, non reprise."));
                    continue;
                }
                if (already)
                {
                    steps.Add(new LegacyStep("file." + file.Kind, file.Path, label, target, "ignore", 0, "Reprise identique déjà appliquée" + FrenchText.Colon + "rien à écrire."));
                    continue;
                }
                if (file.Rows <= 0)
                {
                    steps.Add(new LegacyStep("file." + file.Kind, file.Path, label, target, "ignore", 0, "Source vide" + FrenchText.Colon + "rien à reprendre."));
                    continue;
                }
                if (!taken.Add(target))
                {
                    steps.Add(new LegacyStep("file." + file.Kind, file.Path, label, target, "ignore", 0, "Une source est déjà reprise pour " + target + FrenchText.Colon + "la première trouvée est retenue."));
                    continue;
                }
                steps.Add(target == "user_machine_links"
                    ? new LegacyStep("file." + file.Kind, file.Path, label, target, "add", file.Rows, "Un lien par poste, le plus récent ; les associations existantes sont conservées, aucun détail libre repris.")
                    : new LegacyStep("file." + file.Kind, file.Path, label, target, "import", file.Rows, FrenchText.Count(file.Rows, "ligne reprise", "lignes reprises") + " dans une table vide ; fichier historique conservé."));
            }
            var rejected = files.Sum(f => (long)f.Rejected);
            lines.Add("Fichiers de l’ancienne version" + FrenchText.Colon + string.Join(", ", files.Select(f => FileLabel(f.Kind).ToLowerInvariant() + " " + FrenchText.Integer(f.Rows))) + ". Lignes invalides ignorées" + FrenchText.Colon + FrenchText.Integer(rejected) + ".");
        }
        else
        {
            lines.Add("Fichiers de l’ancienne version (objets.tsv, parc.tsv, recherches.tsv, secrets-etat.tsv, liens)" + FrenchText.Colon + "aucun trouvé.");
        }
        if (source.Database is LegacyDatabase db)
        {
            lines.Insert(0, "Base de Domenia 1" + FrenchText.Colon + db.Name + " (" + SettingsFormat.Size(db.Bytes) + ", schéma " + (db.SchemaVersion ?? "inconnu") + ", révision " + (db.Revision ?? "inconnue") + ", domaine " + (db.Domain ?? "inconnu") + "), lue en lecture seule.");
        }
        else
        {
            lines.Insert(0, "Base de Domenia 1" + FrenchText.Colon + "aucune trouvée.");
        }
        var writeCount = blockers.Count > 0 ? 0 : steps.Where(s => s.Action is "import" or "add").Sum(s => s.Rows);
        if (blockers.Count > 0)
        {
            // A refused plan writes nothing: every write it would have made is reported, never sent.
            steps = [.. steps.Select(s => s.Action is "import" or "add" ? s with { Action = "refuse", Reason = "Reporté" + FrenchText.Colon + "la reprise est refusée (voir les blocages)." } : s)];
        }
        if (already)
        {
            lines.Add("Reprise déjà appliquée" + (source.ImportedAt is DateTimeOffset at ? " le " + at.UtcDateTime.ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture) : "") + FrenchText.Colon + "la reprise est idempotente, rien n’est rejoué.");
        }
        lines.Add("Les fichiers et la base de Domenia 1 restent en place ; une sauvegarde de migration de la base de Domenia 2 est faite juste avant, hors rotation.");
        return new LegacyPlan([.. steps], [.. blockers], writeCount, already, blockers.Count == 0 && writeCount > 0, [.. lines]);
    }

    private static LegacyStep PartStep(LegacyPart part, string source, bool already)
    {
        var id = "part." + part.Id;
        if (already)
        {
            return new LegacyStep(id, source, part.Label, part.Target, "ignore", 0, "Reprise identique déjà appliquée" + FrenchText.Colon + "rien à écrire.");
        }
        if (part.Rows <= 0)
        {
            return new LegacyStep(id, source, part.Label, part.Target, "ignore", 0, "Rien à reprendre.");
        }
        switch (part.Rule)
        {
            case "emptyOnly":
                return part.Present > 0
                    ? new LegacyStep(id, source, part.Label, part.Target, "keep", 0, "Déjà alimenté dans Domenia 2 (" + FrenchText.Integer(part.Present) + ")" + FrenchText.Colon + "aucune fusion ni remplacement.")
                    : new LegacyStep(id, source, part.Label, part.Target, "import", part.Rows, FrenchText.Count(part.Rows, "ligne reprise", "lignes reprises") + " dans une table vide.");
            case "addMissing":
                var missing = Math.Max(0, part.Rows - part.Present);
                return missing > 0
                    ? new LegacyStep(id, source, part.Label, part.Target, "add", missing, FrenchText.Count(missing, "ajout", "ajouts") + (part.Present > 0 ? " ; " + FrenchText.Count(part.Present, "élément déjà présent conservé", "éléments déjà présents conservés") : "") + ", jamais remplacés.")
                    : new LegacyStep(id, source, part.Label, part.Target, "keep", 0, "Tout est déjà présent dans Domenia 2" + FrenchText.Colon + "rien à ajouter.");
            case "history":
                return part.Present >= part.Rows
                    ? new LegacyStep(id, source, part.Label, part.Target, "keep", 0, "Historique déjà repris.")
                    : new LegacyStep(id, source, part.Label, part.Target, "import", part.Rows - part.Present, "Historique conservé en lecture seule, jamais rejoué.");
            default:
                return new LegacyStep(id, source, part.Label, part.Target, "ignore", 0, "Règle inconnue" + FrenchText.Colon + "partie conservée, non reprise.");
        }
    }
}
