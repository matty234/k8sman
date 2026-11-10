package plugins

import (
	"strings"

	"gopkg.in/yaml.v3"
)

// exprPos maps a CEL source location (1-based line, 0-based column) of e
// into the file. YAML folds and unindents what it reads, so the
// expression's text is found line by line in the file.
func (d *decoder) exprPos(e Expr, line, col int) Pos {
	n := e.node
	if n == nil {
		return e.pos
	}
	off := 0
	for l := 1; l < line; l++ {
		i := strings.IndexByte(e.Src[off:], '\n')
		if i < 0 {
			break
		}
		off += i + 1
	}
	off = min(off+col, len(e.Src))
	if n.Style == yaml.LiteralStyle || n.Style == yaml.FoldedStyle {
		return d.walk(e.Src, off, n.Line+1, 0)
	}
	q := 0
	if n.Style == yaml.DoubleQuotedStyle || n.Style == yaml.SingleQuotedStyle {
		q = 1
	}
	return d.walk(e.Src, off, n.Line, n.Column-1+q)
}

// walk finds byte off of src in the file, starting at line (whose text
// starts at column first; later lines are unindented).
func (d *decoder) walk(src string, off, line, first int) Pos {
	k := 0
	for l := line; l <= len(d.lines); l++ {
		raw := d.lines[l-1]
		var text string
		var indent int
		if l == line && first > 0 {
			first = min(first, len(raw))
			text, indent = raw[first:], first
		} else {
			text = strings.TrimLeft(raw, " ")
			indent = len(raw) - len(text)
		}
		text = strings.TrimRight(text, " \r")
		if l == line && first > 0 {
			// The scalar's first line may end with its closing quote.
			text = strings.TrimRight(text, `"'`)
		}
		if text == "" {
			continue
		}
		i := strings.Index(src[k:], text)
		if i < 0 {
			// Escapes we can't follow: the offset on this line is the
			// best guess.
			if l == line {
				return Pos{File: d.file, Line: l, Col: indent + off + 1}
			}
			break
		}
		start := k + i
		if off < start+len(text) {
			return Pos{File: d.file, Line: l, Col: indent + max(0, off-start) + 1}
		}
		k = start + len(text)
	}
	return Pos{File: d.file, Line: line, Col: first + 1}
}
