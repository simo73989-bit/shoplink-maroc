# Finalisation ShopLink Maroc — 26 octobre 2026

Base inspectée : `166b186b806a703a65a40437816c0f395eab58d9`.
Branche : `fix/shoplink-security-otp-20261025`.
Aucune intervention sur main, Vercel, Supabase, clients, SMS ou paiements réels.

## Corrections

- **P1 confidentialité des notes** : le trigger AFTER ignorait les écritures imbriquées
  et laissait apparaître la note dans RETURNING. Reproduction sur l'ancienne migration
  dans PostgreSQL 17 : `baseline_RETURNING_leaks=true`. Le trigger BEFORE et la FK
  différée corrigent ce chemin. Les doublons d'ID sont refusés avant capture, y compris
  ON CONFLICT DO NOTHING, pour préserver la note existante. Les callers faisant des
  upserts doivent être revus sur le vrai schéma avant publication.
- **P2 dates** : l'ancien trigger réécrivait updated_at lors de la capture d'une note
  d'INSERT. Reproduit : `baseline_insert_timestamp_changed=true`. Plus de second UPDATE.
  Le backfill préserve tous les champs hors note et le mode initial du trigger de dates.
- **P1 reprise** : une tentative JSON corrompue pouvait être interprétée comme absente
  et remplacée par un nouvel UUID. Elle bloque désormais l'envoi. Les tests couvrent
  rechargement, panier/quantités modifiés, stockage indisponible et reçu non sauvegardé.
- **P2 intégrité des reçus** : résultat backend sans ID/référence utilisable refusé
  atomiquement ; aucune commande ni marqueur ne survit dans le test d'échec.
- **P2 conservation** : le dashboard ne supprime plus physiquement les commandes
  expirées à la lecture. Le filtre de visibilité est conservé.
- **P1 paiement, préparation uniquement** : registre privé avec un UUID par commande,
  contraintes transaction/événement, verrous, RPC service-only, montant fixe et états
  terminaux. Les duplications ne redéclenchent pas le déblocage. Les remboursements
  reverrouillent le contact. Les tentatives ambiguës ne sont jamais remplacées.
  L'UI bloque le double clic et ne modifie plus les URL de checkout émises par le serveur.
- **P2 backup** : TLS vérifié, noms uniques, nettoyage de tous les fichiers partiels
  invalides, vérification des deux clients PostgreSQL 17, refus d'un dossier Git,
  restauration des variables de connexion et messages sans faux succès de restauration.

**Correction de l'audit précédent :** le `END` final sans point-virgule est accepté
par PostgreSQL 17. La migration exacte de `eb2c482` a compilé dans une base temporaire.
Ce n'était pas un bug SQL confirmé ; le rapport précédent était erroné sur ce point.

## Tests réellement exécutés

- `node tests/checkout-recovery.test.cjs` : PASS. Mocks checkout, rechargement, reçu,
  stockage, ancienneté et corruption ; 6 scénarios OTP ; CSV/contact et paiement UI ;
  analyse syntaxique des 14 scripts inline. L'exception de renderCart est volontaire.
- `node tests/payment-gateway-contract-sandbox.test.cjs` : **8/8 PASS**.
  Le véritable cœur préparé est exécuté avec un faux prestataire, sans réseau.
- `tests/postgres-sandbox.test.sh` : PASS sur **PostgreSQL 17.11**, conteneur isolé,
  réseau désactivé, base neuve `shoplink_sandbox`. Les migrations 01 à 05 sont exécutées
  sur une fixture fictive. Concurrence réelle, rollback DDL 01/04/05, conflits,
  tombstones, révocations OTP/v2, RLS et rôles, sauvegarde des notes, triggers imbriqués,
  RETURNING, dates, accès vendeurs A/B, RPC de paiement, événements et états terminaux.
  **15 préparations et 15 callbacks SQL concurrents** : une tentative et un événement.
- `tests/private-order-notes.test.sql` et `tests/payment-sessions.test.sql` : exécutés
  par le harness PostgreSQL ci-dessus, avec assertions qui lèvent une exception.
- `pwsh -NoProfile -File tests/backup-helper.test.ps1` : PASS sur PowerShell 7.4.19
  Linux. Outils pg_dump/restore factices ; aucun accès réseau/backup réel. Comportement
  natif Windows et authentification Session Pooler non validés.
- `deno check` : PASS pour les deux Edge Functions préparées.
- `deno test --allow-env=CONTACT_PAYMENT_ALLOWED_ORIGIN tests/payment-edge.test.ts` :
  **3/3 PASS** sans droit réseau : endpoints désactivés, CORS et corps signé limité.
- CSS inchangé par comparaison des blocs style avec la base ; logo/assets inchangés.
  `git diff --check`, syntaxe Bash et TOML : PASS.

Le statut du workflow GitHub du commit final est rapporté dans la réponse de livraison
avec son lien. Un ancien run vert ne valide pas les modifications de cette session.

## Limites et actions du propriétaire

1. **Backup réel absent.** Résoudre l'authentification localement sans réinitialisation
   de mot de passe, créer/protéger/chiffrer le dump hors Git, puis restaurer en isolation.
   Le helper ne chiffre pas automatiquement l'archive et ne sauvegarde pas les objets
   Storage, rôles globaux ni secrets/configuration du projet.
2. **Schéma de production absent du dépôt.** Les anciennes RPC de commande, OTP, stock
   et paiement sont des fixtures dans les tests. Le stock réel, le tarif produit réel,
   les limites anti-abus, tous les triggers et les droits Supabase doivent être validés
   sur un clone isolé et assaini. Aucun connecteur Supabase n'a été utilisé ici.
3. **OTP reporté.** Les deux RPC de test sont identifiées dans les documents historiques
   et leur révocation est testée sur des fonctions fictives. Pas de nouveau contrôle
   live des ACL, ni SMS réel. JWT mémoire perdu sur refresh et réponse Auth perdue
   restent des limites ; pas de faux succès dans les simulations.
4. **PSP absent.** Aucun adaptateur officiel/signature fournisseur n'est implémenté.
   `configuredProvider()` retourne null et tout paiement/callback est refusé. Il faut
   sélectionner un prestataire acceptant 5 MAD, ses docs officielles et ses identifiants
   sandbox, puis tester ses API et la réconciliation externe. Ne pas présenter le HMAC
   fictif d'un ancien test comme une signature officielle.
5. **Intégration financière encore à faire.** Le registre préparé est distinct des
   paiements legacy. Vérifier FK `orders.payment_id`, admin/reporting, whitelist/free,
   anciens paiements en attente et suppression/archivage avant activation. Ne jamais
   exécuter deux finalizers concurrents. Une tentative terminale exige réconciliation
   avant toute nouvelle génération ; les coordonnées déjà lues ne sont pas révocables.
6. **Texte libre** : notes, téléphone et adresse ont des chemins testés ; aucun filtre
   général ne garantit qu'un client ne cache pas un numéro dans son nom/ville/article.
   La politique de champs et l'ensemble des vues/RPC/API restent à vérifier sur clone.

## Verdict

**PRÊT pour poursuivre les tests d'intégration isolés**, avec fixture validée et
limites explicites. Il faut obtenir le vrai schéma assaini pour valider la compatibilité.
**NON PRÊT pour la production**, ni pour les SMS/paiements réels.

L'ordre de publication et le rollback sont dans `supabase/changes/RELEASE_NOTES.md` :
backup/restauration, clone, confidentialité 04 indépendante, OTP validé, 01 puis frontend
puis 02/03 après traitement des vieux onglets. Le paiement 05/adaptateur reste séparé.
Ne pas supprimer les tombstones/notes privées ni réouvrir les contournements OTP.

## Fichiers modifiés ou ajoutés

- `.github/workflows/shoplink-postgres-sandbox.yml`
- `.gitignore`
- `index.html`
- `ops/FINALIZATION_REPORT_2026-10-26.md`
- `ops/backup-shoplink-local.ps1`
- `payments/5MAD_PROVIDER_INTEGRATION.md`
- `supabase/changes/01_order_idempotence_PREPARED.sql`
- `supabase/changes/04_private_order_notes_PREPARED.sql`
- `supabase/changes/05_payment_sessions_PREPARED.sql`
- `supabase/changes/PREFLIGHT_BACKUP_2026-10-26.md`
- `supabase/changes/RELEASE_NOTES.md`
- `supabase/config.toml`
- `supabase/functions/_shared/payment-core.mjs`
- `supabase/functions/_shared/payment-runtime.ts`
- `supabase/functions/_shared/provider.mjs`
- `supabase/functions/contact-payment-webhook/index.ts`
- `supabase/functions/contact-unlock/index.ts`
- `tests/backup-helper.test.ps1`
- `tests/checkout-recovery.test.cjs`
- `tests/otp-recovery.test.cjs`
- `tests/payment-edge.test.ts`
- `tests/payment-gateway-contract-sandbox.test.cjs`
- `tests/payment-sessions.test.sql`
- `tests/postgres-sandbox-fixture.sql`
- `tests/postgres-sandbox.test.sh`
- `tests/private-order-notes.test.sql`
- `tests/seller-privacy.test.cjs`
