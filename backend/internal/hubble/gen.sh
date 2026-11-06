#!/bin/sh
# Regenerates pb/ from the vendored Hubble protos (see proto/README.md).
set -eu
cd "$(dirname "$0")"
mod=github.com/matty234/k8sman/backend/internal/hubble/pb
maps=""
for p in flow observer relay; do
	maps="$maps --go_opt=M$p/$p.proto=$mod/$p --go-grpc_opt=M$p/$p.proto=$mod/$p"
done
rm -rf pb
mkdir pb
# shellcheck disable=SC2086
protoc -I proto \
	--go_out=pb --go_opt=module=$mod \
	--go-grpc_out=pb --go-grpc_opt=module=$mod \
	$maps \
	flow/flow.proto observer/observer.proto relay/relay.proto
