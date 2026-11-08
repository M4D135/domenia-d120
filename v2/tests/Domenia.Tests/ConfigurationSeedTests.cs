using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class ConfigurationSeedTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static PortableConfigurationDocument Document(int zoom = 125, bool ui = false) => PortableConfiguration.Read(PortableConfiguration.Export(
        new Dictionary<string, JsonElement> { [PreferenceApproval.ZoomKey] = JsonSerializer.SerializeToElement(zoom) }, [PreferenceApproval.ZoomKey],
        ui ? JsonSerializer.SerializeToElement(new { theme = "dark", logSize = 14 }) : null, "Annuaire", TestClock.Reference).Text);
    private static ConfigurationSeedCoordinator Coordinator(IConfigurationPreferenceStore store, string source, string build = "build-A") =>
        new(AppMode.Directory, true, store, build, TestClock.Fixed(), token =>
        {
            var file = PortableConfigurationFile.Read(source, token);
            return file is null ? null : new(file.Document, file.FileSha256);
        }, (seed, token) => PortableConfigurationFile.Hold(source, seed.FileSha256, token));

    [Test]
    public static async Task Virgin_profile_applies_once_before_any_UI_write_and_never_reads_source_in_simulation()
    {
        using var folder = new TemporaryFolder(); var source = folder.File(PortableConfiguration.FileName); File.WriteAllText(source, Document().Text);
        using var preferences = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var coordinator = Coordinator(preferences, source);
        var first = await coordinator.ExamineAsync(true, None);
        Check.True(first.AutomaticallyApplied, "profil réellement absent initialisé");
        Check.True(preferences.TryGet(PreferenceApproval.ZoomKey, out var value), "réglage moteur présent avant UI");
        Check.Equal(125, value.GetInt32(), "valeur livrée exacte");
        var bytes = File.ReadAllBytes(folder.File("preferences.json"));
        Check.False((await coordinator.ExamineAsync(true, None)).NeedsDecision, "preuve de cette version et empreinte conservée");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(folder.File("preferences.json"))), "second lancement sans nouvelle écriture");
        var reads = 0;
        var simulation = new ConfigurationSeedCoordinator(AppMode.Simulation, true, new MemoryPreferenceStore(), "build", TestClock.Fixed(),
            _ => { reads++; throw new TestFailureException("Acquisition réelle en simulation"); }, (_, _) => throw new TestFailureException("Verrou réel en simulation"));
        Check.False((await simulation.ExamineAsync(true, None)).Available, "simulation sans seed réel");
        await Check.ThrowsAsync<InvalidDataException>(() => simulation.DecideAsync("id", "sha", "fingerprint", true, None), "appel direct refusé avant source");
        Check.Equal(0, reads, "zéro accès au fichier");
    }

    [Test]
    public static async Task Existing_web_profile_prevents_automatic_replacement_even_without_engine_preferences()
    {
        var store = new MemoryPreferenceStore(); var document = Document(ui: true);
        var coordinator = new ConfigurationSeedCoordinator(AppMode.Directory, true, store, "build", TestClock.Fixed(),
            _ => new(document, document.Sha256), (_, _) => throw new TestFailureException("Aucun commit automatique attendu."), () => false);
        var result = await coordinator.ExamineAsync(true, None);
        Check.True(result.NeedsDecision && !result.AutomaticallyApplied, "choix du profil web existant proposés au lieu d’être écrasés");
        Check.Equal(0, store.Writes, "aucune écriture en attendant une décision");
    }

    [Test]
    public static async Task Existing_profile_requires_confirmation_decline_is_per_build_and_exact_seed_then_new_seed_proposes_again()
    {
        using var folder = new TemporaryFolder(); var source = folder.File(PortableConfiguration.FileName); File.WriteAllText(source, Document().Text);
        using var preferences = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        await preferences.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), None);
        var coordinator = Coordinator(preferences, source);
        var proposal = await coordinator.ExamineAsync(true, None);
        Check.True(proposal.NeedsDecision && !proposal.AutomaticallyApplied, "pas d’écrasement d’un profil existant");
        var refusal = await coordinator.DecideAsync(proposal.DecisionId!, proposal.SourceSha256!, proposal.Fingerprint!, false, None);
        Check.False(refusal.Applied, "refus effectif");
        Check.True(preferences.TryGet(PreferenceApproval.ZoomKey, out var value) && value.GetInt32() == 100, "choix conservé");
        Check.False((await coordinator.ExamineAsync(true, None)).NeedsDecision, "pas de proposition infinie pour même build et SHA");
        Check.True((await Coordinator(preferences, source, "build-B").ExamineAsync(true, None)).NeedsDecision, "nouvelle version propose à nouveau");
        File.WriteAllText(source, Document(130).Text);
        Check.True((await coordinator.ExamineAsync(true, None)).NeedsDecision, "nouvel exact fichier propose à nouveau");
    }

    [Test]
    public static async Task Accepted_replacement_keeps_exact_verified_backup_and_unrelated_future_identity_and_UI_fields()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        await preferences.SetAsync("future.key", JsonSerializer.SerializeToElement(new { original = new[] { 1, 2 } }), None);
        await preferences.SetAsync(SettingsViewRules.ConnectionKey, JsonSerializer.SerializeToElement(new { login = "local-only" }), None);
        await preferences.SetAsync(ShellInterfaceRules.InterfaceKey, JsonSerializer.SerializeToElement(new { future = "kept", density = "compact" }), None);
        var original = File.ReadAllBytes(path);
        var snapshot = await preferences.ReadConfigurationAsync(None);
        var applied = await preferences.CommitConfigurationAsync(new(Document(ui: true), snapshot.Fingerprint, TestClock.Reference), None);
        Check.True(applied.Applied && applied.Backup is not null, "sauvegarde réelle avant remplacement");
        var copied = File.ReadAllBytes(folder.File(applied.Backup!));
        Check.True(original.SequenceEqual(copied), "octets originaux exacts conservés");
        Check.Equal(Convert.ToHexStringLower(SHA256.HashData(copied)), applied.BackupSha256, "SHA de sauvegarde vérifié");
        var actual = await preferences.ReadConfigurationAsync(None);
        Check.Equal("local-only", actual.Values[SettingsViewRules.ConnectionKey].GetProperty("login").GetString(), "identité locale préservée");
        Check.Equal(snapshot.Values["future.key"].GetRawText(), actual.Values["future.key"].GetRawText(), "données futures intactes");
        Check.Equal("kept", actual.Values[ShellInterfaceRules.InterfaceKey].GetProperty("future").GetString(), "interface future conservée");
        Check.Equal("compact", actual.Values[ShellInterfaceRules.InterfaceKey].GetProperty("density").GetString(), "champ UI non choisi conservé");
        Check.Equal("dark", actual.Values[ShellInterfaceRules.InterfaceKey].GetProperty("theme").GetString(), "vraie interface moteur patchée");
    }

    [Test]
    public static async Task Concurrent_choice_replaced_seed_and_future_preferences_refuse_without_backups_or_partial_changes()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json"); var source = folder.File(PortableConfiguration.FileName);
        File.WriteAllText(source, Document().Text);
        using var a = new FilePreferenceStore(path, new RecordingJournal()); using var b = new FilePreferenceStore(path, new RecordingJournal());
        await a.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), None);
        var proposal = await Coordinator(a, source).ExamineAsync(true, None);
        await b.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(110), None);
        var before = File.ReadAllBytes(path);
        await Check.ThrowsAsync<InvalidDataException>(() => Coordinator(a, source).DecideAsync(proposal.DecisionId!, proposal.SourceSha256!, proposal.Fingerprint!, true, None), "choix concurrent refusé");
        Check.True(before.SequenceEqual(File.ReadAllBytes(path)), "original concurrent intact");
        Check.Equal(0, Directory.GetFiles(folder.Path, "preferences.before-configuration-*.json").Length, "aucun faux backup d’un commit refusé");
        proposal = await Coordinator(a, source).ExamineAsync(false, None);
        File.WriteAllText(source, Document(130).Text);
        await Check.ThrowsAsync<InvalidDataException>(() => Coordinator(a, source).DecideAsync(proposal.DecisionId!, proposal.SourceSha256!, proposal.Fingerprint!, true, None), "seed remplacé refusé");
        Check.True(before.SequenceEqual(File.ReadAllBytes(path)), "aucune décision écrite pour une mauvaise source");
        File.WriteAllText(path, "{\"format\":\"domenia.preferences\",\"version\":1,\"values\":{},\"future\":true}");
        await Check.ThrowsAsync<InvalidDataException>(() => a.ReadConfigurationAsync(None), "document futur ne devient jamais profil vierge");
        Check.Contains("future", File.ReadAllText(path), "champ futur conservé");
    }

    [Test]
    public static async Task Late_source_mutation_under_commit_lock_and_failed_replacement_leave_previous_document_intact()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json"); var source = folder.File(PortableConfiguration.FileName);
        File.WriteAllText(source, Document().Text);
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        await preferences.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), None);
        var snapshot = await preferences.ReadConfigurationAsync(None); var original = File.ReadAllBytes(path);
        var parsed = PortableConfigurationFile.Read(source, None)!;
        await Check.ThrowsAsync<InvalidDataException>(() => preferences.CommitConfigurationAsync(new(parsed.Document, snapshot.Fingerprint, TestClock.Reference), None, token =>
        { File.WriteAllText(source, Document(135).Text); return PortableConfigurationFile.Hold(source, parsed.FileSha256, token); }), "source requalifiée après mutex destination");
        Check.True(original.SequenceEqual(File.ReadAllBytes(path)), "aucune écriture tardive");
        using (var blocked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var failure = await Check.ThrowsAsync<Exception>(() => preferences.CommitConfigurationAsync(new(Document(), snapshot.Fingerprint, TestClock.Reference), None), "échec de remplacement physique");
            Check.True(failure is IOException or UnauthorizedAccessException,
                "refus disque Windows de partage ou d’accès ; aucune autre erreur ne remplace la tentative physique");
        }
        Check.True(original.SequenceEqual(File.ReadAllBytes(path)), "ancien document et mémoire après échec disque");
        Check.Equal(0, Directory.GetFiles(folder.Path, "*.tmp").Length, "aucun temporaire de remplacement abandonné après refus disque");
        Check.True(preferences.TryGet(PreferenceApproval.ZoomKey, out var zoom) && zoom.GetInt32() == 100, "pas de mémoire optimiste");
        Check.Equal(1, Directory.GetFiles(folder.Path, "preferences.before-configuration-*.json").Length, "backup de tentative conservé");
    }

    [Test]
    public static async Task Real_simulated_manual_handlers_apply_atomically_and_offer_full_allowlist_with_explicit_OU()
    {
        var preferences = new MemoryPreferenceStore(); var bridge = new SimulatedBridge(preferences: preferences);
        var scope = WorkingScope.PreferencePrefix + new string('a', 64);
        await preferences.SetAsync(scope, JsonSerializer.SerializeToElement(new { dn = "OU=Equipe,DC=example,DC=invalid", subtree = true }), None);
        var options = SimulatedBridge.Json(await bridge.CallAsync("settings.configuration.options"));
        var choice = options.GetProperty("choices").EnumerateArray().Single(v => v.GetProperty("key").GetString() == scope);
        Check.False(choice.GetProperty("selected").GetBoolean(), "OU jamais cochée implicitement");
        Check.Equal(5, options.GetProperty("choices").GetArrayLength(), "toute allowlist avec défauts réels proposée");
        var text = Document(ui: true).Text;
        var preview = SimulatedBridge.Json(await bridge.CallAsync("settings.configuration.preview", JsonSerializer.Serialize(new { text })));
        var applied = SimulatedBridge.Json(await bridge.CallAsync("settings.configuration.apply", JsonSerializer.Serialize(new { text, fingerprint = preview.GetProperty("fingerprint").GetString() })));
        Check.True(applied.GetProperty("applied").GetBoolean(), "vrai moteur de simulation appliqué");
        Check.True(preferences.TryGet(PreferenceApproval.ZoomKey, out var zoom) && zoom.GetInt32() == 125, "valeur observable par le consommateur");
        Check.True(preferences.TryGet(scope, out _), "OU non choisie dans l’import reste intacte");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune mutation AD ni collecte implicite");
    }
}
