using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class PosteSessionPresentationTests
{
    [Test]
    public static void A_partial_or_cached_empty_list_cannot_authorize_a_restart_as_if_no_user_were_connected()
    {
        var empty = PosteSessions.View("PC1", SourceStatus.Empty, [], Fixtures.Now, "Opérateur", TestClock.Paris);
        foreach (var uncertain in new[] { empty with { Cached = true }, empty with { Partial = true }, empty with { ReadAt = null }, empty with { UnreadSessions = 1 } })
        {
            var restart = PosteSessions.ForRestart(uncertain, null);
            Check.False(restart.Known, "sessions actuelles inconnues"); Check.Equal(-1, restart.Count, "pas de faux zéro");
        }
        Check.True(PosteSessions.ForRestart(empty, null).Known, "une vraie liste vide fraîche demeure exploitable");
    }

    [Test]
    public static void A_partial_restart_summary_keeps_the_known_people_visible_without_claiming_a_total()
    {
        var list = PosteSessions.View("PC1", SourceStatus.Partial,
            [new("1", "RDP-Tcp#1", "alice", "TEST", "Active", "RDP", null, null, null)], Fixtures.Now, "Opérateur", TestClock.Paris, 2);
        var restart = PosteSessions.ForRestart(list, null);
        Check.False(restart.Known, "total inconnu"); Check.Equal(1, restart.Lines.Length, "utilisatrice connue conservée");
        Check.True(restart.Lines[0].Contains("TEST\\alice", StringComparison.Ordinal), "identité qualifiée visible");
    }

    [Test]
    public static async Task Simulation_also_keeps_the_domain_when_opening_a_session_account()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        var directory = source.CurrentDirectory; var user = directory.Users.First(); var reader = new SimulatedPosteReader(source);
        Check.Null(await reader.FindAccountAsync("OTHER\\" + user.SamAccountName, CancellationToken.None), "aucun homonyme étranger");
        Check.Null(await reader.FindAccountAsync(user.SamAccountName + "@foreign.invalid", CancellationToken.None), "aucun UPN inventé");
        Check.Equal(user.ObjectGuid, (await reader.FindAccountAsync(directory.Domain.NetbiosName + "\\" + user.SamAccountName, CancellationToken.None))!.Guid!.Value, "identité du domaine de simulation");
    }
}
