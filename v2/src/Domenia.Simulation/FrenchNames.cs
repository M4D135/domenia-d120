using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Simulation;

/// <summary>French given names (by gender), surnames and job titles used to build the fictitious directory.</summary>
public static class FrenchNames
{
    public static ImmutableArray<string> Female { get; } =
    [
        "Marie", "Nathalie", "Isabelle", "Sylvie", "Catherine", "Françoise", "Valérie", "Christine", "Sandrine", "Sophie",
        "Céline", "Véronique", "Stéphanie", "Laurence", "Patricia", "Nicole", "Anne", "Julie", "Aurélie", "Émilie",
        "Caroline", "Virginie", "Camille", "Laura", "Léa", "Manon", "Chloé", "Sarah", "Pauline", "Mathilde",
        "Élodie", "Audrey", "Hélène", "Martine", "Brigitte", "Monique", "Corinne", "Agnès", "Delphine", "Karine",
        "Florence", "Claire", "Charlotte", "Inès", "Lucie", "Juliette", "Clémence", "Margaux", "Océane", "Anaïs",
        "Morgane", "Marion", "Justine", "Elsa", "Noémie", "Amandine", "Coralie", "Mélanie", "Gaëlle", "Solène",
        "Maëlle", "Bérénice", "Josiane", "Ghislaine", "Danielle", "Jacqueline", "Odile", "Yasmine", "Fatima", "Nadia",
        "Leïla", "Aïcha", "Samia", "Linh", "Chantal", "Annick", "Joëlle", "Marine", "Laëtitia", "Héloïse",
        "Marie-Claire", "Anne-Sophie", "Marie-Hélène", "Anne-Laure", "Marie-Pierre", "Marie-Christine",
    ];

    public static ImmutableArray<string> Male { get; } =
    [
        "Jean", "Philippe", "Michel", "Alain", "Patrick", "Nicolas", "Christophe", "Pierre", "Christian", "Éric",
        "Frédéric", "Laurent", "Stéphane", "David", "Olivier", "Sébastien", "Thierry", "Julien", "Pascal", "Daniel",
        "Thomas", "Bernard", "Alexandre", "François", "Vincent", "Jérôme", "Didier", "Bruno", "Guillaume", "Gilles",
        "Antoine", "Maxime", "Romain", "Hugo", "Lucas", "Mathieu", "Benoît", "Cédric", "Yannick", "Fabrice",
        "Arnaud", "Emmanuel", "Grégory", "Sylvain", "Hervé", "Joël", "Lionel", "Raphaël", "Gaël", "Loïc",
        "Mickaël", "Jérémy", "Kévin", "Aurélien", "Florian", "Adrien", "Bastien", "Quentin", "Damien", "Théo",
        "Clément", "Valentin", "Baptiste", "Nathan", "Noël", "Régis", "Gérard", "Rémi", "Yves", "Marc",
        "Karim", "Mehdi", "Rachid", "Samir", "Mamadou", "Moussa", "Hoang", "Kenji", "Paulo", "Joaquim",
        "Jean-Pierre", "Jean-Luc", "Jean-Marc", "Jean-François", "Pierre-Yves", "Jean-Baptiste", "Paul-Henri",
    ];

    public static ImmutableArray<string> Surnames { get; } =
    [
        "Martin", "Bernard", "Thomas", "Petit", "Robert", "Richard", "Durand", "Dubois", "Moreau", "Laurent",
        "Simon", "Michel", "Lefebvre", "Leroy", "Roux", "David", "Bertrand", "Morel", "Fournier", "Girard",
        "Bonnet", "Dupont", "Lambert", "Fontaine", "Rousseau", "Vincent", "Muller", "Lefèvre", "Faure", "André",
        "Mercier", "Blanc", "Guérin", "Boyer", "Garnier", "Chevalier", "François", "Legrand", "Gauthier", "Garcia",
        "Perrin", "Robin", "Clément", "Morin", "Nicolas", "Henry", "Roussel", "Mathieu", "Gautier", "Masson",
        "Marchand", "Duval", "Denis", "Dumont", "Marie", "Lemaire", "Noël", "Meyer", "Dufour", "Meunier",
        "Brun", "Blanchard", "Giraud", "Joly", "Rivière", "Lucas", "Brunet", "Gaillard", "Barbier", "Arnaud",
        "Martinez", "Gérard", "Roche", "Renard", "Schmitt", "Roy", "Leroux", "Colin", "Vidal", "Caron",
        "Picard", "Roger", "Fabre", "Aubert", "Lemoine", "Renaud", "Dumas", "Lacroix", "Olivier", "Philippe",
        "Bourgeois", "Pierre", "Benoît", "Rey", "Leclerc", "Payet", "Rolland", "Leclercq", "Guillaume", "Lecomte",
        "Lopez", "Jean", "Dupuy", "Guillot", "Hubert", "Berger", "Carpentier", "Sanchez", "Dupuis", "Moulin",
        "Louis", "Deschamps", "Huet", "Vasseur", "Perez", "Boucher", "Fleury", "Royer", "Klein", "Jacquet",
        "Adam", "Paris", "Poirier", "Marty", "Aubry", "Guyot", "Carré", "Charles", "Renault", "Charpentier",
        "Ménard", "Maillard", "Baron", "Bertin", "Bailly", "Hervé", "Schneider", "Fernandez", "Le Gall", "Collet",
        "Léger", "Bouvier", "Julien", "Prévost", "Millet", "Perrot", "Daniel", "Le Roux", "Cousin", "Germain",
        "Breton", "Besson", "Langlois", "Rémy", "Le Goff", "Pelletier", "Lévêque", "Perrier", "Leblanc", "Barré",
        "Lebrun", "Marchal", "Weber", "Mallet", "Hamon", "Boulanger", "Jacob", "Monnier", "Michaud", "Rodriguez",
        "Guichard", "Gillet", "Étienne", "Grondin", "Poulain", "Tessier", "Chevallier", "Collin", "Chauvin", "Da Silva",
        "Bouchet", "Gay", "Lemaître", "Bénard", "Maréchal", "Humbert", "Reynaud", "Antoine", "Hoarau", "Perret",
        "Barthélemy", "Cordier", "Pichon", "Lejeune", "Gilbert", "Lamy", "Delaunay", "D'Almeida", "N'Diaye", "Lefort",
    ];

    /// <summary>Titles per service, masculine and feminine; the first person of each service gets the manager title.</summary>
    public static FrozenDictionary<string, ServiceTitles> Titles { get; } = new Dictionary<string, ServiceTitles>(StringComparer.Ordinal)
    {
        ["Direction"] = new(
            ["Directeur de site", "Assistant de direction", "Chargé de mission", "Directeur adjoint"],
            ["Directrice de site", "Assistante de direction", "Chargée de mission", "Directrice adjointe"],
            "Directeur général", "Directrice générale"),
        ["Finances"] = new(
            ["Comptable", "Contrôleur de gestion", "Trésorier", "Gestionnaire comptable"],
            ["Comptable", "Contrôleuse de gestion", "Trésorière", "Gestionnaire comptable"],
            "Responsable financier", "Responsable financière"),
        ["Ressources humaines"] = new(
            ["Chargé de recrutement", "Gestionnaire de paie", "Chargé de formation", "Assistant RH"],
            ["Chargée de recrutement", "Gestionnaire de paie", "Chargée de formation", "Assistante RH"],
            "Responsable des ressources humaines", "Responsable des ressources humaines"),
        ["Informatique"] = new(
            ["Technicien support", "Administrateur systèmes", "Ingénieur réseau", "Chef de projet informatique"],
            ["Technicienne support", "Administratrice systèmes", "Ingénieure réseau", "Cheffe de projet informatique"],
            "Responsable informatique", "Responsable informatique"),
        ["Juridique"] = new(
            ["Juriste", "Assistant juridique", "Juriste d’affaires"],
            ["Juriste", "Assistante juridique", "Juriste d’affaires"],
            "Responsable juridique", "Responsable juridique"),
        ["Communication"] = new(
            ["Chargé de communication", "Rédacteur", "Chargé des relations presse", "Graphiste"],
            ["Chargée de communication", "Rédactrice", "Chargée des relations presse", "Graphiste"],
            "Responsable de la communication", "Responsable de la communication"),
        ["Achats"] = new(
            ["Acheteur", "Assistant achats", "Approvisionneur"],
            ["Acheteuse", "Assistante achats", "Approvisionneuse"],
            "Responsable des achats", "Responsable des achats"),
        ["Commercial"] = new(
            ["Chargé de clientèle", "Commercial sédentaire", "Technico-commercial", "Conseiller clientèle"],
            ["Chargée de clientèle", "Commerciale sédentaire", "Technico-commerciale", "Conseillère clientèle"],
            "Responsable d’agence", "Responsable d’agence"),
        ["Logistique"] = new(
            ["Préparateur de commandes", "Magasinier", "Cariste", "Agent logistique"],
            ["Préparatrice de commandes", "Magasinière", "Cariste", "Agente logistique"],
            "Responsable d’entrepôt", "Responsable d’entrepôt"),
    }.ToFrozenDictionary(StringComparer.Ordinal);
}

/// <summary>Job titles of one service, agreed with the gender of the given name.</summary>
public sealed record ServiceTitles(ImmutableArray<string> Masculine, ImmutableArray<string> Feminine, string ManagerMasculine, string ManagerFeminine)
{
    public string Pick(SeededRandom random, bool female, bool manager)
    {
        ArgumentNullException.ThrowIfNull(random);
        if (manager)
        {
            return female ? ManagerFeminine : ManagerMasculine;
        }
        var list = female ? Feminine : Masculine;
        return list[random.Next(list.Length)];
    }
}
