# Switching to SSH Key Auth and Disabling Root Password Login

Steps to harden SSH access on the server by switching from password authentication to SSH key authentication and disabling password login for root.

## 1. Generate an SSH key on your local machine (skip if you have one)

```
ssh-keygen -t ed25519 -C "adronhall@proton.me"
```

Press Enter to accept the default path (`~/.ssh/id_ed25519`) and set a passphrase when prompted.

## 2. Copy your public key to the server

```
ssh-copy-id root@74.208.68.132
```

This appends your public key to `/root/.ssh/authorized_keys` on the server.

## 3. Verify key-based login works

Open a **new** terminal (keep your current root session open as a safety net) and test:

```
ssh root@74.208.68.132
```

You should log in without being asked for the server password. **Do not proceed until this works** — otherwise you'll lock yourself out.

## 4. Harden sshd config

On the server, edit `/etc/ssh/sshd_config`:

```
sudo vi /etc/ssh/sshd_config
```

Set (or add) these lines:

```
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
```

`prohibit-password` allows root login *only* via key. If you'd rather block root entirely (recommended once you have a non-root sudo user), set `PermitRootLogin no` instead.

## 5. Check for override files

Some distros (Ubuntu in particular) ship drop-in configs that re-enable password auth:

```
sudo grep -r "PasswordAuthentication" /etc/ssh/sshd_config.d/ /etc/ssh/sshd_config
```

If any file sets `PasswordAuthentication yes`, change it to `no` or delete the line.

## 6. Test the config before reloading

```
sudo sshd -t
```

Silent output = OK. Any errors, fix them before continuing.

## 7. Reload sshd

```
sudo systemctl reload sshd
```

(Use `reload`, not `restart` — reload won't drop your current session if something's wrong.)

## 8. Final verification

From your local machine, open yet another terminal and confirm:

```
ssh root@74.208.68.132          # should succeed via key
ssh -o PubkeyAuthentication=no root@74.208.68.132   # should be rejected
```

If both behave as expected, you're done. Keep your original root session open until you're sure.

## Optional but recommended

- Create a non-root sudo user and disable root SSH entirely (`PermitRootLogin no`).
- Install `fail2ban` to throttle brute-force attempts.
- Change SSH port from 22 to something non-standard (reduces noise, not a real security measure).
