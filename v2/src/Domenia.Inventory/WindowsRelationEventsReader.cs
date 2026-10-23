using System.Collections.Immutable;
using System.ComponentModel;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.Net;
using System.Security.Principal;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed record RelationLogRequest(string Controller, DateTimeOffset From, DateTimeOffset To, int Maximum, string? SubjectSid = null)
{
    /// <summary>One workstation: at most forty interactive 4624 events and three seconds, never a DC harvest.</summary>
    public bool WorkstationInteractive { get; init; }
}
public sealed record RelationLogEvent(long RecordId, int EventId, DateTimeOffset At, string Account, string? Domain, string? UserSid,
    string? Address, string? Workstation, int? LogonType);
public sealed record RelationLogReading(ImmutableArray<RelationLogEvent> Events, int Read, int Rejected, int Ignored, bool Truncated,
    SourceStatus Status, bool AuthenticationRejected, string Detail);
internal sealed record RelationLogRaw(long? RecordId, int Id, DateTimeOffset? At, string? Provider, string? Channel, string? Computer, IReadOnlyList<object?> Values);

/// <summary>One Security journal, closed selectors, no XML/message/ticket payload, two native workers and no authentication fallback.</summary>
public sealed class WindowsRelationEventsReader(TimeProvider clock)
{
    private const string Provider = "Microsoft-Windows-Security-Auditing";
    private static readonly SemaphoreSlim Workers = new(2, 2);
    private static readonly string[] Fields = ["TargetUserName", "TargetDomainName", "TargetSid", "TargetUserSid", "IpAddress", "WorkstationName", "LogonType", "Status"];
    internal Func<RelationLogRequest, string, RemoteProbeCredential?, CancellationToken, IEnumerable<RelationLogRaw>>? ReadOverride { get; init; }
    private sealed record Progress(ImmutableList<RelationLogEvent> Events, int Read, int Rejected, int Ignored, bool Truncated);

    public async Task<RelationLogReading> ReadAsync(RelationLogRequest request, RemoteProbeCredential? credential, CancellationToken cancellationToken)
    {
        var query = Query(request);
        if (request.To > clock.GetUtcNow().AddMinutes(2)) { throw new ArgumentException("Fin de fenêtre future."); }
        if (credential is { Session: false, Password: null })
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Secret du compte choisi absent ; aucun autre compte essayé."); }
        if (credential is { Session: false } && !CredentialRules.IsWellFormed(credential.Account)) { throw new ArgumentException("Compte du journal mal formé."); }
        cancellationToken.ThrowIfCancellationRequested();
        if (!Workers.Wait(0)) { throw new DomeniaOperationException("machine.busy", "Deux lectures de journaux se terminent encore ; aucun nouvel appel envoyé."); }
        RemoteProbeCredential? owned;
        try { owned = credential is null ? null : new(credential.Account, credential.Password?.Copy(), credential.Session); }
        catch { Workers.Release(); throw; }
        var tracked = SecureCredentialCopies.Track(owned?.Password);
        var timeout = TimeSpan.FromSeconds(request.WorkstationInteractive ? 3 : request.SubjectSid is null ? 60 : 15);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var latest = new Progress([], 0, 0, 0, false);
        RelationLogReading Snapshot(Progress value, SourceStatus? status = null, bool authentication = false, string? detail = null) => new(
            value.Events.ToImmutableArray(), value.Read, value.Rejected, value.Ignored, value.Truncated,
            status ?? (value.Truncated || value.Rejected > 0 ? SourceStatus.Partial : value.Events.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok), authentication,
            detail ?? FrenchText.Count(value.Read, "événement examiné", "événements examinés") + ", " + FrenchText.Count(value.Events.Count, "événement réussi retenu", "événements réussis retenus")
                + ", " + FrenchText.Count(value.Ignored, "événement hors population ou en échec écarté", "événements hors population ou en échec écartés")
                + (value.Rejected > 0 ? ", " + FrenchText.Count(value.Rejected, "événement incohérent écarté", "événements incohérents écartés") : "")
                + (value.Truncated ? ". Lecture partielle : limite de volume ou d’événements atteinte." : "."));
        var worker = Task.Run(() =>
        {
            using (owned)
            using (tracked)
            {
                var current = latest; var ids = new Dictionary<long, RelationLogEvent>(); var conflicts = new HashSet<long>(); long bytes = 0;
                try
                {
                    var input = ReadOverride?.Invoke(request, query, owned, stop.Token) ?? ReadNative(request, query, owned, stop.Token);
                    foreach (var raw in input)
                    {
                        stop.Token.ThrowIfCancellationRequested();
                        if (current.Read == request.Maximum) { current = current with { Truncated = true }; break; }
                        current = current with { Read = current.Read + 1 };
                        var value = Map(raw, request, out var ignored);
                        if (ignored) { current = current with { Ignored = current.Ignored + 1 }; }
                        else if (value is null || conflicts.Contains(value.RecordId)) { current = current with { Rejected = current.Rejected + 1 }; }
                        else if (ids.TryGetValue(value.RecordId, out var previous))
                        {
                            if (previous == value) { current = current with { Rejected = current.Rejected + 1 }; }
                            else
                            {
                                conflicts.Add(value.RecordId);
                                current = current with { Events = current.Events.Remove(previous), Rejected = current.Rejected + 2 };
                            }
                        }
                        else
                        {
                            bytes += Encoding.UTF8.GetByteCount(value.Account) + new[] { value.Domain, value.UserSid, value.Address, value.Workstation }.Sum(s => s is null ? 0 : Encoding.UTF8.GetByteCount(s)) + 64;
                            if (bytes > 16 * 1024 * 1024) { current = current with { Truncated = true }; break; }
                            ids.Add(value.RecordId, value);
                            current = current with { Events = current.Events.Add(value) };
                        }
                        Volatile.Write(ref latest, current);
                    }
                    stop.Token.ThrowIfCancellationRequested(); Volatile.Write(ref latest, current); return Snapshot(current);
                }
                catch (OperationCanceledException)
                { return Snapshot(current with { Truncated = true }, SourceStatus.Interrupted, detail: "Lecture arrêtée ; événements déjà qualifiés conservés."); }
                catch (Exception ex) when (ex is EventLogException or UnauthorizedAccessException or Win32Exception or TimeoutException or InvalidDataException)
                {
                    var error = ex is Win32Exception native ? native.NativeErrorCode : ex.HResult;
                    var authentication = WindowsAuthenticationErrors.IsRejected(error);
                    var win32 = ((uint)error & 0xffff0000) == 0x80070000 ? error & ushort.MaxValue : error;
                    var denied = authentication || ex is UnauthorizedAccessException || win32 is 5 or 1314;
                    return Snapshot(current with { Truncated = true }, denied ? SourceStatus.Refused : SourceStatus.Unavailable, authentication,
                        authentication ? "Identifiants rejetés ; aucun autre compte essayé. Événements déjà qualifiés conservés."
                            : denied ? "Lecture du journal refusée ; les droits ne sont pas modifiés. Événements déjà qualifiés conservés."
                            : "Journal indisponible, délai ou curseur invalidé ; événements déjà qualifiés conservés, aucune reprise implicite.");
                }
            }
        }, CancellationToken.None);
        try { return await worker.WaitAsync(timeout, clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            // Native cancellation may itself be slow. Resources and the secure copy remain owned until the worker ends.
            _ = stop.CancelAsync().ContinueWith(t => _ = t.Exception, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return Snapshot(Volatile.Read(ref latest) with { Truncated = true }, SourceStatus.Interrupted,
                detail: "Arrêt ou budget du journal atteint ; événements déjà qualifiés conservés. Fermeture native demandée.");
        }
        finally
        {
            _ = worker.ContinueWith(t => { _ = t.Exception; stop.Dispose(); Workers.Release(); }, CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    internal static string Query(RelationLogRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!CimQuery.IsHostName(request.Controller) || !request.Controller.Contains('.') || IPAddress.TryParse(request.Controller, out _)
            || request.From == DateTimeOffset.MinValue || request.From >= request.To || request.To - request.From > TimeSpan.FromDays(30)
            || request.Maximum is < 1 or > 20_000 || request.SubjectSid is { } sid && (!AccountsRules.IsDomainSid(sid) || request.Maximum > 100)
            || request.WorkstationInteractive && (request.SubjectSid is not null || request.Maximum > 40))
        { throw new ArgumentException("Contrôleur, période, SID ou limite du journal invalide."); }
        static string At(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        return "*[System[Provider[@Name='" + Provider + "'] and " + (request.WorkstationInteractive ? "EventID=4624" : request.SubjectSid is null ? "(EventID=4768 or EventID=4769 or EventID=4624)" : "EventID=4768")
            + " and TimeCreated[@SystemTime >= '" + At(request.From) + "' and @SystemTime <= '" + At(request.To) + "']]]"
            + (request.WorkstationInteractive ? " and *[EventData[Data[@Name='LogonType']='2' or Data[@Name='LogonType']='10' or Data[@Name='LogonType']='11']]"
                : request.SubjectSid is null ? "" : " and *[EventData[Data[@Name='TargetSid']='" + request.SubjectSid + "' and Data[@Name='Status']='0x0']]");
    }

    internal static RelationLogEvent? Map(RelationLogRaw raw, RelationLogRequest request, out bool ignored)
    {
        ignored = false;
        if (raw.Provider != Provider || raw.Channel != "Security" || raw.Id is not (4768 or 4769 or 4624) || raw.RecordId is not > 0
            || raw.At is not { } at || at < request.From || at > request.To || raw.Values.Count != Fields.Length
            || !(string.Equals(raw.Computer, request.Controller, StringComparison.OrdinalIgnoreCase)
                || string.Equals(raw.Computer, request.Controller.Split('.')[0], StringComparison.OrdinalIgnoreCase))) { return null; }
        var invalid = false;
        string? Text(int index, int maximum)
        {
            var value = raw.Values[index];
            if (value is not null and not string && !(index is 2 or 3 && value is SecurityIdentifier)
                && !(index is 6 or 7 && value is byte or ushort or uint or ulong or short or int or long)) { invalid = true; return null; }
            var text = value switch { null => null, string s => s.Trim(), SecurityIdentifier sid => sid.Value,
                byte or ushort or uint or ulong or short or int or long => Convert.ToString(value, CultureInfo.InvariantCulture), _ => null };
            if (value is not null && text is null || text?.Length > maximum || text?.Any(char.IsControl) == true) { invalid = true; }
            return text is null or "" or "-" ? null : text;
        }
        var account = Text(0, 320); var domain = Text(1, 255); var sid4768 = Text(2, 184); var sid4624 = Text(3, 184);
        var address = Text(4, 128); var workstation = Text(5, 255); var typeText = Text(6, 12); var status = Text(7, 16);
        if (invalid || account is null) { return null; }
        int? logonType = null;
        if (raw.Id == 4624)
        {
            if (!int.TryParse(typeText, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number is < 0 or > 13 or 1) { return null; }
            logonType = number;
        }
        else
        {
            if (status is null) { return null; }
            var hex = status.StartsWith("0x", StringComparison.OrdinalIgnoreCase);
            if (!uint.TryParse(hex ? status[2..] : status, hex ? NumberStyles.AllowHexSpecifier : NumberStyles.None, CultureInfo.InvariantCulture, out var code)) { return null; }
            if (code != 0) { ignored = true; return null; }
        }
        if (request.WorkstationInteractive && (raw.Id != 4624 || logonType is not (2 or 10 or 11))) { ignored = true; return null; }
        // ServiceSid is deliberately not selected: in 4769 it identifies the ticket's destination, not the user or client.
        var userSid = raw.Id == 4624 ? sid4624 : raw.Id == 4768 ? sid4768 : null;
        if (userSid is not null && !AccountsRules.IsDomainSid(userSid))
        {
            try { _ = new SecurityIdentifier(userSid); } catch (ArgumentException) { return null; }
            ignored = true; return null;
        }
        if (request.SubjectSid is not null && (raw.Id != 4768 || userSid != request.SubjectSid)) { return null; }
        if (address is not null)
        {
            if (!IPAddress.TryParse(address, out var ip)) { address = null; }
            else
            {
                var mapped = ip.IsIPv4MappedToIPv6; ip = mapped ? ip.MapToIPv4() : ip;
                address = IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any) || ip.Equals(IPAddress.IPv6Any) || ip.Equals(IPAddress.Broadcast)
                    || !mapped && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && address != ip.ToString() ? null : ip.ToString();
            }
        }
        return new(raw.RecordId.Value, raw.Id, at, account, domain, userSid, address, workstation, logonType);
    }

    private static IEnumerable<RelationLogRaw> ReadNative(RelationLogRequest request, string xpath, RemoteProbeCredential? credential, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var name = credential is { Session: false } ? CredentialRules.Parse(credential.Account) : null;
        using var session = name is null ? new EventLogSession(request.Controller)
            : new EventLogSession(request.Controller, name.Form == AccountNameForm.Upn ? null : name.Authority,
                name.Form == AccountNameForm.Upn ? credential!.Account : name.Name, credential!.Password, SessionAuthentication.Kerberos);
        var query = new EventLogQuery("Security", PathType.LogName, xpath) { Session = session, ReverseDirection = true, TolerateQueryErrors = false };
        using var reader = new EventLogReader(query) { BatchSize = 32 };
        using var cancel = token.Register(() =>
        {
            try { reader.CancelReading(); }
            catch (Exception ex) when (ex is EventLogException or InvalidOperationException or ObjectDisposedException) { }
        });
        using var selector = new EventLogPropertySelector(Fields.Select(f => "Event/EventData/Data[@Name='" + f + "']"));
        while (true)
        {
            token.ThrowIfCancellationRequested();
            using var record = reader.ReadEvent(TimeSpan.FromSeconds(1));
            if (record is null) { yield break; }
            if (record is not EventLogRecord native) { throw new InvalidDataException("Type d’événement inattendu."); }
            var date = record.TimeCreated;
            yield return new(record.RecordId, record.Id, date is { Kind: not DateTimeKind.Unspecified } time ? new DateTimeOffset(time.ToUniversalTime()) : null,
                record.ProviderName, record.LogName, record.MachineName, native.GetPropertyValues(selector).ToArray());
        }
    }
}
