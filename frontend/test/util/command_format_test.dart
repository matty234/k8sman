import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/util/command_format.dart';

void main() {
  test('formatCommand: short stays on one line; long breaks by flag, script and chain', () {
    expect(formatCommand(['nginx', '-g', 'daemon off;']), "nginx -g 'daemon off;'");

    expect(
      formatCommand(['/app/server', 'serve', '--listen-address=0.0.0.0:8080', '--config', '/etc/app/config.yaml', '--log-level', 'debug', '--verbose', '--data-dir', '/var/lib/app']),
      '/app/server serve \\\n  --listen-address=0.0.0.0:8080 \\\n  --config /etc/app/config.yaml \\\n  --log-level debug \\\n  --verbose \\\n  --data-dir /var/lib/app',
    );

    final script = 'set -e\necho "starting up the service now"\nexec /app/server --port 8080 --config /etc/app/config.yaml';
    expect(formatCommand(['/bin/sh', '-ec', script]), "/bin/sh -ec '\n  set -e\n  echo \"starting up the service now\"\n  exec /app/server --port 8080 --config /etc/app/config.yaml\n'");

    expect(
      formatCommand(['sh', '-c', 'mkdir -p /data/cache && chown -R 1000:1000 /data && cp /defaults/app.conf /data/app.conf; exec /app/server']),
      "sh -c '\n  mkdir -p /data/cache &&\n  chown -R 1000:1000 /data &&\n  cp /defaults/app.conf /data/app.conf;\n  exec /app/server\n'",
    );
  });
}
