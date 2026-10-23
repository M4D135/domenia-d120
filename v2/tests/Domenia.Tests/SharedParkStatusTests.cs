using Domenia.Core;

namespace Domenia.Tests;

/// <summary>
/// Pure conversion of the stored park statuses (Domenia 1 park_state.status and the shared TSV). The shared survey carries
/// names and the words of the worker, never a certified AD identity: an unreadable value must stay an error, never a guess.
/// </summary>
internal static class SharedParkStatusTests
{
    [Test]
    public static void French_worker_statuses_map_to_their_real_state()
    {
        Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("CONFIRME"), "CONFIRME est une session vue");
        Check.Equal(ParkStatus.Empty, SyncPark.StoredStatus("LU"), "LU est une absence de session");
        Check.Equal(ParkStatus.Unreachable, SyncPark.StoredStatus("PING_MUET"), "PING_MUET reste injoignable");
        Check.Equal(ParkStatus.Refused, SyncPark.StoredStatus("REFUSE"), "REFUSE reste accès refusé");
        Check.Equal(ParkStatus.Refused, SyncPark.StoredStatus("AUTH_REJETEE"), "AUTH_REJETEE reste accès refusé");
    }

    [Test]
    public static void Timeouts_and_failures_never_become_a_certain_state()
    {
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("DELAI"), "DELAI n’est pas une session");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("ERREUR"), "ERREUR n’est pas une absence de session");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("INCONNU"), "une valeur inconnue reste une erreur de relevé");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("CONFIRM"), "une orthographe approchante n’est pas corrigée en succès");
    }

    [Test]
    public static void English_spellings_stay_understood_for_an_older_base()
    {
        Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("CONFIRMED"), "CONFIRMED (Domenia 1 anglais)");
        Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("SESSION"), "SESSION");
        Check.Equal(ParkStatus.Empty, SyncPark.StoredStatus("EMPTY"), "EMPTY");
        Check.Equal(ParkStatus.Unreachable, SyncPark.StoredStatus("UNREACHABLE"), "UNREACHABLE");
        Check.Equal(ParkStatus.Refused, SyncPark.StoredStatus("REFUSED"), "REFUSED");
    }

    [Test]
    public static void Case_and_surrounding_spaces_do_not_change_the_meaning()
    {
        Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("  Confirme  "), "casse et espaces ignorées");
        Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("cOnFiRmEd"), "casse mixte ignorée");
        Check.Equal(ParkStatus.Refused, SyncPark.StoredStatus("\t auth_rejetee \n"), "tabulations ignorées");
        Check.Equal(ParkStatus.Empty, SyncPark.StoredStatus(" lu "), "espaces périphériques ignorées");
    }

    [Test]
    public static void One_external_prefix_is_removed_only_at_the_start()
    {
        Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("PARTAGE_CONFIRME"), "observation d’une autre console, confirmée");
        Check.Equal(ParkStatus.Empty, SyncPark.StoredStatus("partage_lu"), "préfixe en minuscules");
        Check.Equal(ParkStatus.Unreachable, SyncPark.StoredStatus("PARTAGE_PING_MUET"), "préfixe sur un poste injoignable");
        Check.Equal(ParkStatus.Refused, SyncPark.StoredStatus("PARTAGE_AUTH_REJETEE"), "préfixe sur un refus d’authentification");
    }

    [Test]
    public static void A_repeated_or_misplaced_prefix_never_becomes_a_certain_status()
    {
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("PARTAGE_PARTAGE_CONFIRME"), "un préfixe répété n’est pas retiré deux fois");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("X_PARTAGE_CONFIRME"), "un préfixe au milieu n’est pas un préfixe");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("CONFIRME_PARTAGE"), "le préfixe n’est pas cherché n’importe où");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("PARTAGE_"), "un préfixe seul ne décrit aucun poste");
    }

    [Test]
    public static void Missing_status_is_an_error_and_never_a_default_state()
    {
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus(null), "aucun statut lu");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus(""), "statut vide");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("   "), "statut réduit à des espaces");
        Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("null"), "le mot « null » n’est pas un statut");
    }

    [Test]
    public static void Mapped_statuses_keep_their_french_label_and_tone()
    {
        Check.Equal("Session ouverte", SyncPark.StatusLabel(SyncPark.StoredStatus("CONFIRME")), "libellé français d’une session");
        Check.Equal("Aucune session", SyncPark.StatusLabel(SyncPark.StoredStatus("LU")), "libellé français d’une absence de session");
        Check.Equal("Injoignable", SyncPark.StatusLabel(SyncPark.StoredStatus("PING_MUET")), "libellé français d’un poste injoignable");
        Check.Equal("Accès refusé", SyncPark.StatusLabel(SyncPark.StoredStatus("AUTH_REJETEE")), "libellé français d’un refus");
        Check.Equal("Erreur de relevé", SyncPark.StatusLabel(SyncPark.StoredStatus("DELAI")), "libellé français d’un relevé non concluant");
        Check.Equal(Tone.Ok, SyncPark.StatusTone(SyncPark.StoredStatus("CONFIRME")), "ton d’une session confirmée");
        Check.Equal(Tone.Alert, SyncPark.StatusTone(SyncPark.StoredStatus("DELAI")), "un relevé non concluant alerte, jamais rassure");
    }

    [Test]
    public static void Conversion_is_pure_and_repeatable()
    {
        for (var pass = 0; pass < 3; pass++)
        {
            Check.Equal(ParkStatus.Session, SyncPark.StoredStatus("PARTAGE_CONFIRME"), "même résultat à chaque passage");
            Check.Equal(ParkStatus.Error, SyncPark.StoredStatus("DELAI"), "aucun état interne modifié");
        }
        Check.Equal(SyncPark.StoredStatus("CONFIRME"), SyncPark.StoredStatus("confirme"), "conversion sans effet de bord");
    }
}
