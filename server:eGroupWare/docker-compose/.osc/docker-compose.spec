Name: docker-compose
Version: 1.24.1
Release:
Summary: Define and run multi-container applications with Docker
#Group: Web/Database
License: Apache-2.0
URL: http://www.egroupware.org/EPL
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# create with: tar czvf docker-compose-1.24.1.tar.gz docker-compose
Source: %{name}-%{version}.tar.gz
#Source0: docker-compose

AutoReqProv: no

# docker-compose release-notes (https://docs.docker.com/release-notes/docker-compose/)
# state very little about required docker version, thought it says for 1.22.0:
# Introduced version 3.7 of the docker-compose.yml specification.
# This version requires Docker Engine 18.06.0 or above
%if 0%{?suse_version}
Requires: docker >= 18.06.1
%else # RHEL/CentOS 7
# as current RHEL/CentOS 7 only containers 1.13.1 AND docker-compose 1.24 works with our files
Requires: docker >= 1.13.1
%endif

BuildRequires: curl

%description
Installs docker-compose command - running in a container - from GitHub,
as some distros lack it.

%prep
%setup -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT/usr/bin
install -m 755 docker-compose $RPM_BUILD_ROOT/usr/bin

%files
%defattr(-,root,root)
%attr(0755,root,root)/usr/bin/docker-compose
