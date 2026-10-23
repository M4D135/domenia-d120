using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Optional local Security history; event timestamps and user SIDs remain distinct from a current console.</summary>
public sealed class WindowsLastUserEventsReader(TimeProvider clock)
{
    internal WindowsRelationEventsReader? EventReaderOverride { get; init; }

    public async Task<WorkstationUserReading> ReadAsync(string host, DateTimeOffset computerCreated, PosteConfiguration configuration,
        RemoteProbeCredential credential, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(configuration); ArgumentNullException.ThrowIfNull(credential);
        const string category = "Security";
        if (!configuration.UseSecurityLog)
        { return new(null, new(category, SourceStatus.Skipped, "Journal Sécurité désactivé par Remote.UseSecurityLog ; aucun contact.", 0, 0, InventoryTransport.EventLog), []); }
        var now = clock.GetUtcNow(); var start = clock.GetTimestamp();
        if (!CimQuery.IsHostName(host) || !host.Contains('.') || computerCreated == DateTimeOffset.MinValue || computerCreated >= now)
        { throw new ArgumentException("Identité ou date du poste invalide pour le journal."); }
        var from = computerCreated > now.AddDays(-30) ? computerCreated : now.AddDays(-30);
        var request = new RelationLogRequest(host, from, now, 40) { WorkstationInteractive = true };
        var read = await (EventReaderOverride ?? new WindowsRelationEventsReader(clock)).ReadAsync(request, credential, token).ConfigureAwait(false);
        return Project(host, request, read, (int)clock.GetElapsedTime(start).TotalMilliseconds);
    }

    internal static WorkstationUserReading Project(string host, RelationLogRequest request, RelationLogReading reading, int duration)
    {
        var candidates = ImmutableArray.CreateBuilder<WorkstationUserCandidate>();
        foreach (var row in reading.Events.Where(e => e.EventId == 4624 && e.LogonType is 2 or 10 or 11 && e.At >= request.From && e.At <= request.To)
            .OrderByDescending(e => e.At).ThenByDescending(e => e.RecordId))
        {
            // A 4624's source workstation can be empty or another client; its journal identity was checked by the native mapper.
            if (row.UserSid is not { } sid || !AccountsRules.IsDomainSid(sid) || row.Account is not { Length: > 0 and <= 320 }) { continue; }
            var account = row.Account.Contains('\\') || row.Account.Contains('@') ? row.Account
                : row.Domain is { Length: > 0 } domain ? domain + "\\" + row.Account : null;
            if (account is not null && !CredentialRules.IsWellFormed(account)) { continue; }
            if (candidates.Any(c => c.Sid == sid)) { continue; }
            candidates.Add(new(account, sid, row.At, "Journal Sécurité 4624 (type " + row.LogonType + ")"));
            if (candidates.Count == 5) { break; }
        }
        return new(reading.Events.IsEmpty ? null : host.Split('.')[0], new("Security", reading.Status,
            reading.Detail + " Historique d’ouvertures interactives ; aucune session actuelle déduite.", duration, reading.Read, InventoryTransport.EventLog)
            { AuthenticationRejected = reading.AuthenticationRejected }, candidates.ToImmutable());
    }
}
