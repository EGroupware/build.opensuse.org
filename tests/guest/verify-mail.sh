# Checks of the egroupware-mail package, sourced by verify.sh (uses ok, bad, check, $TIMEOUT)
MDIR=/etc/egroupware-mail
ROOTPW=$(sed -n 's/^EGW_DB_ROOT_PW=//p' /etc/egroupware-docker/.env)
dbroot() { docker exec -i egroupware-db mariadb -uroot -p"$ROOTPW" egroupware -N -e "$1" 2>/dev/null; }
SYSOP_PW=$(awk '/^EGroupware username: *sysop/{f=1;next} f&&/password:/{print $2;exit}' /var/lib/egroupware/egroupware-docker-install.log)

check "mail: container egroupware-mail (Dovecot) running" test "$(docker inspect -f '{{.State.Running}}' egroupware-mail)" = true
check "mail: container egroupware-smtp (Postfix) running" test "$(docker inspect -f '{{.State.Running}}' egroupware-smtp)" = true
echo "INFO: Dovecot $(docker inspect -f '{{.Config.Image}}' egroupware-mail) $(docker inspect -f '{{.Image}}' egroupware-mail | cut -c1-19), Postfix $(docker inspect -f '{{.Config.Image}}' egroupware-smtp) $(docker exec egroupware-smtp postconf -h mail_version 2>/dev/null) $(docker inspect -f '{{.Image}}' egroupware-smtp | cut -c1-19)"

# configuration written by the package
check "mail: docker-compose.override.yml created"            test -f $MDIR/docker-compose.override.yml
check "mail: self-signed certificate and key generated"       sh -c "test -s $MDIR/certificate.pem && test -s $MDIR/certificate.key"
check "mail: certificate key only readable by root (mode 600)" test "$(stat -c %a $MDIR/certificate.key)" = 600
check "mail: push bearer token patched into dovecot config"   sh -c "! grep -q 'Bearer:token' $MDIR/dovecot/conf.d/14-egroupware-push.conf"
MPW=$(sed -n 's/^password *= *//p' $MDIR/dovecot/my.cnf)
check "mail: random DB password generated for user mail (32 hex chars)" sh -c "echo '$MPW' | grep -qE '^[0-9a-f]{32}$'"
check "mail: same DB credentials in all postfix sql-*.cf"     sh -c "[ \$(grep -h '^password *= *$MPW\$' $MDIR/postfix/sql-*.cf | wc -l) = 3 ] && [ \$(grep -h '^user *= *mail\$' $MDIR/postfix/sql-*.cf | wc -l) = 3 ]"
check "mail: DB user mail can log in and read egroupware"     sh -c "docker exec -i egroupware-db mariadb -umail -p$MPW egroupware -N -e 'SELECT COUNT(*) FROM egw_accounts' | grep -qE '^[1-9]'"
[ "$(dbroot "SELECT COUNT(*) FROM egw_accounts WHERE account_lid='dovecot'")" = 1 ] && ok "mail: Dovecot master user exists in EGroupware" || bad "mail: Dovecot master user missing"
[ "$(dbroot "SELECT acc_name FROM egw_ea_accounts WHERE acc_id=1")" = "EGroupware Mail" ] && ok "mail: mail account 'EGroupware Mail' created" || bad "mail: mail account 'EGroupware Mail' missing"
DOMAIN=$(dbroot "SELECT config_value FROM egw_config WHERE config_app='phpgwapi' AND config_name='mail_suffix'")
[ -n "$DOMAIN" ] && ok "mail: mail_suffix set to '$DOMAIN'" || bad "mail: mail_suffix not set"

# a user is only a mail user, if mail is enabled for the account: rows in egw_mailaccounts (Api\Mail\Smtp\Sql: type 0 = enabled, 5 = mailbox name, used as home by Dovecot),
# which EGroupware writes, when mail is enabled in the account in Admin, a new installation has them for nobody; and the email address is in the contact
SYSOP_ID=$(dbroot "SELECT account_id FROM egw_accounts WHERE account_lid='sysop'")
dbroot "INSERT INTO egw_mailaccounts (account_id,mail_type,mail_value) VALUES ($SYSOP_ID,0,'active'),($SYSOP_ID,5,'sysop')" >/dev/null
dbroot "UPDATE egw_addressbook SET contact_email='sysop@$DOMAIN' WHERE account_id=$SYSOP_ID" >/dev/null

# Postfix asks the EGroupware database via its mysql maps (TLS to MariaDB: postfix 3.10 with connector 3.4 verifies the server certificate)
deadline=$((SECONDS+TIMEOUT))
until [ "$(docker exec egroupware-smtp postmap -q "$DOMAIN" mysql:/etc/postfix/sql-domains.cf 2>/dev/null)" = "$DOMAIN" ] || [ $SECONDS -ge $deadline ]; do sleep 10; done
out=$(docker exec egroupware-smtp postmap -q "$DOMAIN" mysql:/etc/postfix/sql-domains.cf 2>&1)
[ "$out" = "$DOMAIN" ] && ok "mail: postfix sql-domains.cf lookup of $DOMAIN works" || bad "mail: postfix sql-domains.cf lookup of $DOMAIN failed: ${out:0:200}"
for m in aliases mailboxes; do
	out=$(docker exec egroupware-smtp postmap -q "nobody@$DOMAIN" mysql:/etc/postfix/sql-$m.cf 2>&1); rc=$?
	# an unknown address is an empty answer with exit 1, an error is a warning/fatal in the output
	case "$out" in *warning*|*fatal*|*rror*) bad "mail: postfix sql-$m.cf lookup is broken: ${out:0:200}" ;; *) ok "mail: postfix sql-$m.cf lookup works (unknown address gives no result)" ;; esac
done
# positive lookups of the now mail enabled user sysop
out=$(docker exec egroupware-smtp postmap -q "sysop@$DOMAIN" mysql:/etc/postfix/sql-mailboxes.cf 2>&1)
[ "$out" = "sysop@$DOMAIN" ] && ok "mail: postfix sql-mailboxes.cf finds mailbox of sysop@$DOMAIN" || bad "mail: postfix sql-mailboxes.cf lookup of sysop@$DOMAIN: ${out:0:200}"
out=$(docker exec egroupware-smtp postmap -q "sysop@$DOMAIN" mysql:/etc/postfix/sql-aliases.cf 2>&1)
[ "$out" = "sysop@$DOMAIN" ] && ok "mail: postfix sql-aliases.cf finds sysop@$DOMAIN" || bad "mail: postfix sql-aliases.cf lookup of sysop@$DOMAIN: ${out:0:200}"
# lmdb maps (alias_maps) need the dynamic map entry from the image, as /etc/postfix is replaced by the one of the package
out=$(docker exec egroupware-smtp postmap -q root lmdb:/etc/postfix/aliases 2>&1)
case "$out" in *unsupported*|*fatal*|*error*) bad "mail: postfix can not use lmdb maps: ${out:0:200}" ;; *) ok "mail: postfix can use lmdb maps (alias_maps)" ;; esac
check "mail: no database or TLS errors in postfix log" sh -c "! docker logs egroupware-smtp 2>&1 | grep -iE 'mysql.*(error|fatal|warning)|TLS/SSL error|Access denied'"

# Dovecot is amd64 only: under Rosetta on Apple Silicon it dies at startup ("rosetta error: mmap_anonymous_rw mmap failed"), that is not a package problem
if [ "$(uname -m)" != x86_64 ] && docker logs egroupware-mail 2>&1 | grep -q 'rosetta error'; then
	echo "SKIP: Dovecot can not run emulated on $(uname -m), IMAP login and mail delivery are only checked on x86_64"
	return 0 2>/dev/null || exit 0
fi
# Dovecot: IMAP login of sysop with EGroupware's password (auth against the EGroupware DB), via TLS with the self-signed certificate
out=$(curl -sSk -m 20 --user "sysop:$SYSOP_PW" imaps://127.0.0.1:993/ 2>&1)
echo "$out" | grep -q INBOX && ok "mail: IMAPS login of sysop works and lists INBOX" \
	|| bad "mail: IMAPS login of sysop failed: ${out:0:200} | doveadm: $(docker exec egroupware-mail doveadm auth test sysop "$SYSOP_PW" 2>&1 | tr '\n' ' ' | cut -c1-300) | password scheme: $(dbroot "SELECT LEFT(account_pwd,12) FROM egw_accounts WHERE account_lid='sysop'") | dovecot: $(docker logs --tail 6 egroupware-mail 2>&1 | tr '\n' ' ' | cut -c1-500)"
code=$(curl -sk -m 20 --user "sysop:wrong-$SYSOP_PW" imaps://127.0.0.1:993/ -o /dev/null -w '%{http_code}' 2>&1)
curl -sk -m 20 --user "sysop:wrong-$SYSOP_PW" imaps://127.0.0.1:993/ >/dev/null 2>&1 && bad "mail: IMAPS login with wrong password was accepted" || ok "mail: IMAPS login with wrong password is rejected"

# delivery: SMTP -> postfix (virtual mailbox lookup in DB) -> LMTP -> dovecot -> INBOX of sysop
ADDR=$(dbroot "SELECT contact_email FROM egw_addressbook WHERE account_id=(SELECT account_id FROM egw_accounts WHERE account_lid='sysop')")
{ [ -n "$ADDR" ] && [ "$ADDR" != NULL ]; } || { ADDR="sysop@$DOMAIN"; dbroot "UPDATE egw_addressbook SET contact_email='$ADDR' WHERE account_id=(SELECT account_id FROM egw_accounts WHERE account_lid='sysop')" >/dev/null; }
echo "INFO: sysop's address is $ADDR"
SUBJ="egw-test-$RANDOM"
printf 'From: tester@example.net\r\nTo: %s\r\nSubject: %s\r\n\r\nhello\r\n' "$ADDR" "$SUBJ" > /tmp/msg.txt
out=$(curl -sS -m 30 --mail-from tester@example.net --mail-rcpt "$ADDR" -T /tmp/msg.txt smtp://127.0.0.1:25 2>&1); rc=$?
[ $rc = 0 ] && ok "mail: postfix accepts a mail for $ADDR on port 25" || bad "mail: postfix rejected mail for $ADDR (curl rc=$rc): ${out:0:200}"
found=""; for i in $(seq 30); do
	curl -sk -m 20 --user "sysop:$SYSOP_PW" "imaps://127.0.0.1:993/INBOX?SUBJECT%20$SUBJ" 2>/dev/null | grep -q SEARCH.*[0-9] && { found=1; break; }
	sleep 2
done
[ -n "$found" ] && ok "mail: the mail was delivered into sysop's INBOX" || bad "mail: mail not found in sysop's INBOX | postfix: $(docker logs --tail 5 egroupware-smtp 2>&1 | tr '\n' ' ' | cut -c1-300)"
rm -f /tmp/msg.txt
