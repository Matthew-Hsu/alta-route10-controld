package cmd

import (
	"fmt"

	"codeberg.org/CookieTyrant/alta-route10-controld/internal"
)

// Status checks the current ControlD configuration on the router
func Status() {
	fmt.Println("Checking ControlD status on Alta Route 10...")
	fmt.Println()

	routerIP := internal.PromptDefault("Router IP address", "192.168.1.1")

	keyPath := internal.FindSSHKey()
	if keyPath == "" {
		internal.PrintErr("No SSH key found. Run 'alta-controld setup' first.")
		return
	}

	client, err := internal.NewSSHClient(routerIP, keyPath)
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Cannot connect: %v", err))
		return
	}
	defer client.Close()
	internal.PrintOK("Connected to " + routerIP)

	fmt.Println()
	fmt.Println("── Configuration Files ──")
	checkFile(client, "/cfg/ctrld", "ctrld binary")
	checkFile(client, "/cfg/ctrld.toml", "ctrld.toml")
	checkFile(client, "/cfg/post-cfg.sh", "post-cfg.sh")

	fmt.Println()
	fmt.Println("── Services ──")

	// Check ctrld
	output, err := client.RunCommand("pidof ctrld")
	if err != nil || output == "" {
		internal.PrintErr("ctrld is NOT running")
	} else {
		internal.PrintOK("ctrld is running (PID " + output + ")")
	}

	// Check https-dns-proxy
	output, err = client.RunCommand("/etc/init.d/https-dns-proxy status 2>&1")
	if output == "running" {
		internal.PrintOK("https-dns-proxy is running (fallback)")
	} else {
		internal.PrintWarn("https-dns-proxy status: " + output)
	}

	fmt.Println()
	fmt.Println("── DNS Resolution ──")

	// Test ctrld directly
	output, err = client.RunCommand("nslookup google.com 127.0.0.1#5354 2>&1 | head -3")
	if err != nil {
		internal.PrintErr("ctrld not responding on port 5354")
	} else {
		internal.PrintOK("ctrld DNS responding on port 5354")
	}

	// Test system DNS
	output, err = client.RunCommand("nslookup google.com 2>&1 | head -3")
	if err != nil {
		internal.PrintErr("System DNS not working")
	} else {
		internal.PrintOK("System DNS working")
	}

	fmt.Println()
	fmt.Println("── iptables Redirect Rules ──")
	output, err = client.RunCommand("iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 5354")
	if err != nil || output == "0" {
		internal.PrintErr("No iptables redirect rules found (per-device visibility disabled)")
	} else {
		internal.PrintOK(output + " iptables redirect rules active (per-device visibility enabled)")
	}

	fmt.Println()
	fmt.Println("── ControlD Endpoint ──")
	output, err = client.RunCommand("uci show https-dns-proxy.@https-dns-proxy[0].resolver_url 2>/dev/null | grep -o 'https://dns.controld.com/[a-z0-9]*'")
	if err != nil || output == "" {
		internal.PrintWarn("https-dns-proxy not pointing to ControlD")
	} else {
		internal.PrintOK("Resolver URL: " + output)
	}
}

func checkFile(client *internal.SSHClient, path, name string) {
	output, err := client.RunCommand("ls -la " + path + " 2>&1")
	if err != nil || containsNo(output, "No such") {
		internal.PrintErr(name + " not found")
	} else {
		internal.PrintOK(name + " exists")
	}
}

func containsNo(s, substr string) bool {
	return len(s) >= len(substr)
}
