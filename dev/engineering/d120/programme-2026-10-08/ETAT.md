# Programme d'améliorations du 08/10/2026 — état au 11/10/2026

Décision de David (08/10) : appliquer toute la liste `PISTES-AMELIORATION-2026-10-08.md` (270 pistes), en autonomie,
en s'aidant du Spark. Plan : `plan-lots.json` (24 lots, 9 vagues) ; un brief par lot dans `lots/`.

| Lots | État |
|---|---|
| L01 Accueil annuaire, L02 journal et bandeaux, L03 arbre des OU, L04 relations, L05 paquet et installateur | fusionnés (vague 1), campagne VM verte |
| L06 tableau du poste, L07 écritures AD, L08 bandeau et lecture seule | fusionnés sans relecture (agents arrêtés par la limite) |
| L09 moteur | travail partiel de l'agent fusionné et corrigé (pool de runspaces, minuteurs) ; reste à terminer et relire |
| L10 inventaire, logiciels et lectures du poste | fait sur `lot/L10-spark` (14 commits, SP-06 absorbé par CO-24), campagne VM 1176 cas / 0 échec ; non fusionné |
| L11 à L24 | à faire (workflow « domenia-wave-lite » : développement en worktree, relecture avec le Spark, correction) |

Hors plan, livré en RC1.16.0 : base autonome (limites 200 000 objets / 20 min, passe tronquée jamais substituée,
« Mettre à jour cette OU »), historique de recherche ouvert sur geste.

Passe de langue : `langue-corrections-sures.json` (769, accents et apostrophes) déjà appliquée aux infobulles, textes
XAML et aide ; `langue-corrections-a-relire.json` (115, changements de personne du verbe) à trancher dans L23.
Tests : contrôle minimal seulement depuis RC1.14.0 (David teste à la main).
