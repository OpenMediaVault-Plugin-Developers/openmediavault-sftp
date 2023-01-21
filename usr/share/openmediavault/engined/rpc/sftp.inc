<?php
/**
 * Copyright (C) 2009-2013 Volker Theile <volker.theile@openmediavault.org>
 * Copyright (C) 2013-2023 OpenMediaVault Plugin Developers
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

class OMVRpcServiceSftp extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return 'Sftp';
    }

    public function initialize()
    {
        $this->registerMethod('getSettings');
        $this->registerMethod('setSettings');
        $this->registerMethod('getShareList');
        $this->registerMethod('getShare');
        $this->registerMethod('setShare');
        $this->registerMethod('deleteShare');
    }

    public function getSettings($params, $context) {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.sftp');
        return $object->getAssoc();
    }

    public function setSettings($params, $context) {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.sftp.setsettings');
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.sftp');
        $object->setAssoc($params);
        // Set the configuration object.
        $db->set($object);
        // Remove useless properties from the object.
        $object->remove('shares');
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function getShareList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.sftp.share');
        // Add additional share informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => $objectv) {
            // Add the new property 'sharedfoldername'.
            $objectv->add('sharedfoldername', 'string', gettext("n/a"));
            // Get the shared folder configuration object.
            $sfObject = $db->get('conf.system.sharedfolder',
                $objectv->get('sharedfolderref'));
            // Update the 'sharedfoldername' property.
            $objectv->set('sharedfoldername', $sfObject->get('name'));
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getShare($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.sftp.share', $params['uuid']);
    }

    public function setShare($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.sftp.setshare');
        // Get the shared folder configuration object.
        $db = \OMV\Config\Database::getInstance();
        // Check to see if user has read only or read/write privileges
        // If not, exit with error
        $perms = 0;
        $objectSF = $db->get('conf.system.sharedfolder', $params['sharedfolderref']);
        if (FALSE === $objectSF->isEmpty('privileges')) {
            foreach ($objectSF->get('privileges.privilege') as $objectv) {
                if ($objectv['name'] === $params['username']) {
                    $perms = intval($objectv['perms']);
                    break;
                }
            }
        }
        if (($perms !== 5) && ($perms !== 7)) {
            throw new \OMV\Exception(
                "'%s' does not have read only or read/write privileges to this shared folder.",
                $params['username']
            );
        }
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.sftp.share');
        $object->setAssoc($params);
        // Set the configuration object.
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteShare($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.sftp.share', $params['uuid']);
        // Umount path
        $sfObject = $db->get('conf.system.sharedfolder', $object->get('sharedfolderref'));
        $dirName = sprintf('/sftp/%s/%s', $object->get('username'), $sfObject->get('name'));
        if (file_exists($dirName)) {
            $cmd = sprintf('omv-removesftpmount "%s"', $dirName);
            $process = new \OMV\System\Process($cmd);
            $process->execute($output, $result);
        }
        // Delete the configuration object.
        $db->delete($object);
        // Apply changes immmediately
        \OMV\Rpc\Rpc::call('Config', 'applyChanges', [
            'modules' => [ 'sftp', 'fstab' ],
            'force' => TRUE
        ], $context);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }
}
