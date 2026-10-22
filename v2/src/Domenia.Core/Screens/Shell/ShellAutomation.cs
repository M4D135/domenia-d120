using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Local automation contract « Domenia.Automation/1 » (Domenia 1 Get-DomeniaAutomationContract, Test-DomeniaAutomationRequest,
/// New-DomeniaAutomationEnvelope, ConvertTo-DomeniaAutomationCsv; TRV-067 to TRV-069): versioned commands, bounds, exit codes,
/// validation of a command line and the published shape of an answer. Pure: the command line host (wave 3) reads the local
/// base; the shell shows the contract and previews an answer from the data of the session.
/// </summary>
public static partial class ShellAutomation
{
    public const string ContractName = "Domenia.Automation/1";
    public const string Meaning = "Lecture de la base locale de Domenia : données datées, non revérifiées dans Active Directory ni sur les postes.";

    public static AutomationLimits Limits { get; } = new(1000, 5000, 500, 2048);

    private static readonly string Perimeter = "Périmètre" + FrenchText.Colon + "-OrganizationalUnit (DN d’une OU), -Computers (noms) ou -Guids (GUID de postes).";

    /// <summary>The contract, as the command line answers « version ».</summary>
    public static AutomationContract Contract { get; } = new(
        ContractName,
        1,
        "Ligne de commande locale" + FrenchText.Nbsp + "; aucun port réseau, aucun service, aucune écriture dans la base.",
        [
            new AutomationCommand("version", "Lecture", "Contrat, version et commandes disponibles.", false, ["Json"]),
            new AutomationCommand("etat", "Lecture", "État daté de la base locale" + FrenchText.Colon + "identité, révision, synchronisations et volumes par famille.", false, ["Json"]),
            new AutomationCommand("postes", "Lecture", "Postes de l’index local. " + Perimeter, true, ["Json", "Csv"]),
            new AutomationCommand("observations", "Lecture", "Dernières observations enregistrées (présence, console, inventaire, sondes), datées, champs secrets exclus. " + Perimeter, true, ["Json"]),
            new AutomationCommand("associations", "Lecture", "Associations utilisateur ↔ poste mémorisées. " + Perimeter, true, ["Json", "Csv"]),
            new AutomationCommand("requetes", "Lecture", "Requêtes enregistrées non archivées (définition et empreinte).", false, ["Json"]),
            new AutomationCommand("dossier", "Export", "Dossier de diagnostic hors ligne daté" + FrenchText.Colon + "état, postes, observations, associations et requêtes du périmètre choisi, avec empreintes SHA-256. " + Perimeter, true, ["Dossier"]),
        ],
        [
            new AutomationExitCode(0, "Succès", "Réponse écrite en entier."),
            new AutomationExitCode(2, "Usage", "Commande, option ou valeur refusée avant toute lecture."),
            new AutomationExitCode(3, "Base", "Base locale occupée, absente ou illisible."),
            new AutomationExitCode(4, "Refus", "Périmètre exigé mais absent : aucune commande ne parcourt tout le domaine implicitement."),
            new AutomationExitCode(5, "Écriture", "Fichier ou dossier de sortie impossible à écrire (rien de partiel n’est laissé)."),
        ],
        Limits,
        [
            "Aucun port ni service" + FrenchText.Colon + "une commande explicite, une réponse datée, puis la fin du processus.",
            "Lecture seule" + FrenchText.Colon + "la base locale est ouverte en lecture ; ni l’annuaire ni un poste ne sont contactés.",
            "Périmètre obligatoire et unique pour les commandes de postes (OU, noms ou GUID)" + FrenchText.Colon + "jamais tout le domaine implicitement.",
            "Bornes explicites (1 000 lignes par défaut, 5 000 au plus, 500 noms)" + FrenchText.Colon + "une troncature est toujours signalée.",
            "CSV neutralisé, écrit en UTF-8 avec BOM, à côté puis renommé" + FrenchText.Colon + "chemins réseau, lecteurs mappés et liens refusés.",
        ]);

    /// <summary>
    /// Validates a command line (Domenia 1 Test-DomeniaAutomationRequest, without the base path, which the command line host
    /// checks): returns the normalized request, or the French reason and the exit code of the refusal.
    /// </summary>
    public static (AutomationRequest? Request, string? Error, int ExitCode) Validate(
        string? command, string? organizationalUnit, IEnumerable<string?>? computers, IEnumerable<string?>? guids, int limit, string? format)
    {
        var name = (command ?? "").Trim().ToLowerInvariant();
        var definition = Contract.Commands.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.Ordinal));
        if (definition is null)
        {
            return (null, "Commande inconnue" + FrenchText.Colon + FrenchText.Quote(ShellTexts.FlatLine(command, 40)) + ". Commandes" + FrenchText.Colon + string.Join(", ", Contract.Commands.Select(c => c.Name)) + ".", 2);
        }
        var formatName = string.IsNullOrWhiteSpace(format) ? definition.Formats[0] : format.Trim();
        var chosen = definition.Formats.FirstOrDefault(f => string.Equals(f, formatName, StringComparison.OrdinalIgnoreCase));
        if (chosen is null)
        {
            return (null, "Format " + FrenchText.Quote(ShellTexts.FlatLine(format, 20)) + " non pris en charge par " + name + " (" + string.Join(", ", definition.Formats) + ").", 2);
        }
        string? ou = null;
        if (!string.IsNullOrWhiteSpace(organizationalUnit))
        {
            ou = NormalizeOu(organizationalUnit);
            if (ou is null)
            {
                return (null, "OU non reconnue" + FrenchText.Colon + FrenchText.Quote(ShellTexts.FlatLine(organizationalUnit, 80)) + " (OU=…,DC=… attendu).", 2);
            }
        }
        var names = new List<string>();
        foreach (var raw in (computers ?? []).SelectMany(c => (c ?? "").Split(',')))
        {
            var computer = raw.Trim().TrimEnd('$');
            var dot = computer.IndexOf('.', StringComparison.Ordinal);
            computer = (dot >= 0 ? computer[..dot] : computer).ToLowerInvariant();
            if (computer.Length == 0 || names.Contains(computer, StringComparer.Ordinal))
            {
                continue;
            }
            if (!ComputerName().IsMatch(computer))
            {
                return (null, "Nom de poste invalide" + FrenchText.Colon + FrenchText.Quote(ShellTexts.FlatLine(computer, 63)) + ".", 2);
            }
            names.Add(computer);
        }
        var guidList = new List<string>();
        foreach (var raw in (guids ?? []).SelectMany(g => (g ?? "").Split(',')))
        {
            var guid = raw.Trim().Trim('{', '}').ToLowerInvariant();
            if (guid.Length == 0 || guidList.Contains(guid, StringComparer.Ordinal))
            {
                continue;
            }
            if (!GuidText().IsMatch(guid))
            {
                return (null, "GUID invalide" + FrenchText.Colon + FrenchText.Quote(ShellTexts.FlatLine(guid, 40)) + ".", 2);
            }
            guidList.Add(guid);
        }
        if (names.Count + guidList.Count > Limits.MaxNames)
        {
            return (null, FrenchText.Integer(Limits.MaxNames) + " postes au plus par commande" + FrenchText.Colon + "choisissez une OU ou découpez la liste.", 2);
        }
        var kinds = (ou is null ? 0 : 1) + (names.Count > 0 ? 1 : 0) + (guidList.Count > 0 ? 1 : 0);
        if (definition.Perimeter && kinds == 0)
        {
            return (null, "Périmètre requis pour " + name + FrenchText.Colon + "-OrganizationalUnit, -Computers ou -Guids. Aucune commande ne parcourt tout le domaine implicitement.", 4);
        }
        if (kinds > 1)
        {
            return (null, "Un seul périmètre à la fois" + FrenchText.Colon + "OU, noms ou GUID.", 2);
        }
        var rows = limit <= 0 ? Limits.DefaultRows : limit;
        if (rows > Limits.MaxRows)
        {
            return (null, "Limite de " + FrenchText.Integer(Limits.MaxRows) + " lignes au plus.", 2);
        }
        var kind = ou is not null ? "OU" : names.Count > 0 ? "Noms" : guidList.Count > 0 ? "Guids" : "Aucun";
        var perimeter = new AutomationPerimeter(kind, ou, [.. names], [.. guidList]);
        return (new AutomationRequest(name, chosen, perimeter, rows), null, 0);
    }

    /// <summary>
    /// DN of an OU, a container or a naming context of a perimeter, spaces around separators removed; null when it is not a
    /// branch of the directory (a perimeter is never a single object) or longer than the bound.
    /// </summary>
    public static string? NormalizeOu(string? dn)
    {
        var text = AroundEquals().Replace(AroundCommas().Replace((dn ?? "").Trim(), ","), "=");
        if (text.Length == 0 || text.Length > Limits.MaxOuLength || !BranchDn().IsMatch(text) || !BranchStart().IsMatch(text))
        {
            return null;
        }
        return text;
    }

    /// <summary>Workstations of a perimeter, in name order (shared by the readers that serve a preview).</summary>
    public static IEnumerable<DirectoryComputer> Select(IEnumerable<DirectoryComputer> computers, AutomationPerimeter perimeter)
    {
        ArgumentNullException.ThrowIfNull(computers);
        ArgumentNullException.ThrowIfNull(perimeter);
        var selected = perimeter.Kind switch
        {
            "OU" => computers.Where(c => perimeter.OrganizationalUnit is string ou && DistinguishedName.IsWithin(c.DistinguishedName, ou, subtree: true)),
            "Noms" => computers.Where(c => perimeter.Computers.Contains(c.Name.ToLowerInvariant(), StringComparer.Ordinal)),
            "Guids" => computers.Where(c => perimeter.Guids.Contains(c.ObjectGuid.ToString("D"), StringComparer.Ordinal)),
            _ => Enumerable.Empty<DirectoryComputer>(),
        };
        return selected.OrderBy(c => c.Name, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The published answer of a command (Domenia 1 New-DomeniaAutomationEnvelope): contract, command, date of the read,
    /// source, perimeter, limit, count, truncation, items and the meaning of the data. JSON, indented.
    /// </summary>
    public static string Envelope(AutomationRequest request, object source, IReadOnlyList<object> items, bool truncated, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(items);
        var envelope = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["Contract"] = ContractName,
            ["Command"] = request.Command,
            ["GeneratedUtc"] = now.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
            ["Source"] = source,
            ["Perimeter"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["Kind"] = request.Perimeter.Kind,
                ["OrganizationalUnit"] = request.Perimeter.OrganizationalUnit,
                ["Computers"] = request.Perimeter.Computers,
                ["Guids"] = request.Perimeter.Guids,
            },
            ["Limit"] = request.Limit,
            ["Count"] = items.Count,
            ["Truncated"] = truncated,
            ["Items"] = items,
            ["Meaning"] = Meaning,
        };
        return JsonSerializer.Serialize(envelope, IndentedJson);
    }

    /// <summary>Items of a « postes » answer (no secret, no internal field).</summary>
    public static IReadOnlyList<object> ComputerItems(IEnumerable<AutomationComputerRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return [.. rows.Select(r => (object)new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["Guid"] = r.Guid,
            ["Nom"] = r.Name,
            ["DNS"] = r.DnsHostName,
            ["DN"] = r.Dn,
            ["Etat"] = r.Enabled ? "Activé" : "Désactivé",
            ["Systeme"] = r.OperatingSystem,
            ["DerniereConnexion"] = r.LastLogon?.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
        })];
    }

    /// <summary>Same CSV as the exports of Domenia (Domenia 1 ConvertTo-DomeniaAutomationCsv): semicolon, quoted, neutralized.</summary>
    public static string ComputerCsv(IEnumerable<AutomationComputerRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        string[] headers = ["Guid", "Nom", "DNS", "DN", "Etat", "Systeme", "DerniereConnexion"];
        var builder = new StringBuilder();
        builder.Append(string.Join(';', headers.Select(h => "\"" + h + "\""))).Append("\r\n");
        foreach (var r in rows)
        {
            string?[] cells = [r.Guid, r.Name, r.DnsHostName, r.Dn, r.Enabled ? "Activé" : "Désactivé", r.OperatingSystem, r.LastLogon?.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture)];
            builder.Append(string.Join(';', cells.Select(c => "\"" + ShellCsv.Neutralize(c ?? "").Replace("\"", "\"\"", StringComparison.Ordinal) + "\""))).Append("\r\n");
        }
        return builder.ToString();
    }

    private static readonly JsonSerializerOptions IndentedJson = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    [GeneratedRegex(@"^[a-z0-9][a-z0-9_-]{0,62}$")]
    private static partial Regex ComputerName();

    [GeneratedRegex(@"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")]
    private static partial Regex GuidText();

    [GeneratedRegex(@"\s*,\s*")]
    private static partial Regex AroundCommas();

    [GeneratedRegex(@"\s*=\s*")]
    private static partial Regex AroundEquals();

    [GeneratedRegex(@"^(?i)((OU|CN)=[^,=]+,)*(DC=[^,=]+)(,DC=[^,=]+)*$")]
    private static partial Regex BranchDn();

    [GeneratedRegex(@"^(?i)(OU|DC)=")]
    private static partial Regex BranchStart();
}
