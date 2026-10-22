using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>A checked « Domenia.exe dossier » command line, or the reason and exit code of its refusal.</summary>
public sealed record OfflineDossierRequest(
    bool Valid,
    string Error,
    int ExitCode,
    string? OrganizationalUnit,
    ImmutableArray<string> Names,
    ImmutableArray<string> Guids,
    string Output,
    ImmutableArray<string> Sections,
    ImmutableArray<string> Remaining);

/// <summary>
/// Command line of the offline dossier (Domenia 1 « Domenia-Automate.ps1 dossier », Test-DomeniaAutomationRequest):
/// <code>Domenia.exe dossier --sortie &lt;dossier parent&gt; (--ou &lt;DN&gt; | --postes PC-01,PC-02 | --guids &lt;GUID&gt;,…) [--sections observations,associations,requetes] [--simulation]</code>
/// The parameter names of Domenia 1 are accepted too (-OutputPath, -OrganizationalUnit, -Computers, -Guids, -Sections). One
/// perimeter exactly, never the whole domain, 500 workstations at most. Exit codes of Domenia 1: 0 success, 2 invalid command
/// or parameter, 3 local base absent or unreadable, 4 refusal (no perimeter), 5 the result cannot be written. Pure rules.
/// </summary>
public static partial class OfflineDossierCommand
{
    public const string Name = "dossier";
    public const int Success = 0;
    public const int Invalid = 2;
    public const int BaseUnavailable = 3;
    public const int Refused = 4;
    public const int WriteFailed = 5;

    private static readonly ImmutableArray<string> AllSections = ["etat", "postes", .. OfflineDossiers.OptionalSections];

    /// <summary>True when the first argument asks for the offline dossier command (the window is then never opened).</summary>
    public static bool IsRequested(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        return args.Count > 0 && string.Equals(args[0], Name, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Reads the arguments after « dossier »; <see cref="OfflineDossierRequest.Remaining"/> keeps « --simulation » for the mode resolver.</summary>
    public static OfflineDossierRequest Parse(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        string? ou = null;
        string? output = null;
        var names = new List<string>();
        var guids = new List<string>();
        var sections = new List<string>();
        var remaining = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var i = IsRequested(args) ? 1 : 0; i < args.Count; i++)
        {
            var argument = args[i] ?? "";
            var option = Option(argument);
            if (option == "simulation")
            {
                remaining.Add(argument);
                continue;
            }
            if (option is null)
            {
                return Refuse("Argument inattendu" + FrenchText.Colon + FrenchText.Quote(Bounded(argument)) + ".", Invalid);
            }
            if (option == "unknown")
            {
                return Refuse("Option inconnue" + FrenchText.Colon + FrenchText.Quote(Bounded(argument))
                    + ". Options" + FrenchText.Colon + "--sortie, --ou, --postes, --guids, --sections, --simulation.", Invalid);
            }
            if (option == "database")
            {
                return Refuse("La base locale est celle de Domenia" + FrenchText.Colon + "-DatabasePath (base de Domenia" + FrenchText.Nbsp + "1) n’est pas lue par cette version.", BaseUnavailable);
            }
            if (!seen.Add(option))
            {
                return Refuse("Option répétée" + FrenchText.Colon + FrenchText.Quote(Bounded(argument)) + ".", Invalid);
            }
            if (i + 1 >= args.Count || Option(args[i + 1] ?? "") is not null)
            {
                return Refuse("Valeur attendue après " + FrenchText.Quote(Bounded(argument)) + ".", Invalid);
            }
            var value = (args[++i] ?? "").Trim();
            switch (option)
            {
                case "output":
                    output = value;
                    break;
                case "ou":
                    ou = value;
                    break;
                case "names":
                    names.AddRange(Split(value));
                    break;
                case "guids":
                    guids.AddRange(Split(value));
                    break;
                default:
                    sections.AddRange(Split(value));
                    break;
            }
        }
        var cleanNames = new List<string>();
        foreach (var raw in names)
        {
            var name = raw.TrimEnd('$');
            var dot = name.IndexOf('.', StringComparison.Ordinal);
            name = (dot > 0 ? name[..dot] : name).ToLowerInvariant();
            if (!ComputerName().IsMatch(name))
            {
                return Refuse("Nom de poste invalide" + FrenchText.Colon + FrenchText.Quote(Bounded(raw)) + ".", Invalid);
            }
            if (!cleanNames.Contains(name))
            {
                cleanNames.Add(name);
            }
        }
        var cleanGuids = new List<string>();
        foreach (var raw in guids)
        {
            if (!Guid.TryParse(raw.Trim('{', '}'), out var guid) || guid == Guid.Empty)
            {
                return Refuse("GUID invalide" + FrenchText.Colon + FrenchText.Quote(Bounded(raw)) + ".", Invalid);
            }
            var text = guid.ToString("D");
            if (!cleanGuids.Contains(text))
            {
                cleanGuids.Add(text);
            }
        }
        if (cleanNames.Count + cleanGuids.Count > OfflineDossiers.MaxNames)
        {
            return Refuse(FrenchText.Integer(OfflineDossiers.MaxNames) + " postes au plus par commande" + FrenchText.Colon + "choisissez une OU ou découpez la liste.", Invalid);
        }
        if (ou is not null && !IsOrganizationalUnit(ou))
        {
            return Refuse("OU non reconnue" + FrenchText.Colon + FrenchText.Quote(Bounded(ou)) + " (OU=…,DC=… attendu).", Invalid);
        }
        var kinds = (ou is null ? 0 : 1) + (cleanNames.Count > 0 ? 1 : 0) + (cleanGuids.Count > 0 ? 1 : 0);
        if (kinds > 1)
        {
            return Refuse("Un seul périmètre à la fois" + FrenchText.Colon + "OU, noms ou GUID.", Invalid);
        }
        var chosen = new List<string>();
        foreach (var raw in sections)
        {
            var section = raw.ToLowerInvariant();
            if (!AllSections.Contains(section))
            {
                return Refuse("Section de dossier inconnue" + FrenchText.Colon + FrenchText.Quote(Bounded(raw)) + ".", Invalid);
            }
            if (!chosen.Contains(section))
            {
                chosen.Add(section);
            }
        }
        if (string.IsNullOrWhiteSpace(output))
        {
            return Refuse("Dossier de destination requis" + FrenchText.Colon + "--sortie <dossier parent>.", Invalid);
        }
        if (kinds == 0)
        {
            return Refuse("Périmètre requis" + FrenchText.Colon + "--ou, --postes ou --guids. Aucune commande ne parcourt tout le domaine implicitement.", Refused);
        }
        // Without --sections every optional section is written, as in Domenia 1.
        var optional = chosen.Count == 0 ? OfflineDossiers.OptionalSections : [.. OfflineDossiers.OptionalSections.Where(chosen.Contains)];
        return new OfflineDossierRequest(true, "", Success, ou, [.. cleanNames], [.. cleanGuids], output.Trim(), optional, [.. remaining]);
    }

    private static OfflineDossierRequest Refuse(string why, int code) => new(false, why, code, null, [], [], "", [], []);

    /// <summary>Canonical option name, « unknown » for an option this command does not have, or null for a value.</summary>
    private static string? Option(string argument)
    {
        if (!argument.StartsWith('-'))
        {
            return null;
        }
        return argument.TrimStart('-').ToLowerInvariant() switch
        {
            "simulation" => "simulation",
            "sortie" or "outputpath" => "output",
            "ou" or "organizationalunit" => "ou",
            "postes" or "computers" => "names",
            "guids" => "guids",
            "sections" => "sections",
            "databasepath" => "database",
            _ => "unknown",
        };
    }

    private static IEnumerable<string> Split(string value) =>
        value.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string Bounded(string text) => text.Length > 80 ? text[..79] + "…" : text;

    private static bool IsOrganizationalUnit(string dn)
    {
        if (!dn.StartsWith("OU=", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        try
        {
            var parts = DistinguishedName.Parse(dn);
            return parts.Any(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase));
        }
        catch (FormatException)
        {
            return false;
        }
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9_-]{0,62}$", RegexOptions.CultureInvariant, 100)]
    private static partial Regex ComputerName();
}
