package cobra

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const ShellCompRequestCmd = "__complete"

type Command struct {
	Use           string
	Short         string
	Long          string
	RunE          func(cmd *Command, args []string) error
	SilenceUsage  bool
	SilenceErrors bool

	parent          *Command
	subcommands     []*Command
	persistentFlags *FlagSet
}

type FlagSet struct {
	stringVars   map[string]*string
	durationVars map[string]*time.Duration
	boolVars     map[string]*bool
}

func newFlagSet() *FlagSet {
	return &FlagSet{
		stringVars:   map[string]*string{},
		durationVars: map[string]*time.Duration{},
		boolVars:     map[string]*bool{},
	}
}

func (f *FlagSet) StringVar(p *string, name, value, _ string) { *p = value; f.stringVars[name] = p }
func (f *FlagSet) DurationVar(p *time.Duration, name string, value time.Duration, _ string) {
	*p = value
	f.durationVars[name] = p
}
func (f *FlagSet) BoolVar(p *bool, name string, value bool, _ string) {
	*p = value
	f.boolVars[name] = p
}

func (c *Command) PersistentFlags() *FlagSet {
	if c.persistentFlags == nil {
		c.persistentFlags = newFlagSet()
	}
	return c.persistentFlags
}

func (c *Command) AddCommand(cmds ...*Command) {
	for _, sub := range cmds {
		sub.parent = c
		c.subcommands = append(c.subcommands, sub)
	}
}

func (c *Command) InitDefaultCompletionCmd() {
	for _, sub := range c.subcommands {
		if strings.Fields(sub.Use)[0] == "completion" {
			return
		}
	}
	c.AddCommand(&Command{Use: "completion", Short: "Generate completion script", RunE: func(cmd *Command, args []string) error { return nil }})
}

func (c *Command) Execute() error {
	args := os.Args[1:]
	return c.execute(args)
}

func (c *Command) execute(args []string) error {
	if err := c.applyPersistentFlags(args); err != nil {
		return err
	}

	remaining, err := stripFlags(args)
	if err != nil {
		return err
	}
	if len(remaining) == 0 {
		if c.RunE != nil {
			return c.RunE(c, nil)
		}
		return errors.New("unknown command")
	}

	next := remaining[0]
	for _, sub := range c.subcommands {
		if strings.Fields(sub.Use)[0] == next {
			return sub.execute(remaining[1:])
		}
	}

	if c.RunE != nil {
		return c.RunE(c, remaining)
	}
	return fmt.Errorf("unknown command %q", next)
}

func stripFlags(args []string) ([]string, error) {
	remaining := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			remaining = append(remaining, a)
			continue
		}
		if a == "--json" {
			continue
		}
		if strings.Contains(a, "=") {
			continue
		}
		if i+1 >= len(args) {
			return nil, fmt.Errorf("invalid argument %s", a)
		}
		i++
	}
	return remaining, nil
}

func (c *Command) applyPersistentFlags(args []string) error {
	root := c
	for root.parent != nil {
		root = root.parent
	}
	if root.persistentFlags == nil {
		return nil
	}

	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			continue
		}
		nameVal := strings.TrimPrefix(a, "--")
		name := nameVal
		value := ""
		hasValue := false
		if strings.Contains(nameVal, "=") {
			parts := strings.SplitN(nameVal, "=", 2)
			name = parts[0]
			value = parts[1]
			hasValue = true
		}

		if ptr, ok := root.persistentFlags.boolVars[name]; ok {
			if hasValue {
				b, err := strconv.ParseBool(value)
				if err != nil {
					return fmt.Errorf("invalid argument %s", a)
				}
				*ptr = b
			} else {
				*ptr = true
			}
			continue
		}

		if !hasValue {
			if i+1 >= len(args) {
				return fmt.Errorf("invalid argument --%s", name)
			}
			i++
			value = args[i]
		}

		if ptr, ok := root.persistentFlags.stringVars[name]; ok {
			*ptr = value
			continue
		}
		if ptr, ok := root.persistentFlags.durationVars[name]; ok {
			d, err := time.ParseDuration(value)
			if err != nil {
				return fmt.Errorf("invalid argument --%s", name)
			}
			*ptr = d
			continue
		}

		return fmt.Errorf("unknown flag: --%s", name)
	}
	return nil
}
