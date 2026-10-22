using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Perimeter choices of the offline dossier: the workstation of the session, the working OU, an OU chosen in the tree (Domenia 1
/// « OU sélectionnée »), the pinned workstations, or the workstations of a list of names (Domenia 1 « postes des résultats
/// affichés », 500 at most: names pasted or exported from a result list, or sent by another screen).
/// </summary>
public enum DossierScope
{
    Subject,
    WorkingOu,
    Branch,
    Pins,
    List,
}

/// <summary>
/// Perimeter of one dossier (Domenia 1 Get-DomeniaOfflineDossierPerimeter): a list of workstation GUIDs (500 at most) or one OU
/// inside the domain, never the whole domain implicitly. <see cref="Valid"/> false carries the reason in <see cref="Error"/>.
/// </summary>
public sealed record DossierPerimeter(bool Valid, string? Error, string Kind, ImmutableArray<string> Guids, string? OrganizationalUnit, string Label, int Count, bool Truncated);

/// <summary>What a dossier is made of: perimeter, sections (« etat » and « postes » always) and the row limit of each section.</summary>
public sealed record DossierRequest(DossierPerimeter Perimeter, ImmutableArray<string> Sections, int Limit);

/// <summary>
/// Rows of the local base for one dossier, in the published shapes of the automation contract (Domenia.Automation/1): source
/// of the data, computers, latest observations, user ↔ workstation links and saved queries.
/// </summary>
public sealed record DossierData(
    JsonObject Source,
    JsonObject State,
    JsonArray Computers,
    bool ComputersTruncated,
    JsonArray Observations,
    bool ObservationsTruncated,
    JsonArray Links,
    JsonArray Queries,
    ImmutableArray<string> Notes);

/// <summary>One file of a dossier: its name, its text, its UTF-8 bytes (no byte order mark) and their SHA-256 (lower-case hexadecimal).</summary>
public sealed record DossierFile(string Name, string Text, byte[] Bytes, string Sha256);

public sealed record DossierBuild(string FolderName, ImmutableArray<DossierFile> Files, ImmutableArray<DossierSectionSummary> Sections, ImmutableArray<string> Excluded);

/// <summary>
/// Offline diagnostic dossier (Domenia 1 points 139 and 140, Domenia.OfflineDossier/1): a new dated folder with one JSON file
/// per section (automation contract envelopes), a readme, a manifest and the SHA-256 of every file. Pure rules: the engine
/// reads the local data (never the network nor the directory) and writes the folder.
/// </summary>
public static partial class OfflineDossiers
{
    public const string Contract = "Domenia.OfflineDossier/1";
    public const string AutomationContract = "Domenia.Automation/1";
    public const int DefaultRows = 1000;
    public const int MaxRows = 5000;
    public const int MaxNames = 500;
    public const int MaxPayloadChars = 262_144;
    public const long MaxDossierChars = 67_108_864;
    public const string Meaning = "Lecture de la base locale de Domenia : données datées, non revérifiées dans Active Directory ni sur les postes.";

    /// <summary>Sections that may be left out; « etat » and « postes » are always written (the others cannot be read without them).</summary>
    public static ImmutableArray<string> OptionalSections { get; } = ["observations", "associations", "requetes"];

    public static ImmutableArray<string> ExcludedFamilies { get; } =
    [
        "Mots de passe et secrets", "Clés de récupération BitLocker", "Mots de passe et métadonnées LAPS", "Table secret_state",
        "Détails d’annuaire bruts (domenia_details)", "Journaux bruts", "Comptes de connexion et jetons",
    ];

    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>French label of a section (« etat » → « État de la base »).</summary>
    public static string SectionLabel(string section) => section switch
    {
        "etat" => "État de la base",
        "postes" => "Postes",
        "observations" => "Observations",
        "associations" => "Associations",
        "requetes" => "Requêtes",
        _ => section,
    };

    /// <summary>Sections of a request in their written order: « etat », « postes », then the chosen optional ones.</summary>
    public static ImmutableArray<string> Sections(IEnumerable<string> optional)
    {
        ArgumentNullException.ThrowIfNull(optional);
        var chosen = optional.ToHashSet(StringComparer.Ordinal);
        return ["etat", "postes", .. OptionalSections.Where(chosen.Contains)];
    }

    /// <summary>A workstation chosen on the screen (the computer subject of the session, a pinned workstation).</summary>
    public sealed record Workstation(string Guid, string Name);

    /// <summary>
    /// Perimeter of a dossier (Domenia 1 Get-DomeniaOfflineDossierPerimeter). <paramref name="workingOu"/> is the working OU,
    /// <paramref name="branch"/> the OU chosen in the tree; <paramref name="listed"/> the workstations found for the names of a
    /// list and <paramref name="unresolved"/> the names that matched none. Never the whole domain, 500 workstations at most.
    /// </summary>
    public static DossierPerimeter Perimeter(
        DossierScope scope,
        Workstation? subject,
        ScopeSelection? workingOu,
        string? domainRootDn,
        IEnumerable<Workstation> pins,
        ScopeSelection? branch = null,
        IEnumerable<Workstation>? listed = null,
        int unresolved = 0)
    {
        ArgumentNullException.ThrowIfNull(pins);
        switch (scope)
        {
            case DossierScope.Subject:
                if (subject is null)
                {
                    return Fail("Choisissez d’abord le poste concerné, ou prenez une OU, les postes épinglés ou une liste de postes.");
                }
                if (!Guid.TryParse(subject.Guid, out var guid) || guid == Guid.Empty)
                {
                    return Fail("Poste choisi sans GUID connu" + FrenchText.Colon + "relisez sa fiche avant de préparer le dossier.");
                }
                return new DossierPerimeter(true, null, "Guids", [guid.ToString("D")], null, subject.Name.Length > 0 ? subject.Name : "poste choisi", 1, false);
            case DossierScope.Pins:
                return Workstations(pins, "poste épinglé", "postes épinglés",
                    "Aucun poste épinglé" + FrenchText.Colon + "épinglez des postes, ou prenez le poste choisi, une OU ou une liste de postes.", 0);
            case DossierScope.List:
                return Workstations(listed ?? [], "poste de la liste", "postes de la liste",
                    unresolved > 0
                        ? "Aucun poste de la liste n’est connu de l’index local" + FrenchText.Colon + AssistanceText.Count(unresolved, "nom inconnu", "noms inconnus") + "."
                        : "Liste de postes vide" + FrenchText.Colon + "collez des noms de postes, un par ligne (500 au plus).",
                    unresolved);
            case DossierScope.Branch:
                return Ou(branch, domainRootDn, "Aucune OU choisie" + FrenchText.Colon + "choisissez une OU dans l’arborescence.", "L’OU choisie");
            default:
                return Ou(workingOu, domainRootDn, "Aucune OU de travail" + FrenchText.Colon + "choisissez-en une depuis l’Accueil.", "L’OU de travail");
        }
    }

    private static DossierPerimeter Fail(string why) => new(false, why, "", [], null, "", 0, false);

    private static DossierPerimeter Workstations(IEnumerable<Workstation> items, string singular, string plural, string empty, int unresolved)
    {
        var guids = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var truncated = false;
        foreach (var item in items)
        {
            if (!Guid.TryParse(item.Guid, out var itemGuid) || itemGuid == Guid.Empty || !seen.Add(itemGuid.ToString("D")))
            {
                continue;
            }
            if (guids.Count >= MaxNames)
            {
                truncated = true;
                break;
            }
            guids.Add(itemGuid.ToString("D"));
        }
        if (guids.Count == 0)
        {
            return Fail(empty);
        }
        var label = AssistanceText.Count(guids.Count, singular, plural) + (truncated ? ", limité aux " + FrenchText.Integer(MaxNames) + " premiers" : "")
            + (unresolved > 0 ? " (" + AssistanceText.Count(unresolved, "nom inconnu ignoré", "noms inconnus ignorés") + ")" : "");
        return new DossierPerimeter(true, null, "Guids", [.. guids], null, label, guids.Count, truncated);
    }

    private static DossierPerimeter Ou(ScopeSelection? ou, string? domainRootDn, string missing, string what)
    {
        if (ou is null || string.IsNullOrWhiteSpace(ou.Dn))
        {
            return Fail(missing);
        }
        if (domainRootDn is not null && ScopeRules.IsDomainRoot(ou, domainRootDn))
        {
            return Fail(what + " est tout le domaine" + FrenchText.Colon + "un dossier n’est jamais préparé sur tout le domaine. Choisissez une OU.");
        }
        if (!ou.Dn.StartsWith("OU=", StringComparison.OrdinalIgnoreCase))
        {
            return Fail(what + " n’est pas une OU" + FrenchText.Colon + "choisissez une OU.");
        }
        if (domainRootDn is not null && !ScopeRules.Contains(new ScopeSelection(domainRootDn, "", true), ou.Dn))
        {
            return Fail(what + " n’appartient pas au domaine de la session" + FrenchText.Colon + "choisissez une OU de ce domaine.");
        }
        return new DossierPerimeter(true, null, "OU", [], ou.Dn, "OU " + ou.Label, 0, false);
    }

    /// <summary>
    /// Folder name: Domenia-Diagnostic-&lt;sujet&gt;-AAAAMMJJ-HHmm at the local time of <paramref name="zone"/> (as every other
    /// export of the screen), letters, digits, dot, dash and underscore only.
    /// </summary>
    public static string FolderName(string? subject, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var clean = SubjectCharacters().Replace((subject ?? "").Trim(), "-").Trim('-', '.');
        if (clean.Length > 60)
        {
            clean = clean[..60].Trim('-', '.');
        }
        if (clean.Length == 0)
        {
            clean = "perimetre";
        }
        return "Domenia-Diagnostic-" + clean + "-" + TimeZoneInfo.ConvertTime(now, zone).ToString("yyyyMMdd'-'HHmm", CultureInfo.InvariantCulture);
    }

    /// <summary>A field whose name says it carries a secret is never exported, whatever its value (pwdLastSet is a date, kept).</summary>
    public static bool IsSecretName(string? name) => !string.IsNullOrWhiteSpace(name) && SecretName().IsMatch(name.Trim());

    /// <summary>Copy of a value without the fields named as secrets, recursively, with the paths of what was left out.</summary>
    public static JsonNode? Protect(JsonNode? value, string path, List<string> excluded, int depth = 0)
    {
        ArgumentNullException.ThrowIfNull(excluded);
        if (depth > 32)
        {
            excluded.Add(path + " (profondeur)");
            return null;
        }
        switch (value)
        {
            case null:
                return null;
            case JsonObject source:
                var copy = new JsonObject();
                foreach (var (key, child) in source)
                {
                    var childPath = path.Length == 0 ? key : path + "." + key;
                    if (IsSecretName(key))
                    {
                        excluded.Add(childPath);
                        continue;
                    }
                    copy[key] = Protect(child, childPath, excluded, depth + 1);
                }
                return copy;
            case JsonArray items:
                var array = new JsonArray();
                for (var i = 0; i < items.Count; i++)
                {
                    array.Add(Protect(items[i], path + "[" + i.ToString(CultureInfo.InvariantCulture) + "]", excluded, depth + 1));
                }
                return array;
            default:
                return value.DeepClone();
        }
    }

    /// <summary>Published answer of one section: contract, date, source, perimeter, items and whether a bound was reached.</summary>
    public static JsonObject Envelope(string command, JsonArray items, JsonObject source, DossierPerimeter perimeter, int limit, bool truncated,
        IReadOnlyList<string> excluded, IReadOnlyList<string> notes, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(items);
        ArgumentNullException.ThrowIfNull(perimeter);
        return new JsonObject
        {
            ["Contract"] = AutomationContract,
            ["Command"] = command,
            ["GeneratedUtc"] = now.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
            ["Source"] = source.DeepClone(),
            ["Perimeter"] = PerimeterJson(perimeter),
            ["Limit"] = limit,
            ["Count"] = items.Count,
            ["Truncated"] = truncated,
            ["ExcludedFields"] = Strings(excluded),
            ["Notes"] = Strings(notes),
            ["Items"] = items.DeepClone(),
            ["Meaning"] = Meaning,
        };
    }

    /// <summary>
    /// The files of one dossier, as texts: one envelope per section, the readme, the manifest (with the SHA-256 of every file
    /// as written, UTF-8 without BOM) and SHA256SUMS.txt. More than 64 Mio of text is refused.
    /// </summary>
    public static DossierBuild Build(DossierRequest request, DossierData data, string subjectName, string build, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(data);
        var files = new List<DossierFile>();
        var summary = new List<DossierSectionSummary>();
        var excludedAll = new List<string>();
        long total = 0;
        foreach (var section in request.Sections)
        {
            var excluded = new List<string>();
            var (rows, truncated) = section switch
            {
                "etat" => (new JsonArray(data.State.DeepClone()), false),
                "postes" => (data.Computers, data.ComputersTruncated),
                "observations" => (data.Observations, data.ObservationsTruncated),
                "associations" => (data.Links, false),
                _ => (data.Queries, false),
            };
            var clean = (JsonArray)Protect(rows, section, excluded)!;
            IReadOnlyList<string> sectionNotes = section switch
            {
                "requetes" when clean.Count == 0 => ["Aucune requête enregistrée dans la base locale."],
                "associations" when clean.Count == 0 => ["Aucune association mémorisée pour ce périmètre."],
                _ => [],
            };
            IReadOnlyList<string> notes = [.. sectionNotes, .. data.Notes];
            var envelope = Envelope(section, clean, data.Source, request.Perimeter, request.Limit, truncated, excluded, notes, now);
            var text = envelope.ToJsonString(Indented);
            total += text.Length;
            if (total > MaxDossierChars)
            {
                throw new DomeniaOperationException(AssistanceErrors.DossierTooLarge, "Dossier supérieur à 64 Mio de texte" + FrenchText.Colon + "réduisez le périmètre ou la limite. Aucun dossier final n’est créé.");
            }
            files.Add(File(section + ".json", text));
            summary.Add(new DossierSectionSummary(section, clean.Count, truncated, excluded.Count));
            excludedAll.AddRange(excluded);
        }
        var perimeterText = request.Perimeter.Kind == "OU" ? "OU " + request.Perimeter.OrganizationalUnit : request.Perimeter.Label;
        var readme = string.Join("\r\n",
            "Dossier de diagnostic hors ligne Domenia",
            "Créé le " + AssistanceText.Stamp(now, zone) + (build.Length > 0 ? " par la version " + build : "") + ".",
            "Périmètre choisi" + FrenchText.Colon + perimeterText + ".",
            "",
            "Contenu : état de la base locale, postes, dernières observations enregistrées, associations et requêtes enregistrées,",
            "selon les sections retenues. Chaque fichier JSON suit le contrat Domenia.Automation/1 et porte sa date de lecture.",
            "",
            "Ce que ce dossier ne prouve pas : les données viennent de la base locale de Domenia ; elles ne sont revérifiées ni",
            "dans Active Directory ni sur les postes. Un relevé ancien reste ancien, une absence de relevé reste inconnue.",
            "",
            "Exclus : mots de passe, clés de récupération BitLocker, mots de passe et métadonnées LAPS, jetons et tout champ nommé",
            "comme un secret (liste dans manifeste.json), table des secrets de la base, journaux bruts et comptes de connexion.",
            "Le dossier contient des noms de postes, de comptes et des chemins internes : conservez-le sur un support protégé.",
            "",
            "Intégrité : SHA256SUMS.txt donne l’empreinte de chaque fichier (Get-FileHash -Algorithm SHA256).") + "\r\n";
        files.Add(File("LISEZMOI.txt", readme));
        var entries = new JsonArray();
        foreach (var file in files)
        {
            entries.Add((JsonNode?)new JsonObject { ["Fichier"] = file.Name, ["Sha256"] = file.Sha256.ToUpperInvariant(), ["Caracteres"] = file.Text.Length, ["Octets"] = file.Bytes.Length });
        }
        var sections = new JsonArray();
        foreach (var item in summary)
        {
            sections.Add((JsonNode?)new JsonObject { ["Section"] = item.Section, ["Elements"] = item.Elements, ["Tronque"] = item.Truncated, ["ChampsExclus"] = item.ExcludedFields });
        }
        var manifest = new JsonObject
        {
            ["Contract"] = Contract,
            ["CreatedUtc"] = now.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
            ["Build"] = build,
            ["Source"] = data.Source.DeepClone(),
            ["Perimeter"] = PerimeterJson(request.Perimeter),
            ["Sections"] = sections,
            ["Files"] = entries,
            ["ExcludedFields"] = Strings(excludedAll),
            ["Excluded"] = Strings(ExcludedFamilies),
            ["Network"] = "Aucun accès réseau pour produire ce dossier.",
        };
        files.Add(File("manifeste.json", manifest.ToJsonString(Indented)));
        var sums = string.Join("\r\n", files.Select(f => f.Sha256 + "  " + f.Name)) + "\r\n";
        files.Add(File("SHA256SUMS.txt", sums));
        return new DossierBuild(FolderName(subjectName, now, zone), [.. files], [.. summary], [.. excludedAll]);
    }

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    private static DossierFile File(string name, string text)
    {
        var bytes = Utf8.GetBytes(text);
        return new DossierFile(name, text, bytes, Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes)));
    }

    private static JsonObject PerimeterJson(DossierPerimeter perimeter)
    {
        var guids = new JsonArray();
        foreach (var guid in perimeter.Guids)
        {
            guids.Add((JsonNode?)JsonValue.Create(guid));
        }
        return new JsonObject
        {
            ["Kind"] = perimeter.Kind,
            ["OrganizationalUnit"] = perimeter.OrganizationalUnit,
            ["Guids"] = guids,
            ["Label"] = perimeter.Label,
        };
    }

    private static JsonArray Strings(IEnumerable<string> values)
    {
        var array = new JsonArray();
        foreach (var value in values)
        {
            array.Add((JsonNode?)JsonValue.Create(value));
        }
        return array;
    }

    [GeneratedRegex(@"[^\p{L}\p{Nd}._-]+", RegexOptions.CultureInvariant, 100)]
    private static partial Regex SubjectCharacters();

    [GeneratedRegex(@"(password|passwd|pwd(?!_?last_?set)|secret|token|credential|ms-mcs-admpwd|laps|bitlocker.*(key|recovery)|recoverypassword|recoverykey|msfve|privatekey|apikey|bearer|cookie)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex SecretName();
}
