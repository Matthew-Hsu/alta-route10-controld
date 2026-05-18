package internal

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Config struct {
	ResolverID  string `json:"resolver_id"`
	BootstrapIP string `json:"bootstrap_ip"`
	RouterIP    string `json:"router_ip"`
	CtrlDVersion string `json:"ctrld_version"`
	LastSetup   string `json:"last_setup"`
}

const StateFileName = ".alta-controld.json"

func StateFilePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return StateFileName
	}
	return filepath.Join(home, StateFileName)
}

func LoadConfig() (*Config, error) {
	path := StateFilePath()
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("invalid state file: %w", err)
	}
	return &cfg, nil
}

func SaveConfig(cfg *Config) error {
	cfg.LastSetup = time.Now().Format(time.RFC3339)
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("cannot serialize config: %w", err)
	}
	return os.WriteFile(StateFilePath(), data, 0600)
}

func ConfigExists() bool {
	_, err := os.Stat(StateFilePath())
	return err == nil
}
