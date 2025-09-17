#
# LMS Bliss Mixer
#
# (c) 2022-2025 Craig Drummond
#
# Licence: GPL v3
#

package Plugins::BlissMixer::Analyser;

use utf8;
use Config;
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.blissmixer');

use base 'Exporter';
our %EXPORT_TAGS = (
    all => [qw(rescan abortScan isScanning)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $analyser;

sub rescan {
    main::DEBUGLOG && $log->is_debug && $log->debug('Analysing...');
}

sub abortScan {
    if (isScanning()) {
        if ($analyser && $analyser->alive) {
            $log->info("killing bliss-analyser");
            $analyser->die;
        }
        main::DEBUGLOG && $log->is_debug && $log->debug('Aborting analysis');
        if ($^O eq 'MSWin32') {
            `taskkill /IM "bliss-analyser.exe" /F /T`
        } else {
            `killall -9 bliss-analyser`
        }
    }
}

sub isScanning {
    my $running = $analyser && $analyser->alive ? 1 : 0;
    if ($running==0) {
        if ($^O eq 'MSWin32') {
            my $output = `tasklist /FI "IMAGENAME eq bliss-analyser.exe" /FO CSV`;
            if ($output =~ /bliss-analyser.exe/) {
                $running = 1;
            }
        } else {
            # Unix-like systems (Linux, macOS, etc.)
            my $output = `ps aux | grep -v grep | grep bliss-analyser`;
            if ($output) {
                $running = 1;
            }
        }
    }
    return $running;
}

1;
