package cmd

import (
	"fmt"

	"codeberg.org/CookieTyrant/alta-route10-controld/internal"
)

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

	internal.PrintInfo("Stopping ctrld...")
	if _, err := client.RunCommand("pidof ctrld"); err == nil {
		if _, err := client.RunCommand("kill $(pidof ctrld) 2>/dev/null"); err != nil {
			internal.PrintWarn("Could not stop ctrld: " + err.Error())
		}
	}
	internal.PrintOK("ctrld stopped")

	internal.PrintInfo("Removing iptables redirect rules...")
	if _, err := client.RunCommand("iptables -t nat -F PREROUTING 2>/dev/null"); err != nil {
		internal.PrintWarn("Could not flush iptables rules: " + err.Error())
	}
	internal.PrintOK("iptables rules removed")

	internal.PrintInfo("Removing configuration files...")
	if _, err := client.RunCommand("rm -f /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh"); err != nil {
		internal.PrintErr("Failed to remove files: " + err.Error())
		return
	}
	internal.PrintOK("Files removed")

	internal.PrintInfo("Restarting default DNS services...")
	if _, err := client.RunCommand("/etc/init.d/https-dns-proxy restart && /etc/init.d/dnsmasq restart"); err != nil {
		internal.PrintWarn("DNS service restart had issues: " + err.Error())
	}
	internal.PrintOK("Default DNS restored")

	fmt.Println()
	fmt.Println("  Uninstall complete. The router is now using its default DNS settings.")
	fmt.Println("  You may want to reboot the router to ensure a clean state.")
	fmt.Println()
}
