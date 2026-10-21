Name: egroupware-guacamole
Version: 1.6.0.20260601
Release:
Summary: Apache Guacamole managed by EGroupware
Group: Web/Database
License: GPL-2.0-or-later
URL: https://github.com/EGroupware/egroupware/wiki/Apache-Guacamole-managed-by-EGroupware
Vendor: EGroupware GmbH, https://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# create with: ./build.sh (the tarball is the content of https://github.com/EGroupware/guacamole, without a top-level directory)
Source: %{name}-%{version}.tar.gz

# some defines in case we want to build it for an other distro
%define etc_dir /etc/egroupware-guacamole
%define src_dir /usr/share/egroupware/guacamole
%define doc_dir /usr/share/doc/egroupware-guacamole
%define data_dir /var/lib/egroupware/default/guacamole

%if 0%{?suse_version}
	%define apache_conf_d /etc/apache2/conf.d
	%define apache_vhosts_d /etc/apache2/vhosts.d
	%define apache_service apache2
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
%else
	%define apache_conf_d /etc/httpd/conf.d
	%define apache_vhosts_d /etc/httpd/conf.d
	%define apache_service httpd
%endif

Buildarch: noarch
AutoReqProv: no

Requires: egroupware-docker >= 19.1.20200409
Requires: (docker-compose-plugin or docker-compose >= 1.10.0)
# prefer Nginx (like for Debian/Ubuntu), unless Apache is already installed or explicitly requested on the command line
%if 0%{?suse_version}
Requires: httpd
# rpm version in SLE 12 does not support suggests, openSUSE Leap 16 has no sle_version
%if 0%{?suse_version} >= 1500
Suggests: nginx
%endif
%else
Requires: webserver
# rpm version in RHEL/CentOS 7 does not support suggests, other RHEL-like distros like Rocky do not define centos_version or rhel_version
%if 0%{?centos_version} != 700 && 0%{?rhel_version} != 700
Suggests: nginx
%endif
%endif
# the password of the database user is generated with openssl
Requires: openssl

%description
This package installs Docker and and use it to run Guacamole in two containers.

Guacamole makes RDP or VNC desktops available via html5 inside EGroupware.
EGroupware supplies account information, authentication via OpenID Connect
and allows to manage connections.

%prep
# the tarball has no top-level directory
%setup -c -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT%{etc_dir}/guacamole-home/extensions
install -D -m 644 doc/docker-compose.yaml $RPM_BUILD_ROOT%{etc_dir}/docker-compose.yaml
install -D -m 644 doc/apache.conf $RPM_BUILD_ROOT%{etc_dir}/apache.conf
install -D -m 644 doc/nginx.conf $RPM_BUILD_ROOT%{etc_dir}/nginx.conf
install -D -m 644 doc/guacamole.properties $RPM_BUILD_ROOT%{etc_dir}/guacamole-home/guacamole.properties

mkdir -p $RPM_BUILD_ROOT%{src_dir}/js
mkdir -p $RPM_BUILD_ROOT%{src_dir}/lang
mkdir -p $RPM_BUILD_ROOT%{src_dir}/src
mkdir -p $RPM_BUILD_ROOT%{src_dir}/setup
mkdir -p $RPM_BUILD_ROOT%{src_dir}/templates/default/images
install -D -m 644 js/* $RPM_BUILD_ROOT%{src_dir}/js/
install -D -m 644 lang/* $RPM_BUILD_ROOT%{src_dir}/lang/
install -D -m 644 src/* $RPM_BUILD_ROOT%{src_dir}/src/
install -D -m 644 setup/* $RPM_BUILD_ROOT%{src_dir}/setup/
install -D -m 644 templates/default/*.xet $RPM_BUILD_ROOT%{src_dir}/templates/default/
install -D -m 644 templates/default/images/* $RPM_BUILD_ROOT%{src_dir}/templates/default/images/

mkdir -p $RPM_BUILD_ROOT%{doc_dir}
install -m 644 README.md $RPM_BUILD_ROOT%{doc_dir}/
install -D -m 644 doc/* $RPM_BUILD_ROOT%{doc_dir}/

mkdir -p $RPM_BUILD_ROOT%{data_dir}/drive
mkdir -p $RPM_BUILD_ROOT%{data_dir}/record

mkdir -p $RPM_BUILD_ROOT%{apache_conf_d}
ln -s %{etc_dir}/apache.conf $RPM_BUILD_ROOT%{apache_conf_d}/egroupware-guacamole.conf

%post
# prefer the docker compose (v2) plugin, only fall back to the old docker-compose script (does not exist on eg. Rocky 10)
COMPOSE="docker compose"
docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"
OVERRIDE=%{etc_dir}/docker-compose.override.yml

case "$1" in
  1)# This is an initial install.
	# create a docker-compose.override.yml file for installation specific changes
	cat <<EOF > $OVERRIDE
#########################################################################################
###
### docker-compose.override.yml file for egroupware-guacamole package
###
### Place all your modifications in this file, instead of /etc/egroupware-guacamole/docker-compose.yaml.
###
### If you want to make some modification / uncomment eg. some enviroment variables, you also have to:
### - uncomment the service eg. "guacamole:", if not already uncommented
### - uncomment the "environment:" section of the service
###
### services:
###   guacamole:
###      environment:
###      - MYSQL_PASSWORD: guacamole-user-password
###
### Please note: indention with space (NOT tabs!) matter in .yml files!
###
##########################################################################################
version: '3'
EOF
	# generate long save hex-only password for guacamole user as docker-compose has problems with special chars!
	password=$(openssl rand -hex 16)
	# MariaDB runs in a container (default since 20.1) or on the host
	MYSQL=mysql
	if test -f /etc/egroupware-docker/.env && grep "'db_host' => 'db'" /var/lib/egroupware/header.inc.php >/dev/null
	then
		. /etc/egroupware-docker/.env
		MYSQL="docker exec -i egroupware-db mariadb -uroot -p$EGW_DB_ROOT_PW"
		# add EGroupware's network to allow to access db container
		# some distros / docker-versions remove the dash from egroupware-docker_default
		egw_network=$(docker network ls|grep -E 'egroupware-?docker_default'|sed 's/ \+/ /g'|cut -d' ' -f2)
		cat <<EOF >> $OVERRIDE
# we need access to networks of egroupware to be able to access the db, if running in a container
networks:
  $egw_network:
    external: true
services:
  guacamole:
    networks:
      - default
      - $egw_network
    environment:
      # MariaDB running as container
      MYSQL_HOSTNAME: db
EOF
	else
		cat <<EOF >> $OVERRIDE
services:
  guacamole:
    environment:
      # MariaDB running on host with bind-address of docker0 interface 172.17.0.1
      MYSQL_HOSTNAME: 172.17.0.1
EOF
		echo "Please make sure the MariaDB or MySQL on the host listens on the docker0 address 172.17.0.1, the bind-address depends on the distribution!"
	fi
	cat <<EOF >> $OVERRIDE
      MYSQL_DATABASE: egroupware
      MYSQL_USER: guacamole
      # guacamole-user-password must NOT contain special chars, eg. use the following to generate a save one: openssl rand -hex 16
      MYSQL_PASSWORD: $password
      # see https://github.com/apache/guacamole-client/blob/master/guacamole-docker/bin/start.sh#L552
      OPENID_AUTHORIZATION_ENDPOINT: https://example.org/egroupware/openid/endpoint.php/authorize
      OPENID_JWKS_ENDPOINT: https://example.org/egroupware/openid/endpoint.php/jwks
      OPENID_ISSUER: https://example.org
      OPENID_CLIENT_ID: guacamole
      OPENID_REDIRECT_URI: https://example.org/guacamole/
    image: guacamole/guacamole:latest
    # set the ip-address of docker0 interface or your docker host AND your official DNS name so Guacamole
    # can access EGroupware without the need to go over your firewall
#   extra_hosts:
#   - "example.org:172.17.0.1"
  guacd:
    image: guacamole/guacd:latest
EOF
	$MYSQL --execute "GRANT ALL on egroupware.* TO guacamole@\`%%\` IDENTIFIED BY '$password'"
	# if domain name specified via HTTP_HOST environment variable, patch it into relevant files
	if [ -n "$HTTP_HOST" ]
	then
		sed -i "s/example.org/$HTTP_HOST/g" $OVERRIDE
	else
		echo "NO HTTP_HOST enviroment variable specified, you need to replace example.org with your fully qualified domain in /etc/egroupware-guacamole/docker-compose.override.yml manually!"
	fi
	;;
esac

# new install AND update from here on
# update docker-compose.override.yml with fixed Guacamole container version to use
test -f $OVERRIDE && sed 's|image: guacamole/\([^:]*\).*|image: guacamole/\1:1.6.0|g' -i $OVERRIDE
# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wired state!)
cd %{etc_dir}
$COMPOSE pull && \
echo "y" | $COMPOSE up -d || true

# Set up Nginx and reload it
if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
then
	if [ "$1" = 1 ]
	then
		[ -d /etc/nginx/app.d ] || mkdir /etc/nginx/app.d
		ln -fs ../../egroupware-guacamole/nginx.conf /etc/nginx/app.d/egroupware-guacamole.conf
	fi
	nginx -s reload || true
fi
# Apache is only touched, if its service exists (the package owns %{apache_vhosts_d}, so the directory always exists)
if [ -d %{apache_vhosts_d} ] && systemctl cat %{apache_service}.service >/dev/null 2>&1
then
	if [ "$1" = 1 ]
	then
		# initial install: add Include /etc/egroupware-guacamole/apache.conf to all vhosts
		cd %{apache_vhosts_d}
		for conf in $(grep -ril '<VirtualHost ' .)
		do
			[ -z "$(grep '/etc/egroupware-guacamole/apache.conf' $conf)" ] && \
				sed -i 's|</VirtualHost>|\t# Guacamole proxy needs to be included inside vhost\n\tinclude /etc/egroupware-guacamole/apache.conf\n\n</VirtualHost>|g' $conf && \
				echo "Include /etc/egroupware-guacamole/apache.conf added to site $conf"
		done
	fi
	# openSUSE/SLES require proxy modules to be enabled first, RHEL/CentOS does not require nor have a2enmod
	[ -x /usr/sbin/a2enmod ] && {
		a2enmod proxy
		a2enmod proxy_http
		a2enmod proxy_wstunnel
		a2enmod rewrite
	}
	systemctl is-active --quiet %{apache_service} && systemctl reload %{apache_service} || true
fi

# install/update EGroupware guacamole app, as post_install.php of egroupware-docker does: restart the egroupware container
# to copy the sources of the app into it, and run the app installation there passing the HTTP_HOST environment variable along
docker restart egroupware && {
	echo -n "Waiting for egroupware container to restart ."
	docker exec egroupware bash -c 'until ps | grep php-fpm >/dev/null; do echo -n "."; sleep 1; done'
	echo
	docker exec -e HTTP_HOST="$HTTP_HOST" egroupware /usr/bin/php /usr/share/egroupware/doc/rpm-build/post_install.php --start_webserver "" --install-update-app guacamole
} || echo "Could not restart the egroupware container, the Guacamole app is NOT installed in EGroupware!"
true

%preun
COMPOSE="docker compose"
docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"

case "$1" in
  0)# This is an un-installation.
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		rm -f /etc/nginx/app.d/egroupware-guacamole.conf
		nginx -s reload || true
	fi
	if [ -d %{apache_vhosts_d} ] && systemctl cat %{apache_service}.service >/dev/null 2>&1
	then
		cd %{apache_vhosts_d}
		for conf in $(grep -li 'include /etc/egroupware-guacamole/apache.conf' *.conf)
		do
			# remove the comment line and the include line (the comment had a typo in some Debian package versions)
			sed -i -e '/# Gu\(a\)\{0,1\}camole proxy needs to be included inside vhost/d' -e '\|include /etc/egroupware-guacamole/apache.conf|d' $conf && \
				echo "Include /etc/egroupware-guacamole/apache.conf removed from site $conf"
		done
		systemctl is-active --quiet %{apache_service} && systemctl reload %{apache_service} || true
	fi
	cd %{etc_dir}
	$COMPOSE stop
	$COMPOSE rm -f
	;;

  1)# This is an upgrade.
	# Do nothing.
	:
	;;
esac
true

%files
%defattr(-,root,root)
%dir %{etc_dir}
%config(noreplace) %{etc_dir}/docker-compose.yaml
%config(noreplace) %{etc_dir}/apache.conf
%config(noreplace) %{etc_dir}/nginx.conf
%dir %{etc_dir}/guacamole-home
%dir %{etc_dir}/guacamole-home/extensions
%config(noreplace) %{etc_dir}/guacamole-home/guacamole.properties
%{src_dir}
%{doc_dir}
%dir %{data_dir}
%dir %{data_dir}/drive
%dir %{data_dir}/record
%{apache_conf_d}/egroupware-guacamole.conf
