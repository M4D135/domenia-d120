using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;

namespace Domenia.Bridge;

public sealed class PosteLayoutOperations : IOperationModule
{
    public string Screen => "poste";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
    [
        new("poste.layout.query", OperationClass.LocalRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["dn", "computer", "item"]);
            var dn = BridgeArguments.GetString(values, "dn");
            var id = BridgeArguments.GetString(values, "item");
            if (!Guid.TryParse(BridgeArguments.GetString(values, "computer"), out var guid) || guid == Guid.Empty)
            { throw BridgeArguments.Invalid("Identité exacte du poste attendue."); }
            var layout = await PosteBoardLayouts.ReadLatestAsync(context.Preferences, "Computer", token).ConfigureAwait(false);
            var item = layout.Valid ? layout.Items.SingleOrDefault(i => i.Id == id && i.Source == FleetWidgetSource.Query && !i.Paused) : null;
            if (item?.QueryBinding is null) { throw BridgeArguments.Invalid("Carte absente ou en pause ; aucune requête évaluée."); }
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var root = session.Domain?.RootDn ?? throw BridgeArguments.Invalid("Domaine local absent.");
            var library = await RequetesServices.Library(context).ReadAsync(root, token).ConfigureAwait(false);
            var dataset = await context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(token).ConfigureAwait(false);
            if (!DistinguishedName.AreEqual(root, dataset.Directory.Domain.RootDn))
            { throw BridgeArguments.Invalid("Domaine remplacé pendant la lecture locale."); }
            var after = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            if (after.Domain?.RootDn is not { } currentRoot || !DistinguishedName.AreEqual(root, currentRoot)
                || after.Epoch != session.Epoch || !string.Equals(after.Account.Login, session.Account.Login, StringComparison.OrdinalIgnoreCase)
                || PosteBoardLayouts.Read(context.Preferences, "Computer").Items.SingleOrDefault(i => i.Id == id) != item)
            { throw BridgeArguments.Invalid("Session ou carte modifiée pendant la lecture locale ; relisez le tableau."); }
            token.ThrowIfCancellationRequested();
            var personal = await ProfileProbeCatalog.ReadAsync(context.Preferences, token).ConfigureAwait(false);
            var result = PosteQueryCards.Build(item, library, dataset, guid, dn, context.Clock.GetUtcNow(), personalProbes: personal.Entries);
            token.ThrowIfCancellationRequested();
            return result;
        }, "Calcule la révision explicitement liée à une carte active sur les données locales de ce poste ; aucune collecte.", ServedInSimulation: true),
        new("poste.layout.probe", OperationClass.LocalRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["dn", "computer", "probe", "page"]);
            var dn = BridgeArguments.GetString(values, "dn");
            var key = BridgeArguments.GetString(values, "probe");
            if (!Guid.TryParse(BridgeArguments.GetString(values, "computer"), out var guid) || guid == Guid.Empty
                || !values.TryGetValue("page", out var rawPage) || rawPage.ValueKind != JsonValueKind.Number || !rawPage.TryGetInt32(out var page) || page is < 1 or > 10_000)
            { throw BridgeArguments.Invalid("Identité du poste et page de sonde attendues."); }
            var frozen = (await ProfileProbeCatalog.ResolveAsync(context.Preferences, [key], token).ConfigureAwait(false)).Single();
            var probe = frozen.RuntimeDefinition;
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var before = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
            var selected = before.Directory.Computers.SingleOrDefault(c => c.ObjectGuid == guid && DistinguishedName.AreEqual(c.DistinguishedName, dn));
            if (selected is null)
            { throw BridgeArguments.Invalid("Identité du poste remplacée ; rouvrez sa console."); }
            var expected = QueryComputerIdentity.Of(selected);
            object result;
            if (Domenia.Core.Poste.ProbeCatalog.Find(key) is { } detailed)
            {
                var store = await context.Readers.Require<IPosteReader>().ProbeStoreAsync(dn, token).ConfigureAwait(false);
                result = PosteProbeDetails.Build(store, detailed, page, context.Clock.LocalTimeZone, context.Clock.GetUtcNow());
            }
            else
            {
                var readings = await context.Readers.Require<IAccueilReader>().StoredProbesAsync(token).ConfigureAwait(false);
                var reading = readings.ByProbe.GetValueOrDefault(key)?.GetValueOrDefault(guid);
                if (reading?.At < selected.WhenCreated) { reading = null; }
                result = PosteScalarProbeCards.Build(probe, reading, page, context.Clock.GetUtcNow(), context.Clock.LocalTimeZone);
            }
            var after = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
            var currentSession = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            await ProfileProbeCatalog.ConfirmAsync(context.Preferences, [frozen], token).ConfigureAwait(false);
            if (!DistinguishedName.AreEqual(before.Directory.Domain.RootDn, after.Directory.Domain.RootDn)
                || currentSession.Epoch != session.Epoch || !string.Equals(currentSession.Account.Login, session.Account.Login, StringComparison.OrdinalIgnoreCase)
                || !after.Directory.Computers.Any(c => expected.Matches(c)))
            { throw BridgeArguments.Invalid("Identité du poste ou domaine remplacé pendant la lecture locale."); }
            token.ThrowIfCancellationRequested();
            return result;
        }, "Valeurs en cache de la sonde choisie pour l’identité exacte du poste, 100 lignes par page ; aucune collecte.", ServedInSimulation: true),
        new("poste.layout.get", OperationClass.LocalRead, async (args, _, token) =>
        {
            token.ThrowIfCancellationRequested();
            var values = BridgeArguments.ReadObject(args, ["board"]);
            return await PosteBoardLayouts.ReadLatestAsync(context.Preferences, BridgeArguments.GetString(values, "board"), token).ConfigureAwait(false);
        }, "Disposition locale du tableau Poste ou Logiciels, sans lecture du poste.", ServedInSimulation: true),
        new("poste.layout.save", OperationClass.LocalWrite, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["board", "items", "expectedChoiceToken"]);
            if (!values.TryGetValue("items", out var items) || items.ValueKind != JsonValueKind.Array || items.GetArrayLength() > PosteBoardLayouts.MaxItems)
            { throw BridgeArguments.Invalid("Une liste de 64 widgets au plus est attendue."); }
            var parsed = items.Deserialize<FleetLayoutItem[]>(PosteBoardLayouts.Json) ?? throw BridgeArguments.Invalid("Disposition absente.");
            return await PosteBoardLayouts.SaveAsync(context.Preferences, BridgeArguments.GetString(values, "board"), parsed, token,
                values.ContainsKey("expectedChoiceToken") ? BridgeArguments.GetString(values, "expectedChoiceToken") : null, context.Clock.GetUtcNow()).ConfigureAwait(false);
        }, "Mémorise l’ordre, les tailles, titres et pauses avec cinq versions précédentes dans les préférences locales.", ServedInSimulation: true),
        new("poste.layout.preset", OperationClass.LocalWrite, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["board", "preset", "expectedChoiceToken"]);
            var board = BridgeArguments.GetString(values, "board");
            var current = await PosteBoardLayouts.ReadLatestAsync(context.Preferences, board, token).ConfigureAwait(false);
            if (!current.Valid) throw new InvalidDataException(current.Reason);
            var next = BoardLayoutPresets.Apply(board, BridgeArguments.GetString(values, "preset"), current.Items);
            return await PosteBoardLayouts.SaveAsync(context.Preferences, board, next, token,
                BridgeArguments.GetString(values, "expectedChoiceToken"), context.Clock.GetUtcNow()).ConfigureAwait(false);
        }, "Applique le préréglage Assistance, Inventaire ou Santé sans supprimer les autres cartes, avec historique et choix concurrent protégés.", ServedInSimulation: true),
        new("poste.layout.restore", OperationClass.LocalWrite, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["board", "versionId", "expectedChoiceToken"]);
            return await PosteBoardLayouts.RestoreAsync(context.Preferences, BridgeArguments.GetString(values, "board"),
                BridgeArguments.GetString(values, "versionId"), BridgeArguments.GetString(values, "expectedChoiceToken"), context.Clock.GetUtcNow(), token).ConfigureAwait(false);
        }, "Restaure explicitement une des cinq versions de ce tableau si le choix affiché est encore courant.", ServedInSimulation: true),
    ];
}
