using System.Collections.Immutable;
using System.Globalization;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdFicheReader
{
    internal Func<string, IAdConnection>? ControllerConnection { get; init; }

    public async Task<FicheLockoutRead> LockoutEventsAsync(string dn, int hours, int maxEvents, CancellationToken cancellationToken)
    {
        if (hours is < 1 or > 720 || maxEvents is < 1 or > 500) { throw FicheErrors.Error(FicheErrors.Invalid, "Fenêtre ou plafond du journal invalide."); }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var epoch = await NetworkEpochAsync(dn, budget.Token).ConfigureAwait(false);
        try
        {
            var user = await objects.UserAsync(dn, budget.Token).ConfigureAwait(false)
                ?? throw FicheErrors.Error(FicheErrors.NotApplicable, "Le journal des verrouillages se lit pour un compte utilisateur.");
            var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
            var read = await new AdAccountLockouts(source).ReadAsync(user, domain, hours, maxEvents, budget.Token).ConfigureAwait(false);
            EnsureEpoch(epoch);
            return new(read.State == LockoutReadState.Read ? "read" : read.State == LockoutReadState.Refused ? "refused" : "unavailable",
                read.Server, read.PdcEmulator ? "émulateur PDC" : "contrôleur de connexion (PDC non confirmé)", hours, maxEvents, read.Truncated,
                [.. read.Events.Select(e => new FicheLockoutEvent(e.At, e.CallerComputer, e.Controller))], source.Clock.GetUtcNow(),
                read.State == LockoutReadState.Read ? null : "Journal Sécurité non lu ; aucune absence de verrouillage déduite.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
        {
            EnsureEpoch(epoch);
            return new("unavailable", source.ControllerName ?? "Non identifié", "Non confirmé", hours, maxEvents, false, [], source.Clock.GetUtcNow(), "Budget de lecture de 15 s atteint.");
        }
    }

    public async Task<FicheLogonReadings> LogonReadingsAsync(string dn, CancellationToken cancellationToken)
    {
        var entry = await objects.ReadExactAsync(dn, ["objectClass"], TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false)
            ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        if (AdFicheObjects.Project(entry).Kind is not (FicheKind.User or FicheKind.Computer)) { throw FicheErrors.Error(FicheErrors.NotApplicable, "Cette lecture concerne un compte utilisateur ou ordinateur."); }
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var epoch = source.Epoch;
        var controllers = domain.Controllers.DistinctBy(d => d.DnsName, StringComparer.OrdinalIgnoreCase).ToArray();
        var interval = FicheDiagnostics.Interval(null, "unavailable");
        try
        {
            var root = await objects.ReadExactAsync(domain.RootDn, ["msDS-LogonTimeSyncInterval"], TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
            interval = FicheDiagnostics.Interval(root?.Int("msDS-LogonTimeSyncInterval"), root is null ? "unavailable" : "read");
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.Timeout or AdErrors.Unavailable) { }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
        using var slots = new SemaphoreSlim(8);
        var readings = await Task.WhenAll(controllers.Take(50).Select(async dc =>
        {
            await slots.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (!CimQuery.IsHostName(dc.DnsName)) { return new FicheLogonReading(dc.DnsName, "Contrôleur", "unavailable", null, null, "Nom DNS invalide"); }
                using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(8), source.Clock);
                using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
                try
                {
                    using var connection = ControllerConnection?.Invoke(dc.DnsName) ?? (source.Connection as AdConnection)?.ForServer(dc.DnsName)
                        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Transport du compte indisponible.");
                    var rows = await connection.SearchAsync(new(domain.RootDn, AdObjectAccess.GuidFilter(entry.Guid("objectGUID")!.Value), AdSearchScope.Subtree,
                        ["objectGUID", "lastLogon", "logonCount"]) { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(8) }, budget.Token).ConfigureAwait(false);
                    if (rows.Count == 0) { return new FicheLogonReading(dc.DnsName, "Contrôleur", "absent", null, null, null); }
                    if (rows.Count != 1 || rows[0].Guid("objectGUID") != entry.Guid("objectGUID")) { throw AdAttributeRange.Incomplete(); }
                    var logon = rows[0].Long("lastLogon");
                    if (logon is null || logon < 0 || logon > 0 && AdValues.FromFileTime(logon) is null)
                    { return new FicheLogonReading(dc.DnsName, "Contrôleur", "unavailable", null, null, "lastLogon absent ou illisible"); }
                    return new FicheLogonReading(dc.DnsName, "Contrôleur", "read", AdValues.FromFileTime(logon), rows[0].Int("logonCount") is >= 0 and var count ? count : null, null);
                }
                catch (DomeniaOperationException ex) { return new FicheLogonReading(dc.DnsName, "Contrôleur", ex.Code == AdErrors.AccessDenied ? "refused" : "unavailable", null, null, ex.Message); }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return new FicheLogonReading(dc.DnsName, "Contrôleur", "timeout", null, null, "Budget de 8 s atteint"); }
            }
            finally { slots.Release(); }
        })).ConfigureAwait(false);
        EnsureEpoch(epoch);
        return new([.. readings], controllers.Length, controllers.Length > 50, interval, source.Clock.GetUtcNow());
    }

    public async Task<FichePolicyReading> PasswordPolicyAsync(string userDn, CancellationToken cancellationToken)
    {
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var epoch = await NetworkEpochAsync(userDn, budget.Token).ConfigureAwait(false);
        var user = await objects.ReadExactAsync(userDn, ["objectClass", "msDS-ResultantPSO"], TimeSpan.FromSeconds(10), budget.Token).ConfigureAwait(false)
            ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        if (AdFicheObjects.Project(user).Kind != FicheKind.User) { throw FicheErrors.Error(FicheErrors.NotApplicable, "La stratégie de mot de passe se lit pour un utilisateur."); }
        var pso = user.String("msDS-ResultantPSO");
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        if (pso is not null && !ScopeRules.Contains(new("CN=Password Settings Container,CN=System," + domain.RootDn, "", false), pso))
        { throw AdAttributeRange.Incomplete(); }
        string[] attrs = pso is null ? ["maxPwdAge", "minPwdLength", "pwdHistoryLength", "pwdProperties", "lockoutThreshold", "lockoutDuration"]
            : ["msDS-MaximumPasswordAge", "msDS-MinimumPasswordLength", "msDS-PasswordHistoryLength", "msDS-PasswordComplexityEnabled", "msDS-LockoutThreshold", "msDS-LockoutDuration"];
        var policy = await objects.ReadExactAsync(pso ?? domain.RootDn, attrs, TimeSpan.FromSeconds(10), budget.Token).ConfigureAwait(false)
            ?? throw AdAttributeRange.Incomplete();
        EnsureEpoch(epoch);
        var lastUser = await objects.ReadExactAsync(userDn, ["msDS-ResultantPSO"], TimeSpan.FromSeconds(5), budget.Token).ConfigureAwait(false)
            ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        AdFicheObjects.SameVersion(user, lastUser);
        if (!string.Equals(pso, lastUser.String("msDS-ResultantPSO"), StringComparison.OrdinalIgnoreCase)) { throw AdAttributeRange.Incomplete(); }
        EnsureEpoch(epoch);
        var age = policy.Long(attrs[0]); var duration = policy.Long(attrs[5]);
        bool? complexity = pso is null ? policy.Int(attrs[3]) is { } flags ? (flags & 1) != 0 : null
            : bool.TryParse(policy.String(attrs[3]), out var enabled) ? enabled : null;
        return new(pso is null ? "none" : "applies", pso is null ? null : FicheValues.DisplayName(pso), Interval(age), age is 0 or long.MinValue,
            Nonnegative(policy.Int(attrs[1])), Nonnegative(policy.Int(attrs[2])), complexity, Nonnegative(policy.Int(attrs[4])), Interval(duration), duration == 0,
            source.ControllerName ?? "Contrôleur non identifié", source.Clock.GetUtcNow());
    }

    private static int? Nonnegative(int? value) => value is >= 0 ? value : null;
    private static TimeSpan? Interval(long? value) => value is < 0 and > long.MinValue ? TimeSpan.FromTicks(-value.Value) : null;

    public async Task<ImmutableArray<FicheAttributeChange>> AttributeHistoryAsync(string dn, CancellationToken cancellationToken)
    {
        var entry = await objects.ReadExactAsync(dn, ["msDS-ReplAttributeMetaData"], TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false)
            ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        return ParseHistory(entry.Strings("msDS-ReplAttributeMetaData"));
    }

    internal static ImmutableArray<FicheAttributeChange> ParseHistory(IReadOnlyList<string> values)
    {
        if (values.Count > 4096 || values.Sum(v => (long)v.Length) > 4_194_304) { throw AdAttributeRange.Incomplete(); }
        var changes = ImmutableArray.CreateBuilder<FicheAttributeChange>();
        foreach (var value in values)
        {
            try
            {
                using var text = new StringReader(value.Trim('\0'));
                using var reader = XmlReader.Create(text, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65536 });
                var root = XElement.Load(reader);
                if (root.Name.LocalName != "DS_REPL_ATTR_META_DATA" || root.Elements().GroupBy(e => e.Name).Any(g => g.Count() != 1)) { throw new XmlException(); }
                string? Get(string name) => root.Element(name)?.Value;
                var attribute = Get("pszAttributeName");
                if (attribute is null || !FicheAttributeRules.IsValidName(attribute)) { throw new XmlException(); }
                if (FicheAttributeRules.IsSensitive(attribute)) { continue; }
                if (!DateTimeOffset.TryParse(Get("ftimeLastOriginatingChange"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)
                    || !int.TryParse(Get("dwVersion"), NumberStyles.None, CultureInfo.InvariantCulture, out var version) || version < 1) { throw new XmlException(); }
                var dsa = Get("pszLastOriginatingDsaDN");
                var parent = dsa is null ? null : SearchTexts.SafeParent(dsa);
                changes.Add(new(attribute, at, parent is null ? Get("uuidLastOriginatingDsaInvocationID") ?? "Non identifié" : FicheValues.DisplayName(parent), version));
            }
            catch (Exception ex) when (ex is XmlException or FormatException or ArgumentException)
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Métadonnées de réplication illisibles : historique non publié."); }
        }
        return [.. changes.OrderByDescending(c => c.At).ThenBy(c => c.Attribute, StringComparer.OrdinalIgnoreCase)];
    }
}
