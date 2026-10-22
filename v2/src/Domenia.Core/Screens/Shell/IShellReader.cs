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

    /// <summary>
    /// The OU of this DN with its GUID, so that the OU picker can check DN and GUID again before handing the choice over
    /// (« ok », « missing » or « denied »). An object of the DN that is not an OU answers « missing ».
    /// </summary>
    Task<ShellLookupCheck> ResolveOuAsync(string dn, CancellationToken cancellationToken);

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

    public const string FileExists = "file.exists";
    public const string FileExistsMessage = "Un fichier de ce nom existe déjà dans ce dossier : choisissez « Remplacer » dans le sélecteur, ou un autre nom.";

    public const string FileChanged = "file.changed";
    public const string FileChangedMessage = "Le fichier à remplacer a changé depuis votre choix (taille ou date) : rien n’a été écrit. Choisissez-le de nouveau.";

    public const string ExportTooLarge = "export.tooLarge";
    public const string ExportTooLargeMessage = "Export refusé : la liste dépasse 200 000 lignes ou 1 000 colonnes. Filtrez-la avant d’exporter.";

    public const string ShareTimeout = "share.timeout";
    public const string ShareTimeoutMessage = "Le partage n’a pas répondu dans les 15 secondes : il est lent ou injoignable. Rien n’a été relancé.";

    public const string ShareRefused = "share.refused";
    public const string ShareRefusedMessage = "Partage refusé : saisissez le chemin complet d’un dossier partagé (\\\\serveur\\partage\\dossier), ni périphérique, ni lien, ni « .. ».";
}
