using System.Runtime.InteropServices;
using System.Security;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CimProjectionPlanTests
{
    private const string Ns = @"root\cimv2";
    private const string Name = "SELECT Name FROM Win32_ComputerSystem";
    private const string Model = "SELECT Model FROM Win32_ComputerSystem";
    private static WmiInstance Row() => new(new Dictionary<string, object?> { ["Name"] = "PC1", ["Model"] = "Model 1" });

    [Test]
    public static void Optimization_limits_and_failing_telemetry_never_disable_a_valid_read()
    {
        using var session = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed()) { ReadOverride = (_, _, _) => [Row()] };
        session.PlanProjections(Enumerable.Repeat(new CimProjection(Ns, Name, 1), 257));
        Check.Equal(SourceStatus.Ok, session.Read("a", Ns, Name, 1).Status, "hors plafond d’optimisation conserve la lecture ordinaire");
        session.PlanProjections([new(Ns, Name, 1), new(Ns, Model, 1)], () => throw new InvalidOperationException("diagnostic"));
        session.Read("b", Ns, Name, 1);
        Check.Equal("Model 1", session.Read("c", Ns, Model, 1).Instances.Single().Text("Model"), "une panne du compteur ne perd pas les données");
        Check.Equal(2, session.QueriesIssued, "lecture normale puis union, aucune requête provoquée par le diagnostic");
    }

    [Test]
    public static void Wrapped_native_authentication_rejection_stops_later_queries_without_conflating_a_timeout()
    {
        var calls = 0;
        using var rejected = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed())
        { ReadOverride = (_, _, _) => { calls++; throw new InvalidOperationException("wrapper", new COMException("native", unchecked((int)0x80070775))); } };
        var first = rejected.Read("a", Ns, Name, 1);
        Check.Equal(SourceStatus.Refused, first.Status, "1909 verrouillage reconnu dans la chaîne"); Check.True(first.AuthenticationRejected, "refus marqué");
        Check.Equal(CollectionReadFailure.CredentialRejected, first.RetryFailure, "même fait natif sur le pipe : pas AccessDenied avec AuthenticationRejected=true");
        Check.True(rejected.Read("b", Ns, Model, 1).AuthenticationRejected, "état terminal conservé"); Check.Equal(1, calls, "aucun deuxième appel");
        Check.Equal(SourceStatus.Interrupted, CimSession.Classify(new TimeoutException()), "timeout seul ne bloque pas des identifiants");
        Check.Equal(SourceStatus.Unreachable, CimSession.Classify(new COMException("RPC", unchecked((int)0x800706BA))), "réseau distinct d’une classe absente");
    }

    [Test]
    public static void Real_session_issues_union_once_projects_exact_columns_and_keeps_identity_checks_fresh()
    {
        var calls = new List<string>(); var completed = 0; var avoided = 0;
        using var session = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed())
        { ReadOverride = (_, query, _) => { calls.Add(query); return [Row()]; }, QueryCompleted = () => completed++ };
        session.PlanProjections([new(Ns, Name, 1), new(Ns, Model, 1)], () => avoided++);
        Check.Equal(SourceStatus.Ok, session.Read("before", Ns, Name, 1, allowProjectionReuse: false).Status, "identité initiale");
        var first = session.Read("one", Ns, Name, 1); var second = session.Read("two", Ns, Model, 1);
        Check.Equal("SELECT Name, Model FROM Win32_ComputerSystem", calls[1], "union réellement transmise");
        Check.True(first.Instances.Single().Names.SequenceEqual(new[] { "Name" }), "colonnes du premier demandeur");
        Check.True(second.Instances.Single().Names.SequenceEqual(new[] { "Model" }), "colonnes du second demandeur");
        Check.Equal("Model 1", second.Instances.Single().Text("Model"), "projection de la réponse réelle");
        Check.Equal(2, calls.Count, "une union plus l’identité initiale"); Check.Equal(1, avoided, "économie consommée seulement");
        Check.Equal(2, completed, "cache ne crédite pas une nouvelle progression native");
        session.Read("after", Ns, Name, 1, allowProjectionReuse: false);
        session.Read("second sample", Ns, Model, 1);
        Check.Equal(4, calls.Count, "contrôle final et demande hors plan relus");
    }

    [Test]
    public static void Exact_filters_are_not_coalesced_and_partial_counts_never_become_complete()
    {
        var calls = 0;
        using var session = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed())
        { ReadOverride = (_, _, _) => { calls++; return [Row(), Row()]; } };
        const string a = "SELECT Name FROM Win32_ComputerSystem WHERE Name='PC1'";
        const string b = "SELECT Model FROM Win32_ComputerSystem WHERE Name = 'PC1'";
        session.PlanProjections([new(Ns, a, 2), new(Ns, b, 2)]);
        session.Read("a", Ns, a, 2); session.Read("b", Ns, b, 2);
        Check.Equal(2, calls, "aucune équivalence approximative de filtre");
        session.PlanProjections([new(Ns, Name, 1), new(Ns, Model, 2)]);
        var one = session.Read("one", Ns, Name, 1); var two = session.Read("two", Ns, Model, 2);
        Check.Equal(SourceStatus.Partial, one.Status, "un élément conservé sur deux"); Check.Equal(1, one.Items, "cap individuel");
        Check.Equal(SourceStatus.Ok, two.Status, "ensemble réellement terminé réutilisé"); Check.Equal(2, two.Items, "cap de l’autre projection");
        Check.Equal(3, calls, "union commune mais statuts par demandeur");
    }

    [Test]
    public static void Only_explicit_projection_rejection_splits_and_missing_columns_are_incomplete()
    {
        foreach (var code in new[] { unchecked((int)0x80041017), unchecked((int)0x80070005), unchecked((int)0x8007052E), unchecked((int)0x800706BA) })
        {
            var calls = 0;
            using var session = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed())
            { ReadOverride = (_, query, _) => { calls++; if (query.Contains("Name, Model", StringComparison.Ordinal)) { throw new COMException("Provider", code); } return [Row()]; } };
            session.PlanProjections([new(Ns, Name, 1), new(Ns, Model, 1)]);
            var result = session.Read("one", Ns, Name, 1);
            Check.Equal(code == unchecked((int)0x80041017) ? 2 : 1, calls, "aucun repli sur refus ou panne réseau");
            Check.Equal(code == unchecked((int)0x80041017), result.Status == SourceStatus.Ok, "succès seulement après rejet de projection confirmé");
        }
        using var missing = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed())
        { ReadOverride = (_, _, _) => [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1" })] };
        missing.PlanProjections([new(Ns, Name, 1), new(Ns, Model, 1)]);
        Check.Equal(SourceStatus.Partial, missing.Read("one", Ns, Name, 1).Status, "réponse commune incomplète annoncée");
        Check.Equal(1, missing.QueriesIssued, "aucun rejeu automatique pour une réponse incomplète");
    }

    [Test]
    public static void Scoped_plan_crosses_real_sessions_but_never_hosts_transports_or_owner_changes()
    {
        var calls = 0; var current = true; var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false);
        using var plan = new CimProjectionScope("PC1", InventoryTransport.Dcom, null,
            [new(Ns, Name, 1), new(Ns, Model, 1)], () => { if (!current) { throw new InvalidOperationException("Contexte modifié"); } }, activity.RecordGroupedCimReuse);
        CimSession Session(string host = "PC1", InventoryTransport transport = InventoryTransport.Dcom) =>
            new(host, TimeSpan.FromSeconds(60), TestClock.Fixed(), transport: transport) { ReadOverride = (_, _, _) => { calls++; return [Row()]; } };
        using (var first = Session()) { first.Read("first", Ns, Name, 1); }
        using (var other = Session("PC2")) { other.Read("other host", Ns, Model, 1); }
        using (var other = Session(transport: InventoryTransport.WinRm)) { other.Read("other transport", Ns, Model, 1); }
        using (var second = Session()) { second.Read("second", Ns, Model, 1); Check.Equal(0, second.QueriesIssued, "réutilisation entre deux vraies sessions"); }
        Check.Equal(3, calls, "les deux contextes étrangers ne consomment pas le plan");
        Check.Equal(1L, activity.GroupedCimQueriesAvoided, "compteur de session réel");
        current = false;
        using var stale = Session();
        Check.Throws<InvalidOperationException>(() => stale.Read("stale", Ns, Model, 1), "propriétaire invalidé avant lecture");
        Check.Equal(3, calls, "aucun appel après invalidation");
    }

    [Test]
    public static void Explicit_account_projections_are_never_reused_by_another_account_or_the_Windows_session()
    {
        using var secret = new SecureString(); secret.AppendChar('x'); secret.MakeReadOnly();
        using var account = new RemoteProbeCredential(@"TEST\reader", secret.Copy(), false);
        using var sameAccount = new RemoteProbeCredential(account.Account, secret.Copy(), false);
        using var otherAccount = new RemoteProbeCredential(@"TEST\other", secret.Copy(), false);
        using var plan = new CimProjectionScope("PC1", InventoryTransport.Dcom, account, [new(Ns, Name, 1), new(Ns, Model, 1)], () => { });
        var calls = 0;
        CimSession Session(RemoteProbeCredential? credential) => new("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed(), credential: credential)
        { ReadOverride = (_, _, _) => { calls++; return [Row()]; } };
        using (var first = Session(account)) { first.Read("first", Ns, Name, 1); }
        using (var other = Session(otherAccount)) { other.Read("other account", Ns, Model, 1); }
        using (var windows = Session(null)) { windows.Read("Windows", Ns, Model, 1); }
        using (var matching = Session(sameAccount))
        {
            Check.Equal("Model 1", matching.Read("same account", Ns, Model, 1).Instances.Single().Text("Model"), "réponse du même compte explicite");
            Check.Equal(0, matching.QueriesIssued, "même compte qualifié réutilise sa projection");
        }
        Check.Equal(3, calls, "les deux autres identités ont réellement relu sans consommer le plan");
    }
}
