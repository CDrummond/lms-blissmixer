package Plugins::BlissMixer::Analyser;

#
# LMS Bliss Mixer
#
# (c) 2022-2025 Craig Drummond
#
# Licence: GPL v3
#

use strict;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');
my $log = logger('plugin.blissmixer');

# Current bliss-analyser process
my $analyser;
# Path to  liss-analyser that will be used on current system
my $analyserBinary;
# Last messaage received from analyser
my $lastAnalyserMsg = "";

sub initBinary {
    my $bindir = shift;
    if (main::ISWINDOWS) {
        Slim::Utils::Misc::addFindBinPaths(catdir($bindir, 'windows'));
    } elsif (main::ISMAC) {
        Slim::Utils::Misc::addFindBinPaths(catdir($bindir, 'mac'));
    }

    $analyserBinary = Slim::Utils::Misc::findbin('bliss-analyser');
    main::INFOLOG && $log->info("Analyser: ${analyserBinary}");

    # All binaries take just over 100Mb! So, remove any binaries
    # that are for other OSs.
    my @analysers = glob("${bindir}/*/bliss-analyser*");
    foreach my $bin (@analysers) {
        if ($bin ne $analyserBinary) {
            main::INFOLOG && $log->info("Removing analyser binary for other OS: ${bin}");
            unlink($bin);
        }
    }
}

sub cliCommand {
    my $request = shift;
    my $act = $request->getParam('act');
    main::DEBUGLOG && $log->debug("Analyser act:${act}");
    if ($act eq 'toggle') {
        if ($analyser && $analyser->alive) {
            stopAnalyser("CLI");
        } else {
            startAnalyser();
        }
    } elsif ($act eq 'start') {
         startAnalyser();
    } elsif ($act eq 'stop') {
         stopAnalyser("CLI");
    } elsif ($act eq 'status') {
        my $running = $analyser && $analyser->alive ? 1 : 0;
        $request->addResult("running", $running);
        if ($running) {
            $request->addResult("msg", $lastAnalyserMsg);
        }
    } elsif ($act eq 'update') {
        $lastAnalyserMsg = $request->getParam('msg');
    } else {
        $request->setStatusBadParams();
        return;
    }
    $request->setStatusDone();
}

sub startAnalyser {
    if ($analyser && $analyser->alive) {
        main::DEBUGLOG && $log->debug("$analyserBinary already running");
    }
    if (!$analyserBinary) {
        $log->warn("No analyser binary");
        return 0;
    }

    $lastAnalyserMsg = "";
    my $prefsDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
    my @params = ();
    push @params, "--db";
    push @params, $prefsDir . "/bliss.db";
    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');
    my $numDirs = 0;
    foreach my $dir (@$mediaDirs) {
        if ($numDirs>0) {
            push @params, "--music_${numDirs}";
        } else {
            push @params, "--music";
        }
        push @params, $dir;
        $numDirs++;
    }
    if ( $prefs->get('analysis_tags')) {
        push @params, "--tags";
        push @params, "--preserve";
    }
    push @params, "--threads";
    push @params, "1111"; # 1111 => num cores -1
    push @params, "--lms";
    push @params, "127.0.0.1";
    push @params, "--json";
    push @params, $serverprefs->get('httpport');
    push @params, "--notifs";
    push @params, "--logging";
    push @params, "error";
    push @params, "--ignore";
    push @params, $prefsDir . "/bliss-ignore.txt";
    push @params, "analyse-lms";
    main::DEBUGLOG && $log->debug("Start analyser: $analyserBinary @params");
    eval { $analyser = Proc::Background->new({ 'die_upon_destroy' => 1 }, $analyserBinary, @params); };

    if ($@) {
        $log->warn($@);
    } else {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
            if ($analyser && $analyser->alive) {
                main::DEBUGLOG && $log->debug("$analyserBinary running");
            } else {
                main::DEBUGLOG && $log->debug("$analyserBinary NOT running");
            }
        });
    }
}

sub stopAnalyser {
    my $why = shift;
    main::DEBUGLOG && $log->debug("Stop analyser (${why})");
    if ($analyser && $analyser->alive) {
        $analyser->die;
    } else {
        main::DEBUGLOG && $log->debug("$analyserBinary not running");
    }
}

1;

__END__
