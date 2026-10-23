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
        if (Start != expectedStart || count < 0 || totalBefore < 0 || totalBefore > maximum || count > maximum - totalBefore
            || End is { } end && (end - Start + 1 != count || count == 0 || totalBefore + count == maximum))
        { throw Incomplete(); }
    }

    internal static DomeniaOperationException Incomplete() => new(DomeniaErrors.SourceUnavailable,
        "Attribut LDAP tronqué, modifié pendant la lecture ou hors limites : aucune valeur incomplète publiée comme complète.");
}
