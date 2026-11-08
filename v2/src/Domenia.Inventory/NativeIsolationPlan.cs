using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Closed review of native read families. Every admitted family uses the same private child boundary;
/// neither a legacy feature flag nor an explicit account permits execution in the UI process.</summary>
internal static class NativeIsolationPlan
{
    internal const uint ProcessLimit = 1;
    internal const ulong MemoryLimit = 512UL * 1024 * 1024;

    internal static string Family(NativeReadKind kind) => kind switch
    {
        NativeReadKind.Query or NativeReadKind.Metadata => "CIM",
        NativeReadKind.Registry or NativeReadKind.RegistryUser => "Registre",
        NativeReadKind.Appx or NativeReadKind.Inventory or NativeReadKind.Events or NativeReadKind.LocalAdmins => "Inventaire",
        NativeReadKind.Diagnostic or NativeReadKind.AccessTrial => "Diagnostic",
        NativeReadKind.WinRmUser => "Session WinRM",
        _ => throw new InvalidDataException("Famille native non déclarée ; aucun contact."),
    };

    internal static void CheckHello(NativeReadHello hello, bool hasPassword)
    {
        if (!CimQuery.IsHostName(hello.Host) || hello.BudgetMs is < 1 or > 300_000 || hello.Account?.Length > 512
            || hello.Transport is not (InventoryTransport.Dcom or InventoryTransport.WinRm)
            || hello.Session && hello.Account is not null || !hello.Session && string.IsNullOrWhiteSpace(hello.Account)
            || hello.Session == hasPassword)
        { throw new InvalidDataException("Session native hors contrat ; aucun contact."); }
    }

    internal static void CheckRequest(NativeReadRequest request)
    {
        _ = Family(request.Kind);
        request.Check();
    }
}
