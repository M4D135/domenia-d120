using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    internal WorkstationUserReading ReadWinRmUserIdentity()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        WorkstationUserReading Empty(SourceStatus status, string detail) => new(null, new("WinRm", status, detail, 0, 0, InventoryTransport.WinRm), []);
        if (!ReadsEnabled || Transport != InventoryTransport.WinRm)
        { return Empty(SourceStatus.Skipped, "Lecture d’identité WinRM désactivée ; aucun shell ouvert."); }
        if (authenticationRefused)
        { return Empty(SourceStatus.Refused, "Identifiants déjà refusés ; aucun nouvel essai.") with { Access = new("WinRm", SourceStatus.Refused,
            "Identifiants déjà refusés ; aucun nouvel essai.", 0, 0, InventoryTransport.WinRm) { AuthenticationRejected = true } }; }
        if (OutOfBudget || cancellationToken.IsCancellationRequested || Remaining <= TimeSpan.FromMilliseconds(200))
        { return Empty(SourceStatus.Interrupted, "Budget atteint avant le shell d’identité."); }
        var began = clock.GetTimestamp();
        var allowed = Remaining;
        var reply = InventoryShellOverride?.Invoke(InventoryShellRead.UserIdentity, allowed) ?? WinRm.ReadInventory(InventoryShellRead.UserIdentity, allowed);
        authenticationRefused |= reply.AuthenticationRejected;
        var cleanup = reply.CleanupComplete ? "" : " Fermeture du shell non confirmée ; aucune nouvelle création.";
        var duration = (int)clock.GetElapsedTime(began).TotalMilliseconds;
        if (reply.Status != SourceStatus.Ok || reply.Json is null)
        { return new(null, new("WinRm", reply.Status, "Identité WinRM non lue." + cleanup, duration, 0, InventoryTransport.WinRm) { AuthenticationRejected = reply.AuthenticationRejected }, []); }
        try
        {
            var read = ParseUserIdentity(reply.Json, Host, clock.GetUtcNow());
            authenticationRefused |= read.Access.AuthenticationRejected;
            return read with { Access = read.Access with { DurationMs = duration, Detail = read.Access.Detail + cleanup,
                Status = !reply.CleanupComplete && read.Access.Status is SourceStatus.Ok or SourceStatus.Empty ? SourceStatus.Partial : read.Access.Status } };
        }
        catch (JsonException) { return Empty(SourceStatus.Error, "Réponse d’identité WinRM hors contrat, ambiguë ou d’un autre poste." + cleanup); }
    }

    internal static WorkstationUserReading ParseUserIdentity(string json, string host, DateTimeOffset readAt)
    {
        if (Encoding.UTF8.GetByteCount(json) > 65_536) { throw new JsonException(); }
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 6 });
        var root = document.RootElement;
        static void Unique(JsonElement value)
        {
            if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != value.EnumerateObject().Count())
            { throw new JsonException(); }
        }
        static string? Field(JsonElement value, string name, int max)
        {
            if (!value.TryGetProperty(name, out var field) || field.ValueKind == JsonValueKind.Null) { return null; }
            if (field.ValueKind != JsonValueKind.String || field.GetString() is not { } text || text.Length > max || text.Any(char.IsControl)) { throw new JsonException(); }
            return text;
        }
        Unique(root);
        if (Field(root, "Format", 64) != "Domenia.UserIdentityRead/1" || !string.Equals(Field(root, "Computer", 255), host.Split('.')[0], StringComparison.OrdinalIgnoreCase)
            || !root.TryGetProperty("Code", out var codeValue) || codeValue.ValueKind != JsonValueKind.Number || !codeValue.TryGetInt32(out var code)
            || !root.TryGetProperty("Truncated", out var truncated) || truncated.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || !root.TryGetProperty("Rows", out var rows) || rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 17)
        { throw new JsonException(); }
        var candidates = ImmutableArray.CreateBuilder<WorkstationUserCandidate>();
        var processIds = new HashSet<uint>(); var console = false;
        foreach (var row in rows.EnumerateArray())
        {
            Unique(row);
            var account = Field(row, "Account", 320); var sid = Field(row, "Sid", 184); var kind = Field(row, "Kind", 16);
            if (account is not { Length: > 0 } || !CredentialRules.IsWellFormed(account)) { throw new JsonException(); }
            if (kind == "Console")
            {
                if (console || sid is not null) { throw new JsonException(); }
                console = true;
                candidates.Insert(0, new(account, null, readAt, "WinRM · Win32_ComputerSystem.UserName") { CurrentConsole = true });
            }
            else if (kind == "Explorer")
            {
                if (sid is null || !AccountsRules.IsDomainSid(sid) || !row.TryGetProperty("ProcessId", out var pid) || pid.ValueKind != JsonValueKind.Number || !pid.TryGetUInt32(out var id)
                    || id == 0 || !processIds.Add(id) || UtcDate(Field(row, "CreatedUtc", 40)) is not { } created || created > readAt || created == DateTimeOffset.MinValue)
                { throw new JsonException(); }
                candidates.Add(new(account, sid, null, "WinRM · propriétaire explorer.exe (SID lu, date de connexion inconnue)"));
            }
            else { throw new JsonException(); }
        }
        var rejected = WindowsAuthenticationErrors.IsRejected(code);
        var status = code == 0 ? truncated.GetBoolean() ? SourceStatus.Partial : candidates.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok
            : rejected ? SourceStatus.Refused : candidates.Count > 0 ? SourceStatus.Partial : Classify(new COMException("Identité non lue.", code)) ?? SourceStatus.Error;
        return new(host.Split('.')[0], new("WinRm", status, "Console et propriétaires des bureaux Explorer ; aucune commande, ligne d’arguments ou session RDP déduite.",
            0, candidates.Count, InventoryTransport.WinRm) { AuthenticationRejected = rejected }, candidates.ToImmutable());
    }
}
