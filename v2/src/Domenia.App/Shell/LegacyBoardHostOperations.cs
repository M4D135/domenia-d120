using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.App;

/// <summary>Explicit local preview and Fleet migration. Simulation/capture/E2E never read the operator's D1 settings.</summary>
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
            return LegacyBoardLayoutFile.Read(AppPaths.AppDirectory, AppPaths.UserData!, token)
                with { FleetChoiceExists = LegacyBoardLayouts.HasFleetChoice(context.Preferences) };
        }
        return
        [
            new OperationDefinition("shell.interface.migration.preview", OperationClass.LocalRead, async (args, _, token) =>
            {
                BridgeArguments.RequireNone(args);
                return await Task.Run(() => Read(token), token).ConfigureAwait(false);
            }, "Prévisualise les dispositions D1 locales du parc, des postes et des logiciels ; ne modifie aucun fichier."),
            new OperationDefinition("shell.interface.migrate", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["sourceSha256"]);
                var sha = BridgeArguments.GetString(values, "sourceSha256");
                if (!available) { throw new DomeniaOperationException("migration.unavailable", "Migration D1 indisponible dans ce mode."); }
                if (sha.Length != 64 || !sha.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')))
                { throw BridgeArguments.Invalid("Empreinte de l’aperçu D1 attendue."); }
                // Re-read the same ordered local sources; the browser supplies no path and never supplies imported preference bytes.
                var preview = await Task.Run(() => Read(token), token).ConfigureAwait(false);
                bool applied;
                try
                {
                    applied = await LegacyBoardLayouts.ApplyFleetAsync(preview, sha, (IConditionalPreferenceStore)context.Preferences,
                        context.Clock.GetUtcNow(), token).ConfigureAwait(false);
                }
                finally
                {
                    // A late cancellation can arrive just after the atomic commit. The consumer must reread that durable state too.
                    AccueilService.From(context).ReloadStoredLayout();
                }
                return new
                {
                    applied,
                    summary = applied ? "Disposition du parc importée dans Accueil. Texte D1 et provenance conservés. Les dispositions Poste et Logiciels restent inchangées."
                        : "Un choix D2 ou une migration existe déjà ; aucune disposition n’a été remplacée, même vide.",
                };
            }, "Importe explicitement la disposition du parc dans Accueil si aucun choix D2 n’existe, avec provenance ; préserve les originaux D1."),
        ];
    }
}
