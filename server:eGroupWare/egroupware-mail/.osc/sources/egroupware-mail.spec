Name: egroupware-mail
Version: 2.3.20261021
Release:
Summary: EGroupware Mail: Dovecot and Postfix in containers, integrated into EGroupware
Group: Web/Database
License: MIT
URL: https://github.com/EGroupware/egroupware/wiki/EGroupwareMail
Vendor: EGroupware GmbH, https://www.egroupware.org/
Packager: Ralf Becker <rb@egroupware.org>

# create with: gtar -czvf egroupware-mail-2.3.20261021.tar.gz egroupware-mail
Source: %{name}-%{version}.tar.gz
# only scripts and configuration, no binaries, so the package installs on any architecture
BuildArch: noarch

# some defines in case we want to build it for an other distro
%define etc_dir /etc/egroupware-mail
%define data_dir /var/lib/egroupware-mail

%if 0%{?suse_version}
# disable post build checks: https://en.opensuse.org/openSUSE:Packaging_checks
BuildRequires:	-post-build-checks
# htpasswd to create the password hash of the dovecot master user
Requires: apache2-utils
%else
Requires: httpd-tools
%endif

# only configuration files, but the Dovecot image is amd64 only, so the package is only built for x86_64
Buildarch: noarch
AutoReqProv: no

# egroupware-docker brings docker and the web server, EGroupware runs in its containers and its MariaDB is accessed from the mail containers
Requires: egroupware-docker >= 20.1
Requires: (docker-compose-plugin or docker-compose >= 1.10.0)
# a self-signed certificate is generated with openssl, dh-parameters are downloaded with curl
Requires: openssl
Requires: curl

%description
This package uses Docker and docker compose to run Dovecot (IMAP, POP3, Sieve)
and Postfix (SMTP) in two containers (quay.io/egroupware/dovecot:lua and
quay.io/egroupware/postfix:mysql) and integrates them into EGroupware:
accounts and mail addresses are read from the EGroupware database, and a
"EGroupware Mail" account is created for all users.

%prep
%setup -n %{name}

%build

%install
mkdir -p $RPM_BUILD_ROOT%{etc_dir}/dovecot/conf.d
mkdir -p $RPM_BUILD_ROOT%{etc_dir}/postfix
install -m 644 docker-compose.yml $RPM_BUILD_ROOT%{etc_dir}/
install -m 644 docker-compose.override.yml $RPM_BUILD_ROOT%{etc_dir}/latest-docker-compose.override.yml
# /etc/dovecot: all files with 644, except the ones with credentials or dh-parameters
for f in dovecot/*; do
	[ -f $f ] && install -m 644 $f $RPM_BUILD_ROOT%{etc_dir}/dovecot/
done
install -m 600 dovecot/my.cnf $RPM_BUILD_ROOT%{etc_dir}/dovecot/
install -m 600 dovecot/dh.pem $RPM_BUILD_ROOT%{etc_dir}/dovecot/
install -m 644 dovecot/conf.d/* $RPM_BUILD_ROOT%{etc_dir}/dovecot/conf.d/
# /etc/postfix: same files as the Debian package
for f in main.cf master.cf sasl_password sql-aliases.cf sql-domains.cf sql-mailboxes.cf access aliases aliases.db dynamicmaps.cf generic header_checks main.cf.proto master.cf.proto postfix-files relocated transport virtual; do
	install -m 644 postfix/$f $RPM_BUILD_ROOT%{etc_dir}/postfix/
done
install -m 600 postfix/dh.pem $RPM_BUILD_ROOT%{etc_dir}/postfix/
# dynamic maps (lmdb, mysql, pcre): /etc/postfix of the image is replaced by this directory, without them Postfix can not use the maps
mkdir -p $RPM_BUILD_ROOT%{etc_dir}/postfix/dynamicmaps.cf.d
install -m 644 postfix/dynamicmaps.cf.d/* $RPM_BUILD_ROOT%{etc_dir}/postfix/dynamicmaps.cf.d/
mkdir -p $RPM_BUILD_ROOT%{data_dir}
# created by %post
touch $RPM_BUILD_ROOT%{etc_dir}/certificate.pem
touch $RPM_BUILD_ROOT%{etc_dir}/certificate.key
touch $RPM_BUILD_ROOT%{etc_dir}/docker-compose.override.yml
# all installed config files are config(noreplace), except the generated ones and the template of the override (always replaced)
( cd $RPM_BUILD_ROOT && find .%{etc_dir} -type f ! -name 'certificate.*' ! -name docker-compose.override.yml ! -name latest-docker-compose.override.yml | sed -e 's|^\.|%%config(noreplace) |' ) > %{_builddir}/%{name}-files.lst

%post
# prefer the docker compose (v2) plugin, only fall back to the old docker-compose script (does not exist on eg. Rocky 10)
COMPOSE="docker compose"
docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"
cd %{etc_dir}

case "$1" in
  1)# This is an initial install.
	# generate a self-signed certificate the user can replace later
	openssl req -x509 -newkey rsa:2048 -keyout %{etc_dir}/certificate.key -out %{etc_dir}/certificate.pem -days 3650 -nodes -subj '/CN=localhost'
	chmod 600 %{etc_dir}/certificate.key

	# generate/download new dhparms (if that fails the distributed ones are used)
	curl https://ssl-config.mozilla.org/ffdhe2048.txt > dh.pem && cp dh.pem dovecot/ && cp dh.pem postfix/ || true
	rm -f dh.pem

	# create docker-compose.override.yml from latest-docker-compose.override.yml
	cp latest-docker-compose.override.yml docker-compose.override.yml

	# patch bearer token for push into dovecot/conf.d/14-egroupware-push.conf
	token=$(docker exec egroupware-push cat /var/www/config.inc.php | grep bearer_token | cut -d"'" -f2)
	sed -i "s/Bearer:token/Bearer:$token/" dovecot/conf.d/14-egroupware-push.conf

	# MariaDB runs in a container (default since 20.1) or on the host
	MYSQL=mysql
	if test -f /etc/egroupware-docker/.env && grep "'db_host' => 'db'" /var/lib/egroupware/header.inc.php >/dev/null
	then
		. /etc/egroupware-docker/.env
		MYSQL="docker exec -i egroupware-db mariadb -uroot -p$EGW_DB_ROOT_PW"
	else
		# change MariaDB or MySQL on the host to bind on docker0 address, the config directory depends on the distribution
		if [ -d /etc/my.cnf.d ]
		then
			printf '[mysqld]\nbind-address = 172.17.0.1\n' > /etc/my.cnf.d/egroupware-mail.cnf
			for s in mariadb mysqld mysql; do systemctl is-active --quiet $s && systemctl restart $s && break; done
		else
			echo "Unable to change MariaDB or MySQL to bind on docker0 addresss (172.17.0.1), please do it manually!"
		fi
		# add extra_hosts for db to docker-compose.override.yml
		sed -e 's/^#\(services:\)/\1/g' \
			-e 's/^#\(  mail:\)/\1/g' \
			-e 's/^#\(  smtp:\)/\1/g' \
			-e 's/^#\(    extra_hosts:\)/\1/g' \
			-e 's/^#\(      - "db:172.17.0.1"\)/\1/g' \
			-i docker-compose.override.yml
	fi
	# check EGroupware database is accessible
	if $MYSQL egroupware --execute "SELECT config_value FROM egw_config WHERE config_name='install_id'"
	then
		# create and patch DB credentials
		password=$(openssl rand --hex 16)
		da_password=$(openssl rand --hex 16)
		da_hash=$(htpasswd -nb -B dovecot $da_password|cut -d: -f2)
		for f in dovecot/my.cnf postfix/sql-*.cf; do
			sed -i "s/^user =.*/user = mail/g" $f
			sed -i "s/^password =.*/password = $password/g" $f
		done
		$MYSQL --execute "GRANT SELECT on egroupware.* TO mail@\`%%\` IDENTIFIED BY '$password'"
		cat <<EOF | $MYSQL --force egroupware || true
# create dovecot user (as member of Default group account_id=1)
REPLACE INTO egw_accounts (account_id, account_lid, account_pwd, account_status, account_expires, account_type, account_primary_group)
  VALUES (NULL, 'dovecot', '{crypt}$da_hash', 'A', -1, 'u', -1);
REPLACE INTO egw_acl (acl_appname,acl_location,acl_account,acl_rights)
  SELECT 'phpgw_group','-1',account_id,1 FROM egw_accounts WHERE account_lid='dovecot';
REPLACE INTO egw_addressbook (account_id,contact_owner,n_given,n_family,n_fn,contact_creator,contact_created,contact_modified)
  SELECT account_id,0,'Dovecot','Master','Dovecot Master',0,UNIX_TIMESTAMP(),UNIX_TIMESTAMP() FROM egw_accounts WHERE account_lid='dovecot';
# overwrite mail-account created by setup with new "EGroupware Mail" account and dummy domain "egroupware.local"
REPLACE INTO egw_ea_accounts (acc_id, acc_name, ident_id, acc_imap_host, acc_imap_ssl, acc_imap_port, acc_sieve_enabled, acc_sieve_host, acc_sieve_port, acc_folder_sent, acc_folder_trash, acc_folder_draft, acc_folder_template, acc_smtp_host, acc_smtp_ssl, acc_smtp_port, acc_smtp_type, acc_imap_type, acc_imap_logintype, acc_domain, acc_user_editable, acc_sieve_ssl, acc_modified, acc_modifier, acc_smtp_auth_session, acc_folder_junk, acc_imap_default_quota, acc_imap_timeout, acc_user_forward, acc_folder_archive, acc_further_identities, acc_folder_ham, acc_spam_api)
  VALUES (1,'EGroupware Mail',1,'mail',2,993,1,'mail',4190,'INBOX/Sent','INBOX/Trash','INBOX/Drafts','INBOX/Templates','mail',1,587,'Smtp\\\\Sql','Imap\\\\Dovecot','standard','egroupware.local',0,1,NOW(),5,1,'INBOX/Junk',NULL,NULL,1,'INBOX/Archive',1,NULL,'');
REPLACE INTO egw_ea_valid (acc_id, account_id)
  VALUES (1,0);
REPLACE INTO egw_ea_credentials (acc_id, cred_type, account_id, cred_username, cred_password, cred_pw_enc)
  VALUES (1,8,0,'dovecot',TO_BASE64('$da_password'),0);
# set acc_domain from mail_suffix, if not localhost, otherwise set mail_suffix from acc_domain="egroupware.local"
UPDATE egw_ea_accounts JOIN egw_config ON config_name='mail_suffix' AND config_app='phpgwapi'
  SET acc_domain=config_value WHERE acc_id=1 AND config_value<>'localhost';
REPLACE INTO egw_config (config_app,config_name,config_value)
  SELECT 'phpgwapi','mail_suffix',acc_domain FROM egw_ea_accounts WHERE acc_id=1;
REPLACE INTO egw_config (config_app,config_name,config_value)
  VALUES ('mail','imap_hosts_with_push','mail');
# this is an insert statement on purpose, to fail and keep current content / signature
INSERT IGNORE INTO egw_ea_identities (ident_id, acc_id, ident_realname, ident_email, ident_org, ident_signature, account_id, ident_name)
  VALUES (1,1,'','','','',0,NULL);
EOF
		# restart EGroupware to invalidate cache after updating config in DB
		docker exec egroupware kill -s USR2 1
	else
		echo "Can NOT connect to EGroupware database as user 'root', you need to create and add DB credentials to dovecot/my.cnf postfix/sql-{aliases,mailboxes,domains}.cf"
	fi

	# some distros remove dashes from names used in docker, we need to fix these to be able to access EGroupware network
	[ "$(docker network ls|grep egroupware-docker_default|sed 's/ \+/ /g'|cut -d' ' -f2)" = "egroupware-docker_default" ] || {
		sed -e 's/^#\(networks:\)/\1/g' \
			-e 's/^#\(  egroupware-docker_default:\)/\1/g' \
			-e 's/^#\(  egroupwaredocker_default:\)/\1/g' \
			-e 's/^#\(    external:.*\)/\1/g' \
			-e 's/^#\(services:\)/\1/g' \
			-e 's/^#\(  mail:\)/\1/g' \
			-e 's/^#\(  smtp:\)/\1/g' \
			-e 's/^#\(    networks:\)/\1/g' \
			-e 's/^#\(      - egroupwaredocker_default\)/\1/g' \
			-i docker-compose.override.yml
	}
	;;
esac

# new install AND update from here on
# (re-)start our containers (do NOT fail package installation on error, as this leaves package in a wired state!)
$COMPOSE pull && \
echo "y" | $COMPOSE up -d || true

# fix postfix can't find it's (already installed) mysql driver
docker exec egroupware-smtp sh -c "apk del postfix-mysql; apk --update add postfix-mysql; postfix reload" || true
# create the lmdb database of the aliases file, the image (Alpine) uses lmdb instead of hash/Berkeley DB maps
docker exec egroupware-smtp sh -c "postalias lmdb:/etc/postfix/aliases; postfix reload" || true
true

%preun
COMPOSE="docker compose"
docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"

case "$1" in
  0)# This is an un-installation: stop and remove the containers, mail data in %{data_dir} is kept.
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

%files -f %{_builddir}/%{name}-files.lst
%defattr(-,root,root)
%dir %{etc_dir}
%dir %{etc_dir}/dovecot
%dir %{etc_dir}/dovecot/conf.d
%dir %{etc_dir}/postfix
%dir %{etc_dir}/postfix/dynamicmaps.cf.d
%{etc_dir}/latest-docker-compose.override.yml
%ghost %config(noreplace) %{etc_dir}/docker-compose.override.yml
%ghost %attr(600,root,root) %{etc_dir}/certificate.key
%ghost %{etc_dir}/certificate.pem
%attr(750,90,101) %dir %{data_dir}
