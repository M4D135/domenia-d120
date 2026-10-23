using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed record WorkstationEventsReading(string? ReportedName, DateTimeOffset At, SourceStatus Status, ImmutableArray<EventEntry> Events, string Detail)
{
    public bool AuthenticationRejected { get; init; }
}

public sealed partial class WmiWorkstationReader
{
    public async Task<WorkstationEventsReading> ReadEventsAsync(string host, EventQuery query, CancellationToken cancellationToken, RemoteProbeCredential? credential = null)
    {
        _ = WsmanReadChannel.CheckedEventPreset(query);
        if (!CimQuery.IsHostName(host)) { throw new ArgumentException("Nom de poste invalide.", nameof(host)); }
        var budget = TimeSpan.FromSeconds(30);
        var latest = new WorkstationEventsReading(null, clock.GetUtcNow(), SourceStatus.Interrupted, [], "Lecture non commencée.");
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<WorkstationEventsReading> work;
        try
        {
            work = WmiReadWorkers.Start(credential, owned =>
            {
                using var session = Session(host, budget, stop.Token, owned);
                var identity = session.Read(InventoryCategories.System, Cimv2, "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
                var name = identity.Instances.FirstOrDefault()?.Text("Name");
                var result = latest with { ReportedName = name, Status = identity.Status, Detail = identity.Detail, AuthenticationRejected = identity.AuthenticationRejected };
                Volatile.Write(ref latest, result);
                if (name is null) { return result with { Status = identity.Answered ? SourceStatus.Unavailable : identity.Status, Detail = "Identité Windows non lue ; événements non demandés." }; }
                if (!name.Equals(host.Split('.')[0], StringComparison.OrdinalIgnoreCase))
                { return result with { Status = SourceStatus.Error, Detail = "Identité Windows différente ; événements non demandés." }; }
                WorkstationEventsReading Project(CimReading read) => result with
                {
                    Status = read.Status, Detail = read.Detail, AuthenticationRejected = read.AuthenticationRejected,
                    Events = [.. read.Instances.Select(row => new EventEntry(row.Int("Id")!.Value, row.Text("Provider")!, row.Text("Log")!,
                        EventLevel(row.Int("Level")), CimSession.UtcDate(row.Text("At"))!.Value, row.Text("Machine"), null, row.Text("Message") ?? ""))],
                };
                var reading = session.ReadEvents(query, part => Volatile.Write(ref latest, Project(part)));
                var final = Project(reading); Volatile.Write(ref latest, final); return final;
            }, stop.Token);
        }
        catch { stop.Dispose(); throw; }
        try { return await work.WaitAsync(budget + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            stop.Cancel();
            _ = work.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            var partial = Volatile.Read(ref latest);
            return partial with { Status = partial.Events.IsEmpty ? SourceStatus.Interrupted : SourceStatus.Partial, Detail = "Lecture arrêtée ou budget atteint ; événements déjà reçus conservés, période incomplète." };
        }
        finally { DisposeAfter(work, stop); }
    }

    private static string EventLevel(int? level) => level switch { 0 => "Journalisation", 1 => "Critique", 2 => "Erreur", 3 => "Avertissement", 4 => "Information", 5 => "Détaillé", _ => "Non lu" };
}
