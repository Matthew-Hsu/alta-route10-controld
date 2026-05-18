package cmd

import (
	"fmt"

	"codeberg.org/CookieTyrant/alta-route10-controld/internal"
)

// Setup runs the interactive setup wizard
func Setup() {
	fmt.Println("╔══════════════════════════════════════════════════════════════╗")
	fmt.Println("║   Alta Labs Route 10 + ControlD DNS Setup Wizard            ║")
	fmt.Println("║   Encrypted DNS with per-device visibility                   ║")
	fmt.Println("╚══════════════════════════════════════════════════════════════╝")
	fmt.Println()

	// ── Step 1: ControlD Configuration ──
	internal.PrintStep(1, "ControlD Configuration")
	fmt.Println("  Get your resolver ID from: https://controld.com → Dashboard → Endpoint Resolvers")
	fmt.Println()

	resolverID := internal.PromptDefault("Resolver ID", "")
	if len(resolverID) < 5 {
		internal.PrintErr("Resolver ID seems too short. Check your ControlD dashboard.")
		return
	}

	bootstrapIP := internal.PromptDefault("Bootstrap IP", "76.76.2.22")
	fmt.Println()

	// ── Step 2: Router Access ──
	internal.PrintStep(2, "Router Access")
	fmt.Println("  Make sure your computer is on the same network as the router.")
	fmt.Println()

	routerIP := internal.PromptDefault("Router IP address", "192.168.1.1")

	// Find or generate SSH key
	keyPath := internal.FindSSHKey()
	if keyPath == "" {
		fmt.Println()
		internal.PrintInfo("No SSH key found on this machine.")
		fmt.Println()

		if internal.Confirm("Generate a new SSH key?", true) {
			var err error
			keyPath, err = internal.GenerateSSHKey()
			if err != nil {
				internal.PrintErr(fmt.Sprintf("Failed to generate SSH key: %v", err))
				return
			}

			pubKey, err := internal.ReadSSHPublicKey(keyPath)
			if err != nil {
				internal.PrintErr("Cannot read generated public key: " + err.Error())
				return
			}
			fmt.Println()
			internal.PrintInfo("SSH key generated! Add this public key to your Alta account:")
			fmt.Println()
			fmt.Printf("    %s\n\n", pubKey)
			fmt.Println("  1. Go to https://manage.alta.inc")
			fmt.Println("  2. Settings → System → SSH Keys")
			fmt.Println("  3. Click 'Add a new key' and paste the key above")
			fmt.Println("  4. Click 'Add Key'")
			fmt.Println()

			internal.Prompt("Press Enter when you've added the key to Alta...")
		} else {
			internal.PrintErr("An SSH key is required to connect to the router.")
			fmt.Println()
			fmt.Println("  To add one manually:")
			fmt.Println("    1. Generate a key: ssh-keygen -t ed25519")
			fmt.Println("    2. Add the public key at https://manage.alta.inc")
			fmt.Println("    3. Run this wizard again")
			return
		}
	} else {
		internal.PrintOK("Found SSH key: " + keyPath)
	}

	// Test SSH connection
	fmt.Println()
	internal.PrintInfo("Testing SSH connection...")
	client, err := internal.NewSSHClient(routerIP, keyPath)
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Cannot connect to router: %v", err))
		fmt.Println()
		fmt.Println("  Troubleshooting:")
		fmt.Println("    - Is the router IP correct?")
		fmt.Println("    - Is your SSH key added at https://manage.alta.inc?")
		fmt.Println("    - Are you on the same network as the router?")
		return
	}
	defer client.Close()
	internal.PrintOK("SSH connection established")

	// ── Step 3: Validate Router ──
	internal.PrintStep(3, "Validating Router")

	arch, err := client.RunCommand("uname -m")
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Cannot detect architecture: %v", err))
		return
	}
	internal.PrintOK("Architecture: " + arch)

	if arch != "aarch64" {
		internal.PrintWarn("Expected aarch64, got " + arch + ". Setup may not work correctly.")
		if !internal.Confirm("Continue anyway?", false) {
			return
		}
	}

	// Check if already installed
	existing, _ := client.RunCommand("ls /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh 2>&1")
	if existing != "" && !containsStr(existing, "No such") {
		internal.PrintWarn("Existing ControlD configuration found on the router.")
		if !internal.Confirm("Overwrite existing configuration?", true) {
			return
		}
	}

	// ── Step 4: Install ctrld ──
	internal.PrintStep(4, "Installing ctrld")

	err = internal.InstallCtrlDOnRouter(client, func(msg string) {
		internal.PrintInfo(msg)
	})
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Installation failed: %v", err))
		return
	}
	internal.PrintOK("ctrld installed successfully")

	// ── Step 5: Configure ──
	internal.PrintStep(5, "Configuring")

	err = internal.ConfigureRouter(client, resolverID, bootstrapIP, func(msg string) {
		internal.PrintInfo(msg)
	})
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Configuration failed: %v", err))
		return
	}
	internal.PrintOK("Configuration files uploaded")

	// ── Step 6: Apply ──
	internal.PrintStep(6, "Applying Configuration")

	err = internal.ApplyConfig(client, func(msg string) {
		internal.PrintInfo(msg)
	})
	if err != nil {
		internal.PrintErr(fmt.Sprintf("Apply failed: %v", err))
		return
	}
	internal.PrintOK("Configuration applied")

	// ── Step 7: Verify ──
	internal.PrintStep(7, "Verification")

	err = internal.VerifySetup(client, func(msg string) {
		internal.PrintOK(msg)
	})
	if err != nil {
		internal.PrintWarn(fmt.Sprintf("Verification issue: %v", err))
		internal.PrintInfo("DNS may need a moment to stabilize. Check your ControlD dashboard in a few minutes.")
	} else {
		internal.PrintOK("All checks passed!")
	}

	// ── Done ──
	fmt.Println()
	fmt.Println("╔══════════════════════════════════════════════════════════════╗")
	fmt.Println("║                    Setup Complete!                           ║")
	fmt.Println("╚══════════════════════════════════════════════════════════════╝")
	fmt.Println()
	fmt.Println("  Your DNS is now routed through ControlD with per-device visibility.")
	fmt.Println()
	fmt.Println("  Check your dashboard: https://controld.com")
	fmt.Println("  You should see individual devices appear within a few minutes.")
	fmt.Println()
	fmt.Println("  Installed files on router:")
	fmt.Println("    /cfg/ctrld         - DNS proxy binary")
	fmt.Println("    /cfg/ctrld.toml    - DNS proxy configuration")
	fmt.Println("    /cfg/post-cfg.sh   - Boot persistence script")
	fmt.Println()
	fmt.Println("  These files persist across reboots.")
	fmt.Println("  To remove: alta-controld uninstall")
	fmt.Println()
}

func containsStr(s, substr string) bool {
	return len(s) >= len(substr) && len(s) > 0 && searchStr(s, substr)
}

func searchStr(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
