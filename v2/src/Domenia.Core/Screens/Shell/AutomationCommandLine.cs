using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

public sealed record AutomationInvocation(bool Valid, string? Error, int ExitCode, AutomationRequest? Request,
    string? DatabasePath, string? OutputPath, string? Family);

/// <summary>Closed, side-effect-free command-line grammar. A local base is explicit; it never resolves a profile or an AD identity.</summary>
public static partial class AutomationCommandLine
{
    public static bool IsRequested(IReadOnlyList<string> args) => args.Count > 0 && !args[0].StartsWith('-')
        && !OfflineDossierCommand.IsRequested(args);

    public static AutomationInvocation Parse(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        static AutomationInvocation Refuse(string reason, int code = 2) => new(false, reason, code, null, null, null, null);
        if (args.Count == 0 || args.Count > 32 || args.Any(a => a is null || a.Length > 32_768 || a.Any(char.IsControl)))
            return Refuse("Ligne de commande absente ou hors limites.");
        var command = args[0].ToLowerInvariant();
        if (command is not ("version" or "etat" or "postes" or "observations" or "associations" or "requetes"))
            return Refuse("Commande inconnue. Utilisez version, etat, postes, observations, associations, requetes ou dossier.");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Count; index++)
        {
            var name = args[index].ToLowerInvariant() switch
            {
                "--base" or "-databasepath" => "database",
                "--sortie" or "-outputpath" => "output",
                "--ou" or "-organizationalunit" => "ou",
                "--postes" or "-computers" => "computers",
                "--guids" or "-guids" => "guids",
                "--limite" or "--limit" or "-limit" => "limit",
                "--format" or "-format" => "format",
                "--famille" or "--family" or "-family" => "family",
                _ => null,
            };
            if (name is null || index + 1 >= args.Count || args[index + 1].StartsWith('-'))
                return Refuse("Option inconnue ou valeur manquante. Aucun profil, service ou accès annuaire n’a été ouvert.");
            if (!values.TryAdd(name, args[++index].Trim())) return Refuse("Une option apparaît plusieurs fois ; commande refusée.");
        }
        string? Value(string name) => values.GetValueOrDefault(name);
        var limit = 0;
        if (Value("limit") is { } raw && (!int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out limit) || limit < 0))
            return Refuse("La limite doit être un entier de 0 à 5 000 (0 conserve le défaut de 1 000).");
        var (request, error, code) = ShellAutomation.Validate(command, Value("ou"),
            Value("computers") is { } computers ? [computers] : [], Value("guids") is { } guids ? [guids] : [], limit, Value("format"));
        if (request is null) return Refuse(error ?? "Commande refusée.", code);
        var database = Value("database");
        if (command == "version" && (database is not null || request.Perimeter.Kind != "Aucun" || Value("family") is not null))
            return Refuse("La commande version ne lit aucune base ni aucun périmètre.");
        if (command is "etat" or "requetes" && request.Perimeter.Kind != "Aucun")
            return Refuse("Cette commande décrit la base locale ; elle n’accepte pas de filtre de postes ignoré.");
        if (command != "version" && (string.IsNullOrWhiteSpace(database) || !database.EndsWith(".db", StringComparison.OrdinalIgnoreCase)))
            return Refuse("Base locale explicite requise : --base <fichier.db> (ou -DatabasePath).");
        var family = Value("family");
        if (family is not null && (command != "observations" || !ObservationFamily().IsMatch(family)))
            return Refuse("Famille réservée aux observations : Presence, Console, Inventory ou Probe:<identifiant>.");
        if (Value("output") is { Length: 0 }) return Refuse("Fichier de sortie vide.");
        return new(true, null, 0, request, database, Value("output"), family);
    }

    [GeneratedRegex("^(Presence|Console|Inventory|Probe:[A-Za-z0-9_.-]{1,128})$", RegexOptions.CultureInvariant, 100)]
    private static partial Regex ObservationFamily();
}
