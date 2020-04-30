#!/usr/bin/env php
<?php
/**
 * EGroupware - RPM post install: automatic install or update EGroupware
 *
 * This file:
 * - restarts "egroupware" Docker container to copy sources of to install app into the container
 * - runs doc/rpm-build/post_install.php via docker exec
 *
 * @link https://www.egroupware.org
 * @license https://opensource.org/licenses/gpl-license.php GPL - GNU General Public License
 * @author rb@egroupware.org
 */

if (php_sapi_name() !== 'cli')	// security precaution: forbit calling post_install as web-page
{
	die('<h1>post_install.php must NOT be called as web-page --> exiting !!!</h1>');
}

$ret = 0;
system('docker restart egroupware', $ret);

if (!$ret)
{
	echo "Waiting for egroupware container to restart .";
	system("docker exec egroupware bash -c 'until ps | grep php-fpm >/dev/null; do echo -n \".\"; sleep 1; done'");
	echo "\n";

	$args = $_SERVER['argv'];
	array_shift($args);
	array_unshift($args, '--start_webserver', '""');
	array_walk($args, function($arg)
	{
			return escapeshellarg($arg);
	});
	$cmd = '/usr/bin/php /usr/share/egroupware/doc/rpm-build/post_install.php '.implode(' ', $args);

	// if HTTP_HOST environment variable is set, pass it on
	if (!empty($_SERVER['HTTP_HOST']))
	{
		$cmd = '/bin/bash -c "HTTP_HOST='.$_SERVER['HTTP_HOST'].' '.$cmd.'"';
	}
	system('docker exec egroupware '.$cmd, $ret);
}
exit($ret);