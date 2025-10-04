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
use HTTP::Status qw(RC_NOT_FOUND RC_OK);

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');
my $log = logger('plugin.blissmixer');

my $FAILURE_URL_RE = qr{blissmixer/analyser-failures\.csv}i;

# Only auto restart analyser if it was running for over X seconds
# and stopped before sending FINISHED
use constant MIN_ANALYSER_RUN_TIME => 15;

# How often to check analyser
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
# Last message received from analyser
my $lastAnalyserMsg = "";
# Last time analyser was started
my $lastAnalyserStart = 0;
# Time check timer was last stated - so that we dont restart too often
my $lastAnalyserCheckTimerStart = 0;
my $analyserMode = "analyse";

my $dbPath;
my $lastTracksInDbCountTime = 0;
my $tracksInDb = 0;
my $ignoredTracksInDb = 0;
my $trackFailuresInDb = 0;
# Epoch time analysis was started, and ended
my $analysisStartTime = 0;
my $analysisEndTime = 0;

sub init {
    $dbPath = shift;
    $analyserBinary = Slim::Utils::Misc::findbin('bliss-analyser');
    main::INFOLOG && $log->info("Analyser: ${analyserBinary}");
    if (!main::ISWINDOWS && !main::ISMAC) {
        # Check can actually run bliss-analyser. On Linux/x86 this is linked to glibc
        # and wont work on some old versions.
        my $output = `${analyserBinary} --help`;
        if (index($output, "Bliss Analyser")<0) {
            $analyserBinary = undef;
            main::INFOLOG && $log->info("Could not start analyser, so assuming wrong ABI");
        }
    }
    my $analysisStartTimeCfg = $prefs->get('analysis_start');
    if ($analysisStartTimeCfg) {
        $analysisStartTime = $analysisStartTimeCfg;
    }
    my $analysisEndTimeCfg = $prefs->get('analysis_end');
    if ($analysisEndTimeCfg) {
        $analysisEndTime = $analysisEndTimeCfg;
    }
    Slim::Web::Pages->addRawFunction($FAILURE_URL_RE, \&_failuresHandler);
}

sub cliCommand {
    my $request = shift;
    my $act = $request->getParam('act');
    #main::DEBUGLOG && $log->debug("Analyser act:${act}");
    if ($act eq 'toggle') {
        if ($analyser && $analyser->alive) {
            stopAnalyser("CLI");
        } else {
            startAnalyser("CLI");
        }
    } elsif ($act eq 'start') {
         startAnalyser("CLI");
    } elsif ($act eq 'stop') {
         stopAnalyser("CLI");
    } elsif ($act eq 'status') {
        my $running = _checkAnalyser();
        _countTracksInDb(0);
        $request->addResult("count", $tracksInDb);
        $request->addResult("ignored", $ignoredTracksInDb);
        $request->addResult("failed", $trackFailuresInDb);
        $request->addResult("running", $running);
        if ($running) {
            $request->addResult("msg", $lastAnalyserMsg);
        }
        if ($analysisStartTime>0) {
            $request->addResult("start", $analysisStartTime);
            if ($running) {
                $request->addResult("duration", time()-$analysisStartTime);
            } elsif ($analysisEndTime>$analysisStartTime) {
                $request->addResult("duration", $analysisEndTime-$analysisStartTime);
            }
        }
    } elsif ($act eq 'update') {
        $lastAnalyserMsg = $request->getParam('msg');
        if ($lastAnalyserMsg eq ANALYSER_FINISHED_MSG) {
            main::DEBUGLOG && $log->debug("Analysis finished successfully");
            _analysisEnded();
        }
    } elsif ($act eq 'ignore') {
         if (!$analyser || !$analyser->alive) {
            startAnalyser("CLI", "ignore");
         }
    } else {
        $request->setStatusBadParams();
        return;
    }
    $request->setStatusDone();
}

sub _analysisEnded() {
    if ($lastAnalyserStart>0) {
        $lastAnalyserStart = 0;
        $analysisEndTime = time();
        $prefs->set('analysis_end', $analysisEndTime);
        _countTracksInDb(1);
    }
}

sub _countTracksInDb {
    my $force = shift;
    my $now = Time::HiRes::time();
    if (-e $dbPath) {
        if (1==$force || 0==$lastTracksInDbCountTime || Time::HiRes::time()-$lastTracksInDbCountTime>=DB_TRACK_COUNT_TIME) {
            eval {
                main::DEBUGLOG && $log->debug("Count tracks in ${dbPath}");
                my $dbh = DBI->connect( "dbi:SQLite:dbname=${dbPath}", '', '', { RaiseError => 0 });
                my $sth = $dbh->prepare( "SELECT COUNT(1) FROM TracksV2" );
                $sth->execute();
                $tracksInDb = $sth->fetchrow_array();
                $sth->finish();

                $sth = $dbh->prepare( "SELECT COUNT(1) FROM TracksV2 WHERE Ignore=1" );
                $sth->execute();
                $ignoredTracksInDb = $sth->fetchrow_array();
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
        $ignoredTracksInDb = 0;
        $trackFailuresInDb = 0;
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
    } elsif ($lastAnalyserStart>0 && $lastAnalyserMsg ne ANALYSER_FINISHED_MSG) {
        if (($analyserMode ne "ignore") && $now-$lastAnalyserStart>MIN_ANALYSER_RUN_TIME) {
            main::DEBUGLOG && $log->debug("Restart due to not running and " . ANALYSER_FINISHED_MSG . " not received");
            startAnalyser();
        } else {
            _analysisEnded();
        }
    }
    return $running;
}

sub startAnalyser {
    my $reason = shift;
    my $mode = shift;

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
    push @params, "--logging";
    push @params, "error";
    push @params, "--ignore";
    my $ignoreFile = $prefsDir . "/bliss-ignore.txt";
    _writeIgnoreFile($ignoreFile);
    push @params, $ignoreFile;

    if ($mode eq "ignore") {
        push @params, $mode;
        $analyserMode = $mode;
    } else {
        $analyserMode = "analyse";
        my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');
        my $numDirs = 0;
        my @ignoreDirs = ();
        my $idpref = $prefs->get('analyser_ignore_dirs');
        if ($idpref) {
            my @lines = split(/\n/, $idpref);
            foreach my $line (@lines) {
                push(@ignoreDirs, $line);
            }
        }
        my %ignoreDirsHash = map { $_ => 1 } @ignoreDirs;
        foreach my $dir (@$mediaDirs) {
            if (exists $ignoreDirsHash{$dir}) {
                main::DEBUGLOG && $log->debug("Ignoring ${dir}");
                next;
            }
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
        my $maxFiles =  $prefs->get('analyser_max_files');
        if ($maxFiles && $maxFiles>0) {
            push @params, "--numfiles";
            push @params, $maxFiles;
        }
        push @params, "--threads";
        my $maxThreads =  $prefs->get('analyser_max_threads');
        if ($maxThreads && $maxThreads>0) {
            push @params, $maxThreads;
        } else {
            push @params, "-1"; # => num cores -1
        }
        push @params, "--lms";
        push @params, "127.0.0.1";
        push @params, "--json";
        push @params, $serverprefs->get('httpport');
        push @params, "--notifs";
        push @params, "analyse-lms";
    }
    main::DEBUGLOG && $log->debug("Start analyser: $analyserBinary @params");
    eval { $analyser = Proc::Background->new({ 'die_upon_destroy' => 1 }, $analyserBinary, @params); };
    if ($reason && $reason eq "CLI") {
        $analysisStartTime = time();
        $prefs->set('analysis_start', $analysisStartTime);
    }
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
    _analysisEnded();
    $lastAnalyserStart = 0;
    if ($analyser && $analyser->alive) {
        $analyser->die;
    } else {
        main::DEBUGLOG && $log->debug("$analyserBinary not running");
    }
}

sub _writeIgnoreFile {
    my $path = shift;
    if (-e $path) {
        unlink($path);
    }
    if (open my $fh, '>:encoding(UTF-8)', $path) {
        my $ignore = $prefs->get('analyser_ignore_txt');
        if ($ignore) {
            my @lines = split(/[\n\v]/, $ignore);
            foreach my $line (@lines) {
                # Trim leading and trailing whitespace
                $line =~ s/^\\s+|\\s+$//g;
                # Ensure non-empty
                if (length $line > 0) {
                    print $fh "$line\n";
                }
            }
        }
        close($fh);
    }
}

sub _arrayToCsv {
    my @fields = @_;
    my @escaped;

    foreach my $field (@fields) {
        # Convert undef to empty string
        $field = '' unless defined $field;

        # Escape double quotes by doubling them
        $field =~ s/"/""/g;

        # If the field contains special CSV characters, wrap it in double quotes
        if ($field =~ /[",\r\n]/) {
            $field = qq{"$field"};
        }

        push @escaped, $field;
    }

    # Join fields with commas
    return join(',', @escaped);
}

sub _failuresHandler {
    my ( $httpClient, $response ) = @_;
    return unless $httpClient->connected;

    my $request = $response->request;

    my @lines = ();
    eval {
        my $dbh = DBI->connect( "dbi:SQLite:dbname=${dbPath}", '', '', { RaiseError => 0 });
        my $sth = $dbh->prepare( "SELECT File, Reason FROM Failures" );
        $sth->execute();
        while (my @row = $sth->fetchrow_array) {
            my @vals = ($row[0], $row[1]);
            push(@lines, _arrayToCsv(@vals));
        }
        $sth->finish();
        $dbh->disconnect();
    };
    my $csv = join("\n", @lines);

    $response->code(RC_OK);
    $response->content_type('text/csv');
    $response->header('Connection' => 'close');
    $response->content($csv);
    $httpClient->send_response($response);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);

}

1;

__END__
