using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Session-only launch overrides. No option binds, reads the directory or changes a preference.</summary>
public sealed record LaunchOptions(string? Server = null, string? BaseDn = null, int? DefaultLimit = null, bool NoAutoConnect = false)
{
    public static LaunchOptions Default { get; } = new();
}

public sealed record LaunchArgumentResult(bool Valid, string? Error, LaunchOptions Options, ImmutableArray<string> Remaining);

/// <summary>TRV-038: bounded launch arguments, with the original PowerShell spellings accepted as aliases.</summary>
public static class LaunchArguments
{
    public static LaunchArgumentResult Parse(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (args.Count > 128 || args.Any(a => a is null || a.Length > 4096)) { return Refuse("Arguments de lancement trop volumineux."); }
        var remaining = ImmutableArray.CreateBuilder<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        string? server = null, baseDn = null;
        int? limit = null;
        var noAutoConnect = false;
        for (var i = 0; i < args.Count; i++)
        {
            var key = args[i].ToLowerInvariant() switch
            {
                "--server" or "-server" => "server",
                "--base" or "--search-base" or "-searchbase" => "base",
                "--default-limit" or "-defaultlimit" => "limit",
                "--no-auto-connect" or "-noautoconnect" => "noAutoConnect",
                _ => null,
            };
            if (key is null) { remaining.Add(args[i]); continue; }
            if (!seen.Add(key)) { return Refuse("Option de lancement répétée ; une seule valeur par option est acceptée."); }
            if (key == "noAutoConnect") { noAutoConnect = true; continue; }
            if (++i >= args.Count || args[i].StartsWith('-')) { return Refuse("Valeur manquante pour une option de lancement."); }
            var value = args[i].Trim();
            switch (key)
            {
                case "server":
                    if (!ValidServer(value)) { return Refuse("Serveur invalide : nom DNS de contrôleur attendu, sans port, chemin ni identifiant."); }
                    server = value;
                    break;
                case "base":
                    if (!ValidBase(value)) { return Refuse("Base de recherche invalide : DN d’une OU ou d’un domaine attendu."); }
                    baseDn = DistinguishedName.Format(DistinguishedName.Parse(value));
                    break;
                case "limit":
                    if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number is < 1 or > SearchLimits.MaxLimit)
                    { return Refuse("Limite de lancement attendue : entier de 1 à 20 000."); }
                    limit = number;
                    break;
            }
        }
        return new(true, null, new(server, baseDn, limit, noAutoConnect), remaining.ToImmutable());
    }

    private static bool ValidServer(string value) => value.Length is > 0 and <= 253 && !value.All(c => char.IsAsciiDigit(c) || c == '.')
        && value.Split('.').All(label => label.Length is > 0 and <= 63 && char.IsAsciiLetterOrDigit(label[0])
            && char.IsAsciiLetterOrDigit(label[^1]) && label.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'));

    private static bool ValidBase(string value)
    {
        if (value.Length is 0 or > 2048 || value.Any(char.IsControl)) { return false; }
        try
        {
            var parts = DistinguishedName.Parse(value);
            return parts.Length > 0 && (parts[0].Type.Equals("OU", StringComparison.OrdinalIgnoreCase)
                || parts[0].Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                && parts.Any(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                && parts.All(p => p.Type.Equals("OU", StringComparison.OrdinalIgnoreCase)
                    || p.Type.Equals("CN", StringComparison.OrdinalIgnoreCase) || p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                && parts.SkipWhile(p => !p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).All(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase));
        }
        catch (FormatException) { return false; }
    }

    private static LaunchArgumentResult Refuse(string error) => new(false, error, LaunchOptions.Default, []);
}
