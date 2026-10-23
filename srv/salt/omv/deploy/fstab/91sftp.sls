{% set config = salt['omv_conf.get']('conf.service.sftp') %}
{% set ns = namespace(option='', deny=False, ro=False, rw=False, seen=[], mounted=[]) %}
{% for share in config.shares.share %}
{% set sfpath = salt['omv_conf.get_sharedfolder_path'](share.sharedfolderref) %}
{% set sf_config = salt['omv_conf.get']('conf.system.sharedfolder', share.sharedfolderref) %}
{% set sftppath = '/sftp/' ~ share.username ~ '/' ~ sf_config.name %}
{# Skip shares whose mount target was already emitted to avoid duplicate #}
{# fstab entries and redundant mount states for the same path. #}
{% if sftppath in ns.seen %}
{% continue %}
{% endif %}
{% set ns.seen = ns.seen + [sftppath] %}
{# Get the effective privileges using the same rules as the SMB service: #}
{# 'No access' for the user or one of its groups wins, then read/write, #}
{# then read only. #}
{% set groups = salt['user.list_groups'](share.username) %}
{% set ns.deny = False %}
{% set ns.ro = False %}
{% set ns.rw = False %}
{% for privilege in sf_config.privileges.privilege %}
{% if (privilege.type == 'user' and privilege.name == share.username) or
      (privilege.type == 'group' and privilege.name in groups) %}
{% if privilege.perms | int == 0 %}
{% set ns.deny = True %}
{% elif privilege.perms | int == 7 %}
{% set ns.rw = True %}
{% elif privilege.perms | int == 5 %}
{% set ns.ro = True %}
{% endif %}
{% endif %}
{% endfor %}
{% set ns.option = '' %}
{% if not ns.deny %}
{% if ns.rw %}
{% set ns.option = 'bind,rw,nofail' %}
{% elif ns.ro %}
{% set ns.option = 'bind,ro,nofail' %}
{% endif %}
{% endif %}

{% if ns.option != "" %}
{% set ns.mounted = ns.mounted + [sftppath] %}
{% set sfpath_fstab = sfpath | escape_blank(True) | replace('\\', '\\\\') %}
{% set sftppath_fstab = sftppath | escape_blank(True) | replace('\\', '\\\\') %}
create_sftp_mountpoint_{{ share.uuid }}:
  file.accumulated:
    - filename: "/etc/fstab"
    - text: "{{ sfpath_fstab }}\t\t{{ sftppath_fstab }}\tnone\t{{ ns.option }},x-systemd.requires-mounts-for={{ sfpath_fstab }},x-systemd.before=omv-sftp.service\t0 0"
    - require_in:
      - file: append_fstab_entries

{# Unmount an existing bind mount that has to be recreated: #}
{# - It points to the wrong (e.g. old) location. A bind mount shows up as #}
{#   '<device>[<subdir>]' in findmnt, so compare the device and inode of #}
{#   the mount point root and the shared folder instead. #}
{# - Its read only/read write flag does not match the privileges anymore. #}
{#   mount.mounted does not remount the bind mount in that case. #}
{% set access = ns.option.split(',')[1] %}
unmount_sftp_mountpoint_{{ share.uuid }}:
  cmd.run:
    - name: {{ ('umount --lazy --quiet ' ~ (sftppath | quote)) | json }}
    - onlyif: {{ ('mountpoint -q ' ~ (sftppath | quote) ~ ' && { [ "$(stat -c %d:%i ' ~ (sftppath | quote) ~ ')" != "$(stat -c %d:%i ' ~ (sfpath | quote) ~ ')" ] || [ "$(findmnt -n -o OPTIONS --mountpoint ' ~ (sftppath | quote) ~ ' | cut -d, -f1)" != ' ~ access ~ ' ]; }') | json }}

mount_sftp_mountpoint_{{ share.uuid }}:
  mount.mounted:
    - name: {{ sftppath | json }}
    - device: {{ sfpath | json }}
    - fstype: "none"
    - opts: {{ ns.option }}
    - mkmnt: True
    - persist: False
    - mount: True
    - require:
      - cmd: unmount_sftp_mountpoint_{{ share.uuid }}
{% endif %}
{% endfor %}

{# Unmount and remove mount points that are not configured anymore, e.g. #}
{# after a share has been deleted or modified, a shared folder has been #}
{# renamed or the privileges of the user have been revoked. #}
{% set cleanup_args = ns.mounted | map('quote') | join(' ') %}
cleanup_sftp_mountpoints:
  cmd.run:
    - name: {{ ('omv-sftp-cleanup-mounts ' ~ cleanup_args) | json }}
    - onlyif: {{ ('omv-sftp-cleanup-mounts --check ' ~ cleanup_args) | json }}
