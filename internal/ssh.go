package internal

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// SSHClient wraps an SSH connection to the router
type SSHClient struct {
	client *ssh.Client
	host   string
}

// FindSSHKey locates an existing SSH key
func FindSSHKey() string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	sshDir := filepath.Join(homeDir, ".ssh")

	// Check for ed25519 first (preferred)
	candidates := []string{
		filepath.Join(sshDir, "id_ed25519"),
		filepath.Join(sshDir, "id_rsa"),
	}

	for _, key := range candidates {
		if _, err := os.Stat(key); err == nil {
			return key
		}
	}
	return ""
}

// GenerateSSHKey creates a new ed25519 key pair
func GenerateSSHKey() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot find home directory: %w", err)
	}

	sshDir := filepath.Join(homeDir, ".ssh")
	keyPath := filepath.Join(sshDir, "id_ed25519")

	// Create .ssh dir if needed
	if err := os.MkdirAll(sshDir, 0700); err != nil {
		return "", fmt.Errorf("cannot create .ssh directory: %w", err)
	}

	// Use ssh-keygen (available on Windows 10+, macOS, Linux)
	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-C", "alta-controld", "-f", keyPath, "-N", "")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("ssh-keygen failed: %w\n%s", err, output)
	}

	return keyPath, nil
}

// ReadSSHPublicKey reads the public key file
func ReadSSHPublicKey(keyPath string) (string, error) {
	pubPath := keyPath + ".pub"
	data, err := os.ReadFile(pubPath)
	if err != nil {
		return "", fmt.Errorf("cannot read public key: %w", err)
	}
	return strings.TrimSpace(string(data)), nil
}

// NewSSHClient connects to the router via SSH
func NewSSHClient(host string, keyPath string) (*SSHClient, error) {
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("cannot read SSH key: %w", err)
	}

	signer, err := ssh.ParsePrivateKey(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("cannot parse SSH key: %w", err)
	}

	config := &ssh.ClientConfig{
		User: "root",
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	}

	addr := fmt.Sprintf("%s:22", host)
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return nil, fmt.Errorf("SSH connection failed: %w", err)
	}

	return &SSHClient{client: client, host: host}, nil
}

// RunCommand executes a command on the router and returns output
func (c *SSHClient) RunCommand(cmd string) (string, error) {
	session, err := c.client.NewSession()
	if err != nil {
		return "", fmt.Errorf("cannot create SSH session: %w", err)
	}
	defer session.Close()

	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr

	err = session.Run(cmd)
	if err != nil {
		return strings.TrimSpace(stderr.String()), err
	}

	return strings.TrimSpace(stdout.String()), nil
}

// RunCommandCombined executes a command and returns combined output
func (c *SSHClient) RunCommandCombined(cmd string) (string, error) {
	session, err := c.client.NewSession()
	if err != nil {
		return "", fmt.Errorf("cannot create SSH session: %w", err)
	}
	defer session.Close()

	var buf bytes.Buffer
	session.Stdout = &buf
	session.Stderr = &buf

	err = session.Run(cmd)
	return strings.TrimSpace(buf.String()), err
}

// UploadFile writes content to a file on the router via SSH
func (c *SSHClient) UploadFile(remotePath, content string) error {
	// Escape single quotes in content for the heredoc
	escaped := strings.ReplaceAll(content, "'", "'\\''")

	cmd := fmt.Sprintf("cat > %s << 'ALTAEOF'\n%s\nALTAEOF", remotePath, escaped)
	_, err := c.RunCommandCombined(cmd)
	return err
}

// Close closes the SSH connection
func (c *SSHClient) Close() error {
	return c.client.Close()
}

// Host returns the router's IP address
func (c *SSHClient) Host() string {
	return c.host
}
