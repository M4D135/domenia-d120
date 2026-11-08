namespace Domenia.Core;

/// <summary>Eligibility shared by the Fiche and Comptes intents; historical plan kinds remain unchanged.</summary>
public static class AccountWritePolicy
{
    public static bool IsSystem(string? sid, bool critical = false) => critical || sid?.EndsWith("-502", StringComparison.Ordinal) == true;

    public static string? ActivationRefusal(int flags, int? adminCount, bool enable, bool system = false)
    {
        if (system) { return "Objet système protégé ; aucune modification depuis Domenia."; }
        if (!enable && AdValues.HasFlag(flags, AdValues.ServerTrustAccount)) { return "Compte de contrôleur de domaine ; désactivation refusée."; }
        if (!enable && adminCount == 1) { return "Objet protégé (adminCount = 1) ; désactivation refusée."; }
        return null;
    }

    public static string? PasswordChangeRefusal(int? flags) => flags is null
        ? "userAccountControl non lu ; l’effet du changement imposé ne peut pas être qualifié."
        : AdValues.HasFlag(flags.Value, AdValues.DontExpirePassword)
            ? "Le mot de passe de ce compte n’expire jamais ; un changement imposé resterait sans effet."
            : null;

    public static string? ConfirmationRefusal(WritePlan plan, int? adminCount, string name) => adminCount == 1
        && (!plan.Confirmation.TypedNameRequired || !string.Equals(plan.Confirmation.TypedName, name, StringComparison.Ordinal))
            ? "La protection ou le nom du compte a changé ; préparez une nouvelle confirmation." : null;
}
