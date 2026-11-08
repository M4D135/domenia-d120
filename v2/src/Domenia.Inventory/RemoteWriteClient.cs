using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Closed transport request. Program arguments are memory-only and never part of logs or receipts.</summary>
public sealed record RemoteWriteRequest(string Kind, DirectoryComputer Computer, Guid OperationId, int TimeoutSeconds)
{
    public RestartRequest? Restart { get; init; }
    public string? Service { get; init; }
    public string? ServiceAction { get; init; }
    [System.Text.Json.Serialization.JsonIgnore] public RunRequest? Run { get; init; }
    public WakeDecision? Wake { get; init; }
    public string? RunUserSid { get; init; }
    public override string ToString() => Kind + ":" + Computer.ObjectGuid.ToString("D") + ":" + OperationId.ToString("N");
}
public sealed record RemoteWriteSnapshot(NativeWorkstationIdentity Identity, DateTimeOffset? LastBoot,
    ServiceRow? Service, ImmutableArray<string> Sessions, bool SessionsComplete)
{ public string? ConsoleUserSid { get; init; } }
public sealed record RemoteWriteResult(WriteResult Result, string Detail, bool CleanupConfirmed = true)
{
    public OperationFailureKind? Failure { get; init; }
}
public sealed class RemoteWriteAccessException(bool authenticationRejected) : Exception("Accès distant refusé ; aucun autre compte essayé.")
{ public bool AuthenticationRejected { get; } = authenticationRejected; }

internal interface IRemoteWriteBackend : IDisposable
{
    RemoteWriteSnapshot Inspect(RemoteWriteRequest request, CancellationToken token);
    RemoteWriteResult Execute(RemoteWriteRequest request);
}

/// <summary>Never returns while a native write still owns the selected credential or physical quota. Provider timeouts
/// bound calls; a lost response is Unknown. The write circuit's soft/hard notifications do not release this owner.</summary>
public sealed class RemoteWriteClient(TimeProvider? clock = null)
{
    private readonly TimeProvider time = clock ?? TimeProvider.System;
    internal Func<RemoteProbeCredential?, PosteConfiguration, IRemoteWriteBackend>? BackendFactory { get; init; }
    public Task<RemoteWriteSnapshot> InspectAsync(RemoteWriteRequest request, RemoteProbeCredential credential, PosteConfiguration settings, CancellationToken token) =>
        RunAsync(request, credential, settings, backend => backend.Inspect(request, token), token);
    public Task<RemoteWriteResult> ExecuteAsync(RemoteWriteRequest request, RemoteProbeCredential? credential, PosteConfiguration settings) =>
        RunAsync(request, credential, settings, backend =>
        {
            if (request.Run is { Interactive: true } && !IsAccountSid(request.RunUserSid)) throw new InvalidDataException("SID du compte interactif non confirmé.");
            return backend.Execute(request);
        }, CancellationToken.None);

    private Task<T> RunAsync<T>(RemoteWriteRequest request, RemoteProbeCredential? credential, PosteConfiguration settings,
        Func<IRemoteWriteBackend, T> execute, CancellationToken token)
    {
        Validate(request); token.ThrowIfCancellationRequested();
        if (request.Kind == PosteRemoteWrites.WakeKind && credential is not null)
            throw new ArgumentException("Le réveil réseau ne transporte aucun identifiant.", nameof(credential));
        if (request.Kind != PosteRemoteWrites.WakeKind && credential is null)
            throw new ArgumentException("Identité distante absente ; aucune session implicite.", nameof(credential));
        if (request.Kind != PosteRemoteWrites.WakeKind) OperationCredentialScope.RequireRemote();
        var place = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Network);
        RemoteProbeCredential? copy = null;
        try
        {
            copy = credential is null ? null : new(credential.Account, credential.Password?.Copy(), credential.Session);
            var held = copy;
            return Task.Run(() =>
            {
                using (place) using (held) using (SecureCredentialCopies.Track(held?.Password))
                using (var backend = BackendFactory?.Invoke(held, settings) ?? new RemoteWriteNativeBackend(held, settings, time))
                    return execute(backend);
            }, CancellationToken.None);
        }
        catch { copy?.Dispose(); place.Dispose(); throw; }
    }

    public static void Validate(RemoteWriteRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!RemoteWriteAccess.IsRemoteKind(request.Kind) || request.OperationId == Guid.Empty || request.TimeoutSeconds is < 1 or > 300
            || request.Computer.ObjectGuid == Guid.Empty || string.IsNullOrWhiteSpace(request.Computer.Sid)
            || !CimQuery.IsHostName(request.Computer.DnsHostName ?? "") || request.Computer.LegacyIndexOnly || AdValues.IsDisabled(request.Computer.UserAccountControl))
            throw new InvalidDataException("Demande distante hors du contrat fermé.");
        if (request.Kind == PosteRemoteWrites.RestartKind && request.Restart is null
            || request.Kind == PosteRemoteWrites.RunKind && request.Run is null
            || request.Kind == PosteRemoteWrites.ServiceKind && (!PosteServices.IsValidName(request.Service ?? "") || request.ServiceAction is not ("start" or "stop" or "restart"))
            || request.Kind == PosteRemoteWrites.WakeKind && request.Wake is not { Allowed: true, Port: 9 })
            throw new InvalidDataException("Paramètres de l’action distante absents ou invalides.");
        if (request.Kind == PosteRemoteWrites.ServiceKind && request.ServiceAction is "stop" or "restart"
            && new[] { "WinDefend", "MpsSvc", "WinRM", "BFE" }.Contains(request.Service, StringComparer.OrdinalIgnoreCase))
            throw new InvalidDataException("Arrêt ou redémarrage d’un service de protection ou de gestion Windows refusé.");
        if (request.Kind != PosteRemoteWrites.ServiceKind && (request.Service is not null || request.ServiceAction is not null)
            || request.Kind != PosteRemoteWrites.RunKind && request.RunUserSid is not null
            || request.RunUserSid is not null && !IsAccountSid(request.RunUserSid))
            throw new InvalidDataException("Paramètres étrangers à cette action distante.");
        if (request.Computer.WhenCreated == DateTimeOffset.MinValue || WorkstationIdentity.ExpectedName(request.Computer) is null
            || (request.Computer.UserAccountControl & AdValues.ServerTrustAccount) != 0)
            throw new InvalidDataException("Identité machine non qualifiée pour une intervention.");
        if (request.Restart is { } restart && (request.Kind != PosteRemoteWrites.RestartKind
            || restart.Now && (restart.DelaySeconds != 0 || restart.Message.Length != 0)
            || !restart.Now && (restart.DelaySeconds is < 60 or > 3600 || restart.Minutes != (int)Math.Ceiling(restart.DelaySeconds / 60d)
                || restart.Message.Length is 0 or > PosteRemote.MaxMessageLength || restart.Message.Any(c => char.IsControl(c) || c == '"'))))
            throw new InvalidDataException("Paramètres de redémarrage hors contrat.");
        if (request.Run is { } run)
        {
            var normalized = PosteRemote.Run(request.Computer.Name, run.Interactive ? "interactive" : "system", run.Command, run.Arguments, run.RunUser, run.Elevated);
            if (request.Kind != PosteRemoteWrites.RunKind || !normalized.Check.Valid || normalized.Request != run
                || !Path.IsPathFullyQualified(run.Command) || run.Command.StartsWith(@"\\", StringComparison.Ordinal) || !run.Command.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                || run.Interactive && !run.RunUser!.Contains('\\'))
                throw new InvalidDataException("Programme local absolu .exe ou compte interactif qualifié requis.");
        }
        if (request.Wake is { } wake && (request.Kind != PosteRemoteWrites.WakeKind || !PosteRemote.Mac(wake.MacAddress).Valid
            || !System.Net.IPAddress.TryParse(wake.Broadcast, out var ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork))
            throw new InvalidDataException("Paramètres de réveil hors contrat.");

    }
    internal static bool IsAccountSid(string? value)
    {
        if (value is null || value.Length > 184) return false;
        try { return new System.Security.Principal.SecurityIdentifier(value).Value == value && value.StartsWith("S-1-5-21-", StringComparison.Ordinal); }
        catch (ArgumentException) { return false; }
    }
}
