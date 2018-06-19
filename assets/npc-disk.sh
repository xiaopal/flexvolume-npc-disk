#! /bin/bash

export SCRIPT_DIR="$(cd "$(dirname ${BASH_SOURCE[0]})"; pwd)" \
	OPTION_FS_TYPE="kubernetes.io/fsType" \
	OPTION_VOLUME_NAME="kubernetes.io/pvOrVolumeName"

[ ! -z "$NPC_API_CONFIG" ] && [ -f "$NPC_API_CONFIG" ] && {
	NPC_API_KEY="$(jq -r '.api_key//.app_key//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_KEY" ] && export NPC_API_KEY
	NPC_API_SECRET="$(jq -r '.api_secret//.app_secret//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_SECRET" ] && export NPC_API_SECRET
	NPC_API_ENDPOINT="$(jq -r '.api_endpoint//.endpoint//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_ENDPOINT" ] && export NPC_API_ENDPOINT
	NPC_API_REGION="$(jq -r '.api_region//.region//empty' "$NPC_API_CONFIG")" && [ ! -z "$NPC_API_REGION" ] && export NPC_API_REGION
} 

exec 2>>"${NPC_DISK_LOG:-/dev/null}"

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
	[ -x /usr/bin/curl ] || {
		apt-get update && apt-get install -y curl
	}
	jq -nc '{status:"Success", capabilities: {attach: true}}'	
}

do_getvolumename() {
	local VOLUME_NAME="$(jq -r '.[env.OPTION_VOLUME_NAME]//empty'<<<"$1")" && [ ! -z "$VOLUME_NAME" ] || return 2
	VOLUME_NAME="$VOLUME_NAME" jq -nc '{status:"Success", volumeName: env.VOLUME_NAME}'
}

find_or_create_disk(){
	local DISK_NAME="$1" OPTIONS="$2" INSTANCE="$3" DISK_ID 
	[ ! -z "$DISK_NAME" ] && [ ! -z "$OPTIONS" ] && [ ! -z "$INSTANCE" ] || return 2
	local DISK_ID="$(jq -r '.["id"]//empty'<<<"$OPTIONS")"
	[ ! -z "$DISK_ID" ] || {
		local ZONE="$(jq -r .zone <<<"$INSTANCE")"
		DISK_ID="$(export LOOKUP_NAME="$DISK_NAME"
			npc api2 'json.DiskCxts[]|select(.DiskName == env.LOOKUP_NAME)|.DiskId//empty' \
				POST "/ncv?Version=2017-12-28&Action=ListDisk${ZONE:+&ZoneId=$ZONE}" \
				"$(jq -n '{ VolumeMatchPattern:{ volumeNameList:[env.LOOKUP_NAME], volumeScopeList:["NVM"] }}')")"
		[ ! -z "$DISK_ID" ] || {
			local CREATE_DISK="$(jq --arg name "$DISK_NAME" --argjson instance "$INSTANCE" -c '{
				volume_name: $name,
				az_name: (.zone//.az//$instance.zone),
				type: (if .type then ({
						CloudSsd: "C_SSD",
						CloudHighPerformanceSsd: "NBS_SSD",
						CloudSas:"C_SAS"
					})[.type]//.type else .type end),
				format: "Raw",
				size: (.capacity//"10G"|sub("[Gg]$"; "") | tonumber/10 | if . > floor then floor + 1 else . end * 10)
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
	local VOLUME_NAME="$(jq -r '.[env.OPTION_VOLUME_NAME]//empty'<<<"$OPTIONS")" NODE_INSTANCE="$(node_instance "$NODE")"
	[ ! -z "$VOLUME_NAME" ] && [ ! -z "$NODE_INSTANCE" ] || return 2
	local DISK_NAME="$(jq -r '.["name"]//empty'<<<"$OPTIONS")" DISK_ID DISK_UUID ATTACHED_INSTANCE_ID
	[ ! -z "$DISK_NAME" ] || DISK_NAME="flexvol-$VOLUME_NAME"
	read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID <<<"$(find_or_create_disk "$DISK_NAME" "$OPTIONS" "$NODE_INSTANCE")" && [ ! -z "$DISK_ID" ] || {
		jq -nc '{status:"Failure", message:"Failed to create disk"}'
		return 1
	}
	local INSTANCE_ID="$(jq -r '.id'<<<"$NODE_INSTANCE")"
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
	local DEVICE="$1" NODE="$2" DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID
	IFS=':' read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID<<<"$DEVICE" && [ ! -z "$DISK_ID" ] || return 2
	read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID <<<"$(wait_disk "$DISK_ID")" && [ ! -z "$ATTACHED_INSTANCE_ID" ] && {
		npc api2 GET "/nvm?Action=DetachDisk&Version=2017-12-14&InstanceId=$ATTACHED_INSTANCE_ID&DiskId=$DISK_ID" >&2 || {
			jq -nc '{status:"Failure", message:"Failed to attach disk"}'
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
				[ ! -z "$FOUND_DEVICE" ] || return 2
				FOUND_FSTYPE="$(jq -r '.[env.OPTION_FS_TYPE]//"ext4"'<<<"$OPTIONS")"
				mkfs -t "$FOUND_FSTYPE" -U "$DISK_UUID" "$FOUND_DEVICE" >&2 || return 2
			}
			mkdir -p "$MOUNTPATH" >&2 && mount -t "$FOUND_FSTYPE" "UUID=$DISK_UUID" "$MOUNTPATH" >&2 || return 2
		}
	}
	jq -nc '{status:"Success"}'
}

do_unmountdevice() {
	local MOUNTPATH="$1" DEVICE="$2"
	mountpoint -q "$MOUNTPATH" && {
		umount ${MOUNTPATH} >&2 || return 2
	}
	jq -nc '{status:"Success"}'
}

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