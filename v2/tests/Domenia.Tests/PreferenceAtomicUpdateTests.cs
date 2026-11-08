using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PreferenceAtomicUpdateTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Atomic_preference_update_refuses_unknown_root_format_and_failure_without_memory_changes()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        const string unknown = "{\"format\":\"domenia.preferences\",\"version\":1,\"values\":{},\"future\":true}";
        File.WriteAllText(path, unknown);
        using var prefs = new FilePreferenceStore(path, new RecordingJournal());
        var invoked = false;
        await Check.ThrowsAsync<InvalidDataException>(() => prefs.UpdateAsync("poste.computerLayout", _ => { invoked = true; return JsonSerializer.SerializeToElement(1); }, None), "document futur refusé");
        Check.False(invoked, "pas de callback sur une source illisible");
        Check.Equal(unknown, File.ReadAllText(path), "original intact");
        Check.False(prefs.TryGet("poste.computerLayout", out _), "aucun état optimiste");
        var memory = new MemoryPreferenceStore();
        await memory.SetAsync("poste.computerLayout", JsonSerializer.SerializeToElement(12), None);
        await Check.ThrowsAsync<InvalidDataException>(() => memory.UpdateAsync("poste.computerLayout", _ => throw new InvalidDataException("refus"), None), "refus mémoire atomique");
        Check.True(memory.TryGet("poste.computerLayout", out var value), "valeur conservée");
        Check.Equal(12, value.GetInt32(), "callback échoué ne change rien");
    }

    [Test]
    public static async Task Pending_local_choice_and_cancelled_update_are_preserved_without_replacement()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var prefs = new FilePreferenceStore(path, new RecordingJournal());
        await prefs.SetAsync("poste.computerLayout", JsonSerializer.SerializeToElement("disk"), None);
        var original = File.ReadAllText(path);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            await Check.ThrowsAsync<IOException>(() => prefs.SetAsync("poste.computerLayout", JsonSerializer.SerializeToElement("pending"), None), "échec d’écriture garde choix local");
        }
        await Check.ThrowsAsync<IOException>(() => prefs.UpdateAsync("poste.computerLayout", _ => JsonSerializer.SerializeToElement("replaced"), None), "choix local en attente refusé");
        Check.True(prefs.TryGet("poste.computerLayout", out var pending), "choix local présent");
        Check.Equal("pending", pending.GetString(), "choix local intact");
        Check.Equal(original, File.ReadAllText(path), "disque intact");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => prefs.UpdateAsync("other.choice", _ => JsonSerializer.SerializeToElement(true), cancelled.Token), "annulation avant écriture");
        Check.Equal(original, File.ReadAllText(path), "aucune écriture annulée");
    }
}
