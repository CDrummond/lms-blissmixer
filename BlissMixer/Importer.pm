#
# LMS Bliss Mixer
#
# (c) 2022-2026 Craig Drummond
#
# Licence: GPL v3
#

package Plugins::BlissMixer::Importer;

use JSON::XS::VersionOneAndTwo;
use strict;
use warnings;
use utf8;
use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;

my $prefs = preferences('plugin.blissmixer');
+my $serverprefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.blissmixer');

sub initPlugin {
    main::DEBUGLOG && $log->is_debug && $log->debug('Init');
    toggleUseImporter();
}

sub toggleUseImporter {
    if ($prefs->get('run_analyser_after_scan') && !$serverprefs->get('authorize')) {
        main::DEBUGLOG && $log->is_debug && $log->debug('Enabling analysis after scan');
        Slim::Music::Import->addImporter('Plugins::BlissMixer::Importer', {
            'type' => 'post',
            'weight' => 999,
            'use' => 1,
        });
    } else {
        main::DEBUGLOG && $log->is_debug && $log->debug('Disabling analysis after scan');
        Slim::Music::Import->useImporter('Plugins::BlissMixer::Importer', 0);
    }
}

sub startScan {
    if (main::SCANNER) {
        my $class = shift;
        if ($prefs->get('run_analyser_after_scan') && !$serverprefs->get('authorize')) {
            main::DEBUGLOG && $log->is_debug && $log->debug('Starting analysis');
            _sendCommand([ 'blissmixer', 'analyser', 'act:start' ]);
        }
        Slim::Music::Import->endImporter($class);
    }
}

sub _sendCommand() {
    my $cmd = shift;
    my $msg = to_json({
        id     => 1,
        method => 'slim.request',
        params => ['', $cmd],
    });
    my $url = "http://127.0.0.1:" . $serverprefs->get('httpport') . "/jsonrpc.js";
    Slim::Networking::SimpleSyncHTTP->new({timeout => 5})->post( $url, 'Content-Type' => 'application/json', $msg );
}

1;
