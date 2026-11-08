using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FileReceiptStore
{
    /// <summary>Closed exception for the exact, validated annex or switch proof carried by a storage plan, LF included.</summary>
    public const int MaxStorageLineBytes = BackupPreferencesRules.MaxEnvelopeBytes;

    private static bool IsStorageKind(string? kind) => kind is StorageWritePlans.Backup or StorageWritePlans.BackupCopy
        or StorageWritePlans.Move or StorageWritePlans.Restore or StorageWritePlans.Resume or StorageWritePlans.Rollback;

    private static bool HasBoundedStoragePayload(WriteReceipt receipt)
    {
        var plan = receipt.Plan;
        if (!IsStorageKind(plan.Kind) || plan.Target.Kind != StorageWritePlans.TargetKind) return false;
        var backup = plan.Kind is StorageWritePlans.Backup or StorageWritePlans.BackupCopy;
        var attribute = backup ? "backup.preferences" : "switch.proof";
        var payloads = plan.Changes.Where(c => c.Attribute == attribute).ToArray();
        if (payloads.Length != 1 || payloads[0].AfterValue is not { } payload) return false;
        try
        {
            if (backup) _ = BackupPreferencesRules.ReadStrict(payload);
            else CompatibleDirectoryCache.ValidateStoredSwitchProof(plan);
            // The larger limit must not admit oversized labels, details, other values or unrelated fields.
            var withoutPayload = receipt with { Plan = plan with { Changes = [.. plan.Changes.Select(c => c.Attribute == attribute ? c with { AfterValue = "" } : c)] } };
            _ = SerializeBounded(withoutPayload, MaxLineBytes);
            return true;
        }
        catch (Exception ex) when (ex is JsonException or IOException or InvalidDataException or ArgumentException or InvalidOperationException) { return false; }
    }

    /// <summary>Stop output growth before allocating an unbounded serialized record.</summary>
    private sealed class ReceiptBuffer(int maximum) : MemoryStream
    {
        private void Require(int count)
        {
            if (Position > maximum - (long)count) throw new IOException("Reçu trop volumineux ; aucune preuve tronquée ni écriture envoyée.");
        }
        public override void Write(byte[] buffer, int offset, int count) { Require(count); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer) { Require(buffer.Length); base.Write(buffer); }
        public override void WriteByte(byte value) { Require(1); base.WriteByte(value); }
    }
}
