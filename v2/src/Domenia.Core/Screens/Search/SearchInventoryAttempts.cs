using System.Globalization;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>Completed sources of one qualified Survey/SurveyComplete retry sequence. It never consumes a cached
/// snapshot or authorizes another read. A retained source remains dated and partial after a later failed attempt.</summary>
public sealed class SearchInventoryAttempts
{
    private static readonly string[][] Groups =
    [
        [InventoryCategories.System, InventoryCategories.Board], [InventoryCategories.Volumes],
        [InventoryCategories.Network], [InventoryCategories.Bios], [InventoryCategories.Tpm],
        [InventoryCategories.Hotfixes], [InventoryCategories.Services],
    ];
    private readonly Dictionary<string, InventorySnapshot> completed = new(StringComparer.Ordinal);
    private string? computer;

    public InventorySnapshot Preserve(InventorySnapshot current)
    {
        ArgumentNullException.ThrowIfNull(current);
        if (computer is not null && !string.Equals(computer, current.Computer, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Essais d’inventaire de postes différents ; aucune fusion.");
        computer ??= current.Computer;
        var result = current;
        var access = current.Access.ToDictionary(a => a.Category, StringComparer.Ordinal);
        foreach (var categories in Groups)
        {
            var key = categories[0];
            if (categories.All(category => current.StatusOf(category) is SourceStatus.Ok or SourceStatus.Empty))
            {
                completed[key] = current;
                continue;
            }
            if (!completed.TryGetValue(key, out var old) || old.CollectedAt > current.CollectedAt) continue;
            result = Copy(key, old, result);
            // Mixed sources are never made younger than their oldest retained observation. The normal UI already
            // displays this timestamp and every access detail; no old value is presented as freshly re-read.
            if (old.CollectedAt < result.CollectedAt) result = result with { CollectedAt = old.CollectedAt };
            foreach (var category in categories)
            {
                var previous = old.Access.Single(a => a.Category == category);
                var last = current.Access.FirstOrDefault(a => a.Category == category);
                access[category] = previous with
                {
                    Status = SourceStatus.Partial,
                    Detail = "Mesure du " + old.CollectedAt.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)
                        + " conservée ; essai du " + current.CollectedAt.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)
                        + " : " + (last?.Status.ToString() ?? "NonLu") + ". " + (last?.Detail ?? "Source non relue."),
                    AuthenticationRejected = last?.AuthenticationRejected == true,
                    RetryFailure = CollectionReadFailure.Unknown,
                };
            }
        }
        return result with { Access = [.. access.Values] };
    }

    private static InventorySnapshot Copy(string category, InventorySnapshot old, InventorySnapshot current) => category switch
    {
        // Console associations require the latest independent qualification. Keep no old account in this aggregate.
        InventoryCategories.System => current with { Os = old.Os,
            System = old.System is null ? null : old.System with { UserName = current.Console?.Account },
            Memory = old.Memory, ClockSkewSeconds = old.ClockSkewSeconds, ClockAgainstController = old.ClockAgainstController },
        InventoryCategories.Volumes => current with { Volumes = old.Volumes },
        InventoryCategories.Network => current with { Network = old.Network },
        InventoryCategories.Bios => current with { Bios = old.Bios, SecureBoot = old.SecureBoot },
        InventoryCategories.Tpm => current with { Tpm = old.Tpm },
        InventoryCategories.Hotfixes => current with { Hotfixes = old.Hotfixes },
        InventoryCategories.Services => current with { Services = old.Services },
        _ => throw new InvalidOperationException("Source de relevé non déclarée."),
    };
}
