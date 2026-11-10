// Package k8scel holds the Kubernetes CEL libraries plugins use: Lists,
// Regex, URLs and Quantity.
//
// They are copied from k8s.io/apiserver v0.33.3 (pkg/cel/library and the
// Quantity and URL types of pkg/cel), Copyright The Kubernetes Authors,
// licensed under the Apache License, Version 2.0 (see the header of each
// file). Changes: the package name, the Quantity and URL types moved into
// this package, and Quantity() renamed QuantityLib() (Quantity is the type).
// Copying them rather than importing k8s.io/apiserver/pkg/cel/library
// keeps most of the apiserver module out of the backend binary, and pins
// the library versions in the app (docs/PLUGINS.md §5).
package k8scel
