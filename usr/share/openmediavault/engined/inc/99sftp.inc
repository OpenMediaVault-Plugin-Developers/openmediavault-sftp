<?php
require_once("openmediavault/functions.inc");
\OMV\System\LogFileSpec::registerSpecification("sftp", [
  "filename" => "openmediavault-sftp",
  "filepath" => "/var/log/openmediavault-sftp.log",
  "regex" => '/^(\S+\s+\S+\s+\S+\s+)(\S+\s+)(internal-sftp\[\d+\]:.*)$/',
  "columns" => [
	  "ts" => [
		  "index" => 1,
		  "func" => function($v) { return strpdate($v,"M D j H:i:s"); }
	  ],
	  "date" => [
		  "index" => 1,
		  "func" => function($v) {
			  return strftime("%c", strpdate($v,"M D j H:i:s"));
		  }
	  ],
	  "hostname" => 2,
	  "message" => 3
  ]]);
