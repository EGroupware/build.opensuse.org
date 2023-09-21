#!/usr/bin/env php
<?php

use Symfony\Component\Yaml\Yaml;

if (!file_exists(__DIR__.'/vendor'))
{
	system($composer='docker run --rm -it --volume '.__DIR__.':/app --user $(id -u):$(id -g) composer require symfony/yaml', $error);
	if ($error)
    {
        echo "Error running: $composer\n";
        exit($error);
	}
}
require_once __DIR__.'/vendor/autoload.php';

$args = $_SERVER['argv'];
$cmd = array_shift($args);
while (($arg=current($args)) && $arg[0] === '-')
{
	switch($arg)
	{
		default:
			usage("Invalid argument '$arg'!");
			break;
	}
	array_shift($args);
}

if (!$args) usage();

if (!file_exists($filename = array_shift($args)) || !is_readable($filename) ||
	!($yaml = file_get_contents($filename)))
{
	usage("File '$filename' not found!");
}

// transform comments to preserve them
$lines = [];
$comment_indent = null;
foreach($yamls=preg_split("/\r?\n/", $yaml) as $n => $line)
{
    if (preg_match('/^( *)(#.*)$/m', $line, $matches))
    {
        if (!isset($comment_indent))
        {
            for($i=$n+1; isset($yamls[$i]) && !preg_match('/^( *)[^#]/', $yamls[$i], $m); ++$i){}
            $comment_indent = isset($yamls[$i]) && isset($m) ? $m[1] : '';
            $lines[] = $comment_indent.".comment$n: |";
        }
        $lines[] = $comment_indent.' '.$line;
    }
    else
    {
        $comment_indent = null;
        $lines[] = $line;
    }
}
$yaml_comments = implode("\n", $lines);
echo $yaml_comments."\n";
$data = Yaml::parse($yaml_comments);
echo json_encode($data, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)."\n\n";
echo Yaml::dump($data, 99, 2, Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK)."\n";

function usage($err=null)
{
	global $cmd;

	echo "$cmd: <yml-file-to-update> <json-to-merge>\n";
	if (!empty($err))
	{
		echo "\n$err\n";
	}
	exit(1);
}