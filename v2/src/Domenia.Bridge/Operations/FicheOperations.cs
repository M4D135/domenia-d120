using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Operations of the « Fiche » screen (docs/ops/fiche.md): the object card of a user, computer, group, OU or contact, its tabs
/// (general, account, groups, members, relations, rights, attributes, history, call sheet), the explicit network reads started
/// from it, and the plans of its writes. Reads of the fictitious directory are LocalRead in simulation and NetworkRead in
/// directory mode (after the operator opens the fiche or a tab); the explicit probes (4740, per-controller logons, presence,
/// rights, call sheet reads) are NetworkRead, served by the simulation. Writes are plans only: the write itself always goes
/// through write.execute (docs/WRITES.md). The local memory of recent fiches is LocalWrite (preferences of the application).
/// </summary>
public sealed class FicheOperations : IOperationModule
{
    public const int MaxText = 256;
    public const int PickLimit = 20;
    public const int RecentLimit = 12;
    public const int MaxChildren = 2000;
    public const string RecentKey = "fiche.recent";

    private static readonly string[] DnArguments = ["dn"];
    private static readonly string[] ResolveArguments = ["text"];
    private static readonly string[] PickArguments = ["text", "kinds"];
    private static readonly string[] WhyArguments = ["dn", "group"];
    private static readonly string[] CompareArguments = ["dn", "other"];
    private static readonly string[] DeltaArguments = ["dn", "current", "add", "remove"];
    private static readonly string[] LockoutArguments = ["dn", "hours"];
    private static readonly string[] CallSheetArguments = ["dn", "computer"];
    private static readonly string[] CallSheetReadArguments = ["dn", "read", "computer"];
    private static readonly string[] UpdateArguments = ["dn", "fields"];
    private static readonly string[] EnableArguments = ["dn", "enabled"];
    private static readonly string[] ExpirationArguments = ["dn", "date"];
    private static readonly string[] OptionsArguments = ["dn", "options"];
    private static readonly string[] RawArguments = ["dn", "attribute", "value"];
    private static readonly string[] MoveArguments = ["dn", "target"];
    private static readonly string[] MemberArguments = ["group", "member", "add"];
    private static readonly string[] CreateOuArguments = ["parent", "name"];
    private static readonly string[] ResetArguments = ["dn", "mustChange", "unlock"];

    private const string NoWritesReason = "Écritures réelles non disponibles dans cette version : elles arriveront avec la lecture de l’annuaire (vague 3). Essayez-les en simulation.";

    public string Screen => "fiche";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var writers = context.Writers;
        var circuit = WriteCircuit.From(context);
        var session = FicheSession.From(context);
        var clock = context.Clock;
        var preferences = context.Preferences;
        var journal = context.Journal;
        var log = context.Log;
        var simulation = context.Mode == AppMode.Simulation;
        var policy = FicheSecurityPolicy.For(context.Mode);
        var readClass = simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        var sourceName = simulation ? "simulation" : "annuaire";
        IFicheReader Reader() => readers.Require<IFicheReader>();
        TimeZoneInfo Zone() => clock.LocalTimeZone;

        async Task<FicheSheet> SheetAsync(FicheEntry entry, string source, DateTimeOffset readAt, string? controller, bool preview, CancellationToken ct)
        {
            var reader = Reader();
            var relations = await reader.RelationsAsync(entry.Dn, ct).ConfigureAwait(false);
            var dns = new List<string>();
            foreach (var attribute in new[] { "manager", "managedBy" })
            {
                if (entry.First(attribute) is string value)
                {
                    dns.Add(value);
                }
            }
            var index = await reader.IndexAsync(dns, ct).ConfigureAwait(false);
            FicheObservation? observation = null;
            if (entry.Kind == FicheKind.Computer)
            {
                observation = session.WithPing(await reader.ObservationAsync(entry.Dn, ct).ConfigureAwait(false), entry.Dn, entry.Name);
            }
            else if (entry.Kind == FicheKind.User && relations.Associations.FirstOrDefault() is FicheAssociation primary)
            {
                observation = session.WithPing(await reader.ObservationAsync(primary.Dn, ct).ConfigureAwait(false), primary.Dn, primary.Name);
            }
            int? children = null;
            if (!preview && entry.Kind is FicheKind.Ou or FicheKind.Container)
            {
                children = (await reader.ChildrenAsync(entry.Dn, MaxChildren, ct).ConfigureAwait(false)).Dns.Length;
            }
            var writes = writers.Find<IObjectUpdateExecutor>() is not null;
            var sheetContext = new FicheContext(source, readAt, controller, preview, clock.GetUtcNow(), Zone(), RootOf(entry.Dn), index, relations.Associations, observation, children,
                entry.Kind == FicheKind.User ? relations.Reports.Length : null, writes, writes ? null : NoWritesReason, FicheDiagnostics.Interval(null, simulation ? "absent" : "notRead"), policy);
            return FicheSheets.Build(entry, sheetContext);
        }

        async Task<FicheRead> FreshAsync(string dn, CancellationToken ct)
        {
            var read = await Reader().ReadAsync(dn, ct).ConfigureAwait(false);
            session.KeepRead(read);
            session.Observe(read.Entry, read.ReadAt);
            return read;
        }

        async Task<FicheRead> KnownAsync(string dn, CancellationToken ct) => session.LastRead(dn) ?? await FreshAsync(dn, ct).ConfigureAwait(false);

        async Task<FicheSummary> ResolveAsync(string text, IReadOnlyCollection<FicheKind> kinds, CancellationToken ct)
        {
            var reader = Reader();
            var value = text.Trim();
            if (LooksLikeDn(value))
            {
                var found = await reader.IndexAsync([value], ct).ConfigureAwait(false);
                if (found.Values.FirstOrDefault() is FicheSummary exact && (kinds.Count == 0 || kinds.Contains(exact.Kind)))
                {
                    return exact;
                }
                throw FicheErrors.Error(FicheErrors.NotFound, FicheErrors.NotFoundMessage);
            }
            var login = value.Contains('\\', StringComparison.Ordinal) ? value[(value.LastIndexOf('\\') + 1)..] : value;
            var candidates = await reader.SearchLocalAsync(login, kinds, 50, ct).ConfigureAwait(false);
            var matches = candidates.Where(c => string.Equals(c.Sam, login, StringComparison.OrdinalIgnoreCase)
                || string.Equals(c.Upn, login, StringComparison.OrdinalIgnoreCase)
                || string.Equals(c.Name, login, StringComparison.OrdinalIgnoreCase)
                || (c.Kind == FicheKind.Computer && string.Equals(c.Sam, login + "$", StringComparison.OrdinalIgnoreCase))).ToList();
            return matches.Count switch
            {
                1 => matches[0],
                0 => throw FicheErrors.Error(FicheErrors.NotFound, FicheErrors.NotFoundMessage),
                _ => throw FicheErrors.Error(FicheErrors.Ambiguous, FicheErrors.AmbiguousMessage),
            };
        }

        async Task<FicheCallSheet> CallSheetAsync(string dn, CancellationToken ct)
        {
            var reader = Reader();
            var kept = session.LastRead(dn);
            FicheEntry entry;
            string origin;
            DateTimeOffset? observedAt;
            string? server;
            if (kept is not null)
            {
                (entry, origin, observedAt, server) = (kept.Entry, "live", kept.ReadAt, kept.Controller);
            }
            else
            {
                var local = await reader.PreviewAsync(dn, ct).ConfigureAwait(false) ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
                (entry, origin, observedAt, server) = (local.Entry, "cache", local.ReadAt, null);
            }
            if (entry.Kind != FicheKind.User)
            {
                throw FicheErrors.Error(FicheErrors.NotApplicable, "La fiche d’appel concerne un compte utilisateur : rien n’a été calculé.");
            }
            var relations = await reader.RelationsAsync(entry.Dn, ct).ConfigureAwait(false);
            var observations = new Dictionary<string, FicheObservation>(StringComparer.OrdinalIgnoreCase);
            var pinged = false;
            foreach (var link in relations.Associations)
            {
                pinged |= session.Ping(link.Dn) is not null;
                if (session.WithPing(await reader.ObservationAsync(link.Dn, ct).ConfigureAwait(false), link.Dn, link.Name) is FicheObservation observation)
                {
                    observations[link.Dn] = observation;
                }
            }
            var groups = await reader.IndexAsync([.. entry.All("memberOf")], ct).ConfigureAwait(false);
            IReadOnlyList<ReceiptRow>? receipts = null;
            DateTimeOffset? receiptsAt = null;
            try
            {
                receipts = (await circuit.ListAsync(ct).ConfigureAwait(false)).Receipts;
                receiptsAt = clock.GetUtcNow();
            }
            catch (DomeniaOperationException ex) when (ex.Code == WriteErrors.ReceiptUnavailable)
            {
                log.Warning("Fiche d’appel : reçus illisibles pour l’instant.");
            }
            var triageDn = session.TriageTarget(entry.ObjectGuid) ?? relations.Associations.FirstOrDefault()?.Dn;
            FicheInventoryReading? inventory = null;
            if (triageDn is not null)
            {
                inventory = session.Inventory(triageDn) ?? await reader.StoredInventoryAsync(triageDn, ct).ConfigureAwait(false);
            }
            var policyKept = session.Policy(entry.ObjectGuid);
            var input = new FicheCallInput(entry, origin, observedAt, server, policyKept?.View, policyKept?.Reading.ReadAt, policyKept?.Reading.Controller,
                session.Lockouts(entry.ObjectGuid), relations.Associations, observations, session.Sessions(relations.Associations.Select(a => a.Dn)),
                session.Baseline(entry.ObjectGuid), groups, receipts, receiptsAt, triageDn, inventory, triageDn is null ? null : observations.GetValueOrDefault(triageDn), pinged);
            return FicheCallSheets.Build(input, clock.GetUtcNow(), Zone());
        }

        async Task<FicheLockoutDiagnosis> LockoutsAsync(string dn, int hours, CancellationToken ct)
        {
            var reader = Reader();
            var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
            if (entry.Kind != FicheKind.User)
            {
                throw FicheErrors.Error(FicheErrors.NotApplicable, "Le journal des verrouillages se lit pour un compte utilisateur : rien n’a été lu.");
            }
            var sid = entry.First("objectSid");
            if (sid is null || !sid.StartsWith("S-1-5-21-", StringComparison.Ordinal))
            {
                throw FicheErrors.Error(FicheErrors.Refused, "SID du compte non lu ou non valide : la lecture du journal Sécurité ne part pas.");
            }
            var read = await reader.LockoutEventsAsync(entry.Dn, hours, 200, ct).ConfigureAwait(false);
            var keys = new[] { entry.First("sAMAccountName"), entry.First("userPrincipalName") }.Where(k => k is not null).Select(k => k!).ToList();
            var duration = session.Policy(entry.ObjectGuid)?.Reading.LockoutDuration ?? TimeSpan.Zero;
            var diagnosis = FicheDiagnostics.Lockouts(entry, read, [], keys, duration, clock.GetUtcNow(), Zone());
            session.KeepLockouts(entry.ObjectGuid, diagnosis);
            return diagnosis;
        }

        async Task<string> ComputerOfAsync(string userDn, string? computer, CancellationToken ct)
        {
            if (computer is not null)
            {
                return BridgeArguments.RequireDistinguishedName(computer, "computer");
            }
            var relations = await Reader().RelationsAsync(userDn, ct).ConfigureAwait(false);
            return relations.Associations.FirstOrDefault()?.Dn
                ?? throw FicheErrors.Error(FicheErrors.NotApplicable, "Aucun poste associé à ce compte : présence, sessions et tri restent inconnus (pas « aucun poste »).");
        }

        async Task<object?> RecentAsync(CancellationToken ct)
        {
            var items = ReadRecent(preferences);
            var index = await Reader().IndexAsync([.. items.Select(i => i.Dn)], ct).ConfigureAwait(false);
            return items.Select(i => index.TryGetValue(i.Dn, out var known)
                ? new FicheRecent(known.Dn, known.Name, known.Kind, known.Detail, i.At, true)
                : i with { Exists = false }).ToImmutableArray();
        }

        async Task<object?> SaveRecentAsync(ImmutableArray<FicheRecent> items, CancellationToken ct)
        {
            var array = JsonSerializer.SerializeToElement(items.Select(i => new { dn = i.Dn, name = i.Name, kind = FicheSheets.KindId(i.Kind), detail = i.Detail, at = i.At.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture) }));
            try
            {
                await preferences.SetAsync(RecentKey, items.IsEmpty ? null : array, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // A local write that fails never fails the operation: the list is kept for the session (OPERATIONS.md § 1.3).
                log.Warning($"Préférences de la fiche non enregistrées ({ex.GetType().Name}).");
                journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "dernières fiches gardées pour la session.", Tone.Warn));
            }
            return items;
        }

        async Task<PlannedWrite> PlanAsync(Task<WritePlanDraft> draft, CancellationToken ct) => await circuit.PlanAsync(await draft.ConfigureAwait(false), ct).ConfigureAwait(false);

        return
        [
            new OperationDefinition("fiche.preview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var local = await Reader().PreviewAsync(dn, ct).ConfigureAwait(false);
                return local is null ? null : await SheetAsync(local.Entry, "baseLocale", local.ReadAt, null, true, ct).ConfigureAwait(false);
            }, "Aperçu local d’une fiche (base locale), affiché avant la lecture de l’annuaire ; null sans projection locale."),

            new OperationDefinition("fiche.read", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var read = await FreshAsync(dn, ct).ConfigureAwait(false);
                return await SheetAsync(read.Entry, sourceName, read.ReadAt, read.Controller, false, ct).ConfigureAwait(false);
            }, "Fiche d’un objet lue dans l’annuaire : identité, états, sections, compte, actions, onglets."),

            new OperationDefinition("fiche.resolve", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ResolveArguments);
                var text = Text(values, "text", MaxText);
                var found = await ResolveAsync(text, [], ct).ConfigureAwait(false);
                return found;
            }, "Objet de la base locale désigné exactement par un identifiant, DOMAINE\\compte, UPN, nom ou DN."),

            new OperationDefinition("fiche.pick", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PickArguments);
                var text = Text(values, "text", 100);
                var kinds = Kinds(values);
                return await Reader().SearchLocalAsync(text, kinds, PickLimit, ct).ConfigureAwait(false);
            }, "Sélecteur d’objets : au plus 20 objets de la base locale dont le nom, le compte ou l’UPN contient le texte."),

            new OperationDefinition("fiche.recent", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await RecentAsync(ct).ConfigureAwait(false);
            }, "Dernières fiches ouvertes (préférences locales), les plus récentes d’abord."),

            new OperationDefinition("fiche.recent.add", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var found = await Reader().IndexAsync([dn], ct).ConfigureAwait(false);
                var known = found.Values.FirstOrDefault() ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
                var items = ReadRecent(preferences).Where(i => !FicheValues.SameDn(i.Dn, known.Dn)).Prepend(new FicheRecent(known.Dn, known.Name, known.Kind, known.Detail, clock.GetUtcNow(), true))
                    .Take(RecentLimit).ToImmutableArray();
                return await SaveRecentAsync(items, ct).ConfigureAwait(false);
            }, "Mémorise une fiche ouverte dans les préférences locales (12 au plus)."),

            new OperationDefinition("fiche.recent.clear", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await SaveRecentAsync([], ct).ConfigureAwait(false);
            }, "Efface la liste des dernières fiches."),

            new OperationDefinition("fiche.attributes", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var read = await FreshAsync(dn, ct).ConfigureAwait(false);
                return FicheAttributeRules.Rows(read.Entry, policy, Zone(), read.HiddenSensitive);
            }, "Attributs bruts de l’objet, triés, dates converties, attributs sensibles exclus."),

            new OperationDefinition("fiche.groups", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                var index = await Reader().IndexAsync([.. entry.All("memberOf")], ct).ConfigureAwait(false);
                return FicheMemberships.Groups(entry, index, FicheMemberships.PrimaryGroup(entry.Int32("primaryGroupID"), null, null));
            }, "Groupes directs de l’objet (memberOf) et son groupe principal."),

            new OperationDefinition("fiche.groups.nested", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var graph = await Reader().GroupGraphAsync(dn, ct).ConfigureAwait(false);
                var index = await Reader().IndexAsync([.. graph.Nodes.Keys], ct).ConfigureAwait(false);
                return FicheMemberships.Nested(graph, index);
            }, "Groupes atteints par imbrication (2 000 groupes, 16 niveaux), avec le groupe direct « via »."),

            new OperationDefinition("fiche.groups.why", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, WhyArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var group = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "group"), "group");
                var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                var name = (await Reader().IndexAsync([group], ct).ConfigureAwait(false)).Values.FirstOrDefault()?.Name ?? FicheValues.DisplayName(group);
                var objectName = entry.First("displayName") ?? entry.Name;
                if (entry.All("memberOf").Any(g => FicheValues.SameDn(g, group)))
                {
                    return FicheMemberships.Why(entry.Dn, objectName, group, name, true, null, false);
                }
                var graph = await Reader().GroupGraphAsync(entry.Dn, ct).ConfigureAwait(false);
                var primary = graph.Primary?.Dn is string primaryDn && FicheValues.SameDn(primaryDn, group);
                return FicheMemberships.Why(entry.Dn, objectName, group, name, false, graph, primary);
            }, "« Pourquoi membre ? » : appartenance directe, chemin d’imbrication ou groupe principal."),

            new OperationDefinition("fiche.groups.delta", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, DeltaArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var delta = FicheMemberships.Delta(DnList(values, "current"), DnList(values, "add"), DnList(values, "remove"), dn);
                return Task.FromResult<object?>(delta);
            }, "Ajouts et retraits choisis seulement (jamais la liste complète) : un plan d’écriture par groupe."),

            new OperationDefinition("fiche.members", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var reader = Reader();
                var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                if (entry.Kind == FicheKind.Group)
                {
                    var members = entry.All("member");
                    var index = await reader.IndexAsync(members, ct).ConfigureAwait(false);
                    return FicheMemberships.Members(entry.Dn, "members", members, index, true, null);
                }
                if (entry.Kind is FicheKind.Ou or FicheKind.Container)
                {
                    var children = await reader.ChildrenAsync(entry.Dn, MaxChildren, ct).ConfigureAwait(false);
                    var index = await reader.IndexAsync(children.Dns, ct).ConfigureAwait(false);
                    return FicheMemberships.Members(entry.Dn, "children", children.Dns, index, children.Complete, children.Note);
                }
                throw FicheErrors.Error(FicheErrors.NotApplicable, "Seuls les groupes ont des membres et les branches un contenu : rien n’a été lu.");
            }, "Membres directs d’un groupe ou contenu d’une OU, types résolus dans la base locale (2 000 au plus)."),

            new OperationDefinition("fiche.relations", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var reader = Reader();
                var relations = await reader.RelationsAsync(dn, ct).ConfigureAwait(false);
                var dns = new List<string>();
                if (relations.ManagerDn is not null)
                {
                    dns.Add(relations.ManagerDn);
                }
                if (relations.ManagedByDn is not null)
                {
                    dns.Add(relations.ManagedByDn);
                }
                dns.AddRange(relations.Reports);
                dns.AddRange(relations.Manages);
                var index = await reader.IndexAsync(dns, ct).ConfigureAwait(false);
                FicheLink Link(string target) => index.TryGetValue(target, out var known)
                    ? new FicheLink(known.Dn, known.Name, FicheSheets.KindId(known.Kind), known.Detail)
                    : new FicheLink(target, FicheValues.DisplayName(target), "unknown", null);
                return new FicheRelations(dn, relations.ManagerDn is null ? null : Link(relations.ManagerDn), [.. relations.Reports.Select(Link)],
                    relations.ManagedByDn is null ? null : Link(relations.ManagedByDn), [.. relations.Manages.Select(Link)], relations.Associations,
                    "Relations de la base locale : responsable et équipe, gestion (managedBy) et associations entre comptes et postes, chacune avec sa règle. Aucun pourcentage de fiabilité.");
            }, "Relations de l’objet : responsable, équipe, gestion et associations comptes ↔ postes."),

            new OperationDefinition("fiche.history", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                var changes = await Reader().AttributeHistoryAsync(entry.Dn, ct).ConfigureAwait(false);
                IReadOnlyList<ReceiptRow> receipts = [];
                try
                {
                    var guid = entry.ObjectGuid.ToString("D");
                    receipts = [.. (await circuit.ListAsync(ct).ConfigureAwait(false)).Receipts.Where(r => string.Equals(r.Target.ObjectGuid, guid, StringComparison.OrdinalIgnoreCase))];
                }
                catch (DomeniaOperationException ex) when (ex.Code == WriteErrors.ReceiptUnavailable)
                {
                    log.Warning("Historique de la fiche : reçus illisibles pour l’instant.");
                }
                return FicheRelationRules.History(entry, changes, receipts, session.Baseline(entry.ObjectGuid), clock.GetUtcNow(), Zone());
            }, "Historique de l’objet : dates lues, métadonnées de réplication, reçus Domenia, changements vus pendant la session."),

            new OperationDefinition("fiche.rights", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var reading = await Reader().SecurityAsync(dn, ct).ConfigureAwait(false);
                return FicheDiagnostics.Rights(reading, Zone());
            }, "Estimation des droits effectifs du compte de session sur l’objet (DACL), avec l’entrée décisive.", ServedInSimulation: true),

            new OperationDefinition("fiche.lockouts", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, LockoutArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var hours = OptionalInt(values, "hours", 1, 720) ?? 168;
                return await LockoutsAsync(dn, hours, ct).ConfigureAwait(false);
            }, "Verrouillages du compte (événements 4740 de l’émulateur PDC, son SID seulement, fenêtre bornée).", ServedInSimulation: true),

            new OperationDefinition("fiche.logonByDc", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                var readings = await Reader().LogonReadingsAsync(entry.Dn, ct).ConfigureAwait(false);
                return FicheDiagnostics.MergeReadings(readings, entry.FileTime("lastLogonTimestamp"), Zone());
            }, "Connexion exacte (lastLogon, logonCount) sur chaque contrôleur, avec la couverture.", ServedInSimulation: true),

            new OperationDefinition("fiche.presence", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var dn = Dn(args);
                var reader = Reader();
                var known = (await reader.IndexAsync([dn], ct).ConfigureAwait(false)).Values.FirstOrDefault() ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
                if (known.Kind == FicheKind.Computer)
                {
                    var reading = await reader.PingAsync(known.Dn, ct).ConfigureAwait(false);
                    session.KeepPing(reading);
                    return reading;
                }
                if (known.Kind != FicheKind.User)
                {
                    throw FicheErrors.Error(FicheErrors.NotApplicable, "La présence se mesure sur un poste ou sur le poste associé d’un compte : rien n’a été envoyé.");
                }
                var relations = await reader.RelationsAsync(known.Dn, ct).ConfigureAwait(false);
                if (relations.Associations.FirstOrDefault() is not FicheAssociation link)
                {
                    return new FichePresenceReading(null, null, "unknown", "Aucun poste associé", clock.GetUtcNow(), null, null,
                        "Un compte n’a pas d’adresse : sa présence se mesure sur son poste associé, et aucun n’est connu. Présence inconnue, pas « aucun poste ».", null);
                }
                var ping = await reader.PingAsync(link.Dn, ct).ConfigureAwait(false);
                session.KeepPing(ping);
                return ping with { Via = "Poste associé " + link.Name + " (" + link.EvidenceLabel + (link.Primary ? ", principal" : "") + ")" };
            }, "Présence d’un poste, ou d’un compte par son poste associé le plus fiable (un ping).", ServedInSimulation: true),

            new OperationDefinition("fiche.compare", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CompareArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var other = Text(values, "other", MaxText);
                var right = await ResolveAsync(other, [FicheKind.User], ct).ConfigureAwait(false);
                var reader = Reader();
                var left = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                if (left.Kind != FicheKind.User)
                {
                    throw FicheErrors.Error(FicheErrors.NotApplicable, "Les droits se comparent entre deux comptes utilisateur : rien n’a été lu.");
                }
                if (FicheValues.SameDn(left.Dn, right.Dn))
                {
                    throw FicheErrors.Error(FicheErrors.Invalid, "Choisissez un autre compte que celui de la fiche : rien n’a été lu.");
                }
                var rightEntry = (await reader.ReadAsync(right.Dn, ct).ConfigureAwait(false)).Entry;
                var leftGraph = await reader.GroupGraphAsync(left.Dn, ct).ConfigureAwait(false);
                var rightGraph = await reader.GroupGraphAsync(rightEntry.Dn, ct).ConfigureAwait(false);
                return FicheMemberships.Compare(left, leftGraph, rightEntry, rightGraph, clock.GetUtcNow(), Zone());
            }, "Droits comparés de deux utilisateurs (groupes directs, imbriqués et principal, attributs d’organisation)."),

            new OperationDefinition("fiche.callSheet", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CallSheetArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                if (BridgeArguments.GetOptionalString(values, "computer") is string computer)
                {
                    var target = BridgeArguments.RequireDistinguishedName(computer, "computer");
                    var kept = session.LastRead(dn);
                    if (kept is null)
                    {
                        var local = await Reader().PreviewAsync(dn, ct).ConfigureAwait(false) ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
                        kept = new FicheRead(local.Entry, local.ReadAt, null, 0);
                    }
                    session.ChooseTriage(kept.Entry.ObjectGuid, target);
                }
                return await CallSheetAsync(dn, ct).ConfigureAwait(false);
            }, "Fiche d’appel d’un compte, construite sans lecture réseau à partir de la fiche et des lectures déjà faites."),

            new OperationDefinition("fiche.callSheet.read", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CallSheetReadArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var read = BridgeArguments.GetString(values, "read");
                var computer = BridgeArguments.GetOptionalString(values, "computer");
                var reader = Reader();
                switch (read)
                {
                    case "lockouts":
                        await LockoutsAsync(dn, 168, ct).ConfigureAwait(false);
                        break;
                    case "policy":
                        var entry = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                        var reading = await reader.PasswordPolicyAsync(entry.Dn, ct).ConfigureAwait(false);
                        session.KeepPolicy(entry.ObjectGuid, FicheDiagnostics.Policy(entry, reading, clock.GetUtcNow(), Zone()), reading);
                        break;
                    case "presence":
                        session.KeepPing(await reader.PingAsync(await ComputerOfAsync(dn, computer, ct).ConfigureAwait(false), ct).ConfigureAwait(false));
                        break;
                    case "sessions":
                        session.KeepSessions(await reader.SessionsAsync(await ComputerOfAsync(dn, computer, ct).ConfigureAwait(false), ct).ConfigureAwait(false));
                        break;
                    case "triage":
                        var target = await ComputerOfAsync(dn, computer, ct).ConfigureAwait(false);
                        var user = (await KnownAsync(dn, ct).ConfigureAwait(false)).Entry;
                        session.ChooseTriage(user.ObjectGuid, target);
                        session.KeepInventory(await reader.InventoryAsync(target, ct).ConfigureAwait(false));
                        break;
                    default:
                        throw BridgeArguments.Invalid(FrenchText.Quote("read") + " doit valoir lockouts, policy, presence, sessions ou triage.");
                }
                return await CallSheetAsync(dn, ct).ConfigureAwait(false);
            }, "Lecture explicite de la fiche d’appel (4740, stratégie, présence, sessions, tri du poste), puis la fiche à jour.", ServedInSimulation: true),

            new OperationDefinition("fiche.update.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, UpdateArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var fields = FieldMap(values);
                return await PlanAsync(writers.Require<IObjectUpdateExecutor>().PlanAsync(dn, fields, ct), ct).ConfigureAwait(false);
            }, "Plan de l’enregistrement des champs modifiés d’une fiche ; rien n’est écrit."),

            new OperationDefinition("fiche.enable.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, EnableArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var enabled = BridgeArguments.GetBoolean(values, "enabled");
                return await PlanAsync(writers.Require<IAccountEnabledExecutor>().PlanAsync(dn, enabled, ct), ct).ConfigureAwait(false);
            }, "Plan de l’activation ou de la désactivation d’un compte ; rien n’est écrit."),

            new OperationDefinition("fiche.expiration.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ExpirationArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var day = OptionalDate(values, "date");
                return await PlanAsync(writers.Require<IAccountExpirationExecutor>().PlanAsync(dn, day, ct), ct).ConfigureAwait(false);
            }, "Plan de l’expiration d’un compte (un jour ou jamais) ; rien n’est écrit."),

            new OperationDefinition("fiche.expirePassword.plan", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                return await PlanAsync(writers.Require<IPasswordExpireExecutor>().PlanAsync(dn, ct), ct).ConfigureAwait(false);
            }, "Plan de « Imposer un nouveau mot de passe » (pwdLastSet = 0) ; rien n’est écrit."),

            new OperationDefinition("fiche.options.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, OptionsArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var options = BoolMap(values, "options");
                return await PlanAsync(writers.Require<IAccountOptionsExecutor>().PlanAsync(dn, options, ct), ct).ConfigureAwait(false);
            }, "Plan des options de sécurité du compte (bits changés seulement) ; rien n’est écrit."),

            new OperationDefinition("fiche.rawAttribute.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, RawArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var attribute = Text(values, "attribute", 127);
                var value = BridgeArguments.GetOptionalString(values, "value");
                if (value is not null && value.Length > 4096)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("value") + " doit faire au plus 4 096 caractères.");
                }
                // SE-02, first check: before the plan (the executor applies it again before sending).
                var decision = FicheAttributeRules.RawWriteAllowed(attribute, policy);
                if (!decision.Allowed)
                {
                    throw FicheErrors.Error(FicheErrors.Refused, decision.Reason + " Aucune écriture préparée.");
                }
                return await PlanAsync(writers.Require<IRawAttributeExecutor>().PlanAsync(dn, attribute, value, ct), ct).ConfigureAwait(false);
            }, "Plan d’une écriture brute d’attribut (règle de sécurité appliquée deux fois) ; rien n’est écrit."),

            new OperationDefinition("fiche.move.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, MoveArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var target = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "target"), "target");
                return await PlanAsync(writers.Require<IObjectMoveExecutor>().PlanAsync(dn, target, ct), ct).ConfigureAwait(false);
            }, "Plan du déplacement d’un objet vers une OU du domaine ; rien n’est écrit."),

            new OperationDefinition("fiche.membership.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, MemberArguments);
                var group = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "group"), "group");
                var member = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "member"), "member");
                var add = BridgeArguments.GetBoolean(values, "add");
                return await PlanAsync(writers.Require<IGroupMemberExecutor>().PlanAsync(group, member, add, ct), ct).ConfigureAwait(false);
            }, "Plan de l’ajout ou du retrait d’un membre direct d’un groupe ; rien n’est écrit."),

            new OperationDefinition("fiche.delete.plan", readClass, async (args, _, ct) =>
            {
                var dn = Dn(args);
                return await PlanAsync(writers.Require<IObjectDeleteExecutor>().PlanAsync(dn, ct), ct).ConfigureAwait(false);
            }, "Plan de la suppression non récursive d’un objet ; rien n’est écrit."),

            new OperationDefinition("fiche.createOu.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CreateOuArguments);
                var parent = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "parent"), "parent");
                var name = Text(values, "name", 64);
                return await PlanAsync(writers.Require<IOuCreateExecutor>().PlanAsync(parent, name, ct), ct).ConfigureAwait(false);
            }, "Plan de la création d’une OU sous une OU ou un conteneur ; rien n’est écrit."),

            new OperationDefinition("fiche.resetPassword.plan", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ResetArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var mustChange = BridgeArguments.GetBoolean(values, "mustChange");
                var unlock = BridgeArguments.GetBoolean(values, "unlock");
                return await PlanAsync(writers.Require<IPasswordResetExecutor>().PlanAsync(dn, mustChange, unlock, ct), ct).ConfigureAwait(false);
            }, "Plan de la réinitialisation du mot de passe (généré par le moteur, jamais dans le plan) ; rien n’est écrit."),
        ];
    }

    /// <summary>One remembered fiche (preference « fiche.recent »).</summary>
    public sealed record FicheRecent(string Dn, string Name, FicheKind Kind, string? Detail, DateTimeOffset At, bool Exists);

    private static ImmutableArray<FicheRecent> ReadRecent(IPreferenceStore preferences)
    {
        if (!preferences.TryGet(RecentKey, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            return [];
        }
        var items = ImmutableArray.CreateBuilder<FicheRecent>();
        foreach (var item in value.EnumerateArray().Take(RecentLimit))
        {
            if (item.ValueKind != JsonValueKind.Object
                || !item.TryGetProperty("dn", out var dn) || dn.ValueKind != JsonValueKind.String
                || !item.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            var kind = item.TryGetProperty("kind", out var k) && k.ValueKind == JsonValueKind.String ? KindOf(k.GetString()) : null;
            var detail = item.TryGetProperty("detail", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() : null;
            var at = item.TryGetProperty("at", out var a) && a.ValueKind == JsonValueKind.String
                && DateTimeOffset.TryParse(a.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed) ? parsed : DateTimeOffset.MinValue;
            var dnText = dn.GetString()!;
            if (dnText.Length is 0 or > BridgeArguments.MaxDistinguishedNameLength)
            {
                continue;
            }
            items.Add(new FicheRecent(dnText, name.GetString()!, kind ?? FicheKind.Container, detail, at, true));
        }
        return items.ToImmutable();
    }

    private static FicheKind? KindOf(string? id) => id switch
    {
        "user" => FicheKind.User,
        "computer" => FicheKind.Computer,
        "group" => FicheKind.Group,
        "ou" => FicheKind.Ou,
        "contact" => FicheKind.Contact,
        "container" => FicheKind.Container,
        _ => null,
    };

    private static string Dn(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, DnArguments);
        return BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
    }

    private static string RootOf(string dn)
    {
        try
        {
            var parts = DistinguishedName.Parse(dn).Where(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).ToList();
            return DistinguishedName.Format(parts);
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    private static bool LooksLikeDn(string text)
    {
        if (!text.Contains('=', StringComparison.Ordinal) || text.Length > BridgeArguments.MaxDistinguishedNameLength)
        {
            return false;
        }
        try
        {
            return DistinguishedName.Parse(text).Length > 1;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Text(IReadOnlyDictionary<string, JsonElement> values, string name, int max)
    {
        var text = BridgeArguments.GetString(values, name);
        if (text.Length > max)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(max) + " caractères.");
        }
        return text;
    }

    private static int? OptionalInt(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number) || number < min || number > max)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
        }
        return number;
    }

    private static DateOnly? OptionalDate(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetOptionalString(values, name);
        if (text is null)
        {
            return null;
        }
        return DateOnly.TryParseExact(text, "yyyy'-'MM'-'dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day) && day.Year is >= 1990 and <= 2199
            ? day
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une date aaaa-mm-jj ou null.");
    }

    private static readonly FicheKind[] AllKinds = [FicheKind.User, FicheKind.Computer, FicheKind.Group, FicheKind.Ou, FicheKind.Contact, FicheKind.Container];

    private static ImmutableArray<FicheKind> Kinds(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("kinds", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return [.. AllKinds];
        }
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > 6)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("kinds") + " doit être un tableau de types d’objet.");
        }
        var kinds = new List<FicheKind>();
        foreach (var item in value.EnumerateArray())
        {
            var kind = item.ValueKind == JsonValueKind.String ? KindOf(item.GetString()) : null;
            if (kind is null)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("kinds") + " doit être un tableau de types d’objet.");
            }
            kinds.Add(kind.Value);
        }
        return [.. kinds.Distinct()];
    }

    private static ImmutableArray<string> DnList(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > 2000)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un tableau d’au plus 2 000 noms distinctifs.");
        }
        var list = ImmutableArray.CreateBuilder<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un tableau d’au plus 2 000 noms distinctifs.");
            }
            list.Add(BridgeArguments.RequireDistinguishedName(item.GetString()!, name));
        }
        return list.ToImmutable();
    }

    private static Dictionary<string, string?> FieldMap(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("fields", out var value) || value.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("fields") + " est obligatoire et doit être un objet.");
        }
        var fields = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in value.EnumerateObject())
        {
            if (!FicheAttributeRules.IsValidName(property.Name) || fields.Count >= WritePlans.MaxChanges)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("fields") + " contient un nom d’attribut non admis.");
            }
            string? text = property.Value.ValueKind switch
            {
                JsonValueKind.Null => null,
                JsonValueKind.String => property.Value.GetString(),
                _ => throw BridgeArguments.Invalid(FrenchText.Quote("fields") + " n’admet que des textes ou null."),
            };
            if (text is not null && text.Length > 4096)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("fields") + " contient une valeur trop longue.");
            }
            if (!fields.TryAdd(property.Name, text))
            {
                throw BridgeArguments.Invalid(BridgeArguments.PropertyNotAllowed);
            }
        }
        if (fields.Count == 0)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("fields") + " doit nommer au moins un champ.");
        }
        return fields;
    }

    private static Dictionary<string, bool> BoolMap(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être un objet.");
        }
        var map = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (property.Value.ValueKind is not (JsonValueKind.True or JsonValueKind.False) || map.Count >= 16 || !map.TryAdd(property.Name, property.Value.GetBoolean()))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote(name) + " n’admet que des valeurs true ou false.");
            }
        }
        return map;
    }
}
