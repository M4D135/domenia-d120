using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

/// <summary>
/// The workstation console (screen « poste », docs/ops/poste.md): local reads of the console (list, console, stored readings,
/// cached software), network reads made only after an explicit gesture on one workstation (ping, live state, inventory,
/// software, services, processes, events, sessions, diagnosis, WMI explorer, probes, slow triage, logons, last user, secrets,
/// WAPT), plans of the writes and remote actions (reads too: the write itself is always write.execute), the authorizations of
/// the session (Local) and the approved BIOS references (LocalWrite). Handlers only validate their arguments and delegate.
/// </summary>
public sealed partial class PosteOperations : IOperationModule
{
    private const int MaxTextLength = 100;
    private const int MaxDsregLength = PosteDsreg.MaxLength;

    public string Screen => "poste";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var scope = WorkingScope.From(context);
        var session = PosteSession.For(context.Directory);
        var policy = PosteHealthPolicy.Default;
        var simulation = context.Mode == AppMode.Simulation;
        var planClass = simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;

        IPosteReader Reader() => readers.Require<IPosteReader>();
        DateTimeOffset Now() => context.Clock.GetUtcNow();

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
                return await Reader().ListAsync(current, text, limit, policy, ct).ConfigureAwait(false);
            }, "Postes de l’OU de travail, filtrés localement (nom, utilisateur, système, site) ; base locale seulement."),

            new("poste.open", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                return await Reader().OpenAsync(dn.Dn, policy, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
            }, "Console d’un poste à partir de sa fiche et des observations enregistrées ; aucune lecture réseau."),

            Network("poste.ping", async (args, _, ct) =>
            {
                var dn = Dn(args, []);
                var reading = await Reader().PingAsync(dn.Dn, ct).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(Now(), "Ping" + FrenchText.Colon + (reading.Answered == true ? "répond en " + FrenchText.Integer(reading.RoundTripMs ?? 0) + " ms" : "pas de réponse"), reading.Answered == true ? Tone.Ok : Tone.Warn));
                return reading;
            }, "Un seul écho ICMP vers le poste, enregistré avant affichage."),

            Network("poste.live", async (args, _, ct) =>
                await Reader().LiveAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "État en direct : présence, durée de fonctionnement, utilisateur connecté."),

            Network("poste.inventory", async (args, bridge, ct) =>
            {
                var dn = Dn(args, ["deep"]);
                var deep = OptionalBool(dn.Values, "deep") ?? false;
                var result = await Collect(session, dn.Dn, ct, token => Reader().InventoryAsync(dn.Dn, deep, policy, Progress(bridge), token)).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(Now(), (deep ? "Inventaire complet" : "Inventaire rapide") + FrenchText.Colon + result.Computer + " · " + FrenchText.Count(result.Access.Count(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial), "source lue", "sources lues"), Tone.Ok));
                return result;
            }, "Inventaire rapide (55 s au plus) ou complet (150 s au plus) du poste, enregistré comme le dernier ; arrêtable."),

            new("poste.collect.stop", OperationClass.Local, (args, _, _) =>
            {
                var dn = Dn(args, []);
                var stopped = session.StopCollection(dn.Dn);
                return Task.FromResult<object?>(new { stopped, text = stopped ? "Arrêt demandé : les valeurs déjà lues sont conservées." : "Aucun relevé en cours pour ce poste." });
            }, "Arrête le relevé en cours du poste ouvert (inventaire, sondes, diagnostic) ; les valeurs déjà lues sont conservées."),

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
            }, "Événements d’un préréglage, fenêtre de 1 à 720 h, 1 à 200 événements (bornes signalées)."),

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
                var result = await Collect(session, dn.Dn, ct, token => Reader().DiagnosticAsync(dn.Dn, Progress(bridge), token)).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(Now(), "Diagnostic" + FrenchText.Colon + result.Computer + " · " + FrenchText.Integer(result.Passed) + " réussi(s), " + FrenchText.Integer(result.Failed) + " en échec", result.Failed > 0 ? Tone.Warn : Tone.Ok));
                return result;
            }, "Diagnostic du poste (DNS, ping, ports, CIM, C$, WinRM, transports), verdict et couche bloquante."),

            Network("poste.quickDiag", async (args, _, ct) =>
                await Reader().QuickDiagnosticAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Diagnostic rapide borné : cinq contrôles en lecture seule, 20 s annoncées, sans repli."),

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
                var dn = Dn(args, []);
                var store = await Collect(session, dn.Dn, ct, token => Reader().CollectProbesAsync(dn.Dn, Progress(bridge), token)).ConfigureAwait(false);
                var book = await BiosBookAsync(context, ct).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(Now(), "Relevé des sondes" + FrenchText.Colon + store.Computer, Tone.Ok));
                return PosteReadings.Build(store, policy, book, Now(), context.Clock.LocalTimeZone);
            }, "Relève une fois les sondes du tableau du poste, puis les enregistre ; arrêtable."),

            Network("poste.slow", async (args, _, ct) =>
                await Reader().SlowTriageAsync(Dn(args, []).Dn, policy, ct).ConfigureAwait(false),
                "Tri d’un poste lent : mémoire, processeur mesuré, disques, démarrage, journaux, réseau ; aucune action lancée."),

            Network("poste.logonByDc", async (args, _, ct) =>
                await Reader().LogonByControllerAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "lastLogon du compte ordinateur sur chaque contrôleur, avec la couverture."),

            Network("poste.lastUser.detect", async (args, bridge, ct) =>
                await Reader().DetectLastUserAsync(Dn(args, []).Dn, Progress(bridge), ct).ConfigureAwait(false),
                "Détection du dernier utilisateur (association locale, CIM, LogonUI, profils…) ; une association existante n’est jamais écrasée."),

            Network("poste.laps", async (args, _, ct) =>
                await Reader().LapsAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Métadonnées LAPS du poste (source, publication, expiration, déchiffreur) ; jamais le mot de passe."),

            Network("poste.laps.reveal", async (args, _, ct) =>
            {
                var reveal = await Reader().RevealLapsAsync(Dn(args, []).Dn, ct).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(Now(), "Mot de passe LAPS affiché" + FrenchText.Colon + reveal.Computer + " (valeur jamais journalisée)", Tone.Info));
                return reveal;
            }, "Lit le mot de passe LAPS pour une seule révélation de 30 s ; jamais journalisé ni gardé."),

            Network("poste.bitlocker.list", async (args, _, ct) =>
                await Reader().BitLockerListAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Objets de récupération BitLocker sous le poste (métadonnées seulement, 256 au plus)."),

            Network("poste.bitlocker.reveal", async (args, _, ct) =>
            {
                var dn = Dn(args, ["key"]);
                var key = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(dn.Values, "key"), "key");
                var reveal = await Reader().RevealBitLockerAsync(dn.Dn, key, ct).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(Now(), "Clé BitLocker affichée" + FrenchText.Colon + reveal.Computer + " · identifiant " + reveal.Identifier + " (valeur jamais journalisée)", Tone.Info));
                return reveal;
            }, "Lit une seule clé, enfant direct du poste, par une recherche Base sur son DN ; jamais journalisée."),

            Network("poste.wapt", async (args, _, ct) =>
                await Reader().WaptAsync(Dn(args, []).Dn, ct).ConfigureAwait(false),
                "Enregistrement WAPT du poste (connecteur en lecture seule)."),

            new("poste.tool.open", OperationClass.NetworkRead, (args, _, _) =>
            {
                var dn = Dn(args, ["tool"]);
                var tool = BridgeArguments.GetString(dn.Values, "tool");
                if (tool is not ("rdp" or "c" or "compmgmt" or "eventvwr" or "services"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("tool") + " doit valoir rdp, c, compmgmt, eventvwr ou services.");
                }
                throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Ouverture d’un outil Windows vers le poste non disponible dans cette version : copiez la commande (vue Intervenir).");
            }, "Ouvre un outil Windows vers le poste (Bureau à distance, C$, Gestion, Observateur, Services) ; jamais en simulation."),
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

    /// <summary>
    /// Runs a stoppable collection of one workstation (Domenia 1 PST-052): « poste.collect.stop » cancels it; values already read
    /// are kept and the page is told the stop was asked, never that it was an error.
    /// </summary>
    private static async Task<T> Collect<T>(PosteSession session, string dn, CancellationToken outer, Func<CancellationToken, Task<T>> run)
    {
        var source = session.BeginCollection(dn, outer);
        try
        {
            return await run(source.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested && !outer.IsCancellationRequested)
        {
            throw new DomeniaOperationException(PosteErrors.Cancelled, PosteErrors.CancelledMessage);
        }
        finally
        {
            session.EndCollection(dn, source);
        }
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
            context.Log.Warning($"Préférences non enregistrées (références BIOS) : {ex.GetType().Name}.");
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "la référence BIOS vaut pour cette session", Tone.Warn));
        }
    }
}
