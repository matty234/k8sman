//go:build !windows

package server

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// userShell is the user's login shell, run as a login shell (-l) so PATH and
// the rest of their profile are set up even when the app was started from
// Finder or a desktop launcher with a minimal environment.
func userShell() (string, []string) {
	return pickShell(os.Getenv("SHELL"), passwdShell(), runtime.GOOS), []string{"-l"}
}

// pickShell prefers $SHELL, then the passwd entry, then the platform default.
func pickShell(env, passwd, goos string) string {
	for _, s := range []string{env, passwd} {
		if filepath.IsAbs(s) && isExecutable(s) {
			return s
		}
	}
	if goos == "darwin" {
		return "/bin/zsh"
	}
	for _, s := range []string{"/bin/bash", "/bin/sh"} {
		if isExecutable(s) {
			return s
		}
	}
	return "/bin/sh"
}

func isExecutable(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

// passwdShell reads the current user's shell from /etc/passwd (Linux; macOS
// keeps it in Directory Services, where $SHELL is reliably set).
func passwdShell() string {
	u, err := user.Current()
	if err != nil {
		return ""
	}
	f, err := os.Open("/etc/passwd")
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Split(sc.Text(), ":")
		if len(fields) >= 7 && fields[0] == u.Username {
			return fields[6]
		}
	}
	return ""
}

type unixShell struct {
	cmd  *exec.Cmd
	tty  *os.File
	done chan struct{}
	code int
	err  error
	once sync.Once
}

func startLocalShell(spec localShellSpec) (localShell, error) {
	cmd := exec.Command(spec.Shell, spec.Args...)
	cmd.Dir = spec.Dir
	cmd.Env = spec.Env
	var size *pty.Winsize
	if spec.Cols > 0 && spec.Rows > 0 {
		size = &pty.Winsize{Cols: spec.Cols, Rows: spec.Rows}
	}
	// pty.Start makes the shell a session leader with the terminal as its
	// controlling tty, so hanging up reaches its whole job tree.
	tty, err := pty.StartWithSize(cmd, size)
	if err != nil {
		return nil, err
	}
	s := &unixShell{cmd: cmd, tty: tty, done: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		s.code, s.err = exitCode(err)
		close(s.done)
	}()
	return s, nil
}

func exitCode(err error) (int, error) {
	if err == nil {
		return 0, nil
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal()), nil
		}
		return ee.ExitCode(), nil
	}
	return -1, err
}

func (s *unixShell) Read(p []byte) (int, error) {
	n, err := s.tty.Read(p)
	if err != nil && errors.Is(err, syscall.EIO) {
		err = os.ErrClosed // Linux reports EIO once the shell side closes
	}
	return n, err
}

func (s *unixShell) Write(p []byte) (int, error) { return s.tty.Write(p) }

func (s *unixShell) Resize(cols, rows uint16) error {
	return pty.Setsize(s.tty, &pty.Winsize{Cols: cols, Rows: rows})
}

func (s *unixShell) Wait() (int, error) {
	<-s.done
	return s.code, s.err
}

func (s *unixShell) Close() error {
	s.once.Do(func() {
		select {
		case <-s.done:
		default:
			// Hang up the session like closing a terminal window would.
			if pgid, err := syscall.Getpgid(s.cmd.Process.Pid); err == nil {
				_ = syscall.Kill(-pgid, syscall.SIGHUP)
			}
			select {
			case <-s.done:
			case <-time.After(2 * time.Second):
				_ = s.cmd.Process.Kill()
				<-s.done
			}
		}
		_ = s.tty.Close()
	})
	return nil
}
