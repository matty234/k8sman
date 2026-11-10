# cert-manager plugin for k8sman

An example [k8sman plugin](../../../docs/PLUGINS.md) for
[cert-manager](https://cert-manager.io), written against the
`k8sman.dev/v1` schema.

- **Certificates:** Ready, Issuer and Expires (time left) columns; a
  Certificate section with expiry warnings, the secret and issuer as links,
  DNS names, private key settings and conditions; **Renew** and
  **cmctl status** actions (they run `cmctl` on your computer, in the dock).
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

The actions need [`cmctl`](https://cert-manager.io/docs/reference/cmctl/) on
your PATH. The first run asks you to allow the plugin; every run shows the
command first. They are hidden on read-only contexts.

Check it without a cluster: `k8sman-server plugin validate examples/plugins/cert-manager`.
