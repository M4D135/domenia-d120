using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<DomainAccountMeasure?> ReadDomainAccountsAsync(CancellationToken token) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return null; }
        using var db = Open(readOnly: true, cancellationToken: token);
        db.Begin(write: false);
        CheckIdentity(db, allowLegacy: true);
        var result = ReadDomainAccounts(db);
        db.Commit();
        return result;
    }, token);

    public Task<DomainAccountMeasure> SaveDomainAccountsAsync(DomainAccountMeasure measure, CancellationToken token) =>
        ObserveWriteAsync("SaveDomainAccounts", measure, true, ct => SaveDomainAccountsCoreAsync(measure, ct), token);

    private async Task<DomainAccountMeasure> SaveDomainAccountsCoreAsync(DomainAccountMeasure measure, CancellationToken token)
    {
        ValidateDomainAccounts(measure);
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: false, cancellationToken: token);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, token);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                if (ReadDomainAccounts(db) is { } previous && previous.ReadAt > measure.ReadAt)
                { throw new InvalidDataException("Relevé des comptes antérieur à la mesure conservée."); }
                db.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('domainAccounts',?1) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload;", JsonSerializer.Serialize(measure, Json));
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                db.Commit();
                return ReadDomainAccounts(db) ?? throw new InvalidDataException("Compteurs absents après enregistrement.");
            }, token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private DomainAccountMeasure? ReadDomainAccounts(SqliteDatabase db)
    {
        var raw = Table(db, "domenia_v2_metadata") ? db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='domainAccounts';") as string : null;
        if (raw is null) { return null; }
        var measure = JsonSerializer.Deserialize<DomainAccountMeasure>(raw, Json) ?? throw new InvalidDataException("Compteurs du domaine illisibles.");
        ValidateDomainAccounts(measure);
        return measure;
    }

    private void ValidateDomainAccounts(DomainAccountMeasure measure)
    {
        if (measure.Domain is null || !DistinguishedName.AreEqual(measure.Domain.RootDn, DomainDn)
            || measure.ReadAt == DateTimeOffset.MinValue || measure.ReadAt > clock.GetUtcNow().AddMinutes(2)
            || measure.PasswordWindowDays is < 1 or > 365
            || new[] { measure.Active, measure.Disabled, measure.Locked, measure.LockUnknown, measure.Expiring, measure.Expired, measure.MustChange, measure.NeverExpires, measure.PasswordUnknown }.Any(x => x < 0)
            || (long)measure.Locked + measure.LockUnknown > measure.Active
            || (long)measure.Expiring + measure.Expired + measure.MustChange + measure.NeverExpires + measure.PasswordUnknown > measure.Active)
        { throw new InvalidDataException("Compteurs du domaine incohérents ou hors contexte."); }
    }
}

public sealed partial class SqliteDirectoryCache : IDomainAccountCache
{
    public Task<DomainAccountMeasure?> ReadDomainAccountsAsync(CancellationToken token) => Database.ReadDomainAccountsAsync(token);
    public async Task<DomainAccountMeasure> SaveDomainAccountsAsync(DomainAccountMeasure measure, CancellationToken token)
    {
        await Database.InitializeAsync(token).ConfigureAwait(false);
        return await Database.SaveDomainAccountsAsync(measure, token).ConfigureAwait(false);
    }
}

public sealed partial class CompatibleDirectoryCache : IDomainAccountCache
{
    public async Task<DomainAccountMeasure?> ReadDomainAccountsAsync(CancellationToken token) =>
        await (await CacheAsync(token).ConfigureAwait(false)).ReadDomainAccountsAsync(token).ConfigureAwait(false);
    public async Task<DomainAccountMeasure> SaveDomainAccountsAsync(DomainAccountMeasure measure, CancellationToken token) =>
        await (await CacheAsync(token).ConfigureAwait(false)).SaveDomainAccountsAsync(measure, token).ConfigureAwait(false);
}
