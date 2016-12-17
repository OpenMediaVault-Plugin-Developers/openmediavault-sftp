<?php

/**
 * Copyright (C) 2009-2013 Volker Theile <volker.theile@openmediavault.org>
 * Copyright (C) 2013-2016 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVModuleSftp extends \OMV\Engine\Module\ServiceAbstract
    implements \OMV\Engine\Notify\IListener, \OMV\Engine\Module\IServiceStatus
{
    public function getName()
    {
        return 'sftp';
    }

    /**
     * Stop the managed service.
     */
    public function stopService() {
        $systemCtl = new \OMV\System\SystemCtl("omv-sftp");
        $systemCtl->disable(TRUE);
    }

    /**
     * Start the managed service.
     */
    public function startService() {
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.sftp");
        if (TRUE !== $object->get("enable"))
            return;
        $systemCtl = new \OMV\System\SystemCtl("omv-sftp");
        $systemCtl->enable(TRUE);
    }

    public function getStatus()
    {
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.sftp");
        $systemCtl = new \OMV\System\SystemCtl("omv-sftp");
        return array(
            "name" => $this->getName(),
            "title" => gettext("SFTP"),
            "enabled" => $object->get("enable"),
            "running" => $systemCtl->isActive()
        );
    }

    public function applyConfig()
    {
        $cmd = new \OMV\System\Process('omv-mkconf', 'sftp');
        $cmd->setRedirect2to1();
        $cmd->execute();
    }

    final public function onSharedFolder($type, $path, $object)
    {
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $db->existsByProperty('conf.services.sftp.share', 'sharedfolderref', $object['uuid'])) {
            $this->setDirty();
            $this->setDirtyByName('fstab');
        }
    }

    public function bindListeners(\OMV\Engine\Notify\Dispatcher $dispatcher)
    {
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_MODIFY | OMV_NOTIFY_DELETE,
            'org.openmediavault.conf.service.sftp.share',
            [ $this, 'setDirty' ]);
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_DELETE,
            'org.openmediavault.conf.system.filesystem.mountpoint',
            [ $this, 'setDirty' ]);
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            'org.openmediavault.conf.system.sharedfolder',
            [ $this, 'onSharedFolder' ]);
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            'org.openmediavault.conf.system.sharedfolder.privilege',
            [ $this, 'onSharedFolder' ]);
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            'org.openmediavault.conf.service.sftp',
            [ $this, 'setDirty' ]);
    }
}
