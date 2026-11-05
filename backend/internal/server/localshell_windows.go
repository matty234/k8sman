//go:build windows

package server

// Local shells on Windows need ConPTY; until then the endpoint reports
// errLocalShellUnsupported and the UI disables the button.

func userShell() (string, []string) { return "powershell.exe", nil }

func startLocalShell(localShellSpec) (localShell, error) { return nil, errLocalShellUnsupported }
