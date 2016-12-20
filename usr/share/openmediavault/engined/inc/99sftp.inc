<?php

//Dec 19 22:18:45 openmediavault-jessie internal-sftp[31005]: session opened for local user test from [10.10.10.23]
//Dec 19 22:19:20 openmediavault-jessie internal-sftp[31005]: opendir "/Videos"

require_once("openmediavault/functions.inc");
\OMV\System\LogFileSpec::registerSpecification("sftp", [
  "filename" => "openmediavault-sftp",
  "filepath" => "/var/log/openmediavault-sftp.log",
  "regex" => '/^(\S+\s+\d+\s+\S+)\s+(\S+)\s+(.*)$/',
  "columns" => [
	  "ts" => [
		  "index" => 1,
		  "func" => function($v) { return strpdate($v,"M j G:i:s"); }
	  ],
	  "date" => [
		  "index" => 1,
		  "func" => function($v) {
			  return strftime("%c", strpdate($v,"M j G:i:s"));
		  }
	  ],
	  "hostname" => 2,
	  "message" => 3
  ]]);
