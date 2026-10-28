# sourced by verify.sh: SMB/CIFS access from the egroupware container to a Samba server (SMB=1 of run-test.sh, started by smb.sh)
# server: container smb-server, share "data", user egw, reachable in the compose network as fileserver.corp.test
SMB_PW=Secret123
SMB_FQDN=fileserver.corp.test
EGW_IMG=$(docker inspect -f '{{.Config.Image}}' egroupware)
NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' egroupware)

# create, write, read, list and delete a file on the share via the smb:// stream wrapper of PHP's smbclient extension, script is read from stdin
smb_roundtrip() {   # host
	cat <<'PHPEOF'
<?php
$b = 'smb://egw:'.rawurlencode(getenv('SMB_PW')).'@'.getenv('SMB_HOST').'/data';
$d = $b.'/roundtrip-'.getmypid();
$ok = @mkdir($d) && file_put_contents("$d/hello.txt", 'hello smb') === 9 && file_get_contents("$d/hello.txt") === 'hello smb'
	&& in_array('hello.txt', scandir($d)) && unlink("$d/hello.txt") && rmdir($d);
echo $ok ? "OK\n" : 'FAILED: '.(error_get_last()['message'] ?? 'unknown')."\n";
exit($ok ? 0 : 1);
PHPEOF
}

check "smb: Samba server container running" test "$(docker inspect -f '{{.State.Running}}' smb-server)" = true
check "smb: PHP smbclient extension loaded in the egroupware container" sh -c "docker exec egroupware php -m | grep -qx smbclient"
echo "INFO: $(docker exec egroupware php --ri smbclient 2>/dev/null | grep -E 'library Version' | tr -s ' ')"

# 1. PHP in the running egroupware container, with the FQDN
OUT=$(smb_roundtrip | docker exec -i -e SMB_HOST=$SMB_FQDN -e SMB_PW=$SMB_PW egroupware php 2>&1) && ok "smb: create/write/read/list/delete via smb:// in the egroupware container ($SMB_FQDN)" \
	|| bad "smb: roundtrip via smb:// in the egroupware container failed: $(echo "$OUT" | head -c 200)"
OUT=$(smb_roundtrip | docker exec -i -e SMB_HOST=$SMB_FQDN -e SMB_PW=wrong-$SMB_PW egroupware php 2>&1) \
	&& bad "smb: access with a wrong password was NOT rejected" || ok "smb: access with a wrong password is rejected"

# 2. through EGroupware's own VFS: mount the share as /smb with filemanager/cli.php and read a file back via the VFS
# (the cli treats plain paths as local files, VFS paths need the vfs://default/ URL)
CLI="docker exec -u www-data egroupware php /usr/share/egroupware/filemanager/cli.php"
echo "smb-probe $$" | docker exec -i -e SMB_HOST=$SMB_FQDN -e SMB_PW=$SMB_PW egroupware php -r '
$f = "smb://egw:".rawurlencode(getenv("SMB_PW"))."@".getenv("SMB_HOST")."/data/probe.txt"; exit(file_put_contents($f, trim(stream_get_contents(STDIN))) ? 0 : 1);' \
	|| bad "smb: could not create probe.txt on the share"
$CLI mount "smb://egw:$SMB_PW@$SMB_FQDN/data" /smb --user root_admin --password "$ADMIN_PW" >/tmp/smb-mount.log 2>&1 \
	&& ok "smb: share mounted into EGroupware's VFS as /smb (filemanager/cli.php mount)" || bad "smb: mounting the share into the VFS failed: $(head -c 200 /tmp/smb-mount.log)"
LS=$($CLI ls vfs://default/smb --user root_admin --password "$ADMIN_PW" 2>&1 || true)
echo "$LS" | grep -q probe.txt && ok "smb: EGroupware's VFS lists the files of the share (/smb/probe.txt)" || bad "smb: VFS listing of /smb has no probe.txt: $(echo "$LS" | head -c 200)"
CAT=$($CLI cat vfs://default/smb/probe.txt --user root_admin --password "$ADMIN_PW" 2>&1 || true)
echo "$CAT" | grep -q "smb-probe $$" && ok "smb: EGroupware's VFS reads a file from the share" || bad "smb: VFS could not read /smb/probe.txt: $(echo "$CAT" | head -c 200)"
$CLI rm vfs://default/smb/probe.txt --user root_admin --password "$ADMIN_PW" >/dev/null 2>&1 || true
$CLI umount /smb --user root_admin --password "$ADMIN_PW" >/dev/null 2>&1 || true

# 3. server names resolved via the search domain of the container (ticket #127001), in throw-away containers of the same image with the DNS options
# (search corp.test, the server has the names fileserver.corp.test and fileserver.sub.corp.test): a customer reported mounts with a server name WITHOUT domain to be broken
# after the update to the Alpine based image: its musl resolver does not fall back to the search domain like glibc does, it only uses it for names with fewer dots
# than "ndots" (Docker Desktop, NOT Linux, sets ndots:0, so even short names fail), FQDNs always work, also without any search domain
smb_name() {   # host ndots
	smb_roundtrip | docker run --rm -i --network "$NET" --dns-search corp.test --dns-option ndots:$2 -e SMB_HOST=$1 -e SMB_PW=$SMB_PW --entrypoint php "$EGW_IMG" 2>&1
}
# must work: FQDNs with any ndots, short name and host.subdomain, where the search domain is needed, as long as ndots is higher than the dots in the name
for t in "fileserver.corp.test 0" "fileserver.corp.test 1" "fileserver.sub.corp.test 0" "fileserver.sub.corp.test 1" "fileserver 1" "fileserver 2" "fileserver.sub 2"; do
	set -- $t
	OUT=$(smb_name $1 $2) && ok "smb: server name '$1' works with search domain and ndots:$2" || bad "smb: server name '$1' does not work with search domain and ndots:$2: $(echo "$OUT" | head -c 150)"
done
# known problem of ticket #127001, a WARN until the image resolves them like glibc did: then turn them into checks
for t in "fileserver 0" "fileserver.sub 0" "fileserver.sub 1"; do
	set -- $t
	if OUT=$(smb_name $1 $2); then ok "smb: server name '$1' works with search domain and ndots:$2"
	else echo "WARN: smb: server name '$1' does NOT work with search domain and ndots:$2 (ticket #127001, musl of the Alpine image does not fall back to the search domain): $(echo "$OUT" | head -c 100)"; fi
done
