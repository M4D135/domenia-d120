using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Reads of the shell served by the directory source of the mode (docs/ops/shell.md): the embedded object picker, the check of
/// a picked object, the coverage of the demonstration directory and the workstations of an automation preview. Served by the
/// simulation today, by Domenia.Ad and the local base later (wave 3). Read only.
/// </summary>
public interface IShellReader : IScreenReader
{
    /// <summary>Objects whose names, account, principal name, mail or DNS name contain the text (accents and case ignored).</summary>
    Task<ShellLookupResult> LookupAsync(string text, IReadOnlySet<ShellLookupKind> kinds, int limit, CancellationToken cancellationToken);

    /// <summary>Checks that a picked object still exists with this DN and this GUID (moved, missing or refused otherwise).</summary>
    Task<ShellLookupCheck> VerifyAsync(string dn, Guid objectGuid, CancellationToken cancellationToken);

    /// <summary>What the demonstration directory holds, category by category (simulation only).</summary>
    Task<ShellDemoCoverage> CoverageAsync(CancellationToken cancellationToken);

    /// <summary>Workstations of an automation perimeter, at most <paramref name="limit"/> plus one (truncation signal).</summary>
    Task<ImmutableArray<AutomationComputerRow>> ComputersAsync(AutomationPerimeter perimeter, int limit, CancellationToken cancellationToken);
}

/// <summary>Error codes and messages of the shell operations (docs/ops/shell.md § « Erreurs »).</summary>
public static class ShellErrors
{
    public const string LookupDenied = "lookup.denied";
    public const string LookupDeniedMessage = "Accès refusé pour ce compte : cet objet ne peut pas être choisi. Choisissez-en un autre ou utilisez un compte qui a le droit de le lire.";

    public const string ExportUnavailable = "export.unavailable";
    public const string ExportUnavailableMessage = "Export impossible : le dossier des exports n’a pas pu être écrit. Rien n’a été laissé de partiel.";

    public const string FileRefused = "file.refused";
    public const string FileRefusedMessage = "Fichier refusé : choisissez un fichier local de la liste (ni partage réseau, ni lecteur mappé, ni lien).";

    public const string FileUnreadable = "file.unreadable";
    public const string FileUnreadableMessage = "Fichier illisible pour l’instant : il est peut-être ouvert ailleurs ou trop volumineux (1 Mo au plus).";

    public const string GuideMissing = "guide.missing";

    public const string FolderUnavailable = "folder.unavailable";
    public const string FolderUnavailableMessage = "Dossier indisponible : il n’existe plus ou ne peut pas être lu.";
}
