using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class OperationCredentialNeedsTests
{
    [Test]
    public static void Every_real_network_export_has_a_closed_credential_contract_or_its_typed_write_dispatch()
    {
        var source = new UnavailableDirectorySource("test.local", () => @"TEST\operator");
        using var context = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), source,
            new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(OperationModules).Assembly]));
        var absent = registry.Names.Where(n => registry.TryGet(n, out var d) && d.Class == OperationClass.NetworkRead && n is not ("write.receipts.verify" or "poste.account.other")
            && !OperationCredentialNeeds.ForRead(n).Known).Order(StringComparer.Ordinal).ToArray();
        Check.Equal("", string.Join(", ", absent), "contrat explicite pour toutes les routes réseau actuelles");
        Check.False(OperationCredentialNeeds.ForRead("poste.future").Known, "aucune autorisation par préfixe");
    }
    [Test]
    public static async Task Read_scope_denies_other_channels_survives_await_and_restores_the_parent()
    {
        using var outer = OperationCredentialScope.Enter(OperationCredentialNeeds.ForRead("search.run"));
        OperationCredentialScope.RequireDirectory(CredentialRules.Directory); await Task.Yield();
        Check.Throws<DomeniaOperationException>(OperationCredentialScope.RequireRemote, "recherche sans secret distant");
        using (OperationCredentialScope.Enter(OperationCredentialNeeds.ForRead("poste.laps")))
        {
            OperationCredentialScope.RequireDirectory(CredentialRules.Laps);
            Check.Throws<DomeniaOperationException>(() => OperationCredentialScope.RequireDirectory(CredentialRules.BitLocker), "ressources secrètes séparées");
            Check.Throws<DomeniaOperationException>(() => OperationCredentialScope.RequireDirectory(CredentialRules.Directory), "pas de rabattement annuaire");
        }
        OperationCredentialScope.RequireDirectory(CredentialRules.Directory);
        Check.Equal(OperationCredentialChannel.None, OperationCredentialNeeds.ForRead("search.recheck", "ping").Channels, "ping sans identifiants");
        Check.Equal(OperationCredentialChannel.Directory | OperationCredentialChannel.Remote, OperationCredentialNeeds.ForRead("search.recheck").Channels, "mode console historique par défaut");
        Check.Equal(OperationCredentialChannel.Directory, OperationCredentialNeeds.ForRead("poste.ping").Channels, "identité AD mais aucun secret réseau");
        Check.Equal(OperationCredentialChannel.Directory, OperationCredentialNeeds.ForWrite(PosteRemoteWrites.WakeKind).Channels, "réveil sans copie distante");
        var other = OperationCredentialNeeds.ForRead("poste.account.other", resource: "laps"); other.RequireAuthentication(); other.RequireDirectory(CredentialRules.Laps);
        Check.Throws<DomeniaOperationException>(other.RequireRemote, "autre compte secrets ne donne aucun accès poste");
        Check.False(OperationCredentialNeeds.ForRead("poste.account.other", resource: "future").Known, "ressource fermée");
    }
}
