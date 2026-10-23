using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Bounded CIM fallback for logon sessions. Never infers a WTS state, protocol, idle time or desktop session id.</summary>
public sealed class WmiLogonSessionsReader(TimeProvider clock)
{
    public static bool NeedsFallback(WindowsSessionsRead reading) => !reading.AuthenticationRejected
        && reading.Status is not (SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial);

    public async Task<WindowsSessionsRead> ReadAsync(string host, RemoteProbeCredential credential, TimeSpan budget, CancellationToken token)
    {
        if (budget <= TimeSpan.Zero) { return new(SourceStatus.Interrupted, [], 0, clock.GetUtcNow(), "Budget des sessions atteint avant le repli CIM."); }
        var bounded = budget > TimeSpan.FromSeconds(5) ? TimeSpan.FromSeconds(5) : budget;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        Task<WindowsSessionsRead> worker;
        try { worker = WmiReadWorkers.Start(credential, owned => Read(new CimSession(host, bounded, clock, cancellationToken: stop.Token, credential: owned)), stop.Token); }
        catch { stop.Dispose(); throw; }
        try { return await worker.WaitAsync(bounded, clock, token).ConfigureAwait(false); }
        catch (TimeoutException) { stop.Cancel(); return new(SourceStatus.Interrupted, [], 0, clock.GetUtcNow(), "Budget du repli CIM atteint ; sessions non établies."); }
        catch (OperationCanceledException) { stop.Cancel(); throw; }
        finally { _ = worker.ContinueWith(t => { _ = t.Exception; stop.Dispose(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default); }
    }

    internal static WindowsSessionsRead Read(CimSession session)
    {
        const string ns = @"root\cimv2";
        var identity = session.Read("sessions.identity", ns, "SELECT Name FROM Win32_ComputerSystem", 1);
        if (identity.Status != SourceStatus.Ok || !string.Equals(identity.Instances.FirstOrDefault()?.Text("Name"), CredentialRules.MachineKey(session.Host), StringComparison.OrdinalIgnoreCase))
        { return new(identity.Status is SourceStatus.Refused or SourceStatus.Interrupted or SourceStatus.Unreachable ? identity.Status : SourceStatus.Error, [], 0, session.Clock.GetUtcNow(), "Nom du poste non confirmé ; sessions CIM écartées.") { AuthenticationRejected = identity.AuthenticationRejected }; }
        var logons = session.Read("sessions.logons", ns, "SELECT LogonId, LogonType, StartTime FROM Win32_LogonSession WHERE LogonType=2 OR LogonType=10 OR LogonType=11 OR LogonType=12", 64);
        if (!logons.Answered) { return new(logons.Status, [], 0, session.Clock.GetUtcNow(), logons.Detail) { AuthenticationRejected = logons.AuthenticationRejected }; }
        if (logons.Status == SourceStatus.Empty) { return new(SourceStatus.Empty, [], 0, session.Clock.GetUtcNow(), "Aucune ouverture de session interactive CIM ; WTS indisponible, état du bureau non établi."); }
        var links = session.Read("sessions.accounts", ns, "SELECT Antecedent, Dependent FROM Win32_LoggedOnUser", 2000);
        return Project(session.Host, logons, links, session.Clock.GetUtcNow());
    }

    internal static WindowsSessionsRead Project(string host, CimReading logons, CimReading links, DateTimeOffset at)
    {
        var accounts = new Dictionary<string, HashSet<(string Domain, string User)>>(StringComparer.Ordinal);
        var invalid = 0;
        foreach (var row in links.Instances)
        {
            var dependent = Reference(row.Text("Dependent"), host, "Win32_LogonSession");
            var antecedent = Reference(row.Text("Antecedent"), host, "Win32_Account") ?? Reference(row.Text("Antecedent"), host, "Win32_UserAccount")
                ?? Reference(row.Text("Antecedent"), host, "Win32_SystemAccount");
            if (dependent is null || dependent.Count != 1 || Id(dependent.GetValueOrDefault("LogonId")) is not { } id
                || antecedent is null || antecedent.Count != 2 || antecedent.GetValueOrDefault("Name") is not { Length: > 0 and <= 256 } name
                || antecedent.GetValueOrDefault("Domain") is not { Length: > 0 and <= 256 } domain)
            { invalid++; continue; }
            if (!accounts.TryGetValue(id, out var values)) { accounts[id] = values = []; }
            values.Add((domain, name));
        }
        var sessions = ImmutableArray.CreateBuilder<LocalSession>();
        var unread = 0;
        foreach (var row in logons.Instances)
        {
            var id = Id(row.Text("LogonId") ?? row.Number("LogonId")?.ToString(CultureInfo.InvariantCulture));
            var kind = row.Int("LogonType");
            if (id is null || kind is not (2 or 10 or 11 or 12)) { unread++; continue; }
            var account = accounts.TryGetValue(id, out var values) && values.Count == 1 ? values.Single() : ((string Domain, string User)?)null;
            if (account is null) { unread++; }
            sessions.Add(new("CIM:" + id, null, account?.User, account?.Domain,
                "Ouverture de session CIM ; état du bureau inconnu", kind is 10 or 12 ? "Interactive distante" : "Interactive",
                row.Dmtf("StartTime"), null, null));
        }
        var partial = unread > 0 || invalid > 0 || logons.Status != SourceStatus.Ok || links.Status is not (SourceStatus.Ok or SourceStatus.Empty);
        return new(partial ? SourceStatus.Partial : sessions.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok, sessions.ToImmutable(), unread, at,
            "Repli CIM : ouvertures de session, sans état actif/déconnecté, protocole mesuré ni durée d’inactivité." + (partial ? " Relevé partiel ; certaines associations n’ont pas été établies." : ""))
            { AuthenticationRejected = logons.AuthenticationRejected || links.AuthenticationRejected };
    }

    private static string? Id(string? value) => value is { Length: > 0 and <= 20 } && value.All(char.IsAsciiDigit)
        && ulong.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) ? number.ToString(CultureInfo.InvariantCulture) : null;

    /// <summary>Parses only returned WMI references; never follows them or uses their text in another query.</summary>
    internal static Dictionary<string, string>? Reference(string? value, string host, string className)
    {
        if (value is not { Length: > 0 and <= 4096 } || value.Any(char.IsControl)) { return null; }
        var body = value;
        if (body.StartsWith(@"\\", StringComparison.Ordinal))
        {
            var serverEnd = body.IndexOf('\\', 2);
            if (serverEnd < 3) { return null; }
            var server = body[2..serverEnd];
            if (server.Contains('.') ? !string.Equals(server.TrimEnd('.'), host.TrimEnd('.'), StringComparison.OrdinalIgnoreCase)
                : !string.Equals(server, CredentialRules.MachineKey(host), StringComparison.OrdinalIgnoreCase)) { return null; }
            var prefix = @"\root\cimv2:";
            if (!body.AsSpan(serverEnd).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { return null; }
            body = body[(serverEnd + prefix.Length)..];
        }
        if (!body.StartsWith(className + ".", StringComparison.OrdinalIgnoreCase)) { return null; }
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var index = className.Length + 1;
        while (index < body.Length)
        {
            var start = index;
            while (index < body.Length && char.IsAsciiLetter(body[index])) { index++; }
            if (index == start || index + 1 >= body.Length || body[index] != '=' || body[index + 1] != '"') { return null; }
            var key = body[start..index]; index += 2;
            var text = new StringBuilder(); var ended = false;
            while (index < body.Length)
            {
                var character = body[index++];
                if (character == '"') { ended = true; break; }
                if (character == '\\')
                {
                    if (index >= body.Length || body[index] is not ('\\' or '"')) { return null; }
                    character = body[index++];
                }
                text.Append(character);
                if (text.Length > 512) { return null; }
            }
            if (!ended || !result.TryAdd(key, text.ToString()) || result.Count > 2) { return null; }
            if (index == body.Length) { return result; }
            if (body[index++] != ',' || index == body.Length) { return null; }
        }
        return null;
    }
}
