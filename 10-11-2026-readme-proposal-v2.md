# VPS Bootstrap (Ubuntu 24.04)

Interactive first-time setup for a **new** Ubuntu 24.04 VPS. It creates a sudo
user, configures SSH and UFW, installs Fail2ban and Docker, and starts Telemt
and 3x-ui. The script is intentionally split into preparation and SSH
finalization so that you can verify a real login before disabling root login.

The script refuses to take over an existing user, Telemt directory, 3x-ui
container or SSH drop-in. It is not an in-place upgrade tool for an earlier
vps-bootstrap installation.

## Before you start

- Have a working console or recovery access from the VPS provider.
- Save a provider snapshot or backup.
- Keep the current SSH session open throughout setup.
- Ensure the provider's external firewall will allow the new SSH port
  `4422/tcp` and Telemt port `1243/tcp`.
- Have a public SSH key and a domain to use for Telemt TLS masking.
- Review the downloaded script before running it as root.

## Installation

On the VPS, from the existing root SSH session:

```bash
curl -fsSLo /tmp/vps-bootstrap.sh https://raw.githubusercontent.com/birdset/vps-bootstrap/main/bootstrap.sh
less /tmp/vps-bootstrap.sh
bash /tmp/vps-bootstrap.sh --prepare
```

The script asks for the new user name, public key, and Telemt TLS domain.
Preparation creates the user and key, then opens the old and new SSH ports.
It does **not** disable the old SSH login or install containers yet.

On your **local computer**, open a second terminal. Keep the first session open:

```bash
ssh -p 4422 <user>@<server-address>
```

In the **new VPS session**, verify that `sudo -v` works. Only then run:

```bash
sudo bash /tmp/vps-bootstrap.sh --finalize --confirm-ssh-login
```

Finalization installs the remaining services. Open one more new SSH session on
port 4422 before closing the original session.
If the login fails, use the original session or provider console to inspect
`/etc/ssh/sshd_config.d/00-vps-bootstrap.conf`, `sshd -t`, `sshd -T`,
`ufw status`, and the provider firewall.

## What the installer changes

- Creates a new sudo user and adds the supplied public key.
- Adds a managed SSH drop-in. Preparation listens on the original and new
  ports. Finalization disables root and password SSH login and checks the
  effective sshd settings.
- Opens only the existing SSH port, 4422/tcp and 1243/tcp in UFW. It enables
  UFW if it was inactive. It does not reset existing rules.
- Adds a managed Fail2ban SSH jail.
- Installs Docker from Docker's official apt repository if Docker is absent.
  It refuses to uninstall conflicting packages automatically. It does not run
  `apt upgrade` or add the new user to the root-equivalent `docker` group.
  Use `sudo docker` instead.
- Starts Telemt in Docker Compose. Its secret configuration and installation
  log are restricted to root. The loopback API requires a random authorization
  header; its connection link is not printed to the log.
- Starts 3x-ui without `--privileged`. It uses host networking; open only the
  panel and proxy ports you actually configure. Its bundled Fail2ban is
  disabled because it needs host network administration capabilities. Keep
  the panel blocked by UFW until you configure a suitable access policy.
- Resolves each container image to a digest at first pull and records that
  digest for later runs. Review the selected digest before using this script
  in production.
- Installs a per-client Telemt SYN limiter in a dedicated `VPS-TELEMT`
  chain attached to Docker's `DOCKER-USER` chain. The rule is IPv4 only.
- Adds two aliases without clearing an existing `~/.bash_aliases` file.

State is kept under `/var/lib/vps-bootstrap`; the installation log is
`/var/log/vps-bootstrap.log`. The state and log are root-readable only.
Do not edit the state files by hand.

Docker-published ports bypass ordinary UFW input rules. Inspect published
ports with `sudo docker ps` and test from a separate network.

## Safe cleanup

Download the cleanup script to a local file on the VPS:

```bash
curl -fsSLo /tmp/vps-unbootstrap.sh https://raw.githubusercontent.com/birdset/vps-bootstrap/main/unbootstrap.sh
less /tmp/vps-unbootstrap.sh
sudo bash /tmp/vps-unbootstrap.sh --dry-run
```

Review the exact list. To proceed:

```bash
sudo bash /tmp/vps-unbootstrap.sh --apply
```

The cleanup requires you to type `CLEANUP`. It stops managed services,
removes managed containers and configuration files, and restores the original
SSH configuration by removing the managed drop-in. It keeps the original SSH
port allowed until a fresh login is verified.

**Data remains intact:** the user, Docker engine, packages, images, volumes,
`/opt/telemt`, `/etc/x-ui`, `/usr/local/x-ui`, and installation state are
retained. This is safe cleanup, not a full restoration of the original OS
image. Restore a provider snapshot for a full rollback. Never remove the
remaining user until another administrative login has been tested.

## Validation before production use

On Ubuntu 24.04, run `bash -n` and ShellCheck on both scripts. In an isolated
test VPS, check fresh installation, second-session SSH login, finalization,
repeat preparation, failure during each stage, cleanup, and a host that had
Docker and UFW before installation. Verify the existing containers and their
data survive cleanup.
