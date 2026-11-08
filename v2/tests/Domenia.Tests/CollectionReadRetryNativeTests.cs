using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CollectionReadRetryNativeTests
{
    [Test]
    public static void Native_retry_classification_uses_closed_codes_never_error_text()
    {
        Check.Equal(CollectionReadFailure.Transient, CimSession.RetryFailure(new TimeoutException(), SourceStatus.Interrupted), "délai source qualifié");
        Check.Equal(CollectionReadFailure.Cancelled, CimSession.RetryFailure(new OperationCanceledException(), SourceStatus.Interrupted), "arrêt utilisateur");
        Check.Equal(CollectionReadFailure.Unknown, CimSession.RetryFailure(new IOException("timeout après mot de passe refusé"), SourceStatus.Error), "texte non interprété");
        Check.Equal(CollectionReadFailure.CredentialRejected, CimSession.RetryFailure(new COMException("", unchecked((int)0x8007052E)), SourceStatus.Refused), "identifiants rejetés");
        Check.Equal(CollectionReadFailure.AccessDenied, CimSession.RetryFailure(new UnauthorizedAccessException(), SourceStatus.Refused), "droits refusés");
        Check.Equal(CollectionReadFailure.ClassAbsent, CimSession.RetryFailure(new COMException("", unchecked((int)0x80041010)), SourceStatus.Unavailable), "classe absente");
        Check.Equal(CollectionReadFailure.ProtocolUnavailable, CimSession.RetryFailure(new COMException("", unchecked((int)0x800706BA)), SourceStatus.Unreachable), "RPC inaccessible même si le ping répond");
    }

    [Test]
    public static async Task Native_light_inventory_reports_its_transient_failure_only_after_worker_disposal()
    {
        var clock = TimeProvider.System;
        var probe = new WmiWorkstationProbe(clock)
        {
            SessionFactory = (host, timeout, token) => new CimSession(host, timeout, clock, cancellationToken: token)
            {
                ReadOverride = (_, query, _) => query.Contains("Win32_OperatingSystem", StringComparison.Ordinal)
                    ? throw new TimeoutException()
                    : query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                        ? [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC-TEST", ["DNSHostName"] = "PC-TEST", ["Domain"] = "test.local", ["UserName"] = null })]
                        : [],
            },
        };
        var read = await probe.ReadFactsAsync("PC-TEST", TimeSpan.FromSeconds(15), default);
        Check.True(read.ReadPhysicallyCompleted, "le worker et sa session ont terminé");
        Check.Equal("PC-TEST", read.ReportedName, "identité reçue");
        Check.Equal(CollectionReadFailure.Transient, read.RetryFailure, "le disque non envoyé garde la cause de son prérequis");
        // Missing system drive must never be promoted to a healthy inventory.
        Check.False(read.Inventory.HasReading, "inventaire incomplet conservé comme tel");
        Check.False(read.AuthenticationRejected, "un délai ne devient pas un refus d’identifiants");
    }

    [Test]
    public static async Task Native_console_failure_reaches_the_real_reader_with_physical_completion_evidence()
    {
        var clock = TimeProvider.System;
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, timeout, token) => new CimSession(host, timeout, clock, cancellationToken: token)
            { ReadOverride = (_, _, _) => throw new TimeoutException() },
        };
        var result = await reader.ReadConsoleAccountAsync("PC-TEST", default);
        Check.NotNull(result, "résultat de la source console");
        Check.Equal(CollectionReadFailure.Transient, result!.RetryFailure, "classification native propagée");
        Check.True(result.ReadPhysicallyCompleted, "la tâche réelle a rendu sa place avant le retour");
        Check.False(result.Answered, "le délai ne prouve aucun compte connecté");
    }
}
