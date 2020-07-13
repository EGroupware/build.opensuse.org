Name: egroupware-collabora-key
Version: 4.2.20200713
Release:
Summary: Collabora Online Office with support-key
Group: Web/Database
License: GPLv2
URL: http://www.egroupware.org/EPL
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

Source: %{name}-%{version}.tar.gz
#Source0: docker-compose.yml
#Source1: apache.conf
#Source2: loolwsd.xml
#Source3: loolkitconfig.xcu
#Source4: key.pem
#Source5: cert.pem
#Source6: ca-chain.cert.pem

# some defines in case we want to build it for an other distro
%define etc_dir /etc/egroupware-collabora-key
%define etc_loolwsd /var/lib/egroupware/default/loolwsd

%if 0%{?suse_version}
	%define apache_conf_d /etc/apache2/conf.d
	%define apache_vhosts_d /etc/apache2/vhosts.d
	%define apache_user wwwrun
	%define apache_group www
	%define apache_service apache2
Requires: httpd
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
%else
	%define apache_conf_d /etc/httpd/conf.d
	%define apache_vhosts_d /etc/httpd/conf.d
	%define apache_user apache
	%define apache_group apache
	%define apache_service httpd
Requires: webserver
    %define apache_extra mod_ssl
%endif

Buildarch: noarch
AutoReqProv: no

#disabled to allow docker-ce too, we still require docker-compose
#Requires: docker >= 1.12
Requires: docker-compose >= 1.10.0
%if "%{?apache_extra}" != ""
# require mod_ssl so we can patch include of Collabora proxy into it
Requires: %{apache_extra}
%endif

%post
case "$1" in
  1)# This is an initial install.
	# enable and start docker
	systemctl enable docker
	systemctl is-active --quiet docker || systemctl start docker

	# set up Nginx, if used
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		[ -d /etc/nginx/app.d ] || mkdir /etc/nginx/app.d
		ln -fs ../../egroupware-collabora-key/nginx.conf /etc/nginx/app.d/egroupware-collabora-key.conf
		systemctl enable nginx
		systemctl restart nginx
	fi

	# set up Apache by patch include /etc/egroupware-collabora-key/apache.conf into all vhosts
	if [ -d %{apache_vhosts_d} ]
	then
		# patch include /etc/egroupware-collabora-key/apache.conf into all vhosts
		cd %{apache_vhosts_d}
		for conf in $(grep -ril '<VirtualHost ' .)
		do [ -z "$(grep '/etc/egroupware-collabora-key/apache.conf' $conf)" ] && \
			sed -i 's|</VirtualHost>|\t# Collabora proxy needs to be included inside vhost\n\tinclude /etc/egroupware-collabora-key/apache.conf\n\n</VirtualHost>|g' $conf && \
			echo "Include /etc/egroupware-collabora-key/apache.conf added to site $conf"
		done

		systemctl enable %{apache_service}
		# openSUSE/SLES require proxy modules to be enabled first, RHEL/CentOS does not require nor have a2enmod
		[ -x /usr/sbin/a2enmod ] && {
			a2enmod proxy
			a2enmod proxy_http
			a2enmod proxy_wstunnel
		}
		systemctl restart %{apache_service}
	fi

	# start our containers (do NOT fail as it leaves package in a wired state)
	cd %{etc_dir}
	docker-compose up -d || true
	;;

  2)# This is an upgrade.
	# (re-)start our containers (do NOT fail as it leaves package in a wired state)
	cd %{etc_dir}
	docker-compose pull && \
	docker-compose up -d || true
	;;
esac

%preun
case "$1" in
  0)# This is an un-installation.
	cd %{apache_vhosts_d}
	for conf in $(grep -li 'include /etc/egroupware-collabora-key/apache.conf' *.conf)
	do
		sed -i 's|\t# Collabora proxy needs to be included inside vhost\n\tinclude /etc/egroupware-collabora-key/apache.conf||g' $conf && \
			echo "Include /etc/egroupware-collabora-key/apache.conf removed from site $conf"
	done
	rm %{apache_conf_d}/egroupware-collabora.conf
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
This package installs Docker and docker-compose and use it to run the container
quay.io/egroupware/collabora-key:stable.

It also uses v2tec/watchtower (https://github.com/v2tec/watchtower) to automatic
use new versions of its containers everyday at 4am, if a new version is available.

Support-key can be entered from EGroupware Collabora app into
/var/lib/egroupware/default/loolwsd/loolwsd.xml, which is used as volume for
collabora-key container.

%prep
%setup -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT%{etc_dir}
install -m 644 docker-compose.yml $RPM_BUILD_ROOT%{etc_dir}
install -m 644 apache.conf $RPM_BUILD_ROOT%{etc_dir}
install -m 644 nginx.conf $RPM_BUILD_ROOT%{etc_dir}

mkdir -p $RPM_BUILD_ROOT%{etc_loolwsd}
install -m 644 loolwsd.xml $RPM_BUILD_ROOT%{etc_loolwsd}
install -m 444 loolkitconfig.xcu $RPM_BUILD_ROOT%{etc_loolwsd}
install -m 444 *.pem $RPM_BUILD_ROOT%{etc_loolwsd}

mkdir -p $RPM_BUILD_ROOT%{apache_conf_d}
ln -s %{etc_dir}/apache.conf $RPM_BUILD_ROOT%{apache_conf_d}/egroupware-collabora-key.conf
%if "%{apache_conf_d}" != "%{apache_vhosts_d}"
mkdir -p $RPM_BUILD_ROOT%{apache_vhosts_d}
%endif

%files
%defattr(-,root,root)
%{etc_dir}
%config(noreplace) %{etc_dir}/apache.conf
%config(noreplace) %{etc_dir}/nginx.conf
%config(noreplace) %{etc_dir}/docker-compose.yml
%{apache_conf_d}
%if "%{apache_conf_d}" != "%{apache_vhosts_d}"
%{apache_vhosts_d}
%endif
%attr(0755,%{apache_user},%{apache_group}) %{etc_loolwsd}
%config(noreplace) %attr(0644,%{apache_user},%{apache_group}) %{etc_loolwsd}/loolwsd.xml
