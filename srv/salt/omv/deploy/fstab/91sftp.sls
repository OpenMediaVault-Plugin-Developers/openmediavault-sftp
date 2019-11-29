{% set config = salt['omv_conf.get']('conf.service.sftp') %}

{% for share in config.shares.share %}
{% set sfpath = salt['omv_conf.get_sharedfolder_path'](share.sharedfolderref) %}
{% set sfpath2 = sfpath | replace(' ', '\\040') %}
{% set sf_config = salt['omv_conf.get']('conf.system.sharedfolder', share.sharedfolderref) %}
{% set sftppath = '/sftp/' + share.username + '/' + sf_config.name | escape_blank %}
{% set option = '' %}
{% for privilege in sf_config.privileges.privilege | selectattr('name', 'equalto', share.username) %}
{% if privilege.perms == 5 %}
{% set option = 'bind,ro,nofail' %}
{% elif privilege.perms == 7 %}
{% set option = 'bind,rw,nofail' %}
{% endif %}
{% endfor %}

{% if option != "" %}
create_sftp_mountpoint_{{ share.uuid }}:
  file.accumulated:
    - filename: "/etc/fstab"
    - text: "{{ sfpath2 }}\t\t{{ sftppath }}\tnone\t{{ option }}\t0 0"
    - require_in:
      - file: append_fstab_entries

mount_sftp_mountpoint_{{ share.uuid }}:
  mount.mounted:
    - name: {{ sftppath }}
    - device: {{ sfpath }}
    - fstype: "none"
    - opts: {{ option }}
    - mkmnt: True
    - persist: False
    - mount: True
{% else %}
unmount_sftp_mountpoint_{{ share.uuid }}:
  mount.unmounted:
    - name: {{ sftppath }}
    - device: {{ sfpath }}
    - persist: True

remove_openmediavault_dir_{{ share.uuid }}:
  file.absent:
    - name: {{ sftppath }}
{% endif %}
{% endfor %}
