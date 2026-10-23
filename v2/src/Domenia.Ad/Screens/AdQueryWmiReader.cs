using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdQueryWmiReader(AdDirectorySource source) : IQueryWmiReader
{
    internal Func<PosteConfiguration, WmiWorkstationReader>? InventoryReaderOverride { get; init; }
    internal Action<DirectoryComputer>? ExpectedIdentity { get; init; }
    private WmiWorkstationReader Reader(AdQueryAccess access) => InventoryReaderOverride?.Invoke(access.Machine.Settings) ?? access.Machine.InventoryReader();

    private async Task<(DirectoryComputer Computer, WorkstationWmiReading Read)> MetadataAsync(Guid guid, WmiMetadataKind kind, string ns, string? name, CancellationToken token)
    {
        WqlRules.CheckNamespace(ns);
        if (name is not null) { WqlRules.CheckTarget(ns, name); }
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(50), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        using var access = await AdQueryAccess.OpenAsync(source, guid, stop.Token).ConfigureAwait(false);
        var read = await Reader(access).ReadWmiMetadataAsync(access.Computer.DnsHostName!, kind, ns, name, stop.Token, access.Machine.Credential).ConfigureAwait(false);
        CheckStatus(access, read.Status, read.AuthenticationRejected, read.Detail);
        await access.ConfirmAsync(read.ReportedName, stop.Token).ConfigureAwait(false);
        return (access.Computer, read);
    }

    private static void CheckStatus(AdQueryAccess access, SourceStatus status, bool authentication, string detail)
    {
        access.EnsureCurrent();
        if (authentication || status == SourceStatus.Refused) { access.Machine.Refused(access.Computer.DnsHostName!, "Atelier de requêtes WMI", authentication); }
        if (authentication || status is not (SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Lecture WMI " + PosteLabels.SourceStatusLabel(status).ToLowerInvariant() + " : " + detail); }
    }

    public async Task<WmiNamespaceList> NamespacesAsync(Guid computer, string ns, CancellationToken cancellationToken)
    {
        var (pc, read) = await MetadataAsync(computer, WmiMetadataKind.Namespaces, ns, null, cancellationToken).ConfigureAwait(false);
        return new(pc.Name, ns, [.. read.Names.Select(n => ns + "\\" + n).Take(500)], read.Status == SourceStatus.Partial || read.Names.Length > 500, source.Clock.GetUtcNow());
    }

    public async Task<WmiClassList> ClassesAsync(Guid computer, string ns, string? filter, CancellationToken cancellationToken)
    {
        WqlRules.CheckClassFilter(filter);
        var (pc, read) = await MetadataAsync(computer, WmiMetadataKind.Classes, ns, null, cancellationToken).ConfigureAwait(false);
        var prefix = filter?.TrimEnd('*') ?? "";
        var names = read.Names.Where(n => prefix.Length == 0 || (filter!.EndsWith('*') ? n.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) : n.Equals(prefix, StringComparison.OrdinalIgnoreCase))).ToArray();
        return new(pc.Name, ns, filter, [.. names.Take(2000).Select(n => new Domenia.Core.Queries.WmiClassInfo(n, -1, -1,
            QueryProbeCatalog.MsiProviderClasses.Contains(n, StringComparer.OrdinalIgnoreCase) ? "Fournisseur MSI : instances interdites." : "Définition disponible ; propriétés et clés lues à son ouverture."))],
            read.Status == SourceStatus.Partial || names.Length > 2000, source.Clock.GetUtcNow());
    }

    public async Task<WmiClassSchema> SchemaAsync(Guid computer, string ns, string className, CancellationToken cancellationToken)
    {
        var (pc, read) = await MetadataAsync(computer, WmiMetadataKind.Properties, ns, className, cancellationToken).ConfigureAwait(false);
        return new(pc.Name, ns, className, read.Detail + (read.Status == SourceStatus.Partial ? " Schéma partiel ; aucune absence de propriété déduite." : ""),
            [.. read.Schema.Select(p => new WmiPropertyInfo(p.Name, p.Type, p.Key, "", p.Qualifiers))], [], source.Clock.GetUtcNow());
    }

    internal async Task<(DirectoryComputer Computer, WorkstationQueryRead Read)> ReadAsync(Guid guid, string ns, WqlSelect select, int limit, CancellationToken token, Action<DirectoryComputer>? onEngaged = null)
    {
        var checkedPlan = WmiWorkstationReader.CheckWorkshopSelect(ns, select, limit);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(65), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        using var access = await AdQueryAccess.OpenAsync(source, guid, stop.Token).ConfigureAwait(false);
        ExpectedIdentity?.Invoke(access.Computer);
        onEngaged?.Invoke(access.Computer);
        var read = await Reader(access).ReadWorkshopSelectAsync(access.Computer.DnsHostName!, ns, checkedPlan, limit, stop.Token, access.Machine.Credential).ConfigureAwait(false);
        CheckStatus(access, read.Status, read.AuthenticationRejected, read.Detail);
        await access.ConfirmAsync(read.ReportedName, stop.Token).ConfigureAwait(false);
        return (access.Computer, read);
    }

    public async Task<WmiSelectResult> SelectAsync(Guid computer, string ns, WqlSelect select, int limit, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch;
        var parsed = WmiWorkstationReader.CheckWorkshopSelect(ns, select, limit);
        var key = WqlRules.RequestKey(ns, parsed.CanonicalQuery);
        DirectoryComputer? engaged = null;
        try
        {
            var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
            engaged = local.Directory.Computers.SingleOrDefault(c => c.ObjectGuid == computer);
            var (pc, read) = await ReadAsync(computer, ns, parsed, limit, cancellationToken, pc => engaged = pc).ConfigureAwait(false);
            var (rows, truncated) = WmiWorkstationReader.WorkshopRows(read);
            var result = new WmiSelectResult(pc.Name, computer, ns, parsed.ClassName, parsed.CanonicalQuery, [.. read.Schema.Select(p => p.Name)], rows,
                truncated, rows.Length, read.At, key, read.Detail + (truncated ? " Nombre minimal reçu, total non confirmé." : " Lecture terminée ; nombre complet."));
            await AdQueryMemory.For(source).SaveAsync(pc, [], [new(key, read.At, true, rows.Length, !truncated, truncated)], epoch, cancellationToken).ConfigureAwait(false);
            Remember(result, epoch);
            return result;
        }
        catch (Exception ex) when (ex is DomeniaOperationException or IOException or OperationCanceledException)
        {
            Forget(computer);
            if (source.Epoch == epoch && engaged is not null)
            {
                var failure = AdQueryMemory.For(source).Invalidate(engaged, key, epoch);
                await AdQueryMemory.For(source).PersistFailureAsync(failure, ex).ConfigureAwait(false);
            }
            throw;
        }
    }
}
