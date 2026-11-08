using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private static readonly JsonSerializerOptions LegacyJournalJson = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private string SerializeRelationJournal(RelationJournalRecord entry) => JsonSerializer.Serialize(new
    {
        entry.Id, Action = entry.Action.ToString(), WhenUtc = entry.At.ToUniversalTime().ToString("o"), entry.Declarant, entry.Note, entry.Key, BaseDn = DomainDn,
        Relation = new
        {
            entry.Relation.UserLogin, UserGuid = entry.Relation.UserGuid?.ToString("D"), entry.Relation.UserDn,
            entry.Relation.Computer, ComputerGuid = entry.Relation.ComputerGuid?.ToString("D"), entry.Relation.ComputerDn,
            Kind = entry.Relation.Kind switch { RelationKind.Assignment => "Affectation", RelationKind.RemoteSession => "SessionRdp",
                RelationKind.History => "Historique", RelationKind.Imported => "Importe", RelationKind.Hint => "Indice", RelationKind.Unknown => "Inconnu", _ => "Console" },
            entry.Relation.Source, When = entry.Relation.When?.ToUniversalTime().ToString("o"), entry.Relation.Details,
            VerifiedInAD = entry.Relation.VerifiedInAd, entry.Relation.Declarant, entry.Relation.BatchId, Confidence = 0,
        },
    }, LegacyJournalJson);

    private FileStream? OpenRelationJournalForAppend()
    {
        var path = Path + ".relations-journal.jsonl";
        CompatibleDirectoryCache.ValidateLocalPath(path);
        try { return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }

    private void ValidateRestorations(SqliteDatabase db, RelationStoreWrite request, CancellationToken token)
    {
        var restores = request.Items.Where(i => i.RestoresEntry is not null).ToArray();
        if (restores.Length == 0) { return; }
        // The append lease denies concurrent legacy writers while this decision and the SQLite commit take place.
        var journal = ReadRelationJournal(db, token);
        if (!journal.LegacyReadable) { throw RelationStale("Le journal D1 ne peut pas être relu ; restauration différée."); }
        var available = RelationRules.Restorable(journal.Entries).ToDictionary(e => e.Id, StringComparer.Ordinal);
        foreach (var item in restores)
        {
            if (!available.TryGetValue(item.RestoresEntry!, out var entry)
                || RelationRules.Fingerprint(entry.Relation) != RelationRules.Fingerprint(item.After!))
            { throw RelationStale("Retrait absent, modifié ou déjà restauré ; relisez le journal."); }
            if (Table(db, RelationJournalTable) && (long)db.Scalar("SELECT count(*) FROM domenia_v2_relation_journal WHERE restores_id=?1;", item.RestoresEntry)! != 0)
            { throw RelationStale("Ce retrait a déjà été restauré."); }
        }
    }

    /// <summary>Durable outbox: append then fsync, then acknowledge. A crash between these steps may repeat an identical UUID, never lose a removal.</summary>
    private static int ExportRelationJournal(SqliteDatabase db, FileStream? stream)
    {
        var pending = -1;
        try
        {
            pending = checked((int)(long)db.Scalar("SELECT count(*) FROM domenia_v2_relation_journal WHERE exported=0;")!);
            if (stream is null || pending == 0) { return pending; }
            var rows = db.Query("SELECT id,CASE WHEN typeof(payload)='text' AND length(CAST(payload AS BLOB))<=65536 THEN payload ELSE NULL END AS payload FROM domenia_v2_relation_journal WHERE exported=0 ORDER BY at,id LIMIT 256;");
            stream.Position = stream.Length;
            if (stream.Length > 0)
            {
                stream.Position--; var last = stream.ReadByte();
                if (last != '\n') { stream.WriteByte((byte)'\n'); } // Preserve a partial legacy line, make the following entry independently readable.
            }
            foreach (var row in rows)
            {
                if (row["payload"] is not string payload) { return pending; }
                var bytes = Encoding.UTF8.GetBytes(payload + "\n"); stream.Write(bytes);
            }
            stream.Flush(flushToDisk: true);
            db.Begin();
            foreach (var row in rows) { db.Execute("UPDATE domenia_v2_relation_journal SET exported=1 WHERE id=?1;", row["id"]); }
            db.Commit(); return pending - rows.Count;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SqliteStoreException or OperationCanceledException)
        {
            // If acknowledgement fails, its transaction is rolled back on disposal and the same durable IDs stay pending.
            return pending;
        }
    }
}
