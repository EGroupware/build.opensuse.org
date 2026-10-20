# egroupware-docker package tests

Run the package install in a systemd container with docker-in-docker, on the native platform of the host (`linux/arm64` on Apple Silicon, `linux/amd64` on x86 hosts and CI, `PLATFORM=...` overrides it).
The package installs Docker itself, exactly as on a fresh server, so the test machine has no Docker preinstalled.

    ./run-test.sh ubuntu-24.04 install      # distros: ubuntu-26.04 -24.04 -22.04, debian-13 -12, rocky-10 -9, opensuse-16.1 -16.0
    KEEP=1 ./run-test.sh debian-13          # keep machine: docker exec -it egw-test-debian-13 bash
    WEBSERVER=apache ./run-test.sh ubuntu-24.04       # installs apache2 (httpd on RHEL) too, Nginx must then not be pulled in
    NO_RECOMMENDS=1 ./run-test.sh ubuntu-24.04

Recommends (egroupware-collabora-key) are installed as per wiki, on arm64 it switches to Collabora's CODE image. NO_RECOMMENDS=1 skips it. Rocketchat has no arm64 image and is not tested yet.
OBS builds egroupware-docker for aarch64 on Ubuntu 22.04/24.04/26.04 and Debian 12/13 only, other distros can only be tested on amd64.

The guest install script exports `COMPOSE_PROGRESS=plain`, so the postinst's `docker compose pull/up` logs plain lines instead of animated bars in `docker logs`. The package itself is unchanged.

## Manual steps (Debian/Ubuntu), keep in sync with the wiki
Source: [Installation using EGroupware docker RPM DEB package](https://github.com/EGroupware/egroupware/wiki/Installation-using-EGroupware-docker-RPM-DEB-package),
[Distribution specific instructions](https://github.com/EGroupware/egroupware/wiki/Distribution-specific-instructions).
`guest/install-deb.sh` automates exactly this:

1. add repo `deb http://download.opensuse.org/repositories/server:/eGroupWare/<xUbuntu_24.04|Debian_13>/ /`
2. `apt install gnupg`, import `Release.key` into `/etc/apt/trusted.gpg.d/server:eGroupWare.asc`, `apt update`
3. `apt install egroupware-docker` (optionally `apache2` too, or `--no-install-recommends`)
4. credentials of the first admin are in `/var/lib/egroupware/egroupware-docker-install.log`

## Success criteria (`guest/verify.sh`, extend there)
- docker enabled+active, `docker compose` (v2 plugin) available
- `/etc/egroupware-docker/docker-compose{,.override}.yml`, install log and `header.inc.php` exist
- containers egroupware, egroupware-db, egroupware-push, egroupware-nginx, egroupware-watchtower running
- `http://localhost/egroupware/login.php` returns 200 through the host webserver
- web server: default installs Nginx and not Apache, `WEBSERVER=apache` installs Apache and not Nginx
- egroupware-collabora-key (unless NO_RECOMMENDS): compose uses collabora/code:latest on arm64 (quay.io/egroupware/collabora-key:stable on amd64), container runs it, `/hosting/discovery` answers on 127.0.0.1:9980 and through the host webserver
- installation actually succeeded: `egroupware-docker-install.log` says `EGroupware successful installed`, is mode 600 and holds passwords of `admin` and `sysop`;
  `sysop` can list `/egroupware/groupdav.php/addressbook-accounts/` via REST (JSON, contains the default `Admin User` account of sysop), `principals/users/sysop/` exists, a wrong password gets 401;
  the request is found in the host webserver's access log (host Nginx -> egroupware-nginx container on 127.0.0.1:8080 -> PHP-FPM) and the container answers directly too
- setup user `admin` can authenticate with the logged password via `setup/setup-cli.php --config default,admin` (exit 0), a wrong password is rejected
- accounts in the database (`mysql.sh`) are exactly users `sysop`, `anonymous` and groups `Admins`, `Default`, `NoGroup`, `Teachers`

## Limits on a Mac (Docker Desktop with Rosetta)
- amd64 containers cannot run newer systemd: Rosetta does not implement the `pidfd_open` syscall, which systemd 255 and later needs (Ubuntu 24.04+, Debian 13, Rocky 10, openSUSE Leap 16). Rocky 9, Ubuntu 22.04 and Debian 12 boot.
- The inner Docker of Debian 12 fails under Rosetta (`runc create failed`), Collabora's LibreOfficeKit fails to install its seccomp filter. Use native arm64 here and amd64 in CI.
- every test machine has its own docker+containerd volumes with all images (several GB), `run-test.sh` aborts if less than `MIN_FREE_GB` (20) are free on the host disk.

## CI: `.github/workflows/package-tests.yml`
Runs natively on amd64 on every push to `egroupware-docker-26` or `egroupware-collabora-key` of `server:eGroupWare` (not for `.osc` changes only), and manually.
- `plan.sh` selects the distros: the 2 latest Debian and Ubuntu releases and only the latest Rocky and openSUSE Leap, manual runs can select any (or all), and which packages the commit changed.
- `wait-for-obs.py` waits until OBS has built exactly the source revision of the commit (`srcmd5` from `.osc/_files`) and published it in all needed repos (plus a few minutes for the mirrors), then the install jobs run (each distro with Nginx and with Apache).
- **Commit to git only after `osc commit`**, otherwise `.osc/_files` has the old source revision and the tests run on the old packages.

## Todo
update N -> N+1; Rocket.Chat; SELinux enforcing and firewalld on the RPM distros; Leap 15.x and SLE 15.
