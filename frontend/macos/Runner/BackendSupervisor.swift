import Cocoa
import Darwin

/// Runs the embedded Go backend (`Contents/MacOS/k8sman-server`) and keeps it
/// alive.
///
/// - Spawned with `--addr 127.0.0.1:0`; the port is learned from the
///   `K8SMAN_LISTENING <addr>` line on stdout.
/// - Spawned with the user's login-shell environment, so kubeconfig exec
///   credential plugins (aws, gke-gcloud-auth-plugin, kubelogin, …) are on PATH.
/// - Its stdin is a pipe held by this process and it runs with
///   `--exit-on-stdin-eof`, so it exits even if the app is killed.
/// - On quit it gets SIGTERM (it stops port-forwards), then SIGKILL after 3s.
/// - If it crashes it is restarted with exponential backoff; after
///   `maxQuickFailures` failed starts in a row it stays down until `restart()`.
final class BackendSupervisor {
  static let shared = BackendSupervisor()

  enum State: String {
    case idle, starting, running, restarting, failed, stopped
  }

  /// Called on the main thread whenever the status changes.
  var onChange: (([String: Any]) -> Void)?

  private let queue = DispatchQueue(label: "dev.k8sman.backend")
  private var process: Process?
  private var stdinPipe: Pipe?
  private var state: State = .idle
  private var url: String?
  private var lastError: String?
  private var logTail: [String] = []
  private var restarts = 0
  private var consecutiveFailures = 0
  private var startedAt = Date()
  private var generation = 0
  private var stopping = false
  private var loginEnv: [String: String]?
  private var stdoutBuffer = Data()

  private let maxLogLines = 200
  private let maxQuickFailures = 5
  private let startupTimeout: TimeInterval = 30

  /// Resolve the login environment early (it can take a moment).
  func prewarm() {
    queue.async { _ = self.environment() }
  }

  /// Start the backend if it isn't running yet.
  func start() {
    queue.async {
      switch self.state {
      case .idle, .failed, .stopped: self.launch()
      default: self.publish()
      }
    }
  }

  /// Kill any running backend and start a fresh one now.
  func restart() {
    queue.async {
      self.consecutiveFailures = 0
      self.generation += 1
      if let p = self.process, p.isRunning {
        self.stopping = true
        p.terminate()
        self.waitForExit(p, timeout: 3)
        self.stopping = false
      }
      self.process = nil
      self.launch()
    }
  }

  /// Current status snapshot (safe from any thread).
  func status() -> [String: Any] {
    queue.sync { snapshot() }
  }

  /// SIGTERM the backend and wait briefly. Called from applicationWillTerminate.
  func stop() {
    queue.sync {
      stopping = true
      generation += 1
      guard let p = process, p.isRunning else { return }
      p.terminate()
      waitForExit(p, timeout: 3)
      if p.isRunning { kill(p.processIdentifier, SIGKILL) }
      state = .stopped
    }
  }

  // MARK: - process management (on `queue`)

  private func snapshot() -> [String: Any] {
    var s: [String: Any] = [
      "state": state.rawValue,
      "restarts": restarts,
      "log": logTail.joined(separator: "\n"),
    ]
    if let url = url { s["url"] = url }
    if let e = lastError { s["error"] = e }
    if let p = process, p.isRunning { s["pid"] = Int(p.processIdentifier) }
    return s
  }

  private func publish() {
    let s = snapshot()
    DispatchQueue.main.async { self.onChange?(s) }
  }

  private func appendLog(_ text: String) {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      logTail.append(String(line))
    }
    if logTail.count > maxLogLines { logTail.removeFirst(logTail.count - maxLogLines) }
  }

  private func launch() {
    generation += 1
    let gen = generation
    stopping = false
    url = nil
    stdoutBuffer = Data()
    guard let binary = Bundle.main.url(forAuxiliaryExecutable: "k8sman-server") else {
      state = .failed
      lastError = "The backend binary (k8sman-server) is missing from the app bundle."
      publish()
      return
    }
    state = restarts > 0 || consecutiveFailures > 0 ? .restarting : .starting
    lastError = nil
    publish()

    let p = Process()
    p.executableURL = binary
    var args = ["--addr", "127.0.0.1:0", "--exit-on-stdin-eof"]
    // Power users: `defaults write dev.k8sman.app BackendArgs -array --read-only`
    args += UserDefaults.standard.stringArray(forKey: "BackendArgs") ?? []
    p.arguments = args
    p.environment = environment()
    p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = errPipe

    outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty else { h.readabilityHandler = nil; return }
      self?.queue.async { self?.handleStdout(data, gen: gen) }
    }
    errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty else { h.readabilityHandler = nil; return }
      self?.queue.async {
        guard let self = self else { return }
        self.appendLog(String(decoding: data, as: UTF8.self))
        // Only push log updates while not healthy, to keep the UI quiet.
        if self.state != .running && gen == self.generation { self.publish() }
      }
    }
    p.terminationHandler = { [weak self] proc in
      self?.queue.async { self?.handleExit(proc, gen: gen) }
    }

    do {
      try p.run()
    } catch {
      state = .failed
      lastError = "Could not start the backend: \(error.localizedDescription)"
      publish()
      return
    }
    process = p
    stdinPipe = inPipe
    startedAt = Date()

    queue.asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
      guard let self = self, gen == self.generation, self.url == nil, let p = self.process, p.isRunning else { return }
      self.appendLog("k8sman: backend did not report a listening address within \(Int(self.startupTimeout))s")
      p.terminate()
    }
  }

  private func handleStdout(_ data: Data, gen: Int) {
    guard gen == generation else { return }
    stdoutBuffer.append(data)
    while let nl = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
      let line = String(decoding: stdoutBuffer[stdoutBuffer.startIndex..<nl], as: UTF8.self)
      stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
      if line.hasPrefix("K8SMAN_LISTENING ") {
        let addr = line.dropFirst("K8SMAN_LISTENING ".count).trimmingCharacters(in: .whitespaces)
        url = "http://\(addr)"
        state = .running
        lastError = nil
        publish()
      } else {
        appendLog(line)
      }
    }
  }

  private func handleExit(_ proc: Process, gen: Int) {
    guard gen == generation else { return }
    process = nil
    stdinPipe = nil
    url = nil
    if stopping {
      state = .stopped
      publish()
      return
    }
    let reason = proc.terminationReason == .uncaughtSignal
      ? "killed by signal \(proc.terminationStatus)"
      : "exited with status \(proc.terminationStatus)"
    lastError = "The backend \(reason)."
    // A backend that ran for a while gets a fresh failure budget.
    if Date().timeIntervalSince(startedAt) > 60 { consecutiveFailures = 0 }
    consecutiveFailures += 1
    if consecutiveFailures >= maxQuickFailures {
      state = .failed
      publish()
      return
    }
    restarts += 1
    state = .restarting
    publish()
    let delay = min(pow(2.0, Double(consecutiveFailures - 1)), 30)
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self = self, gen == self.generation, !self.stopping else { return }
      self.launch()
    }
  }

  private func waitForExit(_ p: Process, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
  }

  // MARK: - login environment

  /// The app's environment overlaid with the user's login-shell environment
  /// (GUI apps get a minimal PATH from launchd).
  private func environment() -> [String: String] {
    if loginEnv == nil { loginEnv = Self.resolveLoginEnvironment() ?? [:] }
    var env = ProcessInfo.processInfo.environment
    for (k, v) in loginEnv! where !Self.ignoredEnvKeys.contains(k) { env[k] = v }
    // Make common tool locations reachable even if the shell env failed.
    var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/google-cloud-sdk/bin"]
    where !path.contains(extra) && FileManager.default.fileExists(atPath: extra) {
      path.append(extra)
    }
    env["PATH"] = path.joined(separator: ":")
    return env
  }

  private static let ignoredEnvKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM", "PS1"]

  /// Runs `$SHELL -i -l -c env` (falling back to `-l -c`) with a timeout and
  /// parses its output. Markers fence the env dump from any shell banner.
  static func resolveLoginEnvironment() -> [String: String]? {
    let shell: String = {
      if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell { return String(cString: s) }
      return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()
    let start = "__K8SMAN_ENV_START__", end = "__K8SMAN_ENV_END__"
    let cmd = "printf '\(start)'; /usr/bin/env -0; printf '\(end)'"
    for flags in [["-i", "-l", "-c"], ["-l", "-c"]] {
      if let out = run(shell, flags + [cmd], timeout: 5),
         let s = out.range(of: start), let e = out.range(of: end, range: s.upperBound..<out.endIndex) {
        var env: [String: String] = [:]
        for entry in out[s.upperBound..<e.lowerBound].split(separator: "\0") {
          guard let eq = entry.firstIndex(of: "=") else { continue }
          env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        if !env.isEmpty { return env }
      }
    }
    NSLog("k8sman: could not resolve the login shell environment")
    return nil
  }

  private static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["K8SMAN_RESOLVING_SHELL_ENV"] = "1"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    var data = Data()
    let readDone = DispatchSemaphore(value: 0)
    do { try p.run() } catch { return nil }
    DispatchQueue.global().async {
      data = out.fileHandleForReading.readDataToEndOfFile()
      readDone.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {
      p.terminate()
      usleep(100_000)
      if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    // Background jobs started by shell rc files may hold the pipe open.
    if readDone.wait(timeout: .now() + 1) == .timedOut { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
