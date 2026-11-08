namespace Domenia.Core;

public sealed partial class SupportWorkshop
{
    /// <summary>Seals the local directory identity after a real subject read; no additional network request.</summary>
    public async Task<SubjectRecord> SealSelectionAsync(SubjectRecord record, CancellationToken token)
    {
        var identity = await LocalSelectionAsync(record.Dn, token).ConfigureAwait(false);
        var sid = record.Properties.FirstOrDefault(pair => pair.Key.Equals("objectSid", StringComparison.OrdinalIgnoreCase)).Value?.FirstOrDefault()?.ToString();
        if (identity.ObjectGuid != record.Guid || identity.Kind != record.Kind.ToString().ToLowerInvariant()
            || !DistinguishedName.AreEqual(identity.Dn, record.Dn)
            || sid is not null && !string.Equals(identity.Sid, sid, StringComparison.OrdinalIgnoreCase)) throw SelectionChanged();
        return record with { Selection = identity };
    }

    /// <summary>Both before a scheduled step's actual start and before retaining its result. Expected generation may only
    /// advance through SelectionReadScope's observed acquisition of that step's own one-shot credential.</summary>
    public async Task EnsureSameSelectionAsync(SelectionIdentity? expected, CancellationToken token)
    {
        if (expected is null || !expected.SameContext(await LocalSelectionAsync(expected.Dn, token).ConfigureAwait(false))) throw SelectionChanged();
    }

    private async Task<SelectionIdentity> LocalSelectionAsync(string dn, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var accounts = AccountAccess.From(context); var generation = accounts.SelectionVersion;
        var index = context.Readers.Find<IFicheReader>() ?? throw SelectionChanged();
        var objects = await index.IndexAsync([dn], token).ConfigureAwait(false);
        var rows = objects.Values.Where(row => DistinguishedName.AreEqual(row.Dn, dn)).Take(2).ToArray();
        if (rows.Length != 1) throw SelectionChanged();
        var row = rows[0];
        var identity = SelectionIdentity.Capture(session, row.ObjectGuid, FicheSheets.KindId(row.Kind), row.Dn, row.Name, row.Sam, row.Sid, generation);
        var after = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (identity is null || accounts.SelectionVersion != generation || SelectionIdentity.ReaderKey(session) != SelectionIdentity.ReaderKey(after)) throw SelectionChanged();
        return identity;
    }
    private static DomeniaOperationException SelectionChanged() => new("selection.changed", "Le sujet ou le compte a changé depuis sa lecture ; relisez sa fiche avant cette étape.");
}
