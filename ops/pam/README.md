# MRBS-backed PAM check for SSH password login

This directory provides a minimal PAM integration that allows SSH login only when the user has an active MRBS booking for the target VM.

## Files

- `mrbs_ssh_booking_check.sh`: PAM `account` checker script.
- `mrbs_ssh_booking_check.cnf.example`: MySQL client credentials template.
- `mrbs_pam.env.example`: policy and VM mapping variables.
- `mrbs_vm_access_map.my.sql`: helper table mapping VM hostnames to MRBS room IDs.

## 1) Create DB objects and read-only DB user

Run SQL as a DB admin:

```sql
SOURCE ops/pam/mrbs_vm_access_map.my.sql;

CREATE USER IF NOT EXISTS 'mrbs_ro'@'localhost' IDENTIFIED BY 'strong-password';
GRANT SELECT ON mrbs.mrbs_entry TO 'mrbs_ro'@'localhost';
GRANT SELECT ON mrbs.mrbs_participants TO 'mrbs_ro'@'localhost';
GRANT SELECT ON mrbs.mrbs_vm_access_map TO 'mrbs_ro'@'localhost';
FLUSH PRIVILEGES;
```

Insert VM mapping:

```sql
INSERT INTO mrbs_vm_access_map(vm_hostname, room_id) VALUES ('gpu-vm-01', 12);
```

## 2) Install config on the VM host

```bash
sudo install -m 750 ops/pam/mrbs_ssh_booking_check.sh /usr/local/sbin/mrbs_ssh_booking_check.sh
sudo install -m 600 ops/pam/mrbs_ssh_booking_check.cnf.example /etc/security/mrbs-pam.cnf
sudo install -m 600 ops/pam/mrbs_pam.env.example /etc/security/mrbs-pam.env
```

Then edit:

- `/etc/security/mrbs-pam.cnf` with DB credentials.
- `/etc/security/mrbs-pam.env` with `MRBS_DB_NAME`, `MRBS_VM_HOSTNAME`, and `MRBS_POLICY`.

## 3) Hook into PAM for SSH

In `/etc/pam.d/sshd`, add this line in the `account` section before final permit lines:

```pam
account required pam_exec.so quiet /usr/local/sbin/mrbs_ssh_booking_check.sh
```

Ensure SSH uses PAM in `/etc/ssh/sshd_config`:

```text
UsePAM yes
PasswordAuthentication yes
```

Reload sshd after config changes.

## 4) How decision works

Access is allowed when all are true:

- `PAM_USER` equals booking owner (`mrbs_entry.create_by`), or is in participants (if policy is `owner_or_participant`).
- current time is within booking: `start_time <= now < end_time`.
- VM hostname maps to the room through `mrbs_vm_access_map`.

Otherwise login is denied.

## 5) Test

From VM host:

```bash
sudo PAM_USER=alice /usr/local/sbin/mrbs_ssh_booking_check.sh; echo $?
```

- `0` means allow.
- `1` means deny.

Check logs:

```bash
sudo journalctl -t mrbs-pam -n 100 --no-pager
```

## Notes

- This is designed for MySQL-based MRBS.
- For recurring bookings, ensure your MRBS setup creates concrete rows in `mrbs_entry` for active occurrences, or extend logic for `mrbs_repeat` if needed.
- Keep break-glass users in `MRBS_BYPASS_USERS` for emergency access.
