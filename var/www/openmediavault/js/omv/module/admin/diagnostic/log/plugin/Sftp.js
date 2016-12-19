// require("js/omv/grid/column/WhiteSpace.js")
// require("js/omv/module/admin/diagnostic/log/plugin/Plugin.js")

Ext.define("OMV.module.admin.diagnostic.log.plugin.sftp.Syslog", {
	extend: "OMV.module.admin.diagnostic.log.plugin.Plugin",
	alias: "omv.plugin.diagnostic.log.sftp.syslog",
	requires: [
		"OMV.grid.column.WhiteSpace"
	],

	id: "sftp",
	text: _("SFTP"),
	stateful: true,
	stateId: "da26708e-9212-11e6-8222-0002b3a176b4",
	isLogDeletable: false,
	columns: [{
		text: _("Date & Time"),
		sortable: true,
		dataIndex: "rownum",
		stateId: "date",
		renderer: function(value, metaData, record) {
			return record.get("date");
		}
	},{
		text: _("Hostname"),
		hidden: true,
		sortable: true,
		dataIndex: "hostname",
		stateId: "hostname"
	},{
		xtype: "whitespacecolumn",
		text: _("Message"),
		sortable: true,
		dataIndex: "message",
		stateId: "message",
		flex: 1
	}],
	rpcParams: {
		id: "sftp"
	},
	rpcFields: [
		{ name: "rownum", type: "int" },
		{ name: "ts", type: "int" },
		{ name: "date", type: "string" },
		{ name: "hostname", type: "string" },
		{ name: "message", type: "string" }
	]
});
