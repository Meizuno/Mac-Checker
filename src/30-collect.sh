# ---------------------------------------------------------- збір даних ----

[ -t 2 ] && printf '%s' "${C_DIM}$(T collecting)${C_RESET}" >&2

system_profiler -json \
	SPHardwareDataType SPSoftwareDataType SPPowerDataType SPNVMeDataType \
	SPSerialATADataType SPDisplaysDataType SPCameraDataType SPAudioDataType \
	SPBluetoothDataType SPiBridgeDataType \
	> "$TMP_DIR/sp.json" 2>/dev/null

# Розбір JSON через JavaScript for Automation (є в кожній macOS, на відміну від jq/python).
# Результат — рядки "ключ<TAB>значення".
osascript -l JavaScript - "$TMP_DIR/sp.json" > "$TMP_DIR/sp.tsv" 2>/dev/null <<'JS'
ObjC.import('Foundation');
function run(argv) {
	var raw = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
	var d = {};
	try { d = JSON.parse(raw.js); } catch (e) {}
	var out = [];
	function put(k, v) {
		if (v === undefined || v === null || v === '') return;
		out.push(k + '\t' + String(v).replace(/[\t\r\n]+/g, ' '));
	}
	function find(o, key) {
		if (o === null || typeof o !== 'object') return undefined;
		if (Array.isArray(o)) {
			for (var i = 0; i < o.length; i++) { var r = find(o[i], key); if (r !== undefined) return r; }
			return undefined;
		}
		if (key in o) return o[key];
		for (var k in o) { var r2 = find(o[k], key); if (r2 !== undefined) return r2; }
		return undefined;
	}
	function first(name) { return (d[name] || [])[0] || {}; }

	var hw = first('SPHardwareDataType');
	put('model_name', hw.machine_name);
	put('model_id', hw.machine_model);
	put('model_number', hw.model_number);
	put('serial', hw.serial_number);
	put('chip', hw.chip_type || hw.cpu_type);
	put('cpu_speed', hw.current_processor_speed);
	put('cores', hw.number_processors);
	put('memory', hw.physical_memory);
	put('activation_lock', hw.activation_lock_status);

	var sw = first('SPSoftwareDataType');
	put('os', sw.os_version);

	var pw = d.SPPowerDataType || [];
	put('bat_present', find(pw, 'sppower_battery_health_info') !== undefined ? 'yes' : '');
	put('bat_cycles', find(pw, 'sppower_battery_cycle_count'));
	put('bat_health', find(pw, 'sppower_battery_health'));
	put('bat_maxcap', find(pw, 'sppower_battery_health_maximum_capacity'));
	put('bat_charge', find(pw, 'sppower_battery_state_of_charge'));
	put('bat_charging', find(pw, 'sppower_battery_is_charging'));
	put('bat_serial', find(pw, 'sppower_battery_serial_number'));
	put('ac_connected', find(pw, 'sppower_battery_charger_connected'));
	put('ac_watts', find(pw, 'sppower_ac_charger_watts'));
	put('ac_name', find(pw, 'sppower_ac_charger_name'));

	var n = 0;
	['SPNVMeDataType', 'SPSerialATADataType'].forEach(function (t) {
		(d[t] || []).forEach(function (ctrl) {
			(ctrl._items || []).forEach(function (dr) {
				if (dr.detachable_drive === 'yes' || dr.removable_media === 'yes') return;
				n++;
				put('disk_' + n, [dr.device_model || dr._name, dr.size || '', dr.smart_status || '', dr.medium_type || (t === 'SPNVMeDataType' ? 'ssd' : '')].join('|'));
			});
		});
	});
	put('disk_count', n);

	var g = 0, s = 0;
	(d.SPDisplaysDataType || []).forEach(function (gpu) {
		g++;
		put('gpu_' + g, [gpu.sppci_model || gpu._name, gpu.sppci_cores || '', gpu.spdisplays_vram || gpu.spdisplays_vram_shared || ''].join('|'));
		(gpu.spdisplays_ndrvs || []).forEach(function (sc) {
			s++;
			var internal = sc.spdisplays_connection_type === 'spdisplays_internal' || /built-?in|color lcd/i.test(sc._name || '');
			put('disp_' + s, [sc._name, sc._spdisplays_pixels || sc._spdisplays_resolution || '', internal ? '1' : '0'].join('|'));
		});
	});
	put('gpu_count', g);
	put('disp_count', s);

	put('cameras', (d.SPCameraDataType || []).map(function (c) { return c._name; }).join('; '));

	var spk = [], mic = [];
	(d.SPAudioDataType || []).forEach(function (grp) {
		(grp._items || []).forEach(function (a) {
			if (a.coreaudio_device_transport !== 'coreaudio_device_type_builtin') return;
			if (a.coreaudio_device_output) spk.push(a._name);
			if (a.coreaudio_device_input) mic.push(a._name);
		});
	});
	put('speakers', spk.join('; '));
	put('mics', mic.join('; '));

	var bt = d.SPBluetoothDataType || [];
	put('bt_chip', find(bt, 'controller_chipset'));
	put('bt_state', find(bt, 'controller_state'));

	put('t2', find(d.SPiBridgeDataType || [], 'ibridge_model_name'));
	return out.join('\n');
}
JS

while IFS=$'\t' read -r key val; do
	[ -n "$key" ] && printf -v "SP_$key" '%s' "$val"
done < "$TMP_DIR/sp.tsv"

# Значення поля з `ioreg` для батареї (числа або Yes/No).
ioreg -rn AppleSmartBattery > "$TMP_DIR/battery.txt" 2>/dev/null
bat_field() {
	LC_ALL=C sed -n "s/^ *\"$1\" = \\(.*\\)$/\\1/p" "$TMP_DIR/battery.txt" | head -1
}

[ -t 2 ] && printf '\r\033[K' >&2

