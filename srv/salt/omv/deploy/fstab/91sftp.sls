{% set config = salt['omv_conf.get']('conf.service.sftp') %}
{% set ns = namespace(option='') %}
{% for share in config.shares.share %}
{% set sfpath = salt['omv_conf.get_sharedfolder_path'](share.sharedfolderref) %}
{% set sfpath2 = sfpath | escape_blank %}
{% set sf_config = salt['omv_conf.get']('conf.system.sharedfolder', share.sharedfolderref) %}
{% set sftppath = '/sftp/' + share.username + '/' + sf_config.name | escape_blank %}
{% set ns.option = '' %}
{% for privilege in sf_config.privileges.privilege | selectattr('name', 'equalto', share.username) %}
{% if privilege.perms == 5 %}
{% set ns.option = 'bind,ro,nofail' %}
{% elif privilege.perms == 7 %}
{% set ns.option = 'bind,rw,nofail' %}
{% endif %}
{% endfor %}

{% if ns.option != "" %}
create_sftp_mountpoint_{{ share.uuid }}:
  file.accumulated:
    - filename: "/etc/fstab"
    - text: "{{ sfpath2 }}\t\t{{ sftppath }}\tnone\t{{ ns.option }}\t0 0"
    - require_in:
      - file: append_fstab_entries

mount_sftp_mountpoint_{{ share.uuid }}:
  mount.mounted:
    - name: {{ sftppath }}
    - device: {{ sfpath }}
    - fstype: "none"
    - opts: {{ ns.option }}
    - mkmnt: True
    - persist: False
    - mount: True
{% else %}

{% if salt['file.directory_exists'](sftppath) %}
unmount_sftp_mountpoint_{{ share.uuid }}:
  cmd.run:
    - name: "umount --lazy --quiet '{{ sftppath }}'"
    - check_cmd:
      - /usr/bin/true

remove_openmediavault_dir_{{ share.uuid }}:
  cmd.run:
    - name: "rmdir '{{ sftppath }}'"
{% endif %}

{% endif %}
{% endfor %}
