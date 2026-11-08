> Archive R1.6. Pour la version courante, consulter INTERFACE-GUIDEE-R1.7.md.

# ADCC 1.0 R1.6 — Apple-like UX / simplicité

Cette révision met l'accent sur l'ergonomie.

## Objectifs
- interface plus douce, plus lisible et plus cohérente ;
- mode **Essentiel** vraiment orienté usage quotidien ;
- aide contextuelle visible en permanence ;
- **tooltips** sur l'ensemble des éléments, y compris ceux qui n'en avaient pas encore ;
- meilleure compréhension des actions sans lire la documentation.

## Principales améliorations

### 1) Simplification visuelle
- palette plus claire, plus douce, inspirée des interfaces Apple ;
- angles plus arrondis ;
- libellés plus simples ;
- navigation principale renommée pour être plus compréhensible :
  - `Accueil` → `Vue d ensemble`
  - `Objet` → `Fiche`
  - `Poste` → `Assistance poste`
  - `Outils` → `Outils avances`
  - bouton `Comptes` → `Identites`

### 2) Profils d'interface clarifiés
- `Mode simple` devient **Essentiel** ;
- `Mode avance` devient **Expert** ;
- en mode **Essentiel**, les vues les plus techniques sont masquées :
  - attributs bruts,
  - permissions,
  - WMI,
  - auto-verification,
  - cmdlets,
  - journal avance.

### 3) Aide contextuelle permanente
Un nouveau bloc **Aide contextuelle** apparait dans l'entete.
- au survol d'un controle, l'entete explique instantanement :
  - ce qu'est l'element ;
  - a quoi il sert ;
  - ce qu'il va faire.
- le meme principe fonctionne au clavier lors de la prise de focus.

### 4) Tooltips systematiques
- tous les elements recuperent un tooltip quand il manque ;
- certains controles critiques ont un texte personnalise ;
- le delai d'affichage est raccourci pour rendre l'aide plus naturelle.

## Notes techniques
- implementation dans `wad/ADCC-Core.ps1` ;
- aucune dependance externe ajoutee ;
- la logique fonctionnelle AD n'est pas remaniee ;
- la nouveaute porte surtout sur la presentation et la comprehension des ecrans.
