package main

import (
	"fmt"
	"os"

	"codeberg.org/CookieTyrant/alta-route10-controld/cmd"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "setup":
		cmd.Setup()
	case "uninstall":
		cmd.Uninstall()
	case "status":
		cmd.Status()
	case "help", "--help", "-h":
		printUsage()
	default:
		fmt.Printf("Unknown command: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("Alta Labs Route 10 + ControlD DNS Setup Tool")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  alta-controld setup      Interactive setup wizard")
	fmt.Println("  alta-controld status     Check current configuration status")
	fmt.Println("  alta-controld uninstall  Remove ControlD configuration")
	fmt.Println("  alta-controld help       Show this help message")
}
