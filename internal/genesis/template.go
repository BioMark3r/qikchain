package genesis

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

var placeholderRE = regexp.MustCompile(`\{\{([A-Z0-9_]+)\}\}`)

func LoadTemplate(path string) (map[string]any, error) {
	return loadJSONFile(path)
}

func loadJSONFile(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return out, nil
}

func ApplyPlaceholders(doc map[string]any, values map[string]string, strict bool) error {
	resolved, unresolved, err := walkReplace(doc, values)
	if err != nil {
		return err
	}
	_ = resolved
	if strict && len(unresolved) > 0 {
		sort.Strings(unresolved)
		return fmt.Errorf("unresolved placeholders: %s", strings.Join(unresolved, ", "))
	}
	return nil
}

func walkReplace(node any, values map[string]string) (any, []string, error) {
	unresolved := make([]string, 0)
	switch t := node.(type) {
	case map[string]any:
		for k, v := range t {
			rv, u, err := walkReplace(v, values)
			if err != nil {
				return nil, nil, err
			}
			t[k] = rv
			unresolved = append(unresolved, u...)
		}
		return t, unresolved, nil
	case []any:
		for i, v := range t {
			rv, u, err := walkReplace(v, values)
			if err != nil {
				return nil, nil, err
			}
			t[i] = rv
			unresolved = append(unresolved, u...)
		}
		return t, unresolved, nil
	case string:
		matches := placeholderRE.FindAllStringSubmatch(t, -1)
		if len(matches) == 0 {
			return t, unresolved, nil
		}
		if len(matches) == 1 && matches[0][0] == t {
			key := matches[0][1]
			val, ok := values[key]
			if !ok {
				return t, []string{key}, nil
			}
			var typed any
			if err := json.Unmarshal([]byte(val), &typed); err == nil {
				return typed, nil, nil
			}
			return val, nil, nil
		}
		updated := t
		for _, m := range matches {
			key := m[1]
			val, ok := values[key]
			if !ok {
				unresolved = append(unresolved, key)
				continue
			}
			updated = strings.ReplaceAll(updated, m[0], val)
		}
		return updated, unresolved, nil
	default:
		return node, unresolved, nil
	}
}

func DeepMerge(base, overlay map[string]any) map[string]any {
	out := cloneMap(base)
	for k, v := range overlay {
		if bv, ok := out[k]; ok {
			bm, bok := bv.(map[string]any)
			om, ook := v.(map[string]any)
			if bok && ook {
				out[k] = DeepMerge(bm, om)
				continue
			}
		}
		out[k] = cloneAny(v)
	}
	return out
}

func cloneMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = cloneAny(v)
	}
	return out
}

func cloneAny(v any) any {
	switch t := v.(type) {
	case map[string]any:
		return cloneMap(t)
	case []any:
		arr := make([]any, len(t))
		for i := range t {
			arr[i] = cloneAny(t[i])
		}
		return arr
	default:
		return t
	}
}

func MarshalCanonical(v any) ([]byte, error) {
	buf := &bytes.Buffer{}
	if err := writeCanonical(buf, v, "", ""); err != nil {
		return nil, err
	}
	buf.WriteByte('\n')
	return buf.Bytes(), nil
}

func MarshalCanonicalIndented(v any) ([]byte, error) {
	buf := &bytes.Buffer{}
	if err := writeCanonical(buf, v, "", "  "); err != nil {
		return nil, err
	}
	buf.WriteByte('\n')
	return buf.Bytes(), nil
}

func writeCanonical(buf *bytes.Buffer, v any, currentIndent, step string) error {
	switch t := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		buf.WriteByte('{')
		if len(keys) > 0 && step != "" {
			buf.WriteByte('\n')
		}
		for i, k := range keys {
			if step != "" {
				buf.WriteString(currentIndent + step)
			}
			keyBytes, _ := json.Marshal(k)
			buf.Write(keyBytes)
			buf.WriteByte(':')
			if step != "" {
				buf.WriteByte(' ')
			}
			if err := writeCanonical(buf, t[k], currentIndent+step, step); err != nil {
				return err
			}
			if i < len(keys)-1 {
				buf.WriteByte(',')
			}
			if step != "" {
				buf.WriteByte('\n')
			}
		}
		if len(keys) > 0 && step != "" {
			buf.WriteString(currentIndent)
		}
		buf.WriteByte('}')
		return nil
	case []any:
		buf.WriteByte('[')
		for i, it := range t {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeCanonical(buf, it, currentIndent, step); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
		return nil
	default:
		b, err := json.Marshal(t)
		if err != nil {
			return err
		}
		buf.Write(b)
		return nil
	}
}
