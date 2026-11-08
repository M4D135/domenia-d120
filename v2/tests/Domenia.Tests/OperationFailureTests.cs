using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class OperationFailureTests
{
    [Test]
    public static void Native_codes_and_exception_chains_keep_authentication_distinct_from_rights_sources_and_timeouts()
    {
        foreach (var (code, kind) in new[]
        {
            (1909, OperationFailureKind.AccountLocked), (1331, OperationFailureKind.AccountUnavailable),
            (1326, OperationFailureKind.LogonFailure), (5, OperationFailureKind.AccessDenied),
            (1722, OperationFailureKind.Unavailable), (1460, OperationFailureKind.Timeout),
            (unchecked((int)0x8004100E), OperationFailureKind.ModuleUnavailable),
            (unchecked((int)0x80041003), OperationFailureKind.AccessDenied),
            (unchecked((int)0x80041069), OperationFailureKind.Timeout),
        })
        {
            var ex = new InvalidOperationException("outer text", new AggregateException(new Exception("unrelated"), new COMException("native detail", code)));
            var decision = OperationFailure.Classify(ex);
            Check.Equal(kind, decision.Kind, "chaîne complète : " + code);
            if (kind is OperationFailureKind.Timeout or OperationFailureKind.ModuleUnavailable or OperationFailureKind.Unavailable)
                Check.False(decision.CanOfferAnotherAccount, "pas de changement de compte pour la source : " + code);
        }
        Check.Equal(OperationFailureKind.AccountLocked, OperationFailure.Classify(new Win32Exception(1909)).Kind, "code natif Win32 et pas HRESULT générique");
        Check.True(WindowsAuthenticationErrors.IsRejected(unchecked((int)0x8007052E)), "HRESULT Win32 de connexion refusée");
        Check.False(WindowsAuthenticationErrors.IsRejected(unchecked((int)0x80070005)), "un refus de droit ne grille pas les identifiants");
        Check.Equal(OperationFailureKind.Unknown, OperationFailure.FromNative(unchecked((int)0x80043001)).Kind, "valeur WMI réservée, jamais devinée comme délai");
    }

    [Test]
    public static void Closed_legacy_markers_are_bounded_and_never_leak_free_text_or_change_an_uncertain_outcome()
    {
        var marker = new Exception("PRIVATE-TEXT [DOMENIA:AccountLocked;1909;0x80070775]");
        var decision = OperationFailure.Classify(marker);
        Check.Equal(OperationFailureKind.AccountLocked, decision.Kind, "marqueur fermé");
        Check.Equal(1909, decision.NativeCode, "code technique borné");
        Check.False(JsonSerializer.Serialize(decision).Contains("PRIVATE-TEXT", StringComparison.Ordinal), "texte serveur absent de la décision");
        foreach (var text in new[] { "AccessDenied", "data 775", "[DOMENIA:Invented;5;0x80070005]", "[DOMENIA:AccountLocked;99999;0x80070775]", new string('x', 8193) + marker.Message })
            Check.Equal(OperationFailureKind.Unknown, OperationFailure.Classify(new Exception(text)).Kind, "texte ambigu non interprété");
        var uncertain = OperationFailure.Classify(new TimeoutException("delayed", marker), "write.receiptsPending");
        Check.Equal(OperationFailureKind.Uncertain, uncertain.Kind, "le reçu incertain reste l’autorité");
        Check.False(uncertain.CanOfferAnotherAccount || uncertain.MayRetryRead, "aucun geste de contournement proposé");
        Check.False(OperationFailure.Classify(new TimeoutException("delayed")).CanOfferAnotherAccount, "un délai seul ne prouve pas des identifiants refusés");
        Check.Equal(OperationFailureKind.AccountLocked, OperationFailure.Classify(new TimeoutException("wrapper", new Win32Exception(1909))).Kind,
            "un vrai refus natif imbriqué reste bloquant pour protéger le compte");
        Exception bounded = new Win32Exception(1909);
        for (var i = 0; i < 100; i++) bounded = new Exception("wrapper", bounded);
        Check.Equal(OperationFailureKind.Unknown, OperationFailure.Classify(bounded).Kind, "chaîne hostile bornée à 32 nœuds");
    }

    [Test]
    public static async Task Real_bridge_transports_only_the_structured_decision_and_keeps_provider_account_protection()
    {
        var sent = new List<BridgeResponse>();
        var registry = new OperationRegistry([new OperationDefinition("test.native", OperationClass.Local,
            (_, _, _) => throw new InvalidOperationException("PRIVATE-SERVER-TEXT", new Win32Exception(1909)), "native")]);
        var dispatcher = new BridgeDispatcher(registry, sent.Add);
        await dispatcher.HandleAsync("""{"id":"r1","op":"test.native","args":{}}""", CancellationToken.None);
        var error = sent.Single().Error!;
        Check.Equal("operation.failed", error.Code, "code public stable");
        Check.Equal(OperationFailureKind.AccountLocked, error.Decision!.Kind, "décision issue de la cause native");
        Check.False(JsonSerializer.Serialize(error, BridgeJson.Options).Contains("PRIVATE-SERVER-TEXT", StringComparison.Ordinal), "aucun diagnostic serveur recopié vers la page");
        Check.Equal(BridgeProviderOutcome.CredentialRejected, BridgeScheduling.Outcome(new Exception("outer", new Win32Exception(1909))), "le budget protège aussi la chaîne native");
        Check.Equal(BridgeProviderOutcome.Refused, BridgeScheduling.Outcome(new COMException("absent", unchecked((int)0x80041010))), "classe absente ne pénalise pas le réseau");
    }
}
