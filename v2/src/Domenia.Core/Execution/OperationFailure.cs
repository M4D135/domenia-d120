using System.ComponentModel;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

public enum OperationFailureKind
{
    Unknown, CredentialPaused, AccountLocked, AccountUnavailable, LogonFailure, AccessDenied,
    Unavailable, Uncertain, ModuleUnavailable, Timeout, Cancelled,
}

/// <summary>A bounded decision, never a copy of a native message. It authorizes no retry or account change.</summary>
public sealed record OperationFailureDecision(OperationFailureKind Kind, bool CanOfferAnotherAccount, bool MayRetryRead,
    string Help, int? NativeCode = null, int? HResult = null);

/// <summary>Shared classification for directory, native readers and the bridge. No localized-message guessing.
/// The legacy closed marker is recognized, but free text and exception Data never leave this component.</summary>
public static class OperationFailure
{
    private const int MaximumNodes = 32;
    private const int MaximumText = 8192;

    public static OperationFailureDecision Classify(Exception error, string? code = null)
    {
        ArgumentNullException.ThrowIfNull(error);
        var selected = FromCode(code);
        var pending = new Queue<Exception>(); pending.Enqueue(error);
        var seen = new HashSet<Exception>(ReferenceEqualityComparer.Instance);
        while (pending.Count > 0 && seen.Count < MaximumNodes)
        {
            var current = pending.Dequeue();
            if (!seen.Add(current)) continue;
            Choose(FromCode(current is DomeniaOperationException operation ? operation.Code : null));
            if (current is OperationCanceledException) Choose(Decision(OperationFailureKind.Cancelled));
            if (current is TimeoutException) Choose(Decision(OperationFailureKind.Timeout));
            if (current is UnauthorizedAccessException) Choose(Decision(OperationFailureKind.AccessDenied));
            Choose(FromNative(current is Win32Exception native ? native.NativeErrorCode : current.HResult));
            Choose(Marker(current.Message));
            if (current is AggregateException aggregate)
            {
                foreach (var inner in aggregate.InnerExceptions.Take(MaximumNodes - seen.Count)) pending.Enqueue(inner);
            }
            else if (current.InnerException is { } inner) pending.Enqueue(inner);
        }
        return selected;
        void Choose(OperationFailureDecision candidate)
        {
            if (Rank(candidate.Kind) > Rank(selected.Kind)) selected = candidate;
        }
    }

    public static OperationFailureDecision FromCode(string? code) => Decision(code switch
    {
        "write.targetPending" or "write.receiptsPending" or "write.uncertain" or "remote.uncertain" => OperationFailureKind.Uncertain,
        "account.paused" or "machine.accountPaused" or "accounts.credentialPaused" => OperationFailureKind.CredentialPaused,
        "account.locked" => OperationFailureKind.AccountLocked,
        "account.unavailable" or "account.disabled" or "account.expired" => OperationFailureKind.AccountUnavailable,
        "account.rejected" or "accounts.credentialRejected" or "ad.credentials" => OperationFailureKind.LogonFailure,
        "access.denied" or "ad.accessDenied" or "write.capabilityDenied" => OperationFailureKind.AccessDenied,
        "network.timeout" or "read.timeout" => OperationFailureKind.Timeout,
        "operation.cancelled" or "operation.replaced" => OperationFailureKind.Cancelled,
        "module.unavailable" or "wmi.classUnavailable" => OperationFailureKind.ModuleUnavailable,
        "network.unavailable" or "source.unavailable" => OperationFailureKind.Unavailable,
        _ => OperationFailureKind.Unknown,
    });

    public static OperationFailureDecision FromNative(int value)
    {
        var native = NativeCode(value);
        var kind = value switch
        {
            unchecked((int)0x8009030C) => OperationFailureKind.LogonFailure,
            unchecked((int)0x80041003) => OperationFailureKind.AccessDenied,
            unchecked((int)0x80041010) or unchecked((int)0x8004100E) => OperationFailureKind.ModuleUnavailable,
            unchecked((int)0x80338029) or unchecked((int)0x80041069) => OperationFailureKind.Timeout,
            _ => native switch
            {
                1909 => OperationFailureKind.AccountLocked,
                1317 or 1327 or 1328 or 1329 or 1330 or 1331 or 1385 or 1793 or 1907 => OperationFailureKind.AccountUnavailable,
                1326 => OperationFailureKind.LogonFailure,
                5 or 1314 => OperationFailureKind.AccessDenied,
                121 or 258 or 1460 => OperationFailureKind.Timeout,
                53 or 64 or 1722 or 1726 => OperationFailureKind.Unavailable,
                _ => OperationFailureKind.Unknown,
            },
        };
        return Decision(kind) with { NativeCode = native, HResult = value < 0 ? value : null };
    }

    public static bool IsAuthenticationRejected(int value) => FromNative(value).Kind is
        OperationFailureKind.AccountLocked or OperationFailureKind.AccountUnavailable or OperationFailureKind.LogonFailure;

    public static int? NativeCode(int value) => value is >= 0 and <= ushort.MaxValue ? value
        : ((uint)value & 0xffff0000) == 0x80070000 ? value & ushort.MaxValue : null;

    /// <summary>Only LDAP error 49 callers use this diagnostic; arbitrary server text cannot invent an account failure.</summary>
    public static string LdapAuthenticationKind(string? diagnostic)
    {
        return LdapAuthenticationCode(diagnostic) switch
        {
            0x525 => "unknownAccount", 0x532 => "passwordExpired", 0x533 => "disabled", 0x701 => "accountExpired",
            0x773 => "mustChange", 0x775 => "locked", 0x52f or 0x530 or 0x531 => "restricted", _ => "badCredentials",
        };
    }
    public static int? LdapAuthenticationCode(string? diagnostic)
    {
        if (string.IsNullOrEmpty(diagnostic) || diagnostic.Length > MaximumText) return null;
        var match = Regex.Match(diagnostic, @"(?:^|[,;]\s*)data\s+([0-9a-f]{1,8})(?:[,\s]|$)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(50));
        if (!match.Success || !int.TryParse(match.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var code)) return null;
        return code is 0x525 or 0x52e or 0x52f or 0x530 or 0x531 or 0x532 or 0x533 or 0x701 or 0x773 or 0x775 ? code : null;
    }

    private static OperationFailureDecision Marker(string? message)
    {
        if (string.IsNullOrEmpty(message) || message.Length > MaximumText) return Decision(OperationFailureKind.Unknown);
        var match = Regex.Match(message, @"\[DOMENIA:(CredentialPaused|AccountLocked|AccountUnavailable|LogonFailure|AccessDenied|Unavailable|Uncertain|ModuleUnavailable|Unknown);([0-9]{1,5});0x([0-9a-fA-F]{8})\]",
            RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(50));
        if (!match.Success || !Enum.TryParse<OperationFailureKind>(match.Groups[1].Value, out var kind)
            || !int.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var native) || native > ushort.MaxValue
            || !uint.TryParse(match.Groups[3].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hr)) return Decision(OperationFailureKind.Unknown);
        return Decision(kind) with { NativeCode = native, HResult = unchecked((int)hr) };
    }

    private static OperationFailureDecision Decision(OperationFailureKind kind) => new(kind,
        kind is OperationFailureKind.CredentialPaused or OperationFailureKind.AccountLocked or OperationFailureKind.AccountUnavailable
            or OperationFailureKind.LogonFailure or OperationFailureKind.AccessDenied,
        kind == OperationFailureKind.Unavailable, kind switch
        {
            OperationFailureKind.CredentialPaused => "Le compte est en pause. Vérifiez son état avant un nouvel essai explicite.",
            OperationFailureKind.AccountLocked => "Le compte est verrouillé. Aucun nouvel essai avec ce compte.",
            OperationFailureKind.AccountUnavailable => "Le compte ne peut pas ouvrir cette session. Vérifiez son état et les restrictions d’accès.",
            OperationFailureKind.LogonFailure => "Les identifiants ont été refusés. Vous pouvez choisir explicitement un autre compte.",
            OperationFailureKind.AccessDenied => "Le compte n’a pas les droits requis sur cette ressource.",
            OperationFailureKind.Unavailable => "La source ne répond pas. Une nouvelle lecture exige un geste explicite ou la politique de reprise déjà confirmée.",
            OperationFailureKind.Uncertain => "Le résultat reste à vérifier. Aucun rejeu ni changement de compte ne résout une opération incertaine.",
            OperationFailureKind.ModuleUnavailable => "La classe, l’espace de noms ou le module demandé n’est pas disponible. Un autre compte ne remplace pas cette source.",
            OperationFailureKind.Timeout => "Le délai est dépassé. Cela ne prouve pas un problème d’identifiants.",
            OperationFailureKind.Cancelled => "La demande est arrêtée. Aucun nouvel essai automatique.",
            _ => "L’erreur n’est pas classée. Consultez le diagnostic avant une nouvelle action.",
        });

    // Uncertainty survives wrapping. An explicit authentication rejection must still protect the account even
    // when wrapped in a timeout; a timeout alone never invents such evidence or suggests changing credentials.
    private static int Rank(OperationFailureKind kind) => kind switch
    {
        OperationFailureKind.Uncertain => 100, OperationFailureKind.CredentialPaused => 95, OperationFailureKind.AccountLocked => 94,
        OperationFailureKind.AccountUnavailable => 93, OperationFailureKind.LogonFailure => 92,
        OperationFailureKind.Cancelled => 90, OperationFailureKind.Timeout => 80, OperationFailureKind.AccessDenied => 30,
        OperationFailureKind.ModuleUnavailable => 20, OperationFailureKind.Unavailable => 10, _ => 0,
    };
}
