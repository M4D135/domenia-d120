using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

/// <summary>
/// The workstation console (screen « poste », docs/ops/poste.md): local reads of the console (list, console, stored readings,
/// cached inventory and software), network reads made only after an explicit gesture on one workstation (ping, live state,
/// inventory, software, services, processes, events, sessions, diagnosis, WMI explorer, probes, slow triage, logons, last
/// user, secrets), plans of the writes and remote actions (reads too: the write itself is always write.execute), the
/// authorizations of the session (Local), the services of the host (secure window of the secrets, launcher of the Windows
/// and suite tools, « Enregistrer sous » of the exports) and the approved BIOS references (LocalWrite). Handlers only
/// validate their arguments and delegate.
/// </summary>
public sealed partial class PosteOperations : IOperationModule
{
    private const int MaxTextLength = 100;
    private const int MaxDsregLength = PosteDsreg.MaxLength;

    /// <summary>Largest CSV accepted by an export (all its files together), in characters.</summary>
    private const int MaxExportLength = 8 * 1024 * 1024;

    /// <summary>Preference of the screen: also read the console user when a workstation is opened from the list (PST-051).</summary>
    internal const string OpenReadsConsoleKey = "poste.openReadsConsole";

    private static readonly FrozenStringSet ExportKinds = new(["inventaire", "logiciels", "logiciels-inventaire", "services", "processus", "sessions", "evenements", "wmi", "sondes", "diagnostic", "secrets"]);
    private static readonly FrozenStringSet ExportParts = new(["lignes", "sources", "liste"]);

    public string Screen => "poste";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var scope = WorkingScope.From(context);
        var session = PosteSession.For(context.Directory);
        var simulation = context.Mode == AppMode.Simulation;
        var planClass = simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;

        IPosteReader Reader() => readers.Require<IPosteReader>();
        DateTimeOffset Now() => context.Clock.GetUtcNow();
        void Journal(string text, Tone tone) => context.Journal.Add(new JournalEntry(Now(), text, tone));

        // The health policy is the book shared with the Accueil, resolved for the opened workstation (PST-092, PST-093).
        async Task<PosteHealthPolicy> PolicyAsync(string? computerDn, CancellationToken ct)
        {
            var info = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var root = info.Domain?.RootDn ?? "";
            if (root.Length == 0)
            {
                return PosteHealthPolicy.Default with { EvaluatedAt = Now() };
            }
            JsonElement? book = context.Preferences.TryGet(PosteHealthPolicies.PreferenceKey(root), out var stored) ? stored : null;
            return PosteHealthPolicies.Resolve(book, root, computerDn ?? root, Now(), context.Clock.LocalTimeZone);
        }

        IPosteSecretWindow SecretWindow() => readers.Find<IPosteSecretWindow>() ?? throw new DomeniaOperationException(PosteErrors.HostUnavailable,
            "Aucune fenêtre sécurisée n’est disponible ici (aperçu ou tests) : la valeur ne peut pas être affichée. Rien n’a été lu.");

        OperationDefinition Network(string name, OperationHandler handler, string description) =>
            new(name, OperationClass.NetworkRead, handler, description, ServedInSimulation: true);

        var operations = new List<OperationDefinition>
        {
            new("poste.list", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = ReadOptionalObject(args, ["text", "limit"]);
                var text = BridgeArguments.GetOptionalString(values, "text");
                if (text?.Length > MaxTextLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(MaxTextLength) + " caractères.");
                }
                var limit = OptionalInt(values, "limit", 1, 1000) ?? 500;
                var info = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                var current = await scope.CurrentAsync(info, ct).ConfigureAwait(false);
                var policy = await PolicyAsync(current?.Dn, ct).ConfigureAwait(false);
                return await Reader().ListAsync(current, text, limit, policy, ct).ConfigureAwait(false);
            }, "Postes de l’OU de travail, filtrés localement (nom, utilisateur, système, site) ; base locale seulement."),

            new("poste.open", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                await BindSessionAsync(context, session, ct).ConfigureAwait(false);
                var policy = await PolicyAsync(dn.Dn, ct).ConfigureAwait(false);
                return await Reader().OpenAsync(dn.Dn, policy, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
            }, "Console d’un poste à partir de sa fiche et des observations enregistrées ; aucune lecture réseau."),

            new("poste.host", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                var openReadsConsole = context.Preferences.TryGet(OpenReadsConsoleKey, out var stored) && stored.ValueKind == JsonValueKind.True;
                return Task.FromResult<object?>(new
                {
                    secretWindow = readers.Find<IPosteSecretWindow>() is not null,
                    toolLauncher = readers.Find<IPosteToolLauncher>() is not null,
                    fileExport = readers.Find<IPosteFileExport>() is not null,
                    simulation,
                    openReadsConsole,
                });
            }, "Services de l’hôte disponibles (fenêtre sécurisée, lanceur d’outils, enregistrement des exports) et options de l’écran."),

            new("poste.option.set", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["name", "value"]);
                if (BridgeArguments.GetString(values, "name") != "openReadsConsole")
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("name") + " doit valoir openReadsConsole.");
                }
                var value = BridgeArguments.GetBoolean(values, "value");
                try
                {
                    await context.Preferences.SetAsync(OpenReadsConsoleKey, JsonSerializer.SerializeToElement(value), ct).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    context.Log.Warning($"Préférences non enregistrées (option de l’écran Poste) : {ex.GetType().Name}.");
                    Journal("Préférences non enregistrées" + FrenchText.Colon + "l’option vaut pour cette session", Tone.Warn);
                }
                return new { name = "openReadsConsole", value };
            }, "Option locale de l’écran : lire aussi l’utilisateur connecté à l’ouverture d’un poste depuis la liste ; aucune action sur un poste."),

            Network("poste.ping", async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                var reading = await Reader().PingAsync(dn.Dn, ct).ConfigureAwait(false);
                // An unknown round trip is never written « 0 ms ».
                var answer = reading.Answered != true ? "pas de réponse" : reading.RoundTripMs is > 0 ? "répond en " + FrenchText.Integer(reading.RoundTripMs.Value) + FrenchText.Nbsp + "ms" : "répond";
                Journal("Ping de " + NameOf(dn.Dn) + FrenchText.Colon + answer, reading.Answered == true ? Tone.Ok : Tone.Warn);
                return reading;
            }, "Un seul écho ICMP vers le poste, enregistré avant affichage."),

            Network("poste.live", async (args, _, ct) =>
                await Reader().LiveAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "État en direct : présence, durée de fonctionnement, utilisateur connecté."),

            Network("poste.inventory", async (args, bridge, ct) =>
            {
                var dn = Dn(args, ["deep"]);
                var deep = OptionalBool(dn.Values, "deep") ?? false;
                var policy = await PolicyAsync(dn.Dn, ct).ConfigureAwait(false);
                var result = await Collect(session, dn.Dn, CollectionKind.Inventory, Now(), ct, token => Reader().InventoryAsync(dn.Dn, deep, policy, Progress(bridge), token)).ConfigureAwait(false);
                var read = result.Access.Count(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial);
                Journal((deep ? "Inventaire complet" : "Inventaire rapide") + FrenchText.Colon + result.Computer + " · " + FrenchText.Count(read, "source lue", "sources lues")
                    + (result.Partial ? " · résultat partiel" : ""), read == 0 ? Tone.Warn : result.Partial ? Tone.Info : Tone.Ok);
                return result;
            }, "Inventaire rapide (55 s au plus) ou complet (150 s au plus) du poste, enregistré comme le dernier ; arrêtable, résultat partiel à l’arrêt."),

            new("poste.inventory.cached", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                var policy = await PolicyAsync(dn.Dn, ct).ConfigureAwait(false);
                return await Reader().CachedInventoryAsync(dn.Dn, policy, ct).ConfigureAwait(false);
            }, "Dernier inventaire enregistré du poste (cette session, sinon la base locale), avec ses lignes ; aucune lecture réseau."),

            new("poste.running", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(session.Running());
            }, "Relevés en cours dans la session, tous postes : la page nomme ceux d’un autre poste."),

            new("poste.collect.stop", OperationClass.Local, (args, _, _) =>
            {
                var dn = Dn(args, ["kind"]);
                var kind = BridgeArguments.GetOptionalString(dn.Values, "kind") switch
                {
                    null => (CollectionKind?)null,
                    "inventory" => CollectionKind.Inventory,
                    "diagnostic" => CollectionKind.Diagnostic,
                    "probes" => CollectionKind.Probes,
                    "detection" => CollectionKind.Detection,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir inventory, diagnostic, probes ou detection."),
                };
                var stopped = session.StopCollection(dn.Dn, kind);
                var text = stopped.IsEmpty
                    ? "Aucun relevé de ce type en cours pour ce poste : rien n’a été arrêté."
                    : "Arrêt demandé" + FrenchText.Colon + string.Join(", ", stopped.Select(PosteSession.Label)) + " ; ce qui est déjà lu est gardé.";
                return Task.FromResult<object?>(new { stopped = stopped.Select(KindName).ToImmutableArray(), text });
            }, "Arrête un relevé du poste ouvert (un type : inventaire, sondes, diagnostic ou détection) ; ce qui est déjà lu est gardé."),

            Network("poste.software", async (args, _, ct) =>
            {
                var dn = Dn(args, ["perUser", "store", "updates"]);
                var request = new SoftwareRequest(OptionalBool(dn.Values, "perUser") ?? false, OptionalBool(dn.Values, "store") ?? false, OptionalBool(dn.Values, "updates") ?? false);
                return await Reader().SoftwareAsync(dn.Dn, request, ct).ConfigureAwait(false);
            }, "Logiciels installés (registre Uninstall, SCCM, profils chargés, Store) ; jamais Win32_Product."),

            new("poste.software.cached", OperationClass.LocalRead, async (args, _, ct) =>
                await Reader().CachedSoftwareAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Logiciels déjà lus par le dernier inventaire ; aucune lecture réseau."),

            Network("poste.services", async (args, _, ct) =>
                await Reader().ServicesAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Services du poste (Win32_Service, 500 au plus), lecture seule."),

            Network("poste.processes", async (args, _, ct) =>
                await Reader().ProcessesAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Processus et part du processeur mesurée entre deux lectures."),

            Network("poste.events", async (args, _, ct) =>
            {
                var dn = Dn(args, ["preset", "hours", "max"]);
                var preset = BridgeArguments.GetString(dn.Values, "preset");
                if (PosteEvents.Preset(preset) is null)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("preset") + " doit être un préréglage connu (Startup, Crash, Disk, Policy, Updates).");
                }
                var hours = OptionalInt(dn.Values, "hours", int.MinValue, int.MaxValue) ?? 72;
                var max = OptionalInt(dn.Values, "max", int.MinValue, int.MaxValue) ?? 50;
                return await Reader().EventsAsync(dn.Dn, preset, hours, max, ct).ConfigureAwait(false);
            }, "Événements d’un préréglage, fenêtre de 1 à 720 h, 1 à 200 événements (bornes signalées)."),

            Network("poste.sessions", async (args, _, ct) =>
                await Reader().SessionsAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Sessions Windows du poste (WTS), consultation seule."),

            Network("poste.restart.sessions", async (args, _, ct) =>
            {
                var dn = Dn(args, []).Dn;
                try
                {
                    return PosteSessions.ForRestart(await Reader().SessionsAsync(dn, ct).ConfigureAwait(false), null);
                }
                catch (DomeniaOperationException ex) when (ex.Code != PosteErrors.ComputerUnknown)
                {
                    // The restart panel says why the sessions are unknown instead of failing: a delayed restart stays possible.
                    return PosteSessions.ForRestart(null, ex.Message);
                }
            }, "Sessions ouvertes lues juste avant un redémarrage, résumées pour le panneau (une lecture impossible est dite, jamais tue)."),

            Network("poste.diagnostic", async (args, bridge, ct) =>
            {
                var dn = Dn(args, []);
                var result = await Collect(session, dn.Dn, CollectionKind.Diagnostic, Now(), ct, token => Reader().DiagnosticAsync(dn.Dn, Progress(bridge), token)).ConfigureAwait(false);
                Journal("Diagnostic" + FrenchText.Colon + result.Computer + " · " + FrenchText.Count(result.Passed, "réussi", "réussis") + ", " + FrenchText.Integer(result.Failed) + " en échec", result.Failed > 0 ? Tone.Warn : Tone.Ok);
                return result;
            }, "Diagnostic du poste (DNS, ping, ports, CIM, C$, WinRM, transports), verdict et couche bloquante ; arrêtable."),

            Network("poste.quickDiag", async (args, _, ct) =>
                await Reader().QuickDiagnosticAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Diagnostic rapide borné : cinq contrôles en lecture seule, 20 s annoncées, sans repli."),

            Network("poste.wmi.namespaces", async (args, _, ct) =>
            {
                var dn = Dn(args, ["parent"]);
                var parent = BridgeArguments.GetOptionalString(dn.Values, "parent");
                if (parent is not null && !PosteWmi.IsNamespace(parent))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("parent") + " doit être un espace de noms WMI valide.");
                }
                return await Reader().WmiNamespacesAsync(dn.Dn, parent, ct).ConfigureAwait(false);
            }, "Espaces de noms WMI (root et ses enfants directs)."),

            Network("poste.wmi.classes", async (args, _, ct) =>
            {
                var dn = Dn(args, ["ns"]);
                var ns = BridgeArguments.GetString(dn.Values, "ns");
                if (!PosteWmi.IsNamespace(ns))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("ns") + " doit être un espace de noms WMI valide.");
                }
                return await Reader().WmiClassesAsync(dn.Dn, ns, ct).ConfigureAwait(false);
            }, "Classes d’un espace de noms WMI (classes du fournisseur MSI marquées bloquées)."),

            Network("poste.wmi.query", async (args, _, ct) =>
            {
                var dn = Dn(args, ["ns", "cls", "where", "limit"]);
                var (request, reason) = PosteWmi.Validate(BridgeArguments.GetString(dn.Values, "ns"), BridgeArguments.GetString(dn.Values, "cls"),
                    BridgeArguments.GetOptionalString(dn.Values, "where"), OptionalInt(dn.Values, "limit", int.MinValue, int.MaxValue));
                if (request is null)
                {
                    throw new DomeniaOperationException(PosteErrors.QueryRefused, "Requête WMI refusée : " + reason + " Rien n’a été envoyé.");
                }
                return await Reader().WmiQueryAsync(dn.Dn, request, ct).ConfigureAwait(false);
            }, "SELECT sur une classe WMI (WHERE facultatif, 1 à 500 instances) ; aucune méthode invoquée."),

            new("poste.readings", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                var store = await Reader().ProbeStoreAsync(dn.Dn, ct).ConfigureAwait(false);
                var book = await BiosBookAsync(context, ct).ConfigureAwait(false);
                var policy = await PolicyAsync(dn.Dn, ct).ConfigureAwait(false);
                return PosteReadings.Build(store, policy, book, Now(), context.Clock.LocalTimeZone);
            }, "Lectures interprétées du poste à partir des relevés enregistrés (sondes du catalogue) ; aucune requête au poste."),

            new("poste.probe.details", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args, ["probe", "page"]);
                var probe = BridgeArguments.GetString(dn.Values, "probe");
                var info = ProbeCatalog.Find(probe) ?? throw BridgeArguments.Invalid(FrenchText.Quote("probe") + " doit être une sonde du catalogue.");
                var page = OptionalInt(dn.Values, "page", 1, 10_000) ?? 1;
                var store = await Reader().ProbeStoreAsync(dn.Dn, ct).ConfigureAwait(false);
                return PosteProbeDetails.Build(store, info, page, context.Clock.LocalTimeZone, Now());
            }, "Valeurs enregistrées d’une sonde du poste, 100 lignes par page ; n’interroge jamais le poste."),

            Network("poste.probes.collect", async (args, bridge, ct) =>
            {
                var dn = Dn(args, ["probes"]);
                ImmutableArray<string> wanted = dn.Values.TryGetValue("probes", out var probes) && probes.ValueKind == JsonValueKind.Array
                    ? [.. probes.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.String).Select(p => p.GetString()!).Distinct(StringComparer.Ordinal)]
                    : [.. PosteReadings.Catalog.SelectMany(r => r.Probes).Distinct(StringComparer.Ordinal)];
                if (wanted.IsEmpty || wanted.Length > 64)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("probes") + " doit nommer de 1 à 64 sondes du catalogue.");
                }
                foreach (var id in wanted)
                {
                    if (ProbeCatalog.Find(id) is null)
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("probes") + " ne doit contenir que des sondes du catalogue.");
                    }
                }
                var store = await Collect(session, dn.Dn, CollectionKind.Probes, Now(), ct, token => Reader().CollectProbesAsync(dn.Dn, wanted, Progress(bridge), token)).ConfigureAwait(false);
                var book = await BiosBookAsync(context, ct).ConfigureAwait(false);
                Journal("Relevé des sondes" + FrenchText.Colon + store.Computer + " · " + FrenchText.Count(wanted.Length, "sonde demandée", "sondes demandées"), Tone.Ok);
                var policy = await PolicyAsync(dn.Dn, ct).ConfigureAwait(false);
                return PosteReadings.Build(store, policy, book, Now(), context.Clock.LocalTimeZone);
            }, "Relève une fois les seules sondes du tableau du poste (ou celles demandées), puis les enregistre ; arrêtable."),

            Network("poste.slow", async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                var policy = await PolicyAsync(dn.Dn, ct).ConfigureAwait(false);
                return await Reader().SlowTriageAsync(dn.Dn, policy, ct).ConfigureAwait(false);
            }, "Tri d’un poste lent : mémoire, processeur mesuré, disques, démarrage, journaux, réseau ; aucune action lancée."),

            Network("poste.logonByDc", async (args, _, ct) =>
                await Reader().LogonByControllerAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "lastLogon du compte ordinateur sur chaque contrôleur, avec la couverture."),

            Network("poste.lastUser.detect", async (args, bridge, ct) =>
            {
                var dn = Dn(args, []);
                return await Collect(session, dn.Dn, CollectionKind.Detection, Now(), ct, token => Reader().DetectLastUserAsync(dn.Dn, Progress(bridge), token)).ConfigureAwait(false);
            }, "Détection du dernier utilisateur (association locale, CIM, LogonUI, profils…) ; une association existante n’est jamais écrasée ; arrêtable."),

            Network("poste.laps", async (args, _, ct) =>
                await Reader().LapsAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Métadonnées LAPS du poste, sans la valeur."),

            Network("poste.laps.reveal", async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                // The value never reaches the page (OPERATIONS.md § 1.2): it is handed to the secure window of the host, which is
                // checked before anything is read.
                var window = SecretWindow();
                var reading = await Reader().RevealLapsAsync(dn.Dn, ct).ConfigureAwait(false);
                var shown = await window.ShowAsync(reading, note => Journal(note, Tone.Info), ct).ConfigureAwait(false);
                Journal("Mot de passe LAPS affiché dans la fenêtre sécurisée" + FrenchText.Colon + shown.Computer + " (valeur jamais journalisée)", Tone.Info);
                return shown;
            }, "Lit le mot de passe LAPS et le montre 30 s dans la fenêtre sécurisée de l’application ; la valeur ne passe jamais par la page."),

            Network("poste.bitlocker.list", async (args, _, ct) =>
                await Reader().BitLockerListAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Objets de récupération BitLocker sous le poste (un niveau, 256 au plus), sans aucune clé."),

            Network("poste.bitlocker.reveal", async (args, _, ct) =>
            {
                var dn = Dn(args, ["key", "expectedId"]);
                var key = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(dn.Values, "key"), "key");
                var expectedId = BridgeArguments.GetString(dn.Values, "expectedId");
                if (expectedId.Length is 0 or > 64)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("expectedId") + " doit être l’identifiant de récupération de la clé choisie.");
                }
                var window = SecretWindow();
                var reading = await Reader().RevealBitLockerAsync(dn.Dn, key, expectedId, ct).ConfigureAwait(false);
                var shown = await window.ShowAsync(reading, note => Journal(note, Tone.Info), ct).ConfigureAwait(false);
                Journal("Clé BitLocker affichée dans la fenêtre sécurisée" + FrenchText.Colon + shown.Computer + " · identifiant " + shown.Identifier + " (valeur jamais journalisée)", Tone.Info);
                return shown;
            }, "Lit une seule clé, enfant direct du poste, dont l’identifiant relu doit être celui choisi (sinon rien) ; montrée 30 s dans la fenêtre sécurisée."),

            new("poste.secret.hide", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var window = readers.Find<IPosteSecretWindow>();
                var hidden = window is not null && await window.HideAsync(ct).ConfigureAwait(false);
                return (object?)new { hidden, text = hidden ? "Fenêtre sécurisée fermée : la valeur a été effacée." : "Aucune valeur n’était affichée." };
            }, "Ferme la fenêtre sécurisée et efface la valeur affichée (changement de vue ou de poste, « Masquer »)."),

            new("poste.secret.state", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                var window = readers.Find<IPosteSecretWindow>();
                return Task.FromResult<object?>(window?.State() ?? new SecretWindowState(false, false, null, null, null, null, 0, "Aucune fenêtre sécurisée dans cet affichage."));
            }, "État de la fenêtre sécurisée : ouverte, masquée ou fermée, échéance ; jamais la valeur."),

            Network("poste.account.other", async (args, _, ct) =>
            {
                var dn = Dn(args, ["resource"]);
                var resource = BridgeArguments.GetString(dn.Values, "resource");
                if (resource is not ("laps" or "bitlocker"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("resource") + " doit valoir laps ou bitlocker.");
                }
                var result = await Reader().UseOtherAccountAsync(dn.Dn, resource, ct).ConfigureAwait(false);
                Journal("Autre compte " + (result.Accepted ? "accepté pour " : "non proposé pour ") + (resource == "laps" ? "LAPS" : "BitLocker") + FrenchText.Colon + result.Computer, result.Accepted ? Tone.Ok : Tone.Info);
                return result;
            }, "Propose un autre compte pour une ressource de secret refusée (invite Windows) : le refus est levé pour cette seule ressource ; aucun mot de passe."),

            Network("poste.secrets.index", async (args, bridge, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var info = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                var current = await scope.CurrentAsync(info, ct).ConfigureAwait(false) ?? throw new DomeniaOperationException(PosteErrors.Refused,
                    "Aucune OU de travail choisie : l’index des secrets porte sur l’OU de travail (Accueil). Rien n’a été lu.");
                var index = await Reader().SecretsIndexAsync(current, Progress(bridge), ct).ConfigureAwait(false);
                Journal("Index des secrets de l’OU " + current.Label + FrenchText.Colon + FrenchText.Count(index.Rows.Length, "poste", "postes") + " (aucune valeur)", Tone.Info);
                return index;
            }, "Index non secret des secrets de l’OU de travail (clés BitLocker comptées, expiration LAPS), 50 000 postes au plus ; aucune clé, aucune valeur."),

            Network("poste.tool.open", async (args, _, ct) =>
            {
                var dn = Dn(args, ["tool"]);
                var tool = BridgeArguments.GetString(dn.Values, "tool");
                if (tool is not ("rdp" or "c" or "compmgmt" or "eventvwr" or "services"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("tool") + " doit valoir rdp, c, compmgmt, eventvwr ou services.");
                }
                // Tools are launched by the administration workstation only (Domenia 1 Invoke-ComputerTool); nothing runs in simulation.
                var launcher = readers.Find<IPosteToolLauncher>() ?? throw new DomeniaOperationException(PosteErrors.HostUnavailable,
                    "Ouverture d’un outil Windows impossible dans cet affichage : copiez la commande (vue Intervenir).");
                var reader = Reader();
                var console = await reader.OpenAsync(dn.Dn, PosteHealthPolicy.Default, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
                var result = await launcher.OpenToolAsync(new ToolRequest(tool, console.Computer.DnsName ?? console.Computer.Name, reader.Options.OperationsAccount, simulation), ct).ConfigureAwait(false);
                Journal(result.Label + FrenchText.Colon + (result.Launched ? "ouvert vers " : "non ouvert vers ") + console.Computer.Name, result.Launched ? Tone.Ok : Tone.Info);
                return result;
            }, "Ouvre un outil Windows vers le poste depuis le poste d’administration (Bureau à distance, C$, Gestion, Observateur, Services) ; rien n’est lancé en simulation."),

            Network("poste.suite.launch", async (args, _, ct) =>
            {
                var dn = Dn(args, ["tool"]);
                var tool = BridgeArguments.GetString(dn.Values, "tool");
                var reader = Reader();
                var definition = reader.Options.SuiteTools.FirstOrDefault(t => t.Id == tool) ?? throw BridgeArguments.Invalid(FrenchText.Quote("tool") + " doit valoir pesto ou filpro.");
                var launcher = readers.Find<IPosteToolLauncher>() ?? throw new DomeniaOperationException(PosteErrors.HostUnavailable,
                    "Lancement d’un outil de la suite impossible dans cet affichage : le plan d’ouverture reste consultable.");
                var console = await reader.OpenAsync(dn.Dn, PosteHealthPolicy.Default, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
                var info = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                var result = await launcher.OpenSuiteAsync(new SuiteRequest(definition.Id, definition.Label, definition.Path, definition.Sha256, SuiteContext(console, info).ToImmutableDictionary(StringComparer.Ordinal), simulation), ct).ConfigureAwait(false);
                Journal("Outil de la suite " + definition.Label + FrenchText.Colon + (result.Launched ? "ouvert" : "non ouvert") + " pour " + console.Computer.Name, result.Launched ? Tone.Ok : Tone.Info);
                return result;
            }, "Ouvre Pesto ou FILPRO avec le contexte du poste, après contrôle du contrat et de l’empreinte ; rien n’est lancé en simulation."),

            new("poste.account.find", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["login"]);
                var login = BridgeArguments.GetString(values, "login");
                if (login.Length is 0 or > MaxTextLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("login") + " doit faire de 1 à " + FrenchText.Integer(MaxTextLength) + " caractères.");
                }
                return await Reader().FindAccountAsync(login, ct).ConfigureAwait(false);
            }, "Compte utilisateur d’une session (sAMAccountName, domaine retiré), pour ouvrir sa fiche ; null quand aucun compte ne correspond ; base locale."),

            new("poste.export.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var dn = Dn(args, ["kind", "files"]);
                var kind = BridgeArguments.GetString(dn.Values, "kind");
                if (!ExportKinds.Contains(kind))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit être un export connu de l’écran.");
                }
                var files = ExportFiles(dn.Values);
                var exporter = readers.Find<IPosteFileExport>() ?? throw new DomeniaOperationException(PosteErrors.HostUnavailable,
                    "Enregistrement d’un fichier impossible dans cet affichage : la liste a été copiée dans le presse-papiers à la place.");
                var local = TimeZoneInfo.ConvertTime(Now(), context.Clock.LocalTimeZone);
                var name = "Domenia-" + SafeFilePart(NameOf(dn.Dn)) + "-" + kind + "-" + local.ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".csv";
                var result = await exporter.SaveAsync(new ExportRequest(name, files), ct).ConfigureAwait(false);
                if (result.Saved)
                {
                    Journal("Export enregistré" + FrenchText.Colon + string.Join(", ", result.Names), Tone.Ok);
                }
                return result;
            }, "Enregistre un export CSV (une ou deux parties) dans le fichier choisi par l’opérateur (boîte « Enregistrer sous » de Windows), nommé d’après le poste ; aucune action sur un poste."),
        };
        operations.AddRange(LocalOperations(context, session, readers));
        operations.AddRange(PlanOperations(context, planClass, readers));
        return operations;
    }

    // ------------------------------------------------------------------ helpers

    private static IProgress<PosteProgress> Progress(BridgeContext bridge) => new BridgeProgress(bridge);

    /// <summary>Pushes « &lt;operation&gt;:progress » synchronously (no SynchronizationContext capture, no reordering).</summary>
    private sealed class BridgeProgress(BridgeContext bridge) : IProgress<PosteProgress>
    {
        public void Report(PosteProgress value) => bridge.Publish("progress", value);
    }

    /// <summary>Short name of a computer from its DN (first RDN), without any read.</summary>
    internal static string NameOf(string dn)
    {
        try
        {
            return PosteText.ShortName(DistinguishedName.Parse(dn)[0].Value);
        }
        catch (FormatException)
        {
            return "poste";
        }
    }

    private static string KindName(CollectionKind kind) => kind switch
    {
        CollectionKind.Inventory => "inventory",
        CollectionKind.Diagnostic => "diagnostic",
        CollectionKind.Probes => "probes",
        _ => "detection",
    };

    /// <summary>
    /// Binds the authorizations of the session to the account and the domain of the directory session (Domenia 1: they are
    /// cleared when the session changes); a change withdraws them all and stops every collection.
    /// </summary>
    internal static async Task BindSessionAsync(EngineContext context, PosteSession session, CancellationToken cancellationToken)
    {
        var info = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (session.EnsureSession(info.Account.Login + "|" + (info.Domain?.DnsName ?? ""), context.Clock.GetUtcNow()))
        {
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Autorisations du poste effacées" + FrenchText.Colon + "changement de session (autre compte ou autre domaine)", Tone.Info));
        }
    }

    /// <summary>
    /// Runs a stoppable collection of one workstation and one kind (Domenia 1 PST-052): « poste.collect.stop » cancels it. The
    /// readers of the inventory, the probes and the diagnosis return what was already read; a stop that reaches this point
    /// means nothing was read yet, which the page is told, never as an error of the workstation.
    /// </summary>
    private static async Task<T> Collect<T>(PosteSession session, string dn, CollectionKind kind, DateTimeOffset now, CancellationToken outer, Func<CancellationToken, Task<T>> run)
    {
        var source = session.BeginCollection(dn, NameOf(dn), kind, now, outer);
        try
        {
            return await run(source.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested && !outer.IsCancellationRequested)
        {
            throw new DomeniaOperationException(PosteErrors.Cancelled, kind == CollectionKind.Detection
                ? "Détection arrêtée à votre demande : l’association connue est gardée telle quelle, rien n’est relancé."
                : PosteErrors.CancelledMessage);
        }
        finally
        {
            session.EndCollection(dn, kind, source);
        }
    }

    /// <summary>The declared context fields of a suite tool (Domenia 1 Get-DomeniaSuiteContextFields), validated by the plan.</summary>
    internal static Dictionary<string, string?> SuiteContext(PosteConsole console, SessionSnapshot info) => new(StringComparer.Ordinal)
    {
        ["ComputerName"] = console.Computer.Name,
        ["ComputerGuid"] = console.Computer.Guid.ToString("D"),
        ["UserLogin"] = console.Association.User?.Login,
        ["UserGuid"] = console.Association.User?.Guid?.ToString("D"),
        ["Domain"] = info.Domain?.DnsName,
    };

    /// <summary>The files of an export: 1 or 2, known parts, CSV text of 8 Mio at most altogether.</summary>
    private static ImmutableArray<ExportFile> ExportFiles(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("files", out var files) || files.ValueKind != JsonValueKind.Array || files.GetArrayLength() is 0 or > 2)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("files") + " doit contenir une ou deux parties.");
        }
        var list = ImmutableArray.CreateBuilder<ExportFile>();
        var total = 0;
        foreach (var file in files.EnumerateArray())
        {
            var item = BridgeArguments.ReadObject(file, ["part", "csv"]);
            var part = BridgeArguments.GetString(item, "part");
            var csv = BridgeArguments.GetString(item, "csv");
            if (!ExportParts.Contains(part) || list.Any(f => f.Part == part))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("part") + " doit valoir lignes, sources ou liste, une fois chacune.");
            }
            total += csv.Length;
            if (total > MaxExportLength)
            {
                throw BridgeArguments.Invalid("export de plus de 8 Mio : filtrez la liste avant de l’exporter.");
            }
            list.Add(new ExportFile(part, csv));
        }
        return list.ToImmutable();
    }

    /// <summary>A computer name kept to letters, digits and hyphens in a file name.</summary>
    private static string SafeFilePart(string name)
    {
        var text = new string(name.Where(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-').ToArray());
        return text.Length == 0 ? "poste" : text[..Math.Min(text.Length, 63)];
    }

    /// <summary>Object with the allowed properties, « args » absent or null meaning {}.</summary>
    private static IReadOnlyDictionary<string, JsonElement> ReadOptionalObject(JsonElement args, IReadOnlyCollection<string> allowed) =>
        args.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null ? new Dictionary<string, JsonElement>() : BridgeArguments.ReadObject(args, allowed);

    /// <summary>« dn » (required, a well-formed DN) plus the other allowed properties.</summary>
    private static (string Dn, IReadOnlyDictionary<string, JsonElement> Values) Dn(JsonElement args, IReadOnlyCollection<string> others)
    {
        var values = BridgeArguments.ReadObject(args, [.. others, "dn"]);
        var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
        return (dn, values);
    }

    private static bool? OptionalBool(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit valoir true, false ou null.");
    }

    private static int? OptionalInt(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number) || number < min || number > max)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + (min == int.MinValue ? " doit être un nombre entier." : " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + "."));
        }
        return number;
    }

    /// <summary>A small closed set of names (ordinal).</summary>
    private sealed class FrozenStringSet(IEnumerable<string> values)
    {
        private readonly HashSet<string> set = new(values, StringComparer.Ordinal);

        public bool Contains(string value) => set.Contains(value);
    }

    // ------------------------------------------------------------------ BIOS references (LocalWrite)

    private const string BiosPreferencePrefix = "poste.biosReferences.";

    private static async Task<string> BiosKeyAsync(EngineContext context, CancellationToken cancellationToken)
    {
        var info = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var root = (info.Domain?.RootDn ?? "").ToUpperInvariant();
        return BiosPreferencePrefix + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(root)));
    }

    internal static async Task<ImmutableArray<BiosReference>> BiosBookAsync(EngineContext context, CancellationToken cancellationToken)
    {
        var key = await BiosKeyAsync(context, cancellationToken).ConfigureAwait(false);
        if (!context.Preferences.TryGet(key, out var stored) || stored.ValueKind != JsonValueKind.Array)
        {
            return [];
        }
        var list = ImmutableArray.CreateBuilder<BiosReference>();
        foreach (var item in stored.EnumerateArray())
        {
            try
            {
                var reference = item.Deserialize<BiosReference>(BridgeJson.Options);
                if (reference is not null && BiosReferences.IsValid(reference) && list.Count < BiosReferences.MaxModels)
                {
                    list.Add(reference);
                }
            }
            catch (JsonException)
            {
                // A malformed entry is dropped, never fatal (Domenia 1 ConvertTo-DomeniaBiosReferenceBook).
            }
        }
        return list.ToImmutable();
    }

    private static async Task SaveBiosBookAsync(EngineContext context, ImmutableArray<BiosReference> book, CancellationToken cancellationToken)
    {
        var key = await BiosKeyAsync(context, cancellationToken).ConfigureAwait(false);
        try
        {
            await context.Preferences.SetAsync(key, JsonSerializer.SerializeToElement(book, BridgeJson.Options), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Préférences non enregistrées (références BIOS) : {ex.GetType().Name}.");
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "la référence BIOS vaut pour cette session", Tone.Warn));
        }
    }
}
