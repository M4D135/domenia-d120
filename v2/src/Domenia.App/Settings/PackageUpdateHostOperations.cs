using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.App.Settings;

namespace Domenia.App;

internal sealed record UpdateCandidateView(string Version, string FileName, long? Bytes, string Sha256, string Provenance);
internal sealed record UpdateView(bool Demonstration, bool Available, bool Busy, string InstalledVersion, string Folder,
    string Source, UpdateCandidateView? Candidate, bool Prepared, string? Confirmation, DateTimeOffset? ExpiresAt,
    string Message, string[] Advice, string? PreparationFolder);

/// <summary>Owns offers and plans, never accepts paths, URLs or manifests from an install command.</summary>
internal sealed class PackageUpdateHost : IDisposable
{
    private const string FolderKey = "updates.distributionFolder";
    private readonly EngineContext context;
    private readonly PackageUpdateSources sources;
    private readonly SemaphoreSlim serial = new(1, 1);
    private Func<bool, CancellationToken, Task<string?>>? picker;
    private Action<PreparedUpdate, string>? schedule;
    private UpdateOffer? offer;
    private PreparedUpdate? prepared;
    private PackageSignatureVerdict? publisher;
    private string folder = "", source = "folder", installed = ProductInfo.DisplayVersion;
    private string? confirmation;
    private DateTimeOffset? expires;
    private int installing;
    private UpdateView view;
    private bool Demo => context.Mode == AppMode.Simulation;

    internal PackageUpdateHost(EngineContext context)
    {
        this.context = context; sources = new(context.Mode, light: AppPaths.IsLight);
        if (!Demo && context.Preferences.TryGet(FolderKey, out var saved) && saved.ValueKind == JsonValueKind.String)
        {
            var value = saved.GetString();
            if (value is { Length: > 0 and <= 512 }) { try { folder = PackageUpdateSources.QualifiedFolder(value); } catch (InvalidDataException) { } }
        }
        view = MakeView("Choisissez une source, puis lancez une recherche explicite. Aucune lecture automatique.");
    }

    internal void Attach(Func<bool, CancellationToken, Task<string?>> pick, Action<PreparedUpdate, string> install)
    { picker = pick; schedule = install; Publish(view.Message); }
    internal UpdateView View() => Volatile.Read(ref view);
    internal async Task<DefaultsPackageResult> DefaultsPackage(string text, CancellationToken token)
    {
        _ = PortableConfiguration.Read(text);
        await serial.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (Demo) { return new(true, null, null, null, "Configuration par défaut fictive enregistrée avec ces réglages ; aucun fichier réel écrit."); }
            Available();
            async Task<string?> Backup(byte[] previous, CancellationToken ct)
            {
                var saved = await context.Documents.SaveFileAsync("Domenia.settings.seed.avant-remplacement.json", previous, ct).ConfigureAwait(false);
                return saved.Saved ? saved.Name : null;
            }
            var result = await Task.Run(() => PackageDefaults.WriteAsync(PackageLayout.ApplicationRoot, text, Backup, token), token).ConfigureAwait(false);
            await KeepOwnSettings(result, token).ConfigureAwait(false);
            return result;
        }
        finally { serial.Release(); }
    }

    // The profile that defined the defaults already holds them: like GLPI Pilot, it is not offered its own file again.
    private async Task KeepOwnSettings(DefaultsPackageResult result, CancellationToken token)
    {
        try
        {
            var seeds = ConfigurationSeedHost.From(context);
            var status = await seeds.StatusAsync(token).ConfigureAwait(false);
            if (status is { NeedsDecision: true, DecisionId: { } id, SourceSha256: { } sha, Fingerprint: { } fingerprint } && sha == result.Sha256)
            { await seeds.DecideAsync(id, sha, fingerprint, false, token).ConfigureAwait(false); }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or ArgumentException)
        { context.Log.Warning("Configuration par défaut écrite ; ce profil la verra proposée au prochain démarrage (" + ex.GetType().Name + ")."); }
    }
    private UpdateView MakeView(string message) => new(Demo, Demo || (!HostFacts.Unattended && picker is not null && schedule is not null && AppPaths.UserData is not null),
        Volatile.Read(ref installing) != 0, installed, Demo ? "Partage fictif de démonstration" : folder, source,
        offer is null ? null : new(offer.Asset.Version, offer.Asset.Name, offer.Asset.Size, offer.Asset.Sha256, offer.Location),
        confirmation is not null, confirmation, expires, message,
        [Demo ? "Catalogue, préparation, installation et retour arrière fictifs ; aucun service, fichier réel ou binaire installé n’est modifié." : publisher?.Notice ?? PackageUpdateCatalog.TrustNotice,
            "Un paquet de la même variante est préparé et contrôlé avant fermeture. Le succès exige ensuite le contrôle de démarrage lié à la transaction.",
            "Les données, préférences, profils et bases restent séparés du retour arrière des binaires."], prepared is null ? null : Path.GetDirectoryName(prepared.Directory));
    private UpdateView Publish(string message) { var next = MakeView(message); Volatile.Write(ref view, next); return next; }
    private void Available()
    {
        if (!View().Available) { throw new InvalidOperationException("Mise à jour indisponible dans cette fenêtre ; utilisez un pack publié et une session interactive."); }
        if (Volatile.Read(ref installing) != 0) { throw new InvalidOperationException("Une fermeture pour installation est déjà demandée."); }
    }
    private void ClearPlan() { publisher = null; prepared = null; confirmation = null; expires = null; }

    internal async Task<UpdateView> ChooseFolder(CancellationToken token)
    {
        await serial.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Available();
            if (Demo) { source = "folder"; return Publish("Partage fictif choisi. Aucun dossier réel n’a été interrogé."); }
            var selected = await picker!(true, token).ConfigureAwait(false);
            if (selected is null) { return View(); }
            var next = PackageUpdateSources.QualifiedFolder(selected);
            await context.Preferences.SetAsync(FolderKey, JsonSerializer.SerializeToElement(next), token).ConfigureAwait(false);
            folder = next; source = "folder"; offer = null; ClearPlan();
            return Publish("Dossier mémorisé. La recherche utilisera les droits de votre session Windows, sans enregistrer de mot de passe.");
        }
        finally { serial.Release(); }
    }

    internal async Task<UpdateView> Check(string selectedSource, CancellationToken token)
    {
        if (selectedSource is not ("folder" or "local")) { throw new InvalidDataException("Source de mise à jour inconnue."); }
        await serial.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Available(); string? selected = null;
            if (!Demo && selectedSource == "local")
            {
                selected = await picker!(false, token).ConfigureAwait(false);
                if (selected is null) { return View(); }
            }
            if (!Demo && selectedSource == "folder" && folder.Length == 0) { throw new InvalidDataException("Choisissez d’abord le dossier de diffusion."); }
            source = selectedSource; offer = null; ClearPlan(); Publish("Lecture explicite de la source choisie…");
            if (Demo)
            {
                offer = new(source, "Source fictive — example.invalid", new("Domenia_2.0.1_PROD_Windows-x64.zip", "2.0.1", 10485760, new string('d', 64)), new string('e', 64));
                return Publish("Version fictive trouvée. Aucune connexion ni lecture de partage réel.");
            }
            offer = source == "folder" ? await sources.FolderAsync(folder, installed, token).ConfigureAwait(false)
                : await sources.LocalZipAsync(selected!, token).ConfigureAwait(false);
            if (offer is not null && PackageUpdateCatalog.Latest([offer.Asset], installed) is null)
            { offer = null; return Publish("Ce pack n’est pas plus récent que la version installée. Un retour arrière utilise le bilan de sa transaction, jamais ce chemin d’installation."); }
            return Publish(offer is null ? "Aucune nouvelle version stable compatible sur cette source." : "Version trouvée. Contrôlez la provenance puis demandez explicitement la copie et la préparation.");
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or OperationCanceledException)
        { Publish("Recherche interrompue ou refusée ; aucune autre source n’a été utilisée. Réessayez explicitement."); throw; }
        finally { serial.Release(); }
    }

    internal async Task<UpdateView> Prepare(CancellationToken token)
    {
        await serial.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Available(); var selected = offer ?? throw new InvalidDataException("Recherchez d’abord une version."); ClearPlan();
            Publish("Préparation explicitement demandée ; aucune installation tant que tous les contrôles n’ont pas abouti.");
            if (Demo)
            {
                confirmation = Guid.NewGuid().ToString("N"); expires = context.Clock.GetUtcNow().AddMinutes(10);
                return Publish("Préparation fictive vérifiée. La confirmation ne modifiera que la version affichée dans cet espace.");
            }
            prepared = await sources.PrepareAsync(selected, Path.Combine(AppPaths.UserData!, "UpdatePreparations"), token).ConfigureAwait(false);
            var plan = new PackageLifecycle(prepared.Directory, context.Clock) { RequireHealth = true }.PreviewUpdate(PackageLayout.ApplicationRoot, token);
            if (plan.SourceIdentity != prepared.ManifestSha256) { throw new InvalidDataException("Le paquet préparé a changé."); }
            publisher = plan.Publisher;
            confirmation = plan.Confirmation; expires = context.Clock.GetUtcNow().AddMinutes(10);
            return Publish("Pack complet préparé et relu. L’installation ferme cette fenêtre après la fin des opérations ; le bilan sera affiché par l’assistant.");
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or OperationCanceledException)
        { confirmation = null; expires = null; Publish("Préparation refusée ou interrompue. Les preuves locales sont conservées et l’installation courante reste intacte."); throw; }
        finally { serial.Release(); }
    }

    internal object Install(string expected)
    {
        if (!serial.Wait(0)) { throw new InvalidOperationException("Préparation encore en cours."); }
        try
        {
            Available();
            if (confirmation is null || expected != confirmation || expires is null || context.Clock.GetUtcNow() >= expires)
            { throw new InvalidDataException("Confirmation expirée ou différente. Préparez à nouveau le pack."); }
            if (Demo)
            {
                installed = "2.0.1-demo"; ClearPlan(); Publish("Mise à jour fictive terminée ; les binaires réels sont inchangés.");
                return new { accepted = true, simulated = true, message = "Mise à jour de démonstration seulement." };
            }
            var package = prepared ?? throw new InvalidDataException("Préparation absente.");
            Interlocked.Exchange(ref installing, 1); Publish("Fermeture demandée pour l’assistant. L’installation n’est pas encore confirmée.");
            try { schedule!(package, expected); } catch { Interlocked.Exchange(ref installing, 0); throw; }
            return new { accepted = true, simulated = false, message = "Assistant demandé ; attendez son bilan de vérification." };
        }
        finally { serial.Release(); }
    }

    internal UpdateView DemoRollback()
    {
        if (!Demo) { throw new InvalidOperationException("Le retour arrière réel exige la transaction sauvegardée de l’assistant ; aucun binaire n’a été touché."); }
        if (!serial.Wait(0)) { throw new InvalidOperationException("Opération encore en cours."); }
        try { installed = ProductInfo.DisplayVersion; ClearPlan(); return Publish("Retour arrière fictif terminé ; aucune base ou installation réelle modifiée."); }
        finally { serial.Release(); }
    }

    internal void TransitionFailed(string message) { Interlocked.Exchange(ref installing, 0); Publish(message); }
    public void Dispose() { sources.Dispose(); serial.Dispose(); }
}

public sealed class PackageUpdateHostOperations : IOperationModule
{
    public string Screen => "settings";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        var host = context.Shared(static c => new PackageUpdateHost(c));
        return
        [
            new("settings.defaults.package", OperationClass.LocalWrite, async (args, _, ct) =>
            { var values = BridgeArguments.ReadObject(args, ["text"]); return await host.DefaultsPackage(BridgeArguments.GetString(values, "text"), ct).ConfigureAwait(false); },
                "Écrit les réglages explicitement choisis dans la configuration par défaut du dossier (wad), hors manifeste ; binaires, manifeste et ZIP officiel intacts, ancien fichier sauvegardé dans les exports.") { ServedInSimulation = true },
            new("settings.update.status", OperationClass.Local, (args, _, _) => { BridgeArguments.RequireNone(args); return Task.FromResult<object?>(host.View()); }, "État local de la mise à jour ; aucune recherche automatique."),
            new("settings.update.folder", OperationClass.LocalWrite, async (args, _, ct) => { BridgeArguments.RequireNone(args); return await host.ChooseFolder(ct).ConfigureAwait(false); }, "Choisit explicitement le dossier de diffusion et mémorise son chemin sans mot de passe."),
            new("settings.update.check", OperationClass.NetworkRead, async (args, _, ct) =>
            { var values = BridgeArguments.ReadObject(args, ["source"]); return await host.Check(BridgeArguments.GetString(values, "source"), ct).ConfigureAwait(false); }, "Recherche une version sur la seule source choisie, ou utilise le catalogue fictif en démonstration.") { ServedInSimulation = true },
            new("settings.update.prepare", OperationClass.NetworkRead, async (args, _, ct) => { BridgeArguments.RequireNone(args); return await host.Prepare(ct).ConfigureAwait(false); }, "Copie et vérifie explicitement le pack choisi ; aucune installation.") { ServedInSimulation = true },
            new("settings.update.install", OperationClass.LocalWrite, (args, _, _) =>
            { var values = BridgeArguments.ReadObject(args, ["confirmation"]); return Task.FromResult<object?>(host.Install(BridgeArguments.GetString(values, "confirmation"))); }, "Demande la fermeture contrôlée et l’assistant pour le seul plan confirmé."),
            new("settings.update.demoRollback", OperationClass.LocalWrite, (args, _, _) =>
            { BridgeArguments.RequireNone(args); return Task.FromResult<object?>(host.DemoRollback()); }, "Retour arrière fictif uniquement ; les binaires et bases réels sont inaccessibles."),
        ];
    }
}
