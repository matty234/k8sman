# cert-manager plugin for k8sman

An example [k8sman plugin](../../../docs/PLUGINS.md) for
[cert-manager](https://cert-manager.io), written against the
`k8sman.dev/v1` schema ([`schema/plugin.v1.json`](../../../schema/plugin.v1.json)).

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

## Try it

1. Settings ▸ Integrations ▸ Plugins ▸ turn on **Developer mode**.
2. **Load plugin folder…** and choose this folder.
3. Open Certificates on a cluster with cert-manager. Edit `plugin.yaml` and
   save to see changes live.

The first action asks you to allow the plugin (it reads Certificates,
CertificateRequests, Issuers, ClusterIssuers and Secrets' names and keys;
queries Prometheus; runs `cmctl`; changes Certificates). Every run asks
first. Actions are hidden on read-only contexts. The shell actions need
[`cmctl`](https://cert-manager.io/docs/reference/cmctl/) on your PATH; the
Expiry (Prometheus) field needs the Prometheus integration and
cert-manager's metrics.

## Without a cluster

```sh
k8sman-server plugin validate examples/plugins/cert-manager
k8sman-server plugin test examples/plugins/cert-manager        # compare with fixtures/__snapshots__
k8sman-server plugin render examples/plugins/cert-manager \
  examples/plugins/cert-manager/fixtures/certificate-expiring.yaml
```

`fixtures/` holds three objects with what their related lookups see
(`fixtures/test.yaml` fixes the time, the context and a metric answer);
`plugin test --update` rewrites the snapshots after a change, for review.
