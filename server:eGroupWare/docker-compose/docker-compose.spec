Name: docker-compose
Version: 1.18.0
Release:
Summary: Define and run multi-container applications with Docker
#Group: Web/Database
License: Apache-2.0
URL: http://www.egroupware.org/EPL
Vendor: EGroupware GmbH, http://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

#Source: https://github.com/docker/compose/releases/download/%{Version}/docker-compose-Linux-%_target_arch
Source0: docker-compose

AutoReqProv: no

Requires: docker >= 1.12

BuildRequires: curl

%description
Installs docker-compose command - running in a container - from GitHub,
as some distros lack it.

%prep

%build

%install
mkdir -p $RPM_BUILD_ROOT/usr/bin
install -m 755 %{SOURCE0} $RPM_BUILD_ROOT/usr/bin

%files
%defattr(-,root,root)
%attr(0755,root,root)/usr/bin/docker-compose
