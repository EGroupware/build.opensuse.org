Name: egroupware-rocketchat
Version: 5.4.20230524
Release:
Summary: Rocket.Chat container for EGroupware
Group: Web/Database
License: MIT
URL: https://rocket.chat
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# create with: tar -czvf egroupware-rocketchat-5.4.20230524.tar.gz egroupware-rocketchat
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
Requires: jq
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

# RHEL/CentOS 8 no longer provides docker
%if 0%{?centos_version} >= 800 || 0%{?rhel_version} >= 800
Requires: docker-ce >= 1.12
%else
#disabled to allow docker-ce too, we still require docker-compose
#Requires: docker >= 1.12
%endif
Requires: docker-compose >= 1.10.0
Requires: %{apache_package} >= 2.4
%if "%{?apache_extra}" != ""
# require mod_ssl so we can patch include of Rocket.Chat proxy into it
Requires: %{apache_extra}
%endif

%post
# change owner of Rocket.Chat data-directory to 65533 used by container
chown -R 65533:65533 /var/lib/egroupware/default/rocketchat

case "$1" in
  1)# This is an initial install.
	# enable and start docker
	systemctl enable docker
	systemctl status docker || systemctl start docker

	cd %{etc_dir}
	# create docker-compose.override.yml from latest-docker-compose.override.yml
    cp latest-docker-compose.override.yml docker-compose.override.yml

    # if HTTP_HOST given, patch docker-compose.override.yml with it and install and integrate Rocket.Chat into EGroupware
	test -z "$HTTP_HOST" || {
		sed -i %{etc_dir}/docker-compose.override.yml \
			-e "s#ROOT_URL=.*#ROOT_URL=https://${HTTP_HOST}/rocketchat#g"
		./install-rocketchat.sh
	}
    # otherwise use our primary IP (of interface with default route) and leave installation to Rocket.Chat itself
    test -n "$HTTP_HOST" || \
	sed -i %{etc_dir}/docker-compose.override.yml \
		-e "s#ROOT_URL=.*#ROOT_URL=http://$(ifconfig $(netstat -rn|grep ^0.0.0.0|head -1|sed 's/^.* \(.*\)$/\1/g')|grep 'inet '|sed -En 's/.*inet ([0-9.]+).*/\1/p')/rocketchat#g"

	# start our containers (do NOT fail package installation on error, as this leaves package in a wirded state!)
	echo "y" | docker-compose up -d || true

	# Set up web server and reload it.
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		# initial install: enable egroupware and disable default site
		if [ -z "$2" ]
		then
			[ -d /etc/nginx/app.d ] || mkdir /etc/nginx/app.d
			ln -fs ../../egroupware-rocketchat/nginx.conf /etc/nginx/app.d/egroupware-rocketchat.conf
		fi
		nginx -s reload
	fi
	if [ -d /etc/apache2 -a -x /usr/sbin/a2enmod ]
	then
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
	fi
	;;

  2)# This is an upgrade.
	cd %{etc_dir}
	# if we dont have it, create docker-compose.override.yml
    test -f docker-compose.override.yml || {
      # if we have modifications in docker-compose.yml update created a docker-compose.yml.rpmnew
      test docker-compose.yml.rpmnew -nt docker-compose.yml && {
         # use current docker-compose.yml as .override
         sed "s|version:'2'|version:'3'|" docker-compose.yml > docker-compose.override.yml
         # disabling a couple of settings, which would break with MongoDB 5.0 and Rocket.Chat 5.4
         sed -i  docker-compose.override.yml \
          -e "s|^\( *\)\(- MONGO_.*\)$|\1#\2|" \
          -e "s|^\( *\)\(image: *mongo:.*\)$|\1#\2|" \
          -e "s|^\( *\)\(command: *mongod.*\)$|\1#\2|"
         # and move new .rpmnew in place
         mv docker-compose.yml.rpmnew docker-compose.yml
      } || \
      # otherwise create it from latest-docker-compose.override
      cp latest-docker-compose.override.yml docker-compose.override.yml
    }
    # if docker-compose.yml.rpmnew exists and is newer than docker-compose.yml --> replace it
    test docker-compose.yml.rpmnew -nt docker-compose.yml && {
      mv docker-compose.yml.rpmnew docker-compose.yml
    } || true
    # update to MongoDB to 5.0
    ./update-mongodb.sh 5.0 && {
      # on success: disable image overwrite, to get quay.io/egroupware/rocket.chat:latest from docker-compose.yml
      sed 's/^\( *\)\(image: *.*rocket.chat.*\)$/\1#\2/g' -i docker-compose.override.yml
      # remove mongo service overwrites, as docker-compose.yml has everything for 5.0
      sed -e '/^ *mongo:/,+99d' docker-compose.override.yml
    } || {
      # on failure: set old "stable" image, as the new one does NOT support MongoDB 4.0
      sed 's|^\( *\)#*\(image: *.*rocket.chat.*\)$|\1image: quay.io/egroupware/rocket.chat:stable|g' -i docker-compose.override.yml
    }
	# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wired state!)
	docker-compose pull && \
	echo "y" | docker-compose up -d || true
	;;
esac

%preun
case "$1" in
  0)# This is an un-installation.
	if [ -d /etc/apache2 -a -x /usr/sbin/a2enmod ]
	then
		cd /etc/apache2/sites-available
		for conf in $(grep -li 'include /etc/egroupware-rocketchat/apache.conf' *.conf)
		do
			sed -i 's|\t# Rocket.Chat proxy needs to be included inside vhost\n\tinclude /etc/egroupware-rocketchat/apache.conf||g' $conf && \
				echo "Include /etc/egroupware-rocketchat/apache.conf removed from site $conf"
		done
		webserver_soft_reload apache2
	fi
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		rm -f /etc/nginx/app.d/egroupware-rocketchat.conf
		nginx -s reload
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
This package installs Docker and docker-compose and use it to run Rocket.Chat
via the container quay.io/egroupware/rocket.chat:stable.

%prep
%setup -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT%{etc_dir}
install -m 644 docker-compose.yml $RPM_BUILD_ROOT%{etc_dir}
install -m 644 docker-compose.override.yml $RPM_BUILD_ROOT%{etc_dir}/latest-docker-compose.override.yml
install -m 644 apache.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 644 nginx.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 700 install-rocketchat.sh $RPM_BUILD_ROOT%{etc_dir}
install -m 700 update-mongodb.sh $RPM_BUILD_ROOT%{etc_dir}
install -m 644 mongodump-rocketchat-5.4.gz $RPM_BUILD_ROOT%{etc_dir}
mkdir -p $RPM_BUILD_ROOT/var/lib/egroupware/default/rocketchat/uploads

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
%{etc_dir}/latest-docker-compose.override.yml
%{apache_conf_d}
%if "%{apache_conf_d}" != "%{apache_vhost_d}"
%{apache_vhosts_d}
%endif
/var/lib/egroupware/default/rocketchat/uploads