package internal

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// Prompt displays a prompt and reads a line from stdin
func Prompt(prompt string) string {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print(prompt)
	text, _ := reader.ReadString('\n')
	return strings.TrimSpace(text)
}

// PromptDefault displays a prompt with a default value
func PromptDefault(prompt, defaultVal string) string {
	if defaultVal != "" {
		result := Prompt(fmt.Sprintf("%s [%s]: ", prompt, defaultVal))
		if result == "" {
			return defaultVal
		}
		return result
	}
	for {
		result := Prompt(prompt + ": ")
		if result != "" {
			return result
		}
		fmt.Println("  This field is required.")
	}
}

// Confirm displays a yes/no prompt
func Confirm(prompt string, defaultYes bool) bool {
	if defaultYes {
		result := Prompt(fmt.Sprintf("%s [Y/n]: ", prompt))
		return result == "" || strings.ToLower(result) == "y" || strings.ToLower(result) == "yes"
	}
	result := Prompt(fmt.Sprintf("%s [y/N]: ", prompt))
	return strings.ToLower(result) == "y" || strings.ToLower(result) == "yes"
}

// PrintStep prints a numbered step header
func PrintStep(step int, title string) {
	fmt.Println()
	fmt.Printf("=== Step %d: %s ===\n", step, title)
	fmt.Println()
}

// PrintOK prints a green checkmark message
func PrintOK(msg string) {
	fmt.Printf("  [OK] %s\n", msg)
}

// PrintErr prints a red error message
func PrintErr(msg string) {
	fmt.Printf("  [ERROR] %s\n", msg)
}

// PrintWarn prints a yellow warning
func PrintWarn(msg string) {
	fmt.Printf("  [WARN] %s\n", msg)
}

// PrintInfo prints an info message
func PrintInfo(msg string) {
	fmt.Printf("  %s\n", msg)
}
