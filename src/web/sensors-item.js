	// PVE-SENSORS-MOD-BEGIN
	{
	    itemId: 'thermal',
	    colspan: 2,
	    printBar: false,
	    title: gettext('Temperatures'),
	    textField: 'thermalstate',
	    value: '',
	    renderer: function(value) {
		if (!value) { return 'N/A'; }
		let obj;
		try {
		    // some lm-sensors versions emit a trailing comma; tolerate it
		    obj = JSON.parse(String(value).replace(/,\s*([}\]])/g, '$1'));
		} catch (e) {
		    return 'N/A';
		}
		let fmt = function(t) { return (Math.round(t * 10) / 10).toFixed(1) + '&deg;C'; };
		let groups = { CPU: [], GPU: [], NVMe: [], Disks: [], Board: [] };
		Object.keys(obj || {}).forEach(function(chip) {
		    let feats = obj[chip];
		    if (!feats || typeof feats !== 'object') { return; }
		    let group;
		    if (/^(coretemp|k10temp|k8temp|zenpower)/.test(chip)) { group = 'CPU'; }
		    else if (/^(amdgpu|radeon|nouveau|i915|xe)/.test(chip)) { group = 'GPU'; }
		    else if (/^nvme/.test(chip)) { group = 'NVMe'; }
		    else if (/^drivetemp/.test(chip)) { group = 'Disks'; }
		    else if (/^(acpitz|nct|it8|w836|jc42|smsc)/.test(chip)) { group = 'Board'; }
		    else { return; }

		    let entries = [];
		    Object.keys(feats).forEach(function(label) {
			let f = feats[label];
			if (!f || typeof f !== 'object') { return; }
			let k = Object.keys(f).find(function(x) { return (/^temp\d+_input$/).test(x); });
			if (k === undefined || typeof f[k] !== 'number') { return; }
			// unconnected channel: nct6779 publishes CPUTIN=-125, AUXTIN2=107, PCH=0
			if (f[k] < 5 || f[k] > 105) { return; }
			entries.push({ label: label, temp: f[k] });
		    });

		    // CPU: if there is Package/Tctl/Tdie show only those, otherwise it becomes a huge list of cores
		    if (group === 'CPU') {
			let pref = entries.filter(function(e) { return (/^(Package id|Tctl|Tdie|Tccd)/i).test(e.label); });
			if (pref.length) { entries = pref; }
		    }
		    if (group === 'NVMe') {
			let pref = entries.filter(function(e) { return (/^Composite/i).test(e.label); });
			if (pref.length) { entries = pref; }
		    }
		    if (group === 'Board') {
			let pref = entries.filter(function(e) { return (/^(SYSTIN|System|MB|Motherboard)/i).test(e.label); });
			if (pref.length) { entries = pref; }
		    }

		    let useChipName = (group === 'NVMe' || group === 'Disks');
		    entries.forEach(function(e) {
			// 'drivetemp-scsi-0-0' -> 'scsi-0-0': the panel is narrow and
			// with 6 disks the line wraps and cuts the rest of the Summary
			let label = useChipName ? chip.replace(/^drivetemp-/, '') : e.label;
			groups[group].push(Ext.String.htmlEncode(label) + ': <b>' + fmt(e.temp) + '</b>');
		    });
		});
		let out = [];
		Object.keys(groups).forEach(function(g) {
		    if (groups[g].length) {
			out.push('<b>' + g + '</b> &mdash; ' + groups[g].join(' &nbsp;|&nbsp; '));
		    }
		});
		return out.length ? out.join('<br>') : 'N/A';
	    },
	},
	// PVE-SENSORS-MOD-END
