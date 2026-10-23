<?php

//2026-10-23T14:00:00Z omv8box internal-sftp[31005]: session opened for local user test from [10.10.10.23]
//2026-10-23T14:00:35Z omv8box internal-sftp[31005]: opendir "/Videos"

require_once("openmediavault/functions.inc");

// The messages of chrooted sessions are passed on to the journal by
// rsyslog, so journald records rsyslog as the sender. Format the entries
// with jq to show the PID of the SFTP session (SYSLOG_PID) instead.
$jqProgram = <<<'JQ'
def str: if type == "array" then implode else (. // "") end;
"\(.__REALTIME_TIMESTAMP | tonumber / 1000000 | floor | todate) \(._HOSTNAME | str) \(.SYSLOG_IDENTIFIER | str)[\(.SYSLOG_PID // ._PID | str)]: \(.MESSAGE | str | gsub("\n"; " "))"
JQ;

\OMV\System\LogFileSpec::registerSpecification("sftp", [
  "command" => "export SYSTEMD_COLORS=0; journalctl --quiet --no-pager ".
    "--output=json --output-fields=_HOSTNAME,SYSLOG_IDENTIFIER,SYSLOG_PID,_PID,MESSAGE ".
    "--identifier=internal-sftp | jq --raw-output ".escapeshellarg($jqProgram),
  "filename" => "openmediavault-sftp",
  "regex" => '/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+(\S+)\s+(.*)$/',
  "columns" => [
	  "ts" => [
		  "index" => 1,
		  "func" => function($v) { return strtotime($v); }
	  ],
	  "date" => [
		  "index" => 1,
		  "func" => function($v) {
			  return date("D M j H:i:s Y", strtotime($v));
		  }
	  ],
	  "hostname" => 2,
	  "message" => 3
  ]]);
