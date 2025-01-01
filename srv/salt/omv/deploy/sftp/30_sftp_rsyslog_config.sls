# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2025 openmediavault plugin developers
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
    - mode: 644

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

delete_dev_log_and_empty_dev_directory:
  cmd.run:
    - name: rm -f /sftp/*/dev/log || true

delete_dev_directory:
  cmd.run:
    - name: rmdir /sftp/*/dev || true

restart_rsyslog_service_sftp2:
  service.running:
    - name: rsyslog
    - enable: True
    - watch:
      - file: remove_omv_sftp_rsyslog_config

{% endif %}

