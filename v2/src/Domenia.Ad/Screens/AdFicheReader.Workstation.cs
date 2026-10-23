using System.Collections.Immutable;
using System.Net.NetworkInformation;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdFicheReader
{
    internal Func<string, CancellationToken, Task<InventorySnapshot>>? InventoryOverride { get; init; }

    private async Task<DirectoryComputer> ComputerAsync(string dn, CancellationToken token)
    {
        var epoch = await NetworkEpochAsync(dn, token).ConfigureAwait(false);
        var entry = await objects.ReadExactAsync(dn, AdDirectoryMapper.ComputerAttributes, TimeSpan.FromSeconds(10), token).ConfigureAwait(false)
            ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        var computer = entry.Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase) ? AdDirectoryMapper.Computer(entry) : null;
        if (computer is null) { throw FicheErrors.Error(FicheErrors.NotApplicable, "Cette lecture concerne un ordinateur."); }
        if (computer.DnsHostName is not { } host || !CimQuery.IsHostName(host)) { throw FicheErrors.Error(FicheErrors.Invalid, "Nom DNS du poste absent ou invalide : aucun appel distant."); }
        var domain = await source.DomainAsync(token).ConfigureAwait(false);
        await source.RememberObjectsAsync(new(domain, source.Clock.GetUtcNow(), false, [], [], [computer], []), epoch, token).ConfigureAwait(false);
        return computer;
    }

    public async Task<FicheObservation?> ObservationAsync(string computerDn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(computerDn);
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false);
        var computer = local?.Directory.Computers.FirstOrDefault(c => FicheValues.SameDn(c.DistinguishedName, computerDn));
        if (computer is null) { return null; }
        var reading = local!.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid);
        var machine = source.FleetDetails.Facts.Machines.GetValueOrDefault(computer.ObjectGuid);
        return new(computer.DistinguishedName, computer.Name, reading?.Presence.State ?? MeasureState.NotRead, reading?.Presence.Answered,
            reading?.Presence.CheckedAt, reading?.Presence.LastOnlineAt, machine?.ConsoleUser, machine?.ConsoleAt,
            reading?.Inventory.State ?? MeasureState.NotRead, reading?.Inventory.CheckedAt);
    }

    public async Task<FicheInventoryReading?> StoredInventoryAsync(string computerDn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(computerDn);
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false);
        var computer = local?.Directory.Computers.FirstOrDefault(c => FicheValues.SameDn(c.DistinguishedName, computerDn));
        return computer is not null && source.FleetDetails.Inventories.TryGetValue(computer.ObjectGuid, out var inventory)
            ? InventoryView(computer, inventory) : null;
    }

    public async Task<FichePresenceReading> PingAsync(string computerDn, CancellationToken cancellationToken)
    {
        var epoch = await NetworkEpochAsync(computerDn, cancellationToken).ConfigureAwait(false);
        var computer = await ComputerAsync(computerDn, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(epoch);
        var old = await ObservationAsync(computerDn, cancellationToken).ConfigureAwait(false);
        var at = source.Clock.GetUtcNow();
        PresenceMeasure measure;
        using var elapsed = new CancellationTokenSource(TimeSpan.FromMilliseconds(1500), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        using var ping = new Ping();
        try
        {
            var answer = await ping.SendPingAsync(computer.DnsHostName!, TimeSpan.FromMilliseconds(1200), null, null, budget.Token).ConfigureAwait(false);
            var answered = answer.Status == IPStatus.Success;
            measure = new(MeasureState.Known, answered, at, answered ? at : old?.LastOnlineAt);
        }
        catch (PingException) { measure = new(MeasureState.Error, null, at, old?.LastOnlineAt); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { measure = new(MeasureState.Incomplete, null, at, old?.LastOnlineAt); }
        await source.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(at, [new(computer.ObjectGuid, measure, InventoryMeasure.Unread)]) }, epoch, CancellationToken.None).ConfigureAwait(false);
        var state = measure.Answered == true ? "online" : measure.Answered == false ? "offline" : "unknown";
        return new(computerDn, computer.Name, state, measure.Answered == true ? "Répond au ping" : "Pas de réponse confirmée", at, measure.LastOnlineAt,
            old?.ConsoleUser, "Un seul ping ; absence de réponse ne prouve pas que le poste est arrêté.", null);
    }

    public async Task<FicheSessionsReading> SessionsAsync(string computerDn, CancellationToken cancellationToken)
    {
        var epoch = await NetworkEpochAsync(computerDn, cancellationToken).ConfigureAwait(false);
        var computer = await ComputerAsync(computerDn, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(epoch);
        if (source.Connection is not AdConnection actual) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Compte Windows du transport indisponible."); }
        var credential = actual.CopyCredential();
        WindowsSessionsRead read;
        using (credential.Password)
        { read = await new WindowsSessionsReader(source.Clock).ReadAsync(computer.DnsHostName!, credential.User, credential.Domain, credential.Password, cancellationToken).ConfigureAwait(false); }
        EnsureEpoch(epoch);
        var rows = read.Sessions.Where(s => !string.IsNullOrEmpty(s.User)).Select(s => new FicheSessionRow(string.IsNullOrEmpty(s.Domain) ? s.User! : s.Domain + "\\" + s.User,
            s.State, s.Protocol, PosteSessions.OpenedText(s.LogonAt, read.At, source.Zone), PosteSessions.IdleText(s.Idle))).ToImmutableArray();
        return new(computerDn, computer.Name, read.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial ? "read" : read.Status == SourceStatus.Refused ? "refused" : "failed",
            rows, read.Unread, read.At, read.Detail);
    }

    public async Task<FicheInventoryReading> InventoryAsync(string computerDn, CancellationToken cancellationToken)
    {
        var epoch = await NetworkEpochAsync(computerDn, cancellationToken).ConfigureAwait(false);
        var computer = await ComputerAsync(computerDn, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(epoch);
        if (InventoryOverride is null && source.Connection is not AdConnection { UsesWindowsIdentity: true })
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Le transport CIM doit utiliser le compte de connexion explicite ; aucun repli sur le compte Windows."); }
        var reading = InventoryOverride is { } injected ? await injected(computer.DnsHostName!, cancellationToken).ConfigureAwait(false)
            : await new WmiWorkstationReader(source.Clock).ReadAsync(computer.DnsHostName!, WorkstationReading.Triage, null, cancellationToken).ConfigureAwait(false);
        if (!string.Equals(reading.ReportedName, computer.Name, StringComparison.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité CIM absente ou différente du compte ordinateur : inventaire non associé."); }
        await source.SaveFleetAsync(AdSearchReader.MapInventory(computer.ObjectGuid, reading), epoch, CancellationToken.None).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        var saved = source.FleetDetails.Inventories.GetValueOrDefault(computer.ObjectGuid);
        return InventoryView(computer, saved ?? reading);
    }

    private static FicheInventoryReading InventoryView(DirectoryComputer computer, InventorySnapshot value)
    {
        var complete = !value.Interrupted && value.Access.All(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Skipped);
        var sample = value.ProcessSample;
        long? free = value.Memory?.FreeKb is >= 0 and <= long.MaxValue / 1024 and var kb ? kb * 1024 : null;
        return new(computer.DistinguishedName, computer.Name, value.Os is null && value.System is null ? "failed" : "read", value.CollectedAt,
            value.Processors.Any(p => p.LoadPercent is not null) ? value.Processors.Where(p => p.LoadPercent is not null).Average(p => (double)p.LoadPercent!.Value) : null,
            value.System?.TotalPhysicalMemory, free,
            [.. value.Volumes.Where(d => d.SizeBytes is >= 0 && d.FreeBytes is >= 0 && d.FreeBytes <= d.SizeBytes).Select(d => new FicheDisk(d.Id, d.SizeBytes!.Value, d.FreeBytes!.Value))],
            sample is null ? [] : [.. sample.Rows.Where(p => p.CpuPercent is not null && p.WorkingSetBytes is >= 0).Take(20).Select(p => new FicheProcess(p.Name, p.CpuPercent!.Value, p.WorkingSetBytes!.Value / 1048576d))],
            sample?.IntervalMs / 1000d, value.Os?.LastBoot,
            value.PendingReboot is null ? null : value.PendingReboot.Confirmed.Length > 0 ? "required" : value.PendingReboot.Partial.Length > 0 ? "partial" : "none",
            value.PendingReboot is null ? [] : [.. value.PendingReboot.Confirmed, .. value.PendingReboot.Partial], value.System?.Model, value.Os?.Caption,
            complete ? null : "Lecture partielle ; les sources non lues restent inconnues.") { SystemDrive = value.Os?.SystemDrive ?? "" };
    }
}
