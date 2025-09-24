package Plugins::BlissMixer::Plugin;

#
# LMS Bliss Mixer
#
# (c) 2022-2025 Craig Drummond
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Copy;
use File::Slurp;
use File::Spec;
use File::Spec::Functions qw(catdir);
use Proc::Background;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

use Plugins::BlissMixer::Analyser;
use Plugins::BlissMixer::Importer;
use Plugins::BlissMixer::Settings;
use Plugins::BlissMixer::ProtocolHandler;

use constant DEF_NUM_DSTM_TRACKS => 5;
use constant NUM_SEED_TRACKS => 5;
use constant MAX_PREVIOUS_TRACKS => 200;
use constant DEF_MAX_PREVIOUS_TRACKS => 100;
use constant NUM_MIX_TRACKS_FEW => 20; # Number of tracks in a mix if few seeds
use constant NUM_MIX_TRACKS => 50;     # Number of tracks in a mix
use constant NUM_LIST_TRACKS => 50;    # Number of tracks in a similarity list
use constant DB_NAME  => "bliss.db";
use constant STOP_MIXER => 60 * 60;
use constant MAX_MIXER_START_CHECKS => 10;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.blissmixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');
my $dbPath = "";
my $initialized = 0;
# Current bliss-mixer process
my $mixer;
# Port number mixer is running on
my $mixerPort = 0;
# Path to bliss-mixer that will be used on current system
my $mixerBinary;
# store time when bliss-mixer was started. This is then checked in _startMixer
# to ensure it is not attempted to be started again
my $lastMixerStart = 0;

my $lastWeights = "";

sub shutdownPlugin {
    _stopMixer();
    Plugins::BlissMixer::Analyser::stopAnalyser("SHUTDOWN");
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres    => 0,
        filter_xmas      => 1,
        host             => 'localhost',
        mixer_port       => 12000,
        min_duration     => 0,
        max_duration     => 0,
        no_repeat_artist => 15,
        no_repeat_album  => 25,
        no_repeat_track  => DEF_MAX_PREVIOUS_TRACKS,
        dstm_tracks      => DEF_NUM_DSTM_TRACKS,
        timeout          => 30,
        weight_tempo     => 4,
        weight_timbre    => 30,
        weight_loudness  => 9,
        weight_chroma    => 57,
        max_bpm_diff     => 0,
        use_track_genre  => 0,
        run_analyser_after_scan => 0,
        analysis_read_tags => 0,
        analysis_write_tags => 0
    });

    $prefs->setChange(\&Plugins::BlissMixer::Importer::toggleUseImporter, 'run_analyser_after_scan');

    if ( main::WEBUI ) {
        Plugins::BlissMixer::Settings->new;
    }

    #                                                            |requires Client
    #                                                            |  |is a Query
    #                                                            |  |  |has Tags
    #                                                            |  |  |  |Function to call
    #                                                            C  Q  T  F
    Slim::Control::Request::addDispatch(['blissmixer', '_cmd'], [0, 0, 1, \&_cliCommand]);

    Slim::Menu::TrackInfo->registerInfoProvider( blissmix => (
        above    => 'favorites',
        func     => \&trackInfoHandler,
    ) );

    Slim::Menu::TrackInfo->registerInfoProvider( blisssimilarity => (
        above    => 'favorites',
        func     => \&similarTracksHandler,
    ) );

    Slim::Menu::TrackInfo->registerInfoProvider( blisssimilaritybyartist => (
        above    => 'favorites',
        func     => \&similarTracksByArtistHandler,
    ) );

    Slim::Menu::AlbumInfo->registerInfoProvider( blissmix => (
        below    => 'addalbum',
        func     => \&albumInfoHandler,
    ) );

    Slim::Menu::ArtistInfo->registerInfoProvider( blissmix => (
        below    => 'addartist',
        func     => \&artistInfoHandler,
    ) );

    Slim::Player::ProtocolHandlers->registerHandler(
        blissmixer => 'Plugins::BlissMixer::ProtocolHandler'
    );

    my $dbDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
    my $prevDbPath = $serverprefs->get('cachedir') . "/" . DB_NAME;
    $dbPath = $dbDir . "/" . DB_NAME;
    if ((-e $prevDbPath) && (! -e $dbPath)) {
        move($prevDbPath, $dbPath);
    }

    _initBinaries();

    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXER_DSTM', sub {
            my ($client, $cb) = @_;
            _dstmMix($client, $cb, $prefs->get('filter_genres') || 0, 0);
        });
        #Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXER_DSTM_IGNORE_GENRES', sub {
        #    my ($client, $cb) = @_;
        #    _dstmMix($client, $cb, 0, 0);
        #});
    }
}

sub _initBinaries {
    my $dir = dirname(__FILE__);
    if (main::ISWINDOWS) {
        Slim::Utils::Misc::addFindBinPaths(catdir($dir, 'Bin', 'windows'));
    } elsif (main::ISMAC) {
        Slim::Utils::Misc::addFindBinPaths(catdir($dir, 'Bin', 'mac'));
    }
    $mixerBinary = Slim::Utils::Misc::findbin('bliss-mixer');
    main::INFOLOG && $log->info("Mixer: ${mixerBinary}");

    Plugins::BlissMixer::Analyser::init($dbPath);
}

sub _resetMixerTimeout {
    Slim::Utils::Timers::killTimers(undef, \&_stopMixer);
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + STOP_MIXER, \&_stopMixer);
}

sub _stopMixer {
    Slim::Utils::Timers::killTimers(undef, \&_stopMixer);
    if ($mixer && $mixer->alive) {
        $mixer->die;
    } else {
        main::DEBUGLOG && $log->debug("$mixerBinary not running");
    }
    $lastMixerStart = 0;
}

#
# If LMS is password protected then mixer cannot inform us of its port, so
# we run it on a user defined port. However, we need to know (for mixes) when
# it is actually ready, hence we poll /api/ready
#
sub _checkIfMixerReady {
    my $attempts = shift;
    my $port = $prefs->get('mixer_port');
    my $url = "http://localhost:$port/api/ready";
    my $http = LWP::UserAgent->new;

    $http->timeout(1);

    main::DEBUGLOG && $log->debug("Call $url");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            main::DEBUGLOG && $log->debug("Mixer is ready");
            $mixerPort = int($port);
        },
        sub {
            if ($attempts < MAX_MIXER_START_CHECKS) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _checkIfMixerReady($attempts + 1);
                });
            } else {
                main::DEBUGLOG && $log->debug("Could not determine if mixer is ready, assume it is?");
                $mixerPort = int($port);
            }
        }
    )->get($url, 'Content-Type' => 'application/json;charset=utf-8');
}

sub _weightParam {
    my @weights = ();
    my $tempo = int($prefs->get('weight_tempo') || 4);
    my $timbre = int($prefs->get('weight_timbre') || 30);
    my $loudness = int($prefs->get('weight_loudness') || 9);
    my $chroma = int($prefs->get('weight_chroma') || 57);

    my $total = $tempo + $timbre + $loudness + $chroma;
    $tempo = (($tempo / $total) * 100.0) / 4.0;
    $timbre = (($timbre / $total) * 100.0) / 30.0;
    $loudness = (($loudness / $total) * 100.0) / 9.0;
    $chroma = (($chroma / $total) * 100.0) / 57.0;

    push @weights, $tempo;
    for (my $i = 0; $i < 7; $i++) {
        push @weights, $timbre;
    }
    for (my $i = 0; $i < 2; $i++) {
        push @weights, $loudness;
    }
    for (my $i = 0; $i < 13; $i++) {
        push @weights, $chroma;
    }

    my $str = join(",", @weights);
    return $str;
}

sub _startMixer {
    my $allowUploads = shift;

    if ($mixer && $mixer->alive) {
        main::DEBUGLOG && $log->debug("$mixerBinary already running");
    }
    if (!$mixerBinary) {
        $log->warn("No mixer binary");
        return 0;
    }

    # Check to see if we attempted to start bliss-mixer less that 'MAX_MIXER_START_CHECKS+1'
    # seconds ago. If so, then we are awaiting its start response so no need to try to start
    my $now = Time::HiRes::time();
    if ($lastMixerStart!=0 && ($now-$lastMixerStart)<(MAX_MIXER_START_CHECKS+1)) {
        return 1;
    }

    $lastMixerStart = 0;
    if (($allowUploads == 0) && (! -e $dbPath)) {
        $log->warn("No database ($dbPath)");
        return 0;
    }
    $mixerPort = 0;
    my $cfgPort = int($prefs->get('mixer_port') || 0);
    if (!$serverprefs->get('authorize')) {
        $cfgPort = 0;
    }
    my @params;
    if ($cfgPort>0) {
        push @params, "--port";
        push @params, $cfgPort;
    } else {
        my $port = $serverprefs->get('httpport') || 9000;
        push @params, "--lms";
        push @params, Slim::Utils::Network::serverAddr() . ":" . $port;
    }
    push @params, "--db";
    push @params, $dbPath;
    if ($allowUploads == 1) {
        push @params, "--upload";
    } else {
        push @params, "--address";
        push @params, "127.0.0.1";
    }
    if ($prefs->get('mixerdebug')) {
        push @params, "--logging";
        push @params, "debug";
    }
    push @params, "--weights";
    $lastWeights = _weightParam();
    push @params, $lastWeights;
    main::DEBUGLOG && $log->debug("Start mixer: $mixerBinary @params");
    eval { $mixer = Proc::Background->new({ 'die_upon_destroy' => 1 }, $mixerBinary, @params); };
    if ($@) {
        $log->warn($@);
    } else {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
            if ($mixer && $mixer->alive) {
                main::DEBUGLOG && $log->debug("$mixerBinary running");
                # Mixer is running. If we have a hard-coded port then mixer will not inform us of its
                # ready state by sending this port. Therefore if we are in upload mode, assume its ready,
                # else poll its api/ready - as it might be reading db file...
                if ($cfgPort>0) {
                    if ($allowUploads) {
                        $mixerPort = $cfgPort;
                    } else {
                        _checkIfMixerReady(0);
                    }
                }
            } else {
                main::DEBUGLOG && $log->debug("$mixerBinary NOT running");
            }
        });
    }

    # Store start time
    $lastMixerStart = $now;
    return 1;
}

sub _cliCommand {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotCommand([['blissmixer']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');

    if ($request->paramUndefinedOrNotOneOf($cmd, ['port', 'start-upload', 'stop', 'mix', 'list', 'analyser']) ) {
        $request->setStatusBadParams();
        return;
    }

    if ($cmd eq 'port') {
        my $number = $request->getParam('number');
        if (!$number) {
            $request->setStatusBadParams();
            return;
        }
        main::DEBUGLOG && $log->debug("Mixer port: ${number}");
        $mixerPort = int($number);
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'start-upload') {
        main::DEBUGLOG && $log->debug("Requested to allow uploads");
        _stopMixer();
        _startMixer(1);
        $request->setStatusProcessing();
        _confirmMixerStarted($request, 0);
        return;
    }

    if ($cmd eq 'stop') {
        main::DEBUGLOG && $log->debug("Requested to stop");
        _stopMixer();
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'analyser') {
        Plugins::BlissMixer::Analyser::cliCommand($request);
        return;
    }

    my $count = $request->getParam('count') || -1;

    my @seedsToUse = ();
    if ($request->getParam('track_id')) {
        my ($trackObj) = Slim::Schema->find('Track', $request->getParam('track_id'));
        if ($trackObj) {
            main::DEBUGLOG && $log->debug("BlissMix Track Seed " . $trackObj->path);
            push @seedsToUse, $trackObj;
        }
    } else {
        my $sql;
        my $col = 'track';
        my $param;
        my $dbh = Slim::Schema->dbh;
        if ($request->getParam('artist_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT track FROM contributor_track WHERE contributor = ?} );
            $param = $request->getParam('artist_id');
        } elsif ($request->getParam('album_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT id FROM tracks WHERE album = ?} );
            $col = 'id';
            $param = $request->getParam('album_id');
        } elsif ($request->getParam('genre_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT track FROM genre_track WHERE genre = ?} );
            $param = $request->getParam('genre_id');
        } else {
            $request->setStatusBadDispatch();
            return
        }

        $sql->execute($param);
        if ( my $result = $sql->fetchall_arrayref({}) ) {
            foreach my $res (@$result) {
                my ($trackObj) = Slim::Schema->find('Track', $res->{$col});
                if ($trackObj) {
                    push @seedsToUse, $trackObj;
                }
            }
        }
        if (scalar @seedsToUse > NUM_SEED_TRACKS) {
            Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
            @seedsToUse = splice(@seedsToUse, 0, NUM_SEED_TRACKS);
        }

        foreach my $trackObj (@seedsToUse) {
            main::DEBUGLOG && $log->debug("BlissMix Track Seed " . $trackObj->path);
        }
    }

    main::DEBUGLOG && $log->debug("Num tracks for BlissMix: " . scalar(@seedsToUse));

    if (scalar @seedsToUse > 0) {
        if ($cmd eq 'mix') {
            my $numTracks = (scalar @seedsToUse) > 2 ? NUM_MIX_TRACKS : NUM_MIX_TRACKS_FEW;
            if ($count>0 && $count<$numTracks) {
                $numTracks = $count;
            }
            my $jsonData = _getMixData(\@seedsToUse, undef, $numTracks, 1, $prefs->get('filter_genres') || 0);

            Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
            if (0==_callApi($request, $jsonData, $numTracks, @seedsToUse[0], "mix", 0)) {
                $request->setStatusProcessing();
            }
        } else { # list
            my $numTracks = NUM_LIST_TRACKS;
            if ($count>0 && $count<$numTracks) {
                $numTracks = $count;
            }
            my $jsonData = _getListData(@seedsToUse[0], $numTracks, $prefs->get('filter_genres') || 0, $request->getParam('byArtist') || 0);
            if (0==_callApi($request, $jsonData, $numTracks, undef, "list", 0)) {
                $request->setStatusProcessing();
            }
        }
        return;
    }
    $request->setStatusBadDispatch();
}

sub _confirmMixerStarted {
    my $request = shift;
    my $attempts = shift;
    if ($mixer && $mixer->alive && $mixerPort>0) {
        $request->addResult("port", $mixerPort);
        $request->setStatusDone();
        return;
    }

    if ($attempts < 5) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
            _confirmMixerStarted($request, $attempts + 1);
        });
    } else {
        $request->addResult("port", 0);
        $request->setStatusDone();
    }
}

sub _getMixableProperties {
    my ($client, $count) = @_;

    return unless $client;

    $client = $client->master;

    my ($trackId, $artist, $title, $duration, $tracks);

    # Get last count*2 tracks from queue
    foreach (reverse @{ Slim::Player::Playlist::playList($client) } ) {
        ($artist, $title, $duration, $trackId) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);

        next unless defined $artist && defined $title;

        push @$tracks, $trackId;
        if ($count && scalar @$tracks > ($count * 2)) {
            last;
        }
    }

    if ($tracks && ref $tracks && scalar @$tracks && $duration) {
        main::INFOLOG && $log->info("Auto-mixing from random tracks in current playlist");

        if ($count && scalar @$tracks > $count) {
            Slim::Player::Playlist::fischer_yates_shuffle($tracks);
            splice(@$tracks, $count);
        }

        return $tracks;
    } elsif (main::INFOLOG && $log->is_info) {
        if (!$duration) {
            main::INFOLOG && $log->info("Found radio station last in the queue - don't start a mix.");
        } else {
            main::INFOLOG && $log->info("No mixable items found in current playlist!");
        }
    }

    return;
}

sub _mixerNotAvailable {
    my ($client, $cb) = @_;
    my $numSpot = 0;
    my $seedTracks = _getMixableProperties($client, NUM_SEED_TRACKS); # Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client,
    if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
        foreach my $seedTrack (@$seedTracks) {
            my ($trackObj) = Slim::Schema->find('Track', $seedTrack);
            if ($trackObj) {
                if ( $trackObj->path =~ m/^spotify:/ ) {
                    $numSpot++;
                }
            }
        }
    }
    _mixFailed($client, $cb, $numSpot);
}

sub _startsWith {
    my $str = shift;
    my $needle = shift;
    return rindex($str, $needle, 0)!=-1 ? 1 : 0;
}

# Convert a track object into a path relative to music folder
sub _trackToPath {
    my $mediaDirs = shift;
    my $track = shift;

    # Is this a CUE track? If so encode <file>#<start>-<stop> as <file>.CUE_TRACK.<num>
    my @parts = split(/#/, $track->url);
    my $suffix = "";
    if (2==scalar(@parts)) {
        $suffix = ".CUE_TRACK." . $track->tracknum;
    }

    # Get track's path relative to mediaDir
    my $path = $track->path;
    if (main::ISWINDOWS) {
       $path =~ s#\\#/#g;
    }

    foreach my $mediaDir (@$mediaDirs) {
        my $mdLen = length($mediaDir);
        if ($mdLen<1) {
            next;
        }
        if (main::ISWINDOWS) {
            $mediaDir =~ s#\\#/#g;
        }
        if (_startsWith($path, $mediaDir)) {
            $path = substr($path, $mdLen);
            $path = Slim::Utils::Unicode::utf8decode_locale($path);
            last;
        }
    }

    # Remove any leading slash
    if (_startsWith($path, "/")) {
        $path = substr($path, 1);
    }

    return $path . $suffix;
}

# Convert a path relative to music folder to a track object
sub _pathToTrack {
    my $mediaDirs = shift;
    my $path = shift;
    my $sep = "/";

    if (main::ISWINDOWS) {
        $path =~ s#/#\\#g;
        $sep = "\\";
    }

    # Decode <file>.CUE_TRACK.<num> to <file>#<start>-<stop>
    my $cueTrackNum = 0;
    my @parts = split(/\.CUE_TRACK\./, $path);
    if (2==scalar(@parts)) {
        $cueTrackNum = int($parts[1]);
        $path = @parts[0];
    }

    foreach my $mediaDir (@$mediaDirs) {
        my $mdLen = length($mediaDir);
        if ($mdLen<1) {
            next;
        }

        if (main::ISWINDOWS) {
           $mediaDir =~ s#/#\\#g;
        }
        my $md = substr($mediaDir, -1) eq $sep ? $mediaDir : "${mediaDir}${sep}";
        my $absPath = "${md}${path}";

        # Bug 4281 - need to convert from UTF-8 on Windows.
        if (main::ISWINDOWS && !-e track && -e Win32::GetANSIPathName($absPath)) {
            $absPath = Win32::GetANSIPathName($absPath);
        }

        $absPath = Slim::Utils::Unicode::utf8encode_locale($absPath);
        if (-e $absPath) {
            my $url = Slim::Utils::Misc::fileURLFromPath($absPath);

            if ($cueTrackNum>0) {
                # Get URL of specific track in CUE file
                my $dbh = Slim::Schema->dbh;
                my $sql = $dbh->prepare("SELECT url FROM tracks WHERE url LIKE '$url#%' AND tracknum = $cueTrackNum LIMIT 1");
                $sql->execute();
                if ( my $result = $sql->fetchall_arrayref({}) ) {
                    my $trackUrl = $result->[0]->{'url'} if ref $result && scalar @$result;
                    if ($trackUrl) {
                        # Got URL now get object
                        my $trackObj = Slim::Schema->objectForUrl($trackUrl);
                        if (blessed $trackObj) {
                            return $trackObj;
                        }
                    }
                }
            } else {
                my $trackObj = Slim::Schema->objectForUrl($url);
                if (blessed $trackObj) {
                    return $trackObj;
                }
            }
        }
    }
}

sub _callApi {
    my $request = shift;
    my $jsonData = shift;
    my $maxTracks = shift;
    my $seedToAdd = shift;
    my $api = shift;
    my $callCount = shift;

    my $weights = _weightParam();
    if ($weights ne $lastWeights) {
         main::DEBUGLOG && $log->debug("Metric weights changed, LAST: $lastWeights NOW: $weights - stop current mixer");
        _stopMixer();
    }

    # If mixer is not running, or not yet informed us of its port, then start mixer
    if (!$mixer || !$mixer->alive || $mixerPort<1) {
        if ($mixerBinary && $callCount < MAX_MIXER_START_CHECKS) {
            $callCount++;
            my $ok = _startMixer(0);
            if ($ok == 1) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _callApi($request, $jsonData, $maxTracks, $seedToAdd, $api, $callCount);
                });
                return 0;
            }
        }
        main::DEBUGLOG && $log->debug("Failed to start mixer");
        $request->setStatusDone();
        $lastMixerStart = 0;
        return 1;
    }

    _resetMixerTimeout();

    my $port = $mixerPort || 12000;
    my $url = "http://localhost:$port/api/$api";
    my $http = LWP::UserAgent->new;

    $http->timeout($prefs->get('timeout') || 30);

    main::DEBUGLOG && $log->debug("Call $url");
    $request->setStatusProcessing();
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            main::DEBUGLOG && $log->debug("Received API response ");

            my @songs = split(/\n/, $response->content);
            my $count = scalar @songs;
            my $tracks = ();
            my $tags     = $request->getParam('tags') || 'al';
            my $menu     = $request->getParam('menu');
            my $menuMode = defined $menu;
            my $loopname = $menuMode ? 'item_loop' : 'titles_loop';
            my $chunkCount = 0;
            my $useContextMenu = $request->getParam('useContextMenu');
            my @usableTracks = ();
            my @ids          = ();
            my $mediaDirs    = Slim::Utils::Misc::getMediaDirs('audio');

            # TODO: Add more?
            if ($seedToAdd) {
                push @usableTracks, $seedToAdd;
                push @ids, $seedToAdd->id;
            }

            foreach my $track (@songs) {
                my $trackObj = _pathToTrack($mediaDirs, $track);
                if (blessed $trackObj && (!$seedToAdd || ($trackObj->id != $seedToAdd->id))) {
                    push @usableTracks, $trackObj;
                    main::DEBUGLOG && $log->debug("..." . $track);
                    push @ids, $trackObj->id;
                    if (scalar(@ids) >= $maxTracks) {
                        last;
                    }
                }
            }

            if ($menuMode) {
                my $idList = join( ",", @ids );
                my $base = {
                    actions => {
                        go => {
                            cmd => ['trackinfo', 'items'],
                            params => {
                                menu => 'nowhere',
                                useContextMenu => '1',
                            },
                            itemsParams => 'params',
                        },
                        play => {
                            cmd => ['playlistcontrol'],
                            params => {
                                cmd  => 'load',
                                menu => 'nowhere',
                            },
                            nextWindow => 'nowPlaying',
                            itemsParams => 'params',
                        },
                        add =>  {
                            cmd => ['playlistcontrol'],
                            params => {
                                cmd  => 'add',
                                menu => 'nowhere',
                            },
                            itemsParams => 'params',
                        },
                        'add-hold' =>  {
                            cmd => ['playlistcontrol'],
                            params => {
                                cmd  => 'insert',
                                menu => 'nowhere',
                            },
                            itemsParams => 'params',
                        },
                    },
                };

                if ($useContextMenu) {
                    # "+ is more"
                    $base->{'actions'}{'more'} = $base->{'actions'}{'go'};
                    # "go is play"
                    $base->{'actions'}{'go'} = $base->{'actions'}{'play'};
                }
                $request->addResult('base', $base);

                $request->addResult('offset', 0);

                my $thisWindow = {
                    'windowStyle' => 'icon_list',
                    'text'       => $request->string('BLISSMIXER_MIX'),
                };
                $request->addResult('window', $thisWindow);

                # add an item for "play this mix"
                $request->addResultLoop($loopname, $chunkCount, 'nextWindow', 'nowPlaying');
                $request->addResultLoop($loopname, $chunkCount, 'text', $request->string('BLISSMIXER_PLAYTHISMIX'));
                $request->addResultLoop($loopname, $chunkCount, 'icon-id', '/html/images/playall.png');
                my $actions = {
                    'go' => {
                        'cmd' => ['playlistcontrol', 'cmd:load', 'menu:nowhere', 'track_id:' . $idList],
                    },
                    'play' => {
                        'cmd' => ['playlistcontrol', 'cmd:load', 'menu:nowhere', 'track_id:' . $idList],
                    },
                    'add' => {
                        'cmd' => ['playlistcontrol', 'cmd:add', 'menu:nowhere', 'track_id:' . $idList],
                    },
                    'add-hold' => {
                        'cmd' => ['playlistcontrol', 'cmd:insert', 'menu:nowhere', 'track_id:' . $idList],
                    },
                };
                $request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
                $chunkCount++;
            }

            foreach my $trackObj (@usableTracks) {
                if ($menuMode) {
                    Slim::Control::Queries::_addJiveSong($request, $loopname, $chunkCount, $chunkCount, $trackObj);
                } else {
                    Slim::Control::Queries::_addSong($request, $loopname, $chunkCount, $trackObj, $tags);
                }
                $chunkCount++;
            }
            main::DEBUGLOG && $log->debug("Num tracks to use:" . ($chunkCount - 1)); # Remove 'Play this mix' from count
            $request->addResult('count', $chunkCount);
            $request->setStatusDone();
        },
        sub {
            my $response = shift;
            my $error  = $response->error;
            main::DEBUGLOG && $log->debug("Failed to fetch URL: $error");
            $request->setStatusDone();
        }
    )->post($url, 'Timeout' => 30, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
    return 1;
}

sub trackInfoHandler {
    return _objectInfoHandler( 'track', @_ );
}

sub albumInfoHandler {
    return _objectInfoHandler( 'album', @_ );
}

sub artistInfoHandler {
    return _objectInfoHandler( 'artist', @_ );
}

sub _objectInfoHandler {
    my ( $objectType, $client, $url, $obj, $remoteMeta, $tags ) = @_;
    $tags ||= {};

    my $special;
    if ($objectType eq 'album') {
        $special->{'actionParam'} = 'album_id';
        $special->{'modeParam'}   = 'album';
        $special->{'urlKey'}      = 'album';
    } elsif ($objectType eq 'artist') {
        $special->{'actionParam'} = 'artist_id';
        $special->{'modeParam'}   = 'artist';
        $special->{'urlKey'}      = 'artist';
    } else {
        $special->{'actionParam'} = 'track_id';
        $special->{'modeParam'}   = 'track';
        $special->{'urlKey'}      = 'song';
    }

    return {
        type => 'redirect',
        jive => {
            actions => {
                go => {
                    player => 0,
                    cmd    => [ 'blissmixer', 'mix' ],
                    params => {
                        menu     => 1,
                        useContextMenu => 1,
                        $special->{actionParam} => $obj->id,
                    },
                },
            }
        },
        name      => cstring($client, 'BLISSMIXER_CREATE_MIX'),
        favorites => 0,

        player => {
            mode => 'blissmixer_mix',
            modeParams => {
                $special->{actionParam} => $obj->id,
            },
        }
    };
}

sub _trackSimilarityHandler {
    my ( $byArtist, $client, $url, $obj, $remoteMeta, $tags ) = @_;
    $tags ||= {};

    my $special;
    $special->{'actionParam'} = 'track_id';
    $special->{'modeParam'}   = 'track';
    $special->{'urlKey'}      = 'song';

    return {
        type      => 'redirect',
        jive      => {
            actions => {
                go => {
                    player => 0,
                    cmd    => [ 'blissmixer', 'list' ],
                    params => {
                        menu     => 1,
                        useContextMenu => 1,
                        $special->{actionParam} => $obj->id,
                        byArtist => $byArtist
                    },
                },
            }
        },
        name      => cstring($client, $byArtist == 1 ? 'BLISSMIXER_SIMILAR_TRACKS_BY_ARTIST' : 'BLISSMIXER_SIMILAR_TRACKS'),
        favorites => 0,

        player => {
            mode => 'blissmixer_list',
            modeParams => {
                $special->{actionParam} => $obj->id,
            },
        }
    };
}

sub similarTracksHandler {
    return _trackSimilarityHandler( 0, @_ );
}

sub similarTracksByArtistHandler {
    return _trackSimilarityHandler( 1, @_ );
}

sub _dstmMix {
    my ($client, $cb, $filterGenres, $callCount) = @_;

    if (_weightParam() ne $lastWeights) {
        _stopMixer();
    }

    # If mixer is not running, or not yet informed us of its port, then start mixer
    if (!$mixer || !$mixer->alive || $mixerPort<1) {
        if ($mixerBinary && $callCount < MAX_MIXER_START_CHECKS) {
            $callCount++;
            my $ok = _startMixer(0);
            if ($ok == 1) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _dstmMix($client, $cb, $filterGenres, $callCount);
                });
                return;
            }
        }

        $lastMixerStart = 0;
        _mixerNotAvailable($client, $cb);
        return;
    }

    _resetMixerTimeout();

    main::DEBUGLOG && $log->debug("Get tracks");
    my $seedTracks = _getMixableProperties($client, NUM_SEED_TRACKS); # Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, NUM_SEED_TRACKS);

    # don't seed from radio stations - only do if we're playing from some track based source
    # Get list of valid seeds...
    if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
        my @seedIds = ();
        my @seedsToUse = ();
        my $numSpot = 0;
        foreach my $seedTrack (@$seedTracks) {
            my ($trackObj) = Slim::Schema->find('Track', $seedTrack);
            if ($trackObj) {
                main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack);
                if ( $trackObj->path =~ m/^spotify:/ ) {
                    $numSpot++;
                } elsif (! ($trackObj->path =~ m/^deezer:/ || $trackObj->path =~ m/^qobuz:/ || $trackObj->path =~ m/^wimp:/) ) {
                    push @seedsToUse, $trackObj;
                    push @seedIds, $seedTrack;
                }
            }
        }

        if (scalar @seedsToUse > 0) {
            my $maxNumPrevTracks = $prefs->get('no_repeat_track');
            if ($maxNumPrevTracks<0 || $maxNumPrevTracks>MAX_PREVIOUS_TRACKS) {
                $maxNumPrevTracks = DEF_MAX_PREVIOUS_TRACKS;
            }
            my $previousTracks = _getPreviousTracks($client, $maxNumPrevTracks);
            main::DEBUGLOG && $log->debug("Num tracks to previous: " . ($previousTracks ? scalar(@$previousTracks) : 0));

            my $dstm_tracks = $prefs->get('dstm_tracks') || DEF_NUM_DSTM_TRACKS;
            my $jsonData = _getMixData(\@seedsToUse, $previousTracks ? \@$previousTracks : undef, $dstm_tracks, 1, $filterGenres);
            my $port = $mixerPort || 12000;
            my $url = "http://localhost:$port/api/mix";
            main::DEBUGLOG && $log->debug("URL: ${url}");
            Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $response = shift;
                    main::DEBUGLOG && $log->debug("Received API response");

                    my @songs = split(/\n/, $response->content);
                    my $count = scalar @songs;
                    my $tracks = ();
                    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');

                    for (my $j = 0; $j < $count; $j++) {
                        my $trackObj = _pathToTrack($mediaDirs, $songs[$j]);
                        if (blessed $trackObj) {
                            push @$tracks, $trackObj->url;
                        } else {
                            $log->error('API attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
                        }
                    }

                    if (!defined $tracks) {
                        _mixFailed($client, $cb, $numSpot);
                    } else {
                        main::DEBUGLOG && $log->debug("Num tracks to use:" . scalar(@$tracks));
                        foreach my $track (@$tracks) {
                            main::DEBUGLOG && $log->debug("..." . $track);
                        }
                        if (scalar @$tracks > 0) {
                            $cb->($client, $tracks);
                        } else {
                            _mixFailed($client, $cb, $numSpot);
                        }
                    }
                },
                sub {
                    my $response = shift;
                    my $error  = $response->error;
                    main::DEBUGLOG && $log->debug("Failed to fetch URL: $error");
                    _mixFailed($client, $cb, $numSpot);
                }
            )->post($url, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
        } else {
            _mixFailed($client, $cb, $numSpot);
        }
    }
}

sub prefName {
    my $class = shift;
    return lc($class->title);
}

sub title {
    my $class = shift;
    return 'BlissMixer';
}

sub _mixFailed {
    my ($client, $cb, $numSpot) = @_;

    if ($numSpot > 0 && exists $INC{'Plugins/Spotty/DontStopTheMusic.pm'}) {
        main::DEBUGLOG && $log->debug("Call through to Spotty");
        Plugins::Spotty::DontStopTheMusic::dontStopTheMusic($client, $cb);
    } elsif (exists $INC{'Plugins/LastMix/DontStopTheMusic.pm'}) {
        main::DEBUGLOG && $log->debug("Call through to LastMix");
        Plugins::LastMix::DontStopTheMusic::please($client, $cb);
    } else {
        main::DEBUGLOG && $log->debug("Return empty list");
        $cb->($client, []);
    }
}

sub _getPreviousTracks {
    my ($client, $count) = @_;
    main::DEBUGLOG && $log->debug("Get last " . $count . " tracks");
    return unless $client;

    $client = $client->master;

    my $tracks = ();
    if ($count>0) {
        for my $track (reverse @{ Slim::Player::Playlist::playList($client) } ) {
            if (!blessed $track) {
                $track = Slim::Schema->objectForUrl($track);
            }

            next unless blessed $track;

            push @$tracks, $track;
            if (scalar @$tracks >= $count) {
                return $tracks;
            }
        }
    }
    return $tracks;
}

sub _getMixData {
    my $seedTracks = shift;
    my $previousTracks = shift;
    my $trackCount = shift;
    my $shuffle = shift;
    my $filterGenres = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @previous = ref $previousTracks ? @$previousTracks : ($previousTracks);
    my @mix = ();
    my @track_paths = ();
    my @previous_paths = ();
    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');

    foreach my $track (@tracks) {
        push @track_paths, _trackToPath($mediaDirs, $track);
    }

    if ($previousTracks and scalar @previous > 0) {
        foreach my $track (@previous) {
            push @previous_paths, _trackToPath($mediaDirs, $track);
        }
    }

    my $filterXmas = 1;
    my $filterXmpsPref = $prefs->get('filter_xmas');
    if (defined $filterXmpsPref) {
        $filterXmas = int($filterXmpsPref);
    }

    my $jsonData = to_json({
                        count       => int($trackCount),
                        filtergenre => int($filterGenres),
                        filterxmas  => $filterXmas,
                        min         => int($prefs->get('min_duration') || 0),
                        max         => int($prefs->get('max_duration') || 0),
                        maxbpmdiff  => int($prefs->get('max_bpm_diff') || 0),
                        tracks      => [@track_paths],
                        previous    => [@previous_paths],
                        shuffle     => int($shuffle),
                        norepart    => int($prefs->get('no_repeat_artist')),
                        norepalb    => int($prefs->get('no_repeat_album')),
                        genregroups => _genreGroups()
                    });
    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

sub _getListData {
    my $seedTrack = shift;
    my $trackCount = shift;
    my $filterGenres = shift;
    my $byArtist = shift;

    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');
    my $jsonData = to_json({
                        count       => int($trackCount),
                        filtergenre => int($filterGenres),
                        min         => int($prefs->get('min_duration') || 0),
                        max         => int($prefs->get('max_duration') || 0),
                        maxbpmdiff  => int($prefs->get('max_bpm_diff') || 0),
                        track       => _trackToPath($mediaDirs, $seedTrack),
                        genregroups => _genreGroups(),
                        byartist    => int($byArtist)
                    });

    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

my $genreGroups = [];
my $genreGroupsTs = 0;
my $useTrackGenreTs = 0;

sub _genreGroups {
    # Check to see if config has changed, saves having to read and process each time
    my $ggTs = $prefs->get('_ts_genre_groups');
    my $utgTs = $prefs->get('_ts_use_track_genre');
    if ($ggTs==$genreGroupsTs && $utgTs==$useTrackGenreTs) {
        return $genreGroups;
    }
    $genreGroupsTs = $ggTs;
    $useTrackGenreTs = $utgTs;

    $genreGroups = [];
    my %genresInGroups=();
    my $ggpref = $prefs->get('genre_groups');
    if ($ggpref) {
        my @lines = split(/\n/, $ggpref);
        foreach my $line (@lines) {
            my @genreGroup = split(/\;/, $line);
            my $grp = ();
            foreach my $genre (@genreGroup) {
                # left trim
                $genre=~ s/^\s+//;
                # right trim
                $genre=~ s/\s+$//;
                if (length $genre > 0){
                    push(@$grp, $genre);
                    $genresInGroups{$genre}=1;
                }
            }
            if (scalar $grp > 0) {
                push(@$genreGroups, $grp);
            }
        }
    }
    if ($prefs->get('use_track_genre')) {
        my $request = Slim::Control::Request::executeRequest(undef, ["genres", 0, 5000] );
        foreach my $genre ( @{ $request->getResult('genres_loop') || [] } ) {
            my $name = $genre->{genre};
            if ($name && (not exists($genresInGroups{$name}))) {
                $genresInGroups{$name}=1;
                my $grp = ();
                push(@$grp, $name);
                push(@$genreGroups, $grp);
            }
        }
    }
    return $genreGroups;
}

1;

__END__
