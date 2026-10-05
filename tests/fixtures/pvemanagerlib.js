// Minimal stand-in for pve-manager/js/pvemanagerlib.js: only the parts the patcher anchors on.
Ext.define('pve-rrd-node', {
    extend: 'Ext.data.Model',
    fields: [
	{ name: 'cpu', calculate: function(data) { return data.cpu; } },
	'netin',
	{ type: 'date', dateFormat: 'timestamp', name: 'time' },
    ],
});

Ext.define('PVE.node.StatusView', {
    extend: 'Proxmox.panel.StatusView',
    alias: 'widget.pveNodeStatus',

    height: 350,
    bodyPadding: '15 5 15 5',

    items: [
	{
	    itemId: 'cpu',
	    title: gettext('CPU usage'),
	},
	{
	    itemId: 'cpus',
	    colspan: 2,
	    printBar: false,
	    title: gettext('CPU(s)'),
	    textField: 'cpuinfo',
	},
	{
	    itemId: 'kversion',
	    title: gettext('Kernel Version'),
	},
    ],
});

Ext.define('PVE.node.Summary', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveNodeSummary',

    initComponent: function() {
	var me = this;
	var rrdstore = Ext.create('Proxmox.data.RRDStore', {});

	Ext.apply(me, {
	    items: [
		{
		    xtype: 'container',
		    itemId: 'itemcontainer',
		    layout: 'column',
		    defaults: {
			minHeight: 360,
			padding: 5,
			columnWidth: 1,
		    },
		    items: [
			{
			    xtype: 'pveNodeStatus',
			},
			{
			    xtype: 'proxmoxRRDChart',
			    title: gettext('CPU usage'),
			    fields: ['cpu'],
			    store: rrdstore,
			},
		    ],
		},
	    ],
	});

	me.callParent();
    },
});
