#!/usr/bin/env python3
"""Wait until packages built by OBS from a given source revision are published in the given repositories.

Used by .github/workflows/package-tests.yml, so the install tests only run, once the packages of a commit are available.
Needs no credentials, it uses the public (anonymous) OBS API.

For every package/srcmd5 and repository it waits for
  1. a finished build of exactly that source revision (srcmd5, from .osc/_files of the commit) in the job history,
     a build of it with another result than "succeeded" fails immediately,
  2. the package state to be "succeeded" and the repository state to be "published" (not "building", not "dirty"),
and finally waits --settle seconds, as download mirrors can lag a bit behind OBS ("File has unexpected size" from apt).

Exit codes: 0 all published, 1 a build failed, 2 timeout.

Example:
  wait-for-obs.py --pkg egroupware-docker-26=65f2f01d56056a068349388226fdf283 --repo RockyLinux_10 --repo xUbuntu_24.04
"""
import argparse
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

API = 'https://api.opensuse.org/public/build'


def get(url):
    """GET url and return parsed XML or None on an (assumed temporary) error"""
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return ET.fromstring(r.read())
    except (urllib.error.URLError, ET.ParseError, TimeoutError, ConnectionError) as e:
        print('   (%s: %s)' % (url, e), flush=True)
        return None


def check(project, arch, pkg, srcmd5, repo):
    """return (state, message), state is one of "ok", "failed", "wait" """
    q = urllib.parse.urlencode({'package': pkg, 'limit': 20})
    hist = get('%s/%s/%s/%s/_jobhistory?%s' % (API, project, repo, arch, q))
    if hist is None:
        return 'wait', 'OBS not reachable'
    builds = [j for j in hist.findall('jobhist') if j.get('srcmd5') == srcmd5]
    if not builds:
        return 'wait', 'no finished build of source %s yet' % srcmd5[:8]
    last = max(builds, key=lambda j: int(j.get('endtime') or 0))
    if last.get('code') != 'succeeded':
        return 'failed', 'build %s-%s.%s of source %s: %s' % (
            last.get('package'), last.get('versrel'), last.get('bcnt'), srcmd5[:8], last.get('code'))
    q = urllib.parse.urlencode({'package': pkg, 'repository': repo, 'arch': arch})
    res = get('%s/%s/_result?%s' % (API, project, q))
    if res is None:
        return 'wait', 'OBS not reachable'
    for result in res.findall('result'):
        status = result.find('status')
        code = status.get('code') if status is not None else '?'
        if result.get('state') == 'published' and result.get('dirty') != 'true' and code == 'succeeded':
            return 'ok', 'published (%s.%s)' % (last.get('versrel'), last.get('bcnt'))
        return 'wait', 'built (%s.%s), but package is "%s" and repository "%s"%s' % (
            last.get('versrel'), last.get('bcnt'), code, result.get('state'), ' (dirty)' if result.get('dirty') == 'true' else '')
    return 'wait', 'repository %s/%s not found in result' % (repo, arch)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--project', default='server:eGroupWare')
    p.add_argument('--arch', default='x86_64')
    p.add_argument('--pkg', action='append', required=True, metavar='PACKAGE=SRCMD5', help='package and source md5 of the expected build, can be repeated')
    p.add_argument('--repo', action='append', required=True, help='OBS repository, can be repeated')
    p.add_argument('--timeout', type=int, default=3 * 3600, help='seconds to wait in total (default 3h)')
    p.add_argument('--interval', type=int, default=60, help='seconds between checks (default 60)')
    p.add_argument('--settle', type=int, default=180, help='seconds to wait after everything is published, for the mirrors (default 180)')
    a = p.parse_args()

    pkgs = []
    for spec in a.pkg:
        name, _, md5 = spec.partition('=')
        if not md5:
            p.error('--pkg needs PACKAGE=SRCMD5, got %r' % spec)
        pkgs.append((name, md5))
    pending = {(pkg, md5, repo) for pkg, md5 in pkgs for repo in a.repo}
    started = time.time()
    last_msg = {}
    while True:
        for item in sorted(pending):
            pkg, md5, repo = item
            state, msg = check(a.project, a.arch, pkg, md5, repo)
            if last_msg.get(item) != msg:
                print('%s %-26s %-20s %s' % (time.strftime('%H:%M:%S'), pkg, repo, msg), flush=True)
                last_msg[item] = msg
            if state == 'failed':
                print('FAILED: %s %s: %s' % (pkg, repo, msg), file=sys.stderr, flush=True)
                return 1
            if state == 'ok':
                pending.discard(item)
        if not pending:
            break
        if time.time() - started > a.timeout:
            print('TIMEOUT after %ds, still waiting for: %s' % (a.timeout, ', '.join('%s/%s' % (i[0], i[2]) for i in sorted(pending))), file=sys.stderr, flush=True)
            return 2
        time.sleep(a.interval)
    print('%s all %d package/repository combinations published, waiting %ds for the mirrors' % (time.strftime('%H:%M:%S'), len(pkgs) * len(a.repo), a.settle), flush=True)
    time.sleep(a.settle)
    return 0


if __name__ == '__main__':
    sys.exit(main())
