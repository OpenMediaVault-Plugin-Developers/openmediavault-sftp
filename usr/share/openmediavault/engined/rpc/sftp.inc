<?php
/**
 * Copyright (C) 2009-2013 Volker Theile <volker.theile@openmediavault.org>
 * Copyright (C) 2013-2026 openmediavault plugin developers
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
        $objectSF = $db->get('conf.system.sharedfolder', $params['sharedfolderref']);
        // The 'dev' directory inside the chroot is used for the rsyslog
        // socket, a shared folder mounted there would collide with it.
        if ('dev' === $objectSF->get('name')) {
            throw new \OMV\Exception(
                "A shared folder named 'dev' can not be used for SFTP.");
        }
        $perms = $this->getEffectivePerms($objectSF, $params['username']);
        if (($perms !== 5) && ($perms !== 7)) {
            throw new \OMV\Exception(
                "'%s' does not have read only or read/write privileges to this shared folder.",
                $params['username']
            );
        }
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.sftp.share');
        $object->setAssoc($params);
        // Ensure the user/shared folder pair is unique. This prevents
        // duplicate entries that would also result in duplicate fstab
        // bind mounts.
        $db->assertIsUniqueByFilter($object, [
            "operator" => "and",
            "arg0" => [
                "operator" => "stringEquals",
                "arg0" => "username",
                "arg1" => $object->get("username")
            ],
            "arg1" => [
                "operator" => "stringEquals",
                "arg0" => "sharedfolderref",
                "arg1" => $object->get("sharedfolderref")
            ]
        ], sprintf(
            gettext("An SFTP share for the user '%s' and this shared folder already exists."),
            $object->get("username")
        ));
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

    private function getEffectivePerms($sfObject, $username)
    {
        if (TRUE === $sfObject->isEmpty('privileges')) {
            return 0;
        }
        $user = new \OMV\System\User($username);
        $groups = $user->exists() ? $user->getGroups() : [];
        if (!is_array($groups)) {
            $groups = [];
        }
        $result = 0;
        foreach ($sfObject->get('privileges.privilege') as $objectv) {
            $matches = ((('user' === $objectv['type']) &&
                ($objectv['name'] === $username)) ||
                (('group' === $objectv['type']) &&
                in_array($objectv['name'], $groups, TRUE)));
            if (!$matches) {
                continue;
            }
            $perms = intval($objectv['perms']);
            if (0 === $perms) {
                return 0;
            }
            $result = max($result, $perms);
        }
        return $result;
    }
}
