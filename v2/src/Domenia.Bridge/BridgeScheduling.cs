using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Server-declared order; writes always retain Write regardless of supplied metadata.</summary>
public enum OperationPriority { Write, Explicit, Selection, Background }
public enum OperationProvider { Local, Directory, Cim, Wts, Storage, Network }

/// <summary>Only declared reads with a closed argument list may wait. No credential, plan or live object is captured by this metadata.</summary>
public sealed record OperationScheduling(OperationPriority Priority, OperationProvider Provider, ImmutableArray<string> Arguments,
    string? TargetArgument = null, string? ReplacementKey = null);

internal sealed record BridgeSessionStamp(string Identity, string Group);
internal sealed record BridgeProviderBudget(int Concurrent, int TimeoutSeconds, int Failures, int BackoffSeconds, int MaxBackoffSeconds,
    int PerGroup, int GroupFailures);
internal enum BridgeProviderOutcome { Success, Failure, Timeout, CredentialRejected, AccessDenied, Cancelled, Refused }

/// <summary>Small explicit table of eligible bridge reads. Native workers keep their own bounds; these are request budgets, not a physical-worker census.</summary>
internal static class BridgeScheduling
{
    internal const int MaxQueuedMessageLength = 16_384;
    // Five hundred explicit GUIDs occupy about 20 KiB. Only this closed GUID-only route needs the larger envelope.
    internal static int MessageLimit(OperationDefinition definition) => definition.Name == "search.revalidate" ? 32_768 : MaxQueuedMessageLength;

    internal static OperationDefinition Declare(OperationDefinition definition)
    {
        if (definition.Scheduling is not null || definition.Class is not (OperationClass.LocalRead or OperationClass.NetworkRead)) { return definition; }
        var declared = definition.Name switch
        {
            "directory.ou.children" or "directory.branch.children" => Read(OperationProvider.Directory, "dn"),
            "directory.ou.search" => Read(OperationProvider.Directory, "text"),
            "search.run" => Read(OperationProvider.Directory, "text", "scope", "type", "limit", "match"),
            "search.browse" => Read(OperationProvider.Directory, "dn", "subtree", "type", "limit"),
            "search.containers" => Read(OperationProvider.Directory, "counts"),
            "schema.read" => Read(OperationProvider.Directory),
            "audit.overview" => Read(OperationProvider.Directory),
            "audit.dc.compare" => Read(OperationProvider.Directory, "dn", "controllers"),
            "audit.dc.services" => Read(OperationProvider.Cim, "controllers"),
            "audit.object.policy" or "audit.object.groups" or "audit.object.acl" or "audit.object.gpoLinks" => Read(OperationProvider.Directory, "dn"),
            "audit.object.membership" => Read(OperationProvider.Directory, "dn", "groupDn"),
            "audit.object.gpoApplied" or "audit.object.machineIdentity" => Read(OperationProvider.Cim, "dn"),
            "audit.object.history" => Read(OperationProvider.Storage, "dn", "limit"),
            "audit.identities.scan" => Read(OperationProvider.Directory, "dn", "subtree"),
            "fiche.read" => Read(OperationProvider.Directory, "dn", "reread"),
            "poste.sessions" => Read(OperationProvider.Wts, "dn"),
            "fiche.lockouts" => Read(OperationProvider.Directory, "dn", "hours"),
            "fiche.logonByDc" or "poste.logonByDc" => Read(OperationProvider.Directory, "dn"),
            "relations.targets.search" => Read(OperationProvider.Directory, "dn", "text"),
            "search.view" => Read(OperationProvider.Directory, "id", "dn", "subtree", "wholeDomain", "limit"),
            "search.preload" => new(OperationPriority.Selection, OperationProvider.Directory, ["id"], ReplacementKey: "object"),
            "search.revalidate" => new(OperationPriority.Background, OperationProvider.Directory, ["ids"]),
            "search.measures" => new(OperationPriority.Background, OperationProvider.Storage, ["listId", "offset"]),
            "search.suggest" => Read(OperationProvider.Storage, "text", "type"),
            "search.dns.reverse" => new(OperationPriority.Explicit, OperationProvider.Network, ["ip"], "ip"),
            "requetes.wmi.namespaces" => new(OperationPriority.Explicit, OperationProvider.Cim, ["computer", "namespace"], "computer"),
            "requetes.wmi.classes" => new(OperationPriority.Explicit, OperationProvider.Cim, ["computer", "namespace", "filter"], "computer"),
            "requetes.wmi.schema" => new(OperationPriority.Explicit, OperationProvider.Cim, ["computer", "namespace", "className"], "computer"),
            "dashboard.summary" => new(OperationPriority.Background, OperationProvider.Storage, []),
            _ => null,
        };
        return definition with { Scheduling = declared, ShareRead = SharedName(definition.Name) };
    }

    private static OperationScheduling Read(OperationProvider provider, params string[] arguments)
        => new(OperationPriority.Explicit, provider, [.. arguments]);

    internal static void Validate(OperationDefinition definition)
    {
        if (definition.ShareRead && (!Eligible(definition) || !SharedName(definition.Name) || definition.Scheduling!.ReplacementKey is not null))
        { throw new ArgumentException("Seules les lectures fermées explicitement retenues peuvent être partagées.", nameof(definition)); }
        if (definition.ShareRead && BridgeReadIdentity.Required(definition.Name) && definition.CaptureReadIdentity is null)
        { throw new ArgumentException("La qualification locale de l’identité cible est obligatoire pour cette lecture partagée.", nameof(definition)); }
        if (definition.Scheduling is not { } schedule) { return; }
        if (!Enum.IsDefined(schedule.Priority) || !Enum.IsDefined(schedule.Provider) || schedule.Arguments.IsDefault || schedule.Arguments.Length > 32
            || schedule.Arguments.Any(a => string.IsNullOrEmpty(a) || a.Length > 64 || a.Any(char.IsControl) || Sensitive(a))
            || schedule.Arguments.Distinct(StringComparer.Ordinal).Count() != schedule.Arguments.Length
            || schedule.TargetArgument is { } target && !schedule.Arguments.Contains(target, StringComparer.Ordinal)
            || schedule.ReplacementKey is { } replacement && (replacement.Length is 0 or > 64 || replacement.Any(char.IsControl)))
        { throw new ArgumentException("Métadonnées d’ordonnancement non bornées ou sensibles.", nameof(definition)); }
    }

    internal static bool Eligible(OperationDefinition definition) => definition.Scheduling is not null
        && definition.Class is OperationClass.LocalRead or OperationClass.NetworkRead
        && !definition.Name.Split('.').Any(p => p is "plan" or "commit" or "execute" || Sensitive(p));

    private static bool SharedName(string name) => name is "directory.branch.children" or "directory.ou.children" or "directory.ou.search" or "search.containers" or "schema.read"
        or "audit.overview" or "audit.dc.compare" or "audit.dc.services" or "audit.object.policy" or "audit.object.groups"
        or "audit.object.membership" or "audit.object.acl" or "audit.object.gpoLinks" or "audit.object.gpoApplied"
        or "audit.object.machineIdentity" or "audit.object.history" or "audit.identities.scan" or "fiche.read" or "poste.sessions"
        or "fiche.lockouts" or "fiche.logonByDc" or "poste.logonByDc" or "search.revalidate" or "relations.targets.search";

    internal static string? SharedKey(OperationDefinition definition, JsonElement arguments)
    {
        if (!definition.ShareRead) { return null; }
        // The request envelope is already bounded (16 KiB, or 32 KiB for 500 GUIDs) and Target validated every primitive. Property ordering alone
        // is normalized; absent/default arguments may remain distinct, which cannot share an incompatible request.
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            if (arguments.ValueKind == JsonValueKind.Object)
            {
                foreach (var property in arguments.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                { writer.WritePropertyName(property.Name); property.Value.WriteTo(writer); }
            }
            writer.WriteEndObject();
        }
        // Null/absent and {} are deliberately distinct: a handler may allow an empty object but reject null. Sharing must
        // never allow malformed arguments to inherit the result of a valid request and bypass the handler's own schema.
        var requirements = JsonSerializer.Serialize(new { definition.Name, definition.Class, definition.ServedInSimulation, definition.Scheduling, ArgumentKind = arguments.ValueKind });
        return Digest(requirements + ":" + Convert.ToHexStringLower(SHA256.HashData(stream.GetBuffer().AsSpan(0, checked((int)stream.Length)))));
    }

    private static bool Sensitive(string value) => value.Contains("password", StringComparison.OrdinalIgnoreCase)
        || value.Contains("credential", StringComparison.OrdinalIgnoreCase) || value.Contains("secret", StringComparison.OrdinalIgnoreCase)
        || value.Contains("token", StringComparison.OrdinalIgnoreCase) || value.Contains("planId", StringComparison.OrdinalIgnoreCase);

    internal static string Target(OperationScheduling scheduling, JsonElement arguments)
    {
        if (arguments.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) { return ""; }
        var values = BridgeArguments.ReadObject(arguments, scheduling.Arguments.ToArray());
        // Keep only bounded primitive JSON, never an opaque object/credential bag; the handler still validates its complete schema at start.
        foreach (var value in values.Values) { ValidateValue(value, 0); }
        if (scheduling.TargetArgument is null || !values.TryGetValue(scheduling.TargetArgument, out var target)) { return ""; }
        if (target.ValueKind != JsonValueKind.String || target.GetString() is not { Length: > 0 and <= 256 } text)
        { throw BridgeArguments.Invalid("La cible de lecture doit être une chaîne bornée."); }
        return Digest(text.ToLowerInvariant());
    }

    private static void ValidateValue(JsonElement value, int depth)
    {
        if (value.ValueKind == JsonValueKind.Array && depth == 0 && value.GetArrayLength() <= 512)
        { foreach (var element in value.EnumerateArray()) { ValidateValue(element, 1); } return; }
        if (value.ValueKind is JsonValueKind.Object or JsonValueKind.Undefined or JsonValueKind.Array
            || value.ValueKind == JsonValueKind.String && value.GetString()!.Length > 4096)
        { throw BridgeArguments.Invalid("Une lecture en attente ne conserve que des arguments simples et bornés."); }
    }

    internal static async Task<BridgeSessionStamp> Capture(EngineContext context, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        // The effective working OU (session.setScope), not only the provider's default scope: a local OU choice does not move the source epoch.
        var working = await WorkingScope.From(context).CurrentAsync(session, token).ConfigureAwait(false);
        var scope = working ?? session.Scope;
        string[] parts = [context.Directory.Kind.ToString(), RuntimeHelpers.GetHashCode(context.Directory).ToString(CultureInfo.InvariantCulture),
            session.Epoch.ToString(CultureInfo.InvariantCulture), session.Connection.ToString(), session.Domain?.RootDn ?? "", session.Account.Login,
            session.Authentication.Method.ToString(), session.Controller?.DnsName ?? "", scope?.Dn ?? "", scope?.Subtree.ToString() ?? "",
            MachineAccountService.From(context).Generation.ToString(CultureInfo.InvariantCulture),
            AccountAccess.From(context).SelectionVersion.ToString(CultureInfo.InvariantCulture)];
        if (parts.Any(p => p.Length > 4096) || (session.Controller?.Site?.Length ?? 0) > 4096)
        { throw new BridgeOperationException("operation.contextInvalid", "Contexte de lecture non borné ; aucune mise en attente."); }
        return new(Digest(JsonSerializer.Serialize(parts)), Digest(session.Controller?.Site ?? session.Controller?.DnsName ?? "local"));
    }

    private static string Digest(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    internal static BridgeProviderBudget Budget(OperationProvider provider) => provider switch
    {
        OperationProvider.Directory => new(4, 30, 3, 20, 300, 4, 3),
        OperationProvider.Cim => new(3, 25, 2, 60, 600, 2, 3),
        OperationProvider.Wts => new(2, 20, 2, 60, 600, 1, 3),
        OperationProvider.Storage => new(1, 30, 3, 15, 120, 1, 0),
        OperationProvider.Network => new(4, 10, 3, 30, 300, 3, 3),
        _ => new(2, 30, 3, 10, 60, 2, 0),
    };

    internal static BridgeProviderOutcome Outcome(Exception? exception)
    {
        if (exception is null) return BridgeProviderOutcome.Success;
        return OperationFailure.Classify(exception, (exception as BridgeOperationException)?.Code).Kind switch
        {
            OperationFailureKind.Cancelled => BridgeProviderOutcome.Cancelled,
            OperationFailureKind.Timeout => BridgeProviderOutcome.Timeout,
            OperationFailureKind.CredentialPaused or OperationFailureKind.AccountLocked or OperationFailureKind.AccountUnavailable
                or OperationFailureKind.LogonFailure => BridgeProviderOutcome.CredentialRejected,
            OperationFailureKind.AccessDenied => BridgeProviderOutcome.AccessDenied,
            OperationFailureKind.Uncertain or OperationFailureKind.ModuleUnavailable => BridgeProviderOutcome.Refused,
            OperationFailureKind.Unavailable => BridgeProviderOutcome.Failure,
            _ => exception is BridgeOperationException or DomeniaOperationException ? BridgeProviderOutcome.Refused : BridgeProviderOutcome.Failure,
        };
    }
}
