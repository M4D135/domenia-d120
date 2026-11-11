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
    internal WorkstationPresenceReader? PresenceReaderOverride { get; init; }
    internal Action? DatasetReadObserved { get; init; }

    public async Task<QueryDataset> DatasetAsync(CancellationToken cancellationToken)
    {
        DatasetReadObserved?.Invoke();
        var epoch = source.Epoch;
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var fleet = source.FleetDetails;
        var stored = await AdQueryMemory.For(source).ReadAsync(epoch, cancellationToken).ConfigureAwait(false);
        var computers = local.Directory.Computers.ToDictionary(c => c.ObjectGuid);
        var qualified = stored.Computers.Where(c => computers.TryGetValue(c.Computer, out var pc) && pc.WhenCreated == c.Created
            && DistinguishedName.AreEqual(c.Dn, pc.DistinguishedName) && (c.Identity is null || c.Identity.Matches(pc))).ToArray();
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
        return new(local.Directory, fleet.Observations, qualified.ToImmutableDictionary(c => c.Computer,
                c => c.Probes.Where(p => p.Identity is null || p.Identity.Matches(computers[c.Computer])).ToImmutableArray()), console,
            bitlocker.ToImmutable(), qualified.ToImmutableDictionary(c => c.Computer, c => c.Details), version, "Base locale du domaine · lectures datées et qualifiées", false);
    }

    public async Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Computers.IsDefaultOrEmpty || request.Computers.Length > 1000 || request.Computers.Any(g => g == Guid.Empty)
            || request.Computers.Distinct().Count() != request.Computers.Length || request.Probes.IsDefault || request.Probes.Length > QueryProbeCatalog.All.Length + Domenia.Core.Accueil.PersonalProbeCatalog.Capacity
            || request.Probes.Distinct(StringComparer.Ordinal).Count() != request.Probes.Length || request.DetailReads.Length > 32
            || !request.Presence && !request.Console && !request.Inventory && request.Probes.IsEmpty && request.DetailReads.IsEmpty)
        { throw new QueryDefinitionException("Collecte limitée à 1 000 postes identifiés, une demande par sonde et 32 SELECT."); }
        request.ValidateTargetMeasures();
        if (!request.OwnsCampaign && source.AccountContext is { } collectionContext)
            CollectionAdmission.EnsureTargets(CollectionAdmission.Read(collectionContext.Preferences), request.Computers.Length);
        var catalog = QueryPersonalProbes.ForRequest(request);
        if (catalog.Definitions.Length > 0)
        {
            var preferences = source.AccountContext?.Preferences ?? throw new QueryDefinitionException("Profil de sondes indisponible ; aucun contact.");
            await ProfileProbeCatalog.ConfirmAsync(preferences, catalog.Definitions, cancellationToken).ConfigureAwait(false);
        }
        if (request.Probes.Any(p => catalog.Find(p) is null)) { throw new QueryDefinitionException("Sonde inconnue ; aucun contact."); }
        foreach (var detail in request.DetailReads) { WqlRules.CheckReadDefinition(detail); _ = WmiWorkstationReader.CheckWorkshopSelect(detail.Namespace, WqlRules.Parse(detail.CanonicalQuery), detail.Limit); }
        var epoch = source.Epoch;
        if (request.ExpectedEpoch is { } expectedEpoch && epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée depuis le plan ; aucun contact."); }
        var accountVersion = request.ExpectedAccountVersion ?? (source.AccountContext is { } accounts ? AccountAccess.From(accounts).SelectionVersion : (long?)null);
        var machineGeneration = request.ExpectedMachineGeneration ?? (source.AccountContext is { } machines ? MachineAccountService.From(machines).Generation : (long?)null);
        void ConfirmAccounts()
        {
            if (accountVersion is { } expectedAccount && (source.AccountContext is not { } accountContext || AccountAccess.From(accountContext).SelectionVersion != expectedAccount)
                || machineGeneration is { } expectedMachine && (source.AccountContext is not { } machineContext || MachineAccountService.From(machineContext).Generation != expectedMachine))
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Sélection des comptes modifiée depuis le plan ; aucune nouvelle source contactée.");
        }
        ConfirmAccounts();
        void ConfirmExpected(DirectoryComputer pc)
        {
            if (request.ExpectedIdentities is { } identities && (!identities.TryGetValue(pc.ObjectGuid, out var identity) || !identity.Matches(pc)))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité différente de celle du plan ; aucun contact avec ce poste."); }
        }
        var local = (await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false)).Directory;
        var index = AdComputerIndex.For(local);
        var computers = request.Computers.Select(g => index.Find(g) ?? throw new QueryDefinitionException("Poste absent ou ambigu ; aucun contact.")).ToArray();
        foreach (var pc in computers) { ConfirmExpected(pc); }
        if (request.OwnsCampaign && source.LocalStore is IOperationsLocalStore claimedStore
            && (request.ExpectedEpoch != epoch || !await claimedStore.HasOperationsLeaseAsync(cancellationToken).ConfigureAwait(false)))
        { throw new DomeniaOperationException("operations.surveyBusy", "Bail de la campagne absent ou session modifiée ; aucune sonde envoyée."); }
        // Keep one verified backup handle for this bounded request. Home campaigns already own this
        // lease across their workers; reacquiring it would refuse their nested query reads.
        using var collectionLease = !request.OwnsCampaign && source.LocalStore is IOperationsLocalStore operationStore
            ? await operationStore.AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false) : null;
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(4), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var answered = 0; var failed = 0; var disabled = 0; var notRead = 0;
        (long Account, long Machine)? spentOneShot = null;
        void RememberSingleUse(bool used)
        {
            if (used && source.AccountContext is { } context)
                spentOneShot = (AccountAccess.From(context).SelectionVersion, MachineAccountService.From(context).Generation);
        }
        void ConfirmSpentSelection()
        {
            if (spentOneShot is { } spent && (source.AccountContext is not { } context || AccountAccess.From(context).SelectionVersion != spent.Account
                || MachineAccountService.From(context).Generation != spent.Machine))
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié après le relevé autorisé ; collecte arrêtée sans nouveau contact.");
        }
        var wmi = new AdQueryWmiReader(source) { InventoryReaderOverride = InventoryReaderOverride, ExpectedIdentity = ConfirmExpected,
            ExpectedAccountVersion = accountVersion, ExpectedMachineGeneration = machineGeneration };
        foreach (var pc in computers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; collecte arrêtée."); }
            if (spentOneShot is not null)
            {
                ConfirmSpentSelection();
                if (AdValues.IsDisabled(pc.UserAccountControl)) { disabled++; }
                else { failed++; notRead++; }
                continue;
            }
            ConfirmAccounts();
            if (AdValues.IsDisabled(pc.UserAccountControl)) { disabled++; continue; }
            if (stop.IsCancellationRequested) { failed++; continue; }
            var selection = request.ForComputer(pc.ObjectGuid);
            var selectedProbes = selection.Probes.Select(p => catalog.Find(p)!).ToArray();
            var ok = true;
            var savedProbes = new HashSet<string>(StringComparer.Ordinal);
            var savedDetails = new HashSet<string>(StringComparer.Ordinal);
            try
            {
                var needsMachine = selection.Inventory || selection.Console || selection.DetailReads.Length > 0
                    || selectedProbes.Any(p => !p.SkipOnDc || (pc.UserAccountControl & AdValues.ServerTrustAccount) == 0);
                // One selected pair owns every source for this workstation. A one-shot is consumed once,
                // remains held through the physical native work and never falls back between sources.
                using var access = needsMachine ? await AdQueryAccess.OpenAsync(source, pc.ObjectGuid, stop.Token,
                    accountVersion, machineGeneration).ConfigureAwait(false) : null;
                if (access is not null) { ConfirmExpected(access.Computer); RememberSingleUse(access.Held.SingleUse); }
                if (!selection.PersonalProbes.IsDefaultOrEmpty)
                    await ProfileProbeCatalog.ConfirmAsync(source.AccountContext!.Preferences, selection.PersonalProbes, stop.Token).ConfigureAwait(false);
                // Freeze relative filters once. Personal probes remain outside the shared inventory plan until their
                // own native role check; no extra personal property can escape through the initial identity read.
                var probeAt = source.Clock.GetUtcNow();
                var probeSelects = selectedProbes.ToDictionary(p => p.Id, p => QueryPersonalProbes.Select(p, probeAt), StringComparer.Ordinal);
                var projections = selectedProbes.Where(p => catalog.Definition(p.Id) is null && !(p.SkipOnDc && (pc.UserAccountControl & AdValues.ServerTrustAccount) != 0))
                    .Select(p => new CimProjection(p.Namespace, probeSelects[p.Id].CanonicalQuery, p.Mode == "First" ? 1 : 500))
                    .Concat(selection.Inventory ? WmiWorkstationReader.SurveyProjections : [])
                    .Concat(selection.DetailReads.Select(d => new CimProjection(d.Namespace, d.CanonicalQuery, d.Limit)));
                using var sharedProjections = access is null ? null : new CimProjectionScope(access.Computer.DnsHostName!, access.Machine.Settings.ReadCimTransport,
                    access.Machine.Credential, projections, access.EnsureCurrent,
                    () => { if (source.AccountContext is { } metrics) { OperationActivity.From(metrics).RecordGroupedCimReuse(); } });
                if (selection.Presence)
                {
                    // ICMP alone needs the selected directory qualification, never a machine credential.
                    var preview = access is null && source.AccountContext is { } pingContext
                        ? await AccountAccess.From(pingContext).PreviewDirectoryReadAsync(CredentialRules.Directory, pc.DistinguishedName, stop.Token).ConfigureAwait(false)
                        : (DirectoryReadPreview?)null;
                    using var pingDirectory = access is null ? await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, pc.DistinguishedName,
                        stop.Token, expectedSelectionVersion: accountVersion ?? preview?.SelectionVersion).ConfigureAwait(false) : null;
                    RememberSingleUse(preview?.OneShot == true);
                    var target = access?.Computer ?? await AdQueryAccess.QualifyAsync(source, pingDirectory!, pc, stop.Token).ConfigureAwait(false);
                    if (!QueryComputerIdentity.Of(pc).Matches(target)) throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité modifiée avant le ping ; aucun contact ICMP.");
                    ConfirmExpected(target);
                    var lastOnline = source.CurrentObservations.Find(pc.ObjectGuid)?.Presence.LastOnlineAt;
                    PresenceMeasure presence;
                    if (PingOverride is { } ping)
                    {
                        var online = await ping(target.DnsHostName!, stop.Token).ConfigureAwait(false);
                        var checkedAt = source.Clock.GetUtcNow();
                        presence = new(MeasureState.Known, online, checkedAt, online ? checkedAt : lastOnline);
                    }
                    else presence = await (PresenceReaderOverride ?? new WorkstationPresenceReader(source.Clock, source.AccountContext?.Log))
                        .ReadAsync(target.DnsHostName!, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(1), lastOnline, stop.Token).ConfigureAwait(false);
                    if (access is not null) { await access.ConfirmDirectoryAsync(stop.Token).ConfigureAwait(false); }
                    else if (!QueryComputerIdentity.Of(pc).Matches(await AdQueryAccess.QualifyAsync(source, pingDirectory!, pc, stop.Token).ConfigureAwait(false)))
                        throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité modifiée pendant le ping ; mesure écartée.");
                    var at = source.Clock.GetUtcNow();
                    await source.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(at, [new(pc.ObjectGuid, presence, InventoryMeasure.Unread)]) }, epoch, stop.Token).ConfigureAwait(false);
                    if (!presence.HasReading || needsMachine && !CollectionNetworkPolicy.Eligible(presence, CollectionNetworkPolicy.Read(source.AccountContext?.Preferences)))
                        throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, presence.Diagnostic?.Text ?? "Présence non confirmée ; aucune source suivante contactée.");
                }
                if (selection.Inventory)
                {
                    var reading = await new AdRelationsReader(source) { InventoryReaderOverride = InventoryReaderOverride }
                        .InventoryAsync(pc, WorkstationReading.Survey, null, stop.Token, awaitPhysicalCompletion: true,
                            retainedAccess: access!.Held).ConfigureAwait(false);
                    if (WorkstationIdentity.Matches(pc, reading.Value.ReportedName, reading.Value.HostIdentity))
                    { await source.SaveFleetAsync(AdSearchReader.MapInventory(pc.ObjectGuid, reading.Value), epoch, CancellationToken.None).ConfigureAwait(false); }
                    // The stopped reader can return received values only so that this local receipt finishes.
                    // It must not launch the next source or report a successful collection afterwards.
                    stop.Token.ThrowIfCancellationRequested();
                    ok &= !reading.Denied && reading.Value.StatusOf(InventoryCategories.System) == SourceStatus.Ok;
                }
                else if (selection.Console)
                {
                    var reading = await new AdRelationsReader(source) { InventoryReaderOverride = InventoryReaderOverride }.ComputerSessionAsync(QueryComputerIdentity.Of(pc), stop.Token,
                        retainedAccess: access!.Held).ConfigureAwait(false);
                    ok &= reading.ConsoleReadAt is not null;
                }
                foreach (var probe in selectedProbes)
                {
                    var personal = catalog.Definition(probe.Id);
                    if (personal is not null)
                    { await ProfileProbeCatalog.ConfirmAsync(source.AccountContext!.Preferences, [personal], stop.Token).ConfigureAwait(false); }
                    if (probe.SkipOnDc && (pc.UserAccountControl & AdValues.ServerTrustAccount) != 0)
                    {
                        await AdQueryMemory.For(source).SaveAsync(pc, [new(probe.Id, source.Clock.GetUtcNow(), null, true, false, null, false, []) { PersonalDeclaration = probe.PersonalDeclaration }], [], epoch, stop.Token).ConfigureAwait(false);
                        savedProbes.Add(probe.Id); continue;
                    }
                    var query = probeSelects[probe.Id];
                    var (engaged, read) = await wmi.ReadAsync(pc.ObjectGuid, probe.Namespace, query, probe.Mode == "First" ? 1 : 500, stop.Token, actual =>
                    {
                        if (actual.WhenCreated != pc.WhenCreated || !DistinguishedName.AreEqual(actual.DistinguishedName, pc.DistinguishedName))
                        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Poste déplacé ou recréé depuis la préparation de la collecte."); }
                    }, awaitPhysicalCompletion: true, personalProbe: personal, probeAt: probeAt, retainedAccess: access!).ConfigureAwait(false);
                    var instances = read.Rows.Select((r, i) => new ProbeInstance(i.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        probe.Properties.ToImmutableDictionary(p => p, p => r.Raw(p), StringComparer.OrdinalIgnoreCase), ImmutableArray<string>.Empty)).ToImmutableArray();
                    // A first-instance probe intentionally stops at one item; its value is usable, never a complete collection count.
                    var truncated = !read.Complete && probe.Mode != "First";
                    var stored = new QueryProbeReading(probe.Id, read.At, null, false, truncated, instances.Length, read.Complete, instances)
                    { PersonalDeclaration = probe.PersonalDeclaration };
                    if (personal is not null) { await ProfileProbeCatalog.ConfirmAsync(source.AccountContext!.Preferences, [personal], stop.Token).ConfigureAwait(false); }
                    access!.EnsureCurrent();
                    await AdQueryMemory.For(source).SaveAsync(engaged, [stored], [], epoch, stop.Token).ConfigureAwait(false);
                    savedProbes.Add(probe.Id); ok &= !truncated;
                }
                foreach (var detail in selection.DetailReads)
                {
                    var result = await wmi.SelectCampaignAsync(pc.ObjectGuid, detail.Namespace, WqlRules.Parse(detail.CanonicalQuery), detail.Limit, stop.Token, retainedAccess: access!).ConfigureAwait(false);
                    savedDetails.Add(detail.RequestKey); ok &= !result.Truncated;
                }
            }
            catch (Exception ex) when (ex is DomeniaOperationException or QueryDefinitionException or PingException or IOException or OperationCanceledException)
            {
                if (source.Epoch != epoch) { throw; }
                ok = false;
                // Invalidate only unfinished sources. Values already qualified and saved earlier in this attempt
                // keep their original date; the stop of a later source cannot erase those real measurements.
                var at = source.Clock.GetUtcNow();
                var memory = AdQueryMemory.For(source);
                var failure = memory.Invalidate(pc,
                    [.. selectedProbes.Where(p => !savedProbes.Contains(p.Id)).Select(p => new QueryProbeReading(p.Id, at, "Collecte interrompue ou source non lue ; relancer explicitement.", false, false, null, false, []) { PersonalDeclaration = p.PersonalDeclaration })],
                    [.. selection.DetailReads.Where(d => !savedDetails.Contains(d.RequestKey)).Select(d => new StoredWmiResult(d.RequestKey, at, false, 0, false, false))], epoch);
                await memory.PersistFailureAsync(failure, ex).ConfigureAwait(false);
                if (cancellationToken.IsCancellationRequested) { throw; }
                if (ex is DomeniaOperationException { Code: AccountAccess.EpochChanged })
                    throw new DomeniaOperationException(AccountAccess.EpochChanged, ex.Message + " Collecte arrêtée : les mesures déjà qualifiées sont conservées ; aucun poste suivant contacté.");
                if (spentOneShot is not null) { ConfirmSpentSelection(); }
                else { ConfirmAccounts(); }
            }
            if (ok) { answered++; } else { failed++; }
        }
        var version = request.OnlyOutcome ? 0 : (await DatasetAsync(cancellationToken).ConfigureAwait(false)).Version;
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; bilan de collecte écarté."); }
        ConfirmSpentSelection();
        if (spentOneShot is null) { ConfirmAccounts(); }
        return new(computers.Length, answered, failed, disabled, version, source.Clock.GetUtcNow())
        { NotRead = notRead, StopReason = notRead > 0 ? "Bail à usage unique consommé par le premier poste : les cibles suivantes n’ont pas été contactées. Préparez une nouvelle collecte avec le compte voulu." : null };
    }
}
