using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Password policy that applies to one account (AUD-011; Domenia 1 ConvertTo-DomeniaPasswordPolicyView and
/// Resolve-DomeniaPasswordPolicy). msDS-ResultantPSO decides. The domain policy is presumed only when the account can see
/// the fine-grained policies and none applies; otherwise the applicable policy stays unknown and the domain policy is shown
/// as a reference only. Nothing about the password itself is read, scored or called compromised. Pure.
/// </summary>
public static class AuditPolicyRules
{
    private const string ResultantSource = "msDS-ResultantPSO";

    public static AuditFact Fact(string label, string value, AuditFactState state = AuditFactState.Observed, string? source = null, string? limit = null, string? id = null) =>
        new(label, value, state, AuditText.FactStateLabel(state), source, string.IsNullOrWhiteSpace(limit) ? null : limit, id);

    public static AuditPolicy View(PasswordPolicyRead read, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(zone);
        var resultantError = read.ResultantError?.Trim().TrimEnd('.');
        var state = PolicyState.Unreadable;
        string? reason = null;
        if (!string.IsNullOrEmpty(read.ResultantPso))
        {
            if (read.Pso is not null)
            {
                state = PolicyState.Applies;
            }
            else
            {
                reason = "Une stratégie fine s’applique (" + AuditText.NameOf(read.ResultantPso) + ") mais ses paramètres ne sont pas lisibles avec ce compte.";
            }
        }
        else if (!string.IsNullOrEmpty(resultantError))
        {
            reason = "msDS-ResultantPSO non lu (" + resultantError + ") : la stratégie du domaine n’est donc pas présumée.";
        }
        else if (read.PsoVisibleCount > 0)
        {
            if (read.Domain is not null)
            {
                state = PolicyState.None;
            }
            else
            {
                reason = "Aucune stratégie fine ne s’applique, mais la stratégie du domaine n’a pas pu être lue.";
            }
        }
        else if (read.PsoVisibleCount == 0)
        {
            reason = "Aucune stratégie fine visible avec ce compte : il n’en existe peut-être aucune, ou ce compte ne peut pas les lire. La stratégie du domaine n’est donc pas présumée.";
        }
        else
        {
            reason = "Conteneur des stratégies fines illisible : la stratégie applicable reste inconnue.";
        }

        var resolved = Resolve(read, state, now, zone);
        var facts = resolved.Facts.ToBuilder();
        if (reason is not null)
        {
            facts.Insert(Math.Min(1, facts.Count), Fact("Pourquoi inconnue", reason, AuditFactState.Unknown, "msDS-ResultantPSO et conteneur des stratégies fines"));
        }
        if (state == PolicyState.Applies && read.Pso!.Precedence is int precedence)
        {
            facts.Add(Fact("Priorité de la stratégie fine", FrenchText.Integer(precedence), AuditFactState.Observed, "msDS-PasswordSettingsPrecedence",
                "La plus petite valeur gagne quand plusieurs stratégies visent le compte ; le contrôleur a déjà fait ce choix."));
        }
        if (state == PolicyState.Unreadable && read.Domain is not null)
        {
            // Shown as a reference only: never presented as the policy of this account.
            foreach (var fact in PolicyFacts(DomainBag(read.Domain), "Stratégie du domaine"))
            {
                facts.Add(Fact("Domaine (référence) · " + fact.Label, fact.Value, AuditFactState.Unknown, "Stratégie du domaine",
                    "Référence seulement : ne s’applique à ce compte que si aucune stratégie fine ne le vise."));
            }
        }
        var summary = state switch
        {
            PolicyState.Applies => "Stratégie fine applicable : " + AuditText.NameOf(read.ResultantPso!) + ".",
            PolicyState.None => "Aucune stratégie fine ne vise ce compte : la stratégie du domaine s’applique.",
            _ => "Stratégie applicable inconnue. " + reason,
        };
        return new AuditPolicy(read.Dn, state, resolved.Known, summary, facts.ToImmutable(), resolved.ExpiresAt, read.Controller, read.ReadAt);
    }

    private sealed record PolicyBag(int? MinLength, int? History, string? Complexity, AdInterval MaxAge, int? LockoutThreshold, AdInterval LockoutDuration);

    private static PolicyBag PsoBag(PsoRead pso) => new(pso.MinLength, pso.History,
        pso.Complexity is bool c ? (c ? "Oui" : "Non") : null, pso.MaxAge, pso.LockoutThreshold, pso.LockoutDuration);

    private static PolicyBag DomainBag(DomainPolicyRead domain) => new(domain.MinLength, domain.History,
        domain.PasswordProperties is int p ? ((p & 1) != 0 ? "Oui" : "Non") : null, domain.MaxAge, domain.LockoutThreshold, domain.LockoutDuration);

    private sealed record Resolved(bool Known, DateTimeOffset? ExpiresAt, ImmutableArray<AuditFact> Facts);

    private static Resolved Resolve(PasswordPolicyRead read, PolicyState state, DateTimeOffset now, TimeZoneInfo zone)
    {
        var facts = ImmutableArray.CreateBuilder<AuditFact>();
        PolicyBag? bag = null;
        var source = string.Empty;
        if (state == PolicyState.Applies && read.Pso is { } pso)
        {
            bag = PsoBag(pso);
            source = "Stratégie fine : " + pso.Name;
        }
        else if (state == PolicyState.None && read.Domain is { } domain)
        {
            bag = DomainBag(domain);
            source = "Stratégie du domaine";
        }
        var known = bag is not null;
        if (!known)
        {
            facts.Add(Fact("Stratégie applicable", "Inconnue", AuditFactState.Unknown, ResultantSource,
                "Stratégie non lisible avec ce compte : aucune valeur n’est déduite de la stratégie du domaine."));
        }
        else
        {
            facts.Add(Fact("Stratégie applicable", source, AuditFactState.Observed, ResultantSource));
            facts.AddRange(PolicyFacts(bag!, source));
        }

        // Expiration: the controller's computed value first; otherwise only when the policy is known.
        var account = AccountState.Evaluate(read.UserAccountControl, read.ComputedAccountControl, null);
        DateTimeOffset? expiry = null;
        string? text = null;
        var expiryState = AuditFactState.Observed;
        string? limit = null;
        if (account.PasswordNeverExpires)
        {
            text = "N’expire jamais (option du compte)";
        }
        else if (read.PasswordLastSet == 0)
        {
            text = "À changer à la prochaine ouverture de session";
        }
        else if (read.PasswordExpiryComputed is long computed && computed != 0)
        {
            if (computed == AdValues.Never)
            {
                text = "N’expire pas";
            }
            else if (AdValues.FromFileTime(computed) is DateTimeOffset at)
            {
                expiry = at;
                text = AuditText.LocalDateTime(at, zone);
            }
        }
        else if (known)
        {
            var lastSet = AdValues.FromFileTime(read.PasswordLastSet);
            if (bag!.MaxAge.State == AdIntervalState.Never)
            {
                text = "N’expire pas (stratégie sans limite)";
            }
            else if (bag.MaxAge is { State: AdIntervalState.Value, Span: TimeSpan maxAge } && lastSet is DateTimeOffset set)
            {
                expiry = set + maxAge;
                text = AuditText.LocalDateTime(expiry.Value, zone);
                expiryState = AuditFactState.Estimated;
                limit = "Calculé à partir de la stratégie lue ; valeur du contrôleur non disponible.";
            }
        }
        if (text is null)
        {
            text = "Inconnue";
            expiryState = AuditFactState.Unknown;
            limit = "Stratégie ou date de changement non lisible.";
        }
        else if (expiry is DateTimeOffset e && e < now)
        {
            text += " (échu)";
        }
        facts.Add(Fact("Expiration du mot de passe", text, expiryState, "Compte utilisateur", limit, "expiry"));
        if (account.SmartCardRequired)
        {
            facts.Add(Fact("Restriction", "Carte à puce exigée : le mot de passe n’est pas utilisable pour ouvrir une session interactive.", AuditFactState.Observed, "userAccountControl"));
        }
        if (account.PasswordNotRequired)
        {
            facts.Add(Fact("Restriction", "Mot de passe non requis (PASSWD_NOTREQD) : à revoir.", AuditFactState.Observed, "userAccountControl"));
        }
        if (account.Disabled)
        {
            facts.Add(Fact("Restriction", "Compte désactivé.", AuditFactState.Observed, "userAccountControl"));
        }
        return new Resolved(known, expiry, facts.ToImmutable());
    }

    private static IEnumerable<AuditFact> PolicyFacts(PolicyBag bag, string source)
    {
        if (bag.MinLength is int length)
        {
            yield return Fact("Longueur minimale", FrenchText.Count(length, "caractère", "caractères"), AuditFactState.Observed, source);
        }
        if (bag.Complexity is string complexity)
        {
            yield return Fact("Complexité exigée", complexity, AuditFactState.Observed, source);
        }
        if (bag.History is int history)
        {
            yield return Fact("Historique", FrenchText.Count(history, "mot de passe", "mots de passe"), AuditFactState.Observed, source);
        }
        // An absent or unreadable duration is not « no limit »: only an explicit 0 (or Int64.MinValue) means never.
        yield return bag.MaxAge.State switch
        {
            AdIntervalState.Value => Fact("Durée de validité", AuditText.Interval(bag.MaxAge), AuditFactState.Observed, source),
            AdIntervalState.Never => Fact("Durée de validité", "Sans limite", AuditFactState.Observed, source),
            _ => Fact("Durée de validité", "Non lue", AuditFactState.Unknown, source, "Durée absente de la lecture ou illisible : aucune absence de limite n’est déduite."),
        };
        if (bag.LockoutThreshold is int threshold)
        {
            var value = threshold == 0 ? "Aucun verrouillage" : FrenchText.Count(threshold, "échec", "échecs");
            var state = AuditFactState.Observed;
            string? limit = null;
            if (threshold != 0)
            {
                switch (bag.LockoutDuration.State)
                {
                    case AdIntervalState.Value:
                        value += ", durée " + AuditText.Interval(bag.LockoutDuration, minutes: true);
                        break;
                    case AdIntervalState.Never:
                        value += ", déverrouillage par un administrateur";
                        break;
                    default:
                        value += ", durée de verrouillage non lue";
                        state = AuditFactState.Unknown;
                        limit = "lockoutDuration absent de la lecture ou illisible.";
                        break;
                }
            }
            yield return Fact("Verrouillage", value, state, source, limit);
        }
    }
}
