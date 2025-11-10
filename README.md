# Vaultwarden Installation Sécurisée

Installation automatisée de Vaultwarden sur Ubuntu Server avec :
- 🔒 Sécurité maximale (Fail2ban, UFW, SSH sécurisé)
- 🔄 Mises à jour automatiques (Watchtower)
- 💾 Sauvegardes quotidiennes automatiques
- 📦 Conservation de 30 jours de backups

## Installation
```bash
wget https://raw.githubusercontent.com/TON-USERNAME/vaultwarden-secure-install/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## Configuration requise
- Ubuntu Server 22.04 ou 24.04
- Accès root ou sudo
- Un nom de domaine configuré
- Nginx Proxy Manager (ou autre reverse proxy)
