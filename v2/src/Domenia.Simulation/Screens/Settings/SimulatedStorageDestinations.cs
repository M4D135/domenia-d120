using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>Invented destinations for the real storage plan rules. Never inspects a disk or resolves a supplied path.</summary>
public static class SimulatedStorageDestinations
{
    public const string Root = @"D:\Domenia-Fictif";
    public static DestinationProposal Proposal(TimeProvider clock) => new(
        StorageWritePlans.ExportFileName(clock.GetUtcNow(), clock.LocalTimeZone), Root + @"\Sauvegardes",
        [new("fiction", "Démonstration — disque fictif", Root), new("backup", "Sauvegardes fictives", Root + @"\Sauvegardes")]);

    public static FolderListing Browse(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return new(null, null, [new("Disque fictif", Root)], false, "Démonstration — aucun disque réel parcouru.");
        if (string.Equals(path.TrimEnd('\\'), Root, StringComparison.OrdinalIgnoreCase))
            return new(Root, null, [new("Sauvegardes fictives", Root + @"\Sauvegardes")], false, "Démonstration — dossier fictif.");
        if (string.Equals(path.TrimEnd('\\'), Root + @"\Sauvegardes", StringComparison.OrdinalIgnoreCase))
            return new(Root + @"\Sauvegardes", Root, [], false, "Démonstration — aucun sous-dossier.");
        throw new DomeniaOperationException(StorageWritePlans.DestinationRefused, "Choisissez le disque fictif ; aucun dossier réel n’est parcouru en démonstration.");
    }

    public static DestinationFacts Facts(string? destination)
    {
        var path = destination?.Trim() ?? "";
        var last = path.LastIndexOf('\\');
        var folder = last >= 0 ? path[..last] : "";
        var known = string.Equals(folder, Root, StringComparison.OrdinalIgnoreCase)
            || string.Equals(folder, Root + @"\Sauvegardes", StringComparison.OrdinalIgnoreCase);
        return new(known, known, false, false, known ? 240L * 1024 * 1024 * 1024 : null);
    }
}
