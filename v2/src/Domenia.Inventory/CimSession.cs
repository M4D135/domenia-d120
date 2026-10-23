using System.Management;
using Domenia.Core;
using Domenia.Core.Poste;
using WmiEnumerationOptions = System.Management.EnumerationOptions;

namespace Domenia.Inventory;

/// <summary>
/// Answer of one CIM read: what was asked for, whether it answered, what it said and how long it took. The status is the
/// one the operator sees (docs/ops/poste.md § 8.2): a refusal, an unreachable workstation and an error are three different
/// answers, and none of them is an empty list.
/// </summary>
public sealed record CimReading(string Category, SourceStatus Status, string Detail, int DurationMs, IReadOnlyList<WmiInstance> Instances)
{
    public bool AuthenticationRejected { get; init; }
    /// <summary>True when the source answered (OK, empty or partial): its instances then describe the workstation.</summary>
    public bool Answered => Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial;

    /// <summary>Number of instances read.</summary>
    public int Items => Instances.Count;

    /// <summary>The line of the access report for this reading.</summary>
    public SourceAccess ToAccess(InventoryTransport transport) => new(Category, Status, Detail, DurationMs, Items, transport) { AuthenticationRejected = AuthenticationRejected };
}

/// <summary>
/// Read-only CIM session of one workstation (CIM over DCOM, Windows session of the operator, Kerberos, packet privacy), as
/// <see cref="WmiWorkstationProbe"/> opens it. Three things make it safe to point at a real machine:
/// <list type="bullet">
/// <item>only plain SELECT projections leave the process — <see cref="CimQuery.IsReadOnlySelect"/> refuses anything else,
/// and no method of any class is ever invoked, so the session cannot change the workstation;</item>
/// <item>every read is bounded three times over: the bind, each query by its own delay, and the whole reading by the budget
/// given at construction — past the budget, the remaining sources answer « Interrompu » and what was read is kept;</item>
/// <item>a failure is classified, never swallowed: refused (access denied), unreachable (RPC, network), interrupted
/// (timeout) or error, each with its French wording for the access report.</item>
/// </list>
/// Synchronous by design: it is called from a worker thread by <see cref="WmiWorkstationReader"/>, never on the UI thread.
/// Scopes are opened per read and never kept, so no WMI object outlives the read that created it.
/// </summary>
public sealed class CimSession
{
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal? journal;
    private readonly long started;
    private readonly CancellationToken cancellationToken;
    private bool authenticationRefused;
    private readonly RemoteProbeCredential? credential;
    internal Func<string, string, TimeSpan, IEnumerable<WmiInstance>>? ReadOverride { get; init; }

    /// <param name="host">NetBIOS or DNS name of the workstation; nothing is contacted before the first read.</param>
    /// <param name="budget">Ceiling of the whole reading, clamped to <see cref="CimBudgets.Bound"/>.</param>
    public CimSession(string host, TimeSpan budget, TimeProvider clock, ITechnicalJournal? journal = null, CancellationToken cancellationToken = default, RemoteProbeCredential? credential = null)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(clock);
        if (!CimQuery.IsHostName(host))
        {
            throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Nom de poste invalide : aucun poste contacté.");
        }

        Host = host;
        this.clock = clock;
        this.journal = journal;
        Clock = clock;
        Budget = CimBudgets.Bound(budget);
        started = clock.GetTimestamp();
        this.cancellationToken = cancellationToken;
        this.credential = credential;
        if (credential is { Session: false } && (credential.Password is null || string.IsNullOrWhiteSpace(credential.Account)))
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Compte CIM explicite incomplet ; aucun repli sur le compte Windows."); }
    }

    /// <summary>Workstation this session reads.</summary>
    public string Host { get; }

    /// <summary>Clock of the session, so a collector measures the same time as the reader that opened it.</summary>
    public TimeProvider Clock { get; }

    /// <summary>Ceiling granted to the whole reading.</summary>
    public TimeSpan Budget { get; }

    /// <summary>Transport this session can use (CIM over DCOM only; WinRM is a separate decision, docs/ops/poste.md § 8.2).</summary>
    public InventoryTransport Transport => InventoryTransport.Dcom;

    /// <summary>True once the budget is spent: the sources not read yet are said, not guessed.</summary>
    public bool OutOfBudget => Remaining == TimeSpan.Zero;

    /// <summary>Time left before the budget is spent, never negative.</summary>
    public TimeSpan Remaining
    {
        get
        {
            var left = Budget - clock.GetElapsedTime(started);
            return left < TimeSpan.Zero ? TimeSpan.Zero : left;
        }
    }

    /// <summary>
    /// Reads one category. <paramref name="wql"/> must be a plain SELECT (otherwise the read is refused here, before any
    /// contact); <paramref name="maxItems"/> caps the instances, and reaching the cap is reported as a partial answer.
    /// This method never throws for a workstation reason: it answers with a status. It does throw on cancellation.
    /// </summary>
    public CimReading Read(string category, string namespaceName, string wql, int maxItems, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(category);
        ArgumentNullException.ThrowIfNull(namespaceName);
        ArgumentNullException.ThrowIfNull(wql);
        var started = clock.GetTimestamp();
        int Elapsed() => (int)clock.GetElapsedTime(started).TotalMilliseconds;

        if (!CimQuery.IsReadOnlySelect(wql, namespaceName))
        {
            journal?.Warning("Requête CIM refusée par la garde de lecture seule (" + category + ") : rien n’a été envoyé.");
            return new CimReading(category, SourceStatus.Error, "requête refusée par la garde de lecture seule", Elapsed(), []);
        }

        if (maxItems is <= 0 or > 20_000)
        {
            return new CimReading(category, SourceStatus.Skipped, "aucune instance demandée", Elapsed(), []);
        }

        if (authenticationRefused) { return new CimReading(category, SourceStatus.Refused, "authentification déjà refusée : aucun nouvel essai", Elapsed(), []) { AuthenticationRejected = true }; }

        if (OutOfBudget || cancellationToken.IsCancellationRequested)
        {
            return new CimReading(category, SourceStatus.Interrupted, "budget de la lecture atteint", Elapsed(), []);
        }

        var requested = Bound(timeout ?? CimBudgets.Query);
        var perQuery = requested < Remaining ? requested : Remaining;
        var instances = new List<WmiInstance>();
        try
        {
            var begin = clock.GetTimestamp();
            var rows = ReadOverride is null ? Query(namespaceName, wql, perQuery) : ReadOverride(namespaceName, wql, perQuery);
            var truncated = false;
            foreach (var row in rows)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (OutOfBudget || clock.GetElapsedTime(begin) >= perQuery) { throw new TimeoutException(); }
                if (instances.Count == maxItems) { truncated = true; break; }
                instances.Add(row);
            }
            cancellationToken.ThrowIfCancellationRequested();
            if (OutOfBudget || clock.GetElapsedTime(begin) >= perQuery) { throw new TimeoutException(); }
            var status = instances.Count == 0 ? SourceStatus.Empty : truncated ? SourceStatus.Partial : SourceStatus.Ok;
            var detail = instances.Count switch
            {
                0 => "aucune instance",
                var count when truncated => FrenchText.Integer(count) + " instances (plafond atteint)",
                var count => FrenchText.Count(count, "instance lue", "instances lues"),
            };
            return new CimReading(category, status, detail, Elapsed(), instances);
        }
        catch (Exception ex) when (Classify(ex) is SourceStatus outcome)
        {
            if (WindowsAuthenticationErrors.IsRejected(ex.HResult)) { authenticationRefused = true; }
            journal?.Info("Lecture CIM de " + Host + " (" + category + ") : " + Detail(ex, outcome) + ".");
            return new CimReading(category, instances.Count > 0 ? SourceStatus.Partial : outcome, Detail(ex, outcome), Elapsed(), instances.ToArray()) { AuthenticationRejected = authenticationRefused };
        }
    }

    /// <summary>
    /// Which status an exception of a CIM read means; null when the exception is not a workstation outcome (a
    /// cancellation, a programming error), which then propagates instead of being reported as a reading.
    /// </summary>
    internal static SourceStatus? Classify(Exception exception) => exception switch
    {
        OperationCanceledException => SourceStatus.Interrupted,
        UnauthorizedAccessException => SourceStatus.Refused,
        ManagementException { ErrorCode: ManagementStatus.AccessDenied } => SourceStatus.Refused,
        ManagementException { ErrorCode: ManagementStatus.Timedout } => SourceStatus.Interrupted,
        // An unreachable namespace is not a refusal: the workstation answered, the class is simply not there.
        ManagementException => SourceStatus.Error,
        // RPC server unavailable, call failed, network errors: the workstation did not answer the CIM bind.
        System.Runtime.InteropServices.COMException ex when ex.HResult == unchecked((int)0x80070005) || WindowsAuthenticationErrors.IsRejected(ex.HResult) => SourceStatus.Refused,
        System.Runtime.InteropServices.COMException { HResult: unchecked((int)0x800706BA) or unchecked((int)0x800706BE) or unchecked((int)0x80070035) } => SourceStatus.Unreachable,
        System.Runtime.InteropServices.COMException => SourceStatus.Error,
        TimeoutException => SourceStatus.Interrupted,
        _ => null,
    };

    private static string Detail(Exception exception, SourceStatus status) => status switch
    {
        SourceStatus.Refused => "accès refusé par le poste",
        SourceStatus.Unreachable => "poste injoignable par CIM",
        SourceStatus.Interrupted => "délai dépassé sur cette source",
        _ => "erreur CIM (" + exception.GetType().Name + ")",
    };

    private static TimeSpan Bound(TimeSpan requested) => requested < TimeSpan.FromMilliseconds(200) ? TimeSpan.FromMilliseconds(200) : requested > CimBudgets.Maximum ? CimBudgets.Maximum : requested;

    /// <summary>One bind for one read: the scope is never kept, so no WMI handle outlives the read that opened it.</summary>
    private IEnumerable<WmiInstance> Query(string namespaceName, string wql, TimeSpan timeout)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var started = clock.GetTimestamp();
        var options = new ConnectionOptions
        {
            Impersonation = ImpersonationLevel.Impersonate,
            Authentication = AuthenticationLevel.PacketPrivacy,
            EnablePrivileges = false,
            Timeout = timeout < CimBudgets.Connect ? timeout : CimBudgets.Connect,
        };
        ManagementScope? scope = null;
        ManagementObjectSearcher? searcher = null;
        try
        {
            if (credential is { Session: false }) { options.Username = credential.Account; options.SecurePassword = credential.Password; }
            scope = new ManagementScope(@"\\" + Host + @"\" + namespaceName, options);
            scope.Connect();
            cancellationToken.ThrowIfCancellationRequested();
            var remaining = timeout - clock.GetElapsedTime(started);
            if (remaining <= TimeSpan.Zero) { throw new TimeoutException(); }
            var enumeration = new WmiEnumerationOptions { Timeout = remaining, ReturnImmediately = true, Rewindable = false, BlockSize = 1 };
            searcher = new ManagementObjectSearcher(scope, new ObjectQuery(wql), enumeration);
            using var results = searcher.Get();
            foreach (var item in results)
            {
                using (item)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (OutOfBudget) { throw new TimeoutException(); }
                    var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                    foreach (var property in item.Properties) { values[property.Name] = property.Value; }
                    yield return new WmiInstance(values);
                }
            }
        }
        finally
        {
            if (searcher is not null) { searcher.Scope.Options.SecurePassword = null; searcher.Dispose(); }
            if (scope is not null) { scope.Options.SecurePassword = null; }
            options.SecurePassword = null;
        }
    }
}
