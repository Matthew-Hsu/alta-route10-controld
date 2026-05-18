package internal

import (
	"fmt"
	"strings"
)

const (
	CtrlDDownloadURL = "https://github.com/Control-D-Inc/ctrld/releases/download/v" + CtrlDVersion + "/ctrld_" + CtrlDVersion + "_linux_arm64.tar.gz"
)

func InstallCtrlDOnRouter(client *SSHClient, progress func(string)) error {
	progress("Downloading ctrld v" + CtrlDVersion + "...")

	cmd := fmt.Sprintf(
		"cd /cfg && wget -O ctrld.tar.gz '%s' && tar xzf ctrld.tar.gz -C /tmp && mv /tmp/dist/ctrld_%s_linux_arm64/ctrld /cfg/ctrld && chmod +x /cfg/ctrld && rm -rf /tmp/dist ctrld.tar.gz",
		CtrlDDownloadURL, CtrlDVersion,
	)

	output, err := client.RunCommandCombined(cmd)
	if err != nil {
		return fmt.Errorf("ctrld install failed: %w\n%s", err, output)
	}

	progress("ctrld binary installed to /cfg/ctrld")

	output, err = client.RunCommand("/cfg/ctrld --help 2>&1 | head -1")
	if err != nil {
		return fmt.Errorf("ctrld binary verification failed: %w", err)
	}
	if !strings.Contains(output, "ctrld") {
		return fmt.Errorf("ctrld binary appears invalid: %s", output)
	}

	progress("ctrld binary verified")
	return nil
}

func ConfigureRouter(client *SSHClient, resolverID, bootstrapIP string, progress func(string)) error {
	// Upload recovery env file (survives firmware updates if /cfg/ persists)
	progress("Uploading recovery config...")
	env := RenderControldEnv(resolverID, bootstrapIP, CtrlDVersion)
	if err := client.UploadFile("/cfg/controld.env", env); err != nil {
		return fmt.Errorf("failed to upload controld.env: %w", err)
	}

	// Upload ctrld.toml
	progress("Generating ctrld.toml...")
	toml := RenderCtrlDTOML(resolverID, bootstrapIP)
	if err := client.UploadFile("/cfg/ctrld.toml", toml); err != nil {
		return fmt.Errorf("failed to upload ctrld.toml: %w", err)
	}
	progress("ctrld.toml uploaded")

	// Upload post-cfg.sh (self-healing boot script)
	progress("Generating post-cfg.sh...")
	postCfg := RenderPostCfgSh(resolverID, bootstrapIP)
	if err := client.UploadFile("/cfg/post-cfg.sh", postCfg); err != nil {
		return fmt.Errorf("failed to upload post-cfg.sh: %w", err)
	}

	if _, err := client.RunCommand("chmod +x /cfg/post-cfg.sh"); err != nil {
		return fmt.Errorf("failed to chmod post-cfg.sh: %w", err)
	}
	progress("post-cfg.sh uploaded and made executable")

	// Upload auto-update script
	progress("Installing auto-update script...")
	updateSh := RenderControldUpdateSh()
	if err := client.UploadFile("/cfg/controld-update.sh", updateSh); err != nil {
		return fmt.Errorf("failed to upload controld-update.sh: %w", err)
	}
	if _, err := client.RunCommand("chmod +x /cfg/controld-update.sh"); err != nil {
		return fmt.Errorf("failed to chmod controld-update.sh: %w", err)
	}

	// Install weekly cron job for auto-updates
	if err := InstallUpdateCron(client); err != nil {
		// Non-fatal: auto-update is nice-to-have
		progress("Warning: could not install cron job: " + err.Error())
	} else {
		progress("Weekly auto-update cron job installed")
	}

	return nil
}

// InstallUpdateCron adds a weekly cron job to check for ctrld updates.
func InstallUpdateCron(client *SSHClient) error {
	// Remove any existing entry first
	client.RunCommand("crontab -l 2>/dev/null | grep -v controld-update | crontab -")

	// Add the weekly job (Mondays at 3am)
	output, err := client.RunCommand("(crontab -l 2>/dev/null; echo '0 3 * * 1 /cfg/controld-update.sh') | crontab -")
	if err != nil {
		return fmt.Errorf("crontab install failed: %w, output: %s", err, output)
	}
	return nil
}

func ApplyConfig(client *SSHClient, progress func(string)) error {
	progress("Running post-cfg.sh...")

	output, err := client.RunCommandCombined("timeout 60 /cfg/post-cfg.sh 2>&1")
	if err != nil {
		progress("post-cfg.sh completed with warnings")
		_ = output
		return fmt.Errorf("post-cfg.sh reported errors: %w", err)
	}

	progress("post-cfg.sh completed successfully")
	return nil
}

func VerifySetup(client *SSHClient, progress func(string)) error {
	output, err := client.RunCommand("pidof ctrld")
	if err != nil || output == "" {
		return fmt.Errorf("ctrld is not running")
	}
	progress("ctrld is running (PID " + output + ")")

	output, err = client.RunCommand("nslookup google.com 127.0.0.1#5354 2>&1 | head -5")
	if err != nil {
		return fmt.Errorf("ctrld DNS not responding on port 5354")
	}
	progress("ctrld DNS responding on port 5354")

	output, err = client.RunCommand("iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 5354")
	if err != nil || output == "0" {
		return fmt.Errorf("iptables redirect rules not found")
	}
	progress("iptables redirect rules active")

	return nil
}
