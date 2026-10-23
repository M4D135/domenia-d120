using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public enum UserDetectionSource { Console, LogonUi, Profiles }
public sealed record WorkstationUserCandidate(string? Account, string? Sid, DateTimeOffset? EvidenceAt, string Origin);
public sealed record WorkstationUserReading(string? ReportedName, SourceAccess Access, ImmutableArray<WorkstationUserCandidate> Candidates);

public sealed partial class WmiWorkstationReader
{
    /// <summary>One closed source, at most six seconds, without scripts, profile mounting or service changes.</summary>
    public async Task<WorkstationUserReading> ReadUserSourceAsync(string host, UserDetectionSource kind, CancellationToken token, RemoteProbeCredential? credential = null)
    {
        if (!CimQuery.IsHostName(host) || !Enum.IsDefined(kind)) { throw new ArgumentException("Source de détection invalide."); }
        var budget = TimeSpan.FromSeconds(6);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        var began = clock.GetTimestamp();
        Task<WorkstationUserReading> work;
        try { work = WmiReadWorkers.Start(credential, owned =>
        {
            using var session = Session(host, budget, stop.Token, owned);
            return ReadUserSource(session, kind, clock.GetUtcNow());
        }, token); }
        catch { stop.Dispose(); throw; }
        try { return await work.WaitAsync(budget, clock, token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is OperationCanceledException or TimeoutException)
        {
            stop.Cancel();
            return new(null, new(kind.ToString(), SourceStatus.Interrupted, "Lecture arrêtée ou délai atteint ; aucun candidat reçu.",
                (int)clock.GetElapsedTime(began).TotalMilliseconds, 0, transport), []);
        }
        finally { DisposeAfter(work, stop); }
    }

    private static WorkstationUserReading ReadUserSource(CimSession session, UserDetectionSource kind, DateTimeOffset now)
    {
        var identity = session.Read("user.identity", Cimv2, "SELECT Name, UserName FROM Win32_ComputerSystem", 2, TimeSpan.FromSeconds(3));
        var name = identity.Status == SourceStatus.Ok && identity.Items == 1 ? identity.Instances[0].Text("Name") : null;
        if (!string.Equals(session.Host.Split('.')[0], name, StringComparison.OrdinalIgnoreCase))
        {
            return new(name, identity.ToAccess(session.Transport) with { Status = identity.Answered ? SourceStatus.Unavailable : identity.Status,
                Detail = "Identité Windows non confirmée ; aucune autre source interrogée." }, []);
        }
        if (kind == UserDetectionSource.Console)
        {
            var account = identity.Instances[0].Text("UserName");
            var present = identity.Instances[0].Names.Contains("UserName", StringComparer.OrdinalIgnoreCase);
            return new(name, identity.ToAccess(session.Transport) with { Status = present ? account is null ? SourceStatus.Empty : SourceStatus.Ok : SourceStatus.Partial,
                Detail = present ? "Compte de console à la date de lecture ; SID du jeton non lu." : "Attribut utilisateur absent de la réponse ; console non déterminée." },
                account is null ? [] : [new(account, null, now, "Win32_ComputerSystem.UserName")]);
        }
        if (kind == UserDetectionSource.LogonUi)
        {
            var candidates = ImmutableArray.CreateBuilder<WorkstationUserCandidate>();
            var readings = new List<RegistryReading>();
            foreach (var attribute in new[] { "LastLoggedOnSAMUser", "LastLoggedOnUser" })
            {
                var read = session.ReadRegistry(new(InventoryRegistry.Machine, InventoryRegistry.LogonUi, attribute, RegistryMethod.String), TimeSpan.FromSeconds(2));
                readings.Add(read);
                if (read.Answered && read.Text is { } text) { candidates.Add(new(text, null, null, "LogonUI." + attribute)); }
                if (read.AuthenticationRejected || read.Status == SourceStatus.Interrupted) { break; }
            }
            var failure = readings.FirstOrDefault(r => !r.Answered);
            return new(name, new(kind.ToString(), failure is null ? candidates.Count > 0 ? SourceStatus.Ok : SourceStatus.Empty
                : candidates.Count > 0 ? SourceStatus.Partial : failure.Status,
                "Derniers noms affichés par LogonUI ; date de connexion et SID inconnus.", readings.Sum(r => r.DurationMs), candidates.Count, session.Transport)
                { AuthenticationRejected = readings.Any(r => r.AuthenticationRejected) }, candidates.ToImmutable());
        }
        // A profile directory name is not an account identity. Only an explicit SID and a valid last-use timestamp are candidates.
        var profiles = session.Read("user.profiles", Cimv2, "SELECT SID, LastUseTime, Special FROM Win32_UserProfile", 129, TimeSpan.FromSeconds(3));
        var eligible = profiles.Instances.Where(p => p.Bool("Special") == false && p.Text("SID") is { } sid && AccountsRules.IsDomainSid(sid)
            && p.Dmtf("LastUseTime") is { } at && at <= now && at != DateTimeOffset.MinValue).ToArray();
        var duplicate = eligible.GroupBy(p => p.Text("SID"), StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var chosen = eligible.Where(p => !duplicate.Contains(p.Text("SID"))).OrderByDescending(p => p.Dmtf("LastUseTime")).Take(5).ToArray();
        var status = profiles.Status;
        if (profiles.Answered && (profiles.Items > 128 || duplicate.Count > 0 || eligible.Length < profiles.Instances.Count(p => p.Bool("Special") != true))) { status = SourceStatus.Partial; }
        return new(name, profiles.ToAccess(session.Transport) with { Status = status, Detail = "Cinq profils récents au plus, par SID ; historique d’utilisation, pas une session actuelle." },
            [.. chosen.Select(p => new WorkstationUserCandidate(null, p.Text("SID"), p.Dmtf("LastUseTime"), "Win32_UserProfile.SID/LastUseTime"))]);
    }
}
