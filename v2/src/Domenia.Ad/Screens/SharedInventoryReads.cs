using System.Runtime.CompilerServices;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Only identical native reads within one AD source and one selected credential generation may share work.</summary>
internal sealed record InventoryReadKey(Guid ObjectGuid, string Dn, DateTimeOffset CreatedAt, string Host,
    WorkstationReading Reading, string CredentialGeneration, bool Cim, bool Registry, bool WinRm);

internal sealed class SharedInventoryReads
{
    private static readonly ConditionalWeakTable<AdDirectorySource, SharedInventoryReads> Sources = new();
    private readonly Lock gate = new();
    private readonly Dictionary<InventoryReadKey, Entry> active = [];
    private readonly ITechnicalJournal? journal;
    internal SharedInventoryReads(ITechnicalJournal? journal = null) => this.journal = journal;
    internal static SharedInventoryReads For(AdDirectorySource source) => Sources.GetValue(source, s => new(s.AccountContext?.Log));

    internal async Task<(InventorySnapshot Value, bool Shared)> ReadAsync(InventoryReadKey key,
        Func<IProgress<PosteProgress>, CancellationToken, Task<InventorySnapshot>> read,
        IProgress<PosteProgress>? progress, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        Entry entry; bool shared; var subscriber = new object();
        lock (gate)
        {
            shared = active.TryGetValue(key, out entry!);
            if (shared && (entry.Closing || entry.Stop.IsCancellationRequested))
            { throw Busy("La lecture identique arrêtée se termine encore ; aucun nouveau worker lancé."); }
            if (shared && entry.Subscribers.Count >= 64 || !shared && active.Count >= 32)
            { throw Busy("Capacité des lectures partagées atteinte ; aucune demande ajoutée."); }
            if (!shared) { active[key] = entry = new(); }
            entry.Subscribers.Add(subscriber, progress);
        }
        if (!shared) { _ = RunAsync(key, entry, read); }
        try { return (await entry.Result.Task.WaitAsync(token).ConfigureAwait(false), shared); }
        finally
        {
            var cancel = false;
            lock (gate)
            {
                entry.Subscribers.Remove(subscriber);
                cancel = entry.Subscribers.Count == 0 && !entry.Finished;
                if (cancel) { entry.Closing = true; }
            }
            if (cancel)
            {
                try { entry.Stop.Cancel(); }
                catch (ObjectDisposedException) { /* Native worker finished between release and cancellation. */ }
            }
        }
    }

    private async Task RunAsync(InventoryReadKey key, Entry entry, Func<IProgress<PosteProgress>, CancellationToken, Task<InventorySnapshot>> read)
    {
        InventorySnapshot? value = null; Exception? error = null;
        try { value = await read(new Relay(this, entry), entry.Stop.Token).ConfigureAwait(false); }
        catch (Exception ex) { error = ex; }
        finally
        {
            // Remove before releasing results: a later read never becomes a cache hit on a completed worker.
            lock (gate) { entry.Finished = true; active.Remove(key); }
            entry.Stop.Dispose();
        }
        if (error is OperationCanceledException canceled) { entry.Result.TrySetCanceled(canceled.CancellationToken); }
        else if (error is not null) { entry.Result.TrySetException(error); _ = entry.Result.Task.Exception; }
        else { entry.Result.TrySetResult(value!); }
    }

    private void Publish(Entry entry, PosteProgress value)
    {
        IProgress<PosteProgress>[] subscribers;
        lock (gate) { subscribers = entry.Subscribers.Values.OfType<IProgress<PosteProgress>>().ToArray(); }
        foreach (var subscriber in subscribers)
        {
            try { subscriber.Report(value); }
            catch (Exception ex) { journal?.Warning("Publication d’une lecture partagée non reçue (" + ex.GetType().Name + ")."); }
        }
    }
    private static DomeniaOperationException Busy(string text) => new("machine.busy", text);
    private sealed class Relay(SharedInventoryReads owner, Entry entry) : IProgress<PosteProgress>
    { public void Report(PosteProgress value) => owner.Publish(entry, value); }
    private sealed class Entry
    {
        public CancellationTokenSource Stop { get; } = new();
        public TaskCompletionSource<InventorySnapshot> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Dictionary<object, IProgress<PosteProgress>?> Subscribers { get; } = [];
        public bool Finished { get; set; }
        public bool Closing { get; set; }
    }
}
