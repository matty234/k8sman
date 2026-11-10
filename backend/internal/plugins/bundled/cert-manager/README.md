# cert-manager (bundled plugin)

[cert-manager](https://cert-manager.io) in k8sman, written as a
[plugin](../../../../../docs/PLUGINS.md#bundled-plugins) and compiled into
the backend. It is on by default where the cluster serves `cert-manager.io`
kinds, and turned off in **Settings ▸ Integrations ▸ cert-manager**.
A short, commented version is the teaching example in
[`examples/plugins/cert-manager`](../../../../../examples/plugins/cert-manager).

What it adds:

- **Certificates:** Ready, Issuer and Expires (time left) columns; a
  Certificate section with expiry warnings, the secret and issuer as links,
  the issuer's own status and the expiry Prometheus reports; the
  certificate's **Secret** (name, type, keys: never its values) and its
  **CertificateRequests**, both read as related objects; DNS names, private
  key settings and conditions.
- **Actions on Certificates:** **Renew** and **cmctl status** run `cmctl`
  on your computer, in the dock; **Set renewal time…** and **Private key
  rotation…** change the Certificate (a form, then a dry run showing the
  change, then your confirmation).
- **Alerts:** Certificates expired, expiring within 14 days, or not ready;
  Issuers and ClusterIssuers not ready. They show on the Overview (under
  Plugins) and in the dock's Issues tab.
- **CertificateRequests:** Approved and Ready columns; issuer, requester,
  owner links and conditions.
- **Issuers and ClusterIssuers:** Type and Server columns; ACME, CA and
  Vault details and the ACME solvers.
- A **cert-manager** section in the sidebar, with icons for its kinds.

## Trust

No consent prompt (it is bundled), otherwise like any plugin: it reads
Certificates, CertificateRequests, Issuers, ClusterIssuers and Secrets'
names and keys, queries Prometheus, runs `cmctl` and changes Certificates
only through the action path. Every `cmctl` run asks first, showing the
command; every patch shows a dry run and asks. Actions are hidden on
read-only contexts. The shell actions need
[`cmctl`](https://cert-manager.io/docs/reference/cmctl/) on your PATH (the
dock says so when it is missing); the Expiry (Prometheus) field needs the
Prometheus integration and cert-manager's metrics.

## Try changes

Settings ▸ Integrations ▸ Plugins ▸ turn on **Developer mode**, **Load
plugin folder…** and choose this folder: it overrides the bundled copy
while loaded, with hot reload.

## Without a cluster

```sh
k8sman-server plugin validate backend/internal/plugins/bundled/cert-manager
k8sman-server plugin test backend/internal/plugins/bundled/cert-manager        # compare with fixtures/__snapshots__
k8sman-server plugin render backend/internal/plugins/bundled/cert-manager \
  backend/internal/plugins/bundled/cert-manager/fixtures/certificate-expiring.yaml
```

`fixtures/` holds three objects with what their related lookups see
(`fixtures/test.yaml` fixes the time, the context and a metric answer);
`plugin test --update` rewrites the snapshots after a change, for review.
