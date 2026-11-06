# Vendored Hubble protos

`flow/flow.proto`, `observer/observer.proto` and `relay/relay.proto` are
copied unchanged from Cilium v1.18.7 (`api/v1/`): Apache-2.0, Copyright
Authors of Hubble. Only these three files are vendored, so the backend
doesn't depend on the `github.com/cilium/cilium` Go module.

The Go code in `../pb` is generated from them by `../gen.sh`. It needs
`protoc` plus protoc-gen-go v1.36.5 and protoc-gen-go-grpc v1.5.1 on PATH
(the versions that match go.mod's protobuf and gRPC):

    go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.5
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
    backend/internal/hubble/gen.sh

To update, copy the three files from a newer Cilium tag and regenerate.
The protocol is backward compatible, so older relays keep working.
