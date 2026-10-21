# Checks of the Rocket.Chat package and its OAuth integration with EGroupware, sourced by verify.sh (uses ok, bad, check, $BASE, $TIMEOUT)
RCDIR=/etc/egroupware-rocketchat
HOST=${TLS_HOST:-egw.test}
# value of a JSON string key, the first one in the input
jstr() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }

check "rocketchat: container rocketchat running"       test "$(docker inspect -f '{{.State.Running}}' rocketchat)" = true
check "rocketchat: container rocketchat-mongo running" test "$(docker inspect -f '{{.State.Running}}' rocketchat-mongo)" = true

# Rocket.Chat needs a while to start, behind the host's webserver, which sends / to it
deadline=$((SECONDS+TIMEOUT))
until curl -sf $BASE/api/info 2>/dev/null | grep -q '"version"' || [ $SECONDS -ge $deadline ]; do sleep 10; done
INFO=$(curl -sf $BASE/api/info 2>/dev/null)
[ -n "$INFO" ] && ok "rocketchat: $BASE/api/info answers through the host webserver" || bad "rocketchat: $BASE/api/info does not answer"
# the image uses a running tag (stable8), so say what was tested
echo "INFO: Rocket.Chat $(echo "$INFO" | jstr version), image $(docker inspect -f '{{.Image}}' rocketchat | cut -c1-19), amd64 emulated: $(docker exec rocketchat uname -m)"

# the admin created by install-rocketchat.sh: random password in .env
check "rocketchat: .env is only readable by root (mode 600)" test "$(stat -c %a $RCDIR/.env)" = 600
RC_ADMIN_USER=$(sed -n 's/^RC_ADMIN_USER=//p' $RCDIR/.env); RC_ADMIN_PASS=$(sed -n 's/^RC_ADMIN_PASS=//p' $RCDIR/.env)
check "rocketchat: .env contains admin user and password" test -n "$RC_ADMIN_USER" -a -n "$RC_ADMIN_PASS"
LOGIN=$(curl -s -X POST $BASE/api/v1/login -H 'Content-Type: application/json' -d "{\"user\":\"$RC_ADMIN_USER\",\"password\":\"$RC_ADMIN_PASS\"}")
echo "$LOGIN" | grep -q '"status":"success"' && ok "rocketchat: admin $RC_ADMIN_USER from .env can log in via REST" || bad "rocketchat: admin login failed: $(echo "$LOGIN" | head -c 150)"
check "rocketchat: that admin has the role admin" sh -c "echo '$LOGIN' | grep -q '\"admin\"'"

# the custom OAuth service has to be created by install-rocketchat.sh, it does not exist in a new database
OAUTH=$(curl -s $BASE/api/v1/settings.oauth)
echo "$OAUTH" | grep -q '"clientId":"Rocket.Chat"' && echo "$OAUTH" | grep -q "\"serverURL\":\"https://$HOST/egroupware/openid/endpoint.php\"" \
	&& ok "rocketchat: custom OAuth service for EGroupware exists (client Rocket.Chat, https://$HOST/egroupware/openid/endpoint.php)" \
	|| bad "rocketchat: no custom OAuth service for EGroupware: $(echo "$OAUTH" | head -c 200)"
for s in token_sent_via=payload identity_token_sent_via=header; do
	v=$(docker exec rocketchat-mongo mongosh --quiet mongo/rocketchat --eval "print(db.rocketchat_settings.findOne({_id:'Accounts_OAuth_Custom-Egroupware-${s%%=*}'}).value)" 2>/dev/null)
	[ "$v" = "${s#*=}" ] && ok "rocketchat: OAuth setting ${s%%=*} is ${s#*=}" || bad "rocketchat: OAuth setting ${s%%=*} is '$v', expected ${s#*=}"
done

# the whole OAuth login of EGroupware user sysop, without a browser:
# 1. login to EGroupware, 2. authorize the client Rocket.Chat (an EGroupware app, so no consent screen),
# 3. Rocket.Chat exchanges the code with EGroupware and fetches the identity via https (needs the private CA), 4. login via DDP with the credential
SYSOP_PW=$(awk '/^EGroupware username: *sysop/{f=1;next} f&&/password:/{print $2;exit}' /var/lib/egroupware/egroupware-docker-install.log)
J=/tmp/rc-oauth.cookies; rm -f $J
curl -s -c $J -b $J -o /dev/null -d "login=sysop&passwd=$SYSOP_PW&passwd_type=text&account_type=u&submitit=1" $BASE/egroupware/login.php
TOKEN=oauthtest$(date +%s)$RANDOM
STATE=$(printf '%s' "{\"loginStyle\":\"redirect\",\"credentialToken\":\"$TOKEN\",\"redirectUrl\":\"https://$HOST/home\",\"isCordova\":false}" | base64 | tr -d '\n=' | tr '+/' '-_')
LOC=$(curl -s -b $J -c $J -o /dev/null -w '%{redirect_url}' "$BASE/egroupware/openid/endpoint.php/authorize?response_type=code&client_id=Rocket.Chat&redirect_uri=https%3A%2F%2F$HOST%2F_oauth%2Fegroupware&scope=openid%20email%20profile%20roles%20groups&state=$STATE")
case "$LOC" in "https://$HOST/_oauth/egroupware?code="*) ok "oauth: EGroupware authorizes Rocket.Chat and redirects with a code (no consent screen)" ;;
	*) bad "oauth: authorize did not redirect to Rocket.Chat with a code: '${LOC:0:120}'" ;; esac
PAGE=$(curl -s "$LOC")
if echo "$PAGE" | grep -q '"setCredentialToken":true'; then
	ok "oauth: Rocket.Chat exchanged the code and fetched the identity from EGroupware via https"
else
	bad "oauth: Rocket.Chat could not log the user in: $(docker exec rocketchat-mongo mongosh --quiet mongo/rocketchat --eval 'db.getCollection("meteor_oauth_pendingCredentials").find().sort({createdAt:-1}).limit(1).forEach(d=>print((d.credential&&d.credential.error&&d.credential.error.message)||"?"))' 2>/dev/null | head -c 300)"
fi
SECRET=$(echo "$PAGE" | jstr credentialSecret)
RESULT=$(docker exec -i -e TOKEN="$TOKEN" -e SECRET="$SECRET" rocketchat node - <<'JS' 2>&1
const ws = new WebSocket("ws://127.0.0.1:3000/websocket");
const done = (m) => { console.log(m); process.exit(0); };
setTimeout(() => done("TIMEOUT"), 60000);
ws.onopen = () => ws.send(JSON.stringify({msg: "connect", version: "1", support: ["1"]}));
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.msg === "ping") return ws.send(JSON.stringify({msg: "pong"}));
  if (m.msg === "connected") ws.send(JSON.stringify({msg: "method", method: "login", id: "1",
    params: [{oauth: {credentialToken: process.env.TOKEN, credentialSecret: process.env.SECRET}}]}));
  if (m.msg === "result" && m.id === "1") done(m.error ? "LOGIN ERROR: " + JSON.stringify(m.error).slice(0, 300) : "LOGIN OK type=" + m.result.type);
};
ws.onerror = (e) => done("WS ERROR " + (e.message || ""));
JS
)
echo "$RESULT" | grep -q '^LOGIN OK type=egroupware' && ok "oauth: sysop is logged in to Rocket.Chat via the EGroupware OAuth service" || bad "oauth: login failed: ${RESULT:0:200}"
n=$(docker exec rocketchat-mongo mongosh --quiet mongo/rocketchat --eval 'print(db.users.countDocuments({username:"sysop","services.egroupware":{$exists:true}}))' 2>/dev/null)
[ "$n" = 1 ] && ok "oauth: Rocket.Chat created the user sysop from the EGroupware identity" || bad "oauth: user sysop not created in Rocket.Chat ($n)"
