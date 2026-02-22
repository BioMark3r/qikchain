package edge

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var desiredForks = []string{
	"homestead",
	"byzantium",
	"constantinople",
	"petersburg",
	"istanbul",
	"london",
	"eip150",
	"eip155",
	"eip158",
	"quorumCalcAlignment",
	"txHashWithType",
	"londonFix",
}

func DesiredForks() []string {
	return append([]string(nil), desiredForks...)
}

func DetectSupportedForks(repoRoot string) ([]string, string) {
	srcRoot := filepath.Join(repoRoot, "third_party", "polygon-edge")
	if st, err := os.Stat(srcRoot); err == nil && st.IsDir() {
		if forks := detectFromPath(srcRoot); len(forks) > 0 {
			return forks, srcRoot
		}
	}

	binPath := filepath.Join(repoRoot, "bin", "polygon-edge")
	if st, err := os.Stat(binPath); err == nil && !st.IsDir() {
		if forks := detectFromBinary(binPath); len(forks) > 0 {
			return forks, binPath
		}
	}

	fallback := []string{"homestead", "byzantium", "constantinople", "petersburg", "istanbul"}
	return fallback, "fallback"
}

func FilterSupportedForks(desired, supported []string) []string {
	supportedSet := make(map[string]struct{}, len(supported))
	for _, k := range supported {
		supportedSet[k] = struct{}{}
	}
	out := make([]string, 0, len(desired))
	for _, k := range desired {
		if _, ok := supportedSet[k]; ok {
			out = append(out, k)
		}
	}
	return out
}

func detectFromPath(root string) []string {
	present := map[string]bool{}
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		s := string(b)
		for _, fork := range desiredForks {
			if strings.Contains(s, fmt.Sprintf("\"%s\"", fork)) {
				present[fork] = true
			}
		}
		return nil
	})
	return sortedForks(present)
}

func detectFromBinary(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	s := string(b)
	present := map[string]bool{}
	for _, fork := range desiredForks {
		if strings.Contains(s, fork) {
			present[fork] = true
		}
	}
	return sortedForks(present)
}

func sortedForks(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k, ok := range set {
		if ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}
