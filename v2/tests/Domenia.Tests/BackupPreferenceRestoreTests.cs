using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class BackupPreferenceRestoreTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static string Annex(int zoom) => BackupPreferencesRules.Snapshot(new Dictionary<string, JsonElement>
        { [PreferenceApproval.ZoomKey] = JsonSerializer.SerializeToElement(zoom) });

    [Test]
    public static async Task Actual_annex_keeps_all_three_board_histories_and_scopes_from_other_domains()
    {
        using var folder = new TemporaryFolder();
        using var preferences = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences);
        using var context = bridge.Context;
        var home = AccueilService.From(context);
        await home.SaveLayoutAsync([new("one", FleetWidgetSource.Builtin, "fleet.machines", "Kpi", "S", "Parc", false, "")], None);
        await home.SaveLayoutAsync([], None);
        foreach (var board in new[] { "Computer", "Software" })
        {
            await PosteBoardLayouts.SaveAsync(preferences, board, [], None, now: Fixtures.Now);
            await PosteBoardLayouts.SaveAsync(preferences, board, PosteBoardLayouts.Defaults(board), None, now: Fixtures.Now);
        }
        var foreign = WorkingScope.PreferenceKey("DC=other,DC=local");
        await preferences.SetAsync(foreign, JsonSerializer.SerializeToElement(new { dn = "OU=Work,DC=other,DC=local", subtree = true }), None);
        await preferences.SetAsync(SettingsViewRules.ConnectionKey, JsonSerializer.SerializeToElement(new { lastLogin = "local-only-identity" }), None);
        var raw = await SettingsAnnex.SnapshotAsync(context, None);
        var values = BackupPreferencesRules.ReadStrict(raw).ToDictionary(v => v.Key, v => v.Value);
        foreach (var key in new[] { AccueilService.LayoutPreference, "poste.computerLayout", "poste.softwareLayout" })
        {
            Check.True(preferences.TryGet(key, out var original), "disposition effectivement enregistrée");
            Check.Equal(JsonSerializer.Serialize(original), JsonSerializer.Serialize(values[key]), "choix et historique entiers dans l’annexe");
            Check.True(values[key].GetProperty("history").GetArrayLength() > 0, "historique réel inclus");
        }
        Check.True(values.ContainsKey(foreign), "OU d’un autre domaine conservée sans lecture AD");
        Check.False(raw.Contains("local-only-identity", StringComparison.Ordinal), "identité de connexion exclue");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture réseau");
    }

    [Test]
    public static async Task Native_restore_is_atomic_keeps_a_verified_previous_copy_and_preserves_local_identity()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        await store.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), None);
        await store.SetAsync(SettingsViewRules.ConnectionKey, JsonSerializer.SerializeToElement(new { lastLogin = "local" }), None);
        var current = await store.ReadConfigurationAsync(None); var bytes = File.ReadAllBytes(path);
        using (var blocked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var failure = await Check.ThrowsAsync<Exception>(() => store.ApplyBackupPreferencesAsync(Annex(125), current.Fingerprint, None), "remplacement refusé par le vrai fichier Windows");
            Check.True(failure is IOException or UnauthorizedAccessException, "échec physique attendu");
        }
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(path)), "original conservé après refus");
        Check.True(store.TryGet(PreferenceApproval.ZoomKey, out var unchanged) && unchanged.GetInt32() == 100, "aucun choix optimiste en mémoire");
        Check.Equal(0, Directory.GetFiles(folder.Path, "*.tmp").Length, "temporaire nettoyé");
        var backups = Directory.GetFiles(folder.Path, "*.before-restore-*.bak");
        Check.Equal(1, backups.Length, "copie préalable conservée même après refus");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(backups[0])), "copie exacte de tout le document précédent");
        await store.ApplyBackupPreferencesAsync(Annex(125), current.Fingerprint, None);
        using var reopened = new FilePreferenceStore(path, new RecordingJournal());
        Check.True(reopened.TryGet(PreferenceApproval.ZoomKey, out var restored) && restored.GetInt32() == 125, "restauration durable entière");
        Check.True(reopened.TryGet(SettingsViewRules.ConnectionKey, out var identity) && identity.GetProperty("lastLogin").GetString() == "local", "identité locale conservée");
        await Check.ThrowsAsync<InvalidDataException>(() => store.ApplyBackupPreferencesAsync(Annex(140), current.Fingerprint, None), "ancienne empreinte refusée sans écrasement");
    }

    [Test]
    public static async Task Annex_larger_than_the_local_profile_is_refused_without_truncation_or_partial_restore()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        await store.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), None);
        var current = await store.ReadConfigurationAsync(None); var before = File.ReadAllBytes(path);
        var large = BackupPreferencesRules.Snapshot(Enumerable.Range(0, 500).ToDictionary(
            n => WorkingScope.PreferenceKey($"DC=domain{n},DC=local"),
            n => JsonSerializer.SerializeToElement(new { dn = "OU=" + new string('a', 2200) + $",DC=domain{n},DC=local", subtree = true })));
        Check.True(System.Text.Encoding.UTF8.GetByteCount(large) > FilePreferenceStore.MaxBytes, "annexe valide dépassant réellement le profil local");
        Check.Equal(500, BackupPreferencesRules.ReadStrict(large).Length, "l’archive garde toutes ses valeurs valides");
        await Check.ThrowsAsync<InvalidDataException>(() => store.ApplyBackupPreferencesAsync(large, current.Fingerprint, None), "aucune troncature au plafond local");
        Check.True(before.SequenceEqual(File.ReadAllBytes(path)), "profil antérieur intact");
        Check.True(store.TryGet(PreferenceApproval.ZoomKey, out var zoom) && zoom.GetInt32() == 100, "mémoire antérieure intacte");
        Check.Equal(0, Directory.GetFiles(folder.Path, "*.bak").Length, "refus avant toute création de sauvegarde inutile");
    }

    [Test]
    public static void Annex_boundaries_and_invalid_layouts_are_refused_before_any_partial_application()
    {
        Check.Equal(4_194_304, BackupPreferencesRules.MaxBytes, "borne de quatre Mio explicite");
        Check.Throws<InvalidDataException>(() => BackupPreferencesRules.ReadStrict(new string(' ', BackupPreferencesRules.MaxBytes + 1)), "octets bornés avant parsing");
        Check.Throws<JsonException>(() => BackupPreferencesRules.ReadStrict(new string('[', BackupPreferencesRules.MaxDepth + 1) + "0" + new string(']', BackupPreferencesRules.MaxDepth + 1)), "profondeur bornée");
        Check.Throws<InvalidDataException>(() => BackupPreferencesRules.ReadStrict("{\"settings.zoom\":100,\"settings.zoom\":125}"), "clé dupliquée jamais choisie arbitrairement");
        var key = WorkingScope.PreferenceKey(Fixtures.Root);
        Check.Throws<InvalidDataException>(() => BackupPreferencesRules.ReadStrict("{\"" + key + "\":{\"dn\":\"" + Fixtures.Root + "\",\"dn\":\"" + Fixtures.Postes + "\"}}"), "champ imbriqué dupliqué refusé aussi");
        Check.Throws<InvalidDataException>(() => BackupPreferencesRules.ReadStrict("{\"accueil.layout\":{\"version\":999,\"items\":[]},\"settings.zoom\":125}"), "disposition future empêche la réapplication partielle");
        Check.Throws<JsonException>(() => BackupPreferencesRules.Bind("pas du JSON", "", Fixtures.Now), "document invalide jamais remplacé silencieusement par une annexe vide");
    }
}
