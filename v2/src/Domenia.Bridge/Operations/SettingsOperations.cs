using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Operations of the Paramètres screen (docs/ops/parametres.md): connection preferences and working OU, collection and
/// network budgets, local base (state, measures, policy, previews and write plans), reset of the preferences, facts of the
/// simulation. The host adds what only it knows (about, configuration, journals, data policy, preferences document:
/// Domenia.App/Settings/SettingsHostOperations.cs). Handlers only validate the arguments and delegate. Every write of the
/// local base is a plan (a read) run by write.execute; the module itself only writes local preferences (LocalWrite).
/// </summary>
public sealed class SettingsOperations : IOperationModule
{
    /// <summary>Bounds of the engine used by the limits of the local base (Domenia 1 Async defaults).</summary>
    public const int DefaultMaxConcurrent = 6;
    public const int DefaultMaxQueued = 32;

    public const string SimulationCode = "settings.simulation";
    public const string SimulationMessage = "Simulation" + FrenchText.Nbsp + ": aucune saisie d’identifiants, rien n’est mémorisé ; ce réglage s’applique en mode annuaire.";
    public const string WindowInvalidCode = "settings.windowInvalid";

    private static readonly string[] NoArguments = [];
    private static readonly string[] RememberArguments = ["rememberLogin"];
    private static readonly string[] CollectionArguments = ["profile", "freshness", "window", "budgets"];
    private static readonly string[] WindowArguments = ["text", "grid"];
    private static readonly string[] RetentionArguments = ["presenceDays", "consoleDays", "inventoryDays", "probeDays", "detailDays", "linkHistoryDays"];
    private static readonly string[] ScheduleArguments = ["enabled", "hours", "keep"];
    private static readonly string[] PurgeArguments = ["categories", "historyDays"];
    private static readonly string[] PurgePlanArguments = ["categories", "historyDays", "fingerprint"];
    private static readonly string[] FingerprintArguments = ["fingerprint"];
    private static readonly string[] DestinationArguments = ["destination"];
    private static readonly string[] BackupArguments = ["backupId"];
    private static readonly string[] ResetArguments = ["group"];

    public string Screen => "settings";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var preferences = context.Preferences;
        var log = context.Log;
        var journal = context.Journal;
        var clock = context.Clock;
        var simulated = context.Mode == AppMode.Simulation;

        void Note(string text, Tone tone = Tone.Info) => journal.Add(new JournalEntry(clock.GetUtcNow(), text, tone));

        async Task Store(string key, JsonElement? value, string label, CancellationToken cancellationToken)
        {
            try
            {
                await preferences.SetAsync(key, value, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // The value holds for the session; the operator is told (PLATFORM.md § 5).
                log.Warning($"Préférence {key} non enregistrée ({ex.GetType().Name}) : elle vaut pour la session.");
                Note("Préférences non enregistrées" + FrenchText.Colon + label, Tone.Warn);
            }
        }

        JsonElement? Read(string key) => preferences.TryGet(key, out var value) ? value : null;

        StoragePolicy Policy(out bool unreadable) => StoragePolicyRules.Read(Read(StoragePolicyRules.PreferenceKey), out unreadable);

        // The handlers name their bridge context « _ »: inside them « out _ » would not be a discard.
        StoragePolicy CurrentPolicy() => Policy(out _);

        async Task<int> ApprovedKeysAsync(CancellationToken cancellationToken)
        {
            var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            var keys = new List<string> { DashboardService.DisabledWidgetsPreference, CollectionSettingsRules.PreferenceKey, StoragePolicyRules.PreferenceKey };
            if (session.Domain?.RootDn is string root)
            {
                try
                {
                    keys.Add(WorkingScope.PreferenceKey(root));
                }
                catch (FormatException)
                {
                    log.Warning("Racine du domaine illisible : clé de l’OU de travail ignorée.");
                }
            }
            return keys.Count(k => preferences.TryGet(k, out _));
        }

        async Task<object?> StorageViewAsync(LocalStoreSnapshot? snapshot, CancellationToken cancellationToken)
        {
            var policy = Policy(out var unreadable);
            var zone = clock.LocalTimeZone;
            var reader = context.Readers.Find<ISettingsReader>();
            if (reader is null)
            {
                return StorageViewBuilder.Unavailable(policy, unreadable, DefaultMaxConcurrent, DefaultMaxQueued, zone);
            }
            snapshot ??= await reader.LocalStoreAsync(cancellationToken).ConfigureAwait(false);
            return StorageViewBuilder.Build(snapshot, policy, unreadable, DefaultMaxConcurrent, DefaultMaxQueued, clock.GetUtcNow(), zone, snapshot.Available ? snapshot.PathLabel : null);
        }

        ISettingsReader Reader() => context.Readers.Find<ISettingsReader>()
            ?? throw new DomeniaOperationException(StorageWritePlans.StoreUnavailable, StorageViewBuilder.DirectoryModeReason);

        T Writer<T>() where T : class, IWriteExecutor => context.Writers.Find<T>()
            ?? throw new DomeniaOperationException(StorageWritePlans.StoreUnavailable, StorageViewBuilder.DirectoryModeReason);

        async Task<object?> ConnectionViewAsync(CancellationToken cancellationToken)
        {
            var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            var info = await DashboardService.From(context).GetSessionInfoAsync(cancellationToken).ConfigureAwait(false);
            var stored = SettingsViewRules.ReadConnection(Read(SettingsViewRules.ConnectionKey));
            var scope = info.Scope;
            var root = info.Domain?.RootDn;
            var whole = scope is not null && root is not null && DistinguishedName.AreEqual(scope.Dn, root);
            var defaultScope = session.Scope;
            var scopeView = new SettingsScopeView(scope?.Dn, scope?.Label, scope?.Subtree ?? false, scope is null ? null : ReadablePath(scope.Dn, info.Domain?.DnsName),
                whole, defaultScope?.Dn, defaultScope?.Label, scope is not null && defaultScope is not null && DistinguishedName.AreEqual(scope.Dn, defaultScope.Dn) && scope.Subtree == defaultScope.Subtree);
            return new ConnectionView(
                info.Connection,
                simulated ? AppInfoBuilder.SimulationModeText : AppInfoBuilder.DirectoryModeText,
                simulated,
                info.Domain,
                info.Controller,
                info.Account,
                info.Authentication,
                info.Rights,
                info.ReadOnly,
                SettingsViewRules.ConnectionView(stored, simulated),
                scopeView,
                SettingsViewRules.Sections(scope),
                [
                    "L’OU de travail est mémorisée par domaine ; seule une OU du domaine courant est admise, vérifiée dans l’index local, jamais par le réseau.",
                    "Avec tout le domaine comme OU de travail, les mesures de postes restent refusées : jamais tout le domaine.",
                    "Les sections suivent l’OU de travail ; une OU propre à une section viendra la remplacer, après confirmation dans la page.",
                ]);
        }

        CollectionSettingsView CollectionView()
        {
            var warnings = new List<string>();
            var settings = CollectionSettingsRules.Read(Read(CollectionSettingsRules.PreferenceKey), warnings);
            return CollectionSettingsRules.View(settings, warnings, clock.GetUtcNow(), clock.LocalTimeZone);
        }

        return
        [
            // ----- Connection and working OU -----
            new OperationDefinition("settings.connection", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await ConnectionViewAsync(cancellationToken).ConfigureAwait(false);
            }, "Session, compte, préférences de connexion et OU de travail ; aucune lecture réseau."),

            new OperationDefinition("settings.connection.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, RememberArguments);
                var remember = BridgeArguments.GetBoolean(values, "rememberLogin");
                if (simulated)
                {
                    throw new DomeniaOperationException(SimulationCode, SimulationMessage);
                }
                var stored = SettingsViewRules.ReadConnection(Read(SettingsViewRules.ConnectionKey));
                if (stored.RememberLogin != remember)
                {
                    var next = remember ? stored with { RememberLogin = true } : stored with { RememberLogin = false, LastLogin = "" };
                    await Store(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(next), "préférences de connexion", cancellationToken).ConfigureAwait(false);
                    Note("Connexion" + FrenchText.Colon + "« se souvenir de mon identifiant » " + (remember ? "activé" : "désactivé, dernier identifiant oublié"));
                }
                return await ConnectionViewAsync(cancellationToken).ConfigureAwait(false);
            }, "« Se souvenir de mon identifiant » (jamais de mot de passe) ; refusé en simulation."),

            new OperationDefinition("settings.connection.forget", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                if (simulated)
                {
                    throw new DomeniaOperationException(SimulationCode, SimulationMessage);
                }
                var stored = SettingsViewRules.ReadConnection(Read(SettingsViewRules.ConnectionKey));
                if (stored.LastLogin.Length > 0 || stored.VaultUser.Length > 0 || stored.VaultDomain.Length > 0)
                {
                    await Store(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(stored with { LastLogin = "", VaultDomain = "", VaultUser = "" }), "préférences de connexion", cancellationToken).ConfigureAwait(false);
                    Note("Connexion" + FrenchText.Colon + "dernier identifiant et compte du coffre oubliés (le coffre Windows n’est pas modifié)");
                }
                return await ConnectionViewAsync(cancellationToken).ConfigureAwait(false);
            }, "Oublie le dernier identifiant et le nom du compte du coffre ; refusé en simulation."),

            // ----- Collection and network budgets -----
            new OperationDefinition("settings.collection", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult<object?>(CollectionView());
            }, "Profil de collecte, durées de fraîcheur, fenêtre et budgets des relevés."),

            new OperationDefinition("settings.collection.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, CollectionArguments);
                if (values.Count == 0)
                {
                    throw BridgeArguments.Invalid("au moins un réglage est attendu.");
                }
                var warnings = new List<string>();
                var settings = CollectionSettingsRules.Read(Read(CollectionSettingsRules.PreferenceKey), warnings);
                var changed = new List<string>();
                if (values.TryGetValue("profile", out var profileValue))
                {
                    var profile = profileValue.ValueKind == JsonValueKind.String ? profileValue.GetString() : null;
                    if (!CollectionSettingsRules.IsProfile(profile))
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("profile") + " doit être standard, slowNetwork ou troubleshooting.");
                    }
                    if (profile != settings.Profile)
                    {
                        settings = settings with { Profile = profile! };
                        changed.Add("profil " + FrenchText.Quote(CollectionSettingsRules.Profile(profile).Label));
                    }
                }
                if (values.TryGetValue("freshness", out var freshness))
                {
                    var current = settings.Freshness.GetValueOrDefault(settings.Profile) ?? ImmutableDictionary<string, int>.Empty;
                    if (freshness.ValueKind == JsonValueKind.Null)
                    {
                        current = ImmutableDictionary<string, int>.Empty;
                        changed.Add("durées du profil rétablies");
                    }
                    else if (freshness.ValueKind == JsonValueKind.Object)
                    {
                        foreach (var entry in freshness.EnumerateObject())
                        {
                            var family = CollectionSettingsRules.Family(entry.Name)
                                ?? throw BridgeArguments.Invalid("famille de fraîcheur inconnue.");
                            if (entry.Value.ValueKind == JsonValueKind.Null)
                            {
                                current = current.Remove(family.Id);
                            }
                            else if (entry.Value.ValueKind == JsonValueKind.Number && entry.Value.TryGetInt32(out var seconds) && seconds >= family.Minimum && seconds <= family.Maximum)
                            {
                                current = current.SetItem(family.Id, seconds);
                            }
                            else
                            {
                                throw BridgeArguments.Invalid("une durée est un nombre entier de secondes, de 0 à 7 jours, ou null.");
                            }
                            changed.Add(family.Label.ToLowerInvariant());
                        }
                    }
                    else
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("freshness") + " doit être un objet ou null.");
                    }
                    settings = settings with
                    {
                        Freshness = current.Count == 0 ? settings.Freshness.Remove(settings.Profile) : settings.Freshness.SetItem(settings.Profile, current),
                    };
                }
                if (values.TryGetValue("window", out var windowValue))
                {
                    if (windowValue.ValueKind == JsonValueKind.Null)
                    {
                        settings = settings with { Windows = settings.Windows.Remove(settings.Profile) };
                        changed.Add("fenêtre du profil rétablie");
                    }
                    else if (windowValue.ValueKind == JsonValueKind.String)
                    {
                        var text = windowValue.GetString()!;
                        if (text.Length > CollectionWindowRules.MaxLength)
                        {
                            throw BridgeArguments.Invalid(FrenchText.Quote("window") + " doit faire au plus " + FrenchText.Integer(CollectionWindowRules.MaxLength) + " caractères.");
                        }
                        var window = CollectionWindowRules.Parse(text);
                        if (!window.Valid)
                        {
                            throw new DomeniaOperationException(WindowInvalidCode, "Fenêtre de collecte non enregistrée" + FrenchText.Colon + string.Join(" ", window.Errors));
                        }
                        settings = settings with { Windows = settings.Windows.SetItem(settings.Profile, window.Text) };
                        changed.Add("fenêtre de collecte");
                    }
                    else
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("window") + " doit être un texte ou null.");
                    }
                }
                if (values.TryGetValue("budgets", out var budgets))
                {
                    if (budgets.ValueKind != JsonValueKind.Object)
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("budgets") + " doit être un objet.");
                    }
                    var next = settings.Budgets;
                    foreach (var entry in budgets.EnumerateObject())
                    {
                        var definition = CollectionSettingsRules.Budget(entry.Name) ?? throw BridgeArguments.Invalid("budget inconnu.");
                        if (entry.Value.ValueKind != JsonValueKind.Number || !entry.Value.TryGetInt32(out var number) || number < definition.Minimum || number > definition.Maximum)
                        {
                            throw BridgeArguments.Invalid(FrenchText.Quote(definition.Id) + " doit être compris entre " + FrenchText.Integer(definition.Minimum) + " et " + FrenchText.Integer(definition.Maximum) + ".");
                        }
                        next = next.SetItem(definition.Id, number);
                        changed.Add(definition.Label.ToLowerInvariant() + " " + CollectionSettingsRules.BudgetLabel(definition, number));
                    }
                    settings = settings with { Budgets = next };
                }
                await Store(CollectionSettingsRules.PreferenceKey, CollectionSettingsRules.ToJson(settings), "réglages de collecte", cancellationToken).ConfigureAwait(false);
                if (changed.Count > 0)
                {
                    Note("Collecte" + FrenchText.Colon + string.Join(", ", changed.Distinct(StringComparer.Ordinal)));
                }
                return CollectionView();
            }, "Enregistre le profil, les durées, la fenêtre ou les budgets ; une fenêtre invalide n’est jamais enregistrée."),

            new OperationDefinition("settings.collection.window.check", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, WindowArguments);
                string text;
                if (values.TryGetValue("grid", out var grid))
                {
                    if (values.ContainsKey("text"))
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("text") + " ou " + FrenchText.Quote("grid") + ", pas les deux.");
                    }
                    text = CollectionWindowRules.FromWeekGrid(ReadGrid(grid));
                }
                else
                {
                    text = BridgeArguments.GetString(values, "text");
                    if (text.Length > CollectionWindowRules.MaxLength)
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(CollectionWindowRules.MaxLength) + " caractères.");
                    }
                }
                return Task.FromResult<object?>(CollectionSettingsRules.CheckWindow(text, clock.GetUtcNow(), clock.LocalTimeZone));
            }, "Analyse une fenêtre de collecte (texte ou grille de la semaine) sans l’enregistrer."),

            // ----- Local base -----
            new OperationDefinition("settings.storage", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await StorageViewAsync(null, cancellationToken).ConfigureAwait(false);
            }, "État de la base locale : emplacement, espace, sauvegardes, conservation, limites, purge, cache, reprise."),

            new OperationDefinition("settings.storage.measure", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var snapshot = await Reader().MeasureAsync(cancellationToken).ConfigureAwait(false);
                Note("Base locale mesurée" + FrenchText.Colon + SettingsFormat.Size(snapshot.DatabaseBytes + snapshot.WalBytes)
                    + (snapshot.Space.FreeBytes is long free ? ", " + SettingsFormat.Size(free) + " libres sur le volume" : ""));
                return await StorageViewAsync(snapshot, cancellationToken).ConfigureAwait(false);
            }, "Mesure en lecture seule de la base et de l’espace libre de son volume."),

            new OperationDefinition("settings.storage.integrity", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var snapshot = await Reader().CheckIntegrityAsync(cancellationToken).ConfigureAwait(false);
                if (snapshot.Integrity is not null)
                {
                    var verdict = LocalStoreRules.Integrity(snapshot.Integrity, clock.LocalTimeZone);
                    Note("Intégrité de la base locale" + FrenchText.Colon + verdict.Verdict, verdict.Tone == Tone.Alert ? Tone.Alert : verdict.Tone == Tone.Warn ? Tone.Warn : Tone.Info);
                }
                return await StorageViewAsync(snapshot, cancellationToken).ConfigureAwait(false);
            }, "Neuf contrôles d’intégrité en lecture seule ; aucune réparation."),

            new OperationDefinition("settings.storage.retention.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, RetentionArguments);
                var current = CurrentPolicy();
                var policy = current with
                {
                    PresenceDays = RequiredInteger(values, "presenceDays", 0, StoragePolicyRules.MaxRetentionDays),
                    ConsoleDays = RequiredInteger(values, "consoleDays", 0, StoragePolicyRules.MaxRetentionDays),
                    InventoryDays = RequiredInteger(values, "inventoryDays", 0, StoragePolicyRules.MaxRetentionDays),
                    ProbeDays = RequiredInteger(values, "probeDays", 0, StoragePolicyRules.MaxRetentionDays),
                    DetailDays = RequiredInteger(values, "detailDays", 0, StoragePolicyRules.MaxRetentionDays),
                    LinkHistoryDays = RequiredInteger(values, "linkHistoryDays", 0, StoragePolicyRules.MaxRetentionDays),
                };
                if (policy != current)
                {
                    await Store(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(policy), "conservation des mesures", cancellationToken).ConfigureAwait(false);
                    Note("Conservation enregistrée (rien n’est supprimé)" + FrenchText.Colon + string.Join(", ", StoragePolicyRules.Families.Select(f => f.Label.ToLowerInvariant() + " " + SettingsFormat.Days(StoragePolicyRules.DaysOf(policy, f.Family)))));
                }
                return await StorageViewAsync(null, cancellationToken).ConfigureAwait(false);
            }, "Enregistre la conservation par famille ; ne supprime rien (prévisualisation et confirmation d’abord)."),

            new OperationDefinition("settings.storage.backup.schedule.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ScheduleArguments);
                var current = CurrentPolicy();
                var policy = current with
                {
                    AutomaticBackup = BridgeArguments.GetBoolean(values, "enabled"),
                    BackupHours = RequiredInteger(values, "hours", 1, 720),
                    BackupKeep = RequiredInteger(values, "keep", 2, 30),
                };
                if (policy != current)
                {
                    await Store(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(policy), "sauvegarde automatique", cancellationToken).ConfigureAwait(false);
                    Note("Sauvegarde automatique" + FrenchText.Colon + (policy.AutomaticBackup ? "toutes les " + FrenchText.Integer(policy.BackupHours) + FrenchText.Nbsp + "h, " + FrenchText.Count(policy.BackupKeep, "copie conservée", "copies conservées") : "désactivée"));
                }
                return await StorageViewAsync(null, cancellationToken).ConfigureAwait(false);
            }, "Sauvegarde automatique pendant que Domenia est ouvert : 1 à 720 h, 2 à 30 copies."),

            new OperationDefinition("settings.storage.retention.preview", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var snapshot = await Reader().LocalStoreAsync(cancellationToken).ConfigureAwait(false);
                EnsureStore(snapshot);
                return StoragePolicyRules.Preview(CurrentPolicy(), snapshot, clock.GetUtcNow(), clock.LocalTimeZone);
            }, "Compte ce que la conservation retirerait, sans rien supprimer, avec l’empreinte exigée par le plan."),

            new OperationDefinition("settings.storage.purge.preview", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, PurgeArguments);
                var categories = Categories(values);
                var days = OptionalInteger(values, "historyDays", 1, StoragePolicyRules.MaxRetentionDays) ?? LocalStoreRules.DefaultHistoryDays;
                var snapshot = await Reader().LocalStoreAsync(cancellationToken).ConfigureAwait(false);
                EnsureStore(snapshot);
                return LocalStoreRules.PurgePlan(snapshot, categories, days, clock.GetUtcNow(), clock.LocalTimeZone);
            }, "Simule une purge par catégories fermées : lignes comptées, refus nommés, empreinte exigée par le plan."),

            new OperationDefinition("settings.storage.legacy.preview", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var snapshot = await Reader().LocalStoreAsync(cancellationToken).ConfigureAwait(false);
                return StorageViewBuilder.LegacySimulation(snapshot, clock.LocalTimeZone);
            }, "Simule la reprise des données de Domenia 1, sans rien écrire."),

            // ----- Write plans of the local base (reads; executed by write.execute only) -----
            Plan(context, "settings.storage.backup.plan", NoArguments, async (_, cancellationToken) =>
                await Writer<IStorageBackupExecutor>().PlanBackupAsync(CurrentPolicy(), await ApprovedKeysAsync(cancellationToken).ConfigureAwait(false), cancellationToken).ConfigureAwait(false),
                "Plan d’une sauvegarde vérifiée de la base locale."),

            Plan(context, "settings.storage.backupCopy.plan", DestinationArguments, async (values, cancellationToken) =>
                await Writer<IStorageBackupCopyExecutor>().PlanBackupCopyAsync(Destination(values), CurrentPolicy(), await ApprovedKeysAsync(cancellationToken).ConfigureAwait(false), cancellationToken).ConfigureAwait(false),
                "Plan d’une sauvegarde vérifiée publiée vers un fichier choisi."),

            Plan(context, "settings.storage.retention.plan", FingerprintArguments, async (values, cancellationToken) =>
                await Writer<IStorageRetentionExecutor>().PlanRetentionAsync(CurrentPolicy(), Fingerprint(values), cancellationToken).ConfigureAwait(false),
                "Plan de la conservation, lié à l’empreinte de sa prévisualisation."),

            Plan(context, "settings.storage.purge.plan", PurgePlanArguments, async (values, cancellationToken) =>
                await Writer<IStoragePurgeExecutor>().PlanPurgeAsync(Categories(values), OptionalInteger(values, "historyDays", 1, StoragePolicyRules.MaxRetentionDays) ?? LocalStoreRules.DefaultHistoryDays,
                    Fingerprint(values), cancellationToken).ConfigureAwait(false),
                "Plan d’une purge, lié à l’empreinte de sa simulation."),

            Plan(context, "settings.storage.move.plan", DestinationArguments, async (values, cancellationToken) =>
                await Writer<IStorageMoveExecutor>().PlanMoveAsync(Destination(values), cancellationToken).ConfigureAwait(false),
                "Plan du déplacement de la base locale vers un fichier local."),

            Plan(context, "settings.storage.restore.plan", BackupArguments, async (values, cancellationToken) =>
            {
                var id = BridgeArguments.GetString(values, "backupId");
                if (!WritePlans.IsPlanId(id))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("backupId") + " doit être un identifiant de sauvegarde (32 caractères hexadécimaux).");
                }
                return await Writer<IStorageRestoreExecutor>().PlanRestoreAsync(id, cancellationToken).ConfigureAwait(false);
            }, "Plan de la restauration d’une sauvegarde vérifiée dans un nouveau fichier."),

            Plan(context, "settings.storage.resume.plan", NoArguments, async (_, cancellationToken) =>
                await Writer<IStorageResumeExecutor>().PlanResumeAsync(cancellationToken).ConfigureAwait(false),
                "Plan de la reprise d’une bascule interrompue."),

            Plan(context, "settings.storage.rollback.plan", NoArguments, async (_, cancellationToken) =>
                await Writer<IStorageRollbackExecutor>().PlanRollbackAsync(cancellationToken).ConfigureAwait(false),
                "Plan du retour à la base précédente."),

            Plan(context, "settings.storage.writerResume.plan", NoArguments, async (_, cancellationToken) =>
                await Writer<IStorageWriterResumeExecutor>().PlanWriterResumeAsync(cancellationToken).ConfigureAwait(false),
                "Plan de la reprise des enregistrements locaux suspendus."),

            Plan(context, "settings.storage.legacy.plan", FingerprintArguments, async (values, cancellationToken) =>
                await Writer<IStorageLegacyImportExecutor>().PlanLegacyImportAsync(Fingerprint(values), cancellationToken).ConfigureAwait(false),
                "Plan de la reprise des données de Domenia 1, lié à l’empreinte de sa simulation."),

            // ----- Preferences -----
            new OperationDefinition("settings.preferences.reset", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ResetArguments);
                var group = BridgeArguments.GetString(values, "group");
                string[] groups = group switch
                {
                    "all" => ["widgets", "workingScope", "collection", "storage", "connection"],
                    "widgets" or "workingScope" or "collection" or "storage" or "connection" => [group],
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("group") + " doit être widgets, workingScope, collection, storage, connection ou all."),
                };
                var keys = new List<string>();
                var failed = new List<string>();
                foreach (var name in groups)
                {
                    try
                    {
                        switch (name)
                        {
                            case "widgets":
                                var dashboard = DashboardService.From(context);
                                foreach (var widget in WidgetCatalog.All)
                                {
                                    await dashboard.SetEnabledAsync(widget.Id, true, cancellationToken).ConfigureAwait(false);
                                }
                                keys.Add(DashboardService.DisabledWidgetsPreference);
                                break;
                            case "workingScope":
                                var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                                if (session.Scope is ScopeSelection defaultScope && session.Domain?.RootDn is string root)
                                {
                                    await WorkingScope.From(context).SetAsync(session, defaultScope.Dn, defaultScope.Subtree, cancellationToken).ConfigureAwait(false);
                                    var key = WorkingScope.PreferenceKey(root);
                                    await Store(key, null, "OU de travail", cancellationToken).ConfigureAwait(false);
                                    keys.Add(key);
                                }
                                break;
                            case "collection":
                                await Store(CollectionSettingsRules.PreferenceKey, null, "réglages de collecte", cancellationToken).ConfigureAwait(false);
                                keys.Add(CollectionSettingsRules.PreferenceKey);
                                break;
                            case "storage":
                                await Store(StoragePolicyRules.PreferenceKey, null, "conservation et sauvegardes", cancellationToken).ConfigureAwait(false);
                                keys.Add(StoragePolicyRules.PreferenceKey);
                                break;
                            case "connection":
                                await Store(SettingsViewRules.ConnectionKey, null, "préférences de connexion", cancellationToken).ConfigureAwait(false);
                                keys.Add(SettingsViewRules.ConnectionKey);
                                break;
                        }
                    }
                    catch (DomeniaOperationException ex)
                    {
                        log.Warning($"Réinitialisation du groupe {name} refusée : {ex.Code}.");
                        failed.Add(PreferenceTransfer.ResetGroups.First(g => g.Id == name).Label + FrenchText.Colon + ex.Message);
                    }
                }
                var labels = groups.Select(g => PreferenceTransfer.ResetGroups.First(r => r.Id == g).Label.ToLowerInvariant());
                var summary = "Préférences réinitialisées" + FrenchText.Colon + string.Join(", ", labels) + "." + (failed.Count > 0 ? " Non réinitialisé" + FrenchText.Colon + string.Join(" ", failed) : "");
                Note(summary, failed.Count > 0 ? Tone.Warn : Tone.Info);
                return new PreferenceApplyResult(keys.Count, [.. keys], [.. failed], summary);
            }, "Réinitialise un groupe de préférences du moteur (widgets, OU de travail, collecte, conservation, connexion, tout)."),

            // ----- Simulation -----
            new OperationDefinition("settings.demo", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var reader = context.Readers.Find<ISettingsReader>();
                var facts = reader is null ? null : await reader.SimulationAsync(cancellationToken).ConfigureAwait(false);
                return SettingsViewRules.Simulation(context.Decision, simulated ? facts : null);
            }, "Mode de démarrage et faits de la simulation (graine, annuaire fictif, surcouche)."),
        ];
    }

    /// <summary>A plan operation: LocalRead (it reads the local base), sealed by the write circuit, executed by write.execute only.</summary>
    private static OperationDefinition Plan(EngineContext context, string name, string[] arguments, Func<IReadOnlyDictionary<string, JsonElement>, CancellationToken, Task<WritePlanDraft>> draft, string description) =>
        new(name, OperationClass.LocalRead, async (args, _, cancellationToken) =>
        {
            var values = arguments.Length == 0 ? ReadNone(args) : BridgeArguments.ReadObject(args, arguments);
            var plan = await draft(values, cancellationToken).ConfigureAwait(false);
            return await WriteCircuit.From(context).PlanAsync(plan, cancellationToken).ConfigureAwait(false);
        }, description);

    private static IReadOnlyDictionary<string, JsonElement> ReadNone(JsonElement args)
    {
        BridgeArguments.RequireNone(args);
        return new Dictionary<string, JsonElement>(StringComparer.Ordinal);
    }

    /// <summary>The base must exist to be previewed (directory mode of this version: no base).</summary>
    private static void EnsureStore(LocalStoreSnapshot snapshot)
    {
        if (!snapshot.Available)
        {
            throw new DomeniaOperationException(StorageWritePlans.StoreUnavailable, StorageViewBuilder.DirectoryModeReason);
        }
    }

    private static int RequiredInteger(IReadOnlyDictionary<string, JsonElement> values, string name, int minimum, int maximum) =>
        OptionalInteger(values, name, minimum, maximum) ?? throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être un nombre entier.");

    private static int? OptionalInteger(IReadOnlyDictionary<string, JsonElement> values, string name, int minimum, int maximum)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un nombre entier.");
        }
        if (number < minimum || number > maximum)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être compris entre " + FrenchText.Integer(minimum) + " et " + FrenchText.Integer(maximum) + ".");
        }
        return number;
    }

    private static string[] Categories(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("categories", out var value) || value.ValueKind != JsonValueKind.Array)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("categories") + " est obligatoire et doit être un tableau de textes.");
        }
        var list = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || item.GetString()!.Length is 0 or > 32)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("categories") + " ne contient que des noms de catégories.");
            }
            list.Add(item.GetString()!);
        }
        if (list.Count is 0 or > 8)
        {
            throw BridgeArguments.Invalid("choisissez de 1 à 8 catégories.");
        }
        return [.. list];
    }

    private static string Fingerprint(IReadOnlyDictionary<string, JsonElement> values)
    {
        var text = BridgeArguments.GetString(values, "fingerprint");
        return SettingsFormat.Sha256Text(text) is string sha && sha == text
            ? text
            : throw BridgeArguments.Invalid(FrenchText.Quote("fingerprint") + " doit être une empreinte SHA-256 (64 caractères hexadécimaux minuscules).");
    }

    private static string Destination(IReadOnlyDictionary<string, JsonElement> values)
    {
        var text = BridgeArguments.GetString(values, "destination");
        return text.Length is 0 or > 260
            ? throw BridgeArguments.Invalid(FrenchText.Quote("destination") + " doit être un chemin de 1 à 260 caractères.")
            : text;
    }

    private static bool[][] ReadGrid(JsonElement grid)
    {
        const string Message = "« grid » doit être un tableau de 7 jours de 48 demi-heures (booléens).";
        if (grid.ValueKind != JsonValueKind.Array || grid.GetArrayLength() != 7)
        {
            throw BridgeArguments.Invalid(Message);
        }
        var rows = new bool[7][];
        var n = 0;
        foreach (var day in grid.EnumerateArray())
        {
            if (day.ValueKind != JsonValueKind.Array || day.GetArrayLength() != 48)
            {
                throw BridgeArguments.Invalid(Message);
            }
            rows[n] = [.. day.EnumerateArray().Select(c => c.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw BridgeArguments.Invalid(Message) })];
            n++;
        }
        return rows;
    }

    /// <summary>« example.local › Postes › Paris » from a DN (the domain, then each OU from the top).</summary>
    private static string ReadablePath(string dn, string? dnsName)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            var domain = dnsName ?? string.Join('.', names.Where(n => string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value));
            var ous = names.Where(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Reverse().Select(n => n.Value);
            return string.Join(FrenchText.PathSeparator, new[] { domain }.Concat(ous));
        }
        catch (FormatException)
        {
            return dn;
        }
    }
}
