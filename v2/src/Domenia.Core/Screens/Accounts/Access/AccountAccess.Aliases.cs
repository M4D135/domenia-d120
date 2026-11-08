namespace Domenia.Core;

public sealed partial class AccountAccess
{
    private readonly HashSet<string> ambiguousAliases = new(StringComparer.Ordinal);
    /// <summary>Only exact, authenticated AD identities reach this cache. It performs no lookup and never overwrites a conflict.</summary>
    private bool RegisterAliasesLocked(SessionSnapshot session, string sid, IEnumerable<string> logins, string? target)
    {
        if (!AccountsRules.IsDomainSid(sid)) return false;
        var keys = logins.Where(CredentialRules.IsWellFormed).Select(login => Key(session, login, target)).Distinct(StringComparer.Ordinal).Take(17).ToArray();
        if (keys.Length is 0 or > 16 || ambiguousAliases.Count >= 1024) return false;
        var conflict = false;
        foreach (var key in keys)
        {
            if (ambiguousAliases.Contains(key) || sids.TryGetValue(key, out var prior) && prior != sid)
            { sids.Remove(key); ambiguousAliases.Add(key); conflict = true; }
        }
        if (conflict) return false;
        if (!sids.ContainsValue(sid) && sids.Values.Distinct(StringComparer.Ordinal).Count() >= 64) return false;
        if (sids.Count(pair => pair.Value == sid) + keys.Count(key => !sids.ContainsKey(key)) > 16) return false;
        foreach (var key in keys) sids.TryAdd(key, sid);
        return true;
    }
    /// <summary>Native bind serialization key, never shown as an authorization verdict.</summary>
    public string AuthenticationIdentity(string accountKey)
    {
        lock (gate)
        {
            if (ambiguousAliases.Contains(accountKey)) throw new DomeniaOperationException(ContextRefused, "Identifiant ambigu dans cette session ; aucune authentification envoyée.");
            return sids.TryGetValue(accountKey, out var sid) ? "sid:" + sid : accountKey;
        }
    }
}
