Name: egroupware-collabora-key
Version: 24.04.20240908
Release:
Summary: Collabora Online Office with support-key
Group: Web/Database
License: MPL-2.0
URL: https://www.collaboraoffice.com/terms/collabora-online-mplv2/
Vendor: EGroupware GmbH, https://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# create with: tar -czvf egroupware-collabora-key-24.04.20240908.tar.gz egroupware-collabora-key
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
    %define apache_package apache2
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
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
%if "%{?apache_extra}" != ""
# require mod_ssl, but only if Apache is used (an unconditional Requires would force Apache over Nginx), so we can patch include of Collabora proxy into it
Requires: (%{apache_extra} if httpd)
%endif

%post
# prefer the docker compose (v2) plugin, only fall back to the old docker-compose script (does not exist on eg. Rocky 10)
COMPOSE="docker compose"
docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"
case "$1" in
  1)# This is an initial install.
	# enable and start docker
	systemctl enable docker
	systemctl is-active --quiet docker || systemctl start docker

	# Set up Nginx: our proxy is included by EGroupware's nginx.conf from /etc/nginx/app.d
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		[ -d /etc/nginx/app.d ] || mkdir /etc/nginx/app.d
		ln -fs ../../egroupware-collabora-key/nginx.conf /etc/nginx/app.d/egroupware-collabora-key.conf
		nginx -s reload || true
	fi

	# Apache is only touched, if its service exists (the package owns %{apache_vhosts_d}, so the directory always exists)
	if [ -d %{apache_vhosts_d} ] && systemctl cat %{apache_service}.service >/dev/null 2>&1
	then
	# patch include /etc/egroupware-collabora-key/apache.conf into all vhosts
	cd %{apache_vhosts_d}
	for conf in $(grep -ril '<VirtualHost ' .)
	do [ -z "$(grep '/etc/egroupware-collabora-key/apache.conf' $conf)" ] && \
		sed -i 's|</VirtualHost>|\t# Collabora proxy needs to be included inside vhost\n\tinclude /etc/egroupware-collabora-key/apache.conf\n\n</VirtualHost>|g' $conf && \
		echo "Include /etc/egroupware-collabora-key/apache.conf added to site $conf"
	done

	# openSUSE Leap 16.1+: /srv/www/htdocs is a ghost file of the apache2 package, which systemd-tmpfiles only creates at the end of the transaction,
	# Apache does not start without it, so create it now (mid-transaction, as only at the end of it our restart would be too early)
	[ -f /usr/lib/tmpfiles.d/apache2.conf ] && systemd-tmpfiles --create /usr/lib/tmpfiles.d/apache2.conf || true
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
	# collabora-key image is amd64 only: on arm64 ONLY switch to Collabora's CODE image (without support-key)
	case "$(uname -m)" in
	aarch64|arm64)
		sed -i 's|^\( *image: *\)"quay.io/egroupware/collabora-key:stable"|\1"collabora/code:latest"|' docker-compose.yml
		;;
	esac
	echo "y" | $COMPOSE up -d || true
	;;

  2)# This is an upgrade.

	# (re-)start our containers (do NOT fail as it leaves package in a wired state)
	cd %{etc_dir}
	# collabora-key image is amd64 only: on arm64 ONLY switch to Collabora's CODE image (without support-key)
	case "$(uname -m)" in
	aarch64|arm64)
		sed -i 's|^\( *image: *\)"quay.io/egroupware/collabora-key:stable"|\1"collabora/code:latest"|' docker-compose.yml
		;;
	esac
	$COMPOSE pull && \
	echo "y" | $COMPOSE up -d || true
	;;
esac

%preun
# prefer the docker compose (v2) plugin, only fall back to the old docker-compose script (does not exist on eg. Rocky 10)
COMPOSE="docker compose"
docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"
case "$1" in
  0)# This is an un-installation.
	if [ -d /etc/nginx -a -x /usr/sbin/nginx ]
	then
		rm -f /etc/nginx/app.d/egroupware-collabora-key.conf
		nginx -s reload || true
	fi
	if [ -d %{apache_vhosts_d} ] && systemctl cat %{apache_service}.service >/dev/null 2>&1
	then
	cd %{apache_vhosts_d}
	for conf in $(grep -li 'include /etc/egroupware-collabora-key/apache.conf' *.conf)
	do
		sed -i 's|\t# Collabora proxy needs to be included inside vhost\n\tinclude /etc/egroupware-collabora-key/apache.conf||g' $conf && \
			echo "Include /etc/egroupware-collabora-key/apache.conf removed from site $conf"
	done
	rm -f %{apache_conf_d}/egroupware-collabora-key.conf
	systemctl restart %{apache_service}
	fi
	cd %{etc_dir}
	$COMPOSE rm -fs
	;;

  1)# This is an upgrade.
    # if we have no separate coolwsd.xml created it now, but patch in termination and support_key from loolwsd.xml
    test ! -s /var/lib/egroupware/default/loolwsd/coolwsd.xml -a -f /var/lib/egroupware/default/loolwsd/coolwsd.xml.rpmnew && {
        cd /etc/egroupware-collabora-key
        $COMPOSE stop
        $COMPOSE rm -f
        # if we are not using the current docker-compose.yml, mv it in place, but keep extra_hosts
        test -f docker-compose.yml.rpmnew && {
        (echo; grep -A2 '^ *extra_hosts:' docker-compose.yml | grep -v '^ *#') >> docker-compose.yml.rpmnew
        mv docker-compose.yml docker-compose.yml.rpmold
        mv docker-compose.yml.rpmnew docker-compose.yml
        } || true
        cd /var/lib/egroupware/default/loolwsd
        mv coolwsd.xml.dpkg-dist coolwsd.xml
        grep '<termination .*>true</termination>' loolwsd.xml &&
            sed 's#>false</termination>#>true</termination>#' -i /var/lib/egroupware/default/loolwsd/coolwsd.xml || true
        grep '<support_key>.*</support_key>' loolwsd.xml &&
            sed "s#<support_key></support_key>#<support_key>$(grep '<support_key>.*</support_key>' /var/lib/egroupware/default/loolwsd/loolwsd.xml|sed 's/^ *//')</support_key>#" \
                -i /var/lib/egroupware/default/loolwsd/coolwsd.xml || true
    } || true
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
install -m 644 coolwsd.xml $RPM_BUILD_ROOT%{etc_loolwsd}
install -m 444 coolkitconfig.xcu $RPM_BUILD_ROOT%{etc_loolwsd}
install -m 444 *.pem $RPM_BUILD_ROOT%{etc_loolwsd}

mkdir -p $RPM_BUILD_ROOT%{apache_conf_d}
ln -s %{etc_dir}/apache.conf $RPM_BUILD_ROOT%{apache_conf_d}/egroupware-collabora-key.conf
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
%attr(0755,%{apache_user},%{apache_group}) %{etc_loolwsd}
%config(noreplace) %attr(0644,%{apache_user},%{apache_group}) %{etc_loolwsd}/loolwsd.xml
%config(noreplace) %attr(0644,%{apache_user},%{apache_group}) %{etc_loolwsd}/loolkitconfig.xcu
%config(noreplace) %attr(0644,%{apache_user},%{apache_group}) %{etc_loolwsd}/coolwsd.xml
%config(noreplace) %attr(0644,%{apache_user},%{apache_group}) %{etc_loolwsd}/coolkitconfig.xcu