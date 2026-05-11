# Agent Prompt — gitea-runner install.sh update

## Objectif

Modifier `gitea-runner/install.sh` pour ajouter :
1. Les tags LXC `infra-script` et `cicd` à la création du conteneur
2. La configuration automatique des métriques Prometheus de `act_runner`
3. La rotation des logs via `logrotate`

## Fichier à modifier

`gitea-runner/install.sh` sur la branche `feat/gitea-runner-metrics-logrotate`

Lis d'abord le fichier actuel avant toute modification.

---

## Changements attendus

### 1. Tags LXC (dans `create_lxc()`)

Dans la commande `pct create`, ajouter l'argument `--tags` :

```bash
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --tags "infra-script,cicd" \   # ← AJOUTER CETTE LIGNE
  --start 0
```

---

### 2. Métriques Prometheus (dans `install_runner()`)

Après le bloc de création de l'utilisateur `gitea-runner` et du répertoire `/var/lib/gitea-runner`, ajouter la génération et configuration du fichier `config.yaml` :

```bash
log_info "Generating act_runner config with Prometheus metrics enabled..."
act_runner generate-config > /var/lib/gitea-runner/config.yaml
# Enable Prometheus metrics on port 9101
sed -i '/^metrics:/,/enabled:/{s/enabled: false/enabled: true/}' /var/lib/gitea-runner/config.yaml
chown gitea-runner:docker /var/lib/gitea-runner/config.yaml
chmod 640 /var/lib/gitea-runner/config.yaml
```

Dans le service OpenRC généré, modifier `command_args` pour passer le fichier de config :

```bash
# AVANT :
command_args="daemon"

# APRÈS :
command_args="daemon --config /var/lib/gitea-runner/config.yaml"
```

---

### 3. Logrotate (dans `install_runner()`)

Après la création du service OpenRC, ajouter l'installation et la configuration de logrotate :

```bash
log_info "Configuring logrotate for gitea-runner..."
apk add --no-cache logrotate > /dev/null

cat > /etc/logrotate.d/gitea-runner << 'LOGROTATE'
/var/log/gitea-runner.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

# S'assurer que logrotate est bien exécuté daily via le cron Alpine
ln -sf /usr/sbin/logrotate /etc/periodic/daily/logrotate 2>/dev/null || true
```

---

## Contraintes

- Ne pas modifier la logique de détection de contexte (`main()`)
- Ne pas modifier `update_runner()`
- Conserver tous les `log_info` existants et leur style
- Le script doit rester compatible avec une réinstallation propre
- Utiliser le même style de code que le fichier existant (bash, `set -euo pipefail`, heredoc `<<'EOF'`)

## Livrable

Un seul commit sur `feat/gitea-runner-metrics-logrotate` modifiant `gitea-runner/install.sh`, puis ouvrir une PR vers `main` avec le titre :

`feat(gitea-runner): add prometheus metrics, logrotate and LXC tags`
