using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Pure rules of the Paramètres screen (docs/ops/parametres.md): written with the code, run at the end (decision of David, 21/10).</summary>
internal static class SettingsRulesTests
{
    private const string Nbsp = FrenchText.Nbsp;

    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }

    private static IReadOnlyList<IReadOnlyList<bool>> Grid(ImmutableArray<ImmutableArray<bool>> grid) => [.. grid.Select(r => (IReadOnlyList<bool>)r)];

    private static LocalStoreSnapshot SimulatedStore() =>
        SimulatedLocalStore.For(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed())).Snapshot();

    // ---------- Collection window ----------

    [Test]
    public static void Window_parses_days_ranges_and_overnight_ranges()
    {
        var week = CollectionWindowRules.Parse("lun-ven 07:30-12:00 13:30-18:00; sam");
        Check.True(week.Valid, "fenêtre valide");
        Check.Equal(CollectionWindowMode.Rules, week.Mode, "mode règles");
        Check.Equal(3, week.Rules.Length, "deux plages en semaine et le samedi");
        Check.True(week.Rules[0].Days.SequenceEqual([1, 2, 3, 4, 5]), "lundi à vendredi");
        Check.Equal(450, week.Rules[0].StartMinute, "07:30");
        Check.Equal(720, week.Rules[0].EndMinute, "12:00");
        Check.True(week.Rules[2].Days.SequenceEqual([6]) && week.Rules[2].StartMinute == 0 && week.Rules[2].EndMinute == 1440, "samedi entier");

        var night = CollectionWindowRules.Parse("ven-lun 22:00-06:00");
        Check.True(night.Valid && night.Rules[0].Overnight, "plage de nuit");
        Check.True(night.Rules[0].Days.SequenceEqual([5, 6, 0, 1]), "vendredi, samedi, dimanche, lundi");
        Check.True(CollectionWindowRules.Covers(night.Rules[0], DayOfWeek.Tuesday, 5 * 60), "mardi 05:00 : suite de la nuit de lundi");
        Check.False(CollectionWindowRules.Covers(night.Rules[0], DayOfWeek.Wednesday, 5 * 60), "mercredi 05:00 : hors fenêtre");

        Check.Equal(CollectionWindowMode.Always, CollectionWindowRules.Parse("").Mode, "vide : toujours");
        Check.Equal(CollectionWindowMode.Always, CollectionWindowRules.Parse("  Toujours ").Mode, "toujours, casse ignorée");
        Check.Equal(CollectionWindowMode.Never, CollectionWindowRules.Parse("JAMAIS").Mode, "jamais");
        Check.True(CollectionWindowRules.Parse("Mercredi 08:00-09:00").Valid, "nom complet du jour");
        Check.True(CollectionWindowRules.Parse("tous 08:00-24:00").Valid, "tous les jours, fin à 24:00");
    }

    [Test]
    public static void Window_names_each_faulty_token_and_never_guesses()
    {
        var days = CollectionWindowRules.Parse("lundy 08:00-09:00");
        Check.False(days.Valid, "jour inconnu");
        Check.Equal(CollectionWindowMode.Invalid, days.Mode, "mode invalide");
        Check.Contains("Jours non reconnus", days.Errors[0], "jour nommé");
        Check.Contains("lundy", days.Errors[0], "jeton cité");
        Check.Contains("Heure invalide", CollectionWindowRules.Parse("lun 25:00-26:00").Errors[0], "heure hors bornes");
        Check.Contains("Plage vide", CollectionWindowRules.Parse("lun 08:00-08:00").Errors[0], "plage vide");
        Check.Contains("Plage horaire non reconnue", CollectionWindowRules.Parse("lun 8h-9h").Errors[0], "format d’heure");
        Check.False(CollectionWindowRules.Parse(new string('a', CollectionWindowRules.MaxLength + 1)).Valid, "plus de 400 caractères");
        Check.Equal(2, CollectionWindowRules.Parse("lundy; mardy").Errors.Length, "chaque clause fautive est dite");
    }

    [Test]
    public static void Window_state_names_the_next_change_in_local_time()
    {
        var window = CollectionWindowRules.Parse("lun-ven 07:30-12:00 13:30-18:00; sam");
        // Wednesday 21 October 2026, 18:26 in Paris: closed since 18:00, open again Thursday at 07:30 (05:30 UTC).
        var state = CollectionWindowRules.StateAt(window, TestClock.Reference, TestClock.Paris);
        Check.False(state.Open, "fermée à 18:26");
        Check.Equal(new DateTimeOffset(2026, 10, 22, 5, 30, 0, TimeSpan.Zero), state.NextChange, "reprise jeudi 07:30");
        Check.Equal("Fenêtre de collecte fermée" + FrenchText.Colon + "travaux de fond en pause, reprise demain à 07:30.",
            CollectionWindowRules.Sentence(state, TestClock.Reference, TestClock.Paris), "phrase");

        var morning = new DateTimeOffset(2026, 10, 22, 8, 0, 0, TimeSpan.Zero); // Thursday 10:00 in Paris
        var open = CollectionWindowRules.StateAt(window, morning, TestClock.Paris);
        Check.True(open.Open, "ouverte à 10:00");
        Check.Equal("Fenêtre de collecte ouverte jusqu’à 12:00.", CollectionWindowRules.Sentence(open, morning, TestClock.Paris), "fin de la plage");

        Check.True(CollectionWindowRules.StateAt(CollectionWindowRules.Parse("toujours"), morning, TestClock.Paris).Open, "toujours ouverte");
        Check.Contains("suspendus", CollectionWindowRules.Sentence(CollectionWindowRules.StateAt(CollectionWindowRules.Parse("lundy"), morning, TestClock.Paris), morning, TestClock.Paris), "invalide : travaux suspendus");
    }

    [Test]
    public static void Week_grid_and_text_are_inverse()
    {
        const string Text = "lun-ven 07:30-12:00 13:30-18:00; sam";
        var grid = CollectionWindowRules.WeekGrid(CollectionWindowRules.Parse(Text));
        Check.Equal(7, grid.Length, "sept jours");
        Check.True(grid.All(r => r.Length == 48), "48 demi-heures");
        Check.False(grid[0][14], "lundi 07:00 fermé");
        Check.True(grid[0][15], "lundi 07:30 ouvert");
        Check.True(grid[5].All(c => c), "samedi entier");
        Check.True(grid[6].All(c => !c), "dimanche fermé");
        Check.Equal(Text, CollectionWindowRules.FromWeekGrid(Grid(grid)), "aller-retour");

        bool[][] full = [.. Enumerable.Range(0, 7).Select(_ => Enumerable.Repeat(true, 48).ToArray())];
        bool[][] empty = [.. Enumerable.Range(0, 7).Select(_ => new bool[48])];
        Check.Equal("toujours", CollectionWindowRules.FromWeekGrid(full), "semaine pleine");
        Check.Equal("jamais", CollectionWindowRules.FromWeekGrid(empty), "semaine vide");
        Check.Throws<ArgumentException>(() => CollectionWindowRules.FromWeekGrid([new bool[48]]), "un seul jour refusé");

        var night = CollectionWindowRules.WeekGrid(CollectionWindowRules.Parse("lun 22:00-02:00"));
        Check.True(night[0][44] && night[1][0] && night[1][3] && !night[1][4], "la nuit de lundi déborde sur mardi jusqu’à 02:00");
    }

    // ---------- Collection settings ----------

    [Test]
    public static void Collection_settings_read_their_defaults_and_drop_what_is_out_of_bounds()
    {
        var warnings = new List<string>();
        var defaults = CollectionSettingsRules.Read(null, warnings);
        Check.Equal(CollectionSettingsRules.Standard, defaults.Profile, "profil Standard par défaut");
        Check.Equal(0, warnings.Count, "aucun avertissement sans réglage");

        var stored = CollectionSettingsRules.Read(Json("""{"profile":"slowNetwork","budgets":{"concurrency":2}}"""), warnings);
        Check.Equal(CollectionSettingsRules.SlowNetwork, stored.Profile, "profil réseau lent");
        Check.Equal(2, stored.Budgets[CollectionSettingsRules.Concurrency], "budget lu");
        var round = CollectionSettingsRules.Read(CollectionSettingsRules.ToJson(stored), warnings);
        Check.Equal(stored.Profile, round.Profile, "aller-retour du profil");
        Check.Equal(2, round.Budgets[CollectionSettingsRules.Concurrency], "aller-retour du budget");
        Check.Equal(0, warnings.Count, "aucun avertissement pour des valeurs valides");

        CollectionSettingsRules.Read(Json("""{"profile":"turbo"}"""), warnings);
        Check.Equal(1, warnings.Count, "profil inconnu signalé");
        warnings.Clear();
        CollectionSettingsRules.Read(Json("[1]"), warnings);
        Check.Contains("illisibles", warnings.Single(), "document illisible signalé");

        Check.Equal(3, CollectionSettingsRules.Profiles.Length, "trois profils de Domenia 1");
        Check.True(CollectionSettingsRules.BudgetDefinitions.All(b => b.Default >= b.Minimum && b.Default <= b.Maximum), "défauts dans leurs bornes");
    }

    [Test]
    public static void Collection_view_checks_a_window_without_saving_it()
    {
        var view = CollectionSettingsRules.CheckWindow("lun-ven 07:30-12:00", TestClock.Reference, TestClock.Paris);
        Check.True(view.Valid, "valide");
        Check.False(view.Open, "fermée mercredi 18:26");
        Check.Equal(7, view.Grid.Length, "grille de la semaine");
        var bad = CollectionSettingsRules.CheckWindow("lun 99:00-10:00", TestClock.Reference, TestClock.Paris);
        Check.False(bad.Valid, "invalide");
        Check.True(bad.Errors.Length > 0, "erreur dite");
    }

    // ---------- Storage policy ----------

    [Test]
    public static void Storage_policy_keeps_defaults_and_reports_an_unreadable_document()
    {
        Check.Equal(StoragePolicyRules.Default, StoragePolicyRules.Read(null, out var unreadable), "défaut");
        Check.False(unreadable, "absent n’est pas illisible");

        var partial = StoragePolicyRules.Read(Json("""{"presenceDays":45}"""), out unreadable);
        Check.False(unreadable, "valeur partielle valide");
        Check.Equal(45, partial.PresenceDays, "présence lue");
        Check.Equal(StoragePolicyRules.Default.InventoryDays, partial.InventoryDays, "clé absente : défaut");

        Check.Equal(StoragePolicyRules.Default, StoragePolicyRules.Read(Json("""{"backupHours":0}"""), out unreadable), "hors bornes : défaut");
        Check.True(unreadable, "hors bornes signalé illisible");
        StoragePolicyRules.Read(Json("""{"automaticBackup":"oui"}"""), out unreadable);
        Check.True(unreadable, "type faux signalé");
        StoragePolicyRules.Read(Json("\"texte\""), out unreadable);
        Check.True(unreadable, "document qui n’est pas un objet");

        Check.NotNull(StoragePolicyRules.Problem(StoragePolicyRules.Default with { BackupKeep = 1 }), "une seule copie refusée");
        Check.NotNull(StoragePolicyRules.Problem(StoragePolicyRules.Default with { ProbeDays = -1 }), "durée négative refusée");
        Check.Null(StoragePolicyRules.Problem(StoragePolicyRules.Default with { ProbeDays = 0 }), "0 = sans limite");
        var changed = StoragePolicyRules.Default with { AutomaticBackup = true, BackupHours = 12, LinkHistoryDays = 365 };
        Check.Equal(changed, StoragePolicyRules.Read(StoragePolicyRules.ToJson(changed), out _), "aller-retour");
    }

    [Test]
    public static void Retention_preview_counts_without_deleting_and_binds_its_fingerprint()
    {
        var store = SimulatedStore();
        var preview = StoragePolicyRules.Preview(StoragePolicyRules.Default, store, TestClock.Reference, TestClock.Paris);
        Check.False(preview.NothingToDo, "la base fictive a des mesures anciennes");
        Check.True(preview.TotalRows > 0, "lignes comptées");
        Check.Equal(preview.Families.Sum(f => f.Rows), preview.TotalRows, "total = somme des familles");
        Check.Equal(64, preview.Fingerprint.Length, "empreinte SHA-256");
        Check.Equal(preview.Fingerprint, StoragePolicyRules.Preview(StoragePolicyRules.Default, store, TestClock.Reference, TestClock.Paris).Fingerprint, "empreinte stable");
        var longer = StoragePolicyRules.Preview(StoragePolicyRules.Default with { PresenceDays = 365 }, store, TestClock.Reference, TestClock.Paris);
        Check.False(longer.Fingerprint == preview.Fingerprint, "autre politique, autre empreinte");
        Check.True(longer.TotalRows < preview.TotalRows, "conserver plus longtemps retire moins");
        var keepAll = StoragePolicyRules.Default with { PresenceDays = 0, ConsoleDays = 0, InventoryDays = 0, ProbeDays = 0, DetailDays = 0, LinkHistoryDays = 0 };
        Check.True(StoragePolicyRules.Preview(keepAll, store, TestClock.Reference, TestClock.Paris).NothingToDo, "sans limite : rien à retirer");
    }

    // ---------- Local base ----------

    [Test]
    public static void Purge_is_limited_to_closed_categories()
    {
        var store = SimulatedStore();
        var preview = LocalStoreRules.PurgePlan(store, ["observations", "receipts", "drop table"], LocalStoreRules.DefaultHistoryDays, TestClock.Reference, TestClock.Paris);
        Check.True(preview.Categories.SequenceEqual(["observations"]), "seule la catégorie purgeable est retenue");
        Check.Equal(2, preview.Refused.Length, "reçus et catégorie inconnue refusés");
        Check.Contains("jamais purgé", preview.Refused[0], "reçus jamais purgés");
        Check.Contains("catégorie inconnue", preview.Refused[1], "inconnue nommée");
        Check.True(preview.KeepsReceipts && preview.KeepsConfiguration && preview.KeepsManualLinks, "garanties dites");
        Check.Equal(4, LocalStoreRules.PurgeCategories.Count(p => p.Purgeable), "quatre catégories purgeables");
        Check.Throws<ArgumentException>(() => LocalStoreRules.PurgeTargets("receipts"), "aucune table pour une catégorie jamais purgée");

        var history = LocalStoreRules.PurgePlan(store, ["history"], 30, TestClock.Reference, TestClock.Paris);
        var older = LocalStoreRules.PurgePlan(store, ["history"], 730, TestClock.Reference, TestClock.Paris);
        Check.True(history.TotalRows >= older.TotalRows, "un âge plus court retire plus");
        Check.Equal(TestClock.Reference - TimeSpan.FromDays(30), history.HistoryCutoff, "date limite de l’historique");
        Check.False(history.Fingerprint == older.Fingerprint, "l’âge entre dans l’empreinte");
    }

    [Test]
    public static void Directory_mode_says_the_base_is_not_wired_yet()
    {
        var view = StorageViewBuilder.Unavailable(StoragePolicyRules.Default, false, 6, 32, TestClock.Paris);
        Check.False(view.Available, "aucune base en mode annuaire dans cette version");
        Check.Equal(StorageViewBuilder.DirectoryModeReason, view.UnavailableReason, "raison dite");
        Check.Equal(0, view.Backups.Length, "aucune sauvegarde inventée");
        Check.Equal(6, view.Retention.Length, "la conservation reste réglable");
        Check.True(view.Limits.Length > 0, "limites du moteur dites");

        var store = SimulatedStore();
        var built = StorageViewBuilder.Build(store, StoragePolicyRules.Default, false, 6, 32, TestClock.Reference, TestClock.Paris, store.PathLabel);
        Check.True(built.Available && built.Simulated, "base fictive");
        Check.Equal(store.Backups.Length, built.Backups.Length, "sauvegardes listées");
        Check.Equal(8, built.Purge.Length, "catégories de purge");
    }

    [Test]
    public static void Destinations_are_local_db_files_other_than_the_active_base()
    {
        const string Active = @"C:\Users\x\AppData\Local\Domenia\Data\Domenia.db";
        Check.Null(LocalStoreRules.DestinationProblem(@"D:\Domenia\Domenia.db", Active), "fichier local .db admis");
        Check.Contains("réseau", LocalStoreRules.DestinationProblem(@"\\serveur\partage\Domenia.db", Active), "partage refusé");
        Check.Contains("Chemin complet", LocalStoreRules.DestinationProblem(@"Domenia.db", Active), "chemin relatif refusé");
        Check.Contains("relatif", LocalStoreRules.DestinationProblem(@"D:\a\..\Domenia.db", Active), "remontée refusée");
        Check.Contains(".db", LocalStoreRules.DestinationProblem(@"D:\Domenia\copie.txt", Active), "extension exigée");
        Check.Contains("non admis", LocalStoreRules.DestinationProblem(@"D:\Domenia\co?pie.db", Active), "caractère interdit");
        Check.Contains("base active", LocalStoreRules.DestinationProblem(Active.ToUpperInvariant(), Active), "base active refusée");
        Check.Contains("base active", LocalStoreRules.DestinationProblem(Active + "-wal", Active), "journal refusé");
        Check.NotNull(LocalStoreRules.DestinationProblem("", Active), "destination vide");
    }

    [Test]
    public static void Storage_plans_are_bound_to_the_revision_of_the_base()
    {
        var store = SimulatedStore();
        Check.Equal(StorageWritePlans.StoreGuid(store.StoreId), StorageWritePlans.StoreGuid(store.StoreId), "GUID stable");
        Check.True(Guid.TryParse(StorageWritePlans.StoreGuid(store.StoreId), out _), "GUID valide");
        Check.Equal(StorageWritePlans.TargetKind, StorageWritePlans.Target(store).Kind, "cible : base locale");
        Check.Equal("Domenia-20261021-182600.db", StorageWritePlans.BackupFileName(TestClock.Reference, TestClock.Paris), "nom en heure locale");
        var draft = StorageWritePlans.BackupDraft(store, StoragePolicyRules.Default, "{}", TestClock.Reference, TestClock.Paris);
        Check.Equal(StorageWritePlans.Backup, draft.Kind, "type");
        Check.False(draft.Confirmation.TypedNameRequired, "sauvegarde : confirmation simple");
        var purge = LocalStoreRules.PurgePlan(store, ["observations"], 730, TestClock.Reference, TestClock.Paris);
        var purgeDraft = StorageWritePlans.PurgeDraft(store, purge, purge.Fingerprint, TestClock.Paris);
        Check.True(purgeDraft.Confirmation.TypedNameRequired, "purge : nom du domaine saisi");
        Check.Equal(store.Domain, purgeDraft.Confirmation.TypedName, "nom attendu : le domaine");
        var stale = Check.Throws<DomeniaOperationException>(() => StorageWritePlans.PurgeDraft(store, purge, new string('0', 64), TestClock.Paris), "empreinte périmée");
        Check.Equal(StorageWritePlans.PreviewStale, stale.Code, "code de prévisualisation périmée");
    }

    [Test]
    public static void Formats_are_french_and_unknown_stays_unknown()
    {
        Check.Equal("512" + Nbsp + "o", SettingsFormat.Size(512), "octets");
        Check.Equal("1,5" + Nbsp + "Ko", SettingsFormat.Size(1536), "une décimale");
        Check.Equal("2" + Nbsp + "Mo", SettingsFormat.Size(2L << 20), "entier sans décimale");
        Check.Equal("inconnu", SettingsFormat.Size(-1), "taille inconnue");
        Check.Equal("inconnu", SettingsFormat.Size((long?)null), "taille absente");
        Check.Equal("0" + Nbsp + "s (toujours relire)", SettingsFormat.Duration(0), "zéro");
        Check.Equal("1" + Nbsp + "h " + "30" + Nbsp + "min", SettingsFormat.Duration(5400), "heures et minutes");
        Check.Equal("2" + Nbsp + "j " + "4" + Nbsp + "h", SettingsFormat.Duration(187200), "jours et heures");
        Check.Equal("sans limite", SettingsFormat.Days(0), "0 jour");
        Check.Equal("1 jour", SettingsFormat.Days(1), "singulier");
        Check.Equal(new string('a', 64), SettingsFormat.Sha256Text(new string('A', 64)), "empreinte en minuscules");
        Check.Null(SettingsFormat.Sha256Text("abc"), "empreinte trop courte");
        Check.Equal("à une date future (horloge à vérifier)", SettingsFormat.Elapsed(TestClock.Reference + TimeSpan.FromHours(1), TestClock.Reference), "date future dite");
        Check.Equal("21/10/2026 18:26", SettingsFormat.LocalDate(TestClock.Reference, TestClock.Paris), "date locale");
    }

    // ---------- Configuration ----------

    [Test]
    public static void Configuration_is_bounded_and_a_bad_file_falls_back_to_defaults()
    {
        var absent = ConfigurationRules.Read(null, "Domenia.config.json");
        Check.Equal("absent", absent.FileState, "fichier absent");
        Check.Equal(0, absent.FromFile, "aucune valeur du fichier");
        Check.True(absent.Sections.SelectMany(s => s.Entries).All(e => e.Source == "default"), "tout par défaut");

        var bytes = Encoding.UTF8.GetBytes("\uFEFF" + """{"Auth":{"logintimeoutseconds":500,"AllowWindowsSession":false},"Inconnue":{},"GuiElementPolicy":{"Export":"Hidden","Copie":"Rouge"}}""");
        var report = ConfigurationRules.Read(bytes, "Domenia.config.json");
        Check.Equal("read", report.FileState, "fichier lu malgré le BOM");
        var timeout = report.Sections.SelectMany(s => s.Entries).Single(e => e.Key == "LoginTimeoutSeconds");
        Check.Equal("120", timeout.Value, "ramené au maximum");
        Check.Equal("clamped", timeout.Source, "provenance : bornée");
        Check.Equal("false", report.Sections.SelectMany(s => s.Entries).Single(e => e.Key == "AllowWindowsSession").Value, "booléen du fichier");
        Check.Equal(2, report.FromFile, "deux valeurs du fichier");
        Check.True(report.UnknownSections.SequenceEqual(["Inconnue"]), "section inconnue conservée et dite");
        Check.Equal(2, report.GuiPolicy.Length, "deux politiques d’interface");
        Check.True(report.GuiPolicy.Single(g => g.Element == "Export").Valid, "Hidden admis");
        Check.False(report.GuiPolicy.Single(g => g.Element == "Copie").Valid, "valeur inconnue signalée");
        Check.Equal(120, ConfigurationRules.Integer(report, "Auth", "LoginTimeoutSeconds", 30), "valeur effective lue par les autres écrans");

        var duplicate = ConfigurationRules.Read(Encoding.UTF8.GetBytes("""{"Auth":{"DemoProvider":true,"demoprovider":false}}"""), "x");
        Check.Equal("invalid", duplicate.FileState, "clé en double selon la casse");
        Check.True(duplicate.Sections.SelectMany(s => s.Entries).All(e => e.Source == "default"), "défauts appliqués à un fichier illisible");
        Check.Equal("invalid", ConfigurationRules.Read(Encoding.UTF8.GetBytes("{"), "x").FileState, "JSON illisible");
        Check.Contains("illisible", ConfigurationRules.Read(Encoding.UTF8.GetBytes("[]"), "x").Notes[0], "la note dit le repli");
    }

    // ---------- Preferences ----------

    [Test]
    public static void Preference_export_never_carries_the_connection_identity()
    {
        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            ["dashboard.disabledWidgets"] = Json("""["lockedAccounts"]"""),
            ["settings.collection"] = Json("""{"profile":"slowNetwork"}"""),
            ["settings.connection"] = Json("""{"rememberLogin":true,"lastLogin":"jdupont"}"""),
        };
        var export = PreferenceTransfer.Export(values, "simulation", TestClock.Reference);
        Check.Equal(2, export.Keys, "deux clés exportées");
        Check.True(export.Excluded.SequenceEqual(["settings.connection"]), "identité de connexion exclue");
        Check.False(export.Text.Contains("jdupont", StringComparison.Ordinal), "aucun identifiant dans le texte");
        Check.Contains(PreferenceTransfer.Format, export.Text, "format nommé");
        Check.Contains("2026-10-21T16:26:00Z", export.Text, "date d’export");
        Check.Equal(2, PreferenceTransfer.Owners(values).Length, "propriétaires : dashboard et settings");
    }

    [Test]
    public static void Preference_import_is_previewed_and_fingerprinted()
    {
        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            ["dashboard.disabledWidgets"] = Json("""["lockedAccounts"]"""),
            ["settings.collection"] = Json("""{"profile":"slowNetwork"}"""),
        };
        var text = PreferenceTransfer.Export(values, "directory", TestClock.Reference).Text;

        var fresh = PreferenceTransfer.Preview(text, _ => null);
        Check.True(fresh.Valid, "export valide");
        Check.Equal(2, fresh.Changes.Length, "deux ajouts");
        Check.True(fresh.Changes.All(c => c.Kind == "add"), "ajouts");
        Check.Equal(TestClock.Reference, fresh.ExportedAt, "date relue");
        Check.Equal(64, fresh.Fingerprint.Length, "empreinte");

        var same = PreferenceTransfer.Preview(text, k => values.TryGetValue(k, out var v) ? v : null);
        Check.Equal(0, same.Changes.Length, "rien ne change");
        Check.Equal(2, same.Unchanged, "deux valeurs identiques");
        Check.False(same.Fingerprint == fresh.Fingerprint, "l’état courant entre dans l’empreinte");
        Check.Equal(fresh.Fingerprint, PreferenceTransfer.Preview(text, _ => null).Fingerprint, "empreinte stable");

        var badProfile = """{"format":"domenia.preferencesExport","version":1,"values":{"dashboard.disabledWidgets":["lockedAccounts"],"settings.collection":{"profile":"turbo"}}}""";
        var refused = PreferenceTransfer.Preview(badProfile, _ => null);
        Check.Equal(1, refused.Changes.Length, "une valeur admise");
        Check.Contains("settings.collection", refused.Refused.Single(), "refus nommé");

        var connection = """{"format":"domenia.preferencesExport","version":1,"values":{"settings.connection":{"rememberLogin":true}}}""";
        Check.Contains("jamais importée", PreferenceTransfer.Preview(connection, _ => null).Refused.Single(), "identité de connexion jamais importée");
        var unknown = """{"format":"domenia.preferencesExport","version":1,"values":{"accounts.secretKey":"x","settings.window":{"x":0}}}""";
        var unknownPreview = PreferenceTransfer.Preview(unknown, _ => null);
        Check.Equal(0, unknownPreview.Changes.Length, "rien d’inconnu n’est admis");
        Check.Contains("clé inconnue", unknownPreview.Refused.First(r => r.StartsWith("accounts.", StringComparison.Ordinal)), "clé inconnue refusée par son nom");
        Check.Contains("fenêtre de ce poste", unknownPreview.Refused.First(r => r.StartsWith("settings.window", StringComparison.Ordinal)), "fenêtre jamais importée");
        Check.False(PreferenceTransfer.Preview("pas du JSON", _ => null).Valid, "texte illisible");
        Check.False(PreferenceTransfer.Preview("""{"format":"autre","version":1,"values":{}}""", _ => null).Valid, "autre format");
        Check.False(PreferenceTransfer.Preview("""{"format":"domenia.preferencesExport","version":9,"values":{}}""", _ => null).Valid, "version inconnue");
        Check.False(PreferenceTransfer.Preview("", _ => null).Valid, "texte vide");
        Check.True(PreferenceTransfer.Values(text, ["settings.collection"]).Select(v => v.Key).SequenceEqual(["settings.collection"]), "seules les clés admises sont appliquées");
    }

    [Test]
    public static void Preference_document_is_inspected_read_only()
    {
        Check.Equal("memory", PreferenceDocument.Inspect(null).State, "préférences en mémoire");
        using var folder = new TemporaryFolder();
        Check.Equal("absent", PreferenceDocument.Inspect(folder.File("preferences.json")).State, "fichier absent");
        File.WriteAllText(folder.File("preferences.json"), """{"format":"domenia.preferences","version":1,"values":{"settings.storage":{"presenceDays":10},"Bad":1}}""");
        var read = PreferenceDocument.Inspect(folder.File("preferences.json"));
        Check.Equal("read", read.State, "fichier lu");
        Check.True(read.Values.ContainsKey("settings.storage"), "clé valide");
        Check.False(read.Values.ContainsKey("Bad"), "clé mal formée écartée");
        Check.Equal("unknownFormat", PreferenceDocument.Parse(Encoding.UTF8.GetBytes("""{"format":"x"}"""), 14, null).State, "format inconnu");
        Check.Equal("unreadable", PreferenceDocument.Parse(Encoding.UTF8.GetBytes("{"), 1, null).State, "JSON illisible");
    }

    // ---------- About ----------

    [Test]
    public static void Compatibility_never_claims_more_than_observed()
    {
        var observed = new EnvironmentFacts("Client", 26100, "24H2", true, "10.0.0", "embarque", "154.0.3600.0", true, "3.43.2");
        var verdict = Compatibility.Verdict(Compatibility.Matrix, observed);
        Check.Equal(CompatibilityStatus.Expected, verdict.Overall, "prévu, jamais testé");
        Check.Equal(5, verdict.Rows.Length, "cinq dimensions relevées");
        Check.False(verdict.Rows.Any(r => r.Status is CompatibilityStatus.Tested or CompatibilityStatus.Qualified), "rien de testé ni de qualifié n’est revendiqué");
        Check.Equal(4, verdict.Documented.Length, "annuaire et CIM documentés à part");

        var unknown = Compatibility.Verdict(Compatibility.Matrix, new EnvironmentFacts(null, null, null, null, null, null, null, null, null));
        Check.Equal(CompatibilityStatus.Unknown, unknown.Overall, "rien relevé : inconnu");
        Check.True(unknown.Rows.All(r => r.Observed == "non relevé"), "chaque dimension dite non relevée");

        var x86 = Compatibility.Verdict(Compatibility.Matrix, observed with { Is64BitProcess = false });
        Check.Equal(CompatibilityStatus.Unsupported, x86.Overall, "processus 32 bits non pris en charge");
        Check.Contains("32 bits", x86.Text, "la raison est dite");
        var win10 = Compatibility.Verdict(Compatibility.Matrix, observed with { Build = 18363 });
        Check.Equal(CompatibilityStatus.Unsupported, win10.Overall, "Windows 10 avant 22H2");
    }

    [Test]
    public static void Component_versions_are_shown_only_when_bound_to_the_file()
    {
        var sha = new string('c', 64);
        var view = ComponentInventory.Build(
            [
                new ComponentFile("Domenia.exe", 1000, sha, "2.0.0.0", "2.0.0-dev+abcdef"),
                new ComponentFile("Domenia.Core.dll", 500, null, "2.0.0.0", "2.0.0"),
                new ComponentFile("Microsoft.Web.WebView2.Core.dll", 300, sha, null, null),
            ],
            [new ComponentFolder("web", 40, 2000, null)]);
        var exe = view.Rows.Single(r => r.Path == "Domenia.exe");
        Check.True(exe.Bound, "version liée à l’empreinte");
        Check.Equal("2.0.0-dev", exe.Version, "révision source retirée de l’affichage");
        var core = view.Rows.Single(r => r.Path == "Domenia.Core.dll");
        Check.False(core.Bound, "sans empreinte : pas de version");
        Check.Null(core.Version, "version masquée");
        Check.Null(view.Rows.Single(r => r.Path == "Microsoft.Web.WebView2.Core.dll").Version, "sans ressource de version : rien");
        Check.False(view.Rows.Single(r => r.Kind == "web").Bound, "dossier web : version non reliée");
        Check.Equal(3800L, view.TotalBytes, "total = somme des lignes");
        Check.Contains("1 avec une version liée", view.Summary, "résumé honnête");
    }

    [Test]
    public static void Data_policy_says_unknown_when_the_policy_is_unreadable()
    {
        var locations = new DataLocations("data", "prefs", "receipts", "logs", "profile", null, null, true, false);
        var known = DataPolicyRules.Build(StoragePolicyRules.Default, false, locations);
        Check.False(known.PolicyUnreadable, "politique lue");
        Check.False(known.Rows.Any(r => r.Retention.Contains("durée inconnue", StringComparison.Ordinal)), "durées connues");
        var unknown = DataPolicyRules.Build(StoragePolicyRules.Default, true, locations);
        Check.True(unknown.Rows.Any(r => r.Retention.Contains("durée inconnue", StringComparison.Ordinal)), "jamais un défaut présenté comme réglé");
        Check.Contains("aucune donnée hors de ce poste", unknown.Statement, "engagement de confidentialité");
    }

    [Test]
    public static void Section_scopes_follow_the_working_ou()
    {
        var sections = SettingsViewRules.Sections(new ScopeSelection("OU=Postes,DC=example,DC=local", "Postes", true));
        Check.True(sections.Length >= 3, "sections listées");
        Check.True(sections.All(s => s.Follows), "toutes suivent l’OU de travail");
        var connection = SettingsViewRules.ConnectionView(SettingsViewRules.DefaultConnection, simulated: true);
        Check.False(connection.Editable, "simulation : préférences de connexion en lecture seule");
        Check.NotNull(connection.Reason, "la raison est dite");
        var stored = SettingsViewRules.ReadConnection(JsonSerializer.SerializeToElement(new { rememberLogin = true, lastLogin = new string('x', SettingsViewRules.MaxLoginLength + 1) }));
        Check.True(stored.RememberLogin, "case lue");
        Check.Equal("", stored.LastLogin, "identifiant trop long écarté");
        var forgotten = SettingsViewRules.ReadConnection(SettingsViewRules.ToJson(new ConnectionPreferences(false, "jdupont", "", "")));
        Check.Equal("", forgotten.LastLogin, "case décochée : l’identifiant n’est pas gardé");
    }
}
