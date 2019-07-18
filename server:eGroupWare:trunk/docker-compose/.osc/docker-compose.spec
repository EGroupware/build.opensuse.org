Name: docker-compose
Version: 1.24.0
Release:
Summary: Define and run multi-container applications with Docker
#Group: Web/Database
License: Apache-2.0
URL: http://www.egroupware.org/EPL
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

Source: %{name}-%{version}.tar.gz
#Source0: docker-compose

AutoReqProv: no

Requires: docker >= 18.06.1

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
