using Domenia.Bridge.Operations.Requetes;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.App;

/// <summary>Explicit local board migration. Simulation/capture/E2E never read the operator's D1 settings.</summary>
public sealed class LegacyBoardHostOperations : IOperationModule
{
    public string Screen => "shell";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        var available = context.Mode == AppMode.Directory && context.Preferences.Persistent
            && context.Preferences is IConditionalPreferenceStore && AppPaths.UserData is not null;
        LegacyBoardPreview Read(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (!available)
            {
                return new(null, null, [], [], Available: false,
                    Reason: "La migration D1 est disponible avec les préférences persistantes du mode annuaire, hors capture et essai isolé.");
            }
            var preview = LegacyBoardLayoutFile.Read(AppPaths.AppDirectory, AppPaths.UserData!, token,
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            var fleetChoice = LegacyBoardLayouts.HasFleetChoice(context.Preferences);
            return preview with { FleetChoiceExists = fleetChoice, Boards = [.. preview.Boards.Select(b => b with
                { ChoiceExists = b.Board == "Fleet" ? fleetChoice : PosteBoardLayouts.HasChoice(context.Preferences, b.Board) })] };
        }
        async Task<LegacyBoardPreview> ReadPreview(CancellationToken token)
        {
            var preview = await Task.Run(() => Read(token), token).ConfigureAwait(false);
            if (!preview.Boards.Any(b => b.State == "needsQueryBinding")) { return preview; }
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var root = session.Domain?.RootDn ?? throw new InvalidDataException("Domaine local absent pour qualifier les requêtes historiques.");
            var content = await RequetesServices.Library(context).ReadAsync(root, token).ConfigureAwait(false);
            return LegacyBoardLayouts.BindQueries(preview, content, root);
        }
        return
        [
            new OperationDefinition("shell.interface.compatibility.preview", OperationClass.LocalRead, async (args, _, token) =>
            {
                BridgeArguments.RequireNone(args);
                if (!available) return new LegacyCompatibilityPreview(false, null, [], "", "Copies de compatibilité disponibles uniquement en mode annuaire avec préférences persistantes.");
                return await Task.Run(() => LegacyCompatibilityFiles.Preview(AppPaths.AppDirectory, AppPaths.UserData!, token), token).ConfigureAwait(false);
            }, "Inspecte cinq copies de compatibilité ADCC/D1 fermées, sans créer ni modifier un fichier."),
            new OperationDefinition("shell.interface.compatibility.apply", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "fingerprint"]);
                var id = BridgeArguments.GetString(values, "id");
                var fingerprint = BridgeArguments.GetString(values, "fingerprint");
                if (!available) throw new DomeniaOperationException("migration.unavailable", "Copie de compatibilité indisponible dans ce mode.");
                if (fingerprint.Length != 64 || !fingerprint.All(c => char.IsAsciiHexDigit(c))) throw BridgeArguments.Invalid("Empreinte de l’aperçu attendue.");
                return await Task.Run(() => LegacyCompatibilityFiles.Apply(AppPaths.AppDirectory, AppPaths.UserData!, id, fingerprint, token), token).ConfigureAwait(false);
            }, "Copie un fichier de compatibilité validé seulement vers une destination absente ; conserve l’original et relit la copie."),
            new OperationDefinition("shell.interface.migration.preview", OperationClass.LocalRead, async (args, _, token) =>
            {
                BridgeArguments.RequireNone(args);
                return await ReadPreview(token).ConfigureAwait(false);
            }, "Prévisualise les dispositions D1 locales du parc, des postes et des logiciels ; ne modifie aucun fichier."),
            new OperationDefinition("shell.interface.migrate", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["sourceSha256", "board", "configurationSha256", "queryBindingsSha256"]);
                var sha = BridgeArguments.GetString(values, "sourceSha256");
                var board = values.ContainsKey("board") ? BridgeArguments.GetString(values, "board") : "Fleet";
                var querySha = values.ContainsKey("queryBindingsSha256") ? BridgeArguments.GetString(values, "queryBindingsSha256") : null;
                var configurationSha = values.ContainsKey("configurationSha256") ? BridgeArguments.GetString(values, "configurationSha256") : null;
                if (board is not ("Fleet" or "Computer" or "Software")) { throw BridgeArguments.Invalid("Tableau historique inconnu."); }
                if (!available) { throw new DomeniaOperationException("migration.unavailable", "Migration D1 indisponible dans ce mode."); }
                if (sha.Length != 64 || !sha.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')))
                { throw BridgeArguments.Invalid("Empreinte de l’aperçu D1 attendue."); }
                if (querySha is not null && (querySha.Length != 64 || !querySha.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'))))
                { throw BridgeArguments.Invalid("Empreinte des liaisons de requêtes attendue."); }
                if (configurationSha is not null && (configurationSha.Length != 64 || !configurationSha.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'))))
                { throw BridgeArguments.Invalid("Empreinte de la disposition d’équipe attendue."); }
                // Re-read the same ordered local sources; the browser supplies no path and never supplies imported preference bytes.
                var preview = await ReadPreview(token).ConfigureAwait(false);
                bool applied;
                try
                {
                    applied = await LegacyBoardLayouts.ApplyAsync(preview, board, sha, (IConditionalPreferenceStore)context.Preferences,
                        context.Clock.GetUtcNow(), token, configurationSha, ct =>
                        {
                            // The destination mutex has now been acquired. Detect a new higher-priority settings file too.
                            var current = ReadPreview(ct).GetAwaiter().GetResult();
                            LegacyBoardLayouts.ConfirmPreview(preview, current, board);
                            return LegacyBoardLayoutFile.HoldSources(current, board, ct);
                        }, querySha).ConfigureAwait(false);
                }
                finally
                {
                    // A late cancellation can arrive just after the atomic commit. The consumer must reread that durable state too.
                    if (board == "Fleet") { AccueilService.From(context).ReloadStoredLayout(); }
                }
                return new
                {
                    applied,
                    summary = applied ? "Disposition importée dans " + (board == "Fleet" ? "Accueil" : board == "Computer" ? "Poste" : "Logiciels") + ". Texte D1 et provenance conservés."
                        : "Un choix D2 ou une migration existe déjà ; aucune disposition n’a été remplacée, même vide.",
                };
            }, "Importe explicitement la disposition du tableau choisi si aucun choix D2 n’existe, avec provenance ; préserve les originaux D1."),
        ];
    }
}
