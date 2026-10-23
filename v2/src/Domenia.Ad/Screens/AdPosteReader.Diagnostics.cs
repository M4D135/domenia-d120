using System.Collections.Immutable;
using System.Net.Sockets;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    internal Func<string, int, TimeSpan, CancellationToken, Task<bool?>>? PortOverride { get; init; }

    private async Task<bool?> PortAsync(string host, int port, TimeSpan timeout, CancellationToken token)
    {
        if (PortOverride is { } injected) { return await injected(host, port, timeout, token).ConfigureAwait(false); }
        if (token.IsCancellationRequested) { return null; }
        using var limit = new CancellationTokenSource(timeout, source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, limit.Token);
        using var client = new TcpClient();
        try { await client.ConnectAsync(host, port, stop.Token).ConfigureAwait(false); return true; }
        catch (SocketException) { return false; }
        catch (OperationCanceledException) { return token.IsCancellationRequested ? null : false; }
    }

    public async Task<QuickDiagResult> QuickDiagnosticAsync(string dn, CancellationToken cancellationToken)
    {
        var started = source.Clock.GetTimestamp();
        using var deadline = new CancellationTokenSource(CimBudgets.QuickDiagnostic, source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var local = await NetworkAsync(dn, stop.Token).ConfigureAwait(false);
        var timeout = TimeSpan.FromMilliseconds(Math.Min(configuration.PortTimeoutMs, 2000));
        // The three bare TCP openings are independent of the selected account and do not send application data.
        var ports = Task.WhenAll(new[] { 135, 445, 5985 }.Select(async p => (Port: p, Open: await PortAsync(local.Computer.DnsHostName!, p, timeout, stop.Token).ConfigureAwait(false))));
        InventorySnapshot read;
        try { read = await ReadAsync(local, WorkstationReading.QuickDiagnostic, null, stop.Token).ConfigureAwait(false); }
        catch { stop.Cancel(); await ports.ConfigureAwait(false); throw; }
        var portResults = await ports.ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var raw = QuickRaw(read, portResults.ToImmutableArray(), (int)Math.Clamp(source.Clock.GetElapsedTime(started).TotalMilliseconds, 0, int.MaxValue));
        return PosteDiagnostics.QuickFacts(local.Computer.Name, raw, source.Clock.GetUtcNow(), source.Zone, "Compte machine sélectionné");
    }

    internal static QuickDiagRaw QuickRaw(InventorySnapshot read, ImmutableArray<(int Port, bool? Open)> ports, int duration)
    {
        QuickRaw State(string category) => new(read.StatusOf(category), read.Access.FirstOrDefault(a => a.Category == category)?.Detail);
        var disk = read.Volumes.SingleOrDefault(d => d.Id.Equals("C:", StringComparison.OrdinalIgnoreCase));
        var services = read.Services.ToDictionary(s => s.Name, StringComparer.OrdinalIgnoreCase);
        var complete = read.StatusOf(InventoryCategories.Services) is SourceStatus.Ok or SourceStatus.Empty;
        return new(duration, State(InventoryCategories.System), read.Os?.Caption, read.Os?.Version, State(InventoryCategories.System), read.Os?.LastBoot,
            State(InventoryCategories.Volumes), disk?.FreeBytes, disk?.SizeBytes,
            new(ports.All(p => p.Open is not null) ? SourceStatus.Ok : SourceStatus.Partial, "Ouvertures TCP uniquement ; aucun protocole ni droit prouvé."), ports,
            State(InventoryCategories.Services), [.. PosteDiagnostics.QuickServices.Where(n => complete || services.ContainsKey(n)).Select(n =>
                services.TryGetValue(n, out var service) ? (n, true, (string?)service.State, (string?)service.StartMode) : (n, false, (string?)null, (string?)null))]);
    }

    public async Task<SlowTriage> SlowTriageAsync(string dn, PosteHealthPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        var read = await ReadAsync(local, WorkstationReading.Triage, null, cancellationToken).ConfigureAwait(false);
        var processes = read.ProcessSample;
        if (processes is not null && read.StatusOf(InventoryCategories.Processes) is not (SourceStatus.Ok or SourceStatus.Empty))
        { processes = processes with { TotalCpu = null }; }
        return PosteSlow.Triage(local.Computer.Name, read, processes, policy, source.Clock.GetUtcNow());
    }
}
