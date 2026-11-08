using System.Globalization;

namespace Domenia.Core.Accueil;

public static partial class ProbeCatalog
{
    /// <summary>Resolve only the two declared rolling windows, in UTC DMTF form, immediately before the read.</summary>
    public static string ResolveFilter(string filter, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(filter);
        if (filter.Length > 512 || filter.Any(char.IsControl) || !FilterPattern().IsMatch(filter) || now.UtcDateTime < DateTime.MinValue.AddDays(7))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Filtre de sonde ou date de lecture invalide ; aucun contact."); }
        string Since(int days) => now.UtcDateTime.AddDays(-days).ToString("yyyyMMddHHmmss.ffffff'+000'", CultureInfo.InvariantCulture);
        var resolved = filter.Replace("{SINCE_24H}", Since(1), StringComparison.Ordinal)
            .Replace("{SINCE_7D}", Since(7), StringComparison.Ordinal);
        if (resolved.Contains('{', StringComparison.Ordinal) || resolved.Contains('}', StringComparison.Ordinal))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Jeton de filtre inconnu ou incomplet ; aucun contact."); }
        return resolved;
    }
}
