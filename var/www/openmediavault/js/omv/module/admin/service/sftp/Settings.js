/**
 *
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2009-2016 Volker Theile
 * @copyright Copyright (c) 2016-2020 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
// require("js/omv/WorkspaceManager.js")
// require("js/omv/workspace/form/Panel.js")

/**
 * @class OMV.module.admin.service.sftp.Settings
 * @derived OMV.workspace.form.Panel
 */
Ext.define("OMV.module.admin.service.sftp.Settings", {
    extend: "OMV.workspace.form.Panel",

    rpcService: "SFTP",
    rpcGetMethod: "getSettings",
    rpcSetMethod: "setSettings",

    getFormItems: function() {
        return [{
            xtype: "checkbox",
            name: "enable",
            fieldLabel: _("Enable"),
            checked: false
        },{
            xtype: "numberfield",
            name: "port",
            fieldLabel: _("Port"),
            vtype: "port",
            minValue: 1,
            maxValue: 65535,
            allowDecimals: false,
            allowBlank: false,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Port number. Choose a different one from the default ssh server")
            }]
        },{
            xtype: "checkbox",
            name: "passwordauthentication",
            fieldLabel: _("Password authentication"),
            checked: true,
            boxLabel: _("Enable keyboard-interactive authentication")
        },{
            xtype: "checkbox",
            name: "pubkeyauthentication",
            fieldLabel: _("Public key authentication"),
            checked: true,
            boxLabel: _("Enable public key authentication")
        },{
            xtype: "checkbox",
            name: "allowgroups",
            fieldLabel: _("AllowGroups"),
            checked: false,
            boxLabel: _("Allow access to sftp-access group only")
        },{
            xtype: "textarea",
            name: "extraoptions",
            fieldLabel: _("Extra options"),
            allowBlank: true,
            plugins: [{
                ptype: "fieldinfo",
                text: _("Please check the <a href='http://www.openbsd.org/cgi-bin/man.cgi?query=sshd_config&sektion=5' target='_blank'>manual page</a> for more details."),
            }]
        }];
    }
});

OMV.WorkspaceManager.registerPanel({
    id: "settings",
    path: "/service/sftp",
    text: _("Settings"),
    position: 10,
    className: "OMV.module.admin.service.sftp.Settings"
});
