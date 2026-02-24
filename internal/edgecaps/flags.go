package edgecaps

import "regexp"

func DetectFlags(help string, names []string) map[string]bool {
	out := make(map[string]bool, len(names))
	for _, name := range names {
		out[name] = HasFlag(help, name)
	}
	return out
}

func HasFlag(help, name string) bool {
	re := regexp.MustCompile(`(^|[^[:alnum:]-])--` + regexp.QuoteMeta(name) + `([^[:alnum:]-]|$)`)
	return re.FindStringIndex(help) != nil
}
