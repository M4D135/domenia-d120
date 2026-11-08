using System.Globalization;
using System.Text;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

public sealed class BoardLayoutOperations : IOperationModule
{
    public string Screen => "shell";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        async Task<BoardLayoutImport> Examine(string board, string text, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (!BoardLayoutTransfer.RequiresLibrary(text)) return BoardLayoutTransfer.Examine(board, text);
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var root = session.Domain?.RootDn ?? throw new InvalidDataException("Domaine absent pour qualifier les cartes de requêtes.");
            var library = await RequetesServices.Library(context).ReadAsync(root, token).ConfigureAwait(false);
            var result = BoardLayoutTransfer.Examine(board, text, library, root);
            var after = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            if (after.Epoch != session.Epoch || SessionIdentity.Key(after) != SessionIdentity.Key(session))
                throw new InvalidDataException("Session remplacée pendant la qualification du fichier ; relisez son aperçu.");
            token.ThrowIfCancellationRequested();
            return result with { SessionStamp = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(SessionIdentity.Key(session) + "|" + session.Epoch.ToString(CultureInfo.InvariantCulture)))) };
        }
        async Task<object> Save(string board, IReadOnlyList<FleetLayoutItem> items, string choice, CancellationToken token, Func<CancellationToken, IDisposable> qualify)
        {
            if (board == "Fleet") return await AccueilService.From(context).SaveLayoutAsync(items, token, choice, qualify).ConfigureAwait(false);
            return await PosteBoardLayouts.SaveAsync(context.Preferences, board, items, token, choice, context.Clock.GetUtcNow(), qualify).ConfigureAwait(false);
        }
        return
        [
            new("shell.board.import.preview", OperationClass.LocalRead, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["board", "text"]);
                return await Examine(BridgeArguments.GetString(values, "board"), BridgeArguments.GetString(values, "text"), token).ConfigureAwait(false);
            }, "Examine un fichier de disposition D1 ou D2, son tableau, son empreinte et chaque liaison locale ; aucun changement."),
            new("shell.board.import.apply", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["board", "text", "sha256", "expectedChoiceToken", "allowQueryProposal", "queryBindingsSha256", "sessionStamp"]);
                var board = BridgeArguments.GetString(values, "board");
                var text = BridgeArguments.GetString(values, "text");
                var expected = BridgeArguments.GetString(values, "sha256");
                var preview = await Examine(board, text, token).ConfigureAwait(false);
                var bindings = BridgeArguments.GetOptionalString(values, "queryBindingsSha256");
                var sessionStamp = BridgeArguments.GetOptionalString(values, "sessionStamp");
                var consent = values.TryGetValue("allowQueryProposal", out var allow) && allow.ValueKind == System.Text.Json.JsonValueKind.True;
                if (preview.Sha256 != expected || preview.SessionStamp != sessionStamp || preview.QueryBindingsSha256 != bindings || preview.NeedsQueryConsent && !consent)
                    throw new InvalidDataException("Aperçu, liaisons ou consentement remplacés ; aucune disposition importée.");
                var saved = await Save(board, preview.Items, BridgeArguments.GetString(values, "expectedChoiceToken"), token, ct =>
                {
                    // Called after the destination mutex: library revision/domain may have changed while the user confirmed.
                    var current = Examine(board, text, ct).GetAwaiter().GetResult();
                    if (current.Sha256 != expected || current.SessionStamp != sessionStamp || current.QueryBindingsSha256 != bindings || !current.Items.SequenceEqual(preview.Items))
                        throw new InvalidDataException("Bibliothèque ou liaison modifiée pendant l’attente ; relisez le fichier.");
                    return new EmptyLease();
                }).ConfigureAwait(false);
                context.Journal.Add(new(context.Clock.GetUtcNow(), "Disposition importée · " + board + " · SHA-256 UTF8 " + expected, Tone.Info));
                return saved;
            }, "Remplace explicitement la disposition affichée après aperçu, avec historique et protection du choix concurrent ; original du fichier intact."),
            new("shell.board.default.preview", OperationClass.LocalRead, (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["board"]);
                return Task.FromResult<object?>(context.Readers.Require<IBoardLayoutDefaults>().Read(BridgeArguments.GetString(values, "board"), token));
            }, "Aperçu du défaut d’équipe local ou du défaut livré ; aucune lecture réseau."),
            new("shell.board.default.apply", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["board", "sourceSha256", "expectedChoiceToken"]);
                var board = BridgeArguments.GetString(values, "board");
                var sha = BridgeArguments.GetString(values, "sourceSha256");
                var reader = context.Readers.Require<IBoardLayoutDefaults>();
                var preview = reader.Read(board, token);
                if (preview.SourceSha256 != sha) throw new InvalidDataException("Défaut d’équipe remplacé depuis l’aperçu.");
                return await Save(board, preview.Items, BridgeArguments.GetString(values, "expectedChoiceToken"), token, ct => reader.Hold(board, sha, ct)).ConfigureAwait(false);
            }, "Rétablit explicitement le défaut d’équipe ou livré, source requalifiée sous verrou et historique conservé."),
            new("shell.board.export", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["board", "expectedChoiceToken"]);
                var board = BridgeArguments.GetString(values, "board");
                IReadOnlyList<FleetLayoutItem> items;
                string choice;
                if (board == "Fleet")
                {
                    var view = await AccueilService.From(context).LayoutLatestAsync(token).ConfigureAwait(false);
                    if (!view.Valid) throw new InvalidDataException(view.Reason);
                    items = view.Items; choice = view.ChoiceToken;
                }
                else
                {
                    var view = await PosteBoardLayouts.ReadLatestAsync(context.Preferences, board, token).ConfigureAwait(false);
                    if (!view.Valid) throw new InvalidDataException(view.Reason);
                    items = view.Items; choice = view.ChoiceToken;
                }
                if (choice != BridgeArguments.GetString(values, "expectedChoiceToken")) throw new InvalidDataException("Disposition modifiée depuis l’affichage ; relisez-la avant l’export.");
                var text = BoardLayoutTransfer.Export(board, items, context.Clock.GetUtcNow());
                var label = board == "Fleet" ? "accueil" : board == "Computer" ? "poste" : "logiciels";
                var name = "Domenia-disposition-" + label + "-" + context.Clock.GetUtcNow().ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".json";
                var saved = await context.Documents.SaveFileAsync(name, Encoding.UTF8.GetBytes(text), token).ConfigureAwait(false);
                return new { fileName = saved.Name, saved = saved.Saved, text, summary = saved.Saved ? "Disposition exportée dans " + saved.Name + "." : "Disposition préparée en mémoire ; aucun fichier écrit dans ce mode." };
            }, "Exporte exactement la disposition choisie dans un document D2 versionné, sans données de parc ni permission d’exécution."),
        ];
    }
    private sealed class EmptyLease : IDisposable { public void Dispose() { } }
}
