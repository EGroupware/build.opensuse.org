Name: egroupware-docker
Version: 20.1.20201005
Release:
Summary: EGroupware is a web-based groupware suite written in php
Group: Web/Database
License: GPLv2 or (at your option) any later version
URL: http://www.egroupware.org/EPL
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# EGroupware data directory stays on the host
%define egwdatadir /var/lib/egroupware
# ancient package name
%define egw_packagename eGroupware
# old (17.1 and before) package name
%define old_name egroupware-epl

# create with: tar -czvf egroupware-docker-20.1.20201005.tar.gz egroupware-docker
Source: %{name}-%{version}.tar.gz

# some defines in case we want to build it for an other distro
%define etc_dir /etc/egroupware-docker
%define nginx_app_dir /etc/nginx/app.d

%if 0%{?suse_version}
	%define apache_conf_d /etc/apache2/conf.d
	%define apache_vhosts_d /etc/apache2/vhosts.d
	%define apache_user wwwrun
	%define apache_group www
	%define apache_service apache2
Requires: httpd
# rpm version in SLE 12 does not support suggests
%if 0%{?sle_version} >= 150000
Suggests: nginx
%endif
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
# recommend Collabora for (open)SUSE
Recommends: egroupware-collabora-key
%else
	%define apache_conf_d /etc/httpd/conf.d
	%define apache_vhosts_d /etc/httpd/conf.d
	%define apache_user apache
	%define apache_group apache
	%define apache_service httpd
    %define apache_extra mod_ssl
Requires: webserver
# rpm version in RHEL/CentOS 7 does not support suggests
%if 0%{?centos_version} >= 800 || 0%{?rhel_version} >= 800
Suggests: nginx
%endif
%endif

Buildarch: noarch
AutoReqProv: no

# RHEL/CentOS 8 no longer provides docker
%if 0%{?centos_version} >= 800 || 0%{?rhel_version} >= 800
Requires: docker-ce >= 1.12
%else
#disabled to allow docker-ce too, we still require docker-compose
#Requires: docker >= 1.12
%endif
Requires: docker-compose >= 1.10.0
Requires: patch
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
%{etc_dir}/create-override.sh
case "$1" in
  1)# This is an initial install.
	# enable and start docker
	systemctl enable docker
	systemctl is-active --quiet docker || systemctl start docker

	# set up Nginx and reload it
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		# initial install: enable egroupware and disable default site
		ln -fs ../../egroupware-docker/nginx.conf /etc/nginx/conf.d/egroupware.conf
		[ -d /etc/nginx/app.d ] || mkdir /etc/nginx/app.d
		# at least openSUSE does not have proxy_params
		[ -f /etc/nginx/proxy_params ] || cat <<EOF > /etc/nginx/proxy_params
proxy_set_header Host \$http_host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
EOF
		# enable and (re)start nginx
		systemctl enable nginx
		systemctl restart nginx
	fi

	# set up Apache by patch include /etc/egroupware-docker/apache.conf into all vhosts
	if [ -d %{apache_vhosts_d} ]
	then
		cd %{apache_vhosts_d}
		for conf in $(grep -ril '<VirtualHost ' .)
		do [ -z "$(grep '/etc/egroupware-docker/apache.conf' $conf)" ] && \
			sed -i 's|</VirtualHost>|\t# EGroupware proxy needs to be included inside vhost\n\tinclude /etc/egroupware-docker/apache.conf\n\n</VirtualHost>|g' $conf && \
			echo "Include /etc/egroupware-docker/apache.conf added to site $conf"
		done

		systemctl enable %{apache_service}
		# openSUSE/SLES require proxy modules to be enabled first, RHEL/CentOS does not require nor have a2enmod
		[ -x /usr/sbin/a2enmod ] && {
			a2enmod rewrite
			a2enmod proxy
			a2enmod proxy_http
			a2enmod proxy_wstunnel
			a2enmod headers
		}
		systemctl restart %{apache_service}
	fi

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

	# fix or create empty /root/.docker/config.json
	mkdir -p /root/.docker
	test -d /root/.docker/config.json && rm -rf /root/.docker/config.json
	test -f /root/.docker/config.json || echo "{}" > /root/.docker/config.json

	# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wirded state!)
	cd %{etc_dir}
	test -f docker-compose.override.yml || /bin/bash create-override.sh
	# start only egroupware container first, as we need to copy push sources to sources volume before starting push server
	echo "y" | docker-compose up -d egroupware && sleep 5 && \
	echo "y" | docker-compose up -d || true
	;;

  2)# This is an upgrade.
	# we might not have all required apache modules enabled for openSUSE/SLE, if comming from 17.1
	if [ -d %{apache_vhosts_d} -a -x /usr/sbin/a2enmod ]
	then
		a2enmod rewrite
		a2enmod proxy
		a2enmod proxy_http
		a2enmod proxy_wstunnel
		a2enmod headers
		systemctl restart %{apache_service}
	fi
	# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wirded state!)
	cd %{etc_dir}
	test -f docker-compose.override.yml || /bin/bash create-override.sh
	docker-compose pull && \
	# start only egroupware container first, as we need to copy push sources to sources volume before starting push server
	echo "y" | docker-compose up -d egroupware && sleep 5 && \
	echo "y" | docker-compose up -d || true
	;;
esac
# get our addition to docker unit working in case MariaDB/MySQL runs an update
systemctl daemon-reload

%preun
case "$1" in
  0)# This is an un-installation.
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		rm -f /etc/nginx/conf.d/egroupware.conf
		nginx -s reload
	fi
    if [ -d %{apache_vhosts_d} ]
    then
		cd %{apache_vhosts_d}
		for conf in $(grep -li 'include /etc/egroupware-docker/apache.conf' *.conf)
		do
			sed -i 's|\t# EGroupware proxy needs to be included inside vhost\n\tinclude /etc/egroupware-docker/apache.conf||g' $conf && \
				echo "Include /etc/egroupware-docker/apache.conf removed from site $conf"
		done
		rm %{apache_conf_d}/egroupware-docker.conf
		systemctl restart %{apache_service}
	fi
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
egroupware/egroupware:latest, phpswoole/swoole:latest and nginx:stable-alpine.

It also uses containrrr/watchtower (https://github.com/containrrr/watchtower) to automatic
use new versions of its containers everyday at 4am, if a new version is available.

%prep
%setup -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT%{etc_dir}
install -m 644 docker-compose.yml $RPM_BUILD_ROOT%{etc_dir}
install -m 644 docker-compose.yml $RPM_BUILD_ROOT%{etc_dir}/latest-docker-compose.yml
install -m 644 docker-compose.override.yml $RPM_BUILD_ROOT%{etc_dir}/latest-docker-compose.override.yml
install -m 644 mariadb.cnf $RPM_BUILD_ROOT%{etc_dir}/mariadb.cnf
install -m 644 apache.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 644 nginx.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 644 egroupware-nginx.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 755 use-epl.sh $RPM_BUILD_ROOT%{etc_dir}
install -m 755 mysql.sh $RPM_BUILD_ROOT%{etc_dir}
install -m 755 create-override.sh $RPM_BUILD_ROOT%{etc_dir}
install -m 755 egroupware-logs.sh $RPM_BUILD_ROOT%{etc_dir}
mkdir -p $RPM_BUILD_ROOT%{nginx_app_dir}
install -m 644 nginx-egroupware-push.conf $RPM_BUILD_ROOT%{nginx_app_dir}/egroupware-push.conf
install -m 644 nginx-phpmyadmin.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 644 phpmyadmin.yml $RPM_BUILD_ROOT%{etc_dir}
mkdir -p $RPM_BUILD_ROOT/usr/share/egroupware/doc/rpm-build
install -m 755 post_install.php $RPM_BUILD_ROOT/usr/share/egroupware/doc/rpm-build/
# tell systemd to start docker after MariaDB
mkdir -p $RPM_BUILD_ROOT/etc/systemd/system/docker.service.d
install -m 755 docker-egroupware.conf $RPM_BUILD_ROOT/etc/systemd/system/docker.service.d/egroupware.conf

mkdir -p $RPM_BUILD_ROOT%{apache_conf_d}
ln -s %{etc_dir}/apache.conf $RPM_BUILD_ROOT%{apache_conf_d}/egroupware-docker.conf
%if "%{apache_conf_d}" != "%{apache_vhosts_d}"
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
%{etc_dir}/latest-docker-compose.yml
%{etc_dir}/latest-docker-compose.override.yml
%config(noreplace) %{etc_dir}/mariadb.cnf
%{etc_dir}/use-epl.sh
%{etc_dir}/create-override.sh
%{etc_dir}/egroupware-logs.sh
%{nginx_app_dir}
%config(noreplace) %{nginx_app_dir}/egroupware-push.conf
%config(noreplace) %{egwdatadir}/header.inc.php
%{apache_conf_d}
%if "%{apache_conf_d}" != "%{apache_vhosts_d}"
%{apache_vhosts_d}
%endif
/usr/share/egroupware/doc/rpm-build/post_install.php
/etc/systemd/system/docker.service.d/egroupware.conf
