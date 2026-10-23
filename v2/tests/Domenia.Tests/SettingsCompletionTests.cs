using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Paramètres, second round (docs/ops/parametres.md): journal of the session, approved preferences and the annex of the
/// backups, takeover of the Domenia 1 data with its guards, destinations, purge per table, zoom and window, writer and
/// demonstration scenarios, restores from a published copy with the annex re-applied, automatic backup, directory mode.
/// Written with the code, run at the end (decision of David, 21/10).
/// </summary>
internal static class SettingsCompletionTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }

    private static string Execute(JsonElement planned, string? typedName = null) => Args(new
    {
        planId = planned.GetProperty("plan").GetProperty("id").GetString(),
        token = planned.GetProperty("token").GetString(),
        typedName,
    });

    private static string Domain(SimulatedBridge bridge) => bridge.Source.World.Directory.Domain.DnsName;

    private static LocalStoreSnapshot Store(SimulatedBridge bridge) => SimulatedLocalStore.For(bridge.Source).Snapshot();

    private static LocalStoreSnapshot SimulatedStore() =>
        SimulatedLocalStore.For(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed())).Snapshot();

    private static async Task<JsonElement> ResultAsync(SimulatedBridge bridge, string operation, string arguments = "{}") =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, arguments));

    private static async Task<string?> ErrorAsync(SimulatedBridge bridge, string operation, string arguments = "{}")
    {
        var response = await bridge.CallAsync(operation, arguments);
        Check.Equal("error", response.Kind, operation + " devait être refusée");
        return response.Error?.Code;
    }

    private static async Task<JsonElement> PlayAsync(SimulatedBridge bridge, string scenario)
    {
        var planned = await ResultAsync(bridge, "settings.demo.scenario.plan", Args(new { scenario }));
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "scénario « " + scenario + " » relu");
        return receipt;
    }

    // ---------- Technical journal ----------

    [Test]
    public static void Journal_keeps_continuations_bounds_its_tail_and_counts_the_session_apart()
    {
        const string Text = "2026-10-22T08:00:00Z [INFO] début\n2026-10-22T08:00:01Z [ERREUR] échec\n   à Domenia.X()\n   à Domenia.Y()\nligne sans date\n2026-10-22T08:00:02Z [ATTENTION] lent\n";
        var lines = TechnicalLogTail.Parse(Text, startsMidway: false, out var cut);
        Check.False(cut, "rien de coupé");
        Check.Equal(3, lines.Length, "trois enregistrements");
        Check.Equal(3, lines[1].More.Length, "pile et ligne sans date rattachées à l’erreur");
        Check.Equal("ERREUR", lines[1].Level, "niveau lu");

        var midway = TechnicalLogTail.Parse("tielle\n2026-10-22T08:00:00Z [INFO] entier\n", startsMidway: true, out _);
        Check.Equal(1, midway.Length, "première ligne partielle écartée");
        Check.Equal("entier", midway[0].Text, "enregistrement entier gardé");

        var many = new StringBuilder();
        for (var n = 0; n < TechnicalLogTail.MaxRecords + 50; n++)
        {
            many.Append("2026-10-22T08:00:00Z [INFO] ligne ").Append(n.ToString(System.Globalization.CultureInfo.InvariantCulture)).Append('\n');
        }
        var tail = TechnicalLogTail.Parse(many.ToString(), startsMidway: false, out var cutMany);
        Check.True(cutMany, "plus de 5 000 : coupé");
        Check.Equal(TechnicalLogTail.MaxRecords, tail.Length, "5 000 enregistrements au plus");
        Check.Equal("ligne 50", tail[0].Text, "les plus récents gardés");

        var since = TechnicalLogTail.Since(lines, new DateTimeOffset(2026, 10, 22, 8, 0, 1, 400, TimeSpan.Zero));
        Check.Equal((1, 1), since, "erreur de la seconde du démarrage comptée");
        Check.Equal((0, 1), TechnicalLogTail.Since(lines, new DateTimeOffset(2026, 10, 22, 8, 0, 2, TimeSpan.Zero)), "seulement ce qui suit le démarrage");
    }

    [Test]
    public static void Open_folder_is_a_closed_set_never_during_a_capture()
    {
        Check.Equal("settings.folderUnavailable", SettingsFolders.Refusal("logs", unattended: true, simulation: true)?.Code, "jamais en capture ni en E2E");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, SettingsFolders.Refusal("..\\Windows", unattended: false, simulation: false)?.Code, "ensemble fermé");
        Check.Contains("Base de démonstration", SettingsFolders.Refusal("base", unattended: false, simulation: true)?.Message, "base fictive : aucun fichier");
        Check.Contains("Aucune base locale", SettingsFolders.Refusal("base", unattended: false, simulation: false)?.Message, "mode annuaire : pas encore de base");
        Check.Null(SettingsFolders.Refusal("logs", unattended: false, simulation: false), "dossier des journaux admis");
        Check.True(SettingsFolders.IsFile("preferences") && !SettingsFolders.IsFile("data"), "fichier sélectionné ou dossier ouvert");
        var tooLarge = ConfigurationRules.Read(new byte[LegacyConfiguration.MaxBytes + 1], "Domenia.config.json");
        Check.Equal("invalid", tooLarge.FileState, "configuration trop volumineuse : défauts");
        Check.True(tooLarge.Sections.SelectMany(s => s.Entries).All(e => e.Source == "default"), "aucune valeur d’un fichier refusé");
    }

    // ---------- Approved preferences and annex ----------

    [Test]
    public static void Approved_preferences_are_a_closed_list_with_a_validator_each()
    {
        Check.Null(PreferenceApproval.Problem(PreferenceApproval.ZoomKey, Json("120")), "zoom admis");
        Check.Contains("80 à 150", PreferenceApproval.Problem(PreferenceApproval.ZoomKey, Json("70")), "zoom hors bornes");
        Check.Contains("fenêtre de ce poste", PreferenceApproval.Problem(PreferenceApproval.WindowKey, Json("{}")), "fenêtre jamais importée");
        Check.Contains("identité de connexion", PreferenceApproval.Problem(SettingsViewRules.ConnectionKey, Json("{}")), "connexion jamais importée");
        Check.Contains("clé inconnue", PreferenceApproval.Problem("accounts.secret", Json("1")), "clé inconnue refusée");
        Check.Null(PreferenceApproval.Problem(DashboardService.DisabledWidgetsPreference, Json("""["lockedAccounts"]""")), "widgets connus");
        Check.Contains("widget inconnu", PreferenceApproval.Problem(DashboardService.DisabledWidgetsPreference, Json("""["inventé"]""")), "widget inconnu");
        var scope = WorkingScope.PreferenceKey("DC=example,DC=local");
        Check.True(PreferenceApproval.IsApproved(scope), "OU de travail d’un domaine admise");
        Check.Null(PreferenceApproval.Problem(scope, Json("""{"dn":"OU=Postes,DC=example,DC=local","subtree":true}""")), "OU lisible");
        Check.Contains("illisible", PreferenceApproval.Problem(scope, Json("""{"dn":"pas un DN"}""")), "OU illisible");
        Check.False(PreferenceApproval.IsApproved("session.workingScope.abc"), "empreinte de domaine exigée");

        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            [DashboardService.DisabledWidgetsPreference] = Json("[]"),
            [SettingsViewRules.ConnectionKey] = Json("""{"rememberLogin":true,"lastLogin":"jdupont"}"""),
            [PreferenceApproval.WindowKey] = Json("""{"x":1,"y":2,"width":1400,"height":900}"""),
            [PreferenceApproval.ZoomKey] = Json("110"),
            ["accounts.x"] = Json("1"),
        };
        Check.True(PreferenceApproval.Filter(values).Select(v => v.Key).SequenceEqual([DashboardService.DisabledWidgetsPreference, PreferenceApproval.ZoomKey]), "seules les clés approuvées et valides");
        var export = PreferenceTransfer.Export(values, "simulation", TestClock.Reference);
        Check.Equal(2, export.Keys, "export des clés approuvées");
        Check.False(export.Text.Contains("jdupont", StringComparison.Ordinal), "aucun identifiant exporté");
        Check.Equal(3, export.Excluded.Length, "connexion, fenêtre et clé inconnue exclues");
    }

    [Test]
    public static void Annex_of_a_backup_is_bound_to_its_copy_and_never_carries_this_workstation()
    {
        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            [StoragePolicyRules.PreferenceKey] = StoragePolicyRules.ToJson(StoragePolicyRules.Default),
            [SettingsViewRules.ConnectionKey] = Json("""{"rememberLogin":true,"lastLogin":"jdupont"}"""),
            [PreferenceApproval.WindowKey] = Json("""{"x":1,"y":2,"width":1400,"height":900}"""),
            [PreferenceApproval.ZoomKey] = Json("120"),
        };
        var snapshot = BackupPreferencesRules.Snapshot(values);
        Check.Contains(PreferenceApproval.ZoomKey, snapshot, "zoom joint");
        Check.False(snapshot.Contains("jdupont", StringComparison.Ordinal) || snapshot.Contains(PreferenceApproval.WindowKey, StringComparison.Ordinal), "ni identité ni fenêtre");
        Check.Equal(2, BackupPreferencesRules.Count(snapshot), "deux clés approuvées");

        var sha = new string('c', 64);
        var annex = BackupPreferencesRules.Bind(snapshot, sha, TestClock.Reference);
        Check.Equal(BackupPreferencesRules.Format, annex.Format, "format Domenia.BackupPreferences.1");
        var backup = new LocalStoreBackup(new string('a', 32), "Domenia-x.db", TestClock.Reference, 10, sha, true, TestClock.Reference, "manual", 1,
            new LocalStoreCounts(1, 1, 1, 1, 1, 1), null, annex);
        Check.True(BackupPreferencesRules.IsBound(backup), "annexe liée à cette copie");
        Check.False(BackupPreferencesRules.IsBound(backup with { Sha256 = new string('d', 64) }), "autre copie : annexe non liée");
        Check.False(BackupPreferencesRules.IsBound(backup with { Preferences = annex with { Json = annex.Json.Replace("120", "130", StringComparison.Ordinal) } }), "annexe modifiée refusée");
        Check.False(BackupPreferencesRules.IsBound(backup with { Preferences = null }), "sans annexe : non liée");
        Check.Equal(2, BackupPreferencesRules.Values(annex.Json).Length, "valeurs relues");
        Check.Equal(0, BackupPreferencesRules.Values("pas du JSON").Length, "annexe illisible : rien");
    }

    // ---------- Takeover of the Domenia 1 data ----------

    private static ImmutableDictionary<string, long> EmptyTargets() =>
        ImmutableDictionary<string, long>.Empty.Add("ad_objects", 0).Add("park_state", 0).Add("user_scan_history", 0).Add("secret_state", 0);

    private static LegacyDatabase Base(string schema = "11", string? revision = "1", string? domain = "example.local") =>
        new("Domenia.db", @"C:\Users\x\AppData\Local\DOMENIA\Domenia.db", schema, revision, domain, 1000,
        [
            new LegacyPart("links", "Associations déclarées", "user_machine_links", 49, 12, "addMissing"),
            new LegacyPart("objects", "Index des objets", "ad_objects", 100, 50, "emptyOnly"),
            new LegacyPart("receipts", "Reçus terminés", "operation_receipts", 41, 0, "history"),
        ]);

    private static LegacyFile File(string kind, long rows = 10, long bytes = 1000, int duplicates = 0, bool locked = true, params string[] domains) =>
        new(kind, @"Index\" + kind + ".tsv", bytes, rows, 0, duplicates, new string('a', 64), [.. domains], locked);

    private static LegacySource Source(LegacyDatabase? database = null, ImmutableArray<LegacyFile>? files = null, ImmutableDictionary<string, long>? targets = null, string? applied = null) =>
        new(true, "loc", "example.local", TestClock.Reference, database, [], files ?? [], targets ?? EmptyTargets(), "m1", applied, null);

    [Test]
    public static void Takeover_of_the_Domenia_1_base_follows_the_rule_of_each_part()
    {
        var plan = LegacyRules.Plan(Source(Base()), "example.local");
        Check.Equal(0, plan.Blockers.Length, "aucun blocage");
        Check.Equal("add", plan.Steps.Single(s => s.Id == "part.links").Action, "associations ajoutées");
        Check.Equal(37L, plan.Steps.Single(s => s.Id == "part.links").Rows, "seules les associations absentes");
        Check.Equal("keep", plan.Steps.Single(s => s.Id == "part.objects").Action, "table déjà alimentée : aucune fusion");
        Check.Equal("import", plan.Steps.Single(s => s.Id == "part.receipts").Action, "historique repris en lecture seule");
        Check.Equal(78L, plan.WriteCount, "lignes à écrire");
        Check.True(plan.Allowed, "reprise possible");

        Check.Contains("Version de base non prise en charge", LegacyRules.Plan(Source(Base(schema: "10")), "example.local").Blockers.Single(), "schéma 11 exigé");
        Check.Contains("Révision", LegacyRules.Plan(Source(Base(revision: "2")), "example.local").Blockers.Single(), "révision 1 exigée");
        var other = LegacyRules.Plan(Source(Base(domain: "autre.local")), "example.local");
        Check.Contains("Domaine différent", other.Blockers.Single(), "aucune fusion entre domaines");
        Check.Equal(0L, other.WriteCount, "un plan refusé n’écrit rien");
        Check.True(other.Steps.Where(s => s.Rows > 0).All(s => s.Action == "refuse"), "écritures reportées");

        var already = LegacyRules.Plan(Source(Base(), applied: "m1"), "example.local");
        Check.True(already.Already && already.WriteCount == 0, "reprise identique déjà appliquée");
        Check.True(already.Steps.All(s => s.Action == "ignore"), "rien à écrire");
        Check.Contains("Une autre reprise", LegacyRules.Plan(Source(Base(), applied: "m0"), "example.local").Blockers.Single(), "autre reprise appliquée");
        Check.Equal("example.local", LegacyRules.DomainOf("CN=x,OU=y,DC=Example,DC=Local"), "domaine d’un DN");
        Check.False(LegacyRules.Plan(new LegacySource(false, "loc", "", null, null, [], [], EmptyTargets(), "", null, null), "example.local").Allowed, "rien trouvé");
    }

    [Test]
    public static void Takeover_of_the_older_files_keeps_every_guard_of_Domenia_1()
    {
        var ok = LegacyRules.Plan(Source(files: [File("Objets", domains: "example.local"), File("Liens", rows: 4)]), "example.local");
        Check.Equal(0, ok.Blockers.Length, "fichiers admis");
        Check.Equal("import", ok.Steps.Single(s => s.Id == "file.Objets").Action, "objets repris dans une table vide");
        Check.Equal("add", ok.Steps.Single(s => s.Id == "file.Liens").Action, "liens ajoutés, existants conservés");
        Check.Equal(14L, ok.WriteCount, "lignes reprises");

        static string Blocker(LegacySource source) => string.Join(" ", LegacyRules.Plan(source, "example.local").Blockers);
        Check.Contains("trop volumineux", Blocker(Source(files: [File("Objets", bytes: LegacyRules.MaxFileBytes + 1, domains: "example.local")])), "128 Mo au plus");
        Check.Contains("250", Blocker(Source(files: [File("Parc", rows: LegacyRules.MaxRows + 1)])), "250 000 lignes au plus");
        Check.Contains("Doublon", Blocker(Source(files: [File("Recherches", duplicates: 1)])), "doublon refusé");
        Check.Contains("en cours d’écriture", Blocker(Source(files: [File("Secrets", locked: false)])), "fichier lu sous verrou");
        Check.Contains("Plusieurs domaines", Blocker(Source(files: [File("Objets", domains: ["example.local", "autre.local"])])), "un seul domaine");
        Check.Contains("Domaine différent", Blocker(Source(files: [File("Objets", domains: "autre.local")])), "même domaine que la session");
        Check.Contains("contient déjà des données", Blocker(Source(files: [File("Objets", domains: "example.local")], targets: EmptyTargets().SetItem("ad_objects", 5))), "quatre tables cibles vides");
        Check.Contains("inconnu", Blocker(Source(files: [File("Objets", domains: "example.local")], targets: ImmutableDictionary<string, long>.Empty)), "état des tables exigé");
    }

    // ---------- Destinations, purge per table, zoom and window ----------

    [Test]
    public static void Destination_of_a_copy_or_a_move_is_checked_read_only()
    {
        const string Active = @"C:\Users\x\AppData\Local\Domenia\Data\Domenia.db";
        const long Base = 100L << 20;
        var ok = new DestinationFacts(true, true, false, false, 10L << 30);
        Check.True(LocalStoreRules.CheckDestination(@"D:\Domenia\copie.db", "copy", Active, Base, ok).Ok, "copie admise");
        Check.Contains("disque local fixe", LocalStoreRules.CheckDestination(@"E:\copie.db", "copy", Active, Base, ok with { LocalFixedDrive = false }).Problem, "lecteur amovible refusé");
        Check.Contains("Dossier absent", LocalStoreRules.CheckDestination(@"D:\absent\copie.db", "copy", Active, Base, ok with { FolderExists = false }).Problem, "dossier absent");
        Check.Contains("Lien ou jonction", LocalStoreRules.CheckDestination(@"D:\lien\copie.db", "copy", Active, Base, ok with { ReparsePoint = true }).Problem, "jonction refusée");
        Check.Contains("nouveau fichier", LocalStoreRules.CheckDestination(@"D:\Domenia\Domenia.db", "move", Active, Base, ok with { FileExists = true }).Problem, "déplacement vers un nouveau fichier");
        Check.Contains("remplacé", LocalStoreRules.CheckDestination(@"D:\Domenia\copie.db", "copy", Active, Base, ok with { FileExists = true }).Text, "copie : remplacement dit");
        var small = LocalStoreRules.CheckDestination(@"D:\Domenia\Domenia.db", "move", Active, Base, ok with { FreeBytes = 50L << 20 });
        Check.Contains("Espace insuffisant", small.Problem, "réserve exigée");
        Check.Equal(LocalStoreRules.CopyReserve(Base), small.ReserveBytes, "deux copies et 32 Mo");
        Check.Contains("réseau", LocalStoreRules.CheckDestination(@"\\srv\x\copie.db", "copy", Active, Base, ok).Problem, "partage refusé");
        Check.Null(LocalStoreRules.BackupFileProblem(@"%LOCALAPPDATA%\Domenia\Data\Domains\example.local\Backups\Domenia-x.db"), "dossier des sauvegardes admis");
        Check.Contains("partage", LocalStoreRules.BackupFileProblem(@"\\srv\Domenia.db"), "sauvegarde sur un partage refusée");
        Check.Contains(".db", LocalStoreRules.BackupFileProblem(@"D:\copie.txt"), "fichier .db exigé");
        Check.Equal("Domenia-20261021-1826.db", StorageWritePlans.ExportFileName(TestClock.Reference, TestClock.Paris), "nom proposé Domenia-AAAAMMJJ-HHmm.db");
    }

    [Test]
    public static void Purge_counts_the_rows_of_every_table()
    {
        var store = SimulatedStore();
        foreach (var (category, days) in new[] { ("observations", 730), ("snapshots", 730), ("history", 30), ("index", 730) })
        {
            var rows = LocalStoreRules.PurgeTableRows(store, category, days);
            Check.True(rows.All(r => r.Rows > 0), "lignes comptées pour chaque table : " + category);
            Check.Equal(rows.Where(r => r.Action != "reset").Sum(r => r.Rows), LocalStoreRules.PurgeRows(store, category, days), "total de la catégorie : " + category);
        }
        var preview = LocalStoreRules.PurgePlan(store, ["observations"], 730, TestClock.Reference, TestClock.Paris);
        Check.Equal(6, preview.Targets.Length, "six tables d’observations");
        Check.True(preview.Targets.All(t => t.Rows > 0), "aucune colonne vide");
        Check.Equal(1L, LocalStoreRules.PurgeTableRows(store, "index", 730).Single(t => t.Table == "sync_state").Rows, "point de reprise réinitialisé, pas retiré");
        var unknown = store with { Tables = [] };
        Check.True(LocalStoreRules.PurgeTableRows(unknown, "observations", 730).Skip(1).All(t => t.Rows == 0), "sans comptage par table : total sur la première, rien d’inventé");
    }

    [Test]
    public static void Zoom_and_window_are_bounded_and_brought_back_on_a_screen()
    {
        Check.Equal(100, WindowRules.ReadZoom(null), "zoom par défaut");
        Check.Equal(120, WindowRules.ReadZoom(Json("120")), "zoom relu");
        Check.Equal(100, WindowRules.ReadZoom(Json("200")), "zoom hors bornes : défaut");
        Check.Equal(125, WindowRules.ClampZoom(124.6), "arrondi");
        Check.Equal(150, WindowRules.ClampZoom(300), "plafond 150");
        Check.Equal(100, WindowRules.ClampZoom(double.NaN), "valeur illisible");

        var saved = WindowRules.ReadPlacement(Json("""{"x":3000,"y":100,"width":1400,"height":900,"maximized":true}"""));
        Check.NotNull(saved, "fenêtre relue");
        Check.Null(WindowRules.ReadPlacement(Json("""{"x":"a"}""")), "fenêtre illisible");
        Check.Null(WindowRules.ReadPlacement(Json("""{"x":0,"y":0,"width":100,"height":100}""")), "taille absurde");
        var primary = new ScreenArea(0, 0, 1920, 1040);
        var gone = WindowRules.Fit(saved!, [primary], primary);
        Check.Equal(new WindowPlacement(260, 70, 1400, 900, true), gone, "moniteur disparu : centrée sur l’écran principal, agrandie");
        var edge = WindowRules.Fit(new WindowPlacement(1800, 100, 1400, 900, false), [primary], primary);
        Check.Equal(new WindowPlacement(520, 100, 1400, 900, false), edge, "bande visible : toute la fenêtre ramenée dans l’écran");
        var big = WindowRules.Fit(new WindowPlacement(0, 0, 4000, 3000, false), [primary], primary);
        Check.Equal(1920, big.Width, "largeur ramenée à l’écran");
        Check.Contains("par défaut", WindowRules.Describe(null), "aucune fenêtre mémorisée");
        Check.Contains("agrandie", WindowRules.Describe(gone), "état dit");
        Check.Equal("Paris (UTC+01:00, heure d’été UTC+02:00)", SettingsFormat.ZoneLabel(TestClock.Paris), "fuseau en français, jamais l’identifiant de Windows");
    }

    [Test]
    public static void Saved_window_handles_small_screens_layout_gaps_and_extreme_coordinates()
    {
        Check.Null(WindowRules.ReadPlacement(Json("""{"x":-2147483648,"y":0,"width":1400,"height":900}""")), "coordonnée malformée écartée sans débordement");
        var small = new ScreenArea(0, 0, 800, 560);
        Check.Equal(new WindowPlacement(0, 0, 800, 560, false), WindowRules.Fit(new(0, 0, 1440, 900, false), [small], small), "petit écran : dimensions bornées");
        var primary = new ScreenArea(0, 0, 1920, 1040); var upper = new ScreenArea(1920, -1080, 1920, 1040);
        var gap = WindowRules.Fit(new(2400, 500, 1000, 700, false), [primary, upper], primary);
        Check.Equal(new WindowPlacement(460, 170, 1000, 700, false), gap, "trou de disposition en L : retour centré");
        var minimum = WindowRules.Fit(new(0, 0, 400, 300, false), [small], small);
        Check.Equal(640, minimum.Width, "minimum utilisable"); Check.Equal(420, minimum.Height, "hauteur minimum");
    }

    // ---------- Writer and scenarios (pure) ----------

    [Test]
    public static void Writer_resume_waits_for_an_active_save_and_scenarios_read_the_state()
    {
        var store = SimulatedStore();
        Check.Equal("normal", StorageWritePlans.ScenarioOf(store), "base saine");
        var suspended = store with { Writer = store.Writer with { Suspended = true, Pending = 4 } };
        Check.Equal(StorageWritePlans.WriterResume, StorageWritePlans.WriterResumeDraft(suspended).Kind, "reprise proposée");
        Check.Equal(StorageWritePlans.StoreUnavailable, Check.Throws<DomeniaOperationException>(() => StorageWritePlans.WriterResumeDraft(suspended with { Writer = suspended.Writer with { Active = true } }), "enregistrement actif").Code, "refusé tant qu’un enregistrement est actif");
        Check.Equal(WriteErrors.NothingToDo, Check.Throws<DomeniaOperationException>(() => StorageWritePlans.WriterResumeDraft(store), "écrivain actif").Code, "rien à reprendre");
        Check.Equal("writerSuspended", StorageWritePlans.ScenarioOf(suspended), "écrivain suspendu");
        Check.Equal("storeUnreadable", StorageWritePlans.ScenarioOf(store with { Maintenance = store.Maintenance with { Recovery = true } }), "base illisible");
        Check.Equal("switchInterrupted", StorageWritePlans.ScenarioOf(store with { Maintenance = store.Maintenance with { Locked = true, TargetPath = @"D:\x.db" } }), "bascule interrompue");
        Check.Equal("lowSpace", StorageWritePlans.ScenarioOf(store with { Space = new LocalStoreSpace(100L << 20, TestClock.Reference, 0) }), "disque presque plein");
        Check.Equal(WriteErrors.NothingToDo, Check.Throws<DomeniaOperationException>(() => StorageWritePlans.ScenarioDraft(store, "normal"), "déjà normal").Code, "état déjà atteint");
        Check.Equal(StorageWritePlans.StoreUnavailable, Check.Throws<DomeniaOperationException>(() => StorageWritePlans.ScenarioDraft(store with { Simulated = false }, "storeUnreadable"), "base réelle").Code, "jamais sur une base réelle");
        Check.Throws<ArgumentException>(() => StorageWritePlans.ScenarioDraft(store, "panne"), "scénario inconnu");
        var unreadable = LocalStoreRules.Maintenance(store with { Maintenance = store.Maintenance with { Recovery = true } });
        Check.True(unreadable.Restore && !unreadable.Move && !unreadable.Rollback, "base illisible : seule la restauration");
    }

    // ---------- Bridge (simulation) ----------

    [Test]
    public static async Task Backup_joins_the_annex_of_the_approved_preferences_only()
    {
        var bridge = new SimulatedBridge();
        await bridge.Preferences.SetAsync(SettingsViewRules.ConnectionKey, Json("""{"rememberLogin":true,"lastLogin":"jdupont"}"""), default);
        await bridge.Preferences.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(120), default);
        await bridge.Preferences.SetAsync(PreferenceApproval.WindowKey, Json("""{"x":1,"y":2,"width":1400,"height":900}"""), default);
        var planned = await ResultAsync(bridge, "settings.storage.backup.plan");
        var annex = planned.GetProperty("plan").GetProperty("changes").EnumerateArray().Single(c => c.GetProperty("attribute").GetString() == "backup.preferences").GetProperty("afterValue").GetString()!;
        Check.Contains(PreferenceApproval.ZoomKey, annex, "zoom joint");
        Check.False(annex.Contains("jdupont", StringComparison.Ordinal) || annex.Contains(PreferenceApproval.WindowKey, StringComparison.Ordinal), "ni identité ni fenêtre dans le plan");
        var file = planned.GetProperty("plan").GetProperty("changes").EnumerateArray().Single(c => c.GetProperty("attribute").GetString() == "backup.file").GetProperty("afterValue").GetString();
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "copie et annexe relues");
        var copy = Store(bridge).Backups.Single(b => b.FileName == file);
        Check.True(BackupPreferencesRules.IsBound(copy), "annexe liée au SHA-256 de la copie du plan");
        Check.Equal(1, copy.PreferenceKeys, "une clé approuvée");
        var view = await ResultAsync(bridge, "settings.storage");
        Check.True(view.GetProperty("backups")[0].GetProperty("preferencesBound").GetBoolean(), "annexe dite dans la liste");
    }

    [Test]
    public static async Task Restore_re_applies_the_annex_after_a_verified_switch_only()
    {
        var bridge = new SimulatedBridge();
        var backup = Store(bridge).Backups.First(b => b.Kind == "manual");
        await bridge.Preferences.SetAsync(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(StoragePolicyRules.Default with { PresenceDays = 10 }), default);
        await bridge.Preferences.SetAsync(SettingsViewRules.ConnectionKey, Json("""{"rememberLogin":true,"lastLogin":"jdupont"}"""), default);
        var planned = await ResultAsync(bridge, "settings.storage.restore.plan", Args(new { backupId = backup.Id }));
        var changes = planned.GetProperty("plan").GetProperty("changes").EnumerateArray().Select(c => c.GetProperty("attribute").GetString()).ToList();
        Check.True(changes.Contains("restore.preferences") && changes.Contains("restore.lastBatch") && changes.Contains("restore.lastMeasure"), "annexe, dernier lot et dernière mesure dans le plan");
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned, Domain(bridge)));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "bascule vérifiée");
        var applied = await ResultAsync(bridge, "settings.storage.restore.preferences", Args(new { receiptId = receipt.GetProperty("id").GetString() }));
        Check.Equal(2, applied.GetProperty("changed").GetInt32(), "deux clés de l’annexe réappliquées");
        Check.True(bridge.Preferences.TryGet(StoragePolicyRules.PreferenceKey, out var policy) && StoragePolicyRules.Read(policy, out _).PresenceDays == 30, "politique de la sauvegarde rétablie");
        Check.True(bridge.Preferences.TryGet(SettingsViewRules.ConnectionKey, out var connection) && connection.GetRawText().Contains("jdupont", StringComparison.Ordinal), "identité de connexion de ce poste conservée");

        Check.Equal(WriteErrors.ReceiptUnknown, await ErrorAsync(bridge, "settings.storage.restore.preferences", Args(new { receiptId = new string('f', 32) })), "reçu inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.restore.preferences", Args(new { receiptId = "x" })), "identifiant mal formé");
        var backupPlan = await ResultAsync(bridge, "settings.storage.backup.plan");
        var backupReceipt = await ResultAsync(bridge, "write.execute", Execute(backupPlan));
        Check.Equal(SettingsOperations.RestorePreferencesCode, await ErrorAsync(bridge, "settings.storage.restore.preferences", Args(new { receiptId = backupReceipt.GetProperty("id").GetString() })), "seulement une restauration vérifiée");

        var migration = Store(bridge).Backups.First(b => b.Kind == "migration");
        var plain = await ResultAsync(bridge, "settings.storage.restore.plan", Args(new { backupId = migration.Id }));
        var plainReceipt = await ResultAsync(bridge, "write.execute", Execute(plain, Domain(bridge)));
        var none = await ResultAsync(bridge, "settings.storage.restore.preferences", Args(new { receiptId = plainReceipt.GetProperty("id").GetString() }));
        Check.Equal(0, none.GetProperty("changed").GetInt32(), "sauvegarde sans annexe : données seules");
    }

    [Test]
    public static async Task A_published_copy_can_be_restored_and_other_files_are_named_refusals()
    {
        var bridge = new SimulatedBridge();
        var copy = await ResultAsync(bridge, "settings.storage.backupCopy.plan", Args(new { destination = @"D:\Domenia\copie.db" }));
        Check.Equal("verified", (await ResultAsync(bridge, "write.execute", Execute(copy))).GetProperty("verification").GetString(), "copie publiée relue");
        var fromCopy = await ResultAsync(bridge, "settings.storage.restore.plan", Args(new { file = @"D:\Domenia\copie.db" }));
        Check.Equal(StorageWritePlans.Restore, fromCopy.GetProperty("plan").GetProperty("kind").GetString(), "copie publiée restaurable");
        var folder = StorageViewBuilder.BackupFolder(Store(bridge).PathLabel)!;
        var inFolder = await ResultAsync(bridge, "settings.storage.restore.plan", Args(new { file = folder + @"\" + Store(bridge).Backups[0].FileName }));
        Check.Equal(StorageWritePlans.Restore, inFolder.GetProperty("plan").GetProperty("kind").GetString(), "fichier du dossier Backups restaurable");
        Check.Equal(WriteErrors.TargetUnknown, await ErrorAsync(bridge, "settings.storage.restore.plan", Args(new { file = @"D:\Domenia\autre.db" })), "fichier inconnu de la base fictive");
        Check.Equal(StorageWritePlans.DestinationRefused, await ErrorAsync(bridge, "settings.storage.restore.plan", Args(new { file = @"\\srv\x.db" })), "partage refusé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.restore.plan", Args(new { backupId = Store(bridge).Backups[0].Id, file = @"D:\x.db" })), "l’un ou l’autre");
    }

    [Test]
    public static async Task Suspended_writer_is_resumed_once_through_the_circuit()
    {
        var bridge = new SimulatedBridge();
        await PlayAsync(bridge, "writerSuspended");
        Check.True(Store(bridge).Writer.Suspended, "écrivain suspendu");
        var view = await ResultAsync(bridge, "settings.storage");
        Check.True(view.GetProperty("writer").GetProperty("canResume").GetBoolean(), "reprise proposée");
        Check.Equal("writerSuspended", view.GetProperty("scenario").GetString(), "scénario dit");
        var revision = Store(bridge).Revision;
        var resume = await ResultAsync(bridge, "settings.storage.writerResume.plan");
        var receipt = await ResultAsync(bridge, "write.execute", Execute(resume));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "écrivain réarmé");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "écrivain relu actif");
        Check.False(Store(bridge).Writer.Suspended, "plus suspendu");
        Check.Equal(revision + 1, Store(bridge).Revision, "ce qui était en mémoire est enregistré");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.writerResume.plan"), "plus rien à reprendre");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.demo.scenario.plan", Args(new { scenario = "normal" })), "déjà normal");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.demo.scenario.plan", Args(new { scenario = "panne" })), "scénario inconnu");
    }

    [Test]
    public static async Task Interrupted_switch_is_resumed_or_abandoned_never_both()
    {
        var bridge = new SimulatedBridge();
        var original = Store(bridge).PathLabel;
        await PlayAsync(bridge, "switchInterrupted");
        Check.True(Store(bridge).Maintenance.Locked, "bascule à terminer");
        Check.Equal(StorageWritePlans.StoreUnavailable, await ErrorAsync(bridge, "settings.storage.backup.plan"), "aucune sauvegarde pendant une bascule à terminer");
        var resume = await ResultAsync(bridge, "settings.storage.resume.plan");
        Check.Equal("verified", (await ResultAsync(bridge, "write.execute", Execute(resume))).GetProperty("verification").GetString(), "bascule terminée et relue");
        Check.True(Store(bridge).PathLabel.EndsWith("Domenia-deplacee.db", StringComparison.Ordinal), "base active : la copie désignée");
        var back = await ResultAsync(bridge, "settings.storage.rollback.plan");
        Check.Equal("verified", (await ResultAsync(bridge, "write.execute", Execute(back))).GetProperty("verification").GetString(), "retour relu");
        Check.Equal(original, Store(bridge).PathLabel, "base d’origine rétablie");

        var second = new SimulatedBridge();
        await PlayAsync(second, "switchInterrupted");
        var abandon = await ResultAsync(second, "settings.storage.rollback.plan");
        Check.Equal("verified", (await ResultAsync(second, "write.execute", Execute(abandon))).GetProperty("verification").GetString(), "bascule abandonnée");
        Check.False(Store(second).Maintenance.Locked, "marqueur retiré");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(second, "settings.storage.resume.plan"), "plus rien à reprendre");
    }

    [Test]
    public static async Task Unreadable_base_only_accepts_a_restore()
    {
        var bridge = new SimulatedBridge();
        await PlayAsync(bridge, "storeUnreadable");
        Check.Equal(StorageWritePlans.StoreUnavailable, await ErrorAsync(bridge, "settings.storage.backup.plan"), "aucune sauvegarde d’une base illisible");
        var checkedView = await ResultAsync(bridge, "settings.storage.integrity");
        Check.Equal("Défaut", checkedView.GetProperty("integrity").GetProperty("verdict").GetString(), "défaut prouvé");
        Check.False(checkedView.GetProperty("maintenance").GetProperty("move").GetBoolean(), "pas de déplacement");
        Check.True(checkedView.GetProperty("maintenance").GetProperty("restore").GetBoolean(), "restauration proposée");
        var backup = Store(bridge).Backups.First(StoragePolicyRules.IsVerified);
        var planned = await ResultAsync(bridge, "settings.storage.restore.plan", Args(new { backupId = backup.Id }));
        Check.Equal("verified", (await ResultAsync(bridge, "write.execute", Execute(planned, Domain(bridge)))).GetProperty("verification").GetString(), "base restaurée relue");
        Check.False(Store(bridge).Maintenance.Recovery, "base de nouveau lisible");

        var low = new SimulatedBridge();
        await PlayAsync(low, "lowSpace");
        var space = (await ResultAsync(low, "settings.storage")).GetProperty("space");
        Check.True(space.GetProperty("blocksCollections").GetBoolean(), "collectes suspendues sous 512 Mo");
    }

    [Test]
    public static async Task Legacy_takeover_reads_the_Domenia_1_base_and_writes_each_step_once()
    {
        var bridge = new SimulatedBridge();
        var preview = await ResultAsync(bridge, "settings.storage.legacy.preview");
        Check.Equal(101L, preview.GetProperty("writeCount").GetInt64(), "associations, requêtes, reçus et réglages à reprendre");
        var steps = preview.GetProperty("steps").EnumerateArray().ToDictionary(s => s.GetProperty("id").GetString()!, s => s.GetProperty("action").GetString());
        Check.Equal("keep", steps["part.objects"], "index déjà alimenté : conservé");
        Check.Equal("add", steps["part.links"], "associations absentes ajoutées");
        var associations = Store(bridge).Counts.Associations;
        var planned = await ResultAsync(bridge, "settings.storage.legacy.plan", Args(new { fingerprint = preview.GetProperty("fingerprint").GetString() }));
        Check.True(planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "nom du domaine saisi");
        Check.Equal("verified", (await ResultAsync(bridge, "write.execute", Execute(planned, Domain(bridge)))).GetProperty("verification").GetString(), "marqueur relu");
        Check.Equal(associations + 37, Store(bridge).Counts.Associations, "37 associations ajoutées");
        Check.True(Store(bridge).Backups.Any(b => b.Kind == "import"), "sauvegarde de migration faite avant");
        var again = await ResultAsync(bridge, "settings.storage.legacy.preview");
        Check.True(again.GetProperty("nothingToDo").GetBoolean(), "reprise idempotente");
    }

    [Test]
    public static async Task Purge_preview_fills_the_rows_of_every_table()
    {
        var bridge = new SimulatedBridge();
        var preview = await ResultAsync(bridge, "settings.storage.purge.preview", Args(new { categories = new[] { "observations", "index" } }));
        var targets = preview.GetProperty("targets").EnumerateArray().ToList();
        Check.Equal(13, targets.Count, "six tables d’observations et sept de l’index");
        Check.True(targets.All(t => t.GetProperty("rows").GetInt64() > 0), "aucune ligne vide dans la simulation");
    }

    [Test]
    public static async Task Automatic_backup_runs_through_the_circuit_when_due_and_waits_otherwise()
    {
        var bridge = new SimulatedBridge();
        var scheduler = StorageBackupScheduler.From(bridge.Context);
        Check.Equal("disabled", await scheduler.TickAsync(default), "désactivée par défaut");
        await ResultAsync(bridge, "settings.storage.backup.schedule.set", Args(new { enabled = true, hours = 24, keep = 7 }));
        Check.Equal("recent", await scheduler.TickAsync(default), "dernière copie de moins de 24 h");
        await ResultAsync(bridge, "settings.storage.backup.schedule.set", Args(new { enabled = true, hours = 1, keep = 7 }));
        var before = Store(bridge).Backups.Length;
        Check.Equal("scheduled", await scheduler.TickAsync(default), "copie due");
        Check.Equal(before + 1, Store(bridge).Backups.Length, "une copie planifiée de plus");
        Check.True(Store(bridge).Backups.Any(b => b.Kind == "scheduled" && BackupPreferencesRules.IsBound(b)), "copie planifiée vérifiée, annexe liée");
        Check.True(((MemoryReceiptStore)bridge.Receipts).Appends > 0, "reçu de la copie planifiée");
        Check.Equal("retryCooldown", await scheduler.TickAsync(default), "15 min entre deux essais");
        Check.NotNull(scheduler.State.LastSuccess, "dernier succès retenu");

        var busy = new SimulatedBridge();
        await ResultAsync(busy, "settings.storage.backup.schedule.set", Args(new { enabled = true, hours = 1, keep = 7 }));
        await PlayAsync(busy, "writerSuspended");
        Check.Equal("busy", await StorageBackupScheduler.From(busy.Context).TickAsync(default), "différée pendant un enregistrement local");
    }

    [Test]
    public static async Task Reset_of_everything_forgets_the_zoom_and_the_window()
    {
        var bridge = new SimulatedBridge();
        await bridge.Preferences.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(130), default);
        await bridge.Preferences.SetAsync(PreferenceApproval.WindowKey, Json("""{"x":1,"y":2,"width":1400,"height":900}"""), default);
        var result = await ResultAsync(bridge, "settings.preferences.reset", Args(new { group = "all" }));
        Check.Equal(0, result.GetProperty("failed").GetArrayLength(), "tout réinitialisé");
        Check.False(bridge.Preferences.TryGet(PreferenceApproval.ZoomKey, out _), "zoom oublié");
        Check.False(bridge.Preferences.TryGet(PreferenceApproval.WindowKey, out _), "fenêtre oubliée");
    }

    // ---------- Directory mode of this version ----------

    [Test]
    public static async Task Directory_mode_refuses_every_plan_of_the_local_base_with_its_reason()
    {
        var clock = TestClock.Fixed();
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        var assemblies = new[] { typeof(SimulatedDirectorySource).Assembly };
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, assemblies),
            writers: WriteExecutors.Discover(source, assemblies), receipts: new MemoryReceiptStore());
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(DashboardOperations).Assembly]));
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, r => { lock (sent) { sent.Add(r); } }, AdmissionGuards.For(AppMode.Directory));
        async Task<BridgeResponse> Call(string operation, string arguments)
        {
            var id = "d" + sent.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) + operation;
            await dispatcher.HandleAsync("{\"id\":\"" + id + "\",\"op\":\"" + operation + "\",\"args\":" + arguments + "}", default);
            lock (sent)
            {
                return sent.Last(r => r.Id == id);
            }
        }
        var fingerprint = Args(new { fingerprint = new string('0', 64) });
        (string Operation, string Arguments)[] plans =
        [
            ("settings.storage.backup.plan", "{}"),
            ("settings.storage.backupCopy.plan", Args(new { destination = @"D:\Domenia\copie.db" })),
            ("settings.storage.retention.plan", fingerprint),
            ("settings.storage.purge.plan", Args(new { categories = new[] { "observations" }, fingerprint = new string('0', 64) })),
            ("settings.storage.move.plan", Args(new { destination = @"D:\Domenia\Domenia.db" })),
            ("settings.storage.restore.plan", Args(new { backupId = new string('a', 32) })),
            ("settings.storage.resume.plan", "{}"),
            ("settings.storage.rollback.plan", "{}"),
            ("settings.storage.writerResume.plan", "{}"),
            ("settings.storage.legacy.plan", fingerprint),
            ("settings.storage.retention.preview", "{}"),
            ("settings.storage.legacy.preview", "{}"),
            ("settings.storage.measure", "{}"),
            ("settings.storage.integrity", "{}"),
        ];
        foreach (var (operation, arguments) in plans)
        {
            var response = await Call(operation, arguments);
            Check.Equal("error", response.Kind, operation + " refusée en mode annuaire");
            Check.Equal(StorageWritePlans.StoreUnavailable, response.Error?.Code, "raison dite : " + operation);
        }
        var scenario = await Call("settings.demo.scenario.plan", Args(new { scenario = "lowSpace" }));
        Check.Equal(SettingsOperations.SimulationCode, scenario.Error?.Code, "scénarios : simulation seulement");
        var storage = await Call("settings.storage", "{}");
        Check.Equal("result", storage.Kind, "état de la base lisible");
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(storage.Data, BridgeJson.Options));
        Check.False(document.RootElement.GetProperty("available").GetBoolean(), "base pas encore branchée, dit");
    }
}
