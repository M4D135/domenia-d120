namespace Domenia.Core;

/// <summary>
/// Rules of a result list, ported from Domenia 1 (Domenia-Search.Model.ps1, Domenia-SearchWorkspace.Model.ps1): counter,
/// explicit continuation, « contient » offer, absence hint and readable perimeter. Pure texts and decisions.
/// </summary>
public static class SearchLists
{
    /// <summary>
    /// Says plainly whether the list is complete, limited or still loading; at the safety maximum the next step is to refine
    /// (Domenia 1 Get-DomeniaResultCounterText).
    /// </summary>
    public static string Counter(int loaded, int limit, bool complete, int maximum = SearchLimits.MaxLimit)
    {
        if (complete)
        {
            return FrenchText.Count(loaded, "résultat", "résultats") + " · liste complète";
        }
        var text = FrenchText.Count(loaded, "ligne chargée", "lignes chargées") + " · liste limitée à " + FrenchText.Integer(limit);
        return text + FrenchText.Colon + (limit >= maximum ? "affinez la recherche" : "affinez ou chargez la suite");
    }

    /// <summary>
    /// « Charger la suite » only for a finished list stopped at its limit, below the safety maximum. The next load reads the
    /// following rows only (list doubled, 20 000 at most); « Charger jusqu’à 1 000 » then 5 000 then the maximum
    /// (Domenia 1 Get-DomeniaContinuationDecision, MO-07).
    /// </summary>
    public static SearchContinuation Continuation(bool limitReached, int limit, int loaded, int maximum = SearchLimits.MaxLimit)
    {
        if (!limitReached)
        {
            return new SearchContinuation(false, limit, 0, 0, null, "Liste complète" + FrenchText.Colon + "aucune suite à charger.");
        }
        if (limit >= maximum)
        {
            return new SearchContinuation(false, limit, 0, 0, null, "Limite de sécurité de " + FrenchText.Integer(maximum) + " lignes atteinte" + FrenchText.Colon + "affinez la recherche.");
        }
        var loadedRows = Math.Min(Math.Max(0, loaded), limit);
        var next = Math.Max(limit + 1, Math.Min(maximum, limit * 2));
        var page = Math.Max(1, next - loadedRows);
        var jump = 0;
        foreach (var step in new[] { 1000, 5000, maximum })
        {
            if (step > next && step <= maximum)
            {
                jump = step;
                break;
            }
        }
        var jumpText = jump > 0 ? "Charger jusqu’à " + FrenchText.Integer(jump) : null;
        var reason = "Lit les " + FrenchText.Integer(page) + " lignes suivantes (liste portée à " + FrenchText.Integer(next) + " lignes), sans relire les lignes déjà chargées.";
        return new SearchContinuation(true, next, page, jump, jumpText, reason);
    }

    /// <summary>
    /// After few results of a plain text, offer « Chercher aussi les noms qui contiennent « … » »: a chip only, the read starts on
    /// its click with the same perimeter, type and limit (Domenia 1 Get-DomeniaContainsSearchOffer, FO-01).
    /// </summary>
    public static SearchContainsOffer? ContainsOffer(string? text, SearchListKind kind, SearchPlanKind planKind, SearchMatchMode match, int loaded, bool limitReached,
        int threshold = SearchLimits.ContainsThreshold)
    {
        var value = (text ?? "").Trim();
        if (kind != SearchListKind.Search || limitReached || match == SearchMatchMode.Contains || planKind != SearchPlanKind.Default
            || value.Length == 0 || value.Contains('*', StringComparison.Ordinal) || loaded > Math.Max(0, threshold))
        {
            return null;
        }
        if (!SearchText.ContainsFilter(value, SearchTypeFilter.All).Valid)
        {
            return null;
        }
        return new SearchContainsOffer(value, "Chercher aussi les noms qui contiennent " + FrenchText.Quote(value),
            "Relance la même recherche (même périmètre, même type, même limite) sur les noms, noms affichés, comptes et noms DNS qui contiennent ce texte, "
            + "pas seulement ceux qui commencent par lui. Plus lent" + FrenchText.Colon + "l’annuaire parcourt tous les noms du périmètre. Rien n’est lu avant le clic.");
    }

    /// <summary>Absence is scoped to the loaded list, never a claim that an object does not exist (Domenia 1 Get-DomeniaSearchAbsenceHint).</summary>
    public static string Absence(string scopeLabel, SearchTypeFilter type, bool limitReached, int limit)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(scopeLabel))
        {
            parts.Add("Portée" + FrenchText.Colon + scopeLabel + ". Un objet extérieur à cette portée n’est pas recherché.");
        }
        if (type != SearchTypeFilter.All)
        {
            parts.Add("Type retenu" + FrenchText.Colon + SearchText.TypeLabel(type) + ". Les autres types sont exclus.");
        }
        parts.Add(limitReached
            ? "Plafond de " + FrenchText.Integer(limit) + " lignes atteint" + FrenchText.Colon + "la liste est incomplète. Affinez la recherche ou poursuivez sa lecture."
            : "Lecture terminée dans cette portée et selon ces critères ; elle ne prouve pas une absence ailleurs dans l’annuaire.");
        return string.Join(' ', parts);
    }

    /// <summary>
    /// Readable perimeter of a list. Global: the whole domain (« Partout ») or an OU chosen by the chip of the bar (sub-OUs
    /// included); OU: the OU of the tree with its depth (Domenia 1 Get-DomeniaScopeLabel, Get-DomeniaSearchBarText).
    /// </summary>
    public static SearchScopeInfo Scope(bool global, string dn, string rootDn, string dnsName, bool subtree)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(rootDn);
        ArgumentNullException.ThrowIfNull(dnsName);
        var whole = IsRoot(dn, rootDn);
        var name = whole ? dnsName : SearchTexts.Leaf(dn);
        var path = whole ? dnsName : SearchTexts.Path(dn, dnsName);
        if (global)
        {
            return whole
                ? new SearchScopeInfo("global", rootDn, "Domaine entier", path, true, true, "Partout · domaine entier")
                : new SearchScopeInfo("global", dn, "Dans " + FrenchText.Quote(name) + " · sous-OU incluses", path, true, false, "Dans " + FrenchText.Quote(name));
        }
        var depth = whole || subtree ? "sous-OU incluses" : "niveau direct";
        var label = whole ? "Tout le domaine · " + depth : "Dans cette OU" + FrenchText.Colon + name + " · " + (subtree ? "Sous-OU incluses" : "Enfants directs");
        return new SearchScopeInfo("ou", whole ? rootDn : dn, label, path, whole || subtree, whole && subtree, (whole ? "Domaine " : "OU ") + name + " · " + depth);
    }

    /// <summary>True when <paramref name="dn"/> names the root (escaping and case ignored); a malformed DN never does.</summary>
    public static bool IsRoot(string dn, string rootDn)
    {
        try
        {
            return DistinguishedName.AreEqual(dn, rootDn);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
