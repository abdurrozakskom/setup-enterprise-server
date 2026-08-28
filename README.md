# setup-enterprise-server.sh

# Berikan permission executable
chmod +x setup-enterprise-server.sh

# Jalankan sebagai root
sudo bash setup-enterprise-server.sh

# Cek health semua service
/usr/local/sbin/health-check.sh

# Deploy konfigurasi (idempotent)
/usr/local/sbin/deploy-config.sh

# Cek scaling trigger
/usr/local/sbin/check-scaling-trigger.sh

# Jalankan backup manual
/usr/local/sbin/backup-applications.sh
