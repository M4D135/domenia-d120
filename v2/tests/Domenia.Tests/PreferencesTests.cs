using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PreferencesTests
{
    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }

    [Test]
    public static void One_document_per_mode()
    {
        Check.Equal("preferences.json", FilePreferenceStore.FileNameFor(AppMode.Directory), "mode annuaire");
        Check.Equal("preferences-simulation.json", FilePreferenceStore.FileNameFor(AppMode.Simulation), "simulation séparée");
        Check.Throws<ArgumentException>(() => new FilePreferenceStore("preferences.json", new RecordingJournal()), "chemin relatif refusé");
    }

    [Test]
    public static void Keys_are_dotted_names()
    {
        Check.True(PreferenceKeys.IsValid("dashboard.disabledWidgets"), "clé valide");
        Check.True(PreferenceKeys.IsValid(WorkingScope.PreferenceKey("DC=example,DC=local")), "clé de l’OU de travail valide");
        Check.False(PreferenceKeys.IsValid("dashboard"), "un seul segment");
        Check.False(PreferenceKeys.IsValid("Dashboard.x"), "majuscule initiale");
        Check.False(PreferenceKeys.IsValid("dashboard..x"), "segment vide");
        Check.False(PreferenceKeys.IsValid("dashboard.x-y"), "tiret");
        Check.False(PreferenceKeys.IsValid(".x"), "premier segment vide");
        Check.False(PreferenceKeys.IsValid("."), "deux segments vides");
        Check.False(PreferenceKeys.IsValid("x."), "dernier segment vide");
        Check.False(PreferenceKeys.IsValid("a." + new string('x', PreferenceKeys.MaxLength)), "trop longue");
        Check.Throws<ArgumentException>(() => new MemoryPreferenceStore().TryGet("x", out _), "clé invalide refusée");
    }

    [Test]
    public static async Task Absent_document_then_atomic_write_and_read_back()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences-simulation.json");
        var journal = new RecordingJournal();
        using (var store = new FilePreferenceStore(path, journal))
        {
            Check.False(store.TryGet("dashboard.disabledWidgets", out _), "document absent : aucune valeur");
            Check.False(File.Exists(path), "lire ne crée rien");
            await store.SetAsync("dashboard.disabledWidgets", Json("""["lockedAccounts"]"""), CancellationToken.None);
            await store.SetAsync("session.workingScope.abc", Json("""{"dn":"OU=Paris,OU=Postes,DC=example,DC=local","subtree":false}"""), CancellationToken.None);
        }
        Check.True(File.Exists(path), "document écrit");
        Check.False(Directory.EnumerateFiles(folder.Path, "*.tmp").Any(), "aucun fichier temporaire laissé");
        using var written = JsonDocument.Parse(await File.ReadAllBytesAsync(path));
        Check.Equal("domenia.preferences", written.RootElement.GetProperty("format").GetString(), "format");
        Check.Equal(1, written.RootElement.GetProperty("version").GetInt32(), "version");
        string[] keys = [.. written.RootElement.GetProperty("values").EnumerateObject().Select(p => p.Name)];
        Check.True(keys.SequenceEqual(["dashboard.disabledWidgets", "session.workingScope.abc"]), "clés triées : " + string.Join(", ", keys));
        using var again = new FilePreferenceStore(path, journal);
        Check.True(again.TryGet("dashboard.disabledWidgets", out var widgets), "relu par une nouvelle instance");
        Check.Equal("lockedAccounts", widgets[0].GetString(), "valeur relue");
        await again.SetAsync("dashboard.disabledWidgets", null, CancellationToken.None);
        using var third = new FilePreferenceStore(path, journal);
        Check.False(third.TryGet("dashboard.disabledWidgets", out _), "valeur retirée");
        Check.True(third.TryGet("session.workingScope.abc", out _), "les autres valeurs restent");
    }

    [Test]
    public static async Task Unknown_keys_written_by_another_screen_are_kept()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        await File.WriteAllTextAsync(path, """{"format":"domenia.preferences","version":1,"values":{"futur.reglage":{"a":1},"bad key":2}}""");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        {
            await store.SetAsync("dashboard.disabledWidgets", Json("[]"), CancellationToken.None);
        }
        var text = await File.ReadAllTextAsync(path);
        Check.Contains("futur.reglage", text, "clé d’un autre écran conservée");
        Check.False(text.Contains("bad key", StringComparison.Ordinal), "clé mal formée écartée");
    }

    [Test]
    public static async Task Keys_with_an_empty_segment_in_the_document_are_ignored_without_failing()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        await File.WriteAllTextAsync(path, """{"format":"domenia.preferences","version":1,"values":{".x":1,".":3,"a.b":2}}""");
        var journal = new RecordingJournal();
        using var store = new FilePreferenceStore(path, journal);
        Check.True(store.TryGet("a.b", out var value) && value.GetInt32() == 2, "clé valide lue malgré « .x » et « . »");
        await store.SetAsync("dashboard.disabledWidgets", Json("[]"), CancellationToken.None);
        var text = await File.ReadAllTextAsync(path);
        Check.False(text.Contains("\".x\"", StringComparison.Ordinal), "clé à segment vide écartée");
        Check.Contains("\"a.b\"", text, "clé valide conservée");
        Check.False(File.Exists(path + ".illisible"), "document lisible : rien mis de côté");
    }

    [Test]
    public static async Task Document_locked_for_a_moment_is_read_again_and_never_replaced_unread()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        var original = """{"format":"domenia.preferences","version":1,"values":{"dashboard.disabledWidgets":["diskAlerts"],"session.workingScope.abc":{"dn":"OU=Paris,DC=example,DC=local","subtree":true}}}""";
        await File.WriteAllTextAsync(path, original);
        var journal = new RecordingJournal();
        using var store = new FilePreferenceStore(path, journal);
        using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            // An antivirus or a backup holds the file: defaults for now, never an exception.
            Check.False(store.TryGet("dashboard.disabledWidgets", out _), "document verrouillé : valeur par défaut pour l’instant");
            Check.True(journal.Lines.Any(l => l.StartsWith("ATTENTION Préférences preferences.json non lues", StringComparison.Ordinal)), "lecture impossible tracée");
            _ = await Check.ThrowsAsync<IOException>(() => store.SetAsync("session.workingScope.def", Json("""{"dn":"OU=Lyon,DC=other,DC=local","subtree":false}"""), CancellationToken.None), "écriture refusée tant que le document n’a pas été relu");
            Check.True(store.TryGet("session.workingScope.def", out _), "le choix vaut pour la session");
        }
        Check.Equal(original, await File.ReadAllTextAsync(path), "document d’origine intact");
        Check.True(store.TryGet("dashboard.disabledWidgets", out var widgets) && widgets[0].GetString() == "diskAlerts", "relu une fois libéré");
        await store.SetAsync("dashboard.refresh", Json("1"), CancellationToken.None);
        using var reread = new FilePreferenceStore(path, journal);
        Check.True(reread.TryGet("dashboard.disabledWidgets", out _), "valeur d’origine conservée");
        Check.True(reread.TryGet("session.workingScope.abc", out _), "OU d’origine conservée");
        Check.True(reread.TryGet("session.workingScope.def", out _), "changement en attente écrit avec le suivant");
        Check.True(reread.TryGet("dashboard.refresh", out _), "nouvelle valeur écrite");
        Check.False(File.Exists(path + ".illisible"), "document lisible : rien mis de côté");
    }

    [Test]
    public static async Task Two_instances_never_erase_each_other()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        var journal = new RecordingJournal();
        using var first = new FilePreferenceStore(path, journal);
        using var second = new FilePreferenceStore(path, journal);
        // Both read the (absent) document before either writes.
        Check.False(first.TryGet("session.workingScope.abc", out _), "première instance : rien");
        Check.False(second.TryGet("dashboard.disabledWidgets", out _), "seconde instance : rien");
        await first.SetAsync("session.workingScope.abc", Json("""{"dn":"OU=Paris,DC=example,DC=local","subtree":true}"""), CancellationToken.None);
        await second.SetAsync("dashboard.disabledWidgets", Json("""["lockedAccounts"]"""), CancellationToken.None);
        await first.SetAsync("dashboard.refresh", Json("2"), CancellationToken.None);
        using var third = new FilePreferenceStore(path, journal);
        Check.True(third.TryGet("session.workingScope.abc", out _), "OU de la première instance conservée");
        Check.True(third.TryGet("dashboard.disabledWidgets", out _), "widgets de la seconde instance conservés");
        Check.True(third.TryGet("dashboard.refresh", out _), "dernière valeur de la première instance");
        Check.Equal(FilePreferenceStore.LockNameFor(path), FilePreferenceStore.LockNameFor(path.ToUpperInvariant()), "même verrou quelle que soit la casse");
        Check.False(FilePreferenceStore.LockNameFor(path).Contains("preferences.json", StringComparison.OrdinalIgnoreCase) || FilePreferenceStore.LockNameFor(path).Contains(Path.GetDirectoryName(path)!, StringComparison.OrdinalIgnoreCase), "nom du verrou sans chemin");
    }

    [Test]
    public static async Task Unreadable_document_never_blocks_and_is_kept_aside_once()
    {
        foreach (var content in new[] { "{pas du json", "[]", """{"format":"autre","version":1,"values":{}}""", """{"format":"domenia.preferences","version":2,"values":{}}""" })
        {
            using var folder = new TemporaryFolder();
            var path = folder.File("preferences.json");
            await File.WriteAllTextAsync(path, content);
            var journal = new RecordingJournal();
            using var store = new FilePreferenceStore(path, journal);
            Check.False(store.TryGet("dashboard.disabledWidgets", out _), "valeurs par défaut : " + content);
            Check.True(journal.Lines.Any(l => l.StartsWith("ATTENTION Préférences preferences.json illisibles", StringComparison.Ordinal)), "illisible tracé");
            Check.False(journal.Lines.Any(l => l.Contains(content, StringComparison.Ordinal)), "contenu jamais recopié");
            await store.SetAsync("dashboard.disabledWidgets", Json("[]"), CancellationToken.None);
            Check.Equal(content, await File.ReadAllTextAsync(path + ".illisible"), "ancien document mis de côté");
            using var reread = JsonDocument.Parse(await File.ReadAllBytesAsync(path));
            Check.Equal("domenia.preferences", reread.RootElement.GetProperty("format").GetString(), "nouveau document lisible");
        }
    }

    [Test]
    public static async Task Oversized_document_is_not_read()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        await File.WriteAllTextAsync(path, "{\"format\":\"domenia.preferences\",\"version\":1,\"values\":{\"a.b\":\"" + new string('x', FilePreferenceStore.MaxBytes) + "\"}}");
        var journal = new RecordingJournal();
        using var store = new FilePreferenceStore(path, journal);
        Check.False(store.TryGet("a.b", out _), "document trop grand ignoré");
        Check.True(journal.Lines.Any(l => l.Contains("plus de 1 Mo", StringComparison.Ordinal)), "taille tracée");
    }

    [Test]
    public static async Task Failed_write_keeps_the_value_for_the_session_and_raises_an_io_error()
    {
        using var folder = new TemporaryFolder();
        // A folder where the document should be: the final replacement cannot happen.
        var path = folder.File("preferences.json");
        Directory.CreateDirectory(path);
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        var failure = await Check.ThrowsAsync<Exception>(() => store.SetAsync("dashboard.disabledWidgets", Json("""["diskAlerts"]"""), CancellationToken.None), "écriture refusée");
        Check.True(failure is IOException or UnauthorizedAccessException, "erreur d’entrée-sortie : " + failure.GetType().Name);
        Check.True(store.TryGet("dashboard.disabledWidgets", out var kept), "valeur gardée pour la session");
        Check.Equal("diskAlerts", kept[0].GetString(), "valeur en mémoire");
        Check.False(Directory.EnumerateFiles(folder.Path, "*.tmp").Any(), "fichier temporaire retiré");
    }

    [Test]
    public static async Task Disabled_widgets_are_remembered_and_restored_at_the_next_start()
    {
        var preferences = new MemoryPreferenceStore();
        var first = new SimulatedBridge(preferences: preferences);
        _ = SimulatedBridge.Json(await first.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"lockedAccounts\",\"enabled\":false}"));
        _ = SimulatedBridge.Json(await first.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"diskAlerts\",\"enabled\":false}"));
        Check.True(preferences.TryGet(DashboardService.DisabledWidgetsPreference, out var stored), "état mémorisé");
        string[] ids = [.. stored.EnumerateArray().Select(e => e.GetString()!)];
        Check.True(ids.SequenceEqual(["lockedAccounts", "diskAlerts"]), "ordre du catalogue : " + string.Join(", ", ids));
        var writes = preferences.Writes;
        _ = SimulatedBridge.Json(await first.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"diskAlerts\",\"enabled\":false}"));
        Check.Equal(writes, preferences.Writes, "même état redemandé : aucune écriture");

        // Next start: same preferences, new engine.
        var second = new SimulatedBridge(preferences: preferences);
        var summary = SimulatedBridge.Json(await second.CallAsync("dashboard.summary"));
        var widgets = summary.GetProperty("widgets");
        Check.False(widgets.GetProperty("lockedAccounts").GetProperty("enabled").GetBoolean(), "verrouillés restent désactivés");
        Check.Equal(JsonValueKind.Null, widgets.GetProperty("diskAlerts").GetProperty("data").ValueKind, "disques restent sans mesure");
        Check.True(widgets.GetProperty("activeAccounts").GetProperty("enabled").GetBoolean(), "les autres restent actifs");
        Check.Equal("widget.disabled", (await second.CallAsync("dashboard.widget.refresh", "{\"id\":\"lockedAccounts\"}")).Error!.Code, "actualisation refusée dès le démarrage");

        _ = SimulatedBridge.Json(await second.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"lockedAccounts\",\"enabled\":true}"));
        Check.True(preferences.TryGet(DashboardService.DisabledWidgetsPreference, out stored), "état toujours mémorisé");
        Check.True(stored.EnumerateArray().Select(e => e.GetString()!).SequenceEqual(["diskAlerts"]), "réactivation mémorisée");
    }

    [Test]
    public static async Task Remembered_state_with_unknown_widgets_or_a_bad_shape_is_tolerated()
    {
        var preferences = new MemoryPreferenceStore();
        await preferences.SetAsync(DashboardService.DisabledWidgetsPreference, Json("""["watchlist", "inexistant", 3]"""), CancellationToken.None);
        var bridge = new SimulatedBridge(preferences: preferences);
        var widgets = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary")).GetProperty("widgets");
        Check.False(widgets.GetProperty("watchlist").GetProperty("enabled").GetBoolean(), "widget connu restauré");
        Check.Equal(10, widgets.EnumerateObject().Count(), "les inconnus sont ignorés");

        var bad = new MemoryPreferenceStore();
        await bad.SetAsync(DashboardService.DisabledWidgetsPreference, Json("""{"watchlist":true}"""), CancellationToken.None);
        var tolerant = new SimulatedBridge(preferences: bad);
        var all = SimulatedBridge.Json(await tolerant.CallAsync("dashboard.summary")).GetProperty("widgets");
        Check.True(all.EnumerateObject().All(w => w.Value.GetProperty("enabled").GetBoolean()), "forme illisible : tous actifs");
        Check.True(tolerant.Log.Lines.Any(l => l.Contains("dashboard.disabledWidgets illisible", StringComparison.Ordinal)), "forme illisible tracée");
    }

    [Test]
    public static async Task Preferences_that_cannot_be_written_never_fail_the_operation()
    {
        var bridge = new SimulatedBridge(preferences: new FailingPreferenceStore());
        var off = await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"lockedAccounts\",\"enabled\":false}");
        Check.Equal("result", off.Kind, "le choix vaut pour la session");
        var summary = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        var rows = summary.GetProperty("widgets").GetProperty("recentOperations").GetProperty("data").GetProperty("rows");
        Check.True(rows.EnumerateArray().Any(r => r.GetProperty("label").GetString()!.StartsWith("Préférences non enregistrées", StringComparison.Ordinal)
            && r.GetProperty("tone").GetString() == "warn"), "l’opérateur est prévenu dans le journal");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("IOException", StringComparison.Ordinal)), "type de l’erreur tracé");
    }

    [Test]
    public static async Task Memory_store_reads_and_writes_nothing_on_disk()
    {
        var store = new MemoryPreferenceStore();
        Check.False(store.Persistent, "mémoire seulement");
        await store.SetAsync("a.b", Json("1"), CancellationToken.None);
        Check.True(store.TryGet("a.b", out var value) && value.GetInt32() == 1, "valeur gardée");
        await store.SetAsync("a.b", null, CancellationToken.None);
        Check.False(store.TryGet("a.b", out _), "valeur retirée");
    }
}
