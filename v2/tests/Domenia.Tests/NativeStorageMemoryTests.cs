using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageMemoryTests
{
    [Test]
    public static void Schema_inspection_can_use_an_isolated_memory_database_without_a_disk_fence()
    {
        using var first = new SqliteDatabase(":memory:", false);
        using var second = new SqliteDatabase(":memory:", false);
        first.Script("CREATE TABLE schema_probe(value INTEGER NOT NULL); INSERT INTO schema_probe VALUES(11);");
        Check.Equal(11L, first.Scalar("SELECT value FROM schema_probe;"), "base temporaire utilisable sans chemin de fichier");
        Check.Equal(0L, second.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='schema_probe';"), "chaque connexion mémoire reste indépendante");
        Check.Throws<InvalidDataException>(() => StorageWriteFence.Exclusive(":memory:", default), "une bascule exige toujours un vrai chemin local");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Check.Throws<OperationCanceledException>(() => StorageWriteFence.Writer(":memory:", cancelled.Token), "annulation respectée même sans fichier");
    }
}
