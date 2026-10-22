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
    /// <summary>True when the source answered (OK, empty or partial): its instances then describe the workstation.</summary>
    public bool Answered => Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial;

    /// <summary>Number of instances read.</summary>
    public int Items => Instances.Count;

    /// <summary>The line of the access report for this reading.</summary>
    public SourceAccess ToAccess(InventoryTransport transport) => new(Category, Status, Detail, DurationMs, Items, transport);
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
    private readonly DateTimeOffset deadline;

    /// <param name="host">NetBIOS or DNS name of the workstation; nothing is contacted before the first read.</param>
    /// <param name="budget">Ceiling of the whole reading, clamped to <see cref="CimBudgets.Bound"/>.</param>
    public CimSession(string host, TimeSpan budget, TimeProvider clock, ITechnicalJournal? journal = null)
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
        deadline = clock.GetUtcNow() + Budget;
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
    public bool OutOfBudget => clock.GetUtcNow() >= deadline;

    /// <summary>Time left before the budget is spent, never negative.</summary>
    public TimeSpan Remaining
    {
        get
        {
            var left = deadline - clock.GetUtcNow();
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

        if (!CimQuery.IsReadOnlySelect(wql))
        {
            journal?.Warning("Requête CIM refusée par la garde de lecture seule (" + category + ") : rien n’a été envoyé.");
            return new CimReading(category, SourceStatus.Error, "requête refusée par la garde de lecture seule", Elapsed(), []);
        }

        if (maxItems <= 0)
        {
            return new CimReading(category, SourceStatus.Skipped, "aucune instance demandée", Elapsed(), []);
        }

        if (OutOfBudget)
        {
            return new CimReading(category, SourceStatus.Interrupted, "budget de la lecture atteint", Elapsed(), []);
        }

        var perQuery = Bound(timeout ?? CimBudgets.Query);
        try
        {
            var scope = Open(namespaceName, perQuery);
            var instances = Query(scope, wql, perQuery, maxItems, out var truncated);
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
            journal?.Info("Lecture CIM de " + Host + " (" + category + ") : " + Detail(ex, outcome) + ".");
            return new CimReading(category, outcome, Detail(ex, outcome), Elapsed(), []);
        }
    }

    /// <summary>
    /// Which status an exception of a CIM read means; null when the exception is not a workstation outcome (a
    /// cancellation, a programming error), which then propagates instead of being reported as a reading.
    /// </summary>
    internal static SourceStatus? Classify(Exception exception) => exception switch
    {
        OperationCanceledException => null,
        UnauthorizedAccessException => SourceStatus.Refused,
        ManagementException { ErrorCode: ManagementStatus.AccessDenied } => SourceStatus.Refused,
        ManagementException { ErrorCode: ManagementStatus.Timedout } => SourceStatus.Interrupted,
        // An unreachable namespace is not a refusal: the workstation answered, the class is simply not there.
        ManagementException => SourceStatus.Error,
        // RPC server unavailable, call failed, network errors: the workstation did not answer the CIM bind.
        System.Runtime.InteropServices.COMException => SourceStatus.Unreachable,
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
    private ManagementScope Open(string namespaceName, TimeSpan timeout)
    {
        var options = new ConnectionOptions
        {
            Impersonation = ImpersonationLevel.Impersonate,
            Authentication = AuthenticationLevel.PacketPrivacy,
            EnablePrivileges = false,
            Timeout = timeout < CimBudgets.Connect ? timeout : CimBudgets.Connect,
        };
        var scope = new ManagementScope(@"\\" + Host + @"\" + namespaceName, options);
        scope.Connect();
        return scope;
    }

    /// <summary>Instances of a projection, copied out while the WMI objects are alive; every object is disposed here.</summary>
    private static List<WmiInstance> Query(ManagementScope scope, string wql, TimeSpan timeout, int maxItems, out bool truncated)
    {
        var options = new WmiEnumerationOptions { Timeout = timeout, ReturnImmediately = true, Rewindable = false };
        using var searcher = new ManagementObjectSearcher(scope, new ObjectQuery(wql), options);
        using var results = searcher.Get();
        var instances = new List<WmiInstance>(Math.Min(maxItems, 64));
        truncated = false;
        foreach (var item in results)
        {
            using (item)
            {
                var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                foreach (var property in item.Properties)
                {
                    values[property.Name] = property.Value;
                }

                instances.Add(new WmiInstance(values));
            }

            if (instances.Count >= maxItems)
            {
                truncated = true;
                break;
            }
        }

        return instances;
    }
}
