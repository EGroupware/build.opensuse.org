#!/bin/bash
# Diagnostics after a failed setup step: what runs, what stopped, and the last log lines of every container
echo "=== diagnostics: containers"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1
for c in $(docker ps -aq 2>/dev/null); do
	echo "=== diagnostics: $(docker inspect -f '{{.Name}} ({{.Config.Image}}, {{.State.Status}}, exit {{.State.ExitCode}})' $c)"
	docker logs --tail ${DIAG_LINES:-15} $c 2>&1 | cut -c1-300
done
echo "=== diagnostics: end"
