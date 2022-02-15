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


my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.blissmixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');
my $initialized = 0;

sub shutdownPlugin {
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
            _dstmMix($client, $cb, 1);
        });
        #Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXER_IGNORE_GENRE_MIX', sub {
        #    my ($client, $cb) = @_;
        #    _dstmMix($client, $cb, 0);
        #});
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
			$log->info("Found radio station last in the queue - don't start a mix.");
		}
		else {
			$log->info("No mixable items found in current playlist!");
		}
	}

	return;
}

sub _dstmMix {
    my ($client, $cb, $filterGenres) = @_;
    main::DEBUGLOG && $log->debug("Get similar tracks");
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
            my $host = $prefs->get('host') || 'localhost';
            my $port = $prefs->get('port') || 11000;
            my $url = "http://$host:$port/api/similar";
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
                        filtergenre => $filterGenres,
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
