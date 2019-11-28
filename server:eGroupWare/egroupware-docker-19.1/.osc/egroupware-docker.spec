Name: egroupware-docker
Version: 19.1.20191119
Release:
Summary: EGroupware is a web-based groupware suite written in php
Group: Web/Database
License: GPLv2 with exception of EPL-functions and esyncpro module, which is proprietary
URL: http://www.egroupware.org/EPL
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# EGroupware data directory stays on the host
%define egwdatadir /var/lib/egroupware
# ancient package name
%define egw_packagename eGroupware
# old (17.1 and before) package name
%define old_name egroupware-epl

# create with: tar -czvf egroupware-docker-19.1.20190822.tar.gz egroupware-docker
Source: %{name}-%{version}.tar.gz

# some defines in case we want to build it for an other distro
%define etc_dir /etc/egroupware-docker

%if 0%{?suse_version}
	%define apache_conf_d /etc/apache2/conf.d
	%define apache_vhosts_d /etc/apache2/vhosts.d
	%define apache_user wwwrun
	%define apache_group www
	%define apache_service apache2
    %define apache_package apache2
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
# recommend MariaDB, Rocket.Chat and Collabora for (open)SUSE
Recommends: mariadb-server, egroupware-rocketchat, egroupware-collabora-key
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

# RHEL/CentOS 8 no longer provides docker
%if 0%{?centos_version} >= 800 || 0%{?rhel_version} >= 800
Requires: docker-ce >= 1.12
%else
Requires: docker >= 1.12
%endif
Requires: docker-compose >= 1.10.0
Requires: %{apache_package} >= 2.4
%if "%{?apache_extra}" != ""
# require mod_ssl so we can patch include of our proxy into it
Requires: %{apache_extra}
%endif

Obsoletes: %{egw_packagename}
Obsoletes: %{egw_packagename}-core
Obsoletes: %{egw_packagename}-egw-pear
Obsoletes: %{egw_packagename}-esync
Obsoletes: %{egw_packagename}-addressbook
Obsoletes: %{egw_packagename}-bookmarks
Obsoletes: %{egw_packagename}-calendar
Obsoletes: %{egw_packagename}-developer_tools
Obsoletes: %{egw_packagename}-emailadmin
Obsoletes: %{egw_packagename}-felamimail
Obsoletes: %{egw_packagename}-filemanager
Obsoletes: %{egw_packagename}-infolog
Obsoletes: %{egw_packagename}-importexport
Obsoletes: %{egw_packagename}-manual
Obsoletes: %{egw_packagename}-news_admin
Obsoletes: %{egw_packagename}-notifications
Obsoletes: %{egw_packagename}-phpbrain
Obsoletes: %{egw_packagename}-phpfreechat
Obsoletes: %{egw_packagename}-phpsysinfo
Obsoletes: %{egw_packagename}-polls
Obsoletes: %{egw_packagename}-projectmanager
Obsoletes: %{egw_packagename}-registration
Obsoletes: %{egw_packagename}-resources
Obsoletes: %{egw_packagename}-sambaadmin
Obsoletes: %{egw_packagename}-sitemgr
Obsoletes: %{egw_packagename}-timesheet
Obsoletes: %{egw_packagename}-tracker
Obsoletes: %{egw_packagename}-wiki
# packages no longer in 14.1
Obsoletes: %{old_name}-felamimail
Obsoletes: %{old_name}-syncml
Obsoletes: %{old_name}-phpsysinfo
Obsoletes: %{old_name}-polls
Obsoletes: %{egw_packagename}-felamimail
Obsoletes: %{egw_packagename}-syncml
Obsoletes: %{egw_packagename}-phpsysinfo
Obsoletes: %{egw_packagename}-polls
# packages no longer in 14.2
Obsoletes: %{old_name}-egw-pear
# packages no longer in 14.3
Obsoletes: %{old_name}-manual
Obsoletes: %{old_name}-developer_tools
# 19.1 egroupware-docker obsolets all (non-deprecated) 17.1 packages
Obsoletes: %{old_name}
Obsoletes: %{old_name}-core
Obsoletes: %{old_name}-functions
Obsoletes: %{old_name}-esync
Obsoletes: %{old_name}-esyncpro
Obsoletes: %{old_name}-bookmarks
Obsoletes: %{old_name}-calendar
Obsoletes: %{old_name}-collabora
Obsoletes: %{old_name}-filemanager
Obsoletes: %{old_name}-infolog
Obsoletes: %{old_name}-importexport
Obsoletes: %{old_name}-jdots
Obsoletes: %{old_name}-mail
Obsoletes: %{old_name}-news_admin
Obsoletes: %{old_name}-notifications
Obsoletes: %{old_name}-phpfreechat
Obsoletes: %{old_name}-projectmanager
Obsoletes: %{old_name}-registration
Obsoletes: %{old_name}-resources
Obsoletes: %{old_name}-sambaadmin
Obsoletes: %{old_name}-timesheet
Obsoletes: %{old_name}-tracker
Obsoletes: %{old_name}-vendor

# not obsolete deprecated packages which still make some sense
#Obsoletes: %{old_name}-phpbrain
#Obsoletes: %{old_name}-sitemgr
#Obsoletes: %{old_name}-wiki
#Obsoletes: %{old_name}-compat

# Provides of former egroupware-epl-core package allowing to install egroupware-epl-{wiki,sitemgr,phpbrain,compat}
Provides: egw-core %{version}
Provides: egw-addressbook %{version}

%post
case "$1" in
  1)# This is an initial install.
	# enable and start docker
	systemctl enable docker
	systemctl is-active --quiet docker || systemctl start docker

	# some distro specific commands
%if 0%{?suse_version}

%else	# RHEL / CentOS
	# enable and start MariaDB, if that's not already done
	systemctl enable mariadb && systemctl status mariadb || systemctl start mariadb
%endif

	# patch include /etc/egroupware-docker/apache.conf into all vhosts
	cd %{apache_vhosts_d}
	for conf in $(grep -ril '<VirtualHost ' .)
	do [ -z "$(grep '/etc/egroupware-docker/apache.conf' $conf)" ] && \
		sed -i 's|</VirtualHost>|\t# EGroupware proxy needs to be included inside vhost\n\tinclude /etc/egroupware-docker/apache.conf\n\n</VirtualHost>|g' $conf && \
		echo "Include /etc/egroupware-docker/apache.conf added to site $conf"
	done

	systemctl enable %{apache_service}
	# openSUSE/SLES require proxy modules to be enabled first, RHEL/CentOS does not require nor have a2enmod
	[ -x /usr/sbin/a2enmod ] && {
		a2enmod proxy
		a2enmod proxy_http
		a2enmod proxy_wstunnel
		a2enmod headers
	}
	systemctl restart %{apache_service}

	# fix permissions in data directory: Ubuntu www-data is uid/gid 33/33
    mkdir -p %{egwdatadir}/default/files/sqlfs
    mkdir -p %{egwdatadir}/default/backup
	chown -R 33:33 %{egwdatadir}

	# if an old /root/egroupware-epl-install.log exists, move it datadir and symlink it
	[ -f /root/egroupware-epl-install.log -a ! -L /root/egroupware-epl-install.log ] && {
		mv /root/egroupware-epl-install.log %{egwdatadir}/egroupware-docker-install.log
		chmod 600 %{egwdatadir}/egroupware-docker-install.log
		chown root %{egwdatadir}/egroupware-docker-install.log
		ln -s %{egwdatadir}/egroupware-docker-install.log /root/egroupware-epl-install.log
	}

	# set correct mysql.sock in docker-compose
%if 0%{?suse_version}
	sed -i 's|- /var/run/mysqld/mysqld.sock:|- /var/run/mysql/mysql.sock:|g' %{etc_dir}/docker-compose.yml
%else # RHEL/CentOS
	sed -i 's|- /var/run/mysqld/mysqld.sock:|- /var/lib/mysql/mysql.sock:|g' %{etc_dir}/docker-compose.yml
%endif

	# fix or create empty /root/.docker/config.json
	mkdir -p /root/.docker
	test -d /root/.docker/config.json && rm -rf /root/.docker/config.json
	test -f /root/.docker/config.json || echo "{}" > /root/.docker/config.json

	# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wirded state!)
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
# get our addition to docker unit working in case MariaDB/MySQL runs an update
systemctl daemon-reload

%preun
case "$1" in
  0)# This is an un-installation.
	cd %{apache_vhosts_d}
	for conf in $(grep -li 'include /etc/egroupware-docker/apache.conf' *.conf)
	do
		sed -i 's|\t# EGroupware proxy needs to be included inside vhost\n\tinclude /etc/egroupware-docker/apache.conf||g' $conf && \
			echo "Include /etc/egroupware-docker/apache.conf removed from site $conf"
	done
	rm %{apache_conf_d}/egroupware-docker.conf
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
This package installs docker and docker-compose and use it to run the container
quay.io/egroupware/egroupware:latest and nginx:stable-alpine.

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
install -m 644 egroupware-nginx.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 755 use-epl.sh $RPM_BUILD_ROOT%{etc_dir}
mkdir -p $RPM_BUILD_ROOT/usr/share/egroupware/doc/rpm-build
install -m 755 post_install.php $RPM_BUILD_ROOT/usr/share/egroupware/doc/rpm-build/
# tell systemd to start docker after MariaDB
mkdir -p $RPM_BUILD_ROOT/etc/systemd/system/docker.service.d
install -m 755 docker-egroupware.conf $RPM_BUILD_ROOT/etc/systemd/system/docker.service.d/egroupware.conf

mkdir -p $RPM_BUILD_ROOT%{apache_conf_d}
ln -s %{etc_dir}/apache.conf $RPM_BUILD_ROOT%{apache_conf_d}/egroupware-docker.conf
%if "%{apache_conf_d}" != "%{apache_vhost_d}"
mkdir -p $RPM_BUILD_ROOT%{apache_vhosts_d}
%endif

mkdir -p $RPM_BUILD_ROOT%{egwdatadir}/default/files/sqlfs
mkdir -p $RPM_BUILD_ROOT%{egwdatadir}/default/backup
install -m 640 header.inc.php $RPM_BUILD_ROOT%{egwdatadir}

%clean
[ "%{buildroot}" != "/" ] && rm -rf %{buildroot}

%files
# Ubuntu www-data is uid/gid 33/33
%dir %attr(0755,33,33) %{egwdatadir}

%defattr(-,root,root)
%{etc_dir}
%config(noreplace) %{etc_dir}/apache.conf
%config(noreplace) %{etc_dir}/nginx.conf
%config(noreplace) %{etc_dir}/egroupware-nginx.conf
%config(noreplace) %{etc_dir}/docker-compose.yml
%{etc_dir}/use-epl.sh
%config(noreplace) %{egwdatadir}/header.inc.php
%{apache_conf_d}
%if "%{apache_conf_d}" != "%{apache_vhost_d}"
%{apache_vhosts_d}
%endif
/usr/share/egroupware/doc/rpm-build/post_install.php
/etc/systemd/system/docker.service.d/egroupware.conf
