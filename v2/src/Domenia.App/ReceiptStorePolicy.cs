using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

/// <summary>A native E2E run uses a separate durable journal; it never weakens the production write contract.</summary>
internal static class ReceiptStorePolicy
{
    internal static IReceiptStore Create(AppMode mode, bool isolated, string? userFolder, ITechnicalJournal log)
    {
        if (isolated && mode == AppMode.Simulation)
        {
            log.Info("Reçus simulés en mémoire pour la capture ou les scénarios E2E.");
            return new MemoryReceiptStore();
        }
        if (string.IsNullOrWhiteSpace(userFolder) || !Path.IsPathFullyQualified(userFolder))
        {
            log.Warning("Dossier local des reçus indisponible : écritures réelles refusées, aucun repli en mémoire.");
            return mode == AppMode.Simulation ? new MemoryReceiptStore() : new UnavailableReceipts();
        }
        var path = isolated
            ? Path.Combine(userFolder, "E2E", "receipts-annuaire.jsonl")
            : Path.Combine(userFolder, FileReceiptStore.FileNameFor(mode));
        if (isolated) { log.Info("Recette annuaire : reçus durables séparés dans E2E, conservés entre les scénarios et les redémarrages."); }
        return new FileReceiptStore(path, log);
    }

    private sealed class UnavailableReceipts : IReceiptStore
    {
        public bool Persistent => false;
        private static IOException Failure() => new("Journal durable indisponible. Aucune écriture réelle autorisée avant le rétablissement du stockage des reçus.");
        public Task AppendAsync(WriteReceipt receipt, CancellationToken cancellationToken) => Task.FromException(Failure());
        public Task<ReceiptLog> ReadAllAsync(CancellationToken cancellationToken) => Task.FromException<ReceiptLog>(Failure());
    }
}
