using System.ComponentModel;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>One bounded DNS resolution followed by one ICMP echo. No retry, alternate address or authentication.</summary>
public sealed class WorkstationPresenceReader(TimeProvider clock, ITechnicalJournal? journal = null, AdaptiveReadBudget? adaptive = null)
{
    internal sealed record EchoReply(IPStatus Status, IPAddress? Address, long? RoundtripTimeMs = null);
    /// <summary>Address and latency are transient display data; only Measure belongs in the presence cache.</summary>
    public sealed record Result(PresenceMeasure Measure, IPAddress? AnswerAddress, long? RoundtripTimeMs = null);
    internal Func<string, CancellationToken, Task<IPAddress[]>>? ResolveOverride { get; init; }
    internal Func<IPAddress, TimeSpan, CancellationToken, Task<EchoReply>>? EchoOverride { get; init; }

    public async Task<PresenceMeasure> ReadAsync(string host, TimeSpan total, TimeSpan echoTimeout,
        DateTimeOffset? lastOnlineAt, CancellationToken cancellationToken) =>
        (await ReadDetailedAsync(host, total, echoTimeout, lastOnlineAt, cancellationToken).ConfigureAwait(false)).Measure;

    internal static bool ValidTarget(string host) => CimQuery.IsHostName(host) || IPAddress.TryParse(host, out _);

    public async Task<Result> ReadDetailedAsync(string host, TimeSpan total, TimeSpan echoTimeout,
        DateTimeOffset? lastOnlineAt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(total, TimeSpan.Zero);
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(echoTimeout, TimeSpan.Zero);
        cancellationToken.ThrowIfCancellationRequested();
        var measuredOutcome = ReadPerformanceOutcome.Failure;
        Result Finish(PresenceReadOutcome outcome, string phase, int? code = null, IPAddress? address = null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var at = clock.GetUtcNow();
            var answered = outcome == PresenceReadOutcome.Reply ? true : outcome == PresenceReadOutcome.NoReply ? false : (bool?)null;
            var state = answered is not null ? MeasureState.Known
                : outcome is PresenceReadOutcome.DnsTimeout or PresenceReadOutcome.DeadlineExceeded ? MeasureState.Incomplete : MeasureState.Error;
            var diagnostic = new PresenceDiagnostic(outcome, phase, code);
            measuredOutcome = outcome is PresenceReadOutcome.Reply or PresenceReadOutcome.NoReply ? ReadPerformanceOutcome.Success : ReadPerformanceOutcome.Failure;
            if (state != MeasureState.Known)
                journal?.Warning("Présence non mesurée : étape " + phase + ", résultat " + outcome
                    + (code is { } native ? ", code " + native.ToString(System.Globalization.CultureInfo.InvariantCulture) : "") + ". " + diagnostic.Text);
            return new(new(state, answered, at, answered == true ? at : lastOnlineAt) { Diagnostic = diagnostic }, address);
        }
        if (!ValidTarget(host)) { return Finish(PresenceReadOutcome.InvalidTarget, "target"); }
        var queuedAt = clock.GetTimestamp();
        var capacity = adaptive ?? AdaptiveReadBudget.Presence;
        using var site = PhysicalWorkBudget.InWriteContext ? null : await capacity.AcquireAsync(host, cancellationToken).ConfigureAwait(false);
        using var physical = await PhysicalWorkBudget.AcquireAsync(PhysicalWorkRoute.Network, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        site?.RequireContinuation();
        // Local queueing is not a DNS/ICMP attempt and must not consume the target's deadline.
        var started = clock.GetTimestamp();
        var queueMilliseconds = ReadPerformance.Milliseconds(clock.GetElapsedTime(queuedAt, started));
        using var deadline = new ReadProgressDeadline(clock, total, total);
        using var elapsed = new CancellationTokenSource(total, clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token, elapsed.Token);
        var stage = "dns";
        try
        {
            IPAddress? address;
            if (IPAddress.TryParse(host, out var supplied)) { address = supplied; }
            else
            {
                var addresses = await (ResolveOverride is { } resolve ? resolve(host, budget.Token)
                    : Dns.GetHostAddressesAsync(host, budget.Token)).ConfigureAwait(false);
                // Domenia v1 selected IPv4 first on dual-stack domains. Select once; never send a second echo.
                address = addresses.FirstOrDefault(candidate => candidate.AddressFamily == AddressFamily.InterNetwork)
                    ?? addresses.FirstOrDefault();
            }
            deadline.Snapshot();
            budget.Token.ThrowIfCancellationRequested();
            if (address is null || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any)
                || address.Equals(IPAddress.Broadcast)
                || address.AddressFamily is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6))
            { return Finish(PresenceReadOutcome.AddressUnavailable, "address"); }
            stage = "icmp";
            var remaining = total - clock.GetElapsedTime(started);
            if (remaining <= TimeSpan.Zero) { return Finish(PresenceReadOutcome.DeadlineExceeded, stage); }
            var allowed = echoTimeout < remaining ? echoTimeout : remaining;
            var reply = await (EchoOverride is { } echo ? echo(address, allowed, budget.Token)
                : EchoAsync(address, allowed, budget.Token)).ConfigureAwait(false);
            deadline.Snapshot();
            budget.Token.ThrowIfCancellationRequested();
            if (reply.Status == IPStatus.Success)
            {
                capacity.ObserveAddress(host, reply.Address);
                // Share only the observed grouping hint. WMI failures and its circuit remain independent of ICMP.
                AdaptiveReadBudget.Cim.ObserveAddress(host, reply.Address);
                site?.Report(AdaptiveReadOutcome.Success, clock.GetElapsedTime(started));
            }
            // Only a completed timed-out echo qualifies as "no reply". DNS/setup/transport failures do not.
            return reply.Status switch
            {
                IPStatus.Success => Finish(PresenceReadOutcome.Reply, stage, (int)reply.Status, reply.Address) with { RoundtripTimeMs = reply.RoundtripTimeMs },
                IPStatus.TimedOut => Finish(PresenceReadOutcome.NoReply, stage, (int)reply.Status),
                IPStatus.DestinationHostUnreachable or IPStatus.DestinationNetworkUnreachable
                    or IPStatus.DestinationPortUnreachable or IPStatus.DestinationProtocolUnreachable
                    or IPStatus.DestinationUnreachable or IPStatus.BadRoute =>
                        Finish(PresenceReadOutcome.NetworkUnavailable, stage, (int)reply.Status),
                IPStatus.BadDestination or IPStatus.BadOption =>
                    Finish(PresenceReadOutcome.AddressUnavailable, "address", (int)reply.Status),
                _ => Finish(PresenceReadOutcome.IcmpError, stage, (int)reply.Status),
            };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && budget.IsCancellationRequested)
        { return Finish(stage == "dns" ? PresenceReadOutcome.DnsTimeout : PresenceReadOutcome.DeadlineExceeded, stage); }
        catch (SocketException ex)
        { return SocketFailure(ex, stage, Finish); }
        catch (PingException ex)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (ex.InnerException is SocketException socket) { return SocketFailure(socket, stage, Finish); }
            if (ex.InnerException is OperationCanceledException || budget.IsCancellationRequested)
            { return Finish(stage == "dns" ? PresenceReadOutcome.DnsTimeout : PresenceReadOutcome.DeadlineExceeded, stage); }
            return Finish(PresenceReadOutcome.IcmpError, stage, ex.InnerException is Win32Exception native ? native.NativeErrorCode : null);
        }
        catch (NotSupportedException)
        { return Finish(PresenceReadOutcome.AddressUnavailable, "address"); }
        finally
        {
            ReadPerformance.Publish(new(ReadPerformanceMethod.Ping, "Presence", queueMilliseconds,
                ReadPerformance.Milliseconds(clock.GetElapsedTime(started)), cancellationToken.IsCancellationRequested ? ReadPerformanceOutcome.Cancelled : measuredOutcome));
        }
    }

    private static Result SocketFailure(SocketException ex, string stage,
        Func<PresenceReadOutcome, string, int?, IPAddress?, Result> finish)
    {
        var outcome = stage == "dns"
            ? ex.SocketErrorCode is SocketError.HostNotFound or SocketError.NoData ? PresenceReadOutcome.DnsNotFound
                : ex.SocketErrorCode == SocketError.TimedOut ? PresenceReadOutcome.DnsTimeout : PresenceReadOutcome.DnsUnavailable
            : ex.SocketErrorCode is SocketError.AddressFamilyNotSupported or SocketError.AddressNotAvailable ? PresenceReadOutcome.AddressUnavailable
                : PresenceReadOutcome.NetworkUnavailable;
        return finish(outcome, stage, (int)ex.SocketErrorCode, null);
    }

    private static async Task<EchoReply> EchoAsync(IPAddress address, TimeSpan timeout, CancellationToken token)
    {
        using var ping = new Ping();
        var reply = await ping.SendPingAsync(address, timeout, null, null, token).ConfigureAwait(false);
        return new(reply.Status, reply.Address, reply.Status == IPStatus.Success ? reply.RoundtripTime : null);
    }
}
