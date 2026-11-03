package overview

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// cronSchedule is a minimal standard 5-field cron schedule, enough to tell
// when a CronJob should next have run. It supports the syntax the CronJob
// controller accepts: lists, ranges, steps, `*`/`?`, month and weekday names,
// the @yearly/@monthly/@weekly/@daily/@hourly macros and a CRON_TZ= / TZ= prefix.
type cronSchedule struct {
	minute, hour, dom, month, dow uint64
	domStar, dowStar              bool
	loc                           *time.Location
}

var cronMacros = map[string]string{
	"@yearly":   "0 0 1 1 *",
	"@annually": "0 0 1 1 *",
	"@monthly":  "0 0 1 * *",
	"@weekly":   "0 0 * * 0",
	"@daily":    "0 0 * * *",
	"@midnight": "0 0 * * *",
	"@hourly":   "0 * * * *",
}

var monthNames = map[string]int{"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
var dowNames = map[string]int{"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}

// parseCron parses spec. timeZone (CronJob.spec.timeZone) overrides UTC; a
// CRON_TZ= prefix in spec overrides both.
func parseCron(spec, timeZone string) (*cronSchedule, error) {
	loc := time.UTC
	if timeZone != "" {
		l, err := time.LoadLocation(timeZone)
		if err != nil {
			return nil, fmt.Errorf("time zone %q: %w", timeZone, err)
		}
		loc = l
	}
	spec = strings.TrimSpace(spec)
	if strings.HasPrefix(spec, "CRON_TZ=") || strings.HasPrefix(spec, "TZ=") {
		i := strings.IndexByte(spec, ' ')
		if i < 0 {
			return nil, fmt.Errorf("missing schedule after time zone")
		}
		tz := spec[strings.IndexByte(spec, '=')+1 : i]
		l, err := time.LoadLocation(tz)
		if err != nil {
			return nil, fmt.Errorf("time zone %q: %w", tz, err)
		}
		loc = l
		spec = strings.TrimSpace(spec[i+1:])
	}
	if m, ok := cronMacros[strings.ToLower(spec)]; ok {
		spec = m
	}
	f := strings.Fields(spec)
	if len(f) != 5 {
		return nil, fmt.Errorf("expected 5 fields, got %d", len(f))
	}
	s := &cronSchedule{loc: loc}
	var err error
	if s.minute, err = parseCronField(f[0], 0, 59, nil); err != nil {
		return nil, err
	}
	if s.hour, err = parseCronField(f[1], 0, 23, nil); err != nil {
		return nil, err
	}
	if s.dom, err = parseCronField(f[2], 1, 31, nil); err != nil {
		return nil, err
	}
	if s.month, err = parseCronField(f[3], 1, 12, monthNames); err != nil {
		return nil, err
	}
	if s.dow, err = parseCronField(f[4], 0, 7, dowNames); err != nil {
		return nil, err
	}
	if s.dow&(1<<7) != 0 { // 7 = Sunday
		s.dow |= 1
	}
	s.domStar = f[2] == "*" || f[2] == "?"
	s.dowStar = f[4] == "*" || f[4] == "?"
	return s, nil
}

func parseCronField(field string, lo, hi int, names map[string]int) (uint64, error) {
	var bits uint64
	val := func(s string) (int, error) {
		if n, ok := names[strings.ToLower(s)]; ok {
			return n, nil
		}
		n, err := strconv.Atoi(s)
		if err != nil || n < lo || n > hi {
			return 0, fmt.Errorf("invalid value %q (want %d-%d)", s, lo, hi)
		}
		return n, nil
	}
	for _, part := range strings.Split(field, ",") {
		rng, step := part, 1
		if i := strings.IndexByte(part, '/'); i >= 0 {
			n, err := strconv.Atoi(part[i+1:])
			if err != nil || n <= 0 {
				return 0, fmt.Errorf("invalid step in %q", part)
			}
			rng, step = part[:i], n
		}
		start, end := lo, hi
		switch {
		case rng == "*" || rng == "?":
		case strings.Contains(rng, "-"):
			a, b, _ := strings.Cut(rng, "-")
			var err error
			if start, err = val(a); err != nil {
				return 0, err
			}
			if end, err = val(b); err != nil {
				return 0, err
			}
		default:
			v, err := val(rng)
			if err != nil {
				return 0, err
			}
			start = v
			if step == 1 {
				end = v
			}
		}
		if start > end {
			return 0, fmt.Errorf("invalid range %q", part)
		}
		for v := start; v <= end; v += step {
			bits |= 1 << uint(v)
		}
	}
	return bits, nil
}

func (s *cronSchedule) dayMatches(t time.Time) bool {
	domOK := s.dom&(1<<uint(t.Day())) != 0
	dowOK := s.dow&(1<<uint(t.Weekday())) != 0
	if s.domStar || s.dowStar {
		return domOK && dowOK
	}
	return domOK || dowOK
}

// next returns the first activation strictly after t, or the zero time if
// none is found within five years (e.g. "0 0 30 2 *").
func (s *cronSchedule) next(t time.Time) time.Time {
	t = t.In(s.loc).Truncate(time.Minute).Add(time.Minute)
	limit := t.AddDate(5, 0, 0)
	for t.Before(limit) {
		if s.month&(1<<uint(t.Month())) == 0 {
			t = time.Date(t.Year(), t.Month()+1, 1, 0, 0, 0, 0, s.loc)
			continue
		}
		if !s.dayMatches(t) {
			t = time.Date(t.Year(), t.Month(), t.Day()+1, 0, 0, 0, 0, s.loc)
			continue
		}
		if s.hour&(1<<uint(t.Hour())) == 0 {
			t = time.Date(t.Year(), t.Month(), t.Day(), t.Hour()+1, 0, 0, 0, s.loc)
			continue
		}
		if s.minute&(1<<uint(t.Minute())) == 0 {
			t = t.Add(time.Minute)
			continue
		}
		return t
	}
	return time.Time{}
}
