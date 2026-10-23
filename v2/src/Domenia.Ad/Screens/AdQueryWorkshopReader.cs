using System.Collections.Immutable;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;
using QueryProbeReading = Domenia.Core.Queries.ProbeReading;

namespace Domenia.Ad;

public sealed class AdQueryWorkshopReader(AdDirectorySource source) : IQueryWorkshopReader
{
    internal Func<PosteConfiguration, WmiWorkstationReader>? InventoryReaderOverride { get; init; }
    internal Func<string, CancellationToken, Task<bool>>? PingOverride { get; init; }

    public async Task<QueryDataset> DatasetAsync(CancellationToken cancellationToken)
    {
        var epoch = source.Epoch;
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var fleet = source.FleetDetails;
        var stored = await AdQueryMemory.For(source).ReadAsync(epoch, cancellationToken).ConfigureAwait(false);
        var computers = local.Directory.Computers.ToDictionary(c => c.ObjectGuid);
        var qualified = stored.Computers.Where(c => computers.TryGetValue(c.Computer, out var pc) && pc.WhenCreated == c.Created && DistinguishedName.AreEqual(c.Dn, pc.DistinguishedName)).ToArray();
        var console = fleet.Facts.Machines.Where(p => computers.TryGetValue(p.Key, out var pc) && p.Value.ConsoleAt >= pc.WhenCreated && p.Value.ConsoleAt <= source.Clock.GetUtcNow())
            .ToImmutableDictionary(p => p.Key, p => new ConsoleReading(p.Value.ConsoleUser, p.Value.ConsoleAt, null));
        var bitlocker = ImmutableDictionary.CreateBuilder<Guid, char>();
        foreach (var pc in computers.Values)
        {
            var reading = fleet.Facts.BitLocker.Where(b => b.At >= pc.WhenCreated && b.At <= source.Clock.GetUtcNow() && b.Machines.ContainsKey(pc.ObjectGuid)).OrderByDescending(b => b.At).FirstOrDefault();
            if (reading is not null && reading.Machines[pc.ObjectGuid].Keys > 0) { bitlocker[pc.ObjectGuid] = 'O'; }
            // Zero visible recovery objects does not establish the encryption state of a workstation.
        }
        var stamp = string.Join("|", epoch, stored.Revision, stored.TransientRevision, local.Directory.ReadAt.UtcTicks, fleet.Observations.TakenAt?.UtcTicks,
            string.Join(";", fleet.Facts.Machines.OrderBy(p => p.Key).Select(p => p.Key + ":" + p.Value.ConsoleAt?.UtcTicks + ":" + p.Value.WmiAt?.UtcTicks)));
        var version = BitConverter.ToInt64(SHA256.HashData(Encoding.UTF8.GetBytes(stamp)), 0) & long.MaxValue;
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; données locales écartées."); }
        return new(local.Directory, fleet.Observations, qualified.ToImmutableDictionary(c => c.Computer, c => c.Probes), console,
            bitlocker.ToImmutable(), qualified.ToImmutableDictionary(c => c.Computer, c => c.Details), version, "Base locale du domaine · lectures datées et qualifiées", false);
    }

    public async Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Computers.IsDefaultOrEmpty || request.Computers.Length > 1000 || request.Computers.Any(g => g == Guid.Empty)
            || request.Computers.Distinct().Count() != request.Computers.Length || request.Probes.IsDefault || request.Probes.Length > QueryProbeCatalog.All.Length
            || request.Probes.Distinct(StringComparer.Ordinal).Count() != request.Probes.Length || request.DetailReads.Length > 32
            || !request.Presence && !request.Console && !request.Inventory && request.Probes.IsEmpty && request.DetailReads.IsEmpty)
        { throw new QueryDefinitionException("Collecte limitée à 1 000 postes identifiés, une demande par sonde et 32 SELECT."); }
        var probes = request.Probes.Select(p => QueryProbeCatalog.Find(p) ?? throw new QueryDefinitionException("Sonde inconnue ; aucun contact.")).ToArray();
        foreach (var detail in request.DetailReads) { WqlRules.CheckReadDefinition(detail); _ = WmiWorkstationReader.CheckWorkshopSelect(detail.Namespace, WqlRules.Parse(detail.CanonicalQuery), detail.Limit); }
        var epoch = source.Epoch;
        var local = (await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false)).Directory;
        var computers = request.Computers.Select(g => local.Computers.SingleOrDefault(c => c.ObjectGuid == g) ?? throw new QueryDefinitionException("Poste inconnu ; aucun contact.")).ToArray();
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(4), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var answered = 0; var failed = 0; var disabled = 0;
        var wmi = new AdQueryWmiReader(source) { InventoryReaderOverride = InventoryReaderOverride };
        foreach (var pc in computers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; collecte arrêtée."); }
            if (AdValues.IsDisabled(pc.UserAccountControl)) { disabled++; continue; }
            if (stop.IsCancellationRequested) { failed++; continue; }
            var ok = true;
            try
            {
                if (request.Presence)
                {
                    using var access = await AdQueryAccess.OpenAsync(source, pc.ObjectGuid, stop.Token).ConfigureAwait(false);
                    bool online;
                    if (PingOverride is { } ping) { online = await ping(access.Computer.DnsHostName!, stop.Token).ConfigureAwait(false); }
                    else { using var native = new Ping(); online = (await native.SendPingAsync(access.Computer.DnsHostName!, TimeSpan.FromSeconds(1), null, null, stop.Token).ConfigureAwait(false)).Status == IPStatus.Success; }
                    await access.ConfirmDirectoryAsync(stop.Token).ConfigureAwait(false); var at = source.Clock.GetUtcNow();
                    await source.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(at, [new(pc.ObjectGuid, new(MeasureState.Known, online, at, online ? at : null), InventoryMeasure.Unread)]) }, epoch, stop.Token).ConfigureAwait(false);
                }
                if (request.Inventory)
                {
                    var reading = await new AdRelationsReader(source) { InventoryReaderOverride = InventoryReaderOverride }.InventoryAsync(pc, WorkstationReading.Survey, null, stop.Token).ConfigureAwait(false);
                    if (WorkstationIdentity.Matches(pc, reading.Value.ReportedName))
                    { await source.SaveFleetAsync(AdSearchReader.MapInventory(pc.ObjectGuid, reading.Value), epoch, stop.Token).ConfigureAwait(false); }
                    ok &= !reading.Denied && reading.Value.StatusOf(InventoryCategories.System) == SourceStatus.Ok;
                }
                else if (request.Console)
                {
                    var reading = await new AdRelationsReader(source) { InventoryReaderOverride = InventoryReaderOverride }.ComputerSessionAsync(pc.DistinguishedName, pc.ObjectGuid, stop.Token).ConfigureAwait(false);
                    ok &= reading.ConsoleReadAt is not null;
                }
                foreach (var probe in probes)
                {
                    if (probe.SkipOnDc && (pc.UserAccountControl & AdValues.ServerTrustAccount) != 0)
                    { await AdQueryMemory.For(source).SaveAsync(pc, [new(probe.Id, source.Clock.GetUtcNow(), null, true, false, null, false, [])], [], epoch, stop.Token).ConfigureAwait(false); continue; }
                    var query = WqlRules.Parse("SELECT " + string.Join(", ", probe.Properties) + " FROM " + probe.Class + (probe.Filter.Length == 0 ? "" : " WHERE " + probe.Filter));
                    var (engaged, read) = await wmi.ReadAsync(pc.ObjectGuid, probe.Namespace, query, probe.Mode == "First" ? 1 : 500, stop.Token, actual =>
                    {
                        if (actual.WhenCreated != pc.WhenCreated || !DistinguishedName.AreEqual(actual.DistinguishedName, pc.DistinguishedName))
                        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Poste déplacé ou recréé depuis la préparation de la collecte."); }
                    }).ConfigureAwait(false);
                    var instances = read.Rows.Select((r, i) => new ProbeInstance(i.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        probe.Properties.ToImmutableDictionary(p => p, p => r.Raw(p), StringComparer.OrdinalIgnoreCase), ImmutableArray<string>.Empty)).ToImmutableArray();
                    // A first-instance probe intentionally stops at one item; its value is usable, never a complete collection count.
                    var truncated = !read.Complete && probe.Mode != "First";
                    var stored = new QueryProbeReading(probe.Id, read.At, null, false, truncated, instances.Length, read.Complete, instances);
                    await AdQueryMemory.For(source).SaveAsync(engaged, [stored], [], epoch, stop.Token).ConfigureAwait(false); ok &= !truncated;
                }
                foreach (var detail in request.DetailReads)
                { var result = await wmi.SelectAsync(pc.ObjectGuid, detail.Namespace, WqlRules.Parse(detail.CanonicalQuery), detail.Limit, stop.Token).ConfigureAwait(false); ok &= !result.Truncated; }
            }
            catch (Exception ex) when (ex is DomeniaOperationException or QueryDefinitionException or PingException or IOException or OperationCanceledException)
            {
                if (source.Epoch != epoch) { throw; }
                ok = false;
                // A fresh failed attempt supersedes old successful criteria; it must not silently renew their age.
                var at = source.Clock.GetUtcNow();
                var memory = AdQueryMemory.For(source);
                var failure = memory.Invalidate(pc,
                    [.. probes.Select(p => new QueryProbeReading(p.Id, at, "Collecte interrompue ou source non lue ; relancer explicitement.", false, false, null, false, []))],
                    [.. request.DetailReads.Select(d => new StoredWmiResult(d.RequestKey, at, false, 0, false, false))], epoch);
                await memory.PersistFailureAsync(failure, ex).ConfigureAwait(false);
                if (cancellationToken.IsCancellationRequested) { throw; }
            }
            if (ok) { answered++; } else { failed++; }
        }
        var dataset = await DatasetAsync(cancellationToken).ConfigureAwait(false);
        return new(computers.Length, answered, failed, disabled, dataset.Version, source.Clock.GetUtcNow());
    }
}
