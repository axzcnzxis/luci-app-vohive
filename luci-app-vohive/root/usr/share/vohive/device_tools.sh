#!/bin/sh

. /usr/share/vohive/lib.sh

ACTION="${1:-status}"
PORT="${2:-}"
TARGET="${3:-}"

DEFAULT_TIMEOUT_SECONDS=2

json_escape() {
	printf '%s' "$1" | tr -d '\r' | awk '
		{
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			if (NR > 1)
				printf "\\n"
			printf "%s", $0
		}
	'
}

fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$1")"
	exit 1
}

pkg_installed() {
	local manager

	manager="$(package_manager 2>/dev/null || true)"
	case "$manager" in
		opkg)
			opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed'
			;;
		apk)
			apk info -e "$1" >/dev/null 2>&1 ||
				apk list --installed "$1" 2>/dev/null | grep -q "^$1-"
			;;
		*)
			return 1
			;;
	esac
}

dep_value() {
	if pkg_installed "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

# Report the real state: a module can be present on disk without the package
# database knowing about it (manual copy, preinstalled firmware, side-loaded ipk).
serial_driver_state() {
	if pkg_installed kmod-usb-serial || module_file_present usbserial; then
		printf 'true'
	else
		printf 'false'
	fi
}

option_driver_state() {
	if pkg_installed kmod-usb-serial-option || module_file_present option; then
		printf 'true'
	else
		printf 'false'
	fi
}

# A module counts as available when its .ko exists for the running kernel or
# when it was linked into the kernel (some custom x86_64 builds build usbnet in
# instead of shipping it as a module).
module_available() {
	module_file_present "$1" && return 0
	grep -q "/$1\.ko" "/lib/modules/$(kernel_release)/modules.builtin" 2>/dev/null
}

qmi_driver_state() {
	if pkg_installed kmod-usb-net-qmi-wwan || module_available qmi_wwan; then
		printf 'true'
	else
		printf 'false'
	fi
}

mbim_driver_state() {
	if pkg_installed kmod-usb-net-cdc-mbim || module_available cdc_mbim; then
		printf 'true'
	else
		printf 'false'
	fi
}

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

has_timeout() {
	has_cmd timeout || busybox timeout 1 true >/dev/null 2>&1
}

run_timeout() {
	if has_cmd timeout; then
		timeout "$@"
	else
		busybox timeout "$@"
	fi
}

download_file() {
	local url="$1"
	local output="$2"

	if has_cmd curl; then
		curl -fL --connect-timeout 20 --retry 2 -o "$output" "$url" >/dev/null 2>&1
	elif has_cmd uclient-fetch; then
		uclient-fetch -q -O "$output" "$url" >/dev/null 2>&1
	elif has_cmd wget; then
		wget -q -O "$output" "$url" >/dev/null 2>&1
	else
		return 1
	fi
}

# Extract one field of one package stanza from an opkg/apk Packages index.
feed_package_field() {
	local index="$1"
	local package="$2"
	local field="$3"

	awk -v pkg="$package" -v field="$field" '
		BEGIN { RS = ""; FS = "\n" }
		{
			name = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^Package: /) {
					name = substr($i, 10)
					continue
				}
				if (name == pkg && $i ~ ("^" field ": ")) {
					print substr($i, length(field) + 3)
					exit
				}
			}
		}
	' "$index"
}

file_sha256() {
	has_cmd sha256sum || return 1
	sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

task_enabled() {
	[ -n "${VOHIVE_TASK_ID:-}" ] && [ -n "${VOHIVE_TASK_TYPE:-}" ] && [ -f /usr/share/vohive/task_lib.sh ]
}

task_progress() {
	local stage="$1"
	local message="$2"

	if task_enabled; then
		# shellcheck source=/usr/share/vohive/task_lib.sh
		. /usr/share/vohive/task_lib.sh
		task_log "$VOHIVE_TASK_ID" "$message"
		task_write_status "$VOHIVE_TASK_ID" "$VOHIVE_TASK_TYPE" "running" "$stage" "$message" "" 0 0 0 0
	fi
}

# Ordered by dependency: option depends on wwan, wwan depends on usbserial.
KMOD_SERIAL_PACKAGES="kmod-usb-serial kmod-usb-serial-wwan kmod-usb-serial-option"
# QMI backend: qmi_wwan depends on usbnet and cdc_wdm (kmod-usb-wdm).
KMOD_QMI_PACKAGES="kmod-usb-net kmod-usb-wdm kmod-usb-net-qmi-wwan"
# MBIM backend: cdc_mbim depends on cdc_ncm -> cdc_ether, plus cdc_wdm.
KMOD_MBIM_PACKAGES="kmod-usb-net kmod-usb-net-cdc-ether kmod-usb-wdm kmod-usb-net-cdc-ncm kmod-usb-net-cdc-mbim"

serial_modules_present() {
	module_available usbserial &&
		module_available usb_wwan &&
		module_available option
}

qmi_modules_present() {
	module_available qmi_wwan
}

mbim_modules_present() {
	module_available cdc_mbim &&
		module_available cdc_ncm &&
		module_available cdc_wdm
}

load_serial_modules() {
	modprobe usbserial 2>/dev/null || true
	modprobe usb_wwan 2>/dev/null || true
	modprobe option 2>/dev/null || true
	prepare_serial_driver
}

load_qmi_modules() {
	modprobe cdc_wdm 2>/dev/null || true
	modprobe qmi_wwan 2>/dev/null || true
}

load_mbim_modules() {
	modprobe cdc_wdm 2>/dev/null || true
	modprobe cdc_ncm 2>/dev/null || true
	modprobe cdc_mbim 2>/dev/null || true
}

bind_option_id() {
	local vendor="$1"
	local product="$2"
	local new_id="/sys/bus/usb-serial/drivers/option1/new_id"

	modprobe option 2>/dev/null || true
	[ -w "$new_id" ] || return 0
	printf '%s %s\n' "$vendor" "$product" > "$new_id" 2>/dev/null || true
}

prepare_serial_driver() {
	bind_option_id 2ca3 4006
	bind_option_id 2c7c 0125
	bind_option_id 2c7c 0124
}

serial_ports() {
	ls /dev/ttyUSB* 2>/dev/null | sort -V
}

control_devices() {
	ls /dev/cdc-wdm* 2>/dev/null | sort -V
}

first_control_device() {
	control_devices | head -n 1
}

cdc_wdm_state() {
	if module_available cdc_wdm || [ -n "$(first_control_device)" ]; then
		printf 'true'
	else
		printf 'false'
	fi
}

at_with_socat() {
	local port="$1"
	local command="$2"
	local timeout_seconds="${3:-$DEFAULT_TIMEOUT_SECONDS}"
	local tmp="/tmp/vohive/socat.$$"
	local input="/tmp/vohive/socat-in.$$"
	local pid elapsed limit

	mkdir -p /tmp/vohive
	limit=$((timeout_seconds + 1))
	printf '%s\r\n' "$command" > "$input"
	socat -T "$timeout_seconds" - "OPEN:$port,raw,echo=0,crnl" < "$input" > "$tmp" 2>&1 &
	pid="$!"
	elapsed=0
	while [ "$elapsed" -lt "$limit" ]; do
		if grep -Eq '(^|[[:space:]])(OK|ERROR)|\+CME ERROR:' "$tmp" 2>/dev/null; then
			break
		fi
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
		elapsed=$((elapsed + 1))
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	cat "$tmp" 2>/dev/null | sed '/socat\[[0-9][0-9]*\] W exiting on signal 15/d' || true
	rm -f "$tmp" "$input"
}

at_with_shell() {
	local port="$1"
	local command="$2"
	local timeout_seconds="${3:-$DEFAULT_TIMEOUT_SECONDS}"
	local tmp="/tmp/vohive/at.$$"

	mkdir -p /tmp/vohive
	stty -F "$port" 115200 raw -echo -echoe -echok 2>/dev/null || true
	run_timeout "$timeout_seconds" cat "$port" > "$tmp" 2>/dev/null &
	local reader="$!"
	sleep 1
	printf '%s\r\n' "$command" > "$port" 2>/dev/null || true
	wait "$reader" 2>/dev/null || true
	cat "$tmp" 2>/dev/null || true
	rm -f "$tmp"
}

at_command() {
	local port="$1"
	local command="$2"
	local timeout_seconds="${3:-$DEFAULT_TIMEOUT_SECONDS}"

	if has_cmd socat; then
		at_with_socat "$port" "$command" "$timeout_seconds"
	elif has_timeout && has_cmd stty; then
		at_with_shell "$port" "$command" "$timeout_seconds"
	else
		return 1
	fi
}

normalize_at() {
	printf '%s' "$1" | tr '\r' '\n' | sed '/^[[:space:]]*$/d'
}

clean_at_value() {
	printf '%s\n' "$1" |
		sed '/^[[:space:]]*OK[[:space:]]*$/d; /^[[:space:]]*ERROR[[:space:]]*$/d; /^[[:space:]]*AT/d; /^[[:space:]]*$/d' |
		head -n 3 |
		tr '\n' ' ' |
		sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

first_non_empty() {
	local value

	for value in "$@"; do
		[ -n "$value" ] && {
			printf '%s' "$value"
			return 0
		}
	done
}

extract_after_colon() {
	printf '%s\n' "$1" |
		sed -n 's/^[[:space:]]*+[^:]*:[[:space:]]*//p' |
		head -n 1 |
		sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

extract_cpin_status() {
	extract_after_colon "$1"
}

extract_qccid_value() {
	extract_after_colon "$1" | tr -d '" ' | sed 's/[Ff]$//'
}

extract_cgpaddr_value() {
	local ip

	ip="$(printf '%s\n' "$1" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)"
	[ -n "$ip" ] && {
		printf '%s' "$ip"
		return 0
	}
	extract_after_colon "$1"
}

extract_qtemp_value() {
	local temps value out sep

	temps="$(extract_after_colon "$1")"
	[ -n "$temps" ] || return 0

	out=""
	sep=""
	IFS=","
	for value in $temps; do
		value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
		[ -n "$value" ] || continue
		out="${out}${sep}${value}°C"
		sep=" / "
	done
	unset IFS
	printf '%s' "$out"
}

extract_csq_value() {
	local line rssi ber dbm quality ber_text

	line="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*+CSQ:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*,[[:space:]]*\([0-9][0-9]*\).*/\1 \2/p' | head -n 1)"
	[ -n "$line" ] || {
		clean_at_value "$1"
		return 0
	}

	rssi="${line%% *}"
	ber="${line#* }"
	if [ "$rssi" = "99" ]; then
		quality="未知"
		dbm="未知"
	else
		dbm=$((2 * rssi - 113))
		if [ "$rssi" -ge 20 ]; then
			quality="优秀"
		elif [ "$rssi" -ge 15 ]; then
			quality="良好"
		elif [ "$rssi" -ge 10 ]; then
			quality="一般"
		else
			quality="较弱"
		fi
	fi

	if [ "$ber" = "99" ]; then
		ber_text="误码率未知"
	else
		ber_text="误码率 $ber"
	fi

	if [ "$dbm" = "未知" ]; then
		printf '%s (%s/31，%s)' "$quality" "$rssi" "$ber_text"
	else
		printf '%s · %s dBm (%s/31，%s)' "$quality" "$dbm" "$rssi" "$ber_text"
	fi
}

extract_operator_value() {
	local value

	value="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*+QSPN:[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p' | head -n 1)"
	[ -n "$value" ] && {
		printf '%s' "$value"
		return 0
	}
	value="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*+COPS:[^"'\'']*["'\'']\([^"'\'']*\)["'\''].*/\1/p' | head -n 1)"
	[ -n "$value" ] && {
		printf '%s' "$value"
		return 0
	}
	clean_at_value "$1"
}

extract_usb_cfg() {
	printf '%s\n' "$1" | grep -Eio '0x[0-9a-f]{4}[, ]+0x[0-9a-f]{4}' | head -n 1 | tr '[:lower:]' '[:upper:]'
}

extract_usbnet() {
	printf '%s\n' "$1" | sed -n 's/.*"usbnet",[[:space:]]*\([0-9]\+\).*/\1/p' | head -n 1
}

identity_from_cfg() {
	case "$1" in
		0X2CA3*0X4006|0x2CA3*0x4006|0x2ca3*0x4006) printf 'dji' ;;
		0X2C7C*0X0125|0x2C7C*0x0125|0x2c7c*0x0125) printf 'ec25' ;;
		0X2C7C*0X0124|0x2C7C*0x0124|0x2c7c*0x0124) printf 'ec21' ;;
		*) printf 'unknown' ;;
	esac
}

identity_from_vidpid() {
	case "$1" in
		2ca3:4006|2CA3:4006) printf 'dji' ;;
		2c7c:0125|2C7C:0125) printf 'ec25' ;;
		2c7c:0124|2C7C:0124) printf 'ec21' ;;
		*) printf 'unknown' ;;
	esac
}

identity_label() {
	case "$1" in
		dji) printf 'DJI 4G Module (2ca3:4006)' ;;
		ec25) printf 'Quectel EC20/EC25 (2c7c:0125)' ;;
		ec21) printf 'Quectel EC21 (2c7c:0124)' ;;
		*) printf '未知' ;;
	esac
}

target_identity_label() {
	identity_label "$1"
}

target_usbnet_value() {
	case "$1" in
		qmi|QMI|0|dji|DJI) printf '0' ;;
		ecm|ECM|1|quectel_ecm) printf '1' ;;
		mbim|MBIM|2|quectel_mbim) printf '2' ;;
		rndis|RNDIS|dji_rndis) printf '1' ;;
		dji_ecm) printf '2' ;;
		ncm|NCM|dji_ncm) printf '3' ;;
		dji_mbim) printf '4' ;;
		*) return 1 ;;
	esac
}

usbnet_profile() {
	case "$1" in
		dji) printf 'dji' ;;
		*) printf 'quectel' ;;
	esac
}

usbnet_label() {
	local mode="$1"
	local profile="${2:-quectel}"

	if [ "$profile" = "dji" ]; then
		case "$mode" in
			0) printf 'DJI 私有模式' ;;
			1) printf 'RNDIS' ;;
			2) printf 'CDC-ECM' ;;
			3) printf 'CDC-NCM' ;;
			4) printf 'MBIM' ;;
			*) printf '未知' ;;
		esac
		return
	fi

	case "$mode" in
		0) printf 'QMI' ;;
		1) printf 'ECM' ;;
		2) printf 'MBIM' ;;
		3) printf 'RNDIS' ;;
		*) printf '未知' ;;
	esac
}

tty_sysfs_dir() {
	local tty="${1##*/}"
	local path="/sys/class/tty/$tty/device"

	[ -e "$path" ] || return 1
	readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
}

sysfs_parent_value() {
	local dir="$1"
	local file="$2"
	local current="$dir"

	while [ -n "$current" ] && [ "$current" != "/" ]; do
		if [ -r "$current/$file" ]; then
			cat "$current/$file" 2>/dev/null | head -n 1
			return 0
		fi
		current="${current%/*}"
	done

	return 1
}

sysfs_vidpid() {
	local dir vendor product

	dir="$(tty_sysfs_dir "$1" 2>/dev/null || true)"
	[ -n "$dir" ] || return 1
	vendor="$(sysfs_parent_value "$dir" idVendor 2>/dev/null || true)"
	product="$(sysfs_parent_value "$dir" idProduct 2>/dev/null || true)"
	[ -n "$vendor" ] && [ -n "$product" ] || return 1
	printf '%s:%s' "$vendor" "$product" | tr '[:upper:]' '[:lower:]'
}

sysfs_usb_value() {
	local dir

	dir="$(tty_sysfs_dir "$1" 2>/dev/null || true)"
	[ -n "$dir" ] || return 1
	sysfs_parent_value "$dir" "$2" 2>/dev/null || true
}

sysfs_interface_number() {
	local dir current

	dir="$(tty_sysfs_dir "$1" 2>/dev/null || true)"
	[ -n "$dir" ] || return 1
	current="$dir"
	while [ -n "$current" ] && [ "$current" != "/" ]; do
		if [ -r "$current/bInterfaceNumber" ]; then
			cat "$current/bInterfaceNumber" 2>/dev/null | head -n 1
			return 0
		fi
		current="${current%/*}"
	done
	return 1
}

is_at_candidate_port() {
	local port="$1"
	local ifnum

	ifnum="$(sysfs_interface_number "$port" 2>/dev/null || true)"
	case "$ifnum" in
		02|03|'')
			return 0
			;;
		*)
			return 1
			;;
	esac
}

at_query() {
	local port="$1"
	local command="$2"
	local timeout="${3:-$DEFAULT_TIMEOUT_SECONDS}"

	normalize_at "$(at_command "$port" "$command" "$timeout" 2>/dev/null || true)"
}

json_field() {
	printf '"%s":"%s"' "$1" "$(json_escape "$2")"
}

detail_pair_json() {
	printf '{"label":"%s","value":"%s"}' "$(json_escape "$1")" "$(json_escape "$2")"
}

probe_port_json() {
	local port="$1"
	local full="${2:-0}"
	local allow_config="${3:-0}"
	local probe_at="${4:-1}"
	local at ati cgmi cgmm cgmr cgsn qccid cpin csq qnwinfo qspn cops qtemp cgpaddr qcfg qnet
	local cfg cfg_identity vidpid vidpid_identity manufacturer product serial usbnet usbnet_name ifnum profile
	local status module can_config mismatch output safe_output first primary_at
	local sim_status operator_status imei_value iccid_value ip_value temp_value signal_value

	at=""
	status="no_response"
	module=""
	cfg=""
	cfg_identity="unknown"
	usbnet=""
	usbnet_name="未知"
	profile="quectel"
	can_config=false
	primary_at=false
	mismatch=false
	output="AT:\n$at"
	vidpid="$(sysfs_vidpid "$port" 2>/dev/null || true)"
	vidpid_identity="$(identity_from_vidpid "$vidpid")"
	manufacturer="$(sysfs_usb_value "$port" manufacturer 2>/dev/null || true)"
	product="$(sysfs_usb_value "$port" product 2>/dev/null || true)"
	serial="$(sysfs_usb_value "$port" serial 2>/dev/null || true)"
	ifnum="$(sysfs_interface_number "$port" 2>/dev/null || true)"

	if [ "$probe_at" != 1 ]; then
		output="已隐藏附属接口，仅保留 USB 枚举信息"
	elif ! is_at_candidate_port "$port"; then
		output="跳过非 AT 候选接口：USB interface ${ifnum:-未知}"
	else
		at="$(at_query "$port" AT 1)"
		output="AT:\n$at"
	fi

	if [ -n "$at" ] && printf '%s\n' "$at" | grep -q 'OK'; then
		status="ok"
		ati="$(at_query "$port" ATI 2)"
		qcfg="$(at_query "$port" 'AT+QCFG="usbcfg"' 2)"
		qnet="$(at_query "$port" 'AT+QCFG="usbnet"' 2)"
		output="AT:\n$at\n\nATI:\n$ati\n\nAT+QCFG=\"usbcfg\":\n$qcfg\n\nAT+QCFG=\"usbnet\":\n$qnet"

		if [ "$full" = 1 ]; then
			cgmi="$(at_query "$port" AT+CGMI 2)"
			cgmm="$(at_query "$port" AT+CGMM 2)"
			cgmr="$(at_query "$port" AT+CGMR 2)"
			cgsn="$(at_query "$port" AT+CGSN 2)"
			qccid="$(at_query "$port" AT+QCCID 2)"
			cpin="$(at_query "$port" 'AT+CPIN?' 2)"
			csq="$(at_query "$port" AT+CSQ 2)"
			qnwinfo="$(at_query "$port" AT+QNWINFO 2)"
			qspn="$(at_query "$port" AT+QSPN 2)"
			cops="$(at_query "$port" 'AT+COPS?' 2)"
			qtemp="$(at_query "$port" AT+QTEMP 2)"
			cgpaddr="$(at_query "$port" AT+CGPADDR=1 2)"
			output="AT:\n$at\n\nATI:\n$ati\n\nAT+CGMI:\n$cgmi\n\nAT+CGMM:\n$cgmm\n\nAT+CGMR:\n$cgmr\n\nAT+CGSN:\n$cgsn\n\nAT+QCCID:\n$qccid\n\nAT+CPIN?:\n$cpin\n\nAT+CSQ:\n$csq\n\nAT+QNWINFO:\n$qnwinfo\n\nAT+QSPN:\n$qspn\n\nAT+COPS?:\n$cops\n\nAT+QTEMP:\n$qtemp\n\nAT+CGPADDR=1:\n$cgpaddr\n\nAT+QCFG=\"usbcfg\":\n$qcfg\n\nAT+QCFG=\"usbnet\":\n$qnet"
		fi

		cfg="$(extract_usb_cfg "$qcfg")"
		cfg_identity="$(identity_from_cfg "$cfg")"
		[ "$cfg_identity" = "unknown" ] && cfg_identity="$vidpid_identity"
		profile="$(usbnet_profile "$cfg_identity")"
		usbnet="$(extract_usbnet "$qnet")"
		usbnet_name="$(usbnet_label "$usbnet" "$profile")"
		if [ "$full" = 1 ]; then
			module="$(printf '%s %s %s' "$(clean_at_value "$cgmi")" "$(clean_at_value "$cgmm")" "$(clean_at_value "$cgmr")" | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
		else
			module="$(clean_at_value "$ati")"
		fi
		if [ "$allow_config" = 1 ]; then
			case "$cfg_identity" in
				dji|ec25|ec21)
					can_config=true
					primary_at=true
					;;
			esac
		fi
		[ "$cfg_identity" != "unknown" ] && [ "$vidpid_identity" != "unknown" ] && [ "$cfg_identity" != "$vidpid_identity" ] && mismatch=true
	fi

	sim_status="$(first_non_empty "$(extract_cpin_status "$cpin")" "$(clean_at_value "$cpin")")"
	operator_status="$(first_non_empty "$(extract_operator_value "$qspn")" "$(extract_operator_value "$cops")")"
	imei_value="$(clean_at_value "$cgsn")"
	iccid_value="$(first_non_empty "$(extract_qccid_value "$qccid")" "$(clean_at_value "$qccid")")"
	ip_value="$(first_non_empty "$(extract_cgpaddr_value "$cgpaddr")" "$(clean_at_value "$cgpaddr")")"
	temp_value="$(first_non_empty "$(extract_qtemp_value "$qtemp")" "$(clean_at_value "$qtemp")")"
	signal_value="$(extract_csq_value "$csq")"

	printf '{'
	json_field port "$port"; printf ','
	json_field status "$status"; printf ','
	json_field identity "$cfg_identity"; printf ','
	json_field identity_label "$(identity_label "$cfg_identity")"; printf ','
	json_field usb_config "$cfg"; printf ','
	json_field usb_vidpid "$vidpid"; printf ','
	json_field usb_identity "$vidpid_identity"; printf ','
	json_field usb_identity_label "$(identity_label "$vidpid_identity")"; printf ','
	json_field usb_manufacturer "$manufacturer"; printf ','
	json_field usb_product "$product"; printf ','
	json_field usb_serial "$serial"; printf ','
	json_field usb_interface "$ifnum"; printf ','
	json_field usbnet "$usbnet"; printf ','
	json_field usbnet_label "$usbnet_name"; printf ','
	json_field usbnet_profile "$profile"; printf ','
	json_field module "$module"; printf ','
	printf '"can_config":%s,' "$can_config"
	printf '"primary_at":%s,' "$primary_at"
	printf '"identity_mismatch":%s,' "$mismatch"
	printf '"summary":{'
	json_field vendor "$(clean_at_value "$cgmi")"; printf ','
	json_field model "$(clean_at_value "$cgmm")"; printf ','
	json_field firmware "$(clean_at_value "$cgmr")"; printf ','
	json_field sim "$sim_status"; printf ','
	json_field signal "$signal_value"; printf ','
	json_field network "$(clean_at_value "$qnwinfo")"; printf ','
	json_field operator "$operator_status"
	printf '},'
	printf '"details":['
	first=1
	for pair in \
		"IMEI|$imei_value" \
		"ICCID|$iccid_value" \
		"IP 地址|$ip_value" \
		"温度|$temp_value" \
		"USB 产品|$manufacturer $product" \
		"USB 序列号|$serial"
	do
		[ "$first" = 1 ] || printf ','
		first=0
		detail_pair_json "${pair%%|*}" "${pair#*|}"
	done
	printf '],'
	safe_output="$(printf '%s' "$output" | tr '"' "'")"
	json_field output "$safe_output"
	printf '}'
}

# Shared dependency block for status/probe responses. It reports both the
# package/driver state and the /dev/cdc-wdm* control device used by the QMI and
# MBIM backends.
driver_status_json() {
	printf '"kernel_version":"%s",' "$(json_escape "$(kernel_release)")"
	printf '"kernel_package_version":"%s",' "$(json_escape "$(kernel_package_version 2>/dev/null || true)")"
	printf '"serial_driver_installed":%s,' "$(serial_driver_state)"
	printf '"option_driver_installed":%s,' "$(option_driver_state)"
	printf '"qmi_driver_installed":%s,' "$(qmi_driver_state)"
	printf '"mbim_driver_installed":%s,' "$(mbim_driver_state)"
	printf '"cdc_wdm_present":%s,' "$(cdc_wdm_state)"
	printf '"control_device":"%s",' "$(json_escape "$(first_control_device)")"
	printf '"uqmi_installed":%s,' "$(dep_value uqmi)"
	printf '"umbim_installed":%s,' "$(dep_value umbim)"
	printf '"socat_installed":%s,' "$(dep_value socat)"
	printf '"stty_available":%s,' "$(has_cmd stty && printf true || printf false)"
	printf '"timeout_available":%s' "$(has_timeout && printf true || printf false)"
}

status_json() {
	printf '{"ok":true,'
	driver_status_json
	printf '}\n'
}

probe_json() {
	local first=1 full_done=0 config_done=0 full allow_config probe_at port tmp port_json

	prepare_serial_driver
	printf '{"ok":true,'
	driver_status_json
	printf ',"ports":['
	for port in $(serial_ports); do
		task_progress "probe" "正在探测 $port"
		full=0
		allow_config=0
		probe_at=1
		[ "$full_done" = 0 ] && full=1
		[ "$config_done" = 0 ] && allow_config=1
		[ "$config_done" = 1 ] && probe_at=0
		tmp="/tmp/vohive/probe-port.$$"
		probe_port_json "$port" "$full" "$allow_config" "$probe_at" > "$tmp"
		port_json="$(cat "$tmp" 2>/dev/null || true)"
		rm -f "$tmp"
		if [ "$full_done" = 0 ] && printf '%s' "$port_json" | grep -q '"status":"ok"'; then
			full_done=1
		fi
		if [ "$config_done" = 0 ] && printf '%s' "$port_json" | grep -q '"primary_at":true'; then
			config_done=1
		fi
		[ "$first" = 1 ] || printf ','
		first=0
		printf '%s' "$port_json"
	done
	printf ']}\n'
}

install_packages() {
	local packages="$1"
	local output manager

	manager="$(package_manager)" || fail "未找到 opkg 或 apk"
	case "$manager" in
		opkg)
			output="$(opkg update 2>&1 && opkg install $packages 2>&1)"
			;;
		apk)
			output="$(apk update 2>&1 && apk add $packages 2>&1)"
			;;
		*)
			fail "不支持的包管理器: $manager"
			;;
	esac || {
		printf '{"ok":false,"message":"安装失败","output":"%s"}\n' "$(json_escape "$output")"
		exit 1
	}

	printf '{"ok":true,"message":"安装完成","output":"%s"}\n' "$(json_escape "$output")"
}

# Candidate kmod feeds. The default mirrors the builder layout used by
# custom x86_64 images whose kernel is newer than the release the feeds point
# at; {kernel} expands to the installed kernel package version.
kmod_feed_candidates() {
	local custom

	custom="$(uci_get kmod_feed_base '')"
	[ -n "$custom" ] && printf '%s\n' "$custom"
	printf '%s\n' 'https://raw.githubusercontent.com/sbwml/openwrt_core2/x86_64/{kernel}'
}

expand_kmod_feed() {
	printf '%s' "$1" | sed "s|{kernel}|$2|g"
}

# Download the requested kmod ipk files from a kernel-matched feed, verify them
# against the feed index and install them locally. Local ipk installs do not
# depend on the feed being configured in /etc/opkg, so this works even when the
# device only has the stock release feeds.
install_kmods_from_feed() {
	local base="$1"
	local workdir="$2"
	local packages="$3"
	local index="$workdir/Packages"
	local package filename expected file actual

	download_file "$base/Packages" "$index" || {
		printf '无法下载模块索引: %s/Packages\n' "$base"
		return 1
	}
	[ -s "$index" ] || {
		printf '模块索引为空: %s/Packages\n' "$base"
		return 1
	}

	for package in $packages; do
		filename="$(feed_package_field "$index" "$package" Filename)"
		if [ -z "$filename" ]; then
			printf '模块源中没有 %s\n' "$package"
			return 1
		fi
		expected="$(feed_package_field "$index" "$package" SHA256sum)"
		file="$workdir/$filename"
		if ! download_file "$base/$filename" "$file"; then
			printf '下载失败: %s\n' "$filename"
			return 1
		fi
		if [ -n "$expected" ]; then
			actual="$(file_sha256 "$file" || true)"
			if [ "$actual" != "$expected" ]; then
				printf '校验失败: %s\n' "$filename"
				return 1
			fi
		fi
		if ! opkg install "$file" 2>&1; then
			printf '安装失败: %s\n' "$filename"
			return 1
		fi
	done

	return 0
}

# Generic kmod installer shared by the serial, QMI and MBIM drivers.
# $1 label (shown to the user), $2 package list, $3 present-check function,
# $4 load function. It first tries the configured feeds and only falls back to
# a kernel-matched kmod feed when the stock feeds do not carry the modules.
install_drivers_json() {
	local label="$1"
	local packages="$2"
	local present_fn="$3"
	local load_fn="$4"
	local kernel version manager output native_output base workdir

	kernel="$(kernel_release)"
	output="当前内核: $kernel\n"
	workdir="/tmp/vohive/kmod.$$"
	mkdir -p "$workdir"

	if "$present_fn"; then
		"$load_fn"
		rm -rf "$workdir"
		output="${output}${label}模块已存在，已直接加载，无需联网安装。\n"
		printf '{"ok":true,"message":"%s已就绪","output":"%s"}\n' "$(json_escape "$label")" "$(json_escape "$output")"
		return 0
	fi

	manager="$(package_manager 2>/dev/null || true)"
	output="${output}尝试从当前软件源安装: $packages\n"
	case "$manager" in
		opkg)
			native_output="$(opkg update 2>&1; opkg install $packages 2>&1)"
			;;
		apk)
			native_output="$(apk update 2>&1; apk add $packages 2>&1)"
			;;
		*)
			native_output="未找到 opkg 或 apk"
			;;
	esac
	output="${output}${native_output}\n"

	if "$present_fn"; then
		"$load_fn"
		rm -rf "$workdir"
		output="${output}安装完成。\n"
		printf '{"ok":true,"message":"%s安装完成","output":"%s"}\n' "$(json_escape "$label")" "$(json_escape "$output")"
		return 0
	fi

	if [ "$manager" != opkg ]; then
		rm -rf "$workdir"
		output="${output}当前源没有与内核 $kernel 匹配的模块，且包管理器 ${manager:-未知} 不支持模块源回退。\n"
		printf '{"ok":false,"message":"安装失败：当前源没有匹配的%s","output":"%s"}\n' "$(json_escape "$label")" "$(json_escape "$output")"
		exit 1
	fi

	version="$(kernel_package_version 2>/dev/null || true)"
	if [ -z "$version" ]; then
		rm -rf "$workdir"
		output="${output}当前源没有与内核 $kernel 匹配的模块，也无法确定内核软件包版本。\n"
		printf '{"ok":false,"message":"无法确定内核版本，安装失败","output":"%s"}\n' "$(json_escape "$output")"
		exit 1
	fi

	output="${output}当前源没有与内核匹配的模块，改用与内核版本 $version 对应的模块源。\n"
	for base in $(kmod_feed_candidates); do
		base="$(expand_kmod_feed "$base" "$version")"
		output="${output}模块源: $base\n"
		install_kmods_from_feed "$base" "$workdir" "$packages" > "$workdir/log" 2>&1 || true
		output="${output}$(cat "$workdir/log" 2>/dev/null || true)"
		"$present_fn" && break
	done

	rm -rf "$workdir"

	if "$present_fn"; then
		"$load_fn"
		output="${output}安装完成。\n"
		printf '{"ok":true,"message":"%s安装完成","output":"%s"}\n' "$(json_escape "$label")" "$(json_escape "$output")"
		return 0
	fi

	output="${output}未找到与内核 $kernel 匹配的模块。\n可在 /etc/config/vohive 中通过 kmod_feed_base 指定模块源，地址中的 {kernel} 会替换为内核软件包版本。\n"
	printf '{"ok":false,"message":"安装失败：没有匹配当前内核的%s","output":"%s"}\n' "$(json_escape "$label")" "$(json_escape "$output")"
	exit 1
}

install_serial_drivers_json() {
	install_drivers_json '串口驱动' "$KMOD_SERIAL_PACKAGES" serial_modules_present load_serial_modules
}

install_qmi_drivers_json() {
	install_drivers_json 'QMI 驱动' "$KMOD_QMI_PACKAGES" qmi_modules_present load_qmi_modules
}

install_mbim_drivers_json() {
	install_drivers_json 'MBIM 驱动' "$KMOD_MBIM_PACKAGES" mbim_modules_present load_mbim_modules
}

# Classify a read-only AT probe into ok / error / no_response / unknown.
at_probe_state() {
	local response="$1"

	if [ -z "$response" ]; then
		printf 'no_response'
	elif printf '%s\n' "$response" | grep -q 'ERROR'; then
		printf 'error'
	elif printf '%s\n' "$response" | grep -q 'OK'; then
		printf 'ok'
	else
		printf 'unknown'
	fi
}

esim_probe_message() {
	local at_apdu="$1"
	local recommended="$2"

	if [ "$at_apdu" = true ]; then
		printf '模块支持 AT APDU，可直接使用 AT 传输管理 eSIM。'
	elif [ "$recommended" = qmi ]; then
		printf 'AT 通道不支持 APDU，但检测到 QMI 控制口，可尝试改用 QMI 传输。'
	elif [ "$recommended" = mbim ]; then
		printf 'AT 通道不支持 APDU，但检测到 MBIM 控制口，可尝试改用 MBIM 传输。'
	else
		printf 'AT 通道不支持 APDU，且未检测到 QMI/MBIM 控制口。该模块可能无法通过本工具管理 eSIM。'
	fi
}

# Read-only eSIM/APDU capability probe. It never writes to the module: it only
# asks the AT parser whether the SIM APDU commands exist and whether a QMI/MBIM
# control device (/dev/cdc-wdm*) is exposed.
probe_esim_capability_json() {
	local port="$1"
	local ccho cgla cchc csim
	local ccho_state cgla_state cchc_state csim_state
	local at_apdu=false qmi_present=false mbim_present=false
	local recommended=none control output

	[ -n "$port" ] || fail "缺少 AT 串口参数"
	[ -c "$port" ] || fail "串口不存在: $port"

	ccho="$(at_query "$port" 'AT+CCHO=?' 2)"
	cgla="$(at_query "$port" 'AT+CGLA=?' 2)"
	cchc="$(at_query "$port" 'AT+CCHC=?' 2)"
	csim="$(at_query "$port" 'AT+CSIM=?' 2)"

	ccho_state="$(at_probe_state "$ccho")"
	cgla_state="$(at_probe_state "$cgla")"
	cchc_state="$(at_probe_state "$cchc")"
	csim_state="$(at_probe_state "$csim")"

	if [ "$ccho_state" = ok ] && [ "$cgla_state" = ok ]; then
		at_apdu=true
	fi

	control="$(first_control_device)"
	if [ -n "$control" ] && [ "$(qmi_driver_state)" = true ]; then
		qmi_present=true
	fi
	if [ -n "$control" ] && [ "$(mbim_driver_state)" = true ]; then
		mbim_present=true
	fi

	if [ "$at_apdu" = true ]; then
		recommended=at
	elif [ "$qmi_present" = true ]; then
		recommended=qmi
	elif [ "$mbim_present" = true ]; then
		recommended=mbim
	fi

	output="AT 端口: $port\n"
	output="${output}AT+CCHO=?: $ccho_state\n$ccho\n"
	output="${output}AT+CGLA=?: $cgla_state\n$cgla\n"
	output="${output}AT+CCHC=?: $cchc_state\n$cchc\n"
	output="${output}AT+CSIM=?: $csim_state\n$csim\n"
	output="${output}控制设备: ${control:-未发现 /dev/cdc-wdm*}\n"
	output="${output}QMI 驱动: $(qmi_driver_state)\n"
	output="${output}MBIM 驱动: $(mbim_driver_state)\n"
	output="${output}推荐传输: $recommended\n"

	printf '{"ok":true,'
	printf '"port":"%s",' "$(json_escape "$port")"
	printf '"at_apdu_supported":%s,' "$at_apdu"
	printf '"qmi_device_present":%s,' "$qmi_present"
	printf '"mbim_device_present":%s,' "$mbim_present"
	printf '"recommended_transport":"%s",' "$recommended"
	printf '"control_device":"%s",' "$(json_escape "$control")"
	printf '"at_ccho":"%s",' "$(json_escape "$ccho_state")"
	printf '"at_cgla":"%s",' "$(json_escape "$cgla_state")"
	printf '"at_cchc":"%s",' "$(json_escape "$cchc_state")"
	printf '"at_csim":"%s",' "$(json_escape "$csim_state")"
	printf '"message":"%s",' "$(json_escape "$(esim_probe_message "$at_apdu" "$recommended")")"
	printf '"output":"%s"}\n' "$(json_escape "$output")"
}

target_command() {
	case "$1" in
		ec25) printf 'AT+QCFG="usbcfg",0x2C7C,0x0125,1,1,1,1,1,0,0' ;;
		dji) printf 'AT+QCFG="usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,0' ;;
		*) return 1 ;;
	esac
}

wait_for_identity() {
	local target="$1"
	local now end port qcfg cfg identity vidpid

	now="$(date +%s)"
	end="$((now + 30))"
	while [ "$(date +%s)" -lt "$end" ]; do
		prepare_serial_driver
		for port in $(serial_ports); do
			vidpid="$(sysfs_vidpid "$port" 2>/dev/null || true)"
			identity="$(identity_from_vidpid "$vidpid")"
			if [ "$identity" = "$target" ]; then
				printf '检测到目标身份：%s on %s (USB %s)\n' "$(identity_label "$target")" "$port" "$vidpid"
				return 0
			fi

			qcfg="$(at_query "$port" 'AT+QCFG="usbcfg"' 2)"
			cfg="$(extract_usb_cfg "$qcfg")"
			identity="$(identity_from_cfg "$cfg")"
			if [ "$identity" = "$target" ]; then
				printf '检测到目标身份：%s on %s\n' "$(identity_label "$target")" "$port"
				return 0
			fi
		done
		sleep 2
	done

	printf '30 秒内未检测到目标身份：%s\n' "$(identity_label "$target")"
	return 1
}

wait_for_usbnet() {
	local target="$1"
	local profile="${2:-quectel}"
	local now end port qnet mode

	now="$(date +%s)"
	end="$((now + 30))"
	while [ "$(date +%s)" -lt "$end" ]; do
		prepare_serial_driver
		for port in $(serial_ports); do
			qnet="$(at_query "$port" 'AT+QCFG="usbnet"' 2)"
			mode="$(extract_usbnet "$qnet")"
			if [ "$mode" = "$target" ]; then
				printf '检测到目标 USB 网络模式：%s on %s\n' "$(usbnet_label "$target" "$profile")" "$port"
				return 0
			fi
		done
		sleep 2
	done

	printf '30 秒内未验证目标 USB 网络模式：%s\n' "$(usbnet_label "$target" "$profile")"
	return 1
}

restart_module() {
	local port="$1"
	at_query "$port" 'AT+CFUN=1,1' 2
}

stop_vohive() {
	task_progress service "停止 VoHive 服务"
	/etc/init.d/vohive stop 2>&1 || true
}

start_vohive() {
	task_progress service "启动 VoHive 服务"
	/etc/init.d/vohive start 2>&1 || true
}

convert_json() {
	local port="$1"
	local target="$2"
	local command output write_result reset_result wait_result ok=true

	[ -c "$port" ] || fail "串口不存在: $port"
	command="$(target_command "$target")" || fail "不支持的目标身份: $target"

	output="停止 VoHive 服务...\n"
	output="$output$(stop_vohive)\n\n"

	task_progress write "写入 USB 身份：$(target_identity_label "$target")"
	output="${output}写入 USB 身份：$(target_identity_label "$target")\n"
	write_result="$(at_query "$port" "$command" 3)"
	output="$output$write_result\n\n"
	if ! printf '%s\n' "$write_result" | grep -q 'OK'; then
		ok=false
		output="${output}写入命令未返回 OK。\n\n"
	fi

	task_progress reboot "重启模块"
	output="${output}重启模块...\n"
	reset_result="$(restart_module "$port")"
	output="$output$reset_result\n\n"

	task_progress verify "等待模块重新枚举并验证身份"
	output="${output}等待模块重新枚举...\n"
	wait_result="$(wait_for_identity "$target" 2>&1)" || ok=partial
	output="$output$wait_result\n\n"

	output="${output}启动 VoHive 服务...\n"
	output="$output$(start_vohive)\n"

	case "$ok" in
		true)
			printf '{"ok":true,"message":"已转换为 %s","output":"%s"}\n' "$(json_escape "$(target_identity_label "$target")")" "$(json_escape "$output")"
			;;
		partial)
			printf '{"ok":true,"message":"写入已完成，但未验证到目标身份；请等待模块重启完成后刷新探测","output":"%s"}\n' "$(json_escape "$output")"
			;;
		*)
			printf '{"ok":false,"message":"写入命令未确认成功，VoHive 已启动","output":"%s"}\n' "$(json_escape "$output")"
			exit 1
			;;
	esac
}

switch_usbnet_json() {
	local port="$1"
	local target="$2"
	local target_value write_result reset_result wait_result output ok=true qcfg cfg identity profile

	[ -c "$port" ] || fail "串口不存在: $port"
	target_value="$(target_usbnet_value "$target")" || fail "不支持的 USB 网络模式: $target"
	qcfg="$(at_query "$port" 'AT+QCFG="usbcfg"' 2)"
	cfg="$(extract_usb_cfg "$qcfg")"
	identity="$(identity_from_cfg "$cfg")"
	profile="$(usbnet_profile "$identity")"

	output="停止 VoHive 服务...\n"
	output="$output$(stop_vohive)\n\n"

	task_progress write "写入 USB 网络模式：$(usbnet_label "$target_value" "$profile")"
	output="${output}写入 USB 网络模式：$(usbnet_label "$target_value" "$profile")\n"
	write_result="$(at_query "$port" "AT+QCFG=\"usbnet\",$target_value" 3)"
	output="$output$write_result\n\n"
	if ! printf '%s\n' "$write_result" | grep -q 'OK'; then
		output="${output}写入命令未返回 OK。\n\n"
		ok=false
	fi

	task_progress reboot "重启模块"
	output="${output}重启模块...\n"
	reset_result="$(restart_module "$port")"
	output="$output$reset_result\n\n"

	task_progress verify "等待模块重新枚举并验证 USB 网络模式"
	output="${output}等待模块重新枚举...\n"
	wait_result="$(wait_for_usbnet "$target_value" "$profile" 2>&1)" || ok=partial
	output="$output$wait_result\n\n"

	output="${output}启动 VoHive 服务...\n"
	output="$output$(start_vohive)\n"

	case "$ok" in
		true)
			printf '{"ok":true,"message":"已切换为 %s","output":"%s"}\n' "$(json_escape "$(usbnet_label "$target_value" "$profile")")" "$(json_escape "$output")"
			;;
		partial)
			printf '{"ok":true,"message":"配置已写入，但未验证到目标模式；请等待模块重启完成后刷新探测","output":"%s"}\n' "$(json_escape "$output")"
			;;
		*)
			printf '{"ok":false,"message":"写入命令未确认成功，VoHive 已启动","output":"%s"}\n' "$(json_escape "$output")"
			exit 1
			;;
	esac
}

case "$ACTION" in
	status)
		status_json
		;;
	probe)
		probe_json
		;;
	install_serial_drivers)
		install_serial_drivers_json
		;;
	install_qmi_driver)
		install_qmi_drivers_json
		;;
	install_mbim_driver)
		install_mbim_drivers_json
		;;
	probe_esim_capability)
		probe_esim_capability_json "$PORT"
		;;
	install_socat)
		install_packages 'socat'
		;;
	convert)
		convert_json "$PORT" "$TARGET"
		;;
	switch_usbnet)
		switch_usbnet_json "$PORT" "$TARGET"
		;;
	*)
		fail "不支持的操作: $ACTION"
		;;
esac
