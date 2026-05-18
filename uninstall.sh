#!/bin/sh
# Uninstall ControlD from Alta Labs Route 10
# Run on the router: sh uninstall.sh

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   Uninstall ControlD from Alta Route 10                 ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [ ! -f /cfg/post-cfg.sh ] && [ ! -f /cfg/ctrld ]; then
    echo "  No ControlD installation found."
    exit 0
fi

printf "  Remove all ControlD configuration? [y/N]: "
read -r CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "  Aborting."; exit 0; }

echo ""

# Stop ctrld
if pidof ctrld >/dev/null 2>&1; then
    echo "  Stopping ctrld..."
    kill $(pidof ctrld) 2>/dev/null
    echo "  [OK] ctrld stopped"
else
    echo "  [OK] ctrld not running"
fi

# Remove iptables rules
echo "  Removing iptables rules..."
iptables -t nat -F PREROUTING 2>/dev/null
echo "  [OK] iptables rules removed"

# Remove files
echo "  Removing configuration files..."
rm -f /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh /cfg/controld.env /cfg/controld-update.sh
echo "  [OK] Files removed"

# Remove cron job
crontab -l 2>/dev/null | grep -v controld-update | crontab - 2>/dev/null
echo "  [OK] Auto-update cron removed"

# Restart default DNS
echo "  Restarting default DNS services..."
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
echo "  [OK] Default DNS restored"

echo ""
echo "  Uninstall complete. Reboot recommended."
echo ""
