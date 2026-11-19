# LUNDER PRINTE — checklist de pré-lancement

Cette liste distingue ce qui est déjà implémenté dans le code de ce qui doit être configuré dans les tableaux de bord hébergeur / Supabase. Une compilation réussie ne remplace pas un test réel du flux d'authentification.

## Comptes clients et propriétaire

- [x] Inscription client avec nom, e-mail et mot de passe.
- [x] Confirmation d'adresse e-mail via le flux Supabase Auth.
- [x] Renvoi du message de confirmation depuis l'espace client.
- [x] Connexion et déconnexion client.
- [x] Demande de réinitialisation de mot de passe depuis l'espace client.
- [x] Formulaire de nouveau mot de passe après retour du lien de récupération.
- [x] Modification du mot de passe depuis un compte connecté.
- [x] Réinitialisation du mot de passe propriétaire depuis l'écran de connexion admin.
- [x] Autorisation admin contrôlée par le rôle `profiles.role = 'owner'`; aucune inscription publique ne peut choisir ce rôle.
- [ ] Vérifier les e-mails de confirmation et de récupération avec une vraie boîte e-mail sur le domaine de production.
- [ ] Vérifier que les liens expirés ou déjà utilisés affichent une erreur compréhensible.

## Configuration Supabase Auth obligatoire

Dans **Authentication → URL Configuration** du projet Supabase réellement utilisé par le déploiement :

1. Définir **Site URL** sur l'URL publique canonique du site, par exemple `https://votre-domaine.dz`.
2. Ajouter les URL de redirection autorisées :
   - `https://votre-domaine.dz/**`
   - `http://localhost:5173/**` (développement local uniquement)
   - Ajouter séparément le domaine de prévisualisation si des liens de prévisualisation sont utilisés.
3. Garder la confirmation d'e-mail activée pour les inscriptions si c'est la politique souhaitée.
4. Vérifier les modèles d'e-mail **Confirm signup** et **Reset password** : le bouton doit utiliser `{{ .ConfirmationURL }}` ou le modèle officiel Supabase équivalent. Ne jamais exposer un jeton dans les journaux.
5. Pour une boutique publique, configurer un fournisseur SMTP fiable dans **Authentication → SMTP Settings** avant l'ouverture. Le service d'e-mail intégré est limité et peut ne pas convenir à une boutique active.
6. Définir des limites raisonnables pour les demandes de confirmation et de récupération, et activer CAPTCHA si le trafic ou les abus le justifient.

Les fonctions du site transmettent les chemins suivants comme destinations :
- Confirmation : `/boutique/compte?mode=verified`
- Récupération : `/boutique/compte?mode=recovery`

## Vérifications de sécurité avant ouverture

- [ ] Confirmer l'identifiant du projet Supabase utilisé par les variables `VITE_SUPABASE_URL` et `VITE_SUPABASE_ANON_KEY`. Ne pas supposer que le projet de production et le projet historique sont interchangeables.
- [ ] Ne jamais placer `service_role`, une clé secrète ou un mot de passe dans une variable `VITE_*`.
- [ ] Comparer les 31 migrations versionnées avec la base de données ciblée. Ne pas fusionner, renommer, rejouer ou appliquer les migrations à l'aveugle.
- [ ] Exécuter les Security Advisor et Performance Advisor sur le projet ciblé, puis examiner chaque avertissement.
- [ ] Vérifier RLS sur toutes les tables et vues exposées, y compris les vues de commandes et d'historique client.
- [ ] Vérifier que le client A ne peut jamais lire les commandes, demandes, devis ou fichiers du client B.
- [ ] Vérifier qu'un compte client ne peut ni modifier son rôle, ni accéder aux routes ou données du propriétaire.
- [ ] Vérifier les règles Storage : lecture publique seulement pour les médias destinés au catalogue; écriture et suppression réservées au propriétaire ou à un flux validé.
- [ ] Vérifier les sauvegardes et la procédure de restauration avant toute migration de production.

## Audit de production en lecture seule — 19 novembre 2026

Projet examiné : `bavsrogbmfbalvpmbozc` (projet précédemment désigné comme production). Aucun SQL de modification ni aucune migration n'a été exécuté.

Constats à traiter avant d'activer les commandes publiques :

- L'historique Supabase retourné par l'API ne contient que les versions `20261114233127` et `20261114233352`, alors que le dépôt contient 31 fichiers de migration. Cela peut refléter une histoire historique réinitialisée ou un déploiement manuel, mais il faut rapprocher chaque version de la structure réellement présente avant de déployer.
- Security Advisor signale la vue `public.manufacturing_materials_public` comme `SECURITY DEFINER`. Sa définition actuelle ne sélectionne que le nom, les couleurs, la disponibilité et l'ordre d'affichage des matières disponibles; il faut néanmoins la convertir en vue `security_invoker` ou prouver explicitement pourquoi le comportement actuel est requis.
- Security Advisor signale 23 fonctions `SECURITY DEFINER` exécutables par `anon` et 31 exécutables par `authenticated`. La revue initiale a confirmé que plusieurs fonctions de gestion vérifient `public.is_owner()`, mais les avertissements ne doivent pas être ignorés : révoquer les appels anonymes sur les fonctions de propriétaire et de déclencheur, tout en conservant uniquement les RPC anonymes nécessaires au catalogue, au devis public, au suivi et à la commande invitée.
- `public.tracking_attempts` a RLS activé sans politique. Cela bloque l'accès direct (comportement fermé); confirmer que c'est intentionnel et que seul le code privilégié écrit les tentatives.
- Security Advisor signale des fonctions avec un `search_path` mutable, notamment `update_updated_at`, `next_order_number` et `customer_quote_breakdown`.
- Performance Advisor signale notamment des politiques RLS réévaluant `auth.uid()` ligne par ligne, des index non utilisés et des clés étrangères sans index couvrant. À prioriser après les points de sécurité, sans supprimer d'index sur la seule base d'un avertissement.

Ces avertissements proviennent de l'analyseur statique et ne prouvent pas chacun une vulnérabilité exploitable. Ne pas révoquer en bloc toutes les fonctions `SECURITY DEFINER` : certaines sont nécessaires au parcours invité et doivent être évaluées fonction par fonction. Toute correction SQL doit être préparée dans un environnement isolé, testée, puis proposée dans une migration séparée avant approbation explicite de production.

## Test manuel de bout en bout

Utiliser une adresse e-mail de test et des données non commerciales :

1. Créer un compte client et confirmer le message.
2. Se déconnecter, puis se reconnecter.
3. Demander un lien de mot de passe oublié, ouvrir le lien et enregistrer un nouveau mot de passe.
4. Se reconnecter avec le nouveau mot de passe; vérifier que l'ancien ne fonctionne plus.
5. Depuis un compte connecté, changer le mot de passe et vérifier le résultat.
6. Créer une commande de test uniquement sur une base de test isolée; vérifier son affichage côté client et côté propriétaire.
7. Mettre à jour le statut depuis l'admin et vérifier le suivi côté client.
8. Tenter d'ouvrir une route admin avec un compte client : l'accès doit être refusé.
9. Tester sur téléphone, y compris les liens reçus par e-mail et les retours vers le site.

## Statut du déploiement

Le dépôt contient une application React/Vite et un fichier de configuration de routage Vercel. La publication du frontend ne configure pas Supabase Auth, SMTP, les politiques RLS ou les migrations. Ne pas annoncer la boutique comme prête à recevoir des commandes réelles tant que les cases obligatoires ci-dessus ne sont pas validées.
