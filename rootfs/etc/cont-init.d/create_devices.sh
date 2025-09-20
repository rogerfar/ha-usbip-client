#!/command/with-contenv bashio
# shellcheck disable=SC1008
bashio::config.require 'log_level'
bashio::log.level "$(bashio::config 'log_level')"

declare server_address
declare bus_id
declare hardware_id
declare script_directory="/usr/local/bin"
declare mount_script="/usr/local/bin/mount_devices"
declare discovery_server_address

normalize() {
    [[ "$1" == "null" ]] && echo "" || echo "$1"
}

discovery_server_address=$(bashio::config 'discovery_server_address')

bashio::log.info ""
bashio::log.info "-----------------------------------------------------------------------"
bashio::log.info "-------------------- Starting USB/IP Client Add-on --------------------"
bashio::log.info "-----------------------------------------------------------------------"
bashio::log.info ""

# Check if the script directory exists and log details
bashio::log.debug "Checking if script directory ${script_directory} exists."
if ! bashio::fs.directory_exists "${script_directory}"; then
    bashio::log.info "Creating script directory at ${script_directory}."
    mkdir -p "${script_directory}" || bashio::exit.nok "Could not create bin folder"
else
    bashio::log.debug "Script directory ${script_directory} already exists."
fi

# Create or clean the mount script
bashio::log.debug "Checking if mount script ${mount_script} exists."
if bashio::fs.file_exists "${mount_script}"; then
    bashio::log.info "Mount script already exists. Removing old script."
    rm "${mount_script}"
fi
bashio::log.info "Creating new mount script at ${mount_script}."
touch "${mount_script}" || bashio::exit.nok "Could not create mount script"
chmod +x "${mount_script}"

# Write initial content to the mount script
echo '#!/command/with-contenv bashio' >"${mount_script}"
echo 'mount -o remount -t sysfs sysfs /sys' >>"${mount_script}"
bashio::log.debug "Mount script initialization complete."

# Discover available devices
bashio::log.info "Discovering devices from server ${discovery_server_address}."
if available_devices=$(usbip list -r "${discovery_server_address}" 2>/dev/null); then
    if [ -z "$available_devices" ]; then
        bashio::log.warning "No devices found on server ${discovery_server_address}."
    else
        bashio::log.info "Available devices from ${discovery_server_address}:"
        echo "$available_devices" | while read -r line; do
            bashio::log.info "$line"
        done
    fi
else
    bashio::log.error "Failed to retrieve device list from server ${discovery_server_address}."
fi

bashio::log.info "Dumping usbip list output from ${server_address} for debugging..."
if output=$(/usr/sbin/usbip list -r "${server_address}" 2>&1); then
    while IFS= read -r line; do
        bashio::log.info "[usbip] $line"
    done <<< "$output"
else
    bashio::log.error "Failed to run usbip list -r ${server_address}: $output"
fi

# Loop through configured devices
bashio::log.info "Iterating over configured devices."
for device in $(bashio::config 'devices|keys'); do
    server_address=$(bashio::config "devices[${device}].server_address")
    bus_id=$(normalize "$(bashio::config "devices[${device}].bus_id")")
    hardware_id=$(normalize "$(bashio::config "devices[${device}].hardware_id")")

    bashio::log.debug "Device ${device}: server_address='${server_address}', bus_id='${bus_id}', hardware_id='${hardware_id}'"

    # Determine connection type and validate
    if [[ -n "$bus_id" && -n "$hardware_id" ]]; then
        bashio::log.error "Device ${device}: Cannot specify both bus_id and hardware_id. Please use only one."
        continue
    elif [[ -z "$bus_id" && -z "$hardware_id" ]]; then
        bashio::log.error "Device ${device}: Must specify either bus_id or hardware_id."
        continue
    fi

    if [[ -n "$bus_id" ]]; then
        bashio::log.info "Adding device from server ${server_address} on bus ${bus_id}"
        
        # Detach any existing attachments by bus_id
        bashio::log.debug "Detaching device ${bus_id} from server ${server_address} if already attached."
        echo "/usr/sbin/usbip detach -r ${server_address} -b ${bus_id} >/dev/null 2>&1 || true" >>"${mount_script}"

        # Attach the device by bus_id
        bashio::log.debug "Attaching device ${bus_id} from server ${server_address}."
        echo "/usr/sbin/usbip attach --remote=${server_address} --busid=${bus_id}" >>"${mount_script}"
    elif [[ -n "$hardware_id" ]]; then
        bashio::log.info "Adding device from server ${server_address} with hardware ID ${hardware_id}"
        
        # Note: detach by hardware_id is not directly supported, but we can detach all from server
        bashio::log.debug "Detaching any existing devices from server ${server_address}."
        echo "/usr/sbin/usbip detach -r ${server_address} >/dev/null 2>&1 || true" >>"${mount_script}"

        # Attach the device by hardware_id
        bashio::log.debug "Looking up bus_id for hardware_id ${hardware_id} on ${server_address}"
        bus_id_from_hwid=$(usbip list -r "${server_address}" | awk -v hwid="${hardware_id}" '
            BEGIN {bus=""}
            /busid/ {bus=$2}
            /Vendor.*Product/ {
                if (index($0, hwid) > 0) {
                    print bus
                    exit
                }
            }')
        
        if [[ -n "$bus_id_from_hwid" ]]; then
            bashio::log.info "Resolved hardware ID ${hardware_id} to bus ${bus_id_from_hwid}"
            echo "/usr/sbin/usbip detach -r ${server_address} -b ${bus_id_from_hwid} >/dev/null 2>&1 || true" >>"${mount_script}"
            echo "/usr/sbin/usbip attach --remote=${server_address} --busid=${bus_id_from_hwid}" >>"${mount_script}"
        else
            bashio::log.error "Could not find matching device for hardware ID ${hardware_id} on ${server_address}"
        fi
    fi
done

bashio::log.info "Device configuration complete. Ready to attach devices."
