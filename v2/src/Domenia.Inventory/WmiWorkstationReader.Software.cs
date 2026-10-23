using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Raw software read; the caller validates ReportedName against the directory before saving or displaying it.</summary>
public sealed record WorkstationSoftwareReading(string Computer, string? ReportedName, DateTimeOffset CollectedAt,
    ImmutableArray<SoftwareEntry> Entries, ImmutableArray<SoftwareScopeAccess> Access)
{
    public bool AuthenticationRejected { get; init; }
    public bool Complete => Access.All(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Skipped);
}

public sealed partial class WmiWorkstationReader
{
    public async Task<WorkstationSoftwareReading> ReadSoftwareAsync(string host, SoftwareRequest request, CancellationToken cancellationToken, RemoteProbeCredential? credential = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!CimQuery.IsHostName(host)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Nom de poste invalide ; aucun contact."); }
        var budget = request.PerUser ? CimBudgets.SoftwareWithProfiles : CimBudgets.Software;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var latest = new WorkstationSoftwareReading(host, null, clock.GetUtcNow(), [], []);
        Task<WorkstationSoftwareReading> work;
        try
        {
            work = WmiReadWorkers.Start(credential, owned =>
            {
                var session = Session(host, budget, stop.Token, owned);
                var identity = session.Read(InventoryCategories.System, Cimv2, "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
                var result = latest with { ReportedName = identity.Instances.FirstOrDefault()?.Text("Name"), AuthenticationRejected = identity.AuthenticationRejected };
                return CollectSoftware(session, result, request, true, stop.Token, value => Volatile.Write(ref latest, value));
            }, stop.Token);
        }
        catch { stop.Dispose(); throw; }
        try { return await work.WaitAsync(budget + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            stop.Cancel();
            _ = work.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return SoftwareInterrupted(Volatile.Read(ref latest), request);
        }
        finally { DisposeAfter(work, stop); }
    }

    private static WorkstationSoftwareReading SoftwareInterrupted(WorkstationSoftwareReading result, SoftwareRequest request) => result with
    {
        Access = [.. new[] { "Machine", "Utilisateur", "Store" }.Select(scope =>
        {
            var previous = result.Access.FirstOrDefault(a => a.Scope == scope);
            if (previous is not null && previous.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Skipped) { return previous; }
            var asked = scope == "Machine" || scope == "Utilisateur" && request.PerUser || scope == "Store" && request.Store;
            return ScopeAccess(scope, asked ? SourceStatus.Interrupted : SourceStatus.Skipped,
                result.Entries.Count(e => e.Scope == scope), asked ? "Lecture arrêtée ; entrées déjà lues conservées." : "Portée non demandée.");
        })],
    };

    private static SoftwareScopeAccess ScopeAccess(string scope, SourceStatus status, int items, string detail) =>
        new(scope, status, PosteLabels.SourceStatusLabel(status), items, detail);

    private static InventorySnapshot ReadSoftwareInventory(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var begin = session.Clock.GetTimestamp();
        var result = CollectSoftware(session, new(session.Host, current.ReportedName, current.CollectedAt, [], []), new(false, false, false), false, token, _ => { });
        var machine = result.Access.Single(a => a.Scope == "Machine");
        access.Add(new(InventoryCategories.Software, machine.Status, machine.Detail,
            (int)session.Clock.GetElapsedTime(begin).TotalMilliseconds, result.Entries.Length, session.Transport) { AuthenticationRejected = result.AuthenticationRejected });
        return current with { Software = result.Entries };
    }

    private sealed class SoftwareScopeState
    {
        internal int Answered;
        internal int Scanned;
        internal bool Incomplete;
        internal bool AuthenticationRejected;
        internal readonly List<SourceStatus> Failures = [];
        internal void Observe(RegistryReading reading)
        {
            if (reading.Answered) { Answered++; }
            if (!reading.Answered || reading.Status == SourceStatus.Partial) { Failures.Add(reading.Status); }
            AuthenticationRejected |= reading.AuthenticationRejected;
        }
        internal SourceStatus Status(int count)
        {
            if (Incomplete || Failures.Count > 0 && (Answered > 0 || count > 0)) { return SourceStatus.Partial; }
            if (Failures.Contains(SourceStatus.Refused)) { return SourceStatus.Refused; }
            if (Failures.Count > 0) { return Failures[0]; }
            return count > 0 ? SourceStatus.Ok : SourceStatus.Empty;
        }
    }

    private static WorkstationSoftwareReading CollectSoftware(CimSession session, WorkstationSoftwareReading initial, SoftwareRequest request,
        bool detailed, CancellationToken token, Action<WorkstationSoftwareReading> publish) => session.RegistryBatch(() =>
    {
        var entries = new List<SoftwareEntry>();
        var access = new List<SoftwareScopeAccess>();
        var result = initial;
        WorkstationSoftwareReading Snapshot() => result with { Entries = [.. entries], Access = [.. access] };
        void Publish() { result = Snapshot(); publish(result); }
        void ReadRoots(uint hive, string prefix, string? profile, SoftwareScopeState state)
        {
            foreach (var (root, architecture, source) in new[] { (InventoryRegistry.Uninstall, "64 bits", "Uninstall64"), (InventoryRegistry.Uninstall32, "32 bits", "Uninstall32") })
            {
                var key = prefix + root;
                var names = session.ReadRegistry(new(hive, key, null, RegistryMethod.Keys)); state.Observe(names);
                // Refusal or absence of one view must not hide the outcome of the other view.
                foreach (var child in names.Strings.Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase))
                {
                    if (token.IsCancellationRequested || session.OutOfBudget || state.AuthenticationRejected || state.Scanned >= PosteSoftware.KeyCap)
                    { state.Incomplete = true; break; }
                    state.Scanned++;
                    var path = key + "\\" + child;
                    RegistryReading Read(string name, RegistryMethod method = RegistryMethod.String)
                    {
                        var value = session.ReadRegistry(new(hive, path, name, method)); state.Observe(value); return value;
                    }
                    var name = Read("DisplayName");
                    if (SoftwareText(name.Text) is not { } display) { continue; }
                    var component = Read("SystemComponent", RegistryMethod.Dword);
                    var release = Read("ReleaseType");
                    var parent = Read("ParentKeyName");
                    var isUpdate = component.Number == 1 || !string.IsNullOrWhiteSpace(parent.Text)
                        || new[] { "update", "hotfix", "security" }.Any(mark => release.Text?.Contains(mark, StringComparison.OrdinalIgnoreCase) == true);
                    if (!request.Updates)
                    {
                        if (isUpdate) { continue; }
                        if (!component.Answered || !release.Answered || !parent.Answered || component.Found && component.Flag is null)
                        { state.Incomplete = true; continue; } // Unknown filter is not permission to include a hidden component.
                    }
                    var version = SoftwareText(Read("DisplayVersion").Text);
                    string? publisher = null, location = null, uninstall = null;
                    DateOnly? date = null; long? size = null;
                    if (detailed)
                    {
                        publisher = SoftwareText(Read("Publisher").Text);
                        var declared = Read("InstallDate");
                        if (SoftwareText(declared.Text) is { } text)
                        {
                            if (DateOnly.TryParseExact(text, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)) { date = parsed; }
                            else { state.Incomplete = true; }
                        }
                        var kb = Read("EstimatedSize", RegistryMethod.Dword).Number;
                        size = kb > 0 ? kb * 1024L : null;
                        location = SoftwareText(Read("InstallLocation").Text);
                        // An uninstall command is never executed; retain its executable, not possibly sensitive arguments.
                        var command = SoftwareText(Read("UninstallString").Text);
                        uninstall = command is null ? null : PosteLabels.CommandExecutable(command);
                    }
                    entries.Add(new(display, version, publisher, date, size, architecture, profile is null ? "Machine" : "Utilisateur",
                        profile, location, uninstall, profile is null ? source : "UserHives"));
                    result = result with { AuthenticationRejected = result.AuthenticationRejected || state.AuthenticationRejected };
                    Publish();
                }
            }
        }
        void Finish(string scope, SoftwareScopeState state, string detail)
        {
            var count = entries.Count(e => e.Scope == scope);
            access.Add(ScopeAccess(scope, state.Status(count), count, detail + " " + state.Scanned + " clé(s) parcourue(s), plafond " + PosteSoftware.KeyCap + "."
                + (state.Incomplete || state.Failures.Count > 0 ? " Lecture incomplète : plafond, arrêt ou valeurs non lues." : "")));
            result = result with { AuthenticationRejected = result.AuthenticationRejected || state.AuthenticationRejected }; Publish();
        }
        var machine = new SoftwareScopeState();
        ReadRoots(InventoryRegistry.Machine, "", null, machine);
        Finish("Machine", machine, "Registre Uninstall 64 et 32 bits ; une entrée par clé, sans fusion.");
        if (request.PerUser)
        {
            var users = new SoftwareScopeState();
            var hives = session.ReadRegistry(new(InventoryRegistry.Users, "", null, RegistryMethod.Keys)); users.Observe(hives);
            foreach (var sid in hives.Strings.Where(InventoryRegistry.ProfileSid).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase))
            {
                if (token.IsCancellationRequested || session.OutOfBudget || users.AuthenticationRejected || users.Scanned >= PosteSoftware.KeyCap) { users.Incomplete = true; break; }
                ReadRoots(InventoryRegistry.Users, sid + "\\", sid, users);
            }
            Finish("Utilisateur", users, "Ruches des profils chargés uniquement ; profils identifiés par SID, sans montage de ruche.");
        }
        else { access.Add(ScopeAccess("Utilisateur", SourceStatus.Skipped, 0, "Profils non demandés.")); }
        access.Add(ScopeAccess("Store", request.Store ? SourceStatus.Unavailable : SourceStatus.Skipped, 0,
            request.Store ? "Applications Appx non lues : le transport WinRM reste à raccorder." : "Store non demandé."));
        Publish();
        return result;
    });

    private static string? SoftwareText(string? value) => string.IsNullOrWhiteSpace(value) || value.Any(char.IsControl) ? null : value.Trim();
}
