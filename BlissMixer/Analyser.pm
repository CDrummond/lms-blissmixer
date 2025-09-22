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

# Only auto restart analyser if it was running for over X seconds
# and stopped before sending FINISHED
use constant MIN_ANALYSER_RUN_TIME => 15;

# How often to check anayser
use constant CHECK_ANALYSER_TIME => 60;

# How often to check track count in DB
use constant DB_TRACK_COUNT_TIME => 15;

# Message sent by analyser when it has successfully finished
use constant ANALYSER_FINISHED_MSG => "FINISHED";

use constant DB_NAME  => "bliss.db";

# Current bliss-analyser process
my $analyser;
# Path to  liss-analyser that will be used on current system
my $analyserBinary;
# Last messaage received from analyser
my $lastAnalyserMsg = "";
# Last time analyser was started
my $lastAnalyserStart = 0;
# Time check timer was last stated - so that we dont restart too often
my $lastAnalyserCheckTimerStart = 0;

my $dbPath;
my $lastTracksInDbCountTime = 0;
my $tracksInDb = 0;
my $trackFailuresInDb = 0;

sub init {
    $dbPath = shift;
    $analyserBinary = Slim::Utils::Misc::findbin('bliss-analyser');
    main::INFOLOG && $log->info("Analyser: ${analyserBinary}");
}

sub cliCommand {
    my $request = shift;
    my $act = $request->getParam('act');
    #main::DEBUGLOG && $log->debug("Analyser act:${act}");
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
        my $running = _checkAnalyser();
        _countTracksInDb();
        $request->addResult("count", $tracksInDb);
        $request->addResult("failed", $trackFailuresInDb);
        $request->addResult("running", $running);
        if ($running) {
            $request->addResult("msg", $lastAnalyserMsg);
        }
    } elsif ($act eq 'update') {
        $lastAnalyserMsg = $request->getParam('msg');
        if ($lastAnalyserMsg eq ANALYSER_FINISHED_MSG) {
            main::DEBUGLOG && $log->debug("Analysis finished successfully");
        }
    } else {
        $request->setStatusBadParams();
        return;
    }
    $request->setStatusDone();
}

sub _countTracksInDb {
    my $now = Time::HiRes::time();
    if (-e $dbPath) {
        if (0==$lastTracksInDbCountTime || Time::HiRes::time()-$lastTracksInDbCountTime>=DB_TRACK_COUNT_TIME) {
            eval {
                main::DEBUGLOG && $log->debug("Count tracks in ${dbPath}");
                my $dbh = DBI->connect( "dbi:SQLite:dbname=${dbPath}", '', '', { RaiseError => 0 });
                my $sth = $dbh->prepare( "SELECT COUNT(1) FROM TracksV2" );
                $sth->execute();
                $tracksInDb = $sth->fetchrow_array();
                $sth->finish();

                $sth = $dbh->prepare( "SELECT COUNT(1) FROM Failures" );
                $sth->execute();
                $trackFailuresInDb = $sth->fetchrow_array();
                $sth->finish();

                $dbh->disconnect();
                $lastTracksInDbCountTime = $now;
            }
        }
    } else {
        $tracksInDb = 0;
    }
}

sub _startAnalyserCheckTimer {
    $lastAnalyserCheckTimerStart = Time::HiRes::time();
    main::DEBUGLOG && $log->debug("Start analyser check timer");
    Slim::Utils::Timers::killTimers(undef, \&_checkAnalyser);
    Slim::Utils::Timers::setTimer(undef, $lastAnalyserCheckTimerStart + CHECK_ANALYSER_TIME, \&_checkAnalyser);
}

sub _checkAnalyser {
    my $running = $analyser && $analyser->alive ? 1 : 0;
    my $now = Time::HiRes::time();
    main::DEBUGLOG && $log->debug("Check status");
    if ($running) {
        if ($lastAnalyserCheckTimerStart<=0 || $now-$lastAnalyserCheckTimerStart>=(CHECK_ANALYSER_TIME-10)) {
            _startAnalyserCheckTimer();
        }
    } elsif ($lastAnalyserStart>0 && $lastAnalyserMsg ne ANALYSER_FINISHED_MSG && $now-$lastAnalyserStart>MIN_ANALYSER_RUN_TIME) {
        main::DEBUGLOG && $log->debug("Restart due to not running and " . ANALYSER_FINISHED_MSG . " not received");
        startAnalyser();
    }
    return $running;
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
    if ( $prefs->get('analysis_read_tags')) {
        push @params, "--readtags";
    }
    if ( $prefs->get('analysis_write_tags')) {
        push @params, "--writetags";
        push @params, "--preserve";
    }
    push @params, "--threads";
    push @params, "-1"; # => num cores -1
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
    $lastAnalyserStart = Time::HiRes::time();
    _startAnalyserCheckTimer();
}

sub stopAnalyser {
    my $why = shift;
    main::DEBUGLOG && $log->debug("Stop analyser (${why})");
    Slim::Utils::Timers::killTimers(undef, \&_checkAnalyser);
    $lastAnalyserStart = 0;
    if ($analyser && $analyser->alive) {
        $analyser->die;
    } else {
        main::DEBUGLOG && $log->debug("$analyserBinary not running");
    }
}

1;

__END__
