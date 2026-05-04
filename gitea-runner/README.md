# Gitea Act Runner

Script d'installation automatisée d'un runner Gitea Actions dans un LXC Alpine sur Proxmox.

## Fonctionnalités

Un seul script, trois modes automatiques :

| Contexte | Action |
|---|---|
| Depuis l'hôte Proxmox | Crée le LXC Alpine + installe tout |
| Depuis un LXC vide | Installe Docker + act_runner + service OpenRC |
| Depuis un LXC avec act_runner | Met à jour le binaire vers la dernière version |

## Utilisation

### Installation complète (depuis le shell Proxmox)

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh)"
```

Le script crée automatiquement un LXC Alpine 3.23 avec Docker et act_runner.

### Personnalisation

Variables d'environnement pour surcharger les valeurs par défaut :

```bash
CTID=120 HOSTNAME=runner-02 CORES=4 RAM=4096 bash -c "$(curl -fsSL ...)"
```

| Variable | Défaut | Description |
|---|---|---|
| `CTID` | auto | ID du conteneur |
| `RUNNER_HOSTNAME` | `gitea-runner` | Hostname du LXC |
| `CORES` | `2` | CPU cores |
| `RAM` | `2048` | RAM en MiB |
| `DISK` | `8` | Disque en GB |
| `STORAGE` | `local-lvm` | Storage Proxmox pour le LXC |
| `BRIDGE` | `vmbr0` | Bridge réseau |

### Enregistrement du runner

Après installation, entrer dans le LXC et enregistrer le runner :

```bash
pct enter <CTID>
cd /var/lib/gitea-runner
su -s /bin/bash gitea-runner -c "act_runner register"
rc-service gitea-runner start
```

### Mise à jour

Depuis l'intérieur du LXC :

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh | bash
```

Le script détecte que act_runner est déjà installé et passe en mode update automatiquement.

## Architecture

- **OS** : Alpine 3.23 (LXC non-privilegié, nesting activé)
- **Docker** : installé via apk, service OpenRC
- **act_runner** : binaire officiel depuis gitea.com/gitea/act_runner
- **Service** : OpenRC avec logs dans `/var/log/gitea-runner.log`
- **Utilisateur** : `gitea-runner` (groupe `docker`)
