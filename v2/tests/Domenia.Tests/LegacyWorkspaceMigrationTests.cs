using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacyWorkspaceMigrationTests
{
    private static readonly DomainIdentity Domain = new("test.local", "TEST", Fixtures.Root);
    private static string Key => "search.workspaces." + SearchMemoryRules.DomainKey(Fixtures.Root);
    private static SearchWorkspaceDraft Draft(string name) => new(name, Fixtures.Postes, true, SearchTypeFilter.Computers, "all", "", 200, "computers", null);
    private static SearchMemory Memory(IPreferenceStore prefs) => new(prefs, new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
    private static JsonElement D1(string id, string domain = "DC=test,DC=local") => JsonSerializer.SerializeToElement(new
    {
        Version = 1, Id = id, Name = "Vue historique", DomainDn = domain, OuDn = "OU=Postes," + domain, Subtree = true,
        TypeLabel = "Machines", Presence = "En ligne", LocalFilter = "PC", Limit = 200,
        Columns = new[] { new { Key = "Name", Index = 0, Width = 210, Unit = "Pixel" } }, Sort = new[] { new { Field = "Name", Direction = "Descending" } },
    });

    [Test]
    public static async Task Actual_legacy_file_flattens_wrappers_and_keeps_every_unreadable_foreign_and_duplicate_entry_through_save_remove_undo()
    {
        using var folder = new TemporaryFolder();
        var id = Guid.NewGuid(); var same = D1(id.ToString("D")); var foreign = D1(Guid.NewGuid().ToString("D"), "DC=other,DC=local");
        var text = "[[[],[" + same.GetRawText() + "]],null,17,{\"unknown\":\"kept\"}," + foreign.GetRawText() + "," + same.GetRawText() + "]";
        var source = folder.File("Domenia.settings.json");
        await File.WriteAllTextAsync(source, JsonSerializer.Serialize(new Dictionary<string, string> { ["Search.WorkspacesJson"] = text }));
        var original = await File.ReadAllBytesAsync(source);
        var profile = folder.File("prefs.json");
        using (var prefs = new FilePreferenceStore(profile, new RecordingJournal()))
        using (var memory = Memory(prefs))
        {
            Task<JsonElement?> Read(CancellationToken token) => Task.FromResult(LegacySearchFile.ReadWorkspaces([source], token));
            var state = await memory.StateAsync(Domain, default, legacyWorkspaces: Read);
            Check.Equal(1, state.Workspaces.Length, "seule la vue valide du domaine est proposée");
            Check.Equal(id.ToString("N"), state.Workspaces.Single().Id, "identité D1 conservée");
            Check.Equal("online", state.Workspaces.Single().Presence, "vrai filtre D1 traduit");
            Check.Equal(-1, state.Workspaces.Single().Layout!.Sort.Single().Dir, "tri réel traduit");
            Check.True(state.Warning!.Contains("entrées conservées"), "incompatibles comptés, pas cachés silencieusement");
            await Check.ThrowsAsync<DomeniaOperationException>(() => memory.RemoveWorkspaceAsync(Domain, id.ToString("N"), default), "doublon pas supprimé arbitrairement");
            var added = await memory.SaveWorkspaceAsync(Domain, Draft("Nouvelle"), default);
            await memory.RemoveWorkspaceAsync(Domain, added.Workspaces.Single(v => v.Name == "Nouvelle").Id, default);
            var restored = await memory.UndoRemoveAsync(Domain, default);
            Check.Equal(2, restored.Workspaces.Length, "les deux vues accessibles après annulation");
            Check.True(prefs.TryGet(Key, out var raw), "préférence réellement enregistrée");
            var kept = SearchWorkspaceStore.Read(raw);
            Check.Equal(7, kept.Entries.Length, "toutes les entrées, même null, comptent");
            Check.Equal(2, kept.Entries.Count(e => e.GetRawText() == same.GetRawText()), "doublon original et vue rétablie conservés sans réparation");
            var again = await memory.StateAsync(Domain, default, legacyWorkspaces: _ => throw new TestFailureException("Source relue après reçu atomique."));
            Check.Equal(2, again.Workspaces.Length, "pas de réimport après reçu dans la même enveloppe");
        }
        using var cold = new FilePreferenceStore(profile, new RecordingJournal());
        Check.True(cold.TryGet(Key, out var persisted), "relecture froide");
        Check.Equal(7, SearchWorkspaceStore.Read(persisted).Entries.Length, "entrées durables après fermeture");
        var after = await File.ReadAllBytesAsync(source);
        Check.True(original.SequenceEqual(after), "source historique strictement intacte");
    }

    [Test]
    public static async Task Raw_limits_and_corrupt_envelopes_refuse_mutation_without_dropping_original_entries()
    {
        var prefs = new MemoryPreferenceStore(); using var memory = Memory(prefs);
        await prefs.SetAsync(Key, JsonSerializer.SerializeToElement(Enumerable.Range(0, 100).Select(i => new { incompatible = i })), default);
        var before = prefs.TryGet(Key, out var raw) ? raw.GetRawText() : "";
        await Check.ThrowsAsync<DomeniaOperationException>(() => memory.SaveWorkspaceAsync(Domain, Draft("Ne doit pas écraser"), default), "les entrées non proposées comptent aussi dans la limite");
        Check.True(prefs.TryGet(Key, out raw) && raw.GetRawText() == before, "100 entrées conservées");
        await prefs.SetAsync(Key, JsonSerializer.SerializeToElement(new { broken = true }), default);
        var state = await memory.StateAsync(Domain, default);
        Check.True(state.Warning!.Contains("aucune entrée"), "enveloppe illisible annoncée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => memory.SaveWorkspaceAsync(Domain, Draft("Non"), default), "enveloppe corrompue refuse l’écriture");
        Check.True(prefs.TryGet(Key, out raw) && raw.GetProperty("broken").GetBoolean(), "document intact");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Task.Run(() => SearchWorkspaceStore.DecodeLegacy("[\"" + new string('a', 1_048_576) + "\"]")), "taille contrôlée avant parse");
    }

    [Test]
    public static async Task Concurrent_profile_workspace_change_is_never_overwritten_by_an_old_session()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("profile.json");
        using var first = new FilePreferenceStore(path, new RecordingJournal()); using var a = Memory(first);
        await a.SaveWorkspaceAsync(Domain, Draft("Première"), default);
        using var second = new FilePreferenceStore(path, new RecordingJournal()); using var b = Memory(second);
        await b.SaveWorkspaceAsync(Domain, Draft("Autre session"), default);
        await Check.ThrowsAsync<DomeniaOperationException>(() => a.SaveWorkspaceAsync(Domain, Draft("Ancienne session"), default), "pas de mise à jour perdue");
        var refreshed = await a.StateAsync(Domain, default);
        Check.Equal(2, refreshed.Workspaces.Length, "relire les vues recharge réellement le choix concurrent");
        using var cold = new FilePreferenceStore(path, new RecordingJournal()); using var read = Memory(cold);
        var views = (await read.StateAsync(Domain, default)).Workspaces;
        Check.True(views.Select(v => v.Name).Order().SequenceEqual(new[] { "Autre session", "Première" }), "deux choix durables conservés");
    }
}
