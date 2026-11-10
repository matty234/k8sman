# cert-manager plugin example

A short, commented [k8sman plugin](../../../docs/PLUGINS.md) for
[cert-manager](https://cert-manager.io), meant for reading and copying. It
shows, in under 100 lines of [`plugin.yaml`](plugin.yaml):

- two columns on Certificates (Ready, and Expires as time left);
- a panel section with a badge, fields and a link to the Secret;
- an alert for certificates expiring within 14 days;
- a shell action, **cmctl status** (needs
  [`cmctl`](https://cert-manager.io/docs/reference/cmctl/) on your PATH;
  every run asks first, and it is hidden on read-only contexts);
- a sidebar section and an icon.

The full plugin (related objects, Prometheus metrics, renew and patch
actions with forms, Issuers and CertificateRequests) is bundled with the app:
[`backend/internal/plugins/bundled/cert-manager`](../../../backend/internal/plugins/bundled/cert-manager).

## Replacing the bundled plugin

This folder keeps the id `cert-manager`. Loaded in developer mode, it
replaces the bundled plugin while it is loaded (the documented override
path):

1. Settings ▸ Integrations ▸ Plugins ▸ turn on **Developer mode**.
2. **Load plugin folder…** and choose this folder (or start the backend with
   `--plugin-dev examples/plugins/cert-manager`).
3. Open Certificates on a cluster with cert-manager. Edit `plugin.yaml` and
   save to see changes live. Unload the folder to get the bundled plugin
   back.

## Without a cluster

```sh
k8sman-server plugin validate examples/plugins/cert-manager
k8sman-server plugin test examples/plugins/cert-manager        # compare with fixtures/__snapshots__
k8sman-server plugin render examples/plugins/cert-manager \
  examples/plugins/cert-manager/fixtures/certificate-expiring.yaml
```

`fixtures/` holds two Certificates (`fixtures/test.yaml` fixes the time and
the context); `plugin test --update` rewrites the snapshots after a change,
for review.
