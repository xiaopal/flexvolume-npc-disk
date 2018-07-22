#! /bin/bash

[ ! -z "$SCRIPT_DIR" ] || exit 2

jq() {
	"$SCRIPT_DIR/jq" "$@"
}

node_instance(){
	local NODE="$1" PREFIX="npc.instance."
	kubectl get node "$NODE" -o json | jq --arg prefix "$PREFIX" '.metadata.labels//{} 
		| with_entries(select(.key|startswith($prefix))|.key|=.[($prefix|length):])'
}

wait_for_port(){
	local WAIT_PORT="$1" WAIT_HOST="${2:-127.0.0.1}" WAIT_TIMEOUT="${3:-10}" WAIT_START="$SECONDS"
	while (( SECONDS - WAIT_START < WAIT_TIMEOUT )); do
		nc -z -w 1 "$WAIT_HOST" "$WAIT_PORT" &>/dev/null && return 0
		sleep 1s
	done
    return 1
}

[ ! -z "$NPC_INSTANCE_ID" ] && {
	[ ! -z "$(node_instance "$HOSTNAME" | jq -r '.id//empty')" ] || {	
		LABELS=("npc.instance.id=$NPC_INSTANCE_ID")
		[ ! -z "$NPC_INSTANCE_NAME" ] && LABELS=("${LABELS[@]}" "npc.instance.name=$NPC_INSTANCE_NAME")
		[ ! -z "$NPC_INSTANCE_ZONE" ] && LABELS=("${LABELS[@]}" "npc.instance.zone=$NPC_INSTANCE_ZONE")
		kubectl label node "$HOSTNAME" "${LABELS[@]}" >&2 || {
			jq -nc '{status:"Failure", message:"failed to label instance id to node"}'
			exit 1
		}
	}
}

[ ! -z "$NPC_DISK_RESOURCE_CAPACITY" ] && [ ! -z "$NPC_DISK_RESOURCE" ] && {
	[ ! -z "$(node_instance "$HOSTNAME" | jq -r '.id//empty')" ] || {
		jq -nc '{status:"Failure", message:"instance id not labeled"}'
		exit 1
	}

	patch_disk_resource() {
		local PROXY_PORT=8888 PROXY_PID CAPACITY_RESULT
		kubectl proxy -p "$PROXY_PORT" >&2 & 
		PROXY_PID="$!" && wait_for_port "$PROXY_PORT" && \
		curl -sS -H "Content-Type: application/json-patch+json" -X PATCH -d "$(jq -nc '[{
				op: "add", 
				path: "/status/capacity/\(env.NPC_DISK_RESOURCE|gsub("/";"~1"))", 
				value: (env.NPC_DISK_RESOURCE_CAPACITY|tonumber) }]')" \
			"http://127.0.0.1:$PROXY_PORT/api/v1/nodes/$HOSTNAME/status" | jq -r '.status.capacity[env.NPC_DISK_RESOURCE]//empty'
		kill -TERM "$PROXY_PID" >/dev/null
	}

	CAPACITY="$(kubectl get node "$HOSTNAME" -o json | jq -r '.status.capacity[env.NPC_DISK_RESOURCE]//empty')"
	[ "$NPC_DISK_RESOURCE_CAPACITY" == "$CAPACITY" ] || {
		exec 100>"$SCRIPT_DIR/init.lock" && flock 100; 
		CAPACITY="$(kubectl get node "$HOSTNAME" -o json | jq -r '.status.capacity[env.NPC_DISK_RESOURCE]//empty')"
		[ "$NPC_DISK_RESOURCE_CAPACITY" == "$CAPACITY" ] || [ "$NPC_DISK_RESOURCE_CAPACITY" == "$(patch_disk_resource)" ] || {
			jq -nc '{status:"Failure", message:"failed to patch disk resource to node"}'
			exit 1
		}
	}
}

jq -nc '{status:"Success", capabilities: {attach: true}}'