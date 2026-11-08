using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PreferenceLimitsTests
{
    [Test]
    public static async Task Count_and_UTF8_document_budgets_refuse_before_replacing_memory_or_disk()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        var entries = Enumerable.Range(0, PreferenceDocumentLimits.MaxKeys).ToDictionary(i => "screen.key" + i, _ => JsonSerializer.SerializeToElement(true));
        var original = PreferenceDocumentLimits.Encode(entries); await File.WriteAllBytesAsync(path, original);
        var memory = new MemoryPreferenceStore();
        foreach (var pair in entries) await memory.SetAsync(pair.Key, pair.Value, default);
        using var disk = new FilePreferenceStore(path, new RecordingJournal());
        foreach (IPreferenceStore store in new IPreferenceStore[] { memory, disk })
        {
            await Check.ThrowsAsync<InvalidDataException>(() => store.SetAsync("screen.excess", JsonSerializer.SerializeToElement(1), default), "257e clé refusée avant mutation");
            Check.False(store.TryGet("screen.excess", out _), "pas de choix fantôme en mémoire");
            await Check.ThrowsAsync<InvalidDataException>(() => ((IAtomicPreferenceStore)store).UpdateAsync("screen.key0", _ => JsonSerializer.SerializeToElement(new string('é', PreferenceDocumentLimits.MaxBytes / 2)), default), "UTF-8 et enveloppe bornés ensemble");
            Check.True(store.TryGet("screen.key0", out var before) && before.GetBoolean(), "original conservé après refus atomique");
        }
        var afterRefusal = await File.ReadAllBytesAsync(path);
        Check.True(original.SequenceEqual(afterRefusal), "octets du document inchangés");
        await disk.SetAsync("screen.key0", JsonSerializer.SerializeToElement(false), default);
        using var reopened = new FilePreferenceStore(path, new RecordingJournal());
        Check.True(reopened.TryGet("screen.key0", out var saved) && !saved.GetBoolean(), "une mise à jour valide reste possible après refus");
        Check.True(reopened.TryGet("screen.key255", out _), "clés des autres écrans conservées");
    }

    [Test]
    public static async Task Recovery_copies_are_never_overwritten_by_a_second_corrupt_document()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        await File.WriteAllTextAsync(path, "original illisible");
        using (var first = new FilePreferenceStore(path, new RecordingJournal()))
            await first.SetAsync("screen.choice", JsonSerializer.SerializeToElement(1), default);
        Check.Equal("original illisible", await File.ReadAllTextAsync(path + ".illisible"), "copie vérifiée du premier original");
        await File.WriteAllTextAsync(path, "second original illisible");
        using (var second = new FilePreferenceStore(path, new RecordingJournal()))
            await second.SetAsync("screen.choice", JsonSerializer.SerializeToElement(2), default);
        Check.Equal("original illisible", await File.ReadAllTextAsync(path + ".illisible"), "première récupération intacte");
        var extra = Directory.GetFiles(folder.Path, "preferences.json.illisible.*")
            .Single(file => !string.Equals(file, path + ".illisible", StringComparison.OrdinalIgnoreCase));
        Check.Equal("second original illisible", await File.ReadAllTextAsync(extra), "second original conservé séparément");
    }
}
