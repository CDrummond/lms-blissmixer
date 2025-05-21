package Plugins::BlissMixer::ProtocolHandler;

#
# LMS Bliss Mixer
#
# (c) 2022-2025 Craig Drummond
#
# Licence: GPL v3
#

use strict;
use URI;
use URI::QueryParam;
use Slim::Utils::Log;
use URI::Escape qw(uri_unescape);

use Plugins::BlissMixer::Plugin;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.blissmixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

sub _getId {
    my ($dbh, $query, $param) = @_;
    main::DEBUGLOG && $log->debug("Query ${query}, param ${param}");
    my $sql = $dbh->prepare_cached( $query );
    $sql->execute(uri_unescape($param));
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            main::DEBUGLOG && $log->debug("Return " . $res->{id});
            return $res->{id};
        }
    }
    main::DEBUGLOG && $log->debug("Not found?");
    return undef;
}

sub _handleResp {
    my ( $client, $req, $params ) = @_;

    my $cleared = $params->{clear}==1 ? 0 : 1;
    my $useable = 0;
    main::DEBUGLOG && $log->debug("Process results");

    my @ids = ();
    foreach my $item ( @{ $req->getResult('titles_loop') || [] } ) {
        if ($item->{'id'}) {
            push @ids, $item->{'id'};
        }
    }

    if (scalar(@ids) > 0) {
        my $idList = join( ",", @ids );
        main::DEBUGLOG && $log->debug("Load IDS ${idList}");
        $client->execute(["playlistcontrol", "cmd:load", "track_id:${idList}"]);
        # Enable DSTM on player and set to bliss
        if ($params->{dstm}==1) {
            main::DEBUGLOG && $log->debug("Set to use DSTM");
            $client->execute(["playerpref", "plugin.dontstopthemusic:provider", "BLISSMIXER_DSTM"]);
            $client->execute(["playlist", "repeat", "0"]);
        }
    } else {
        main::DEBUGLOG && $log->debug("No tracks?");
    }
}

sub overridePlayback {
    my ( $class, $client, $url ) = @_;

    main::DEBUGLOG && $log->debug("Handler called");
    return unless $client;

    my $uri = URI->new($url);

    return unless $uri->scheme eq 'blissmixer';

    if ( Slim::Player::Source::streamingSongIndex($client) ) {
        # don't start immediately if we're part of a playlist and previous track isn't done playing
        return if $client->controller()->playingSongDuration()
    }

    main::DEBUGLOG && $log->debug("Parse params");
    my $params = $uri->query_form_hash;
    my $trackId = undef;
    my $genreId = undef;
    my $artistId = undef;
    my $albumId = undef;
    my $dbh = Slim::Schema->dbh;

    my $path = $params->{path};
    my $genre = $params->{genre};
    my $artist = $params->{artist};
    my $album = $params->{album};
    my $count = $params->{count};
    if ($path) {
        $trackId = _getId($dbh, "SELECT id FROM tracks WHERE url = ? LIMIT 1", $path);
    } elsif ($genre) {
        $genreId = _getId($dbh, "SELECT id FROM genres WHERE name = ? LIMIT 1", $genre);
    } else {
        if ($artist) {
            $artistId = _getId($dbh, "SELECT id FROM contributors WHERE name = ? LIMIT 1", $artist );
            if ($album && $artistId) {
                $albumId = _getId($dbh, "SELECT id FROM albums WHERE title = ? AND contributor=${artistId} LIMIT 1", $album );
            }
        }
    }

    my $command = ['blissmixer', 'mix'];
    if ($trackId) {
        push @$command, "track_id:$trackId";
    } elsif ($genreId) {
        push @$command, "genre_id:$genreId";
    } elsif ($albumId) {
        push @$command, "album_id:$albumId";
    } elsif ($artistId) {
        push @$command, "artist_id:$artistId";
    } else {
        main::DEBUGLOG && $log->debug("No ID found?");
        return;
    }

    if ($count && $count>0) {
        push @$command, "count:$count";
    }

    my $req = Slim::Control::Request::executeRequest(undef, $command);
    if ($req->isStatusProcessing) {
        $req->callbackFunction( sub { _handleResp($client, $req, $params); } );
    } else {
        _handleResp($client, $req, $params);
    }

    return 1;
}

sub canDirectStream { 0 }

sub contentType {
    return 'bliss';
}

sub isRemote { 0 }

sub getMetadataFor {
    my ( $class, $client, $url ) = @_;

    return unless $client && $url;

    my $uri = URI->new($url);
    my $params = $uri->query_form_hash;
    my $path = $params->{genre};
    my $genre = $params->{genre};
    my $artist = $params->{artist};
    my $album = $params->{album};
    my $text = "?";

    main::DEBUGLOG && $log->debug("url: ${url}");
    main::DEBUGLOG && $log->debug("path: ${path}");
    main::DEBUGLOG && $log->debug("genre: ${genre}");
    main::DEBUGLOG && $log->debug("artist: ${artist}");
    main::DEBUGLOG && $log->debug("album: ${album}");

    if ($path) {
        $text = uri_unescape($path);
    } elsif ($genre) {
        $text = uri_unescape($genre);
    } elsif ($artist && $album) {
        $text = uri_unescape($artist) . " - " . uri_unescape($album);
    } elsif ($artist) {
        $text = uri_unescape($artist);
    }

    return {
        title => $text,
        artist => $client->string('BLISSMIXER'),
        cover => $class->getIcon(),
    };
}

sub getIcon {
    return 'plugins/BlissMixer/html/images/blissmixer.png'; # Plugins::BlissMixer::Plugin->_pluginDataFor('icon');
}

1;
