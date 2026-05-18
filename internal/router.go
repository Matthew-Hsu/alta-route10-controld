package internal

import (
	"fmt"
	"strings"
)

const (
	CtrlDVersion     = "1.5.0"
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
	progress("Generating ctrld.toml...")
	toml := RenderCtrlDTOML(resolverID, bootstrapIP)
	if err := client.UploadFile("/cfg/ctrld.toml", toml); err != nil {
		return fmt.Errorf("failed to upload ctrld.toml: %w", err)
	}
	progress("ctrld.toml uploaded")

	progress("Generating post-cfg.sh...")
	postCfg := RenderPostCfgSh(resolverID, bootstrapIP)
	if err := client.UploadFile("/cfg/post-cfg.sh", postCfg); err != nil {
		return fmt.Errorf("failed to upload post-cfg.sh: %w", err)
	}

	if _, err := client.RunCommand("chmod +x /cfg/post-cfg.sh"); err != nil {
		return fmt.Errorf("failed to chmod post-cfg.sh: %w", err)
	}
	progress("post-cfg.sh uploaded and made executable")

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
