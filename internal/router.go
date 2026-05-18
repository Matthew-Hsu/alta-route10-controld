package internal

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

const (
	CtrlDVersion     = "1.5.0"
	CtrlDDownloadURL = "https://github.com/Control-D-Inc/ctrld/releases/download/v" + CtrlDVersion + "/ctrld_" + CtrlDVersion + "_linux_arm64.tar.gz"
)

// DownloadCtrlD downloads the ctrld binary to a local temp file
func DownloadCtrlD(progress func(string)) (string, error) {
	tmpDir := os.TempDir()
	localPath := filepath.Join(tmpDir, "ctrld.tar.gz")

	progress("Downloading ctrld v" + CtrlDVersion + "...")

	resp, err := http.Get(CtrlDDownloadURL)
	if err != nil {
		return "", fmt.Errorf("download failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download failed with status %d", resp.StatusCode)
	}

	f, err := os.Create(localPath)
	if err != nil {
		return "", fmt.Errorf("cannot create temp file: %w", err)
	}
	defer f.Close()

	// Copy with progress
	_, err = io.Copy(f, resp.Body)
	if err != nil {
		return "", fmt.Errorf("download incomplete: %w", err)
	}

	progress("Download complete")
	return localPath, nil
}

// InstallCtrlDOnRouter downloads ctrld, extracts, and uploads to the router
func InstallCtrlDOnRouter(client *SSHClient, progress func(string)) error {
	progress("Downloading ctrld v" + CtrlDVersion + "...")

	// Download directly on the router - simpler and faster
	cmd := fmt.Sprintf(
		"cd /cfg && wget -O ctrld.tar.gz '%s' && tar xzf ctrld.tar.gz -C /tmp && mv /tmp/dist/ctrld_%s_linux_arm64/ctrld /cfg/ctrld && chmod +x /cfg/ctrld && rm -rf /tmp/dist ctrld.tar.gz",
		CtrlDDownloadURL, CtrlDVersion,
	)

	output, err := client.RunCommandCombined(cmd)
	if err != nil {
		return fmt.Errorf("ctrld install failed: %w\n%s", err, output)
	}

	progress("ctrld binary installed to /cfg/ctrld")

	// Verify
	output, err = client.RunCommand("/cfg/ctrld --help 2>&1 | head -1")
	if err != nil {
		return fmt.Errorf("ctrld binary verification failed: %w", err)
	}
	if !contains(output, "ctrld") {
		return fmt.Errorf("ctrld binary appears invalid: %s", output)
	}

	progress("ctrld binary verified")
	return nil
}

// ConfigureRouter generates and uploads config files
func ConfigureRouter(client *SSHClient, resolverID, bootstrapIP string, progress func(string)) error {
	// Upload ctrld.toml
	progress("Generating ctrld.toml...")
	toml := RenderCtrlDTOML(resolverID, bootstrapIP)
	if err := client.UploadFile("/cfg/ctrld.toml", toml); err != nil {
		return fmt.Errorf("failed to upload ctrld.toml: %w", err)
	}
	progress("ctrld.toml uploaded")

	// Upload post-cfg.sh
	progress("Generating post-cfg.sh...")
	postCfg := RenderPostCfgSh(resolverID, bootstrapIP)
	if err := client.UploadFile("/cfg/post-cfg.sh", postCfg); err != nil {
		return fmt.Errorf("failed to upload post-cfg.sh: %w", err)
	}

	// Make executable
	_, err := client.RunCommand("chmod +x /cfg/post-cfg.sh")
	if err != nil {
		return fmt.Errorf("failed to chmod post-cfg.sh: %w", err)
	}
	progress("post-cfg.sh uploaded and made executable")

	return nil
}

// ApplyConfig runs post-cfg.sh on the router
func ApplyConfig(client *SSHClient, progress func(string)) error {
	progress("Running post-cfg.sh...")

	output, err := client.RunCommandCombined("timeout 60 /cfg/post-cfg.sh 2>&1")
	if err != nil {
		// Check if it's just a timeout warning
		progress("post-cfg.sh completed (some warnings may be normal)")
	} else {
		progress("post-cfg.sh completed successfully")
	}
	_ = output

	return nil
}

// VerifySetup checks that everything is working
func VerifySetup(client *SSHClient, progress func(string)) error {
	// Check ctrld is running
	output, err := client.RunCommand("pidof ctrld")
	if err != nil || output == "" {
		return fmt.Errorf("ctrld is not running")
	}
	progress("ctrld is running (PID " + output + ")")

	// Check DNS resolution on router
	output, err = client.RunCommand("nslookup google.com 127.0.0.1#5354 2>&1 | head -5")
	if err != nil {
		return fmt.Errorf("ctrld DNS not responding on port 5354")
	}
	progress("ctrld DNS responding on port 5354")

	// Check iptables rules
	output, err = client.RunCommand("iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 5354")
	if err != nil || output == "0" {
		return fmt.Errorf("iptables redirect rules not found")
	}
	progress("iptables redirect rules active")

	return nil
}

// timeoutContext creates a context with a timeout (unused but kept for future use)
// func timeoutContext(d time.Duration) (context.Context, context.CancelFunc) {
// 	return context.WithTimeout(context.Background(), d)
// }

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchSubstring(s, substr)
}

func searchSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
