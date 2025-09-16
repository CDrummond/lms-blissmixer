package Plugins::BlissMixer::Settings;

#
# LMS Bliss Mixer
#
# (c) 2022-2025 Craig Drummond
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.blissmixer',
    'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('BlissMixer');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/BlissMixer/settings/blissmixer.html');
}

sub prefs {
    return ($prefs, 'host mixer_port', 'filter_genres', 'filter_xmas', 'min_duration', 'max_duration', 'no_repeat_artist', 'no_repeat_album', 'no_repeat_track', 'dstm_tracks', 'genre_groups', 'weight_tempo', 'weight_timbre', 'weight_loudness', 'weight_chroma', 'max_bpm_diff', 'use_track_genre', 'run_analyser_after_scan', 'analysis_running');
}

sub beforeRender {
    my ($class, $paramRef) = @_;
    $paramRef->{allowPortConfig} = $serverprefs->get('authorize');
    $paramRef->{'analysisRunning'} = 1 if Plugins::BlissMixer::Analyser::isScanning();
}

sub handler {
    my ($class, $client, $paramRef) = @_;
    if ($paramRef->{'rescan'}) {
        Plugins::BlissMixer::Analyser::rescan();
    } elsif ($paramRef->{'abortscan'}) {
        Plugins::BlissMixer::Analyser::abortScan();
    }
    return $class->SUPER::handler($client, $paramRef);
}

1;

__END__
