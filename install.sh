#!/bin/bash
# Installation complète Vaultwarden avec sécurité maximale
# Ubuntu Server 22.04/24.04

echo "=== ÉTAPE 1 : Mise à jour du système ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git ufw fail2ban unattended-upgrades

echo "=== ÉTAPE 2 : Configuration mises à jour automatiques ==="
sudo dpkg-reconfigure -plow unattended-upgrades
# Activer les mises à jour auto de sécurité
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

echo "=== ÉTAPE 3 : Installation Docker ==="
# Désinstaller anciennes versions
sudo apt remove -y docker docker-engine docker.io containerd runc

# Ajouter le repo Docker officiel
sudo apt install -y ca-certificates gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ajouter l'utilisateur au groupe docker
sudo usermod -aG docker $USER

echo "=== ÉTAPE 4 : Configuration Firewall UFW ==="
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw --force enable

echo "=== ÉTAPE 5 : Configuration Fail2ban ==="
sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 22
logpath = %(sshd_log)s
backend = %(sshd_backend)s

[vaultwarden]
enabled = true
port = 80,443
filter = vaultwarden
logpath = /var/log/vaultwarden/vaultwarden.log
maxretry = 3
bantime = 14400
findtime = 14400
EOF

# Créer le filtre Vaultwarden pour Fail2ban
sudo tee /etc/fail2ban/filter.d/vaultwarden.conf > /dev/null <<EOF
[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*Username or password is incorrect\. Try again\. IP: <ADDR>\. Username:.*$
ignoreregex =
EOF

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

echo "=== ÉTAPE 6 : Créer la structure des dossiers ==="
mkdir -p ~/vaultwarden/{data,backups,logs}
cd ~/vaultwarden

echo "=== ÉTAPE 7 : Créer docker-compose.yml ==="
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - DOMAIN=https://vault.thbd.fr  # À MODIFIER
      - SIGNUPS_ALLOWED=true  # Mettre false après création de ton compte
      - INVITATIONS_ALLOWED=true
      - SHOW_PASSWORD_HINT=false
      - LOG_FILE=/data/vaultwarden.log
      - LOG_LEVEL=warn
      - EXTENDED_LOGGING=true
      - TZ=Europe/Paris
      # Limiter les tentatives de connexion
      - LOGIN_RATELIMIT_MAX_BURST=10
      - LOGIN_RATELIMIT_SECONDS=60
      # Désactiver l'admin panel ou le protéger
      - ADMIN_TOKEN=Kx7B9mP3nQ8vF2wE5tY1uI6oA4sD7fG9hJ0kL3mN5pQ8rT2vX4z  # À MODIFIER avec un token aléatoire
    volumes:
      - ./data:/data
      - ./logs:/logs
    ports:
      - "8080:80"
    networks:
      - vaultwarden_network

  # Watchtower pour les mises à jour automatiques
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *  # Tous les jours à 4h du matin
      - TZ=Europe/Paris
    networks:
      - vaultwarden_network

  # Backup automatique
  backup:
    image: offen/docker-volume-backup:latest
    container_name: vaultwarden_backup
    restart: unless-stopped
    environment:
      - BACKUP_CRON_EXPRESSION=0 3 * * *  # Tous les jours à 3h du matin
      - BACKUP_FILENAME=vaultwarden-backup-%Y-%m-%d.tar.gz
      - BACKUP_RETENTION_DAYS=30  # Garder 30 jours de sauvegardes
      - BACKUP_PRUNING_PREFIX=vaultwarden-backup-
      - TZ=Europe/Paris
    volumes:
      - ./data:/backup/vaultwarden-data:ro
      - ./backups:/archive
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - vaultwarden_network

networks:
  vaultwarden_network:
    driver: bridge
EOF

echo "=== ÉTAPE 8 : Générer un token admin sécurisé ==="
ADMIN_TOKEN=$(openssl rand -base64 48)
echo ""
echo "⚠️  TOKEN ADMIN GÉNÉRÉ (SAUVEGARDE ÇA PRÉCIEUSEMENT) :"
echo "$ADMIN_TOKEN"
echo ""
echo "Remplace CHANGE_ME_GENERATE_RANDOM_TOKEN dans docker-compose.yml par ce token"
read -p "Appuie sur Entrée une fois que c'est fait..."

echo "=== ÉTAPE 9 : Configuration du domaine ==="
echo "N'oublie pas de modifier 'votre-domaine.com' dans docker-compose.yml"
echo "Configure ton NPM pour pointer vers ce serveur sur le port 8080"
read -p "Appuie sur Entrée une fois que c'est fait..."

echo "=== ÉTAPE 10 : Démarrer Vaultwarden ==="
docker compose up -d

echo "=== ÉTAPE 11 : Créer un script de sauvegarde manuelle ==="
cat > ~/vaultwarden/backup-manual.sh <<'EOF'
#!/bin/bash
BACKUP_DIR=~/vaultwarden/backups
DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="$BACKUP_DIR/manual-backup-$DATE.tar.gz"

echo "Création de la sauvegarde..."
docker compose -f ~/vaultwarden/docker-compose.yml stop vaultwarden
tar -czf "$BACKUP_FILE" -C ~/vaultwarden/data .
docker compose -f ~/vaultwarden/docker-compose.yml start vaultwarden

echo "Sauvegarde créée : $BACKUP_FILE"
echo "Nettoyage des sauvegardes de plus de 30 jours..."
find "$BACKUP_DIR" -name "manual-backup-*.tar.gz" -mtime +30 -delete
EOF

chmod +x ~/vaultwarden/backup-manual.sh

echo "=== ÉTAPE 12 : Script de restauration ==="
cat > ~/vaultwarden/restore-backup.sh <<'EOF'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: ./restore-backup.sh <fichier-backup.tar.gz>"
    echo "Sauvegardes disponibles:"
    ls -lh ~/vaultwarden/backups/
    exit 1
fi

BACKUP_FILE="$1"
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Fichier introuvable: $BACKUP_FILE"
    exit 1
fi

read -p "⚠️  Cela va écraser les données actuelles. Continuer? (yes/no) " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Annulé."
    exit 1
fi

echo "Arrêt de Vaultwarden..."
docker compose -f ~/vaultwarden/docker-compose.yml stop vaultwarden

echo "Sauvegarde des données actuelles..."
mv ~/vaultwarden/data ~/vaultwarden/data.old.$(date +%Y-%m-%d_%H-%M-%S)

echo "Restauration..."
mkdir -p ~/vaultwarden/data
tar -xzf "$BACKUP_FILE" -C ~/vaultwarden/data

echo "Redémarrage de Vaultwarden..."
docker compose -f ~/vaultwarden/docker-compose.yml start vaultwarden

echo "✅ Restauration terminée!"
EOF

chmod +x ~/vaultwarden/restore-backup.sh

echo "=== ÉTAPE 13 : Sécuriser SSH (IMPORTANT) ==="
echo ""
echo "⚠️  IMPORTANT : Tu dois sécuriser SSH maintenant !"
echo ""
echo "1. Génère une clé SSH sur ton PC (si pas déjà fait):"
echo "   ssh-keygen -t ed25519 -C 'ton-email@example.com'"
echo ""
echo "2. Copie la clé sur le serveur:"
echo "   ssh-copy-id user@ton-serveur"
echo ""
echo "3. Une fois la clé copiée, lance ce script pour désactiver le login par mot de passe:"
cat > ~/vaultwarden/secure-ssh.sh <<'EOF'
#!/bin/bash
echo "Sécurisation SSH..."
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
echo "✅ SSH sécurisé ! Seules les clés SSH sont autorisées maintenant."
EOF

chmod +x ~/vaultwarden/secure-ssh.sh

echo ""
echo "=================================================="
echo "✅ INSTALLATION TERMINÉE !"
echo "=================================================="
echo ""
echo "📋 Prochaines étapes :"
echo "1. Édite docker-compose.yml et remplace:"
echo "   - votre-domaine.com par ton vrai domaine"
echo "   - CHANGE_ME_GENERATE_RANDOM_TOKEN par le token généré"
echo ""
echo "2. Configure ton NPM pour pointer vers ce serveur (port 8080)"
echo ""
echo "3. Redémarre les containers: docker compose up -d"
echo ""
echo "4. Accède à https://vault.thbd.fr/admin avec le token admin"
echo ""
echo "5. Crée ton compte Vaultwarden"
echo ""
echo "6. IMPORTANT: Mets SIGNUPS_ALLOWED=false dans docker-compose.yml"
echo "   puis: docker compose up -d"
echo ""
echo "7. Sécurise SSH avec: ~/vaultwarden/secure-ssh.sh"
echo ""
echo "📁 Commandes utiles :"
echo "- Sauvegarde manuelle: ~/vaultwarden/backup-manual.sh"
echo "- Restaurer: ~/vaultwarden/restore-backup.sh <fichier>"
echo "- Logs: docker logs vaultwarden -f"
echo "- Status: docker compose ps"
echo ""
echo "🔐 Sauvegardes automatiques: tous les jours à 3h du matin"
echo "🔄 Mises à jour auto: tous les jours à 4h du matin"
echo "📦 Conservation: 30 jours de sauvegardes"
echo ""
echo "=================================================="
EOF
