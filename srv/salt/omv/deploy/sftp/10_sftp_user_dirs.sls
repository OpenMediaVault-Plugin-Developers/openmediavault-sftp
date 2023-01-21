# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2023 OpenMediaVault Plugin Developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

configure_sftp_root_dir:
  file.directory:
    - name: "/sftp"
    - user: root
    - group: root
    - mode: 755

{% set config = salt['omv_conf.get']('conf.service.sftp') %}
{% set existingNames = [] %}
{% for share in config.shares.share %}
{% if share.username not in existingNames %}
configure_sftp_user_dir_{{ share.username }}:
  file.directory:
    - name: "/sftp/{{ share.username }}"
    - user: root
    - group: root
    - mode: 755
    - makedirs: True
{% set _ = existingNames.append(share.username) %}
{% endif %}
{% endfor %}

