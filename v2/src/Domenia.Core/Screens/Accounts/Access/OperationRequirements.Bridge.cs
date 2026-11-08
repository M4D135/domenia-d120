namespace Domenia.Core;

public static partial class OperationRequirements
{
    /// <summary>Explicit links to the current bridge contract. No name-prefix or message-text inference.</summary>
    public static OperationRequirement ForBridge(string operation)
    {
        var legacy = operation switch
        {
            "search.run" or "search.more" or "search.recipe.run" or "search.recipe.more" => "GlobalSearch",
            "search.reconcile" or "search.revalidate" or "search.recheck" => "ScopeReconcile",
            "directory.branch.children" or "directory.ou.children" or "directory.ou.search" => "TreeChildren",
            "fiche.read" or "fiche.attributes" or "accounts.detail" or "accounts.list" => "OpenAdObject",
            "fiche.resolve" or "fiche.pick" => "OpenLinkedObject",
            "fiche.rights" or "audit.object.acl" or "audit.object.estimate" => "PermissionAnalysis",
            "fiche.lockouts" or "accounts.lockouts" => "LockoutDiagnosis",
            "fiche.logonByDc" or "poste.logonByDc" => "LogonHarvest",
            "fiche.groups" or "fiche.groups.nested" or "fiche.groups.why" or "fiche.members" or "audit.object.groupPath" => "GroupPathRead",
            "audit.object.gpoLinks" => "GpoLinksRead",
            "audit.object.policy" => "PasswordPolicyRead",
            "audit.dc.compare" => "DcCompareRead",
            "audit.identities.scan" => "AdConsistencyScan",
            "poste.inventory" => "ComputerInventory",
            "poste.diagnostic" or "poste.quickDiag" => "ComputerDiagnostics",
            "poste.lastUser.detect" => "ComputerLastUser",
            "poste.ping" => "ComputerPing",
            "search.netdiag" => "BatchNetworkDiag",
            "poste.sessions" or "poste.restart.sessions" => "SessionsList",
            "poste.laps" or "poste.laps.reveal" => "ReadLaps",
            "poste.bitlocker.list" => "ReadBitLockerList",
            "poste.bitlocker.reveal" => "ReadBitLockerKey",
            "accueil.bitlocker.read" => "BitLockerPresence",
            _ => null,
        };
        return For(legacy ?? operation) with { Id = operation };
    }
}
