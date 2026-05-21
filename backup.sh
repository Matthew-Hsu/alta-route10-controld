#!/bin/sh
# Backup and restore ControlD config for Alta Labs Route 10
# Run on the router: sh backup.sh           (to backup)
#                     sh backup.sh restore   (to restore)

FILES="/cfg/controld.env /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh /cfg/controld-update.sh"
BACKUP_DIR="/cfg/controld-backup"

if [ "$1" = "restore" ]; then
    echo ""
    echo "  Restoring ControlD config from backup..."

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "  [!] No backup found at $BACKUP_DIR"
        exit 1
    fi

    for f in $FILES; do
        base=$(basename "$f")
        if [ -f "$BACKUP_DIR/$base" ]; then
            cp "$BACKUP_DIR/$base" "$f"
            echo "  [OK] $f restored"
        else
            echo "  [!!] $base not in backup"
        fi
    done

    chmod +x /cfg/ctrld /cfg/post-cfg.sh /cfg/controld-update.sh 2>/dev/null

    if [ -f "$BACKUP_DIR/crontab" ]; then
        crontab "$BACKUP_DIR/crontab" 2>/dev/null
        echo "  [OK] Cron job restored"
    fi

    if [ -x /cfg/post-cfg.sh ]; then
        echo ""
        echo "  Applying configuration..."
        /cfg/post-cfg.sh
    fi

    echo ""
    echo "  Restore complete."
    exit 0
fi

echo ""
echo "  Backing up ControlD config..."

mkdir -p "$BACKUP_DIR"

count=0
for f in $FILES; do
    if [ -f "$f" ]; then
        cp "$f" "$BACKUP_DIR/$(basename "$f")"
        echo "  [OK] $f"
        count=$((count + 1))
    else
        echo "  [--] $f (not found, skipping)"
    fi
done

if [ "$count" -eq 0 ]; then
    echo ""
    echo "  [!] No ControlD files found. Is it installed?"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

crontab -l 2>/dev/null | grep -q controld-update && {
    crontab -l 2>/dev/null > "$BACKUP_DIR/crontab"
    echo "  [OK] Cron job saved"
}

echo ""
echo "  Backed up $count files to $BACKUP_DIR/"
echo "  To restore after firmware update: sh backup.sh restore"
echo ""
