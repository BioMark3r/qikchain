package cli

import "github.com/spf13/cobra"

func newBlockCmd(cfg *Config) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "block",
		Short: "Block-related commands",
	}

	cmd.AddCommand(newBlockHeadCmd(cfg))
	return cmd
}
