using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private static readonly string[] NativeInspectionTables =
    [
        "domenia_v2_batches", "domenia_v2_deletions", "domenia_v2_directory_branches", "domenia_v2_fiches", "domenia_v2_fleet_rows", "domenia_v2_fleet_state",
        "domenia_v2_legacy_receipts", "domenia_v2_metadata", "domenia_v2_objects", "domenia_v2_operations", "domenia_v2_purge_receipts",
        "domenia_v2_query_library", "domenia_v2_query_library_archive", "domenia_v2_query_results", "domenia_v2_relation_journal", "domenia_v2_relation_writes",
        "domenia_v2_retention_receipts", "domenia_v2_shared_park_receipts", "domenia_v2_store_lineage", "domenia_v2_sweep_writes",
        "domenia_v2_sync_proofs", "domenia_v2_sync_receipts", "domenia_v2_writer_receipts", "park_state",
    ];

    public async Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken)
    {
        // The same gate as purge/retention: an explicit diagnostic never queues behind maintenance.
        var locked = measure || integrity;
        if (locked && !await writer.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        { throw new DomeniaOperationException("settings.diagnosticBusy", "Enregistrement, maintenance ou diagnostic en cours : relancez le contrôle après sa fin."); }
        LocalStoreSnapshot snapshot;
        try { snapshot = await InspectLocalStoreCoreAsync(measure, integrity, cancellationToken).ConfigureAwait(false); }
        finally { if (locked) { writer.Release(); } }
        return snapshot with { Writer = ActualWriterState(snapshot.Writer.Unavailable) };
    }

    private static (bool Available, string Note, Dictionary<string, long> Bytes) MeasureAllocatedBytes(SqliteDatabase db)
    {
        // SQLITE_ENABLE_DBSTAT_VTAB is optional in the Windows SQLite library. No extension is loaded.
        var compiled = db.Query("PRAGMA compile_options;").Any(r => r.Values.Any(v => v as string == "ENABLE_DBSTAT_VTAB"));
        if (!compiled) { return (false, "dbstat absent de la bibliothèque SQLite Windows : répartition par nombre de lignes. Les octets par table restent inconnus.", new(StringComparer.Ordinal)); }
        var sizes = db.Query("SELECT COALESCE(m.tbl_name,d.name) AS owner,SUM(d.pgsize) AS bytes FROM dbstat AS d LEFT JOIN sqlite_master AS m ON m.name=d.name GROUP BY COALESCE(m.tbl_name,d.name);")
            .ToDictionary(r => (string)r["owner"]!, r => (long)r["bytes"]!, StringComparer.Ordinal);
        return (true, "Pages allouées aux tables et à leurs index, mesurées par dbstat ; pages libres et journal WAL exclus.", sizes);
    }

    private LocalStoreCheck ReadJournalCheck(SqliteDatabase db)
    {
        var mode = db.Scalar("PRAGMA journal_mode;") as string;
        var hasWal = File.Exists(Path + "-wal");
        var bytes = hasWal ? new FileInfo(Path + "-wal").Length : 0;
        var known = mode is "wal" or "delete" or "truncate" or "persist";
        return new("wal", known ? "ok" : "warning", "Mode SQLite observé : " + (mode ?? "inconnu")
            + (hasWal ? "; fichier WAL présent, " + SettingsFormat.Size(bytes) : "; aucun fichier WAL présent")
            + ". Lu dans la transaction SQLite ; aucun checkpoint, changement de mode ou effacement.");
    }

    private static LocalStoreCheck CheckReceiptHeaders(SqliteDatabase db, long revision)
    {
        static bool Invalid(SqliteDatabase db, string table, string hash, long revision) => Table(db, table)
            && (long)db.Scalar("SELECT count(*) FROM " + table + " WHERE revision<0 OR revision>?1 OR " + hash + " IS NULL OR length(" + hash + ")<>64 OR " + hash + " GLOB '*[^0-9A-Fa-f]*';", revision)! > 0;
        var bad = Invalid(db, "domenia_store_batches", "payload_hash", revision) || Invalid(db, "domenia_v2_batches", "sha256", revision);
        return new("receipts", bad ? "failed" : "ok", bad ? "Révision ou empreinte d’un en-tête de reçu incohérente."
            : "En-têtes historiques et natifs : révisions et forme SHA-256 vérifiées. Aucun contenu historique rejoué ni certifié par ce contrôle.");
    }
}
