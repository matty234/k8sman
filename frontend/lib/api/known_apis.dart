/// The Kubernetes apiVersions the UI writes itself: built-in templates in
/// the create editor and the RBAC objects the Access view builds.
///
/// To bump an API version, edit it here. Everything else the UI shows or
/// edits takes its apiVersion from the object or from discovery
/// (AppState.types, ResourceType.apiVersion), so it follows the cluster.
/// The backend's registry, with each group's version preference (newest
/// first), is backend/internal/kapi/kapi.go.
library;

const coreApiVersion = 'v1';
const appsApiVersion = 'apps/v1';
const batchApiVersion = 'batch/v1';
const networkingApiVersion = 'networking.k8s.io/v1';
const rbacApiVersion = 'rbac.authorization.k8s.io/v1';
