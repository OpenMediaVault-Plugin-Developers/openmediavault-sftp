# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2026 openmediavault plugin developers
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

{% set config = salt['omv_conf.get']('conf.service.sftp') %}
{% set rsyslogConf = salt['pillar.get']('default:OMV_SFTP_RSYSLOGCONF', '/etc/rsyslog.d/openmediavault-sftp.conf') -%}

{% if config.rsyslog | to_bool %}

configure_omv_sftp_rsyslog_config:
  file.managed:
    - name: {{ rsyslogConf }}
    - source:
      - salt://{{ tpldir }}/files/omv_sftp_rsyslog_config.j2
    - template: jinja
    - context:
        config: {{ config.shares.share | json }}
    - user: root
    - group: root
    - mode: '0644'

restart_rsyslog_service_sftp1:
  service.running:
    - name: rsyslog
    - enable: True
    - watch:
      - file: configure_omv_sftp_rsyslog_config

{% else %}

remove_omv_sftp_rsyslog_config:
  file.absent:
    - name: {{ rsyslogConf }}

# Only remove the rsyslog sockets and their directories. Skip a 'dev'
# directory that is a mount point, it is a shared folder holding user data.
delete_dev_log_and_empty_dev_directory:
  cmd.run:
    - name: >-
        for d in /sftp/*/dev; do
        mountpoint -q "${d}" && continue;
        [ -S "${d}/log" ] && rm -f "${d}/log";
        rmdir "${d}" 2>/dev/null;
        done; true
    - onlyif: >-
        for d in /sftp/*/dev; do
        [ -d "${d}" ] && ! mountpoint -q "${d}" && exit 0;
        done; exit 1

restart_rsyslog_service_sftp2:
  service.running:
    - name: rsyslog
    - enable: True
    - watch:
      - file: remove_omv_sftp_rsyslog_config

{% endif %}

