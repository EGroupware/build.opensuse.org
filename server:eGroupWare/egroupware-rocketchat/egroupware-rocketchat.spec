Name: egroupware-rocketchat
Version: 2.3.20191128
Release:
Summary: Rocket.Chat container for EGroupware
Group: Web/Database
License: MIT
URL: https://rocket.chat
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# create with: tar -czvf egroupware-rocketchat-1.2.20190709.tar.gz egroupware-rocketchat
Source: %{name}-%{version}.tar.gz

# some defines in case we want to build it for an other distro
%define etc_dir /etc/egroupware-rocketchat

%if 0%{?suse_version}
	%define apache_conf_d /etc/apache2/conf.d
	%define apache_vhosts_d /etc/apache2/vhosts.d
	%define apache_user wwwrun
	%define apache_group www
	%define apache_service apache2
    %define apache_package apache2
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
Requires: net-tools-deprecated
%else
	%define apache_conf_d /etc/httpd/conf.d
	%define apache_vhosts_d /etc/httpd/conf.d
	%define apache_user apache
	%define apache_group apache
	%define apache_service httpd
    %define apache_package httpd
    %define apache_extra mod_ssl
%endif

Buildarch: noarch
AutoReqProv: no

Requires: docker >= 1.12
Requires: docker-compose
Requires: %{apache_package} >= 2.4
%if "%{?apache_extra}" != ""
# require mod_ssl so we can patch include of Rocket.Chat proxy into it
Requires: %{apache_extra}
%endif

%post
case "$1" in
  1)# This is an initial install.
	# enable and start docker
	systemctl enable docker
	systemctl status docker || systemctl start docker

	# patch include /etc/egroupware-rocketchat/apache.conf into all vhosts
	cd %{apache_vhosts_d}
	for conf in $(grep -ril '<VirtualHost ' .)
	do [ -z "$(grep '/etc/egroupware-rocketchat/apache.conf' $conf)" ] && \
		sed -i 's|</VirtualHost>|\t# Rocket.Chat proxy needs to be included inside vhost\n\tinclude /etc/egroupware-rocketchat/apache.conf\n\n</VirtualHost>|g' $conf && \
		echo "Include /etc/egroupware-rocketchat/apache.conf added to site $conf"
	done

	systemctl enable %{apache_service}
	# openSUSE/SLES require proxy modules to be enabled first, RHEL/CentOS does not require nor have a2enmod
	[ -x /usr/sbin/a2enmod ] && {
		a2enmod proxy
		a2enmod proxy_http
		a2enmod proxy_wstunnel
		a2enmod rewrite
	}
	systemctl restart %{apache_service}

	# patch docker-compose.yml with our primary IP (of interface with default route)
	sed -i %{etc_dir}/docker-compose.yml \
		-e "s#ROOT_URL=.*#ROOT_URL=http://$(ifconfig $(netstat -rn|grep ^0.0.0.0|head -1|sed 's/^.* \(.*\)$/\1/g')|grep 'inet '|sed -En 's/.*inet ([0-9.]+).*/\1/p')/rocketchat#g"

	# start our containers (do NOT fail package installation on error, as this leaves package in a wirded state!)
	cd %{etc_dir}
	docker-compose up -d || true
	;;

  2)# This is an upgrade.
	# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wirded state!)
	cd %{etc_dir}
	docker-compose pull && \
	docker-compose up -d || true
	;;
esac

%preun
case "$1" in
  0)# This is an un-installation.
	cd %{apache_vhosts_d}
	for conf in $(grep -li 'include /etc/egroupware-rocketchat/apache.conf' *.conf)
	do
		sed -i 's|\t# Rocket.Chat proxy needs to be included inside vhost\n\tinclude /etc/egroupware-rocketchat/apache.conf||g' $conf && \
			echo "Include /etc/egroupware-rocketchat/apache.conf removed from site $conf"
	done
	rm %{apache_conf_d}/egroupware-rocketchat.conf
	systemctl restart %{apache_service}
	cd %{etc_dir}
	docker-compose rm -fs
	;;

  1)# This is an upgrade.
    # Do nothing.
    :
  ;;
esac

%description
This package installs Docker and docker-compose and use it to run Rocket.Chat
via the container rocketchat/rocket.chat:latest.

It also uses v2tec/watchtower (https://github.com/v2tec/watchtower) to automatic
use new versions of its containers everyday at 4am, if a new version is available.

%prep
%setup -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT%{etc_dir}
install -m 644 docker-compose.yml $RPM_BUILD_ROOT%{etc_dir}
install -m 644 apache.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 644 nginx.conf $RPM_BUILD_ROOT%{etc_dir}

mkdir -p $RPM_BUILD_ROOT%{apache_conf_d}
ln -s %{etc_dir}/apache.conf $RPM_BUILD_ROOT%{apache_conf_d}/egroupware-rocketchat.conf
%if "%{apache_conf_d}" != "%{apache_vhost_d}"
mkdir -p $RPM_BUILD_ROOT%{apache_vhosts_d}
%endif

%files
%defattr(-,root,root)
%{etc_dir}
%config(noreplace) %{etc_dir}/apache.conf
%config(noreplace) %{etc_dir}/nginx.conf
%config(noreplace) %{etc_dir}/docker-compose.yml
%{apache_conf_d}
%if "%{apache_conf_d}" != "%{apache_vhost_d}"
%{apache_vhosts_d}
%endif
