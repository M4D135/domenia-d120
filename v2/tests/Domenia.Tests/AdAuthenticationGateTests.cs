using System.DirectoryServices.Protocols;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdAuthenticationGateTests
{
    [Test]
    public static void Alternate_account_connections_share_a_pause_only_for_the_same_source_epoch_and_selection()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap);
        var first = AdAuthenticationGate.ForSelection(source, "account-a", 1, 3);
        first.ObserveFailure(new LdapException(49));
        var shared = AdAuthenticationGate.ForSelection(source, "account-a", 1, 3);
        Check.True(ReferenceEquals(first, shared), "copie pour le même compte et la même sélection");
        Check.Throws<DomeniaOperationException>(() => shared.RequireAvailable(), "refus commun");
        AdAuthenticationGate.ForSelection(source, "account-b", 1, 3).RequireAvailable();
        AdAuthenticationGate.ForSelection(source, "account-a", 1, 4).RequireAvailable();
        AdAuthenticationGate.ForSelection(source, "account-a", 2, 4).RequireAvailable();
        Check.Throws<DomeniaOperationException>(() => AdAuthenticationGate.ForSelection(source, "account-a", 1, 3), "une copie ancienne ne remplace pas la génération actuelle");
        Check.Throws<DomeniaOperationException>(() => first.RequireAvailable(), "un ancien lecteur conservé ne se réactive pas");
    }

    [Test]
    public static async Task Queued_binds_share_one_credential_refusal_and_never_try_the_same_rejected_identity_again()
    {
        var gate = new AdAuthenticationGate(); var calls = 0;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = gate.BindAsync(async () => { Interlocked.Increment(ref calls); entered.SetResult(); await release.Task; throw new LdapException(49); }, default);
        await entered.Task;
        var queued = Enumerable.Range(0, 32).Select(_ => gate.BindAsync(() => { Interlocked.Increment(ref calls); return Task.CompletedTask; }, default)).ToArray();
        release.SetResult();
        await Check.ThrowsAsync<LdapException>(() => first, "le premier refus est conservé");
        foreach (var task in queued)
        {
            var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => task, "aucun nouvel essai avec le même secret");
            Check.Equal(AdErrors.Credentials, refusal.Code, "reconnexion proposée");
        }
        Check.Equal(1, calls, "un refus ne devient pas 33 tentatives");
        gate.ObserveFailure(new LdapException(81));
        Check.Throws<DomeniaOperationException>(() => gate.RequireAvailable(), "une panne réseau ultérieure ne réactive pas le compte");
        await new AdAuthenticationGate().BindAsync(() => Task.CompletedTask, default);
    }

    [Test]
    public static async Task Transport_or_rights_failures_and_queue_cancellation_do_not_mark_valid_credentials_as_rejected()
    {
        foreach (var code in new[] { 50, 81, 85 })
        {
            var gate = new AdAuthenticationGate();
            await Check.ThrowsAsync<LdapException>(() => gate.BindAsync(() => throw new LdapException(code), default), "erreur d’origine");
            gate.RequireAvailable();
            await gate.BindAsync(() => Task.CompletedTask, default);
        }
        var waitingGate = new AdAuthenticationGate();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var held = waitingGate.BindAsync(() => release.Task, default);
        using var stop = new CancellationTokenSource();
        var waiting = waitingGate.BindAsync(() => throw new InvalidOperationException("Aucun bind attendu"), stop.Token);
        stop.Cancel(); await Check.ThrowsAsync<OperationCanceledException>(() => waiting, "annulation avant envoi");
        release.SetResult(); await held;
        waitingGate.RequireAvailable();
    }
}
