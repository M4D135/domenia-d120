# Recette de l’actualisation OU

Choisir une petite OU contenant quelques postes connus. Les actions ci-dessous lisent AD et les postes ; elles écrivent uniquement la base locale. Les trois actions incluent les sous-OU, même si la liste Recherche est filtrée.

1. **Base locale** : attendre la confirmation d’enregistrement. La date AD doit avancer ; les dates ping/WMI doivent rester celles des relevés précédents.
2. **Recalculer la vue** : vérifier que seules la date du calcul et éventuellement la présentation changent. Les dates de collecte ne doivent pas revenir à un ancien repère.
3. **Postes (ping/WMI)** : vérifier l’OU et le nombre annoncé, puis confirmer. Les observations reçues doivent avoir une nouvelle date. Un poste inaccessible conserve son ancien inventaire et sa date ; l’échec doit être visible.
4. **Les deux** : vérifier l’ordre lecture AD → enregistrement → confirmation des postes → relevé. L’annulation doit empêcher la phase suivante.
5. Dans **Recherche**, sélectionner la même OU puis masquer certains résultats par un filtre : le relevé OU doit toujours annoncer la population active locale de l’OU et de ses sous-OU, pas seulement les lignes affichées.

En cas d’anomalie, transmettre une capture du panneau, les lignes du journal autour de l’action, le nombre attendu/affiché et les trois dates. Masquer les informations confidentielles. Aucun mot de passe n’est nécessaire.
