package Plugins::BlissMixer::Plugin;

#
# LMS Bliss Mixer
#
# (c) 2022 Craig Drummond
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Slurp;
use File::Spec;
use Proc::Background;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

if ( main::WEBUI ) {
    require Plugins::BlissMixer::Settings;
}

use Plugins::BlissMixer::Settings;


use constant DEF_NUM_DSTM_TRACKS => 5;
use constant NUM_SEED_TRACKS => 5;
use constant MAX_PREVIOUS_TRACKS => 200;
use constant DEF_MAX_PREVIOUS_TRACKS => 100;
use constant NUM_MIX_TRACKS => 50;
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
my $initialized = 0;
my $mixer;
my $binary;


sub shutdownPlugin {
    _stopMixer();
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres    => 0,
        filter_xmas      => 1,
        host             => 'localhost',
        port             => 12000,
        min_duration     => 0,
        max_duration     => 0,
        no_repeat_artist => 15,
        no_repeat_album  => 25,
        no_repeat_track  => DEF_MAX_PREVIOUS_TRACKS,
        dstm_tracks      => DEF_NUM_DSTM_TRACKS,
        timeout          => 30
    });

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

    Slim::Menu::AlbumInfo->registerInfoProvider( blissmix => (
        below    => 'addalbum',
        func     => \&albumInfoHandler,
    ) );

    Slim::Menu::ArtistInfo->registerInfoProvider( blissmix => (
        below    => 'addartist',
        func     => \&artistInfoHandler,
    ) );


    $binary = Slim::Utils::Misc::findbin('bliss-mixer');
    main::INFOLOG && $log->info("Mixer: ${binary}");
    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXER_MIX', sub {
            my ($client, $cb) = @_;
            _dstmMix($client, $cb, 1, 0);
        });
        #Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXER_IGNORE_GENRE_MIX', sub {
        #    my ($client, $cb) = @_;
        #    _dstmMix($client, $cb, 0, 0);
        #});
    }
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
        main::DEBUGLOG && $log->debug("$binary not running");
    }
}

sub _startMixer {
    my $allow_uploads = shift;

    if ($mixer && $mixer->alive) {
        main::DEBUGLOG && $log->debug("$binary already running");
    }
    if (!$binary) {
        $log->warn("No mixer binary");
        return 0;
    }

    my $db = $serverprefs->get('cachedir') . "/" . DB_NAME;
    if ($allow_uploads == 0) {
        if (! -e $db) {
            $log->warn("No database ($db)");
            return 0;
        }
    }
    $prefs->set('port', 0);
    my @params;
    push @params, "--lms";
    push @params, "127.0.0.1";
    push @params, "--db";
    push @params, $db;
    if ($allow_uploads == 1) {
        push @params, "--upload";
    } else {
        push @params, "--address";
        push @params, "127.0.0.1";
    }
    main::DEBUGLOG && $log->debug("Start mixer with params: @params");
    eval { $mixer = Proc::Background->new({ 'die_upon_destroy' => 1 }, $binary, @params); };
    if ($@) {
        $log->warn($@);
    } else {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
            if ($mixer && $mixer->alive) {
                main::DEBUGLOG && $log->debug("$binary running");
            } else {
                main::DEBUGLOG && $log->debug("$binary NOT running");
            }
        });
    }
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

    if ($request->paramUndefinedOrNotOneOf($cmd, ['port', 'start-upload', 'stop', 'mix']) ) {
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
        $prefs->set('port', $number);
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

    # get our parameters
    my $tags   = $request->getParam('tags') || 'al';

    my $params = {
        track  => $request->getParam('track_id'),
        artist => $request->getParam('artist_id'),
        album  => $request->getParam('album_id'),
        genre  => $request->getParam('genre_id')
    };

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
        my $jsonData = _getMixData(\@seedsToUse, undef, NUM_MIX_TRACKS * 2, 1, $prefs->get('filter_genres') || 0);

        Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
        _callApi($request, $jsonData, NUM_MIX_TRACKS, @seedsToUse[0], 0);
        return;
    }
    $request->setStatusBadDispatch();
}

sub _confirmMixerStarted {
    my $request = shift;
    my $attempts = 0;
    if ($mixer && $mixer->alive && $prefs->get('port')>0) {
        $request->addResult("port", int($prefs->get('port')));
        $request->setStatusDone();
    }

    if ($attempts < 5) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
            _confirmMixerStarted($request, $attempts);
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

sub _callApi {
    my $request = shift;
    my $jsonData = shift;
    my $maxTracks = shift;
    my $seedToAdd = shift;
    my $callCount = shift;

    # If mixer is not running, or not yet informed us of its port, then start mixer
    if (!$mixer || !$mixer->alive || $prefs->get('port')<1) {
        if ($binary && $callCount < MAX_MIXER_START_CHECKS) {
            $callCount++;
            my $ok = _startMixer(0);
            if ($ok == 1) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _callApi($request, $jsonData, $maxTracks, $seedToAdd, $callCount);
                });
                return;
            }
        }
        main::DEBUGLOG && $log->debug("Failed to start mixer");
        $request->setStatusDone();
        return;
    }

    _resetMixerTimeout();

    my $port = $prefs->get('port') || 12000;
    my $url = "http://localhost:$port/api/mix";
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

            # TODO: Add more?
            push @usableTracks, $seedToAdd;
            push @ids, $seedToAdd->id;

            foreach my $track (@songs) {
                # Bug 4281 - need to convert from UTF-8 on Windows.
                if (main::ISWINDOWS && !-e track && -e Win32::GetANSIPathName($track)) {
                    $track = Win32::GetANSIPathName($track);
                }

                my $isFileUrl = index($track, 'file:///')==0;
                my $isCueUrl = $isFileUrl && index($track, '#')>0;
                if ($isFileUrl || -e $track || -e Slim::Utils::Unicode::utf8encode_locale($track)) {
                    # Decode file:// URL and re-encode so that match LMS's encoding
                    my $trackObj = Slim::Schema->objectForUrl($isCueUrl
                                                                ? $track
                                                                : Slim::Utils::Misc::fileURLFromPath($isFileUrl
                                                                                            ? Slim::Utils::Misc::pathFromFileURL($track)
                                                                                            : $track));
                    if (blessed $trackObj && ($trackObj->id != $seedToAdd->id)) {
                        push @usableTracks, $trackObj;
                        main::DEBUGLOG && $log->debug("..." . $track);
                        push @ids, $trackObj->id;
                        if (scalar(@ids) >= $maxTracks) {
                            last;
                        }
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

sub _dstmMix {
    my ($client, $cb, $filterGenres, $callCount) = @_;

    # If mixer is not running, or not yet informed us of its port, then start mixer
    if (!$mixer || !$mixer->alive || $prefs->get('port')<1) {
        if ($binary && $callCount < MAX_MIXER_START_CHECKS) {
            $callCount++;
            my $ok = _startMixer(0);
            if ($ok == 1) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _dstmMix($client, $cb, $filterGenres, $callCount);
                });
                return;
            }
        }

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
                push @seedsToUse, $trackObj;
                push @seedIds, $seedTrack;
                if ( $trackObj->path =~ m/^spotify:/ ) {
                    $numSpot++;
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
            my $port = $prefs->get('port') || 12000;
            my $url = "http://localhost:$port/api/mix";
            main::DEBUGLOG && $log->debug("URL: ${url}");
            Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $response = shift;
                    main::DEBUGLOG && $log->debug("Received API response");

                    my @songs = split(/\n/, $response->content);
                    my $count = scalar @songs;
                    my $tracks = ();

                    for (my $j = 0; $j < $count; $j++) {
                        # Bug 4281 - need to convert from UTF-8 on Windows.
                        if (main::ISWINDOWS && !-e $songs[$j] && -e Win32::GetANSIPathName($songs[$j])) {
                            $songs[$j] = Win32::GetANSIPathName($songs[$j]);
                        }

                        if (index($songs[$j], 'file:///')==0) {
                            if (index($songs[$j], '#')>0) { # Cue tracks
                                push @$tracks, $songs[$j];
                            } else {
                                # Decode file:// URL and re-encode so that match LMS's encoding
                                push @$tracks, Slim::Utils::Misc::fileURLFromPath(Slim::Utils::Misc::pathFromFileURL($songs[$j]));
                            }
                        } elsif ( -e $songs[$j] || -e Slim::Utils::Unicode::utf8encode_locale($songs[$j])) {
                            push @$tracks, Slim::Utils::Misc::fileURLFromPath($songs[$j]);
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

    foreach my $track (@tracks) {
        push @track_paths, $track->url;
    }

    if ($previousTracks and scalar @previous > 0) {
        foreach my $track (@previous) {
            push @previous_paths, $track->url;
        }
    }

    my $mediaDirs = $serverprefs->get('mediadirs');
    my $jsonData = to_json({
                        count       => int($trackCount),
                        filtergenre => int($filterGenres),
                        filterxmas  => int($prefs->get('filter_xmas') || 1),
                        min         => int($prefs->get('min_duration') || 0),
                        max         => int($prefs->get('max_duration') || 0),
                        tracks      => [@track_paths],
                        previous    => [@previous_paths],
                        shuffle     => int($shuffle),
                        norepart    => int($prefs->get('no_repeat_artist')),
                        norepalb    => int($prefs->get('no_repeat_album')),
                        genregroups => _genreGroups(),
                        mpath       => @$mediaDirs[0]
                    });

    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

my $configuredGenreGroups = [];
my $configuredGenreGroupsTs = 0;

sub _genreGroups {
    # Check to see if config has changed, saves try to read and process each time
    my $ts = $prefs->get('_ts_genre_groups');
    if ($ts==$configuredGenreGroupsTs) {
        return $configuredGenreGroups;
    }
    $configuredGenreGroupsTs = $ts;

    $configuredGenreGroups = [];
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
                }
            }
            if (scalar $grp > 0) {
                push(@$configuredGenreGroups, $grp);
            }
        }
    }
    return $configuredGenreGroups;
}

1;

__END__
