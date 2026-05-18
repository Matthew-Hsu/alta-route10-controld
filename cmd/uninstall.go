package cmd

import (
	"fmt"

	"codeberg.org/CookieTyrant/alta-route10-controld/internal"
)

// Uninstall removes all ControlD configuration from the router
func Uninstall() {
	fmt.Println("╔══════════════════════════════════════════════════════════════╗")
	fmt.Println("║   Uninstall ControlD from Alta Route 10                     ║")
	fmt.Println("╚══════════════════════════════════════════════════════════════╝")
	fmt.Println()

	routerIP := internal.PromptDefault("Router IP address", "192.168.1.1")

	keyPath := internal.FindSSHKey()
	if keyPath == "" {
		internal.PrintErr("No SSH key found. Cannot connect to router.")
		return
	}

	client, err := internal.NewSSHClient(routerIP, keyPath)
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Cannot connect: %v", err))
		return
	}
	defer client.Close()

	fmt.Println()
	if !internal.Confirm("This will remove all ControlD configuration. Continue?", false) {
		fmt.Println("Cancelled.")
		return
	}

	fmt.Println()

	// Stop ctrld
	internal.PrintInfo("Stopping ctrld...")
	client.RunCommand("kill $(pidof ctrld) 2>/dev/null")
	internal.PrintOK("ctrld stopped")

	// Remove iptables rules
	internal.PrintInfo("Removing iptables redirect rules...")
	client.RunCommand("iptables -t nat -F PREROUTING 2>/dev/null")
	internal.PrintOK("iptables rules removed")

	// Remove files
	internal.PrintInfo("Removing configuration files...")
	client.RunCommand("rm -f /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh")
	internal.PrintOK("Files removed")

	// Restart default DNS services
	internal.PrintInfo("Restarting default DNS services...")
	client.RunCommand("/etc/init.d/https-dns-proxy restart")
	client.RunCommand("/etc/init.d/dnsmasq restart")
	internal.PrintOK("Default DNS restored")

	fmt.Println()
	fmt.Println("  Uninstall complete. The router is now using its default DNS settings.")
	fmt.Println("  You may want to reboot the router to ensure a clean state.")
	fmt.Println()
}
