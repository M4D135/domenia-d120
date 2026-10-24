using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    /// <summary>
    /// Local, read-only view of the stored park survey, as the merge step needs it: the whole <see cref="RelationSweepCacheSnapshot"/>
    /// is carried (original rows, storage keys, GUIDs, DNs, fingerprints), never a projection that could lose an identity. One
    /// deterministic fingerprint binds store, domain, revision and generation to the exhaustive row fingerprint already computed.
    /// </summary>
    internal sealed record SharedParkLocalRead(bool Exists, bool Legacy, string StoreId, string DomainDn, long Revision, long Generation,
        string RowsFingerprint, string Fingerprint, RelationSweepCacheSnapshot Sweeps)
    {
        /// <summary>Codec-ready lines, reachable only once every row was proven representable in the bounded D1 TSV.</summary>
        internal ImmutableArray<SharedParkLine> CodecLines() => [.. Sweeps.Rows.Select(r => new SharedParkLine(r.Computer, r.At!.Value, r.Status, r.UserLogin, r.Attempts, null))];
    }

    /// <summary>
    /// Strictly local and read-only: one read transaction, no initialize, no upgrade, no backup, no file, column, table or generation
    /// created. It takes no share path, reads no share configuration and takes no network lock.
    /// </summary>
    internal Task<SharedParkLocalRead> ReadSharedParkLocalAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (LocalBaseAbsent(cancellationToken)) { return AbsentSharedParkLocal(); }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(false);
        CheckIdentity(db, allowLegacy: true);
        var (revision, legacy) = ReadSharedParkRevision(db);
        var sweeps = ReadRelationSweeps(db, cancellationToken);
        var read = QualifySharedParkLocal(sweeps, revision, legacy, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        db.Commit();
        return read;
    }, cancellationToken);

    /// <summary>
    /// A survey is published only as a whole: a truncated read, a rejected row, an uncertain or missing date, a sentinel date, an
    /// inconsistent total or a value the TSV codec could not write refuses everything. Nothing is corrected, substituted or dropped.
    /// The walk over up to 50 000 rows is cancellable, like the SQL read that produced it.
    /// </summary>
    internal SharedParkLocalRead QualifySharedParkLocal(RelationSweepCacheSnapshot sweeps, long revision, bool legacy, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(sweeps);
        token.ThrowIfCancellationRequested();
        if (!string.Equals(sweeps.StoreId, StoreId, StringComparison.Ordinal) || !string.Equals(sweeps.DomainDn, DomainDn, StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Relevé local rattaché à une autre identité de base ; aucune fusion engagée."); }
        if (revision < 0) { throw new InvalidDataException("Révision locale négative ; aucune fusion engagée."); }
        if (sweeps.Generation < 0) { throw new InvalidDataException("Génération des relevés négative ; aucune fusion engagée."); }
        if (sweeps.Truncated) { throw new InvalidDataException("Relevé local lu partiellement (50 000 lignes ou 16 Mio au plus) ; aucune publication partielle n’est envisagée."); }
        if (sweeps.Rejected > 0) { throw new InvalidDataException("Relevé local contenant des lignes illisibles ; rien n’est publié sans une base entièrement relisible."); }
        if (sweeps.UncertainDates > 0) { throw new InvalidDataException("Relevé local contenant des dates non qualifiées ; aucune date de substitution n’est fabriquée."); }
        if (sweeps.Total < 0 || sweeps.Total != sweeps.Rows.Length || sweeps.Rows.Length > SharedParkFile.MaxRows)
        { throw new InvalidDataException("Nombre de lignes du relevé local incohérent ou hors limites ; aucune fusion engagée."); }
        foreach (var row in sweeps.Rows)
        {
            token.ThrowIfCancellationRequested();
            if (row.At is null) { throw new InvalidDataException("Relevé local sans date réelle pour « " + row.StorageKey + " » ; DateTimeOffset.MinValue n’est jamais substitué."); }
            SharedParkFile.Validate(new SharedParkLine(row.Computer, row.At.Value, row.Status, row.UserLogin, row.Attempts, null));
        }
        token.ThrowIfCancellationRequested();
        var fingerprint = SharedParkLocalFingerprint(StoreId, DomainDn, revision, sweeps.Generation, legacy, sweeps.Fingerprint);
        return new(true, legacy, StoreId, DomainDn, revision, sweeps.Generation, sweeps.Fingerprint, fingerprint, sweeps);
    }

    /// <summary>Same bytes, same fingerprint: the merge preview can be re-derived without ever trusting a stored summary.</summary>
    internal static string SharedParkLocalFingerprint(string storeId, string domainDn, long revision, long generation, bool legacy, string rowsFingerprint)
    {
        ArgumentNullException.ThrowIfNull(storeId);
        ArgumentNullException.ThrowIfNull(domainDn);
        ArgumentNullException.ThrowIfNull(rowsFingerprint);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n',
            "domenia.sharedpark.local.v1", storeId, domainDn.ToLowerInvariant(),
            revision.ToString(CultureInfo.InvariantCulture), generation.ToString(CultureInfo.InvariantCulture),
            legacy ? "herite" : "natif", rowsFingerprint))));
    }

    private SharedParkLocalRead AbsentSharedParkLocal()
    {
        var empty = EmptySweeps();
        return new(false, false, StoreId, DomainDn, 0, 0, empty.Fingerprint, SharedParkLocalFingerprint(StoreId, DomainDn, 0, 0, false, empty.Fingerprint), empty);
    }

    /// <summary>
    /// Local presence qualification that never turns an access error into an absence and never reads a directory as an absent file.
    /// The real root and every existing ancestor are qualified first, in path order; only a genuinely missing terminal file, or a
    /// genuinely missing component under already qualified parents, answers <c>true</c> (Exists stays false, nothing is created). A
    /// directory standing where the base should be, a reparse/junction anywhere on the path, an unavailable root, and a component
    /// that is not a directory refuse the whole read; an access or other IO error surfaces instead of masquerading as absent. A
    /// present but unreadable or foreign file is left to <see cref="SqliteDatabase"/> and <c>CheckIdentity</c>, never initialized.
    /// Every step is cancellable and creates no directory, no file and no base.
    /// </summary>
    private bool LocalBaseAbsent(CancellationToken token)
    {
        var root = System.IO.Path.GetPathRoot(Path);
        if (string.IsNullOrEmpty(root)) { throw new InvalidDataException("Racine de la base locale absente ; une absence de profil n’est jamais déduite d’un chemin sans racine."); }
        token.ThrowIfCancellationRequested();
        FileAttributes rootAttributes;
        try { rootAttributes = File.GetAttributes(root); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        { throw new InvalidDataException("Racine de la base locale inaccessible : « " + root + " » ; une racine indisponible n’est jamais un nouveau profil.", ex); }
        if ((rootAttributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Racine de la base locale est un point d’analyse, une jonction ou un lien : « " + root + " » ; la lecture s’arrête là."); }
        if ((rootAttributes & FileAttributes.Directory) == 0) { throw new InvalidDataException("Racine de la base locale n’est pas un répertoire : « " + root + " » ; aucune lecture engagée."); }

        var directory = System.IO.Path.GetDirectoryName(Path)!;
        string relative;
        try { relative = System.IO.Path.GetRelativePath(root, directory); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        { throw new InvalidDataException("Chemin de la base locale impossible à qualifier sous sa racine : « " + Path + " » ; aucune absence n’est supposée.", ex); }
        var current = root;
        if (!string.IsNullOrEmpty(relative) && relative != ".")
        {
            foreach (var segment in relative.Split(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar))
            {
                token.ThrowIfCancellationRequested();
                if (segment.Length == 0) { continue; }
                current = System.IO.Path.Combine(current, segment);
                FileAttributes attributes;
                try { attributes = File.GetAttributes(current); }
                catch (Exception ex) when (ex is DirectoryNotFoundException or FileNotFoundException) { return true; }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
                { throw new InvalidDataException("Parent de la base locale inaccessible : « " + current + " » ; une erreur d’accès n’est jamais convertie en absence.", ex); }
                if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Parent de la base locale est un point d’analyse, une jonction ou un lien : « " + current + " » ; la lecture s’arrête là."); }
                if ((attributes & FileAttributes.Directory) == 0) { throw new InvalidDataException("Parent de la base locale n’est pas un répertoire : « " + current + " » ; aucune lecture engagée."); }
            }
        }

        token.ThrowIfCancellationRequested();
        FileAttributes terminal;
        try { terminal = File.GetAttributes(Path); }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return true; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        { throw new InvalidDataException("Base locale inaccessible : « " + Path + " » ; une erreur d’accès n’est jamais convertie en absence.", ex); }
        if ((terminal & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("La base locale est un point d’analyse, une jonction ou un lien ; la lecture s’arrête là."); }
        if ((terminal & FileAttributes.Directory) != 0) { throw new InvalidDataException("La cible de la base locale est un dossier ; aucun dossier n’est lu comme une base."); }
        return false;
    }


    /// <summary>A Domenia 1 base without the storage checkpoint stays Domenia 1: revision zero, declared inherited, never migrated here.</summary>
    private (long Revision, bool Legacy) ReadSharedParkRevision(SqliteDatabase db)
    {
        if (!Table(db, "domenia_store_state")) { return (0, true); }
        var rows = db.Query("SELECT id,store_id,domain_dn,revision FROM domenia_store_state LIMIT 2;");
        if (rows.Count != 1) { throw new InvalidDataException("État du stockage absent ou multiple ; aucune révision n’est supposée."); }
        var row = rows[0];
        if (row["id"] is not long id || id != 1) { throw new InvalidDataException("Ligne d’état du stockage mal identifiée ; aucune révision n’est supposée."); }
        if (row["revision"] is not long revision || revision < 0) { throw new InvalidDataException("Révision du stockage illisible ; elle n’est jamais convertie en zéro."); }
        if (row["store_id"] is not string storeId || !string.Equals(storeId, StoreId, StringComparison.Ordinal)
            || row["domain_dn"] is not string domain || !string.Equals(domain, DomainDn, StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("État du stockage d’une identité étrangère ; aucune fusion engagée."); }
        return (revision, false);
    }
}
