using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageSwitch
{
    private sealed record SwitchState(int Version, string DomainDn, string ActivePath, string Stage, string Transaction,
        string OriginalPlanFingerprint, string OriginalKind, string SourcePath, string DestinationPath,
        string OriginalStoreId, long OriginalRevision, string OriginalFingerprint, bool OriginalReadOnly,
        DomeniaDatabase.SwitchSource CopySource, DomeniaDatabase.SwitchSource? Copy, string? StagingPath,
        string LastPlanId, string LastPlanFingerprint, string LastKind);
    private sealed record SwitchProof(string PlanId, string PlanFingerprint, string Transaction, string Kind,
        string ActivePath, string StoreId, long Revision, string Fingerprint, DateTimeOffset At);
    private sealed record SwitchEnvelope(string Sha256, string Json);
    private static readonly JsonSerializerOptions SwitchJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, MaxDepth = 40 };

    private string SwitchDomain => string.Join(',', joinedDomain.Split('.').Select(l => "DC=" + l));
    private string SwitchFile => System.IO.Path.Combine(userFolder, "Domenia-v2", isolated ? "Storage-Isolated" : "Storage", QueryDomainKey(SwitchDomain) + ".json");
    private string SwitchProofFile(string planId) => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(SwitchFile)!, QueryDomainKey(SwitchDomain) + "." + planId + ".receipt.json");
    private static string QueryDomainKey(string dn) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(dn.ToLowerInvariant())));
    private static string SwitchHash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private static T? ReadSwitchDocument<T>(string path) where T : class
    {
        ValidateLocalPath(path);
        if (!File.Exists(path)) { return null; }
        if (new FileInfo(path).Length > 4_194_304) { throw new InvalidDataException("Marqueur de stockage hors limites."); }
        var envelope = JsonSerializer.Deserialize<SwitchEnvelope>(File.ReadAllBytes(path), SwitchJson) ?? throw new InvalidDataException("Marqueur de stockage illisible.");
        if (SwitchHash(envelope.Json) != envelope.Sha256) { throw new InvalidDataException("Marqueur de stockage altéré ; aucun changement implicite de base."); }
        return JsonSerializer.Deserialize<T>(envelope.Json, SwitchJson) ?? throw new InvalidDataException("Marqueur de stockage vide.");
    }

    private static void WriteSwitchDocument<T>(string path, T value, bool replace)
    {
        ValidateLocalPath(path); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var json = JsonSerializer.Serialize(value, SwitchJson);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new SwitchEnvelope(SwitchHash(json), json), SwitchJson);
        if (bytes.Length > 4_194_304) { throw new InvalidDataException("Marqueur de stockage hors limites."); }
        var staged = path + ".partial-" + Guid.NewGuid().ToString("N");
        using (var file = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
        { file.Write(bytes); file.Flush(flushToDisk: true); }
        File.Move(staged, path, overwrite: replace);
        if (!File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes)) { throw new IOException("Marqueur de stockage non relu après publication."); }
    }

    private SwitchState? ReadSwitchState()
    {
        var state = ReadSwitchDocument<SwitchState>(SwitchFile);
        if (state is null) { return null; }
        if (state.Version != 1 || !DistinguishedName.AreEqual(state.DomainDn, SwitchDomain) || !WritePlans.IsPlanId(state.Transaction)
            || !WritePlans.IsPlanId(state.LastPlanId) || state.OriginalPlanFingerprint.Length != 64 || state.LastPlanFingerprint.Length != 64
            || !SwitchKind(state.OriginalKind) || !SwitchKind(state.LastKind) || state.CopySource is null
            || state.OriginalFingerprint is not { Length: 64 } || state.OriginalStoreId is not { Length: 64 }
            || state.Stage is not ("prepared" or "copied" or "committed" or "returning" or "rolledBack")
            || state.ActivePath != (state.Stage == "committed" ? state.DestinationPath : state.Stage == "returning" ? state.ActivePath : state.SourcePath)
            || state.Stage == "returning" && state.ActivePath != state.SourcePath && state.ActivePath != state.DestinationPath)
        { throw new InvalidDataException("Marqueur d’un autre domaine ou état de bascule incohérent."); }
        foreach (var path in new[] { state.ActivePath, state.SourcePath, state.DestinationPath, state.CopySource.Path })
        { ValidateLocalPath(path); }
        if (state.StagingPath is not null) { ValidateLocalPath(state.StagingPath); }
        if (state.Copy is not null && (state.Copy.Path != state.DestinationPath || state.Copy.StoreId != new DomeniaDatabase(state.DestinationPath, SwitchDomain, clock).StoreId))
        { throw new InvalidDataException("Copie désignée par le marqueur incohérente."); }
        if (!File.Exists(state.ActivePath)) { throw new FileNotFoundException("Base sélectionnée absente ; aucun repli sur une base vide.", state.ActivePath); }
        return state;
    }

    private bool SwitchPending(SwitchState state) => state.Stage is "prepared" or "copied" or "returning"
        || state.Stage == "committed" && (File.Exists(StorageWriteFence.Marker(state.DestinationPath)) || !File.Exists(SwitchProofFile(state.LastPlanId)))
        || state.Stage == "rolledBack" && (File.Exists(StorageWriteFence.Marker(state.SourcePath)) || !File.Exists(SwitchProofFile(state.LastPlanId)));

    private LocalStoreSnapshot WithSwitchState(LocalStoreSnapshot snapshot)
    {
        var state = ReadSwitchState();
        if (state is null) { return snapshot; }
        var pending = SwitchPending(state);
        var matches = string.Equals(snapshot.PathLabel, state.ActivePath, StringComparison.OrdinalIgnoreCase);
        var canUndo = matches && state.Stage == "committed" && !pending && state.Copy is not null && snapshot.Revision == state.Copy.Revision;
        return snapshot with
        {
            Maintenance = snapshot.Maintenance with { Locked = pending || !matches, TargetPath = pending ? state.Stage is "returning" or "rolledBack" ? state.SourcePath : state.DestinationPath : null,
                CanUndo = canUndo, PreviousPath = state.Stage == "rolledBack" ? null : state.SourcePath, RecoveryReceipt = pending && snapshot.Maintenance.Recovery },
            Writer = snapshot.Writer with { Suspended = pending || !matches, Fault = !matches ? "Cette instance conserve l’ancien emplacement ; reconnectez le stockage avant d’écrire." : pending ? "Bascule interrompue : reprise ou retour explicite nécessaire." : snapshot.Writer.Fault },
            Backups = state.CopySource.Backup is { } backup && snapshot.Backups.All(b => b.Id != backup.Id) ? snapshot.Backups.Add(backup) : snapshot.Backups,
        };
    }

    private void PublishSwitch(SwitchState state)
    { WriteSwitchDocument(SwitchFile, state, replace: true); }

    private void RecordSwitchProof(WritePlan plan, SwitchState state, DomeniaDatabase.SwitchSource current)
    {
        var path = SwitchProofFile(plan.Id);
        var prior = ReadSwitchDocument<SwitchProof>(path);
        if (prior is not null)
        {
            if (prior.PlanFingerprint != plan.Fingerprint || prior.ActivePath != current.Path || prior.Transaction != state.Transaction)
            { throw new InvalidDataException("Identifiant de reçu déjà utilisé pour une autre bascule."); }
            return;
        }
        WriteSwitchDocument(path, new SwitchProof(plan.Id, plan.Fingerprint, state.Transaction, plan.Kind, current.Path, current.StoreId,
            current.Revision, current.Fingerprint, clock.GetUtcNow()), replace: false);
    }
}
