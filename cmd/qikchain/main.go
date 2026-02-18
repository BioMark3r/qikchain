package main

import (
	"os"

	"github.com/BioMark3r/qikchain/cmd/qikchain/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:]))
}

