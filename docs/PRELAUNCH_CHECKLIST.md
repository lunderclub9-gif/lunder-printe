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
