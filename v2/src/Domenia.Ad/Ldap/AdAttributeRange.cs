using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Strict LDAP range syntax and continuity checks shared by automatic and explicit range readers.</summary>
internal sealed record AdAttributeRange(string Attribute, int Start, int? End)
{
    internal static bool TryParse(string name, out AdAttributeRange? range)
    {
        range = null;
        var parts = name.Split(';');
        if (parts.Length != 2 || !FicheAttributeRules.IsValidName(parts[0]) || !parts[1].StartsWith("range=", StringComparison.OrdinalIgnoreCase)) { return false; }
        var bounds = parts[1][6..].Split('-');
        if (bounds.Length != 2 || !int.TryParse(bounds[0], NumberStyles.None, CultureInfo.InvariantCulture, out var start)) { return false; }
        int? end = null;
        if (bounds[1] != "*")
        {
            if (!int.TryParse(bounds[1], NumberStyles.None, CultureInfo.InvariantCulture, out var last) || last < start || last == int.MaxValue) { return false; }
            end = last;
        }
        range = new(parts[0], start, end);
        return true;
    }

    internal void Validate(int expectedStart, int count, int totalBefore, int maximum)
    {
        var category = Start != expectedStart ? "plage-discontinue"
            : count < 0 || totalBefore < 0 || totalBefore > maximum || count > maximum - totalBefore ? "limite-valeurs"
            : End is { } end && (end - Start + 1 != count || count == 0) ? "nombre-valeurs-incohérent"
            : End is not null && totalBefore + count == maximum ? "limite-sans-plage-terminale" : null;
        if (category is not null)
        { throw AdReadDiagnostics.Refuse(category, Attribute, expectedStart, maximum - 1, Start, End, End is null, count, totalBefore, maximum); }
    }

    /// <summary>MS-ADTS permits an empty unqualified attribute alongside its ranged value, in either order.</summary>
    internal static string[] ValueNames(AdEntry entry, string attribute)
    {
        var names = entry.AttributeNames.Where(n => n.Equals(attribute, StringComparison.OrdinalIgnoreCase)
            || n.StartsWith(attribute + ";", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (names.Length > 1 && names.Any(n => TryParse(n, out _)) && !entry.Has(attribute))
        { return names.Where(n => !n.Equals(attribute, StringComparison.OrdinalIgnoreCase)).ToArray(); }
        return names;
    }

    internal static DomeniaOperationException Incomplete() => new(DomeniaErrors.SourceUnavailable,
        "Attribut LDAP tronqué, modifié pendant la lecture ou hors limites : aucune valeur incomplète publiée comme complète.");
}
