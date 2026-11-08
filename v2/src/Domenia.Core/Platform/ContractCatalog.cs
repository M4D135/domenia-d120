using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core;

public enum ContractReadDecision { Read, Migrate, Unreadable, Unexpected, Unknown, Newer, TooOld }
public sealed record DocumentContract(string Id, string Label, string Current, ImmutableArray<string> Readable, string Migration);
public sealed record ContractReadVerdict(ContractReadDecision Decision, string Message)
{
    public bool Allowed => Decision is ContractReadDecision.Read or ContractReadDecision.Migrate;
}

/// <summary>Closed version admission. This never replaces each owner's bounded payload/schema validation.</summary>
public static class ContractCatalog
{
    public static ImmutableArray<DocumentContract> All { get; } =
    [
        new("query", "Requête", QueryRecipe.FormatV4, [QueryRecipe.FormatV1, QueryRecipe.FormatV2, QueryRecipe.FormatV3, QueryRecipe.FormatV4], "Lecture normalisée en mémoire ; source conservée."),
        new("queryLibrary", "Bibliothèque", QueryLibrary.DocumentFormat + "/" + QueryLibrary.DocumentVersion, ["domenia.queryLibrary/1", "domenia.queryLibrary/2", "domenia.queryLibrary/3", "domenia.queryLibrary/4"], "Écriture courante seulement avec reçu durable."),
        new("queryPack", "Pack de requêtes", QueryLibrary.PackFormat, ["Domenia.QueryPack/1", "Domenia.QueryPack/2", QueryLibrary.PackFormat], "Aperçu et confirmation d’import requis."),
        new("referencePatch", "Liaisons de requêtes", QueryReferenceCodec.Format, [QueryReferenceCodec.Format], "Aucune migration."),
        new("wmi", "Lecture WMI", WqlRules.ReadFormat, [WqlRules.ReadFormat], "Aucune migration."),
        new("personalProbes", "Sondes personnelles", PersonalProbeCatalog.Format, [PersonalProbeCatalog.Format], "Aucune migration."),
        new("board", "Disposition", BoardLayoutTransfer.Format, ["Domenia.BoardLayout.1", BoardLayoutTransfer.Format], "Aperçu explicite ; liaisons de requêtes vérifiées."),
        new("localPreferences", "Préférences du poste", "domenia.preferences/1", ["domenia.preferences/1"], "Version future protégée contre toute rétrogradation."),
        new("legacyQueryLibrary", "Bibliothèque Domenia 1", "Domenia.QueryLibrary/1", ["Domenia.QueryLibrary/1"], "Import explicite ; source d’origine conservée."),
        new("queryImplementation", "Moteur de requêtes livré", "Domenia.QueryImplementation/1", ["Domenia.QueryImplementation/1"], "Manifeste livré vérifié ; aucun moteur externe chargé."),
        new("collectionRun", "Ancien journal de collecte", "Domenia.CollectionRun/1", ["Domenia.CollectionRun/1"], "Lecture vers le journal courant ; aucune collecte rejouée."),
        new("probeContract", "Contrat de sonde", "Domenia.ProbeContract/1", ["Domenia.ProbeContract/1"], "Contrat calculé et validé dans le code ; pas d’import exécutable."),
        new("remoteRead", "Rapport distant", "Domenia.RemoteRead/1", ["Domenia.RemoteRead/1"], "Validation du plan, de l’identité et du nonce avant lecture."),
        new("fleetRows", "Pages du parc local", "Domenia.FleetRows/1", ["Domenia.FleetRows/1"], "Identité, génération et empreinte vérifiées avant projection."),
        new("campaignTargets", "Pages de cibles locales", "Domenia.CampaignTargets/1", ["Domenia.CampaignTargets/1"], "Pages liées à la base et au manifeste de campagne."),
        new("suite", "Application associée", "DomeniaSuiteContract/1", ["DomeniaSuiteContract/1"], "Lecture des capacités déclarées ; aucun lancement par lecture."),
        new("preferences", "Préférences exportées", PreferenceTransfer.Format + "/" + PreferenceTransfer.Version, ["domenia.preferencesExport/1"], "Aucune migration."),
        new("backupPreferences", "Annexe de sauvegarde", BackupPreferencesRules.Format, [BackupPreferencesRules.Format], "Aucune migration."),
        new("operations", "Journal des opérations", OperationsDocumentCodec.Format, ["Domenia.Operations/1", OperationsDocumentCodec.Format], "Anciennes opérations lues sans rejouer de tâche."),
        new("campaign", "Plan de campagne", OperationsDocumentCodec.CampaignFormat, [OperationsDocumentCodec.CampaignFormat], "Aucune migration."),
        new("campaignPages", "Cibles paginées", OperationsDocumentCodec.PagedCampaignFormat, [OperationsDocumentCodec.PagedCampaignFormat], "Pages immuables liées à leur base."),
        new("homeCampaign", "Campagne Accueil", OperationsDocumentCodec.HomeFormat, [OperationsDocumentCodec.HomeFormat], "Aucune migration."),
        new("homePages", "Campagne Accueil paginée", OperationsDocumentCodec.PagedHomeFormat, [OperationsDocumentCodec.PagedHomeFormat], "Pages immuables liées à leur base."),
        new("automation", "Automatisation", ShellAutomation.ContractName, [ShellAutomation.ContractName], "Aucune migration ; aucun lancement par lecture."),
        new("dossier", "Dossier hors connexion", OfflineDossiers.Contract, [OfflineDossiers.Contract], "Aucune migration."),
        new("capture", "Capture", CaptureFiles.Format, [CaptureFiles.Format], "Aucune migration."),
        new("diagnostic", "Diagnostic", OperationsDiagnostics.Format, [OperationsDiagnostics.Format], "Anciennes versions conservées en brut, pas réinterprétées."),
        new("ticket", "Ticket", TicketReport.Format, [TicketReport.Format], "Aucune migration."),
    ];

    public static ContractReadVerdict Decide(string expectedId, string? format)
    {
        var expected = All.FirstOrDefault(c => c.Id == expectedId);
        if (expected is null) return new(ContractReadDecision.Unknown, "Contrat inconnu ; aucune lecture.");
        if (string.IsNullOrWhiteSpace(format) || format.Length > 128 || format.Any(char.IsControl))
            return new(ContractReadDecision.Unreadable, "Format illisible ; original conservé.");
        if (expected.Readable.Contains(format, StringComparer.Ordinal))
            return format == expected.Current ? new(ContractReadDecision.Read, "Version courante lisible.")
                : new(ContractReadDecision.Migrate, expected.Migration);
        if (All.Any(c => c.Readable.Contains(format, StringComparer.Ordinal)))
            return new(ContractReadDecision.Unexpected, "Document d’une autre catégorie ; aucune lecture.");
        // Only a known family can be classified as newer/older. No generic parser accepts a guessed version.
        var at = expected.Current.Length;
        while (at > 0 && char.IsAsciiDigit(expected.Current[at - 1])) at--;
        var prefix = expected.Current[..at];
        if (at < expected.Current.Length && format.StartsWith(prefix, StringComparison.Ordinal)
            && long.TryParse(format.AsSpan(at), NumberStyles.None, CultureInfo.InvariantCulture, out var version))
        {
            var current = long.Parse(expected.Current.AsSpan(at), CultureInfo.InvariantCulture);
            return version > current ? new(ContractReadDecision.Newer, "Version plus récente ; mettez Domenia à jour. Aucune projection effectuée.")
                : version < 1 || version < expected.Readable.Select(f => long.TryParse(f.AsSpan(at), out var v) ? v : current).Min()
                    ? new(ContractReadDecision.TooOld, "Version trop ancienne ; original conservé.")
                    : new(ContractReadDecision.Unreadable, "Version non prise en charge ; original conservé.");
        }
        return new(ContractReadDecision.Unknown, "Format inconnu ; aucune lecture.");
    }
}
