using Domenia.Core;

namespace Domenia.Tests;

internal static class CollectionNetworkPolicyTests
{
    [Test]
    public static void Direct_reads_require_opt_in_and_a_completed_echo_never_a_dns_or_target_error()
    {
        var noReply = new PresenceMeasure(MeasureState.Known, false, Fixtures.Now, null)
        { Diagnostic = new(PresenceReadOutcome.NoReply, "icmp") };
        Check.False(CollectionNetworkPolicy.Read(null), "option désactivée par défaut");
        Check.False(CollectionNetworkPolicy.Eligible(noReply, false), "absence de réponse bloquée sans accord");
        Check.True(CollectionNetworkPolicy.Eligible(noReply, true), "un essai direct autorisé");
        foreach (var failure in Enum.GetValues<PresenceReadOutcome>().Where(v => v is not (PresenceReadOutcome.NoReply or PresenceReadOutcome.Reply)))
        { Check.False(CollectionNetworkPolicy.Eligible(noReply with { Diagnostic = new(failure, "test") }, true), "échec avant écho : " + failure); }
        Check.False(CollectionNetworkPolicy.Eligible(PresenceMeasure.Unread, true), "jamais lu n'est pas sans réponse");
        Check.False(CollectionNetworkPolicy.Eligible(noReply with { State = MeasureState.Error }, true), "erreur ne devient pas succès");
        using (CollectionNetworkPolicy.Enter(true))
        {
            Check.True(CollectionNetworkPolicy.Read(null), "plan fige son option");
            using (CollectionNetworkPolicy.Enter(false)) Check.False(CollectionNetworkPolicy.Read(null), "portée interne explicite");
            Check.True(CollectionNetworkPolicy.Read(null), "option du plan rétablie");
        }
        Check.False(CollectionNetworkPolicy.Read(null), "aucune fuite vers une autre campagne");
    }
}
