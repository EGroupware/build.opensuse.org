# egroupware-docker package tests

Run the package install in a systemd container with docker-in-docker, on the native platform of the host (`linux/arm64` on Apple Silicon, `linux/amd64` on x86 hosts and CI, `PLATFORM=...` overrides it).
The package installs Docker itself, exactly as on a fresh server, so the test machine has no Docker preinstalled.

    ./run-test.sh ubuntu-24.04 install      # distros: ubuntu-26.04 -24.04 -22.04, debian-13 -12, rocky-10 -9, opensuse-16.1 -16.0
    KEEP=1 ./run-test.sh debian-13          # keep machine: docker exec -it egw-test-debian-13 bash
    WEBSERVER=apache ./run-test.sh ubuntu-24.04       # installs apache2 (httpd on RHEL) too, Nginx must then not be pulled in
    NO_RECOMMENDS=1 ./run-test.sh ubuntu-24.04
    ROCKETCHAT=1 ./run-test.sh rocky-10               # also egroupware-rocketchat with OAuth integration into EGroupware (Nginx, own CA for egw.test, see guest/tls.sh)
    ROCKETCHAT=1 RC_OVERLAY=<package dir> ./run-test.sh rocky-10   # test files of an unreleased package version over the published package
    GUACAMOLE=1 ./run-test.sh rocky-10               # also egroupware-guacamole with OpenID login via EGroupware (Nginx, own CA like ROCKETCHAT=1)
    MAIL=1 ./run-test.sh ubuntu-24.04                # also egroupware-mail (Dovecot and Postfix), plain http, no own CA needed
    MAIL=1 MAIL_PKG=<file.rpm> ./run-test.sh rocky-10   # install this package file instead of the published one (noarch RPM, tests an unpublished spec)

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

- Rocket.Chat (`ROCKETCHAT=1`): containers running, API through the webserver, admin from `.env` can log in, custom OAuth service exists with the right settings,
  EGroupware user `sysop` can log in via OAuth (authorize, code exchange over https with the injected CA, login, user created). Prints the Rocket.Chat version and image, as it uses a running tag.
  Rocket.Chat only builds amd64 images, on arm64 it runs emulated, the deb packages are not built for arm64, so locally only the RPM distros work.
- Guacamole (`GUACAMOLE=1`): containers running, override file with the domain and a random DB password, app installed in EGroupware, OpenID client with the right redirect URI,
  DB user can see the `guacamole_*` tables, API through the webserver, and the whole OpenID login of `sysop` (Guacamole asks EGroupware, EGroupware issues an id_token without consent,
  Guacamole validates it with the keys fetched via https: `guest/guacamole.sh` puts the own CA into a Java truststore and resolves `egw.test` via `extra_hosts`).
- Mail (`MAIL=1`): containers running, certificate, DB user `mail` with a random password in all configs, `dovecot` master user and the "EGroupware Mail" account created, the three postfix
  mysql maps answer (no TLS or DB errors in the postfix log), IMAPS login of `sysop` with the EGroupware password, and a mail sent to port 25 arrives in `sysop`'s INBOX.
  The package and the Dovecot image are amd64 only: on arm64 the amd64 deb is forced onto the machine (only the first part of the checks), and Dovecot dies under Rosetta
  (`rosetta error: mmap_anonymous_rw mmap failed`), so the IMAP and delivery checks are skipped there and only run on x86_64 (CI).

## Limits on a Mac (Docker Desktop with Rosetta)
- amd64 containers cannot run newer systemd: Rosetta does not implement the `pidfd_open` syscall, which systemd 255 and later needs (Ubuntu 24.04+, Debian 13, Rocky 10, openSUSE Leap 16). Rocky 9, Ubuntu 22.04 and Debian 12 boot.
- The inner Docker of Debian 12 fails under Rosetta (`runc create failed`), Collabora's LibreOfficeKit fails to install its seccomp filter. Use native arm64 here and amd64 in CI.
- every test machine has its own docker+containerd volumes with all images (several GB), `run-test.sh` aborts if less than `MIN_FREE_GB` (20) are free on the host disk.

## CI: `.github/workflows/package-tests.yml`
Runs natively on amd64 on every push to `egroupware-docker-26`, `egroupware-collabora-key`, `egroupware-rocketchat`, `egroupware-guacamole` or `egroupware-mail` of `server:eGroupWare` (not for `.osc` changes only), and manually.
- `plan.sh` selects the distros: the 2 latest Debian and Ubuntu releases and only the latest Rocky and openSUSE Leap, manual runs can select any (or all), and which packages the commit changed.
  Commits to `egroupware-docker-26` or `egroupware-collabora-key` run the install tests with Nginx and with Apache, commits to `egroupware-rocketchat` or `egroupware-guacamole` run
  their tests (`ROCKETCHAT=1` / `GUACAMOLE=1`, Nginx only, not on openSUSE: its package installs Apache by default and `guest/tls.sh` needs Nginx), commits to `egroupware-mail` the mail tests
  (`MAIL=1`, Debian and Ubuntu only until the RPM is published and its OBS repos are enabled).
  A manual run chooses with `test`: `install`, `rocketchat`, `guacamole`, `mail` or `all`, and tests what is currently published.
  Every job of the matrix has a `kind` (base, rocketchat, guacamole, mail), a distro and a web server; a kind without matching distro gives no job.
- `wait-for-obs.py` waits until OBS has built exactly the source revision of the commit (`srcmd5` from `.osc/_files`) and published it in all needed repos of the package (`--pkg PACKAGE=SRCMD5:REPO,REPO` restricts them, eg. mail only waits for the Debian and Ubuntu repos; plus a few minutes for the mirrors), then the install jobs run (each distro with Nginx and with Apache).
- **Commit to git only after `osc commit`**, otherwise `.osc/_files` has the old source revision and the tests run on the old packages.

## Todo
update N -> N+1; Apache and SUSE in `guest/tls.sh` (then Rocket.Chat and Guacamole on openSUSE); mail on the RPM distros once published; the mail test against `postfix:mysql-3.10.10`; SELinux enforcing and firewalld on the RPM distros; Leap 15.x and SLE 15.
