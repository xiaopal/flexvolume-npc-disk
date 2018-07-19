#! /bin/bash

export SCRIPT_DIR="$(cd "$(dirname ${BASH_SOURCE[0]})"; pwd)" \
	OPTION_FS_TYPE="kubernetes.io/fsType" \
	OPTION_VOLUME_NAME="kubernetes.io/pvOrVolumeName" \
	NPC_DISK_RESOURCE="${NPC_DISK_RESOURCE:-flexvolume.npc-disk/mount}" \
	NPC_DISK_RESOURCE_CAPACITY="$NPC_DISK_RESOURCE_CAPACITY"

[ ! -z "$NPC_API_CONFIG" ] && [ -f "$NPC_API_CONFIG" ] && {
	NPC_API_KEY="$(jq -r '.api_key//.app_key//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_KEY" ] && export NPC_API_KEY
	NPC_API_SECRET="$(jq -r '.api_secret//.app_secret//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_SECRET" ] && export NPC_API_SECRET
	NPC_API_ENDPOINT="$(jq -r '.api_endpoint//.endpoint//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_ENDPOINT" ] && export NPC_API_ENDPOINT
	NPC_API_REGION="$(jq -r '.api_region//.region//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_REGION" ] && export NPC_API_REGION
} 

jq() {
	"$SCRIPT_DIR/jq" "$@"
}

npc() {
	"$SCRIPT_DIR/npc-shell.sh" "$@"
}

log() {
	echo "$(date -Is) $*" >&2
}

node_instance(){
	local NODE="$1" PREFIX="npc.instance."
	kubectl get node "$NODE" -o json | jq --arg prefix "$PREFIX" '.metadata.labels//{} 
		| with_entries(select(.key|startswith($prefix))|.key|=.[($prefix|length):])'
}

do_init() {
	[ -x /usr/bin/curl ] || ( apt-get update && apt-get install -y curl ) >&2

	[ ! -z "$NPC_INSTANCE_ID" ] && {
		[ ! -z "$(node_instance "$HOSTNAME" | jq -r '.id//empty')" ] || {	
			local LABELS=("npc.instance.id=$NPC_INSTANCE_ID")
			[ ! -z "$NPC_INSTANCE_NAME" ] && LABELS=("${LABELS[@]}" "npc.instance.name=$NPC_INSTANCE_NAME")
			[ ! -z "$NPC_INSTANCE_ZONE" ] && LABELS=("${LABELS[@]}" "npc.instance.zone=$NPC_INSTANCE_ZONE")
			kubectl label node "$HOSTNAME" "${LABELS[@]}" >&2 
		}
	}
	
	[ ! -z "$NPC_DISK_RESOURCE_CAPACITY" ] && {
		[ ! -z "$(node_instance "$HOSTNAME" | jq -r '.id//empty')" ] || {
			jq -nc '{status:"Failure", message:"instance id not labeled"}'
			return 1
		}
		kubectl get node "$HOSTNAME" -o json | jq -e '.status.capacity[env.NPC_DISK_RESOURCE]' >/dev/null || (
			exec 100>"$SCRIPT_DIR/init.lock" && flock 100
			kubectl get node "$HOSTNAME" -o json | jq -e '.status.capacity[env.NPC_DISK_RESOURCE]' >/dev/null || {
				kubectl proxy -p 8888 & local KUBE_PROXY="$!" && sleep 1s
				curl -sS -H "Content-Type: application/json-patch+json" -X PATCH \
					-d "$(jq -nc '[{
						op: "add", 
						path: "/status/capacity/\(env.NPC_DISK_RESOURCE|gsub("/";"~1"))", 
						value: (env.NPC_DISK_RESOURCE_CAPACITY|tonumber) }]')" \
					"http://127.0.0.1:8888/api/v1/nodes/$HOSTNAME/status" | \
					log "PATCH $HOSTNAME $NPC_DISK_RESOURCE=$(jq -r '.status.capacity[env.NPC_DISK_RESOURCE]')"
				kill -TERM "$KUBE_PROXY" && wait
			}>&2 )
	}
	jq -nc '{status:"Success", capabilities: {attach: true}}'	
}

find_disk(){
	local DISK_NAME="$1" INSTANCE="$2" && [ ! -z "$DISK_NAME" ] || return 2
	local ZONE="$([ ! -z "$INSTANCE" ] && jq -r '.zone//empty' <<<"$INSTANCE")"
	(export LOOKUP_NAME="$DISK_NAME"
		npc api2 'json.DiskCxts[]|select(.DiskName == env.LOOKUP_NAME)|.DiskId//empty' \
			POST "/ncv?Version=2017-12-28&Action=ListDisk${ZONE:+&ZoneId=$ZONE}" \
			"$(jq -n '{ VolumeMatchPattern:{ volumeNameList:[env.LOOKUP_NAME], volumeScopeList:["NVM"] }}')") || return 2
}

find_or_create_disk(){
	local DISK_NAME="$1" OPTIONS="$2" INSTANCE="$3" 
	[ ! -z "$DISK_NAME" ] && [ ! -z "$OPTIONS" ] && [ ! -z "$INSTANCE" ] || return 2
	local DISK_ID="$(jq -r '.["id"]//empty'<<<"$OPTIONS")" && [ ! -z "$DISK_ID" ] || {
		DISK_ID="$(find_disk "$DISK_NAME" "$INSTANCE")" && [ ! -z "$DISK_ID" ] || {
			local DISK_CAPACITY="$(jq '.capacity//empty'<<<"$OPTIONS")"
			[ ! -z "$DISK_CAPACITY" ] || DISK_CAPACITY="$(kubectl get pv "$DISK_NAME" -o json | jq -r '.spec.capacity.storage//empty')"
			[ ! -z "$DISK_CAPACITY" ] || DISK_CAPACITY="10G"
			local CREATE_DISK="$(jq --arg name "$DISK_NAME" --arg capacity "$DISK_CAPACITY" --argjson instance "$INSTANCE" -c '{
				volume_name: $name,
				az_name: (.zone//.az//$instance.zone),
				type: (if .type then ({
						CloudSsd: "C_SSD",
						CloudHighPerformanceSsd: "NBS_SSD",
						CloudSas:"C_SAS"
					})[.type]//.type else .type end),
				format: "Raw",
				size: ($capacity|sub("[Gg]i?$"; "") | tonumber/10 | if . > floor then floor + 1 else . end * 10)
			}|with_entries(select(.value))'<<<"$OPTIONS")"
			DISK_ID="$(npc api 'json.id//empty' POST "/api/v1/cloud-volumes" "$CREATE_DISK")" && [ ! -z "$DISK_ID" ] || return 2
		}
	}
	wait_disk "$DISK_ID" || return 2
}

wait_disk(){
	local DISK_ID="$1" WAIT_STATUS WAIT_RESULT
	while true; do
		read -r WAIT_STATUS WAIT_RESULT < <(npc api 'json | select(.id) | .status as $status |
			if ["creating","mounting","unmounting"]|index($status) then "wait"
			elif [".create_fail"]|index($status) then "destroy"
			else "ok \(.name) \(.id) \(.volume_uuid) \(.service_name//"")"
			end' GET "/api/v1/cloud-volumes/$DISK_ID") && case "$WAIT_STATUS" in
			ok)
				log "disk: $WAIT_RESULT"
				echo "$WAIT_RESULT"; return 0
				;;
			wait)
				log "wait disk status"
				sleep 1s; continue
				;;
			destroy)
				log "destroy disk"
				npc api DELETE "/api/v1/cloud-volumes/$DISK_ID" >&2
				return 2
				;;
		esac
		log "failed to wait disk"
		return 2
	done
}

do_attach() {
	local OPTIONS="$1" NODE="$2" && [ ! -z "$NODE" ] || return 2
	local DISK_NAME="$(jq -r '.[env.OPTION_VOLUME_NAME]//empty'<<<"$OPTIONS")" NODE_INSTANCE="$(node_instance "$NODE")"
	[ ! -z "$DISK_NAME" ] && [ ! -z "$NODE_INSTANCE" ] || return 2
	local DISK_ID DISK_UUID ATTACHED_INSTANCE_ID
	read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID <<<"$(find_or_create_disk "$DISK_NAME" "$OPTIONS" "$NODE_INSTANCE")" && [ ! -z "$DISK_ID" ] || {
		jq -nc '{status:"Failure", message:"Failed to find/create disk"}'
		return 1
	}
	local INSTANCE_ID="$(jq -r '.id//empty'<<<"$NODE_INSTANCE")" && [ ! -z "$INSTANCE_ID" ] || {
		jq -nc '{status:"Failure", message:"instance id not labeled"}'
		return 1
	}
	[ -z "$ATTACHED_INSTANCE_ID" ] || [ "$ATTACHED_INSTANCE_ID" == "$INSTANCE_ID" ] || {
		jq -nc '{status:"Failure", message:"Disk already attached"}'
		return 1
	}
	[ -z "$ATTACHED_INSTANCE_ID" ] && {
		npc api2 GET "/nvm?Action=AttachDisk&Version=2017-12-14&InstanceId=$INSTANCE_ID&DiskId=$DISK_ID" >&2 || {
			jq -nc '{status:"Failure", message:"Failed to attach disk"}'
			return 1
		}
		read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID <<<"$(wait_disk "$DISK_ID")" && [ ! -z "$ATTACHED_INSTANCE_ID" ] || return 2
	}
	DEVICE="$DISK_NAME:$DISK_ID:${DISK_UUID,,}:$INSTANCE_ID" jq -nc '{status:"Success", device: env.DEVICE}'
}

do_detach() {
	local DISK_NAME="$1" NODE_INSTANCE="$(node_instance "$2")" && [ ! -z "$DISK_NAME" ] && [ ! -z "$NODE_INSTANCE" ] || return 2
	local INSTANCE_ID="$(jq -r '.id//empty'<<<"$NODE_INSTANCE")" ATTACHED_INSTANCE_ID && [ ! -z "$INSTANCE_ID" ] || {
		jq -nc '{status:"Failure", message:"instance id not labeled"}'
		return 1
	}
	local DISK_ID="$(find_disk "$DISK_NAME" "$NODE_INSTANCE")" && [ ! -z "$DISK_ID" ] && \
		read -r _ _ _ ATTACHED_INSTANCE_ID <<<"$(wait_disk "$DISK_ID")" && [ "$ATTACHED_INSTANCE_ID" == "$INSTANCE_ID" ] && {
			npc api2 GET "/nvm?Action=DetachDisk&Version=2017-12-14&InstanceId=$ATTACHED_INSTANCE_ID&DiskId=$DISK_ID" >&2 || {
				jq -nc '{status:"Failure", message:"Failed to detach disk"}'
				return 1
			}
		}
	jq -nc '{status:"Success"}'
}

do_waitforattach() {
	local DEVICE="$1" OPTIONS="$2"
	DEVICE="$DEVICE" jq -nc '{status:"Success", device: env.DEVICE}'
}

do_isattached() {
	local OPTIONS="$1" NODE="$2"
	jq -nc '{status:"Success", attached: true}'
}

do_mountdevice() {
	local MOUNTPATH="$1" DEVICE="$2" OPTIONS="$3" DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID
	IFS=':' read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID<<<"$DEVICE" && [ ! -z "$DISK_UUID" ] || return 2
	mountpoint -q "$MOUNTPATH" || {
		local NAME UUID FSTYPE MOUNTPOINT SERIAL \
			FOUND_DEVICE FOUND_FSTYPE FOUND_MNT
		while IFS=',' read -r _ NAME UUID FSTYPE MOUNTPOINT; do
			[ ! -z "$MOUNTPOINT" ] && {
				[ "$MOUNTPOINT" == "$MOUNTPATH" ] && FOUND_MNT="$NAME" && break
				continue
			}
			[ ! -z "$FSTYPE" ] && {
				[ "${UUID,,}" == "${DISK_UUID}" ] && FOUND_FSTYPE="$FSTYPE" && break
				continue
			}
			SERIAL="$(udevadm info -q property -n "/dev/$NAME" | sed -n 's/^ID_SERIAL=\(.*\)/\1/p')" && [ ! -z "$SERIAL" ] && {
				[ "${SERIAL,,}" == "${DISK_UUID:0:20}" ] && FOUND_DEVICE="/dev/$NAME" && break
			}
		done < <(lsblk -o 'TYPE,NAME,UUID,FSTYPE,MOUNTPOINT' -bdsrn | tr ' ' ',' | grep '^disk,')
		[ ! -z "$FOUND_MNT" ] || {
			[ ! -z "$FOUND_FSTYPE" ] || {
				[ ! -z "$FOUND_DEVICE" ] || {
					jq -nc '{status:"Failure", message:"device not found"}'
					return 1
				}
				FOUND_FSTYPE="$(jq -r '.[env.OPTION_FS_TYPE]//empty'<<<"$OPTIONS")"
				mkfs -t "${FOUND_FSTYPE:-ext4}" -U "$DISK_UUID" "$FOUND_DEVICE" >&2 || {
					jq -nc '{status:"Failure", message:"failed to mkfs"}'
					return 1
				}
			}
			mkdir -p "$MOUNTPATH" >&2 && mount -t "${FOUND_FSTYPE:-ext4}" "UUID=$DISK_UUID" "$MOUNTPATH" >&2 || {
				jq -nc '{status:"Failure", message:"failed to mount device"}'
				return 1
			}
		}
	}
	jq -nc '{status:"Success"}'
}

do_unmountdevice() {
	local MOUNTPATH="$1"
	! mountpoint -q "$MOUNTPATH" || umount "${MOUNTPATH}" >&2 || {
		jq -nc '{status:"Failure", message:"failed to mount device"}'
		return 1
	}
	rm -fr "${MOUNTPATH}"
	jq -nc '{status:"Success"}'
}

{
	log "$@"
	if ACTION="do_$1" && shift && declare -F "$ACTION" >/dev/null; then
		"$ACTION" "$@" || {
			case "$?" in
			1)
				:
				;;
			*)
				jq -nc '{status:"Failure", message:"Something wrong"}'
				;;
			esac
			exit 1
		}
	else
		jq -nc '{status:"Not supported"}'
		exit 1
	fi
} 2> >( if [ ! -z "$NPC_DISK_SYSLOG" ]; then
		systemd-cat -t "$NPC_DISK_SYSLOG" &>/dev/null
	else
		cat &>>${NPC_DISK_LOG:-/dev/null}
	fi )
