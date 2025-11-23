#!/bin/bash

# ============================================
# Installation complète Vaultwarden + Restic
# ============================================

set -e  # Arrêter en cas d'erreur

echo "=== Installation de Docker ==="

# Mettre à jour le système
sudo apt update && sudo apt upgrade -y

# Installer les prérequis
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

# Ajouter la clé GPG Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Ajouter le dépôt Docker
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Installer Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Ajouter l'utilisateur au groupe docker
sudo usermod -aG docker $USER

echo "✓ Docker installé. Vous devrez vous reconnecter pour utiliser docker sans sudo"

echo ""
echo "=== Installation de Vaultwarden ==="

# Créer les répertoires
mkdir -p ~/vaultwarden/data
cd ~/vaultwarden

# Créer le fichier docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3'

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - DOMAIN=https://votre-domaine.com  # À MODIFIER avec votre domaine
      - SIGNUPS_ALLOWED=true              # Mettre false après création des comptes
      - INVITATIONS_ALLOWED=true
      - SHOW_PASSWORD_HINT=false
      - LOG_FILE=/data/vaultwarden.log
      - LOG_LEVEL=info
      - EXTENDED_LOGGING=true
    volumes:
      - ./data:/data
    ports:
      - "8080:80"  # Port pour Nginx Proxy Manager
EOF

echo "✓ Fichier docker-compose.yml créé"

# Démarrer Vaultwarden
echo ""
echo "Démarrage de Vaultwarden..."
docker compose up -d

echo ""
echo "✓ Vaultwarden est maintenant accessible sur http://localhost:8080"
echo ""

echo "=== Installation de Restic ==="

# Installer Restic
sudo apt install -y restic

# Créer les répertoires de sauvegarde
mkdir -p ~/backups/vaultwarden-repo
mkdir -p ~/backups/scripts

# Créer le script de sauvegarde Restic
cat > ~/backups/scripts/backup-vaultwarden.sh <<'BACKUP_SCRIPT'
#!/bin/bash

# Configuration
RESTIC_REPOSITORY="/home/$USER/backups/vaultwarden-repo"
RESTIC_PASSWORD_FILE="/home/$USER/backups/.restic-password"
VAULTWARDEN_DATA="/home/$USER/vaultwarden/data"
LOG_FILE="/home/$USER/backups/backup.log"

# Fonction de log
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Vérifier que le mot de passe existe
if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    log "ERREUR: Fichier de mot de passe Restic introuvable"
    exit 1
fi

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

log "=== Début de la sauvegarde Vaultwarden ==="

# Arrêter Vaultwarden pour une sauvegarde cohérente
log "Arrêt de Vaultwarden..."
cd /home/$USER/vaultwarden
docker compose stop vaultwarden

# Effectuer la sauvegarde
log "Sauvegarde en cours..."
restic backup "$VAULTWARDEN_DATA" \
    --tag vaultwarden \
    --tag "$(date +%Y-%m-%d)" 2>&1 | tee -a "$LOG_FILE"

BACKUP_STATUS=${PIPESTATUS[0]}

# Redémarrer Vaultwarden
log "Redémarrage de Vaultwarden..."
docker compose start vaultwarden

if [ $BACKUP_STATUS -eq 0 ]; then
    log "✓ Sauvegarde réussie"
else
    log "✗ ERREUR lors de la sauvegarde"
    exit 1
fi

# Nettoyage : garder les 7 derniers snapshots quotidiens, 4 hebdomadaires, 6 mensuels
log "Nettoyage des anciennes sauvegardes..."
restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune 2>&1 | tee -a "$LOG_FILE"

log "=== Sauvegarde terminée ==="
echo "" >> "$LOG_FILE"
BACKUP_SCRIPT

chmod +x ~/backups/scripts/backup-vaultwarden.sh

# Créer le fichier de mot de passe Restic
echo ""
echo "Création du mot de passe Restic..."
echo "Entrez un mot de passe FORT pour chiffrer vos sauvegardes (vous en aurez besoin pour restaurer) :"
read -s RESTIC_PASSWORD
echo "$RESTIC_PASSWORD" > ~/backups/.restic-password
chmod 600 ~/backups/.restic-password

# Initialiser le dépôt Restic
echo ""
echo "Initialisation du dépôt Restic..."
export RESTIC_REPOSITORY="$HOME/backups/vaultwarden-repo"
export RESTIC_PASSWORD_FILE="$HOME/backups/.restic-password"
restic init

echo ""
echo "✓ Restic configuré"

# Créer un script de restauration
cat > ~/backups/scripts/restore-vaultwarden.sh <<'RESTORE_SCRIPT'
#!/bin/bash

RESTIC_REPOSITORY="/home/$USER/backups/vaultwarden-repo"
RESTIC_PASSWORD_FILE="/home/$USER/backups/.restic-password"

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

echo "=== Snapshots disponibles ==="
restic snapshots

echo ""
echo "Entrez l'ID du snapshot à restaurer (ou 'latest' pour le dernier) :"
read SNAPSHOT_ID

echo ""
echo "Restauration vers : /home/$USER/vaultwarden/data-restored"
mkdir -p /home/$USER/vaultwarden/data-restored

restic restore "$SNAPSHOT_ID" --target /home/$USER/vaultwarden/data-restored

echo ""
echo "✓ Restauration terminée dans : /home/$USER/vaultwarden/data-restored"
echo "Pour l'utiliser, arrêtez Vaultwarden et remplacez le dossier data"
RESTORE_SCRIPT

chmod +x ~/backups/scripts/restore-vaultwarden.sh

# Configurer la sauvegarde automatique quotidienne
echo ""
echo "Configuration de la sauvegarde automatique quotidienne..."

# Ajouter au crontab (tous les jours à 2h du matin)
(crontab -l 2>/dev/null; echo "0 2 * * * $HOME/backups/scripts/backup-vaultwarden.sh") | crontab -

echo "✓ Sauvegarde automatique configurée (tous les jours à 2h)"

# Effectuer une première sauvegarde de test
echo ""
echo "Effectuer une première sauvegarde de test ? (o/n)"
read -r response
if [[ "$response" =~ ^[Oo]$ ]]; then
    ~/backups/scripts/backup-vaultwarden.sh
fi

echo ""
echo "============================================"
echo "✓ INSTALLATION TERMINÉE"
echo "============================================"
echo ""
echo "Vaultwarden : http://localhost:8080"
echo "Données : ~/vaultwarden/data"
echo ""
echo "Sauvegardes Restic :"
echo "  - Dépôt : ~/backups/vaultwarden-repo"
echo "  - Script sauvegarde : ~/backups/scripts/backup-vaultwarden.sh"
echo "  - Script restauration : ~/backups/scripts/restore-vaultwarden.sh"
echo "  - Mot de passe : ~/backups/.restic-password"
echo ""
echo "Commandes utiles :"
echo "  docker compose logs -f           # Voir les logs"
echo "  docker compose restart           # Redémarrer"
echo "  restic snapshots                 # Lister les sauvegardes"
echo "  ~/backups/scripts/backup-vaultwarden.sh  # Sauvegarde manuelle"
echo ""
echo "IMPORTANT : Sauvegardez le fichier ~/backups/.restic-password ailleurs !"
echo "            Sans ce mot de passe, impossible de restaurer vos sauvegardes."
echo ""
