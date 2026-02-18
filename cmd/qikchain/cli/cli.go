package cli

import (
	"flag"
	"fmt"
	"os"
)

func Run(args []string) int {
	fs := flag.NewFlagSet("qikchain", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	help := fs.Bool("h", false, "help")
	fs.BoolVar(help, "help", false, "help")

	if err := fs.Parse(args); err != nil {
		// flag package already printed an error
		return 2
	}
	if *help {
		fmt.Println("qikchain (WIP)")
		fmt.Println("Usage:")
		fmt.Println("  qikchain --help")
		fmt.Println("  qikchain status --rpc http://127.0.0.1:8545   (TODO)")
		return 0
	}

	rest := fs.Args()
	if len(rest) == 0 {
		fmt.Println("qikchain: no command (try --help)")
		return 2
	}

	switch rest[0] {
	case "status":
		fmt.Println("qikchain status: TODO (wire to RPC)")
		return 0
	case "block":
		fmt.Println("qikchain block: TODO (wire to RPC)")
		return 0
	default:
		fmt.Fprintf(os.Stderr, "qikchain: unknown command %q (try --help)\n", rest[0])
		return 2
	}
}

