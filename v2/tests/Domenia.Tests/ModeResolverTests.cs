using Domenia.Core;

namespace Domenia.Tests;

internal static class ModeResolverTests
{
    private static readonly DomainJoinInfo Joined = new(DomainJoinState.Joined, "cnamts.local");

    private static Func<DomainJoinInfo> Probe(DomainJoinInfo info, Action? called = null) => () =>
    {
        called?.Invoke();
        return info;
    };

    private static DomainJoinInfo NeverCalled() => throw new TestFailureException("la sonde de jonction ne devait pas être appelée");

    [Test]
    public static void Argument_wins_over_the_variable_and_the_join_state()
    {
        var decision = ModeResolver.Resolve(["--simulation"], "0", NeverCalled);
        Check.Equal(AppMode.Simulation, decision.Mode, "mode");
        Check.Equal(ModeReason.Argument, decision.Reason, "raison");
        Check.Equal(ModeTexts.DetailArgument, decision.Detail, "détail");
        Check.Equal(ModeTexts.Banner, decision.Banner, "bannière");
    }

    [Test]
    public static void Variable_one_and_zero_decide_without_probing()
    {
        Check.Equal(ModeReason.Environment, ModeResolver.Resolve([], "1", NeverCalled).Reason, "1");
        Check.Equal(ModeReason.Environment, ModeResolver.Resolve([], " 1 ", NeverCalled).Reason, "1 entouré d’espaces");
        var optOut = ModeResolver.Resolve([], "0", NeverCalled);
        Check.Equal(AppMode.Directory, optOut.Mode, "0 force l’annuaire");
        Check.Equal(ModeReason.EnvironmentOptOut, optOut.Reason, "raison 0");
        Check.Null(optOut.Banner, "pas de bannière en annuaire");
    }

    [Test]
    public static void Other_variable_values_are_ignored_with_a_warning()
    {
        foreach (var value in new[] { "true", "oui", "2" })
        {
            var probed = false;
            var decision = ModeResolver.Resolve([], value, Probe(new DomainJoinInfo(DomainJoinState.Workgroup, null), () => probed = true));
            Check.True(probed, "sonde appelée pour " + value);
            Check.Equal(ModeReason.NotDomainJoined, decision.Reason, "raison pour " + value);
            Check.Equal(1, decision.Warnings.Length, "un avertissement pour " + value);
            Check.Equal(ModeTexts.WarningVariable, decision.Warnings[0], "texte de l’avertissement");
        }
    }

    [Test]
    public static void Join_state_decides_when_nothing_else_does()
    {
        Check.Equal(ModeReason.NotDomainJoined, ModeResolver.Resolve([], null, Probe(new DomainJoinInfo(DomainJoinState.Workgroup, "WORKGROUP"))).Reason, "groupe de travail");
        Check.Equal(ModeReason.NotDomainJoined, ModeResolver.Resolve([], null, Probe(new DomainJoinInfo(DomainJoinState.Unjoined, null))).Reason, "non joint");
        var unknown = ModeResolver.Resolve([], null, Probe(new DomainJoinInfo(DomainJoinState.Unknown, null)));
        Check.Equal(AppMode.Simulation, unknown.Mode, "illisible → simulation");
        Check.Equal(ModeReason.JoinStateUnknown, unknown.Reason, "raison illisible");
        var joined = ModeResolver.Resolve([], "", Probe(Joined));
        Check.Equal(AppMode.Directory, joined.Mode, "joint → annuaire");
        Check.Equal(ModeReason.DomainJoined, joined.Reason, "raison joint");
        Check.Equal("Poste joint au domaine cnamts.local.", joined.Detail, "nom du domaine dans le détail");
        Check.Equal("cnamts.local", joined.JoinedDomain, "domaine retenu");
        Check.Equal(0, joined.Warnings.Length, "variable vide sans avertissement");
    }

    [Test]
    public static void Argument_is_case_insensitive_but_exact()
    {
        Check.Equal(ModeReason.Argument, ModeResolver.Resolve(["--SIMULATION"], null, NeverCalled).Reason, "majuscules admises");
        var notRecognized = ModeResolver.Resolve(["--simulation=1", "-simulation", "/p:secret"], null, Probe(Joined));
        Check.Equal(ModeReason.DomainJoined, notRecognized.Reason, "formes voisines non reconnues");
        Check.Equal(1, notRecognized.Warnings.Length, "un seul avertissement");
        Check.Contains("3 arguments", notRecognized.Warnings[0], "arguments comptés");
        Check.False(notRecognized.Warnings[0].Contains("secret", StringComparison.Ordinal), "argument jamais recopié");
    }

    [Test]
    public static void App_info_has_a_banner_only_in_simulation()
    {
        var simulation = AppInfoBuilder.Build(ModeResolver.Resolve(["--simulation"], null, NeverCalled), "10.0.12", "embarque");
        Check.Equal("simulation", simulation.Mode, "mode simulation");
        Check.Equal("Simulation", simulation.ModeLabel, "libellé simulation");
        Check.Equal(ModeTexts.Banner, simulation.Banner, "bannière");
        Check.Equal(ProductInfo.Version, simulation.Version, "version");

        var directory = AppInfoBuilder.Build(ModeResolver.Resolve([], null, Probe(Joined)), "10.0.12", "windows");
        Check.Equal("annuaire", directory.Mode, "mode annuaire");
        Check.Equal("Annuaire Active Directory", directory.ModeLabel, "libellé annuaire");
        Check.Null(directory.Banner, "aucune bannière");

        Check.Equal("Variable DOMENIA_SIMULATION=1 présente.", AppInfoBuilder.Build(ModeResolver.Resolve([], "1", NeverCalled), "x", "x").ModeDetail, "détail environment");
        Check.Equal("Ce poste n’est joint à aucun domaine : démarrage en simulation.",
            AppInfoBuilder.Build(ModeResolver.Resolve([], null, Probe(new DomainJoinInfo(DomainJoinState.Unjoined, null))), "x", "x").ModeDetail, "détail hors domaine");
    }
}
