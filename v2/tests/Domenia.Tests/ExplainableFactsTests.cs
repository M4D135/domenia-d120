using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class ExplainableFactsTests
{
    [Test]
    public static void Search_preview_exposes_the_limits_of_the_stored_network_and_inventory_readings()
    {
        var computer = Fixtures.Computer("PC1");
        var snapshot = Fixtures.Snapshot(computers: [computer]);
        var observation = Fixtures.Observe(computer, Fixtures.Presence(false, TimeSpan.FromMinutes(5)), Fixtures.Disk(1000, 100, TimeSpan.FromHours(1)));
        var row = new SearchRowFactory(snapshot, [observation], null, Fixtures.Now).Computer(computer);
        var preview = SearchDetails.Preview(row, computer, snapshot, observation, TimeZoneInfo.Utc, "Cache local");
        Check.Contains("ce n’est pas une preuve qu’il est éteint", preview.Sections.Single(s => s.Id == "presence").Items.Single(i => i.Label == "Limite").Value, "le silence ICMP ne devient pas une extinction");
        Check.Contains("il ne mesure pas l’état du poste à l’instant", preview.Sections.Single(s => s.Id == "inventory").Items.Single(i => i.Label == "Limite").Value, "le cache garde la limite temporelle de son relevé");
        Check.Equal(MeasureState.Known, observation.Presence.State, "la présentation n’altère pas les données conservées");
    }

    [Test]
    public static void Shared_evidence_reaches_the_real_bridge_contract_for_every_screen()
    {
        object[] facts = [
            new PosteFact("Console", "Non lu", FactState.Unknown, "CIM", null, "À vérifier", null, Tone.Off),
            new AuditFact("Politique", "Non lu", AuditFactState.Unknown, "Inconnu", null, null),
            new AccountsFact("Compte", "Non lu", Tone.Off, null, null, null),
            new FicheFact("Compte", "État", "Non lu", "unknown", "AD", null, null),
        ];
        foreach (var fact in facts)
        {
            var json = System.Text.Json.JsonSerializer.SerializeToElement(fact, fact.GetType(), Domenia.Bridge.BridgeJson.Options);
            var evidence = json.GetProperty("evidence");
            Check.Equal("unknown", evidence.GetProperty("state").GetString(), "l’état partagé atteint la page");
            Check.Equal(DomeniaFact.LimitNotRecorded, evidence.GetProperty("limit").GetString(), "une limite absente est signalée au lieu d’être cachée");
            Check.True(evidence.TryGetProperty("reader", out _) && evidence.TryGetProperty("at", out _) && evidence.TryGetProperty("hypothesis", out _), "provenance complète, sans inventer les données manquantes");
        }
    }

    [Test]
    public static void A_known_flag_without_a_dated_read_is_not_an_observed_fact()
    {
        var presence = new PresenceMeasure(MeasureState.Known, true, null, null).AsFact();
        Check.Equal(DomeniaFactState.Unknown, presence.State, "un drapeau connu ne remplace pas un relevé daté");
        Check.Contains("rien n’est conclu", presence.Limit, "la présence reste non prouvée");
        var inventory = (InventoryMeasure.Unread with { State = MeasureState.Known }).AsFact();
        Check.Equal(DomeniaFactState.Unknown, inventory.State, "l’inventaire non daté reste inconnu");
        Check.Equal("Inventaire non daté", inventory.Value, "la date manquante est signalée");
    }

    [Test]
    public static void The_five_states_of_a_fact_exist_once_for_every_module()
    {
        Check.True(typeof(FactState) == typeof(AuditFactState) && typeof(FactState) == typeof(DomeniaFactState),
            "les pages poste et audit n’ont plus chacune leur énumération des cinq états");
        Check.Equal("Constaté", DomeniaFact.LabelOf(DomeniaFactState.Observed), "Constaté");
        Check.Equal("Estimé", DomeniaFact.LabelOf(DomeniaFactState.Estimated), "Estimé");
        Check.Equal("Refusé", DomeniaFact.LabelOf(DomeniaFactState.Refused), "Refusé");
        Check.Equal("Indisponible", DomeniaFact.LabelOf(DomeniaFactState.Unavailable), "Indisponible");
        Check.Equal("Inconnu", DomeniaFact.LabelOf(DomeniaFactState.Unknown), "Inconnu");
        foreach (var state in Enum.GetValues<DomeniaFactState>())
        {
            Check.Equal(DomeniaFact.LabelOf(state), AuditText.FactStateLabel(state), "l’audit dit les mêmes mots que le format commun");
        }
    }

    [Test]
    public static void Nothing_above_a_bare_observation_is_stated_without_its_limit()
    {
        foreach (var state in Enum.GetValues<DomeniaFactState>().Where(s => s != DomeniaFactState.Observed))
        {
            Check.Throws<ArgumentException>(() => DomeniaFact.New("Compteur", "3", state, "Lecture AD", " "),
                "un fait " + state + " sans limite est refusé à sa création");
        }
        var bare = DomeniaFact.New("Compteur", "3", DomeniaFactState.Observed, "Lecture AD", "");
        Check.False(bare.CarriesItsLimit, "un constat sans limite reste un constat");
        Check.Equal(DomeniaFact.LimitNotRecorded, bare.LimitSaid, "la limite absente est dite, jamais inventée");
        Check.False(bare.LimitSaid.Contains("l’annuaire", StringComparison.Ordinal), "aucune limite n’est supposée d’après la source");
    }

    [Test]
    public static void Every_module_projects_its_fact_onto_the_one_format()
    {
        var at = Fixtures.Now;
        var poste = new PosteFact("Console", "j.martin", FactState.Estimated, "Win32_ComputerSystem", null, "Session observée, pas certifiée.", at, Tone.Info) { Reader = "EXAMPLE\\observateur" }.ToFact();
        Check.Equal("Console", poste.Label, "le fait garde son nom");
        Check.Equal("j.martin", poste.Value, "la valeur est celle de la page");
        Check.Equal(DomeniaFactState.Estimated, poste.State, "une estimation n’est jamais un constat");
        Check.Equal("Win32_ComputerSystem", poste.Source, "la source est celle de la lecture");
        Check.Equal("Session observée, pas certifiée.", poste.Hypothesis, "l’indice de la page devient l’hypothèse commune");
        Check.Equal(at, poste.At, "la date du relevé est conservée");
        Check.Equal("EXAMPLE\\observateur", poste.Reader, "le compte lecteur est conservé");
        Check.Equal(DomeniaFact.LimitNotRecorded, poste.LimitSaid, "la limite oubliée par la page est dite absente");

        var audit = new AuditFact("Politique", "90 jours", AuditFactState.Observed, "Constaté", "domain object", "Âge maximal déclaré, pas vérifié sur le poste.", "expiry")
        { Hypothesis = "Stratégie du domaine", At = at, Reader = "EXAMPLE\\lecteur" }.ToFact();
        Check.Equal("Politique", audit.Label, "l’audit garde son libellé");
        Check.Equal("Stratégie du domaine", audit.Hypothesis, "l’audit porte désormais son hypothèse");
        Check.Equal(at, audit.At, "l’audit porte désormais sa date");
        Check.Equal("EXAMPLE\\lecteur", audit.Reader, "l’audit porte désormais son compte lecteur");
        Check.True(audit.CarriesItsLimit, "la limite de l’audit est conservée");

        var accounts = new AccountsFact("Verrouillage", "3 échecs", Tone.Warn, "lockoutTime", "Compteur propre au contrôleur.", null).ToFact();
        Check.Equal(DomeniaFactState.Unknown, accounts.State, "un ton seul ne constate rien : l’état reste à dire");
        Check.Contains("Compteur propre au contrôleur", accounts.Limit, "la limite d’accès est conservée");

        var fiche = new FicheFact("Compte", "Dernier verrouillage", "05/03/2026 08:12:00", "known", "CN=PC-01", "Date du dernier verrouillage enregistré, pas son état actuel.", null, "EXAMPLE\\lecteur", "05/03/2026").ToFact();
        Check.Contains("Compte", fiche.Label, "le groupe de la fiche rejoint le nom du fait");
        Check.Contains("Dernier verrouillage", fiche.Label, "le nom du fait de la fiche est conservé");
        Check.Equal(DomeniaFactState.Observed, fiche.State, "« known » de la fiche est lu comme le constat partagé");
        Check.Equal("EXAMPLE\\lecteur", fiche.Reader, "le compte lecteur de la fiche est conservé");
        Check.Null(fiche.At, "aucune date n’est inventée à partir du texte déjà formaté de la page");
        Check.Equal(DomeniaFactState.Unknown, new FicheFact("Compte", "État calculé par le contrôleur", "Non lu", "unknown", "CN=PC-01", "Sans cet état, un lockoutTime non nul ne prouve pas un verrouillage actuel.", null).ToFact().State,
            "« unknown » de la fiche reste inconnu");
    }

    [Test]
    public static void Directory_and_reading_measures_state_their_facts_like_the_pages_do()
    {
        Check.Equal(DomeniaFactState.Observed, DomeniaFact.StateOf(MeasureState.Known), "lu : constaté");
        Check.Equal(DomeniaFactState.Observed, DomeniaFact.StateOf(MeasureState.Absent), "absence constatée par la lecture");
        Check.Equal(DomeniaFactState.Refused, DomeniaFact.StateOf(MeasureState.Refused), "refusé");
        Check.Equal(DomeniaFactState.Unknown, DomeniaFact.StateOf(MeasureState.NotRead), "jamais lu : inconnu");
        Check.Equal(DomeniaFactState.Estimated, DomeniaFact.StateOf(MeasureState.Expired), "une valeur ancienne reste une estimation");
        Check.Equal(DomeniaFactState.Estimated, DomeniaFact.StateOf(MeasureState.Incomplete), "une lecture incomplète reste une estimation");
        Check.Equal(DomeniaFactState.Unavailable, DomeniaFact.StateOf(MeasureState.Error), "une source en erreur est indisponible");

        var unread = PresenceMeasure.Unread.AsFact();
        Check.Equal(DomeniaFactState.Unknown, unread.State, "aucune lecture n’invente un état du poste");
        Check.Equal("Jamais relevé", unread.Value, "le fait dit ce qui manque");
        Check.Contains("rien n’est conclu", unread.Limit, "le fait porte la limite de ce qu’il ne prouve pas");
        Check.True(unread.CarriesItsLimit, "la limite n’est jamais facultative dans le format commun");
        Check.Null(unread.At, "aucune date inventée pour une lecture absente");

        var silent = new PresenceMeasure(MeasureState.Known, false, Fixtures.Now, null).AsFact();
        Check.Equal(DomeniaFactState.Observed, silent.State, "le silence du ping est bien constaté");
        Check.Equal("Ne répond pas au ping", silent.Value, "ce qui a été mesuré est dit");
        Check.Contains("ce n’est pas une preuve qu’il est éteint", silent.Limit, "aucun faux silence ICMP lu comme extinction");
        Check.Equal(Fixtures.Now, silent.At, "la date de la mesure est conservée");

        var failed = new PresenceMeasure(MeasureState.Error, null, Fixtures.Now, null) { Diagnostic = new(PresenceReadOutcome.IcmpError, "icmp") }.AsFact();
        Check.Equal(DomeniaFactState.Unavailable, failed.State, "une sonde en erreur n’est pas un poste muet");
        Check.Contains("aucune réponse négative", failed.Limit, "le diagnostic devient la limite du fait");

        var inventory = InventoryMeasure.Unread.AsFact();
        Check.Equal(DomeniaFactState.Unknown, inventory.State, "inventaire jamais lu : inconnu, jamais zéro");
        Check.Contains("rien n’est conclu", inventory.Limit, "l’inventaire non lu porte sa limite");
        var read = (InventoryMeasure.Unread with { State = MeasureState.Known, CheckedAt = Fixtures.Now }).AsFact(reader: "EXAMPLE\\lecteur");
        Check.Equal(DomeniaFactState.Observed, read.State, "inventaire lu : constaté");
        Check.Contains("il ne mesure pas l’état du poste à l’instant", read.Limit, "un inventaire date de sa lecture, c’est dit");
        Check.Equal("EXAMPLE\\lecteur", read.Reader, "le compte lecteur est porté jusqu’au format commun");
    }
}
