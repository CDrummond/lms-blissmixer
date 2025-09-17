#
# LMS Bliss Mixer
#
# (c) 2022-2025 Craig Drummond
#
# Licence: GPL v3
#

package Plugins::BlissMixer::Importer;

use strict;
use warnings;
use utf8;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;

my $prefs = preferences('plugin.blissmixer');
my $log = Slim::Utils::Log::logger('plugin.blissmixer');

sub initPlugin {
	main::DEBUGLOG && $log->is_debug && $log->debug('Init');
	toggleUseImporter();
}

sub toggleUseImporter {
	if ($prefs->get('run_analyser_after_scan')) {
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
	my $class = shift;
	if ($prefs->get('run_analyser_after_scan')) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Starting analysis');
		$class->rescan(1);
	}
	Slim::Music::Import->endImporter($class);
}

1;
